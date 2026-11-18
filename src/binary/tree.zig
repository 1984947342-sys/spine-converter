//! JSON tree access for binary codecs

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const Error = error{ Malformed, OutOfMemory };

/// Puts skip values equal to the JSON default
pub const Object = struct {
    arena: std.mem.Allocator,
    map: ObjectMap = .empty,

    pub fn init(arena: std.mem.Allocator) Object {
        return .{ .arena = arena };
    }

    pub fn put(o: *Object, key: []const u8, v: Value) Error!void {
        try o.map.put(o.arena, key, v);
    }

    pub fn float(o: *Object, key: []const u8, v: f32, default: f32) Error!void {
        if (v != default) try o.put(key, .{ .float = v });
    }

    pub fn int(o: *Object, key: []const u8, v: i64, default: i64) Error!void {
        if (v != default) try o.put(key, .{ .integer = v });
    }

    pub fn boolean(o: *Object, key: []const u8, v: bool, default: bool) Error!void {
        if (v != default) try o.put(key, .{ .bool = v });
    }

    pub fn string(o: *Object, key: []const u8, v: ?[]const u8) Error!void {
        if (v) |s| try o.put(key, .{ .string = s });
    }

    pub fn color(o: *Object, key: []const u8, rgba8888: u32, default: u32) Error!void {
        if (rgba8888 != default) try o.put(key, .{ .string = try hex(o.arena, rgba8888, 8) });
    }

    pub fn value(o: Object) Value {
        return .{ .object = o.map };
    }
};

pub fn array(arena: std.mem.Allocator) std.json.Array {
    return .init(arena);
}

pub fn hex(arena: std.mem.Allocator, v: u32, comptime digits: u8) Error![]const u8 {
    return std.fmt.allocPrint(arena, "{x:0>" ++ std.fmt.comptimePrint("{d}", .{digits}) ++ "}", .{v});
}

/// Extra trailing digits are ignored like the JSON readers do
pub fn parseHex(s: []const u8, digits: usize) Error!u32 {
    if (s.len < digits) return error.Malformed;
    return std.fmt.parseInt(u32, s[0..digits], 16) catch error.Malformed;
}

pub fn get(o: Value, key: []const u8) ?Value {
    if (o != .object) return null;
    const v = o.object.get(key) orelse return null;
    return if (v == .null) null else v;
}

pub fn number(v: Value) Error!f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        .number_string => |s| std.fmt.parseFloat(f32, s) catch error.Malformed,
        else => error.Malformed,
    };
}

pub fn getFloat(o: Value, key: []const u8, default: f32) Error!f32 {
    return if (get(o, key)) |v| number(v) else default;
}

pub fn integer(v: Value) Error!i32 {
    return switch (v) {
        .integer => |i| std.math.cast(i32, i) orelse error.Malformed,
        .float => |f| if (f == @trunc(f) and @abs(f) <= std.math.maxInt(i32)) @intFromFloat(f) else error.Malformed,
        else => error.Malformed,
    };
}

pub fn getInt(o: Value, key: []const u8, default: i32) Error!i32 {
    return if (get(o, key)) |v| integer(v) else default;
}

/// Counts and indices are never negative
pub fn natural(v: Value) Error!u31 {
    return std.math.cast(u31, try integer(v)) orelse error.Malformed;
}

pub fn getNatural(o: Value, key: []const u8, default: u31) Error!u31 {
    return if (get(o, key)) |v| natural(v) else default;
}

pub fn getBool(o: Value, key: []const u8, default: bool) Error!bool {
    const v = get(o, key) orelse return default;
    return if (v == .bool) v.bool else error.Malformed;
}

pub fn getString(o: Value, key: []const u8) Error!?[]const u8 {
    const v = get(o, key) orelse return null;
    return if (v == .string) v.string else error.Malformed;
}

/// Skel from 4.0 on holds 8 hash bytes, other hashes read as none
pub fn getHash(o: Value) Error![8]u8 {
    return hashBytes(try getString(o, "hash") orelse "");
}

/// Start of a base64 hash or zeros
pub fn hashBytes(text: []const u8) [8]u8 {
    const decoder = std.base64.standard_no_pad.Decoder;
    var bytes: [32]u8 = @splat(0);
    const size = decoder.calcSizeForSlice(text) catch 0;
    if (size < 8 or size > bytes.len) return @splat(0);
    decoder.decode(bytes[0..size], text) catch return @splat(0);
    return bytes[0..8].*;
}

pub fn requireString(o: Value, key: []const u8) Error![]const u8 {
    return try getString(o, key) orelse error.Malformed;
}

pub fn getArray(o: Value, key: []const u8) Error![]const Value {
    const v = get(o, key) orelse return &.{};
    return if (v == .array) v.array.items else error.Malformed;
}

/// Missing objects read as empty
pub fn getObject(o: Value, key: []const u8) Error!ObjectMap {
    const v = get(o, key) orelse return .empty;
    return if (v == .object) v.object else error.Malformed;
}

/// RGB text gets opaque alpha like Color.valueOf
pub fn getColor(o: Value, key: []const u8, default: u32) Error!u32 {
    const s = try getString(o, key) orelse return default;
    return if (s.len == 6) try parseHex(s, 6) << 8 | 0xff else parseHex(s, 8);
}

test Object {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var o: Object = .init(arena.allocator());
    try o.float("x", 0, 0);
    try o.float("y", 2, 0);
    try o.color("color", 0xff3f00ff, 0xffffffff);
    const v = o.value();
    try std.testing.expectEqual(null, get(v, "x"));
    try std.testing.expectEqual(2, try getFloat(v, "y", 0));
    try std.testing.expectEqualStrings("ff3f00ff", (try getString(v, "color")).?);
    try std.testing.expectEqual(0xff3f00ff, try getColor(v, "color", 0));
    try std.testing.expectError(error.Malformed, getBool(v, "y", false));
}

test getHash {
    const a = std.testing.allocator;
    const short = try std.json.parseFromSlice(Value, a, "{\"hash\":\"AAAAAAAAAAE\"}", .{});
    defer short.deinit();
    try std.testing.expectEqual(1, (try getHash(short.value))[7]);
    const long = try std.json.parseFromSlice(Value, a, "{\"hash\":\"itfFESDjM1rBjm48y5ND1Ud5zqk\"}", .{});
    defer long.deinit();
    try std.testing.expectEqualSlices(u8, "\x8a\xd7\xc5\x11\x20\xe3\x33\x5a", &try getHash(long.value));
    const odd = try std.json.parseFromSlice(Value, a, "{\"hash\":\"my rig\"}", .{});
    defer odd.deinit();
    try std.testing.expectEqual(@as([8]u8, @splat(0)), try getHash(odd.value));
}

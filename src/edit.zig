//! In-place JSON tree edits for migrations

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const tree = @import("binary/tree.zig");

pub const Error = error{ Malformed, OutOfMemory };

/// Copies containers so edits of the copy keep the source
pub fn clone(arena: std.mem.Allocator, v: Value) Error!Value {
    switch (v) {
        .array => |a| {
            var out = try std.json.Array.initCapacity(arena, a.items.len);
            for (a.items) |item| out.appendAssumeCapacity(try clone(arena, item));
            return .{ .array = out };
        },
        .object => |o| {
            var out: ObjectMap = .empty;
            for (o.keys(), o.values()) |k, item| try out.put(arena, k, try clone(arena, item));
            return .{ .object = out };
        },
        else => return v,
    }
}

pub fn objectOf(v: *Value) Error!*ObjectMap {
    if (v.* != .object) return error.Malformed;
    return &v.object;
}

pub fn childValue(map: *ObjectMap, key: []const u8) Error!?*Value {
    const v = map.getPtr(key) orelse return null;
    return if (v.* == .null) null else v;
}

pub fn childOf(map: *ObjectMap, key: []const u8) Error!?*ObjectMap {
    return objectOf(try childValue(map, key) orelse return null);
}

pub fn arrayOf(map: *ObjectMap, key: []const u8) Error![]Value {
    const v = try childValue(map, key) orelse return &.{};
    if (v.* != .array) return error.Malformed;
    return v.array.items;
}

pub fn keysOf(v: *Value) Error![]Value {
    if (v.* != .array) return error.Malformed;
    return v.array.items;
}

/// Timelines of an animation grouped by constraint name
pub fn timelinesOf(animation: *ObjectMap, key: []const u8) Error!ObjectMap.Iterator {
    const empty: ObjectMap = .empty;
    const map = try childOf(animation, key) orelse return empty.iterator();
    return map.iterator();
}

pub fn take(map: *ObjectMap, key: []const u8) ?Value {
    return if (map.fetchOrderedRemove(key)) |kv| kv.value else null;
}

pub fn takeBool(map: *ObjectMap, key: []const u8) Error!bool {
    const v = take(map, key) orelse return false;
    if (v != .bool) return error.Malformed;
    return v.bool;
}

pub fn float(map: *const ObjectMap, key: []const u8, default: f32) Error!f32 {
    return tree.getFloat(.{ .object = map.* }, key, default);
}

/// Last key time below the value
pub fn lastTime(v: Value) f64 {
    var last: f64 = 0;
    switch (v) {
        .object => |o| for (o.keys(), o.values()) |key, c| {
            last = @max(last, if (std.mem.eql(u8, key, "time")) switch (c) {
                .integer => |i| @as(f64, @floatFromInt(i)),
                .float => |f| f,
                else => 0,
            } else lastTime(c));
        },
        .array => |a| for (a.items) |c| {
            last = @max(last, lastTime(c));
        },
        else => {},
    }
    return last;
}

pub fn indexOf(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

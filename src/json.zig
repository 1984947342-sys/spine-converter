const std = @import("std");
const Value = std.json.Value;
const Document = @import("Document.zig");
const Version = @import("Version.zig");
const stripBom = @import("detect.zig").stripBom;

pub const Error = error{ Malformed, OutOfMemory };

pub const EncodeOptions = struct {
    pretty: bool = false,
};

pub fn decode(arena: std.mem.Allocator, data: []const u8, version: Version) Error!Document {
    try checkDepth(data);
    var root = std.json.parseFromSliceLeaky(Value, arena, stripBom(data), .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    if (root != .object) return error.Malformed;
    // spine-csharp throws on a null list
    var i: usize = 0;
    while (i < root.object.count()) {
        if (root.object.values()[i] == .null) root.object.orderedRemoveAt(i) else i += 1;
    }
    return .{ .version = version, .origin = .json, .root = root };
}

/// Far deeper than any Spine export
const max_depth = 64;

fn checkDepth(data: []const u8) Error!void {
    var depth: usize = 0;
    var string = false;
    var escaped = false;
    for (data) |c| {
        if (string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') string = false;
            continue;
        }
        switch (c) {
            '"' => string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_depth) return error.Malformed;
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
}

pub fn encode(arena: std.mem.Allocator, doc: Document, options: EncodeOptions) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var w: Writer = .{ .arena = arena, .out = &out.writer, .pretty = options.pretty };
    w.value(doc.root) catch |e| return switch (e) {
        error.WriteFailed, error.OutOfMemory => error.OutOfMemory,
        error.Malformed => error.Malformed,
    };
    if (options.pretty) out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Floats are written as the shortest f32 text
const Writer = struct {
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    pretty: bool,
    depth: usize = 0,

    const WriteError = std.Io.Writer.Error || Error;

    /// Java readers take a surrogate as three bytes
    fn string(w: *Writer, s: []const u8) WriteError!void {
        if (std.unicode.utf8ValidateSlice(s)) return std.json.Stringify.encodeJsonString(s, .{}, w.out);
        const text = try w.arena.alloc(u8, s.len);
        var len: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const pair = s.len - i >= 6 and s[i] == 0xED and s[i + 1] & 0xF0 == 0xA0 and s[i + 2] & 0xC0 == 0x80 and
                s[i + 3] == 0xED and s[i + 4] & 0xF0 == 0xB0 and s[i + 5] & 0xC0 == 0x80;
            if (!pair) {
                text[len] = s[i];
                len += 1;
                i += 1;
                continue;
            }
            const high = @as(u21, s[i + 1] & 0x0F) << 6 | (s[i + 2] & 0x3F);
            const low = @as(u21, s[i + 4] & 0x0F) << 6 | (s[i + 5] & 0x3F);
            len += std.unicode.utf8Encode(0x10000 + (high << 10 | low), text[len..]) catch unreachable;
            i += 6;
        }
        if (!std.unicode.utf8ValidateSlice(text[0..len])) return error.Malformed;
        try std.json.Stringify.encodeJsonString(text[0..len], .{}, w.out);
    }

    /// JSON holds no NaN or infinity
    fn value(w: *Writer, v: Value) WriteError!void {
        switch (v) {
            .null => try w.out.writeAll("null"),
            .bool => |b| try w.out.writeAll(if (b) "true" else "false"),
            .integer => |i| try w.out.print("{d}", .{i}),
            .float => |f| if (!std.math.isFinite(f))
                return error.Malformed
            else if (@abs(f) <= std.math.floatMax(f32))
                try w.out.print("{d}", .{@as(f32, @floatCast(f))})
            else
                try w.out.print("{d}", .{f}),
            .number_string => |s| try w.out.writeAll(s),
            .string => |s| try w.string(s),
            .array => |a| {
                try w.out.writeByte('[');
                w.depth += 1;
                for (a.items, 0..) |item, i| {
                    if (i > 0) try w.out.writeByte(',');
                    try w.newline();
                    try w.value(item);
                }
                w.depth -= 1;
                if (a.items.len > 0) try w.newline();
                try w.out.writeByte(']');
            },
            .object => |o| {
                try w.out.writeByte('{');
                w.depth += 1;
                var it = o.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try w.out.writeByte(',');
                    first = false;
                    try w.newline();
                    try w.string(entry.key_ptr.*);
                    try w.out.writeAll(if (w.pretty) ": " else ":");
                    try w.value(entry.value_ptr.*);
                }
                w.depth -= 1;
                if (o.count() > 0) try w.newline();
                try w.out.writeByte('}');
            },
        }
    }

    fn newline(w: *Writer) std.Io.Writer.Error!void {
        if (!w.pretty) return;
        try w.out.writeByte('\n');
        try w.out.splatByteAll('\t', w.depth);
    }
};

test "round trip keeps order and f32 text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "{\"skeleton\":{\"spine\":\"4.3.39\"},\"b\":[1,0.30000001,-2.5,\"\\\"q\\\"\",null,true],\"a\":{}}";
    const doc = try decode(a, text, Version.parse("4.3.39").?);
    try std.testing.expectEqualStrings(
        "{\"skeleton\":{\"spine\":\"4.3.39\"},\"b\":[1,0.3,-2.5,\"\\\"q\\\"\",null,true],\"a\":{}}",
        try encode(a, doc, .{}),
    );
    try std.testing.expectEqualStrings("{\n\t\"a\": [\n\t\t1\n\t]\n}\n", try encode(a, try decode(a, "{\"a\":[1]}", doc.version), .{ .pretty = true }));
    try std.testing.expectError(error.Malformed, decode(a, "[1]", doc.version));
}

test "nesting depth" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = Version.parse("4.3.39").?;
    const deep = try repeat(a, "[", max_depth);
    const shut = try repeat(a, "]", max_depth);
    _ = try decode(a, try std.mem.concat(a, u8, &.{ "{\"a\":", deep[1..], shut[1..], "}" }), v);
    try std.testing.expectError(error.Malformed, decode(a, try std.mem.concat(a, u8, &.{ "{\"a\":", deep, shut, "}" }), v));
    _ = try decode(a, try std.mem.concat(a, u8, &.{ "{\"a\":\"\\\"", deep, deep, "\"}" }), v);
}

test "invalid UTF-8" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try decode(a, "{\"a\":1}", Version.parse("4.3.39").?);
    try doc.root.object.put(a, "a", .{ .string = "\xFF" });
    try std.testing.expectError(error.Malformed, encode(a, doc, .{}));
    _ = doc.root.object.orderedRemove("a");
    try doc.root.object.put(a, "\xFF", .null);
    try std.testing.expectError(error.Malformed, encode(a, doc, .{}));
}

test "surrogate pairs from binary" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try decode(a, "{}", Version.parse("4.3.39").?);
    try doc.root.object.put(a, "a\xED\xA0\xBD\xED\xB8\x80", .{ .string = "\xED\xA0\xBD\xED\xB8\x80b" });
    try std.testing.expectEqualStrings("{\"a\xF0\x9F\x98\x80\":\"\xF0\x9F\x98\x80b\"}", try encode(a, doc, .{}));
    for ([_][]const u8{ "\xED\xA0\xBD", "\xED\xB8\x80", "\xED\xA0\xBD\xED\xA0\xBD" }) |lone| {
        try doc.root.object.put(a, "b", .{ .string = lone });
        try std.testing.expectError(error.Malformed, encode(a, doc, .{}));
    }
}

test "non-finite floats" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try decode(a, "{\"a\":1}", Version.parse("4.3.39").?);
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |f| {
        try doc.root.object.put(a, "a", .{ .float = f });
        try std.testing.expectError(error.Malformed, encode(a, doc, .{}));
    }
}

fn repeat(a: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |_| try out.appendSlice(a, s);
    return out.items;
}

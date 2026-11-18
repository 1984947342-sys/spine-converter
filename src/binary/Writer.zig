//! Primitives of the Spine binary format, big endian

const std = @import("std");

const Writer = @This();

pub const Error = error{OutOfMemory};

arena: std.mem.Allocator,
out: std.ArrayList(u8) = .empty,

pub fn byte(w: *Writer, b: u8) Error!void {
    try w.out.append(w.arena, b);
}

pub fn boolean(w: *Writer, b: bool) Error!void {
    try w.byte(@intFromBool(b));
}

pub fn bytes(w: *Writer, data: []const u8) Error!void {
    try w.out.appendSlice(w.arena, data);
}

pub fn int(w: *Writer, comptime T: type, value: T) Error!void {
    var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .big);
    try w.bytes(&buf);
}

pub fn float(w: *Writer, value: f32) Error!void {
    try w.int(u32, @bitCast(value));
}

/// Without optimize_positive the value is zigzag encoded
pub fn varint(w: *Writer, value: i32, optimize_positive: bool) Error!void {
    var v: u32 = if (optimize_positive) @bitCast(value) else @bitCast((value << 1) ^ (value >> 31));
    while (v >= 0x80) : (v >>= 7) try w.byte(@as(u8, @truncate(v)) | 0x80);
    try w.byte(@truncate(v));
}

pub fn count(w: *Writer, n: usize) Error!void {
    try w.varint(@intCast(n), true);
}

/// Byte count plus one prefix zero is null
pub fn string(w: *Writer, s: ?[]const u8) Error!void {
    const text = s orelse return w.byte(0);
    try w.count(text.len + 1);
    try w.bytes(text);
}

test "matches Reader" {
    const Reader = @import("Reader.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: Writer = .{ .arena = arena.allocator() };
    try w.varint(300, true);
    try w.varint(-2, false);
    try w.varint(-1, true);
    try w.varint(std.math.minInt(i32), false);
    try w.string(null);
    try w.string("abc");
    try w.float(1.5);
    var r: Reader = .{ .data = w.out.items };
    try std.testing.expectEqual(300, try r.varint(true));
    try std.testing.expectEqual(-2, try r.varint(false));
    try std.testing.expectEqual(-1, try r.varint(true));
    try std.testing.expectEqual(std.math.minInt(i32), try r.varint(false));
    try std.testing.expectEqual(null, try r.string());
    try std.testing.expectEqualStrings("abc", (try r.string()).?);
    try std.testing.expectEqual(1.5, try r.float());
}

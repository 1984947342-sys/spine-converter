//! Primitives of the Spine binary format, big endian

const std = @import("std");

const Reader = @This();

pub const Error = error{EndOfData};

data: []const u8,
pos: usize = 0,

pub fn byte(r: *Reader) Error!u8 {
    if (r.pos >= r.data.len) return error.EndOfData;
    defer r.pos += 1;
    return r.data[r.pos];
}

pub fn boolean(r: *Reader) Error!bool {
    return try r.byte() != 0;
}

pub fn bytes(r: *Reader, len: usize) Error![]const u8 {
    if (r.data.len - r.pos < len) return error.EndOfData;
    defer r.pos += len;
    return r.data[r.pos..][0..len];
}

pub fn int(r: *Reader, comptime T: type) Error!T {
    const n = @divExact(@typeInfo(T).int.bits, 8);
    return std.mem.readInt(T, (try r.bytes(n))[0..n], .big);
}

pub fn float(r: *Reader) Error!f32 {
    return @bitCast(try r.int(u32));
}

/// Without optimize_positive the value is zigzag encoded
pub fn varint(r: *Reader, optimize_positive: bool) Error!i32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) : (shift += 7) {
        const b = try r.byte();
        result |= @as(u32, b & 0x7F) << shift;
        if (b & 0x80 == 0 or shift == 28) break;
    }
    if (optimize_positive) return @bitCast(result);
    return @bitCast((result >> 1) ^ (0 -% (result & 1)));
}

/// Byte count plus one prefix zero is null
pub fn string(r: *Reader) Error!?[]const u8 {
    const n: u32 = @bitCast(try r.varint(true));
    if (n == 0) return null;
    return try r.bytes(n - 1);
}

test varint {
    var r: Reader = .{ .data = &.{ 0x05, 0xAC, 0x02, 0x03, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F } };
    try std.testing.expectEqual(5, try r.varint(true));
    try std.testing.expectEqual(300, try r.varint(true));
    try std.testing.expectEqual(-2, try r.varint(false));
    try std.testing.expectEqual(-1, try r.varint(true));
    try std.testing.expectError(error.EndOfData, r.byte());
}

test string {
    var r: Reader = .{ .data = "\x00\x01\x04abc" };
    try std.testing.expectEqual(null, try r.string());
    try std.testing.expectEqualStrings("", (try r.string()).?);
    try std.testing.expectEqualStrings("abc", (try r.string()).?);
}

test float {
    var r: Reader = .{ .data = &.{ 0x3F, 0x80, 0x00, 0x00 } };
    try std.testing.expectEqual(1.0, try r.float());
}

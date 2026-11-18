//! Binary codecs by minor version

const std = @import("std");
const Document = @import("Document.zig");
const Report = @import("Report.zig");
const Version = @import("Version.zig");

pub const CodecError = error{ Malformed, OutOfMemory };
pub const Error = CodecError || error{UnsupportedVersion};

/// Each codec maps binary data to the JSON tree of the same version
pub const Codec = struct {
    major: u16,
    minor: u16,
    decode: *const fn (arena: std.mem.Allocator, data: []const u8, version: Version, report: *Report) CodecError!Document,
    encode: *const fn (arena: std.mem.Allocator, doc: Document, report: *Report) CodecError![]const u8,
};

const codecs = [_]Codec{
    entry(3, 5, @import("binary/v3_5.zig")),
    entry(3, 6, @import("binary/v3_6.zig")),
    entry(3, 7, @import("binary/v3_7.zig")),
    entry(3, 8, @import("binary/v3_8.zig")),
    entry(4, 0, @import("binary/v4_0.zig")),
    entry(4, 1, @import("binary/v4_1.zig")),
    entry(4, 2, @import("binary/v4_2.zig")),
    entry(4, 3, @import("binary/v4_3.zig")),
};

fn entry(major: u16, minor: u16, comptime module: type) Codec {
    return .{ .major = major, .minor = minor, .decode = module.decode, .encode = module.encode };
}

pub fn decode(arena: std.mem.Allocator, data: []const u8, version: Version, report: *Report) Error!Document {
    const codec = find(version) orelse return error.UnsupportedVersion;
    return codec.decode(arena, data, version, report);
}

pub fn encode(arena: std.mem.Allocator, doc: Document, report: *Report) Error![]const u8 {
    const codec = find(doc.version) orelse return error.UnsupportedVersion;
    return codec.encode(arena, doc, report);
}

fn find(version: Version) ?Codec {
    for (codecs) |codec| {
        if (codec.major == version.major and codec.minor == version.minor) return codec;
    }
    return null;
}

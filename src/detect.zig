const std = @import("std");
const Version = @import("Version.zig");
const Reader = @import("binary/Reader.zig");

/// Values mirror spc_format in spine_converter.h
pub const Format = enum(c_int) {
    unknown = 0,
    json = 1,
    binary = 2,
    atlas = 3,
};

pub const Detected = struct {
    format: Format,
    /// Null for atlases and JSON skeletons that carry no version
    version: ?Version,
};

pub const Error = error{UnknownFormat};

pub fn detect(data: []const u8) Error!Detected {
    // a 4.0+ binary hash can start with a brace
    if (isJson(data)) return .{ .format = .json, .version = jsonVersion(data) catch return asBinary(data, false) };
    if (isAtlas(data)) return .{ .format = .atlas, .version = null };
    return asBinary(data, true);
}

fn asBinary(data: []const u8, old: bool) Error!Detected {
    return .{ .format = .binary, .version = binaryVersion(data, old) catch return error.UnknownFormat };
}

pub fn stripBom(data: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) data[3..] else data;
}

fn isJson(data: []const u8) bool {
    for (stripBom(data)) |c| switch (c) {
        ' ', '\t', '\r', '\n' => continue,
        '{' => return true,
        else => return false,
    };
    return false;
}

/// Atlases start with a page name line followed by key value lines
fn isAtlas(data: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stripBom(data), '\n');
    var name = false;
    while (lines.next()) |raw| {
        for (raw) |c| if (c < 0x20 and c != '\t' and c != '\r') return false;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            if (name) return false;
            continue;
        }
        const entry = isEntry(line);
        if (name) return entry;
        if (!entry) name = true;
    }
    return false;
}

/// Runtimes only read lettered keys
fn isEntry(line: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    const key = std.mem.trimEnd(u8, line[0..colon], " \t");
    if (key.len == 0) return false;
    for (key) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}

fn jsonVersion(data: []const u8) Error!?Version {
    var scratch: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = std.json.Scanner.initCompleteInput(fba.allocator(), stripBom(data));
    return scanRoot(&scanner, fba.allocator()) catch error.UnknownFormat;
}

fn scanRoot(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !?Version {
    if (try scanner.next() != .object_begin) return error.UnknownFormat;
    var is_skeleton = false;
    var version: ?Version = null;
    while (try nextKey(scanner, allocator)) |key| {
        if (std.mem.eql(u8, key, "skeleton")) {
            is_skeleton = true;
            version = try scanSkeleton(scanner, allocator);
        } else {
            if (std.mem.eql(u8, key, "bones")) is_skeleton = true;
            try scanner.skipValue();
        }
    }
    if (!is_skeleton) return error.UnknownFormat;
    return version;
}

fn scanSkeleton(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !?Version {
    if (try scanner.next() != .object_begin) return error.UnknownFormat;
    var version: ?Version = null;
    while (try nextKey(scanner, allocator)) |key| {
        if (!std.mem.eql(u8, key, "spine")) {
            try scanner.skipValue();
            continue;
        }
        const s = switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
            .string, .allocated_string => |s| s,
            else => return error.UnknownFormat,
        };
        version = Version.parse(s) orelse Version.unnumbered(s) orelse return error.UnknownFormat;
    }
    return version;
}

fn nextKey(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !?[]const u8 {
    return switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
        .object_end => null,
        .string, .allocated_string => |s| s,
        else => error.UnknownFormat,
    };
}

/// Header layouts and length limit from SkeletonBinary
fn binaryVersion(data: []const u8, old: bool) !Version {
    // 4.0+ int64 hash then version string
    var r: Reader = .{ .data = data, .pos = @min(8, data.len) };
    if (headerString(&r)) |s| {
        if (s.len > 0 and std.ascii.isDigit(s[0])) return Version.parse(s) orelse error.UnknownFormat;
    } else |_| {}
    if (!old) return error.UnknownFormat;
    // 3.8 and older hash string then version string
    r = .{ .data = data };
    _ = try r.string();
    const s = try headerString(&r);
    if (Version.parse(s)) |version| return version;
    if (!std.mem.eql(u8, s, "Dev")) return error.UnknownFormat;
    return Version.unnumbered(s) orelse error.UnknownFormat;
}

fn headerString(r: *Reader) ![]const u8 {
    const start = r.pos;
    if (try r.varint(true) > 13) return error.UnknownFormat;
    r.pos = start;
    return (try r.string()) orelse error.UnknownFormat;
}

test "json" {
    const d = try detect("\xEF\xBB\xBF {\"skeleton\":{\"hash\":\"x\",\"spine\":\"4.2.43\"},\"bones\":[]}");
    try std.testing.expectEqual(Format.json, d.format);
    try std.testing.expectEqualStrings("4.2.43", d.version.?.text());
    try std.testing.expectEqual(null, (try detect("{\"bones\":[{\"name\":\"root\"}]}")).version);
    try std.testing.expectError(error.UnknownFormat, detect("{\"name\":\"package\"}"));
    try std.testing.expectError(error.UnknownFormat, detect("{\"skeleton\":"));
}

test "atlas" {
    try std.testing.expectEqual(Format.atlas, (try detect("\na.png\nsize: 2,2\nr\n  xy: 0, 0\n")).format);
    try std.testing.expectEqual(Format.atlas, (try detect("scale: 1\na.png\n\tsize: 2, 2\n")).format);
    try std.testing.expectError(error.UnknownFormat, detect("[\n  { \"Code\": \"en\" }\n]\n"));
    try std.testing.expectEqual(null, (try detect("a.png\nsize: 2,2\n")).version);
    try std.testing.expectError(error.UnknownFormat, detect("a.png\n\nsize: 2,2\n"));
}

test "binary" {
    const new = "\x01\x02\x03\x04\x05\x06\x07\x08\x07" ++ "4.3.22" ++ "rest";
    try std.testing.expectEqualStrings("4.3.22", (try detect(new)).version.?.text());
    const old = "\x0C" ++ "itfFESDjM1c" ++ "\x07" ++ "3.8.99" ++ "rest";
    try std.testing.expectEqualStrings("3.8.99", (try detect(old)).version.?.text());
    const brace = "{\x02\x03\x04\x05\x06\x07\x08\x07" ++ "4.3.22" ++ "rest";
    try std.testing.expectEqual(Format.binary, (try detect(brace)).format);
    try std.testing.expectEqualStrings("4.3.22", (try detect(brace)).version.?.text());
    // newline as the length of an old version
    const prose = "\x1Athis text has a line break\x0Athe next lin";
    try std.testing.expectError(error.UnknownFormat, detect(prose));
    const dev = "\x0C" ++ "itfFESDjM1c" ++ "\x04" ++ "Dev" ++ "rest";
    try std.testing.expectEqualStrings("Dev", (try detect(dev)).version.?.text());
    // brace as the length of an old hash
    var text: [132]u8 = undefined;
    text[0] = '{';
    @memset(text[1..123], ' ');
    text[123] = '\t';
    @memcpy(text[124..], "  \"targe");
    try std.testing.expectError(error.UnknownFormat, detect(&text));
    try std.testing.expectError(error.UnknownFormat, detect("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR"));
    try std.testing.expectError(error.UnknownFormat, detect(""));
}

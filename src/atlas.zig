//
// Spine Runtimes License Agreement
// Last updated April 5, 2025. Replaces all prior versions.
//
// Copyright (c) 2013-2025, Esoteric Software LLC
//
// Integration of the Spine Runtimes into software or otherwise creating
// derivative works of the Spine Runtimes is permitted under the terms and
// conditions of Section 2 of the Spine Editor License Agreement:
// http://esotericsoftware.com/spine-editor-license
//
// Otherwise, it is permitted to integrate the Spine Runtimes into software
// or otherwise create derivative works of the Spine Runtimes (collectively,
// "Products"), provided that each user of the Products must obtain their own
// Spine Editor license and redistribution of the Products in any form must
// include this license and copyright notice.
//
// THE SPINE RUNTIMES ARE PROVIDED BY ESOTERIC SOFTWARE LLC "AS IS" AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL ESOTERIC SOFTWARE LLC BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES,
// BUSINESS INTERRUPTION, OR LOSS OF USE, DATA, OR PROFITS) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
// THE SPINE RUNTIMES, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

//! Texture atlas text, mapped by Atlas.cpp of the 3.8 and 4.x branches

const std = @import("std");
const Version = @import("Version.zig");
const Report = @import("Report.zig");
const stripBom = @import("detect.zig").stripBom;

pub const Error = error{ UnsupportedVersion, Malformed, OutOfMemory };

const Entry = struct { key: []const u8, values: []const []const u8 };

const Section = struct {
    name: []const u8,
    entries: []const Entry,
};

const Page = struct {
    section: Section,
    regions: []const Section,
};

const Atlas = struct {
    header: []const Entry,
    pages: []const Page,
};

/// Null target keeps the data, 3.5 to 3.8 get the positional layout and 4.x the keyed layout
pub fn convert(arena: std.mem.Allocator, data: []const u8, target: ?Version, report: *Report) Error![]const u8 {
    const t = target orelse return arena.dupe(u8, data);
    const legacy = t.major == 3 and t.minor >= 5 and t.minor <= 8;
    if (!legacy and !(t.major == 4 and t.minor <= 3)) return error.UnsupportedVersion;
    const atlas = try parse(arena, data);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    (if (legacy) writeLegacy(arena, w, atlas, t.minor, report) else writeKeyed(arena, w, atlas)) catch |e| return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
    return out.written();
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn parseEntry(arena: std.mem.Allocator, raw: ?[]const u8) Error!?Entry {
    const line = trim(raw orelse return null);
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var values: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
    while (it.next()) |v| try values.append(arena, trim(v));
    return .{ .key = trim(line[0..colon]), .values = values.items };
}

fn parseEntries(arena: std.mem.Allocator, lines: *std.mem.SplitIterator(u8, .scalar), line: *?[]const u8) Error![]const Entry {
    var entries: std.ArrayList(Entry) = .empty;
    while (true) {
        line.* = lines.next();
        try entries.append(arena, try parseEntry(arena, line.*) orelse break);
    }
    return entries.items;
}

fn parse(arena: std.mem.Allocator, data: []const u8) Error!Atlas {
    var lines = std.mem.splitScalar(u8, stripBom(data), '\n');
    var line = lines.next();
    while (line != null and trim(line.?).len == 0) line = lines.next();
    var header: std.ArrayList(Entry) = .empty;
    while (line) |l| : (line = lines.next()) {
        try header.append(arena, try parseEntry(arena, l) orelse break);
    }

    var pages: std.ArrayList(Page) = .empty;
    var regions: std.ArrayList(Section) = .empty;
    var in_page = false;
    while (line) |l| {
        const name = trim(l);
        if (name.len == 0) {
            if (in_page) pages.items[pages.items.len - 1].regions = try regions.toOwnedSlice(arena);
            in_page = false;
            line = lines.next();
        } else if (!in_page) {
            try pages.append(arena, .{ .section = .{ .name = name, .entries = try parseEntries(arena, &lines, &line) }, .regions = &.{} });
            in_page = true;
        } else {
            try regions.append(arena, .{ .name = name, .entries = try parseEntries(arena, &lines, &line) });
        }
    }
    if (in_page) pages.items[pages.items.len - 1].regions = try regions.toOwnedSlice(arena);
    if (pages.items.len == 0) return error.Malformed;
    return .{ .header = header.items, .pages = pages.items };
}

fn ints(comptime n: usize, entry: Entry) Error![n]i32 {
    if (entry.values.len < n) return error.Malformed;
    var result: [n]i32 = undefined;
    for (&result, entry.values[0..n]) |*r, v| r.* = std.fmt.parseInt(i32, v, 10) catch return error.Malformed;
    return result;
}

pub const Region = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    original_width: i32 = 0,
    original_height: i32 = 0,
    degrees: i32 = 0,
    /// spine-libgdx default, spine-cpp 4.x leaves 0
    index: i32 = -1,
    custom: []const Entry = &.{},
};

/// Regions by name, the first of a name wins
pub fn regionMap(arena: std.mem.Allocator, data: []const u8) Error!std.StringHashMapUnmanaged(Region) {
    var out: std.StringHashMapUnmanaged(Region) = .empty;
    for ((try parse(arena, data)).pages) |page| for (page.regions) |section| {
        const entry = try out.getOrPut(arena, section.name);
        if (!entry.found_existing) entry.value_ptr.* = try regionOf(arena, section);
    };
    return out;
}

/// Whether whitespace was stripped
pub fn isStripped(r: Region) bool {
    return r.offset_x != 0 or r.offset_y != 0 or r.original_width != r.width or r.original_height != r.height;
}

fn regionOf(arena: std.mem.Allocator, section: Section) Error!Region {
    var r: Region = .{};
    var custom: std.ArrayList(Entry) = .empty;
    for (section.entries) |e| {
        if (std.mem.eql(u8, e.key, "xy")) {
            r.x, r.y = try ints(2, e);
        } else if (std.mem.eql(u8, e.key, "size")) {
            r.width, r.height = try ints(2, e);
        } else if (std.mem.eql(u8, e.key, "bounds")) {
            r.x, r.y, r.width, r.height = try ints(4, e);
        } else if (std.mem.eql(u8, e.key, "offset")) {
            r.offset_x, r.offset_y = try ints(2, e);
        } else if (std.mem.eql(u8, e.key, "orig")) {
            r.original_width, r.original_height = try ints(2, e);
        } else if (std.mem.eql(u8, e.key, "offsets")) {
            r.offset_x, r.offset_y, r.original_width, r.original_height = try ints(4, e);
        } else if (std.mem.eql(u8, e.key, "rotate")) {
            if (e.values.len == 0) return error.Malformed;
            if (std.mem.eql(u8, e.values[0], "true")) {
                r.degrees = 90;
            } else if (!std.mem.eql(u8, e.values[0], "false")) {
                r.degrees = (try ints(1, e))[0];
            }
        } else if (std.mem.eql(u8, e.key, "index")) {
            r.index = (try ints(1, e))[0];
        } else {
            try custom.append(arena, e);
        }
    }
    if (r.original_width == 0 and r.original_height == 0) {
        r.original_width = r.width;
        r.original_height = r.height;
    }
    r.custom = custom.items;
    return r;
}

fn find(entries: []const Entry, key: []const u8) ?Entry {
    for (entries) |e| if (std.mem.eql(u8, e.key, key)) return e;
    return null;
}

fn isPageKey(key: []const u8) bool {
    for ([_][]const u8{ "size", "format", "filter", "repeat", "pma" }) |k| if (std.mem.eql(u8, key, k)) return true;
    return false;
}

fn writeEntry(w: *std.Io.Writer, indent: []const u8, e: Entry) !void {
    try w.print("{s}{s}: ", .{ indent, e.key });
    for (e.values, 0..) |v, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", v });
    try w.writeByte('\n');
}

fn writeKeyed(arena: std.mem.Allocator, w: *std.Io.Writer, atlas: Atlas) !void {
    for (atlas.header) |e| try writeEntry(w, "", e);
    for (atlas.pages, 0..) |page, p| {
        if (p > 0 or atlas.header.len > 0) try w.writeByte('\n');
        try w.print("{s}\n", .{page.section.name});
        for (page.section.entries) |e| try writeEntry(w, "\t", e);
        for (page.regions) |section| {
            const r = try regionOf(arena, section);
            try w.print("{s}\n\tbounds: {d}, {d}, {d}, {d}\n", .{ section.name, r.x, r.y, r.width, r.height });
            if (isStripped(r)) {
                try w.print("\toffsets: {d}, {d}, {d}, {d}\n", .{ r.offset_x, r.offset_y, r.original_width, r.original_height });
            }
            if (r.degrees != 0) try w.print("\trotate: {d}\n", .{r.degrees});
            if (r.index != -1) try w.print("\tindex: {d}\n", .{r.index});
            for (r.custom) |e| try writeEntry(w, "\t", e);
        }
    }
}

fn writeLegacy(arena: std.mem.Allocator, w: *std.Io.Writer, atlas: Atlas, minor: u16, report: *Report) !void {
    const degrees = minor == 8;
    for (atlas.header) |e| try lose(report, .@"atlas.header.dropped", e.key, "header entry {s}", .{e.key});
    for (atlas.pages, 0..) |page, p| {
        const entries = page.section.entries;
        if (p > 0) try w.writeByte('\n');
        const size = if (find(entries, "size")) |e| try ints(2, e) else [2]i32{ 0, 0 };
        try w.print("{s}\nsize: {d},{d}\n", .{ page.section.name, size[0], size[1] });
        try w.print("format: {s}\n", .{if (find(entries, "format")) |e| if (e.values.len > 0) e.values[0] else "" else "RGBA8888"});
        if (find(entries, "filter")) |e| {
            if (e.values.len < 2) return error.Malformed;
            try w.print("filter: {s},{s}\n", .{ e.values[0], e.values[1] });
        } else try w.writeAll("filter: Nearest,Nearest\n");
        const repeat = if (find(entries, "repeat")) |e| if (e.values.len > 0) e.values[0] else "" else "";
        const u = std.mem.indexOfScalar(u8, repeat, 'x') != null;
        const v = std.mem.indexOfScalar(u8, repeat, 'y') != null;
        try w.print("repeat: {s}\n", .{if (u and v) "xy" else if (u) "x" else if (v) "y" else "none"});
        for (entries) |e| {
            if (std.mem.eql(u8, e.key, "pma")) {
                if (e.values.len > 0 and std.mem.eql(u8, e.values[0], "true")) {
                    try lose(report, .@"atlas.pma.dropped", try path(arena, "pages", page.section.name, e.key), "premultiplied alpha flag", .{});
                }
            } else if (!isPageKey(e.key)) {
                try lose(report, .@"atlas.page.dropped", try path(arena, "pages", page.section.name, e.key), "page entry {s}", .{e.key});
            }
        }

        for (page.regions) |section| {
            const r = try regionOf(arena, section);
            try w.print("{s}\n", .{section.name});
            switch (r.degrees) {
                0 => try w.writeAll("  rotate: false\n"),
                90 => try w.writeAll("  rotate: true\n"),
                else => if (degrees) try w.print("  rotate: {d}\n", .{r.degrees}) else {
                    try lose(report, .@"atlas.rotate.dropped", try path(arena, "regions", section.name, "rotate"), "rotation {d}", .{r.degrees});
                    try w.writeAll("  rotate: false\n");
                },
            }
            // 3.7 fixed mesh UVs of stripped regions
            if (minor <= 6 and isStripped(r)) {
                try lose(report, .@"atlas.strip.approximated", try path(arena, "regions", section.name, "offsets"), "stripped whitespace", .{});
            }
            try w.print("  xy: {d}, {d}\n  size: {d}, {d}\n", .{ r.x, r.y, r.width, r.height });
            // 3.8 reads split and pad by position and only four values
            const split = find(r.custom, "split");
            const has_split = if (split) |e| e.values.len == 4 else false;
            for (r.custom) |e| {
                const kept = e.values.len == 4 and (std.mem.eql(u8, e.key, "split") or std.mem.eql(u8, e.key, "pad") and has_split);
                if (!kept) try lose(report, .@"atlas.values.dropped", try path(arena, "regions", section.name, e.key), "region values {s}", .{e.key});
            }
            if (has_split) {
                try writeEntry(w, "  ", split.?);
                if (find(r.custom, "pad")) |pad| if (pad.values.len == 4) try writeEntry(w, "  ", pad);
            }
            try w.print("  orig: {d}, {d}\n  offset: {d}, {d}\n  index: {d}\n", .{
                r.original_width,
                r.original_height,
                r.offset_x,
                r.offset_y,
                r.index,
            });
        }
    }
}

fn path(arena: std.mem.Allocator, list: []const u8, name: []const u8, key: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.{s}.{s}", .{ list, name, key });
}

fn lose(report: *Report, code: Report.Code, where: []const u8, comptime fmt: []const u8, args: anytype) Error!void {
    try report.add(.{
        .code = code,
        .step = "",
        .path = where,
        .message = try std.fmt.allocPrint(report.arena, fmt, args),
    });
}

const keyed =
    "spineboy.png\n" ++
    "\tsize: 1024, 256\n" ++
    "\tfilter: Linear, Linear\n" ++
    "\tpma: true\n" ++
    "\tscale: 0.5\n" ++
    "eye\n" ++
    "\tbounds: 186, 17, 45, 45\n" ++
    "\trotate: 90\n" ++
    "patch\n" ++
    "\tbounds: 1, 2, 30, 40\n" ++
    "\toffsets: 1, 2, 32, 44\n" ++
    "\tsplit: 1, 2, 3, 4\n" ++
    "\tpad: 5, 6, 7, 8\n" ++
    "\tindex: 3\n" ++
    "\n";

test "keyed to legacy" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    const legacy = try convert(arena.allocator(), keyed, Version.parse("3.8").?, &report);
    try std.testing.expectEqualStrings(
        \\spineboy.png
        \\size: 1024,256
        \\format: RGBA8888
        \\filter: Linear,Linear
        \\repeat: none
        \\eye
        \\  rotate: true
        \\  xy: 186, 17
        \\  size: 45, 45
        \\  orig: 45, 45
        \\  offset: 0, 0
        \\  index: -1
        \\patch
        \\  rotate: false
        \\  xy: 1, 2
        \\  size: 30, 40
        \\  split: 1, 2, 3, 4
        \\  pad: 5, 6, 7, 8
        \\  orig: 32, 44
        \\  offset: 1, 2
        \\  index: 3
        \\
    , legacy);
    try std.testing.expectEqual(2, report.entries.items.len);
    try std.testing.expectEqual(.@"atlas.pma.dropped", report.entries.items[0].code);
    try std.testing.expectEqual(.@"atlas.page.dropped", report.entries.items[1].code);

    report.entries.clearRetainingCapacity();
    const back = try convert(arena.allocator(), legacy, Version.parse("4.3").?, &report);
    try std.testing.expectEqual(0, report.entries.items.len);
    try std.testing.expect(std.mem.indexOf(u8, back, "\tbounds: 1, 2, 30, 40\n\toffsets: 1, 2, 32, 44\n\tindex: 3\n\tsplit: 1, 2, 3, 4\n") != null);
}

test "malformed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    const v = Version.parse("3.8").?;
    try std.testing.expectError(error.Malformed, convert(arena.allocator(), "", v, &report));
    try std.testing.expectError(error.Malformed, convert(arena.allocator(), "a.png\nsize: 1\n", v, &report));
    try std.testing.expectError(error.Malformed, convert(arena.allocator(), "a.png\nr\nbounds: 1, x, 2, 3\n", v, &report));
    try std.testing.expectError(error.UnsupportedVersion, convert(arena.allocator(), keyed, Version.parse("3.4").?, &report));
}

test "rotation in 3.7" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    const data = "a.png\n\tsize: 8, 8\nr\n\tbounds: 0, 0, 4, 4\n\trotate: 180\n";
    const old = try convert(arena.allocator(), data, Version.parse("3.7").?, &report);
    try std.testing.expect(std.mem.indexOf(u8, old, "  rotate: false\n") != null);
    try std.testing.expectEqual(.@"atlas.rotate.dropped", report.entries.items[0].code);
    report.entries.clearRetainingCapacity();
    const kept = try convert(arena.allocator(), data, Version.parse("3.8").?, &report);
    try std.testing.expect(std.mem.indexOf(u8, kept, "  rotate: 180\n") != null);
    try std.testing.expectEqual(0, report.entries.items.len);
}

test "rotation before 3.8" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    const turned = "a.png\n\tsize: 2, 2\nr\n\tbounds: 0, 0, 1, 1\n\trotate: 270\n";
    const kept = try convert(arena.allocator(), turned, Version.parse("3.8").?, &report);
    try std.testing.expect(std.mem.indexOf(u8, kept, "  rotate: 270\n") != null);
    try std.testing.expectEqual(0, report.entries.items.len);
    const dropped = try convert(arena.allocator(), turned, Version.parse("3.6").?, &report);
    try std.testing.expect(std.mem.indexOf(u8, dropped, "  rotate: false\n") != null);
    try std.testing.expectEqual(.@"atlas.rotate.dropped", report.entries.items[0].code);
    report.entries.clearRetainingCapacity();
    const oldest = try convert(arena.allocator(), turned, Version.parse("3.5").?, &report);
    try std.testing.expect(std.mem.indexOf(u8, oldest, "  rotate: false\n") != null);
    try std.testing.expectEqual(.@"atlas.rotate.dropped", report.entries.items[0].code);
}

test "stripped whitespace before 3.7" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    const stripped = "a.png\n\tsize: 8, 8\nr\n\tbounds: 0, 0, 4, 4\n\toffsets: 1, 0, 6, 4\n";
    _ = try convert(arena.allocator(), stripped, Version.parse("3.7").?, &report);
    try std.testing.expectEqual(0, report.entries.items.len);
    for ([_][]const u8{ "3.6", "3.5" }) |v| {
        _ = try convert(arena.allocator(), stripped, Version.parse(v).?, &report);
        try std.testing.expectEqual(1, report.entries.items.len);
        try std.testing.expectEqual(.@"atlas.strip.approximated", report.entries.items[0].code);
        try std.testing.expectEqualStrings("regions.r.offsets", report.entries.items[0].path);
        report.entries.clearRetainingCapacity();
    }
}

test "byte order mark" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    const plain = try convert(arena.allocator(), keyed, Version.parse("3.8").?, &report);
    const marked = try convert(arena.allocator(), "\xEF\xBB\xBF" ++ keyed, Version.parse("3.8").?, &report);
    try std.testing.expectEqualStrings(plain, marked);
    try std.testing.expectEqual(4, report.entries.items.len);
}

test "null target copies the input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    const kept = try convert(arena.allocator(), keyed, null, &report);
    try std.testing.expectEqualStrings(keyed, kept);
    try std.testing.expect(kept.ptr != keyed.ptr);
}

const std = @import("std");
const Version = @import("Version.zig");
const Format = @import("detect.zig").Format;

const Document = @This();

version: Version,
origin: Format,
/// Tree in the JSON schema of version
root: std.json.Value,

pub const Flags = struct {
    /// Allows data changes the target runtime evaluates identically
    rewrite: bool = false,
    /// Set by migrate.run when the run reaches 4.3 sliders
    slider: bool = false,
    /// Target minor, set by migrate.run for the steps
    target: ?Version.Minor = null,
    /// Atlas text of the skeleton for region whitespace
    atlas: ?[]const u8 = null,
};

/// Keeps skeleton.spine equal to version
pub fn setVersion(doc: *Document, arena: std.mem.Allocator, version: Version) !void {
    doc.version = version;
    const skeleton = doc.root.object.getPtr("skeleton") orelse return;
    if (skeleton.* != .object) return;
    try skeleton.object.put(arena, "spine", .{ .string = try arena.dupe(u8, version.text()) });
}

test setVersion {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"skeleton\":{\"spine\":\"4.2.43\"}}", .{});
    var doc: Document = .{ .version = Version.parse("4.2.43").?, .origin = .json, .root = root };
    try doc.setVersion(a, Version.parse("4.3.39").?);
    try std.testing.expectEqualStrings("4.3.39", doc.root.object.get("skeleton").?.object.get("spine").?.string);
}

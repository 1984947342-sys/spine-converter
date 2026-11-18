const std = @import("std");

const Version = @This();

pub const max_len = 31;

major: u16 = 0,
minor: u16 = 0,
patch: u16 = 0,
text_buf: [max_len]u8 = undefined,
text_len: u8 = 0,

pub fn text(v: *const Version) []const u8 {
    return v.text_buf[0..v.text_len];
}

/// Accepts editor suffixes like 3.8.75-beta
pub fn parse(s: []const u8) ?Version {
    var v = unnumbered(s) orelse return null;
    var i: usize = 0;
    v.major = number(s, &i) orelse return null;
    if (i >= s.len or s[i] != '.') return null;
    i += 1;
    v.minor = number(s, &i) orelse return null;
    if (i < s.len and s[i] == '.') {
        i += 1;
        v.patch = number(s, &i) orelse 0;
    }
    return v;
}

/// Editor dev builds write Dev
pub fn unnumbered(s: []const u8) ?Version {
    if (s.len == 0 or s.len > max_len) return null;
    for (s) |c| if (!std.ascii.isPrint(c)) return null;
    var v: Version = .{};
    @memcpy(v.text_buf[0..s.len], s);
    v.text_len = @intCast(s.len);
    return v;
}

pub const Minor = struct { major: u16, minor: u16 };

pub fn isBeta(v: Version) bool {
    return std.mem.endsWith(u8, v.text(), "-beta");
}

/// 4.x release patches restart after the betas
pub fn order(a: Version, b: Version) std.math.Order {
    return std.math.order(rank(a), rank(b));
}

fn rank(v: Version) u64 {
    return @as(u64, v.major) << 48 | @as(u64, v.minor) << 32 | @as(u64, @intFromBool(!v.isBeta())) << 16 | v.patch;
}

pub fn ofRoot(root: std.json.Value) ?Version {
    if (root != .object) return null;
    const skeleton = root.object.get("skeleton") orelse return null;
    if (skeleton != .object) return null;
    const spine = skeleton.object.get("spine") orelse return null;
    if (spine != .string) return null;
    return parse(spine.string) orelse unnumbered(spine.string);
}

pub const Editor = enum { old, unsure, new };

pub const Change = enum {
    offset_reflect_35,
    no_rotation_35,
    reflect_order_36,
    zero_bone_nan_36,
    zero_bone_36,
    path_epsilon_36,
    clip_vertices_36,
    reflect_37,
    local_mix_37,
    path_start_37,
    ik_solve_3825,
    ik_frames_3825,
    ik_world_38,
    order_40,
    stretch_40,
    relative_scale_40,
    zero_bone_40,
    sequence_mode_41,
    sequence_linked_41,
    mix_scale_y_41,
    ik_singular_41,
    local_wrap_42,
    reset_43,
    volume_43,
    derive_43,
    singular_43,
    slider_linked_43,
    json_mix_43,
};

pub const Row = struct { change: Change, old_through: []const u8, new_from: []const u8 };

/// Rows follow the order of Change
pub const rows = [_]Row{
    .{ .change = .offset_reflect_35, .old_through = "3.5.08-beta", .new_from = "3.5.09-beta" },
    .{ .change = .no_rotation_35, .old_through = "3.5.03-beta", .new_from = "3.5.04-beta" },
    .{ .change = .reflect_order_36, .old_through = "3.6.37", .new_from = "3.6.38" },
    .{ .change = .zero_bone_nan_36, .old_through = "3.6.38", .new_from = "3.6.39" },
    .{ .change = .zero_bone_36, .old_through = "3.6.45", .new_from = "3.6.46" },
    .{ .change = .path_epsilon_36, .old_through = "3.6.45", .new_from = "3.6.46" },
    .{ .change = .clip_vertices_36, .old_through = "3.6.32", .new_from = "3.6.35" },
    .{ .change = .reflect_37, .old_through = "3.7.71-beta", .new_from = "3.7.72-beta" },
    .{ .change = .local_mix_37, .old_through = "3.7.73-beta", .new_from = "3.7.74-beta" },
    .{ .change = .path_start_37, .old_through = "3.7.42-beta", .new_from = "3.7.43-beta" },
    .{ .change = .ik_solve_3825, .old_through = "3.8.25-beta", .new_from = "3.8.26-beta" },
    .{ .change = .ik_frames_3825, .old_through = "3.8.25-beta", .new_from = "3.8.26-beta" },
    .{ .change = .ik_world_38, .old_through = "3.8.79", .new_from = "3.8.81" },
    .{ .change = .order_40, .old_through = "4.0.75-beta", .new_from = "4.0.76-beta" },
    .{ .change = .stretch_40, .old_through = "4.0.72-beta", .new_from = "4.0.73-beta" },
    .{ .change = .relative_scale_40, .old_through = "4.0.25", .new_from = "4.0.27" },
    .{ .change = .zero_bone_40, .old_through = "4.0.31-beta", .new_from = "4.0.34-beta" },
    .{ .change = .sequence_mode_41, .old_through = "4.1.09-beta", .new_from = "4.1.10-beta" },
    .{ .change = .sequence_linked_41, .old_through = "4.1.26-beta", .new_from = "4.1.27-beta" },
    .{ .change = .mix_scale_y_41, .old_through = "4.1.17", .new_from = "4.1.18" },
    .{ .change = .ik_singular_41, .old_through = "4.1.17", .new_from = "4.1.20" },
    .{ .change = .local_wrap_42, .old_through = "4.2.59-beta", .new_from = "4.2.60-beta" },
    .{ .change = .reset_43, .old_through = "4.3.17", .new_from = "4.3.18" },
    .{ .change = .volume_43, .old_through = "4.3.01", .new_from = "4.3.02" },
    .{ .change = .derive_43, .old_through = "4.3.01", .new_from = "4.3.03" },
    .{ .change = .singular_43, .old_through = "4.3.02", .new_from = "4.3.03" },
    .{ .change = .slider_linked_43, .old_through = "4.3.23", .new_from = "4.3.24" },
    .{ .change = .json_mix_43, .old_through = "4.3.23", .new_from = "4.3.24" },
};

const bounds = blk: {
    @setEvalBranchQuota(10000);
    var parsed: [rows.len][2]Version = undefined;
    for (rows, &parsed) |r, *b| b.* = .{ parse(r.old_through).?, parse(r.new_from).? };
    break :blk parsed;
};

/// Every editor dated change of its minor reads the final semantics
pub fn settled(v: Version) bool {
    for (0..rows.len) |i| if (editor(v, @fromBackingInt(@intCast(i))) != .new) return false;
    return true;
}

pub fn editor(v: Version, change: Change) Editor {
    const old, const new = bounds[@backingInt(change)];
    // another minor already wrote final semantics
    if (v.major != old.major or v.minor != old.minor) return .new;
    if (std.mem.count(u8, v.text(), ".") < 2) return .unsure;
    // cross minor output of the converter, editors write two digit patches
    if (std.mem.endsWith(u8, v.text(), ".0")) return .new;
    if (order(v, old) != .gt) return .old;
    if (order(v, new) != .lt) return .new;
    return .unsure;
}

fn number(s: []const u8, i: *usize) ?u16 {
    const start = i.*;
    while (i.* < s.len and std.ascii.isDigit(s[i.*])) i.* += 1;
    if (i.* == start) return null;
    return std.fmt.parseInt(u16, s[start..i.*], 10) catch null;
}

test parse {
    const v = parse("3.8.75-beta").?;
    try std.testing.expectEqual(3, v.major);
    try std.testing.expectEqual(8, v.minor);
    try std.testing.expectEqual(75, v.patch);
    try std.testing.expectEqualStrings("3.8.75-beta", v.text());
    try std.testing.expectEqual(0, parse("4.2").?.patch);
    try std.testing.expect(parse("x.2") == null);
    try std.testing.expect(parse("4") == null);
}

test unnumbered {
    try std.testing.expectEqual(0, unnumbered("Dev").?.major);
    try std.testing.expect(unnumbered("\x01\x02") == null);
}

test isBeta {
    try std.testing.expect(parse("4.3.75-beta").?.isBeta());
    try std.testing.expect(!parse("4.3.17").?.isBeta());
}

test order {
    try std.testing.expectEqual(.lt, order(parse("4.3.75-beta").?, parse("4.3.01").?));
    try std.testing.expectEqual(.lt, order(parse("3.8.25-beta").?, parse("3.8.75").?));
    try std.testing.expectEqual(.gt, order(parse("4.0.25").?, parse("4.0.27-beta").?));
    try std.testing.expectEqual(.lt, order(parse("3.8.99").?, parse("4.0.01-beta").?));
    try std.testing.expectEqual(.lt, order(unnumbered("Dev").?, parse("3.5.03-beta").?));
    try std.testing.expectEqual(.eq, order(parse("3.8.79").?, parse("3.8.79").?));
}

test ofRoot {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"skeleton\":{\"spine\":\"3.8.75\"}}", .{});
    try std.testing.expectEqualStrings("3.8.75", ofRoot(root).?.text());
    const dev = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"skeleton\":{\"spine\":\"Dev\"}}", .{});
    try std.testing.expectEqualStrings("Dev", ofRoot(dev).?.text());
    try std.testing.expect(ofRoot(.null) == null);
}

test rows {
    try std.testing.expectEqual(std.enums.values(Change).len, rows.len);
    for (rows, bounds, 0..) |r, b, i| {
        try std.testing.expectEqual(@as(Change, @fromBackingInt(@intCast(i))), r.change);
        try std.testing.expectEqual(.lt, order(b[0], b[1]));
        try std.testing.expectEqual(b[0].major, b[1].major);
        try std.testing.expectEqual(b[0].minor, b[1].minor);
    }
}

test editor {
    const cases = [_]struct { []const u8, Change, Editor }{
        .{ "3.8.55", .ik_world_38, .old },
        .{ "3.8.75", .ik_world_38, .old },
        .{ "3.8.79", .ik_world_38, .old },
        .{ "3.8.80", .ik_world_38, .unsure },
        .{ "3.8.81", .ik_world_38, .new },
        .{ "3.8.99", .ik_world_38, .new },
        .{ "3.8", .ik_world_38, .unsure },
        .{ "4.0.31", .ik_world_38, .new },
        .{ "3.7.90", .ik_world_38, .new },
        .{ "Dev", .ik_world_38, .new },
        .{ "4.0.25", .relative_scale_40, .old },
        .{ "4.0.26", .relative_scale_40, .unsure },
        .{ "4.0.27", .relative_scale_40, .new },
        .{ "4.0.75-beta", .order_40, .old },
        .{ "4.0.76-beta", .order_40, .new },
        .{ "4.0.02", .order_40, .new },
        .{ "4.3.75-beta", .reset_43, .old },
        .{ "4.3.17", .reset_43, .old },
        .{ "4.3.18", .reset_43, .new },
        .{ "4.3.0", .reset_43, .new },
        .{ "4.0.0", .order_40, .new },
        .{ "4.1.19", .ik_singular_41, .unsure },
        .{ "3.5.03-beta", .no_rotation_35, .old },
        .{ "3.5.51", .no_rotation_35, .new },
        .{ "3.6.32", .clip_vertices_36, .old },
        .{ "3.6.33", .clip_vertices_36, .unsure },
        .{ "3.6.35", .clip_vertices_36, .new },
    };
    for (cases) |c| {
        const v = parse(c[0]) orelse unnumbered(c[0]).?;
        try std.testing.expectEqual(c[2], editor(v, c[1]));
    }
}

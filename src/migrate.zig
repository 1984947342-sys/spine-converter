//! Adjacent version steps applied in order

const std = @import("std");
const Value = std.json.Value;
const Document = @import("Document.zig");
const Report = @import("Report.zig");
const Version = @import("Version.zig");
const edit = @import("edit.zig");

pub const Error = error{ UnsupportedVersion, Malformed, OutOfMemory };

const Minor = Version.Minor;

const Step = struct {
    lower: Minor,
    upper: Minor,
    up: *const fn (arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) error{ Malformed, OutOfMemory }!void,
    down: *const fn (arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) error{ Malformed, OutOfMemory }!void,
    /// Runs for exports of upper and the lower of the first step
    early: *const fn (arena: std.mem.Allocator, root: *Value, report: *Report, target: Minor, flags: Flags) error{ Malformed, OutOfMemory }!void,
};

const steps = [_]Step{
    step(.{ .major = 3, .minor = 5 }, .{ .major = 3, .minor = 6 }, @import("migrate/v3_5_v3_6.zig")),
    step(.{ .major = 3, .minor = 6 }, .{ .major = 3, .minor = 7 }, @import("migrate/v3_6_v3_7.zig")),
    step(.{ .major = 3, .minor = 7 }, .{ .major = 3, .minor = 8 }, @import("migrate/v3_7_v3_8.zig")),
    step(.{ .major = 3, .minor = 8 }, .{ .major = 4, .minor = 0 }, @import("migrate/v3_8_v4_0.zig")),
    step(.{ .major = 4, .minor = 0 }, .{ .major = 4, .minor = 1 }, @import("migrate/v4_0_v4_1.zig")),
    step(.{ .major = 4, .minor = 1 }, .{ .major = 4, .minor = 2 }, @import("migrate/v4_1_v4_2.zig")),
    step(.{ .major = 4, .minor = 2 }, .{ .major = 4, .minor = 3 }, @import("migrate/v4_2_v4_3.zig")),
};

fn step(lower: Minor, upper: Minor, comptime module: type) Step {
    return .{ .lower = lower, .upper = upper, .up = module.up, .down = module.down, .early = module.early };
}

pub const Flags = Document.Flags;

pub const latest = steps[steps.len - 1].upper;

/// Loader quirks of JSON written for another loader
pub fn checkJson(arena: std.mem.Allocator, doc: *Document, report: *Report) Error!void {
    if (std.meta.eql(minorOf(doc.version), Minor{ .major = 4, .minor = 0 })) try @import("migrate/v3_8_v4_0.zig").jsonShear(arena, &doc.root, report);
    if (doc.version.major == 3 and doc.version.minor <= 7) try @import("migrate/v3_7_v3_8.zig").jsonAngles(arena, &doc.root);
}

/// Patchless targets keep the source patch only within a minor
pub fn run(arena: std.mem.Allocator, doc: *Document, target: Version, flags: Flags, report: *Report) Error!void {
    const source = minorOf(doc.version);
    const want = minorOf(target);
    // a minor between rows would step back and forth
    if (!std.meta.eql(source, want) and !known(want)) return error.UnsupportedVersion;
    const owner = for (steps) |s| {
        if (std.meta.eql(s.upper, source)) break s;
    } else if (std.meta.eql(steps[0].lower, source)) steps[0] else null;
    if (owner) |s| if (order(source, want) != .gt) try s.early(arena, &doc.root, report, want, flags);
    var step_flags = flags;
    step_flags.slider = order(want, latest) != .lt;
    step_flags.target = want;
    const before = try durations(arena, doc.root);
    var at = source;
    while (order(at, want) != .eq) {
        const upward = order(at, want) == .lt;
        const s = for (steps) |s| {
            if (std.meta.eql(if (upward) s.lower else s.upper, at)) break s;
        } else return error.UnsupportedVersion;
        if (upward) try s.up(arena, &doc.root, report, step_flags) else try s.down(arena, &doc.root, report, step_flags);
        at = if (upward) s.upper else s.lower;
    }
    try checkDurations(arena, before, doc.root, source, want, report);
    if (std.mem.count(u8, target.text(), ".") >= 2) return doc.setVersion(arena, target);
    // an export before a dated change gets final semantics and loses its patch
    if (std.meta.eql(source, want) and Version.settled(doc.version)) return;
    var buf: [Version.max_len]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}.{d}.0", .{ want.major, want.minor }) catch unreachable;
    try doc.setVersion(arena, Version.parse(text).?);
}

/// Last key time of every animation
fn durations(arena: std.mem.Allocator, root: Value) Error!std.StringArrayHashMapUnmanaged(f64) {
    var out: std.StringArrayHashMapUnmanaged(f64) = .empty;
    const animations = (if (root == .object) root.object.get("animations") else null) orelse return out;
    if (animations != .object) return out;
    for (animations.object.keys(), animations.object.values()) |name, animation| try out.put(arena, name, edit.lastTime(animation));
    return out;
}

/// Dropped timelines can end an animation earlier
fn checkDurations(arena: std.mem.Allocator, before: std.StringArrayHashMapUnmanaged(f64), root: Value, source: Minor, want: Minor, report: *Report) Error!void {
    const after = try durations(arena, root);
    for (before.keys(), before.values()) |name, old| {
        const new = after.get(name) orelse continue;
        if (old - new <= 1e-6) continue;
        try report.add(.{
            .code = .@"animation.duration.approximated",
            .step = try std.fmt.allocPrint(arena, "{d}.{d}-{d}.{d}", .{ source.major, source.minor, want.major, want.minor }),
            .path = try std.fmt.allocPrint(arena, "animations.{s}", .{name}),
            .message = try std.fmt.allocPrint(arena, "ends at {d} instead of {d}", .{ new, old }),
        });
    }
}

fn known(m: Minor) bool {
    for (steps) |s| if (std.meta.eql(s.lower, m) or std.meta.eql(s.upper, m)) return true;
    return false;
}

fn minorOf(v: Version) Minor {
    return .{ .major = v.major, .minor = v.minor };
}

fn order(a: Minor, b: Minor) std.math.Order {
    return std.math.order(@as(u32, a.major) << 16 | a.minor, @as(u32, b.major) << 16 | b.minor);
}

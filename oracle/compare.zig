const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const max_reported = 10;
/// Rig animations and trailing bones the converter adds, see helper_prefix
const helper_prefix = "spine-converter/";

/// Line format written by oracle/dump_*.cpp
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(arena);
    var args: std.ArrayList([]const u8) = .empty;
    var clip = true;
    var clip_region = false;
    var dark = true;
    var dropped = false;
    var excuse_path: ?[]const u8 = null;
    var next: usize = 0;
    while (next < all_args.len) : (next += 1) {
        const arg = all_args[next];
        if (std.mem.eql(u8, arg, "--no-clip")) {
            clip = false;
        } else if (std.mem.eql(u8, arg, "--clip-region")) {
            clip_region = true;
        } else if (std.mem.eql(u8, arg, "--no-dark")) {
            dark = false;
        } else if (std.mem.eql(u8, arg, "--no-dropped")) {
            dropped = true;
        } else if (std.mem.eql(u8, arg, "--excuse") and next + 1 < all_args.len) {
            next += 1;
            excuse_path = all_args[next];
        } else try args.append(arena, arg);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    if (args.items.len < 3 or args.items.len > 6) {
        try out.writeAll("usage: pose-compare [--no-clip | --clip-region] [--no-dark] [--no-dropped] [--excuse <scope>] <expected.jsonl> <actual.jsonl> [abs tolerance] [rel tolerance] [color tolerance]\n");
        return 2;
    }
    // samples parse one pair at a time, a parsed dump takes many times its size
    const expected = try readLines(io, arena, args.items[1]);
    const actual = try readLines(io, arena, args.items[2]);
    if (expected.len == 0 or actual.len == 0) {
        try out.writeAll("empty dump\n");
        return 1;
    }
    const names = try std.json.parseFromSliceLeaky(Value, arena, expected[0], .{});
    const actual_names = try std.json.parseFromSliceLeaky(Value, arena, actual[0], .{});
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();

    var c: Comparison = .{
        .out = out,
        .gpa = arena,
        .abs_tolerance = if (args.items.len > 3) try std.fmt.parseFloat(f64, args.items[3]) else 1e-3,
        .rel_tolerance = if (args.items.len > 4) try std.fmt.parseFloat(f64, args.items[4]) else 1e-5,
        .color_tolerance = if (args.items.len > 5) try std.fmt.parseFloat(f64, args.items[5]) else 2e-3,
        .clip = clip,
        .clip_region = clip_region,
        .dark = dark,
        .dropped = dropped,
        .names = names,
    };
    const excuse: Excuse = if (excuse_path) |path| try .read(io, arena, path, names) else .{};
    c.line = 1;
    try c.boneNames(names, actual_names);
    try c.exact(names, actual_names, "slots");
    try c.exact(names, actual_names, "skins");
    // samples pair in order within a skin and animation, so a shorter animation shifts no other
    var groups: std.StringArrayHashMapUnmanaged([2]std.ArrayList(usize)) = .empty;
    for ([_][]const []const u8{ expected, actual }, 0..) |lines, side| {
        for (lines[1..], 1..) |line, i| {
            defer _ = scratch.reset(.retain_capacity);
            const sample = try std.json.parseFromSliceLeaky(struct { skin: []const u8, animation: []const u8 }, scratch.allocator(), line, .{ .ignore_unknown_fields = true });
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ sample.skin, sample.animation });
            const entry = try groups.getOrPutValue(arena, key, .{ .empty, .empty });
            try entry.value_ptr[side].append(arena, i);
        }
    }
    for (groups.keys(), groups.values()) |key, group| {
        const animation = key[std.mem.indexOfScalar(u8, key, 0).? + 1 ..];
        const es = group[0].items;
        const as = group[1].items;
        if (es.len == 0 and std.mem.startsWith(u8, animation, helper_prefix)) continue;
        const paired = @min(es.len, as.len);
        for (es[0..paired], as[0..paired]) |ei, ai| {
            defer _ = scratch.reset(.retain_capacity);
            c.line = ei + 1;
            const e = try std.json.parseFromSliceLeaky(Value, scratch.allocator(), expected[ei], .{});
            const a = try std.json.parseFromSliceLeaky(Value, scratch.allocator(), actual[ai], .{});
            try c.sample(&excuse, e, a);
        }
        c.context = animation;
        c.excusing = paired > 0 and excuse.duration(animation);
        for (es[paired..]) |ei| {
            c.line = ei + 1;
            try c.mismatch("{s} missing from actual", .{"sample"});
        }
        for (as[paired..]) |ai| {
            c.line = ai + 1;
            try c.mismatch("{s} missing from expected", .{"sample"});
        }
        c.context = "";
        c.excusing = false;
    }
    for (c.by_key.keys(), c.by_key.values()) |key, count| try out.print("  {s}: {d}\n", .{ key, count });
    try out.print("{d} samples, {d} mismatches, max deviation {e}\n", .{ expected.len -| 1, c.mismatches, c.max_deviation });
    if (excuse_path != null) try out.print("excused {d}\n", .{c.excused});
    return if (c.mismatches == 0) 0 else 1;
}

fn readLines(io: Io, arena: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const data = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, data, '\n');
    while (it.next()) |line| try lines.append(arena, line);
    return lines.items;
}

const Comparison = struct {
    out: *Io.Writer,
    line: usize = 0,
    context: []const u8 = "",
    abs_tolerance: f64,
    rel_tolerance: f64,
    /// Default is half an 8-bit channel step
    color_tolerance: f64,
    mismatches: usize = 0,
    excusing: bool = false,
    excused: usize = 0,
    max_deviation: f64 = 0,
    gpa: std.mem.Allocator,
    by_key: std.StringArrayHashMapUnmanaged(usize) = .empty,
    clip: bool,
    clip_region: bool,
    dark: bool,
    dropped: bool,
    /// First line of the expected dump
    names: Value,
    /// Trailing helper bones of the actual skeleton
    helpers: usize = 0,

    fn sample(c: *Comparison, excuse: *const Excuse, e: Value, a: Value) !void {
        const skin = e.object.get("skin").?.string;
        const animation = e.object.get("animation").?.string;
        c.excusing = excuse.all(animation);
        try c.events(e.object.get("events") orelse .null, a.object.get("events") orelse .null);
        c.excusing = false;
        try c.numbers(e.object.get("time").?, a.object.get("time").?, "time");
        const eb = e.object.get("bones").?.array.items;
        const all = a.object.get("bones").?.array.items;
        const ab = all[0..all.len -| c.helpers];
        if (eb.len != ab.len) try c.mismatch("bone count {d} vs {d}", .{ eb.len, ab.len });
        const bone_names = c.names.object.get("bones").?.array.items;
        for (eb[0..@min(eb.len, ab.len)], ab[0..@min(eb.len, ab.len)], 0..) |bone_e, bone_a, i| {
            c.context = if (i < bone_names.len) bone_names[i].string else "";
            c.excusing = excuse.bone(animation, i);
            try c.numbers(bone_e, bone_a, "bones");
        }
        c.context = "";
        c.excusing = excuse.order(animation);
        try c.exact(e, a, "drawOrder");
        c.excusing = false;
        const es = e.object.get("slots").?.array.items;
        const as = a.object.get("slots").?.array.items;
        if (es.len != as.len) return c.mismatch("slot count {d} vs {d}", .{ es.len, as.len });
        const slot_names = c.names.object.get("slots").?.array.items;
        for (es, as, 0..) |slot_e, slot_a, i| {
            c.context = if (i < slot_names.len) slot_names[i].string else "";
            c.excusing = excuse.slot(animation, skin, i);
            // Dropped attachments draw nothing in the target
            if (c.dropped and slot_a.object.get("attachment").? == .null and slot_e.object.get("attachment").? != .null) continue;
            try c.exact(slot_e, slot_a, "attachment");
            if (slot_e.object.get("sequence") != null and slot_a.object.get("sequence") != null) try c.exact(slot_e, slot_a, "sequence");
            try c.numbers(slot_e.object.get("color").?, slot_a.object.get("color").?, "color");
            if (c.dark) try c.numbers(slot_e.object.get("dark").?, slot_a.object.get("dark").?, "dark");
            const clipping = slot_e.object.get("clip").? != .null;
            if (!c.clip_region or !clipping) try c.numbers(slot_e.object.get("vertices").?, slot_a.object.get("vertices").?, "vertices");
            if (c.clip) try c.numbers(slot_e.object.get("clip").?, slot_a.object.get("clip").?, "clip");
        }
        c.context = "";
        c.excusing = false;
    }

    fn mismatch(c: *Comparison, comptime fmt: []const u8, args: anytype) !void {
        if (c.excusing) {
            c.excused += 1;
            return;
        }
        c.mismatches += 1;
        if (@hasField(@TypeOf(args), "0") and @TypeOf(args[0]) == []const u8) {
            const entry = try c.by_key.getOrPutValue(c.gpa, args[0], 0);
            entry.value_ptr.* += 1;
        }
        if (c.mismatches > max_reported) return;
        try c.out.print("line {d} {s}: " ++ fmt ++ "\n", .{ c.line, c.context } ++ args);
    }

    fn boneNames(c: *Comparison, e: Value, a: Value) !void {
        const expected = e.object.get("bones").?.array.items;
        const actual = a.object.get("bones").?.array.items;
        var n = actual.len;
        while (n > expected.len and std.mem.startsWith(u8, actual[n - 1].string, helper_prefix)) n -= 1;
        c.helpers = actual.len - n;
        if (n != expected.len) return c.mismatch("{s} differs", .{"bones"});
        for (expected, actual[0..n]) |x, y| if (!equal(x, y)) return c.mismatch("{s} differs", .{"bones"});
    }

    fn exact(c: *Comparison, e: Value, a: Value, key: []const u8) !void {
        const ev = e.object.get(key) orelse Value.null;
        const av = a.object.get(key) orelse Value.null;
        if (!equal(ev, av)) try c.mismatch("{s} differs", .{key});
    }

    /// Event is name int float string volume balance time audio, volume and balance only load with audio
    fn events(c: *Comparison, e: Value, a: Value) !void {
        if (e == .null or a == .null) {
            if (!equal(e, a)) try c.mismatch("{s} differ", .{"events"});
            return;
        }
        if (e.array.items.len != a.array.items.len) return c.mismatch("{s} count differs", .{"events"});
        for (e.array.items, a.array.items) |x, y| {
            for ([_]usize{ 0, 1, 3, 7 }) |i| {
                if (!equal(x.array.items[i], y.array.items[i])) try c.mismatch("{s} differ", .{"events"});
            }
            const audio = x.array.items[7].string.len > 0;
            for ([_]usize{ 2, 4, 5, 6 }) |i| {
                if (audio or i == 2 or i == 6) try c.numbers(x.array.items[i], y.array.items[i], "events");
            }
        }
    }

    fn numbers(c: *Comparison, e: Value, a: Value, key: []const u8) !void {
        switch (e) {
            .array => |ea| {
                if (a != .array or a.array.items.len != ea.items.len) return c.mismatch("{s} length differs", .{key});
                for (ea.items, a.array.items) |x, y| try c.numbers(x, y, key);
            },
            .null => if (a != .null) try c.mismatch("{s} null differs", .{key}),
            else => {
                const x = toFloat(e) orelse return c.mismatch("{s} not a number", .{key});
                const y = toFloat(a) orelse return c.mismatch("{s} not a number", .{key});
                const deviation = @abs(x - y);
                if (!c.excusing) c.max_deviation = @max(c.max_deviation, deviation);
                const color = std.mem.eql(u8, key, "color") or std.mem.eql(u8, key, "dark");
                const allowed = if (color) @min(c.abs_tolerance, c.color_tolerance) else c.abs_tolerance + c.rel_tolerance * @max(@abs(x), @abs(y));
                if (deviation > allowed) {
                    try c.mismatch("{s} {d} vs {d}", .{ key, x, y });
                }
            },
        }
    }
};

fn toFloat(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn equal(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .integer => |i| i == b.integer,
        .string => |s| std.mem.eql(u8, s, b.string),
        .array => |arr| arr.items.len == b.array.items.len and for (arr.items, b.array.items) |x, y| {
            if (!equal(x, y)) break false;
        } else true,
        else => false,
    };
}

/// Lines written by oracle/scope.zig, animation * matches every sample
const Excuse = struct {
    groups: std.StringHashMapUnmanaged(Group) = .empty,

    const Group = struct {
        bones: std.AutoHashMapUnmanaged(usize, void) = .empty,
        slots: std.AutoHashMapUnmanaged(usize, void) = .empty,
        skin_slots: std.ArrayList(struct { slot: usize, skin: []const u8 }) = .empty,
        order: bool = false,
        all: bool = false,
        duration: bool = false,
    };

    fn read(io: Io, arena: std.mem.Allocator, path: []const u8, names: Value) !Excuse {
        const data = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        var x: Excuse = .{};
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        while (lines.next()) |line| {
            var fields: [4][]const u8 = .{ "", "", "", "" };
            var count: usize = 0;
            var it = std.mem.splitScalar(u8, line, '\t');
            while (it.next()) |field| : (count += 1) {
                if (count < fields.len) fields[count] = field;
            }
            const kind = fields[0];
            const animation = if (std.mem.eql(u8, kind, "order") or std.mem.eql(u8, kind, "all") or std.mem.eql(u8, kind, "duration")) fields[1] else fields[2];
            const entry = try x.groups.getOrPutValue(arena, animation, .{});
            const g = entry.value_ptr;
            if (std.mem.eql(u8, kind, "all")) {
                g.all = true;
            } else if (std.mem.eql(u8, kind, "order")) {
                g.order = true;
            } else if (std.mem.eql(u8, kind, "duration")) {
                g.duration = true;
            } else if (std.mem.eql(u8, kind, "bone")) {
                if (find(names.object.get("bones").?, fields[1])) |i| try g.bones.put(arena, i, {});
            } else if (std.mem.eql(u8, kind, "slot")) {
                const i = find(names.object.get("slots").?, fields[1]) orelse continue;
                if (count > 3) try g.skin_slots.append(arena, .{ .slot = i, .skin = fields[3] }) else try g.slots.put(arena, i, {});
            }
        }
        return x;
    }

    fn find(list: Value, name: []const u8) ?usize {
        for (list.array.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.string, name)) return i;
        }
        return null;
    }

    fn lookup(x: *const Excuse, animation: []const u8) [2]?*Group {
        return .{ x.groups.getPtr(animation), x.groups.getPtr("*") };
    }

    fn all(x: *const Excuse, animation: []const u8) bool {
        for (x.lookup(animation)) |g| if (g != null and g.?.all) return true;
        return false;
    }

    fn order(x: *const Excuse, animation: []const u8) bool {
        for (x.lookup(animation)) |g| if (g != null and (g.?.all or g.?.order)) return true;
        return false;
    }

    /// Samples past the shorter end of the animation, never through *
    fn duration(x: *const Excuse, animation: []const u8) bool {
        const g = x.groups.getPtr(animation) orelse return false;
        return g.duration;
    }

    fn bone(x: *const Excuse, animation: []const u8, i: usize) bool {
        for (x.lookup(animation)) |g| if (g != null and (g.?.all or g.?.bones.contains(i))) return true;
        return false;
    }

    fn slot(x: *const Excuse, animation: []const u8, skin: []const u8, i: usize) bool {
        for (x.lookup(animation)) |group| {
            const g = group orelse continue;
            if (g.all or g.slots.contains(i)) return true;
            for (g.skin_slots.items) |s| {
                if (s.slot == i and std.mem.eql(u8, s.skin, skin)) return true;
            }
        }
        return false;
    }
};

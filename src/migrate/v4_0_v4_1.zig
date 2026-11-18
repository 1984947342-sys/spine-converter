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

//! Spine 4.0 and 4.1 JSON, mapped by SkeletonJson.java of both branches

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Report = @import("../Report.zig");
const Version = @import("../Version.zig");
const Flags = @import("../Document.zig").Flags;
const tree = @import("../binary/tree.zig");
const edit = @import("../edit.zig");
const singular = @import("singular.zig");
const marks = @import("marks.zig");

pub const Error = error{ Malformed, OutOfMemory };

const reason_4_1 = "4.1 skips the solve while the parent is singular";
const reason_4_0 = "4.0 ignores mixScaleY when the other mixes are zero";

/// Transform mixes in curve value order
const Mixes = [6]f32;
const scale_y = 4;
/// Bounds padding of damaged input
const max_digits = 32;

pub fn early(arena: std.mem.Allocator, root: *Value, report: *Report, target: Version.Minor, flags: Flags) Error!void {
    const version = Version.ofRoot(root.*) orelse return;
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.1" };
    const doc = try edit.objectOf(root);
    const mix = Version.editor(version, .mix_scale_y_41);
    const why = "4.1 exports before 4.1.18 ignore mixScaleY when the other mixes are zero";
    if (mix == .old and flags.rewrite and target.major == 4 and target.minor >= 3) try m.gate(doc);
    if (mix == .old) try m.zeroSetup(doc, why) else if (mix != .new) try m.reportSetup(doc, why);
    if (mix != .new) if (try edit.childOf(doc, "animations")) |animations| {
        var it = animations.iterator();
        while (it.next()) |animation| {
            const map = try edit.objectOf(animation.value_ptr);
            if (mix == .old) try m.zeroKeys(animation.key_ptr.*, map, why) else try m.reportKeys(animation.key_ptr.*, map, why);
        }
    };
    if (Version.editor(version, .ik_singular_41) != .new) try singular.check(arena, doc, report, m.step, "4.1 exports before 4.1.20 solve through the singular parent");
    const mode = Version.editor(version, .sequence_mode_41);
    if (mode != .new) try m.checkSequenceMode(doc, mode == .old and flags.rewrite);
    if (Version.editor(version, .sequence_linked_41) != .new) try m.checkLinkedSequence(doc, flags.rewrite);
}

pub fn up(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.0-4.1" };
    const doc = try edit.objectOf(root);
    if (flags.rewrite and flags.slider) try m.gate(doc);
    try singular.check(arena, doc, report, m.step, reason_4_1);
    try m.zeroSetup(doc, reason_4_0);
    for (try edit.arrayOf(doc, "skins")) |*skin| {
        const attachments = try edit.childOf(try edit.objectOf(skin), "attachments") orelse continue;
        var slots = attachments.iterator();
        while (slots.next()) |slot| {
            var entries = (try edit.objectOf(slot.value_ptr)).iterator();
            while (entries.next()) |entry| try m.rename(try edit.objectOf(entry.value_ptr), "deform", "timelines");
        }
    }
    const animations = try edit.childOf(doc, "animations") orelse return;
    var it = animations.iterator();
    while (it.next()) |animation| {
        const name = animation.key_ptr.*;
        const map = try edit.objectOf(animation.value_ptr);
        var slots = try edit.timelinesOf(map, "slots");
        while (slots.next()) |slot| {
            const keys = try edit.childValue(try edit.objectOf(slot.value_ptr), "attachment") orelse continue;
            for (try edit.keysOf(keys)) |*key| {
                const k = try edit.objectOf(key);
                if (k.get("name")) |v| if (v == .null) {
                    _ = k.orderedRemove("name");
                };
            }
        }
        if (try edit.childOf(map, "deform")) |deform| {
            if (map.get("attachments") != null) return error.Malformed;
            var skins = deform.iterator();
            while (skins.next()) |skin| {
                var deform_slots = (try edit.objectOf(skin.value_ptr)).iterator();
                while (deform_slots.next()) |slot| {
                    var entries = (try edit.objectOf(slot.value_ptr)).iterator();
                    while (entries.next()) |entry| {
                        var timelines: ObjectMap = .empty;
                        try timelines.put(arena, "deform", entry.value_ptr.*);
                        entry.value_ptr.* = .{ .object = timelines };
                    }
                }
            }
            try m.rename(map, "deform", "attachments");
        }
        try m.zeroKeys(name, map, reason_4_0);
    }
}

pub fn down(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    _ = flags;
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.1-4.0" };
    const doc = try edit.objectOf(root);
    const version = Version.ofRoot(root.*);
    const old_mix = if (version) |v| Version.editor(v, .mix_scale_y_41) == .old else false;
    if (if (version) |v| Version.editor(v, .ik_singular_41) != .old else true) try singular.check(arena, doc, report, m.step, reason_4_1);
    if (!old_mix) try m.reportSetup(doc, reason_4_0);
    try m.downSkins(doc);
    const animations = try edit.childOf(doc, "animations") orelse return;
    var it = animations.iterator();
    while (it.next()) |animation| {
        const name = animation.key_ptr.*;
        const map = try edit.objectOf(animation.value_ptr);
        var slots = try edit.timelinesOf(map, "slots");
        while (slots.next()) |slot| {
            const keys = try edit.childValue(try edit.objectOf(slot.value_ptr), "attachment") orelse continue;
            for (try edit.keysOf(keys)) |*key| {
                const k = try edit.objectOf(key);
                // 4.0 readers require the name even when null
                if (k.get("name") == null) try k.put(arena, "name", .null);
            }
        }
        if (try edit.childOf(map, "attachments")) |attachments| {
            if (map.get("deform") != null) return error.Malformed;
            var deform: ObjectMap = .empty;
            var skins = attachments.iterator();
            while (skins.next()) |skin| {
                var deform_slots: ObjectMap = .empty;
                var timeline_slots = (try edit.objectOf(skin.value_ptr)).iterator();
                while (timeline_slots.next()) |slot| {
                    var entries: ObjectMap = .empty;
                    var timelines = (try edit.objectOf(slot.value_ptr)).iterator();
                    while (timelines.next()) |entry| {
                        const t = try edit.objectOf(entry.value_ptr);
                        if (try edit.childValue(t, "sequence") != null) {
                            const where = try std.fmt.allocPrint(arena, "animations.{s}.attachments.{s}.{s}.{s}.sequence", .{ name, skin.key_ptr.*, slot.key_ptr.*, entry.key_ptr.* });
                            try m.lose(.@"animation.sequence.dropped", where, "sequence timeline has no 4.0 equivalent", .{});
                        }
                        const keys = try edit.childValue(t, "deform") orelse continue;
                        try entries.put(arena, entry.key_ptr.*, keys.*);
                    }
                    if (entries.count() > 0) try deform_slots.put(arena, slot.key_ptr.*, .{ .object = entries });
                }
                if (deform_slots.count() > 0) try deform.put(arena, skin.key_ptr.*, .{ .object = deform_slots });
            }
            _ = map.orderedRemove("attachments");
            if (deform.count() > 0) try map.put(arena, "deform", .{ .object = deform });
        }
        if (!old_mix) try m.reportKeys(name, map, reason_4_0);
    }
}

fn mixesOf(map: *const ObjectMap) Error!Mixes {
    const x = try edit.float(map, "mixX", 1);
    const scale_x = try edit.float(map, "mixScaleX", 1);
    return .{ try edit.float(map, "mixRotate", 1), x, try edit.float(map, "mixY", x), scale_x, try edit.float(map, "mixScaleY", scale_x), try edit.float(map, "mixShearY", 1) };
}

/// 4.0 skips a transform constraint when all mixes but scaleY are zero
fn othersZero(v: Mixes) bool {
    for (v, 0..) |mix, i| if (i != scale_y and mix != 0) return false;
    return true;
}

fn onlyScaleY(v: Mixes) bool {
    return othersZero(v) and v[scale_y] != 0;
}

/// Bézier handles of the other mixes stay at 0
fn quietCurve(key: *const ObjectMap) Error!bool {
    const curve = key.get("curve") orelse return true;
    if (curve != .array) return true;
    for (0..6) |channel| {
        if (channel == scale_y) continue;
        for ([_]usize{ 1, 3 }) |i| {
            if (channel * 4 + i >= curve.array.items.len) break;
            if (try tree.number(curve.array.items[channel * 4 + i]) != 0) return false;
        }
    }
    return true;
}

fn isStepped(key: *const ObjectMap) bool {
    const curve = key.get("curve") orelse return false;
    return curve == .string and std.mem.eql(u8, curve.string, "stepped");
}

/// Paths the plain zeroing would report as approximated
fn liveSpans(m: *Migration, doc: *ObjectMap, map: *ObjectMap, name: []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var keyed = false;
    var quiet = true;
    if (try edit.childOf(doc, "animations")) |animations| {
        var it = animations.iterator();
        while (it.next()) |animation| {
            const keys = tree.get(tree.get(animation.value_ptr.*, "transform") orelse continue, name) orelse continue;
            if (keys != .array) return error.Malformed;
            keyed = keyed or keys.array.items.len > 0;
            for (keys.array.items) |*key| {
                const k = try edit.objectOf(key);
                quiet = quiet and othersZero(try mixesOf(k)) and try quietCurve(k);
            }
            var copy = try edit.clone(m.arena, keys);
            if (try upTransformKeys(m.arena, try edit.keysOf(&copy))) try out.append(m.arena, try std.fmt.allocPrint(m.arena, "animations.{s}.transform.{s}", .{ animation.key_ptr.*, name }));
        }
    }
    if (keyed and !quiet and onlyScaleY(try mixesOf(map))) try out.append(m.arena, try m.path("transform", map));
    return out.items;
}

/// Zeroes mixScaleY where 4.0 skips the constraint, for a gate that failed
pub fn zeroSkipped(arena: std.mem.Allocator, doc: *ObjectMap, c: *ObjectMap) Error!void {
    if (onlyScaleY(try mixesOf(c))) try c.put(arena, "mixScaleY", .{ .float = 0 });
    const name = try tree.getString(.{ .object = c.* }, "name") orelse "";
    const animations = try edit.childOf(doc, "animations") orelse return;
    for (animations.values()) |*animation| {
        const timelines = try edit.childOf(try edit.objectOf(animation), "transform") orelse continue;
        const keys = timelines.getPtr(name) orelse continue;
        _ = try upTransformKeys(arena, try edit.keysOf(keys));
    }
}

/// Another mix is nonzero at setup
pub fn gateSetup(c: *const ObjectMap) Error!bool {
    return !othersZero(try mixesOf(c));
}

/// One key of the gate, the gate stays off at an instant and turns on at later
pub const Gate = struct { time: f32, on: bool, later: ?f32 };

/// Where 4.0 applies mixScaleY, per key
pub fn gateKeys(arena: std.mem.Allocator, keys: []Value) Error![]const Gate {
    const out = try arena.alloc(Gate, keys.len);
    for (keys, out, 0..) |*key, *g, i| {
        const k = try edit.objectOf(key);
        const zero = othersZero(try mixesOf(k));
        const time = try edit.float(k, "time", 0);
        var span = !zero;
        var next_time = time;
        if (i + 1 < keys.len) {
            const next = try edit.objectOf(&keys[i + 1]);
            next_time = try edit.float(next, "time", 0);
            if (!isStepped(k)) span = !(zero and othersZero(try mixesOf(next)) and try quietCurve(k));
        }
        g.* = .{ .time = time, .on = !zero, .later = if (zero and span and next_time > time) std.math.nextAfter(f32, time, next_time) else null };
    }
    return out;
}

/// Zeroes mixScaleY where 4.0 skips the constraint, true when an interpolated neighbor changes
fn upTransformKeys(arena: std.mem.Allocator, keys: []Value) Error!bool {
    const zero = try arena.alloc(bool, keys.len);
    const stepped = try arena.alloc(bool, keys.len);
    for (keys, zero, stepped) |*key, *z, *s| {
        const k = try edit.objectOf(key);
        z.* = othersZero(try mixesOf(k));
        const curve = try edit.childValue(k, "curve");
        s.* = if (curve) |c| c.* == .string and std.mem.eql(u8, c.string, "stepped") else false;
    }
    const skip = try arena.alloc(bool, keys.len);
    for (skip, 0..) |*s, i| s.* = zero[i] and (stepped[i] or i + 1 == keys.len or zero[i + 1] and try quietCurve(try edit.objectOf(&keys[i])));

    var inexact = false;
    for (keys, 0..) |*key, i| {
        const k = try edit.objectOf(key);
        const interpolated_before = i > 0 and !stepped[i - 1];
        const interpolated_after = i + 1 < keys.len and !stepped[i];
        if (skip[i] and interpolated_after) if (try edit.childValue(k, "curve")) |c| {
            if (c.* == .array and c.array.items.len >= 4 * scale_y + 4) {
                c.array.items[4 * scale_y + 1] = .{ .float = 0 };
                c.array.items[4 * scale_y + 3] = .{ .float = 0 };
            }
        };
        const forced = skip[i] or interpolated_before and skip[i - 1];
        if (!forced or (try mixesOf(k))[scale_y] == 0) continue;
        try k.put(arena, "mixScaleY", .{ .float = 0 });
        if (interpolated_before and !skip[i - 1] or interpolated_after and !skip[i]) inexact = true;
    }
    return inexact;
}

/// Sequence keys of one attachment
const Linked = struct { skin: []const u8, slot: []const u8, name: []const u8, parent_skin: []const u8, parent: []const u8, own: u31, count: u31 };

const replay_steps = 100_000;
const replay_keys = 4096;

/// Frame of the linked mesh before 4.1.27-beta, from the parent count
fn shownIndex(mode: []const u8, index: i64, count: i64, own: i64) ?i64 {
    if (count < 1 or own < 1) return null;
    const n = 2 * count - 2;
    const i: i64 = if (std.mem.eql(u8, mode, "hold"))
        index
    else if (std.mem.eql(u8, mode, "once"))
        @min(count - 1, index)
    else if (std.mem.eql(u8, mode, "loop"))
        @mod(index, count)
    else if (std.mem.eql(u8, mode, "pingpong")) blk: {
        const p = if (n == 0) 0 else @mod(index, n);
        break :blk if (p >= count) n - p else p;
    } else if (std.mem.eql(u8, mode, "onceReverse"))
        @max(count - 1 - index, 0)
    else if (std.mem.eql(u8, mode, "loopReverse"))
        count - 1 - @mod(index, count)
    else if (std.mem.eql(u8, mode, "pingpongReverse")) blk: {
        const p = if (n == 0) 0 else @mod(index + count - 1, n);
        break :blk if (p >= count) n - p else p;
    } else return null;
    return @min(own - 1, i);
}

fn holdKey(arena: std.mem.Allocator, time: f64, index: i64) Error!Value {
    var key: ObjectMap = .empty;
    if (time != 0) try key.put(arena, "time", .{ .float = time });
    if (index != 0) try key.put(arena, "index", .{ .integer = index });
    return .{ .object = key };
}

fn child(arena: std.mem.Allocator, map: *ObjectMap, key: []const u8) Error!*ObjectMap {
    const entry = try map.getOrPut(arena, key);
    if (!entry.found_existing) entry.value_ptr.* = .{ .object = .empty };
    return edit.objectOf(entry.value_ptr);
}

const Sequence = struct { animation: []const u8, skin: []const u8, slot: []const u8, attachment: []const u8, keys: []Value };

const Migration = struct {
    arena: std.mem.Allocator,
    report: *Report,
    step: []const u8,
    /// Constraints a 4.3 slider gates later
    marked: std.StringHashMapUnmanaged(void) = .empty,

    /// Marks constraints with a span the plain zeroing cannot hold
    fn gate(m: *Migration, doc: *ObjectMap) Error!void {
        for (try edit.arrayOf(doc, "transform")) |*c| {
            const map = try edit.objectOf(c);
            const name = try tree.getString(c.*, "name") orelse "";
            if (map.get(marks.mix_scale_y_gate) == null) {
                const spans = try liveSpans(m, doc, map, name);
                if (spans.len == 0) continue;
                try map.put(m.arena, marks.mix_scale_y_gate, .{ .string = m.step });
                for (spans) |where| try m.lose(.@"transform.mixScaleY.rewritten", where, "mixScaleY gated by a slider while another mix is nonzero", .{});
            }
            try m.marked.put(m.arena, name, {});
        }
    }

    /// Exact only while the constraint is unkeyed
    fn zeroSetup(m: *Migration, doc: *ObjectMap, why: []const u8) Error!void {
        for (try edit.arrayOf(doc, "transform")) |*c| {
            const map = try edit.objectOf(c);
            if (map.get(marks.mix_scale_y_gate) != null or !onlyScaleY(try mixesOf(map))) continue;
            try map.put(m.arena, "mixScaleY", .{ .float = 0 });
            const name = try tree.getString(c.*, "name") orelse "";
            var keyed = false;
            var quiet = true;
            if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |animation| {
                const keys = tree.get(tree.get(animation, "transform") orelse continue, name) orelse continue;
                if (keys != .array) return error.Malformed;
                keyed = keyed or keys.array.items.len > 0;
                for (keys.array.items) |*key| {
                    const k = try edit.objectOf(key);
                    quiet = quiet and othersZero(try mixesOf(k)) and try quietCurve(k);
                }
            };
            // the other mixes stay 0 everywhere, so the skip holds in every crossfade
            if (keyed and !quiet) {
                try m.lose(.@"transform.mixScaleY.approximated", try m.path("transform", map), "{s}", .{why});
            } else try m.lose(.@"transform.mixScaleY.rewritten", try m.path("transform", map), "mixScaleY as the only nonzero mix set to 0", .{});
        }
    }

    fn zeroKeys(m: *Migration, animation: []const u8, map: *ObjectMap, why: []const u8) Error!void {
        var transforms = try edit.timelinesOf(map, "transform");
        while (transforms.next()) |timeline| {
            if (m.marked.contains(timeline.key_ptr.*)) continue;
            if (try upTransformKeys(m.arena, try edit.keysOf(timeline.value_ptr))) {
                const where = try std.fmt.allocPrint(m.arena, "animations.{s}.transform.{s}", .{ animation, timeline.key_ptr.* });
                try m.lose(.@"transform.mixScaleY.approximated", where, "{s}", .{why});
            }
        }
    }

    fn reportSetup(m: *Migration, doc: *ObjectMap, why: []const u8) Error!void {
        for (try edit.arrayOf(doc, "transform")) |*c| {
            const map = try edit.objectOf(c);
            if (onlyScaleY(try mixesOf(map))) try m.lose(.@"transform.mixScaleY.approximated", try m.path("transform", map), "{s}", .{why});
        }
    }

    fn reportKeys(m: *Migration, animation: []const u8, map: *ObjectMap, why: []const u8) Error!void {
        var transforms = try edit.timelinesOf(map, "transform");
        while (transforms.next()) |timeline| {
            for (try edit.keysOf(timeline.value_ptr)) |*key| {
                if (!onlyScaleY(try mixesOf(try edit.objectOf(key)))) continue;
                const where = try std.fmt.allocPrint(m.arena, "animations.{s}.transform.{s}", .{ animation, timeline.key_ptr.* });
                try m.lose(.@"transform.mixScaleY.approximated", where, "{s}", .{why});
                break;
            }
        }
    }

    /// Sequence keys of every attachment timeline
    fn sequences(m: *Migration, doc: *ObjectMap) Error![]const Sequence {
        var out: std.ArrayList(Sequence) = .empty;
        const animations = try edit.childOf(doc, "animations") orelse return &.{};
        var it = animations.iterator();
        while (it.next()) |animation| {
            var skins = try edit.timelinesOf(try edit.objectOf(animation.value_ptr), "attachments");
            while (skins.next()) |skin| {
                var slots = (try edit.objectOf(skin.value_ptr)).iterator();
                while (slots.next()) |slot| {
                    var entries = (try edit.objectOf(slot.value_ptr)).iterator();
                    while (entries.next()) |entry| {
                        const keys = try edit.childValue(try edit.objectOf(entry.value_ptr), "sequence") orelse continue;
                        try out.append(m.arena, .{ .animation = animation.key_ptr.*, .skin = skin.key_ptr.*, .slot = slot.key_ptr.*, .attachment = entry.key_ptr.*, .keys = try edit.keysOf(keys) });
                    }
                }
            }
        }
        return out.items;
    }

    /// Old pingpongReverse counts up and the display clamps it like once
    fn checkSequenceMode(m: *Migration, doc: *ObjectMap, rewrite: bool) Error!void {
        for (try m.sequences(doc)) |s| {
            var found = false;
            for (s.keys) |*key| {
                if (!std.mem.eql(u8, try tree.getString(key.*, "mode") orelse "hold", "pingpongReverse")) continue;
                found = true;
                if (rewrite) try (try edit.objectOf(key)).put(m.arena, "mode", .{ .string = "once" });
            }
            if (!found) continue;
            const where = try std.fmt.allocPrint(m.arena, "animations.{s}.attachments.{s}.{s}.{s}.sequence", .{ s.animation, s.skin, s.slot, s.attachment });
            if (rewrite)
                try m.lose(.@"sequence.mode.rewritten", where, "old pingpongReverse keys become once", .{})
            else
                try m.lose(.@"sequence.mode.approximated", where, "4.1 exports before 4.1.10-beta leave the pingpongReverse index unbounded", .{});
        }
    }

    /// Linked meshes play parent keys with parent count
    /// Gives the linked mesh its own hold keys of the old display and the parent deform keys
    fn unroll(m: *Migration, doc: *ObjectMap, l: Linked) Error!bool {
        const animations = try edit.childOf(doc, "animations") orelse return true;
        const Plan = struct { animation: *ObjectMap, sequence: ?Value, deform: ?Value };
        var plans: std.ArrayList(Plan) = .empty;
        for (animations.values()) |*animation| {
            const map = try edit.objectOf(animation);
            const attachments = tree.get(animation.*, "attachments") orelse continue;
            const slot = tree.get(tree.get(attachments, l.parent_skin) orelse .null, l.slot) orelse .null;
            // keys of its own would apply on top
            if (tree.get(tree.get(tree.get(attachments, l.skin) orelse .null, l.slot) orelse .null, l.name) != null) return false;
            const parent = tree.get(slot, l.parent) orelse continue;
            var plan: Plan = .{ .animation = map, .sequence = null, .deform = null };
            if (tree.get(parent, "deform")) |d| plan.deform = try edit.clone(m.arena, d);
            if (tree.get(parent, "sequence")) |s| {
                if (s != .array) return error.Malformed;
                plan.sequence = try m.replay(s.array.items, l, edit.lastTime(animation.*)) orelse return false;
            }
            try plans.append(m.arena, plan);
        }
        for (plans.items) |p| {
            const attachments = try child(m.arena, p.animation, "attachments");
            const own = try child(m.arena, try child(m.arena, try child(m.arena, attachments, l.skin), l.slot), l.name);
            if (p.sequence) |s| try own.put(m.arena, "sequence", s);
            if (p.deform) |d| try own.put(m.arena, "deform", d);
        }
        return true;
    }

    /// Old display of parent keys as hold keys, null past the key budget
    fn replay(m: *Migration, keys: []const Value, l: Linked, end: f64) Error!?Value {
        var out = tree.array(m.arena);
        var steps: usize = 0;
        for (keys, 0..) |key, j| {
            const time: f64 = try tree.getFloat(key, "time", 0);
            const last = j + 1 == keys.len;
            const until: f64 = if (last) end else try tree.getFloat(keys[j + 1], "time", 0);
            const mode = try tree.getString(key, "mode") orelse "hold";
            const index: i64 = try tree.getNatural(key, "index", 0);
            var shown = shownIndex(mode, index, l.count, l.own) orelse return null;
            try out.append(try holdKey(m.arena, time, shown));
            if (std.mem.eql(u8, mode, "hold")) continue;
            const delay: f64 = try tree.getFloat(key, "delay", 0);
            if (!(delay > 0)) return null;
            var n: i64 = 1;
            while (true) : (n += 1) {
                steps += 1;
                if (steps > replay_steps or out.items.len > replay_keys) return null;
                const at: f64 = time + (@as(f64, @floatFromInt(n)) - 0.00001) * delay;
                if (if (last) at > until else at >= until) break;
                const next = shownIndex(mode, index + n, l.count, l.own).?;
                if (next != shown) try out.append(try holdKey(m.arena, at, next));
                shown = next;
                // once modes stay on their end frame
                if ((std.mem.eql(u8, mode, "once") or std.mem.eql(u8, mode, "onceReverse")) and index + n >= l.count - 1) break;
            }
        }
        return .{ .array = out };
    }

    fn checkLinkedSequence(m: *Migration, doc: *ObjectMap, rewrite: bool) Error!void {
        const keyed = try m.sequences(doc);
        const skins = try edit.arrayOf(doc, "skins");
        for (skins) |skin| {
            const skin_name = try tree.requireString(skin, "name");
            const attachments = tree.get(skin, "attachments") orelse continue;
            if (attachments != .object) return error.Malformed;
            var slots = attachments.object.iterator();
            while (slots.next()) |slot| {
                if (slot.value_ptr.* != .object) return error.Malformed;
                var entries = slot.value_ptr.object.iterator();
                while (entries.next()) |entry| {
                    const a = entry.value_ptr.*;
                    if (!std.mem.eql(u8, try tree.getString(a, "type") orelse "region", "linkedmesh") or !try tree.getBool(a, "timelines", true)) continue;
                    const own = tree.get(a, "sequence") orelse continue;
                    const parent = try tree.requireString(a, "parent");
                    const parent_skin = try tree.getString(a, "skin") orelse skin_name;
                    const source = for (skins) |other| {
                        if (!std.mem.eql(u8, try tree.requireString(other, "name"), parent_skin)) continue;
                        break tree.get(tree.get(tree.get(other, "attachments") orelse .null, slot.key_ptr.*) orelse .null, parent);
                    } else null;
                    const count = tree.get(source orelse continue, "sequence") orelse continue;
                    const own_count = try tree.getNatural(own, "count", 0);
                    const parent_count = try tree.getNatural(count, "count", 0);
                    if (own_count == parent_count) continue;
                    // hold keeps its index and once clamps below the parent count first
                    var differs = false;
                    for (keyed) |s| {
                        if (!std.mem.eql(u8, s.skin, parent_skin) or !std.mem.eql(u8, s.slot, slot.key_ptr.*) or !std.mem.eql(u8, s.attachment, parent)) continue;
                        for (s.keys) |key| {
                            const mode = try tree.getString(key, "mode") orelse "hold";
                            if (std.mem.eql(u8, mode, "hold") or std.mem.eql(u8, mode, "once") and parent_count >= own_count) continue;
                            differs = true;
                        }
                    }
                    if (!differs) continue;
                    const where = try std.fmt.allocPrint(m.arena, "skins.{s}.{s}.{s}", .{ skin_name, slot.key_ptr.*, entry.key_ptr.* });
                    const linked: Linked = .{ .skin = skin_name, .slot = slot.key_ptr.*, .name = entry.key_ptr.*, .parent_skin = parent_skin, .parent = parent, .own = own_count, .count = parent_count };
                    if (rewrite and try m.unroll(doc, linked)) {
                        try entry.value_ptr.object.put(m.arena, "timelines", .{ .bool = false });
                        try m.lose(.@"sequence.linked.rewritten", where, "own hold keys replay the frames of the parent count, the parent deform keys are copied", .{});
                    } else try m.lose(.@"sequence.linked.approximated", where, "4.1 exports before 4.1.27-beta play it with the parent frame count", .{});
                }
            }
        }
    }

    fn downSkins(m: *Migration, doc: *ObjectMap) Error!void {
        for (try edit.arrayOf(doc, "skins")) |*skin| {
            const attachments = try edit.childOf(try edit.objectOf(skin), "attachments") orelse continue;
            var slots = attachments.iterator();
            while (slots.next()) |slot| {
                var entries = (try edit.objectOf(slot.value_ptr)).iterator();
                while (entries.next()) |entry| {
                    const a = try edit.objectOf(entry.value_ptr);
                    try m.rename(a, "timelines", "deform");
                    const sequence = edit.take(a, "sequence") orelse continue;
                    if (sequence == .null) continue;
                    try a.put(m.arena, "path", .{ .string = try setupPath(m.arena, a, entry.key_ptr.*, sequence) });
                    const where = try std.fmt.allocPrint(m.arena, "skins.{s}.{s}.{s}", .{ try tree.getString(skin.*, "name") orelse "", slot.key_ptr.*, entry.key_ptr.* });
                    try m.lose(.@"attachment.sequence.dropped", where, "sequence becomes its setup region", .{});
                }
            }
        }
    }

    fn rename(m: *Migration, map: *ObjectMap, from: []const u8, to: []const u8) Error!void {
        if (map.fetchOrderedRemove(from)) |kv| try map.put(m.arena, to, kv.value);
    }

    fn path(m: *Migration, list: []const u8, map: *const ObjectMap) Error![]const u8 {
        const name = try tree.getString(.{ .object = map.* }, "name") orelse "";
        return std.fmt.allocPrint(m.arena, "{s}.{s}", .{ list, name });
    }

    fn lose(m: *Migration, code: Report.Code, where: []const u8, comptime fmt: []const u8, args: anytype) Error!void {
        try m.report.add(.{
            .code = code,
            .step = m.step,
            .path = where,
            .message = try std.fmt.allocPrint(m.arena, fmt, args),
        });
    }
};

/// Region name of the setup frame like Sequence.getPath
fn setupPath(arena: std.mem.Allocator, attachment: *const ObjectMap, entry: []const u8, sequence: Value) Error![]const u8 {
    if (sequence != .object) return error.Malformed;
    const a: Value = .{ .object = attachment.* };
    const base = try tree.getString(a, "path") orelse try tree.getString(a, "name") orelse entry;
    const count = try tree.natural(tree.get(sequence, "count") orelse return error.Malformed);
    if (count == 0) return error.Malformed;
    const digits = try tree.getNatural(sequence, "digits", 0);
    if (digits > max_digits) return error.Malformed;
    const index = @min(try tree.getNatural(sequence, "setup", 0), count - 1);
    const frame = try std.fmt.allocPrint(arena, "{d}", .{@as(i64, try tree.getInt(sequence, "start", 1)) + index});
    const zeros = @as(usize, digits) -| frame.len;
    const out = try arena.alloc(u8, base.len + zeros + frame.len);
    @memcpy(out[0..base.len], base);
    @memset(out[base.len..][0..zeros], '0');
    @memcpy(out[base.len + zeros ..], frame);
    return out;
}

test "attachment timelines up and down" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Report = .{ .arena = a };
    const input =
        \\{"skins":[{"name":"default","attachments":{"s":{"l":{"type":"linkedmesh","parent":"m","deform":false},
        \\"r":{"path":"wing"}}}}],
        \\"animations":{"a":{"slots":{"s":{"attachment":[{"name":null}]}},
        \\"deform":{"default":{"s":{"m":[{"time":0}]}}},
        \\"transform":{"t":[{"mixRotate":0,"mixX":0,"mixScaleX":0,"mixShearY":0,"mixScaleY":1,"curve":"stepped"},{"time":1}]}}}}
    ;
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    const skin = root.object.get("skins").?.array.items[0].object.get("attachments").?.object.get("s").?.object;
    try up(a, &root, &report, .{});
    try std.testing.expectEqual(0, report.entries.items.len);
    try std.testing.expect(!skin.get("l").?.object.get("timelines").?.bool);
    const animation = root.object.get("animations").?.object.get("a").?.object;
    try std.testing.expect(animation.get("slots").?.object.get("s").?.object.get("attachment").?.array.items[0].object.get("name") == null);
    try std.testing.expectEqual(1, animation.get("attachments").?.object.get("default").?.object.get("s").?.object.get("m").?.object.get("deform").?.array.items.len);
    try std.testing.expectEqual(0, animation.get("transform").?.object.get("t").?.array.items[0].object.get("mixScaleY").?.float);

    const sequence = try std.json.parseFromSliceLeaky(Value, a, "{\"count\":9,\"digits\":2,\"setup\":3}", .{});
    try skin.getPtr("r").?.object.put(a, "sequence", sequence);
    try down(a, &root, &report, .{});
    try std.testing.expectEqual(1, report.entries.items.len);
    try std.testing.expectEqual(.@"attachment.sequence.dropped", report.entries.items[0].code);
    try std.testing.expectEqualStrings("wing04", skin.get("r").?.object.get("path").?.string);
    try std.testing.expect(!skin.get("l").?.object.get("deform").?.bool);
    const restored = root.object.get("animations").?.object.get("a").?.object;
    try std.testing.expect(restored.get("slots").?.object.get("s").?.object.get("attachment").?.array.items[0].object.get("name").? == .null);
    try std.testing.expectEqual(1, restored.get("deform").?.object.get("default").?.object.get("s").?.object.get("m").?.array.items.len);
}

fn codes(report: *const Report, a: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (report.entries.items) |e| {
        try out.appendSlice(a, @tagName(e.code));
        try out.append(a, ' ');
    }
    return out.items;
}

test "mixScaleY setup up" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const setup =
        \\{"transform":[{"name":"t","mixRotate":0,"mixX":0,"mixScaleX":0,"mixShearY":0,"mixScaleY":1}]
    ;
    for ([_]struct { json: []const u8, code: []const u8 }{
        .{ .json = setup ++ "}", .code = "transform.mixScaleY.rewritten " },
        .{ .json = setup ++ ",\"animations\":{\"a\":{\"transform\":{\"t\":[{\"mixRotate\":1}]}}}}", .code = "transform.mixScaleY.approximated " },
    }) |case| {
        var report: Report = .{ .arena = a };
        var root = try std.json.parseFromSliceLeaky(Value, a, case.json, .{});
        try up(a, &root, &report, .{});
        try std.testing.expectEqualStrings(case.code, try codes(&report, a));
        try std.testing.expectEqual(0, root.object.get("transform").?.array.items[0].object.get("mixScaleY").?.float);
    }
}

test "4.1 beta exports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skeleton =
        \\"bones":[{"name":"root"},{"name":"hip","parent":"root"},{"name":"leg","parent":"hip"}],
        \\"slots":[{"name":"s","bone":"root"}],
        \\"ik":[{"name":"i","bones":["leg"],"target":"root"}],
        \\"transform":[{"name":"t","bones":["leg"],"target":"root","mixRotate":0,"mixX":0,"mixScaleX":0,"mixShearY":0,"mixScaleY":1}],
        \\"skins":[{"name":"default","attachments":{"s":{"m":{"type":"mesh","sequence":{"count":3}},
        \\"l":{"type":"linkedmesh","parent":"m","sequence":{"count":2}}}}}],
        \\"animations":{"a":{"bones":{"root":{"scale":[{"x":-1},{"time":1}]}},
        \\"transform":{"t":[{"mixRotate":0,"mixX":0,"mixScaleX":0,"mixShearY":0,"mixScaleY":0.5}]},
        \\"attachments":{"default":{"s":{"m":{"sequence":[{"mode":"pingpongReverse"}]}}}}}}}
    ;
    const v4_3: Version.Minor = .{ .major = 4, .minor = 3 };
    for ([_]struct { version: []const u8, flags: Flags, code: []const u8, zero: bool }{
        .{ .version = "4.1.09-beta", .flags = .{}, .code = "transform.mixScaleY.rewritten ik.singular.approximated sequence.mode.approximated sequence.linked.approximated ", .zero = true },
        .{ .version = "4.1.09-beta", .flags = .{ .rewrite = true }, .code = "transform.mixScaleY.rewritten ik.singular.approximated sequence.mode.rewritten ", .zero = true },
        .{ .version = "4.1.17", .flags = .{}, .code = "transform.mixScaleY.rewritten ik.singular.approximated ", .zero = true },
        .{ .version = "4.1.19", .flags = .{}, .code = "ik.singular.approximated ", .zero = false },
        .{ .version = "4.1.20", .flags = .{}, .code = "", .zero = false },
    }) |case| {
        var report: Report = .{ .arena = a };
        const input = try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"{s}\"}},{s}", .{ case.version, skeleton });
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try early(a, &root, &report, v4_3, case.flags);
        try std.testing.expectEqualStrings(case.code, try codes(&report, a));
        const key = root.object.get("animations").?.object.get("a").?.object.get("transform").?.object.get("t").?.array.items[0];
        try std.testing.expectEqual(case.zero, try tree.getFloat(key, "mixScaleY", 1) == 0);
    }
}

test "mixScaleY gate marks the live span" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"skeleton":{"spine":"4.1.17"},"bones":[{"name":"root"},{"name":"leg","parent":"root"}],
        \\"transform":[{"name":"t","bones":["leg"],"target":"root","mixRotate":0,"mixX":0,"mixScaleX":0,"mixShearY":0,"mixScaleY":1}],
        \\"animations":{"a":{"transform":{"t":[{"mixRotate":0,"mixX":0,"mixScaleX":0,"mixShearY":0,"mixScaleY":0.4},
        \\{"time":1,"mixRotate":0.5,"mixX":0,"mixScaleX":0,"mixShearY":0,"mixScaleY":0.8}]}}}}
    ;
    for ([_]struct { minor: u8, flags: Flags, marked: bool, code: []const u8 }{
        .{ .minor = 3, .flags = .{ .rewrite = true }, .marked = true, .code = "transform.mixScaleY.rewritten " },
        .{ .minor = 3, .flags = .{}, .marked = false, .code = "transform.mixScaleY.approximated " },
        .{ .minor = 2, .flags = .{ .rewrite = true }, .marked = false, .code = "transform.mixScaleY.approximated " },
    }) |case| {
        var report: Report = .{ .arena = a };
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try early(a, &root, &report, .{ .major = 4, .minor = case.minor }, case.flags);
        try std.testing.expectEqualStrings(case.code, try codes(&report, a));
        try std.testing.expectEqual(case.marked, root.object.get("transform").?.array.items[0].object.get(marks.mix_scale_y_gate) != null);
        try std.testing.expectEqual(!case.marked, try tree.getFloat(root.object.get("transform").?.array.items[0], "mixScaleY", 1) == 0);
    }
}

test "down from 4.1 betas" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skeleton =
        \\"bones":[{"name":"root"},{"name":"hip","parent":"root"},{"name":"leg","parent":"hip"}],
        \\"ik":[{"name":"i","bones":["leg"],"target":"root"}],
        \\"transform":[{"name":"t","bones":["leg"],"target":"root","mixRotate":0,"mixX":0,"mixScaleX":0,"mixShearY":0,"mixScaleY":1}],
        \\"animations":{"a":{"bones":{"root":{"scale":[{"x":-1},{"time":1}]}}}}}
    ;
    for ([_]struct { version: []const u8, code: []const u8 }{
        .{ .version = "4.1.17", .code = "" },
        .{ .version = "4.1.19", .code = "ik.singular.approximated transform.mixScaleY.approximated " },
        .{ .version = "4.1.20", .code = "ik.singular.approximated transform.mixScaleY.approximated " },
    }) |case| {
        var report: Report = .{ .arena = a };
        const input = try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"{s}\"}},{s}", .{ case.version, skeleton });
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try down(a, &root, &report, .{});
        try std.testing.expectEqualStrings(case.code, try codes(&report, a));
    }
}

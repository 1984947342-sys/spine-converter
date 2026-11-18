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

//! Spine 4.1 and 4.2 JSON, mapped by SkeletonJson.java of both branches

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Report = @import("../Report.zig");
const Version = @import("../Version.zig");
const Flags = @import("../Document.zig").Flags;
const tree = @import("../binary/tree.zig");
const edit = @import("../edit.zig");
const marks = @import("marks.zig");

pub const Error = error{ Malformed, OutOfMemory };

const kinds = [_][]const u8{ "ik", "transform", "path", "physics" };

pub fn early(arena: std.mem.Allocator, root: *Value, report: *Report, target: Version.Minor, flags: Flags) Error!void {
    const version = Version.ofRoot(root.*) orelse return;
    if (Version.editor(version, .local_wrap_42) == .new) return;
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.2", .rewrite = flags.rewrite, .rig = flags.rewrite and target.major == 4 and target.minor >= 3 };
    try m.checkLocalWrap(try edit.objectOf(root), "4.2 exports before 4.2.60-beta wrap it");
}

pub fn up(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.1-4.2", .rewrite = flags.rewrite, .rig = flags.rewrite and flags.slider };
    const doc = try edit.objectOf(root);
    try m.checkLocalWrap(doc, "4.1 wraps it");
    try m.checkApplied(doc, true);
    try m.checkSkip(doc, false);
    for (try edit.arrayOf(doc, "bones")) |*bone| {
        const map = try edit.objectOf(bone);
        if (map.fetchOrderedRemove("transform")) |kv| try map.put(arena, "inherit", kv.value);
    }
}

pub fn down(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.2-4.1", .rewrite = flags.rewrite };
    const doc = try edit.objectOf(root);
    const version = Version.ofRoot(root.*);
    if (version == null or Version.editor(version.?, .local_wrap_42) != .old) try m.checkLocalWrap(doc, "4.1 wraps it");
    try m.checkApplied(doc, false);
    try m.checkSkip(doc, true);
    if (try edit.childOf(doc, "skeleton")) |skeleton| {
        if (try edit.float(skeleton, "referenceScale", 100) != 100) {
            try m.lose(.@"skeleton.referenceScale.dropped", "skeleton.referenceScale", "physics reference scale", .{});
        }
        _ = edit.take(skeleton, "referenceScale");
    }
    var inherits: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (try edit.arrayOf(doc, "bones")) |*bone| {
        const map = try edit.objectOf(bone);
        if (map.fetchOrderedRemove("inherit")) |kv| try map.put(arena, "transform", kv.value);
        try inherits.put(arena, try tree.getString(bone.*, "name") orelse "", try tree.getString(bone.*, "transform") orelse "normal");
        try m.dropKeys(map, "bones", &.{ .{ "icon", .@"bone.icon.dropped" }, .{ "visible", .@"bone.visible.dropped" } });
    }
    for (try edit.arrayOf(doc, "slots")) |*slot| try m.dropKeys(try edit.objectOf(slot), "slots", &.{.{ "visible", .@"slot.visible.dropped" }});
    try m.downPhysics(doc);
    for (try edit.arrayOf(doc, "skins")) |*skin| {
        const map = try edit.objectOf(skin);
        _ = edit.take(map, "physics");
        try m.dropKeys(map, "skins", &.{.{ "color", .@"skin.color.dropped" }});
    }

    const animations = try edit.childOf(doc, "animations") orelse return;
    var it = animations.iterator();
    while (it.next()) |animation| {
        const map = try edit.objectOf(animation.value_ptr);
        if (edit.take(map, "physics") != null) {
            try m.lose(.@"animation.physics.dropped", try std.fmt.allocPrint(arena, "animations.{s}.physics", .{animation.key_ptr.*}), "physics timelines", .{});
        }
        var bones = try edit.timelinesOf(map, "bones");
        while (bones.next()) |bone| {
            const timeline = edit.take(try edit.objectOf(bone.value_ptr), "inherit") orelse continue;
            const where = try std.fmt.allocPrint(arena, "animations.{s}.bones.{s}.inherit", .{ animation.key_ptr.*, bone.key_ptr.* });
            if (try holdsOnly(timeline, inherits.get(bone.key_ptr.*) orelse "normal")) {
                try m.lose(.@"animation.inherit.setup.dropped", where, "inherit timeline holds only the setup inherit", .{});
            } else try m.lose(.@"animation.inherit.dropped", where, "inherit timeline", .{});
        }
    }
}

fn holdsOnly(timeline: Value, inherit: []const u8) Error!bool {
    if (timeline != .array) return error.Malformed;
    for (timeline.array.items) |key| {
        if (!std.mem.eql(u8, try tree.getString(key, "inherit") orelse "normal", inherit)) return false;
    }
    return true;
}

const Dropped = struct { []const u8, Report.Code };

const Migration = struct {
    arena: std.mem.Allocator,
    report: *Report,
    step: []const u8,
    rewrite: bool = false,
    /// Target runtime has transform constraint mappings that rebuild the wrap
    rig: bool = false,

    /// 4.1 wraps local absolute differences, 4.2 does not
    fn checkLocalWrap(m: *Migration, doc: *ObjectMap, reason: []const u8) Error!void {
        var parents: std.StringHashMapUnmanaged(?[]const u8) = .empty;
        for (try edit.arrayOf(doc, "bones")) |bone| try parents.put(m.arena, try tree.requireString(bone, "name"), try tree.getString(bone, "parent"));
        const constraints = try ordered(m.arena, doc, parents);
        for (try edit.arrayOf(doc, "transform")) |*value| {
            const c = value.*;
            if (!try tree.getBool(c, "local", false) or try tree.getBool(c, "relative", false)) continue;
            const name = try tree.requireString(c, "name");
            const target = try tree.requireString(c, "target");
            const bones = try tree.getArray(c, "bones");
            const lists = try keyLists(m.arena, doc, &.{ "transform", name });
            var wraps = false;
            var wrapped: [2]bool = .{ false, false };
            // turns of 360 the old wrap always removes, null when they vary
            var turns: [2]?f32 = .{ 0, 0 };
            for ([_]bool{ true, false }, &turns, &wrapped) |rotate, *turn, *wrap| {
                const key = if (rotate) "mixRotate" else "mixShearY";
                var mix: Range = .of(try tree.getFloat(c, key, 1));
                try mix.keys(lists, key, 1, if (rotate) 0 else 5);
                if (!mix.partial) continue;
                const offset = try tree.getFloat(c, if (rotate) "rotation" else "shearY", 0);
                const t = try angle(m.arena, doc, target, rotate);
                for (bones, 0..) |bone, i| {
                    if (bone != .string) return error.Malformed;
                    const b = try angle(m.arena, doc, bone.string, rotate);
                    const low = t.min + offset - b.max;
                    const high = t.max + offset - b.min;
                    if (@max(-low, high) > 180) {
                        wraps = true;
                        wrap.* = true;
                    }
                    if (i == 0) turn.* = @round((low + high) / 720);
                    const k = turn.* orelse continue;
                    // a margin keeps the old rounding on one side
                    if (low <= k * 360 - 179.99 or high >= k * 360 + 179.99) turn.* = null;
                }
            }
            if (!wraps) continue;
            const where = try std.fmt.allocPrint(m.arena, "transform.{s}", .{name});
            const free = !try constrainedBefore(doc, constraints, try tree.getInt(c, "order", 0), target, bones);
            const fixed = turns[0] != null and turns[1] != null and free;
            if (m.rewrite and fixed) {
                const map = try edit.objectOf(value);
                for ([_][]const u8{ "rotation", "shearY" }, turns) |field, k| if (k.? != 0) {
                    try map.put(m.arena, field, .{ .float = try tree.getFloat(c, field, 0) - k.? * 360 });
                };
                try m.lose(.@"transform.localWrap.rewritten", where, "absolute local offset moved by the turns the old wrap removes", .{});
            } else if (m.rewrite and m.rig and free) {
                const map = try edit.objectOf(value);
                try map.put(m.arena, marks.local_wrap, .{ .integer = @as(i64, @intFromBool(wrapped[0])) | @as(i64, @intFromBool(wrapped[1])) << 1 });
                try m.lose(.@"transform.localWrap.rewritten", where, "absolute local wrap rebuilt with helper bones", .{});
            } else try m.lose(.@"transform.localWrap.approximated", where, "absolute local mix below 1 with a difference past 180, {s}", .{reason});
        }
    }

    /// 4.2 decomposes applied transforms per inherit mode and negates the shear
    fn checkApplied(m: *Migration, doc: *ObjectMap, up_step: bool) Error!void {
        var parents: std.StringHashMapUnmanaged(?[]const u8) = .empty;
        for (try edit.arrayOf(doc, "bones")) |bone| try parents.put(m.arena, try tree.requireString(bone, "name"), try tree.getString(bone, "parent"));
        const constraints = try ordered(m.arena, doc, parents);
        var reported: std.StringHashMapUnmanaged(void) = .empty;
        for (constraints, 0..) |c, i| {
            if (c.kind == 0 or c.kind == 1 and c.local) continue;
            for (c.bones) |b| {
                if (reported.contains(b.string)) continue;
                if ((parents.get(b.string) orelse return error.Malformed) == null) continue;
                const loose = try notNormal(m.arena, doc, b.string);
                const skewed = c.shear or try sheared(m.arena, doc, b.string) or c.basis and try distorted(m.arena, doc, b.string, parents);
                if (!loose and !skewed) continue;
                var targets: std.ArrayList([]const u8) = .empty;
                var readers: std.ArrayList(Constraint) = .empty;
                for (constraints[i + 1 ..]) |later| switch (try reads(later, b.string, loose, parents)) {
                    .none => {},
                    .target => try targets.append(m.arena, later.name),
                    .recompose => try readers.append(m.arena, later),
                };
                if (readers.items.len == 0 and targets.items.len == 0) continue;
                try reported.put(m.arena, b.string, {});
                const exact = up_step and m.rewrite and loose and !skewed and !try distorted(m.arena, doc, b.string, parents) and try mirrorable(doc, constraints, c, b.string, if (readers.items.len == 1) readers.items[0].name else null);
                if (exact and readers.items.len == 0) {
                    try m.mirror(doc, c, b.string, targets.items, null, false);
                    try m.lose(.@"bone.applied.rewritten", try std.fmt.allocPrint(m.arena, "bones.{s}", .{b.string}), "later local transforms read a normal mirror bone with the world of the bone", .{});
                    continue;
                }
                if (exact and !m.rig and readers.items.len == 1 and try scaleKept(m.arena, doc, c, b.string, parents) and try copiable(doc, constraints, c, readers.items[0], targets.items, b.string)) {
                    try m.mirror(doc, c, b.string, targets.items, readers.items[0], false);
                    try m.lose(.@"bone.applied.rewritten", try std.fmt.allocPrint(m.arena, "bones.{s}", .{b.string}), "a mirror bone and a clone with the inherit of the bone copy the 4.1 applied transform onto it before its reader", .{});
                    continue;
                }
                if (up_step and m.rig and !loose and !c.shear and try steadyShear(m.arena, doc, b.string, parents) and targets.items.len == 0 and readers.items.len == 1 and try mirrorable(doc, constraints, c, b.string, readers.items[0].name) and try copiable(doc, constraints, c, readers.items[0], targets.items, b.string)) {
                    try m.mirror(doc, c, b.string, targets.items, readers.items[0], true);
                    try m.lose(.@"bone.applied.rewritten", try std.fmt.allocPrint(m.arena, "bones.{s}", .{b.string}), "a mirror bone and a shear copy with scale -1 give the bone the 4.1 applied shear before its reader", .{});
                    continue;
                }
                try m.lose(.@"bone.applied.approximated", try std.fmt.allocPrint(m.arena, "bones.{s}", .{b.string}), "world constrained bone read later, 4.1 and 4.2 decompose its applied transform differently", .{});
            }
        }
    }

    fn shift(m: *Migration, doc: *ObjectMap, from: i32, by: i32) Error!void {
        for (kinds) |kind| for (try edit.arrayOf(doc, kind)) |*other| {
            const at = try tree.getInt(other.*, "order", 0);
            if (at >= from) try (try edit.objectOf(other)).put(m.arena, "order", .{ .integer = at + by });
        };
    }

    /// Only this constraint holds the bone and its order is unique and in range
    fn mirrorable(doc: *ObjectMap, constraints: []const Constraint, c: Constraint, bone: []const u8, reader: ?[]const u8) Error!bool {
        if (c.skin or try tree.getBool(try boneOf(doc, bone), "skin", false)) return false;
        for (constraints) |other| {
            if (other.kind == c.kind and std.mem.eql(u8, other.name, c.name)) continue;
            if (other.order == c.order) return false;
            if (reader != null and std.mem.eql(u8, other.name, reader.?)) continue;
            for (other.bones) |b| if (std.mem.eql(u8, b.string, bone)) return false;
        }
        for (c.bones) |b| if (!std.mem.eql(u8, b.string, bone)) return false;
        return c.order >= 0 and c.order < constraints.len;
    }

    /// Own scales and the ones above stay off 0, and the constraint adds no scale or takes it from such a source
    fn scaleKept(arena: std.mem.Allocator, doc: *ObjectMap, c: Constraint, name: []const u8, parents: std.StringHashMapUnmanaged(?[]const u8)) Error!bool {
        if (!try scaleSigned(arena, doc, name)) return false;
        var ancestor = parents.get(name) orelse return error.Malformed;
        while (ancestor) |a| : (ancestor = parents.get(a) orelse return error.Malformed) {
            if (!try scaleSigned(arena, doc, a)) return false;
        }
        if (c.kind != 1) return false;
        for (try edit.arrayOf(doc, "transform")) |value| {
            if (!std.mem.eql(u8, try tree.requireString(value, "name"), c.name)) continue;
            const lists = try keyLists(arena, doc, &.{ "transform", c.name });
            for ([_][]const u8{ "mixScaleX", "mixScaleY" }, 0..) |field, i| {
                const fallback: f32 = if (i == 1) try tree.getFloat(value, "mixScaleX", 1) else 1;
                var mix: Range = .of(try tree.getFloat(value, field, fallback));
                try mix.keys(lists, field, 1, 3 + i);
                if (mix.min != 0 or mix.max != 0) return scaleSigned(arena, doc, c.target orelse return error.Malformed);
            }
            return true;
        }
        return error.Malformed;
    }

    /// Setup, keys and handles of both scales stay on one side of 0
    fn scaleSigned(arena: std.mem.Allocator, doc: *ObjectMap, name: []const u8) Error!bool {
        const bone = try boneOf(doc, name);
        var x: Range = .of(try tree.getFloat(bone, "scaleX", 1));
        var y: Range = .of(try tree.getFloat(bone, "scaleY", 1));
        try x.keys(try keyLists(arena, doc, &.{ "bones", name, "scale" }), "x", 1, 0);
        try y.keys(try keyLists(arena, doc, &.{ "bones", name, "scale" }), "y", 1, 1);
        try x.keys(try keyLists(arena, doc, &.{ "bones", name, "scalex" }), "value", 1, 0);
        try y.keys(try keyLists(arena, doc, &.{ "bones", name, "scaley" }), "value", 1, 0);
        return (x.min > 0 or x.max < 0) and (y.min > 0 or y.max < 0);
    }

    /// Constant shear below a parent chain of similarities, positive scales, no keys on any of them
    fn steadyShear(arena: std.mem.Allocator, doc: *ObjectMap, name: []const u8, parents: std.StringHashMapUnmanaged(?[]const u8)) Error!bool {
        const bone = try boneOf(doc, name);
        if (try tree.getFloat(bone, "shearX", 0) != 0 or try tree.getFloat(bone, "scaleX", 1) <= 0 or try tree.getFloat(bone, "scaleY", 1) <= 0) return false;
        for ([_][]const u8{ "shear", "shearx", "sheary", "scale", "scalex", "scaley" }) |t| {
            if ((try keyLists(arena, doc, &.{ "bones", name, t })).len > 0) return false;
        }
        var ancestor = parents.get(name) orelse return error.Malformed;
        while (ancestor) |a| : (ancestor = parents.get(a) orelse return error.Malformed) {
            if (try distorted(arena, doc, a, parents)) return false;
        }
        return true;
    }

    /// One reader that never skips, after the readers of the target, with room for the copies
    fn copiable(doc: *ObjectMap, constraints: []const Constraint, c: Constraint, reader: Constraint, targets: []const []const u8, bone: []const u8) Error!bool {
        if (reader.skin or reader.order <= c.order or inheritKeyed(doc, bone) catch true) return false;
        const direct = for (reader.bones) |b| {
            if (std.mem.eql(u8, b.string, bone)) break true;
        } else false;
        if (direct) {
            if (!reader.always or reader.kind == 2 or reader.kind == 0 and reader.bones.len != 1) return false;
            if (reader.kind == 1 and (!reader.local or std.mem.eql(u8, reader.target.?, bone))) return false;
        }
        for (constraints) |other| for (targets) |t| {
            if (std.mem.eql(u8, other.name, t) and other.order > reader.order) return false;
        };
        return true;
    }

    /// Normal mirror bone with the world of the bone, and with a reader a clone of the bone and copies before it
    fn mirror(m: *Migration, doc: *ObjectMap, c: Constraint, bone: []const u8, targets: []const []const u8, reader: ?Constraint, flip: bool) Error!void {
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (kinds) |kind| for (try edit.arrayOf(doc, kind)) |other| try names.put(m.arena, try tree.requireString(other, "name"), {});
        var bone_names: std.StringHashMapUnmanaged(void) = .empty;
        for (try edit.arrayOf(doc, "bones")) |b| try bone_names.put(m.arena, try tree.requireString(b, "name"), {});
        const source = try boneOf(doc, bone);
        const parent = try tree.getString(source, "parent") orelse return error.Malformed;
        const slots: i32 = if (reader != null and !flip) 2 else 1;
        try m.shift(doc, c.order + 1, slots);
        var reader_order: i32 = 0;
        if (reader) |r| {
            reader_order = r.order + slots;
            try m.shift(doc, reader_order, if (flip) 1 else 3);
        }
        const mirror_name = try fresh(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "spine-converter/{s}-applied", .{bone}));
        try bone_names.put(m.arena, mirror_name, {});
        var plain: ObjectMap = .empty;
        try plain.put(m.arena, "name", .{ .string = mirror_name });
        try plain.put(m.arena, "parent", .{ .string = parent });
        try (try edit.childValue(doc, "bones") orelse return error.Malformed).array.append(.{ .object = plain });
        try m.worldCopy(doc, &names, bone, mirror_name, c.order + 1);
        for (try edit.arrayOf(doc, "transform")) |*value| {
            const name = try tree.requireString(value.*, "name");
            for (targets) |t| if (std.mem.eql(u8, t, name)) try (try edit.objectOf(value)).put(m.arena, "target", .{ .string = mirror_name });
        }
        if (reader == null) return;
        if (flip) {
            try m.localCopy(doc, &names, bone, mirror_name, reader_order, .{ 0, 0, 0, 0, 0, 1 }, false);
            const list = try m.listOf(doc, "transform");
            try (try edit.objectOf(&list.items[list.items.len - 1])).put(m.arena, marks.applied_flip, .{ .float = try tree.getFloat(source, "shearY", 0) });
            return;
        }
        const clone_name = try fresh(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "spine-converter/{s}-inherit", .{bone}));
        var clone = (try edit.clone(m.arena, source)).object;
        try clone.put(m.arena, "name", .{ .string = clone_name });
        for ([_][]const u8{ "color", "icon", "visible", "skin" }) |key| _ = clone.orderedRemove(key);
        try (try edit.childValue(doc, "bones") orelse return error.Malformed).array.append(.{ .object = clone });
        if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |*animation| {
            const timelines = try edit.childOf(try edit.objectOf(animation), "bones") orelse continue;
            if (timelines.get(bone)) |t| try timelines.put(m.arena, clone_name, try edit.clone(m.arena, t));
        };
        try m.worldCopy(doc, &names, bone, clone_name, c.order + 2);
        // the absolute scale copy leaves the ratio of the scales on the clone, the multiplying copy restores the scale
        try m.localCopy(doc, &names, clone_name, mirror_name, reader_order, .{ 0, 0, 0, 1, 1, 0 }, false);
        try m.localCopy(doc, &names, bone, mirror_name, reader_order + 1, .{ 1, 1, 1, 0, 0, 1 }, false);
        try m.localCopy(doc, &names, bone, clone_name, reader_order + 2, .{ 0, 0, 0, 1, 1, 0 }, true);
    }

    fn worldCopy(m: *Migration, doc: *ObjectMap, names: *std.StringHashMapUnmanaged(void), source: []const u8, bone: []const u8, order: i32) Error!void {
        try m.localCopy(doc, names, bone, source, order, .{ 1, 1, 1, 1, 1, 1 }, null);
    }

    /// Transform constraint on a bone, world when relative is null
    fn localCopy(m: *Migration, doc: *ObjectMap, names: *std.StringHashMapUnmanaged(void), bone: []const u8, source: []const u8, order: i32, mix: [6]f32, relative: ?bool) Error!void {
        var copy: ObjectMap = .empty;
        const name = try fresh(m.arena, names, try std.fmt.allocPrint(m.arena, "spine-converter/{s}-copy", .{bone}));
        try names.put(m.arena, name, {});
        try copy.put(m.arena, "name", .{ .string = name });
        try copy.put(m.arena, "order", .{ .integer = order });
        var list = tree.array(m.arena);
        try list.append(.{ .string = bone });
        try copy.put(m.arena, "bones", .{ .array = list });
        try copy.put(m.arena, "target", .{ .string = source });
        if (relative) |r| {
            try copy.put(m.arena, "local", .{ .bool = true });
            if (r) try copy.put(m.arena, "relative", .{ .bool = true });
        }
        for ([_][]const u8{ "mixRotate", "mixX", "mixY", "mixScaleX", "mixScaleY", "mixShearY" }, mix) |field, value| {
            if (!std.mem.eql(u8, field, "mixScaleY") or value != mix[3]) try copy.put(m.arena, field, .{ .float = value });
        }
        try (try m.listOf(doc, "transform")).append(.{ .object = copy });
    }

    /// 4.2 skips two bone IK unless inherit is normal
    fn checkSkip(m: *Migration, doc: *ObjectMap, down_step: bool) Error!void {
        for (try edit.arrayOf(doc, "ik")) |*value| {
            const bones = try tree.getArray(value.*, "bones");
            if (bones.len != 2) continue;
            for (bones) |b| if (b != .string) return error.Malformed;
            const c = try edit.objectOf(value);
            const name = try tree.requireString(value.*, "name");
            var mix: Range = .of(try edit.float(c, "mix", 1));
            try mix.keys(try keyLists(m.arena, doc, &.{ "ik", name }), "mix", 1, 0);
            if (mix.min == 0 and mix.max == 0) continue;
            if (!try notNormal(m.arena, doc, bones[0].string) and !try notNormal(m.arena, doc, bones[1].string)) continue;
            const where = try std.fmt.allocPrint(m.arena, "ik.{s}", .{name});
            const keyed = try inheritKeyed(doc, bones[0].string) or try inheritKeyed(doc, bones[1].string);
            if (!down_step and m.rewrite and try m.childProxied(doc, value.*)) {
                try m.childRig(doc, value);
                try m.lose(.@"ik.skip.rewritten", where, "the IK solves a normal clone of the child and copies its rotation and y back", .{});
                continue;
            }
            if (!down_step or !m.rewrite or keyed) {
                try m.report.add(.{
                    .code = .@"ik.skip.approximated",
                    .step = m.step,
                    .path = where,
                    .message = "two bone IK on a bone with inherit other than normal, skipped from 4.2",
                    .remedy = if (down_step) .none else .runtime,
                });
                continue;
            }
            try c.put(m.arena, "mix", .{ .float = 0 });
            if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |*animation| {
                const timelines = try edit.childOf(try edit.objectOf(animation), "ik") orelse continue;
                _ = timelines.orderedRemove(name);
            };
            try m.lose(.@"ik.skip.rewritten", where, "two bone IK skipped from 4.2 gets mix 0 and loses its timelines", .{});
        }
    }

    /// Only the child is not normal and nothing else moves it
    fn childProxied(m: *Migration, doc: *ObjectMap, c: Value) Error!bool {
        const bones = try tree.getArray(c, "bones");
        if (try notNormal(m.arena, doc, bones[0].string)) return false;
        const child = bones[1].string;
        if (try tree.getBool(try boneOf(doc, child), "skin", false)) return false;
        const own = try tree.requireString(c, "name");
        const order = try tree.getInt(c, "order", 0);
        var count: i64 = 0;
        var same: usize = 0;
        for (kinds) |kind| for (try edit.arrayOf(doc, kind)) |other| {
            count += 1;
            if (try tree.getInt(other, "order", 0) == order) same += 1;
            if (std.mem.eql(u8, kind, "ik") and std.mem.eql(u8, try tree.requireString(other, "name"), own)) continue;
            for (try tree.getArray(other, "bones")) |b| if (b == .string and std.mem.eql(u8, b.string, child)) return false;
        };
        // the copy runs right after the IK only with an order of its own
        return order >= 0 and order < count and same == 1;
    }

    /// Normal clone of the child solved by the IK, its rotation and y copied back
    fn childRig(m: *Migration, doc: *ObjectMap, value: *Value) Error!void {
        const c = try edit.objectOf(value);
        const ik = try tree.requireString(value.*, "name");
        const bones = try edit.arrayOf(c, "bones");
        const child = bones[1].string;
        const order = try tree.getInt(value.*, "order", 0);
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (kinds) |kind| for (try edit.arrayOf(doc, kind)) |*other| {
            try names.put(m.arena, try tree.requireString(other.*, "name"), {});
            const at = try tree.getInt(other.*, "order", 0);
            if (at > order) try (try edit.objectOf(other)).put(m.arena, "order", .{ .integer = at + 1 });
        };
        var bone_names: std.StringHashMapUnmanaged(void) = .empty;
        for (try edit.arrayOf(doc, "bones")) |b| try bone_names.put(m.arena, try tree.requireString(b, "name"), {});
        const helper = try fresh(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "spine-converter/{s}-child", .{ik}));
        var clone = (try edit.clone(m.arena, try boneOf(doc, child))).object;
        try clone.put(m.arena, "name", .{ .string = helper });
        for ([_][]const u8{ "transform", "inherit", "color", "icon", "visible", "skin" }) |key| _ = clone.orderedRemove(key);
        try (try edit.childValue(doc, "bones") orelse return error.Malformed).array.append(.{ .object = clone });
        if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |*animation| {
            const timelines = try edit.childOf(try edit.objectOf(animation), "bones") orelse continue;
            if (timelines.get(child)) |t| try timelines.put(m.arena, helper, try edit.clone(m.arena, t));
        };
        bones[1] = .{ .string = helper };
        const name = try fresh(m.arena, &names, try std.fmt.allocPrint(m.arena, "{s}-child", .{ik}));
        var copy: ObjectMap = .empty;
        try copy.put(m.arena, "name", .{ .string = name });
        try copy.put(m.arena, "order", .{ .integer = order + 1 });
        const skin = try tree.getBool(value.*, "skin", false);
        if (skin) try copy.put(m.arena, "skin", .{ .bool = true });
        var list = tree.array(m.arena);
        try list.append(.{ .string = child });
        try copy.put(m.arena, "bones", .{ .array = list });
        try copy.put(m.arena, "target", .{ .string = helper });
        try copy.put(m.arena, "local", .{ .bool = true });
        for ([_][]const u8{ "mixRotate", "mixX", "mixY", "mixScaleX", "mixScaleY", "mixShearY" }, [_]f32{ 1, 0, 1, 0, 0, 0 }) |field, mix| {
            try copy.put(m.arena, field, .{ .float = mix });
        }
        try (try m.listOf(doc, "transform")).append(.{ .object = copy });
        // a skin bound IK gets a copy bound to the same skins
        if (skin) for (try edit.arrayOf(doc, "skins")) |*s| {
            const map = try edit.objectOf(s);
            const held = for (try tree.getArray(s.*, "ik")) |n| {
                if (n == .string and std.mem.eql(u8, n.string, ik)) break true;
            } else false;
            if (held) try (try m.listOf(map, "transform")).append(.{ .string = name });
        };
    }

    fn listOf(m: *Migration, map: *ObjectMap, key: []const u8) Error!*std.json.Array {
        const entry = try map.getOrPut(m.arena, key);
        if (!entry.found_existing or entry.value_ptr.* == .null) entry.value_ptr.* = .{ .array = tree.array(m.arena) };
        if (entry.value_ptr.* != .array) return error.Malformed;
        return &entry.value_ptr.array;
    }

    /// Drops physics and renumbers the remaining constraints
    fn downPhysics(m: *Migration, doc: *ObjectMap) Error!void {
        if (edit.take(doc, "physics")) |physics| {
            if (physics != .array and physics != .null) return error.Malformed;
            if (physics == .array) for (physics.array.items) |c| {
                const name = try tree.getString(c, "name") orelse "";
                try m.lose(.@"physics.dropped", try std.fmt.allocPrint(m.arena, "physics.{s}", .{name}), "physics constraint", .{});
            };
        }
        const Entry = struct { order: i32, kind: usize, map: *ObjectMap };
        var entries: std.ArrayList(Entry) = .empty;
        for (kinds[0..3], 0..) |kind, k| {
            for (try edit.arrayOf(doc, kind)) |*c| {
                try entries.append(m.arena, .{ .order = try tree.getInt(c.*, "order", 0), .kind = k, .map = try edit.objectOf(c) });
            }
        }
        std.sort.block(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.order < b.order or a.order == b.order and a.kind < b.kind;
            }
        }.lessThan);
        // 4.1 skips constraints whose order reaches the constraint count
        for (entries.items, 0..) |e, i| {
            _ = e.map.orderedRemove("order");
            if (i > 0) try e.map.put(m.arena, "order", .{ .integer = @intCast(i) });
        }
    }

    fn dropKeys(m: *Migration, map: *ObjectMap, list: []const u8, keys: []const Dropped) Error!void {
        for (keys) |entry| {
            const key, const code = entry;
            if (edit.take(map, key) == null) continue;
            const name = try tree.getString(.{ .object = map.* }, "name") orelse "";
            try m.lose(code, try std.fmt.allocPrint(m.arena, "{s}.{s}.{s}", .{ list, name, key }), "{s} has no 4.1 equivalent", .{key});
        }
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

const Constraint = struct {
    kind: usize,
    name: []const u8,
    order: i32,
    skin: bool = false,
    /// Some mix other than 0
    live: bool = true,
    /// A mix of one sign in setup, keys and handles, so it never skips
    always: bool = false,
    /// Local transform reading rotation or scale of its target
    reads_pose: bool = false,
    /// Local transform reading the shear of its target
    reads_shear: bool = false,
    bones: []const Value,
    target: ?[]const u8 = null,
    local: bool = false,
    /// Positive shear mix with an offset or distorted target
    shear: bool = false,
    /// Some mix can change the world basis
    basis: bool = false,
};

fn ordered(arena: std.mem.Allocator, doc: *ObjectMap, parents: std.StringHashMapUnmanaged(?[]const u8)) Error![]Constraint {
    var out: std.ArrayList(Constraint) = .empty;
    for (kinds[0..3], 0..) |list, kind| for (try edit.arrayOf(doc, list)) |c| {
        const bones = try tree.getArray(c, "bones");
        for (bones) |b| if (b != .string) return error.Malformed;
        try out.append(arena, .{
            .kind = kind,
            .name = try tree.requireString(c, "name"),
            .order = try tree.getInt(c, "order", 0),
            .skin = try tree.getBool(c, "skin", false),
            .bones = bones,
            .target = if (kind == 1) try tree.getString(c, "target") else null,
            .local = kind == 1 and try tree.getBool(c, "local", false),
        });
        const last = &out.items[out.items.len - 1];
        try mixes(arena, doc, c, kind, last);
        if (kind != 0 and !last.local) last.basis = try basis(arena, doc, c, kind);
        if (kind != 1 or last.local) continue;
        var mix: Range = .of(try tree.getFloat(c, "mixShearY", 1));
        try mix.keys(try keyLists(arena, doc, &.{ "transform", try tree.requireString(c, "name") }), "mixShearY", 1, 5);
        last.shear = mix.max > 0 and (try tree.getFloat(c, "shearY", 0) != 0 or try distorted(arena, doc, last.target orelse return error.Malformed, parents));
    };
    std.sort.block(Constraint, out.items, {}, struct {
        fn lessThan(_: void, a: Constraint, b: Constraint) bool {
            return a.order < b.order;
        }
    }.lessThan);
    return out.items;
}

/// Rotate, scale or shear mix other than 0
fn basis(arena: std.mem.Allocator, doc: *ObjectMap, c: Value, kind: usize) Error!bool {
    const name = try tree.requireString(c, "name");
    const lists = try keyLists(arena, doc, if (kind == 1) &.{ "transform", name } else &.{ "path", name, "mix" });
    const fields: []const struct { []const u8, usize } = if (kind == 1) &.{ .{ "mixRotate", 0 }, .{ "mixScaleX", 3 }, .{ "mixScaleY", 4 }, .{ "mixShearY", 5 } } else &.{.{ "mixRotate", 0 }};
    for (fields) |entry| {
        const field, const channel = entry;
        const scale_y = std.mem.eql(u8, field, "mixScaleY");
        var mix: Range = .of(try tree.getFloat(c, field, if (scale_y) try tree.getFloat(c, "mixScaleX", 1) else 1));
        try mix.keys(lists, field, if (scale_y) 0 else 1, channel);
        if (mix.min != 0 or mix.max != 0) return true;
    }
    return false;
}

/// Mix live, and what a local transform takes from its target
fn mixes(arena: std.mem.Allocator, doc: *ObjectMap, c: Value, kind: usize, out: *Constraint) Error!void {
    const name = out.name;
    if (kind == 0) {
        var mix: Range = .of(try tree.getFloat(c, "mix", 1));
        try mix.keys(try keyLists(arena, doc, &.{ "ik", name }), "mix", 1, 0);
        out.live = mix.min != 0 or mix.max != 0;
        out.always = mix.min > 0 or mix.max < 0;
        return;
    }
    const lists = try keyLists(arena, doc, if (kind == 1) &.{ "transform", name } else &.{ "path", name, "mix" });
    const fields = [_][]const u8{ "mixRotate", "mixX", "mixY", "mixScaleX", "mixScaleY", "mixShearY" };
    out.live = false;
    for (fields[0..if (kind == 1) fields.len else 3], 0..) |field, channel| {
        const fallback: f32 = if (channel == 2) try tree.getFloat(c, "mixX", 1) else if (channel == 4) try tree.getFloat(c, "mixScaleX", 1) else 1;
        var mix: Range = .of(try tree.getFloat(c, field, fallback));
        try mix.keys(lists, field, 1, channel);
        if (mix.min == 0 and mix.max == 0) continue;
        out.live = true;
        if (mix.min > 0 or mix.max < 0) out.always = true;
        if (channel == 0 or channel == 3 or channel == 4) out.reads_pose = true;
        if (channel == 5) out.reads_shear = true;
    }
}

const Read = enum { none, target, recompose };

/// How a later constraint takes the applied transform of a bone, an ancestor constraint recomposes it
fn reads(later: Constraint, bone: []const u8, loose: bool, parents: std.StringHashMapUnmanaged(?[]const u8)) Error!Read {
    for (later.bones, 0..) |b, i| {
        var ancestor = parents.get(bone) orelse return error.Malformed;
        while (ancestor) |a| : (ancestor = parents.get(a) orelse return error.Malformed) {
            if (std.mem.eql(u8, a, b.string)) return .recompose;
        }
        if (!later.live) continue;
        if (later.kind == 0 and std.mem.eql(u8, b.string, bone) and (loose or later.bones.len == 1 or i == 1)) return .recompose;
        if (later.local and std.mem.eql(u8, b.string, bone)) return .recompose;
    }
    if (later.live and later.local and std.mem.eql(u8, later.target.?, bone) and (later.reads_shear or loose and later.reads_pose)) return .target;
    return .none;
}

fn boneOf(doc: *ObjectMap, name: []const u8) Error!Value {
    for (try edit.arrayOf(doc, "bones")) |bone| {
        if (std.mem.eql(u8, try tree.requireString(bone, "name"), name)) return bone;
    }
    return error.Malformed;
}

/// 4.1 names the inherit key transform
fn notNormal(arena: std.mem.Allocator, doc: *ObjectMap, name: []const u8) Error!bool {
    const bone = try boneOf(doc, name);
    const setup = try tree.getString(bone, "inherit") orelse try tree.getString(bone, "transform") orelse "normal";
    if (!std.mem.eql(u8, setup, "normal")) return true;
    for (try keyLists(arena, doc, &.{ "bones", name, "inherit" })) |list| for (list) |key| {
        if (!std.mem.eql(u8, try tree.getString(key, "inherit") orelse "normal", "normal")) return true;
    };
    return false;
}

fn fresh(arena: std.mem.Allocator, taken: *std.StringHashMapUnmanaged(void), base: []const u8) Error![]const u8 {
    if (!taken.contains(base)) return base;
    var i: usize = 2;
    while (true) : (i += 1) {
        const name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, i });
        if (!taken.contains(name)) return name;
    }
}

fn inheritKeyed(doc: *ObjectMap, name: []const u8) Error!bool {
    const animations = try edit.childOf(doc, "animations") orelse return false;
    for (animations.values()) |animation| {
        if (tree.get(tree.get(tree.get(animation, "bones") orelse continue, name) orelse continue, "inherit") != null) return true;
    }
    return false;
}

/// Sheared or under an ancestor that is no similarity
fn distorted(arena: std.mem.Allocator, doc: *ObjectMap, name: []const u8, parents: std.StringHashMapUnmanaged(?[]const u8)) Error!bool {
    if (try sheared(arena, doc, name)) return true;
    var ancestor = parents.get(name) orelse return error.Malformed;
    while (ancestor) |a| : (ancestor = parents.get(a) orelse return error.Malformed) {
        const bone = try boneOf(doc, a);
        if (try tree.getFloat(bone, "scaleX", 1) != try tree.getFloat(bone, "scaleY", 1) or try sheared(arena, doc, a)) return true;
        for ([_][]const u8{ "scale", "scalex", "scaley" }) |t| {
            if ((try keyLists(arena, doc, &.{ "bones", a, t })).len > 0) return true;
        }
    }
    return false;
}

fn sheared(arena: std.mem.Allocator, doc: *ObjectMap, name: []const u8) Error!bool {
    const bone = try boneOf(doc, name);
    var x: Range = .of(try tree.getFloat(bone, "shearX", 0));
    var y: Range = .of(try tree.getFloat(bone, "shearY", 0));
    try x.keys(try keyLists(arena, doc, &.{ "bones", name, "shear" }), "x", 0, 0);
    try y.keys(try keyLists(arena, doc, &.{ "bones", name, "shear" }), "y", 0, 1);
    try x.keys(try keyLists(arena, doc, &.{ "bones", name, "shearx" }), "value", 0, 0);
    try y.keys(try keyLists(arena, doc, &.{ "bones", name, "sheary" }), "value", 0, 0);
    return x.min != 0 or x.max != 0 or y.min != 0 or y.max != 0;
}

/// Whether physics or an earlier constraint moves the source or a bone
fn constrainedBefore(doc: *ObjectMap, constraints: []const Constraint, order: i32, target: []const u8, bones: []const Value) Error!bool {
    for (constraints) |other| if (other.order < order) for (other.bones) |b| {
        if (named(b.string, target, bones)) return true;
    };
    for (try edit.arrayOf(doc, "physics")) |p| if (named(try tree.requireString(p, "bone"), target, bones)) return true;
    return false;
}

fn named(bone: []const u8, target: []const u8, bones: []const Value) bool {
    if (std.mem.eql(u8, bone, target)) return true;
    for (bones) |b| if (std.mem.eql(u8, b.string, bone)) return true;
    return false;
}

fn angle(arena: std.mem.Allocator, doc: *ObjectMap, name: []const u8, rotate: bool) Error!Range {
    const bone = try boneOf(doc, name);
    var r: Range = .of(0);
    if (rotate) {
        try r.keys(try keyLists(arena, doc, &.{ "bones", name, "rotate" }), "value", 0, 0);
    } else {
        try r.keys(try keyLists(arena, doc, &.{ "bones", name, "shear" }), "y", 0, 1);
        try r.keys(try keyLists(arena, doc, &.{ "bones", name, "sheary" }), "value", 0, 0);
    }
    const setup = try tree.getFloat(bone, if (rotate) "rotation" else "shearY", 0);
    return .{ .min = setup + r.min, .max = setup + r.max, .partial = r.partial };
}

fn keyLists(arena: std.mem.Allocator, doc: *ObjectMap, path: []const []const u8) Error![]const []Value {
    var out: std.ArrayList([]Value) = .empty;
    const animations = try edit.childOf(doc, "animations") orelse return out.items;
    for (animations.values()) |animation| {
        var v = animation;
        const keys: ?Value = for (path) |p| {
            v = tree.get(v, p) orelse break null;
        } else v;
        const list = keys orelse continue;
        if (list != .array) return error.Malformed;
        try out.append(arena, list.array.items);
    }
    return out.items;
}

const Range = struct {
    min: f32,
    max: f32,
    /// Reaches a value other than 0 and 1
    partial: bool,

    fn of(setup: f32) Range {
        return .{ .min = setup, .max = setup, .partial = setup != 0 and setup != 1 };
    }

    fn add(r: *Range, v: f32) void {
        r.min = @min(r.min, v);
        r.max = @max(r.max, v);
        if (v != 0 and v != 1) r.partial = true;
    }

    fn keys(r: *Range, lists: []const []Value, field: []const u8, default: f32, channel: usize) Error!void {
        for (lists) |list| {
            var previous: ?f32 = null;
            for (list) |key| {
                const v = try tree.getFloat(key, field, default);
                r.add(v);
                if (previous) |p| if (p != v) {
                    r.partial = true;
                };
                const curve = tree.get(key, "curve") orelse .null;
                previous = if (curve == .string) null else v;
                if (curve != .array) continue;
                if (curve.array.items.len < channel * 4 + 4) return error.Malformed;
                r.add(try tree.number(curve.array.items[channel * 4 + 1]));
                r.add(try tree.number(curve.array.items[channel * 4 + 3]));
            }
        }
    }
};

test "physics down renumbers constraints" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Report = .{ .arena = a };
    const input =
        \\{"bones":[{"name":"b","inherit":"noScale"}],
        \\"ik":[{"name":"i","order":2}],"physics":[{"name":"p","order":1}],"transform":[{"name":"t","target":"b"}]}
    ;
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    try down(a, &root, &report, .{});
    try std.testing.expectEqual(1, root.object.get("ik").?.array.items[0].object.get("order").?.integer);
    try std.testing.expect(root.object.get("transform").?.array.items[0].object.get("order") == null);
    try std.testing.expectEqualStrings("noScale", root.object.get("bones").?.array.items[0].object.get("transform").?.string);
    try std.testing.expectEqual(1, report.entries.items.len);

    try up(a, &root, &report, .{});
    try std.testing.expectEqualStrings("noScale", root.object.get("bones").?.array.items[0].object.get("inherit").?.string);
}

fn testCodes(a: std.mem.Allocator, input: []const u8, step: enum { early, up, down }, flags: Flags) !struct { Value, []Report.Code } {
    var report: Report = .{ .arena = a };
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    switch (step) {
        .early => try early(a, &root, &report, .{ .major = 4, .minor = 2 }, flags),
        .up => try up(a, &root, &report, flags),
        .down => try down(a, &root, &report, flags),
    }
    const out = try a.alloc(Report.Code, report.entries.items.len);
    for (out, report.entries.items) |*c, e| c.* = e.code;
    return .{ root, out };
}

test "absolute local difference past 180" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"skeleton":{"spine":"VERSION"},"bones":[{"name":"root"},{"name":"t","parent":"root","rotation":100},{"name":"b","parent":"root","rotation":-90}],
        \\"transform":[{"name":"w","bones":["b"],"target":"t","local":true,"mixRotate":0.5},
        \\{"name":"r","bones":["b"],"target":"t","local":true,"relative":true,"mixRotate":0.5},
        \\{"name":"f","bones":["b"],"target":"t","local":true}]}
    ;
    _, const up_codes = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "VERSION", "4.1.20"), .up, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.localWrap.approximated"}, up_codes);
    _, const beta = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "VERSION", "4.2.56-beta"), .early, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.localWrap.approximated"}, beta);
    _, const beta_down = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "VERSION", "4.2.56-beta"), .down, .{});
    try std.testing.expectEqual(0, beta_down.len);
    _, const release = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "VERSION", "4.2.20"), .early, .{});
    try std.testing.expectEqual(0, release.len);
    _, const release_down = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "VERSION", "4.2.20"), .down, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.localWrap.approximated"}, release_down);
    _, const near = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "\"rotation\":-90", "\"rotation\":-70"), .up, .{});
    try std.testing.expectEqual(0, near.len);
    const old = try std.mem.replaceOwned(u8, a, input, "VERSION", "4.1.20");
    const root, const rewritten = try testCodes(a, old, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.localWrap.rewritten"}, rewritten);
    try std.testing.expectEqual(-360, try tree.getFloat(root.object.get("transform").?.array.items[0], "rotation", 0));
    _, const beta_rewritten = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "VERSION", "4.2.56-beta"), .early, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.localWrap.rewritten"}, beta_rewritten);
    const turning = try std.mem.replaceOwned(u8, a, old, "]}", "],\"animations\":{\"a\":{\"bones\":{\"t\":{\"rotate\":[{},{\"time\":1,\"value\":400}]}}}}}");
    _, const spread = try testCodes(a, turning, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.localWrap.approximated"}, spread);
    _, const after = try testCodes(a, try std.mem.replaceOwned(u8, a, old, "\"local\":true,\"mixRotate\":0.5}", "\"local\":true,\"mixRotate\":0.5,\"order\":1}"), .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.localWrap.approximated"}, after);
    const wrapped, const rigged = try testCodes(a, turning, .up, .{ .rewrite = true, .slider = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.localWrap.rewritten"}, rigged);
    try std.testing.expectEqual(1, wrapped.object.get("transform").?.array.items[0].object.get(marks.local_wrap).?.integer);
    _, const late = try testCodes(a, try std.mem.replaceOwned(u8, a, old, "\"local\":true,\"mixRotate\":0.5}", "\"local\":true,\"mixRotate\":0.5,\"order\":1}"), .up, .{ .rewrite = true, .slider = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.localWrap.approximated"}, late);
}

test "applied transform read after a world constraint" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, []const u8, []const u8, usize };
    for ([_]Case{
        .{ "{\"name\":\"b\",\"parent\":\"root\",\"transform\":\"noScale\"}", "", "\"ik\":[{\"name\":\"i\",\"order\":1,\"bones\":[\"b\"],\"target\":\"root\"}]", 1 },
        .{ "{\"name\":\"b\",\"parent\":\"root\",\"shearX\":5}", "", "\"ik\":[{\"name\":\"i\",\"order\":1,\"bones\":[\"b\"],\"target\":\"root\"}]", 1 },
        .{ "{\"name\":\"b\",\"parent\":\"root\"}", "", "\"ik\":[{\"name\":\"i\",\"order\":1,\"bones\":[\"b\"],\"target\":\"root\"}]", 0 },
        .{ "{\"name\":\"b\",\"parent\":\"root\",\"transform\":\"noScale\"}", "", "\"ik\":[{\"name\":\"i\",\"bones\":[\"b\"],\"target\":\"root\"}]", 0 },
        .{ "{\"name\":\"b\",\"parent\":\"root\",\"transform\":\"noScale\"}", "", "\"ik\":[{\"name\":\"i\",\"order\":1,\"bones\":[\"root\"],\"target\":\"root\"}]", 1 },
        .{ "{\"name\":\"p\",\"parent\":\"root\",\"scaleX\":2},{\"name\":\"b\",\"parent\":\"p\",\"rotation\":40}", ",\"mixRotate\":0,\"mixScaleX\":0,\"mixShearY\":0", "\"ik\":[{\"name\":\"i\",\"order\":1,\"bones\":[\"b\"],\"target\":\"root\"}]", 0 },
        .{ "{\"name\":\"p\",\"parent\":\"root\",\"scaleX\":2},{\"name\":\"b\",\"parent\":\"p\",\"rotation\":40}", ",\"mixRotate\":0.5,\"mixScaleX\":0,\"mixShearY\":0", "\"ik\":[{\"name\":\"i\",\"order\":1,\"bones\":[\"b\"],\"target\":\"root\"}]", 1 },
        .{ "{\"name\":\"b\",\"parent\":\"root\",\"shearY\":20}", ",\"mixRotate\":0,\"mixScaleX\":0,\"mixShearY\":0", "\"ik\":[{\"name\":\"i\",\"order\":1,\"bones\":[\"b\"],\"target\":\"root\"}]", 1 },
    }) |case| {
        const bone, const weights, const reader, const losses = case;
        const input = try std.fmt.allocPrint(a, "{{\"bones\":[{{\"name\":\"root\"}},{s}],\"transform\":[{{\"name\":\"t\",\"bones\":[\"b\"],\"target\":\"root\"{s}}}],{s}}}", .{ bone, weights, reader });
        _, const codes = try testCodes(a, input, .up, .{});
        try std.testing.expectEqual(losses, std.mem.count(Report.Code, codes, &.{.@"bone.applied.approximated"}));
    }
}

test "applied transform read by local transforms only" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root"},{"name":"b","parent":"root","transform":"noScale"},{"name":"h","parent":"root"}],
        \\"transform":[{"name":"t","bones":["b"],"target":"root","mixShearY":0},
        \\{"name":"l","order":1,"bones":["h"],"target":"b","local":true,"mixRotate":1,"mixX":0,"mixScaleX":0,"mixShearY":0}]}
    ;
    _, const reported = try testCodes(a, input, .up, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.applied.approximated"}, reported);
    const root, const rewritten = try testCodes(a, input, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.applied.rewritten"}, rewritten);
    const transforms = root.object.get("transform").?.array.items;
    try std.testing.expectEqual(3, transforms.len);
    try std.testing.expectEqualStrings("spine-converter/b-applied", try tree.requireString(transforms[1], "target"));
    const shear = try std.mem.replaceOwned(u8, a, input, "\"mixRotate\":1", "\"mixRotate\":0");
    _, const skipped = try testCodes(a, shear, .up, .{});
    try std.testing.expectEqual(0, skipped.len);
}

test "applied transform copied before its reader" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root"},{"name":"b","parent":"root","transform":"noScale"}],
        \\"transform":[{"name":"t","bones":["b"],"target":"root","mixShearY":0}],
        \\"ik":[{"name":"i","order":1,"bones":["b"],"target":"root","mix":0.5}]}
    ;
    const root, const rewritten = try testCodes(a, input, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.applied.rewritten"}, rewritten);
    try std.testing.expectEqual(6, root.object.get("transform").?.array.items.len);
    const keyed = try std.mem.replaceOwned(u8, a, input, "\"mix\":0.5}]}", "\"mix\":0.5}],\"animations\":{\"a\":{\"ik\":{\"i\":[{\"mix\":0},{\"time\":1,\"mix\":1}]}}}}");
    _, const skipped = try testCodes(a, keyed, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.applied.approximated"}, skipped);
    const zero = try std.mem.replaceOwned(u8, a, input, "\"mix\":0.5}]}", "\"mix\":0.5}],\"animations\":{\"a\":{\"bones\":{\"b\":{\"scale\":[{\"x\":1},{\"time\":1,\"x\":0}]}}}}}");
    _, const scaled = try testCodes(a, zero, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.applied.approximated"}, scaled);
    const mixed = try std.mem.replaceOwned(u8, a, input, "\"mixShearY\":0}", "\"mixShearY\":0,\"mixScaleX\":1}");
    _, const mixing = try testCodes(a, mixed, .up, .{ .rewrite = true });
    try std.testing.expectEqual(.@"bone.applied.rewritten", mixing[0]);
    const flat = try std.mem.replaceOwned(u8, a, mixed, "{\"name\":\"root\"}", "{\"name\":\"root\",\"scaleX\":0}");
    _, const flattened = try testCodes(a, flat, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.applied.approximated"}, flattened);
    const grown = try std.mem.replaceOwned(u8, a, mixed, "{\"name\":\"b\"", "{\"name\":\"s\",\"parent\":\"root\",\"scaleX\":-1,\"scaleY\":0},{\"name\":\"b\"");
    const retargeted = try std.mem.replaceOwned(u8, a, grown, "\"target\":\"root\",\"mixShearY\"", "\"target\":\"s\",\"mixShearY\"");
    _, const sourced = try testCodes(a, retargeted, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.applied.approximated"}, sourced);
    const skewed = try std.mem.replaceOwned(u8, a, input, "\"transform\":\"noScale\"", "\"shearY\":10");
    _, const normal = try testCodes(a, skewed, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.applied.approximated"}, normal);
    _, const rigged = try testCodes(a, skewed, .up, .{ .rewrite = true, .slider = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.applied.rewritten"}, rigged);
}

test "two bone IK skipped from 4.2" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root"},{"name":"p","parent":"root","inherit":"noScale"},{"name":"c","parent":"p"}],
        \\"ik":[{"name":"i","bones":["p","c"],"target":"root"}],"animations":{"a":{"ik":{"i":[{"mix":0.5}]}}}}
    ;
    _, const standard = try testCodes(a, input, .down, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"ik.skip.approximated"}, standard);
    const root, const rewritten = try testCodes(a, input, .down, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"ik.skip.rewritten"}, rewritten);
    try std.testing.expectEqual(0, try tree.getFloat(root.object.get("ik").?.array.items[0], "mix", 1));
    try std.testing.expect(root.object.get("animations").?.object.get("a").?.object.get("ik").?.object.get("i") == null);
    const keyed = try std.mem.replaceOwned(u8, a, input, "\"ik\":{\"i\"", "\"bones\":{\"c\":{\"inherit\":[{}]}},\"ik\":{\"i\"");
    _, const kept = try testCodes(a, keyed, .down, .{ .rewrite = true });
    try std.testing.expectEqual(.@"ik.skip.approximated", kept[0]);
    const old = try std.mem.replaceOwned(u8, a, input, "\"inherit\":\"noScale\"", "\"transform\":\"noScale\"");
    _, const up_codes = try testCodes(a, old, .up, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"ik.skip.approximated"}, up_codes);
}

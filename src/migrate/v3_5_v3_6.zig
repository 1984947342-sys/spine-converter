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

//! Spine 3.5 and 3.6 JSON, mapped by SkeletonJson.java of 3.5.51 and the 3.6 branch

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Report = @import("../Report.zig");
const Version = @import("../Version.zig");
const Flags = @import("../Document.zig").Flags;
const tree = @import("../binary/tree.zig");
const edit = @import("../edit.zig");
const marks = @import("marks.zig");
const spaces = @import("chain.zig");

pub const Error = error{ Malformed, OutOfMemory };

/// Owns 3.5 and 3.6 exports
pub fn early(arena: std.mem.Allocator, root: *Value, report: *Report, target: Version.Minor, flags: Flags) Error!void {
    const v = Version.ofRoot(root.*) orelse return;
    const doc = try edit.objectOf(root);
    var m: Migration = .{ .arena = arena, .report = report, .step = if (v.minor == 5) "3.5" else "3.6" };
    try m.indexDoc(doc);
    // 3.7 and 3.8 scale a fixed position, 3.6 and 4.0 do not
    if (target.major == 4) for (try edit.arrayOf(doc, "path")) |*c| try (try edit.objectOf(c)).put(arena, marks.position_unscaled, .{ .bool = true });
    if (v.minor == 5) {
        const reflect = Version.editor(v, .offset_reflect_35);
        if (reflect != .new) try m.offsetReflect(doc, reflect == .old and flags.rewrite, target.major == 4 and target.minor >= 3);
        // 3.5.02 and 3.5.03 betas turn the local matrix back by the parent angle
        if (Version.editor(v, .no_rotation_35) != .new) try m.noRotation(doc, flags.rewrite and v.patch >= 2 and target.major == 4 and target.minor >= 3);
        return;
    }
    const order = Version.editor(v, .reflect_order_36);
    if (order != .new) try m.reflection(doc, order == .old and flags.rewrite);
    // 3.7 reports every path start itself
    if (Version.editor(v, .path_epsilon_36) != .new and target.minor == 6) {
        for (try edit.arrayOf(doc, "path")) |*c| {
            const map = try edit.objectOf(c);
            if (try m.onPathStart(map)) try m.lose(.@"path.start.approximated", try m.path("path", map, "position"), "3.6 before 3.6.46 evaluates a curve start at 1e-4", .{});
        }
    }
    if (Version.editor(v, .zero_bone_36) != .new) try m.zeroBones(doc, Version.editor(v, .zero_bone_nan_36) != .new);
    const clip = Version.editor(v, .clip_vertices_36);
    if (clip != .new) try m.clipVertices(doc, clip == .old and flags.rewrite);
}

/// Keeps the document, 3.6 only adds data
pub fn up(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    // The patch reproduces 3.8 semantics only
    var m: Migration = .{ .arena = arena, .report = report, .step = "3.5-3.6" };
    const doc = try edit.objectOf(root);
    try m.indexDoc(doc);
    try m.reflection(doc, flags.rewrite);
    try m.check(doc, flags.target, flags.rewrite);
}

pub fn down(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "3.6-3.5" };
    const doc = try edit.objectOf(root);
    try m.indexDoc(doc);
    // old 3.6 editors pose these like 3.5
    if (Version.ofRoot(root.*)) |v| {
        if (Version.editor(v, .reflect_order_36) != .old) try m.reflection(doc, false);
        m.start_old = Version.editor(v, .path_epsilon_36) == .old;
    } else try m.reflection(doc, false);
    try m.check(doc, null, flags.rewrite);
    for (try edit.arrayOf(doc, "slots")) |*slot| {
        const map = try edit.objectOf(slot);
        if (edit.take(map, "dark") != null) try m.lose(.@"slot.dark.dropped", try m.path("slots", map, "dark"), "two color tint", .{});
    }
    for (try edit.arrayOf(doc, "transform")) |*c| {
        const map = try edit.objectOf(c);
        if (try edit.takeBool(map, "local")) try m.lose(.@"transform.local.dropped", try m.path("transform", map, "local"), "local transform constraint becomes world", .{});
        if (try edit.takeBool(map, "relative")) try m.lose(.@"transform.relative.dropped", try m.path("transform", map, "relative"), "relative transform constraint becomes absolute", .{});
    }

    var dropped: std.StringHashMapUnmanaged(void) = .empty;
    if (try edit.childOf(doc, "skins")) |skins| {
        var it = skins.iterator();
        while (it.next()) |skin| {
            var slots = (try edit.objectOf(skin.value_ptr)).iterator();
            while (slots.next()) |slot| {
                const attachments = try edit.objectOf(slot.value_ptr);
                var i: usize = 0;
                while (i < attachments.count()) {
                    const name = attachments.keys()[i];
                    const kind = try tree.getString(attachments.values()[i], "type") orelse "region";
                    const code: Report.Code = if (std.mem.eql(u8, kind, "clipping"))
                        .@"attachment.clipping.dropped"
                    else if (std.mem.eql(u8, kind, "point"))
                        .@"attachment.point.dropped"
                    else {
                        i += 1;
                        continue;
                    };
                    const key = try std.fmt.allocPrint(arena, "{s}.{s}.{s}", .{ skin.key_ptr.*, slot.key_ptr.*, name });
                    try dropped.put(arena, key, {});
                    try m.lose(code, try std.fmt.allocPrint(arena, "skins.{s}", .{key}), "{s} attachment", .{kind});
                    attachments.orderedRemoveAt(i);
                }
            }
        }
    }

    const animations = try edit.childOf(doc, "animations") orelse return;
    var it = animations.iterator();
    while (it.next()) |animation| {
        const map = try edit.objectOf(animation.value_ptr);
        var slots = try edit.timelinesOf(map, "slots");
        while (slots.next()) |slot| {
            const where = try std.fmt.allocPrint(arena, "animations.{s}.slots.{s}.twoColor", .{ animation.key_ptr.*, slot.key_ptr.* });
            try m.downTwoColor(try edit.objectOf(slot.value_ptr), where);
        }
        // 3.5 rejects deform of missing attachments
        var skins = try edit.timelinesOf(map, "deform");
        while (skins.next()) |skin| {
            var deform_slots = (try edit.objectOf(skin.value_ptr)).iterator();
            while (deform_slots.next()) |slot| {
                const timelines = try edit.objectOf(slot.value_ptr);
                var i: usize = 0;
                while (i < timelines.count()) {
                    const key = try std.fmt.allocPrint(arena, "{s}.{s}.{s}", .{ skin.key_ptr.*, slot.key_ptr.*, timelines.keys()[i] });
                    if (dropped.contains(key)) timelines.orderedRemoveAt(i) else i += 1;
                }
            }
        }
    }
}

const Migration = struct {
    arena: std.mem.Allocator,
    report: *Report,
    step: []const u8,
    bones: std.StringArrayHashMapUnmanaged(Value) = .empty,
    animations: ?*ObjectMap = null,
    /// Editor evaluates a curve start like 3.5
    start_old: bool = false,

    fn indexDoc(m: *Migration, doc: *ObjectMap) Error!void {
        for (try edit.arrayOf(doc, "bones")) |bone| try m.bones.put(m.arena, try tree.requireString(bone, "name"), bone);
        m.animations = try edit.childOf(doc, "animations");
    }

    /// Runtime changes both directions lose
    /// Path checks, a null target meaning 3.6 to 3.5
    fn check(m: *Migration, doc: *ObjectMap, target: ?Version.Minor, rewrite: bool) Error!void {
        const animations = m.animations;
        for (try edit.arrayOf(doc, "path")) |*c| {
            const map = try edit.objectOf(c);
            const name = try tree.getString(c.*, "name") orelse "";
            // 3.5 evaluates a curve start at 1e-4 and 3.6 at 1e-5
            if (!m.start_old and try m.onPathStart(map)) try m.lose(.@"path.start.approximated", try m.path("path", map, "position"), "path on its start", .{});
            const mode = try tree.getString(c.*, "spacingMode") orelse "length";
            const length = std.mem.eql(u8, mode, "length");
            const chain = std.mem.eql(u8, try tree.getString(c.*, "rotateMode") orelse "tangent", "chainScale");
            // 3.5 clamps length spacing at 0 like 4.3, 3.6 to 4.2 do not
            const latest = if (target) |t| t.major == 4 and t.minor >= 3 else false;
            if (length and latest) try map.put(m.arena, marks.length_clamped, .{ .bool = true });
            if (!length and !chain) continue;
            var spacing = try edit.float(map, "spacing", 0) != 0;
            var lowest = try edit.float(map, "spacing", 0);
            var bounded = true;
            if (animations) |list| for (list.values()) |animation| {
                const keys = tree.get(tree.get(tree.get(animation, "paths") orelse continue, name) orelse continue, "spacing") orelse continue;
                if (keys != .array) return error.Malformed;
                for (keys.array.items) |k| {
                    const v = try tree.getFloat(k, "spacing", 0);
                    spacing = spacing or v != 0;
                    lowest = @min(lowest, v);
                    bounded = bounded and try percentWithin(k);
                }
            };
            if (!spacing) continue;
            const where = try m.path("path", map, "spacing");
            const shortest = try spaces.shortest(doc, c.*);
            // 3.7 stops scaling chain scale percent spacing again, zero length bones get 0 until 4.0
            if (target) |t| if (!length and std.mem.eql(u8, mode, "percent") and (t.major == 4 or t.minor >= 7)) {
                if (t.major == 4 or shortest >= spaces.epsilon) {
                    try map.put(m.arena, marks.spacing_unscaled, .{ .bool = true });
                    continue;
                }
            };
            // 3.6 scales by the bone world scale and gives zero length bones 0
            const k = try spaces.constant(m.arena, doc, c.*);
            const clamp_free = latest or !length or bounded and lowest + (if (target == null) shortest else @as(f32, @floatCast(k orelse 0)) * shortest) >= 0;
            if (k == null or shortest < spaces.epsilon or !clamp_free) {
                try m.lose(.@"path.spacing.approximated", where, "spacing on scaled bones", .{});
                continue;
            }
            const factor = if (target == null) k.? else 1 / k.?;
            if (factor == 1) continue;
            if (!rewrite) {
                try m.lose(.@"path.spacing.approximated", where, "spacing on scaled bones", .{});
                continue;
            }
            try spaces.scaleSpacing(m.arena, doc, c, factor);
            try m.lose(.@"path.spacing.rewritten", where, "spacing scaled by the constant bone world scale", .{});
        }
    }

    /// 3.6 from 3.6.38 negates the parent axis before the shear
    fn reflection(m: *Migration, doc: *ObjectMap, rewrite: bool) Error!void {
        for (try edit.arrayOf(doc, "bones")) |*bone| {
            const map = try edit.objectOf(bone);
            const mode = try tree.getString(bone.*, "transform") orelse "normal";
            const name = try tree.getString(bone.*, "name") orelse "";
            if (!try m.sheared(name)) continue;
            if (std.mem.eql(u8, mode, "noScale") and try m.reflected(bone.*, false)) {
                const where = try m.path("bones", map, "transform");
                const parent = m.bones.get(try tree.requireString(bone.*, "parent")) orelse return error.Malformed;
                const steady = if (rewrite and !try m.constrained(doc, name)) try m.steadyReflection(doc, parent) else null;
                if (steady == null) {
                    try m.lose(.@"bone.reflection.approximated", where, "sheared noScale bone under a reflected parent", .{});
                } else if (steady.?) {
                    try m.negateShear(map, name);
                    try m.lose(.@"bone.reflection.rewritten", where, "shear negated under a parent that stays reflected", .{});
                }
            } else if (std.mem.eql(u8, mode, "noScaleOrReflection")) {
                try m.lose(.@"bone.flip.approximated", try m.path("bones", map, "transform"), "sheared noScaleOrReflection bone under a flipped skeleton", .{});
            }
        }
    }

    /// A constraint lists or reads the bone
    fn constrained(m: *Migration, doc: *ObjectMap, name: []const u8) Error!bool {
        _ = m;
        for ([_][]const u8{ "ik", "transform", "path" }) |kind| for (try edit.arrayOf(doc, kind)) |c| {
            if (std.mem.eql(u8, try tree.getString(c, "target") orelse "", name)) return true;
            for (try tree.getArray(c, "bones")) |b| if (b == .string and std.mem.eql(u8, b.string, name)) return true;
        };
        return false;
    }

    /// Reflecting the parent axis before the shear equals the old order with both shears negated
    fn negateShear(m: *Migration, bone: *ObjectMap, name: []const u8) Error!void {
        for ([_][]const u8{ "shearX", "shearY" }) |field| if (bone.get(field)) |v| try bone.put(m.arena, field, .{ .float = -try tree.number(v) });
        const animations = m.animations orelse return;
        for (animations.values()) |*animation| {
            const bones = try edit.childOf(try edit.objectOf(animation), "bones") orelse continue;
            const timelines = try edit.childOf(bones, name) orelse continue;
            const keys = timelines.getPtr("shear") orelse continue;
            for (try edit.keysOf(keys)) |*key| {
                const k = try edit.objectOf(key);
                for ([_][]const u8{ "x", "y" }) |field| if (k.get(field)) |v| try k.put(m.arena, field, .{ .float = -try tree.number(v) });
            }
        }
    }

    /// 3.5 before 3.5.09-beta adds offsets with a fixed sign
    fn offsetReflect(m: *Migration, doc: *ObjectMap, rewrite: bool, unsigned: bool) Error!void {
        for (try edit.arrayOf(doc, "transform")) |*c| {
            const map = try edit.objectOf(c);
            const target = m.bones.get(try tree.requireString(c.*, "target")) orelse return error.Malformed;
            const offset = try edit.float(map, "rotation", 0);
            const rotate = offset != 0 and try m.mixed(map, "transform", "", "rotateMix");
            const shear = try edit.float(map, "shearY", 0) != 0 and try m.mixed(map, "transform", "", "shearMix");
            if (!rotate and !shear) continue;
            const where = try m.path("transform", map, "rotation");
            const flip = "offset under a flipped skeleton";
            if (!try m.reflected(target, true)) {
                try m.lose(.@"transform.offsetFlip.approximated", where, flip, .{});
                continue;
            }
            const world = !try tree.getBool(c.*, "local", false) and !try tree.getBool(c.*, "relative", false);
            const steady = if (rewrite) try m.steadyReflection(doc, target) else null;
            if (steady) |negative| {
                if (negative) {
                    for ([_][]const u8{ "rotation", "shearY" }) |field| if (map.get(field)) |v| try map.put(m.arena, field, .{ .float = -try tree.number(v) });
                    try m.lose(.@"transform.offsetReflect.rewritten", where, "offsets negated for a target that stays reflected", .{});
                }
            } else if (rewrite and unsigned and world and !shear and @abs(offset) <= 180) {
                try map.put(m.arena, marks.offset_unsigned, .{ .bool = true });
                try m.lose(.@"transform.offsetReflect.rewritten", where, "rotation offset moved to the 4.3 mapping offset, which ignores reflection", .{});
            } else {
                try m.lose(.@"transform.offsetReflect.approximated", where, "offset on a reflected target", .{});
                continue;
            }
            try m.lose(.@"transform.offsetFlip.approximated", where, flip, .{});
        }
        const slots = try edit.arrayOf(doc, "slots");
        for (try edit.arrayOf(doc, "path")) |*c| {
            const map = try edit.objectOf(c);
            const offset = try edit.float(map, "rotation", 0);
            if (offset == 0 or !try m.mixed(map, "paths", "mix", "rotateMix")) continue;
            const target = try tree.requireString(c.*, "target");
            const slot = for (slots) |s| {
                if (std.mem.eql(u8, try tree.requireString(s, "name"), target)) break s;
            } else return error.Malformed;
            const bone = m.bones.get(try tree.requireString(slot, "bone")) orelse return error.Malformed;
            const where = try m.path("path", map, "rotation");
            if (try m.reflected(bone, true)) {
                const steady = if (rewrite) try m.steadyReflection(doc, bone) else null;
                if (steady == null) {
                    try m.lose(.@"path.offsetReflect.approximated", where, "rotation offset on a reflected path", .{});
                    continue;
                }
                if (steady.?) {
                    try map.put(m.arena, "rotation", .{ .float = -offset });
                    try m.lose(.@"path.offsetReflect.rewritten", where, "rotation offset negated for a path bone that stays reflected", .{});
                }
            }
            try m.lose(.@"path.offsetFlip.approximated", where, "rotation offset under a flipped skeleton", .{});
        }
    }

    /// World reflection of a bone, null when it may change
    fn steadyReflection(m: *Migration, doc: *ObjectMap, bone: Value) Error!?bool {
        var flips = false;
        var at: ?Value = bone;
        while (at) |b| : (at = if (try tree.getString(b, "parent")) |p| m.bones.get(p) orelse return error.Malformed else null) {
            const name = try tree.requireString(b, "name");
            if (!std.mem.eql(u8, try tree.getString(b, "transform") orelse "normal", "normal")) return null;
            if (try tree.getFloat(b, "shearX", 0) != 0 or try tree.getFloat(b, "shearY", 0) != 0) return null;
            if ((try m.timelineKeys("bones", name, "shear")).len > 0) return null;
            for (try edit.arrayOf(doc, "transform")) |c| for (try tree.getArray(c, "bones")) |other| {
                if (other == .string and std.mem.eql(u8, other.string, name)) return null;
            };
            for ([_][]const u8{ "scaleX", "scaleY" }, [_][]const u8{ "x", "y" }) |field, axis| {
                const setup = try tree.getFloat(b, field, 1);
                if (setup == 0) return null;
                for (try m.timelineKeys("bones", name, "scale")) |k| {
                    if (try tree.getFloat(k, axis, 1) * setup <= 0) return null;
                    const curve = tree.get(k, "curve") orelse continue;
                    if (curve != .array) continue;
                    if (curve.array.items.len != 4) return error.Malformed;
                    // a percent outside 0 to 1 can leave the key range
                    for ([_]usize{ 1, 3 }) |i| {
                        const p = try tree.number(curve.array.items[i]);
                        if (p < 0 or p > 1) return null;
                    }
                }
                if (setup < 0) flips = !flips;
            }
        }
        return flips;
    }

    /// 3.5.03-beta builds the noRotationOrReflection basis in another order
    fn noRotation(m: *Migration, doc: *ObjectMap, rig: bool) Error!void {
        for (try edit.arrayOf(doc, "bones")) |*bone| {
            if (!std.mem.eql(u8, try tree.getString(bone.*, "transform") orelse "normal", "noRotationOrReflection")) continue;
            var at: ?Value = bone.*;
            const uneven = while (at) |b| : (at = m.bones.get(try tree.getString(b, "parent") orelse break false)) {
                if (try m.skewed(b)) break true;
            } else false;
            if (!uneven) continue;
            if (rig and try m.alone(doc, bone.*)) {
                try (try edit.objectOf(bone)).put(m.arena, marks.no_rotation, .{ .bool = true });
                try m.lose(.@"bone.noRotation.rewritten", try m.path("bones", try edit.objectOf(bone), "transform"), "helper bones rebuild the turned back local matrix", .{});
                continue;
            }
            try m.report.add(.{
                .code = .@"bone.noRotation.approximated",
                .step = m.step,
                .path = try m.path("bones", try edit.objectOf(bone), "transform"),
                .message = "noRotationOrReflection bone with nonuniform scale or shear in its chain",
                .remedy = .runtime,
            });
        }
    }

    /// No constraint moves the bone or its ancestors or reads it
    fn alone(m: *Migration, doc: *ObjectMap, bone: Value) Error!bool {
        const name = try tree.requireString(bone, "name");
        var chain: std.ArrayList([]const u8) = .empty;
        var at: ?[]const u8 = name;
        while (at) |b| : (at = try tree.getString(m.bones.get(b) orelse return error.Malformed, "parent")) try chain.append(m.arena, b);
        if (chain.items.len < 2) return false;
        for ([_][]const u8{ "ik", "transform", "path" }) |kind| for (try edit.arrayOf(doc, kind)) |c| {
            if (!std.mem.eql(u8, kind, "path")) if (try tree.getString(c, "target")) |t| if (std.mem.eql(u8, t, name)) return false;
            for (try tree.getArray(c, "bones")) |b| for (chain.items) |n| if (b == .string and std.mem.eql(u8, b.string, n)) return false;
        };
        return true;
    }

    /// 3.6 before 3.6.46 still spaces bones shorter than 1e-5
    fn zeroBones(m: *Migration, doc: *ObjectMap, nan: bool) Error!void {
        for (try edit.arrayOf(doc, "path")) |*c| {
            const length = std.mem.eql(u8, try tree.getString(c.*, "spacingMode") orelse "length", "length");
            const chain = std.mem.eql(u8, try tree.getString(c.*, "rotateMode") orelse "tangent", "chainScale");
            if (!length and !chain) continue;
            const zero = for (try tree.getArray(c.*, "bones")) |name| {
                if (name != .string) return error.Malformed;
                const bone = m.bones.get(name.string) orelse return error.Malformed;
                if (try tree.getFloat(bone, "length", 0) < 0.00001) break true;
            } else false;
            if (!zero) continue;
            const map = try edit.objectOf(c);
            const message = if (nan) "3.6 before 3.6.39 spaces zero length bones as NaN" else "3.6 before 3.6.46 spaces zero length bones by their scale";
            try m.lose(.@"path.spacing.approximated", try m.path("path", map, "spacing"), "{s}", .{message});
        }
    }

    /// 3.6.32 editors clip with polygons below 3 vertices
    fn clipVertices(m: *Migration, doc: *ObjectMap, rewrite: bool) Error!void {
        const skins = try edit.childOf(doc, "skins") orelse return;
        for (skins.keys(), skins.values()) |skin, *slots| {
            if (slots.* != .object) return error.Malformed;
            for (slots.object.keys(), slots.object.values()) |slot, *attachments| {
                if (attachments.* != .object) return error.Malformed;
                for (attachments.object.keys(), attachments.object.values()) |name, *a| {
                    if (!std.mem.eql(u8, try tree.getString(a.*, "type") orelse "region", "clipping")) continue;
                    if (try tree.getFloat(a.*, "vertexCount", 0) >= 3) continue;
                    const where = try std.fmt.allocPrint(m.arena, "skins.{s}.{s}.{s}", .{ skin, slot, name });
                    if (rewrite and try m.clipOnly(skins, slot)) {
                        try m.hideAll(doc, skin, slot, name, try edit.objectOf(a));
                        try m.lose(.@"clipping.vertices.rewritten", where, "polygon replaced by a far triangle on an unscaled bone, which clips everything away", .{});
                    } else try m.lose(.@"clipping.vertices.approximated", where, "3.6 from 3.6.35 ignores clipping below 3 vertices", .{});
                }
            }
        }
    }

    /// Every attachment of the slot in every skin clips
    fn clipOnly(m: *Migration, skins: *ObjectMap, slot: []const u8) Error!bool {
        _ = m;
        for (skins.values()) |slots| {
            const attachments = tree.get(slots, slot) orelse continue;
            if (attachments != .object) return error.Malformed;
            for (attachments.object.values()) |a| if (!std.mem.eql(u8, try tree.getString(a, "type") orelse "region", "clipping")) return false;
        }
        return true;
    }

    /// 3.6.32 clips everything away with fewer than 3 vertices, a far triangle does in every 4.3 runtime
    fn hideAll(m: *Migration, doc: *ObjectMap, skin: []const u8, slot: []const u8, name: []const u8, clip: *ObjectMap) Error!void {
        const bones = try edit.arrayOf(doc, "bones");
        if (bones.len == 0) return error.Malformed;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (bones) |b| try names.put(m.arena, try tree.requireString(b, "name"), {});
        var helper = try std.fmt.allocPrint(m.arena, "spine-converter/{s}-clip", .{slot});
        var n: usize = 2;
        while (names.contains(helper)) : (n += 1) helper = try std.fmt.allocPrint(m.arena, "spine-converter/{s}-clip{d}", .{ slot, n });
        for (try edit.arrayOf(doc, "slots")) |*s| {
            if (!std.mem.eql(u8, try tree.requireString(s.*, "name"), slot)) continue;
            const map = try edit.objectOf(s);
            const bone = try tree.requireString(s.*, "bone");
            if (std.mem.startsWith(u8, bone, "spine-converter/")) break;
            // the helper keeps the far triangle at world scale 1
            var b: tree.Object = .init(m.arena);
            try b.put("name", .{ .string = helper });
            try b.put("parent", .{ .string = try tree.requireString(bones[0], "name") });
            try b.put("transform", .{ .string = "onlyTranslation" });
            try (try edit.childValue(doc, "bones")).?.array.append(b.value());
            try map.put(m.arena, "bone", .{ .string = helper });
            break;
        }
        var vertices = tree.array(m.arena);
        for ([_]f32{ 1e6, 1e6, 1.01e6, 1e6, 1e6, 1.01e6 }) |v| try vertices.append(.{ .float = v });
        try clip.put(m.arena, "vertexCount", .{ .integer = 3 });
        try clip.put(m.arena, "vertices", .{ .array = vertices });
        const animations = m.animations orelse return;
        for (animations.values()) |*animation| {
            const deform = try edit.childOf(try edit.objectOf(animation), "deform") orelse continue;
            const slots = try edit.childOf(deform, skin) orelse continue;
            const entries = try edit.childOf(slots, slot) orelse continue;
            _ = entries.orderedRemove(name);
        }
    }

    fn onPathStart(m: *Migration, map: *ObjectMap) Error!bool {
        const fixed = std.mem.eql(u8, try tree.getString(.{ .object = map.* }, "positionMode") orelse "percent", "fixed");
        if (onStart(try edit.float(map, "position", 0), fixed)) return true;
        for (try m.timelineKeys("paths", try tree.getString(.{ .object = map.* }, "name") orelse "", "position")) |k| {
            if (onStart(try tree.getFloat(k, "position", 0), fixed)) return true;
        }
        return false;
    }

    fn mixed(m: *Migration, c: *ObjectMap, group: []const u8, timeline: []const u8, key: []const u8) Error!bool {
        if (try edit.float(c, key, 1) != 0) return true;
        for (try m.timelineKeys(group, try tree.getString(.{ .object = c.* }, "name") orelse "", timeline)) |k| {
            if (try tree.getFloat(k, key, 1) != 0) return true;
        }
        return false;
    }

    /// Negative setup or keyed scale on the bone or an ancestor
    fn reflected(m: *Migration, bone: Value, self: bool) Error!bool {
        var at: ?Value = if (self) bone else m.bones.get(try tree.getString(bone, "parent") orelse return false);
        while (at) |b| : (at = m.bones.get(try tree.getString(b, "parent") orelse return false)) {
            if (try tree.getFloat(b, "scaleX", 1) < 0 or try tree.getFloat(b, "scaleY", 1) < 0) return true;
            for (try m.timelineKeys("bones", try tree.requireString(b, "name"), "scale")) |k| {
                if (try tree.getFloat(k, "x", 1) < 0 or try tree.getFloat(k, "y", 1) < 0) return true;
            }
        }
        return false;
    }

    fn sheared(m: *Migration, name: []const u8) Error!bool {
        const bone = m.bones.get(name) orelse return error.Malformed;
        if (try tree.getFloat(bone, "shearX", 0) != 0 or try tree.getFloat(bone, "shearY", 0) != 0) return true;
        for (try m.timelineKeys("bones", name, "shear")) |k| {
            if (try tree.getFloat(k, "x", 0) != 0 or try tree.getFloat(k, "y", 0) != 0) return true;
        }
        return false;
    }

    fn skewed(m: *Migration, bone: Value) Error!bool {
        const name = try tree.requireString(bone, "name");
        if (try m.sheared(name)) return true;
        const sx = try tree.getFloat(bone, "scaleX", 1);
        const sy = try tree.getFloat(bone, "scaleY", 1);
        if (sx != sy) return true;
        for (try m.timelineKeys("bones", name, "scale")) |k| {
            if (try tree.getFloat(k, "x", 1) != try tree.getFloat(k, "y", 1)) return true;
        }
        return false;
    }

    /// Empty timeline takes the keys of the owner
    fn timelineKeys(m: *Migration, group: []const u8, owner: []const u8, timeline: []const u8) Error![]const Value {
        var out: std.ArrayList(Value) = .empty;
        const animations = m.animations orelse return &.{};
        for (animations.values()) |animation| {
            var list = tree.get(tree.get(animation, group) orelse continue, owner) orelse continue;
            if (timeline.len > 0) list = tree.get(list, timeline) orelse continue;
            if (list != .array) return error.Malformed;
            try out.appendSlice(m.arena, list.array.items);
        }
        return out.items;
    }

    /// Keeps the light color of two color keys
    fn downTwoColor(m: *Migration, slot: *ObjectMap, where: []const u8) Error!void {
        const index = slot.getIndex("twoColor") orelse return;
        const keys = slot.values()[index];
        if (keys != .array) return error.Malformed;
        try m.lose(.@"animation.dark.dropped", where, "dark color keys", .{});
        // The later timeline wins
        if (slot.getIndex("color")) |color| if (color > index) {
            slot.orderedRemoveAt(index);
            return;
        };
        var out = tree.array(m.arena);
        for (keys.array.items) |key| {
            var k: ObjectMap = .empty;
            if (key != .object) return error.Malformed;
            for (key.object.keys(), key.object.values()) |name, v| {
                if (std.mem.eql(u8, name, "dark")) continue;
                try k.put(m.arena, if (std.mem.eql(u8, name, "light")) "color" else name, v);
            }
            try out.append(.{ .object = k });
        }
        slot.orderedRemoveAt(index);
        try slot.put(m.arena, "color", .{ .array = out });
    }

    fn path(m: *Migration, list: []const u8, map: *ObjectMap, key: []const u8) Error![]const u8 {
        const name = try tree.getString(.{ .object = map.* }, "name") orelse "";
        return std.fmt.allocPrint(m.arena, "{s}.{s}.{s}", .{ list, name, key });
    }

    fn lose(m: *Migration, code: Report.Code, where: []const u8, comptime fmt: []const u8, args: anytype) Error!void {
        try m.report.add(.{ .code = code, .step = m.step, .path = where, .message = try std.fmt.allocPrint(m.arena, fmt, args) });
    }
};

fn parse(a: std.mem.Allocator, input: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, input, .{});
}

/// Key order matters, encoders keep it
fn expectJson(a: std.mem.Allocator, actual: Value, expected: []const u8) !void {
    const want = try std.json.Stringify.valueAlloc(a, try parse(a, expected), .{});
    try std.testing.expectEqualStrings(want, try std.json.Stringify.valueAlloc(a, actual, .{}));
}

fn codes(a: std.mem.Allocator, report: *const Report) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (report.entries.items) |e| {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, @tagName(e.code));
    }
    return out.items;
}

test "up keeps the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Report = .{ .arena = a };
    const input =
        \\{"skeleton":{"spine":"3.5.51"},"bones":[{"name":"root"},{"name":"b","parent":"root","transform":"noScale"}],
        \\"path":[{"name":"p","bones":["b"],"target":"s","position":0.5,"spacingMode":"percent","spacing":0.5}],
        \\"animations":{"a":{"bones":{"b":{"rotate":[{"time":0,"angle":5}]}}}}}
    ;
    var root = try parse(a, input);
    try up(a, &root, &report, .{});
    try std.testing.expectEqual(0, report.entries.items.len);
    try expectJson(a, root, input);
}

test "spacing scaled by the bone world scale is reported both ways" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root"},{"name":"b","parent":"root","scaleX":2,"length":10}],
        \\"path":[{"name":"length","bones":["b"],"position":0.5,"spacing":2},{"name":"chain","bones":["b"],"position":0.5,"spacingMode":"fixed","rotateMode":"chainScale"},
        \\{"name":"percent","bones":["b"],"position":0.5,"spacingMode":"percent","spacing":1},{"name":"zero","bones":["b"],"position":0.5}],
        \\"animations":{"a":{"paths":{"chain":{"spacing":[{"time":0,"spacing":3}]},"zero":{"spacing":[{"time":0}]}}}}}
    ;
    var root = try parse(a, input);
    var report: Report = .{ .arena = a };
    try up(a, &root, &report, .{});
    try std.testing.expectEqualStrings("path.spacing.approximated path.spacing.approximated", try codes(a, &report));
    try std.testing.expectEqualStrings("path.length.spacing", report.entries.items[0].path);
    try std.testing.expectEqualStrings("path.chain.spacing", report.entries.items[1].path);
    report = .{ .arena = a };
    try down(a, &root, &report, .{});
    try std.testing.expectEqualStrings("3.6-3.5", report.entries.items[1].step);
    try std.testing.expectEqual(2, report.entries.items.len);
}

test "sheared noScale bones under reflection are reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root"},{"name":"flip","parent":"root","scaleX":-1},{"name":"keyflip","parent":"root"},
        \\{"name":"setup","parent":"flip","transform":"noScale","shearX":10},{"name":"plain","parent":"flip","transform":"noScale"},
        \\{"name":"keyed","parent":"root","transform":"noScaleOrReflection"},{"name":"upright","parent":"root","transform":"noScale","shearX":5},
        \\{"name":"late","parent":"keyflip","transform":"noScale","shearY":3},{"name":"normal","parent":"flip","shearY":5}],
        \\"animations":{"a":{"bones":{"keyed":{"shear":[{"time":0},{"time":1,"y":4}]},"plain":{"shear":[{"time":0}]},
        \\"keyflip":{"scale":[{"time":0,"y":-1}]}}}}}
    ;
    var root = try parse(a, input);
    var report: Report = .{ .arena = a };
    try up(a, &root, &report, .{});
    try std.testing.expectEqualStrings("bone.reflection.approximated bone.flip.approximated bone.reflection.approximated", try codes(a, &report));
    try std.testing.expectEqualStrings("bones.setup.transform", report.entries.items[0].path);
    try std.testing.expectEqualStrings("bones.keyed.transform", report.entries.items[1].path);
    try std.testing.expectEqualStrings("bones.late.transform", report.entries.items[2].path);
    try std.testing.expectEqual(.control, report.entries.items[1].code.impact());
}

fn earlyCodes(a: std.mem.Allocator, version: []const u8, body: []const u8, target: u16) ![]const u8 {
    var root = try parse(a, try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"{s}\"}},{s}}}", .{ version, body }));
    var report: Report = .{ .arena = a };
    try early(a, &root, &report, .{ .major = 3, .minor = target }, .{});
    return codes(a, &report);
}

test "early 3.5 offsets and noRotationOrReflection" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\"bones":[{"name":"root"},{"name":"neg","parent":"root","scaleY":-1},{"name":"b","parent":"neg"},{"name":"t","parent":"root"},
        \\{"name":"wide","parent":"root","scaleX":2},{"name":"n","parent":"wide","transform":"noRotationOrReflection"},
        \\{"name":"m","parent":"t","transform":"noRotationOrReflection","scaleX":3,"scaleY":3}],
        \\"slots":[{"name":"s","bone":"neg"}],
        \\"transform":[{"name":"r","bones":["t"],"target":"b","rotation":10},{"name":"u","bones":["b"],"target":"t","rotation":10},
        \\{"name":"z","bones":["t"],"target":"b","rotation":10,"rotateMix":0},{"name":"y","bones":["t"],"target":"b","shearY":5}],
        \\"path":[{"name":"p","bones":["t"],"target":"s","rotation":20}]
    ;
    try std.testing.expectEqualStrings(
        "transform.offsetReflect.approximated transform.offsetFlip.approximated transform.offsetReflect.approximated " ++
            "path.offsetReflect.approximated bone.noRotation.approximated",
        try earlyCodes(a, "3.5.03-beta", body, 6),
    );
    try std.testing.expectEqualStrings("", try earlyCodes(a, "3.5.51", body, 5));
}

test "early 3.6 exports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\"bones":[{"name":"root"},{"name":"flip","parent":"root","scaleX":-1},{"name":"s","parent":"flip","transform":"noScale","shearX":10},
        \\{"name":"long","parent":"root","length":20}],
        \\"path":[{"name":"start","bones":["long"],"target":"x","spacingMode":"percent"},{"name":"zero","bones":["s"],"target":"x","position":0.5},
        \\{"name":"fixed","bones":["s"],"target":"x","position":0.5,"spacingMode":"fixed"}],
        \\"skins":{"default":{"x":{"c":{"type":"clipping","vertexCount":2,"vertices":[0,0,1,1]},"d":{"type":"clipping","vertexCount":3,"vertices":[0,0,1,1,1,0]}}}}
    ;
    try std.testing.expectEqualStrings(
        "bone.reflection.approximated path.start.approximated path.spacing.approximated clipping.vertices.approximated",
        try earlyCodes(a, "3.6.32", body, 6),
    );
    try std.testing.expectEqualStrings("bone.reflection.approximated path.spacing.approximated clipping.vertices.approximated", try earlyCodes(a, "3.6.32", body, 7));
    try std.testing.expectEqualStrings("path.start.approximated path.spacing.approximated", try earlyCodes(a, "3.6.40", body, 6));
    try std.testing.expectEqualStrings("", try earlyCodes(a, "3.6.46", body, 6));
    try std.testing.expectEqualStrings("", try earlyCodes(a, "3.6.0", body, 6));

    var root = try parse(a, try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"3.6.32\"}},{s}}}", .{body}));
    var report: Report = .{ .arena = a };
    try early(a, &root, &report, .{ .major = 3, .minor = 6 }, .{});
    try std.testing.expect(std.mem.indexOf(u8, report.entries.items[2].message, "NaN") != null);
    try std.testing.expectEqualStrings("skins.default.x.c", report.entries.items[3].path);
}

test "down skips what old 3.6 editors pose like 3.5" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\"bones":[{{"name":"root"}},{{"name":"flip","parent":"root","scaleX":-1}},{{"name":"s","parent":"flip","transform":"noScale","shearX":10}},
        \\{{"name":"l","parent":"root","length":5}}],"path":[{{"name":"p","bones":["l"],"target":"x","spacingMode":"percent"}}]
    ;
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "3.6.32", "" },
        .{ "3.6.40", "bone.reflection.approximated" },
        .{ "3.6.52", "bone.reflection.approximated path.start.approximated" },
    }) |case| {
        var root = try parse(a, try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"{s}\"}}," ++ body ++ "}}", .{case[0]}));
        var report: Report = .{ .arena = a };
        try down(a, &root, &report, .{});
        try std.testing.expectEqualStrings(case[1], try codes(a, &report));
    }
}

test "down drops two color tint and keeps the light color" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"slots":[{"name":"s","bone":"root","color":"ff0000ff","dark":"00ff00"},{"name":"t","bone":"root"}],
        \\"animations":{"a":{"slots":{"s":{"twoColor":[{"time":0,"light":"ffffffff","dark":"000000","curve":"stepped"},
        \\{"time":1,"light":"ff00ffff","dark":"112233"}]},
        \\"t":{"twoColor":[{"time":0,"light":"00000000","dark":"000000"}],"color":[{"time":0,"color":"123456ff"}]}}}}}
    ;
    var root = try parse(a, input);
    var report: Report = .{ .arena = a };
    try down(a, &root, &report, .{});
    try std.testing.expectEqualStrings("slot.dark.dropped animation.dark.dropped animation.dark.dropped", try codes(a, &report));
    const expected =
        \\{"slots":[{"name":"s","bone":"root","color":"ff0000ff"},{"name":"t","bone":"root"}],
        \\"animations":{"a":{"slots":{"s":{"color":[{"time":0,"color":"ffffffff","curve":"stepped"},{"time":1,"color":"ff00ffff"}]},
        \\"t":{"color":[{"time":0,"color":"123456ff"}]}}}}}
    ;
    try expectJson(a, root, expected);
    try std.testing.expectEqual(.render, report.entries.items[0].code.impact());
}

test "down turns local and relative transform constraints into world absolute" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a,
        \\{"transform":[{"name":"l","local":true,"relative":true},{"name":"w","local":false,"relative":false}]}
    );
    var report: Report = .{ .arena = a };
    try down(a, &root, &report, .{});
    try std.testing.expectEqualStrings("transform.local.dropped transform.relative.dropped", try codes(a, &report));
    try std.testing.expectEqualStrings("transform.l.relative", report.entries.items[1].path);
    try expectJson(a, root, "{\"transform\":[{\"name\":\"l\"},{\"name\":\"w\"}]}");
}

test "down drops clipping and point attachments with their deform" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a,
        \\{"skins":{"default":{"s":{"clip":{"type":"clipping","end":"t","vertexCount":3,"vertices":[0,0,1,0,0,1]},
        \\"p":{"type":"point","x":1},"m":{"type":"mesh","uvs":[],"triangles":[],"vertices":[],"hull":0}}}},
        \\"animations":{"a":{"deform":{"default":{"s":{"clip":[{"time":0}],"m":[{"time":0}]}}}}}}
    );
    var report: Report = .{ .arena = a };
    try down(a, &root, &report, .{});
    try std.testing.expectEqualStrings("attachment.clipping.dropped attachment.point.dropped", try codes(a, &report));
    try std.testing.expectEqualStrings("skins.default.s.clip", report.entries.items[0].path);
    try std.testing.expectEqual(.control, report.entries.items[1].code.impact());
    const expected =
        \\{"skins":{"default":{"s":{"m":{"type":"mesh","uvs":[],"triangles":[],"vertices":[],"hull":0}}}},
        \\"animations":{"a":{"deform":{"default":{"s":{"m":[{"time":0}]}}}}}}
    ;
    try expectJson(a, root, expected);
}

/// Whole percents and fixed 0 sit on the path start
fn onStart(position: f32, fixed: bool) bool {
    return if (fixed) position == 0 else position == @floor(position);
}

test "path on its start is reported both ways" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"path":[{"name":"setup","spacingMode":"percent"},{"name":"keyed","position":0.5,"spacingMode":"percent"},
        \\{"name":"fixed","positionMode":"fixed","position":3,"spacingMode":"percent"},{"name":"off","position":0.5,"spacingMode":"percent"}],
        \\"animations":{"a":{"paths":{"keyed":{"position":[{"time":0,"position":0.5},{"time":1,"position":2}]}}}}}
    ;
    var root = try parse(a, input);
    var report: Report = .{ .arena = a };
    try up(a, &root, &report, .{});
    try std.testing.expectEqualStrings("path.start.approximated path.start.approximated", try codes(a, &report));
    try std.testing.expectEqualStrings("path.setup.position", report.entries.items[0].path);
    try std.testing.expectEqualStrings("path.keyed.position", report.entries.items[1].path);
    report = .{ .arena = a };
    try down(a, &root, &report, .{});
    try std.testing.expectEqualStrings("path.start.approximated path.start.approximated", try codes(a, &report));
}

test "old clipping below 3 vertices hides everything" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"skeleton":{"spine":"3.6.32"},"bones":[{"name":"root"},{"name":"b","parent":"root","scaleX":0.001}],
        \\"slots":[{"name":"x","bone":"b","attachment":"c"}],
        \\"skins":{"default":{"x":{"c":{"type":"clipping","vertexCount":2,"vertices":[0,0,1,1]}}}},
        \\"animations":{"a":{"deform":{"default":{"x":{"c":[{"time":0}]}}}}}}
    ;
    var report: Report = .{ .arena = a };
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    try early(a, &root, &report, .{ .major = 4, .minor = 3 }, .{ .rewrite = true });
    try std.testing.expectEqual(.@"clipping.vertices.rewritten", report.entries.items[0].code);
    const bones = root.object.get("bones").?.array.items;
    try std.testing.expectEqualStrings("spine-converter/x-clip", try tree.requireString(bones[2], "name"));
    try std.testing.expectEqualStrings("spine-converter/x-clip", try tree.requireString(root.object.get("slots").?.array.items[0], "bone"));
    const clip = root.object.get("skins").?.object.get("default").?.object.get("x").?.object.get("c").?;
    try std.testing.expectEqual(6, (try tree.getArray(clip, "vertices")).len);
    const deform = root.object.get("animations").?.object.get("a").?.object.get("deform").?.object.get("default").?.object.get("x").?;
    try std.testing.expect(deform.object.get("c") == null);
}
/// A 3.x Bézier percent stays within the two key values
fn percentWithin(key: Value) Error!bool {
    const curve = tree.get(key, "curve") orelse return true;
    if (curve != .array) return true;
    for (curve.array.items, 0..) |v, i| {
        if (i % 2 == 0) continue;
        const p = try tree.number(v);
        if (p < 0 or p > 1) return false;
    }
    return true;
}

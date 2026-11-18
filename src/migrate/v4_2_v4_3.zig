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

//! Spine 4.2 and 4.3 JSON, mapped by SkeletonJson.java of both branches

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Report = @import("../Report.zig");
const Version = @import("../Version.zig");
const Flags = @import("../Document.zig").Flags;
const tree = @import("../binary/tree.zig");
const edit = @import("../edit.zig");
const singular = @import("singular.zig");
const resets = @import("order.zig");
const marks = @import("marks.zig");
const gating = @import("v4_0_v4_1.zig");

pub const Error = error{ Malformed, OutOfMemory };

/// 4.2 update order breaks ties in this order
const kinds = [_][]const u8{ "ik", "transform", "path", "physics" };
const properties = [_][]const u8{ "rotate", "x", "y", "scaleX", "scaleY", "shearY" };
const mixes = [_][]const u8{ "mixRotate", "mixX", "mixY", "mixScaleX", "mixScaleY", "mixShearY" };
const Mixes = [mixes.len]f32;
const geometry = [_][]const u8{ "uvs", "triangles", "vertices", "hull", "edges", "width", "height" };

const reason_4_3 = "4.3 exports before 4.3.03 use the 4.2 thresholds";
const reason_4_2_4_3 = "4.2 and 4.3 use other thresholds near zero";
const reset_4_3 = "4.3 exports before 4.3.18";

pub fn early(arena: std.mem.Allocator, root: *Value, report: *Report, target: Version.Minor, flags: Flags) Error!void {
    const version = Version.ofRoot(root.*) orelse return;
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.3" };
    const doc = try edit.objectOf(root);
    if (Version.editor(version, .volume_43) != .new) try m.checkVolume(doc);
    if (Version.editor(version, .singular_43) != .new) {
        try singular.check(arena, doc, report, m.step, reason_4_3);
        try singular.checkBones(arena, doc, report, m.step, reason_4_3);
    }
    if (Version.editor(version, .derive_43) != .new) {
        m.rewrite = flags.rewrite;
        try m.checkDerive(doc, "4.3 exports before 4.3.03 derive it like 4.2");
        m.rewrite = false;
    }
    if (Version.editor(version, .slider_linked_43) != .new) try m.checkSliderLinked(doc);
    if (Version.editor(version, .json_mix_43) != .new) try m.checkJsonMix(doc);
    const reset = Version.editor(version, .reset_43);
    if (reset != .new) try m.checkReset(doc, reset == .old and flags.rewrite, target.major == 4 and target.minor >= 3, reset_4_3);
}

pub fn up(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.2-4.3", .rewrite = flags.rewrite };
    const doc = try edit.objectOf(root);
    try m.dropSkipped(doc);
    try m.checkLengthSpacing(doc, true);
    try m.checkPhysics(doc);
    try m.checkClosed(doc);
    try m.checkColors(doc);
    try m.checkIkShear(doc);
    try singular.check(arena, doc, report, m.step, reason_4_2_4_3);
    try singular.checkBones(arena, doc, report, m.step, reason_4_2_4_3);
    try m.checkDerive(doc, "4.3 derives it from the world pass");
    try m.checkShear(doc, true);
    try m.upConstraints(doc);
    try m.noRotationRigs(doc);
    for (try edit.arrayOf(doc, "skins")) |*skin| {
        const attachments = try edit.childOf(try edit.objectOf(skin), "attachments") orelse continue;
        var it = attachments.iterator();
        while (it.next()) |slot| {
            var entries = (try edit.objectOf(slot.value_ptr)).iterator();
            while (entries.next()) |entry| {
                const a = try edit.objectOf(entry.value_ptr);
                try m.rename(a, "parent", "source");
                try m.regionSize(a, 32);
            }
        }
    }
    const animations = try edit.childOf(doc, "animations") orelse return;
    var it = animations.iterator();
    while (it.next()) |animation| {
        const map = try edit.objectOf(animation.value_ptr);
        var transforms = try edit.timelinesOf(map, "transform");
        while (transforms.next()) |timeline| {
            for (try edit.keysOf(timeline.value_ptr)) |*key| {
                const k = try edit.objectOf(key);
                if (k.get("mixScaleY") == null) if (k.get("mixScaleX")) |x| try k.put(arena, "mixScaleY", x);
            }
        }
        var physics = try edit.timelinesOf(map, "physics");
        while (physics.next()) |constraint| {
            const mix = try edit.childValue(try edit.objectOf(constraint.value_ptr), "mix") orelse continue;
            for (try edit.keysOf(mix)) |*key| try m.default(try edit.objectOf(key), "value", 0);
        }
        const timelines = try edit.childOf(map, "transform") orelse continue;
        for (m.helpers.keys(), m.helpers.values()) |original, helper| {
            const keys = timelines.get(original) orelse continue;
            const name = try tree.requireString(.{ .object = helper }, "name");
            if (!m.gated.contains(name)) try timelines.put(arena, name, keys);
        }
        for (m.signs.keys(), m.signs.values()) |original, sign| {
            const keys = timelines.get(original) orelse continue;
            const name = try tree.requireString(.{ .object = sign.post }, "name");
            if (!m.gated.contains(name)) try timelines.put(arena, name, keys);
        }
    }
}

pub fn down(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.3-4.2", .rewrite = flags.rewrite };
    const doc = try edit.objectOf(root);
    const version = Version.ofRoot(root.*);
    if (version) |v| if (v.major == 4 and v.minor == 3) {
        const reset = Version.editor(v, .reset_43);
        if (reset != .new) try m.checkReset(doc, reset == .old and flags.rewrite, false, reset_4_3);
    };
    if (flags.rewrite) try m.findDeformed(doc);
    try m.checkColors(doc);
    try m.checkIkShear(doc);
    if (!old(version, .singular_43)) {
        try singular.check(arena, doc, report, m.step, reason_4_2_4_3);
        try singular.checkBones(arena, doc, report, m.step, reason_4_2_4_3);
    }
    if (!old(version, .derive_43)) try m.checkDerive(doc, "4.2 derives it from the applied transform");
    try m.checkShear(doc, false);
    if (version) |v| if (Version.editor(v, .json_mix_43) != .new) try m.checkJsonMix(doc);
    try m.downConstraints(doc);
    try m.checkLengthSpacing(doc, false);
    try m.checkPhysics(doc);
    try m.checkClosed(doc);
    for (try edit.arrayOf(doc, "bones")) |*bone| {
        const map = try edit.objectOf(bone);
        if (edit.take(map, "iconSize") != null or edit.take(map, "iconRotation") != null) {
            try m.lose(.@"bone.icon.dropped", try m.path("bones", map), "bone icon size and rotation", .{});
        }
    }
    try m.downSkins(doc);
    const animations = try edit.childOf(doc, "animations") orelse return;
    var it = animations.iterator();
    while (it.next()) |animation| {
        const name = animation.key_ptr.*;
        const map = try edit.objectOf(animation.value_ptr);
        for ([_]Dropped{
            .{ "color", .@"animation.color.dropped" },
            .{ "slider", .@"animation.slider.dropped" },
            .{ "drawOrderFolder", .@"animation.drawOrderFolder.dropped" },
        }) |entry| {
            const key, const code = entry;
            if (edit.take(map, key) == null) continue;
            const where = try std.fmt.allocPrint(arena, "animations.{s}.{s}", .{ name, key });
            try m.lose(code, where, "{s} has no 4.2 equivalent", .{key});
        }
        var transforms = try edit.timelinesOf(map, "transform");
        while (transforms.next()) |timeline| {
            const enabled: [mixes.len]bool = m.enabled.get(timeline.key_ptr.*) orelse @splat(true);
            for (try edit.keysOf(timeline.value_ptr)) |*key| {
                const k = try edit.objectOf(key);
                const x = try edit.float(k, "mixX", 1);
                var values: Mixes = .{ try edit.float(k, "mixRotate", 1), x, try edit.float(k, "mixY", x), try edit.float(k, "mixScaleX", 1), try edit.float(k, "mixScaleY", 1), try edit.float(k, "mixShearY", 1) };
                try m.putMixes(k, &values, enabled);
            }
        }
        var physics = try edit.timelinesOf(map, "physics");
        while (physics.next()) |constraint| {
            const mix = try edit.childValue(try edit.objectOf(constraint.value_ptr), "mix") orelse continue;
            for (try edit.keysOf(mix)) |*key| try m.default(try edit.objectOf(key), "value", 1);
        }
    }
}

const Sign = struct { pre: [2]ObjectMap, post: ObjectMap };

fn rotateLink(arena: std.mem.Allocator, from: []const u8, to: []const u8) Error!Value {
    var entry: ObjectMap = .empty;
    try entry.put(arena, to, .{ .object = .empty });
    var link: ObjectMap = .empty;
    try link.put(arena, "to", .{ .object = entry });
    var map: ObjectMap = .empty;
    try map.put(arena, from, .{ .object = link });
    return .{ .object = map };
}

const Dropped = struct { []const u8, Report.Code };

const Migration = struct {
    arena: std.mem.Allocator,
    report: *Report,
    step: []const u8,
    /// Transform properties a 4.3 constraint applies, by name
    enabled: std.StringHashMapUnmanaged([mixes.len]bool) = .empty,
    rewrite: bool = false,
    /// Skin, slot and attachment names joined by a zero byte
    deformed: std.StringHashMapUnmanaged(void) = .empty,
    /// Shear helpers inserted after the named constraint
    helpers: std.StringArrayHashMapUnmanaged(ObjectMap) = .empty,
    /// Reflection signing rigs of the named constraint
    signs: std.StringArrayHashMapUnmanaged(Sign) = .empty,
    /// Helper constraints whose mix a slider drives
    gated: std.StringHashMapUnmanaged(void) = .empty,
    /// Shear sources inserted before the named constraint
    leads: std.StringArrayHashMapUnmanaged(ObjectMap) = .empty,

    /// 4.2 never updates a constraint whose order repeats or reaches the count, 4.3 updates every one
    fn dropSkipped(m: *Migration, doc: *ObjectMap) Error!void {
        const Entry = struct { order: i64, kind: usize, name: []const u8 };
        var entries: std.ArrayList(Entry) = .empty;
        for (kinds, 0..) |kind, k| for (try edit.arrayOf(doc, kind)) |c| {
            try entries.append(m.arena, .{ .order = try tree.getInt(c, "order", 0), .kind = k, .name = try tree.requireString(c, "name") });
        };
        std.sort.block(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.order < b.order or a.order == b.order and a.kind < b.kind;
            }
        }.lessThan);
        for (entries.items, 0..) |e, i| {
            if (e.order >= 0 and e.order < entries.items.len and (i == 0 or entries.items[i - 1].order != e.order)) continue;
            const where = try std.fmt.allocPrint(m.arena, "{s}.{s}", .{ kinds[e.kind], e.name });
            if (!m.rewrite) {
                try m.lose(.@"constraint.skipped.approximated", where, "4.2 never updates it and 4.3 does", .{});
                continue;
            }
            const list = (try edit.childValue(doc, kinds[e.kind])).?;
            for (list.array.items, 0..) |c, at| if (std.mem.eql(u8, try tree.requireString(c, "name"), e.name)) {
                _ = list.array.orderedRemove(at);
                break;
            };
            for (try edit.arrayOf(doc, "skins")) |*skin| {
                const names = try edit.childValue(try edit.objectOf(skin), kinds[e.kind]) orelse continue;
                if (names.* != .array) return error.Malformed;
                for (names.array.items, 0..) |n, at| if (n == .string and std.mem.eql(u8, n.string, e.name)) {
                    _ = names.array.orderedRemove(at);
                    break;
                };
            }
            if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |*animation| {
                const timelines = try edit.childOf(try edit.objectOf(animation), kinds[e.kind]) orelse continue;
                _ = timelines.orderedRemove(e.name);
            };
            try m.lose(.@"constraint.skipped.rewritten", where, "4.2 never updates it, removed", .{});
        }
    }

    fn upConstraints(m: *Migration, doc: *ObjectMap) Error!void {
        const unit = try unitScale(m.arena, doc);
        const Entry = struct { order: i32, kind: usize, map: ObjectMap };
        var entries: std.ArrayList(Entry) = .empty;
        for (kinds, 0..) |kind, k| {
            const list = edit.take(doc, kind) orelse continue;
            if (list == .null) continue;
            if (list != .array) return error.Malformed;
            for (list.array.items) |c| {
                if (c != .object) return error.Malformed;
                try entries.append(m.arena, .{ .order = try tree.getInt(c, "order", 0), .kind = k, .map = c.object });
            }
        }
        std.sort.block(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.order < b.order or a.order == b.order and a.kind < b.kind;
            }
        }.lessThan);

        var constraints = tree.array(m.arena);
        var restored: std.StringHashMapUnmanaged([]const u8) = .empty;
        var rescaled: std.StringHashMapUnmanaged(void) = .empty;
        var taken: std.StringHashMapUnmanaged(void) = .empty;
        for (entries.items) |e| try taken.put(m.arena, try tree.requireString(.{ .object = e.map }, "name"), {});
        if (try edit.childOf(doc, "animations")) |animations| for (animations.keys()) |name| try taken.put(m.arena, name, {});
        for ([_][]const ObjectMap{ m.helpers.values(), m.leads.values() }) |list| for (list) |h| try taken.put(m.arena, h.get("name").?.string, {});
        for (m.signs.values()) |sign| {
            for (sign.pre) |p| try taken.put(m.arena, p.get("name").?.string, {});
            try taken.put(m.arena, sign.post.get("name").?.string, {});
        }
        for (entries.items) |*e| {
            const c = &e.map;
            _ = c.orderedRemove("order");
            const bones = try bonesOf(m.arena, .{ .object = c.* }, e.kind);
            const neutral = try m.scaleNeutral(doc, c, e.kind, bones);
            var floors: [floor_parts.len]?Value = @splat(null);
            var copies: ?[2]Value = null;
            var proxy: ?Value = null;
            if (e.kind == 2 and edit.take(c, marks.path_gate) != null) try m.pathGate(doc, c, &taken, &constraints);
            var relative: []const Value = &.{};
            var wrapped: []const Value = &.{};
            switch (e.kind) {
                0 => {
                    if (try edit.takeBool(c, "uniform")) try c.put(m.arena, "scaleY", .{ .string = "uniform" });
                    if (edit.take(c, marks.stretch_offset) != null) copies = try m.stretchRig(doc, c, &taken);
                    if (edit.take(c, marks.ik_proxy) != null) proxy = try m.proxyRig(doc, c, &taken);
                },
                1 => {
                    const keyed = (try keyLists(m.arena, doc, &.{ "transform", try tree.requireString(.{ .object = c.* }, "name") })).len > 0;
                    const free = for (bones) |b| {
                        if (rescaled.contains(b.string)) break false;
                    } else true;
                    const rig: ?Rig = if (free) .{ .doc = doc, .taken = &taken, .out = &constraints } else null;
                    try m.upTransform(c, if (keyed) null else appliedSteady(bones, unit, rescaled), appliedUnit(bones, unit, rescaled), keyed or appliedLive(bones, unit, rescaled), rig);
                    if (edit.take(c, marks.applied_flip)) |shear| {
                        const properties_map = try edit.childOf(c, "properties") orelse return error.Malformed;
                        try mapScale(m.arena, properties_map, "shearY", -1);
                        try mapScale(m.arena, properties_map, "scaleY", @floatCast(@cos(try tree.number(shear) * std.math.rad_per_deg)));
                        try c.put(m.arena, "mixScaleY", .{ .float = 1 });
                    }
                    for (floor_parts, &floors) |part, *floor| if (edit.take(c, part.mark)) |mark| {
                        floor.* = try m.floorMix(doc, c, &taken, &constraints, part, mark);
                    };
                    if (edit.take(c, marks.relative_scale) != null) relative = try m.relativeRig(doc, c, &taken);
                    if (edit.take(c, marks.local_wrap)) |mask| wrapped = try m.wrapRig(doc, c, &taken, mask.integer);
                    if (edit.take(c, marks.offset_unsigned) != null) {
                        // one wrap stays in range with the offset below 0
                        const offset = try edit.float(c, "rotation", 0);
                        _ = c.orderedRemove("rotation");
                        if ((try edit.childOf(c, "properties")).?.get("rotate")) |from| {
                            const rotate = from.object.get("to").?.object.getPtr("rotate").?;
                            try rotate.object.put(m.arena, "offset", .{ .float = if (offset > 0) offset - 360 else offset });
                        }
                    }
                    if (m.leads.get(try tree.requireString(.{ .object = c.* }, "name"))) |lead| {
                        _ = (try edit.childOf(c, "properties") orelse return error.Malformed).orderedRemove("shearY");
                        try constraints.append(.{ .object = lead });
                    }
                    if (m.signs.get(try tree.requireString(.{ .object = c.* }, "name"))) |sign| {
                        for (sign.pre) |p| try constraints.append(.{ .object = p });
                    }
                },
                2 => {
                    try m.rename(c, "target", "slot");
                    // early libgdx loaders read 1 here
                    const x = try edit.float(c, "mixX", 1);
                    if (c.get("mixY") == null and x != 1) try c.put(m.arena, "mixY", .{ .float = x });
                },
                else => {
                    try m.default(c, "inertia", 1);
                    try m.default(c, "damping", 1);
                },
            }
            // taken before the append copies the map
            const reset = e.kind == 0 and edit.take(c, marks.shear_reset) != null;
            const restores = edit.take(c, marks.restore);
            const gated = edit.take(c, marks.restore_gate);
            try c.put(m.arena, "type", .{ .string = kinds[e.kind] });
            try constraints.append(.{ .object = c.* });
            if (reset) try constraints.append(try m.shearReset(doc, c, &taken));
            if (proxy) |p| try constraints.append(p);
            for (floors) |floor| if (floor) |s| try constraints.append(s);
            if (e.kind == 1) if (m.helpers.get(try tree.requireString(.{ .object = c.* }, "name"))) |helper| {
                try constraints.append(.{ .object = helper });
            };
            try constraints.appendSlice(wrapped);
            if (e.kind == 1) if (m.signs.get(try tree.requireString(.{ .object = c.* }, "name"))) |sign| {
                try constraints.append(.{ .object = sign.post });
            };
            if (copies) |pair| for (pair) |t| try constraints.append(t);
            try constraints.appendSlice(relative);
            if (restores) |list| for (list.array.items) |bone| {
                var part = try m.rigPart(doc, c, &taken, try std.fmt.allocPrint(m.arena, "restore-{s}", .{bone.string}), try m.restoreBone(doc, bone.string, &restored), &.{bone.string}, false, &restore_links);
                if (gated) |g| if (std.mem.eql(u8, g.string, bone.string)) try m.gateRestore(doc, c, &taken, &constraints, &part);
                try constraints.append(part.value());
            };
            if (!neutral) for (bones) |b| try rescaled.put(m.arena, b.string, {});
        }
        if (constraints.items.len > 0) try doc.put(m.arena, "constraints", .{ .array = constraints });
    }

    fn mapScale(arena: std.mem.Allocator, properties_map: *ObjectMap, name: []const u8, scale: f32) Error!void {
        const from = properties_map.getPtr(name) orelse {
            var entry: ObjectMap = .empty;
            try entry.put(arena, "scale", .{ .float = scale });
            var to: ObjectMap = .empty;
            try to.put(arena, name, .{ .object = entry });
            var map: ObjectMap = .empty;
            try map.put(arena, "to", .{ .object = to });
            try properties_map.put(arena, name, .{ .object = map });
            return;
        };
        const to = (try edit.childOf(try edit.objectOf(from), "to") orelse return error.Malformed).getPtr(name) orelse return error.Malformed;
        try (try edit.objectOf(to)).put(arena, "scale", .{ .float = scale });
    }

    /// Helper under the root that copies the world scale of the source before the constraint
    fn snapshot(m: *Migration, doc: *ObjectMap, c: *ObjectMap, taken: *std.StringHashMapUnmanaged(void), out: *std.json.Array, names: *std.StringHashMapUnmanaged(void), root: []const u8) Error!Value {
        const name = try tree.requireString(.{ .object = c.* }, "name");
        const helper = try unique(m.arena, names, try std.fmt.allocPrint(m.arena, "{s}{s}-snapshot", .{ helper_prefix, name }));
        var bone: tree.Object = .init(m.arena);
        try bone.put("name", .{ .string = helper });
        try bone.put("parent", .{ .string = root });
        try (try edit.childValue(doc, "bones")).?.array.append(bone.value());
        var part = try m.rigPart(doc, c, taken, "snapshot", try tree.requireString(.{ .object = c.* }, "source"), &.{helper}, false, &.{
            .{ .from = "scaleX", .to = "scaleX" },
            .{ .from = "scaleY", .to = "scaleY" },
        });
        try part.put("localSource", .{ .bool = false });
        try part.put("localTarget", .{ .bool = false });
        try out.append(part.value());
        return .{ .string = helper };
    }

    /// Moves a one bone IK to a normal clone and copies its local result back
    fn proxyRig(m: *Migration, doc: *ObjectMap, c: *ObjectMap, taken: *std.StringHashMapUnmanaged(void)) Error!Value {
        const original = try tree.requireString(.{ .object = c.* }, "name");
        const ik_bones = try edit.arrayOf(c, "bones");
        if (ik_bones.len != 1 or ik_bones[0] != .string) return error.Malformed;
        const name = ik_bones[0].string;
        const helper = try m.cloneBone(doc, name, try std.fmt.allocPrint(m.arena, "{s}{s}-proxy", .{ helper_prefix, original }));
        ik_bones[0] = .{ .string = helper };
        var back = try m.rigPart(doc, c, taken, "proxy", helper, &.{name}, false, &.{
            .{ .from = "rotate", .to = "rotate" },
            .{ .from = "scaleX", .to = "scaleX" },
            .{ .from = "scaleY", .to = "scaleY" },
        });
        _ = &back;
        return back.value();
    }

    const restore_links = [_]Link{
        .{ .from = "rotate", .to = "rotate" },
        .{ .from = "x", .to = "x" },
        .{ .from = "y", .to = "y" },
        .{ .from = "scaleX", .to = "scaleX" },
        .{ .from = "scaleY", .to = "scaleY" },
        .{ .from = "shearY", .to = "shearY" },
    };

    /// Clone of a bone with its keys, one per restored bone
    fn restoreBone(m: *Migration, doc: *ObjectMap, bone: []const u8, restored: *std.StringHashMapUnmanaged([]const u8)) Error![]const u8 {
        if (restored.get(bone)) |helper| return helper;
        const helper = try m.cloneBone(doc, bone, try std.fmt.allocPrint(m.arena, "{s}{s}-restore", .{ helper_prefix, bone }));
        try restored.put(m.arena, bone, helper);
        return helper;
    }

    /// Adds a bone with the setup and keys of another one under the same parent
    fn cloneBone(m: *Migration, doc: *ObjectMap, name: []const u8, base: []const u8) Error![]const u8 {
        const list = try edit.childValue(doc, "bones") orelse return error.Malformed;
        var bone_names: std.StringHashMapUnmanaged(void) = .empty;
        for (list.array.items) |b| try bone_names.put(m.arena, try tree.requireString(b, "name"), {});
        const helper = try unique(m.arena, &bone_names, base);
        var h = (try edit.clone(m.arena, try boneOf(doc, name))).object;
        try h.put(m.arena, "name", .{ .string = helper });
        for ([_][]const u8{ "inherit", "color", "icon", "visible", "skin" }) |key| _ = h.orderedRemove(key);
        try list.array.append(.{ .object = h });
        if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |*animation| {
            const timelines = try edit.childOf(try edit.objectOf(animation), "bones") orelse continue;
            if (timelines.get(name)) |t| {
                var copy = try edit.clone(m.arena, t);
                _ = (try edit.objectOf(&copy)).orderedRemove("inherit");
                try timelines.put(m.arena, helper, copy);
            }
        };
        return helper;
    }

    /// 3.5 beta basis, local pose, then a turn back by the parent angle
    fn noRotationRigs(m: *Migration, doc: *ObjectMap) Error!void {
        const list = try edit.childValue(doc, "bones") orelse return;
        var taken: std.StringHashMapUnmanaged(void) = .empty;
        var bone_names: std.StringHashMapUnmanaged(void) = .empty;
        for (list.array.items) |b| try bone_names.put(m.arena, try tree.requireString(b, "name"), {});
        for (try edit.arrayOf(doc, "constraints")) |c| try taken.put(m.arena, try tree.requireString(c, "name"), {});
        if (try edit.childOf(doc, "animations")) |animations| for (animations.keys()) |name| try taken.put(m.arena, name, {});
        var rigs: std.ArrayList(Value) = .empty;
        const count = list.array.items.len;
        for (0..count) |i| {
            const bone = &list.array.items[i].object;
            if (edit.take(bone, marks.no_rotation) == null) continue;
            const name = try tree.requireString(.{ .object = bone.* }, "name");
            const parent = try tree.requireString(.{ .object = bone.* }, "parent");
            const names = [3][]const u8{
                try unique(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "{s}{s}-basis", .{ helper_prefix, name })),
                try unique(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "{s}{s}-local", .{ helper_prefix, name })),
                try unique(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "{s}{s}-turn", .{ helper_prefix, name })),
            };
            var helpers: [3]tree.Object = .{ .init(m.arena), .init(m.arena), .init(m.arena) };
            for (&helpers, names, [_][]const u8{ parent, names[0], names[1] }) |*h, n, p| {
                try h.put("name", .{ .string = n });
                try h.put("parent", .{ .string = p });
            }
            try helpers[0].put("inherit", .{ .string = "noRotationOrReflection" });
            for ([_][]const u8{ "rotation", "scaleX", "scaleY", "shearX", "shearY", "inherit" }) |key| if (bone.fetchOrderedRemove(key)) |kv| {
                if (!std.mem.eql(u8, key, "inherit")) try helpers[1].put(key, kv.value);
            };
            for (helpers) |h| try list.array.append(h.value());
            if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |*animation| {
                const timelines = try edit.childOf(try edit.objectOf(animation), "bones") orelse continue;
                const own = try edit.childOf(timelines, name) orelse continue;
                var moved: ObjectMap = .empty;
                for ([_][]const u8{ "rotate", "scale", "scalex", "scaley", "shear", "shearx", "sheary" }) |key| if (own.fetchOrderedRemove(key)) |kv| {
                    try moved.put(m.arena, key, kv.value);
                };
                if (moved.count() > 0) try timelines.put(m.arena, names[1], .{ .object = moved });
            };
            var owner: ObjectMap = .empty;
            try owner.put(m.arena, "name", .{ .string = name });
            const rotate = [_]Link{.{ .from = "rotate", .to = "rotate" }};
            var basis = try m.rigPart(doc, &owner, &taken, "basis", parent, &.{names[0]}, false, &rotate);
            var back = try m.rigPart(doc, &owner, &taken, "turn", parent, &.{names[2]}, false, &.{.{ .from = "rotate", .to = "rotate", .to_scale = -1 }});
            var copy = try m.rigPart(doc, &owner, &taken, "world", names[2], &.{name}, false, &.{
                .{ .from = "rotate", .to = "rotate" },
                .{ .from = "scaleX", .to = "scaleX" },
                .{ .from = "scaleY", .to = "scaleY" },
                .{ .from = "shearY", .to = "shearY" },
            });
            // the parent angle and the copy are world values
            try basis.put("localSource", .{ .bool = false });
            try back.put("localSource", .{ .bool = false });
            try copy.put("localSource", .{ .bool = false });
            try copy.put("localTarget", .{ .bool = false });
            try rigs.appendSlice(m.arena, &.{ basis.value(), back.value(), copy.value() });
        }
        if (rigs.items.len == 0) return;
        const entry = try doc.getOrPut(m.arena, "constraints");
        if (!entry.found_existing or entry.value_ptr.* != .array) entry.value_ptr.* = .{ .array = tree.array(m.arena) };
        try entry.value_ptr.array.insertSlice(0, rigs.items);
    }

    /// Slider whose animation keys the IK parent shear to 0
    fn shearReset(m: *Migration, doc: *ObjectMap, c: *ObjectMap, taken: *std.StringHashMapUnmanaged(void)) Error!Value {
        const name = try tree.requireString(.{ .object = c.* }, "name");
        const bones = try tree.getArray(.{ .object = c.* }, "bones");
        const parent = try boneOf(doc, bones[0].string);
        var key: tree.Object = .init(m.arena);
        try key.float("x", -try tree.getFloat(parent, "shearX", 0), 0);
        try key.float("y", -try tree.getFloat(parent, "shearY", 0), 0);
        var keys = tree.array(m.arena);
        try keys.append(key.value());
        var timeline: ObjectMap = .empty;
        try timeline.put(m.arena, "shear", .{ .array = keys });
        var timelines: ObjectMap = .empty;
        try timelines.put(m.arena, bones[0].string, .{ .object = timeline });
        var animation: ObjectMap = .empty;
        try animation.put(m.arena, "bones", .{ .object = timelines });
        const animation_name = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}{s}-shear", .{ helper_prefix, name }));
        if (try edit.childOf(doc, "animations") == null) try doc.put(m.arena, "animations", .{ .object = .empty });
        try (try edit.childOf(doc, "animations")).?.put(m.arena, animation_name, .{ .object = animation });

        var slider: tree.Object = .init(m.arena);
        const slider_name = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-shear", .{name}));
        try slider.put("name", .{ .string = slider_name });
        try m.joinSkins(doc, c, &slider, "slider", slider_name);
        try slider.put("type", .{ .string = "slider" });
        try slider.put("animation", .{ .string = animation_name });
        return slider.value();
    }

    /// 4.3 integrates physics with a lag 4.2 lacks
    fn checkPhysics(m: *Migration, doc: *ObjectMap) Error!void {
        for (try edit.arrayOf(doc, "physics")) |c| {
            const name = try tree.requireString(c, "name");
            var mix = try tree.getFloat(c, "mix", 1) != 0;
            for (try keyLists(m.arena, doc, &.{ "physics", name, "mix" })) |keys| for (keys) |key| {
                // the default of a missing value differs between the minors
                mix = mix or tree.get(key, "value") == null or try tree.getFloat(key, "value", 0) != 0;
            };
            if (!mix) continue;
            try m.report.add(.{
                .code = .@"physics.step.approximated",
                .step = m.step,
                .path = try m.path("physics", &c.object),
                .message = "physics steps through another integrator, trajectories differ",
                .remedy = .runtime,
            });
        }
    }

    /// 4.3 clamps length spacing at minus the bone length, 4.2 does not
    fn checkLengthSpacing(m: *Migration, doc: *ObjectMap, up_: bool) Error!void {
        var lengths: std.StringHashMapUnmanaged(f32) = .empty;
        for (try edit.arrayOf(doc, "bones")) |bone| {
            try lengths.put(m.arena, try tree.requireString(bone, "name"), try tree.getFloat(bone, "length", 0));
        }
        const animations = try edit.childOf(doc, "animations");
        for (try edit.arrayOf(doc, "path")) |*c| {
            if (!std.mem.eql(u8, try tree.getString(c.*, "spacingMode") orelse "length", "length")) continue;
            // a 3.5 source clamps like 4.3
            if (edit.take(try edit.objectOf(c), marks.length_clamped) != null) continue;
            var shortest = std.math.inf(f32);
            var common: ?f32 = null;
            var uniform = true;
            for (try tree.getArray(c.*, "bones")) |bone| {
                if (bone != .string) return error.Malformed;
                const length = lengths.get(bone.string) orelse return error.Malformed;
                if (length >= 0.00001) shortest = @min(shortest, length);
                if (length < 0.00001 or (common != null and common.? != length)) uniform = false;
                common = length;
            }
            const name = try tree.requireString(c.*, "name");
            var lowest = try tree.getFloat(c.*, "spacing", 0);
            if (animations) |all| {
                var it = all.iterator();
                while (it.next()) |animation| {
                    const timelines = try edit.childOf(try edit.objectOf(animation.value_ptr), "path") orelse continue;
                    const timeline = try edit.childOf(timelines, name) orelse continue;
                    const spacing = try edit.childValue(timeline, "spacing") orelse continue;
                    for (try edit.keysOf(spacing)) |key| {
                        lowest = @min(lowest, try tree.getFloat(key, "value", 0));
                        // a Bezier stays within its control values
                        const curve = tree.get(key, "curve") orelse continue;
                        if (curve != .array) continue;
                        for (curve.array.items, 0..) |v, i| if (i % 2 == 1) {
                            lowest = @min(lowest, try tree.number(v));
                        };
                    }
                }
            }
            if (shortest + lowest >= 0) continue;
            const where = try m.path("path", &c.object);
            if (up_ and m.rewrite and uniform and common != null) {
                try m.fixedSpacing(&c.object, animations, name, common.?);
                try m.lose(.@"path.length.rewritten", where, "length spacing moved to fixed spacing plus the bone length", .{});
            } else try m.lose(.@"path.length.approximated", where, "length spacing below minus the bone length", .{});
        }
    }

    /// Fixed spacing scales by the same length ratio without the clamp
    fn fixedSpacing(m: *Migration, c: *ObjectMap, animations: ?*ObjectMap, name: []const u8, length: f32) Error!void {
        try c.put(m.arena, "spacingMode", .{ .string = "fixed" });
        try c.put(m.arena, "spacing", .{ .float = try edit.float(c, "spacing", 0) + length });
        const all = animations orelse return;
        for (all.values()) |*animation| {
            const timelines = try edit.childOf(try edit.objectOf(animation), "path") orelse continue;
            const timeline = try edit.childOf(timelines, name) orelse continue;
            const spacing = try edit.childValue(timeline, "spacing") orelse continue;
            for (try edit.keysOf(spacing)) |*key| {
                const k = try edit.objectOf(key);
                try k.put(m.arena, "value", .{ .float = try edit.float(k, "value", 0) + length });
                const curve = k.getPtr("curve") orelse continue;
                if (curve.* != .array) continue;
                for (curve.array.items, 0..) |*v, i| if (i % 2 == 1) {
                    const shifted = try tree.number(v.*) + length;
                    v.* = .{ .float = shifted };
                };
            }
        }
    }

    /// Leaves the applied scale of its bones as it found them
    fn scaleNeutral(m: *Migration, doc: *ObjectMap, c: *ObjectMap, kind: usize, bones: []const Value) Error!bool {
        for (c.keys()) |key| if (std.mem.startsWith(u8, key, "spine-converter-")) return false;
        const name = try tree.requireString(.{ .object = c.* }, "name");
        switch (kind) {
            0 => {
                if (try tree.getBool(.{ .object = c.* }, "stretch", false) or try tree.getBool(.{ .object = c.* }, "compress", false)) return false;
                for (try keyLists(m.arena, doc, &.{ "ik", name })) |list| for (list) |key| {
                    if (try tree.getBool(key, "stretch", false) or try tree.getBool(key, "compress", false)) return false;
                };
                return true;
            },
            1 => {
                if (m.helpers.contains(name) or m.leads.contains(name)) return false;
                const r = try mixRanges(m.arena, doc, c);
                for (r[3..5]) |x| if (x.min != 0 or x.max != 0) return false;
                if (try tree.getBool(.{ .object = c.* }, "local", false)) return true;
                for ([_]Range{ r[0], r[5] }) |x| if (x.min != 0 or x.max != 0) return false;
                for (bones) |b| {
                    const inherit = try tree.getString(try boneOf(doc, b.string), "inherit") orelse continue;
                    if (!std.mem.eql(u8, inherit, "normal")) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    /// Steady holds the applied scales when they and the mixes never change
    fn upTransform(m: *Migration, c: *ObjectMap, steady: ?[2]f32, unit: bool, live: bool, rig: ?Rig) Error!void {
        var divided = false;
        var rigged = false;
        try m.rename(c, "target", "source");
        const local = try edit.takeBool(c, "local");
        const relative = try edit.takeBool(c, "relative");
        if (local) {
            try c.put(m.arena, "localSource", .{ .bool = true });
            try c.put(m.arena, "localTarget", .{ .bool = true });
            if (!relative and (try edit.float(c, "mixScaleX", 1) != 0 or c.get("mixScaleY") != null)) {
                if (unit) {} else if (m.rewrite and steady != null) {
                    divided = true;
                    try m.lose(.@"transform.scale.rewritten", try m.path("transform", c), "local absolute scale division folded into the scale mapping", .{});
                } else if (m.rewrite and rig != null and try m.rigScale(rig.?, c)) {
                    rigged = true;
                    try m.lose(.@"transform.scale.rewritten", try m.path("transform", c), "local absolute scale division rebuilt with sliders", .{});
                } else try m.report.add(.{
                    .code = .@"transform.scale.approximated",
                    .step = m.step,
                    .path = try m.path("transform", c),
                    .message = "local absolute scale divides by the bone scale in 4.2",
                    .remedy = if (live) .runtime else .none,
                });
            }
        }
        if (relative) try c.put(m.arena, "additive", .{ .bool = true });
        const mix_x = try edit.float(c, "mixScaleX", 1);
        const mix_y = try edit.float(c, "mixScaleY", mix_x);
        if (divided) {
            try c.put(m.arena, "mixScaleX", .{ .float = if (mix_x != 0 and steady.?[0] != 0) 1 else 0 });
            try c.put(m.arena, "mixScaleY", .{ .float = if (mix_y != 0 and steady.?[1] != 0) 1 else 0 });
        }
        if (rigged) {
            try c.put(m.arena, "mixScaleX", .{ .float = 0 });
            try c.put(m.arena, "mixScaleY", .{ .float = 0 });
        }
        var map: ObjectMap = .empty;
        for (properties) |p| {
            var entry: ObjectMap = .empty;
            const axis: ?usize = if (std.mem.eql(u8, p, "scaleX")) 0 else if (std.mem.eql(u8, p, "scaleY")) 1 else null;
            if (divided) if (axis) |a| {
                // 4.2 gives 1 + (value / s - 1) * mix
                const mix = if (a == 0) mix_x else mix_y;
                if (mix != 0 and steady.?[a] != 0) {
                    try entry.put(m.arena, "offset", .{ .float = 1 - mix });
                    try entry.put(m.arena, "scale", .{ .float = mix / steady.?[a] });
                }
            };
            var to: ObjectMap = .empty;
            try to.put(m.arena, p, .{ .object = entry });
            var from: ObjectMap = .empty;
            try from.put(m.arena, "to", .{ .object = to });
            try map.put(m.arena, p, .{ .object = from });
        }
        try c.put(m.arena, "properties", .{ .object = map });
    }

    /// Rebuilds the 4.2 division by a keyed bone scale
    fn rigScale(m: *Migration, rig: Rig, c: *ObjectMap) Error!bool {
        const name = try tree.requireString(.{ .object = c.* }, "name");
        const source = try tree.requireString(.{ .object = c.* }, "source");
        const mix_x = try edit.float(c, "mixScaleX", 1);
        const mix = [2]f32{ mix_x, try edit.float(c, "mixScaleY", mix_x) };
        const bones = try bonesOf(m.arena, .{ .object = c.* }, 1);
        const all = try mixRanges(m.arena, rig.doc, c);
        const ranges = [2]Range{ all[3], all[4] };
        var active: [2]bool = undefined;
        var used: [2]bool = @splat(false);
        var gates: [2]bool = @splat(false);
        for (&active, ranges, &gates) |*on, r, *g| {
            on.* = r.min != 0 or r.max != 0;
            if (!on.* or r.min > 0 or r.max < 0) continue;
            // 4.2 skips a zero mix and applies every other, a gate holds a mix of one sign
            if (r.min < 0 and r.max > 0 or @max(r.max, -r.min) < gate_start) return false;
            g.* = true;
        }
        if (gates[0] or gates[1]) {
            // one gate serves both axes only when they share every mix
            if (c.get(marks.scale_floor) != null) return false;
            if (active[0] and active[1] and !(gates[0] and gates[1] and try sameScaleMixes(m.arena, rig.doc, c))) return false;
        }
        const Helper = struct { bone: []const u8, axis: usize, keys: Value, negative: bool };
        var helpers: std.ArrayList(Helper) = .empty;
        for (bones) |b| {
            if (std.mem.eql(u8, b.string, source)) return false;
            const bone = try boneOf(rig.doc, b.string);
            for (0..2, scale_axes) |axis, field| {
                if (!active[axis]) continue;
                const setup = try tree.getFloat(bone, field, 1);
                const span = try scaleSpan(m.arena, rig.doc, b.string, axis, setup);
                // 4.3 skips a bone scale of 0 as well
                if (span[0] == 0 and span[1] == 0) continue;
                const negative = span[1] < 0;
                if (!std.math.isFinite(span[0]) or !std.math.isFinite(span[1]) or !negative and !(span[0] > 0)) return false;
                const lo = if (negative) -span[1] else span[0];
                const hi = if (negative) -span[0] else span[1];
                if (!std.math.isNormal(lo) or !std.math.isNormal(1 / (lo * setup))) return false;
                var keys = try reciprocalKeys(m.arena, lo, hi, setup, if (negative) -1 else 1) orelse return false;
                // the slider skips times before the first key
                var hold: tree.Object = .init(m.arena);
                try hold.float("value", try tree.getFloat(keys.array.items[0], "value", 1), 1);
                try keys.array.insert(0, hold.value());
                try helpers.append(m.arena, .{ .bone = b.string, .axis = axis, .keys = keys, .negative = negative });
                used[axis] = true;
            }
        }
        for (&active, used) |*on, u| on.* = on.* and u;
        if (helpers.items.len == 0) {
            try m.silence(rig.doc, name);
            return true;
        }
        if (try edit.childOf(rig.doc, "animations") == null) try rig.doc.put(m.arena, "animations", .{ .object = .empty });
        const animations = (try edit.childOf(rig.doc, "animations")).?;
        for (&gates, active) |*g, on| g.* = g.* and on;
        const gate: ?usize = if (gates[0]) 0 else if (gates[1]) 1 else null;
        var gated: std.ArrayList([]const u8) = .empty;
        var gate_bone: []const u8 = undefined;
        var gate_animation: []const u8 = undefined;
        const negative_gate = if (gate) |axis| ranges[axis].max == 0 else false;
        if (gate) |axis| {
            const bones_list = try edit.arrayOf(rig.doc, "bones");
            var bone_names: std.StringHashMapUnmanaged(void) = .empty;
            for (bones_list) |b| try bone_names.put(m.arena, try tree.requireString(b, "name"), {});
            gate_bone = try unique(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "{s}{s}-scaleMix", .{ helper_prefix, name }));
            var helper: tree.Object = .init(m.arena);
            try helper.put("name", .{ .string = gate_bone });
            try helper.put("parent", .{ .string = try tree.requireString(bones_list[0], "name") });
            try helper.float("x", mix[axis], 0);
            try (try edit.childValue(rig.doc, "bones")).?.array.append(helper.value());
            gate_animation = try unique(m.arena, rig.taken, try std.fmt.allocPrint(m.arena, "{s}{s}-scaleMix", .{ helper_prefix, name }));
            var slider: tree.Object = .init(m.arena);
            const slider_name = try unique(m.arena, rig.taken, try std.fmt.allocPrint(m.arena, "{s}-scaleMix", .{name}));
            try slider.put("name", .{ .string = slider_name });
            try m.joinSkins(rig.doc, c, &slider, "slider", slider_name);
            try slider.put("type", .{ .string = "slider" });
            try slider.put("bone", .{ .string = gate_bone });
            try slider.put("property", .{ .string = "x" });
            try slider.put("local", .{ .bool = true });
            // slider time stays at or above 0
            if (negative_gate) try slider.put("scale", .{ .float = -1 });
            try slider.put("animation", .{ .string = gate_animation });
            try rig.out.append(slider.value());
        }
        for (helpers.items) |h| {
            const axis = scale_axes[h.axis];
            const animation = try unique(m.arena, rig.taken, try std.fmt.allocPrint(m.arena, "{s}{s}-{s}-{s}", .{ helper_prefix, name, h.bone, axis }));
            var timelines: ObjectMap = .empty;
            try timelines.put(m.arena, if (h.axis == 0) "scalex" else "scaley", h.keys);
            var bone: ObjectMap = .empty;
            try bone.put(m.arena, h.bone, .{ .object = timelines });
            var map: ObjectMap = .empty;
            try map.put(m.arena, "bones", .{ .object = bone });
            try animations.put(m.arena, animation, .{ .object = map });
            var slider: tree.Object = .init(m.arena);
            const slider_name = try unique(m.arena, rig.taken, try std.fmt.allocPrint(m.arena, "{s}-{s}-{s}", .{ name, h.bone, axis }));
            try slider.put("name", .{ .string = slider_name });
            try m.joinSkins(rig.doc, c, &slider, "slider", slider_name);
            try slider.put("type", .{ .string = "slider" });
            try slider.put("bone", .{ .string = h.bone });
            try slider.put("property", .{ .string = axis });
            try slider.put("local", .{ .bool = true });
            if (h.negative) try slider.put("scale", .{ .float = -1 });
            try slider.put("animation", .{ .string = animation });
            try rig.out.append(slider.value());
            if (gates[h.axis]) try gated.append(m.arena, slider_name);
        }
        var mix_name: []const u8 = undefined;
        var multiply_name: []const u8 = undefined;
        for ([_][]const u8{ "source", "mix" }) |role| {
            var t: tree.Object = .init(m.arena);
            mix_name = try unique(m.arena, rig.taken, try std.fmt.allocPrint(m.arena, "{s}-scale-{s}", .{ name, role }));
            if (role[0] == 's') multiply_name = mix_name;
            try t.put("name", .{ .string = mix_name });
            try m.joinSkins(rig.doc, c, &t, "transform", mix_name);
            try t.put("type", .{ .string = "transform" });
            try t.put("bones", c.get("bones") orelse return error.Malformed);
            try t.put("source", .{ .string = source });
            try t.put("localSource", .{ .bool = true });
            try t.put("localTarget", .{ .bool = true });
            const multiply = std.mem.eql(u8, role, "source");
            if (multiply) {
                try t.put("additive", .{ .bool = true });
                for (scale_axes) |field| if (c.get(field)) |offset| try t.put(field, offset);
            }
            var map: ObjectMap = .empty;
            for (0..2, scale_axes) |axis, field| {
                try t.put(if (axis == 0) "mixScaleX" else "mixScaleY", .{ .float = if (!active[axis]) 0 else if (multiply) 1 else 1 - mix[axis] });
                var entry: ObjectMap = .empty;
                // the mix pass reads a constant one
                if (!multiply) {
                    try entry.put(m.arena, "offset", .{ .float = 1 });
                    try entry.put(m.arena, "scale", .{ .float = 0 });
                }
                var to: ObjectMap = .empty;
                try to.put(m.arena, field, .{ .object = entry });
                var from: ObjectMap = .empty;
                try from.put(m.arena, "to", .{ .object = to });
                try map.put(m.arena, field, .{ .object = from });
            }
            for ([_][]const u8{ "mixRotate", "mixX", "mixY", "mixShearY" }) |other| try t.put(other, .{ .float = 0 });
            try t.put("properties", .{ .object = map });
            try rig.out.append(t.value());
        }
        for (animations.values()) |*animation| {
            const timelines = try edit.childOf(try edit.objectOf(animation), "transform") orelse continue;
            const keys = timelines.getPtr(name) orelse continue;
            var copy = tree.array(m.arena);
            for (try edit.keysOf(keys)) |*key| {
                const k = try edit.objectOf(key);
                var out: tree.Object = .init(m.arena);
                if (k.get("time")) |time| try out.put("time", time);
                const x = try edit.float(k, "mixScaleX", 1);
                const values = [2]f32{ x, try edit.float(k, "mixScaleY", x) };
                if (gate) |axis| {
                    try out.float("value", values[axis] - mix[axis], 0);
                    try k.put(m.arena, "mixScaleX", .{ .float = 0 });
                    try k.put(m.arena, "mixScaleY", .{ .float = 0 });
                    if (k.getPtr("curve")) |curve| if (curve.* == .array) {
                        var handles = tree.array(m.arena);
                        for (0..4) |i| {
                            const v = try tree.number(curve.array.items[(3 + axis) * 4 + i]);
                            try handles.append(.{ .float = if (i % 2 == 0) v else v - mix[axis] });
                        }
                        try out.put("curve", .{ .array = handles });
                        for ([_]usize{ 13, 15, 17, 19 }) |i| curve.array.items[i] = .{ .float = 0 };
                    } else try out.put("curve", curve.*);
                    try copy.append(out.value());
                    continue;
                }
                for (mixes, 0..) |field, i| {
                    const axis = i -% 3;
                    try out.put(field, .{ .float = if (axis < 2 and active[axis]) 1 - values[axis] else 0 });
                }
                try k.put(m.arena, "mixScaleX", .{ .float = 0 });
                try k.put(m.arena, "mixScaleY", .{ .float = 0 });
                if (k.getPtr("curve")) |curve| if (curve.* == .array) {
                    var handles = tree.array(m.arena);
                    for (curve.array.items, 0..) |v, i| {
                        const axis = i / 4 -% 3;
                        // time handles and scale value handles survive
                        const value = if (i % 2 == 0) try tree.number(v) else if (axis < 2 and active[axis]) 1 - try tree.number(v) else 0;
                        try handles.append(.{ .float = value });
                        if (axis < 2 and i % 2 == 1) curve.array.items[i] = .{ .float = 0 };
                    }
                    try out.put("curve", .{ .array = handles });
                } else try out.put("curve", curve.*);
                try copy.append(out.value());
            }
            if (gate == null) {
                try timelines.put(m.arena, mix_name, .{ .array = copy });
                continue;
            }
            const owner = try edit.objectOf(animation);
            if (try edit.childOf(owner, "bones") == null) try owner.put(m.arena, "bones", .{ .object = .empty });
            var timeline: ObjectMap = .empty;
            try timeline.put(m.arena, "translatex", .{ .array = copy });
            try (try edit.childOf(owner, "bones")).?.put(m.arena, gate_bone, .{ .object = timeline });
        }
        if (gate) |axis| try m.gateRamp(rig.doc, gate_animation, gated.items, .{ multiply_name, mix_name }, gates, ranges[axis], negative_gate);
        return true;
    }

    /// Turns the gate on at the first mix above 0 and ramps the pass toward 1
    fn gateRamp(m: *Migration, doc: *ObjectMap, animation: []const u8, sliders: []const []const u8, passes: [2][]const u8, gates: [2]bool, range: Range, negative: bool) Error!void {
        const animations = (try edit.childOf(doc, "animations")).?;
        const top = @max(range.max, -range.min);
        var timelines: [2]std.json.Array = .{ tree.array(m.arena), tree.array(m.arena) };
        var slider_keys = tree.array(m.arena);
        for ([_]f32{ 0, gate_start, top }, 0..) |t, i| {
            const on = i > 0;
            var slider_key: tree.Object = .init(m.arena);
            try slider_key.float("time", t, 0);
            try slider_key.put("value", .{ .float = if (on) 1 else 0 });
            if (i == 0) try slider_key.put("curve", .{ .string = "stepped" });
            try slider_keys.append(slider_key.value());
            for (&timelines, 0..) |*list, pass| {
                var key: tree.Object = .init(m.arena);
                try key.float("time", t, 0);
                if (i == 0) try key.put("curve", .{ .string = "stepped" });
                for (mixes, 0..) |field, f| {
                    const value: f32 = if (f < 3 or f > 4 or !gates[f - 3] or !on) 0 else if (pass == 0) 1 else 1 - (if (negative) -t else t);
                    try key.put(field, .{ .float = value });
                }
                try list.append(key.value());
            }
        }
        var transform: ObjectMap = .empty;
        for (passes, timelines) |pass, list| try transform.put(m.arena, pass, .{ .array = list });
        var out: ObjectMap = .empty;
        try out.put(m.arena, "transform", .{ .object = transform });
        var slider: ObjectMap = .empty;
        for (sliders) |name| {
            var one: ObjectMap = .empty;
            try one.put(m.arena, "mix", .{ .array = slider_keys });
            try slider.put(m.arena, name, .{ .object = one });
        }
        if (sliders.len > 0) try out.put(m.arena, "slider", .{ .object = slider });
        try animations.put(m.arena, animation, .{ .object = out });
    }

    /// Zeroes the scale mix keys of a constraint with nothing left to scale
    fn silence(m: *Migration, doc: *ObjectMap, name: []const u8) Error!void {
        const animations = try edit.childOf(doc, "animations") orelse return;
        for (animations.values()) |*animation| {
            const timelines = try edit.childOf(try edit.objectOf(animation), "transform") orelse continue;
            const keys = timelines.getPtr(name) orelse continue;
            for (try edit.keysOf(keys)) |*key| {
                const k = try edit.objectOf(key);
                try k.put(m.arena, "mixScaleX", .{ .float = 0 });
                try k.put(m.arena, "mixScaleY", .{ .float = 0 });
                if (k.getPtr("curve")) |curve| if (curve.* == .array) {
                    for ([_]usize{ 13, 15, 17, 19 }) |i| curve.array.items[i] = .{ .float = 0 };
                };
            }
        }
    }

    /// Holds the path mix of one channel as the x of a helper bone
    fn pathMixBone(m: *Migration, doc: *ObjectMap, name: []const u8, suffix: []const u8, field: []const u8, channel: usize, setup: f32, root: []const u8, names: *std.StringHashMapUnmanaged(void)) Error![]const u8 {
        const helper = try unique(m.arena, names, try std.fmt.allocPrint(m.arena, "{s}{s}-{s}Mix", .{ helper_prefix, name, suffix }));
        var bone: tree.Object = .init(m.arena);
        try bone.put("name", .{ .string = helper });
        try bone.put("parent", .{ .string = root });
        try bone.float("x", setup, 0);
        try (try edit.childValue(doc, "bones")).?.array.append(bone.value());
        const animations = (try edit.childOf(doc, "animations")).?;
        for (animations.values()) |*animation| {
            const owner = try edit.objectOf(animation);
            const timelines = try edit.childOf(owner, "path") orelse continue;
            const entry = timelines.getPtr(name) orelse continue;
            const keys = try edit.childValue(try edit.objectOf(entry), "mix") orelse continue;
            var moved = tree.array(m.arena);
            for (try edit.keysOf(keys)) |*key| {
                const k = try edit.objectOf(key);
                var out_key: tree.Object = .init(m.arena);
                if (k.get("time")) |time| try out_key.put("time", time);
                try out_key.float("value", try edit.float(k, field, 1) - setup, 0);
                if (k.get("curve")) |curve| if (curve == .array) {
                    if (curve.array.items.len < channel * 4 + 4) return error.Malformed;
                    var handles = tree.array(m.arena);
                    for (channel * 4..channel * 4 + 4) |i| {
                        const v = try tree.number(curve.array.items[i]);
                        try handles.append(.{ .float = if (i % 2 == 0) v else v - setup });
                    }
                    try out_key.put("curve", .{ .array = handles });
                } else try out_key.put("curve", curve);
                try moved.append(out_key.value());
            }
            if (try edit.childOf(owner, "bones") == null) try owner.put(m.arena, "bones", .{ .object = .empty });
            var timeline: ObjectMap = .empty;
            try timeline.put(m.arena, "translatex", .{ .array = moved });
            try (try edit.childOf(owner, "bones")).?.put(m.arena, helper, .{ .object = timeline });
        }
        return helper;
    }

    fn pathSlider(m: *Migration, out: *std.json.Array, base: []const u8, bone: ?[]const u8, animation: []const u8, additive: bool) Error!void {
        var slider: tree.Object = .init(m.arena);
        try slider.put("name", .{ .string = base });
        try slider.put("type", .{ .string = "slider" });
        if (bone) |b| {
            try slider.put("bone", .{ .string = b });
            try slider.put("property", .{ .string = "x" });
            try slider.put("local", .{ .bool = true });
        }
        if (additive) try slider.put("additive", .{ .bool = true });
        try slider.put("animation", .{ .string = animation });
        try out.append(slider.value());
    }

    /// Zeroes the path mixes while neither the rotate nor the translate mix is positive
    fn pathGate(m: *Migration, doc: *ObjectMap, c: *ObjectMap, taken: *std.StringHashMapUnmanaged(void), out: *std.json.Array) Error!void {
        const name = try tree.requireString(.{ .object = c.* }, "name");
        const bones = try edit.arrayOf(doc, "bones");
        if (bones.len == 0) return error.Malformed;
        const root = try tree.requireString(bones[0], "name");
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (bones) |b| try names.put(m.arena, try tree.requireString(b, "name"), {});
        if (try edit.childOf(doc, "animations") == null) try doc.put(m.arena, "animations", .{ .object = .empty });
        const animations = (try edit.childOf(doc, "animations")).?;
        const rotate = try m.pathMixBone(doc, name, "rotate", "mixRotate", 0, try edit.float(c, "mixRotate", 1), root, &names);
        const translate = try m.pathMixBone(doc, name, "translate", "mixX", 1, try edit.float(c, "mixX", 1), root, &names);
        const gate = try unique(m.arena, &names, try std.fmt.allocPrint(m.arena, "{s}{s}-pathGate", .{ helper_prefix, name }));
        var bone: tree.Object = .init(m.arena);
        try bone.put("name", .{ .string = gate });
        try bone.put("parent", .{ .string = root });
        try (try edit.childValue(doc, "bones")).?.array.append(bone.value());

        const turn_on = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}{s}-pathGate", .{ helper_prefix, name }));
        var ramp = tree.array(m.arena);
        for ([_]f32{ 0, gate_start }) |t| {
            var key: tree.Object = .init(m.arena);
            try key.float("time", t, 0);
            try key.put("value", .{ .float = if (t == 0) 0 else 1 });
            if (t == 0) try key.put("curve", .{ .string = "stepped" });
            try ramp.append(key.value());
        }
        var translatex: ObjectMap = .empty;
        try translatex.put(m.arena, "translatex", .{ .array = ramp });
        var on: ObjectMap = .empty;
        try on.put(m.arena, gate, .{ .object = translatex });
        var first: ObjectMap = .empty;
        try first.put(m.arena, "bones", .{ .object = on });
        try animations.put(m.arena, turn_on, .{ .object = first });

        const turn_off = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}{s}-pathGateMix", .{ helper_prefix, name }));
        const zero = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}{s}-pathZero", .{ helper_prefix, name }));
        const off = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-pathOff", .{name}));
        var steps = tree.array(m.arena);
        for ([_]f32{ 0, 1 }) |t| {
            var key: tree.Object = .init(m.arena);
            try key.float("time", t, 0);
            try key.put("value", .{ .float = 1 - t });
            try key.put("curve", .{ .string = "stepped" });
            try steps.append(key.value());
        }
        var mix_timeline: ObjectMap = .empty;
        try mix_timeline.put(m.arena, "mix", .{ .array = steps });
        var by_name: ObjectMap = .empty;
        try by_name.put(m.arena, off, .{ .object = mix_timeline });
        var second: ObjectMap = .empty;
        try second.put(m.arena, "slider", .{ .object = by_name });
        try animations.put(m.arena, turn_off, .{ .object = second });

        var clear: tree.Object = .init(m.arena);
        try clear.put("time", .{ .float = 0 });
        for ([_][]const u8{ "mixRotate", "mixX", "mixY" }) |field| try clear.put(field, .{ .float = 0 });
        var key_list = tree.array(m.arena);
        try key_list.append(clear.value());
        var zero_mix: ObjectMap = .empty;
        try zero_mix.put(m.arena, "mix", .{ .array = key_list });
        var zero_path: ObjectMap = .empty;
        try zero_path.put(m.arena, name, .{ .object = zero_mix });
        var third: ObjectMap = .empty;
        try third.put(m.arena, "path", .{ .object = zero_path });
        try animations.put(m.arena, zero, .{ .object = third });

        try m.pathSlider(out, try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-pathRotate", .{name})), rotate, turn_on, false);
        try m.pathSlider(out, try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-pathTranslate", .{name})), translate, turn_on, true);
        try m.pathSlider(out, try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-pathGate", .{name})), gate, turn_off, false);
        try m.pathSlider(out, off, null, zero, false);
    }

    /// Rebuilds the 3.8 skip of a world scale mix turn_on to 0
    fn floorMix(m: *Migration, doc: *ObjectMap, c: *ObjectMap, taken: *std.StringHashMapUnmanaged(void), out: *std.json.Array, part: Floor, mark: Value) Error!?Value {
        const name = try tree.requireString(.{ .object = c.* }, "name");
        const gate_on = try gating.gateSetup(c);
        if (part.signed and try m.gateBlocked(doc, c, mark)) return null;
        const setup = try edit.float(c, part.mixes[0], 1);
        var range: Range = .of(setup);
        try range.keys(try keyLists(m.arena, doc, &.{ "transform", name }), part.mixes[0], 1, part.channel);
        const bones = try edit.arrayOf(doc, "bones");
        if (bones.len == 0) return error.Malformed;
        const root = try tree.requireString(bones[0], "name");
        var bone_names: std.StringHashMapUnmanaged(void) = .empty;
        for (bones) |b| try bone_names.put(m.arena, try tree.requireString(b, "name"), {});
        const helper = try unique(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "{s}{s}-{s}Mix", .{ helper_prefix, name, part.suffix }));
        var bone: tree.Object = .init(m.arena);
        try bone.put("name", .{ .string = helper });
        try bone.put("parent", .{ .string = root });
        try bone.float("x", setup, 0);
        try (try edit.childValue(doc, "bones")).?.array.append(bone.value());

        const source = if (std.mem.eql(u8, part.suffix, "scale") and edit.take(c, marks.scale_snapshot) != null) try m.snapshot(doc, c, taken, out, &bone_names, root) else c.get("source") orelse return error.Malformed;
        // a relative constraint already has its shear in helpers
        const copy = !(std.mem.eql(u8, part.suffix, "shear") and try tree.getBool(.{ .object = c.* }, "additive", false) and !try tree.getBool(.{ .object = c.* }, "localTarget", false));
        var scale: tree.Object = .init(m.arena);
        const scale_name = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-{s}", .{ name, part.suffix }));
        if (copy) {
            try scale.put("name", .{ .string = scale_name });
            try m.joinSkins(doc, c, &scale, "transform", scale_name);
            try scale.put("type", .{ .string = "transform" });
            try scale.put("bones", c.get("bones") orelse return error.Malformed);
            try scale.put("source", source);
            for ([_][]const u8{ "additive", "localSource", "localTarget" }) |key| if (c.get(key)) |v| try scale.put(key, v);
            for (part.properties) |field| if (c.get(field)) |offset| try scale.put(field, offset);
            var map: ObjectMap = .empty;
            const mapping = try edit.childOf(c, "properties") orelse return error.Malformed;
            for (part.properties) |field| try map.put(m.arena, field, mapping.get(field) orelse return error.Malformed);
            try scale.put("properties", .{ .object = map });
            for (mixes) |field| {
                const on = edit.indexOf(part.mixes, field) != null;
                try scale.put(field, .{ .float = if (on and !part.signed) @max(setup, 0) else 0 });
            }
        }
        for (part.mixes) |field| try c.put(m.arena, field, .{ .float = 0 });
        const slider_name = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-{s}Mix", .{ name, part.suffix }));
        var extras: std.ArrayList([]const u8) = .empty;
        if (std.mem.eql(u8, part.suffix, "shear")) {
            if (m.helpers.getPtr(name)) |split| {
                try split.put(m.arena, "mixShearY", .{ .float = 0 });
                try extras.append(m.arena, split.get("name").?.string);
            }
            if (m.signs.getPtr(name)) |sign| {
                try sign.post.put(m.arena, "mixShearY", .{ .float = 0 });
                try extras.append(m.arena, sign.post.get("name").?.string);
            }
            for (extras.items) |extra| try m.gated.put(m.arena, extra, {});
        }

        const animations = (try edit.childOf(doc, "animations")).?;
        for (animations.values()) |*animation| {
            const owner = try edit.objectOf(animation);
            const timelines = try edit.childOf(owner, "transform") orelse continue;
            const keys = timelines.getPtr(name) orelse continue;
            if (part.signed) try m.gateTimeline(owner, slider_name, try gating.gateKeys(m.arena, try edit.keysOf(keys)));
            var moved = tree.array(m.arena);
            for (try edit.keysOf(keys)) |*key| {
                const k = try edit.objectOf(key);
                var out_key: tree.Object = .init(m.arena);
                if (k.get("time")) |time| try out_key.put("time", time);
                try out_key.float("value", try edit.float(k, part.mixes[0], 1) - setup, 0);
                for (part.mixes) |field| try k.put(m.arena, field, .{ .float = 0 });
                if (k.getPtr("curve")) |curve| if (curve.* == .array) {
                    const first = part.channel * 4;
                    if (curve.array.items.len < first + part.mixes.len * 4) return error.Malformed;
                    var handles = tree.array(m.arena);
                    for (first..first + 4) |i| {
                        const v = try tree.number(curve.array.items[i]);
                        try handles.append(.{ .float = if (i % 2 == 0) v else v - setup });
                    }
                    for (0..part.mixes.len * 2) |i| curve.array.items[first + 1 + i * 2] = .{ .float = 0 };
                    try out_key.put("curve", .{ .array = handles });
                } else try out_key.put("curve", curve.*);
                try moved.append(out_key.value());
            }
            if (try edit.childOf(owner, "bones") == null) try owner.put(m.arena, "bones", .{ .object = .empty });
            var timeline: ObjectMap = .empty;
            try timeline.put(m.arena, "translatex", .{ .array = moved });
            try (try edit.childOf(owner, "bones")).?.put(m.arena, helper, .{ .object = timeline });
        }

        // slider time stays at or above 0, so it reads max(0, mix) unless signed
        const animation = try unique(m.arena, taken, helper);
        var ramp = tree.array(m.arena);
        const low: f32 = if (part.signed) range.min else 0;
        const ends = [2]f32{ low, if (part.signed) range.max else @max(range.max, 0) };
        for (ends, 0..) |end, i| {
            if (part.signed and i == 1 and ends[0] == ends[1]) break;
            var key: tree.Object = .init(m.arena);
            try key.float("time", end - low, 0);
            for (mixes) |field| try key.put(field, .{ .float = if (edit.indexOf(part.mixes, field) != null) end else 0 });
            try ramp.append(key.value());
        }
        var transform: ObjectMap = .empty;
        if (copy) try transform.put(m.arena, scale_name, .{ .array = ramp });
        for (extras.items) |extra| try transform.put(m.arena, extra, try edit.clone(m.arena, .{ .array = ramp }));
        var timelines: ObjectMap = .empty;
        try timelines.put(m.arena, "transform", .{ .object = transform });
        try animations.put(m.arena, animation, .{ .object = timelines });

        var slider: tree.Object = .init(m.arena);
        try slider.put("name", .{ .string = slider_name });
        try m.joinSkins(doc, c, &slider, "slider", slider_name);
        try slider.put("type", .{ .string = "slider" });
        try slider.put("bone", .{ .string = helper });
        try slider.put("property", .{ .string = "x" });
        try slider.float("from", low, 0);
        try slider.put("local", .{ .bool = true });
        if (part.signed) try slider.float("mix", if (gate_on) 1 else 0, 1);
        try slider.put("animation", .{ .string = animation });
        try out.append(slider.value());
        return if (copy) scale.value() else null;
    }

    /// Keeps the 4.0 skip when a rig already took the scale mix, true when it cannot
    fn gateBlocked(m: *Migration, doc: *ObjectMap, c: *ObjectMap, mark: Value) Error!bool {
        const x = try edit.float(c, "mixScaleX", 1);
        if (c.get("mixScaleY") == null) try c.put(m.arena, "mixScaleY", .{ .float = x });
        const name = try tree.requireString(.{ .object = c.* }, "name");
        for (try keyLists(m.arena, doc, &.{ "transform", name })) |list| for (list) |*key| {
            const k = try edit.objectOf(key);
            const key_x = try edit.float(k, "mixScaleX", 1);
            if (k.get("mixScaleY") == null) try k.put(m.arena, "mixScaleY", .{ .float = key_x });
        };
        const ranges = try mixRanges(m.arena, doc, c);
        const range = ranges[4];
        // the gate scales after the shear, a negative factor only commutes with no shear
        const flips = ranges[5].min != 0 or ranges[5].max != 0;
        const safe = range.min >= 0 and range.max <= 1 and try edit.float(c, "scaleY", 0) >= 0;
        const taken = c.get(marks.relative_scale) != null or c.get(marks.scale_floor) != null;
        if ((range.min != 0 or range.max != 0) and !taken and (safe or !flips)) return false;
        try gating.zeroSkipped(m.arena, doc, c);
        const step = if (mark == .string) mark.string else m.step;
        const tail = try std.fmt.allocPrint(m.arena, ".transform.{s}", .{name});
        const own = try m.path("transform", c);
        var i = m.report.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = m.report.entries.items[i];
            if (e.code != .@"transform.mixScaleY.rewritten" or !std.mem.eql(u8, e.step, step)) continue;
            if (!std.mem.eql(u8, e.path, own) and !(std.mem.startsWith(u8, e.path, "animations.") and std.mem.endsWith(u8, e.path, tail))) continue;
            _ = m.report.entries.orderedRemove(i);
            try m.report.add(.{ .code = .@"transform.mixScaleY.approximated", .step = step, .path = e.path, .message = "4.0 skips mixScaleY while the other mixes are 0, another rig took the scale mix" });
        }
        return true;
    }

    /// Runs the restore only where the IK mix is 0, through a slider that sets its mixes
    fn gateRestore(m: *Migration, doc: *ObjectMap, c: *ObjectMap, taken: *std.StringHashMapUnmanaged(void), out: *std.json.Array, part: *tree.Object) Error!void {
        const name = try tree.requireString(.{ .object = c.* }, "name");
        const part_name = try tree.requireString(part.value(), "name");
        var key: tree.Object = .init(m.arena);
        for (mixes) |field| {
            try key.put(field, part.map.get(field) orelse return error.Malformed);
            try part.put(field, .{ .float = 0 });
        }
        var keys = tree.array(m.arena);
        try keys.append(key.value());
        var transform: ObjectMap = .empty;
        try transform.put(m.arena, part_name, .{ .array = keys });
        var timelines: ObjectMap = .empty;
        try timelines.put(m.arena, "transform", .{ .object = transform });
        const animation = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}{s}-gate", .{ helper_prefix, part_name }));
        if (try edit.childOf(doc, "animations") == null) try doc.put(m.arena, "animations", .{ .object = .empty });
        const animations = (try edit.childOf(doc, "animations")).?;
        try animations.put(m.arena, animation, .{ .object = timelines });

        var slider: tree.Object = .init(m.arena);
        const slider_name = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-gate", .{part_name}));
        try slider.put("name", .{ .string = slider_name });
        try m.joinSkins(doc, c, &slider, "slider", slider_name);
        try slider.put("type", .{ .string = "slider" });
        try slider.put("animation", .{ .string = animation });
        try slider.float("mix", if (try edit.float(c, "mix", 1) == 0) 1 else 0, 1);
        try out.append(slider.value());
        for (animations.values()) |*owner| {
            const map = try edit.objectOf(owner);
            const list = try edit.childOf(map, "ik") orelse continue;
            const found = list.getPtr(name) orelse continue;
            try m.gateTimeline(map, slider_name, try resetGates(m.arena, try edit.keysOf(found)));
        }
    }

    /// Keys the slider mix of the gate from the other mixes
    fn gateTimeline(m: *Migration, owner: *ObjectMap, slider: []const u8, gates: []const gating.Gate) Error!void {
        var list = tree.array(m.arena);
        for (gates) |g| {
            for ([_]?f32{ g.time, g.later }, [_]bool{ g.on, !g.on }) |time, on| {
                const t = time orelse continue;
                var key: tree.Object = .init(m.arena);
                try key.float("time", t, 0);
                try key.put("value", .{ .float = if (on) 1 else 0 });
                try key.put("curve", .{ .string = "stepped" });
                try list.append(key.value());
            }
        }
        var one: ObjectMap = .empty;
        try one.put(m.arena, "mix", .{ .array = list });
        const entry = try owner.getOrPut(m.arena, "slider");
        if (!entry.found_existing) entry.value_ptr.* = .{ .object = .empty };
        try (try edit.objectOf(entry.value_ptr)).put(m.arena, slider, .{ .object = one });
    }

    /// Rebuilds old 4.0 relative scale 1 + s * k with helper bones
    fn relativeRig(m: *Migration, doc: *ObjectMap, c: *ObjectMap, taken: *std.StringHashMapUnmanaged(void)) Error![]const Value {
        const name = try tree.requireString(.{ .object = c.* }, "name");
        const source = try tree.requireString(.{ .object = c.* }, "source");
        const targets = try tree.getArray(.{ .object = c.* }, "bones");
        const bones = try edit.arrayOf(doc, "bones");
        if (bones.len == 0) return error.Malformed;
        const root = try tree.requireString(bones[0], "name");
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (bones) |b| try names.put(m.arena, try tree.requireString(b, "name"), {});
        var out: std.ArrayList(Value) = .empty;

        // helper position holds k = (t - 1 + offset) * mix
        const factor = try m.rigBone(doc, &names, root, name);
        var gather = try m.rigPart(doc, c, taken, "relativeScale", source, &.{factor}, true, &.{
            .{ .from = "scaleX", .to = "x", .from_offset = 1 },
            .{ .from = "scaleY", .to = "y", .from_offset = 1 },
        });
        for (scale_axes) |field| if (c.get(field)) |offset| try gather.put(field, offset);
        const mix_x = try edit.float(c, "mixScaleX", 1);
        try gather.put("mixX", .{ .float = mix_x });
        try gather.put("mixY", .{ .float = try edit.float(c, "mixScaleY", mix_x) });
        try c.put(m.arena, "mixScaleX", .{ .float = 0 });
        try c.put(m.arena, "mixScaleY", .{ .float = 0 });
        const gather_name = gather.map.get("name").?.string;
        try out.append(m.arena, gather.value());
        if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |*animation| {
            const timelines = try edit.childOf(try edit.objectOf(animation), "transform") orelse continue;
            const keys = timelines.getPtr(name) orelse continue;
            var moved = tree.array(m.arena);
            for (try edit.keysOf(keys)) |*key| {
                const k = try edit.objectOf(key);
                var copy: tree.Object = .init(m.arena);
                if (k.get("time")) |time| try copy.put("time", time);
                const x = try edit.float(k, "mixScaleX", 1);
                for (mixes, [_]f32{ 0, x, try edit.float(k, "mixScaleY", x), 0, 0, 0 }) |field, v| try copy.put(field, .{ .float = v });
                try k.put(m.arena, "mixScaleX", .{ .float = 0 });
                try k.put(m.arena, "mixScaleY", .{ .float = 0 });
                if (k.getPtr("curve")) |curve| if (curve.* == .array) {
                    const items = curve.array.items;
                    if (items.len < 20) return error.Malformed;
                    var handles = tree.array(m.arena);
                    for (items, 0..) |v, i| try handles.append(if (i >= 4 and i < 12) items[i + 8] else if (i % 2 == 1) .{ .float = 0 } else v);
                    for ([_]usize{ 13, 15, 17, 19 }) |i| items[i] = .{ .float = 0 };
                    try copy.put("curve", .{ .array = handles });
                } else try copy.put("curve", curve.*);
                try moved.append(copy.value());
            }
            try timelines.put(m.arena, gather_name, .{ .array = moved });
        };

        var products: std.ArrayList([]const u8) = .empty;
        for (targets) |b| {
            if (b != .string) return error.Malformed;
            try products.append(m.arena, try m.rigBone(doc, &names, root, try std.fmt.allocPrint(m.arena, "{s}-{s}", .{ name, b.string })));
        }
        const spread = try m.rigPart(doc, c, taken, "relativeScale-factor", factor, products.items, false, &.{
            .{ .from = "x", .to = "scaleX" },
            .{ .from = "y", .to = "scaleY" },
        });
        try out.append(m.arena, spread.value());
        for (targets, products.items) |b, product| {
            // the product helper becomes s * k
            const times = try m.rigPart(doc, c, taken, "relativeScale-bone", b.string, &.{product}, true, &.{
                .{ .from = "scaleX", .to = "scaleX" },
                .{ .from = "scaleY", .to = "scaleY" },
            });
            try out.append(m.arena, times.value());
            const result = try m.rigPart(doc, c, taken, "relativeScale-result", product, &.{b.string}, false, &.{
                .{ .from = "scaleX", .to = "scaleX", .to_offset = 1 },
                .{ .from = "scaleY", .to = "scaleY", .to_offset = 1 },
            });
            try out.append(m.arena, result.value());
        }
        return out.items;
    }

    /// Unkeyed helper bone under the root
    fn rigBone(m: *Migration, doc: *ObjectMap, names: *std.StringHashMapUnmanaged(void), parent: []const u8, base: []const u8) Error![]const u8 {
        const helper = try unique(m.arena, names, try std.fmt.allocPrint(m.arena, "{s}{s}-relativeScale", .{ helper_prefix, base }));
        var bone: tree.Object = .init(m.arena);
        try bone.put("name", .{ .string = helper });
        try bone.put("parent", .{ .string = parent });
        try (try edit.childValue(doc, "bones")).?.array.append(bone.value());
        return helper;
    }

    const Link = struct { from: []const u8, to: []const u8, from_offset: f32 = 0, to_offset: f32 = 0, to_scale: f32 = 1 };

    /// Local transform constraint of a rig with full mixes on its links
    fn rigPart(m: *Migration, doc: *ObjectMap, c: *ObjectMap, taken: *std.StringHashMapUnmanaged(void), suffix: []const u8, source: []const u8, targets: []const []const u8, additive: bool, links: []const Link) Error!tree.Object {
        var part: tree.Object = .init(m.arena);
        const name = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-{s}", .{ try tree.requireString(.{ .object = c.* }, "name"), suffix }));
        try part.put("name", .{ .string = name });
        try m.joinSkins(doc, c, &part, "transform", name);
        try part.put("type", .{ .string = "transform" });
        var list = tree.array(m.arena);
        for (targets) |t| try list.append(.{ .string = t });
        try part.put("bones", .{ .array = list });
        try part.put("source", .{ .string = source });
        try part.put("localSource", .{ .bool = true });
        try part.put("localTarget", .{ .bool = true });
        if (additive) try part.put("additive", .{ .bool = true });
        var map: ObjectMap = .empty;
        for (links) |l| {
            var entry: ObjectMap = .empty;
            if (l.to_offset != 0) try entry.put(m.arena, "offset", .{ .float = l.to_offset });
            if (l.to_scale != 1) try entry.put(m.arena, "scale", .{ .float = l.to_scale });
            var to: ObjectMap = .empty;
            try to.put(m.arena, l.to, .{ .object = entry });
            var from: ObjectMap = .empty;
            if (l.from_offset != 0) try from.put(m.arena, "offset", .{ .float = l.from_offset });
            try from.put(m.arena, "to", .{ .object = to });
            try map.put(m.arena, l.from, .{ .object = from });
        }
        try part.put("properties", .{ .object = map });
        for (mixes, properties) |field, p| {
            const used = for (links) |l| {
                if (std.mem.eql(u8, l.to, p)) break true;
            } else false;
            try part.put(field, .{ .float = if (used) 1 else 0 });
        }
        return part;
    }

    const Wrapped = struct { bit: i64, property: []const u8, offset: []const u8, mix: []const u8, channel: usize };

    /// Rebuilds the wrap to 180 that 4.1 and 4.2 apply to a partial local rotate or shear
    fn wrapRig(m: *Migration, doc: *ObjectMap, c: *ObjectMap, taken: *std.StringHashMapUnmanaged(void), mask: i64) Error![]const Value {
        const name = try tree.requireString(.{ .object = c.* }, "name");
        const source = try tree.requireString(.{ .object = c.* }, "source");
        const targets = try tree.getArray(.{ .object = c.* }, "bones");
        const list = try edit.childValue(doc, "bones") orelse return error.Malformed;
        if (list.array.items.len == 0) return error.Malformed;
        const root = try tree.requireString(list.array.items[0], "name");
        var bone_names: std.StringHashMapUnmanaged(void) = .empty;
        for (list.array.items) |b| try bone_names.put(m.arena, try tree.requireString(b, "name"), {});
        var out: std.ArrayList(Value) = .empty;
        const channels = [_]Wrapped{
            .{ .bit = 1, .property = "rotate", .offset = "rotation", .mix = "mixRotate", .channel = 0 },
            .{ .bit = 2, .property = "shearY", .offset = "shearY", .mix = "mixShearY", .channel = 5 },
        };
        for (channels) |ch| {
            if (mask & ch.bit == 0) continue;
            const offset = try edit.float(c, ch.offset, 0);
            const setup = try edit.float(c, ch.mix, 1);
            for (targets) |target| {
                if (target != .string) return error.Malformed;
                const diff = try unique(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "{s}{s}-{s}-{s}-diff", .{ helper_prefix, name, target.string, ch.property }));
                const wrap = try unique(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "{s}{s}-{s}-{s}-wrap", .{ helper_prefix, name, target.string, ch.property }));
                for ([_][]const u8{ diff, wrap }) |helper| {
                    var bone: tree.Object = .init(m.arena);
                    try bone.put("name", .{ .string = helper });
                    try bone.put("parent", .{ .string = root });
                    try bone.put("inherit", .{ .string = "onlyTranslation" });
                    try list.array.append(bone.value());
                }
                const suffix = try std.fmt.allocPrint(m.arena, "{s}-{s}", .{ target.string, ch.property });
                var first = try m.rigPart(doc, c, taken, try std.fmt.allocPrint(m.arena, "{s}-target", .{suffix}), source, &.{diff}, false, &.{
                    .{ .from = ch.property, .to = "rotate", .from_offset = -offset },
                });
                try out.append(m.arena, first.value());
                var second = try m.rigPart(doc, c, taken, try std.fmt.allocPrint(m.arena, "{s}-bone", .{suffix}), target.string, &.{diff}, true, &.{
                    .{ .from = ch.property, .to = "rotate", .to_scale = -1 },
                });
                try out.append(m.arena, second.value());

                var spin: tree.Object = .init(m.arena);
                const turn_name = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-{s}-wrap", .{ name, suffix }));
                try spin.put("name", .{ .string = turn_name });
                try m.joinSkins(doc, c, &spin, "transform", turn_name);
                try spin.put("type", .{ .string = "transform" });
                var bones = tree.array(m.arena);
                try bones.append(.{ .string = wrap });
                try spin.put("bones", .{ .array = bones });
                try spin.put("source", .{ .string = diff });
                try spin.put("additive", .{ .bool = true });
                var to: ObjectMap = .empty;
                try to.put(m.arena, "rotate", .{ .object = .empty });
                var from: ObjectMap = .empty;
                try from.put(m.arena, "to", .{ .object = to });
                var map: ObjectMap = .empty;
                try map.put(m.arena, "rotate", .{ .object = from });
                try spin.put("properties", .{ .object = map });
                for (mixes) |field| try spin.put(field, .{ .float = if (std.mem.eql(u8, field, "mixRotate")) setup else 0 });
                try out.append(m.arena, spin.value());
                if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |*animation| {
                    const timelines = try edit.childOf(try edit.objectOf(animation), "transform") orelse continue;
                    const keys = timelines.get(name) orelse continue;
                    try timelines.put(m.arena, turn_name, try m.moveMix(keys, ch.mix, ch.channel));
                };

                var last = try m.rigPart(doc, c, taken, try std.fmt.allocPrint(m.arena, "{s}-add", .{suffix}), wrap, &.{target.string}, true, &.{
                    .{ .from = "rotate", .to = ch.property },
                });
                try out.append(m.arena, last.value());
            }
            _ = (try edit.childOf(c, "properties") orelse return error.Malformed).orderedRemove(ch.property);
            _ = c.orderedRemove(ch.offset);
        }
        return out.items;
    }

    /// Keys with one mix channel moved to the rotate mix
    fn moveMix(m: *Migration, keys: Value, field: []const u8, channel: usize) Error!Value {
        if (keys != .array) return error.Malformed;
        var out = tree.array(m.arena);
        for (keys.array.items) |key| {
            var moved: tree.Object = .init(m.arena);
            if (tree.get(key, "time")) |time| try moved.put("time", time);
            try moved.float("mixRotate", try tree.getFloat(key, field, 1), 1);
            if (tree.get(key, "curve")) |curve| {
                if (curve != .array) {
                    try moved.put("curve", curve);
                } else {
                    if (curve.array.items.len < channel * 4 + 4) return error.Malformed;
                    var copy = try edit.clone(m.arena, curve);
                    @memcpy(copy.array.items[0..4], curve.array.items[channel * 4 ..][0..4]);
                    try moved.put("curve", copy);
                }
            }
            try out.append(moved.value());
        }
        return .{ .array = out };
    }

    /// Adds a rig part to the skins of its constraint
    fn joinSkins(m: *Migration, doc: *ObjectMap, c: *ObjectMap, part: *tree.Object, kind: []const u8, name: []const u8) Error!void {
        const original = try tree.requireString(.{ .object = c.* }, "name");
        try part.put("skin", c.get("skin") orelse return);
        for (try edit.arrayOf(doc, "skins")) |*skin| {
            const map = try edit.objectOf(skin);
            const list = try edit.childValue(map, "transform") orelse continue;
            if (list.* != .array) return error.Malformed;
            for (list.array.items) |entry| {
                if (entry != .string) return error.Malformed;
                if (!std.mem.eql(u8, entry.string, original)) continue;
                if (try edit.childValue(map, kind) == null) try map.put(m.arena, kind, .{ .array = tree.array(m.arena) });
                const parts = (try edit.childValue(map, kind)).?;
                if (parts.* != .array) return error.Malformed;
                try parts.array.append(.{ .string = name });
                break;
            }
        }
    }

    fn downConstraints(m: *Migration, doc: *ObjectMap) Error!void {
        const list = edit.take(doc, "constraints") orelse return;
        if (list == .null) return;
        if (list != .array) return error.Malformed;
        const unit = try unitScale(m.arena, doc);
        var earlier: std.StringHashMapUnmanaged(void) = .empty;
        var out: [kinds.len]std.json.Array = @splat(tree.array(m.arena));
        var order: i64 = 0;
        for (list.array.items) |*value| {
            const c = try edit.objectOf(value);
            const kind = try tree.requireString(.{ .object = c.* }, "type");
            _ = c.orderedRemove("type");
            if (std.mem.eql(u8, kind, "slider")) {
                try m.lose(.@"slider.dropped", try m.path("constraints", c), "sliders have no 4.2 equivalent", .{});
                continue;
            }
            const k = for (kinds, 0..) |name, k| {
                if (std.mem.eql(u8, name, kind)) break k;
            } else return error.Malformed;
            // 4.2 skips constraints whose order reaches the constraint count
            if (order > 0) try c.put(m.arena, "order", .{ .integer = order });
            order += 1;
            const bones = try bonesOf(m.arena, value.*, k);
            switch (k) {
                0 => if (edit.take(c, "scaleY")) |mode| {
                    if (mode != .string) return error.Malformed;
                    if (std.mem.eql(u8, mode.string, "uniform")) {
                        try c.put(m.arena, "uniform", .{ .bool = true });
                    } else if (!std.mem.eql(u8, mode.string, "none")) {
                        try m.lose(.@"ik.scaleY.approximated", try m.path("constraints", c), "IK scaleY {s} becomes none", .{mode.string});
                    }
                },
                1 => try m.downTransform(c, appliedUnit(bones, unit, earlier)),
                2 => {
                    try m.rename(c, "slot", "target");
                    const x = try edit.float(c, "mixX", 1);
                    if (c.get("mixY") == null and x != 1) try c.put(m.arena, "mixY", .{ .float = x });
                },
                else => {
                    try m.default(c, "inertia", 0.5);
                    try m.default(c, "damping", 0.85);
                    if (edit.take(c, "scaleY")) |mode| {
                        if (mode != .string) return error.Malformed;
                        if (!std.mem.eql(u8, mode.string, "none")) {
                            try m.lose(.@"physics.scaleY.dropped", try m.path("constraints", c), "physics scaleY {s} becomes none", .{mode.string});
                        }
                    }
                },
            }
            try out[k].append(.{ .object = c.* });
            for (bones) |b| try earlier.put(m.arena, b.string, {});
        }
        for (kinds, out) |kind, items| {
            if (items.items.len > 0) try doc.put(m.arena, kind, .{ .array = items });
        }
    }

    /// Unit means every applied scale stays 1
    fn downTransform(m: *Migration, c: *ObjectMap, unit: bool) Error!void {
        const where = try m.path("constraints", c);
        try m.rename(c, "source", "target");
        const local_source = try edit.takeBool(c, "localSource");
        const local_target = try edit.takeBool(c, "localTarget");
        if (local_target) try c.put(m.arena, "local", .{ .bool = true });
        if (local_source != local_target) {
            try m.lose(.@"transform.local.approximated", where, "local source and target differ", .{});
        }
        const additive = try edit.takeBool(c, "additive");
        if (additive) try c.put(m.arena, "relative", .{ .bool = true });
        if (try edit.takeBool(c, "clamp")) try m.lose(.@"transform.clamp.dropped", where, "clamp has no 4.2 equivalent", .{});

        var enabled: [mixes.len]bool = @splat(false);
        if (edit.take(c, "properties")) |value| {
            if (value != .object) return error.Malformed;
            var froms = value.object.iterator();
            while (froms.next()) |from| {
                const f = edit.indexOf(&properties, from.key_ptr.*) orelse return error.Malformed;
                const from_map = try edit.objectOf(from.value_ptr);
                const from_offset = try edit.float(from_map, "offset", 0);
                const to_map = try edit.childOf(from_map, "to") orelse continue;
                var tos = to_map.iterator();
                while (tos.next()) |to| {
                    const t = edit.indexOf(&properties, to.key_ptr.*) orelse return error.Malformed;
                    const to_entry = try edit.objectOf(to.value_ptr);
                    if (f == t and from_offset == 0 and try edit.float(to_entry, "offset", 0) == 0 and try edit.float(to_entry, "scale", 1) == 1) {
                        enabled[t] = true;
                    } else {
                        try m.lose(.@"transform.property.dropped", where, "{s} to {s} with offset or scale", .{ properties[f], properties[t] });
                    }
                }
            }
        }
        if (local_target and !additive and !unit and (enabled[3] or enabled[4])) {
            try m.lose(.@"transform.scale.approximated", where, "local absolute scale divides by the bone scale in 4.2", .{});
        }
        const x = try edit.float(c, "mixX", 1);
        const scale_x = try edit.float(c, "mixScaleX", 1);
        var values: Mixes = .{ try edit.float(c, "mixRotate", 1), x, try edit.float(c, "mixY", x), scale_x, try edit.float(c, "mixScaleY", scale_x), try edit.float(c, "mixShearY", 1) };
        try m.putMixes(c, &values, enabled);
        if (std.mem.indexOfScalar(bool, &enabled, false) != null) {
            try m.enabled.put(m.arena, try tree.requireString(.{ .object = c.* }, "name"), enabled);
        }
    }

    fn findDeformed(m: *Migration, doc: *ObjectMap) Error!void {
        const animations = try edit.childOf(doc, "animations") orelse return;
        for (animations.values()) |*animation| {
            const skins = try edit.childOf(try edit.objectOf(animation), "attachments") orelse continue;
            for (skins.keys(), skins.values()) |skin, *slots| {
                for ((try edit.objectOf(slots)).keys(), (try edit.objectOf(slots)).values()) |slot, *attachments| {
                    for ((try edit.objectOf(attachments)).keys(), (try edit.objectOf(attachments)).values()) |attachment, *timelines| {
                        if ((try edit.objectOf(timelines)).get("deform") == null) continue;
                        try m.deformed.put(m.arena, try std.mem.join(m.arena, "\x00", &.{ skin, slot, attachment }), {});
                    }
                }
            }
        }
    }

    /// 4.2 keeps the closed path segment between positions
    fn checkClosed(m: *Migration, doc: *ObjectMap) Error!void {
        var lengths: std.StringHashMapUnmanaged(f32) = .empty;
        for (try edit.arrayOf(doc, "bones")) |bone| {
            try lengths.put(m.arena, try tree.requireString(bone, "name"), try tree.getFloat(bone, "length", 0));
        }
        for (try edit.arrayOf(doc, "path")) |c| {
            const total = try closedLength(doc, try tree.requireString(c, "target")) orelse continue;
            const name = try tree.requireString(c, "name");
            var spacing: Range = .of(try tree.getFloat(c, "spacing", 0));
            try spacing.keys(try keyLists(m.arena, doc, &.{ "path", name, "spacing" }), "value", 0, 0);
            var longest: f32 = 0;
            for (try tree.getArray(c, "bones")) |bone| {
                if (bone != .string) return error.Malformed;
                longest = @max(longest, lengths.get(bone.string) orelse return error.Malformed);
            }
            const mode = try tree.getString(c, "spacingMode") orelse "length";
            const fixed = std.mem.eql(u8, mode, "fixed");
            const percent = std.mem.eql(u8, mode, "percent");
            const backward = (fixed or percent) and spacing.min < 0;
            const past = if (percent) spacing.max >= 1 else if (fixed) spacing.max >= total else if (std.mem.eql(u8, mode, "length")) spacing.max + longest >= total else false;
            if (backward or past) try m.lose(.@"path.closed.approximated", try m.path("path", &c.object), "closed constant speed path walked backward or past its length", .{});
        }
    }

    /// 4.2 leaves most color channels unclamped
    fn checkColors(m: *Migration, doc: *ObjectMap) Error!void {
        const animations = try edit.childOf(doc, "animations") orelse return;
        for (animations.keys(), animations.values()) |name, animation| {
            const slots = tree.get(animation, "slots") orelse continue;
            if (slots != .object) return error.Malformed;
            for (slots.object.keys(), slots.object.values()) |slot, timelines| {
                for (unclamped) |entry| {
                    const timeline, const channels = entry;
                    const keys = tree.get(timelines, timeline) orelse continue;
                    if (keys != .array) return error.Malformed;
                    if (!try overshoots(keys.array.items, channels)) continue;
                    const where = try std.fmt.allocPrint(m.arena, "animations.{s}.slots.{s}.{s}", .{ name, slot, timeline });
                    try m.lose(.@"color.clamp.approximated", where, "color curve leaves 0 to 1, 4.3 clamps it", .{});
                }
            }
        }
    }

    /// 4.2 two bone IK drops the parent shear
    fn checkIkShear(m: *Migration, doc: *ObjectMap) Error!void {
        for (try ordered(m.arena, doc)) |c| {
            if (c.kind != 0 or c.bones.len != 2) continue;
            var mix: Range = .of(try edit.float(c.map, "mix", 1));
            try mix.keys(try keyLists(m.arena, doc, &.{ "ik", try c.name() }), "mix", 1, 0);
            if (mix.min == 0 and mix.max == 0) continue;
            const parent = c.bones[0].string;
            if (!try sheared(m.arena, doc, parent)) continue;
            // a slider after the IK drops the parent shear as 4.2 does
            if (m.rewrite and mix.min > 0 and try plainIk(m.arena, doc, c)) {
                try c.map.put(m.arena, marks.shear_reset, .{ .bool = true });
                try m.lose(.@"ik.shear.rewritten", try m.pathOf(c), "two bone parent {s} shear set to 0 after the IK by a 4.3 slider", .{parent});
                continue;
            }
            try m.lose(.@"ik.shear.approximated", try m.pathOf(c), "two bone parent {s} is sheared, 4.2 drops its shear", .{parent});
        }
    }

    /// Normalizing bones derive their local pose differently
    fn checkDerive(m: *Migration, doc: *ObjectMap, reason: []const u8) Error!void {
        const constraints = try ordered(m.arena, doc);
        var parents: std.StringHashMapUnmanaged(?[]const u8) = .empty;
        for (try edit.arrayOf(doc, "bones")) |bone| try parents.put(m.arena, try tree.requireString(bone, "name"), try tree.getString(bone, "parent"));
        const animations = try edit.childOf(doc, "animations");
        var reported: std.StringHashMapUnmanaged(void) = .empty;
        var pending: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (constraints, 0..) |c, i| {
            if (c.kind == 0 or c.kind == 1 and c.local_target) continue;
            for (c.bones) |b| {
                if (reported.contains(b.string)) continue;
                const inherit = try singular.normalizing(try boneOf(doc, b.string), b.string, animations) orelse continue;
                for (constraints[i + 1 ..], i + 1..) |later, j| {
                    if (!try reads(later, b.string, parents)) continue;
                    if (try m.derivesAlike(doc, constraints[0..j], c, later, b.string, parents)) break;
                    if (try m.zeroable(doc, constraints, i, j, b.string)) {
                        try pending.put(m.arena, b.string, {});
                        break;
                    }
                    try m.lose(.@"bone.derive.approximated", try std.fmt.allocPrint(m.arena, "bones.{s}", .{b.string}), "{s} bone set by a world constraint is read later, {s}", .{ inherit, reason });
                    try reported.put(m.arena, b.string, {});
                    _ = pending.orderedRemove(b.string);
                    break;
                }
            }
        }
        for (pending.keys()) |name| {
            for (try edit.arrayOf(doc, "bones")) |*bone| {
                if (!std.mem.eql(u8, try tree.requireString(bone.*, "name"), name)) continue;
                const rotation = try tree.getFloat(bone.*, "rotation", 0);
                _ = (try edit.objectOf(bone)).orderedRemove("rotation");
                try m.lose(.@"bone.derive.rewritten", try std.fmt.allocPrint(m.arena, "bones.{s}", .{name}), "setup rotation {d} set to 0, 4.2 derives it as 0 and the IK poses the bone without it", .{rotation});
            }
        }
    }

    /// The IK that reads the derived rotation poses the bone without its setup rotation
    fn zeroable(m: *Migration, doc: *ObjectMap, constraints: []const Constraint, i: usize, j: usize, bone: []const u8) Error!bool {
        const c = constraints[i];
        const reader = constraints[j];
        if (!m.rewrite or reader.kind != 0 or reader.bones.len != 1 or !try m.calm(doc, c, false) or try sliding(doc)) return false;
        var mix: Range = .of(try edit.float(reader.map, "mix", 1));
        try mix.keys(try keyLists(m.arena, doc, &.{ "ik", try reader.name() }), "mix", 1, 0);
        if (mix.min <= 0) return false;
        const value: Value = .{ .object = reader.map.* };
        for ([_][]const u8{ "compress", "stretch", "skin" }) |flag| if (try tree.getBool(value, flag, false)) return false;
        for (constraints) |other| if (other.kind > 1) return false;
        for (constraints[0..j]) |other| {
            const target = try tree.getString(.{ .object = other.map.* }, "target");
            if (target != null and std.mem.eql(u8, target.?, bone)) return false;
            if (other.map != c.map and listed(other, bone) and !try m.calm(doc, other, true)) return false;
        }
        const node = try boneOf(doc, bone);
        const mode = try tree.getString(node, "inherit") orelse "normal";
        if (!std.mem.eql(u8, mode, "noScale") and !std.mem.eql(u8, mode, "noScaleOrReflection")) return false;
        for ([_][]const u8{ "inherit", "rotate" }) |key| if ((try keyLists(m.arena, doc, &.{ "bones", bone, key })).len > 0) return false;
        return m.plainBone(doc, bone, false);
    }

    /// 4.2 and 4.3 derive the same local pose
    fn derivesAlike(m: *Migration, doc: *ObjectMap, before: []const Constraint, c: Constraint, reader: Constraint, bone: []const u8, parents: std.StringHashMapUnmanaged(?[]const u8)) Error!bool {
        if (!try m.calm(doc, c, false) or try sliding(doc)) return false;
        if (std.mem.eql(u8, c.list, "constraints") and !listed(reader, bone) and !(reader.local_source and std.mem.eql(u8, reader.source orelse "", bone))) return false;
        for (before) |other| {
            if (other.map == c.map or !listed(other, bone)) continue;
            if (!try m.calm(doc, other, true)) return false;
        }
        const animations = try edit.childOf(doc, "animations");
        const frames = try inheritFrames(try boneOf(doc, bone), bone, animations) orelse return false;
        if (!try m.plainBone(doc, bone, frames.zero)) return false;
        if (!frames.axis) return true;
        var ancestor = parents.get(bone) orelse return error.Malformed;
        while (ancestor) |a| : (ancestor = parents.get(a) orelse return error.Malformed) {
            if (!try m.axisBone(doc, before, a)) return false;
        }
        return true;
    }

    /// A transform constraint that keeps rotation and shear and positive scales
    fn calm(m: *Migration, doc: *ObjectMap, c: Constraint, local: bool) Error!bool {
        if (c.kind != 1) return false;
        if (std.mem.eql(u8, c.list, "constraints")) return translating(c);
        if (!std.mem.eql(u8, c.list, "transform")) return false;
        const lists = try keyLists(m.arena, doc, &.{ "transform", try c.name() });
        for ([_][]const u8{ "mixRotate", "mixShearY" }, [_]usize{ 0, 5 }) |field, channel| {
            var mix: Range = .of(try edit.float(c.map, field, 1));
            try mix.keys(lists, field, 1, channel);
            if (mix.min != 0 or mix.max != 0) return false;
        }
        var scaled = false;
        const first = try edit.float(c.map, "mixScaleX", 1);
        for ([_][]const u8{ "mixScaleX", "mixScaleY" }, [_]usize{ 3, 4 }, [_]f32{ first, try edit.float(c.map, "mixScaleY", first) }) |field, channel, setup| {
            var mix: Range = .of(setup);
            try mix.keys(lists, field, 1, channel);
            if (mix.min == 0 and mix.max == 0) continue;
            if (local or mix.min < 0 or mix.max >= 1) return false;
            scaled = true;
        }
        if (!scaled) return true;
        return try edit.float(c.map, "scaleX", 0) == 0 and try edit.float(c.map, "scaleY", 0) == 0;
    }

    /// Local pose without shear, with positive scales and optionally no rotation
    fn plainBone(m: *Migration, doc: *ObjectMap, name: []const u8, zero: bool) Error!bool {
        const bone = try boneOf(doc, name);
        if (try tree.getFloat(bone, "shearX", 0) != 0 or try tree.getFloat(bone, "shearY", 0) != 0) return false;
        if (try tree.getFloat(bone, "scaleX", 1) <= 0 or try tree.getFloat(bone, "scaleY", 1) <= 0) return false;
        if (zero and try tree.getFloat(bone, "rotation", 0) != 0) return false;
        const Timeline = struct { key: []const u8, field: []const u8, channel: usize, zero: bool };
        for ([_]Timeline{
            .{ .key = "rotate", .field = "value", .channel = 0, .zero = zero },
            .{ .key = "shear", .field = "x", .channel = 0, .zero = true },
            .{ .key = "shear", .field = "y", .channel = 1, .zero = true },
            .{ .key = "shearx", .field = "value", .channel = 0, .zero = true },
            .{ .key = "sheary", .field = "value", .channel = 0, .zero = true },
            .{ .key = "scale", .field = "x", .channel = 0, .zero = false },
            .{ .key = "scale", .field = "y", .channel = 1, .zero = false },
            .{ .key = "scalex", .field = "value", .channel = 0, .zero = false },
            .{ .key = "scaley", .field = "value", .channel = 0, .zero = false },
        }) |t| {
            const scale = !t.zero and !std.mem.eql(u8, t.key, "rotate");
            var range: Range = .of(if (scale) 1 else 0);
            try range.keys(try keyLists(m.arena, doc, &.{ "bones", name, t.key }), t.field, if (scale) 1 else 0, t.channel);
            if (scale and range.min <= 0) return false;
            if (!scale and (range.min != 0 or range.max != 0)) return false;
        }
        return true;
    }

    /// A bone whose world x axis stays on the skeleton x axis
    fn axisBone(m: *Migration, doc: *ObjectMap, before: []const Constraint, name: []const u8) Error!bool {
        const bone = try boneOf(doc, name);
        if (!std.mem.eql(u8, try tree.getString(bone, "inherit") orelse "normal", "normal")) return false;
        if ((try keyLists(m.arena, doc, &.{ "bones", name, "inherit" })).len > 0) return false;
        if (try tree.getFloat(bone, "rotation", 0) != 0 or try tree.getFloat(bone, "shearX", 0) != 0) return false;
        if (try tree.getFloat(bone, "scaleX", 1) <= 0 or try tree.getFloat(bone, "scaleY", 1) <= 0) return false;
        for (before) |c| if (listed(c, name)) return false;
        const Timeline = struct { key: []const u8, field: []const u8, channel: usize, scale: bool };
        for ([_]Timeline{
            .{ .key = "rotate", .field = "value", .channel = 0, .scale = false },
            .{ .key = "shear", .field = "x", .channel = 0, .scale = false },
            .{ .key = "shearx", .field = "value", .channel = 0, .scale = false },
            .{ .key = "scale", .field = "x", .channel = 0, .scale = true },
            .{ .key = "scale", .field = "y", .channel = 1, .scale = true },
            .{ .key = "scalex", .field = "value", .channel = 0, .scale = true },
            .{ .key = "scaley", .field = "value", .channel = 0, .scale = true },
        }) |t| {
            var range: Range = .of(if (t.scale) 1 else 0);
            try range.keys(try keyLists(m.arena, doc, &.{ "bones", name, t.key }), t.field, if (t.scale) 1 else 0, t.channel);
            if (t.scale and range.min <= 0 or !t.scale and (range.min != 0 or range.max != 0)) return false;
        }
        return true;
    }

    /// 4.2 world shear skips negatives and offsets after wrapping
    fn checkShear(m: *Migration, doc: *ObjectMap, up_step: bool) Error!void {
        const constraints = try ordered(m.arena, doc);
        const bones = try edit.arrayOf(doc, "bones");
        if (bones.len == 0) return;
        const root = try tree.requireString(bones[0], "name");
        var steady: ?bool = null;
        for (constraints) |c| {
            if (c.kind != 1 or c.local_source or c.local_target or !c.shear) continue;
            const where = try m.pathOf(c);
            const lists = try keyLists(m.arena, doc, &.{ "transform", try c.name() });
            var mix: Range = .of(try edit.float(c.map, "mixShearY", 1));
            try mix.keys(lists, "mixShearY", 1, 5);
            const rewriting = up_step and m.rewrite;
            var gate = false;
            if (mix.min < 0) {
                if (rewriting and mix.max <= 0) {
                    try zeroShear(m.arena, c.map, lists);
                    try m.lose(.@"transform.shearMix.rewritten", where, "world shear mix that is never positive set to 0", .{});
                    continue;
                }
                // a 4.3 slider clamps the live mix at 0, the copy of an absolute one reads the source late
                gate = rewriting and (c.additive or !try sourceUnder(doc, c));
                if (!gate) try m.lose(.@"transform.shearMix.approximated", where, "negative world shear mix, skipped by 4.2 and applied by 4.3", .{});
            }
            if (mix.max <= 0) continue;
            const usable = rewriting and (mix.min >= 0 or gate);
            const offset = try edit.float(c.map, "shearY", 0);
            if (c.additive) {
                const source = c.source orelse return error.Malformed;
                var shift = offset;
                var exact = true;
                if (offset != 0 and try reflectable(m.arena, doc, source)) {
                    const flip = try reflection(m.arena, doc, source, constraints);
                    if (m.rewrite and flip != null) {
                        if (flip.?) {
                            shift = -offset;
                            try c.map.put(m.arena, "shearY", .{ .float = shift });
                            try m.lose(.@"transform.shearOffset.rewritten", where, "relative world shearY offset negated for a source that stays reflected", .{});
                        }
                    } else if (usable and @abs(offset) < 180) {
                        shift = 0;
                        _ = c.map.orderedRemove("shearY");
                        try m.signRig(doc, c.map, offset, constraints);
                        try m.lose(.@"transform.shearOffset.rewritten", where, "relative world shearY offset signed by the source reflection through helper bone rotations", .{});
                    } else {
                        exact = false;
                        try m.lose(.@"transform.shearOffset.approximated", where, "relative world shearY offset with a source that may reflect, 4.2 negates it then", .{});
                    }
                }
                if (!mix.partial) continue;
                if (usable and exact) {
                    try m.wrapShear(doc, c.map, shift, constraints);
                    try m.lose(.@"transform.shearWrap.rewritten", where, "relative world shear read through a helper bone rotation that wraps it", .{});
                    if (gate) try m.gateShear(c.map, where);
                    continue;
                }
                try m.lose(.@"transform.shearWrap.approximated", where, "relative world shear mix below 1, 4.2 wraps the source shear", .{});
                continue;
            }
            const reflect = if (offset != 0) try reflectable(m.arena, doc, c.source orelse return error.Malformed) else false;
            if (offset != 0 and (mix.partial or reflect)) {
                if (usable) {
                    const flip: ?bool = if (reflect) try reflection(m.arena, doc, c.source.?, constraints) else false;
                    if (steady == null) steady = try steadyRoot(m.arena, doc, root, constraints);
                    if (flip != null and steady.?) {
                        try m.splitShear(doc, c.map, root, if (flip.?) -offset else offset, constraints);
                        try m.lose(.@"transform.shearOffset.rewritten", where, "absolute world shearY offset moved to an additive shear constraint from the root", .{});
                    } else if (@abs(offset) < 180) {
                        _ = c.map.orderedRemove("shearY");
                        try m.signRig(doc, c.map, offset, constraints);
                        try m.lose(.@"transform.shearOffset.rewritten", where, "absolute world shearY offset moved to an additive shear constraint signed by the source reflection", .{});
                    } else try m.lose(.@"transform.shearOffset.approximated", where, "absolute world shearY offset of 180 or more with a partial mix or a reflected source", .{});
                } else try m.lose(.@"transform.shearOffset.approximated", where, "absolute world shearY offset with a partial mix or a reflected source, 4.2 adds it after the wrap", .{});
            }
            if (gate) try m.gateShear(c.map, where);
        }
    }

    fn gateShear(m: *Migration, c: *ObjectMap, where: []const u8) Error!void {
        try c.put(m.arena, marks.shear_floor, .{ .bool = true });
        try m.lose(.@"transform.shearMix.rewritten", where, "world shear mix keyed through 0 clamped at 0 by a 4.3 slider", .{});
    }

    /// Names a rig must not reuse
    fn takenNames(m: *Migration, doc: *ObjectMap, constraints: []const Constraint) Error!std.StringHashMapUnmanaged(void) {
        var taken: std.StringHashMapUnmanaged(void) = .empty;
        for (constraints) |other| try taken.put(m.arena, try other.name(), {});
        for ([_][]const ObjectMap{ m.helpers.values(), m.leads.values() }) |list| for (list) |h| try taken.put(m.arena, h.get("name").?.string, {});
        for (m.signs.values()) |sign| {
            for (sign.pre) |p| try taken.put(m.arena, p.get("name").?.string, {});
            try taken.put(m.arena, sign.post.get("name").?.string, {});
        }
        if (try edit.childOf(doc, "animations")) |animations| for (animations.keys()) |name| try taken.put(m.arena, name, {});
        return taken;
    }

    /// Helper bones turn to the source angle and then to the signed offset, an additive constraint reads it
    fn signRig(m: *Migration, doc: *ObjectMap, c: *ObjectMap, offset: f32, constraints: []const Constraint) Error!void {
        const original = try tree.requireString(.{ .object = c.* }, "name");
        const bones = try edit.arrayOf(doc, "bones");
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (bones) |b| try names.put(m.arena, try tree.requireString(b, "name"), {});
        const root = try tree.requireString(bones[0], "name");
        const base = try unique(m.arena, &names, try std.fmt.allocPrint(m.arena, "{s}{s}-shearSign", .{ helper_prefix, original }));
        const turned = try unique(m.arena, &names, try std.fmt.allocPrint(m.arena, "{s}-turned", .{base}));
        var first: tree.Object = .init(m.arena);
        try first.put("name", .{ .string = base });
        try first.put("parent", .{ .string = root });
        try first.put("inherit", .{ .string = "onlyTranslation" });
        var second: tree.Object = .init(m.arena);
        try second.put("name", .{ .string = turned });
        try second.put("parent", .{ .string = base });
        try (try edit.childValue(doc, "bones")).?.array.append(first.value());
        try (try edit.childValue(doc, "bones")).?.array.append(second.value());

        var taken = try m.takenNames(doc, constraints);
        const source = c.get("target") orelse return error.Malformed;
        var sign: Sign = undefined;
        const roles = [_]struct { []const u8, []const u8 }{ .{ "sign-base", base }, .{ "sign-turned", turned } };
        for (roles, 0..) |role, i| {
            const name = try unique(m.arena, &taken, try std.fmt.allocPrint(m.arena, "{s}-{s}", .{ original, role[0] }));
            var part: tree.Object = .init(m.arena);
            try part.put("name", .{ .string = name });
            try m.joinSkins(doc, c, &part, "transform", name);
            try part.put("type", .{ .string = "transform" });
            var list = tree.array(m.arena);
            try list.append(.{ .string = role[1] });
            try part.put("bones", .{ .array = list });
            try part.put("source", source);
            if (i == 1) try part.put("rotation", .{ .float = offset });
            try part.put("properties", try rotateLink(m.arena, "rotate", "rotate"));
            sign.pre[i] = part.map;
        }
        const name = try unique(m.arena, &taken, try std.fmt.allocPrint(m.arena, "{s}-sign", .{original}));
        var post: tree.Object = .init(m.arena);
        try post.put("name", .{ .string = name });
        try m.joinSkins(doc, c, &post, "transform", name);
        try post.put("type", .{ .string = "transform" });
        try post.put("bones", c.get("bones") orelse return error.Malformed);
        try post.put("source", .{ .string = turned });
        try post.put("localSource", .{ .bool = true });
        try post.put("additive", .{ .bool = true });
        try post.put("properties", try rotateLink(m.arena, "rotate", "shearY"));
        if (c.get("mixShearY")) |mix| try post.put("mixShearY", mix);
        sign.post = post.map;
        try m.signs.put(m.arena, original, sign);
    }

    /// Moves the offset into an additive root helper
    fn splitShear(m: *Migration, doc: *ObjectMap, c: *ObjectMap, root: []const u8, offset: f32, constraints: []const Constraint) Error!void {
        const original = try tree.requireString(.{ .object = c.* }, "name");
        var name = try std.fmt.allocPrint(m.arena, "{s}-shearY", .{original});
        var n: usize = 2;
        while (try named(constraints, name) or m.helpers.count() > 0 and helperNamed(m.helpers.values(), name)) : (n += 1) {
            name = try std.fmt.allocPrint(m.arena, "{s}-shearY{d}", .{ original, n });
        }
        _ = c.orderedRemove("shearY");
        var to: ObjectMap = .empty;
        try to.put(m.arena, "shearY", .{ .object = .empty });
        var from: ObjectMap = .empty;
        try from.put(m.arena, "to", .{ .object = to });
        var map: ObjectMap = .empty;
        try map.put(m.arena, "shearY", .{ .object = from });
        var helper: ObjectMap = .empty;
        try helper.put(m.arena, "name", .{ .string = name });
        if (c.get("skin")) |skin| try helper.put(m.arena, "skin", skin);
        try helper.put(m.arena, "bones", c.get("bones") orelse return error.Malformed);
        try helper.put(m.arena, "source", .{ .string = root });
        try helper.put(m.arena, "additive", .{ .bool = true });
        try helper.put(m.arena, "properties", .{ .object = map });
        try helper.put(m.arena, "shearY", .{ .float = offset });
        if (c.get("mixShearY")) |mix| try helper.put(m.arena, "mixShearY", mix);
        try helper.put(m.arena, "type", .{ .string = "transform" });
        try m.helpers.put(m.arena, original, helper);
        if (c.get("skin") == null) return;
        for (try edit.arrayOf(doc, "skins")) |*skin| {
            const list = try edit.childValue(try edit.objectOf(skin), "transform") orelse continue;
            if (list.* != .array) return error.Malformed;
            for (list.array.items) |entry| {
                if (entry != .string) return error.Malformed;
                if (!std.mem.eql(u8, entry.string, original)) continue;
                try list.array.append(.{ .string = name });
                break;
            }
        }
    }

    /// IK turns a helper parent aimed at the child, copies give the old pose
    fn stretchRig(m: *Migration, doc: *ObjectMap, c: *ObjectMap, taken: *std.StringHashMapUnmanaged(void)) Error![2]Value {
        const original = try tree.requireString(.{ .object = c.* }, "name");
        const ik_bones = try edit.arrayOf(c, "bones");
        if (ik_bones.len != 2 or ik_bones[0] != .string or ik_bones[1] != .string) return error.Malformed;
        const names = [2][]const u8{ ik_bones[0].string, ik_bones[1].string };
        const list = try edit.childValue(doc, "bones") orelse return error.Malformed;
        var bone_names: std.StringHashMapUnmanaged(void) = .empty;
        var found: [2]?ObjectMap = .{ null, null };
        for (list.array.items) |b| {
            const name = try tree.requireString(b, "name");
            try bone_names.put(m.arena, name, {});
            for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
                found[i] = b.object;
            };
        }
        const parent = found[0] orelse return error.Malformed;
        const child = found[1] orelse return error.Malformed;
        const p: Value = .{ .object = parent };
        const ch: Value = .{ .object = child };
        const cx = try tree.getFloat(ch, "x", 0);
        const cy = try tree.getFloat(ch, "y", 0);
        const aim: f32 = std.math.atan2(cy, cx) * std.math.deg_per_rad;
        const reflect: f32 = if ((try tree.getFloat(p, "scaleX", 1) < 0) != (try tree.getFloat(p, "scaleY", 1) < 0)) -1 else 1;
        const helpers = [2][]const u8{
            try unique(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "{s}{s}-stretch-parent", .{ helper_prefix, original })),
            try unique(m.arena, &bone_names, try std.fmt.allocPrint(m.arena, "{s}{s}-stretch-child", .{ helper_prefix, original })),
        };
        var h = (try edit.clone(m.arena, p)).object;
        try h.put(m.arena, "name", .{ .string = helpers[0] });
        try h.put(m.arena, "rotation", .{ .float = try tree.getFloat(p, "rotation", 0) + aim * reflect });
        var k = (try edit.clone(m.arena, ch)).object;
        try k.put(m.arena, "name", .{ .string = helpers[1] });
        try k.put(m.arena, "parent", .{ .string = helpers[0] });
        try k.put(m.arena, "x", .{ .float = std.math.hypot(cx, cy) });
        try k.put(m.arena, "y", .{ .float = 0 });
        try k.put(m.arena, "rotation", .{ .float = try tree.getFloat(ch, "rotation", 0) - aim });
        for ([_]*ObjectMap{ &h, &k }) |b| for ([_][]const u8{ "color", "icon", "visible", "skin" }) |key| {
            _ = b.orderedRemove(key);
        };
        try list.array.append(.{ .object = h });
        try list.array.append(.{ .object = k });
        if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |*animation| {
            const timelines = try edit.childOf(try edit.objectOf(animation), "bones") orelse continue;
            for (names, helpers) |n, helper| if (timelines.get(n)) |t| {
                try timelines.put(m.arena, helper, try edit.clone(m.arena, t));
            };
        };
        ik_bones[0] = .{ .string = helpers[0] };
        ik_bones[1] = .{ .string = helpers[1] };
        var out: [2]Value = undefined;
        for (0..2) |i| {
            var to: ObjectMap = .empty;
            var rotate: ObjectMap = .empty;
            try rotate.put(m.arena, "offset", .{ .float = if (i == 0) -aim * reflect else aim });
            try to.put(m.arena, "rotate", .{ .object = rotate });
            var map: ObjectMap = .empty;
            var from: ObjectMap = .empty;
            try from.put(m.arena, "to", .{ .object = to });
            try map.put(m.arena, "rotate", .{ .object = from });
            if (i == 0) {
                var scale_to: ObjectMap = .empty;
                try scale_to.put(m.arena, "scaleX", .{ .object = .empty });
                var scale: ObjectMap = .empty;
                try scale.put(m.arena, "to", .{ .object = scale_to });
                try map.put(m.arena, "scaleX", .{ .object = scale });
            }
            var bones = tree.array(m.arena);
            try bones.append(.{ .string = names[i] });
            var t: ObjectMap = .empty;
            try t.put(m.arena, "type", .{ .string = "transform" });
            try t.put(m.arena, "name", .{ .string = try unique(m.arena, taken, try std.fmt.allocPrint(m.arena, "{s}-stretch-{s}", .{ original, if (i == 0) "parent" else "child" })) });
            try t.put(m.arena, "bones", .{ .array = bones });
            try t.put(m.arena, "source", .{ .string = helpers[i] });
            try t.put(m.arena, "localSource", .{ .bool = true });
            try t.put(m.arena, "localTarget", .{ .bool = true });
            try t.put(m.arena, "properties", .{ .object = map });
            out[i] = .{ .object = t };
        }
        return out;
    }

    /// FromRotate keeps the helper angle in 0 to 360
    fn wrapShear(m: *Migration, doc: *ObjectMap, c: *ObjectMap, offset: f32, constraints: []const Constraint) Error!void {
        const original = try tree.requireString(.{ .object = c.* }, "name");
        const bones = try edit.arrayOf(doc, "bones");
        var taken: std.StringHashMapUnmanaged(void) = .empty;
        for (bones) |b| try taken.put(m.arena, try tree.requireString(b, "name"), {});
        const helper = try unique(m.arena, &taken, try std.fmt.allocPrint(m.arena, "{s}{s}-shearWrap", .{ helper_prefix, original }));
        var bone: tree.Object = .init(m.arena);
        try bone.put("name", .{ .string = helper });
        try bone.put("parent", .{ .string = try tree.requireString(bones[0], "name") });
        try bone.put("inherit", .{ .string = "onlyTranslation" });
        try (try edit.childValue(doc, "bones")).?.array.append(bone.value());

        taken = .empty;
        for (constraints) |other| try taken.put(m.arena, try other.name(), {});
        for ([_][]const ObjectMap{ m.helpers.values(), m.leads.values() }) |list| for (list) |h| try taken.put(m.arena, h.get("name").?.string, {});
        if (try edit.childOf(doc, "animations")) |animations| for (animations.keys()) |name| try taken.put(m.arena, name, {});
        const Part = struct { role: []const u8, from: []const u8, to: []const u8, from_offset: f32, to_offset: f32 };
        const parts = [2]Part{
            // the helper turns to the source shear plus 180
            .{ .role = "source", .from = "shearY", .to = "rotate", .from_offset = 0, .to_offset = 270 },
            .{ .role = "wrap", .from = "rotate", .to = "shearY", .from_offset = 180, .to_offset = offset - 90 },
        };
        for (parts) |p| {
            const lead = std.mem.eql(u8, p.role, "source");
            const name = try unique(m.arena, &taken, try std.fmt.allocPrint(m.arena, "{s}-shear-{s}", .{ original, p.role }));
            var to: ObjectMap = .empty;
            var entry: ObjectMap = .empty;
            if (p.to_offset != 0) try entry.put(m.arena, "offset", .{ .float = p.to_offset });
            try to.put(m.arena, p.to, .{ .object = entry });
            var from: ObjectMap = .empty;
            if (p.from_offset != 0) try from.put(m.arena, "offset", .{ .float = p.from_offset });
            try from.put(m.arena, "to", .{ .object = to });
            var map: ObjectMap = .empty;
            try map.put(m.arena, p.from, .{ .object = from });
            var t: ObjectMap = .empty;
            try t.put(m.arena, "name", .{ .string = name });
            if (c.get("skin")) |skin| try t.put(m.arena, "skin", skin);
            if (lead) {
                var list = tree.array(m.arena);
                try list.append(.{ .string = helper });
                try t.put(m.arena, "bones", .{ .array = list });
                try t.put(m.arena, "source", c.get("target") orelse return error.Malformed);
            } else {
                try t.put(m.arena, "bones", c.get("bones") orelse return error.Malformed);
                try t.put(m.arena, "source", .{ .string = helper });
                try t.put(m.arena, "additive", .{ .bool = true });
                if (c.get("mixShearY")) |mix| try t.put(m.arena, "mixShearY", mix);
            }
            try t.put(m.arena, "properties", .{ .object = map });
            try t.put(m.arena, "type", .{ .string = "transform" });
            try (if (lead) &m.leads else &m.helpers).put(m.arena, original, t);
            if (c.get("skin") == null) continue;
            for (try edit.arrayOf(doc, "skins")) |*skin| {
                const list = try edit.childValue(try edit.objectOf(skin), "transform") orelse continue;
                if (list.* != .array) return error.Malformed;
                for (list.array.items) |entry_name| {
                    if (entry_name != .string) return error.Malformed;
                    if (!std.mem.eql(u8, entry_name.string, original)) continue;
                    try list.array.append(.{ .string = name });
                    break;
                }
            }
        }
    }

    /// 4.3.01 leaves the volume factor unbounded
    fn checkVolume(m: *Migration, doc: *ObjectMap) Error!void {
        for (try ordered(m.arena, doc)) |c| {
            if (c.kind != 0) continue;
            const v: Value = .{ .object = c.map.* };
            if (!std.mem.eql(u8, try tree.getString(v, "scaleY") orelse "none", "volume")) continue;
            const compress = try tree.getBool(v, "compress", false);
            const stretch = try tree.getBool(v, "stretch", false);
            var mix: Range = .of(try tree.getFloat(v, "mix", 1));
            try mix.keys(try keyLists(m.arena, doc, &.{ "ik", try c.name() }), "mix", 1, 0);
            // only these reach a factor below 0.7
            if (!(compress and c.bones.len == 1) and !((compress or stretch) and mix.min < 0)) continue;
            try m.lose(.@"ik.volume.approximated", try m.pathOf(c), "IK scaleY volume with a factor below 0.7, unbounded before 4.3.02", .{});
        }
    }

    /// Old 4.3 ignores slider keys on linked slots
    fn checkSliderLinked(m: *Migration, doc: *ObjectMap) Error!void {
        var sources: std.StringHashMapUnmanaged(void) = .empty;
        for (try edit.arrayOf(doc, "skins")) |skin| {
            const attachments = tree.get(skin, "attachments") orelse continue;
            if (attachments != .object) return error.Malformed;
            for (attachments.object.keys(), attachments.object.values()) |slot, entries| {
                if (entries != .object) return error.Malformed;
                for (entries.object.values()) |a| {
                    const source = try tree.getString(a, "source") orelse continue;
                    const from = try tree.getString(a, "slot") orelse continue;
                    if (std.mem.eql(u8, from, slot) or !try tree.getBool(a, "timelines", true)) continue;
                    try sources.put(m.arena, try std.mem.join(m.arena, "\x00", &.{ from, source }), {});
                }
            }
        }
        if (sources.count() == 0) return;
        const animations = try edit.childOf(doc, "animations") orelse return;
        for (try edit.arrayOf(doc, "constraints")) |*c| {
            if (!std.mem.eql(u8, try tree.getString(c.*, "type") orelse "", "slider")) continue;
            const animation = animations.get(try tree.getString(c.*, "animation") orelse continue) orelse continue;
            if (!try keysSources(m.arena, animation, sources)) continue;
            try m.lose(.@"slider.linkedMesh.approximated", try m.path("constraints", try edit.objectOf(c)), "slider keys a mesh with linked meshes in other slots", .{});
        }
    }

    /// Old 4.3 JSON may mean other absent mixes
    fn checkJsonMix(m: *Migration, doc: *ObjectMap) Error!void {
        for (try ordered(m.arena, doc)) |c| {
            if (c.kind != 1) continue;
            const map = tree.get(.{ .object = c.map.* }, "properties") orelse continue;
            if (map != .object) return error.Malformed;
            var y = false;
            var scale_y = false;
            for (map.object.values()) |from| {
                const to = tree.get(from, "to") orelse continue;
                y = y or tree.get(to, "y") != null;
                scale_y = scale_y or tree.get(to, "scaleY") != null;
            }
            const ambiguous = found: for (try keyLists(m.arena, doc, &.{ "transform", try c.name() })) |list| {
                for (list) |key| {
                    if (y and tree.get(key, "mixY") == null and try tree.getFloat(key, "mixX", 1) != 1) break :found true;
                    if (scale_y and tree.get(key, "mixScaleY") == null and try tree.getFloat(key, "mixScaleX", 1) != 1) break :found true;
                }
            } else false;
            if (ambiguous) try m.lose(.@"transform.jsonMix.approximated", try m.pathOf(c), "transform keys without mixY or mixScaleY beside an X mix other than 1", .{});
        }
    }

    /// 4.3 before 4.3.18 drops world results under a later ancestor constraint
    fn checkReset(m: *Migration, doc: *ObjectMap, allowed: bool, restore: bool, which: []const u8) Error!void {
        var bones: resets.Bones = .empty;
        for (try edit.arrayOf(doc, "bones")) |b| {
            try bones.put(m.arena, try tree.requireString(b, "name"), .{ .parent = try tree.getString(b, "parent"), .required = try tree.getBool(b, "skin", false) });
        }
        var list: std.ArrayList(resets.Constraint) = .empty;
        var maps: std.ArrayList(*ObjectMap) = .empty;
        var world: std.ArrayList(bool) = .empty;
        var values: std.ArrayList(Value) = .empty;
        var touched: std.ArrayList([]const u8) = .empty;
        var pending: std.AutoArrayHashMapUnmanaged(usize, std.ArrayList([]const u8)) = .empty;
        for (try edit.arrayOf(doc, "constraints"), 0..) |*value, i| {
            const kind = try tree.requireString(value.*, "type");
            const name = try tree.requireString(value.*, "name");
            var constrained: std.ArrayList([]const u8) = .empty;
            var read: std.ArrayList([]const u8) = .empty;
            var always = false;
            var drop: resets.Drop = .none;
            var modifies_world = false;
            if (std.mem.eql(u8, kind, "slider")) {
                if (try tree.getString(value.*, "bone")) |b| {
                    try read.append(m.arena, b);
                    try touched.append(m.arena, b);
                }
                const animations = try edit.childOf(doc, "animations") orelse return error.Malformed;
                const animation = animations.get(try tree.requireString(value.*, "animation")) orelse return error.Malformed;
                if (tree.get(animation, "bones")) |keyed| {
                    if (keyed != .object) return error.Malformed;
                    try constrained.appendSlice(m.arena, keyed.object.keys());
                }
            } else for (try bonesOf(m.arena, value.*, edit.indexOf(&kinds, kind) orelse return error.Malformed)) |b| try constrained.append(m.arena, b.string);
            if (!std.mem.eql(u8, kind, "transform") and !std.mem.eql(u8, kind, "path") and !std.mem.eql(u8, kind, "physics")) try touched.appendSlice(m.arena, constrained.items);
            if (std.mem.eql(u8, kind, "ik")) {
                try read.append(m.arena, try tree.requireString(value.*, "target"));
            } else if (std.mem.eql(u8, kind, "transform")) {
                try read.append(m.arena, try tree.requireString(value.*, "source"));
                modifies_world = !try tree.getBool(value.*, "localTarget", false);
                if (modifies_world) drop = .any else try touched.appendSlice(m.arena, constrained.items);
                if (try tree.getBool(value.*, "localSource", false)) try touched.append(m.arena, read.items[0]);
                always = try m.alwaysActive(doc, value.*, name);
            } else if (std.mem.eql(u8, kind, "path")) {
                try read.appendSlice(m.arena, try pathReads(m.arena, doc, try tree.requireString(value.*, "slot")));
                modifies_world = true;
                drop = .suffix;
            } else if (std.mem.eql(u8, kind, "physics")) modifies_world = true;
            var skins: ?[]const []const u8 = null;
            if (try tree.getBool(value.*, "skin", false)) {
                var holding: std.ArrayList([]const u8) = .empty;
                for (try edit.arrayOf(doc, "skins")) |skin| for (try tree.getArray(skin, kind)) |n| {
                    if (n == .string and std.mem.eql(u8, n.string, name)) try holding.append(m.arena, try tree.requireString(skin, "name"));
                };
                skins = holding.items;
            }
            try list.append(m.arena, .{
                .order = @floatFromInt(i),
                .bones = constrained.items,
                .reads = read.items,
                .skins = skins,
                .bound = read.items.len > 0 and if (bones.get(read.items[0])) |b| b.required else false,
                .always = always,
                .certain = std.mem.eql(u8, kind, "transform"),
                .drop = drop,
            });
            try maps.append(m.arena, try edit.objectOf(value));
            try world.append(m.arena, modifies_world);
            try values.append(m.arena, value.*);
        }
        for (try resets.find(m.arena, &bones, list.items)) |reset| {
            if (!world.items[reset.index]) continue;
            if (!try m.resetVisible(doc, &bones, list.items, values.items, reset)) continue;
            const map = maps.items[reset.index];
            const where = try m.path("constraints", map);
            if (!allowed or !reset.exact) {
                if (allowed and restore and try m.markRestore(doc, &bones, list.items, touched.items, reset, &pending)) {
                    try m.lose(.@"constraint.order.rewritten", where, "bones a later ancestor constraint resets in {s} restored by local transform constraints", .{which});
                    continue;
                }
                try m.lose(.@"constraint.order.approximated", where, "a later ancestor constraint resets this result in {s}", .{which});
                continue;
            }
            const kept = try resets.kept(m.arena, list.items[reset.index].bones, reset.bones);
            var array = try std.json.Array.initCapacity(m.arena, kept.len);
            for (kept) |b| array.appendAssumeCapacity(.{ .string = b });
            try map.put(m.arena, "bones", .{ .array = array });
            try m.lose(.@"constraint.order.rewritten", where, "bones a later ancestor constraint resets in {s} removed", .{which});
        }
        if (pending.count() > 0) try m.addRestores(doc, maps.items, &pending);
    }

    /// Queues a restore after each later constraint when the reset bones keep their pose as local values
    fn markRestore(m: *Migration, doc: *ObjectMap, bones: *const resets.Bones, list: []const resets.Constraint, touched: []const []const u8, reset: resets.Reset, pending: *std.AutoArrayHashMapUnmanaged(usize, std.ArrayList([]const u8))) Error!bool {
        const Pair = struct { later: usize, bone: []const u8 };
        var hits: std.ArrayList(Pair) = .empty;
        for (reset.bones) |bone| {
            if (contains(touched, bone) or !try m.restorable(doc, bone)) return false;
            for (try resets.restorers(m.arena, bones, list, reset.index, bone) orelse return false) |later| try hits.append(m.arena, .{ .later = later, .bone = bone });
        }
        for (hits.items) |p| {
            const entry = try pending.getOrPut(m.arena, p.later);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            if (!contains(entry.value_ptr.items, p.bone)) try entry.value_ptr.append(m.arena, p.bone);
        }
        return true;
    }

    /// Setup and keys without shearX and with scales above 0
    fn restorable(m: *Migration, doc: *ObjectMap, bone: []const u8) Error!bool {
        const setup = try boneOf(doc, bone);
        var shear: Range = .of(try tree.getFloat(setup, "shearX", 0));
        try shear.keys(try keyLists(m.arena, doc, &.{ "bones", bone, "shear" }), "x", 0, 0);
        try shear.keys(try keyLists(m.arena, doc, &.{ "bones", bone, "shearx" }), "value", 0, 0);
        if (shear.min != 0 or shear.max != 0) return false;
        for ([_][]const u8{ "scaleX", "scaleY" }, 0..) |field, axis| {
            var scale: Range = .of(try tree.getFloat(setup, field, 1));
            try scale.keys(try keyLists(m.arena, doc, &.{ "bones", bone, "scale" }), if (axis == 0) "x" else "y", 1, axis);
            try scale.keys(try keyLists(m.arena, doc, &.{ "bones", bone, if (axis == 0) "scalex" else "scaley" }), "value", 1, 0);
            if (scale.min <= 0) return false;
        }
        return true;
    }

    /// A local transform constraint right after each later constraint copies the clone of the bone
    fn addRestores(m: *Migration, doc: *ObjectMap, maps: []const *ObjectMap, pending: *std.AutoArrayHashMapUnmanaged(usize, std.ArrayList([]const u8))) Error!void {
        var taken: std.StringHashMapUnmanaged(void) = .empty;
        for (maps) |c| try taken.put(m.arena, try tree.requireString(.{ .object = c.* }, "name"), {});
        if (try edit.childOf(doc, "animations")) |animations| for (animations.keys()) |name| try taken.put(m.arena, name, {});
        var restored: std.StringHashMapUnmanaged([]const u8) = .empty;
        var out = tree.array(m.arena);
        for (maps, 0..) |c, i| {
            try out.append(.{ .object = c.* });
            const list = pending.get(i) orelse continue;
            for (list.items) |bone| {
                var part = try m.rigPart(doc, c, &taken, try std.fmt.allocPrint(m.arena, "restore-{s}", .{bone}), try m.restoreBone(doc, bone, &restored), &.{bone}, false, &restore_links);
                try out.append(part.value());
            }
        }
        try doc.put(m.arena, "constraints", .{ .array = out });
    }

    /// Some pose runs both and the earlier one moves
    fn resetVisible(m: *Migration, doc: *ObjectMap, bones: *const resets.Bones, list: []const resets.Constraint, values: []const Value, reset: resets.Reset) Error!bool {
        var poses: std.ArrayList(?Value) = .empty;
        try poses.append(m.arena, null);
        if (try edit.childOf(doc, "animations")) |animations| for (animations.values()) |a| try poses.append(m.arena, a);
        const earlier = values[reset.index];
        for (poses.items) |animation| {
            if (!try activeIn(earlier, animation) or try holds(doc, earlier, values[0..reset.index], animation)) continue;
            for (reset.bones) |bone| for (list[reset.index + 1 ..], values[reset.index + 1 ..]) |later, v| {
                if (contains(later.bones, bone) or !ancestorIn(bones, bone, later.bones)) continue;
                if (try activeIn(v, animation)) return true;
            };
        }
        return false;
    }

    /// TransformConstraint.update skips only when every mix is 0
    fn alwaysActive(m: *Migration, doc: *ObjectMap, c: Value, name: []const u8) Error!bool {
        const enabled = try transformTargets(c);
        const lists = try keyLists(m.arena, doc, &.{ "transform", name });
        for (mixes, 0..) |field, i| {
            if (!enabled[i] or std.mem.eql(u8, field, "mixY")) continue;
            var mix: Range = .of(try tree.getFloat(c, field, if (std.mem.eql(u8, field, "mixScaleY")) try tree.getFloat(c, "mixScaleX", 1) else 1));
            try mix.keys(lists, field, 1, i);
            if (mix.min > 0 or mix.max < 0) return true;
        }
        return false;
    }

    fn pathOf(m: *Migration, c: Constraint) Error![]const u8 {
        return std.fmt.allocPrint(m.arena, "{s}.{s}", .{ c.list, try c.name() });
    }

    fn downSkins(m: *Migration, doc: *ObjectMap) Error!void {
        const skins = try edit.arrayOf(doc, "skins");
        for (skins) |*skin| {
            const map = try edit.objectOf(skin);
            _ = edit.take(map, "slider");
            const attachments = try edit.childOf(map, "attachments") orelse continue;
            var slots = attachments.iterator();
            while (slots.next()) |slot| {
                var entries = (try edit.objectOf(slot.value_ptr)).iterator();
                while (entries.next()) |entry| {
                    const a = try edit.objectOf(entry.value_ptr);
                    const where = try std.fmt.allocPrint(m.arena, "skins.{s}.{s}.{s}", .{ try tree.getString(skin.*, "name") orelse "", slot.key_ptr.*, entry.key_ptr.* });
                    if (try edit.takeBool(a, "inverse")) try m.lose(.@"clipping.inverse.dropped", where, "clipping inverse has no 4.2 equivalent", .{});
                    if (try edit.takeBool(a, "convex")) {
                        const id = try std.mem.join(m.arena, "\x00", &.{ try tree.getString(skin.*, "name") orelse "", slot.key_ptr.*, entry.key_ptr.* });
                        if (m.rewrite and !m.deformed.contains(id) and try convexHull(m.arena, a)) {
                            try m.lose(.@"clipping.convex.rewritten", where, "vertices replaced by their convex hull", .{});
                        } else try m.lose(.@"clipping.convex.dropped", where, "clipping convex has no 4.2 equivalent", .{});
                    }
                    try m.regionSize(a, 0);
                    try m.rename(a, "source", "parent");
                    const source_slot = edit.take(a, "slot") orelse continue;
                    if (source_slot != .string) return error.Malformed;
                    try copySource(m.arena, skins, a, source_slot.string);
                    try m.lose(.@"linkedmesh.slot.approximated", where, "source mesh in slot {s} copied, its timelines are not inherited", .{source_slot.string});
                }
            }
        }
    }

    /// Writes mixes in 4.2 form, zero where the 4.3 constraint has no such property
    fn putMixes(m: *Migration, c: *ObjectMap, values: *Mixes, enabled: [mixes.len]bool) Error!void {
        for (values, enabled) |*v, e| {
            if (!e) v.* = 0;
        }
        for (mixes) |key| _ = c.orderedRemove(key);
        const defaults: Mixes = .{ 1, 1, values[1], 1, values[3], 1 };
        for (mixes, values, defaults) |key, v, d| if (v != d) try c.put(m.arena, key, .{ .float = v });
    }

    fn rename(m: *Migration, map: *ObjectMap, from: []const u8, to: []const u8) Error!void {
        if (map.fetchOrderedRemove(from)) |kv| try map.put(m.arena, to, kv.value);
    }

    /// Loaders before 4.3 default region sizes to 32
    fn regionSize(m: *Migration, map: *ObjectMap, value: f32) Error!void {
        if (!std.mem.eql(u8, try tree.getString(.{ .object = map.* }, "type") orelse "region", "region")) return;
        try m.default(map, "width", value);
        try m.default(map, "height", value);
    }

    /// Writes the default of the other version where the key is missing
    fn default(m: *Migration, map: *ObjectMap, key: []const u8, value: f32) Error!void {
        if (map.get(key) == null) try map.put(m.arena, key, .{ .float = value });
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

fn old(version: ?Version, change: Version.Change) bool {
    return if (version) |v| Version.editor(v, change) == .old else false;
}

const Constraint = struct {
    kind: usize,
    list: []const u8,
    map: *ObjectMap,
    order: i32 = 0,
    bones: []const Value,
    source: ?[]const u8 = null,
    local_source: bool = false,
    local_target: bool = false,
    additive: bool = false,
    /// Maps shearY to shearY
    shear: bool = true,

    fn name(c: Constraint) Error![]const u8 {
        return tree.requireString(.{ .object = c.map.* }, "name");
    }
};

fn ordered(arena: std.mem.Allocator, doc: *ObjectMap) Error![]Constraint {
    var out: std.ArrayList(Constraint) = .empty;
    for (try edit.arrayOf(doc, "constraints")) |*value| {
        const kind = edit.indexOf(&kinds, try tree.requireString(value.*, "type")) orelse continue;
        var c: Constraint = .{ .kind = kind, .list = "constraints", .map = try edit.objectOf(value), .bones = try bonesOf(arena, value.*, kind) };
        if (kind == 1) {
            c.source = try tree.getString(value.*, "source");
            c.local_source = try tree.getBool(value.*, "localSource", false);
            c.local_target = try tree.getBool(value.*, "localTarget", false);
            c.additive = try tree.getBool(value.*, "additive", false);
            const from = tree.get(tree.get(value.*, "properties") orelse .null, "shearY") orelse .null;
            c.shear = tree.get(tree.get(from, "to") orelse .null, "shearY") != null;
        }
        try out.append(arena, c);
    }
    for (kinds, 0..) |list, kind| for (try edit.arrayOf(doc, list)) |*value| {
        var c: Constraint = .{ .kind = kind, .list = list, .map = try edit.objectOf(value), .order = try tree.getInt(value.*, "order", 0), .bones = try bonesOf(arena, value.*, kind) };
        if (kind == 1) {
            c.source = try tree.getString(value.*, "target");
            c.local_source = try tree.getBool(value.*, "local", false);
            c.local_target = c.local_source;
            c.additive = try tree.getBool(value.*, "relative", false);
        }
        try out.append(arena, c);
    };
    std.sort.block(Constraint, out.items, {}, struct {
        fn lessThan(_: void, a: Constraint, b: Constraint) bool {
            return a.order < b.order;
        }
    }.lessThan);
    return out.items;
}

/// Two bone IK both runtimes always solve, with the child off the parent origin
fn plainIk(arena: std.mem.Allocator, doc: *ObjectMap, c: Constraint) Error!bool {
    if (c.map.get(marks.stretch_offset) != null) return false;
    for (c.bones) |b| {
        const bone = try boneOf(doc, b.string);
        if (!std.mem.eql(u8, try tree.getString(bone, "inherit") orelse "normal", "normal")) return false;
        if ((try keyLists(arena, doc, &.{ "bones", b.string, "inherit" })).len > 0) return false;
    }
    const child = try boneOf(doc, c.bones[1].string);
    if (try tree.getFloat(child, "x", 0) == 0 and try tree.getFloat(child, "y", 0) == 0) return false;
    for ([_][]const u8{ "translate", "translatex", "translatey" }) |t| if ((try keyLists(arena, doc, &.{ "bones", c.bones[1].string, t })).len > 0) return false;
    return true;
}

/// The transform source is a constrained bone or below one
fn sourceUnder(doc: *ObjectMap, c: Constraint) Error!bool {
    var at: ?[]const u8 = c.source orelse return error.Malformed;
    while (at) |name| {
        for (c.bones) |b| if (std.mem.eql(u8, b.string, name)) return true;
        at = try tree.getString(try boneOf(doc, name), "parent");
    }
    return false;
}

/// Physics names a single bone
fn bonesOf(arena: std.mem.Allocator, c: Value, kind: usize) Error![]const Value {
    if (kind == 3) {
        const one = try arena.alloc(Value, 1);
        one[0] = .{ .string = try tree.getString(c, "bone") orelse return &.{} };
        return one;
    }
    const bones = try tree.getArray(c, "bones");
    for (bones) |b| if (b != .string) return error.Malformed;
    return bones;
}

fn named(constraints: []const Constraint, name: []const u8) Error!bool {
    for (constraints) |c| if (std.mem.eql(u8, try c.name(), name)) return true;
    return false;
}

fn helperNamed(helpers: []const ObjectMap, name: []const u8) bool {
    for (helpers) |h| if (std.mem.eql(u8, h.get("name").?.string, name)) return true;
    return false;
}

fn sliding(doc: *ObjectMap) Error!bool {
    for (try edit.arrayOf(doc, "constraints")) |c| if (std.mem.eql(u8, try tree.requireString(c, "type"), "slider")) return true;
    return false;
}

/// A 4.3 transform constraint that only maps x or y
fn translating(c: Constraint) bool {
    const mapped = c.map.get("properties") orelse return false;
    if (mapped != .object) return false;
    for (mapped.object.values()) |property| {
        const to = tree.get(property, "to") orelse return false;
        if (to != .object) return false;
        for (to.object.keys()) |key| if (!std.mem.eql(u8, key, "x") and !std.mem.eql(u8, key, "y")) return false;
    }
    return true;
}

fn listed(c: Constraint, bone: []const u8) bool {
    for (c.bones) |b| if (std.mem.eql(u8, b.string, bone)) return true;
    return false;
}

/// Which derivation conditions the inherit modes need
const Frames = struct { zero: bool, axis: bool };

fn inheritFrames(bone: Value, name: []const u8, animations: ?*ObjectMap) Error!?Frames {
    var frames: Frames = .{ .zero = false, .axis = false };
    const setup = try tree.getString(bone, "inherit") orelse "normal";
    if (!note(&frames, setup)) return null;
    for ((animations orelse return frames).values()) |animation| {
        const keys = tree.get(tree.get(tree.get(animation, "bones") orelse continue, name) orelse continue, "inherit") orelse continue;
        if (keys != .array) return error.Malformed;
        for (keys.array.items) |key| if (!note(&frames, try tree.getString(key, "inherit") orelse "normal")) return null;
    }
    return frames;
}

fn note(frames: *Frames, mode: []const u8) bool {
    if (std.mem.eql(u8, mode, "normal")) return true;
    if (std.mem.eql(u8, mode, "noRotationOrReflection")) frames.axis = true else if (std.mem.eql(u8, mode, "noScale") or std.mem.eql(u8, mode, "noScaleOrReflection")) frames.zero = true else return false;
    return true;
}

/// Also true for a later constraint on an ancestor
fn reads(later: Constraint, bone: []const u8, parents: std.StringHashMapUnmanaged(?[]const u8)) Error!bool {
    if (later.kind == 1 and later.local_source and later.source != null and std.mem.eql(u8, later.source.?, bone)) return true;
    const local = later.kind == 0 or later.kind == 1 and later.local_target;
    for (later.bones) |b| {
        if (local and std.mem.eql(u8, b.string, bone)) return true;
        var ancestor = parents.get(bone) orelse return error.Malformed;
        while (ancestor) |a| : (ancestor = parents.get(a) orelse return error.Malformed) {
            if (std.mem.eql(u8, a, b.string)) return true;
        }
    }
    return false;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn ancestorIn(bones: *const resets.Bones, bone: []const u8, ancestors: []const []const u8) bool {
    var current = bone;
    for (0..bones.count()) |_| {
        current = (bones.get(current) orelse return false).parent orelse return false;
        if (contains(ancestors, current)) return true;
    }
    return false;
}

/// Keys replace the setup mix where the animation has them
fn activeIn(c: Value, animation: ?Value) Error!bool {
    const kind = try tree.requireString(c, "type");
    const name = try tree.requireString(c, "name");
    const transform = std.mem.eql(u8, kind, "transform");
    const path = std.mem.eql(u8, kind, "path");
    const fields: []const []const u8 = if (transform) &mixes else if (path) &.{ "mixRotate", "mixX", "mixY" } else &.{"mix"};
    const value_key = std.mem.eql(u8, kind, "physics") or std.mem.eql(u8, kind, "slider");
    if (animation) |a| {
        const timelines = tree.get(a, kind) orelse .null;
        const lists: []const Value = &.{ tree.get(timelines, name) orelse .null, if (std.mem.eql(u8, kind, "physics")) tree.get(timelines, "") orelse .null else .null };
        var keyed = false;
        for (lists) |entry| {
            const keys = if (transform or std.mem.eql(u8, kind, "ik")) entry else tree.get(entry, "mix") orelse .null;
            if (keys == .null) continue;
            if (keys != .array) return error.Malformed;
            keyed = keyed or keys.array.items.len > 0;
            for (keys.array.items) |key| for (fields, 0..) |field, channel| {
                const v = if (value_key) try tree.getFloat(key, "value", 1) else if (std.mem.eql(u8, field, "mixY")) try tree.getFloat(key, "mixY", try tree.getFloat(key, "mixX", 1)) else try tree.getFloat(key, field, 1);
                if (v != 0) return true;
                const curve = tree.get(key, "curve") orelse continue;
                if (curve != .array) continue;
                if (curve.array.items.len < channel * 4 + 4) return error.Malformed;
                if (try tree.number(curve.array.items[channel * 4 + 1]) != 0 or try tree.number(curve.array.items[channel * 4 + 3]) != 0) return true;
            };
        }
        if (keyed) return false;
    }
    const enabled = if (transform) try transformTargets(c) else @as([mixes.len]bool, @splat(true));
    for (fields, 0..) |field, i| {
        if (!enabled[i]) continue;
        const default: f32 = if (std.mem.eql(u8, field, "mixY")) try tree.getFloat(c, "mixX", 1) else if (std.mem.eql(u8, field, "mixScaleY")) try tree.getFloat(c, "mixScaleX", 1) else 1;
        if (try tree.getFloat(c, field, default) != 0) return true;
    }
    return false;
}

/// Translation keeping bones at their sibling offset
fn holds(doc: *ObjectMap, c: Value, before: []const Value, animation: ?Value) Error!bool {
    if (!std.mem.eql(u8, try tree.requireString(c, "type"), "transform")) return false;
    if (try tree.getBool(c, "localSource", false) or try tree.getBool(c, "additive", false) or try tree.getBool(c, "clamp", false)) return false;
    const map = tree.get(c, "properties") orelse return false;
    if (map != .object) return error.Malformed;
    for (map.object.keys(), map.object.values()) |from, entry| {
        if (!std.mem.eql(u8, from, "x") and !std.mem.eql(u8, from, "y")) return false;
        if (try tree.getFloat(entry, "offset", 0) != 0) return false;
        const to = tree.get(entry, "to") orelse return false;
        if (to != .object or to.object.count() != 1) return false;
        const target = to.object.get(from) orelse return false;
        if (try tree.getFloat(target, "offset", 0) != 0 or try tree.getFloat(target, "scale", 1) != 1) return false;
    }
    const source_name = try tree.requireString(c, "source");
    const source = try boneOf(doc, source_name);
    const parent = try tree.getString(source, "parent");
    const ox = try tree.getFloat(c, "x", 0);
    const oy = try tree.getFloat(c, "y", 0);
    const r = std.math.degreesToRadians(try tree.getFloat(source, "rotation", 0));
    const sa = @cos(r + std.math.degreesToRadians(try tree.getFloat(source, "shearX", 0))) * try tree.getFloat(source, "scaleX", 1);
    const sc = @sin(r + std.math.degreesToRadians(try tree.getFloat(source, "shearX", 0))) * try tree.getFloat(source, "scaleX", 1);
    const sb = @cos(r + std.math.degreesToRadians(90 + try tree.getFloat(source, "shearY", 0))) * try tree.getFloat(source, "scaleY", 1);
    const sd = @sin(r + std.math.degreesToRadians(90 + try tree.getFloat(source, "shearY", 0))) * try tree.getFloat(source, "scaleY", 1);
    const tx = try tree.getFloat(source, "x", 0) + sa * ox + sb * oy;
    const ty = try tree.getFloat(source, "y", 0) + sc * ox + sd * oy;
    if (!try still(source, animation)) return false;
    for (try tree.getArray(c, "bones")) |b| {
        if (b != .string) return error.Malformed;
        const bone = try boneOf(doc, b.string);
        if (!eqlOptional(try tree.getString(bone, "parent"), parent) or !try still(bone, animation)) return false;
        if (@abs(try tree.getFloat(bone, "x", 0) - tx) > 1e-3 or @abs(try tree.getFloat(bone, "y", 0) - ty) > 1e-3) return false;
        for (before) |e| if (try touches(e, b.string)) return false;
    }
    for (before) |e| if (try touches(e, source_name)) return false;
    return true;
}

/// Normal inherit and no timeline in the animation
fn still(bone: Value, animation: ?Value) Error!bool {
    if (!std.mem.eql(u8, try tree.getString(bone, "inherit") orelse "normal", "normal")) return false;
    const a = animation orelse return true;
    return tree.get(tree.get(a, "bones") orelse .null, try tree.requireString(bone, "name")) == null;
}

fn eqlOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Sliders count as changing every bone
fn touches(c: Value, bone: []const u8) Error!bool {
    if (std.mem.eql(u8, try tree.requireString(c, "type"), "slider")) return true;
    if (tree.get(c, "bone")) |b| if (b == .string and std.mem.eql(u8, b.string, bone)) return true;
    for (try tree.getArray(c, "bones")) |b| if (b == .string and std.mem.eql(u8, b.string, bone)) return true;
    return false;
}

/// Target properties named in the properties map
fn transformTargets(c: Value) Error![mixes.len]bool {
    var out: [mixes.len]bool = @splat(false);
    const map = tree.get(c, "properties") orelse return out;
    if (map != .object) return error.Malformed;
    for (map.object.values()) |from| {
        const to = tree.get(from, "to") orelse continue;
        if (to != .object) return error.Malformed;
        for (to.object.keys()) |t| out[edit.indexOf(&properties, t) orelse return error.Malformed] = true;
    }
    return out;
}

/// Slot bone and weighted path bones
fn pathReads(arena: std.mem.Allocator, doc: *ObjectMap, slot: []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try edit.arrayOf(doc, "slots")) |s| {
        if (std.mem.eql(u8, try tree.requireString(s, "name"), slot)) try out.append(arena, try tree.requireString(s, "bone"));
    }
    if (out.items.len == 0) return error.Malformed;
    const all = try edit.arrayOf(doc, "bones");
    for (try edit.arrayOf(doc, "skins")) |skin| {
        const attachments = tree.get(tree.get(skin, "attachments") orelse continue, slot) orelse continue;
        if (attachments != .object) return error.Malformed;
        for (attachments.object.values()) |a| {
            if (!std.mem.eql(u8, try tree.getString(a, "type") orelse "region", "path")) continue;
            const vertices = try tree.getArray(a, "vertices");
            if (vertices.len == @as(usize, try tree.getNatural(a, "vertexCount", 0)) * 2) continue;
            var i: usize = 0;
            while (i < vertices.len) {
                const count = try tree.natural(vertices[i]);
                i += 1;
                for (0..count) |_| {
                    if (i >= vertices.len) return error.Malformed;
                    const at = try tree.natural(vertices[i]);
                    if (at >= all.len) return error.Malformed;
                    try out.append(arena, try tree.requireString(all[at], "name"));
                    i += 4;
                }
            }
        }
    }
    return out.items;
}

fn boneOf(doc: *ObjectMap, name: []const u8) Error!Value {
    for (try edit.arrayOf(doc, "bones")) |bone| {
        if (std.mem.eql(u8, try tree.requireString(bone, "name"), name)) return bone;
    }
    return error.Malformed;
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

const Rig = struct {
    doc: *ObjectMap,
    taken: *std.StringHashMapUnmanaged(void),
    out: *std.json.Array,
};

/// Mixes a slider clamps at 0 in their own constraint
const Floor = struct { mark: []const u8, mixes: []const []const u8, properties: []const []const u8, channel: usize, suffix: []const u8, signed: bool = false };
const floor_parts = [_]Floor{
    .{ .mark = marks.scale_floor, .mixes = &.{ "mixScaleX", "mixScaleY" }, .properties = &scale_axes, .channel = 3, .suffix = "scale" },
    .{ .mark = marks.shear_floor, .mixes = &.{"mixShearY"}, .properties = &.{"shearY"}, .channel = 5, .suffix = "shear" },
    .{ .mark = marks.mix_scale_y_gate, .mixes = &.{"mixScaleY"}, .properties = &.{"scaleY"}, .channel = 4, .suffix = "scaleYGate", .signed = true },
};
const scale_axes = [_][]const u8{ "scaleX", "scaleY" };
/// oracle/compare.zig skips animations under this prefix
pub const helper_prefix = "spine-converter/";
/// Relative error the runtime sampling may show
const reciprocal_tolerance = 1e-6;
const reciprocal_key_limit = 4096;
/// First mix magnitude that counts as nonzero
const gate_start: f32 = 1e-30;

fn unique(arena: std.mem.Allocator, taken: *std.StringHashMapUnmanaged(void), base: []const u8) Error![]const u8 {
    var name = base;
    var n: usize = 2;
    while (taken.contains(name)) : (n += 1) name = try std.fmt.allocPrint(arena, "{s}{d}", .{ base, n });
    try taken.put(arena, name, {});
    return name;
}

/// The two scale mixes agree at setup, in every key and in every handle
fn sameScaleMixes(arena: std.mem.Allocator, doc: *ObjectMap, c: *ObjectMap) Error!bool {
    const x = try edit.float(c, "mixScaleX", 1);
    if (x != try edit.float(c, "mixScaleY", x)) return false;
    for (try keyLists(arena, doc, &.{ "transform", try tree.requireString(.{ .object = c.* }, "name") })) |list| for (list) |key| {
        const key_x = try tree.getFloat(key, "mixScaleX", 1);
        if (key_x != try tree.getFloat(key, "mixScaleY", key_x)) return false;
        const curve = tree.get(key, "curve") orelse continue;
        if (curve != .array) continue;
        if (curve.array.items.len < 20) return error.Malformed;
        for (12..16) |i| if (try tree.number(curve.array.items[i]) != try tree.number(curve.array.items[i + 4])) return false;
    };
    return true;
}

/// Ranges of the six mixes over setup, keys and Bézier handles
fn mixRanges(arena: std.mem.Allocator, doc: *ObjectMap, c: *ObjectMap) Error![mixes.len]Range {
    const x = try edit.float(c, "mixScaleX", 1);
    const setup: Mixes = .{ try edit.float(c, "mixRotate", 1), try edit.float(c, "mixX", 1), 0, x, try edit.float(c, "mixScaleY", x), try edit.float(c, "mixShearY", 1) };
    var out: [mixes.len]Range = undefined;
    for (&out, setup) |*r, v| r.* = .of(v);
    out[2] = .of(try edit.float(c, "mixY", setup[1]));
    for (try keyLists(arena, doc, &.{ "transform", try tree.requireString(.{ .object = c.* }, "name") })) |list| for (list) |key| {
        const key_x = try tree.getFloat(key, "mixX", 1);
        const key_scale = try tree.getFloat(key, "mixScaleX", 1);
        const values: Mixes = .{ try tree.getFloat(key, "mixRotate", 1), key_x, try tree.getFloat(key, "mixY", key_x), key_scale, try tree.getFloat(key, "mixScaleY", key_scale), try tree.getFloat(key, "mixShearY", 1) };
        for (&out, values) |*r, v| r.add(v);
        const curve = tree.get(key, "curve") orelse continue;
        if (curve != .array) continue;
        if (curve.array.items.len < 20) return error.Malformed;
        for (&out, 0..) |*r, i| for ([_]usize{ 1, 3 }) |h| {
            if (i * 4 + h < curve.array.items.len) r.add(try tree.number(curve.array.items[i * 4 + h]));
        };
    };
    return out;
}

/// Scale extremes of one axis with Bézier handles
fn scaleSpan(arena: std.mem.Allocator, doc: *ObjectMap, bone: []const u8, axis: usize, setup: f32) Error![2]f32 {
    var r: Range = .of(1);
    try r.keys(try keyLists(arena, doc, &.{ "bones", bone, "scale" }), if (axis == 0) "x" else "y", 1, axis);
    try r.keys(try keyLists(arena, doc, &.{ "bones", bone, if (axis == 0) "scalex" else "scaley" }), "value", 1, 0);
    return .{ @min(setup * r.min, setup * r.max), @max(setup * r.min, setup * r.max) };
}

/// Reciprocal Bézier keys checked as the runtime samples
/// The keys read the negated scale when sign is -1
fn reciprocalKeys(arena: std.mem.Allocator, lo: f32, hi: f32, setup: f32, sign: f64) Error!?Value {
    const Fit = struct {
        s: f64,
        k: f64,
        keys: std.json.Array,
        failed: bool = false,

        fn at(f: *const @This(), t: f64) f64 {
            return f.k / (t * f.s);
        }

        fn close(f: *const @This(), x: f64, y: f64) bool {
            const want = f.at(x);
            return @abs(y - want) <= reciprocal_tolerance * @abs(want);
        }

        fn handles(f: *const @This(), a: f64, b: f64) [4]f64 {
            const h = (b - a) / 3;
            return .{ a + h, f.at(a) - f.k * h / (a * a * f.s), b - h, f.at(b) + f.k * h / (b * b * f.s) };
        }

        fn fits(f: *const @This(), a: f64, b: f64) bool {
            const c = f.handles(a, b);
            var x = a;
            var y = f.at(a);
            for (1..11) |k| {
                const u: f64 = @as(f64, @floatFromInt(k)) / 10;
                const r = 1 - u;
                const px = if (k == 10) b else r * r * r * a + 3 * r * r * u * c[0] + 3 * r * u * u * c[2] + u * u * u * b;
                const py = if (k == 10) f.at(b) else r * r * r * f.at(a) + 3 * r * r * u * c[1] + 3 * r * u * u * c[3] + u * u * u * f.at(b);
                if (!f.close(px, py) or !f.close((x + px) / 2, (y + py) / 2)) return false;
                x = px;
                y = py;
            }
            return true;
        }

        fn key(f: *@This(), arena_: std.mem.Allocator, t: f64, curve: ?[4]f64) Error!void {
            if (f.keys.items.len >= reciprocal_key_limit) return;
            var k: tree.Object = .init(arena_);
            try k.float("time", @floatCast(t), 0);
            try k.float("value", @floatCast(f.at(t)), 1);
            if (curve) |c| {
                var list = tree.array(arena_);
                for (c) |v| try list.append(.{ .float = v });
                try k.put("curve", .{ .array = list });
            }
            try f.keys.append(k.value());
        }

        fn split(f: *@This(), arena_: std.mem.Allocator, a: f64, b: f64, depth: usize) Error!void {
            if (f.fits(a, b)) return f.key(arena_, a, f.handles(a, b));
            if (depth == 0) {
                f.failed = true;
                return;
            }
            try f.split(arena_, a, (a + b) / 2, depth - 1);
            try f.split(arena_, (a + b) / 2, b, depth - 1);
        }
    };
    var fit: Fit = .{ .s = setup, .k = sign, .keys = tree.array(arena) };
    if (lo < hi) try fit.split(arena, lo, hi, 24);
    try fit.key(arena, hi, null);
    if (fit.failed or fit.keys.items.len >= reciprocal_key_limit) return null;
    return .{ .array = fit.keys };
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

/// Where the keys hold the IK mix at 0, on at an instant, off right after a leaving key
fn resetGates(arena: std.mem.Allocator, keys: []Value) Error![]const gating.Gate {
    const out = try arena.alloc(gating.Gate, keys.len);
    for (keys, out, 0..) |*key, *g, i| {
        const k = try edit.objectOf(key);
        const zero = try edit.float(k, "mix", 1) == 0;
        const time = try edit.float(k, "time", 0);
        var span = zero;
        var next_time = time;
        if (i + 1 < keys.len) {
            const next = try edit.objectOf(&keys[i + 1]);
            next_time = try edit.float(next, "time", 0);
            const curve = k.get("curve") orelse .null;
            const stepped = curve == .string and std.mem.eql(u8, curve.string, "stepped");
            var flat = true;
            if (curve == .array and curve.array.items.len >= 4) for ([_]usize{ 1, 3 }) |at| {
                flat = flat and try tree.number(curve.array.items[at]) == 0;
            };
            if (!stepped) span = zero and try edit.float(next, "mix", 1) == 0 and flat;
        }
        g.* = .{ .time = time, .on = zero, .later = if (zero and !span and next_time > time) std.math.nextAfter(f32, time, next_time) else null };
    }
    return out;
}

/// Setup scales of bones without scale keys
fn unitScale(arena: std.mem.Allocator, doc: *ObjectMap) Error!std.StringHashMapUnmanaged([2]f32) {
    var unit: std.StringHashMapUnmanaged([2]f32) = .empty;
    for (try edit.arrayOf(doc, "bones")) |bone| {
        try unit.put(arena, try tree.requireString(bone, "name"), .{ try tree.getFloat(bone, "scaleX", 1), try tree.getFloat(bone, "scaleY", 1) });
    }
    const animations = try edit.childOf(doc, "animations") orelse return unit;
    for (animations.values()) |animation| {
        const bones = tree.get(animation, "bones") orelse continue;
        if (bones != .object) return error.Malformed;
        for (bones.object.keys(), bones.object.values()) |name, timelines| {
            for ([_][]const u8{ "scale", "scalex", "scaley" }) |t| {
                if (tree.get(timelines, t) != null) _ = unit.remove(name);
            }
        }
    }
    return unit;
}

fn appliedUnit(bones: []const Value, unit: std.StringHashMapUnmanaged([2]f32), earlier: std.StringHashMapUnmanaged(void)) bool {
    for (bones) |b| {
        const s = unit.get(b.string) orelse return false;
        if (s[0] != 1 or s[1] != 1 or earlier.contains(b.string)) return false;
    }
    return true;
}

/// Bones whose applied scale changes
fn appliedLive(bones: []const Value, unit: std.StringHashMapUnmanaged([2]f32), earlier: std.StringHashMapUnmanaged(void)) bool {
    for (bones) |b| if (!unit.contains(b.string) or earlier.contains(b.string)) return true;
    return false;
}

/// Applied scales shared by the bones, a 0 where every bone has none
fn appliedSteady(bones: []const Value, unit: std.StringHashMapUnmanaged([2]f32), earlier: std.StringHashMapUnmanaged(void)) ?[2]f32 {
    var out: [2]f32 = .{ 0, 0 };
    for (bones) |b| {
        if (earlier.contains(b.string)) return null;
        const s = unit.get(b.string) orelse return null;
        for (&out, s) |*o, v| {
            if (v == 0) continue;
            if (o.* != 0 and o.* != v) return null;
            o.* = v;
        }
    }
    return out;
}

/// Scale keys multiply the setup scale
fn scaleRange(arena: std.mem.Allocator, doc: *ObjectMap, bone: Value, name: []const u8) Error!Range {
    var r: Range = .of(try tree.getFloat(bone, "scaleX", 1));
    r.add(try tree.getFloat(bone, "scaleY", 1));
    try r.keys(try keyLists(arena, doc, &.{ "bones", name, "scale" }), "x", 1, 0);
    try r.keys(try keyLists(arena, doc, &.{ "bones", name, "scale" }), "y", 1, 1);
    try r.keys(try keyLists(arena, doc, &.{ "bones", name, "scalex" }), "value", 1, 0);
    try r.keys(try keyLists(arena, doc, &.{ "bones", name, "scaley" }), "value", 1, 0);
    return r;
}

/// Bone or ancestor scale can reach 0
fn reflectable(arena: std.mem.Allocator, doc: *ObjectMap, bone: []const u8) Error!bool {
    var name: ?[]const u8 = bone;
    while (name) |n| {
        const b = try boneOf(doc, n);
        if ((try scaleRange(arena, doc, b, n)).min <= 0) return true;
        name = try tree.getString(b, "parent");
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

/// Constant reflection of a bone, null when it may change
fn reflection(arena: std.mem.Allocator, doc: *ObjectMap, bone: []const u8, constraints: []const Constraint) Error!?bool {
    var flip = false;
    var name: ?[]const u8 = bone;
    while (name) |n| {
        for (constraints) |c| for (c.bones) |b| if (std.mem.eql(u8, b.string, n)) return null;
        const b = try boneOf(doc, n);
        if (!std.mem.eql(u8, try tree.getString(b, "inherit") orelse "normal", "normal")) return null;
        if ((try keyLists(arena, doc, &.{ "bones", n, "inherit" })).len > 0 or try sheared(arena, doc, n)) return null;
        for ([_][]const u8{ "x", "y" }, 0..) |axis, i| {
            var r: Range = .of(try tree.getFloat(b, if (i == 0) "scaleX" else "scaleY", 1));
            try r.keys(try keyLists(arena, doc, &.{ "bones", n, "scale" }), axis, 1, i);
            try r.keys(try keyLists(arena, doc, &.{ "bones", n, if (i == 0) "scalex" else "scaley" }), "value", 1, 0);
            if (r.max < 0) flip = !flip else if (!(r.min > 0)) return null;
        }
        name = try tree.getString(b, "parent");
    }
    return flip;
}

/// Root keeps 4.3 world shear at 0
fn steadyRoot(arena: std.mem.Allocator, doc: *ObjectMap, root: []const u8, constraints: []const Constraint) Error!bool {
    for (constraints) |c| for (c.bones) |b| if (std.mem.eql(u8, b.string, root)) return false;
    const bone = try boneOf(doc, root);
    if ((try scaleRange(arena, doc, bone, root)).min <= 0 or try sheared(arena, doc, root)) return false;
    var rotation: Range = .of(0);
    try rotation.keys(try keyLists(arena, doc, &.{ "bones", root, "rotate" }), "value", 0, 0);
    const setup = try tree.getFloat(bone, "rotation", 0);
    return setup + rotation.min > -180 and setup + rotation.max <= 90;
}

/// Zeroes the Bezier controls too
fn zeroShear(arena: std.mem.Allocator, c: *ObjectMap, lists: []const []Value) Error!void {
    try c.put(arena, "mixShearY", .{ .float = 0 });
    for (lists) |list| for (list) |*key| {
        try (try edit.objectOf(key)).put(arena, "mixShearY", .{ .float = 0 });
        const curve = tree.get(key.*, "curve") orelse continue;
        if (curve != .array) continue;
        if (curve.array.items.len < 24) return error.Malformed;
        curve.array.items[21] = .{ .float = 0 };
        curve.array.items[23] = .{ .float = 0 };
    };
}

/// Shortest closed constant speed path in the slot
fn closedLength(doc: *ObjectMap, slot: []const u8) Error!?f32 {
    var shortest: ?f32 = null;
    for (try edit.arrayOf(doc, "skins")) |skin| {
        const entries = tree.get(tree.get(skin, "attachments") orelse continue, slot) orelse continue;
        if (entries != .object) return error.Malformed;
        for (entries.object.values()) |a| {
            if (!std.mem.eql(u8, try tree.getString(a, "type") orelse "region", "path")) continue;
            if (!try tree.getBool(a, "closed", false) or !try tree.getBool(a, "constantSpeed", true)) continue;
            const lengths = try tree.getArray(a, "lengths");
            const total = if (lengths.len > 0) try tree.number(lengths[lengths.len - 1]) else std.math.inf(f32);
            shortest = @min(shortest orelse total, total);
        }
    }
    return shortest;
}

/// Field holds a hex byte or the alpha
const Channel = struct { curve: usize, field: []const u8, byte: usize = 0 };

/// Channels 4.2 leaves unclamped, per timeline
const unclamped = [_]struct { []const u8, []const Channel }{
    .{ "rgb", &.{ .{ .curve = 0, .field = "color" }, .{ .curve = 1, .field = "color", .byte = 1 }, .{ .curve = 2, .field = "color", .byte = 2 } } },
    .{ "alpha", &.{.{ .curve = 0, .field = "value" }} },
    .{ "rgba2", &.{ .{ .curve = 4, .field = "dark" }, .{ .curve = 5, .field = "dark", .byte = 1 }, .{ .curve = 6, .field = "dark", .byte = 2 } } },
    .{ "rgb2", &.{
        .{ .curve = 0, .field = "light" }, .{ .curve = 1, .field = "light", .byte = 1 }, .{ .curve = 2, .field = "light", .byte = 2 },
        .{ .curve = 3, .field = "dark" },  .{ .curve = 4, .field = "dark", .byte = 1 },  .{ .curve = 5, .field = "dark", .byte = 2 },
    } },
};

/// Bezier samples leave 0 to 1
fn overshoots(keys: []const Value, channels: []const Channel) Error!bool {
    if (keys.len < 2) return false;
    for (keys[0 .. keys.len - 1], keys[1..]) |key, next| {
        const curve = tree.get(key, "curve") orelse continue;
        if (curve != .array) continue;
        for (channels) |ch| {
            if (curve.array.items.len < ch.curve * 4 + 4) return error.Malformed;
            const cy1 = try tree.number(curve.array.items[ch.curve * 4 + 1]);
            const cy2 = try tree.number(curve.array.items[ch.curve * 4 + 3]);
            if (cy1 >= 0 and cy1 <= 1 and cy2 >= 0 and cy2 <= 1) continue;
            const v1 = try channelValue(key, ch);
            const v2 = try channelValue(next, ch);
            for (1..10) |i| {
                const t = @as(f32, @floatFromInt(i)) / 10;
                const u = 1 - t;
                const y = u * u * u * v1 + 3 * u * u * t * cy1 + 3 * u * t * t * cy2 + t * t * t * v2;
                if (y < 0 or y > 1) return true;
            }
        }
    }
    return false;
}

fn channelValue(key: Value, ch: Channel) Error!f32 {
    if (std.mem.eql(u8, ch.field, "value")) return tree.getFloat(key, "value", 0);
    const text = try tree.requireString(key, ch.field);
    if (text.len < ch.byte * 2 + 2) return error.Malformed;
    return @as(f32, @floatFromInt(try tree.parseHex(text[ch.byte * 2 ..], 2))) / 255;
}

fn keysSources(arena: std.mem.Allocator, animation: Value, sources: std.StringHashMapUnmanaged(void)) Error!bool {
    const skins = tree.get(animation, "attachments") orelse return false;
    if (skins != .object) return error.Malformed;
    for (skins.object.values()) |slots| {
        if (slots != .object) return error.Malformed;
        for (slots.object.keys(), slots.object.values()) |slot, attachments| {
            if (attachments != .object) return error.Malformed;
            for (attachments.object.keys(), attachments.object.values()) |attachment, timelines| {
                if (tree.get(timelines, "deform") == null and tree.get(timelines, "sequence") == null) continue;
                if (sources.contains(try std.mem.join(arena, "\x00", &.{ slot, attachment }))) return true;
            }
        }
    }
    return false;
}

/// Replaces unweighted clipping vertices by the hull 4.3 clips with, false when weighted or degenerate
fn convexHull(arena: std.mem.Allocator, clip: *ObjectMap) Error!bool {
    const count = try tree.getInt(.{ .object = clip.* }, "vertexCount", 0);
    const vertices = try tree.getArray(.{ .object = clip.* }, "vertices");
    if (count < 3 or vertices.len != count * 2) return false;
    const polygon = try arena.alloc(f32, vertices.len);
    for (polygon, vertices) |*p, v| p.* = @floatCast(try tree.number(v));
    const hull = try makeConvex(arena, polygon);
    if (hull.len < 6) return false;
    var list: std.json.Array = try .initCapacity(arena, hull.len);
    for (hull) |h| list.appendAssumeCapacity(.{ .float = h });
    try clip.put(arena, "vertices", .{ .array = list });
    try clip.put(arena, "vertexCount", .{ .integer = @intCast(hull.len / 2) });
    return true;
}

/// SkeletonClipping::makeConvex of 4.3, monotone chain that drops collinear points
fn makeConvex(arena: std.mem.Allocator, polygon: []const f32) Error![]f32 {
    const n = polygon.len;
    const sorted = try arena.dupe(f32, polygon);
    var i: usize = 2;
    while (i < n) : (i += 2) {
        const x = sorted[i];
        const y = sorted[i + 1];
        var p = i;
        while (p >= 2 and (sorted[p - 2] > x or (sorted[p - 2] == x and sorted[p - 1] > y))) : (p -= 2) {
            sorted[p] = sorted[p - 2];
            sorted[p + 1] = sorted[p - 1];
        }
        sorted[p] = x;
        sorted[p + 1] = y;
    }
    const v = try arena.alloc(f32, n * 2 + 4);
    @memcpy(v[0..4], sorted[0..4]);
    var s: usize = 4;
    i = 4;
    while (i < n) : ({
        i += 2;
        s += 2;
    }) {
        while (turn(v, s, sorted[i], sorted[i + 1]) >= 0) {
            s -= 2;
            if (s == 2) break;
        }
        v[s] = sorted[i];
        v[s + 1] = sorted[i + 1];
    }
    v[s] = sorted[n - 4];
    v[s + 1] = sorted[n - 3];
    const t = s;
    s += 2;
    var j = n - 4;
    while (j >= 2) : ({
        j -= 2;
        s += 2;
    }) {
        while (turn(v, s, sorted[j - 2], sorted[j - 1]) >= 0) {
            s -= 2;
            if (s == t) break;
        }
        v[s] = sorted[j - 2];
        v[s + 1] = sorted[j - 1];
    }
    return v[0 .. s - 2];
}

fn turn(v: []const f32, s: usize, x: f32, y: f32) f32 {
    return (v[s - 2] - v[s - 4]) * (y - v[s - 3]) - (v[s - 1] - v[s - 3]) * (x - v[s - 4]);
}

/// Copies the geometry of a source mesh from another slot into a linked mesh
fn copySource(arena: std.mem.Allocator, skins: []Value, mesh: *ObjectMap, slot: []const u8) Error!void {
    const skin_name = if (edit.take(mesh, "skin")) |s| if (s == .string) s.string else return error.Malformed else "default";
    const parent = edit.take(mesh, "parent") orelse return error.Malformed;
    if (parent != .string) return error.Malformed;
    _ = edit.take(mesh, "timelines");
    const skin = for (skins) |s| {
        if (std.mem.eql(u8, try tree.getString(s, "name") orelse "", skin_name)) break s;
    } else return error.Malformed;
    const source = tree.get(tree.get(tree.get(skin, "attachments") orelse return error.Malformed, slot) orelse return error.Malformed, parent.string) orelse return error.Malformed;
    if (source != .object or source.object.get("uvs") == null) return error.Malformed;
    for (geometry) |key| if (source.object.get(key)) |v| try mesh.put(arena, key, v);
    try mesh.put(arena, "type", .{ .string = "mesh" });
}

test "constraints up and down" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Report = .{ .arena = a };
    const input =
        \\{"bones":[{"name":"t"},{"name":"b","parent":"t"}],"ik":[{"name":"i","order":1,"bones":["b"],"target":"t","uniform":true}],
        \\"transform":[{"name":"t","bones":["b"],"target":"t","local":true,"relative":true,"mixX":0.5}]}
    ;
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    try up(a, &root, &report, .{});
    const constraints = root.object.get("constraints").?.array.items;
    try std.testing.expectEqualStrings("transform", constraints[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("uniform", constraints[1].object.get("scaleY").?.string);
    try std.testing.expect(constraints[0].object.get("additive").?.bool);

    try down(a, &root, &report, .{});
    try std.testing.expectEqual(0, report.entries.items.len);
    const ik = root.object.get("ik").?.array.items[0].object;
    try std.testing.expectEqual(1, ik.get("order").?.integer);
    try std.testing.expect(ik.get("uniform").?.bool);
    const transform = root.object.get("transform").?.array.items[0].object;
    try std.testing.expectEqual(0.5, transform.get("mixX").?.float);
    try std.testing.expect(transform.get("mixY") == null);
    try std.testing.expect(transform.get("relative").?.bool);
}

test "length spacing below minus the bone length" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, usize }{
        .{ "\"spacing\":-50", 0 },
        .{ "\"spacing\":-150", 1 },
        .{ "\"spacing\":-150,\"spacingMode\":\"fixed\"", 0 },
        .{ "\"spacing\":-50},{\"name\":\"q\",\"order\":1,\"bones\":[\"z\"],\"target\":\"s\",\"spacing\":-150", 0 },
    };
    for (cases) |case| {
        const spacing, const losses = case;
        var report: Report = .{ .arena = a };
        const input = try std.fmt.allocPrint(a, "{{\"bones\":[{{\"name\":\"b\",\"length\":100}},{{\"name\":\"z\"}}],\"path\":[{{\"name\":\"p\",\"bones\":[\"b\"],\"target\":\"s\",{s}}}]}}", .{spacing});
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try up(a, &root, &report, .{});
        try std.testing.expectEqual(losses, report.entries.items.len);
    }
    var report: Report = .{ .arena = a };
    const keyed =
        \\{"bones":[{"name":"b","length":100}],"constraints":[{"type":"path","name":"p","bones":["b"],"slot":"s"}],
        \\"animations":{"a":{"path":{"p":{"spacing":[{"value":10,"curve":[0,10,0.5,-120]},{"time":1,"value":0}]}}}}}
    ;
    var root = try std.json.parseFromSliceLeaky(Value, a, keyed, .{});
    try down(a, &root, &report, .{});
    try std.testing.expectEqual(.@"path.length.approximated", report.entries.items[0].code);
}

test "length spacing of equal bones becomes fixed spacing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, Report.Code }{
        .{ "100},{\"name\":\"c\",\"length\":100", .@"path.length.rewritten" },
        .{ "100},{\"name\":\"c\",\"length\":60", .@"path.length.approximated" },
        .{ "100},{\"name\":\"c\"", .@"path.length.approximated" },
    };
    for (cases) |case| {
        const lengths, const code = case;
        var report: Report = .{ .arena = a };
        const input = try std.fmt.allocPrint(a,
            \\{{"bones":[{{"name":"b","length":{s}}}],"path":[{{"name":"p","bones":["b","c"],"target":"s","spacing":-150}}],
            \\"animations":{{"a":{{"path":{{"p":{{"spacing":[{{"value":10,"curve":[0,10,0.5,-120]}},{{"time":1}}]}}}}}}}}}}
        , .{lengths});
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try up(a, &root, &report, .{ .rewrite = true });
        try std.testing.expectEqual(code, report.entries.items[0].code);
        if (code != .@"path.length.rewritten") continue;
        const p = root.object.get("constraints").?.array.items[0];
        try std.testing.expectEqualStrings("fixed", p.object.get("spacingMode").?.string);
        try std.testing.expectEqual(-50, try tree.getFloat(p, "spacing", 0));
        const keys = root.object.get("animations").?.object.get("a").?.object.get("path").?.object.get("p").?.object.get("spacing").?.array.items;
        try std.testing.expectEqual(110, try tree.getFloat(keys[0], "value", 0));
        try std.testing.expectEqual(-20, try tree.number(keys[0].object.get("curve").?.array.items[3]));
        try std.testing.expectEqual(0.5, try tree.number(keys[0].object.get("curve").?.array.items[2]));
        try std.testing.expectEqual(100, try tree.getFloat(keys[1], "value", 0));
    }
}

test "convex clipping becomes its hull only on request" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"skins":[{"name":"default","attachments":{"s":{
        \\"c":{"type":"clipping","convex":true,"vertexCount":5,"vertices":[0,0,4,0,2,1,4,4,0,4]},
        \\"w":{"type":"clipping","convex":true,"vertexCount":3,"vertices":[1,0,0,0,1,1,1,0,1,1,0,1,1,0,0,1]},
        \\"d":{"type":"clipping","convex":true,"vertexCount":3,"vertices":[0,0,1,0,0,1]}}}}],
        \\"animations":{"a":{"attachments":{"default":{"s":{"d":{"deform":[{}]}}}}}}}
    ;
    for ([_]bool{ false, true }) |rewrite| {
        var report: Report = .{ .arena = a };
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try down(a, &root, &report, .{ .rewrite = rewrite });
        const s = root.object.get("skins").?.array.items[0].object.get("attachments").?.object.get("s").?.object;
        const c = s.get("c").?.object;
        try std.testing.expectEqual(@as(i64, if (rewrite) 4 else 5), c.get("vertexCount").?.integer);
        try std.testing.expect(c.get("convex") == null);
        try std.testing.expectEqual(3, report.entries.items.len);
        try std.testing.expectEqual(@as(Report.Code, if (rewrite) .@"clipping.convex.rewritten" else .@"clipping.convex.dropped"), report.entries.items[0].code);
        try std.testing.expectEqual(.@"clipping.convex.dropped", report.entries.items[1].code);
        try std.testing.expectEqual(.@"clipping.convex.dropped", report.entries.items[2].code);
    }
}

test makeConvex {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const hull = try makeConvex(arena.allocator(), &.{ 0, 0, 4, 0, 2, 1, 4, 4, 2, 4, 0, 4 });
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 4, 4, 4, 4, 0 }, hull);
}

fn testCodes(a: std.mem.Allocator, input: []const u8, step: enum { early, up, down }, flags: Flags) !struct { Value, []Report.Code } {
    var report: Report = .{ .arena = a };
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    switch (step) {
        .early => try early(a, &root, &report, .{ .major = 4, .minor = 3 }, flags),
        .up => try up(a, &root, &report, flags),
        .down => try down(a, &root, &report, flags),
    }
    const out = try a.alloc(Report.Code, report.entries.items.len);
    for (out, report.entries.items) |*c, e| c.* = e.code;
    return .{ root, out };
}

test "relative world shear offset of a reflected source" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root"},{"name":"p","parent":"root","scaleY":-2},{"name":"s","parent":"p"},{"name":"b","parent":"root"}],
        \\"transform":[{"name":"t","bones":["b"],"target":"s","relative":true,"shearY":30}]ANIM}
    ;
    const root, const negated = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "ANIM", ""), .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.shearOffset.rewritten"}, negated);
    try std.testing.expectEqual(-30, try tree.getFloat(root.object.get("constraints").?.array.items[0], "shearY", 0));
    _, const kept = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "ANIM", ""), .up, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.shearOffset.approximated"}, kept);
    const keyed = ",\"animations\":{\"a\":{\"bones\":{\"p\":{\"scale\":[{\"y\":-1},{\"time\":1,\"y\":1}]}}}}";
    _, const flipping = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "ANIM", keyed), .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.shearOffset.rewritten"}, flipping);
}

test "world shear mix and offset" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root"},{"name":"s","parent":"root"},{"name":"b","parent":"root"}],
        \\"transform":[{"name":"neg","bones":["b"],"target":"s","mixShearY":-0.5},
        \\{"name":"off","order":1,"bones":["b"],"target":"s","shearY":200,"mixShearY":0.5},
        \\{"name":"rel","order":2,"bones":["b"],"target":"s","relative":true,"mixShearY":0.5},
        \\{"name":"one","order":3,"bones":["b"],"target":"s","shearY":30}],
        \\"animations":{"a":{"transform":{"neg":[{"mixShearY":-1,"curve":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.2,-0.5,0.8,-1]},{"time":1,"mixShearY":0}]}}}}
    ;
    _, const standard = try testCodes(a, input, .up, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{ .@"transform.shearMix.approximated", .@"transform.shearOffset.approximated", .@"transform.shearWrap.approximated" }, standard);

    const root, const rewritten = try testCodes(a, input, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{ .@"transform.shearMix.rewritten", .@"transform.shearOffset.rewritten", .@"transform.shearWrap.rewritten" }, rewritten);
    const constraints = root.object.get("constraints").?.array.items;
    try std.testing.expectEqual(7, constraints.len);
    try std.testing.expectEqual(0, try tree.getFloat(constraints[0], "mixShearY", 1));
    const key = root.object.get("animations").?.object.get("a").?.object.get("transform").?.object.get("neg").?.array.items[0];
    try std.testing.expectEqual(0, try tree.getFloat(key, "mixShearY", 1));
    try std.testing.expectEqual(0, try tree.number(key.object.get("curve").?.array.items[21]));
    try std.testing.expectEqual(0, try tree.getFloat(constraints[1], "shearY", 0));
    const helper = constraints[2];
    try std.testing.expectEqualStrings("off-shearY", try tree.requireString(helper, "name"));
    try std.testing.expectEqualStrings("root", try tree.requireString(helper, "source"));
    try std.testing.expect(try tree.getBool(helper, "additive", false));
    try std.testing.expectEqual(200, try tree.getFloat(helper, "shearY", 0));
    try std.testing.expectEqual(0.5, try tree.getFloat(helper, "mixShearY", 1));
    const wrap = constraints[5];
    try std.testing.expectEqualStrings("rel-shear-wrap", try tree.requireString(wrap, "name"));
    try std.testing.expectEqual(0.5, try tree.getFloat(wrap, "mixShearY", 1));
    try std.testing.expectEqualStrings("rel-shear-source", try tree.requireString(constraints[3], "name"));
    try std.testing.expect(constraints[4].object.get("properties").?.object.get("shearY") == null);
    const bones = root.object.get("bones").?.array.items;
    try std.testing.expectEqualStrings(helper_prefix ++ "rel-shearWrap", try tree.requireString(bones[bones.len - 1], "name"));

    const reflected = try std.mem.replaceOwned(u8, a, input, "{\"name\":\"s\",\"parent\":\"root\"}", "{\"name\":\"s\",\"parent\":\"root\",\"scaleX\":-1}");
    _, const kept = try testCodes(a, reflected, .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{ .@"transform.shearMix.rewritten", .@"transform.shearOffset.rewritten", .@"transform.shearWrap.rewritten", .@"transform.shearOffset.rewritten" }, kept);

    const down_input =
        \\{"bones":[{"name":"root"},{"name":"s","parent":"root"},{"name":"b","parent":"root"}],"constraints":[
        \\{"type":"transform","name":"neg","bones":["b"],"source":"s","properties":{"shearY":{"to":{"shearY":{}}}},"mixShearY":-0.5},
        \\{"type":"transform","name":"off","bones":["b"],"source":"s","properties":{"shearY":{"to":{"shearY":{}}}},"shearY":20,"mixShearY":0.5},
        \\{"type":"transform","name":"none","bones":["b"],"source":"s","properties":{"rotate":{"to":{"rotate":{}}}},"shearY":20,"mixShearY":-1}]}
    ;
    _, const lowered = try testCodes(a, down_input, .down, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{ .@"transform.shearMix.approximated", .@"transform.shearOffset.approximated" }, lowered);
}

test "local absolute scale of bones keeping scale 1" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, usize };
    for ([_]Case{
        .{ "{\"name\":\"b\",\"parent\":\"root\"}],", 0 },
        .{ "{\"name\":\"b\",\"parent\":\"root\",\"scaleY\":2}],", 1 },
        .{ "{\"name\":\"b\",\"parent\":\"root\"}],\"animations\":{\"a\":{\"bones\":{\"b\":{\"scale\":[{}]}}}},", 1 },
        .{ "{\"name\":\"b\",\"parent\":\"root\"}],\"ik\":[{\"name\":\"i\",\"bones\":[\"b\"],\"target\":\"root\"}],", 0 },
        .{ "{\"name\":\"b\",\"parent\":\"root\"}],\"ik\":[{\"name\":\"i\",\"bones\":[\"b\"],\"target\":\"root\",\"stretch\":true}],", 1 },
    }) |case| {
        const bone, const losses = case;
        const input = try std.fmt.allocPrint(a, "{{\"bones\":[{{\"name\":\"root\"}},{s}\"transform\":[{{\"name\":\"t\",\"order\":1,\"bones\":[\"b\"],\"target\":\"root\",\"local\":true}}]}}", .{bone});
        _, const codes = try testCodes(a, input, .up, .{});
        try std.testing.expectEqual(losses, std.mem.count(Report.Code, codes, &.{.@"transform.scale.approximated"}));
    }
}

test "local absolute scale of bones keeping another scale" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, []const u8, bool };
    for ([_]Case{
        .{ "\"scaleX\":2,\"scaleY\":0.5", "", true },
        .{ "\"scaleX\":2", ",\"animations\":{\"a\":{\"transform\":{\"t\":[{}]}}}", false },
        .{ "\"scaleX\":2", ",\"animations\":{\"a\":{\"bones\":{\"b\":{\"scalex\":[{\"value\":0}]}}}}", false },
    }) |case| {
        const scale, const animations, const rewritten = case;
        const input = try std.fmt.allocPrint(a, "{{\"bones\":[{{\"name\":\"root\"}},{{\"name\":\"b\",\"parent\":\"root\",{s}}}],\"transform\":[{{\"name\":\"t\",\"bones\":[\"b\"],\"target\":\"root\",\"local\":true,\"mixScaleX\":0.4,\"mixScaleY\":0}}]{s}}}", .{ scale, animations });
        const root, const codes = try testCodes(a, input, .up, .{ .rewrite = true });
        try std.testing.expectEqualSlices(Report.Code, &.{if (rewritten) .@"transform.scale.rewritten" else .@"transform.scale.approximated"}, codes);
        const c = tree.get(root, "constraints").?.array.items[0];
        const to = tree.get(tree.get(tree.get(tree.get(c, "properties").?, "scaleX").?, "to").?, "scaleX").?;
        try std.testing.expectEqual(if (rewritten) @as(f32, 0.2) else 1, try tree.getFloat(to, "scale", 1));
        try std.testing.expectEqual(if (rewritten) @as(f32, 0.6) else 0, try tree.getFloat(to, "offset", 0));
        try std.testing.expectEqual(if (rewritten) @as(f32, 1) else 0.4, try tree.getFloat(c, "mixScaleX", 1));
        try std.testing.expectEqual(0, try tree.getFloat(c, "mixScaleY", 1));
    }
    const zero = try testCodes(a, "{\"bones\":[{\"name\":\"root\"},{\"name\":\"b\",\"parent\":\"root\",\"scaleX\":0}],\"transform\":[{\"name\":\"t\",\"bones\":[\"b\"],\"target\":\"root\",\"local\":true,\"mixScaleX\":0.4,\"mixScaleY\":0}]}", .up, .{ .rewrite = true });
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.scale.rewritten"}, zero[1]);
    try std.testing.expectEqual(0, try tree.getFloat(tree.get(zero[0], "constraints").?.array.items[0], "mixScaleX", 1));
    _, const plain = try testCodes(a, "{\"bones\":[{\"name\":\"root\"},{\"name\":\"b\",\"parent\":\"root\",\"scaleX\":2}],\"transform\":[{\"name\":\"t\",\"bones\":[\"b\"],\"target\":\"root\",\"local\":true}]}", .up, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.scale.approximated"}, plain);
}

test "local absolute scale of keyed bones becomes a slider rig" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const curve = "\"curve\":[0.25,0,0.75,0,0.25,0,0.75,0,0.25,0,0.75,0,0.25,0.3,0.75,0.7,0.25,0,0.75,0,0.25,0,0.75,0]";
    const keyed = ",\"transform\":{\"t\":[{\"mixScaleX\":0.2,\"mixScaleY\":0," ++ curve ++ "},{\"time\":1,\"mixScaleX\":0.8,\"mixScaleY\":0}]}";
    const crossing = ",\"transform\":{\"t\":[{\"mixScaleX\":0.2,\"mixScaleY\":0},{\"time\":1,\"mixScaleX\":-0.1,\"mixScaleY\":0}]}";
    const Case = struct { []const u8, []const u8, []const u8, []const u8, bool };
    for ([_]Case{
        .{ "", "o", "0.5", "", true },
        .{ ",\"skin\":true", "o", "0.5", "", true },
        .{ "", "o", "0.5", keyed, true },
        .{ "", "o", "0.5", crossing, false },
        .{ "", "b", "0.5", "", false },
        .{ "", "o", "1e-40", "", false },
        .{ "", "o", "1e39", "", false },
    }) |case| {
        const skin, const earlier, const low, const timeline, const rigged = case;
        const input = try std.fmt.allocPrint(a,
            \\{{"bones":[{{"name":"root"}},{{"name":"s","parent":"root","scaleX":1.5}},{{"name":"b","parent":"root","scaleX":2}},{{"name":"o","parent":"root"}}],
            \\"transform":[{{"name":"t0","order":0,"bones":["{s}"],"target":"s","mixRotate":0.5,"mixScaleX":0}},
            \\{{"name":"t","order":1,"bones":["b"],"target":"s","local":true,"mixScaleX":0.4,"mixScaleY":0,"scaleX":0.3{s}}}],
            \\"skins":[{{"name":"k","transform":["t"]}}],
            \\"animations":{{"spine-converter/t-b-scaleX":{{}},"a":{{"bones":{{"b":{{"scalex":[{{"value":{s}}},{{"time":1,"value":1.5}}]}}}}{s}}}}}}}
        , .{ earlier, skin, low, timeline });
        const root, const codes = try testCodes(a, input, .up, .{ .rewrite = true });
        try std.testing.expectEqualSlices(Report.Code, &.{if (rigged) .@"transform.scale.rewritten" else .@"transform.scale.approximated"}, codes);
        const list = tree.get(root, "constraints").?.array.items;
        if (!rigged) {
            try std.testing.expectEqual(2, list.len);
            continue;
        }
        const names = [_][]const u8{ "t0", "t-b-scaleX", "t-scale-source", "t-scale-mix", "t" };
        try std.testing.expectEqual(names.len, list.len);
        for (names, list) |name, c| try std.testing.expectEqualStrings(name, try tree.requireString(c, "name"));
        const slider = list[1];
        try std.testing.expectEqualStrings("slider", try tree.requireString(slider, "type"));
        try std.testing.expectEqualStrings("scaleX", try tree.requireString(slider, "property"));
        const animation = try tree.requireString(slider, "animation");
        try std.testing.expectEqualStrings("spine-converter/t-b-scaleX2", animation);
        const animations = tree.get(root, "animations").?;
        const keys = tree.get(tree.get(tree.get(tree.get(animations, animation).?, "bones").?, "b").?, "scalex").?.array.items;
        try std.testing.expect(keys.len > 1 and keys.len < 128);
        try std.testing.expectEqual(0, try tree.getFloat(keys[0], "time", 0));
        try std.testing.expectEqual(0.5, try tree.getFloat(keys[0], "value", 1));
        try std.testing.expectEqual(1, try tree.getFloat(keys[1], "time", 0));
        try std.testing.expectEqual(3, try tree.getFloat(keys[keys.len - 1], "time", 0));
        try std.testing.expectApproxEqRel(1.0 / 6.0, try tree.getFloat(keys[keys.len - 1], "value", 1), 1e-6);
        const multiply = list[2];
        try std.testing.expect(try tree.getBool(multiply, "additive", false));
        try std.testing.expectEqual(0.3, try tree.getFloat(multiply, "scaleX", 0));
        try std.testing.expectEqual(1, try tree.getFloat(multiply, "mixScaleX", 0));
        try std.testing.expectEqual(0, try tree.getFloat(multiply, "mixScaleY", 1));
        try std.testing.expectApproxEqRel(0.6, try tree.getFloat(list[3], "mixScaleX", 0), 1e-6);
        try std.testing.expectEqual(0, try tree.getFloat(list[4], "mixScaleX", 1));
        const lists = tree.get(tree.get(root, "skins").?.array.items[0], "slider");
        try std.testing.expectEqual(skin.len > 0, lists != null);
        if (skin.len > 0) {
            try std.testing.expectEqualStrings("t-b-scaleX", lists.?.array.items[0].string);
            try std.testing.expect(try tree.getBool(slider, "skin", false));
            const transforms = tree.get(tree.get(root, "skins").?.array.items[0], "transform").?.array.items;
            try std.testing.expectEqual(3, transforms.len);
        }
        const timelines = tree.get(tree.get(animations, "a").?, "transform") orelse continue;
        const moved = tree.get(timelines, "t-scale-mix").?.array.items;
        try std.testing.expectApproxEqRel(0.8, try tree.getFloat(moved[0], "mixScaleX", 0), 1e-6);
        try std.testing.expectApproxEqRel(0.2, try tree.getFloat(moved[1], "mixScaleX", 0), 1e-6);
        try std.testing.expectEqual(0, try tree.getFloat(moved[0], "mixRotate", 1));
        const handles = tree.get(moved[0], "curve").?.array.items;
        try std.testing.expectApproxEqRel(0.7, try tree.number(handles[13]), 1e-6);
        try std.testing.expectApproxEqRel(0.3, try tree.number(handles[15]), 1e-6);
        const kept = tree.get(timelines, "t").?.array.items;
        try std.testing.expectEqual(0, try tree.getFloat(kept[1], "mixScaleX", 1));
        try std.testing.expectEqual(0, try tree.number(tree.get(kept[0], "curve").?.array.items[13]));
    }
    const negative =
        \\{"bones":[{"name":"root"},{"name":"s","parent":"root"},{"name":"b","parent":"root","scaleX":2}],
        \\"transform":[{"name":"t","bones":["b"],"target":"s","local":true,"mixScaleX":-0.4,"mixScaleY":0}],
        \\"animations":{"a":{"bones":{"b":{"scalex":[{"value":0.5},{"time":1,"value":1.5}]}},
        \\"transform":{"t":[{"mixScaleX":-0.2,"mixScaleY":0},{"time":1,"mixScaleX":MIX,"mixScaleY":0}]}}}}
    ;
    for ([_]struct { []const u8, Report.Code }{ .{ "-0.8", .@"transform.scale.rewritten" }, .{ "0.3", .@"transform.scale.approximated" } }) |case| {
        _, const codes = try testCodes(a, try std.mem.replaceOwned(u8, a, negative, "MIX", case[0]), .up, .{ .rewrite = true });
        try std.testing.expectEqualSlices(Report.Code, &.{case[1]}, codes);
    }
}

test "local absolute scale with a mix reaching 0 gets a gate" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root"},{"name":"s","parent":"root"},{"name":"b","parent":"root","scaleX":-2}],
        \\"transform":[{"name":"t","bones":["b"],"target":"s","local":true,"mixScaleX":MIX,"mixScaleY":0}],
        \\"animations":{"a":{"bones":{"b":{"scalex":[{"value":0.5},{"time":1,"value":1.5}]}},
        \\"transform":{"t":[{"mixScaleX":0,"mixScaleY":0},{"time":1,"mixScaleX":MIX2,"mixScaleY":0}]}}}}
    ;
    for ([_]struct { []const u8, []const u8, bool, bool }{
        .{ "0", "0.8", true, false },
        .{ "0", "-0.8", true, true },
        .{ "-0.3", "0", true, true },
        .{ "0.3", "-0.8", false, false },
    }) |case| {
        var text = try std.mem.replaceOwned(u8, a, input, "MIX2", case[1]);
        text = try std.mem.replaceOwned(u8, a, text, "MIX", case[0]);
        const root, const codes = try testCodes(a, text, .up, .{ .rewrite = true });
        if (!case[2]) {
            try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.scale.approximated"}, codes);
            continue;
        }
        try std.testing.expectEqualSlices(Report.Code, &.{.@"transform.scale.rewritten"}, codes);
        const list = tree.get(root, "constraints").?.array.items;
        try std.testing.expectEqualStrings("t-scaleMix", try tree.requireString(list[0], "name"));
        try std.testing.expectEqual(case[3], tree.get(list[0], "scale") != null);
        try std.testing.expectEqual(0, try tree.getFloat(list[list.len - 1], "mixScaleX", 1));
    }
}

test "reciprocal keys of a negative scale read the negated scale" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = (try reciprocalKeys(a, 0.5, 3, -1.25, -1)).?.array.items;
    try std.testing.expectEqual(0.5, try tree.getFloat(keys[0], "time", 0));
    try std.testing.expectApproxEqRel(1.6, try tree.getFloat(keys[0], "value", 1), 1e-6);
    try std.testing.expectEqual(3, try tree.getFloat(keys[keys.len - 1], "time", 0));
    try std.testing.expectApproxEqRel(0.26666668, try tree.getFloat(keys[keys.len - 1], "value", 1), 1e-6);
}

test "reciprocal keys as the runtime samples them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const setup: f64 = 1.3;
    const keys = (try reciprocalKeys(a, 0.1, 4, @floatCast(setup), 1)).?.array.items;
    try std.testing.expect(keys.len < 400);
    for (keys[0 .. keys.len - 1], keys[1..]) |k, next| {
        const t0: f64 = try tree.getFloat(k, "time", 0);
        const t1: f64 = try tree.getFloat(next, "time", 0);
        const v0: f64 = try tree.getFloat(k, "value", 1);
        const v1: f64 = try tree.getFloat(next, "value", 1);
        const curve = tree.get(k, "curve").?.array.items;
        var c: [4]f64 = undefined;
        for (&c, curve) |*x, v| x.* = try tree.number(v);
        var x = t0;
        var y = v0;
        for (1..11) |i| {
            const u: f64 = @as(f64, @floatFromInt(i)) / 10;
            const r = 1 - u;
            const px = if (i == 10) t1 else r * r * r * t0 + 3 * r * r * u * c[0] + 3 * r * u * u * c[2] + u * u * u * t1;
            const py = if (i == 10) v1 else r * r * r * v0 + 3 * r * r * u * c[1] + 3 * r * u * u * c[3] + u * u * u * v1;
            for (0..5) |j| {
                const w: f64 = @as(f64, @floatFromInt(j)) / 4;
                const t = x + (px - x) * w;
                try std.testing.expectApproxEqRel(1 / (t * setup), y + (py - y) * w, 2e-6);
            }
            x = px;
            y = py;
        }
    }
}

test "two bone IK with a sheared parent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skeleton = "{\"bones\":[{\"name\":\"root\"},{\"name\":\"p\",\"parent\":\"root\"},{\"name\":\"c\",\"parent\":\"p\"}],\"ik\":[{\"name\":\"i\",\"bones\":[\"p\",\"c\"],\"target\":\"root\"";
    _, const plain = try testCodes(a, skeleton ++ "}]}", .up, .{});
    try std.testing.expectEqual(0, plain.len);
    _, const keyed = try testCodes(a, skeleton ++ "}],\"animations\":{\"a\":{\"bones\":{\"p\":{\"shear\":[{\"x\":5}]}}}}}", .up, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"ik.shear.approximated"}, keyed);
    _, const off = try testCodes(a, skeleton ++ ",\"mix\":0}],\"animations\":{\"a\":{\"bones\":{\"p\":{\"shear\":[{\"x\":5}]}}}}}", .up, .{});
    try std.testing.expectEqual(0, off.len);
}

test "local pose derived after a world constraint" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skeleton = "{\"bones\":[{\"name\":\"root\"},{\"name\":\"p\",\"parent\":\"root\"},{\"name\":\"b\",\"parent\":\"p\",\"inherit\":\"noScale\"}],";
    _, const ik = try testCodes(a, skeleton ++ "\"transform\":[{\"name\":\"t\",\"bones\":[\"b\"],\"target\":\"root\"}],\"ik\":[{\"name\":\"i\",\"order\":1,\"bones\":[\"b\"],\"target\":\"root\"}]}", .up, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.derive.approximated"}, ik);
    _, const ancestor = try testCodes(a, skeleton ++ "\"transform\":[{\"name\":\"t\",\"bones\":[\"b\"],\"target\":\"root\"},{\"name\":\"u\",\"order\":1,\"bones\":[\"p\"],\"target\":\"root\"}]}", .up, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.derive.approximated"}, ancestor);
    _, const earlier = try testCodes(a, skeleton ++ "\"transform\":[{\"name\":\"t\",\"order\":1,\"bones\":[\"b\"],\"target\":\"root\"}],\"ik\":[{\"name\":\"i\",\"bones\":[\"b\"],\"target\":\"root\"}]}", .up, .{});
    try std.testing.expectEqual(0, earlier.len);
    const within = "{\"skeleton\":{\"spine\":\"VERSION\"}," ++ skeleton[1..] ++ "\"slots\":[{\"name\":\"s\",\"bone\":\"root\"}],\"constraints\":[{\"type\":\"path\",\"name\":\"p\",\"bones\":[\"b\"],\"slot\":\"s\"},{\"type\":\"ik\",\"name\":\"i\",\"bones\":[\"b\"],\"target\":\"root\"}]}";
    _, const old_export = try testCodes(a, try std.mem.replaceOwned(u8, a, within, "VERSION", "4.3.01"), .early, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.derive.approximated"}, old_export);
    _, const new_export = try testCodes(a, try std.mem.replaceOwned(u8, a, within, "VERSION", "4.3.03"), .early, .{});
    try std.testing.expectEqual(0, new_export.len);
    _, const old_down = try testCodes(a, try std.mem.replaceOwned(u8, a, within, "VERSION", "4.3.01"), .down, .{});
    try std.testing.expectEqual(0, old_down.len);
    _, const new_down = try testCodes(a, try std.mem.replaceOwned(u8, a, within, "VERSION", "4.3.03"), .down, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{.@"bone.derive.approximated"}, new_down);
}

test "local pose derived alike after a calm world constraint" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "{\"bones\":[{\"name\":\"root\"},{\"name\":\"p\",\"parent\":\"root\"},{\"name\":\"b\",\"parent\":\"p\",ROT\"inherit\":\"noScale\"}]," ++
        "\"transform\":[{\"name\":\"t\",\"bones\":[\"b\"],\"target\":\"root\",\"mixRotate\":0,\"mixShearY\":0,\"mixScaleX\":SCALE}]," ++
        "\"ik\":[{\"name\":\"i\",\"order\":1,\"bones\":[\"b\"],\"target\":\"root\",\"mix\":MIX}]}";
    const Case = struct { []const u8, []const u8, []const u8, bool, []const Report.Code };
    for ([_]Case{
        .{ "", "0.5", "1", false, &.{} },
        .{ "\"rotation\":30,", "0.5", "1", false, &.{.@"bone.derive.approximated"} },
        .{ "\"rotation\":30,", "0.5", "1", true, &.{.@"bone.derive.rewritten"} },
        .{ "\"rotation\":30,", "0.5", "0", true, &.{.@"bone.derive.approximated"} },
        .{ "\"rotation\":30,", "1", "1", true, &.{.@"bone.derive.approximated"} },
        .{ "\"shearY\":10,", "0.5", "1", false, &.{.@"bone.derive.approximated"} },
    }) |case| {
        const text = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, input, "ROT", case[0]), "SCALE", case[1]), "MIX", case[2]);
        _, const codes = try testCodes(a, text, .up, .{ .rewrite = case[3] });
        try std.testing.expectEqualSlices(Report.Code, case[4], codes);
    }
}

test "local pose derived alike in 4.3 exports before 4.3.03" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "{\"skeleton\":{\"spine\":\"4.3.01\"},\"bones\":[{\"name\":\"root\"},{\"name\":\"p\",\"parent\":\"root\"},{\"name\":\"b\",\"parent\":\"p\",\"rotation\":30,\"inherit\":\"noScale\"}]," ++
        "\"constraints\":[{\"name\":\"t\",\"type\":\"transform\",\"bones\":[\"b\"],\"source\":\"root\",\"properties\":{PROPS}}," ++
        "{\"name\":\"i\",\"type\":\"ik\",\"bones\":[\"b\"],\"target\":\"root\"}]}";
    const Case = struct { []const u8, bool, []const Report.Code };
    for ([_]Case{
        .{ "\"x\":{\"to\":{\"x\":{}}}", false, &.{.@"bone.derive.approximated"} },
        .{ "\"x\":{\"to\":{\"x\":{}}}", true, &.{.@"bone.derive.rewritten"} },
        .{ "\"rotate\":{\"to\":{\"rotate\":{}}}", true, &.{.@"bone.derive.approximated"} },
    }) |case| {
        _, const codes = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "PROPS", case[0]), .early, .{ .rewrite = case[1] });
        try std.testing.expectEqualSlices(Report.Code, case[2], codes);
    }
}

test "closed constant speed path walked backward" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, []const u8, usize };
    for ([_]Case{
        .{ "\"spacingMode\":\"fixed\",\"spacing\":-5", "\"closed\":true", 1 },
        .{ "\"spacingMode\":\"fixed\",\"spacing\":5", "\"closed\":true", 0 },
        .{ "\"spacingMode\":\"fixed\",\"spacing\":150", "\"closed\":true", 1 },
        .{ "\"spacingMode\":\"percent\",\"spacing\":-0.1", "\"closed\":true,\"constantSpeed\":false", 0 },
        .{ "\"spacingMode\":\"fixed\",\"spacing\":-5", "\"closed\":false", 0 },
        .{ "\"spacing\":-5", "\"closed\":true", 0 },
    }) |case| {
        const constraint, const attachment, const losses = case;
        const input = try std.fmt.allocPrint(a,
            \\{{"bones":[{{"name":"root"}},{{"name":"b","parent":"root","length":10}}],"slots":[{{"name":"s","bone":"root"}}],
            \\"path":[{{"name":"p","bones":["b"],"target":"s",{s}}}],
            \\"skins":[{{"name":"default","attachments":{{"s":{{"path":{{"type":"path",{s},"lengths":[50,100],"vertexCount":6,"vertices":[0,0,0,0,0,0,0,0,0,0,0,0]}}}}}}}}]}}
        , .{ constraint, attachment });
        _, const codes = try testCodes(a, input, .up, .{});
        try std.testing.expectEqual(losses, std.mem.count(Report.Code, codes, &.{.@"path.closed.approximated"}));
    }
}

test "color curves leaving 0 to 1" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, usize };
    for ([_]Case{
        .{ "\"rgb\":[{\"color\":\"ff0000\",\"curve\":[0.2,1.4,0.8,1,0,0,1,0,0,0,1,0]},{\"time\":1,\"color\":\"ff0000\"}]", 1 },
        .{ "\"rgb\":[{\"color\":\"800000\",\"curve\":[0.2,1.05,0.8,0.5,0,0,1,0,0,0,1,0]},{\"time\":1,\"color\":\"000000\"}]", 0 },
        .{ "\"rgba\":[{\"color\":\"ff0000ff\",\"curve\":[0.2,1.4,0.8,1,0,0,1,0,0,0,1,0,0,1,1,1]},{\"time\":1,\"color\":\"ff0000ff\"}]", 0 },
        .{ "\"alpha\":[{\"value\":0,\"curve\":[0.2,-0.5,0.8,0]},{\"time\":1,\"value\":0}]", 1 },
        .{ "\"rgba2\":[{\"light\":\"ffffffff\",\"dark\":\"000000\",\"curve\":[0,2,1,2,0,2,1,2,0,2,1,2,0,2,1,2,0,0,1,0,0,0,1,0,0,0,1,0]},{\"time\":1,\"light\":\"ffffffff\",\"dark\":\"000000\"}]", 0 },
        .{ "\"rgb2\":[{\"light\":\"ffffff\",\"dark\":\"000000\",\"curve\":[0,0,1,0,0,0,1,0,0,0,1,0,0,-1,1,-1,0,0,1,0,0,0,1,0]},{\"time\":1,\"light\":\"ffffff\",\"dark\":\"000000\"}]", 1 },
    }) |case| {
        const timeline, const losses = case;
        const input = try std.fmt.allocPrint(a, "{{\"bones\":[{{\"name\":\"root\"}}],\"animations\":{{\"a\":{{\"slots\":{{\"s\":{{{s}}}}}}}}}}}", .{timeline});
        _, const codes = try testCodes(a, input, .up, .{});
        try std.testing.expectEqual(losses, codes.len);
    }
}

test "4.3 exports with old semantics" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"skeleton":{"spine":"VERSION"},"bones":[{"name":"root"},{"name":"p","parent":"root"},{"name":"b","parent":"p","inherit":"noRotationOrReflection"}],
        \\"slots":[{"name":"s","bone":"root"},{"name":"t","bone":"root"}],
        \\"constraints":[{"type":"ik","name":"v","bones":["b"],"target":"root","compress":true,"scaleY":"volume"},
        \\{"type":"transform","name":"j","bones":["b"],"source":"root","properties":{"y":{"to":{"y":{}}}}},
        \\{"type":"slider","name":"l","animation":"a"}],
        \\"skins":[{"name":"default","attachments":{"s":{"m":{"type":"mesh","uvs":[],"vertices":[],"triangles":[]}},"t":{"k":{"type":"linkedmesh","source":"m","slot":"s"}}}}],
        \\"animations":{"a":{"bones":{"p":{"scale":[{"x":-1},{"time":1}]}},"attachments":{"default":{"s":{"m":{"deform":[{}]}}}},
        \\"transform":{"j":[{"mixX":0.5}]}}}}
    ;
    _, const old_export = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "VERSION", "4.3.01"), .early, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{ .@"ik.volume.approximated", .@"ik.singular.approximated", .@"bone.singular.approximated", .@"slider.linkedMesh.approximated", .@"transform.jsonMix.approximated", .@"constraint.order.approximated" }, old_export);
    _, const late = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "VERSION", "4.3.20"), .early, .{});
    try std.testing.expectEqualSlices(Report.Code, &.{ .@"slider.linkedMesh.approximated", .@"transform.jsonMix.approximated" }, late);
    _, const current = try testCodes(a, try std.mem.replaceOwned(u8, a, input, "VERSION", "4.3.24"), .early, .{});
    try std.testing.expectEqual(0, current.len);
}

test "4.3 world results reset by a later ancestor constraint" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"skeleton":{"spine":"VERSION"},"bones":[{"name":"root"},{"name":"p","parent":"root"},{"name":"b","parent":"p"},{"name":"x","parent":"root"}],
        \\"constraints":[{"type":"EARLIER","name":"t","bones":["x","b"],"source":"root","target":"root","properties":{"rotate":{"to":{"rotate":{}}}}},
        \\{"type":"transform","name":"u","bones":["p"],"source":"root","mixRotate":0,"properties":{"x":{"to":{"x":{}}}}}],
        \\"animations":{"a":{"transform":{"u":[{"mixX":MIX}]}}}}
    ;
    const Case = struct { version: []const u8, earlier: []const u8 = "transform", mix: []const u8 = "0.5", down: bool = false, rewrite: bool = false, code: ?Report.Code, bones: usize = 2 };
    for ([_]Case{
        .{ .version = "4.3.10", .code = .@"constraint.order.approximated" },
        .{ .version = "4.3.10", .rewrite = true, .code = .@"constraint.order.rewritten", .bones = 1 },
        .{ .version = "4.3.10", .down = true, .rewrite = true, .code = .@"constraint.order.rewritten", .bones = 1 },
        .{ .version = "4.3.10", .mix = "0", .rewrite = true, .code = .@"constraint.order.approximated" },
        .{ .version = "4.3.10", .earlier = "ik", .rewrite = true, .code = null },
        .{ .version = "4.3", .rewrite = true, .code = .@"constraint.order.approximated" },
        .{ .version = "4.3.18", .rewrite = true, .code = null },
        .{ .version = "4.3.18", .down = true, .rewrite = true, .code = null },
    }) |case| {
        var text = try std.mem.replaceOwned(u8, a, input, "VERSION", case.version);
        text = try std.mem.replaceOwned(u8, a, text, "EARLIER", case.earlier);
        text = try std.mem.replaceOwned(u8, a, text, "MIX", case.mix);
        const root, const codes = try testCodes(a, text, if (case.down) .down else .early, .{ .rewrite = case.rewrite });
        if (case.code) |code| try std.testing.expectEqual(1, std.mem.count(Report.Code, codes, &.{code}));
        if (case.code == null) for (codes) |c| try std.testing.expect(c != .@"constraint.order.approximated" and c != .@"constraint.order.rewritten");
        if (!case.down) try std.testing.expectEqual(case.bones, (try tree.getArray(tree.get(root, "constraints").?.array.items[0], "bones")).len);
    }
}

test "4.3 reset restores the bone through a clone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"skeleton":{"spine":"4.3.10"},"bones":[{"name":"root"},{"name":"p","parent":"root"},{"name":"b","parent":"p"BONE},{"name":"x","parent":"root"}],
        \\"constraints":[{"type":"transform","name":"t","bones":["x","b"],"source":"root","properties":{"rotate":{"to":{"rotate":{}}}}},
        \\{"type":"transform","name":"r","bones":["x"],"source":"b","properties":{"rotate":{"to":{"rotate":{}}}}}MORE,
        \\{"type":"transform","name":"u","bones":["p"],"source":"root","properties":{"x":{"to":{"x":{}}}}}],
        \\"animations":{"a":{}}}
    ;
    const Case = struct { bone: []const u8 = "", more: []const u8 = "", code: Report.Code, constraints: usize };
    for ([_]Case{
        .{ .code = .@"constraint.order.rewritten", .constraints = 4 },
        .{ .bone = ",\"shearX\":5", .code = .@"constraint.order.approximated", .constraints = 3 },
        .{ .bone = ",\"scaleX\":0", .code = .@"constraint.order.approximated", .constraints = 3 },
        .{ .more = ",{\"type\":\"ik\",\"name\":\"k\",\"bones\":[\"b\"],\"target\":\"root\"}", .code = .@"constraint.order.approximated", .constraints = 4 },
        .{ .more = ",{\"type\":\"transform\",\"name\":\"k\",\"bones\":[\"x\"],\"source\":\"b\",\"localSource\":true,\"properties\":{\"x\":{\"to\":{\"x\":{}}}}}", .code = .@"constraint.order.approximated", .constraints = 4 },
    }) |case| {
        var text = try std.mem.replaceOwned(u8, a, input, "BONE", case.bone);
        text = try std.mem.replaceOwned(u8, a, text, "MORE", case.more);
        const root, const codes = try testCodes(a, text, .early, .{ .rewrite = true });
        try std.testing.expectEqual(1, std.mem.count(Report.Code, codes, &.{case.code}));
        try std.testing.expectEqual(case.constraints, tree.get(root, "constraints").?.array.items.len);
    }
}

test "4.3 resets only where a pose can differ" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skeleton =
        \\{"skeleton":{"spine":"4.3.10"},"bones":[{"name":"root"},{"name":"p","parent":"root"},{"name":"s","parent":"p","x":10},{"name":"b","parent":"p","x":15,"y":5},{"name":"x","parent":"root"}],
    ;
    const later = "{\"type\":\"transform\",\"name\":\"u\",\"bones\":[\"p\"],\"source\":\"root\",\"mixRotate\":0,\"properties\":{\"rotate\":{\"to\":{\"rotate\":{}}}}}";
    const Case = struct { []const u8, []const u8, usize };
    for ([_]Case{
        .{ "{\"type\":\"transform\",\"name\":\"t\",\"bones\":[\"x\",\"b\"],\"source\":\"x\",\"properties\":{\"rotate\":{\"to\":{\"rotate\":{}}}}}", "\"a\":{\"transform\":{\"u\":[{\"mixRotate\":0.5}]}}", 1 },
        .{ "{\"type\":\"transform\",\"name\":\"t\",\"bones\":[\"x\",\"b\"],\"source\":\"x\",\"mixRotate\":0,\"properties\":{\"rotate\":{\"to\":{\"rotate\":{}}}}}", "\"a\":{\"transform\":{\"u\":[{\"mixRotate\":0.5}]}},\"c\":{\"transform\":{\"t\":[{\"mixRotate\":1}]}}", 0 },
        .{ "{\"type\":\"transform\",\"name\":\"t\",\"bones\":[\"b\"],\"source\":\"s\",\"x\":5,\"y\":5,\"mixX\":-1,\"properties\":{\"x\":{\"to\":{\"x\":{}}},\"y\":{\"to\":{\"y\":{}}}}}", "\"a\":{\"transform\":{\"u\":[{\"mixRotate\":0.5}]}}", 0 },
        .{ "{\"type\":\"transform\",\"name\":\"t\",\"bones\":[\"b\"],\"source\":\"s\",\"x\":5,\"y\":5,\"mixX\":-1,\"properties\":{\"x\":{\"to\":{\"x\":{}}},\"y\":{\"to\":{\"y\":{}}}}}", "\"a\":{\"transform\":{\"u\":[{\"mixRotate\":0.5}]},\"bones\":{\"s\":{\"translate\":[{\"x\":3}]}}}", 1 },
        .{ "{\"type\":\"physics\",\"name\":\"t\",\"bone\":\"b\",\"rotate\":1}", "\"a\":{\"transform\":{\"u\":[{\"mixRotate\":0.5}]}}", 1 },
    }) |case| {
        const earlier, const animations, const losses = case;
        const input = try std.fmt.allocPrint(a, "{s}\"constraints\":[{s},{s}],\"animations\":{{{s}}}}}", .{ skeleton, earlier, later, animations });
        _, const codes = try testCodes(a, input, .early, .{});
        try std.testing.expectEqual(losses, std.mem.count(Report.Code, codes, &.{.@"constraint.order.approximated"}));
    }
}

test "marked stretch IK solves helper bones" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root"},{"name":"p","parent":"root","rotation":10,"scaleX":-2,"scaleY":2},
        \\{"name":"c","parent":"p","x":10,"y":10,"rotation":5}],
        \\"ik":[{"name":"k","bones":["p","c"],"target":"root","stretch":true,"spine-converter-stretch-offset":true}],
        \\"animations":{"a":{"bones":{"c":{"rotate":[{"value":30}]}}}}}
    ;
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    var report: Report = .{ .arena = a };
    try up(a, &root, &report, .{ .rewrite = true });
    const bones = root.object.get("bones").?.array.items;
    try std.testing.expectEqual(5, bones.len);
    try std.testing.expectEqualStrings("spine-converter/k-stretch-parent", bones[3].object.get("name").?.string);
    try std.testing.expectApproxEqAbs(-35, try tree.getFloat(bones[3], "rotation", 0), 1e-4);
    try std.testing.expectApproxEqAbs(@sqrt(200.0), try tree.getFloat(bones[4], "x", 0), 1e-4);
    try std.testing.expectApproxEqAbs(-40, try tree.getFloat(bones[4], "rotation", 0), 1e-4);
    const constraints = root.object.get("constraints").?.array.items;
    try std.testing.expectEqual(3, constraints.len);
    try std.testing.expectEqualStrings("spine-converter/k-stretch-child", (try tree.getArray(constraints[0], "bones"))[1].string);
    try std.testing.expect(constraints[0].object.get("spine-converter-stretch-offset") == null);
    const parent = constraints[1].object.get("properties").?.object.get("rotate").?.object.get("to").?.object.get("rotate").?;
    try std.testing.expectApproxEqAbs(45, try tree.getFloat(parent, "offset", 0), 1e-4);
    try std.testing.expectEqualStrings("c", (try tree.getArray(constraints[2], "bones"))[0].string);
    const helper = root.object.get("animations").?.object.get("a").?.object.get("bones").?.object.get("spine-converter/k-stretch-child").?;
    try std.testing.expect(helper.object.get("rotate") != null);
}

test "physics reported both ways unless its mix stays 0" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, usize }{
        .{ "{\"name\":\"p\",\"bone\":\"b\"}", 1 },
        .{ "{\"name\":\"p\",\"bone\":\"b\",\"mix\":0}", 0 },
    };
    for (cases) |case| {
        const physics, const count = case;
        var report: Report = .{ .arena = a };
        const input = try std.fmt.allocPrint(a, "{{\"bones\":[{{\"name\":\"b\"}}],\"physics\":[{s}]}}", .{physics});
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try up(a, &root, &report, .{});
        try std.testing.expectEqual(count, report.entries.items.len);
        if (count == 0) continue;
        try std.testing.expectEqual(.@"physics.step.approximated", report.entries.items[0].code);
        report = .{ .arena = a };
        try down(a, &root, &report, .{});
        try std.testing.expectEqual(.@"physics.step.approximated", report.entries.items[0].code);
    }
}

test "marked relative scale builds helper bones" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root"},{"name":"b","parent":"root","scaleX":2},{"name":"t","parent":"root"}],
        \\"transform":[{"name":"f","bones":["b"],"target":"t","local":true,"relative":true,"scaleX":0.5,"mixScaleX":0.6,
        \\"spine-converter-relative-scale":true}],
        \\"animations":{"a":{"transform":{"f":[{"mixScaleX":0.2,"curve":[0,0,1,1,0,0,1,1,0,0,1,1,0,0.2,1,0.7,0,0.2,1,0.7,0,0,1,1]},{"time":1}]}}}}
    ;
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    var report: Report = .{ .arena = a };
    try up(a, &root, &report, .{ .rewrite = true });
    try std.testing.expectEqual(5, root.object.get("bones").?.array.items.len);
    const constraints = root.object.get("constraints").?.array.items;
    try std.testing.expectEqual(5, constraints.len);
    try std.testing.expectEqual(0, try tree.getFloat(constraints[0], "mixScaleX", 1));
    try std.testing.expectEqual(0.6, try tree.getFloat(constraints[1], "mixX", 1));
    try std.testing.expectEqual(0.5, try tree.getFloat(constraints[1], "scaleX", 0));
    try std.testing.expectEqualStrings("b", try tree.requireString(constraints[3], "source"));
    const result = constraints[4].object.get("properties").?.object.get("scaleX").?.object.get("to").?.object.get("scaleX").?;
    try std.testing.expectEqual(1, try tree.getFloat(result, "offset", 0));
    const timelines = root.object.get("animations").?.object.get("a").?.object.get("transform").?;
    const moved = timelines.object.get("f-relativeScale").?.array.items[0];
    try std.testing.expectEqual(0.2, try tree.getFloat(moved, "mixX", 1));
    try std.testing.expectEqual(0.7, try tree.number(moved.object.get("curve").?.array.items[7]));
    const kept = timelines.object.get("f").?.array.items[0];
    try std.testing.expectEqual(0, try tree.number(kept.object.get("curve").?.array.items[15]));
}

test "constraints 4.2 never updates are removed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"a"},{"name":"t"}],"skins":[{"name":"s","transform":["two","one"]}],
        \\"ik":[{"name":"i","order":1,"bones":["a"],"target":"t"}],
        \\"transform":[{"name":"one","bones":["a"],"target":"t"},{"name":"two","bones":["a"],"target":"t"},{"name":"far","order":4,"bones":["a"],"target":"t"}],
        \\"animations":{"a":{"transform":{"two":[{"mixX":0}],"one":[{"mixX":0}]}}}}
    ;
    var report: Report = .{ .arena = a };
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    try up(a, &root, &report, .{ .rewrite = true });
    try std.testing.expectEqual(2, report.entries.items.len);
    try std.testing.expectEqualStrings("transform.two", report.entries.items[0].path);
    try std.testing.expectEqualStrings("transform.far", report.entries.items[1].path);
    const constraints = root.object.get("constraints").?.array.items;
    try std.testing.expectEqual(2, constraints.len);
    try std.testing.expectEqualStrings("one", constraints[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("i", constraints[1].object.get("name").?.string);
    report = .{ .arena = a };
    root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    try up(a, &root, &report, .{});
    try std.testing.expectEqual(2, report.entries.items.len);
    try std.testing.expectEqual(.@"constraint.skipped.approximated", report.entries.items[0].code);
}

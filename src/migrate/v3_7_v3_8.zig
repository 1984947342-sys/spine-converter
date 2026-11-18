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

//! Spine 3.7 and 3.8 JSON, mapped by SkeletonJson.java of both branches

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

const curve_handles = [_][]const u8{ "c2", "c3", "c4" };
const curve_defaults = [_]f32{ 0, 1, 1 };
const constraint_kinds = [_][]const u8{ "ik", "transform", "path" };

pub fn early(arena: std.mem.Allocator, root: *Value, report: *Report, target: Version.Minor, flags: Flags) Error!void {
    const v = Version.ofRoot(root.*) orelse return;
    const world = Version.editor(v, .ik_world_38) != .new;
    const solve = Version.editor(v, .ik_solve_3825) != .new;
    if (!world and !solve) return;
    var m: Migration = .{ .arena = arena, .report = report, .step = "3.8", .rewrite = flags.rewrite, .target = target };
    const doc = try edit.objectOf(root);
    try m.index(doc);
    try m.checkEarly(doc, world, solve);
}

pub fn up(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "3.7-3.8", .rewrite = flags.rewrite, .target = flags.target };
    const doc = try edit.objectOf(root);
    if (try edit.childValue(doc, "skins")) |skins| {
        var it = (try edit.objectOf(skins)).iterator();
        var list = try std.json.Array.initCapacity(arena, it.len);
        while (it.next()) |entry| {
            var skin: ObjectMap = .empty;
            try skin.put(arena, "name", .{ .string = entry.key_ptr.* });
            try skin.put(arena, "attachments", entry.value_ptr.*);
            list.appendAssumeCapacity(.{ .object = skin });
        }
        skins.* = .{ .array = list };
    }
    try m.index(doc);
    // the source is 3.7 unless an earlier step ran
    const source = if (Version.ofRoot(root.*)) |v| v.major == 3 and v.minor == 7 else true;
    try m.check(doc, "3.8", source);
    const animations = try edit.childOf(doc, "animations") orelse return;
    for (animations.values()) |*animation| {
        const map = try edit.objectOf(animation);
        _ = edit.take(map, "path");
        try m.rename(map, "paths", "path");
        for (try m.keyLists(map)) |list| for (list.keys) |*key| {
            const k = try edit.objectOf(key);
            try upCurve(arena, k);
            // 3.7 defaults missing scale keys to 0
            if (list.scale) for ([_][]const u8{ "x", "y" }) |axis| {
                if (k.get(axis) == null) try k.put(arena, axis, .{ .float = 0 });
            };
        };
        var skins = try edit.timelinesOf(map, "deform");
        while (skins.next()) |skin| {
            var slots = (try edit.objectOf(skin.value_ptr)).iterator();
            while (slots.next()) |slot| for ((try edit.objectOf(slot.value_ptr)).keys()) |attachment| {
                if (!try m.inheritsDeform(skin.key_ptr.*, slot.key_ptr.*, attachment)) continue;
                const where = try std.fmt.allocPrint(arena, "skins.{s}.{s}.{s}", .{ skin.key_ptr.*, slot.key_ptr.*, attachment });
                if (flags.rewrite and !try m.parentDeformed(skin.key_ptr.*, slot.key_ptr.*, attachment)) {
                    try m.ownDeform(doc, skin.key_ptr.*, slot.key_ptr.*, attachment);
                    try m.lose(.@"linkedmesh.deform.rewritten", where, "linked mesh keeps its own deform keys, its parent has none", .{});
                } else try m.lose(.@"linkedmesh.deform.approximated", where, "3.8 ignores deform keys of a linked mesh that inherits deform", .{});
            };
        }
    }
}

/// Rotate keys of skel sources omit the angle 3.5 to 3.7 JSON loaders require
pub fn jsonAngles(arena: std.mem.Allocator, root: *Value) Error!void {
    const animations = try edit.childOf(try edit.objectOf(root), "animations") orelse return;
    for (animations.values()) |*animation| {
        const bones = try edit.childOf(try edit.objectOf(animation), "bones") orelse continue;
        for (bones.values()) |*bone| {
            const rotate = (try edit.objectOf(bone)).getPtr("rotate") orelse continue;
            for (try edit.keysOf(rotate)) |*key| {
                const k = try edit.objectOf(key);
                if (k.get("angle") == null) try k.put(arena, "angle", .{ .float = 0 });
            }
        }
    }
}

pub fn down(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "3.8-3.7" };
    const doc = try edit.objectOf(root);
    try m.index(doc);
    if (Version.ofRoot(root.*)) |v| {
        m.world_old = Version.editor(v, .ik_world_38) == .old;
        m.solve_old = Version.editor(v, .ik_solve_3825) == .old;
    }
    const target = if (flags.target) |t| t.major == 3 and t.minor == 7 else true;
    try m.check(doc, "3.7", target);
    if (try edit.childOf(doc, "skeleton")) |skeleton| {
        const x = if (edit.take(skeleton, "x")) |v| try tree.number(v) else 0;
        const y = if (edit.take(skeleton, "y")) |v| try tree.number(v) else 0;
        if (x != 0 or y != 0) try m.lose(.@"skeleton.position.dropped", "skeleton", "setup pose bounds position", .{});
    }
    for (try edit.arrayOf(doc, "bones")) |*bone| {
        const map = try edit.objectOf(bone);
        if (try edit.takeBool(map, "skin")) try m.lose(.@"skin.required.dropped", try m.path("bones", map), "3.7 updates the bone without its skin", .{});
    }
    for (constraint_kinds) |kind| for (try edit.arrayOf(doc, kind)) |*c| {
        const map = try edit.objectOf(c);
        if (try edit.takeBool(map, "skin")) try m.lose(.@"skin.required.dropped", try m.path(kind, map), "3.7 applies the constraint without its skin", .{});
    };
    for (try edit.arrayOf(doc, "ik")) |*c| {
        const map = try edit.objectOf(c);
        var soft = if (edit.take(map, "softness")) |v| try tree.number(v) != 0 else false;
        const name = try tree.requireString(c.*, "name");
        if (m.animations) |all| for (all.values()) |*animation| {
            const timelines = try edit.childOf(try edit.objectOf(animation), "ik") orelse continue;
            for (try edit.keysOf(timelines.getPtr(name) orelse continue)) |*key| {
                if (edit.take(try edit.objectOf(key), "softness")) |v| soft = soft or try tree.number(v) != 0;
            }
        };
        if (soft) try m.lose(.@"ik.softness.dropped", try m.path("ik", map), "IK softness", .{});
    }
    if (try edit.childValue(doc, "skins")) |skins| {
        var map: ObjectMap = .empty;
        for (try edit.keysOf(skins)) |*skin| {
            const s = try edit.objectOf(skin);
            const attachments = s.get("attachments") orelse Value{ .object = .empty };
            if (attachments != .object) return error.Malformed;
            try map.put(arena, try tree.requireString(skin.*, "name"), attachments);
        }
        skins.* = .{ .object = map };
    }
    const animations = try edit.childOf(doc, "animations") orelse return;
    for (animations.values()) |*animation| {
        const map = try edit.objectOf(animation);
        _ = edit.take(map, "paths");
        try m.rename(map, "path", "paths");
        var skins = try edit.timelinesOf(map, "deform");
        while (skins.next()) |skin| {
            var slots = (try edit.objectOf(skin.value_ptr)).iterator();
            while (slots.next()) |slot| {
                const attachments = try edit.objectOf(slot.value_ptr);
                var i: usize = 0;
                // 3.8 ignores them where 3.7 applies them
                while (i < attachments.count()) {
                    if (try m.inheritsDeform(skin.key_ptr.*, slot.key_ptr.*, attachments.keys()[i])) attachments.orderedRemoveAt(i) else i += 1;
                }
            }
        }
        for (try m.keyLists(map)) |list| for (list.keys) |*key| {
            const k = try edit.objectOf(key);
            try downCurve(arena, k);
            // 3.7 requires time and angle
            if (k.get("time") == null) try k.put(arena, "time", .{ .float = 0 });
            if (list.rotate and k.get("angle") == null) try k.put(arena, "angle", .{ .float = 0 });
            if (list.scale) for ([_][]const u8{ "x", "y" }) |axis| {
                if (k.get(axis) == null) try k.put(arena, axis, .{ .float = 1 });
            };
        };
    }
}

/// Bone modes the final 3.8 one bone IK solves from the world transform
fn fresh(arena: std.mem.Allocator, taken: anytype, base: []const u8) Error![]const u8 {
    if (!taken.contains(base)) return base;
    var i: usize = 2;
    while (true) : (i += 1) {
        const name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, i });
        if (!taken.contains(name)) return name;
    }
}

fn worldSolved(mode: []const u8, scaled: bool) bool {
    const turns = std.mem.eql(u8, mode, "onlyTranslation") or std.mem.eql(u8, mode, "noRotationOrReflection");
    return turns or scaled and (std.mem.eql(u8, mode, "noScale") or std.mem.eql(u8, mode, "noScaleOrReflection"));
}

fn upCurve(arena: std.mem.Allocator, key: *ObjectMap) Error!void {
    for (curve_handles) |name| _ = edit.take(key, name);
    const curve = edit.take(key, "curve") orelse return;
    switch (curve) {
        .string => |s| if (std.mem.eql(u8, s, "stepped")) try key.put(arena, "curve", curve),
        .array => |c| {
            if (c.items.len != 4) return error.Malformed;
            _ = try tree.number(c.items[0]);
            try key.put(arena, "curve", c.items[0]);
            for (curve_handles, curve_defaults, c.items[1..]) |name, default, v| {
                if (try tree.number(v) != default) try key.put(arena, name, v);
            }
        },
        // 3.7 reads other curves as linear
        else => {},
    }
}

fn downCurve(arena: std.mem.Allocator, key: *ObjectMap) Error!void {
    var handles: [3]?Value = undefined;
    for (curve_handles, &handles) |name, *h| h.* = edit.take(key, name);
    const curve = edit.take(key, "curve") orelse return;
    if (curve == .string) return key.put(arena, "curve", .{ .string = "stepped" });
    var c = try std.json.Array.initCapacity(arena, 4);
    c.appendAssumeCapacity(.{ .float = try tree.number(curve) });
    for (handles, curve_defaults) |h, default| c.appendAssumeCapacity(.{ .float = if (h) |v| try tree.number(v) else default });
    try key.put(arena, "curve", .{ .array = c });
}

const KeyList = struct { keys: []Value, rotate: bool = false, scale: bool = false };

const Migration = struct {
    arena: std.mem.Allocator,
    report: *Report,
    step: []const u8,
    bones: std.StringHashMapUnmanaged(Value) = .empty,
    skins: std.StringHashMapUnmanaged(Value) = .empty,
    animations: ?*ObjectMap = null,
    /// Editor solves one bone IK as 3.7
    world_old: bool = false,
    /// Editor solves a child at the parent origin with both bones
    solve_old: bool = false,
    rewrite: bool = false,
    /// Target of the conversion, null when unknown
    target: ?Version.Minor = null,

    /// Needs the 3.8 skin list
    fn index(m: *Migration, doc: *ObjectMap) Error!void {
        for (try edit.arrayOf(doc, "bones")) |bone| try m.bones.put(m.arena, try tree.requireString(bone, "name"), bone);
        for (try edit.arrayOf(doc, "skins")) |skin| {
            try m.skins.put(m.arena, try tree.requireString(skin, "name"), tree.get(skin, "attachments") orelse .null);
        }
        m.animations = try edit.childOf(doc, "animations");
    }

    /// Solver and transform differences between the runtimes
    fn check(m: *Migration, doc: *ObjectMap, target: []const u8, seven: bool) Error!void {
        for (try edit.arrayOf(doc, "ik")) |*entry| {
            const c = entry.*;
            const ik = try m.ikOf(c);
            if (!ik.mixed) continue;
            if (ik.bones.len == 1) {
                const mode = try m.modeOf(ik.bones[0]);
                if (worldSolved(mode, ik.compress or ik.stretch) and !m.world_old) {
                    if (try m.proxy(doc, entry, ik)) {
                        try m.lose(.@"ik.inherit.rewritten", ik.where, "one bone IK on a {s} bone solved by a normal proxy bone", .{mode});
                    } else try m.lose(.@"ik.inherit.approximated", ik.where, "{s} solves one bone IK on {s} bones differently", .{ target, mode });
                }
            } else if (ik.bones.len == 2 and try m.atOrigin(ik.bones[1].string)) {
                // softness is the only difference left to 3.7
                if (m.solve_old and !ik.soft) continue;
                try m.lose(.@"ik.origin.approximated", ik.where, "3.8 turns only the parent when the child sits at its origin", .{});
            }
        }
        // only a 3.7 side scales by the runtime skeleton scale differently
        if (!seven) return;
        for (try edit.arrayOf(doc, "bones")) |bone| {
            const name = try tree.requireString(bone, "name");
            const where = try std.fmt.allocPrint(m.arena, "bones.{s}", .{name});
            if (std.mem.eql(u8, try tree.getString(bone, "transform") orelse "normal", "noRotationOrReflection")) {
                try m.lose(.@"skeleton.scale.approximated", where, "3.7 applies the skeleton scale twice to noRotationOrReflection bones", .{});
            } else if (tree.get(bone, "parent") == null and try turned(doc, bone, name)) {
                try m.lose(.@"skeleton.scale.approximated", where, "3.7 scales the columns of a turned root by the skeleton scale, 3.6 and 3.8 the rows", .{});
            }
        }
    }

    fn checkEarly(m: *Migration, doc: *ObjectMap, world: bool, solve: bool) Error!void {
        for (try edit.arrayOf(doc, "ik")) |*entry| {
            const c = entry.*;
            const ik = try m.ikOf(c);
            if (!ik.mixed) continue;
            if (ik.bones.len == 1) {
                const mode = try m.modeOf(ik.bones[0]);
                if (world and worldSolved(mode, ik.compress or ik.stretch)) {
                    if (try m.proxy(doc, entry, ik)) {
                        try m.lose(.@"ik.beta.rewritten", ik.where, "one bone IK on a {s} bone solved by a normal proxy bone", .{mode});
                    } else try m.lose(.@"ik.beta.approximated", ik.where, "3.8 exports before 3.8.81 solve one bone IK on {s} bones differently", .{mode});
                }
                continue;
            }
            if (ik.bones.len != 2) continue;
            if (try m.atOrigin(ik.bones[1].string)) {
                const mode = try m.modeOf(ik.bones[0]);
                if (solve) {
                    try m.lose(.@"ik.origin.approximated", ik.where, "3.8.25-beta solves a child at the parent origin with both bones", .{});
                } else if (world and worldSolved(mode, ik.stretch)) {
                    try m.lose(.@"ik.beta.approximated", ik.where, "3.8 exports before 3.8.81 solve a child at the origin of a {s} parent differently", .{mode});
                }
            }
            if (solve and ik.soft and (try m.scaledX(ik.bones[0].string) or try m.scaledX(ik.bones[1].string))) {
                // a parent scale of 1 leaves only the child factor on the softness
                const parent = if (m.rewrite) try m.steadyScaleX(doc, ik.bones[0].string, c) else null;
                const child = if (parent == 1) try m.steadyScaleX(doc, ik.bones[1].string, c) else null;
                if (child) |k| {
                    try m.scaleSoftness(entry, 2 / (k + 1));
                    try m.lose(.@"ik.softness.rewritten", ik.where, "softness divided by the factor 3.8 applies for the child scale", .{});
                } else try m.lose(.@"ik.softness.approximated", ik.where, "3.8.25-beta ignores the bone scale in IK softness", .{});
            }
        }
    }

    const Ik = struct { bones: []const Value, where: []const u8, mixed: bool, compress: bool, stretch: bool, soft: bool };

    fn ikOf(m: *Migration, c: Value) Error!Ik {
        const bones = try tree.getArray(c, "bones");
        for (bones) |bone| if (bone != .string) return error.Malformed;
        const name = try tree.requireString(c, "name");
        var ik: Ik = .{
            .bones = bones,
            .where = try std.fmt.allocPrint(m.arena, "ik.{s}", .{name}),
            .mixed = try tree.getFloat(c, "mix", 1) != 0,
            .compress = try tree.getBool(c, "compress", false),
            .stretch = try tree.getBool(c, "stretch", false),
            .soft = try tree.getFloat(c, "softness", 0) != 0,
        };
        for (try m.constraintKeys("ik", name)) |key| {
            ik.mixed = ik.mixed or try tree.getFloat(key, "mix", 1) != 0;
            ik.compress = ik.compress or try tree.getBool(key, "compress", false);
            ik.stretch = ik.stretch or try tree.getBool(key, "stretch", false);
            ik.soft = ik.soft or try tree.getFloat(key, "softness", 0) != 0;
        }
        return ik;
    }

    fn modeOf(m: *Migration, bone: Value) Error![]const u8 {
        return try tree.getString(m.bones.get(bone.string) orelse .null, "transform") orelse "normal";
    }

    /// Setup or keyed scaleX not 1
    fn scaledX(m: *Migration, name: []const u8) Error!bool {
        const bone = m.bones.get(name) orelse return error.Malformed;
        const setup = try tree.getFloat(bone, "scaleX", 1);
        if (@abs(setup) != 1) return true;
        const animations = m.animations orelse return false;
        for (animations.values()) |animation| {
            const keys = tree.get(tree.get(tree.get(animation, "bones") orelse continue, name) orelse continue, "scale") orelse continue;
            if (keys != .array) return error.Malformed;
            for (keys.array.items) |key| if (@abs(setup * try tree.getFloat(key, "x", 1)) != 1) return true;
        }
        return false;
    }

    /// Constant magnitude of the bone scaleX, null when keys or constraints change it
    fn steadyScaleX(m: *Migration, doc: *ObjectMap, name: []const u8, own: Value) Error!?f32 {
        const bone = m.bones.get(name) orelse return error.Malformed;
        const setup = @abs(try tree.getFloat(bone, "scaleX", 1));
        if (m.animations) |animations| for (animations.values()) |animation| {
            const keys = tree.get(tree.get(tree.get(animation, "bones") orelse continue, name) orelse continue, "scale") orelse continue;
            if (keys != .array) return error.Malformed;
            for (keys.array.items) |key| if (@abs(try tree.getFloat(key, "x", 1)) != 1) return null;
        };
        for ([_][]const u8{ "transform", "path" }) |kind| for (try edit.arrayOf(doc, kind)) |c| {
            for (try tree.getArray(c, "bones")) |b| if (b == .string and std.mem.eql(u8, b.string, name)) return null;
        };
        for (try edit.arrayOf(doc, "ik")) |c| {
            if (std.mem.eql(u8, try tree.requireString(c, "name"), try tree.requireString(own, "name"))) continue;
            if (!try tree.getBool(c, "stretch", false) and !try tree.getBool(c, "compress", false)) continue;
            for (try tree.getArray(c, "bones")) |b| if (b == .string and std.mem.eql(u8, b.string, name)) return null;
        }
        return setup;
    }

    fn scaleSoftness(m: *Migration, c: *Value, factor: f32) Error!void {
        const map = try edit.objectOf(c);
        if (map.get("softness")) |s| try map.put(m.arena, "softness", .{ .float = try tree.number(s) * factor });
        const name = try tree.requireString(c.*, "name");
        const animations = m.animations orelse return;
        for (animations.values()) |*animation| {
            const keys = try edit.childValue(try edit.childOf(try edit.objectOf(animation), "ik") orelse continue, name) orelse continue;
            for (try edit.keysOf(keys)) |*k| {
                const key = try edit.objectOf(k);
                if (key.get("softness")) |s| try key.put(m.arena, "softness", .{ .float = try tree.number(s) * factor });
            }
        }
    }

    /// Moves a one bone IK to a normal proxy bone, in 4.3 or with a 3.8 rig
    fn proxy(m: *Migration, doc: *ObjectMap, entry: *Value, ik: Ik) Error!bool {
        if (!m.rewrite) return false;
        const t = m.target orelse return false;
        if (t.major == 3 and t.minor < 8 or !try m.proxied(doc, entry.*)) return false;
        if (t.major > 4 or t.major == 4 and t.minor >= 3) {
            try entry.object.put(m.arena, marks.ik_proxy, .{ .bool = true });
            return true;
        }
        if (try tree.getBool(entry.*, "skin", false) or !try m.alone(doc, entry.*)) return false;
        const name = ik.bones[0].string;
        // 3.8 to 4.2 local constraints divide the copied scale by the bone scale
        const scaled = ik.compress or ik.stretch;
        if (scaled and !try m.unitScale(name)) return false;
        try m.proxyRig(doc, entry, name, scaled);
        return true;
    }

    /// Order of the constraint is its own and runs
    fn alone(m: *Migration, doc: *ObjectMap, c: Value) Error!bool {
        _ = m;
        const order = try tree.getInt(c, "order", 0);
        var count: i64 = 0;
        var same: usize = 0;
        for (constraint_kinds) |kind| for (try edit.arrayOf(doc, kind)) |other| {
            count += 1;
            if (try tree.getInt(other, "order", 0) == order) same += 1;
        };
        return order >= 0 and order < count and same == 1;
    }

    fn unitScale(m: *Migration, name: []const u8) Error!bool {
        const bone = m.bones.get(name) orelse return error.Malformed;
        if (try tree.getFloat(bone, "scaleX", 1) != 1 or try tree.getFloat(bone, "scaleY", 1) != 1) return false;
        if (m.animations) |animations| for (animations.values()) |animation| {
            const timelines = tree.get(tree.get(animation, "bones") orelse continue, name) orelse continue;
            if (tree.get(timelines, "scale") != null) return false;
        };
        return true;
    }

    /// Normal clone of the bone that solves the IK, then a local constraint copies its rotation and scale back
    fn proxyRig(m: *Migration, doc: *ObjectMap, entry: *Value, name: []const u8, scaled: bool) Error!void {
        const c = try edit.objectOf(entry);
        const ik_name = try tree.requireString(entry.*, "name");
        const order = try tree.getInt(entry.*, "order", 0);
        var constraint_names: std.StringHashMapUnmanaged(void) = .empty;
        for (constraint_kinds) |kind| for (try edit.arrayOf(doc, kind)) |*other| {
            try constraint_names.put(m.arena, try tree.requireString(other.*, "name"), {});
            const at = try tree.getInt(other.*, "order", 0);
            if (at > order) try (try edit.objectOf(other)).put(m.arena, "order", .{ .integer = at + 1 });
        };
        const helper = try fresh(m.arena, &m.bones, try std.fmt.allocPrint(m.arena, "spine-converter/{s}-proxy", .{ik_name}));
        var bone = (try edit.clone(m.arena, m.bones.get(name).?)).object;
        try bone.put(m.arena, "name", .{ .string = helper });
        for ([_][]const u8{ "transform", "color", "skin" }) |key| _ = bone.orderedRemove(key);
        try (try edit.childValue(doc, "bones") orelse return error.Malformed).array.append(.{ .object = bone });
        try m.bones.put(m.arena, helper, .{ .object = bone });
        if (m.animations) |animations| for (animations.values()) |*animation| {
            const timelines = try edit.childOf(try edit.objectOf(animation), "bones") orelse continue;
            if (timelines.get(name)) |t| try timelines.put(m.arena, helper, try edit.clone(m.arena, t));
        };
        (try edit.arrayOf(c, "bones"))[0] = .{ .string = helper };
        var copy: ObjectMap = .empty;
        try copy.put(m.arena, "name", .{ .string = try fresh(m.arena, &constraint_names, try std.fmt.allocPrint(m.arena, "{s}-proxy", .{ik_name})) });
        try copy.put(m.arena, "order", .{ .integer = order + 1 });
        var bones = tree.array(m.arena);
        try bones.append(.{ .string = name });
        try copy.put(m.arena, "bones", .{ .array = bones });
        try copy.put(m.arena, "target", .{ .string = helper });
        try copy.put(m.arena, "local", .{ .bool = true });
        try copy.put(m.arena, "rotateMix", .{ .float = 1 });
        try copy.put(m.arena, "translateMix", .{ .float = 0 });
        try copy.put(m.arena, "scaleMix", .{ .float = if (scaled) 1 else 0 });
        try copy.put(m.arena, "shearMix", .{ .float = 0 });
        if (try edit.childValue(doc, "transform")) |list| {
            if (list.* != .array) return error.Malformed;
            try list.array.append(.{ .object = copy });
        } else {
            var list = tree.array(m.arena);
            try list.append(.{ .object = copy });
            try doc.put(m.arena, "transform", .{ .array = list });
        }
    }

    /// A one bone IK a 4.3 proxy reproduces, on a bone no other constraint changes
    fn proxied(m: *Migration, doc: *ObjectMap, c: Value) Error!bool {
        const name = (try tree.getArray(c, "bones"))[0].string;
        const bone = m.bones.get(name) orelse return error.Malformed;
        if (try tree.getBool(bone, "skin", false)) return false;
        const own = try tree.requireString(c, "name");
        for ([_][]const u8{ "ik", "transform", "path" }) |kind| for (try edit.arrayOf(doc, kind)) |other| {
            if (std.mem.eql(u8, kind, "ik") and std.mem.eql(u8, try tree.requireString(other, "name"), own)) continue;
            for (try tree.getArray(other, "bones")) |b| if (b == .string and std.mem.eql(u8, b.string, name)) return false;
        };
        // the target must not follow the bone
        var at: ?[]const u8 = try tree.requireString(c, "target");
        while (at) |t| : (at = try tree.getString(m.bones.get(t) orelse return error.Malformed, "parent")) {
            if (std.mem.eql(u8, t, name)) return false;
        }
        return true;
    }

    /// 3.8 skips the two bone solve below this parent distance
    fn atOrigin(m: *Migration, child: []const u8) Error!bool {
        const bone = m.bones.get(child) orelse return error.Malformed;
        if (@abs(try tree.getFloat(bone, "x", 0)) < 0.0001 and @abs(try tree.getFloat(bone, "y", 0)) < 0.0001) return true;
        const animations = m.animations orelse return false;
        for (animations.values()) |animation| {
            const keys = tree.get(tree.get(tree.get(animation, "bones") orelse continue, child) orelse continue, "translate") orelse continue;
            if (keys != .array) return error.Malformed;
            for (keys.array.items) |key| {
                if (@abs(try tree.getFloat(key, "x", 0)) < 0.0001 and @abs(try tree.getFloat(key, "y", 0)) < 0.0001) return true;
            }
        }
        return false;
    }

    fn inheritsDeform(m: *Migration, skin: []const u8, slot: []const u8, name: []const u8) Error!bool {
        const attachment = tree.get(tree.get(m.skins.get(skin) orelse return false, slot) orelse return false, name) orelse return false;
        const kind = try tree.getString(attachment, "type") orelse return false;
        return std.mem.eql(u8, kind, "linkedmesh") and try tree.getBool(attachment, "deform", true);
    }

    /// Some animation deforms the parent of a linked mesh
    fn parentDeformed(m: *Migration, skin: []const u8, slot: []const u8, name: []const u8) Error!bool {
        const linked = tree.get(tree.get(m.skins.get(skin) orelse return error.Malformed, slot) orelse return error.Malformed, name) orelse return error.Malformed;
        const parent = try tree.requireString(linked, "parent");
        // 3.7 finds the parent in the default skin unless the linked mesh names one
        const parent_skin = try tree.getString(linked, "skin") orelse "default";
        const animations = m.animations orelse return false;
        for (animations.values()) |animation| {
            const slots = tree.get(tree.get(animation, "deform") orelse continue, parent_skin) orelse continue;
            if (tree.get(tree.get(slots, slot) orelse continue, parent) != null) return true;
        }
        return false;
    }

    /// 3.8 then applies the linked mesh timelines and no others
    fn ownDeform(m: *Migration, doc: *ObjectMap, skin: []const u8, slot: []const u8, name: []const u8) Error!void {
        for (try edit.arrayOf(doc, "skins")) |*s| {
            const map = try edit.objectOf(s);
            if (!std.mem.eql(u8, try tree.requireString(s.*, "name"), skin)) continue;
            const slots = try edit.childOf(map, "attachments") orelse return error.Malformed;
            const entries = try edit.childOf(slots, slot) orelse return error.Malformed;
            const linked = try edit.childOf(entries, name) orelse return error.Malformed;
            return linked.put(m.arena, "deform", .{ .bool = false });
        }
        return error.Malformed;
    }

    /// Key arrays of every timeline in an animation
    fn keyLists(m: *Migration, animation: *ObjectMap) Error![]KeyList {
        var out: std.ArrayList(KeyList) = .empty;
        for ([_][]const u8{ "bones", "slots", "path", "paths" }) |group| {
            var owners = try edit.timelinesOf(animation, group);
            while (owners.next()) |owner| {
                var timelines = (try edit.objectOf(owner.value_ptr)).iterator();
                while (timelines.next()) |t| {
                    const bones = std.mem.eql(u8, group, "bones");
                    try out.append(m.arena, .{
                        .keys = try edit.keysOf(t.value_ptr),
                        .rotate = bones and std.mem.eql(u8, t.key_ptr.*, "rotate"),
                        .scale = bones and std.mem.eql(u8, t.key_ptr.*, "scale"),
                    });
                }
            }
        }
        for ([_][]const u8{ "ik", "transform" }) |group| {
            var constraints = try edit.timelinesOf(animation, group);
            while (constraints.next()) |c| try out.append(m.arena, .{ .keys = try edit.keysOf(c.value_ptr) });
        }
        var skins = try edit.timelinesOf(animation, "deform");
        while (skins.next()) |skin| {
            var slots = (try edit.objectOf(skin.value_ptr)).iterator();
            while (slots.next()) |slot| for ((try edit.objectOf(slot.value_ptr)).values()) |*attachment| {
                try out.append(m.arena, .{ .keys = try edit.keysOf(attachment) });
            };
        }
        for ([_][]const u8{ "drawOrder", "draworder", "events" }) |name| {
            if (try edit.childValue(animation, name)) |keys| try out.append(m.arena, .{ .keys = try edit.keysOf(keys) });
        }
        return out.items;
    }

    /// Keys of one constraint in all animations
    fn constraintKeys(m: *Migration, kind: []const u8, name: []const u8) Error![]const Value {
        var out: std.ArrayList(Value) = .empty;
        const animations = m.animations orelse return &.{};
        for (animations.values()) |*animation| {
            const constraints = try edit.childOf(try edit.objectOf(animation), kind) orelse continue;
            try out.appendSlice(m.arena, try edit.keysOf(constraints.getPtr(name) orelse continue));
        }
        return out.items;
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

test "skins curves and timelines up and down" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Report = .{ .arena = a };
    const old =
        \\{"skeleton":{"spine":"3.6.53"},"bones":[{"name":"root"}],"slots":[{"name":"s","bone":"root"}],"skins":{"default":{"s":{"r":{}}},"red":{}},
        \\"animations":{"a":{"bones":{"root":{"scale":[{"time":0,"x":2,"curve":[0.25,0,0.75,0.5],"c2":9},{"time":1,"curve":"linear"}],
        \\"rotate":[{"time":0,"angle":5,"curve":"stepped"},{"time":1,"angle":0}]}},"paths":{"p":{"mix":[{"time":0}]}}}}}
    ;
    var root = try std.json.parseFromSliceLeaky(Value, a, old, .{});
    try up(a, &root, &report, .{});
    try std.testing.expectEqual(0, report.entries.items.len);
    const skins = root.object.get("skins").?.array.items;
    try std.testing.expectEqual(2, skins.len);
    try std.testing.expectEqualStrings("red", skins[1].object.get("name").?.string);
    try std.testing.expectEqual(1, skins[0].object.get("attachments").?.object.count());
    const animation = root.object.get("animations").?.object.get("a").?.object;
    try std.testing.expect(animation.get("paths") == null and animation.get("path") != null);
    const scale = animation.get("bones").?.object.get("root").?.object.get("scale").?.array.items;
    try std.testing.expectEqual(0.25, try tree.number(scale[0].object.get("curve").?));
    try std.testing.expect(scale[0].object.get("c2") == null);
    try std.testing.expectEqual(0.75, try tree.number(scale[0].object.get("c3").?));
    try std.testing.expectEqual(0.5, try tree.number(scale[0].object.get("c4").?));
    try std.testing.expectEqual(0, try tree.number(scale[0].object.get("y").?));
    try std.testing.expectEqual(0, try tree.number(scale[1].object.get("x").?));
    try std.testing.expect(scale[1].object.get("curve") == null);
    const rotate = animation.get("bones").?.object.get("root").?.object.get("rotate").?.array.items;
    try std.testing.expectEqualStrings("stepped", rotate[0].object.get("curve").?.string);

    const new =
        \\{"skeleton":{"x":-5,"y":0},"bones":[{"name":"root"},{"name":"b","parent":"root","skin":true}],
        \\"ik":[{"name":"i","bones":["b"],"target":"root","softness":3}],
        \\"skins":[{"name":"default","attachments":{}},{"name":"red","bones":["b"]}],
        \\"animations":{"a":{"bones":{"root":{"scale":[{"x":2,"curve":0.25,"c4":0.5},{"time":1,"curve":"x"}],"rotate":[{"time":1}]}},
        \\"ik":{"i":[{"softness":0,"mix":0.5}]},"path":{"p":{"mix":[{}]}},"events":[{"name":"e"}]}}}
    ;
    root = try std.json.parseFromSliceLeaky(Value, a, new, .{});
    try down(a, &root, &report, .{ .target = .{ .major = 3, .minor = 6 } });
    const codes = [_]Report.Code{ .@"skeleton.position.dropped", .@"skin.required.dropped", .@"ik.softness.dropped" };
    try std.testing.expectEqual(codes.len, report.entries.items.len);
    for (codes, report.entries.items) |code, entry| try std.testing.expectEqual(code, entry.code);
    try std.testing.expect(root.object.get("skeleton").?.object.get("x") == null);
    try std.testing.expect(root.object.get("bones").?.array.items[1].object.get("skin") == null);
    try std.testing.expect(root.object.get("ik").?.array.items[0].object.get("softness") == null);
    const map = root.object.get("skins").?.object;
    try std.testing.expectEqual(2, map.count());
    try std.testing.expectEqual(0, map.get("red").?.object.count());
    const restored = root.object.get("animations").?.object.get("a").?.object;
    try std.testing.expect(restored.get("path") == null and restored.get("paths") != null);
    try std.testing.expect(restored.get("ik").?.object.get("i").?.array.items[0].object.get("softness") == null);
    const keys = restored.get("bones").?.object.get("root").?.object.get("scale").?.array.items;
    const curve = keys[0].object.get("curve").?.array.items;
    for ([_]f32{ 0.25, 0, 1, 0.5 }, curve) |want, got| try std.testing.expectEqual(want, try tree.number(got));
    try std.testing.expect(keys[0].object.get("c4") == null);
    try std.testing.expectEqual(0, try tree.number(keys[0].object.get("time").?));
    try std.testing.expectEqual(1, try tree.number(keys[0].object.get("y").?));
    try std.testing.expectEqualStrings("stepped", keys[1].object.get("curve").?.string);
    const turn = restored.get("bones").?.object.get("root").?.object.get("rotate").?.array.items[0].object;
    try std.testing.expectEqual(0, try tree.number(turn.get("angle").?));
    try std.testing.expectEqual(0, try tree.number(restored.get("events").?.array.items[0].object.get("time").?));

    var bad = try std.json.parseFromSliceLeaky(Value, a, "{\"animations\":{\"a\":{\"ik\":{\"i\":[{\"curve\":[1,2]}]}}}}", .{});
    try std.testing.expectError(error.Malformed, up(a, &bad, &report, .{}));
}

/// A root bone with rotation or shear in its setup or keys
fn turned(doc: *ObjectMap, bone: Value, name: []const u8) Error!bool {
    for ([_][]const u8{ "rotation", "shearX", "shearY" }) |key| if (try tree.getFloat(bone, key, 0) != 0) return true;
    const animations = try edit.childOf(doc, "animations") orelse return false;
    for (animations.values()) |animation| {
        const timelines = tree.get(tree.get(animation, "bones") orelse continue, name) orelse continue;
        if (tree.get(timelines, "rotate") != null or tree.get(timelines, "shear") != null) return true;
    }
    return false;
}

test "a turned root under a 3.7 skeleton scale" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, usize }{
        .{ "{\"bones\":[{\"name\":\"root\",\"rotation\":30}]}", 1 },
        .{ "{\"skeleton\":{\"spine\":\"3.6.53\"},\"bones\":[{\"name\":\"root\",\"rotation\":30}]}", 0 },
        .{ "{\"bones\":[{\"name\":\"root\"}],\"animations\":{\"a\":{\"bones\":{\"root\":{\"shear\":[{\"x\":5}]}}}}}", 1 },
        .{ "{\"bones\":[{\"name\":\"root\"}]}", 0 },
    }) |case| {
        var report: Report = .{ .arena = a };
        var root = try std.json.parseFromSliceLeaky(Value, a, case[0], .{});
        try up(a, &root, &report, .{});
        try std.testing.expectEqual(case[1], report.entries.items.len);
    }
}

test "solver differences" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { mode: []const u8, ik: []const u8, extra: []const u8 = "", child: []const u8 = "", code: ?Report.Code };
    for ([_]Case{
        .{ .mode = "onlyTranslation", .ik = "\"b\"", .code = .@"ik.inherit.approximated" },
        .{ .mode = "noRotationOrReflection", .ik = "\"b\"", .extra = ",\"mix\":0", .code = .@"skeleton.scale.approximated" },
        .{ .mode = "noScale", .ik = "\"b\"", .code = null },
        .{ .mode = "noScale", .ik = "\"b\"", .extra = ",\"stretch\":true", .code = .@"ik.inherit.approximated" },
        .{ .mode = "normal", .ik = "\"b\",\"c\"", .child = ",\"x\":5", .code = null },
        .{ .mode = "normal", .ik = "\"b\",\"c\"", .code = .@"ik.origin.approximated" },
    }) |case| {
        for ([_]bool{ false, true }) |downward| {
            var report: Report = .{ .arena = a };
            const input = try std.fmt.allocPrint(a, "{{\"bones\":[{{\"name\":\"root\"}},{{\"name\":\"b\",\"parent\":\"root\",\"transform\":\"{s}\"}},{{\"name\":\"c\",\"parent\":\"b\"{s}}}],\"ik\":[{{\"name\":\"i\",\"bones\":[{s}],\"target\":\"root\"{s}}}]}}", .{ case.mode, case.child, case.ik, case.extra });
            var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
            if (downward) try down(a, &root, &report, .{}) else try up(a, &root, &report, .{});
            const entries = report.entries.items;
            if (case.code) |code| {
                try std.testing.expectEqual(1, entries.len);
                try std.testing.expectEqual(code, entries[0].code);
            } else try std.testing.expectEqual(0, entries.len);
        }
    }
}

fn earlyCodes(a: std.mem.Allocator, version: []const u8, body: []const u8, downward: bool) ![]const Report.Code {
    var report: Report = .{ .arena = a };
    const input = try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"{s}\"}},{s}}}", .{ version, body });
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    if (downward) try down(a, &root, &report, .{}) else try early(a, &root, &report, .{ .major = 3, .minor = 8 }, .{});
    var out: std.ArrayList(Report.Code) = .empty;
    for (report.entries.items) |e| try out.append(a, e.code);
    return out.items;
}

test "early 3.8 IK solves" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one =
        \\"bones":[{{"name":"root"}},{{"name":"b","parent":"root","transform":"{s}"}}],"ik":[{{"name":"i","bones":["b"],"target":"root"{s}}}]
    ;
    const two =
        \\"bones":[{{"name":"root"}},{{"name":"p","parent":"root","transform":"{s}"{s}}},{{"name":"c","parent":"p"{s}}}],
        \\"ik":[{{"name":"i","bones":["p","c"],"target":"root"{s}}}]
    ;
    const Case = struct { []const u8, []const u8, []const Report.Code };
    const beta: []const Report.Code = &.{.@"ik.beta.approximated"};
    for ([_]Case{
        .{ "3.8.75", try std.fmt.allocPrint(a, one, .{ "onlyTranslation", "" }), beta },
        .{ "3.8.55", try std.fmt.allocPrint(a, one, .{ "noRotationOrReflection", "" }), beta },
        .{ "3.8", try std.fmt.allocPrint(a, one, .{ "onlyTranslation", "" }), beta },
        .{ "3.8.99", try std.fmt.allocPrint(a, one, .{ "onlyTranslation", "" }), &.{} },
        .{ "3.8.79", try std.fmt.allocPrint(a, one, .{ "onlyTranslation", ",\"mix\":0" }), &.{} },
        .{ "3.8.76", try std.fmt.allocPrint(a, one, .{ "noScale", "" }), &.{} },
        .{ "3.8.76", try std.fmt.allocPrint(a, one, .{ "noScale", ",\"compress\":true" }), beta },
        .{ "3.8.55", try std.fmt.allocPrint(a, two, .{ "onlyTranslation", "", "", "" }), beta },
        .{ "3.8.55", try std.fmt.allocPrint(a, two, .{ "noScale", "", "", ",\"compress\":true" }), &.{} },
        .{ "3.8.55", try std.fmt.allocPrint(a, two, .{ "normal", "", "", "" }), &.{} },
        .{ "3.8.81", try std.fmt.allocPrint(a, two, .{ "onlyTranslation", "", "", "" }), &.{} },
        .{ "3.8.25-beta", try std.fmt.allocPrint(a, two, .{ "onlyTranslation", "", "", "" }), &.{.@"ik.origin.approximated"} },
        .{ "3.8.25-beta", try std.fmt.allocPrint(a, two, .{ "normal", ",\"scaleX\":2", ",\"x\":5", ",\"softness\":3" }), &.{.@"ik.softness.approximated"} },
        .{ "3.8.25-beta", try std.fmt.allocPrint(a, two, .{ "normal", ",\"scaleX\":-1", ",\"x\":5", ",\"softness\":3" }), &.{} },
        .{ "3.8.25-beta", try std.fmt.allocPrint(a, two, .{ "normal", "", ",\"x\":5", "" }), &.{} },
        .{ "3.8.26-beta", try std.fmt.allocPrint(a, two, .{ "normal", ",\"scaleX\":2", ",\"x\":5", ",\"softness\":3" }), &.{} },
        .{ "3.8.25-beta", try std.fmt.allocPrint(a, two ++ ",\"animations\":{{\"a\":{{\"bones\":{{\"c\":{{\"scale\":[{{\"x\":0.5}}]}}}}}}}}", .{ "normal", "", ",\"x\":5", ",\"softness\":3" }), &.{.@"ik.softness.approximated"} },
    }) |case| {
        const got = try earlyCodes(a, case[0], case[1], false);
        try std.testing.expectEqualSlices(Report.Code, case[2], got);
    }
}

test "early 3.8 IK solves go down without loss" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one =
        \\"bones":[{"name":"root"},{"name":"b","parent":"root","transform":"onlyTranslation"}],"ik":[{"name":"i","bones":["b"],"target":"root"}]
    ;
    const two =
        \\"bones":[{{"name":"root"}},{{"name":"p","parent":"root"}},{{"name":"c","parent":"p"}}],"ik":[{{"name":"i","bones":["p","c"],"target":"root"{s}}}]
    ;
    const inherit: []const Report.Code = &.{.@"ik.inherit.approximated"};
    const origin: []const Report.Code = &.{.@"ik.origin.approximated"};
    const Case = struct { []const u8, []const u8, []const Report.Code };
    for ([_]Case{
        .{ "3.8.25-beta", one, &.{} },
        .{ "3.8.55", one, &.{} },
        .{ "3.8.79", one, &.{} },
        .{ "3.8.81", one, inherit },
        .{ "3.8.99", one, inherit },
        .{ "3.8", one, inherit },
        .{ "3.8.25-beta", try std.fmt.allocPrint(a, two, .{""}), &.{} },
        .{ "3.8.25-beta", try std.fmt.allocPrint(a, two, .{",\"softness\":2"}), &.{ .@"ik.origin.approximated", .@"ik.softness.dropped" } },
        .{ "3.8.26-beta", try std.fmt.allocPrint(a, two, .{""}), origin },
    }) |case| {
        const got = try earlyCodes(a, case[0], case[1], true);
        try std.testing.expectEqualSlices(Report.Code, case[2], got);
    }
}

test "deform keys of linked meshes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const animations =
        \\"animations":{"a":{"deform":{"default":{"s":{"l":[{"time":0}],"k":[{"time":0}],"m":[{"time":0}]}}}}}}
    ;
    const attachments =
        \\{"s":{"m":{"type":"mesh"},"l":{"type":"linkedmesh","parent":"m"},"k":{"type":"linkedmesh","parent":"m","deform":false}}}
    ;
    var report: Report = .{ .arena = a };
    var root = try std.json.parseFromSliceLeaky(Value, a, "{\"skins\":{\"default\":" ++ attachments ++ "}," ++ animations, .{});
    try up(a, &root, &report, .{});
    try std.testing.expectEqual(1, report.entries.items.len);
    try std.testing.expectEqual(.@"linkedmesh.deform.approximated", report.entries.items[0].code);
    try std.testing.expectEqualStrings("skins.default.s.l", report.entries.items[0].path);

    report = .{ .arena = a };
    root = try std.json.parseFromSliceLeaky(Value, a, "{\"skins\":[{\"name\":\"default\",\"attachments\":" ++ attachments ++ "}]," ++ animations, .{});
    try down(a, &root, &report, .{});
    try std.testing.expectEqual(0, report.entries.items.len);
    const deform = root.object.get("animations").?.object.get("a").?.object.get("deform").?.object.get("default").?.object.get("s").?.object;
    try std.testing.expectEqual(2, deform.count());
    try std.testing.expect(deform.get("l") == null);
}

test "rotate keys of JSON before 3.8 carry an angle" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try std.json.parseFromSliceLeaky(Value, a, "{\"animations\":{\"a\":{\"bones\":{\"b\":{\"rotate\":[{\"time\":0},{\"time\":1,\"angle\":5}],\"translate\":[{\"time\":0}]}}}}}", .{});
    try jsonAngles(a, &root);
    const bone = tree.get(tree.get(tree.get(root, "animations").?, "a").?, "bones").?.object.get("b").?;
    try std.testing.expectEqual(0, try tree.getFloat(bone.object.get("rotate").?.array.items[0], "angle", 1));
    try std.testing.expectEqual(5, try tree.getFloat(bone.object.get("rotate").?.array.items[1], "angle", 1));
    try std.testing.expect(tree.get(bone.object.get("translate").?.array.items[0], "angle") == null);
}

test "linked mesh deform keys without parent keys stay its own" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"skins":{"default":{"s":{"m":{"type":"mesh"}}},"b":{"s":{"l":{"type":"linkedmesh","parent":"m"}}}},
        \\"animations":{"a":{"deform":{"b":{"s":{"l":[{"time":0}]}}}}}}
    ;
    for ([_]bool{ true, false }) |rewrite| {
        var report: Report = .{ .arena = a };
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try up(a, &root, &report, .{ .rewrite = rewrite });
        try std.testing.expectEqual(1, report.entries.items.len);
        const linked = root.object.get("skins").?.array.items[1].object.get("attachments").?.object.get("s").?.object.get("l").?;
        try std.testing.expectEqual(!rewrite, try tree.getBool(linked, "deform", true));
        try std.testing.expectEqual(if (rewrite) Report.Code.@"linkedmesh.deform.rewritten" else .@"linkedmesh.deform.approximated", report.entries.items[0].code);
    }
}

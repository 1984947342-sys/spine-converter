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

//! Spine 3.6 and 3.7 JSON, mapped by SkeletonJson.java of both branches

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Report = @import("../Report.zig");
const Version = @import("../Version.zig");
const Flags = @import("../Document.zig").Flags;
const atlas = @import("../atlas.zig");
const tree = @import("../binary/tree.zig");
const edit = @import("../edit.zig");
const marks = @import("marks.zig");
const spaces = @import("chain.zig");

pub const Error = error{ Malformed, OutOfMemory };

/// Local transform mixes 3.6 applies only when positive
const local_mixes = [_][]const u8{ "scaleMix", "shearMix" };

pub fn early(arena: std.mem.Allocator, root: *Value, report: *Report, target: Version.Minor, flags: Flags) Error!void {
    const v = Version.ofRoot(root.*) orelse return;
    var m: Migration = .{ .arena = arena, .report = report, .step = "3.7", .rewrite = flags.rewrite, .slider = flags.rewrite and target.major == 4 and target.minor >= 3 };
    const doc = try edit.objectOf(root);
    m.animations = try edit.childOf(doc, "animations");
    const reflect = Version.editor(v, .reflect_37);
    if (reflect != .new) try m.reflection(doc, "3.7 before 3.7.72-beta does not reflect noScale bones under a reflected parent", reflect == .old and flags.rewrite);
    const local = Version.editor(v, .local_mix_37);
    if (local != .new) {
        for (try edit.arrayOf(doc, "transform")) |*c| {
            if (!try tree.getBool(c.*, "local", false)) continue;
            if (local == .old) {
                for (local_mixes) |key| try m.clampMix(doc, c, key);
            } else try m.negativeMix(c.*, "3.7 before 3.7.74-beta ignores negative local scale and shear mixes");
        }
        try m.localShear(doc, "3.7 before 3.7.74-beta adds absolute local shear to the local pose instead of the applied pose");
    }
    if (Version.editor(v, .path_start_37) != .new) for (try edit.arrayOf(doc, "path")) |c| {
        if (try m.startsOnCurve(c)) try m.lose(.@"path.start.approximated", try m.pathOf("path", try tree.requireString(c, "name")), "3.7 before 3.7.43-beta evaluates curves at 1e-5 or more and takes tangents near a curve start from the curve", .{});
    };
}

pub fn up(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "3.6-3.7", .rewrite = flags.rewrite, .slider = flags.slider and flags.rewrite };
    const doc = try edit.objectOf(root);
    if (flags.atlas) |text| m.regions = atlas.regionMap(arena, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    m.animations = try edit.childOf(doc, "animations");
    for (try edit.arrayOf(doc, "transform")) |*c| {
        if (!try tree.getBool(c.*, "local", false)) continue;
        for (local_mixes) |key| try m.clampMix(doc, c, key);
    }
    try m.check(doc);
    try m.stripped(doc);
}

pub fn down(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "3.7-3.6", .rewrite = flags.rewrite, .down = true };
    const doc = try edit.objectOf(root);
    m.animations = try edit.childOf(doc, "animations");
    if (Version.ofRoot(root.*)) |v| {
        // old 3.7 editors pose these like 3.6
        m.local_old = Version.editor(v, .local_mix_37) == .old;
        m.start_old = Version.editor(v, .path_start_37) == .old;
        if (Version.editor(v, .reflect_37) != .new) try m.reflection(doc, "3.6 reflects noScale bones under a reflected parent", false);
    }
    if (!m.local_old) for (try edit.arrayOf(doc, "transform")) |c| {
        if (try tree.getBool(c, "local", false)) try m.negativeMix(c, "3.6 ignores negative local scale and shear mixes");
    };
    try m.check(doc);
    for (try edit.arrayOf(doc, "ik")) |*c| try m.downIk(try edit.objectOf(c));
    if (try edit.childOf(doc, "skeleton")) |skeleton| if (edit.take(skeleton, "audio")) |audio| {
        if (audio == .string and audio.string.len > 0) try m.lose(.@"skeleton.audio.dropped", "skeleton.audio", "audio path", .{});
    };
    if (try edit.childOf(doc, "events")) |events| {
        var it = events.iterator();
        while (it.next()) |event| {
            const map = try edit.objectOf(event.value_ptr);
            _ = edit.take(map, "volume");
            _ = edit.take(map, "balance");
            if (edit.take(map, "audio")) |audio| if (audio == .string) {
                try m.lose(.@"event.audio.dropped", try m.pathOf("events", event.key_ptr.*), "event audio, volume and balance", .{});
            };
        }
    }
    const animations = m.animations orelse return;
    for (animations.values()) |*animation| {
        for (try edit.arrayOf(try edit.objectOf(animation), "events")) |*key| {
            const map = try edit.objectOf(key);
            _ = edit.take(map, "volume");
            _ = edit.take(map, "balance");
        }
    }
}

const Migration = struct {
    arena: std.mem.Allocator,
    report: *Report,
    step: []const u8,
    animations: ?*ObjectMap = null,
    /// Editor skips negative local mixes and shears the local pose
    local_old: bool = false,
    /// Editor evaluates a curve start like final 3.6
    start_old: bool = false,
    rewrite: bool = false,
    down: bool = false,
    /// Regions of the atlas given with the skeleton
    regions: ?std.StringHashMapUnmanaged(atlas.Region) = null,
    /// The run reaches 4.3 sliders with rewrites
    slider: bool = false,

    /// 3.7 applies the negative mixes 3.6 skips
    fn clampMix(m: *Migration, doc: *ObjectMap, entry: *Value, key: []const u8) Error!void {
        const c = try edit.objectOf(entry);
        const name = try tree.requireString(entry.*, "name");
        var crosses = false;
        if (m.animations) |animations| for (animations.values()) |animation| {
            const timeline = tree.get(tree.get(animation, "transform") orelse continue, name) orelse continue;
            if (timeline != .array) return error.Malformed;
            const keys = timeline.array.items;
            for (keys, 0..) |*k, i| {
                const value = try tree.getFloat(k.*, key, 1);
                if (i + 1 < keys.len) crosses = crosses or try crossing(value, try tree.getFloat(keys[i + 1], key, 1), tree.get(k.*, "curve"));
            }
        };
        const where = try m.pathOf("transform", name);
        // a 4.3 slider clamps the live mix at 0
        if (crosses and m.slider and !try m.targetUnder(doc, entry.*)) {
            try c.put(m.arena, if (std.mem.eql(u8, key, "scaleMix")) marks.scale_floor else marks.shear_floor, .{ .bool = true });
            return m.lose(.@"transform.localMix.rewritten", where, "{s} keys cross zero, clamped at 0 by a 4.3 slider", .{key});
        }
        if (try edit.float(c, key, 1) < 0) try c.put(m.arena, key, .{ .integer = 0 });
        if (m.animations) |animations| for (animations.values()) |animation| {
            const timeline = tree.get(tree.get(animation, "transform") orelse continue, name) orelse continue;
            for (timeline.array.items) |*k| if (try tree.getFloat(k.*, key, 1) < 0) try (try edit.objectOf(k)).put(m.arena, key, .{ .integer = 0 });
        };
        if (crosses) try m.lose(.@"transform.localMix.approximated", where, "{s} keys cross zero, 3.6 skips the nonpositive part", .{key});
    }

    /// The target is a constrained bone or below one
    fn targetUnder(m: *Migration, doc: *ObjectMap, c: Value) Error!bool {
        _ = m;
        const bones = try tree.getArray(c, "bones");
        var at: ?[]const u8 = try tree.requireString(c, "target");
        while (at) |name| {
            for (bones) |b| if (b == .string and std.mem.eql(u8, b.string, name)) return true;
            at = for (try edit.arrayOf(doc, "bones")) |bone| {
                if (std.mem.eql(u8, try tree.requireString(bone, "name"), name)) break try tree.getString(bone, "parent");
            } else return error.Malformed;
        }
        return false;
    }

    /// Reports semantics that differ in both directions
    fn check(m: *Migration, doc: *ObjectMap) Error!void {
        if (!m.local_old) try m.localShear(doc, "3.6 adds absolute local shear to the local pose instead of the applied pose");
        for (try edit.arrayOf(doc, "path")) |*c| {
            try m.checkPath(doc, c);
            _ = edit.take(try edit.objectOf(c), marks.spacing_unscaled);
        }
    }

    fn localShear(m: *Migration, doc: *ObjectMap, message: []const u8) Error!void {
        for (try edit.arrayOf(doc, "transform")) |c| {
            if (!try tree.getBool(c, "local", false) or try tree.getBool(c, "relative", false)) continue;
            const name = try tree.requireString(c, "name");
            var shear = try tree.getFloat(c, "shearMix", 1) > 0;
            for (try m.constraintKeys("transform", name, null)) |k| shear = shear or try tree.getFloat(k, "shearMix", 1) > 0;
            if (shear) try m.lose(.@"transform.localShear.approximated", try m.pathOf("transform", name), "{s}", .{message});
        }
    }

    fn negativeMix(m: *Migration, c: Value, message: []const u8) Error!void {
        const name = try tree.requireString(c, "name");
        var negative = false;
        for (local_mixes) |key| {
            negative = negative or try tree.getFloat(c, key, 1) < 0;
            for (try m.constraintKeys("transform", name, null)) |k| negative = negative or try tree.getFloat(k, key, 1) < 0;
        }
        if (negative) try m.lose(.@"transform.localMix.approximated", try m.pathOf("transform", name), "{s}", .{message});
    }

    /// noScale bones under a parent with negative setup or keyed scale
    fn reflection(m: *Migration, doc: *ObjectMap, message: []const u8, rewrite: bool) Error!void {
        var bones: std.StringHashMapUnmanaged(Value) = .empty;
        for (try edit.arrayOf(doc, "bones")) |bone| try bones.put(m.arena, try tree.requireString(bone, "name"), bone);
        for (try edit.arrayOf(doc, "bones")) |*entry| {
            const bone = entry.*;
            if (!std.mem.eql(u8, try tree.getString(bone, "transform") orelse "normal", "noScale")) continue;
            // old noScale is the final noScaleOrReflection
            if (rewrite) try entry.object.put(m.arena, "transform", .{ .string = "noScaleOrReflection" });
            var at = bones.get(try tree.getString(bone, "parent") orelse continue);
            const reflected = while (at) |b| : (at = bones.get(try tree.getString(b, "parent") orelse break false)) {
                const name = try tree.requireString(b, "name");
                if (try tree.getFloat(b, "scaleX", 1) < 0 or try tree.getFloat(b, "scaleY", 1) < 0) break true;
                const keys = for (try m.constraintKeys("bones", name, "scale")) |k| {
                    if (try tree.getFloat(k, "x", 1) < 0 or try tree.getFloat(k, "y", 1) < 0) break true;
                } else false;
                if (keys) break true;
            } else false;
            const where = try m.pathOf("bones", try tree.requireString(bone, "name"));
            if (!reflected) {} else if (rewrite)
                try m.lose(.@"bone.reflection.rewritten", where, "old noScale became noScaleOrReflection", .{})
            else
                try m.lose(.@"bone.reflection.approximated", where, "{s}", .{message});
        }
    }

    /// Path on its start or turned by curve tangents
    fn startsOnCurve(m: *Migration, c: Value) Error!bool {
        if (std.mem.eql(u8, try tree.getString(c, "rotateMode") orelse "tangent", "tangent")) return true;
        const fixed = std.mem.eql(u8, try tree.getString(c, "positionMode") orelse "percent", "fixed");
        if (onStart(try tree.getFloat(c, "position", 0), fixed)) return true;
        for (try m.constraintKeys("path", try tree.requireString(c, "name"), "position")) |k| {
            if (onStart(try tree.getFloat(k, "position", 0), fixed)) return true;
        }
        return false;
    }

    fn checkPath(m: *Migration, doc: *ObjectMap, entry: *Value) Error!void {
        const c = entry.*;
        const name = try tree.requireString(c, "name");
        const where = try m.pathOf("path", name);
        const fixed_position = std.mem.eql(u8, try tree.getString(c, "positionMode") orelse "percent", "fixed");
        const spacing_mode = try tree.getString(c, "spacingMode") orelse "length";
        const rotate_mode = try tree.getString(c, "rotateMode") orelse "tangent";
        const chain_scale = std.mem.eql(u8, rotate_mode, "chainScale");

        const setup = try tree.getFloat(c, "position", 0);
        var start = onStart(setup, fixed_position);
        var position = setup != 0;
        for (try m.constraintKeys("path", name, "position")) |k| {
            const p = try tree.getFloat(k, "position", 0);
            start = start or onStart(p, fixed_position);
            position = position or p != 0;
        }
        if ((start or std.mem.eql(u8, rotate_mode, "tangent")) and !m.start_old) {
            try m.lose(.@"path.start.approximated", where, "3.6 evaluates curves at 1e-5 or more and takes tangents near a curve start from the curve", .{});
        }

        var spacing = try tree.getFloat(c, "spacing", 0) != 0;
        for (try m.constraintKeys("path", name, "spacing")) |k| spacing = spacing or try tree.getFloat(k, "spacing", 0) != 0;
        const fixed = std.mem.eql(u8, spacing_mode, "fixed") and !chain_scale;
        const percent = std.mem.eql(u8, spacing_mode, "percent") and chain_scale and tree.get(c, marks.spacing_unscaled) == null;
        if (spacing and (fixed or percent)) {
            // 3.7 scales fixed spacing and 3.6 chain scale percent spacing by the bone world scale
            const k = try spaces.constant(m.arena, doc, c);
            if (k == null or (fixed and try spaces.shortest(doc, c) < spaces.epsilon)) {
                try m.lose(.@"path.spacingScale.approximated", where, "spacing scaled by the bone world scale in only one version", .{});
            } else if (k.? != 1) {
                if (m.rewrite) {
                    try spaces.scaleSpacing(m.arena, doc, entry, if (fixed != m.down) 1 / k.? else k.?);
                    try m.lose(.@"path.spacingScale.rewritten", where, "spacing scaled by the constant bone world scale", .{});
                } else try m.lose(.@"path.spacingScale.approximated", where, "spacing scaled by the bone world scale in only one version", .{});
            }
        }

        if (!fixed_position or !position or tree.get(c, marks.position_unscaled) != null) return;
        const slot = try tree.requireString(c, "target");
        const skins = try edit.childOf(doc, "skins") orelse return;
        for (skins.values()) |skin| {
            const attachments = tree.get(skin, slot) orelse continue;
            if (attachments != .object) return error.Malformed;
            for (attachments.object.values()) |a| {
                if (!std.mem.eql(u8, try tree.getString(a, "type") orelse "region", "path")) continue;
                if (!try tree.getBool(a, "constantSpeed", true)) continue;
                return m.lose(.@"path.position.approximated", where, "3.7 scales a fixed position by the world path length", .{});
            }
        }
    }

    /// 3.7 fixed mesh UVs of stripped regions
    fn stripped(m: *Migration, doc: *ObjectMap) Error!void {
        const skins = try edit.childOf(doc, "skins") orelse return;
        var it = skins.iterator();
        while (it.next()) |skin| {
            if (skin.value_ptr.* != .object) return error.Malformed;
            var slots = skin.value_ptr.object.iterator();
            while (slots.next()) |slot| {
                if (slot.value_ptr.* != .object) return error.Malformed;
                var attachments = slot.value_ptr.object.iterator();
                while (attachments.next()) |a| {
                    const kind = try tree.getString(a.value_ptr.*, "type") orelse "region";
                    const mesh = std.mem.eql(u8, kind, "mesh");
                    if (!mesh and !std.mem.eql(u8, kind, "linkedmesh")) continue;
                    const where = try std.fmt.allocPrint(m.arena, "skins.{s}.{s}.{s}", .{ skin.key_ptr.*, slot.key_ptr.*, a.key_ptr.* });
                    const own = m.regionOf(a.value_ptr.*, a.key_ptr.*) catch |e| switch (e) {
                        error.Missing => {
                            try m.lose(.@"atlas.strip.approximated", where, "3.7 maps mesh UVs into stripped whitespace", .{});
                            continue;
                        },
                        else => |other| return other,
                    };
                    if (mesh) {
                        if (!atlas.isStripped(own)) continue;
                        if (own.degrees != 0 or own.original_width <= 0 or own.original_height <= 0 or !m.rewrite) {
                            try m.lose(.@"atlas.strip.approximated", where, "3.7 maps mesh UVs into stripped whitespace", .{});
                            continue;
                        }
                        try unstrip(try edit.childValue(try edit.objectOf(a.value_ptr), "uvs") orelse return error.Malformed, own);
                        try m.lose(.@"atlas.strip.rewritten", where, "mesh UVs mapped through the stripped whitespace of the region", .{});
                        continue;
                    }
                    const parent = try m.parentRegion(skins, a.value_ptr.*, slot.key_ptr.*);
                    const same = if (parent) |p| sameStrip(own, p) else false;
                    if (!atlas.isStripped(own) and (parent == null or !atlas.isStripped(parent.?))) continue;
                    if (!same) {
                        try m.lose(.@"atlas.strip.approximated", where, "3.7 maps the UVs of the parent mesh into this region's whitespace", .{});
                    }
                }
            }
        }
    }

    /// Atlas region of an attachment, missing without an atlas
    fn regionOf(m: *Migration, a: Value, key: []const u8) (Error || error{Missing})!atlas.Region {
        const regions = m.regions orelse return error.Missing;
        return regions.get(try tree.getString(a, "path") orelse key) orelse error.Missing;
    }

    /// Region of the parent mesh a linked mesh reuses UVs of
    fn parentRegion(m: *Migration, skins: *ObjectMap, a: Value, slot: []const u8) Error!?atlas.Region {
        const name = try tree.getString(a, "parent") orelse return error.Malformed;
        const skin = skins.get(try tree.getString(a, "skin") orelse "default") orelse return null;
        const attachments = tree.get(skin, slot) orelse return null;
        const parent = tree.get(attachments, name) orelse return null;
        return m.regionOf(parent, name) catch |e| switch (e) {
            error.Missing => null,
            else => |other| other,
        };
    }

    /// Both regions map region UVs alike when unrotated
    fn sameStrip(a: atlas.Region, b: atlas.Region) bool {
        return a.degrees == 0 and b.degrees == 0 and a.width == b.width and a.height == b.height and a.offset_x == b.offset_x and
            a.offset_y == b.offset_y and a.original_width == b.original_width and a.original_height == b.original_height;
    }

    /// Region UVs of the packed size to the original size
    fn unstrip(uvs: *Value, r: atlas.Region) Error!void {
        if (uvs.* != .array) return error.Malformed;
        const list = uvs.array.items;
        if (list.len % 2 != 0) return error.Malformed;
        const w: f64 = @floatFromInt(r.width);
        const h: f64 = @floatFromInt(r.height);
        const ow: f64 = @floatFromInt(r.original_width);
        const oh: f64 = @floatFromInt(r.original_height);
        const ox: f64 = @floatFromInt(r.offset_x);
        const oy: f64 = @floatFromInt(r.offset_y);
        var i: usize = 0;
        while (i < list.len) : (i += 2) {
            // read before the union write
            const u: f64 = try tree.number(list[i]);
            const v: f64 = try tree.number(list[i + 1]);
            list[i] = .{ .float = (u * w + ox) / ow };
            list[i + 1] = .{ .float = (v * h + oh - oy - h) / oh };
        }
    }

    fn downIk(m: *Migration, c: *ObjectMap) Error!void {
        const name = try tree.requireString(.{ .object = c.* }, "name");
        const one = (try tree.getArray(.{ .object = c.* }, "bones")).len == 1;
        var compress = try edit.takeBool(c, "compress");
        var stretch = try edit.takeBool(c, "stretch");
        _ = edit.take(c, "uniform");
        const animations = m.animations orelse return m.loseIk(name, one and compress, stretch);
        for (animations.values()) |animation| {
            const timeline = tree.get(tree.get(animation, "ik") orelse continue, name) orelse continue;
            if (timeline != .array) return error.Malformed;
            for (timeline.array.items) |*k| {
                const map = try edit.objectOf(k);
                compress = try edit.takeBool(map, "compress") or compress;
                stretch = try edit.takeBool(map, "stretch") or stretch;
            }
        }
        try m.loseIk(name, one and compress, stretch);
    }

    fn loseIk(m: *Migration, name: []const u8, compress: bool, stretch: bool) Error!void {
        const where = try m.pathOf("ik", name);
        if (compress) try m.lose(.@"ik.compress.dropped", where, "3.6 IK does not compress", .{});
        if (stretch) try m.lose(.@"ik.stretch.dropped", where, "3.6 IK does not stretch", .{});
    }

    /// Keys of one constraint in all animations
    fn constraintKeys(m: *Migration, kind: []const u8, name: []const u8, sub: ?[]const u8) Error![]const Value {
        var out: std.ArrayList(Value) = .empty;
        const animations = m.animations orelse return &.{};
        const group = if (std.mem.eql(u8, kind, "path")) "paths" else kind;
        for (animations.values()) |animation| {
            var timeline = tree.get(tree.get(animation, group) orelse continue, name) orelse continue;
            if (sub) |s| timeline = tree.get(timeline, s) orelse continue;
            if (timeline != .array) return error.Malformed;
            try out.appendSlice(m.arena, timeline.array.items);
        }
        return out.items;
    }

    fn pathOf(m: *Migration, list: []const u8, name: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(m.arena, "{s}.{s}", .{ list, name });
    }

    fn lose(m: *Migration, code: Report.Code, path: []const u8, comptime fmt: []const u8, args: anytype) Error!void {
        try m.report.add(.{
            .code = code,
            .step = m.step,
            .path = path,
            .message = try std.fmt.allocPrint(m.arena, fmt, args),
        });
    }
};

/// Whole percents and fixed 0 sit on the path start
fn onStart(position: f32, fixed: bool) bool {
    return if (fixed) position == 0 else position == @floor(position);
}

/// Interpolated mixes may reach both signs
fn crossing(a: f32, b: f32, curve: ?Value) Error!bool {
    var low = @min(a, b);
    var high = @max(a, b);
    if (curve) |c| {
        if (c == .string and std.mem.eql(u8, c.string, "stepped")) return false;
        if (c == .array) {
            if (c.array.items.len != 4) return error.Malformed;
            for ([_]usize{ 1, 3 }) |i| {
                const h = a + (b - a) * try tree.number(c.array.items[i]);
                low = @min(low, h);
                high = @max(high, h);
            }
        }
    }
    return low < 0 and high > 0;
}

const Run = struct { root: Value, report: Report };

fn testRun(a: std.mem.Allocator, input: []const u8, upward: bool) !Run {
    var report: Report = .{ .arena = a };
    var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
    if (upward) try up(a, &root, &report, .{}) else try down(a, &root, &report, .{});
    return .{ .root = root, .report = report };
}

fn expectCodes(report: Report, codes: []const Report.Code) !void {
    try std.testing.expectEqual(codes.len, report.entries.items.len);
    for (codes, report.entries.items) |code, e| try std.testing.expectEqual(code, e.code);
}

test "up clamps negative local mixes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exact = try testRun(a,
        \\{"transform":[{"name":"t","local":true,"relative":true,"scaleMix":-0.5,"shearMix":-1}],
        \\"animations":{"a":{"transform":{"t":[{"time":0,"scaleMix":-1,"shearMix":-1},{"time":1,"scaleMix":0,"shearMix":-0.5}]}}}}
    , true);
    try expectCodes(exact.report, &.{});
    const c = exact.root.object.get("transform").?.array.items[0];
    try std.testing.expectEqual(0, try tree.getFloat(c, "scaleMix", 1));
    try std.testing.expectEqual(0, try tree.getFloat(c, "shearMix", 1));
    const keys = exact.root.object.get("animations").?.object.get("a").?.object.get("transform").?.object.get("t").?.array.items;
    for (keys) |k| try std.testing.expectEqual(0, try tree.getFloat(k, "shearMix", 1));

    const crossing_keys = try testRun(a,
        \\{"transform":[{"name":"t","local":true,"relative":true}],
        \\"animations":{"a":{"transform":{"t":[{"time":0,"scaleMix":-1,"shearMix":0},{"time":1,"scaleMix":1,"shearMix":0}]}}}}
    , true);
    try expectCodes(crossing_keys.report, &.{.@"transform.localMix.approximated"});

    const overshoot = try testRun(a,
        \\{"transform":[{"name":"t","local":true,"relative":true,"scaleMix":0}],
        \\"animations":{"a":{"transform":{"t":[{"time":0,"scaleMix":-1,"shearMix":0,"curve":[0.2,1.4,0.8,1]},{"time":1,"scaleMix":0,"shearMix":0}]}}}}
    , true);
    try expectCodes(overshoot.report, &.{.@"transform.localMix.approximated"});

    const world = try testRun(a,
        \\{"transform":[{"name":"t","scaleMix":-1}]}
    , true);
    try expectCodes(world.report, &.{});
    try std.testing.expectEqual(-1, try tree.getFloat(world.root.object.get("transform").?.array.items[0], "scaleMix", 1));
}

test "down reports negative local mixes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try testRun(arena.allocator(),
        \\{"transform":[{"name":"t","local":true,"relative":true}],
        \\"animations":{"a":{"transform":{"t":[{"time":0,"shearMix":-1}]}}}}
    , false);
    try expectCodes(r.report, &.{.@"transform.localMix.approximated"});
}

test "absolute local shear" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"transform":[{"name":"t","local":true,"shearMix":0},{"name":"r","local":true,"relative":true},{"name":"w"}],
        \\"animations":{"a":{"transform":{"t":[{"time":0,"shearMix":0.5}]}}}}
    ;
    try expectCodes((try testRun(a, input, true)).report, &.{.@"transform.localShear.approximated"});
    try expectCodes((try testRun(a, input, false)).report, &.{.@"transform.localShear.approximated"});
    try expectCodes((try testRun(a,
        \\{"transform":[{"name":"t","local":true,"shearMix":0}]}
    , true)).report, &.{});
}

test "path semantics" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skins =
        \\"skins":{"default":{"p":{"p":{"type":"path","lengths":[1],"vertexCount":6,"vertices":[0,0,0,0,0,0]}}}},
        \\"bones":[{"name":"root"},{"name":"b","parent":"root","scaleX":2}]
    ;
    const fixed_spacing = try std.fmt.allocPrint(a,
        \\{{"path":[{{"name":"c","bones":["b"],"target":"p","rotateMode":"chain","position":0.5,"spacingMode":"fixed","spacing":2}}],{s}}}
    , .{skins});
    try expectCodes((try testRun(a, fixed_spacing, true)).report, &.{.@"path.spacingScale.approximated"});
    try expectCodes((try testRun(a, fixed_spacing, false)).report, &.{.@"path.spacingScale.approximated"});

    const percent_scale = try std.fmt.allocPrint(a,
        \\{{"path":[{{"name":"c","bones":["b"],"target":"p","rotateMode":"chainScale","position":0.5,"spacingMode":"percent"}}],
        \\"animations":{{"a":{{"paths":{{"c":{{"spacing":[{{"time":0,"spacing":0.1}}]}}}}}}}},{s}}}
    , .{skins});
    try expectCodes((try testRun(a, percent_scale, true)).report, &.{.@"path.spacingScale.approximated"});

    const unchanged = try std.fmt.allocPrint(a,
        \\{{"path":[{{"name":"c","target":"p","rotateMode":"chainScale","position":0.5,"spacing":3}}],{s}}}
    , .{skins});
    try expectCodes((try testRun(a, unchanged, true)).report, &.{});

    const start = try std.fmt.allocPrint(a,
        \\{{"path":[{{"name":"c","target":"p","rotateMode":"chain","position":0.5}}],
        \\"animations":{{"a":{{"paths":{{"c":{{"position":[{{"time":0}}]}}}}}}}},{s}}}
    , .{skins});
    try expectCodes((try testRun(a, start, true)).report, &.{.@"path.start.approximated"});
    const tangent = try std.fmt.allocPrint(a,
        \\{{"path":[{{"name":"c","target":"p","position":0.5}}],{s}}}
    , .{skins});
    try expectCodes((try testRun(a, tangent, false)).report, &.{.@"path.start.approximated"});

    const fixed_position = try std.fmt.allocPrint(a,
        \\{{"path":[{{"name":"c","target":"p","rotateMode":"chain","positionMode":"fixed","position":5}}],{s}}}
    , .{skins});
    try expectCodes((try testRun(a, fixed_position, true)).report, &.{.@"path.position.approximated"});
    const uneven = try std.fmt.allocPrint(a,
        \\{{"path":[{{"name":"c","target":"p","rotateMode":"chain","positionMode":"fixed","position":5}}],
        \\"skins":{{"default":{{"p":{{"p":{{"type":"path","constantSpeed":false,"lengths":[1],"vertexCount":6,"vertices":[0,0,0,0,0,0]}}}}}}}}}}
    , .{});
    try expectCodes((try testRun(a, uneven, true)).report, &.{});
}

test "down drops IK compress and stretch" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try testRun(arena.allocator(),
        \\{"ik":[{"name":"one","bones":["a"],"target":"t","compress":true,"uniform":true},
        \\{"name":"two","bones":["a","b"],"target":"t","compress":true}],
        \\"animations":{"a":{"ik":{"two":[{"time":0,"stretch":true,"compress":true}]}}}}
    , false);
    try expectCodes(r.report, &.{ .@"ik.compress.dropped", .@"ik.stretch.dropped" });
    for (r.root.object.get("ik").?.array.items) |c| {
        for ([_][]const u8{ "compress", "stretch", "uniform" }) |key| try std.testing.expect(c.object.get(key) == null);
    }
    const key = r.root.object.get("animations").?.object.get("a").?.object.get("ik").?.object.get("two").?.array.items[0];
    try std.testing.expect(key.object.get("stretch") == null and key.object.get("compress") == null);
}

test "down drops audio" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try testRun(arena.allocator(),
        \\{"skeleton":{"spine":"3.7.94","audio":"./audio"},
        \\"events":{"step":{"audio":"step.ogg","volume":0.5,"balance":1},"hit":{"int":1}},
        \\"animations":{"a":{"events":[{"time":0,"name":"step","volume":0.2,"balance":-1}]}}}
    , false);
    try expectCodes(r.report, &.{ .@"skeleton.audio.dropped", .@"event.audio.dropped" });
    try std.testing.expect(r.root.object.get("skeleton").?.object.get("audio") == null);
    const step = r.root.object.get("events").?.object.get("step").?;
    try std.testing.expectEqual(0, step.object.count());
    const key = r.root.object.get("animations").?.object.get("a").?.object.get("events").?.array.items[0];
    try std.testing.expectEqual(2, key.object.count());
}

test "up and down keep plain data" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"skeleton":{"spine":"3.6.53"},"bones":[{"name":"root"}],"ik":[{"name":"i","bones":["root"],"target":"root"}],
        \\"transform":[{"name":"t","bones":["root"],"target":"root","scaleMix":0.5}],"events":{"e":{"int":2}}}
    ;
    try expectCodes((try testRun(a, input, true)).report, &.{});
    try expectCodes((try testRun(a, input, false)).report, &.{});
}

test "meshes going up report stripped whitespace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Report = .{ .arena = a };
    var root = try std.json.parseFromSliceLeaky(Value, a,
        \\{"skins":{"default":{"s":{"r":{},"m":{"type":"mesh","uvs":[],"triangles":[],"vertices":[],"hull":0},"l":{"type":"linkedmesh","parent":"m"}}}}}
    , .{});
    try up(a, &root, &report, .{});
    try std.testing.expectEqual(2, report.entries.items.len);
    try std.testing.expectEqualStrings("skins.default.s.m", report.entries.items[0].path);
    try std.testing.expectEqual(Report.Impact.render, report.maxImpact());
    report = .{ .arena = a };
    try down(a, &root, &report, .{});
    try std.testing.expectEqual(0, report.entries.items.len);
}

const early_body =
    \\"bones":[{"name":"root"},{"name":"flip","parent":"root","scaleY":-1},{"name":"n","parent":"flip","transform":"noScale"}],
    \\"transform":[{"name":"t","bones":["n"],"target":"root","local":true,"relative":true,"scaleMix":-0.5,"shearMix":-1},
    \\{"name":"s","bones":["n"],"target":"root","local":true,"shearMix":0.5}],
    \\"path":[{"name":"p","bones":["n"],"target":"x","rotateMode":"chain","position":0.5},{"name":"q","bones":["n"],"target":"x","position":0.5}]
;

fn versioned(a: std.mem.Allocator, version: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"{s}\"}},{s}}}", .{ version, early_body }), .{});
}

test "early 3.7 exports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, Flags, []const Report.Code, f32 };
    for ([_]Case{
        .{ "3.7.29-beta", .{}, &.{ .@"bone.reflection.approximated", .@"transform.localShear.approximated", .@"path.start.approximated" }, 0 },
        .{ "3.7", .{}, &.{ .@"bone.reflection.approximated", .@"transform.localMix.approximated", .@"transform.localShear.approximated", .@"path.start.approximated" }, -0.5 },
        .{ "3.7.73-beta", .{}, &.{.@"transform.localShear.approximated"}, 0 },
        .{ "3.7.90", .{}, &.{}, -0.5 },
    }) |case| {
        var root = try versioned(a, case[0]);
        var report: Report = .{ .arena = a };
        try early(a, &root, &report, .{ .major = 3, .minor = 7 }, case[1]);
        try expectCodes(report, case[2]);
        try std.testing.expectEqual(case[3], try tree.getFloat(root.object.get("transform").?.array.items[0], "scaleMix", 1));
    }
}

test "down skips what old 3.7 editors pose like 3.6" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, []const Report.Code };
    for ([_]Case{
        .{ "3.7.29-beta", &.{.@"bone.reflection.approximated"} },
        .{ "3.7.90", &.{ .@"transform.localMix.approximated", .@"transform.localShear.approximated", .@"path.start.approximated" } },
    }) |case| {
        var root = try versioned(a, case[0]);
        var report: Report = .{ .arena = a };
        try down(a, &root, &report, .{});
        try expectCodes(report, case[1]);
    }
}

test "spacing on bones of one constant world scale" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"bones":[{"name":"root","scaleX":-2,"scaleY":2},{"name":"b","parent":"root","rotation":30,"length":LENGTH}],
        \\"path":[{"name":"c","bones":["b"],"target":"p","rotateMode":"chain","position":0.5,"spacingMode":"fixed","spacing":2}],
        \\"animations":{"a":{"paths":{"c":{"spacing":[{"time":0,"spacing":6}]}}}},
        \\"skins":{"default":{"p":{"p":{"type":"path","lengths":[1],"vertexCount":6,"vertices":[0,0,0,0,0,0]}}}}}
    ;
    const long = try std.mem.replaceOwned(u8, a, input, "LENGTH", "10");
    var r = try testRun(a, long, true);
    try expectCodes(r.report, &.{.@"path.spacingScale.approximated"});
    var report: Report = .{ .arena = a };
    var root = try std.json.parseFromSliceLeaky(Value, a, long, .{});
    try up(a, &root, &report, .{ .rewrite = true });
    try expectCodes(report, &.{.@"path.spacingScale.rewritten"});
    const c = (try edit.arrayOf(&root.object, "path"))[0];
    try std.testing.expectEqual(1, try tree.getFloat(c, "spacing", 0));
    try down(a, &root, &report, .{ .rewrite = true });
    try std.testing.expectEqual(2, try tree.getFloat((try edit.arrayOf(&root.object, "path"))[0], "spacing", 0));
    r = try testRun(a, try std.mem.replaceOwned(u8, a, input, "LENGTH", "0"), true);
    try expectCodes(r.report, &.{.@"path.spacingScale.approximated"});
}

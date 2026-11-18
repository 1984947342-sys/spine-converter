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

//! Spine 3.8 and 4.0 JSON, mapped by SkeletonJson.java of both branches

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Report = @import("../Report.zig");
const Version = @import("../Version.zig");
const Flags = @import("../Document.zig").Flags;
const tree = @import("../binary/tree.zig");
const edit = @import("../edit.zig");
const singular = @import("singular.zig");
const order = @import("order.zig");
const marks = @import("marks.zig");

pub const Error = error{ Malformed, OutOfMemory };

const reason_3_8 = "3.8 and 4.0 interpolate scale keys differently";

const transform_old = [_][]const u8{ "rotateMix", "translateMix", "scaleMix", "shearMix" };
const transform_new = [_][]const u8{ "mixRotate", "mixX", "mixScaleX", "mixShearY" };
const transform_all = [_][]const u8{ "mixRotate", "mixX", "mixY", "mixScaleX", "mixScaleY", "mixShearY" };
const path_old = [_][]const u8{ "rotateMix", "translateMix" };
const path_new = [_][]const u8{ "mixRotate", "mixX" };
const pairs = [_][]const u8{ "translate", "scale", "shear" };
const pair_defaults = [_]f32{ 0, 1, 0 };

/// A mix key and its 4.0 Bezier channel
const Mix = struct { name: []const u8, channel: usize = 0, like: ?[]const u8 = null };

const scale_old = [_]Mix{.{ .name = "scaleMix" }};
const scale_new = [_]Mix{ .{ .name = "mixScaleX", .channel = 3 }, .{ .name = "mixScaleY", .channel = 4, .like = "mixScaleX" } };
const path_mix_old = [_]Mix{ .{ .name = "rotateMix" }, .{ .name = "translateMix" } };
const path_mix_new = [_]Mix{ .{ .name = "mixRotate" }, .{ .name = "mixX", .channel = 1 }, .{ .name = "mixY", .channel = 2, .like = "mixX" } };

/// Constraint keys whose meaning differs between the runtimes
const Names = struct {
    scale: []const Mix,
    path_mix: []const Mix,
    rotate_mix: []const u8,
    angle: []const u8,
    spacing: []const u8,
    down: bool,
};

const names_old: Names = .{ .scale = &scale_old, .path_mix = &path_mix_old, .rotate_mix = "rotateMix", .angle = "angle", .spacing = "spacing", .down = false };
const names_new: Names = .{ .scale = &scale_new, .path_mix = &path_mix_new, .rotate_mix = "mixRotate", .angle = "value", .spacing = "value", .down = true };

pub fn early(arena: std.mem.Allocator, root: *Value, report: *Report, target: Version.Minor, flags: Flags) Error!void {
    const rig = flags.rewrite and target.major == 4 and target.minor >= 3;
    const version = Version.ofRoot(root.*) orelse return;
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.0", .version = version };
    const doc = try edit.objectOf(root);
    try m.index(doc);
    const reset = m.editor(.order_40);
    if (reset != .new) try m.rewriteOrder(doc, reset == .old and flags.rewrite, rig, "4.0 exports before 4.0.76-beta");
    const stretch = m.editor(.stretch_40);
    for (try edit.arrayOf(doc, "ik")) |*c| {
        if ((try tree.getArray(c.*, "bones")).len != 2) continue;
        if (stretch != .new and try m.stretched(c.*) and try m.childMoves(c.*)) {
            const where = try m.path("ik", &c.object);
            if (stretch == .old and rig and try m.stretchRig(doc, c.*)) {
                try c.object.put(arena, marks.stretch_offset, .{ .bool = true });
                try m.lose(.@"ik.stretch.rewritten", where, "child Y position kept by a 4.3 helper parent turned toward the child", .{});
            } else try m.lose(.@"ik.stretch.approximated", where, "4.0 exports before 4.0.73-beta keep the child Y position", .{});
        }
        // betas before 4.0.73-beta ignore two bone uniform
        if (stretch == .old) _ = edit.take(try edit.objectOf(c), "uniform");
    }
    if (m.editor(.relative_scale_40) != .new) try m.checkRelativeScale(doc, "4.0 exports before 4.0.27 scale relative local transforms by another formula", rig and m.editor(.relative_scale_40) == .old);
    if (m.editor(.zero_bone_40) != .new) for (try edit.arrayOf(doc, "path")) |c| {
        if (try m.zeroSpacing(c, "value")) try m.lose(.@"path.spacing.approximated", try m.path("path", &c.object), "4.0 exports before 4.0.34-beta space zero length bones by 0", .{});
    };
}

pub fn up(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "3.8-4.0", .rewrite = flags.rewrite, .slider = flags.slider };
    const doc = try edit.objectOf(root);
    try m.index(doc);
    try m.check(doc, names_old);
    try singular.check(arena, doc, report, m.step, reason_3_8);
    if (try edit.childOf(doc, "skeleton")) |skeleton| if (edit.take(skeleton, "hash")) |hash| {
        if (hash != .string) return error.Malformed;
        // 4.0 hashes hold eight bytes
        const bytes = tree.hashBytes(hash.string);
        if (!std.mem.allEqual(u8, &bytes, 0)) {
            const encoder = std.base64.standard_no_pad.Encoder;
            const text = try arena.alloc(u8, encoder.calcSize(bytes.len));
            try skeleton.put(arena, "hash", .{ .string = encoder.encode(text, &bytes) });
        }
    };
    for (try edit.arrayOf(doc, "ik")) |*c| {
        const map = try edit.objectOf(c);
        // 3.8 ignores uniform for two bones
        if ((try tree.getArray(c.*, "bones")).len == 2) _ = edit.take(map, "uniform");
    }
    for (try edit.arrayOf(doc, "transform")) |*c| try m.renameAll(try edit.objectOf(c), &transform_old, &transform_new);
    for (try edit.arrayOf(doc, "path")) |*c| {
        const map = try edit.objectOf(c);
        try m.renameAll(map, &path_old, &path_new);
        if (map.get("mixX")) |x| if (try tree.number(x) != 1) try map.put(arena, "mixY", x);
    }
    const animations = try edit.childOf(doc, "animations") orelse return;
    var it = animations.iterator();
    while (it.next()) |animation| try m.upAnimation(try edit.objectOf(animation.value_ptr));
}

/// 4.0 JSON loaders reuse the first shear mix
pub fn jsonShear(arena: std.mem.Allocator, root: *Value, report: *Report) Error!void {
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.0" };
    try m.index(try edit.objectOf(root));
    try m.checkJsonShear();
}

pub fn down(arena: std.mem.Allocator, root: *Value, report: *Report, flags: Flags) Error!void {
    _ = flags;
    var m: Migration = .{ .arena = arena, .report = report, .step = "4.0-3.8", .version = Version.ofRoot(root.*) };
    const doc = try edit.objectOf(root);
    try m.index(doc);
    try m.check(doc, names_new);
    if (m.editor(.relative_scale_40) != .new) try m.checkRelativeScale(doc, "3.8 scales relative local transforms by another formula", false);
    try singular.check(arena, doc, report, m.step, reason_3_8);
    for (try edit.arrayOf(doc, "transform")) |*c| {
        const map = try edit.objectOf(c);
        const x = try edit.float(map, "mixX", 1);
        const scale_x = try edit.float(map, "mixScaleX", 1);
        const y = edit.take(map, "mixY");
        const scale_y = edit.take(map, "mixScaleY");
        if (y != null and try tree.number(y.?) != x or scale_y != null and try tree.number(scale_y.?) != scale_x) {
            try m.lose(.@"transform.mix.approximated", try m.path("transform", map), "Y mixes differ from X mixes", .{});
        }
        try m.renameAll(map, &transform_new, &transform_old);
    }
    for (try edit.arrayOf(doc, "path")) |*c| {
        const map = try edit.objectOf(c);
        const x = try edit.float(map, "mixX", 1);
        const y = edit.take(map, "mixY");
        if (y != null and try tree.number(y.?) != x) {
            try m.lose(.@"path.mix.approximated", try m.path("path", map), "mixY differs from mixX", .{});
        }
        try m.renameAll(map, &path_new, &path_old);
    }
    for (try edit.arrayOf(doc, "skins")) |*skin| {
        const map = try edit.objectOf(skin);
        // 3.8 spine-cpp crashes on a skin without attachments
        if (try edit.childValue(map, "attachments") == null) try map.put(arena, "attachments", .{ .object = .empty });
    }
    const animations = try edit.childOf(doc, "animations") orelse return;
    var it = animations.iterator();
    while (it.next()) |animation| try m.downAnimation(animation.key_ptr.*, try edit.objectOf(animation.value_ptr));
}

/// Key values in 4.0 Bezier channel order
const Shape = union(enum) {
    value: f32,
    rotate,
    pair: f32,
    rgba,
    rgb,
    rgba2,
    rgb2,
    ik,
    transform,
    path_mix,
    deform,

    fn channels(s: Shape) usize {
        return switch (s) {
            .value, .rotate, .deform => 1,
            .pair, .ik => 2,
            .rgb, .path_mix => 3,
            .rgba => 4,
            .rgb2, .transform => 6,
            .rgba2 => 7,
        };
    }
};

fn readValues(key: Value, shape: Shape, out: []f64) Error!void {
    switch (shape) {
        .value => |d| out[0] = try finite(key, "value", d),
        .rotate => out[0] = try finite(key, "value", 0),
        .pair => |d| {
            out[0] = try finite(key, "x", d);
            out[1] = try finite(key, "y", d);
        },
        .rgba => try readColor(try tree.requireString(key, "color"), out[0..4]),
        .rgb => try readColor(try tree.requireString(key, "color"), out[0..3]),
        .rgba2 => {
            try readColor(try tree.requireString(key, "light"), out[0..4]);
            try readColor(try tree.requireString(key, "dark"), out[4..7]);
        },
        .rgb2 => {
            try readColor(try tree.requireString(key, "light"), out[0..3]);
            try readColor(try tree.requireString(key, "dark"), out[3..6]);
        },
        .ik => {
            out[0] = try finite(key, "mix", 1);
            out[1] = try finite(key, "softness", 0);
        },
        .transform => {
            out[0] = try finite(key, "mixRotate", 1);
            out[1] = try finite(key, "mixX", 1);
            out[2] = try finite(key, "mixY", @floatCast(out[1]));
            out[3] = try finite(key, "mixScaleX", 1);
            out[4] = try finite(key, "mixScaleY", @floatCast(out[3]));
            out[5] = try finite(key, "mixShearY", 1);
        },
        .path_mix => {
            out[0] = try finite(key, "mixRotate", 1);
            out[1] = try finite(key, "mixX", 1);
            out[2] = try finite(key, "mixY", @floatCast(out[1]));
        },
        .deform => out[0] = 0,
    }
}

fn readColor(s: []const u8, out: []f64) Error!void {
    if (s.len < out.len * 2) return error.Malformed;
    for (out, 0..) |*v, i| {
        const byte = std.fmt.parseInt(u8, s[i * 2 ..][0..2], 16) catch return error.Malformed;
        v.* = @as(f64, @floatFromInt(byte)) / 255;
    }
}

fn hexOf(arena: std.mem.Allocator, values: []const f64) Error![]const u8 {
    var rgba: u32 = 0;
    for (values) |v| rgba = rgba << 8 | @as(u32, @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255)));
    return tree.hex(arena, rgba, 8);
}

fn finite(key: Value, name: []const u8, default: f32) Error!f64 {
    return finiteOf(try tree.getFloat(key, name, default));
}

fn finiteOf(v: f32) Error!f64 {
    return if (std.math.isFinite(v)) v else error.Malformed;
}

/// Matches the angle wrap of the 3.8 RotateTimeline
fn wrap(d: f32) f32 {
    const turns: f64 = 16384 - @trunc(16384.499999999996 - @as(f64, d / 360));
    return d - @as(f32, @floatCast(turns * 360));
}

const Curve = union(enum) {
    linear,
    stepped,
    bezier: [4]f64,
};

const Key = struct { time: f64, value: f64, curve: Curve };

/// One 4.0 timeline value like getBezierValue
const Channel = struct {
    keys: []const Key = &.{},
    /// Value before the first key
    default: f64 = 0,

    fn last(ch: Channel, t: f64, inclusive: bool) usize {
        var i = ch.keys.len - 1;
        while (i > 0 and (ch.keys[i].time > t or !inclusive and ch.keys[i].time == t)) i -= 1;
        return i;
    }

    fn at(ch: Channel, t: f64, left: bool) f64 {
        const keys = ch.keys;
        if (keys.len == 0 or t < keys[0].time or left and t == keys[0].time) return ch.default;
        const i = ch.last(t, !left);
        if (i + 1 == keys.len) return keys[i].value;
        if (left and t == keys[i + 1].time) return if (keys[i].curve == .stepped) keys[i].value else keys[i + 1].value;
        return segmentAt(keys[i], keys[i + 1], t);
    }

    /// The segment spanning u to w, null outside the keys
    fn span(ch: Channel, u: f64, w: f64) ?[2]Key {
        const keys = ch.keys;
        if (keys.len == 0 or w <= keys[0].time or u >= keys[keys.len - 1].time) return null;
        const i = ch.last(u, true);
        return .{ keys[i], keys[i + 1] };
    }

    fn shape(ch: Channel, u: f64, w: f64) Span {
        const s = ch.span(u, w) orelse return .flat;
        const a = s[0];
        const b = s[1];
        const whole = a.time == u and b.time == w;
        switch (a.curve) {
            .linear => return if (a.value == b.value) .flat else .linear,
            .stepped => return if (whole and a.value != b.value) .stepped else .flat,
            .bezier => |c| {
                if (a.value == b.value and c[1] == a.value and c[3] == a.value) return .flat;
                const dt = b.time - a.time;
                const dv = b.value - a.value;
                if (!whole or dv == 0) return .bake;
                return .{ .bezier = .{
                    .handles = .{ (c[0] - a.time) / dt, (c[1] - a.value) / dv, (c[2] - a.time) / dt, (c[3] - a.value) / dv },
                    .dt = dt,
                    .dv = @abs(dv),
                    .magnitude = @max(@abs(a.value), @abs(b.value), @abs(a.time), @abs(b.time)),
                } };
            },
        }
    }

    fn eql(a: Channel, b: Channel) bool {
        if (a.keys.len != b.keys.len) return false;
        for (a.keys, b.keys, 0..) |x, y, i| {
            if (x.value != y.value) return false;
            if (i + 1 == a.keys.len) continue;
            if (!std.meta.eql(x.curve, y.curve)) return false;
        }
        return true;
    }
};

fn samples(a: Key, b: Key, c: [4]f64) [9][2]f64 {
    var out: [9][2]f64 = undefined;
    for (&out, 1..) |*p, k| {
        const s: f64 = @as(f64, @floatFromInt(k)) / 10;
        const r = 1 - s;
        const w0 = r * r * r;
        const w1 = 3 * r * r * s;
        const w2 = 3 * r * s * s;
        const w3 = s * s * s;
        p.* = .{ w0 * a.time + w1 * c[0] + w2 * c[2] + w3 * b.time, w0 * a.value + w1 * c[1] + w2 * c[3] + w3 * b.value };
    }
    return out;
}

fn segmentAt(a: Key, b: Key, t: f64) f64 {
    switch (a.curve) {
        .linear => return a.value + (t - a.time) / (b.time - a.time) * (b.value - a.value),
        .stepped => return a.value,
        .bezier => |c| {
            const points = samples(a, b, c);
            var x = a.time;
            var y = a.value;
            for (points) |p| {
                if (p[0] >= t) return y + (t - x) / (p[0] - x) * (p[1] - y);
                x = p[0];
                y = p[1];
            }
            return y + (t - x) / (b.time - x) * (b.value - y);
        },
    }
}

const Bezier = struct {
    handles: [4]f64,
    dt: f64,
    dv: f64,
    magnitude: f64,

    /// Same curve as other up to f32 rounding
    fn matches(b: Bezier, other: Bezier) bool {
        const eps = 1e-6 * (1 + b.magnitude);
        return @abs(b.handles[0] - other.handles[0]) * b.dt <= eps and @abs(b.handles[2] - other.handles[2]) * b.dt <= eps and
            @abs(b.handles[1] - other.handles[1]) * b.dv <= eps and @abs(b.handles[3] - other.handles[3]) * b.dv <= eps;
    }
};

const Span = union(enum) {
    flat,
    linear,
    stepped,
    bezier: Bezier,
    bake,
};

/// A 3.8 key and its source key
const Out = struct { time: f64, values: []f64, curve: Curve, src: usize };

const Plan = struct {
    curve: Curve = .linear,
    bake: bool = false,
    /// Shared curve when only the channel curves disagree
    dominant: ?[4]f64 = null,
};

fn plan(channels: []const Channel, u: f64, w: f64, max_delta: f64) Plan {
    var linear = false;
    var stepped = false;
    var dominant: ?Bezier = null;
    for (channels) |ch| switch (ch.shape(u, w)) {
        .flat => {},
        .linear => linear = true,
        .stepped => stepped = true,
        .bake => return .{ .bake = true },
        .bezier => |b| if (dominant == null or b.dv > dominant.?.dv) {
            dominant = b;
        },
    };
    if (dominant) |d| {
        if (linear or d.dv >= max_delta) return .{ .bake = true };
        for (channels) |ch| switch (ch.shape(u, w)) {
            .bezier => |b| if (!b.matches(d)) return .{ .bake = true, .dominant = d.handles },
            else => {},
        };
        return .{ .curve = .{ .bezier = d.handles } };
    }
    if (linear) return .{};
    if (stepped) return .{ .curve = .stepped };
    return .{};
}

const Resampled = struct { keys: []Out, approximated: bool = false };

const Migration = struct {
    arena: std.mem.Allocator,
    report: *Report,
    step: []const u8,
    bones: std.StringHashMapUnmanaged(Value) = .empty,
    slot_colors: std.StringHashMapUnmanaged(u32) = .empty,
    animations: ?*ObjectMap = null,
    rewrite: bool = false,
    slider: bool = false,
    version: ?Version = null,

    fn index(m: *Migration, doc: *ObjectMap) Error!void {
        for (try edit.arrayOf(doc, "bones")) |bone| try m.bones.put(m.arena, try tree.requireString(bone, "name"), bone);
        for (try edit.arrayOf(doc, "slots")) |slot| {
            try m.slot_colors.put(m.arena, try tree.requireString(slot, "name"), try tree.getColor(slot, "color", 0xffffffff));
        }
        m.animations = try edit.childOf(doc, "animations");
    }

    fn editor(m: *const Migration, change: Version.Change) Version.Editor {
        return Version.editor(m.version orelse return .new, change);
    }

    /// Reports constraint semantics no rewrite preserves
    fn check(m: *Migration, doc: *ObjectMap, names: Names) Error!void {
        const stretch_old = m.editor(.stretch_40) == .old;
        for (try edit.arrayOf(doc, "ik")) |*entry| {
            const c = entry.*;
            const bones = try tree.getArray(c, "bones");
            if (bones.len != 2) continue;
            const name = try tree.requireString(c, "name");
            const where = try std.fmt.allocPrint(m.arena, "ik.{s}", .{name});
            if (!stretch_old and try m.stretched(c)) {
                if (!try m.childMoves(c)) {} else if (!names.down and m.rewrite and m.slider and try m.stretchRig(doc, c)) {
                    try entry.object.put(m.arena, marks.stretch_offset, .{ .bool = true });
                    try m.lose(.@"ik.stretch.rewritten", where, "child Y position kept by a 4.3 helper parent turned toward the child", .{});
                } else try m.lose(.@"ik.stretch.approximated", where, "4.0 stretch ignores the child Y position", .{});
                if (names.down and try tree.getBool(c, "uniform", false)) {
                    try m.lose(.@"ik.uniform.dropped", where, "3.8 two bone IK stretches without uniform scale", .{});
                }
            }
            var zero = try tree.getFloat(c, "mix", 1) == 0;
            for (try m.constraintKeys("ik", name, null)) |key| zero = zero or try tree.getFloat(key, "mix", 1) == 0;
            if (bones[1] != .string) return error.Malformed;
            if (zero and try m.earlierOn(doc, bones[1].string, try tree.getFloat(c, "order", 0))) {
                if (m.rewrite and m.slider and !names.down and try m.restoresIk(c, name, bones[1].string)) {
                    try m.addRestore(entry, bones[1].string);
                    if (!try m.alwaysZero(c, name)) try entry.object.put(m.arena, marks.restore_gate, .{ .string = bones[1].string });
                    try m.lose(.@"ik.reset.rewritten", where, "child kept at its local pose by a 4.3 helper constraint", .{});
                } else try m.lose(.@"ik.reset.approximated", where, "3.8 updates the child from its local pose at mix 0", .{});
            }
        }
        for (try edit.arrayOf(doc, "transform")) |*c| {
            const name = try tree.requireString(c.*, "name");
            const where = try std.fmt.allocPrint(m.arena, "transform.{s}", .{name});
            if (try tree.getBool(c.*, "local", false)) {
                if (try tree.getBool(c.*, "relative", false) and try m.rotateRange(c.*, names)) {
                    try m.lose(.@"transform.rotateRange.approximated", where, "3.8 wraps the target rotation around its setup", .{});
                }
                continue;
            }
            const range = try m.bounds("transform", name, null, c.*, names.scale, names.down);
            if (range[0] >= 0) continue;
            if (m.rewrite and range[1] <= 0) {
                try m.zeroMix(c, "transform", name, names.scale[0].name);
                try m.lose(.@"transform.scaleMix.rewritten", where, "world scale mix that is never positive set to 0", .{});
            } else if (m.rewrite and m.slider and (!try m.under(try tree.requireString(c.*, "target"), try tree.getArray(c.*, "bones")) or try snapshot(doc, c.*))) {
                try c.object.put(m.arena, marks.scale_floor, .{ .bool = true });
                // 3.8 reads the target before the constraint moves its ancestor
                if (try m.under(try tree.requireString(c.*, "target"), try tree.getArray(c.*, "bones"))) try c.object.put(m.arena, marks.scale_snapshot, .{ .bool = true });
                try m.lose(.@"transform.scaleMix.rewritten", where, "negative world scale mix clamped at 0 by a 4.3 slider", .{});
            } else try m.lose(.@"transform.scaleMix.approximated", where, "negative world scale mix", .{});
        }
        for (try edit.arrayOf(doc, "path")) |*c| try m.checkPath(doc, c, names);
        if (m.rewrite) {
            try m.rewriteOrder(doc, true, m.slider and !names.down, "3.8");
        } else if (m.editor(.order_40) != .old) try m.checkOrder(doc);
    }

    /// 3.8 updates a bone again from its local pose
    fn checkOrder(m: *Migration, doc: *ObjectMap) Error!void {
        const Constraint = struct { kind: []const u8, value: Value, order: f32, bones: []const Value };
        var all: std.ArrayList(Constraint) = .empty;
        for ([_][]const u8{ "ik", "transform", "path" }) |kind| for (try edit.arrayOf(doc, kind)) |c| {
            const bones = try tree.getArray(c, "bones");
            for (bones) |bone| if (bone != .string) return error.Malformed;
            try all.append(m.arena, .{ .kind = kind, .value = c, .order = try tree.getFloat(c, "order", 0), .bones = bones });
        };
        for (all.items) |a| {
            var reset = false;
            for (a.bones) |bone| reset = reset or try m.resetBy(all.items, a.order, bone.string);
            if (!reset) continue;
            const where = try std.fmt.allocPrint(m.arena, "{s}.{s}", .{ a.kind, try tree.requireString(a.value, "name") });
            try m.lose(.@"constraint.order.approximated", where, "a later ancestor constraint resets this result in 3.8", .{});
        }
    }

    fn resetBy(m: *Migration, all: anytype, from: f32, bone: []const u8) Error!bool {
        for (all) |b| {
            if (b.order <= from or contains(b.bones, bone)) continue;
            var current = bone;
            for (0..m.bones.count()) |_| {
                current = try tree.getString(m.bones.get(current) orelse break, "parent") orelse break;
                if (contains(b.bones, current)) return true;
            }
        }
        return false;
    }

    /// Drops bones a later ancestor constraint resets
    fn rewriteOrder(m: *Migration, doc: *ObjectMap, allowed: bool, restore: bool, which: []const u8) Error!void {
        const bones = try m.orderBones();
        var list: std.ArrayList(order.Constraint) = .empty;
        var values: std.ArrayList(*Value) = .empty;
        var paths: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ "ik", "transform", "path" }) |kind| for (try edit.arrayOf(doc, kind)) |*c| {
            const name = try tree.requireString(c.*, "name");
            var constrained: std.ArrayList([]const u8) = .empty;
            for (try tree.getArray(c.*, "bones")) |b| {
                if (b != .string) return error.Malformed;
                try constrained.append(m.arena, b.string);
            }
            const is_path = std.mem.eql(u8, kind, "path");
            const reads = if (is_path) try m.pathReads(doc, try tree.requireString(c.*, "target")) else try m.arena.dupe([]const u8, &.{try tree.requireString(c.*, "target")});
            var skins: ?[]const []const u8 = null;
            if (try tree.getBool(c.*, "skin", false)) {
                var holding: std.ArrayList([]const u8) = .empty;
                for (try edit.arrayOf(doc, "skins")) |skin| for (try tree.getArray(skin, kind)) |n| {
                    if (n == .string and std.mem.eql(u8, n.string, name)) try holding.append(m.arena, try tree.requireString(skin, "name"));
                };
                skins = holding.items;
            }
            try list.append(m.arena, .{
                .order = try tree.getFloat(c.*, "order", 0),
                .bones = constrained.items,
                .reads = reads,
                .skins = skins,
                .bound = if (bones.get(reads[0])) |b| b.required else false,
                .drop = if (std.mem.eql(u8, kind, "ik")) .none else if (is_path) .suffix else .any,
            });
            try values.append(m.arena, c);
            try paths.append(m.arena, try std.fmt.allocPrint(m.arena, "{s}.{s}", .{ kind, name }));
        };
        for (try order.find(m.arena, &bones, list.items)) |reset| {
            const where = paths.items[reset.index];
            if (allowed and !reset.exact and restore and try m.markRestore(&bones, list.items, values.items, reset)) {
                try m.lose(.@"constraint.order.rewritten", where, "bones a later ancestor constraint resets in {s} restored by 4.3 helper constraints", .{which});
                continue;
            }
            if (!allowed or !reset.exact) {
                try m.lose(.@"constraint.order.approximated", where, "a later ancestor constraint resets this result in {s}", .{which});
                continue;
            }
            const kept = try order.kept(m.arena, list.items[reset.index].bones, reset.bones);
            var array = try std.json.Array.initCapacity(m.arena, kept.len);
            for (kept) |b| array.appendAssumeCapacity(.{ .string = b });
            try (try edit.objectOf(values.items[reset.index])).put(m.arena, "bones", .{ .array = array });
            try m.lose(.@"constraint.order.rewritten", where, "bones a later ancestor constraint resets in {s} removed", .{which});
        }
    }

    fn orderBones(m: *Migration) Error!order.Bones {
        var bones: order.Bones = .empty;
        var it = m.bones.iterator();
        while (it.next()) |b| {
            try bones.put(m.arena, b.key_ptr.*, .{ .parent = try tree.getString(b.value_ptr.*, "parent"), .required = try tree.getBool(b.value_ptr.*, "skin", false) });
        }
        return bones;
    }

    /// Marks the later constraints whose reset a 4.3 helper constraint undoes
    fn markRestore(m: *Migration, bones: *const order.Bones, list: []const order.Constraint, values: []const *Value, reset: order.Reset) Error!bool {
        const Pair = struct { later: usize, bone: []const u8 };
        var hits: std.ArrayList(Pair) = .empty;
        for (reset.bones) |bone| {
            if (!try m.restorable(bones, bone)) return false;
            for (values) |v| {
                const gated = tree.get(v.*, marks.restore_gate) orelse continue;
                if (gated == .string and std.mem.eql(u8, gated.string, bone)) return false;
            }
            for (try order.restorers(m.arena, bones, list, reset.index, bone) orelse return false) |later| try hits.append(m.arena, .{ .later = later, .bone = bone });
        }
        for (hits.items) |p| try m.addRestore(values[p.later], p.bone);
        return true;
    }

    fn addRestore(m: *Migration, c: *Value, bone: []const u8) Error!void {
        const map = try edit.objectOf(c);
        const entry = try map.getOrPut(m.arena, marks.restore);
        if (!entry.found_existing) entry.value_ptr.* = .{ .array = tree.array(m.arena) };
        for (entry.value_ptr.array.items) |b| if (std.mem.eql(u8, b.string, bone)) return;
        try entry.value_ptr.array.append(.{ .string = bone });
    }

    fn alwaysZero(m: *Migration, c: Value, name: []const u8) Error!bool {
        if (try tree.getFloat(c, "mix", 1) != 0) return false;
        for (try m.constraintKeys("ik", name, null)) |key| if (try tree.getFloat(key, "mix", 1) != 0) return false;
        return true;
    }

    /// An IK without skin whose child a helper can restore
    fn restoresIk(m: *Migration, c: Value, name: []const u8, child: []const u8) Error!bool {
        _ = name;
        if (try tree.getBool(c, "skin", false)) return false;
        const bones = try m.orderBones();
        const target = bones.get(try tree.requireString(c, "target")) orelse return false;
        return !target.required and try m.restorable(&bones, child);
    }

    /// A restore may copy the local pose through a 4.3 local constraint
    fn restorable(m: *Migration, bones: *const order.Bones, bone: []const u8) Error!bool {
        if (order.required(bones, bone)) return false;
        const setup = m.bones.get(bone) orelse return false;
        if (try tree.getFloat(setup, "shearX", 0) != 0) return false;
        const scale = [_]f32{ try tree.getFloat(setup, "scaleX", 1), try tree.getFloat(setup, "scaleY", 1) };
        if (scale[0] == 0 or scale[1] == 0) return false;
        const animations = m.animations orelse return true;
        for (animations.values()) |animation| {
            const timelines = tree.get(tree.get(animation, "bones") orelse continue, bone) orelse continue;
            if (tree.get(timelines, "shear")) |shear| {
                if (shear != .array) return error.Malformed;
                for (shear.array.items) |key| if (try tree.getFloat(key, "x", 0) != 0) return false;
            }
            if (tree.get(timelines, "scale")) |keys| {
                if (keys != .array) return error.Malformed;
                for (keys.array.items) |key| for ([_][]const u8{ "x", "y" }, 0..) |field, channel| {
                    if (!try positive(key, field, channel)) return false;
                };
            }
        }
        return true;
    }

    /// Slot bone and weighted path bones
    fn pathReads(m: *Migration, doc: *ObjectMap, slot: []const u8) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try edit.arrayOf(doc, "slots")) |s| {
            if (std.mem.eql(u8, try tree.requireString(s, "name"), slot)) try out.append(m.arena, try tree.requireString(s, "bone"));
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
                        try out.append(m.arena, try tree.requireString(all[at], "name"));
                        i += 4;
                    }
                }
            }
        }
        return out.items;
    }

    /// Bone constrained before order at
    fn earlierOn(m: *Migration, doc: *ObjectMap, bone: []const u8, at: f32) Error!bool {
        _ = m;
        for ([_][]const u8{ "ik", "transform", "path" }) |kind| for (try edit.arrayOf(doc, kind)) |c| {
            if (try tree.getFloat(c, "order", 0) >= at) continue;
            for (try tree.getArray(c, "bones")) |b| if (b == .string and std.mem.eql(u8, b.string, bone)) return true;
        };
        return false;
    }

    fn stretched(m: *Migration, c: Value) Error!bool {
        var stretch = try tree.getBool(c, "stretch", false);
        for (try m.constraintKeys("ik", try tree.requireString(c, "name"), null)) |key| stretch = stretch or try tree.getBool(key, "stretch", false);
        return stretch;
    }

    /// A helper parent keeps the child Y position in 4.3
    fn stretchRig(m: *Migration, doc: *ObjectMap, c: Value) Error!bool {
        const bones = try tree.getArray(c, "bones");
        const name = try tree.requireString(c, "name");
        for (bones) |b| if (b != .string) return error.Malformed;
        const parent = m.bones.get(bones[0].string) orelse return error.Malformed;
        const child = m.bones.get(bones[1].string) orelse return error.Malformed;
        for ([_]Value{ parent, child }) |bone| {
            if (!std.mem.eql(u8, try tree.getString(bone, "transform") orelse "normal", "normal")) return false;
            if (try tree.getBool(bone, "skin", false)) return false;
        }
        const sx = try tree.getFloat(parent, "scaleX", 1);
        if (sx == 0 or @abs(sx) != @abs(try tree.getFloat(parent, "scaleY", 1))) return false;
        if (try tree.getFloat(parent, "shearX", 0) != 0 or try tree.getFloat(parent, "shearY", 0) != 0) return false;
        if (m.animations) |animations| for (animations.values()) |animation| {
            const timelines = tree.get(animation, "bones") orelse continue;
            for (bones, [_][]const []const u8{ &.{ "scale", "shear" }, &.{"translate"} }) |b, banned| {
                const t = tree.get(timelines, b.string) orelse continue;
                if (t != .object) return error.Malformed;
                for (t.object.keys()) |key| for (banned) |prefix| if (std.mem.startsWith(u8, key, prefix)) return false;
            }
        };
        for ([_][]const u8{ "ik", "transform", "path" }) |kind| for (try edit.arrayOf(doc, kind)) |other| {
            if (std.mem.eql(u8, try tree.requireString(other, "name"), name)) continue;
            for (try tree.getArray(other, "bones")) |b| {
                if (b != .string) return error.Malformed;
                if (std.mem.eql(u8, b.string, bones[0].string) or std.mem.eql(u8, b.string, bones[1].string)) return false;
            }
        };
        for (try edit.arrayOf(doc, "skins")) |skin| for (try tree.getArray(skin, "ik")) |entry| {
            if (entry == .string and std.mem.eql(u8, entry.string, name)) return false;
        };
        return true;
    }

    /// Two bone IK child has a Y position
    fn childMoves(m: *Migration, c: Value) Error!bool {
        const bones = try tree.getArray(c, "bones");
        if (bones[1] != .string) return error.Malformed;
        const child = bones[1].string;
        var moves = try tree.getFloat(m.bones.get(child) orelse .null, "y", 0) != 0;
        if (m.animations) |animations| for (animations.values()) |animation| {
            const timelines = tree.get(tree.get(animation, "bones") orelse continue, child) orelse continue;
            moves = moves or tree.get(timelines, "translate") != null or tree.get(timelines, "translatey") != null;
        };
        return moves;
    }

    /// Partial rotate mix past 180 from setup
    fn rotateRange(m: *Migration, c: Value, names: Names) Error!bool {
        const setup = try tree.getFloat(c, names.rotate_mix, 1);
        var partial = setup != 0 and setup != 1;
        for (try m.keysPer("transform", try tree.requireString(c, "name"), null)) |keys| for (keys, 0..) |key, i| {
            const mix = try tree.getFloat(key, names.rotate_mix, 1);
            partial = partial or mix != 0 and mix != 1;
            if (i + 1 == keys.len or (tree.get(key, "curve") orelse .null) == .string) continue;
            partial = partial or mix != try tree.getFloat(keys[i + 1], names.rotate_mix, 1);
        };
        if (!partial) return false;
        const target = try tree.requireString(c, "target");
        const animations = m.animations orelse return false;
        for (animations.values()) |animation| {
            const keys = tree.get(tree.get(tree.get(animation, "bones") orelse continue, target) orelse continue, "rotate") orelse continue;
            if (keys != .array) return error.Malformed;
            var previous: ?f32 = null;
            var angle: f32 = 0;
            for (keys.array.items) |key| {
                const raw = try tree.getFloat(key, names.angle, 0);
                angle = if (previous) |p| angle + if (names.down) raw - p else wrap(raw - p) else raw;
                previous = raw;
                if (@abs(raw) > 180 or @abs(angle) > 180) return true;
            }
        }
        return false;
    }

    /// Mix range including Bezier control values
    fn bounds(m: *Migration, kind: []const u8, name: []const u8, sub: ?[]const u8, c: Value, mixes: []const Mix, new: bool) Error![2]f32 {
        var out: [2]f32 = .{ std.math.inf(f32), -std.math.inf(f32) };
        for (mixes) |mix| widen(&out, try mixOf(c, mix));
        for (try m.keysPer(kind, name, sub)) |keys| for (keys, 0..) |key, i| for (mixes) |mix| {
            const v = try mixOf(key, mix);
            widen(&out, v);
            if (i + 1 == keys.len) continue;
            const curve = tree.get(key, "curve") orelse continue;
            if (new) {
                if (curve != .array or curve.array.items.len < mix.channel * 4 + 4) continue;
                for ([_]usize{ 1, 3 }) |k| widen(&out, try tree.number(curve.array.items[mix.channel * 4 + k]));
            } else if (curve != .string) {
                const next = try mixOf(keys[i + 1], mix);
                for ([_]f32{ try tree.getFloat(key, "c2", 0), try tree.getFloat(key, "c4", 1) }) |h| widen(&out, v + h * (next - v));
            }
        };
        return out;
    }

    /// A snapshot under the root keeps its scale while the constraint runs
    fn snapshot(doc: *ObjectMap, c: Value) Error!bool {
        const list = try edit.arrayOf(doc, "bones");
        if (list.len == 0) return error.Malformed;
        const root = try tree.requireString(list[0], "name");
        for (try tree.getArray(c, "bones")) |b| if (b == .string and std.mem.eql(u8, b.string, root)) return false;
        return true;
    }

    /// Whether the bone is one of bones or below one
    fn under(m: *Migration, bone: []const u8, bones: []const Value) Error!bool {
        var at: ?[]const u8 = bone;
        while (at) |name| {
            for (bones) |b| if (b == .string and std.mem.eql(u8, b.string, name)) return true;
            at = try tree.getString(m.bones.get(name) orelse return error.Malformed, "parent");
        }
        return false;
    }

    fn zeroPathMixes(m: *Migration, c: *Value, name: []const u8, mixes: []const Mix) Error!void {
        for (mixes) |mix| try (try edit.objectOf(c)).put(m.arena, mix.name, .{ .float = 0 });
        const animations = m.animations orelse return;
        for (animations.values()) |*animation| {
            const timelines = try edit.childOf(try edit.childOf(try edit.objectOf(animation), "path") orelse continue, name) orelse continue;
            const keys = timelines.getPtr("mix") orelse continue;
            for (try edit.keysOf(keys)) |*k| for (mixes) |mix| try (try edit.objectOf(k)).put(m.arena, mix.name, .{ .float = 0 });
        }
    }

    fn zeroMix(m: *Migration, c: *Value, kind: []const u8, name: []const u8, key: []const u8) Error!void {
        try (try edit.objectOf(c)).put(m.arena, key, .{ .float = 0 });
        const animations = m.animations orelse return;
        for (animations.values()) |*animation| {
            const keys = try edit.childValue(try edit.childOf(try edit.objectOf(animation), kind) orelse continue, name) orelse continue;
            for (try edit.keysOf(keys)) |*k| try (try edit.objectOf(k)).put(m.arena, key, .{ .float = 0 });
        }
    }

    /// Early 4.0 relative local scale formula
    fn checkRelativeScale(m: *Migration, doc: *ObjectMap, message: []const u8, rig: bool) Error!void {
        for (try edit.arrayOf(doc, "transform")) |*entry| {
            const c = entry.*;
            if (!try tree.getBool(c, "local", false) or !try tree.getBool(c, "relative", false)) continue;
            const name = try tree.requireString(c, "name");
            var mixed = false;
            for (transform_all) |key| mixed = mixed or try tree.getFloat(c, key, 1) != 0;
            for (try m.constraintKeys("transform", name, null)) |k| for (transform_all) |key| {
                mixed = mixed or try tree.getFloat(k, key, 1) != 0;
            };
            if (!mixed) continue;
            const at = try tree.getFloat(c, "order", 0);
            for (try tree.getArray(c, "bones")) |bone| {
                if (bone != .string) return error.Malformed;
                if (!try m.scaledBone(doc, bone.string, at)) continue;
                if (rig and try m.relativeRig(doc, c)) {
                    try entry.object.put(m.arena, marks.relative_scale, .{ .bool = true });
                    try m.lose(.@"transform.relativeScale.rewritten", try std.fmt.allocPrint(m.arena, "transform.{s}", .{name}), "old relative scale rebuilt by 4.3 helper bones", .{});
                    break;
                }
                try m.report.add(.{
                    .code = .@"transform.relativeScale.approximated",
                    .step = m.step,
                    .path = try std.fmt.allocPrint(m.arena, "transform.{s}", .{name}),
                    .message = message,
                    .remedy = .runtime,
                });
                break;
            }
        }
    }

    /// Old relative scale runs on a nonzero bone scale
    fn relativeRig(m: *Migration, doc: *ObjectMap, c: Value) Error!bool {
        const keys = try m.constraintKeys("transform", try tree.requireString(c, "name"), null);
        // old 4.0 skips the constraint when every mix but scaleY is 0
        const live = for ([_]usize{ 0, 1, 3, 5 }) |channel| {
            const setup = try tree.getFloat(c, transform_all[channel], 1);
            if (setup != 0 and try sameSign(keys, transform_all[channel], channel, setup)) break true;
        } else false;
        if (!live) return false;
        const target = m.bones.get(try tree.requireString(c, "target")) orelse return error.Malformed;
        if (try tree.getBool(target, "skin", false)) return false;
        const at = try tree.getFloat(c, "order", 0);
        for (try tree.getArray(c, "bones")) |bone| {
            if (bone != .string) return error.Malformed;
            const data = m.bones.get(bone.string) orelse return error.Malformed;
            if (try tree.getBool(data, "skin", false) or try m.earlierOn(doc, bone.string, at)) return false;
            for ([_][]const u8{ "scaleX", "scaleY" }, [_][]const u8{ "x", "y" }, [_][]const u8{ "scalex", "scaley" }, 0..) |field, value, single, axis| {
                const setup = try tree.getFloat(data, field, 1);
                if (setup == 0) return false;
                const animations = m.animations orelse continue;
                for (animations.values()) |animation| {
                    const timelines = tree.get(tree.get(animation, "bones") orelse continue, bone.string) orelse continue;
                    if (tree.get(timelines, "scale")) |list| if (list != .array or !try sameSign(list.array.items, value, axis, setup)) return false;
                    if (tree.get(timelines, single)) |list| if (list != .array or !try sameSign(list.array.items, "value", 0, setup)) return false;
                }
            }
        }
        return true;
    }

    /// Bone scale may differ from 1
    fn scaledBone(m: *Migration, doc: *ObjectMap, bone: []const u8, at: f32) Error!bool {
        const data = m.bones.get(bone) orelse .null;
        if (try tree.getFloat(data, "scaleX", 1) != 1 or try tree.getFloat(data, "scaleY", 1) != 1) return true;
        if (m.animations) |animations| for (animations.values()) |animation| {
            const timelines = tree.get(tree.get(animation, "bones") orelse continue, bone) orelse continue;
            for ([_][2][]const u8{ .{ "scale", "x" }, .{ "scale", "y" }, .{ "scalex", "value" }, .{ "scaley", "value" } }) |axis| {
                const keys = tree.get(timelines, axis[0]) orelse continue;
                if (keys != .array) return error.Malformed;
                for (keys.array.items) |key| {
                    if (try tree.getFloat(key, axis[1], 1) != 1 or (tree.get(key, "curve") orelse .null) == .array) return true;
                }
            }
        };
        return m.earlierOn(doc, bone, at);
    }

    fn checkJsonShear(m: *Migration) Error!void {
        const animations = m.animations orelse return;
        var it = animations.iterator();
        while (it.next()) |animation| {
            var transforms = try edit.timelinesOf(try edit.objectOf(animation.value_ptr), "transform");
            while (transforms.next()) |timeline| {
                const keys = try edit.keysOf(timeline.value_ptr);
                if (keys.len == 0) continue;
                const first = try tree.getFloat(keys[0], "mixShearY", 1);
                for (keys[1..]) |key| if (try tree.getFloat(key, "mixShearY", 1) != first) {
                    const where = try std.fmt.allocPrint(m.arena, "animations.{s}.transform.{s}", .{ animation.key_ptr.*, timeline.key_ptr.* });
                    try m.lose(.@"transform.jsonShear.approximated", where, "4.0 JSON loaders read the shear mix of the first key", .{});
                    break;
                };
            }
        }
    }

    fn checkPath(m: *Migration, doc: *ObjectMap, c: *Value, names: Names) Error!void {
        const name = try tree.requireString(c.*, "name");
        const where = try std.fmt.allocPrint(m.arena, "path.{s}", .{name});
        if ((try m.bounds("path", name, "mix", c.*, names.path_mix, names.down))[0] < 0) {
            // 3.8 runs the constraint only while a mix is positive, then applies any sign
            const rotate = try m.bounds("path", name, "mix", c.*, names.path_mix[0..1], names.down);
            const translate = try m.bounds("path", name, "mix", c.*, names.path_mix[1..], names.down);
            if (rotate[0] > 0 or translate[0] > 0 and !names.down) {} else if (rotate[1] <= 0 and translate[1] <= 0 and !names.down and m.rewrite) {
                try m.zeroPathMixes(c, name, names.path_mix);
                try m.lose(.@"path.negative.rewritten", where, "path mixes that never turn positive became 0", .{});
            } else if (m.rewrite and m.slider and !names.down and !try tree.getBool(c.*, "skin", false)) {
                try (try edit.objectOf(c)).put(m.arena, marks.path_gate, .{ .bool = true });
                try m.lose(.@"path.negative.rewritten", where, "negative path mix gated by sliders", .{});
            } else try m.lose(.@"path.negative.approximated", where, "negative path mix", .{});
        }

        const unscaled = edit.take(try edit.objectOf(c), marks.position_unscaled) != null;
        if (!unscaled and std.mem.eql(u8, try tree.getString(c.*, "positionMode") orelse "percent", "fixed")) {
            const slot = try tree.requireString(c.*, "target");
            var constant = false;
            for (try edit.arrayOf(doc, "skins")) |skin| {
                const attachments = tree.get(tree.get(skin, "attachments") orelse continue, slot) orelse continue;
                if (attachments != .object) return error.Malformed;
                for (attachments.object.values()) |a| {
                    if (std.mem.eql(u8, try tree.getString(a, "type") orelse "region", "path")) constant = constant or try tree.getBool(a, "constantSpeed", true);
                }
            }
            const length = if (constant and !names.down and m.rewrite) try m.setupLength(doc, slot) else null;
            if (length) |l| {
                try m.percentPosition(c, name, l);
                try m.lose(.@"path.position.rewritten", where, "fixed position became percent of the setup path length", .{});
            } else if (constant) try m.lose(.@"path.position.approximated", where, "3.8 scales a fixed position by the world path length", .{});
        }

        const mode = try tree.getString(c.*, "spacingMode") orelse "length";
        if (std.mem.eql(u8, mode, "proportional")) {
            try c.object.put(m.arena, "spacingMode", .{ .string = "percent" });
            return m.lose(.@"path.proportional.approximated", where, "proportional spacing becomes percent", .{});
        }
        const percent = std.mem.eql(u8, mode, "percent");
        const chain = std.mem.eql(u8, try tree.getString(c.*, "rotateMode") orelse "tangent", "chainScale");
        // betas before 4.0.34-beta also zeroed percent
        const differs = if (m.editor(.zero_bone_40) == .old) percent and !chain else !percent or chain;
        if (differs and try m.zeroSpacing(c.*, names.spacing)) {
            try m.lose(.@"path.spacing.approximated", where, "zero length bones space differently", .{});
        }
    }

    /// Setup length every path of the slot shares, null unless all are constant speed
    fn setupLength(m: *Migration, doc: *ObjectMap, slot: []const u8) Error!?f32 {
        _ = m;
        var length: ?f32 = null;
        for (try edit.arrayOf(doc, "skins")) |skin| {
            const attachments = tree.get(tree.get(skin, "attachments") orelse continue, slot) orelse continue;
            if (attachments != .object) return error.Malformed;
            for (attachments.object.values()) |a| {
                if (!std.mem.eql(u8, try tree.getString(a, "type") orelse "region", "path")) continue;
                if (!try tree.getBool(a, "constantSpeed", true)) return null;
                // 3.8 divides by the length up to the last curve, an open path holds one more entry
                const lengths = try tree.getArray(a, "lengths");
                const last: usize = if (try tree.getBool(a, "closed", false)) 1 else 2;
                if (lengths.len < last) return error.Malformed;
                const l = try tree.number(lengths[lengths.len - last]);
                if (l <= 0 or (length != null and length.? != l)) return null;
                length = l;
            }
        }
        return length;
    }

    /// 3.8 fixed position p is 4.0 percent position p / length
    fn percentPosition(m: *Migration, c: *Value, name: []const u8, length: f32) Error!void {
        const map = try edit.objectOf(c);
        try map.put(m.arena, "positionMode", .{ .string = "percent" });
        if (map.get("position")) |p| try map.put(m.arena, "position", .{ .float = try tree.number(p) / length });
        const animations = m.animations orelse return;
        for (animations.values()) |*animation| {
            const paths = try edit.childOf(try edit.objectOf(animation), "path") orelse continue;
            const timelines = try edit.childOf(paths, name) orelse continue;
            const keys = timelines.getPtr("position") orelse continue;
            for (try edit.keysOf(keys)) |*key| {
                const k = try edit.objectOf(key);
                if (k.get("position")) |p| try k.put(m.arena, "position", .{ .float = try tree.number(p) / length });
            }
        }
    }

    /// Nonzero spacing along a zero length bone
    fn zeroSpacing(m: *Migration, c: Value, key: []const u8) Error!bool {
        var spacing = try tree.getFloat(c, "spacing", 0) != 0;
        for (try m.constraintKeys("path", try tree.requireString(c, "name"), "spacing")) |k| spacing = spacing or try tree.getFloat(k, key, 0) != 0;
        if (!spacing) return false;
        const tangent = std.mem.eql(u8, try tree.getString(c, "rotateMode") orelse "tangent", "tangent");
        const bones = try tree.getArray(c, "bones");
        // tangents give the last bone no space
        for (bones[0 .. bones.len - @intFromBool(tangent and bones.len > 0)]) |bone| {
            if (bone != .string) return error.Malformed;
            if (try tree.getFloat(m.bones.get(bone.string) orelse .null, "length", 0) < 0.00001) return true;
        }
        return false;
    }

    /// Key arrays of one constraint per animation
    fn keysPer(m: *Migration, kind: []const u8, name: []const u8, sub: ?[]const u8) Error![]const []const Value {
        var out: std.ArrayList([]const Value) = .empty;
        const animations = m.animations orelse return &.{};
        for (animations.values()) |animation| {
            var timeline = tree.get(tree.get(animation, kind) orelse continue, name) orelse continue;
            if (sub) |s| timeline = tree.get(timeline, s) orelse continue;
            if (timeline != .array) return error.Malformed;
            try out.append(m.arena, timeline.array.items);
        }
        return out.items;
    }

    /// Keys of one constraint in all animations
    fn constraintKeys(m: *Migration, kind: []const u8, name: []const u8, sub: ?[]const u8) Error![]const Value {
        var out: std.ArrayList(Value) = .empty;
        const animations = m.animations orelse return &.{};
        for (animations.values()) |animation| {
            var timeline = tree.get(tree.get(animation, kind) orelse continue, name) orelse continue;
            if (sub) |s| timeline = tree.get(timeline, s) orelse continue;
            if (timeline != .array) return error.Malformed;
            try out.appendSlice(m.arena, timeline.array.items);
        }
        return out.items;
    }

    /// 3.8 reads RGB as opaque, 4.0 needs the alpha
    fn withAlpha(m: *Migration, keys: *Value, field: []const u8) Error!void {
        for (try edit.keysOf(keys)) |*key| {
            const color = try tree.requireString(key.*, field);
            if (color.len == 6) try (try edit.objectOf(key)).put(m.arena, field, .{ .string = try std.mem.concat(m.arena, u8, &.{ color, "ff" }) });
        }
    }

    fn upAnimation(m: *Migration, animation: *ObjectMap) Error!void {
        if (animation.get("drawOrder") == null) try m.rename(animation, "draworder", "drawOrder");
        var slots = try edit.timelinesOf(animation, "slots");
        while (slots.next()) |slot| {
            const map = try edit.objectOf(slot.value_ptr);
            try m.rename(map, "color", "rgba");
            try m.rename(map, "twoColor", "rgba2");
            if (try edit.childValue(map, "rgba")) |keys| {
                try m.withAlpha(keys, "color");
                try m.upCurves(keys, .rgba);
            }
            if (try edit.childValue(map, "rgba2")) |keys| {
                try m.withAlpha(keys, "light");
                try m.upCurves(keys, .rgba2);
            }
        }
        var bones = try edit.timelinesOf(animation, "bones");
        while (bones.next()) |bone| {
            const map = try edit.objectOf(bone.value_ptr);
            if (try edit.childValue(map, "rotate")) |keys| {
                for (try edit.keysOf(keys)) |*key| try m.rename(try edit.objectOf(key), "angle", "value");
                try m.upCurves(keys, .rotate);
            }
            for (pairs, pair_defaults) |name, d| {
                if (try edit.childValue(map, name)) |keys| try m.upCurves(keys, .{ .pair = d });
            }
        }
        var iks = try edit.timelinesOf(animation, "ik");
        while (iks.next()) |ik| try m.upCurves(ik.value_ptr, .ik);
        var transforms = try edit.timelinesOf(animation, "transform");
        while (transforms.next()) |transform| {
            for (try edit.keysOf(transform.value_ptr)) |*key| try m.renameAll(try edit.objectOf(key), &transform_old, &transform_new);
            try m.upCurves(transform.value_ptr, .transform);
        }
        var paths = try edit.timelinesOf(animation, "path");
        while (paths.next()) |constraint| {
            const map = try edit.objectOf(constraint.value_ptr);
            for ([_][]const u8{ "position", "spacing" }) |name| {
                const keys = try edit.childValue(map, name) orelse continue;
                for (try edit.keysOf(keys)) |*key| try m.rename(try edit.objectOf(key), name, "value");
                try m.upCurves(keys, .{ .value = 0 });
            }
            if (try edit.childValue(map, "mix")) |keys| {
                for (try edit.keysOf(keys)) |*key| try m.renameAll(try edit.objectOf(key), &path_old, &path_new);
                try m.upCurves(keys, .path_mix);
            }
        }
        var skins = try edit.timelinesOf(animation, "deform");
        while (skins.next()) |skin| {
            var deform_slots = (try edit.objectOf(skin.value_ptr)).iterator();
            while (deform_slots.next()) |slot| {
                var attachments = (try edit.objectOf(slot.value_ptr)).iterator();
                while (attachments.next()) |attachment| try m.upCurves(attachment.value_ptr, .deform);
            }
        }
    }

    /// Splits the shared 3.8 curve per value
    fn upCurves(m: *Migration, timeline: *Value, shape: Shape) Error!void {
        const keys = try edit.keysOf(timeline);
        const n = shape.channels();
        const values = try m.arena.alloc(f64, keys.len * n);
        for (keys, 0..) |key, i| try readValues(key, shape, values[i * n ..][0..n]);
        if (shape == .rotate and keys.len > 0) {
            var previous: f32 = @floatCast(values[0]);
            var angle = previous;
            for (keys[1..], values[1..]) |*key, *v| {
                const raw: f32 = @floatCast(v.*);
                angle += wrap(raw - previous);
                previous = raw;
                v.* = angle;
                if (angle != raw) try (try edit.objectOf(key)).put(m.arena, "value", .{ .float = angle });
            }
        }
        for (keys, 0..) |*key, i| {
            const k = try edit.objectOf(key);
            const curve = edit.take(k, "curve");
            var handles: [4]f64 = .{ 0, 0, 1, 1 };
            for ([_][]const u8{ "c2", "c3", "c4" }, handles[1..]) |name, *h| {
                if (edit.take(k, name)) |v| h.* = try finiteOf(try tree.number(v));
            }
            const c = curve orelse continue;
            if (i + 1 == keys.len) continue;
            // 3.8 Java treats any string as stepped
            if (c == .string) {
                try k.put(m.arena, "curve", .{ .string = "stepped" });
                continue;
            }
            handles[0] = try finiteOf(try tree.number(c));
            const t1 = try finite(key.*, "time", 0);
            const dt = try finite(keys[i + 1], "time", 0) - t1;
            var out = try std.json.Array.initCapacity(m.arena, n * 4);
            for (0..n) |ch| {
                const v1 = if (shape == .deform) 0 else values[i * n + ch];
                const dv = if (shape == .deform) 1 else values[(i + 1) * n + ch] - v1;
                for ([_]f64{ t1 + handles[0] * dt, v1 + handles[1] * dv, t1 + handles[2] * dt, v1 + handles[3] * dv }) |v| {
                    out.appendAssumeCapacity(.{ .float = v });
                }
            }
            try k.put(m.arena, "curve", .{ .array = out });
        }
    }

    fn downAnimation(m: *Migration, name: []const u8, animation: *ObjectMap) Error!void {
        try m.prune(animation, 1);
        for ([_][]const u8{ "slots", "bones", "ik", "transform", "path", "deform" }, [_]usize{ 2, 2, 1, 1, 2, 3 }) |group, depth| {
            if (try edit.childOf(animation, group)) |map| try m.prune(map, depth);
        }
        var slots = try edit.timelinesOf(animation, "slots");
        while (slots.next()) |slot| try m.downSlot(name, slot.key_ptr.*, try edit.objectOf(slot.value_ptr));
        var bones = try edit.timelinesOf(animation, "bones");
        while (bones.next()) |bone| {
            const map = try edit.objectOf(bone.value_ptr);
            if (try take(map, "rotate")) |keys| {
                const r = try m.resample(try m.channelsOf(keys, .rotate), false, 180);
                try map.put(m.arena, "rotate", try m.emit(r.keys, .{ .names = &.{"angle"}, .defaults = &.{0} }, keys));
            }
            for (pairs, pair_defaults) |pair, d| {
                const whole = try take(map, pair);
                const xs = try take(map, try std.mem.concat(m.arena, u8, &.{ pair, "x" }));
                const ys = try take(map, try std.mem.concat(m.arena, u8, &.{ pair, "y" }));
                var channels: [2]Channel = @splat(.{ .default = d });
                if (whole) |keys| {
                    for (&channels, try m.channelsOf(keys, .{ .pair = d })) |*ch, from| ch.keys = from.keys;
                } else {
                    if (xs == null and ys == null) continue;
                    for ([_]?[]Value{ xs, ys }, &channels) |single, *ch| {
                        if (single) |keys| ch.keys = (try m.channelsOf(keys, .{ .value = d }))[0].keys;
                    }
                }
                const r = try m.resample(&channels, false, std.math.inf(f64));
                try map.put(m.arena, pair, try m.emit(r.keys, .{ .names = &.{ "x", "y" }, .defaults = &.{ d, d } }, &.{}));
            }
        }
        var iks = try edit.timelinesOf(animation, "ik");
        while (iks.next()) |ik| {
            const keys = try edit.keysOf(ik.value_ptr);
            const r = try m.resample(try m.channelsOf(keys, .ik), false, std.math.inf(f64));
            ik.value_ptr.* = try m.emit(r.keys, .{ .names = &.{ "mix", "softness" }, .defaults = &.{ 1, 0 }, .flags = true }, keys);
        }
        var transforms = try edit.timelinesOf(animation, "transform");
        while (transforms.next()) |transform| {
            const keys = try edit.keysOf(transform.value_ptr);
            const channels = try m.channelsOf(keys, .transform);
            if (!channels[1].eql(channels[2]) or !channels[3].eql(channels[4])) {
                const where = try std.fmt.allocPrint(m.arena, "animations.{s}.transform.{s}", .{ name, transform.key_ptr.* });
                try m.lose(.@"transform.mix.approximated", where, "Y mixes differ from X mixes", .{});
            }
            const r = try m.resample(&.{ channels[0], channels[1], channels[3], channels[5] }, false, std.math.inf(f64));
            transform.value_ptr.* = try m.emit(r.keys, .{ .names = &transform_old, .defaults = &.{ 1, 1, 1, 1 } }, keys);
        }
        var paths = try edit.timelinesOf(animation, "path");
        while (paths.next()) |constraint| {
            const map = try edit.objectOf(constraint.value_ptr);
            inline for (.{ "position", "spacing" }) |key| {
                if (try take(map, key)) |keys| {
                    const r = try m.resample(try m.channelsOf(keys, .{ .value = 0 }), false, std.math.inf(f64));
                    try map.put(m.arena, key, try m.emit(r.keys, .{ .names = &.{key}, .defaults = &.{0} }, keys));
                }
            }
            const keys = try take(map, "mix") orelse continue;
            const channels = try m.channelsOf(keys, .path_mix);
            if (!channels[1].eql(channels[2])) {
                const where = try std.fmt.allocPrint(m.arena, "animations.{s}.path.{s}", .{ name, constraint.key_ptr.* });
                try m.lose(.@"path.mix.approximated", where, "mixY differs from mixX", .{});
            }
            const r = try m.resample(channels[0..2], false, std.math.inf(f64));
            try map.put(m.arena, "mix", try m.emit(r.keys, .{ .names = &path_old, .defaults = &.{ 1, 1 } }, keys));
        }
        var skins = try edit.timelinesOf(animation, "deform");
        while (skins.next()) |skin| {
            var deform_slots = (try edit.objectOf(skin.value_ptr)).iterator();
            while (deform_slots.next()) |slot| {
                var attachments = (try edit.objectOf(slot.value_ptr)).iterator();
                while (attachments.next()) |attachment| try m.downDeform(try edit.keysOf(attachment.value_ptr));
            }
        }
    }

    /// Drops timelines without keys which 3.8 cannot load
    fn prune(m: *Migration, map: *ObjectMap, depth: usize) Error!void {
        var empty: std.ArrayList([]const u8) = .empty;
        var it = map.iterator();
        while (it.next()) |entry| {
            const v = entry.value_ptr;
            if (depth > 1) {
                if (v.* == .object) try m.prune(&v.object, depth - 1);
            } else if (v.* == .array and v.array.items.len == 0) try empty.append(m.arena, entry.key_ptr.*);
        }
        for (empty.items) |key| _ = map.orderedRemove(key);
    }

    fn downSlot(m: *Migration, animation: []const u8, slot: []const u8, map: *ObjectMap) Error!void {
        const setup = m.slot_colors.get(slot) orelse 0xffffffff;
        var defaults: [4]f64 = undefined;
        for (&defaults, 0..) |*d, i| d.* = @as(f64, @floatFromInt(setup >> @intCast(24 - i * 8) & 0xff)) / 255;
        const rgba = try take(map, "rgba");
        const rgb = try take(map, "rgb");
        var alpha = try take(map, "alpha");
        const rgba2 = try take(map, "rgba2");
        const rgb2 = try take(map, "rgb2");
        const where = try std.fmt.allocPrint(m.arena, "animations.{s}.slots.{s}", .{ animation, slot });

        if (rgba2 != null or rgb2 != null) {
            var channels: [7]Channel = undefined;
            if (rgba2) |keys| {
                channels = (try m.channelsOf(keys, .rgba2))[0..7].*;
            } else {
                const light = try m.channelsOf(rgb2.?, .rgb2);
                channels = .{ light[0], light[1], light[2], .{}, light[3], light[4], light[5] };
                if (alpha) |keys| channels[3] = (try m.channelsOf(keys, .{ .value = 0 }))[0];
                alpha = null;
            }
            for (channels[0..4], defaults) |*ch, d| ch.default = d;
            const r = try m.resample(&channels, true, std.math.inf(f64));
            if (r.approximated) try m.lose(.@"color.curve.approximated", where, "per channel color curves merged", .{});
            try map.put(m.arena, "twoColor", try m.emit(r.keys, .{ .color = .two }, &.{}));
        }
        if (rgba == null and rgb == null and alpha == null) return;
        var channels: [4]Channel = @splat(.{});
        if (rgba) |keys| channels = (try m.channelsOf(keys, .rgba))[0..4].*;
        if (rgb) |keys| for (channels[0..3], try m.channelsOf(keys, .rgb)) |*ch, from| {
            ch.keys = from.keys;
        };
        if (rgba == null) if (alpha) |keys| {
            channels[3].keys = (try m.channelsOf(keys, .{ .value = 0 }))[0].keys;
        };
        for (&channels, defaults) |*ch, d| ch.default = d;
        const r = try m.resample(&channels, true, std.math.inf(f64));
        if (r.approximated) try m.lose(.@"color.curve.approximated", where, "per channel color curves merged", .{});
        try map.put(m.arena, "color", try m.emit(r.keys, .{ .color = .rgba }, &.{}));
    }

    /// 4.0 deform curves keep values as percent
    fn downDeform(m: *Migration, keys: []Value) Error!void {
        for (keys, 0..) |*key, i| {
            const k = try edit.objectOf(key);
            const curve = edit.take(k, "curve") orelse continue;
            if (i + 1 == keys.len) continue;
            switch (try curveOf(curve, 0, 1, false)) {
                .linear => {},
                .stepped => try k.put(m.arena, "curve", curve),
                .bezier => |c| {
                    const t1 = try finite(key.*, "time", 0);
                    const dt = try finite(keys[i + 1], "time", 0) - t1;
                    if (dt <= 0) continue;
                    var o: tree.Object = .{ .arena = m.arena, .map = k.* };
                    try o.put("curve", .{ .float = (c[0] - t1) / dt });
                    try o.float("c2", @floatCast(c[1]), 0);
                    try o.float("c3", @floatCast((c[2] - t1) / dt), 1);
                    try o.float("c4", @floatCast(c[3]), 1);
                    k.* = o.map;
                },
            }
        }
    }

    fn channelsOf(m: *Migration, keys: []const Value, shape: Shape) Error![]Channel {
        const n = shape.channels();
        const channels = try m.arena.alloc(Channel, n);
        const all = try m.arena.alloc(Key, keys.len * n);
        var values: [7]f64 = undefined;
        for (keys, 0..) |key, i| {
            try readValues(key, shape, values[0..n]);
            const time = try finite(key, "time", 0);
            for (0..n) |c| all[c * keys.len + i] = .{ .time = time, .value = values[c], .curve = try curveOf(tree.get(key, "curve"), c, n, i + 1 == keys.len) };
        }
        for (channels, 0..) |*ch, c| ch.* = .{ .keys = all[c * keys.len ..][0..keys.len] };
        return channels;
    }

    /// Merges channels into keys sharing one curve
    fn resample(m: *Migration, channels: []const Channel, quantized: bool, max_delta: f64) Error!Resampled {
        var times: std.ArrayList(f64) = .empty;
        for (channels) |ch| for (ch.keys) |k| try times.append(m.arena, k.time);
        std.mem.sort(f64, times.items, {}, std.sort.asc(f64));
        var unique: usize = 0;
        for (times.items) |t| {
            if (unique > 0 and times.items[unique - 1] == t) continue;
            times.items[unique] = t;
            unique += 1;
        }
        const keys = times.items[0..unique];

        var result: Resampled = .{ .keys = &.{} };
        var out: std.ArrayList(Out) = .empty;
        var stepped = false;
        for (keys, 0..) |u, j| {
            const right = try m.sample(channels, u, false);
            if (j > 0 and !stepped) {
                const left = try m.sample(channels, u, true);
                if (!std.mem.eql(f64, left, right)) try out.append(m.arena, .{ .time = u, .values = left, .curve = .stepped, .src = srcOf(channels[0], u, false) });
            }
            const src = srcOf(channels[0], u, true);
            if (j + 1 == keys.len) {
                try out.append(m.arena, .{ .time = u, .values = right, .curve = .linear, .src = src });
                break;
            }
            const w = keys[j + 1];
            var p = plan(channels, u, w, max_delta);
            if (p.bake and quantized) {
                result.approximated = true;
                if (p.dominant) |d| p = .{ .curve = .{ .bezier = d } };
            }
            stepped = !p.bake and p.curve == .stepped;
            try out.append(m.arena, .{ .time = u, .values = right, .curve = p.curve, .src = src });
            if (!p.bake) continue;
            var inner: std.ArrayList(f64) = .empty;
            for (channels) |ch| {
                const s = ch.span(u, w) orelse continue;
                if (s[0].curve != .bezier) continue;
                for (samples(s[0], s[1], s[0].curve.bezier)) |point| {
                    if (point[0] > u and point[0] < w) try inner.append(m.arena, point[0]);
                }
            }
            std.mem.sort(f64, inner.items, {}, std.sort.asc(f64));
            for (inner.items, 0..) |t, i| {
                if (i > 0 and inner.items[i - 1] == t) continue;
                try out.append(m.arena, .{ .time = t, .values = try m.sample(channels, t, false), .curve = .linear, .src = src });
            }
        }
        if (max_delta == std.math.inf(f64)) {
            result.keys = out.items;
            return result;
        }
        var split: std.ArrayList(Out) = .empty;
        for (out.items, 0..) |o, i| {
            try split.append(m.arena, o);
            if (o.curve != .linear or i + 1 == out.items.len) continue;
            const next = out.items[i + 1];
            const delta = next.values[0] - o.values[0];
            const dt = next.time - o.time;
            if (@abs(delta) < max_delta or dt <= 0) continue;
            if (@abs(delta) > 1e6) return error.Malformed;
            const count: usize = @intFromFloat(@floor(@abs(delta) / (max_delta - 1)) + 1);
            for (1..count) |k| {
                const f = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count));
                const values = try m.arena.alloc(f64, 1);
                values[0] = o.values[0] + delta * f;
                try split.append(m.arena, .{ .time = o.time + dt * f, .values = values, .curve = .linear, .src = o.src });
            }
        }
        result.keys = split.items;
        return result;
    }

    fn sample(m: *Migration, channels: []const Channel, t: f64, left: bool) Error![]f64 {
        const values = try m.arena.alloc(f64, channels.len);
        for (values, channels) |*v, ch| v.* = ch.at(t, left);
        return values;
    }

    const Layout = struct {
        names: []const []const u8 = &.{},
        defaults: []const f32 = &.{},
        color: enum { none, rgba, two } = .none,
        flags: bool = false,
    };

    fn emit(m: *Migration, out: []const Out, layout: Layout, src: []const Value) Error!Value {
        var keys = try std.json.Array.initCapacity(m.arena, out.len);
        for (out) |o| {
            var k: tree.Object = .init(m.arena);
            try k.float("time", @floatCast(o.time), 0);
            switch (layout.color) {
                .none => for (layout.names, layout.defaults, o.values) |name, d, v| try k.float(name, @floatCast(v), d),
                .rgba => try k.put("color", .{ .string = try hexOf(m.arena, o.values[0..4]) }),
                .two => {
                    try k.put("light", .{ .string = try hexOf(m.arena, o.values[0..4]) });
                    try k.put("dark", .{ .string = (try hexOf(m.arena, &.{ o.values[4], o.values[5], o.values[6], 0 }))[0..6] });
                },
            }
            if (layout.flags) for ([_][]const u8{ "bendPositive", "compress", "stretch" }) |flag| {
                if (tree.get(src[o.src], flag)) |v| try k.put(flag, v);
            };
            switch (o.curve) {
                .linear => {},
                .stepped => try k.put("curve", .{ .string = "stepped" }),
                .bezier => |c| {
                    try k.put("curve", .{ .float = c[0] });
                    try k.float("c2", @floatCast(c[1]), 0);
                    try k.float("c3", @floatCast(c[2]), 1);
                    try k.float("c4", @floatCast(c[3]), 1);
                },
            }
            keys.appendAssumeCapacity(k.value());
        }
        return .{ .array = keys };
    }

    fn renameAll(m: *Migration, map: *ObjectMap, from: []const []const u8, to: []const []const u8) Error!void {
        for (from, to) |f, t| try m.rename(map, f, t);
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

fn mixOf(v: Value, mix: Mix) Error!f32 {
    return tree.getFloat(v, mix.name, if (mix.like) |like| try tree.getFloat(v, like, 1) else 1);
}

fn widen(range: *[2]f32, v: f32) void {
    range[0] = @min(range[0], v);
    range[1] = @max(range[1], v);
}

fn contains(list: []const Value, name: []const u8) bool {
    for (list) |v| if (std.mem.eql(u8, v.string, name)) return true;
    return false;
}

fn take(map: *ObjectMap, key: []const u8) Error!?[]Value {
    const v = edit.take(map, key) orelse return null;
    if (v == .null) return null;
    if (v != .array) return error.Malformed;
    return v.array.items;
}

fn srcOf(ch: Channel, t: f64, inclusive: bool) usize {
    return if (ch.keys.len == 0) 0 else ch.last(t, inclusive);
}

fn curveOf(curve: ?Value, c: usize, n: usize, last: bool) Error!Curve {
    const v = curve orelse return .linear;
    if (last) return .linear;
    switch (v) {
        .string => |s| return if (std.mem.eql(u8, s, "stepped")) .stepped else .linear,
        .array => |a| {
            if (a.items.len < n * 4) return error.Malformed;
            var out: [4]f64 = undefined;
            for (&out, a.items[c * 4 ..][0..4]) |*o, h| o.* = try finiteOf(try tree.number(h));
            return .{ .bezier = out };
        },
        else => return error.Malformed,
    }
}

test "curves and timelines up and down" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Report = .{ .arena = a };
    const old =
        \\{"skeleton":{"hash":"itfFESDjM1rBjm48y5ND1Ud5zqk"},"bones":[{"name":"root"}],
        \\"transform":[{"name":"t","bones":["root"],"target":"root","rotateMix":0.5,"translateMix":0.25}],
        \\"animations":{"a":{"bones":{"root":{"rotate":[{"angle":170,"curve":0.25,"c2":0.5},{"time":1,"angle":-170}]}}}}}
    ;
    var root = try std.json.parseFromSliceLeaky(Value, a, old, .{});
    try up(a, &root, &report, .{});
    try std.testing.expectEqual(0, report.entries.items.len);
    try std.testing.expectEqual(11, root.object.get("skeleton").?.object.get("hash").?.string.len);
    const transform = root.object.get("transform").?.array.items[0].object;
    try std.testing.expectEqual(0.5, try tree.number(transform.get("mixRotate").?));
    try std.testing.expectEqual(0.25, try tree.number(transform.get("mixX").?));
    const rotate = root.object.get("animations").?.object.get("a").?.object.get("bones").?.object.get("root").?.object.get("rotate").?.array.items;
    try std.testing.expectEqual(190, try tree.number(rotate[1].object.get("value").?));
    const curve = rotate[0].object.get("curve").?.array.items;
    for ([_]f32{ 0.25, 180, 1, 190 }, curve) |want, got| try std.testing.expectApproxEqAbs(want, try tree.number(got), 1e-4);

    const new =
        \\{"bones":[{"name":"root"}],"slots":[{"name":"s","bone":"root"}],
        \\"animations":{"a":{"bones":{"root":{"translatex":[{"value":0},{"time":1,"value":10}],
        \\"translatey":[{"value":0,"curve":[0.5,4,0.5,4]},{"time":1,"value":4}]}},
        \\"slots":{"s":{"rgb":[{"color":"ff0000"},{"time":1,"color":"00ff00"}],"alpha":[{"value":1},{"time":1,"value":0}]}}}}}
    ;
    root = try std.json.parseFromSliceLeaky(Value, a, new, .{});
    try down(a, &root, &report, .{});
    try std.testing.expectEqual(0, report.entries.items.len);
    const animation = root.object.get("animations").?.object.get("a").?.object;
    const translate = animation.get("bones").?.object.get("root").?.object.get("translate").?.array.items;
    try std.testing.expectEqual(11, translate.len);
    for (translate) |key| try std.testing.expect(key.object.get("curve") == null);
    try std.testing.expectEqual(4, try tree.number(translate[10].object.get("y").?));
    const color = animation.get("slots").?.object.get("s").?.object.get("color").?.array.items;
    try std.testing.expectEqual(2, color.len);
    try std.testing.expectEqualStrings("ff0000ff", color[0].object.get("color").?.string);
    try std.testing.expectEqualStrings("00ff0000", color[1].object.get("color").?.string);

    var bad = try std.json.parseFromSliceLeaky(Value, a, "{\"animations\":{\"a\":{\"bones\":{\"root\":{\"rotate\":[{\"angle\":\"x\"}]}}}}}", .{});
    try std.testing.expectError(error.Malformed, up(a, &bad, &report, .{}));
}

fn codes(report: *const Report, a: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (report.entries.items) |e| {
        try out.appendSlice(a, @tagName(e.code));
        try out.append(a, ' ');
    }
    return out.items;
}

test "negative world scale mix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { setup: []const u8, keys: []const u8, flags: Flags, code: []const u8 };
    for ([_]Case{
        .{ .setup = "0.5", .keys = "", .flags = .{}, .code = "" },
        .{ .setup = "0.5", .keys = "{\"scaleMix\":0.1,\"curve\":0.25,\"c2\":-3,\"c3\":0.75,\"c4\":-3},{\"time\":1,\"scaleMix\":0.5}", .flags = .{ .rewrite = true }, .code = "transform.scaleMix.approximated " },
        .{ .setup = "0.5", .keys = "{\"scaleMix\":0.1,\"curve\":0.25,\"c2\":-3,\"c3\":0.75,\"c4\":-3},{\"time\":1,\"scaleMix\":0.5}", .flags = .{ .rewrite = true, .slider = true }, .code = "transform.scaleMix.rewritten " },
        .{ .setup = "0.5", .keys = "{\"scaleMix\":-0.1},{\"time\":1}", .flags = .{ .slider = true }, .code = "transform.scaleMix.approximated " },
        .{ .setup = "-0.5", .keys = "{\"scaleMix\":-0.5,\"curve\":0.25,\"c2\":-1,\"c3\":0.75,\"c4\":1.2},{\"time\":1,\"scaleMix\":-0.1}", .flags = .{}, .code = "transform.scaleMix.approximated " },
        .{ .setup = "-0.5", .keys = "{\"scaleMix\":-0.5,\"curve\":0.25,\"c2\":-1,\"c3\":0.75,\"c4\":1.2},{\"time\":1,\"scaleMix\":-0.1}", .flags = .{ .rewrite = true }, .code = "transform.scaleMix.rewritten " },
        .{ .setup = "-0.5", .keys = "{\"scaleMix\":-0.5,\"curve\":0.25,\"c2\":-1,\"c3\":0.75,\"c4\":1.5},{\"time\":1,\"scaleMix\":-0.1}", .flags = .{ .rewrite = true }, .code = "transform.scaleMix.approximated " },
    }) |case| {
        var report: Report = .{ .arena = a };
        const input = try std.fmt.allocPrint(a,
            \\{{"bones":[{{"name":"root"}},{{"name":"b","parent":"root"}}],
            \\"transform":[{{"name":"t","bones":["b"],"target":"root","scaleMix":{s}}}],
            \\"animations":{{"a":{{"transform":{{"t":[{s}]}}}}}}}}
        , .{ case.setup, case.keys });
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try up(a, &root, &report, case.flags);
        try std.testing.expectEqualStrings(case.code, try codes(&report, a));
        const marked = root.object.get("transform").?.array.items[0].object.get(marks.scale_floor) != null;
        try std.testing.expectEqual(case.flags.slider and case.flags.rewrite, marked);
        if (std.mem.endsWith(u8, case.code, "rewritten ") and !marked) {
            try std.testing.expectEqual(0, try tree.number(root.object.get("transform").?.array.items[0].object.get("mixScaleX").?));
            const keys = root.object.get("animations").?.object.get("a").?.object.get("transform").?.object.get("t").?.array.items;
            for (keys) |key| try std.testing.expectEqual(0, try tree.getFloat(key, "mixScaleX", 1));
        }
    }
}

test "order reset rewrite" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skeleton =
        \\{"bones":[{"name":"root"},{"name":"arm","parent":"root"},{"name":"hand","parent":"arm"},{"name":"x","parent":"root"},{"name":"t","parent":"root"}],
    ;
    const Case = struct { constraints: []const u8, flags: Flags, code: []const u8, bones: usize, marked: bool = false };
    for ([_]Case{
        .{ .constraints = "\"transform\":[{\"name\":\"e\",\"bones\":[\"x\",\"hand\"],\"target\":\"t\"},{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\"],\"target\":\"t\"}]}", .flags = .{}, .code = "constraint.order.approximated ", .bones = 2 },
        .{ .constraints = "\"transform\":[{\"name\":\"e\",\"bones\":[\"x\",\"hand\"],\"target\":\"t\"},{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\"],\"target\":\"t\"}]}", .flags = .{ .rewrite = true }, .code = "constraint.order.rewritten ", .bones = 1 },
        .{ .constraints = "\"transform\":[{\"name\":\"e\",\"bones\":[\"hand\"],\"target\":\"t\"},{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\"],\"target\":\"t\"}]}", .flags = .{ .rewrite = true }, .code = "constraint.order.rewritten ", .bones = 0 },
        .{ .constraints = "\"ik\":[{\"name\":\"e\",\"bones\":[\"hand\"],\"target\":\"t\"}],\"transform\":[{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\"],\"target\":\"t\"}]}", .flags = .{ .rewrite = true }, .code = "constraint.order.approximated ", .bones = 1 },
        .{ .constraints = "\"transform\":[{\"name\":\"e\",\"bones\":[\"x\",\"hand\"],\"target\":\"t\"},{\"name\":\"r\",\"order\":1,\"bones\":[\"x\"],\"target\":\"hand\"},{\"name\":\"l\",\"order\":2,\"bones\":[\"arm\"],\"target\":\"t\"}]}", .flags = .{ .rewrite = true }, .code = "constraint.order.approximated ", .bones = 2 },
        .{ .constraints = "\"transform\":[{\"name\":\"e\",\"bones\":[\"x\",\"hand\"],\"target\":\"t\"},{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\"],\"target\":\"t\",\"skin\":true}]}", .flags = .{ .rewrite = true }, .code = "constraint.order.approximated ", .bones = 2 },
        .{ .constraints = "\"slots\":[{\"name\":\"s\",\"bone\":\"t\"}],\"path\":[{\"name\":\"e\",\"bones\":[\"x\",\"hand\"],\"target\":\"s\"}],\"transform\":[{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\"],\"target\":\"t\"}]}", .flags = .{ .rewrite = true }, .code = "constraint.order.rewritten ", .bones = 1 },
        .{ .constraints = "\"slots\":[{\"name\":\"s\",\"bone\":\"t\"}],\"path\":[{\"name\":\"e\",\"bones\":[\"hand\",\"x\"],\"target\":\"s\"}],\"transform\":[{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\"],\"target\":\"t\"}]}", .flags = .{ .rewrite = true }, .code = "constraint.order.approximated ", .bones = 2 },
        .{ .constraints = "\"ik\":[{\"name\":\"e\",\"bones\":[\"hand\"],\"target\":\"t\"}],\"transform\":[{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\"],\"target\":\"t\"}]}", .flags = .{ .rewrite = true, .slider = true }, .code = "constraint.order.rewritten ", .bones = 1, .marked = true },
        .{ .constraints = "\"transform\":[{\"name\":\"e\",\"bones\":[\"x\",\"hand\"],\"target\":\"t\"},{\"name\":\"r\",\"order\":1,\"bones\":[\"x\"],\"target\":\"hand\"},{\"name\":\"l\",\"order\":2,\"bones\":[\"arm\"],\"target\":\"t\"}]}", .flags = .{ .rewrite = true, .slider = true }, .code = "constraint.order.rewritten ", .bones = 2, .marked = true },
        .{ .constraints = "\"ik\":[{\"name\":\"e\",\"bones\":[\"hand\"],\"target\":\"t\"}],\"transform\":[{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\"],\"target\":\"t\",\"skin\":true}]}", .flags = .{ .rewrite = true, .slider = true }, .code = "constraint.order.approximated ", .bones = 1 },
        .{ .constraints = "\"ik\":[{\"name\":\"e\",\"bones\":[\"hand\"],\"target\":\"t\"}],\"transform\":[{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\",\"hand\"],\"target\":\"t\"}]}", .flags = .{ .rewrite = true, .slider = true }, .code = "", .bones = 1 },
        .{ .constraints = "\"ik\":[{\"name\":\"e\",\"bones\":[\"hand\"],\"target\":\"t\"}],\"transform\":[{\"name\":\"l\",\"order\":1,\"bones\":[\"arm\",\"x\"],\"target\":\"t\"}]}", .flags = .{ .rewrite = true, .slider = true }, .code = "constraint.order.rewritten ", .bones = 1, .marked = true },
    }) |case| {
        var report: Report = .{ .arena = a };
        var root = try std.json.parseFromSliceLeaky(Value, a, try std.mem.concat(a, u8, &.{ skeleton, case.constraints }), .{});
        try up(a, &root, &report, case.flags);
        try std.testing.expectEqualStrings(case.code, try codes(&report, a));
        const list = root.object.get("ik") orelse root.object.get("path") orelse root.object.get("transform").?;
        const first = list.array.items[0];
        try std.testing.expectEqual(case.bones, (try tree.getArray(first, "bones")).len);
        const later = root.object.get("transform").?.array.items;
        try std.testing.expectEqual(case.marked, later[later.len - 1].object.get(marks.restore) != null);
    }
}

test "two bone IK at mix 0 and relative rotation range" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { json: []const u8, code: []const u8 };
    const ik =
        \\{"bones":[{"name":"root"},{"name":"u","parent":"root"},{"name":"l","parent":"u"},{"name":"t","parent":"root"}],
        \\"ik":[{"name":"i","order":1,"bones":["u","l"],"target":"t"
    ;
    const rel =
        \\{"bones":[{"name":"root"},{"name":"b","parent":"root"},{"name":"t","parent":"root"}],
        \\"transform":[{"name":"r","bones":["b"],"target":"t","local":true,"relative":true
    ;
    for ([_]Case{
        .{ .json = ik ++ ",\"mix\":0}],\"transform\":[{\"name\":\"e\",\"bones\":[\"l\"],\"target\":\"t\"}]}", .code = "ik.reset.approximated " },
        .{ .json = ik ++ "}],\"transform\":[{\"name\":\"e\",\"bones\":[\"l\"],\"target\":\"t\"}],\"animations\":{\"a\":{\"ik\":{\"i\":[{\"mix\":0}]}}}}", .code = "ik.reset.approximated " },
        .{ .json = ik ++ ",\"mix\":0}],\"transform\":[{\"name\":\"e\",\"order\":2,\"bones\":[\"l\"],\"target\":\"t\"}]}", .code = "" },
        .{ .json = ik ++ "}],\"transform\":[{\"name\":\"e\",\"bones\":[\"l\"],\"target\":\"t\"}]}", .code = "" },
        .{ .json = rel ++ ",\"rotateMix\":0.5}],\"animations\":{\"a\":{\"bones\":{\"t\":{\"rotate\":[{\"angle\":0},{\"time\":0.5,\"angle\":170},{\"time\":1,\"angle\":-20}]}}}}}", .code = "transform.rotateRange.approximated " },
        .{ .json = rel ++ "}],\"animations\":{\"a\":{\"bones\":{\"t\":{\"rotate\":[{\"angle\":0},{\"time\":0.5,\"angle\":170},{\"time\":1,\"angle\":-20}]}}}}}", .code = "" },
        .{ .json = rel ++ ",\"rotateMix\":0.5}],\"animations\":{\"a\":{\"bones\":{\"t\":{\"rotate\":[{\"angle\":0},{\"time\":1,\"angle\":170}]}}}}}", .code = "" },
        .{ .json = rel ++ "}],\"animations\":{\"a\":{\"transform\":{\"r\":[{\"rotateMix\":0},{\"time\":1}]},\"bones\":{\"t\":{\"rotate\":[{\"angle\":190}]}}}}}", .code = "transform.rotateRange.approximated " },
    }) |case| {
        var report: Report = .{ .arena = a };
        var root = try std.json.parseFromSliceLeaky(Value, a, case.json, .{});
        try up(a, &root, &report, .{});
        try std.testing.expectEqualStrings(case.code, try codes(&report, a));
    }
}

test "two bone IK at mix 0 restores the child" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { bone: []const u8, ik: []const u8, tail: []const u8, flags: Flags, code: []const u8 };
    const plain = "{\"name\":\"l\",\"parent\":\"u\"}";
    for ([_]Case{
        .{ .bone = plain, .ik = ",\"mix\":0", .tail = "", .flags = .{ .rewrite = true }, .code = "ik.reset.approximated " },
        .{ .bone = plain, .ik = ",\"mix\":0", .tail = "", .flags = .{ .rewrite = true, .slider = true }, .code = "ik.reset.rewritten " },
        .{ .bone = plain, .ik = ",\"mix\":0", .tail = ",\"animations\":{\"a\":{\"ik\":{\"i\":[{\"mix\":0},{\"time\":1,\"mix\":0}]}}}", .flags = .{ .rewrite = true, .slider = true }, .code = "ik.reset.rewritten " },
        .{ .bone = plain, .ik = ",\"mix\":0", .tail = ",\"animations\":{\"a\":{\"ik\":{\"i\":[{\"mix\":0},{\"time\":1}]}}}", .flags = .{ .rewrite = true, .slider = true }, .code = "ik.reset.rewritten " },
        .{ .bone = plain, .ik = ",\"mix\":0,\"skin\":true", .tail = "", .flags = .{ .rewrite = true, .slider = true }, .code = "ik.reset.approximated " },
        .{ .bone = "{\"name\":\"l\",\"parent\":\"u\",\"shearX\":5}", .ik = ",\"mix\":0", .tail = "", .flags = .{ .rewrite = true, .slider = true }, .code = "ik.reset.approximated " },
        .{ .bone = "{\"name\":\"l\",\"parent\":\"u\",\"scaleX\":0}", .ik = ",\"mix\":0", .tail = "", .flags = .{ .rewrite = true, .slider = true }, .code = "ik.reset.approximated " },
        .{ .bone = plain, .ik = ",\"mix\":0", .tail = ",\"animations\":{\"a\":{\"bones\":{\"l\":{\"scale\":[{\"x\":1},{\"time\":1,\"x\":-1}]}}}}", .flags = .{ .rewrite = true, .slider = true }, .code = "ik.reset.approximated " },
    }) |case| {
        var report: Report = .{ .arena = a };
        const input = try std.fmt.allocPrint(a,
            \\{{"bones":[{{"name":"root"}},{{"name":"u","parent":"root"}},{s},{{"name":"t","parent":"root"}}],
            \\"ik":[{{"name":"i","order":1,"bones":["u","l"],"target":"t"{s}}}],
            \\"transform":[{{"name":"e","bones":["l"],"target":"t"}}]{s}}}
        , .{ case.bone, case.ik, case.tail });
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try up(a, &root, &report, case.flags);
        try std.testing.expectEqualStrings(case.code, try codes(&report, a));
        const marked = root.object.get("ik").?.array.items[0].object.get(marks.restore) != null;
        try std.testing.expectEqual(std.mem.eql(u8, case.code, "ik.reset.rewritten "), marked);
        const gated = root.object.get("ik").?.array.items[0].object.get(marks.restore_gate) != null;
        try std.testing.expectEqual(marked and case.tail.len > 0 and std.mem.indexOf(u8, case.tail, "\"time\":1}") != null, gated);
    }
}

test "negative path mix in a Bezier control" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skeleton =
        \\{"bones":[{"name":"root"}],"slots":[{"name":"s","bone":"root"}],"path":[{"name":"p","bones":["root"],"target":"s","spacingMode":"percent"}],
    ;
    var report: Report = .{ .arena = a };
    var root = try std.json.parseFromSliceLeaky(Value, a, skeleton ++
        \\"animations":{"a":{"path":{"p":{"mix":[{"rotateMix":0,"translateMix":0.2,"curve":0.25,"c2":-2,"c3":0.75,"c4":1},{"time":1,"translateMix":0.6}]}}}}}
    , .{});
    try up(a, &root, &report, .{});
    try std.testing.expectEqualStrings("path.negative.approximated ", try codes(&report, a));
    report = .{ .arena = a };
    root = try std.json.parseFromSliceLeaky(Value, a, skeleton ++
        \\"animations":{"a":{"path":{"p":{"mix":[{"mixRotate":0,"mixX":0.2,"curve":[0,0,0,0,0.25,-1,0.75,1,0,0,0,0]},{"time":1,"mixX":0.6}]}}}}}
    , .{});
    try down(a, &root, &report, .{});
    try std.testing.expectEqualStrings("path.negative.approximated path.mix.approximated ", try codes(&report, a));
}

test "4.0 beta exports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skeleton =
        \\"bones":[{"name":"root"},{"name":"arm","parent":"root","length":10},{"name":"hand","parent":"arm","y":5,"scaleX":2},{"name":"z","parent":"root"},{"name":"t","parent":"root"}],
        \\"slots":[{"name":"s","bone":"root"}],
        \\"ik":[{"name":"i","order":2,"bones":["arm","hand"],"target":"t","stretch":true,"uniform":true}],
        \\"transform":[{"name":"e","bones":["z","hand"],"target":"t"},{"name":"l","order":1,"bones":["arm"],"target":"t"},
        \\{"name":"r","order":3,"bones":["hand"],"target":"t","local":true,"relative":true}],
        \\"path":[{"name":"p","order":4,"bones":["z","t"],"target":"s","spacing":5}],
        \\"animations":{"a":{"transform":{"l":[{"mixShearY":1},{"time":1,"mixShearY":0}]}}}}
    ;
    const Case = struct { version: []const u8, target: Version.Minor, flags: Flags, code: []const u8, uniform: bool };
    const v4_0: Version.Minor = .{ .major = 4, .minor = 0 };
    const v4_3: Version.Minor = .{ .major = 4, .minor = 3 };
    for ([_]Case{
        .{ .version = "4.0.31-beta", .target = v4_3, .flags = .{}, .code = "constraint.order.approximated ik.stretch.approximated transform.relativeScale.approximated path.spacing.approximated ", .uniform = false },
        .{ .version = "4.0.59-beta", .target = v4_0, .flags = .{ .rewrite = true }, .code = "constraint.order.rewritten ik.stretch.approximated transform.relativeScale.approximated ", .uniform = false },
        .{ .version = "4.0.74-beta", .target = v4_3, .flags = .{}, .code = "constraint.order.approximated transform.relativeScale.approximated ", .uniform = true },
        .{ .version = "4.0.26", .target = v4_3, .flags = .{}, .code = "transform.relativeScale.approximated ", .uniform = true },
        .{ .version = "4.0.31", .target = v4_0, .flags = .{}, .code = "", .uniform = true },
        .{ .version = "4.0.31", .target = v4_3, .flags = .{}, .code = "", .uniform = true },
    }) |case| {
        var report: Report = .{ .arena = a };
        const input = try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"{s}\"}},{s}", .{ case.version, skeleton });
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try early(a, &root, &report, case.target, case.flags);
        try std.testing.expectEqualStrings(case.code, try codes(&report, a));
        try std.testing.expectEqual(case.uniform, root.object.get("ik").?.array.items[0].object.get("uniform") != null);
    }
}

test "down from 4.0 betas" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skeleton =
        \\"bones":[{"name":"root"},{"name":"arm","parent":"root","length":10},{"name":"hand","parent":"arm","y":5,"scaleX":2},{"name":"z","parent":"root"},{"name":"t","parent":"root"}],
        \\"slots":[{"name":"s","bone":"root"}],
        \\"ik":[{"name":"i","order":2,"bones":["arm","hand"],"target":"t","stretch":true,"uniform":true}],
        \\"transform":[{"name":"e","bones":["z","hand"],"target":"t"},{"name":"l","order":1,"bones":["arm"],"target":"t"},
        \\{"name":"r","order":3,"bones":["hand"],"target":"t","local":true,"relative":true}],
        \\"path":[{"name":"p","order":4,"bones":["z","t"],"target":"s","spacing":5,"spacingMode":"percent"}]}
    ;
    const Case = struct { version: []const u8, code: []const u8 };
    for ([_]Case{
        .{ .version = "4.0.31-beta", .code = "path.spacing.approximated transform.relativeScale.approximated " },
        .{ .version = "4.0.74-beta", .code = "ik.stretch.approximated ik.uniform.dropped transform.relativeScale.approximated " },
        .{ .version = "4.0.31", .code = "ik.stretch.approximated ik.uniform.dropped constraint.order.approximated " },
    }) |case| {
        var report: Report = .{ .arena = a };
        const input = try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"{s}\"}},{s}", .{ case.version, skeleton });
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try down(a, &root, &report, .{});
        try std.testing.expectEqualStrings(case.code, try codes(&report, a));
    }
}

test "six digit two color light" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Report = .{ .arena = a };
    const old =
        \\{"bones":[{"name":"root"}],"slots":[{"name":"s","bone":"root","dark":"000000"}],
        \\"animations":{"a":{"slots":{"s":{"twoColor":[{"light":"ff8000","dark":"102030"},{"time":1,"light":"00ff0080","dark":"000000"}]}}}}}
    ;
    var root = try std.json.parseFromSliceLeaky(Value, a, old, .{});
    try up(a, &root, &report, .{});
    const keys = root.object.get("animations").?.object.get("a").?.object.get("slots").?.object.get("s").?.object.get("rgba2").?.array.items;
    try std.testing.expectEqualStrings("ff8000ff", keys[0].object.get("light").?.string);
    try std.testing.expectEqualStrings("00ff0080", keys[1].object.get("light").?.string);
}

/// A scale key and its handles cannot reach 0
fn positive(key: Value, field: []const u8, channel: usize) Error!bool {
    if (try tree.getFloat(key, field, 1) <= 0) return false;
    const curve = tree.get(key, "curve") orelse return true;
    switch (curve) {
        .array => |items| for ([_]usize{ 1, 3 }) |i| {
            if (channel * 4 + i >= items.items.len) return error.Malformed;
            if (try tree.number(items.items[channel * 4 + i]) <= 0) return false;
        },
        .string => {},
        else => for ([_][]const u8{ "c2", "c4" }, [_]f32{ 0, 1 }) |name, default| {
            const handle = try tree.getFloat(key, name, default);
            if (handle < 0 or handle > 1) return false;
        },
    }
    return true;
}

/// Keys and their Bézier handles keep the sign of setup
fn sameSign(keys: []const Value, field: []const u8, channel: usize, setup: f32) Error!bool {
    for (keys) |key| {
        if (try tree.getFloat(key, field, 1) * setup <= 0) return false;
        const curve = tree.get(key, "curve") orelse continue;
        if (curve != .array) continue;
        for ([_]usize{ 1, 3 }) |i| {
            if (channel * 4 + i >= curve.array.items.len) return error.Malformed;
            if (try tree.number(curve.array.items[channel * 4 + i]) * setup <= 0) return false;
        }
    }
    return true;
}

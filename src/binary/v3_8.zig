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

//! Spine 3.8 binary, ported from SkeletonBinary.java of the 3.8 branch

const std = @import("std");
const Value = std.json.Value;
const Document = @import("../Document.zig");
const Report = @import("../Report.zig");
const Version = @import("../Version.zig");
const Reader = @import("Reader.zig");
const Writer = @import("Writer.zig");
const tree = @import("tree.zig");
const Object = tree.Object;

pub const Error = error{ Malformed, OutOfMemory };

const transform_names = [_][]const u8{ "normal", "onlyTranslation", "noRotationOrReflection", "noScale", "noScaleOrReflection" };
const blend_names = [_][]const u8{ "normal", "additive", "multiply", "screen" };
const position_names = [_][]const u8{ "fixed", "percent" };
const spacing_names = [_][]const u8{ "length", "fixed", "percent" };
const rotate_names = [_][]const u8{ "tangent", "chain", "chainScale" };
const attachment_type_names = [_][]const u8{ "region", "boundingbox", "mesh", "linkedmesh", "path", "point", "clipping" };
const slot_timeline_names = [_][]const u8{ "attachment", "color", "twoColor" };
const bone_timeline_names = [_][]const u8{ "rotate", "translate", "scale", "shear" };
const path_timeline_names = [_][]const u8{ "position", "spacing", "mix" };

/// Tag names are the JSON keys of each constraint list
const ConstraintKind = enum { ik, transform, path };
const constraint_kinds = [_]ConstraintKind{ .ik, .transform, .path };

const bone_color = 0x9b9b9bff;
const white = 0xffffffff;

const curve_linear = 0;
const curve_stepped = 1;
const curve_bezier = 2;

pub fn decode(arena: std.mem.Allocator, data: []const u8, version: Version, report: *Report) Error!Document {
    _ = report;
    var d: Decoder = .{ .arena = arena, .r = .{ .data = data }, .ik_softness = Version.editor(version, .ik_frames_3825) != .old };
    const root = d.skeletonData() catch |e| return switch (e) {
        error.EndOfData => error.Malformed,
        else => |other| other,
    };
    return .{ .version = version, .origin = .binary, .root = root };
}

const Event = struct {
    int: i32,
    float: f32,
    audio: bool,
    volume: f32,
    balance: f32,
    name: []const u8,
};

const Shape = union(enum) {
    value: struct { []const u8, f32 },
    pair: f32,
    color,
    two_color,
    ik,
    transform,
    path_mix,
    deform,
};

const Decoder = struct {
    arena: std.mem.Allocator,
    r: Reader,
    nonessential: bool = false,
    /// 3.8.25-beta IK keys omit softness
    ik_softness: bool = true,
    strings: []const ?[]const u8 = &.{},
    bones: []const []const u8 = &.{},
    slots: []const []const u8 = &.{},
    constraints: [constraint_kinds.len][]const []const u8 = @splat(&.{}),
    skins: []const []const u8 = &.{},
    events: []const Event = &.{},

    const E = Error || Reader.Error;

    fn skeletonData(d: *Decoder) E!Value {
        var root: Object = .init(d.arena);
        var skeleton: Object = .init(d.arena);
        if (try d.r.string()) |hash| if (hash.len > 0) try skeleton.put("hash", .{ .string = hash });
        if (try d.r.string()) |version| if (version.len > 0) try skeleton.put("spine", .{ .string = version });
        for ([_][]const u8{ "x", "y", "width", "height" }) |key| try skeleton.put(key, .{ .float = try d.r.float() });
        d.nonessential = try d.r.boolean();
        if (d.nonessential) {
            try skeleton.float("fps", try d.r.float(), 30);
            try skeleton.put("images", try d.nullable(try d.r.string()));
            try skeleton.put("audio", try d.nullable(try d.r.string()));
        }
        try root.put("skeleton", skeleton.value());

        const strings = try d.arena.alloc(?[]const u8, try d.count());
        for (strings) |*s| s.* = try d.r.string();
        d.strings = strings;

        try root.put("bones", try d.readBones());
        try root.put("slots", try d.readSlots());
        for (constraint_kinds) |kind| try d.readConstraints(&root, kind);

        var skins = tree.array(d.arena);
        var skin_names: std.ArrayList([]const u8) = .empty;
        const default_slots = try d.count();
        if (default_slots > 0) {
            try skin_names.append(d.arena, "default");
            try skins.append(try d.readSkin("default", default_slots));
        }
        for (0..try d.count()) |_| {
            const skin_name = try d.stringRef() orelse return error.Malformed;
            try skin_names.append(d.arena, skin_name);
            try skins.append(try d.readSkin(skin_name, null));
        }
        d.skins = skin_names.items;

        var events: Object = .init(d.arena);
        const event_data = try d.arena.alloc(Event, try d.count());
        for (event_data) |*e| {
            e.name = try d.stringRef() orelse return error.Malformed;
            e.int = try d.r.varint(false);
            e.float = try d.r.float();
            var event: Object = .init(d.arena);
            try event.int("int", e.int, 0);
            try event.float("float", e.float, 0);
            if (try d.r.string()) |s| if (s.len > 0) try event.put("string", .{ .string = s });
            const audio = try d.r.string();
            e.audio = audio != null;
            e.volume = 1;
            e.balance = 0;
            if (audio) |audio_path| {
                e.volume = try d.r.float();
                e.balance = try d.r.float();
                try event.put("audio", .{ .string = audio_path });
                try event.float("volume", e.volume, 1);
                try event.float("balance", e.balance, 0);
            }
            try events.put(e.name, event.value());
        }
        d.events = event_data;

        var animations: Object = .init(d.arena);
        for (0..try d.count()) |_| {
            const animation_name = try d.requiredString();
            try animations.put(animation_name, try d.readAnimation());
        }

        if (skins.items.len > 0) try root.put("skins", .{ .array = skins });
        if (events.map.count() > 0) try root.put("events", events.value());
        if (animations.map.count() > 0) try root.put("animations", animations.value());
        if (d.r.pos != d.r.data.len) return error.Malformed;
        return root.value();
    }

    fn readBones(d: *Decoder) E!Value {
        var values = tree.array(d.arena);
        const names = try d.arena.alloc([]const u8, try d.count());
        for (names, 0..) |*bone_name, i| {
            bone_name.* = try d.requiredString();
            var bone: Object = .init(d.arena);
            try bone.put("name", .{ .string = bone_name.* });
            if (i > 0) try bone.put("parent", .{ .string = try d.pick(names[0..i]) });
            const rotation = try d.r.float();
            const x = try d.r.float();
            const y = try d.r.float();
            const scale_x = try d.r.float();
            const scale_y = try d.r.float();
            const shear_x = try d.r.float();
            const shear_y = try d.r.float();
            try bone.float("length", try d.r.float(), 0);
            try bone.float("rotation", rotation, 0);
            try bone.float("x", x, 0);
            try bone.float("y", y, 0);
            try bone.float("scaleX", scale_x, 1);
            try bone.float("scaleY", scale_y, 1);
            try bone.float("shearX", shear_x, 0);
            try bone.float("shearY", shear_y, 0);
            const transform = try d.enumName(&transform_names, try d.unsigned());
            if (!std.mem.eql(u8, transform, "normal")) try bone.put("transform", .{ .string = transform });
            try bone.boolean("skin", try d.r.boolean(), false);
            if (d.nonessential) try bone.color("color", try d.r.int(u32), bone_color);
            try values.append(bone.value());
        }
        d.bones = names;
        return .{ .array = values };
    }

    fn readSlots(d: *Decoder) E!Value {
        var values = tree.array(d.arena);
        const names = try d.arena.alloc([]const u8, try d.count());
        for (names) |*slot_name| {
            slot_name.* = try d.requiredString();
            var slot: Object = .init(d.arena);
            try slot.put("name", .{ .string = slot_name.* });
            try slot.put("bone", .{ .string = try d.pick(d.bones) });
            try slot.color("color", try d.r.int(u32), white);
            const dark = try d.r.int(i32);
            if (dark != -1) try slot.put("dark", .{ .string = try tree.hex(d.arena, @as(u32, @bitCast(dark)) & 0xffffff, 6) });
            try slot.string("attachment", try d.stringRef());
            const blend = try d.enumName(&blend_names, try d.unsigned());
            if (!std.mem.eql(u8, blend, "normal")) try slot.put("blend", .{ .string = blend });
            try values.append(slot.value());
        }
        d.slots = names;
        return .{ .array = values };
    }

    fn readConstraints(d: *Decoder, root: *Object, kind: ConstraintKind) E!void {
        var values = tree.array(d.arena);
        const names = try d.arena.alloc([]const u8, try d.count());
        for (names) |*constraint_name| {
            constraint_name.* = try d.requiredString();
            var c: Object = .init(d.arena);
            try c.put("name", .{ .string = constraint_name.* });
            try c.int("order", try d.unsigned(), 0);
            try c.boolean("skin", try d.r.boolean(), false);
            try c.put("bones", try d.pickList(d.bones));
            try c.put("target", .{ .string = try d.pick(if (kind == .path) d.slots else d.bones) });
            switch (kind) {
                .ik => {
                    try c.float("mix", try d.r.float(), 1);
                    try c.float("softness", try d.r.float(), 0);
                    try c.boolean("bendPositive", try d.bendPositive(), true);
                    try c.boolean("compress", try d.r.boolean(), false);
                    try c.boolean("stretch", try d.r.boolean(), false);
                    try c.boolean("uniform", try d.r.boolean(), false);
                },
                .transform => {
                    try c.boolean("local", try d.r.boolean(), false);
                    try c.boolean("relative", try d.r.boolean(), false);
                    for ([_][]const u8{ "rotation", "x", "y", "scaleX", "scaleY", "shearY" }) |key| try c.float(key, try d.r.float(), 0);
                    for ([_][]const u8{ "rotateMix", "translateMix", "scaleMix", "shearMix" }) |key| try c.float(key, try d.r.float(), 1);
                },
                .path => {
                    const position_mode = try d.enumName(&position_names, try d.unsigned());
                    const spacing_mode = try d.enumName(&spacing_names, try d.unsigned());
                    const rotate_mode = try d.enumName(&rotate_names, try d.unsigned());
                    if (!std.mem.eql(u8, position_mode, "percent")) try c.put("positionMode", .{ .string = position_mode });
                    if (!std.mem.eql(u8, spacing_mode, "length")) try c.put("spacingMode", .{ .string = spacing_mode });
                    if (!std.mem.eql(u8, rotate_mode, "tangent")) try c.put("rotateMode", .{ .string = rotate_mode });
                    for ([_][]const u8{ "rotation", "position", "spacing" }) |key| try c.float(key, try d.r.float(), 0);
                    for ([_][]const u8{ "rotateMix", "translateMix" }) |key| try c.float(key, try d.r.float(), 1);
                },
            }
            try values.append(c.value());
        }
        d.constraints[@backingInt(kind)] = names;
        if (values.items.len > 0) try root.put(@tagName(kind), .{ .array = values });
    }

    fn readSkin(d: *Decoder, skin_name: []const u8, default_slots: ?usize) E!Value {
        var skin: Object = .init(d.arena);
        try skin.put("name", .{ .string = skin_name });
        const slot_count = default_slots orelse slots: {
            const bones = try d.pickList(d.bones);
            if (bones.array.items.len > 0) try skin.put("bones", bones);
            for (constraint_kinds) |kind| {
                const list = try d.pickList(d.constraints[@backingInt(kind)]);
                if (list.array.items.len > 0) try skin.put(@tagName(kind), list);
            }
            break :slots try d.count();
        };
        var attachments: Object = .init(d.arena);
        for (0..slot_count) |_| {
            const slot_name = try d.pick(d.slots);
            var slot: Object = .init(d.arena);
            for (0..try d.count()) |_| {
                const placeholder = try d.stringRef() orelse return error.Malformed;
                try slot.put(placeholder, try d.readAttachment(placeholder));
            }
            try attachments.put(slot_name, slot.value());
        }
        // the official 3.8 JSON loader crashes without it
        try skin.put("attachments", attachments.value());
        return skin.value();
    }

    fn readAttachment(d: *Decoder, placeholder: []const u8) E!Value {
        var a: Object = .init(d.arena);
        const attachment_name = try d.stringRef() orelse placeholder;
        if (!std.mem.eql(u8, attachment_name, placeholder)) try a.put("name", .{ .string = attachment_name });
        const kind = try d.r.byte();
        const type_name = try d.enumName(&attachment_type_names, kind);
        if (kind != 0) try a.put("type", .{ .string = type_name });
        switch (kind) {
            0 => {
                try d.path(&a, attachment_name);
                try a.float("rotation", try d.r.float(), 0);
                try a.float("x", try d.r.float(), 0);
                try a.float("y", try d.r.float(), 0);
                try a.float("scaleX", try d.r.float(), 1);
                try a.float("scaleY", try d.r.float(), 1);
                try a.put("width", .{ .float = try d.r.float() });
                try a.put("height", .{ .float = try d.r.float() });
                try a.color("color", try d.r.int(u32), white);
            },
            1 => {
                const vertex_count = try d.count();
                try a.put("vertexCount", .{ .integer = @intCast(vertex_count) });
                try a.put("vertices", try d.readVertices(vertex_count));
                if (d.nonessential) try a.color("color", try d.r.int(u32), 0x60f000ff);
            },
            2 => {
                try d.path(&a, attachment_name);
                try a.color("color", try d.r.int(u32), white);
                const vertex_count = try d.count();
                try a.put("uvs", try d.floats(vertex_count * 2));
                try a.put("triangles", try d.shorts());
                try a.put("vertices", try d.readVertices(vertex_count));
                try a.put("hull", .{ .integer = try d.unsigned() });
                if (d.nonessential) {
                    try a.put("edges", try d.shorts());
                    try a.float("width", try d.r.float(), 0);
                    try a.float("height", try d.r.float(), 0);
                }
            },
            3 => {
                try d.path(&a, attachment_name);
                try a.color("color", try d.r.int(u32), white);
                try a.string("skin", try d.stringRef());
                try a.put("parent", .{ .string = try d.stringRef() orelse return error.Malformed });
                try a.boolean("deform", try d.r.boolean(), true);
                if (d.nonessential) {
                    try a.float("width", try d.r.float(), 0);
                    try a.float("height", try d.r.float(), 0);
                }
            },
            4 => {
                try a.boolean("closed", try d.r.boolean(), false);
                try a.boolean("constantSpeed", try d.r.boolean(), true);
                const vertex_count = try d.count();
                try a.put("vertexCount", .{ .integer = @intCast(vertex_count) });
                try a.put("vertices", try d.readVertices(vertex_count));
                try a.put("lengths", try d.floats(vertex_count / 3));
                if (d.nonessential) try a.color("color", try d.r.int(u32), 0xff7f00ff);
            },
            5 => {
                try a.float("rotation", try d.r.float(), 0);
                try a.float("x", try d.r.float(), 0);
                try a.float("y", try d.r.float(), 0);
                if (d.nonessential) try a.color("color", try d.r.int(u32), 0xf1f100ff);
            },
            6 => {
                try a.put("end", .{ .string = try d.pick(d.slots) });
                const vertex_count = try d.count();
                try a.put("vertexCount", .{ .integer = @intCast(vertex_count) });
                try a.put("vertices", try d.readVertices(vertex_count));
                if (d.nonessential) try a.color("color", try d.r.int(u32), 0x3a3aceff);
            },
            else => unreachable,
        }
        return a.value();
    }

    fn path(d: *Decoder, a: *Object, attachment_name: []const u8) E!void {
        const p = try d.stringRef() orelse return;
        if (!std.mem.eql(u8, p, attachment_name)) try a.put("path", .{ .string = p });
    }

    fn readVertices(d: *Decoder, vertex_count: usize) E!Value {
        if (!try d.r.boolean()) return d.floats(vertex_count * 2);
        var values = tree.array(d.arena);
        for (0..vertex_count) |_| {
            const bone_count = try d.count();
            try values.append(.{ .integer = @intCast(bone_count) });
            for (0..bone_count) |_| {
                try values.append(.{ .integer = try d.unsigned() });
                for (0..3) |_| try values.append(.{ .float = try d.r.float() });
            }
        }
        return .{ .array = values };
    }

    fn readAnimation(d: *Decoder) E!Value {
        var animation: Object = .init(d.arena);

        var slots: Object = .init(d.arena);
        for (0..try d.count()) |_| {
            const slot_name = try d.pick(d.slots);
            var timelines: Object = .init(d.arena);
            for (0..try d.count()) |_| {
                const kind = try d.r.byte();
                const timeline_name = try d.enumName(&slot_timeline_names, kind);
                const frame_count = try d.count();
                try timelines.put(timeline_name, switch (kind) {
                    0 => attachments: {
                        var keys = tree.array(d.arena);
                        for (0..frame_count) |_| {
                            var key: Object = .init(d.arena);
                            try key.float("time", try d.r.float(), 0);
                            try key.put("name", try d.nullable(try d.stringRef()));
                            try keys.append(key.value());
                        }
                        break :attachments .{ .array = keys };
                    },
                    1 => try d.frames(frame_count, .color),
                    2 => try d.frames(frame_count, .two_color),
                    else => unreachable,
                });
            }
            try slots.put(slot_name, timelines.value());
        }
        if (slots.map.count() > 0) try animation.put("slots", slots.value());

        var bones: Object = .init(d.arena);
        for (0..try d.count()) |_| {
            const bone_name = try d.pick(d.bones);
            var timelines: Object = .init(d.arena);
            for (0..try d.count()) |_| {
                const kind = try d.r.byte();
                const timeline_name = try d.enumName(&bone_timeline_names, kind);
                const frame_count = try d.count();
                try timelines.put(timeline_name, try d.frames(frame_count, switch (kind) {
                    0 => .{ .value = .{ "angle", 0 } },
                    2 => .{ .pair = 1 },
                    else => .{ .pair = 0 },
                }));
            }
            try bones.put(bone_name, timelines.value());
        }
        if (bones.map.count() > 0) try animation.put("bones", bones.value());

        for ([_]ConstraintKind{ .ik, .transform }) |kind| {
            var constraints: Object = .init(d.arena);
            for (0..try d.count()) |_| {
                const constraint_name = try d.pick(d.constraints[@backingInt(kind)]);
                try constraints.put(constraint_name, try d.frames(try d.count(), if (kind == .ik) .ik else .transform));
            }
            if (constraints.map.count() > 0) try animation.put(@tagName(kind), constraints.value());
        }

        var paths: Object = .init(d.arena);
        for (0..try d.count()) |_| {
            const constraint_name = try d.pick(d.constraints[@backingInt(ConstraintKind.path)]);
            var timelines: Object = .init(d.arena);
            for (0..try d.count()) |_| {
                const kind = try d.r.byte();
                const timeline_name = try d.enumName(&path_timeline_names, kind);
                const frame_count = try d.count();
                const shape: Shape = if (kind == 2) .path_mix else .{ .value = .{ timeline_name, 0 } };
                try timelines.put(timeline_name, try d.frames(frame_count, shape));
            }
            try paths.put(constraint_name, timelines.value());
        }
        if (paths.map.count() > 0) try animation.put("path", paths.value());

        var deform: Object = .init(d.arena);
        for (0..try d.count()) |_| {
            const skin_name = try d.pick(d.skins);
            var skin: Object = .init(d.arena);
            for (0..try d.count()) |_| {
                const slot_name = try d.pick(d.slots);
                var slot: Object = .init(d.arena);
                for (0..try d.count()) |_| {
                    const attachment_name = try d.stringRef() orelse return error.Malformed;
                    try slot.put(attachment_name, try d.frames(try d.count(), .deform));
                }
                try skin.put(slot_name, slot.value());
            }
            try deform.put(skin_name, skin.value());
        }
        if (deform.map.count() > 0) try animation.put("deform", deform.value());

        const draw_order_count = try d.count();
        if (draw_order_count > 0) {
            var keys = tree.array(d.arena);
            for (0..draw_order_count) |_| {
                var key: Object = .init(d.arena);
                try key.float("time", try d.r.float(), 0);
                const change_count = try d.count();
                if (change_count > 0) {
                    var offsets = tree.array(d.arena);
                    for (0..change_count) |_| {
                        var offset: Object = .init(d.arena);
                        try offset.put("slot", .{ .string = try d.pick(d.slots) });
                        try offset.put("offset", .{ .integer = try d.r.varint(true) });
                        try offsets.append(offset.value());
                    }
                    try key.put("offsets", .{ .array = offsets });
                }
                try keys.append(key.value());
            }
            try animation.put("drawOrder", .{ .array = keys });
        }

        const event_count = try d.count();
        if (event_count > 0) {
            var keys = tree.array(d.arena);
            for (0..event_count) |_| {
                var key: Object = .init(d.arena);
                try key.float("time", try d.r.float(), 0);
                const index = try d.unsigned();
                if (index >= d.events.len) return error.Malformed;
                const e = d.events[index];
                try key.put("name", .{ .string = e.name });
                try key.int("int", try d.r.varint(false), e.int);
                try key.float("float", try d.r.float(), e.float);
                if (try d.r.boolean()) try key.string("string", try d.r.string());
                if (e.audio) {
                    try key.float("volume", try d.r.float(), e.volume);
                    try key.float("balance", try d.r.float(), e.balance);
                }
                try keys.append(key.value());
            }
            try animation.put("events", .{ .array = keys });
        }

        return animation.value();
    }

    /// Every key but the last carries its own curve
    fn frames(d: *Decoder, frame_count: usize, shape: Shape) E!Value {
        var keys = tree.array(d.arena);
        for (0..frame_count) |frame| {
            var key: Object = .init(d.arena);
            try key.float("time", try d.r.float(), 0);
            try d.keyValues(&key, shape);
            if (frame + 1 < frame_count) try d.curve(&key);
            try keys.append(key.value());
        }
        return .{ .array = keys };
    }

    fn curve(d: *Decoder, key: *Object) E!void {
        switch (try d.r.byte()) {
            curve_linear => {},
            curve_stepped => try key.put("curve", .{ .string = "stepped" }),
            curve_bezier => {
                try key.put("curve", .{ .float = try d.r.float() });
                try key.float("c2", try d.r.float(), 0);
                try key.float("c3", try d.r.float(), 1);
                try key.float("c4", try d.r.float(), 1);
            },
            else => return error.Malformed,
        }
    }

    fn keyValues(d: *Decoder, key: *Object, shape: Shape) E!void {
        switch (shape) {
            .value => |v| try key.float(v[0], try d.r.float(), v[1]),
            .pair => |default| {
                try key.float("x", try d.r.float(), default);
                try key.float("y", try d.r.float(), default);
            },
            .color => try key.put("color", .{ .string = try tree.hex(d.arena, try d.r.int(u32), 8) }),
            .two_color => {
                try key.put("light", .{ .string = try tree.hex(d.arena, try d.r.int(u32), 8) });
                try key.put("dark", .{ .string = try tree.hex(d.arena, try d.r.int(u32) & 0xffffff, 6) });
            },
            .ik => {
                try key.float("mix", try d.r.float(), 1);
                if (d.ik_softness) try key.float("softness", try d.r.float(), 0);
                try key.boolean("bendPositive", try d.bendPositive(), true);
                try key.boolean("compress", try d.r.boolean(), false);
                try key.boolean("stretch", try d.r.boolean(), false);
            },
            .transform => {
                for ([_][]const u8{ "rotateMix", "translateMix", "scaleMix", "shearMix" }) |name| try key.float(name, try d.r.float(), 1);
            },
            .path_mix => {
                for ([_][]const u8{ "rotateMix", "translateMix" }) |name| try key.float(name, try d.r.float(), 1);
            },
            .deform => {
                const end = try d.count();
                if (end > 0) {
                    try key.int("offset", try d.unsigned(), 0);
                    try key.put("vertices", try d.floats(end));
                }
            },
        }
    }

    /// Bend direction byte is one or minus one
    fn bendPositive(d: *Decoder) E!bool {
        return @as(i8, @bitCast(try d.r.byte())) >= 0;
    }

    fn floats(d: *Decoder, n: usize) E!Value {
        if (n > (d.r.data.len - d.r.pos) / 4) return error.Malformed;
        var values = try std.json.Array.initCapacity(d.arena, n);
        for (0..n) |_| values.appendAssumeCapacity(.{ .float = try d.r.float() });
        return .{ .array = values };
    }

    fn shorts(d: *Decoder) E!Value {
        const n = try d.count();
        if (n > (d.r.data.len - d.r.pos) / 2) return error.Malformed;
        var values = try std.json.Array.initCapacity(d.arena, n);
        for (0..n) |_| values.appendAssumeCapacity(.{ .integer = try d.r.int(u16) });
        return .{ .array = values };
    }

    fn pickList(d: *Decoder, from: []const []const u8) E!Value {
        var values = tree.array(d.arena);
        for (0..try d.count()) |_| try values.append(.{ .string = try d.pick(from) });
        return .{ .array = values };
    }

    /// Counts beyond the remaining bytes are corrupt
    fn count(d: *Decoder) E!usize {
        const n = try d.r.varint(true);
        if (n < 0 or n > d.r.data.len - d.r.pos) return error.Malformed;
        return @intCast(n);
    }

    fn unsigned(d: *Decoder) E!u32 {
        const n = try d.r.varint(true);
        if (n < 0) return error.Malformed;
        return @intCast(n);
    }

    fn pick(d: *Decoder, from: []const []const u8) E![]const u8 {
        const i = try d.unsigned();
        return if (i < from.len) from[i] else error.Malformed;
    }

    fn enumName(_: *Decoder, values: []const []const u8, i: usize) Error![]const u8 {
        return if (i < values.len) values[i] else error.Malformed;
    }

    fn requiredString(d: *Decoder) E![]const u8 {
        return try d.r.string() orelse error.Malformed;
    }

    fn stringRef(d: *Decoder) E!?[]const u8 {
        const i = try d.unsigned();
        if (i == 0) return null;
        return if (i <= d.strings.len) d.strings[i - 1] else error.Malformed;
    }

    fn nullable(_: *Decoder, s: ?[]const u8) Error!Value {
        return if (s) |v| .{ .string = v } else .null;
    }
};

pub fn encode(arena: std.mem.Allocator, doc: Document, report: *Report) Error![]const u8 {
    var e: Encoder = .{ .arena = arena, .report = report, .root = doc.root, .w = .{ .arena = arena } };
    var version = doc.version;
    return e.skeletonData(version.text());
}

const Names = std.StringArrayHashMapUnmanaged(void);

const Encoder = struct {
    arena: std.mem.Allocator,
    report: *Report,
    root: Value,
    w: Writer,
    nonessential: bool = false,
    ik_softness: bool = true,
    strings: Names = .empty,
    bones: Names = .empty,
    slots: Names = .empty,
    constraints: [constraint_kinds.len]Names = @splat(.empty),
    skins: Names = .empty,
    skin_values: std.ArrayList(Value) = .empty,
    events: std.json.ObjectMap = .empty,

    fn skeletonData(e: *Encoder, version_text: []const u8) Error![]const u8 {
        const skeleton = tree.get(e.root, "skeleton") orelse Value{ .object = .empty };
        var head: Writer = .{ .arena = e.arena };
        // SkeletonBinary.java fails on null header strings
        try head.string(try tree.getString(skeleton, "hash") orelse "");
        const spine = try tree.getString(skeleton, "spine") orelse version_text;
        try head.string(spine);
        if (Version.parse(spine)) |v| e.ik_softness = Version.editor(v, .ik_frames_3825) != .old;
        for ([_][]const u8{ "x", "y", "width", "height" }) |key| try head.float(try tree.getFloat(skeleton, key, 0));
        for ([_][]const u8{ "fps", "images", "audio" }) |key| {
            if (skeleton == .object and skeleton.object.contains(key)) e.nonessential = true;
        }
        try head.boolean(e.nonessential);
        if (e.nonessential) {
            try head.float(try tree.getFloat(skeleton, "fps", 30));
            try head.string(try tree.getString(skeleton, "images") orelse "");
            try head.string(try tree.getString(skeleton, "audio") orelse "");
        }

        try e.collectNames();
        try e.writeBones();
        try e.writeSlots();
        for (constraint_kinds) |kind| try e.writeConstraints(kind);
        try e.writeSkins();
        try e.writeEvents();
        const animations = try tree.getObject(e.root, "animations");
        try e.w.count(animations.count());
        for (animations.keys(), animations.values()) |name, animation| {
            try e.w.string(name);
            try e.writeAnimation(animation);
        }

        try head.count(e.strings.count());
        for (e.strings.keys()) |s| try head.string(s);
        try head.bytes(e.w.out.items);
        return head.out.items;
    }

    fn collectNames(e: *Encoder) Error!void {
        for ([_][]const u8{ "bones", "slots" }, [_]*Names{ &e.bones, &e.slots }) |key, names| {
            for (try tree.getArray(e.root, key)) |item| {
                const entry = try names.getOrPut(e.arena, try tree.requireString(item, "name"));
                if (entry.found_existing) return error.Malformed;
            }
        }
        for (constraint_kinds, &e.constraints) |kind, *names| {
            for (try tree.getArray(e.root, @tagName(kind))) |c| {
                const entry = try names.getOrPut(e.arena, try tree.requireString(c, "name"));
                if (entry.found_existing) return error.Malformed;
            }
        }
        e.events = try tree.getObject(e.root, "events");

        const skins = try tree.getArray(e.root, "skins");
        for (skins) |skin| {
            if (!std.mem.eql(u8, try tree.requireString(skin, "name"), "default")) continue;
            if ((try tree.getObject(skin, "attachments")).count() > 0) {
                try e.skins.put(e.arena, "default", {});
                try e.skin_values.append(e.arena, skin);
            }
            break;
        }
        for (skins) |skin| {
            const name = try tree.requireString(skin, "name");
            if (std.mem.eql(u8, name, "default")) continue;
            const entry = try e.skins.getOrPut(e.arena, name);
            if (entry.found_existing) return error.Malformed;
            try e.skin_values.append(e.arena, skin);
        }
    }

    fn writeBones(e: *Encoder) Error!void {
        const bones = try tree.getArray(e.root, "bones");
        try e.w.count(bones.len);
        for (bones, 0..) |b, i| {
            try e.w.string(try tree.requireString(b, "name"));
            if (i > 0) {
                const parent = try indexOf(e.bones, try tree.getString(b, "parent") orelse return error.Malformed);
                if (parent >= i) return error.Malformed;
                try e.w.count(parent);
            }
            try e.floats(b, &.{ .{ "rotation", 0 }, .{ "x", 0 }, .{ "y", 0 }, .{ "scaleX", 1 }, .{ "scaleY", 1 }, .{ "shearX", 0 }, .{ "shearY", 0 }, .{ "length", 0 } });
            try e.w.count(try enumIndex(&transform_names, try tree.getString(b, "transform") orelse "normal"));
            try e.w.boolean(try tree.getBool(b, "skin", false));
            if (e.nonessential) try e.w.int(u32, try tree.getColor(b, "color", bone_color));
        }
    }

    fn writeSlots(e: *Encoder) Error!void {
        const slots = try tree.getArray(e.root, "slots");
        try e.w.count(slots.len);
        for (slots) |s| {
            try e.w.string(try tree.requireString(s, "name"));
            try e.w.count(try indexOf(e.bones, try tree.requireString(s, "bone")));
            try e.w.int(u32, try tree.getColor(s, "color", white));
            const dark: i32 = if (try tree.getString(s, "dark")) |d| @intCast(try tree.parseHex(d, 6)) else -1;
            try e.w.int(i32, dark);
            try e.ref(try tree.getString(s, "attachment"));
            try e.w.count(try enumIndex(&blend_names, try tree.getString(s, "blend") orelse "normal"));
        }
    }

    fn writeConstraints(e: *Encoder, kind: ConstraintKind) Error!void {
        const constraints = try tree.getArray(e.root, @tagName(kind));
        try e.w.count(constraints.len);
        for (constraints) |c| {
            try e.w.string(try tree.requireString(c, "name"));
            try e.w.count(try tree.getNatural(c, "order", 0));
            try e.w.boolean(try tree.getBool(c, "skin", false));
            try e.boneList(c, "bones");
            const target = try tree.requireString(c, "target");
            try e.w.count(try indexOf(if (kind == .path) e.slots else e.bones, target));
            switch (kind) {
                .ik => {
                    try e.floats(c, &.{ .{ "mix", 1 }, .{ "softness", 0 } });
                    try e.w.byte(if (try tree.getBool(c, "bendPositive", true)) 1 else 0xff);
                    for ([_][]const u8{ "compress", "stretch", "uniform" }) |key| try e.w.boolean(try tree.getBool(c, key, false));
                },
                .transform => {
                    for ([_][]const u8{ "local", "relative" }) |key| try e.w.boolean(try tree.getBool(c, key, false));
                    try e.floats(c, &.{ .{ "rotation", 0 }, .{ "x", 0 }, .{ "y", 0 }, .{ "scaleX", 0 }, .{ "scaleY", 0 }, .{ "shearY", 0 } });
                    try e.floats(c, &.{ .{ "rotateMix", 1 }, .{ "translateMix", 1 }, .{ "scaleMix", 1 }, .{ "shearMix", 1 } });
                },
                .path => {
                    try e.w.count(try enumIndex(&position_names, try tree.getString(c, "positionMode") orelse "percent"));
                    try e.w.count(try enumIndex(&spacing_names, try tree.getString(c, "spacingMode") orelse "length"));
                    try e.w.count(try enumIndex(&rotate_names, try tree.getString(c, "rotateMode") orelse "tangent"));
                    try e.floats(c, &.{ .{ "rotation", 0 }, .{ "position", 0 }, .{ "spacing", 0 }, .{ "rotateMix", 1 }, .{ "translateMix", 1 } });
                },
            }
        }
    }

    fn writeSkins(e: *Encoder) Error!void {
        const has_default = e.skins.count() > 0 and std.mem.eql(u8, e.skins.keys()[0], "default");
        if (has_default) try e.writeSkinAttachments(e.skin_values.items[0]) else try e.w.count(0);
        const first: usize = @intFromBool(has_default);
        try e.w.count(e.skins.count() - first);
        for (e.skins.keys()[first..], e.skin_values.items[first..]) |name, skin| {
            try e.ref(name);
            try e.boneList(skin, "bones");
            for (constraint_kinds, e.constraints) |kind, names| {
                const list = try tree.getArray(skin, @tagName(kind));
                try e.w.count(list.len);
                for (list) |c| {
                    if (c != .string) return error.Malformed;
                    try e.w.count(try indexOf(names, c.string));
                }
            }
            try e.writeSkinAttachments(skin);
        }
    }

    fn writeSkinAttachments(e: *Encoder, skin: Value) Error!void {
        const attachments = try tree.getObject(skin, "attachments");
        try e.w.count(attachments.count());
        for (attachments.keys(), attachments.values()) |slot_name, slot| {
            try e.w.count(try indexOf(e.slots, slot_name));
            const map = try objectOf(slot);
            try e.w.count(map.count());
            for (map.keys(), map.values()) |placeholder, a| {
                try e.ref(placeholder);
                try e.writeAttachment(placeholder, a);
            }
        }
    }

    fn writeAttachment(e: *Encoder, placeholder: []const u8, a: Value) Error!void {
        const name = try tree.getString(a, "name") orelse placeholder;
        try e.ref(if (std.mem.eql(u8, name, placeholder)) null else name);
        var kind = try enumIndex(&attachment_type_names, try tree.getString(a, "type") orelse "region");
        // SkeletonJson.java reads both mesh types alike
        if (kind == 2 or kind == 3) kind = if (try tree.getString(a, "parent") != null) 3 else 2;
        try e.w.byte(kind);
        switch (kind) {
            0 => {
                try e.path(a, name);
                try e.floats(a, &.{ .{ "rotation", 0 }, .{ "x", 0 }, .{ "y", 0 }, .{ "scaleX", 1 }, .{ "scaleY", 1 }, .{ "width", 32 }, .{ "height", 32 } });
                try e.w.int(u32, try tree.getColor(a, "color", white));
            },
            1 => {
                const vertex_count = try tree.getNatural(a, "vertexCount", 0);
                try e.w.count(vertex_count);
                try e.writeVertices(a, vertex_count);
                if (e.nonessential) try e.w.int(u32, try tree.getColor(a, "color", 0x60f000ff));
            },
            2 => {
                try e.path(a, name);
                try e.w.int(u32, try tree.getColor(a, "color", white));
                const uvs = try tree.getArray(a, "uvs");
                if (uvs.len % 2 != 0) return error.Malformed;
                try e.w.count(uvs.len / 2);
                for (uvs) |v| try e.w.float(try tree.number(v));
                try e.shorts(a, "triangles");
                try e.writeVertices(a, uvs.len / 2);
                try e.w.count(try tree.getNatural(a, "hull", 0));
                if (e.nonessential) {
                    try e.shorts(a, "edges");
                    try e.floats(a, &.{ .{ "width", 0 }, .{ "height", 0 } });
                }
            },
            3 => {
                try e.path(a, name);
                try e.w.int(u32, try tree.getColor(a, "color", white));
                try e.ref(try tree.getString(a, "skin"));
                try e.ref(try tree.requireString(a, "parent"));
                try e.w.boolean(try tree.getBool(a, "deform", true));
                if (e.nonessential) try e.floats(a, &.{ .{ "width", 0 }, .{ "height", 0 } });
            },
            4 => {
                try e.w.boolean(try tree.getBool(a, "closed", false));
                try e.w.boolean(try tree.getBool(a, "constantSpeed", true));
                const vertex_count = try tree.getNatural(a, "vertexCount", 0);
                try e.w.count(vertex_count);
                try e.writeVertices(a, vertex_count);
                const lengths = try tree.getArray(a, "lengths");
                if (lengths.len != vertex_count / 3) return error.Malformed;
                for (lengths) |l| try e.w.float(try tree.number(l));
                if (e.nonessential) try e.w.int(u32, try tree.getColor(a, "color", 0xff7f00ff));
            },
            5 => {
                try e.floats(a, &.{ .{ "rotation", 0 }, .{ "x", 0 }, .{ "y", 0 } });
                if (e.nonessential) try e.w.int(u32, try tree.getColor(a, "color", 0xf1f100ff));
            },
            6 => {
                const end = if (try tree.getString(a, "end")) |s| try indexOf(e.slots, s) else e.slots.count() -| 1;
                try e.w.count(end);
                const vertex_count = try tree.getNatural(a, "vertexCount", 0);
                try e.w.count(vertex_count);
                try e.writeVertices(a, vertex_count);
                if (e.nonessential) try e.w.int(u32, try tree.getColor(a, "color", 0x3a3aceff));
            },
            else => unreachable,
        }
    }

    fn path(e: *Encoder, a: Value, name: []const u8) Error!void {
        const p = try tree.getString(a, "path");
        try e.ref(if (p != null and !std.mem.eql(u8, p.?, name)) p else null);
    }

    /// Unweighted vertices hold two floats per vertex
    fn writeVertices(e: *Encoder, a: Value, vertex_count: usize) Error!void {
        const values = try tree.getArray(a, "vertices");
        const weighted = values.len != vertex_count * 2;
        try e.w.boolean(weighted);
        if (!weighted) {
            for (values) |v| try e.w.float(try tree.number(v));
            return;
        }
        var i: usize = 0;
        var n: usize = 0;
        while (i < values.len) : (n += 1) {
            const bone_count: usize = try tree.natural(values[i]);
            if (bone_count > (values.len - i - 1) / 4) return error.Malformed;
            i += 1 + bone_count * 4;
        }
        if (n != vertex_count) return error.Malformed;
        i = 0;
        while (i < values.len) {
            const bone_count: usize = try tree.natural(values[i]);
            try e.w.count(bone_count);
            for (values[i + 1 ..][0 .. bone_count * 4], 0..) |x, j| {
                if (j % 4 == 0) try e.w.count(try tree.natural(x)) else try e.w.float(try tree.number(x));
            }
            i += 1 + bone_count * 4;
        }
    }

    fn shorts(e: *Encoder, o: Value, key: []const u8) Error!void {
        const values = try tree.getArray(o, key);
        try e.w.count(values.len);
        for (values) |v| try e.w.int(u16, std.math.cast(u16, try tree.natural(v)) orelse return error.Malformed);
    }

    fn writeEvents(e: *Encoder) Error!void {
        try e.w.count(e.events.count());
        for (e.events.keys(), e.events.values()) |name, event| {
            try e.ref(name);
            try e.w.varint(try tree.getInt(event, "int", 0), false);
            try e.w.float(try tree.getFloat(event, "float", 0));
            try e.w.string(try tree.getString(event, "string") orelse "");
            const audio = try tree.getString(event, "audio");
            try e.w.string(audio);
            if (audio != null) try e.floats(event, &.{ .{ "volume", 1 }, .{ "balance", 0 } });
        }
    }

    fn writeAnimation(e: *Encoder, animation: Value) Error!void {
        const slots = try tree.getObject(animation, "slots");
        try e.w.count(slots.count());
        for (slots.keys(), slots.values()) |slot_name, timelines| {
            try e.w.count(try indexOf(e.slots, slot_name));
            const map = try objectOf(timelines);
            try e.w.count(try nonEmpty(map));
            for (map.keys(), map.values()) |timeline_name, keys| {
                const items = try keysOf(keys) orelse continue;
                const kind = try enumIndex(&slot_timeline_names, timeline_name);
                try e.w.byte(kind);
                try e.w.count(items.len);
                switch (kind) {
                    0 => for (items) |key| {
                        try e.w.float(try tree.getFloat(key, "time", 0));
                        try e.ref(try tree.getString(key, "name"));
                    },
                    1 => try e.frames(items, .color),
                    2 => try e.frames(items, .two_color),
                    else => unreachable,
                }
            }
        }

        const bones = try tree.getObject(animation, "bones");
        try e.w.count(bones.count());
        for (bones.keys(), bones.values()) |bone_name, timelines| {
            try e.w.count(try indexOf(e.bones, bone_name));
            const map = try objectOf(timelines);
            try e.w.count(try nonEmpty(map));
            for (map.keys(), map.values()) |timeline_name, keys| {
                const items = try keysOf(keys) orelse continue;
                const kind = try enumIndex(&bone_timeline_names, timeline_name);
                try e.w.byte(kind);
                try e.w.count(items.len);
                try e.frames(items, switch (kind) {
                    0 => .{ .value = .{ "angle", 0 } },
                    2 => .{ .pair = 1 },
                    else => .{ .pair = 0 },
                });
            }
        }

        for ([_]ConstraintKind{ .ik, .transform }) |kind| {
            const constraints = try tree.getObject(animation, @tagName(kind));
            try e.w.count(try nonEmpty(constraints));
            for (constraints.keys(), constraints.values()) |constraint_name, keys| {
                const items = try keysOf(keys) orelse continue;
                try e.w.count(try indexOf(e.constraints[@backingInt(kind)], constraint_name));
                try e.w.count(items.len);
                if (kind == .ik and !e.ik_softness) for (items) |key| if (try tree.getFloat(key, "softness", 0) != 0) {
                    try e.report.add(.{
                        .code = .@"ik.softness.dropped",
                        .step = "",
                        .path = try std.fmt.allocPrint(e.arena, "ik.{s}", .{constraint_name}),
                        .message = "3.8.25-beta binary keys carry no IK softness",
                    });
                    break;
                };
                try e.frames(items, if (kind == .ik) .ik else .transform);
            }
        }

        const paths = try tree.getObject(animation, "path");
        try e.w.count(paths.count());
        for (paths.keys(), paths.values()) |constraint_name, timelines| {
            try e.w.count(try indexOf(e.constraints[@backingInt(ConstraintKind.path)], constraint_name));
            const map = try objectOf(timelines);
            try e.w.count(try nonEmpty(map));
            for (map.keys(), map.values()) |timeline_name, keys| {
                const items = try keysOf(keys) orelse continue;
                const kind = try enumIndex(&path_timeline_names, timeline_name);
                try e.w.byte(kind);
                try e.w.count(items.len);
                try e.frames(items, if (kind == 2) .path_mix else .{ .value = .{ timeline_name, 0 } });
            }
        }

        const deform = try tree.getObject(animation, "deform");
        try e.w.count(deform.count());
        for (deform.keys(), deform.values()) |skin_name, skin| {
            try e.w.count(try indexOf(e.skins, skin_name));
            const skin_map = try objectOf(skin);
            try e.w.count(skin_map.count());
            for (skin_map.keys(), skin_map.values()) |slot_name, slot| {
                try e.w.count(try indexOf(e.slots, slot_name));
                const slot_map = try objectOf(slot);
                try e.w.count(try nonEmpty(slot_map));
                for (slot_map.keys(), slot_map.values()) |attachment_name, keys| {
                    const items = try keysOf(keys) orelse continue;
                    try e.ref(attachment_name);
                    try e.w.count(items.len);
                    try e.frames(items, .deform);
                }
            }
        }

        const draw_order = if (tree.get(animation, "drawOrder") != null) try tree.getArray(animation, "drawOrder") else try tree.getArray(animation, "draworder");
        try e.w.count(draw_order.len);
        for (draw_order) |key| {
            try e.w.float(try tree.getFloat(key, "time", 0));
            const offsets = try tree.getArray(key, "offsets");
            try e.w.count(offsets.len);
            for (offsets) |offset| {
                try e.w.count(try indexOf(e.slots, try tree.requireString(offset, "slot")));
                try e.w.varint(try tree.getInt(offset, "offset", 0), true);
            }
        }

        const events = try tree.getArray(animation, "events");
        try e.w.count(events.len);
        for (events) |key| {
            try e.w.float(try tree.getFloat(key, "time", 0));
            const index = e.events.getIndex(try tree.requireString(key, "name")) orelse return error.Malformed;
            const setup = e.events.values()[index];
            try e.w.count(index);
            try e.w.varint(try tree.getInt(key, "int", try tree.getInt(setup, "int", 0)), false);
            try e.w.float(try tree.getFloat(key, "float", try tree.getFloat(setup, "float", 0)));
            const string = try tree.getString(key, "string");
            try e.w.boolean(string != null);
            if (string) |s| try e.w.string(s);
            if (try tree.getString(setup, "audio") != null) {
                try e.w.float(try tree.getFloat(key, "volume", try tree.getFloat(setup, "volume", 1)));
                try e.w.float(try tree.getFloat(key, "balance", try tree.getFloat(setup, "balance", 0)));
            }
        }
    }

    /// Every key but the last carries its own curve
    fn frames(e: *Encoder, keys: []const Value, shape: Shape) Error!void {
        for (keys, 0..) |key, i| {
            try e.w.float(try tree.getFloat(key, "time", 0));
            try e.keyValues(key, shape);
            if (i + 1 < keys.len) try e.curve(key);
        }
    }

    /// SkeletonJson.java reads any string as stepped
    fn curve(e: *Encoder, key: Value) Error!void {
        const c = tree.get(key, "curve") orelse return e.w.byte(curve_linear);
        if (c == .string) return e.w.byte(curve_stepped);
        try e.w.byte(curve_bezier);
        try e.w.float(try tree.number(c));
        try e.floats(key, &.{ .{ "c2", 0 }, .{ "c3", 1 }, .{ "c4", 1 } });
    }

    fn keyValues(e: *Encoder, key: Value, shape: Shape) Error!void {
        switch (shape) {
            .value => |v| try e.w.float(try tree.getFloat(key, v[0], v[1])),
            .pair => |default| try e.floats(key, &.{ .{ "x", default }, .{ "y", default } }),
            .color => try e.w.int(u32, try requireColor(key, "color")),
            .two_color => {
                try e.w.int(u32, try requireColor(key, "light"));
                try e.w.int(u32, try tree.parseHex(try tree.requireString(key, "dark"), 6));
            },
            .ik => {
                try e.w.float(try tree.getFloat(key, "mix", 1));
                if (e.ik_softness) try e.w.float(try tree.getFloat(key, "softness", 0));
                try e.w.byte(if (try tree.getBool(key, "bendPositive", true)) 1 else 0xff);
                for ([_][]const u8{ "compress", "stretch" }) |name| try e.w.boolean(try tree.getBool(key, name, false));
            },
            .transform => try e.floats(key, &.{ .{ "rotateMix", 1 }, .{ "translateMix", 1 }, .{ "scaleMix", 1 }, .{ "shearMix", 1 } }),
            .path_mix => try e.floats(key, &.{ .{ "rotateMix", 1 }, .{ "translateMix", 1 } }),
            .deform => {
                const values = try tree.getArray(key, "vertices");
                try e.w.count(values.len);
                if (values.len == 0) return;
                try e.w.count(try tree.getNatural(key, "offset", 0));
                for (values) |v| try e.w.float(try tree.number(v));
            },
        }
    }

    fn requireColor(o: Value, key: []const u8) Error!u32 {
        if (tree.get(o, key) == null) return error.Malformed;
        return tree.getColor(o, key, white);
    }

    const Field = struct { []const u8, f32 };

    fn floats(e: *Encoder, o: Value, fields: []const Field) Error!void {
        for (fields) |field| try e.w.float(try tree.getFloat(o, field[0], field[1]));
    }

    fn boneList(e: *Encoder, o: Value, key: []const u8) Error!void {
        const names = try tree.getArray(o, key);
        try e.w.count(names.len);
        for (names) |name| {
            if (name != .string) return error.Malformed;
            try e.w.count(try indexOf(e.bones, name.string));
        }
    }

    fn ref(e: *Encoder, s: ?[]const u8) Error!void {
        const text = s orelse return e.w.count(0);
        const entry = try e.strings.getOrPut(e.arena, text);
        try e.w.count(entry.index + 1);
    }

    fn indexOf(names: Names, name: []const u8) Error!u32 {
        return @intCast(names.getIndex(name) orelse return error.Malformed);
    }

    fn enumIndex(values: []const []const u8, name: []const u8) Error!u8 {
        for (values, 0..) |v, i| {
            if (std.mem.eql(u8, v, name)) return @intCast(i);
        }
        return error.Malformed;
    }

    fn objectOf(v: Value) Error!std.json.ObjectMap {
        return if (v == .object) v.object else error.Malformed;
    }

    /// Runtimes fail on empty key lists
    fn keysOf(v: Value) Error!?[]const Value {
        if (v != .array) return error.Malformed;
        return if (v.array.items.len == 0) null else v.array.items;
    }

    fn nonEmpty(map: std.json.ObjectMap) Error!usize {
        var n: usize = 0;
        for (map.values()) |keys| n += @intFromBool(try keysOf(keys) != null);
        return n;
    }
};

test "3.8.25-beta IK keys without softness" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sizes: [2]usize = undefined;
    for ([_][]const u8{ "3.8.25-beta", "3.8.26-beta" }, &sizes) |text, *size| {
        var report: Report = .{ .arena = a };
        const input = try std.fmt.allocPrint(a,
            \\{{"skeleton":{{"spine":"{s}"}},"bones":[{{"name":"root"}},{{"name":"b","parent":"root"}}],
            \\"ik":[{{"name":"i","bones":["b"],"target":"root"}}],
            \\"animations":{{"a":{{"ik":{{"i":[{{"mix":0.5,"softness":2,"bendPositive":false}},{{"time":1}}]}}}}}}}}
        , .{text});
        const root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        const version = Version.parse(text).?;
        const data = try encode(a, .{ .version = version, .origin = .json, .root = root }, &report);
        size.* = data.len;
        const old = Version.editor(version, .ik_frames_3825) == .old;
        try std.testing.expectEqual(@intFromBool(old), report.entries.items.len);
        const doc = try decode(a, data, version, &report);
        const key = doc.root.object.get("animations").?.object.get("a").?.object.get("ik").?.object.get("i").?.array.items[0].object;
        try std.testing.expectEqual(0.5, key.get("mix").?.float);
        try std.testing.expectEqual(old, key.get("softness") == null);
        try std.testing.expectEqual(false, key.get("bendPositive").?.bool);
    }
    try std.testing.expectEqual(sizes[1], sizes[0] + 8);
}

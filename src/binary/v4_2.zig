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

//! Spine 4.2 binary, ported from SkeletonBinary.java of the 4.2 branch

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

const inherit_names = [_][]const u8{ "normal", "onlyTranslation", "noRotationOrReflection", "noScale", "noScaleOrReflection" };
const blend_names = [_][]const u8{ "normal", "additive", "multiply", "screen" };
const position_names = [_][]const u8{ "fixed", "percent" };
const spacing_names = [_][]const u8{ "length", "fixed", "percent", "proportional" };
const rotate_names = [_][]const u8{ "tangent", "chain", "chainScale" };
const sequence_mode_names = [_][]const u8{ "hold", "once", "loop", "pingpong", "onceReverse", "loopReverse", "pingpongReverse" };
const attachment_type_names = [_][]const u8{ "region", "boundingbox", "mesh", "linkedmesh", "path", "point", "clipping" };
const bone_timeline_names = [_][]const u8{ "rotate", "translate", "translatex", "translatey", "scale", "scalex", "scaley", "shear", "shearx", "sheary", "inherit" };
const slot_timeline_names = [_][]const u8{ "attachment", "rgba", "rgb", "rgba2", "rgb2", "alpha" };
const path_timeline_names = [_][]const u8{ "position", "spacing", "mix" };
/// Index three is unused by the format
const physics_timeline_names = [_][]const u8{ "inertia", "strength", "damping", "", "mass", "wind", "gravity", "mix", "reset" };

const ConstraintKind = enum(u8) { ik, transform, path, physics };
const constraint_type_names = [_][]const u8{ "ik", "transform", "path", "physics" };

const transform_offsets = [_][]const u8{ "rotation", "x", "y", "scaleX", "scaleY", "shearY" };
const transform_mixes = [_][]const u8{ "mixRotate", "mixX", "mixY", "mixScaleX", "mixScaleY", "mixShearY" };
const physics_globals = [_][]const u8{ "inertiaGlobal", "strengthGlobal", "dampingGlobal", "massGlobal", "windGlobal", "gravityGlobal", "mixGlobal" };

const bone_color = 0x9b9b9bff;
const skin_color = 0xfe9e4fff;
const white = 0xffffffff;

const curve_linear = 0;
const curve_stepped = 1;
const curve_bezier = 2;

pub fn decode(arena: std.mem.Allocator, data: []const u8, version: Version, report: *Report) Error!Document {
    _ = report;
    var d: Decoder = .{ .arena = arena, .r = .{ .data = data } };
    const root = d.skeletonData() catch |e| return switch (e) {
        error.EndOfData => error.Malformed,
        else => |other| other,
    };
    return .{ .version = version, .origin = .binary, .root = root };
}

const Event = struct {
    name: []const u8,
    int: i32,
    float: f32,
    string: ?[]const u8,
    audio: bool,
    volume: f32,
    balance: f32,
};

const Decoder = struct {
    arena: std.mem.Allocator,
    r: Reader,
    nonessential: bool = false,
    strings: []const ?[]const u8 = &.{},
    bones: []const []const u8 = &.{},
    slots: []const []const u8 = &.{},
    constraints: [constraint_type_names.len][]const []const u8 = @splat(&.{}),
    skins: []const []const u8 = &.{},
    events: []const Event = &.{},

    const E = Error || Reader.Error;

    fn skeletonData(d: *Decoder) E!Value {
        var root: Object = .init(d.arena);
        var skeleton: Object = .init(d.arena);
        const hash = try d.r.bytes(8);
        if (!std.mem.allEqual(u8, hash, 0)) {
            const text = try d.arena.alloc(u8, std.base64.standard_no_pad.Encoder.calcSize(8));
            try skeleton.put("hash", .{ .string = std.base64.standard_no_pad.Encoder.encode(text, hash) });
        }
        const version = try d.r.string();
        try skeleton.string("spine", if (version) |v| if (v.len == 0) null else v else null);
        for ([_][]const u8{ "x", "y", "width", "height" }) |key| try skeleton.put(key, .{ .float = try d.r.float() });
        try skeleton.float("referenceScale", try d.r.float(), 100);
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

        for (constraint_type_names, 0..) |key, kind| {
            var values = tree.array(d.arena);
            const names = try d.arena.alloc([]const u8, try d.count());
            for (names) |*name| {
                name.* = try d.requiredString();
                try values.append(try d.readConstraint(name.*, @fromBackingInt(@intCast(kind))));
            }
            d.constraints[kind] = names;
            if (values.items.len > 0) try root.put(key, .{ .array = values });
        }

        var skins = tree.array(d.arena);
        var skin_names: std.ArrayList([]const u8) = .empty;
        const default_slots = try d.count();
        if (default_slots > 0) {
            try skin_names.append(d.arena, "default");
            d.skins = skin_names.items;
            try skins.append(try d.readSkin("default", default_slots));
        }
        for (0..try d.count()) |_| {
            const skin_name = try d.requiredString();
            try skin_names.append(d.arena, skin_name);
            d.skins = skin_names.items;
            try skins.append(try d.readSkin(skin_name, null));
        }

        try d.resolveLinkedSkins(skins.items);

        var events: Object = .init(d.arena);
        const event_data = try d.arena.alloc(Event, try d.count());
        for (event_data) |*e| {
            e.* = .{
                .name = try d.requiredString(),
                .int = try d.r.varint(false),
                .float = try d.r.float(),
                .string = try d.r.string(),
                .audio = false,
                .volume = 1,
                .balance = 0,
            };
            var event: Object = .init(d.arena);
            try event.int("int", e.int, 0);
            try event.float("float", e.float, 0);
            if (e.string) |s| if (s.len > 0) try event.put("string", .{ .string = s });
            if (try d.r.string()) |audio| {
                e.audio = true;
                e.volume = try d.r.float();
                e.balance = try d.r.float();
                try event.put("audio", .{ .string = audio });
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

    /// Linked meshes may name skins read after them
    fn resolveLinkedSkins(d: *Decoder, skins: []Value) E!void {
        for (skins) |skin| {
            const attachments = skin.object.get("attachments") orelse continue;
            for (attachments.object.values()) |slot| {
                for (slot.object.values()) |*attachment| {
                    const skin_index = attachment.object.get("skin") orelse continue;
                    const i: usize = @intCast(skin_index.integer);
                    if (i >= d.skins.len) return error.Malformed;
                    if (std.mem.eql(u8, d.skins[i], "default")) {
                        _ = attachment.object.orderedRemove("skin");
                    } else {
                        try attachment.object.put(d.arena, "skin", .{ .string = d.skins[i] });
                    }
                }
            }
        }
    }

    fn readBones(d: *Decoder) E!Value {
        var values = tree.array(d.arena);
        const names = try d.arena.alloc([]const u8, try d.count());
        for (names, 0..) |*bone_name, i| {
            bone_name.* = try d.requiredString();
            var bone: Object = .init(d.arena);
            try bone.put("name", .{ .string = bone_name.* });
            if (i > 0) try bone.put("parent", .{ .string = try d.pick(names[0..i]) });
            try bone.float("rotation", try d.r.float(), 0);
            try bone.float("x", try d.r.float(), 0);
            try bone.float("y", try d.r.float(), 0);
            try bone.float("scaleX", try d.r.float(), 1);
            try bone.float("scaleY", try d.r.float(), 1);
            try bone.float("shearX", try d.r.float(), 0);
            try bone.float("shearY", try d.r.float(), 0);
            try bone.float("length", try d.r.float(), 0);
            const inherit = try d.enumName(&inherit_names, try d.r.byte());
            if (!std.mem.eql(u8, inherit, "normal")) try bone.put("inherit", .{ .string = inherit });
            try bone.boolean("skin", try d.r.boolean(), false);
            if (d.nonessential) {
                try bone.color("color", try d.r.int(u32), bone_color);
                try bone.string("icon", try d.r.string());
                try bone.boolean("visible", try d.r.boolean(), true);
            }
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
            if (d.nonessential) try slot.boolean("visible", try d.r.boolean(), true);
            try values.append(slot.value());
        }
        d.slots = names;
        return .{ .array = values };
    }

    fn readConstraint(d: *Decoder, constraint_name: []const u8, kind: ConstraintKind) E!Value {
        var c: Object = .init(d.arena);
        try c.put("name", .{ .string = constraint_name });
        try c.int("order", try d.unsigned(), 0);
        switch (kind) {
            .ik => {
                try c.put("bones", try d.pickList(d.bones));
                try c.put("target", .{ .string = try d.pick(d.bones) });
                const flags = try d.r.byte();
                try c.boolean("skin", flags & 1 != 0, false);
                try c.boolean("bendPositive", flags & 2 != 0, true);
                try c.boolean("compress", flags & 4 != 0, false);
                try c.boolean("stretch", flags & 8 != 0, false);
                try c.boolean("uniform", flags & 16 != 0, false);
                const mix: f32 = if (flags & 32 == 0) 0 else if (flags & 64 != 0) try d.r.float() else 1;
                try c.float("mix", mix, 1);
                if (flags & 128 != 0) try c.float("softness", try d.r.float(), 0);
            },
            .transform => {
                try c.put("bones", try d.pickList(d.bones));
                try c.put("target", .{ .string = try d.pick(d.bones) });
                var flags = try d.r.byte();
                try c.boolean("skin", flags & 1 != 0, false);
                try c.boolean("local", flags & 2 != 0, false);
                try c.boolean("relative", flags & 4 != 0, false);
                for (transform_offsets[0..5], 3..) |key, bit| {
                    if (flags & (@as(u8, 1) << @intCast(bit)) != 0) try c.float(key, try d.r.float(), 0);
                }
                flags = try d.r.byte();
                if (flags & 1 != 0) try c.float("shearY", try d.r.float(), 0);
                var mixes: [6]f32 = @splat(0);
                for (&mixes, 1..) |*m, bit| {
                    if (flags & (@as(u8, 1) << @intCast(bit)) != 0) m.* = try d.r.float();
                }
                try transformMixes(&c, mixes);
            },
            .path => {
                try c.boolean("skin", try d.r.boolean(), false);
                try c.put("bones", try d.pickList(d.bones));
                try c.put("target", .{ .string = try d.pick(d.slots) });
                const flags = try d.r.byte();
                const position_mode = try d.enumName(&position_names, flags & 1);
                const spacing_mode = try d.enumName(&spacing_names, (flags >> 1) & 3);
                const rotate_mode = try d.enumName(&rotate_names, (flags >> 3) & 3);
                if (!std.mem.eql(u8, position_mode, "percent")) try c.put("positionMode", .{ .string = position_mode });
                if (!std.mem.eql(u8, spacing_mode, "length")) try c.put("spacingMode", .{ .string = spacing_mode });
                if (!std.mem.eql(u8, rotate_mode, "tangent")) try c.put("rotateMode", .{ .string = rotate_mode });
                if (flags & 128 != 0) try c.float("rotation", try d.r.float(), 0);
                try c.float("position", try d.r.float(), 0);
                try c.float("spacing", try d.r.float(), 0);
                try c.float("mixRotate", try d.r.float(), 1);
                const mix_x = try d.r.float();
                try c.float("mixX", mix_x, 1);
                const mix_y = try d.r.float();
                // spine-cpp defaults mixY to mixX and the Java runtime to one
                if (mix_y != 1 or mix_x != 1) try c.put("mixY", .{ .float = mix_y });
            },
            .physics => {
                try c.put("bone", .{ .string = try d.pick(d.bones) });
                var flags = try d.r.byte();
                try c.boolean("skin", flags & 1 != 0, false);
                if (flags & 2 != 0) try c.float("x", try d.r.float(), 0);
                if (flags & 4 != 0) try c.float("y", try d.r.float(), 0);
                if (flags & 8 != 0) try c.float("rotate", try d.r.float(), 0);
                if (flags & 16 != 0) try c.float("scaleX", try d.r.float(), 0);
                if (flags & 32 != 0) try c.float("shearX", try d.r.float(), 0);
                if (flags & 64 != 0) try c.float("limit", try d.r.float(), 5000);
                try c.int("fps", try d.r.byte(), 60);
                try c.float("inertia", try d.r.float(), 1);
                try c.float("strength", try d.r.float(), 100);
                try c.float("damping", try d.r.float(), 1);
                if (flags & 128 != 0) try c.float("mass", 1 / try d.r.float(), 1);
                try c.float("wind", try d.r.float(), 0);
                try c.float("gravity", try d.r.float(), 0);
                flags = try d.r.byte();
                for (physics_globals, 0..) |key, i| try c.boolean(key, flags & (@as(u8, 1) << @intCast(i)) != 0, false);
                if (flags & 128 != 0) try c.float("mix", try d.r.float(), 1);
            },
        }
        return c.value();
    }

    /// JSON readers default the Y mixes to the X mixes
    fn transformMixes(o: *Object, mixes: [6]f32) Error!void {
        for (transform_mixes, mixes, 0..) |key, m, i| try o.float(key, m, if (i == 2 or i == 4) mixes[i - 1] else 1);
    }

    fn readSkin(d: *Decoder, skin_name: []const u8, default_slots: ?usize) E!Value {
        var skin: Object = .init(d.arena);
        try skin.put("name", .{ .string = skin_name });
        var color: ?u32 = null;
        const slot_count = default_slots orelse slots: {
            if (d.nonessential) color = try d.r.int(u32);
            const bones = try d.pickList(d.bones);
            if (bones.array.items.len > 0) try skin.put("bones", bones);
            for (constraint_type_names, d.constraints) |key, names| {
                const list = try d.pickList(names);
                if (list.array.items.len > 0) try skin.put(key, list);
            }
            break :slots try d.count();
        };
        var attachments: Object = .init(d.arena);
        for (0..slot_count) |_| {
            const slot_index = try d.unsigned();
            if (slot_index >= d.slots.len) return error.Malformed;
            var slot: Object = .init(d.arena);
            for (0..try d.count()) |_| {
                const placeholder = try d.stringRef() orelse return error.Malformed;
                try slot.put(placeholder, try d.readAttachment(placeholder));
            }
            try attachments.put(d.slots[slot_index], slot.value());
        }
        if (attachments.map.count() > 0) try skin.put("attachments", attachments.value());
        if (color) |c| try skin.color("color", c, skin_color);
        return skin.value();
    }

    fn readAttachment(d: *Decoder, placeholder: []const u8) E!Value {
        var a: Object = .init(d.arena);
        const flags = try d.r.byte();
        const attachment_name = if (flags & 8 != 0) try d.stringRef() orelse placeholder else placeholder;
        if (!std.mem.eql(u8, attachment_name, placeholder)) try a.put("name", .{ .string = attachment_name });
        const kind = try d.enumName(&attachment_type_names, flags & 7);
        if (flags & 7 != 0) try a.put("type", .{ .string = kind });
        switch (flags & 7) {
            0 => {
                try d.path(&a, flags, attachment_name);
                if (flags & 32 != 0) try a.color("color", try d.r.int(u32), white);
                const sequence = try d.readSequence(flags & 64 != 0);
                if (flags & 128 != 0) try a.float("rotation", try d.r.float(), 0);
                try a.float("x", try d.r.float(), 0);
                try a.float("y", try d.r.float(), 0);
                try a.float("scaleX", try d.r.float(), 1);
                try a.float("scaleY", try d.r.float(), 1);
                try a.put("width", .{ .float = try d.r.float() });
                try a.put("height", .{ .float = try d.r.float() });
                if (sequence) |s| try a.put("sequence", s);
            },
            1 => {
                _ = try d.readVertices(&a, flags & 16 != 0);
                if (d.nonessential) try a.color("color", try d.r.int(u32), 0x60f000ff);
            },
            2 => {
                try d.path(&a, flags, attachment_name);
                if (flags & 32 != 0) try a.color("color", try d.r.int(u32), white);
                const sequence = try d.readSequence(flags & 64 != 0);
                const hull = try d.count();
                const vertex_count = try d.readVertices(&a, flags & 128 != 0);
                _ = a.map.orderedRemove("vertexCount");
                try a.put("uvs", try d.floats(vertex_count * 2));
                const triangle_count = std.math.sub(usize, vertex_count * 2, hull + 2) catch return error.Malformed;
                try a.put("triangles", try d.ints(std.math.mul(usize, triangle_count, 3) catch return error.Malformed));
                try a.put("hull", .{ .integer = @intCast(hull) });
                if (d.nonessential) {
                    try a.put("edges", try d.ints(try d.count()));
                    try a.float("width", try d.r.float(), 0);
                    try a.float("height", try d.r.float(), 0);
                }
                if (sequence) |s| try a.put("sequence", s);
            },
            3 => {
                try d.path(&a, flags, attachment_name);
                if (flags & 32 != 0) try a.color("color", try d.r.int(u32), white);
                const sequence = try d.readSequence(flags & 64 != 0);
                try a.boolean("timelines", flags & 128 != 0, true);
                try a.put("skin", .{ .integer = try d.unsigned() });
                try a.put("parent", .{ .string = try d.stringRef() orelse return error.Malformed });
                if (d.nonessential) {
                    try a.float("width", try d.r.float(), 0);
                    try a.float("height", try d.r.float(), 0);
                }
                if (sequence) |s| try a.put("sequence", s);
            },
            4 => {
                try a.boolean("closed", flags & 16 != 0, false);
                try a.boolean("constantSpeed", flags & 32 != 0, true);
                const vertex_count = try d.readVertices(&a, flags & 64 != 0);
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
                _ = try d.readVertices(&a, flags & 16 != 0);
                if (d.nonessential) try a.color("color", try d.r.int(u32), 0x3a3aceff);
            },
            else => return error.Malformed,
        }
        return a.value();
    }

    fn path(d: *Decoder, a: *Object, flags: u8, attachment_name: []const u8) E!void {
        if (flags & 16 == 0) return;
        const p = try d.stringRef() orelse return;
        if (!std.mem.eql(u8, p, attachment_name)) try a.put("path", .{ .string = p });
    }

    fn readSequence(d: *Decoder, present: bool) E!?Value {
        if (!present) return null;
        var s: Object = .init(d.arena);
        try s.put("count", .{ .integer = try d.unsigned() });
        try s.int("start", try d.unsigned(), 1);
        try s.int("digits", try d.unsigned(), 0);
        try s.int("setup", try d.unsigned(), 0);
        return s.value();
    }

    /// Returns the vertex count
    fn readVertices(d: *Decoder, a: *Object, weighted: bool) E!usize {
        const vertex_count = try d.count();
        try a.put("vertexCount", .{ .integer = @intCast(vertex_count) });
        if (!weighted) {
            try a.put("vertices", try d.floats(vertex_count * 2));
            return vertex_count;
        }
        var values = tree.array(d.arena);
        for (0..vertex_count) |_| {
            const bone_count = try d.count();
            try values.append(.{ .integer = @intCast(bone_count) });
            for (0..bone_count) |_| {
                try values.append(.{ .integer = try d.unsigned() });
                for (0..3) |_| try values.append(.{ .float = try d.r.float() });
            }
        }
        try a.put("vertices", .{ .array = values });
        return vertex_count;
    }

    fn readAnimation(d: *Decoder) E!Value {
        _ = try d.count();
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
                            try key.string("name", try d.stringRef());
                            try keys.append(key.value());
                        }
                        break :attachments .{ .array = keys };
                    },
                    1 => try d.curveTimeline(frame_count, .rgba),
                    2 => try d.curveTimeline(frame_count, .rgb),
                    3 => try d.curveTimeline(frame_count, .rgba2),
                    4 => try d.curveTimeline(frame_count, .rgb2),
                    5 => try d.curveTimeline(frame_count, .alpha),
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
                try timelines.put(timeline_name, switch (kind) {
                    0, 2, 3, 8, 9 => try d.curveTimeline(frame_count, .{ .value = 0 }),
                    5, 6 => try d.curveTimeline(frame_count, .{ .value = 1 }),
                    1, 7 => try d.curveTimeline(frame_count, .{ .pair = 0 }),
                    4 => try d.curveTimeline(frame_count, .{ .pair = 1 }),
                    10 => inherit: {
                        var keys = tree.array(d.arena);
                        for (0..frame_count) |_| {
                            var key: Object = .init(d.arena);
                            try key.float("time", try d.r.float(), 0);
                            const inherit = try d.enumName(&inherit_names, try d.r.byte());
                            if (!std.mem.eql(u8, inherit, "normal")) try key.put("inherit", .{ .string = inherit });
                            try keys.append(key.value());
                        }
                        break :inherit .{ .array = keys };
                    },
                    else => unreachable,
                });
            }
            try bones.put(bone_name, timelines.value());
        }
        if (bones.map.count() > 0) try animation.put("bones", bones.value());

        var ik: Object = .init(d.arena);
        for (0..try d.count()) |_| {
            const constraint_name = try d.pick(d.constraints[@backingInt(ConstraintKind.ik)]);
            try ik.put(constraint_name, try d.ikTimeline(try d.count()));
        }
        if (ik.map.count() > 0) try animation.put("ik", ik.value());

        var transform: Object = .init(d.arena);
        for (0..try d.count()) |_| {
            const constraint_name = try d.pick(d.constraints[@backingInt(ConstraintKind.transform)]);
            try transform.put(constraint_name, try d.curveTimeline(try d.count(), .transform));
        }
        if (transform.map.count() > 0) try animation.put("transform", transform.value());

        var paths: Object = .init(d.arena);
        for (0..try d.count()) |_| {
            const constraint_name = try d.pick(d.constraints[@backingInt(ConstraintKind.path)]);
            var timelines: Object = .init(d.arena);
            for (0..try d.count()) |_| {
                const kind = try d.r.byte();
                const timeline_name = try d.enumName(&path_timeline_names, kind);
                const frame_count = try d.count();
                const shape: Shape = if (kind == 2) .path_mix else .{ .value = 0 };
                try timelines.put(timeline_name, try d.curveTimeline(frame_count, shape));
            }
            try paths.put(constraint_name, timelines.value());
        }
        if (paths.map.count() > 0) try animation.put("path", paths.value());

        var physics: Object = .init(d.arena);
        const physics_names = d.constraints[@backingInt(ConstraintKind.physics)];
        for (0..try d.count()) |_| {
            const index = try d.unsigned();
            const constraint_name = if (index == 0) "" else if (index - 1 < physics_names.len) physics_names[index - 1] else return error.Malformed;
            var timelines: Object = .init(d.arena);
            for (0..try d.count()) |_| {
                const kind = try d.r.byte();
                const timeline_name = try d.enumName(&physics_timeline_names, kind);
                if (kind == 3) return error.Malformed;
                const frame_count = try d.count();
                try timelines.put(timeline_name, if (kind == 8) reset: {
                    var keys = tree.array(d.arena);
                    for (0..frame_count) |_| {
                        var key: Object = .init(d.arena);
                        try key.float("time", try d.r.float(), 0);
                        try keys.append(key.value());
                    }
                    break :reset .{ .array = keys };
                } else try d.curveTimeline(frame_count, .{ .value = 0 }));
            }
            try physics.put(constraint_name, timelines.value());
        }
        if (physics.map.count() > 0) try animation.put("physics", physics.value());

        var attachments: Object = .init(d.arena);
        for (0..try d.count()) |_| {
            const skin_name = try d.pick(d.skins);
            var skin: Object = .init(d.arena);
            for (0..try d.count()) |_| {
                const slot_name = try d.pick(d.slots);
                var slot: Object = .init(d.arena);
                for (0..try d.count()) |_| {
                    const attachment_name = try d.stringRef() orelse return error.Malformed;
                    var timelines: Object = .init(d.arena);
                    const kind = try d.r.byte();
                    const frame_count = try d.count();
                    switch (kind) {
                        0 => try timelines.put("deform", try d.curveTimeline(frame_count, .deform)),
                        1 => {
                            var keys = tree.array(d.arena);
                            var last_delay: f32 = 0;
                            for (0..frame_count) |_| {
                                var key: Object = .init(d.arena);
                                try key.float("time", try d.r.float(), 0);
                                const mode_and_index = try d.r.int(i32);
                                const mode = try d.enumName(&sequence_mode_names, @intCast(mode_and_index & 0xf));
                                if (!std.mem.eql(u8, mode, "hold")) try key.put("mode", .{ .string = mode });
                                try key.int("index", mode_and_index >> 4, 0);
                                const delay = try d.r.float();
                                try key.float("delay", delay, last_delay);
                                last_delay = delay;
                                try keys.append(key.value());
                            }
                            try timelines.put("sequence", .{ .array = keys });
                        },
                        else => return error.Malformed,
                    }
                    try mergeInto(&slot, attachment_name, timelines);
                }
                try skin.put(slot_name, slot.value());
            }
            try attachments.put(skin_name, skin.value());
        }
        if (attachments.map.count() > 0) try animation.put("attachments", attachments.value());

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
                if (try d.r.string()) |s| {
                    if (!std.mem.eql(u8, s, e.string orelse "")) try key.put("string", .{ .string = s });
                }
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

    fn mergeInto(slot: *Object, attachment_name: []const u8, timelines: Object) Error!void {
        const existing = slot.map.getPtr(attachment_name) orelse return slot.put(attachment_name, timelines.value());
        var it = timelines.map.iterator();
        while (it.next()) |entry| try existing.object.put(slot.arena, entry.key_ptr.*, entry.value_ptr.*);
    }

    fn ikTimeline(d: *Decoder, frame_count: usize) E!Value {
        _ = try d.count();
        var keys = tree.array(d.arena);
        var previous: ?Object = null;
        for (0..frame_count) |_| {
            const flags = try d.r.byte();
            var key: Object = .init(d.arena);
            try key.float("time", try d.r.float(), 0);
            const mix: f32 = if (flags & 1 == 0) 0 else if (flags & 2 != 0) try d.r.float() else 1;
            try key.float("mix", mix, 1);
            if (flags & 4 != 0) try key.float("softness", try d.r.float(), 0);
            try key.boolean("bendPositive", flags & 8 != 0, true);
            try key.boolean("compress", flags & 16 != 0, false);
            try key.boolean("stretch", flags & 32 != 0, false);
            if (previous) |*p| {
                if (flags & 64 != 0) {
                    try p.put("curve", .{ .string = "stepped" });
                } else if (flags & 128 != 0) {
                    try p.put("curve", try d.floats(8));
                }
                try keys.append(p.value());
            }
            previous = key;
        }
        if (previous) |p| try keys.append(p.value());
        return .{ .array = keys };
    }

    const Shape = union(enum) {
        value: f32,
        pair: f32,
        rgba,
        rgb,
        rgba2,
        rgb2,
        alpha,
        transform,
        path_mix,
        deform,
    };

    /// Curves trail the next key except in deform
    fn curveTimeline(d: *Decoder, frame_count: usize, shape: Shape) E!Value {
        _ = try d.count();
        var keys = tree.array(d.arena);
        var previous: ?Object = null;
        var time: f32 = if (shape == .deform and frame_count > 0) try d.r.float() else 0;
        for (0..frame_count) |frame| {
            var key: Object = .init(d.arena);
            if (shape != .deform) time = try d.r.float();
            try key.float("time", time, 0);
            const channels = try d.keyValues(&key, shape);
            if (shape == .deform) {
                if (frame + 1 < frame_count) {
                    time = try d.r.float();
                    try d.curve(&key, channels);
                }
                try keys.append(key.value());
                continue;
            }
            if (previous) |*p| {
                try d.curve(p, channels);
                try keys.append(p.value());
            }
            previous = key;
        }
        if (previous) |p| try keys.append(p.value());
        return .{ .array = keys };
    }

    fn curve(d: *Decoder, key: *Object, channels: usize) E!void {
        switch (try d.r.byte()) {
            curve_linear => {},
            curve_stepped => try key.put("curve", .{ .string = "stepped" }),
            curve_bezier => try key.put("curve", try d.floats(channels * 4)),
            else => return error.Malformed,
        }
    }

    /// Returns the channel count
    fn keyValues(d: *Decoder, key: *Object, shape: Shape) E!usize {
        switch (shape) {
            .value => |default| {
                try key.float("value", try d.r.float(), default);
                return 1;
            },
            .pair => |default| {
                try key.float("x", try d.r.float(), default);
                try key.float("y", try d.r.float(), default);
                return 2;
            },
            .rgba => {
                try key.put("color", .{ .string = try tree.hex(d.arena, try d.r.int(u32), 8) });
                return 4;
            },
            .rgb => {
                try key.put("color", .{ .string = try tree.hex(d.arena, try d.r.int(u24), 6) });
                return 3;
            },
            .rgba2 => {
                try key.put("light", .{ .string = try tree.hex(d.arena, try d.r.int(u32), 8) });
                try key.put("dark", .{ .string = try tree.hex(d.arena, try d.r.int(u24), 6) });
                return 7;
            },
            .rgb2 => {
                try key.put("light", .{ .string = try tree.hex(d.arena, try d.r.int(u24), 6) });
                try key.put("dark", .{ .string = try tree.hex(d.arena, try d.r.int(u24), 6) });
                return 6;
            },
            .alpha => {
                try key.float("value", @as(f32, @floatFromInt(try d.r.byte())) / 255, 0);
                return 1;
            },
            .transform => {
                var mixes: [6]f32 = undefined;
                for (&mixes) |*m| m.* = try d.r.float();
                try transformMixes(key, mixes);
                return 6;
            },
            .path_mix => {
                try key.float("mixRotate", try d.r.float(), 1);
                const mix_x = try d.r.float();
                try key.float("mixX", mix_x, 1);
                try key.float("mixY", try d.r.float(), mix_x);
                return 3;
            },
            .deform => {
                const end = try d.count();
                if (end > 0) {
                    try key.int("offset", try d.unsigned(), 0);
                    try key.put("vertices", try d.floats(end));
                }
                return 1;
            },
        }
    }

    fn floats(d: *Decoder, n: usize) E!Value {
        if (n > (d.r.data.len - d.r.pos) / 4) return error.Malformed;
        var values = try std.json.Array.initCapacity(d.arena, n);
        for (0..n) |_| values.appendAssumeCapacity(.{ .float = try d.r.float() });
        return .{ .array = values };
    }

    fn ints(d: *Decoder, n: usize) E!Value {
        if (n > d.r.data.len - d.r.pos) return error.Malformed;
        var values = try std.json.Array.initCapacity(d.arena, n);
        for (0..n) |_| values.appendAssumeCapacity(.{ .integer = try d.unsigned() });
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
    strings: Names = .empty,
    bones: Names = .empty,
    slots: Names = .empty,
    constraints: [constraint_type_names.len]Names = @splat(.empty),
    skins: Names = .empty,
    skin_values: std.ArrayList(Value) = .empty,
    events: std.json.ObjectMap = .empty,
    animations: std.json.ObjectMap = .empty,

    fn skeletonData(e: *Encoder, version_text: []const u8) Error![]const u8 {
        const skeleton = tree.get(e.root, "skeleton") orelse Value{ .object = .empty };
        var head: Writer = .{ .arena = e.arena };
        const hash = try tree.getHash(skeleton);
        try head.bytes(&hash);
        try head.string(try tree.getString(skeleton, "spine") orelse version_text);
        for ([_][]const u8{ "x", "y", "width", "height" }) |key| try head.float(try tree.getFloat(skeleton, key, 0));
        try head.float(try tree.getFloat(skeleton, "referenceScale", 100));
        for ([_][]const u8{ "fps", "images", "audio" }) |key| {
            if (skeleton == .object and skeleton.object.contains(key)) e.nonessential = true;
        }
        try head.boolean(e.nonessential);
        if (e.nonessential) {
            try head.float(try tree.getFloat(skeleton, "fps", 30));
            try head.string(try tree.getString(skeleton, "images"));
            try head.string(try tree.getString(skeleton, "audio"));
        }

        try e.collectNames();
        try e.writeBones();
        try e.writeSlots();
        try e.writeConstraints();
        try e.writeSkins();
        try e.writeEvents();
        try e.w.count(e.animations.count());
        for (e.animations.keys(), e.animations.values()) |name, animation| {
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
        for (constraint_type_names, &e.constraints) |key, *names| {
            for (try tree.getArray(e.root, key)) |c| {
                const entry = try names.getOrPut(e.arena, try tree.requireString(c, "name"));
                if (entry.found_existing) return error.Malformed;
            }
        }
        e.events = try tree.getObject(e.root, "events");
        e.animations = try tree.getObject(e.root, "animations");
        const skins = try tree.getArray(e.root, "skins");
        for (skins) |skin| {
            if (!std.mem.eql(u8, try tree.requireString(skin, "name"), "default")) continue;
            if ((try tree.getObject(skin, "attachments")).count() == 0) continue;
            const entry = try e.skins.getOrPut(e.arena, "default");
            if (entry.found_existing) return error.Malformed;
            try e.skin_values.append(e.arena, skin);
        }
        for (skins) |skin| {
            const name = try tree.requireString(skin, "name");
            if (std.mem.eql(u8, name, "default")) continue;
            const entry = try e.skins.getOrPut(e.arena, name);
            if (entry.found_existing) return error.Malformed;
            try e.skin_values.append(e.arena, skin);
        }
    }

    fn constraintIndex(e: *Encoder, kind: ConstraintKind, name: []const u8) Error!u32 {
        return indexOf(e.constraints[@backingInt(kind)], name);
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
            try e.w.byte(try enumIndex(&inherit_names, try tree.getString(b, "inherit") orelse "normal"));
            try e.w.boolean(try tree.getBool(b, "skin", false));
            if (e.nonessential) {
                try e.w.int(u32, try tree.getColor(b, "color", bone_color));
                try e.w.string(try tree.getString(b, "icon"));
                try e.w.boolean(try tree.getBool(b, "visible", true));
            }
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
            if (e.nonessential) try e.w.boolean(try tree.getBool(s, "visible", true));
        }
    }

    fn writeConstraints(e: *Encoder) Error!void {
        for (constraint_type_names, 0..) |key, i| {
            const kind: ConstraintKind = @fromBackingInt(@intCast(i));
            const constraints = try tree.getArray(e.root, key);
            try e.w.count(constraints.len);
            for (constraints) |c| {
                try e.w.string(try tree.requireString(c, "name"));
                try e.w.count(try tree.getNatural(c, "order", 0));
                const skin = try tree.getBool(c, "skin", false);
                switch (kind) {
                    .ik => {
                        try e.boneList(c, "bones");
                        try e.w.count(try indexOf(e.bones, try tree.requireString(c, "target")));
                        const mix = try tree.getFloat(c, "mix", 1);
                        const softness = try tree.getFloat(c, "softness", 0);
                        var flags: u8 = @intFromBool(skin);
                        if (try tree.getBool(c, "bendPositive", true)) flags |= 2;
                        if (try tree.getBool(c, "compress", false)) flags |= 4;
                        if (try tree.getBool(c, "stretch", false)) flags |= 8;
                        if (try tree.getBool(c, "uniform", false)) flags |= 16;
                        if (mix != 0) flags |= 32;
                        if (mix != 0 and mix != 1) flags |= 64;
                        if (softness != 0) flags |= 128;
                        try e.w.byte(flags);
                        if (flags & 64 != 0) try e.w.float(mix);
                        if (flags & 128 != 0) try e.w.float(softness);
                    },
                    .transform => {
                        try e.boneList(c, "bones");
                        try e.w.count(try indexOf(e.bones, try tree.requireString(c, "target")));
                        var values: [12]f32 = undefined;
                        for (values[0..6], transform_offsets) |*v, k| v.* = try tree.getFloat(c, k, 0);
                        const mixes = values[6..];
                        for (mixes, transform_mixes, 0..) |*m, k, j| {
                            m.* = try tree.getFloat(c, k, if (j == 2 or j == 4) mixes[j - 1] else 1);
                        }
                        var flags: u16 = @intFromBool(skin);
                        if (try tree.getBool(c, "local", false)) flags |= 2;
                        if (try tree.getBool(c, "relative", false)) flags |= 4;
                        for (values, 3..) |v, bit| {
                            if (v != 0) flags |= @as(u16, 1) << @intCast(bit);
                        }
                        try e.w.byte(@truncate(flags));
                        for (values[0..5]) |v| if (v != 0) try e.w.float(v);
                        try e.w.byte(@intCast(flags >> 8));
                        for (values[5..]) |v| if (v != 0) try e.w.float(v);
                    },
                    .path => {
                        try e.w.boolean(skin);
                        try e.boneList(c, "bones");
                        try e.w.count(try indexOf(e.slots, try tree.requireString(c, "target")));
                        const position_mode = try enumIndex(&position_names, try tree.getString(c, "positionMode") orelse "percent");
                        const spacing_mode = try enumIndex(&spacing_names, try tree.getString(c, "spacingMode") orelse "length");
                        const rotate_mode = try enumIndex(&rotate_names, try tree.getString(c, "rotateMode") orelse "tangent");
                        const rotation = try tree.getFloat(c, "rotation", 0);
                        var flags = position_mode | spacing_mode << 1 | rotate_mode << 3;
                        if (rotation != 0) flags |= 128;
                        try e.w.byte(flags);
                        if (rotation != 0) try e.w.float(rotation);
                        try e.floats(c, &.{ .{ "position", 0 }, .{ "spacing", 0 }, .{ "mixRotate", 1 }, .{ "mixX", 1 }, .{ "mixY", try tree.getFloat(c, "mixX", 1) } });
                    },
                    .physics => {
                        try e.w.count(try indexOf(e.bones, try tree.requireString(c, "bone")));
                        const fields = [_]Field{ .{ "x", 0 }, .{ "y", 0 }, .{ "rotate", 0 }, .{ "scaleX", 0 }, .{ "shearX", 0 }, .{ "limit", 5000 } };
                        var values: [fields.len]f32 = undefined;
                        const mass = try tree.getFloat(c, "mass", 1);
                        const fps = try tree.getInt(c, "fps", 60);
                        if (fps < 1 or fps > 255) return error.Malformed;
                        var flags: u8 = @intFromBool(skin);
                        for (&values, fields, 1..) |*v, field, bit| {
                            v.* = try tree.getFloat(c, field[0], field[1]);
                            if (v.* != field[1]) flags |= @as(u8, 1) << @intCast(bit);
                        }
                        if (mass != 1) flags |= 128;
                        try e.w.byte(flags);
                        for (values, fields) |v, field| if (v != field[1]) try e.w.float(v);
                        try e.w.byte(@intCast(fps));
                        try e.floats(c, &.{ .{ "inertia", 1 }, .{ "strength", 100 }, .{ "damping", 1 } });
                        if (mass != 1) try e.w.float(1 / mass);
                        try e.floats(c, &.{ .{ "wind", 0 }, .{ "gravity", 0 } });
                        var global_flags: u8 = 0;
                        for (physics_globals, 0..) |k, j| {
                            if (try tree.getBool(c, k, false)) global_flags |= @as(u8, 1) << @intCast(j);
                        }
                        const mix = try tree.getFloat(c, "mix", 1);
                        if (mix != 1) global_flags |= 128;
                        try e.w.byte(global_flags);
                        if (mix != 1) try e.w.float(mix);
                    },
                }
            }
        }
    }

    fn writeSkins(e: *Encoder) Error!void {
        const has_default = e.skins.count() > 0 and std.mem.eql(u8, e.skins.keys()[0], "default");
        if (has_default) try e.writeSkinAttachments(e.skin_values.items[0]) else try e.w.count(0);
        const first: usize = @intFromBool(has_default);
        try e.w.count(e.skins.count() - first);
        for (e.skins.keys()[first..], e.skin_values.items[first..]) |name, skin| {
            try e.w.string(name);
            if (e.nonessential) try e.w.int(u32, try tree.getColor(skin, "color", skin_color));
            try e.boneList(skin, "bones");
            for (constraint_type_names, 0..) |key, i| {
                const names = try tree.getArray(skin, key);
                try e.w.count(names.len);
                for (names) |c| {
                    if (c != .string) return error.Malformed;
                    try e.w.count(try e.constraintIndex(@fromBackingInt(@intCast(i)), c.string));
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
        var kind = try enumIndex(&attachment_type_names, try tree.getString(a, "type") orelse "region");
        if (kind == 2 or kind == 3) kind = if (try tree.getString(a, "parent") != null) 3 else 2;
        const named: u8 = if (std.mem.eql(u8, name, placeholder)) 0 else 8;
        const path = try tree.getString(a, "path");
        const has_path = path != null and !std.mem.eql(u8, path.?, name);
        const color = try tree.getColor(a, "color", white);
        const sequence = tree.get(a, "sequence");
        var flags: u8 = kind | named;
        switch (kind) {
            0, 2, 3 => {
                if (has_path) flags |= 16;
                if (color != white) flags |= 32;
                if (sequence != null) flags |= 64;
            },
            else => {},
        }
        const vertices = try vertexData(a, kind);
        switch (kind) {
            0 => if (try tree.getFloat(a, "rotation", 0) != 0) {
                flags |= 128;
            },
            1, 6 => if (vertices.weighted) {
                flags |= 16;
            },
            2 => if (vertices.weighted) {
                flags |= 128;
            },
            3 => if (try tree.getBool(a, "timelines", true)) {
                flags |= 128;
            },
            4 => {
                if (try tree.getBool(a, "closed", false)) flags |= 16;
                if (try tree.getBool(a, "constantSpeed", true)) flags |= 32;
                if (vertices.weighted) flags |= 64;
            },
            else => {},
        }
        try e.w.byte(flags);
        if (named != 0) try e.ref(name);
        if (flags & 16 != 0 and (kind == 0 or kind == 2 or kind == 3)) try e.ref(path);
        if (flags & 32 != 0 and (kind == 0 or kind == 2 or kind == 3)) try e.w.int(u32, color);
        if (flags & 64 != 0 and (kind == 0 or kind == 2 or kind == 3)) {
            const s = sequence.?;
            try e.w.count(try tree.getNatural(s, "count", 0));
            try e.w.count(try tree.getNatural(s, "start", 1));
            try e.w.count(try tree.getNatural(s, "digits", 0));
            try e.w.count(try tree.getNatural(s, "setup", 0));
        }
        switch (kind) {
            0 => {
                if (flags & 128 != 0) try e.w.float(try tree.getFloat(a, "rotation", 0));
                try e.floats(a, &.{ .{ "x", 0 }, .{ "y", 0 }, .{ "scaleX", 1 }, .{ "scaleY", 1 }, .{ "width", 32 }, .{ "height", 32 } });
            },
            1 => {
                try e.writeVertices(vertices);
                if (e.nonessential) try e.w.int(u32, try tree.getColor(a, "color", 0x60f000ff));
            },
            2 => {
                const triangles = try tree.getArray(a, "triangles");
                var hull: usize = try tree.getNatural(a, "hull", 0);
                const fits = std.math.sub(usize, vertices.count * 2, @as(usize, hull) + 2) catch return error.Malformed;
                if (triangles.len > fits * 3) {
                    // a smaller hull makes room for every triangle
                    const slots = vertices.count * 2 - 2;
                    if (triangles.len % 3 == 0 and triangles.len / 3 <= slots) {
                        hull = slots - triangles.len / 3;
                        try e.report.add(.{
                            .code = .@"mesh.hull.approximated",
                            .step = "",
                            .path = name,
                            .message = try std.fmt.allocPrint(e.arena, "hull lowered to {d} so the binary keeps every triangle", .{hull}),
                        });
                    } else try e.report.add(.{
                        .code = .@"mesh.triangles.approximated",
                        .step = "",
                        .path = name,
                        .message = "binary keeps two triangles per vertex minus the hull",
                    });
                }
                try e.w.count(hull);
                try e.writeVertices(vertices);
                const uvs = try tree.getArray(a, "uvs");
                if (uvs.len != vertices.count * 2) return error.Malformed;
                for (uvs) |v| try e.w.float(try tree.number(v));
                const expected = vertices.count * 2 - hull - 2;
                if (triangles.len < expected * 3) try e.report.add(.{
                    .code = .@"mesh.padding.approximated",
                    .step = "",
                    .path = name,
                    .message = "binary fills two triangles per vertex minus the hull with degenerate ones",
                });
                const kept = @min(triangles.len, expected * 3);
                for (triangles[0..kept]) |t| try e.w.count(try tree.natural(t));
                const degenerate = if (kept > 0) try tree.natural(triangles[0]) else 0;
                for (kept..expected * 3) |_| try e.w.count(degenerate);
                if (e.nonessential) {
                    const edges = try tree.getArray(a, "edges");
                    try e.w.count(edges.len);
                    for (edges) |edge| try e.w.count(try tree.natural(edge));
                    try e.floats(a, &.{ .{ "width", 0 }, .{ "height", 0 } });
                }
            },
            3 => {
                try e.w.count(try indexOf(e.skins, try tree.getString(a, "skin") orelse "default"));
                try e.ref(try tree.requireString(a, "parent"));
                if (e.nonessential) try e.floats(a, &.{ .{ "width", 0 }, .{ "height", 0 } });
            },
            4 => {
                try e.writeVertices(vertices);
                const lengths = try tree.getArray(a, "lengths");
                if (lengths.len != vertices.count / 3) return error.Malformed;
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
                try e.writeVertices(vertices);
                if (e.nonessential) try e.w.int(u32, try tree.getColor(a, "color", 0x3a3aceff));
            },
            else => return error.Malformed,
        }
    }

    const Vertices = struct {
        count: usize = 0,
        weighted: bool = false,
        values: []const Value = &.{},
    };

    fn vertexData(a: Value, kind: u8) Error!Vertices {
        if (kind == 0 or kind == 3 or kind == 5) return .{};
        const values = try tree.getArray(a, "vertices");
        const count: usize = if (kind == 2) (try tree.getArray(a, "uvs")).len / 2 else try tree.getNatural(a, "vertexCount", 0);
        return .{ .count = count, .weighted = values.len != count * 2, .values = values };
    }

    fn writeVertices(e: *Encoder, v: Vertices) Error!void {
        try e.w.count(v.count);
        if (!v.weighted) {
            for (v.values) |x| try e.w.float(try tree.number(x));
            return;
        }
        var i: usize = 0;
        var vertex_count: usize = 0;
        while (i < v.values.len) : (vertex_count += 1) {
            const bone_count: usize = try tree.natural(v.values[i]);
            if (bone_count > (v.values.len - i - 1) / 4) return error.Malformed;
            i += 1 + bone_count * 4;
        }
        if (i != v.values.len or vertex_count != v.count) return error.Malformed;
        i = 0;
        while (i < v.values.len) {
            const bone_count: usize = try tree.natural(v.values[i]);
            try e.w.count(bone_count);
            for (v.values[i + 1 ..][0 .. bone_count * 4], 0..) |x, j| {
                if (j % 4 == 0) try e.w.count(try tree.natural(x)) else try e.w.float(try tree.number(x));
            }
            i += 1 + bone_count * 4;
        }
    }

    fn writeEvents(e: *Encoder) Error!void {
        try e.w.count(e.events.count());
        for (e.events.keys(), e.events.values()) |name, event| {
            try e.w.string(name);
            try e.w.varint(try tree.getInt(event, "int", 0), false);
            try e.w.float(try tree.getFloat(event, "float", 0));
            try e.w.string(try tree.getString(event, "string"));
            const audio = try tree.getString(event, "audio");
            try e.w.string(audio);
            if (audio != null) try e.floats(event, &.{ .{ "volume", 1 }, .{ "balance", 0 } });
        }
    }

    fn writeAnimation(e: *Encoder, animation: Value) Error!void {
        const slots = try tree.getObject(animation, "slots");
        const bones = try tree.getObject(animation, "bones");
        const ik = try tree.getObject(animation, "ik");
        const transform = try tree.getObject(animation, "transform");
        const paths = try tree.getObject(animation, "path");
        const physics = try tree.getObject(animation, "physics");
        const attachments = try tree.getObject(animation, "attachments");
        const draw_order = try tree.getArray(animation, "drawOrder");
        const events = try tree.getArray(animation, "events");

        var timeline_count: usize = @as(usize, @intFromBool(draw_order.len > 0)) + @intFromBool(events.len > 0);
        for ([_]std.json.ObjectMap{ slots, bones, paths, physics }) |group| {
            for (group.values()) |timelines| timeline_count += try nonEmpty(timelines);
        }
        for ([_]std.json.ObjectMap{ ik, transform }) |group| timeline_count += try nonEmptyKeys(group);
        for (attachments.values()) |skin| {
            for ((try objectOf(skin)).values()) |slot| {
                for ((try objectOf(slot)).values()) |timelines| timeline_count += try nonEmpty(timelines);
            }
        }
        try e.w.count(timeline_count);

        try e.w.count(slots.count());
        for (slots.keys(), slots.values()) |slot_name, timelines| {
            try e.w.count(try indexOf(e.slots, slot_name));
            const map = try objectOf(timelines);
            try e.w.count(try nonEmpty(timelines));
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
                    1 => try e.curveKeys(items, .rgba),
                    2 => try e.curveKeys(items, .rgb),
                    3 => try e.curveKeys(items, .rgba2),
                    4 => try e.curveKeys(items, .rgb2),
                    5 => try e.curveKeys(items, .alpha),
                    else => unreachable,
                }
            }
        }

        try e.w.count(bones.count());
        for (bones.keys(), bones.values()) |bone_name, timelines| {
            try e.w.count(try indexOf(e.bones, bone_name));
            const map = try objectOf(timelines);
            try e.w.count(try nonEmpty(timelines));
            for (map.keys(), map.values()) |timeline_name, keys| {
                const items = try keysOf(keys) orelse continue;
                const kind = try enumIndex(&bone_timeline_names, timeline_name);
                try e.w.byte(kind);
                try e.w.count(items.len);
                switch (kind) {
                    0, 2, 3, 8, 9 => try e.curveKeys(items, .{ .value = 0 }),
                    5, 6 => try e.curveKeys(items, .{ .value = 1 }),
                    1, 7 => try e.curveKeys(items, .{ .pair = 0 }),
                    4 => try e.curveKeys(items, .{ .pair = 1 }),
                    10 => for (items) |key| {
                        try e.w.float(try tree.getFloat(key, "time", 0));
                        try e.w.byte(try enumIndex(&inherit_names, try tree.getString(key, "inherit") orelse "normal"));
                    },
                    else => unreachable,
                }
            }
        }

        try e.w.count(try nonEmptyKeys(ik));
        for (ik.keys(), ik.values()) |constraint_name, keys| {
            const items = try keysOf(keys) orelse continue;
            try e.w.count(try e.constraintIndex(.ik, constraint_name));
            try e.w.count(items.len);
            try e.w.count(bezierCount(items, 2));
            for (items, 0..) |key, i| {
                const mix = try tree.getFloat(key, "mix", 1);
                const softness = try tree.getFloat(key, "softness", 0);
                var flags: u8 = 0;
                if (mix != 0) flags |= 1;
                if (mix != 0 and mix != 1) flags |= 2;
                if (softness != 0) flags |= 4;
                if (try tree.getBool(key, "bendPositive", true)) flags |= 8;
                if (try tree.getBool(key, "compress", false)) flags |= 16;
                if (try tree.getBool(key, "stretch", false)) flags |= 32;
                const previous_curve = if (i > 0) tree.get(items[i - 1], "curve") else null;
                if (previous_curve) |c| flags |= if (c == .string) 64 else 128;
                try e.w.byte(flags);
                try e.w.float(try tree.getFloat(key, "time", 0));
                if (flags & 2 != 0) try e.w.float(mix);
                if (flags & 4 != 0) try e.w.float(softness);
                if (flags & 128 != 0) try e.bezier(previous_curve.?, 2);
            }
        }

        try e.w.count(try nonEmptyKeys(transform));
        for (transform.keys(), transform.values()) |constraint_name, keys| {
            const items = try keysOf(keys) orelse continue;
            try e.w.count(try e.constraintIndex(.transform, constraint_name));
            try e.w.count(items.len);
            try e.curveKeys(items, .transform);
        }

        try e.w.count(paths.count());
        for (paths.keys(), paths.values()) |constraint_name, timelines| {
            try e.w.count(try e.constraintIndex(.path, constraint_name));
            const map = try objectOf(timelines);
            try e.w.count(try nonEmpty(timelines));
            for (map.keys(), map.values()) |timeline_name, keys| {
                const items = try keysOf(keys) orelse continue;
                const kind = try enumIndex(&path_timeline_names, timeline_name);
                try e.w.byte(kind);
                try e.w.count(items.len);
                try e.curveKeys(items, if (kind == 2) .path_mix else .{ .value = 0 });
            }
        }

        try e.w.count(physics.count());
        for (physics.keys(), physics.values()) |constraint_name, timelines| {
            try e.w.count(if (constraint_name.len == 0) 0 else 1 + try e.constraintIndex(.physics, constraint_name));
            const map = try objectOf(timelines);
            try e.w.count(try nonEmpty(timelines));
            for (map.keys(), map.values()) |timeline_name, keys| {
                const items = try keysOf(keys) orelse continue;
                const kind = try enumIndex(&physics_timeline_names, timeline_name);
                if (timeline_name.len == 0) return error.Malformed;
                try e.w.byte(kind);
                try e.w.count(items.len);
                if (kind == 8) {
                    for (items) |key| try e.w.float(try tree.getFloat(key, "time", 0));
                } else try e.curveKeys(items, .{ .value = 0 });
            }
        }

        try e.w.count(attachments.count());
        for (attachments.keys(), attachments.values()) |skin_name, skin| {
            try e.w.count(try indexOf(e.skins, skin_name));
            const skin_map = try objectOf(skin);
            try e.w.count(skin_map.count());
            for (skin_map.keys(), skin_map.values()) |slot_name, slot| {
                try e.w.count(try indexOf(e.slots, slot_name));
                const slot_map = try objectOf(slot);
                var entries: usize = 0;
                for (slot_map.values()) |timelines| entries += try nonEmpty(timelines);
                try e.w.count(entries);
                for (slot_map.keys(), slot_map.values()) |attachment_name, timelines| {
                    const map = try objectOf(timelines);
                    for (map.keys(), map.values()) |timeline_name, keys| {
                        const items = try keysOf(keys) orelse continue;
                        try e.ref(attachment_name);
                        if (std.mem.eql(u8, timeline_name, "deform")) {
                            try e.w.byte(0);
                            try e.w.count(items.len);
                            try e.curveKeys(items, .deform);
                        } else if (std.mem.eql(u8, timeline_name, "sequence")) {
                            try e.w.byte(1);
                            try e.w.count(items.len);
                            var last_delay: f32 = 0;
                            for (items) |key| {
                                try e.w.float(try tree.getFloat(key, "time", 0));
                                const mode: i32 = try enumIndex(&sequence_mode_names, try tree.getString(key, "mode") orelse "hold");
                                const index = std.math.shlExact(i32, try tree.getNatural(key, "index", 0), 4) catch return error.Malformed;
                                try e.w.int(i32, mode | index);
                                last_delay = try tree.getFloat(key, "delay", last_delay);
                                try e.w.float(last_delay);
                            }
                        } else return error.Malformed;
                    }
                }
            }
        }

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

        try e.w.count(events.len);
        for (events) |key| {
            try e.w.float(try tree.getFloat(key, "time", 0));
            const name = try tree.requireString(key, "name");
            const index = e.events.getIndex(name) orelse return error.Malformed;
            const setup = e.events.values()[index];
            try e.w.count(index);
            try e.w.varint(try tree.getInt(key, "int", try tree.getInt(setup, "int", 0)), false);
            try e.w.float(try tree.getFloat(key, "float", try tree.getFloat(setup, "float", 0)));
            try e.w.string(try tree.getString(key, "string"));
            if (try tree.getString(setup, "audio") != null) {
                try e.w.float(try tree.getFloat(key, "volume", try tree.getFloat(setup, "volume", 1)));
                try e.w.float(try tree.getFloat(key, "balance", try tree.getFloat(setup, "balance", 0)));
            }
        }
    }

    const Shape = Decoder.Shape;

    fn channels(shape: Shape) usize {
        return switch (shape) {
            .value, .alpha, .deform => 1,
            .pair => 2,
            .rgb, .path_mix => 3,
            .rgba => 4,
            .rgb2, .transform => 6,
            .rgba2 => 7,
        };
    }

    /// Curves trail the next key except in deform
    fn curveKeys(e: *Encoder, keys: []const Value, shape: Shape) Error!void {
        const n = channels(shape);
        try e.w.count(bezierCount(keys, n));
        if (shape == .deform) try e.w.float(try tree.getFloat(keys[0], "time", 0));
        for (keys, 0..) |key, i| {
            if (shape != .deform) try e.w.float(try tree.getFloat(key, "time", 0));
            try e.keyValues(key, shape);
            if (shape == .deform) {
                if (i + 1 < keys.len) {
                    try e.w.float(try tree.getFloat(keys[i + 1], "time", 0));
                    try e.curve(key, n);
                }
            } else if (i > 0) try e.curve(keys[i - 1], n);
        }
    }

    fn curve(e: *Encoder, key: Value, n: usize) Error!void {
        const c = tree.get(key, "curve") orelse return e.w.byte(curve_linear);
        if (c == .string) return e.w.byte(if (std.mem.eql(u8, c.string, "stepped")) curve_stepped else curve_linear);
        try e.w.byte(curve_bezier);
        try e.bezier(c, n);
    }

    fn bezier(e: *Encoder, c: Value, n: usize) Error!void {
        if (c != .array or c.array.items.len < n * 4) return error.Malformed;
        for (c.array.items[0 .. n * 4]) |v| try e.w.float(try tree.number(v));
    }

    fn bezierCount(keys: []const Value, n: usize) usize {
        var count: usize = 0;
        for (keys[0..keys.len -| 1]) |key| {
            if (tree.get(key, "curve")) |c| {
                if (c == .array) count += n;
            }
        }
        return count;
    }

    fn keyValues(e: *Encoder, key: Value, shape: Shape) Error!void {
        switch (shape) {
            .value => |default| try e.w.float(try tree.getFloat(key, "value", default)),
            .pair => |default| try e.floats(key, &.{ .{ "x", default }, .{ "y", default } }),
            .rgba => try e.w.int(u32, try tree.parseHex(try tree.requireString(key, "color"), 8)),
            .rgb => try e.w.int(u24, @intCast(try tree.parseHex(try tree.requireString(key, "color"), 6))),
            .rgba2 => {
                try e.w.int(u32, try tree.parseHex(try tree.requireString(key, "light"), 8));
                try e.w.int(u24, @intCast(try tree.parseHex(try tree.requireString(key, "dark"), 6)));
            },
            .rgb2 => {
                try e.w.int(u24, @intCast(try tree.parseHex(try tree.requireString(key, "light"), 6)));
                try e.w.int(u24, @intCast(try tree.parseHex(try tree.requireString(key, "dark"), 6)));
            },
            .alpha => try e.w.byte(@intFromFloat(@round(std.math.clamp(try tree.getFloat(key, "value", 0), 0, 1) * 255))),
            .transform => {
                var mixes: [6]f32 = undefined;
                for (&mixes, transform_mixes, 0..) |*m, k, i| {
                    m.* = try tree.getFloat(key, k, if (i == 2 or i == 4) mixes[i - 1] else 1);
                    try e.w.float(m.*);
                }
            },
            .path_mix => {
                try e.floats(key, &.{ .{ "mixRotate", 1 }, .{ "mixX", 1 } });
                try e.w.float(try tree.getFloat(key, "mixY", try tree.getFloat(key, "mixX", 1)));
            },
            .deform => {
                const values = try tree.getArray(key, "vertices");
                try e.w.count(values.len);
                if (values.len == 0) return;
                try e.w.count(try tree.getNatural(key, "offset", 0));
                for (values) |v| try e.w.float(try tree.number(v));
            },
        }
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

    /// Empty key lists are skipped like the JSON readers do
    fn keysOf(v: Value) Error!?[]const Value {
        if (v != .array) return error.Malformed;
        return if (v.array.items.len == 0) null else v.array.items;
    }

    fn nonEmpty(timelines: Value) Error!usize {
        var n: usize = 0;
        for ((try objectOf(timelines)).values()) |keys| n += @intFromBool(try keysOf(keys) != null);
        return n;
    }

    fn nonEmptyKeys(map: std.json.ObjectMap) Error!usize {
        var n: usize = 0;
        for (map.values()) |keys| n += @intFromBool(try keysOf(keys) != null);
        return n;
    }
};

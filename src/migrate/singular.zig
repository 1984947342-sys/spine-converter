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

//! IK and inherit modes under a parent scale near zero

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Report = @import("../Report.zig");
const tree = @import("../binary/tree.zig");
const edit = @import("../edit.zig");

pub const Error = error{ Malformed, OutOfMemory };

/// IK inverts the parent matrix a zero scale makes singular
pub fn check(arena: std.mem.Allocator, doc: *ObjectMap, report: *Report, step: []const u8, reason: []const u8) Error!void {
    var parents: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    var setups: std.StringHashMapUnmanaged([2]f32) = .empty;
    try readBones(arena, doc, &parents, &setups);
    const animations = try edit.childOf(doc, "animations");
    var list: []const u8 = "ik";
    var constraints = try edit.arrayOf(doc, "ik");
    if (constraints.len == 0) {
        list = "constraints";
        constraints = try edit.arrayOf(doc, "constraints");
    }
    for (constraints) |c| {
        if (!std.mem.eql(u8, try tree.getString(c, "type") orelse "ik", "ik")) continue;
        const bones = try tree.getArray(c, "bones");
        if (bones.len == 0) continue;
        if (bones[0] != .string) return error.Malformed;
        const name = try tree.requireString(c, "name");
        var mixed = try tree.getFloat(c, "mix", 1) != 0;
        if (animations) |all| for (all.values()) |animation| {
            const keys = tree.get(tree.get(animation, "ik") orelse continue, name) orelse continue;
            if (keys != .array) return error.Malformed;
            for (keys.array.items) |key| mixed = mixed or try tree.getFloat(key, "mix", 1) != 0;
        };
        if (!mixed) continue;
        var bone = parents.get(bones[0].string) orelse return error.Malformed;
        while (bone) |b| : (bone = parents.get(b) orelse return error.Malformed) {
            if (!try crosses(setups.get(b) orelse return error.Malformed, b, animations)) continue;
            try report.add(.{
                .code = .@"ik.singular.approximated",
                .step = step,
                .path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ list, name }),
                .message = try std.fmt.allocPrint(arena, "scale of {s} passes through zero, {s}", .{ b, reason }),
            });
            break;
        }
    }
}

/// These inherit modes normalize the parent basis
pub fn checkBones(arena: std.mem.Allocator, doc: *ObjectMap, report: *Report, step: []const u8, reason: []const u8) Error!void {
    var parents: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    var setups: std.StringHashMapUnmanaged([2]f32) = .empty;
    try readBones(arena, doc, &parents, &setups);
    const animations = try edit.childOf(doc, "animations");
    for (try edit.arrayOf(doc, "bones")) |bone| {
        const name = try tree.requireString(bone, "name");
        const inherit = try normalizing(bone, name, animations) orelse continue;
        var parent = parents.get(name).?;
        while (parent) |p| : (parent = parents.get(p) orelse return error.Malformed) {
            if (!try crosses(setups.get(p) orelse return error.Malformed, p, animations)) continue;
            try report.add(.{
                .code = .@"bone.singular.approximated",
                .step = step,
                .path = try std.fmt.allocPrint(arena, "bones.{s}", .{name}),
                .message = try std.fmt.allocPrint(arena, "{s} bone under {s} whose scale passes through zero, {s}", .{ inherit, p, reason }),
            });
            break;
        }
    }
}

fn readBones(arena: std.mem.Allocator, doc: *ObjectMap, parents: *std.StringHashMapUnmanaged(?[]const u8), setups: *std.StringHashMapUnmanaged([2]f32)) Error!void {
    for (try edit.arrayOf(doc, "bones")) |bone| {
        const name = try tree.requireString(bone, "name");
        try parents.put(arena, name, try tree.getString(bone, "parent"));
        try setups.put(arena, name, .{ try tree.getFloat(bone, "scaleX", 1), try tree.getFloat(bone, "scaleY", 1) });
    }
}

/// Returns the first normalizing inherit, setup or keyed
pub fn normalizing(bone: Value, name: []const u8, animations: ?*ObjectMap) Error!?[]const u8 {
    const modes = [_][]const u8{ "noRotationOrReflection", "noScale", "noScaleOrReflection" };
    const setup = try tree.getString(bone, "inherit") orelse "normal";
    if (edit.indexOf(&modes, setup) != null) return setup;
    const all = animations orelse return null;
    for (all.values()) |animation| {
        const keys = tree.get(tree.get(tree.get(animation, "bones") orelse continue, name) orelse continue, "inherit") orelse continue;
        if (keys != .array) return error.Malformed;
        for (keys.array.items) |key| {
            const mode = try tree.getString(key, "inherit") orelse "normal";
            if (edit.indexOf(&modes, mode) != null) return mode;
        }
    }
    return null;
}

fn crosses(setup: [2]f32, bone: []const u8, animations: ?*ObjectMap) Error!bool {
    if (setup[0] == 0 or setup[1] == 0) return true;
    const all = animations orelse return false;
    for (all.values()) |animation| {
        const timelines = tree.get(tree.get(animation, "bones") orelse continue, bone) orelse continue;
        const Axis = struct { timeline: []const u8, field: []const u8, channel: usize };
        for ([_]Axis{ .{ .timeline = "scale", .field = "x", .channel = 0 }, .{ .timeline = "scale", .field = "y", .channel = 1 }, .{ .timeline = "scalex", .field = "value", .channel = 0 }, .{ .timeline = "scaley", .field = "value", .channel = 0 } }) |axis| {
            const keys = tree.get(timelines, axis.timeline) orelse continue;
            if (keys != .array) return error.Malformed;
            for (keys.array.items, 0..) |key, i| {
                const value = try tree.getFloat(key, axis.field, 1);
                if (value == 0) return true;
                if (i + 1 == keys.array.items.len) continue;
                const curve = tree.get(key, "curve") orelse .null;
                if (curve == .string and std.mem.eql(u8, curve.string, "stepped")) continue;
                const next = try tree.getFloat(keys.array.items[i + 1], axis.field, 1);
                if (std.math.sign(value) != std.math.sign(next)) return true;
                // a Bézier stays within the signs of its control values
                for (try handles(key, axis.timeline, axis.channel, value, next)) |h| if (h == 0 or std.math.sign(h) != std.math.sign(value)) return true;
            }
        }
    }
    return false;
}

/// Handle values of a key, 3.x curves holding percents and 4.x curves values
fn handles(key: Value, timeline: []const u8, channel: usize, value: f32, next: f32) Error![2]f32 {
    const curve = tree.get(key, "curve") orelse return .{ value, value };
    if (curve == .array) {
        const c = curve.array.items;
        // 3.x keys one percent curve for both scale channels
        if (c.len == 4 and std.mem.eql(u8, timeline, "scale")) {
            return .{ value + (next - value) * try tree.number(c[1]), value + (next - value) * try tree.number(c[3]) };
        }
        if (c.len < channel * 4 + 4) return error.Malformed;
        return .{ try tree.number(c[channel * 4 + 1]), try tree.number(c[channel * 4 + 3]) };
    }
    if (curve != .float and curve != .integer) return .{ value, value };
    return .{ value + (next - value) * try tree.getFloat(key, "c2", 0), value + (next - value) * try tree.getFloat(key, "c4", 1) };
}

test check {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { json: []const u8, losses: usize };
    const skeleton =
        \\{"bones":[{"name":"root"},{"name":"hip","parent":"root"},{"name":"leg","parent":"hip"}],"ik":[{"name":"i","bones":["leg"],"target":"root"
    ;
    for ([_]Case{
        .{ .json = skeleton ++ "}]}", .losses = 0 },
        .{ .json = skeleton ++ "}],\"animations\":{\"a\":{\"bones\":{\"root\":{\"scale\":[{\"x\":-1},{\"time\":1}]}}}}}", .losses = 1 },
        .{ .json = skeleton ++ "}],\"animations\":{\"a\":{\"bones\":{\"hip\":{\"scaley\":[{\"value\":0}]}}}}}", .losses = 1 },
        .{ .json = skeleton ++ "}],\"animations\":{\"a\":{\"bones\":{\"leg\":{\"scale\":[{\"x\":-1},{\"time\":1}]}}}}}", .losses = 0 },
        .{ .json = skeleton ++ "}],\"animations\":{\"a\":{\"bones\":{\"root\":{\"scale\":[{\"x\":-1},{\"time\":1,\"x\":-2}]}}}}}", .losses = 0 },
        .{ .json = skeleton ++ "}],\"animations\":{\"a\":{\"bones\":{\"root\":{\"scale\":[{\"x\":-1,\"curve\":\"stepped\"},{\"time\":1}]}}}}}", .losses = 0 },
        .{ .json = skeleton ++ "}],\"animations\":{\"a\":{\"bones\":{\"root\":{\"scale\":[{\"curve\":[0.3,1,0.6,1,0.3,-0.5,0.6,1]},{\"time\":1}]}}}}}", .losses = 1 },
        .{ .json = skeleton ++ "}],\"animations\":{\"a\":{\"bones\":{\"root\":{\"scale\":[{\"x\":2,\"curve\":[0.3,3,0.6,1.5,0.3,1,0.6,1]},{\"time\":1}]}}}}}", .losses = 0 },
        .{ .json = skeleton ++ "}],\"animations\":{\"a\":{\"bones\":{\"root\":{\"scale\":[{\"x\":2,\"curve\":[0.3,2.5,0.6,1]},{\"time\":1}]}}}}}", .losses = 1 },
        .{ .json = skeleton ++ ",\"mix\":0}],\"animations\":{\"a\":{\"bones\":{\"root\":{\"scale\":[{\"x\":-1},{\"time\":1}]}}}}}", .losses = 0 },
    }) |case| {
        var report: Report = .{ .arena = a };
        var root = try std.json.parseFromSliceLeaky(Value, a, case.json, .{});
        try check(a, &root.object, &report, "4.0-4.1", "r");
        try std.testing.expectEqual(case.losses, report.entries.items.len);
    }
    var report: Report = .{ .arena = a };
    var root = try std.json.parseFromSliceLeaky(Value, a, "{\"bones\":[{\"name\":\"root\",\"scaleX\":0},{\"name\":\"leg\",\"parent\":\"root\"}],\"ik\":[{\"name\":\"i\",\"bones\":[\"leg\"],\"target\":\"root\"}]}", .{});
    try check(a, &root.object, &report, "4.0-4.1", "r");
    try std.testing.expectEqualStrings("scale of root passes through zero, r", report.entries.items[0].message);
}

test checkBones {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, usize };
    for ([_]Case{
        .{ "\"inherit\":\"noScale\"}]}", 0 },
        .{ "\"inherit\":\"noScale\"}],\"animations\":{\"a\":{\"bones\":{\"p\":{\"scalex\":[{\"value\":0}]}}}}}", 1 },
        .{ "\"inherit\":\"normal\"}],\"animations\":{\"a\":{\"bones\":{\"p\":{\"scalex\":[{\"value\":0}]}}}}}", 0 },
        .{ "\"inherit\":\"normal\"}],\"animations\":{\"a\":{\"bones\":{\"p\":{\"scalex\":[{\"value\":0}]},\"b\":{\"inherit\":[{\"inherit\":\"noRotationOrReflection\"}]}}}}}", 1 },
    }) |case| {
        const bone, const losses = case;
        const input = try std.fmt.allocPrint(a, "{{\"bones\":[{{\"name\":\"p\"}},{{\"name\":\"b\",\"parent\":\"p\",{s}", .{bone});
        var report: Report = .{ .arena = a };
        var root = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try checkBones(a, &root.object, &report, "4.2-4.3", "r");
        try std.testing.expectEqual(losses, report.entries.items.len);
    }
}

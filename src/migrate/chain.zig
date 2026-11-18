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

//! World x scale of path bones in 3.5 to 3.7, which scales their spacing

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const tree = @import("../binary/tree.zig");
const edit = @import("../edit.zig");

pub const Error = error{ Malformed, OutOfMemory };

/// Shortest setup length below which spacing ignores the bone
pub const epsilon = 0.00001;

/// Bones that get a space, the last one not with tangents
pub fn spaced(c: Value) Error![]const Value {
    const bones = try tree.getArray(c, "bones");
    const tangent = std.mem.eql(u8, try tree.getString(c, "rotateMode") orelse "tangent", "tangent");
    return bones[0 .. bones.len - @intFromBool(tangent and bones.len > 0)];
}

/// Shortest setup length of the spaced bones
pub fn shortest(doc: *ObjectMap, c: Value) Error!f32 {
    var out = std.math.inf(f32);
    for (try spaced(c)) |b| {
        if (b != .string) return error.Malformed;
        out = @min(out, try tree.getFloat(try find(doc, b.string), "length", 0));
    }
    return out;
}

/// World x scale every spaced bone keeps in every pose, null when it can change
pub fn constant(arena: std.mem.Allocator, doc: *ObjectMap, c: Value) Error!?f64 {
    var out: ?f64 = null;
    for (try spaced(c)) |b| {
        if (b != .string) return error.Malformed;
        const k = try world(arena, doc, c, b.string, false) orelse return null;
        if (out) |o| {
            if (@abs(k - o) > 1e-6 * o) return null;
        } else out = k;
    }
    return out;
}

/// Multiply setup and keyed spacing of the constraint
pub fn scaleSpacing(arena: std.mem.Allocator, doc: *ObjectMap, c: *Value, factor: f64) Error!void {
    const map = try edit.objectOf(c);
    if (map.get("spacing")) |s| try map.put(arena, "spacing", .{ .float = try tree.number(s) * factor });
    const name = try tree.requireString(c.*, "name");
    const animations = try edit.childOf(doc, "animations") orelse return;
    for (animations.values()) |*animation| {
        const paths = try edit.childOf(try edit.objectOf(animation), "paths") orelse continue;
        const timelines = try edit.childOf(paths, name) orelse continue;
        const keys = timelines.getPtr("spacing") orelse continue;
        for (try edit.keysOf(keys)) |*key| {
            const k = try edit.objectOf(key);
            if (k.get("spacing")) |s| try k.put(arena, "spacing", .{ .float = try tree.number(s) * factor });
        }
    }
}

fn find(doc: *ObjectMap, name: []const u8) Error!Value {
    for (try edit.arrayOf(doc, "bones")) |bone| {
        if (std.mem.eql(u8, try tree.requireString(bone, "name"), name)) return bone;
    }
    return error.Malformed;
}

/// World x scale of a bone, as an ancestor also requiring a similarity
fn world(arena: std.mem.Allocator, doc: *ObjectMap, c: Value, name: []const u8, ancestor: bool) Error!?f64 {
    const bone = try find(doc, name);
    const sx: f64 = @abs(try tree.getFloat(bone, "scaleX", 1));
    if (ancestor and sx != @abs(try tree.getFloat(bone, "scaleY", 1))) return null;
    if (try tree.getFloat(bone, "shearX", 0) != 0 or try tree.getFloat(bone, "shearY", 0) != 0) return null;
    if (try keyed(doc, name) or try scaled(doc, c, name)) return null;
    const mode = try tree.getString(bone, "transform") orelse "normal";
    if (std.mem.eql(u8, mode, "normal")) {
        const parent = try tree.getString(bone, "parent") orelse return sx;
        return if (try world(arena, doc, c, parent, true)) |p| sx * p else null;
    }
    // these modes drop the parent scale
    for ([_][]const u8{ "onlyTranslation", "noScale", "noScaleOrReflection" }) |m| if (std.mem.eql(u8, mode, m)) return sx;
    return null;
}

/// Scale or shear keys of the bone
fn keyed(doc: *ObjectMap, name: []const u8) Error!bool {
    const animations = try edit.childOf(doc, "animations") orelse return false;
    for (animations.values()) |animation| {
        const timelines = tree.get(tree.get(animation, "bones") orelse continue, name) orelse continue;
        if (tree.get(timelines, "scale") != null or tree.get(timelines, "shear") != null) return true;
    }
    return false;
}

/// Another constraint can scale the bone
fn scaled(doc: *ObjectMap, c: Value, name: []const u8) Error!bool {
    for ([_][]const u8{ "transform", "path", "ik" }) |kind| for (try edit.arrayOf(doc, kind)) |other| {
        if (std.mem.eql(u8, kind, "path")) {
            if (std.mem.eql(u8, try tree.requireString(other, "name"), try tree.requireString(c, "name"))) continue;
            if (!std.mem.eql(u8, try tree.getString(other, "rotateMode") orelse "tangent", "chainScale")) continue;
        }
        if (std.mem.eql(u8, kind, "ik") and !try tree.getBool(other, "stretch", false) and !try tree.getBool(other, "compress", false)) continue;
        for (try tree.getArray(other, "bones")) |b| if (b == .string and std.mem.eql(u8, b.string, name)) return true;
    };
    return false;
}

test "spacing scale of a uniform chain" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try std.json.parseFromSliceLeaky(Value, a,
        \\{"bones":[{"name":"root","scaleX":2,"scaleY":-2},{"name":"a","parent":"root","scaleX":1.5,"scaleY":3,"length":1},
        \\{"name":"b","parent":"a","scaleX":1.5,"transform":"noScale","length":0},{"name":"c","parent":"a","scaleX":3,"length":1}],
        \\"path":[{"name":"p","bones":["a","b"],"rotateMode":"chain"},{"name":"q","bones":["a","c"]},{"name":"r","bones":["a"],"rotateMode":"chain"}],
        \\"ik":[{"name":"i","bones":["c"],"stretch":true}]}
    , .{});
    const doc = &root.object;
    const paths = try edit.arrayOf(doc, "path");
    try std.testing.expectEqual(null, try constant(a, doc, paths[0]));
    try std.testing.expectEqual(0, try shortest(doc, paths[0]));
    try std.testing.expectEqual(3, (try constant(a, doc, paths[1])).?);
    try std.testing.expectEqual(1, try shortest(doc, paths[1]));
    try std.testing.expectEqual(3, (try constant(a, doc, paths[2])).?);
    try scaleSpacing(a, doc, &paths[2], 0.5);
}

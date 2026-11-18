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

//! Constraint results a later constraint on an ancestor resets

const std = @import("std");

pub const Error = error{OutOfMemory};

pub const Bone = struct {
    parent: ?[]const u8,
    /// Skin required
    required: bool = false,
};

pub const Bones = std.StringHashMapUnmanaged(Bone);

/// Which constrained bones a rewrite may remove
pub const Drop = enum { none, any, suffix };

pub const Constraint = struct {
    order: f32,
    bones: []const []const u8,
    /// Bones whose world it reads besides its own
    reads: []const []const u8 = &.{},
    /// Skins holding it when skin required
    skins: ?[]const []const u8 = null,
    /// Inactive while a read bone is
    bound: bool = false,
    /// Resets descendants every time it is active
    always: bool = true,
    /// Whether always is known for every pose
    certain: bool = true,
    drop: Drop = .any,
};

pub const Reset = struct {
    index: usize,
    /// Constrained bones whose result is discarded
    bones: []const []const u8,
    /// Removing the bones keeps every pose
    exact: bool,
};

/// Skeleton.sortReset keeps bones the later constraint lists
pub fn find(arena: std.mem.Allocator, bones: *const Bones, constraints: []const Constraint) Error![]Reset {
    const sorted = try arena.alloc(usize, constraints.len);
    for (sorted, 0..) |*s, i| s.* = i;
    std.mem.sort(usize, sorted, constraints, struct {
        fn lessThan(all: []const Constraint, a: usize, b: usize) bool {
            return all[a].order < all[b].order;
        }
    }.lessThan);
    var out: std.ArrayList(Reset) = .empty;
    for (constraints, 0..) |e, index| {
        var reset: std.ArrayList([]const u8) = .empty;
        var exact = e.drop != .none;
        for (e.bones) |bone| {
            var hit = false;
            var survives = true;
            for (sorted) |l| {
                const later = constraints[l];
                if (later.order <= e.order or contains(later.bones, bone)) continue;
                if (!under(bones, bone, later.bones)) continue;
                hit = true;
                if (reliable(e, later) and !read(bones, constraints, e.order, later.order, bone)) {
                    survives = false;
                    break;
                }
            }
            if (!hit) continue;
            try reset.append(arena, bone);
            if (survives or required(bones, bone)) exact = false;
        }
        if (reset.items.len == 0) continue;
        if (reset.items.len == e.bones.len and e.drop != .any) exact = false;
        if (e.drop == .suffix) for (reset.items, e.bones[e.bones.len - reset.items.len ..]) |a, b| {
            if (!std.mem.eql(u8, a, b)) exact = false;
        };
        try out.append(arena, .{ .index = index, .bones = reset.items, .exact = exact });
    }
    return out.items;
}

/// Constraints after a later one that reset a bone, none when a restore cannot undo them
pub fn restorers(arena: std.mem.Allocator, bones: *const Bones, constraints: []const Constraint, index: usize, bone: []const u8) Error!?[]usize {
    if (required(bones, bone)) return null;
    var out: std.ArrayList(usize) = .empty;
    for (constraints, 0..) |later, i| {
        if (later.order <= constraints[index].order or contains(later.bones, bone) or !under(bones, bone, later.bones)) continue;
        if (!later.always or !later.certain or later.bound or later.skins != null) return null;
        for (later.bones) |b| if (under(bones, b, &.{bone})) return null;
        try out.append(arena, i);
    }
    return out.items;
}

/// Constrained bones without the reset ones
pub fn kept(arena: std.mem.Allocator, all: []const []const u8, reset: []const []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |b| if (!contains(reset, b)) try out.append(arena, b);
    return out.items;
}

/// Later is active whenever earlier is
fn reliable(earlier: Constraint, later: Constraint) bool {
    if (!later.always or later.bound) return false;
    const skins = later.skins orelse return true;
    for (earlier.skins orelse return false) |s| if (!contains(skins, s)) return false;
    return true;
}

/// A constraint between them sees the earlier result
fn read(bones: *const Bones, constraints: []const Constraint, from: f32, to: f32, bone: []const u8) bool {
    for (constraints) |c| {
        if (c.order <= from or c.order >= to) continue;
        for ([_][]const []const u8{ c.bones, c.reads }) |list| for (list) |b| {
            if (std.mem.eql(u8, b, bone) or under(bones, b, &.{bone})) return true;
        };
    }
    return false;
}

fn under(bones: *const Bones, bone: []const u8, ancestors: []const []const u8) bool {
    var current = bone;
    for (0..bones.count()) |_| {
        current = (bones.get(current) orelse return false).parent orelse return false;
        if (contains(ancestors, current)) return true;
    }
    return false;
}

/// Skeleton.sortReset skips inactive bones
pub fn required(bones: *const Bones, bone: []const u8) bool {
    var current: ?[]const u8 = bone;
    for (0..bones.count()) |_| {
        const b = bones.get(current orelse return false) orelse return false;
        if (b.required) return true;
        current = b.parent;
    }
    return false;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

test find {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bones: Bones = .empty;
    for ([_][2][]const u8{ .{ "hip", "root" }, .{ "arm", "hip" }, .{ "hand", "arm" }, .{ "eye", "hip" }, .{ "t", "root" } }) |pair| {
        try bones.put(a, pair[0], .{ .parent = pair[1] });
    }
    try bones.put(a, "root", .{ .parent = null });

    const two = [_]Constraint{
        .{ .order = 0, .bones = &.{ "hand", "eye" }, .reads = &.{"t"} },
        .{ .order = 1, .bones = &.{"hip"}, .reads = &.{"t"} },
    };
    const resets = try find(a, &bones, &two);
    try std.testing.expectEqual(1, resets.len);
    try std.testing.expectEqual(0, resets[0].index);
    try std.testing.expectEqual(2, resets[0].bones.len);
    try std.testing.expect(resets[0].exact);

    const Case = struct { earlier: Constraint, middle: ?Constraint, later: Constraint, exact: bool };
    const e: Constraint = .{ .order = 0, .bones = &.{ "t", "hand" } };
    const l: Constraint = .{ .order = 2, .bones = &.{"arm"} };
    for ([_]Case{
        .{ .earlier = e, .middle = null, .later = l, .exact = true },
        .{ .earlier = e, .middle = .{ .order = 1, .bones = &.{"t"}, .reads = &.{"hand"} }, .later = l, .exact = false },
        .{ .earlier = e, .middle = .{ .order = 3, .bones = &.{"t"}, .reads = &.{"hand"} }, .later = l, .exact = true },
        .{ .earlier = e, .middle = null, .later = .{ .order = 2, .bones = &.{"arm"}, .skins = &.{"a"} }, .exact = false },
        .{ .earlier = .{ .order = 0, .bones = &.{ "t", "hand" }, .skins = &.{"a"} }, .middle = null, .later = .{ .order = 2, .bones = &.{"arm"}, .skins = &.{ "a", "b" } }, .exact = true },
        .{ .earlier = e, .middle = null, .later = .{ .order = 2, .bones = &.{"arm"}, .always = false }, .exact = false },
        .{ .earlier = e, .middle = null, .later = .{ .order = 2, .bones = &.{"arm"}, .bound = true }, .exact = false },
        .{ .earlier = .{ .order = 0, .bones = &.{ "t", "hand" }, .drop = .none }, .middle = null, .later = l, .exact = false },
        .{ .earlier = .{ .order = 0, .bones = &.{ "hand", "t" }, .drop = .suffix }, .middle = null, .later = l, .exact = false },
        .{ .earlier = .{ .order = 0, .bones = &.{ "t", "hand" }, .drop = .suffix }, .middle = null, .later = l, .exact = true },
        .{ .earlier = .{ .order = 0, .bones = &.{"hand"} }, .middle = null, .later = l, .exact = true },
        .{ .earlier = .{ .order = 0, .bones = &.{"hand"}, .drop = .suffix }, .middle = null, .later = l, .exact = false },
    }) |case| {
        var list: std.ArrayList(Constraint) = .empty;
        try list.append(a, case.earlier);
        if (case.middle) |m| try list.append(a, m);
        try list.append(a, case.later);
        const found = try find(a, &bones, list.items);
        try std.testing.expectEqual(1, found.len);
        try std.testing.expectEqualStrings("hand", found[0].bones[0]);
        try std.testing.expectEqual(case.exact, found[0].exact);
    }

    try std.testing.expectEqual(0, (try find(a, &bones, &.{ .{ .order = 0, .bones = &.{"hand"} }, .{ .order = 1, .bones = &.{ "arm", "hand" } } })).len);
    try std.testing.expectEqual(0, (try find(a, &bones, &.{ .{ .order = 1, .bones = &.{"hand"} }, .{ .order = 0, .bones = &.{"arm"} } })).len);
    try bones.put(a, "arm", .{ .parent = "hip", .required = true });
    try std.testing.expect(!(try find(a, &bones, &.{ e, l }))[0].exact);
    try std.testing.expectEqualStrings("t", (try kept(a, &.{ "t", "hand" }, &.{"hand"}))[0]);
}

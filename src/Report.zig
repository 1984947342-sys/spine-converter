//! Entries are described in docs/report.md

const std = @import("std");

const Report = @This();

/// Last segment of every code
pub const Severity = enum { dropped, approximated, rewritten };

/// Values mirror spc_impact in spine_converter.h
pub const Impact = enum(c_int) { none, editor, control, pose, render };

/// Values mirror spc_remedy in spine_converter.h
pub const Remedy = enum(c_int) { none, rewrite, runtime };

/// Rows mirror docs/report.md
pub const Code = enum {
    @"slider.dropped",
    @"animation.slider.dropped",
    @"slider.linkedMesh.approximated",
    @"animation.color.dropped",
    @"animation.drawOrderFolder.dropped",
    @"bone.icon.dropped",
    @"ik.scaleY.approximated",
    @"physics.scaleY.dropped",
    @"transform.local.approximated",
    @"transform.clamp.dropped",
    @"transform.property.dropped",
    @"transform.scale.approximated",
    @"transform.scale.rewritten",
    @"clipping.convex.dropped",
    @"clipping.inverse.dropped",
    @"clipping.convex.rewritten",
    @"clipping.vertices.approximated",
    @"clipping.vertices.rewritten",
    @"linkedmesh.slot.approximated",
    @"skeleton.referenceScale.dropped",
    @"bone.visible.dropped",
    @"slot.visible.dropped",
    @"skin.color.dropped",
    @"physics.dropped",
    @"physics.step.approximated",
    @"animation.physics.dropped",
    @"animation.duration.approximated",
    @"animation.inherit.dropped",
    @"animation.inherit.setup.dropped",
    @"mesh.triangles.approximated",
    @"mesh.padding.approximated",
    @"mesh.hull.approximated",
    @"attachment.sequence.dropped",
    @"animation.sequence.dropped",
    @"sequence.mode.approximated",
    @"sequence.mode.rewritten",
    @"sequence.linked.approximated",
    @"sequence.linked.rewritten",
    @"transform.mixScaleY.approximated",
    @"transform.mixScaleY.rewritten",
    @"color.curve.approximated",
    @"color.clamp.approximated",
    @"transform.mix.approximated",
    @"transform.scaleMix.approximated",
    @"transform.scaleMix.rewritten",
    @"transform.shearMix.approximated",
    @"transform.shearMix.rewritten",
    @"transform.shearOffset.approximated",
    @"transform.shearOffset.rewritten",
    @"transform.shearWrap.approximated",
    @"transform.shearWrap.rewritten",
    @"transform.rotateRange.approximated",
    @"transform.relativeScale.approximated",
    @"transform.relativeScale.rewritten",
    @"transform.localWrap.approximated",
    @"transform.localWrap.rewritten",
    @"transform.offsetReflect.approximated",
    @"transform.offsetReflect.rewritten",
    @"transform.offsetFlip.approximated",
    @"transform.jsonMix.approximated",
    @"transform.jsonShear.approximated",
    @"path.mix.approximated",
    @"path.negative.approximated",
    @"path.negative.rewritten",
    @"path.position.approximated",
    @"path.position.rewritten",
    @"path.spacing.approximated",
    @"path.spacing.rewritten",
    @"path.proportional.approximated",
    @"path.length.approximated",
    @"path.length.rewritten",
    @"path.offsetReflect.approximated",
    @"path.offsetReflect.rewritten",
    @"path.offsetFlip.approximated",
    @"path.closed.approximated",
    @"ik.stretch.approximated",
    @"ik.stretch.rewritten",
    @"ik.uniform.dropped",
    @"ik.beta.approximated",
    @"ik.beta.rewritten",
    @"ik.singular.approximated",
    @"ik.inherit.approximated",
    @"ik.inherit.rewritten",
    @"ik.origin.approximated",
    @"ik.softness.approximated",
    @"ik.softness.rewritten",
    @"ik.reset.approximated",
    @"ik.reset.rewritten",
    @"ik.skip.approximated",
    @"ik.skip.rewritten",
    @"ik.shear.approximated",
    @"ik.shear.rewritten",
    @"ik.volume.approximated",
    @"ik.softness.dropped",
    @"linkedmesh.deform.approximated",
    @"linkedmesh.deform.rewritten",
    @"skin.required.dropped",
    @"skeleton.position.dropped",
    @"skeleton.scale.approximated",
    @"constraint.skipped.approximated",
    @"constraint.skipped.rewritten",
    @"constraint.order.approximated",
    @"constraint.order.rewritten",
    @"slot.dark.dropped",
    @"animation.dark.dropped",
    @"transform.local.dropped",
    @"transform.relative.dropped",
    @"attachment.clipping.dropped",
    @"attachment.point.dropped",
    @"bone.reflection.approximated",
    @"bone.reflection.rewritten",
    @"bone.flip.approximated",
    @"bone.noRotation.approximated",
    @"bone.noRotation.rewritten",
    @"bone.singular.approximated",
    @"bone.applied.approximated",
    @"bone.applied.rewritten",
    @"bone.derive.approximated",
    @"bone.derive.rewritten",
    @"transform.localMix.approximated",
    @"transform.localMix.rewritten",
    @"transform.localShear.approximated",
    @"path.spacingScale.approximated",
    @"path.spacingScale.rewritten",
    @"path.start.approximated",
    @"ik.compress.dropped",
    @"ik.stretch.dropped",
    @"event.audio.dropped",
    @"skeleton.audio.dropped",
    @"atlas.header.dropped",
    @"atlas.page.dropped",
    @"atlas.pma.dropped",
    @"atlas.rotate.dropped",
    @"atlas.strip.approximated",
    @"atlas.strip.rewritten",
    @"atlas.values.dropped",

    pub fn severity(c: Code) Severity {
        const name = @tagName(c);
        return std.meta.stringToEnum(Severity, name[std.mem.lastIndexOfScalar(u8, name, '.').? + 1 ..]).?;
    }

    /// Left in a latest target only by semantics of changes/needs-a-runtime.md
    pub fn needsRuntime(c: Code) bool {
        return switch (c) {
            .@"bone.noRotation.approximated",
            .@"bone.singular.approximated",
            .@"bone.derive.approximated",
            .@"color.clamp.approximated",
            .@"ik.origin.approximated",
            .@"ik.singular.approximated",
            .@"ik.skip.approximated",
            .@"ik.volume.approximated",
            .@"path.negative.approximated",
            .@"path.closed.approximated",
            .@"path.start.approximated",
            .@"physics.step.approximated",
            .@"slider.linkedMesh.approximated",
            .@"transform.localShear.approximated",
            .@"transform.mixScaleY.approximated",
            .@"transform.relativeScale.approximated",
            .@"transform.rotateRange.approximated",
            .@"transform.shearMix.approximated",
            .@"transform.shearOffset.approximated",
            => true,
            else => false,
        };
    }

    pub fn impact(c: Code) Impact {
        return switch (c) {
            .@"clipping.convex.rewritten",
            .@"transform.scaleMix.rewritten",
            .@"transform.scale.rewritten",
            .@"constraint.order.rewritten",
            .@"ik.reset.rewritten",
            .@"transform.mixScaleY.rewritten",
            .@"ik.skip.rewritten",
            .@"transform.shearOffset.rewritten",
            .@"transform.shearMix.rewritten",
            .@"transform.localWrap.rewritten",
            .@"path.length.rewritten",
            .@"ik.stretch.rewritten",
            .@"transform.relativeScale.rewritten",
            .@"sequence.mode.rewritten",
            .@"transform.offsetReflect.rewritten",
            .@"path.offsetReflect.rewritten",
            .@"bone.reflection.rewritten",
            .@"constraint.skipped.rewritten",
            .@"path.negative.rewritten",
            .@"transform.localMix.rewritten",
            .@"ik.shear.rewritten",
            .@"bone.derive.rewritten",
            .@"ik.softness.rewritten",
            .@"ik.inherit.rewritten",
            .@"ik.beta.rewritten",
            .@"sequence.linked.rewritten",
            .@"bone.noRotation.rewritten",
            .@"path.position.rewritten",
            .@"atlas.strip.rewritten",
            .@"bone.applied.rewritten",
            .@"path.spacing.rewritten",
            .@"path.spacingScale.rewritten",
            .@"linkedmesh.deform.rewritten",
            .@"clipping.vertices.rewritten",
            .@"transform.shearWrap.rewritten",
            => .none,
            .@"animation.color.dropped",
            .@"bone.icon.dropped",
            .@"skeleton.referenceScale.dropped",
            .@"bone.visible.dropped",
            .@"slot.visible.dropped",
            .@"skin.color.dropped",
            .@"mesh.hull.approximated",
            .@"skeleton.audio.dropped",
            .@"skeleton.position.dropped",
            .@"atlas.header.dropped",
            .@"atlas.page.dropped",
            => .editor,
            .@"animation.inherit.setup.dropped",
            .@"event.audio.dropped",
            .@"mesh.padding.approximated",
            .@"attachment.sequence.dropped",
            .@"attachment.point.dropped",
            .@"skeleton.scale.approximated",
            .@"atlas.values.dropped",
            .@"bone.flip.approximated",
            .@"transform.offsetFlip.approximated",
            .@"path.offsetFlip.approximated",
            .@"transform.jsonShear.approximated",
            .@"animation.duration.approximated",
            => .control,
            .@"clipping.convex.dropped",
            .@"clipping.inverse.dropped",
            .@"slot.dark.dropped",
            .@"animation.dark.dropped",
            .@"attachment.clipping.dropped",
            .@"mesh.triangles.approximated",
            .@"atlas.pma.dropped",
            .@"atlas.rotate.dropped",
            .@"atlas.strip.approximated",
            .@"clipping.vertices.approximated",
            => .render,
            else => .pose,
        };
    }
};

pub const Entry = struct {
    code: Code,
    step: []const u8,
    path: []const u8,
    message: []const u8,
    remedy: Remedy = .none,

    pub fn jsonStringify(e: Entry, w: anytype) !void {
        try w.beginObject();
        try w.objectField("code");
        try w.write(@tagName(e.code));
        try w.objectField("severity");
        try w.write(@tagName(e.code.severity()));
        try w.objectField("impact");
        try w.write(@tagName(e.code.impact()));
        try w.objectField("step");
        try w.write(e.step);
        try w.objectField("path");
        try w.write(e.path);
        try w.objectField("message");
        try w.write(e.message);
        try w.objectField("remedy");
        try w.write(@tagName(e.remedy));
        try w.endObject();
    }
};

arena: std.mem.Allocator,
entries: std.ArrayList(Entry) = .empty,

pub fn add(r: *Report, entry: Entry) !void {
    try r.entries.append(r.arena, entry);
}

pub fn lossCount(r: *const Report) usize {
    var count: usize = 0;
    for (r.entries.items) |e| count += @intFromBool(e.code.severity() != .rewritten);
    return count;
}

pub fn remedyCount(r: *const Report, remedy: Remedy) usize {
    var count: usize = 0;
    for (r.entries.items) |e| count += @intFromBool(e.remedy == remedy);
    return count;
}

pub fn maxImpact(r: *const Report) Impact {
    var max: Impact = .none;
    for (r.entries.items) |e| max = @fromBackingInt(@intCast(@max(@backingInt(max), @backingInt(e.code.impact()))));
    return max;
}

pub fn toJson(r: *const Report) ![:0]const u8 {
    var out: std.Io.Writer.Allocating = .init(r.arena);
    try std.json.Stringify.value(r.entries.items, .{}, &out.writer);
    return out.toOwnedSliceSentinel(0);
}

test toJson {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r: Report = .{ .arena = arena.allocator() };
    try std.testing.expectEqualStrings("[]", try r.toJson());
    try std.testing.expectEqual(.none, r.maxImpact());
    try r.add(.{ .code = .@"bone.icon.dropped", .step = "4.2-4.1", .path = "x", .message = "m" });
    try r.add(.{ .code = .@"physics.dropped", .step = "4.2-4.1", .path = "y", .message = "m" });
    try std.testing.expectEqual(2, r.lossCount());
    try std.testing.expectEqual(.pose, r.maxImpact());
    try std.testing.expectEqual(2, r.remedyCount(.none));
    try std.testing.expectEqualStrings(
        "[{\"code\":\"bone.icon.dropped\",\"severity\":\"dropped\",\"impact\":\"editor\",\"step\":\"4.2-4.1\",\"path\":\"x\",\"message\":\"m\",\"remedy\":\"none\"}," ++
            "{\"code\":\"physics.dropped\",\"severity\":\"dropped\",\"impact\":\"pose\",\"step\":\"4.2-4.1\",\"path\":\"y\",\"message\":\"m\",\"remedy\":\"none\"}]",
        try r.toJson(),
    );
}

test "codes match docs" {
    try expectCodeTable(@embedFile("report.md"), "| Code | Severity | Impact | Meaning |");
    try expectCodeTable(@embedFile("report.zh-CN.md"), "| 代码 | 严重程度 | 影响 | 含义 |");
}

fn expectCodeTable(doc: []const u8, header: []const u8) !void {
    var lines = std.mem.splitScalar(u8, doc[std.mem.indexOf(u8, doc, header).? + header.len ..], '\n');
    _ = lines.next();
    _ = lines.next();
    var rows: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| `")) break;
        var cells = std.mem.tokenizeAny(u8, line, "|` ");
        const name = cells.next().?;
        const code = std.meta.stringToEnum(Code, name) orelse {
            std.debug.print("unknown code {s}\n", .{name});
            return error.UnknownCode;
        };
        try std.testing.expectEqualStrings(@tagName(code.severity()), cells.next().?);
        try std.testing.expectEqualStrings(@tagName(code.impact()), cells.next().?);
        rows += 1;
    }
    try std.testing.expectEqual(std.enums.values(Code).len, rows);
}

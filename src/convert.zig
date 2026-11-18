const std = @import("std");
const detect = @import("detect.zig");
const Format = detect.Format;
const Version = @import("Version.zig");
const Report = @import("Report.zig");
const json = @import("json.zig");
const binary = @import("binary.zig");
const migrate = @import("migrate.zig");
const atlas = @import("atlas.zig");
const edit = @import("edit.zig");
const Document = @import("Document.zig");

pub const Options = struct {
    /// Null keeps the source version
    target_version: ?Version = null,
    /// Unknown keeps the source format
    target_format: Format = .unknown,
    fail_on_loss: bool = false,
    rewrite: bool = true,
    pretty_json: bool = false,
    /// Atlas text that lets 3.5 and 3.6 meshes keep their UVs
    atlas: ?[]const u8 = null,
};

pub const Error = error{ UnknownFormat, UnsupportedVersion, Malformed, OutOfMemory, LossyRejected, FormatMismatch };

pub const Output = struct {
    format: Format,
    data: []const u8,
};

/// All memory comes from arena
pub fn convert(arena: std.mem.Allocator, data: []const u8, options: Options, report: *Report) Error!Output {
    const detected = try detect.detect(data);
    if (detected.format == .atlas or options.target_format == .atlas) {
        if (detected.format != .atlas or options.target_format == .json or options.target_format == .binary) return error.FormatMismatch;
        const output = try atlas.convert(arena, data, options.target_version, report);
        if (options.fail_on_loss and report.lossCount() != 0) return error.LossyRejected;
        return .{ .format = .atlas, .data = output };
    }
    const source = detected.version orelse return error.UnsupportedVersion;
    if (beforeFreeze(source)) return error.UnsupportedVersion;
    var doc = try decode(arena, data, detected.format, source, report);

    const target = options.target_version orelse source;
    const migrated = report.entries.items.len;
    try migrate.run(arena, &doc, target, .{ .rewrite = options.rewrite, .atlas = options.atlas }, report);
    if (!options.rewrite) try markRewritable(arena, data, detected.format, source, target, options.atlas, report.entries.items[migrated..]);
    // a latest target leaves these only where no data reproduces them
    if (migrate.latest.major == target.major and migrate.latest.minor == target.minor) for (report.entries.items[migrated..]) |*e| {
        if (e.remedy == .none and e.code.needsRuntime()) e.remedy = .runtime;
    };
    const format: Format = if (options.target_format == .unknown) detected.format else options.target_format;
    // the source loader already read JSON of its own minor
    const same = detected.format == .json and source.major == doc.version.major and source.minor == doc.version.minor;
    if (format == .json and !same) try migrate.checkJson(arena, &doc, report);
    // binary encoders report losses of their own
    const output = switch (format) {
        .json => try json.encode(arena, try withHash(arena, &doc), .{ .pretty = options.pretty_json }),
        .binary => try binary.encode(arena, doc, report),
        .unknown, .atlas => unreachable,
    };
    if (options.fail_on_loss and report.lossCount() != 0) return error.LossyRejected;
    return .{ .format = format, .data = output };
}

fn decode(arena: std.mem.Allocator, data: []const u8, format: Format, source: Version, report: *Report) Error!Document {
    const doc = switch (format) {
        .json => try json.decode(arena, data, source),
        .binary => try binary.decode(arena, data, source, report),
        .unknown, .atlas => unreachable,
    };
    try checkParents(arena, doc.root);
    return doc;
}

/// Loaders require parents before children
fn checkParents(arena: std.mem.Allocator, root: std.json.Value) Error!void {
    const bones = root.object.get("bones") orelse return;
    if (bones != .array) return error.Malformed;
    var earlier: std.StringHashMapUnmanaged(void) = .empty;
    for (bones.array.items) |bone| {
        if (bone != .object) return error.Malformed;
        const parent = bone.object.get("parent") orelse .null;
        if (parent != .null and (parent != .string or !earlier.contains(parent.string))) return error.Malformed;
        const name = bone.object.get("name") orelse return error.Malformed;
        if (name != .string) return error.Malformed;
        try earlier.put(arena, name.string, {});
    }
}

/// Marks losses a second migration with rewrites makes exact
fn markRewritable(arena: std.mem.Allocator, data: []const u8, format: Format, source: Version, target: Version, atlas_text: ?[]const u8, entries: []Report.Entry) Error!void {
    for (entries) |e| {
        if (e.code.severity() != .rewritten) break;
    } else return;
    var scratch: Report = .{ .arena = arena };
    var doc = try decode(arena, data, format, source, &scratch);
    const decoded = scratch.entries.items.len;
    try migrate.run(arena, &doc, target, .{ .rewrite = true, .atlas = atlas_text }, &scratch);
    for (entries) |*e| for (scratch.entries.items[decoded..]) |r| {
        if (r.code.severity() == .rewritten and std.mem.eql(u8, e.step, r.step) and std.mem.eql(u8, e.path, r.path) and std.mem.eql(u8, stem(e.code), stem(r.code))) e.remedy = .rewrite;
    };
}

fn stem(code: Report.Code) []const u8 {
    const name = @tagName(code);
    return name[0..std.mem.lastIndexOfScalar(u8, name, '.').?];
}

/// spine-csharp reads the hash without a default
fn withHash(arena: std.mem.Allocator, doc: *Document) Error!Document {
    if (try edit.childOf(try edit.objectOf(&doc.root), "skeleton")) |skeleton| {
        if (!skeleton.contains("hash")) try skeleton.put(arena, "hash", .{ .string = "" });
    }
    return doc.*;
}

/// Rows mirror docs/architecture.md
const freezes = [_]struct { major: u16, minor: u16, beta: u16 }{
    .{ .major = 3, .minor = 5, .beta = 3 },
    .{ .major = 3, .minor = 6, .beta = 14 },
    .{ .major = 3, .minor = 7, .beta = 29 },
    .{ .major = 3, .minor = 8, .beta = 25 },
    .{ .major = 4, .minor = 0, .beta = 27 },
    .{ .major = 4, .minor = 1, .beta = 4 },
    .{ .major = 4, .minor = 2, .beta = 56 },
    .{ .major = 4, .minor = 3, .beta = 74 },
};

/// Patch numbers restart at release
fn beforeFreeze(v: Version) bool {
    if (!v.isBeta()) return false;
    for (freezes) |f| {
        if (f.major == v.major and f.minor == v.minor) return v.patch < f.beta;
    }
    return false;
}

test "same version json" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    const input = "{\"skeleton\":{\"spine\":\"4.2.43\",\"hash\":\"h\"},\"bones\":[{\"name\":\"root\",\"x\":0.30000001}]}";

    const kept = try convert(arena.allocator(), input, .{}, &report);
    try std.testing.expectEqualStrings("{\"skeleton\":{\"spine\":\"4.2.43\",\"hash\":\"h\"},\"bones\":[{\"name\":\"root\",\"x\":0.3}]}", kept.data);

    const patched = try convert(arena.allocator(), input, .{ .target_version = Version.parse("4.2.11").? }, &report);
    try std.testing.expect(std.mem.indexOf(u8, patched.data, "\"4.2.11\"") != null);

    try std.testing.expectError(error.UnsupportedVersion, convert(arena.allocator(), input, .{ .target_version = Version.parse("3.4").? }, &report));
    try std.testing.expectError(error.UnsupportedVersion, convert(arena.allocator(), "{\"bones\":[]}", .{}, &report));
}

test beforeFreeze {
    for ([_][]const u8{ "3.5.02-beta", "3.6.12-beta", "3.7.28-beta", "3.8.20-beta", "4.0.24-beta", "4.1.03-beta", "4.2.43-beta", "4.3.69-beta" }) |s| {
        try std.testing.expect(beforeFreeze(Version.parse(s).?));
    }
    for ([_][]const u8{ "3.5.03-beta", "3.5.49", "3.6.14-beta", "3.7.29-beta", "3.7.90", "3.8.25-beta", "3.8.75", "4.0.07", "4.1.04-beta", "4.2.56-beta", "4.3.74-beta", "4.3.75-beta", "Dev" }) |s| {
        try std.testing.expect(!beforeFreeze(Version.parse(s) orelse Version.unnumbered(s).?));
    }
}

test "editor rows start at or after the freeze" {
    for (Version.rows) |r| {
        const v = Version.parse(r.old_through).?;
        try std.testing.expect(for (freezes) |f| {
            if (f.major == v.major and f.minor == v.minor) break true;
        } else false);
        try std.testing.expect(!beforeFreeze(v));
    }
}

test "beta before freeze" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    for ([_][]const u8{ "3.5.02-beta", "3.6.12-beta", "3.7.28-beta", "3.8.20-beta", "4.0.24-beta", "4.1.03-beta", "4.2.43-beta", "4.3.69-beta" }) |s| {
        const json_input = try std.fmt.allocPrint(arena.allocator(), "{{\"skeleton\":{{\"spine\":\"{s}\"}},\"bones\":[]}}", .{s});
        try std.testing.expectError(error.UnsupportedVersion, convert(arena.allocator(), json_input, .{}, &report));
    }
    const binary_input = "\x01\x02\x03\x04\x05\x06\x07\x08\x0C" ++ "4.3.69-beta" ++ "rest";
    try std.testing.expectError(error.UnsupportedVersion, convert(arena.allocator(), binary_input, .{}, &report));
    const legacy_input = "\x01\x0C" ++ "3.5.02-beta" ++ "rest";
    try std.testing.expectError(error.UnsupportedVersion, convert(arena.allocator(), legacy_input, .{}, &report));
}

test "json output has a hash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    const input = "{\"skeleton\":{\"hash\":\"x\",\"spine\":\"3.8.99\"},\"bones\":[{\"name\":\"root\"}]}";
    const output = try convert(arena.allocator(), input, .{ .target_version = Version.parse("4.3").? }, &report);
    try std.testing.expectEqualStrings("{\"skeleton\":{\"spine\":\"4.3.0\",\"hash\":\"\"},\"bones\":[{\"name\":\"root\"}]}", output.data);
}

test "3.8.75 one bone IK within 3.8" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const input = "{\"skeleton\":{\"spine\":\"3.8.75\",\"hash\":\"h\"},\"bones\":[{\"name\":\"root\"},{\"name\":\"b\",\"parent\":\"root\",\"transform\":\"onlyTranslation\"},{\"name\":\"t\",\"parent\":\"root\"}],\"ik\":[{\"name\":\"i\",\"bones\":[\"b\"],\"target\":\"t\"}]}";
    for ([_]?[]const u8{ null, "3.8", "3.8.99" }) |to| for ([_]bool{ false, true }) |rewrite| {
        var report: Report = .{ .arena = arena.allocator() };
        const target = if (to) |t| Version.parse(t).? else null;
        _ = try convert(arena.allocator(), input, .{ .target_version = target, .target_format = .binary, .rewrite = rewrite }, &report);
        try std.testing.expectEqual(1, report.entries.items.len);
        try std.testing.expectEqual(if (rewrite) Report.Code.@"ik.beta.rewritten" else .@"ik.beta.approximated", report.entries.items[0].code);
        try std.testing.expectEqual(if (rewrite) Report.Impact.none else .pose, report.maxImpact());
    };
}

test "4.0 JSON shear keys from other loaders" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "\"bones\":[{{\"name\":\"root\"}},{{\"name\":\"b\",\"parent\":\"root\"}}],\"transform\":[{{\"name\":\"t\",\"bones\":[\"b\"],\"target\":\"root\"}}],\"animations\":{{\"a\":{{\"transform\":{{\"t\":[{{\"{s}\":1}},{{\"time\":1,\"{s}\":0}}]}}}}}}}}";
    const v38 = try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"3.8.99\",\"hash\":\"h\"}}," ++ body, .{ "shearMix", "shearMix" });
    const v40 = try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"4.0.64\",\"hash\":\"AAAAAAAAAAA\"}}," ++ body, .{ "mixShearY", "mixShearY" });
    var report: Report = .{ .arena = a };
    const v40_binary = (try convert(a, v40, .{ .target_format = .binary }, &report)).data;
    const Case = struct { []const u8, ?[]const u8, Format, usize };
    for ([_]Case{
        .{ v38, "4.0", .json, 1 },
        .{ v38, "4.0", .binary, 0 },
        .{ v38, "4.1", .json, 0 },
        .{ v40, null, .json, 0 },
        .{ v40_binary, null, .json, 1 },
    }) |case| {
        report = .{ .arena = a };
        const target = if (case[1]) |t| Version.parse(t).? else null;
        _ = try convert(a, case[0], .{ .target_version = target, .target_format = case[2] }, &report);
        var found: usize = 0;
        for (report.entries.items) |e| found += @intFromBool(e.code == .@"transform.jsonShear.approximated");
        try std.testing.expectEqual(case[3], found);
    }
}

test "dropped timelines end an animation earlier" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"skeleton":{"spine":"4.2.43","hash":"AAAAAAAAAAA"},"bones":[{"name":"root"}],"physics":[{"name":"p","bone":"root","x":1}],
        \\"animations":{"a":{"bones":{"root":{"rotate":[{"time":0.5,"value":10}]}},"physics":{"p":{"inertia":[{"time":2,"value":0.5}]}}},
        \\"b":{"bones":{"root":{"rotate":[{"time":3,"value":10}]}},"physics":{"p":{"inertia":[{"time":2,"value":0.5}]}}}}}
    ;
    var report: Report = .{ .arena = a };
    _ = try convert(a, input, .{ .target_version = Version.parse("4.1").? }, &report);
    var paths: std.ArrayList(u8) = .empty;
    for (report.entries.items) |e| if (e.code == .@"animation.duration.approximated") try paths.print(a, "{s} ", .{e.path});
    try std.testing.expectEqualStrings("animations.a ", paths.items);
}

test "losses carry their remedy" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const steady =
        \\{"skeleton":{"spine":"4.2.22"},"bones":[{"name":"root"},{"name":"s","parent":"root","scaleX":1.6},{"name":"b","parent":"root","scaleX":2}],
        \\"transform":[{"name":"t","bones":["b"],"target":"s","local":true,"mixRotate":0,"mixX":0,"mixScaleX":0.5,"mixShearY":0}]}
    ;
    const keyed =
        \\{"skeleton":{"spine":"4.2.22"},"bones":[{"name":"root"},{"name":"s","parent":"root","scaleX":1.6},{"name":"b","parent":"root","scaleX":2}],
        \\"transform":[{"name":"t","bones":["b"],"target":"s","local":true,"mixRotate":0,"mixX":0,"mixScaleX":0.5,"mixShearY":0}],
        \\"animations":{"a":{"bones":{"b":{"scale":[{"x":0.5},{"time":1}]}}}}}
    ;
    const mixed =
        \\{"skeleton":{"spine":"4.2.22"},"bones":[{"name":"root"},{"name":"s","parent":"root","scaleX":1.6},{"name":"b","parent":"root","scaleX":2}],
        \\"transform":[{"name":"t","bones":["b"],"target":"s","local":true,"mixRotate":0,"mixX":0,"mixScaleX":0.5,"mixShearY":0}],
        \\"animations":{"a":{"transform":{"t":[{"mixScaleX":0.3},{"time":1,"mixScaleX":-0.3}]}}}}
    ;
    for ([_]struct { []const u8, bool, Report.Remedy }{
        .{ steady, false, .rewrite },
        .{ keyed, false, .rewrite },
        .{ mixed, false, .runtime },
        .{ mixed, true, .runtime },
    }) |case| {
        var report: Report = .{ .arena = a };
        _ = try convert(a, case[0], .{ .target_version = Version.parse("4.3").?, .rewrite = case[1] }, &report);
        try std.testing.expectEqual(1, report.entries.items.len);
        try std.testing.expectEqual(.@"transform.scale.approximated", report.entries.items[0].code);
        try std.testing.expectEqual(case[2], report.entries.items[0].remedy);
        try std.testing.expectEqual(1, report.remedyCount(case[2]));
    }
    for ([_][]const u8{ steady, keyed }) |input| {
        var report: Report = .{ .arena = a };
        _ = try convert(a, input, .{ .target_version = Version.parse("4.3").? }, &report);
        try std.testing.expectEqual(.@"transform.scale.rewritten", report.entries.items[0].code);
        try std.testing.expectEqual(.none, report.entries.items[0].remedy);
    }
}

test "losses of the binary encoder fail on loss" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"skeleton":{"spine":"4.3.22"},"bones":[{"name":"root"}],
        \\"constraints":[{"type":"physics","name":"p","bone":"root","x":1,"scaleX":2,"scaleY":"uniform"}]}
    ;
    var report: Report = .{ .arena = arena.allocator() };
    _ = try convert(arena.allocator(), input, .{ .fail_on_loss = true }, &report);
    try std.testing.expectError(error.LossyRejected, convert(arena.allocator(), input, .{ .target_format = .binary, .fail_on_loss = true }, &report));
    try std.testing.expectEqual(Report.Code.@"physics.scaleY.dropped", report.entries.items[0].code);
}

test "targets between table rows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    const input = "{\"skeleton\":{\"spine\":\"3.8.99\"},\"bones\":[{\"name\":\"root\"}]}";
    for ([_][]const u8{ "3.9", "4.4", "3.4" }) |to| {
        try std.testing.expectError(error.UnsupportedVersion, convert(arena.allocator(), input, .{ .target_version = Version.parse(to).? }, &report));
    }
}

test "parents come before their bones" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var report: Report = .{ .arena = arena.allocator() };
    for ([_][]const u8{
        "[{\"name\":\"a\",\"parent\":\"a\"}]",
        "[{\"name\":\"root\"},{\"name\":\"a\",\"parent\":\"b\"},{\"name\":\"b\",\"parent\":\"a\"}]",
        "[{\"name\":\"root\"},{\"name\":\"a\",\"parent\":\"missing\"}]",
    }) |bones| {
        const input = try std.fmt.allocPrint(arena.allocator(), "{{\"skeleton\":{{\"spine\":\"3.6.53\"}},\"bones\":{s},\"ik\":[{{\"name\":\"i\",\"bones\":[\"a\"],\"target\":\"a\"}}]}}", .{bones});
        try std.testing.expectError(error.Malformed, convert(arena.allocator(), input, .{ .target_version = Version.parse("4.3").? }, &report));
    }
}

test "path setup mixY survives binary when mixX differs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "4.0.64", "4.1.24", "4.2.43" }) |version| {
        const input = try std.fmt.allocPrint(a,
            \\{{"skeleton":{{"spine":"{s}"}},"bones":[{{"name":"root"}},{{"name":"b","parent":"root"}}],"slots":[{{"name":"s","bone":"root"}}],
            \\"path":[{{"name":"p","bones":["b"],"target":"s","mixX":0.5,"mixY":1}}]}}
        , .{version});
        var report: Report = .{ .arena = a };
        const skel = try convert(a, input, .{ .target_format = .binary }, &report);
        const back = try convert(a, skel.data, .{ .target_format = .json }, &report);
        try std.testing.expect(std.mem.indexOf(u8, back.data, "\"mixX\":0.5,\"mixY\":1") != null);
    }
}

test "path setup mixY defaults to mixX in binary" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "4.0.64", "4.1.24", "4.2.43" }) |version| {
        const input = try std.fmt.allocPrint(a,
            \\{{"skeleton":{{"spine":"{s}"}},"bones":[{{"name":"root"}},{{"name":"b","parent":"root"}}],"slots":[{{"name":"s","bone":"root"}}],
            \\"path":[{{"name":"p","bones":["b"],"target":"s","mixX":0.5}}]}}
        , .{version});
        var report: Report = .{ .arena = a };
        const skel = try convert(a, input, .{ .target_format = .binary }, &report);
        const back = try convert(a, skel.data, .{ .target_format = .json }, &report);
        try std.testing.expect(std.mem.indexOf(u8, back.data, "\"mixX\":0.5,\"mixY\":0.5") != null);
    }
}

test "path setup mixY defaults to mixX across 4.3" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "4.0.64", "4.1.24", "4.2.43" }) |version| {
        const input = try std.fmt.allocPrint(a,
            \\{{"skeleton":{{"spine":"{s}"}},"bones":[{{"name":"root"}},{{"name":"b","parent":"root"}}],"slots":[{{"name":"s","bone":"root"}}],
            \\"path":[{{"name":"p","bones":["b"],"target":"s","mixX":0.5}}]}}
        , .{version});
        var report: Report = .{ .arena = a };
        const output = try convert(a, input, .{ .target_version = Version.parse("4.3").?, .target_format = .json }, &report);
        try std.testing.expect(std.mem.indexOf(u8, output.data, "\"mixY\":0.5") != null);
    }
}

test "region sizes keep their defaults across 4.3" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skeleton = "\"bones\":[{\"name\":\"root\"}],\"slots\":[{\"name\":\"s\",\"bone\":\"root\"}],\"skins\":[{\"name\":\"default\",\"attachments\":{\"s\":{\"r\":{}}}}]}";
    for ([_]struct { from: []const u8, to: []const u8, size: f64 }{
        .{ .from = "4.2.43", .to = "4.3", .size = 32 },
        .{ .from = "4.3.22", .to = "4.2", .size = 0 },
    }) |case| {
        const source = try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"{s}\"}},{s}", .{ case.from, skeleton });
        var report: Report = .{ .arena = a };
        const output = try convert(a, source, .{ .target_version = Version.parse(case.to).?, .target_format = .json }, &report);
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, output.data, .{});
        const r = root.object.get("skins").?.array.items[0].object.get("attachments").?.object.get("s").?.object.get("r").?.object;
        try std.testing.expectEqual(case.size, try floatOf(r.get("width").?));
        try std.testing.expectEqual(case.size, try floatOf(r.get("height").?));
    }
}

fn floatOf(v: std.json.Value) !f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.TestUnexpectedResult,
    };
}

test "linked mesh without parent encodes as mesh" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "4.0.64", "4.1.24", "4.2.43", "4.3.40" }) |version| {
        const input = try std.fmt.allocPrint(a,
            \\{{"skeleton":{{"spine":"{s}"}},"bones":[{{"name":"root"}}],"slots":[{{"name":"s","bone":"root"}}],
            \\"skins":[{{"name":"default","attachments":{{"s":{{"m":{{"type":"linkedmesh","uvs":[0,0,1,0,0,1],"triangles":[0,1,2],"vertices":[0,0,1,0,0,1],"hull":3}}}}}}}}]}}
        , .{version});
        var report: Report = .{ .arena = a };
        const skel = try convert(a, input, .{ .target_format = .binary }, &report);
        const back = try convert(a, skel.data, .{ .target_format = .json }, &report);
        try std.testing.expect(std.mem.indexOf(u8, back.data, "\"type\":\"mesh\"") != null);
    }
}

test "old binaries read back with any hash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "3.5.51", "3.6.53", "3.7.94", "3.8.99" }) |version| {
        for ([_][]const u8{ "my rig", "caf\xc3\xa9", "\\u0000" }) |hash| {
            const input = try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"hash\":\"{s}\",\"spine\":\"{s}\"}},\"bones\":[{{\"name\":\"root\"}}]}}", .{ hash, version });
            var report: Report = .{ .arena = a };
            const skel = try convert(a, input, .{ .target_format = .binary }, &report);
            const back = try convert(a, skel.data, .{ .target_format = .json }, &report);
            try std.testing.expect(std.mem.indexOf(u8, back.data, hash) != null);
        }
    }
}

test "null lists read as missing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "3.8.99", "4.3.22" }) |version| {
        const input = try std.fmt.allocPrint(a, "{{\"skeleton\":{{\"spine\":\"{s}\"}},\"bones\":null,\"constraints\":null}}", .{version});
        for ([_]Format{ .json, .binary }) |format| {
            var report: Report = .{ .arena = a };
            const out = try convert(a, input, .{ .target_format = format }, &report);
            try std.testing.expect(std.mem.indexOf(u8, out.data, "null") == null);
        }
    }
}

test "path setup mixY defaults to mixX down to 3.8" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", ",\"mixY\":1" }, [_]usize{ 0, 1 }) |mix_y, losses| {
        const input = try std.fmt.allocPrint(a,
            \\{{"skeleton":{{"spine":"4.0.64"}},"bones":[{{"name":"root"}},{{"name":"b","parent":"root"}}],"slots":[{{"name":"s","bone":"root"}}],
            \\"path":[{{"name":"p","bones":["b"],"target":"s","mixX":0.5{s}}}]}}
        , .{mix_y});
        var report: Report = .{ .arena = a };
        _ = try convert(a, input, .{ .target_version = Version.parse("3.8").? }, &report);
        try std.testing.expectEqual(losses, report.lossCount());
    }
}

test "atlas keeps 3.6 mesh UVs of stripped regions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const atlas_text = "\na.png\nsize: 64,64\nformat: RGBA8888\nfilter: Linear,Linear\nrepeat: none\n" ++
        "r\n  rotate: false\n  xy: 2, 2\n  size: 20, 30\n  orig: 32, 40\n  offset: 5, 3\n  index: -1\n" ++
        "q\n  rotate: true\n  xy: 30, 2\n  size: 20, 30\n  orig: 32, 40\n  offset: 5, 3\n  index: -1\n" ++
        "p\n  rotate: false\n  xy: 2, 40\n  size: 16, 16\n  orig: 16, 16\n  offset: 0, 0\n  index: -1\n";
    const mesh = "\"type\":\"mesh\",\"uvs\":[0,0,1,0,1,1,0.25,0.7],\"triangles\":[0,1,2,0,2,3],\"vertices\":[0,0,10,0,10,10,0,10],\"hull\":4";
    const input = "{\"skeleton\":{\"spine\":\"3.6.53\"},\"bones\":[{\"name\":\"root\"}],\"slots\":[{\"name\":\"s\",\"bone\":\"root\"}]," ++
        "\"skins\":{\"default\":{\"s\":{\"r\":{" ++ mesh ++ "},\"q\":{" ++ mesh ++ "},\"p\":{" ++ mesh ++ "}}}}}";
    const to: Version = Version.parse("3.7").?;

    // UVs agree with spine-csharp 3.6 and 3.7 UpdateUVs
    var report: Report = .{ .arena = a };
    const out = try convert(a, input, .{ .target_version = to, .atlas = atlas_text }, &report);
    try std.testing.expect(std.mem.indexOf(u8, out.data, "\"uvs\":[0.15625,0.175,0.78125,0.175,0.78125,0.925,0.3125,0.7]") != null);
    try std.testing.expectEqual(2, report.entries.items.len);
    try std.testing.expectEqual(.@"atlas.strip.rewritten", report.entries.items[0].code);
    try std.testing.expectEqualStrings("skins.default.s.q", report.entries.items[1].path);

    var kept: Report = .{ .arena = a };
    _ = try convert(a, input, .{ .target_version = to, .atlas = atlas_text, .rewrite = false }, &kept);
    try std.testing.expectEqual(2, kept.lossCount());
    try std.testing.expectEqual(.rewrite, kept.entries.items[0].remedy);

    var blind: Report = .{ .arena = a };
    _ = try convert(a, input, .{ .target_version = to }, &blind);
    try std.testing.expectEqual(3, blind.lossCount());
}

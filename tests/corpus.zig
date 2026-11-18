const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const sc = @import("spine_converter");
const document_diff = @import("document_diff.zig");

const Truth = union(enum) {
    not_skeleton,
    unversioned,
    any_version,
    version: []const u8,
};

const Sample = struct {
    path: []const u8,
    is_skel: bool,
    data: []const u8,
    truth: Truth,
    /// Parsed JSON of a JSON sample or of the JSON export beside a skel
    tree: ?Value,
    /// JSON export beside a skel
    sibling: []const u8 = "",
};

const Check = struct {
    name: []const u8,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    fn fail(c: *Check, out: *Io.Writer, path: []const u8, comptime fmt: []const u8, args: anytype) !void {
        c.failed += 1;
        try out.print("FAIL {s} {s}: " ++ fmt ++ "\n", .{ c.name, path } ++ args);
    }

    fn difference(c: *Check, a: std.mem.Allocator, out: *Io.Writer, path: []const u8, d: document_diff.Difference) !void {
        const expected = try document_diff.preview(a, d.expected);
        const actual = try document_diff.preview(a, d.actual);
        try c.fail(out, path, "differs at {s} expected {s} actual {s}", .{ d.path, expected, actual });
    }
};

/// Every check of one file or of the whole corpus
const Tally = struct {
    detection: Check = .{ .name = "detect" },
    round_trip: Check = .{ .name = "json-round-trip" },
    skel: SkelChecks = .{},
    robustness: Check = .{ .name = "robustness" },
    atlas: Check = .{ .name = "atlas" },

    fn checks(t: *const Tally) [7]Check {
        return .{ t.detection, t.round_trip, t.skel.decode, t.skel.round_trip, t.skel.encode, t.atlas, t.robustness };
    }

    fn add(t: *Tally, other: Tally) void {
        inline for (.{ "detection", "round_trip", "robustness", "atlas" }) |field| sum(&@field(t, field), @field(other, field));
        inline for (.{ "decode", "round_trip", "encode" }) |field| sum(&@field(t.skel, field), @field(other.skel, field));
    }

    fn sum(c: *Check, other: Check) void {
        c.passed += other.passed;
        c.failed += other.failed;
        c.skipped += other.skipped;
    }
};

/// One file checked on its own task, printed in walk order
const Job = struct {
    path: []const u8,
    tally: Tally = .{},
    output: Io.Writer.Allocating,
    err: ?anyerror = null,
};

/// Layout written by tools/fetch-corpus.sh
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const root_path = if (args.len > 1) args[1] else "testdata/corpus";

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var root = Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |e| {
        try out.print("cannot open {s}: {t}\nrun tools/fetch-corpus.sh first\n", .{ root_path, e });
        return 2;
    };
    defer root.close(io);

    var jobs: std.ArrayList(Job) = .empty;
    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".atlas") and !std.mem.eql(u8, ext, ".skel") and !std.mem.eql(u8, ext, ".json")) continue;
        try jobs.append(arena, .{ .path = try arena.dupe(u8, entry.path), .output = .init(gpa) });
    }

    var group: Io.Group = .init;
    for (jobs.items) |*job| group.async(io, checkFile, .{ io, gpa, root, job });
    try group.await(io);

    var total: Tally = .{};
    for (jobs.items) |*job| {
        defer job.output.deinit();
        if (job.err) |e| return e;
        try out.writeAll(job.output.written());
        total.add(job.tally);
    }
    var failed = false;
    for (total.checks()) |c| {
        try out.print("{s}: {d} passed, {d} failed, {d} skipped\n", .{ c.name, c.passed, c.failed, c.skipped });
        failed = failed or c.failed > 0 or c.passed == 0;
    }
    return if (failed) 1 else 0;
}

fn checkFile(io: Io, gpa: std.mem.Allocator, root: Io.Dir, job: *Job) void {
    checkPath(io, gpa, root, job) catch |e| {
        job.err = e;
    };
}

fn checkPath(io: Io, gpa: std.mem.Allocator, root: Io.Dir, job: *Job) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const out = &job.output.writer;
    const t = &job.tally;
    const dir_path = std.fs.path.dirname(job.path) orelse ".";
    var dir = try root.openDir(io, dir_path, .{});
    defer dir.close(io);
    const basename = std.fs.path.basename(job.path);
    const ext = std.fs.path.extension(basename);
    if (std.mem.eql(u8, ext, ".atlas")) {
        const data = try dir.readFileAlloc(io, basename, a, .unlimited);
        try checkAtlas(a, out, &t.atlas, job.path, data);
        try checkAtlasRobustness(gpa, &t.robustness, job.path, data);
        return;
    }
    const sample = try load(io, a, dir, basename, job.path, std.mem.eql(u8, ext, ".skel"));
    try checkDetection(out, &t.detection, sample);
    try checkJsonRoundTrip(a, out, &t.round_trip, sample);
    try checkSkel(a, out, &t.skel, sample);
    try checkRobustness(gpa, &t.robustness, sample);
}

fn load(io: Io, a: std.mem.Allocator, dir: Io.Dir, name: []const u8, path: []const u8, is_skel: bool) !Sample {
    const data = try dir.readFileAlloc(io, name, a, .unlimited);
    if (!is_skel) {
        const tree = parse(a, data);
        return .{ .path = path, .is_skel = false, .data = data, .tree = tree, .truth = truthOf(tree) };
    }
    const stem = name[0 .. name.len - ".skel".len];
    const sibling = dir.readFileAlloc(io, try std.mem.concat(a, u8, &.{ stem, ".json" }), a, .unlimited) catch "";
    const sibling_tree = parse(a, sibling);
    const truth: Truth = switch (truthOf(sibling_tree)) {
        .not_skeleton => .unversioned,
        // dev exports of json and skel may differ
        .version => |v| if (sc.Version.parse(v) == null or staleBeta(data, v)) .any_version else .{ .version = v },
        else => |t| t,
    };
    return .{ .path = path, .is_skel = true, .data = data, .tree = sibling_tree, .sibling = sibling, .truth = truth };
}

/// A skel left from a beta of the minor its json was re-exported in, as in 3.5.51
fn staleBeta(skel: []const u8, json_version: []const u8) bool {
    const want = sc.Version.parse(json_version) orelse return false;
    const detected = sc.detect(skel) catch return false;
    const got = detected.version orelse return false;
    return got.major == want.major and got.minor == want.minor and !std.mem.eql(u8, got.text(), json_version) and
        std.mem.indexOf(u8, got.text(), "beta") != null;
}

fn parse(a: std.mem.Allocator, data: []const u8) ?Value {
    const body = if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) data[3..] else data;
    return std.json.parseFromSliceLeaky(Value, a, body, .{}) catch null;
}

fn truthOf(tree: ?Value) Truth {
    const root = tree orelse return .not_skeleton;
    if (root != .object) return .not_skeleton;
    const skeleton = root.object.get("skeleton");
    if (skeleton == null and root.object.get("bones") == null) return .not_skeleton;
    const spine = if (skeleton) |s| if (s == .object) s.object.get("spine") else null else null;
    return if (spine) |v| if (v == .string) .{ .version = v.string } else .unversioned else .unversioned;
}

fn checkDetection(out: *Io.Writer, check: *Check, sample: Sample) !void {
    const detected = sc.detect(sample.data);
    const format: sc.Format = if (sample.is_skel) .binary else .json;
    const ok = switch (sample.truth) {
        .not_skeleton => detected == error.UnknownFormat,
        .unversioned => if (detected) |d| d.format == .json and d.version == null else |_| sample.is_skel,
        .any_version => if (detected) |d| d.version != null else |_| false,
        .version => |want| if (detected) |d|
            d.format == format and d.version != null and std.mem.eql(u8, d.version.?.text(), want)
        else |_|
            false,
    };
    if (ok) {
        check.passed += 1;
        return;
    }
    const got = if (detected) |d| if (d.version) |*v| v.text() else "no version" else |_| "unknown";
    const want = switch (sample.truth) {
        .version => |v| v,
        else => @tagName(sample.truth),
    };
    try check.fail(out, sample.path, "expected {s}, detected {s}", .{ want, got });
}

fn checkJsonRoundTrip(a: std.mem.Allocator, out: *Io.Writer, check: *Check, sample: Sample) !void {
    if (sample.is_skel or sample.truth != .version) return;
    var report: sc.Report = .{ .arena = a };
    const output = sc.convert.convert(a, sample.data, .{}, &report) catch |e| {
        return check.fail(out, sample.path, "{t}", .{e});
    };
    const tree = parse(a, output.data) orelse return check.fail(out, sample.path, "output is not JSON", .{});
    if (try document_diff.firstDifference(a, sample.tree.?, tree, .{})) |d| return check.difference(a, out, sample.path, d);
    check.passed += 1;
}

const powerup_keys: []const []const u8 = &.{
    "bounce/bones/star6/rotate/1", "bounce/bones/star6/scale/1", "bounce/bones/star6/translate/1",
    "bounce/bones/star8/rotate/1", "bounce/bones/star8/scale/1", "bounce/bones/star8/translate/1",
    "bounce/bones/star9/rotate/1", "bounce/bones/star9/scale/1", "bounce/bones/star9/translate/1",
    "bounce/slots/star5/color/2",  "bounce/slots/star6/color/0", "bounce/slots/star6/color/2",
    "bounce/slots/star8/color/2",  "bounce/slots/star9/color/1",
};

/// Json keys of the corpus that are stepped where the skel of the same export is linear
const linear_in_skel = [_]struct { []const u8, []const []const u8 }{
    .{ "3.5/powerup/powerup", &.{
        "animation/bones/star5/rotate/1", "animation/bones/star5/scale/1", "animation/bones/star5/translate/1",
        "animation/bones/star6/rotate/1", "animation/bones/star6/scale/1", "animation/bones/star6/translate/1",
        "animation/bones/star8/rotate/1", "animation/bones/star8/scale/1", "animation/bones/star8/translate/1",
        "animation/bones/star9/rotate/1", "animation/bones/star9/scale/1", "animation/bones/star9/translate/1",
        "animation/slots/star5/color/2",  "animation/slots/star6/color/2", "animation/slots/star8/color/2",
        "animation/slots/star9/color/1",
    } },
    .{ "3.6/powerup/powerup-", powerup_keys },
    .{ "3.7/powerup/powerup-", powerup_keys },
    .{ "3.8/powerup/powerup-", powerup_keys },
};

/// Skel keys of the corpus that are stepped where the json of the same export is linear
const linear_in_json = [_]struct { []const u8, []const []const u8 }{
    .{ "3.6/raptor/raptor-pro", &.{"gun-holster/ik/front-arm-goal/1"} },
};

const SkelChecks = struct {
    decode: Check = .{ .name = "skel-decode" },
    round_trip: Check = .{ .name = "skel-round-trip" },
    encode: Check = .{ .name = "json-encode" },
};

/// Skips versions without a binary codec
fn checkSkel(a: std.mem.Allocator, out: *Io.Writer, checks: *SkelChecks, sample: Sample) !void {
    if (!sample.is_skel or sample.truth != .version) return;
    var decoded = convertTo(a, sample.data, .json) catch |e| switch (e) {
        error.UnsupportedVersion => return,
        else => return checks.decode.fail(out, sample.path, "{t}", .{e}),
    };

    round_trip: {
        const binary = convertTo(a, sample.data, .binary) catch |e| break :round_trip try checks.round_trip.fail(out, sample.path, "encode {t}", .{e});
        const again = convertTo(a, binary.string, .json) catch |e| break :round_trip try checks.round_trip.fail(out, sample.path, "decode {t}", .{e});
        if (try document_diff.firstDifference(a, decoded, again, .{})) |d| break :round_trip try checks.round_trip.difference(a, out, sample.path, d);
        checks.round_trip.passed += 1;
    }

    for (linear_in_json) |known| {
        if (!std.mem.startsWith(u8, sample.path, known[0])) continue;
        for (known[1]) |key| if (!makeLinear(&decoded, key)) return checks.decode.fail(out, sample.path, "{s} is not a stepped key", .{key});
    }
    const tolerance = exportTolerance(sample.truth.version);
    const legacy = sc.Version.parse(sample.truth.version).?.major < 4;
    var expected = sample.tree.?;
    var sibling = sample.sibling;
    for (linear_in_skel) |known| {
        if (!std.mem.startsWith(u8, sample.path, known[0])) continue;
        for (known[1]) |key| if (!makeLinear(&expected, key)) return checks.decode.fail(out, sample.path, "{s} is not a stepped key", .{key});
        sibling = try std.json.Stringify.valueAlloc(a, expected, .{});
    }
    try normalizeExport(a, &expected, tolerance);
    try normalizeExport(a, &decoded, tolerance);
    if (legacy) {
        normalizeLegacyExport(&expected);
        normalizeLegacyExport(&decoded);
    }
    if (try document_diff.firstDifference(a, expected, decoded, tolerance)) |d| {
        try checks.decode.difference(a, out, sample.path, d);
    } else checks.decode.passed += 1;

    const binary = convertTo(a, sibling, .binary) catch |e| return checks.encode.fail(out, sample.path, "encode {t}", .{e});
    var encoded = convertTo(a, binary.string, .json) catch |e| return checks.encode.fail(out, sample.path, "decode {t}", .{e});
    try normalizeExport(a, &encoded, tolerance);
    if (legacy) normalizeLegacyExport(&encoded);
    if (try document_diff.firstDifference(a, decoded, encoded, tolerance)) |d| return checks.encode.difference(a, out, sample.path, d);
    checks.encode.passed += 1;
}

/// Path is animation, timeline kind, name, timeline and key index
fn makeLinear(root: *Value, path: []const u8) bool {
    if (root.* != .object) return false;
    var v = root.object.getPtr("animations") orelse return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| v = switch (v.*) {
        .object => |*o| o.getPtr(part) orelse return false,
        .array => |*items| key: {
            const i = std.fmt.parseInt(usize, part, 10) catch return false;
            if (i >= items.items.len) return false;
            break :key &items.items[i];
        },
        else => return false,
    };
    if (v.* != .object) return false;
    const curve = v.object.get("curve") orelse return false;
    if (curve != .string or !std.mem.eql(u8, curve.string, "stepped")) return false;
    _ = v.object.orderedRemove("curve");
    return true;
}

fn exportTolerance(version: []const u8) document_diff.Tolerance {
    const v = sc.Version.parse(version).?;
    if (v.major == 3 and v.minor <= 5) return document_diff.truncated_export;
    return if (v.major > 4 or v.major == 4 and v.minor >= 3) document_diff.json_export else document_diff.legacy_export;
}

/// JSON output comes back parsed, binary output as a string value
fn convertTo(a: std.mem.Allocator, data: []const u8, format: sc.Format) !Value {
    var report: sc.Report = .{ .arena = a };
    const output = try sc.convert.convert(a, data, .{ .target_format = format }, &report);
    if (format == .binary) return .{ .string = output.data };
    return parse(a, output.data) orelse error.Malformed;
}

/// Removes what JSON exports write differently from binary exports of the same project
fn normalizeExport(a: std.mem.Allocator, v: *Value, tolerance: document_diff.Tolerance) !void {
    switch (v.*) {
        .array => |*items| {
            for (items.items) |*item| try normalizeExport(a, item, tolerance);
            // only JSON exports keep the curve of the last key
            if (items.items.len > 0 and items.getLast() == .object) _ = items.items[items.items.len - 1].object.orderedRemove("curve");
            for (items.items[0..items.items.len -| 1], 1..) |*key, next| {
                if (key.* != .object) continue;
                const c = key.object.get("curve") orelse continue;
                // stepped between keys equal at export precision equals linear
                if (c == .string and try sameValues(a, key.*, items.items[next], tolerance)) _ = key.object.orderedRemove("curve");
            }
        },
        .object => |*o| {
            // JSON exports omit visibility
            _ = o.orderedRemove("visible");
            if (o.get("skins")) |skins| if (skins == .array) {
                // JSON exports write skin lists in set order and hash that order
                var listed = false;
                for (skins.array.items) |skin| listed = sortSkinLists(skin) or listed;
                const skeleton = o.getPtr("skeleton");
                if (listed and skeleton != null and skeleton.?.* == .object) _ = skeleton.?.object.orderedRemove("hash");
            };
            const one_bone = if (o.get("bones")) |b| b == .array and b.array.items.len == 1 else false;
            // bend direction is unused by one bone IK
            if (one_bone and o.get("target") != null) _ = o.orderedRemove("bendPositive");
            if (o.get("bone") != null and o.get("type") != null and std.mem.eql(u8, o.get("type").?.string, "slider")) {
                // JSON exports write the slider max as time
                if (o.fetchOrderedRemove("time")) |time| try o.put(a, "max", time.value);
            }
            if (o.get("vertices") != null and o.get("uvs") == null and o.get("vertexCount") == null) try denseDeform(a, o);
            for (o.values()) |*child| try normalizeExport(a, child, tolerance);
        },
        else => {},
    }
}

/// Removes what exports before 4.0 write differently in JSON and binary
fn normalizeLegacyExport(v: *Value) void {
    if (v.* != .object) return;
    // JSON and binary exports hash different data
    if (v.object.getPtr("skeleton")) |s| if (s.* == .object) {
        _ = s.object.orderedRemove("hash");
    };
    // binary exports drop skins without attachments
    const skins = v.object.getPtr("skins") orelse return;
    // skins before 3.8 map names to slots
    if (skins.* == .object) {
        var i: usize = 0;
        while (i < skins.object.count()) {
            const slots = skins.object.values()[i];
            if (slots == .object and slots.object.count() == 0) skins.object.orderedRemoveAt(i) else i += 1;
        }
        return;
    }
    if (skins.* != .array) return;
    var i: usize = 0;
    while (i < skins.array.items.len) {
        const attachments = if (skins.array.items[i] == .object) skins.array.items[i].object.get("attachments") else null;
        const empty = if (attachments) |m| m == .object and m.object.count() == 0 else true;
        if (empty) _ = skins.array.orderedRemove(i) else i += 1;
    }
}

/// JSON exports trim deform values that round to zero
fn denseDeform(a: std.mem.Allocator, key: *std.json.ObjectMap) !void {
    const offset: usize = if (key.fetchOrderedRemove("offset")) |o| @intCast(o.value.integer) else 0;
    var dense = std.json.Array.init(a);
    try dense.appendNTimes(.{ .integer = 0 }, offset);
    try dense.appendSlice(key.get("vertices").?.array.items);
    while (dense.items.len > 0) {
        const last = dense.getLast();
        const x: f64 = switch (last) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => break,
        };
        if (@abs(x) > document_diff.json_export.vertices) break;
        _ = dense.pop();
    }
    if (dense.items.len == 0) {
        _ = key.orderedRemove("vertices");
    } else try key.put(a, "vertices", .{ .array = dense });
}

fn sameValues(a: std.mem.Allocator, key: Value, next: Value, tolerance: document_diff.Tolerance) !bool {
    if (next != .object) return false;
    var x = try key.object.clone(a);
    var y = try next.object.clone(a);
    // 3.8 JSON splits bezier curves into c2 c3 c4
    for ([_][]const u8{ "time", "curve", "c2", "c3", "c4" }) |k| {
        _ = x.orderedRemove(k);
        _ = y.orderedRemove(k);
    }
    return try document_diff.firstDifference(a, .{ .object = x }, .{ .object = y }, tolerance) == null;
}

/// Damaged input may fail but must not crash
fn checkRobustness(gpa: std.mem.Allocator, check: *Check, sample: Sample) !void {
    if (sample.truth != .version) return;
    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0, sample.path));
    const random = prng.random();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    if (convertTo(a, sample.data, .json)) |_| {} else |e| if (e == error.UnsupportedVersion) return;
    const targets = neighbors(sc.Version.parse(sample.truth.version) orelse return);

    if (sample.is_skel) {
        for (0..64) |i| {
            _ = scratch.reset(.retain_capacity);
            const data = try a.dupe(u8, sample.data);
            const damaged = if (i < 32) data[0 .. data.len * i / 32] else damage: {
                for (0..1 + random.uintLessThan(usize, 4)) |_| data[random.uintLessThan(usize, data.len)] = random.int(u8);
                break :damage data;
            };
            attempt(a, damaged, &targets);
        }
        check.passed += 1;
        return;
    }

    var tree = sample.tree orelse return;
    var values: std.ArrayList(*Value) = .empty;
    try collectValues(a, &tree, &values);
    const replacements = [_]Value{ .null, .{ .integer = -1 }, .{ .integer = 1 << 40 }, .{ .float = -0.5 }, .{ .string = "?" }, .{ .string = "itfFESDjM1rBjm48y5ND1Ud5zqk" }, .{ .float = 1e30 }, .{ .integer = -(1 << 40) }, .{ .bool = true }, .{ .array = .init(a) }, .{ .object = .empty } };
    for (0..32) |_| {
        const target = values.items[random.uintLessThan(usize, values.items.len)];
        const original = target.*;
        target.* = replacements[random.uintLessThan(usize, replacements.len)];
        defer target.* = original;
        attempt(a, try std.json.Stringify.valueAlloc(a, tree, .{}), &targets);
    }
    check.passed += 1;
}

/// Atlases convert to both layouts
fn checkAtlas(a: std.mem.Allocator, out: *Io.Writer, check: *Check, path: []const u8, data: []const u8) !void {
    const detected = sc.detect(data) catch |e| return check.fail(out, path, "detect {t}", .{e});
    if (detected.format != .atlas) return check.fail(out, path, "detected {t}", .{detected.format});
    for (atlas_targets) |version| {
        var report: sc.Report = .{ .arena = a };
        _ = sc.convert.convert(a, data, .{ .target_version = sc.Version.parse(version).? }, &report) catch |e| {
            return check.fail(out, path, "to {s} {t}", .{ version, e });
        };
    }
    check.passed += 1;
}

const atlas_targets = [_][]const u8{ "3.8", "4.3" };

/// Damaged atlases may fail but must not crash
fn checkAtlasRobustness(gpa: std.mem.Allocator, check: *Check, path: []const u8, data: []const u8) !void {
    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0, path));
    const random = prng.random();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const bytes = ":,\n\t -0123456789xytruefalse";
    for (0..64) |i| {
        _ = scratch.reset(.retain_capacity);
        const copy = try a.dupe(u8, data);
        const damaged = if (i < 32) copy[0 .. copy.len * i / 32] else damage: {
            for (0..1 + random.uintLessThan(usize, 4)) |_| copy[random.uintLessThan(usize, copy.len)] = bytes[random.uintLessThan(usize, bytes.len)];
            break :damage copy;
        };
        for (atlas_targets) |version| {
            var report: sc.Report = .{ .arena = a };
            _ = sc.convert.convert(a, damaged, .{ .target_version = sc.Version.parse(version).? }, &report) catch {};
        }
    }
    check.passed += 1;
}

/// Converts to both formats in the source version and its adjacent versions, errors are expected
fn attempt(a: std.mem.Allocator, data: []const u8, targets: []const ?sc.Version) void {
    for (targets) |version| for ([_]sc.Format{ .json, .binary }) |format| {
        var report: sc.Report = .{ .arena = a };
        _ = sc.convert.convert(a, data, .{ .target_version = version, .target_format = format }, &report) catch {};
    };
}

fn neighbors(version: sc.Version) [3]?sc.Version {
    const minors = [_][]const u8{ "3.8", "4.0", "4.1", "4.2", "4.3" };
    var out: [3]?sc.Version = .{ null, null, null };
    for (minors, 0..) |m, i| {
        const v = sc.Version.parse(m).?;
        if (v.major != version.major or v.minor != version.minor) continue;
        if (i > 0) out[1] = sc.Version.parse(minors[i - 1]).?;
        if (i + 1 < minors.len) out[2] = sc.Version.parse(minors[i + 1]).?;
    }
    return out;
}

/// Skips the version so detection still succeeds
fn collectValues(a: std.mem.Allocator, v: *Value, out: *std.ArrayList(*Value)) !void {
    switch (v.*) {
        .array => |*items| for (items.items) |*item| {
            try out.append(a, item);
            try collectValues(a, item, out);
        },
        .object => |*o| for (o.keys(), o.values()) |key, *item| {
            if (std.mem.eql(u8, key, "spine")) continue;
            try out.append(a, item);
            try collectValues(a, item, out);
        },
        else => {},
    }
}

/// Returns whether the skin lists any names
fn sortSkinLists(skin: Value) bool {
    if (skin != .object) return false;
    var listed = false;
    lists: for (skin.object.values()) |list| {
        if (list != .array) continue;
        for (list.array.items) |name| if (name != .string) continue :lists;
        std.mem.sort(Value, list.array.items, {}, struct {
            fn lessThan(_: void, x: Value, y: Value) bool {
                return std.mem.lessThan(u8, x.string, y.string);
            }
        }.lessThan);
        listed = listed or list.array.items.len > 0;
    }
    return listed;
}

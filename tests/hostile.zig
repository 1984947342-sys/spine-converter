const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const sc = @import("spine_converter");

const usage =
    \\usage: hostile damage <skeleton> <case file> <cases>
    \\       hostile replay <case file>
    \\       hostile text <count>
    \\       hostile variants <json> <out directory> <count>
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const command = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, command, "damage") and args.len == 5) {
        return damage(init.gpa, io, out, args[2], args[3], try std.fmt.parseInt(usize, args[4], 10));
    }
    if (std.mem.eql(u8, command, "replay") and args.len == 3) {
        return replay(init.gpa, io, out, args[2]);
    }
    if (std.mem.eql(u8, command, "text") and args.len == 3) {
        return text(a, out, try std.fmt.parseInt(usize, args[2], 10));
    }
    if (std.mem.eql(u8, command, "variants") and args.len == 5) {
        return variants(a, io, args[2], args[3], try std.fmt.parseInt(usize, args[4], 10));
    }
    try out.writeAll(usage);
    return 2;
}

const Tally = struct {
    attempts: usize = 0,
    accepted: usize = 0,
    /// Output the converter cannot read back
    unreadable: ?Attempt = null,
    /// Framed but damaged in meaning
    binary: ?[]const u8 = null,
};

const Attempt = struct {
    version: ?sc.Version = null,
    format: sc.Format = .unknown,
    rewrite: bool = true,
    failure: anyerror = error.None,
    output: []const u8 = "",
};

const minors = [_][]const u8{ "3.5", "3.6", "3.7", "3.8", "4.0", "4.1", "4.2", "4.3" };

/// Crashes hangs and unreadable output are the failures
fn attempt(a: std.mem.Allocator, data: []const u8, how: Attempt, tally: *Tally) void {
    tally.attempts += 1;
    var report: sc.Report = .{ .arena = a };
    const output = sc.convert.convert(a, data, .{
        .target_version = how.version,
        .target_format = how.format,
        .rewrite = how.rewrite,
    }, &report) catch return;
    tally.accepted += 1;
    if (output.format == .binary) tally.binary = output.data;
    var back: sc.Report = .{ .arena = a };
    _ = sc.convert.convert(a, output.data, .{ .target_format = output.format }, &back) catch |e| {
        if (e != error.OutOfMemory and tally.unreadable == null) {
            tally.unreadable = how;
            tally.unreadable.?.failure = e;
            tally.unreadable.?.output = output.data;
        }
    };
}

/// Superset of what one damage case picks
fn attemptAll(a: std.mem.Allocator, data: []const u8, tally: *Tally) void {
    for ([_]sc.Format{ .json, .binary }) |format| {
        attempt(a, data, .{ .format = format }, tally);
        for (minors) |minor| {
            const version = sc.Version.parse(minor).?;
            attempt(a, data, .{ .version = version, .format = format }, tally);
            attempt(a, data, .{ .version = version, .format = format, .rewrite = false }, tally);
        }
    }
}

fn attemptSome(a: std.mem.Allocator, random: std.Random, data: []const u8, tally: *Tally) void {
    attempt(a, data, .{ .format = .json }, tally);
    attempt(a, data, .{ .format = .binary }, tally);
    const version = sc.Version.parse(minors[random.uintLessThan(usize, minors.len)]).?;
    const rewrite = random.boolean();
    attempt(a, data, .{ .version = version, .format = .json, .rewrite = rewrite }, tally);
    attempt(a, data, .{ .version = version, .format = .binary, .rewrite = rewrite }, tally);
}

fn damage(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, path: []const u8, case_path: []const u8, cases: usize) !u8 {
    var input: std.heap.ArenaAllocator = .init(gpa);
    defer input.deinit();
    const data = try Io.Dir.cwd().readFileAlloc(io, path, input.allocator(), .unlimited);
    const detected = sc.detect(data) catch return 0;
    if (detected.format != .json and detected.format != .binary) return 0;

    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0, std.fs.path.basename(path)) ^ data.len);
    const random = prng.random();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var tally: Tally = .{};
    for (0..cases) |_| {
        _ = scratch.reset(.retain_capacity);
        var case = if (detected.format == .json) try damagedJson(a, random, data) else try damagedBytes(a, random, data);
        // the case then a binary made from it
        for (0..2) |_| {
            // kept for replay when the process dies
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = case_path, .data = case });
            tally.binary = null;
            attemptSome(a, random, case, &tally);
            if (tally.unreadable) |how| {
                try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.out", .{case_path}), .data = how.output });
                try out.print("UNREADABLE {t} {s} to {?s} {t} rewrite {}\n", .{ how.failure, path, if (how.version) |*v| v.text() else null, how.format, how.rewrite });
                return 1;
            }
            case = tally.binary orelse break;
        }
    }
    try out.print("{d} {d}\n", .{ tally.attempts, tally.accepted });
    return 0;
}

fn replay(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, path: []const u8) !u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const data = try Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var tally: Tally = .{};
    attemptAll(a, data, &tally);
    try out.print("{d} attempts {d} accepted\n", .{ tally.attempts, tally.accepted });
    if (tally.unreadable) |how| {
        try out.print("UNREADABLE to {?s} {t} rewrite {}\n", .{ if (how.version) |*v| v.text() else null, how.format, how.rewrite });
        return 1;
    }
    return 0;
}

/// Bytes that keep framing more often than random ones
fn damagedBytes(a: std.mem.Allocator, random: std.Random, source: []const u8) ![]const u8 {
    var data: std.ArrayList(u8) = .empty;
    try data.appendSlice(a, source);
    for (0..1 + random.uintLessThan(usize, 3)) |_| {
        if (data.items.len < 16) break;
        // the header stays so detection passes
        const at = 16 + random.uintLessThan(usize, data.items.len - 16);
        const room = data.items.len - at;
        switch (random.uintLessThan(u8, 7)) {
            0 => data.items[at] = ([_]u8{ 0, 1, 0x7F, 0x80, 0xFF })[random.uintLessThan(usize, 5)],
            1 => data.items[at] +%= 1,
            2 => data.items[at] -%= 1,
            3 => if (room >= 4) {
                const words = [_]u32{ 0x7FC00000, 0x7F800000, 0xFF800000, 0x7FFFFFFF, 0x80000000 };
                std.mem.writeInt(u32, data.items[at..][0..4], words[random.uintLessThan(usize, words.len)], .big);
            },
            4 => if (room >= 5) {
                // varint of the largest count
                @memcpy(data.items[at..][0..5], "\xFF\xFF\xFF\xFF\x07");
            },
            5 => {
                const length = 1 + random.uintLessThan(usize, @min(room, 64));
                data.replaceRangeAssumeCapacity(at, length, &.{});
            },
            else => {
                const length = 1 + random.uintLessThan(usize, @min(room, 64));
                const copy = try a.dupe(u8, data.items[at..][0..length]);
                try data.insertSlice(a, at, copy);
            },
        }
    }
    return data.items;
}

const Node = struct {
    value: *Value,
    /// Null for the root
    owner: ?*Value = null,
    key: []const u8 = "",
    index: usize = 0,
};

/// Skips the version so detection still succeeds
fn collect(a: std.mem.Allocator, v: *Value, nodes: *std.ArrayList(Node), names: *std.ArrayList([]const u8)) !void {
    switch (v.*) {
        .array => |*items| for (items.items, 0..) |*item, i| {
            try nodes.append(a, .{ .value = item, .owner = v, .index = i });
            try collect(a, item, nodes, names);
        },
        .object => |*o| for (o.keys(), o.values()) |key, *item| {
            if (std.mem.eql(u8, key, "spine")) continue;
            if (std.mem.eql(u8, key, "name") and item.* == .string) try names.append(a, item.string);
            try nodes.append(a, .{ .value = item, .owner = v, .key = key });
            try collect(a, item, nodes, names);
        },
        else => {},
    }
}

/// Loaders read these as references or counts
const wild = [_]Value{
    .null,                   .{ .integer = 0 },       .{ .integer = -1 },         .{ .integer = 1 },
    .{ .integer = 1 << 31 }, .{ .integer = 1 << 53 }, .{ .integer = -(1 << 31) }, .{ .float = 0.5 },
    .{ .float = 1e308 },     .{ .float = -1e308 },    .{ .float = 1e-320 },       .{ .string = "" },
    .{ .string = "?" },      .{ .string = "\x00" },   .{ .bool = true },
};

fn damagedJson(a: std.mem.Allocator, random: std.Random, source: []const u8) ![]const u8 {
    const body = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) source[3..] else source;
    var tree = try std.json.parseFromSliceLeaky(Value, a, body, .{});
    for (0..1 + random.uintLessThan(usize, 3)) |_| {
        var nodes: std.ArrayList(Node) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        try collect(a, &tree, &nodes, &names);
        if (nodes.items.len == 0) break;
        try damageNode(a, random, &tree, nodes.items, names.items);
    }
    return std.json.Stringify.valueAlloc(a, tree, .{});
}

fn damageNode(a: std.mem.Allocator, random: std.Random, tree: *Value, nodes: []const Node, names: []const []const u8) !void {
    const node = nodes[random.uintLessThan(usize, nodes.len)];
    const owner = node.owner.?;
    switch (random.uintLessThan(u8, 8)) {
        0 => node.value.* = wild[random.uintLessThan(usize, wild.len)],
        1 => switch (owner.*) {
            .object => |*o| _ = o.orderedRemove(node.key),
            .array => |*items| _ = items.orderedRemove(node.index),
            else => unreachable,
        },
        2 => if (owner.* == .array) try owner.array.append(try cloned(a, node.value.*)),
        3 => if (owner.* == .array and owner.array.items.len > 1) {
            std.mem.swap(Value, node.value, &owner.array.items[random.uintLessThan(usize, owner.array.items.len)]);
        },
        // dangling and repeated references
        4 => if (node.value.* == .string and names.len > 0) {
            node.value.* = .{ .string = names[random.uintLessThan(usize, names.len)] };
        },
        5 => if (node.value.* == .array) {
            node.value.array.shrinkRetainingCapacity(random.uintLessThan(usize, node.value.array.items.len + 1));
        },
        6 => try wrongParent(a, random, tree),
        else => node.value.* = switch (node.value.*) {
            .object => .{ .array = .init(a) },
            .array => .{ .object = .empty },
            .string => .{ .integer = 1 },
            else => .{ .string = "?" },
        },
    }
}

/// Cycles and parents that come later
fn wrongParent(a: std.mem.Allocator, random: std.Random, tree: *Value) !void {
    if (tree.* != .object) return;
    const bones = tree.object.getPtr("bones") orelse return;
    if (bones.* != .array or bones.array.items.len == 0) return;
    const items = bones.array.items;
    const bone = &items[random.uintLessThan(usize, items.len)];
    const other = items[random.uintLessThan(usize, items.len)];
    if (bone.* != .object or other != .object) return;
    const name = other.object.get("name") orelse return;
    try bone.object.put(a, "parent", name);
}

fn cloned(a: std.mem.Allocator, v: Value) !Value {
    return std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, v, .{}), .{});
}

/// Shapes found beside exports that are not skeletons
const not_skeletons = [_][]const u8{
    "",
    " \r\n",
    "{}",
    "[]",
    "null",
    "{\"name\":\"package\",\"version\":\"1.0.0\",\"dependencies\":{}}",
    "{\r\n  \"runtimeTarget\": {\r\n    \"name\": \".NETStandard,Version=v2.0/\",\r\n    \"signature\": \"\"\r\n  },\r\n  \"compilationOptions\": {},\r\n  \"targets\": {\r\n    \".NETStandard,Version=v2.0\": {},\r\n    \".NETStandard,Version=v2.0/\": {\r\n      \"spine-csharp/1.0.0\": {\r\n        \"runtime\": {}\r\n      }\r\n    }\r\n  },\r\n  \"libraries\": {}\r\n}\r\n",
    "{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{}}",
    "[{\"Code\":\"en\",\"Name\":\"English\"},{\"Code\":\"zh\",\"Name\":\"Chinese\"}]",
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Project Sdk=\"Microsoft.NET.Sdk\"></Project>\n",
    "using System;\nnamespace Game;\npublic class Enemy { }\n",
    "keys,en,zh\nhello,Hello,Ni Hao\n",
    "[gd_scene load_steps=2 format=3]\n\n[node name=\"Player\" type=\"Node2D\"]\n",
    "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR",
    "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03",
    "PK\x03\x04\x14\x00\x00\x00\x08\x00",
};

/// A newline can land on a binary length
fn text(a: std.mem.Allocator, out: *Io.Writer, count: usize) !u8 {
    var wrong: usize = 0;
    for (not_skeletons) |sample| wrong += try misdetected(out, sample);
    var prng: std.Random.DefaultPrng = .init(0);
    const random = prng.random();
    const printable = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-=/.,;\"<>()[]";
    for (0..count) |i| {
        const length = 1 + random.uintLessThan(usize, 512);
        const data = try a.alloc(u8, length);
        for (data) |*c| c.* = if (random.uintLessThan(u8, 16) == 0) '\n' else printable[random.uintLessThan(usize, printable.len)];
        // half are objects without skeleton keys
        if (i % 2 == 0) data[0] = '{';
        wrong += try misdetected(out, data);
        a.free(data);
    }
    try out.print("{d} {d}\n", .{ not_skeletons.len + count, wrong });
    return if (wrong == 0) 0 else 1;
}

fn misdetected(out: *Io.Writer, data: []const u8) !usize {
    const detected = sc.detect(data) catch return 0;
    try out.print("MISDETECTED {t} {?s}: {f}\n", .{
        detected.format,
        if (detected.version) |*v| v.text() else null,
        std.zig.fmtString(data[0..@min(data.len, 40)]),
    });
    return 1;
}

/// Loaders accept these under these keys
const enums = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "transform", &[_][]const u8{ "normal", "onlyTranslation", "noRotationOrReflection", "noScale", "noScaleOrReflection" } },
    .{ "inherit", &[_][]const u8{ "normal", "onlyTranslation", "noRotationOrReflection", "noScale", "noScaleOrReflection" } },
    .{ "blend", &[_][]const u8{ "normal", "additive", "multiply", "screen" } },
    .{ "positionMode", &[_][]const u8{ "fixed", "percent" } },
    .{ "spacingMode", &[_][]const u8{ "length", "fixed", "percent", "proportional" } },
    .{ "rotateMode", &[_][]const u8{ "tangent", "chain", "chainScale" } },
});

/// Structure the loaders read as counts and indices
const structural = std.StaticStringMap(void).initComptime(.{
    .{"vertices"}, .{"uvs"},        .{"triangles"}, .{"edges"},   .{"hull"},  .{"vertexCount"},
    .{"lengths"},  .{"order"},      .{"offset"},    .{"offsets"}, .{"hash"},  .{"spine"},
    .{"images"},   .{"audio"},      .{"name"},      .{"parent"},  .{"color"}, .{"dark"},
    .{"path"},     .{"bone"},       .{"bones"},     .{"target"},  .{"slot"},  .{"skin"},
    .{"type"},     .{"attachment"}, .{"time"},
});

/// Defaults exports leave out and the first and last minor that read them
const Optional = struct { key: []const u8, from: u32 = 305, to: u32 = 403 };
const optional = [_]Optional{
    .{ .key = "mix" },
    .{ .key = "mixX", .from = 400 },
    .{ .key = "mixY", .from = 400 },
    .{ .key = "mixRotate", .from = 400 },
    .{ .key = "mixScaleX", .from = 400 },
    .{ .key = "mixScaleY", .from = 400 },
    .{ .key = "mixShearY", .from = 400 },
    .{ .key = "rotateMix", .to = 308 },
    .{ .key = "translateMix", .to = 308 },
    .{ .key = "scaleMix", .to = 308 },
    .{ .key = "shearMix", .to = 308 },
    .{ .key = "softness", .from = 308 },
    .{ .key = "compress", .from = 307 },
    .{ .key = "stretch", .from = 307 },
    .{ .key = "uniform", .from = 307, .to = 402 },
    .{ .key = "local", .from = 306 },
    .{ .key = "relative", .from = 306, .to = 402 },
    .{ .key = "x" },
    .{ .key = "y" },
    .{ .key = "rotation" },
    .{ .key = "scaleX" },
    .{ .key = "scaleY" },
    .{ .key = "shearX" },
    .{ .key = "shearY" },
    .{ .key = "length" },
    .{ .key = "position" },
    .{ .key = "spacing" },
    .{ .key = "inertia", .from = 402 },
    .{ .key = "strength", .from = 402 },
    .{ .key = "damping", .from = 402 },
    .{ .key = "mass", .from = 402 },
    .{ .key = "wind", .from = 402 },
    .{ .key = "gravity", .from = 402 },
    .{ .key = "limit", .from = 402 },
    .{ .key = "fps", .from = 307 },
};

const flags = std.StaticStringMap(void).initComptime(.{
    .{"uniform"}, .{"compress"}, .{"stretch"}, .{"local"}, .{"relative"},
});

/// Runtimes disagree at these exact zeros
const zeroless = std.StaticStringMap(void).initComptime(.{
    .{"x"}, .{"y"}, .{"spacing"},
});

const Spot = struct { value: *Value, owner: *Value, key: []const u8 };

/// Number arrays stay whole
fn spots(a: std.mem.Allocator, v: *Value, owners: *std.ArrayList(*Value), found: *std.ArrayList(Spot)) !void {
    switch (v.*) {
        .array => |*items| for (items.items) |*item| try spots(a, item, owners, found),
        .object => |*o| {
            try owners.append(a, v);
            for (o.keys(), o.values()) |key, *item| {
                if (!structural.has(key)) switch (item.*) {
                    .integer, .float, .bool => try found.append(a, .{ .value = item, .owner = v, .key = key }),
                    .string => if (enums.has(key)) try found.append(a, .{ .value = item, .owner = v, .key = key }),
                    .null, .array, .object, .number_string => {},
                };
                // the same keys hold names and lists of constraints
                if (item.* == .array or item.* == .object) {
                    if (!(structural.has(key) and !std.mem.eql(u8, key, "path") and !std.mem.eql(u8, key, "bones"))) try spots(a, item, owners, found);
                }
            }
        },
        else => {},
    }
}

/// A field in a map reads as a child
fn record(owners: []const *Value, random: std.Random) ?*Value {
    for (0..32) |_| {
        const owner = owners[random.uintLessThan(usize, owners.len)];
        for (owner.object.values()) |v| if (v != .object and v != .array) return owner;
    }
    return null;
}

/// One change a runtime may still load
fn vary(a: std.mem.Allocator, random: std.Random, tree: *Value, log: *std.ArrayList(u8)) !void {
    const version = sc.Version.ofRoot(tree.*) orelse return;
    const minor = @as(u32, version.major) * 100 + version.minor;
    const sections = tree.object.keys();
    for (0..16) |_| {
        const section = sections[random.uintLessThan(usize, sections.len)];
        if (std.mem.eql(u8, section, "skeleton")) continue;
        var owners: std.ArrayList(*Value) = .empty;
        var found: std.ArrayList(Spot) = .empty;
        try spots(a, tree.object.getPtr(section).?, &owners, &found);
        if (owners.items.len == 0) continue;
        if (found.items.len > 0 and random.boolean()) {
            const spot = found.items[random.uintLessThan(usize, found.items.len)];
            if (random.uintLessThan(u8, 4) == 0 and !zeroless.has(spot.key)) {
                try log.print(a, "{s} delete {s}\n", .{ section, spot.key });
                _ = spot.owner.object.orderedRemove(spot.key);
                return;
            }
            spot.value.* = changed(random, minor, spot.key, spot.value.*);
            try log.print(a, "{s} set {s} {f}\n", .{ section, spot.key, std.json.fmt(spot.value.*, .{}) });
            return;
        }
        const owner = record(owners.items, random) orelse continue;
        const pick = optional[random.uintLessThan(usize, optional.len)];
        // 4.3 reads a mode from this key
        if ((std.mem.eql(u8, section, "ik") or std.mem.eql(u8, section, "physics")) and std.mem.eql(u8, pick.key, "scaleY")) continue;
        if (minor < pick.from or minor > pick.to) continue;
        const key = pick.key;
        const value = changed(random, minor, key, if (flags.has(key)) .{ .bool = random.boolean() } else .{ .float = 1 });
        try owner.object.put(a, key, value);
        try log.print(a, "{s} add {s} {f}\n", .{ section, key, std.json.fmt(value, .{}) });
        return;
    }
}

fn changed(random: std.Random, minor: u32, key: []const u8, value: Value) Value {
    if (enums.get(key)) |names| {
        const name = names[random.uintLessThan(usize, names.len)];
        // loaders before 4.0 read proportional as length
        if (minor < 400 and std.mem.eql(u8, name, "proportional")) return .{ .string = "length" };
        return .{ .string = name };
    }
    const number: f64 = switch (value) {
        .bool => |b| return .{ .bool = !b },
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
    // spine-cpp before 4.2 skips negative scale mixes
    if (std.mem.startsWith(u8, key, "mixScale") or std.mem.eql(u8, key, "scaleMix")) return .{ .float = @abs(number) * random.float(f64) };
    const result: f64 = switch (random.uintLessThan(u8, 8)) {
        0 => 0,
        1 => 1,
        2 => -number,
        3 => number * 0.5,
        4 => number * 2,
        5 => number + 1,
        6 => number - 1,
        else => 0.25,
    };
    return .{ .float = if (result == 0 and zeroless.has(key)) 1 else result };
}

/// Loaders take any hash and read null as missing
fn loosen(a: std.mem.Allocator, random: std.Random, tree: *Value, log: *std.ArrayList(u8), hash: bool) !void {
    const version = sc.Version.ofRoot(tree.*) orelse return;
    const minor = @as(u32, version.major) * 100 + version.minor;
    if (hash) {
        const hashes = [_][]const u8{ "my rig", "caf\u{e9}", "x" };
        const value = hashes[random.uintLessThan(usize, hashes.len)];
        try tree.object.getPtr("skeleton").?.object.put(a, "hash", .{ .string = value });
        return log.print(a, "skeleton set hash {s}\n", .{value});
    }
    const lists = [_]Optional{
        .{ .key = "ik", .to = 402 },            .{ .key = "transform", .to = 402 },
        .{ .key = "path", .to = 402 },          .{ .key = "physics", .from = 402, .to = 402 },
        .{ .key = "constraints", .from = 403 }, .{ .key = "events" },
        .{ .key = "animations" },               .{ .key = "skins" },
        .{ .key = "slots" },
    };
    for (0..32) |_| {
        const list = lists[random.uintLessThan(usize, lists.len)];
        if (minor < list.from or minor > list.to or tree.object.contains(list.key)) continue;
        try tree.object.put(a, list.key, .null);
        return log.print(a, "{s} set null\n", .{list.key});
    }
    try vary(a, random, tree, log);
}

/// Beside each variant a text file holds its change
fn variants(a: std.mem.Allocator, io: Io, path: []const u8, directory: []const u8, count: usize) !u8 {
    const source = try Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    const body = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) source[3..] else source;
    try Io.Dir.cwd().createDirPath(io, directory);
    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0, std.fs.path.basename(path)) ^ source.len);
    const random = prng.random();
    for (0..count) |i| {
        var scratch: std.heap.ArenaAllocator = .init(a);
        defer scratch.deinit();
        const s = scratch.allocator();
        var tree = try std.json.parseFromSliceLeaky(Value, s, body, .{});
        var log: std.ArrayList(u8) = .empty;
        if (i + 2 >= count) try loosen(s, random, &tree, &log, i + 1 == count) else try vary(s, random, &tree, &log);
        const stem = try std.fmt.allocPrint(s, "{s}/{d:0>4}", .{ directory, i });
        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(s, "{s}.json", .{stem}),
            .data = try std.json.Stringify.valueAlloc(s, tree, .{}),
        });
        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(s, "{s}.txt", .{stem}),
            .data = log.items,
        });
    }
    return 0;
}

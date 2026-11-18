const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Version = @import("spine_converter").Version;

const usage =
    \\usage: pose-scope <skeleton 4.3.json> <report.tsv>
    \\       pose-scope editor <version>
    \\       pose-scope unsure <version>
    \\
;

/// Report lines are severity impact code path message as printed by the CLI
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err = &stderr_writer.interface;
    defer err.flush() catch {};

    if (args.len != 3) {
        try err.writeAll(usage);
        return 2;
    }
    if (std.mem.eql(u8, args[1], "editor")) return editor(out, err, args[2], .old);
    if (std.mem.eql(u8, args[1], "unsure")) return editor(out, err, args[2], .unsure);

    const data = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    const root = try std.json.parseFromSliceLeaky(Value, arena, data, .{});
    var s: Skeleton = try .init(arena, root);
    var groups: std.StringArrayHashMapUnmanaged(Seeds) = .empty;

    const report = try Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited);
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        var fields: [6][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |field| : (count += 1) {
            if (count < fields.len) fields[count] = field;
        }
        if (count != fields.len) continue;
        // control entry excusing only samples past the shorter end
        if (std.mem.eql(u8, fields[2], "animation.duration.approximated")) {
            if (!try s.shorter(arena, &groups, fields[3])) try err.print("pose-scope: unmapped {s} {s}\n", .{ fields[2], fields[3] });
            continue;
        }
        if (!std.mem.eql(u8, fields[1], "pose")) continue;
        if (!try s.seed(arena, &groups, fields[3])) try err.print("pose-scope: unmapped {s} {s}\n", .{ fields[2], fields[3] });
    }

    for (groups.keys(), groups.values()) |animation, *seeds| try s.write(arena, out, animation, seeds);
    return 0;
}

/// Prints the runtime changes the editor of a version predates or may predate
fn editor(out: *Io.Writer, err: *Io.Writer, text: []const u8, state: Version.Editor) !u8 {
    const v = Version.parse(text) orelse Version.unnumbered(text) orelse {
        try err.print("pose-scope: invalid version {s}\n", .{text});
        return 2;
    };
    for (std.enums.values(Version.Change)) |change| {
        if (Version.editor(v, change) == state) try out.print("{t}\n", .{change});
    }
    return 0;
}

const Seeds = struct {
    bones: std.ArrayList(usize) = .empty,
    slots: std.ArrayList(usize) = .empty,
    skin_slots: std.ArrayList(struct { slot: usize, skin: []const u8 }) = .empty,
    constraints: std.ArrayList(usize) = .empty,
    order: bool = false,
    all: bool = false,
    duration: bool = false,
};

const Constraint = struct {
    name: []const u8,
    kind: []const u8,
    bones: []const usize,
    /// Bones whose pose the constraint reads
    sources: []const usize,
    slot: ?usize,
    animation: ?[]const u8,
};

const Attachment = struct { slot: usize, name: []const u8, weights: []const usize, end: ?usize };

const Skeleton = struct {
    bones: []const []const u8,
    parents: []const ?usize,
    slots: []const []const u8,
    slot_bones: []const usize,
    skins: []const []const u8,
    constraints: []const Constraint,
    constraint_names: []const []const u8,
    attachments: []const Attachment,
    animations: std.json.ObjectMap,

    fn init(arena: std.mem.Allocator, root: Value) !Skeleton {
        var s: Skeleton = undefined;
        const bones = array(root, "bones");
        const names = try arena.alloc([]const u8, bones.len);
        const parents = try arena.alloc(?usize, bones.len);
        for (bones, names, parents) |bone, *name, *parent| {
            name.* = string(bone, "name").?;
            parent.* = null;
        }
        s.bones = names;
        for (bones, parents) |bone, *parent| {
            if (string(bone, "parent")) |p| parent.* = index(s.bones, p);
        }
        s.parents = parents;

        const slots = array(root, "slots");
        const slot_names = try arena.alloc([]const u8, slots.len);
        const slot_bones = try arena.alloc(usize, slots.len);
        for (slots, slot_names, slot_bones) |slot, *name, *bone| {
            name.* = string(slot, "name").?;
            bone.* = index(s.bones, string(slot, "bone").?) orelse 0;
        }
        s.slots = slot_names;
        s.slot_bones = slot_bones;

        var skins: std.ArrayList([]const u8) = .empty;
        var attachments: std.ArrayList(Attachment) = .empty;
        for (array(root, "skins")) |skin| {
            try skins.append(arena, string(skin, "name") orelse "default");
            const map = skin.object.get("attachments") orelse continue;
            for (map.object.keys(), map.object.values()) |slot_name, entries| {
                const slot = index(s.slots, slot_name) orelse continue;
                for (entries.object.keys(), entries.object.values()) |name, a| {
                    try attachments.append(arena, .{
                        .slot = slot,
                        .name = name,
                        .weights = try weights(arena, a),
                        .end = if (string(a, "end")) |end| index(s.slots, end) else null,
                    });
                }
            }
        }
        s.skins = skins.items;
        // linked meshes take the weights of their parent mesh
        for (array(root, "skins")) |skin| {
            const map = skin.object.get("attachments") orelse continue;
            for (map.object.keys(), map.object.values()) |slot_name, entries| {
                for (entries.object.keys(), entries.object.values()) |name, a| {
                    const parent = string(a, "parent") orelse continue;
                    for (attachments.items) |p| {
                        if (!std.mem.eql(u8, p.name, parent) or p.weights.len == 0) continue;
                        for (attachments.items) |*linked| {
                            if (std.mem.eql(u8, linked.name, name) and std.mem.eql(u8, s.slots[linked.slot], slot_name)) linked.weights = p.weights;
                        }
                        break;
                    }
                }
            }
        }
        s.attachments = attachments.items;

        var constraints: std.ArrayList(Constraint) = .empty;
        for (array(root, "constraints")) |c| {
            var list: std.ArrayList(usize) = .empty;
            for (array(c, "bones")) |b| if (index(s.bones, b.string)) |i| try list.append(arena, i);
            var sources: std.ArrayList(usize) = .empty;
            for ([_][]const u8{ "target", "source", "bone" }) |key| {
                if (string(c, key)) |b| if (index(s.bones, b)) |i| try sources.append(arena, i);
            }
            const kind = string(c, "type") orelse "";
            if (std.mem.eql(u8, kind, "physics")) try list.appendSlice(arena, sources.items);
            try constraints.append(arena, .{
                .name = string(c, "name").?,
                .kind = kind,
                .bones = list.items,
                .sources = sources.items,
                .slot = if (string(c, "slot")) |slot| index(s.slots, slot) else null,
                .animation = string(c, "animation"),
            });
        }
        s.constraints = constraints.items;
        const constraint_names = try arena.alloc([]const u8, constraints.items.len);
        for (constraints.items, constraint_names) |c, *name| name.* = c.name;
        s.constraint_names = constraint_names;
        s.animations = if (root.object.get("animations")) |a| a.object else .empty;
        return s;
    }

    /// Path heads mirror the report paths of src/migrate
    fn shorter(s: *Skeleton, arena: std.mem.Allocator, groups: *std.StringArrayHashMapUnmanaged(Seeds), path: []const u8) !bool {
        const head, const rest = split(path);
        if (!std.mem.eql(u8, head, "animations") or index(s.animations.keys(), rest) == null) return false;
        (try group(arena, groups, rest)).duration = true;
        return true;
    }

    fn seed(s: *Skeleton, arena: std.mem.Allocator, groups: *std.StringArrayHashMapUnmanaged(Seeds), path: []const u8) !bool {
        const head, const rest = split(path);
        if (std.mem.eql(u8, head, "skeleton")) {
            (try group(arena, groups, "*")).all = true;
            return true;
        }
        if (std.mem.eql(u8, head, "animations")) {
            const animation, const timeline = longest(s.animations.keys(), rest) orelse return false;
            const kind, const name = split(timeline);
            const g = try group(arena, groups, animation);
            if (std.mem.eql(u8, kind, "drawOrder") or std.mem.eql(u8, kind, "drawOrderFolder")) {
                g.order = true;
                return true;
            }
            if (std.mem.eql(u8, kind, "slider") and name.len == 0) {
                g.all = true;
                return true;
            }
            if (std.mem.eql(u8, kind, "physics") and name.len == 0) {
                for (s.constraints, 0..) |c, i| if (std.mem.eql(u8, c.kind, "physics")) try g.constraints.append(arena, i);
                return true;
            }
            if (std.mem.eql(u8, kind, "attachments") or std.mem.eql(u8, kind, "deform")) return s.skinSlot(arena, g, name);
            return s.item(arena, g, kind, name);
        }
        if (std.mem.eql(u8, head, "skins")) return s.skinSlot(arena, try group(arena, groups, "*"), rest);
        return s.item(arena, try group(arena, groups, "*"), head, rest);
    }

    fn item(s: *Skeleton, arena: std.mem.Allocator, g: *Seeds, kind: []const u8, rest: []const u8) !bool {
        if (std.mem.eql(u8, kind, "bones")) {
            const name, _ = longest(s.bones, rest) orelse return false;
            try g.bones.append(arena, index(s.bones, name).?);
        } else if (std.mem.eql(u8, kind, "slots")) {
            const name, _ = longest(s.slots, rest) orelse return false;
            try g.slots.append(arena, index(s.slots, name).?);
        } else for ([_][]const u8{ "ik", "transform", "path", "physics", "slider", "constraints" }) |head| {
            if (!std.mem.eql(u8, kind, head)) continue;
            const name, _ = longest(s.constraint_names, rest) orelse return false;
            try g.constraints.append(arena, index(s.constraint_names, name).?);
            return true;
        } else return false;
        return true;
    }

    fn skinSlot(s: *Skeleton, arena: std.mem.Allocator, g: *Seeds, rest: []const u8) !bool {
        const skin, const after = longest(s.skins, rest) orelse return false;
        const slot, _ = longest(s.slots, after) orelse return false;
        try g.skin_slots.append(arena, .{ .slot = index(s.slots, slot).?, .skin = skin });
        return true;
    }

    fn write(s: *Skeleton, arena: std.mem.Allocator, out: *Io.Writer, animation: []const u8, seeds: *Seeds) !void {
        if (seeds.duration) try out.print("duration\t{s}\n", .{animation});
        if (seeds.all) return out.print("all\t{s}\n", .{animation});
        if (seeds.order) try out.print("order\t{s}\n", .{animation});
        const bones = try arena.alloc(bool, s.bones.len);
        const slots = try arena.alloc(bool, s.slots.len);
        const constraints = try arena.alloc(bool, s.constraints.len);
        @memset(bones, false);
        @memset(slots, false);
        @memset(constraints, false);
        for (seeds.bones.items) |i| bones[i] = true;
        for (seeds.slots.items) |i| slots[i] = true;
        for (seeds.constraints.items) |i| constraints[i] = true;
        var changed = true;
        while (changed) {
            changed = false;
            for (s.constraints, constraints) |c, on| {
                if (!on) continue;
                for (c.bones) |i| changed = set(&bones[i]) or changed;
                const slider = c.animation orelse continue;
                changed = try s.keyed(slider, bones, slots, constraints) or changed;
            }
            // parents precede their children
            for (s.parents, 0..) |parent, i| {
                if (parent) |p| if (bones[p]) {
                    changed = set(&bones[i]) or changed;
                };
            }
            for (s.slot_bones, slots) |b, *on| {
                if (bones[b]) changed = set(on) or changed;
            }
            for (s.attachments) |a| {
                for (a.weights) |b| if (bones[b]) {
                    changed = set(&slots[a.slot]) or changed;
                };
            }
            for (s.attachments) |a| {
                const end = a.end orelse continue;
                if (!slots[a.slot]) continue;
                for (a.slot + 1..@min(end + 1, slots.len)) |i| changed = set(&slots[i]) or changed;
            }
            for (s.constraints, constraints) |c, *on| {
                if (on.*) continue;
                var reads = false;
                for (c.sources) |b| reads = reads or bones[b];
                if (c.slot) |slot| reads = reads or slots[slot] or bones[s.slot_bones[slot]];
                if (reads) changed = set(on) or changed;
            }
        }
        for (s.bones, bones) |name, on| if (on) try out.print("bone\t{s}\t{s}\n", .{ name, animation });
        for (s.slots, slots) |name, on| if (on) try out.print("slot\t{s}\t{s}\n", .{ name, animation });
        for (seeds.skin_slots.items) |x| {
            if (!slots[x.slot]) try out.print("slot\t{s}\t{s}\t{s}\n", .{ s.slots[x.slot], animation, x.skin });
        }
    }

    /// Marks what the animation of a slider keys
    fn keyed(s: *Skeleton, animation: []const u8, bones: []bool, slots: []bool, constraints: []bool) !bool {
        const timelines = s.animations.get(animation) orelse return false;
        var changed = false;
        for (timelines.object.keys(), timelines.object.values()) |kind, map| {
            if (map != .object) continue;
            if (std.mem.eql(u8, kind, "bones")) {
                for (map.object.keys()) |name| if (index(s.bones, name)) |i| {
                    changed = set(&bones[i]) or changed;
                };
            } else if (std.mem.eql(u8, kind, "slots")) {
                for (map.object.keys()) |name| if (index(s.slots, name)) |i| {
                    changed = set(&slots[i]) or changed;
                };
            } else if (std.mem.eql(u8, kind, "attachments")) {
                for (map.object.values()) |skin| for (skin.object.keys()) |name| if (index(s.slots, name)) |i| {
                    changed = set(&slots[i]) or changed;
                };
            } else {
                for (map.object.keys()) |name| for (s.constraints, constraints) |c, *on| {
                    if (std.mem.eql(u8, c.name, name)) changed = set(on) or changed;
                };
            }
        }
        return changed;
    }
};

fn set(flag: *bool) bool {
    defer flag.* = true;
    return !flag.*;
}

fn group(arena: std.mem.Allocator, groups: *std.StringArrayHashMapUnmanaged(Seeds), animation: []const u8) !*Seeds {
    const entry = try groups.getOrPutValue(arena, animation, .{});
    return entry.value_ptr;
}

fn split(path: []const u8) struct { []const u8, []const u8 } {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return .{ path, "" };
    return .{ path[0..dot], path[dot + 1 ..] };
}

/// Names may hold dots, so the longest name followed by a dot or the end wins
fn longest(names: []const []const u8, path: []const u8) ?struct { []const u8, []const u8 } {
    var best: ?[]const u8 = null;
    for (names) |name| {
        if (!std.mem.startsWith(u8, path, name)) continue;
        if (path.len != name.len and path[name.len] != '.') continue;
        if (best == null or name.len > best.?.len) best = name;
    }
    const name = best orelse return null;
    return .{ name, if (path.len > name.len) path[name.len + 1 ..] else "" };
}

fn index(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

fn array(v: Value, key: []const u8) []const Value {
    const a = v.object.get(key) orelse return &.{};
    return if (a == .array) a.array.items else &.{};
}

fn string(v: Value, key: []const u8) ?[]const u8 {
    const s = v.object.get(key) orelse return null;
    return if (s == .string) s.string else null;
}

/// Weighted vertices are bone count then bone, x, y, weight per bone
fn weights(arena: std.mem.Allocator, a: Value) ![]const usize {
    const vertices = array(a, "vertices");
    const uvs = array(a, "uvs");
    const count: usize = if (a.object.get("vertexCount")) |n| @intCast(n.integer) else uvs.len / 2;
    if (vertices.len <= count * 2) return &.{};
    var list: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (i < vertices.len) {
        const n: usize = @intFromFloat(number(vertices[i]));
        for (0..n) |k| try list.append(arena, @intFromFloat(number(vertices[i + 1 + k * 4])));
        i += 1 + n * 4;
    }
    return list.items;
}

fn number(v: Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

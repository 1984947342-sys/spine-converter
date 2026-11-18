const std = @import("std");
const Value = std.json.Value;

/// Zero tolerance compares f32 values exactly
pub const Tolerance = struct {
    relative: f32 = 0,
    absolute: f32 = 0,
    /// Applies inside arrays named vertices
    vertices: f32 = 0,
    /// A missing number equals zero or one within this distance
    missing: f32 = 0,
};

/// JSON exports keep seven significant digits and two decimals for setup vertices
pub const json_export: Tolerance = .{ .relative = 2e-6, .absolute = 1e-6, .vertices = 0.0051, .missing = 0.0051 };

/// Exports before 4.3 keep two decimals for every number
pub const legacy_export: Tolerance = .{ .relative = 2e-6, .absolute = 0.0051, .vertices = 0.0051, .missing = 0.0051 };

/// 3.5 exports truncate to two decimals
pub const truncated_export: Tolerance = .{ .relative = 2e-6, .absolute = 0.0101, .vertices = 0.0101, .missing = 0.0101 };

pub const Difference = struct {
    path: []const u8,
    expected: ?Value,
    actual: ?Value,
};

pub fn firstDifference(arena: std.mem.Allocator, expected: Value, actual: Value, tolerance: Tolerance) !?Difference {
    return diff(arena, "$", expected, actual, tolerance, false);
}

fn diff(arena: std.mem.Allocator, path: []const u8, e: Value, a: Value, t: Tolerance, in_vertices: bool) !?Difference {
    const different: Difference = .{ .path = path, .expected = e, .actual = a };
    if (number(e)) |x| {
        const y = number(a) orelse return different;
        const absolute = if (in_vertices) @max(t.absolute, t.vertices) else t.absolute;
        const limit = @max(absolute, t.relative * @max(@abs(x), @abs(y)));
        return if (x == y or @abs(x - y) <= limit) null else different;
    }
    if (std.meta.activeTag(e) != std.meta.activeTag(a)) return different;
    switch (e) {
        .null => return null,
        .bool => |b| return if (b == a.bool) null else different,
        .string => |s| return if (std.mem.eql(u8, s, a.string)) null else different,
        .array => |items| {
            if (items.items.len != a.array.items.len) return different;
            for (items.items, a.array.items, 0..) |x, y, i| {
                const child = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ path, i });
                if (try diff(arena, child, x, y, t, in_vertices)) |d| return d;
            }
            return null;
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const child = try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, key });
                const other = a.object.get(key) orelse {
                    if (nearDefault(entry.value_ptr.*, t)) continue;
                    return .{ .path = child, .expected = entry.value_ptr.*, .actual = null };
                };
                if (try diff(arena, child, entry.value_ptr.*, other, t, std.mem.eql(u8, key, "vertices"))) |d| return d;
            }
            var extra = a.object.iterator();
            while (extra.next()) |entry| {
                if (o.contains(entry.key_ptr.*) or nearDefault(entry.value_ptr.*, t)) continue;
                const child = try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, entry.key_ptr.* });
                return .{ .path = child, .expected = null, .actual = entry.value_ptr.* };
            }
            return null;
        },
        else => unreachable,
    }
}

fn nearDefault(v: Value, t: Tolerance) bool {
    const x = number(v) orelse return v == .null;
    return @abs(x) <= t.missing or @abs(x - 1) <= t.missing;
}

fn number(v: Value) ?f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        .number_string => |s| std.fmt.parseFloat(f32, s) catch null,
        else => null,
    };
}

/// Short JSON text of a difference side
pub fn preview(arena: std.mem.Allocator, v: ?Value) ![]const u8 {
    const value = v orelse return "missing";
    const text = try std.json.Stringify.valueAlloc(arena, value, .{});
    return if (text.len > 80) text[0..80] else text;
}

test "missing numbers near defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try std.json.parseFromSliceLeaky(Value, a, "{\"x\":0.001,\"v\":{\"vertices\":[1.004]}}", .{});
    const b = try std.json.parseFromSliceLeaky(Value, a, "{\"mix\":1,\"v\":{\"vertices\":[1]}}", .{});
    try std.testing.expectEqual(null, try firstDifference(a, e, b, json_export));
    try std.testing.expect(try firstDifference(a, e, b, .{}) != null);
}

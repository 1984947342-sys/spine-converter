//! Exports are pub so bindings/godot calls them in process
const std = @import("std");
const builtin = @import("builtin");
const sc = @import("spine_converter");

/// Values mirror spine_converter.h
pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    unknown_format = 2,
    unsupported_version = 3,
    malformed = 4,
    out_of_memory = 5,
    lossy_rejected = 6,
    _,
};

/// Values mirror SPC_FLAG_ in spine_converter.h
pub const flag_fail_on_loss = 1 << 0;
pub const flag_pretty_json = 1 << 1;
pub const flag_no_rewrite = 1 << 2;
const flags_known = flag_fail_on_loss | flag_pretty_json | flag_no_rewrite;

pub const DetectResult = extern struct {
    format: sc.Format,
    version: [32]u8,
    major: u16,
    minor: u16,
    patch: u16,
};

pub const Options = extern struct {
    struct_size: u32,
    target_version: ?[*:0]const u8,
    // any int may arrive from C
    target_format: c_int,
    flags: u32,
    atlas: ?[*]const u8,
    atlas_length: usize,
};

const CAllocator = extern struct {
    ctx: ?*anyopaque,
    alloc: *const fn (ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque,
    free: *const fn (ctx: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void,

    fn allocator(self: *const CAllocator) std.mem.Allocator {
        return .{ .ptr = @constCast(self), .vtable = &.{
            .alloc = vtableAlloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = vtableFree,
        } };
    }

    fn vtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *const CAllocator = @ptrCast(@alignCast(ctx));
        return @ptrCast(self.alloc(self.ctx, len, alignment.toByteUnits()));
    }

    fn vtableFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
        const self: *const CAllocator = @ptrCast(@alignCast(ctx));
        self.free(self.ctx, memory.ptr, memory.len, alignment.toByteUnits());
    }
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    /// Caller allocator ctx must outlive the result
    c_allocator: ?CAllocator,
    status: Status = .ok,
    data: ?[]const u8 = null,
    report: [:0]const u8 = "[]",
    loss_count: usize = 0,
    max_impact: sc.Report.Impact = .none,
    remedy_counts: [std.enums.values(sc.Report.Remedy).len]usize = @splat(0),
    err: [:0]const u8 = "",

    fn create(allocator: ?*const CAllocator) ?*Result {
        var c_allocator: ?CAllocator = if (allocator) |a| a.* else null;
        var arena: std.heap.ArenaAllocator = .init(if (c_allocator) |*a| a.allocator() else default_allocator);
        const result = arena.allocator().create(Result) catch {
            arena.deinit();
            return null;
        };
        result.* = .{ .arena = arena, .c_allocator = c_allocator };
        if (result.c_allocator) |*a| result.arena.child_allocator = a.allocator();
        return result;
    }

    fn destroy(result: *Result) void {
        // arena frees the memory holding its own allocator
        var c_allocator = result.c_allocator;
        var arena = result.arena;
        if (c_allocator) |*a| arena.child_allocator = a.allocator();
        arena.deinit();
    }
};

const default_allocator = if (builtin.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.page_allocator;

pub export fn spc_abi_version() u32 {
    return 1;
}

pub export fn spc_library_version() [*:0]const u8 {
    return sc.library_version;
}

pub export fn spc_status_string(status: Status) [*:0]const u8 {
    return switch (status) {
        .ok => "ok",
        .invalid_argument => "invalid argument",
        .unknown_format => "not Spine skeleton data",
        .unsupported_version => "unsupported Spine version",
        .malformed => "malformed skeleton data",
        .out_of_memory => "out of memory",
        .lossy_rejected => "conversion would lose data",
        _ => "unknown status",
    };
}

pub export fn spc_detect(data: ?[*]const u8, length: usize, out: ?*DetectResult) Status {
    const result = out orelse return .invalid_argument;
    const bytes = input(data, length) orelse return .invalid_argument;
    result.* = std.mem.zeroes(DetectResult);
    const detected = sc.detect(bytes) catch return .unknown_format;
    result.format = detected.format;
    if (detected.version) |v| {
        @memcpy(result.version[0..v.text().len], v.text());
        result.major = v.major;
        result.minor = v.minor;
        result.patch = v.patch;
    }
    return .ok;
}

pub export fn spc_convert(
    data: ?[*]const u8,
    length: usize,
    options: ?*const Options,
    allocator: ?*const CAllocator,
    out: ?*?*Result,
) Status {
    const result_out = out orelse return .invalid_argument;
    result_out.* = null;
    const bytes = input(data, length) orelse return .invalid_argument;
    const convert_options = convertOptions(options) orelse return .invalid_argument;

    const result = Result.create(allocator) orelse return .out_of_memory;
    result_out.* = result;
    const arena = result.arena.allocator();
    var report: sc.Report = .{ .arena = arena };

    const output = sc.convert.convert(arena, bytes, convert_options, &report);
    result.report = report.toJson() catch "[]";
    result.loss_count = report.lossCount();
    result.max_impact = report.maxImpact();
    for (std.enums.values(sc.Report.Remedy), &result.remedy_counts) |remedy, *count| count.* = report.remedyCount(remedy);
    if (output) |o| {
        result.data = o.data;
    } else |e| {
        result.status, result.err = switch (e) {
            error.UnknownFormat => .{ .unknown_format, "input is not Spine skeleton data" },
            error.UnsupportedVersion => .{ .unsupported_version, "source or target version is not supported" },
            error.Malformed => .{ .malformed, "skeleton data is corrupt or truncated" },
            error.OutOfMemory => .{ .out_of_memory, "out of memory" },
            error.LossyRejected => .{ .lossy_rejected, "conversion would lose data, see the report" },
            error.FormatMismatch => .{ .invalid_argument, "atlases only convert to atlases" },
        };
    }
    return result.status;
}

fn input(data: ?[*]const u8, length: usize) ?[]const u8 {
    if (data) |d| return d[0..length];
    return if (length == 0) &.{} else null;
}

fn convertOptions(options: ?*const Options) ?sc.convert.Options {
    const o = options orelse return .{};
    if (o.struct_size < @sizeOf(Options) or o.flags & ~@as(u32, flags_known) != 0) return null;
    const target_version = if (o.target_version) |v| sc.Version.parse(std.mem.span(v)) orelse return null else null;
    return .{
        .target_version = target_version,
        .target_format = std.enums.fromInt(sc.Format, o.target_format) orelse return null,
        .fail_on_loss = o.flags & flag_fail_on_loss != 0,
        .pretty_json = o.flags & flag_pretty_json != 0,
        .rewrite = o.flags & flag_no_rewrite == 0,
        .atlas = if (o.atlas != null or o.atlas_length != 0) input(o.atlas, o.atlas_length) orelse return null else null,
    };
}

pub export fn spc_result_status(result: ?*const Result) Status {
    return if (result) |r| r.status else .invalid_argument;
}

pub export fn spc_result_data(result: ?*const Result, length: ?*usize) ?[*]const u8 {
    const data = if (result) |r| r.data else null;
    if (length) |l| l.* = if (data) |d| d.len else 0;
    return if (data) |d| d.ptr else null;
}

pub export fn spc_result_report(result: ?*const Result, length: ?*usize) [*:0]const u8 {
    const report: [:0]const u8 = if (result) |r| r.report else "[]";
    if (length) |l| l.* = report.len;
    return report.ptr;
}

pub export fn spc_result_loss_count(result: ?*const Result) usize {
    return if (result) |r| r.loss_count else 0;
}

pub export fn spc_result_max_impact(result: ?*const Result) sc.Report.Impact {
    return if (result) |r| r.max_impact else .none;
}

pub export fn spc_result_remedy_count(result: ?*const Result, remedy: c_int) usize {
    const r = result orelse return 0;
    const known = std.enums.fromInt(sc.Report.Remedy, remedy) orelse return 0;
    return r.remedy_counts[@intCast(@backingInt(known))];
}

pub export fn spc_result_error(result: ?*const Result) [*:0]const u8 {
    return if (result) |r| r.err.ptr else "";
}

pub export fn spc_result_free(result: ?*Result) void {
    if (result) |r| r.destroy();
}

comptime {
    if (builtin.cpu.arch.isWasm()) {
        // bindings/js writes these offsets
        std.debug.assert(@sizeOf(Options) == 24 and @offsetOf(Options, "atlas_length") == 20);
        std.debug.assert(@sizeOf(DetectResult) == 44);
        @export(&wasmAlloc, .{ .name = "spc_wasm_alloc" });
        @export(&wasmFree, .{ .name = "spc_wasm_free" });
    }
}

/// Lets a WebAssembly host place input in linear memory
fn wasmAlloc(size: usize) callconv(.c) ?[*]u8 {
    return (default_allocator.alloc(u8, size) catch return null).ptr;
}

fn wasmFree(ptr: ?[*]u8, size: usize) callconv(.c) void {
    if (ptr) |p| default_allocator.free(p[0..size]);
}

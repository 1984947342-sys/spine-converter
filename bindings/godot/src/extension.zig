//! GDExtension that registers the SpineConverter class, static methods over the C ABI

const std = @import("std");
const abi = @import("abi");
const gd = @import("gdextension.zig");

var api: gd.Interface = undefined;
var library: ?gd.Ptr = null;

const Builtins = struct {
    dictionary_new: gd.PtrConstructor,
    array_new: gd.PtrConstructor,
    bytes_new: gd.PtrConstructor,
    string_free: gd.PtrDestructor,
    dictionary_free: gd.PtrDestructor,
    array_free: gd.PtrDestructor,
    bytes_free: gd.PtrDestructor,
    from_int: gd.VariantFromType,
    from_string: gd.VariantFromType,
    from_dictionary: gd.VariantFromType,
    from_array: gd.VariantFromType,
    from_bytes: gd.VariantFromType,
    to_int: gd.TypeFromVariant,
    to_string: gd.TypeFromVariant,
    to_dictionary: gd.TypeFromVariant,
    to_bytes: gd.TypeFromVariant,
    bytes_size: gd.PtrBuiltInMethod,
    bytes_resize: gd.PtrBuiltInMethod,
    array_resize: gd.PtrBuiltInMethod,
};
var builtins: Builtins = undefined;

const Kind = enum { bytes, string, int, dictionary };

const Arg = struct { name: [:0]const u8, kind: Kind, required: bool = false };

const Value = union(enum) { bytes: []const u8, string: []const u8, int: i64 };

const Method = struct {
    name: [:0]const u8,
    args: []const Arg,
    returns: Kind,
    run: *const fn (std.mem.Allocator, []const Value, *gd.Variant) void,
};

const methods = [_]Method{
    .{ .name = "convert", .returns = .dictionary, .run = convert, .args = &.{
        .{ .name = "data", .kind = .bytes, .required = true },
        .{ .name = "target_version", .kind = .string },
        .{ .name = "target_format", .kind = .int },
        .{ .name = "flags", .kind = .int },
        .{ .name = "atlas", .kind = .bytes },
    } },
    .{ .name = "detect", .returns = .dictionary, .run = detect, .args = &.{
        .{ .name = "data", .kind = .bytes, .required = true },
    } },
    .{ .name = "describe", .returns = .string, .run = describe, .args = &.{
        .{ .name = "status", .kind = .int, .required = true },
    } },
    .{ .name = "library_version", .returns = .string, .run = libraryVersion, .args = &.{} },
};
const max_args = 5;

const Constant = struct { group: [:0]const u8, name: [:0]const u8, value: i64, bitfield: bool = false };

/// Values mirror include/spine_converter.h
const constants = [_]Constant{
    .{ .group = "Status", .name = "STATUS_OK", .value = 0 },
    .{ .group = "Status", .name = "STATUS_INVALID_ARGUMENT", .value = 1 },
    .{ .group = "Status", .name = "STATUS_UNKNOWN_FORMAT", .value = 2 },
    .{ .group = "Status", .name = "STATUS_UNSUPPORTED_VERSION", .value = 3 },
    .{ .group = "Status", .name = "STATUS_MALFORMED", .value = 4 },
    .{ .group = "Status", .name = "STATUS_OUT_OF_MEMORY", .value = 5 },
    .{ .group = "Status", .name = "STATUS_LOSSY_REJECTED", .value = 6 },
    .{ .group = "Format", .name = "FORMAT_UNKNOWN", .value = 0 },
    .{ .group = "Format", .name = "FORMAT_JSON", .value = 1 },
    .{ .group = "Format", .name = "FORMAT_BINARY", .value = 2 },
    .{ .group = "Format", .name = "FORMAT_ATLAS", .value = 3 },
    .{ .group = "Impact", .name = "IMPACT_NONE", .value = 0 },
    .{ .group = "Impact", .name = "IMPACT_EDITOR", .value = 1 },
    .{ .group = "Impact", .name = "IMPACT_CONTROL", .value = 2 },
    .{ .group = "Impact", .name = "IMPACT_POSE", .value = 3 },
    .{ .group = "Impact", .name = "IMPACT_RENDER", .value = 4 },
    .{ .group = "Flags", .name = "FLAG_FAIL_ON_LOSS", .value = abi.flag_fail_on_loss, .bitfield = true },
    .{ .group = "Flags", .name = "FLAG_PRETTY_JSON", .value = abi.flag_pretty_json, .bitfield = true },
    .{ .group = "Flags", .name = "FLAG_NO_REWRITE", .value = abi.flag_no_rewrite, .bitfield = true },
};

/// Hashes from extension_api.json, unchanged since 4.0
const hash_size = 3173160232;
const hash_resize = 848867239;

pub export fn spine_converter_godot_init(get_proc: gd.GetProcAddress, lib: ?gd.Ptr, init: *gd.Initialization) callconv(.c) gd.Bool {
    inline for (@typeInfo(gd.Interface).@"struct".field_names) |field| {
        const proc = get_proc(field) orelse {
            if (get_proc("print_error_with_message")) |p| {
                const print: @FieldType(gd.Interface, "print_error_with_message") = @ptrCast(p);
                print("spine_converter needs Godot 4.3 or later", "missing " ++ field, "spine_converter_godot_init", @src().file, @src().line, 1);
            }
            return 0;
        };
        @field(api, field) = @ptrCast(proc);
    }
    library = lib;
    init.* = .{ .minimum_initialization_level = gd.initialization_scene, .userdata = null, .initialize = initialize, .deinitialize = deinitialize };
    return 1;
}

var class_name: gd.Opaque = .{};
var parent_name: gd.Opaque = .{};
var empty_name: gd.Opaque = .{};
var empty_string: gd.Opaque = .{};
var method_names: [methods.len]gd.Opaque = @splat(.{});
var arg_names: [methods.len][max_args]gd.Opaque = @splat(@splat(.{}));
var group_names: [constants.len]gd.Opaque = @splat(.{});
var constant_names: [constants.len]gd.Opaque = @splat(.{});
var defaults: [3]gd.Variant = @splat(.{});

fn name(storage: *gd.Opaque, text: [:0]const u8) *gd.Opaque {
    api.string_name_new_with_latin1_chars(storage, text.ptr, 1);
    return storage;
}

fn variantType(kind: Kind) u32 {
    return switch (kind) {
        .bytes => gd.Type.packed_byte_array,
        .string => gd.Type.string,
        .int => gd.Type.int,
        .dictionary => gd.Type.dictionary,
    };
}

fn initialize(_: ?*anyopaque, level: u32) callconv(.c) void {
    if (level != gd.initialization_scene) return;
    builtins = loadBuiltins() orelse {
        api.print_error_with_message("spine_converter could not load Godot builtins", "", "initialize", @src().file, @src().line, 1);
        return;
    };
    _ = api.string_new_with_utf8_chars_and_len2(&empty_string, "", 0);
    _ = name(&empty_name, "");

    var empty: gd.Opaque = .{};
    _ = api.string_new_with_utf8_chars_and_len2(&empty, "", 0);
    builtins.from_string(&defaults[0], &empty);
    builtins.string_free(&empty);
    var zero: i64 = 0;
    builtins.from_int(&defaults[1], &zero);
    var bytes: gd.PackedArray = .{};
    builtins.bytes_new(&bytes, null);
    builtins.from_bytes(&defaults[2], &bytes);
    builtins.bytes_free(&bytes);

    const info: gd.ClassCreationInfo3 = .{ .is_abstract = 1, .free_instance_func = freeInstance };
    api.classdb_register_extension_class3(library, name(&class_name, "SpineConverter"), name(&parent_name, "RefCounted"), &info);

    for (&methods, &method_names, &arg_names) |*method, *method_name, *names| {
        var infos: [max_args]gd.PropertyInfo = undefined;
        var metadata: [max_args]u32 = @splat(0);
        var method_defaults: [max_args]gd.Ptr = undefined;
        var default_count: u32 = 0;
        for (method.args, 0..) |arg, i| {
            infos[i] = .{ .type = variantType(arg.kind), .name = name(&names[i], arg.name), .class_name = &empty_name, .hint_string = &empty_string };
            if (!arg.required) {
                method_defaults[default_count] = switch (arg.kind) {
                    .string => &defaults[0],
                    .int => &defaults[1],
                    else => &defaults[2],
                };
                default_count += 1;
            }
        }
        const returns: gd.PropertyInfo = .{ .type = variantType(method.returns), .name = &empty_name, .class_name = &empty_name, .hint_string = &empty_string };
        api.classdb_register_extension_class_method(library, &class_name, &.{
            .name = name(method_name, method.name),
            .method_userdata = @constCast(method),
            .call_func = call,
            .ptrcall_func = ptrcall,
            .method_flags = gd.method_flag_normal | gd.method_flag_static,
            .has_return_value = 1,
            .return_value_info = &returns,
            .argument_count = @intCast(method.args.len),
            .arguments_info = &infos,
            .arguments_metadata = &metadata,
            .default_argument_count = default_count,
            .default_arguments = &method_defaults,
        });
    }
    for (&constants, &group_names, &constant_names) |c, *group, *constant| {
        api.classdb_register_extension_class_integer_constant(library, &class_name, name(group, c.group), name(constant, c.name), c.value, @intFromBool(c.bitfield));
    }
}

fn deinitialize(_: ?*anyopaque, level: u32) callconv(.c) void {
    if (level != gd.initialization_scene) return;
    api.classdb_unregister_extension_class(library, &class_name);
    for (&defaults) |*d| api.variant_destroy(d);
    builtins.string_free(&empty_string);
}

fn freeInstance(_: ?*anyopaque, _: ?gd.Ptr) callconv(.c) void {}

fn loadBuiltins() ?Builtins {
    var size_name: gd.Opaque = .{};
    var resize_name: gd.Opaque = .{};
    _ = name(&size_name, "size");
    _ = name(&resize_name, "resize");
    const t = gd.Type;
    return .{
        .dictionary_new = api.variant_get_ptr_constructor(t.dictionary, 0) orelse return null,
        .array_new = api.variant_get_ptr_constructor(t.array, 0) orelse return null,
        .bytes_new = api.variant_get_ptr_constructor(t.packed_byte_array, 0) orelse return null,
        .string_free = api.variant_get_ptr_destructor(t.string) orelse return null,
        .dictionary_free = api.variant_get_ptr_destructor(t.dictionary) orelse return null,
        .array_free = api.variant_get_ptr_destructor(t.array) orelse return null,
        .bytes_free = api.variant_get_ptr_destructor(t.packed_byte_array) orelse return null,
        .from_int = api.get_variant_from_type_constructor(t.int) orelse return null,
        .from_string = api.get_variant_from_type_constructor(t.string) orelse return null,
        .from_dictionary = api.get_variant_from_type_constructor(t.dictionary) orelse return null,
        .from_array = api.get_variant_from_type_constructor(t.array) orelse return null,
        .from_bytes = api.get_variant_from_type_constructor(t.packed_byte_array) orelse return null,
        .to_int = api.get_variant_to_type_constructor(t.int) orelse return null,
        .to_string = api.get_variant_to_type_constructor(t.string) orelse return null,
        .to_dictionary = api.get_variant_to_type_constructor(t.dictionary) orelse return null,
        .to_bytes = api.get_variant_to_type_constructor(t.packed_byte_array) orelse return null,
        .bytes_size = api.variant_get_ptr_builtin_method(t.packed_byte_array, &size_name, hash_size) orelse return null,
        .bytes_resize = api.variant_get_ptr_builtin_method(t.packed_byte_array, &resize_name, hash_resize) orelse return null,
        .array_resize = api.variant_get_ptr_builtin_method(t.array, &resize_name, hash_resize) orelse return null,
    };
}

/// Untyped calls, missing trailing arguments take their defaults
fn call(userdata: ?*anyopaque, _: ?gd.Ptr, args: [*]const gd.ConstPtr, count: gd.Int, ret: gd.Ptr, err: *gd.CallError) callconv(.c) void {
    const method: *const Method = @ptrCast(@alignCast(userdata.?));
    var required: usize = 0;
    for (method.args) |arg| required += @intFromBool(arg.required);
    err.* = .{ .@"error" = gd.CallErrorType.ok, .argument = 0, .expected = 0 };
    if (count > method.args.len) {
        err.* = .{ .@"error" = gd.CallErrorType.too_many_arguments, .argument = 0, .expected = @intCast(method.args.len) };
        return;
    }
    if (count < required) {
        err.* = .{ .@"error" = gd.CallErrorType.too_few_arguments, .argument = 0, .expected = @intCast(required) };
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var values: [max_args]Value = undefined;
    for (method.args, 0..) |arg, i| {
        if (i >= count) {
            values[i] = switch (arg.kind) {
                .string => .{ .string = "" },
                .int => .{ .int = 0 },
                else => .{ .bytes = &.{} },
            };
            continue;
        }
        const expected = variantType(arg.kind);
        if (api.variant_get_type(args[i]) != expected) {
            err.* = .{ .@"error" = gd.CallErrorType.invalid_argument, .argument = @intCast(i), .expected = @intCast(expected) };
            return;
        }
        const variant: gd.Ptr = @constCast(args[i]);
        values[i] = switch (arg.kind) {
            .dictionary => unreachable,
            .int => blk: {
                var number: i64 = 0;
                builtins.to_int(&number, variant);
                break :blk .{ .int = number };
            },
            .string => blk: {
                var text: gd.Opaque = .{};
                builtins.to_string(&text, variant);
                defer builtins.string_free(&text);
                break :blk .{ .string = utf8(arena.allocator(), &text) orelse return };
            },
            .bytes => blk: {
                var bytes: gd.PackedArray = .{};
                builtins.to_bytes(&bytes, variant);
                defer builtins.bytes_free(&bytes);
                break :blk .{ .bytes = arena.allocator().dupe(u8, byteSlice(&bytes)) catch return };
            },
        };
    }
    method.run(arena.allocator(), values[0..method.args.len], @ptrCast(@alignCast(ret)));
}

/// Typed calls pass every argument and an initialized return value
fn ptrcall(userdata: ?*anyopaque, _: ?gd.Ptr, args: [*]const gd.ConstPtr, ret: gd.Ptr) callconv(.c) void {
    const method: *const Method = @ptrCast(@alignCast(userdata.?));
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var values: [max_args]Value = undefined;
    for (method.args, 0..) |arg, i| {
        values[i] = switch (arg.kind) {
            .dictionary => unreachable,
            .int => .{ .int = @as(*const i64, @ptrCast(@alignCast(args[i]))).* },
            .string => .{ .string = utf8(arena.allocator(), args[i]) orelse return },
            .bytes => .{ .bytes = byteSlice(args[i]) },
        };
    }
    var result: gd.Variant = .{};
    method.run(arena.allocator(), values[0..method.args.len], &result);
    defer api.variant_destroy(&result);
    switch (method.returns) {
        .dictionary => {
            builtins.dictionary_free(ret);
            builtins.to_dictionary(ret, &result);
        },
        .string => {
            builtins.string_free(ret);
            builtins.to_string(ret, &result);
        },
        else => unreachable,
    }
}

fn utf8(allocator: std.mem.Allocator, godot_string: gd.ConstPtr) ?[]const u8 {
    const length: usize = @intCast(api.string_to_utf8_chars(godot_string, null, 0));
    const text = allocator.alloc(u8, length) catch return null;
    _ = api.string_to_utf8_chars(godot_string, text.ptr, @intCast(length));
    return text;
}

fn byteSlice(bytes: gd.ConstPtr) []const u8 {
    var size: i64 = 0;
    builtins.bytes_size(@constCast(bytes), null, &size, 0);
    if (size <= 0) return &.{};
    const data = api.packed_byte_array_operator_index_const(bytes, 0) orelse return &.{};
    return data[0..@intCast(size)];
}

fn ptrOrNull(bytes: []const u8) ?[*]const u8 {
    return if (bytes.len == 0) null else bytes.ptr;
}

const Dictionary = struct {
    storage: gd.Opaque = .{},

    fn init() Dictionary {
        var d: Dictionary = .{};
        builtins.dictionary_new(&d.storage, null);
        return d;
    }

    /// Takes ownership of value
    fn put(d: *Dictionary, key: []const u8, value: *gd.Variant) void {
        var key_variant = string(key);
        defer api.variant_destroy(&key_variant);
        const slot = api.dictionary_operator_index(&d.storage, &key_variant);
        api.variant_destroy(slot);
        move(@ptrCast(@alignCast(slot)), value);
    }

    fn putInt(d: *Dictionary, key: []const u8, value: i64) void {
        var v = int(value);
        d.put(key, &v);
    }

    fn putString(d: *Dictionary, key: []const u8, value: []const u8) void {
        var v = string(value);
        d.put(key, &v);
    }

    /// Moves the dictionary into out
    fn finish(d: *Dictionary, out: *gd.Variant) void {
        builtins.from_dictionary(out, &d.storage);
        builtins.dictionary_free(&d.storage);
    }
};

/// dst holds no value before
fn move(dst: *gd.Variant, src: *gd.Variant) void {
    api.variant_new_copy(dst, src);
    api.variant_destroy(src);
}

fn int(value: i64) gd.Variant {
    var v: gd.Variant = .{};
    var copy = value;
    builtins.from_int(&v, &copy);
    return v;
}

fn string(text: []const u8) gd.Variant {
    var s: gd.Opaque = .{};
    _ = api.string_new_with_utf8_chars_and_len2(&s, text.ptr, @intCast(text.len));
    defer builtins.string_free(&s);
    var v: gd.Variant = .{};
    builtins.from_string(&v, &s);
    return v;
}

fn bytesVariant(data: []const u8) gd.Variant {
    var bytes: gd.PackedArray = .{};
    builtins.bytes_new(&bytes, null);
    defer builtins.bytes_free(&bytes);
    if (data.len != 0) {
        const length: i64 = @intCast(data.len);
        var err: i64 = 0;
        builtins.bytes_resize(&bytes, &.{&length}, &err, 1);
        if (api.packed_byte_array_operator_index(&bytes, 0)) |p| @memcpy(p[0..data.len], data);
    }
    var v: gd.Variant = .{};
    builtins.from_bytes(&v, &bytes);
    return v;
}

const Entry = struct {
    code: []const u8,
    severity: []const u8,
    impact: []const u8,
    step: []const u8,
    path: []const u8,
    message: []const u8,
    remedy: []const u8,
};

fn reportVariant(allocator: std.mem.Allocator, json: []const u8) gd.Variant {
    const entries = std.json.parseFromSliceLeaky([]const Entry, allocator, json, .{}) catch &.{};
    var array: gd.Opaque = .{};
    builtins.array_new(&array, null);
    defer builtins.array_free(&array);
    const length: i64 = @intCast(entries.len);
    var err: i64 = 0;
    builtins.array_resize(&array, &.{&length}, &err, 1);
    for (entries, 0..) |entry, i| {
        var d: Dictionary = .init();
        inline for (@typeInfo(Entry).@"struct".field_names) |field| d.putString(field, @field(entry, field));
        const slot: *gd.Variant = @ptrCast(@alignCast(api.array_operator_index(&array, @intCast(i))));
        api.variant_destroy(slot);
        d.finish(slot);
    }
    var v: gd.Variant = .{};
    builtins.from_array(&v, &array);
    return v;
}

fn convert(allocator: std.mem.Allocator, values: []const Value, out: *gd.Variant) void {
    const data = values[0].bytes;
    const atlas = values[4].bytes;
    const version: ?[*:0]const u8 = if (values[1].string.len == 0) null else (allocator.dupeSentinel(u8, values[1].string, 0) catch return).ptr;
    const options: abi.Options = .{
        .struct_size = @sizeOf(abi.Options),
        .target_version = version,
        .target_format = std.math.cast(c_int, values[2].int) orelse -1,
        .flags = std.math.cast(u32, values[3].int) orelse std.math.maxInt(u32),
        .atlas = ptrOrNull(atlas),
        .atlas_length = atlas.len,
    };
    var result: ?*abi.Result = null;
    const status = abi.spc_convert(ptrOrNull(data), data.len, &options, null, &result);
    defer abi.spc_result_free(result);

    var d: Dictionary = .init();
    d.putInt("status", @backingInt(status));
    const message = if (status == .ok) "" else if (result != null) abi.spc_result_error(result) else abi.spc_status_string(status);
    d.putString("error", std.mem.span(message));
    var length: usize = 0;
    const output = abi.spc_result_data(result, &length);
    var output_variant = bytesVariant(if (output) |o| o[0..length] else &.{});
    d.put("data", &output_variant);
    var report_length: usize = 0;
    const report = abi.spc_result_report(result, &report_length);
    var report_variant = reportVariant(allocator, report[0..report_length]);
    d.put("report", &report_variant);
    d.putInt("loss_count", @intCast(abi.spc_result_loss_count(result)));
    d.putInt("max_impact", @backingInt(abi.spc_result_max_impact(result)));
    d.finish(out);
}

fn detect(_: std.mem.Allocator, values: []const Value, out: *gd.Variant) void {
    const data = values[0].bytes;
    var result = std.mem.zeroes(abi.DetectResult);
    const status = abi.spc_detect(ptrOrNull(data), data.len, &result);
    var d: Dictionary = .init();
    d.putInt("status", @backingInt(status));
    d.putInt("format", @backingInt(result.format));
    d.putString("version", std.mem.sliceTo(&result.version, 0));
    d.putInt("major", result.major);
    d.putInt("minor", result.minor);
    d.putInt("patch", result.patch);
    d.finish(out);
}

fn describe(_: std.mem.Allocator, values: []const Value, out: *gd.Variant) void {
    const status: abi.Status = @fromBackingInt(std.math.cast(c_int, values[0].int) orelse -1);
    var v = string(std.mem.span(abi.spc_status_string(status)));
    move(out, &v);
}

fn libraryVersion(_: std.mem.Allocator, _: []const Value, out: *gd.Variant) void {
    var v = string(std.mem.span(abi.spc_library_version()));
    move(out, &v);
}

//! Part of the Godot GDExtension interface, declared from gdextension_interface.h of Godot 4.3 and later

pub const Ptr = *anyopaque;
pub const ConstPtr = *const anyopaque;
pub const Bool = u8;
pub const Int = i64;

/// GDExtensionVariantType values used here
pub const Type = struct {
    pub const nil: u32 = 0;
    pub const int: u32 = 2;
    pub const string: u32 = 4;
    pub const dictionary: u32 = 27;
    pub const array: u32 = 28;
    pub const packed_byte_array: u32 = 29;
};

pub const CallErrorType = struct {
    pub const ok: u32 = 0;
    pub const invalid_argument: u32 = 2;
    pub const too_many_arguments: u32 = 3;
    pub const too_few_arguments: u32 = 4;
};

pub const CallError = extern struct {
    @"error": u32,
    argument: i32,
    expected: i32,
};

pub const PropertyInfo = extern struct {
    type: u32,
    name: ConstPtr,
    class_name: ConstPtr,
    hint: u32 = 0,
    hint_string: ConstPtr,
    usage: u32 = 6,
};

pub const method_flag_normal: u32 = 1;
pub const method_flag_static: u32 = 32;

pub const MethodCall = *const fn (?*anyopaque, ?Ptr, [*]const ConstPtr, Int, Ptr, *CallError) callconv(.c) void;
pub const MethodPtrCall = *const fn (?*anyopaque, ?Ptr, [*]const ConstPtr, Ptr) callconv(.c) void;

pub const MethodInfo = extern struct {
    name: ConstPtr,
    method_userdata: ?*anyopaque,
    call_func: MethodCall,
    ptrcall_func: MethodPtrCall,
    method_flags: u32,
    has_return_value: Bool,
    return_value_info: ?*const PropertyInfo,
    return_value_metadata: u32 = 0,
    argument_count: u32,
    arguments_info: ?[*]const PropertyInfo,
    arguments_metadata: ?[*]const u32,
    default_argument_count: u32,
    default_arguments: ?[*]const Ptr,
};

pub const FreeInstance = *const fn (?*anyopaque, ?Ptr) callconv(.c) void;

/// GDExtensionClassCreationInfo3, members after free_instance_func stay null
pub const ClassCreationInfo3 = extern struct {
    is_virtual: Bool = 0,
    is_abstract: Bool = 0,
    is_exposed: Bool = 1,
    is_runtime: Bool = 0,
    set_func: ?*const anyopaque = null,
    get_func: ?*const anyopaque = null,
    get_property_list_func: ?*const anyopaque = null,
    free_property_list_func: ?*const anyopaque = null,
    property_can_revert_func: ?*const anyopaque = null,
    property_get_revert_func: ?*const anyopaque = null,
    validate_property_func: ?*const anyopaque = null,
    notification_func: ?*const anyopaque = null,
    to_string_func: ?*const anyopaque = null,
    reference_func: ?*const anyopaque = null,
    unreference_func: ?*const anyopaque = null,
    create_instance_func: ?*const anyopaque = null,
    free_instance_func: FreeInstance,
    recreate_instance_func: ?*const anyopaque = null,
    get_virtual_func: ?*const anyopaque = null,
    get_virtual_call_data_func: ?*const anyopaque = null,
    call_virtual_with_data_func: ?*const anyopaque = null,
    get_rid_func: ?*const anyopaque = null,
    class_userdata: ?*anyopaque = null,
};

pub const initialization_scene: u32 = 2;

pub const Initialization = extern struct {
    minimum_initialization_level: u32,
    userdata: ?*anyopaque,
    initialize: *const fn (?*anyopaque, u32) callconv(.c) void,
    deinitialize: *const fn (?*anyopaque, u32) callconv(.c) void,
};

pub const GetProcAddress = *const fn ([*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void;

pub const PtrConstructor = *const fn (Ptr, ?[*]const ConstPtr) callconv(.c) void;
pub const PtrDestructor = *const fn (Ptr) callconv(.c) void;
pub const PtrBuiltInMethod = *const fn (Ptr, ?[*]const ConstPtr, ?Ptr, i32) callconv(.c) void;
pub const VariantFromType = *const fn (Ptr, Ptr) callconv(.c) void;
pub const TypeFromVariant = *const fn (Ptr, Ptr) callconv(.c) void;

/// Field names are the names get_proc_address resolves, all since 4.1 except where noted
pub const Interface = struct {
    print_error_with_message: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, i32, Bool) callconv(.c) void,
    /// since 4.3
    classdb_register_extension_class3: *const fn (?Ptr, ConstPtr, ConstPtr, *const ClassCreationInfo3) callconv(.c) void,
    classdb_register_extension_class_method: *const fn (?Ptr, ConstPtr, *const MethodInfo) callconv(.c) void,
    classdb_register_extension_class_integer_constant: *const fn (?Ptr, ConstPtr, ConstPtr, ConstPtr, Int, Bool) callconv(.c) void,
    classdb_unregister_extension_class: *const fn (?Ptr, ConstPtr) callconv(.c) void,
    /// since 4.2
    string_name_new_with_latin1_chars: *const fn (Ptr, [*:0]const u8, Bool) callconv(.c) void,
    /// since 4.3
    string_new_with_utf8_chars_and_len2: *const fn (Ptr, [*]const u8, Int) callconv(.c) Int,
    string_to_utf8_chars: *const fn (ConstPtr, ?[*]u8, Int) callconv(.c) Int,
    variant_get_ptr_constructor: *const fn (u32, i32) callconv(.c) ?PtrConstructor,
    variant_get_ptr_destructor: *const fn (u32) callconv(.c) ?PtrDestructor,
    variant_get_ptr_builtin_method: *const fn (u32, ConstPtr, Int) callconv(.c) ?PtrBuiltInMethod,
    get_variant_from_type_constructor: *const fn (u32) callconv(.c) ?VariantFromType,
    get_variant_to_type_constructor: *const fn (u32) callconv(.c) ?TypeFromVariant,
    variant_new_copy: *const fn (Ptr, ConstPtr) callconv(.c) void,
    variant_destroy: *const fn (Ptr) callconv(.c) void,
    variant_get_type: *const fn (ConstPtr) callconv(.c) u32,
    packed_byte_array_operator_index: *const fn (Ptr, Int) callconv(.c) ?[*]u8,
    packed_byte_array_operator_index_const: *const fn (ConstPtr, Int) callconv(.c) ?[*]const u8,
    dictionary_operator_index: *const fn (Ptr, ConstPtr) callconv(.c) Ptr,
    array_operator_index: *const fn (Ptr, Int) callconv(.c) Ptr,
};

/// Storage of builtin types, sizes from builtin_class_sizes of extension_api.json for single precision builds
pub const Variant = extern struct { bytes: [24]u8 align(8) = undefined };
pub const Opaque = extern struct { bytes: [@sizeOf(usize)]u8 align(8) = undefined };
pub const PackedArray = extern struct { bytes: [2 * @sizeOf(usize)]u8 align(8) = undefined };

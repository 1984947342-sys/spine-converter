[English](stability.md) | [中文](stability.zh-CN.md)

# Stability

Releases follow [semantic versioning](https://semver.org). The library reports its version as `1.2.3+commit`, packages carry `1.2.3`.

| Interface | Within one major version |
|---|---|
| C functions, structs, enum values and `SPC_FLAG_` bits of `include/spine_converter.h` | never change or go, new ones may come |
| `spc_options` | new fields only at the end, `struct_size` tells them apart |
| `SPC_ABI_VERSION` | changes only with the major version |
| report JSON fields | never change or go, new ones may come |
| report codes, their severity and impact | never renamed or removed, new codes may come, callers should accept codes they do not know |
| report messages | may change in any release |
| CLI commands, flags and exit status | never change or go, new ones may come |
| bindings for C++, C#, JavaScript, Python, Unity and Godot | follow the C ABI rules |
| Zig module | may change in a minor release, it follows Zig |
| converted output | may change in a minor release when a case becomes exact or is reported more precisely |

A patch release fixes bugs only. A minor release may add rewrites, codes, functions and flags.

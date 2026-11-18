[English](README.md) | [中文](README.zh-CN.md)

# Zig module

The package exports the module `spine_converter`, the converter itself without the C ABI. It needs Zig 0.17.

```
zig fetch --save=spine_converter <release source archive URL>
```

```zig
const dep = b.dependency("spine_converter", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("spine_converter", dep.module("spine_converter"));
```

```zig
const sc = @import("spine_converter");

var report: sc.Report = .{ .arena = arena };
const output = try sc.convert.convert(arena, data, .{ .target_version = sc.Version.parse("4.3").? }, &report);
std.debug.print("{d} bytes, {d} losses\n", .{ output.data.len, report.lossCount() });
```

| Member | Use |
|---|---|
| `sc.detect(data)` | format and version |
| `sc.convert.convert(arena, data, options, &report)` | output format and bytes, all memory from the arena |
| `sc.convert.Options` | target version and format, `fail_on_loss`, `rewrite`, `pretty_json`, `atlas` |
| `sc.Report` | entries, `lossCount`, `maxImpact`, `remedyCount`, `toJson` |
| `sc.library_version` | version text |

The module follows Zig releases and may change in a minor release, the C ABI is the stable interface, see [docs/stability.md](../../docs/stability.md).

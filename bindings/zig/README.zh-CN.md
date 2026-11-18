[English](README.md) | [中文](README.zh-CN.md)

# Zig 模块

本包导出模块 `spine_converter`，即不经过 C ABI 的转换器本身。需要 Zig 0.17。

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

| 成员 | 用途 |
|---|---|
| `sc.detect(data)` | 格式与版本 |
| `sc.convert.convert(arena, data, options, &report)` | 输出格式和字节，所有内存来自 arena |
| `sc.convert.Options` | 目标版本与格式、`fail_on_loss`、`rewrite`、`pretty_json`、`atlas` |
| `sc.Report` | 条目、`lossCount`、`maxImpact`、`remedyCount`、`toJson` |
| `sc.library_version` | 版本文本 |

该模块跟随 Zig 版本，次版本可能变化。稳定接口是 C ABI，见 [docs/stability.zh-CN.md](../../docs/stability.zh-CN.md)。

[English](stability.md) | [中文](stability.zh-CN.md)

# 稳定性

版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。库报告的版本形如 `1.2.3+commit`，软件包使用 `1.2.3`。

| 接口 | 同一主版本内 |
|---|---|
| `include/spine_converter.h` 中的 C 函数、结构体、枚举值和 `SPC_FLAG_` 位 | 不修改、不删除，可新增 |
| `spc_options` | 新字段只加在末尾，由 `struct_size` 区分 |
| `SPC_ABI_VERSION` | 只随主版本变化 |
| 报告 JSON 字段 | 不修改、不删除，可新增 |
| 报告代码及其严重程度和影响 | 不改名、不删除，可新增，调用方应接受未知代码 |
| 报告消息文本 | 任何版本都可能变化 |
| 命令行命令、参数和退出码 | 不修改、不删除，可新增 |
| C++、C#、JavaScript、Python、Unity 和 Godot 绑定 | 遵循 C ABI 的规则 |
| Zig 模块 | 次版本可能变化，跟随 Zig 版本 |
| 转换结果 | 次版本可能变化，例如某种情况变为精确改写，或报告更准确 |

修订版本只修复缺陷。次版本可以新增改写、代码、函数和参数。

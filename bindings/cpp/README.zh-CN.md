[English](README.md) | [中文](README.zh-CN.md)

# C++ 绑定

[spine_converter.hpp](spine_converter.hpp) 是 [C 库](../c/README.zh-CN.md) 的纯头文件 C++17 封装，失败时抛出异常，通过 RAII 释放结果。发布压缩包将其放在 `include/` 中，与 `spine_converter.h` 并列，链接方式与 C 相同。

## 用法

```cpp
#include <spine_converter.hpp>

namespace sc = spine_converter;

sc::Options options;
options.target_version = "4.3";
options.target_format = SPC_FORMAT_BINARY;
try {
    sc::Result result = sc::convert(data.data(), data.size(), options);
    std::vector<uint8_t> skel(result.data(), result.data() + result.size());
    std::string_view report = result.report();
} catch (const sc::Error &e) {
    std::cerr << e.what() << " " << e.status() << "\n";
}
```

| 成员 | 用途 |
|---|---|
| `detect(data, size)` | 含格式和版本的 `Detection`，数据不是 Spine 数据时为 `SPC_FORMAT_UNKNOWN` |
| `convert(data, size, options)` | `Result`，失败时抛出 `Error`，包括 `SPC_ERR_LOSSY_REJECTED` |
| `Options` | `target_version`、`target_format`、由 `SPC_FLAG_` 位组成的 `flags`、`atlas` |
| `Result` | `data()`、`size()`、`report()`、`loss_count()`、`max_impact()`、`remedy_count(remedy)` |
| `Error` | 带 `status()` 的 `std::runtime_error` |
| `abi_version()` `library_version()` | 所链接库的版本 |

`target_version` 为空且 `target_format` 为 `SPC_FORMAT_UNKNOWN` 时，保持源版本和格式。3.5 或 3.6 骨骼的图集文本可保留被裁剪区域的网格 UV。`report()` 是 [docs/report.zh-CN.md](../../docs/report.zh-CN.md) 所述的 JSON 数组。`Result` 拥有其输出，返回的视图在其生命周期内有效。

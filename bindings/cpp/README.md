[English](README.md) | [中文](README.zh-CN.md)

# C++ binding

[spine_converter.hpp](spine_converter.hpp) is a header-only C++17 wrapper of the [C library](../c/README.md). It throws on failure and frees results through RAII. Release archives carry it in `include/` beside `spine_converter.h`, linking is the same as for C.

## Usage

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

| Member | Use |
|---|---|
| `detect(data, size)` | `Detection` with format and version, `SPC_FORMAT_UNKNOWN` when the data is not Spine data |
| `convert(data, size, options)` | `Result`, throws `Error` on failure, `SPC_ERR_LOSSY_REJECTED` included |
| `Options` | `target_version`, `target_format`, `flags` of `SPC_FLAG_` bits, `atlas` |
| `Result` | `data()`, `size()`, `report()`, `loss_count()`, `max_impact()`, `remedy_count(remedy)` |
| `Error` | `std::runtime_error` with `status()` |
| `abi_version()` `library_version()` | versions of the linked library |

An empty `target_version` and `SPC_FORMAT_UNKNOWN` keep the source version and format. The atlas text of a 3.5 or 3.6 skeleton keeps mesh UVs of stripped regions. `report()` is the JSON array of [docs/report.md](../../docs/report.md). A `Result` owns its output, the views it returns stay valid while it lives.

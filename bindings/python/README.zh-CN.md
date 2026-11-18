[English](README.md) | [中文](README.zh-CN.md)

# Python 绑定

`spine-converter` 用 `ctypes` 绑定 C ABI。每个 wheel 带有对应平台的原生库，无依赖。需要 Python 3.10 及以上。

```
pip install spine-converter
```

```python
import spine_converter as sc

result = sc.convert(data, "4.3", sc.Format.BINARY)
print(result.loss_count, result.report)
```

| 成员 | 用途 |
|---|---|
| `detect(data)` | 格式与版本，非 Spine 数据时为 `Format.UNKNOWN` |
| `convert(data, target_version, target_format, flags, atlas)` | 返回 `Conversion`，包含输出字节、报告、损失数和最高影响，`atlas` 同 `--atlas` |
| `Flags` | `FAIL_ON_LOSS`、`PRETTY_JSON` 和 `NO_REWRITE`，对应 `SPC_FLAG_` 位 |
| `abi_version()` `library_version()` | 已加载库的版本，ABI 不匹配时导入失败 |
| `describe(status)` | 状态的文字说明 |
| `ConverterError` | 所有失败都抛出，`status` 为 C ABI 状态 |

目标版本为 `None` 且格式为 `Format.UNKNOWN` 时保留源版本和格式。报告条目见 [docs/report.zh-CN.md](../../docs/report.zh-CN.md)。

`SPINE_CONVERTER_LIBRARY` 可指定另一个要加载的库文件。测试使用 `zig build dist` 生成的库。

```
zig build dist
SPINE_CONVERTER_LIBRARY=zig-out/dist/linux-x64/libspine_converter.so PYTHONPATH=bindings/python/src python -m unittest discover -s bindings/python/tests
```

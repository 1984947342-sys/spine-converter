[English](https://github.com/MindsMaster/spine-converter/blob/main/bindings/python/README.md) | [中文](https://github.com/MindsMaster/spine-converter/blob/main/bindings/python/README.zh-CN.md)

# Python binding

`spine-converter` binds the C ABI with `ctypes`. Each wheel carries the native library of its platform and has no dependencies. Python 3.10 and later.

```
pip install spine-converter
```

```python
import spine_converter as sc

result = sc.convert(data, "4.3", sc.Format.BINARY)
print(result.loss_count, result.report)
```

| Member | Use |
|---|---|
| `detect(data)` | format and version, `Format.UNKNOWN` for data that is not Spine data |
| `convert(data, target_version, target_format, flags, atlas)` | a `Conversion` with the output bytes, the report, its loss count and most severe impact, `atlas` as `--atlas` |
| `Flags` | `FAIL_ON_LOSS`, `PRETTY_JSON` and `NO_REWRITE`, matching the `SPC_FLAG_` bits |
| `abi_version()` `library_version()` | versions of the loaded library, a mismatched ABI fails at import |
| `describe(status)` | text of a status |
| `ConverterError` | raised on every failure, `status` holds the C ABI status |

A `None` target version and `Format.UNKNOWN` keep the source version and format. Report entries follow [docs/report.md](https://github.com/MindsMaster/spine-converter/blob/main/docs/report.md).

`SPINE_CONVERTER_LIBRARY` names another library file to load. Tests run against the library of `zig build dist`.

```
zig build dist
SPINE_CONVERTER_LIBRARY=zig-out/dist/linux-x64/libspine_converter.so PYTHONPATH=bindings/python/src python -m unittest discover -s bindings/python/tests
```

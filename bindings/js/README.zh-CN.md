[English](README.md) | [中文](README.zh-CN.md)

# JavaScript 与 TypeScript 绑定

`spine-converter` 以 WebAssembly 形式在浏览器和 Node 18 及以上版本中运行转换器。包含类型声明，无依赖。

```
npm install spine-converter
```

```js
import { Converter } from "spine-converter";

const converter = await Converter.load();
const result = converter.convert(bytes, { targetVersion: "4.3", targetFormat: "binary" });
console.log(result.lossCount, result.report);
```

| 成员 | 用途 |
|---|---|
| `Converter.load(source)` | 实例化模块，默认加载包入口旁的 `spine_converter.wasm`，也可传入 URL、字节、`Response` 或已编译的 `WebAssembly.Module` |
| `converter.detect(data)` | 格式与版本，非 Spine 数据时格式为 `unknown` |
| `converter.convert(data, options)` | 输出字节、报告、损失数和最高影响 |
| `ConvertOptions` | `targetVersion`、`targetFormat`、`failOnLoss`、`prettyJson`、`noRewrite`，`atlas` 同 `--atlas` |
| `converter.abiVersion` `converter.libraryVersion` | 已加载模块的版本，ABI 不匹配时抛出异常 |
| `ConverterError` | 所有失败都抛出，`status` 为 C ABI 状态名 |

未指定目标版本或格式时保留源版本和格式。报告条目见 [docs/report.zh-CN.md](../../docs/report.zh-CN.md)。

支持 `new URL("./file", import.meta.url)` 的打包工具，如 Vite 和 webpack 5，会自行处理该模块。其他情况可把 `spine-converter/spine_converter.wasm` 的 URL 或字节传给 `load`。

```
zig build wasm
pnpm install
pnpm run build
pnpm test
```

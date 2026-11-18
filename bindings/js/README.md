[English](https://github.com/MindsMaster/spine-converter/blob/main/bindings/js/README.md) | [中文](https://github.com/MindsMaster/spine-converter/blob/main/bindings/js/README.zh-CN.md)

# JavaScript and TypeScript binding

`spine-converter` runs the converter as WebAssembly in browsers and Node 18 or later. It includes type declarations and has no dependencies.

```
npm install spine-converter
```

```js
import { Converter } from "spine-converter";

const converter = await Converter.load();
const result = converter.convert(bytes, { targetVersion: "4.3", targetFormat: "binary" });
console.log(result.lossCount, result.report);
```

| Member | Use |
|---|---|
| `Converter.load(source)` | instantiates the module, by default `spine_converter.wasm` beside the package entry, or a URL, bytes, a `Response` or a compiled `WebAssembly.Module` |
| `converter.detect(data)` | format and version, format `unknown` for data that is not Spine data |
| `converter.convert(data, options)` | output bytes, the report, its loss count and most severe impact |
| `ConvertOptions` | `targetVersion`, `targetFormat`, `failOnLoss`, `prettyJson`, `noRewrite`, `atlas` as `--atlas` |
| `converter.abiVersion` `converter.libraryVersion` | versions of the loaded module, a mismatched ABI throws |
| `ConverterError` | thrown on every failure, `status` names the C ABI status |

An absent target version or format keeps the source version and format. Report entries follow [docs/report.md](https://github.com/MindsMaster/spine-converter/blob/main/docs/report.md).

Bundlers that understand `new URL("./file", import.meta.url)`, such as Vite and webpack 5, copy the module on their own. Others can pass the URL or bytes of `spine-converter/spine_converter.wasm` to `load`.

```
zig build wasm
pnpm install
pnpm run build
pnpm test
```

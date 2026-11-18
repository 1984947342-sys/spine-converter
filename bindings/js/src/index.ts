/*
 * spine-converter, unofficial converter for Spine skeleton data
 * Spine is a trademark of Esoteric Software
 * Users must hold their own Spine Editor license, see LICENSE
 */

export type Format = "unknown" | "json" | "binary" | "atlas";
export type Impact = "none" | "editor" | "control" | "pose" | "render";
export type Remedy = "none" | "rewrite" | "runtime";
export type Status =
    | "ok"
    | "invalidArgument"
    | "unknownFormat"
    | "unsupportedVersion"
    | "malformed"
    | "outOfMemory"
    | "lossyRejected";

/** Index mirrors spc_status */
const statuses: readonly Status[] = [
    "ok",
    "invalidArgument",
    "unknownFormat",
    "unsupportedVersion",
    "malformed",
    "outOfMemory",
    "lossyRejected",
];
/** Index mirrors spc_format */
const formats: readonly Format[] = ["unknown", "json", "binary", "atlas"];
/** Index mirrors spc_impact */
const impacts: readonly Impact[] = ["none", "editor", "control", "pose", "render"];

const abi = 1;
const flagFailOnLoss = 1 << 0;
const flagPrettyJson = 1 << 1;
const flagNoRewrite = 1 << 2;

export interface Detection {
    format: Format;
    /** Empty when the data carries no version */
    version: string;
    major: number;
    minor: number;
    patch: number;
}

/** Fields of one docs/report.md entry */
export interface ReportEntry {
    code: string;
    severity: "dropped" | "approximated" | "rewritten";
    impact: Impact;
    step: string;
    path: string;
    message: string;
    remedy: Remedy;
}

export interface ConvertOptions {
    /** Such as "4.3" or "3.8.99", absent keeps the source version */
    targetVersion?: string;
    /** Absent keeps the source format, atlases only convert to atlases */
    targetFormat?: Format;
    failOnLoss?: boolean;
    prettyJson?: boolean;
    noRewrite?: boolean;
    /** Atlas text of a 3.5 or 3.6 skeleton, keeps mesh UVs of stripped regions */
    atlas?: Uint8Array | string;
}

export interface Conversion {
    data: Uint8Array;
    reportJson: string;
    report: ReportEntry[];
    /** Entries that are not rewritten */
    lossCount: number;
    maxImpact: Impact;
}

export class ConverterError extends Error {
    readonly status: Status;

    constructor(status: Status, message: string) {
        super(message);
        this.name = "ConverterError";
        this.status = status;
    }
}

interface Exports {
    memory: WebAssembly.Memory;
    spc_abi_version(): number;
    spc_library_version(): number;
    spc_status_string(status: number): number;
    spc_detect(data: number, length: number, out: number): number;
    spc_convert(data: number, length: number, options: number, allocator: number, out: number): number;
    spc_result_data(result: number, length: number): number;
    spc_result_report(result: number, length: number): number;
    spc_result_loss_count(result: number): number;
    spc_result_max_impact(result: number): number;
    spc_result_error(result: number): number;
    spc_result_free(result: number): void;
    spc_wasm_alloc(size: number): number;
    spc_wasm_free(ptr: number, size: number): void;
}

export type WasmSource = URL | string | BufferSource | WebAssembly.Module | Response | Promise<Response>;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class Converter {
    readonly abiVersion: number;
    readonly libraryVersion: string;
    readonly #wasm: Exports;

    private constructor(wasm: Exports) {
        this.#wasm = wasm;
        this.abiVersion = wasm.spc_abi_version();
        if (this.abiVersion !== abi) {
            throw new ConverterError("invalidArgument", `wasm ABI ${this.abiVersion}, binding expects ${abi}`);
        }
        this.libraryVersion = this.#string(wasm.spc_library_version());
    }

    /** Defaults to spine_converter.wasm beside this module */
    static async load(source?: WasmSource): Promise<Converter> {
        const instance = await instantiate(source ?? new URL("./spine_converter.wasm", import.meta.url));
        return new Converter(instance.exports as unknown as Exports);
    }

    describe(status: Status): string {
        return this.#string(this.#wasm.spc_status_string(statuses.indexOf(status)));
    }

    /** Format unknown when the data is not Spine data */
    detect(data: Uint8Array): Detection {
        const w = this.#wasm;
        const input = this.#copyIn(data);
        const out = w.spc_wasm_alloc(44) >>> 0;
        try {
            const status = statuses[w.spc_detect(input.ptr, data.length, out)] ?? "invalidArgument";
            if (status === "unknownFormat") return { format: "unknown", version: "", major: 0, minor: 0, patch: 0 };
            if (status !== "ok") throw new ConverterError(status, this.describe(status));
            const view = new DataView(w.memory.buffer);
            return {
                format: formats[view.getInt32(out, true)] ?? "unknown",
                version: this.#string(out + 4),
                major: view.getUint16(out + 36, true),
                minor: view.getUint16(out + 38, true),
                patch: view.getUint16(out + 40, true),
            };
        } finally {
            w.spc_wasm_free(out, 44);
            input.free();
        }
    }

    /** Throws ConverterError on failure, including lossyRejected */
    convert(data: Uint8Array, options: ConvertOptions = {}): Conversion {
        const w = this.#wasm;
        const input = this.#copyIn(data);
        const version = options.targetVersion === undefined ? undefined : this.#copyIn(encoder.encode(options.targetVersion + "\0"));
        const atlasBytes = typeof options.atlas === "string" ? encoder.encode(options.atlas) : options.atlas;
        const atlas = atlasBytes === undefined ? undefined : this.#copyIn(atlasBytes);
        // spc_options then the result and a length
        const scratch = w.spc_wasm_alloc(32) >>> 0;
        let result = 0;
        try {
            let view = new DataView(w.memory.buffer);
            const flags =
                (options.failOnLoss ? flagFailOnLoss : 0) |
                (options.prettyJson ? flagPrettyJson : 0) |
                (options.noRewrite ? flagNoRewrite : 0);
            view.setUint32(scratch, 24, true);
            view.setUint32(scratch + 4, version?.ptr ?? 0, true);
            view.setInt32(scratch + 8, formats.indexOf(options.targetFormat ?? "unknown"), true);
            view.setUint32(scratch + 12, flags, true);
            view.setUint32(scratch + 16, atlas?.ptr ?? 0, true);
            view.setUint32(scratch + 20, atlasBytes?.length ?? 0, true);
            const code = w.spc_convert(input.ptr, data.length, scratch, 0, scratch + 24);
            const status = statuses[code] ?? "invalidArgument";
            view = new DataView(w.memory.buffer);
            result = view.getUint32(scratch + 24, true);
            if (status !== "ok") {
                throw new ConverterError(status, result === 0 ? this.describe(status) : this.#string(w.spc_result_error(result)));
            }
            const output = w.spc_result_data(result, scratch + 28) >>> 0;
            const length = new DataView(w.memory.buffer).getUint32(scratch + 28, true);
            const bytes = new Uint8Array(w.memory.buffer, output, length).slice();
            const reportPtr = w.spc_result_report(result, scratch + 28) >>> 0;
            const reportLength = new DataView(w.memory.buffer).getUint32(scratch + 28, true);
            const reportJson = decoder.decode(new Uint8Array(w.memory.buffer, reportPtr, reportLength));
            return {
                data: bytes,
                reportJson,
                report: JSON.parse(reportJson) as ReportEntry[],
                lossCount: w.spc_result_loss_count(result),
                maxImpact: impacts[w.spc_result_max_impact(result)] ?? "render",
            };
        } finally {
            w.spc_result_free(result);
            w.spc_wasm_free(scratch, 32);
            atlas?.free();
            version?.free();
            input.free();
        }
    }

    #copyIn(bytes: Uint8Array): { ptr: number; free(): void } {
        const w = this.#wasm;
        if (bytes.length === 0) return { ptr: 0, free() {} };
        const ptr = w.spc_wasm_alloc(bytes.length) >>> 0;
        if (ptr === 0) throw new ConverterError("outOfMemory", this.describe("outOfMemory"));
        new Uint8Array(w.memory.buffer, ptr, bytes.length).set(bytes);
        return { ptr, free: () => w.spc_wasm_free(ptr, bytes.length) };
    }

    #string(ptr: number): string {
        const memory = new Uint8Array(this.#wasm.memory.buffer);
        ptr >>>= 0;
        let end = ptr;
        while (memory[end] !== 0) end++;
        return decoder.decode(memory.subarray(ptr, end));
    }
}

async function instantiate(source: WasmSource): Promise<WebAssembly.Instance> {
    if (source instanceof WebAssembly.Module) return WebAssembly.instantiate(source, {});
    if (typeof source === "string" || source instanceof URL) {
        const url = new URL(source, import.meta.url);
        if (url.protocol === "file:") {
            const fs = "node:fs/promises";
            const { readFile } = (await import(/* @vite-ignore */ fs)) as { readFile(path: URL): Promise<Uint8Array<ArrayBuffer>> };
            return fromBytes(await readFile(url));
        }
        source = fetch(url);
    }
    if (source instanceof Promise || (typeof Response !== "undefined" && source instanceof Response)) {
        const response = await source;
        if (!response.ok) throw new ConverterError("invalidArgument", `cannot load wasm: ${response.status}`);
        return fromBytes(await response.arrayBuffer());
    }
    return fromBytes(source as BufferSource);
}

async function fromBytes(bytes: BufferSource): Promise<WebAssembly.Instance> {
    return WebAssembly.instantiate(await WebAssembly.compile(bytes), {});
}

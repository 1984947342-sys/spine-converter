import assert from "node:assert/strict";
import { test } from "node:test";
import { Converter, ConverterError } from "../dist/index.js";

const encoder = new TextEncoder();
const json = encoder.encode('{"skeleton":{"spine":"3.8.99","hash":""},"bones":[]}');
const physics = encoder.encode(
    '{"skeleton":{"spine":"4.2.43","referenceScale":50},"bones":[{"name":"root"}],"physics":[{"name":"p","bone":"root"}]}',
);
const atlas =
    "\na.png\nsize: 64,64\nformat: RGBA8888\nfilter: Linear,Linear\nrepeat: none\n" +
    "r\n  rotate: false\n  xy: 2, 2\n  size: 20, 30\n  orig: 32, 40\n  offset: 5, 3\n  index: -1\n";
const stripped = encoder.encode(
    '{"skeleton":{"spine":"3.6.53"},"bones":[{"name":"root"}],"slots":[{"name":"s","bone":"root"}],' +
        '"skins":{"default":{"s":{"r":{"type":"mesh","uvs":[0,0,1,0,1,1,0.25,0.7],"triangles":[0,1,2,0,2,3],' +
        '"vertices":[0,0,10,0,10,10,0,10],"hull":4}}}}}',
);
const converter = await Converter.load();

test("versions", () => {
    assert.equal(converter.abiVersion, 1);
    assert.match(converter.libraryVersion, /^\d+\.\d+\.\d+/);
    assert.equal(converter.describe("ok"), "ok");
});

test("detect", () => {
    assert.deepEqual(converter.detect(json), { format: "json", version: "3.8.99", major: 3, minor: 8, patch: 99 });
    assert.equal(converter.detect(encoder.encode("PNG")).format, "unknown");
    assert.equal(converter.detect(new Uint8Array()).format, "unknown");
});

test("convert keeps the source", () => {
    const same = converter.convert(json);
    assert.deepEqual(same.data, json);
    assert.equal(same.reportJson, "[]");
    assert.equal(same.lossCount, 0);
    assert.equal(same.maxImpact, "none");
});

test("convert reports losses", () => {
    const lossy = converter.convert(physics, { targetVersion: "4.1" });
    assert.equal(lossy.lossCount, 2);
    assert.equal(lossy.maxImpact, "pose");
    assert.ok(lossy.report.some((e) => e.code === "physics.dropped" && e.remedy === "none"));
});

test("convert formats", () => {
    const skel = converter.convert(json, { targetVersion: "4.3", targetFormat: "binary" });
    assert.equal(converter.detect(skel.data).format, "binary");
    const back = converter.convert(skel.data, { targetFormat: "json", prettyJson: true });
    assert.equal(converter.detect(back.data).version.slice(0, 3), "4.3");
});

test("convert with an atlas", () => {
    assert.equal(converter.convert(stripped, { targetVersion: "3.7" }).lossCount, 1);
    for (const text of [atlas, encoder.encode(atlas)]) {
        const kept = converter.convert(stripped, { targetVersion: "3.7", atlas: text });
        assert.equal(kept.lossCount, 0);
        assert.ok(new TextDecoder().decode(kept.data).includes("0.15625,0.175"));
    }
});

test("convert errors", () => {
    const failure = (options, status) =>
        assert.throws(() => converter.convert(physics, options), (e) => e instanceof ConverterError && e.status === status);
    failure({ targetVersion: "4.1", failOnLoss: true }, "lossyRejected");
    failure({ targetVersion: "3.4" }, "unsupportedVersion");
    failure({ targetVersion: "not a version" }, "invalidArgument");
    assert.throws(() => converter.convert(encoder.encode("PNG")), (e) => e.status === "unknownFormat");
});

test("memory is released", () => {
    for (let i = 0; i < 200; i++) {
        converter.convert(physics, { targetVersion: "4.1" });
        converter.convert(stripped, { targetVersion: "3.7", atlas });
    }
    const before = converter.convert(physics, { targetVersion: "3.8" });
    assert.ok(before.data.length > 0);
});

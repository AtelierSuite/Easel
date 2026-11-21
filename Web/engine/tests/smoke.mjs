// Smoke tests for the engine, in Node: makes, renders, saves and reopens
// documents. Pass paths to .psd, .pxd, .png or .jpg files to open them too.
//
//   node engine/tests/smoke.mjs [files...]

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { basename } from "node:path";
import assert from "node:assert/strict";
import { Engine } from "../engine.js";

const web = fileURLToPath(new URL("../../", import.meta.url));
const wasm = await readFile(process.env.EASEL_WASM ?? `${web}build/easel-engine.wasm`);
const engine = await Engine.load(wasm, { stdout: () => {}, stderr: (line) => console.warn("[engine]", line) });

let failures = 0;
async function test(name, body) {
  const start = performance.now();
  try {
    await body();
    console.log(`ok   ${name} (${Math.round(performance.now() - start)} ms)`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL ${name}\n     ${error.stack || error}`);
  }
}

function call(request, payload) {
  const result = engine.call(request, payload);
  assert.equal(result.response.ok, true, result.response.error);
  return result;
}

function pixel(bytes, width, x, y) {
  const i = (y * width + x) * 4;
  return [...bytes.subarray(i, i + 4)];
}

function near(actual, expected, tolerance = 2) {
  assert.ok(actual.every((v, i) => Math.abs(v - expected[i]) <= tolerance), `${actual} is not ${expected}`);
}

/** A picture's bytes as the page hands over what it decoded itself. */
function rawPixels(width, height, fill) {
  const bytes = new Uint8Array(17 + width * height * 4);
  bytes.set(new TextEncoder().encode("EaselRGBA"));
  new DataView(bytes.buffer).setUint32(9, width, true);
  new DataView(bytes.buffer).setUint32(13, height, true);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) bytes.set(fill(x, y), 17 + (y * width + x) * 4);
  }
  return bytes;
}

await test("a new document renders its fill", () => {
  const { response } = call({ op: "new", width: 64, height: 48, fill: [1, 0, 0, 1] });
  assert.equal(response.width, 64);
  assert.equal(response.rows.length, 1);
  const { response: size, payload } = call({ op: "render", doc: response.doc });
  assert.equal(size.width, 64);
  near(pixel(payload, 64, 10, 10), [255, 0, 0, 255]);
});

let pictureDoc;
await test("a picture opens as one layer, upright", () => {
  const picture = rawPixels(40, 30, (x, y) => (y < 15 ? [0, 0, 255, 255] : [0, 255, 0, 128]));
  const { response } = call({ op: "open", name: "picture.heic" }, picture);
  pictureDoc = response.doc;
  assert.equal(response.width, 40);
  const { payload } = call({ op: "render", doc: response.doc });
  near(pixel(payload, 40, 5, 5), [0, 0, 255, 255]);
  near(pixel(payload, 40, 5, 25), [0, 255, 0, 128]);
});

let png;
await test("PNG round trip", () => {
  png = call({ op: "export", doc: pictureDoc, format: "png" }).payload;
  assert.deepEqual([...png.subarray(1, 4)], [0x50, 0x4e, 0x47]);
  const { response } = call({ op: "open", name: "again.png" }, png);
  const { payload } = call({ op: "render", doc: response.doc });
  near(pixel(payload, 40, 5, 5), [0, 0, 255, 255]);
  near(pixel(payload, 40, 5, 25), [0, 255, 0, 128]);
});

await test("JPEG export reads back", () => {
  const jpeg = call({ op: "export", doc: pictureDoc, format: "jpeg" }).payload;
  assert.deepEqual([...jpeg.subarray(0, 2)], [0xff, 0xd8]);
  const { response } = call({ op: "open", name: "again.jpg" }, jpeg);
  const { payload } = call({ op: "render", doc: response.doc });
  near(pixel(payload, 40, 5, 5), [0, 0, 255, 255], 12);
});

await test("Photoshop round trip keeps layers and blend modes", () => {
  const { response } = call({ op: "new", width: 32, height: 32, fill: [1, 1, 1, 1] });
  const doc = response.doc;
  const layer = response.rows[0].id;
  call({ op: "update", doc, id: layer, opacity: 0.5, name: "Base" });
  const psd = call({ op: "export", doc, format: "psd" }).payload;
  assert.equal(new TextDecoder().decode(psd.subarray(0, 4)), "8BPS");
  const reopened = call({ op: "open", name: "round.psd" }, psd).response;
  assert.equal(reopened.width, 32);
  const base = reopened.rows.find((row) => row.name === "Base");
  assert.ok(base, `layers: ${reopened.rows.map((r) => r.name)}`);
  assert.ok(Math.abs(base.opacity - 0.5) < 0.01);
  const { payload } = call({ op: "render", doc: reopened.doc });
  near(pixel(payload, 32, 16, 16), [255, 255, 255, 128], 3);
});

await test("hiding a layer leaves the canvas clear", () => {
  const { response } = call({ op: "new", width: 16, height: 16, fill: [0, 0, 0, 1] });
  const updated = call({ op: "update", doc: response.doc, id: response.rows[0].id, visible: false }).response;
  assert.equal(updated.rows[0].visible, false);
  const { payload } = call({ op: "render", doc: response.doc });
  near(pixel(payload, 16, 8, 8), [0, 0, 0, 0]);
});

await test("thumbnails and smaller renders", () => {
  const { response } = call({ op: "new", width: 400, height: 200, fill: [0, 0.5, 1, 1] });
  const small = call({ op: "render", doc: response.doc, maxSize: 100 });
  assert.equal(small.response.width, 100);
  assert.equal(small.response.height, 50);
  const thumb = call({ op: "thumbnail", doc: response.doc, layer: response.rows[0].id, size: 48 });
  assert.equal(thumb.response.width, 48);
  near(pixel(thumb.payload, 48, 10, 10), [0, 128, 255, 255], 3);
});

await test("an Easel package round trip", () => {
  const zip = call({ op: "export", doc: pictureDoc, format: "easel" }).payload;
  assert.deepEqual([...zip.subarray(0, 2)], [0x50, 0x4b]);
  const { response } = call({ op: "open", name: "copy.easel" }, zip);
  assert.equal(response.width, 40);
  const { payload } = call({ op: "render", doc: response.doc });
  near(pixel(payload, 40, 5, 5), [0, 0, 255, 255]);
});

await test("the sample draws its effects, filters and adjustment", () => {
  const { response } = call({ op: "sample" });
  assert.equal(response.rows.length, 8);
  const { payload } = call({ op: "render", doc: response.doc });
  // The badge's middle is blue, and its drop shadow darkens the sky below right of it.
  const badge = pixel(payload, 1200, 220, 220);
  assert.ok(badge[2] > 200 && badge[0] < 100, `badge ${badge}`);
  const shadow = pixel(payload, 1200, 300, 330), sky = pixel(payload, 1200, 300, 420);
  assert.ok(shadow[0] + shadow[1] + shadow[2] < sky[0] + sky[1] + sky[2], `shadow ${shadow}, sky ${sky}`);
  // The hills' blur softens their top edge.
  const edge = pixel(payload, 1200, 600, 540);
  assert.ok(edge[1] > 60 && edge[1] < 200, `edge ${edge}`);
});

for (const path of process.argv.slice(2)) {
  await test(`opens ${basename(path)}`, async () => {
    const bytes = new Uint8Array(await readFile(path));
    const { response } = call({ op: "open", name: basename(path) }, bytes);
    const { response: size } = call({ op: "render", doc: response.doc, maxSize: 512 });
    console.log(`     ${response.width}×${response.height}, ${response.rows.length} rows, rendered ${size.width}×${size.height}`);
  });
}

console.log(failures ? `${failures} failed` : "All passed");
process.exit(failures ? 1 : 0);

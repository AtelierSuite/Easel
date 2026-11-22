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

await test("painting, filling, undo and redo", () => {
  const { response } = call({ op: "new", width: 64, height: 64, fill: [1, 1, 1, 1] });
  const doc = response.doc, layer = response.rows[0].id;
  const painted = call({ op: "stroke", doc, layer, kind: "paint", points: [8, 32, 1, 56, 32, 1], size: 8, color: [0, 0, 1, 1] }).response;
  assert.equal(painted.canUndo, true);
  near(pixel(call({ op: "render", doc }).payload, 64, 32, 32), [0, 0, 255, 255]);
  call({ op: "fill", doc, layer, x: 32, y: 8, color: [1, 0, 0, 1], tolerance: 0.1 });
  const filled = call({ op: "render", doc }).payload;
  near(pixel(filled, 64, 32, 8), [255, 0, 0, 255]);
  near(pixel(filled, 64, 32, 32), [0, 0, 255, 255]);
  call({ op: "stroke", doc, layer, kind: "erase", points: [32, 0, 1, 32, 63, 1], size: 6 });
  near(pixel(call({ op: "render", doc }).payload, 64, 32, 16), [0, 0, 0, 0]);
  call({ op: "undo", doc });
  call({ op: "undo", doc });
  const undone = call({ op: "render", doc }).payload;
  near(pixel(undone, 64, 32, 8), [255, 255, 255, 255]);
  near(pixel(undone, 64, 32, 32), [0, 0, 255, 255]);
  const redone = call({ op: "redo", doc }).response;
  assert.equal(redone.canRedo, true);
  near(pixel(call({ op: "render", doc }).payload, 64, 32, 8), [255, 0, 0, 255]);
});

await test("soft strokes paint and erase", () => {
  const { response } = call({ op: "new", width: 64, height: 64, fill: [1, 1, 1, 1] });
  const doc = response.doc, layer = response.rows[0].id;
  call({ op: "stroke", doc, layer, kind: "paint", points: [8, 16, 1, 56, 16, 1], size: 12, softness: 0.5, color: [0, 0, 1, 1] });
  call({ op: "stroke", doc, layer, kind: "erase", points: [8, 48, 1, 56, 48, 1], size: 12, softness: 0.5 });
  const { payload } = call({ op: "render", doc });
  const painted = pixel(payload, 64, 32, 16), erased = pixel(payload, 64, 32, 48);
  assert.ok(painted[2] > 200 && painted[0] < 120, `painted ${painted}`);
  assert.ok(erased[3] < 100, `erased ${erased}`);
});

await test("a selection confines painting, and clearing empties it", () => {
  const { response } = call({ op: "new", width: 64, height: 64, fill: [1, 1, 1, 1] });
  const doc = response.doc, layer = response.rows[0].id;
  const selected = call({ op: "select", doc, shape: "rectangle", rect: [0, 0, 32, 64] }).response;
  assert.match(selected.selection, /^M0 0/);
  call({ op: "stroke", doc, layer, points: [4, 32, 1, 60, 32, 1], size: 10, color: [1, 0, 0, 1] });
  let picture = call({ op: "render", doc }).payload;
  near(pixel(picture, 64, 16, 32), [255, 0, 0, 255]);
  near(pixel(picture, 64, 48, 32), [255, 255, 255, 255]);
  call({ op: "select", doc, shape: "invert" });
  call({ op: "clear", doc, layer });
  picture = call({ op: "render", doc }).payload;
  near(pixel(picture, 64, 48, 8), [0, 0, 0, 0]);
  near(pixel(picture, 64, 16, 8), [255, 255, 255, 255]);
  assert.equal(call({ op: "select", doc, shape: "none" }).response.selection, null);
});

await test("move, gradient, shape, text and crop", () => {
  const { response } = call({ op: "new", width: 64, height: 64, fill: [1, 1, 1, 1] });
  const doc = response.doc, layer = response.rows[0].id;
  call({ op: "gradient", doc, layer, line: [0, 0, 64, 0], stops: [0, 0, 0, 0, 1, 1, 0, 0, 1, 1] });
  let picture = call({ op: "render", doc }).payload;
  assert.ok(pixel(picture, 64, 4, 32)[2] < 40 && pixel(picture, 64, 60, 32)[2] > 200);
  const shape = call({ op: "shape", doc, layer, shape: "rectangle", line: [10, 10, 30, 30], color: [1, 0, 0, 1] }).response;
  assert.equal(shape.rows.find((row) => row.id === shape.added).type, "vector");
  near(pixel(call({ op: "render", doc }).payload, 64, 20, 20), [255, 0, 0, 255]);
  call({ op: "move", doc, layer: shape.added, dx: 20, dy: 0 });
  picture = call({ op: "render", doc }).payload;
  near(pixel(picture, 64, 40, 20), [255, 0, 0, 255]);
  assert.equal(call({ op: "hit", doc, x: 40, y: 20 }).response.layer, shape.added);
  const text = call({ op: "text", doc, layer, x: 32, y: 50, string: "Hi", color: [0, 0, 0, 1] }).response;
  assert.equal(text.rows.find((row) => row.id === text.added).type, "text");
  assert.equal(call({ op: "hit", doc, x: 32, y: 50, text: true }).response.string, "Hi");
  const cropped = call({ op: "crop", doc, rect: [8, 8, 40, 30] }).response;
  assert.equal(cropped.width, 40);
  assert.equal(cropped.height, 30);
});

await test("retouching strokes change only where they're drawn", () => {
  const stripes = () => rawPixels(64, 64, (x) => (x % 2 ? [255, 255, 255, 255] : [0, 0, 0, 255]));
  const strokes = [
    { kind: "blur" }, { kind: "mosaic" }, { kind: "motionBlur", angle: 0 }, { kind: "heal" }, { kind: "liquify" },
    { kind: "smudge" }, { kind: "tone", tone: "burn" }, { kind: "clone", dx: 1, dy: 0 },
  ];
  for (const stroke of strokes) {
    const { response } = call({ op: "open", name: "stripes.png" }, stripes());
    const before = call({ op: "render", doc: response.doc }).payload;
    call({ op: "stroke", doc: response.doc, layer: response.rows[0].id, points: [4, 32, 1, 60, 32, 1], size: 16, ...stroke });
    const after = call({ op: "render", doc: response.doc }).payload;
    const changed = (y) => [...Array(64).keys()].some((x) => pixel(after, 64, x, y)[0] !== pixel(before, 64, x, y)[0]);
    assert.ok(changed(32), `${stroke.kind} changed nothing`);
    assert.ok(!changed(4), `${stroke.kind} changed too much`);
  }
});

await test("the canvas's parts: the layer painted stands alone, the rest flattened", () => {
  const { response } = call({ op: "sample" });
  const doc = response.doc;
  // Top first: Vibrance, Title, Badge, the Sun group, Haze, Sun disc, Hills, Sky.
  const id = (name) => response.rows[["Vibrance", "Title", "Badge", "Sun", "Haze", "Sun disc", "Hills", "Sky"].indexOf(name)].id;
  // A tap passes over the adjustment on top to the badge seen there.
  assert.equal(call({ op: "hit", doc, x: 220, y: 220 }).response.layer, id("Badge"));
  // The adjustment on top flattens everything beneath it.
  assert.equal(call({ op: "canvas", doc, layer: id("Hills") }).response.parts.length, 1);
  call({ op: "update", doc, id: id("Vibrance"), visible: false });
  const { response: split, payload } = call({ op: "canvas", doc, layer: id("Hills"), maxSize: 600 });
  assert.equal(split.width, 600);
  assert.deepEqual(split.parts.map((part) => `${part.blendMode}${part.active ? "*" : ""}`), ["normal", "normal*", "normal", "multiply", "normal"]);
  assert.equal(payload.length, 600 * 400 * 4 * 5);
  const only = call({ op: "canvas", doc, layer: id("Hills"), maxSize: 600, only: "active" }).response;
  assert.deepEqual(only.rendered, [1]);
  assert.equal(only.key, split.key);
});

await test("a hidden or locked layer can't be painted on", () => {
  const { response } = call({ op: "new", width: 16, height: 16 });
  const doc = response.doc, layer = response.rows[0].id;
  call({ op: "update", doc, id: layer, locked: true });
  const result = engine.call({ op: "stroke", doc, layer, points: [8, 8, 1], size: 4 });
  assert.equal(result.response.ok, false);
});

await test("layers are added, copied, stacked, grouped, merged and deleted", () => {
  const { response } = call({ op: "new", width: 16, height: 16, fill: [1, 1, 1, 1] });
  const doc = response.doc, background = response.rows[0].id;
  const layers = (args) => call({ op: "layers", doc, ...args }).response;
  let r = layers({ action: "add", layer: background });
  const added = r.added;
  assert.equal(r.rows.length, 2);
  assert.equal(r.rows[0].id, added);
  r = layers({ action: "duplicate", layer: added });
  assert.equal(r.rows.length, 3);
  r = layers({ action: "moveBy", layer: added, offset: 1 });
  assert.equal(r.rows[0].id, added);
  r = layers({ action: "group", layer: added });
  const group = r.added;
  assert.equal(r.rows[0].kind, "group");
  assert.equal(r.groups.length, 1);
  r = layers({ action: "mergeGroup", group });
  assert.equal(r.groups.length, 0);
  assert.equal(r.rows.length, 3);
  r = layers({ action: "mergeDown", layer: r.added });
  assert.equal(r.rows.length, 2);
  r = layers({ action: "clip", layer: r.added, clipped: true });
  assert.equal(r.rows[0].clipped, true);
  r = layers({ action: "delete", layer: r.rows[0].id });
  assert.equal(r.rows.length, 1);
  assert.equal(engine.call({ op: "layers", doc, action: "delete", layer: background }).response.rows.length, 1);
  r = layers({ action: "addAdjustment", kind: "invert", layer: background });
  assert.equal(r.rows[0].type, "adjustment");
  assert.equal(r.rows[0].adjustment.kind, "invert");
  assert.ok(r.adjustmentKinds.flat().some((kind) => kind.id === "brightness"));
  const { payload } = call({ op: "render", doc });
  near(pixel(payload, 16, 4, 4), [0, 0, 0, 255]);
  call({ op: "update", doc, id: r.rows[0].id, fillOpacity: 0.5 });
});

await test("a mask hides where the brush paints and shows where the eraser does", () => {
  const { response } = call({ op: "new", width: 32, height: 32, fill: [1, 0, 0, 1] });
  const doc = response.doc, layer = response.rows[0].id;
  let r = call({ op: "layers", doc, action: "addMask", layer }).response;
  assert.equal(r.rows[0].masked, true);
  call({ op: "stroke", doc, layer, mask: true, kind: "paint", points: [16, 0, 1, 16, 32, 1], size: 10 });
  let { payload } = call({ op: "render", doc });
  near(pixel(payload, 32, 16, 16), [0, 0, 0, 0]);
  near(pixel(payload, 32, 2, 16), [255, 0, 0, 255]);
  call({ op: "stroke", doc, layer, mask: true, kind: "erase", points: [16, 0, 1, 16, 32, 1], size: 10 });
  ({ payload } = call({ op: "render", doc }));
  near(pixel(payload, 32, 16, 16), [255, 0, 0, 255]);
  assert.equal(engine.call({ op: "fill", doc, layer, mask: true, x: 1, y: 1 }).response.ok, false);
  call({ op: "layers", doc, action: "invertMask", layer });
  ({ payload } = call({ op: "render", doc }));
  near(pixel(payload, 32, 2, 16), [0, 0, 0, 0]);
  call({ op: "layers", doc, action: "enableMask", layer, enabled: false });
  ({ payload } = call({ op: "render", doc }));
  near(pixel(payload, 32, 2, 16), [255, 0, 0, 255]);
  r = call({ op: "layers", doc, action: "deleteMask", layer }).response;
  assert.equal(r.rows[0].masked, false);
});

await test("the pen draws a path, and its points move and go", () => {
  const { response } = call({ op: "new", width: 40, height: 40, fill: [1, 1, 1, 1] });
  const doc = response.doc, background = response.rows[0].id;
  const square = [[5, 5], [35, 5], [35, 35], [5, 35]].map(([x, y]) => ({ x, y, in: null, out: null, smooth: false }));
  let r = call({ op: "vector", doc, layer: background, action: "add", paths: [{ nodes: square, closed: true, fill: [0, 0, 1, 1], stroke: null, strokeWidth: 2 }] }).response;
  const layer = r.added;
  assert.equal(r.rows[0].type, "vector");
  let { payload } = call({ op: "render", doc });
  near(pixel(payload, 40, 20, 20), [0, 0, 255, 255]);
  let paths = call({ op: "paths", doc, layer }).response.paths;
  assert.equal(paths[0].nodes.length, 4);
  near([paths[0].nodes[2].x, paths[0].nodes[2].y], [35, 35], 0.01);
  paths[0].nodes[2] = { ...paths[0].nodes[2], x: 15, y: 15 };
  paths[0].nodes.pop();
  call({ op: "vector", doc, layer, action: "set", paths });
  ({ payload } = call({ op: "render", doc }));
  near(pixel(payload, 40, 30, 30), [255, 255, 255, 255]);
  paths = call({ op: "paths", doc, layer }).response.paths;
  assert.equal(paths[0].nodes.length, 3);
  near([paths[0].nodes[0].x, paths[0].nodes[0].y], [5, 5], 0.01);
  r = call({ op: "vector", doc, layer, action: "set", paths: [] }).response;
  assert.equal(r.rows.length, 1);
});

await test("paths take gradients, patterns, stroke styles and text, grow, outline and build", () => {
  const { response } = call({ op: "new", width: 60, height: 60, fill: [1, 1, 1, 1] });
  const doc = response.doc;
  const square = (x, y, s) => [[x, y], [x + s, y], [x + s, y + s], [x, y + s]].map(([x, y]) => ({ x, y, in: null, out: null, smooth: false }));
  const both = [square(5, 5, 30), square(20, 20, 30)].map((nodes) => ({ nodes, closed: true, fill: [1, 0, 0, 1], stroke: [0, 0, 0, 1], strokeWidth: 2 }));
  const layer = call({ op: "vector", doc, action: "add", paths: both }).response.added;
  const paths = () => call({ op: "paths", doc, layer }).response.paths;
  call({ op: "vector", doc, layer, action: "style", path: 0, gradient: "radial", angle: 30 });
  assert.equal(paths()[0].gradient.kind, "radial");
  assert.equal(paths()[0].gradient.angle, 30);
  call({ op: "vector", doc, layer, action: "style", path: 0, stops: [0, 1, 0, 0, 1, 0.5, 0, 1, 0, 1, 1, 0, 0, 1, 1] });
  assert.equal(paths()[0].gradient.stops.length, 3);
  assert.equal(paths()[1].gradient, null);
  call({ op: "vector", doc, layer, action: "style", pattern: "dots" });
  assert.equal(paths()[0].pattern, "dots");
  assert.equal(paths()[0].gradient, null);
  call({ op: "vector", doc, layer, action: "style", strokeStyle: { dash: "dashed", endArrow: "triangle" } });
  assert.equal(paths()[1].strokeStyle.dash, "dashed");
  call({ op: "vector", doc, layer, action: "style", path: 1, text: { string: "Hello" } });
  assert.equal(paths()[1].text.string, "Hello");
  assert.equal(paths()[1].stroke, null);
  call({ op: "vector", doc, layer, action: "style", path: 1, text: null });
  assert.equal(paths()[1].text, null);
  const faces = call({ op: "paths", doc, layer, faces: true }).response;
  assert.equal(faces.faces.length, 3);
  call({ op: "vector", doc, layer, action: "build", picked: faces.faces.map((_, i) => i) });
  assert.equal(paths().length, 1);
  const before = paths()[0].nodes.map((n) => n.x);
  call({ op: "vector", doc, layer, action: "offset", distance: 4 });
  assert.ok(Math.min(...paths()[0].nodes.map((n) => n.x)) < Math.min(...before));
  call({ op: "vector", doc, layer, action: "outline" });
  assert.equal(paths()[0].stroke, null);
});

await test("shapes combine exactly", () => {
  const { response } = call({ op: "new", width: 60, height: 60, fill: [1, 1, 1, 1] });
  const doc = response.doc;
  const square = (x, y, s) => [[x, y], [x + s, y], [x + s, y + s], [x, y + s]].map(([x, y]) => ({ x, y, in: null, out: null, smooth: false }));
  const both = [square(5, 5, 30), square(20, 20, 30)].map((nodes) => ({ nodes, closed: true, fill: [0, 0, 1, 1], stroke: null, strokeWidth: 1 }));
  const layer = call({ op: "vector", doc, action: "add", paths: both }).response.added;
  call({ op: "vector", doc, layer, action: "combine", operation: "subtract" });
  const { payload } = call({ op: "render", doc });
  near(pixel(payload, 60, 10, 10), [0, 0, 255, 255]);
  near(pixel(payload, 60, 27, 27), [255, 255, 255, 255]);
  near(pixel(payload, 60, 45, 45), [255, 255, 255, 255]);
  const nodes = call({ op: "paths", doc, layer }).response.paths[0].nodes;
  assert.equal(nodes.length, 6);
  const start = performance.now();
  const circle = Array.from({ length: 4 }, (_, i) => {
    const a = (i * Math.PI) / 2, k = 0.5523 * 20;
    const x = 30 + Math.cos(a) * 20, y = 30 + Math.sin(a) * 20;
    return { x, y, in: [x + Math.sin(a) * k, y - Math.cos(a) * k], out: [x - Math.sin(a) * k, y + Math.cos(a) * k], smooth: true };
  });
  const round = call({ op: "vector", doc, action: "add", paths: [{ nodes: circle, closed: true, fill: [1, 0, 0, 1], stroke: null, strokeWidth: 1 }] }).response.added;
  call({ op: "vector", doc, layer: round, action: "offset", distance: 5 });
  assert.ok(performance.now() - start < 3000);
  const grown = call({ op: "render", doc }).payload;
  near(pixel(grown, 60, 53, 30), [255, 0, 0, 255]);
  near(pixel(grown, 60, 57, 30), [255, 255, 255, 255]);
});

await test("brush tips paint, and symmetry mirrors the stroke", () => {
  const { response } = call({ op: "new", width: 40, height: 40, fill: [0, 0, 0, 0] });
  const doc = response.doc, layer = response.rows[0].id;
  call({ op: "stroke", doc, layer, kind: "paint", points: [5, 5, 1, 12, 12, 1], times: [0, 0.05], size: 6, color: [1, 0, 0, 1], tip: "chalk", symmetry: "both", dynamics: { taper: 0.2 } });
  const { payload } = call({ op: "render", doc });
  for (const [x, y] of [[8, 8], [31, 8], [8, 31], [31, 31]]) {
    const around = [-1, 0, 1].flatMap((dx) => [-1, 0, 1].map((dy) => pixel(payload, 40, x + dx, y + dy)[3]));
    assert.ok(Math.max(...around) > 0, `nothing painted near ${x}, ${y}`);
  }
  near(pixel(payload, 40, 20, 20), [0, 0, 0, 0]);
});

await test("a picture the page decoded stands in for its bytes", () => {
  const heic = new Uint8Array([0, 0, 0, 24, ...new TextEncoder().encode("ftypheic"), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  let hash = 0x811c9dc5;
  for (const byte of heic) hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  call({ op: "picture", key: `${heic.length}-${hash.toString(16)}` }, rawPixels(3, 2, () => [0, 0, 255, 255]));
  const { response } = call({ op: "open", name: "photo.heic" }, heic);
  assert.equal(response.width, 3);
  const { payload } = call({ op: "render", doc: response.doc });
  near(pixel(payload, 3, 1, 1), [0, 0, 255, 255]);
  assert.equal(engine.call({ op: "open", name: "photo.heic" }, heic).response.ok, false);
});

await test("transform bends a layer by its corners", () => {
  const { response } = call({ op: "new", width: 40, height: 40, fill: [1, 0, 0, 1] });
  const doc = response.doc, layer = response.rows[0].id;
  const handles = call({ op: "transform", doc, layer, action: "handles", mode: "distort" }).response;
  assert.deepEqual(handles.points, [0, 0, 40, 0, 40, 40, 0, 40]);
  assert.equal(call({ op: "transform", doc, layer, action: "handles", mode: "warp" }).response.points.length, 32);
  const points = [0, 0, 20, 0, 20, 20, 0, 20];
  const preview = call({ op: "transform", doc, layer, action: "preview", mode: "distort", points, maxSize: 20 });
  assert.equal(preview.response.width, 20);
  near(pixel(preview.payload, 20, 15, 15), [0, 0, 0, 0]);
  call({ op: "transform", doc, layer, action: "apply", mode: "distort", points });
  const { payload } = call({ op: "render", doc });
  near(pixel(payload, 40, 10, 10), [255, 0, 0, 255]);
  near(pixel(payload, 40, 30, 30), [0, 0, 0, 0]);
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

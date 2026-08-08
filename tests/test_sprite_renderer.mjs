// Unit tests for client/sprite_renderer.js: protocol parsing, sprite
// decoding, composition, input encoding, and the renderer lifecycle.
// Runs in plain Node (no Window, no DOM) with a stub OffscreenCanvas,
// which doubles as proof that the module has no Window/DOM dependencies.
//
//   node tests/test_sprite_renderer.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const clientDir = join(dirname(fileURLToPath(import.meta.url)), "..", "client");

// --- Canvas stubs -----------------------------------------------------------

class StubImageData {
  constructor(width, height) {
    this.width = width;
    this.height = height;
    this.data = new Uint8ClampedArray(width * height * 4);
  }
}

class StubContext {
  constructor(canvas) {
    this.canvas = canvas;
    this.imageSmoothingEnabled = true;
    this.imageSmoothingQuality = "low";
    this.fillStyle = "";
    this.strokeStyle = "";
    this.lineWidth = 1;
    this.font = "";
    this.textBaseline = "";
    this.calls = [];
    this.lastPutImage = null;
    this.transform = [1, 0, 0, 1, 0, 0];
  }
  record(name, args) {
    this.calls.push({ name, args });
  }
  createImageData(width, height) {
    return new StubImageData(width, height);
  }
  putImageData(image, x, y) {
    this.lastPutImage = image;
    this.record("putImageData", [image, x, y]);
  }
  drawImage(...args) {
    this.record("drawImage", args);
  }
  fillRect(...args) {
    this.record("fillRect", args);
  }
  clearRect(...args) {
    this.record("clearRect", args);
  }
  setTransform(...args) {
    this.transform = args;
    this.record("setTransform", args);
  }
  strokeRect(...args) {
    this.record("strokeRect", args);
  }
  fillText(...args) {
    this.record("fillText", args);
  }
  measureText(text) {
    return { width: text.length * 5 };
  }
  save() {}
  restore() {}
}

const allCanvases = [];

class StubOffscreenCanvas {
  constructor(width, height) {
    this.width = width;
    this.height = height;
    this.ctx = new StubContext(this);
    allCanvases.push(this);
  }
  getContext(kind) {
    assert.equal(kind, "2d");
    return this.ctx;
  }
  transferToImageBitmap() {
    return { bitmap: true, width: this.width, height: this.height, close() {} };
  }
}

globalThis.OffscreenCanvas = StubOffscreenCanvas;
globalThis.self = globalThis;

// --- Load SnappyJS and the renderer as classic scripts ----------------------

new Function(readFileSync(join(clientDir, "snappyjs.min.js"), "utf8"))();
new Function(readFileSync(join(clientDir, "sprite_renderer.js"), "utf8"))();
const { SnappyJS, BitworldSpriteRenderer: R } = globalThis;
assert.ok(SnappyJS, "SnappyJS should attach to the global scope");
assert.ok(R, "BitworldSpriteRenderer should attach to the global scope");

// --- Packet builders (framing per docs/sprite_v1.md) ------------------------

const u16 = value => [value & 255, (value >> 8) & 255];
const i16 = value => u16(value & 0xffff);
const u32 = value => [
  value & 255, (value >> 8) & 255, (value >> 16) & 255, (value >> 24) & 255
];
const utf8 = text => [...new TextEncoder().encode(text)];

function spritePacket(id, width, height, rgba, label = "") {
  const compressed = [...SnappyJS.compress(Uint8Array.from(rgba))];
  return [
    0x01, ...u16(id), ...u16(width), ...u16(height),
    ...u32(compressed.length), ...compressed,
    ...u16(utf8(label).length), ...utf8(label)
  ];
}

const objectPacket = (id, x, y, z, layer, spriteId) =>
  [0x02, ...u16(id), ...i16(x), ...i16(y), ...i16(z), layer, ...u16(spriteId)];
const layerPacket = (id, type, flags) => [0x06, id, type, flags];
const viewportPacket = (layer, width, height) =>
  [0x05, layer, ...u16(width), ...u16(height)];

const bytes = (...parts) => Uint8Array.from(parts.flat());
const tick = () => new Promise(resolve => setTimeout(resolve, 40));

// Solid RGBA fills.
const fill = (count, r, g, b, a) => {
  const pixels = [];
  for (let index = 0; index < count; index++) pixels.push(r, g, b, a);
  return pixels;
};

// --- parsePackets -----------------------------------------------------------

{
  const events = [];
  const stream = bytes(
    layerPacket(0, 0, 1),
    viewportPacket(0, 4, 4),
    spritePacket(7, 2, 2, fill(4, 255, 0, 0, 255), "red"),
    objectPacket(1, 1, 1, 0, 0, 7),
    [0x07, ...u16(42)],
    [0x03, ...u16(1)],
    [0x04]
  );
  R.parsePackets(stream, {
    onSprite: (id, sprite, packetBytes) => events.push(["sprite", id, sprite, packetBytes]),
    onObject: object => events.push(["object", object]),
    onDeleteObject: id => events.push(["delete", id]),
    onClearObjects: () => events.push(["clear"]),
    onViewport: (layer, width, height) => events.push(["viewport", layer, width, height]),
    onLayer: (id, type, flags) => events.push(["layer", id, type, flags]),
    onIdentity: objectId => events.push(["identity", objectId])
  });
  assert.deepEqual(events[0], ["layer", 0, 0, 1]);
  assert.deepEqual(events[1], ["viewport", 0, 4, 4]);
  const [kind, id, sprite, packetBytes] = events[2];
  assert.equal(kind, "sprite");
  assert.equal(id, 7);
  assert.equal(sprite.width, 2);
  assert.equal(sprite.label, "red");
  assert.equal(sprite.compressed, null);
  assert.deepEqual([...sprite.pixels], fill(4, 255, 0, 0, 255));
  assert.equal(packetBytes, spritePacket(7, 2, 2, fill(4, 255, 0, 0, 255), "red").length);
  assert.deepEqual(events[3], ["object", { id: 1, x: 1, y: 1, z: 0, layer: 0, spriteId: 7 }]);
  assert.deepEqual(events[4], ["identity", 42]);
  assert.deepEqual(events[5], ["delete", 1]);
  assert.deepEqual(events[6], ["clear"]);
  console.log("parsePackets decodes every message type");
}

{
  // Raw-palette fallback: payload with no valid snappy framing decodes as
  // one palette index per pixel (index 3 = PICO-8 red #ff004d).
  const raw = [0x01, ...u16(9), ...u16(1), ...u16(2), 0, 4];
  const sprites = [];
  R.parsePackets(Uint8Array.from(raw), {
    onSprite: (id, sprite) => sprites.push(sprite)
  });
  assert.deepEqual([...sprites[0].pixels], [0, 0, 0, 0, 255, 0, 77, 255]);
  console.log("parsePackets falls back to raw-palette payloads");
}

{
  // Snappy-mandatory mode: valid framing with a corrupt payload is retained
  // for retry instead of desyncing the stream.
  const corrupt = [
    0x01, ...u16(3), ...u16(2), ...u16(2),
    ...u32(4), 0xff, 0xff, 0xff, 0xff, ...u16(0),
    ...objectPacket(5, 0, 0, 0, 0, 3)
  ];
  const events = [];
  R.parsePackets(Uint8Array.from(corrupt), {
    onSprite: (id, sprite) => events.push(["sprite", id, sprite]),
    onObject: object => events.push(["object", object.id])
  }, { rawPaletteFallback: false });
  assert.equal(events[0][0], "sprite");
  assert.equal(events[0][2].pixels, null);
  assert.deepEqual([...events[0][2].compressed], [0xff, 0xff, 0xff, 0xff]);
  assert.deepEqual(events[1], ["object", 5]);
  // Structurally unparseable sprite payloads throw in snappy-mandatory mode.
  assert.throws(
    () => R.parsePackets(bytes([0x01, ...u16(3), ...u16(2), ...u16(2), 0, 0]), {},
      { rawPaletteFallback: false }),
    /unparseable pixel payload/
  );
  console.log("parsePackets retains corrupt snappy payloads without desync");
}

{
  assert.throws(() => R.parsePackets(bytes([0x99]), {}), /Unknown Sprite v1 packet type/);
  assert.throws(() => R.parsePackets(bytes([0x02, 1, 2, 3]), {}), /Truncated/);
  console.log("parsePackets rejects unknown and truncated messages");
}

// --- putSpritePixel ---------------------------------------------------------

{
  const image = new StubImageData(2, 1);
  // Opaque source overwrites.
  R.putSpritePixel(image, 0, 0, Uint8Array.from([10, 20, 30, 255]), 0);
  assert.deepEqual([...image.data.slice(0, 4)], [10, 20, 30, 255]);
  // Transparent source is a no-op.
  R.putSpritePixel(image, 0, 0, Uint8Array.from([99, 99, 99, 0]), 0);
  assert.deepEqual([...image.data.slice(0, 4)], [10, 20, 30, 255]);
  // 50% alpha over opaque blends straight-alpha source-over.
  R.putSpritePixel(image, 0, 0, Uint8Array.from([110, 120, 130, 128]), 0);
  const srcAlpha = 128 / 255;
  const expected = channel => Math.round(
    (channel[0] * srcAlpha + channel[1] * (1 - srcAlpha)) / 1
  );
  assert.deepEqual(
    [...image.data.slice(0, 4)],
    [expected([110, 10]), expected([120, 20]), expected([130, 30]), 255]
  );
  // Out-of-bounds writes are clipped.
  R.putSpritePixel(image, 5, 0, Uint8Array.from([1, 2, 3, 255]), 0);
  assert.deepEqual([...image.data.slice(4, 8)], [0, 0, 0, 0]);
  console.log("putSpritePixel composites correctly");
}

// --- Input packet encoders --------------------------------------------------

{
  assert.deepEqual([...R.encodePlayerButtons(0xff)], [0x84, 0x7f]);
  assert.deepEqual([...R.encodeInputText("hi")], [0x81, 2, 0, 104, 105]);
  assert.equal(R.encodeInputText("\n\t"), null);
  console.log("input packet encoders match the wire format");
}

// --- Renderer lifecycle -----------------------------------------------------

{
  const packets = [];
  let draws = 0;
  const canvas = new StubOffscreenCanvas(128, 128);
  const renderer = R.create({
    canvas,
    width: 128,
    height: 128,
    dpr: 1,
    onPacket: packet => packets.push([...packet]),
    onDraw: () => draws++
  });

  renderer.ingest(bytes(
    layerPacket(0, 0, 1),
    viewportPacket(0, 4, 4),
    spritePacket(7, 2, 2, fill(4, 255, 0, 0, 255), "red"),
    objectPacket(1, 1, 1, 0, 0, 7)
  ));
  await tick();
  assert.ok(draws > 0, "draw should run after ingest");

  // The 4x4 layer canvas composited the 2x2 red sprite at (1,1).
  const layerCanvas = allCanvases.find(c => c.width === 4 && c.height === 4);
  const image = layerCanvas.ctx.lastPutImage;
  const pixel = (x, y) => [...image.data.slice((y * 4 + x) * 4, (y * 4 + x) * 4 + 4)];
  assert.deepEqual(pixel(0, 0), [0, 0, 0, 0]);
  assert.deepEqual(pixel(1, 1), [255, 0, 0, 255]);
  assert.deepEqual(pixel(2, 2), [255, 0, 0, 255]);
  assert.deepEqual(pixel(3, 3), [0, 0, 0, 0]);

  // Auto-fit scales the 4x4 viewport to the 128x128 canvas (zoom 32).
  const layerDraw = canvas.ctx.calls.findLast(call => call.name === "drawImage");
  assert.deepEqual(layerDraw.args.slice(1), [0, 0, 128, 128]);

  // Pointer down at (64,64) maps to layer point (2,2): a 0x82 position
  // packet fused with a 0x83 button-down packet.
  renderer.handleInput({ action: "pointerdown", x: 64, y: 64 });
  assert.deepEqual(packets.at(-1), [0x82, 2, 0, 2, 0, 0, 0x83, 0x01, 1]);
  renderer.handleInput({ action: "pointerup", x: 64, y: 64 });
  assert.deepEqual(packets.at(-1), [0x82, 2, 0, 2, 0, 0, 0x83, 0x01, 0]);

  // Wheel zoom-in shrinks the map cell under the cursor.
  renderer.handleInput({ action: "wheel", x: 0, y: 0, deltaY: -100 });
  renderer.handleInput({ action: "pointermove", x: 64, y: 64 });
  assert.deepEqual(packets.at(-1).slice(0, 5), [0x82, 1, 0, 1, 0]);

  // Double click restores auto-fit.
  renderer.handleInput({ action: "dblclick", x: 64, y: 64 });
  await tick();
  renderer.handleInput({ action: "pointermove", x: 64, y: 64 });
  assert.deepEqual(packets.at(-1).slice(0, 5), [0x82, 2, 0, 2, 0]);

  // Resize with a device pixel ratio scales the backing store.
  renderer.resize(100, 50, 2);
  assert.equal(canvas.width, 200);
  assert.equal(canvas.height, 100);

  // Debug snapshots deliver sprite previews as transferable bitmaps.
  const snapshots = [];
  const rendererDebug = R.create({
    canvas: new StubOffscreenCanvas(64, 64),
    width: 64,
    height: 64,
    onDebug: (snapshot, transfers) => snapshots.push({ snapshot, transfers })
  });
  rendererDebug.ingest(bytes(spritePacket(3, 1, 1, fill(1, 0, 255, 0, 255), "green")));
  rendererDebug.setDebug(true);
  assert.equal(snapshots.length, 1);
  assert.equal(snapshots[0].snapshot.sprites.length, 1);
  assert.equal(snapshots[0].snapshot.sprites[0].label, "green");
  assert.ok(snapshots[0].snapshot.sprites[0].bitmap.bitmap);
  assert.equal(snapshots[0].transfers.length, 1);
  rendererDebug.dispose();

  // Errors surface through onError instead of being swallowed.
  const errors = [];
  const rendererErrors = R.create({
    canvas: new StubOffscreenCanvas(8, 8),
    width: 8,
    height: 8,
    onError: error => errors.push(error)
  });
  rendererErrors.ingest(bytes([0x99]));
  assert.match(errors[0].message, /Unknown Sprite v1 packet type/);
  rendererErrors.dispose();

  // Dispose stops ingestion and rendering.
  const drawsBefore = draws;
  renderer.dispose();
  renderer.ingest(bytes(objectPacket(2, 0, 0, 0, 0, 7)));
  await tick();
  assert.equal(draws, drawsBefore);
  console.log("renderer lifecycle: ingest, draw, input, resize, debug, errors, dispose");
}

console.log("All sprite renderer tests passed");

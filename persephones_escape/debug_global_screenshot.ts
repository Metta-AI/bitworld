/**
 * Connects to the global viewer websocket, captures one composited frame,
 * writes it as a PNG to /tmp/global_screenshot.png.
 *
 * Usage: npx tsx debug_global_screenshot.ts [ws://localhost:8080/global]
 */

import WebSocket from "ws";
import { createCanvas } from "canvas";
import { writeFileSync } from "fs";

const url = process.argv[2] ?? "ws://localhost:8080/global";
const CANVAS_W = 1280;
const CANVAS_H = 720;

const palette = [
  [0,0,0,255],[194,195,199,255],[255,241,232,255],[255,0,77,255],
  [255,119,168,255],[95,87,79,255],[171,82,54,255],[255,163,0,255],
  [255,236,39,255],[126,37,83,255],[0,135,81,255],[0,228,54,255],
  [29,43,83,255],[131,118,156,255],[41,173,255,255],[255,204,170,255]
];

const ZoomableFlag = 1, UiFlag = 2, MapLayerType = 0;
const UiZoom = 3;

interface Layer {
  id: number; type: number; flags: number;
  width: number; height: number;
  image: Uint8ClampedArray | null;
}
interface Sprite { width: number; height: number; pixels: Uint8Array; }
interface Obj { id: number; x: number; y: number; z: number; layer: number; spriteId: number; }

const layers = new Map<number, Layer>();
const sprites = new Map<number, Sprite>();
const objects = new Map<number, Obj>();

function ensureLayer(id: number): Layer {
  let l = layers.get(id);
  if (!l) { l = { id, type: 0, flags: 0, width: 1, height: 1, image: null }; layers.set(id, l); }
  return l;
}

function parsePacket(buf: Buffer) {
  let i = 0;
  const u8 = () => buf[i++];
  const u16 = () => { const v = buf[i] | (buf[i+1] << 8); i += 2; return v; };
  const i16 = () => { let v = buf[i] | (buf[i+1] << 8); i += 2; if (v >= 0x8000) v -= 0x10000; return v; };

  while (i < buf.length) {
    const op = u8();
    switch (op) {
      case 0x01: { // addSprite
        const id = u16(); const w = u16(); const h = u16();
        const px = new Uint8Array(w * h);
        for (let j = 0; j < w * h; j++) px[j] = u8();
        sprites.set(id, { width: w, height: h, pixels: px });
        break;
      }
      case 0x02: { // addObject
        const id = u16(); const x = i16(); const y = i16();
        const z = i16(); const layer = u8(); const spriteId = u16();
        objects.set(id, { id, x, y, z, layer, spriteId });
        break;
      }
      case 0x03: { // removeObject
        objects.delete(u16());
        break;
      }
      case 0x04: { // clearAll
        sprites.clear(); objects.clear(); layers.clear();
        break;
      }
      case 0x05: { // setViewport
        const lid = u8(); const w = u16(); const h = u16();
        const l = ensureLayer(lid);
        l.width = w; l.height = h;
        l.image = new Uint8ClampedArray(w * h * 4);
        break;
      }
      case 0x06: { // defineLayer
        const lid = u8(); const type = u8(); const flags = u8();
        const l = ensureLayer(lid);
        l.type = type; l.flags = flags;
        break;
      }
      default:
        console.error(`Unknown opcode 0x${op.toString(16)} at offset ${i-1}`);
        return;
    }
  }
}

function putPixel(layer: Layer, x: number, y: number, color: number) {
  if (x < 0 || y < 0 || x >= layer.width || y >= layer.height || color === 0 || !layer.image) return;
  const rgba = palette[(color - 1) & 15];
  const offset = (y * layer.width + x) * 4;
  layer.image[offset] = rgba[0];
  layer.image[offset+1] = rgba[1];
  layer.image[offset+2] = rgba[2];
  layer.image[offset+3] = 255;
}

function layerScreenPos(layer: Layer) {
  const uiZoom = (layer.flags & UiFlag) !== 0 ? UiZoom : 1;
  const width = layer.width * uiZoom, height = layer.height * uiZoom;
  if ((layer.flags & ZoomableFlag) !== 0 || layer.type === MapLayerType) {
    // Auto-fit map to canvas center
    const scale = Math.min(CANVAS_W / layer.width, CANVAS_H / layer.height) * 0.8;
    const w = layer.width * scale, h = layer.height * scale;
    return { x: (CANVAS_W - w) / 2, y: (CANVAS_H - h) / 2, w, h };
  }
  switch (layer.type) {
    case 1: return { x: 0, y: 0, w: width, h: height };            // TopLeft
    case 2: return { x: CANVAS_W - width, y: 0, w: width, h: height }; // TopRight
    case 3: return { x: CANVAS_W - width, y: CANVAS_H - height, w: width, h: height }; // BottomRight
    case 4: return { x: 0, y: CANVAS_H - height, w: width, h: height }; // BottomLeft
    case 5: return { x: (CANVAS_W - width) / 2, y: 0, w: width, h: height }; // TopCenter
    case 6: return { x: CANVAS_W - width, y: (CANVAS_H - height) / 2, w: width, h: height }; // MiddleRight
    case 7: return { x: 0, y: (CANVAS_H - height) / 2, w: width, h: height }; // MiddleLeft
    case 8: return { x: (CANVAS_W - width) / 2, y: CANVAS_H - height, w: width, h: height }; // BottomCenter
    default: return { x: 0, y: 0, w: width, h: height };
  }
}

function renderFrame(): Buffer {
  const canvas = createCanvas(CANVAS_W, CANVAS_H);
  const ctx = canvas.getContext("2d");
  ctx.imageSmoothingEnabled = false;
  ctx.fillStyle = "black";
  ctx.fillRect(0, 0, CANVAS_W, CANVAS_H);

  const orderedLayers = [...layers.values()].sort((a, b) => a.type - b.type || a.id - b.id);
  for (const layer of orderedLayers) {
    if (!layer.image) continue;
    const objs = [...objects.values()].filter(o => o.layer === layer.id).sort((a, b) => a.z - b.z || a.y - b.y || a.id - b.id);
    if ((layer.flags & UiFlag) !== 0 && objs.length === 0) continue;

    layer.image.fill(0);
    for (const obj of objs) {
      const sprite = sprites.get(obj.spriteId);
      if (!sprite) continue;
      for (let y = 0; y < sprite.height; y++) {
        for (let x = 0; x < sprite.width; x++) {
          putPixel(layer, obj.x + x, obj.y + y, sprite.pixels[y * sprite.width + x]);
        }
      }
    }

    const layerCanvas = createCanvas(layer.width, layer.height);
    const layerCtx = layerCanvas.getContext("2d");
    const imgData = layerCtx.createImageData(layer.width, layer.height);
    imgData.data.set(layer.image);
    layerCtx.putImageData(imgData, 0, 0);

    const pos = layerScreenPos(layer);
    ctx.drawImage(layerCanvas, pos.x, pos.y, pos.w, pos.h);

    if ((layer.flags & UiFlag) !== 0) {
      ctx.strokeStyle = "rgba(255,255,255,0.8)";
      ctx.lineWidth = 1;
      ctx.strokeRect(Math.round(pos.x) + 0.5, Math.round(pos.y) + 0.5, Math.round(pos.w) - 1, Math.round(pos.h) - 1);
    }
  }

  return canvas.toBuffer("image/png");
}

// Connect and grab a frame after game starts
const ws = new WebSocket(url, { perMessageDeflate: false });
let frameCount = 0;

ws.on("message", (data: Buffer) => {
  parsePacket(data);
  frameCount++;
  // Wait a few frames for state to settle
  if (frameCount >= 5) {
    const png = renderFrame();
    writeFileSync("/tmp/global_screenshot.png", png);
    console.log(`Screenshot saved to /tmp/global_screenshot.png (${CANVAS_W}x${CANVAS_H}, ${layers.size} layers, ${sprites.size} sprites, ${objects.size} objects)`);
    for (const [id, l] of layers) {
      const objCount = [...objects.values()].filter(o => o.layer === id).length;
      console.log(`  Layer ${id}: type=${l.type} flags=${l.flags} ${l.width}x${l.height} (${objCount} objects)`);
    }
    ws.close();
    process.exit(0);
  }
});

ws.on("open", () => console.log("Connected to global viewer"));
ws.on("error", (e) => { console.error("Error:", e.message); process.exit(1); });
ws.on("close", () => process.exit(0));

setTimeout(() => { console.error("Timeout waiting for frames"); process.exit(1); }, 10000);

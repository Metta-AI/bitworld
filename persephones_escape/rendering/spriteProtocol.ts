import { Framebuffer } from "./framebuffer.js";
// @ts-ignore — no type declarations for snappyjs
import SnappyJS from "snappyjs";

// PICO-8 palette (matches player_client.html). Index 0 = transparent,
// indices 1-16 map to player_client palette entries 0-15.
const PALETTE_RGBA: Uint8Array[] = [
  Uint8Array.from([0, 0, 0, 0]),         // 0 = transparent (not in player palette)
  Uint8Array.from([0, 0, 0, 255]),       // 1 = black (player palette 0)
  Uint8Array.from([194, 195, 199, 255]), // 2 = light gray (player palette 1)
  Uint8Array.from([255, 241, 232, 255]), // 3 = white/cream (player palette 2)
  Uint8Array.from([255, 0, 77, 255]),    // 4 = red (player palette 3)
  Uint8Array.from([255, 119, 168, 255]), // 5 = pink (player palette 4)
  Uint8Array.from([95, 87, 79, 255]),    // 6 = dark gray (player palette 5)
  Uint8Array.from([171, 82, 54, 255]),   // 7 = brown (player palette 6)
  Uint8Array.from([255, 163, 0, 255]),   // 8 = orange (player palette 7)
  Uint8Array.from([255, 236, 39, 255]),  // 9 = yellow (player palette 8)
  Uint8Array.from([126, 37, 83, 255]),   // 10 = dark purple (player palette 9)
  Uint8Array.from([0, 135, 81, 255]),    // 11 = dark green (player palette 10)
  Uint8Array.from([0, 228, 54, 255]),    // 12 = green (player palette 11)
  Uint8Array.from([29, 43, 83, 255]),    // 13 = dark blue (player palette 12)
  Uint8Array.from([131, 118, 156, 255]), // 14 = lavender (player palette 13)
  Uint8Array.from([41, 173, 255, 255]),  // 15 = sky blue (player palette 14)
  Uint8Array.from([255, 204, 170, 255]), // 16 = peach (player palette 15)
];

export const LayerType = {
  Map: 0,
  TopLeft: 1,
  Interstitial: 2,
  BottomRight: 3,
  BottomLeft: 4,
  TopCenter: 5,
  RightCenter: 6,
  LeftCenter: 7,
  BottomCenter: 8,
} as const;

export const LayerFlag = {
  Zoomable: 1,
  Ui: 2,
  UiLarge: 6,  // includes Ui bit (2 | 4)
} as const;

export function spriteColor(paletteIndex: number): number {
  return (paletteIndex & 0x0f) + 1;
}

export class SpritePacket {
  private buf: number[] = [];

  private u8(v: number) { this.buf.push(v & 0xff); }
  private u16(v: number) { this.buf.push(v & 0xff, (v >> 8) & 0xff); }
  private i16(v: number) {
    const clamped = Math.max(-32768, Math.min(32767, v));
    const u = clamped < 0 ? clamped + 0x10000 : clamped;
    this.buf.push(u & 0xff, (u >> 8) & 0xff);
  }

  defineLayer(layerId: number, layerType: number, flags: number) {
    this.u8(0x06); this.u8(layerId); this.u8(layerType); this.u8(flags);
  }

  setViewport(layerId: number, width: number, height: number) {
    this.u8(0x05); this.u8(layerId); this.u16(width); this.u16(height);
  }

  clearAll() { this.u8(0x04); }

  private u32(v: number) {
    this.buf.push(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >>> 24) & 0xff);
  }

  addSprite(spriteId: number, width: number, height: number, pixels: Uint8Array, label: string = "") {
    const rgba = new Uint8Array(width * height * 4);
    for (let i = 0; i < width * height; i++) {
      const c = pixels[i] ?? 0;
      const entry = c < PALETTE_RGBA.length ? PALETTE_RGBA[c] : PALETTE_RGBA[0];
      rgba[i * 4] = entry[0];
      rgba[i * 4 + 1] = entry[1];
      rgba[i * 4 + 2] = entry[2];
      rgba[i * 4 + 3] = entry[3];
    }
    const compressed = SnappyJS.compress(rgba);
    const compressedBytes = new Uint8Array(compressed);

    this.u8(0x01); this.u16(spriteId); this.u16(width); this.u16(height);
    this.u32(compressedBytes.length);
    for (let i = 0; i < compressedBytes.length; i++) this.buf.push(compressedBytes[i]);
    const labelBytes = Buffer.from(label, "utf-8");
    this.u16(labelBytes.length);
    for (let i = 0; i < labelBytes.length; i++) this.buf.push(labelBytes[i]);
  }

  addObject(objectId: number, x: number, y: number, z: number, layerId: number, spriteId: number) {
    this.u8(0x02); this.u16(objectId); this.i16(x); this.i16(y); this.i16(z); this.u8(layerId); this.u16(spriteId);
  }

  deleteObject(objectId: number) { this.u8(0x03); this.u16(objectId); }

  toBuffer(): Buffer {
    return Buffer.from(this.buf);
  }
}

export function buildTextSprite(lines: string[], color: number): { width: number; height: number; pixels: Uint8Array } {
  const fb = new Framebuffer();
  let maxW = 1;
  for (const line of lines) maxW = Math.max(maxW, fb.measureText(line) + 1);
  const height = Math.max(1, lines.length * 7);
  const width = maxW;
  const pixels = new Uint8Array(width * height);

  for (let li = 0; li < lines.length; li++) {
    const baseY = li * 7;
    let x = 0;
    for (const ch of lines[li]) {
      if (ch === " ") { x += 4; continue; }
      const glyph = fb.glyphFor(ch);
      if (!glyph) continue;
      for (let gy = 0; gy < glyph.length; gy++) {
        for (let gx = 0; gx < glyph[gy].length; gx++) {
          if (glyph[gy][gx]) {
            const px = x + gx;
            const py = baseY + gy;
            if (px >= 0 && px < width && py >= 0 && py < height) {
              pixels[py * width + px] = spriteColor(color);
            }
          }
        }
      }
      x += glyph[0].length + 1;
    }
  }

  return { width, height, pixels };
}

export function buildFilledTextSprite(lines: { text: string; color: number }[], bgColor: number): { width: number; height: number; pixels: Uint8Array } {
  const fb = new Framebuffer();
  let maxW = 1;
  for (const line of lines) maxW = Math.max(maxW, fb.measureText(line.text) + 3);
  const height = Math.max(1, lines.length * 7 + 2);
  const width = maxW;
  const pixels = new Uint8Array(width * height);
  const bg = spriteColor(bgColor);
  pixels.fill(bg);

  for (let li = 0; li < lines.length; li++) {
    const baseY = li * 7 + 1;
    const { text, color } = lines[li];
    let x = 1;
    for (const ch of text) {
      if (ch === " ") { x += 4; continue; }
      const glyph = fb.glyphFor(ch);
      if (!glyph) continue;
      for (let gy = 0; gy < glyph.length; gy++) {
        for (let gx = 0; gx < glyph[gy].length; gx++) {
          if (glyph[gy][gx]) {
            const px = x + gx;
            const py = baseY + gy;
            if (px >= 0 && px < width && py >= 0 && py < height) {
              pixels[py * width + px] = spriteColor(color);
            }
          }
        }
      }
      x += glyph[0].length + 1;
    }
  }

  return { width, height, pixels };
}

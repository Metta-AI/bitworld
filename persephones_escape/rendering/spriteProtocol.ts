import { Framebuffer } from "./framebuffer.js";

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

  addSprite(spriteId: number, width: number, height: number, pixels: Uint8Array) {
    this.u8(0x01); this.u16(spriteId); this.u16(width); this.u16(height);
    for (let i = 0; i < pixels.length; i++) this.buf.push(pixels[i]);
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

import type { uint8 } from "./types.js";
import { SCREEN_WIDTH, SCREEN_HEIGHT, PROTOCOL_BYTES } from "./constants.js";

function f(rows: string[]): number[][] {
  return rows.map((r) => [...r].map((c) => (c === "#" ? 1 : 0)));
}

export const FONT: Record<string, number[][]> = {
  A: f(["###", "#.#", "###", "#.#", "#.#"]),
  B: f(["##.", "#.#", "##.", "#.#", "##."]),
  C: f(["###", "#..", "#..", "#..", "###"]),
  D: f(["##.", "#.#", "#.#", "#.#", "##."]),
  E: f(["###", "#..", "##.", "#..", "###"]),
  F: f(["###", "#..", "##.", "#..", "#.."]),
  G: f(["###", "#..", "#.#", "#.#", "###"]),
  H: f(["#.#", "#.#", "###", "#.#", "#.#"]),
  I: f(["###", ".#.", ".#.", ".#.", "###"]),
  J: f(["..#", "..#", "..#", "#.#", "###"]),
  K: f(["#.#", "#.#", "##.", "#.#", "#.#"]),
  L: f(["#..", "#..", "#..", "#..", "###"]),
  M: f(["#.#", "###", "#.#", "#.#", "#.#"]),
  N: f(["#.#", "###", "###", "#.#", "#.#"]),
  O: f(["###", "#.#", "#.#", "#.#", "###"]),
  P: f(["###", "#.#", "###", "#..", "#.."]),
  Q: f(["###", "#.#", "#.#", "###", "..#"]),
  R: f(["###", "#.#", "##.", "#.#", "#.#"]),
  S: f(["###", "#..", "###", "..#", "###"]),
  T: f(["###", ".#.", ".#.", ".#.", ".#."]),
  U: f(["#.#", "#.#", "#.#", "#.#", "###"]),
  V: f(["#.#", "#.#", "#.#", "#.#", ".#."]),
  W: f(["#.#", "#.#", "#.#", "###", "#.#"]),
  X: f(["#.#", "#.#", ".#.", "#.#", "#.#"]),
  Y: f(["#.#", "#.#", "###", ".#.", ".#."]),
  Z: f(["###", "..#", ".#.", "#..", "###"]),
  "0": f(["###", "#.#", "#.#", "#.#", "###"]),
  "1": f([".#.", "##.", ".#.", ".#.", "###"]),
  "2": f(["###", "..#", "###", "#..", "###"]),
  "3": f(["###", "..#", "###", "..#", "###"]),
  "4": f(["#.#", "#.#", "###", "..#", "..#"]),
  "5": f(["###", "#..", "###", "..#", "###"]),
  "6": f(["###", "#..", "###", "#.#", "###"]),
  "7": f(["###", "..#", "..#", "..#", "..#"]),
  "8": f(["###", "#.#", "###", "#.#", "###"]),
  "9": f(["###", "#.#", "###", "..#", "###"]),
  ":": f(["...", ".#.", "...", ".#.", "..."]),
  "!": f([".#.", ".#.", ".#.", "...", ".#."]),
  "?": f(["###", "..#", ".##", "...", ".#."]),
  "'": f([".#.", ".#.", "...", "...", "..."]),
  ".": f(["...", "...", "...", "...", ".#."]),
  ",": f(["...", "...", "...", ".#.", "#.."]),
  "-": f(["...", "...", "###", "...", "..."]),
  "/": f(["..#", "..#", ".#.", "#..", "#.."]),
  "*": f(["...", "#.#", ".#.", "#.#", "..."]),
  "(": f([".#.", "#..", "#..", "#..", ".#."]),
  ")": f([".#.", "..#", "..#", "..#", ".#."]),
  "<": f(["..#", ".#.", "#..", ".#.", "..#"]),
  ">": f(["#..", ".#.", "..#", ".#.", "#.."]),
};

export class Framebuffer {
  indices: Uint8Array;
  packed: Buffer;

  constructor() {
    this.indices = new Uint8Array(SCREEN_WIDTH * SCREEN_HEIGHT);
    this.packed = Buffer.alloc(PROTOCOL_BYTES);
  }

  clear(bg: uint8) {
    this.indices.fill(bg);
  }

  putPixel(x: number, y: number, color: uint8) {
    if (x < 0 || y < 0 || x >= SCREEN_WIDTH || y >= SCREEN_HEIGHT) return;
    this.indices[y * SCREEN_WIDTH + x] = color & 0x0f;
  }

  getPixel(x: number, y: number): uint8 {
    if (x < 0 || y < 0 || x >= SCREEN_WIDTH || y >= SCREEN_HEIGHT) return 0;
    return this.indices[y * SCREEN_WIDTH + x];
  }

  pack(): Buffer {
    for (let i = 0; i < PROTOCOL_BYTES; i++) {
      const lo = this.indices[i * 2] & 0x0f;
      const hi = this.indices[i * 2 + 1] & 0x0f;
      this.packed[i] = lo | (hi << 4);
    }
    return this.packed;
  }

  fillRect(x: number, y: number, w: number, h: number, color: uint8) {
    const x0 = Math.max(0, x);
    const y0 = Math.max(0, y);
    const x1 = Math.min(SCREEN_WIDTH, x + w);
    const y1 = Math.min(SCREEN_HEIGHT, y + h);
    for (let py = y0; py < y1; py++) {
      for (let px = x0; px < x1; px++) {
        this.indices[py * SCREEN_WIDTH + px] = color & 0x0f;
      }
    }
  }

  drawRect(x: number, y: number, w: number, h: number, color: uint8) {
    for (let dx = 0; dx < w; dx++) {
      this.putPixel(x + dx, y, color);
      this.putPixel(x + dx, y + h - 1, color);
    }
    for (let dy = 0; dy < h; dy++) {
      this.putPixel(x, y + dy, color);
      this.putPixel(x + w - 1, y + dy, color);
    }
  }

  drawChar(ch: string, sx: number, sy: number, color: uint8) {
    const glyph = FONT[ch.toUpperCase()] ?? FONT[ch];
    if (!glyph) return;
    for (let row = 0; row < glyph.length; row++) {
      for (let col = 0; col < glyph[row].length; col++) {
        if (glyph[row][col]) {
          this.putPixel(sx + col, sy + row, color);
        }
      }
    }
  }

  drawText(text: string, sx: number, sy: number, color: uint8) {
    let x = sx;
    for (const ch of text) {
      if (ch === " ") { x += 4; continue; }
      const glyph = FONT[ch.toUpperCase()] ?? FONT[ch];
      if (!glyph) continue;
      this.drawChar(ch, x, sy, color);
      x += glyph[0].length + 1;
    }
  }

  glyphFor(ch: string): number[][] | undefined {
    return FONT[ch.toUpperCase()] ?? FONT[ch];
  }

  measureText(text: string): number {
    let w = 0;
    for (const ch of text) {
      if (ch === " ") { w += 4; continue; }
      const glyph = FONT[ch.toUpperCase()] ?? FONT[ch];
      if (!glyph) continue;
      w += glyph[0].length + 1;
    }
    return Math.max(0, w - 1);
  }
}

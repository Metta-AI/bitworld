// Sprite and text recognition for pixel buffers.
// Sprites are color-agnostic: categories (0, 1, 2, ...) represent structural
// roles, not specific palette indices. Two pixels match if they agree on
// same-vs-different category, not on a particular color value.

import { SPRITES, type Sprite7x7 } from "./sprites.js";

export interface PixelBuffer {
  pixels: Uint8Array;
  width: number;
  height: number;
}

export interface SpriteMatch {
  x: number;
  y: number;
  score: number;
  // Maps each sprite category to the palette index it resolved to.
  // e.g. { 1: 0, 2: 7 } means outline=black, fill=yellow.
  colors: Record<number, number>;
}

export type RecognitionResult = Map<string, SpriteMatch[]>;

// Constraints callers can pin on sprite categories.
// "skip" means that category is transparent — don't match it at all.
// A number pins that category to a specific palette index.
export type CategoryConstraints = Record<number, number | "skip">;

function getPixel(buf: PixelBuffer, x: number, y: number): number {
  if (x < 0 || y < 0 || x >= buf.width || y >= buf.height) return 0;
  return buf.pixels[y * buf.width + x];
}

function collectCategories(sprite: Sprite7x7): Set<number> {
  const cats = new Set<number>();
  for (const row of sprite) {
    for (const v of row) cats.add(v);
  }
  return cats;
}

function matchSpriteAt(
  buf: PixelBuffer,
  sprite: Sprite7x7,
  sx: number,
  sy: number,
  constraints: CategoryConstraints,
): { score: number; colors: Record<number, number> } | null {
  const h = sprite.length;
  const w = sprite[0].length;
  const cats = collectCategories(sprite);

  // Build list of active (non-skipped) categories
  const activeCats: number[] = [];
  for (const c of cats) {
    if (constraints[c] === "skip") continue;
    activeCats.push(c);
  }
  if (activeCats.length === 0) return null;

  // Collect pixel values per category
  const catPixels: Map<number, number[]> = new Map();
  for (const c of activeCats) catPixels.set(c, []);

  for (let dy = 0; dy < h; dy++) {
    for (let dx = 0; dx < w; dx++) {
      const sv = sprite[dy][dx];
      if (constraints[sv] === "skip") continue;
      catPixels.get(sv)!.push(getPixel(buf, sx + dx, sy + dy));
    }
  }

  // Resolve each category to its best palette index
  const resolved: Record<number, number> = {};
  const usedColors = new Set<number>();

  // If a category is pinned by constraint, lock it in first
  for (const c of activeCats) {
    const pin = constraints[c];
    if (typeof pin === "number") {
      resolved[c] = pin;
      usedColors.add(pin);
    }
  }

  // For unpinned categories, pick the most frequent palette index in their
  // pixels that hasn't been claimed by another category.
  // Sort categories by pixel count descending so larger categories get first pick.
  const unpinned = activeCats
    .filter((c) => resolved[c] === undefined)
    .sort((a, b) => catPixels.get(b)!.length - catPixels.get(a)!.length);

  for (const c of unpinned) {
    const counts = new Uint16Array(16);
    for (const px of catPixels.get(c)!) counts[px]++;

    let bestColor = -1;
    let bestCount = 0;
    for (let i = 0; i < 16; i++) {
      if (usedColors.has(i)) continue;
      if (counts[i] > bestCount) {
        bestColor = i;
        bestCount = counts[i];
      }
    }
    if (bestColor === -1) return null;
    resolved[c] = bestColor;
    usedColors.add(bestColor);
  }

  // Score: fraction of active pixels that match their resolved category color
  let matched = 0;
  let total = 0;
  for (let dy = 0; dy < h; dy++) {
    for (let dx = 0; dx < w; dx++) {
      const sv = sprite[dy][dx];
      if (constraints[sv] === "skip") continue;
      total++;
      const px = getPixel(buf, sx + dx, sy + dy);
      if (px === resolved[sv]) matched++;
    }
  }

  if (total === 0) return null;
  return { score: matched / total, colors: resolved };
}

export function recognizeSprites(
  buf: PixelBuffer,
  threshold: number,
  catalog?: Record<string, Sprite7x7>,
  constraints?: CategoryConstraints,
): RecognitionResult {
  const sprites = catalog ?? SPRITES;
  const cons = constraints ?? { 0: "skip" };
  const result: RecognitionResult = new Map();

  for (const [name, sprite] of Object.entries(sprites)) {
    const h = sprite.length;
    const w = sprite[0].length;
    const matches: SpriteMatch[] = [];

    for (let sy = 0; sy <= buf.height - h; sy++) {
      for (let sx = 0; sx <= buf.width - w; sx++) {
        const m = matchSpriteAt(buf, sprite, sx, sy, cons);
        if (m && m.score >= threshold) {
          matches.push({ x: sx, y: sy, score: m.score, colors: m.colors });
        }
      }
    }

    if (matches.length > 0) {
      result.set(name, matches);
    }
  }

  return result;
}

// --- Text recognition ---
// Font glyphs use binary masks (0=off, 1=on), so they have two categories.

export interface TextMatch {
  x: number;
  y: number;
  score: number;
  color: number;
}

export type TextRecognitionResult = Map<string, TextMatch[]>;

const FONT_ROWS: Record<string, number[][]> = {};

function initFont() {
  if (Object.keys(FONT_ROWS).length > 0) return;
  function f(rows: string[]): number[][] {
    return rows.map((r) => [...r].map((c) => (c === "#" ? 1 : 0)));
  }
  const defs: Record<string, string[]> = {
    A: ["###", "#.#", "###", "#.#", "#.#"],
    B: ["##.", "#.#", "##.", "#.#", "##."],
    C: ["###", "#..", "#..", "#..", "###"],
    D: ["##.", "#.#", "#.#", "#.#", "##."],
    E: ["###", "#..", "##.", "#..", "###"],
    F: ["###", "#..", "##.", "#..", "#.."],
    G: ["###", "#..", "#.#", "#.#", "###"],
    H: ["#.#", "#.#", "###", "#.#", "#.#"],
    I: ["###", ".#.", ".#.", ".#.", "###"],
    J: ["..#", "..#", "..#", "#.#", "###"],
    K: ["#.#", "#.#", "##.", "#.#", "#.#"],
    L: ["#..", "#..", "#..", "#..", "###"],
    M: ["#.#", "###", "#.#", "#.#", "#.#"],
    N: ["#.#", "###", "###", "#.#", "#.#"],
    O: ["###", "#.#", "#.#", "#.#", "###"],
    P: ["###", "#.#", "###", "#..", "#.."],
    Q: ["###", "#.#", "#.#", "###", "..#"],
    R: ["###", "#.#", "##.", "#.#", "#.#"],
    S: ["###", "#..", "###", "..#", "###"],
    T: ["###", ".#.", ".#.", ".#.", ".#."],
    U: ["#.#", "#.#", "#.#", "#.#", "###"],
    V: ["#.#", "#.#", "#.#", "#.#", ".#."],
    W: ["#.#", "#.#", "#.#", "###", "#.#"],
    X: ["#.#", "#.#", ".#.", "#.#", "#.#"],
    Y: ["#.#", "#.#", "###", ".#.", ".#."],
    Z: ["###", "..#", ".#.", "#..", "###"],
    "0": ["###", "#.#", "#.#", "#.#", "###"],
    "1": [".#.", "##.", ".#.", ".#.", "###"],
    "2": ["###", "..#", "###", "#..", "###"],
    "3": ["###", "..#", "###", "..#", "###"],
    "4": ["#.#", "#.#", "###", "..#", "..#"],
    "5": ["###", "#..", "###", "..#", "###"],
    "6": ["###", "#..", "###", "#.#", "###"],
    "7": ["###", "..#", "..#", "..#", "..#"],
    "8": ["###", "#.#", "###", "#.#", "###"],
    "9": ["###", "#.#", "###", "..#", "###"],
    ":": ["...", ".#.", "...", ".#.", "..."],
    "!": [".#.", ".#.", ".#.", "...", ".#."],
    "?": ["###", "..#", ".##", "...", ".#."],
    "'": [".#.", ".#.", "...", "...", "..."],
    ".": ["...", "...", "...", "...", ".#."],
    ",": ["...", "...", "...", ".#.", "#.."],
    "-": ["...", "...", "###", "...", "..."],
    "/": ["..#", "..#", ".#.", "#..", "#.."],
    "*": ["...", "#.#", ".#.", "#.#", "..."],
    "(": [".#.", "#..", "#..", "#..", ".#."],
    ")": [".#.", "..#", "..#", "..#", ".#."],
    "<": ["..#", ".#.", "#..", ".#.", "..#"],
    ">": ["#..", ".#.", "..#", ".#.", "#.."],
  };
  for (const [ch, rows] of Object.entries(defs)) {
    FONT_ROWS[ch] = f(rows);
  }
}

function matchGlyphAt(
  buf: PixelBuffer,
  glyph: number[][],
  sx: number,
  sy: number,
  pinColor?: number,
): { score: number; color: number } {
  const h = glyph.length;
  const w = glyph[0].length;

  let color: number;
  if (pinColor !== undefined) {
    color = pinColor;
  } else {
    const counts = new Uint16Array(16);
    for (let dy = 0; dy < h; dy++) {
      for (let dx = 0; dx < w; dx++) {
        if (glyph[dy][dx]) counts[getPixel(buf, sx + dx, sy + dy)]++;
      }
    }
    color = 0;
    let maxCount = 0;
    for (let c = 1; c < 16; c++) {
      if (counts[c] > maxCount) {
        color = c;
        maxCount = counts[c];
      }
    }
    if (color === 0) return { score: 0, color: 0 };
  }

  let matched = 0;
  let total = 0;
  for (let dy = 0; dy < h; dy++) {
    for (let dx = 0; dx < w; dx++) {
      total++;
      const px = getPixel(buf, sx + dx, sy + dy);
      if (glyph[dy][dx]) {
        if (px === color) matched++;
      } else {
        if (px !== color) matched++;
      }
    }
  }

  return { score: total > 0 ? matched / total : 0, color };
}

export function recognizeText(
  buf: PixelBuffer,
  threshold: number,
  charset?: Record<string, number[][]>,
  pinColor?: number,
): TextRecognitionResult {
  initFont();
  const glyphs = charset ?? FONT_ROWS;
  const result: TextRecognitionResult = new Map();

  for (const [ch, glyph] of Object.entries(glyphs)) {
    const h = glyph.length;
    const w = glyph[0].length;
    const matches: TextMatch[] = [];

    for (let sy = 0; sy <= buf.height - h; sy++) {
      for (let sx = 0; sx <= buf.width - w; sx++) {
        const { score, color } = matchGlyphAt(buf, glyph, sx, sy, pinColor);
        if (score >= threshold) {
          matches.push({ x: sx, y: sy, score, color });
        }
      }
    }

    if (matches.length > 0) {
      result.set(ch, matches);
    }
  }

  return result;
}

export function readTextAt(
  buf: PixelBuffer,
  x: number,
  y: number,
  maxLen: number,
  threshold: number,
  charset?: Record<string, number[][]>,
  pinColor?: number,
): string {
  initFont();
  const glyphs = charset ?? FONT_ROWS;
  let cx = x;
  let text = "";

  for (let i = 0; i < maxLen; i++) {
    let bestCh = "";
    let bestScore = threshold;
    let bestWidth = 0;

    for (const [ch, glyph] of Object.entries(glyphs)) {
      const w = glyph[0].length;
      if (cx + w > buf.width) continue;
      const { score } = matchGlyphAt(buf, glyph, cx, y, pinColor);
      if (score > bestScore) {
        bestScore = score;
        bestCh = ch;
        bestWidth = w;
      }
    }

    if (!bestCh) {
      let isSpace = true;
      for (let dy = 0; dy < 5; dy++) {
        for (let dx = 0; dx < 3; dx++) {
          if (getPixel(buf, cx + dx, y + dy) !== 0) {
            isSpace = false;
            break;
          }
        }
        if (!isSpace) break;
      }
      if (isSpace && cx + 4 <= buf.width) {
        text += " ";
        cx += 4;
        continue;
      }
      break;
    }

    text += bestCh;
    cx += bestWidth + 1;
  }

  return text.trim();
}

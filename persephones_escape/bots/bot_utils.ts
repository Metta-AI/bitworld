import {
  BUTTON_UP, BUTTON_DOWN, BUTTON_LEFT, BUTTON_RIGHT,
  BUTTON_A, BUTTON_B, BUTTON_SELECT,
  PACKET_INPUT, SCREEN_WIDTH, SCREEN_HEIGHT,
  ROOM_W, ROOM_H, PLAYER_W, PLAYER_H,
  BUBBLE_RADIUS, TARGET_FPS, BOTTOM_BAR_H,
  MINIMAP_SIZE, MINIMAP_X, MINIMAP_Y,
  CHAT_MAX_TOTAL,
} from "../game/constants.js";
import { Room } from "../game/types.js";
import WebSocket from "ws";

// ---------------------------------------------------------------------------
// Input helpers
// ---------------------------------------------------------------------------

export function sendInput(ws: WebSocket, mask: number) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(Buffer.from([PACKET_INPUT, mask & 0x7f]));
  }
}

export function sendChat(ws: WebSocket, text: string) {
  if (ws.readyState !== WebSocket.OPEN) return;
  const buf = Buffer.alloc(1 + text.length);
  buf[0] = 1; // PACKET_CHAT
  for (let i = 0; i < text.length; i++) buf[i + 1] = text.charCodeAt(i) & 0x7f;
  ws.send(buf);
}

/**
 * Truncate a chat message to the maximum that sim.chatRateCheck will accept
 * without dropping characters. Longer inputs are trimmed to CHAT_MAX_TOTAL.
 * Returns { sent, truncated } so callers can report the actual wire payload
 * and whether any content was dropped.
 */
export function truncateChatInput(text: string): { sent: string; truncated: boolean } {
  if (text.length <= CHAT_MAX_TOTAL) return { sent: text, truncated: false };
  return { sent: text.slice(0, CHAT_MAX_TOTAL), truncated: true };
}

// ---------------------------------------------------------------------------
// Frame unpacking
// ---------------------------------------------------------------------------

export const PACKED_FRAME_BYTES = (SCREEN_WIDTH * SCREEN_HEIGHT) / 2;

export function unpackFrame(packed: Buffer): Uint8Array {
  const pixels = new Uint8Array(SCREEN_WIDTH * SCREEN_HEIGHT);
  for (let i = 0; i < packed.length; i++) {
    pixels[i * 2] = packed[i] & 0x0f;
    pixels[i * 2 + 1] = packed[i] >> 4;
  }
  return pixels;
}

// ---------------------------------------------------------------------------
// Action queue — sequence of button masks to drain one per tick
// ---------------------------------------------------------------------------

export class ActionQueue {
  private queue: number[] = [];

  get length() { return this.queue.length; }
  get empty() { return this.queue.length === 0; }

  push(...masks: number[]) { this.queue.push(...masks); }
  clear() { this.queue.length = 0; }

  shift(): number | undefined { return this.queue.shift(); }

  pushWithGaps(...masks: number[]) {
    for (const m of masks) {
      this.queue.push(m);
      this.queue.push(0); // release frame so the sim sees a rising edge
    }
  }
}

// ---------------------------------------------------------------------------
// Menu system — re-export from menu_defs for bot consumption
// ---------------------------------------------------------------------------

export { menuSequence, COMMAND_ACTIONS, MENU_DEFS } from "../game/menu_defs.js";
export type { MenuDef } from "../game/menu_defs.js";

// ---------------------------------------------------------------------------
// Hostage selection — builds action sequences for leaders during HostageSelect
// Hostage picker is inside global chat: A toggles, B commits, SELECT closes
// ---------------------------------------------------------------------------

export function hostageSelectSequence(targetIndices: number[], eligible: number[]): number[] {
  const seq: number[] = [];
  let cursor = 0;
  for (const target of targetIndices) {
    const targetPos = eligible.indexOf(target);
    if (targetPos < 0) continue;
    const delta = targetPos - cursor;
    if (delta > 0) {
      for (let i = 0; i < delta; i++) seq.push(BUTTON_RIGHT, 0);
    } else if (delta < 0) {
      for (let i = 0; i < -delta; i++) seq.push(BUTTON_LEFT, 0);
    }
    seq.push(BUTTON_A, 0);
    cursor = targetPos;
  }
  seq.push(BUTTON_B, 0);
  return seq;
}

// ---------------------------------------------------------------------------
// Pathfinding — BFS on the room's wall map to find a path between two points
// Returns a list of {x, y} waypoints (pixel coordinates), or null if no path.
// Uses a coarse grid (step size = PLAYER_W) for performance.
// ---------------------------------------------------------------------------

export interface Point { x: number; y: number; }

const PATH_STEP = PLAYER_W;

export function findPath(
  wallMap: Uint8Array,
  from: Point,
  to: Point,
  roomW = ROOM_W,
  roomH = ROOM_H,
): Point[] | null {
  const gridW = Math.ceil(roomW / PATH_STEP);
  const gridH = Math.ceil(roomH / PATH_STEP);

  const startGx = Math.floor(from.x / PATH_STEP);
  const startGy = Math.floor(from.y / PATH_STEP);
  const endGx = clamp(Math.floor(to.x / PATH_STEP), 0, gridW - 1);
  const endGy = clamp(Math.floor(to.y / PATH_STEP), 0, gridH - 1);

  if (startGx === endGx && startGy === endGy) return [to];

  function blocked(gx: number, gy: number): boolean {
    const px = gx * PATH_STEP;
    const py = gy * PATH_STEP;
    for (let dy = 0; dy < PLAYER_H; dy++) {
      for (let dx = 0; dx < PLAYER_W; dx++) {
        const wx = px + dx, wy = py + dy;
        if (wx < 0 || wy < 0 || wx >= roomW || wy >= roomH) return true;
        if (wallMap[wy * roomW + wx]) return true;
      }
    }
    return false;
  }

  const visited = new Uint8Array(gridW * gridH);
  const parent = new Int32Array(gridW * gridH).fill(-1);
  const queue: number[] = [];
  const startIdx = startGy * gridW + startGx;
  visited[startIdx] = 1;
  queue.push(startIdx);

  const DX = [0, 0, -1, 1];
  const DY = [-1, 1, 0, 0];

  let found = false;
  const endIdx = endGy * gridW + endGx;

  while (queue.length > 0) {
    const cur = queue.shift()!;
    const cx = cur % gridW;
    const cy = Math.floor(cur / gridW);

    for (let d = 0; d < 4; d++) {
      const nx = cx + DX[d], ny = cy + DY[d];
      if (nx < 0 || ny < 0 || nx >= gridW || ny >= gridH) continue;
      const ni = ny * gridW + nx;
      if (visited[ni]) continue;
      if (blocked(nx, ny)) { visited[ni] = 1; continue; }
      visited[ni] = 1;
      parent[ni] = cur;
      if (ni === endIdx) { found = true; break; }
      queue.push(ni);
    }
    if (found) break;
  }

  if (!found) return null;

  const path: Point[] = [];
  let idx = endIdx;
  while (idx !== startIdx && idx >= 0) {
    const gx = idx % gridW;
    const gy = Math.floor(idx / gridW);
    path.push({ x: gx * PATH_STEP, y: gy * PATH_STEP });
    idx = parent[idx];
  }
  path.reverse();
  // Replace the last point with the exact target
  if (path.length > 0) path[path.length - 1] = { x: to.x, y: to.y };
  return path;
}

// ---------------------------------------------------------------------------
// Movement — converts a target position into directional button masks
// ---------------------------------------------------------------------------

export function moveToward(px: number, py: number, tx: number, ty: number): number {
  const dx = tx - px;
  const dy = ty - py;
  let mask = 0;
  if (Math.abs(dx) > 2) mask |= dx < 0 ? BUTTON_LEFT : BUTTON_RIGHT;
  if (Math.abs(dy) > 2) mask |= dy < 0 ? BUTTON_UP : BUTTON_DOWN;
  return mask;
}

export function moveTowardPlayer(
  me: { x: number; y: number },
  target: { x: number; y: number },
): number {
  return moveToward(me.x, me.y, target.x, target.y);
}

export function distTo(a: Point, b: Point): number {
  return Math.sqrt((a.x - b.x) ** 2 + (a.y - b.y) ** 2);
}

export function isNearby(a: Point, b: Point): boolean {
  return distTo(a, b) <= BUBBLE_RADIUS;
}

// ---------------------------------------------------------------------------
// Random direction for wandering
// ---------------------------------------------------------------------------

const DIRS = [
  BUTTON_UP, BUTTON_DOWN, BUTTON_LEFT, BUTTON_RIGHT,
  BUTTON_UP | BUTTON_LEFT, BUTTON_UP | BUTTON_RIGHT,
  BUTTON_DOWN | BUTTON_LEFT, BUTTON_DOWN | BUTTON_RIGHT,
];

export function randomDir(): number {
  return DIRS[Math.floor(Math.random() * DIRS.length)];
}

export function randomPoint(room: Room, roomW = ROOM_W, roomH = ROOM_H): Point {
  const margin = PLAYER_W + 2;
  return {
    x: margin + Math.floor(Math.random() * (roomW - 2 * margin)),
    y: margin + Math.floor(Math.random() * (roomH - 2 * margin)),
  };
}

export function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

// ---------------------------------------------------------------------------
// Self-positioning — reads the frame to estimate world coordinates
//
// 1. Detect room from floor colors near screen center.
// 2. Find the player's white dot (color 2) on the minimap for coarse
//    world position (±half a minimap cell = ±6px at 240/20).
// 3. Find any 2x2 alt-color floor dot on screen. These sit on a fixed
//    DOT_GRID pixel grid. Using the coarse position to resolve which
//    tile the dot belongs to gives the exact camera offset.
// 4. Recover player world position from camera. When not at a room edge
//    the player is at screen center; at edges, fall back to minimap.
//
// Robust to bubble highlights, players, walls, and fog obscuring some
// dots — only one visible dot is needed, and ~25 are in the viewport.
// ---------------------------------------------------------------------------

export const DOT_GRID = 24;
const DOT_OFFSET = 11;

export interface Position {
  room: Room;
  x: number;
  y: number;
}

const ROOM_A_BASE = 12;
const ROOM_A_ALT = 6;
const ROOM_B_BASE = 9;
const ROOM_B_ALT = 10;
const TOP_BAR = 9;
const HALF_W = Math.floor(SCREEN_WIDTH / 2);
const PLAYER_CENTER_SCREEN_Y = 64;

export function readPosition(frame: Uint8Array, roomW = ROOM_W, roomH = ROOM_H): Position | null {
  const room = detectRoom(frame);
  if (room === null) return null;

  const coarse = readMinimapPlayerDot(frame, roomW, roomH);
  if (!coarse) return null;

  const alt = room === Room.RoomA ? ROOM_A_ALT : ROOM_B_ALT;
  const dot = findFloorDot(frame, alt);

  if (!dot) {
    return { room, x: coarse.x - Math.floor(PLAYER_W / 2), y: coarse.y - Math.floor(PLAYER_H / 2) };
  }

  const maxCamX = Math.max(0, roomW - SCREEN_WIDTH);
  const maxCamY = Math.max(-TOP_BAR, roomH - SCREEN_HEIGHT + BOTTOM_BAR_H);
  const approxCamX = clamp(coarse.x - HALF_W, 0, maxCamX);
  const approxCamY = clamp(coarse.y - PLAYER_CENTER_SCREEN_Y, -TOP_BAR, maxCamY);

  const dotWorldXApprox = approxCamX + dot.sx;
  const dotWorldYApprox = approxCamY + dot.sy;
  const tileNx = Math.round((dotWorldXApprox - DOT_OFFSET) / DOT_GRID);
  const tileNy = Math.round((dotWorldYApprox - DOT_OFFSET) / DOT_GRID);
  const exactCamX = tileNx * DOT_GRID + DOT_OFFSET - dot.sx;
  const exactCamY = tileNy * DOT_GRID + DOT_OFFSET - dot.sy;
  const pcx = (exactCamX > 0 && exactCamX < maxCamX)
    ? exactCamX + HALF_W
    : coarse.x;
  const pcy = (exactCamY > -TOP_BAR && exactCamY < maxCamY)
    ? exactCamY + PLAYER_CENTER_SCREEN_Y
    : coarse.y;

  return {
    room,
    x: pcx - Math.floor(PLAYER_W / 2),
    y: pcy - Math.floor(PLAYER_H / 2),
  };
}

function detectRoom(frame: Uint8Array): Room | null {
  const cx = HALF_W;
  const cy = Math.floor((SCREEN_HEIGHT + TOP_BAR - BOTTOM_BAR_H) / 2);
  let aCount = 0, bCount = 0;
  for (let dy = -6; dy <= 6; dy++) {
    for (let dx = -6; dx <= 6; dx++) {
      const sx = cx + dx, sy = cy + dy;
      if (sx < 0 || sy < TOP_BAR || sx >= SCREEN_WIDTH || sy >= SCREEN_HEIGHT - BOTTOM_BAR_H) continue;
      const c = frame[sy * SCREEN_WIDTH + sx];
      if (c === ROOM_A_BASE || c === ROOM_A_ALT) aCount++;
      if (c === ROOM_B_BASE || c === ROOM_B_ALT) bCount++;
    }
  }
  if (aCount > bCount && aCount >= 5) return Room.RoomA;
  if (bCount > aCount && bCount >= 5) return Room.RoomB;
  return null;
}

function readMinimapPlayerDot(frame: Uint8Array, roomW = ROOM_W, roomH = ROOM_H): Point | null {
  const cellW = roomW / MINIMAP_SIZE;
  const cellH = roomH / MINIMAP_SIZE;
  let dotMx = -1, dotMy = -1;
  for (let my = 0; my < MINIMAP_SIZE; my++) {
    for (let mx = 0; mx < MINIMAP_SIZE; mx++) {
      if (frame[(MINIMAP_Y + my) * SCREEN_WIDTH + MINIMAP_X + mx] === 2) {
        dotMx = mx; dotMy = my;
      }
    }
  }
  if (dotMx < 0) return null;
  return {
    x: Math.floor(dotMx * cellW + cellW / 2),
    y: Math.floor(dotMy * cellH + cellH / 2),
  };
}

function findFloorDot(frame: Uint8Array, alt: number): { sx: number; sy: number } | null {
  const botLimit = SCREEN_HEIGHT - BOTTOM_BAR_H;
  const cx = HALF_W;
  const cy = Math.floor((TOP_BAR + botLimit) / 2);
  let bestDist = Infinity;
  let bestSx = -1, bestSy = -1;

  for (let sy = TOP_BAR; sy < botLimit - 1; sy++) {
    for (let sx = 0; sx < SCREEN_WIDTH - 1; sx++) {
      if (sx >= MINIMAP_X - 1 && sy <= MINIMAP_Y + MINIMAP_SIZE + 1) continue;
      const off = sy * SCREEN_WIDTH + sx;
      if (frame[off] !== alt) continue;
      if (frame[off + 1] !== alt) continue;
      if (frame[off + SCREEN_WIDTH] !== alt) continue;
      if (frame[off + SCREEN_WIDTH + 1] !== alt) continue;
      const d = (sx - cx) ** 2 + (sy - cy) ** 2;
      if (d < bestDist) { bestDist = d; bestSx = sx; bestSy = sy; }
    }
  }

  if (bestSx < 0) return null;
  return { sx: bestSx, sy: bestSy };
}

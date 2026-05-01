import {
  readTextAt as commonReadText,
  recognizeSprites,
  type PixelBuffer,
  type CategoryConstraints,
} from "../../common/spriteRecognition.js";
import {
  SCREEN_WIDTH, SCREEN_HEIGHT,
  ROOM_W, ROOM_H, MINIMAP_SIZE, MINIMAP_X, MINIMAP_Y,
  BOTTOM_BAR_H, PLAYER_W, PLAYER_H,
  PLAYER_SHAPES, PLAYER_COLORS,
  TEAM_A_COLOR, TEAM_B_COLOR,
  TEAM_A_NAME, TEAM_B_NAME,
  ROOM_A_NAME, ROOM_B_NAME,
  HADES_ROLE_NAME, PERSEPHONE_ROLE_NAME, CERBERUS_ROLE_NAME,
  DEMETER_ROLE_NAME, SHADES_ROLE_NAME, NYMPHS_ROLE_NAME,
} from "../game/constants.js";
import { Room, PlayerShape } from "../game/types.js";
import type { Point } from "./bot_utils.js";

// ---------------------------------------------------------------------------
// PixelBuffer adapter — wraps a raw frame for the common recognition library
// ---------------------------------------------------------------------------

export function frameToBuf(frame: Uint8Array): PixelBuffer {
  return { pixels: frame, width: SCREEN_WIDTH, height: SCREEN_HEIGHT };
}

function colorFilteredBuf(frame: Uint8Array, color: number): PixelBuffer {
  const filtered = new Uint8Array(frame.length);
  for (let i = 0; i < frame.length; i++) {
    filtered[i] = frame[i] === color ? color : 0;
  }
  return { pixels: filtered, width: SCREEN_WIDTH, height: SCREEN_HEIGHT };
}

// ---------------------------------------------------------------------------
// Text reading — delegates to common spriteRecognition
// ---------------------------------------------------------------------------

const GLYPH_THRESHOLD = 0.9;

export function readTextAt(
  frame: Uint8Array, sx: number, sy: number, color: number, maxChars = 30,
): string {
  const buf = colorFilteredBuf(frame, color);
  return commonReadText(buf, sx, sy, maxChars, GLYPH_THRESHOLD);
}

export function readTextAtAnyColor(
  frame: Uint8Array, sx: number, sy: number, maxChars = 30,
): { text: string; color: number } | null {
  if (sx >= SCREEN_WIDTH || sy >= SCREEN_HEIGHT) return null;
  const probe = frame[sy * SCREEN_WIDTH + sx];
  if (probe === 0) return null;
  const text = readTextAt(frame, sx, sy, probe, maxChars);
  if (text.length === 0) return null;
  return { text, color: probe };
}

// ---------------------------------------------------------------------------
// Phase detection
// ---------------------------------------------------------------------------

export type ParsedPhase =
  | "lobby" | "playing" | "hostage_select" | "hostage_exchange"
  | "role_reveal" | "reveal" | "game_over" | "info_screen"
  | "chatroom" | "waiting_entry" | "unknown";

// S/5 and O/0 have identical 3x5 glyphs — normalize for text comparison
function norm(s: string): string {
  return s.replace(/5/g, "S").replace(/0/g, "O");
}

export function parsePhase(frame: Uint8Array): ParsedPhase {
  const border0 = frame[0];
  const border2 = frame[2 * SCREEN_WIDTH + 2];
  if (border0 !== 0 && border2 !== 0 && border0 === border2) {
    const inner = frame[4 * SCREEN_WIDTH + 4];
    if (inner === 0) return "role_reveal";
  }

  const hudText = readTextAt(frame, 2, 2, 2);
  if (norm(hudText).startsWith("CHAT")) return "chatroom";

  // Check bottom-bar "WAITING..." indicator (means pendingChatroomEntry is set).
  // In this state, overworld is still shown but B/A actions will cancel/break.
  const barY = SCREEN_HEIGHT - BOTTOM_BAR_H;
  const barTxt = readTextAt(frame, 2, barY + 2, 8, 10);
  if (norm(barTxt).startsWith("WAITING")) return "waiting_entry";

  if (hudText.startsWith("R") && hudText.includes(":")) return "playing";
  if (hudText.match(/^\d+\/\d+/)) return "lobby";
  if (norm(hudText).startsWith("REVEAL")) return "reveal";

  const hudText8 = readTextAt(frame, 2, 2, 8);
  if (norm(hudText8).startsWith("SELECT")) return "hostage_select";
  if (norm(hudText8).startsWith("EXCHANGING")) return "hostage_exchange";

  const hudText1 = readTextAt(frame, 2, 2, 1);
  if (norm(hudText1).includes("PICK")) return "hostage_select";

  if (border0 !== 0 && border0 === border2) return "info_screen";

  return "unknown";
}

// ---------------------------------------------------------------------------
// HUD info parsing (Playing phase)
// ---------------------------------------------------------------------------

export interface HudInfo {
  round: number;
  timerSecs: number;
  roleName: string | null;
  roleColor: number;
}

// Convert ambiguous text back to digits for numeric parsing
function toDigits(s: string): string {
  return s.replace(/[OSos]/g, ch => ch === "O" || ch === "o" ? "0" : "5");
}

export function parsePlayingHud(frame: Uint8Array): HudInfo | null {
  const text = readTextAt(frame, 2, 2, 2, 15);
  const digitized = toDigits(text);
  const m = digitized.match(/^R(\d+)\s+(\d+):(\d+)/);
  if (!m) return null;

  const round = parseInt(m[1]);
  const timerSecs = parseInt(m[2]) * 60 + parseInt(m[3]);

  let roleName: string | null = null;
  let roleColor = 0;
  for (const color of [TEAM_A_COLOR, TEAM_B_COLOR]) {
    const maxRoleWidth = 11 * 4;
    const startX = SCREEN_WIDTH - MINIMAP_SIZE - 4 - maxRoleWidth;
    for (let x = Math.max(0, startX); x < SCREEN_WIDTH - MINIMAP_SIZE - 4; x++) {
      const t = readTextAt(frame, x, 2, color, 12);
      if (t.length >= 3) {
        roleName = t;
        roleColor = color;
        break;
      }
    }
    if (roleName) break;
  }

  return { round, timerSecs, roleName, roleColor };
}

// ---------------------------------------------------------------------------
// Role reveal screen parsing
// ---------------------------------------------------------------------------

export interface RoleRevealInfo {
  role: string;
  team: string;
  room: string;
  teamColor: number;
  playerCount: number;
  roomSize: number;
}

const ROLE_NAMES = [
  HADES_ROLE_NAME, PERSEPHONE_ROLE_NAME, CERBERUS_ROLE_NAME,
  DEMETER_ROLE_NAME, SHADES_ROLE_NAME, NYMPHS_ROLE_NAME,
].map(n => n.toUpperCase());

const TEAM_NAMES = [TEAM_A_NAME.toUpperCase(), TEAM_B_NAME.toUpperCase(), "NEUTRAL"];
const ROOM_NAMES = [ROOM_A_NAME.toUpperCase(), ROOM_B_NAME.toUpperCase()];

export function parseRoleRevealScreen(frame: Uint8Array): RoleRevealInfo | null {
  const borderColor = frame[0];
  if (borderColor === 0) return null;
  if (frame[2 * SCREEN_WIDTH + 2] !== borderColor) return null;
  if (frame[4 * SCREEN_WIDTH + 4] !== 0) return null;

  for (const baseY of [8, 12, 20]) {
    const youAre = readTextAt(frame, 0, baseY, 2, 20);
    const youAreNorm = norm(youAre).replace(/\s/g, "");
    if (!youAreNorm.includes("YOUARE")) {
      const centered = findCenteredText(frame, baseY, 2, "YOUARE");
      if (!centered) continue;
    }

    const roleY = baseY + 10;
    const role = findCenteredTextFromList(frame, roleY, borderColor, ROLE_NAMES);
    if (!role) continue;

    const teamY = roleY + 10;
    const teamText = findCenteredTextFromList(frame, teamY, borderColor,
      TEAM_NAMES.map(t => t + "TEAM"));

    let team = "UNKNOWN";
    if (teamText) {
      if (teamText.startsWith(TEAM_A_NAME.toUpperCase())) team = TEAM_A_NAME;
      else if (teamText.startsWith(TEAM_B_NAME.toUpperCase())) team = TEAM_B_NAME;
      else team = "Neutral";
    } else {
      team = borderColor === TEAM_A_COLOR ? TEAM_A_NAME : TEAM_B_NAME;
    }

    let room = "UNKNOWN";
    for (const roomY of [baseY + 42, baseY + 40, baseY + 38, baseY + 36, baseY + 34, baseY + 32]) {
      const r = findCenteredTextFromList(frame, roomY, 2, ROOM_NAMES);
      if (r) {
        room = r === ROOM_A_NAME.toUpperCase() ? ROOM_A_NAME : ROOM_B_NAME;
        break;
      }
    }

    const roleProper = matchProperCase(role, [
      HADES_ROLE_NAME, PERSEPHONE_ROLE_NAME, CERBERUS_ROLE_NAME,
      DEMETER_ROLE_NAME, SHADES_ROLE_NAME, NYMPHS_ROLE_NAME,
    ]);

    let playerCount = 0;
    let roomSize = 0;
    for (const infoY of [baseY + 48, baseY + 46, baseY + 44]) {
      for (let x = 0; x < SCREEN_WIDTH - 20; x++) {
        const infoText = readTextAt(frame, x, infoY, 1, 20);
        const m = toDigits(infoText).match(/(\d+)P\s+(\d+)[Xx](\d+)/);
        if (m) {
          playerCount = parseInt(m[1]);
          roomSize = parseInt(m[2]);
          break;
        }
      }
      if (roomSize > 0) break;
    }

    return { role: roleProper ?? role, team, room, teamColor: borderColor, playerCount, roomSize };
  }

  return null;
}

function findCenteredText(
  frame: Uint8Array, y: number, color: number, expected: string,
): boolean {
  for (let x = 0; x < SCREEN_WIDTH - 10; x++) {
    const t = readTextAt(frame, x, y, color, expected.length + 2);
    if (norm(t).replace(/\s/g, "").includes(expected)) return true;
  }
  return false;
}

function findCenteredTextFromList(
  frame: Uint8Array, y: number, color: number, candidates: string[],
): string | null {
  for (let x = 0; x < SCREEN_WIDTH - 6; x++) {
    const t = readTextAt(frame, x, y, color, 20);
    if (t.length < 2) continue;
    const clean = norm(t).replace(/\s/g, "");
    for (const c of candidates) {
      if (clean.startsWith(norm(c).replace(/\s/g, ""))) return c;
    }
  }
  return null;
}

function matchProperCase(upper: string, candidates: string[]): string | null {
  const u = upper.replace(/\s/g, "");
  for (const c of candidates) {
    if (c.toUpperCase().replace(/\s/g, "") === u) return c;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Minimap scanning — find player dots on the 20x20 minimap
// ---------------------------------------------------------------------------

export interface MinimapDot {
  color: number;
  mx: number;
  my: number;
  worldX: number;
  worldY: number;
  isSelf: boolean;
}

export function scanMinimapPlayers(frame: Uint8Array, selfRoom: Room, roomW = ROOM_W, roomH = ROOM_H): MinimapDot[] {
  const base = selfRoom === Room.RoomA ? 12 : 9;
  const excluded = new Set([0, 1, 5, base]);
  const cellW = roomW / MINIMAP_SIZE;
  const cellH = roomH / MINIMAP_SIZE;
  const dots: MinimapDot[] = [];

  for (let my = 0; my < MINIMAP_SIZE; my++) {
    for (let mx = 0; mx < MINIMAP_SIZE; mx++) {
      const px = MINIMAP_X + mx;
      const py = MINIMAP_Y + my;
      if (px >= SCREEN_WIDTH || py >= SCREEN_HEIGHT) continue;
      const c = frame[py * SCREEN_WIDTH + px];
      if (excluded.has(c)) continue;
      dots.push({
        color: c,
        mx, my,
        worldX: Math.floor(mx * cellW + cellW / 2),
        worldY: Math.floor(my * cellH + cellH / 2),
        isSelf: c === 2,
      });
    }
  }
  return dots;
}

// ---------------------------------------------------------------------------
// Shared info screen parsing — reads the structured "KNOWN PLAYERS" list
// ---------------------------------------------------------------------------

export interface InfoScreenEntry {
  playerColor: number;
  playerShape: PlayerShape | null;
  roleName: string | null;
  teamColor: number | null;
  isSelf: boolean;
  colorOnlyReveal: boolean;
}

const INFO_HEADER_Y = 2;
const INFO_ROW_START_Y = 12;
const INFO_ROW_H = 11;
const INFO_SPRITE_X = 4;
const INFO_TEXT_X = 15;
const INFO_MAX_ROWS = Math.floor((SCREEN_HEIGHT - 22) / INFO_ROW_H);
const SPRITE_MATCH_THRESHOLD = 0.75;
const SPRITE_CONSTRAINTS: CategoryConstraints = { 0: "skip", 1: 0 };

function matchShapeAt(
  frame: Uint8Array, sx: number, sy: number,
): { shape: PlayerShape; color: number } | null {
  const buf: PixelBuffer = { pixels: frame, width: SCREEN_WIDTH, height: SCREEN_HEIGHT };
  let bestShape: PlayerShape | null = null;
  let bestScore = SPRITE_MATCH_THRESHOLD;
  let bestColor = 0;

  const shapeEntries = Object.entries(PLAYER_SHAPES) as [string, number[][]][];
  for (const [key, pat] of shapeEntries) {
    const shapeIdx = parseInt(key);
    if (isNaN(shapeIdx)) continue;

    const catalog = { test: pat };
    const result = recognizeSprites(
      { pixels: frame.slice(0), width: SCREEN_WIDTH, height: SCREEN_HEIGHT },
      SPRITE_MATCH_THRESHOLD,
      catalog,
      SPRITE_CONSTRAINTS,
    );
    // Check at exact position only
    const matches = result.get("test");
    if (!matches) continue;
    for (const m of matches) {
      if (m.x === sx && m.y === sy && m.score > bestScore) {
        bestScore = m.score;
        bestShape = shapeIdx as PlayerShape;
        bestColor = m.colors[2] ?? 0;
      }
    }
  }

  if (bestShape === null) {
    // Fallback: just read the center pixel of the sprite area
    const centerIdx = (sy + 3) * SCREEN_WIDTH + (sx + 3);
    const c = frame[centerIdx];
    if (c !== 0 && c !== 1) return { shape: PlayerShape.Circle, color: c };
    return null;
  }
  return { shape: bestShape, color: bestColor };
}

export function parseInfoScreen(frame: Uint8Array): InfoScreenEntry[] | null {
  const headerText = norm(readTextAt(frame, 2, INFO_HEADER_Y, 2, 15));
  if (!headerText.startsWith("KNOWN")) return null;

  const entries: InfoScreenEntry[] = [];

  for (let row = 0; row < INFO_MAX_ROWS; row++) {
    const y = INFO_ROW_START_Y + row * INFO_ROW_H;

    const shapeMatch = matchShapeAt(frame, INFO_SPRITE_X, y);
    if (!shapeMatch || shapeMatch.color === 0) break;

    const textResult = readTextAtAnyColor(frame, INFO_TEXT_X, y + 2);

    let roleName: string | null = null;
    let teamColor: number | null = null;
    let colorOnlyReveal = false;

    if (textResult) {
      const cleaned = norm(textResult.text).trim();
      if (cleaned === "???" || cleaned === "???") {
        colorOnlyReveal = true;
        // Read team color from the role-slot dot at (sprite_x+3, y+PLAYER_H+1)
        const dotIdx = (y + PLAYER_H + 1) * SCREEN_WIDTH + (INFO_SPRITE_X + 3);
        const dotColor = frame[dotIdx];
        if (dotColor !== 0) teamColor = dotColor;
      } else if (cleaned.length >= 2) {
        roleName = matchProperCase(cleaned, [
          HADES_ROLE_NAME, PERSEPHONE_ROLE_NAME, CERBERUS_ROLE_NAME,
          DEMETER_ROLE_NAME, SHADES_ROLE_NAME, NYMPHS_ROLE_NAME,
        ]) ?? cleaned;
        teamColor = textResult.color;
      }
    }

    entries.push({
      playerColor: shapeMatch.color,
      playerShape: shapeMatch.shape,
      roleName,
      teamColor,
      isSelf: row === 0,
      colorOnlyReveal,
    });
  }

  return entries.length > 0 ? entries : null;
}

// ---------------------------------------------------------------------------
// Speech bubble detection — find players who are in a chatroom
// ---------------------------------------------------------------------------

// Bubble pattern (color 2, rendered at sx-3,sy-3 relative to player sprite):
//   2 2 2 0
//   2 2 2 0
//   0 0 0 2
const BUBBLE_COLOR = 2;

export function scanSpeechBubbles(frame: Uint8Array): { screenX: number; screenY: number }[] {
  const W = SCREEN_WIDTH;
  const H = SCREEN_HEIGHT;
  const results: { screenX: number; screenY: number }[] = [];
  const px = (x: number, y: number) => frame[y * W + x];

  for (let y = 0; y < H - 5; y++) {
    for (let x = 0; x < W - 4; x++) {
      if (px(x, y) !== BUBBLE_COLOR) continue;
      if (px(x + 1, y) !== BUBBLE_COLOR) continue;
      if (px(x + 2, y) !== BUBBLE_COLOR) continue;
      if (px(x + 3, y) === BUBBLE_COLOR) continue;
      if (px(x, y + 1) !== BUBBLE_COLOR) continue;
      if (px(x + 1, y + 1) !== BUBBLE_COLOR) continue;
      if (px(x + 2, y + 1) !== BUBBLE_COLOR) continue;
      if (px(x + 3, y + 1) === BUBBLE_COLOR) continue;
      if (px(x + 3, y + 2) !== BUBBLE_COLOR) continue;
      if (px(x, y + 2) === BUBBLE_COLOR) continue;
      if (px(x + 1, y + 2) === BUBBLE_COLOR) continue;
      if (px(x + 2, y + 2) === BUBBLE_COLOR) continue;
      // Player sprite top-left is at (x+3, y+3)
      results.push({ screenX: x + 3, screenY: y + 3 });
    }
  }
  return results;
}

// ---------------------------------------------------------------------------
// Chatroom pending-offer detection
// ---------------------------------------------------------------------------

export interface ChatroomStatus {
  pendingRoleOffer: boolean;
  pendingColorOffer: boolean;
  pendingEntry: boolean;
  occupantCount: number;
  occupantColors: number[];
}

/**
 * Read the last-shout strip rendered at y = SCREEN_HEIGHT - BOTTOM_BAR_H - 7.
 * Returns the raw text (without the "#" prefix) or null if none visible.
 * The text is drawn in the sender's player color, not a fixed color, so we scan
 * all non-background colors at that row.
 */
export function parseLastShout(frame: Uint8Array): string | null {
  const stripY = SCREEN_HEIGHT - BOTTOM_BAR_H - 7;
  // Marker: color-8 pixels at x=0, y in [stripY, stripY+2]
  let hasMarker = false;
  for (let y = stripY; y < stripY + 3; y++) {
    if (frame[y * SCREEN_WIDTH] === 8) { hasMarker = true; break; }
  }
  if (!hasMarker) return null;

  // Text starts at x=2 in the sender's player color. Find any non-bg color used
  // in this row (excluding the marker color 8 and black 0).
  const colors = new Set<number>();
  for (let x = 2; x < SCREEN_WIDTH; x++) {
    for (let y = stripY; y < stripY + 5; y++) {
      const c = frame[y * SCREEN_WIDTH + x];
      if (c !== 0 && c !== 8) colors.add(c);
    }
  }
  for (const c of colors) {
    const txt = readTextAt(frame, 2, stripY, c, 29);
    if (txt.length >= 2) return txt;
  }
  return null;
}

export function parseChatroomStatus(frame: Uint8Array): ChatroomStatus {
  // Offer indicators drawn in color 8 at (SCREEN_WIDTH - 10, barY + 2).
  const barY = SCREEN_HEIGHT - BOTTOM_BAR_H;
  const offerTxt = readTextAt(frame, SCREEN_WIDTH - 10, barY + 2, 8, 2);

  // Pending-entry indicator: renderer draws "!" at (2, reqY) in color 8, then
  // a sprite at (8, reqY), then "WANTS IN" at (17, reqY).
  // reqY = msgAreaBot - lineH = (barY - 1) - 7 = barY - 8.
  // Detect the "!" specifically: look for color-8 pixels in a small region
  // at x∈[2,4], y∈[barY-8, barY-4].
  let pendingEntry = false;
  for (let y = barY - 9; y <= barY - 3; y++) {
    for (let x = 2; x <= 4; x++) {
      if (frame[y * SCREEN_WIDTH + x] === 8) { pendingEntry = true; break; }
    }
    if (pendingEntry) break;
  }

  // Count occupant sprites in the top bar. They're drawn at x=22, 31, 40, ... (stride 9),
  // y=1..7 in the sprite's color. We detect by scanning the row for non-background pixels.
  const occupantColors: number[] = [];
  const topSpriteY = 4;  // middle of the 7-tall sprite row (y=1..7)
  for (let slot = 0; slot < 12; slot++) {
    const sx = 22 + slot * (PLAYER_W + 2);
    if (sx + PLAYER_W > SCREEN_WIDTH - 2) break;
    // Any non-zero pixel in the sprite bounding box signals an occupant.
    let color = 0;
    for (let dy = 0; dy < PLAYER_H; dy++) {
      for (let dx = 0; dx < PLAYER_W; dx++) {
        const c = frame[(1 + dy) * SCREEN_WIDTH + (sx + dx)];
        if (c !== 0 && c !== 1) { color = c; break; }
      }
      if (color !== 0) break;
    }
    if (color === 0) break;  // first empty slot = end of occupants
    occupantColors.push(color);
  }

  return {
    pendingRoleOffer: offerTxt.startsWith("R"),
    pendingColorOffer: offerTxt.startsWith("C"),
    pendingEntry,
    occupantCount: occupantColors.length,
    occupantColors,
  };
}

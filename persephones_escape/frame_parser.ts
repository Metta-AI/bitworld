import {
  readTextAt as commonReadText,
  type PixelBuffer,
} from "../common/spriteRecognition.js";
import {
  SCREEN_WIDTH, SCREEN_HEIGHT,
  ROOM_W, ROOM_H, MINIMAP_SIZE, MINIMAP_X, MINIMAP_Y,
  BOTTOM_BAR_H, PLAYER_W, PLAYER_H,
  TEAM_A_COLOR, TEAM_B_COLOR,
  TEAM_A_NAME, TEAM_B_NAME,
  ROOM_A_NAME, ROOM_B_NAME,
  HADES_ROLE_NAME, PERSEPHONE_ROLE_NAME, CERBERUS_ROLE_NAME,
  DEMETER_ROLE_NAME, SHADES_ROLE_NAME, NYMPHS_ROLE_NAME,
} from "./constants.js";
import { Room } from "./types.js";
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
  | "role_reveal" | "reveal" | "game_over" | "info_screen" | "unknown";

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

  for (const baseY of [12, 20]) {
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
    for (const roomY of [baseY + 32, baseY + 34]) {
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

    return { role: roleProper ?? role, team, room, teamColor: borderColor };
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

export function scanMinimapPlayers(frame: Uint8Array, selfRoom: Room): MinimapDot[] {
  const base = selfRoom === Room.RoomA ? 12 : 9;
  const excluded = new Set([0, 1, 5, base]);
  const cellW = ROOM_W / MINIMAP_SIZE;
  const cellH = ROOM_H / MINIMAP_SIZE;
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
// Nearby player detection — look for player sprites near screen center
// ---------------------------------------------------------------------------

export interface ScreenPlayer {
  screenX: number;
  screenY: number;
  color: number;
}

const FLOOR_COLORS = new Set([12, 9, 6, 10, 13, 0, 5]);

export function detectNearbyPlayers(frame: Uint8Array): ScreenPlayer[] {
  const topBar = 9;
  const botLimit = SCREEN_HEIGHT - BOTTOM_BAR_H;
  const players: ScreenPlayer[] = [];
  const seen = new Set<number>();

  for (let sy = topBar + 2; sy < botLimit - PLAYER_H; sy += 3) {
    for (let sx = 2; sx < SCREEN_WIDTH - PLAYER_W - 2; sx += 3) {
      if (sx >= MINIMAP_X - 2 && sy <= MINIMAP_Y + MINIMAP_SIZE + 2) continue;
      const c = frame[sy * SCREEN_WIDTH + sx];
      if (FLOOR_COLORS.has(c)) continue;
      if (c === 1) continue;
      let count = 0;
      for (let dy = 0; dy < PLAYER_H; dy++) {
        for (let dx = 0; dx < PLAYER_W; dx++) {
          if (frame[(sy + dy) * SCREEN_WIDTH + (sx + dx)] === c) count++;
        }
      }
      if (count >= 10) {
        const key = (sy >> 3) * 256 + (sx >> 3);
        if (!seen.has(key)) {
          seen.add(key);
          players.push({ screenX: sx, screenY: sy, color: c });
        }
      }
    }
  }
  return players;
}

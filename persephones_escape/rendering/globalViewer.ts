import type { Sim } from "../game/sim.js";
import { Phase, Role, Room, Team, PlayerShape } from "../game/types.js";
import type { Whisper } from "../game/types.js";
import {
  PLAYER_SHAPES, PLAYER_W, TARGET_FPS,
  ROOM_A_NAME, ROOM_B_NAME, LEADER_A_NAME, LEADER_B_NAME,
  TEAM_A_COLOR, TEAM_B_COLOR, playerSpriteName,
} from "../game/constants.js";
import { SpritePacket, LayerType, LayerFlag, spriteColor, buildFilledTextSprite } from "./spriteProtocol.js";
import { Framebuffer } from "./framebuffer.js";

// ---------------------------------------------------------------------------
// Sprite / object ID ranges
// ---------------------------------------------------------------------------

const ROOM_A_SPRITE = 0;
const ROOM_A_OBJECT = 0;
const ROOM_B_SPRITE = 1;
const ROOM_B_OBJECT = 1;
const PLAYER_ACCOUTREMENT_SPRITE_BASE = 100;
const PLAYER_ACCOUTREMENT_OBJECT_BASE = 100;
const PLAYER_BODY_SPRITE_BASE = 200;
const PLAYER_BODY_OBJECT_BASE = 200;
const HUD_SPRITE = 50;
const HUD_OBJECT = 50;
const LEGEND_SPRITE = 51;
const LEGEND_OBJECT = 51;

const SHOUT_A_SPRITE = 60;
const SHOUT_A_OBJECT = 60;
const SHOUT_B_SPRITE = 61;
const SHOUT_B_OBJECT = 61;

const VOTE_A_SPRITE = 62;
const VOTE_A_OBJECT = 62;
const VOTE_B_SPRITE = 63;
const VOTE_B_OBJECT = 63;

const CR_SLOT_SPRITE_BASE = 70;
const CR_SLOT_OBJECT_BASE = 70;
const CR_SLOTS = 3;


// ---------------------------------------------------------------------------
// Layer IDs
// ---------------------------------------------------------------------------

const MAP_LAYER = 0;
const HUD_LAYER = 1;
const SHOUT_A_LAYER = 2;   // TopLeft — Room A shout
const SHOUT_B_LAYER = 3;   // TopRight — Room B shout
const VOTE_A_LAYER = 4;    // BottomLeft — Room A leader/votes
const VOTE_B_LAYER = 5;    // BottomRight — Room B leader/votes
const CR_A_LAYER = 6;      // LeftCenter — Room A private whispers
const CR_B_LAYER = 7;      // RightCenter — Room B private whispers
const STATE_LAYER = 8;     // BottomCenter — legend + leaders

const GAP = 16;

// Fixed panel sizes (in sprite pixels, rendered at UiZoom=3 on client)
const SHOUT_PANEL_W = 128;
const SHOUT_PANEL_LINES = 10;
const VOTE_PANEL_W = 128;
const CR_SLOT_W = 128;
const CR_SLOT_H = 80;

// ---------------------------------------------------------------------------
// Main entry
// ---------------------------------------------------------------------------

export function buildGlobalFrame(sim: Sim): Buffer {
  const ROOM_W = sim.roomW;
  const ROOM_H = sim.roomH;
  const ROOM_B_OFFSET_X = ROOM_W + GAP;

  const pkt = new SpritePacket();
  const padX = 120;
  const padY = 80;

  pkt.clearAll();

  pkt.defineLayer(MAP_LAYER, LayerType.Map, LayerFlag.Zoomable);
  pkt.setViewport(MAP_LAYER, ROOM_W * 2 + GAP + padX * 2, ROOM_H + padY * 2);

  pkt.defineLayer(HUD_LAYER, LayerType.TopCenter, LayerFlag.Ui);
  pkt.defineLayer(SHOUT_A_LAYER, LayerType.TopLeft, LayerFlag.UiLarge);
  pkt.defineLayer(SHOUT_B_LAYER, LayerType.Interstitial, LayerFlag.UiLarge);
  pkt.defineLayer(VOTE_A_LAYER, LayerType.BottomLeft, LayerFlag.Ui);
  pkt.defineLayer(VOTE_B_LAYER, LayerType.BottomRight, LayerFlag.Ui);
  pkt.defineLayer(CR_A_LAYER, LayerType.LeftCenter, LayerFlag.Ui);
  pkt.defineLayer(CR_B_LAYER, LayerType.RightCenter, LayerFlag.Ui);
  pkt.defineLayer(STATE_LAYER, LayerType.BottomCenter, LayerFlag.Ui);

  // Map view
  if (sim.phase === Phase.PsychopompExchange) {
    buildExchangeView(sim, pkt, padX, padY, ROOM_W, ROOM_H, ROOM_B_OFFSET_X);
  } else {
    buildNormalMapView(sim, pkt, padX, padY, ROOM_B_OFFSET_X);
  }

  // HUD
  buildHud(sim, pkt);

  // Shout panels (top corners)
  buildShoutPanel(sim, pkt, Room.RoomA, SHOUT_A_LAYER, SHOUT_A_SPRITE, SHOUT_A_OBJECT);
  buildShoutPanel(sim, pkt, Room.RoomB, SHOUT_B_LAYER, SHOUT_B_SPRITE, SHOUT_B_OBJECT);

  // Vote panels (bottom corners)
  buildVotePanel(sim, pkt, Room.RoomA, VOTE_A_LAYER, VOTE_A_SPRITE, VOTE_A_OBJECT);
  buildVotePanel(sim, pkt, Room.RoomB, VOTE_B_LAYER, VOTE_B_SPRITE, VOTE_B_OBJECT);

  // Private whisper slots (side panels)
  buildWhisperSlots(sim, pkt, Room.RoomA, CR_A_LAYER, 0);
  buildWhisperSlots(sim, pkt, Room.RoomB, CR_B_LAYER, CR_SLOTS);

  // Legend
  buildLegend(sim, pkt);

  return pkt.toBuffer();
}

// ---------------------------------------------------------------------------
// Map views
// ---------------------------------------------------------------------------

function buildRoomSprite(sim: Sim, pkt: SpritePacket, room: Room, spriteId: number) {
  const rw = sim.roomW, rh = sim.roomH;
  const pixels = new Uint8Array(rw * rh);
  for (let my = 0; my < rh; my++) {
    for (let mx = 0; mx < rw; mx++) {
      const c = sim.isWallInRoom(room, mx, my) ? 5 : sim.floorColorAt(room, mx, my);
      pixels[my * rw + mx] = spriteColor(c);
    }
  }
  pkt.addSprite(spriteId, rw, rh, pixels);
}

// Sprite layout: 10 wide x 14 tall. Player shape at cols 3-9, rows 4-10.
// Bubble (when in whisper): L-shape at cols 0-3 rows 0-2 (one-pixel gap above
// player shape at row 3), matching renderer.ts at (sx-3..sx, sy-4..sy-2).
// Object is anchored at (p.x - PLAYER_SPRITE_OFFSET_X, p.y - PLAYER_SPRITE_OFFSET_Y).
const PLAYER_SPRITE_OFFSET_X = 3;
const PLAYER_SPRITE_OFFSET_Y = 4;

function buildPlayerAccoutrementSprite(sim: Sim, pkt: SpritePacket, pi: number, spriteId: number) {
  const p = sim.players[pi];
  const ind = sim.roleIndicator(p.role, p.team);
  const sw = 10, sh = 14;
  const shapeX = PLAYER_SPRITE_OFFSET_X;
  const shapeY = PLAYER_SPRITE_OFFSET_Y;
  const px = new Uint8Array(sw * sh);

  if (p.isLeader) {
    const cc = spriteColor(8);
    px[(shapeY - 3) * sw + (shapeX + 1)] = cc;
    px[(shapeY - 3) * sw + (shapeX + 3)] = cc;
    px[(shapeY - 3) * sw + (shapeX + 5)] = cc;
    px[(shapeY - 2) * sw + (shapeX + 2)] = cc;
    px[(shapeY - 2) * sw + (shapeX + 3)] = cc;
    px[(shapeY - 2) * sw + (shapeX + 4)] = cc;
  }

  const rc = spriteColor(ind.color);
  const barY0 = shapeY + 8;
  for (let dx = 1; dx <= 5; dx++) {
    px[barY0 * sw + (dx + shapeX)] = rc;
    px[(barY0 + 1) * sw + (dx + shapeX)] = rc;
  }
  if (ind.special) {
    const dot = spriteColor(p.role === Role.Hades || p.role === Role.EchoOfHades ? 8 : 2);
    px[barY0 * sw + (3 + shapeX)] = dot;
    px[(barY0 + 1) * sw + (3 + shapeX)] = dot;
  }

  if (p.inWhisper >= 0) {
    const bc = spriteColor(2);
    px[0 * sw + 0] = bc; px[0 * sw + 1] = bc; px[0 * sw + 2] = bc;
    px[1 * sw + 0] = bc; px[1 * sw + 1] = bc; px[1 * sw + 2] = bc;
    px[2 * sw + 3] = bc;
  }

  if (p.pendingWhisperEntry >= 0 && (sim.tickCount & 8)) {
    px[(shapeY - 1) * sw + (shapeX + 3)] = spriteColor(8);
  }

  if (p.selectedAsPsychopomp && sim.phase === Phase.PsychopompSelect) {
    const hc = spriteColor(8);
    px[(shapeY - 1) * sw + (shapeX + 0)] = hc;
    px[(shapeY - 1) * sw + (shapeX + 6)] = hc;
    px[(shapeY + 7) * sw + (shapeX + 0)] = hc;
    px[(shapeY + 7) * sw + (shapeX + 6)] = hc;
  }

  pkt.addSprite(spriteId, sw, sh, px);
}

function buildPlayerBodySprite(sim: Sim, pkt: SpritePacket, pi: number, spriteId: number) {
  const p = sim.players[pi];
  const color = sim.playerColor(pi);
  const sw = 10, sh = 14;
  const shapeX = PLAYER_SPRITE_OFFSET_X;
  const shapeY = PLAYER_SPRITE_OFFSET_Y;
  const px = new Uint8Array(sw * sh);
  const pat = PLAYER_SHAPES[p.shape];
  for (let dy = 0; dy < 7; dy++) {
    for (let dx = 0; dx < 7; dx++) {
      const v = pat[dy][dx];
      if (v === 1) px[(dy + shapeY) * sw + (dx + shapeX)] = spriteColor(0);
      else if (v === 2) px[(dy + shapeY) * sw + (dx + shapeX)] = spriteColor(color);
    }
  }
  pkt.addSprite(spriteId, sw, sh, px);
}

function buildNormalMapView(sim: Sim, pkt: SpritePacket, padX: number, padY: number, roomBOffX: number) {
  buildRoomSprite(sim, pkt, Room.RoomA, ROOM_A_SPRITE);
  pkt.addObject(ROOM_A_OBJECT, padX, padY, -100, 0, ROOM_A_SPRITE);

  buildRoomSprite(sim, pkt, Room.RoomB, ROOM_B_SPRITE);
  pkt.addObject(ROOM_B_OBJECT, padX + roomBOffX, padY, -100, 0, ROOM_B_SPRITE);

  for (let i = 0; i < sim.players.length; i++) {
    const p = sim.players[i];
    buildPlayerAccoutrementSprite(sim, pkt, i, PLAYER_ACCOUTREMENT_SPRITE_BASE + i);
    buildPlayerBodySprite(sim, pkt, i, PLAYER_BODY_SPRITE_BASE + i);
    const roomOffX = p.room === Room.RoomB ? roomBOffX : 0;
    const x = padX + roomOffX + p.x - PLAYER_SPRITE_OFFSET_X;
    const y = padY + p.y - PLAYER_SPRITE_OFFSET_Y;
    pkt.addObject(PLAYER_ACCOUTREMENT_OBJECT_BASE + i, x, y, i, 0, PLAYER_ACCOUTREMENT_SPRITE_BASE + i);
    pkt.addObject(PLAYER_BODY_OBJECT_BASE + i, x, y, 1000 + i, 0, PLAYER_BODY_SPRITE_BASE + i);
  }
}

function buildExchangeView(
  sim: Sim, pkt: SpritePacket,
  padX: number, padY: number,
  roomW: number, roomH: number, roomBOffX: number,
) {
  const fb = new Framebuffer();
  const lineH = 10;
  const spriteCol = 2;
  const textCol = PLAYER_W + 4;
  const w = 160;

  type Row = { text: string; color: number; pi?: number };
  const rows: Row[] = [];
  rows.push({ text: "PSYCHOPOMP EXCHANGE", color: 8 });
  rows.push({ text: "", color: 0 });

  const leaderA = sim.exchangeLeaderA;
  const leaderB = sim.exchangeLeaderB;
  if (leaderA >= 0) {
    rows.push({ text: `${ROOM_A_NAME} LEADER: ${sim.roleName(sim.players[leaderA].role)}`, color: TEAM_A_COLOR, pi: leaderA });
  }
  if (leaderB >= 0) {
    rows.push({ text: `${ROOM_B_NAME} LEADER: ${sim.roleName(sim.players[leaderB].role)}`, color: TEAM_B_COLOR, pi: leaderB });
  }
  rows.push({ text: "", color: 0 });

  for (const [label, psychopomps] of [
    [`LEAVING ${ROOM_A_NAME}:`, sim.exchangeFromA],
    [`LEAVING ${ROOM_B_NAME}:`, sim.exchangeFromB],
  ] as [string, typeof sim.exchangeFromA][]) {
    if (psychopomps.length > 0) {
      rows.push({ text: label, color: 8 });
      for (const h of psychopomps) {
        if (h.pi >= 0 && h.pi < sim.players.length) {
          rows.push({ text: sim.roleName(sim.players[h.pi].role), color: sim.playerColor(h.pi), pi: h.pi });
        }
      }
    }
  }

  const h = rows.length * lineH + 2;
  const pixels = new Uint8Array(w * h);

  let y = 1;
  for (const row of rows) {
    if (row.pi !== undefined && row.pi >= 0 && row.pi < sim.players.length) {
      const p = sim.players[row.pi];
      drawSmallSprite(pixels, w, spriteCol, y + 1, p.shape, sim.playerColor(row.pi));
      drawTextIntoPixels(fb, pixels, w, h, textCol, y + 2, row.text, row.color);
    } else if (row.text) {
      drawTextIntoPixels(fb, pixels, w, h, 2, y + 2, row.text, row.color);
    }
    y += lineH;
  }

  const totalW = roomW * 2 + (roomBOffX - roomW);
  pkt.addSprite(ROOM_A_SPRITE, w, h, pixels);
  pkt.addObject(ROOM_A_OBJECT,
    padX + Math.floor((totalW - w) / 2),
    padY + Math.floor((roomH - h) / 2),
    -100, 0, ROOM_A_SPRITE);
}

// ---------------------------------------------------------------------------
// HUD (top center)
// ---------------------------------------------------------------------------

function buildHud(sim: Sim, pkt: SpritePacket) {
  const secs = Math.ceil(sim.revealTimer / TARGET_FPS);
  const showSchedule = sim.phase === Phase.RoleReveal && sim.introPanel === 3;

  const lines: { text: string; color: number }[] = [];

  if (showSchedule) {
    lines.push({ text: "ROUND SCHEDULE", color: 2 });
    lines.push({ text: "ROUND  TIME  PSYCHOPOMP", color: 1 });
    const rounds = sim.config.rounds;
    for (let i = 0; i < Math.min(rounds.length, 5); i++) {
      const r = rounds[i];
      const mins = Math.floor(r.durationSecs / 60);
      const rsecs = r.durationSecs % 60;
      const timeStr = `${mins}:${rsecs.toString().padStart(2, "0")}`;
      lines.push({ text: `  ${i + 1}      ${timeStr}     ${r.psychopomps}`, color: 2 });
    }
    lines.push({ text: `STARTING IN ${secs}`, color: 2 });
  } else {
    const phaseText = Phase[sim.phase].toUpperCase();
    let hudText = `${phaseText}  P:${sim.players.length}`;
    if (sim.phase === Phase.Playing) {
      const roundSecs = Math.max(0, Math.ceil(sim.roundTimer / TARGET_FPS));
      hudText += `  R${sim.currentRound + 1} ${Math.floor(roundSecs / 60)}:${(roundSecs % 60).toString().padStart(2, "0")}`;
    }
    lines.push({ text: hudText, color: 2 });

    if (sim.phase === Phase.RosterReveal || sim.phase === Phase.RoleReveal) {
      lines.push({ text: `STARTING IN ${secs}`, color: 2 });
    }

    if (sim.phase === Phase.LeaderSummit) {
      const summitSecs = Math.max(0, Math.ceil(sim.leaderSummitTimer / TARGET_FPS));
      lines.push({ text: `SUMMIT ${summitSecs}s — LEADERS NEGOTIATING`, color: 8 });
      const hostA = sim.psychopompsSelectedA.map(i => playerTag(sim, i)).join(", ");
      const hostB = sim.psychopompsSelectedB.map(i => playerTag(sim, i)).join(", ");
      if (hostA) lines.push({ text: `UW PSYCHOPOMPS: ${hostA}`, color: TEAM_A_COLOR });
      if (hostB) lines.push({ text: `MR PSYCHOPOMPS: ${hostB}`, color: TEAM_B_COLOR });
      const summitCr = sim.whispers.get(sim.leaderSummitWhisperId);
      if (summitCr) {
        const recent = summitCr.messages.slice(-4);
        for (const m of recent) {
          if (m.type === "system") {
            lines.push({ text: `[${m.text}]`, color: 1 });
          } else {
            const tag = playerTag(sim, m.senderIndex);
            lines.push({ text: `${tag}: ${m.text}`, color: 2 });
          }
        }
      }
    }

    if (sim.phase !== Phase.Lobby && sim.phase !== Phase.RosterReveal && sim.phase !== Phase.RoleReveal) {
      const hades = sim.effectiveRoleHolders(Role.Hades);
      const persephone = sim.effectiveRoleHolders(Role.Persephone);
      const cerberus = sim.effectiveRoleHolders(Role.Cerberus);
      const demeter = sim.effectiveRoleHolders(Role.Demeter);

      const sameRoom = sim.sameRoomBetweenAny(hades, persephone);
      const hcShared = sim.sharedBetweenAny(hades, cerberus);
      const pdShared = sim.sharedBetweenAny(persephone, demeter);

      lines.push({ text: `HADES AND PERSEPHONE: ${sameRoom ? "IN SAME ROOM" : "NOT IN SAME ROOM"}`, color: sameRoom ? 8 : 1 });
      lines.push({ text: `HADES HAS ${hcShared ? "FOUND" : "NOT FOUND"} CERBERUS`, color: hcShared ? 11 : 1 });
      lines.push({ text: `PERSEPHONE HAS ${pdShared ? "FOUND" : "NOT FOUND"} DEMETER`, color: pdShared ? 11 : 1 });

      if (sim.phase === Phase.Reveal || sim.phase === Phase.GameOver) {
        lines.push({ text: "", color: 0 });
        if (sim.winner !== null) {
          const tc = sim.winner === Team.TeamA ? TEAM_A_COLOR : TEAM_B_COLOR;
          const name = sim.winner === Team.TeamA ? "SHADES" : "NYMPHS";
          lines.push({ text: `>>> ${name} WIN <<<`, color: tc });
        } else {
          lines.push({ text: ">>> NO WINNER — DRAW <<<", color: 8 });
        }
      }
    }
  }

  const textSprite = buildFilledTextSprite(lines, 0);
  const barH = 5;
  const barGap = 2;
  const barW = roundsBarWidth(sim);
  const totalW = Math.max(textSprite.width, barW);
  const totalH = textSprite.height + barGap + barH;
  const pixels = new Uint8Array(totalW * totalH);

  for (let y = 0; y < textSprite.height; y++) {
    for (let x = 0; x < textSprite.width; x++) {
      pixels[y * totalW + x] = textSprite.pixels[y * textSprite.width + x];
    }
  }

  drawRoundsBar(sim, pixels, totalW, textSprite.height + barGap, barH);

  pkt.setViewport(HUD_LAYER, totalW, totalH);
  pkt.addSprite(HUD_SPRITE, totalW, totalH, pixels);
  pkt.addObject(HUD_OBJECT, 0, 0, 0, HUD_LAYER, HUD_SPRITE);
}

function roundsBarWidth(sim: Sim): number {
  const pxPerSec = 0.5;
  let totalSecs = 0;
  for (const r of sim.config.rounds) totalSecs += r.durationSecs;
  return Math.ceil(totalSecs * pxPerSec) + 2;
}

function drawRoundsBar(sim: Sim, pixels: Uint8Array, bufW: number, barY: number, barH: number) {
  const pxPerSec = 0.5;
  const rounds = sim.config.rounds;
  let elapsedSecs = 0;

  for (let i = 0; i < rounds.length; i++) {
    const x0 = Math.floor(elapsedSecs * pxPerSec) + 1;
    const x1 = Math.floor((elapsedSecs + rounds[i].durationSecs) * pxPerSec) + 1;

    const isPast = sim.phase !== Phase.Lobby && sim.phase !== Phase.RosterReveal && sim.phase !== Phase.RoleReveal && i < sim.currentRound;
    const isActive = sim.phase === Phase.Playing && i === sim.currentRound;
    const isFuture = !isPast && !isActive;

    const color = isActive ? 11 : isPast ? 5 : 1;
    const sc = spriteColor(color);

    for (let x = x0; x < x1 && x < bufW; x++) {
      for (let y = barY; y < barY + barH; y++) {
        pixels[y * bufW + x] = sc;
      }
    }

    if (isActive && sim.roundTimer > 0) {
      const elapsed = rounds[i].durationSecs * TARGET_FPS - sim.roundTimer;
      const cx = Math.floor((elapsedSecs + elapsed / TARGET_FPS) * pxPerSec) + 1;
      if (cx >= x0 && cx < x1 && cx < bufW) {
        const mc = spriteColor(2);
        for (let y = barY; y < barY + barH; y++) {
          pixels[y * bufW + cx] = mc;
        }
      }
    }

    elapsedSecs += rounds[i].durationSecs;
  }
}

// ---------------------------------------------------------------------------
// Shout panels (top corners)
// ---------------------------------------------------------------------------

function buildShoutPanel(
  sim: Sim, pkt: SpritePacket, room: Room,
  layerId: number, spriteId: number, objId: number,
) {
  const fb = new Framebuffer();
  const roomName = room === Room.RoomA ? ROOM_A_NAME : ROOM_B_NAME;
  const lineH = 7;
  const w = SHOUT_PANEL_W;
  const h = SHOUT_PANEL_LINES * lineH + 2;
  const pixels = new Uint8Array(w * h);

  drawTextIntoPixels(fb, pixels, w, h, 1, 1, `${roomName} SHOUT`, 2);

  const shoutMsgs = room === Room.RoomA ? sim.shoutMessagesA : sim.shoutMessagesB;
  const recent = shoutMsgs.slice(-(SHOUT_PANEL_LINES - 1));

  if (recent.length > 0) {
    let y = lineH + 1;
    for (const m of recent) {
      if (y + lineH > h) break;
      drawRichChatMsg(sim, fb, pixels, w, h, 1, y, m);
      y += lineH;
    }
  } else {
    drawTextIntoPixels(fb, pixels, w, h, 1, lineH + 1, "...", 1);
  }

  pkt.setViewport(layerId, w, h);
  pkt.addSprite(spriteId, w, h, pixels);
  pkt.addObject(objId, 0, 0, 0, layerId, spriteId);
}

// ---------------------------------------------------------------------------
// Vote panels (bottom corners)
// ---------------------------------------------------------------------------

const VOTE_BOX_H = 24;
const VOTE_PANEL_H = 8 + VOTE_BOX_H * 2 + 4;

function buildVotePanel(
  sim: Sim, pkt: SpritePacket, room: Room,
  layerId: number, spriteId: number, objId: number,
) {
  const fb = new Framebuffer();
  const leaderTitle = room === Room.RoomA ? LEADER_A_NAME : LEADER_B_NAME;
  const leader = sim.players.findIndex(p => p.isLeader && p.room === room);
  const votes = sim.phase === Phase.Playing ? sim.usurpVotes(room) : [];
  const topTwo = votes.slice(0, 2);

  const leaderH = 12;
  const w = VOTE_PANEL_W;
  const h = leaderH + VOTE_BOX_H * 2 + 6;
  const pixels = new Uint8Array(w * h);

  // Leader row + psychopomp sprites
  const psychopomps = room === Room.RoomA ? sim.psychopompsSelectedA : sim.psychopompsSelectedB;
  if (leader >= 0 && sim.phase !== Phase.Lobby) {
    drawSmallSprite(pixels, w, 1, 2, sim.players[leader].shape, sim.playerColor(leader));
    const titleText = leaderTitle.toUpperCase();
    drawTextIntoPixels(fb, pixels, w, h, PLAYER_W + 3, 4, titleText, 2);
    let hx = PLAYER_W + 3 + fb.measureText(titleText) + 4;
    for (const hi of psychopomps) {
      if (hx + PLAYER_W > w - 2) break;
      if (hi >= 0 && hi < sim.players.length) {
        drawSmallSprite(pixels, w, hx, 2, sim.players[hi].shape, sim.playerColor(hi));
        hx += PLAYER_W + 1;
      }
    }
  } else {
    drawTextIntoPixels(fb, pixels, w, h, 1, 4, leaderTitle.toUpperCase(), 1);
  }

  // Separator
  const sepY = leaderH;
  const sepC = spriteColor(1);
  for (let x = 0; x < w; x++) pixels[sepY * w + x] = sepC;

  // Vote boxes
  for (let slot = 0; slot < 2; slot++) {
    const boxY = leaderH + 2 + slot * (VOTE_BOX_H + 2);
    const bc = spriteColor(5);
    for (let x = 0; x < w; x++) { pixels[boxY * w + x] = bc; pixels[(boxY + VOTE_BOX_H - 1) * w + x] = bc; }
    for (let y = boxY; y < boxY + VOTE_BOX_H; y++) { pixels[y * w] = bc; pixels[y * w + w - 1] = bc; }

    if (slot >= topTwo.length) {
      continue;
    }

    const v = topTwo[slot];
    const cp = sim.players[v.candidate];

    const innerX = 3, innerY = boxY + 2, innerW = 11, innerH = 11;
    const ic = spriteColor(1);
    for (let x = innerX; x < innerX + innerW; x++) { pixels[innerY * w + x] = ic; pixels[(innerY + innerH - 1) * w + x] = ic; }
    for (let y = innerY; y < innerY + innerH; y++) { pixels[y * w + innerX] = ic; pixels[y * w + innerX + innerW - 1] = ic; }
    drawSmallSprite(pixels, w, innerX + 2, innerY + 2, cp.shape, sim.playerColor(v.candidate));

    drawTextIntoPixels(fb, pixels, w, h, innerX + innerW + 2, innerY + 2, `${v.votes} VOTES`, sim.playerColor(v.candidate));

    const voterPis: number[] = [];
    for (let i = 0; i < sim.players.length; i++) {
      if (sim.players[i].usurpVote === v.candidate && sim.players[i].room === room) {
        voterPis.push(i);
      }
    }
    let vx = innerX + innerW + 2;
    const vy = innerY + 10;
    for (const vi of voterPis) {
      if (vx + PLAYER_W > w - 2) break;
      drawSmallSprite(pixels, w, vx, vy, sim.players[vi].shape, sim.playerColor(vi));
      vx += PLAYER_W + 2;
    }
  }

  pkt.setViewport(layerId, w, h);
  pkt.addSprite(spriteId, w, h, pixels);
  pkt.addObject(objId, 0, 0, 0, layerId, spriteId);
}

// ---------------------------------------------------------------------------
// Private whisper slots (side panels)
// ---------------------------------------------------------------------------

function drawSmallSprite(
  pixels: Uint8Array, bufW: number,
  ox: number, oy: number,
  shape: PlayerShape, color: number,
) {
  const pat = PLAYER_SHAPES[shape];
  for (let dy = 0; dy < 7; dy++) {
    for (let dx = 0; dx < 7; dx++) {
      const v = pat[dy][dx];
      const px = ox + dx;
      const py = oy + dy;
      if (px >= 0 && px < bufW && v) {
        if (v === 1) pixels[py * bufW + px] = spriteColor(0);
        else if (v === 2) pixels[py * bufW + px] = spriteColor(color);
      }
    }
  }
}

function renderWhisperSlot(sim: Sim, cr: Whisper | null): { width: number; height: number; pixels: Uint8Array } {
  const fb = new Framebuffer();
  const lineH = 7;
  const headerH = 9;
  const w = CR_SLOT_W;
  const h = CR_SLOT_H;
  const pixels = new Uint8Array(w * h);

  // Draw border
  const bc = spriteColor(5);
  for (let x = 0; x < w; x++) { pixels[x] = bc; pixels[(h - 1) * w + x] = bc; }
  for (let y = 0; y < h; y++) { pixels[y * w] = bc; pixels[y * w + w - 1] = bc; }

  if (!cr) {
    drawTextIntoPixels(fb, pixels, w, h, 3, 3, "EMPTY", 1);
    return { width: w, height: h, pixels };
  }

  // Header: occupant sprites (inset by border)
  let sx = 3;
  for (const oi of cr.occupants) {
    if (sx + PLAYER_W > w - 3) break;
    if (oi >= 0 && oi < sim.players.length) {
      drawSmallSprite(pixels, w, sx, 2, sim.players[oi].shape, sim.playerColor(oi));
      sx += PLAYER_W + 2;
    }
  }

  // Separator line (inside border)
  const sepY = headerH + 1;
  for (let x = 1; x < w - 1; x++) pixels[sepY * w + x] = spriteColor(1);

  // Messages — fill remaining space
  const msgAreaH = h - sepY - 2;
  const maxMsgLines = Math.floor(msgAreaH / lineH);
  const msgs = cr.messages.slice(-maxMsgLines);

  let y = sepY + 1;
  for (const m of msgs) {
    if (y + lineH > h - 1) break;
    drawRichChatMsg(sim, fb, pixels, w, h, 3, y, m);
    y += lineH;
  }

  if (msgs.length === 0) {
    drawTextIntoPixels(fb, pixels, w, h, 3, sepY + 1, "...", 1);
  }

  return { width: w, height: h, pixels };
}

function drawTextIntoPixels(
  fb: Framebuffer, pixels: Uint8Array,
  bufW: number, bufH: number,
  sx: number, sy: number,
  text: string, color: number,
) {
  let x = sx;
  const sc = spriteColor(color);
  for (const ch of text) {
    if (ch === " ") { x += 4; continue; }
    const glyph = fb.glyphFor(ch);
    if (!glyph) continue;
    if (x + glyph[0].length > bufW) break;
    for (let gy = 0; gy < glyph.length; gy++) {
      for (let gx = 0; gx < glyph[gy].length; gx++) {
        if (glyph[gy][gx]) {
          const px = x + gx;
          const py = sy + gy;
          if (px >= 0 && px < bufW && py >= 0 && py < bufH) {
            pixels[py * bufW + px] = sc;
          }
        }
      }
    }
    x += glyph[0].length + 1;
  }
}

function drawRichTextIntoPixels(
  sim: Sim, fb: Framebuffer, pixels: Uint8Array,
  bufW: number, bufH: number,
  sx: number, sy: number,
  text: string, color: number,
) {
  let x = sx;
  let i = 0;
  while (i < text.length && x < bufW - 2) {
    if (text.charCodeAt(i) === 1 && i + 1 < text.length) {
      const pi = text.charCodeAt(i + 1);
      if (pi >= 0 && pi < sim.players.length) {
        const p = sim.players[pi];
        drawSmallSprite(pixels, bufW, x, sy, p.shape, sim.playerColor(pi));
        x += PLAYER_W + 1;
      }
      i += 2;
    } else if (text[i] === " ") {
      x += 4;
      i++;
    } else {
      const glyph = fb.glyphFor(text[i]);
      if (!glyph) { i++; continue; }
      if (x + glyph[0].length > bufW) break;
      const sc = spriteColor(color);
      for (let gy = 0; gy < glyph.length; gy++) {
        for (let gx = 0; gx < glyph[gy].length; gx++) {
          if (glyph[gy][gx]) {
            const px = x + gx;
            const py = sy + gy;
            if (px >= 0 && px < bufW && py >= 0 && py < bufH) {
              pixels[py * bufW + px] = sc;
            }
          }
        }
      }
      x += glyph[0].length + 1;
      i++;
    }
  }
}

function drawRichChatMsg(
  sim: Sim, fb: Framebuffer, pixels: Uint8Array,
  bufW: number, bufH: number,
  sx: number, sy: number,
  m: { type: string; senderIndex: number; text: string },
) {
  if (m.type === 'system') {
    drawRichTextIntoPixels(sim, fb, pixels, bufW, bufH, sx, sy, m.text, 2);
  } else if (m.senderIndex >= 0 && m.senderIndex < sim.players.length) {
    const p = sim.players[m.senderIndex];
    drawSmallSprite(pixels, bufW, sx, sy, p.shape, sim.playerColor(m.senderIndex));
    drawRichTextIntoPixels(sim, fb, pixels, bufW, bufH, sx + PLAYER_W + 1, sy, m.text, sim.playerColor(m.senderIndex));
  } else {
    drawRichTextIntoPixels(sim, fb, pixels, bufW, bufH, sx, sy, m.text, 2);
  }
}

function buildWhisperSlots(
  sim: Sim, pkt: SpritePacket, room: Room,
  layerId: number, slotOffset: number,
) {
  const SLOT_GAP = 6;

  const roomCrs: Whisper[] = [];
  for (const cr of sim.whispers.values()) {
    if (cr.room === room && cr.occupants.size >= 2) roomCrs.push(cr);
  }

  const cycleOffset = roomCrs.length > CR_SLOTS
    ? Math.floor(sim.tickCount / (3 * TARGET_FPS))
    : 0;

  const totalH = CR_SLOTS * CR_SLOT_H + (CR_SLOTS - 1) * SLOT_GAP;
  pkt.setViewport(layerId, CR_SLOT_W, totalH);

  for (let i = 0; i < CR_SLOTS; i++) {
    const cr = i < roomCrs.length
      ? roomCrs[(cycleOffset + i) % roomCrs.length]
      : null;
    const slot = renderWhisperSlot(sim, cr);
    const spriteId = CR_SLOT_SPRITE_BASE + slotOffset + i;
    const objId = CR_SLOT_OBJECT_BASE + slotOffset + i;
    pkt.addSprite(spriteId, slot.width, slot.height, slot.pixels);
    pkt.addObject(objId, 0, i * (CR_SLOT_H + SLOT_GAP), 0, layerId, spriteId);
  }
}

// ---------------------------------------------------------------------------
// Legend (bottom center)
// ---------------------------------------------------------------------------

function playerTag(sim: Sim, pi: number): string {
  if (pi < 0 || pi >= sim.players.length) return "?";
  return playerSpriteName(sim.players[pi].colorIndex);
}

const TEAM_ROLE_ORDER: [Team, Role][] = [
  [Team.TeamA, Role.Hades],
  [Team.TeamA, Role.EchoOfHades],
  [Team.TeamA, Role.Cerberus],
  [Team.TeamA, Role.EchoOfCerberus],
  [Team.TeamA, Role.Spy],
  [Team.TeamA, Role.Shades],
  [Team.TeamB, Role.Persephone],
  [Team.TeamB, Role.EchoOfPersephone],
  [Team.TeamB, Role.Demeter],
  [Team.TeamB, Role.EchoOfDemeter],
  [Team.TeamB, Role.Spy],
  [Team.TeamB, Role.Nymphs],
];

function buildLegend(sim: Sim, pkt: SpritePacket) {
  if (sim.players.length === 0) return;

  const rowH = 10;
  const fb = new Framebuffer();

  const roleRows: { label: string; labelColor: number; players: number[] }[] = [];
  for (const [team, role] of TEAM_ROLE_ORDER) {
    const pis: number[] = [];
    for (let i = 0; i < sim.players.length; i++) {
      if (sim.players[i].role === role && sim.players[i].team === team) pis.push(i);
    }
    if (pis.length === 0) continue;
    roleRows.push({ label: sim.roleName(role), labelColor: sim.roleIndicator(role, team).color, players: pis });
  }

  let maxLabelW = 0;
  for (const r of roleRows) maxLabelW = Math.max(maxLabelW, fb.measureText(r.label));
  const spriteStartX = 1 + maxLabelW + 4;
  let maxRowW = spriteStartX + PLAYER_W + 2;
  for (const r of roleRows) maxRowW = Math.max(maxRowW, spriteStartX + r.players.length * 10);

  const totalW = maxRowW + 1;
  const totalH = roleRows.length * rowH;
  const pixels = new Uint8Array(totalW * totalH);

  let curY = 0;
  for (const r of roleRows) {
    drawTextIntoPixels(fb, pixels, totalW, totalH, 1, curY + 2, r.label, r.labelColor);
    for (let si = 0; si < r.players.length; si++) {
      const pi = r.players[si];
      const p = sim.players[pi];
      drawSmallSprite(pixels, totalW, spriteStartX + si * 10, curY + 1, p.shape, sim.playerColor(pi));
    }
    curY += rowH;
  }

  pkt.setViewport(STATE_LAYER, totalW, totalH);
  pkt.addSprite(LEGEND_SPRITE, totalW, totalH, pixels);
  pkt.addObject(LEGEND_OBJECT, 0, 0, 0, STATE_LAYER, LEGEND_SPRITE);
}

import type { Sim } from "../game/sim.js";
import { Phase, Role, Room, Team, PlayerShape } from "../game/types.js";
import type { Chatroom } from "../game/types.js";
import {
  PLAYER_SHAPES, PLAYER_W, TARGET_FPS,
  ROOM_A_NAME, ROOM_B_NAME, LEADER_A_NAME, LEADER_B_NAME,
  TEAM_A_COLOR, TEAM_B_COLOR,
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
const PLAYER_SPRITE_BASE = 100;
const PLAYER_OBJECT_BASE = 100;
const HUD_SPRITE = 50;
const HUD_OBJECT = 50;
const LEGEND_SPRITE = 51;
const LEGEND_OBJECT = 51;

const GCHAT_A_SPRITE = 60;
const GCHAT_A_OBJECT = 60;
const GCHAT_B_SPRITE = 61;
const GCHAT_B_OBJECT = 61;

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
const GCHAT_A_LAYER = 2;   // TopLeft — Room A global chat
const GCHAT_B_LAYER = 3;   // TopRight — Room B global chat
const VOTE_A_LAYER = 4;    // BottomLeft — Room A leader/votes
const VOTE_B_LAYER = 5;    // BottomRight — Room B leader/votes
const CR_A_LAYER = 6;      // LeftCenter — Room A private chatrooms
const CR_B_LAYER = 7;      // RightCenter — Room B private chatrooms
const STATE_LAYER = 8;     // BottomCenter — legend + leaders

const GAP = 16;

// Fixed panel sizes (in sprite pixels, rendered at UiZoom=3 on client)
const CHAT_PANEL_W = 80;
const CHAT_PANEL_LINES = 6;
const VOTE_PANEL_W = 80;
const CR_SLOT_W = 80;
const CR_SLOT_H = 50;

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
  pkt.defineLayer(GCHAT_A_LAYER, LayerType.TopLeft, LayerFlag.Ui);
  pkt.defineLayer(GCHAT_B_LAYER, LayerType.Interstitial, LayerFlag.Ui);
  pkt.defineLayer(VOTE_A_LAYER, LayerType.BottomLeft, LayerFlag.Ui);
  pkt.defineLayer(VOTE_B_LAYER, LayerType.BottomRight, LayerFlag.Ui);
  pkt.defineLayer(CR_A_LAYER, LayerType.LeftCenter, LayerFlag.Ui);
  pkt.defineLayer(CR_B_LAYER, LayerType.RightCenter, LayerFlag.Ui);
  pkt.defineLayer(STATE_LAYER, LayerType.BottomCenter, LayerFlag.Ui);

  // Map view
  if (sim.phase === Phase.HostageExchange) {
    buildExchangeView(sim, pkt, padX, padY, ROOM_W, ROOM_H, ROOM_B_OFFSET_X);
  } else {
    buildNormalMapView(sim, pkt, padX, padY, ROOM_B_OFFSET_X);
  }

  // HUD
  buildHud(sim, pkt);

  // Global chat panels (top corners)
  buildGlobalChat(sim, pkt, Room.RoomA, GCHAT_A_LAYER, GCHAT_A_SPRITE, GCHAT_A_OBJECT);
  buildGlobalChat(sim, pkt, Room.RoomB, GCHAT_B_LAYER, GCHAT_B_SPRITE, GCHAT_B_OBJECT);

  // Vote panels (bottom corners)
  buildVotePanel(sim, pkt, Room.RoomA, VOTE_A_LAYER, VOTE_A_SPRITE, VOTE_A_OBJECT);
  buildVotePanel(sim, pkt, Room.RoomB, VOTE_B_LAYER, VOTE_B_SPRITE, VOTE_B_OBJECT);

  // Private chatroom slots (side panels)
  buildChatroomSlots(sim, pkt, Room.RoomA, CR_A_LAYER, 0);
  buildChatroomSlots(sim, pkt, Room.RoomB, CR_B_LAYER, CR_SLOTS);

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

function buildPlayerSprite(sim: Sim, pkt: SpritePacket, pi: number, spriteId: number) {
  const p = sim.players[pi];
  const color = sim.playerColor(pi);
  const ind = sim.roleIndicator(p.role);
  const sw = 7, sh = 13;
  const px = new Uint8Array(sw * sh);

  if (p.isLeader) {
    const cc = spriteColor(8);
    px[0 * sw + 1] = cc; px[0 * sw + 3] = cc; px[0 * sw + 5] = cc;
    px[1 * sw + 2] = cc; px[1 * sw + 3] = cc; px[1 * sw + 4] = cc;
  }

  const pat = PLAYER_SHAPES[p.shape];
  for (let dy = 0; dy < 7; dy++) {
    for (let dx = 0; dx < 7; dx++) {
      const v = pat[dy][dx];
      if (v === 1) px[(dy + 3) * sw + dx] = spriteColor(0);
      else if (v === 2) px[(dy + 3) * sw + dx] = spriteColor(color);
    }
  }

  const rc = spriteColor(ind.color);
  for (let dx = 1; dx <= 5; dx++) {
    px[11 * sw + dx] = rc;
    px[12 * sw + dx] = rc;
  }
  if (ind.special) {
    const dot = spriteColor(p.role === Role.Hades ? 8 : 2);
    px[11 * sw + 3] = dot;
    px[12 * sw + 3] = dot;
  }

  if (p.inChatroom >= 0) {
    const bc = spriteColor(1);
    px[0 * sw + 2] = bc; px[0 * sw + 3] = bc; px[0 * sw + 4] = bc;
    px[1 * sw + 3] = bc;
  }

  if (p.pendingChatroomEntry >= 0 && (sim.tickCount & 8)) {
    px[2 * sw + 3] = spriteColor(8);
  }

  if (p.selectedAsHostage && sim.phase === Phase.HostageSelect) {
    const hc = spriteColor(8);
    px[2 * sw + 0] = hc; px[2 * sw + 6] = hc;
    px[10 * sw + 0] = hc; px[10 * sw + 6] = hc;
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
    buildPlayerSprite(sim, pkt, i, PLAYER_SPRITE_BASE + i);
    const roomOffX = p.room === Room.RoomB ? roomBOffX : 0;
    pkt.addObject(PLAYER_OBJECT_BASE + i, padX + roomOffX + p.x, padY + p.y - 6, i, 0, PLAYER_SPRITE_BASE + i);
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
  rows.push({ text: "HOSTAGE EXCHANGE", color: 8 });
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

  for (const [label, hostages] of [
    [`LEAVING ${ROOM_A_NAME}:`, sim.exchangeFromA],
    [`LEAVING ${ROOM_B_NAME}:`, sim.exchangeFromB],
  ] as [string, typeof sim.exchangeFromA][]) {
    if (hostages.length > 0) {
      rows.push({ text: label, color: 8 });
      for (const h of hostages) {
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
  const lines: { text: string; color: number }[] = [];
  const phaseText = Phase[sim.phase].toUpperCase();
  let hudText = `${phaseText}  P:${sim.players.length}`;
  if (sim.phase === Phase.Playing) {
    const secs = Math.max(0, Math.ceil(sim.roundTimer / TARGET_FPS));
    hudText += `  R${sim.currentRound + 1} ${Math.floor(secs / 60)}:${(secs % 60).toString().padStart(2, "0")}`;
  }
  lines.push({ text: hudText, color: 2 });

  if (sim.phase !== Phase.Lobby) {
    const hi = findByRole(sim, Role.Hades);
    const pi = findByRole(sim, Role.Persephone);
    const ci = findByRole(sim, Role.Cerberus);
    const di = findByRole(sim, Role.Demeter);

    const sameRoom = hi >= 0 && pi >= 0 && sim.players[hi].room === sim.players[pi].room;
    const hcShared = hi >= 0 && ci >= 0 && sim.players[hi].sharedWith.has(ci);
    const pdShared = pi >= 0 && di >= 0 && sim.players[pi].sharedWith.has(di);

    lines.push({ text: `HADES AND PERSEPHONE: ${sameRoom ? "IN SAME ROOM" : "NOT IN SAME ROOM"}`, color: sameRoom ? 8 : 1 });
    lines.push({ text: `HADES HAS ${hcShared ? "FOUND" : "NOT FOUND"} CERBERUS`, color: hcShared ? 11 : 1 });
    lines.push({ text: `PERSEPHONE HAS ${pdShared ? "FOUND" : "NOT FOUND"} DEMETER`, color: pdShared ? 11 : 1 });

    if (sim.winner !== null) {
      const tc = sim.winner === Team.TeamA ? TEAM_A_COLOR : TEAM_B_COLOR;
      const name = sim.winner === Team.TeamA ? "SHADES" : "NYMPHS";
      lines.push({ text: `WINNER: ${name}`, color: tc });
    }
  }

  const sprite = buildFilledTextSprite(lines, 0);
  pkt.setViewport(HUD_LAYER, sprite.width, sprite.height);
  pkt.addSprite(HUD_SPRITE, sprite.width, sprite.height, sprite.pixels);
  pkt.addObject(HUD_OBJECT, 0, 0, 0, HUD_LAYER, HUD_SPRITE);
}

// ---------------------------------------------------------------------------
// Global chat panels (top corners)
// ---------------------------------------------------------------------------

function buildGlobalChat(
  sim: Sim, pkt: SpritePacket, room: Room,
  layerId: number, spriteId: number, objId: number,
) {
  const fb = new Framebuffer();
  const roomName = room === Room.RoomA ? ROOM_A_NAME : ROOM_B_NAME;
  const lineH = 7;
  const w = CHAT_PANEL_W;
  const h = CHAT_PANEL_LINES * lineH + 2;
  const pixels = new Uint8Array(w * h);

  drawTextIntoPixels(fb, pixels, w, h, 1, 1, `${roomName} CHAT`, 2);

  const globalMsgs = room === Room.RoomA ? sim.globalMessagesA : sim.globalMessagesB;
  const recent = globalMsgs.slice(-(CHAT_PANEL_LINES - 1));

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

  // Leader row
  if (leader >= 0 && sim.phase !== Phase.Lobby) {
    drawSmallSprite(pixels, w, 1, 2, sim.players[leader].shape, sim.playerColor(leader));
    drawTextIntoPixels(fb, pixels, w, h, PLAYER_W + 3, 4, leaderTitle.toUpperCase(), 2);
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
// Private chatroom slots (side panels)
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

function renderChatroomSlot(sim: Sim, cr: Chatroom | null): { width: number; height: number; pixels: Uint8Array } {
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
    drawRichTextIntoPixels(sim, fb, pixels, bufW, bufH, sx, sy, m.text, 8);
  } else if (m.senderIndex >= 0 && m.senderIndex < sim.players.length) {
    const p = sim.players[m.senderIndex];
    drawSmallSprite(pixels, bufW, sx, sy, p.shape, sim.playerColor(m.senderIndex));
    drawRichTextIntoPixels(sim, fb, pixels, bufW, bufH, sx + PLAYER_W + 1, sy, m.text, sim.playerColor(m.senderIndex));
  } else {
    drawRichTextIntoPixels(sim, fb, pixels, bufW, bufH, sx, sy, m.text, 2);
  }
}

function buildChatroomSlots(
  sim: Sim, pkt: SpritePacket, room: Room,
  layerId: number, slotOffset: number,
) {
  const SLOT_GAP = 6;
  const totalH = CR_SLOTS * CR_SLOT_H + (CR_SLOTS - 1) * SLOT_GAP;
  pkt.setViewport(layerId, CR_SLOT_W, totalH);

  const roomCrs: Chatroom[] = [];
  for (const cr of sim.chatrooms.values()) {
    if (cr.room === room && cr.occupants.size >= 2) roomCrs.push(cr);
  }

  const cycleOffset = roomCrs.length > CR_SLOTS
    ? Math.floor(sim.tickCount / (3 * TARGET_FPS))
    : 0;

  for (let i = 0; i < CR_SLOTS; i++) {
    const cr = i < roomCrs.length
      ? roomCrs[(cycleOffset + i) % roomCrs.length]
      : null;
    const slot = renderChatroomSlot(sim, cr);
    const spriteId = CR_SLOT_SPRITE_BASE + slotOffset + i;
    const objId = CR_SLOT_OBJECT_BASE + slotOffset + i;
    pkt.addSprite(spriteId, slot.width, slot.height, slot.pixels);
    pkt.addObject(objId, 0, i * (CR_SLOT_H + SLOT_GAP), 0, layerId, spriteId);
  }
}

// ---------------------------------------------------------------------------
// Legend (bottom center)
// ---------------------------------------------------------------------------

function findByRole(sim: Sim, role: Role): number {
  return sim.players.findIndex(p => p.role === role);
}

const TEAM_ROLE_ORDER: [Team, Role][] = [
  [Team.TeamA, Role.Hades],
  [Team.TeamA, Role.Cerberus],
  [Team.TeamA, Role.Shades],
  [Team.TeamB, Role.Persephone],
  [Team.TeamB, Role.Demeter],
  [Team.TeamB, Role.Nymphs],
];

function buildLegend(sim: Sim, pkt: SpritePacket) {
  if (sim.players.length === 0) return;

  const rowH = 10;
  const fb = new Framebuffer();

  const roleRows: { label: string; labelColor: number; players: number[] }[] = [];
  for (const [, role] of TEAM_ROLE_ORDER) {
    const pis: number[] = [];
    for (let i = 0; i < sim.players.length; i++) {
      if (sim.players[i].role === role) pis.push(i);
    }
    if (pis.length === 0) continue;
    roleRows.push({ label: sim.roleName(role), labelColor: sim.roleIndicator(role).color, players: pis });
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

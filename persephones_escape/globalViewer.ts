import type { Sim } from "./sim.js";
import { Phase, Role, Room, PlayerShape } from "./types.js";
import {
  ROOM_W, ROOM_H, PLAYER_SHAPES, TARGET_FPS,
  ROOM_A_NAME, ROOM_B_NAME, LEADER_A_NAME, LEADER_B_NAME, CHAT_FADE_TICKS,
} from "./constants.js";
import { SpritePacket, LayerType, LayerFlag, spriteColor, buildFilledTextSprite } from "./spriteProtocol.js";

const ROOM_A_SPRITE = 0;
const ROOM_A_OBJECT = 0;
const ROOM_B_SPRITE = 1;
const ROOM_B_OBJECT = 1;
const PLAYER_SPRITE_BASE = 100;
const PLAYER_OBJECT_BASE = 100;
const HUD_SPRITE = 50;
const HUD_OBJECT = 50;
const VOTE_A_SPRITE = 60;
const VOTE_A_OBJECT = 60;
const VOTE_B_SPRITE = 61;
const VOTE_B_OBJECT = 61;
const CHAT_A_SPRITE = 62;
const CHAT_A_OBJECT = 62;
const CHAT_B_SPRITE = 63;
const CHAT_B_OBJECT = 63;

const HUD_LAYER = 1;
const LEFT_PANEL_LAYER = 2;
const RIGHT_PANEL_LAYER = 3;

const GAP = 16;
const TOTAL_W = ROOM_W * 2 + GAP;
const TOTAL_H = ROOM_H;
const ROOM_B_OFFSET_X = ROOM_W + GAP;

export function buildGlobalFrame(sim: Sim): Buffer {
  const pkt = new SpritePacket();

  const padX = 120;
  const padY = 80;
  pkt.defineLayer(0, LayerType.Map, LayerFlag.Zoomable);
  pkt.setViewport(0, TOTAL_W + padX * 2, TOTAL_H + padY * 2);

  pkt.defineLayer(HUD_LAYER, LayerType.TopCenter, LayerFlag.Ui);
  pkt.setViewport(HUD_LAYER, 128, 10);

  pkt.defineLayer(LEFT_PANEL_LAYER, LayerType.TopLeft, LayerFlag.Ui);
  pkt.setViewport(LEFT_PANEL_LAYER, 100, 80);

  pkt.defineLayer(RIGHT_PANEL_LAYER, LayerType.BottomRight, LayerFlag.Ui);
  pkt.setViewport(RIGHT_PANEL_LAYER, 100, 80);

  pkt.clearAll();

  // Room A sprite
  buildRoomSprite(sim, pkt, Room.RoomA, ROOM_A_SPRITE);
  pkt.addObject(ROOM_A_OBJECT, padX, padY, -100, 0, ROOM_A_SPRITE);

  // Room B sprite
  buildRoomSprite(sim, pkt, Room.RoomB, ROOM_B_SPRITE);
  pkt.addObject(ROOM_B_OBJECT, padX + ROOM_B_OFFSET_X, padY, -100, 0, ROOM_B_SPRITE);

  // Player sprites
  for (let i = 0; i < sim.players.length; i++) {
    const p = sim.players[i];
    const color = sim.playerColor(i);
    const ind = sim.roleIndicator(p.role);
    const spriteId = PLAYER_SPRITE_BASE + i;
    const objId = PLAYER_OBJECT_BASE + i;

    const sw = 7, sh = 13;
    const px = new Uint8Array(sw * sh);

    if (p.isLeader) {
      const cc = spriteColor(8);
      px[0 * sw + 1] = cc; px[0 * sw + 3] = cc; px[0 * sw + 5] = cc;
      px[1 * sw + 2] = cc; px[1 * sw + 3] = cc; px[1 * sw + 4] = cc;
    }

    const pat = PLAYER_SHAPES[p.shape] ?? PLAYER_SHAPES[PlayerShape.Square];
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

    const roomOffX = p.room === Room.RoomB ? ROOM_B_OFFSET_X : 0;
    pkt.addSprite(spriteId, sw, sh, px);
    pkt.addObject(objId, padX + roomOffX + p.x, padY + p.y - 6, i, 0, spriteId);
  }

  buildHud(sim, pkt);

  buildRoomPanel(sim, pkt, Room.RoomA, LEFT_PANEL_LAYER, VOTE_A_SPRITE, VOTE_A_OBJECT, CHAT_A_SPRITE, CHAT_A_OBJECT);
  buildRoomPanel(sim, pkt, Room.RoomB, RIGHT_PANEL_LAYER, VOTE_B_SPRITE, VOTE_B_OBJECT, CHAT_B_SPRITE, CHAT_B_OBJECT);

  return pkt.toBuffer();
}

function buildRoomSprite(sim: Sim, pkt: SpritePacket, room: Room, spriteId: number) {
  const pixels = new Uint8Array(ROOM_W * ROOM_H);
  for (let my = 0; my < ROOM_H; my++) {
    for (let mx = 0; mx < ROOM_W; mx++) {
      const c = sim.isWallInRoom(room, mx, my) ? 5 : sim.floorColorAt(room, mx, my);
      pixels[my * ROOM_W + mx] = spriteColor(c);
    }
  }
  pkt.addSprite(spriteId, ROOM_W, ROOM_H, pixels);
}

function buildHud(sim: Sim, pkt: SpritePacket) {
  const lines: { text: string; color: number }[] = [];
  const phaseText = Phase[sim.phase].toUpperCase();
  let hudText = `${phaseText}  P:${sim.players.length}`;
  if (sim.phase === Phase.Playing) {
    const secs = Math.max(0, Math.ceil(sim.roundTimer / TARGET_FPS));
    hudText += `  R${sim.currentRound + 1} ${Math.floor(secs / 60)}:${(secs % 60).toString().padStart(2, "0")}`;
  }
  lines.push({ text: hudText, color: 2 });
  const sprite = buildFilledTextSprite(lines, 0);
  pkt.addSprite(HUD_SPRITE, sprite.width, sprite.height, sprite.pixels);
  pkt.addObject(HUD_OBJECT, 0, 0, 0, HUD_LAYER, HUD_SPRITE);
}

function buildRoomPanel(
  sim: Sim, pkt: SpritePacket, room: Room,
  layerId: number,
  voteSpriteId: number, voteObjId: number,
  chatSpriteId: number, chatObjId: number,
) {
  const roomName = room === Room.RoomA ? ROOM_A_NAME : ROOM_B_NAME;

  const voteLines: { text: string; color: number }[] = [];
  voteLines.push({ text: roomName + " VOTES", color: 2 });

  const leader = sim.players.findIndex((p, i) => p.isLeader && p.room === room);
  const leaderTitle = room === Room.RoomA ? LEADER_A_NAME : LEADER_B_NAME;
  if (leader >= 0) {
    voteLines.push({ text: leaderTitle.toUpperCase(), color: sim.playerColor(leader) });
  }

  if (sim.phase === Phase.Playing) {
    const votes = sim.usurpVotes(room);
    if (votes.length > 0) {
      for (const v of votes.slice(0, 3)) {
        voteLines.push({ text: `VOTES: ${v.votes}`, color: sim.playerColor(v.candidate) });
      }
    } else {
      voteLines.push({ text: "NO VOTES", color: 1 });
    }
  }

  const voteSprite = buildFilledTextSprite(voteLines, 0);
  pkt.addSprite(voteSpriteId, voteSprite.width, voteSprite.height, voteSprite.pixels);
  pkt.addObject(voteObjId, 0, 0, 0, layerId, voteSpriteId);

  const chatLines: { text: string; color: number }[] = [];
  chatLines.push({ text: roomName + " CHAT", color: 2 });

  const msgs = sim.chatMessages.filter(
    (m) => m.room === room && sim.tickCount - m.tick < CHAT_FADE_TICKS
  ).slice(-4);

  if (msgs.length > 0) {
    for (const m of msgs) {
      chatLines.push({ text: m.text.slice(0, 24), color: m.color });
    }
  } else {
    chatLines.push({ text: "...", color: 1 });
  }

  const chatSprite = buildFilledTextSprite(chatLines, 0);
  pkt.addSprite(chatSpriteId, chatSprite.width, chatSprite.height, chatSprite.pixels);
  pkt.addObject(chatObjId, 0, voteSprite.height + 2, 0, layerId, chatSpriteId);
}

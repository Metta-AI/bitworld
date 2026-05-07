import type { Sim } from "../game/sim.js";
import type { uint8 } from "../game/types.js";
import { Phase, Team, Role, Room, PlayerShape } from "../game/types.js";
import { Framebuffer, FrameRegion } from "./framebuffer.js";
import {
  SCREEN_WIDTH, SCREEN_HEIGHT,
  PLAYER_W, PLAYER_H,
  TARGET_FPS,
  BOTTOM_BAR_H, MINIMAP_SIZE, MINIMAP_X, MINIMAP_Y,
  SHADOW_MAP, PLAYER_SHAPES,
  TEAM_A_NAME, TEAM_B_NAME, TEAM_A_COLOR, TEAM_B_COLOR,
  ROOM_A_NAME, ROOM_B_NAME,
  LEADER_ROOM_NAME,
  playerCountFromConfig,
  playerSpriteName,
} from "../game/constants.js";
import { clamp, coalesceChatFragments } from "../game/util.js";
import { WHISPER_MENU, whisperMenuAction, whisperMenuItemLabel } from "../game/menu_defs.js";
import { FRAME_REGIONS } from "./frameRegions.js";

function drawRichText(sim: Sim, fb: Framebuffer, text: string, x: number, y: number, color: uint8) {
  let cx = x;
  let i = 0;
  while (i < text.length && cx < SCREEN_WIDTH - 2) {
    if (text.charCodeAt(i) === 1 && i + 1 < text.length) {
      const pi = text.charCodeAt(i + 1);
      if (pi >= 0 && pi < sim.players.length) {
        const p = sim.players[pi];
        drawPlayerSprite(fb, cx, y, p.shape, sim.playerColor(pi));
        cx += PLAYER_W;
      }
      i += 2;
    } else if (text[i] === " ") {
      cx += 4;
      i++;
    } else {
      const glyph = fb.glyphFor(text[i]);
      if (glyph) {
        for (let gy = 0; gy < glyph.length; gy++) {
          for (let gx = 0; gx < glyph[gy].length; gx++) {
            if (glyph[gy][gx]) fb.putPixel(cx + gx, y + gy, color);
          }
        }
        cx += glyph[0].length + 1;
      }
      i++;
    }
  }
}

function drawChatMsg(sim: Sim, fb: Framebuffer, m: { type: string; senderIndex: number; text: string }, x: number, y: number) {
  if (m.type === 'system') {
    drawRichText(sim, fb, m.text, x, y, 8);
  } else if (m.senderIndex >= 0 && m.senderIndex < sim.players.length) {
    const p = sim.players[m.senderIndex];
    drawPlayerSprite(fb, x, y, p.shape, sim.playerColor(m.senderIndex));
    drawRichText(sim, fb, m.text, x + PLAYER_W + 1, y, sim.playerColor(m.senderIndex));
  } else {
    drawRichText(sim, fb, m.text, x, y, 2);
  }
}

function drawRoleSlot(sim: Sim, fb: Framebuffer, sx: number, slotY: number, role: Role, team?: Team) {
  const ind = sim.roleIndicator(role, team);
  fb.fillRect(sx + 1, slotY, 5, 2, ind.color);
  if (role === Role.Hades || role === Role.EchoOfHades) {
    fb.putPixel(sx + 3, slotY, 8);
    fb.putPixel(sx + 3, slotY + 1, 8);
  } else if (role === Role.Persephone || role === Role.EchoOfPersephone) {
    fb.putPixel(sx + 3, slotY, 8);
    fb.putPixel(sx + 3, slotY + 1, 8);
  } else if (role === Role.Cerberus || role === Role.EchoOfCerberus) {
    fb.putPixel(sx + 2, slotY, 8);
    fb.putPixel(sx + 4, slotY, 8);
  } else if (role === Role.Demeter || role === Role.EchoOfDemeter) {
    fb.putPixel(sx + 2, slotY, 2);
    fb.putPixel(sx + 4, slotY, 2);
  }
}

function drawWrappedLines(fb: Framebuffer, lines: string[], x: number, y: number, color: uint8, maxWidth = SCREEN_WIDTH - x - 2): number {
  for (const line of lines) {
    let current = "";
    for (const word of line.split(" ")) {
      const candidate = current.length === 0 ? word : `${current} ${word}`;
      if (fb.measureText(candidate) <= maxWidth) {
        current = candidate;
      } else {
        if (current.length > 0) {
          fb.drawText(current, x, y, color);
          y += 8;
        }
        current = word;
      }
    }
    if (current.length > 0) {
      fb.drawText(current, x, y, color);
      y += 8;
    }
  }
  return y;
}

export function playerView(sim: Sim, pi: number): { cameraX: number; cameraY: number; originMx: number; originMy: number } {
  const p = sim.players[pi];
  const cx = p.x + Math.floor(PLAYER_W / 2);
  const cy = p.y + Math.floor(PLAYER_H / 2);
  const topBar = 9;
  const botBar = BOTTOM_BAR_H;
  const visH = SCREEN_HEIGHT - topBar - botBar;
  const targetY = cy - topBar - Math.floor(visH / 2);
  return {
    cameraX: clamp(cx - Math.floor(SCREEN_WIDTH / 2), 0, Math.max(0, sim.roomW - SCREEN_WIDTH)),
    cameraY: clamp(targetY, -topBar, Math.max(-topBar, sim.roomH - SCREEN_HEIGHT + botBar)),
    originMx: cx,
    originMy: cy,
  };
}

export function drawPlayerSprite(fb: Framebuffer, sx: number, sy: number, shape: PlayerShape, color: uint8) {
  const pat = PLAYER_SHAPES[shape];
  for (let dy = 0; dy < 7; dy++) {
    for (let dx = 0; dx < 7; dx++) {
      const v = pat[dy][dx];
      if (v === 1) fb.putPixel(sx + dx, sy + dy, 0);
      else if (v === 2) fb.putPixel(sx + dx, sy + dy, color);
    }
  }
}

function drawPlayerWorldAccoutrements(
  sim: Sim,
  fb: Framebuffer,
  viewerIndex: number,
  pi: number,
  sx: number,
  sy: number,
  showAll: boolean,
) {
  const p = sim.players[pi];

  if (p.isLeader) {
    fb.putPixel(sx + 1, sy - 2, 8);
    fb.putPixel(sx + 3, sy - 3, 8);
    fb.putPixel(sx + 5, sy - 2, 8);
    fb.putPixel(sx + 2, sy - 1, 8);
    fb.putPixel(sx + 3, sy - 1, 8);
    fb.putPixel(sx + 4, sy - 1, 8);
  }

  if (p.selectedAsPsychopomp) fb.putPixel(sx + 3, sy - 1, 3);

  if (p.inWhisper >= 0) {
    fb.putPixel(sx - 3, sy - 4, 2);
    fb.putPixel(sx - 2, sy - 4, 2);
    fb.putPixel(sx - 1, sy - 4, 2);
    fb.putPixel(sx - 3, sy - 3, 2);
    fb.putPixel(sx - 2, sy - 3, 2);
    fb.putPixel(sx - 1, sy - 3, 2);
    fb.putPixel(sx,     sy - 2, 2);
  }

  if (p.pendingWhisperEntry >= 0 && (sim.tickCount & 8)) {
    fb.putPixel(sx + 3, sy - 1, 8);
  }

  const slotY = sy + PLAYER_H + 1;
  if (showAll || pi === viewerIndex) {
    drawRoleSlot(sim, fb, sx, slotY, p.role, p.team);
  } else if (p.revealedTo.has(viewerIndex)) {
    drawRoleSlot(sim, fb, sx, slotY, p.role, sim.roleRevealTeam(pi, viewerIndex));
  } else if (p.colorRevealedTo.has(viewerIndex)) {
    fb.putPixel(sx + 3, slotY, sim.colorRevealTeamColor(pi));
  }
}

function roundClockText(sim: Sim): string {
  const round = Math.min(sim.currentRound + 1, sim.config.rounds.length);
  const secs = sim.phase === Phase.PsychopompSelect
    ? Math.max(0, Math.ceil(sim.psychopompSelectTimer / TARGET_FPS))
    : sim.phase === Phase.LeaderSummit
      ? Math.max(0, Math.ceil(sim.leaderSummitTimer / TARGET_FPS))
      : Math.max(0, Math.ceil(sim.roundTimer / TARGET_FPS));
  return `R${round} ${Math.floor(secs / 60)}:${(secs % 60).toString().padStart(2, "0")}`;
}

function renderWhisperView(sim: Sim, fb: Framebuffer, viewerIndex: number): Buffer {
  const viewer = sim.players[viewerIndex];
  fb.clear(0);

  const header = FRAME_REGIONS.whisper.header;
  const bottomBar = FRAME_REGIONS.whisper.bottomBar();
  const bottomText = FRAME_REGIONS.whisper.bottomText();
  fb.fillRect(header.x, header.y, header.w, header.h, 0);
  const cr = sim.whispers.get(viewer.inWhisper);
  const isSummit = cr && cr.room === Room.LeaderRoom;
  fb.drawText(roundClockText(sim), FRAME_REGIONS.whisper.clockText.x, FRAME_REGIONS.whisper.clockText.y, 2);
  fb.drawText(
    isSummit ? "SUMMIT" : "WHISP",
    FRAME_REGIONS.whisper.titleText.x,
    FRAME_REGIONS.whisper.titleText.y,
    isSummit ? 8 : 2,
  );
  if (cr) {
    let slot = 0;
    for (const oi of cr.occupants) {
      const r = FRAME_REGIONS.whisper.occupantSlot(slot);
      if (r.x + r.w > SCREEN_WIDTH - 2) break;
      drawPlayerSprite(fb, r.x, r.y, sim.players[oi].shape, sim.playerColor(oi));
      slot++;
    }
  }

  const barY = bottomBar.y;
  fb.fillRect(bottomBar.x, bottomBar.y, bottomBar.w, bottomBar.h, 0);

  if (viewer.shareSelectOpen) {
    const isColor = viewer.shareSelectMode === "color";
    const offerers = isColor ? sim.whisperColorOfferers(viewerIndex) : sim.whisperShareOfferers(viewerIndex);
    if (offerers.length > 0) {
      const label = isColor ? "COLOR:" : "ROLE:";
      fb.drawText(label, bottomText.x, bottomText.y, 8);
      let sx = bottomText.x + fb.measureText(label) + 2;
      const row = Math.min(viewer.shareSelectRow, offerers.length - 1);
      for (let t = 0; t < offerers.length; t++) {
        const p = sim.players[offerers[t]];
        if (p && sx + PLAYER_W < SCREEN_WIDTH - 2) {
          if (t === row) fb.drawRect(sx - 1, barY, PLAYER_W + 2, BOTTOM_BAR_H, 2);
          drawPlayerSprite(fb, sx, barY + 1, p.shape, sim.playerColor(offerers[t]));
          sx += PLAYER_W + 3;
        }
      }
    }
  } else if (viewer.whisperMenuOpen) {
    const cat = WHISPER_MENU[viewer.whisperMenuCat];
    if (cat) {
      const itemIdx = Math.min(viewer.whisperMenuItem, cat.items.length - 1);
      const action = whisperMenuAction(viewer.whisperMenuCat, itemIdx);
      const label = action ? whisperMenuItemLabel(cat, itemIdx) : "";
      const enabled = action ? sim.whisperActionEnabled(viewerIndex, action) : false;
      const color: uint8 = enabled ? 2 : 1;
      fb.drawText(`(${cat.label}) ${label}`, bottomText.x, bottomText.y, color);
    }
  } else if (isSummit) {
    const secs = Math.max(0, Math.ceil(sim.leaderSummitTimer / TARGET_FPS));
    fb.drawText(`SUMMIT ${secs}S  ENTER:MSG`, bottomText.x, bottomText.y, 8);
  } else {
    fb.drawText("H/I:TAB L:EXIT K:ACT", bottomText.x, bottomText.y, 1);
  }

  const roleOfferers = sim.whisperShareOfferers(viewerIndex);
  const colorOfferers = sim.whisperColorOfferers(viewerIndex);
  const hasLeaderOffer = sim.whisperHasLeaderOffer(viewerIndex);
  const offer = FRAME_REGIONS.whisper.offerIndicator();
  if (hasLeaderOffer) {
    fb.drawText("L!", offer.x, offer.y, 8);
  } else if (roleOfferers.length > 0) {
    fb.drawText("R!", offer.x, offer.y, 8);
  } else if (colorOfferers.length > 0) {
    fb.drawText("C!", offer.x, offer.y, 8);
  }

  const msgArea = FRAME_REGIONS.whisper.messageArea();
  const msgAreaTop = msgArea.y;
  const msgAreaBot = msgArea.y + msgArea.h;
  const lineH = 7;
  const maxLines = Math.floor((msgAreaBot - msgAreaTop) / lineH);

  const messages = sim.whisperMessagesForPlayer(viewerIndex);
  const hasPending = !!(cr && cr.pendingEntry.length > 0);

  const showCount = Math.min(messages.length, maxLines - (hasPending ? 1 : 0));
  const startIdx = Math.max(0, messages.length - showCount - viewer.whisperScrollOffset);
  let y = msgAreaBot - showCount * lineH - (hasPending ? lineH : 0);
  for (let i = startIdx; i < startIdx + showCount && i < messages.length; i++) {
    const m = messages[i];
    drawChatMsg(sim, fb, m, 2, y);
    y += lineH;
  }

  // Draw pending-entry indicator LAST so it's not overwritten by messages.
  if (hasPending && cr) {
    const reqPi = cr.pendingEntry[0];
    const reqP = sim.players[reqPi];
    if (reqP) {
      const bang = FRAME_REGIONS.whisper.pendingEntryBang();
      const sprite = FRAME_REGIONS.whisper.pendingEntrySprite();
      const text = FRAME_REGIONS.whisper.pendingEntryText();
      fb.fillRect(0, bang.y, SCREEN_WIDTH, bang.h, 0);
      fb.drawText("!", bang.x, sprite.y, 8);
      drawPlayerSprite(fb, sprite.x, sprite.y, reqP.shape, sim.playerColor(reqPi));
      fb.drawText("WANTS IN", text.x, text.y, 8);
    }
  }

  fb.pack();
  return fb.packed;
}

function renderShoutView(sim: Sim, fb: Framebuffer, viewerIndex: number): Buffer {
  const viewer = sim.players[viewerIndex];
  fb.clear(0);

  fb.fillRect(0, 0, SCREEN_WIDTH, 9, 0);
  const leaderPsychopomp = sim.phase === Phase.PsychopompSelect && viewer.isLeader;
  fb.drawText(roundClockText(sim), 2, 2, 2);
  if (sim.phase === Phase.PsychopompSelect) {
    const secs = Math.max(0, Math.ceil(sim.psychopompSelectTimer / TARGET_FPS));
    fb.drawText(`SELECT ${secs}S`, 42, 2, 8);
  } else {
    fb.drawText("SHOUT", 42, 2, 2);
  }

  const barY = SCREEN_HEIGHT - BOTTOM_BAR_H;
  fb.fillRect(0, barY, SCREEN_WIDTH, BOTTOM_BAR_H, 0);

  let votingBottomY = 10;

  if (leaderPsychopomp) {
    const eligible = sim.eligiblePsychopomps(viewer.room);
    const cursor = viewer.room === Room.RoomA ? sim.psychopompCursorA : sim.psychopompCursorB;
    const selected = viewer.room === Room.RoomA ? sim.psychopompsSelectedA : sim.psychopompsSelectedB;
    const committed = viewer.room === Room.RoomA ? sim.committedA : sim.committedB;

    if (eligible.length > 0 && !committed) {
      const cellW = 12; const cellH = 14;
      const cols = Math.min(eligible.length, 4);
      const rows = Math.ceil(eligible.length / cols);
      const gridW = cols * cellW;
      const gridH = rows * cellH;
      const gridX = Math.floor((SCREEN_WIDTH - gridW) / 2);
      const gridY = 11;

      for (let k = 0; k < eligible.length; k++) {
        const pi = eligible[k];
        const col = k % cols;
        const row = Math.floor(k / cols);
        const cx = gridX + col * cellW;
        const cy = gridY + row * cellH;
        const color = sim.playerColor(pi);
        const spriteX = cx + Math.floor((cellW - PLAYER_W) / 2);
        const spriteY = cy + 1;
        drawPlayerSprite(fb, spriteX, spriteY, sim.players[pi].shape, color);

        if (selected.includes(pi)) {
          fb.putPixel(cx + cellW - 3, cy + 1, 11);
          fb.putPixel(cx + cellW - 2, cy + 2, 11);
          fb.putPixel(cx + cellW - 3, cy + 3, 11);
        }
        if (k === cursor % eligible.length) fb.drawRect(cx, cy, cellW, cellH, 2);
      }

      const label = `${selected.length}/${sim.psychopompsPerRoom} PSYCHOPOMPS`;
      fb.drawText(label, gridX + Math.floor((gridW - fb.measureText(label)) / 2), gridY + gridH + 2, 2);
      votingBottomY = gridY + gridH + 10;
    } else if (committed) {
      fb.drawText("COMMITTED", Math.floor((SCREEN_WIDTH - fb.measureText("COMMITTED")) / 2), 14, 2);
      votingBottomY = 24;
    }
    fb.drawText("J:TOG  K:COMMIT  L:CLOSE", 2, barY + 2, 1);
  } else {
    const candidates = sim.usurpCandidates(viewerIndex);
    if (candidates.length > 0) {
      const row = Math.min(viewer.shoutActionRow, candidates.length - 1);
      const cand = candidates[row];
      const label = "USURP: ";
      fb.drawText(label, 2, 11, 1);
      const afterLabel = 2 + fb.measureText(label);
      const pMatch = cand.match(/^P(\d+)$/);
      if (pMatch) {
        const pi = parseInt(pMatch[1]);
        const p = sim.players[pi];
        if (p) drawPlayerSprite(fb, afterLabel, 11, p.shape, sim.playerColor(pi));
      } else {
        fb.drawText(cand, afterLabel, 11, 2);
      }
      votingBottomY = 20;
    }
    fb.drawText("H/I:TAB L:CLOSE K:NEXT", 2, barY + 2, 1);
  }

  fb.fillRect(0, votingBottomY, SCREEN_WIDTH, 1, 1);

  const msgAreaTop = votingBottomY + 2;
  const msgAreaBot = barY - 1;
  const lineH = 7;
  const maxLines = Math.floor((msgAreaBot - msgAreaTop) / lineH);

  if (maxLines > 0) {
    const messages = sim.shoutMessagesForPlayer(viewerIndex);
    const showCount = Math.min(messages.length, maxLines);
    const startIdx = Math.max(0, messages.length - showCount - viewer.shoutScroll);
    let y = msgAreaBot - showCount * lineH;
    for (let i = startIdx; i < startIdx + showCount && i < messages.length; i++) {
      drawChatMsg(sim, fb, messages[i], 2, y);
      y += lineH;
    }
  }

  fb.pack();
  return fb.packed;
}

function renderMinimap(sim: Sim, fb: Framebuffer, viewerIndex: number) {
  const viewer = sim.players[viewerIndex];
  const scaleX = MINIMAP_SIZE / sim.roomW;
  const scaleY = MINIMAP_SIZE / sim.roomH;
  const base = sim.floorColor(viewer.room);

  // Minimap overlays everything — write directly to indices
  const put = (x: number, y: number, c: uint8) => {
    if (x >= 0 && y >= 0 && x < SCREEN_WIDTH && y < SCREEN_HEIGHT)
      fb.indices[y * SCREEN_WIDTH + x] = c & 0x0f;
  };
  const fill = (rx: number, ry: number, rw: number, rh: number, c: uint8) => {
    for (let py = Math.max(0, ry); py < Math.min(SCREEN_HEIGHT, ry + rh); py++)
      for (let px = Math.max(0, rx); px < Math.min(SCREEN_WIDTH, rx + rw); px++)
        fb.indices[py * SCREEN_WIDTH + px] = c & 0x0f;
  };

  fill(MINIMAP_X - 1, MINIMAP_Y - 1, MINIMAP_SIZE + 2, MINIMAP_SIZE + 2, 0);
  for (let dx = 0; dx < MINIMAP_SIZE + 2; dx++) {
    put(MINIMAP_X - 1 + dx, MINIMAP_Y - 1, 1);
    put(MINIMAP_X - 1 + dx, MINIMAP_Y + MINIMAP_SIZE, 1);
  }
  for (let dy = 0; dy < MINIMAP_SIZE + 2; dy++) {
    put(MINIMAP_X - 1, MINIMAP_Y - 1 + dy, 1);
    put(MINIMAP_X + MINIMAP_SIZE, MINIMAP_Y - 1 + dy, 1);
  }
  fill(MINIMAP_X, MINIMAP_Y, MINIMAP_SIZE, MINIMAP_SIZE, base);

  for (const ob of sim.obstacles) {
    if (ob.room !== viewer.room) continue;
    put(MINIMAP_X + Math.floor(ob.x * scaleX), MINIMAP_Y + Math.floor(ob.y * scaleY), 5);
  }

  const showAll = sim.phase === Phase.Lobby || sim.phase === Phase.Reveal || sim.phase === Phase.GameOver;
  const useFog = sim.phase === Phase.Playing || sim.phase === Phase.PsychopompSelect || sim.phase === Phase.LeaderSummit;
  const camView = playerView(sim, viewerIndex);
  const n = sim.players.length;
  const mmOrder: number[] = [];
  for (let k = 1; k < n; k++) mmOrder.push((viewerIndex + k) % n);
  mmOrder.push(viewerIndex);
  for (const i of mmOrder) {
    const p = sim.players[i];
    if (!showAll && p.room !== viewer.room) continue;
    if (i !== viewerIndex && useFog) {
      const sx = p.x + Math.floor(PLAYER_W / 2) - camView.cameraX;
      const sy = p.y + Math.floor(PLAYER_H / 2) - camView.cameraY;
      if (sx >= 0 && sx < SCREEN_WIDTH && sy >= 0 && sy < SCREEN_HEIGHT && sim.shadowBuf[sy * SCREEN_WIDTH + sx]) continue;
    }
    put(MINIMAP_X + Math.floor((p.x + PLAYER_W / 2) * scaleX), MINIMAP_Y + Math.floor((p.y + PLAYER_H / 2) * scaleY), i === viewerIndex ? 2 : sim.playerColor(i));
  }
}

function renderHud(
  sim: Sim, fb: Framebuffer, viewerIndex: number,
  topBar: FrameRegion, bottomBar: FrameRegion, chatStrip: FrameRegion | null,
) {
  const viewer = sim.players[viewerIndex];
  if (!viewer) return;

  topBar.fillRect(topBar.x0, topBar.y0, topBar.w, topBar.h, 0);
  switch (sim.phase) {
    case Phase.Lobby: {
      topBar.drawText(`${sim.players.length}/${playerCountFromConfig(sim.config)} PLAYERS`, 2, 2, 2);
      if (sim.lobbyCountdown > 0) {
        topBar.drawText(`START ${Math.ceil(sim.lobbyCountdown / TARGET_FPS)}`, 80, 2, 8);
      }
      break;
    }
    case Phase.Playing: {
      topBar.drawText(roundClockText(sim), 2, 2, 2);
      const rn = sim.roleName(viewer.role) + (viewer.isLeader ? "*" : "");
      topBar.drawText(rn, SCREEN_WIDTH - MINIMAP_SIZE - 4 - topBar.measureText(rn), 2, sim.teamColor(viewer.team));
      if (chatStrip) {
        const shoutMsgs = coalesceChatFragments(sim.shoutMessagesForPlayer(viewerIndex));
        const last = shoutMsgs[shoutMsgs.length - 1];
        if (last) {
          const stripY = chatStrip.y0;
          chatStrip.fillRect(chatStrip.x0, stripY, chatStrip.w, chatStrip.h, 0);
          const senderColor = last.senderIndex >= 0 ? sim.playerColor(last.senderIndex) : 2;
          chatStrip.putPixel(0, stripY, 8);
          chatStrip.putPixel(0, stripY + 1, 8);
          chatStrip.putPixel(0, stripY + 2, 8);
          chatStrip.drawText(last.text.slice(0, 29), 2, stripY, senderColor);
        }
      }
      break;
    }
    case Phase.PsychopompSelect: {
      const committed = viewer.room === Room.RoomA ? sim.committedA : sim.committedB;
      const secs = Math.max(0, Math.ceil(sim.psychopompSelectTimer / TARGET_FPS));
      topBar.drawText(roundClockText(sim), 2, 2, 2);
      topBar.drawText(`SELECT ${secs}S`, 42, 2, viewer.isLeader && !committed ? 8 : 1);
      if (chatStrip) {
        const shoutMsgs = coalesceChatFragments(sim.shoutMessagesForPlayer(viewerIndex));
        const last = shoutMsgs[shoutMsgs.length - 1];
        if (last) {
          const stripY = chatStrip.y0;
          chatStrip.fillRect(chatStrip.x0, stripY, chatStrip.w, chatStrip.h, 0);
          const senderColor = last.senderIndex >= 0 ? sim.playerColor(last.senderIndex) : 2;
          chatStrip.putPixel(0, stripY, 8);
          chatStrip.putPixel(0, stripY + 1, 8);
          chatStrip.putPixel(0, stripY + 2, 8);
          chatStrip.drawText(last.text.slice(0, 29), 2, stripY, senderColor);
        }
      }
      break;
    }
    case Phase.LeaderSummit: {
      const secs = Math.max(0, Math.ceil(sim.leaderSummitTimer / TARGET_FPS));
      topBar.drawText(roundClockText(sim), 2, 2, 2);
      if (viewer.isLeader) {
        topBar.drawText(`SUMMIT ${secs}S`, 42, 2, 8);
      } else {
        topBar.drawText(`LEADERS MEET ${secs}S`, 42, 2, 1);
      }
      const rn2 = sim.roleName(viewer.role) + (viewer.isLeader ? "*" : "");
      topBar.drawText(rn2, SCREEN_WIDTH - MINIMAP_SIZE - 4 - topBar.measureText(rn2), 2, sim.teamColor(viewer.team));
      if (chatStrip) {
        const shoutMsgs = coalesceChatFragments(sim.shoutMessagesForPlayer(viewerIndex));
        const last = shoutMsgs[shoutMsgs.length - 1];
        if (last) {
          const stripY = chatStrip.y0;
          chatStrip.fillRect(chatStrip.x0, stripY, chatStrip.w, chatStrip.h, 0);
          const senderColor = last.senderIndex >= 0 ? sim.playerColor(last.senderIndex) : 2;
          chatStrip.putPixel(0, stripY, 8);
          chatStrip.putPixel(0, stripY + 1, 8);
          chatStrip.putPixel(0, stripY + 2, 8);
          chatStrip.drawText(last.text.slice(0, 29), 2, stripY, senderColor);
        }
      }
      break;
    }
    case Phase.PsychopompExchange:
      topBar.drawText(roundClockText(sim), 2, 2, 2);
      topBar.drawText("EXCHANGING", 42, 2, 8);
      break;
    case Phase.Reveal: {
      const winText = sim.winner === Team.TeamA ? `${TEAM_A_NAME} WIN!` : sim.winner === Team.TeamB ? `${TEAM_B_NAME} WIN!` : "NO ONE WINS!";
      const wc = sim.winner === Team.TeamA ? TEAM_A_COLOR : sim.winner === Team.TeamB ? TEAM_B_COLOR : 1;
      topBar.drawText(roundClockText(sim), 2, 2, 2);
      topBar.drawText("REVEAL!", 42, 2, 2);
      fb.drawText(winText, Math.floor((SCREEN_WIDTH - fb.measureText(winText)) / 2), 60, wc);
      break;
    }
    case Phase.GameOver: {
      const winText = sim.winner === Team.TeamA ? `${TEAM_A_NAME} WIN!` : sim.winner === Team.TeamB ? `${TEAM_B_NAME} WIN!` : "NO ONE WINS!";
      const wc = sim.winner === Team.TeamA ? TEAM_A_COLOR : sim.winner === Team.TeamB ? TEAM_B_COLOR : 1;
      fb.drawText(winText, Math.floor((SCREEN_WIDTH - fb.measureText(winText)) / 2), 60, wc);
      break;
    }
  }

  const barY = bottomBar.y0;
  bottomBar.fillRect(bottomBar.x0, barY, bottomBar.w, bottomBar.h, 0);

  if (sim.phase === Phase.Playing || sim.phase === Phase.PsychopompSelect || sim.phase === Phase.LeaderSummit) {
    if (viewer.pendingWhisperEntry >= 0) {
      bottomBar.drawText("WAITING...", 2, barY + 2, 8);
      const unread = sim.shoutUnreadCount(viewerIndex);
      if (unread > 0 && (sim.tickCount & 16)) {
        bottomBar.putPixel(SCREEN_WIDTH - 4, barY + 4, 11);
      }
    } else if (viewer.noticeText && sim.tickCount < viewer.noticeUntilTick) {
      bottomBar.drawText(viewer.noticeText, 2, barY + 2, 8);
    } else {
      bottomBar.drawText("J:NEW K:JOIN L:SHOUT", 2, barY + 2, 1);
      const unread = sim.shoutUnreadCount(viewerIndex);
      if (unread > 0 && (sim.tickCount & 16)) {
        bottomBar.putPixel(SCREEN_WIDTH - 4, barY + 4, 11);
      }
    }
  }
}

function renderIntro(sim: Sim, fb: Framebuffer, viewerIndex: number): Buffer {
  const secs = Math.ceil(sim.revealTimer / TARGET_FPS);
  if (sim.introPanel === 0) return renderIntroRoster(sim, fb, secs);
  if (sim.introPanel === 1) return renderIntroRole(sim, fb, viewerIndex, secs);
  if (sim.introPanel === 2) return renderIntroRoleSummary(sim, fb, secs);
  return renderIntroSchedule(sim, fb, secs);
}

function renderIntroRoster(sim: Sim, fb: Framebuffer, secs: number): Buffer {
  fb.clear(0);
  fb.drawRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 2);
  fb.drawRect(2, 2, SCREEN_WIDTH - 4, SCREEN_HEIGHT - 4, 2);

  const cx = (text: string) => Math.floor((SCREEN_WIDTH - fb.measureText(text)) / 2);
  fb.drawText("PLAYER ROSTER", cx("PLAYER ROSTER"), 6, 2);

  const columns = [
    { title: "UNDERWORLD", room: Room.RoomA, x: 5, color: 8 },
    { title: "MORTAL REALM", room: Room.RoomB, x: 67, color: 11 },
  ];
  const startY = 25;
  const rowH = 15;
  const nameXOff = PLAYER_W + 5;

  for (const col of columns) {
    fb.drawText(col.title, col.x, 17, col.color);
    let row = 0;
    for (let i = 0; i < sim.players.length; i++) {
      const p = sim.players[i];
      if (p.room !== col.room) continue;
      const y = startY + row * rowH;
      if (y > SCREEN_HEIGHT - 22) break;
      drawPlayerSprite(fb, col.x, y, p.shape, sim.playerColor(i));
      fb.drawText(playerSpriteName(i), col.x + nameXOff, y + 1, 1);
      row++;
    }
  }

  const startText = `NEXT IN ${secs}`;
  fb.drawText(startText, cx(startText), SCREEN_HEIGHT - 10, 2);

  fb.pack();
  return fb.packed;
}

function renderIntroRole(sim: Sim, fb: Framebuffer, viewerIndex: number, secs: number): Buffer {
  const viewer = sim.players[viewerIndex];
  const tc = sim.teamColor(viewer.team);

  fb.clear(0);
  fb.drawRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, tc);
  fb.drawRect(2, 2, SCREEN_WIDTH - 4, SCREEN_HEIGHT - 4, tc);

  const roleName = sim.roleName(viewer.role);
  const teamName = viewer.team === Team.TeamA ? TEAM_A_NAME : viewer.team === Team.TeamB ? TEAM_B_NAME : "NEUTRAL";
  const roomName = viewer.room === Room.RoomA ? ROOM_A_NAME : ROOM_B_NAME;

  let y = 8;
  const cx = (text: string) => Math.floor((SCREEN_WIDTH - fb.measureText(text)) / 2);

  const spriteX = Math.floor((SCREEN_WIDTH - PLAYER_W) / 2);
  drawPlayerSprite(fb, spriteX, y, viewer.shape, sim.playerColor(viewerIndex));
  y += 10;

  fb.drawText("YOU ARE", cx("YOU ARE"), y, 2); y += 10;
  fb.drawText(roleName, cx(roleName), y, tc); y += 10;
  fb.drawText(teamName + " TEAM", cx(teamName + " TEAM"), y, tc); y += 10;
  fb.drawText("ASSIGNED TO", cx("ASSIGNED TO"), y, 1); y += 8;
  fb.drawText(roomName, cx(roomName), y, 2); y += 10;

  const infoLine = `${sim.players.length}P  ${sim.roomW}x${sim.roomH}`;
  fb.drawText(infoLine, cx(infoLine), y, 1); y += 8;
  fb.drawText("MATCH ROLES NEXT", cx("MATCH ROLES NEXT"), y, 1); y += 10;

  fb.drawText("WASD  MOVE", 14, y, 1); y += 8;
  fb.drawText("J     NEW   K  JOIN", 14, y, 1); y += 8;
  fb.drawText("L     SHOUT/COMMIT", 14, y, 1); y += 10;

  const startText = `STARTING IN ${secs}`;
  fb.drawText(startText, cx(startText), y, 2);

  fb.pack();
  return fb.packed;
}

function roleSummaryNames(sim: Sim): string[] {
  const names: string[] = [];
  const seen = new Set<string>();
  for (const p of sim.players) {
    const name = sim.roleName(p.role);
    if (!seen.has(name)) {
      seen.add(name);
      names.push(name);
    }
  }
  return names;
}

function renderIntroRoleSummary(sim: Sim, fb: Framebuffer, secs: number): Buffer {
  fb.clear(0);
  fb.drawRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 2);
  fb.drawRect(2, 2, SCREEN_WIDTH - 4, SCREEN_HEIGHT - 4, 2);

  const cx = (text: string) => Math.floor((SCREEN_WIDTH - fb.measureText(text)) / 2);
  let y = 8;

  fb.drawText("MATCH ROLES", cx("MATCH ROLES"), y, 2); y += 12;
  y = drawWrappedLines(fb, roleSummaryNames(sim), 6, y, 1, SCREEN_WIDTH - 12);

  const missing = sim.missingCoreRoles();
  if (missing.length > 0 && y < SCREEN_HEIGHT - 24) {
    y += 2;
    fb.drawText("MISSING:", 6, y, 8); y += 8;
    y = drawWrappedLines(fb, [missing.map(role => sim.roleName(role)).join(" ")], 6, y, 1, SCREEN_WIDTH - 12);
  }

  const echoes = sim.activeEchoSubstitutions();
  if (echoes.length > 0 && y < SCREEN_HEIGHT - 24) {
    y += 2;
    fb.drawText("ECHO ACTIVE:", 6, y, 11); y += 8;
    for (const row of echoes) {
      if (y >= SCREEN_HEIGHT - 16) break;
      y = drawWrappedLines(fb, [`${sim.roleName(row.echoRole)} -> ${sim.roleName(row.coreRole)}`], 6, y, 1, SCREEN_WIDTH - 12);
    }
  }

  const startText = `STARTING IN ${secs}`;
  fb.drawText(startText, cx(startText), SCREEN_HEIGHT - 10, 2);

  fb.pack();
  return fb.packed;
}

function renderIntroSchedule(sim: Sim, fb: Framebuffer, secs: number): Buffer {
  fb.clear(0);
  fb.drawRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 2);
  fb.drawRect(2, 2, SCREEN_WIDTH - 4, SCREEN_HEIGHT - 4, 2);

  let y = 8;
  const cx = (text: string) => Math.floor((SCREEN_WIDTH - fb.measureText(text)) / 2);

  fb.drawText("ROUND SCHEDULE", cx("ROUND SCHEDULE"), y, 2); y += 12;

  fb.drawText("ROUND  TIME  PSYCHOPOMP", 10, y, 1); y += 8;

  const rounds = sim.config.rounds;
  for (let i = 0; i < Math.min(rounds.length, 5); i++) {
    const r = rounds[i];
    const mins = Math.floor(r.durationSecs / 60);
    const rsecs = r.durationSecs % 60;
    const timeStr = `${mins}:${rsecs.toString().padStart(2, "0")}`;
    const line = `  ${i + 1}      ${timeStr}     ${r.psychopomps}`;
    fb.drawText(line, 10, y, 2); y += 8;
  }

  y += 4;
  const startText = `STARTING IN ${secs}`;
  fb.drawText(startText, cx(startText), y, 2);

  fb.pack();
  return fb.packed;
}

function renderInfoScreen(sim: Sim, fb: Framebuffer, viewerIndex: number): Buffer {
  const viewer = sim.players[viewerIndex];
  fb.clear(0);

  if (viewer.infoScreen === "role") {
    const tc = sim.teamColor(viewer.team);
    fb.drawRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, tc);
    fb.drawRect(2, 2, SCREEN_WIDTH - 4, SCREEN_HEIGHT - 4, tc);

    const rn = sim.roleName(viewer.role);
    const tn = viewer.team === Team.TeamA ? TEAM_A_NAME : viewer.team === Team.TeamB ? TEAM_B_NAME : "NEUTRAL";
    const cx = (t: string) => Math.floor((SCREEN_WIDTH - fb.measureText(t)) / 2);

    let y = 20;
    fb.drawText("YOU ARE", cx("YOU ARE"), y, 2); y += 10;
    fb.drawText(rn, cx(rn), y, tc); y += 10;
    fb.drawText(tn, cx(tn), y, tc); y += 16;

    // Draw own sprite + role slot
    const sx = Math.floor(SCREEN_WIDTH / 2) - Math.floor(PLAYER_W / 2);
    drawPlayerSprite(fb, sx, y, viewer.shape, sim.playerColor(viewerIndex));
    drawRoleSlot(sim, fb, sx, y + PLAYER_H + 1, viewer.role, viewer.team);
    y += PLAYER_H + 6;

    fb.drawText("PRESS ANY KEY", cx("PRESS ANY KEY"), SCREEN_HEIGHT - 10, 1);
  } else if (viewer.infoScreen === "shared") {
    fb.drawText("KNOWN PLAYERS", 2, 2, 2);

    // Collect known players: self + anyone revealed to us
    const known: { pi: number; role: Role; showRole: boolean }[] = [];
    known.push({ pi: viewerIndex, role: viewer.role, showRole: true });

    for (let i = 0; i < sim.players.length; i++) {
      if (i === viewerIndex) continue;
      const p = sim.players[i];
      if (p.revealedTo.has(viewerIndex)) {
        known.push({ pi: i, role: p.role, showRole: true });
      } else if (p.colorRevealedTo.has(viewerIndex)) {
        known.push({ pi: i, role: p.role, showRole: false });
      }
    }

    const rowH = 11;
    const maxRows = Math.floor((SCREEN_HEIGHT - 22) / rowH);
    const scrollOffset = Math.min(viewer.infoScrollOffset, Math.max(0, known.length - maxRows));
    let y = 12;

    for (let k = scrollOffset; k < Math.min(known.length, scrollOffset + maxRows); k++) {
      const entry = known[k];
      const p = sim.players[entry.pi];
      const sx = 4;

      drawPlayerSprite(fb, sx, y, p.shape, sim.playerColor(entry.pi));

      if (entry.showRole) {
        drawRoleSlot(sim, fb, sx, y + PLAYER_H + 1, entry.role, sim.roleRevealTeam(entry.pi, viewerIndex));
      } else {
        fb.putPixel(sx + 3, y + PLAYER_H + 1, sim.colorRevealTeamColor(entry.pi));
      }

      const infoX = sx + PLAYER_W + 4;
      if (entry.showRole) {
        const rn = sim.roleName(entry.role);
        fb.drawText(rn, infoX, y + 2, sim.teamColor(sim.roleRevealTeam(entry.pi, viewerIndex)));
      } else {
        fb.drawText("???", infoX, y + 2, 1);
      }

      y += rowH;
    }

    if (known.length === 1) {
      fb.drawText("NO SHARES YET", 20, 40, 1);
    }

    if (known.length > maxRows) {
      const scrollPct = scrollOffset / Math.max(1, known.length - maxRows);
      const trackTop = 12;
      const trackBot = SCREEN_HEIGHT - 12;
      const thumbY = trackTop + Math.floor(scrollPct * (trackBot - trackTop - 4));
      fb.putPixel(SCREEN_WIDTH - 3, thumbY, 2);
      fb.putPixel(SCREEN_WIDTH - 3, thumbY + 1, 2);
    }

    fb.drawText("UP/DN SCROLL", 2, SCREEN_HEIGHT - 8, 1);
  }

  fb.pack();
  return fb.packed;
}

function renderExchangeRow(sim: Sim, fb: Framebuffer, pi: number, x: number, y: number) {
  if (pi < 0 || pi >= sim.players.length) return;
  const p = sim.players[pi];
  drawPlayerSprite(fb, x, y, p.shape, sim.playerColor(pi));
  drawRoleSlot(sim, fb, x, y + PLAYER_H + 1, p.role, p.team);
}

function renderExchange(sim: Sim, fb: Framebuffer, viewerIndex: number): Buffer {
  const viewer = sim.players[viewerIndex];
  const isLeader = viewerIndex === sim.exchangeLeaderA || viewerIndex === sim.exchangeLeaderB;
  const inRoomA = viewer.room === Room.RoomA;
  fb.clear(0);

  const floorC = sim.floorColor(viewer.room);
  for (let sy = 12; sy < SCREEN_HEIGHT - BOTTOM_BAR_H; sy++) {
    for (let sx = 4; sx < SCREEN_WIDTH - 4; sx++) {
      fb.putPixel(sx, sy, floorC);
    }
  }

  const cx = (text: string) => Math.floor((SCREEN_WIDTH - fb.measureText(text)) / 2);

  // Title
  const title = "PSYCHOPOMP EXCHANGE";
  fb.drawText(title, cx(title), 14, 8);

  const departing = inRoomA ? sim.exchangeFromA : sim.exchangeFromB;
  const arriving = inRoomA ? sim.exchangeFromB : sim.exchangeFromA;
  const myLeader = inRoomA ? sim.exchangeLeaderA : sim.exchangeLeaderB;
  const otherLeader = inRoomA ? sim.exchangeLeaderB : sim.exchangeLeaderA;

  let y = 26;

  // Your room's leader
  const leaderLabel = isLeader ? "LEADERS" : "LEADER";
  fb.drawText(leaderLabel, 8, y, 2);
  y += 7;
  renderExchangeRow(sim, fb, myLeader, 10, y);
  if (isLeader) {
    renderExchangeRow(sim, fb, otherLeader, 30, y);
  }
  y += 14;

  // Both psychopomp groups
  fb.drawText("DEPARTING", 8, y, 8);
  y += 7;
  for (const h of departing) {
    renderExchangeRow(sim, fb, h.pi, 10, y);
    y += 14;
  }

  fb.drawText("ARRIVING", 8, y, 11);
  y += 7;
  for (const h of arriving) {
    renderExchangeRow(sim, fb, h.pi, 10, y);
    y += 14;
  }

  // Bottom bar
  const barY = SCREEN_HEIGHT - BOTTOM_BAR_H;
  fb.fillRect(0, barY, SCREEN_WIDTH, BOTTOM_BAR_H, 0);
  const isPsychopomp = sim.exchangeFromA.some(h => h.pi === viewerIndex) || sim.exchangeFromB.some(h => h.pi === viewerIndex);
  if (isPsychopomp) {
    fb.drawText("YOU ARE BEING EXCHANGED", 2, barY + 2, 8);
  } else if (isLeader) {
    fb.drawText("ESCORTING PSYCHOPOMPS", 2, barY + 2, 2);
  } else {
    fb.drawText("PSYCHOPOMPS EXCHANGING...", 2, barY + 2, 1);
  }

  fb.pack();
  return fb.packed;
}

export function render(sim: Sim, viewerIndex: number): Buffer {
  const fb = sim.fb;
  fb.clear(0);

  if (viewerIndex < 0 || viewerIndex >= sim.players.length) {
    fb.pack();
    return fb.packed;
  }

  const viewer = sim.players[viewerIndex];

  if (sim.phase === Phase.RosterReveal || sim.phase === Phase.RoleReveal) {
    return renderIntro(sim, fb, viewerIndex);
  }

  if (sim.phase === Phase.PsychopompExchange) {
    return renderExchange(sim, fb, viewerIndex);
  }

  if (viewer.infoScreen !== "none") {
    return renderInfoScreen(sim, fb, viewerIndex);
  }

  if (viewer.shoutOpen || (sim.phase === Phase.PsychopompSelect && viewer.isLeader)) {
    return renderShoutView(sim, fb, viewerIndex);
  }

  if (viewer.inWhisper >= 0) {
    return renderWhisperView(sim, fb, viewerIndex);
  }

  // Claim HUD regions before drawing world — world pixels can't bleed in
  const barY = SCREEN_HEIGHT - BOTTOM_BAR_H;
  const topBar = fb.region("hud-top", 0, 0, SCREEN_WIDTH, 9);
  const bottomBar = fb.region("hud-bottom", 0, barY, SCREEN_WIDTH, BOTTOM_BAR_H);
  const chatStrip = (sim.phase === Phase.Playing || sim.phase === Phase.PsychopompSelect || sim.phase === Phase.LeaderSummit)
    ? fb.region("hud-chat-strip", 0, barY - 7, SCREEN_WIDTH, 7)
    : null;
  const drawMinimap = sim.phase !== Phase.Lobby;

  const view = playerView(sim, viewerIndex);
  const { cameraX, cameraY } = view;

  const room = viewer.room;
  for (let sy = 0; sy < SCREEN_HEIGHT; sy++) {
    for (let sx = 0; sx < SCREEN_WIDTH; sx++) {
      const mx = cameraX + sx;
      const my = cameraY + sy;
      if (mx < 0 || my < 0 || mx >= sim.roomW || my >= sim.roomH) {
        fb.putPixel(sx, sy, 0);
      } else if (sim.isWallInRoom(room, mx, my)) {
        fb.putPixel(sx, sy, 5);
      } else {
        fb.putPixel(sx, sy, sim.floorColorAt(room, mx, my));
      }
    }
  }

  // Fog of war — compute before drawing players so we can hide shadowed ones
  const useFog = sim.phase === Phase.Playing || sim.phase === Phase.PsychopompSelect || sim.phase === Phase.LeaderSummit;
  if (useFog) {
    sim.castShadows(viewer.room, view.originMx, view.originMy, cameraX, cameraY);
    const base = sim.floorColor(room);
    const alt = room === Room.RoomA ? 6 : 10;
    for (let idx = 0; idx < SCREEN_WIDTH * SCREEN_HEIGHT; idx++) {
      if (sim.shadowBuf[idx] && fb.owners[idx] === 0) {
        const c = fb.indices[idx] & 0x0f;
        if (c !== 5) {
          fb.indices[idx] = SHADOW_MAP[c];
        }
      }
    }
  }

  const showAll = sim.phase === Phase.Reveal || sim.phase === Phase.GameOver || sim.phase === Phase.Lobby;
  const n = sim.players.length;
  const drawOrder: number[] = [];
  for (let k = 1; k < n; k++) {
    drawOrder.push((viewerIndex + k) % n);
  }
  drawOrder.push(viewerIndex);
  const visiblePlayers: { pi: number; sx: number; sy: number }[] = [];
  for (const i of drawOrder) {
    const p = sim.players[i];
    if (!showAll && p.room !== viewer.room) continue;

    const sx = p.x - cameraX;
    const sy = p.y - cameraY;
    if (sx + PLAYER_W < 0 || sx >= SCREEN_WIDTH || sy + PLAYER_H < 0 || sy >= SCREEN_HEIGHT) continue;

    // Hide players in shadow (except self)
    if (useFog && i !== viewerIndex) {
      const cx = sx + Math.floor(PLAYER_W / 2);
      const cy = sy + Math.floor(PLAYER_H / 2);
      if (cx >= 0 && cx < SCREEN_WIDTH && cy >= 0 && cy < SCREEN_HEIGHT && sim.shadowBuf[cy * SCREEN_WIDTH + cx]) continue;
    }

    visiblePlayers.push({ pi: i, sx, sy });
  }

  for (const player of visiblePlayers) {
    drawPlayerWorldAccoutrements(sim, fb, viewerIndex, player.pi, player.sx, player.sy, showAll);
  }

  for (const player of visiblePlayers) {
    const p = sim.players[player.pi];
    drawPlayerSprite(fb, player.sx, player.sy, p.shape, sim.playerColor(player.pi));
  }

  renderHud(sim, fb, viewerIndex, topBar, bottomBar, chatStrip);

  if (drawMinimap) {
    renderMinimap(sim, fb, viewerIndex);
  }

  fb.pack();
  return fb.packed;
}

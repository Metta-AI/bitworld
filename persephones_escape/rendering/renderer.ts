import type { Sim } from "../sim.js";
import type { uint8 } from "../types.js";
import { Phase, Team, Role, Room, PlayerShape } from "../types.js";
import { Framebuffer, FrameRegion } from "./framebuffer.js";
import {
  SCREEN_WIDTH, SCREEN_HEIGHT,
  PLAYER_W, PLAYER_H,
  TARGET_FPS,
  BOTTOM_BAR_H, MINIMAP_SIZE, MINIMAP_X, MINIMAP_Y,
  SHADOW_MAP, PLAYER_SHAPES,
  TEAM_A_NAME, TEAM_B_NAME, TEAM_A_COLOR, TEAM_B_COLOR,
  ROOM_A_NAME, ROOM_B_NAME, LEADER_A_NAME, LEADER_B_NAME,
  playerCountFromConfig,
} from "../constants.js";
import { clamp, coalesceChatFragments } from "../util.js";
import { CHATROOM_MENU, chatMenuAction, chatMenuItemLabel } from "../menu_defs.js";

function drawRichText(sim: Sim, fb: Framebuffer, text: string, x: number, y: number, color: uint8) {
  let cx = x;
  let i = 0;
  while (i < text.length && cx < SCREEN_WIDTH - 2) {
    if (text.charCodeAt(i) === 1 && i + 1 < text.length) {
      const pi = text.charCodeAt(i + 1);
      if (pi >= 0 && pi < sim.players.length) {
        const p = sim.players[pi];
        drawPlayerSprite(fb, cx, y, p.shape, sim.playerColor(pi));
        cx += PLAYER_W + 1;
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

function drawChatMessage(sim: Sim, fb: Framebuffer, m: { type: string; senderIndex: number; text: string }, x: number, y: number) {
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

function drawRoleSlot(sim: Sim, fb: Framebuffer, sx: number, slotY: number, role: Role) {
  const ind = sim.roleIndicator(role);
  fb.fillRect(sx + 1, slotY, 5, 2, ind.color);
  if (role === Role.Hades) {
    fb.putPixel(sx + 3, slotY, 8);
    fb.putPixel(sx + 3, slotY + 1, 8);
  } else if (role === Role.Persephone) {
    fb.putPixel(sx + 3, slotY, 2);
    fb.putPixel(sx + 3, slotY + 1, 2);
  } else if (role === Role.Cerberus) {
    fb.putPixel(sx + 2, slotY, 8);
    fb.putPixel(sx + 4, slotY, 8);
  } else if (role === Role.Demeter) {
    fb.putPixel(sx + 2, slotY, 2);
    fb.putPixel(sx + 4, slotY, 2);
  }
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

function renderChatroomView(sim: Sim, fb: Framebuffer, viewerIndex: number): Buffer {
  const viewer = sim.players[viewerIndex];
  fb.clear(0);

  fb.fillRect(0, 0, SCREEN_WIDTH, 9, 0);
  fb.drawText("CHAT", 2, 2, 2);
  const cr = sim.chatrooms.get(viewer.inChatroom);
  if (cr) {
    let sx = 22;
    for (const oi of cr.occupants) {
      if (sx + PLAYER_W > SCREEN_WIDTH - 2) break;
      drawPlayerSprite(fb, sx, 1, sim.players[oi].shape, sim.playerColor(oi));
      sx += PLAYER_W + 2;
    }
  }

  const barY = SCREEN_HEIGHT - BOTTOM_BAR_H;
  fb.fillRect(0, barY, SCREEN_WIDTH, BOTTOM_BAR_H, 0);

  if (viewer.shareSelectOpen) {
    const isColor = viewer.shareSelectMode === "color";
    const offerers = isColor ? sim.chatroomColorOfferers(viewerIndex) : sim.chatroomShareOfferers(viewerIndex);
    if (offerers.length > 0) {
      const label = isColor ? "COLOR:" : "ROLE:";
      fb.drawText(label, 2, barY + 2, 8);
      let sx = 2 + fb.measureText(label) + 2;
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
  } else if (viewer.chatMenuOpen) {
    const cat = CHATROOM_MENU[viewer.chatMenuCat];
    if (cat) {
      const toggled = sim.chatroomToggledActions(viewerIndex);
      const itemIdx = Math.min(viewer.chatMenuItem, cat.items.length - 1);
      const action = chatMenuAction(viewer.chatMenuCat, itemIdx, toggled);
      const label = action ? chatMenuItemLabel(cat, itemIdx, toggled.has(cat.items[itemIdx].action)) : "";
      const enabled = action ? sim.chatroomActionEnabled(viewerIndex, action) : false;
      const color: uint8 = enabled ? 2 : 1;
      fb.drawText(`(${cat.label}) ${label}`, 2, barY + 2, color);
    }
  } else {
    fb.drawText("L:EXIT  K:ACTIONS  ENTER:MSG", 2, barY + 2, 1);
    // Pending-offer indicators — steady, not blinking — so frame parsers can detect reliably.
    const roleOfferers = sim.chatroomShareOfferers(viewerIndex);
    const colorOfferers = sim.chatroomColorOfferers(viewerIndex);
    if (roleOfferers.length > 0) {
      fb.drawText("R!", SCREEN_WIDTH - 10, barY + 2, 8);
    } else if (colorOfferers.length > 0) {
      fb.drawText("C!", SCREEN_WIDTH - 10, barY + 2, 8);
    }
  }

  const msgAreaTop = 10;
  const msgAreaBot = barY - 1;
  const lineH = 7;
  const maxLines = Math.floor((msgAreaBot - msgAreaTop) / lineH);

  const messages = sim.chatroomMessagesForPlayer(viewerIndex);
  const hasPending = !!(cr && cr.pendingEntry.length > 0);

  const showCount = Math.min(messages.length, maxLines - (hasPending ? 1 : 0));
  const startIdx = Math.max(0, messages.length - showCount - viewer.chatScrollOffset);
  let y = msgAreaBot - showCount * lineH - (hasPending ? lineH : 0);
  for (let i = startIdx; i < startIdx + showCount && i < messages.length; i++) {
    const m = messages[i];
    drawChatMessage(sim, fb, m, 2, y);
    y += lineH;
  }

  // Draw pending-entry indicator LAST so it's not overwritten by messages.
  if (hasPending && cr) {
    const reqPi = cr.pendingEntry[0];
    const reqP = sim.players[reqPi];
    if (reqP) {
      const reqY = msgAreaBot - lineH;
      fb.fillRect(0, reqY - 1, SCREEN_WIDTH, lineH + 1, 0);
      fb.drawText("!", 2, reqY, 8);
      drawPlayerSprite(fb, 8, reqY, reqP.shape, sim.playerColor(reqPi));
      fb.drawText("WANTS IN", 8 + PLAYER_W + 2, reqY, 8);
    }
  }

  fb.pack();
  return fb.packed;
}

function renderGlobalChatView(sim: Sim, fb: Framebuffer, viewerIndex: number): Buffer {
  const viewer = sim.players[viewerIndex];
  fb.clear(0);

  const roomName = viewer.room === Room.RoomA ? ROOM_A_NAME : ROOM_B_NAME;
  fb.fillRect(0, 0, SCREEN_WIDTH, 9, 0);
  fb.drawText(`${roomName} CHAT`, 2, 2, 2);

  const barY = SCREEN_HEIGHT - BOTTOM_BAR_H;
  fb.fillRect(0, barY, SCREEN_WIDTH, BOTTOM_BAR_H, 0);

  const leaderHostage = sim.phase === Phase.HostageSelect && viewer.isLeader;

  let votingBottomY = 10;

  if (leaderHostage) {
    const eligible = sim.eligibleHostages(viewer.room);
    const cursor = viewer.room === Room.RoomA ? sim.hostageCursorA : sim.hostageCursorB;
    const selected = viewer.room === Room.RoomA ? sim.hostagesSelectedA : sim.hostagesSelectedB;
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

      const label = `${selected.length}/${sim.hostagesPerRoom} HOSTAGES`;
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
      const row = Math.min(viewer.globalChatActionRow, candidates.length - 1);
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
    fb.drawText("L:CLOSE  ENTER:TYPE", 2, barY + 2, 1);
  }

  fb.fillRect(0, votingBottomY, SCREEN_WIDTH, 1, 1);

  const msgAreaTop = votingBottomY + 2;
  const msgAreaBot = barY - 1;
  const lineH = 7;
  const maxLines = Math.floor((msgAreaBot - msgAreaTop) / lineH);

  if (maxLines > 0) {
    const messages = sim.globalMessagesForPlayer(viewerIndex);
    const showCount = Math.min(messages.length, maxLines);
    const startIdx = Math.max(0, messages.length - showCount - viewer.globalChatScroll);
    let y = msgAreaBot - showCount * lineH;
    for (let i = startIdx; i < startIdx + showCount && i < messages.length; i++) {
      drawChatMessage(sim, fb, messages[i], 2, y);
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
  const useFog = sim.phase === Phase.Playing || sim.phase === Phase.HostageSelect;
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
      const secs = Math.max(0, Math.ceil(sim.roundTimer / TARGET_FPS));
      topBar.drawText(`R${sim.currentRound + 1} ${Math.floor(secs / 60)}:${(secs % 60).toString().padStart(2, "0")}`, 2, 2, 2);
      const rn = sim.roleName(viewer.role);
      topBar.drawText(rn, SCREEN_WIDTH - MINIMAP_SIZE - 4 - topBar.measureText(rn), 2, sim.teamColor(viewer.team));
      if (chatStrip) {
        const globalMsgs = coalesceChatFragments(sim.globalMessagesForPlayer(viewerIndex));
        const last = globalMsgs[globalMsgs.length - 1];
        if (last && last.type === 'text') {
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
    case Phase.HostageSelect: {
      const committed = viewer.room === Room.RoomA ? sim.committedA : sim.committedB;
      const secs = Math.max(0, Math.ceil(sim.hostageSelectTimer / TARGET_FPS));
      if (viewer.isLeader && !committed) {
        topBar.drawText(`SELECT ${secs}S`, 2, 2, 8);
      } else if (committed) {
        topBar.drawText("WAITING...", 2, 2, 2);
      } else {
        const ln = viewer.room === Room.RoomA ? LEADER_A_NAME : LEADER_B_NAME;
        topBar.drawText(`${ln.toUpperCase()} PICKS ${secs}S`, 2, 2, 1);
      }
      break;
    }
    case Phase.HostageExchange:
      topBar.drawText("EXCHANGING", 2, 2, 8);
      break;
    case Phase.Reveal: {
      const winText = sim.winner === Team.TeamA ? `${TEAM_A_NAME} WIN!` : sim.winner === Team.TeamB ? `${TEAM_B_NAME} WIN!` : "NO ONE WINS!";
      const wc = sim.winner === Team.TeamA ? TEAM_A_COLOR : sim.winner === Team.TeamB ? TEAM_B_COLOR : 1;
      topBar.drawText("REVEAL!", 2, 2, 2);
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

  if (viewer.commMenuOpen) {
    const items = sim.commMenuItems(viewerIndex);
    const row = Math.min(viewer.commMenuRow, items.length - 1);
    const item = items[row] ?? "";
    bottomBar.drawText(`< ${item} >`, 2, barY + 2, 2);
  } else if (sim.phase === Phase.Playing || sim.phase === Phase.HostageSelect) {
    if (viewer.pendingChatroomEntry >= 0) {
      bottomBar.drawText("WAITING...", 2, barY + 2, 8);
      const unread = sim.globalUnreadCount(viewerIndex);
      if (unread > 0 && (sim.tickCount & 16)) {
        bottomBar.putPixel(SCREEN_WIDTH - 4, barY + 4, 11);
      }
    } else {
      bottomBar.drawText("J:CHAT  K:INFO  L:MENU", 2, barY + 2, 1);
      const unread = sim.globalUnreadCount(viewerIndex);
      if (unread > 0 && (sim.tickCount & 16)) {
        bottomBar.putPixel(SCREEN_WIDTH - 4, barY + 4, 11);
      }
    }
  }
}

function renderIntro(sim: Sim, fb: Framebuffer, viewerIndex: number): Buffer {
  const viewer = sim.players[viewerIndex];
  const tc = sim.teamColor(viewer.team);

  fb.clear(0);
  fb.drawRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, tc);
  fb.drawRect(2, 2, SCREEN_WIDTH - 4, SCREEN_HEIGHT - 4, tc);

  const roleName = sim.roleName(viewer.role);
  const teamName = viewer.team === Team.TeamA ? TEAM_A_NAME : viewer.team === Team.TeamB ? TEAM_B_NAME : "NEUTRAL";
  const roomName = viewer.room === Room.RoomA ? ROOM_A_NAME : ROOM_B_NAME;

  const rolesInPlay: string[] = [];
  const seen = new Set<string>();
  for (const p of sim.players) {
    const rn = sim.roleName(p.role);
    if (!seen.has(rn)) { seen.add(rn); rolesInPlay.push(rn); }
  }

  let y = 8;
  const cx = (text: string) => Math.floor((SCREEN_WIDTH - fb.measureText(text)) / 2);

  fb.drawText("YOU ARE", cx("YOU ARE"), y, 2); y += 10;
  fb.drawText(roleName, cx(roleName), y, tc); y += 10;
  fb.drawText(teamName + " TEAM", cx(teamName + " TEAM"), y, tc); y += 10;
  fb.drawText("ASSIGNED TO", cx("ASSIGNED TO"), y, 1); y += 8;
  fb.drawText(roomName, cx(roomName), y, 2); y += 10;

  const infoLine = `${sim.players.length}P  ${sim.roomW}x${sim.roomH}`;
  fb.drawText(infoLine, cx(infoLine), y, 1); y += 8;
  const rolesLine = rolesInPlay.join(" ");
  fb.drawText(rolesLine, cx(rolesLine), y, 1); y += 10;

  fb.drawText("WASD  MOVE", 14, y, 1); y += 8;
  fb.drawText("J     COMM  K  INFO", 14, y, 1); y += 8;
  fb.drawText("L     GLOBAL/COMMIT", 14, y, 1); y += 10;

  const secs = Math.ceil(sim.revealTimer / TARGET_FPS);
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
    drawRoleSlot(sim, fb, sx, y + PLAYER_H + 1, viewer.role);
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
        drawRoleSlot(sim, fb, sx, y + PLAYER_H + 1, entry.role);
      } else {
        fb.putPixel(sx + 3, y + PLAYER_H + 1, sim.teamColor(p.team));
      }

      const infoX = sx + PLAYER_W + 4;
      if (entry.showRole) {
        const rn = sim.roleName(entry.role);
        fb.drawText(rn, infoX, y + 2, sim.teamColor(p.team));
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
  drawRoleSlot(sim, fb, x, y + PLAYER_H + 1, p.role);
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
  const title = "HOSTAGE EXCHANGE";
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

  // Both hostage groups
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
  const isHostage = sim.exchangeFromA.some(h => h.pi === viewerIndex) || sim.exchangeFromB.some(h => h.pi === viewerIndex);
  if (isHostage) {
    fb.drawText("YOU ARE BEING EXCHANGED", 2, barY + 2, 8);
  } else if (isLeader) {
    fb.drawText("ESCORTING HOSTAGES", 2, barY + 2, 2);
  } else {
    fb.drawText("HOSTAGES EXCHANGING...", 2, barY + 2, 1);
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

  if (sim.phase === Phase.RoleReveal) {
    return renderIntro(sim, fb, viewerIndex);
  }

  if (sim.phase === Phase.HostageExchange) {
    return renderExchange(sim, fb, viewerIndex);
  }

  if (viewer.infoScreen !== "none") {
    return renderInfoScreen(sim, fb, viewerIndex);
  }

  if (viewer.inChatroom >= 0) {
    return renderChatroomView(sim, fb, viewerIndex);
  }

  if (viewer.globalChatOpen) {
    return renderGlobalChatView(sim, fb, viewerIndex);
  }

  // Claim HUD regions before drawing world — world pixels can't bleed in
  const barY = SCREEN_HEIGHT - BOTTOM_BAR_H;
  const topBar = fb.region("hud-top", 0, 0, SCREEN_WIDTH, 9);
  const bottomBar = fb.region("hud-bottom", 0, barY, SCREEN_WIDTH, BOTTOM_BAR_H);
  const chatStrip = (sim.phase === Phase.Playing)
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
  const useFog = sim.phase === Phase.Playing || sim.phase === Phase.HostageSelect;
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

    const color = sim.playerColor(i);
    drawPlayerSprite(fb, sx, sy, p.shape, color);

    if (p.isLeader) {
      fb.putPixel(sx + 1, sy - 2, 8);
      fb.putPixel(sx + 3, sy - 3, 8);
      fb.putPixel(sx + 5, sy - 2, 8);
      fb.putPixel(sx + 2, sy - 1, 8);
      fb.putPixel(sx + 3, sy - 1, 8);
      fb.putPixel(sx + 4, sy - 1, 8);
    }

    if (p.selectedAsHostage) fb.putPixel(sx + 3, sy - 1, 3);

    if (p.inChatroom >= 0) {
      fb.putPixel(sx - 3, sy - 3, 2);
      fb.putPixel(sx - 2, sy - 3, 2);
      fb.putPixel(sx - 1, sy - 3, 2);
      fb.putPixel(sx - 3, sy - 2, 2);
      fb.putPixel(sx - 2, sy - 2, 2);
      fb.putPixel(sx - 1, sy - 2, 2);
      fb.putPixel(sx,     sy - 1, 2);
    }

    if (p.pendingChatroomEntry >= 0 && (sim.tickCount & 8)) {
      fb.putPixel(sx + 3, sy - 1, 8);
    }

    const slotY = sy + PLAYER_H + 1;
    if (showAll || i === viewerIndex) {
      drawRoleSlot(sim, fb, sx, slotY, p.role);
    } else if (p.revealedTo.has(viewerIndex)) {
      drawRoleSlot(sim, fb, sx, slotY, p.role);
    } else if (p.colorRevealedTo.has(viewerIndex)) {
      fb.putPixel(sx + 3, slotY, sim.teamColor(p.team));
    }
  }

  renderHud(sim, fb, viewerIndex, topBar, bottomBar, chatStrip);

  if (drawMinimap) {
    renderMinimap(sim, fb, viewerIndex);
  }

  fb.pack();
  return fb.packed;
}

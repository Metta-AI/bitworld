import type { Sim } from "./sim.js";
import type { uint8 } from "./types.js";
import { Phase, Team, Role, Room, PlayerShape } from "./types.js";
import { Framebuffer } from "./framebuffer.js";
import {
  SCREEN_WIDTH, SCREEN_HEIGHT, ROOM_W, ROOM_H,
  PLAYER_W, PLAYER_H,
  TARGET_FPS,
  BOTTOM_BAR_H, MINIMAP_SIZE, MINIMAP_X, MINIMAP_Y,
  SHADOW_MAP, PLAYER_SHAPES,
  TEAM_A_NAME, TEAM_B_NAME, TEAM_A_COLOR, TEAM_B_COLOR,
  ROOM_A_NAME, ROOM_B_NAME, LEADER_A_NAME, LEADER_B_NAME,
} from "./constants.js";
import { clamp } from "./util.js";

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
    cameraX: clamp(cx - Math.floor(SCREEN_WIDTH / 2), 0, ROOM_W - SCREEN_WIDTH),
    cameraY: clamp(targetY, -topBar, ROOM_H - SCREEN_HEIGHT + botBar),
    originMx: cx,
    originMy: cy,
  };
}

export function drawPlayerSprite(fb: Framebuffer, sx: number, sy: number, shape: PlayerShape, color: uint8) {
  const pat = PLAYER_SHAPES[shape] ?? PLAYER_SHAPES[PlayerShape.Square];
  for (let dy = 0; dy < 7; dy++) {
    for (let dx = 0; dx < 7; dx++) {
      const v = pat[dy][dx];
      if (v === 1) fb.putPixel(sx + dx, sy + dy, 0);
      else if (v === 2) fb.putPixel(sx + dx, sy + dy, color);
    }
  }
}

export function renderHostageGrid(sim: Sim, fb: Framebuffer, viewerIndex: number) {
  const viewer = sim.players[viewerIndex];
  if (!viewer) return;
  const eligible = sim.eligibleHostages(viewer.room);
  if (eligible.length === 0) return;

  const cursor = viewer.room === Room.RoomA ? sim.hostageCursorA : sim.hostageCursorB;
  const selected = viewer.room === Room.RoomA ? sim.hostagesSelectedA : sim.hostagesSelectedB;

  const cellW = 12; const cellH = 14;
  const cols = Math.min(eligible.length, 4);
  const rows = Math.ceil(eligible.length / cols);
  const gridW = cols * cellW;
  const gridH = rows * cellH;
  const gridX = Math.floor((SCREEN_WIDTH - gridW) / 2);
  const gridY = Math.floor((SCREEN_HEIGHT - BOTTOM_BAR_H - gridH) / 2);

  fb.fillRect(gridX - 2, gridY - 2, gridW + 4, gridH + 10, 0);

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
    const offerers = sim.chatroomShareOfferers(viewerIndex);
    if (offerers.length > 0) {
      fb.drawText("ACCEPT:", 2, barY + 2, 8);
      let sx = 2 + fb.measureText("ACCEPT:") + 2;
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
    const actions = sim.chatroomActions(viewerIndex);
    if (actions.length > 0) {
      const row = Math.min(viewer.chatMenuRow, actions.length - 1);
      fb.drawText(`< ${actions[row]} >`, 2, barY + 2, 2);
    }
  } else {
    fb.drawText("J:EXIT  K:ACTIONS  ENTER:MSG", 2, barY + 2, 1);
  }

  const msgAreaTop = 10;
  const msgAreaBot = barY - 1;
  const lineH = 7;
  const maxLines = Math.floor((msgAreaBot - msgAreaTop) / lineH);

  const messages = sim.chatroomMessagesForPlayer(viewerIndex);

  if (cr && cr.pendingEntry.length > 0) {
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

  const showCount = Math.min(messages.length, maxLines - (cr && cr.pendingEntry.length > 0 ? 1 : 0));
  const startIdx = Math.max(0, messages.length - showCount - viewer.chatScrollOffset);
  let y = msgAreaBot - showCount * lineH;
  for (let i = startIdx; i < startIdx + showCount && i < messages.length; i++) {
    const m = messages[i];
    const color = m.type === 'system' ? 8 : (m.senderIndex >= 0 ? sim.playerColor(m.senderIndex) : 2);
    const prefix = m.type === 'system' ? "* " : ". ";
    const displayText = (prefix + m.text).slice(0, 30);
    fb.drawText(displayText, 2, y, color);
    y += lineH;
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
  const candidates = sim.usurpCandidates(viewerIndex);
  if (candidates.length > 0) {
    const row = Math.min(viewer.globalChatActionRow, candidates.length - 1);
    const cand = candidates[row];
    const label = "USURP: ";
    fb.drawText(label, 2, barY + 2, 1);
    const afterLabel = 2 + fb.measureText(label);
    const pMatch = cand.match(/^P(\d+)$/);
    if (pMatch) {
      const pi = parseInt(pMatch[1]);
      const p = sim.players[pi];
      if (p) drawPlayerSprite(fb, afterLabel, barY + 1, p.shape, sim.playerColor(pi));
    } else {
      fb.drawText(cand, afterLabel, barY + 2, 2);
    }
  } else {
    fb.drawText("J:CLOSE  ENTER:TYPE", 2, barY + 2, 1);
  }

  const msgAreaTop = 10;
  const msgAreaBot = barY - 1;
  const lineH = 7;
  const maxLines = Math.floor((msgAreaBot - msgAreaTop) / lineH);

  const messages = sim.globalMessagesForPlayer(viewerIndex);
  const showCount = Math.min(messages.length, maxLines);
  const startIdx = Math.max(0, messages.length - showCount - viewer.globalChatScroll);
  let y = msgAreaBot - showCount * lineH;
  for (let i = startIdx; i < startIdx + showCount && i < messages.length; i++) {
    const m = messages[i];
    const color = m.type === 'system' ? 8 : (m.senderIndex >= 0 ? sim.playerColor(m.senderIndex) : 2);
    const displayText = m.text.slice(0, 30);
    fb.drawText(displayText, 2, y, color);
    y += lineH;
  }

  fb.pack();
  return fb.packed;
}

function renderMinimap(sim: Sim, fb: Framebuffer, viewerIndex: number) {
  const viewer = sim.players[viewerIndex];
  const scaleX = MINIMAP_SIZE / ROOM_W;
  const scaleY = MINIMAP_SIZE / ROOM_H;
  const base = sim.floorColor(viewer.room);

  fb.fillRect(MINIMAP_X - 1, MINIMAP_Y - 1, MINIMAP_SIZE + 2, MINIMAP_SIZE + 2, 0);
  fb.drawRect(MINIMAP_X - 1, MINIMAP_Y - 1, MINIMAP_SIZE + 2, MINIMAP_SIZE + 2, 1);
  fb.fillRect(MINIMAP_X, MINIMAP_Y, MINIMAP_SIZE, MINIMAP_SIZE, base);

  for (const ob of sim.obstacles) {
    if (ob.room !== viewer.room) continue;
    const ox = MINIMAP_X + Math.floor(ob.x * scaleX);
    const oy = MINIMAP_Y + Math.floor(ob.y * scaleY);
    fb.putPixel(ox, oy, 5);
  }

  const showAll = sim.phase === Phase.Lobby || sim.phase === Phase.Reveal || sim.phase === Phase.GameOver;
  const useFog = sim.phase === Phase.Playing || sim.phase === Phase.HostageSelect;
  const camView = playerView(sim, viewerIndex);
  for (let i = 0; i < sim.players.length; i++) {
    if (i === viewerIndex) {
      const px = MINIMAP_X + Math.floor((sim.players[i].x + PLAYER_W / 2) * scaleX);
      const py = MINIMAP_Y + Math.floor((sim.players[i].y + PLAYER_H / 2) * scaleY);
      fb.putPixel(px, py, 2);
      continue;
    }
    const p = sim.players[i];
    if (!showAll && p.room !== viewer.room) continue;
    if (useFog) {
      const sx = p.x + Math.floor(PLAYER_W / 2) - camView.cameraX;
      const sy = p.y + Math.floor(PLAYER_H / 2) - camView.cameraY;
      if (sx >= 0 && sx < SCREEN_WIDTH && sy >= 0 && sy < SCREEN_HEIGHT && sim.shadowBuf[sy * SCREEN_WIDTH + sx]) continue;
    }
    const px = MINIMAP_X + Math.floor((p.x + PLAYER_W / 2) * scaleX);
    const py = MINIMAP_Y + Math.floor((p.y + PLAYER_H / 2) * scaleY);
    fb.putPixel(px, py, sim.playerColor(i));
  }
}

function renderHud(sim: Sim, fb: Framebuffer, viewerIndex: number) {
  const viewer = sim.players[viewerIndex];
  if (!viewer) return;

  fb.fillRect(0, 0, SCREEN_WIDTH, 9, 0);
  switch (sim.phase) {
    case Phase.Lobby: {
      fb.drawText(`${sim.players.length}/${sim.config.minPlayers} PLAYERS`, 2, 2, 2);
      if (sim.lobbyCountdown > 0) {
        fb.drawText(`START ${Math.ceil(sim.lobbyCountdown / TARGET_FPS)}`, 80, 2, 8);
      }
      break;
    }
    case Phase.Playing: {
      const secs = Math.max(0, Math.ceil(sim.roundTimer / TARGET_FPS));
      fb.drawText(`R${sim.currentRound + 1} ${Math.floor(secs / 60)}:${(secs % 60).toString().padStart(2, "0")}`, 2, 2, 2);
      const rn = sim.roleName(viewer.role);
      fb.drawText(rn, SCREEN_WIDTH - MINIMAP_SIZE - 4 - fb.measureText(rn), 2, sim.teamColor(viewer.team));
      break;
    }
    case Phase.HostageSelect: {
      const committed = viewer.room === Room.RoomA ? sim.committedA : sim.committedB;
      const secs = Math.max(0, Math.ceil(sim.hostageSelectTimer / TARGET_FPS));
      if (viewer.isLeader && !committed) {
        fb.drawText(`SELECT ${secs}S`, 2, 2, 8);
      } else if (committed) {
        fb.drawText("WAITING...", 2, 2, 2);
      } else {
        const ln = viewer.room === Room.RoomA ? LEADER_A_NAME : LEADER_B_NAME;
        fb.drawText(`${ln.toUpperCase()} PICKS ${secs}S`, 2, 2, 1);
      }
      break;
    }
    case Phase.HostageExchange:
      fb.drawText("EXCHANGING", 2, 2, 8);
      break;
    case Phase.Reveal: {
      const winText = sim.winner === Team.TeamA ? `${TEAM_A_NAME} WIN!` : sim.winner === Team.TeamB ? `${TEAM_B_NAME} WIN!` : "NO ONE WINS!";
      const wc = sim.winner === Team.TeamA ? TEAM_A_COLOR : sim.winner === Team.TeamB ? TEAM_B_COLOR : 1;
      fb.drawText("REVEAL!", 2, 2, 2);
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

  const barY = SCREEN_HEIGHT - BOTTOM_BAR_H;
  fb.fillRect(0, barY, SCREEN_WIDTH, BOTTOM_BAR_H, 0);

  if (viewer.commMenuOpen) {
    const items = sim.commMenuItems(viewerIndex);
    const row = Math.min(viewer.commMenuRow, items.length - 1);
    const item = items[row] ?? "";
    fb.drawText(`< ${item} >`, 2, barY + 2, 2);
  } else if (sim.phase === Phase.Playing || sim.phase === Phase.HostageSelect) {
    if (sim.phase === Phase.HostageSelect && viewer.isLeader) {
      fb.drawText("L:COMMIT  </>:PICK  J:TOG", 2, barY + 2, 1);
    } else if (viewer.pendingChatroomEntry >= 0) {
      fb.drawText("WAITING...", 2, barY + 2, 8);
      const unread = sim.globalUnreadCount(viewerIndex);
      if (unread > 0 && (sim.tickCount & 16)) {
        fb.putPixel(SCREEN_WIDTH - 4, barY + 4, 11);
      }
    } else {
      fb.drawText("J:COMM  K:INFO  L:GLOBAL", 2, barY + 2, 1);
      const unread = sim.globalUnreadCount(viewerIndex);
      if (unread > 0 && (sim.tickCount & 16)) {
        fb.putPixel(SCREEN_WIDTH - 4, barY + 4, 11);
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

  let y = 12;
  const cx = (text: string) => Math.floor((SCREEN_WIDTH - fb.measureText(text)) / 2);

  fb.drawText("YOU ARE", cx("YOU ARE"), y, 2); y += 10;
  fb.drawText(roleName, cx(roleName), y, tc); y += 10;
  fb.drawText(teamName + " TEAM", cx(teamName + " TEAM"), y, tc); y += 14;
  fb.drawText("ASSIGNED TO", cx("ASSIGNED TO"), y, 1); y += 8;
  fb.drawText(roomName, cx(roomName), y, 2); y += 16;

  fb.drawText("WASD  MOVE", 14, y, 1); y += 8;
  fb.drawText("J     COMM", 14, y, 1); y += 8;
  fb.drawText("K     INFO", 14, y, 1); y += 8;
  fb.drawText("L     GLOBAL/COMMIT", 14, y, 1); y += 8;
  fb.drawText("ENTER TYPE", 14, y, 1); y += 12;

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

  const exchText = "HOSTAGE EXCHANGE";
  fb.drawText(exchText, Math.floor((SCREEN_WIDTH - fb.measureText(exchText)) / 2), 14, 8);

  const departing = inRoomA ? sim.exchangeFromA : sim.exchangeFromB;
  const arriving = inRoomA ? sim.exchangeFromB : sim.exchangeFromA;
  const myLeader = inRoomA ? sim.exchangeLeaderA : sim.exchangeLeaderB;
  const otherLeader = inRoomA ? sim.exchangeLeaderB : sim.exchangeLeaderA;

  let y = 26;

  // Leader(s)
  if (isLeader) {
    fb.drawText("LEADERS", 8, y, 2);
    y += 7;
    renderExchangeRow(sim, fb, myLeader, 10, y);
    renderExchangeRow(sim, fb, otherLeader, 30, y);
    y += 14;
  } else {
    fb.drawText("LEADER", 8, y, 2);
    y += 7;
    renderExchangeRow(sim, fb, myLeader, 10, y);
    y += 14;
  }

  // Departing hostages
  fb.drawText("DEPARTING", 8, y, 8);
  y += 7;
  for (const h of departing) {
    renderExchangeRow(sim, fb, h.pi, 10, y);
    y += 14;
  }

  // Arriving hostages
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

  const view = playerView(sim, viewerIndex);
  const { cameraX, cameraY } = view;

  const room = viewer.room;
  for (let sy = 0; sy < SCREEN_HEIGHT; sy++) {
    for (let sx = 0; sx < SCREEN_WIDTH; sx++) {
      const mx = cameraX + sx;
      const my = cameraY + sy;
      if (mx < 0 || my < 0 || mx >= ROOM_W || my >= ROOM_H) {
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
      if (sim.shadowBuf[idx]) {
        const c = fb.indices[idx] & 0x0f;
        if (c !== base && c !== alt) {
          fb.indices[idx] = SHADOW_MAP[c];
        }
      }
    }
  }

  const showAll = sim.phase === Phase.Reveal || sim.phase === Phase.GameOver || sim.phase === Phase.Lobby;
  for (let i = 0; i < sim.players.length; i++) {
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
      fb.putPixel(sx + 2, sy - 3, 2);
      fb.putPixel(sx + 3, sy - 3, 2);
      fb.putPixel(sx + 4, sy - 3, 2);
      fb.putPixel(sx + 3, sy - 2, 2);
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

  if (sim.phase === Phase.HostageSelect && viewer.isLeader) {
    renderHostageGrid(sim, fb, viewerIndex);
  }

  renderHud(sim, fb, viewerIndex);

  if (sim.phase !== Phase.Lobby) {
    renderMinimap(sim, fb, viewerIndex);
  }

  fb.pack();
  return fb.packed;
}

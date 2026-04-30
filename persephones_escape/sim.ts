import { Phase, Team, Role, Room, PlayerShape, type InputState, type Player, type ChatMessage, type ChatroomMessage, type Chatroom, type Obstacle, type uint8, type GameConfig } from "./types.js";
import { ROOM_W, ROOM_H, PLAYER_W, PLAYER_H, SCREEN_WIDTH, SCREEN_HEIGHT, MOTION_SCALE, ACCEL, FRICTION_NUM, FRICTION_DEN, MAX_SPEED, STOP_THRESHOLD, BUBBLE_RADIUS, TARGET_FPS, LOBBY_WAIT_TICKS, CHAT_MAX_CHARS_PER_LINE, CHAT_MAX_LINES, ACTION_RATE_LIMIT_TICKS, CHATROOM_MAX_OCCUPANTS, ENTRY_REQUEST_TIMEOUT, OBSTACLE_SIZE, PLAYER_COLORS, HADES_ROLE_NAME, PERSEPHONE_ROLE_NAME, CERBERUS_ROLE_NAME, DEMETER_ROLE_NAME, SHADES_ROLE_NAME, NYMPHS_ROLE_NAME, TEAM_A_COLOR, TEAM_B_COLOR, DEFAULT_GAME_CONFIG, MINIMAP_SIZE, roomSizeForPlayers, obstaclesForPlayers, playerCountFromConfig } from "./constants.js";
import { Framebuffer } from "./framebuffer.js";
import { emptyInput } from "./protocol.js";
import { clamp, distSq } from "./util.js";
import {
  MENU_DEFS, pressed, anyPressed, navigateMenu,
  CHATROOM_MENU, CHATROOM_OPEN_BUTTON, CHATROOM_CLOSE_BUTTON, CHATROOM_SELECT_BUTTON,
  navigateChatMenu, chatMenuAction,
} from "./menu_defs.js";

function pref(pi: number): string {
  return `\x01${String.fromCharCode(pi)}`;
}

export class Sim {
  players: Player[] = [];
  chatMessages: ChatMessage[] = [];
  obstacles: Obstacle[] = [];
  roomW = ROOM_W;
  roomH = ROOM_H;
  wallMapA = new Uint8Array(ROOM_W * ROOM_H);
  wallMapB = new Uint8Array(ROOM_W * ROOM_H);
  fb = new Framebuffer();
  shadowBuf = new Uint8Array(SCREEN_WIDTH * SCREEN_HEIGHT);
  tickCount = 0;
  phase: Phase = Phase.Lobby;
  lobbyCountdown = 0;
  currentRound = 0;
  roundTimer = 0;
  hostagesPerRoom = 1;
  revealTimer = 0;
  gameOverTimer = 0;
  winner: Team | null = null;
  config: GameConfig;
  rng: () => number;

  leaderA = -1;
  leaderB = -1;
  hostagesSelectedA: number[] = [];
  hostagesSelectedB: number[] = [];
  hostageCursorA = 0;
  hostageCursorB = 0;
  committedA = false;
  committedB = false;
  hostageSelectTimer = 0;

  chatrooms = new Map<number, Chatroom>();
  nextChatroomId = 0;
  globalMessagesA: ChatroomMessage[] = [];
  globalMessagesB: ChatroomMessage[] = [];

  // Exchange animation state — positions before swap
  exchangeFromA: { pi: number; startX: number; startY: number }[] = [];
  exchangeFromB: { pi: number; startX: number; startY: number }[] = [];
  exchangeLeaderA = -1;
  exchangeLeaderB = -1;
  exchangeLeaderAStart = { x: 0, y: 0 };
  exchangeLeaderBStart = { x: 0, y: 0 };
  exchangeDuration = 0;
  exchangeTimer = 0;

  seed: number;

  constructor(config: GameConfig = DEFAULT_GAME_CONFIG, seed = 0xb1770) {
    this.config = config;
    this.seed = seed;
    let s = seed;
    this.rng = () => {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      return s / 0x7fffffff;
    };
    this.rebuildWallMap();
  }

  randInt(max: number): number {
    return Math.floor(this.rng() * max);
  }

  // ---- World geometry ----

  roomBounds(room: Room): { x: number; y: number; w: number; h: number } {
    return { x: 1, y: 1, w: this.roomW - 2, h: this.roomH - 2 };
  }

  wallMap(room: Room): Uint8Array {
    return room === Room.RoomA ? this.wallMapA : this.wallMapB;
  }

  rebuildWallMap() {
    const rw = this.roomW, rh = this.roomH;
    for (const wm of [this.wallMapA, this.wallMapB]) {
      wm.fill(0);
      for (let y = 0; y < rh; y++) {
        for (let x = 0; x < rw; x++) {
          if (x === 0 || y === 0 || x === rw - 1 || y === rh - 1) {
            wm[y * rw + x] = 1;
          }
        }
      }
    }
    for (const ob of this.obstacles) {
      const wm = this.wallMap(ob.room);
      for (let dy = 0; dy < ob.h; dy++) {
        for (let dx = 0; dx < ob.w; dx++) {
          const wx = ob.x + dx, wy = ob.y + dy;
          if (wx >= 0 && wx < rw && wy >= 0 && wy < rh) {
            wm[wy * rw + wx] = 1;
          }
        }
      }
    }
  }

  isWallInRoom(room: Room, mx: number, my: number): boolean {
    if (mx < 0 || my < 0 || mx >= this.roomW || my >= this.roomH) return true;
    return this.wallMap(room)[my * this.roomW + mx] === 1;
  }

  floorColor(room: Room): uint8 {
    return room === Room.RoomA ? 12 : 9;
  }

  floorColorAt(room: Room, mx: number, my: number): uint8 {
    const base = room === Room.RoomA ? 12 : 9;
    const alt = room === Room.RoomA ? 6 : 10;
    // 2x2 dots on a fixed 24-pixel grid across the entire room.
    // Sparse enough to look clean, dense enough that one dot is
    // always visible in the 128x128 viewport for positioning.
    const lx = mx % 24;
    const ly = my % 24;
    if (lx >= 11 && lx <= 12 && ly >= 11 && ly <= 12) return alt;
    return base;
  }

  canOccupy(x: number, y: number, room: Room): boolean {
    const wm = this.wallMap(room);
    for (let dy = 0; dy < PLAYER_H; dy++) {
      for (let dx = 0; dx < PLAYER_W; dx++) {
        const wx = x + dx, wy = y + dy;
        if (wx < 0 || wy < 0 || wx >= this.roomW || wy >= this.roomH) return false;
        if (wm[wy * this.roomW + wx]) return false;
      }
    }
    return true;
  }

  obstacleOverlap(x: number, y: number, room: Room): number {
    let total = 0;
    const pr = x + PLAYER_W, pb = y + PLAYER_H;
    for (const ob of this.obstacles) {
      if (ob.room !== room) continue;
      const ox = Math.max(x, ob.x), oy = Math.max(y, ob.y);
      const ox2 = Math.min(pr, ob.x + ob.w), oy2 = Math.min(pb, ob.y + ob.h);
      if (ox < ox2 && oy < oy2) total += (ox2 - ox) * (oy2 - oy);
    }
    return total;
  }

  playerOverlap(pi: number, x: number, y: number, room: Room): number {
    let total = 0;
    const pr = x + PLAYER_W, pb = y + PLAYER_H;
    for (let i = 0; i < this.players.length; i++) {
      if (i === pi) continue;
      const o = this.players[i];
      if (o.room !== room) continue;
      const ox = Math.max(x, o.x), oy = Math.max(y, o.y);
      const ox2 = Math.min(pr, o.x + PLAYER_W), oy2 = Math.min(pb, o.y + PLAYER_H);
      if (ox < ox2 && oy < oy2) total += (ox2 - ox) * (oy2 - oy);
    }
    return total;
  }

  playersInBubble(pi: number): number[] {
    const player = this.players[pi];
    const r2 = BUBBLE_RADIUS * BUBBLE_RADIUS;
    const result: number[] = [];
    for (let i = 0; i < this.players.length; i++) {
      if (i === pi) continue;
      const other = this.players[i];
      if (other.room !== player.room) continue;
      if (distSq(player.x, player.y, other.x, other.y) <= r2) {
        result.push(i);
      }
    }
    return result;
  }

  // ---- Fog of war ----

  castShadows(room: Room, originMx: number, originMy: number, cameraX: number, cameraY: number) {
    const sb = this.shadowBuf;
    const wm = this.wallMap(room);
    sb.fill(0);
    for (let sy = 0; sy < SCREEN_HEIGHT; sy += 2) {
      for (let sx = 0; sx < SCREEN_WIDTH; sx += 2) {
        const mx = cameraX + sx;
        const my = cameraY + sy;
        const dx = mx - originMx;
        const dy = my - originMy;
        const steps = Math.max(Math.abs(dx), Math.abs(dy));
        let shadowed = false;
        if (steps > 0) {
          for (let s = 1; s < steps; s++) {
            const rx = originMx + ((dx * s / steps) | 0);
            const ry = originMy + ((dy * s / steps) | 0);
            if (rx < 0 || ry < 0 || rx >= this.roomW || ry >= this.roomH) { shadowed = true; break; }
            if (wm[ry * this.roomW + rx]) { shadowed = true; break; }
          }
        }
        if (shadowed) {
          const idx = sy * SCREEN_WIDTH + sx;
          sb[idx] = 1;
          if (sx + 1 < SCREEN_WIDTH) sb[idx + 1] = 1;
          if (sy + 1 < SCREEN_HEIGHT) {
            sb[idx + SCREEN_WIDTH] = 1;
            if (sx + 1 < SCREEN_WIDTH) sb[idx + SCREEN_WIDTH + 1] = 1;
          }
        }
      }
    }
  }

  hasLineOfSight(room: Room, x1: number, y1: number, x2: number, y2: number): boolean {
    const wm = this.wallMap(room);
    const dx = x2 - x1;
    const dy = y2 - y1;
    const steps = Math.max(Math.abs(dx), Math.abs(dy));
    if (steps === 0) return true;
    for (let s = 1; s < steps; s++) {
      const rx = x1 + ((dx * s / steps) | 0);
      const ry = y1 + ((dy * s / steps) | 0);
      if (rx < 0 || ry < 0 || rx >= this.roomW || ry >= this.roomH) return false;
      if (wm[ry * this.roomW + rx]) return false;
    }
    return true;
  }

  playersInSight(pi: number): number[] {
    const player = this.players[pi];
    const cx1 = player.x + Math.floor(PLAYER_W / 2);
    const cy1 = player.y + Math.floor(PLAYER_H / 2);
    const result: number[] = [];
    for (let i = 0; i < this.players.length; i++) {
      if (i === pi) continue;
      const other = this.players[i];
      if (other.room !== player.room) continue;
      const cx2 = other.x + Math.floor(PLAYER_W / 2);
      const cy2 = other.y + Math.floor(PLAYER_H / 2);
      if (this.hasLineOfSight(player.room, cx1, cy1, cx2, cy2)) {
        result.push(i);
      }
    }
    return result;
  }

  // ---- Physics ----

  applyMomentumAxis(pi: number, player: Player, carry: { val: number }, velocity: number, horizontal: boolean) {
    carry.val += velocity;
    while (Math.abs(carry.val) >= MOTION_SCALE) {
      const step = carry.val < 0 ? -1 : 1;
      const nx = horizontal ? player.x + step : player.x;
      const ny = horizontal ? player.y : player.y + step;
      if (this.canMove(pi, player, nx, ny)) {
        if (horizontal) player.x = nx; else player.y = ny;
        carry.val -= step * MOTION_SCALE;
      } else {
        let slid = false;
        if (horizontal) {
          for (const slideY of [player.y - 1, player.y + 1]) {
            if (this.canMove(pi, player, nx, slideY)) {
              player.x = nx; player.y = slideY;
              carry.val -= step * MOTION_SCALE; slid = true; break;
            }
          }
        } else {
          for (const slideX of [player.x - 1, player.x + 1]) {
            if (this.canMove(pi, player, slideX, ny)) {
              player.x = slideX; player.y = ny;
              carry.val -= step * MOTION_SCALE; slid = true; break;
            }
          }
        }
        if (!slid) { carry.val = 0; break; }
      }
    }
  }

  canMove(pi: number, player: Player, nx: number, ny: number): boolean {
    const room = player.room;
    if (nx < 0 || ny < 0 || nx + PLAYER_W > this.roomW || ny + PLAYER_H > this.roomH) return false;
    const curObstacle = this.obstacleOverlap(player.x, player.y, room);
    const newObstacle = this.obstacleOverlap(nx, ny, room);
    if (newObstacle > curObstacle) return false;
    const curPlayer = this.playerOverlap(pi, player.x, player.y, room);
    const newPlayer = this.playerOverlap(pi, nx, ny, room);
    if (newPlayer > curPlayer) return false;
    if (newObstacle > 0 || newPlayer > 0) return true;
    return this.canOccupy(nx, ny, room);
  }

  applyInput(pi: number, input: InputState, prevInput: InputState) {
    const player = this.players[pi];
    if (!player) return;

    if (player.infoScreen !== "none") {
      if (pressed(input, prevInput, MENU_DEFS.info.selectButton)) player.infoScrollOffset = Math.max(0, player.infoScrollOffset - 1);
      if (input.up && !prevInput.up) player.infoScrollOffset = Math.max(0, player.infoScrollOffset - 1);
      if (input.down && !prevInput.down) player.infoScrollOffset++;
      if (anyPressed(input, prevInput, MENU_DEFS.info.closeButton!,
        MENU_DEFS.comm.openButton!, MENU_DEFS.chatroom.closeButton!)) {
        player.infoScreen = "none"; player.infoScrollOffset = 0;
      }
      return;
    }

    if (player.inChatroom >= 0) {
      this.applyChatroomInput(pi, input, prevInput);
      return;
    }

    if (player.globalChatOpen) {
      this.applyGlobalChatInput(pi, input, prevInput);
      return;
    }

    if (player.commMenuOpen) {
      const def = MENU_DEFS.comm;
      if (def.closeButton && pressed(input, prevInput, def.closeButton)) { player.commMenuOpen = false; return; }
      const items = this.commMenuItems(pi);
      if (items.length > 0) {
        player.commMenuRow = navigateMenu(input, prevInput, def, items.length, player.commMenuRow);
      }
      if (pressed(input, prevInput, def.selectButton) && items.length > 0) {
        this.commMenuSelect(pi, items[player.commMenuRow]);
      }
      return;
    }

    {
      let inputX = 0;
      let inputY = 0;
      if (input.left) inputX -= 1;
      if (input.right) inputX += 1;
      if (input.up) inputY -= 1;
      if (input.down) inputY += 1;

      if (inputX !== 0) {
        player.velX = clamp(player.velX + inputX * ACCEL, -MAX_SPEED, MAX_SPEED);
      } else {
        player.velX = Math.trunc((player.velX * FRICTION_NUM) / FRICTION_DEN);
        if (Math.abs(player.velX) < STOP_THRESHOLD) player.velX = 0;
      }
      if (inputY !== 0) {
        player.velY = clamp(player.velY + inputY * ACCEL, -MAX_SPEED, MAX_SPEED);
      } else {
        player.velY = Math.trunc((player.velY * FRICTION_NUM) / FRICTION_DEN);
        if (Math.abs(player.velY) < STOP_THRESHOLD) player.velY = 0;
      }

      const carryX = { val: player.carryX };
      const carryY = { val: player.carryY };
      this.applyMomentumAxis(pi, player, carryX, player.velX, true);
      this.applyMomentumAxis(pi, player, carryY, player.velY, false);
      player.carryX = carryX.val;
      player.carryY = carryY.val;
    }

    // A creates/requests chatroom entry
    if (pressed(input, prevInput, MENU_DEFS.chatroom.selectButton)) {
      if (this.phase === Phase.Playing || this.phase === Phase.HostageSelect) {
        const nearby = this.findNearbyChatroomPlayer(pi);
        if (nearby >= 0 && player.pendingChatroomEntry < 0) {
          const cr = this.chatrooms.get(this.players[nearby].inChatroom);
          if (cr) this.requestChatroomEntry(pi, cr.id);
        } else if (player.pendingChatroomEntry < 0) {
          this.createChatroom(pi);
        }
      }
    }

    // B toggles shared info screen / cancels entry
    if (pressed(input, prevInput, MENU_DEFS.info.openButton!)) {
      if (player.pendingChatroomEntry >= 0) {
        this.cancelEntryRequest(pi);
      } else {
        player.infoScreen = player.infoScreen === "none" ? "shared" : "none";
      }
    }

    // SELECT opens comm menu
    if (pressed(input, prevInput, MENU_DEFS.comm.openButton!)) {
      if (this.phase === Phase.Playing || this.phase === Phase.HostageSelect) {
        player.commMenuOpen = true;
        player.commMenuRow = 0;
      }
    }

    if (this.phase === Phase.RoleReveal) {
      // any button = ready
    }
  }

  applyChatroomInput(pi: number, input: InputState, prevInput: InputState) {
    const player = this.players[pi];
    const cr = this.chatrooms.get(player.inChatroom);
    if (!cr) { player.inChatroom = -1; return; }

    const shareDef = MENU_DEFS.share;

    if (player.shareSelectOpen) {
      const offerers = player.shareSelectMode === "color"
        ? this.chatroomColorOfferers(pi)
        : this.chatroomShareOfferers(pi);
      if (offerers.length === 0) { player.shareSelectOpen = false; return; }
      player.shareSelectRow = navigateMenu(input, prevInput, shareDef, offerers.length, player.shareSelectRow);
      if (pressed(input, prevInput, shareDef.selectButton)) {
        const target = offerers[player.shareSelectRow];
        if (player.shareSelectMode === "color") {
          player.colorRevealedTo.add(target);
          this.players[target].colorRevealedTo.add(pi);
          cr.colorOffers.delete(target);
          cr.colorOffers.delete(pi);
          cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} swapped colors ${pref(target)}` });
        } else {
          player.revealedTo.add(target);
          this.players[target].revealedTo.add(pi);
          player.sharedWith.add(target);
          this.players[target].sharedWith.add(pi);
          cr.revealOffers.delete(target);
          cr.revealOffers.delete(pi);
          cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} shared roles ${pref(target)}` });
        }
        player.shareSelectOpen = false;
      }
      if (shareDef.closeButton && pressed(input, prevInput, shareDef.closeButton)) {
        player.shareSelectOpen = false;
      }
      player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
      return;
    }

    if (player.chatMenuOpen) {
      const nav = navigateChatMenu(input, prevInput, player.chatMenuCat, player.chatMenuItem);
      player.chatMenuCat = nav.catIdx;
      player.chatMenuItem = nav.itemIdx;

      if (pressed(input, prevInput, CHATROOM_SELECT_BUTTON)) {
        const toggledSet = this.chatroomToggledActions(pi);
        const action = chatMenuAction(player.chatMenuCat, player.chatMenuItem, toggledSet);
        if (action && this.chatroomActionEnabled(pi, action)) {
          this.chatroomActionSelect(pi, action);
          player.chatMenuOpen = false;
        }
      }
      if (pressed(input, prevInput, CHATROOM_CLOSE_BUTTON)) {
        player.chatMenuOpen = false;
      }
      player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
      return;
    }

    if (pressed(input, prevInput, CHATROOM_CLOSE_BUTTON)) {
      this.leaveChatroom(pi);
      return;
    }

    if (pressed(input, prevInput, CHATROOM_OPEN_BUTTON)) {
      player.chatMenuOpen = true;
      player.chatMenuCat = 0;
      player.chatMenuItem = 0;
      return;
    }

    if (input.up && !prevInput.up) {
      player.chatScrollOffset = Math.min(player.chatScrollOffset + 1, Math.max(0, cr.messages.length - 1));
    }
    if (input.down && !prevInput.down) {
      player.chatScrollOffset = Math.max(player.chatScrollOffset - 1, 0);
    }

    player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
  }

  applyGlobalChatInput(pi: number, input: InputState, prevInput: InputState) {
    const player = this.players[pi];
    const msgs = this.globalMessagesForPlayer(pi);
    const gDef = MENU_DEFS.global;
    const hDef = MENU_DEFS.hostage;

    if (gDef.closeButton && pressed(input, prevInput, gDef.closeButton)) {
      player.globalChatLastRead = (player.room === Room.RoomA ? this.globalMessagesA : this.globalMessagesB).length;
      player.globalChatOpen = false;
      player.globalChatScroll = 0;
      return;
    }

    const leaderHostage = this.phase === Phase.HostageSelect && player.isLeader;

    if (leaderHostage) {
      const committed = player.room === Room.RoomA ? this.committedA : this.committedB;
      if (!committed) {
        const eligible = this.eligibleHostages(player.room);
        const cursor = player.room === Room.RoomA ? this.hostageCursorA : this.hostageCursorB;
        const newCursor = navigateMenu(input, prevInput, hDef, eligible.length, cursor);
        if (player.room === Room.RoomA) this.hostageCursorA = newCursor;
        else this.hostageCursorB = newCursor;
        if (pressed(input, prevInput, hDef.selectButton)) this.handleHostageToggle(pi);
        if (pressed(input, prevInput, MENU_DEFS.chatroom.openButton!)) {
          if (player.room === Room.RoomA) this.committedA = true;
          else this.committedB = true;
        }
      }
    } else {
      if (pressed(input, prevInput, gDef.selectButton)) {
        const candidates = this.usurpCandidates(pi);
        if (candidates.length > 0) {
          const row = Math.min(player.globalChatActionRow, candidates.length - 1);
          const item = candidates[row];
          const prevVote = player.usurpVote;
          if (item === "NONE") player.usurpVote = -1;
          else if (item === "ME") player.usurpVote = pi;
          else {
            const match = item.match(/^P(\d+)$/);
            if (match) player.usurpVote = parseInt(match[1]);
          }
          if (player.usurpVote !== prevVote && player.usurpVote >= 0) {
            const globalMsgs = player.room === Room.RoomA ? this.globalMessagesA : this.globalMessagesB;
            globalMsgs.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} voted for ${pref(player.usurpVote)}` });
          }
          this.checkUsurp(player.room);
        }
      }

      const candidates = this.usurpCandidates(pi);
      if (candidates.length > 0) {
        player.globalChatActionRow = navigateMenu(input, prevInput, gDef, candidates.length, player.globalChatActionRow);
      }
    }

    if (input.up && !prevInput.up) {
      player.globalChatScroll = Math.min(player.globalChatScroll + 1, Math.max(0, msgs.length - 1));
    }
    if (input.down && !prevInput.down) {
      player.globalChatScroll = Math.max(player.globalChatScroll - 1, 0);
    }

    player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
  }

  // ---- Comm menu (A-button in game world) ----

  commMenuItems(pi: number): string[] {
    const items: string[] = [];
    if (this.phase === Phase.Playing || this.phase === Phase.HostageSelect) {
      items.push("SHOUT");
      items.push("INFO");
    }
    return items;
  }

  commMenuSelect(pi: number, item: string) {
    const player = this.players[pi];
    player.commMenuOpen = false;
    switch (item) {
      case "SHOUT":
        player.globalChatOpen = true;
        player.globalChatScroll = 0;
        player.globalChatActionRow = 0;
        break;
      case "INFO":
        player.infoScreen = "shared";
        player.infoScrollOffset = 0;
        break;
    }
  }

  // ---- Chatroom action items (B-button in chatroom) ----

  chatroomShareOfferers(pi: number): number[] {
    const player = this.players[pi];
    const cr = this.chatrooms.get(player.inChatroom);
    if (!cr) return [];
    const offerers: number[] = [];
    for (const oi of cr.revealOffers) {
      if (oi !== pi && cr.occupants.has(oi)) offerers.push(oi);
    }
    return offerers;
  }

  chatroomColorOfferers(pi: number): number[] {
    const player = this.players[pi];
    const cr = this.chatrooms.get(player.inChatroom);
    if (!cr) return [];
    const offerers: number[] = [];
    for (const oi of cr.colorOffers) {
      if (oi !== pi && cr.occupants.has(oi)) offerers.push(oi);
    }
    return offerers;
  }

  usurpCandidates(pi: number): string[] {
    const player = this.players[pi];
    if (player.isLeader) return [];
    if (this.phase !== Phase.Playing && this.phase !== Phase.HostageSelect) return [];
    const items: string[] = ["NONE"];
    for (let i = 0; i < this.players.length; i++) {
      if (i !== pi && this.players[i].room === player.room && !this.players[i].isLeader) {
        items.push(`P${i}`);
      }
    }
    items.push("ME");
    return items;
  }

  checkUsurp(room: Room) {
    const roomPlayers: number[] = [];
    for (let i = 0; i < this.players.length; i++) {
      if (this.players[i].room === room) roomPlayers.push(i);
    }
    if (roomPlayers.length < 2) return;
    const votes = new Map<number, number>();
    for (const i of roomPlayers) {
      const v = this.players[i].usurpVote;
      if (v >= 0 && v < this.players.length && this.players[v].room === room) {
        votes.set(v, (votes.get(v) ?? 0) + 1);
      }
    }
    const majority = Math.floor(roomPlayers.length / 2) + 1;
    for (const [candidate, count] of votes) {
      if (count >= majority) {
        this.setLeader(room, candidate);
        for (const i of roomPlayers) this.players[i].usurpVote = -1;
        return;
      }
    }
  }

  usurpVotes(room: Room): { candidate: number; votes: number }[] {
    const roomPlayers: number[] = [];
    for (let i = 0; i < this.players.length; i++) {
      if (this.players[i].room === room) roomPlayers.push(i);
    }
    const tally = new Map<number, number>();
    for (const i of roomPlayers) {
      const v = this.players[i].usurpVote;
      if (v >= 0 && v < this.players.length && this.players[v].room === room) {
        tally.set(v, (tally.get(v) ?? 0) + 1);
      }
    }
    const result: { candidate: number; votes: number }[] = [];
    for (const [candidate, votes] of tally) result.push({ candidate, votes });
    result.sort((a, b) => b.votes - a.votes);
    return result;
  }

  // ---- Actions ----

  handleHostageToggle(pi: number) {
    const player = this.players[pi];
    const committed = player.room === Room.RoomA ? this.committedA : this.committedB;
    if (committed) return;
    const eligible = this.eligibleHostages(player.room);
    if (eligible.length === 0) return;
    const cursor = player.room === Room.RoomA ? this.hostageCursorA : this.hostageCursorB;
    const targetIdx = eligible[cursor % eligible.length];
    if (targetIdx === undefined) return;

    const list = player.room === Room.RoomA ? this.hostagesSelectedA : this.hostagesSelectedB;
    const already = list.indexOf(targetIdx);
    if (already >= 0) {
      list.splice(already, 1);
      this.players[targetIdx].selectedAsHostage = false;
    } else if (list.length < this.hostagesPerRoom) {
      list.push(targetIdx);
      this.players[targetIdx].selectedAsHostage = true;
    }
  }

  moveCursor(pi: number, delta: number) {
    const player = this.players[pi];
    if (this.phase !== Phase.HostageSelect || !player.isLeader) return;
    const committed = player.room === Room.RoomA ? this.committedA : this.committedB;
    if (committed) return;
    const eligible = this.eligibleHostages(player.room);
    if (eligible.length === 0) return;
    if (player.room === Room.RoomA) {
      this.hostageCursorA = (this.hostageCursorA + delta + eligible.length) % eligible.length;
    } else {
      this.hostageCursorB = (this.hostageCursorB + delta + eligible.length) % eligible.length;
    }
  }

  eligibleHostages(room: Room): number[] {
    const result: number[] = [];
    for (let i = 0; i < this.players.length; i++) {
      const p = this.players[i];
      if (p.room === room && !p.isLeader) result.push(i);
    }
    return result;
  }

  // ---- Chatrooms ----

  createChatroom(pi: number) {
    const player = this.players[pi];
    if (player.inChatroom >= 0) return;
    const id = this.nextChatroomId++;
    const cr: Chatroom = {
      id, room: player.room, ownerIndex: pi,
      x: player.x, y: player.y,
      occupants: new Set([pi]),
      pendingEntry: [], pendingEntryTicks: [],
      messages: [], revealOffers: new Set(), colorOffers: new Set(), leaderOffer: -1,
    };
    this.chatrooms.set(id, cr);
    player.inChatroom = id;
    player.chatroomEntryTick = this.tickCount;
    player.chatScrollOffset = 0;
    player.chatMenuOpen = false; player.chatMenuCat = 0; player.chatMenuItem = 0;
    player.shareSelectOpen = false; player.shareSelectRow = 0;
    player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
  }

  findNearbyChatroomPlayer(pi: number): number {
    const player = this.players[pi];
    const r2 = BUBBLE_RADIUS * BUBBLE_RADIUS;
    for (let i = 0; i < this.players.length; i++) {
      if (i === pi) continue;
      const other = this.players[i];
      if (other.room !== player.room || other.inChatroom < 0) continue;
      if (distSq(player.x, player.y, other.x, other.y) <= r2) return i;
    }
    return -1;
  }

  requestChatroomEntry(pi: number, chatroomId: number) {
    const cr = this.chatrooms.get(chatroomId);
    if (!cr) return;
    if (cr.occupants.has(pi)) return;
    if (cr.pendingEntry.includes(pi)) return;
    if (cr.occupants.size >= CHATROOM_MAX_OCCUPANTS) return;
    cr.pendingEntry.push(pi);
    cr.pendingEntryTicks.push(this.tickCount);
    this.players[pi].pendingChatroomEntry = chatroomId;
    cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} requests entry` });
  }

  grantChatroomEntry(chatroomId: number, requestingPi: number) {
    const cr = this.chatrooms.get(chatroomId);
    if (!cr) return;
    const idx = cr.pendingEntry.indexOf(requestingPi);
    if (idx < 0) return;
    if (cr.occupants.size >= CHATROOM_MAX_OCCUPANTS) return;
    cr.pendingEntry.splice(idx, 1);
    cr.pendingEntryTicks.splice(idx, 1);
    cr.occupants.add(requestingPi);
    const p = this.players[requestingPi];
    p.inChatroom = chatroomId;
    p.chatroomEntryTick = this.tickCount;
    p.pendingChatroomEntry = -1;
    p.chatScrollOffset = 0;
    p.chatMenuOpen = false; p.chatMenuCat = 0; p.chatMenuItem = 0;
    p.shareSelectOpen = false; p.shareSelectRow = 0;
    p.velX = 0; p.velY = 0; p.carryX = 0; p.carryY = 0;
  }

  denyChatroomEntry(chatroomId: number, requestingPi: number) {
    const cr = this.chatrooms.get(chatroomId);
    if (!cr) return;
    const idx = cr.pendingEntry.indexOf(requestingPi);
    if (idx < 0) return;
    cr.pendingEntry.splice(idx, 1);
    cr.pendingEntryTicks.splice(idx, 1);
    this.players[requestingPi].pendingChatroomEntry = -1;
  }

  cancelEntryRequest(pi: number) {
    const player = this.players[pi];
    if (player.pendingChatroomEntry < 0) return;
    const cr = this.chatrooms.get(player.pendingChatroomEntry);
    if (cr) {
      const idx = cr.pendingEntry.indexOf(pi);
      if (idx >= 0) { cr.pendingEntry.splice(idx, 1); cr.pendingEntryTicks.splice(idx, 1); }
    }
    player.pendingChatroomEntry = -1;
  }

  leaveChatroom(pi: number) {
    const player = this.players[pi];
    const cr = this.chatrooms.get(player.inChatroom);
    player.inChatroom = -1;
    player.chatScrollOffset = 0;
    player.chatMenuOpen = false;
    player.shareSelectOpen = false;
    if (!cr) return;
    cr.occupants.delete(pi);
    cr.revealOffers.delete(pi);
    cr.colorOffers.delete(pi);
    if (cr.leaderOffer === pi) cr.leaderOffer = -1;
    cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} left` });
    if (cr.occupants.size === 0) {
      for (const pendingPi of cr.pendingEntry) {
        this.players[pendingPi].pendingChatroomEntry = -1;
      }
      this.chatrooms.delete(cr.id);
    }
  }

  ejectAllChatrooms() {
    for (const cr of this.chatrooms.values()) {
      for (const oi of cr.occupants) {
        this.players[oi].inChatroom = -1;
        this.players[oi].chatScrollOffset = 0;
      }
      for (const pi of cr.pendingEntry) {
        this.players[pi].pendingChatroomEntry = -1;
      }
    }
    this.chatrooms.clear();
  }

  tickChatrooms() {
    for (const cr of this.chatrooms.values()) {
      for (let i = cr.pendingEntry.length - 1; i >= 0; i--) {
        if (this.tickCount - cr.pendingEntryTicks[i] > ENTRY_REQUEST_TIMEOUT) {
          this.players[cr.pendingEntry[i]].pendingChatroomEntry = -1;
          cr.pendingEntry.splice(i, 1);
          cr.pendingEntryTicks.splice(i, 1);
        }
      }
    }
  }

  chatroomToggledActions(pi: number): Set<string> {
    const toggled = new Set<string>();
    const cr = this.chatrooms.get(this.players[pi].inChatroom);
    if (!cr) return toggled;
    if (cr.colorOffers.has(pi)) toggled.add("C.OFFER");
    if (cr.revealOffers.has(pi)) toggled.add("R.OFFER");
    return toggled;
  }

  chatroomActionEnabled(pi: number, action: string): boolean {
    const player = this.players[pi];
    const cr = this.chatrooms.get(player.inChatroom);
    if (!cr) return false;
    switch (action) {
      case "C.OFFER": return !cr.colorOffers.has(pi);
      case "C.UNOFFR": return cr.colorOffers.has(pi);
      case "C.ACCPT": return this.chatroomColorOfferers(pi).length > 0;
      case "ROLE": return true;
      case "R.OFFER": return !cr.revealOffers.has(pi);
      case "R.UNOFFR": return cr.revealOffers.has(pi);
      case "R.ACCPT": return this.chatroomShareOfferers(pi).length > 0;
      case "PASS": return player.isLeader;
      case "TAKE": return cr.leaderOffer >= 0 && cr.leaderOffer !== pi && cr.occupants.has(cr.leaderOffer);
      case "GRANT": return cr.pendingEntry.length > 0;
      case "EXIT": return true;
      default: return false;
    }
  }

  chatroomActionSelect(pi: number, action: string) {
    const player = this.players[pi];
    const cr = this.chatrooms.get(player.inChatroom);
    if (!cr) return;
    if (!this.actionRateCheck(pi, action)) return;

    switch (action) {
      case "C.OFFER":
        cr.colorOffers.add(pi);
        cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} offered color` });
        break;
      case "C.UNOFFR":
        cr.colorOffers.delete(pi);
        cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} withdrew color` });
        break;
      case "C.ACCPT":
        player.shareSelectOpen = true;
        player.shareSelectRow = 0;
        player.shareSelectMode = "color";
        break;
      case "ROLE":
        for (const oi of cr.occupants) {
          if (oi !== pi) player.revealedTo.add(oi);
        }
        cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} showed role` });
        break;
      case "R.OFFER":
        cr.revealOffers.add(pi);
        cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} offered role` });
        break;
      case "R.UNOFFR":
        cr.revealOffers.delete(pi);
        cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} withdrew role` });
        break;
      case "R.ACCPT":
        player.shareSelectOpen = true;
        player.shareSelectRow = 0;
        player.shareSelectMode = "card";
        break;
      case "PASS":
        if (player.isLeader) {
          cr.leaderOffer = pi;
          cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} offered lead` });
        }
        break;
      case "TAKE":
        if (cr.leaderOffer >= 0 && cr.leaderOffer !== pi) {
          const leader = this.players[cr.leaderOffer];
          if (leader && leader.isLeader) {
            const prevLeader = cr.leaderOffer;
            leader.isLeader = false;
            this.setLeader(player.room, pi);
            cr.leaderOffer = -1;
            cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} took lead from ${pref(prevLeader)}` });
          }
        }
        break;
      case "GRANT":
        if (cr.pendingEntry.length > 0) {
          const entrant = cr.pendingEntry[0];
          this.grantChatroomEntry(cr.id, entrant);
          cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} granted ${pref(entrant)}` });
        }
        break;
      case "EXIT":
        this.leaveChatroom(pi);
        break;
    }
  }

  private actionRateCheck(pi: number, action: string): boolean {
    if (pi < 0 || pi >= this.players.length) return false;
    const player = this.players[pi];
    const limits = this.config.actionRateLimits;
    const limit = limits?.[action] ?? limits?.["_default"] ?? ACTION_RATE_LIMIT_TICKS;
    const last = player.lastActionTicks.get(action) ?? -Infinity;
    if (this.tickCount - last < limit) return false;
    player.lastActionTicks.set(action, this.tickCount);
    return true;
  }

  private chatRateCheck(pi: number, text: string): string[] | null {
    if (!this.actionRateCheck(pi, "chat")) return null;
    const perLine = this.config.chatMaxCharsPerLine ?? CHAT_MAX_CHARS_PER_LINE;
    const clean = text.replace(/[^\x20-\x7e]/g, "");
    if (clean.length === 0) return null;
    const lines: string[] = [];
    for (let i = 0; i < clean.length && lines.length < CHAT_MAX_LINES; i += perLine) {
      lines.push(clean.slice(i, i + perLine));
    }
    return lines;
  }

  addChatroomChat(chatroomId: number, pi: number, text: string) {
    const cr = this.chatrooms.get(chatroomId);
    if (!cr || !cr.occupants.has(pi)) return;
    const lines = this.chatRateCheck(pi, text);
    if (!lines) return;
    for (const line of lines) {
      cr.messages.push({ type: 'text', senderIndex: pi, tick: this.tickCount, text: line });
    }
  }

  addGlobalChat(pi: number, text: string) {
    const lines = this.chatRateCheck(pi, text);
    if (!lines) return;
    const player = this.players[pi];
    const dest = player.room === Room.RoomA ? this.globalMessagesA : this.globalMessagesB;
    for (const line of lines) {
      dest.push({ type: 'text', senderIndex: pi, tick: this.tickCount, text: line });
    }
  }

  globalMessagesForPlayer(pi: number): ChatroomMessage[] {
    const player = this.players[pi];
    const msgs = player.room === Room.RoomA ? this.globalMessagesA : this.globalMessagesB;
    return msgs.filter((m) => m.tick >= player.roomEntryTick);
  }

  chatroomMessagesForPlayer(pi: number): ChatroomMessage[] {
    const player = this.players[pi];
    const cr = this.chatrooms.get(player.inChatroom);
    if (!cr) return [];
    return cr.messages.filter((m) => m.tick >= player.chatroomEntryTick);
  }

  globalUnreadCount(pi: number): number {
    const player = this.players[pi];
    const msgs = player.room === Room.RoomA ? this.globalMessagesA : this.globalMessagesB;
    let count = 0;
    for (let i = player.globalChatLastRead; i < msgs.length; i++) {
      if (msgs[i].tick >= player.roomEntryTick) count++;
    }
    return count;
  }

  addChat(pi: number, text: string) {
    const lines = this.chatRateCheck(pi, text);
    if (!lines) return;
    const player = this.players[pi];
    for (const line of lines) {
      this.chatMessages.push({
        playerIndex: pi, color: this.playerColor(pi),
        text: line, room: player.room, tick: this.tickCount,
      });
    }
    while (this.chatMessages.length > 64) this.chatMessages.shift();
  }

  setLeader(room: Room, pi: number) {
    const player = this.players[pi];
    if (room === Room.RoomA) {
      if (this.leaderA >= 0 && this.leaderA < this.players.length) this.players[this.leaderA].isLeader = false;
      this.leaderA = pi;
    } else {
      if (this.leaderB >= 0 && this.leaderB < this.players.length) this.players[this.leaderB].isLeader = false;
      this.leaderB = pi;
    }
    player.isLeader = true;
  }

  // ---- Game setup ----

  addPlayer(name: string): number {
    if (this.players.length >= playerCountFromConfig(this.config)) return -1;
    const room = this.players.length % 2 === 0 ? Room.RoomA : Room.RoomB;
    const b = this.roomBounds(room);
    const x = b.x + 10 + this.randInt(Math.max(1, b.w - 20 - PLAYER_W));
    const y = b.y + 10 + this.randInt(Math.max(1, b.h - 20 - PLAYER_H));
    const shapeCount = Object.keys(PlayerShape).length / 2;

    this.players.push({
      name, x, y, velX: 0, velY: 0, carryX: 0, carryY: 0,
      room, team: Team.TeamA, role: Role.Shades,
      shape: (this.players.length % shapeCount) as PlayerShape,
      isLeader: false, isHostage: false, selectedAsHostage: false,
      revealedTo: new Set(), sharedWith: new Set(), colorRevealedTo: new Set(),
      colorIndex: this.players.length,
      commMenuOpen: false, commMenuRow: 0,
      chatMenuOpen: false, chatMenuCat: 0, chatMenuItem: 0,
      shareSelectOpen: false, shareSelectRow: 0, shareSelectMode: "card" as const,
      infoScreen: "none", infoScrollOffset: 0, usurpVote: -1,
      inChatroom: -1, chatroomEntryTick: 0, chatScrollOffset: 0,
      pendingChatroomEntry: -1,
      globalChatOpen: false, globalChatLastRead: 0, globalChatScroll: 0, globalChatActionRow: 0,
      roomEntryTick: 0,
      lastActionTicks: new Map<string, number>(),
    });
    return this.players.length - 1;
  }

  removePlayer(index: number) {
    if (index < 0 || index >= this.players.length) return;
    this.players.splice(index, 1);
    if (this.leaderA === index) this.leaderA = -1;
    else if (this.leaderA > index) this.leaderA--;
    if (this.leaderB === index) this.leaderB = -1;
    else if (this.leaderB > index) this.leaderB--;
    this.hostagesSelectedA = this.hostagesSelectedA.filter((i) => i !== index).map((i) => (i > index ? i - 1 : i));
    this.hostagesSelectedB = this.hostagesSelectedB.filter((i) => i !== index).map((i) => (i > index ? i - 1 : i));
  }

  assignRoles() {
    const cfg = this.config;

    // Separate LLM and non-LLM players, shuffle each group
    const llmPIs = this.players.map((p, i) => p.name.startsWith("llm_") ? i : -1).filter(i => i >= 0);
    const otherPIs = this.players.map((p, i) => p.name.startsWith("llm_") ? -1 : i).filter(i => i >= 0);
    for (let i = llmPIs.length - 1; i > 0; i--) {
      const j = this.randInt(i + 1);
      [llmPIs[i], llmPIs[j]] = [llmPIs[j], llmPIs[i]];
    }
    for (let i = otherPIs.length - 1; i > 0; i--) {
      const j = this.randInt(i + 1);
      [otherPIs[i], otherPIs[j]] = [otherPIs[j], otherPIs[i]];
    }

    // Expand role entries into per-player slots, TeamA first then TeamB
    const teamARoles: { role: Role; team: Team }[] = [];
    const teamBRoles: { role: Role; team: Team }[] = [];
    for (const entry of cfg.roles) {
      for (let c = 0; c < entry.count; c++) {
        (entry.team === Team.TeamA ? teamARoles : teamBRoles).push({ role: entry.role, team: entry.team });
      }
    }

    // Assign LLMs to TeamA roles, others to TeamB roles, overflow into remaining
    let li = 0, oi = 0;
    for (const { role, team } of teamARoles) {
      const pi = li < llmPIs.length ? llmPIs[li++] : otherPIs[oi++];
      if (pi === undefined) break;
      this.players[pi].role = role;
      this.players[pi].team = team;
    }
    for (const { role, team } of teamBRoles) {
      const pi = oi < otherPIs.length ? otherPIs[oi++] : llmPIs[li++];
      if (pi === undefined) break;
      this.players[pi].role = role;
      this.players[pi].team = team;
    }

    const n = this.players.length;
    const halfN = Math.ceil(n / 2);
    const groupPrefix = this.config.groupNamePrefixInRoomA;
    let orderedPIs: number[];

    if (groupPrefix) {
      // Put all players with the group prefix in RoomA (first halfN slots).
      const groupPIs: number[] = [];
      const restPIs: number[] = [];
      for (let i = 0; i < n; i++) {
        if (this.players[i].name.startsWith(groupPrefix)) groupPIs.push(i);
        else restPIs.push(i);
      }
      for (let i = groupPIs.length - 1; i > 0; i--) {
        const j = this.randInt(i + 1);
        [groupPIs[i], groupPIs[j]] = [groupPIs[j], groupPIs[i]];
      }
      for (let i = restPIs.length - 1; i > 0; i--) {
        const j = this.randInt(i + 1);
        [restPIs[i], restPIs[j]] = [restPIs[j], restPIs[i]];
      }
      orderedPIs = [...groupPIs, ...restPIs];
      // If more group players than RoomA slots, overflow into RoomB.
      if (groupPIs.length > halfN) {
        orderedPIs = [...groupPIs.slice(0, halfN), ...restPIs, ...groupPIs.slice(halfN)];
      }
    } else {
      const shuffled = Array.from({ length: n }, (_, i) => i);
      for (let i = n - 1; i > 0; i--) {
        const j = this.randInt(i + 1);
        [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
      }
      orderedPIs = shuffled;
    }

    for (let k = 0; k < n; k++) {
      const pi = orderedPIs[k];
      const room = k < halfN ? Room.RoomA : Room.RoomB;
      this.players[pi].room = room;
      this.players[pi].roomEntryTick = this.tickCount;
      const b = this.roomBounds(room);
      this.players[pi].x = b.x + 10 + this.randInt(Math.max(1, b.w - 20 - PLAYER_W));
      this.players[pi].y = b.y + 10 + this.randInt(Math.max(1, b.h - 20 - PLAYER_H));
    }
  }

  generateObstacles() {
    this.obstacles = [];
    const configured = this.config.obstacleCount;
    const obsCount = configured !== undefined
      ? configured
      : obstaclesForPlayers(this.players.length);
    if (obsCount <= 0) return;
    for (const room of [Room.RoomA, Room.RoomB]) {
      const b = this.roomBounds(room);
      for (let i = 0; i < obsCount; i++) {
        const margin = OBSTACLE_SIZE + PLAYER_W + 4;
        const ox = b.x + margin + this.randInt(Math.max(1, b.w - 2 * margin));
        const oy = b.y + margin + this.randInt(Math.max(1, b.h - 2 * margin));
        this.obstacles.push({ x: ox, y: oy, w: OBSTACLE_SIZE, h: OBSTACLE_SIZE, room });
      }
    }
  }

  startGame() {
    const sz = roomSizeForPlayers(this.players.length);
    this.roomW = sz;
    this.roomH = sz;
    this.wallMapA = new Uint8Array(sz * sz);
    this.wallMapB = new Uint8Array(sz * sz);
    this.generateObstacles();
    this.rebuildWallMap();
    this.assignRoles();
    this.phase = Phase.RoleReveal;
    this.revealTimer = 5 * TARGET_FPS;
    this.currentRound = 0;
  }

  startRound() {
    this.phase = Phase.Playing;
    const roundCfg = this.config.rounds[this.currentRound];
    this.roundTimer = (roundCfg?.durationSecs ?? 60) * TARGET_FPS;
    this.leaderA = -1;
    this.leaderB = -1;
    this.hostagesSelectedA = [];
    this.hostagesSelectedB = [];
    for (const p of this.players) {
      p.isLeader = false; p.isHostage = false; p.selectedAsHostage = false;
      p.commMenuOpen = false; p.chatMenuOpen = false; p.shareSelectOpen = false;
      p.infoScreen = "none"; p.usurpVote = -1;
      p.inChatroom = -1; p.pendingChatroomEntry = -1;
      p.globalChatOpen = false;
    }
    this.chatrooms.clear();
    this.hostagesPerRoom = this.getHostageCount();
    this.ensureLeaders();
  }

  ensureLeaders() {
    const roomA: number[] = [];
    const roomB: number[] = [];
    for (let i = 0; i < this.players.length; i++) {
      if (this.players[i].room === Room.RoomA) roomA.push(i);
      else roomB.push(i);
    }
    if ((this.leaderA < 0 || this.leaderA >= this.players.length || this.players[this.leaderA].room !== Room.RoomA) && roomA.length > 0) {
      this.setLeader(Room.RoomA, roomA[this.randInt(roomA.length)]);
    }
    if ((this.leaderB < 0 || this.leaderB >= this.players.length || this.players[this.leaderB].room !== Room.RoomB) && roomB.length > 0) {
      this.setLeader(Room.RoomB, roomB[this.randInt(roomB.length)]);
    }
  }

  getHostageCount(): number {
    const roundCfg = this.config.rounds[Math.min(this.currentRound, this.config.rounds.length - 1)];
    return roundCfg?.hostages ?? 1;
  }

  beginHostageSelect() {
    this.phase = Phase.HostageSelect;
    this.hostagesSelectedA = []; this.hostagesSelectedB = [];
    this.hostageCursorA = 0; this.hostageCursorB = 0;
    this.committedA = false; this.committedB = false;
    this.hostageSelectTimer = 15 * TARGET_FPS;
    for (const p of this.players) p.selectedAsHostage = false;
  }

  autoFillHostages(room: Room) {
    const list = room === Room.RoomA ? this.hostagesSelectedA : this.hostagesSelectedB;
    if (list.length >= this.hostagesPerRoom) return;
    const eligible = this.eligibleHostages(room).filter((i) => !list.includes(i));
    while (list.length < this.hostagesPerRoom && eligible.length > 0) {
      const idx = this.randInt(eligible.length);
      const pick = eligible.splice(idx, 1)[0];
      list.push(pick);
      this.players[pick].selectedAsHostage = true;
    }
  }

  exchangeProgress(): number {
    if (this.exchangeDuration <= 0) return 1;
    return 1 - this.exchangeTimer / this.exchangeDuration;
  }

  executeHostageExchange() {
    this.ejectAllChatrooms();
    for (const p of this.players) { p.globalChatOpen = false; }
    this.phase = Phase.HostageExchange;

    this.exchangeLeaderA = this.leaderA;
    this.exchangeLeaderB = this.leaderB;
    if (this.leaderA >= 0 && this.leaderA < this.players.length) {
      this.exchangeLeaderAStart = { x: this.players[this.leaderA].x, y: this.players[this.leaderA].y };
    }
    if (this.leaderB >= 0 && this.leaderB < this.players.length) {
      this.exchangeLeaderBStart = { x: this.players[this.leaderB].x, y: this.players[this.leaderB].y };
    }
    this.exchangeFromA = [];
    this.exchangeFromB = [];

    for (const hi of this.hostagesSelectedA) {
      if (hi >= 0 && hi < this.players.length) {
        this.exchangeFromA.push({ pi: hi, startX: this.players[hi].x, startY: this.players[hi].y });
      }
    }
    for (const hi of this.hostagesSelectedB) {
      if (hi >= 0 && hi < this.players.length) {
        this.exchangeFromB.push({ pi: hi, startX: this.players[hi].x, startY: this.players[hi].y });
      }
    }

    this.exchangeDuration = 3 * TARGET_FPS;
    this.exchangeTimer = this.exchangeDuration;
  }

  private resetExchangedPlayer(pi: number) {
    const p = this.players[pi];
    p.usurpVote = -1;
    p.globalChatLastRead = 0;
    p.globalChatScroll = 0;
  }

  finalizeExchange() {
    for (const h of this.exchangeFromA) {
      if (h.pi >= 0 && h.pi < this.players.length) {
        this.players[h.pi].room = Room.RoomB;
        this.players[h.pi].roomEntryTick = this.tickCount;
        const b = this.roomBounds(Room.RoomB);
        this.players[h.pi].x = b.x + 10 + this.randInt(Math.max(1, b.w - 20 - PLAYER_W));
        this.players[h.pi].y = b.y + 10 + this.randInt(Math.max(1, b.h - 20 - PLAYER_H));
        this.players[h.pi].velX = 0; this.players[h.pi].velY = 0;
        this.players[h.pi].carryX = 0; this.players[h.pi].carryY = 0;
        this.resetExchangedPlayer(h.pi);
      }
    }
    for (const h of this.exchangeFromB) {
      if (h.pi >= 0 && h.pi < this.players.length) {
        this.players[h.pi].room = Room.RoomA;
        this.players[h.pi].roomEntryTick = this.tickCount;
        const b = this.roomBounds(Room.RoomA);
        this.players[h.pi].x = b.x + 10 + this.randInt(Math.max(1, b.w - 20 - PLAYER_W));
        this.players[h.pi].y = b.y + 10 + this.randInt(Math.max(1, b.h - 20 - PLAYER_H));
        this.players[h.pi].velX = 0; this.players[h.pi].velY = 0;
        this.players[h.pi].carryX = 0; this.players[h.pi].carryY = 0;
        this.resetExchangedPlayer(h.pi);
      }
    }
    this.ensureLeaders();
  }

  checkWinCondition() {
    let hadesIdx = -1, persephoneIdx = -1, cerberusIdx = -1, demeterIdx = -1;
    for (let i = 0; i < this.players.length; i++) {
      if (this.players[i].role === Role.Hades) hadesIdx = i;
      if (this.players[i].role === Role.Persephone) persephoneIdx = i;
      if (this.players[i].role === Role.Cerberus) cerberusIdx = i;
      if (this.players[i].role === Role.Demeter) demeterIdx = i;
    }

    const sameRoom = hadesIdx >= 0 && persephoneIdx >= 0 &&
      this.players[hadesIdx].room === this.players[persephoneIdx].room;

    const hadesSharedWithCerberus = hadesIdx >= 0 && cerberusIdx >= 0 &&
      this.players[hadesIdx].sharedWith.has(cerberusIdx);

    const persephoneSharedWithDemeter = persephoneIdx >= 0 && demeterIdx >= 0 &&
      this.players[persephoneIdx].sharedWith.has(demeterIdx);

    if (sameRoom) {
      if (hadesSharedWithCerberus) this.winner = Team.TeamA;
      else if (persephoneSharedWithDemeter) this.winner = Team.TeamB;
      else this.winner = null;
    } else {
      if (persephoneSharedWithDemeter) this.winner = Team.TeamB;
      else if (hadesSharedWithCerberus) this.winner = Team.TeamA;
      else this.winner = null;
    }
  }

  // ---- Main tick ----

  step(inputs: InputState[], prevInputs: InputState[]) {
    this.tickCount++;
    switch (this.phase) {
      case Phase.Lobby: {
        if (this.players.length >= playerCountFromConfig(this.config)) {
          if (this.lobbyCountdown <= 0) this.lobbyCountdown = LOBBY_WAIT_TICKS;
          this.lobbyCountdown--;
          if (this.lobbyCountdown <= 0) this.startGame();
        } else {
          this.lobbyCountdown = 0;
        }
        for (let i = 0; i < this.players.length; i++) {
          this.applyInput(i, inputs[i] ?? emptyInput(), prevInputs[i] ?? emptyInput());
        }
        break;
      }
      case Phase.RoleReveal: {
        this.revealTimer--;
        for (let i = 0; i < this.players.length; i++) {
          this.applyInput(i, inputs[i] ?? emptyInput(), prevInputs[i] ?? emptyInput());
        }
        if (this.revealTimer <= 0) this.startRound();
        break;
      }
      case Phase.Playing: {
        this.roundTimer--;
        for (let i = 0; i < this.players.length; i++) {
          this.applyInput(i, inputs[i] ?? emptyInput(), prevInputs[i] ?? emptyInput());
        }
        this.tickChatrooms();
        if (this.roundTimer <= 0) this.beginHostageSelect();
        break;
      }
      case Phase.HostageSelect: {
        this.hostageSelectTimer--;
        for (let i = 0; i < this.players.length; i++) {
          this.applyInput(i, inputs[i] ?? emptyInput(), prevInputs[i] ?? emptyInput());
        }
        if ((this.committedA && this.committedB) || this.hostageSelectTimer <= 0) {
          this.autoFillHostages(Room.RoomA);
          this.autoFillHostages(Room.RoomB);
          this.executeHostageExchange();
        }
        break;
      }
      case Phase.HostageExchange: {
        this.exchangeTimer--;
        if (this.exchangeTimer <= 0) {
          this.finalizeExchange();
          this.currentRound++;
          if (this.currentRound >= this.config.rounds.length) {
            this.checkWinCondition();
            this.phase = Phase.Reveal;
            this.revealTimer = 5 * TARGET_FPS;
          } else {
            this.startRound();
          }
        }
        break;
      }
      case Phase.Reveal: {
        this.revealTimer--;
        if (this.revealTimer <= 0) {
          this.phase = Phase.GameOver;
          this.gameOverTimer = 10 * TARGET_FPS;
        }
        break;
      }
      case Phase.GameOver: {
        this.gameOverTimer--;
        if (this.gameOverTimer <= 0) this.resetGame();
        break;
      }
    }
  }

  resetGame() {
    this.phase = Phase.Lobby;
    this.tickCount = 0; this.lobbyCountdown = 0; this.currentRound = 0;
    this.roundTimer = 0; this.winner = null;
    this.leaderA = -1; this.leaderB = -1;
    this.hostagesSelectedA = []; this.hostagesSelectedB = [];
    this.chatMessages = []; this.obstacles = [];
    this.chatrooms.clear(); this.nextChatroomId = 0;
    this.globalMessagesA = []; this.globalMessagesB = [];
    for (const p of this.players) {
      p.team = Team.TeamA; p.role = Role.Shades;
      p.isLeader = false; p.isHostage = false; p.selectedAsHostage = false;
      p.revealedTo = new Set(); p.sharedWith = new Set(); p.colorRevealedTo = new Set();
      p.commMenuOpen = false; p.commMenuRow = 0;
      p.chatMenuOpen = false; p.chatMenuCat = 0; p.chatMenuItem = 0;
      p.shareSelectOpen = false; p.shareSelectRow = 0;
      p.infoScreen = "none"; p.usurpVote = -1;
      p.inChatroom = -1; p.chatroomEntryTick = 0; p.chatScrollOffset = 0;
      p.pendingChatroomEntry = -1;
      p.globalChatOpen = false; p.globalChatLastRead = 0; p.globalChatScroll = 0; p.globalChatActionRow = 0;
      p.roomEntryTick = 0;
      p.lastActionTicks = new Map<string, number>();
      p.velX = 0; p.velY = 0; p.carryX = 0; p.carryY = 0;
      const b = this.roomBounds(p.room);
      p.x = b.x + 10 + this.randInt(Math.max(1, b.w - 20 - PLAYER_W));
      p.y = b.y + 10 + this.randInt(Math.max(1, b.h - 20 - PLAYER_H));
    }
  }

  // ---- Helpers used by renderer ----

  roleName(role: Role): string {
    switch (role) {
      case Role.Hades: return HADES_ROLE_NAME;
      case Role.Persephone: return PERSEPHONE_ROLE_NAME;
      case Role.Cerberus: return CERBERUS_ROLE_NAME;
      case Role.Demeter: return DEMETER_ROLE_NAME;
      case Role.Shades: return SHADES_ROLE_NAME;
      case Role.Nymphs: return NYMPHS_ROLE_NAME;
    }
  }

  teamColor(team: Team): uint8 {
    switch (team) {
      case Team.TeamA: return TEAM_A_COLOR;
      case Team.TeamB: return TEAM_B_COLOR;
    }
  }

  playerColor(pi: number): uint8 {
    return PLAYER_COLORS[pi % PLAYER_COLORS.length];
  }

  roleIndicator(role: Role): { color: uint8; special: boolean } {
    switch (role) {
      case Role.Hades: return { color: TEAM_A_COLOR, special: true };
      case Role.Persephone: return { color: TEAM_B_COLOR, special: true };
      case Role.Cerberus: return { color: TEAM_A_COLOR, special: true };
      case Role.Demeter: return { color: TEAM_B_COLOR, special: true };
      case Role.Shades: return { color: TEAM_A_COLOR, special: false };
      case Role.Nymphs: return { color: TEAM_B_COLOR, special: false };
    }
  }
}

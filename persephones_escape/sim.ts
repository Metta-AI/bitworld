import { Phase, Team, Role, Room, PlayerShape, type InputState, type Player, type ChatMessage, type Obstacle, type uint8, type GameConfig } from "./types.js";
import { ROOM_W, ROOM_H, PLAYER_W, PLAYER_H, SCREEN_WIDTH, SCREEN_HEIGHT, MOTION_SCALE, ACCEL, FRICTION_NUM, FRICTION_DEN, MAX_SPEED, STOP_THRESHOLD, BUBBLE_RADIUS, TARGET_FPS, LOBBY_WAIT_TICKS, CHAT_MAX_CHARS, CHAT_VISIBLE_MESSAGES, CHAT_FADE_TICKS, SHARE_OFFER_TIMEOUT, OBSTACLE_SIZE, OBSTACLES_PER_ROOM, PLAYER_COLORS, HADES_ROLE_NAME, PERSEPHONE_ROLE_NAME, CERBERUS_ROLE_NAME, DEMETER_ROLE_NAME, SHADES_ROLE_NAME, NYMPHS_ROLE_NAME, GAMBLER_ROLE_NAME, TEAM_A_COLOR, TEAM_B_COLOR, DEFAULT_GAME_CONFIG, MINIMAP_SIZE } from "./constants.js";
import { Framebuffer } from "./framebuffer.js";
import { emptyInput } from "./protocol.js";
import { clamp, distSq } from "./util.js";

export class Sim {
  players: Player[] = [];
  chatMessages: ChatMessage[] = [];
  obstacles: Obstacle[] = [];
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

  // Exchange animation state — positions before swap
  exchangeFromA: { pi: number; startX: number; startY: number }[] = [];
  exchangeFromB: { pi: number; startX: number; startY: number }[] = [];
  exchangeLeaderA = -1;
  exchangeLeaderB = -1;
  exchangeLeaderAStart = { x: 0, y: 0 };
  exchangeLeaderBStart = { x: 0, y: 0 };
  exchangeDuration = 0;
  exchangeTimer = 0;

  constructor(config: GameConfig = DEFAULT_GAME_CONFIG) {
    this.config = config;
    let seed = 0xb1770;
    this.rng = () => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    };
    this.rebuildWallMap();
  }

  randInt(max: number): number {
    return Math.floor(this.rng() * max);
  }

  // ---- World geometry ----

  roomBounds(room: Room): { x: number; y: number; w: number; h: number } {
    return { x: 1, y: 1, w: ROOM_W - 2, h: ROOM_H - 2 };
  }

  wallMap(room: Room): Uint8Array {
    return room === Room.RoomA ? this.wallMapA : this.wallMapB;
  }

  rebuildWallMap() {
    for (const wm of [this.wallMapA, this.wallMapB]) {
      wm.fill(0);
      for (let y = 0; y < ROOM_H; y++) {
        for (let x = 0; x < ROOM_W; x++) {
          if (x === 0 || y === 0 || x === ROOM_W - 1 || y === ROOM_H - 1) {
            wm[y * ROOM_W + x] = 1;
          }
        }
      }
    }
    for (const ob of this.obstacles) {
      const wm = this.wallMap(ob.room);
      for (let dy = 0; dy < ob.h; dy++) {
        for (let dx = 0; dx < ob.w; dx++) {
          const wx = ob.x + dx, wy = ob.y + dy;
          if (wx >= 0 && wx < ROOM_W && wy >= 0 && wy < ROOM_H) {
            wm[wy * ROOM_W + wx] = 1;
          }
        }
      }
    }
  }

  isWallInRoom(room: Room, mx: number, my: number): boolean {
    if (mx < 0 || my < 0 || mx >= ROOM_W || my >= ROOM_H) return true;
    return this.wallMap(room)[my * ROOM_W + mx] === 1;
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
        if (wx < 0 || wy < 0 || wx >= ROOM_W || wy >= ROOM_H) return false;
        if (wm[wy * ROOM_W + wx]) return false;
      }
    }
    return true;
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
          const step = steps > 32 ? 2 : 1;
          for (let s = 1; s < steps; s += step) {
            const rx = originMx + ((dx * s / steps) | 0);
            const ry = originMy + ((dy * s / steps) | 0);
            if (rx < 0 || ry < 0 || rx >= ROOM_W || ry >= ROOM_H) { shadowed = true; break; }
            if (wm[ry * ROOM_W + rx]) { shadowed = true; break; }
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
      if (rx < 0 || ry < 0 || rx >= ROOM_W || ry >= ROOM_H) return false;
      if (wm[ry * ROOM_W + rx]) return false;
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

  applyMomentumAxis(player: Player, carry: { val: number }, velocity: number, horizontal: boolean) {
    carry.val += velocity;
    while (Math.abs(carry.val) >= MOTION_SCALE) {
      const step = carry.val < 0 ? -1 : 1;
      const nx = horizontal ? player.x + step : player.x;
      const ny = horizontal ? player.y : player.y + step;
      if (this.canOccupy(nx, ny, player.room)) {
        if (horizontal) player.x = nx; else player.y = ny;
        carry.val -= step * MOTION_SCALE;
      } else {
        let slid = false;
        if (horizontal) {
          for (const slideY of [player.y - 1, player.y + 1]) {
            if (this.canOccupy(nx, slideY, player.room)) {
              player.x = nx; player.y = slideY;
              carry.val -= step * MOTION_SCALE; slid = true; break;
            }
          }
        } else {
          for (const slideX of [player.x - 1, player.x + 1]) {
            if (this.canOccupy(slideX, ny, player.room)) {
              player.x = slideX; player.y = ny;
              carry.val -= step * MOTION_SCALE; slid = true; break;
            }
          }
        }
        if (!slid) { carry.val = 0; break; }
      }
    }
  }

  applyInput(pi: number, input: InputState, prevInput: InputState) {
    const player = this.players[pi];
    if (!player) return;

    if (player.infoScreen !== "none") {
      const anyPress = (input.attack && !prevInput.attack) || (input.b && !prevInput.b) ||
        (input.select && !prevInput.select);
      if (anyPress) player.infoScreen = "none";
      return;
    }

    if (player.menuOpen) {
      if (input.b && !prevInput.b) {
        player.menuOpen = false;
        return;
      }
      const cols = this.menuColumns(pi);
      if (cols.length > 0) {
        player.menuCol = Math.min(player.menuCol, cols.length - 1);
        const col = cols[player.menuCol];
        player.menuRow = Math.min(player.menuRow, col.items.length - 1);

        if (input.left && !prevInput.left) {
          player.menuCol = (player.menuCol - 1 + cols.length) % cols.length;
          player.menuRow = cols[player.menuCol].items.length - 1;
        }
        if (input.right && !prevInput.right) {
          player.menuCol = (player.menuCol + 1) % cols.length;
          player.menuRow = cols[player.menuCol].items.length - 1;
        }
        if (input.up && !prevInput.up) {
          const curCol = cols[player.menuCol];
          player.menuRow = (player.menuRow - 1 + curCol.items.length) % curCol.items.length;
        }
        if (input.down && !prevInput.down) {
          const curCol = cols[player.menuCol];
          player.menuRow = (player.menuRow + 1) % curCol.items.length;
        }
      }
      if (input.attack && !prevInput.attack) {
        this.menuSelect(pi);
      }
      return;
    }

    const leaderSelecting = this.phase === Phase.HostageSelect && player.isLeader && !player.menuOpen;
    if (leaderSelecting) {
      if (input.left && !prevInput.left) this.moveCursor(pi, -1);
      if (input.right && !prevInput.right) this.moveCursor(pi, 1);
      if (input.attack && !prevInput.attack) this.handleHostageToggle(pi);
      player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
    } else {
      let inputX = 0;
      let inputY = 0;
      if (input.left && !player.menuOpen) inputX -= 1;
      if (input.right && !player.menuOpen) inputX += 1;
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
      this.applyMomentumAxis(player, carryX, player.velX, true);
      this.applyMomentumAxis(player, carryY, player.velY, false);
      player.carryX = carryX.val;
      player.carryY = carryY.val;

      // Rooms are disjoint — no room switching via movement
    }

    if (input.b && !prevInput.b && !player.menuOpen) {
      if (this.phase === Phase.Playing || this.phase === Phase.HostageSelect) {
        player.menuOpen = true;
        player.menuCol = 0;
        player.menuRow = 0;
      }
    }

    if (input.select && !prevInput.select) {
      if (this.phase === Phase.HostageSelect && player.isLeader) {
        if (player.room === Room.RoomA) this.committedA = true;
        else this.committedB = true;
      }
    }

    if (this.phase === Phase.RoleReveal) {
      if ((input.attack && !prevInput.attack) || (input.b && !prevInput.b) || (input.select && !prevInput.select)) {
        // ready
      }
    }
  }

  // ---- Menu ----

  menuColumns(pi: number): { cat: string; items: string[] }[] {
    const player = this.players[pi];
    const cols: { cat: string; items: string[] }[] = [];

    cols.push({ cat: "INFO", items: ["ROLE", "SHARED"] });

    if (this.phase === Phase.Playing || this.phase === Phase.HostageSelect) {
      cols.push({ cat: "SHOW", items: ["CARD-NEAR", "COLOR-NEAR", "CARD-SIGHT", "COLOR-SIGHT"] });

      const shareItems: string[] = ["OFFER"];
      const nearby = this.playersInBubble(pi);
      const pending = nearby.filter((i) => this.players[i].shareOfferTarget === pi);
      if (pending.length > 0) shareItems.push("ACCEPT");
      cols.push({ cat: "SHARE", items: shareItems });

      const leaderItems: string[] = [];
      if (player.isLeader) leaderItems.push("PASS");
      const leaderIdx = player.room === Room.RoomA ? this.leaderA : this.leaderB;
      if (leaderIdx >= 0 && leaderIdx < this.players.length && !player.isLeader) {
        const leader = this.players[leaderIdx];
        if (leader.leaderOfferTarget === pi) leaderItems.push("ACCEPT");
      }
      if (leaderItems.length > 0) cols.push({ cat: "LEADER", items: leaderItems });

      if (!player.isLeader) {
        const roommates: string[] = ["NONE"];
        for (let i = 0; i < this.players.length; i++) {
          if (i !== pi && this.players[i].room === player.room && !this.players[i].isLeader) {
            roommates.push(`P${i}`);
          }
        }
        roommates.push("ME");
        cols.push({ cat: "USURP", items: roommates });
      }
    }

    return cols;
  }

  menuCurrentItem(pi: number): { cat: string; item: string } | null {
    const cols = this.menuColumns(pi);
    if (cols.length === 0) return null;
    const player = this.players[pi];
    const col = cols[Math.min(player.menuCol, cols.length - 1)];
    const row = Math.min(player.menuRow, col.items.length - 1);
    return { cat: col.cat, item: col.items[row] };
  }

  menuSelect(pi: number) {
    const player = this.players[pi];
    const cur = this.menuCurrentItem(pi);
    if (!cur) return;
    const key = `${cur.cat}:${cur.item}`;

    switch (key) {
      case "INFO:ROLE":
        player.infoScreen = "role";
        player.menuOpen = false;
        break;
      case "INFO:SHARED":
        player.infoScreen = "shared";
        player.menuOpen = false;
        break;
      case "SHOW:CARD-NEAR": {
        const nearby = this.playersInBubble(pi);
        for (const i of nearby) player.revealedTo.add(i);
        player.menuOpen = false;
        break;
      }
      case "SHOW:COLOR-NEAR": {
        const nearby = this.playersInBubble(pi);
        for (const i of nearby) player.colorRevealedTo.add(i);
        player.menuOpen = false;
        break;
      }
      case "SHOW:CARD-SIGHT": {
        for (const i of this.playersInSight(pi)) player.revealedTo.add(i);
        player.menuOpen = false;
        break;
      }
      case "SHOW:COLOR-SIGHT": {
        for (const i of this.playersInSight(pi)) player.colorRevealedTo.add(i);
        player.menuOpen = false;
        break;
      }
      case "SHARE:OFFER": {
        const nearby = this.playersInBubble(pi);
        if (nearby.length > 0) {
          player.shareOfferTarget = nearby[0];
          player.shareOfferTick = this.tickCount;
        }
        player.menuOpen = false;
        break;
      }
      case "SHARE:ACCEPT": {
        const nearby = this.playersInBubble(pi);
        const pending = nearby.filter((i) => this.players[i].shareOfferTarget === pi);
        if (pending.length > 0) {
          const other = this.players[pending[0]];
          player.revealedTo.add(pending[0]);
          other.revealedTo.add(pi);
          other.shareOfferTarget = -1;
          player.shareOfferTarget = -1;
        }
        player.menuOpen = false;
        break;
      }
      case "LEADER:PASS": {
        const nearby = this.playersInBubble(pi);
        if (nearby.length > 0) {
          player.leaderOfferTarget = nearby[0];
          player.leaderOfferTick = this.tickCount;
        }
        player.menuOpen = false;
        break;
      }
      case "LEADER:ACCEPT": {
        const leaderIdx = player.room === Room.RoomA ? this.leaderA : this.leaderB;
        if (leaderIdx >= 0 && leaderIdx < this.players.length) {
          const leader = this.players[leaderIdx];
          if (leader.leaderOfferTarget === pi) {
            leader.leaderOfferTarget = -1;
            leader.isLeader = false;
            this.setLeader(player.room, pi);
          }
        }
        player.menuOpen = false;
        break;
      }
    }

    if (cur.cat === "USURP") {
      if (cur.item === "NONE") {
        player.usurpVote = -1;
      } else if (cur.item === "ME") {
        player.usurpVote = pi;
      } else {
        for (let i = 0; i < this.players.length; i++) {
          if (i !== pi && this.players[i].room === player.room &&
              `P${i}` === cur.item) {
            player.usurpVote = i;
            break;
          }
        }
      }
      player.menuOpen = false;
      this.checkUsurp(player.room);
    }
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

  addChat(pi: number, text: string) {
    if (pi < 0 || pi >= this.players.length) return;
    const clean = text.slice(0, CHAT_MAX_CHARS).replace(/[^\x20-\x7e]/g, "");
    if (clean.length === 0) return;
    const player = this.players[pi];
    this.chatMessages.push({
      playerIndex: pi, color: this.playerColor(pi),
      text: clean, room: player.room, tick: this.tickCount,
    });
    while (this.chatMessages.length > CHAT_VISIBLE_MESSAGES * 4) this.chatMessages.shift();
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
    player.leaderOfferTarget = -1;
  }

  // ---- Game setup ----

  addPlayer(name: string): number {
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
      revealedTo: new Set(), colorRevealedTo: new Set(),
      colorIndex: this.players.length,
      shareOfferTarget: -1, shareOfferTick: 0,
      leaderOfferTarget: -1, leaderOfferTick: 0,
      menuOpen: false, menuCol: 0, menuRow: 0, infoScreen: "none",
      usurpVote: -1,
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
    const n = this.players.length;
    const cfg = this.config;
    const indices = Array.from({ length: n }, (_, i) => i);
    for (let i = n - 1; i > 0; i--) {
      const j = this.randInt(i + 1);
      [indices[i], indices[j]] = [indices[j], indices[i]];
    }

    const fixed = cfg.roles.filter((e) => typeof e.count === "number");
    const fills = cfg.roles.filter((e) => e.count === "fill");

    let assigned = 0;
    for (const entry of fixed) {
      for (let c = 0; c < (entry.count as number) && assigned < n; c++) {
        this.players[indices[assigned]].role = entry.role;
        this.players[indices[assigned]].team = entry.team;
        assigned++;
      }
    }

    const remaining = n - assigned;
    if (fills.length > 0 && remaining > 0) {
      const per = Math.floor(remaining / fills.length);
      let extra = remaining - per * fills.length;
      for (const entry of fills) {
        const cnt = per + (extra > 0 ? 1 : 0);
        if (extra > 0) extra--;
        for (let c = 0; c < cnt && assigned < n; c++) {
          this.players[indices[assigned]].role = entry.role;
          this.players[indices[assigned]].team = entry.team;
          assigned++;
        }
      }
    }

    const shuffled = Array.from({ length: n }, (_, i) => i);
    for (let i = n - 1; i > 0; i--) {
      const j = this.randInt(i + 1);
      [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
    }
    const halfN = Math.ceil(n / 2);
    for (let k = 0; k < n; k++) {
      const pi = shuffled[k];
      const room = k < halfN ? Room.RoomA : Room.RoomB;
      this.players[pi].room = room;
      const b = this.roomBounds(room);
      this.players[pi].x = b.x + 10 + this.randInt(Math.max(1, b.w - 20 - PLAYER_W));
      this.players[pi].y = b.y + 10 + this.randInt(Math.max(1, b.h - 20 - PLAYER_H));
    }
  }

  generateObstacles() {
    this.obstacles = [];
    for (const room of [Room.RoomA, Room.RoomB]) {
      const b = this.roomBounds(room);
      for (let i = 0; i < OBSTACLES_PER_ROOM; i++) {
        const margin = OBSTACLE_SIZE + PLAYER_W + 4;
        const ox = b.x + margin + this.randInt(Math.max(1, b.w - 2 * margin));
        const oy = b.y + margin + this.randInt(Math.max(1, b.h - 2 * margin));
        this.obstacles.push({ x: ox, y: oy, w: OBSTACLE_SIZE, h: OBSTACLE_SIZE, room });
      }
    }
  }

  startGame() {
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
      p.shareOfferTarget = -1; p.leaderOfferTarget = -1;
      p.menuOpen = false; p.infoScreen = "none"; p.usurpVote = -1;
    }
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

  finalizeExchange() {
    for (const h of this.exchangeFromA) {
      if (h.pi >= 0 && h.pi < this.players.length) {
        this.players[h.pi].room = Room.RoomB;
        const b = this.roomBounds(Room.RoomB);
        this.players[h.pi].x = b.x + 10 + this.randInt(Math.max(1, b.w - 20 - PLAYER_W));
        this.players[h.pi].y = b.y + 10 + this.randInt(Math.max(1, b.h - 20 - PLAYER_H));
        this.players[h.pi].velX = 0; this.players[h.pi].velY = 0;
        this.players[h.pi].carryX = 0; this.players[h.pi].carryY = 0;
      }
    }
    for (const h of this.exchangeFromB) {
      if (h.pi >= 0 && h.pi < this.players.length) {
        this.players[h.pi].room = Room.RoomA;
        const b = this.roomBounds(Room.RoomA);
        this.players[h.pi].x = b.x + 10 + this.randInt(Math.max(1, b.w - 20 - PLAYER_W));
        this.players[h.pi].y = b.y + 10 + this.randInt(Math.max(1, b.h - 20 - PLAYER_H));
        this.players[h.pi].velX = 0; this.players[h.pi].velY = 0;
        this.players[h.pi].carryX = 0; this.players[h.pi].carryY = 0;
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
      this.players[hadesIdx].revealedTo.has(cerberusIdx) &&
      this.players[cerberusIdx].revealedTo.has(hadesIdx);

    const persephoneSharedWithDemeter = persephoneIdx >= 0 && demeterIdx >= 0 &&
      this.players[persephoneIdx].revealedTo.has(demeterIdx) &&
      this.players[demeterIdx].revealedTo.has(persephoneIdx);

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
        if (this.players.length >= this.config.minPlayers) {
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
        for (const p of this.players) {
          if (p.shareOfferTarget >= 0 && this.tickCount - p.shareOfferTick > SHARE_OFFER_TIMEOUT) p.shareOfferTarget = -1;
          if (p.leaderOfferTarget >= 0 && this.tickCount - p.leaderOfferTick > SHARE_OFFER_TIMEOUT) p.leaderOfferTarget = -1;
        }
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
    for (const p of this.players) {
      p.team = Team.TeamA; p.role = Role.Shades;
      p.isLeader = false; p.isHostage = false; p.selectedAsHostage = false;
      p.revealedTo = new Set(); p.colorRevealedTo = new Set();
      p.shareOfferTarget = -1; p.leaderOfferTarget = -1; p.menuOpen = false; p.infoScreen = "none"; p.usurpVote = -1;
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
      case Role.Gambler: return GAMBLER_ROLE_NAME;
    }
  }

  teamColor(team: Team): uint8 {
    switch (team) {
      case Team.TeamA: return TEAM_A_COLOR;
      case Team.TeamB: return TEAM_B_COLOR;
      case Team.Gambler: return 1;
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
      case Role.Gambler: return { color: 1, special: false };
    }
  }
}

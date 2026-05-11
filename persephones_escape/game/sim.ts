import { Phase, Team, Role, Room, PlayerShape, type InputState, type Player, type ShoutMessage, type WhisperMessage, type Whisper, type Obstacle, type uint8, type GameConfig } from "./types.js";
import { ROOM_W, ROOM_H, PLAYER_W, PLAYER_H, SCREEN_WIDTH, SCREEN_HEIGHT, MOTION_SCALE, ACCEL, FRICTION_NUM, FRICTION_DEN, MAX_SPEED, STOP_THRESHOLD, BUBBLE_RADIUS, TARGET_FPS, LOBBY_WAIT_TICKS, CHAT_MAX_CHARS_PER_LINE, CHAT_MAX_LINES, ACTION_RATE_LIMIT_TICKS, WHISPER_RATE_LIMIT_TICKS, WHISPER_MAX_OCCUPANTS, ENTRY_REQUEST_TIMEOUT, OBSTACLE_SIZE, PLAYER_COLORS, HADES_ROLE_NAME, PERSEPHONE_ROLE_NAME, CERBERUS_ROLE_NAME, DEMETER_ROLE_NAME, SHADES_ROLE_NAME, NYMPHS_ROLE_NAME, SPY_ROLE_NAME, ECHO_HADES_ROLE_NAME, ECHO_PERSEPHONE_ROLE_NAME, ECHO_CERBERUS_ROLE_NAME, ECHO_DEMETER_ROLE_NAME, TEAM_A_COLOR, TEAM_B_COLOR, DEFAULT_GAME_CONFIG, MINIMAP_SIZE, BUTTON_A, BUTTON_B, BUTTON_LEFT, BUTTON_RIGHT, roomSizeForPlayers, obstaclesForPlayers, playerCountFromConfig, playerSpriteName, LEADER_SUMMIT_DURATION_SECS } from "./constants.js";
import { Framebuffer } from "../rendering/framebuffer.js";
import { emptyInput } from "./protocol.js";
import { clamp, distSq } from "./util.js";
import {
  MENU_DEFS, pressed, anyPressed, navigateMenu,
  WHISPER_MENU, WHISPER_OPEN_BUTTON, WHISPER_CLOSE_BUTTON, WHISPER_SELECT_BUTTON,
  navigateWhisperMenu, whisperMenuAction,
} from "./menu_defs.js";

function pref(pi: number): string {
  return `\x01${String.fromCharCode(pi)}`;
}

function prefList(indices: number[]): string {
  return indices.length > 0 ? indices.map(i => pref(i)).join(", ") : "NONE";
}

const INTRO_TOTAL_TICKS = 15 * TARGET_FPS;
const INTRO_PANEL_COUNT = 4;

function secondsToTicks(seconds: number): number {
  return Math.max(1, Math.floor(seconds * TARGET_FPS));
}

export class Sim {
  players: Player[] = [];
  chatMessages: ShoutMessage[] = [];
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
  psychopompsPerRoom = 1;
  revealTimer = 0;
  introPanel = 0;
  introReady = new Set<number>();
  gameOverTimer = 0;
  winner: Team | null = null;
  config: GameConfig;
  rng: () => number;

  leaderA = -1;
  leaderB = -1;
  psychopompsSelectedA: number[] = [];
  psychopompsSelectedB: number[] = [];
  psychopompCursorA = 0;
  psychopompCursorB = 0;
  committedA = false;
  committedB = false;
  psychopompSelectTimer = 0;

  leaderSummitTimer = 0;
  leaderSummitWhisperId = -1;
  leaderSummitOrigRoomA = Room.RoomA;
  leaderSummitOrigRoomB = Room.RoomB;

  whispers = new Map<number, Whisper>();
  nextWhisperId = 0;
  shoutMessagesA: WhisperMessage[] = [];
  shoutMessagesB: WhisperMessage[] = [];

  // Exchange animation state — positions before swap
  exchangeFromA: { pi: number; startX: number; startY: number }[] = [];
  exchangeFromB: { pi: number; startX: number; startY: number }[] = [];
  exchangeLeaderA = -1;
  exchangeLeaderB = -1;
  exchangeLeaderAStart = { x: 0, y: 0 };
  exchangeLeaderBStart = { x: 0, y: 0 };
  exchangeDuration = 0;
  exchangeTimer = 0;

  gameLog: { tick: number; event: string }[] = [];

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

  private pn(pi: number): string {
    return playerSpriteName(pi);
  }

  private log(event: string) {
    this.gameLog.push({ tick: this.tickCount, event });
  }

  private phaseTicks(normalSeconds: number, fastSeconds: number): number {
    return secondsToTicks(this.config.fastTimers ? fastSeconds : normalSeconds);
  }

  private introTicks(): number {
    return this.config.fastTimers ? secondsToTicks(1) : INTRO_TOTAL_TICKS;
  }

  private roleRevealTicks(): number {
    return this.introTicks();
  }

  private lobbyWaitTicks(): number {
    return this.config.fastTimers ? secondsToTicks(0.5) : LOBBY_WAIT_TICKS;
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
      if (player.infoScreen === "shared" && (this.phase === Phase.Playing || this.phase === Phase.PsychopompSelect || this.phase === Phase.LeaderSummit)) {
        if (input.left && !prevInput.left) { this.cycleSocialSurface(pi, -1); return; }
        if (input.right && !prevInput.right) { this.cycleSocialSurface(pi, 1); return; }
      }
      if (pressed(input, prevInput, MENU_DEFS.info.selectButton)) player.infoScrollOffset = Math.max(0, player.infoScrollOffset - 1);
      if (input.up && !prevInput.up) player.infoScrollOffset = Math.max(0, player.infoScrollOffset - 1);
      if (input.down && !prevInput.down) player.infoScrollOffset++;
      if (anyPressed(input, prevInput, MENU_DEFS.info.closeButton!,
        MENU_DEFS.shout.openButton!, MENU_DEFS.whisper.closeButton!)) {
        player.infoScreen = "none"; player.infoScrollOffset = 0;
      }
      return;
    }

    if (player.shoutOpen || (this.phase === Phase.PsychopompSelect && player.isLeader)) {
      this.applyShoutInput(pi, input, prevInput);
      return;
    }

    if (player.inWhisper >= 0) {
      this.applyWhisperInput(pi, input, prevInput);
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

    // A creates a new whisper only. Joining existing whispers is explicit via B.
    if (pressed(input, prevInput, MENU_DEFS.whisper.selectButton)) {
      if (this.phase === Phase.Playing || this.phase === Phase.PsychopompSelect || this.phase === Phase.LeaderSummit) {
        const nearbyWhisperer = this.findNearbyWhisperPlayer(pi);
        if (nearbyWhisperer >= 0) {
          this.setNotice(pi, "YOU'LL BE OVERHEARD");
        } else if (player.pendingWhisperEntry < 0) {
          this.createWhisper(pi);
        }
      }
    }

    // B requests entry to a nearby whisper, or cancels a pending entry request.
    if (pressed(input, prevInput, MENU_DEFS.info.openButton!)) {
      if (player.pendingWhisperEntry >= 0) {
        this.cancelEntryRequest(pi);
      } else {
        const nearbyWhisperer = this.findNearbyWhisperPlayer(pi);
        if (nearbyWhisperer >= 0) {
          const cr = this.whispers.get(this.players[nearbyWhisperer].inWhisper);
          if (cr) this.requestWhisperEntry(pi, cr.id);
        }
      }
    }

    // SELECT opens room shout/info surface directly. Left/right swaps shout/info.
    if (pressed(input, prevInput, MENU_DEFS.shout.openButton!)) {
      if (this.phase === Phase.Playing || this.phase === Phase.PsychopompSelect || this.phase === Phase.LeaderSummit) {
        this.openShoutSurface(pi);
      }
    }

    if (this.phase === Phase.RoleReveal) {
      // any button = ready
    }
  }

  openShoutSurface(pi: number) {
    const player = this.players[pi];
    player.infoScreen = "none";
    player.whisperMenuOpen = false;
    player.shareSelectOpen = false;
    player.shoutOpen = true;
    player.shoutScroll = 0;
    player.shoutActionRow = 0;
  }

  openInfoSurface(pi: number) {
    const player = this.players[pi];
    player.shoutOpen = false;
    player.whisperMenuOpen = false;
    player.shareSelectOpen = false;
    player.infoScreen = "shared";
    player.infoScrollOffset = 0;
  }

  cycleSocialSurface(pi: number, dir: -1 | 1) {
    const player = this.players[pi];
    const tabs = player.inWhisper >= 0 ? ["whisper", "shout", "info"] : ["shout", "info"];
    const current = player.infoScreen === "shared" ? "info" : player.shoutOpen ? "shout" : "whisper";
    const idx = Math.max(0, tabs.indexOf(current));
    const next = tabs[(idx + dir + tabs.length) % tabs.length];

    player.infoScreen = "none";
    player.shoutOpen = false;
    player.whisperMenuOpen = false;
    player.shareSelectOpen = false;

    if (next === "shout") this.openShoutSurface(pi);
    else if (next === "info") this.openInfoSurface(pi);
  }

  setNotice(pi: number, text: string) {
    const player = this.players[pi];
    player.noticeText = text;
    player.noticeUntilTick = this.tickCount + TARGET_FPS;
  }

  applyWhisperInput(pi: number, input: InputState, prevInput: InputState) {
    const player = this.players[pi];
    const cr = this.whispers.get(player.inWhisper);
    if (!cr) { player.inWhisper = -1; return; }

    const shareDef = MENU_DEFS.share;

    if (player.shareSelectOpen) {
      const offerers = player.shareSelectMode === "color"
        ? this.whisperColorOfferers(pi)
        : this.whisperShareOfferers(pi);
      if (offerers.length === 0) { player.shareSelectOpen = false; return; }
      player.shareSelectRow = navigateMenu(input, prevInput, shareDef, offerers.length, player.shareSelectRow);
      if (pressed(input, prevInput, shareDef.selectButton)) {
        const target = offerers[player.shareSelectRow];
        if (player.shareSelectMode === "color") {
          this.executeColorSwap(cr, pi, target);
        } else {
          this.executeRoleSwap(cr, pi, target);
        }
        player.shareSelectOpen = false;
      }
      if (shareDef.closeButton && pressed(input, prevInput, shareDef.closeButton)) {
        player.shareSelectOpen = false;
      }
      player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
      return;
    }

    if (player.whisperMenuOpen) {
      const nav = navigateWhisperMenu(input, prevInput, player.whisperMenuCat, player.whisperMenuItem);
      player.whisperMenuCat = nav.catIdx;
      player.whisperMenuItem = nav.itemIdx;

      if (pressed(input, prevInput, WHISPER_SELECT_BUTTON)) {
        const action = whisperMenuAction(player.whisperMenuCat, player.whisperMenuItem);
        if (action && this.whisperActionEnabled(pi, action)) {
          this.whisperActionSelect(pi, action);
          player.whisperMenuOpen = false;
        }
      }
      if (pressed(input, prevInput, WHISPER_CLOSE_BUTTON)) {
        player.whisperMenuOpen = false;
      }
      player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
      return;
    }

    const isSummit = this.phase === Phase.LeaderSummit && cr.id === this.leaderSummitWhisperId;

    if (input.left && !prevInput.left) {
      this.cycleSocialSurface(pi, -1);
      return;
    }
    if (input.right && !prevInput.right) {
      this.cycleSocialSurface(pi, 1);
      return;
    }

    if (!isSummit && pressed(input, prevInput, WHISPER_CLOSE_BUTTON)) {
      this.leaveWhisper(pi);
      return;
    }

    if (!isSummit && pressed(input, prevInput, WHISPER_OPEN_BUTTON)) {
      player.whisperMenuOpen = true;
      player.whisperMenuCat = 0;
      player.whisperMenuItem = 0;
      return;
    }

    if (input.up && !prevInput.up) {
      player.whisperScrollOffset = Math.min(player.whisperScrollOffset + 1, Math.max(0, cr.messages.length - 1));
    }
    if (input.down && !prevInput.down) {
      player.whisperScrollOffset = Math.max(player.whisperScrollOffset - 1, 0);
    }

    player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
  }

  applyShoutInput(pi: number, input: InputState, prevInput: InputState) {
    const player = this.players[pi];
    const msgs = this.shoutMessagesForPlayer(pi);
    const gDef = MENU_DEFS.shout;
    const hDef = MENU_DEFS.psychopomp;

    if (gDef.closeButton && pressed(input, prevInput, gDef.closeButton)) {
      player.shoutLastRead = (player.room === Room.RoomA ? this.shoutMessagesA : this.shoutMessagesB).length;
      player.shoutOpen = false;
      player.shoutScroll = 0;
      return;
    }

    const leaderPsychopomp = this.phase === Phase.PsychopompSelect && player.isLeader;

    if (!leaderPsychopomp) {
      if (input.left && !prevInput.left) { this.cycleSocialSurface(pi, -1); return; }
      if (input.right && !prevInput.right) { this.cycleSocialSurface(pi, 1); return; }
      if (pressed(input, prevInput, MENU_DEFS.whisper.openButton!)) {
        const candidates = this.usurpCandidates(pi);
        if (candidates.length > 0) {
          player.shoutActionRow = (player.shoutActionRow + 1) % candidates.length;
        }
        return;
      }
    }

    if (leaderPsychopomp) {
      const committed = player.room === Room.RoomA ? this.committedA : this.committedB;
      if (!committed) {
        const eligible = this.eligiblePsychopomps(player.room);
        const cursor = player.room === Room.RoomA ? this.psychopompCursorA : this.psychopompCursorB;
        const newCursor = navigateMenu(input, prevInput, hDef, eligible.length, cursor);
        if (player.room === Room.RoomA) this.psychopompCursorA = newCursor;
        else this.psychopompCursorB = newCursor;
        if (pressed(input, prevInput, hDef.selectButton)) this.handlePsychopompToggle(pi);
        if (pressed(input, prevInput, MENU_DEFS.whisper.openButton!)) {
          if (player.room === Room.RoomA) this.committedA = true;
          else this.committedB = true;
        }
      }
    } else {
      if (pressed(input, prevInput, gDef.selectButton)) {
        const candidates = this.usurpCandidates(pi);
        if (candidates.length > 0) {
          const row = Math.min(player.shoutActionRow, candidates.length - 1);
          const item = candidates[row];
          const prevVote = player.usurpVote;
          if (item === "NONE") player.usurpVote = -1;
          else if (item === "ME") player.usurpVote = pi;
          else {
            const match = item.match(/^P(\d+)$/);
            if (match) player.usurpVote = parseInt(match[1]);
          }
          if (player.usurpVote !== prevVote && player.usurpVote >= 0) {
            const shoutMsgs = player.room === Room.RoomA ? this.shoutMessagesA : this.shoutMessagesB;
            shoutMsgs.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} voted for ${pref(player.usurpVote)}` });
          }
          this.checkUsurp(player.room);
        }
      }

      const candidates = this.usurpCandidates(pi);
      if (candidates.length > 0) {
        player.shoutActionRow = navigateMenu(input, prevInput, gDef, candidates.length, player.shoutActionRow);
      }
    }

    if (input.up && !prevInput.up) {
      player.shoutScroll = Math.min(player.shoutScroll + 1, Math.max(0, msgs.length - 1));
    }
    if (input.down && !prevInput.down) {
      player.shoutScroll = Math.max(player.shoutScroll - 1, 0);
    }

    player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
  }

  // ---- Whisper action items (B-button in whisper) ----

  private executeColorSwap(cr: { colorOffers: Set<number>; messages: any[]; occupants: Set<number> }, pi: number, target: number) {
    if (this.players[pi].colorRevealedTo.has(target) && this.players[target].colorRevealedTo.has(pi)) {
      cr.colorOffers.delete(target);
      cr.colorOffers.delete(pi);
      return;
    }
    this.players[pi].colorRevealedTo.add(target);
    this.players[target].colorRevealedTo.add(pi);
    cr.colorOffers.delete(target);
    cr.colorOffers.delete(pi);
    cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `COLOR XCHG: ${prefList([...cr.occupants])}` });
    this.log(`${this.pn(pi)} and ${this.pn(target)} exchanged colors`);
  }

  private executeRoleSwap(cr: { revealOffers: Set<number>; messages: any[]; occupants: Set<number> }, pi: number, target: number) {
    if (this.players[pi].sharedWith.has(target) && this.players[target].sharedWith.has(pi)) {
      cr.revealOffers.delete(target);
      cr.revealOffers.delete(pi);
      return;
    }
    this.players[pi].revealedTo.add(target);
    this.players[target].revealedTo.add(pi);
    this.players[pi].sharedWith.add(target);
    this.players[target].sharedWith.add(pi);
    cr.revealOffers.delete(target);
    cr.revealOffers.delete(pi);
    cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `ROLE XCHG: ${prefList([...cr.occupants])}` });
    this.log(`${this.pn(pi)} and ${this.pn(target)} shared roles`);
  }

  whisperShareOfferers(pi: number): number[] {
    const player = this.players[pi];
    const cr = this.whispers.get(player.inWhisper);
    if (!cr) return [];
    const offerers: number[] = [];
    for (const oi of cr.revealOffers) {
      if (oi !== pi && cr.occupants.has(oi) && !this.players[pi].sharedWith.has(oi)) offerers.push(oi);
    }
    return offerers;
  }

  whisperHasLeaderOffer(pi: number): boolean {
    const player = this.players[pi];
    const cr = this.whispers.get(player.inWhisper);
    if (!cr) return false;
    return cr.leaderOffer >= 0 && cr.leaderOffer !== pi && cr.occupants.has(cr.leaderOffer);
  }

  whisperColorOfferers(pi: number): number[] {
    const player = this.players[pi];
    const cr = this.whispers.get(player.inWhisper);
    if (!cr) return [];
    const offerers: number[] = [];
    for (const oi of cr.colorOffers) {
      if (oi !== pi && cr.occupants.has(oi) && !this.players[pi].colorRevealedTo.has(oi)) offerers.push(oi);
    }
    return offerers;
  }

  usurpCandidates(pi: number): string[] {
    const player = this.players[pi];
    if (player.isLeader) return [];
    if (this.phase !== Phase.Playing && this.phase !== Phase.PsychopompSelect) return [];
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

  handlePsychopompToggle(pi: number) {
    const player = this.players[pi];
    const committed = player.room === Room.RoomA ? this.committedA : this.committedB;
    if (committed) return;
    const eligible = this.eligiblePsychopomps(player.room);
    if (eligible.length === 0) return;
    const cursor = player.room === Room.RoomA ? this.psychopompCursorA : this.psychopompCursorB;
    const targetIdx = eligible[cursor % eligible.length];
    if (targetIdx === undefined) return;

    const list = player.room === Room.RoomA ? this.psychopompsSelectedA : this.psychopompsSelectedB;
    const already = list.indexOf(targetIdx);
    if (already >= 0) {
      list.splice(already, 1);
      this.players[targetIdx].selectedAsPsychopomp = false;
    } else if (list.length < this.psychopompsPerRoom) {
      list.push(targetIdx);
      this.players[targetIdx].selectedAsPsychopomp = true;
    }
  }

  moveCursor(pi: number, delta: number) {
    const player = this.players[pi];
    if (this.phase !== Phase.PsychopompSelect || !player.isLeader) return;
    const committed = player.room === Room.RoomA ? this.committedA : this.committedB;
    if (committed) return;
    const eligible = this.eligiblePsychopomps(player.room);
    if (eligible.length === 0) return;
    if (player.room === Room.RoomA) {
      this.psychopompCursorA = (this.psychopompCursorA + delta + eligible.length) % eligible.length;
    } else {
      this.psychopompCursorB = (this.psychopompCursorB + delta + eligible.length) % eligible.length;
    }
  }

  eligiblePsychopomps(room: Room): number[] {
    const result: number[] = [];
    for (let i = 0; i < this.players.length; i++) {
      const p = this.players[i];
      if (p.room === room && !p.isLeader) result.push(i);
    }
    return result;
  }

  // ---- Whispers ----

  createWhisper(pi: number) {
    const player = this.players[pi];
    if (player.inWhisper >= 0) return;
    const id = this.nextWhisperId++;
    const cr: Whisper = {
      id, room: player.room, ownerIndex: pi,
      x: player.x, y: player.y,
      occupants: new Set([pi]),
      pendingEntry: [], pendingEntryTicks: [],
      messages: [], revealOffers: new Set(), colorOffers: new Set(), leaderOffer: -1,
    };
    this.whispers.set(id, cr);
    player.inWhisper = id;
    player.whisperEntryTick = this.tickCount;
    player.whisperScrollOffset = 0;
    player.whisperMenuOpen = false; player.whisperMenuCat = 0; player.whisperMenuItem = 0;
    player.shareSelectOpen = false; player.shareSelectRow = 0;
    player.velX = 0; player.velY = 0; player.carryX = 0; player.carryY = 0;
    this.log(`${this.pn(pi)} opened whisper`);
  }

  findNearbyWhisperPlayer(pi: number): number {
    const player = this.players[pi];
    const r2 = BUBBLE_RADIUS * BUBBLE_RADIUS;
    for (let i = 0; i < this.players.length; i++) {
      if (i === pi) continue;
      const other = this.players[i];
      if (other.room !== player.room || other.inWhisper < 0) continue;
      if (distSq(player.x, player.y, other.x, other.y) <= r2) return i;
    }
    return -1;
  }

  requestWhisperEntry(pi: number, whisperId: number) {
    const cr = this.whispers.get(whisperId);
    if (!cr) return;
    if (cr.occupants.has(pi)) return;
    if (cr.pendingEntry.includes(pi)) return;
    if (cr.occupants.size >= WHISPER_MAX_OCCUPANTS) return;
    cr.pendingEntry.push(pi);
    cr.pendingEntryTicks.push(this.tickCount);
    this.players[pi].pendingWhisperEntry = whisperId;
    cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} requests entry` });
  }

  addToWhisper(whisperId: number, pi: number) {
    const cr = this.whispers.get(whisperId);
    if (!cr) return;
    if (cr.occupants.has(pi)) return;
    if (cr.occupants.size >= WHISPER_MAX_OCCUPANTS) return;
    const p = this.players[pi];
    if (p.inWhisper >= 0) return;
    cr.occupants.add(pi);
    cr.colorOffers.clear();
    cr.revealOffers.clear();
    p.inWhisper = whisperId;
    p.whisperEntryTick = this.tickCount;
    p.pendingWhisperEntry = -1;
    p.whisperScrollOffset = 0;
    p.whisperMenuOpen = false; p.whisperMenuCat = 0; p.whisperMenuItem = 0;
    p.shareSelectOpen = false; p.shareSelectRow = 0;
    p.velX = 0; p.velY = 0; p.carryX = 0; p.carryY = 0;
    this.log(`${this.pn(pi)} joined ${this.pn(cr.ownerIndex)}'s whisper`);
  }

  grantWhisperEntry(whisperId: number, requestingPi: number) {
    const cr = this.whispers.get(whisperId);
    if (!cr) return;
    const idx = cr.pendingEntry.indexOf(requestingPi);
    if (idx < 0) return;
    if (cr.occupants.size >= WHISPER_MAX_OCCUPANTS) return;
    cr.pendingEntry.splice(idx, 1);
    cr.pendingEntryTicks.splice(idx, 1);
    this.addToWhisper(whisperId, requestingPi);
  }

  denyWhisperEntry(whisperId: number, requestingPi: number) {
    const cr = this.whispers.get(whisperId);
    if (!cr) return;
    const idx = cr.pendingEntry.indexOf(requestingPi);
    if (idx < 0) return;
    cr.pendingEntry.splice(idx, 1);
    cr.pendingEntryTicks.splice(idx, 1);
    this.players[requestingPi].pendingWhisperEntry = -1;
  }

  cancelEntryRequest(pi: number) {
    const player = this.players[pi];
    if (player.pendingWhisperEntry < 0) return;
    const cr = this.whispers.get(player.pendingWhisperEntry);
    if (cr) {
      const idx = cr.pendingEntry.indexOf(pi);
      if (idx >= 0) { cr.pendingEntry.splice(idx, 1); cr.pendingEntryTicks.splice(idx, 1); }
    }
    player.pendingWhisperEntry = -1;
  }

  leaveWhisper(pi: number) {
    const player = this.players[pi];
    const cr = this.whispers.get(player.inWhisper);
    player.inWhisper = -1;
    player.whisperScrollOffset = 0;
    player.whisperMenuOpen = false;
    player.shareSelectOpen = false;
    if (!cr) return;
    cr.occupants.delete(pi);
    cr.revealOffers.delete(pi);
    cr.colorOffers.delete(pi);
    if (cr.leaderOffer === pi) cr.leaderOffer = -1;
    cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} left` });
    if (cr.occupants.size === 0) {
      for (const pendingPi of cr.pendingEntry) {
        this.players[pendingPi].pendingWhisperEntry = -1;
      }
      this.whispers.delete(cr.id);
    }
  }

  ejectAllWhispers() {
    for (const cr of this.whispers.values()) {
      for (const oi of cr.occupants) {
        this.players[oi].inWhisper = -1;
        this.players[oi].whisperScrollOffset = 0;
      }
      for (const pi of cr.pendingEntry) {
        this.players[pi].pendingWhisperEntry = -1;
      }
    }
    this.whispers.clear();
  }

  tickWhispers() {
    for (const cr of this.whispers.values()) {
      for (let i = cr.pendingEntry.length - 1; i >= 0; i--) {
        if (this.tickCount - cr.pendingEntryTicks[i] > ENTRY_REQUEST_TIMEOUT) {
          this.players[cr.pendingEntry[i]].pendingWhisperEntry = -1;
          cr.pendingEntry.splice(i, 1);
          cr.pendingEntryTicks.splice(i, 1);
        }
      }
    }
  }

  whisperActionEnabled(pi: number, action: string): boolean {
    const player = this.players[pi];
    const cr = this.whispers.get(player.inWhisper);
    if (!cr) return false;
    switch (action) {
      case "C.OFFER": return [...cr.occupants].some(oi => oi !== pi && !this.players[pi].colorRevealedTo.has(oi));
      case "C.UNOFFR": return cr.colorOffers.has(pi);
      case "C.ACCPT": return this.whisperColorOfferers(pi).length > 0;
      case "ROLE": return true;
      case "R.OFFER": return [...cr.occupants].some(oi => oi !== pi && !this.players[pi].sharedWith.has(oi));
      case "R.UNOFFR": return cr.revealOffers.has(pi);
      case "R.ACCPT": return this.whisperShareOfferers(pi).length > 0;
      case "PASS": return player.isLeader;
      case "TAKE": return cr.leaderOffer >= 0 && cr.leaderOffer !== pi && cr.occupants.has(cr.leaderOffer);
      case "GRANT": return cr.pendingEntry.length > 0;
      case "EXIT": return true;
      default: return false;
    }
  }

  whisperActionSelect(pi: number, action: string) {
    const player = this.players[pi];
    const cr = this.whispers.get(player.inWhisper);
    if (!cr) return;
    if (!this.actionRateCheck(pi, action)) return;

    switch (action) {
      case "C.OFFER": {
        if (cr.colorOffers.has(pi)) break;
        cr.colorOffers.add(pi);
        const colorOfferers = this.whisperColorOfferers(pi);
        if (colorOfferers.length === 1) {
          this.executeColorSwap(cr, pi, colorOfferers[0]);
        } else {
          cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} offered color` });
        }
        break;
      }
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
        this.log(`${this.pn(pi)} showed role to whisper`);
        break;
      case "R.OFFER": {
        if (cr.revealOffers.has(pi)) break;
        cr.revealOffers.add(pi);
        const roleOfferers = this.whisperShareOfferers(pi);
        if (roleOfferers.length === 1) {
          this.executeRoleSwap(cr, pi, roleOfferers[0]);
        } else {
          cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} offered role` });
          this.log(`${this.pn(pi)} offered role exchange`);
        }
        break;
      }
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
            this.log(`${this.pn(pi)} took leadership from ${this.pn(prevLeader)}`);
          }
        }
        break;
      case "GRANT":
        if (cr.pendingEntry.length > 0) {
          const entrant = cr.pendingEntry[0];
          this.grantWhisperEntry(cr.id, entrant);
          cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} granted ${pref(entrant)}` });
        }
        break;
      case "EXIT":
        this.leaveWhisper(pi);
        break;
    }
  }

  private actionRateCheck(pi: number, action: string, defaultLimit?: number): boolean {
    if (pi < 0 || pi >= this.players.length) return false;
    const player = this.players[pi];
    const limits = this.config.actionRateLimits;
    const limit = limits?.[action] ?? limits?.["_default"] ?? defaultLimit ?? ACTION_RATE_LIMIT_TICKS;
    const last = player.lastActionTicks.get(action) ?? -Infinity;
    if (this.tickCount - last < limit) return false;
    player.lastActionTicks.set(action, this.tickCount);
    return true;
  }

  private chatRateCheck(pi: number, text: string, isWhisper: boolean): string[] | null {
    const key = isWhisper ? "whisper_chat" : "shout";
    const limit = isWhisper ? WHISPER_RATE_LIMIT_TICKS : undefined;
    if (!this.actionRateCheck(pi, key, limit)) return null;
    const perLine = this.config.chatMaxCharsPerLine ?? CHAT_MAX_CHARS_PER_LINE;
    const clean = text.replace(/[^\x20-\x7e]/g, "");
    if (clean.length === 0) return null;
    const lines: string[] = [];
    for (let i = 0; i < clean.length && lines.length < CHAT_MAX_LINES; i += perLine) {
      lines.push(clean.slice(i, i + perLine));
    }
    return lines;
  }

  addWhisperChat(whisperId: number, pi: number, text: string) {
    const cr = this.whispers.get(whisperId);
    if (!cr || !cr.occupants.has(pi)) return;
    const lines = this.chatRateCheck(pi, text, true);
    if (!lines) return;
    for (const line of lines) {
      cr.messages.push({ type: 'text', senderIndex: pi, tick: this.tickCount, text: line });
    }
    this.log(`${this.pn(pi)} whisper: ${lines.join("")}`);
  }

  addShout(pi: number, text: string) {
    const lines = this.chatRateCheck(pi, text, false);
    if (!lines) return;
    const player = this.players[pi];
    const dest = player.room === Room.RoomA ? this.shoutMessagesA : this.shoutMessagesB;
    for (const line of lines) {
      dest.push({ type: 'text', senderIndex: pi, tick: this.tickCount, text: line });
    }
    this.log(`${this.pn(pi)} shout: ${lines.join("")}`);
  }

  shoutMessagesForPlayer(pi: number): WhisperMessage[] {
    const player = this.players[pi];
    const msgs = player.room === Room.RoomA ? this.shoutMessagesA : this.shoutMessagesB;
    return msgs.filter((m) => m.tick >= player.roomEntryTick);
  }

  whisperMessagesForPlayer(pi: number): WhisperMessage[] {
    const player = this.players[pi];
    const cr = this.whispers.get(player.inWhisper);
    if (!cr) return [];
    return cr.messages.filter((m: WhisperMessage) => m.tick >= player.whisperEntryTick);
  }

  shoutUnreadCount(pi: number): number {
    const player = this.players[pi];
    const msgs = player.room === Room.RoomA ? this.shoutMessagesA : this.shoutMessagesB;
    let count = 0;
    for (let i = player.shoutLastRead; i < msgs.length; i++) {
      if (msgs[i].tick >= player.roomEntryTick) count++;
    }
    return count;
  }

  addChat(pi: number, text: string) {
    const lines = this.chatRateCheck(pi, text, false);
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
    const shoutMsgs = room === Room.RoomA ? this.shoutMessagesA : this.shoutMessagesB;
    shoutMsgs.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `${pref(pi)} is now leader` });
    this.log(`${this.pn(pi)} became leader of ${player.room === Room.RoomA ? "Underworld" : "Mortal Realm"}`);
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
      isLeader: false, isPsychopomp: false, selectedAsPsychopomp: false,
      revealedTo: new Set(), sharedWith: new Set(), colorRevealedTo: new Set(),
      colorIndex: this.players.length,
      whisperMenuOpen: false, whisperMenuCat: 0, whisperMenuItem: 0,
      shareSelectOpen: false, shareSelectRow: 0, shareSelectMode: "card" as const,
      infoScreen: "none", infoScrollOffset: 0, usurpVote: -1,
      inWhisper: -1, whisperEntryTick: 0, whisperScrollOffset: 0,
      pendingWhisperEntry: -1,
      shoutOpen: false, shoutLastRead: 0, shoutScroll: 0, shoutActionRow: 0,
      noticeText: null, noticeUntilTick: 0,
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
    this.psychopompsSelectedA = this.psychopompsSelectedA.filter((i) => i !== index).map((i) => (i > index ? i - 1 : i));
    this.psychopompsSelectedB = this.psychopompsSelectedB.filter((i) => i !== index).map((i) => (i > index ? i - 1 : i));
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
    this.phase = Phase.RosterReveal;
    this.revealTimer = this.introTicks();
    this.introPanel = 0;
    this.introReady.clear();
    this.currentRound = 0;
    this.gameLog = [];
    for (let i = 0; i < this.players.length; i++) {
      const p = this.players[i];
      this.log(`${this.pn(i)} = ${this.roleName(p.role)} (${p.team === Team.TeamA ? "Shades" : "Nymphs"}) in ${p.room === Room.RoomA ? "Underworld" : "Mortal Realm"}`);
    }
  }

  startRound() {
    this.log(`--- Round ${this.currentRound + 1} started ---`);
    this.phase = Phase.Playing;
    this.introReady.clear();
    const roundCfg = this.config.rounds[this.currentRound];
    this.roundTimer = (roundCfg?.durationSecs ?? 60) * TARGET_FPS;
    this.leaderA = -1;
    this.leaderB = -1;
    this.psychopompsSelectedA = [];
    this.psychopompsSelectedB = [];
    for (const p of this.players) {
      p.isLeader = false; p.isPsychopomp = false; p.selectedAsPsychopomp = false;
      p.whisperMenuOpen = false; p.shareSelectOpen = false;
      p.infoScreen = "none"; p.usurpVote = -1;
      p.inWhisper = -1; p.pendingWhisperEntry = -1;
      p.shoutOpen = false;
      p.noticeText = null; p.noticeUntilTick = 0;
    }
    this.whispers.clear();
    this.psychopompsPerRoom = this.getPsychopompCount();
    this.ensureLeaders();
  }

  private setIntroPanel(panel: number) {
    const next = Math.max(0, Math.min(INTRO_PANEL_COUNT - 1, panel));
    if (next === this.introPanel) return;
    this.introPanel = next;
    this.phase = next === 0 ? Phase.RosterReveal : Phase.RoleReveal;
    this.introReady.clear();
  }

  private handleIntroInput(pi: number, input: InputState, prevInput: InputState) {
    const forward = pressed(input, prevInput, BUTTON_A) || pressed(input, prevInput, BUTTON_RIGHT);
    const back = pressed(input, prevInput, BUTTON_B) || pressed(input, prevInput, BUTTON_LEFT);
    if (back) {
      this.setIntroPanel(this.introPanel - 1);
      return;
    }
    if (!forward) return;
    if (this.introPanel < INTRO_PANEL_COUNT - 1) {
      this.setIntroPanel(this.introPanel + 1);
    } else {
      this.introReady.add(pi);
    }
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

  getPsychopompCount(): number {
    const roundCfg = this.config.rounds[Math.min(this.currentRound, this.config.rounds.length - 1)];
    return roundCfg?.psychopomps ?? 1;
  }

  beginPsychopompSelect() {
    this.phase = Phase.PsychopompSelect;
    this.psychopompsSelectedA = []; this.psychopompsSelectedB = [];
    this.psychopompCursorA = 0; this.psychopompCursorB = 0;
    this.committedA = false; this.committedB = false;
    this.psychopompSelectTimer = this.phaseTicks(15, 1);
    for (let i = 0; i < this.players.length; i++) {
      const p = this.players[i];
      p.selectedAsPsychopomp = false;
      if (p.isLeader) {
        if (p.inWhisper >= 0) this.leaveWhisper(i);
        if (p.pendingWhisperEntry >= 0) this.cancelEntryRequest(i);
        p.shoutOpen = false;
        p.infoScreen = "none";
      }
    }
  }

  autoFillPsychopomps(room: Room) {
    const list = room === Room.RoomA ? this.psychopompsSelectedA : this.psychopompsSelectedB;
    if (list.length >= this.psychopompsPerRoom) return;
    const eligible = this.eligiblePsychopomps(room).filter((i) => !list.includes(i));
    while (list.length < this.psychopompsPerRoom && eligible.length > 0) {
      const idx = this.randInt(eligible.length);
      const pick = eligible.splice(idx, 1)[0];
      list.push(pick);
      this.players[pick].selectedAsPsychopomp = true;
    }
  }

  beginLeaderSummit() {
    this.phase = Phase.LeaderSummit;
    this.leaderSummitTimer = this.phaseTicks(LEADER_SUMMIT_DURATION_SECS, 1);

    const announceA = prefList(this.psychopompsSelectedA);
    const announceB = prefList(this.psychopompsSelectedB);
    this.shoutMessagesA.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `LEAVING: ${announceA}` });
    this.shoutMessagesB.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `LEAVING: ${announceB}` });
    this.log(`Psychopomps from Underworld: ${this.psychopompsSelectedA.map(i => this.pn(i)).join(", ")}`);
    this.log(`Psychopomps from Mortal Realm: ${this.psychopompsSelectedB.map(i => this.pn(i)).join(", ")}`);

    const id = this.nextWhisperId++;
    const cr: Whisper = {
      id, room: Room.LeaderRoom, ownerIndex: this.leaderA,
      x: 0, y: 0,
      occupants: new Set<number>(),
      pendingEntry: [], pendingEntryTicks: [],
      messages: [], revealOffers: new Set(), colorOffers: new Set(), leaderOffer: -1,
    };

    if (this.leaderA >= 0 && this.leaderA < this.players.length) {
      this.leaderSummitOrigRoomA = this.players[this.leaderA].room;
    }
    if (this.leaderB >= 0 && this.leaderB < this.players.length) {
      this.leaderSummitOrigRoomB = this.players[this.leaderB].room;
    }

    for (const li of [this.leaderA, this.leaderB]) {
      if (li >= 0 && li < this.players.length) {
        const p = this.players[li];
        if (p.inWhisper >= 0) this.leaveWhisper(li);
        if (p.pendingWhisperEntry >= 0) this.cancelEntryRequest(li);
        p.room = Room.LeaderRoom;
        p.inWhisper = id;
        p.whisperEntryTick = this.tickCount;
        p.whisperScrollOffset = 0;
        p.whisperMenuOpen = false; p.whisperMenuCat = 0; p.whisperMenuItem = 0;
        p.shareSelectOpen = false; p.shareSelectRow = 0;
        p.shoutOpen = false;
        p.velX = 0; p.velY = 0; p.carryX = 0; p.carryY = 0;
        cr.occupants.add(li);
      }
    }

    this.whispers.set(id, cr);
    this.leaderSummitWhisperId = id;
    cr.messages.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `LEADER SUMMIT` });
    this.log(`Leader summit began`);
  }

  endLeaderSummit() {
    const cr = this.whispers.get(this.leaderSummitWhisperId);
    if (cr) {
      for (const oi of cr.occupants) {
        const p = this.players[oi];
        p.inWhisper = -1;
        p.whisperScrollOffset = 0;
        p.whisperMenuOpen = false;
        p.shareSelectOpen = false;
      }
      this.whispers.delete(this.leaderSummitWhisperId);
    }
    this.leaderSummitWhisperId = -1;

    if (this.leaderA >= 0 && this.leaderA < this.players.length) {
      this.players[this.leaderA].room = this.leaderSummitOrigRoomA;
    }
    if (this.leaderB >= 0 && this.leaderB < this.players.length) {
      this.players[this.leaderB].room = this.leaderSummitOrigRoomB;
    }

    this.executePsychopompExchange();
  }

  exchangeProgress(): number {
    if (this.exchangeDuration <= 0) return 1;
    return 1 - this.exchangeTimer / this.exchangeDuration;
  }

  executePsychopompExchange() {
    this.ejectAllWhispers();
    for (const p of this.players) { p.shoutOpen = false; }
    this.phase = Phase.PsychopompExchange;

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

    for (const hi of this.psychopompsSelectedA) {
      if (hi >= 0 && hi < this.players.length) {
        this.exchangeFromA.push({ pi: hi, startX: this.players[hi].x, startY: this.players[hi].y });
      }
    }
    for (const hi of this.psychopompsSelectedB) {
      if (hi >= 0 && hi < this.players.length) {
        this.exchangeFromB.push({ pi: hi, startX: this.players[hi].x, startY: this.players[hi].y });
      }
    }

    this.exchangeDuration = this.phaseTicks(8, 1);
    this.exchangeTimer = this.exchangeDuration;
  }

  private resetExchangedPlayer(pi: number) {
    const p = this.players[pi];
    p.usurpVote = -1;
    p.shoutLastRead = 0;
    p.shoutScroll = 0;
  }

  roleHolders(role: Role): number[] {
    const holders: number[] = [];
    for (let i = 0; i < this.players.length; i++) {
      if (this.players[i].role === role) holders.push(i);
    }
    return holders;
  }

  echoRoleForCore(role: Role): Role | null {
    switch (role) {
      case Role.Hades: return Role.EchoOfHades;
      case Role.Persephone: return Role.EchoOfPersephone;
      case Role.Cerberus: return Role.EchoOfCerberus;
      case Role.Demeter: return Role.EchoOfDemeter;
      default: return null;
    }
  }

  coreRoleForEcho(role: Role): Role | null {
    switch (role) {
      case Role.EchoOfHades: return Role.Hades;
      case Role.EchoOfPersephone: return Role.Persephone;
      case Role.EchoOfCerberus: return Role.Cerberus;
      case Role.EchoOfDemeter: return Role.Demeter;
      default: return null;
    }
  }

  effectiveRoleHolders(coreRole: Role): number[] {
    const primary = this.roleHolders(coreRole);
    if (primary.length > 0) return primary;
    const echoRole = this.echoRoleForCore(coreRole);
    return echoRole === null ? [] : this.roleHolders(echoRole);
  }

  activeEchoSubstitutions(): { echoRole: Role; coreRole: Role; holders: number[] }[] {
    const rows: { echoRole: Role; coreRole: Role; holders: number[] }[] = [];
    for (const coreRole of [Role.Hades, Role.Persephone, Role.Cerberus, Role.Demeter]) {
      if (this.roleHolders(coreRole).length > 0) continue;
      const echoRole = this.echoRoleForCore(coreRole);
      if (echoRole === null) continue;
      const holders = this.roleHolders(echoRole);
      if (holders.length > 0) rows.push({ echoRole, coreRole, holders });
    }
    return rows;
  }

  missingCoreRoles(): Role[] {
    return [Role.Hades, Role.Persephone, Role.Cerberus, Role.Demeter]
      .filter(role => this.roleHolders(role).length === 0);
  }

  sharedBetweenAny(left: number[], right: number[]): boolean {
    for (const li of left) {
      for (const ri of right) {
        if (li !== ri && this.players[li].sharedWith.has(ri)) return true;
      }
    }
    return false;
  }

  sameRoomBetweenAny(left: number[], right: number[]): boolean {
    for (const li of left) {
      for (const ri of right) {
        if (li !== ri && this.players[li].room === this.players[ri].room) return true;
      }
    }
    return false;
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
    this.shoutMessagesA.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `ARRIVED: ${prefList(this.exchangeFromB.map(h => h.pi))}` });
    this.shoutMessagesB.push({ type: 'system', senderIndex: -1, tick: this.tickCount, text: `ARRIVED: ${prefList(this.exchangeFromA.map(h => h.pi))}` });
    this.ensureLeaders();
  }

  checkWinCondition() {
    const hades = this.effectiveRoleHolders(Role.Hades);
    const persephone = this.effectiveRoleHolders(Role.Persephone);
    const cerberus = this.effectiveRoleHolders(Role.Cerberus);
    const demeter = this.effectiveRoleHolders(Role.Demeter);

    const sameRoom = this.sameRoomBetweenAny(hades, persephone);
    const hadesSharedWithCerberus = this.sharedBetweenAny(hades, cerberus);
    const persephoneSharedWithDemeter = this.sharedBetweenAny(persephone, demeter);

    if (sameRoom) {
      if (hadesSharedWithCerberus) this.winner = Team.TeamA;
      else if (persephoneSharedWithDemeter) this.winner = Team.TeamB;
      else this.winner = null;
    } else {
      if (persephoneSharedWithDemeter) this.winner = Team.TeamB;
      else if (hadesSharedWithCerberus) this.winner = Team.TeamA;
      else this.winner = null;
    }
    this.log(`--- Game over: ${this.winner === Team.TeamA ? "Shades" : this.winner === Team.TeamB ? "Nymphs" : "no one"} wins ---`);
    this.log(`Hades/Cerberus shared: ${hadesSharedWithCerberus}, Persephone/Demeter shared: ${persephoneSharedWithDemeter}, same room: ${sameRoom}`);
  }

  // ---- Main tick ----

  step(inputs: InputState[], prevInputs: InputState[]) {
    this.tickCount++;
    switch (this.phase) {
      case Phase.Lobby: {
        if (this.players.length >= playerCountFromConfig(this.config)) {
          if (this.lobbyCountdown <= 0) this.lobbyCountdown = this.lobbyWaitTicks();
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
      case Phase.RosterReveal:
      case Phase.RoleReveal: {
        this.revealTimer--;
        let panelChanged = false;
        for (let i = 0; i < this.players.length; i++) {
          if (panelChanged) continue;
          const panelBeforeInput = this.introPanel;
          this.handleIntroInput(i, inputs[i] ?? emptyInput(), prevInputs[i] ?? emptyInput());
          panelChanged = this.introPanel !== panelBeforeInput;
        }
        if (this.revealTimer <= 0 || (this.introPanel === INTRO_PANEL_COUNT - 1 && this.introReady.size >= this.players.length)) {
          this.startRound();
        }
        break;
      }
      case Phase.Playing: {
        this.roundTimer--;
        for (let i = 0; i < this.players.length; i++) {
          this.applyInput(i, inputs[i] ?? emptyInput(), prevInputs[i] ?? emptyInput());
        }
        this.tickWhispers();
        if (this.roundTimer <= 0) this.beginPsychopompSelect();
        break;
      }
      case Phase.PsychopompSelect: {
        this.psychopompSelectTimer--;
        for (let i = 0; i < this.players.length; i++) {
          this.applyInput(i, inputs[i] ?? emptyInput(), prevInputs[i] ?? emptyInput());
        }
        if ((this.committedA && this.committedB) || this.psychopompSelectTimer <= 0) {
          this.autoFillPsychopomps(Room.RoomA);
          this.autoFillPsychopomps(Room.RoomB);
          this.beginLeaderSummit();
        }
        break;
      }
      case Phase.LeaderSummit: {
        this.leaderSummitTimer--;
        for (let i = 0; i < this.players.length; i++) {
          this.applyInput(i, inputs[i] ?? emptyInput(), prevInputs[i] ?? emptyInput());
        }
        this.tickWhispers();
        if (this.leaderSummitTimer <= 0) {
          this.endLeaderSummit();
        }
        break;
      }
      case Phase.PsychopompExchange: {
        this.exchangeTimer--;
        if (this.exchangeTimer <= 0) {
          this.finalizeExchange();
          this.currentRound++;
          if (this.currentRound >= this.config.rounds.length) {
            this.checkWinCondition();
            this.phase = Phase.Reveal;
            this.revealTimer = this.phaseTicks(5, 0.5);
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
          this.gameOverTimer = this.phaseTicks(10, 0.5);
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
    this.psychopompsSelectedA = []; this.psychopompsSelectedB = [];
    this.chatMessages = []; this.obstacles = [];
    this.whispers.clear(); this.nextWhisperId = 0;
    this.shoutMessagesA = []; this.shoutMessagesB = [];
    this.leaderSummitTimer = 0; this.leaderSummitWhisperId = -1;
    this.leaderSummitOrigRoomA = Room.RoomA; this.leaderSummitOrigRoomB = Room.RoomB;
    for (const p of this.players) {
      p.team = Team.TeamA; p.role = Role.Shades;
      p.isLeader = false; p.isPsychopomp = false; p.selectedAsPsychopomp = false;
      p.revealedTo = new Set(); p.sharedWith = new Set(); p.colorRevealedTo = new Set();
      p.whisperMenuOpen = false; p.whisperMenuCat = 0; p.whisperMenuItem = 0;
      p.shareSelectOpen = false; p.shareSelectRow = 0;
      p.infoScreen = "none"; p.usurpVote = -1;
      p.inWhisper = -1; p.whisperEntryTick = 0; p.whisperScrollOffset = 0;
      p.pendingWhisperEntry = -1;
      p.shoutOpen = false; p.shoutLastRead = 0; p.shoutScroll = 0; p.shoutActionRow = 0;
      p.noticeText = null; p.noticeUntilTick = 0;
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
      case Role.Spy: return SPY_ROLE_NAME;
      case Role.EchoOfHades: return ECHO_HADES_ROLE_NAME;
      case Role.EchoOfPersephone: return ECHO_PERSEPHONE_ROLE_NAME;
      case Role.EchoOfCerberus: return ECHO_CERBERUS_ROLE_NAME;
      case Role.EchoOfDemeter: return ECHO_DEMETER_ROLE_NAME;
    }
  }

  roleDefaultTeam(role: Role): Team {
    switch (role) {
      case Role.Persephone:
      case Role.Demeter:
      case Role.Nymphs:
      case Role.EchoOfPersephone:
      case Role.EchoOfDemeter:
        return Team.TeamB;
      default:
        return Team.TeamA;
    }
  }

  teamColor(team: Team): uint8 {
    switch (team) {
      case Team.TeamA: return TEAM_A_COLOR;
      case Team.TeamB: return TEAM_B_COLOR;
    }
  }

  colorRevealTeamColor(pi: number): uint8 {
    const p = this.players[pi];
    if (p.role === Role.Spy) {
      return this.teamColor(p.team === Team.TeamA ? Team.TeamB : Team.TeamA);
    }
    return this.teamColor(p.team);
  }

  roleRevealTeam(pi: number, viewerIndex: number): Team {
    const p = this.players[pi];
    if (p.role === Role.Spy && pi !== viewerIndex && !p.sharedWith.has(viewerIndex)) {
      return p.team === Team.TeamA ? Team.TeamB : Team.TeamA;
    }
    return p.team;
  }

  playerColor(pi: number): uint8 {
    return PLAYER_COLORS[pi % PLAYER_COLORS.length];
  }

  roleIndicator(role: Role, team?: Team): { color: uint8; special: boolean } {
    switch (role) {
      case Role.Hades: return { color: TEAM_A_COLOR, special: true };
      case Role.Persephone: return { color: TEAM_B_COLOR, special: true };
      case Role.Cerberus: return { color: TEAM_A_COLOR, special: true };
      case Role.Demeter: return { color: TEAM_B_COLOR, special: true };
      case Role.Shades: return { color: TEAM_A_COLOR, special: false };
      case Role.Nymphs: return { color: TEAM_B_COLOR, special: false };
      case Role.Spy: return { color: team === Team.TeamB ? TEAM_B_COLOR : TEAM_A_COLOR, special: false };
      case Role.EchoOfHades: return { color: TEAM_A_COLOR, special: true };
      case Role.EchoOfPersephone: return { color: TEAM_B_COLOR, special: true };
      case Role.EchoOfCerberus: return { color: TEAM_A_COLOR, special: true };
      case Role.EchoOfDemeter: return { color: TEAM_B_COLOR, special: true };
    }
  }

  generatePlayerLog(pi: number): string {
    const p = this.players[pi];
    const name = this.pn(pi);
    const lines: string[] = [];

    lines.push(`=== GAME LOG: ${name} ===`);
    lines.push(`Role: ${this.roleName(p.role)} | Team: ${p.team === Team.TeamA ? "Shades" : "Nymphs"}`);
    lines.push(`Result: ${this.winner === null ? "Draw" : this.winner === p.team ? "WIN" : "LOSS"}`);
    lines.push("");

    lines.push("INTERACTIONS:");
    if (p.sharedWith.size > 0) {
      lines.push(`  Shared roles with: ${[...p.sharedWith].map(i => this.pn(i)).join(", ")}`);
    }
    if (p.colorRevealedTo.size > 0) {
      lines.push(`  Exchanged colors with: ${[...p.colorRevealedTo].map(i => this.pn(i)).join(", ")}`);
    }
    if (p.revealedTo.size > 0) {
      const showOnly = [...p.revealedTo].filter(i => !p.sharedWith.has(i));
      if (showOnly.length > 0) {
        lines.push(`  Showed role to: ${showOnly.map(i => this.pn(i)).join(", ")}`);
      }
    }
    if (p.sharedWith.size === 0 && p.colorRevealedTo.size === 0 && p.revealedTo.size === 0) {
      lines.push("  (none)");
    }
    lines.push("");

    lines.push("TIMELINE:");
    for (const entry of this.gameLog) {
      if (entry.event.includes(name)) {
        const secs = (entry.tick / TARGET_FPS).toFixed(1);
        lines.push(`  ${secs}s: ${entry.event}`);
      }
    }
    lines.push("");

    return lines.join("\n");
  }

  generateFullLog(): string {
    const lines: string[] = [];
    lines.push("=== FULL GAME LOG ===");
    lines.push(`Players: ${this.players.length} | Winner: ${this.winner === Team.TeamA ? "Shades" : this.winner === Team.TeamB ? "Nymphs" : "Draw"}`);
    lines.push("");
    for (const entry of this.gameLog) {
      const secs = (entry.tick / TARGET_FPS).toFixed(1);
      lines.push(`${secs}s: ${entry.event}`);
    }
    return lines.join("\n");
  }
}

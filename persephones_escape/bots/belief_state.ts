import { Room } from "../types.js";
import { ROOM_W, ROOM_H, SCREEN_WIDTH, SCREEN_HEIGHT, BUBBLE_RADIUS, TARGET_FPS, TEAM_A_COLOR, TEAM_A_NAME, TEAM_B_NAME, spriteNameFromPaletteColor } from "../constants.js";
import { readPosition, type Point } from "./bot_utils.js";
import {
  parsePhase, parsePlayingHud, parseRoleRevealScreen, scanMinimapPlayers,
  parseChatroomStatus, parseLastShout, scanSpeechBubbles,
  type ParsedPhase, type InfoScreenEntry, type MinimapDot,
} from "./frame_parser.js";

// ---------------------------------------------------------------------------
// Belief state — accumulated knowledge from info screen polling + actions
// ---------------------------------------------------------------------------

export interface PlayerBelief {
  color: number;
  lastRoom: Room | null;
  lastPos: Point | null;
  lastSeenTick: number;
  knownRole: string | null;
  knownTeam: string | null;
  isLeader: boolean;
  inChatroom: boolean;
  weSharedWith: boolean;
  theyRevealedCard: boolean;
  theyRevealedColor: boolean;
}

export interface BeliefState {
  myName: string;
  myRole: string | null;
  myTeam: string | null;
  myRoom: Room | null;
  myPos: Point | null;
  amLeader: boolean;
  phase: ParsedPhase;
  prevPhase: ParsedPhase;
  round: number;
  timerSecs: number;
  players: Map<number, PlayerBelief>;
  minimapDots: MinimapDot[];
  nearbyColors: number[];
  prevNearbyColors: number[];
  chatLog: { tick: number; from: string; text: string }[];
  tick: number;
  lastRoleCheckTick: number;
  lastInfoPollTick: number;
  roomName: string | null;
  roomW: number;
  roomH: number;
  playerCount: number;
  pendingRoleOffer: boolean;
  pendingColorOffer: boolean;
  pendingEntry: boolean;
  prevPendingRoleOffer: boolean;
  /** In chatroom: number of occupants including self, parsed from the top-bar sprites. */
  occupantCount: number;
  /** Colors of other occupants (not self) in the current chatroom. */
  occupantColors: number[];
  /** Last N shouts seen in the overworld strip; each one deduplicated. */
  shoutLog: { tick: number; text: string }[];
  /** Most recently parsed shout text; used to dedupe against shoutLog. */
  lastShoutText: string | null;
}

export function createBeliefState(name: string): BeliefState {
  return {
    myName: name,
    myRole: null,
    myTeam: null,
    myRoom: null,
    myPos: null,
    amLeader: false,
    phase: "unknown",
    prevPhase: "unknown",
    round: 0,
    timerSecs: 0,
    players: new Map(),
    minimapDots: [],
    nearbyColors: [],
    prevNearbyColors: [],
    chatLog: [],
    tick: 0,
    lastRoleCheckTick: -999,
    lastInfoPollTick: -999,
    roomName: null,
    roomW: ROOM_W,
    roomH: ROOM_H,
    playerCount: 0,
    pendingRoleOffer: false,
    pendingColorOffer: false,
    pendingEntry: false,
    prevPendingRoleOffer: false,
    occupantCount: 0,
    occupantColors: [],
    shoutLog: [],
    lastShoutText: null,
  };
}

export function updatePhase(state: BeliefState, frame: Uint8Array): void {
  state.tick++;
  state.prevPhase = state.phase;
  state.phase = parsePhase(frame);

  if (state.phase === "role_reveal" && state.myRole === null) {
    const info = parseRoleRevealScreen(frame);
    if (info) {
      state.myRole = info.role;
      state.myTeam = info.team;
      state.roomName = info.room;
      state.myRoom = info.room.toUpperCase().includes("UNDERWORLD") ? Room.RoomA : Room.RoomB;
      if (info.roomSize > 0) {
        state.roomW = info.roomSize;
        state.roomH = info.roomSize;
      }
      if (info.playerCount > 0) {
        state.playerCount = info.playerCount;
      }
    }
  }

  if (state.phase === "info_screen" && state.myRole === null) {
    const info = parseRoleRevealScreen(frame);
    if (info) {
      state.myRole = info.role;
      state.myTeam = info.team;
    }
  }

  state.prevPendingRoleOffer = state.pendingRoleOffer;
  if (state.phase === "chatroom") {
    const status = parseChatroomStatus(frame);
    state.pendingRoleOffer = status.pendingRoleOffer;
    state.pendingColorOffer = status.pendingColorOffer;
    state.pendingEntry = status.pendingEntry;
    state.occupantCount = status.occupantCount;
    // Self sprite is the first occupant slot in the top bar. Others are the rest.
    state.occupantColors = status.occupantColors.slice(1);
  } else {
    state.pendingRoleOffer = false;
    state.pendingColorOffer = false;
    state.pendingEntry = false;
    state.occupantCount = 0;
    state.occupantColors = [];
  }

  // Parse the last-shout strip. Only log when the text changes.
  if (state.phase === "playing") {
    const shout = parseLastShout(frame);
    if (shout && shout !== state.lastShoutText) {
      state.shoutLog.push({ tick: state.tick, text: shout });
      if (state.shoutLog.length > 20) state.shoutLog.shift();
      state.lastShoutText = shout;
    }
  }
}

export function updateMinimap(state: BeliefState, frame: Uint8Array): void {
  if (state.phase !== "playing" && state.phase !== "hostage_select") return;
  if (state.myRoom === null) return;
  state.minimapDots = scanMinimapPlayers(frame, state.myRoom, state.roomW, state.roomH);
  const nearby: number[] = [];
  for (const dot of state.minimapDots) {
    if (dot.isSelf) continue;
    let belief = state.players.get(dot.color);
    if (!belief) {
      belief = {
        color: dot.color, lastRoom: state.myRoom, lastPos: null,
        lastSeenTick: state.tick, knownRole: null, knownTeam: null,
        isLeader: false, inChatroom: false, weSharedWith: false,
        theyRevealedCard: false, theyRevealedColor: false,
      };
      state.players.set(dot.color, belief);
    }
    belief.lastRoom = state.myRoom;
    belief.lastPos = { x: dot.worldX, y: dot.worldY };
    belief.lastSeenTick = state.tick;
    if (state.myPos) {
      const dx = dot.worldX - state.myPos.x;
      const dy = dot.worldY - state.myPos.y;
      // Minimap cell resolution is ~roomSize/20 ≈ 5 world units, so loosen by 1 cell
      if (Math.sqrt(dx * dx + dy * dy) <= BUBBLE_RADIUS + 5) {
        nearby.push(dot.color);
      }
    }
  }
  state.prevNearbyColors = state.nearbyColors;
  state.nearbyColors = nearby;

  // Reset inChatroom for all known players, then detect from speech bubbles
  for (const b of state.players.values()) b.inChatroom = false;
  const bubbles = scanSpeechBubbles(frame);
  for (const bub of bubbles) {
    // Read the player's fill color from center of the 7x7 sprite
    const cx = bub.screenX + 3;
    const cy = bub.screenY + 3;
    if (cx >= 0 && cx < SCREEN_WIDTH && cy >= 0 && cy < SCREEN_HEIGHT) {
      const c = frame[cy * SCREEN_WIDTH + cx];
      if (c !== 0 && c !== 1) {
        const b = state.players.get(c);
        if (b) b.inChatroom = true;
      }
    }
  }
}

export function updatePosition(state: BeliefState, frame: Uint8Array): void {
  if (state.phase !== "playing" && state.phase !== "hostage_select") return;
  const pos = readPosition(frame, state.roomW, state.roomH);
  if (pos) {
    state.myPos = { x: pos.x, y: pos.y };
    state.myRoom = pos.room;
  }
}

export function updateHud(state: BeliefState, frame: Uint8Array): void {
  if (state.phase !== "playing" && state.phase !== "hostage_select") return;
  const hud = parsePlayingHud(frame);
  if (hud) {
    state.round = hud.round;
    state.timerSecs = hud.timerSecs;
    if (hud.roleName && state.myRole === null) {
      state.myRole = hud.roleName;
    }
  }
}

export function updateFromInfoScreen(state: BeliefState, entries: InfoScreenEntry[]): boolean {
  let newInfo = false;
  state.lastInfoPollTick = state.tick;

  for (const entry of entries) {
    if (entry.isSelf) {
      if (entry.teamColor !== null && state.myTeam === null) {
        state.myTeam = entry.teamColor === TEAM_A_COLOR ? TEAM_A_NAME : TEAM_B_NAME;
      }
      continue;
    }

    let belief = state.players.get(entry.playerColor);
    if (!belief) {
      belief = {
        color: entry.playerColor,
        lastRoom: null,
        lastPos: null,
        lastSeenTick: state.tick,
        knownRole: null,
        knownTeam: null,
        isLeader: false,
        inChatroom: false,
        weSharedWith: false,
        theyRevealedCard: false,
        theyRevealedColor: false,
      };
      state.players.set(entry.playerColor, belief);
      newInfo = true;
    }

    belief.lastSeenTick = state.tick;

    if (entry.roleName && !belief.knownRole) {
      belief.knownRole = entry.roleName;
      belief.theyRevealedCard = true;
      newInfo = true;
    }
    if (entry.teamColor !== null && !belief.knownTeam) {
      belief.knownTeam = entry.teamColor === TEAM_A_COLOR ? TEAM_A_NAME : TEAM_B_NAME;
      belief.theyRevealedColor = true;
      newInfo = true;
    }
    if (entry.colorOnlyReveal && !belief.theyRevealedColor) {
      belief.theyRevealedColor = true;
      newInfo = true;
    }
  }

  return newInfo;
}

// ---------------------------------------------------------------------------
// Trigger events — detect decision points for the LLM
// ---------------------------------------------------------------------------

export type TriggerEvent =
  | "game_start" | "round_start" | "info_updated"
  | "hostage_phase" | "idle" | "role_learned" | "periodic"
  | "player_nearby" | "player_left"
  | "role_offer_pending"
  | "shout_received";

export function checkTriggers(
  state: BeliefState,
  lastPromptTick: number,
  hasActiveGoal: boolean,
): TriggerEvent | null {
  const cooldown = TARGET_FPS * 2;

  if (state.phase === "playing" && state.prevPhase !== "playing") {
    if (state.prevPhase === "role_reveal" || state.prevPhase === "lobby") return "game_start";
    return "round_start";
  }

  if (state.phase === "playing" && state.prevPhase === "hostage_exchange") {
    return "round_start";
  }

  if (state.phase === "hostage_select" && state.prevPhase !== "hostage_select") {
    return "hostage_phase";
  }

  if (state.myRole !== null && state.lastRoleCheckTick < 0) {
    state.lastRoleCheckTick = state.tick;
    return "role_learned";
  }

  // Fire immediately when a role offer appears (no cooldown — this is a win-path trigger).
  if (state.pendingRoleOffer && !state.prevPendingRoleOffer) {
    return "role_offer_pending";
  }

  // Fire when a new shout arrives (most recent entry added this tick).
  const latestShout = state.shoutLog[state.shoutLog.length - 1];
  if (latestShout && latestShout.tick === state.tick) {
    return "shout_received";
  }

  if (state.tick - lastPromptTick < cooldown) return null;

  if (state.nearbyColors.length > 0 && state.prevNearbyColors.length === 0) {
    return "player_nearby";
  }
  if (state.nearbyColors.length === 0 && state.prevNearbyColors.length > 0) {
    return "player_left";
  }

  if (!hasActiveGoal && state.tick - lastPromptTick > TARGET_FPS * 3) {
    return "idle";
  }

  if (state.phase === "playing" && state.tick - lastPromptTick > TARGET_FPS * 5) {
    return "periodic";
  }

  return null;
}

// ---------------------------------------------------------------------------
// Context dump — structured text for the LLM
// ---------------------------------------------------------------------------

export function formatContextDump(state: BeliefState, event: TriggerEvent): string {
  const lines: string[] = [];

  lines.push(`EVENT: ${event}`);
  lines.push(`TICK: ${state.tick} | ROUND: ${state.round}/3 | TIME: ~${state.timerSecs}s | PHASE: ${state.phase} | ROOM: ${state.roomW}x${state.roomH}`);
  lines.push("");

  lines.push("MY STATE:");
  lines.push(`  Role: ${state.myRole ?? "UNKNOWN"} | Team: ${state.myTeam ?? "UNKNOWN"} | Room: ${state.roomName ?? roomStr(state.myRoom)}`);
  if (state.myPos) {
    lines.push(`  Position: (${state.myPos.x}, ${state.myPos.y}) | Leader: ${state.amLeader ? "yes" : "no"}`);
  }
  if (state.phase === "chatroom") {
    lines.push(`  IN CHATROOM. pending_role_offer=${state.pendingRoleOffer} pending_color_offer=${state.pendingColorOffer} pending_entry=${state.pendingEntry}`);
    if (state.pendingEntry) {
      lines.push(`  >>> Another player wants to enter your chatroom. Use "grant_entry" to let them in, or ignore to keep them out.`);
    }
    if (state.pendingRoleOffer) {
      lines.push(`  >>> Another occupant has offered a MUTUAL ROLE EXCHANGE. If you accept and they turn out to be your key partner, your team WINS. If they're an enemy you leak your role. Only the two keys (Hades+Cerberus for Shades, Persephone+Demeter for Nymphs) trigger the win.`);
    } else if (state.pendingColorOffer) {
      lines.push(`  >>> Another occupant has offered a COLOR EXCHANGE. color_accept reveals teams to each other (safe, no role info).`);
    }
  } else if (state.phase === "waiting_entry") {
    lines.push(`  WAITING TO ENTER ANOTHER PLAYER'S CHATROOM. Just "wait" — the owner must grant_entry. Do not press action buttons or you'll cancel your request.`);
  }
  lines.push("");

  if (state.nearbyColors.length > 0) {
    lines.push(`NEARBY PLAYERS (in chatroom range — press open_chatroom to interact):`);
    for (const c of state.nearbyColors) {
      const b = state.players.get(c);
      lines.push(`  ${b ? playerDesc(b) : spriteNameFromPaletteColor(c)}`);
    }
    lines.push("");
  }

  const otherDots = state.minimapDots.filter(d => !d.isSelf);
  if (otherDots.length > 0) {
    lines.push("OTHERS IN ROOM (from minimap):");
    lines.push("  " + otherDots.map(d => `${spriteNameFromPaletteColor(d.color)} ~(${d.worldX},${d.worldY})`).join(" | "));
    lines.push("");
  }

  if (state.shoutLog.length > 0) {
    lines.push("RECENT SHOUTS (global room chat):");
    for (const s of state.shoutLog.slice(-8)) {
      lines.push(`  tick=${s.tick}: "${s.text}"`);
    }
    lines.push("");
  }

  const knownPlayers = [...state.players.values()];
  if (knownPlayers.length > 0) {
    const staleness = state.tick - state.lastInfoPollTick;
    lines.push(`KNOWN PLAYERS (polled ${staleness} ticks ago):`);
    for (const b of knownPlayers) {
      lines.push(`  ${playerDesc(b)}`);
    }
    lines.push("");
  }

  const recentChat = state.chatLog.slice(-5);
  if (recentChat.length > 0) {
    lines.push("RECENT CHAT:");
    for (const m of recentChat) {
      lines.push(`  ${m.from}: ${m.text}`);
    }
    lines.push("");
  }

  lines.push("STRATEGIC CONTEXT:");
  lines.push(buildStrategicContext(state));
  lines.push("");

  lines.push("COMMANDS:");
  lines.push("  Movement: move_to <x> <y>, approach_nearest, wander, wait");
  lines.push("  Chatroom: open_chatroom, color_offer, color_accept, show_role, role_offer, role_accept, exit_chatroom, chat <msg>");
  lines.push("  Leadership: leader_pass, leader_take, grant_entry");
  lines.push("  Menu: info_shared, start_chat, shout <msg>");
  lines.push("  Hostage: select_hostages <indices>, commit_hostages");

  return lines.join("\n");
}

function roomStr(room: Room | null): string {
  if (room === Room.RoomA) return "Underworld";
  if (room === Room.RoomB) return "Mortal Realm";
  return "UNKNOWN";
}

function playerDesc(b: PlayerBelief): string {
  const parts = [spriteNameFromPaletteColor(b.color)];
  if (b.lastPos) parts.push(`~(${b.lastPos.x},${b.lastPos.y})`);
  if (b.knownRole) parts.push(`role: ${b.knownRole}`);
  else if (b.knownTeam) parts.push(`team: ${b.knownTeam}`);
  if (b.inChatroom) parts.push("IN CHATROOM");
  if (b.weSharedWith) parts.push("MUTUAL SHARE");
  return parts.join(", ");
}

function buildStrategicContext(state: BeliefState): string {
  if (!state.myRole || !state.myTeam) {
    return "  Role unknown yet — it is shown at game start.";
  }

  const role = state.myRole.toUpperCase();
  const lines: string[] = [];

  if (role === "HADES") {
    lines.push("  Win: I (Hades) must mutually share cards with Cerberus.");
    const cerb = findKnownByRole(state, "Cerberus");
    lines.push(cerb ? `  Cerberus: FOUND ${spriteNameFromPaletteColor(cerb.color)}, shared: ${cerb.weSharedWith}` : "  Cerberus: NOT FOUND.");
  } else if (role === "CERBERUS") {
    lines.push("  Win: Hades must mutually share cards with me (Cerberus).");
    const hades = findKnownByRole(state, "Hades");
    lines.push(hades ? `  Hades: FOUND ${spriteNameFromPaletteColor(hades.color)}, shared: ${hades.weSharedWith}` : "  Hades: NOT FOUND.");
  } else if (role === "PERSEPHONE") {
    lines.push("  Win: I (Persephone) must mutually share cards with Demeter.");
    const dem = findKnownByRole(state, "Demeter");
    lines.push(dem ? `  Demeter: FOUND ${spriteNameFromPaletteColor(dem.color)}, shared: ${dem.weSharedWith}` : "  Demeter: NOT FOUND.");
  } else if (role === "DEMETER") {
    lines.push("  Win: Persephone must mutually share cards with me (Demeter).");
    const pers = findKnownByRole(state, "Persephone");
    lines.push(pers ? `  Persephone: FOUND ${spriteNameFromPaletteColor(pers.color)}, shared: ${pers.weSharedWith}` : "  Persephone: NOT FOUND.");
  } else {
    lines.push(`  Win: Help my team (${state.myTeam}) by finding and assisting key roles.`);
  }

  return lines.join("\n");
}

function findKnownByRole(state: BeliefState, role: string): PlayerBelief | null {
  for (const b of state.players.values()) {
    if (b.knownRole?.toUpperCase() === role.toUpperCase()) return b;
  }
  return null;
}

import { Room } from "./types.js";
import { ROOM_W, ROOM_H, MINIMAP_SIZE, BUBBLE_RADIUS, TARGET_FPS } from "./constants.js";
import { readPosition, type Point } from "./bot_utils.js";
import {
  parsePhase, parsePlayingHud, parseRoleRevealScreen, scanMinimapPlayers,
  type ParsedPhase, type MinimapDot,
} from "./frame_parser.js";

// ---------------------------------------------------------------------------
// Belief state — accumulated knowledge from frame parsing + own actions
// ---------------------------------------------------------------------------

export interface PlayerBelief {
  color: number;
  lastRoom: Room | null;
  lastPos: Point | null;
  lastSeenTick: number;
  knownRole: string | null;
  knownTeam: string | null;
  isLeader: boolean;
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
  nearbyColors: number[];
  prevNearbyColors: number[];
  minimapDots: MinimapDot[];
  chatLog: { tick: number; from: string; text: string }[];
  actionLog: { tick: number; action: string }[];
  tick: number;
  lastRoleCheckTick: number;
  roomName: string | null;
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
    nearbyColors: [],
    prevNearbyColors: [],
    minimapDots: [],
    chatLog: [],
    actionLog: [],
    tick: 0,
    lastRoleCheckTick: -999,
    roomName: null,
  };
}

export function updateFromFrame(state: BeliefState, frame: Uint8Array): void {
  state.tick++;
  state.prevPhase = state.phase;
  state.prevNearbyColors = [...state.nearbyColors];

  state.phase = parsePhase(frame);

  if (state.phase === "role_reveal" && state.myRole === null) {
    const info = parseRoleRevealScreen(frame);
    if (info) {
      state.myRole = info.role;
      state.myTeam = info.team;
      state.roomName = info.room;
      state.myRoom = info.room.toUpperCase().includes("UNDERWORLD") ? Room.RoomA : Room.RoomB;
    }
  }

  if (state.phase === "info_screen" && state.myRole === null) {
    const info = parseRoleRevealScreen(frame);
    if (info) {
      state.myRole = info.role;
      state.myTeam = info.team;
    }
  }

  if (state.phase === "playing" || state.phase === "hostage_select") {
    const pos = readPosition(frame);
    if (pos) {
      state.myPos = { x: pos.x, y: pos.y };
      state.myRoom = pos.room;
    }

    const hud = parsePlayingHud(frame);
    if (hud) {
      state.round = hud.round;
      state.timerSecs = hud.timerSecs;
      if (hud.roleName && state.myRole === null) {
        state.myRole = hud.roleName;
      }
    }

    if (state.myRoom !== null) {
      state.minimapDots = scanMinimapPlayers(frame, state.myRoom);
      updatePlayerBeliefs(state);
    }
  }
}

function updatePlayerBeliefs(state: BeliefState): void {
  const nearby: number[] = [];

  for (const dot of state.minimapDots) {
    if (dot.isSelf) continue;
    let belief = state.players.get(dot.color);
    if (!belief) {
      belief = {
        color: dot.color,
        lastRoom: state.myRoom,
        lastPos: null,
        lastSeenTick: state.tick,
        knownRole: null,
        knownTeam: null,
        isLeader: false,
        weSharedWith: false,
        theyRevealedCard: false,
        theyRevealedColor: false,
      };
      state.players.set(dot.color, belief);
    }
    belief.lastRoom = state.myRoom;
    belief.lastPos = { x: dot.worldX, y: dot.worldY };
    belief.lastSeenTick = state.tick;

    if (state.myPos) {
      const dx = dot.worldX - state.myPos.x;
      const dy = dot.worldY - state.myPos.y;
      if (Math.sqrt(dx * dx + dy * dy) <= BUBBLE_RADIUS * 2) {
        nearby.push(dot.color);
      }
    }
  }

  state.nearbyColors = nearby;
}

export function updateFromCommand(state: BeliefState, command: string): void {
  state.actionLog.push({ tick: state.tick, action: command });
  if (state.actionLog.length > 50) state.actionLog.shift();
}

// ---------------------------------------------------------------------------
// Trigger events — detect decision points for the LLM
// ---------------------------------------------------------------------------

export type TriggerEvent =
  | "game_start" | "round_start" | "player_nearby" | "player_left"
  | "hostage_phase" | "room_changed" | "idle" | "role_learned";

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

  return null;
}

// ---------------------------------------------------------------------------
// Context dump — structured text for the LLM
// ---------------------------------------------------------------------------

export function formatContextDump(state: BeliefState, event: TriggerEvent): string {
  const lines: string[] = [];

  lines.push(`EVENT: ${event}`);
  lines.push(`TICK: ${state.tick} | ROUND: ${state.round}/3 | TIME: ~${state.timerSecs}s | PHASE: ${state.phase}`);
  lines.push("");

  lines.push("MY STATE:");
  lines.push(`  Role: ${state.myRole ?? "UNKNOWN"} | Team: ${state.myTeam ?? "UNKNOWN"} | Room: ${state.roomName ?? roomStr(state.myRoom)}`);
  if (state.myPos) {
    lines.push(`  Position: (${state.myPos.x}, ${state.myPos.y}) | Leader: ${state.amLeader ? "yes" : "no"}`);
  }
  lines.push("");

  const nearbyBeliefs = state.nearbyColors
    .map(c => state.players.get(c))
    .filter((b): b is PlayerBelief => b !== null && b !== undefined);

  if (nearbyBeliefs.length > 0) {
    lines.push("NEARBY PLAYERS (interaction range):");
    for (const b of nearbyBeliefs) {
      lines.push(`  ${playerDesc(b)}`);
    }
    lines.push("");
  }

  if (state.minimapDots.length > 1) {
    const others = state.minimapDots.filter(d => !d.isSelf);
    if (others.length > 0) {
      lines.push("ROOM PLAYERS (minimap):");
      const descs = others.map(d => `[color=${d.color}] ~(${d.worldX},${d.worldY})`);
      lines.push("  " + descs.join(" | "));
      lines.push("");
    }
  }

  const knownPlayers = [...state.players.values()].filter(
    b => b.knownRole || b.knownTeam || b.weSharedWith
  );
  if (knownPlayers.length > 0) {
    lines.push("KNOWN PLAYERS:");
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

  const recentActions = state.actionLog.slice(-5);
  if (recentActions.length > 0) {
    lines.push("MY RECENT ACTIONS:");
    lines.push("  " + recentActions.map(a => a.action).join(" | "));
    lines.push("");
  }

  lines.push("STRATEGIC CONTEXT:");
  lines.push(buildStrategicContext(state));
  lines.push("");

  lines.push("COMMANDS:");
  lines.push("  Movement: move_to <x> <y>, approach_nearest, wander, wait");
  lines.push("  Chatroom: open_chatroom, reveal, show_color, accept_reveal, exit_chatroom, chat <msg>");
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
  const parts = [`[color=${b.color}]`];
  if (b.lastPos) parts.push(`~(${b.lastPos.x},${b.lastPos.y})`);
  if (b.knownRole) parts.push(`role: ${b.knownRole}`);
  else if (b.knownTeam) parts.push(`team: ${b.knownTeam}`);
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
    lines.push(cerb ? `  Cerberus: FOUND [color=${cerb.color}], shared: ${cerb.weSharedWith}` : "  Cerberus: NOT FOUND.");
  } else if (role === "CERBERUS") {
    lines.push("  Win: Hades must mutually share cards with me (Cerberus).");
    const hades = findKnownByRole(state, "Hades");
    lines.push(hades ? `  Hades: FOUND [color=${hades.color}], shared: ${hades.weSharedWith}` : "  Hades: NOT FOUND.");
  } else if (role === "PERSEPHONE") {
    lines.push("  Win: I (Persephone) must mutually share cards with Demeter.");
    const dem = findKnownByRole(state, "Demeter");
    lines.push(dem ? `  Demeter: FOUND [color=${dem.color}], shared: ${dem.weSharedWith}` : "  Demeter: NOT FOUND.");
  } else if (role === "DEMETER") {
    lines.push("  Win: Persephone must mutually share cards with me (Demeter).");
    const pers = findKnownByRole(state, "Persephone");
    lines.push(pers ? `  Persephone: FOUND [color=${pers.color}], shared: ${pers.weSharedWith}` : "  Persephone: NOT FOUND.");
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

import { Room } from "../game/types.js";
import { ROOM_W, ROOM_H, SCREEN_WIDTH, SCREEN_HEIGHT, BUBBLE_RADIUS, TARGET_FPS, TEAM_A_COLOR, TEAM_A_NAME, TEAM_B_NAME, characterName, spriteNameFromPaletteColor, COLOR_LETTERS, SHAPE_NAMES, paletteColorFromLetter } from "../game/constants.js";
import { PlayerShape } from "../game/types.js";
import { readPosition, type Point } from "./bot_utils.js";
import {
  parsePhase, parsePlayingHud, parseRoleRevealScreen, scanMinimapPlayers,
  parseWhisperStatus, parseLastShout, scanSpeechBubbles,
  parseWhisperMessages, parseShoutMessages,
  type ParsedPhase, type InfoScreenEntry, type MinimapDot, type ParsedChatLine,
} from "./frame_parser.js";

// ---------------------------------------------------------------------------
// Belief state — accumulated knowledge from info screen polling + actions
// ---------------------------------------------------------------------------

export interface PlayerBelief {
  name: string;
  color: number;
  shape: PlayerShape | null;
  lastRoom: Room | null;
  lastPos: Point | null;
  lastSeenTick: number;
  knownRole: string | null;
  knownTeam: string | null;
  isLeader: boolean;
  inWhisper: boolean;
  weSharedWith: boolean;
  theyRevealedCard: boolean;
  theyRevealedColor: boolean;
}

export interface BeliefState {
  myName: string;
  myColor: number | null;
  myShape: PlayerShape | null;
  myCharName: string | null;
  myRole: string | null;
  myTeam: string | null;
  myRoom: Room | null;
  myPos: Point | null;
  amLeader: boolean;
  phase: ParsedPhase;
  prevPhase: ParsedPhase;
  round: number;
  timerSecs: number;
  /** Keyed by character name (e.g. "R CRCL"). */
  players: Map<string, PlayerBelief>;
  minimapDots: MinimapDot[];
  nearbyNames: string[];
  prevNearbyNames: string[];
  chatLog: ParsedChatLine[];
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
  /** In whisper: number of occupants including self, parsed from the top-bar sprites. */
  occupantCount: number;
  /** Character names of other occupants (not self) in the current whisper. */
  occupantNames: string[];
  /** Last N shouts seen in the overworld strip; each one deduplicated. */
  shoutLog: { tick: number; text: string; senderColor: number }[];
  /** Most recently parsed shout text; used to dedupe against shoutLog. */
  lastShoutText: string | null;
  /** Whisper messages from last frame parse (replaced each frame). */
  whisperMessages: ParsedChatLine[];
  /** Hash of last whisper message snapshot for deduplication. */
  lastWhisperMsgHash: string;
  /** Shout messages from last frame parse. */
  shoutMessages: ParsedChatLine[];
  /** Hash of last global message snapshot for deduplication. */
  lastShoutMsgHash: string;
  /** True once role/team/color/shape are captured from the reveal screen — never overwrite them. */
  revealLocked: boolean;
  /** Whether we were the starting leader this round (set on first HUD parse). */
  wasStartingLeader: boolean;
  /** Round number when wasStartingLeader was last set. */
  startingLeaderRound: number;
}

export function createBeliefState(name: string): BeliefState {
  return {
    myName: name,
    myColor: null,
    myShape: null,
    myCharName: null,
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
    nearbyNames: [],
    prevNearbyNames: [],
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
    occupantNames: [],
    shoutLog: [],
    lastShoutText: null,
    whisperMessages: [],
    lastWhisperMsgHash: "",
    shoutMessages: [],
    lastShoutMsgHash: "",
    revealLocked: false,
    wasStartingLeader: false,
    startingLeaderRound: -1,
  };
}

function trySetMyCharName(state: BeliefState) {
  if (state.myCharName !== null) return;
  if (state.myColor !== null && state.myShape !== null) {
    state.myCharName = characterName(state.myColor, state.myShape);
  }
}

/** Look up a belief by palette color. Returns the first match (ambiguous if colors collide). */
function beliefByColor(state: BeliefState, color: number): PlayerBelief | undefined {
  for (const b of state.players.values()) {
    if (b.color === color) return b;
  }
  return undefined;
}

/** Get or create a belief for a player identified by color+shape. */
function getOrCreateBelief(state: BeliefState, color: number, shape: PlayerShape | null): PlayerBelief {
  const name = shape !== null ? characterName(color, shape) : spriteNameFromPaletteColor(color);
  let belief = state.players.get(name);
  if (belief) {
    if (shape !== null && belief.shape === null) {
      belief.shape = shape;
      // Migrate from color-only name to full character name
      if (belief.name !== name) {
        state.players.delete(belief.name);
        belief.name = name;
        state.players.set(name, belief);
      }
    }
    return belief;
  }
  // Check if there's an existing color-only entry that can be upgraded
  if (shape !== null) {
    const colorName = spriteNameFromPaletteColor(color);
    const existing = state.players.get(colorName);
    if (existing && existing.color === color && existing.shape === null) {
      existing.shape = shape;
      existing.name = name;
      state.players.delete(colorName);
      state.players.set(name, existing);
      return existing;
    }
  }
  belief = {
    name, color, shape,
    lastRoom: null, lastPos: null, lastSeenTick: state.tick,
    knownRole: null, knownTeam: null,
    isLeader: false, inWhisper: false, weSharedWith: false,
    theyRevealedCard: false, theyRevealedColor: false,
  };
  state.players.set(name, belief);
  return belief;
}

export function updatePhase(state: BeliefState, frame: Uint8Array): void {
  state.tick++;
  state.prevPhase = state.phase;
  state.phase = parsePhase(frame);

  if (state.phase === "role_reveal" && !state.revealLocked) {
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
      if (info.spriteColor !== null) {
        state.myColor = info.spriteColor;
      }
      if (info.spriteShape !== null) {
        state.myShape = info.spriteShape;
      }
      trySetMyCharName(state);
      if (state.myRole && state.myTeam && state.myColor !== null) {
        state.revealLocked = true;
      }
    }
  }

  state.prevPendingRoleOffer = state.pendingRoleOffer;
  if (state.phase === "whisper" || state.phase === "leader_summit") {
    const status = parseWhisperStatus(frame);
    state.pendingRoleOffer = status.pendingRoleOffer;
    state.pendingColorOffer = status.pendingColorOffer;
    state.pendingEntry = status.pendingEntry;
    state.occupantCount = status.occupantCount;
    // First occupant is self
    if (status.occupants.length > 0 && !state.revealLocked) {
      const self = status.occupants[0];
      if (state.myColor === null) state.myColor = self.color;
      if (state.myShape === null && self.shape !== null) state.myShape = self.shape;
      trySetMyCharName(state);
    }
    state.occupantNames = [];
    for (let i = 1; i < status.occupants.length; i++) {
      const o = status.occupants[i];
      const b = getOrCreateBelief(state, o.color, o.shape);
      state.occupantNames.push(b.name);
    }
  } else {
    state.pendingRoleOffer = false;
    state.pendingColorOffer = false;
    state.pendingEntry = false;
    state.occupantCount = 0;
    state.occupantNames = [];
  }

  // Parse the last-shout strip. Only log when the text changes.
  if (state.phase === "playing" || state.phase === "leader_summit") {
    const shout = parseLastShout(frame);
    if (shout && shout.text !== state.lastShoutText) {
      state.shoutLog.push({ tick: state.tick, text: shout.text, senderColor: shout.senderColor });
      if (state.shoutLog.length > 20) state.shoutLog.shift();
      state.lastShoutText = shout.text;
    }
  }

  if (state.phase === "whisper" || state.phase === "leader_summit") {
    const msgs = parseWhisperMessages(frame);
    const hash = msgs.map(m => `${m.senderColor}:${m.text}`).join("|");
    if (hash !== state.lastWhisperMsgHash) {
      state.whisperMessages = msgs;
      state.lastWhisperMsgHash = hash;
      for (const m of msgs) {
        if (m.type !== "text") continue;
        if (m.senderShape !== null && m.senderColor !== 0) {
          getOrCreateBelief(state, m.senderColor, m.senderShape);
        }
        const exists = state.chatLog.some(
          prev => prev.senderColor === m.senderColor && prev.text === m.text
        );
        if (!exists) state.chatLog.push(m);
      }
      if (state.chatLog.length > 30) state.chatLog.splice(0, state.chatLog.length - 30);
    }
  } else {
    state.whisperMessages = [];
    state.lastWhisperMsgHash = "";
  }
}

export function updateMinimap(state: BeliefState, frame: Uint8Array): void {
  if (state.phase !== "playing" && state.phase !== "hostage_select" && state.phase !== "leader_summit") return;
  if (state.myRoom === null) return;
  state.minimapDots = scanMinimapPlayers(frame, state.myRoom, state.roomW, state.roomH);
  const nearby: string[] = [];
  for (const dot of state.minimapDots) {
    if (dot.isSelf) continue;
    // Minimap only gives color — find the best matching belief
    const belief = getOrCreateBelief(state, dot.color, null);
    belief.lastRoom = state.myRoom;
    belief.lastPos = { x: dot.worldX, y: dot.worldY };
    belief.lastSeenTick = state.tick;
    if (state.myPos) {
      const dx = dot.worldX - state.myPos.x;
      const dy = dot.worldY - state.myPos.y;
      if (Math.sqrt(dx * dx + dy * dy) <= BUBBLE_RADIUS + 5) {
        nearby.push(belief.name);
      }
    }
  }
  state.prevNearbyNames = state.nearbyNames;
  state.nearbyNames = nearby;

  // Reset inWhisper for all known players, then detect from speech bubbles
  for (const b of state.players.values()) b.inWhisper = false;
  const bubbles = scanSpeechBubbles(frame);
  for (const bub of bubbles) {
    const cx = bub.screenX + 3;
    const cy = bub.screenY + 3;
    if (cx >= 0 && cx < SCREEN_WIDTH && cy >= 0 && cy < SCREEN_HEIGHT) {
      const c = frame[cy * SCREEN_WIDTH + cx];
      if (c !== 0 && c !== 1) {
        const b = beliefByColor(state, c);
        if (b) b.inWhisper = true;
      }
    }
  }
}

export function updatePosition(state: BeliefState, frame: Uint8Array): void {
  if (state.phase !== "playing" && state.phase !== "hostage_select" && state.phase !== "leader_summit") return;
  const pos = readPosition(frame, state.roomW, state.roomH);
  if (pos) {
    state.myPos = { x: pos.x, y: pos.y };
    state.myRoom = pos.room;
  }
}

export function updateHud(state: BeliefState, frame: Uint8Array): void {
  if (state.phase !== "playing" && state.phase !== "hostage_select" && state.phase !== "leader_summit") return;
  const hud = parsePlayingHud(frame);
  if (hud) {
    state.round = hud.round;
    state.timerSecs = hud.timerSecs;
    state.amLeader = hud.isLeader;
    if (hud.round !== state.startingLeaderRound) {
      state.wasStartingLeader = hud.isLeader;
      state.startingLeaderRound = hud.round;
    }
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
      if (!state.revealLocked) {
        if (entry.teamColor !== null && state.myTeam === null) {
          state.myTeam = entry.teamColor === TEAM_A_COLOR ? TEAM_A_NAME : TEAM_B_NAME;
        }
        if (entry.playerColor !== 0 && state.myColor === null) {
          state.myColor = entry.playerColor;
        }
        if (entry.playerShape !== null && state.myShape === null) {
          state.myShape = entry.playerShape;
        }
        trySetMyCharName(state);
      }
      continue;
    }

    const belief = getOrCreateBelief(state, entry.playerColor, entry.playerShape);
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
  | "hostage_phase" | "leader_summit" | "idle" | "role_learned" | "periodic"
  | "player_nearby" | "player_left"
  | "role_offer_pending"
  | "shout_received"
  | "whisper_entered" | "whisper_left"
  | "whisper_requested_entry";

export function checkTriggers(
  state: BeliefState,
  lastPromptTick: number,
  hasActiveGoal: boolean,
): TriggerEvent | null {
  const cooldown = TARGET_FPS * 8;

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

  if (state.phase === "leader_summit" && state.prevPhase !== "leader_summit") {
    return "leader_summit";
  }

  if (state.myRole !== null && state.lastRoleCheckTick < 0) {
    state.lastRoleCheckTick = state.tick;
    return "role_learned";
  }

  if (state.phase === "whisper" && state.prevPhase !== "whisper") {
    return "whisper_entered";
  }
  if (state.phase === "playing" && state.prevPhase === "whisper") {
    return "whisper_left";
  }
  if (state.phase === "waiting_entry" && state.prevPhase !== "waiting_entry") {
    return "whisper_requested_entry";
  }

  if (state.pendingRoleOffer && !state.prevPendingRoleOffer) {
    return "role_offer_pending";
  }

  const latestShout = state.shoutLog[state.shoutLog.length - 1];
  if (latestShout && latestShout.tick === state.tick) {
    return "shout_received";
  }

  if (state.tick - lastPromptTick < cooldown) return null;

  if (state.nearbyNames.length > 0 && state.prevNearbyNames.length === 0) {
    return "player_nearby";
  }
  if (state.nearbyNames.length === 0 && state.prevNearbyNames.length > 0) {
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
// Helpers
// ---------------------------------------------------------------------------

/** Extract the palette color from a character name like "R CRCL" → 3. */
export function colorFromCharName(name: string): number | null {
  const letter = name.split(" ")[0];
  return paletteColorFromLetter(letter);
}

function beliefDisplayName(b: PlayerBelief): string {
  return b.name;
}

function playerDesc(b: PlayerBelief): string {
  const parts = [beliefDisplayName(b)];
  if (b.lastPos) parts.push(`~(${b.lastPos.x},${b.lastPos.y})`);
  if (b.knownRole) parts.push(`role: ${b.knownRole}`);
  else if (b.knownTeam) parts.push(`team: ${b.knownTeam}`);
  if (b.inWhisper) parts.push("IN WHISPER");
  if (b.weSharedWith) parts.push("MUTUAL SHARE");
  return parts.join(", ");
}

function chatSenderName(color: number, shape: PlayerShape | null): string {
  if (shape !== null) return characterName(color, shape);
  return spriteNameFromPaletteColor(color);
}

function formatChatLine(m: ParsedChatLine, myColor: number | null): string {
  if (m.type === "system") return `  [system] ${m.text}`;
  const name = chatSenderName(m.senderColor, m.senderShape);
  const tag = (myColor !== null && m.senderColor === myColor) ? " (YOU)" : "";
  return `  ${name}${tag}: ${m.text}`;
}

function roomStr(room: Room | null): string {
  if (room === Room.RoomA) return "Underworld";
  if (room === Room.RoomB) return "Mortal Realm";
  return "UNKNOWN";
}

// ---------------------------------------------------------------------------
// Context dump — structured text for the LLM
// ---------------------------------------------------------------------------

export function formatContextDump(state: BeliefState, event: TriggerEvent): string {
  const lines: string[] = [];

  lines.push(`EVENT: ${event}`);
  lines.push(`TICK: ${state.tick} | ROUND: ${state.round} | TIME: ~${state.timerSecs}s | INTERFACE: ${state.phase} | ROOM: ${state.roomW}x${state.roomH}`);
  lines.push("");

  lines.push("MY STATE:");
  const mySpriteName = state.myCharName ?? "UNKNOWN";
  lines.push(`  I am: ${mySpriteName} | Role: ${state.myRole ?? "UNKNOWN"} | Team: ${state.myTeam ?? "UNKNOWN"} | Current Room: ${state.roomName ?? roomStr(state.myRoom)} (the other room is disjoint — players there are unreachable until a hostage swap)`);
  if (state.myPos) {
    let leaderStr = state.amLeader ? "yes" : "no";
    if (state.wasStartingLeader && !state.amLeader) leaderStr = "no (was starting leader)";
    lines.push(`  Position: (${state.myPos.x}, ${state.myPos.y}) | Leader: ${leaderStr}`);
  }
  if (state.phase === "leader_summit") {
    lines.push(`  IN LEADER SUMMIT with: ${state.occupantNames.join(", ") || "(other leader)"}. Hostages have been selected — you and the other room's leader are in a private whisper to negotiate before the exchange. Chat only — no role/color exchanges, no exit.`);
  } else if (state.phase === "whisper") {
    lines.push(`  IN WHISPER with: ${state.occupantNames.join(", ") || "(alone)"}. pending_role_offer=${state.pendingRoleOffer} pending_color_offer=${state.pendingColorOffer} pending_entry=${state.pendingEntry}`);
    if (state.pendingEntry) {
      lines.push(`  >>> Another player wants to enter your whisper. Use "grant_entry" to let them in, or ignore to keep them out.`);
    }
    if (state.pendingRoleOffer) {
      lines.push(`  >>> Another occupant has offered a MUTUAL ROLE EXCHANGE. If you accept and they turn out to be your key partner, your team WINS. If they're an enemy you leak your role. Only the two keys (Hades+Cerberus for Shades, Persephone+Demeter for Nymphs) trigger the win.`);
    } else if (state.pendingColorOffer) {
      lines.push(`  >>> Another occupant has offered a COLOR EXCHANGE. color_accept reveals teams to each other (safe, no role info).`);
    }
  } else if (state.phase === "waiting_entry") {
    lines.push(`  WAITING TO ENTER ANOTHER PLAYER'S WHISPER. You tried to create a whisper but were too close to an existing conversation — entry was requested instead. Wait for the owner to grant_entry, or cancel (B button) and move away to start your own.`);
  } else if (state.phase === "hostage_select") {
    if (state.amLeader) {
      lines.push(`  HOSTAGE SELECT — you are LEADER. Pick hostages to send to the other room. Use precommit_hostages task to auto-select, or the game will auto-fill randomly.`);
    } else {
      lines.push(`  HOSTAGE SELECT — waiting for leaders to pick hostages. You can shout to influence the leader's picks, or usurp_vote to change the leader.`);
    }
  } else if (state.phase === "hostage_exchange") {
    lines.push(`  HOSTAGE EXCHANGE — selected players are being swapped between rooms. Wait for next round.`);
  }

  // State-specific available actions
  lines.push("");
  lines.push("CURRENT STATE & AVAILABLE ACTIONS:");
  if (state.phase === "playing" || state.phase === "hostage_select") {
    lines.push("  State: OVERWORLD (free movement)");
    lines.push("  Tasks: walk_to, pursue_chat, pursue_exchange, shout, usurp_vote, precommit_hostages");
    lines.push("  Transitions: → WHISPER (pursue_chat/pursue_exchange reaches target) | → WAITING_ENTRY (near existing whisper)");
  } else if (state.phase === "whisper") {
    lines.push("  State: WHISPER (private conversation)");
    lines.push("  Tasks: chat, exit_whisper | loops: loop_auto_grant, loop_auto_accept_color, loop_auto_accept_role");
    lines.push("  Active pursue_exchange tasks will auto-offer/accept inside whisper");
    lines.push("  NOTE: You CANNOT hear shouts or see the overworld while in a whisper");
    lines.push("  Transitions: → OVERWORLD (exit_whisper) | → OVERWORLD (round ends — all whispers destroyed)");
  } else if (state.phase === "waiting_entry") {
    lines.push("  State: WAITING_ENTRY (pending whisper entry)");
    lines.push("  Do NOT emit any actions — wait for grant or timeout");
    lines.push("  Transitions: → WHISPER (entry granted) | → OVERWORLD (entry denied or timeout)");
  } else if (state.phase === "leader_summit") {
    lines.push("  State: LEADER_SUMMIT (leaders-only negotiation)");
    lines.push("  Tasks: chat only. No exits, no exchanges.");
    lines.push("  Transitions: → HOSTAGE_EXCHANGE (timer ends)");
  } else {
    lines.push(`  State: ${state.phase.toUpperCase()} — wait for phase to end`);
  }
  lines.push("");

  if (state.nearbyNames.length > 0) {
    lines.push(`NEARBY PLAYERS (in whisper range — press open_whisper to interact):`);
    for (const name of state.nearbyNames) {
      const b = state.players.get(name);
      lines.push(`  ${b ? playerDesc(b) : name}`);
    }
    lines.push("");
  }

  const otherDots = state.minimapDots.filter(d => !d.isSelf);
  if (otherDots.length > 0) {
    lines.push("OTHERS IN MY ROOM (from minimap — these are the only players I can currently interact with):");
    lines.push("  " + otherDots.map(d => {
      const b = beliefByColor(state, d.color);
      const name = b ? beliefDisplayName(b) : spriteNameFromPaletteColor(d.color);
      return `${name} ~(${d.worldX},${d.worldY})`;
    }).join(" | "));
    lines.push("");
  }

  if (state.shoutLog.length > 0) {
    lines.push("RECENT SHOUTS (room chat — only players in your current room):");
    for (const s of state.shoutLog.slice(-8)) {
      const b = beliefByColor(state, s.senderColor);
      const name = b ? beliefDisplayName(b) : spriteNameFromPaletteColor(s.senderColor);
      const tag = (state.myColor !== null && s.senderColor === state.myColor) ? " (YOU)" : "";
      lines.push(`  ${name}${tag}: "${s.text}"`);
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

  if (state.phase === "whisper" && state.whisperMessages.length > 0) {
    lines.push("WHISPER MESSAGES:");
    for (const m of state.whisperMessages.slice(-10)) {
      lines.push(formatChatLine(m, state.myColor));
    }
    lines.push("");
  }

  const recentChat = state.chatLog.slice(-8);
  if (recentChat.length > 0) {
    lines.push("RECENT CHAT HISTORY:");
    for (const m of recentChat) {
      lines.push(formatChatLine(m, state.myColor));
    }
    lines.push("");
  }

  lines.push("STRATEGIC CONTEXT:");
  lines.push(buildStrategicContext(state));
  lines.push("");

  return lines.join("\n");
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
    lines.push(cerb ? `  Cerberus: FOUND ${beliefDisplayName(cerb)}, shared: ${cerb.weSharedWith}` : "  Cerberus: NOT FOUND.");
  } else if (role === "CERBERUS") {
    lines.push("  Win: Hades must mutually share cards with me (Cerberus).");
    const hades = findKnownByRole(state, "Hades");
    lines.push(hades ? `  Hades: FOUND ${beliefDisplayName(hades)}, shared: ${hades.weSharedWith}` : "  Hades: NOT FOUND.");
  } else if (role === "PERSEPHONE") {
    lines.push("  Win: I (Persephone) must mutually share cards with Demeter.");
    const dem = findKnownByRole(state, "Demeter");
    lines.push(dem ? `  Demeter: FOUND ${beliefDisplayName(dem)}, shared: ${dem.weSharedWith}` : "  Demeter: NOT FOUND.");
  } else if (role === "DEMETER") {
    lines.push("  Win: Persephone must mutually share cards with me (Demeter).");
    const pers = findKnownByRole(state, "Persephone");
    lines.push(pers ? `  Persephone: FOUND ${beliefDisplayName(pers)}, shared: ${pers.weSharedWith}` : "  Persephone: NOT FOUND.");
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

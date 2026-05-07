import { Room } from "../game/types.js";
import { ROOM_W, ROOM_H, SCREEN_WIDTH, SCREEN_HEIGHT, BUBBLE_RADIUS, TARGET_FPS, TEAM_A_COLOR, TEAM_A_NAME, TEAM_B_NAME, characterName, spriteNameFromPaletteColor, COLOR_LETTERS, SHAPE_NAMES, paletteColorFromLetter } from "../game/constants.js";
import { PlayerShape } from "../game/types.js";
import { readPosition, type Point } from "./bot_utils.js";
import {
  parsePhase, parsePlayingHud, parseRoleRevealScreen, scanMinimapPlayers,
  parsePsychopompSelectHud,
  parseRoundClock,
  parseWhisperStatus, parseLastShout, scanSpeechBubbles,
  parseWhisperMessages, parseShoutMessages, scanOverworldShapes,
  parseRoundScheduleScreen, matchRoster, parseInfoScreen,
  type ParsedPhase, type InfoScreenEntry, type MinimapDot, type ParsedChatLine, type RosterEntry,
  type FrameParserOptions,
} from "./frame_parser.js";
import type { Activity, AtomicAction } from "./ooda_types.js";

// ---------------------------------------------------------------------------
// Knowledge state — accumulated knowledge from info screen polling + actions
// ---------------------------------------------------------------------------

export interface PlayerKnowledge {
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
  /** Minimap dots only encode color, so this may refer to any same-color player until a sprite-bearing UI disambiguates it. */
  positionAmbiguousByColor: boolean;
  weSharedWith: boolean;
  theyRevealedCard: boolean;
  theyRevealedColor: boolean;
}

export interface RoundFact {
  round: number;
  durationSecs: number;
  psychopomps: number;
}

export interface MatchFacts {
  roomW: number;
  roomH: number;
  playerCount: number;
  startingRoomName: string | null;
  startingRoom: Room | null;
  rounds: RoundFact[];
  currentRound: number;
  timerSecs: number;
  psychopompSelectTimerSecs: number;
}

export interface PlayerNotes {
  summary?: string;
  trust?: "ally" | "enemy" | "unknown" | "mixed";
  wants?: string;
  warnings?: string;
  updatedTick: number;
}

export interface KnowledgeNotes {
  global: string;
  goals: string[];
  risks: string[];
  messageNotes: string[];
  players: Record<string, PlayerNotes>;
  updatedTick: number;
}

export interface DecisionMemory {
  summary: string;
  updatedTick: number;
}

export interface LlmDecisionNotes {
  exchange: DecisionMemory;
  pursue: Record<string, DecisionMemory>;
  psychopomp: DecisionMemory;
  usurp: DecisionMemory;
  messageInterpretation: DecisionMemory;
}

export interface LlmNotes {
  notes: KnowledgeNotes;
  decisions: LlmDecisionNotes;
}

export interface KnowledgeMatch {
  facts: MatchFacts;
}

export interface KnowledgeLearned {
  players: Map<string, PlayerKnowledge>;
  minimapDots: MinimapDot[];
  nearbyNames: string[];
  prevNearbyNames: string[];
  exchanges: ExchangeKnowledge;
}

export interface SenderIdentity {
  name: string;
  color: number;
  shape: PlayerShape | null;
  ambiguous: boolean;
}

export interface SelfKnowledge {
  name: string | null;
  color: number | null;
  shape: PlayerShape | null;
  role: string | null;
  team: string | null;
  room: Room | null;
  pos: Point | null;
  amLeader: boolean;
}

export interface RendezvousOffer {
  sender: SenderIdentity;
  intendedTarget: string | null;
  coords: Point;
  room: Room;
  tick: number;
  expiryTick: number;
  sourceText: string;
  acknowledged: boolean;
  ackTick: number;
}

export interface MessageKnowledge {
  chatLog: ParsedChatLine[];
  shoutLog: { tick: number; text: string; senderColor: number }[];
  whisperMessages: ParsedChatLine[];
  shoutMessages: ParsedChatLine[];
  rendezvousOffers: RendezvousOffer[];
}

export interface ExchangeRecord {
  target: string;
  tick: number;
  source: string;
}

export interface ExchangeKnowledge {
  succeededColor: Record<string, ExchangeRecord>;
  succeededRole: Record<string, ExchangeRecord>;
}

export type CommunicationChannel = "shout" | "whisper";

export interface CommunicationDraft {
  id: string;
  channel: CommunicationChannel;
  target: string | null;
  text: string;
  reason: string;
  source: string;
  writtenTick: number;
  expiryTick: number;
}

export interface CommunicationKnowledge {
  shoutQueue: CommunicationDraft[];
  whisperQueues: Record<string, CommunicationDraft[]>;
  recentKeys: Record<string, number>;
}

export interface StrategyTelemetryEvent {
  tick: number;
  area: "communication" | "exchange" | "policy";
  event: string;
  detail: Record<string, unknown>;
}

export interface StrategyKnowledge {
  communication: CommunicationKnowledge;
  telemetry: StrategyTelemetryEvent[];
}

export interface PrefetchedWhisper {
  target: string;
  message: string;
  tick: number;
}

export interface MeetPoint {
  x: number;
  y: number;
  reason: string;
  tick: number;
}

export type PursueModeHint = {
  mode: "find_spot" | "go_to_player" | "noop";
  reason: string;
  tick: number;
};

export interface ResolvedPolicy {
  keepGlobalCheckActive: boolean;
  globalCheckIntervalTicks: number;
  pursueColorExchangeWithPlayer: string[];
  pursueRoleExchangeWithPlayer: string[];
  avoidPlayers: string[];
  autoGrantEntry: boolean;
  autoGrantDenyPlayers: string[];
  acceptRoleOffers: boolean;
  acceptLeaderOffers: boolean;
  autoAcceptColorOffer: boolean;
  autoOfferColorExchange: boolean;
  autoOfferColorDenyPlayers: string[];
  autoOfferRoleExchange: boolean;
  meetPoint: MeetPoint | null;
  psychopompTargets: string[] | null;
  shouldUsurp: boolean;
  usurpTarget: string | null;
  shoutNext: string | null;
  prefetchedWhisper: PrefetchedWhisper | null;
  whisperActionNext: "ROLE" | "C.OFFER" | "C.UNOFFR" | "R.OFFER" | "R.UNOFFR" | "PASS" | "TAKE" | "GRANT" | null;
  exitCurrentWhisper: boolean;
  pursueModeHints: Record<string, PursueModeHint>;
  hostPrivateSpotProbability: number;
  goToVisiblePlayerProbability: number;
  shoutInviteWhenHostingAlone: boolean;
  choosePsychopompFallback: boolean;
  maybeUsurpFallback: boolean;
  strategyNotes: string;
  lastUpdatedTick: number;
}

export interface PolicyPatch {
  source: string;
  writtenTick: number;
  expiryTick?: number;
  patch: Partial<ResolvedPolicy>;
}

export interface PolicyKnowledge {
  baseline: ResolvedPolicy;
  patches: PolicyPatch[];
  resolved: ResolvedPolicy;
}

export type ExchangePhase = "idle" | "shouting" | "walking" | "whispering" | "done";
export type ExchangeMode = "find_spot" | "go_to_player";
export type WhisperIntentExchange = "color" | "role" | "whisper" | "leader";

export interface WhisperIntent {
  target: string;
  exchange: WhisperIntentExchange;
  startedTick: number;
  lastActionTick: number;
}

export interface ActionExchangeState {
  lastShoutTick: number;
  failedTargets: Map<string, number>;
  badPursueTargets: Map<string, { tick: number; reason: string }>;
  prefetchRequested: string | null;
  currentTarget: string | null;
  currentExchangeMode: ExchangeMode;
  currentExchange: WhisperIntentExchange;
  exchangePhase: ExchangePhase;
  exchangeStartTick: number;
  whisperIntent: WhisperIntent | null;
  lastInitRound: number;
  lastInterpretTick: number;
  lastWhisperActionKey: string | null;
  activeColorOffer: boolean;
  activeRoleOffer: boolean;
  roleFollowupUntilTick: number;
  lastWhisperSeenTick: number;
}

export interface ActionKnowledge {
  currentActivity: Activity | null;
  atomQueue: AtomicAction[];
  exchange: ActionExchangeState;
  psychopompPrecommit: string[];
  psychopompPrecommitRound: number;
  lastUsurpVoteTarget: string | null;
  lastUsurpVoteRound: number;
  lastSentChat: string | null;
  hasNewIncomingChat: boolean;
  lastGlobalCheckTick: number;
  lastInfoCheckTick: number;
  infoCheckIntervalTicks: number;
  forceInfoCheck: boolean;
  lastInfoUpdatedTick: number;
  whisperStartedTick: number | null;
}

export interface AsyncKnowledge {
  pending: Set<string>;
  cooldowns: Record<string, number>;
}

export interface GameKnowledge {
  observed: {
    frameTick: number;
    phase: ParsedPhase;
  };
  match: KnowledgeMatch;
  playersSection: Map<string, PlayerKnowledge>;
  messages: MessageKnowledge;
  learned: KnowledgeLearned;
  self: SelfKnowledge;
  strategy: StrategyKnowledge;
  llmNotes: LlmNotes;
  policy: PolicyKnowledge;
  action: ActionKnowledge;
  async: AsyncKnowledge;
  exchanges: ExchangeKnowledge;

  // Compatibility alias for older prompt code. v2 writes notes through llmNotes.
  notes: KnowledgeNotes;

  // Compatibility fields used by deterministic policy/tasks. These are the
  // same underlying data mirrored into the categorized fields above.
  myName: string;
  myColor: number | null;
  myShape: PlayerShape | null;
  myCharName: string | null;
  myRole: string | null;
  myTeam: string | null;
  myRoom: Room | null;
  myPos: Point | null;
  amLeader: boolean;
  roomLeaderName: string | null;
  phase: ParsedPhase;
  prevPhase: ParsedPhase;
  /** Keyed by character name (e.g. "R.CRCL"). */
  players: Map<string, PlayerKnowledge>;
  minimapDots: MinimapDot[];
  nearbyNames: string[];
  prevNearbyNames: string[];
  chatLog: ParsedChatLine[];
  tick: number;
  lastRoleCheckTick: number;
  lastInfoPollTick: number;
  /** Verifiably correct match setup facts from the intro/info phase. */
  matchFacts: MatchFacts;
  pendingRoleOffer: boolean;
  pendingColorOffer: boolean;
  pendingLeaderOffer: boolean;
  pendingEntry: boolean;
  /** In whisper: character name of the first visible player requesting entry, when parseable. */
  pendingEntryName: string | null;
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

function defaultNotes(): KnowledgeNotes {
  return {
    global: "",
    goals: [],
    risks: [],
    messageNotes: [],
    players: {},
    updatedTick: -1,
  };
}

function defaultLlmDecisionNotes(): LlmDecisionNotes {
  return {
    exchange: { summary: "", updatedTick: -1 },
    pursue: {},
    psychopomp: { summary: "", updatedTick: -1 },
    usurp: { summary: "", updatedTick: -1 },
    messageInterpretation: { summary: "", updatedTick: -1 },
  };
}

export function defaultResolvedPolicy(): ResolvedPolicy {
  return {
    keepGlobalCheckActive: true,
    globalCheckIntervalTicks: 96,
    pursueColorExchangeWithPlayer: [],
    pursueRoleExchangeWithPlayer: [],
    avoidPlayers: [],
    autoGrantEntry: true,
    autoGrantDenyPlayers: [],
    acceptRoleOffers: false,
    acceptLeaderOffers: true,
    autoAcceptColorOffer: true,
    autoOfferColorExchange: true,
    autoOfferColorDenyPlayers: [],
    autoOfferRoleExchange: false,
    meetPoint: null,
    psychopompTargets: null,
    shouldUsurp: false,
    usurpTarget: null,
    shoutNext: null,
    prefetchedWhisper: null,
    whisperActionNext: null,
    exitCurrentWhisper: false,
    pursueModeHints: {},
    hostPrivateSpotProbability: 0.25,
    goToVisiblePlayerProbability: 0.7,
    shoutInviteWhenHostingAlone: true,
    choosePsychopompFallback: true,
    maybeUsurpFallback: true,
    strategyNotes: "",
    lastUpdatedTick: -1,
  };
}

function defaultExchangeKnowledge(): ExchangeKnowledge {
  return {
    succeededColor: {},
    succeededRole: {},
  };
}

function defaultCommunicationKnowledge(): CommunicationKnowledge {
  return {
    shoutQueue: [],
    whisperQueues: {},
    recentKeys: {},
  };
}

export function defaultActionExchangeState(): ActionExchangeState {
  return {
    lastShoutTick: -Infinity,
    failedTargets: new Map(),
    badPursueTargets: new Map(),
    prefetchRequested: null,
    currentTarget: null,
    currentExchangeMode: "go_to_player",
    currentExchange: "color",
    exchangePhase: "idle",
    exchangeStartTick: 0,
    whisperIntent: null,
    lastInitRound: -1,
    lastInterpretTick: -Infinity,
    lastWhisperActionKey: null,
    activeColorOffer: false,
    activeRoleOffer: false,
    roleFollowupUntilTick: -Infinity,
    lastWhisperSeenTick: -Infinity,
  };
}

function syncGameKnowledgeCategories(state: GameKnowledge): void {
  state.observed.frameTick = state.tick;
  state.observed.phase = state.phase;
  state.match.facts = state.matchFacts;
  state.playersSection = state.players;
  state.learned.players = state.players;
  state.learned.minimapDots = state.minimapDots;
  state.learned.nearbyNames = state.nearbyNames;
  state.learned.prevNearbyNames = state.prevNearbyNames;
  state.learned.exchanges = state.exchanges;
  state.messages.chatLog = state.chatLog;
  state.messages.shoutLog = state.shoutLog;
  state.messages.whisperMessages = state.whisperMessages;
  state.messages.shoutMessages = state.shoutMessages;
  state.notes = state.llmNotes.notes;
  state.self.name = state.myCharName;
  state.self.color = state.myColor;
  state.self.shape = state.myShape;
  state.self.role = state.myRole;
  state.self.team = state.myTeam;
  state.self.room = state.myRoom;
  state.self.pos = state.myPos;
  state.self.amLeader = state.amLeader;
}

export function createGameKnowledge(name: string): GameKnowledge {
  const matchFacts: MatchFacts = {
    roomW: ROOM_W,
    roomH: ROOM_H,
    playerCount: 0,
    startingRoomName: null,
    startingRoom: null,
    rounds: [],
    currentRound: 0,
    timerSecs: 0,
    psychopompSelectTimerSecs: 0,
  };
  const players = new Map<string, PlayerKnowledge>();
  const minimapDots: MinimapDot[] = [];
  const nearbyNames: string[] = [];
  const prevNearbyNames: string[] = [];
  const chatLog: ParsedChatLine[] = [];
  const shoutLog: { tick: number; text: string; senderColor: number }[] = [];
  const whisperMessages: ParsedChatLine[] = [];
  const shoutMessages: ParsedChatLine[] = [];
  const notes = defaultNotes();
  const baseline = defaultResolvedPolicy();
  const exchanges = defaultExchangeKnowledge();

  const state: GameKnowledge = {
    observed: { frameTick: 0, phase: "unknown" },
    match: { facts: matchFacts },
    playersSection: players,
    messages: {
      chatLog,
      shoutLog,
      whisperMessages,
      shoutMessages,
      rendezvousOffers: [],
    },
    learned: {
      players,
      minimapDots,
      nearbyNames,
      prevNearbyNames,
      exchanges,
    },
    self: {
      name: null,
      color: null,
      shape: null,
      role: null,
      team: null,
      room: null,
      pos: null,
      amLeader: false,
    },
    strategy: {
      communication: defaultCommunicationKnowledge(),
      telemetry: [],
    },
    llmNotes: {
      notes,
      decisions: defaultLlmDecisionNotes(),
    },
    policy: {
      baseline,
      patches: [],
      resolved: { ...baseline, pursueModeHints: {} },
    },
    action: {
      currentActivity: null,
      atomQueue: [],
      exchange: defaultActionExchangeState(),
      psychopompPrecommit: [],
      psychopompPrecommitRound: -1,
      lastUsurpVoteTarget: null,
      lastUsurpVoteRound: -1,
      lastSentChat: null,
      hasNewIncomingChat: false,
      lastGlobalCheckTick: -Infinity,
      lastInfoCheckTick: -Infinity,
      infoCheckIntervalTicks: 96,
      forceInfoCheck: false,
      lastInfoUpdatedTick: -Infinity,
      whisperStartedTick: null,
    },
    async: {
      pending: new Set(),
      cooldowns: {},
    },
    exchanges,
    notes,
    myName: name,
    myColor: null,
    myShape: null,
    myCharName: null,
    myRole: null,
    myTeam: null,
    myRoom: null,
    myPos: null,
    amLeader: false,
    roomLeaderName: null,
    phase: "unknown",
    prevPhase: "unknown",
    players,
    minimapDots,
    nearbyNames,
    prevNearbyNames,
    chatLog,
    tick: 0,
    lastRoleCheckTick: -999,
    lastInfoPollTick: -999,
    matchFacts,
    pendingRoleOffer: false,
    pendingColorOffer: false,
    pendingLeaderOffer: false,
    pendingEntry: false,
    pendingEntryName: null,
    prevPendingRoleOffer: false,
    occupantCount: 0,
    occupantNames: [],
    shoutLog,
    lastShoutText: null,
    whisperMessages,
    lastWhisperMsgHash: "",
    shoutMessages,
    lastShoutMsgHash: "",
    revealLocked: false,
    wasStartingLeader: false,
    startingLeaderRound: -1,
  };
  syncGameKnowledgeCategories(state);
  return state;
}

function trySetMyCharName(state: GameKnowledge) {
  if (state.myCharName !== null) return;
  if (state.myColor !== null && state.myShape !== null) {
    state.myCharName = characterName(state.myColor, state.myShape);
  }
}

/** Look up a player by palette color. Returns the first match (ambiguous if colors collide). */
function playerByColor(state: GameKnowledge, color: number): PlayerKnowledge | undefined {
  for (const b of state.players.values()) {
    if (b.color === color) return b;
  }
  return undefined;
}

function knownSpriteOptions(state: GameKnowledge): FrameParserOptions {
  return matchRoster(state.players.values());
}

/** Get or create a player for a player identified by color+shape. */
function getOrCreatePlayerKnowledge(state: GameKnowledge, color: number, shape: PlayerShape | null): PlayerKnowledge {
  const name = shape !== null ? characterName(color, shape) : spriteNameFromPaletteColor(color);
  let player = state.players.get(name);
  if (player) {
    if (shape !== null && player.shape === null) {
      player.shape = shape;
      // Migrate from color-only name to full character name
      if (player.name !== name) {
        state.players.delete(player.name);
        player.name = name;
        state.players.set(name, player);
      }
    }
    return player;
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
  player = {
    name, color, shape,
    lastRoom: null, lastPos: null, lastSeenTick: state.tick,
    knownRole: null, knownTeam: null,
    isLeader: false, inWhisper: false, positionAmbiguousByColor: false, weSharedWith: false,
    theyRevealedCard: false, theyRevealedColor: false,
  };
  state.players.set(name, player);
  return player;
}

export function updatePhase(state: GameKnowledge, frame: Uint8Array): void {
  state.tick++;
  state.prevPhase = state.phase;
  state.phase = parsePhase(frame);
  if (state.phase === "whisper") {
    state.action.whisperStartedTick ??= state.tick;
  } else if (state.phase !== "info_screen") {
    state.action.whisperStartedTick = null;
  }

  if (state.phase === "role_reveal") {
    const info = !state.revealLocked ? parseRoleRevealScreen(frame) : null;
    if (info) {
      state.myRole = info.role;
      state.myTeam = info.team;
      state.matchFacts.startingRoomName = info.room;
      state.myRoom = info.room.toUpperCase().includes("UNDERWORLD") ? Room.RoomA : Room.RoomB;
      state.matchFacts.startingRoom = state.myRoom;
      if (info.roomSize > 0) {
        state.matchFacts.roomW = info.roomSize;
        state.matchFacts.roomH = info.roomSize;
      }
      if (info.playerCount > 0) {
        state.matchFacts.playerCount = info.playerCount;
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

    const schedule = parseRoundScheduleScreen(frame);
    if (schedule) state.matchFacts.rounds = schedule;
  }

  state.prevPendingRoleOffer = state.pendingRoleOffer;
  const parserOptions = knownSpriteOptions(state);
  if (state.phase === "whisper" || state.phase === "leader_summit") {
    const status = parseWhisperStatus(frame, parserOptions);
    state.pendingRoleOffer = status.pendingRoleOffer;
    state.pendingColorOffer = status.pendingColorOffer;
    state.pendingLeaderOffer = status.pendingLeaderOffer;
    state.pendingEntry = status.pendingEntry;
    state.pendingEntryName = status.pendingEntryName;
    state.occupantCount = status.occupantCount;
    const selfOccupant = status.occupants.find(o => {
      if (state.myCharName && o.shape !== null) return characterName(o.color, o.shape) === state.myCharName;
      if (state.myColor !== null) return o.color === state.myColor;
      return false;
    }) ?? status.occupants[0];
    if (selfOccupant && !state.revealLocked) {
      const self = selfOccupant;
      if (state.myColor === null) state.myColor = self.color;
      if (state.myShape === null && self.shape !== null) state.myShape = self.shape;
      trySetMyCharName(state);
    }
    state.occupantNames = [];
    for (const o of status.occupants) {
      const b = getOrCreatePlayerKnowledge(state, o.color, o.shape);
      if (b.name !== state.myCharName && !state.occupantNames.includes(b.name)) {
        state.occupantNames.push(b.name);
      }
    }
  } else {
    state.pendingRoleOffer = false;
    state.pendingColorOffer = false;
    state.pendingLeaderOffer = false;
    state.pendingEntry = false;
    state.pendingEntryName = null;
    state.occupantCount = 0;
    state.occupantNames = [];
    state.action.exchange.activeColorOffer = false;
    state.action.exchange.activeRoleOffer = false;
    state.action.exchange.roleFollowupUntilTick = -Infinity;
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

  // Parse full shout messages in shout view for leader changes
  if (state.phase === "playing" || state.phase === "psychopomp_select") {
    const msgs = parseShoutMessages(frame, parserOptions);
    const hash = msgs.map(m => `${m.type}:${m.senderColor}:${m.text}`).join("|");
    if (hash !== state.lastShoutMsgHash) {
      state.shoutMessages = msgs;
      state.lastShoutMsgHash = hash;
      updateLeaderFromShoutMessages(state, msgs);
    }
  }

  if (state.phase === "whisper" || state.phase === "leader_summit") {
    const msgs = parseWhisperMessages(frame, parserOptions);
    const hash = msgs.map(m => `${m.senderColor}:${m.text}`).join("|");
    if (hash !== state.lastWhisperMsgHash) {
      state.whisperMessages = msgs;
      state.lastWhisperMsgHash = hash;
      for (const m of msgs) {
        if (m.type !== "text") continue;
        if (m.senderShape !== null && m.senderColor !== 0) {
          getOrCreatePlayerKnowledge(state, m.senderColor, m.senderShape);
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

export function updateGameKnowledgeFromFrame(
  state: GameKnowledge,
  frame: Uint8Array,
  roster?: RosterEntry[] | null,
): void {
  updatePhase(state, frame);
  if (state.phase === "roster_reveal" && roster) updateFromRosterScreen(state, roster);
  if (state.phase === "info_screen") {
    const entries = parseInfoScreen(frame, matchRoster(state.players.values()));
    if (entries) updateKnowledgeFromInfoScreen(state, entries);
  }

  // Position and minimap are one logical snapshot. Position comes first so
  // shape/nearby inference uses the same frame's camera estimate.
  updatePosition(state, frame);
  updateMinimap(state, frame);
  updateHud(state, frame);
  runDeterministicDerivedOrienters(state);
  syncGameKnowledgeCategories(state);
}

export function updateKnowledgeFromInfoScreen(state: GameKnowledge, entries: InfoScreenEntry[]): boolean {
  const changed = updateFromInfoScreen(state, entries);
  state.action.lastInfoCheckTick = state.tick;
  state.action.forceInfoCheck = false;
  if (changed) state.action.lastInfoUpdatedTick = state.tick;
  syncGameKnowledgeCategories(state);
  return changed;
}

export function updateMinimap(state: GameKnowledge, frame: Uint8Array): void {
  if (state.phase !== "playing" && state.phase !== "psychopomp_select" && state.phase !== "leader_summit") return;
  if (state.myRoom === null) return;
  state.minimapDots = scanMinimapPlayers(frame, state.myRoom, state.matchFacts.roomW, state.matchFacts.roomH);
  const parserOptions = knownSpriteOptions(state);
  const shapeHits = state.myPos
    ? scanOverworldShapes(frame, state.myPos.x, state.myPos.y, state.matchFacts.roomW, state.matchFacts.roomH, state.minimapDots, parserOptions)
    : [];

  const nearby: string[] = [];
  for (const dot of state.minimapDots) {
    if (dot.isSelf) continue;
    const sameColor = Array.from(state.players.values()).filter(b => b.color === dot.color);
    const shapeResolved = shapeHits
      .filter(hit => hit.color === dot.color)
      .map(hit => getOrCreatePlayerKnowledge(state, hit.color, hit.shape));
    const playersForDot = shapeResolved.length > 0 ? shapeResolved : sameColor;
    for (const player of sameColor) {
      player.lastRoom = state.myRoom;
      player.lastPos = { x: dot.worldX, y: dot.worldY };
      player.lastSeenTick = state.tick;
      player.positionAmbiguousByColor = sameColor.length > 1 && shapeResolved.length === 0;
    }
    if (state.myPos) {
      const dx = dot.worldX - state.myPos.x;
      const dy = dot.worldY - state.myPos.y;
      if (Math.sqrt(dx * dx + dy * dy) <= BUBBLE_RADIUS + 5) {
        for (const player of playersForDot) {
          if (!nearby.includes(player.name)) nearby.push(player.name);
        }
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
        const hit = shapeHits.find(h =>
          h.color === c && Math.abs(h.screenX - bub.screenX) <= 2 && Math.abs(h.screenY - bub.screenY) <= 2
        );
        const b = hit ? getOrCreatePlayerKnowledge(state, hit.color, hit.shape) : playerByColor(state, c);
        if (b) {
          b.inWhisper = true;
          if (hit) b.positionAmbiguousByColor = false;
        }
      }
    }
  }
}

export function updateFromRosterScreen(state: GameKnowledge, entries: RosterEntry[]): boolean {
  let newInfo = false;
  for (const entry of entries) {
    const before = state.players.has(entry.name);
    const player = getOrCreatePlayerKnowledge(state, entry.playerColor, entry.playerShape);
    player.name = entry.name;
    player.positionAmbiguousByColor = false;
    if (entry.room !== null) player.lastRoom = entry.room;
    player.lastSeenTick = state.tick;
    if (!before) newInfo = true;
  }
  return newInfo;
}

export function updatePosition(state: GameKnowledge, frame: Uint8Array): void {
  if (state.phase !== "playing" && state.phase !== "psychopomp_select" && state.phase !== "leader_summit") return;
  const pos = readPosition(frame, state.matchFacts.roomW, state.matchFacts.roomH);
  if (pos) {
    state.myPos = { x: pos.x, y: pos.y };
    state.myRoom = pos.room;
  }
}

export function updateHud(state: GameKnowledge, frame: Uint8Array): void {
  if (
    state.phase !== "playing" &&
    state.phase !== "psychopomp_select" &&
    state.phase !== "leader_summit" &&
    state.phase !== "whisper" &&
    state.phase !== "psychopomp_exchange" &&
    state.phase !== "reveal"
  ) return;

  const clock = parseRoundClock(frame);
  if (clock) {
    state.matchFacts.currentRound = clock.round;
    state.matchFacts.timerSecs = clock.timerSecs;
  }

  const hud = parsePlayingHud(frame);
  if (hud) {
    state.matchFacts.currentRound = hud.round;
    state.matchFacts.timerSecs = hud.timerSecs;
    state.matchFacts.psychopompSelectTimerSecs = 0;
    if (hud.roleName) {
      state.amLeader = hud.isLeader;
      if (hud.isLeader && state.myCharName) state.roomLeaderName = state.myCharName;
    }
    if (hud.round !== state.startingLeaderRound) {
      state.wasStartingLeader = hud.isLeader;
      state.startingLeaderRound = hud.round;
    }
    if (hud.roleName && state.myRole === null) {
      state.myRole = hud.roleName;
    }
  }
  if (state.phase === "psychopomp_select") {
    const psychopompHud = parsePsychopompSelectHud(frame);
    if (psychopompHud) {
      state.matchFacts.psychopompSelectTimerSecs = psychopompHud.timerSecs;
    }
  }
}

export function updateFromInfoScreen(state: GameKnowledge, entries: InfoScreenEntry[]): boolean {
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

    const player = getOrCreatePlayerKnowledge(state, entry.playerColor, entry.playerShape);
    player.lastSeenTick = state.tick;

    if (entry.roleName && !player.knownRole) {
      player.knownRole = entry.roleName;
      player.theyRevealedCard = true;
      newInfo = true;
    }
    if (entry.teamColor !== null && !player.knownTeam) {
      player.knownTeam = entry.teamColor === TEAM_A_COLOR ? TEAM_A_NAME : TEAM_B_NAME;
      player.theyRevealedColor = true;
      newInfo = true;
    }
    if (entry.colorOnlyReveal && !player.theyRevealedColor) {
      player.theyRevealedColor = true;
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
  | "psychopomp_phase" | "leader_summit" | "idle" | "role_learned" | "periodic"
  | "player_nearby" | "player_left"
  | "role_offer_pending"
  | "shout_received"
  | "whisper_entered" | "whisper_left"
  | "whisper_requested_entry";

export function checkTriggers(
  state: GameKnowledge,
  lastPromptTick: number,
  hasActiveGoal: boolean,
): TriggerEvent | null {
  const cooldown = TARGET_FPS * 8;

  if (state.phase === "playing" && state.prevPhase !== "playing") {
    if (state.prevPhase === "role_reveal" || state.prevPhase === "lobby") return "game_start";
    return "round_start";
  }

  if (state.phase === "playing" && state.prevPhase === "psychopomp_exchange") {
    return "round_start";
  }

  if (state.phase === "psychopomp_select" && state.prevPhase !== "psychopomp_select") {
    return "psychopomp_phase";
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

/** Extract the palette color from a character name like "R.CRCL" -> 3. */
export function colorFromCharName(name: string): number | null {
  const letter = name.split(".")[0];
  return paletteColorFromLetter(letter);
}

function playerDisplayName(b: PlayerKnowledge): string {
  return b.name;
}

function playerDesc(b: PlayerKnowledge): string {
  const parts = [playerDisplayName(b)];
  if (b.lastPos) parts.push(`~(${b.lastPos.x},${b.lastPos.y})${b.positionAmbiguousByColor ? " color-ambiguous" : ""}`);
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

function senderIdentity(state: GameKnowledge, color: number, shape: PlayerShape | null): SenderIdentity {
  const exactName = shape !== null ? characterName(color, shape) : null;
  const sameColor = Array.from(state.players.values()).filter(p => p.color === color);
  if (exactName) {
    return { name: exactName, color, shape, ambiguous: false };
  }
  if (sameColor.length === 1) {
    return { name: sameColor[0].name, color, shape: sameColor[0].shape, ambiguous: false };
  }
  return { name: spriteNameFromPaletteColor(color), color, shape: null, ambiguous: sameColor.length > 1 };
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

export function psychopompCountForRound(state: GameKnowledge, round: number = state.matchFacts.currentRound): number | null {
  const fact = state.matchFacts.rounds.find(r => r.round === round);
  return fact?.psychopomps ?? null;
}

export function chooseDeterministicPsychopompTargets(state: GameKnowledge): string[] {
  const count = psychopompCountForRound(state) ?? 1;
  const inRoom = Array.from(state.players.values())
    .filter(p => p.lastRoom === state.myRoom && p.name !== state.myCharName);
  const pool = shuffledPsychopompPool(inRoom, state);
  const seen = new Set<string>();
  return pool
    .map(p => p.name)
    .filter(name => {
      if (seen.has(name)) return false;
      seen.add(name);
      return true;
    })
    .slice(0, count);
}

function shuffledPsychopompPool<T extends { name: string }>(items: T[], state: GameKnowledge): T[] {
  return items
    .map(item => ({ item, rank: psychopompShuffleRank(`${state.myCharName ?? "?"}:${state.matchFacts.currentRound}:${item.name}`) }))
    .sort((a, b) => a.rank - b.rank)
    .map(entry => entry.item);
}

function psychopompShuffleRank(input: string): number {
  let h = 2166136261;
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

// ---------------------------------------------------------------------------
// Leader observer — track room leader from shout system messages + self HUD
// ---------------------------------------------------------------------------

function setRoomLeader(state: GameKnowledge, name: string): void {
  // Clear old leader
  if (state.roomLeaderName && state.roomLeaderName !== name) {
    const old = state.players.get(state.roomLeaderName);
    if (old) old.isLeader = false;
  }
  state.roomLeaderName = name;
  const pk = state.players.get(name);
  if (pk) pk.isLeader = true;
  if (name === state.myCharName) state.amLeader = true;
  else if (state.roomLeaderName === state.myCharName) state.amLeader = false;
}

function updateLeaderFromShoutMessages(state: GameKnowledge, msgs: ParsedChatLine[]): void {
  // Sim emits: "${pref(pi)} is now leader" as system message with inline sprite.
  // Parser returns type "system" with senderColor/senderShape from the sprite,
  // and text "IS NOW LEADER" (color 8 text after the sprite).
  for (const m of msgs) {
    if (m.type !== "system" || m.senderColor === 0 || m.senderShape === null) continue;
    const text = m.text.toUpperCase().replace(/\s+/g, "");
    if (text === "ISNOWLEADER") {
      setRoomLeader(state, characterName(m.senderColor, m.senderShape));
    }
  }
}

// ---------------------------------------------------------------------------
// Deterministic derived orienters + policy resolver
// ---------------------------------------------------------------------------

function normalizeRoleName(role: string | null): string {
  const r = (role ?? "").trim().toUpperCase();
  switch (r) {
    case "ECHO OF HADES": return "HADES";
    case "ECHO OF PERSEPHONE": return "PERSEPHONE";
    case "ECHO OF CERBERUS": return "CERBERUS";
    case "ECHO OF DEMETER": return "DEMETER";
    default: return r;
  }
}

function keyPartnerRoleName(role: string | null): string | null {
  switch (normalizeRoleName(role)) {
    case "HADES": return "CERBERUS";
    case "CERBERUS": return "HADES";
    case "PERSEPHONE": return "DEMETER";
    case "DEMETER": return "PERSEPHONE";
    default: return null;
  }
}

function isKnownTeammate(state: GameKnowledge, name: string): boolean {
  const player = state.players.get(name);
  return !!player?.knownTeam && !!state.myTeam && player.knownTeam === state.myTeam;
}

function visibleByName(state: GameKnowledge, name: string): boolean {
  const color = colorFromCharName(name);
  return color !== null && state.minimapDots.some(dot => dot.color === color && !dot.isSelf);
}

function knownCurrentRoomPlayerNames(state: GameKnowledge): Set<string> {
  return new Set(Array.from(state.players.values())
    .filter(p => p.name !== state.myCharName)
    .filter(p => p.lastRoom === state.myRoom)
    .map(p => p.name));
}

function validPolicyName(state: GameKnowledge, name: unknown): name is string {
  return typeof name === "string" && name !== state.myCharName && state.players.has(name);
}

function validateNameArray(state: GameKnowledge, value: unknown, inCurrentRoomOnly = false): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const roomNames = inCurrentRoomOnly ? knownCurrentRoomPlayerNames(state) : null;
  const out: string[] = [];
  for (const raw of value) {
    if (!validPolicyName(state, raw)) continue;
    if (roomNames && !roomNames.has(raw)) continue;
    if (!out.includes(raw)) out.push(raw);
  }
  return out;
}

function clampPolicyText(value: unknown, max: number): string | null | undefined {
  if (value === null) return null;
  if (typeof value !== "string") return undefined;
  const cleaned = value.replace(/\s+/g, " ").trim();
  if (!cleaned) return undefined;
  return cleaned.slice(0, max);
}

function pushStrategyTelemetry(
  state: GameKnowledge,
  area: StrategyTelemetryEvent["area"],
  event: string,
  detail: Record<string, unknown>,
): void {
  state.strategy.telemetry.push({ tick: state.tick, area, event, detail });
  if (state.strategy.telemetry.length > 80) {
    state.strategy.telemetry.splice(0, state.strategy.telemetry.length - 80);
  }
}

export function drainStrategyTelemetry(state: GameKnowledge): StrategyTelemetryEvent[] {
  const out = state.strategy.telemetry;
  state.strategy.telemetry = [];
  return out;
}

export function queueCommunicationDraft(
  state: GameKnowledge,
  draft: {
    channel: CommunicationChannel;
    target?: string | null;
    text: string;
    reason?: string;
    source?: string;
    expiryTicks?: number;
  },
): boolean {
  const text = clampPolicyText(draft.text, 40);
  if (typeof text !== "string") return false;
  const target = draft.target ?? null;
  if (draft.channel === "whisper" && (!target || !validPolicyName(state, target))) return false;
  if (draft.channel === "shout" && target !== null && !validPolicyName(state, target)) return false;

  const key = `${draft.channel}:${target ?? "*"}:${text}`;
  const lastTick = state.strategy.communication.recentKeys[key];
  if (lastTick !== undefined && state.tick - lastTick < 180) return false;
  state.strategy.communication.recentKeys[key] = state.tick;

  const item: CommunicationDraft = {
    id: `${state.tick}:${key}:${Math.random().toString(36).slice(2, 7)}`,
    channel: draft.channel,
    target,
    text,
    reason: clampPolicyText(draft.reason ?? "strategy", 80) ?? "strategy",
    source: clampPolicyText(draft.source ?? "deterministic", 40) ?? "deterministic",
    writtenTick: state.tick,
    expiryTick: state.tick + Math.max(1, draft.expiryTicks ?? 360),
  };

  if (draft.channel === "shout") {
    state.strategy.communication.shoutQueue.push(item);
    if (state.strategy.communication.shoutQueue.length > 10) state.strategy.communication.shoutQueue.shift();
  } else {
    const queue = state.strategy.communication.whisperQueues[target!] ?? [];
    queue.push(item);
    if (queue.length > 6) queue.shift();
    state.strategy.communication.whisperQueues[target!] = queue;
  }
  pushStrategyTelemetry(state, "communication", "queued", {
    channel: item.channel,
    target: item.target,
    text: item.text,
    reason: item.reason,
    source: item.source,
  });
  return true;
}

export function popNextShoutDraft(state: GameKnowledge): CommunicationDraft | null {
  const queue = state.strategy.communication.shoutQueue.filter(d => d.expiryTick >= state.tick);
  state.strategy.communication.shoutQueue = queue;
  const draft = queue.shift() ?? null;
  if (draft) pushStrategyTelemetry(state, "communication", "dequeued_shout", { text: draft.text, source: draft.source });
  return draft;
}

export function popNextWhisperDraft(state: GameKnowledge, occupantNames: string[]): CommunicationDraft | null {
  for (const name of occupantNames) {
    const queue = (state.strategy.communication.whisperQueues[name] ?? []).filter(d => d.expiryTick >= state.tick);
    state.strategy.communication.whisperQueues[name] = queue;
    const draft = queue.shift() ?? null;
    if (draft) {
      pushStrategyTelemetry(state, "communication", "dequeued_whisper", {
        target: draft.target,
        text: draft.text,
        source: draft.source,
      });
      return draft;
    }
  }
  return null;
}

export function hasColorExchangeSucceeded(state: GameKnowledge, target: string): boolean {
  const player = state.players.get(target);
  return !!state.exchanges.succeededColor[target] || !!player?.theyRevealedColor || !!player?.knownTeam;
}

export function hasRoleExchangeSucceeded(state: GameKnowledge, target: string): boolean {
  const player = state.players.get(target);
  return !!state.exchanges.succeededRole[target] || !!player?.weSharedWith;
}

export function markColorExchangeSucceeded(state: GameKnowledge, target: string, source = "task"): string {
  const pb = state.players.get(target);
  if (pb) pb.theyRevealedColor = true;
  if (!state.exchanges.succeededColor[target]) {
    state.exchanges.succeededColor[target] = { target, tick: state.tick, source };
    pushStrategyTelemetry(state, "exchange", "color_succeeded", { target, source });
  }
  return pb?.knownTeam
    ? `color exchange complete — ${target} is ${pb.knownTeam}`
    : `color exchange complete — ${target} color info marked known`;
}

export function markRoleExchangeSucceeded(state: GameKnowledge, target: string, source = "task"): string {
  const pb = state.players.get(target);
  if (pb) {
    pb.weSharedWith = true;
    pb.theyRevealedCard = true;
  }
  if (!state.exchanges.succeededRole[target]) {
    state.exchanges.succeededRole[target] = { target, tick: state.tick, source };
    pushStrategyTelemetry(state, "exchange", "role_succeeded", { target, source });
  }
  return pb?.knownRole
    ? `role exchange complete — ${target} is ${pb.knownRole}`
    : `role exchange complete — ${target} role share marked known`;
}

function validateMeetPoint(state: GameKnowledge, value: unknown): MeetPoint | null | undefined {
  if (value === null) return null;
  if (!value || typeof value !== "object") return undefined;
  const obj = value as Record<string, unknown>;
  if (typeof obj.x !== "number" || typeof obj.y !== "number") return undefined;
  if (obj.x < 0 || obj.y < 0 || obj.x >= state.matchFacts.roomW || obj.y >= state.matchFacts.roomH) return undefined;
  return {
    x: Math.round(obj.x),
    y: Math.round(obj.y),
    reason: clampPolicyText(obj.reason, 80) ?? "policy",
    tick: typeof obj.tick === "number" ? Math.round(obj.tick) : state.tick,
  };
}

function validatePolicyPatch(state: GameKnowledge, raw: Partial<ResolvedPolicy>): Partial<ResolvedPolicy> {
  const out: Partial<ResolvedPolicy> = {};
  const boolKeys = [
    "keepGlobalCheckActive", "autoGrantEntry", "acceptRoleOffers", "acceptLeaderOffers", "autoAcceptColorOffer", "exitCurrentWhisper",
    "autoOfferColorExchange", "autoOfferRoleExchange", "shoutInviteWhenHostingAlone", "choosePsychopompFallback", "maybeUsurpFallback", "shouldUsurp",
  ] as const;
  for (const key of boolKeys) {
    if (typeof raw[key] === "boolean") out[key] = raw[key];
  }
  if (typeof raw.globalCheckIntervalTicks === "number") {
    out.globalCheckIntervalTicks = Math.max(24, Math.min(240, Math.round(raw.globalCheckIntervalTicks)));
  }
  if (typeof raw.hostPrivateSpotProbability === "number") {
    out.hostPrivateSpotProbability = Math.max(0, Math.min(1, raw.hostPrivateSpotProbability));
  }
  if (typeof raw.goToVisiblePlayerProbability === "number") {
    out.goToVisiblePlayerProbability = Math.max(0, Math.min(1, raw.goToVisiblePlayerProbability));
  }

  const color = validateNameArray(state, raw.pursueColorExchangeWithPlayer, true);
  if (color) out.pursueColorExchangeWithPlayer = color;
  const role = validateNameArray(state, raw.pursueRoleExchangeWithPlayer);
  if (role) out.pursueRoleExchangeWithPlayer = role;
  const avoid = validateNameArray(state, raw.avoidPlayers);
  if (avoid) out.avoidPlayers = avoid;
  const deny = validateNameArray(state, raw.autoGrantDenyPlayers);
  if (deny) out.autoGrantDenyPlayers = deny;
  const colorDeny = validateNameArray(state, raw.autoOfferColorDenyPlayers);
  if (colorDeny) out.autoOfferColorDenyPlayers = colorDeny;
  const psychopomps = validateNameArray(state, raw.psychopompTargets, true);
  if (psychopomps) out.psychopompTargets = psychopomps;

  if (raw.usurpTarget === null) out.usurpTarget = null;
  else if (typeof raw.usurpTarget === "string" && state.players.has(raw.usurpTarget)) out.usurpTarget = raw.usurpTarget;

  const meetPoint = validateMeetPoint(state, raw.meetPoint);
  if (meetPoint !== undefined) out.meetPoint = meetPoint;

  const shoutNext = clampPolicyText(raw.shoutNext, 40);
  if (shoutNext !== undefined) out.shoutNext = shoutNext;

  if (raw.prefetchedWhisper === null) {
    out.prefetchedWhisper = null;
  } else if (raw.prefetchedWhisper && typeof raw.prefetchedWhisper === "object") {
    const pf = raw.prefetchedWhisper as PrefetchedWhisper;
    const message = clampPolicyText(pf.message, 40);
    if (validPolicyName(state, pf.target) && typeof message === "string") {
      out.prefetchedWhisper = { target: pf.target, message, tick: typeof pf.tick === "number" ? pf.tick : state.tick };
    }
  }

  if (raw.whisperActionNext === null) out.whisperActionNext = null;
  else if (["ROLE", "C.OFFER", "C.UNOFFR", "R.OFFER", "R.UNOFFR", "PASS", "TAKE", "GRANT"].includes(raw.whisperActionNext as string)) {
    out.whisperActionNext = raw.whisperActionNext;
  }

  if (raw.pursueModeHints && typeof raw.pursueModeHints === "object") {
    const hints: Record<string, PursueModeHint> = {};
    for (const [key, hint] of Object.entries(raw.pursueModeHints)) {
      const [target, exchange] = key.split(":");
      if (!validPolicyName(state, target) || (exchange !== "color" && exchange !== "role")) continue;
      if (!hint || typeof hint !== "object") continue;
      const h = hint as PursueModeHint;
      if (h.mode !== "find_spot" && h.mode !== "go_to_player" && h.mode !== "noop") continue;
      hints[key] = {
        mode: h.mode,
        reason: clampPolicyText(h.reason, 120) ?? "policy",
        tick: typeof h.tick === "number" ? h.tick : state.tick,
      };
    }
    out.pursueModeHints = hints;
  }

  const notes = clampPolicyText(raw.strategyNotes, 240);
  if (notes !== undefined) out.strategyNotes = notes ?? "";
  out.lastUpdatedTick = state.tick;
  return out;
}

export function writePolicyPatch(
  state: GameKnowledge,
  source: string,
  rawPatch: Partial<ResolvedPolicy>,
  expiryTicks = 300,
): boolean {
  const patch = validatePolicyPatch(state, rawPatch);
  if (Object.keys(patch).length === 0) return false;
  state.policy.patches.push({
    source,
    writtenTick: state.tick,
    expiryTick: expiryTicks > 0 ? state.tick + expiryTicks : undefined,
    patch,
  });
  if (state.policy.patches.length > 20) state.policy.patches.splice(0, state.policy.patches.length - 20);
  resolvePolicy(state);
  return true;
}

function applyPolicy(base: ResolvedPolicy, patch: Partial<ResolvedPolicy>): ResolvedPolicy {
  return {
    ...base,
    ...patch,
    pursueColorExchangeWithPlayer: patch.pursueColorExchangeWithPlayer
      ? mergeUnique(base.pursueColorExchangeWithPlayer, patch.pursueColorExchangeWithPlayer)
      : [...base.pursueColorExchangeWithPlayer],
    pursueRoleExchangeWithPlayer: patch.pursueRoleExchangeWithPlayer
      ? mergeUnique(base.pursueRoleExchangeWithPlayer, patch.pursueRoleExchangeWithPlayer)
      : [...base.pursueRoleExchangeWithPlayer],
    avoidPlayers: patch.avoidPlayers ? mergeUnique(base.avoidPlayers, patch.avoidPlayers) : [...base.avoidPlayers],
    autoGrantDenyPlayers: patch.autoGrantDenyPlayers ? mergeUnique(base.autoGrantDenyPlayers, patch.autoGrantDenyPlayers) : [...base.autoGrantDenyPlayers],
    autoOfferColorDenyPlayers: patch.autoOfferColorDenyPlayers ? mergeUnique(base.autoOfferColorDenyPlayers, patch.autoOfferColorDenyPlayers) : [...base.autoOfferColorDenyPlayers],
    psychopompTargets: patch.psychopompTargets ? [...patch.psychopompTargets] : base.psychopompTargets ? [...base.psychopompTargets] : null,
    pursueModeHints: patch.pursueModeHints ? { ...base.pursueModeHints, ...patch.pursueModeHints } : { ...base.pursueModeHints },
  };
}

function mergeUnique(base: string[], patch: string[]): string[] {
  return Array.from(new Set([...base, ...patch]));
}

export function resolvePolicy(state: GameKnowledge): ResolvedPolicy {
  state.policy.patches = state.policy.patches.filter(p => !p.expiryTick || p.expiryTick >= state.tick);
  let resolved: ResolvedPolicy = applyPolicy(defaultResolvedPolicy(), state.policy.baseline);
  for (const patch of state.policy.patches) {
    const valid = validatePolicyPatch(state, patch.patch);
    if (Object.keys(valid).length > 0) resolved = applyPolicy(resolved, valid);
  }
  resolved.lastUpdatedTick = state.tick;
  state.policy.resolved = resolved;
  return resolved;
}

function parseRendezvousText(state: GameKnowledge, sender: SenderIdentity, text: string, tick: number): RendezvousOffer | null {
  if (state.myRoom === null) return null;
  const upper = text.toUpperCase();
  if (!/\b(MEET|COME|OMW)\b|@|<\s*\d/.test(upper)) return null;
  const coord = text.match(/(?:@|<)\s*(\d{1,3})\s*,\s*(\d{1,3})\s*>?/);
  if (!coord) return null;
  const x = Number(coord[1]);
  const y = Number(coord[2]);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
  if (x < 0 || y < 0 || x >= state.matchFacts.roomW || y >= state.matchFacts.roomH) return null;

  let intendedTarget: string | null = null;
  for (const token of text.toUpperCase().split(/[^A-Z.]+/)) {
    if (token && state.players.has(token)) {
      const target = state.players.get(token)!;
      if (target.lastRoom !== null && target.lastRoom !== state.myRoom) return null;
      intendedTarget = token;
      break;
    }
  }

  return {
    sender,
    intendedTarget,
    coords: { x, y },
    room: state.myRoom,
    tick,
    expiryTick: tick + 300,
    sourceText: text.slice(0, 80),
    acknowledged: false,
    ackTick: -1,
  };
}

function updateRendezvousOffers(state: GameKnowledge): void {
  const seen = new Set(state.messages.rendezvousOffers.map(o => `${o.tick}:${o.sender.name}:${o.sourceText}`));
  const offers = state.messages.rendezvousOffers.filter(o => o.expiryTick >= state.tick);

  const newOffers: RendezvousOffer[] = [];

  for (const shout of state.shoutLog.slice(-8)) {
    const sender = senderIdentity(state, shout.senderColor, null);
    const offer = parseRendezvousText(state, sender, shout.text, shout.tick);
    if (offer) {
      const key = `${offer.tick}:${offer.sender.name}:${offer.sourceText}`;
      if (!seen.has(key)) {
        offers.push(offer);
        newOffers.push(offer);
        seen.add(key);
      }
    }
  }

  for (const msg of state.whisperMessages) {
    if (msg.type !== "text") continue;
    const sender = senderIdentity(state, msg.senderColor, msg.senderShape);
    const offer = parseRendezvousText(state, sender, msg.text, state.tick);
    if (offer) {
      const key = `${offer.tick}:${offer.sender.name}:${offer.sourceText}`;
      if (!seen.has(key)) {
        offers.push(offer);
        newOffers.push(offer);
        seen.add(key);
      }
    }
  }

  // Detect acks: if a new offer's coordinates match an existing offer we sent,
  // and the new sender is the intended target (or any responder), mark acknowledged.
  const COORD_TOLERANCE = 4;
  for (const newOffer of newOffers) {
    for (const existing of offers) {
      if (existing === newOffer) continue;
      if (existing.acknowledged) continue;
      if (existing.sender.name === newOffer.sender.name) continue;
      const dx = Math.abs(existing.coords.x - newOffer.coords.x);
      const dy = Math.abs(existing.coords.y - newOffer.coords.y);
      if (dx <= COORD_TOLERANCE && dy <= COORD_TOLERANCE) {
        // The new message references the same coordinates — treat as ack
        if (existing.sender.name === state.myCharName || existing.intendedTarget === newOffer.sender.name) {
          existing.acknowledged = true;
          existing.ackTick = state.tick;
          pushStrategyTelemetry(state, "communication", "rendezvous_acked", {
            offerSender: existing.sender.name,
            acker: newOffer.sender.name,
            coords: existing.coords,
          });
        }
      }
    }
  }

  state.messages.rendezvousOffers = offers.slice(-12);
}

function updateExchangeSuccessFromFacts(state: GameKnowledge): void {
  const roleFollowupTicks = 20 * TARGET_FPS;
  for (const name of state.occupantNames) {
    const pb = state.players.get(name);
    if (pb?.theyRevealedColor || pb?.knownTeam) markColorExchangeSucceeded(state, name, "facts");
    if (pb?.weSharedWith) markRoleExchangeSucceeded(state, name, "facts");
  }

  const systemMessages = state.whisperMessages.filter(m => m.type === "system");
  for (const msg of systemMessages) {
    const text = msg.text.toUpperCase();
    if (text.includes("SHOWED") && text.includes("ROLE") && msg.senderShape !== null && msg.senderColor !== 0) {
      const revealer = getOrCreatePlayerKnowledge(state, msg.senderColor, msg.senderShape);
      if (revealer.name !== state.myCharName && !revealer.theyRevealedCard) {
        revealer.theyRevealedCard = true;
        requestReactiveInfoCheck(state, "role_showed_system_message");
      }
    }

    const sender = msg.senderShape !== null ? characterName(msg.senderColor, msg.senderShape) : null;
    if (sender !== state.myCharName) continue;
    if (text.includes("OFFERED") && text.includes("COLOR")) state.action.exchange.activeColorOffer = true;
    if (text.includes("WITHDREW") && text.includes("COLOR")) state.action.exchange.activeColorOffer = false;
    if ((text.includes("SWAPPED") && text.includes("COLOR")) || (text.includes("COLOR") && text.includes("XCHG"))) {
      state.action.exchange.activeColorOffer = false;
      state.action.exchange.roleFollowupUntilTick = Math.max(state.action.exchange.roleFollowupUntilTick, state.tick + roleFollowupTicks);
    }
    if (text.includes("OFFERED") && text.includes("ROLE")) state.action.exchange.activeRoleOffer = true;
    if (text.includes("WITHDREW") && text.includes("ROLE")) state.action.exchange.activeRoleOffer = false;
    if ((text.includes("SWAPPED") && text.includes("ROLE")) || (text.includes("ROLE") && text.includes("XCHG"))) state.action.exchange.activeRoleOffer = false;
  }

  const systemTexts = systemMessages.map(m => m.text.toUpperCase());
  if (systemTexts.some(t => (t.includes("SWAPPED") && t.includes("COLOR")) || (t.includes("COLOR") && t.includes("XCHG")))) {
    state.action.exchange.activeColorOffer = false;
    state.action.exchange.roleFollowupUntilTick = Math.max(state.action.exchange.roleFollowupUntilTick, state.tick + roleFollowupTicks);
    let newExchange = false;
    const names = state.occupantNames.length === 1
      ? state.occupantNames
      : state.action.exchange.currentTarget && state.occupantNames.includes(state.action.exchange.currentTarget)
        ? [state.action.exchange.currentTarget]
        : [];
    for (const name of names) {
      const alreadyRecorded = !!state.exchanges.succeededColor[name];
      markColorExchangeSucceeded(state, name, "system_message");
      if (!alreadyRecorded) newExchange = true;
    }
    requestReactiveInfoCheck(state, newExchange ? "color_system_message" : "color_system_message_unattributed");
  }
  if (systemTexts.some(t => (t.includes("SWAPPED") && t.includes("ROLE")) || (t.includes("ROLE") && t.includes("XCHG")))) {
    state.action.exchange.activeRoleOffer = false;
    const names = state.occupantNames.length === 1
      ? state.occupantNames
      : state.action.exchange.currentTarget && state.occupantNames.includes(state.action.exchange.currentTarget)
        ? [state.action.exchange.currentTarget]
        : [];
    let newExchange = false;
    for (const name of names) {
      const alreadyRecorded = !!state.exchanges.succeededRole[name];
      markRoleExchangeSucceeded(state, name, "system_message");
      if (!alreadyRecorded) newExchange = true;
    }
    if (newExchange) requestReactiveInfoCheck(state, "role_system_message");
  }
}

function requestReactiveInfoCheck(state: GameKnowledge, source: string): void {
  if (!state.action.forceInfoCheck) {
    pushStrategyTelemetry(state, "exchange", "info_check_requested", { source });
  }
  state.action.forceInfoCheck = true;
  state.action.lastInfoCheckTick = -Infinity;
  state.action.lastGlobalCheckTick = -Infinity;
}

function runCommunicationOrienter(state: GameKnowledge): void {
  const policy = state.policy.resolved;
  const target = state.action.exchange.currentTarget;
  const canShout = state.phase === "playing" || state.phase === "leader_summit";

  if (canShout && policy.shoutNext) {
    queueCommunicationDraft(state, {
      channel: "shout",
      text: policy.shoutNext,
      source: "policy",
      reason: "policy shout",
      expiryTicks: 240,
    });
  }

  if (canShout && target && state.myPos && state.action.exchange.currentExchangeMode === "find_spot") {
    queueCommunicationDraft(state, {
      channel: "shout",
      target,
      text: `${target} COME @ ${Math.round(state.myPos.x)},${Math.round(state.myPos.y)}`,
      source: "communication_orienter",
      reason: "private spot invite",
      expiryTicks: 240,
    });
  }

  if (canShout && target && state.action.exchange.currentExchange !== "whisper") {
    queueCommunicationDraft(state, {
      channel: "shout",
      target,
      text: `${target} XCHG?`,
      source: "communication_orienter",
      reason: "exchange invite",
      expiryTicks: 240,
    });
  }

  // Ack rendezvous offers targeting us when we intend to go there
  if (canShout && state.myCharName) {
    const pendingOffers = state.messages.rendezvousOffers.filter(o =>
      o.expiryTick >= state.tick
      && o.room === state.myRoom
      && o.sender.name !== state.myCharName
      && !o.acknowledged
      && (o.intendedTarget === null || o.intendedTarget === state.myCharName)
    );
    for (const offer of pendingOffers) {
      const weArePursuing = target === offer.sender.name
        || policy.pursueColorExchangeWithPlayer.includes(offer.sender.name)
        || policy.pursueRoleExchangeWithPlayer.includes(offer.sender.name);
      if (weArePursuing) {
        queueCommunicationDraft(state, {
          channel: "shout",
          target: offer.sender.name,
          text: `${offer.sender.name} OMW @ ${Math.round(offer.coords.x)},${Math.round(offer.coords.y)}`,
          source: "communication_orienter",
          reason: "rendezvous ack",
          expiryTicks: 180,
        });
      }
    }
  }

  if (policy.prefetchedWhisper) {
    queueCommunicationDraft(state, {
      channel: "whisper",
      target: policy.prefetchedWhisper.target,
      text: policy.prefetchedWhisper.message,
      source: "focused_llm",
      reason: "prefetched whisper",
      expiryTicks: Math.max(1, policy.prefetchedWhisper.tick + 300 - state.tick),
    });
  }
}

export function writeDeterministicBaselinePolicy(state: GameKnowledge): ResolvedPolicy {
  const baseline = defaultResolvedPolicy();
  baseline.lastUpdatedTick = state.tick;
  baseline.autoGrantEntry = true;
  baseline.autoAcceptColorOffer = true;
  baseline.autoOfferColorExchange = true;
  baseline.keepGlobalCheckActive = true;
  baseline.acceptLeaderOffers = keyPartnerRoleName(state.myRole) === null;
  if (state.myCharName && state.players.has(state.myCharName)) {
    baseline.shouldUsurp = true;
    baseline.usurpTarget = state.myCharName;
  }

  const partnerRole = keyPartnerRoleName(state.myRole);
  for (const player of state.players.values()) {
    if (player.name === state.myCharName) continue;

    const knownEnemy = !!player.knownTeam && !!state.myTeam && player.knownTeam !== state.myTeam;
    if (knownEnemy) {
      baseline.autoGrantDenyPlayers.push(player.name);
      baseline.autoOfferColorDenyPlayers.push(player.name);
    }

    if (!knownEnemy && !hasColorExchangeSucceeded(state, player.name)) {
      baseline.pursueColorExchangeWithPlayer.push(player.name);
    }

    if (player.lastRoom !== state.myRoom) continue;

    const recentColorFollowup = state.tick <= state.action.exchange.roleFollowupUntilTick
      && hasColorExchangeSucceeded(state, player.name)
      && !knownEnemy;
    const teammate = isKnownTeammate(state, player.name);
    const keyPartner = partnerRole !== null && normalizeRoleName(player.knownRole) === partnerRole;
    if ((teammate || keyPartner || recentColorFollowup) && !hasRoleExchangeSucceeded(state, player.name)) {
      baseline.pursueRoleExchangeWithPlayer.push(player.name);
      baseline.acceptRoleOffers = true;
      baseline.autoOfferRoleExchange = true;
    }
    if (keyPartner && !hasRoleExchangeSucceeded(state, player.name)) {
      baseline.pursueRoleExchangeWithPlayer.push(player.name);
      baseline.acceptRoleOffers = true;
      baseline.autoOfferRoleExchange = true;
    }
  }

  baseline.pursueColorExchangeWithPlayer = Array.from(new Set(baseline.pursueColorExchangeWithPlayer));
  baseline.pursueRoleExchangeWithPlayer = Array.from(new Set(baseline.pursueRoleExchangeWithPlayer));
  baseline.autoGrantDenyPlayers = Array.from(new Set(baseline.autoGrantDenyPlayers));
  baseline.autoOfferColorDenyPlayers = Array.from(new Set(baseline.autoOfferColorDenyPlayers));

  // Sort pursue targets by proximity — nearest first for natural convergence
  if (state.myPos) {
    const sortByDist = (names: string[]) => {
      names.sort((a, b) => {
        const aColor = colorFromCharName(a);
        const bColor = colorFromCharName(b);
        const aDot = aColor !== null ? state.minimapDots.find(d => d.color === aColor && !d.isSelf) : undefined;
        const bDot = bColor !== null ? state.minimapDots.find(d => d.color === bColor && !d.isSelf) : undefined;
        if (!aDot && !bDot) return 0;
        if (!aDot) return 1;
        if (!bDot) return -1;
        const aDist = (aDot.worldX - state.myPos!.x) ** 2 + (aDot.worldY - state.myPos!.y) ** 2;
        const bDist = (bDot.worldX - state.myPos!.x) ** 2 + (bDot.worldY - state.myPos!.y) ** 2;
        return aDist - bDist;
      });
    };
    sortByDist(baseline.pursueColorExchangeWithPlayer);
    sortByDist(baseline.pursueRoleExchangeWithPlayer);
  }

  const validOffer = state.messages.rendezvousOffers
    .filter(o => o.expiryTick >= state.tick)
    .filter(o => o.room === state.myRoom)
    .filter(o => o.sender.name !== state.myCharName)
    .filter(o => o.intendedTarget === null || o.intendedTarget === state.myCharName)
    .sort((a, b) => b.tick - a.tick)[0];
  if (validOffer) {
    baseline.meetPoint = {
      x: validOffer.coords.x,
      y: validOffer.coords.y,
      reason: `rendezvous with ${validOffer.sender.name}`,
      tick: validOffer.tick,
    };
  }

  state.policy.baseline = baseline;
  return resolvePolicy(state);
}

export function runDeterministicDerivedOrienters(state: GameKnowledge): void {
  updateExchangeSuccessFromFacts(state);
  updateRendezvousOffers(state);
  writeDeterministicBaselinePolicy(state);
  runCommunicationOrienter(state);
}

// ---------------------------------------------------------------------------
// Context dump — structured text for the LLM
// ---------------------------------------------------------------------------

export function formatContextDump(state: GameKnowledge, event: TriggerEvent): string {
  const lines: string[] = [];

  lines.push(`EVENT: ${event}`);
  const psychopompFact = psychopompCountForRound(state, state.matchFacts.currentRound);
  const psychopompText = psychopompFact === null ? "UNKNOWN" : `${psychopompFact}`;
  lines.push(`TICK: ${state.tick} | ROUND: ${state.matchFacts.currentRound} | TIME: ~${state.matchFacts.timerSecs}s | INTERFACE: ${state.phase} | ROOM: ${state.matchFacts.roomW}x${state.matchFacts.roomH} | PSYCHOPOMPS THIS ROUND: ${psychopompText}`);
  lines.push("");

  lines.push("MY STATE:");
  const mySpriteName = state.myCharName ?? "UNKNOWN";
  lines.push(`  I am: ${mySpriteName} | Role: ${state.myRole ?? "UNKNOWN"} | Team: ${state.myTeam ?? "UNKNOWN"} | Current Room: ${state.matchFacts.startingRoomName ?? roomStr(state.myRoom)} (the other room is disjoint — players there are unreachable until a psychopomp swap)`);
  if (state.myPos) {
    let leaderStr = state.amLeader ? "yes" : "no";
    if (state.wasStartingLeader && !state.amLeader) leaderStr = "no (was starting leader)";
    lines.push(`  Position: (${state.myPos.x}, ${state.myPos.y}) | Leader: ${leaderStr}`);
  }
  if (state.phase === "leader_summit") {
    lines.push(`  IN LEADER SUMMIT with: ${state.occupantNames.join(", ") || "(other leader)"}. Psychopomps have been selected — you and the other room's leader are in a private whisper to negotiate before the exchange. Chat only — no role/color exchanges, no exit.`);
  } else if (state.phase === "whisper") {
    lines.push(`  IN WHISPER with: ${state.occupantNames.join(", ") || "(alone)"}. pending_role_offer=${state.pendingRoleOffer} pending_color_offer=${state.pendingColorOffer} pending_entry=${state.pendingEntry}${state.pendingEntryName ? ` (${state.pendingEntryName})` : ""}`);
    if (state.pendingEntry) {
      lines.push(`  >>> Another player wants to enter your whisper. Use "grant_entry" to let them in, or ignore to keep them out.`);
    }
    if (state.pendingRoleOffer) {
      lines.push(`  >>> Another occupant has offered a MUTUAL ROLE EXCHANGE. If you accept and they turn out to be your key partner, your team WINS. If they're an enemy you leak your role. Only the two keys (Hades+Cerberus for Shades, Persephone+Demeter for Nymphs) trigger the win.`);
    } else if (state.pendingColorOffer) {
      lines.push(`  >>> Another occupant has offered a COLOR EXCHANGE. color_accept reveals teams to each other (safe, no role info).`);
    }
  } else if (state.phase === "waiting_entry") {
    lines.push(`  WAITING TO ENTER ANOTHER PLAYER'S WHISPER. You requested entry with join. Wait for the owner to grant_entry, or cancel (B button) and move away to start your own.`);
  } else if (state.phase === "psychopomp_select") {
    if (state.amLeader) {
      lines.push(`  PSYCHOPOMP SELECT — you are LEADER. Pick psychopomps to send to the other room. Use precommit_psychopomps task to auto-select, or the game will auto-fill randomly.`);
    } else {
    lines.push(`  PSYCHOPOMP SELECT — waiting for leaders to pick psychopomps. Policy may queue a bounded usurp atomic to change the leader.`);
    }
  } else if (state.phase === "psychopomp_exchange") {
    lines.push(`  PSYCHOPOMP EXCHANGE — selected players are being swapped between rooms. Wait for next round.`);
  }

  // State-specific available actions
  lines.push("");
  lines.push("CURRENT STATE & AVAILABLE ACTIONS:");
  if (state.phase === "playing" || state.phase === "psychopomp_select") {
    lines.push("  State: OVERWORLD (free movement)");
    lines.push("  Activities: walk_to, pursue_player(mode: color|role|whisper|leader). Atomics: shout, chat, whisper actions, bounded usurp, psychopomp precommit.");
    lines.push("  Transitions: → WHISPER (pursue_player reaches target) | → WAITING_ENTRY (near existing whisper)");
  } else if (state.phase === "whisper") {
    lines.push("  State: WHISPER (private conversation)");
    lines.push("  Atomics: chat, exit_whisper, grant/accept/offer actions.");
    lines.push("  Active pursue_player activities will message, auto-offer/accept inside whisper");
    lines.push("  NOTE: Shout/info can be checked from whisper by cycling tabs, but movement remains disabled while in whisper.");
    lines.push("  Transitions: → OVERWORLD (exit_whisper) | → OVERWORLD (round ends — all whispers destroyed)");
  } else if (state.phase === "waiting_entry") {
    lines.push("  State: WAITING_ENTRY (pending whisper entry)");
    lines.push("  Do NOT emit any actions — wait for grant or timeout");
    lines.push("  Transitions: → WHISPER (entry granted) | → OVERWORLD (entry denied or timeout)");
  } else if (state.phase === "leader_summit") {
    lines.push("  State: LEADER_SUMMIT (leaders-only negotiation)");
    lines.push("  Atomics: chat only. No exits, no exchanges.");
    lines.push("  Transitions: → PSYCHOPOMP_EXCHANGE (timer ends)");
  } else {
    lines.push(`  State: ${state.phase.toUpperCase()} — wait for phase to end`);
  }
  lines.push("");

  if (state.nearbyNames.length > 0) {
    lines.push(`NEARBY PLAYERS (in whisper range — open_whisper joins/request-entry if they are in a whisper, otherwise creates your own):`);
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
      const b = playerByColor(state, d.color);
      const name = b ? playerDisplayName(b) : spriteNameFromPaletteColor(d.color);
      return `${name} ~(${d.worldX},${d.worldY})`;
    }).join(" | "));
    lines.push("");
  }

  if (state.shoutLog.length > 0) {
    lines.push("RECENT SHOUTS (room chat — only players in your current room):");
    for (const s of state.shoutLog.slice(-8)) {
      const b = playerByColor(state, s.senderColor);
      const name = b ? playerDisplayName(b) : spriteNameFromPaletteColor(s.senderColor);
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

  const colorDone = Object.keys(state.exchanges.succeededColor);
  const roleDone = Object.keys(state.exchanges.succeededRole);
  if (colorDone.length > 0 || roleDone.length > 0) {
    lines.push("SUCCEEDED EXCHANGES (do not repeat these):");
    if (colorDone.length > 0) lines.push(`  Color: ${colorDone.join(", ")}`);
    if (roleDone.length > 0) lines.push(`  Role: ${roleDone.join(", ")}`);
    lines.push("");
  }

  const shoutDrafts = state.strategy.communication.shoutQueue.filter(d => d.expiryTick >= state.tick);
  const whisperDrafts = Object.values(state.strategy.communication.whisperQueues)
    .flat()
    .filter(d => d.expiryTick >= state.tick);
  if (shoutDrafts.length > 0 || whisperDrafts.length > 0) {
    lines.push("PLANNED COMMUNICATION (policy intent, not received facts):");
    for (const d of shoutDrafts.slice(0, 4)) lines.push(`  shout: "${d.text}" (${d.reason})`);
    for (const d of whisperDrafts.slice(0, 6)) lines.push(`  whisper ${d.target}: "${d.text}" (${d.reason})`);
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

function buildStrategicContext(state: GameKnowledge): string {
  if (!state.myRole || !state.myTeam) {
    return "  Role unknown yet — it is shown at game start.";
  }

  const role = state.myRole.toUpperCase();
  const lines: string[] = [];

  if (role === "HADES") {
    lines.push("  Win: I (Hades) must mutually share cards with Cerberus.");
    const cerb = findKnownByRole(state, "Cerberus");
    lines.push(cerb ? `  Cerberus: FOUND ${playerDisplayName(cerb)}, shared: ${cerb.weSharedWith}` : "  Cerberus: NOT FOUND.");
  } else if (role === "CERBERUS") {
    lines.push("  Win: Hades must mutually share cards with me (Cerberus).");
    const hades = findKnownByRole(state, "Hades");
    lines.push(hades ? `  Hades: FOUND ${playerDisplayName(hades)}, shared: ${hades.weSharedWith}` : "  Hades: NOT FOUND.");
  } else if (role === "PERSEPHONE") {
    lines.push("  Win: I (Persephone) must mutually share cards with Demeter.");
    const dem = findKnownByRole(state, "Demeter");
    lines.push(dem ? `  Demeter: FOUND ${playerDisplayName(dem)}, shared: ${dem.weSharedWith}` : "  Demeter: NOT FOUND.");
  } else if (role === "DEMETER") {
    lines.push("  Win: Persephone must mutually share cards with me (Demeter).");
    const pers = findKnownByRole(state, "Persephone");
    lines.push(pers ? `  Persephone: FOUND ${playerDisplayName(pers)}, shared: ${pers.weSharedWith}` : "  Persephone: NOT FOUND.");
  } else {
    lines.push(`  Win: Help my team (${state.myTeam}) by finding and assisting key roles.`);
  }

  return lines.join("\n");
}

function findKnownByRole(state: GameKnowledge, role: string): PlayerKnowledge | null {
  for (const b of state.players.values()) {
    if (b.knownRole?.toUpperCase() === role.toUpperCase()) return b;
  }
  return null;
}

function trimText(value: unknown, max: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const cleaned = value.replace(/\s+/g, " ").trim();
  if (!cleaned) return undefined;
  return cleaned.slice(0, max);
}

function trimStringArray(value: unknown, maxItems: number, maxChars: number): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value
    .map(v => trimText(v, maxChars))
    .filter((v): v is string => !!v)
    .slice(0, maxItems);
}

export function mergeKnowledgeNotes(current: KnowledgeNotes, raw: unknown, tick: number): KnowledgeNotes {
  if (!raw || typeof raw !== "object") return current;
  const obj = raw as Record<string, unknown>;
  const next: KnowledgeNotes = {
    global: current.global,
    goals: [...current.goals],
    risks: [...current.risks],
    messageNotes: [...current.messageNotes],
    players: { ...current.players },
    updatedTick: tick,
  };

  const global = trimText(obj.global, 300);
  if (global !== undefined) next.global = global;

  const goals = trimStringArray(obj.goals, 6, 120);
  if (goals) next.goals = goals;

  const risks = trimStringArray(obj.risks, 6, 120);
  if (risks) next.risks = risks;

  const messageNotes = trimStringArray(obj.messageNotes, 8, 120);
  if (messageNotes) next.messageNotes = messageNotes;

  if (obj.players && typeof obj.players === "object") {
    for (const [name, value] of Object.entries(obj.players as Record<string, unknown>)) {
      if (!value || typeof value !== "object") continue;
      const p = value as Record<string, unknown>;
      const existing = next.players[name] ?? { updatedTick: tick };
      next.players[name] = {
        ...existing,
        summary: trimText(p.summary, 160) ?? existing.summary,
        trust: p.trust === "ally" || p.trust === "enemy" || p.trust === "unknown" || p.trust === "mixed"
          ? p.trust
          : existing.trust,
        wants: trimText(p.wants, 120) ?? existing.wants,
        warnings: trimText(p.warnings, 120) ?? existing.warnings,
        updatedTick: tick,
      };
    }
  }

  return next;
}

export function formatNotes(notes: KnowledgeNotes): string {
  return JSON.stringify(notes, null, 2);
}

export function updateDecisionMemory(
  state: GameKnowledge,
  area: "exchange" | "psychopomp" | "usurp" | "messageInterpretation",
  summary: string,
): void {
  state.llmNotes.decisions[area] = { summary: summary.slice(0, 240), updatedTick: state.tick };
}

export function updatePursueDecisionMemory(
  state: GameKnowledge,
  key: string,
  summary: string,
): void {
  state.llmNotes.decisions.pursue[key] = { summary: summary.slice(0, 240), updatedTick: state.tick };
}

export function roomName(room: Room | null): string {
  if (room === Room.RoomA) return "Underworld";
  if (room === Room.RoomB) return "Mortal Realm";
  return "UNKNOWN";
}

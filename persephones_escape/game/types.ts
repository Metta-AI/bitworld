export type uint8 = number;

export enum Phase {
  Lobby,
  RosterReveal,
  RoleReveal,
  Playing,
  PsychopompSelect,
  LeaderSummit,
  PsychopompExchange,
  Reveal,
  GameOver,
}

export enum Team { TeamA, TeamB }
export enum Role {
  Hades,
  Persephone,
  Cerberus,
  Demeter,
  Shades,
  Nymphs,
  Spy,
  EchoOfHades,
  EchoOfPersephone,
  EchoOfCerberus,
  EchoOfDemeter,
}
export enum Room { RoomA, RoomB, LeaderRoom }

export enum PlayerShape { Circle, Square, Triangle, Diamond, Star, Cross, XShape, Heart, Crescent, Bolt, Hourglass, Ring }

export interface InputState {
  up: boolean;
  down: boolean;
  left: boolean;
  right: boolean;
  select: boolean;
  attack: boolean;
  b: boolean;
}

export interface Obstacle {
  x: number;
  y: number;
  w: number;
  h: number;
  room: Room;
}

export interface Player {
  name: string;
  x: number;
  y: number;
  velX: number;
  velY: number;
  carryX: number;
  carryY: number;
  room: Room;
  team: Team;
  role: Role;
  shape: PlayerShape;
  isLeader: boolean;
  isPsychopomp: boolean;
  selectedAsPsychopomp: boolean;
  revealedTo: Set<number>;
  sharedWith: Set<number>;
  colorRevealedTo: Set<number>;
  colorIndex: number;
  whisperMenuOpen: boolean;
  whisperMenuCat: number;
  whisperMenuItem: number;
  shareSelectOpen: boolean;
  shareSelectRow: number;
  shareSelectMode: "card" | "color";
  infoScreen: "none" | "role" | "shared";
  infoScrollOffset: number;
  usurpVote: number;
  inWhisper: number;
  whisperEntryTick: number;
  whisperScrollOffset: number;
  pendingWhisperEntry: number;
  shoutOpen: boolean;
  shoutLastRead: number;
  shoutScroll: number;
  shoutActionRow: number;
  noticeText: string | null;
  noticeUntilTick: number;
  roomEntryTick: number;
  lastActionTicks: Map<string, number>;
}

export interface ShoutMessage {
  playerIndex: number;
  color: uint8;
  text: string;
  room: Room;
  tick: number;
}

export interface WhisperMessage {
  type: 'text' | 'system';
  senderIndex: number;
  tick: number;
  text: string;
}

export interface Whisper {
  id: number;
  room: Room;
  ownerIndex: number;
  x: number;
  y: number;
  occupants: Set<number>;
  pendingEntry: number[];
  pendingEntryTicks: number[];
  messages: WhisperMessage[];
  revealOffers: Set<number>;
  colorOffers: Set<number>;
  leaderOffer: number;
}

export interface RoleEntry {
  role: Role;
  team: Team;
  count: number;
}

export interface RoundConfig {
  durationSecs: number;
  psychopomps: number;
}

export interface GameConfig {
  roles: RoleEntry[];
  rounds: RoundConfig[];
  /** Number of obstacles per room. If undefined, auto-scales with player count. Use 0 to disable. */
  obstacleCount?: number;
  /** Max characters per line of a chat message. Messages longer than this wrap to the next line. */
  chatMaxCharsPerLine?: number;
  /** Per-action rate limits in ticks. Keys are action names (e.g. "chat", "C.OFFER", "EXIT").
   *  "_default" sets the fallback for unlisted actions. */
  actionRateLimits?: Record<string, number>;
  /** If set, players whose name starts with this prefix all start in RoomA together (useful for testing). */
  groupNamePrefixInRoomA?: string;
  /** If true, whisper entry requests are auto-granted (useful for testing). */
  autoGrantWhisperEntry?: boolean;
  /** If true, use short phase timers for automated certification/smoke runs. */
  fastTimers?: boolean;
}

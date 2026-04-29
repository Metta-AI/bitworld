export type uint8 = number;

export enum Phase {
  Lobby,
  RoleReveal,
  Playing,
  HostageSelect,
  HostageExchange,
  Reveal,
  GameOver,
}

export enum Team { TeamA, TeamB, Gambler }
export enum Role { Hades, Persephone, Cerberus, Demeter, Shades, Nymphs, Gambler }
export enum Room { RoomA, RoomB }

export enum PlayerShape { Square, Diamond, Triangle, Circle, Cross, Star }

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
  isHostage: boolean;
  selectedAsHostage: boolean;
  revealedTo: Set<number>;
  colorRevealedTo: Set<number>;
  colorIndex: number;
  shareOfferTarget: number;
  shareOfferTick: number;
  leaderOfferTarget: number;
  leaderOfferTick: number;
  menuOpen: boolean;
  menuCol: number;
  menuRow: number;
  infoScreen: "none" | "role" | "shared";
  usurpVote: number;
}

export interface ChatMessage {
  playerIndex: number;
  color: uint8;
  text: string;
  room: Room;
  tick: number;
}

export interface RoleEntry {
  role: Role;
  team: Team;
  count: number | "fill";
}

export interface RoundConfig {
  durationSecs: number;
  hostages: number;
}

export interface GameConfig {
  minPlayers: number;
  maxPlayers: number;
  roles: RoleEntry[];
  rounds: RoundConfig[];
}

import { type uint8, PlayerShape, Role, Team, type GameConfig } from "./types.js";
import { SPRITES } from "../common/sprites.js";

// Parameterized names — change these to retheme
export const GAME_NAME = "Persephone's Escape";

export const TEAM_A_NAME = "Shades";
export const TEAM_B_NAME = "Nymphs";
export const TEAM_A_COLOR: uint8 = 3;
export const TEAM_B_COLOR: uint8 = 14;

export const HADES_ROLE_NAME = "Hades";
export const PERSEPHONE_ROLE_NAME = "Persephone";
export const CERBERUS_ROLE_NAME = "Cerberus";
export const DEMETER_ROLE_NAME = "Demeter";
export const SHADES_ROLE_NAME = `${TEAM_A_NAME}`;
export const NYMPHS_ROLE_NAME = `${TEAM_B_NAME}`;


export const ROOM_A_NAME = "Underworld";
export const ROOM_B_NAME = "Mortal Realm";

export const LEADER_A_NAME = "Nether Leader";
export const LEADER_B_NAME = "Mortal Leader";

// Bitworld protocol
export const SCREEN_WIDTH = 128;
export const SCREEN_HEIGHT = 128;
export const PROTOCOL_BYTES = (SCREEN_WIDTH * SCREEN_HEIGHT) / 2;
export const PACKET_INPUT = 0;
export const INPUT_PACKET_BYTES = 2;

export const BUTTON_UP = 1 << 0;
export const BUTTON_DOWN = 1 << 1;
export const BUTTON_LEFT = 1 << 2;
export const BUTTON_RIGHT = 1 << 3;
export const BUTTON_SELECT = 1 << 4;
export const BUTTON_A = 1 << 5;
export const BUTTON_B = 1 << 6;

export const PACKET_CHAT = 1;

// Movement physics (AmongThem port)
export const MOTION_SCALE = 256;
export const ACCEL = 76;
export const FRICTION_NUM = 144;
export const FRICTION_DEN = 256;
export const MAX_SPEED = 704;
export const STOP_THRESHOLD = 8;

// Game
export const TARGET_FPS = 24;

export const PLAYER_W = 7;
export const PLAYER_H = 7;

const ROOM_SIZE_TABLE: [number, number, number][] = [
  // [maxPlayers, roomSize, obstaclesPerRoom]
  [8,  100, 4],
  [11, 120, 5],
  [14, 140, 7],
  [17, 160, 9],
  [20, 180, 11],
  [24, 200, 14],
];

export function roomSizeForPlayers(n: number): number {
  for (const [max, size] of ROOM_SIZE_TABLE) {
    if (n <= max) return size;
  }
  return ROOM_SIZE_TABLE[ROOM_SIZE_TABLE.length - 1][1];
}

export function obstaclesForPlayers(n: number): number {
  for (const [max, , obs] of ROOM_SIZE_TABLE) {
    if (n <= max) return obs;
  }
  return ROOM_SIZE_TABLE[ROOM_SIZE_TABLE.length - 1][2];
}

export const ROOM_W = ROOM_SIZE_TABLE[ROOM_SIZE_TABLE.length - 1][1];
export const ROOM_H = ROOM_W;

export const OBSTACLE_SIZE = 8;

export const BUBBLE_RADIUS = 20;

export const DEFAULT_GAME_CONFIG: GameConfig = {
  roles: [
    { role: Role.Hades, team: Team.TeamA, count: 1 },
    { role: Role.Persephone, team: Team.TeamB, count: 1 },
    { role: Role.Cerberus, team: Team.TeamA, count: 1 },
    { role: Role.Demeter, team: Team.TeamB, count: 1 },
    { role: Role.Shades, team: Team.TeamA, count: 4 },
    { role: Role.Nymphs, team: Team.TeamB, count: 4 },
  ],
  rounds: [
    { durationSecs: 15, hostages: 1 },
    { durationSecs: 15, hostages: 1 },
    { durationSecs: 15, hostages: 1 },
  ],
};

export function playerCountFromConfig(cfg: GameConfig): number {
  return cfg.roles.reduce((sum, r) => sum + r.count, 0);
}

export const LOBBY_WAIT_TICKS = 5 * TARGET_FPS;

// Chat messages are split across up to CHAT_MAX_LINES lines of CHAT_MAX_CHARS_PER_LINE each.
// Messages longer than CHAT_MAX_TOTAL characters are truncated.
export const CHAT_MAX_CHARS_PER_LINE = 18;
export const CHAT_MAX_LINES = 2;
export const CHAT_MAX_TOTAL = CHAT_MAX_CHARS_PER_LINE * CHAT_MAX_LINES;

export const ACTION_RATE_LIMIT_TICKS = 2 * TARGET_FPS;
export const CHATROOM_MAX_OCCUPANTS = 4;
export const ENTRY_REQUEST_TIMEOUT = 10 * TARGET_FPS;

export const SHADOW_MAP: uint8[] = [0, 12, 9, 5, 5, 0, 5, 5, 5, 12, 9, 9, 0, 12, 12, 9];

export const MINIMAP_SIZE = 20;
export const MINIMAP_X = SCREEN_WIDTH - MINIMAP_SIZE - 2;
export const MINIMAP_Y = 2;

export const BOTTOM_BAR_H = 9;

// 8 colors maximizing perceptual distance across hue and brightness.
// Palette: 3=red, 14=sky blue, 8=yellow, 10=dark green, 7=orange, 9=dark purple, 11=bright green, 12=dark blue
export const PLAYER_COLORS: uint8[] = [3, 14, 8, 10, 7, 9, 11, 12];

export const COLOR_NAMES: Record<number, string> = {
  3: "RED", 14: "BLUE", 8: "YELLOW", 10: "GREEN", 7: "ORANGE", 9: "PURPLE", 11: "LIME", 12: "NAVY",
};

export const COLOR_LETTERS: Record<number, string> = {
  3: "R", 14: "B", 8: "Y", 10: "G", 7: "O", 9: "P", 11: "L", 12: "N",
};

export const SHAPE_NAMES: Record<PlayerShape, string> = {
  [PlayerShape.Circle]: "CRCL",
  [PlayerShape.Square]: "SQR",
  [PlayerShape.Triangle]: "TRI",
  [PlayerShape.Diamond]: "DMOND",
  [PlayerShape.Star]: "STAR",
  [PlayerShape.Cross]: "CROSS",
  [PlayerShape.XShape]: "X",
  [PlayerShape.Heart]: "HEART",
  [PlayerShape.Crescent]: "MOON",
  [PlayerShape.Bolt]: "BOLT",
  [PlayerShape.Hourglass]: "GLASS",
  [PlayerShape.Ring]: "RING",
};

export function playerSpriteName(colorIndex: number): string {
  const paletteColor = PLAYER_COLORS[colorIndex % PLAYER_COLORS.length];
  const shape = colorIndex % (Object.keys(PlayerShape).length / 2) as PlayerShape;
  return `${COLOR_LETTERS[paletteColor] ?? "?"} ${SHAPE_NAMES[shape] ?? "?"}`;
}

export function spriteNameFromPaletteColor(paletteColor: number): string {
  return COLOR_NAMES[paletteColor] ?? `COLOR${paletteColor}`;
}

export const PLAYER_SHAPES: Record<PlayerShape, number[][]> = {
  [PlayerShape.Circle]:    SPRITES.circle,
  [PlayerShape.Square]:    SPRITES.square,
  [PlayerShape.Triangle]:  SPRITES.triangle,
  [PlayerShape.Diamond]:   SPRITES.diamond,
  [PlayerShape.Star]:      SPRITES.star,
  [PlayerShape.Cross]:     SPRITES.cross,
  [PlayerShape.XShape]:    SPRITES.xShape,
  [PlayerShape.Heart]:     SPRITES.heart,
  [PlayerShape.Crescent]:  SPRITES.crescent,
  [PlayerShape.Bolt]:      SPRITES.bolt,
  [PlayerShape.Hourglass]: SPRITES.hourglass,
  [PlayerShape.Ring]:      SPRITES.ring,
};

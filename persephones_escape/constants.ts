import { type uint8, PlayerShape, Role, Team, type GameConfig } from "./types.js";

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

export const ROOM_W = 240;
export const ROOM_H = 240;

export const OBSTACLE_SIZE = 8;
export const OBSTACLES_PER_ROOM = 6;

export const BUBBLE_RADIUS = 20;

export const DEFAULT_GAME_CONFIG: GameConfig = {
  minPlayers: 6,
  maxPlayers: 16,
  roles: [
    { role: Role.Hades, team: Team.TeamA, count: 1 },
    { role: Role.Persephone, team: Team.TeamB, count: 1 },
    { role: Role.Cerberus, team: Team.TeamA, count: 1 },
    { role: Role.Demeter, team: Team.TeamB, count: 1 },
    { role: Role.Shades, team: Team.TeamA, count: "fill" },
    { role: Role.Nymphs, team: Team.TeamB, count: "fill" },
  ],
  rounds: [
    { durationSecs: 15, hostages: 1 },
    { durationSecs: 15, hostages: 1 },
    { durationSecs: 15, hostages: 1 },
  ],
};

export const LOBBY_WAIT_TICKS = 5 * TARGET_FPS;
export const CHAT_MAX_CHARS = 48;
export const CHATROOM_MAX_OCCUPANTS = 4;
export const ENTRY_REQUEST_TIMEOUT = 10 * TARGET_FPS;

export const SHADOW_MAP: uint8[] = [0, 12, 9, 5, 5, 0, 5, 5, 5, 12, 9, 9, 0, 12, 12, 9];

export const MINIMAP_SIZE = 20;
export const MINIMAP_X = SCREEN_WIDTH - MINIMAP_SIZE - 2;
export const MINIMAP_Y = 2;

export const BOTTOM_BAR_H = 9;

export const PLAYER_COLORS: uint8[] = [3, 7, 8, 14, 4, 11, 13, 15];

export const PLAYER_SHAPES: Record<PlayerShape, number[][]> = {
  [PlayerShape.Square]: [
    [0,1,1,1,1,1,0],[1,2,2,2,2,2,1],[1,2,2,2,2,2,1],[1,2,2,2,2,2,1],[1,2,2,2,2,2,1],[1,2,2,2,2,2,1],[0,1,1,1,1,1,0],
  ],
  [PlayerShape.Diamond]: [
    [0,0,0,1,0,0,0],[0,0,1,2,1,0,0],[0,1,2,2,2,1,0],[1,2,2,2,2,2,1],[0,1,2,2,2,1,0],[0,0,1,2,1,0,0],[0,0,0,1,0,0,0],
  ],
  [PlayerShape.Triangle]: [
    [0,0,0,1,0,0,0],[0,0,1,2,1,0,0],[0,0,1,2,1,0,0],[0,1,2,2,2,1,0],[0,1,2,2,2,1,0],[1,2,2,2,2,2,1],[1,1,1,1,1,1,1],
  ],
  [PlayerShape.Circle]: [
    [0,0,1,1,1,0,0],[0,1,2,2,2,1,0],[1,2,2,2,2,2,1],[1,2,2,2,2,2,1],[1,2,2,2,2,2,1],[0,1,2,2,2,1,0],[0,0,1,1,1,0,0],
  ],
  [PlayerShape.Cross]: [
    [0,0,1,1,1,0,0],[0,0,1,2,1,0,0],[1,1,1,2,1,1,1],[1,2,2,2,2,2,1],[1,1,1,2,1,1,1],[0,0,1,2,1,0,0],[0,0,1,1,1,0,0],
  ],
  [PlayerShape.Star]: [
    [0,0,0,1,0,0,0],[0,1,1,2,1,1,0],[1,2,2,2,2,2,1],[0,1,2,2,2,1,0],[1,2,2,2,2,2,1],[0,1,1,2,1,1,0],[0,0,0,1,0,0,0],
  ],
};

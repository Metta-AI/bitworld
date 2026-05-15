/**
 * Shared GameConfig presets and JSON config file loader.
 *
 * Presets are named configurations used by both the server and the test
 * harness.  The JSON loader lets operators supply arbitrary configs from
 * a file without touching source.
 */

import { readFileSync } from "fs";
import { Role, Team, type GameConfig } from "./types.js";
import { DEFAULT_GAME_CONFIG } from "./constants.js";

// ---------------------------------------------------------------------------
// Named presets
// ---------------------------------------------------------------------------

/** All built-in config presets, keyed by name. */
export const CONFIGS: Record<string, GameConfig> = {
  default: DEFAULT_GAME_CONFIG,

  fast: DEFAULT_GAME_CONFIG,

  tiny: {
    ...DEFAULT_GAME_CONFIG,
    rounds: [{ durationSecs: 1, psychopomps: 1 }],
  },

  short: {
    ...DEFAULT_GAME_CONFIG,
    rounds: [{ durationSecs: 30, psychopomps: 1 }],
  },

  empty: {
    ...DEFAULT_GAME_CONFIG,
    rounds: [{ durationSecs: 30, psychopomps: 1 }],
    obstacleCount: 0,
  },

  simple: {
    // 6 players (all 4 key roles + 1 Shades + 1 Nymphs), LLMs grouped
    // in RoomA together, no obstacles, 60 s round.
    roles: [
      { role: Role.Hades, team: Team.TeamA, count: 1 },
      { role: Role.Persephone, team: Team.TeamB, count: 1 },
      { role: Role.Cerberus, team: Team.TeamA, count: 1 },
      { role: Role.Demeter, team: Team.TeamB, count: 1 },
      { role: Role.Shades, team: Team.TeamA, count: 1 },
      { role: Role.Nymphs, team: Team.TeamB, count: 1 },
    ],
    rounds: [{ durationSecs: 60, psychopomps: 1 }],
    obstacleCount: 0,
    groupNamePrefixInRoomA: "llm_",
  },

  empty3: {
    ...DEFAULT_GAME_CONFIG,
    rounds: [
      { durationSecs: 45, psychopomps: 2 },
      { durationSecs: 45, psychopomps: 2 },
      { durationSecs: 45, psychopomps: 2 },
    ],
    obstacleCount: 0,
  },

  debug2r: {
    roles: [
      { role: Role.Hades, team: Team.TeamA, count: 1 },
      { role: Role.Persephone, team: Team.TeamB, count: 1 },
      { role: Role.Cerberus, team: Team.TeamA, count: 1 },
      { role: Role.Demeter, team: Team.TeamB, count: 1 },
      { role: Role.Shades, team: Team.TeamA, count: 4 },
      { role: Role.Nymphs, team: Team.TeamB, count: 4 },
    ],
    rounds: [
      { durationSecs: 60, psychopomps: 1 },
      { durationSecs: 60, psychopomps: 1 },
    ],
    obstacleCount: 0,
  },

  medium: {
    ...DEFAULT_GAME_CONFIG,
    rounds: [
      { durationSecs: 180, psychopomps: 1 },
      { durationSecs: 120, psychopomps: 1 },
      { durationSecs: 60, psychopomps: 1 },
    ],
  },

  medium6: {
    roles: [
      { role: Role.Hades, team: Team.TeamA, count: 1 },
      { role: Role.Persephone, team: Team.TeamB, count: 1 },
      { role: Role.Cerberus, team: Team.TeamA, count: 1 },
      { role: Role.Demeter, team: Team.TeamB, count: 1 },
      { role: Role.Shades, team: Team.TeamA, count: 1 },
      { role: Role.Nymphs, team: Team.TeamB, count: 1 },
    ],
    rounds: [
      { durationSecs: 180, psychopomps: 1 },
      { durationSecs: 120, psychopomps: 1 },
      { durationSecs: 60, psychopomps: 1 },
    ],
  },

  medium12: {
    roles: [
      { role: Role.Hades, team: Team.TeamA, count: 1 },
      { role: Role.Persephone, team: Team.TeamB, count: 1 },
      { role: Role.Cerberus, team: Team.TeamA, count: 1 },
      { role: Role.Demeter, team: Team.TeamB, count: 1 },
      { role: Role.Shades, team: Team.TeamA, count: 4 },
      { role: Role.Nymphs, team: Team.TeamB, count: 4 },
    ],
    rounds: [
      { durationSecs: 300, psychopomps: 2 },
      { durationSecs: 240, psychopomps: 2 },
      { durationSecs: 180, psychopomps: 2 },
      { durationSecs: 120, psychopomps: 1 },
      { durationSecs: 60, psychopomps: 1 },
    ],
  },

  medium12_half: {
    roles: [
      { role: Role.Hades, team: Team.TeamA, count: 1 },
      { role: Role.Persephone, team: Team.TeamB, count: 1 },
      { role: Role.Cerberus, team: Team.TeamA, count: 1 },
      { role: Role.Demeter, team: Team.TeamB, count: 1 },
      { role: Role.Shades, team: Team.TeamA, count: 4 },
      { role: Role.Nymphs, team: Team.TeamB, count: 4 },
    ],
    rounds: [
      { durationSecs: 150, psychopomps: 2 },
      { durationSecs: 120, psychopomps: 2 },
      { durationSecs: 90, psychopomps: 2 },
      { durationSecs: 60, psychopomps: 1 },
      { durationSecs: 30, psychopomps: 1 },
    ],
  },

  medium12_3min: {
    roles: [
      { role: Role.Hades, team: Team.TeamA, count: 1 },
      { role: Role.Persephone, team: Team.TeamB, count: 1 },
      { role: Role.Cerberus, team: Team.TeamA, count: 1 },
      { role: Role.Demeter, team: Team.TeamB, count: 1 },
      { role: Role.Shades, team: Team.TeamA, count: 4 },
      { role: Role.Nymphs, team: Team.TeamB, count: 4 },
    ],
    rounds: [
      { durationSecs: 180, psychopomps: 0 },
    ],
  },
};

/**
 * Look up a preset by name.  Throws with a list of available names when
 * the requested preset does not exist.
 */
export function resolveConfigName(name: string): GameConfig {
  const cfg = CONFIGS[name];
  if (cfg) return cfg;

  const available = Object.keys(CONFIGS).join(", ");
  throw new Error(
    `Unknown config preset "${name}". Available presets: ${available}`,
  );
}

// ---------------------------------------------------------------------------
// JSON config file loader
// ---------------------------------------------------------------------------

// Maps used to convert human-readable strings ("Hades", "TeamA") in JSON
// config files to the numeric enum values the engine expects.
const ROLE_BY_NAME: Record<string, Role> = {
  Hades: Role.Hades,
  Persephone: Role.Persephone,
  Cerberus: Role.Cerberus,
  Demeter: Role.Demeter,
  Shades: Role.Shades,
  Nymphs: Role.Nymphs,
  Spy: Role.Spy,
  EchoOfHades: Role.EchoOfHades,
  EchoOfPersephone: Role.EchoOfPersephone,
  EchoOfCerberus: Role.EchoOfCerberus,
  EchoOfDemeter: Role.EchoOfDemeter,
  "Echo of Hades": Role.EchoOfHades,
  "Echo of Persephone": Role.EchoOfPersephone,
  "Echo of Cerberus": Role.EchoOfCerberus,
  "Echo of Demeter": Role.EchoOfDemeter,
};

const TEAM_BY_NAME: Record<string, Team> = {
  TeamA: Team.TeamA,
  TeamB: Team.TeamB,
};

/**
 * Resolve a role value that may be a number (enum ordinal) or a string
 * (enum name).  Throws on unrecognised values.
 */
function resolveRole(raw: unknown, context: string): Role {
  if (typeof raw === "number") {
    if (raw < 0 || raw > Role.EchoOfDemeter || !Number.isInteger(raw)) {
      throw new Error(`${context}: invalid numeric role ${raw} (expected 0-${Role.EchoOfDemeter})`);
    }
    return raw as Role;
  }
  if (typeof raw === "string") {
    const role = ROLE_BY_NAME[raw];
    if (role === undefined) {
      const valid = Object.keys(ROLE_BY_NAME).join(", ");
      throw new Error(`${context}: unknown role "${raw}". Valid roles: ${valid}`);
    }
    return role;
  }
  throw new Error(`${context}: role must be a number or string, got ${typeof raw}`);
}

/**
 * Resolve a team value that may be a number (enum ordinal) or a string
 * (enum name).  Throws on unrecognised values.
 */
function resolveTeam(raw: unknown, context: string): Team {
  if (typeof raw === "number") {
    if (raw !== 0 && raw !== 1) {
      throw new Error(`${context}: invalid numeric team ${raw} (expected 0 or 1)`);
    }
    return raw as Team;
  }
  if (typeof raw === "string") {
    const team = TEAM_BY_NAME[raw];
    if (team === undefined) {
      const valid = Object.keys(TEAM_BY_NAME).join(", ");
      throw new Error(`${context}: unknown team "${raw}". Valid teams: ${valid}`);
    }
    return team;
  }
  throw new Error(`${context}: team must be a number or string, got ${typeof raw}`);
}

/**
 * Load a GameConfig from a JSON file.
 *
 * Role and team values in the JSON may be specified as either their numeric
 * enum ordinals or as human-readable strings (e.g. `"Hades"`, `"TeamA"`).
 *
 * Throws a descriptive error on any validation failure.
 */
export function loadConfigFile(path: string): GameConfig {
  let raw: string;
  try {
    raw = readFileSync(path, "utf-8");
  } catch (err) {
    throw new Error(`Failed to read config file "${path}": ${(err as Error).message}`);
  }

  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch (err) {
    throw new Error(`Failed to parse config file "${path}": ${(err as Error).message}`);
  }

  if (typeof json !== "object" || json === null || Array.isArray(json)) {
    throw new Error(`Config file "${path}": expected a JSON object at the top level`);
  }

  const obj = json as Record<string, unknown>;

  // -- roles (required) -----------------------------------------------------
  if (!Array.isArray(obj.roles) || obj.roles.length === 0) {
    throw new Error(
      `Config file "${path}": "roles" must be a non-empty array`,
    );
  }

  const roles = obj.roles.map((entry: unknown, i: number) => {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      throw new Error(`Config file "${path}": roles[${i}] must be an object`);
    }
    const e = entry as Record<string, unknown>;
    const ctx = `Config file "${path}", roles[${i}]`;

    if (e.role === undefined) throw new Error(`${ctx}: missing "role"`);
    if (e.team === undefined) throw new Error(`${ctx}: missing "team"`);
    if (typeof e.count !== "number" || e.count < 1 || !Number.isInteger(e.count)) {
      throw new Error(`${ctx}: "count" must be a positive integer`);
    }

    return {
      role: resolveRole(e.role, ctx),
      team: resolveTeam(e.team, ctx),
      count: e.count,
    };
  });

  // -- rounds (required) ----------------------------------------------------
  if (!Array.isArray(obj.rounds) || obj.rounds.length === 0) {
    throw new Error(
      `Config file "${path}": "rounds" must be a non-empty array`,
    );
  }

  const rounds = obj.rounds.map((entry: unknown, i: number) => {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      throw new Error(`Config file "${path}": rounds[${i}] must be an object`);
    }
    const e = entry as Record<string, unknown>;
    const ctx = `Config file "${path}", rounds[${i}]`;

    if (typeof e.durationSecs !== "number" || e.durationSecs <= 0) {
      throw new Error(`${ctx}: "durationSecs" must be a positive number`);
    }
    if (typeof e.psychopomps !== "number" || e.psychopomps < 0 || !Number.isInteger(e.psychopomps)) {
      throw new Error(`${ctx}: "psychopomps" must be a non-negative integer`);
    }

    return { durationSecs: e.durationSecs, psychopomps: e.psychopomps };
  });

  // -- optional fields ------------------------------------------------------
  const config: GameConfig = { roles, rounds };

  if (obj.obstacleCount !== undefined) {
    if (typeof obj.obstacleCount !== "number" || !Number.isInteger(obj.obstacleCount) || obj.obstacleCount < 0) {
      throw new Error(`Config file "${path}": "obstacleCount" must be a non-negative integer`);
    }
    config.obstacleCount = obj.obstacleCount;
  }

  if (obj.chatMaxCharsPerLine !== undefined) {
    if (typeof obj.chatMaxCharsPerLine !== "number" || !Number.isInteger(obj.chatMaxCharsPerLine) || obj.chatMaxCharsPerLine < 1) {
      throw new Error(`Config file "${path}": "chatMaxCharsPerLine" must be a positive integer`);
    }
    config.chatMaxCharsPerLine = obj.chatMaxCharsPerLine;
  }

  if (obj.actionRateLimits !== undefined) {
    if (typeof obj.actionRateLimits !== "object" || obj.actionRateLimits === null || Array.isArray(obj.actionRateLimits)) {
      throw new Error(`Config file "${path}": "actionRateLimits" must be an object mapping action names to numbers`);
    }
    for (const [key, val] of Object.entries(obj.actionRateLimits as Record<string, unknown>)) {
      if (typeof val !== "number") {
        throw new Error(`Config file "${path}": actionRateLimits["${key}"] must be a number`);
      }
    }
    config.actionRateLimits = obj.actionRateLimits as Record<string, number>;
  }

  if (obj.groupNamePrefixInRoomA !== undefined) {
    if (typeof obj.groupNamePrefixInRoomA !== "string") {
      throw new Error(`Config file "${path}": "groupNamePrefixInRoomA" must be a string`);
    }
    config.groupNamePrefixInRoomA = obj.groupNamePrefixInRoomA;
  }

  if (obj.autoGrantWhisperEntry !== undefined) {
    if (typeof obj.autoGrantWhisperEntry !== "boolean") {
      throw new Error(`Config file "${path}": "autoGrantWhisperEntry" must be a boolean`);
    }
    config.autoGrantWhisperEntry = obj.autoGrantWhisperEntry;
  }

  if (obj.fastTimers !== undefined) {
    if (typeof obj.fastTimers !== "boolean") {
      throw new Error(`Config file "${path}": "fastTimers" must be a boolean`);
    }
    config.fastTimers = obj.fastTimers;
  }

  return config;
}

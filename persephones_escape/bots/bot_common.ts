import WebSocket from "ws";
import { BUTTON_A, BUTTON_B, BUTTON_SELECT } from "../game/constants.js";
import { Room } from "../game/types.js";
import {
  sendInput, sendChat, truncateChatInput, ActionQueue,
  menuSequence, COMMAND_ACTIONS,
  psychopompSelectSequence,
  moveToward, randomDir, randomPoint, clamp,
  type Point,
} from "./bot_utils.js";
import { whisperMenuSequenceWithTargetPick } from "../game/menu_defs.js";
import { type GameKnowledge } from "./game_knowledge.js";
import type { TaskInstance } from "./tasks.js";

// ---------------------------------------------------------------------------
// CLI argument parser
// ---------------------------------------------------------------------------

export function parseArgs(raw: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < raw.length; i++) {
    if (raw[i].startsWith("--") && i + 1 < raw.length) {
      out[raw[i].slice(2)] = raw[i + 1];
      i++;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Command parsing
// ---------------------------------------------------------------------------

export interface ParsedCommand {
  type: string;
  args: string[];
}

const VALID_COMMANDS = new Set([
  "move_to", "approach_nearest", "wander", "wait",
  "open_whisper", "color_offer", "color_withdraw", "color_accept",
  "show_role", "role_offer", "role_withdraw", "role_accept",
  "exit_whisper", "chat",
  "leader_pass", "leader_take", "grant_entry",
  "info_shared", "start_chat", "shout",
  "select_psychopomps", "commit_psychopomps",
]);

export function parseCommand(line: string, name?: string): ParsedCommand | null {
  let trimmed = line.trim().split("\n")[0].trim();
  trimmed = trimmed.replace(/^```\w*\s*/, "").replace(/```$/, "").trim();
  trimmed = trimmed.replace(/^["'`]|["'`]$/g, "").trim();
  if (!trimmed) return null;
  if (trimmed.toLowerCase().startsWith("chat ")) {
    return { type: "chat", args: [trimmed.slice(5)] };
  }
  if (trimmed.toLowerCase().startsWith("shout ")) {
    return { type: "shout", args: [trimmed.slice(6)] };
  }
  const parts = trimmed.split(/\s+/);
  const type = parts[0].toLowerCase();
  if (VALID_COMMANDS.has(type)) {
    return { type, args: parts.slice(1) };
  }
  for (const word of parts) {
    if (VALID_COMMANDS.has(word.toLowerCase())) {
      if (name) console.log(`[${name}] Extracted command "${word}" from noisy response: ${trimmed}`);
      return { type: word.toLowerCase(), args: [] };
    }
  }
  if (name) console.log(`[${name}] No valid command in: ${trimmed}`);
  return { type: "wander", args: [] };
}

// ---------------------------------------------------------------------------
// Bot controller — shared mutable state for bot frame loops
// ---------------------------------------------------------------------------

export interface BotController {
  ws: WebSocket;
  actions: ActionQueue;
  player: GameKnowledge;
  name: string;
  movementTarget: Point | null;
  wandering: boolean;
  wanderTarget: Point | null;
  wanderTicks: number;
  lastFrame: Uint8Array | null;
  psychopompPrecommit: string[] | null;
  lastSentChat: string | null;
  hasNewIncomingChat: boolean;
  nonInterruptingTasks: TaskInstance[];
}

export { clamp };

export function executeBaseCommand(cmd: ParsedCommand, bot: BotController): boolean {
  const cmdAction = COMMAND_ACTIONS[cmd.type];
  if (cmdAction) {
    // Whisper commands only make sense when we're actually inside a whisper.
    // If we're waiting to enter, the B/arrow inputs will cancel our entry request
    // or walk the world character. Swallow the command.
    if (cmdAction.context === "whisper" && bot.player.phase !== "whisper") {
      console.log(`[${bot.name}] whisper command ${cmd.type} ignored — phase=${bot.player.phase}`);
      return true;
    }
    let seq: number[];
    if (cmdAction.context === "whisper") {
      seq = whisperMenuSequenceWithTargetPick(cmdAction.action);
    } else if (cmd.type === "shout") {
      seq = [BUTTON_SELECT, 0];
    } else if (cmd.type === "info_shared") {
      seq = [BUTTON_B, 0];
    } else {
      const items = cmdAction.context === "info" ? ["open"]
        : [cmdAction.action];
      seq = menuSequence(cmdAction.context, cmdAction.action, items);
    }
    if (seq.length > 0) {
      bot.actions.push(...seq);
      bot.movementTarget = null;
      bot.wandering = false;
      return true;
    }
  }

  switch (cmd.type) {
    case "move_to": {
      const x = parseInt(cmd.args[0]);
      const y = parseInt(cmd.args[1]);
      if (!isNaN(x) && !isNaN(y)) {
        bot.movementTarget = {
          x: clamp(x, 0, bot.player.matchFacts.roomW - 1),
          y: clamp(y, 0, bot.player.matchFacts.roomH - 1),
        };
        bot.wandering = false;
      }
      return true;
    }
    case "open_whisper":
      bot.actions.push(bot.player.nearbyNames.length > 0 ? BUTTON_B : BUTTON_A, 0);
      return true;
    case "chat": {
      const { sent } = truncateChatInput(cmd.args.join(" "));
      if (sent) sendChat(bot.ws, sent);
      return true;
    }
    case "select_psychopomps": {
      const indices = cmd.args.map(s => parseInt(s)).filter(n => !isNaN(n));
      if (indices.length > 0) {
        const eligible = Array.from({ length: 16 }, (_, i) => i);
        bot.actions.push(...psychopompSelectSequence(indices, eligible));
      }
      return true;
    }
    case "commit_psychopomps":
      bot.actions.push(BUTTON_B, 0);
      return true;
    case "wait":
      bot.movementTarget = null;
      bot.wandering = false;
      return true;
    case "wander":
      bot.wandering = true;
      bot.movementTarget = null;
      return true;
  }

  return false;
}

// ---------------------------------------------------------------------------
// Shared frame-loop helpers
// ---------------------------------------------------------------------------

export function tickMovement(bot: BotController): boolean {
  if (bot.movementTarget && bot.player.myPos) {
    const dx = bot.movementTarget.x - bot.player.myPos.x;
    const dy = bot.movementTarget.y - bot.player.myPos.y;
    // Stop within 10 units (close enough to open a whisper)
    if (dx * dx + dy * dy > 100) {
      const mask = moveToward(bot.player.myPos.x, bot.player.myPos.y, bot.movementTarget.x, bot.movementTarget.y);
      if (mask) { sendInput(bot.ws, mask); return true; }
    }
    bot.movementTarget = null;
  }
  return false;
}

export function tickWander(bot: BotController): void {
  if (!bot.wanderTarget || bot.wanderTicks <= 0) {
    bot.wanderTarget = randomPoint(bot.player.myRoom ?? Room.RoomA, bot.player.matchFacts.roomW, bot.player.matchFacts.roomH);
    bot.wanderTicks = 15 + Math.floor(Math.random() * 40);
  }
  bot.wanderTicks--;
  if (bot.player.myPos) {
    const mask = moveToward(bot.player.myPos.x, bot.player.myPos.y, bot.wanderTarget.x, bot.wanderTarget.y);
    sendInput(bot.ws, mask || randomDir());
  } else {
    sendInput(bot.ws, randomDir());
  }
}

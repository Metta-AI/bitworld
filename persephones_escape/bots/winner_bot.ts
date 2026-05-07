/**
 * Winner bot — no LLM, no thought, just hardcoded policy to win.
 *
 * Policy:
 *   1. When phase becomes playing, approach the nearest visible player.
 *   2. When close, open_whisper.
 *   3. Inside whisper, offer a role exchange (role_offer) and also role_accept
 *      any pending offers. If someone offered, accept — the worst case is we
 *      leak our role, the best case is instant team win.
 *
 * Usage:
 *   tsx winner_bot.ts --name winner_1 --url ws://localhost:8080/player
 */

import WebSocket from "ws";
import { argv } from "process";
import {
  TARGET_FPS, BUTTON_A,
} from "../game/constants.js";
import {
  sendInput, PACKED_FRAME_BYTES, unpackFrame, ActionQueue,
  moveToward, randomDir, randomPoint,
  type Point,
} from "./bot_utils.js";
import { Room } from "../game/types.js";
import {
  createGameKnowledge, updatePhase, updatePosition, updateMinimap, updateHud,
} from "./game_knowledge.js";
import {
  parseArgs, executeBaseCommand, tickMovement, tickWander,
  type BotController, type ParsedCommand,
} from "./bot_common.js";

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------

const cliArgs = parseArgs(argv.slice(2));
const botUrl = cliArgs["url"] ?? "ws://localhost:8080/player";
const botName = cliArgs["name"] ?? "winner_bot";

// ---------------------------------------------------------------------------
// Bot state
// ---------------------------------------------------------------------------

const ws = new WebSocket(`${botUrl}?name=${botName}`, { perMessageDeflate: false });
const player = createGameKnowledge(botName);
const bot: BotController = {
  ws, actions: new ActionQueue(), player, name: botName,
  movementTarget: null, wandering: true,
  wanderTarget: null, wanderTicks: 0, lastFrame: null,
  psychopompPrecommit: null, lastSentChat: null, hasNewIncomingChat: false,
  nonInterruptingTasks: [],
};

// Throttle: only issue a policy action every N ticks so we can see state between.
const POLICY_INTERVAL = Math.floor(TARGET_FPS / 2); // twice per second
let lastPolicyTick = -999;
let lastActionTick = -999;

// ---------------------------------------------------------------------------
// Simple helpers
// ---------------------------------------------------------------------------

function exec(type: string, args: string[] = []) {
  const cmd: ParsedCommand = { type, args };
  if (!executeBaseCommand(cmd, bot)) {
    if (type === "approach_nearest") {
      const others = bot.player.minimapDots.filter(d => !d.isSelf);
      if (others.length > 0 && bot.player.myPos) {
        let best = others[0], bestDist = Infinity;
        for (const d of others) {
          const dist = (d.worldX - bot.player.myPos.x) ** 2 + (d.worldY - bot.player.myPos.y) ** 2;
          if (dist < bestDist) { bestDist = dist; best = d; }
        }
        bot.movementTarget = { x: best.worldX, y: best.worldY };
        bot.wandering = false;
      }
    }
  }
  lastActionTick = player.tick;
}

// ---------------------------------------------------------------------------
// Hardcoded policy
// ---------------------------------------------------------------------------

function runPolicy(): void {
  // Accept any pending role offer immediately — the sim only registers the
  // mutual exchange if both are key partners; otherwise we just leak a role.
  if (player.phase === "whisper") {
    if (player.pendingRoleOffer) {
      exec("role_accept");
      return;
    }
    if (player.pendingColorOffer) {
      exec("color_accept");
      return;
    }
    // Keep offering role exchange. The sim ignores redundant offers.
    exec("role_offer");
    return;
  }

  if (player.phase === "playing" || player.phase === "psychopomp_select" || player.phase === "leader_summit") {
    // If someone is nearby, open whisper immediately.
    if (player.nearbyNames.length > 0) {
      exec("open_whisper");
      return;
    }
    // Otherwise walk toward the nearest known player.
    exec("approach_nearest");
    return;
  }

  // Lobby / role_reveal / leader_summit (as leader) / etc: do nothing.
}

// ---------------------------------------------------------------------------
// Frame loop
// ---------------------------------------------------------------------------

function onFrame(data: Buffer): void {
  if (data.length !== PACKED_FRAME_BYTES) return;
  const frame = unpackFrame(data);
  updatePhase(player, frame);
  updateMinimap(player, frame);
  updatePosition(player, frame);
  updateHud(player, frame);

  if (!bot.actions.empty) {
    sendInput(ws, bot.actions.shift()!);
    return;
  }

  if (tickMovement(bot)) return;

  if (player.tick - lastPolicyTick >= POLICY_INTERVAL) {
    lastPolicyTick = player.tick;
    runPolicy();
    if (!bot.actions.empty) {
      sendInput(ws, bot.actions.shift()!);
      return;
    }
  }

  // Fallback: if in overworld and nothing queued, wander.
  if (player.phase === "playing" && !bot.movementTarget) {
    bot.wandering = true;
  }

  if (bot.wandering) {
    tickWander(bot);
  } else {
    sendInput(ws, 0);
  }
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

ws.on("open", () => console.log(`[${botName}] Connected`));
ws.on("message", (data: Buffer) => onFrame(data));
ws.on("close", () => { console.log(`[${botName}] Disconnected`); process.exit(0); });
ws.on("error", (err) => console.error(`[${botName}] Error:`, err.message));
process.on("SIGINT", () => { ws.close(); process.exit(0); });

console.log(`Winner bot: ${botName} | server: ${botUrl}`);

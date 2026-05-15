/**
 * Bot policy config — persistent instructions the LLM sets that the bot
 * evaluates autonomously every frame.
 *
 * The LLM doesn't pick one action per tick. Instead it updates the policy,
 * and the bot evaluates the policy in priority order on each frame.
 */

import { BUTTON_A, BUTTON_B, BUTTON_SELECT, paletteColorFromLetter } from "../game/constants.js";
import { Room } from "../game/types.js";
import {
  sendInput, sendChat, moveToward, randomDir, randomPoint, clamp,
  type Point,
} from "./bot_utils.js";
import type { BotController } from "./bot_common.js";
import type { GameKnowledge } from "./game_knowledge.js";
import { whisperMenuSequence, COMMAND_ACTIONS } from "../game/menu_defs.js";

// ---------------------------------------------------------------------------
// Policy schema
// ---------------------------------------------------------------------------

export interface Policy {
  /** Auto-grant whisper entry requests. */
  autoGrantEntry: boolean;
  /** Auto-accept role exchange offers (only safe if you've verified partner). */
  autoAcceptRoleOffer: boolean;
  /** Auto-accept color exchange offers. */
  autoAcceptColorOffer: boolean;
  /** When in a whisper with at least 2 occupants, auto-offer color reveal. */
  autoOfferColor: boolean;
  /** When in a whisper with at least 2 occupants, auto-offer role reveal. */
  autoOfferRole: boolean;

  /**
   * Ordered list of players to pursue by character name (e.g. "R.CRCL").
   * Bot walks toward the first one it can see on the minimap.
   */
  pursueOrder: string[];

  /**
   * When we reach a pursued player (within bubble range), open a whisper.
   * After that, fall through to in-whisper auto-* flags.
   */
  openWhisperOnReach: boolean;

  /** If true, wander when no pursue targets visible. */
  wanderIfIdle: boolean;

  /** Chat messages to shout into global room chat, consumed one per tick. */
  shoutQueue: string[];

  /** Chat messages to send to current whisper, consumed one per tick. */
  chatQueue: string[];

  /**
   * Walk toward a specific world-space point. Higher priority than pursueOrder.
   * When within ~10 units of the target and openWhisperOnReach is true, the bot
   * presses A (creating a local whisper OR requesting entry to any whisper nearby).
   * Use this to coordinate meetups via shout.
   */
  targetPoint: { x: number; y: number } | null;
}

export function defaultPolicy(): Policy {
  return {
    autoGrantEntry: true,
    autoAcceptRoleOffer: false,  // unsafe default — must verify partner first
    autoAcceptColorOffer: true,
    autoOfferColor: false,
    autoOfferRole: false,
    pursueOrder: [],
    openWhisperOnReach: true,
    wanderIfIdle: true,
    shoutQueue: [],
    chatQueue: [],
    targetPoint: null,
  };
}

/** Shallow-merge a partial update into a policy, preserving keys not given. */
export function mergePolicy(current: Policy, update: Partial<Policy>): Policy {
  return {
    autoGrantEntry: update.autoGrantEntry ?? current.autoGrantEntry,
    autoAcceptRoleOffer: update.autoAcceptRoleOffer ?? current.autoAcceptRoleOffer,
    autoAcceptColorOffer: update.autoAcceptColorOffer ?? current.autoAcceptColorOffer,
    autoOfferColor: update.autoOfferColor ?? current.autoOfferColor,
    autoOfferRole: update.autoOfferRole ?? current.autoOfferRole,
    pursueOrder: update.pursueOrder ?? current.pursueOrder,
    openWhisperOnReach: update.openWhisperOnReach ?? current.openWhisperOnReach,
    wanderIfIdle: update.wanderIfIdle ?? current.wanderIfIdle,
    shoutQueue: update.shoutQueue ?? current.shoutQueue,
    chatQueue: update.chatQueue ?? current.chatQueue,
    targetPoint: update.targetPoint === undefined ? current.targetPoint : update.targetPoint,
  };
}

export function policyToPrompt(policy: Policy): string {
  return JSON.stringify({
    autoGrantEntry: policy.autoGrantEntry,
    autoAcceptRoleOffer: policy.autoAcceptRoleOffer,
    autoAcceptColorOffer: policy.autoAcceptColorOffer,
    autoOfferColor: policy.autoOfferColor,
    autoOfferRole: policy.autoOfferRole,
    pursueOrder: policy.pursueOrder,
    openWhisperOnReach: policy.openWhisperOnReach,
    wanderIfIdle: policy.wanderIfIdle,
    targetPoint: policy.targetPoint,
    pendingShouts: policy.shoutQueue.length,
    pendingChats: policy.chatQueue.length,
  }, null, 2);
}

/**
 * Parse an LLM response containing a policy JSON block and return the partial
 * update. The LLM is prompted to emit a single JSON object with any subset of
 * policy keys. We tolerate surrounding prose and fenced code blocks.
 */
export function parsePolicyUpdate(raw: string, name?: string): Partial<Policy> | null {
  // Find the first { ... } JSON blob
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) {
    if (name) console.log(`[${name}] no JSON in response: ${raw.slice(0, 120)}`);
    return null;
  }
  const jsonStr = raw.slice(start, end + 1);
  try {
    const obj = JSON.parse(jsonStr);
    const update: Partial<Policy> = {};
    if (typeof obj.autoGrantEntry === "boolean") update.autoGrantEntry = obj.autoGrantEntry;
    if (typeof obj.autoAcceptRoleOffer === "boolean") update.autoAcceptRoleOffer = obj.autoAcceptRoleOffer;
    if (typeof obj.autoAcceptColorOffer === "boolean") update.autoAcceptColorOffer = obj.autoAcceptColorOffer;
    if (typeof obj.autoOfferColor === "boolean") update.autoOfferColor = obj.autoOfferColor;
    if (typeof obj.autoOfferRole === "boolean") update.autoOfferRole = obj.autoOfferRole;
    if (Array.isArray(obj.pursueOrder)) {
      update.pursueOrder = obj.pursueOrder.filter((n: any) => typeof n === "string");
    }
    if (typeof obj.openWhisperOnReach === "boolean") update.openWhisperOnReach = obj.openWhisperOnReach;
    if (typeof obj.wanderIfIdle === "boolean") update.wanderIfIdle = obj.wanderIfIdle;
    if (obj.targetPoint === null) {
      update.targetPoint = null;
    } else if (obj.targetPoint && typeof obj.targetPoint.x === "number" && typeof obj.targetPoint.y === "number") {
      update.targetPoint = { x: obj.targetPoint.x, y: obj.targetPoint.y };
    }
    if (Array.isArray(obj.shout)) update.shoutQueue = obj.shout.map((s: any) => String(s));
    if (Array.isArray(obj.chat)) update.chatQueue = obj.chat.map((s: any) => String(s));
    if (typeof obj.shout === "string") update.shoutQueue = [obj.shout];
    if (typeof obj.chat === "string") update.chatQueue = [obj.chat];
    return update;
  } catch (e: any) {
    if (name) console.log(`[${name}] policy parse error: ${e.message} | raw: ${raw.slice(0, 120)}`);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Executor — runs every frame, consults the policy and emits one action
// ---------------------------------------------------------------------------

/** Push a whisper-menu command sequence into the bot's action queue. */
function pushChatCommand(bot: BotController, action: string) {
  const seq = whisperMenuSequence(action);
  if (action === "R.ACCPT" || action === "C.ACCPT") {
    seq.push(BUTTON_A, 0);  // auto-confirm the target-select sub-menu
  }
  bot.actions.push(...seq);
}

/** Returns true if the executor produced an input this frame. */
export function runPolicy(bot: BotController, policy: Policy, ws: any): boolean {
  const player = bot.player;

  // Priority 0: drain pending action queue first
  if (!bot.actions.empty) {
    sendInput(ws, bot.actions.shift()!);
    return true;
  }

  // Priority 1: if we're in waiting_entry, just sit still
  if (player.phase === "waiting_entry") {
    sendInput(ws, 0);
    return true;
  }

  // Priority 2: inside a whisper — apply auto-actions
  if (player.phase === "whisper") {
    // Highest priority: grant pending entry if configured
    if (policy.autoGrantEntry && player.pendingEntry) {
      pushChatCommand(bot, "GRANT");
      sendInput(ws, bot.actions.shift()!);
      return true;
    }
    // Accept role offer if configured (this is the win path when it's safe)
    if (policy.autoAcceptRoleOffer && player.pendingRoleOffer) {
      pushChatCommand(bot, "R.ACCPT");
      sendInput(ws, bot.actions.shift()!);
      return true;
    }
    // Accept color offer if configured
    if (policy.autoAcceptColorOffer && player.pendingColorOffer) {
      pushChatCommand(bot, "C.ACCPT");
      sendInput(ws, bot.actions.shift()!);
      return true;
    }
    // Send a chat message if queued
    if (policy.chatQueue.length > 0) {
      const msg = policy.chatQueue.shift()!;
      sendChat(ws, msg);
      sendInput(ws, 0);
      return true;
    }
    // Offer color if configured (but only once per policy update — clear flag?)
    // For now, leave these as idempotent: the sim no-ops if we're already offering.
    if (policy.autoOfferRole) {
      pushChatCommand(bot, "R.OFFER");
      // Clear the flag so we don't spam
      policy.autoOfferRole = false;
      sendInput(ws, bot.actions.shift()!);
      return true;
    }
    if (policy.autoOfferColor) {
      pushChatCommand(bot, "C.OFFER");
      policy.autoOfferColor = false;
      sendInput(ws, bot.actions.shift()!);
      return true;
    }
    // Nothing to do in whisper — idle
    sendInput(ws, 0);
    return true;
  }

  // Overworld — pursue players or wander

  // Priority 3: shout from shoutQueue
  if (policy.shoutQueue.length > 0) {
    // In overworld, sendChat goes to the global room chat automatically (server
    // routes based on whether player is in whisper).
    const msg = policy.shoutQueue.shift()!;
    sendChat(ws, msg);
    sendInput(ws, 0);
    return true;
  }

  // Priority 3.5: walk toward targetPoint (highest spatial priority — used for
  // coordinated meetups).
  if (player.myPos && policy.targetPoint) {
    const dx = policy.targetPoint.x - player.myPos.x;
    const dy = policy.targetPoint.y - player.myPos.y;
    const distSq = dx * dx + dy * dy;
    if (distSq <= (10 * 10)) {
      // Arrived at meetup point. Try to open/join a whisper.
      if (policy.openWhisperOnReach) {
        bot.actions.push(BUTTON_A, 0);
        sendInput(ws, bot.actions.shift()!);
        return true;
      }
      // Otherwise just stand still at the meetup.
      sendInput(ws, 0);
      return true;
    }
    // Walk toward it.
    const mask = moveToward(player.myPos.x, player.myPos.y, policy.targetPoint.x, policy.targetPoint.y);
    sendInput(ws, mask || randomDir());
    return true;
  }

  // Priority 4: pursue a player in pursueOrder
  if (player.myPos && policy.pursueOrder.length > 0) {
    for (const target of policy.pursueOrder) {
      const targetColor = paletteColorFromLetter(target.split(".")[0]);
      if (targetColor === null) continue;
      const dot = player.minimapDots.find(d => d.color === targetColor && !d.isSelf);
      if (!dot) continue;

      // If within whisper bubble range, open_whisper
      const dx = dot.worldX - player.myPos.x;
      const dy = dot.worldY - player.myPos.y;
      const distSq = dx * dx + dy * dy;

      if (distSq <= (10 * 10) && policy.openWhisperOnReach) {
        // Within grabbing distance — try to open whisper
        bot.actions.push(BUTTON_A, 0);
        sendInput(ws, bot.actions.shift()!);
        return true;
      }

      // Otherwise, walk toward them
      const mask = moveToward(player.myPos.x, player.myPos.y, dot.worldX, dot.worldY);
      sendInput(ws, mask || randomDir());
      return true;
    }
  }

  // Priority 5: wander
  if (policy.wanderIfIdle) {
    if (!bot.wanderTarget || bot.wanderTicks <= 0) {
      bot.wanderTarget = randomPoint(player.myRoom ?? Room.RoomA, player.matchFacts.roomW, player.matchFacts.roomH);
      bot.wanderTicks = 15 + Math.floor(Math.random() * 40);
    }
    bot.wanderTicks--;
    if (player.myPos) {
      const mask = moveToward(player.myPos.x, player.myPos.y, bot.wanderTarget.x, bot.wanderTarget.y);
      sendInput(ws, mask || randomDir());
    } else {
      sendInput(ws, randomDir());
    }
    return true;
  }

  sendInput(ws, 0);
  return true;
}

/**
 * Task-based bot control. The LLM emits a list of ordered tasks; the bot
 * executor walks the list top-to-bottom each frame and runs the first task
 * that produces an action.
 *
 * Task categories:
 *   - ONCE: fires and removes itself (shout, chat, exit_whisper)
 *   - ASYNC: multi-frame, self-terminates on done/failed/timeout (pursue_chat, walk_to)
 *   - LOOP: singleton per kind; reactive (auto_*) or persistent (precommit_psychopomps).
 *           A new loop of the same kind replaces the existing one.
 *
 * Priority: LOOP and ONCE tasks run first (interrupt). ASYNC tasks only run
 * when no LOOP/ONCE fires that frame.
 *
 * Dependencies: each task has an ID (auto-generated or explicit). A task with
 * blockedBy=<id> is skipped until the referenced task succeeds; dropped if it fails.
 */

import type WebSocket from "ws";
import {
  BUBBLE_RADIUS, BUTTON_A, BUTTON_B, BUTTON_LEFT, BUTTON_RIGHT, BUTTON_SELECT,
  isValidCharacterName,
} from "../game/constants.js";
import { sendInput, sendChat, truncateChatInput, moveToward } from "./bot_utils.js";
import { whisperMenuSequenceWithTargetPick } from "../game/menu_defs.js";
import { parseUsurpCandidate } from "./frame_parser.js";
import {
  colorFromCharName,
  hasColorExchangeSucceeded,
  hasRoleExchangeSucceeded,
  markColorExchangeSucceeded,
  markRoleExchangeSucceeded,
  type GameKnowledge,
} from "./game_knowledge.js";
import type { BotController } from "./bot_common.js";
import type { MinimapDot } from "./frame_parser.js";

// ---------------------------------------------------------------------------
// Task definitions
// ---------------------------------------------------------------------------

export type Task =
  // ONCE tasks — fire once and remove
  | { kind: "shout"; text: string }
  | { kind: "chat"; text: string }
  | { kind: "whisper_action"; action: "ROLE" | "C.OFFER" | "C.UNOFFR" | "R.OFFER" | "R.UNOFFR" | "PASS" | "TAKE" | "GRANT" }
  | { kind: "exit_whisper" }
  // ASYNC tasks — multi-frame, self-terminate on done/failed/timeout
  | { kind: "walk_to"; x: number; y: number; timeLimitTicks: number }
  | { kind: "pursue_chat"; target: string; timeLimitTicks: number }
  | {
      kind: "pursue_exchange";
      target: string;
      exchange: "role" | "color" | "whisper";
      timeLimitTicks: number;
      mode?: "find_spot" | "go_to_player";
    }
  | { kind: "usurp_vote"; target: string; timeLimitTicks: number }
  // LOOP tasks (singleton per kind)
  | { kind: "loop_auto_grant" }
  | { kind: "loop_auto_accept_color" }
  | { kind: "loop_auto_accept_role" }
  | { kind: "loop_global_check"; intervalTicks: number }
  // ONCE — immediately stores targets, fires on psychopomp_select
  | { kind: "precommit_psychopomps"; targets: string[] }
  // Non-interruptible atoms. Producers should enqueue these for short,
  // known-safe input sequences.
  | { kind: "atom_input"; masks: number[]; label: string }
  | { kind: "atom_chat"; text: string; label: string };

const ONCE_KINDS = new Set<string>([
  "shout", "chat", "exit_whisper", "precommit_psychopomps",
  "whisper_action", "atom_input", "atom_chat",
]);

const ASYNC_KINDS = new Set<string>([
  "walk_to", "pursue_chat", "pursue_exchange", "usurp_vote",
]);

const LOOP_KINDS = new Set<string>([
  "loop_auto_grant", "loop_auto_accept_color", "loop_auto_accept_role", "loop_global_check",
]);

export function isOnceTask(t: Task): boolean { return ONCE_KINDS.has(t.kind); }
export function isAsyncTask(t: Task): boolean { return ASYNC_KINDS.has(t.kind); }
export function isLoopTask(t: Task): boolean { return LOOP_KINDS.has(t.kind); }
/** @deprecated alias for isAsyncTask */
export function isSequenceTask(t: Task): boolean { return ASYNC_KINDS.has(t.kind); }

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------

let nextAutoId = 1;

export interface TaskInstance {
  id: string;
  blockedBy: string | null; // ID of another task — this task only runs after that task succeeds; dropped if it fails
  task: Task;
  startTick: number;
  lastFiredTick: number;
  // pursue_chat / pursue_exchange runtime
  createdOwnWhisperTick: number | null;
  grantDeadlineTick: number | null;
  lastSawTargetTick: number;
  startedEmitted: boolean;
  // pursue_exchange: whether we've sent our offer in the current whisper yet.
  offerSentTick: number | null;
  // pursue_exchange: whether we shouted about finding a corner after wrong-room whisper
  shoutedWrongRoom: boolean;
  // pursue_exchange: detailed status for LLM visibility
  exchangeStatus: string;
  // pursue_exchange find_spot mode state
  privateSpot: { x: number; y: number } | null;
  privateSpotTick: number;
  privateSpotShoutTick: number;
  nearTargetWaitTick: number;
  // usurp_vote state machine
  usurpState: "idle" | "opening" | "navigating" | "voting" | "closing";
  usurpNavCount: number;
  atomIndex: number;
}

export function createTaskInstance(task: Task, tick: number, id?: string, blockedBy?: string): TaskInstance {
  return {
    id: id ?? `t${nextAutoId++}`,
    blockedBy: blockedBy ?? null,
    task, startTick: tick, lastFiredTick: -1,
    createdOwnWhisperTick: null, grantDeadlineTick: null,
    lastSawTargetTick: -Infinity, startedEmitted: false,
    offerSentTick: null, shoutedWrongRoom: false,
    exchangeStatus: "searching for target",
    privateSpot: null, privateSpotTick: -Infinity, privateSpotShoutTick: -Infinity,
    nearTargetWaitTick: -Infinity,
    usurpState: "idle", usurpNavCount: 0,
    atomIndex: 0,
  };
}

// ---------------------------------------------------------------------------
// Event buffer — structured records the LLM reads each prompt
// ---------------------------------------------------------------------------

export type TaskEventKind =
  | "started"     // task began running (first fire or first relevant tick)
  | "fired"       // ONCE task fired successfully (emitted its action)
  | "succeeded"   // SEQUENCE task completed successfully
  | "failed"      // task failed (pre-condition false, timeout, etc.)
  | "replaced";   // LOOP task was replaced by a new one of the same kind

export interface TaskEvent {
  tick: number;
  task: Task;
  kind: TaskEventKind;
  reason?: string;  // optional human/LLM-readable explanation
}

/** Shared event log — pushed by task lifecycle + merge + executor. */
export interface EventBuffer {
  events: TaskEvent[];
  onEvent?: (ev: TaskEvent) => void;
}

export function createEventBuffer(onEvent?: (ev: TaskEvent) => void): EventBuffer { return { events: [], onEvent }; }

export function pushEvent(buf: EventBuffer, ev: TaskEvent): void {
  buf.events.push(ev);
  buf.onEvent?.(ev);
  if (buf.events.length > 500) buf.events.shift();
}

export function flushEvents(buf: EventBuffer): void { buf.events = []; }

export function eventBufferLines(buf: EventBuffer): string[] {
  if (buf.events.length === 0) return ["  (no events since last response)"];
  return buf.events.map(ev => {
    const body = JSON.stringify(ev.task);
    const tail = ev.reason ? ` — ${ev.reason}` : "";
    return `  t=${ev.tick} ${ev.kind}: ${body}${tail}`;
  });
}

// ---------------------------------------------------------------------------
// Merge an LLM update into the current task list
// ---------------------------------------------------------------------------

export interface TaskAppendItem {
  id?: string;
  blockedBy?: string;
  task: Task;
}

export interface TaskUpdate {
  clear?: "all" | "non_loop" | "non_loop_unsafe";
  append?: TaskAppendItem[];
}

function isActiveSequence(ti: TaskInstance): boolean {
  if (!isSequenceTask(ti.task)) return false;
  if (ti.task.kind === "pursue_exchange" || ti.task.kind === "pursue_chat") {
    return ti.createdOwnWhisperTick !== null || ti.offerSentTick !== null;
  }
  return false;
}

export function mergeTasks(
  current: TaskInstance[],
  update: TaskUpdate,
  tick: number,
  buf?: EventBuffer,
): TaskInstance[] {
  let result: TaskInstance[];
  if (update.clear === "all") {
    if (buf) for (const ti of current) pushEvent(buf, { tick, task: ti.task, kind: "failed", reason: "clear:all" });
    result = [];
  } else if (update.clear === "non_loop_unsafe") {
    if (buf) for (const ti of current) {
      if (!isLoopTask(ti.task)) pushEvent(buf, { tick, task: ti.task, kind: "failed", reason: "clear:non_loop_unsafe" });
    }
    result = current.filter(ti => isLoopTask(ti.task));
  } else if (update.clear === "non_loop") {
    if (buf) for (const ti of current) {
      if (!isLoopTask(ti.task) && !isActiveSequence(ti)) {
        pushEvent(buf, { tick, task: ti.task, kind: "failed", reason: "clear:non_loop" });
      }
    }
    result = current.filter(ti => isLoopTask(ti.task) || isActiveSequence(ti));
  } else {
    result = [...current];
  }

  if (update.append) {
    for (const item of update.append) {
      const task = item.task;
      if (isLoopTask(task)) {
        const idx = result.findIndex(ti => ti.task.kind === task.kind);
        if (idx >= 0) {
          if (buf) pushEvent(buf, { tick, task: result[idx].task, kind: "replaced", reason: "new loop of same kind" });
          result.splice(idx, 1);
        }
      }
      result.push(createTaskInstance(task, tick, item.id, item.blockedBy));
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Target resolution — character name → minimap dot
// ---------------------------------------------------------------------------

function findTargetDot(player: GameKnowledge, target: string): MinimapDot | undefined {
  const targetColor = colorFromCharName(target);
  if (targetColor === null) return undefined;
  const dots = player.minimapDots.filter(d => d.color === targetColor && !d.isSelf);
  if (dots.length <= 1) return dots[0];
  // Ambiguous color — use last known position to disambiguate
  const targetPlayer = player.players.get(target);
  if (!targetPlayer?.lastPos) return dots[0];
  let best = dots[0], bestDist = Infinity;
  for (const d of dots) {
    const dist = (d.worldX - targetPlayer.lastPos.x) ** 2 + (d.worldY - targetPlayer.lastPos.y) ** 2;
    if (dist < bestDist) { bestDist = dist; best = d; }
  }
  return best;
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

interface TaskResult {
  kind: "emitted" | "done" | "failed" | "skip";
  reason?: string;
}
const EMIT: TaskResult = { kind: "emitted" };
const DONE: TaskResult = { kind: "done" };
const SKIP: TaskResult = { kind: "skip" };
function emit(reason: string): TaskResult { return { kind: "emitted", reason }; }
function fail(reason: string): TaskResult { return { kind: "failed", reason }; }
function done(reason?: string): TaskResult { return { kind: "done", reason }; }

function enqueueAtomInput(bot: BotController, masks: number[], label: string): TaskResult {
  bot.nonInterruptingTasks.push(createTaskInstance({ kind: "atom_input", masks, label }, bot.player.tick));
  return emit(`queued atom_input ${label}`);
}

function enqueueAtomChat(bot: BotController, text: string, label: string): TaskResult {
  bot.nonInterruptingTasks.push(createTaskInstance({ kind: "atom_chat", text, label }, bot.player.tick));
  return emit(`queued atom_chat ${label}`);
}

function pushChatAction(bot: BotController, action: string): boolean {
  const seq = whisperMenuSequenceWithTargetPick(action);
  if (seq.length === 0) return false;
  bot.actions.push(...seq);
  return true;
}

function hasExchangeSystemMessage(player: GameKnowledge, exchange: "role" | "color"): boolean {
  const needle = exchange === "role" ? "ROLE" : "COLOR";
  return player.whisperMessages.some(m =>
    m.type === "system" && m.text.toUpperCase().includes(needle)
  );
}

const ALONE_WHISPER_MIN_TICKS = 8 * 24;
const ALONE_WHISPER_JITTER_TICKS = 16 * 24;
const ALONE_WHISPER_SHOUT_INTERVAL_TICKS = 5 * 24;
function randomGrantDeadline(tick: number): number {
  return tick + ALONE_WHISPER_MIN_TICKS + Math.floor(Math.random() * ALONE_WHISPER_JITTER_TICKS);
}

function shouldRequestTargetWhisper(player: GameKnowledge, target: string): boolean {
  const targetBelief = player.players.get(target);
  if (!targetBelief?.inWhisper) return false;
  if (targetBelief.lastRoom !== player.myRoom) return false;
  if (!player.nearbyNames.includes(target)) return false;
  const sameColorNearby = player.nearbyNames.filter(name => {
    const pb = player.players.get(name);
    return pb?.color === targetBelief.color;
  });
  return sameColorNearby.length <= 1;
}

function targetReachableInRoom(player: GameKnowledge, target: string): boolean {
  const pb = player.players.get(target);
  return !!pb && pb.lastRoom === player.myRoom;
}

function firstUnknownOccupant(player: GameKnowledge): string | null {
  for (const name of player.occupantNames) {
    const pb = player.players.get(name);
    if (pb && !hasColorExchangeSucceeded(player, name)) return name;
  }
  return null;
}

function inviteText(player: GameKnowledge, target: string): string | null {
  if (!player.myPos || !targetReachableInRoom(player, target)) return null;
  const short = target.length <= 10 ? target : target.slice(0, 10);
  return `${short} COME @ ${Math.round(player.myPos.x)},${Math.round(player.myPos.y)}`;
}

function distSq(a: { x: number; y: number }, b: { x: number; y: number }): number {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  return dx * dx + dy * dy;
}

function clampPoint(x: number, y: number, player: GameKnowledge): { x: number; y: number } {
  const margin = Math.max(12, BUBBLE_RADIUS);
  return {
    x: Math.max(margin, Math.min(player.matchFacts.roomW - margin, Math.round(x))),
    y: Math.max(margin, Math.min(player.matchFacts.roomH - margin, Math.round(y))),
  };
}

function otherDots(player: GameKnowledge): MinimapDot[] {
  return player.minimapDots.filter(d => !d.isSelf);
}

function nearestOtherDistSq(player: GameKnowledge, point: { x: number; y: number }, exceptTarget?: string): number {
  const exceptColor = exceptTarget ? colorFromCharName(exceptTarget) : null;
  let best = Infinity;
  for (const dot of otherDots(player)) {
    if (exceptColor !== null && dot.color === exceptColor) continue;
    const d = distSq(point, { x: dot.worldX, y: dot.worldY });
    if (d < best) best = d;
  }
  return best;
}

function pointIsPrivate(player: GameKnowledge, point: { x: number; y: number }, exceptTarget?: string): boolean {
  const privacyRadius = BUBBLE_RADIUS * 2.2;
  return nearestOtherDistSq(player, point, exceptTarget) >= privacyRadius * privacyRadius;
}

function choosePrivateSpot(player: GameKnowledge, targetDot?: MinimapDot): { x: number; y: number } | null {
  if (!player.myPos) return null;
  const margin = Math.max(18, BUBBLE_RADIUS + 4);
  const candidates: { x: number; y: number }[] = [];
  const anchors = [
    { x: margin, y: margin },
    { x: player.matchFacts.roomW - margin, y: margin },
    { x: margin, y: player.matchFacts.roomH - margin },
    { x: player.matchFacts.roomW - margin, y: player.matchFacts.roomH - margin },
    { x: Math.floor(player.matchFacts.roomW / 2), y: margin },
    { x: Math.floor(player.matchFacts.roomW / 2), y: player.matchFacts.roomH - margin },
    { x: margin, y: Math.floor(player.matchFacts.roomH / 2) },
    { x: player.matchFacts.roomW - margin, y: Math.floor(player.matchFacts.roomH / 2) },
  ];

  if (targetDot) {
    const awayX = player.myPos.x + (player.myPos.x - targetDot.worldX) * 2;
    const awayY = player.myPos.y + (player.myPos.y - targetDot.worldY) * 2;
    candidates.push(clampPoint(awayX, awayY, player));
  }
  candidates.push(...anchors.map(p => clampPoint(p.x, p.y, player)));

  let best: { x: number; y: number } | null = null;
  let bestScore = -Infinity;
  for (const c of candidates) {
    const crowdDist = Math.sqrt(nearestOtherDistSq(player, c));
    const selfDist = Math.sqrt(distSq(player.myPos, c));
    const targetDist = targetDot ? Math.sqrt(distSq(c, { x: targetDot.worldX, y: targetDot.worldY })) : 0;
    // Prefer quiet spots that are not too far for either participant.
    const score = crowdDist * 3 - selfDist * 0.6 - targetDist * 0.25;
    if (score > bestScore) { bestScore = score; best = c; }
  }
  return best;
}

function tryTask(ti: TaskInstance, bot: BotController, ws: WebSocket): TaskResult {
  const player = bot.player as GameKnowledge;
  const tick = player.tick;
  const t = ti.task;

  // Time-limit check for sequence tasks
  if (isSequenceTask(t)) {
    const limit = (t as any).timeLimitTicks as number;
    if (tick - ti.startTick > limit) return fail("timeout");
  }

  const fireChat = (raw: string): TaskResult => {
    const { sent, truncated } = truncateChatInput(raw);
    if (sent === bot.lastSentChat && !bot.hasNewIncomingChat) {
      return emit(`deduplicated "${sent}" (no new messages since last send)`);
    }
    sendChat(ws, sent);
    sendInput(ws, 0);
    bot.lastSentChat = sent;
    bot.hasNewIncomingChat = false;
    ti.lastFiredTick = tick;
    const reason = truncated
      ? `sent "${sent}" (TRUNCATED from ${raw.length} chars)`
      : `sent "${sent}"`;
    return emit(reason);
  };

  switch (t.kind) {
    case "atom_input": {
      const mask = t.masks[ti.atomIndex] ?? 0;
      sendInput(ws, mask);
      ti.atomIndex++;
      ti.lastFiredTick = tick;
      return ti.atomIndex >= t.masks.length ? done(`atom input complete: ${t.label}`) : EMIT;
    }

    case "atom_chat": {
      const { sent, truncated } = truncateChatInput(t.text);
      if (sent === bot.lastSentChat && !bot.hasNewIncomingChat) {
        return done(`deduplicated atom chat "${sent}"`);
      }
      sendChat(ws, sent);
      sendInput(ws, 0);
      bot.lastSentChat = sent;
      bot.hasNewIncomingChat = false;
      ti.lastFiredTick = tick;
      return done(truncated
        ? `atom chat ${t.label}: sent "${sent}" (TRUNCATED from ${t.text.length} chars)`
        : `atom chat ${t.label}: sent "${sent}"`);
    }

    // ---- ONCE chat tasks ----
    case "shout": {
      if (player.phase !== "playing" && player.phase !== "psychopomp_select" && player.phase !== "leader_summit") return SKIP;
      return enqueueAtomChat(bot, t.text, "shout");
    }
    case "chat": {
      if (player.phase !== "whisper" && player.phase !== "leader_summit") return SKIP;
      return enqueueAtomChat(bot, t.text, "chat");
    }

    case "whisper_action": {
      if (player.phase !== "whisper" && player.phase !== "leader_summit") return SKIP;
      if (!pushChatAction(bot, t.action)) return fail(`whisperMenuSequence returned empty for ${t.action}`);
      ti.lastFiredTick = tick;
      return enqueueAtomInput(bot, [bot.actions.shift()!], `whisper_action:${t.action}`);
    }

    case "exit_whisper": {
      if (player.phase !== "whisper") return SKIP;
      if (!pushChatAction(bot, "EXIT")) return fail("whisperMenuSequence returned empty");
      ti.lastFiredTick = tick;
      return enqueueAtomInput(bot, [bot.actions.shift()!], "exit_whisper");
    }

    // ---- SEQUENCE tasks ----
    case "walk_to": {
      if ((player.phase !== "playing" && player.phase !== "leader_summit") || !player.myPos) return SKIP;
      const dx = t.x - player.myPos.x;
      const dy = t.y - player.myPos.y;
      if (dx * dx + dy * dy <= 9) return done(`arrived at (${t.x},${t.y})`);
      const mask = moveToward(player.myPos.x, player.myPos.y, t.x, t.y);
      return enqueueAtomInput(bot, [mask || 0], "move");
    }

    case "pursue_chat": {
      if (player.phase === "waiting_entry" && ti.createdOwnWhisperTick !== null) {
        ti.createdOwnWhisperTick = null;
        ti.grantDeadlineTick = null;
      }

      if (player.phase === "whisper") {
        if (ti.createdOwnWhisperTick !== null
            && ti.grantDeadlineTick !== null
            && tick > ti.grantDeadlineTick) {
          if (player.pendingEntry) {
            if (pushChatAction(bot, "GRANT")) {
              return enqueueAtomInput(bot, [bot.actions.shift()!], "menu");
            }
          }
          if (pushChatAction(bot, "EXIT")) {
            sendInput(ws, bot.actions.shift()!);
            ti.createdOwnWhisperTick = null;
            ti.grantDeadlineTick = null;
            return EMIT;
          }
        }
        return done("entered whisper");
      }

      if (player.phase === "waiting_entry") {
        return enqueueAtomInput(bot, [0], "wait");
      }

      if ((player.phase !== "playing" && player.phase !== "leader_summit") || !player.myPos) return SKIP;

      const targetDot = findTargetDot(player, t.target);

      if (!targetDot) {
        if (tick - ti.lastSawTargetTick > 12) return SKIP;
        return SKIP;
      }

      ti.lastSawTargetTick = tick;

      const dx = targetDot.worldX - player.myPos.x;
      const dy = targetDot.worldY - player.myPos.y;
      const distSq = dx * dx + dy * dy;

      if (distSq > 100) {
        const mask = moveToward(player.myPos.x, player.myPos.y, targetDot.worldX, targetDot.worldY);
        return enqueueAtomInput(bot, [mask || 0], "move");
      }

      const targetBelief = player.players.get(t.target);
      if (targetBelief?.inWhisper) {
        ti.createdOwnWhisperTick = null;
        ti.grantDeadlineTick = null;
        bot.actions.push(BUTTON_B, 0);
      } else {
        bot.actions.push(BUTTON_A, 0);
        if (ti.createdOwnWhisperTick === null) {
          ti.createdOwnWhisperTick = tick;
          ti.grantDeadlineTick = randomGrantDeadline(tick);
        }
      }
      return enqueueAtomInput(bot, [bot.actions.shift()!], "menu");
    }

    case "pursue_exchange": {
      if (player.phase === "waiting_entry" && ti.createdOwnWhisperTick !== null) {
        ti.createdOwnWhisperTick = null;
        ti.grantDeadlineTick = null;
      }
      if (player.phase === "waiting_entry") {
        ti.exchangeStatus = "waiting for entry to whisper";
        return enqueueAtomInput(bot, [0], "wait");
      }

      // --- In whisper: try to exchange ---
      if (player.phase === "whisper") {
        const wantRole = t.exchange === "role";
        const wantWhisperOnly = t.exchange === "whisper";
        const targetBelief = player.players.get(t.target);
        const targetInWhisper = player.occupantNames.includes(t.target);
        const occupantList = player.occupantNames.join(", ");
        const occCount = player.occupantCount;

        if (wantWhisperOnly) {
          if (targetInWhisper) return done(`in whisper with ${t.target}`);
          if (player.occupantCount >= 2) {
            ti.exchangeStatus = `in wrong whisper (${occCount} occupants: [${occupantList}]); target ${t.target} not present`;
            if (pushChatAction(bot, "EXIT")) {
              sendInput(ws, bot.actions.shift()!);
              ti.createdOwnWhisperTick = null;
              ti.grantDeadlineTick = null;
              return EMIT;
            }
          }
          return enqueueAtomInput(bot, [0], "wait");
        }

        // Check if exchange already completed (player updated from info screen / system msgs)
        if (targetBelief) {
          if (wantRole && hasRoleExchangeSucceeded(player, t.target)) {
            return done(markRoleExchangeSucceeded(player, t.target, "task_known"));
          }
          if (!wantRole && hasColorExchangeSucceeded(player, t.target)) {
            return done(markColorExchangeSucceeded(player, t.target, "task_known"));
          }
          if (ti.offerSentTick !== null && hasExchangeSystemMessage(player, wantRole ? "role" : "color")) {
            return done(wantRole
              ? markRoleExchangeSucceeded(player, t.target, "system_message")
              : markColorExchangeSucceeded(player, t.target, "system_message"));
          }
        }

        // Accept pending offers from others
        if (wantRole && player.pendingRoleOffer && targetInWhisper) {
          if (pushChatAction(bot, "R.ACCPT")) {
            ti.exchangeStatus = `accepting role offer (${occCount} in whisper: ${occupantList})`;
            sendInput(ws, bot.actions.shift()!);
            return done(markRoleExchangeSucceeded(player, t.target, "accept_offer"));
          }
        }
        if (!wantRole && player.pendingColorOffer) {
          if (pushChatAction(bot, "C.ACCPT")) {
            ti.exchangeStatus = targetInWhisper
              ? `accepting color offer from target (${occCount} in whisper: ${occupantList})`
              : `accepting opportunistic color offer (${occCount} in whisper: ${occupantList})`;
            sendInput(ws, bot.actions.shift()!);
            for (const name of player.occupantNames) markColorExchangeSucceeded(player, name, "accept_offer");
            return done(targetInWhisper
              ? markColorExchangeSucceeded(player, t.target, "accept_offer")
              : `opportunistic color exchange complete in wrong whisper: [${occupantList}]`);
          }
        }

        // We already sent our offer — wait for others or check completion
        if (ti.offerSentTick !== null) {
          const waitTicks = tick - ti.offerSentTick;
          if (wantRole) {
            ti.exchangeStatus = `offer sent, waiting ${waitTicks} ticks — ${occCount} occupants: [${occupantList}]`
              + (targetInWhisper ? ` — target ${t.target} IS here` : ` — target ${t.target} NOT in whisper`)
              + (player.pendingRoleOffer ? " — R! indicator (someone offered back)" : " — no R! indicator yet");
          } else {
            ti.exchangeStatus = `offer sent, waiting ${waitTicks} ticks — ${occCount} occupants: [${occupantList}]`
              + (targetInWhisper ? ` — target ${t.target} IS here` : ` — target ${t.target} NOT in whisper`)
              + (player.pendingColorOffer ? " — C! indicator (someone offered back)" : " — no C! indicator yet");
          }
          if (waitTicks > 72) {
            return fail(`offer timed out after ${waitTicks} ticks — ${ti.exchangeStatus}`);
          }
          return enqueueAtomInput(bot, [0], "wait");
        }

        // Alone in whisper — grant entry or wait
        if (player.occupantCount < 2) {
          const aloneTicks = ti.createdOwnWhisperTick === null ? 0 : tick - ti.createdOwnWhisperTick;
          const invite = inviteText(player, t.target);
          ti.exchangeStatus = `alone in whisper ${aloneTicks} ticks, waiting for ${t.target}`;
          if (player.pendingEntry && pushChatAction(bot, "GRANT")) {
            ti.exchangeStatus = "granting entry to pending player";
            return enqueueAtomInput(bot, [bot.actions.shift()!], "menu");
          }
          if (invite && tick - ti.privateSpotShoutTick > ALONE_WHISPER_SHOUT_INTERVAL_TICKS) {
            ti.privateSpotShoutTick = tick;
            ti.exchangeStatus = `reminding ${t.target} of private whisper location`;
            return enqueueAtomChat(bot, invite, "alone_whisper_invite");
          }
          if (ti.createdOwnWhisperTick !== null
              && ti.grantDeadlineTick !== null
              && tick > ti.grantDeadlineTick) {
            ti.exchangeStatus = "alone in whisper too long, exiting to retry";
            if (pushChatAction(bot, "EXIT")) {
              sendInput(ws, bot.actions.shift()!);
              ti.createdOwnWhisperTick = null;
              ti.grantDeadlineTick = null;
              return EMIT;
            }
          }
          return enqueueAtomInput(bot, [0], "wait");
        }

        // 2+ occupants — only offer if target is actually here
        if (!targetInWhisper) {
          const unknownOccupant = firstUnknownOccupant(player);
          if (!wantRole && unknownOccupant) {
            ti.exchangeStatus = `target ${t.target} absent; making whisper productive with ${unknownOccupant}`;
            if (pushChatAction(bot, "C.OFFER")) {
              sendInput(ws, bot.actions.shift()!);
              ti.offerSentTick = tick;
              return EMIT;
            }
          }
          ti.exchangeStatus = `target ${t.target} NOT in whisper — exiting to find them`;
          if (pushChatAction(bot, "EXIT")) {
            sendInput(ws, bot.actions.shift()!);
            ti.createdOwnWhisperTick = null;
            ti.grantDeadlineTick = null;
            return EMIT;
          }
          return SKIP;
        }

        if (player.pendingEntry && pushChatAction(bot, "GRANT")) {
          ti.exchangeStatus = `granting entry while waiting for ${t.target}`;
          return enqueueAtomInput(bot, [bot.actions.shift()!], "menu");
        }

        if (wantRole && hasRoleExchangeSucceeded(player, t.target)) {
          return done(markRoleExchangeSucceeded(player, t.target, "already_succeeded"));
        }
        if (!wantRole && hasColorExchangeSucceeded(player, t.target)) {
          return done(markColorExchangeSucceeded(player, t.target, "already_succeeded"));
        }

        ti.exchangeStatus = `sending ${t.exchange} offer — ${occCount} occupants: [${occupantList}]`;
        const action = wantRole ? "R.OFFER" : "C.OFFER";
        if (pushChatAction(bot, action)) {
          sendInput(ws, bot.actions.shift()!);
          ti.offerSentTick = tick;
          return EMIT;
        }
        return fail("whisperMenuSequence for offer returned empty");
      }

      // --- Overworld: either claim a private spot or walk toward target ---
      if ((player.phase !== "playing" && player.phase !== "leader_summit") || !player.myPos) return SKIP;

      const targetDot = findTargetDot(player, t.target);
      if (targetDot) ti.lastSawTargetTick = tick;
      const targetBelief = player.players.get(t.target);
      if (!targetReachableInRoom(player, t.target)) {
        ti.exchangeStatus = `target ${t.target} is not in current room; aborting canned pursue`;
        return fail(ti.exchangeStatus);
      }
      const targetInNearbyWhisper = shouldRequestTargetWhisper(player, t.target);

      if (targetInNearbyWhisper) {
        ti.exchangeStatus = `requesting entry to ${t.target}'s nearby whisper`;
        bot.actions.push(BUTTON_B, 0);
        return enqueueAtomInput(bot, [bot.actions.shift()!], "menu");
      }

      const mode = t.mode ?? "go_to_player";
      if (mode === "find_spot") {
        if (player.nearbyNames.length > 1) {
          ti.privateSpot = choosePrivateSpot(player, targetDot);
          ti.privateSpotTick = tick;
          ti.exchangeStatus = `too many nearby players for private host (${player.nearbyNames.length}); relocating`;
          return enqueueAtomInput(bot, [0], "wait");
        }

        const currentSpotPrivate = ti.privateSpot
          ? pointIsPrivate(player, ti.privateSpot, t.target)
          : false;
        if (!ti.privateSpot || !currentSpotPrivate || tick - ti.privateSpotTick > 180) {
          ti.privateSpot = choosePrivateSpot(player, targetDot);
          ti.privateSpotTick = tick;
        }
        if (!ti.privateSpot) {
          ti.exchangeStatus = "no private spot available";
          return SKIP;
        }

        const spotDistSq = distSq(player.myPos, ti.privateSpot);
        if (spotDistSq > 100) {
          const dist = Math.round(Math.sqrt(spotDistSq));
          ti.exchangeStatus = `finding private spot for ${t.target} — ${dist} units away`;
          const mask = moveToward(player.myPos.x, player.myPos.y, ti.privateSpot.x, ti.privateSpot.y);
          return enqueueAtomInput(bot, [mask || 0], "move");
        }

        if (!pointIsPrivate(player, player.myPos, t.target)) {
          ti.privateSpot = choosePrivateSpot(player, targetDot);
          ti.privateSpotTick = tick;
          ti.exchangeStatus = "private spot became crowded, relocating";
          return enqueueAtomInput(bot, [0], "wait");
        }

        if (tick - ti.privateSpotShoutTick > 180) {
          const msg = inviteText(player, t.target);
          if (!msg) {
            ti.exchangeStatus = `not shouting invite: ${t.target} is not in current room`;
            return fail(ti.exchangeStatus);
          }
          ti.privateSpotShoutTick = tick;
          ti.shoutedWrongRoom = true;
          ti.exchangeStatus = `advertised private spot to ${t.target}`;
          return enqueueAtomChat(bot, msg, "private_spot_invite");
        }

        ti.exchangeStatus = `creating private whisper for ${t.target}`;
        bot.actions.push(BUTTON_A, 0);
        sendInput(ws, bot.actions.shift()!);
        if (ti.createdOwnWhisperTick === null || tick - ti.createdOwnWhisperTick > 30) {
          ti.createdOwnWhisperTick = tick;
          ti.grantDeadlineTick = randomGrantDeadline(tick);
        }
        return EMIT;
      }

      // After exiting a wrong-room whisper, shout to invite target to a corner.
      if (ti.createdOwnWhisperTick === null && ti.offerSentTick === null && !ti.shoutedWrongRoom
          && ti.startedEmitted && ti.lastFiredTick >= 0) {
        if (!targetReachableInRoom(player, t.target)) {
          ti.exchangeStatus = `not shouting corner invite: ${t.target} is not in current room`;
          return fail(ti.exchangeStatus);
        }
        ti.shoutedWrongRoom = true;
        const short = t.target.length <= 10 ? t.target : t.target.slice(0, 10);
        sendChat(ws, truncateChatInput(`${short} FIND A CORNER`).sent);
        sendInput(ws, 0);
        ti.exchangeStatus = `shouted to ${t.target} to find a corner`;
        return EMIT;
      }

      if (!targetDot) {
        ti.exchangeStatus = `target ${t.target} not visible on minimap`;
        if (tick - ti.lastSawTargetTick > 12) return SKIP;
        bot.actions.push(BUTTON_A, 0);
        sendInput(ws, bot.actions.shift()!);
        if (ti.createdOwnWhisperTick === null) {
          ti.createdOwnWhisperTick = tick;
          ti.grantDeadlineTick = randomGrantDeadline(tick);
        }
        return EMIT;
      }

      const dxe = targetDot.worldX - player.myPos.x;
      const dye = targetDot.worldY - player.myPos.y;
      const distSqE = dxe * dxe + dye * dye;

      if (distSqE > 100) {
        const dist = Math.round(Math.sqrt(distSqE));
        ti.exchangeStatus = `walking to ${t.target} — ${dist} units away`;
        const mask = moveToward(player.myPos.x, player.myPos.y, targetDot.worldX, targetDot.worldY);
        return enqueueAtomInput(bot, [mask || 0], "move");
      }

      ti.exchangeStatus = `reached ${t.target}, opening whisper`;
      if (targetBelief && !targetBelief.inWhisper && player.myCharName && player.myCharName > t.target) {
        if (ti.nearTargetWaitTick === -Infinity) ti.nearTargetWaitTick = tick;
        const waited = tick - ti.nearTargetWaitTick;
        if (waited < 48) {
          ti.exchangeStatus = `reached ${t.target}, waiting ${waited} ticks for lower-name player to host`;
          return enqueueAtomInput(bot, [0], "wait_for_target_host");
        }
      }
      bot.actions.push(BUTTON_A, 0);
      sendInput(ws, bot.actions.shift()!);
      if (ti.createdOwnWhisperTick === null) {
        ti.createdOwnWhisperTick = tick;
        ti.grantDeadlineTick = randomGrantDeadline(tick);
      }
      return EMIT;
    }

    // ---- LOOP tasks ----
    case "loop_auto_grant": {
      if (player.phase !== "whisper" || !player.pendingEntry) return SKIP;
      if (!pushChatAction(bot, "GRANT")) return SKIP;
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }
    case "loop_auto_accept_color": {
      if (player.phase !== "whisper" || !player.pendingColorOffer) return SKIP;
      if (!pushChatAction(bot, "C.ACCPT")) return SKIP;
      for (const name of player.occupantNames) markColorExchangeSucceeded(player, name, "auto_accept");
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }
    case "loop_auto_accept_role": {
      if (player.phase !== "whisper" || !player.pendingRoleOffer) return SKIP;
      if (!pushChatAction(bot, "R.ACCPT")) return SKIP;
      for (const name of player.occupantNames) markRoleExchangeSucceeded(player, name, "auto_accept");
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }
    case "loop_global_check": {
      if (tick - ti.lastFiredTick < t.intervalTicks) return SKIP;
      if (player.phase === "whisper") {
        ti.lastFiredTick = tick;
        return enqueueAtomInput(bot, [BUTTON_RIGHT, 0, BUTTON_LEFT, 0], "global_check_whisper");
      }
      if (player.phase === "playing" || player.phase === "psychopomp_select" || player.phase === "leader_summit") {
        ti.lastFiredTick = tick;
        return enqueueAtomInput(bot, [BUTTON_SELECT, 0, BUTTON_SELECT, 0], "global_check_overworld");
      }
      return SKIP;
    }

    case "usurp_vote": {
      if (player.phase !== "playing" && player.phase !== "unknown" && player.phase !== "psychopomp_select") return SKIP;
      if (player.amLeader) return fail("I am leader, cannot usurp");

      if (ti.usurpState === "idle") {
        bot.actions.push(BUTTON_SELECT, 0);
        sendInput(ws, bot.actions.shift()!);
        ti.usurpState = "opening";
        return EMIT;
      }

      if (ti.usurpState === "opening") {
        if (!bot.lastFrame) { sendInput(ws, 0); return EMIT; }
        const cand = parseUsurpCandidate(bot.lastFrame);
        if (!cand) {
          if (tick - ti.startTick > 30) return fail("shout view not detected");
          return enqueueAtomInput(bot, [0], "wait");
        }
        ti.usurpState = "navigating";
        ti.usurpNavCount = 0;
      }

      if (ti.usurpState === "navigating") {
        if (!bot.lastFrame) { sendInput(ws, 0); return EMIT; }
        const cand = parseUsurpCandidate(bot.lastFrame);
        if (!cand) return fail("lost shout view");

        // Usurp candidate only shows color (single sprite), match on color
        const targetColor = colorFromCharName(t.target);
        const selfTarget = t.target === player.myCharName;
        if ((cand.isSelf && selfTarget) || (cand.isPlayer && targetColor !== null && cand.color === targetColor)) {
          bot.actions.push(BUTTON_A, 0);
          sendInput(ws, bot.actions.shift()!);
          ti.usurpState = "closing";
          return EMIT;
        }

        if (ti.usurpNavCount > 14) return fail("target not in candidate list");
        bot.actions.push(BUTTON_B, 0);
        sendInput(ws, bot.actions.shift()!);
        ti.usurpNavCount++;
        return EMIT;
      }

      if (ti.usurpState === "closing") {
        bot.actions.push(BUTTON_SELECT, 0);
        sendInput(ws, bot.actions.shift()!);
        return done("voted");
      }

      return SKIP;
    }

    case "precommit_psychopomps": {
      bot.psychopompPrecommit = t.targets;
      return emit(`psychopomps precommitted: [${t.targets.join(", ")}]`);
    }
  }
  return SKIP;
}

/**
 * Run one frame of the task executor. Returns the updated task list (with
 * done/failed ONCE-and-SEQUENCE tasks removed; loops preserved).
 */
export function runTasks(
  tasks: TaskInstance[],
  bot: BotController,
  ws: WebSocket,
  buf?: EventBuffer,
): TaskInstance[] {
  const tick = bot.player.tick;

  if (bot.nonInterruptingTasks.length > 0) {
    const atom = bot.nonInterruptingTasks[0];
    const result = tryTask(atom, bot, ws);
    if (result.kind === "done" || result.kind === "failed") {
      if (buf) pushEvent(buf, {
        tick, task: atom.task,
        kind: result.kind === "done" ? "succeeded" : "failed",
        reason: result.reason,
      });
      bot.nonInterruptingTasks.shift();
    }
    return tasks;
  }

  if (bot.player.phase === "waiting_entry") {
    sendInput(ws, 0);
    return tasks;
  }

  // Track completed task IDs this frame for blockedBy resolution.
  const succeeded = new Set<string>();
  const failed = new Set<string>();

  function isBlocked(ti: TaskInstance): boolean {
    if (!ti.blockedBy) return false;
    // If the blocking task already succeeded this frame, unblock.
    if (succeeded.has(ti.blockedBy)) { ti.blockedBy = null; return false; }
    // If it failed, this task will be dropped below.
    if (failed.has(ti.blockedBy)) return true;
    // Still in the list and not yet resolved — still blocked.
    return tasks.some(other => other.id === ti.blockedBy);
  }

  // Phase 1: Run loop and once tasks first — they interrupt async tasks.
  const kept: TaskInstance[] = [];
  let highPriorityEmitted = false;
  const activePursueExchange = tasks.some(ti => ti.task.kind === "pursue_exchange");

  for (const ti of tasks) {
    if (!isLoopTask(ti.task) && !isOnceTask(ti.task)) continue;
    if (activePursueExchange && ti.task.kind === "loop_auto_accept_role") {
      kept.push(ti);
      continue;
    }
    if (isBlocked(ti)) { kept.push(ti); continue; }
    if (highPriorityEmitted) { kept.push(ti); continue; }
    const result = tryTask(ti, bot, ws);

    if (result.kind === "emitted") {
      if (buf && !ti.startedEmitted) {
        pushEvent(buf, { tick, task: ti.task, kind: "started" });
        ti.startedEmitted = true;
      }
      if (isOnceTask(ti.task)) {
        if (buf) pushEvent(buf, { tick, task: ti.task, kind: "fired", reason: result.reason });
        succeeded.add(ti.id);
      } else {
        kept.push(ti);
      }
      highPriorityEmitted = true;
    } else if (result.kind === "done") {
      if (buf) pushEvent(buf, { tick, task: ti.task, kind: "succeeded", reason: result.reason });
      succeeded.add(ti.id);
    } else if (result.kind === "failed") {
      if (buf) pushEvent(buf, { tick, task: ti.task, kind: "failed", reason: result.reason });
      failed.add(ti.id);
    } else {
      kept.push(ti);
    }
  }

  if (highPriorityEmitted) {
    // Keep all async tasks untouched — they resume next frame.
    for (const ti of tasks) {
      if (isAsyncTask(ti.task) && !kept.includes(ti)) kept.push(ti);
    }
    return dropBlockedByFailed(kept, failed, buf, tick);
  }

  // Phase 2: No loop/once fired — drain action queue or run first async task.
  if (!bot.actions.empty) {
    for (const ti of tasks) {
      if (!kept.includes(ti)) kept.push(ti);
    }
    sendInput(ws, bot.actions.shift()!);
    return dropBlockedByFailed(kept, failed, buf, tick);
  }

  // Phase 3: Run first non-blocked async task.
  let asyncEmitted = false;
  for (const ti of tasks) {
    if (isLoopTask(ti.task) || isOnceTask(ti.task)) continue;
    if (isBlocked(ti)) { kept.push(ti); continue; }
    if (asyncEmitted) { kept.push(ti); continue; }
    const result = tryTask(ti, bot, ws);

    if (result.kind === "emitted") {
      if (buf && !ti.startedEmitted) {
        pushEvent(buf, { tick, task: ti.task, kind: "started" });
        ti.startedEmitted = true;
      }
      kept.push(ti);
      asyncEmitted = true;
    } else if (result.kind === "done") {
      if (buf) pushEvent(buf, { tick, task: ti.task, kind: "succeeded", reason: result.reason });
      succeeded.add(ti.id);
    } else if (result.kind === "failed") {
      if (buf) pushEvent(buf, { tick, task: ti.task, kind: "failed", reason: result.reason });
      failed.add(ti.id);
    } else {
      kept.push(ti);
    }
  }

  if (!asyncEmitted) sendInput(ws, 0);
  return dropBlockedByFailed(kept, failed, buf, tick);
}

function dropBlockedByFailed(
  tasks: TaskInstance[],
  failed: Set<string>,
  buf: EventBuffer | undefined,
  tick: number,
): TaskInstance[] {
  if (failed.size === 0) return tasks;
  return tasks.filter(ti => {
    if (ti.blockedBy && failed.has(ti.blockedBy)) {
      if (buf) pushEvent(buf, { tick, task: ti.task, kind: "failed", reason: `dependency ${ti.blockedBy} failed` });
      return false;
    }
    return true;
  });
}

// ---------------------------------------------------------------------------
// LLM response parsing
// ---------------------------------------------------------------------------

const VALID_KINDS = new Set<string>([
  "shout", "chat", "whisper_action", "exit_whisper",
  "walk_to", "pursue_chat", "pursue_exchange", "usurp_vote",
  "loop_auto_grant", "loop_auto_accept_color", "loop_auto_accept_role",
  "loop_global_check", "precommit_psychopomps", "atom_input", "atom_chat",
]);

function coerceTask(raw: any): Task | null {
  if (!raw || typeof raw !== "object" || typeof raw.kind !== "string") return null;
  if (!VALID_KINDS.has(raw.kind)) return null;
  const k = raw.kind;
  switch (k) {
    case "shout":
    case "chat":
      return typeof raw.text === "string" ? { kind: k, text: String(raw.text) } : null;
    case "whisper_action": {
      const action = raw.action;
      return action === "ROLE" || action === "C.OFFER" || action === "C.UNOFFR" ||
        action === "R.OFFER" || action === "R.UNOFFR" ||
        action === "PASS" || action === "TAKE" || action === "GRANT"
        ? { kind: "whisper_action", action }
        : null;
    }
    case "pursue_chat":
      return typeof raw.target === "string" && isValidCharacterName(raw.target) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "pursue_chat", target: raw.target, timeLimitTicks: raw.timeLimitTicks | 0 } : null;
    case "pursue_exchange": {
      const ex = raw.exchange === "role" || raw.exchange === "color" || raw.exchange === "whisper" ? raw.exchange : null;
      if (!ex) return null;
      const mode = raw.mode === "find_spot" || raw.mode === "go_to_player" ? raw.mode : undefined;
      return typeof raw.target === "string" && isValidCharacterName(raw.target) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "pursue_exchange", target: raw.target, exchange: ex, timeLimitTicks: raw.timeLimitTicks | 0, mode } : null;
    }
    case "usurp_vote":
      return typeof raw.target === "string" && isValidCharacterName(raw.target) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "usurp_vote", target: raw.target, timeLimitTicks: raw.timeLimitTicks | 0 } : null;
    case "walk_to":
      return Number.isFinite(raw.x) && Number.isFinite(raw.y) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "walk_to", x: raw.x | 0, y: raw.y | 0, timeLimitTicks: raw.timeLimitTicks | 0 } : null;
    case "loop_global_check":
      return Number.isFinite(raw.intervalTicks)
        ? { kind: "loop_global_check", intervalTicks: raw.intervalTicks | 0 }
        : { kind: "loop_global_check", intervalTicks: 96 };
    case "atom_input":
      return Array.isArray(raw.masks)
        ? { kind: "atom_input", masks: raw.masks.map((n: any) => Number(n) | 0), label: String(raw.label ?? "atom") }
        : null;
    case "atom_chat":
      return typeof raw.text === "string"
        ? { kind: "atom_chat", text: raw.text, label: String(raw.label ?? "chat") }
        : null;
    case "exit_whisper":
    case "loop_auto_grant": case "loop_auto_accept_color": case "loop_auto_accept_role":
      return { kind: k } as Task;
    case "precommit_psychopomps": {
      if (!Array.isArray(raw.targets)) return null;
      const targets = raw.targets.filter((s: any) => typeof s === "string" && isValidCharacterName(s));
      return targets.length > 0 ? { kind: "precommit_psychopomps", targets } : null;
    }
  }
  return null;
}

export function parseTaskUpdate(raw: string, name?: string): TaskUpdate | null {
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) {
    if (name) console.log(`[${name}] no JSON in: ${raw.slice(0, 120)}`);
    return null;
  }
  try {
    const obj = JSON.parse(raw.slice(start, end + 1));
    const update: TaskUpdate = {};
    if (obj.clear === "all" || obj.clear === "non_loop" || obj.clear === "non_loop_unsafe") {
      update.clear = obj.clear;
    } else if (obj.clear === true) {
      update.clear = "all";
    }
    if (Array.isArray(obj.append)) {
      update.append = [];
      for (const raw of obj.append) {
        const task = coerceTask(raw);
        if (task) {
          const item: TaskAppendItem = { task };
          if (typeof raw.id === "string" && raw.id.length > 0) item.id = raw.id;
          if (typeof raw.blockedBy === "string" && raw.blockedBy.length > 0) item.blockedBy = raw.blockedBy;
          update.append.push(item);
        }
      }
    }
    return update;
  } catch (e: any) {
    if (name) console.log(`[${name}] task parse error: ${e.message}`);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Prompt formatting
// ---------------------------------------------------------------------------

export function tasksToPromptLines(tasks: TaskInstance[], tick: number): string[] {
  if (tasks.length === 0) return ["  (empty)"];
  const lines: string[] = [];
  for (let i = 0; i < tasks.length; i++) {
    const ti = tasks[i];
    const t = ti.task;
    const meta: string[] = [];
    meta.push(`id=${ti.id}`);
    if (ti.blockedBy) meta.push(`blockedBy=${ti.blockedBy}`);
    if (isAsyncTask(t)) {
      const limit = (t as any).timeLimitTicks as number;
      meta.push(`elapsed=${tick - ti.startTick}/${limit}`);
      if ((t.kind === "pursue_chat" || t.kind === "pursue_exchange") && ti.createdOwnWhisperTick !== null) {
        const remaining = ti.grantDeadlineTick !== null ? ti.grantDeadlineTick - tick : "?";
        meta.push(`own_whisper wait=${remaining}`);
      }
      if (t.kind === "pursue_exchange") {
        meta.push(ti.exchangeStatus);
        if (ti.offerSentTick !== null || ti.createdOwnWhisperTick !== null) {
          meta.push(">>> protected from clear");
        }
      } else if ((t.kind === "pursue_chat") && ti.createdOwnWhisperTick !== null) {
        meta.push(">>> IN WHISPER — protected from clear");
      }
    }
    if (isLoopTask(t) && "intervalTicks" in t) {
      meta.push(`interval=${(t as any).intervalTicks} last=${ti.lastFiredTick}`);
    }
    const body = JSON.stringify(t);
    lines.push(`  [${i + 1}] ${body} (${meta.join(" ")})`);
  }
  return lines;
}

/**
 * Task-based bot control. The LLM emits a list of ordered tasks; the bot
 * executor walks the list top-to-bottom each frame and runs the first task
 * that produces an action.
 *
 * Task categories:
 *   - ONCE: fires and removes itself (shout, chat, grant_entry, offer_*, accept_*, ...)
 *   - SEQUENCE: multi-frame, self-terminates on done/failed/timeout (pursue_chat, walk_to)
 *   - LOOP: singleton per kind; reactive (auto_*) or periodic (read_global, ...).
 *           A new loop of the same kind replaces the existing one.
 *
 * Context routing: each task kind declares which phases it can execute in.
 * Movement tasks don't run while in chatroom. Chatroom tasks don't run while
 * in overworld. Tasks that can't apply in the current phase are skipped, not
 * removed — they wait for the phase to change (subject to their time limit).
 */

import type WebSocket from "ws";
import { BUTTON_A, CHAT_MAX_TOTAL } from "./constants.js";
import { sendInput, sendChat, moveToward } from "./bot_utils.js";
import { chatMenuSequence } from "./menu_defs.js";
import type { BotController } from "./bot_common.js";

// ---------------------------------------------------------------------------
// Task definitions
// ---------------------------------------------------------------------------

export type Task =
  // ONCE tasks
  | { kind: "shout"; text: string }
  | { kind: "chat"; text: string }
  | { kind: "exit_chatroom" }
  // SEQUENCE tasks — high level; handle their own chatroom dance
  | { kind: "walk_to"; x: number; y: number; timeLimitTicks: number }
  | { kind: "pursue_chat"; targetColor: number; timeLimitTicks: number }
  /**
   * pursue_exchange — walk to targetColor, get into the same chatroom, then
   * perform a mutual exchange. "role" triggers R.OFFER and auto-accepts any
   * pending R offer from that target. "color" does the same with C.OFFER/C.ACCPT.
   * On successful mutual exchange (sim confirms via "swapped/shared" system msg
   * or a re-offer no longer being pending), task succeeds. On timeout, fails.
   */
  | { kind: "pursue_exchange"; targetColor: number; exchange: "role" | "color"; timeLimitTicks: number }
  // LOOP tasks (singleton per kind)
  | { kind: "loop_auto_grant" }
  | { kind: "loop_auto_accept_color" }
  | { kind: "loop_auto_accept_role" }
  | { kind: "loop_read_global"; intervalTicks: number };

const LOOP_KINDS = new Set<string>([
  "loop_auto_grant", "loop_auto_accept_color", "loop_auto_accept_role",
  "loop_read_global",
]);

const SEQUENCE_KINDS = new Set<string>([
  "pursue_chat", "pursue_exchange", "walk_to",
]);

export function isLoopTask(t: Task): boolean { return LOOP_KINDS.has(t.kind); }
export function isSequenceTask(t: Task): boolean { return SEQUENCE_KINDS.has(t.kind); }
export function isOnceTask(t: Task): boolean { return !isLoopTask(t) && !isSequenceTask(t); }

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------

export interface TaskInstance {
  task: Task;
  startTick: number;
  lastFiredTick: number;
  // pursue_chat / pursue_exchange runtime
  createdOwnChatroomTick: number | null;
  grantDeadlineTick: number | null;
  lastSawTargetTick: number;
  startedEmitted: boolean;
  // pursue_exchange: whether we've sent our offer in the current chatroom yet.
  offerSentTick: number | null;
}

export function createTaskInstance(task: Task, tick: number): TaskInstance {
  return {
    task, startTick: tick, lastFiredTick: -1,
    createdOwnChatroomTick: null, grantDeadlineTick: null,
    lastSawTargetTick: -Infinity, startedEmitted: false,
    offerSentTick: null,
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
}

export function createEventBuffer(): EventBuffer { return { events: [] }; }

export function pushEvent(buf: EventBuffer, ev: TaskEvent): void {
  buf.events.push(ev);
  // Hard cap just to prevent runaway — normal flow flushes every LLM call.
  if (buf.events.length > 500) buf.events.shift();
}

/** Reset the buffer. Call this AFTER applying an LLM response, so the next
 *  prompt sees only events that happened between responses. */
export function flushEvents(buf: EventBuffer): void { buf.events = []; }

/** Render the event buffer for the LLM prompt (shows EVERY buffered event,
 *  since the buffer represents the gap since the last LLM response). */
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

export interface TaskUpdate {
  /** "all" = wipe every task; "non_loop" = wipe only ONCE/SEQUENCE; undefined = keep. */
  clear?: "all" | "non_loop";
  /** Tasks to append at the END of the list (after clear, if any). Loops are deduped by kind. */
  append?: Task[];
}

/**
 * Apply an LLM update to the current task list.
 *   - clear="all"     -> start from empty list
 *   - clear="non_loop"-> drop every ONCE/SEQUENCE task, keep loops
 *   - append: [...]   -> added to the END. Loops of an existing kind REPLACE
 *                        the existing loop (runtime resets, new interval wins).
 */
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
  } else if (update.clear === "non_loop") {
    if (buf) for (const ti of current) {
      if (!isLoopTask(ti.task)) pushEvent(buf, { tick, task: ti.task, kind: "failed", reason: "clear:non_loop" });
    }
    result = current.filter(ti => isLoopTask(ti.task));
  } else {
    result = [...current];
  }

  if (update.append) {
    for (const task of update.append) {
      if (isLoopTask(task)) {
        const idx = result.findIndex(ti => ti.task.kind === task.kind);
        if (idx >= 0) {
          if (buf) pushEvent(buf, { tick, task: result[idx].task, kind: "replaced", reason: "new loop of same kind" });
          result.splice(idx, 1);
        }
      }
      result.push(createTaskInstance(task, tick));
    }
  }
  return result;
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

function pushChatAction(bot: BotController, action: string): boolean {
  const seq = chatMenuSequence(action);
  if (seq.length === 0) return false;
  if (action === "R.ACCPT" || action === "C.ACCPT") {
    seq.push(BUTTON_A, 0);  // auto-confirm target-select
  }
  bot.actions.push(...seq);
  return true;
}

const CHAT_ACTION_BY_KIND: Record<string, string> = {
  offer_color: "C.OFFER",
  offer_role: "R.OFFER",
  accept_color: "C.ACCPT",
  accept_role: "R.ACCPT",
  grant_entry: "GRANT",
  exit_chatroom: "EXIT",
  show_role_oneway: "ROLE",
};

function tryTask(ti: TaskInstance, bot: BotController, ws: WebSocket): TaskResult {
  const belief = bot.belief;
  const tick = belief.tick;
  const t = ti.task;

  // Time-limit check for sequence tasks
  if (isSequenceTask(t)) {
    const limit = (t as any).timeLimitTicks as number;
    if (tick - ti.startTick > limit) return fail("timeout");
  }

  switch (t.kind) {
    // ---- ONCE chat tasks ----
    case "shout": {
      if (belief.phase !== "playing" && belief.phase !== "hostage_select") return SKIP;
      const sent = t.text.slice(0, CHAT_MAX_TOTAL);
      sendChat(ws, sent);
      sendInput(ws, 0);
      ti.lastFiredTick = tick;
      const truncated = sent.length < t.text.length;
      const reason = truncated
        ? `sent "${sent}" (TRUNCATED from ${t.text.length} → ${CHAT_MAX_TOTAL} chars)`
        : `sent "${sent}"`;
      return emit(reason);
    }
    case "chat": {
      if (belief.phase !== "chatroom") return SKIP;
      const sent = t.text.slice(0, CHAT_MAX_TOTAL);
      sendChat(ws, sent);
      sendInput(ws, 0);
      ti.lastFiredTick = tick;
      const truncated = sent.length < t.text.length;
      const reason = truncated
        ? `sent "${sent}" (TRUNCATED from ${t.text.length} → ${CHAT_MAX_TOTAL} chars)`
        : `sent "${sent}"`;
      return emit(reason);
    }

    case "exit_chatroom": {
      if (belief.phase !== "chatroom") return SKIP;
      if (!pushChatAction(bot, "EXIT")) return fail("chatMenuSequence returned empty");
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }

    // ---- SEQUENCE tasks ----
    case "walk_to": {
      if (belief.phase !== "playing" || !belief.myPos) return SKIP;
      const dx = t.x - belief.myPos.x;
      const dy = t.y - belief.myPos.y;
      if (dx * dx + dy * dy <= 9) return done(`arrived at (${t.x},${t.y})`);
      const mask = moveToward(belief.myPos.x, belief.myPos.y, t.x, t.y);
      sendInput(ws, mask || 0);
      return EMIT;
    }

    case "pursue_chat": {
      if (belief.phase === "waiting_entry" && ti.createdOwnChatroomTick !== null) {
        ti.createdOwnChatroomTick = null;
        ti.grantDeadlineTick = null;
      }

      if (belief.phase === "chatroom") {
        if (ti.createdOwnChatroomTick !== null
            && ti.grantDeadlineTick !== null
            && tick > ti.grantDeadlineTick) {
          if (belief.pendingEntry) {
            if (pushChatAction(bot, "GRANT")) {
              sendInput(ws, bot.actions.shift()!);
              return EMIT;
            }
          }
          if (pushChatAction(bot, "EXIT")) {
            sendInput(ws, bot.actions.shift()!);
            ti.createdOwnChatroomTick = null;
            ti.grantDeadlineTick = null;
            return EMIT;
          }
        }
        return done("entered chatroom");
      }

      if (belief.phase === "waiting_entry") {
        sendInput(ws, 0);
        return EMIT;
      }

      if (belief.phase !== "playing" || !belief.myPos) return SKIP;

      const targetDot = belief.minimapDots.find(
        d => d.color === t.targetColor && !d.isSelf,
      );

      if (!targetDot) {
        if (tick - ti.lastSawTargetTick > 12) return SKIP;
        bot.actions.push(BUTTON_A, 0);
        sendInput(ws, bot.actions.shift()!);
        if (ti.createdOwnChatroomTick === null) {
          ti.createdOwnChatroomTick = tick;
          ti.grantDeadlineTick = tick + 12 + Math.floor(Math.random() * 37);
        }
        return EMIT;
      }

      ti.lastSawTargetTick = tick;

      const dx = targetDot.worldX - belief.myPos.x;
      const dy = targetDot.worldY - belief.myPos.y;
      const distSq = dx * dx + dy * dy;

      if (distSq > 100) {
        const mask = moveToward(belief.myPos.x, belief.myPos.y, targetDot.worldX, targetDot.worldY);
        sendInput(ws, mask || 0);
        return EMIT;
      }

      bot.actions.push(BUTTON_A, 0);
      sendInput(ws, bot.actions.shift()!);
      if (ti.createdOwnChatroomTick === null) {
        ti.createdOwnChatroomTick = tick;
        ti.grantDeadlineTick = tick + 12 + Math.floor(Math.random() * 37);
      }
      return EMIT;
    }

    case "pursue_exchange": {
      // This task owns the full pipeline: walk → chatroom → offer → wait for
      // accept. Succeeds when the sim's offer state clears (a true exchange
      // cleared the offers from both sides), fails on timeout.
      if (belief.phase === "waiting_entry" && ti.createdOwnChatroomTick !== null) {
        ti.createdOwnChatroomTick = null;
        ti.grantDeadlineTick = null;
      }
      if (belief.phase === "waiting_entry") {
        sendInput(ws, 0);
        return EMIT;
      }

      // --- In chatroom: try to exchange ---
      if (belief.phase === "chatroom") {
        // Auto-accept pending offer of matching kind — this completes the exchange.
        const wantRole = t.exchange === "role";
        if (wantRole && belief.pendingRoleOffer) {
          if (pushChatAction(bot, "R.ACCPT")) {
            sendInput(ws, bot.actions.shift()!);
            return done("accepted role offer (exchange in progress)");
          }
        }
        if (!wantRole && belief.pendingColorOffer) {
          if (pushChatAction(bot, "C.ACCPT")) {
            sendInput(ws, bot.actions.shift()!);
            return done("accepted color offer (exchange in progress)");
          }
        }

        // If we already sent our offer: if it got consumed (sim completed the
        // exchange) the pending flag from us clears — we'd see the offers gone
        // from the chatroom. We can't query sim state directly, but if we've
        // waited more than ~30 ticks after offering and the occupant is still
        // with us, the exchange probably completed. Succeed.
        if (ti.offerSentTick !== null) {
          if (tick - ti.offerSentTick > 30) {
            return done("offer completed (timeout-success)");
          }
          sendInput(ws, 0);
          return EMIT;
        }

        // Need another occupant before offering. If alone, just wait or retry.
        if (belief.occupantCount < 2) {
          // If our grant deadline passed, exit so we can re-pursue.
          if (ti.createdOwnChatroomTick !== null
              && ti.grantDeadlineTick !== null
              && tick > ti.grantDeadlineTick) {
            if (pushChatAction(bot, "EXIT")) {
              sendInput(ws, bot.actions.shift()!);
              ti.createdOwnChatroomTick = null;
              ti.grantDeadlineTick = null;
              return EMIT;
            }
          }
          // Grant if anyone's trying to join (they might be our target).
          if (belief.pendingEntry && pushChatAction(bot, "GRANT")) {
            sendInput(ws, bot.actions.shift()!);
            return EMIT;
          }
          sendInput(ws, 0);
          return EMIT;
        }

        // We have company — send our offer.
        const action = wantRole ? "R.OFFER" : "C.OFFER";
        if (pushChatAction(bot, action)) {
          sendInput(ws, bot.actions.shift()!);
          ti.offerSentTick = tick;
          return EMIT;
        }
        return fail("chatMenuSequence for offer returned empty");
      }

      // --- Overworld: walk toward target ---
      if (belief.phase !== "playing" || !belief.myPos) return SKIP;

      const targetDot = belief.minimapDots.find(
        d => d.color === t.targetColor && !d.isSelf,
      );

      if (!targetDot) {
        // Target may be on top of us (self-dot overwrites). Press A if we saw
        // them very recently.
        if (tick - ti.lastSawTargetTick > 12) return SKIP;
        bot.actions.push(BUTTON_A, 0);
        sendInput(ws, bot.actions.shift()!);
        if (ti.createdOwnChatroomTick === null) {
          ti.createdOwnChatroomTick = tick;
          ti.grantDeadlineTick = tick + 12 + Math.floor(Math.random() * 37);
        }
        return EMIT;
      }

      ti.lastSawTargetTick = tick;

      const dxe = targetDot.worldX - belief.myPos.x;
      const dye = targetDot.worldY - belief.myPos.y;
      const distSqE = dxe * dxe + dye * dye;

      if (distSqE > 100) {
        const mask = moveToward(belief.myPos.x, belief.myPos.y, targetDot.worldX, targetDot.worldY);
        sendInput(ws, mask || 0);
        return EMIT;
      }

      // Within bubble — press A to create/join chatroom.
      bot.actions.push(BUTTON_A, 0);
      sendInput(ws, bot.actions.shift()!);
      if (ti.createdOwnChatroomTick === null) {
        ti.createdOwnChatroomTick = tick;
        ti.grantDeadlineTick = tick + 12 + Math.floor(Math.random() * 37);
      }
      return EMIT;
    }

    // ---- LOOP tasks ----
    case "loop_auto_grant": {
      if (belief.phase !== "chatroom" || !belief.pendingEntry) return SKIP;
      if (!pushChatAction(bot, "GRANT")) return SKIP;
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }
    case "loop_auto_accept_color": {
      if (belief.phase !== "chatroom" || !belief.pendingColorOffer) return SKIP;
      if (!pushChatAction(bot, "C.ACCPT")) return SKIP;
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }
    case "loop_auto_accept_role": {
      if (belief.phase !== "chatroom" || !belief.pendingRoleOffer) return SKIP;
      if (!pushChatAction(bot, "R.ACCPT")) return SKIP;
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }

    case "loop_read_global": {
      const interval = t.intervalTicks;
      if (tick - ti.lastFiredTick < interval) return SKIP;
      ti.lastFiredTick = tick;
      return SKIP;
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
  const tick = bot.belief.tick;

  // Priority 0: drain in-progress action queue
  if (!bot.actions.empty) {
    sendInput(ws, bot.actions.shift()!);
    return tasks;
  }

  // Priority 1: waiting_entry — sit still
  if (bot.belief.phase === "waiting_entry") {
    sendInput(ws, 0);
    return tasks;
  }

  const kept: TaskInstance[] = [];
  let emitted = false;

  for (const ti of tasks) {
    if (emitted) { kept.push(ti); continue; }
    const result = tryTask(ti, bot, ws);

    if (result.kind === "emitted") {
      // First successful fire of this task — emit "started".
      if (buf && !ti.startedEmitted) {
        pushEvent(buf, { tick, task: ti.task, kind: "started" });
        ti.startedEmitted = true;
      }
      if (isOnceTask(ti.task)) {
        if (buf) pushEvent(buf, { tick, task: ti.task, kind: "fired", reason: result.reason });
        // drop
      } else {
        kept.push(ti);
      }
      emitted = true;
    } else if (result.kind === "done") {
      if (buf) pushEvent(buf, { tick, task: ti.task, kind: "succeeded", reason: result.reason });
      // drop
    } else if (result.kind === "failed") {
      if (buf) pushEvent(buf, { tick, task: ti.task, kind: "failed", reason: result.reason });
      // drop
    } else {
      // skip — keep task, continue
      kept.push(ti);
    }
  }

  if (!emitted) sendInput(ws, 0);
  return kept;
}

// ---------------------------------------------------------------------------
// LLM response parsing
// ---------------------------------------------------------------------------

const VALID_KINDS = new Set<string>([
  "shout", "chat", "exit_chatroom",
  "walk_to", "pursue_chat", "pursue_exchange",
  "loop_auto_grant", "loop_auto_accept_color", "loop_auto_accept_role",
  "loop_read_global",
]);

function coerceTask(raw: any): Task | null {
  if (!raw || typeof raw !== "object" || typeof raw.kind !== "string") return null;
  if (!VALID_KINDS.has(raw.kind)) return null;
  const k = raw.kind;
  switch (k) {
    case "shout":
    case "chat":
      return typeof raw.text === "string" ? { kind: k, text: String(raw.text) } : null;
    case "pursue_chat":
      return Number.isFinite(raw.targetColor) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "pursue_chat", targetColor: raw.targetColor | 0, timeLimitTicks: raw.timeLimitTicks | 0 } : null;
    case "pursue_exchange": {
      const ex = raw.exchange === "role" || raw.exchange === "color" ? raw.exchange : null;
      if (!ex) return null;
      return Number.isFinite(raw.targetColor) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "pursue_exchange", targetColor: raw.targetColor | 0, exchange: ex, timeLimitTicks: raw.timeLimitTicks | 0 } : null;
    }
    case "walk_to":
      return Number.isFinite(raw.x) && Number.isFinite(raw.y) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "walk_to", x: raw.x | 0, y: raw.y | 0, timeLimitTicks: raw.timeLimitTicks | 0 } : null;
    case "loop_read_global":
      return Number.isFinite(raw.intervalTicks)
        ? { kind: k, intervalTicks: Math.max(1, raw.intervalTicks | 0) } : null;
    case "exit_chatroom":
    case "loop_auto_grant": case "loop_auto_accept_color": case "loop_auto_accept_role":
      return { kind: k } as Task;
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
    if (obj.clear === "all" || obj.clear === "non_loop") {
      update.clear = obj.clear;
    } else if (obj.clear === true) {
      // tolerate "clear: true" as an alias for "all"
      update.clear = "all";
    }
    if (Array.isArray(obj.append)) {
      update.append = obj.append.map(coerceTask).filter((x: Task | null): x is Task => x !== null);
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
    if (isSequenceTask(t)) {
      const limit = (t as any).timeLimitTicks as number;
      meta.push(`elapsed=${tick - ti.startTick}/${limit}`);
      if (t.kind === "pursue_chat" && ti.createdOwnChatroomTick !== null) {
        const remaining = ti.grantDeadlineTick !== null ? ti.grantDeadlineTick - tick : "?";
        meta.push(`own_chatroom wait=${remaining}`);
      }
    }
    if (isLoopTask(t) && "intervalTicks" in t) {
      meta.push(`interval=${(t as any).intervalTicks} last=${ti.lastFiredTick}`);
    }
    const body = JSON.stringify(t);
    lines.push(`  [${i + 1}] ${body}${meta.length ? " (" + meta.join(" ") + ")" : ""}`);
  }
  return lines;
}

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
 * Movement tasks don't run while in whisper. Whisper tasks don't run while
 * in overworld. Tasks that can't apply in the current phase are skipped, not
 * removed — they wait for the phase to change (subject to their time limit).
 */

import type WebSocket from "ws";
import { BUTTON_A, BUTTON_B, BUTTON_LEFT, BUTTON_RIGHT, BUTTON_SELECT, isValidCharacterName, characterName } from "../game/constants.js";
import { sendInput, sendChat, truncateChatInput, moveToward, menuSequence, COMMAND_ACTIONS } from "./bot_utils.js";
import { whisperMenuSequenceWithTargetPick } from "../game/menu_defs.js";
import { parseHostageGrid, parseUsurpCandidate } from "./frame_parser.js";
import { colorFromCharName, type BeliefState } from "./belief_state.js";
import type { BotController } from "./bot_common.js";
import type { MinimapDot } from "./frame_parser.js";

// ---------------------------------------------------------------------------
// Task definitions
// ---------------------------------------------------------------------------

export type Task =
  // ONCE tasks
  | { kind: "shout"; text: string }
  | { kind: "chat"; text: string }
  | { kind: "exit_whisper" }
  // SEQUENCE tasks — high level; handle their own whisper dance
  | { kind: "walk_to"; x: number; y: number; timeLimitTicks: number }
  | { kind: "pursue_chat"; target: string; timeLimitTicks: number }
  /**
   * pursue_exchange — walk to target, get into the same whisper, then
   * perform a mutual exchange. "role" triggers R.OFFER and auto-accepts any
   * pending R offer from that target. "color" does the same with C.OFFER/C.ACCPT.
   */
  | { kind: "pursue_exchange"; target: string; exchange: "role" | "color"; timeLimitTicks: number }
  // LOOP tasks (singleton per kind)
  | { kind: "loop_auto_grant" }
  | { kind: "loop_auto_accept_color" }
  | { kind: "loop_auto_accept_role" }
  // SEQUENCE — usurp vote
  | { kind: "usurp_vote"; target: string; timeLimitTicks: number }
  // PRECOMMIT — persists like a loop, fires once when conditions are met, then stays for next round
  | { kind: "precommit_hostages"; targets: string[] };

// Each task kind must appear in exactly one of these sets. If you add a new
// kind, put it in the correct set — the classification functions use strict
// lookups, so an omitted kind will fail isOnceTask/isSequenceTask/isLoopTask.
const ONCE_KINDS = new Set<string>([
  "shout", "chat", "exit_whisper",
]);

const SEQUENCE_KINDS = new Set<string>([
  "walk_to", "pursue_chat", "pursue_exchange", "usurp_vote",
]);

const LOOP_KINDS = new Set<string>([
  "loop_auto_grant", "loop_auto_accept_color", "loop_auto_accept_role",
  "precommit_hostages",
]);

export function isOnceTask(t: Task): boolean { return ONCE_KINDS.has(t.kind); }
export function isSequenceTask(t: Task): boolean { return SEQUENCE_KINDS.has(t.kind); }
export function isLoopTask(t: Task): boolean { return LOOP_KINDS.has(t.kind); }

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------

export interface TaskInstance {
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
  // pursue_exchange: detailed status for LLM visibility
  exchangeStatus: string;
  // precommit_hostages state machine
  hostageState: "idle" | "opening_chat" | "selecting" | "committing" | "done";
  hostageRound: number;
  // usurp_vote state machine
  usurpState: "idle" | "opening" | "navigating" | "voting" | "closing";
  usurpNavCount: number;
}

export function createTaskInstance(task: Task, tick: number): TaskInstance {
  return {
    task, startTick: tick, lastFiredTick: -1,
    createdOwnWhisperTick: null, grantDeadlineTick: null,
    lastSawTargetTick: -Infinity, startedEmitted: false,
    offerSentTick: null, exchangeStatus: "searching for target",
    hostageState: "idle", hostageRound: -1,
    usurpState: "idle", usurpNavCount: 0,
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

export interface TaskUpdate {
  clear?: "all" | "non_loop" | "non_loop_unsafe";
  append?: Task[];
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
// Target resolution — character name → minimap dot
// ---------------------------------------------------------------------------

function findTargetDot(belief: BeliefState, target: string): MinimapDot | undefined {
  const targetColor = colorFromCharName(target);
  if (targetColor === null) return undefined;
  const dots = belief.minimapDots.filter(d => d.color === targetColor && !d.isSelf);
  if (dots.length <= 1) return dots[0];
  // Ambiguous color — use last known position to disambiguate
  const player = belief.players.get(target);
  if (!player?.lastPos) return dots[0];
  let best = dots[0], bestDist = Infinity;
  for (const d of dots) {
    const dist = (d.worldX - player.lastPos.x) ** 2 + (d.worldY - player.lastPos.y) ** 2;
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

function pushChatAction(bot: BotController, action: string): boolean {
  const seq = whisperMenuSequenceWithTargetPick(action);
  if (seq.length === 0) return false;
  bot.actions.push(...seq);
  return true;
}

const GRANT_WAIT_MIN_TICKS = 12;
const GRANT_WAIT_JITTER_TICKS = 37;
function randomGrantDeadline(tick: number): number {
  return tick + GRANT_WAIT_MIN_TICKS + Math.floor(Math.random() * GRANT_WAIT_JITTER_TICKS);
}

function tryTask(ti: TaskInstance, bot: BotController, ws: WebSocket): TaskResult {
  const belief = bot.belief;
  const tick = belief.tick;
  const t = ti.task;

  // Time-limit check for sequence tasks
  if (isSequenceTask(t)) {
    const limit = (t as any).timeLimitTicks as number;
    if (tick - ti.startTick > limit) return fail("timeout");
  }

  const fireChat = (raw: string): TaskResult => {
    const { sent, truncated } = truncateChatInput(raw);
    sendChat(ws, sent);
    sendInput(ws, 0);
    ti.lastFiredTick = tick;
    const reason = truncated
      ? `sent "${sent}" (TRUNCATED from ${raw.length} chars)`
      : `sent "${sent}"`;
    return emit(reason);
  };

  switch (t.kind) {
    // ---- ONCE chat tasks ----
    case "shout": {
      if (belief.phase !== "playing" && belief.phase !== "hostage_select" && belief.phase !== "leader_summit") return SKIP;
      return fireChat(t.text);
    }
    case "chat": {
      if (belief.phase !== "whisper" && belief.phase !== "leader_summit") return SKIP;
      return fireChat(t.text);
    }

    case "exit_whisper": {
      if (belief.phase !== "whisper") return SKIP;
      if (!pushChatAction(bot, "EXIT")) return fail("whisperMenuSequence returned empty");
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }

    // ---- SEQUENCE tasks ----
    case "walk_to": {
      if ((belief.phase !== "playing" && belief.phase !== "leader_summit") || !belief.myPos) return SKIP;
      const dx = t.x - belief.myPos.x;
      const dy = t.y - belief.myPos.y;
      if (dx * dx + dy * dy <= 9) return done(`arrived at (${t.x},${t.y})`);
      const mask = moveToward(belief.myPos.x, belief.myPos.y, t.x, t.y);
      sendInput(ws, mask || 0);
      return EMIT;
    }

    case "pursue_chat": {
      if (belief.phase === "waiting_entry" && ti.createdOwnWhisperTick !== null) {
        ti.createdOwnWhisperTick = null;
        ti.grantDeadlineTick = null;
      }

      if (belief.phase === "whisper") {
        if (ti.createdOwnWhisperTick !== null
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
            ti.createdOwnWhisperTick = null;
            ti.grantDeadlineTick = null;
            return EMIT;
          }
        }
        return done("entered whisper");
      }

      if (belief.phase === "waiting_entry") {
        sendInput(ws, 0);
        return EMIT;
      }

      if ((belief.phase !== "playing" && belief.phase !== "leader_summit") || !belief.myPos) return SKIP;

      const targetDot = findTargetDot(belief, t.target);

      if (!targetDot) {
        if (tick - ti.lastSawTargetTick > 12) return SKIP;
        bot.actions.push(BUTTON_A, 0);
        sendInput(ws, bot.actions.shift()!);
        if (ti.createdOwnWhisperTick === null) {
          ti.createdOwnWhisperTick = tick;
          ti.grantDeadlineTick = randomGrantDeadline(tick);
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
      if (ti.createdOwnWhisperTick === null) {
        ti.createdOwnWhisperTick = tick;
        ti.grantDeadlineTick = randomGrantDeadline(tick);
      }
      return EMIT;
    }

    case "pursue_exchange": {
      if (belief.phase === "waiting_entry" && ti.createdOwnWhisperTick !== null) {
        ti.createdOwnWhisperTick = null;
        ti.grantDeadlineTick = null;
      }
      if (belief.phase === "waiting_entry") {
        ti.exchangeStatus = "waiting for entry to whisper";
        sendInput(ws, 0);
        return EMIT;
      }

      // --- In whisper: try to exchange ---
      if (belief.phase === "whisper") {
        const wantRole = t.exchange === "role";
        const targetBelief = belief.players.get(t.target);
        const targetInWhisper = belief.occupantNames.includes(t.target);
        const occupantList = belief.occupantNames.join(", ");
        const occCount = belief.occupantCount;

        // Check if exchange already completed (belief updated from info screen / system msgs)
        if (targetBelief) {
          if (wantRole && targetBelief.knownRole) {
            return done(`role exchange complete — ${t.target} is ${targetBelief.knownRole}`);
          }
          if (!wantRole && targetBelief.knownTeam) {
            return done(`color exchange complete — ${t.target} is ${targetBelief.knownTeam}`);
          }
        }

        // Accept pending offers from others
        if (wantRole && belief.pendingRoleOffer) {
          if (pushChatAction(bot, "R.ACCPT")) {
            ti.exchangeStatus = `accepting role offer (${occCount} in whisper: ${occupantList})`;
            sendInput(ws, bot.actions.shift()!);
            return EMIT;
          }
        }
        if (!wantRole && belief.pendingColorOffer) {
          if (pushChatAction(bot, "C.ACCPT")) {
            ti.exchangeStatus = `accepting color offer (${occCount} in whisper: ${occupantList})`;
            sendInput(ws, bot.actions.shift()!);
            return EMIT;
          }
        }

        // We already sent our offer — wait for others or check completion
        if (ti.offerSentTick !== null) {
          const waitTicks = tick - ti.offerSentTick;
          if (wantRole) {
            ti.exchangeStatus = `offer sent, waiting ${waitTicks} ticks — ${occCount} occupants: [${occupantList}]`
              + (targetInWhisper ? ` — target ${t.target} IS here` : ` — target ${t.target} NOT in whisper`)
              + (belief.pendingRoleOffer ? " — R! indicator (someone offered back)" : " — no R! indicator yet");
          } else {
            ti.exchangeStatus = `offer sent, waiting ${waitTicks} ticks — ${occCount} occupants: [${occupantList}]`
              + (targetInWhisper ? ` — target ${t.target} IS here` : ` — target ${t.target} NOT in whisper`)
              + (belief.pendingColorOffer ? " — C! indicator (someone offered back)" : " — no C! indicator yet");
          }
          if (waitTicks > 72) {
            return fail(`offer timed out after ${waitTicks} ticks — ${ti.exchangeStatus}`);
          }
          sendInput(ws, 0);
          return EMIT;
        }

        // Alone in whisper — grant entry or wait
        if (belief.occupantCount < 2) {
          ti.exchangeStatus = "alone in whisper, waiting for others to join";
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
          if (belief.pendingEntry && pushChatAction(bot, "GRANT")) {
            ti.exchangeStatus = "granting entry to pending player";
            sendInput(ws, bot.actions.shift()!);
            return EMIT;
          }
          sendInput(ws, 0);
          return EMIT;
        }

        // 2+ occupants — send our offer
        ti.exchangeStatus = `sending ${t.exchange} offer — ${occCount} occupants: [${occupantList}]`
          + (targetInWhisper ? ` — target ${t.target} IS here` : ` — target ${t.target} NOT in whisper`);
        const action = wantRole ? "R.OFFER" : "C.OFFER";
        if (pushChatAction(bot, action)) {
          sendInput(ws, bot.actions.shift()!);
          ti.offerSentTick = tick;
          return EMIT;
        }
        return fail("whisperMenuSequence for offer returned empty");
      }

      // --- Overworld: walk toward target ---
      if ((belief.phase !== "playing" && belief.phase !== "leader_summit") || !belief.myPos) return SKIP;

      const targetDot = findTargetDot(belief, t.target);

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

      ti.lastSawTargetTick = tick;

      const dxe = targetDot.worldX - belief.myPos.x;
      const dye = targetDot.worldY - belief.myPos.y;
      const distSqE = dxe * dxe + dye * dye;

      if (distSqE > 100) {
        const dist = Math.round(Math.sqrt(distSqE));
        ti.exchangeStatus = `walking to ${t.target} — ${dist} units away`;
        const mask = moveToward(belief.myPos.x, belief.myPos.y, targetDot.worldX, targetDot.worldY);
        sendInput(ws, mask || 0);
        return EMIT;
      }

      ti.exchangeStatus = `reached ${t.target}, opening whisper`;
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
      if (belief.phase !== "whisper" || !belief.pendingEntry) return SKIP;
      if (!pushChatAction(bot, "GRANT")) return SKIP;
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }
    case "loop_auto_accept_color": {
      if (belief.phase !== "whisper" || !belief.pendingColorOffer) return SKIP;
      if (!pushChatAction(bot, "C.ACCPT")) return SKIP;
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }
    case "loop_auto_accept_role": {
      if (belief.phase !== "whisper" || !belief.pendingRoleOffer) return SKIP;
      if (!pushChatAction(bot, "R.ACCPT")) return SKIP;
      sendInput(ws, bot.actions.shift()!);
      ti.lastFiredTick = tick;
      return EMIT;
    }

    case "usurp_vote": {
      if (belief.phase !== "playing" && belief.phase !== "unknown" && belief.phase !== "hostage_select") return SKIP;
      if (belief.amLeader) return fail("I am leader, cannot usurp");

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
          sendInput(ws, 0);
          return EMIT;
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
        if (cand.isPlayer && targetColor !== null && cand.color === targetColor) {
          bot.actions.push(BUTTON_A, 0);
          sendInput(ws, bot.actions.shift()!);
          ti.usurpState = "closing";
          return EMIT;
        }

        if (ti.usurpNavCount > 14) return fail("target not in candidate list");
        bot.actions.push(BUTTON_RIGHT, 0);
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

    case "precommit_hostages": {
      if (belief.phase !== "hostage_select") {
        if (ti.hostageState !== "idle") {
          ti.hostageState = "idle";
          ti.hostageRound = -1;
        }
        return SKIP;
      }
      if (!belief.amLeader) return SKIP;

      if (ti.hostageState === "done" && ti.hostageRound === belief.round) return SKIP;

      if (ti.hostageState === "idle" || (ti.hostageState === "done" && ti.hostageRound !== belief.round)) {
        ti.hostageState = "opening_chat";
        ti.hostageRound = belief.round;
        const items = ["SHOUT", "INFO"];
        const seq = menuSequence("comm", "SHOUT", items);
        bot.actions.push(...seq);
        sendInput(ws, bot.actions.shift()!);
        return EMIT;
      }

      if (ti.hostageState === "opening_chat") {
        if (!bot.lastFrame) { sendInput(ws, 0); return EMIT; }
        const grid = parseHostageGrid(bot.lastFrame);
        if (!grid) {
          sendInput(ws, 0);
          return EMIT;
        }
        ti.hostageState = "selecting";
      }

      if (ti.hostageState === "selecting") {
        if (!bot.lastFrame) { sendInput(ws, 0); return EMIT; }
        const grid = parseHostageGrid(bot.lastFrame);
        if (!grid) { sendInput(ws, 0); return EMIT; }

        // Build character names for each grid entry, match against targets
        const targetSet = new Set(t.targets);

        for (let i = 0; i < grid.eligible.length; i++) {
          const entry = grid.eligible[i];
          const entryName = entry.shape !== null
            ? characterName(entry.color, entry.shape)
            : null;
          const isTarget = entryName !== null && targetSet.has(entryName);
          const isSelected = grid.selectedPositions.includes(i);
          if (isTarget && !isSelected) {
            const delta = i - grid.cursorPosition;
            if (delta > 0) {
              for (let d = 0; d < delta; d++) bot.actions.push(BUTTON_RIGHT, 0);
            } else if (delta < 0) {
              for (let d = 0; d < -delta; d++) bot.actions.push(BUTTON_LEFT, 0);
            }
            bot.actions.push(BUTTON_A, 0);
            sendInput(ws, bot.actions.shift()!);
            return EMIT;
          }
          if (!isTarget && isSelected) {
            const delta = i - grid.cursorPosition;
            if (delta > 0) {
              for (let d = 0; d < delta; d++) bot.actions.push(BUTTON_RIGHT, 0);
            } else if (delta < 0) {
              for (let d = 0; d < -delta; d++) bot.actions.push(BUTTON_LEFT, 0);
            }
            bot.actions.push(BUTTON_A, 0);
            sendInput(ws, bot.actions.shift()!);
            return EMIT;
          }
        }

        ti.hostageState = "committing";
        bot.actions.push(BUTTON_B, 0);
        sendInput(ws, bot.actions.shift()!);
        return EMIT;
      }

      if (ti.hostageState === "committing") {
        ti.hostageState = "done";
        return SKIP;
      }

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

  if (!bot.actions.empty) {
    sendInput(ws, bot.actions.shift()!);
    return tasks;
  }

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
      if (buf && !ti.startedEmitted) {
        pushEvent(buf, { tick, task: ti.task, kind: "started" });
        ti.startedEmitted = true;
      }
      if (isOnceTask(ti.task)) {
        if (buf) pushEvent(buf, { tick, task: ti.task, kind: "fired", reason: result.reason });
      } else {
        kept.push(ti);
      }
      emitted = true;
    } else if (result.kind === "done") {
      if (buf) pushEvent(buf, { tick, task: ti.task, kind: "succeeded", reason: result.reason });
    } else if (result.kind === "failed") {
      if (buf) pushEvent(buf, { tick, task: ti.task, kind: "failed", reason: result.reason });
    } else {
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
  "shout", "chat", "exit_whisper",
  "walk_to", "pursue_chat", "pursue_exchange", "usurp_vote",
  "loop_auto_grant", "loop_auto_accept_color", "loop_auto_accept_role",
  "precommit_hostages",
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
      return typeof raw.target === "string" && isValidCharacterName(raw.target) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "pursue_chat", target: raw.target, timeLimitTicks: raw.timeLimitTicks | 0 } : null;
    case "pursue_exchange": {
      const ex = raw.exchange === "role" || raw.exchange === "color" ? raw.exchange : null;
      if (!ex) return null;
      return typeof raw.target === "string" && isValidCharacterName(raw.target) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "pursue_exchange", target: raw.target, exchange: ex, timeLimitTicks: raw.timeLimitTicks | 0 } : null;
    }
    case "usurp_vote":
      return typeof raw.target === "string" && isValidCharacterName(raw.target) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "usurp_vote", target: raw.target, timeLimitTicks: raw.timeLimitTicks | 0 } : null;
    case "walk_to":
      return Number.isFinite(raw.x) && Number.isFinite(raw.y) && Number.isFinite(raw.timeLimitTicks)
        ? { kind: "walk_to", x: raw.x | 0, y: raw.y | 0, timeLimitTicks: raw.timeLimitTicks | 0 } : null;
    case "exit_whisper":
    case "loop_auto_grant": case "loop_auto_accept_color": case "loop_auto_accept_role":
      return { kind: k } as Task;
    case "precommit_hostages": {
      if (!Array.isArray(raw.targets)) return null;
      const targets = raw.targets.filter((s: any) => typeof s === "string" && isValidCharacterName(s));
      return targets.length > 0 ? { kind: "precommit_hostages", targets } : null;
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
    if (t.kind === "precommit_hostages" && ti.hostageState !== "idle") {
      meta.push(`state=${ti.hostageState} round=${ti.hostageRound}`);
    }
    const body = JSON.stringify(t);
    lines.push(`  [${i + 1}] ${body}${meta.length ? " (" + meta.join(" ") + ")" : ""}`);
  }
  return lines;
}

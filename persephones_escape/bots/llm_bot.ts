/**
 * LLM Bot — task-based control loop.
 *
 * The LLM emits an ordered task list (append/prepend/cancel/clear). The bot
 * executes tasks top-to-bottom each frame; ONCE tasks self-remove after
 * firing, SEQUENCE tasks terminate on done/timeout, LOOP tasks persist
 * (singleton per kind) until the LLM cancels/clears.
 *
 * Usage:
 *   tsx llm_bot.ts [--name bot_name] [--url ws://...] [--model <id>] [--region us-west-2]
 */

import WebSocket from "ws";
import { argv } from "process";
import {
  BedrockRuntimeClient, ConverseCommand, type Message,
} from "@aws-sdk/client-bedrock-runtime";
import { PACKED_FRAME_BYTES, unpackFrame, ActionQueue } from "../bot_utils.js";
import {
  createBeliefState, updatePhase, updatePosition, updateMinimap, updateHud,
  checkTriggers, formatContextDump,
  type TriggerEvent,
} from "../belief_state.js";
import { parseArgs, type BotController } from "./bot_common.js";
import {
  mergeTasks, parseTaskUpdate, runTasks, tasksToPromptLines,
  createEventBuffer, eventBufferLines, flushEvents,
  type TaskInstance, type EventBuffer,
} from "./tasks.js";

const cliArgs = parseArgs(argv.slice(2));
const botUrl = cliArgs["url"] ?? "ws://localhost:8080/player";
const botName = cliArgs["name"] ?? "llm_bot";
const modelId = cliArgs["model"] ?? "us.anthropic.claude-haiku-4-5-20251001-v1:0";
const region = cliArgs["region"] ?? "us-west-2";

const bedrock = new BedrockRuntimeClient({ region });

const SYSTEM_PROMPT = `You are the STRATEGY LAYER of an autonomous bot playing Persephone's Escape (Two Rooms and a Boom variant). You do NOT pick one action per tick. You maintain an ORDERED TASK LIST. The bot executor walks the list top-to-bottom each frame and runs the first task that produces an action.

============================================================
GAME RULES (brief)
============================================================
- Two teams: Shades (red) and Nymphs (blue). Two disjoint rooms (Underworld, Mortal Realm).
- Key roles: Hades & Cerberus (Shades), Persephone & Demeter (Nymphs).
- Win = mutual role_offer + role_accept between the two keys of a team.
- Chatrooms are local. Another player can only join if you GRANT their entry request.
- Verbal chat/shout can lie; revealed colors and roles are always truthful.

============================================================
TASK SYSTEM
============================================================

Three task categories:

## ONCE — fires once then is removed
  { "kind": "shout", "text": "meet at 10 10" }        // overworld-only global chat
  { "kind": "chat", "text": "i am hades" }            // in-chatroom only
  { "kind": "exit_chatroom" }                         // leave current chatroom

  NOTE on chat/shout text: messages are limited to 2 lines of 18 characters each
  (36 chars total). Anything longer is truncated. Keep text short and dense —
  "meet 50 50" not "teammates please meet me at coordinates 50, 50 for an exchange".

## SEQUENCE — multi-frame; self-terminates on success/failure/timeout
  { "kind": "walk_to", "x": 10, "y": 10, "timeLimitTicks": 240 }
      Straightforward walk to a world coord. Done within 3 units or on timeout.

  { "kind": "pursue_chat", "targetColor": 7, "timeLimitTicks": 240 }
      Walk toward target. In range, press A to create/join a chatroom.
      Succeeds once in a chatroom; fails on timeout.

  { "kind": "pursue_exchange", "targetColor": 7, "exchange": "role", "timeLimitTicks": 360 }
      Full pipeline: walk to target → enter/create chatroom → when a second
      occupant is present, send OFFER of the chosen kind → if they offer back,
      auto-accept → exchange completes. Fails on timeout.
      "exchange" is either "role" (WIN trigger between key pair) or "color" (safe, reveals team).

## LOOP — singleton per kind; persists until cancelled.
  { "kind": "loop_auto_grant" }              // auto-grant any pending chatroom entry
  { "kind": "loop_auto_accept_color" }       // auto-accept any incoming color offer
  { "kind": "loop_auto_accept_role" }        // auto-accept any incoming role offer (WIN if partner)

============================================================
RESPONSE FORMAT
============================================================

Emit ONE JSON object:

{
  "clear": "all" | "non_loop",   // optional: wipe list before appending
                                 //   "all"      = drop everything, including loops
                                 //   "non_loop" = drop only ONCE/SEQUENCE tasks, keep loops
  "append": [ {task}, ... ]      // tasks to add at the END of the list
}

If you have nothing to change, emit: {}

Tasks run top-to-bottom. Since new tasks go to the END, PUT URGENT WORK FIRST by pairing clear+append:
  - To pivot fast: { "clear": "non_loop", "append": [ {new urgent task}, ... ] }
  - To just add more work: { "append": [ ... ] }

Loops are deduplicated by kind automatically — appending a new loop of the same kind replaces the old one (interval overwritten).

============================================================
EACH PROMPT CONTAINS
============================================================

1. FULL BELIEF STATE (role, team, room, position, phase, nearby players, minimap dots, known players, recent shouts, pending offers/entries, etc.).
2. CURRENT TASK LIST (ordered).
3. TASK EVENTS SINCE LAST RESPONSE — everything that happened in the window between your previous response and this prompt:
     started   — a task first fired
     fired     — ONCE task emitted its action (offer_color, grant_entry, ...)
     succeeded — SEQUENCE task completed (e.g. pursue_chat entered chatroom)
     failed    — task failed (timeout, missing precondition, cleared, ...)
     replaced  — LOOP task was replaced by a new one of the same kind

The event log is flushed when you see it, so events between your response and the next prompt appear in that next prompt. You do NOT need to re-queue tasks that already succeeded.

============================================================
PHASE ROUTING (handled automatically)
============================================================
- waiting_entry phase: bot sits still; any button would cancel the entry request.
- chatroom phase: movement/shout/walk_to tasks are SKIPPED (wait for chatroom exit).
- playing phase: chat/offer_*/accept_*/grant_entry tasks are SKIPPED.

So you can keep unrelated tasks in the list; they just wait for the right phase.

============================================================
STRATEGY
============================================================
- All players named "llm_*" are on the SAME team (Shades, TeamA). Random smart bots are Nymphs.
- If you're Hades or Cerberus: you need to find your partner (the OTHER key role) and complete a mutual role exchange. Since both of you and the Shades grunt are LLMs, any "llm_*" player could be your partner.
- A simple winning recipe:
    1. At game_start, if you're Hades or Cerberus, append:
         { "kind": "loop_auto_grant" }
         { "kind": "loop_auto_accept_role" }   // will accept if the other LLM offers
         { "kind": "pursue_exchange", "targetColor": <some-llm-color>, "exchange": "role", "timeLimitTicks": 720 }
       On succeed, your team wins. On fail/timeout, pick another color and retry.
    2. If you're the Shades grunt, just help: enable loop_auto_grant and walk/pursue_chat around so key-role LLMs can find each other. DO NOT enable loop_auto_accept_role (you're not a key role).
- When in doubt about who is who (the other LLMs haven't identified themselves), pursue_exchange one color at a time. Each failed attempt eliminates a possibility.

OUTPUT: A SINGLE JSON OBJECT. No prose, no markdown fences.`;

const history: Message[] = [];

async function askLLM(context: string): Promise<string> {
  history.push({ role: "user", content: [{ text: context }] });
  if (history.length > 16) history.splice(0, history.length - 8);
  try {
    const resp = await bedrock.send(new ConverseCommand({
      modelId,
      system: [{ text: SYSTEM_PROMPT }],
      messages: history,
      inferenceConfig: { maxTokens: 600, temperature: 0.3 },
    }));
    const text = resp.output?.message?.content?.[0]?.text ?? "{}";
    history.push({ role: "assistant", content: [{ text }] });
    return text.trim();
  } catch (e: any) {
    console.error(`[${botName}] Bedrock error:`, e.message);
    return "{}";
  }
}

// ---- Bot state ----

const ws = new WebSocket(`${botUrl}?name=${botName}`, { perMessageDeflate: false });
const belief = createBeliefState(botName);

const bot: BotController = {
  ws, actions: new ActionQueue(), belief, name: botName,
  movementTarget: null, wandering: false,
  wanderTarget: null, wanderTicks: 0,
};

let tasks: TaskInstance[] = [];
const events: EventBuffer = createEventBuffer();
let llmBusy = false;
let lastPromptTick = -999;

async function promptLLM(event: TriggerEvent): Promise<void> {
  if (llmBusy) return;
  llmBusy = true;
  lastPromptTick = belief.tick;

  const context =
    formatContextDump(belief, event) +
    "\n\nCURRENT TASK LIST:\n" +
    tasksToPromptLines(tasks, belief.tick).join("\n") +
    "\n\nTASK EVENTS SINCE LAST RESPONSE:\n" +
    eventBufferLines(events).join("\n");

  // Flush now: events that fire between this moment and the NEXT prompt
  // (including during the LLM round-trip) belong to the next buffer window.
  flushEvents(events);

  console.log(`[${botName}] → LLM (${event})\n${context}\n---`);
  try {
    const raw = await askLLM(context);
    console.log(`[${botName}] ← LLM: ${raw}`);
    const update = parseTaskUpdate(raw, botName);
    if (update) {
      tasks = mergeTasks(tasks, update, belief.tick, events);
      console.log(`[${botName}] tasks now: ${tasks.length} -> ${tasks.map(ti => ti.task.kind).join(", ")}`);
    }
  } catch (e: any) {
    console.error(`[${botName}] LLM error:`, e.message);
  } finally {
    llmBusy = false;
  }
}

function onFrame(data: Buffer): void {
  if (data.length !== PACKED_FRAME_BYTES) return;
  const frame = unpackFrame(data);
  updatePhase(belief, frame);
  updateMinimap(belief, frame);
  updatePosition(belief, frame);
  updateHud(belief, frame);

  const event = checkTriggers(belief, lastPromptTick, false);
  if (event && !llmBusy) promptLLM(event);

  tasks = runTasks(tasks, bot, ws, events);
}

ws.on("open", () => console.log(`[${botName}] Connected to ${botUrl}`));
ws.on("message", (data: Buffer) => onFrame(data));
ws.on("close", () => { console.log(`[${botName}] Disconnected`); process.exit(0); });
ws.on("error", (err) => console.error(`[${botName}] Error:`, err.message));
process.on("SIGINT", () => { ws.close(); process.exit(0); });

console.log(`LLM Bot: ${botName} | model: ${modelId} | region: ${region} | server: ${botUrl}`);

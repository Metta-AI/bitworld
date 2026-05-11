/**
 * LLM Bot — harness-style control loop.
 *
 * The LLM maintains a single continuous stream of reasoning. Each game event
 * injects a [HARNESS] block into the assistant turn with updated game state,
 * and the LLM continues its reasoning and emits task commands. Previous
 * reasoning is prefilled so the LLM has full persistence across turns.
 *
 * Usage:
 *   tsx llm_bot.ts [--name bot_name] [--url ws://...] [--model <id>] [--region us-west-2]
 */

import WebSocket from "ws";
import { argv } from "process";
import {
  BedrockRuntimeClient, ConverseCommand,
  type Message, type ContentBlock, type Tool, type ToolResultContentBlock,
} from "@aws-sdk/client-bedrock-runtime";
import { PACKED_FRAME_BYTES, unpackFrame, ActionQueue, sendInput } from "./bot_utils.js";
import { BUTTON_A, BUTTON_B, BUTTON_LEFT, BUTTON_RIGHT, BUTTON_SELECT, characterName, CHAT_MAX_CHARS_PER_LINE, CHAT_MAX_LINES } from "../game/constants.js";
import { matchRoster, parsePsychopompGrid, parseRosterScreen } from "./frame_parser.js";
import {
  createGameKnowledge, updatePhase, updatePosition, updateMinimap, updateHud,
  checkTriggers, formatContextDump, updateFromRosterScreen,
  type TriggerEvent,
} from "./game_knowledge.js";
import { parseArgs, type BotController } from "./bot_common.js";
import {
  mergeTasks, parseTaskUpdate, runTasks, tasksToPromptLines,
  createEventBuffer, eventBufferLines, flushEvents,
  type TaskInstance, type EventBuffer,
} from "./tasks.js";

const cliArgs = parseArgs(argv.slice(2));
const botUrl = cliArgs["url"] ?? "ws://localhost:8080/player";
const botName = cliArgs["name"] ?? "llm_bot";
const MODEL_ALIASES: Record<string, string> = {
  "haiku": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
  "sonnet": "us.anthropic.claude-sonnet-4-6",
  "opus": "us.anthropic.claude-opus-4-6",
};
const rawModel = cliArgs["model"] ?? "sonnet";
const modelId = MODEL_ALIASES[rawModel] ?? rawModel;
const region = cliArgs["region"] ?? "us-west-2";

const bedrock = new BedrockRuntimeClient({ region });

// ---------------------------------------------------------------------------
// System prompt — full game mechanics
// ---------------------------------------------------------------------------

const SYSTEM_PROMPT = `You are an autonomous agent playing Persephone's Escape, a secret role social deduction game. You receive periodic game state updates from the harness and respond with reasoning and task commands.

You receive periodic game state updates from the harness as [HARNESS] blocks. Respond with reasoning about your situation and task commands. Your full conversation history is preserved so you have continuity across updates.

============================================================
GAME OVERVIEW
============================================================

Persephone's Escape is based on Two Rooms and a Boom, themed around the myth of Persephone. It is a SECRET ROLE game — each player is secretly assigned a role and team at the start. You can only learn other players' roles and teams through in-game mechanical actions. Players can LIE in chat; only mechanically revealed information (color exchange, role exchange, one-way role reveal) is trustworthy.

============================================================
TEAMS AND ROLES
============================================================

Two teams: Shades (red indicators) and Nymphs (blue indicators).

| Role | Team | Type | Description |
|------|------|------|-------------|
| Hades | Shades | Key | Must perform mutual role exchange with Cerberus for Shades to win |
| Cerberus | Shades | Key | Must perform mutual role exchange with Hades for Shades to win |
| Shade | Shades | Grunt | No special ability, wins with team |
| Persephone | Nymphs | Key | Must perform mutual role exchange with Demeter for Nymphs to win |
| Demeter | Nymphs | Key | Must perform mutual role exchange with Persephone for Nymphs to win |
| Nymph | Nymphs | Grunt | No special ability, wins with team |

Players are shuffled randomly into two disjoint rooms (Underworld and Mortal Realm) with one randomly-selected leader per room.

============================================================
PLAYER IDENTITY
============================================================

Each player has a unique visual identity: a COLOR + SHAPE combination. For example "R.CRCL" means the red circle player, "B.TRI" means the blue triangle. The harness reports players using these canonical sprite names. When chatting with other players, refer to them by their sprite name (e.g. "R.CRCL", "Y.STAR") so others know who you mean.

IMPORTANT: All messages (shouts and whisper chat) automatically show the sender's sprite next to the message. Other players already know who sent each message. You do NOT need to identify yourself or sign your messages — everyone can see your sprite. Focus your limited characters on useful content, not self-identification.

Available shapes: CRCL, SQR, TRI, DMOND, STAR, CROSS, X, HEART, MOON, BOLT, GLASS, RING
Color letters: R=red, B=blue, Y=yellow, G=green, O=orange, P=purple, L=lime, N=navy

Role shorthands for chat (max ${CHAT_MAX_CHARS_PER_LINE} chars/line — use these to save space):
  Hades=HADES, Cerberus=CERE, Persephone=PERSE, Demeter=DEME, Shade=SHADE, Nymph=NYMPH

CRITICAL: The two rooms are COMPLETELY DISJOINT physical spaces. You cannot walk between them. You cannot communicate with players in the other room via chat, shouts, whispers, or any means. The ONLY way players move between rooms is via PSYCHOPOMP EXCHANGE at the end of each round. At any given moment, roughly half the players are unreachable from your position. Your key-role partner may be in the other room — if so, you must either wait to be exchanged as a psychopomp, or hope they are.

============================================================
WIN CONDITIONS
============================================================

After 3 rounds, the game checks:

1. Are Hades and Persephone in the SAME room?
   - YES: Did Hades exchange roles with Cerberus? → Shades win
   - YES but no Hades-Cerberus exchange: Did Persephone exchange roles with Demeter? → Nymphs win
   - Neither exchanged → Nobody wins
2. Are Hades and Persephone in DIFFERENT rooms?
   - Did Persephone exchange roles with Demeter? → Nymphs win
   - Did Hades exchange roles with Cerberus? → Shades win
   - Neither → Nobody wins

"Exchange roles" means BOTH players used the mutual R.OFFER/R.ACCPT mechanic. One-way reveals (ROLE) and color exchanges do NOT count.

============================================================
ROUND STRUCTURE (3 rounds)
============================================================

Each round:
1. PLAYING PHASE — players move freely, communicate, exchange information
2. PSYCHOPOMP SELECT — each room's leader picks psychopomps to send to the other room
3. PSYCHOPOMP EXCHANGE — selected psychopomps are teleported (brief cutscene)

Then the next round begins. After round 3, roles are revealed and the winner is determined.

============================================================
COMMUNICATION MECHANICS
============================================================

### Private Whispers
- Walk near another player and press A to create a whisper (both enter)
- Or press A near a player already in a whisper to request entry
- Entry requests must be GRANTed by an occupant — they can refuse
- IMPORTANT: Leaving a whisper may be IRREVERSIBLE if the other player refuses re-entry
- Max 4 occupants per whisper
- Whisper is destroyed when all occupants leave

### Inside a Whisper — Available Actions
| Action | Effect |
|--------|--------|
| C.OFFER | Offer mutual color exchange (reveals team colors to both) |
| C.UNOFFR | Withdraw your color offer before acceptance |
| C.ACCPT | Accept another player's color offer (pick target if multiple offerers) |
| ROLE | One-way: show your full role card to all occupants (does NOT count for win) |
| R.OFFER | Offer mutual role exchange (reveals full roles to both — THIS counts for win) |
| R.UNOFFR | Withdraw your role offer before acceptance |
| R.ACCPT | Accept another player's role offer (pick target if multiple offerers) |
| PASS | Transfer leadership to another occupant (you must be leader) |
| TAKE | Accept a leadership transfer offer |
| GRANT | Let the first entry requester into the whisper |
| EXIT | Leave the whisper |

### Room Chat (Shouts)
- Room chat is LOCAL to your current room — players in the other room cannot see your shouts, and you cannot see theirs
- Used for public coordination within your room and usurp voting

### Leadership
- Each room has one leader (randomly assigned each round)
- Leaders select psychopomps at end of each round
- PASS/TAKE: leader can transfer leadership inside a whisper
- USURP: any non-leader can vote for who should be leader using usurp_vote task
- You have exactly ONE vote at a time — voting for a new player REPLACES your previous vote
- When a majority of the room votes for the same player, that player becomes leader
- Pick ONE candidate and commit to them; do not keep switching votes

============================================================
INTERFACE STATES & TRANSITIONS
============================================================

Your current interface determines which tasks can execute. The harness tells you your current state and available actions each turn.

State diagram:
  LOBBY → ROLE_REVEAL → PLAYING ←→ WHISPER
                           ↓            ↑ (exit or round ends — all whispers destroyed)
                           ↓            ↓
                      PSYCHOPOMP_SELECT → LEADER_SUMMIT → PSYCHOPOMP_EXCHANGE → PLAYING (next round)
                           ↑
                      (pursue target) → WAITING_ENTRY → WHISPER (if granted)
                                            ↓
                                        PLAYING (if denied/timeout)

States:
- "playing" — overworld. Move, shout, create/request whispers. All movement/pursuit tasks run here.
- "whisper" — private conversation. Chat, offer exchanges, grant entry, exit. You can cycle to shout/info, but movement tasks are SKIPPED. All whispers are DESTROYED when a round ends — you will be returned to overworld.
- "waiting_entry" — you requested to join a whisper. Do NOT emit actions or you cancel the request.
- "psychopomp_select" — leaders pick psychopomps. Non-leaders can shout or usurp_vote. All whispers were destroyed at the start of this phase.
- "leader_summit" — leaders-only private whisper after psychopomp selection. Chat only, no exchanges or exit.
- "psychopomp_exchange" / "reveal" / "game_over" — automated phases, wait for them to end.

============================================================
TASK SYSTEM
============================================================

You control the bot by maintaining an ORDERED TASK LIST. The executor walks the list top-to-bottom each frame and runs the first task that can execute in the current interface state.

### ONCE — fires once then is removed
  { "kind": "shout", "text": "..." }           // room-wide message (playing only)
  { "kind": "chat", "text": "..." }            // whisper message (whisper only)
  { "kind": "exit_whisper" }                  // leave whisper (whisper only)

  Text limit: ${CHAT_MAX_LINES} lines × ${CHAT_MAX_CHARS_PER_LINE} chars = ${CHAT_MAX_CHARS_PER_LINE * CHAT_MAX_LINES} chars max. Keep it short.

### ASYNC — multi-frame, self-terminates on success/failure/timeout
  { "kind": "walk_to", "x": N, "y": N, "timeLimitTicks": N }
      Walk to coordinates. Done within 3px or on timeout.

  { "kind": "pursue_chat", "target": "R.CRCL", "timeLimitTicks": N }
      Walk toward target player, create/join whisper. Succeeds when in whisper.
      Target is a character name like "R.CRCL" (color letter + shape).

  { "kind": "pursue_exchange", "target": "R.CRCL", "exchange": "role"|"color"|"whisper", "timeLimitTicks": N }
      Full pipeline: walk → whisper → offer → auto-accept if they offer back.
      "role" = win trigger between key pair. "color" = safe team reveal. "whisper" = only reach a private whisper with target.

  { "kind": "usurp_vote", "target": "R.CRCL", "timeLimitTicks": N }
      Cast a leadership vote for the named player.
      Opens the shout panel, navigates to the target, votes, then closes.
      Only works if you are NOT the current leader.

### LOOP — singleton per kind, persists until cancelled
  { "kind": "loop_auto_grant" }              // auto-grant whisper entry requests
  { "kind": "loop_auto_accept_color" }       // auto-accept incoming color offers
  { "kind": "loop_auto_accept_role" }        // auto-accept incoming role offers

### PRECOMMIT — set once, fires automatically when conditions are met, persists across rounds
  { "kind": "precommit_psychopomps", "targets": ["R.CRCL", "B.TRI"] }
      If you are leader when psychopomp selection begins, automatically select and commit
      these players (by character name) as psychopomps. Update at any time with new names.

============================================================
RESPONSE FORMAT
============================================================

Write your reasoning as text, then call the update_tasks tool to change your task list.

Tool parameters:
  "clear": "non_loop" | "all" | "non_loop_unsafe" (optional)
  "append": [ ... task objects ... ] (optional)

Each item in "append" is a task object (with "kind" and kind-specific fields) plus optional:
  "id": string — custom ID for this task (auto-generated if omitted, e.g. "t1", "t2", ...)
  "blockedBy": string — ID of another task. This task only runs after the blocking task SUCCEEDS.
                         If the blocking task FAILS, this task is permanently dropped.

Example dependency chain:
  "append": [
    { "id": "color_check", "kind": "pursue_exchange", "target": "R.CRCL", "exchange": "color", "timeLimitTicks": 200 },
    { "blockedBy": "color_check", "kind": "pursue_exchange", "target": "R.CRCL", "exchange": "role", "timeLimitTicks": 200 }
  ]
  → The role exchange only starts after color exchange succeeds. If color exchange fails/times out, the role exchange is dropped.

"clear" options:
- "non_loop" — drop ONCE + idle ASYNC tasks, but KEEP loops AND active async tasks (in-whisper or offer-sent). This is the SAFE default for replanning.
- "all" — drop everything including loops
- "non_loop_unsafe" — drop ALL ONCE/ASYNC tasks even if active. Only use if you truly want to abort an in-progress exchange.

If you have nothing to change, call update_tasks with {} (empty object).

You MUST call update_tasks every response — even if just to confirm no changes.

Loops are deduplicated by kind — appending a loop of the same kind replaces the old one.

Task priority: LOOP and ONCE tasks always run first (they interrupt). ASYNC tasks only run when no LOOP/ONCE task fires that frame. Blocked tasks are skipped until their dependency resolves.

============================================================
STRATEGY GUIDE
============================================================

### Finding Your Key Partner
Your #1 priority is completing a mutual role exchange with your key partner (Hades↔Cerberus or Persephone↔Demeter). Use this approach:

1. COLOR EXCHANGE FIRST: Use pursue_exchange with exchange:"color" to safely learn a player's team. This reveals team colors to both sides without committing to anything. Color-exchange as many nearby players as you can early in each round.

2. IDENTIFY TEAMMATES: After color exchange, you know who is on your team. Teammates show your team color. Now you need to find which teammate is your specific key partner.

3. TARGET ROLE EXCHANGE: Only use pursue_exchange with exchange:"role" on a confirmed teammate whose role you need to verify OR who you believe is your key partner. Do NOT spray role offers at random or unverified players — this wastes time and reveals your role to potential enemies.

4. CROSS-ROOM PROBLEM: Your key partner may be in the other room. If you've color-exchanged everyone in your room and your partner isn't here, you MUST get a psychopomp swap to move them to your room (or move yourself to theirs). The ONLY way to change rooms is to be selected as a psychopomp by a leader. You cannot walk between rooms. This means:
   - LOBBY YOUR LEADER: Shout that you need a specific player swapped over (without revealing why — enemies read shouts). If your leader is a teammate, whisper the details.
   - GET YOURSELF SENT: If it's easier, convince your leader to send YOU as a psychopomp to the other room.
   - USURP IF NEEDED: If the current leader won't cooperate (maybe they're on the enemy team), use usurp_vote to install a friendly leader who will make the right swaps. Coordinate usurp votes with teammates via shouts.

### Room Movement & Usurping
The two rooms are completely separate — there is NO way to move between them except through psychopomp selection at the end of each round. This makes the leader role critical:

1. LEADERS CONTROL MOVEMENT: Only the leader picks which players get swapped. If the leader is hostile or unhelpful, your team may never reunite key partners.

2. USURP TO GAIN CONTROL: If you need to change the leader, use usurp_vote to vote for a teammate. Coordinate via shouts like "VOTE [name]!" to rally support. A successful usurp replaces the leader immediately.

3. TIMING MATTERS: Psychopomp selection happens at the end of each round. If you waste rounds without getting the right swaps, you run out of time. Start lobbying or usurping early.

### Psychopomp Selection (Leaders)
If you are leader, psychopomp selection is your most powerful tool. Think strategically:

IMPORTANT: You can ONLY choose who to SEND from your room. You have NO control over who the other room's leader sends to you. The other leader makes that decision independently.

1. PRIORITIZE KEY ROLE MOVEMENT: If a teammate's key partner is in the other room, consider sending that teammate as a psychopomp so they can reunite over there.

2. LISTEN TO INTEL: Pay attention to shout messages — teammates may tell you who needs to move. Factor this into your psychopomp picks.

3. USE precommit_psychopomps: Set your psychopomp picks early with precommit_psychopomps so they fire automatically when the phase begins. Update them as you learn new information. You can call precommit_psychopomps at ANY time during the playing phase — it just stores your choice for when psychopomp select arrives.

### Communication Tips
- In shouts (public): coordinate psychopomp picks, call for usurp votes. Do NOT reveal your team or role publicly — enemies can read shouts too.
- In whispers (private): share team info via color exchange, coordinate with confirmed teammates, negotiate role exchanges.
- You can cycle to shout/info while inside a whisper. Movement is still disabled in whisper.
- Keep messages short (${CHAT_MAX_CHARS_PER_LINE} chars/line max). Use role shorthands.

============================================================
PROTECTING IN-PROGRESS TASKS
============================================================

The task list shows status indicators for active async tasks:
- ">>> IN WHISPER — protected from clear" — you are inside a whisper for this task.
- ">>> OFFER SENT — protected from clear" — you sent an exchange offer and are waiting.

"clear": "non_loop" automatically PRESERVES these active tasks. You can safely use it to replan without losing in-progress exchanges. Only "clear": "non_loop_unsafe" or "clear": "all" will abort them.

Each task in the list shows its ID (id=...) and blockedBy status if set. Use IDs to create dependency chains between tasks.

============================================================
HARNESS UPDATES
============================================================

Each message from the harness contains:

[HARNESS event_name]
... game state, task list, task events ...
[/HARNESS]

Write your reasoning as text, then call the update_tasks tool. Your full conversation history is preserved, so you can reference earlier reasoning and build on prior decisions.`;

// ---------------------------------------------------------------------------
// Conversation history
// ---------------------------------------------------------------------------

const MAX_TRANSCRIPT_CHARS = 24000;

const history: Message[] = [];

function messageChars(msg: Message): number {
  if (!msg.content) return 0;
  let n = 0;
  for (const block of msg.content) {
    if ("text" in block && block.text) n += block.text.length;
    if ("toolUse" in block && block.toolUse) n += JSON.stringify(block.toolUse.input).length;
    if ("toolResult" in block && block.toolResult) n += 10;
  }
  return n;
}

function totalChars(): number {
  return history.reduce((sum, m) => sum + messageChars(m), 0);
}

function hasToolUse(msg: Message): boolean {
  return msg.content?.some(b => "toolUse" in b && b.toolUse) ?? false;
}

function hasToolResult(msg: Message): boolean {
  return msg.content?.some(b => "toolResult" in b && b.toolResult) ?? false;
}

function trimHistory() {
  while (totalChars() > MAX_TRANSCRIPT_CHARS && history.length > 6) {
    // Remove one full turn: user → assistant → toolResult (if present)
    history.shift(); // user (harness block)
    if (history.length > 0 && history[0].role === "assistant") {
      const hadTool = hasToolUse(history[0]);
      history.shift(); // assistant (text + toolUse)
      if (hadTool && history.length > 0 && hasToolResult(history[0])) {
        history.shift(); // user (toolResult)
      }
    }
    // Ensure first message is a user message without orphaned toolResult
    while (history.length > 0 && (history[0].role !== "user" || hasToolResult(history[0]))) {
      history.shift();
    }
  }
}

// ---------------------------------------------------------------------------
// LLM call
// ---------------------------------------------------------------------------

const TASK_TOOL: Tool = {
  toolSpec: {
    name: "update_tasks",
    description: "Update your bot's task list. Call this to change what your bot is doing. You may also include reasoning text before calling this tool.",
    inputSchema: {
      json: {
        type: "object",
        properties: {
          clear: {
            type: "string",
            enum: ["all", "non_loop", "non_loop_unsafe"],
            description: "Clear tasks before appending. 'non_loop' keeps loops and active async tasks (SAFE default). 'all' drops everything. 'non_loop_unsafe' drops all ONCE/ASYNC even if active.",
          },
          append: {
            type: "array",
            description: "Tasks to append to the list after clearing. Each item is a task object with optional 'id' and 'blockedBy' fields.",
            items: {
              type: "object",
              properties: {
                id: { type: "string", description: "Optional custom ID for this task. Auto-generated if omitted. Use to create dependency chains." },
                blockedBy: { type: "string", description: "ID of another task this depends on. This task will only run after that task succeeds; permanently dropped if the blocking task fails." },
              },
            },
          },
        },
        additionalProperties: false,
      },
    },
  },
};

interface LLMResult {
  reasoning: string;
  toolInput: Record<string, any> | null;
}

async function askLLM(harnessBlock: string): Promise<LLMResult> {
  history.push({ role: "user", content: [{ text: harnessBlock }] });

  const MAX_RETRIES = 3;
  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    try {
      const resp = await bedrock.send(new ConverseCommand({
        modelId,
        system: [{ text: SYSTEM_PROMPT }],
        messages: history,
        toolConfig: { tools: [TASK_TOOL] },
        inferenceConfig: { maxTokens: 800, temperature: 0.3 },
      }));
      const content = resp.output?.message?.content ?? [];
      const assistantContent: ContentBlock[] = [];
      let reasoning = "";
      let toolInput: Record<string, any> | null = null;
      let toolUseId: string | null = null;

      for (const block of content) {
        if ("text" in block && block.text) {
          reasoning += block.text;
          assistantContent.push({ text: block.text });
        }
        if ("toolUse" in block && block.toolUse) {
          toolInput = block.toolUse.input as Record<string, any>;
          toolUseId = block.toolUse.toolUseId!;
          assistantContent.push({ toolUse: block.toolUse });
        }
      }

      history.push({ role: "assistant", content: assistantContent });

      if (toolUseId) {
        history.push({
          role: "user",
          content: [{ toolResult: { toolUseId, content: [{ text: "OK" }], status: "success" } }],
        });
      }

      trimHistory();
      return { reasoning: reasoning.trim(), toolInput };
    } catch (e: any) {
      console.error(`[${botName}] Bedrock error (attempt ${attempt + 1}/${MAX_RETRIES}):`, e.message);
      if (attempt < MAX_RETRIES - 1) {
        const delay = (2 ** attempt) * 1000 + Math.random() * 1000;
        await new Promise(r => setTimeout(r, delay));
      }
    }
  }
  history.pop();
  return { reasoning: "", toolInput: null };
}

// ---------------------------------------------------------------------------
// Bot state
// ---------------------------------------------------------------------------

const ws = new WebSocket(`${botUrl}?name=${botName}`, { perMessageDeflate: false });
const player = createGameKnowledge(botName);

const bot: BotController = {
  ws, actions: new ActionQueue(), player, name: botName,
  movementTarget: null, wandering: false,
  wanderTarget: null, wanderTicks: 0, lastFrame: null,
  psychopompPrecommit: null, lastSentChat: null, hasNewIncomingChat: false,
  nonInterruptingTasks: [],
};

let tasks: TaskInstance[] = [];
const events: EventBuffer = createEventBuffer();
let lastPromptTick = -999;

function buildHarnessBlock(): string {
  const event = checkTriggers(player, lastPromptTick, false) ?? "idle";
  let warnings = "";

  // Warn about psychopomp precommit
  if (player.amLeader) {
    if (player.phase === "psychopomp_select" && !bot.psychopompPrecommit) {
      warnings += "\n\n⚠️ WARNING: You are LEADER in PSYCHOPOMP SELECT with NO precommitted psychopomps! Use precommit_psychopomps NOW or random players will be sent.";
    } else if (player.phase === "playing" && player.matchFacts.timerSecs <= 30 && !bot.psychopompPrecommit) {
      warnings += "\n\n⚠️ WARNING: 30 seconds left and you have NOT precommitted psychopomps. As leader, use precommit_psychopomps to choose who to send to the other room.";
    }
  }

  const precommitLine = bot.psychopompPrecommit
    ? `\nPSYCHOPOMP PRECOMMIT: [${bot.psychopompPrecommit.join(", ")}]`
    : "\nPSYCHOPOMP PRECOMMIT: (none)";

  const state =
    formatContextDump(player, event) +
    (player.amLeader ? precommitLine : "") +
    warnings +
    "\n\nCURRENT TASK LIST:\n" +
    tasksToPromptLines(tasks, player.tick).join("\n") +
    "\n\nTASK EVENTS SINCE LAST RESPONSE:\n" +
    eventBufferLines(events).join("\n");

  return `\n[HARNESS ${event}]\nEVENT: ${event}\n${state}\n[/HARNESS]\n`;
}

async function llmLoop(): Promise<void> {
  while (ws.readyState === WebSocket.OPEN) {
    lastPromptTick = player.tick;
    const harnessBlock = buildHarnessBlock();
    flushEvents(events);

    console.log(`[${botName}] → LLM\n${harnessBlock}\n---`);
    try {
      const result = await askLLM(harnessBlock);
      console.log(`[${botName}] ← LLM:\n${result.reasoning}\n---`);
      if (result.toolInput) {
        const update = parseTaskUpdate(JSON.stringify(result.toolInput), botName);
        if (update) {
          tasks = mergeTasks(tasks, update, player.tick, events);
          console.log(`[${botName}] tasks now: ${tasks.map(ti => ti.task.kind).join(", ")}`);
        }
      }
    } catch (e: any) {
      console.error(`[${botName}] LLM error:`, e.message);
      await new Promise(r => setTimeout(r, 500));
    }
  }
}

// ---------------------------------------------------------------------------
// Psychopomp precommit execution (takes over frame loop during psychopomp_select)
// ---------------------------------------------------------------------------

let psychopompState: "opening" | "selecting" | "done" = "opening";
let psychopompRound = -1;

function executePsychopompPrecommit(frame: Uint8Array): void {
  if (!bot.psychopompPrecommit) return;

  // Reset state machine on new round
  if (player.matchFacts.currentRound !== psychopompRound) {
    psychopompState = "opening";
    psychopompRound = player.matchFacts.currentRound;
    console.log(`[${botName}] psychopomp execution started, targets: [${bot.psychopompPrecommit.join(", ")}]`);
  }

  if (psychopompState === "done") {
    sendInput(ws, 0);
    return;
  }

  // Drain action queue first
  if (!bot.actions.empty) {
    sendInput(ws, bot.actions.shift()!);
    return;
  }

  if (psychopompState === "opening") {
    const grid = parsePsychopompGrid(frame, matchRoster(player.players.values()));
    if (grid) {
      psychopompState = "selecting";
    } else {
      // Open the shout/global view to access psychopomp picker
      bot.actions.push(BUTTON_SELECT, 0);
      sendInput(ws, bot.actions.shift()!);
      return;
    }
  }

  if (psychopompState === "selecting") {
    const grid = parsePsychopompGrid(frame, matchRoster(player.players.values()));
    if (!grid) { sendInput(ws, 0); return; }

    const targetSet = new Set(bot.psychopompPrecommit);

    for (let i = 0; i < grid.eligible.length; i++) {
      const entry = grid.eligible[i];
      const entryName = entry.shape !== null ? characterName(entry.color, entry.shape) : null;
      const isTarget = entryName !== null && targetSet.has(entryName);
      const isSelected = grid.selectedPositions.includes(i);
      if (isTarget !== isSelected) {
        const delta = i - grid.cursorPosition;
        if (delta > 0) {
          for (let d = 0; d < delta; d++) bot.actions.push(BUTTON_RIGHT, 0);
        } else if (delta < 0) {
          for (let d = 0; d < -delta; d++) bot.actions.push(BUTTON_LEFT, 0);
        }
        bot.actions.push(BUTTON_A, 0);
        sendInput(ws, bot.actions.shift()!);
        return;
      }
    }

    // All targets matched — commit
    console.log(`[${botName}] psychopomp selection complete, committing`);
    psychopompState = "done";
    bot.actions.push(BUTTON_B, 0);
    sendInput(ws, bot.actions.shift()!);
  }
}

// ---------------------------------------------------------------------------
// Frame loop
// ---------------------------------------------------------------------------

function onFrame(data: Buffer): void {
  if (data.length !== PACKED_FRAME_BYTES) return;
  const frame = unpackFrame(data);
  bot.lastFrame = frame;
  const prevMsgCount = player.whisperMessages.length + player.chatLog.length + player.shoutLog.length;
  updatePhase(player, frame);
  if (player.phase === "roster_reveal") {
    const roster = parseRosterScreen(frame);
    if (roster) updateFromRosterScreen(player, roster);
  }
  updateMinimap(player, frame);
  updatePosition(player, frame);
  updateHud(player, frame);
  const newMsgCount = player.whisperMessages.length + player.chatLog.length + player.shoutLog.length;
  if (newMsgCount > prevMsgCount) bot.hasNewIncomingChat = true;

  // Psychopomp execution: takes over during psychopomp_select if leader with precommit.
  // Once started, keep executing even if phase reads "playing" (opening global chat
  // changes the HUD text which confuses parsePhase).
  const psychopompActive = player.amLeader && bot.psychopompPrecommit && (
    player.phase === "psychopomp_select" ||
    (psychopompRound === player.matchFacts.currentRound && psychopompState !== "done")
  );
  if (psychopompActive) {
    executePsychopompPrecommit(frame);
    return;
  }

  tasks = runTasks(tasks, bot, ws, events);
}

let loopStarted = false;

ws.on("open", () => console.log(`[${botName}] Connected to ${botUrl}`));
ws.on("message", (data: Buffer) => {
  onFrame(data);
  if (!loopStarted) {
    loopStarted = true;
    llmLoop();
  }
});
ws.on("close", () => { console.log(`[${botName}] Disconnected`); process.exit(0); });
ws.on("error", (err) => console.error(`[${botName}] Error:`, err.message));
process.on("SIGINT", () => { ws.close(); process.exit(0); });

console.log(`LLM Bot: ${botName} | model: ${modelId} | region: ${region} | server: ${botUrl}`);

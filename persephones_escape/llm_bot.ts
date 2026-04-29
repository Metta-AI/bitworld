/**
 * LLM Bot for Persephone's Escape — uses AWS Bedrock (Claude) directly.
 *
 * Usage:
 *   tsx llm_bot.ts [--name bot_name] [--url ws://localhost:8080/player]
 *                  [--model us.anthropic.claude-sonnet-4-6-v1] [--region us-west-2]
 *
 * Requires AWS credentials configured (env vars, ~/.aws/credentials, or IAM role).
 */

import WebSocket from "ws";
import { argv } from "process";
import {
  BedrockRuntimeClient,
  ConverseCommand,
  type Message,
} from "@aws-sdk/client-bedrock-runtime";
import {
  ROOM_W, ROOM_H, TARGET_FPS,
  BUTTON_A, BUTTON_B, BUTTON_LEFT, BUTTON_RIGHT, BUTTON_SELECT,
} from "./constants.js";
import { Room } from "./types.js";
import {
  sendInput, sendChat, PACKED_FRAME_BYTES, unpackFrame,
  ActionQueue, menuActionSequence, hostageSelectSequence,
  moveToward, randomDir, randomPoint, readPosition,
  type Point, type MenuAction,
} from "./bot_utils.js";
import {
  createBeliefState, updateFromFrame, updateFromCommand,
  checkTriggers, formatContextDump,
  type BeliefState, type TriggerEvent,
} from "./belief_state.js";

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------

const cliArgs = parseArgs(argv.slice(2));
const botUrl = cliArgs["url"] ?? "ws://localhost:8080/player";
const botName = cliArgs["name"] ?? "llm_bot";
const modelId = cliArgs["model"] ?? "us.anthropic.claude-haiku-4-5-20251001-v1:0";
const region = cliArgs["region"] ?? "us-west-2";

function parseArgs(raw: string[]): Record<string, string> {
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
// Bedrock client
// ---------------------------------------------------------------------------

const bedrock = new BedrockRuntimeClient({ region });

const SYSTEM_PROMPT = `You are playing Persephone's Escape, a social deduction game. You control a character in a 2D room.

GAME RULES:
- Two teams: Shades (red) and Nymphs (blue).
- Key roles: Hades & Cerberus (Shades), Persephone & Demeter (Nymphs), plus generic Shades/Nymphs.
- Shades win if Hades mutually shares cards with Cerberus (both must reveal to each other).
- Nymphs win if Persephone mutually shares cards with Demeter (both must reveal to each other).
- 3 rounds of 15 seconds. Between rounds, leaders select hostages to swap between rooms.
- Room positioning matters for the final win check.

HOW TO INTERACT:
- Walk near another player, then use "open_chatroom" to start a private chat.
- Inside a chatroom you can: "offer_share" (offer to exchange cards), "accept_share" (accept an offer — both cards revealed), "show_color" (show team color only), "show_role" (one-way reveal your role), "chat <msg>" (talk), "exit_chatroom" (leave).
- Card exchange requires BOTH players to consent — one offers, the other accepts. Only this mutual exchange counts for the win condition.
- Use "approach_nearest" to walk toward the closest player you can see.

STRATEGY:
- Find your key partner (Hades↔Cerberus, Persephone↔Demeter) by showing your color to find teammates.
- Once you find a likely ally, open a chatroom and do a mutual reveal.
- As a generic role (Shades/Nymphs), help your key roles find each other.
- Don't reveal your full card to enemies — show color first to verify team.
- If you're leader during hostage select, choose strategically.

RESPOND WITH EXACTLY ONE COMMAND. No explanation, no extra text. Just the command.`;

const conversationHistory: Message[] = [];

async function askLLM(context: string): Promise<string> {
  conversationHistory.push({
    role: "user",
    content: [{ text: context }],
  });

  // Keep conversation manageable
  if (conversationHistory.length > 20) {
    conversationHistory.splice(0, conversationHistory.length - 10);
  }

  try {
    const resp = await bedrock.send(new ConverseCommand({
      modelId,
      system: [{ text: SYSTEM_PROMPT }],
      messages: conversationHistory,
      inferenceConfig: {
        maxTokens: 50,
        temperature: 0.7,
      },
    }));

    const text = resp.output?.message?.content?.[0]?.text ?? "wander";
    conversationHistory.push({
      role: "assistant",
      content: [{ text }],
    });
    return text.trim();
  } catch (e: any) {
    console.error(`[${botName}] Bedrock error:`, e.message);
    return "wander";
  }
}

// ---------------------------------------------------------------------------
// Chatroom action sequences
// ---------------------------------------------------------------------------

const CHATROOM_ACTIONS = ["COLOR", "ROLE", "OFFER", "UNOFFER", "ACCEPT", "PASS", "TAKE", "GRANT", "EXIT"];

function chatroomActionSequence(action: string): number[] {
  const idx = CHATROOM_ACTIONS.indexOf(action.toUpperCase());
  if (idx < 0) return [];
  const seq: number[] = [];
  for (let i = 0; i < CHATROOM_ACTIONS.length; i++) seq.push(BUTTON_LEFT, 0);
  for (let i = 0; i < idx; i++) seq.push(BUTTON_RIGHT, 0);
  seq.push(BUTTON_A, 0);
  return seq;
}

const MENU_COMMANDS: Record<string, MenuAction> = {
  info_shared: "INFO:SHARED",
  usurp: "USURP:SELECT",
  start_chat: "COMM:START",
  shout: "COMM:SHOUT",
};

const CHATROOM_CMDS: Record<string, string> = {
  show_color: "COLOR",
  show_role: "ROLE",
  offer_share: "OFFER",
  withdraw_offer: "UNOFFER",
  accept_share: "ACCEPT",
  leader_pass: "PASS",
  leader_take: "TAKE",
  grant_entry: "GRANT",
  exit_chatroom: "EXIT",
};

// ---------------------------------------------------------------------------
// Bot state
// ---------------------------------------------------------------------------

const ws = new WebSocket(`${botUrl}?name=${botName}`, { perMessageDeflate: false });
const actions = new ActionQueue();
const belief = createBeliefState(botName);

let movementTarget: Point | null = null;
let wandering = true;
let wanderTarget: Point | null = null;
let wanderTicks = 0;
let llmBusy = false;
let lastPromptTick = -999;

// ---------------------------------------------------------------------------
// Command parsing & execution
// ---------------------------------------------------------------------------

interface ParsedCommand { type: string; args: string[]; }

function parseCommand(line: string): ParsedCommand | null {
  const trimmed = line.trim().split("\n")[0].trim();
  if (!trimmed) return null;
  if (trimmed.toLowerCase().startsWith("chat ")) {
    return { type: "chat", args: [trimmed.slice(5)] };
  }
  const parts = trimmed.split(/\s+/);
  return { type: parts[0].toLowerCase(), args: parts.slice(1) };
}

function executeCommand(cmd: ParsedCommand): void {
  updateFromCommand(belief, cmd.type + (cmd.args.length ? " " + cmd.args.join(" ") : ""));

  const menuAction = MENU_COMMANDS[cmd.type];
  if (menuAction) {
    const nearbyCount = belief.minimapDots.filter(d => !d.isSelf).length;
    actions.push(...menuActionSequence(menuAction, {
      usurpListLength: Math.max(3, nearbyCount + 2),
    }));
    movementTarget = null;
    wandering = false;
    return;
  }

  const crAction = CHATROOM_CMDS[cmd.type];
  if (crAction) {
    actions.push(...chatroomActionSequence(crAction));
    movementTarget = null;
    wandering = false;
    return;
  }

  switch (cmd.type) {
    case "move_to": {
      const x = parseInt(cmd.args[0]);
      const y = parseInt(cmd.args[1]);
      if (!isNaN(x) && !isNaN(y)) {
        movementTarget = { x: clamp(x, 0, ROOM_W - 1), y: clamp(y, 0, ROOM_H - 1) };
        wandering = false;
      }
      break;
    }
    case "approach_nearest": {
      const others = belief.minimapDots.filter(d => !d.isSelf);
      if (others.length > 0 && belief.myPos) {
        let best = others[0], bestDist = Infinity;
        for (const d of others) {
          const dist = (d.worldX - belief.myPos.x) ** 2 + (d.worldY - belief.myPos.y) ** 2;
          if (dist < bestDist) { bestDist = dist; best = d; }
        }
        movementTarget = { x: best.worldX, y: best.worldY };
        wandering = false;
      } else {
        wandering = true;
      }
      break;
    }
    case "open_chatroom":
      actions.push(BUTTON_A, 0);
      break;
    case "chat": {
      const text = cmd.args.join(" ").slice(0, 48);
      if (text) sendChat(ws, text);
      break;
    }
    case "select_hostages": {
      const indices = cmd.args.map(s => parseInt(s)).filter(n => !isNaN(n));
      if (indices.length > 0) {
        const eligible = Array.from({ length: 16 }, (_, i) => i);
        actions.push(...hostageSelectSequence(indices, eligible));
      }
      break;
    }
    case "commit_hostages":
      actions.push(BUTTON_SELECT, 0);
      break;
    case "wait":
      movementTarget = null;
      wandering = false;
      break;
    case "wander":
      wandering = true;
      movementTarget = null;
      break;
    default:
      console.log(`[${botName}] Unknown command: ${cmd.type}`);
      break;
  }
}

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

// ---------------------------------------------------------------------------
// LLM prompting
// ---------------------------------------------------------------------------

async function promptLLM(event: TriggerEvent): Promise<void> {
  if (llmBusy) return;
  llmBusy = true;
  lastPromptTick = belief.tick;

  const context = formatContextDump(belief, event);
  console.log(`[${botName}] → LLM (${event})`);

  try {
    const raw = await askLLM(context);
    console.log(`[${botName}] ← LLM: ${raw}`);
    const cmd = parseCommand(raw);
    if (cmd) executeCommand(cmd);
  } catch (e: any) {
    console.error(`[${botName}] LLM error:`, e.message);
    wandering = true;
  } finally {
    llmBusy = false;
  }
}

// ---------------------------------------------------------------------------
// Frame loop
// ---------------------------------------------------------------------------

function onFrame(data: Buffer): void {
  if (data.length !== PACKED_FRAME_BYTES) return;
  const frame = unpackFrame(data);
  updateFromFrame(belief, frame);

  if (!actions.empty) {
    sendInput(ws, actions.shift()!);
    return;
  }

  if (movementTarget && belief.myPos) {
    const dx = movementTarget.x - belief.myPos.x;
    const dy = movementTarget.y - belief.myPos.y;
    if (dx * dx + dy * dy > 9) {
      const mask = moveToward(belief.myPos.x, belief.myPos.y, movementTarget.x, movementTarget.y);
      if (mask) { sendInput(ws, mask); return; }
    }
    movementTarget = null;
  }

  const event = checkTriggers(belief, lastPromptTick, wandering || movementTarget !== null);
  if (event && !llmBusy) {
    promptLLM(event);
  }

  if (wandering || (!movementTarget && actions.empty)) {
    if (!wanderTarget || wanderTicks <= 0) {
      wanderTarget = randomPoint(belief.myRoom ?? Room.RoomA);
      wanderTicks = 15 + Math.floor(Math.random() * 40);
    }
    wanderTicks--;
    if (belief.myPos) {
      const mask = moveToward(belief.myPos.x, belief.myPos.y, wanderTarget.x, wanderTarget.y);
      sendInput(ws, mask || randomDir());
    } else {
      sendInput(ws, randomDir());
    }
  }
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

ws.on("open", () => console.log(`[${botName}] Connected to ${botUrl}`));
ws.on("message", (data: Buffer) => onFrame(data));
ws.on("close", () => { console.log(`[${botName}] Disconnected`); process.exit(0); });
ws.on("error", (err) => console.error(`[${botName}] Error:`, err.message));
process.on("SIGINT", () => { ws.close(); process.exit(0); });

console.log(`LLM Bot: ${botName} | model: ${modelId} | region: ${region} | server: ${botUrl}`);

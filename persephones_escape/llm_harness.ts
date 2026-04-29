import WebSocket from "ws";
import { argv } from "process";
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

const args = parseArgs(argv.slice(2));
const botUrl = args["url"] ?? "ws://localhost:8080/player";
const name = args["name"] ?? "llm_bot";
const llmUrl = args["llm-url"] ?? "http://localhost:5000/decide";
const llmTimeout = parseInt(args["llm-timeout"] ?? "3000");

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
// Command definitions
// ---------------------------------------------------------------------------

interface ParsedCommand {
  type: string;
  args: string[];
}

function parseCommand(line: string): ParsedCommand | null {
  const trimmed = line.trim().split("\n")[0].trim();
  if (!trimmed) return null;
  if (trimmed.toLowerCase().startsWith("chat ")) {
    return { type: "chat", args: [trimmed.slice(5)] };
  }
  const parts = trimmed.split(/\s+/);
  return { type: parts[0].toLowerCase(), args: parts.slice(1) };
}

const CHATROOM_ACTIONS = ["COLOR", "ROLE", "OFFER", "UNOFFER", "ACCEPT", "PASS", "TAKE", "GRANT", "EXIT"];

function chatroomActionSequence(action: string): number[] {
  const idx = CHATROOM_ACTIONS.indexOf(action.toUpperCase());
  if (idx < 0) return [];
  const seq: number[] = [];
  // Navigate: press right from position 0 to reach the action.
  // Since we don't know current position, press left many times to reset to 0.
  for (let i = 0; i < CHATROOM_ACTIONS.length; i++) {
    seq.push(BUTTON_LEFT, 0);
  }
  for (let i = 0; i < idx; i++) {
    seq.push(BUTTON_RIGHT, 0);
  }
  seq.push(BUTTON_A, 0);
  return seq;
}

// Menu commands (only INFO and USURP remain in the menu system)
const MENU_COMMANDS: Record<string, MenuAction> = {
  info_shared: "INFO:SHARED",
  usurp: "USURP:SELECT",
  start_chat: "COMM:START",
  shout: "COMM:SHOUT",
};

// ---------------------------------------------------------------------------
// Bot state
// ---------------------------------------------------------------------------

const ws = new WebSocket(`${botUrl}?name=${name}`, { perMessageDeflate: false });
const actions = new ActionQueue();
const belief = createBeliefState(name);

let movementTarget: Point | null = null;
let wandering = false;
let wanderTarget: Point | null = null;
let wanderTicks = 0;
let llmBusy = false;
let lastPromptTick = -999;

// ---------------------------------------------------------------------------
// LLM HTTP transport
// ---------------------------------------------------------------------------

async function promptLLM(event: TriggerEvent): Promise<void> {
  if (llmBusy) return;
  llmBusy = true;
  lastPromptTick = belief.tick;

  const context = formatContextDump(belief, event);
  console.log(`[${name}] Prompting LLM: ${event}`);

  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), llmTimeout);

    const resp = await fetch(llmUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ event, context }),
      signal: controller.signal,
    });
    clearTimeout(timeout);

    if (!resp.ok) {
      console.error(`[${name}] LLM returned ${resp.status}`);
      llmBusy = false;
      return;
    }

    const body = await resp.json() as { command?: string };
    const raw = body.command ?? "";
    console.log(`[${name}] LLM response: ${raw}`);

    const cmd = parseCommand(raw);
    if (cmd) executeCommand(cmd);
  } catch (e: any) {
    if (e.name === "AbortError") {
      console.log(`[${name}] LLM timeout, falling back to wander`);
    } else {
      console.error(`[${name}] LLM error:`, e.message);
    }
    wandering = true;
  } finally {
    llmBusy = false;
  }
}

// ---------------------------------------------------------------------------
// Command execution
// ---------------------------------------------------------------------------

function executeCommand(cmd: ParsedCommand): void {
  updateFromCommand(belief, cmd.type + (cmd.args.length ? " " + cmd.args.join(" ") : ""));

  // Menu actions (INFO, USURP)
  const menuAction = MENU_COMMANDS[cmd.type];
  if (menuAction) {
    const nearbyCount = belief.minimapDots.filter(d => !d.isSelf).length;
    const seq = menuActionSequence(menuAction, {
      usurpListLength: Math.max(3, nearbyCount + 2),
    });
    actions.push(...seq);
    movementTarget = null;
    wandering = false;
    return;
  }

  // Chatroom actions (require being in a chatroom)
  const chatroomCmds: Record<string, string> = {
    reveal: "REVEAL",
    show_color: "COLOR",
    accept_reveal: "ACCEPT",
    leader_pass: "PASS",
    leader_take: "TAKE",
    grant_entry: "GRANT",
    exit_chatroom: "EXIT",
  };
  const crAction = chatroomCmds[cmd.type];
  if (crAction) {
    const seq = chatroomActionSequence(crAction);
    actions.push(...seq);
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
        let best = others[0];
        let bestDist = Infinity;
        for (const d of others) {
          const dx = d.worldX - belief.myPos.x;
          const dy = d.worldY - belief.myPos.y;
          const dist = dx * dx + dy * dy;
          if (dist < bestDist) { bestDist = dist; best = d; }
        }
        movementTarget = { x: best.worldX, y: best.worldY };
        wandering = false;
      } else {
        wandering = true;
      }
      break;
    }

    case "open_chatroom": {
      // Press A to create/join chatroom
      actions.push(BUTTON_A, 0);
      break;
    }

    case "chat": {
      const text = cmd.args.join(" ").slice(0, 48);
      if (text) sendChat(ws, text);
      break;
    }

    case "select_hostages": {
      const indices = cmd.args.map(s => parseInt(s)).filter(n => !isNaN(n));
      if (indices.length > 0) {
        const eligible = Array.from({ length: 16 }, (_, i) => i);
        const seq = hostageSelectSequence(indices, eligible);
        actions.push(...seq);
      }
      break;
    }

    case "commit_hostages": {
      actions.push(BUTTON_SELECT, 0);
      break;
    }

    case "wait":
      movementTarget = null;
      wandering = false;
      break;

    case "wander":
      wandering = true;
      movementTarget = null;
      break;

    default:
      console.log(`[${name}] Unknown command: ${cmd.type}`);
      break;
  }
}

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

// ---------------------------------------------------------------------------
// Frame loop
// ---------------------------------------------------------------------------

function onFrame(data: Buffer): void {
  if (data.length !== PACKED_FRAME_BYTES) return;
  const frame = unpackFrame(data);

  updateFromFrame(belief, frame);

  // 1. Drain action queue
  if (!actions.empty) {
    sendInput(ws, actions.shift()!);
    return;
  }

  // 2. Active movement toward a target
  if (movementTarget && belief.myPos) {
    const dx = movementTarget.x - belief.myPos.x;
    const dy = movementTarget.y - belief.myPos.y;
    if (dx * dx + dy * dy > 9) {
      const mask = moveToward(belief.myPos.x, belief.myPos.y, movementTarget.x, movementTarget.y);
      if (mask) {
        sendInput(ws, mask);
        return;
      }
    }
    movementTarget = null;
  }

  // 3. Check for LLM trigger events
  const event = checkTriggers(belief, lastPromptTick, wandering || movementTarget !== null);
  if (event && !llmBusy) {
    promptLLM(event);
  }

  // 4. Default behavior: wander
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
// WebSocket connection
// ---------------------------------------------------------------------------

ws.on("open", () => console.log(`[${name}] Connected to ${botUrl}`));
ws.on("message", (data: Buffer) => onFrame(data));
ws.on("close", () => { console.log(`[${name}] Disconnected`); process.exit(0); });
ws.on("error", (err) => console.error(`[${name}] Error:`, err.message));

process.on("SIGINT", () => { ws.close(); process.exit(0); });

console.log(`LLM Harness: ${name} → ${botUrl}, LLM endpoint: ${llmUrl}`);

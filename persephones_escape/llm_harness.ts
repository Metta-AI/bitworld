import WebSocket from "ws";
import { argv } from "process";
import {
  BUTTON_B,
} from "./constants.js";
import {
  sendInput, PACKED_FRAME_BYTES, unpackFrame,
  ActionQueue,
} from "./bot_utils.js";
import {
  createBeliefState, updatePhase, updatePosition, updateMinimap, updateHud,
  updateFromInfoScreen,
  checkTriggers, formatContextDump,
  type TriggerEvent,
} from "./belief_state.js";
import { parseInfoScreen } from "./frame_parser.js";
import {
  parseArgs, parseCommand, executeBaseCommand,
  tickMovement, tickWander,
  type BotController,
} from "./bot_common.js";

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------

const args = parseArgs(argv.slice(2));
const botUrl = args["url"] ?? "ws://localhost:8080/player";
const name = args["name"] ?? "llm_bot";
const llmUrl = args["llm-url"] ?? "http://localhost:5000/decide";
const llmTimeout = parseInt(args["llm-timeout"] ?? "3000");

// ---------------------------------------------------------------------------
// Bot state
// ---------------------------------------------------------------------------

const ws = new WebSocket(`${botUrl}?name=${name}`, { perMessageDeflate: false });
const belief = createBeliefState(name);

const bot: BotController = {
  ws, actions: new ActionQueue(), belief, name,
  movementTarget: null, wandering: false,
  wanderTarget: null, wanderTicks: 0,
};

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

    const cmd = parseCommand(raw, name);
    if (cmd) executeCommand(cmd);
  } catch (e: any) {
    if (e.name === "AbortError") {
      console.log(`[${name}] LLM timeout, falling back to wander`);
    } else {
      console.error(`[${name}] LLM error:`, e.message);
    }
    bot.wandering = true;
  } finally {
    llmBusy = false;
  }
}

// ---------------------------------------------------------------------------
// Command execution
// ---------------------------------------------------------------------------

function executeCommand(cmd: ReturnType<typeof parseCommand>): void {
  if (!cmd) return;
  if (executeBaseCommand(cmd, bot)) return;

  switch (cmd.type) {
    case "approach_nearest": {
      const withPos = [...belief.players.values()].filter(b => b.lastPos !== null);
      if (withPos.length > 0 && belief.myPos) {
        let best = withPos[0];
        let bestDist = Infinity;
        for (const b of withPos) {
          const dx = b.lastPos!.x - belief.myPos.x;
          const dy = b.lastPos!.y - belief.myPos.y;
          const dist = dx * dx + dy * dy;
          if (dist < bestDist) { bestDist = dist; best = b; }
        }
        bot.movementTarget = { x: best.lastPos!.x, y: best.lastPos!.y };
        bot.wandering = false;
      } else {
        bot.wandering = true;
      }
      break;
    }
    default:
      console.log(`[${name}] Unknown command: ${cmd.type}`);
      break;
  }
}

// ---------------------------------------------------------------------------
// Info screen polling
// ---------------------------------------------------------------------------

let inChatroom = false;
let infoPollState: "closed" | "opening" | "reading" | "closing" = "closed";
let infoPollWaitFrames = 0;
let infoPollCooldown = 0;
const INFO_POLL_INTERVAL = 72;
const INFO_SETTLE_FRAMES = 3;

// ---------------------------------------------------------------------------
// Frame loop
// ---------------------------------------------------------------------------

function onFrame(data: Buffer): void {
  if (data.length !== PACKED_FRAME_BYTES) return;
  const frame = unpackFrame(data);

  updatePhase(belief, frame);

  if (!bot.actions.empty) {
    sendInput(ws, bot.actions.shift()!);
    if (infoPollState === "opening" || infoPollState === "closing") {
      infoPollWaitFrames--;
      if (infoPollWaitFrames <= 0) {
        infoPollState = infoPollState === "opening" ? "reading" : "closed";
        if (infoPollState === "closed") infoPollCooldown = INFO_POLL_INTERVAL;
      }
    }
    return;
  }

  if (infoPollState === "opening") {
    infoPollWaitFrames--;
    if (infoPollWaitFrames <= 0) infoPollState = "reading";
  }

  if (infoPollState === "reading") {
    const entries = parseInfoScreen(frame);
    if (entries) {
      const newInfo = updateFromInfoScreen(belief, entries);
      if (newInfo && !llmBusy) promptLLM("info_updated");
    }
    bot.actions.push(BUTTON_B, 0);
    infoPollState = "closing";
    infoPollWaitFrames = 2;
    return;
  }

  if (infoPollState === "closing") {
    infoPollWaitFrames--;
    if (infoPollWaitFrames <= 0) {
      infoPollState = "closed";
      infoPollCooldown = INFO_POLL_INTERVAL;
    }
  }

  const canPoll = infoPollState === "closed"
    && !inChatroom && bot.actions.empty
    && (belief.phase === "playing" || belief.phase === "hostage_select");
  if (canPoll) {
    infoPollCooldown--;
    if (infoPollCooldown <= 0) {
      bot.actions.push(BUTTON_B, 0);
      infoPollState = "opening";
      infoPollWaitFrames = INFO_SETTLE_FRAMES;
      return;
    }
  }

  updateMinimap(belief, frame);

  if (bot.movementTarget || bot.wandering) {
    updatePosition(belief, frame);
  }

  if (tickMovement(bot)) return;

  const event = checkTriggers(belief, lastPromptTick, bot.movementTarget !== null);
  if (event) {
    updateHud(belief, frame);
    if (!llmBusy) promptLLM(event);
  }

  if (bot.wandering || (!bot.movementTarget && bot.actions.empty)) {
    tickWander(bot);
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

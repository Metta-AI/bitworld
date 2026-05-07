/**
 * LLM Bot v2 — OODA policy architecture.
 *
 * Observe parses a frame snapshot. Orient updates deterministic knowledge,
 * schedules/receives non-blocking LLM orienters, and resolves policy. Decide is
 * deterministic and never calls LLMs. Act emits atoms or advances one activity.
 */

import WebSocket from "ws";
import { argv } from "process";
import { appendFileSync, mkdirSync } from "fs";
import { dirname, resolve } from "path";
import { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";
import { ActionQueue } from "./bot_utils.js";
import { createGameKnowledge } from "./game_knowledge.js";
import { parseArgs, type BotController } from "./bot_common.js";
import { BackgroundObserver } from "./background_observer.js";
import { SkillTriggerManager } from "./skills.js";
import { observeFrame } from "./ooda_observe.js";
import { OodaOrienter } from "./ooda_orient.js";
import { OodaDecider } from "./ooda_decide.js";
import { OodaActuator } from "./ooda_act.js";

const cliArgs = parseArgs(argv.slice(2));
const botUrl = cliArgs["url"] ?? "ws://localhost:8080/player";
const botName = cliArgs["name"] ?? "llm_bot";
const MODEL_ALIASES: Record<string, string> = {
  haiku: "us.anthropic.claude-haiku-4-5-20251001-v1:0",
  sonnet: "us.anthropic.claude-sonnet-4-6",
  opus: "us.anthropic.claude-opus-4-6",
};
const rawModel = cliArgs["model"] ?? "sonnet";
const modelId = MODEL_ALIASES[rawModel] ?? rawModel;
const region = cliArgs["region"] ?? "us-west-2";
const llmDisabled = cliArgs["disable-llm"] === "true" || process.env.BOT_DISABLE_LLM === "1";

const bedrock = new BedrockRuntimeClient({ region });
const ws = new WebSocket(`${botUrl}?name=${botName}`, { perMessageDeflate: false });
const knowledge = createGameKnowledge(botName);

const logDir = cliArgs["log-dir"] ?? process.env.BOT_LOG_DIR ?? "../logs/bots";
const logPath = resolve(process.cwd(), logDir, `${Date.now()}-${botName}.jsonl`);
mkdirSync(dirname(logPath), { recursive: true });

function logEvent(kind: string, data: Record<string, unknown> = {}): void {
  const row = {
    t: knowledge.tick,
    bot: botName,
    kind,
    phase: knowledge.phase,
    round: knowledge.matchFacts.currentRound,
    room: knowledge.myRoom,
    self: knowledge.myCharName,
    ...data,
  };
  appendFileSync(logPath, JSON.stringify(row) + "\n");
}

const bot: BotController = {
  ws,
  actions: new ActionQueue(),
  player: knowledge,
  name: botName,
  movementTarget: null,
  wandering: false,
  wanderTarget: null,
  wanderTicks: 0,
  lastFrame: null,
  get psychopompPrecommit() { return knowledge.action.psychopompPrecommit; },
  set psychopompPrecommit(value: string[] | null) {
    knowledge.action.psychopompPrecommit = value ?? [];
    knowledge.action.psychopompPrecommitRound = knowledge.matchFacts.currentRound;
  },
  get lastSentChat() { return knowledge.action.lastSentChat; },
  set lastSentChat(value: string | null) { knowledge.action.lastSentChat = value; },
  get hasNewIncomingChat() { return knowledge.action.hasNewIncomingChat; },
  set hasNewIncomingChat(value: boolean) { knowledge.action.hasNewIncomingChat = value; },
  nonInterruptingTasks: [],
};

const skillConfig = { bedrock, modelId, botName };
const skillTriggers = new SkillTriggerManager(skillConfig);
const observer = new BackgroundObserver({
  bedrock,
  modelId,
  botName,
  ws,
  getKnowledge: () => knowledge,
  onNotesUpdate: (notes) => orienter.onNotesUpdate(notes),
});

const orienter = new OodaOrienter({
  knowledge,
  bot,
  observer,
  skillTriggers,
  llmDisabled,
  logEvent,
});
const actuator = new OodaActuator({ ws, knowledge, bot, botName, logEvent });
const decider = new OodaDecider({
  knowledge,
  bot,
  psychopompStatus: () => actuator.psychopompStatus(),
  logEvent,
});

function onFrame(data: Buffer): void {
  const observation = observeFrame(data);
  if (!observation) return;

  orienter.orient(observation);
  const decision = decider.decide(observation);
  actuator.act(decision);
}

ws.on("open", () => console.log(`[${botName}] Connected to ${botUrl}`));
ws.on("message", (data: Buffer) => onFrame(data));
ws.on("close", () => {
  console.log(`[${botName}] Disconnected`);
  orienter.stop();
  process.exit(0);
});
ws.on("error", (err) => console.error(`[${botName}] Error:`, err.message));
process.on("SIGINT", () => {
  ws.close();
  process.exit(0);
});

console.log(`LLM Bot v2: ${botName} | model: ${llmDisabled ? "disabled" : modelId} | region: ${region} | server: ${botUrl}`);

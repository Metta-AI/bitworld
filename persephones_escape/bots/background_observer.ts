/**
 * Background Observer — slow-cadence LLM loop that writes notes only.
 */

import {
  BedrockRuntimeClient, ConverseCommand,
  type Tool,
} from "@aws-sdk/client-bedrock-runtime";
import WebSocket from "ws";
import {
  type GameKnowledge, type KnowledgeNotes,
  formatContextDump, checkTriggers, mergeKnowledgeNotes, formatNotes,
} from "./game_knowledge.js";

export interface ObserverConfig {
  bedrock: BedrockRuntimeClient;
  modelId: string;
  botName: string;
  ws: WebSocket;
  getKnowledge: () => GameKnowledge;
  onNotesUpdate: (notes: KnowledgeNotes) => void;
}

const OBSERVER_SYSTEM = `You are a strategic observer for an agent playing Persephone's Escape, a secret role social deduction game.

You receive periodic game-state updates. Analyze them and update NOTES only.

Rules:
- You cannot choose direct actions, target queues, psychopomps, usurps, or menu commands.
- Focused Decide skills read your notes later.
- Keep notes compact, factual, and uncertainty-aware.
- Use exact COLOR.SHAPE player names.

Write notes with this schema:
{
  "global": "short strategic summary",
  "goals": ["short goal"],
  "risks": ["short risk"],
  "messageNotes": ["short note from recent messages"],
  "players": {
    "R.CRCL": {"summary":"...", "trust":"ally|enemy|unknown|mixed", "wants":"...", "warnings":"..."}
  }
}`;

const NOTES_TOOL: Tool = {
  toolSpec: {
    name: "update_notes",
    description: "Update compact strategic notes. All fields are optional; omit fields that should not change.",
    inputSchema: {
      json: {
        type: "object",
        properties: {
          global: { type: "string" },
          goals: { type: "array", items: { type: "string" } },
          risks: { type: "array", items: { type: "string" } },
          messageNotes: { type: "array", items: { type: "string" } },
          players: {
            type: "object",
            additionalProperties: {
              type: "object",
              properties: {
                summary: { type: "string" },
                trust: { type: "string", enum: ["ally", "enemy", "unknown", "mixed"] },
                wants: { type: "string" },
                warnings: { type: "string" },
              },
              additionalProperties: false,
            },
          },
        },
        additionalProperties: false,
      },
    },
  },
};

const OBSERVER_MIN_INTERVAL_MS = 10000;
const OBSERVER_TIMEOUT_MS = 20000;

export class BackgroundObserver {
  private running = false;
  private lastPromptTick = -999;
  private lastRunStartedMs = -Infinity;

  constructor(private config: ObserverConfig) {}

  start(): void {
    if (this.running) return;
    this.running = true;
    this.loop();
  }

  stop(): void {
    this.running = false;
  }

  private buildHarnessBlock(): string {
    const knowledge = this.config.getKnowledge();
    const event = checkTriggers(knowledge, this.lastPromptTick, false) ?? "idle";
    const state = formatContextDump(knowledge, event) +
      `\n\nCURRENT NOTES:\n${formatNotes(knowledge.notes)}`;
    return `[STATE UPDATE]\n${state}\n[/STATE UPDATE]`;
  }

  private async callLLM(harnessBlock: string): Promise<Record<string, any> | null> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), OBSERVER_TIMEOUT_MS);
    try {
      const resp = await this.config.bedrock.send(new ConverseCommand({
        modelId: this.config.modelId,
        system: [{ text: OBSERVER_SYSTEM }],
        messages: [{ role: "user", content: [{ text: harnessBlock }] }],
        toolConfig: { tools: [NOTES_TOOL] },
        inferenceConfig: { maxTokens: 500, temperature: 0.2 },
      }), { abortSignal: controller.signal });

      const content = resp.output?.message?.content ?? [];
      let toolInput: Record<string, any> | null = null;

      for (const block of content) {
        if ("toolUse" in block && block.toolUse) {
          toolInput = block.toolUse.input as Record<string, any>;
        }
      }

      return toolInput;
    } catch (e: any) {
      if (e.name === "AbortError" || e.name === "TimeoutError") {
        console.log(`[${this.config.botName}] observer timed out after ${OBSERVER_TIMEOUT_MS}ms`);
      } else {
        console.error(`[${this.config.botName}] observer error:`, e.message);
      }
      return null;
    } finally {
      clearTimeout(timeout);
    }
  }

  private async loop(): Promise<void> {
    while (this.running && this.config.ws.readyState === WebSocket.OPEN) {
      let knowledge = this.config.getKnowledge();
      if (knowledge.phase === "role_reveal" || knowledge.phase === "psychopomp_exchange" || knowledge.phase === "unknown") {
        await new Promise(r => setTimeout(r, 1000));
        continue;
      }

      const elapsedSinceStart = Date.now() - this.lastRunStartedMs;
      if (elapsedSinceStart < OBSERVER_MIN_INTERVAL_MS) {
        await new Promise(r => setTimeout(r, OBSERVER_MIN_INTERVAL_MS - elapsedSinceStart));
        continue;
      }

      this.lastRunStartedMs = Date.now();
      knowledge = this.config.getKnowledge();
      this.lastPromptTick = knowledge.tick;
      console.log(`[${this.config.botName}] observer → LLM notes`);
      const update = await this.callLLM(this.buildHarnessBlock());
      if (update && Object.keys(update).length > 0) {
        const merged = mergeKnowledgeNotes(knowledge.notes, update, knowledge.tick);
        this.config.onNotesUpdate(merged);
        console.log(`[${this.config.botName}] observer updated notes:`, Object.keys(update).join(", "));
      }
    }
  }
}

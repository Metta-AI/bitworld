/**
 * Focused LLM orienters. All outputs are bounded policy patches or notes;
 * deterministic Decide never waits on them.
 */

import {
  BedrockRuntimeClient, ConverseCommand,
} from "@aws-sdk/client-bedrock-runtime";
import {
  type GameKnowledge,
  type KnowledgeNotes,
  type ResolvedPolicy,
  psychopompCountForRound,
  queueCommunicationDraft,
  mergeKnowledgeNotes,
  formatNotes,
  updateDecisionMemory,
  updatePursueDecisionMemory,
} from "./game_knowledge.js";

export interface SkillConfig {
  bedrock: BedrockRuntimeClient;
  modelId: string;
  botName: string;
}

interface SkillCallOptions {
  systemPrompt: string;
  userPrompt: string;
  timeoutMs?: number;
  maxTokens?: number;
}

const DEFAULT_SKILL_TIMEOUT_MS = 20000;

function normalizeRole(role: string | null | undefined): string {
  const r = (role ?? "").trim().toUpperCase();
  switch (r) {
    case "ECHO OF HADES": return "HADES";
    case "ECHO OF PERSEPHONE": return "PERSEPHONE";
    case "ECHO OF CERBERUS": return "CERBERUS";
    case "ECHO OF DEMETER": return "DEMETER";
    default: return r;
  }
}

function keyPartnerRole(role: string | null): string | null {
  switch (normalizeRole(role)) {
    case "HADES": return "CERBERUS";
    case "CERBERUS": return "HADES";
    case "PERSEPHONE": return "DEMETER";
    case "DEMETER": return "PERSEPHONE";
    default: return null;
  }
}

async function callSkillLLM(config: SkillConfig, opts: SkillCallOptions): Promise<string | null> {
  const controller = new AbortController();
  const timeoutMs = opts.timeoutMs ?? DEFAULT_SKILL_TIMEOUT_MS;
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const resp = await config.bedrock.send(new ConverseCommand({
      modelId: config.modelId,
      system: [{ text: opts.systemPrompt }],
      messages: [{ role: "user", content: [{ text: opts.userPrompt }] }],
      inferenceConfig: { maxTokens: opts.maxTokens ?? 300, temperature: 0.25 },
    }), { abortSignal: controller.signal });
    const content = resp.output?.message?.content ?? [];
    let text = "";
    for (const block of content) {
      if ("text" in block && block.text) text += block.text;
    }
    return text.trim() || null;
  } catch (e: any) {
    if (e.name === "AbortError" || e.name === "TimeoutError") {
      console.log(`[${config.botName}] skill timed out (${timeoutMs}ms)`);
    } else {
      console.error(`[${config.botName}] skill error:`, e.message);
    }
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function parseJsonObject(raw: string | null): Record<string, any> | null {
  if (!raw) return null;
  try {
    const start = raw.indexOf("{");
    const end = raw.lastIndexOf("}");
    if (start < 0 || end <= start) return null;
    return JSON.parse(raw.slice(start, end + 1));
  } catch {
    return null;
  }
}

function parseJsonArray(raw: string | null): any[] | null {
  if (!raw) return null;
  try {
    const start = raw.indexOf("[");
    const end = raw.lastIndexOf("]");
    if (start < 0 || end <= start) return null;
    const parsed = JSON.parse(raw.slice(start, end + 1));
    return Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function compactPlayers(knowledge: GameKnowledge) {
  return Array.from(knowledge.players.values()).map(p => ({
    name: p.name,
    room: p.lastRoom,
    pos: p.lastPos,
    knownTeam: p.knownTeam,
    knownRole: p.knownRole,
    exchangedColor: p.theyRevealedColor || !!p.knownTeam,
    exchangedRole: p.weSharedWith,
    roleRevealed: p.theyRevealedCard || !!p.knownRole,
    inWhisper: p.inWhisper,
    ambiguous: p.positionAmbiguousByColor,
    note: knowledge.notes.players[p.name],
  }));
}

function inCurrentRoomPlayers(knowledge: GameKnowledge) {
  return compactPlayers(knowledge)
    .filter(p => p.name !== knowledge.myCharName)
    .filter(p => p.room === knowledge.myRoom);
}

function validNames(knowledge: GameKnowledge): Set<string> {
  return new Set(inCurrentRoomPlayers(knowledge).map(p => p.name));
}

export interface ExchangePriorityDecision {
  pursueColorExchangeWithPlayer?: string[];
  pursueRoleExchangeWithPlayer?: string[];
  avoidPlayers?: string[];
}

const EXCHANGE_DECIDE_SYSTEM = `Choose exchange priority queues for Persephone's Escape.
Return JSON or null. JSON fields are optional:
{"pursueColorExchangeWithPlayer":["R.CRCL"],"pursueRoleExchangeWithPlayer":["B.SQR"],"avoidPlayers":["Y.TRI"]}
Only include valid in-room player names from the provided candidates. Exclude self. Exclude players already exchanged for that information.
Only role-exchange confirmed teammates. If key partner is already role-exchanged/shared, do not include them.`;

export async function decideExchangePriorities(
  config: SkillConfig,
  knowledge: GameKnowledge,
  strategy: ResolvedPolicy,
): Promise<ExchangePriorityDecision | null> {
  const names = validNames(knowledge);
  const candidates = inCurrentRoomPlayers(knowledge);
  const prompt = `Self: ${JSON.stringify(knowledge.self)}
In-room candidates only: ${JSON.stringify(candidates)}
Current strategy: ${JSON.stringify({
    color: strategy.pursueColorExchangeWithPlayer,
    role: strategy.pursueRoleExchangeWithPlayer,
    avoid: strategy.avoidPlayers,
})}
Notes: ${formatNotes(knowledge.notes)}
Strategy notes: ${JSON.stringify(knowledge.llmNotes.decisions.exchange)}
Return JSON update or null.`;
  const raw = await callSkillLLM(config, {
    systemPrompt: EXCHANGE_DECIDE_SYSTEM,
    userPrompt: prompt,
    maxTokens: 220,
  });
  if (raw?.trim().toLowerCase() === "null") return null;
  const obj = parseJsonObject(raw);
  if (!obj) return null;
  const update: ExchangePriorityDecision = {};
  for (const key of ["pursueColorExchangeWithPlayer", "pursueRoleExchangeWithPlayer", "avoidPlayers"] as const) {
    if (!Array.isArray(obj[key])) continue;
    update[key] = obj[key].filter((s: any) => typeof s === "string" && names.has(s) && s !== knowledge.myCharName);
  }
  return Object.keys(update).length > 0 ? update : null;
}

export type PursueModeDecision = "find_spot" | "go_to_player" | "noop";

const PURSUE_MODE_SYSTEM = `Choose how to pursue a target in Persephone's Escape.
Return exactly one JSON object: {"mode":"find_spot"|"go_to_player"|"noop","reason":"short"}.
Use find_spot when clustering is a risk or inviting to a private location is better. Use go_to_player when target is close/available. Use noop if this pursue is currently bad.`;

export async function decidePursueMode(
  config: SkillConfig,
  knowledge: GameKnowledge,
  target: string,
  exchange: "color" | "role",
): Promise<{ mode: PursueModeDecision; reason: string } | null> {
  const pb = knowledge.players.get(target);
  if (!pb || pb.lastRoom !== knowledge.myRoom) {
    return { mode: "noop", reason: `${target} not in current room` };
  }
  const raw = await callSkillLLM(config, {
    systemPrompt: PURSUE_MODE_SYSTEM,
    userPrompt: `Self: ${JSON.stringify(knowledge.self)}
Target: ${JSON.stringify(pb)}
Exchange: ${exchange}
Nearby: ${knowledge.nearbyNames.join(", ")}
Recent shouts: ${knowledge.shoutLog.slice(-5).map(s => s.text).join(" | ")}
Notes: ${formatNotes(knowledge.notes)}`,
    maxTokens: 100,
  });
  const obj = parseJsonObject(raw);
  if (!obj || !["find_spot", "go_to_player", "noop"].includes(obj.mode)) return null;
  return { mode: obj.mode, reason: typeof obj.reason === "string" ? obj.reason.slice(0, 120) : "decide" };
}

const PSYCHOPOMP_SYSTEM = `Choose concrete psychopomp targets to send to the other room.
Return only a JSON array of valid player names, or null only if there are no valid candidates.
Do not use team/enemy priority buckets as hard filters. Known team, role, partner, and message context are strategy signals, but any in-room non-self candidate can be a valid psychopomp.
When there is no clear strategic reason, choose from the valid candidates anyway instead of returning null.`;

export async function decidePsychopomps(
  config: SkillConfig,
  knowledge: GameKnowledge,
): Promise<string[] | null> {
  const count = psychopompCountForRound(knowledge) ?? 1;
  const inRoom = Array.from(knowledge.players.values())
    .filter(p => p.lastRoom === knowledge.myRoom && p.name !== knowledge.myCharName);
  const valid = new Set(inRoom.map(p => p.name));
  const raw = await callSkillLLM(config, {
    systemPrompt: PSYCHOPOMP_SYSTEM,
    userPrompt: `Self: ${JSON.stringify(knowledge.self)}
Need ${count}.
Candidates: ${JSON.stringify(inRoom)}
Notes: ${formatNotes({ ...knowledge.notes, players: Object.fromEntries(inRoom.map(p => [p.name, knowledge.notes.players[p.name]]).filter(([, v]) => !!v)) })}
Strategy notes: ${JSON.stringify(knowledge.llmNotes.decisions.psychopomp)}`,
    maxTokens: 120,
  });
  if (raw?.trim().toLowerCase() === "null") return null;
  const arr = parseJsonArray(raw);
  if (!arr) return null;
  const chosen = arr.filter((s: any) => typeof s === "string" && valid.has(s)).slice(0, count);
  return chosen.length > 0 ? chosen : null;
}

const USURP_SYSTEM = `Decide whether to usurp before psychopomp select. Return JSON or null:
{"shouldUsurp":true|false,"target":"PLAYER.NAME"|null,"reason":"short"}
Usurp can be useful at any point. Recommend it when the current leader is harmful, unresponsive, or a better leader is available.`;

export async function decideUsurp(
  config: SkillConfig,
  knowledge: GameKnowledge,
): Promise<{ shouldUsurp: boolean; target: string | null } | null> {
  const candidates = Array.from(knowledge.players.values())
    .filter(p => p.lastRoom === knowledge.myRoom && p.name !== knowledge.myCharName)
    .map(p => ({ name: p.name, knownTeam: p.knownTeam, knownRole: p.knownRole, isLeader: p.isLeader, note: knowledge.notes.players[p.name] }));
  const raw = await callSkillLLM(config, {
    systemPrompt: USURP_SYSTEM,
    userPrompt: `Self: ${JSON.stringify(knowledge.self)}
Time left: ${knowledge.matchFacts.timerSecs}s
Candidates: ${JSON.stringify(candidates)}
Notes: ${formatNotes({ ...knowledge.notes, players: Object.fromEntries(candidates.map(p => [p.name, knowledge.notes.players[p.name]]).filter(([, v]) => !!v)) })}
Strategy notes: ${JSON.stringify(knowledge.llmNotes.decisions.usurp)}`,
    maxTokens: 120,
  });
  if (raw?.trim().toLowerCase() === "null") return null;
  const obj = parseJsonObject(raw);
  if (!obj || typeof obj.shouldUsurp !== "boolean") return null;
  return { shouldUsurp: obj.shouldUsurp, target: typeof obj.target === "string" ? obj.target : null };
}

const INTERPRET_NOTES_SYSTEM = `Interpret game messages and update notes only. Return JSON notes update or null.
Do not output action queues, psychopomps, usurps, or targets.`;

export async function interpretMessagesToNotes(
  config: SkillConfig,
  knowledge: GameKnowledge,
): Promise<KnowledgeNotes | null> {
  const recentShouts = knowledge.shoutLog.slice(-8).map(s => s.text);
  const recentWhispers = knowledge.whisperMessages.slice(-8).map(m => `${m.senderColor}: ${m.text}`);
  if (recentShouts.length === 0 && recentWhispers.length === 0) return null;
  const raw = await callSkillLLM(config, {
    systemPrompt: INTERPRET_NOTES_SYSTEM,
    userPrompt: `Self: ${JSON.stringify(knowledge.self)}
Recent shouts:
${recentShouts.join("\n") || "(none)"}
Recent whispers:
${recentWhispers.join("\n") || "(none)"}
Known relevant players: ${JSON.stringify(compactPlayers(knowledge).slice(0, 12))}
Current notes: ${formatNotes(knowledge.notes)}
Return notes JSON or null.`,
    maxTokens: 220,
  });
  if (raw?.trim().toLowerCase() === "null") return null;
  const obj = parseJsonObject(raw);
  return obj ? mergeKnowledgeNotes(knowledge.notes, obj, knowledge.tick) : null;
}

const TALK_WHISPER_SYSTEM = `Write one short in-game whisper message under 40 chars. Return only the text or null.`;
const TALK_SHOUT_SYSTEM = `Write one short room shout under 40 chars. Use "@ x,y" for locations. Return only text or null.`;

export async function talkPrefetch(
  config: SkillConfig,
  knowledge: GameKnowledge,
  strategy: ResolvedPolicy,
  target: string,
  context: "whisper" | "shout",
): Promise<string | null> {
  const known = knowledge.players.get(target);
  const recentMessages = context === "whisper"
    ? knowledge.whisperMessages.slice(-3).map(m => `${m.senderShape !== null ? `${m.senderColor}.${m.senderShape}` : m.senderColor}: ${m.text}`).join("\n")
    : knowledge.shoutLog.slice(-3).map(s => s.text).join("\n");
  const raw = await callSkillLLM(config, {
    systemPrompt: context === "whisper" ? TALK_WHISPER_SYSTEM : TALK_SHOUT_SYSTEM,
    userPrompt: `Self: ${JSON.stringify(knowledge.self)}
Target: ${target} ${known ? JSON.stringify({ team: known.knownTeam, role: known.knownRole }) : ""}
Recent messages:
${recentMessages || "(none)"}
Notes: ${formatNotes(knowledge.notes)}
Current strategy: ${JSON.stringify(strategy)}`,
    maxTokens: 60,
  });
  if (!raw || raw.trim().toLowerCase() === "null") return null;
  const cleaned = raw.replace(/^["']|["']$/g, "").trim();
  return cleaned.length > 0 ? cleaned.slice(0, 40) : null;
}

export interface CommunicationDecision {
  shout?: string[];
  whisper?: { target: string; text: string }[];
}

const COMMUNICATION_SYSTEM = `Choose short useful in-game messages for Persephone's Escape.
Return JSON or null:
{"shout":["..."],"whisper":[{"target":"R.CRCL","text":"..."}]}
Only write messages that are immediately useful. Keep each message <=40 chars.
Use shouts for room coordination, meetups, psychopomp requests, and usurp votes.
Use whisper messages for occupants/known reachable players. Do not invent game facts.`;

export async function decideCommunication(
  config: SkillConfig,
  knowledge: GameKnowledge,
  strategy: ResolvedPolicy,
): Promise<CommunicationDecision | null> {
  const valid = validNames(knowledge);
  const recentShouts = knowledge.shoutLog.slice(-18).map(s => `${s.tick}:${s.text}`);
  const recentWhispers = knowledge.chatLog.slice(-18).map(m => `${m.senderColor}.${m.senderShape ?? "?"}: ${m.text}`);
  const prompt = `Self: ${JSON.stringify(knowledge.self)}
Phase: ${knowledge.phase} round=${knowledge.matchFacts.currentRound} time=${knowledge.matchFacts.timerSecs}
Current room players: ${JSON.stringify(inCurrentRoomPlayers(knowledge))}
Occupants: ${knowledge.occupantNames.join(", ") || "(none)"}
Current strategy: ${JSON.stringify({
    color: strategy.pursueColorExchangeWithPlayer,
    role: strategy.pursueRoleExchangeWithPlayer,
    meetPoint: strategy.meetPoint,
    psychopompTargets: strategy.psychopompTargets,
    shouldUsurp: strategy.shouldUsurp,
    usurpTarget: strategy.usurpTarget,
})}
Recent room shouts:
${recentShouts.join("\n") || "(none)"}
Recent whisper/global history:
${recentWhispers.join("\n") || "(none)"}
Notes: ${formatNotes(knowledge.notes)}
Return JSON or null.`;
  const raw = await callSkillLLM(config, {
    systemPrompt: COMMUNICATION_SYSTEM,
    userPrompt: prompt,
    maxTokens: 260,
  });
  if (raw?.trim().toLowerCase() === "null") return null;
  const obj = parseJsonObject(raw);
  if (!obj) return null;
  const out: CommunicationDecision = {};
  if (Array.isArray(obj.shout)) {
    out.shout = obj.shout
      .filter((s: any) => typeof s === "string")
      .map((s: string) => s.replace(/\s+/g, " ").trim().slice(0, 40))
      .filter(Boolean)
      .slice(0, 2);
  }
  if (Array.isArray(obj.whisper)) {
    out.whisper = obj.whisper
      .filter((m: any) => m && typeof m.target === "string" && typeof m.text === "string" && valid.has(m.target))
      .map((m: any) => ({ target: m.target, text: m.text.replace(/\s+/g, " ").trim().slice(0, 40) }))
      .filter((m: { target: string; text: string }) => m.text.length > 0)
      .slice(0, 3);
  }
  return (out.shout?.length || out.whisper?.length) ? out : null;
}

export class SkillTriggerManager {
  private psychopompDecisionTick = -Infinity;
  private usurpDecisionTick = -Infinity;
  private exchangeDecisionTick = -Infinity;
  private interpretTick = -Infinity;
  private communicationTick = -Infinity;
  private talkPrefetchPending = false;
  private exchangePending = false;
  private psychopompPending = false;
  private usurpPending = false;
  private interpretPending = false;
  private communicationPending = false;
  private pursueModePending = new Set<string>();

  constructor(private config: SkillConfig) {}

  check(
    knowledge: GameKnowledge,
    strategy: ResolvedPolicy,
    onStrategyUpdate: (update: Partial<ResolvedPolicy>) => void,
    onNotesUpdate: (notes: KnowledgeNotes) => void,
    onCommunicationUpdate?: (update: CommunicationDecision) => void,
  ): void {
    const tick = knowledge.tick;

    if (
      knowledge.phase === "playing" &&
      tick - this.exchangeDecisionTick > 120 &&
      !this.exchangePending
    ) {
      this.exchangeDecisionTick = tick;
      this.exchangePending = true;
      decideExchangePriorities(this.config, knowledge, strategy).then(update => {
        this.exchangePending = false;
        if (update) {
          updateDecisionMemory(knowledge, "exchange", `exchange queues updated: ${Object.keys(update).join(", ")}`);
          onStrategyUpdate(update);
        } else {
          updateDecisionMemory(knowledge, "exchange", "exchange decide returned no update");
        }
      });
    }

    if (
      knowledge.amLeader &&
      (knowledge.phase === "playing" || knowledge.phase === "leader_summit" || knowledge.phase === "psychopomp_select") &&
      tick - this.psychopompDecisionTick > 120 &&
      !this.psychopompPending
    ) {
      this.psychopompDecisionTick = tick;
      this.psychopompPending = true;
      decidePsychopomps(this.config, knowledge).then(targets => {
        this.psychopompPending = false;
        updateDecisionMemory(knowledge, "psychopomp", targets ? `psychopomp targets: ${targets.join(", ")}` : "psychopomp decide null");
        if (targets) onStrategyUpdate({ psychopompTargets: targets });
      });
    }

    if (
      knowledge.phase !== "lobby" &&
      knowledge.phase !== "roster_reveal" &&
      knowledge.phase !== "role_reveal" &&
      tick - this.communicationTick > 180 &&
      !this.communicationPending &&
      onCommunicationUpdate
    ) {
      this.communicationTick = tick;
      this.communicationPending = true;
      decideCommunication(this.config, knowledge, strategy).then(update => {
        this.communicationPending = false;
        if (!update) return;
        for (const text of update.shout ?? []) {
          queueCommunicationDraft(knowledge, { channel: "shout", text, source: "communication_llm", reason: "focused communication" });
        }
        for (const msg of update.whisper ?? []) {
          queueCommunicationDraft(knowledge, { channel: "whisper", target: msg.target, text: msg.text, source: "communication_llm", reason: "focused communication" });
        }
        onCommunicationUpdate(update);
      });
    }

    if (
      !knowledge.amLeader &&
      (knowledge.phase === "playing" || knowledge.phase === "leader_summit" || knowledge.phase === "psychopomp_select") &&
      tick - this.usurpDecisionTick > 120 &&
      !this.usurpPending
    ) {
      this.usurpDecisionTick = tick;
      this.usurpPending = true;
      decideUsurp(this.config, knowledge).then(result => {
        this.usurpPending = false;
        if (result) {
          updateDecisionMemory(knowledge, "usurp", result.shouldUsurp ? `usurp target ${result.target ?? "unknown"}` : "do not usurp");
          onStrategyUpdate({ shouldUsurp: result.shouldUsurp, usurpTarget: result.target });
        } else {
          updateDecisionMemory(knowledge, "usurp", "usurp decide returned no update");
        }
      });
    }

    if (tick - this.interpretTick > 120 && !this.interpretPending) {
      this.interpretTick = tick;
      this.requestInterpret(knowledge, onNotesUpdate);
    }
  }

  requestTalkPrefetch(
    knowledge: GameKnowledge,
    strategy: ResolvedPolicy,
    target: string,
    context: "whisper" | "shout",
    onStrategyUpdate: (update: Partial<ResolvedPolicy>) => void,
  ): void {
    if (this.talkPrefetchPending) return;
    this.talkPrefetchPending = true;
    talkPrefetch(this.config, knowledge, strategy, target, context).then(message => {
      this.talkPrefetchPending = false;
      if (!message) return;
      if (context === "shout") onStrategyUpdate({ shoutNext: message });
      else onStrategyUpdate({ prefetchedWhisper: { target, message, tick: knowledge.tick } });
    });
  }

  requestPursueMode(
    knowledge: GameKnowledge,
    strategy: ResolvedPolicy,
    target: string,
    exchange: "color" | "role",
    onStrategyUpdate: (update: Partial<ResolvedPolicy>) => void,
  ): void {
    const key = `${target}:${exchange}`;
    if (this.pursueModePending.has(key)) return;
    this.pursueModePending.add(key);
    decidePursueMode(this.config, knowledge, target, exchange).then(result => {
      this.pursueModePending.delete(key);
      if (!result) return;
      updatePursueDecisionMemory(knowledge, key, `${result.mode}: ${result.reason}`);
      onStrategyUpdate({
        pursueModeHints: {
          ...strategy.pursueModeHints,
          [key]: { mode: result.mode, reason: result.reason, tick: knowledge.tick },
        },
      });
    });
  }

  requestInterpret(
    knowledge: GameKnowledge,
    onNotesUpdate: (notes: KnowledgeNotes) => void,
  ): void {
    if (this.interpretPending) return;
    this.interpretPending = true;
    interpretMessagesToNotes(this.config, knowledge).then(notes => {
      this.interpretPending = false;
      if (notes) {
        console.log(`[${this.config.botName}] interpret updated notes`);
        updateDecisionMemory(knowledge, "messageInterpretation", "message interpret updated notes");
        onNotesUpdate(notes);
      }
    });
  }
}

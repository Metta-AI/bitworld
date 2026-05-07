import type { BotController } from "./bot_common.js";
import {
  chooseDeterministicPsychopompTargets,
  psychopompCountForRound,
  updateGameKnowledgeFromFrame,
  drainStrategyTelemetry,
  writePolicyPatch,
  type GameKnowledge,
  type KnowledgeNotes,
  type ResolvedPolicy,
} from "./game_knowledge.js";
import type { BackgroundObserver } from "./background_observer.js";
import type { SkillTriggerManager } from "./skills.js";
import type { BotLogFn, FrameObservation } from "./ooda_types.js";

export interface OodaOrienterConfig {
  knowledge: GameKnowledge;
  bot: BotController;
  observer: BackgroundObserver;
  skillTriggers: SkillTriggerManager;
  llmDisabled: boolean;
  logEvent: BotLogFn;
}

export class OodaOrienter {
  private lastLoggedPhase = "unknown";
  private lastLoggedWhisper = "";
  private observerStarted = false;

  constructor(private config: OodaOrienterConfig) {}

  stop(): void {
    this.config.observer.stop();
  }

  onPolicyPatch = (update: Partial<ResolvedPolicy>): void => {
    const { knowledge, logEvent } = this.config;
    const accepted = writePolicyPatch(knowledge, "focused_llm", update);
    logEvent("policy_patch", { accepted, keys: Object.keys(update), update });
  };

  onNotesUpdate = (notes: KnowledgeNotes): void => {
    const { knowledge, logEvent } = this.config;
    knowledge.llmNotes.notes = notes;
    knowledge.notes = notes;
    logEvent("notes_update", { notes });
  };

  orient(observation: FrameObservation): void {
    const { knowledge, bot, skillTriggers, llmDisabled, logEvent } = this.config;

    bot.lastFrame = observation.frame;
    const prevMsgCount = knowledge.whisperMessages.length + knowledge.chatLog.length + knowledge.shoutLog.length;
    updateGameKnowledgeFromFrame(knowledge, observation.frame, observation.roster);

    if (knowledge.phase !== this.lastLoggedPhase) {
      logEvent("phase_change", { from: this.lastLoggedPhase, to: knowledge.phase });
      this.lastLoggedPhase = knowledge.phase;
    }

    const whisperKey = `${knowledge.phase}:${knowledge.occupantNames.join("|")}:${knowledge.pendingEntry}:${knowledge.pendingEntryName ?? ""}:${knowledge.pendingColorOffer}:${knowledge.pendingRoleOffer}:${knowledge.pendingLeaderOffer}:${knowledge.whisperMessages.map(m => `${m.type}:${m.senderColor}:${m.text}`).join("|")}`;
    if ((knowledge.phase === "whisper" || knowledge.phase === "leader_summit") && whisperKey !== this.lastLoggedWhisper) {
      const offerSystems = knowledge.whisperMessages
        .filter(m => m.type === "system")
        .map(m => m.text)
        .filter(text => /OFFER|XCHG|ACCEPT/i.test(text))
        .slice(-5);
      logEvent("whisper_state", {
        phase: knowledge.phase,
        occupants: knowledge.occupantNames,
        occupantCount: knowledge.occupantCount,
        pendingEntry: knowledge.pendingEntry,
        pendingEntryName: knowledge.pendingEntryName,
        pendingColorOffer: knowledge.pendingColorOffer,
        pendingRoleOffer: knowledge.pendingRoleOffer,
        pendingLeaderOffer: knowledge.pendingLeaderOffer,
        offerSystems,
        recentWhisperMessages: knowledge.whisperMessages.slice(-6),
      });
      this.lastLoggedWhisper = whisperKey;
    }

    const newMsgCount = knowledge.whisperMessages.length + knowledge.chatLog.length + knowledge.shoutLog.length;
    if (newMsgCount > prevMsgCount) {
      bot.hasNewIncomingChat = true;
      logEvent("message_count_increased", {
        prevMsgCount,
        newMsgCount,
        recentShouts: knowledge.shoutLog.slice(-3),
        recentWhispers: knowledge.whisperMessages.slice(-3),
        phase: knowledge.phase,
        occupants: knowledge.occupantNames,
        pendingColorOffer: knowledge.pendingColorOffer,
        pendingRoleOffer: knowledge.pendingRoleOffer,
      });
      if (!llmDisabled) skillTriggers.requestInterpret(knowledge, this.onNotesUpdate);
    }

    if (!llmDisabled && knowledge.phase !== "lobby" && knowledge.phase !== "roster_reveal" && knowledge.phase !== "role_reveal") {
      this.ensureObserverStarted();
      skillTriggers.check(knowledge, knowledge.policy.resolved, this.onPolicyPatch, this.onNotesUpdate, update => {
        logEvent("communication_patch", {
          shout: update.shout ?? [],
          whisper: update.whisper ?? [],
        });
      });
      this.scheduleFocusedActivityOrienters();
    }

    this.updatePsychopompPrecommit();

    for (const event of drainStrategyTelemetry(knowledge)) {
      logEvent("strategy_telemetry", event);
    }
  }

  private scheduleFocusedActivityOrienters(): void {
    const { knowledge, skillTriggers } = this.config;
    const activity = knowledge.action.currentActivity;
    if (activity?.kind !== "pursue_player") return;
    const target = activity.target;
    if (!target || !knowledge.players.has(target)) return;

    if (activity.mode === "color" || activity.mode === "role") {
      const hintKey = `${target}:${activity.mode}`;
      const hint = knowledge.policy.resolved.pursueModeHints[hintKey];
      if (!hint || knowledge.tick - hint.tick > 240) {
        skillTriggers.requestPursueMode(
          knowledge,
          knowledge.policy.resolved,
          target,
          activity.mode,
          this.onPolicyPatch,
        );
      }
    }

    const hasFreshDraft = knowledge.policy.resolved.prefetchedWhisper?.target === target
      && knowledge.tick - knowledge.policy.resolved.prefetchedWhisper.tick <= 300;
    const prefetchKey = `${target}:${activity.mode}`;
    if (!hasFreshDraft && knowledge.action.exchange.prefetchRequested !== prefetchKey) {
      knowledge.action.exchange.prefetchRequested = prefetchKey;
      skillTriggers.requestTalkPrefetch(
        knowledge,
        knowledge.policy.resolved,
        target,
        "whisper",
        this.onPolicyPatch,
      );
    }
  }

  private ensureObserverStarted(): void {
    if (this.config.llmDisabled || this.observerStarted) return;
    this.observerStarted = true;
    this.config.observer.start();
  }

  private updatePsychopompPrecommit(): void {
    const { knowledge, logEvent } = this.config;
    if (!knowledge.amLeader) return;
    if (knowledge.phase !== "playing" && knowledge.phase !== "psychopomp_select") return;
    const needed = psychopompCountForRound(knowledge) ?? 0;
    const fromPolicy = knowledge.policy.resolved.psychopompTargets?.filter(name => knowledge.players.has(name)) ?? [];
    if (knowledge.action.psychopompPrecommitRound !== knowledge.matchFacts.currentRound) {
      knowledge.action.psychopompPrecommit = [];
      knowledge.action.psychopompPrecommitRound = knowledge.matchFacts.currentRound;
      logEvent("psychopomp_precommit_cleared", { round: knowledge.matchFacts.currentRound });
    }

    if (fromPolicy.length > 0) {
      const next = needed > 0 ? fromPolicy.slice(0, needed) : fromPolicy;
      if (knowledge.action.psychopompPrecommit.join("|") !== next.join("|")) {
        knowledge.action.psychopompPrecommit = next;
        knowledge.action.psychopompPrecommitRound = knowledge.matchFacts.currentRound;
        logEvent("psychopomp_precommit_updated", { targets: next, source: "policy" });
      }
      if (knowledge.phase !== "psychopomp_select" || needed <= 0 || next.length >= needed) return;
    }

    if (knowledge.phase !== "psychopomp_select" || needed <= 0 || knowledge.action.psychopompPrecommit.length >= needed) return;

    const existing = knowledge.action.psychopompPrecommit.filter(name => knowledge.players.has(name));
    const deterministic = chooseDeterministicPsychopompTargets(knowledge).filter(name => !existing.includes(name));
    const targets = [...existing, ...deterministic].slice(0, needed);
    if (targets.length > existing.length || knowledge.action.psychopompPrecommit.join("|") !== targets.join("|")) {
      knowledge.action.psychopompPrecommit = targets;
      knowledge.action.psychopompPrecommitRound = knowledge.matchFacts.currentRound;
      logEvent("psychopomp_precommit_filled", { targets, source: "deterministic" });
    }
  }
}

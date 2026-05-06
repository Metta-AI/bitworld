import { BUTTON_A, BUTTON_LEFT, BUTTON_RIGHT, BUTTON_SELECT } from "../game/constants.js";
import type { BotController } from "./bot_common.js";
import {
  colorFromCharName,
  hasColorExchangeSucceeded,
  hasRoleExchangeSucceeded,
  popNextShoutDraft,
  popNextWhisperDraft,
  type GameKnowledge,
  type ResolvedPolicy,
} from "./game_knowledge.js";
import type { Activity, AtomicAction, BotLogFn, FrameDecision, FrameObservation } from "./ooda_types.js";

export interface HostageDecisionStatus {
  round: number;
  done: boolean;
}

export interface OodaDeciderConfig {
  knowledge: GameKnowledge;
  bot: BotController;
  hostageStatus: () => HostageDecisionStatus;
  logEvent: BotLogFn;
}

const SHOUT_COOLDOWN_TICKS = 180;
const GLOBAL_CHECK_MIN_TICKS = 96;
const EXCHANGE_TIMEOUT_TICKS = 900;
const WALK_TIMEOUT_TICKS = 240;
const STALE_VISIBLE_TARGET_TICKS = 10 * 24;
const FALLBACK_HOSTAGE_COMMIT_SECS = 3;
const FALLBACK_HOSTAGE_MAX_WAIT_TICKS = 12 * 24;

let nextActivityId = 1;

export class OodaDecider {
  private introLastAdvanceTick = -Infinity;
  private introAdvanceCount = 0;
  private introRoleSeen = false;
  private introScheduleSeen = false;
  private hostageSelectStartTick = -Infinity;

  constructor(private config: OodaDeciderConfig) {}

  decide(observation: FrameObservation): FrameDecision {
    const introDecision = this.decideIntroInput();
    if (introDecision) return introDecision;

    const { knowledge } = this.config;
    if (knowledge.phase === "hostage_select" && knowledge.prevPhase !== "hostage_select") {
      this.hostageSelectStartTick = knowledge.tick;
    }
    const hostageStatus = this.config.hostageStatus();
    const hostageActive = this.shouldRunHostageSelector(hostageStatus);
    if (hostageActive) return { kind: "hostage_precommit", frame: observation.frame };

    this.enqueueReactiveAtomics();
    this.chooseActivity();
    return { kind: "run_activity", frame: observation.frame };
  }

  private shouldRunHostageSelector(hostageStatus: HostageDecisionStatus): boolean {
    const { knowledge, bot } = this.config;
    if (!knowledge.amLeader || (bot.hostagePrecommit?.length ?? 0) === 0) return false;
    const continuing = hostageStatus.round === knowledge.matchFacts.currentRound && !hostageStatus.done;
    if (continuing) return true;
    if (knowledge.phase !== "hostage_select") return false;

    const policyTargets = knowledge.policy.resolved.hostageTargets?.filter(name => bot.hostagePrecommit?.includes(name)) ?? [];
    if (policyTargets.length > 0) return true;

    const timer = knowledge.matchFacts.hostageSelectTimerSecs;
    const timerNearlyDone = timer > 0 && timer <= FALLBACK_HOSTAGE_COMMIT_SECS;
    const waitedLongEnough = this.hostageSelectStartTick > -Infinity
      && knowledge.tick - this.hostageSelectStartTick >= FALLBACK_HOSTAGE_MAX_WAIT_TICKS;
    return timerNearlyDone || waitedLongEnough;
  }

  private enqueueReactiveAtomics(): void {
    const { knowledge } = this.config;
    const policy = knowledge.policy.resolved;
    const atoms = knowledge.action.atomQueue;
    const has = (kind: AtomicAction["kind"], label?: string) =>
      atoms.some(a => a.kind === kind && (!label || a.label === label));

    if (knowledge.phase !== "whisper" && knowledge.phase !== "leader_summit") {
      knowledge.action.exchange.lastWhisperActionKey = null;
    }

    if (knowledge.phase === "whisper" || knowledge.phase === "leader_summit") {
      const denyEntry = knowledge.pendingEntryName !== null && policy.autoGrantDenyPlayers.includes(knowledge.pendingEntryName);
      if (policy.autoGrantEntry && knowledge.pendingEntry && !denyEntry && !has("whisper_action", "grant_entry")) {
        atoms.push({ kind: "whisper_action", action: "GRANT", label: "grant_entry" });
      }

      if (policy.autoAcceptColorOffer && knowledge.pendingColorOffer && !has("whisper_action", "accept_color")) {
        atoms.push({ kind: "whisper_action", action: "C.ACCPT", label: "accept_color" });
      }

      // Accept role offers from confirmed teammates/key partners
      if (this.shouldAcceptRoleOffer(policy) && knowledge.pendingRoleOffer && !has("whisper_action", "accept_role")) {
        atoms.push({ kind: "whisper_action", action: "R.ACCPT", label: "accept_role" });
      }

      if (policy.acceptLeaderOffers && knowledge.pendingLeaderOffer && !has("whisper_action", "accept_leader")) {
        atoms.push({ kind: "whisper_action", action: "TAKE", label: "accept_leader" });
      }

      const activePursuit = knowledge.action.currentActivity?.kind === "pursue_player"
        ? knowledge.action.currentActivity
        : null;

      if (policy.exitCurrentWhisper && !activePursuit && !has("whisper_action", "exit_policy")) {
        atoms.push({ kind: "whisper_action", action: "EXIT", label: "exit_policy" });
      } else if (policy.whisperActionNext && !activePursuit && !has("whisper_action", "policy_whisper_action")) {
        atoms.push({ kind: "whisper_action", action: policy.whisperActionNext, label: "policy_whisper_action" });
      }

      // Offer exchanges to occupants in our pursue lists
      if (!has("whisper_action")) {
        const occupantKey = knowledge.occupantNames.slice().sort().join("|");
        const roleTarget = knowledge.occupantNames.find(name =>
          policy.pursueRoleExchangeWithPlayer.includes(name)
        );
        if (roleTarget) {
          const key = `R.OFFER:${occupantKey}`;
          if (knowledge.action.exchange.lastWhisperActionKey !== key) {
            atoms.push({ kind: "whisper_action", action: "R.OFFER", label: "reactive_role_offer" });
            knowledge.action.exchange.lastWhisperActionKey = key;
          }
        } else {
          const colorTarget = knowledge.occupantNames.find(name =>
            policy.pursueColorExchangeWithPlayer.includes(name)
          );
          const key = `C.OFFER:${occupantKey}`;
          if (colorTarget && knowledge.action.exchange.lastWhisperActionKey !== key) {
            atoms.push({ kind: "whisper_action", action: "C.OFFER", label: "reactive_color_offer" });
            knowledge.action.exchange.lastWhisperActionKey = key;
          }
        }
      }

      const queuedWhisper = activePursuit ? null : popNextWhisperDraft(knowledge, knowledge.occupantNames);
      if (queuedWhisper && !has("chat")) {
        atoms.push({ kind: "chat", text: queuedWhisper.text, label: `whisper:${queuedWhisper.target ?? "any"}` });
      }
    }

    const canShout = knowledge.phase === "playing" || knowledge.phase === "leader_summit" || knowledge.phase === "hostage_select";
    if (canShout && knowledge.tick - knowledge.action.exchange.lastShoutTick > SHOUT_COOLDOWN_TICKS && !has("chat", "shout")) {
      const queuedShout = popNextShoutDraft(knowledge);
      if (queuedShout) {
        atoms.push({ kind: "chat", text: queuedShout.text, label: "shout" });
        knowledge.action.exchange.lastShoutTick = knowledge.tick;
      }
    }

    // Suppress global check during hostage_select for leaders (would break hostage execution)
    const suppressGlobalCheck = knowledge.amLeader && knowledge.phase === "hostage_select";
    if (policy.keepGlobalCheckActive
        && !suppressGlobalCheck
        && knowledge.tick - knowledge.action.lastGlobalCheckTick > Math.max(GLOBAL_CHECK_MIN_TICKS, policy.globalCheckIntervalTicks)
        && !has("input", "global_check")) {
      if (knowledge.phase === "whisper") {
        atoms.push({ kind: "input", masks: [BUTTON_RIGHT, 0, BUTTON_LEFT, 0], label: "global_check" });
      } else if (knowledge.phase === "playing" || knowledge.phase === "hostage_select" || knowledge.phase === "leader_summit") {
        atoms.push({ kind: "input", masks: [BUTTON_SELECT, 0, BUTTON_SELECT, 0], label: "global_check" });
      }
      knowledge.action.lastGlobalCheckTick = knowledge.tick;
    }

    const canUsurp = knowledge.phase === "playing" || knowledge.phase === "leader_summit" || knowledge.phase === "hostage_select";
    if (canUsurp
        && !knowledge.amLeader
        && policy.shouldUsurp
        && policy.usurpTarget
        && !has("usurp_vote")) {
      atoms.push({
        kind: "usurp_vote",
        target: policy.usurpTarget,
        label: "usurp_vote",
        startedTick: knowledge.tick,
        state: "opening",
        navCount: 0,
      });
    }
  }

  private chooseActivity(): void {
    const { knowledge } = this.config;
    const current = knowledge.action.currentActivity;
    if (current && this.activityStillValid(current)) return;
    if (current) this.finishActivity("invalidated", current.status);
    knowledge.action.currentActivity = null;

    if (knowledge.phase === "whisper" || knowledge.phase === "waiting_entry") return;
    if (knowledge.phase !== "playing" && knowledge.phase !== "leader_summit") return;

    const next = this.nextPolicyActivity(knowledge.policy.resolved);
    if (next) {
      knowledge.action.currentActivity = next;
      knowledge.action.exchange.currentTarget = next.kind === "pursue_player" ? next.target : null;
      knowledge.action.exchange.currentExchange = next.kind === "pursue_player" ? next.mode : "color";
      knowledge.action.exchange.currentExchangeMode = next.kind === "pursue_player" ? next.approach : "go_to_player";
      knowledge.action.exchange.exchangeStartTick = knowledge.tick;
      knowledge.action.exchange.exchangePhase = next.kind === "pursue_player" ? "walking" : "idle";
      this.config.logEvent("activity_started", activityLog(next));
    }
  }

  private nextPolicyActivity(policy: ResolvedPolicy): Activity | null {
    const { knowledge } = this.config;

    if (!knowledge.amLeader && policy.shouldUsurp && policy.usurpTarget && this.canPursueWhisper(policy.usurpTarget)) {
      return this.createPursuePlayer(policy.usurpTarget, "leader");
    }
    for (const target of policy.pursueRoleExchangeWithPlayer) {
      if (this.canPursueRole(target)) return this.createPursuePlayer(target, "role");
    }
    for (const target of policy.pursueColorExchangeWithPlayer) {
      if (this.canPursueColor(target)) return this.createPursuePlayer(target, "color");
    }
    if (policy.meetPoint && knowledge.tick - policy.meetPoint.tick < 300) {
      return this.createWalkTo(policy.meetPoint.x, policy.meetPoint.y, "meet_point", WALK_TIMEOUT_TICKS, true);
    }
    const nearest = this.findNearestColorTarget();
    if (nearest) return this.createPursuePlayer(nearest, "color");

    const roleProbe = this.findDefaultRoleProbeTarget();
    if (roleProbe) return this.createPursuePlayer(roleProbe, "role");

    const whisperProbe = this.findDefaultWhisperTarget();
    if (whisperProbe) return this.createPursuePlayer(whisperProbe, Math.random() < 0.25 ? "role" : "color");

    if (knowledge.myPos) {
      return this.createWalkTo(
        Math.floor(Math.random() * knowledge.matchFacts.roomW),
        Math.floor(Math.random() * knowledge.matchFacts.roomH),
        "wander",
        120,
      );
    }
    return null;
  }

  private createWalkTo(
    x: number,
    y: number,
    reason: string,
    timeLimitTicks = WALK_TIMEOUT_TICKS,
    openWhisperOnArrive = false,
  ): Activity {
    return {
      id: `a${nextActivityId++}`,
      kind: "walk_to",
      startedTick: this.config.knowledge.tick,
      lastActiveTick: this.config.knowledge.tick,
      timeLimitTicks,
      status: reason,
      x,
      y,
      openWhisperOnArrive,
      openedOnArrive: false,
    };
  }

  private createPursuePlayer(target: string, mode: "role" | "color" | "whisper" | "leader"): Activity {
    const knowledge = this.config.knowledge;
    const hint = mode === "color" || mode === "role"
      ? knowledge.policy.resolved.pursueModeHints[`${target}:${mode}`]
      : null;
    const approach = hint && knowledge.tick - hint.tick < 240 && hint.mode !== "noop"
      ? hint.mode
      : mode === "role" || mode === "leader" || Math.random() < knowledge.policy.resolved.hostPrivateSpotProbability
        ? "find_spot"
        : "go_to_player";
    return {
      id: `a${nextActivityId++}`,
      kind: "pursue_player",
      startedTick: knowledge.tick,
      lastActiveTick: knowledge.tick,
      timeLimitTicks: EXCHANGE_TIMEOUT_TICKS,
      status: `pursuing ${target} for ${mode}`,
      target,
      mode,
      approach,
      createdOwnWhisperTick: null,
      grantDeadlineTick: null,
      lastSawTargetTick: -Infinity,
      offerSentTick: null,
      conversationMessageSentTick: null,
      shoutedWrongRoom: false,
      privateSpot: null,
      privateSpotTick: -Infinity,
      privateSpotShoutTick: -Infinity,
      nearTargetWaitTick: -Infinity,
    };
  }

  private activityStillValid(activity: Activity): boolean {
    const { knowledge } = this.config;
    if (knowledge.tick - activity.startedTick > activity.timeLimitTicks) return false;
    if (activity.kind === "walk_to") return knowledge.phase === "playing" || knowledge.phase === "leader_summit";
    if (activity.mode === "role") return this.canContinueRole(activity.target) || knowledge.phase === "whisper" || knowledge.phase === "waiting_entry";
    if (activity.mode === "color") return this.canContinueColor(activity.target) || knowledge.phase === "whisper" || knowledge.phase === "waiting_entry";
    if (activity.mode === "leader") return this.canPursueWhisper(activity.target) || knowledge.phase === "whisper" || knowledge.phase === "waiting_entry";
    return true;
  }

  private canPursueColor(target: string): boolean {
    const { knowledge } = this.config;
    const pb = knowledge.players.get(target);
    if (!pb || pb.name === knowledge.myCharName) return false;
    if (pb.lastRoom !== knowledge.myRoom) return false;
    return !hasColorExchangeSucceeded(knowledge, target) && this.hasRecentPosition(target);
  }

  private canPursueRole(target: string): boolean {
    const { knowledge } = this.config;
    const pb = knowledge.players.get(target);
    if (!pb || pb.name === knowledge.myCharName) return false;
    if (pb.lastRoom !== knowledge.myRoom) return false;
    if (hasRoleExchangeSucceeded(knowledge, target)) return false;
    const partnerRole = keyPartnerRole(knowledge.myRole);
    const isPartner = partnerRole !== null && normalizeRole(pb.knownRole) === partnerRole;
    const isTeam = !!pb.knownTeam && !!knowledge.myTeam && pb.knownTeam === knowledge.myTeam;
    return isPartner || isTeam;
  }

  private canPursueWhisper(target: string): boolean {
    const { knowledge } = this.config;
    const pb = knowledge.players.get(target);
    if (!pb || pb.name === knowledge.myCharName) return false;
    if (pb.lastRoom !== knowledge.myRoom) return false;
    return this.hasRecentPosition(target);
  }

  private canContinueColor(target: string): boolean {
    const { knowledge } = this.config;
    const pb = knowledge.players.get(target);
    return !!pb && pb.lastRoom === knowledge.myRoom && !hasColorExchangeSucceeded(knowledge, target);
  }

  private canContinueRole(target: string): boolean {
    const { knowledge } = this.config;
    const pb = knowledge.players.get(target);
    return !!pb && pb.lastRoom === knowledge.myRoom && !hasRoleExchangeSucceeded(knowledge, target);
  }

  private findNearestColorTarget(): string | null {
    const { knowledge } = this.config;
    if (!knowledge.myPos) return null;
    let best: string | null = null;
    let bestDist = Infinity;
    for (const dot of knowledge.minimapDots) {
      if (dot.isSelf) continue;
      const candidate = Array.from(knowledge.players.values()).find(p => p.color === dot.color);
      if (!candidate || !this.canPursueColor(candidate.name)) continue;
      const dx = dot.worldX - knowledge.myPos.x;
      const dy = dot.worldY - knowledge.myPos.y;
      const dist = dx * dx + dy * dy;
      if (dist < bestDist) {
        best = candidate.name;
        bestDist = dist;
      }
    }
    return best;
  }

  private visibleByName(name: string): boolean {
    const color = colorFromCharName(name);
    return color !== null && this.config.knowledge.minimapDots.some(dot => dot.color === color && !dot.isSelf);
  }

  private hasRecentPosition(name: string): boolean {
    const pb = this.config.knowledge.players.get(name);
    return this.visibleByName(name) || (!!pb?.lastPos && this.config.knowledge.tick - pb.lastSeenTick <= STALE_VISIBLE_TARGET_TICKS);
  }

  private findDefaultRoleProbeTarget(): string | null {
    const { knowledge } = this.config;
    const candidates = Array.from(knowledge.players.values())
      .filter(p => p.name !== knowledge.myCharName)
      .filter(p => p.lastRoom === knowledge.myRoom)
      .filter(p => !hasRoleExchangeSucceeded(knowledge, p.name))
      .filter(p => this.hasRecentPosition(p.name));
    const teammate = candidates.find(p => p.knownTeam && knowledge.myTeam && p.knownTeam === knowledge.myTeam);
    if (teammate) return teammate.name;
    return Math.random() < 0.08 && candidates.length > 0
      ? candidates[Math.floor(Math.random() * candidates.length)].name
      : null;
  }

  private findDefaultWhisperTarget(): string | null {
    const { knowledge } = this.config;
    const candidates = Array.from(knowledge.players.values())
      .filter(p => p.name !== knowledge.myCharName)
      .filter(p => p.lastRoom === knowledge.myRoom)
      .filter(p => this.hasRecentPosition(p.name));
    return candidates.length > 0
      ? candidates[Math.floor(Math.random() * candidates.length)].name
      : null;
  }

  private shouldAcceptRoleOffer(policy: ResolvedPolicy): boolean {
    const { knowledge } = this.config;
    // Always accept role offers from confirmed teammates or key partners
    if (knowledge.occupantNames.some(name => this.canPursueRole(name))) return true;
    // Also accept if policy explicitly allows
    return policy.acceptRoleOffers;
  }

  private finishActivity(kind: string, reason: string): void {
    const activity = this.config.knowledge.action.currentActivity;
    if (!activity) return;
    this.config.logEvent("activity_finished", { ...activityLog(activity), finish: kind, reason });
    this.config.knowledge.action.exchange.currentTarget = null;
    this.config.knowledge.action.exchange.exchangePhase = "idle";
  }

  private decideIntroInput(): FrameDecision | null {
    const { knowledge, logEvent } = this.config;
    if (knowledge.phase === "info_screen") {
      return { kind: "input", mask: BUTTON_SELECT, reason: "dismiss_info_screen" };
    }
    if (knowledge.phase !== "lobby" && knowledge.phase !== "roster_reveal" && knowledge.phase !== "role_reveal") {
      return null;
    }

    if (knowledge.phase === "lobby") {
      this.introLastAdvanceTick = -Infinity;
      this.introAdvanceCount = 0;
      this.introRoleSeen = false;
      this.introScheduleSeen = false;
      return { kind: "input", mask: 0, reason: "lobby_wait" };
    }

    if (knowledge.myRole && knowledge.myTeam && knowledge.myCharName) this.introRoleSeen = true;
    if (knowledge.matchFacts.rounds.length > 0) this.introScheduleSeen = true;

    const cooledDown = knowledge.tick - this.introLastAdvanceTick > 8;
    const shouldAdvanceRoster = knowledge.phase === "roster_reveal";
    const shouldAdvanceRoleInfo = knowledge.phase === "role_reveal" && this.introAdvanceCount < 3 && this.introRoleSeen;
    const shouldConfirmLastPanel = knowledge.phase === "role_reveal" && this.introAdvanceCount >= 3 && this.introScheduleSeen;
    if (cooledDown && (shouldAdvanceRoster || shouldAdvanceRoleInfo || shouldConfirmLastPanel)) {
      this.introLastAdvanceTick = knowledge.tick;
      this.introAdvanceCount++;
      logEvent("intro_advance", {
        introAdvanceCount: this.introAdvanceCount,
        introRoleSeen: this.introRoleSeen,
        introScheduleSeen: this.introScheduleSeen,
      });
      return { kind: "input", mask: BUTTON_A, reason: "intro_advance" };
    }

    return { kind: "input", mask: 0, reason: "intro_wait" };
  }
}

function normalizeRole(role: string | null): string {
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

function activityLog(activity: Activity): Record<string, unknown> {
  if (activity.kind === "walk_to") {
    return { id: activity.id, kind: activity.kind, x: activity.x, y: activity.y, status: activity.status };
  }
  return {
    id: activity.id,
    kind: activity.kind,
    target: activity.target,
    mode: activity.mode,
    approach: activity.approach,
    status: activity.status,
  };
}

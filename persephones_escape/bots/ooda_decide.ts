import { BUTTON_A, BUTTON_SELECT, TARGET_FPS } from "../game/constants.js";
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

export interface PsychopompDecisionStatus {
  round: number;
  done: boolean;
}

export interface OodaDeciderConfig {
  knowledge: GameKnowledge;
  bot: BotController;
  psychopompStatus: () => PsychopompDecisionStatus;
  logEvent: BotLogFn;
}

const SHOUT_COOLDOWN_TICKS = 180;
const EXCHANGE_TIMEOUT_TICKS = 900;
const WALK_TIMEOUT_TICKS = 240;
const STALE_VISIBLE_TARGET_TICKS = 10 * 24;
const FALLBACK_PSYCHOPOMP_COMMIT_SECS = 3;
const FALLBACK_PSYCHOPOMP_MAX_WAIT_TICKS = 12 * 24;
const WHISPER_TIMEOUT_TICKS = 30 * TARGET_FPS;
const FAILED_TARGET_COOLDOWN_TICKS = 30 * TARGET_FPS;

function whisperAlreadyHasConversationPair(knowledge: GameKnowledge): boolean {
  return knowledge.phase === "whisper" && (knowledge.occupantCount >= 2 || knowledge.occupantNames.length >= 1);
}

let nextActivityId = 1;

export class OodaDecider {
  private introLastAdvanceTick = -Infinity;
  private introAdvanceCount = 0;
  private introRoleSeen = false;
  private introScheduleSeen = false;
  private psychopompSelectStartTick = -Infinity;
  private reactiveTelemetryTicks = new Map<string, number>();

  constructor(private config: OodaDeciderConfig) {}

  decide(observation: FrameObservation): FrameDecision {
    const introDecision = this.decideIntroInput();
    if (introDecision) return introDecision;

    const { knowledge } = this.config;
    if (knowledge.phase === "psychopomp_select" && knowledge.prevPhase !== "psychopomp_select") {
      this.psychopompSelectStartTick = knowledge.tick;
    }
    const psychopompStatus = this.config.psychopompStatus();
    const psychopompActive = this.shouldRunPsychopompSelector(psychopompStatus);
    if (psychopompActive) return { kind: "psychopomp_precommit", frame: observation.frame };

    this.enqueueReactiveAtomics();
    this.chooseActivity();
    return { kind: "run_activity", frame: observation.frame };
  }

  private shouldRunPsychopompSelector(psychopompStatus: PsychopompDecisionStatus): boolean {
    const { knowledge, bot } = this.config;
    if (!knowledge.amLeader || (bot.psychopompPrecommit?.length ?? 0) === 0) return false;
    const continuing = psychopompStatus.round === knowledge.matchFacts.currentRound && !psychopompStatus.done;
    if (continuing) return true;
    if (knowledge.phase !== "psychopomp_select") return false;

    const policyTargets = knowledge.policy.resolved.psychopompTargets?.filter(name => bot.psychopompPrecommit?.includes(name)) ?? [];
    if (policyTargets.length > 0) return true;

    const timer = knowledge.matchFacts.psychopompSelectTimerSecs;
    const timerNearlyDone = timer > 0 && timer <= FALLBACK_PSYCHOPOMP_COMMIT_SECS;
    const waitedLongEnough = this.psychopompSelectStartTick > -Infinity
      && knowledge.tick - this.psychopompSelectStartTick >= FALLBACK_PSYCHOPOMP_MAX_WAIT_TICKS;
    return timerNearlyDone || waitedLongEnough;
  }

  private enqueueReactiveAtomics(): void {
    const { knowledge, logEvent } = this.config;
    const policy = knowledge.policy.resolved;
    const atoms = knowledge.action.atomQueue;
    const has = (kind: AtomicAction["kind"], label?: string) =>
      atoms.some(a => a.kind === kind && (!label || a.label === label));

    if (knowledge.phase !== "whisper" && knowledge.phase !== "leader_summit") {
      knowledge.action.exchange.lastWhisperActionKey = null;
    }

    if (knowledge.phase === "whisper" || knowledge.phase === "leader_summit") {
      const denyEntry = knowledge.pendingEntryName !== null && policy.autoGrantDenyPlayers.includes(knowledge.pendingEntryName);
      const whisperFullForEntry = whisperAlreadyHasConversationPair(knowledge);
      const roleTarget = this.reactiveRoleOfferTarget(policy);
      const colorBlockedBy = this.reactiveColorBlockedByOccupant(policy);
      const colorOfferTarget = colorBlockedBy ? null : this.reactiveColorOfferTarget(policy);
      const colorAcceptTarget = this.reactiveColorAcceptTarget(policy);
      const visibleOfferSystems = recentOfferSystemMessages(knowledge);
      const whisperAgeTicks = knowledge.phase === "whisper" && knowledge.action.whisperStartedTick !== null
        ? knowledge.tick - knowledge.action.whisperStartedTick
        : null;
      const whisperGateDetail = {
        phase: knowledge.phase,
        whisperStartedTick: knowledge.action.whisperStartedTick,
        whisperAgeTicks,
        whisperTimeoutTicks: WHISPER_TIMEOUT_TICKS,
        occupants: knowledge.occupantNames,
        occupantCount: knowledge.occupantCount,
        pendingEntry: knowledge.pendingEntry,
        pendingEntryName: knowledge.pendingEntryName,
        pendingColorOffer: knowledge.pendingColorOffer,
        pendingRoleOffer: knowledge.pendingRoleOffer,
        pendingLeaderOffer: knowledge.pendingLeaderOffer,
        visibleOfferSystems,
        queueBefore: atomQueueSummary(atoms),
        activeActivity: activityLog(knowledge.action.currentActivity),
        activeColorOffer: knowledge.action.exchange.activeColorOffer,
        activeRoleOffer: knowledge.action.exchange.activeRoleOffer,
        lastWhisperActionKey: knowledge.action.exchange.lastWhisperActionKey,
        policy: {
          autoGrantEntry: policy.autoGrantEntry,
          autoGrantDenyPlayers: policy.autoGrantDenyPlayers,
          autoAcceptColorOffer: policy.autoAcceptColorOffer,
          autoOfferColorExchange: policy.autoOfferColorExchange,
          autoOfferColorDenyPlayers: policy.autoOfferColorDenyPlayers,
          autoOfferRoleExchange: policy.autoOfferRoleExchange,
          acceptRoleOffers: policy.acceptRoleOffers,
          acceptLeaderOffers: policy.acceptLeaderOffers,
          avoidPlayers: policy.avoidPlayers,
          pursueColorExchangeWithPlayer: policy.pursueColorExchangeWithPlayer,
          pursueRoleExchangeWithPlayer: policy.pursueRoleExchangeWithPlayer,
        },
        gates: {
          denyEntry,
          colorBlockedBy,
          colorTarget: colorOfferTarget,
          colorAcceptTarget,
          roleTarget,
          colorAcceptAllowed: policy.autoAcceptColorOffer && colorAcceptTarget !== null,
          roleAcceptAllowed: (policy.acceptRoleOffers || policy.autoOfferRoleExchange) && roleTarget !== null,
          duplicateGrant: has("whisper_action", "grant_entry"),
          whisperFullForEntry,
          duplicateAcceptColor: has("whisper_action", "accept_color"),
          duplicateAcceptRole: has("whisper_action", "accept_role"),
          hasAnyWhisperActionQueued: has("whisper_action"),
        },
        occupantsState: knowledge.occupantNames.map(name => {
          const pb = knowledge.players.get(name);
          return {
            name,
            colorSucceeded: hasColorExchangeSucceeded(knowledge, name),
            roleSucceeded: hasRoleExchangeSucceeded(knowledge, name),
            knownTeam: pb?.knownTeam ?? null,
            knownRole: pb?.knownRole ?? null,
            lastRoom: pb?.lastRoom ?? null,
            lastSeenTick: pb?.lastSeenTick ?? null,
            inWhisper: pb?.inWhisper ?? null,
          };
        }),
      };
      if (
        knowledge.pendingEntry
        || knowledge.pendingColorOffer
        || knowledge.pendingRoleOffer
        || knowledge.pendingLeaderOffer
        || visibleOfferSystems.length > 0
        || knowledge.occupantNames.length > 0
      ) {
        this.logReactiveTelemetry("whisper_gates", whisperGateDetail, knowledge.pendingColorOffer || knowledge.pendingRoleOffer ? 6 : 24);
      }

      if (knowledge.pendingColorOffer) {
        this.cancelQueuedOfferAtomics(atoms, "color");
      }
      if (knowledge.pendingRoleOffer) {
        this.cancelQueuedOfferAtomics(atoms, "role");
      }

      if (knowledge.phase === "whisper"
          && whisperAgeTicks !== null
          && whisperAgeTicks > WHISPER_TIMEOUT_TICKS
          && !has("whisper_action", "conversation_timeout_exit")) {
        atoms.push({ kind: "whisper_action", action: "EXIT", label: "conversation_timeout_exit" });
        logEvent("reactive_atomic_queued", {
          reason: "conversation_timeout_exit",
          ageTicks: whisperAgeTicks,
          timeoutTicks: WHISPER_TIMEOUT_TICKS,
          queueAfter: atomQueueSummary(atoms),
          activeActivity: activityLog(knowledge.action.currentActivity),
        });
      }

      if (policy.autoGrantEntry && knowledge.pendingEntry && !denyEntry && !whisperFullForEntry && !has("whisper_action", "grant_entry")) {
        atoms.push({ kind: "whisper_action", action: "GRANT", label: "grant_entry" });
        logEvent("reactive_atomic_queued", {
          reason: "grant_entry",
          queueAfter: atomQueueSummary(atoms),
          pendingEntryName: knowledge.pendingEntryName,
        });
      } else if (knowledge.pendingEntry) {
        this.logReactiveTelemetry("grant_entry_blocked", {
          autoGrantEntry: policy.autoGrantEntry,
          denyEntry,
          whisperFullForEntry,
          occupantCount: knowledge.occupantCount,
          occupants: knowledge.occupantNames,
          duplicateGrant: has("whisper_action", "grant_entry"),
          pendingEntryName: knowledge.pendingEntryName,
          queue: atomQueueSummary(atoms),
        }, 12);
      }

      if (policy.autoAcceptColorOffer && colorAcceptTarget !== null && knowledge.pendingColorOffer && !has("whisper_action", "accept_color")) {
        this.enqueueUrgentWhisperAction(atoms, { kind: "whisper_action", action: "C.ACCPT", label: "accept_color", target: colorAcceptTarget });
        logEvent("reactive_atomic_queued", {
          reason: "accept_color",
          target: colorAcceptTarget,
          queueAfter: atomQueueSummary(atoms),
          queuedBehind: atoms.length > 1 ? atomQueueSummary(atoms.slice(0, -1)) : [],
        });
      } else if (knowledge.pendingColorOffer || visibleOfferSystems.some(t => t.includes("COLOR"))) {
        this.logReactiveTelemetry("accept_color_blocked", {
          pendingColorOffer: knowledge.pendingColorOffer,
          visibleOfferSystems,
          autoAcceptColorOffer: policy.autoAcceptColorOffer,
          colorTarget: colorOfferTarget,
          colorAcceptTarget,
          colorBlockedBy,
          duplicateAcceptColor: has("whisper_action", "accept_color"),
          queue: atomQueueSummary(atoms),
          occupants: whisperGateDetail.occupantsState,
        }, 6);
      }

      // Accept role offers from confirmed teammates/key partners
      if ((policy.acceptRoleOffers || policy.autoOfferRoleExchange) && roleTarget !== null && knowledge.pendingRoleOffer && !has("whisper_action", "accept_role")) {
        this.enqueueUrgentWhisperAction(atoms, { kind: "whisper_action", action: "R.ACCPT", label: "accept_role", target: roleTarget });
        logEvent("reactive_atomic_queued", {
          reason: "accept_role",
          target: roleTarget,
          queueAfter: atomQueueSummary(atoms),
          queuedBehind: atoms.length > 1 ? atomQueueSummary(atoms.slice(0, -1)) : [],
        });
      } else if (knowledge.pendingRoleOffer || visibleOfferSystems.some(t => t.includes("ROLE"))) {
        this.logReactiveTelemetry("accept_role_blocked", {
          pendingRoleOffer: knowledge.pendingRoleOffer,
          visibleOfferSystems,
          acceptRoleOffers: policy.acceptRoleOffers,
          autoOfferRoleExchange: policy.autoOfferRoleExchange,
          roleTarget,
          duplicateAcceptRole: has("whisper_action", "accept_role"),
          queue: atomQueueSummary(atoms),
          occupants: whisperGateDetail.occupantsState,
        }, 6);
      }

      if (policy.acceptLeaderOffers && knowledge.pendingLeaderOffer && !has("whisper_action", "accept_leader")) {
        atoms.push({ kind: "whisper_action", action: "TAKE", label: "accept_leader" });
        logEvent("reactive_atomic_queued", {
          reason: "accept_leader",
          queueAfter: atomQueueSummary(atoms),
        });
      }

      const activePursuit = knowledge.action.currentActivity?.kind === "pursue_player"
        ? knowledge.action.currentActivity
        : null;

      if (policy.exitCurrentWhisper && !activePursuit && !has("whisper_action", "exit_policy")) {
        atoms.push({ kind: "whisper_action", action: "EXIT", label: "exit_policy" });
      } else if (policy.whisperActionNext && !activePursuit && !has("whisper_action", "policy_whisper_action")) {
        atoms.push({ kind: "whisper_action", action: policy.whisperActionNext, label: "policy_whisper_action" });
      }

      // Offer exchanges from resolved precommitments. These are intentionally
      // occupant-driven so a productive whisper can react even when the current
      // activity was aimed at a different player.
      if (!has("whisper_action")) {
        const occupantKey = knowledge.occupantNames.slice().sort().join("|");
        if (roleTarget) {
          const key = `R.OFFER:${occupantKey}`;
          if (!knowledge.pendingRoleOffer && !knowledge.action.exchange.activeRoleOffer && knowledge.action.exchange.lastWhisperActionKey !== key) {
            atoms.push({ kind: "whisper_action", action: "R.OFFER", label: "reactive_role_offer" });
            knowledge.action.exchange.lastWhisperActionKey = key;
            logEvent("reactive_atomic_queued", {
              reason: "reactive_role_offer",
              target: roleTarget,
              key,
              queueAfter: atomQueueSummary(atoms),
            });
          } else {
            this.logReactiveTelemetry("reactive_role_offer_blocked", {
              roleTarget,
              key,
              activeRoleOffer: knowledge.action.exchange.activeRoleOffer,
              lastWhisperActionKey: knowledge.action.exchange.lastWhisperActionKey,
              queue: atomQueueSummary(atoms),
            }, 24);
          }
        } else {
          const key = `C.OFFER:${occupantKey}`;
          if (!knowledge.pendingColorOffer && colorOfferTarget && !knowledge.action.exchange.activeColorOffer && knowledge.action.exchange.lastWhisperActionKey !== key) {
            atoms.push({ kind: "whisper_action", action: "C.OFFER", label: "reactive_color_offer" });
            knowledge.action.exchange.lastWhisperActionKey = key;
            logEvent("reactive_atomic_queued", {
              reason: "reactive_color_offer",
              target: colorOfferTarget,
              key,
              queueAfter: atomQueueSummary(atoms),
            });
          } else if (knowledge.occupantNames.length > 0) {
            this.logReactiveTelemetry("reactive_color_offer_blocked", {
              colorTarget: colorOfferTarget,
              colorBlockedBy,
              key,
              activeColorOffer: knowledge.action.exchange.activeColorOffer,
              lastWhisperActionKey: knowledge.action.exchange.lastWhisperActionKey,
              queue: atomQueueSummary(atoms),
              occupants: whisperGateDetail.occupantsState,
            }, 24);
          }
        }
      } else {
        this.logReactiveTelemetry("reactive_offer_waiting_for_queue", {
          queue: atomQueueSummary(atoms),
          roleTarget,
          colorTarget: colorOfferTarget,
          colorAcceptTarget,
          colorBlockedBy,
        }, 24);
      }

      const queuedWhisper = activePursuit ? null : popNextWhisperDraft(knowledge, knowledge.occupantNames);
      if (queuedWhisper && !has("chat")) {
        atoms.push({ kind: "chat", text: queuedWhisper.text, label: `whisper:${queuedWhisper.target ?? "any"}` });
        logEvent("reactive_atomic_queued", {
          reason: "whisper_draft",
          target: queuedWhisper.target,
          text: queuedWhisper.text,
          queueAfter: atomQueueSummary(atoms),
        });
      }
    }

    const canShout = knowledge.phase === "playing" || knowledge.phase === "leader_summit" || knowledge.phase === "psychopomp_select";
    if (canShout && knowledge.tick - knowledge.action.exchange.lastShoutTick > SHOUT_COOLDOWN_TICKS && !has("chat", "shout")) {
      const queuedShout = popNextShoutDraft(knowledge);
      if (queuedShout) {
        atoms.push({ kind: "chat", text: queuedShout.text, label: "shout" });
        knowledge.action.exchange.lastShoutTick = knowledge.tick;
        logEvent("reactive_atomic_queued", {
          reason: "shout_draft",
          text: queuedShout.text,
          queueAfter: atomQueueSummary(atoms),
        });
      }
    }

    // Info checks are event-driven. Successful exchanges force one check so
    // durable team/role facts catch up without periodically interrupting chat.
    const suppressGlobalCheck = knowledge.amLeader && knowledge.phase === "psychopomp_select";
    const canInfoCheck = knowledge.phase === "playing" || knowledge.phase === "whisper" || knowledge.phase === "leader_summit";
    if (policy.keepGlobalCheckActive
        && !suppressGlobalCheck
        && canInfoCheck
        && knowledge.action.forceInfoCheck
        && !has("info_check", "info_check")) {
      if (knowledge.phase === "whisper") this.cancelQueuedWhisperExits(atoms, "forced_info_check");
      this.enqueueUrgentInfoCheck(atoms, { kind: "info_check", label: "info_check", startedTick: knowledge.tick, readTicks: 2 });
      logEvent("reactive_atomic_queued", {
        reason: "info_check",
        phase: knowledge.phase,
        forced: knowledge.action.forceInfoCheck,
        queueAfter: atomQueueSummary(atoms),
      });
    }

    const canUsurp = knowledge.phase === "playing" || knowledge.phase === "leader_summit" || knowledge.phase === "psychopomp_select";
    if (canUsurp
        && !knowledge.amLeader
        && policy.shouldUsurp
        && policy.usurpTarget
        && !knowledge.action.currentActivity
        && (
          knowledge.action.lastUsurpVoteTarget !== policy.usurpTarget
          || knowledge.action.lastUsurpVoteRound !== knowledge.matchFacts.currentRound
        )
        && !has("usurp_vote")) {
      atoms.push({
        kind: "usurp_vote",
        target: policy.usurpTarget,
        label: "usurp_vote",
        startedTick: knowledge.tick,
        state: "opening",
        navCount: 0,
      });
      logEvent("reactive_atomic_queued", {
        reason: "usurp_vote",
        target: policy.usurpTarget,
        queueAfter: atomQueueSummary(atoms),
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
    if (knowledge.phase !== "playing") return;

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
    for (const target of policy.pursueColorExchangeWithPlayer) {
      if (this.canPursueColor(target)) return this.createPursuePlayer(target, "color");
    }
    for (const target of policy.pursueRoleExchangeWithPlayer) {
      if (this.canPursueRole(target)) return this.createPursuePlayer(target, "role");
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
      : mode === "role" || mode === "leader"
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
      enteredWhisperTick: null,
      waitingEntryTick: null,
      grantDeadlineTick: null,
      lastSawTargetTick: -Infinity,
      offerSentTick: null,
      conversationMessageSentTick: null,
      shoutedWrongRoom: false,
      privateSpot: null,
      privateSpotTick: -Infinity,
      privateSpotShoutTick: -Infinity,
      nearTargetWaitTick: -Infinity,
      openAttemptStartTick: null,
      openAttemptCount: 0,
      clusterEscapeStartTick: null,
    };
  }

  private activityStillValid(activity: Activity): boolean {
    const { knowledge } = this.config;
    if (knowledge.tick - activity.startedTick > activity.timeLimitTicks) return false;
    if (activity.kind === "walk_to") return knowledge.phase === "playing";
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
    const failedAt = knowledge.action.exchange.failedTargets.get(target);
    if (failedAt !== undefined && knowledge.tick - failedAt < FAILED_TARGET_COOLDOWN_TICKS) return false;
    if (this.targetIsTemporarilyBad(target)) return false;
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
    if (this.targetIsTemporarilyBad(target)) return false;
    return this.hasRecentPosition(target);
  }

  private targetIsTemporarilyBad(target: string): boolean {
    const { knowledge, logEvent } = this.config;
    const bad = knowledge.action.exchange.badPursueTargets.get(target);
    if (!bad) return false;
    const ageTicks = knowledge.tick - bad.tick;
    const cooldownTicks = badPursuitCooldownTicks(bad.reason);
    if (ageTicks >= cooldownTicks) {
      knowledge.action.exchange.badPursueTargets.delete(target);
      logEvent("target_penalty_expired", {
        target,
        reason: bad.reason,
        ageTicks,
        cooldownTicks,
      });
      return false;
    }
    return true;
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

  private reactiveRoleOfferTarget(policy: ResolvedPolicy): string | null {
    const { knowledge } = this.config;
    if (!policy.autoOfferRoleExchange && !policy.acceptRoleOffers) return null;
    const hasUnsafeOccupant = knowledge.occupantNames.some(name => !this.isRoleExchangeSafeOccupant(name));
    if (hasUnsafeOccupant) return null;
    return knowledge.occupantNames.find(name =>
      policy.pursueRoleExchangeWithPlayer.includes(name) && this.canPursueRole(name)
    ) ?? null;
  }

  private reactiveColorOfferTarget(policy: ResolvedPolicy): string | null {
    const { knowledge } = this.config;
    if (!policy.autoOfferColorExchange) return null;
    if (this.reactiveColorBlockedByOccupant(policy)) return null;
    return knowledge.occupantNames.find(name =>
      name !== knowledge.myCharName
      && policy.pursueColorExchangeWithPlayer.includes(name)
      && !hasColorExchangeSucceeded(knowledge, name)
    ) ?? null;
  }

  private reactiveColorAcceptTarget(policy: ResolvedPolicy): string | null {
    const { knowledge } = this.config;
    const deny = new Set(policy.autoOfferColorDenyPlayers);
    return knowledge.occupantNames.find(name =>
      name !== knowledge.myCharName
      && !deny.has(name)
      && !hasColorExchangeSucceeded(knowledge, name)
    ) ?? null;
  }

  private reactiveColorBlockedByOccupant(policy: ResolvedPolicy): string | null {
    const deny = new Set([...policy.autoOfferColorDenyPlayers, ...policy.avoidPlayers]);
    return this.config.knowledge.occupantNames.find(name => deny.has(name)) ?? null;
  }

  private logReactiveTelemetry(event: string, detail: Record<string, unknown>, minIntervalTicks = 24): void {
    const { knowledge, logEvent } = this.config;
    const key = `${event}:${knowledge.phase}:${knowledge.occupantNames.join("|")}:${knowledge.pendingEntry}:${knowledge.pendingEntryName ?? ""}:${knowledge.pendingColorOffer}:${knowledge.pendingRoleOffer}:${knowledge.pendingLeaderOffer}:${atomQueueSummary(knowledge.action.atomQueue).join("|")}`;
    const lastTick = this.reactiveTelemetryTicks.get(key) ?? -Infinity;
    if (knowledge.tick - lastTick < minIntervalTicks) return;
    this.reactiveTelemetryTicks.set(key, knowledge.tick);
    logEvent("reactive_telemetry", {
      event,
      tick: knowledge.tick,
      ...detail,
    });
  }

  private cancelQueuedOfferAtomics(atoms: AtomicAction[], mode: "color" | "role"): void {
    const { knowledge, logEvent } = this.config;
    const labels = mode === "color"
      ? new Set(["reactive_color_offer", "color_offer"])
      : new Set(["reactive_role_offer", "role_offer"]);
    const action = mode === "color" ? "C.OFFER" : "R.OFFER";
    const before = atomQueueSummary(atoms);
    let insertedCancel = false;
    for (let i = atoms.length - 1; i >= 0; i--) {
      const atom = atoms[i];
      const isQueuedOffer = atom.kind === "whisper_action" && atom.action === action;
      const isOfferInput = atom.kind === "input" && labels.has(atom.label);
      if (!isQueuedOffer && !isOfferInput) continue;

      if (isOfferInput && i === 0 && (atom.index ?? 0) > 0) {
        atoms.splice(i, 1, { kind: "input", masks: [BUTTON_SELECT, 0], label: `cancel_${mode}_offer_for_accept` });
        insertedCancel = true;
      } else {
        atoms.splice(i, 1);
      }
    }
    const after = atomQueueSummary(atoms);
    if (before.join("|") !== after.join("|")) {
      logEvent("reactive_offer_cancelled_for_accept", {
        mode,
        insertedCancel,
        pendingColorOffer: knowledge.pendingColorOffer,
        pendingRoleOffer: knowledge.pendingRoleOffer,
        before,
        after,
      });
    }
  }

  private enqueueUrgentWhisperAction(atoms: AtomicAction[], atom: Extract<AtomicAction, { kind: "whisper_action" }>): void {
    if (atoms.length === 0) {
      atoms.push(atom);
      return;
    }
    const first = atoms[0];
    if (first.kind === "input" && first.label.startsWith("cancel_")) {
      atoms.splice(1, 0, atom);
      return;
    }
    if (first.kind === "input" && first.label === "grant_entry") {
      atoms.splice(1, 0, atom);
      return;
    }
    if (first.kind === "info_check") {
      atoms.splice(1, 0, atom);
      return;
    }
    atoms.unshift(atom);
  }

  private enqueueUrgentInfoCheck(atoms: AtomicAction[], atom: Extract<AtomicAction, { kind: "info_check" }>): void {
    if (atoms.length === 0) {
      atoms.push(atom);
      return;
    }
    const first = atoms[0];
    if (first.kind === "input" && first.label.startsWith("cancel_")) {
      atoms.splice(1, 0, atom);
      return;
    }
    if (first.kind === "whisper_action") {
      atoms.splice(1, 0, atom);
      return;
    }
    atoms.unshift(atom);
  }

  private cancelQueuedWhisperExits(atoms: AtomicAction[], reason: string): void {
    const { knowledge, logEvent } = this.config;
    const before = atomQueueSummary(atoms);
    for (let i = atoms.length - 1; i >= 0; i--) {
      const atom = atoms[i];
      if (atom.kind === "whisper_action" && atom.action === "EXIT") atoms.splice(i, 1);
    }
    const after = atomQueueSummary(atoms);
    if (before.join("|") !== after.join("|")) {
      logEvent("reactive_exit_cancelled", {
        reason,
        before,
        after,
        occupants: knowledge.occupantNames,
        pendingColorOffer: knowledge.pendingColorOffer,
        pendingRoleOffer: knowledge.pendingRoleOffer,
        forceInfoCheck: knowledge.action.forceInfoCheck,
      });
    }
  }

  private isRoleExchangeSafeOccupant(name: string): boolean {
    const { knowledge } = this.config;
    if (hasRoleExchangeSucceeded(knowledge, name)) return true;
    const pb = knowledge.players.get(name);
    if (!pb) return false;
    const partnerRole = keyPartnerRole(knowledge.myRole);
    const isPartner = partnerRole !== null && normalizeRole(pb.knownRole) === partnerRole;
    const isTeam = !!pb.knownTeam && !!knowledge.myTeam && pb.knownTeam === knowledge.myTeam;
    return isPartner || isTeam;
  }

  private finishActivity(kind: string, reason: string): void {
    const activity = this.config.knowledge.action.currentActivity;
    if (!activity) return;
    this.config.logEvent("activity_finished", { activity: activityLog(activity), finish: kind, reason });
    this.config.knowledge.action.exchange.currentTarget = null;
    this.config.knowledge.action.exchange.exchangePhase = "idle";
  }

  private decideIntroInput(): FrameDecision | null {
    const { knowledge, logEvent } = this.config;
    if (knowledge.phase === "info_screen") {
      if (knowledge.action.atomQueue[0]?.kind === "info_check") return null;
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

function activityLog(activity: Activity | null): Record<string, unknown> | null {
  if (!activity) return null;
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

function atomQueueSummary(atoms: AtomicAction[]): string[] {
  return atoms.map(atomSummary);
}

function atomSummary(atom: AtomicAction): string {
  switch (atom.kind) {
    case "input":
      return `input:${atom.label}:${atom.index ?? 0}/${atom.masks.length}`;
    case "chat":
      return `chat:${atom.label}`;
    case "whisper_action":
      return `whisper_action:${atom.label}:${atom.action}`;
    case "info_check":
      return `info_check:${atom.label}:${atom.stage ?? "open"}:${atom.readTicks}`;
    case "usurp_vote":
      return `usurp_vote:${atom.target}:${atom.state}:${atom.navCount}`;
  }
}

function recentOfferSystemMessages(knowledge: GameKnowledge): string[] {
  return knowledge.whisperMessages
    .filter(m => m.type === "system")
    .map(m => m.text.toUpperCase())
    .filter(text => text.includes("OFFER") || text.includes("XCHG") || text.includes("ACCEPT"))
    .slice(-5);
}

function badPursuitCooldownTicks(reason: string): number {
  switch (reason) {
    case "target_seen_in_crowd":
      return 8 * TARGET_FPS;
    case "target_already_in_conversation":
    case "nearby_whisper_blocked_host":
      return 10 * TARGET_FPS;
    case "waiting_entry_timeout":
    case "open_attempt_timeout":
      return 12 * TARGET_FPS;
    default:
      return 15 * TARGET_FPS;
  }
}

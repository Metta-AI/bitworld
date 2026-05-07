import type WebSocket from "ws";
import {
  BUBBLE_RADIUS,
  BUTTON_A,
  BUTTON_B,
  BUTTON_LEFT,
  BUTTON_RIGHT,
  BUTTON_SELECT,
  TARGET_FPS,
  characterName,
} from "../game/constants.js";
import type { BotController } from "./bot_common.js";
import { moveToward, sendChat, sendInput, truncateChatInput, type Point } from "./bot_utils.js";
import {
  colorFromCharName,
  hasColorExchangeSucceeded,
  hasRoleExchangeSucceeded,
  markColorExchangeSucceeded,
  markRoleExchangeSucceeded,
  popNextWhisperDraft,
  type GameKnowledge,
} from "./game_knowledge.js";
import {
  matchRoster,
  parsePsychopompGrid,
  parseUsurpCandidate,
  type MinimapDot,
} from "./frame_parser.js";
import type { Activity, AtomicAction, BotLogFn, FrameDecision, PursuePlayerActivity } from "./ooda_types.js";
import type { PsychopompDecisionStatus } from "./ooda_decide.js";
import {
  navigateUiToward,
  parseUiState,
  type ParsedUiState,
  type UiNavigationState,
  type UiTarget,
  type WhisperAction,
} from "./ui_state.js";

export interface OodaActuatorConfig {
  ws: WebSocket;
  knowledge: GameKnowledge;
  bot: BotController;
  botName: string;
  logEvent: BotLogFn;
}

const ALONE_WHISPER_MIN_TICKS = 8 * 24;
const ALONE_WHISPER_JITTER_TICKS = 16 * 24;
const ALONE_WHISPER_SHOUT_INTERVAL_TICKS = 5 * 24;
const OFFER_WAIT_TICKS = 20 * 24;
const FIND_SPOT_NO_ACK_BAIL_TICKS = 6 * 24;
const CONVERSATION_WAIT_TICKS = 8 * 24;
const CONVERSATION_TIMEOUT_TICKS = 30 * TARGET_FPS;
const WAITING_ENTRY_TIMEOUT_TICKS = 5 * TARGET_FPS;
const TARGET_INTERACT_RADIUS = Math.max(12, BUBBLE_RADIUS - 4);
const TARGET_INTERACT_RADIUS_SQ = TARGET_INTERACT_RADIUS * TARGET_INTERACT_RADIUS;
const CLOSE_APPROACH_RADIUS = 30;
const CLOSE_APPROACH_RADIUS_SQ = CLOSE_APPROACH_RADIUS * CLOSE_APPROACH_RADIUS;
const TARGET_APPROACH_DEADZONE = 6;
const FAILED_TARGET_COOLDOWN_TICKS = 30 * TARGET_FPS;
const OPEN_ATTEMPT_TIMEOUT_TICKS = Math.floor(2.5 * TARGET_FPS);
const CLUSTER_ESCAPE_TICKS = 3 * TARGET_FPS;
const CROWDED_TARGET_MIN_NEIGHBORS = 3;
const WAIT_FOR_TARGET_HOST_TICKS = 18;

type StepResult = "emitted" | "done" | "failed" | "skip";

function whisperAlreadyHasConversationPair(knowledge: GameKnowledge): boolean {
  return knowledge.phase === "whisper" && (knowledge.occupantCount >= 2 || knowledge.occupantNames.length >= 1);
}

export class OodaActuator {
  private psychopompState: "opening" | "selecting" | "done" = "opening";
  private psychopompRound = -1;
  private psychopompGridLogged = false;
  private psychopompReleaseNext = false;
  private activityTelemetryTicks = new Map<string, number>();
  private lastAtomicTelemetryKey: string | null = null;

  constructor(private config: OodaActuatorConfig) {}

  psychopompStatus(): PsychopompDecisionStatus {
    return { round: this.psychopompRound, done: this.psychopompState === "done" };
  }

  act(decision: FrameDecision): void {
    const { ws, knowledge } = this.config;
    switch (decision.kind) {
      case "input":
        sendInput(ws, decision.mask);
        return;
      case "psychopomp_precommit":
        this.executePsychopompPrecommit(decision.frame);
        return;
      case "run_activity":
        if (this.processAtomic(decision.frame)) return;
        if (knowledge.action.currentActivity) {
          const result = this.advanceActivity(knowledge.action.currentActivity);
          if (result === "done" || result === "failed") {
            this.finishActivity(result, knowledge.action.currentActivity.status);
          }
          if (this.processAtomic(decision.frame)) return;
        }
        sendInput(ws, 0);
        return;
    }
  }

  private processAtomic(frame: Uint8Array): boolean {
    const atom = this.config.knowledge.action.atomQueue[0];
    if (!atom) {
      this.lastAtomicTelemetryKey = null;
      return false;
    }

    const atomicKey = atomSummary(atom);
    if (atomicKey !== this.lastAtomicTelemetryKey) {
      this.lastAtomicTelemetryKey = atomicKey;
      this.config.logEvent("atomic_started", {
        atom: atomicKey,
        queue: atomQueueSummary(this.config.knowledge.action.atomQueue),
        phase: this.config.knowledge.phase,
        occupants: this.config.knowledge.occupantNames,
        pendingEntry: this.config.knowledge.pendingEntry,
        pendingEntryName: this.config.knowledge.pendingEntryName,
        pendingColorOffer: this.config.knowledge.pendingColorOffer,
        pendingRoleOffer: this.config.knowledge.pendingRoleOffer,
        activeActivity: activityTelemetrySummary(this.config.knowledge.action.currentActivity),
        activeColorOffer: this.config.knowledge.action.exchange.activeColorOffer,
        activeRoleOffer: this.config.knowledge.action.exchange.activeRoleOffer,
      });
    }

    const result = this.advanceAtomic(atom, frame);
    if (result === "done" || result === "failed") {
      this.config.logEvent("atomic_finished", {
        atomicKind: atom.kind,
        label: atom.label,
        result,
        queueBeforeShift: atomQueueSummary(this.config.knowledge.action.atomQueue),
        phase: this.config.knowledge.phase,
        occupants: this.config.knowledge.occupantNames,
        pendingColorOffer: this.config.knowledge.pendingColorOffer,
        pendingRoleOffer: this.config.knowledge.pendingRoleOffer,
      });
      this.config.knowledge.action.atomQueue.shift();
      this.lastAtomicTelemetryKey = null;
    }
    return result === "emitted" || result === "done" || result === "failed";
  }

  private advanceAtomic(atom: AtomicAction, frame: Uint8Array): StepResult {
    const { ws, knowledge } = this.config;
    switch (atom.kind) {
      case "input": {
        const idx = atom.index ?? 0;
        const mask = atom.masks[idx] ?? 0;
        atom.index = idx + 1;
        sendInput(ws, mask);
        return atom.index >= atom.masks.length ? "done" : "emitted";
      }
      case "chat": {
        const { sent } = truncateChatInput(atom.text);
        if (sent !== knowledge.action.lastSentChat || knowledge.action.hasNewIncomingChat) {
          sendChat(ws, sent);
          knowledge.action.lastSentChat = sent;
          knowledge.action.hasNewIncomingChat = false;
        }
        sendInput(ws, 0);
        return "done";
      }
      case "whisper_action":
        return this.advanceWhisperActionAtomic(atom, frame);
      case "info_check":
        return this.advanceInfoCheckAtomic(atom, frame);
      case "usurp_vote":
        return this.advanceUsurpAtomic(atom, frame);
    }
  }

  private advanceInfoCheckAtomic(atom: Extract<AtomicAction, { kind: "info_check" }>, frame: Uint8Array): StepResult {
    const { ws, knowledge } = this.config;
    atom.stage ??= "open";
    atom.ui ??= {};
    if (!atom.originSurface || atom.originSurface === "other") {
      atom.originSurface = infoCheckOriginSurface(parseUiState(frame));
    }

    if (knowledge.tick - atom.startedTick > 120) {
      this.config.logEvent("info_check_failed", {
        reason: "timeout",
        stage: atom.stage,
        phase: knowledge.phase,
        originSurface: atom.originSurface,
      });
      sendInput(ws, BUTTON_SELECT);
      return "failed";
    }

    if (atom.stage === "release_done") {
      sendInput(ws, 0);
      return "done";
    }

    if (atom.stage === "open") {
      const ensured = this.ensureUiState(frame, { kind: "info_screen" }, atom.ui, atom);
      if (ensured !== "ready") return ensured;
      atom.stage = "read";
      atom.readTicks = Math.max(atom.readTicks, 2);
      atom.ui.releaseNext = false;
      this.config.logEvent("info_check_reading", {
        phase: knowledge.phase,
        originSurface: atom.originSurface,
        lastInfoUpdatedTick: knowledge.action.lastInfoUpdatedTick,
      });
      sendInput(ws, 0);
      return "emitted";
    }

    if (atom.stage === "read") {
      if (atom.readTicks > 0) {
        atom.readTicks--;
        sendInput(ws, 0);
        return "emitted";
      }
      atom.stage = "close";
      atom.ui.releaseNext = false;
    }

    const closeTarget = infoCheckReturnTarget(atom.originSurface);
    const ensured = this.ensureUiState(frame, closeTarget, atom.ui, atom);
    if (ensured !== "ready") return ensured;
    atom.stage = "release_done";
    atom.ui.releaseNext = false;
    knowledge.action.lastInfoCheckTick = knowledge.tick;
    knowledge.action.lastGlobalCheckTick = knowledge.tick;
    knowledge.action.forceInfoCheck = false;
    this.config.logEvent("info_check_finished", {
      lastInfoUpdatedTick: knowledge.action.lastInfoUpdatedTick,
      phase: knowledge.phase,
      originSurface: atom.originSurface,
      returnTarget: closeTarget.kind,
    });
    sendInput(ws, 0);
    return "emitted";
  }

  private advanceWhisperActionAtomic(atom: Extract<AtomicAction, { kind: "whisper_action" }>, frame: Uint8Array): StepResult {
    const { ws, knowledge } = this.config;
    if (knowledge.phase !== "whisper" && knowledge.phase !== "leader_summit") {
      this.config.logEvent("whisper_action_failed", {
        reason: "wrong_phase",
        action: atom.action,
        label: atom.label,
        phase: knowledge.phase,
      });
      return "failed";
    }
    if (atom.action === "C.OFFER" && knowledge.action.exchange.activeColorOffer) {
      this.config.logEvent("whisper_action_failed", {
        reason: "active_color_offer",
        action: atom.action,
        label: atom.label,
        occupants: knowledge.occupantNames,
      });
      return "failed";
    }
    if (atom.action === "R.OFFER" && knowledge.action.exchange.activeRoleOffer) {
      this.config.logEvent("whisper_action_failed", {
        reason: "active_role_offer",
        action: atom.action,
        label: atom.label,
        occupants: knowledge.occupantNames,
      });
      return "failed";
    }
    if (atom.action === "GRANT" && whisperAlreadyHasConversationPair(knowledge)) {
      this.config.logEvent("whisper_action_failed", {
        reason: "whisper_full_for_entry",
        action: atom.action,
        label: atom.label,
        occupantCount: knowledge.occupantCount,
        occupants: knowledge.occupantNames,
        pendingEntryName: knowledge.pendingEntryName,
      });
      return "failed";
    }

    atom.stage ??= "menu";
    atom.ui ??= {};

    if (atom.stage === "release_done") {
      sendInput(ws, 0);
      return "done";
    }

    if (atom.stage === "share_picker") {
      const mode = atom.action === "C.ACCPT" ? "color" : "card";
      const ensured = this.ensureUiState(frame, { kind: "whisper_share_picker", mode }, atom.ui, atom);
      if (ensured !== "ready") return ensured;
      this.applyWhisperActionBookkeeping(atom);
      atom.stage = "release_done";
      atom.ui.releaseNext = false;
      this.config.logEvent("whisper_action_selected", {
        action: atom.action,
        label: atom.label,
        stage: "share_picker",
        occupants: knowledge.occupantNames,
      });
      sendInput(ws, BUTTON_A);
      return "emitted";
    }

    const ensured = this.ensureUiState(frame, { kind: "whisper_menu_action", action: atom.action }, atom.ui, atom);
    if (ensured !== "ready") return ensured;

    this.config.logEvent("whisper_action_selected", {
      action: atom.action,
      label: atom.label,
      stage: "menu",
      occupants: knowledge.occupantNames,
      pendingColorOffer: knowledge.pendingColorOffer,
      pendingRoleOffer: knowledge.pendingRoleOffer,
      activeColorOffer: knowledge.action.exchange.activeColorOffer,
      activeRoleOffer: knowledge.action.exchange.activeRoleOffer,
    });

    if (atom.action === "C.ACCPT" || atom.action === "R.ACCPT") {
      atom.stage = "share_picker";
    } else {
      this.applyWhisperActionBookkeeping(atom);
      atom.stage = "release_done";
    }
    atom.ui.releaseNext = true;
    sendInput(ws, BUTTON_A);
    return "emitted";
  }

  private ensureUiState(
    frame: Uint8Array,
    target: UiTarget,
    nav: UiNavigationState,
    atom: Extract<AtomicAction, { kind: "whisper_action" | "info_check" }>,
  ): "ready" | StepResult {
    const { ws } = this.config;
    const state = parseUiState(frame);
    nav.attempts = (nav.attempts ?? 0) + 1;
    if (nav.attempts > 120) {
      this.config.logEvent("ui_navigation_failed", {
        target,
        action: atom.kind === "whisper_action" ? atom.action : "info_check",
        label: atom.label,
        state: uiStateLog(state),
      });
      sendInput(ws, BUTTON_SELECT);
      return "failed";
    }

    if (nav.releaseNext) {
      nav.releaseNext = false;
      this.config.logEvent("ui_navigation_step", {
        action: atom.kind === "whisper_action" ? atom.action : "info_check",
        label: atom.label,
        target,
        state: uiStateLog(state),
        reason: "release",
        mask: 0,
      });
      sendInput(ws, 0);
      return "emitted";
    }

    const step = navigateUiToward(state, target);
    if (step.ready) return "ready";

    this.config.logEvent("ui_navigation_step", {
      action: atom.kind === "whisper_action" ? atom.action : "info_check",
      label: atom.label,
      target,
      state: uiStateLog(step.state),
      reason: step.reason,
      mask: step.mask,
    });
    nav.releaseNext = step.mask !== 0;
    sendInput(ws, step.mask);
    return "emitted";
  }

  private applyWhisperActionBookkeeping(atom: Extract<AtomicAction, { kind: "whisper_action" }>): void {
    const { knowledge } = this.config;
    const action = atom.action;
    if (action === "C.ACCPT") {
      const target = atom.target
        ?? (knowledge.occupantNames.length === 1 ? knowledge.occupantNames[0] : null);
      if (target) markColorExchangeSucceeded(knowledge, target, "atomic_accept");
      knowledge.action.exchange.activeColorOffer = false;
      knowledge.action.exchange.roleFollowupUntilTick = Math.max(knowledge.action.exchange.roleFollowupUntilTick, knowledge.tick + 20 * TARGET_FPS);
      knowledge.action.lastGlobalCheckTick = -Infinity;
      knowledge.action.forceInfoCheck = true;
      knowledge.action.lastInfoCheckTick = -Infinity;
    } else if (action === "R.ACCPT") {
      const target = atom.target
        ?? (knowledge.action.currentActivity?.kind === "pursue_player"
          ? knowledge.action.currentActivity.target
          : knowledge.occupantNames.length === 1 ? knowledge.occupantNames[0] : null);
      if (target) markRoleExchangeSucceeded(knowledge, target, "atomic_accept");
      knowledge.action.exchange.activeRoleOffer = false;
    } else if (action === "C.OFFER") {
      knowledge.action.exchange.activeColorOffer = true;
    } else if (action === "C.UNOFFR") {
      knowledge.action.exchange.activeColorOffer = false;
    } else if (action === "R.OFFER") {
      knowledge.action.exchange.activeRoleOffer = true;
    } else if (action === "R.UNOFFR") {
      knowledge.action.exchange.activeRoleOffer = false;
    }
  }

  private advanceUsurpAtomic(atom: Extract<AtomicAction, { kind: "usurp_vote" }>, frame: Uint8Array): StepResult {
    const { ws, knowledge } = this.config;
    if (knowledge.tick - atom.startedTick > 120) {
      sendInput(ws, BUTTON_SELECT);
      return "failed";
    }
    if (knowledge.amLeader) return "failed";

    if (atom.state === "opening") {
      atom.state = "navigating";
      sendInput(ws, BUTTON_SELECT);
      return "emitted";
    }

    if (atom.state === "navigating") {
      const candidate = parseUsurpCandidate(frame);
      if (!candidate) {
        sendInput(ws, 0);
        return "emitted";
      }
      const targetColor = colorFromCharName(atom.target);
      const selfTarget = atom.target === knowledge.myCharName;
      if ((candidate.isSelf && selfTarget) || (candidate.isPlayer && targetColor !== null && candidate.color === targetColor)) {
        atom.state = "closing";
        sendInput(ws, BUTTON_A);
        return "emitted";
      }
      if (atom.navCount > 14) {
        atom.state = "closing";
        sendInput(ws, BUTTON_SELECT);
        return "emitted";
      }
      atom.navCount++;
      sendInput(ws, BUTTON_B);
      return "emitted";
    }

    knowledge.action.lastUsurpVoteTarget = atom.target;
    knowledge.action.lastUsurpVoteRound = knowledge.matchFacts.currentRound;
    sendInput(ws, BUTTON_SELECT);
    return "done";
  }

  private advanceActivity(activity: Activity): StepResult {
    if (this.config.knowledge.tick - activity.startedTick > activity.timeLimitTicks) return "failed";
    if (this.config.knowledge.action.atomQueue.length > 0) {
      this.logActivityBlockedByAtoms(activity);
      return "emitted";
    }
    activity.lastActiveTick = this.config.knowledge.tick;
    switch (activity.kind) {
      case "walk_to":
        return this.advanceWalkTo(activity.x, activity.y, activity);
      case "pursue_player":
        return this.advancePursuePlayer(activity);
    }
  }

  private advanceWalkTo(x: number, y: number, activity: Activity): StepResult {
    const { knowledge } = this.config;
    if (knowledge.phase !== "playing" || !knowledge.myPos) return "skip";
    const d = distSq(knowledge.myPos, { x, y });
    if (d <= 64) {
      if (activity.kind === "walk_to" && activity.openWhisperOnArrive && !activity.openedOnArrive) {
        activity.openedOnArrive = true;
        activity.status = `opening whisper at ${x},${y}`;
        this.enqueueInput([BUTTON_A], "walk_open_whisper");
        return "emitted";
      }
      return "done";
    }
    activity.status = `walking to ${x},${y}`;
    this.enqueueInput([moveToward(knowledge.myPos.x, knowledge.myPos.y, x, y) || 0], "walk_to");
    return "emitted";
  }

  private advancePursuePlayer(activity: PursuePlayerActivity): StepResult {
    const { knowledge } = this.config;
    const targetBelief = knowledge.players.get(activity.target);

    if (knowledge.phase === "waiting_entry") {
      activity.waitingEntryTick ??= knowledge.tick;
      activity.createdOwnWhisperTick = null;
      activity.enteredWhisperTick = null;
      activity.grantDeadlineTick = null;
      const waitingTicks = knowledge.tick - activity.waitingEntryTick;
      activity.status = "waiting for entry";
      this.logPursue(activity, "waiting_entry", {
        waitingTicks,
        timeoutTicks: WAITING_ENTRY_TIMEOUT_TICKS,
        targetLastRoom: targetBelief?.lastRoom ?? null,
        targetInWhisper: targetBelief?.inWhisper ?? false,
        nearbyNames: knowledge.nearbyNames,
      });
      if (waitingTicks > WAITING_ENTRY_TIMEOUT_TICKS) {
        activity.status = `entry wait timed out after ${Math.round(waitingTicks / TARGET_FPS)}s`;
        this.markBadPursueTarget(activity.target, "waiting_entry_timeout");
        this.logPursue(activity, "waiting_entry_timeout_cancel", {
          waitingTicks,
          timeoutTicks: WAITING_ENTRY_TIMEOUT_TICKS,
          targetInWhisper: targetBelief?.inWhisper ?? false,
        }, 1);
        this.enqueueInput([BUTTON_B, 0], "pursue_cancel_waiting_entry");
        return "failed";
      }
      this.enqueueInput([0], "pursue_waiting_entry");
      return "emitted";
    }

    if (knowledge.phase === "leader_summit") {
      activity.status = "leader summit interrupted pursue";
      this.logPursue(activity, "leader_summit_interrupt", {
        target: activity.target,
        mode: activity.mode,
        occupants: knowledge.occupantNames,
      }, 120);
      return "done";
    }

    if (knowledge.phase === "whisper") {
      return this.advancePursueInWhisper(activity);
    }

    activity.enteredWhisperTick = null;
    activity.waitingEntryTick = null;
    if (knowledge.phase !== "playing" || !knowledge.myPos) {
      this.logPursue(activity, "not_in_movable_state", { myPos: knowledge.myPos });
      return "skip";
    }
    if (!targetBelief || targetBelief.lastRoom !== knowledge.myRoom) {
      activity.status = `${activity.target} is not in current room`;
      this.logPursue(activity, "target_not_in_room", {
        targetKnown: !!targetBelief,
        targetRoom: targetBelief?.lastRoom ?? null,
        myRoom: knowledge.myRoom,
      }, 120);
      return "failed";
    }

    const targetDot = findTargetDot(knowledge, activity.target);
    if (targetDot) activity.lastSawTargetTick = knowledge.tick;

    if (shouldRequestTargetWhisper(knowledge, activity.target)) {
      activity.status = `requesting entry to ${activity.target}`;
      this.logPursue(activity, "requesting_entry", {
        targetInWhisper: targetBelief.inWhisper,
        nearbyNames: knowledge.nearbyNames,
      });
      this.enqueueInput([BUTTON_B], "request_target_whisper");
      return "emitted";
    }

    if (targetBelief.inWhisper) {
      activity.status = `${activity.target} already in conversation`;
      this.markBadPursueTarget(activity.target, "target_already_in_conversation");
      this.logPursue(activity, "target_already_in_conversation_retarget", {
        targetInWhisper: targetBelief.inWhisper,
        targetLastRoom: targetBelief.lastRoom,
        nearbyNames: knowledge.nearbyNames,
      }, 1);
      return "failed";
    }

    if (activity.approach === "find_spot") {
      return this.advanceFindSpot(activity, targetDot);
    }

    if (!targetDot) {
      const targetPos = targetBelief.lastPos;
      const targetPosAge = knowledge.tick - targetBelief.lastSeenTick;
      if (targetPos && targetPosAge <= 10 * TARGET_FPS) {
        const dist = distSq(knowledge.myPos, targetPos);
        const mask = dist > CLOSE_APPROACH_RADIUS_SQ
          ? moveToward(knowledge.myPos.x, knowledge.myPos.y, targetPos.x, targetPos.y, TARGET_APPROACH_DEADZONE) || 0
          : 0;
        activity.status = `walking to last known ${activity.target}`;
        this.logPursue(activity, "walking_to_last_known_target", {
          distSq: Math.round(dist),
          targetPos,
          targetPosAge,
          visibleDots: knowledge.minimapDots.length,
        }, 48);
        this.enqueueInput(mask ? [mask] : [0], "pursue_walk_to_last_known_target");
        return "emitted";
      }
      activity.status = `${activity.target} not visible`;
      this.logPursue(activity, "target_not_visible_wait", {
        lastSeenTick: targetBelief.lastSeenTick,
        lastPos: targetBelief.lastPos,
        targetPosAge,
        visibleDots: knowledge.minimapDots.length,
      }, 48);
      this.enqueueInput([0], "pursue_target_not_visible");
      return "emitted";
    }

    const dist = distSq(knowledge.myPos, { x: targetDot.worldX, y: targetDot.worldY });
    if (dist > TARGET_INTERACT_RADIUS_SQ) {
      activity.status = `walking to ${activity.target}`;
      this.logPursue(activity, "walking_to_target", {
        distSq: Math.round(dist),
        myPos: knowledge.myPos,
        targetPos: { x: targetDot.worldX, y: targetDot.worldY },
      }, 48);
      const mask = moveToward(knowledge.myPos.x, knowledge.myPos.y, targetDot.worldX, targetDot.worldY, TARGET_APPROACH_DEADZONE) || 0;
      this.enqueueInput(dist <= CLOSE_APPROACH_RADIUS_SQ ? [mask, 0, 0] : [mask], "pursue_walk_to_target");
      return "emitted";
    }

    if (targetBelief && !targetBelief.inWhisper && knowledge.myCharName && knowledge.myCharName > activity.target) {
      if (activity.nearTargetWaitTick === -Infinity) activity.nearTargetWaitTick = knowledge.tick;
      if (knowledge.tick - activity.nearTargetWaitTick < WAIT_FOR_TARGET_HOST_TICKS) {
        activity.status = `waiting for ${activity.target} to host`;
        this.logPursue(activity, "waiting_for_target_to_host", {
          waitTicks: knowledge.tick - activity.nearTargetWaitTick,
          waitLimitTicks: WAIT_FOR_TARGET_HOST_TICKS,
          myName: knowledge.myCharName,
          targetName: activity.target,
        }, 24);
        this.enqueueInput([0], "pursue_wait_for_host");
        return "emitted";
      }
    }

    const nearbyWhisperNames = nearbyPlayersInWhispers(knowledge).filter(name => name !== activity.target);
    const crowdedTargetNames = targetDot ? crowdedNamesNearTarget(knowledge, activity.target, targetDot) : [];
    const openAttemptTicks = activity.openAttemptStartTick === null ? 0 : knowledge.tick - activity.openAttemptStartTick;
    if (crowdedTargetNames.length >= CROWDED_TARGET_MIN_NEIGHBORS) {
      activity.status = `${activity.target} is crowded`;
      this.markBadPursueTarget(activity.target, "target_seen_in_crowd");
      this.logPursue(activity, "target_seen_in_crowd_retarget", {
        crowdedTargetNames,
        nearbyNames: knowledge.nearbyNames,
        nearbyWhisperNames,
      }, 1);
      return "failed";
    }

    if (nearbyWhisperNames.length > 0) {
      if (activity.clusterEscapeStartTick === null) activity.clusterEscapeStartTick = knowledge.tick;
      const escapeTicks = knowledge.tick - activity.clusterEscapeStartTick;
      if (escapeTicks <= CLUSTER_ESCAPE_TICKS) {
        const mask = moveAwayFromPlayers(knowledge, nearbyWhisperNames);
        activity.status = `escaping whisper crowd near ${activity.target}`;
        this.logPursue(activity, "host_blocked_by_nearby_whisper_escape", {
          nearbyWhisperNames,
          crowdedTargetNames,
          escapeTicks,
          openAttemptTicks,
          openAttemptCount: activity.openAttemptCount,
          mask,
        }, 12);
        this.enqueueInput(mask ? [mask, 0] : [0], "pursue_escape_nearby_whisper");
        return "emitted";
      }
      activity.status = `${activity.target} blocked by nearby whisper`;
      this.markBadPursueTarget(activity.target, "nearby_whisper_blocked_host");
      this.logPursue(activity, "host_blocked_by_nearby_whisper_retarget", {
        nearbyWhisperNames,
        crowdedTargetNames,
        escapeTicks,
        openAttemptTicks,
        openAttemptCount: activity.openAttemptCount,
      }, 1);
      return "failed";
    }

    activity.clusterEscapeStartTick = null;
    if (activity.openAttemptStartTick === null) activity.openAttemptStartTick = knowledge.tick;
    activity.openAttemptCount++;
    const currentOpenAttemptTicks = knowledge.tick - activity.openAttemptStartTick;
    if (currentOpenAttemptTicks > OPEN_ATTEMPT_TIMEOUT_TICKS) {
      activity.status = `${activity.target} open attempt timed out`;
      this.markBadPursueTarget(activity.target, "open_attempt_timeout");
      this.logPursue(activity, "open_attempt_timeout_retarget", {
        nearbyNames: knowledge.nearbyNames,
        nearbyWhisperNames,
        crowdedTargetNames,
        openAttemptTicks: currentOpenAttemptTicks,
        openAttemptCount: activity.openAttemptCount,
      }, 1);
      return "failed";
    }

    activity.status = `opening whisper with ${activity.target}`;
    if (activity.createdOwnWhisperTick === null) {
      activity.createdOwnWhisperTick = knowledge.tick;
      activity.grantDeadlineTick = randomGrantDeadline(knowledge.tick);
    }
    this.logPursue(activity, "opening_own_whisper", {
      grantDeadlineTick: activity.grantDeadlineTick,
      nearbyNames: knowledge.nearbyNames,
      nearbyWhisperNames,
      crowdedTargetNames,
      openAttemptTicks: currentOpenAttemptTicks,
      openAttemptCount: activity.openAttemptCount,
    }, 24);
    this.enqueueInput([BUTTON_A], "pursue_open_whisper");
    return "emitted";
  }

  private advanceFindSpot(activity: PursuePlayerActivity, targetDot?: MinimapDot): StepResult {
    const { knowledge } = this.config;
    if (!knowledge.myPos) return "skip";
    if (knowledge.nearbyNames.length > 1) {
      activity.privateSpot = choosePrivateSpot(knowledge, targetDot);
      activity.privateSpotTick = knowledge.tick;
      activity.status = "relocating to private spot";
      this.logPursue(activity, "private_spot_retarget_crowded", {
        nearbyNames: knowledge.nearbyNames,
        privateSpot: activity.privateSpot,
      }, 24);
      const mask = activity.privateSpot
        ? moveToward(knowledge.myPos.x, knowledge.myPos.y, activity.privateSpot.x, activity.privateSpot.y) || 0
        : 0;
      this.enqueueInput([mask], "private_spot_retarget");
      return "emitted";
    }
    const currentSpotPrivate = activity.privateSpot ? pointIsPrivate(knowledge, activity.privateSpot, activity.target) : false;
    if (!activity.privateSpot || !currentSpotPrivate || knowledge.tick - activity.privateSpotTick > 180) {
      const previousSpot = activity.privateSpot;
      activity.privateSpot = choosePrivateSpot(knowledge, targetDot);
      activity.privateSpotTick = knowledge.tick;
      this.logPursue(activity, "private_spot_selected", {
        previousSpot,
        privateSpot: activity.privateSpot,
        currentSpotPrivate,
        targetVisible: !!targetDot,
      }, 48);
    }
    if (!activity.privateSpot) return "skip";
    const spotDist = distSq(knowledge.myPos, activity.privateSpot);
    if (spotDist > 100) {
      activity.status = `finding private spot for ${activity.target}`;
      this.logPursue(activity, "walking_to_private_spot", {
        distSq: Math.round(spotDist),
        myPos: knowledge.myPos,
        privateSpot: activity.privateSpot,
      }, 48);
      this.enqueueInput([moveToward(knowledge.myPos.x, knowledge.myPos.y, activity.privateSpot.x, activity.privateSpot.y) || 0], "private_spot_walk");
      return "emitted";
    }
    if (knowledge.tick - activity.privateSpotShoutTick > 180) {
      activity.privateSpotShoutTick = knowledge.tick;
      const msg = inviteText(knowledge, activity.target);
      if (msg) knowledge.action.atomQueue.push({ kind: "chat", text: msg, label: "private_spot_invite" });
      activity.status = `advertising private spot to ${activity.target}`;
      this.logPursue(activity, "private_spot_invite", {
        text: msg,
        privateSpot: activity.privateSpot,
      }, 1);
      return "emitted";
    }

    // Check if our rendezvous offer has been acknowledged
    const acked = hasRendezvousAck(knowledge, activity.target, activity.privateSpot);
    const waitingSinceShout = activity.privateSpotShoutTick > 0
      ? knowledge.tick - activity.privateSpotShoutTick
      : knowledge.tick - activity.startedTick;

    // Without ack, bail after timeout to try a different approach
    if (!acked && waitingSinceShout > FIND_SPOT_NO_ACK_BAIL_TICKS) {
      activity.status = "no ack, bailing from find_spot";
      this.logPursue(activity, "private_spot_no_ack_bail", {
        waitingSinceShout,
        privateSpot: activity.privateSpot,
      }, 120);
      return "failed";
    }

    activity.status = acked
      ? `waiting for acked ${activity.target}`
      : `creating private whisper for ${activity.target}`;
    if (activity.createdOwnWhisperTick === null || knowledge.tick - activity.createdOwnWhisperTick > 30) {
      activity.createdOwnWhisperTick = knowledge.tick;
      activity.grantDeadlineTick = randomGrantDeadline(knowledge.tick);
    }
    this.logPursue(activity, "private_spot_opening_whisper", {
      acked,
      waitingSinceShout,
      privateSpot: activity.privateSpot,
      grantDeadlineTick: activity.grantDeadlineTick,
    }, 24);
    this.enqueueInput([BUTTON_A], "private_spot_open_whisper");
    return "emitted";
  }

  private advancePursueInWhisper(activity: PursuePlayerActivity): StepResult {
    const { knowledge } = this.config;
    const wantRole = activity.mode === "role";
    const wantWhisperOnly = activity.mode === "whisper" || activity.mode === "leader";
    const targetHere = knowledge.occupantNames.includes(activity.target);
    const occCount = knowledge.occupantCount;
    activity.enteredWhisperTick ??= knowledge.tick;
    activity.waitingEntryTick = null;
    const conversationAgeTicks = knowledge.tick - activity.enteredWhisperTick;

    knowledge.action.exchange.whisperIntent = {
      target: activity.target,
      exchange: activity.mode,
      startedTick: activity.startedTick,
      lastActionTick: knowledge.tick,
    };
    this.logPursue(activity, "in_whisper_state", {
      targetHere,
      occupantCount: occCount,
      occupants: knowledge.occupantNames,
      pendingEntry: knowledge.pendingEntry,
      pendingEntryName: knowledge.pendingEntryName,
      pendingColorOffer: knowledge.pendingColorOffer,
      pendingRoleOffer: knowledge.pendingRoleOffer,
      pendingLeaderOffer: knowledge.pendingLeaderOffer,
      enteredWhisperTick: activity.enteredWhisperTick,
      conversationAgeTicks,
    }, 24);

    if (conversationAgeTicks > CONVERSATION_TIMEOUT_TICKS) {
      activity.status = `conversation timed out after ${Math.round(conversationAgeTicks / TARGET_FPS)}s`;
      knowledge.action.atomQueue.push({ kind: "whisper_action", action: "EXIT", label: "conversation_timeout_exit" });
      this.logPursue(activity, "conversation_timeout_exit", {
        conversationAgeTicks,
        timeoutTicks: CONVERSATION_TIMEOUT_TICKS,
        targetHere,
        occupants: knowledge.occupantNames,
        pendingEntry: knowledge.pendingEntry,
        pendingColorOffer: knowledge.pendingColorOffer,
        pendingRoleOffer: knowledge.pendingRoleOffer,
      }, 1);
      return "failed";
    }

    if (wantWhisperOnly) {
      if (targetHere) {
        if (this.enqueueConversationMessage(activity)) return "emitted";
        if (activity.conversationMessageSentTick !== null && knowledge.tick - activity.conversationMessageSentTick < CONVERSATION_WAIT_TICKS) {
          activity.status = `listening to ${activity.target}`;
          this.logPursue(activity, "listening_after_message", {
            listenTicks: knowledge.tick - activity.conversationMessageSentTick,
          }, 24);
          this.enqueueInput([0], `listen_${activity.mode}`);
          return "emitted";
        }
        this.logPursue(activity, "whisper_only_done", { targetHere }, 120);
        return "done";
      }
      if (occCount >= 2) {
        this.logPursue(activity, "wrong_whisper_exit", {
          occupants: knowledge.occupantNames,
          occupantCount: occCount,
        }, 120);
        knowledge.action.atomQueue.push({ kind: "whisper_action", action: "EXIT", label: "wrong_whisper_exit" });
      }
      return "emitted";
    }

    if (wantRole && hasRoleExchangeSucceeded(knowledge, activity.target)) {
      this.logPursue(activity, "role_already_succeeded", {}, 120);
      return "done";
    }
    if (!wantRole) {
      const followupTarget = this.sameTeamRoleFollowupTarget();
      if (followupTarget) {
        activity.target = followupTarget;
        activity.mode = "role";
        activity.offerSentTick = null;
        activity.conversationMessageSentTick = null;
        activity.status = `upgrading to role exchange with ${followupTarget}`;
        this.logPursue(activity, "upgrading_color_to_role", {
          target: followupTarget,
          source: "same_team_followup",
        }, 24);
        return "emitted";
      }
    }
    if (!wantRole && hasColorExchangeSucceeded(knowledge, activity.target)) {
      // Color done — if they're a teammate, stay and pursue role exchange
      const pb = knowledge.players.get(activity.target);
      const isTeammate = !!pb?.knownTeam && !!knowledge.myTeam && pb.knownTeam === knowledge.myTeam;
      if (isTeammate && !hasRoleExchangeSucceeded(knowledge, activity.target)) {
        activity.mode = "role";
        activity.offerSentTick = null;
        activity.status = `upgrading to role exchange with ${activity.target}`;
        this.logPursue(activity, "upgrading_color_to_role", {
          knownTeam: pb?.knownTeam ?? null,
        }, 120);
        return "emitted";
      }
      this.logPursue(activity, "color_already_succeeded", {
        knownTeam: pb?.knownTeam ?? null,
      }, 120);
      if (knowledge.tick <= knowledge.action.exchange.roleFollowupUntilTick) {
        activity.status = `waiting for same-team role followup`;
        this.enqueueInput([0], "wait_role_followup");
        return "emitted";
      }
      return "done";
    }

    if (wantRole && knowledge.pendingRoleOffer && targetHere) {
      knowledge.action.atomQueue.push({ kind: "whisper_action", action: "R.ACCPT", label: "accept_role", target: activity.target });
      markRoleExchangeSucceeded(knowledge, activity.target, "accept_offer");
      this.logPursue(activity, "accepting_role_offer", { targetHere }, 120);
      return "emitted";
    }
    if (!wantRole && knowledge.pendingColorOffer) {
      const target = targetHere
        ? activity.target
        : knowledge.occupantNames.length === 1 ? knowledge.occupantNames[0] : null;
      knowledge.action.atomQueue.push({ kind: "whisper_action", action: "C.ACCPT", label: "accept_color", target: target ?? undefined });
      if (target) markColorExchangeSucceeded(knowledge, target, "accept_offer");
      knowledge.action.exchange.roleFollowupUntilTick = Math.max(knowledge.action.exchange.roleFollowupUntilTick, knowledge.tick + 20 * TARGET_FPS);
      knowledge.action.lastGlobalCheckTick = -Infinity;
      this.logPursue(activity, "accepting_color_offer", {
        occupants: knowledge.occupantNames,
      }, 120);
      return "emitted";
    }

    if (activity.offerSentTick !== null) {
      const waited = knowledge.tick - activity.offerSentTick;
      activity.status = `offer sent, waiting ${waited}`;
      this.logPursue(activity, waited > OFFER_WAIT_TICKS ? "offer_wait_timeout" : "offer_waiting", {
        waited,
        offerSentTick: activity.offerSentTick,
      }, 48);
      return waited > OFFER_WAIT_TICKS ? "failed" : "emitted";
    }

    if (occCount < 2) {
      if (knowledge.pendingEntry) {
        knowledge.action.atomQueue.push({ kind: "whisper_action", action: "GRANT", label: "grant_entry" });
        this.logPursue(activity, "granting_entry_while_alone", {
          pendingEntryName: knowledge.pendingEntryName,
        }, 24);
        return "emitted";
      }
      const invite = inviteText(knowledge, activity.target);
      if (invite && knowledge.tick - activity.privateSpotShoutTick > ALONE_WHISPER_SHOUT_INTERVAL_TICKS) {
        activity.privateSpotShoutTick = knowledge.tick;
        knowledge.action.atomQueue.push({ kind: "chat", text: invite, label: "alone_whisper_invite" });
        this.logPursue(activity, "alone_whisper_invite", {
          text: invite,
          grantDeadlineTick: activity.grantDeadlineTick,
        }, 1);
      }
      if (activity.createdOwnWhisperTick !== null && activity.grantDeadlineTick !== null && knowledge.tick > activity.grantDeadlineTick) {
        knowledge.action.atomQueue.push({ kind: "whisper_action", action: "EXIT", label: "alone_timeout_exit" });
        this.logPursue(activity, "alone_whisper_timeout", {
          createdOwnWhisperTick: activity.createdOwnWhisperTick,
          grantDeadlineTick: activity.grantDeadlineTick,
        }, 120);
        return "failed";
      }
      this.logPursue(activity, "alone_whisper_waiting", {
        createdOwnWhisperTick: activity.createdOwnWhisperTick,
        grantDeadlineTick: activity.grantDeadlineTick,
        ticksUntilDeadline: activity.grantDeadlineTick !== null ? activity.grantDeadlineTick - knowledge.tick : null,
      }, 48);
      return "emitted";
    }

    if (!targetHere) {
      const roleTarget = this.reactiveRoleTarget();
      const followupTarget = roleTarget ?? this.sameTeamRoleFollowupTarget();
      const colorTarget = followupTarget ? null : this.reactiveColorTarget();
      const pivotTarget = followupTarget ?? colorTarget;
      if (pivotTarget) {
        activity.target = pivotTarget;
        activity.mode = followupTarget ? "role" : "color";
        activity.offerSentTick = null;
        activity.conversationMessageSentTick = null;
        activity.status = `pivoting to exchange with ${pivotTarget}`;
        this.logPursue(activity, "pivoting_to_occupants", {
          occupants: knowledge.occupantNames,
          pivotTarget,
          mode: activity.mode,
        }, 120);
        return "emitted";
      }
      this.logPursue(activity, "target_missing_exit_whisper", {
        occupants: knowledge.occupantNames,
      }, 120);
      knowledge.action.atomQueue.push({ kind: "whisper_action", action: "EXIT", label: "no_exchange_needed" });
      return "failed";
    }

    if (knowledge.pendingEntry) {
      if (whisperAlreadyHasConversationPair(knowledge)) {
        this.logPursue(activity, "entry_blocked_whisper_full", {
          pendingEntryName: knowledge.pendingEntryName,
          occupantCount: knowledge.occupantCount,
          occupants: knowledge.occupantNames,
        }, 24);
        return "emitted";
      }
      knowledge.action.atomQueue.push({ kind: "whisper_action", action: "GRANT", label: "grant_entry" });
      this.logPursue(activity, "granting_entry_with_target_present", {
        pendingEntryName: knowledge.pendingEntryName,
      }, 24);
      return "emitted";
    }

    if (this.enqueueConversationMessage(activity)) return "emitted";
    if ((!wantRole && knowledge.action.exchange.activeColorOffer) || (wantRole && knowledge.action.exchange.activeRoleOffer)) {
      activity.offerSentTick = activity.offerSentTick ?? knowledge.tick;
      activity.status = `offer active, waiting`;
      this.logPursue(activity, "offer_waiting", {
        activeColorOffer: knowledge.action.exchange.activeColorOffer,
        activeRoleOffer: knowledge.action.exchange.activeRoleOffer,
      }, 48);
      return "emitted";
    }

    knowledge.action.atomQueue.push({
      kind: "whisper_action",
      action: wantRole ? "R.OFFER" : "C.OFFER",
      label: wantRole ? "role_offer" : "color_offer",
    });
    activity.offerSentTick = knowledge.tick;
    activity.status = `sent ${activity.mode} offer to ${activity.target}`;
    this.logPursue(activity, "offer_queued", {
      action: wantRole ? "R.OFFER" : "C.OFFER",
      targetHere,
      occupants: knowledge.occupantNames,
    }, 120);
    return "emitted";
  }

  private reactiveRoleTarget(): string | null {
    const { knowledge } = this.config;
    const policy = knowledge.policy.resolved;
    if (!policy.autoOfferRoleExchange && !policy.acceptRoleOffers) return null;
    if (knowledge.occupantNames.some(name => !this.isRoleExchangeSafeOccupant(name))) return null;
    return knowledge.occupantNames.find(name =>
      policy.pursueRoleExchangeWithPlayer.includes(name) &&
      this.isRoleExchangeSafeOccupant(name) && !hasRoleExchangeSucceeded(knowledge, name)
    ) ?? null;
  }

  private sameTeamRoleFollowupTarget(): string | null {
    const { knowledge } = this.config;
    if (knowledge.tick > knowledge.action.exchange.roleFollowupUntilTick) return null;
    return knowledge.occupantNames.find(name => {
      const pb = knowledge.players.get(name);
      return !!pb?.knownTeam
        && !!knowledge.myTeam
        && pb.knownTeam === knowledge.myTeam
        && !hasRoleExchangeSucceeded(knowledge, name);
    }) ?? null;
  }

  private reactiveColorTarget(): string | null {
    const { knowledge } = this.config;
    const policy = knowledge.policy.resolved;
    if (!policy.autoOfferColorExchange) return null;
    const deny = new Set([...policy.autoOfferColorDenyPlayers, ...policy.avoidPlayers]);
    if (knowledge.occupantNames.some(name => deny.has(name))) return null;
    return knowledge.occupantNames.find(name =>
      policy.pursueColorExchangeWithPlayer.includes(name) && !hasColorExchangeSucceeded(knowledge, name)
    ) ?? null;
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

  private enqueueConversationMessage(activity: PursuePlayerActivity): boolean {
    const { knowledge } = this.config;
    if (activity.conversationMessageSentTick !== null) return false;
    const draft = popNextWhisperDraft(knowledge, [activity.target]);
    const text = draft?.text ?? cannedConversationMessage(activity.mode, activity.target);
    if (!text) return false;
    activity.conversationMessageSentTick = knowledge.tick;
    knowledge.action.exchange.whisperIntent = {
      target: activity.target,
      exchange: activity.mode,
      startedTick: activity.startedTick,
      lastActionTick: knowledge.tick,
    };
    knowledge.action.atomQueue.push({ kind: "chat", text, label: `pursue_${activity.mode}_message` });
    activity.status = `messaging ${activity.target} for ${activity.mode}`;
    this.logPursue(activity, "conversation_message_queued", {
      source: draft ? draft.source : "canned",
      text,
    }, 120);
    return true;
  }

  private finishActivity(result: "done" | "failed", reason: string): void {
    const { knowledge, logEvent } = this.config;
    const activity = knowledge.action.currentActivity;
    if (!activity) return;
    logEvent("activity_finished", { id: activity.id, activityKind: activity.kind, result, reason });
    if (result === "failed" && activity.kind === "pursue_player" && shouldStartFailedTargetCooldown(reason)) {
      knowledge.action.exchange.failedTargets.set(activity.target, knowledge.tick);
      logEvent("target_cooldown_started", {
        target: activity.target,
        mode: activity.mode,
        cooldownTicks: FAILED_TARGET_COOLDOWN_TICKS,
        reason,
      });
    }
    knowledge.action.currentActivity = null;
    knowledge.action.exchange.currentTarget = null;
    knowledge.action.exchange.exchangePhase = "idle";
    knowledge.action.exchange.prefetchRequested = null;
  }

  private markBadPursueTarget(target: string, reason: string): void {
    const { knowledge, logEvent } = this.config;
    knowledge.action.exchange.badPursueTargets.set(target, { tick: knowledge.tick, reason });
    logEvent("target_penalty_started", {
      target,
      reason,
      tick: knowledge.tick,
      cooldownTicks: badPursuitCooldownTicks(reason),
    });
  }

  private logPursue(
    activity: PursuePlayerActivity,
    event: string,
    detail: Record<string, unknown> = {},
    minIntervalTicks = 24,
  ): void {
    const { knowledge, logEvent } = this.config;
    const key = `${activity.id}:${event}`;
    const lastTick = this.activityTelemetryTicks.get(key) ?? -Infinity;
    if (knowledge.tick - lastTick < minIntervalTicks) return;
    this.activityTelemetryTicks.set(key, knowledge.tick);
    logEvent("pursue_telemetry", {
      event,
      activityId: activity.id,
      target: activity.target,
      mode: activity.mode,
      approach: activity.approach,
      activityAgeTicks: knowledge.tick - activity.startedTick,
      status: activity.status,
      phase: knowledge.phase,
      occupantCount: knowledge.occupantCount,
      occupants: knowledge.occupantNames,
      pendingEntry: knowledge.pendingEntry,
      pendingEntryName: knowledge.pendingEntryName,
      ...detail,
    });
  }

  private enqueueInput(masks: number[], label: string): void {
    this.config.knowledge.action.atomQueue.push({ kind: "input", masks, label });
    this.config.logEvent("activity_atomic_queued", {
      label,
      kind: "input",
      masks,
      queueAfter: atomQueueSummary(this.config.knowledge.action.atomQueue),
      activeActivity: activityTelemetrySummary(this.config.knowledge.action.currentActivity),
    });
  }

  private logActivityBlockedByAtoms(activity: Activity): void {
    const { knowledge, logEvent } = this.config;
    const key = `${activity.id}:blocked_by_atoms:${atomQueueSummary(knowledge.action.atomQueue).join("|")}`;
    const lastTick = this.activityTelemetryTicks.get(key) ?? -Infinity;
    if (knowledge.tick - lastTick < 24) return;
    this.activityTelemetryTicks.set(key, knowledge.tick);
    logEvent("activity_blocked_by_atoms", {
      activity: activityTelemetrySummary(activity),
      queue: atomQueueSummary(knowledge.action.atomQueue),
      phase: knowledge.phase,
      occupants: knowledge.occupantNames,
      pendingEntry: knowledge.pendingEntry,
      pendingColorOffer: knowledge.pendingColorOffer,
      pendingRoleOffer: knowledge.pendingRoleOffer,
    });
  }

  private executePsychopompPrecommit(frame: Uint8Array): void {
    const { ws, knowledge, bot, botName, logEvent } = this.config;
    if (!bot.psychopompPrecommit || bot.psychopompPrecommit.length === 0) return;

    if (knowledge.matchFacts.currentRound !== this.psychopompRound) {
      this.psychopompState = "opening";
      this.psychopompRound = knowledge.matchFacts.currentRound;
      this.psychopompGridLogged = false;
      this.psychopompReleaseNext = false;
      console.log(`[${botName}] psychopomp execution started, targets: [${bot.psychopompPrecommit.join(", ")}]`);
      logEvent("psychopomp_execution_started", { targets: bot.psychopompPrecommit });
    }

    if (this.psychopompReleaseNext) {
      this.psychopompReleaseNext = false;
      sendInput(ws, 0);
      return;
    }

    if (this.psychopompState === "done") {
      sendInput(ws, 0);
      return;
    }

    if (this.psychopompState === "opening") {
      const grid = parsePsychopompGrid(frame, matchRoster(knowledge.players.values()));
      if (grid) {
        this.psychopompState = "selecting";
      } else {
        this.sendPsychopompInput(BUTTON_SELECT);
        return;
      }
    }

    if (this.psychopompState === "selecting") {
      const grid = parsePsychopompGrid(frame, matchRoster(knowledge.players.values()));
      if (!grid) {
        sendInput(ws, 0);
        return;
      }

      const targetSet = new Set(bot.psychopompPrecommit);
      const gridNames = grid.eligible.map(e => e.shape !== null ? characterName(e.color, e.shape) : `?c${e.color}`);
      if (!this.psychopompGridLogged) {
        this.psychopompGridLogged = true;
        console.log(`[${botName}] psychopomp grid: [${gridNames.join(", ")}] cursor=${grid.cursorPosition} selected=[${grid.selectedPositions.join(",")}] targets=[${bot.psychopompPrecommit.join(",")}]`);
      }

      for (let i = 0; i < grid.eligible.length; i++) {
        const entry = grid.eligible[i];
        const entryName = entry.shape !== null ? characterName(entry.color, entry.shape) : null;
        const isTarget = entryName !== null && targetSet.has(entryName);
        const isSelected = grid.selectedPositions.includes(i);
        if (isTarget !== isSelected) {
          const delta = i - grid.cursorPosition;
          if (delta > 0) this.sendPsychopompInput(BUTTON_RIGHT);
          else if (delta < 0) this.sendPsychopompInput(BUTTON_LEFT);
          else this.sendPsychopompInput(BUTTON_A);
          return;
        }
      }

      console.log(`[${botName}] psychopomp selection complete, committing`);
      logEvent("psychopomp_commit", { targets: bot.psychopompPrecommit });
      this.psychopompState = "done";
      this.sendPsychopompInput(BUTTON_B);
    }
  }

  private sendPsychopompInput(mask: number): void {
    sendInput(this.config.ws, mask);
    this.psychopompReleaseNext = mask !== 0;
  }
}

function randomGrantDeadline(tick: number): number {
  return tick + ALONE_WHISPER_MIN_TICKS + Math.floor(Math.random() * ALONE_WHISPER_JITTER_TICKS);
}

function cannedConversationMessage(mode: PursuePlayerActivity["mode"], target: string): string | null {
  switch (mode) {
    case "color": return `${target} COLOR?`;
    case "role": return `${target} ROLE?`;
    case "whisper": return `${target} TALK?`;
    case "leader": return `${target} LEAD?`;
  }
}

function findTargetDot(player: GameKnowledge, target: string): MinimapDot | undefined {
  const targetColor = colorFromCharName(target);
  if (targetColor === null) return undefined;
  const dots = player.minimapDots.filter(d => d.color === targetColor && !d.isSelf);
  if (dots.length <= 1) return dots[0];
  const targetPlayer = player.players.get(target);
  if (!targetPlayer?.lastPos) return dots[0];
  let best = dots[0], bestDist = Infinity;
  for (const d of dots) {
    const dist = (d.worldX - targetPlayer.lastPos.x) ** 2 + (d.worldY - targetPlayer.lastPos.y) ** 2;
    if (dist < bestDist) { bestDist = dist; best = d; }
  }
  return best;
}

function shouldRequestTargetWhisper(player: GameKnowledge, target: string): boolean {
  const targetBelief = player.players.get(target);
  return !!targetBelief?.inWhisper && targetBelief.lastRoom === player.myRoom && player.nearbyNames.includes(target);
}

function shouldStartFailedTargetCooldown(reason: string): boolean {
  return !(
    reason.includes(" is crowded")
    || reason.includes("already in conversation")
    || reason.includes("blocked by nearby whisper")
    || reason.includes("entry wait timed out")
    || reason.includes("open attempt timed out")
  );
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

function nearbyPlayersInWhispers(player: GameKnowledge): string[] {
  return player.nearbyNames.filter(name => {
    const pb = player.players.get(name);
    return !!pb?.inWhisper;
  });
}

function crowdedNamesNearTarget(player: GameKnowledge, target: string, targetDot: MinimapDot): string[] {
  const crowdRadius = BUBBLE_RADIUS * 1.8;
  const crowdRadiusSq = crowdRadius * crowdRadius;
  const names: string[] = [];
  for (const dot of player.minimapDots) {
    if (dot.isSelf) continue;
    const d = distSq({ x: dot.worldX, y: dot.worldY }, { x: targetDot.worldX, y: targetDot.worldY });
    if (d > crowdRadiusSq) continue;
    const colorMatches = Array.from(player.players.values()).filter(pb => pb.color === dot.color);
    for (const pb of colorMatches) {
      if (pb.name === player.myCharName || pb.name === target) continue;
      if (!names.includes(pb.name)) names.push(pb.name);
    }
  }
  return names;
}

function moveAwayFromPlayers(player: GameKnowledge, names: string[]): number {
  if (!player.myPos) return 0;
  let sx = 0;
  let sy = 0;
  let count = 0;
  for (const name of names) {
    const pb = player.players.get(name);
    if (!pb?.lastPos) continue;
    sx += pb.lastPos.x;
    sy += pb.lastPos.y;
    count++;
  }
  if (count === 0) return 0;
  const cx = sx / count;
  const cy = sy / count;
  const tx = Math.max(0, Math.min(player.matchFacts.roomW - 1, player.myPos.x + (player.myPos.x - cx)));
  const ty = Math.max(0, Math.min(player.matchFacts.roomH - 1, player.myPos.y + (player.myPos.y - cy)));
  return moveToward(player.myPos.x, player.myPos.y, tx, ty, TARGET_APPROACH_DEADZONE) || 0;
}

function firstUnknownOccupant(player: GameKnowledge): string | null {
  for (const name of player.occupantNames) {
    const pb = player.players.get(name);
    if (pb && !hasColorExchangeSucceeded(player, name)) return name;
  }
  return null;
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

function inviteText(player: GameKnowledge, target: string): string | null {
  if (!player.myPos) return null;
  const pb = player.players.get(target);
  if (!pb || pb.lastRoom !== player.myRoom) return null;
  return `${target} COME @ ${Math.round(player.myPos.x)},${Math.round(player.myPos.y)}`;
}

function hasRendezvousAck(knowledge: GameKnowledge, target: string, spot: Point): boolean {
  const COORD_TOLERANCE = 4;
  for (const offer of knowledge.messages.rendezvousOffers) {
    if (offer.sender.name !== knowledge.myCharName) continue;
    if (!offer.acknowledged) continue;
    const dx = Math.abs(offer.coords.x - spot.x);
    const dy = Math.abs(offer.coords.y - spot.y);
    if (dx <= COORD_TOLERANCE && dy <= COORD_TOLERANCE) {
      // Check the acker was our target (by looking at who acked matching coords)
      const ackOffer = knowledge.messages.rendezvousOffers.find(o =>
        o.sender.name === target
        && Math.abs(o.coords.x - spot.x) <= COORD_TOLERANCE
        && Math.abs(o.coords.y - spot.y) <= COORD_TOLERANCE
      );
      if (ackOffer || offer.intendedTarget === target) return true;
    }
  }
  return false;
}

function distSq(a: Point, b: Point): number {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  return dx * dx + dy * dy;
}

function atomQueueSummary(atoms: AtomicAction[]): string[] {
  return atoms.map(atomSummary);
}

function infoCheckOriginSurface(state: ParsedUiState): ParsedUiState["surface"] {
  if (state.surface === "whisper_menu" || state.surface === "whisper_share_picker") {
    return "whisper_idle";
  }
  if (state.surface === "other" && (state.phase === "whisper" || state.phase === "leader_summit")) {
    return "whisper_idle";
  }
  if (state.surface === "other" && (state.phase === "playing" || state.phase === "psychopomp_select")) {
    return "playing";
  }
  return state.surface;
}

function infoCheckReturnTarget(origin: ParsedUiState["surface"] | undefined): UiTarget {
  if (origin === "whisper_idle" || origin === "whisper_menu" || origin === "whisper_share_picker") {
    return { kind: "whisper_idle" };
  }
  if (origin === "shout") {
    return { kind: "shout_screen" };
  }
  return { kind: "playing_surface" };
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

function activityTelemetrySummary(activity: Activity | null): Record<string, unknown> | null {
  if (!activity) return null;
  if (activity.kind === "walk_to") {
    return {
      id: activity.id,
      kind: activity.kind,
      x: activity.x,
      y: activity.y,
      status: activity.status,
      ageTicks: activity.lastActiveTick - activity.startedTick,
    };
  }
  return {
    id: activity.id,
    kind: activity.kind,
    target: activity.target,
    mode: activity.mode,
    approach: activity.approach,
    status: activity.status,
    ageTicks: activity.lastActiveTick - activity.startedTick,
    offerSentTick: activity.offerSentTick,
    conversationMessageSentTick: activity.conversationMessageSentTick,
    createdOwnWhisperTick: activity.createdOwnWhisperTick,
    enteredWhisperTick: activity.enteredWhisperTick,
    waitingEntryTick: activity.waitingEntryTick,
    grantDeadlineTick: activity.grantDeadlineTick,
  };
}

function uiStateLog(state: ParsedUiState): Record<string, unknown> {
  if (state.surface === "whisper_menu") {
    return {
      phase: state.phase,
      surface: state.surface,
      bottomText: state.bottomText,
      catIdx: state.catIdx,
      itemIdx: state.itemIdx,
      action: state.action,
    };
  }
  if (state.surface === "whisper_share_picker") {
    return {
      phase: state.phase,
      surface: state.surface,
      bottomText: state.bottomText,
      mode: state.mode,
    };
  }
  return {
    phase: state.phase,
    surface: state.surface,
    bottomText: state.bottomText,
  };
}

function clampPoint(x: number, y: number, player: GameKnowledge): Point {
  const margin = Math.max(12, BUBBLE_RADIUS);
  return {
    x: Math.max(margin, Math.min(player.matchFacts.roomW - margin, Math.round(x))),
    y: Math.max(margin, Math.min(player.matchFacts.roomH - margin, Math.round(y))),
  };
}

function nearestOtherDistSq(player: GameKnowledge, point: Point, exceptTarget?: string): number {
  const exceptColor = exceptTarget ? colorFromCharName(exceptTarget) : null;
  let best = Infinity;
  for (const dot of player.minimapDots) {
    if (dot.isSelf) continue;
    if (exceptColor !== null && dot.color === exceptColor) continue;
    const d = distSq(point, { x: dot.worldX, y: dot.worldY });
    if (d < best) best = d;
  }
  return best;
}

function pointIsPrivate(player: GameKnowledge, point: Point, exceptTarget?: string): boolean {
  const privacyRadius = BUBBLE_RADIUS * 2.2;
  return nearestOtherDistSq(player, point, exceptTarget) >= privacyRadius * privacyRadius;
}

function choosePrivateSpot(player: GameKnowledge, targetDot?: MinimapDot): Point | null {
  if (!player.myPos) return null;
  const margin = Math.max(18, BUBBLE_RADIUS + 4);
  const candidates: Point[] = [
    { x: margin, y: margin },
    { x: player.matchFacts.roomW - margin, y: margin },
    { x: margin, y: player.matchFacts.roomH - margin },
    { x: player.matchFacts.roomW - margin, y: player.matchFacts.roomH - margin },
  ].map(p => clampPoint(p.x, p.y, player));
  if (targetDot) {
    candidates.unshift(clampPoint(
      player.myPos.x + (player.myPos.x - targetDot.worldX) * 2,
      player.myPos.y + (player.myPos.y - targetDot.worldY) * 2,
      player,
    ));
  }

  let best: Point | null = null;
  let bestScore = -Infinity;
  for (const c of candidates) {
    const crowdDist = Math.sqrt(nearestOtherDistSq(player, c));
    const selfDist = Math.sqrt(distSq(player.myPos, c));
    const targetDist = targetDot ? Math.sqrt(distSq(c, { x: targetDot.worldX, y: targetDot.worldY })) : 0;
    const score = crowdDist * 3 - selfDist * 0.6 - targetDist * 0.25;
    if (score > bestScore) { bestScore = score; best = c; }
  }
  return best;
}

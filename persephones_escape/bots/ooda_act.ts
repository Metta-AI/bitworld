import type WebSocket from "ws";
import {
  BUBBLE_RADIUS,
  BUTTON_A,
  BUTTON_B,
  BUTTON_LEFT,
  BUTTON_RIGHT,
  BUTTON_SELECT,
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
  parseHostageGrid,
  parseUsurpCandidate,
  type MinimapDot,
} from "./frame_parser.js";
import { whisperMenuSequenceWithTargetPick } from "../game/menu_defs.js";
import type { Activity, AtomicAction, BotLogFn, FrameDecision, PursuePlayerActivity } from "./ooda_types.js";
import type { HostageDecisionStatus } from "./ooda_decide.js";

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

type StepResult = "emitted" | "done" | "failed" | "skip";

export class OodaActuator {
  private hostageState: "opening" | "selecting" | "done" = "opening";
  private hostageRound = -1;
  private hostageGridLogged = false;

  constructor(private config: OodaActuatorConfig) {}

  hostageStatus(): HostageDecisionStatus {
    return { round: this.hostageRound, done: this.hostageState === "done" };
  }

  act(decision: FrameDecision): void {
    const { ws, knowledge } = this.config;
    switch (decision.kind) {
      case "input":
        sendInput(ws, decision.mask);
        return;
      case "hostage_precommit":
        this.executeHostagePrecommit(decision.frame);
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
    if (!atom) return false;

    const result = this.advanceAtomic(atom, frame);
    if (result === "done" || result === "failed") {
      this.config.logEvent("atomic_finished", { kind: atom.kind, label: atom.label, result });
      this.config.knowledge.action.atomQueue.shift();
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
      case "whisper_action": {
        if (knowledge.phase !== "whisper" && knowledge.phase !== "leader_summit") return "failed";
        const seq = whisperMenuSequenceWithTargetPick(atom.action);
        if (seq.length === 0) return "failed";
        if (atom.action === "C.ACCPT") {
          for (const name of knowledge.occupantNames) markColorExchangeSucceeded(knowledge, name, "atomic_accept");
        } else if (atom.action === "R.ACCPT") {
          const target = knowledge.action.currentActivity?.kind === "pursue_player"
            ? knowledge.action.currentActivity.target
            : knowledge.occupantNames.length === 1 ? knowledge.occupantNames[0] : null;
          if (target) markRoleExchangeSucceeded(knowledge, target, "atomic_accept");
        }
        knowledge.action.atomQueue[0] = { kind: "input", masks: seq, label: atom.label, index: 0 };
        return this.advanceAtomic(knowledge.action.atomQueue[0], frame);
      }
      case "usurp_vote":
        return this.advanceUsurpAtomic(atom, frame);
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
      if (candidate.isPlayer && targetColor !== null && candidate.color === targetColor) {
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
      sendInput(ws, BUTTON_RIGHT);
      return "emitted";
    }

    sendInput(ws, BUTTON_SELECT);
    return "done";
  }

  private advanceActivity(activity: Activity): StepResult {
    if (this.config.knowledge.tick - activity.startedTick > activity.timeLimitTicks) return "failed";
    if (this.config.knowledge.action.atomQueue.length > 0) return "emitted";
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
    if ((knowledge.phase !== "playing" && knowledge.phase !== "leader_summit") || !knowledge.myPos) return "skip";
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
      activity.createdOwnWhisperTick = null;
      activity.grantDeadlineTick = null;
      activity.status = "waiting for entry";
      this.enqueueInput([0], "pursue_waiting_entry");
      return "emitted";
    }

    if (knowledge.phase === "whisper" || knowledge.phase === "leader_summit") {
      return this.advancePursueInWhisper(activity);
    }

    if ((knowledge.phase !== "playing" && knowledge.phase !== "leader_summit") || !knowledge.myPos) return "skip";
    if (!targetBelief || targetBelief.lastRoom !== knowledge.myRoom) {
      activity.status = `${activity.target} is not in current room`;
      return "failed";
    }

    const targetDot = findTargetDot(knowledge, activity.target);
    if (targetDot) activity.lastSawTargetTick = knowledge.tick;

    if (shouldRequestTargetWhisper(knowledge, activity.target)) {
      activity.status = `requesting entry to ${activity.target}`;
      this.enqueueInput([BUTTON_B], "request_target_whisper");
      return "emitted";
    }

    if (activity.approach === "find_spot") {
      return this.advanceFindSpot(activity, targetDot);
    }

    if (!targetDot) {
      activity.status = `${activity.target} not visible`;
      this.enqueueInput([0], "pursue_target_not_visible");
      return "emitted";
    }

    const dist = distSq(knowledge.myPos, { x: targetDot.worldX, y: targetDot.worldY });
    if (dist > 100) {
      activity.status = `walking to ${activity.target}`;
      this.enqueueInput([moveToward(knowledge.myPos.x, knowledge.myPos.y, targetDot.worldX, targetDot.worldY) || 0], "pursue_walk_to_target");
      return "emitted";
    }

    if (targetBelief && !targetBelief.inWhisper && knowledge.myCharName && knowledge.myCharName > activity.target) {
      if (activity.nearTargetWaitTick === -Infinity) activity.nearTargetWaitTick = knowledge.tick;
      if (knowledge.tick - activity.nearTargetWaitTick < 48) {
        activity.status = `waiting for ${activity.target} to host`;
        this.enqueueInput([0], "pursue_wait_for_host");
        return "emitted";
      }
    }

    activity.status = `opening whisper with ${activity.target}`;
    if (activity.createdOwnWhisperTick === null) {
      activity.createdOwnWhisperTick = knowledge.tick;
      activity.grantDeadlineTick = randomGrantDeadline(knowledge.tick);
    }
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
      this.enqueueInput([0], "private_spot_retarget");
      return "emitted";
    }
    const currentSpotPrivate = activity.privateSpot ? pointIsPrivate(knowledge, activity.privateSpot, activity.target) : false;
    if (!activity.privateSpot || !currentSpotPrivate || knowledge.tick - activity.privateSpotTick > 180) {
      activity.privateSpot = choosePrivateSpot(knowledge, targetDot);
      activity.privateSpotTick = knowledge.tick;
    }
    if (!activity.privateSpot) return "skip";
    const spotDist = distSq(knowledge.myPos, activity.privateSpot);
    if (spotDist > 100) {
      activity.status = `finding private spot for ${activity.target}`;
      this.enqueueInput([moveToward(knowledge.myPos.x, knowledge.myPos.y, activity.privateSpot.x, activity.privateSpot.y) || 0], "private_spot_walk");
      return "emitted";
    }
    if (knowledge.tick - activity.privateSpotShoutTick > 180) {
      activity.privateSpotShoutTick = knowledge.tick;
      const msg = inviteText(knowledge, activity.target);
      if (msg) knowledge.action.atomQueue.push({ kind: "chat", text: msg, label: "private_spot_invite" });
      activity.status = `advertising private spot to ${activity.target}`;
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
      return "failed";
    }

    activity.status = acked
      ? `waiting for acked ${activity.target}`
      : `creating private whisper for ${activity.target}`;
    if (activity.createdOwnWhisperTick === null || knowledge.tick - activity.createdOwnWhisperTick > 30) {
      activity.createdOwnWhisperTick = knowledge.tick;
      activity.grantDeadlineTick = randomGrantDeadline(knowledge.tick);
    }
    this.enqueueInput([BUTTON_A], "private_spot_open_whisper");
    return "emitted";
  }

  private advancePursueInWhisper(activity: PursuePlayerActivity): StepResult {
    const { knowledge } = this.config;
    const wantRole = activity.mode === "role";
    const wantWhisperOnly = activity.mode === "whisper" || activity.mode === "leader";
    const targetHere = knowledge.occupantNames.includes(activity.target);
    const occCount = knowledge.occupantCount;

    knowledge.action.exchange.whisperIntent = {
      target: activity.target,
      exchange: activity.mode,
      startedTick: activity.startedTick,
      lastActionTick: knowledge.tick,
    };

    if (wantWhisperOnly) {
      if (targetHere) {
        if (this.enqueueConversationMessage(activity)) return "emitted";
        if (activity.conversationMessageSentTick !== null && knowledge.tick - activity.conversationMessageSentTick < CONVERSATION_WAIT_TICKS) {
          activity.status = `listening to ${activity.target}`;
          this.enqueueInput([0], `listen_${activity.mode}`);
          return "emitted";
        }
        return "done";
      }
      if (occCount >= 2) knowledge.action.atomQueue.push({ kind: "whisper_action", action: "EXIT", label: "wrong_whisper_exit" });
      return "emitted";
    }

    if (wantRole && hasRoleExchangeSucceeded(knowledge, activity.target)) return "done";
    if (!wantRole && hasColorExchangeSucceeded(knowledge, activity.target)) {
      // Color done — if they're a teammate, stay and pursue role exchange
      const pb = knowledge.players.get(activity.target);
      const isTeammate = !!pb?.knownTeam && !!knowledge.myTeam && pb.knownTeam === knowledge.myTeam;
      if (isTeammate && !hasRoleExchangeSucceeded(knowledge, activity.target)) {
        activity.mode = "role";
        activity.offerSentTick = null;
        activity.status = `upgrading to role exchange with ${activity.target}`;
        return "emitted";
      }
      return "done";
    }

    if (wantRole && knowledge.pendingRoleOffer && targetHere) {
      knowledge.action.atomQueue.push({ kind: "whisper_action", action: "R.ACCPT", label: "accept_role" });
      markRoleExchangeSucceeded(knowledge, activity.target, "accept_offer");
      return "emitted";
    }
    if (!wantRole && knowledge.pendingColorOffer) {
      knowledge.action.atomQueue.push({ kind: "whisper_action", action: "C.ACCPT", label: "accept_color" });
      for (const name of knowledge.occupantNames) markColorExchangeSucceeded(knowledge, name, "accept_offer");
      return "emitted";
    }

    if (activity.offerSentTick !== null) {
      const waited = knowledge.tick - activity.offerSentTick;
      activity.status = `offer sent, waiting ${waited}`;
      return waited > OFFER_WAIT_TICKS ? "failed" : "emitted";
    }

    if (occCount < 2) {
      if (knowledge.pendingEntry) {
        knowledge.action.atomQueue.push({ kind: "whisper_action", action: "GRANT", label: "grant_entry" });
        return "emitted";
      }
      const invite = inviteText(knowledge, activity.target);
      if (invite && knowledge.tick - activity.privateSpotShoutTick > ALONE_WHISPER_SHOUT_INTERVAL_TICKS) {
        activity.privateSpotShoutTick = knowledge.tick;
        knowledge.action.atomQueue.push({ kind: "chat", text: invite, label: "alone_whisper_invite" });
      }
      if (activity.createdOwnWhisperTick !== null && activity.grantDeadlineTick !== null && knowledge.tick > activity.grantDeadlineTick) {
        knowledge.action.atomQueue.push({ kind: "whisper_action", action: "EXIT", label: "alone_timeout_exit" });
        return "failed";
      }
      return "emitted";
    }

    if (!targetHere) {
      // Target not here — stay if any occupant is in our pursue lists
      const policy = knowledge.policy.resolved;
      const wantExchange = knowledge.occupantNames.some(name =>
        policy.pursueColorExchangeWithPlayer.includes(name) ||
        policy.pursueRoleExchangeWithPlayer.includes(name)
      );
      if (wantExchange) {
        activity.status = `pivoting to exchange with ${knowledge.occupantNames.join(",")}`;
        return "emitted";
      }
      knowledge.action.atomQueue.push({ kind: "whisper_action", action: "EXIT", label: "no_exchange_needed" });
      return "failed";
    }

    if (knowledge.pendingEntry) {
      knowledge.action.atomQueue.push({ kind: "whisper_action", action: "GRANT", label: "grant_entry" });
      return "emitted";
    }

    if (this.enqueueConversationMessage(activity)) return "emitted";

    knowledge.action.atomQueue.push({
      kind: "whisper_action",
      action: wantRole ? "R.OFFER" : "C.OFFER",
      label: wantRole ? "role_offer" : "color_offer",
    });
    activity.offerSentTick = knowledge.tick;
    activity.status = `sent ${activity.mode} offer to ${activity.target}`;
    return "emitted";
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
    return true;
  }

  private finishActivity(result: "done" | "failed", reason: string): void {
    const { knowledge, logEvent } = this.config;
    const activity = knowledge.action.currentActivity;
    if (!activity) return;
    logEvent("activity_finished", { id: activity.id, kind: activity.kind, result, reason });
    knowledge.action.currentActivity = null;
    knowledge.action.exchange.currentTarget = null;
    knowledge.action.exchange.exchangePhase = "idle";
    knowledge.action.exchange.prefetchRequested = null;
  }

  private enqueueInput(masks: number[], label: string): void {
    this.config.knowledge.action.atomQueue.push({ kind: "input", masks, label });
  }

  private executeHostagePrecommit(frame: Uint8Array): void {
    const { ws, knowledge, bot, botName, logEvent } = this.config;
    if (!bot.hostagePrecommit || bot.hostagePrecommit.length === 0) return;

    if (knowledge.matchFacts.currentRound !== this.hostageRound) {
      this.hostageState = "opening";
      this.hostageRound = knowledge.matchFacts.currentRound;
      this.hostageGridLogged = false;
      console.log(`[${botName}] hostage execution started, targets: [${bot.hostagePrecommit.join(", ")}]`);
      logEvent("hostage_execution_started", { targets: bot.hostagePrecommit });
    }

    if (this.hostageState === "done") {
      sendInput(ws, 0);
      return;
    }

    if (this.hostageState === "opening") {
      const grid = parseHostageGrid(frame, matchRoster(knowledge.players.values()));
      if (grid) {
        this.hostageState = "selecting";
      } else {
        sendInput(ws, BUTTON_SELECT);
        return;
      }
    }

    if (this.hostageState === "selecting") {
      const grid = parseHostageGrid(frame, matchRoster(knowledge.players.values()));
      if (!grid) {
        sendInput(ws, 0);
        return;
      }

      const targetSet = new Set(bot.hostagePrecommit);
      const gridNames = grid.eligible.map(e => e.shape !== null ? characterName(e.color, e.shape) : `?c${e.color}`);
      if (!this.hostageGridLogged) {
        this.hostageGridLogged = true;
        console.log(`[${botName}] hostage grid: [${gridNames.join(", ")}] cursor=${grid.cursorPosition} selected=[${grid.selectedPositions.join(",")}] targets=[${bot.hostagePrecommit.join(",")}]`);
      }

      for (let i = 0; i < grid.eligible.length; i++) {
        const entry = grid.eligible[i];
        const entryName = entry.shape !== null ? characterName(entry.color, entry.shape) : null;
        const isTarget = entryName !== null && targetSet.has(entryName);
        const isSelected = grid.selectedPositions.includes(i);
        if (isTarget !== isSelected) {
          const delta = i - grid.cursorPosition;
          if (delta > 0) sendInput(ws, BUTTON_RIGHT);
          else if (delta < 0) sendInput(ws, BUTTON_LEFT);
          else sendInput(ws, BUTTON_A);
          return;
        }
      }

      console.log(`[${botName}] hostage selection complete, committing`);
      logEvent("hostage_commit", { targets: bot.hostagePrecommit });
      this.hostageState = "done";
      sendInput(ws, BUTTON_B);
    }
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

function firstUnknownOccupant(player: GameKnowledge): string | null {
  for (const name of player.occupantNames) {
    const pb = player.players.get(name);
    if (pb && !hasColorExchangeSucceeded(player, name)) return name;
  }
  return null;
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

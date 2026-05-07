/**
 * Default deterministic policy layer.
 *
 * Called every frame. Reads GameKnowledge.policy.resolved and manages the task list.
 * Never async. Always produces reasonable behavior even with an empty strategy.
 *
 * Exchange loop: shout intent → walk to meet point/target → open whisper → exchange → exit → next
 */

import {
  type ActionExchangeState,
  type GameKnowledge,
  type ResolvedPolicy,
  colorFromCharName,
  hasColorExchangeSucceeded,
  hasRoleExchangeSucceeded,
  psychopompCountForRound,
  popNextShoutDraft,
  popNextWhisperDraft,
} from "./game_knowledge.js";
import {
  type TaskInstance, type EventBuffer, type Task,
  createTaskInstance, isLoopTask, isAsyncTask, isOnceTask,
} from "./tasks.js";
import type { BotController } from "./bot_common.js";

// ---------------------------------------------------------------------------
// Policy context
// ---------------------------------------------------------------------------

export interface PolicyContext {
  player: GameKnowledge;
  strategy: ResolvedPolicy;
  bot: BotController;
  tasks: TaskInstance[];
  events: EventBuffer;
}

type ExchangeMode = "find_spot" | "go_to_player";
type WhisperIntentExchange = "color" | "role" | "whisper";
type PolicyMemory = ActionExchangeState;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const STALE_PREFETCH_TICKS = 300;
const SHOUT_COOLDOWN_TICKS = 180;
const TASK_RETRY_COOLDOWN = 300;  // ~5s before retrying same target
const EXCHANGE_TIMEOUT_TICKS = 600;
const INTERPRET_COOLDOWN_TICKS = 120;
const FIND_SPOT_HOST_PROBABILITY = 0.45;
const WHISPER_DECISION_GRACE_TICKS = 36;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function hasLoopTask(tasks: TaskInstance[], kind: string): boolean {
  return tasks.some(ti => ti.task.kind === kind);
}

function hasActiveAsync(tasks: TaskInstance[]): boolean {
  return tasks.some(ti => isAsyncTask(ti.task));
}

function hasActivePursueExchange(tasks: TaskInstance[]): boolean {
  return tasks.some(ti => ti.task.kind === "pursue_exchange");
}

function hasActiveTaskForTarget(tasks: TaskInstance[], target: string): boolean {
  return tasks.some(ti => "target" in ti.task && (ti.task as any).target === target);
}

function hasOnceTask(tasks: TaskInstance[], kind: string): boolean {
  return tasks.some(ti => ti.task.kind === kind);
}

function isTargetOnCooldown(mem: PolicyMemory, target: string, tick: number): boolean {
  const failTick = mem.failedTargets.get(target);
  if (failTick === undefined) return false;
  return (tick - failTick) < TASK_RETRY_COOLDOWN;
}

function shuffle<T>(arr: T[]): T[] {
  const out = [...arr];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
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

function isKnownTeammate(player: GameKnowledge, playerName: string): boolean {
  const pb = player.players.get(playerName);
  return !!pb?.knownTeam && !!player.myTeam && pb.knownTeam === player.myTeam;
}

function shouldRoleExchangeWith(player: GameKnowledge, playerName: string): boolean {
  const pb = player.players.get(playerName);
  if (!pb || hasRoleExchangeSucceeded(player, playerName)) return false;
  if (isKnownTeammate(player, playerName)) return true;
  const partner = keyPartnerRole(player.myRole);
  return partner !== null && normalizeRole(pb.knownRole) === partner;
}

function findKnownKeyPartner(player: GameKnowledge) {
  const partner = keyPartnerRole(player.myRole);
  if (!partner) return null;
  for (const pb of player.players.values()) {
    if (normalizeRole(pb.knownRole) === partner) return pb;
  }
  return null;
}

function isVisibleByName(player: GameKnowledge, name: string): boolean {
  const color = colorFromCharName(name);
  return color !== null && player.minimapDots.some(d => d.color === color && !d.isSelf);
}

function isReachableInCurrentRoom(player: GameKnowledge, name: string): boolean {
  const pb = player.players.get(name);
  return !!pb && pb.lastRoom === player.myRoom && isVisibleByName(player, name);
}

function chooseExchangeMode(player: GameKnowledge, exchange: "role" | "color"): ExchangeMode {
  // Role exchanges are more coordination-sensitive, so slightly prefer hosting
  // a private spot; color checks can more often walk to an existing offer.
  const policy = player.policy.resolved;
  const hostProbability = exchange === "role"
    ? Math.min(0.7, policy.hostPrivateSpotProbability + 0.1)
    : policy.hostPrivateSpotProbability;
  if (player.nearbyNames.length > 0 && Math.random() < policy.goToVisiblePlayerProbability) return "go_to_player";
  return Math.random() < hostProbability ? "find_spot" : "go_to_player";
}

function consumePolicyOneShot(player: GameKnowledge, key: "shoutNext" | "prefetchedWhisper" | "whisperActionNext" | "exitCurrentWhisper"): void {
  (player.policy.resolved as any)[key] = key === "exitCurrentWhisper" ? false : null;
  if (key === "prefetchedWhisper") player.action.exchange.prefetchRequested = null;
  for (const patch of player.policy.patches) {
    if (patch.patch && key in patch.patch) delete (patch.patch as any)[key];
  }
}

// ---------------------------------------------------------------------------
// Main policy tick
// ---------------------------------------------------------------------------

export function policyTick(
  ctx: PolicyContext,
  mem: PolicyMemory,
): TaskInstance[] {
  const { player, strategy, bot, events } = ctx;
  let tasks = ctx.tasks;
  const tick = player.tick;

  // Clean stale failure cooldowns
  for (const [target, failTick] of mem.failedTargets) {
    if (tick - failTick > TASK_RETRY_COOLDOWN * 2) mem.failedTargets.delete(target);
  }

  // Track task completions — put targets on cooldown regardless of success/failure
  for (const ev of events.events) {
    if ((ev.kind === "failed" || ev.kind === "succeeded") && "target" in ev.task) {
      const target = (ev.task as any).target as string;
      mem.failedTargets.set(target, ev.tick);
      if (target === mem.currentTarget) {
        mem.exchangePhase = "done";
        mem.currentTarget = null;
        mem.currentExchangeMode = "go_to_player";
        mem.currentExchange = "color";
        mem.prefetchRequested = null;
      }
      if (mem.whisperIntent?.target === target) mem.whisperIntent = null;
    }
  }

  // 1. Ensure baseline loop tasks
  tasks = ensureLoops(tasks, tick, strategy, player);

  // 2. Initialize priority list on new round
  if (player.matchFacts.currentRound !== mem.lastInitRound && player.phase === "playing") {
    mem.lastInitRound = player.matchFacts.currentRound;
    initRoundPriorities(player, strategy, mem);
  }

  // 3. Phase-specific logic
  switch (player.phase) {
    case "playing":
    case "leader_summit":
      mem.lastWhisperActionKey = null;
      tasks = playingPolicy(ctx, tasks, mem);
      break;
    case "whisper":
      tasks = whisperPolicy(ctx, tasks, mem);
      break;
    case "psychopomp_select":
      tasks = psychopompSelectPolicy(ctx, tasks, mem);
      break;
    case "waiting_entry":
      break;
  }

  return tasks;
}

// ---------------------------------------------------------------------------
// Round initialization — build shuffled priority list
// ---------------------------------------------------------------------------

function initRoundPriorities(player: GameKnowledge, strategy: ResolvedPolicy, mem: PolicyMemory): void {
  applyRuleBasedPriorities(player, strategy);
  // Reset exchange state
  mem.currentTarget = null;
  mem.currentExchangeMode = "go_to_player";
  mem.currentExchange = "color";
  mem.exchangePhase = "idle";
  mem.whisperIntent = null;
}

function applyRuleBasedPriorities(player: GameKnowledge, strategy: ResolvedPolicy): void {
  const partner = findKnownKeyPartner(player);
  if (partner) strategy.acceptRoleOffers = true;

  const roleTargets = new Set(strategy.pursueRoleExchangeWithPlayer);
  for (const pb of player.players.values()) {
    if (pb.name === player.myCharName) continue;
    if (shouldRoleExchangeWith(player, pb.name)) {
      roleTargets.add(pb.name);
      strategy.acceptRoleOffers = true;
    }
  }
  strategy.pursueRoleExchangeWithPlayer = Array.from(roleTargets).filter(name => {
    return shouldRoleExchangeWith(player, name);
  });

  const avoid = new Set(strategy.avoidPlayers);
  strategy.pursueColorExchangeWithPlayer = strategy.pursueColorExchangeWithPlayer.filter(name => {
    const pb = player.players.get(name);
    return !!pb && pb.lastRoom === player.myRoom && !hasColorExchangeSucceeded(player, name);
  });
  const current = new Set(strategy.pursueColorExchangeWithPlayer);
  const candidates = Array.from(player.players.values())
    .filter(p => p.name !== player.myCharName)
    .filter(p => !avoid.has(p.name))
    .filter(p => p.lastRoom === player.myRoom)
    .filter(p => !hasColorExchangeSucceeded(player, p.name))
    .filter(p => isVisibleByName(player, p.name))
    .map(p => p.name);

  if (strategy.pursueColorExchangeWithPlayer.length === 0) {
    strategy.pursueColorExchangeWithPlayer = shuffle(candidates);
  } else {
    for (const name of shuffle(candidates)) {
      if (!current.has(name)) strategy.pursueColorExchangeWithPlayer.push(name);
    }
  }
}

// ---------------------------------------------------------------------------
// Loop task management
// ---------------------------------------------------------------------------

function shouldAutoAcceptRoleOffer(strategy: ResolvedPolicy, player: GameKnowledge): boolean {
  if (!strategy.acceptRoleOffers) return false;
  const partnerRole = keyPartnerRole(player.myRole);
  return player.occupantNames.some(name => {
    const pb = player.players.get(name);
    if (!pb) return false;
    if (partnerRole && normalizeRole(pb.knownRole) === partnerRole) return true;
    return isKnownTeammate(player, name);
  });
}

function shouldAutoGrantEntry(strategy: ResolvedPolicy, player: GameKnowledge): boolean {
  if (!strategy.autoGrantEntry) return false;
  if (!player.pendingEntry) return true;
  if (!player.pendingEntryName) return true;
  return !strategy.autoGrantDenyPlayers.includes(player.pendingEntryName);
}

function ensureLoops(
  tasks: TaskInstance[],
  tick: number,
  strategy: ResolvedPolicy,
  player: GameKnowledge,
): TaskInstance[] {
  const autoGrantSafe = shouldAutoGrantEntry(strategy, player);
  if (autoGrantSafe && !hasLoopTask(tasks, "loop_auto_grant")) {
    tasks = [...tasks, createTaskInstance({ kind: "loop_auto_grant" }, tick)];
  }
  if (!autoGrantSafe && hasLoopTask(tasks, "loop_auto_grant")) {
    tasks = tasks.filter(ti => ti.task.kind !== "loop_auto_grant");
  }
  if (strategy.autoAcceptColorOffer && !hasLoopTask(tasks, "loop_auto_accept_color")) {
    tasks = [...tasks, createTaskInstance({ kind: "loop_auto_accept_color" }, tick)];
  }
  if (!strategy.autoAcceptColorOffer && hasLoopTask(tasks, "loop_auto_accept_color")) {
    tasks = tasks.filter(ti => ti.task.kind !== "loop_auto_accept_color");
  }
  if (strategy.keepGlobalCheckActive && !hasLoopTask(tasks, "loop_global_check")) {
    tasks = [...tasks, createTaskInstance({ kind: "loop_global_check", intervalTicks: strategy.globalCheckIntervalTicks }, tick)];
  }
  if (!strategy.keepGlobalCheckActive && hasLoopTask(tasks, "loop_global_check")) {
    tasks = tasks.filter(ti => ti.task.kind !== "loop_global_check");
  }
  const roleAcceptSafe = shouldAutoAcceptRoleOffer(strategy, player);
  if (roleAcceptSafe && !hasLoopTask(tasks, "loop_auto_accept_role")) {
    tasks = [...tasks, createTaskInstance({ kind: "loop_auto_accept_role" }, tick)];
  }
  if (!roleAcceptSafe && hasLoopTask(tasks, "loop_auto_accept_role")) {
    tasks = tasks.filter(ti => ti.task.kind !== "loop_auto_accept_role");
  }
  return tasks;
}

// ---------------------------------------------------------------------------
// Playing phase — exchange loop: shout → walk → whisper → next
// ---------------------------------------------------------------------------

function playingPolicy(
  ctx: PolicyContext,
  tasks: TaskInstance[],
  mem: PolicyMemory,
): TaskInstance[] {
  const { player, strategy } = ctx;
  const tick = player.tick;

  applyRuleBasedPriorities(player, strategy);

  if (tick - mem.lastShoutTick > SHOUT_COOLDOWN_TICKS && !hasOnceTask(tasks, "shout")) {
    const queuedShout = popNextShoutDraft(player);
    if (queuedShout) {
      tasks = [...tasks, createTaskInstance({ kind: "shout", text: queuedShout.text }, tick)];
      if (queuedShout.source === "policy") consumePolicyOneShot(player, "shoutNext");
      mem.lastShoutTick = tick;
    }
  }

  // Fire shoutNext from observer/interpret if available
  if (strategy.shoutNext && tick - mem.lastShoutTick > SHOUT_COOLDOWN_TICKS) {
    if (!hasOnceTask(tasks, "shout")) {
      tasks = [...tasks, createTaskInstance({ kind: "shout", text: strategy.shoutNext }, tick)];
      consumePolicyOneShot(player, "shoutNext");
      mem.lastShoutTick = tick;
    }
  }

  // Don't add new async tasks if one is already running
  if (hasActiveAsync(tasks)) return tasks;

  // Exchange loop state machine
  switch (mem.exchangePhase) {
    case "idle":
    case "done":
      return startNextExchange(ctx, tasks, mem);

    case "shouting":
      // Already shouted, advance to walking
      mem.exchangePhase = "walking";
      return startWalkToTarget(ctx, tasks, mem);

    case "walking":
      // Walk task should be running. If it completed/failed, we're back here.
      // The pursue_exchange task handles walk→whisper→exchange.
      // If no active async, start the pursue.
      return startPursueTarget(ctx, tasks, mem);

    case "whispering":
      // In whisper phase, this won't fire (whisperPolicy handles it)
      return tasks;
  }

  return tasks;
}

function startNextExchange(
  ctx: PolicyContext,
  tasks: TaskInstance[],
  mem: PolicyMemory,
): TaskInstance[] {
  const { player, strategy } = ctx;
  const tick = player.tick;

  // Safe role exchanges are the win path. Once we have a known teammate or key
  // partner candidate, pursue that before gathering more color information.
  const roleTarget = pickNextTarget(strategy.pursueRoleExchangeWithPlayer, player, mem, tick, "role");
  if (roleTarget) {
    mem.currentTarget = roleTarget;
    mem.currentExchangeMode = chooseExchangeMode(player, "role");
    mem.currentExchange = "role";
    mem.exchangeStartTick = tick;
    mem.exchangePhase = "walking";

    const roleHint = strategy.pursueModeHints[`${roleTarget}:role`];
    if (roleHint && tick - roleHint.tick < 240) {
      if (roleHint.mode === "noop") {
        mem.failedTargets.set(roleTarget, tick);
        mem.currentTarget = null;
        mem.exchangePhase = "idle";
        return tasks;
      }
      mem.currentExchangeMode = roleHint.mode;
    }

    tasks = [...tasks, createTaskInstance(
      { kind: "pursue_exchange", target: roleTarget, exchange: "role", timeLimitTicks: EXCHANGE_TIMEOUT_TICKS, mode: mem.currentExchangeMode },
      tick,
    )];
    return tasks;
  }

  // Otherwise gather color/team information from unknown in-room players.
  const colorTarget = pickNextTarget(strategy.pursueColorExchangeWithPlayer, player, mem, tick, "color");
  if (colorTarget) {
    mem.currentTarget = colorTarget;
    mem.currentExchangeMode = chooseExchangeMode(player, "color");
    mem.currentExchange = "color";
    mem.exchangeStartTick = tick;

    const colorHint = strategy.pursueModeHints[`${colorTarget}:color`];
    if (colorHint && tick - colorHint.tick < 240) {
      if (colorHint.mode === "noop") {
        mem.failedTargets.set(colorTarget, tick);
        mem.currentTarget = null;
        mem.exchangePhase = "idle";
        return tasks;
      }
      mem.currentExchangeMode = colorHint.mode;
    }

    // In go_to_player mode, a short shout can pull attention toward the target.
    // In find_spot mode, the task shouts after it reaches its chosen private spot.
    const targetBelief = player.players.get(colorTarget);
    if (mem.currentExchangeMode === "go_to_player" && targetBelief?.lastPos && tick - mem.lastShoutTick > SHOUT_COOLDOWN_TICKS) {
      const msg = `${colorTarget} XCHG?`;
      if (!hasOnceTask(tasks, "shout")) {
        tasks = [...tasks, createTaskInstance({ kind: "shout", text: msg }, tick)];
        mem.lastShoutTick = tick;
      }
      mem.exchangePhase = "shouting";
    } else {
      // No position to announce, go straight to pursuit
      mem.exchangePhase = "walking";
      return startPursueTarget(ctx, tasks, mem);
    }
    return tasks;
  }

  // Fallback: walk toward meetPoint if set, or nearest player
  if (strategy.meetPoint && tick - strategy.meetPoint.tick < 300) {
    tasks = [...tasks, createTaskInstance(
      { kind: "walk_to", x: strategy.meetPoint.x, y: strategy.meetPoint.y, timeLimitTicks: 200 },
      tick,
    )];
    mem.exchangePhase = "walking";
    return tasks;
  }

  // Last resort: pursue nearest unknown player for color exchange
  const nearest = findNearestUnexchangedPlayer(player, strategy, mem, tick);
  if (nearest) {
    mem.currentTarget = nearest;
    mem.currentExchangeMode = chooseExchangeMode(player, "color");
    mem.currentExchange = "color";
    mem.exchangeStartTick = tick;
    mem.exchangePhase = "walking";
    tasks = [...tasks, createTaskInstance(
      { kind: "pursue_exchange", target: nearest, exchange: "color", timeLimitTicks: 400, mode: mem.currentExchangeMode },
      tick,
    )];
    return tasks;
  }

  // Nothing to do — wander
  if (player.myPos) {
    const rx = Math.floor(Math.random() * player.matchFacts.roomW);
    const ry = Math.floor(Math.random() * player.matchFacts.roomH);
    tasks = [...tasks, createTaskInstance(
      { kind: "walk_to", x: rx, y: ry, timeLimitTicks: 120 }, tick,
    )];
  }
  mem.exchangePhase = "idle";
  return tasks;
}

function startWalkToTarget(ctx: PolicyContext, tasks: TaskInstance[], mem: PolicyMemory): TaskInstance[] {
  // Let pursue_exchange handle the walk+whisper+exchange pipeline
  return startPursueTarget(ctx, tasks, mem);
}

function startPursueTarget(ctx: PolicyContext, tasks: TaskInstance[], mem: PolicyMemory): TaskInstance[] {
  const { player, strategy } = ctx;
  const tick = player.tick;
  if (!mem.currentTarget) { mem.exchangePhase = "idle"; return tasks; }
  const currentBelief = player.players.get(mem.currentTarget);
  const currentIsRole = ctx.strategy.pursueRoleExchangeWithPlayer.includes(mem.currentTarget);
  if (currentIsRole) {
    if (!currentBelief || !shouldRoleExchangeWith(player, mem.currentTarget)) {
      mem.exchangePhase = "idle";
      mem.currentTarget = null;
      mem.currentExchangeMode = "go_to_player";
      mem.currentExchange = "color";
      return tasks;
    }
  } else if (hasColorExchangeSucceeded(player, mem.currentTarget)) {
    mem.exchangePhase = "idle";
    mem.currentTarget = null;
    mem.currentExchangeMode = "go_to_player";
    mem.currentExchange = "color";
    return tasks;
  }
  if (strategy.avoidPlayers.includes(mem.currentTarget)) {
    mem.exchangePhase = "idle";
    mem.currentTarget = null;
    mem.currentExchangeMode = "go_to_player";
    mem.currentExchange = "color";
    return tasks;
  }

  tasks = [...tasks, createTaskInstance(
    { kind: "pursue_exchange", target: mem.currentTarget, exchange: mem.currentExchange, timeLimitTicks: EXCHANGE_TIMEOUT_TICKS, mode: mem.currentExchangeMode },
    tick,
  )];
  mem.exchangePhase = "walking";
  return tasks;
}

// ---------------------------------------------------------------------------
// Target picking
// ---------------------------------------------------------------------------

function pickNextTarget(
  targets: string[],
  player: GameKnowledge,
  mem: PolicyMemory,
  tick: number,
  exchange: "role" | "color",
): string | null {
  for (let i = 0; i < targets.length; i++) {
    const target = targets[i];
    if (isTargetOnCooldown(mem, target, tick)) continue;

    const pb = player.players.get(target);
    if (exchange === "color") {
      if (hasColorExchangeSucceeded(player, target)) {
        targets.splice(i, 1);
        i--;
        continue;
      }
    } else {
      if (!pb || !shouldRoleExchangeWith(player, target)) {
        targets.splice(i, 1);
        i--;
        continue;
      }
    }

    const color = colorFromCharName(target);
    if (color === null) continue;
    if (!isReachableInCurrentRoom(player, target)) continue;
    // Check if visible on minimap
    const dot = player.minimapDots.find(d => d.color === color && !d.isSelf);
    if (dot) {
      // Remove from list (consumed) — will re-add on failure
      targets.splice(i, 1);
      return target;
    }
  }
  return null;
}

function findNearestUnexchangedPlayer(
  player: GameKnowledge,
  strategy: ResolvedPolicy,
  mem: PolicyMemory,
  tick: number,
): string | null {
  if (!player.myPos) return null;
  const avoidColors = new Set(
    strategy.avoidPlayers.map(n => colorFromCharName(n)).filter((c): c is number => c !== null)
  );
  let bestDist = Infinity;
  let bestName: string | null = null;
  for (const dot of player.minimapDots) {
    if (dot.isSelf) continue;
    if (avoidColors.has(dot.color)) continue;
    const candidate = Array.from(player.players.values()).find(p => p.color === dot.color);
    if (!candidate) continue;
    if (hasColorExchangeSucceeded(player, candidate.name)) continue; // already exchanged
    if (isTargetOnCooldown(mem, candidate.name, tick)) continue;
    const dx = dot.worldX - player.myPos.x;
    const dy = dot.worldY - player.myPos.y;
    const dist = dx * dx + dy * dy;
    if (dist < bestDist) {
      bestDist = dist;
      bestName = candidate.name;
    }
  }
  return bestName;
}

// ---------------------------------------------------------------------------
// Whisper phase policy
// ---------------------------------------------------------------------------

function whisperPolicy(
  ctx: PolicyContext,
  tasks: TaskInstance[],
  mem: PolicyMemory,
): TaskInstance[] {
  const { player, strategy } = ctx;
  const tick = player.tick;

  // Mark that we're in whisper phase of exchange loop
  if (mem.exchangePhase === "walking") {
    mem.exchangePhase = "whispering";
  }

  const activePursue = tasks.find(ti => ti.task.kind === "pursue_exchange")?.task;
  if (activePursue && activePursue.kind === "pursue_exchange") {
    mem.whisperIntent = {
      target: activePursue.target,
      exchange: activePursue.exchange,
      startedTick: mem.whisperIntent?.target === activePursue.target ? mem.whisperIntent.startedTick : tick,
      lastActionTick: mem.whisperIntent?.target === activePursue.target ? mem.whisperIntent.lastActionTick : tick,
    };
  } else if (mem.whisperIntent && !hasActiveTaskForTarget(tasks, mem.whisperIntent.target)) {
    mem.whisperIntent = null;
  }

  if (!hasOnceTask(tasks, "chat")) {
    const queuedWhisper = popNextWhisperDraft(player, player.occupantNames);
    if (queuedWhisper) {
      tasks = [...tasks, createTaskInstance({ kind: "chat", text: queuedWhisper.text }, tick)];
      if (queuedWhisper.source === "focused_llm") consumePolicyOneShot(player, "prefetchedWhisper");
      if (queuedWhisper.target && mem.whisperIntent?.target === queuedWhisper.target) mem.whisperIntent.lastActionTick = tick;
    }
  }

  // Send prefetched whisper message if target matches an occupant
  if (strategy.prefetchedWhisper) {
    const pf = strategy.prefetchedWhisper;
    const stale = (tick - pf.tick) > STALE_PREFETCH_TICKS;
    const targetInWhisper = player.occupantNames.includes(pf.target);
    if (targetInWhisper && !stale && !hasOnceTask(tasks, "chat")) {
      tasks = [...tasks, createTaskInstance({ kind: "chat", text: pf.message }, tick)];
      consumePolicyOneShot(player, "prefetchedWhisper");
      if (mem.whisperIntent?.target === pf.target) mem.whisperIntent.lastActionTick = tick;
    } else if (stale) {
      consumePolicyOneShot(player, "prefetchedWhisper");
    }
  }

  if (strategy.whisperActionNext && !hasOnceTask(tasks, "whisper_action")) {
    tasks = [...tasks, createTaskInstance({ kind: "whisper_action", action: strategy.whisperActionNext }, tick)];
    consumePolicyOneShot(player, "whisperActionNext");
    if (mem.whisperIntent) mem.whisperIntent.lastActionTick = tick;
  }

  const defaultAction = hasActivePursueExchange(tasks) ? null : defaultWhisperAction(player);
  if (defaultAction && !hasOnceTask(tasks, "whisper_action")) {
    const key = `${defaultAction}:${player.occupantNames.slice().sort().join("|")}`;
    if (mem.lastWhisperActionKey !== key) {
      tasks = [...tasks, createTaskInstance({ kind: "whisper_action", action: defaultAction }, tick)];
      mem.lastWhisperActionKey = key;
      if (mem.whisperIntent) mem.whisperIntent.lastActionTick = tick;
    }
  }

  if (mem.whisperIntent
      && !hasOnceTask(tasks, "chat")
      && !hasOnceTask(tasks, "whisper_action")
      && !hasOnceTask(tasks, "exit_whisper")) {
    const targetHere = player.occupantNames.includes(mem.whisperIntent.target);
    const waited = tick - mem.whisperIntent.lastActionTick;
    if (!targetHere && waited >= WHISPER_DECISION_GRACE_TICKS) {
      tasks = [...tasks, createTaskInstance({ kind: "exit_whisper" }, tick)];
      mem.whisperIntent.lastActionTick = tick;
    }
  }

  // Exit if strategy says so
  if (strategy.exitCurrentWhisper && !hasOnceTask(tasks, "exit_whisper")) {
    tasks = [...tasks, createTaskInstance({ kind: "exit_whisper" }, tick)];
    consumePolicyOneShot(player, "exitCurrentWhisper");
  }

  return tasks;
}

function defaultWhisperAction(player: GameKnowledge): "C.OFFER" | "R.OFFER" | null {
  if (player.occupantNames.length === 0) return null;

  const partnerRole = keyPartnerRole(player.myRole);
  if (partnerRole) {
    const partnerHere = player.occupantNames.some(name => {
      const pb = player.players.get(name);
      return normalizeRole(pb?.knownRole ?? null) === partnerRole && !hasRoleExchangeSucceeded(player, name);
    });
    if (partnerHere) return "R.OFFER";
  }

  const unknownHere = player.occupantNames.some(name => {
    const pb = player.players.get(name);
    return !hasColorExchangeSucceeded(player, name) && !!pb;
  });
  return unknownHere ? "C.OFFER" : null;
}

// ---------------------------------------------------------------------------
// Psychopomp select policy
// ---------------------------------------------------------------------------

function psychopompSelectPolicy(
  ctx: PolicyContext,
  tasks: TaskInstance[],
  mem: PolicyMemory,
): TaskInstance[] {
  const { player, strategy, bot } = ctx;
  const tick = player.tick;

  if (player.amLeader) {
    if (!bot.psychopompPrecommit) {
      if (strategy.psychopompTargets && strategy.psychopompTargets.length > 0) {
        bot.psychopompPrecommit = strategy.psychopompTargets.slice(0, psychopompCount(player));
      } else {
        bot.psychopompPrecommit = pickRandomPsychopomps(player);
      }
    }
  } else {
    if (strategy.shouldUsurp && strategy.usurpTarget && !hasActiveAsync(tasks)) {
      tasks = [...tasks, createTaskInstance(
        { kind: "usurp_vote", target: strategy.usurpTarget, timeLimitTicks: 300 },
        tick,
      )];
    }
  }

  return tasks;
}

function pickRandomPsychopomps(player: GameKnowledge): string[] {
  const myTeam = player.myTeam;
  const inRoom = Array.from(player.players.values()).filter(p =>
    p.lastRoom === player.myRoom && p.name !== player.myCharName
  );
  const keyPartner = findKnownKeyPartner(player)?.name ?? null;
  const safeToSend = inRoom.filter(p => p.name !== keyPartner && !isKnownTeammate(player, p.name));
  const knownEnemies = safeToSend.filter(p => p.knownTeam && p.knownTeam !== myTeam);
  const unknowns = safeToSend.filter(p => !p.knownTeam);
  const fallback = inRoom.filter(p => p.name !== keyPartner);
  const pool = [...shuffle(knownEnemies), ...shuffle(unknowns), ...shuffle(fallback)];
  const seen = new Set<string>();
  const count = psychopompCount(player);
  return pool
    .map(p => p.name)
    .filter(name => {
      if (seen.has(name)) return false;
      seen.add(name);
      return true;
    })
    .slice(0, count);
}

function psychopompCount(player: GameKnowledge): number {
  return psychopompCountForRound(player) ?? 1;
}

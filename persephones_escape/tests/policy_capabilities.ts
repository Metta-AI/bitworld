import assert from "node:assert/strict";
import { HADES_ROLE_NAME, CERBERUS_ROLE_NAME, SHADES_ROLE_NAME, TARGET_FPS, TEAM_A_NAME } from "../game/constants.js";
import { Room, PlayerShape } from "../game/types.js";
import { ActionQueue } from "../bots/bot_utils.js";
import type { BotController } from "../bots/bot_common.js";
import { OodaActuator } from "../bots/ooda_act.js";
import { OodaDecider } from "../bots/ooda_decide.js";
import {
  createGameKnowledge,
  runDeterministicDerivedOrienters,
  writePolicyPatch,
  markColorExchangeSucceeded,
  queueCommunicationDraft,
  type PlayerKnowledge,
  type GameKnowledge,
} from "../bots/game_knowledge.js";

function player(name: string, color: number, shape: PlayerShape, room: Room): PlayerKnowledge {
  return {
    name, color, shape, lastRoom: room,
    lastPos: { x: 20 + color, y: 30 + color },
    lastSeenTick: 1,
    knownRole: null, knownTeam: null,
    isLeader: false, inWhisper: false,
    positionAmbiguousByColor: false,
    weSharedWith: false, theyRevealedCard: false, theyRevealedColor: false,
  };
}

function bot(knowledge: GameKnowledge, overrides?: Partial<BotController>): BotController {
  return {
    ws: { readyState: 1, send: () => {} } as any,
    actions: new ActionQueue(),
    player: knowledge,
    name: knowledge.myCharName ?? "test",
    movementTarget: null,
    wandering: false, wanderTarget: null, wanderTicks: 0,
    lastFrame: null,
    psychopompPrecommit: null,
    lastSentChat: null,
    hasNewIncomingChat: false,
    nonInterruptingTasks: [],
    ...overrides,
  };
}

function makeDecider(knowledge: GameKnowledge, botOverrides?: Partial<BotController>): OodaDecider {
  const b = bot(knowledge, botOverrides);
  return new OodaDecider({
    knowledge,
    bot: b,
    psychopompStatus: () => ({ round: 0, done: true }),
    logEvent: () => {},
  });
}

function decide(knowledge: GameKnowledge, botOverrides?: Partial<BotController>) {
  const d = makeDecider(knowledge, botOverrides);
  return d.decide({ frame: new Uint8Array(128 * 128), roster: null });
}

// ---------------------------------------------------------------------------
// 1. Color exchange pursuit
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("color_exchange_pursuit");
  k.tick = 10;
  k.phase = "playing";
  k.myRoom = Room.RoomA;
  k.myPos = { x: 10, y: 10 };
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.matchFacts.roomW = 100;
  k.matchFacts.roomH = 100;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.minimapDots.push({ color: 14, mx: 2, my: 2, worldX: 34, worldY: 44, isSelf: false });
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(k.action.currentActivity?.kind, "pursue_player");
  if (k.action.currentActivity?.kind === "pursue_player") {
    assert.equal(k.action.currentActivity.target, "B.SQR");
    assert.equal(k.action.currentActivity.mode, "color");
  }
}

// ---------------------------------------------------------------------------
// 2. Failed color targets are cooled down so pursuit rotates
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("color_target_cooldown");
  k.tick = 100;
  k.phase = "playing";
  k.myRoom = Room.RoomA;
  k.myPos = { x: 10, y: 10 };
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.matchFacts.roomW = 100;
  k.matchFacts.roomH = 100;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
  k.minimapDots.push({ color: 14, mx: 2, my: 2, worldX: 34, worldY: 44, isSelf: false });
  k.minimapDots.push({ color: 8, mx: 3, my: 3, worldX: 28, worldY: 38, isSelf: false });
  k.action.exchange.failedTargets.set("Y.TRI", k.tick - 1);
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(k.action.currentActivity?.kind, "pursue_player");
  if (k.action.currentActivity?.kind === "pursue_player") {
    assert.equal(k.action.currentActivity.target, "B.SQR");
    assert.equal(k.action.currentActivity.mode, "color");
  }
}

{
  const k = createGameKnowledge("bad_pursue_targets_are_skipped");
  k.tick = 100;
  k.phase = "playing";
  k.myRoom = Room.RoomA;
  k.myPos = { x: 10, y: 10 };
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.matchFacts.roomW = 100;
  k.matchFacts.roomH = 100;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
  k.minimapDots.push({ color: 14, mx: 2, my: 2, worldX: 12, worldY: 12, isSelf: false });
  k.minimapDots.push({ color: 8, mx: 3, my: 3, worldX: 60, worldY: 60, isSelf: false });
  k.action.exchange.badPursueTargets.set("B.SQR", { tick: k.tick - 1, reason: "target_seen_in_crowd" });
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(k.action.currentActivity?.kind, "pursue_player");
  if (k.action.currentActivity?.kind === "pursue_player") {
    assert.equal(k.action.currentActivity.target, "Y.TRI", "fresh bad target penalty should rotate pursuit");
  }
}

{
  const k = createGameKnowledge("bad_pursue_target_penalty_expires");
  k.tick = 1000;
  k.phase = "playing";
  k.myRoom = Room.RoomA;
  k.myPos = { x: 10, y: 10 };
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.matchFacts.roomW = 100;
  k.matchFacts.roomH = 100;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
  k.minimapDots.push({ color: 14, mx: 2, my: 2, worldX: 12, worldY: 12, isSelf: false });
  k.minimapDots.push({ color: 8, mx: 3, my: 3, worldX: 60, worldY: 60, isSelf: false });
  k.action.exchange.badPursueTargets.set("B.SQR", { tick: k.tick - 20 * TARGET_FPS - 1, reason: "target_seen_in_crowd" });
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(k.action.currentActivity?.kind, "pursue_player");
  if (k.action.currentActivity?.kind === "pursue_player") {
    assert.equal(k.action.currentActivity.target, "B.SQR", "expired bad target penalty should allow nearest target again");
  }
}

// ---------------------------------------------------------------------------
// 3. Color exchange stays ahead of standalone role pursuit
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("role_exchange_pursuit");
  k.tick = 10;
  k.phase = "playing";
  k.myRoom = Room.RoomA;
  k.myPos = { x: 10, y: 10 };
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.myRole = HADES_ROLE_NAME;
  k.myTeam = TEAM_A_NAME;
  k.matchFacts.roomW = 100;
  k.matchFacts.roomH = 100;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  const cerberus = player("B.SQR", 14, PlayerShape.Square, Room.RoomA);
  cerberus.knownRole = CERBERUS_ROLE_NAME;
  k.players.set("B.SQR", cerberus);
  // Also add a color-only target to verify unresolved color discovery is prioritized.
  k.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
  k.minimapDots.push({ color: 14, mx: 2, my: 2, worldX: 34, worldY: 44, isSelf: false });
  k.minimapDots.push({ color: 8, mx: 3, my: 3, worldX: 28, worldY: 38, isSelf: false });
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(k.action.currentActivity?.kind, "pursue_player");
  if (k.action.currentActivity?.kind === "pursue_player") {
    assert.equal(k.action.currentActivity.target, "Y.TRI");
    assert.equal(k.action.currentActivity.mode, "color");
  }
}

// ---------------------------------------------------------------------------
// 3. Avoid players (no exchange, not physical avoidance)
// ---------------------------------------------------------------------------
{
  // Avoid means: don't color/role exchange with them. Verified by ensuring
  // the avoided player is excluded from pursue lists via policy patch.
  const k = createGameKnowledge("avoid_players");
  k.tick = 10;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.pendingColorOffer = true;
  runDeterministicDerivedOrienters(k);
  writePolicyPatch(k, "unit", { avoidPlayers: ["B.SQR"], autoOfferColorDenyPlayers: ["B.SQR"], pursueColorExchangeWithPlayer: [] });
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "C.ACCPT"),
    false,
    "should NOT auto-accept color from avoided player",
  );
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "C.OFFER"),
    false,
    "should NOT offer color exchange to avoided player",
  );
}

// ---------------------------------------------------------------------------
// 4. Auto-accept color offer
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("auto_accept_color");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.pendingColorOffer = true;
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "C.ACCPT"),
    true,
    "should auto-accept color offer from un-exchanged occupant",
  );
}

{
  const k = createGameKnowledge("auto_accept_color_even_when_not_pursuing");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.pendingColorOffer = true;
  runDeterministicDerivedOrienters(k);
  writePolicyPatch(k, "unit", { avoidPlayers: ["B.SQR"], pursueColorExchangeWithPlayer: [] });
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "C.ACCPT"),
    true,
    "pending color offers should be accepted unless explicitly color-denied",
  );
}

// ---------------------------------------------------------------------------
// 5. Auto-accept role offer from teammate
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("auto_grant_entry_when_alone");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.occupantNames = [];
  k.occupantCount = 1;
  k.pendingEntry = true;
  k.pendingEntryName = "B.SQR";
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "GRANT"),
    true,
    "should grant entry when alone in whisper",
  );
}

{
  const k = createGameKnowledge("block_grant_entry_when_whisper_pair_exists");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.pendingEntry = true;
  k.pendingEntryName = "Y.TRI";
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "GRANT"),
    false,
    "should not grant entry once whisper already has self plus one occupant",
  );
}

{
  const k = createGameKnowledge("block_grant_entry_when_visible_occupant_proves_pair");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 1;
  k.pendingEntry = true;
  k.pendingEntryName = "Y.TRI";
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "GRANT"),
    false,
    "should not grant entry when occupant names already show a second participant",
  );
}

{
  const k = createGameKnowledge("activity_blocks_entry_when_whisper_pair_exists");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.pendingEntry = true;
  k.pendingEntryName = "Y.TRI";
  k.action.currentActivity = {
    id: "entry-block",
    kind: "pursue_player",
    startedTick: k.tick - 10,
    lastActiveTick: k.tick - 1,
    timeLimitTicks: 900,
    status: "pursuing B.SQR for color",
    target: "B.SQR",
    mode: "color",
    approach: "go_to_player",
    createdOwnWhisperTick: null,
    enteredWhisperTick: k.tick - 1,
    waitingEntryTick: null,
    grantDeadlineTick: null,
    lastSawTargetTick: k.tick,
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
  runDeterministicDerivedOrienters(k);
  const b = bot(k, { ws: { readyState: 1, send: () => {} } as any });
  const actuator = new OodaActuator({
    ws: b.ws,
    knowledge: k,
    bot: b,
    botName: b.name,
    logEvent: () => {},
  });
  actuator.act({ kind: "run_activity", frame: new Uint8Array(128 * 128) });
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "GRANT"),
    false,
    "pursue activity should not grant a third player into an existing pair",
  );
}

{
  const k = createGameKnowledge("stale_grant_entry_atomic_fails_when_whisper_pair_exists");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.pendingEntry = true;
  k.pendingEntryName = "Y.TRI";
  k.action.atomQueue.push({ kind: "whisper_action", action: "GRANT", label: "grant_entry" });
  const b = bot(k, { ws: { readyState: 1, send: () => {} } as any });
  const actuator = new OodaActuator({
    ws: b.ws,
    knowledge: k,
    bot: b,
    botName: b.name,
    logEvent: () => {},
  });
  actuator.act({ kind: "run_activity", frame: new Uint8Array(128 * 128) });
  assert.equal(k.action.atomQueue.length, 0, "stale grant_entry atomic should fail and be removed");
}

{
  const k = createGameKnowledge("waiting_entry_times_out_quickly");
  k.tick = 300;
  k.phase = "waiting_entry";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  const target = player("B.SQR", 14, PlayerShape.Square, Room.RoomA);
  target.inWhisper = true;
  k.players.set("B.SQR", target);
  k.action.currentActivity = {
    id: "entry-timeout",
    kind: "pursue_player",
    startedTick: k.tick - 160,
    lastActiveTick: k.tick - 1,
    timeLimitTicks: 900,
    status: "waiting for entry",
    target: "B.SQR",
    mode: "color",
    approach: "go_to_player",
    createdOwnWhisperTick: null,
    enteredWhisperTick: null,
    waitingEntryTick: k.tick - 5 * TARGET_FPS - 1,
    grantDeadlineTick: null,
    lastSawTargetTick: k.tick,
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
  const b = bot(k, { ws: { readyState: 1, send: () => {} } as any });
  const actuator = new OodaActuator({
    ws: b.ws,
    knowledge: k,
    bot: b,
    botName: b.name,
    logEvent: () => {},
  });
  actuator.act({ kind: "run_activity", frame: new Uint8Array(128 * 128) });
  assert.equal(k.action.currentActivity, null, "entry wait timeout should finish pursue activity");
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "input" && a.label === "pursue_cancel_waiting_entry"),
    true,
    "entry wait timeout should queue cancel input",
  );
}

{
  const k = createGameKnowledge("target_in_conversation_retargets");
  k.tick = 300;
  k.phase = "playing";
  k.myRoom = Room.RoomA;
  k.myPos = { x: 20, y: 20 };
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.matchFacts.roomW = 100;
  k.matchFacts.roomH = 100;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  const target = player("B.SQR", 14, PlayerShape.Square, Room.RoomA);
  target.inWhisper = true;
  target.lastPos = { x: 45, y: 45 };
  target.lastSeenTick = k.tick;
  k.players.set("B.SQR", target);
  k.minimapDots.push({ color: 14, mx: 2, my: 2, worldX: 45, worldY: 45, isSelf: false });
  k.action.currentActivity = {
    id: "target-in-convo",
    kind: "pursue_player",
    startedTick: k.tick - 10,
    lastActiveTick: k.tick - 1,
    timeLimitTicks: 900,
    status: "pursuing B.SQR for color",
    target: "B.SQR",
    mode: "color",
    approach: "go_to_player",
    createdOwnWhisperTick: null,
    enteredWhisperTick: null,
    waitingEntryTick: null,
    grantDeadlineTick: null,
    lastSawTargetTick: k.tick,
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
  const b = bot(k, { ws: { readyState: 1, send: () => {} } as any });
  const actuator = new OodaActuator({
    ws: b.ws,
    knowledge: k,
    bot: b,
    botName: b.name,
    logEvent: () => {},
  });
  actuator.act({ kind: "run_activity", frame: new Uint8Array(128 * 128) });
  assert.equal(k.action.currentActivity, null, "target already in a conversation should finish/retarget pursue");
  assert.equal(k.action.exchange.badPursueTargets.get("B.SQR")?.reason, "target_already_in_conversation");
  assert.equal(k.action.exchange.failedTargets.has("B.SQR"), false, "conversation retarget should use short bad-target penalty, not broad failure cooldown");
}

{
  const k = createGameKnowledge("host_escape_when_nearby_whisper_blocks_open");
  k.tick = 300;
  k.phase = "playing";
  k.myRoom = Room.RoomA;
  k.myPos = { x: 20, y: 20 };
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.matchFacts.roomW = 100;
  k.matchFacts.roomH = 100;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  const target = player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA);
  target.lastPos = { x: 22, y: 22 };
  target.lastSeenTick = k.tick;
  k.players.set("Y.TRI", target);
  const blocker = player("B.SQR", 14, PlayerShape.Square, Room.RoomA);
  blocker.inWhisper = true;
  blocker.lastPos = { x: 18, y: 18 };
  blocker.lastSeenTick = k.tick;
  k.players.set("B.SQR", blocker);
  k.nearbyNames = ["Y.TRI", "B.SQR"];
  k.minimapDots.push({ color: 8, mx: 2, my: 2, worldX: 22, worldY: 22, isSelf: false });
  k.minimapDots.push({ color: 14, mx: 3, my: 3, worldX: 18, worldY: 18, isSelf: false });
  k.action.currentActivity = {
    id: "blocked-open",
    kind: "pursue_player",
    startedTick: k.tick - 10,
    lastActiveTick: k.tick - 1,
    timeLimitTicks: 900,
    status: "pursuing Y.TRI for color",
    target: "Y.TRI",
    mode: "color",
    approach: "go_to_player",
    createdOwnWhisperTick: null,
    enteredWhisperTick: null,
    waitingEntryTick: null,
    grantDeadlineTick: null,
    lastSawTargetTick: k.tick,
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
  const b = bot(k, { ws: { readyState: 1, send: () => {} } as any });
  const actuator = new OodaActuator({
    ws: b.ws,
    knowledge: k,
    bot: b,
    botName: b.name,
    logEvent: () => {},
  });
  actuator.act({ kind: "run_activity", frame: new Uint8Array(128 * 128) });
  assert.equal(k.action.currentActivity?.kind, "pursue_player", "initial blocked host should try to escape before failing");
  assert.equal(
    k.action.currentActivity?.kind === "pursue_player" && k.action.currentActivity.clusterEscapeStartTick !== null,
    true,
    "nearby active whisper should start escape behavior instead of open-whisper spam",
  );
}

// ---------------------------------------------------------------------------
// 6. Auto-accept role offer from teammate
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("accept_role_teammate");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.myRole = HADES_ROLE_NAME;
  k.myTeam = TEAM_A_NAME;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  const cerberus = player("B.SQR", 14, PlayerShape.Square, Room.RoomA);
  cerberus.knownRole = CERBERUS_ROLE_NAME;
  cerberus.knownTeam = TEAM_A_NAME;
  k.players.set("B.SQR", cerberus);
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.pendingRoleOffer = true;
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "R.ACCPT"),
    true,
    "should auto-accept role offer from known key partner",
  );
}

// ---------------------------------------------------------------------------
// 6. Reject role offer from non-teammate
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("reject_role_unknown");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.myRole = HADES_ROLE_NAME;
  k.myTeam = TEAM_A_NAME;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.pendingRoleOffer = true;
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "R.ACCPT"),
    false,
    "should NOT accept role offer from unknown player",
  );
}

// ---------------------------------------------------------------------------
// 7. Accept leader offer (Shade — default on)
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("accept_leader_shade");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.myRole = SHADES_ROLE_NAME;
  k.myTeam = TEAM_A_NAME;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.pendingLeaderOffer = true;
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "TAKE"),
    true,
    "Shade should accept leader offers by default",
  );
}

// ---------------------------------------------------------------------------
// 8. Reject leader offer (Hades — default off)
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("reject_leader_hades");
  k.tick = 55;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.myRole = HADES_ROLE_NAME;
  k.myTeam = TEAM_A_NAME;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.pendingLeaderOffer = true;
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "TAKE"),
    false,
    "Hades should NOT accept leader offers by default",
  );
}

// ---------------------------------------------------------------------------
// 9. Psychopomp select — leader commits policy targets immediately
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("psychopomp_leader_commit");
  k.tick = 65;
  k.phase = "psychopomp_select";
  k.prevPhase = "playing";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.amLeader = true;
  k.matchFacts.currentRound = 1;
  k.matchFacts.psychopompSelectTimerSecs = 10;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.action.psychopompPrecommit = ["B.SQR"];
  writePolicyPatch(k, "unit", { psychopompTargets: ["B.SQR"] });
  const decision = decide(k, { psychopompPrecommit: ["B.SQR"] });
  assert.equal(decision.kind, "psychopomp_precommit", "leader with policy targets should commit immediately");
}

// ---------------------------------------------------------------------------
// 10. Psychopomp select — non-leader usurps
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("non_leader_usurp");
  k.tick = 60;
  k.phase = "playing";
  k.myRoom = Room.RoomA;
  k.myPos = { x: 10, y: 10 };
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.amLeader = false;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.minimapDots.push({ color: 14, mx: 2, my: 2, worldX: 34, worldY: 44, isSelf: false });
  writePolicyPatch(k, "unit", { shouldUsurp: true, usurpTarget: "B.SQR" });
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "usurp_vote" && a.target === "B.SQR"),
    true,
    "non-leader with shouldUsurp should queue usurp_vote",
  );
}

// ---------------------------------------------------------------------------
// 11. Shout cooldown
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("shout_cooldown");
  k.tick = 100;
  k.phase = "playing";
  k.myRoom = Room.RoomA;
  k.myPos = { x: 10, y: 10 };
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.matchFacts.roomW = 100;
  k.matchFacts.roomH = 100;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.action.exchange.lastShoutTick = 100;
  queueCommunicationDraft(k, { channel: "shout", target: null, text: "HELLO", source: "unit" });
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "chat" && a.label === "shout"),
    false,
    "shout should be suppressed during cooldown",
  );

  k.action.atomQueue = [];
  k.tick = 300;
  queueCommunicationDraft(k, { channel: "shout", target: null, text: "HELLO2", source: "unit" });
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "chat" && a.label === "shout"),
    true,
    "shout should fire after cooldown expires",
  );
}

// ---------------------------------------------------------------------------
// 12. Whisper prefetch consumption
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("whisper_prefetch");
  k.tick = 50;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  writePolicyPatch(k, "unit", {
    prefetchedWhisper: { target: "B.SQR", message: "hello friend", tick: k.tick },
  });
  runDeterministicDerivedOrienters(k);
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "chat" && (a as any).text?.includes("hello friend")),
    true,
    "prefetched whisper should be queued as chat atom",
  );
}

// ---------------------------------------------------------------------------
// 13. Exit whisper on policy signal
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("exit_whisper_signal");
  k.tick = 50;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  writePolicyPatch(k, "unit", { exitCurrentWhisper: true });
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "EXIT"),
    true,
    "exitCurrentWhisper should queue EXIT action",
  );
}

// ---------------------------------------------------------------------------
// 14. Global check suppression during psychopomp select for leaders
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("global_check_suppression");
  k.tick = 200;
  k.phase = "psychopomp_select";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.amLeader = true;
  k.matchFacts.currentRound = 1;
  k.matchFacts.psychopompSelectTimerSecs = 10;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.action.lastGlobalCheckTick = 0;
  runDeterministicDerivedOrienters(k);
  // psychopompPrecommit null so selector doesn't fire, but we reach reactive atomics
  decide(k);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "info_check"),
    false,
    "info check should be suppressed during psychopomp select for leaders",
  );
}

// ---------------------------------------------------------------------------
// 15. Color exchange auto-upgrades to role exchange with teammates
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("color_xchg_auto_upgrade_role");
  k.tick = 100;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.myTeam = TEAM_A_NAME;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  const teammate = player("B.SQR", 14, PlayerShape.Square, Room.RoomA);
  teammate.knownTeam = TEAM_A_NAME;
  teammate.theyRevealedColor = true;
  k.players.set("B.SQR", teammate);
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.action.exchange.roleFollowupUntilTick = k.tick + 20 * 24;
  k.action.currentActivity = {
    id: "auto-upgrade",
    kind: "pursue_player",
    startedTick: k.tick - 10,
    lastActiveTick: k.tick - 1,
    timeLimitTicks: 900,
    status: "pursuing B.SQR for color",
    target: "B.SQR",
    mode: "color",
    approach: "go_to_player",
    createdOwnWhisperTick: null,
    enteredWhisperTick: null,
    waitingEntryTick: null,
    grantDeadlineTick: null,
    lastSawTargetTick: k.tick,
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
  runDeterministicDerivedOrienters(k);

  const sent: Buffer[] = [];
  const b = bot(k, {
    ws: { readyState: 1, send: (msg: unknown) => { if (Buffer.isBuffer(msg)) sent.push(msg); } } as any,
  });
  const actuator = new OodaActuator({
    ws: b.ws,
    knowledge: k,
    bot: b,
    botName: b.name,
    logEvent: () => {},
  });
  const decision = { kind: "run_activity" as const, frame: new Uint8Array(128 * 128) };

  actuator.act(decision);
  assert.equal(k.action.currentActivity?.kind, "pursue_player");
  if (k.action.currentActivity?.kind === "pursue_player") {
    assert.equal(k.action.currentActivity.mode, "role", "color activity should auto-upgrade to role");
    assert.equal(k.action.currentActivity.target, "B.SQR");
  }

  k.tick++;
  actuator.act(decision);
  assert.equal(k.action.currentActivity?.kind, "pursue_player");
  if (k.action.currentActivity?.kind === "pursue_player") {
    assert.equal(k.action.currentActivity.conversationMessageSentTick, k.tick);
  }

  k.tick++;
  actuator.act(decision);
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "R.OFFER" && a.label === "role_offer"),
    true,
    "R.OFFER should be queued as a state-aware role_offer whisper action",
  );
}

// ---------------------------------------------------------------------------
// 16. Forced info checks keep the current whisper open after exchange success
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("forced_info_before_exit");
  k.tick = 120;
  k.phase = "whisper";
  k.myRoom = Room.RoomA;
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.myTeam = TEAM_A_NAME;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  k.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
  k.occupantNames = ["B.SQR"];
  k.occupantCount = 2;
  k.action.forceInfoCheck = true;
  k.action.atomQueue.push({ kind: "whisper_action", action: "EXIT", label: "no_exchange_needed" });
  runDeterministicDerivedOrienters(k);

  decide(k);

  assert.equal(k.action.atomQueue[0]?.kind, "info_check", "forced info check should run before leaving whisper");
  assert.equal(
    k.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "EXIT"),
    false,
    "stale whisper exits should be cancelled while exchange follow-up info is pending",
  );
}

// ---------------------------------------------------------------------------
// 17. Meet point walk
// ---------------------------------------------------------------------------
{
  const k = createGameKnowledge("meet_point_walk");
  k.tick = 70;
  k.phase = "playing";
  k.myRoom = Room.RoomA;
  k.myPos = { x: 5, y: 5 };
  k.myCharName = "R.CRCL";
  k.myColor = 3;
  k.myShape = PlayerShape.Circle;
  k.matchFacts.roomW = 100;
  k.matchFacts.roomH = 100;
  k.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
  writePolicyPatch(k, "unit", { meetPoint: { x: 50, y: 50, reason: "test meet", tick: k.tick } });
  decide(k);
  assert.equal(k.action.currentActivity?.kind, "walk_to");
  if (k.action.currentActivity?.kind === "walk_to") {
    assert.equal(k.action.currentActivity.openWhisperOnArrive, true);
  }
}

console.log("policy_capabilities ok");

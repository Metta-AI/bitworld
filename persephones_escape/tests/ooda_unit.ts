import assert from "node:assert/strict";
import { HADES_ROLE_NAME, CERBERUS_ROLE_NAME, TEAM_A_NAME, TARGET_FPS } from "../game/constants.js";
import { Room, PlayerShape } from "../game/types.js";
import { ActionQueue } from "../bots/bot_utils.js";
import type { BotController } from "../bots/bot_common.js";
import { policyTick } from "../bots/default_policy.js";
import { OodaActuator } from "../bots/ooda_act.js";
import { OodaDecider } from "../bots/ooda_decide.js";
import {
  createGameKnowledge,
  chooseDeterministicPsychopompTargets,
  hasColorExchangeSucceeded,
  markColorExchangeSucceeded,
  queueCommunicationDraft,
  runDeterministicDerivedOrienters,
  writePolicyPatch,
  type PlayerKnowledge,
} from "../bots/game_knowledge.js";
import { createEventBuffer } from "../bots/tasks.js";

function player(name: string, color: number, shape: PlayerShape, room: Room): PlayerKnowledge {
  return {
    name,
    color,
    shape,
    lastRoom: room,
    lastPos: { x: 20 + color, y: 30 + color },
    lastSeenTick: 1,
    knownRole: null,
    knownTeam: null,
    isLeader: false,
    inWhisper: false,
    positionAmbiguousByColor: false,
    weSharedWith: false,
    theyRevealedCard: false,
    theyRevealedColor: false,
  };
}

const knowledge = createGameKnowledge("llm_test");
knowledge.tick = 10;
knowledge.myRoom = Room.RoomA;
knowledge.myCharName = "R.CRCL";
knowledge.myColor = 3;
knowledge.myShape = PlayerShape.Circle;
knowledge.matchFacts.roomW = 100;
knowledge.matchFacts.roomH = 100;
knowledge.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
knowledge.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
knowledge.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomB));

knowledge.shoutLog.push({ tick: 10, senderColor: 14, text: "MEET @ 42,55" });
runDeterministicDerivedOrienters(knowledge);
assert.equal(knowledge.messages.rendezvousOffers.length, 1);
assert.deepEqual(knowledge.policy.resolved.meetPoint, {
  x: 42,
  y: 55,
  reason: "rendezvous with B.SQR",
  tick: 10,
});

knowledge.shoutLog.push({ tick: 11, senderColor: 14, text: "Y.TRI COME @ 10,10" });
knowledge.tick = 11;
runDeterministicDerivedOrienters(knowledge);
assert.equal(
  knowledge.messages.rendezvousOffers.some(o => o.sourceText.includes("Y.TRI")),
  false,
  "out-of-room intended targets are rejected",
);
knowledge.shoutLog.push({ tick: 12, senderColor: 14, text: "<12,13>" });
knowledge.tick = 12;
runDeterministicDerivedOrienters(knowledge);
assert.equal(
  knowledge.messages.rendezvousOffers.some(o => o.coords.x === 12 && o.coords.y === 13),
  true,
  "angle-bracket coordinates create rendezvous offers",
);

const accepted = writePolicyPatch(knowledge, "unit", {
  pursueColorExchangeWithPlayer: ["B.SQR", "NOPE"],
  psychopompTargets: ["B.SQR", "Y.TRI"],
  shoutNext: "B.SQR COME @ 42,55",
  usurpTarget: "NOPE",
});
assert.equal(accepted, true);
assert.equal(knowledge.policy.resolved.pursueColorExchangeWithPlayer.includes("B.SQR"), true);
assert.equal(knowledge.policy.resolved.pursueColorExchangeWithPlayer.includes("NOPE"), false);
assert.deepEqual(knowledge.policy.resolved.psychopompTargets, ["B.SQR"]);
assert.equal(knowledge.policy.resolved.shoutNext, "B.SQR COME @ 42,55");
assert.equal(knowledge.policy.resolved.usurpTarget, "R.CRCL");

const fallbackPsychopomps = createGameKnowledge("llm_psychopomp_fallback");
fallbackPsychopomps.myRoom = Room.RoomA;
fallbackPsychopomps.myCharName = "R.CRCL";
fallbackPsychopomps.matchFacts.currentRound = 1;
fallbackPsychopomps.matchFacts.rounds = [{ round: 1, durationSecs: 60, psychopomps: 2 }];
fallbackPsychopomps.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
fallbackPsychopomps.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
fallbackPsychopomps.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
fallbackPsychopomps.players.set("G.CRCL", player("G.CRCL", 11, PlayerShape.Circle, Room.RoomA));
fallbackPsychopomps.players.set("P.STAR", player("P.STAR", 13, PlayerShape.Star, Room.RoomA));
assert.deepEqual(chooseDeterministicPsychopompTargets(fallbackPsychopomps), ["G.CRCL", "B.SQR"]);

const winPath = createGameKnowledge("llm_win_path");
winPath.tick = 20;
winPath.phase = "playing";
winPath.myRoom = Room.RoomA;
winPath.myPos = { x: 10, y: 10 };
winPath.myCharName = "R.CRCL";
winPath.myColor = 3;
winPath.myShape = PlayerShape.Circle;
winPath.myRole = HADES_ROLE_NAME;
winPath.myTeam = TEAM_A_NAME;
winPath.matchFacts.currentRound = 1;
winPath.matchFacts.roomW = 100;
winPath.matchFacts.roomH = 100;
winPath.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
const cerberus = player("B.SQR", 14, PlayerShape.Square, Room.RoomA);
cerberus.knownRole = CERBERUS_ROLE_NAME;
cerberus.lastPos = { x: 14, y: 10 };
winPath.players.set("B.SQR", cerberus);
winPath.minimapDots.push({ color: 14, mx: 1, my: 1, worldX: 14, worldY: 10, isSelf: false });
runDeterministicDerivedOrienters(winPath);
assert.deepEqual(winPath.policy.resolved.pursueRoleExchangeWithPlayer, ["B.SQR"]);

const mockBot: BotController = {
  ws: { readyState: 1, send: () => {} } as any,
  actions: new ActionQueue(),
  player: winPath,
  name: "llm_win_path",
  movementTarget: null,
  wandering: false,
  wanderTarget: null,
  wanderTicks: 0,
  lastFrame: null,
  psychopompPrecommit: [],
  lastSentChat: null,
  hasNewIncomingChat: false,
  nonInterruptingTasks: [],
};
const tasks = policyTick(
  { player: winPath, strategy: winPath.policy.resolved, bot: mockBot, tasks: [], events: createEventBuffer() },
  winPath.action.exchange,
);
assert.equal(tasks.some(t => t.task.kind === "pursue_exchange" && t.task.exchange === "role" && t.task.target === "B.SQR"), true);

const comm = createGameKnowledge("llm_comm");
comm.tick = 30;
comm.phase = "playing";
comm.myRoom = Room.RoomA;
comm.myPos = { x: 10, y: 10 };
comm.myCharName = "R.CRCL";
comm.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
comm.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
assert.equal(queueCommunicationDraft(comm, { channel: "shout", target: "B.SQR", text: "B.SQR XCHG?", source: "unit" }), true);
const shoutTasks = policyTick(
  { player: comm, strategy: comm.policy.resolved, bot: { ...mockBot, player: comm, actions: new ActionQueue(), nonInterruptingTasks: [] }, tasks: [], events: createEventBuffer() },
  comm.action.exchange,
);
assert.equal(shoutTasks.some(t => t.task.kind === "shout" && t.task.text === "B.SQR XCHG?"), true);

const whisper = createGameKnowledge("llm_whisper");
whisper.tick = 40;
whisper.phase = "whisper";
whisper.myRoom = Room.RoomA;
whisper.myCharName = "R.CRCL";
whisper.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
whisper.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
whisper.occupantNames = ["B.SQR"];
whisper.occupantCount = 2;
assert.equal(queueCommunicationDraft(whisper, { channel: "whisper", target: "B.SQR", text: "MEET @ 12,13", source: "unit" }), true);
const chatTasks = policyTick(
  { player: whisper, strategy: whisper.policy.resolved, bot: { ...mockBot, player: whisper, actions: new ActionQueue(), nonInterruptingTasks: [] }, tasks: [], events: createEventBuffer() },
  whisper.action.exchange,
);
assert.equal(chatTasks.some(t => t.task.kind === "chat" && t.task.text === "MEET @ 12,13"), true);

const dupe = createGameKnowledge("llm_no_dupe");
dupe.tick = 50;
dupe.phase = "whisper";
dupe.myRoom = Room.RoomA;
dupe.myCharName = "R.CRCL";
dupe.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
dupe.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
dupe.occupantNames = ["B.SQR"];
dupe.occupantCount = 2;
markColorExchangeSucceeded(dupe, "B.SQR", "unit");
assert.equal(hasColorExchangeSucceeded(dupe, "B.SQR"), true);
const noDupeTasks = policyTick(
  { player: dupe, strategy: dupe.policy.resolved, bot: { ...mockBot, player: dupe, actions: new ActionQueue(), nonInterruptingTasks: [] }, tasks: [], events: createEventBuffer() },
  dupe.action.exchange,
);
assert.equal(noDupeTasks.some(t => t.task.kind === "whisper_action" && t.task.action === "C.OFFER"), false);

const autoAcceptColor = createGameKnowledge("llm_auto_accept_color");
autoAcceptColor.tick = 55;
autoAcceptColor.phase = "whisper";
autoAcceptColor.myRoom = Room.RoomA;
autoAcceptColor.myCharName = "R.CRCL";
autoAcceptColor.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
autoAcceptColor.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomB));
autoAcceptColor.occupantNames = ["B.SQR"];
autoAcceptColor.occupantCount = 2;
autoAcceptColor.pendingColorOffer = true;
runDeterministicDerivedOrienters(autoAcceptColor);
assert.equal(
  autoAcceptColor.policy.resolved.pursueColorExchangeWithPlayer.includes("B.SQR"),
  true,
  "color precommitment should default to every non-denied known player, even if room facts are stale",
);
const autoAcceptDecider = new OodaDecider({
  knowledge: autoAcceptColor,
  bot: { ...mockBot, player: autoAcceptColor, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: null },
  psychopompStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
autoAcceptDecider.decide({ frame: new Uint8Array(128 * 128), roster: null });
assert.equal(
  autoAcceptColor.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "C.ACCPT" && a.label === "accept_color"),
  true,
  "auto-accept color should accept pending offers from occupants covered by default color precommitment",
);

const autoAcceptCancelsOffer = createGameKnowledge("llm_auto_accept_cancels_offer");
autoAcceptCancelsOffer.tick = 56;
autoAcceptCancelsOffer.phase = "whisper";
autoAcceptCancelsOffer.myRoom = Room.RoomA;
autoAcceptCancelsOffer.myCharName = "R.CRCL";
autoAcceptCancelsOffer.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
autoAcceptCancelsOffer.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
autoAcceptCancelsOffer.occupantNames = ["B.SQR"];
autoAcceptCancelsOffer.occupantCount = 2;
autoAcceptCancelsOffer.pendingColorOffer = true;
autoAcceptCancelsOffer.action.atomQueue.push({ kind: "whisper_action", action: "C.OFFER", label: "reactive_color_offer" });
runDeterministicDerivedOrienters(autoAcceptCancelsOffer);
const autoAcceptCancelsDecider = new OodaDecider({
  knowledge: autoAcceptCancelsOffer,
  bot: { ...mockBot, player: autoAcceptCancelsOffer, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: null },
  psychopompStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
autoAcceptCancelsDecider.decide({ frame: new Uint8Array(128 * 128), roster: null });
assert.equal(
  autoAcceptCancelsOffer.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "C.OFFER"),
  false,
  "pending color offer should cancel queued color offers instead of offering back",
);
assert.equal(
  autoAcceptCancelsOffer.action.atomQueue[0]?.kind === "whisper_action"
    && autoAcceptCancelsOffer.action.atomQueue[0].action === "C.ACCPT",
  true,
  "pending color offer should queue accept before any follow-up atomics",
);

const groupColorExchange = createGameKnowledge("llm_group_color_xchg");
groupColorExchange.tick = 58;
groupColorExchange.phase = "whisper";
groupColorExchange.myRoom = Room.RoomA;
groupColorExchange.myCharName = "R.CRCL";
groupColorExchange.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
groupColorExchange.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
groupColorExchange.occupantNames = ["B.SQR"];
groupColorExchange.occupantCount = 2;
groupColorExchange.action.lastGlobalCheckTick = groupColorExchange.tick;
groupColorExchange.whisperMessages.push({ type: "system", senderColor: 0, senderShape: null, text: "COLOR XCHG:" });
runDeterministicDerivedOrienters(groupColorExchange);
assert.equal(hasColorExchangeSucceeded(groupColorExchange, "B.SQR"), true);
assert.ok(
  groupColorExchange.action.exchange.roleFollowupUntilTick >= groupColorExchange.tick + 20 * 24,
  "group color exchange should leave a long role-followup window",
);
assert.equal(groupColorExchange.action.lastGlobalCheckTick, -Infinity);
assert.equal(groupColorExchange.action.forceInfoCheck, true);

const unattributedGroupColorExchange = createGameKnowledge("llm_multi_color_xchg");
unattributedGroupColorExchange.tick = 58;
unattributedGroupColorExchange.phase = "whisper";
unattributedGroupColorExchange.myRoom = Room.RoomA;
unattributedGroupColorExchange.myCharName = "R.CRCL";
unattributedGroupColorExchange.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
unattributedGroupColorExchange.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
unattributedGroupColorExchange.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
unattributedGroupColorExchange.occupantNames = ["B.SQR", "Y.TRI"];
unattributedGroupColorExchange.occupantCount = 3;
unattributedGroupColorExchange.whisperMessages.push({ type: "system", senderColor: 0, senderShape: null, text: "COLOR XCHG:" });
runDeterministicDerivedOrienters(unattributedGroupColorExchange);
assert.equal(
  hasColorExchangeSucceeded(unattributedGroupColorExchange, "B.SQR"),
  false,
  "unattributed multi-occupant color exchange should not mark every occupant as done",
);
assert.equal(hasColorExchangeSucceeded(unattributedGroupColorExchange, "Y.TRI"), false);
assert.equal(unattributedGroupColorExchange.action.forceInfoCheck, true);

const roleShowed = createGameKnowledge("llm_role_showed");
roleShowed.tick = 59;
roleShowed.phase = "whisper";
roleShowed.myRoom = Room.RoomA;
roleShowed.myCharName = "R.CRCL";
roleShowed.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
roleShowed.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
roleShowed.occupantNames = ["B.SQR"];
roleShowed.occupantCount = 2;
roleShowed.whisperMessages.push({ type: "system", senderColor: 14, senderShape: PlayerShape.Square, text: "B.SQR showed role" });
runDeterministicDerivedOrienters(roleShowed);
assert.equal(roleShowed.players.get("B.SQR")?.theyRevealedCard, true);
assert.equal(roleShowed.action.forceInfoCheck, true, "visible role-show system message should force one info check");

const v2 = createGameKnowledge("llm_v2");
v2.tick = 60;
v2.phase = "playing";
v2.myRoom = Room.RoomA;
v2.myCharName = "R.CRCL";
v2.amLeader = false;
v2.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
v2.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
writePolicyPatch(v2, "unit", { shouldUsurp: true, usurpTarget: "B.SQR" });
const v2Bot = { ...mockBot, player: v2, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: null };
const decider = new OodaDecider({
  knowledge: v2,
  bot: v2Bot,
  psychopompStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
const decision = decider.decide({ frame: new Uint8Array(128 * 128), roster: null });
assert.equal(decision.kind, "run_activity");
assert.equal(v2.action.atomQueue.some(a => a.kind === "usurp_vote" && a.target === "B.SQR"), true);

const defaultUsurp = createGameKnowledge("llm_default_usurp");
defaultUsurp.tick = 62;
defaultUsurp.phase = "playing";
defaultUsurp.myRoom = Room.RoomA;
defaultUsurp.myCharName = "R.CRCL";
defaultUsurp.amLeader = false;
defaultUsurp.matchFacts.currentRound = 1;
defaultUsurp.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
defaultUsurp.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
runDeterministicDerivedOrienters(defaultUsurp);
assert.equal(defaultUsurp.policy.resolved.shouldUsurp, true);
assert.equal(defaultUsurp.policy.resolved.usurpTarget, "R.CRCL");
const defaultUsurpDecider = new OodaDecider({
  knowledge: defaultUsurp,
  bot: { ...mockBot, player: defaultUsurp, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: null },
  psychopompStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
defaultUsurpDecider.decide({ frame: new Uint8Array(128 * 128), roster: null });
assert.equal(
  defaultUsurp.action.atomQueue.some(a => a.kind === "usurp_vote" && a.target === "R.CRCL"),
  true,
  "deterministic baseline should queue a self usurp vote by default",
);

const psychopompEarly = createGameKnowledge("llm_psychopomp_early");
psychopompEarly.tick = 65;
psychopompEarly.phase = "psychopomp_select";
psychopompEarly.prevPhase = "playing";
psychopompEarly.myRoom = Room.RoomA;
psychopompEarly.myCharName = "R.CRCL";
psychopompEarly.amLeader = true;
psychopompEarly.matchFacts.currentRound = 1;
psychopompEarly.matchFacts.psychopompSelectTimerSecs = 10;
psychopompEarly.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
psychopompEarly.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
psychopompEarly.action.psychopompPrecommit = ["B.SQR"];
const psychopompEarlyBot = { ...mockBot, player: psychopompEarly, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: psychopompEarly.action.psychopompPrecommit };
const psychopompEarlyDecider = new OodaDecider({
  knowledge: psychopompEarly,
  bot: psychopompEarlyBot,
  psychopompStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
assert.equal(
  psychopompEarlyDecider.decide({ frame: new Uint8Array(128 * 128), roster: null }).kind,
  "run_activity",
  "fallback psychopomp precommit should not commit immediately at psychopomp-select start",
);

writePolicyPatch(psychopompEarly, "unit", { psychopompTargets: ["B.SQR"] });
assert.equal(
  psychopompEarlyDecider.decide({ frame: new Uint8Array(128 * 128), roster: null }).kind,
  "psychopomp_precommit",
  "policy psychopomp precommit can execute immediately",
);

const psychopompLate = createGameKnowledge("llm_psychopomp_late");
psychopompLate.tick = 66;
psychopompLate.phase = "psychopomp_select";
psychopompLate.prevPhase = "playing";
psychopompLate.myRoom = Room.RoomA;
psychopompLate.myCharName = "R.CRCL";
psychopompLate.amLeader = true;
psychopompLate.matchFacts.currentRound = 1;
psychopompLate.matchFacts.psychopompSelectTimerSecs = 2;
psychopompLate.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
psychopompLate.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
psychopompLate.action.psychopompPrecommit = ["B.SQR"];
const psychopompLateDecider = new OodaDecider({
  knowledge: psychopompLate,
  bot: { ...mockBot, player: psychopompLate, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: psychopompLate.action.psychopompPrecommit },
  psychopompStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
assert.equal(
  psychopompLateDecider.decide({ frame: new Uint8Array(128 * 128), roster: null }).kind,
  "psychopomp_precommit",
  "fallback psychopomp precommit executes near the deadline",
);

const meet = createGameKnowledge("llm_meet_activity");
meet.tick = 70;
meet.phase = "playing";
meet.myRoom = Room.RoomA;
meet.myPos = { x: 5, y: 5 };
meet.myCharName = "R.CRCL";
meet.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
meet.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
writePolicyPatch(meet, "unit", { meetPoint: { x: 20, y: 21, reason: "unit meet", tick: meet.tick } });
const meetBot = { ...mockBot, player: meet, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: null };
const meetDecider = new OodaDecider({
  knowledge: meet,
  bot: meetBot,
  psychopompStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
const meetDecision = meetDecider.decide({ frame: new Uint8Array(128 * 128), roster: null });
assert.equal(meetDecision.kind, "run_activity");
assert.equal(meet.action.currentActivity?.kind, "walk_to");
if (meet.action.currentActivity?.kind === "walk_to") {
  assert.equal(meet.action.currentActivity.openWhisperOnArrive, true);
}

const activeWhisper = createGameKnowledge("llm_v2_active_whisper");
activeWhisper.tick = 80;
activeWhisper.phase = "whisper";
activeWhisper.myRoom = Room.RoomA;
activeWhisper.myCharName = "R.CRCL";
activeWhisper.myColor = 3;
activeWhisper.myShape = PlayerShape.Circle;
activeWhisper.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
activeWhisper.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
activeWhisper.occupantNames = ["B.SQR"];
activeWhisper.occupantCount = 2;
activeWhisper.action.lastGlobalCheckTick = activeWhisper.tick;
activeWhisper.action.currentActivity = {
  id: "unit-active-exchange",
  kind: "pursue_player",
  startedTick: activeWhisper.tick,
  lastActiveTick: activeWhisper.tick,
  timeLimitTicks: 900,
  status: "unit exchange",
  target: "B.SQR",
  mode: "color",
  approach: "go_to_player",
  createdOwnWhisperTick: null,
  enteredWhisperTick: null,
  waitingEntryTick: null,
  grantDeadlineTick: null,
  lastSawTargetTick: activeWhisper.tick,
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
assert.equal(queueCommunicationDraft(activeWhisper, { channel: "whisper", target: "B.SQR", text: "MEET @ 12,13", source: "unit" }), true);
const activeDecider = new OodaDecider({
  knowledge: activeWhisper,
  bot: { ...mockBot, player: activeWhisper, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: null },
  psychopompStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
activeDecider.decide({ frame: new Uint8Array(128 * 128), roster: null });
assert.equal(activeWhisper.action.atomQueue.some(a => a.kind === "chat"), false, "active pursue_player owns whisper chat/action sequencing");

const sentPackets: Buffer[] = [];
const activeActuator = new OodaActuator({
  ws: { readyState: 1, send: (buf: Buffer) => sentPackets.push(buf) } as any,
  knowledge: activeWhisper,
  bot: { ...mockBot, player: activeWhisper, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: null },
  botName: "llm_v2_active_whisper",
  logEvent: () => {},
});
activeActuator.act({ kind: "run_activity", frame: new Uint8Array(128 * 128) });
assert.equal(sentPackets.length > 0, true, "activity refills atomics and atomics emit the frame action");
assert.equal(activeWhisper.action.currentActivity?.kind, "pursue_player");
if (activeWhisper.action.currentActivity?.kind === "pursue_player") {
  assert.equal(activeWhisper.action.currentActivity.conversationMessageSentTick, activeWhisper.tick);
}

const timedOutWhisper = createGameKnowledge("llm_v2_timed_out_whisper");
timedOutWhisper.tick = 1000;
timedOutWhisper.phase = "whisper";
timedOutWhisper.myRoom = Room.RoomA;
timedOutWhisper.myCharName = "R.CRCL";
timedOutWhisper.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
timedOutWhisper.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
timedOutWhisper.occupantNames = ["B.SQR"];
timedOutWhisper.occupantCount = 2;
timedOutWhisper.action.currentActivity = {
  id: "unit-timeout-exchange",
  kind: "pursue_player",
  startedTick: timedOutWhisper.tick - 20,
  lastActiveTick: timedOutWhisper.tick - 1,
  timeLimitTicks: 900,
  status: "unit timed out exchange",
  target: "B.SQR",
  mode: "color",
  approach: "go_to_player",
  createdOwnWhisperTick: timedOutWhisper.tick - 30 * TARGET_FPS - 1,
  enteredWhisperTick: timedOutWhisper.tick - 30 * TARGET_FPS - 1,
  waitingEntryTick: null,
  grantDeadlineTick: timedOutWhisper.tick + 200,
  lastSawTargetTick: timedOutWhisper.tick,
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
const timeoutActuator = new OodaActuator({
  ws: { readyState: 1, send: (_buf: Buffer) => {} } as any,
  knowledge: timedOutWhisper,
  bot: { ...mockBot, player: timedOutWhisper, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: null },
  botName: "llm_v2_timed_out_whisper",
  logEvent: () => {},
});
timeoutActuator.act({ kind: "run_activity", frame: new Uint8Array(128 * 128) });
assert.equal(timedOutWhisper.action.currentActivity, null, "conversation timeout should finish the pursue activity");
assert.equal(
  timedOutWhisper.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "EXIT" && a.label === "conversation_timeout_exit"),
  true,
  "conversation timeout should queue a normal whisper exit",
);

const staleWhisper = createGameKnowledge("llm_v2_stale_whisper");
staleWhisper.tick = 2000;
staleWhisper.phase = "whisper";
staleWhisper.myRoom = Room.RoomA;
staleWhisper.myCharName = "R.CRCL";
staleWhisper.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
staleWhisper.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
staleWhisper.occupantNames = ["B.SQR"];
staleWhisper.occupantCount = 2;
staleWhisper.action.whisperStartedTick = staleWhisper.tick - 30 * TARGET_FPS - 1;
const staleDecider = new OodaDecider({
  knowledge: staleWhisper,
  bot: { ...mockBot, player: staleWhisper, actions: new ActionQueue(), nonInterruptingTasks: [], psychopompPrecommit: null },
  psychopompStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
staleDecider.decide({ frame: new Uint8Array(128 * 128), roster: null });
assert.equal(
  staleWhisper.action.atomQueue.some(a => a.kind === "whisper_action" && a.action === "EXIT" && a.label === "conversation_timeout_exit"),
  true,
  "stale whisper timeout should exit even without an active pursue activity",
);

console.log("ooda_unit ok");

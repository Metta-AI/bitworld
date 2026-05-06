import assert from "node:assert/strict";
import { HADES_ROLE_NAME, CERBERUS_ROLE_NAME, TEAM_A_NAME } from "../game/constants.js";
import { Room, PlayerShape } from "../game/types.js";
import { ActionQueue } from "../bots/bot_utils.js";
import type { BotController } from "../bots/bot_common.js";
import { policyTick } from "../bots/default_policy.js";
import { OodaActuator } from "../bots/ooda_act.js";
import { OodaDecider } from "../bots/ooda_decide.js";
import {
  createGameKnowledge,
  chooseDeterministicHostageTargets,
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
  hostageTargets: ["B.SQR", "Y.TRI"],
  shoutNext: "B.SQR COME @ 42,55",
  usurpTarget: "NOPE",
});
assert.equal(accepted, true);
assert.deepEqual(knowledge.policy.resolved.pursueColorExchangeWithPlayer, ["B.SQR"]);
assert.deepEqual(knowledge.policy.resolved.hostageTargets, ["B.SQR"]);
assert.equal(knowledge.policy.resolved.shoutNext, "B.SQR COME @ 42,55");
assert.equal(knowledge.policy.resolved.usurpTarget, null);

const fallbackHostages = createGameKnowledge("llm_hostage_fallback");
fallbackHostages.myRoom = Room.RoomA;
fallbackHostages.myCharName = "R.CRCL";
fallbackHostages.matchFacts.currentRound = 1;
fallbackHostages.matchFacts.rounds = [{ round: 1, durationSecs: 60, hostages: 2 }];
fallbackHostages.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
fallbackHostages.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
fallbackHostages.players.set("Y.TRI", player("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA));
fallbackHostages.players.set("G.CRCL", player("G.CRCL", 11, PlayerShape.Circle, Room.RoomA));
fallbackHostages.players.set("P.STAR", player("P.STAR", 13, PlayerShape.Star, Room.RoomA));
assert.deepEqual(chooseDeterministicHostageTargets(fallbackHostages), ["G.CRCL", "B.SQR"]);

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
  hostagePrecommit: [],
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

const v2 = createGameKnowledge("llm_v2");
v2.tick = 60;
v2.phase = "playing";
v2.myRoom = Room.RoomA;
v2.myCharName = "R.CRCL";
v2.amLeader = false;
v2.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
v2.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
writePolicyPatch(v2, "unit", { shouldUsurp: true, usurpTarget: "B.SQR" });
const v2Bot = { ...mockBot, player: v2, actions: new ActionQueue(), nonInterruptingTasks: [], hostagePrecommit: null };
const decider = new OodaDecider({
  knowledge: v2,
  bot: v2Bot,
  hostageStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
const decision = decider.decide({ frame: new Uint8Array(128 * 128), roster: null });
assert.equal(decision.kind, "run_activity");
assert.equal(v2.action.atomQueue.some(a => a.kind === "usurp_vote" && a.target === "B.SQR"), true);

const hostageEarly = createGameKnowledge("llm_hostage_early");
hostageEarly.tick = 65;
hostageEarly.phase = "hostage_select";
hostageEarly.prevPhase = "playing";
hostageEarly.myRoom = Room.RoomA;
hostageEarly.myCharName = "R.CRCL";
hostageEarly.amLeader = true;
hostageEarly.matchFacts.currentRound = 1;
hostageEarly.matchFacts.hostageSelectTimerSecs = 10;
hostageEarly.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
hostageEarly.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
hostageEarly.action.hostagePrecommit = ["B.SQR"];
const hostageEarlyBot = { ...mockBot, player: hostageEarly, actions: new ActionQueue(), nonInterruptingTasks: [], hostagePrecommit: hostageEarly.action.hostagePrecommit };
const hostageEarlyDecider = new OodaDecider({
  knowledge: hostageEarly,
  bot: hostageEarlyBot,
  hostageStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
assert.equal(
  hostageEarlyDecider.decide({ frame: new Uint8Array(128 * 128), roster: null }).kind,
  "run_activity",
  "fallback hostage precommit should not commit immediately at hostage-select start",
);

writePolicyPatch(hostageEarly, "unit", { hostageTargets: ["B.SQR"] });
assert.equal(
  hostageEarlyDecider.decide({ frame: new Uint8Array(128 * 128), roster: null }).kind,
  "hostage_precommit",
  "policy hostage precommit can execute immediately",
);

const hostageLate = createGameKnowledge("llm_hostage_late");
hostageLate.tick = 66;
hostageLate.phase = "hostage_select";
hostageLate.prevPhase = "playing";
hostageLate.myRoom = Room.RoomA;
hostageLate.myCharName = "R.CRCL";
hostageLate.amLeader = true;
hostageLate.matchFacts.currentRound = 1;
hostageLate.matchFacts.hostageSelectTimerSecs = 2;
hostageLate.players.set("R.CRCL", player("R.CRCL", 3, PlayerShape.Circle, Room.RoomA));
hostageLate.players.set("B.SQR", player("B.SQR", 14, PlayerShape.Square, Room.RoomA));
hostageLate.action.hostagePrecommit = ["B.SQR"];
const hostageLateDecider = new OodaDecider({
  knowledge: hostageLate,
  bot: { ...mockBot, player: hostageLate, actions: new ActionQueue(), nonInterruptingTasks: [], hostagePrecommit: hostageLate.action.hostagePrecommit },
  hostageStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
assert.equal(
  hostageLateDecider.decide({ frame: new Uint8Array(128 * 128), roster: null }).kind,
  "hostage_precommit",
  "fallback hostage precommit executes near the deadline",
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
const meetBot = { ...mockBot, player: meet, actions: new ActionQueue(), nonInterruptingTasks: [], hostagePrecommit: null };
const meetDecider = new OodaDecider({
  knowledge: meet,
  bot: meetBot,
  hostageStatus: () => ({ round: 0, done: true }),
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
  grantDeadlineTick: null,
  lastSawTargetTick: activeWhisper.tick,
  offerSentTick: null,
  conversationMessageSentTick: null,
  shoutedWrongRoom: false,
  privateSpot: null,
  privateSpotTick: -Infinity,
  privateSpotShoutTick: -Infinity,
  nearTargetWaitTick: -Infinity,
};
assert.equal(queueCommunicationDraft(activeWhisper, { channel: "whisper", target: "B.SQR", text: "MEET @ 12,13", source: "unit" }), true);
const activeDecider = new OodaDecider({
  knowledge: activeWhisper,
  bot: { ...mockBot, player: activeWhisper, actions: new ActionQueue(), nonInterruptingTasks: [], hostagePrecommit: null },
  hostageStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});
activeDecider.decide({ frame: new Uint8Array(128 * 128), roster: null });
assert.equal(activeWhisper.action.atomQueue.some(a => a.kind === "chat"), false, "active pursue_player owns whisper chat/action sequencing");

const sentPackets: Buffer[] = [];
const activeActuator = new OodaActuator({
  ws: { readyState: 1, send: (buf: Buffer) => sentPackets.push(buf) } as any,
  knowledge: activeWhisper,
  bot: { ...mockBot, player: activeWhisper, actions: new ActionQueue(), nonInterruptingTasks: [], hostagePrecommit: null },
  botName: "llm_v2_active_whisper",
  logEvent: () => {},
});
activeActuator.act({ kind: "run_activity", frame: new Uint8Array(128 * 128) });
assert.equal(sentPackets.length > 0, true, "activity refills atomics and atomics emit the frame action");
assert.equal(activeWhisper.action.currentActivity?.kind, "pursue_player");
if (activeWhisper.action.currentActivity?.kind === "pursue_player") {
  assert.equal(activeWhisper.action.currentActivity.conversationMessageSentTick, activeWhisper.tick);
}

console.log("ooda_unit ok");

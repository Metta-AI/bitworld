import assert from "node:assert/strict";
import { Sim } from "../game/sim.js";
import { Role, Team, Room, type GameConfig, type InputState } from "../game/types.js";
import { decodeInputMask, emptyInput } from "../game/protocol.js";
import { characterName } from "../game/constants.js";
import { render } from "../rendering/renderer.js";
import { ActionQueue, unpackFrame } from "../bots/bot_utils.js";
import {
  createGameKnowledge,
  hasColorExchangeSucceeded,
  updateGameKnowledgeFromFrame,
} from "../bots/game_knowledge.js";
import { OodaActuator } from "../bots/ooda_act.js";
import { parseUiState } from "../bots/ui_state.js";
import type { BotController } from "../bots/bot_common.js";

const config: GameConfig = {
  roles: [
    { role: Role.Hades, team: Team.TeamA, count: 1 },
    { role: Role.Cerberus, team: Team.TeamA, count: 1 },
  ],
  rounds: [{ durationSecs: 120, psychopomps: 1 }],
  obstacleCount: 0,
  autoGrantWhisperEntry: true,
  fastTimers: true,
};

interface MockWs {
  sends: number[];
  readyState: number;
  send: (msg: unknown) => void;
}

function makeWs(): MockWs {
  return {
    sends: [],
    readyState: 1,
    send(msg: unknown) {
      if (Buffer.isBuffer(msg) && msg.length >= 2) this.sends.push(msg[1]);
    },
  };
}

function makeBot(name: string, knowledge: ReturnType<typeof createGameKnowledge>, ws: MockWs): BotController {
  return {
    ws: ws as any,
    actions: new ActionQueue(),
    player: knowledge,
    name,
    movementTarget: null,
    wandering: false,
    wanderTarget: null,
    wanderTicks: 0,
    lastFrame: null,
    get psychopompPrecommit() { return knowledge.action.psychopompPrecommit; },
    set psychopompPrecommit(value: string[] | null) { knowledge.action.psychopompPrecommit = value ?? []; },
    get lastSentChat() { return knowledge.action.lastSentChat; },
    set lastSentChat(value: string | null) { knowledge.action.lastSentChat = value; },
    get hasNewIncomingChat() { return knowledge.action.hasNewIncomingChat; },
    set hasNewIncomingChat(value: boolean) { knowledge.action.hasNewIncomingChat = value; },
    nonInterruptingTasks: [],
  };
}

const sim = new Sim(config, 777);
assert.equal(sim.addPlayer("offerer"), 0);
assert.equal(sim.addPlayer("acceptor"), 1);
sim.startGame();
sim.startRound();

sim.players[0].room = Room.RoomA;
sim.players[1].room = Room.RoomA;
sim.createWhisper(1);
const whisper = sim.whispers.get(sim.players[1].inWhisper);
assert.ok(whisper);
whisper.occupants.add(0);
sim.players[0].inWhisper = sim.players[1].inWhisper;
whisper.colorOffers.add(0);

// The regression: a previous stale menu action left us on the wrong item.
sim.players[1].whisperMenuOpen = true;
sim.players[1].whisperMenuCat = 2;
sim.players[1].whisperMenuItem = 2;

const initialFrame = unpackFrame(render(sim, 1));
const initialUi = parseUiState(initialFrame);
assert.equal(initialUi.surface, "whisper_menu");
if (initialUi.surface === "whisper_menu") {
  assert.equal(initialUi.action, "GRANT");
}

const knowledge = createGameKnowledge("acceptor");
knowledge.myColor = sim.playerColor(1);
knowledge.myShape = sim.players[1].shape;
knowledge.myCharName = characterName(sim.playerColor(1), sim.players[1].shape);
knowledge.myRoom = Room.RoomA;
knowledge.action.atomQueue.push({ kind: "whisper_action", action: "C.ACCPT", label: "accept_color" });

const ws = makeWs();
const bot = makeBot("acceptor", knowledge, ws);
const actuator = new OodaActuator({
  ws: ws as any,
  knowledge,
  bot,
  botName: "acceptor",
  logEvent: () => {},
});

let prev0: InputState = emptyInput();
let prev1: InputState = emptyInput();
for (let tick = 0; tick < 80; tick++) {
  const frame = unpackFrame(render(sim, 1));
  updateGameKnowledgeFromFrame(knowledge, frame);
  ws.sends.length = 0;
  actuator.act({ kind: "run_activity", frame });

  const input0 = emptyInput();
  const input1 = decodeInputMask(ws.sends[ws.sends.length - 1] ?? 0);
  sim.step([input0, input1], [prev0, prev1]);
  prev0 = input0;
  prev1 = input1;

  if (sim.players[1].colorRevealedTo.has(0) && knowledge.action.atomQueue.length === 0) break;
}

assert.equal(sim.players[1].colorRevealedTo.has(0), true, "C.ACCPT should navigate from a stale whisper menu and accept the color offer");
assert.equal(whisper.colorOffers.size, 0, "accepted color offer should clear engine color offer state");
assert.equal(knowledge.action.atomQueue.length, 0, "accept atomic should finish after navigating and selecting");

const multiConfig: GameConfig = {
  roles: [{ role: Role.Shades, team: Team.TeamA, count: 3 }],
  rounds: [{ durationSecs: 120, psychopomps: 1 }],
  obstacleCount: 0,
  fastTimers: true,
};

const multiSim = new Sim(multiConfig, 779);
assert.equal(multiSim.addPlayer("viewer"), 0);
assert.equal(multiSim.addPlayer("old-partner"), 1);
assert.equal(multiSim.addPlayer("new-offerer"), 2);
multiSim.startGame();
multiSim.startRound();
for (const p of multiSim.players) p.room = Room.RoomA;
multiSim.createWhisper(0);
const multiWhisper = multiSim.whispers.get(multiSim.players[0].inWhisper);
assert.ok(multiWhisper);
multiWhisper.occupants.add(1);
multiWhisper.occupants.add(2);
multiSim.players[1].inWhisper = multiSim.players[0].inWhisper;
multiSim.players[2].inWhisper = multiSim.players[0].inWhisper;
multiSim.players[0].colorRevealedTo.add(1);
multiSim.players[1].colorRevealedTo.add(0);
multiWhisper.colorOffers.add(2);

const multiKnowledge = createGameKnowledge("viewer");
multiKnowledge.myColor = multiSim.playerColor(0);
multiKnowledge.myShape = multiSim.players[0].shape;
multiKnowledge.myCharName = characterName(multiSim.playerColor(0), multiSim.players[0].shape);
multiKnowledge.myRoom = Room.RoomA;
const oldPartner = characterName(multiSim.playerColor(1), multiSim.players[1].shape);
const newOfferer = characterName(multiSim.playerColor(2), multiSim.players[2].shape);
multiKnowledge.action.atomQueue.push({ kind: "whisper_action", action: "C.ACCPT", label: "accept_color", target: newOfferer });

const multiWs = makeWs();
const multiBot = makeBot("viewer", multiKnowledge, multiWs);
const multiActuator = new OodaActuator({
  ws: multiWs as any,
  knowledge: multiKnowledge,
  bot: multiBot,
  botName: "viewer",
  logEvent: () => {},
});

let multiPrev0: InputState = emptyInput();
let multiPrev1: InputState = emptyInput();
let multiPrev2: InputState = emptyInput();
for (let tick = 0; tick < 80; tick++) {
  const frame = unpackFrame(render(multiSim, 0));
  updateGameKnowledgeFromFrame(multiKnowledge, frame);
  multiWs.sends.length = 0;
  multiActuator.act({ kind: "run_activity", frame });

  const input0 = decodeInputMask(multiWs.sends[multiWs.sends.length - 1] ?? 0);
  const input1 = emptyInput();
  const input2 = emptyInput();
  multiSim.step([input0, input1, input2], [multiPrev0, multiPrev1, multiPrev2]);
  multiPrev0 = input0;
  multiPrev1 = input1;
  multiPrev2 = input2;

  if (multiSim.players[0].colorRevealedTo.has(2) && multiKnowledge.action.atomQueue.length === 0) break;
}

assert.equal(multiSim.players[0].colorRevealedTo.has(2), true, "persistent whisper entrant's color offer should be accepted");
assert.equal(hasColorExchangeSucceeded(multiKnowledge, newOfferer), true, "accept bookkeeping should mark the new offerer");
assert.equal(hasColorExchangeSucceeded(multiKnowledge, oldPartner), false, "accept bookkeeping must not mark every occupant");
assert.equal(multiKnowledge.action.atomQueue.length, 0, "multi-occupant accept atomic should finish");

// Regression: the parser must not confuse the "(ROLE)" category label for the
// selected "ROLE" action, otherwise R.OFFER navigation walks past the target.
sim.players[1].whisperMenuOpen = true;
sim.players[1].whisperMenuCat = 1;
sim.players[1].whisperMenuItem = 0;
knowledge.action.atomQueue.push({ kind: "whisper_action", action: "R.OFFER", label: "offer_role" });
for (let tick = 0; tick < 80; tick++) {
  const frame = unpackFrame(render(sim, 1));
  updateGameKnowledgeFromFrame(knowledge, frame);
  ws.sends.length = 0;
  actuator.act({ kind: "run_activity", frame });

  const input0 = emptyInput();
  const input1 = decodeInputMask(ws.sends[ws.sends.length - 1] ?? 0);
  sim.step([input0, input1], [prev0, prev1]);
  prev0 = input0;
  prev1 = input1;

  if (whisper.revealOffers.has(1) && knowledge.action.atomQueue.length === 0) break;
}

assert.equal(whisper.revealOffers.has(1), true, "R.OFFER should navigate within the ROLE category and select the offer item");
assert.equal(knowledge.action.atomQueue.length, 0, "role offer atomic should finish after selecting R.OFFER");

const infoSim = new Sim(config, 778);
assert.equal(infoSim.addPlayer("viewer"), 0);
assert.equal(infoSim.addPlayer("known"), 1);
infoSim.startGame();
infoSim.startRound();
infoSim.players[0].room = Room.RoomA;
infoSim.players[1].room = Room.RoomA;
infoSim.players[0].team = Team.TeamA;
infoSim.players[1].team = Team.TeamA;
infoSim.players[0].colorRevealedTo.add(1);
infoSim.players[1].colorRevealedTo.add(0);

const infoKnowledge = createGameKnowledge("viewer");
infoKnowledge.myColor = infoSim.playerColor(0);
infoKnowledge.myShape = infoSim.players[0].shape;
infoKnowledge.myCharName = characterName(infoSim.playerColor(0), infoSim.players[0].shape);
infoKnowledge.myRoom = Room.RoomA;
infoKnowledge.myTeam = "Shades";
infoKnowledge.players.set(infoKnowledge.myCharName, {
  name: infoKnowledge.myCharName,
  color: infoSim.playerColor(0),
  shape: infoSim.players[0].shape,
  lastRoom: Room.RoomA,
  lastPos: { x: infoSim.players[0].x, y: infoSim.players[0].y },
  lastSeenTick: 0,
  knownRole: null,
  knownTeam: null,
  isLeader: false,
  inWhisper: false,
  positionAmbiguousByColor: false,
  weSharedWith: false,
  theyRevealedCard: false,
  theyRevealedColor: false,
});
const knownName = characterName(infoSim.playerColor(1), infoSim.players[1].shape);
infoKnowledge.players.set(knownName, {
  name: knownName,
  color: infoSim.playerColor(1),
  shape: infoSim.players[1].shape,
  lastRoom: Room.RoomA,
  lastPos: { x: infoSim.players[1].x, y: infoSim.players[1].y },
  lastSeenTick: 0,
  knownRole: null,
  knownTeam: null,
  isLeader: false,
  inWhisper: false,
  positionAmbiguousByColor: false,
  weSharedWith: false,
  theyRevealedCard: false,
  theyRevealedColor: false,
});
infoKnowledge.action.atomQueue.push({ kind: "info_check", label: "info_check", startedTick: 0, readTicks: 2 });

const infoWs = makeWs();
const infoBot = makeBot("viewer", infoKnowledge, infoWs);
const infoActuator = new OodaActuator({
  ws: infoWs as any,
  knowledge: infoKnowledge,
  bot: infoBot,
  botName: "viewer",
  logEvent: () => {},
});

let infoPrev0: InputState = emptyInput();
let infoPrev1: InputState = emptyInput();
for (let tick = 0; tick < 80; tick++) {
  infoKnowledge.tick = tick;
  const frame = unpackFrame(render(infoSim, 0));
  updateGameKnowledgeFromFrame(infoKnowledge, frame);
  infoWs.sends.length = 0;
  infoActuator.act({ kind: "run_activity", frame });

  const input0 = decodeInputMask(infoWs.sends[infoWs.sends.length - 1] ?? 0);
  const input1 = emptyInput();
  infoSim.step([input0, input1], [infoPrev0, infoPrev1]);
  infoPrev0 = input0;
  infoPrev1 = input1;

  if (infoKnowledge.action.atomQueue.length === 0) break;
}

assert.equal(infoKnowledge.players.get(knownName)?.knownTeam, "Shades", "info_check should parse shared color info into knownTeam");
assert.equal(infoKnowledge.action.atomQueue.length, 0, "info_check atomic should finish after reading and closing info");

const whisperInfoSim = new Sim(config, 779);
assert.equal(whisperInfoSim.addPlayer("whisper_viewer"), 0);
assert.equal(whisperInfoSim.addPlayer("whisper_known"), 1);
whisperInfoSim.startGame();
whisperInfoSim.startRound();
whisperInfoSim.players[0].room = Room.RoomA;
whisperInfoSim.players[1].room = Room.RoomA;
whisperInfoSim.players[0].team = Team.TeamA;
whisperInfoSim.players[1].team = Team.TeamA;
whisperInfoSim.players[0].colorRevealedTo.add(1);
whisperInfoSim.players[1].colorRevealedTo.add(0);
whisperInfoSim.createWhisper(0);
const whisperInfoId = whisperInfoSim.players[0].inWhisper;
const whisperInfo = whisperInfoSim.whispers.get(whisperInfoId);
assert.ok(whisperInfo);
whisperInfo.occupants.add(1);
whisperInfoSim.players[1].inWhisper = whisperInfoId;

const whisperInfoKnowledge = createGameKnowledge("whisper_viewer");
whisperInfoKnowledge.myColor = whisperInfoSim.playerColor(0);
whisperInfoKnowledge.myShape = whisperInfoSim.players[0].shape;
whisperInfoKnowledge.myCharName = characterName(whisperInfoSim.playerColor(0), whisperInfoSim.players[0].shape);
whisperInfoKnowledge.myRoom = Room.RoomA;
whisperInfoKnowledge.myTeam = "Shades";
whisperInfoKnowledge.players.set(whisperInfoKnowledge.myCharName, {
  name: whisperInfoKnowledge.myCharName,
  color: whisperInfoSim.playerColor(0),
  shape: whisperInfoSim.players[0].shape,
  lastRoom: Room.RoomA,
  lastPos: { x: whisperInfoSim.players[0].x, y: whisperInfoSim.players[0].y },
  lastSeenTick: 0,
  knownRole: null,
  knownTeam: null,
  isLeader: false,
  inWhisper: true,
  positionAmbiguousByColor: false,
  weSharedWith: false,
  theyRevealedCard: false,
  theyRevealedColor: false,
});
const whisperKnownName = characterName(whisperInfoSim.playerColor(1), whisperInfoSim.players[1].shape);
whisperInfoKnowledge.players.set(whisperKnownName, {
  name: whisperKnownName,
  color: whisperInfoSim.playerColor(1),
  shape: whisperInfoSim.players[1].shape,
  lastRoom: Room.RoomA,
  lastPos: { x: whisperInfoSim.players[1].x, y: whisperInfoSim.players[1].y },
  lastSeenTick: 0,
  knownRole: null,
  knownTeam: null,
  isLeader: false,
  inWhisper: true,
  positionAmbiguousByColor: false,
  weSharedWith: false,
  theyRevealedCard: false,
  theyRevealedColor: false,
});
whisperInfoKnowledge.action.atomQueue.push({ kind: "info_check", label: "info_check_whisper", startedTick: 0, readTicks: 2 });

const whisperInfoWs = makeWs();
const whisperInfoBot = makeBot("whisper_viewer", whisperInfoKnowledge, whisperInfoWs);
const whisperInfoActuator = new OodaActuator({
  ws: whisperInfoWs as any,
  knowledge: whisperInfoKnowledge,
  bot: whisperInfoBot,
  botName: "whisper_viewer",
  logEvent: () => {},
});

let whisperInfoPrev0: InputState = emptyInput();
let whisperInfoPrev1: InputState = emptyInput();
for (let tick = 0; tick < 80; tick++) {
  whisperInfoKnowledge.tick = tick;
  const frame = unpackFrame(render(whisperInfoSim, 0));
  updateGameKnowledgeFromFrame(whisperInfoKnowledge, frame);
  whisperInfoWs.sends.length = 0;
  whisperInfoActuator.act({ kind: "run_activity", frame });

  const input0 = decodeInputMask(whisperInfoWs.sends[whisperInfoWs.sends.length - 1] ?? 0);
  const input1 = emptyInput();
  whisperInfoSim.step([input0, input1], [whisperInfoPrev0, whisperInfoPrev1]);
  whisperInfoPrev0 = input0;
  whisperInfoPrev1 = input1;

  if (whisperInfoKnowledge.action.atomQueue.length === 0) break;
}

const finalWhisperInfoUi = parseUiState(unpackFrame(render(whisperInfoSim, 0)));
assert.equal(whisperInfoKnowledge.players.get(whisperKnownName)?.knownTeam, "Shades", "whisper-origin info_check should parse shared color info into knownTeam");
assert.equal(whisperInfoKnowledge.action.atomQueue.length, 0, "whisper-origin info_check atomic should finish");
assert.equal(finalWhisperInfoUi.surface, "whisper_idle", "whisper-origin info_check should return to the whisper surface");

console.log("ui_navigation ok");

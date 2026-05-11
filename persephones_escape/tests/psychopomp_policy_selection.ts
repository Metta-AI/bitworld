import assert from "node:assert/strict";
import { Sim } from "../game/sim.js";
import { Phase, Role, Room, Team, type GameConfig, type InputState } from "../game/types.js";
import { decodeInputMask, emptyInput } from "../game/protocol.js";
import { characterName } from "../game/constants.js";
import { render } from "../rendering/renderer.js";
import { ActionQueue, unpackFrame } from "../bots/bot_utils.js";
import { createGameKnowledge, type GameKnowledge, type PlayerKnowledge } from "../bots/game_knowledge.js";
import { OodaActuator } from "../bots/ooda_act.js";
import { OodaDecider } from "../bots/ooda_decide.js";
import type { BotController } from "../bots/bot_common.js";

const config: GameConfig = {
  roles: [{ role: Role.Shades, team: Team.TeamA, count: 6 }],
  rounds: [{ durationSecs: 60, psychopomps: 1 }],
  obstacleCount: 0,
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

function playerKnowledge(sim: Sim, pi: number, room: Room): PlayerKnowledge {
  const player = sim.players[pi];
  return {
    name: characterName(sim.playerColor(pi), player.shape),
    color: sim.playerColor(pi),
    shape: player.shape,
    lastRoom: room,
    lastPos: { x: player.x, y: player.y },
    lastSeenTick: 0,
    knownRole: null,
    knownTeam: null,
    isLeader: player.isLeader,
    inWhisper: false,
    positionAmbiguousByColor: false,
    weSharedWith: false,
    theyRevealedCard: false,
    theyRevealedColor: false,
  };
}

function makePsychopompKnowledge(sim: Sim, target: string): { knowledge: GameKnowledge; bot: BotController; ws: MockWs } {
  const knowledge = createGameKnowledge("psychopomp_policy_test");
  knowledge.phase = "psychopomp_select";
  knowledge.prevPhase = "playing";
  knowledge.amLeader = true;
  knowledge.myRoom = Room.RoomA;
  knowledge.myCharName = characterName(sim.playerColor(0), sim.players[0].shape);
  knowledge.matchFacts.currentRound = 1;
  knowledge.matchFacts.rounds = [{ round: 1, durationSecs: 60, psychopomps: 1 }];
  knowledge.matchFacts.psychopompSelectTimerSecs = 15;
  knowledge.policy.resolved.psychopompTargets = [target];
  knowledge.action.psychopompPrecommit = [target];
  knowledge.action.psychopompPrecommitRound = 1;

  for (let i = 0; i < sim.players.length; i++) {
    const pk = playerKnowledge(sim, i, Room.RoomA);
    knowledge.players.set(pk.name, pk);
  }

  const ws = makeWs();
  const bot: BotController = {
    ws: ws as any,
    actions: new ActionQueue(),
    player: knowledge,
    name: "psychopomp_policy_test",
    movementTarget: null,
    wandering: false,
    wanderTarget: null,
    wanderTicks: 0,
    lastFrame: null,
    get psychopompPrecommit() { return knowledge.action.psychopompPrecommit; },
    set psychopompPrecommit(value: string[] | null) {
      knowledge.action.psychopompPrecommit = value ?? [];
      knowledge.action.psychopompPrecommitRound = knowledge.matchFacts.currentRound;
    },
    get lastSentChat() { return knowledge.action.lastSentChat; },
    set lastSentChat(value: string | null) { knowledge.action.lastSentChat = value; },
    get hasNewIncomingChat() { return knowledge.action.hasNewIncomingChat; },
    set hasNewIncomingChat(value: boolean) { knowledge.action.hasNewIncomingChat = value; },
    nonInterruptingTasks: [],
  };

  return { knowledge, bot, ws };
}

function latestMask(ws: MockWs): number {
  return ws.sends.length > 0 ? ws.sends[ws.sends.length - 1] : 0;
}

const sim = new Sim(config, 101);
for (let i = 0; i < 6; i++) assert.equal(sim.addPlayer(`p${i}`), i);
sim.startRound();
for (const player of sim.players) player.room = Room.RoomA;
sim.setLeader(Room.RoomA, 0);
sim.psychopompsPerRoom = 1;
sim.beginPsychopompSelect();
assert.equal(sim.phase, Phase.PsychopompSelect);

const eligible = sim.eligiblePsychopomps(Room.RoomA);
assert.ok(eligible.length >= 4, "test needs a target more than one cursor step away");
const targetIndex = eligible[3];
const targetName = characterName(sim.playerColor(targetIndex), sim.players[targetIndex].shape);

const { knowledge, bot, ws } = makePsychopompKnowledge(sim, targetName);
const actuator = new OodaActuator({
  ws: ws as any,
  knowledge,
  bot,
  botName: bot.name,
  logEvent: () => {},
});
const decider = new OodaDecider({
  knowledge,
  bot,
  psychopompStatus: () => actuator.psychopompStatus(),
  logEvent: () => {},
});

let prev: InputState = emptyInput();
for (let tick = 0; tick < 40 && !sim.committedA; tick++) {
  const frame = unpackFrame(render(sim, 0));
  knowledge.tick = tick;
  knowledge.matchFacts.psychopompSelectTimerSecs = 15;
  const decision = decider.decide({ frame, roster: null });
  actuator.act(decision);
  const input = decodeInputMask(latestMask(ws));
  sim.applyInput(0, input, prev);
  prev = input;
}

assert.equal(sim.committedA, true, "psychopomp selector should commit before timeout");
assert.deepEqual(
  sim.psychopompsSelectedA,
  [targetIndex],
  `psychopomp selector should select ${targetName}, not default/random psychopomps`,
);
assert.equal(sim.players[targetIndex].selectedAsPsychopomp, true);

console.log("psychopomp policy selection test passed");

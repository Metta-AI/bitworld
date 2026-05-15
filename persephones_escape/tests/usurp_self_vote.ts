import assert from "node:assert/strict";
import { Sim } from "../game/sim.js";
import { Phase, Role, Room, Team, type GameConfig, type InputState } from "../game/types.js";
import { decodeInputMask, emptyInput } from "../game/protocol.js";
import { characterName } from "../game/constants.js";
import { render } from "../rendering/renderer.js";
import { ActionQueue, unpackFrame } from "../bots/bot_utils.js";
import { createGameKnowledge, runDeterministicDerivedOrienters, type GameKnowledge, type PlayerKnowledge } from "../bots/game_knowledge.js";
import { OodaActuator } from "../bots/ooda_act.js";
import { OodaDecider } from "../bots/ooda_decide.js";
import type { BotController } from "../bots/bot_common.js";

const config: GameConfig = {
  roles: [{ role: Role.Shades, team: Team.TeamA, count: 2 }],
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

function latestMask(ws: MockWs): number {
  return ws.sends.length > 0 ? ws.sends[ws.sends.length - 1] : 0;
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

function makeKnowledge(sim: Sim, voterIndex: number): { knowledge: GameKnowledge; bot: BotController; ws: MockWs } {
  const knowledge = createGameKnowledge("usurp_self_vote_test");
  knowledge.phase = "playing";
  knowledge.prevPhase = "playing";
  knowledge.amLeader = false;
  knowledge.myRoom = Room.RoomA;
  knowledge.myCharName = characterName(sim.playerColor(voterIndex), sim.players[voterIndex].shape);
  knowledge.matchFacts.currentRound = 1;
  knowledge.action.lastGlobalCheckTick = 0;

  for (let i = 0; i < sim.players.length; i++) {
    const pk = playerKnowledge(sim, i, Room.RoomA);
    knowledge.players.set(pk.name, pk);
  }
  runDeterministicDerivedOrienters(knowledge);
  assert.equal(knowledge.policy.resolved.usurpTarget, knowledge.myCharName);

  const ws = makeWs();
  const bot: BotController = {
    ws: ws as any,
    actions: new ActionQueue(),
    player: knowledge,
    name: "usurp_self_vote_test",
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

const sim = new Sim(config, 505);
assert.equal(sim.addPlayer("leader"), 0);
assert.equal(sim.addPlayer("voter"), 1);
sim.startRound();
for (const player of sim.players) player.room = Room.RoomA;
sim.setLeader(Room.RoomA, 0);
sim.players[1].isLeader = false;
assert.equal(sim.phase, Phase.Playing);

const voterIndex = 1;
const { knowledge, bot, ws } = makeKnowledge(sim, voterIndex);
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
  psychopompStatus: () => ({ round: 0, done: true }),
  logEvent: () => {},
});

let prev: InputState = emptyInput();
for (let tick = 0; tick < 20 && knowledge.action.lastUsurpVoteTarget !== knowledge.myCharName; tick++) {
  const frame = unpackFrame(render(sim, voterIndex));
  knowledge.tick = tick;
  const decision = decider.decide({ frame, roster: null });
  actuator.act(decision);
  const input = decodeInputMask(latestMask(ws));
  sim.applyInput(voterIndex, input, prev);
  prev = input;
  sim.tickCount++;
}

assert.equal(sim.players[voterIndex].usurpVote, voterIndex, "default usurp atomic should vote for self");
assert.equal(knowledge.action.lastUsurpVoteTarget, knowledge.myCharName);
assert.equal(knowledge.action.lastUsurpVoteRound, knowledge.matchFacts.currentRound);

console.log("usurp self vote test passed");

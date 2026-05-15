/**
 * Integration test: two bots (Hades + Cerberus) run the full OODA loop
 * against a real sim until they complete color exchange, then role exchange.
 */
import assert from "node:assert/strict";
import { Sim } from "../game/sim.js";
import { Phase, Role, Room, Team, type GameConfig, type InputState } from "../game/types.js";
import { decodeInputMask, emptyInput } from "../game/protocol.js";
import { characterName } from "../game/constants.js";
import { render } from "../rendering/renderer.js";
import { ActionQueue, unpackFrame } from "../bots/bot_utils.js";
import {
  createGameKnowledge, updateGameKnowledgeFromFrame,
  runDeterministicDerivedOrienters,
  type GameKnowledge, type PlayerKnowledge,
} from "../bots/game_knowledge.js";
import { parseRosterScreen } from "../bots/frame_parser.js";
import { OodaActuator } from "../bots/ooda_act.js";
import { OodaDecider } from "../bots/ooda_decide.js";
import type { BotController } from "../bots/bot_common.js";

// ---------------------------------------------------------------------------
// Config: 2 players, Hades + Cerberus on same team, same room
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// Sim setup
// ---------------------------------------------------------------------------
const sim = new Sim(config, 42);
assert.equal(sim.addPlayer("bot_0"), 0);
assert.equal(sim.addPlayer("bot_1"), 1);
sim.startGame();
sim.startRound();

// Force both into same room, close together
sim.players[0].room = Room.RoomA;
sim.players[1].room = Room.RoomA;
sim.players[0].x = 40; sim.players[0].y = 40;
sim.players[1].x = 48; sim.players[1].y = 40;

// ---------------------------------------------------------------------------
// Bot setup (OODA architecture)
// ---------------------------------------------------------------------------
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

function makeBot(name: string, knowledge: GameKnowledge, ws: MockWs): BotController {
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
}

const ws0 = makeWs();
const ws1 = makeWs();
const knowledge0 = createGameKnowledge("bot_0");
const knowledge1 = createGameKnowledge("bot_1");

// Pre-seed knowledge: each bot knows the other exists (simulates roster digestion)
function seedKnowledge(k: GameKnowledge, myIndex: number) {
  const p = sim.players[myIndex];
  k.myColor = sim.playerColor(myIndex);
  k.myShape = p.shape;
  k.myCharName = characterName(sim.playerColor(myIndex), p.shape);
  k.myRoom = Room.RoomA;
  k.matchFacts.roomW = sim.roomW;
  k.matchFacts.roomH = sim.roomH;
  k.matchFacts.currentRound = 1;
  k.matchFacts.rounds = [{ round: 1, durationSecs: 120, psychopomps: 1 }];

  // Add all players to knowledge
  for (let i = 0; i < sim.players.length; i++) {
    const sp = sim.players[i];
    const name = characterName(sim.playerColor(i), sp.shape);
    const pk: PlayerKnowledge = {
      name,
      color: sim.playerColor(i),
      shape: sp.shape,
      lastRoom: Room.RoomA,
      lastPos: { x: sp.x, y: sp.y },
      lastSeenTick: 0,
      knownRole: null, knownTeam: null,
      isLeader: sp.isLeader,
      inWhisper: false,
      positionAmbiguousByColor: false,
      weSharedWith: false, theyRevealedCard: false, theyRevealedColor: false,
    };
    k.players.set(name, pk);
  }
}

seedKnowledge(knowledge0, 0);
seedKnowledge(knowledge1, 1);

const bot0 = makeBot("bot_0", knowledge0, ws0);
const bot1 = makeBot("bot_1", knowledge1, ws1);

const actuator0 = new OodaActuator({ ws: ws0 as any, knowledge: knowledge0, bot: bot0, botName: "bot_0", logEvent: () => {} });
const actuator1 = new OodaActuator({ ws: ws1 as any, knowledge: knowledge1, bot: bot1, botName: "bot_1", logEvent: () => {} });
const decider0 = new OodaDecider({ knowledge: knowledge0, bot: bot0, psychopompStatus: () => actuator0.psychopompStatus(), logEvent: () => {} });
const decider1 = new OodaDecider({ knowledge: knowledge1, bot: bot1, psychopompStatus: () => actuator1.psychopompStatus(), logEvent: () => {} });

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------
let prev0: InputState = emptyInput();
let prev1: InputState = emptyInput();

function tick() {
  const f0 = unpackFrame(render(sim, 0));
  const f1 = unpackFrame(render(sim, 1));
  updateGameKnowledgeFromFrame(knowledge0, f0);
  updateGameKnowledgeFromFrame(knowledge1, f1);

  ws0.sends.length = 0;
  ws1.sends.length = 0;
  const d0 = decider0.decide({ frame: f0, roster: null });
  const d1 = decider1.decide({ frame: f1, roster: null });
  actuator0.act(d0);
  actuator1.act(d1);

  const mask0 = ws0.sends[ws0.sends.length - 1] ?? 0;
  const mask1 = ws1.sends[ws1.sends.length - 1] ?? 0;
  const input0 = decodeInputMask(mask0);
  const input1 = decodeInputMask(mask1);
  sim.step([input0, input1], [prev0, prev1]);
  prev0 = input0;
  prev1 = input1;
}

// ---------------------------------------------------------------------------
// Phase 1: Run until color exchange completes
// ---------------------------------------------------------------------------
const MAX_COLOR_TICKS = 720;  // 30 seconds at 24fps
let colorExchanged = false;
for (let t = 0; t < MAX_COLOR_TICKS; t++) {
  tick();
  if (t >= 20 && t <= 50) {
    const cr = sim.whispers.get(sim.players[1].inWhisper);
    const p1 = sim.players[1];
    console.log(`  t=${t}: mask1=${ws1.sends[ws1.sends.length-1]??0} menuOpen=${p1.whisperMenuOpen} menuCat=${p1.whisperMenuCat} menuItem=${p1.whisperMenuItem} cOff=[${cr ? [...cr.colorOffers] : ""}]`);
  }
  if (sim.players[0].colorRevealedTo.has(1) && sim.players[1].colorRevealedTo.has(0)) {
    colorExchanged = true;
    console.log(`  color exchange at tick ${t}`);
    break;
  }
}
assert.equal(colorExchanged, true, "bots should complete color exchange within 30s");

// ---------------------------------------------------------------------------
// Phase 2: Run until role exchange completes
// After color exchange, bots learn each other's team. Since they're both TeamA,
// the policy should recognize them as teammates and pursue role exchange.
// ---------------------------------------------------------------------------
const MAX_ROLE_TICKS = 720;
let roleExchanged = false;
for (let t = 0; t < MAX_ROLE_TICKS; t++) {
  tick();
  if (t < 60 && t % 10 === 0) {
    const cr = sim.whispers.get(sim.players[0].inWhisper);
    const p0inW = sim.players[0].inWhisper;
    const p1inW = sim.players[1].inWhisper;
    const rOff = cr ? [...cr.revealOffers] : [];
    const atoms0 = knowledge0.action.atomQueue.map(a => `${a.kind}:${a.label}`);
    const atoms1 = knowledge1.action.atomQueue.map(a => `${a.kind}:${a.label}`);
    const act0 = knowledge0.action.currentActivity;
    const act1 = knowledge1.action.currentActivity;
    console.log(`  role t=${t}: p0inW=${p0inW} p1inW=${p1inW} rOff=[${rOff}] atoms0=[${atoms0}] atoms1=[${atoms1}] act0=${act0?.kind}:${(act0 as any)?.mode} act1=${act1?.kind}:${(act1 as any)?.mode} phase0=${knowledge0.phase} phase1=${knowledge1.phase} shared0=${[...sim.players[0].sharedWith]} shared1=${[...sim.players[1].sharedWith]}`);
    console.log(`    k0.policy: roleExch=${knowledge0.policy.resolved.autoOfferRoleExchange} pursueRole=${knowledge0.policy.resolved.pursueRoleExchangeWithPlayer} acceptRole=${knowledge0.policy.resolved.acceptRoleOffers}`);
    console.log(`    k1.policy: roleExch=${knowledge1.policy.resolved.autoOfferRoleExchange} pursueRole=${knowledge1.policy.resolved.pursueRoleExchangeWithPlayer} acceptRole=${knowledge1.policy.resolved.acceptRoleOffers}`);
  }
  if (sim.players[0].sharedWith.has(1) && sim.players[1].sharedWith.has(0)) {
    roleExchanged = true;
    console.log(`  role exchange at tick ${t}`);
    break;
  }
}
assert.equal(roleExchanged, true, "bots should complete role exchange after discovering they're teammates");

console.log("policy_integration ok");

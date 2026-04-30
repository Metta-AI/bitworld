/**
 * Integration test: 2 sim players, both controlled by policy executor
 * using the real frame-parsing logic (no LLM). Verifies the full grant +
 * color_offer + role_offer flow works end-to-end.
 */

import { Sim } from "../sim.js";
import { DEFAULT_GAME_CONFIG } from "../constants.js";
import { decodeInputMask, emptyInput } from "../protocol.js";
import type { InputState } from "../types.js";
import { Phase } from "../types.js";
import { render } from "../renderer.js";
import {
  createBeliefState, updatePhase, updatePosition, updateMinimap, updateHud,
  type BeliefState,
} from "../belief_state.js";
import { unpackFrame, ActionQueue, type Point } from "../bot_utils.js";
import type { BotController } from "../bots/bot_common.js";
import { defaultPolicy, runPolicy, type Policy } from "../bots/policy.js";

const config = {
  ...DEFAULT_GAME_CONFIG,
  rounds: [{ durationSecs: 60, hostages: 1 }],
  obstacleCount: 0,
};

const sim = new Sim(config, 42);
for (let i = 0; i < 2; i++) sim.addPlayer(`llm_${i}`);
sim.startGame();
sim.startRound();

// Put them next to each other
sim.players[0].room = 0;
sim.players[1].room = 0;
sim.players[0].x = 50; sim.players[0].y = 50;
sim.players[1].x = 55; sim.players[1].y = 50;

// Mock WebSocket — collects sendInput calls
interface MockWs { sends: number[]; send: (msg: any) => void; readyState: number; }
function mkWs(): MockWs {
  const sends: number[] = [];
  return {
    sends,
    readyState: 1,  // WebSocket.OPEN
    send: (msg: Buffer) => {
      // protocol.ts format: [PACKET_INPUT, mask]
      if (msg instanceof Buffer && msg.length >= 2) sends.push(msg[1]);
    },
  };
}

const ws0 = mkWs();
const ws1 = mkWs();

const belief0 = createBeliefState("llm_0");
const belief1 = createBeliefState("llm_1");

const bot0: BotController = { ws: ws0 as any, actions: new ActionQueue(), belief: belief0, name: "llm_0", movementTarget: null, wandering: false, wanderTarget: null, wanderTicks: 0 };
const bot1: BotController = { ws: ws1 as any, actions: new ActionQueue(), belief: belief1, name: "llm_1", movementTarget: null, wandering: false, wanderTarget: null, wanderTicks: 0 };

// Policies — simulate what a "smart" LLM would do
const policy0: Policy = {
  ...defaultPolicy(),
  autoGrantEntry: true,
  autoAcceptColorOffer: true,
  autoAcceptRoleOffer: true,
  autoOfferColor: true,   // one-shot: fires once
  autoOfferRole: false,
  pursueColorOrder: [],
  wanderIfIdle: false,
};
const policy1: Policy = {
  ...defaultPolicy(),
  autoGrantEntry: true,
  autoAcceptColorOffer: true,
  autoAcceptRoleOffer: true,
  autoOfferColor: false,
  autoOfferRole: true,   // one-shot: fires once
  pursueColorOrder: [],
  wanderIfIdle: false,
};

// Step sim with the collected input masks
let prevInput0: InputState = emptyInput();
let prevInput1: InputState = emptyInput();

function tick() {
  // Parse frames for each bot
  const f0 = unpackFrame(render(sim, 0));
  const f1 = unpackFrame(render(sim, 1));
  updatePhase(belief0, f0); updateMinimap(belief0, f0); updatePosition(belief0, f0); updateHud(belief0, f0);
  updatePhase(belief1, f1); updateMinimap(belief1, f1); updatePosition(belief1, f1); updateHud(belief1, f1);

  // Run policy
  ws0.sends.length = 0; ws1.sends.length = 0;
  runPolicy(bot0, policy0, ws0);
  runPolicy(bot1, policy1, ws1);

  // Collect last input mask
  const mask0 = ws0.sends[ws0.sends.length - 1] ?? 0;
  const mask1 = ws1.sends[ws1.sends.length - 1] ?? 0;

  const input0 = decodeInputMask(mask0);
  const input1 = decodeInputMask(mask1);

  sim.step([input0, input1], [prevInput0, prevInput1]);
  prevInput0 = input0; prevInput1 = input1;
}

// Step 1: both bots press A first tick (from policy)
// Initially: NO chatroom. What does the policy do?

for (let t = 0; t < 5; t++) {
  tick();
  console.log(`t=${t}: P0.inChatroom=${sim.players[0].inChatroom} P1.inChatroom=${sim.players[1].inChatroom}`);
}

// First, get them into a chatroom via open_chatroom policy... wait, open_chatroom
// isn't a policy directly. Let's manually press A first (simulating LLM "open_chatroom")
// via the actions queue.

// Actually, policy's "openChatroomOnReach=true" only applies when pursuing.
// In this test, pursueColorOrder is empty, so no pursuing happens.
// Let me just manually have P0 create a chatroom and P1 request entry.

console.log("\n== Manually: P0 creates chatroom, P1 requests entry ==");
// P0 press A
bot0.actions.push(0x20, 0);  // BUTTON_A
for (let t = 0; t < 3; t++) tick();
console.log(`  P0.inChatroom=${sim.players[0].inChatroom}`);

// P1 press A (requests entry since within bubble of P0)
bot1.actions.push(0x20, 0);
for (let t = 0; t < 3; t++) tick();
console.log(`  P1.inChatroom=${sim.players[1].inChatroom} pendingEntry=${sim.players[1].pendingChatroomEntry}`);

console.log("\n== Let the policy run — P0 should auto-grant ==");
for (let t = 0; t < 60; t++) {
  tick();
  if (t % 5 === 0) {
    const cr = sim.chatrooms.get(sim.players[0].inChatroom);
    console.log(`  t=${t}: chatroom occupants=[${cr ? [...cr.occupants].join(",") : ""}] revealOffers=[${cr ? [...cr.revealOffers].join(",") : ""}] colorOffers=[${cr ? [...cr.colorOffers].join(",") : ""}]`);
    console.log(`         P0.sharedWith=[${[...sim.players[0].sharedWith].join(",")}] P1.sharedWith=[${[...sim.players[1].sharedWith].join(",")}]`);
    console.log(`         policy0.autoOfferColor=${policy0.autoOfferColor} policy1.autoOfferRole=${policy1.autoOfferRole}`);
  }
}

console.log("\n== Final state ==");
console.log(`  P0.sharedWith=[${[...sim.players[0].sharedWith].join(",")}]`);
console.log(`  P1.sharedWith=[${[...sim.players[1].sharedWith].join(",")}]`);
if (sim.players[0].sharedWith.has(1) && sim.players[1].sharedWith.has(0)) {
  console.log("✅ Mutual role exchange complete!");
} else {
  console.log("❌ Mutual role exchange did NOT complete.");
}

console.log("\n== Debug: parse P1's current frame ==");
import { parseChatroomStatus, parsePhase } from "../frame_parser.js";
const p1Buf = render(sim, 1);
const p1Frame = unpackFrame(p1Buf);
console.log(`P1 phase=${parsePhase(p1Frame)}`);
console.log(`P1 chatroom status=${JSON.stringify(parseChatroomStatus(p1Frame))}`);

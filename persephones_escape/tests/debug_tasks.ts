/**
 * Integration test: 2 sim players run the task executor (no LLM). Verifies
 * the whole pursue_chat → grant → color → role → mutual-exchange flow.
 */

import { Sim } from "../sim.js";
import { DEFAULT_GAME_CONFIG } from "../constants.js";
import { decodeInputMask, emptyInput } from "../protocol.js";
import type { InputState } from "../types.js";
import { render } from "../renderer.js";
import {
  createBeliefState, updatePhase, updatePosition, updateMinimap, updateHud,
} from "../bots/belief_state.js";
import { unpackFrame, ActionQueue } from "../bots/bot_utils.js";
import type { BotController } from "../bots/bot_common.js";
import { runTasks, createTaskInstance, createEventBuffer, eventBufferLines, type TaskInstance, type Task } from "../bots/tasks.js";

const sim = new Sim(
  { ...DEFAULT_GAME_CONFIG, rounds: [{ durationSecs: 60, hostages: 1 }], obstacleCount: 0 },
  42,
);
for (let i = 0; i < 2; i++) sim.addPlayer(`llm_${i}`);
sim.startGame();
sim.startRound();

sim.players[0].room = 0;
sim.players[1].room = 0;
sim.players[0].x = 20; sim.players[0].y = 20;
sim.players[1].x = 70; sim.players[1].y = 70;
console.log(`sim.roomW=${sim.roomW} sim.roomH=${sim.roomH}`);

// Mock WS collecting input masks
interface MockWs { sends: number[]; send: (msg: any) => void; readyState: number; }
function mkWs(): MockWs {
  const sends: number[] = [];
  return { sends, readyState: 1, send: (msg: Buffer) => { if (msg instanceof Buffer && msg.length >= 2) sends.push(msg[1]); } };
}

const ws0 = mkWs();
const ws1 = mkWs();

const belief0 = createBeliefState("llm_0");
const belief1 = createBeliefState("llm_1");
// Force belief roomW/roomH to match sim (normally set by role_reveal parsing)
belief0.roomW = sim.roomW; belief0.roomH = sim.roomH; belief0.myRoom = 0;
belief1.roomW = sim.roomW; belief1.roomH = sim.roomH; belief1.myRoom = 0;

const bot0: BotController = { ws: ws0 as any, actions: new ActionQueue(), belief: belief0, name: "llm_0", movementTarget: null, wandering: false, wanderTarget: null, wanderTicks: 0 };
const bot1: BotController = { ws: ws1 as any, actions: new ActionQueue(), belief: belief1, name: "llm_1", movementTarget: null, wandering: false, wanderTarget: null, wanderTicks: 0 };

// Task lists. The scenario: Hades-like bot0 pursues color of bot1 and offers
// role; bot1 auto-accepts. Both auto-grant entry and auto-accept color.
const color0 = sim.playerColor(0);
const color1 = sim.playerColor(1);
console.log(`player colors: 0=${color0}, 1=${color1}`);

let tasks0: TaskInstance[] = ([
  { kind: "loop_auto_grant" },
  { kind: "pursue_exchange", targetColor: color1, exchange: "role", timeLimitTicks: 600 },
] as Task[]).map(t => createTaskInstance(t, 0));

let tasks1: TaskInstance[] = ([
  { kind: "loop_auto_grant" },
  { kind: "loop_auto_accept_role" },
  { kind: "pursue_chat", targetColor: color0, timeLimitTicks: 600 },
] as Task[]).map(t => createTaskInstance(t, 0));

const events0 = createEventBuffer();
const events1 = createEventBuffer();

let prevInput0: InputState = emptyInput();
let prevInput1: InputState = emptyInput();

function tick() {
  const f0 = unpackFrame(render(sim, 0));
  const f1 = unpackFrame(render(sim, 1));
  updatePhase(belief0, f0); updateMinimap(belief0, f0); updatePosition(belief0, f0); updateHud(belief0, f0);
  updatePhase(belief1, f1); updateMinimap(belief1, f1); updatePosition(belief1, f1); updateHud(belief1, f1);

  ws0.sends.length = 0; ws1.sends.length = 0;
  tasks0 = runTasks(tasks0, bot0, ws0 as any, events0);
  tasks1 = runTasks(tasks1, bot1, ws1 as any, events1);

  const mask0 = ws0.sends[ws0.sends.length - 1] ?? 0;
  const mask1 = ws1.sends[ws1.sends.length - 1] ?? 0;
  const input0 = decodeInputMask(mask0);
  const input1 = decodeInputMask(mask1);
  sim.step([input0, input1], [prevInput0, prevInput1]);
  prevInput0 = input0; prevInput1 = input1;
}

for (let t = 0; t < 400; t++) {
  const preP0 = { inCr: sim.players[0].inChatroom, pend: sim.players[0].pendingChatroomEntry };
  const preP1 = { inCr: sim.players[1].inChatroom, pend: sim.players[1].pendingChatroomEntry };
  tick();
  // Detect state change in either player this tick
  const postP0 = { inCr: sim.players[0].inChatroom, pend: sim.players[0].pendingChatroomEntry };
  const postP1 = { inCr: sim.players[1].inChatroom, pend: sim.players[1].pendingChatroomEntry };
  if (preP0.inCr !== postP0.inCr || preP0.pend !== postP0.pend) {
    console.log(`  t=${t}: P0 state change inCr ${preP0.inCr}→${postP0.inCr} pend ${preP0.pend}→${postP0.pend} pos=(${sim.players[0].x},${sim.players[0].y})`);
  }
  if (preP1.inCr !== postP1.inCr || preP1.pend !== postP1.pend) {
    console.log(`  t=${t}: P1 state change inCr ${preP1.inCr}→${postP1.inCr} pend ${preP1.pend}→${postP1.pend} pos=(${sim.players[1].x},${sim.players[1].y})`);
  }
  if (t === 24 || t === 28 || t === 32) {
    console.log(`  t=${t}: P0 phase=${belief0.phase} tasks=${tasks0.map(ti => ti.task.kind).join(",")}`);
    console.log(`  t=${t}: P1 phase=${belief1.phase} tasks=${tasks1.map(ti => ti.task.kind).join(",")}`);
  }
  if (t === 25 || t === 40 || t === 50 || t === 60 || t === 100) {
    console.log(`--- t=${t} diagnostic ---`);
    console.log(`  P0 phase=${belief0.phase} myPos=${JSON.stringify(belief0.myPos)} dots=${belief0.minimapDots.map(d => `[c=${d.color}@${d.worldX},${d.worldY}${d.isSelf?",self":""}]`).join(" ")}`);
    console.log(`  P1 phase=${belief1.phase} myPos=${JSON.stringify(belief1.myPos)} dots=${belief1.minimapDots.map(d => `[c=${d.color}@${d.worldX},${d.worldY}${d.isSelf?",self":""}]`).join(" ")}`);
  }
  if (t % 20 === 0) {
    const cr0 = sim.chatrooms.get(sim.players[0].inChatroom);
    console.log(
      `t=${t} P0:(${sim.players[0].x},${sim.players[0].y}) inCr=${sim.players[0].inChatroom} ` +
      `P1:(${sim.players[1].x},${sim.players[1].y}) inCr=${sim.players[1].inChatroom} ` +
      `occ=[${cr0 ? [...cr0.occupants].join(",") : ""}] ` +
      `revealOffers=[${cr0 ? [...cr0.revealOffers].join(",") : ""}] ` +
      `shared=${[...sim.players[0].sharedWith].join(",")}|${[...sim.players[1].sharedWith].join(",")} ` +
      `tasks0=${tasks0.length} tasks1=${tasks1.length}`,
    );
  }
  if (sim.players[0].sharedWith.has(1) && sim.players[1].sharedWith.has(0)) {
    console.log(`\n✅ Mutual role exchange at t=${t}`);
    console.log(`  tasks0=${tasks0.map(ti => ti.task.kind).join(",")}`);
    console.log(`  tasks1=${tasks1.map(ti => ti.task.kind).join(",")}`);
    console.log(`\nEVENTS (P0):\n${eventBufferLines(events0).join("\n")}`);
    console.log(`\nEVENTS (P1):\n${eventBufferLines(events1).join("\n")}`);
    process.exit(0);
  }
}

console.log(`\n❌ No mutual exchange after 400 ticks`);
console.log(`  tasks0=${tasks0.map(ti => ti.task.kind).join(",")}`);
console.log(`  tasks1=${tasks1.map(ti => ti.task.kind).join(",")}`);
console.log(`  P0.sharedWith=[${[...sim.players[0].sharedWith].join(",")}]`);
console.log(`  P1.sharedWith=[${[...sim.players[1].sharedWith].join(",")}]`);
process.exit(1);

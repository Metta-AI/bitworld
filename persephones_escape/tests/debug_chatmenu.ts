/**
 * Small integration test: set up a real Sim with two players in the same
 * chatroom, feed them the EXACT input sequence that chatMenuSequence("R.OFFER")
 * produces, and verify the offer appears in sim state.
 */

import { Sim } from "../game/sim.js";
import { DEFAULT_GAME_CONFIG } from "../game/constants.js";
import { decodeInputMask, emptyInput } from "../game/protocol.js";
import type { InputState } from "../game/types.js";
import { Phase } from "../game/types.js";
import { chatMenuSequence } from "../game/menu_defs.js";
import { BUTTON_A, BUTTON_B, BUTTON_LEFT, BUTTON_RIGHT, BUTTON_UP, BUTTON_DOWN } from "../game/constants.js";

const config = {
  ...DEFAULT_GAME_CONFIG,
  rounds: [{ durationSecs: 60, hostages: 1 }],
  obstacleCount: 0,
};

const sim = new Sim(config, 42);

// Add 2 players manually
for (let i = 0; i < 2; i++) sim.addPlayer(`p${i}`);

// Force game to start
sim.phase = Phase.Playing;
sim.startGame();
sim.phase = Phase.Playing;
sim.startRound();

// Put both in same room, next to each other
sim.players[0].room = 0;
sim.players[1].room = 0;
sim.players[0].x = 50; sim.players[0].y = 50;
sim.players[1].x = 55; sim.players[1].y = 50;

console.log("== BEFORE: Player 0 state ==");
console.log(`  room=${sim.players[0].room} pos=(${sim.players[0].x},${sim.players[0].y})`);
console.log(`  inChatroom=${sim.players[0].inChatroom}`);
console.log(`  chatMenuOpen=${sim.players[0].chatMenuOpen}`);

// Player 0 creates a chatroom (press A)
const emptyInputs = [0, 1].map(() => emptyInput());
const prevInputs = [0, 1].map(() => emptyInput());

function step(masks: number[]) {
  const inputs: InputState[] = masks.map(m => decodeInputMask(m));
  const prevs = [...prevInputs];
  sim.step(inputs, prevs);
  // update prevInputs for next step
  for (let i = 0; i < 2; i++) prevInputs[i] = inputs[i];
}

// Step 1: Player 0 presses A to create chatroom
console.log("\n== Player 0 presses A to create chatroom ==");
step([BUTTON_A, 0]);
console.log(`  P0 inChatroom=${sim.players[0].inChatroom} chatMenuOpen=${sim.players[0].chatMenuOpen}`);

// Need to release A
step([0, 0]);
console.log(`  after release: P0 inChatroom=${sim.players[0].inChatroom}`);

// Step 2: Player 1 presses A too — does a separate chatroom get created?
console.log("\n== Player 1 presses A ==");
step([0, BUTTON_A]);
console.log(`  P1 inChatroom=${sim.players[1].inChatroom} pendingChatroomEntry=${sim.players[1].pendingChatroomEntry}`);
console.log(`  total chatrooms: ${sim.chatrooms.size}`);
step([0, 0]);

// Check P0 sees the WANTS IN indicator AND P1 sees waiting_entry phase
{
  const { render } = await import("./renderer.js");
  const { unpackFrame } = await import("./bot_utils.js");
  const { parseChatroomStatus, parsePhase } = await import("./frame_parser.js");
  const p0Buf = render(sim, 0);
  const p0Frame = unpackFrame(p0Buf);
  console.log(`  P0 parsed phase: ${parsePhase(p0Frame)}`);
  const s = parseChatroomStatus(p0Frame);
  console.log(`  P0 chatroom status: pendingEntry=${s.pendingEntry}`);

  // Direct sim-state check
  const cr = sim.chatrooms.get(sim.players[0].inChatroom);
  console.log(`  [SIM] chatroom pendingEntry=[${cr ? [...cr.pendingEntry].join(",") : "no cr"}] occupants=[${cr ? [...cr.occupants].join(",") : ""}]`);

  // Dump color-8 pixels in bottom half of P0's frame
  const { SCREEN_WIDTH, SCREEN_HEIGHT, BOTTOM_BAR_H } = await import("./constants.js");
  const barY = SCREEN_HEIGHT - BOTTOM_BAR_H;
  console.log(`  [P0 frame] barY=${barY}, scanning for color-8 pixels (y>=100):`);
  for (let y = 100; y < SCREEN_HEIGHT; y++) {
    let count = 0;
    const xs: number[] = [];
    for (let x = 0; x < SCREEN_WIDTH; x++) {
      if (p0Frame[y * SCREEN_WIDTH + x] === 8) { count++; xs.push(x); }
    }
    if (count > 0) console.log(`    y=${y}: ${count} color-8 pixels at x=[${xs.slice(0, 20).join(",")}...]`);
  }
  console.log(`  parser checks x=[2,4], y=[barY-9, barY-3]=[${barY - 9},${barY - 3}]`);
  console.log(`  Raw pixels at x=0..8, y=108..116:`);
  for (let y = 108; y < 117; y++) {
    const row: number[] = [];
    for (let x = 0; x < 10; x++) row.push(p0Frame[y * SCREEN_WIDTH + x]);
    console.log(`    y=${y}: [${row.join(",")}]`);
  }

  // Try readTextAt at the row/col where "WANTS IN" should be
  const { readTextAt } = await import("./frame_parser.js");
  console.log(`  readTextAt at various positions (color 8):`);
  for (let y = 108; y < 117; y++) {
    for (let x of [0, 2, 8, 10, 15, 17, 18, 19, 20, 22]) {
      const t = readTextAt(p0Frame, x, y, 8, 15);
      if (t.length > 0) console.log(`    y=${y} x=${x}: "${t}"`);
    }
  }

  const p1Buf = render(sim, 1);
  const p1Frame = unpackFrame(p1Buf);
  console.log(`  P1 parsed phase: ${parsePhase(p1Frame)}  (expected: waiting_entry)`);
}

// Step 3: P0 grants entry — navigate to LEADER cat, GRANT item
// But wait, we need to open chat menu first
console.log("\n== P0 opens chat menu (B) ==");
step([BUTTON_B, 0]);
console.log(`  P0 chatMenuOpen=${sim.players[0].chatMenuOpen} cat=${sim.players[0].chatMenuCat} item=${sim.players[0].chatMenuItem}`);
step([0, 0]);

// GRANT is in LEADER category
// Use chatMenuSequence helper
const grantSeq = chatMenuSequence("GRANT");
console.log(`  GRANT sequence: ${grantSeq.map((b, i) => i % 2 === 0 ? buttonName(b) : "0").join(",")}`);

// Actually we already opened the menu. Skip the first B, 0 of the sequence.
// But chatMenuSequence ALWAYS starts with B, 0 to open the menu. Since menu is already open,
// the first B will close it!
console.log("\n=> BUG HYPOTHESIS: chatMenuSequence starts with B which TOGGLES menu");

// Close menu first by pressing A (which cancels?) or SELECT. Actually menu closes via SELECT.
// Let's just start fresh with menu closed.
// Close menu
step([0, 0]); // already closed from previous? check
if (sim.players[0].chatMenuOpen) {
  console.log("Menu still open, closing with SELECT");
  step([0x10, 0]); // BUTTON_SELECT = 0x10
  step([0, 0]);
}
console.log(`  P0 chatMenuOpen=${sim.players[0].chatMenuOpen}`);

// Now run full GRANT sequence
console.log("\n== Running full GRANT sequence on P0 ==");
for (let i = 0; i < grantSeq.length; i++) {
  step([grantSeq[i], 0]);
  const p = sim.players[0];
  console.log(`  frame ${i}: sent ${buttonName(grantSeq[i])} | chatMenuOpen=${p.chatMenuOpen} cat=${p.chatMenuCat} item=${p.chatMenuItem}`);
}

// Step P1 through pending entry: should be granted now
console.log(`\n  After GRANT: P1 inChatroom=${sim.players[1].inChatroom} pendingChatroomEntry=${sim.players[1].pendingChatroomEntry}`);

// Now both should be in chatroom
if (sim.players[0].inChatroom >= 0 && sim.players[1].inChatroom >= 0) {
  console.log("\n== Both in chatroom. Now P0 runs chatMenuSequence('R.OFFER') ==");
  const roSeq = chatMenuSequence("R.OFFER");
  console.log(`  Sequence: ${roSeq.map((b, i) => i % 2 === 0 ? buttonName(b) : "0").join(",")}`);
  for (let i = 0; i < roSeq.length; i++) {
    step([roSeq[i], 0]);
    const p = sim.players[0];
    const cr = sim.chatrooms.get(p.inChatroom);
    const revealOffers = cr ? [...cr.revealOffers] : [];
    console.log(`  frame ${i}: sent ${buttonName(roSeq[i])} | chatMenuOpen=${p.chatMenuOpen} cat=${p.chatMenuCat} item=${p.chatMenuItem} revealOffers=[${revealOffers.join(",")}]`);
  }
  const cr = sim.chatrooms.get(sim.players[0].inChatroom);
  if (cr && cr.revealOffers.has(0)) {
    console.log("\n✅ R.OFFER registered in sim. revealOffers contains player 0.");
  } else {
    console.log("\n❌ R.OFFER did NOT register.");
  }

  // Now render P1's frame and check for R! indicator
  console.log("\n== Check P1 sees R! indicator in rendered frame ==");
  const { render } = await import("./renderer.js");
  const { unpackFrame, PACKED_FRAME_BYTES } = await import("./bot_utils.js");
  const { parseChatroomStatus, parsePhase } = await import("./frame_parser.js");
  const p1Buf = render(sim, 1);
  console.log(`  frame buffer length: ${p1Buf.length} (expected ${PACKED_FRAME_BYTES})`);
  const p1Frame = unpackFrame(p1Buf);
  const phase = parsePhase(p1Frame);
  console.log(`  P1 parsed phase: ${phase}`);
  const status = parseChatroomStatus(p1Frame);
  console.log(`  P1 chatroom status: pendingRoleOffer=${status.pendingRoleOffer} pendingColorOffer=${status.pendingColorOffer}`);

  // Also: P1's actions for role_accept
  console.log("\n== P1 runs chatMenuSequence('R.ACCPT') ==");
  const raSeq = chatMenuSequence("R.ACCPT");
  console.log(`  Sequence: ${raSeq.map((b, i) => i % 2 === 0 ? buttonName(b) : "0").join(",")}`);
  for (let i = 0; i < raSeq.length; i++) {
    step([0, raSeq[i]]);
    const p = sim.players[1];
    const cr = sim.chatrooms.get(p.inChatroom);
    console.log(`  frame ${i}: sent ${buttonName(raSeq[i])} | chatMenuOpen=${p.chatMenuOpen} cat=${p.chatMenuCat} item=${p.chatMenuItem} shareSelectOpen=${p.shareSelectOpen} shareSelectRow=${p.shareSelectRow} p1.sharedWith=${[...p.sharedWith].join(",")}`);
  }

  // Now need to confirm target in share select
  console.log("\n== P1 confirms target (press A) ==");
  step([0, BUTTON_A]);
  step([0, 0]);
  const p1 = sim.players[1];
  console.log(`  P1.sharedWith = [${[...p1.sharedWith].join(",")}]`);
  console.log(`  P0.sharedWith = [${[...sim.players[0].sharedWith].join(",")}]`);
  if (p1.sharedWith.has(0)) {
    console.log("✅ Mutual role exchange completed! P1 sharedWith P0.");
  } else {
    console.log("❌ Mutual role exchange did NOT complete.");
  }
} else {
  console.log("\n❌ Players not both in chatroom, can't test R.OFFER");
}

function buttonName(mask: number): string {
  if (mask === 0) return "---";
  const names: string[] = [];
  if (mask & BUTTON_A) names.push("A");
  if (mask & BUTTON_B) names.push("B");
  if (mask & BUTTON_LEFT) names.push("LEFT");
  if (mask & BUTTON_RIGHT) names.push("RIGHT");
  if (mask & BUTTON_UP) names.push("UP");
  if (mask & BUTTON_DOWN) names.push("DOWN");
  if (mask & 0x10) names.push("SELECT");
  return names.join("+") || `0x${mask.toString(16)}`;
}

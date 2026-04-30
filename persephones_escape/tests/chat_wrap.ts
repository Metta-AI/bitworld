import { Sim } from "../game/sim.js";
import { DEFAULT_GAME_CONFIG, CHAT_MAX_CHARS_PER_LINE, SCREEN_WIDTH, SCREEN_HEIGHT, PROTOCOL_BYTES } from "../game/constants.js";
import { render } from "../rendering/renderer.js";
import { Framebuffer } from "../rendering/framebuffer.js";
import { emptyInput } from "../game/protocol.js";

console.log(`CHAT_MAX_CHARS_PER_LINE = ${CHAT_MAX_CHARS_PER_LINE}`);

const sim = new Sim(DEFAULT_GAME_CONFIG, 42);
for (let i = 0; i < 10; i++) sim.addPlayer(`p${i}`);
sim.startGame();
sim.startRound();

// Put p0 in a chatroom, then add p1
sim.createChatroom(0);
const crId = sim.players[0].inChatroom;
const cr = sim.chatrooms.get(crId)!;
cr.occupants.add(1);
sim.players[1].inChatroom = crId;
sim.players[1].chatroomEntryTick = 0;

function advanceTicks(n: number) {
  for (let t = 0; t < n; t++) {
    const inputs = sim.players.map(() => emptyInput());
    sim.step(inputs, inputs);
  }
}

function textMessages() {
  return cr.messages.filter(m => m.type === "text");
}

// Clear rate limit
advanceTicks(120);

// --- Test 1: 36-char message wraps into two 18-char lines ---
const msg = "HELLO WORLD THIS IS A LONG MSG TEST!";
console.log(`\nTest 1: Wrap long message`);
console.log(`  Sending: "${msg}" (len=${msg.length})`);
sim.addChatroomChat(crId, 0, msg);

const msgs1 = textMessages();
console.assert(msgs1.length === 2, `Expected 2 messages, got ${msgs1.length}`);
console.assert(msgs1[0].text === "HELLO WORLD THIS I", `Line 1: "${msgs1[0].text}"`);
console.assert(msgs1[0].text.length === 18, `Line 1 len: ${msgs1[0].text.length}`);
console.assert(msgs1[1].text === "S A LONG MSG TEST!", `Line 2: "${msgs1[1].text}"`);
console.assert(msgs1[1].text.length === 18, `Line 2 len: ${msgs1[1].text.length}`);
console.log(`  OK: "${msgs1[0].text}" + "${msgs1[1].text}"`);

// --- Test 2: Exactly 18 chars stays as one line ---
advanceTicks(120);
const before2 = textMessages().length;
sim.addChatroomChat(crId, 0, "EXACTLY 18 CHARS!!");
const after2 = textMessages();
console.log(`\nTest 2: Exactly 18 chars`);
console.assert(after2.length === before2 + 1, `Expected ${before2 + 1} messages, got ${after2.length}`);
console.assert(after2[after2.length - 1].text === "EXACTLY 18 CHARS!!", `Text: "${after2[after2.length - 1].text}"`);
console.assert(after2[after2.length - 1].text.length === 18, `Len: ${after2[after2.length - 1].text.length}`);
console.log(`  OK: "${after2[after2.length - 1].text}"`);

// --- Test 3: Short message stays as one line ---
advanceTicks(120);
const before3 = textMessages().length;
sim.addChatroomChat(crId, 0, "hi");
const after3 = textMessages();
console.log(`\nTest 3: Short message`);
console.assert(after3.length === before3 + 1, `Expected ${before3 + 1} messages, got ${after3.length}`);
console.assert(after3[after3.length - 1].text === "hi", `Text: "${after3[after3.length - 1].text}"`);
console.log(`  OK: "${after3[after3.length - 1].text}"`);

// --- Test 4: Message >36 chars is capped at 2 lines ---
advanceTicks(120);
const before4 = textMessages().length;
sim.addChatroomChat(crId, 0, "A".repeat(50));
const after4 = textMessages();
console.log(`\nTest 4: >36 chars capped at 2 lines`);
console.assert(after4.length === before4 + 2, `Expected ${before4 + 2} messages, got ${after4.length}`);
console.assert(after4[after4.length - 2].text.length === 18, `Line 1 len: ${after4[after4.length - 2].text.length}`);
console.assert(after4[after4.length - 1].text.length === 18, `Line 2 len: ${after4[after4.length - 1].text.length}`);
console.log(`  OK: 2 lines of 18 chars each (50 char input truncated to 36)`);

// --- Test 5: Rate-limited message is rejected ---
sim.addChatroomChat(crId, 0, "should fail");
const after5 = textMessages();
console.log(`\nTest 5: Rate-limited rejection`);
console.assert(after5.length === after4.length, `Expected ${after4.length} (unchanged), got ${after5.length}`);
console.log(`  OK: message rejected (rate limited)`);

// --- Test 6: Wrapped lines render in the framebuffer ---
advanceTicks(120);
sim.addChatroomChat(crId, 0, "LINE ONE RENDER!! LINE TWO RENDER!!");

let viewerIdx = -1;
for (let i = 0; i < sim.players.length; i++) {
  if (sim.players[i].inChatroom === crId) { viewerIdx = i; break; }
}

const packed = render(sim, viewerIdx);
const frame = new Uint8Array(SCREEN_WIDTH * SCREEN_HEIGHT);
for (let i = 0; i < PROTOCOL_BYTES; i++) {
  frame[i * 2] = packed[i] & 0x0f;
  frame[i * 2 + 1] = (packed[i] >> 4) & 0x0f;
}

let nonEmptyRows = 0;
for (let y = 0; y < SCREEN_HEIGHT; y++) {
  let hasContent = false;
  for (let x = 0; x < SCREEN_WIDTH; x++) {
    if (frame[y * SCREEN_WIDTH + x] > 0) { hasContent = true; break; }
  }
  if (hasContent) nonEmptyRows++;
}

console.log(`\nTest 6: Frame renders`);
console.assert(nonEmptyRows > 10, `Expected >10 non-empty rows, got ${nonEmptyRows}`);
console.log(`  OK: ${nonEmptyRows} non-empty rows in rendered frame`);

console.log("\nAll tests passed.");

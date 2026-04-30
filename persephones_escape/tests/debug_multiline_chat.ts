/**
 * Integration test: send a chat message longer than 18 chars, confirm it
 * renders as two fragments in the chatroom (separately displayable), and
 * that coalesceChatFragments merges them back.
 */

import { Sim } from "../sim.js";
import { DEFAULT_GAME_CONFIG, CHAT_MAX_CHARS_PER_LINE, CHAT_MAX_TOTAL } from "../constants.js";
import { coalesceChatFragments } from "../util.js";
import { Team, Role } from "../types.js";

const sim = new Sim(
  {
    ...DEFAULT_GAME_CONFIG,
    roles: [
      { role: Role.Hades, team: Team.TeamA, count: 1 },
      { role: Role.Persephone, team: Team.TeamB, count: 1 },
      { role: Role.Cerberus, team: Team.TeamA, count: 1 },
      { role: Role.Demeter, team: Team.TeamB, count: 1 },
      { role: Role.Shades, team: Team.TeamA, count: 1 },
      { role: Role.Nymphs, team: Team.TeamB, count: 1 },
    ],
    rounds: [{ durationSecs: 60, hostages: 1 }],
    obstacleCount: 0,
  },
  42,
);
for (let i = 0; i < 6; i++) sim.addPlayer(`p${i}`);
sim.startGame();
sim.startRound();

// P0 shouts a 30-char message into global chat.
const msg = "hello team meet at 50 50";
sim.addGlobalChat(0, msg);

// Raw messages should be one or two fragments (one here because 24 < 36).
const roomMsgs = sim.globalMessagesForPlayer(0);
console.log(`raw fragments (len=${msg.length}, perLine=${CHAT_MAX_CHARS_PER_LINE}):`);
for (const m of roomMsgs) console.log(`  "${m.text}" (len=${m.text.length})`);

// Try a multi-line case
const long = "alpha bravo charlie delta echo foxtrot";
sim.addGlobalChat(1, long);
const roomMsgs2 = sim.globalMessagesForPlayer(0);
console.log(`\nafter long shout ("${long}" len=${long.length}):`);
for (const m of roomMsgs2) console.log(`  from=${m.senderIndex} tick=${m.tick} "${m.text}"`);

const coalesced = coalesceChatFragments(roomMsgs2);
console.log(`\ncoalesced:`);
for (const m of coalesced) console.log(`  from=${m.senderIndex} tick=${m.tick} "${m.text}" (len=${m.text.length})`);

// Verify the second sender's fragments merged back to a single message.
const last = coalesced[coalesced.length - 1];
const expected = long.slice(0, CHAT_MAX_TOTAL);  // anything past 36 chars is truncated
if (last.text === expected && coalesced.length === 2) {
  console.log(`\n✅ multi-line fragments coalesced: "${last.text}"`);
} else {
  console.log(`\n❌ mismatch — expected "${expected}", got "${last.text}"`);
  process.exit(1);
}

// Test the shout-task truncation reason. Mock a minimal executor call:
{
  const { runTasks, createTaskInstance, createEventBuffer, eventBufferLines } = await import("./tasks.js");
  const { createBeliefState, updatePhase, updatePosition, updateHud } = await import("./belief_state.js");
  const { unpackFrame, ActionQueue } = await import("./bot_utils.js");
  const { render } = await import("./renderer.js");
  const mockWs = { readyState: 1, send: (_: Buffer) => {} };
  const belief = createBeliefState("p0");
  const f = unpackFrame(render(sim, 0));
  updatePhase(belief, f); updatePosition(belief, f); updateHud(belief, f);
  const bot = { ws: mockWs as any, actions: new ActionQueue(), belief, name: "p0",
    movementTarget: null, wandering: false, wanderTarget: null, wanderTicks: 0 };

  // Short shout — no truncation
  const shortTask = createTaskInstance({ kind: "shout", text: "hi team" }, belief.tick);
  const buf = createEventBuffer();
  runTasks([shortTask], bot as any, mockWs as any, buf);

  // Long shout — should report truncation
  const longTask = createTaskInstance(
    { kind: "shout", text: "this message is way way way too long to fit in 36 chars" },
    belief.tick,
  );
  runTasks([longTask], bot as any, mockWs as any, buf);

  console.log(`\n--- events ---\n${eventBufferLines(buf).join("\n")}`);

  const fireEvents = buf.events.filter(e => e.kind === "fired");
  if (fireEvents.length !== 2) { console.log(`❌ expected 2 fired, got ${fireEvents.length}`); process.exit(1); }
  if (fireEvents[0].reason?.includes("TRUNCATED")) { console.log(`❌ short message should not be truncated`); process.exit(1); }
  if (!fireEvents[1].reason?.includes("TRUNCATED")) { console.log(`❌ long message should be truncated`); process.exit(1); }
  console.log("\n✅ shout fired events include truncated text and warning");
}

process.exit(0);

/**
 * Tiny test: send a shout via addGlobalChat, render, check parseLastShout.
 */
import { Sim } from "./sim.js";
import { DEFAULT_GAME_CONFIG } from "./constants.js";
import { Phase } from "./types.js";
import { render } from "./renderer.js";
import { unpackFrame } from "./bot_utils.js";
import { parseLastShout, parsePhase } from "./frame_parser.js";

const sim = new Sim({ ...DEFAULT_GAME_CONFIG, rounds: [{ durationSecs: 60, hostages: 1 }], obstacleCount: 0 }, 42);
for (let i = 0; i < 2; i++) sim.addPlayer(`p${i}`);
sim.startGame();
sim.startRound();

sim.players[0].room = 0;
sim.players[1].room = 0;
sim.players[0].x = 50; sim.players[0].y = 50;
sim.players[1].x = 60; sim.players[1].y = 50;

sim.addGlobalChat(1, "meet at 10 10");
console.log(`globalMessagesA.length=${sim.globalMessagesA.length}`);
console.log(`messages for P0: ${JSON.stringify(sim.globalMessagesForPlayer(0))}`);

const p0Buf = render(sim, 0);
const p0Frame = unpackFrame(p0Buf);

console.log(`phase: ${parsePhase(p0Frame)}`);
console.log(`last shout: ${parseLastShout(p0Frame)}`);

// Scan the strip row and dump colors
const { SCREEN_WIDTH, SCREEN_HEIGHT, BOTTOM_BAR_H } = await import("./constants.js");
const stripY = SCREEN_HEIGHT - BOTTOM_BAR_H - 7;
console.log(`stripY=${stripY}`);
for (let y = stripY - 1; y < stripY + 6; y++) {
  const row: number[] = [];
  for (let x = 0; x < SCREEN_WIDTH; x++) row.push(p0Frame[y * SCREEN_WIDTH + x]);
  const nonzero = row.map((v, i) => v === 0 ? -1 : i).filter(i => i >= 0);
  console.log(`y=${y}: non-zero pixels at x=[${nonzero.slice(0, 30).join(",")}${nonzero.length > 30 ? "..." : ""}]`);
  const colors = [...new Set(row.filter(v => v !== 0))];
  console.log(`  unique colors: [${colors.join(",")}]`);
}

/**
 * Debug: connect to server, capture frames, and dump role reveal info.
 * tsx debug_frame.ts [ws://localhost:PORT/player]
 */
import WebSocket from "ws";
import { PACKED_FRAME_BYTES, unpackFrame } from "../bot_utils.js";
import { SCREEN_WIDTH, SCREEN_HEIGHT } from "../constants.js";
import { parsePhase, parseRoleRevealScreen, readTextAt } from "../frame_parser.js";

const url = process.argv[2] ?? "ws://localhost:8080/player";
const ws = new WebSocket(`${url}?name=debug_probe`, { perMessageDeflate: false });

let frameCount = 0;
let lastPhase = "";
let dumped = false;

ws.on("message", (data: Buffer) => {
  if (data.length !== PACKED_FRAME_BYTES) return;
  const frame = unpackFrame(data);
  frameCount++;
  const phase = parsePhase(frame);

  if (phase !== lastPhase) {
    console.log(`Frame ${frameCount}: phase changed to '${phase}'`);
    lastPhase = phase;
  }

  if (phase === "role_reveal" && !dumped) {
    dumped = true;
    console.log("\n=== ROLE REVEAL FRAME DUMP ===");
    console.log(`Border pixel (0,0)=${frame[0]} (2,2)=${frame[2*SCREEN_WIDTH+2]} (4,4)=${frame[4*SCREEN_WIDTH+4]}`);

    // Dump text at various Y positions with color 2 (white)
    for (let y = 0; y < 80; y++) {
      for (const color of [1, 2, frame[0]]) {
        const text = readTextAt(frame, 0, y, color, 30);
        if (text.length > 0) {
          console.log(`  y=${y} color=${color}: '${text}'`);
        }
      }
      // Also try centered text
      for (const color of [1, 2, frame[0]]) {
        for (let x = 10; x < 60; x += 4) {
          const text = readTextAt(frame, x, y, color, 20);
          if (text.length > 0) {
            console.log(`  y=${y} x=${x} color=${color}: '${text}'`);
            break;
          }
        }
      }
    }

    const info = parseRoleRevealScreen(frame);
    console.log("\nparseRoleRevealScreen result:", info);

    // Dump some raw pixel values to see what colors are where
    console.log("\nRaw pixels at key Y positions:");
    for (const y of [12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 44, 46, 48, 50, 52, 54, 56]) {
      const row: number[] = [];
      for (let x = 0; x < SCREEN_WIDTH; x++) {
        row.push(frame[y * SCREEN_WIDTH + x]);
      }
      const nonzero = row.filter(v => v !== 0);
      if (nonzero.length > 0) {
        const unique = [...new Set(nonzero)];
        console.log(`  y=${y}: ${nonzero.length} non-zero pixels, colors: [${unique.join(",")}]`);
      } else {
        console.log(`  y=${y}: all zero`);
      }
    }

    setTimeout(() => { ws.close(); process.exit(0); }, 500);
  }

  if (phase === "playing" && !dumped) {
    console.log("Game started without capturing role reveal, continuing...");
  }
});

ws.on("open", () => console.log(`Connected to ${url}`));
ws.on("close", () => process.exit(0));
ws.on("error", (e) => { console.error(e.message); process.exit(1); });

import WebSocket from "ws";
import { PACKED_FRAME_BYTES, unpackFrame, readPosition } from "./bot_utils.js";
import { parsePhase, parsePlayingHud, parseRoleRevealScreen, readTextAt } from "./frame_parser.js";
import { SCREEN_WIDTH } from "./constants.js";

const ws = new WebSocket("ws://localhost:8080/player?name=probe", { perMessageDeflate: false });
let count = 0;
let lastPhase = "";

ws.on("open", () => console.log("probe connected"));
ws.on("message", (data: Buffer) => {
  if (data.length !== PACKED_FRAME_BYTES) return;
  count++;
  const frame = unpackFrame(data);
  const phase = parsePhase(frame);

  // Log on phase transitions or every 2 seconds
  if (phase !== lastPhase || count % 48 === 1) {
    if (phase !== lastPhase) {
      console.log(`\n=== PHASE TRANSITION: ${lastPhase || "none"} → ${phase} (tick ${count}) ===`);
      lastPhase = phase;
    }

    if (phase === "playing") {
      const hud = parsePlayingHud(frame);
      if (hud) {
        console.log(`  HUD: R${hud.round} ${hud.timerSecs}s role=${hud.roleName ?? "?"} roleColor=${hud.roleColor}`);
      }
    } else if (phase === "role_reveal") {
      const reveal = parseRoleRevealScreen(frame);
      if (reveal) {
        console.log(`  REVEAL: role=${reveal.role} team=${reveal.team} room=${reveal.room} teamColor=${reveal.teamColor}`);
      } else {
        console.log(`  REVEAL: (could not parse)`);
      }
    } else if (phase === "hostage_select") {
      for (const color of [1, 8]) {
        const t = readTextAt(frame, 2, 2, color, 20);
        if (t.length > 0) console.log(`  HOSTAGE HUD (color=${color}): "${t}"`);
      }
    } else if (phase === "lobby") {
      const t = readTextAt(frame, 2, 2, 2, 15);
      console.log(`  LOBBY: "${t}"`);
    } else if (phase === "unknown") {
      // Dump HUD area for debugging
      for (const color of [1, 2, 3, 7, 8, 14]) {
        const t = readTextAt(frame, 2, 2, color, 15);
        if (t.length > 0) console.log(`  readTextAt(2,2,color=${color}): "${t}"`);
      }
    }

    const pos = readPosition(frame);
    if (pos) console.log(`  pos=(${pos.x},${pos.y})`);
  }

  if (count > 2400) { ws.close(); process.exit(0); }
});
ws.on("error", (e) => console.error(e.message));

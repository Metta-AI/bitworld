import WebSocket from "ws";
import { PACKET_INPUT } from "../game/constants.js";

const url = process.env.COGAMES_ENGINE_WS_URL;
if (!url) throw new Error("COGAMES_ENGINE_WS_URL is required");

const ws = new WebSocket(url, { perMessageDeflate: false });
const idle = Buffer.from([PACKET_INPUT, 0]);
let timer: NodeJS.Timeout | null = null;

ws.on("open", () => {
  timer = setInterval(() => {
    if (ws.readyState === WebSocket.OPEN) ws.send(idle);
  }, 100);
});

ws.on("message", () => {
  if (ws.readyState === WebSocket.OPEN) ws.send(idle);
});

ws.on("close", () => {
  if (timer) clearInterval(timer);
  process.exit(0);
});

ws.on("error", (err) => {
  console.error(`coworld player error: ${err.message}`);
});

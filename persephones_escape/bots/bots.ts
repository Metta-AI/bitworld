import WebSocket from "ws";
import { argv } from "process";

const count = parseInt(argv[2] ?? "5");
const url = argv[3] ?? "ws://localhost:8080/player";

const bots: WebSocket[] = [];

for (let i = 0; i < count; i++) {
  const name = `bot_${i + 1}`;
  const ws = new WebSocket(`${url}?name=${name}`, { perMessageDeflate: false });

  ws.on("open", () => {
    console.log(`${name} connected`);
    // Send an idle input packet every 500ms to keep the connection alive
    const idle = Buffer.from([0x00, 0x00]); // PacketInput, no buttons
    setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(idle);
      }
    }, 500);
  });

  ws.on("message", () => {
    // Discard frames
  });

  ws.on("close", () => {
    console.log(`${name} disconnected`);
  });

  ws.on("error", (err) => {
    console.error(`${name} error:`, err.message);
  });

  bots.push(ws);
}

process.on("SIGINT", () => {
  for (const ws of bots) ws.close();
  process.exit(0);
});

console.log(`Connecting ${count} bots to ${url}...`);

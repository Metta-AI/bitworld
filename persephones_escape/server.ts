import { WebSocketServer, WebSocket } from "ws";
import { createServer } from "http";
import { argv } from "process";
import { Phase, type InputState } from "./types.js";
import { GAME_NAME, TARGET_FPS } from "./constants.js";
import { decodeInputMask, emptyInput, isInputPacket, isChatPacket, blobToMask, blobToChat } from "./protocol.js";
import { Sim } from "./sim.js";
import { render } from "./renderer.js";
import { buildGlobalFrame } from "./globalViewer.js";
import { ReplayRecorder } from "./replay.js";

interface ClientState {
  ws: WebSocket;
  playerIndex: number;
  inputMask: number;
  prevInputMask: number;
  name: string;
}

const PENDING = 0x7fffffff;

function main() {
  let host = "localhost";
  let port = 8080;
  let replayPath: string | null = null;
  let seed = 0xb1770;

  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith("--address=")) host = arg.slice("--address=".length);
    else if (arg.startsWith("--port=")) port = parseInt(arg.slice("--port=".length));
    else if (arg.startsWith("--replay=")) replayPath = arg.slice("--replay=".length);
    else if (arg.startsWith("--seed=")) seed = parseInt(arg.slice("--seed=".length));
    else if (i === 2 && !arg.startsWith("-")) host = arg;
    else if (i === 3 && !arg.startsWith("-")) port = parseInt(arg);
  }

  const sim = new Sim(undefined, seed);
  const clients = new Map<WebSocket, ClientState>();
  const globalViewers = new Set<WebSocket>();
  const recorder = replayPath
    ? new ReplayRecorder(seed, replayPath, JSON.stringify({ seed }))
    : null;

  const httpServer = createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end(`${GAME_NAME} WebSocket server`);
  });

  const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });
  const globalWss = new WebSocketServer({ noServer: true, perMessageDeflate: false });

  httpServer.on("upgrade", (req, socket, head) => {
    const { pathname } = new URL(req.url ?? "/", `http://${req.headers.host}`);
    if (pathname === "/player") {
      wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
    } else if (pathname === "/global") {
      globalWss.handleUpgrade(req, socket, head, (ws) => globalWss.emit("connection", ws, req));
    } else {
      socket.destroy();
    }
  });

  globalWss.on("connection", (ws) => {
    globalViewers.add(ws);
    ws.on("close", () => globalViewers.delete(ws));
    ws.on("error", () => { globalViewers.delete(ws); ws.close(); });
  });

  wss.on("connection", (ws, req) => {
    const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
    const name = url.searchParams.get("name") ?? "unknown";

    const client: ClientState = {
      ws, playerIndex: PENDING,
      inputMask: 0, prevInputMask: 0,
      name: name.replace(/\s+/g, "_").trim() || "unknown",
    };
    clients.set(ws, client);

    ws.on("message", (data: Buffer) => {
      if (isInputPacket(data)) {
        const mask = blobToMask(data);
        if (mask === 255) { client.inputMask = 0; client.prevInputMask = 0; }
        else client.inputMask = mask;
      } else if (isChatPacket(data) && client.playerIndex !== PENDING) {
        const text = blobToChat(data);
        if (text.length > 0) {
          const p = sim.players[client.playerIndex];
          if (p && p.inChatroom >= 0) {
            sim.addChatroomChat(p.inChatroom, client.playerIndex, text);
          } else {
            sim.addGlobalChat(client.playerIndex, text);
          }
        }
      }
    });

    ws.on("close", () => {
      const c = clients.get(ws);
      if (c && c.playerIndex !== PENDING && c.playerIndex < sim.players.length) {
        recorder?.writeLeave(c.playerIndex);
        sim.removePlayer(c.playerIndex);
        for (const [, other] of clients) {
          if (other !== c && other.playerIndex > c.playerIndex && other.playerIndex !== PENDING) {
            other.playerIndex--;
          }
        }
      }
      clients.delete(ws);
    });

    ws.on("error", () => ws.close());
  });

  httpServer.listen(port, host, () => {
    console.log(`${GAME_NAME} listening on ws://${host}:${port}/player`);
    if (recorder) console.log(`Recording replay to ${replayPath}`);
  });

  let lastTick = performance.now();
  const frameDuration = 1000 / TARGET_FPS;

  function gameLoop() {
    const now = performance.now();
    if (now - lastTick < frameDuration) {
      setTimeout(gameLoop, Math.max(1, frameDuration - (now - lastTick)));
      return;
    }
    lastTick = now;

    for (const [, client] of clients) {
      if (client.playerIndex === PENDING && sim.phase === Phase.Lobby) {
        const pi = sim.addPlayer(client.name);
        if (pi >= 0) {
          client.playerIndex = pi;
          recorder?.writeJoin(pi, client.name);
        }
      }
    }

    const inputMasks: number[] = new Array(sim.players.length).fill(0);
    const inputs: InputState[] = new Array(sim.players.length).fill(null).map(() => emptyInput());
    const prevInputs: InputState[] = new Array(sim.players.length).fill(null).map(() => emptyInput());
    for (const [, client] of clients) {
      if (client.playerIndex >= 0 && client.playerIndex < sim.players.length) {
        inputMasks[client.playerIndex] = client.inputMask;
        inputs[client.playerIndex] = decodeInputMask(client.inputMask);
        prevInputs[client.playerIndex] = decodeInputMask(client.prevInputMask);
      }
    }

    try { sim.step(inputs, prevInputs); } catch (e) { console.error("step error:", e); }

    recorder?.recordTick(inputMasks);

    if (sim.tickCount % (TARGET_FPS * 5) === 1) {
      console.log(`tick=${sim.tickCount} phase=${Phase[sim.phase]} players=${sim.players.length}`);
    }

    for (const [ws, client] of clients) {
      if (client.playerIndex >= 0 && client.playerIndex < sim.players.length) {
        try { ws.send(render(sim, client.playerIndex)); } catch { /* cleanup on close */ }
      }
      client.prevInputMask = client.inputMask;
    }

    if (globalViewers.size > 0) {
      const frame = buildGlobalFrame(sim);
      for (const ws of globalViewers) {
        try { ws.send(frame); } catch { /* cleanup on close */ }
      }
    }

    setTimeout(gameLoop, Math.max(1, frameDuration - (performance.now() - lastTick)));
  }

  function shutdown() {
    if (recorder) {
      console.log(`Saving replay (${recorder.tickCount} ticks) to ${replayPath}`);
      recorder.close();
    }
    process.exit(0);
  }

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  gameLoop();
}

main();

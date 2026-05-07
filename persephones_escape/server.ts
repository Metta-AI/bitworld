/**
 * Persephone's Escape server.
 *
 * Modes:
 *   freeplay    Local browser/dev mode. Players join /player?name=...
 *   tournament Coworld mode. Players join /player?slot=N&token=...
 *   replay     Coworld replay mode. Serves /replay from COGAME_LOAD_REPLAY_PATH.
 */
import { WebSocketServer, WebSocket } from "ws";
import { createServer, type IncomingMessage, type ServerResponse } from "http";
import { argv, env, exit } from "process";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { execFileSync } from "child_process";
import { Phase, Team, type InputState, type GameConfig } from "./game/types.js";
import { GAME_NAME, TARGET_FPS, playerSpriteName, DEFAULT_GAME_CONFIG, playerCountFromConfig } from "./game/constants.js";
import { decodeInputMask, emptyInput, isInputPacket, isChatPacket, blobToMask, blobToChat } from "./game/protocol.js";
import { Sim } from "./game/sim.js";
import { resolveConfigName, loadConfigFile } from "./game/config_presets.js";
import { render } from "./rendering/renderer.js";
import { buildGlobalFrame } from "./rendering/globalViewer.js";
import { ReplayRecorder, loadReplay } from "./replay.js";

type ServerMode = "freeplay" | "tournament" | "replay";

interface ClientState {
  ws: WebSocket;
  playerIndex: number;
  inputMask: number;
  prevInputMask: number;
  name: string;
}

interface SlotState {
  slot: number;
  token: string;
  ws: WebSocket | null;
  playerIndex: number;
  inputMask: number;
  prevInputMask: number;
  name: string;
}

interface RuntimeOptions {
  mode: ServerMode;
  host: string;
  port: number;
  replayPath: string | null;
  seed: number;
  config: GameConfig;
  configSource: string;
  tokens: string[];
  resultsPath: string | null;
  saveReplayPath: string | null;
  loadReplayPath: string | null;
}

const PENDING = 0x7fffffff;
const __dirname = dirname(fileURLToPath(import.meta.url));

function main() {
  const opts = resolveRuntimeOptions();
  if (opts.mode === "replay") {
    runReplayServer(opts);
    return;
  }
  runGameServer(opts);
}

function resolveRuntimeOptions(): RuntimeOptions {
  let host = env.COGAME_CONFIG_PATH || env.COGAME_LOAD_REPLAY_PATH ? "0.0.0.0" : "localhost";
  let port = 8080;
  let replayPath: string | null = null;
  let seed = 0xb1770;
  let configName: string | null = null;
  let configFile: string | null = null;
  let mode: ServerMode | null = null;

  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith("--mode=")) mode = parseMode(arg.slice("--mode=".length));
    else if (arg.startsWith("--address=")) host = arg.slice("--address=".length);
    else if (arg.startsWith("--port=")) port = parseInt(arg.slice("--port=".length), 10);
    else if (arg.startsWith("--replay=")) replayPath = arg.slice("--replay=".length);
    else if (arg.startsWith("--seed=")) seed = parseInt(arg.slice("--seed=".length), 10);
    else if (arg.startsWith("--config=")) configName = arg.slice("--config=".length);
    else if (arg.startsWith("--config-file=")) configFile = arg.slice("--config-file=".length);
    else if (i === 2 && !arg.startsWith("-")) host = arg;
    else if (i === 3 && !arg.startsWith("-")) port = parseInt(arg, 10);
  }

  if (env.COGAME_LOAD_REPLAY_PATH) mode = "replay";
  else if (env.COGAME_CONFIG_PATH) mode = "tournament";
  mode ??= "freeplay";

  if (configName && configFile) {
    console.error("Error: --config and --config-file are mutually exclusive. Pick one.");
    exit(1);
  }

  let config: GameConfig;
  let configSource: string;
  let tokens: string[] = [];
  if (env.COGAME_CONFIG_PATH) {
    const raw = readJsonObject(env.COGAME_CONFIG_PATH);
    config = loadConfigFile(env.COGAME_CONFIG_PATH);
    tokens = readTokens(raw, env.COGAME_CONFIG_PATH);
    seed = readOptionalInteger(raw.seed, seed, "seed");
    configSource = env.COGAME_CONFIG_PATH;
    if (raw.mode !== "tournament") {
      throw new Error(`Tournament config must include "mode": "tournament" in ${env.COGAME_CONFIG_PATH}`);
    }
  } else if (configFile) {
    config = loadConfigFile(configFile);
    configSource = configFile;
  } else if (configName) {
    config = resolveConfigName(configName);
    configSource = configName;
  } else {
    config = DEFAULT_GAME_CONFIG;
    configSource = "default";
  }

  if (mode === "tournament") {
    const expected = playerCountFromConfig(config);
    if (tokens.length !== expected) {
      throw new Error(`Tournament config tokens length (${tokens.length}) must match player count (${expected})`);
    }
    replayPath = env.COGAME_SAVE_REPLAY_PATH ?? replayPath;
  }

  return {
    mode,
    host,
    port,
    replayPath,
    seed,
    config,
    configSource,
    tokens,
    resultsPath: env.COGAME_RESULTS_PATH ?? null,
    saveReplayPath: env.COGAME_SAVE_REPLAY_PATH ?? null,
    loadReplayPath: env.COGAME_LOAD_REPLAY_PATH ?? null,
  };
}

function runGameServer(opts: RuntimeOptions) {
  killExistingPortListener(opts.port);
  const sim = new Sim(opts.config, opts.seed);
  const freeplayClients = new Map<WebSocket, ClientState>();
  const slots = opts.tokens.map((token, slot): SlotState => ({
    slot,
    token,
    ws: null,
    playerIndex: PENDING,
    inputMask: 0,
    prevInputMask: 0,
    name: `slot_${slot}`,
  }));
  const globalViewers = new Set<WebSocket>();
  const recorder = opts.replayPath
    ? new ReplayRecorder(opts.seed, opts.replayPath, JSON.stringify({ seed: opts.seed, config: opts.config }))
    : null;

  const httpServer = createServer((req, res) => handleHttp(req, res, opts));
  const playerWss = new WebSocketServer({ noServer: true, perMessageDeflate: false });
  const globalWss = new WebSocketServer({ noServer: true, perMessageDeflate: false });

  httpServer.on("upgrade", (req, socket, head) => {
    const { pathname } = new URL(req.url ?? "/", `http://${req.headers.host}`);
    if (pathname === "/player") {
      if (opts.mode === "tournament" && !validTournamentRequest(req, slots)) {
        socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      playerWss.handleUpgrade(req, socket, head, (ws) => playerWss.emit("connection", ws, req));
    } else if (pathname === "/global") {
      globalWss.handleUpgrade(req, socket, head, (ws) => globalWss.emit("connection", ws, req));
    } else {
      socket.destroy();
    }
  });

  globalWss.on("connection", (ws) => {
    globalViewers.add(ws);
    try { ws.send(buildGlobalFrame(sim)); } catch { /* best effort initial snapshot */ }
    ws.on("close", () => globalViewers.delete(ws));
    ws.on("error", () => { globalViewers.delete(ws); ws.close(); });
  });

  playerWss.on("connection", (ws, req) => {
    if (opts.mode === "tournament") {
      attachTournamentPlayer(ws, req, slots, sim, recorder);
    } else {
      attachFreeplayPlayer(ws, req, freeplayClients, sim, recorder);
    }
  });

  httpServer.listen(opts.port, opts.host, () => {
    console.log(`${GAME_NAME} ${opts.mode} listening on ${opts.host}:${opts.port}`);
    console.log(`Config: ${opts.configSource} (${playerCountFromConfig(opts.config)} players, ${opts.config.rounds.length} rounds)`);
    if (recorder) console.log(`Recording replay to ${opts.replayPath}`);
  });

  let finalizing = false;
  let lastTick = performance.now();
  const frameDuration = 1000 / TARGET_FPS;

  function gameLoop() {
    const now = performance.now();
    if (now - lastTick < frameDuration) {
      setTimeout(gameLoop, Math.max(1, frameDuration - (now - lastTick)));
      return;
    }
    lastTick = now;

    if (opts.mode === "tournament") {
      const readyToSeatSlots = sim.phase === Phase.Lobby &&
        slots.some(slot => slot.playerIndex === PENDING) &&
        slots.every(slot => slot.playerIndex !== PENDING || slot.ws !== null);
      if (readyToSeatSlots) {
        for (const slot of slots) {
          const pi = sim.addPlayer(slot.name);
          if (pi >= 0) {
            slot.playerIndex = pi;
            recorder?.writeJoin(pi, slot.name);
          }
        }
      }
    } else {
      for (const [, client] of freeplayClients) {
        if (client.playerIndex === PENDING && sim.phase === Phase.Lobby) {
          const pi = sim.addPlayer(client.name);
          if (pi >= 0) {
            client.playerIndex = pi;
            recorder?.writeJoin(pi, client.name);
          }
        }
      }
    }

    const inputMasks: number[] = new Array(sim.players.length).fill(0);
    const inputs: InputState[] = new Array(sim.players.length).fill(null).map(() => emptyInput());
    const prevInputs: InputState[] = new Array(sim.players.length).fill(null).map(() => emptyInput());
    const participants = opts.mode === "tournament" ? slots : [...freeplayClients.values()];
    for (const client of participants) {
      if (client.playerIndex >= 0 && client.playerIndex < sim.players.length) {
        inputMasks[client.playerIndex] = client.inputMask;
        inputs[client.playerIndex] = decodeInputMask(client.inputMask);
        prevInputs[client.playerIndex] = decodeInputMask(client.prevInputMask);
      }
    }

    const prevPhase = sim.phase;
    try { sim.step(inputs, prevInputs); } catch (e) { console.error("step error:", e); }

    if (sim.phase === Phase.GameOver && prevPhase !== Phase.GameOver) {
      writeGameLogs(sim);
      if (opts.mode === "tournament" && !finalizing) {
        finalizing = true;
        finalizeTournament(opts, sim, recorder);
        setTimeout(() => {
          httpServer.close(() => exit(0));
          for (const ws of globalViewers) ws.close();
          for (const slot of slots) slot.ws?.close();
        }, 250);
      }
    }

    recorder?.recordTick(inputMasks);

    if (sim.tickCount % (TARGET_FPS * 5) === 1) {
      console.log(`tick=${sim.tickCount} phase=${Phase[sim.phase]} players=${sim.players.length}`);
    }

    for (const client of participants) {
      if (client.playerIndex >= 0 && client.playerIndex < sim.players.length && client.ws) {
        try { client.ws.send(render(sim, client.playerIndex)); } catch { /* cleanup on close */ }
      }
      client.prevInputMask = client.inputMask;
    }

    if (globalViewers.size > 0) {
      const frame = buildGlobalFrame(sim);
      for (const ws of globalViewers) {
        try { ws.send(frame); } catch { /* cleanup on close */ }
      }
    }

    if (!finalizing) setTimeout(gameLoop, Math.max(1, frameDuration - (performance.now() - lastTick)));
  }

  function shutdown() {
    if (recorder) {
      console.log(`Saving replay (${recorder.tickCount} ticks) to ${opts.replayPath}`);
      recorder.close();
    }
    exit(0);
  }

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  gameLoop();
}

function validTournamentRequest(req: IncomingMessage, slots: SlotState[]): boolean {
  const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
  const slotIndex = parseIntegerParam(url.searchParams.get("slot"));
  const token = url.searchParams.get("token");
  return slotIndex !== null && slotIndex >= 0 && slotIndex < slots.length && token === slots[slotIndex].token;
}

function attachFreeplayPlayer(
  ws: WebSocket,
  req: IncomingMessage,
  clients: Map<WebSocket, ClientState>,
  sim: Sim,
  recorder: ReplayRecorder | null,
) {
  const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
  const name = sanitizeName(url.searchParams.get("name") ?? "unknown");
  const client: ClientState = { ws, playerIndex: PENDING, inputMask: 0, prevInputMask: 0, name };
  clients.set(ws, client);

  ws.on("message", (data: Buffer) => handlePlayerMessage(data, client, sim));
  ws.on("close", () => {
    const c = clients.get(ws);
    if (c && c.playerIndex !== PENDING && c.playerIndex < sim.players.length) {
      recorder?.writeLeave(c.playerIndex);
      sim.removePlayer(c.playerIndex);
      for (const [, other] of clients) {
        if (other !== c && other.playerIndex > c.playerIndex && other.playerIndex !== PENDING) other.playerIndex--;
      }
    }
    clients.delete(ws);
  });
  ws.on("error", () => ws.close());
}

function attachTournamentPlayer(
  ws: WebSocket,
  req: IncomingMessage,
  slots: SlotState[],
  sim: Sim,
  recorder: ReplayRecorder | null,
) {
  const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
  const slotIndex = parseIntegerParam(url.searchParams.get("slot"));
  const token = url.searchParams.get("token");
  if (slotIndex === null || slotIndex < 0 || slotIndex >= slots.length || token !== slots[slotIndex].token) {
    ws.close(1008, "invalid slot or token");
    return;
  }

  const slot = slots[slotIndex];
  if (slot.ws && slot.ws.readyState === WebSocket.OPEN) slot.ws.close(1012, "slot reconnected");
  slot.ws = ws;
  slot.name = sanitizeName(url.searchParams.get("name") ?? url.searchParams.get("player") ?? `slot_${slotIndex}`);
  ws.on("message", (data: Buffer) => handlePlayerMessage(data, slot, sim));
  ws.on("close", () => {
    if (slot.ws === ws) {
      slot.ws = null;
      slot.inputMask = 0;
      if (slot.playerIndex !== PENDING) recorder?.writeLeave(slot.playerIndex);
    }
  });
  ws.on("error", () => ws.close());
}

function handlePlayerMessage(data: Buffer, client: ClientState | SlotState, sim: Sim) {
  if (isInputPacket(data)) {
    const mask = blobToMask(data);
    if (mask === 255) {
      client.inputMask = 0;
      client.prevInputMask = 0;
    } else {
      client.inputMask = mask;
    }
  } else if (isChatPacket(data) && client.playerIndex !== PENDING) {
    const text = blobToChat(data);
    if (text.length > 0) {
      const p = sim.players[client.playerIndex];
      if (p && p.inWhisper >= 0) sim.addWhisperChat(p.inWhisper, client.playerIndex, text);
      else sim.addShout(client.playerIndex, text);
    }
  }
}

function runReplayServer(opts: RuntimeOptions) {
  if (!opts.loadReplayPath) throw new Error("Replay mode requires COGAME_LOAD_REPLAY_PATH");
  killExistingPortListener(opts.port);
  const replayData = loadReplay(opts.loadReplayPath);
  const httpServer = createServer((req, res) => handleHttp(req, res, opts));
  const replayWss = new WebSocketServer({ noServer: true, perMessageDeflate: false });

  httpServer.on("upgrade", (req, socket, head) => {
    const { pathname } = new URL(req.url ?? "/", `http://${req.headers.host}`);
    if (pathname === "/replay") replayWss.handleUpgrade(req, socket, head, (ws) => replayWss.emit("connection", ws, req));
    else socket.destroy();
  });

  replayWss.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "replay", ...replayData, hashes: replayData.hashes.map(h => ({ tick: h.tick, hash: h.hash.toString() })) }));
    ws.on("message", (data) => ws.send(JSON.stringify({ type: "control", command: data.toString() })));
  });

  httpServer.listen(opts.port, opts.host, () => {
    console.log(`${GAME_NAME} replay listening on ${opts.host}:${opts.port}`);
  });
}

function handleHttp(req: IncomingMessage, res: ServerResponse, opts: RuntimeOptions) {
  const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
  if (url.pathname === "/healthz") {
    sendJson(res, 200, { ok: true, mode: opts.mode });
  } else if (url.pathname === "/player") {
    sendHtml(res, "player.html");
  } else if (url.pathname === "/global" || url.pathname === "/global_client.html") {
    sendHtml(res, "global_client.html");
  } else if (url.pathname === "/replay") {
    sendHtml(res, "replay.html");
  } else if (url.pathname === "/snappyjs.min.js") {
    sendScript(res, "snappyjs.min.js");
  } else {
    sendText(res, 200, `${GAME_NAME} ${opts.mode} server`);
  }
}

function finalizeTournament(opts: RuntimeOptions, sim: Sim, recorder: ReplayRecorder | null) {
  recorder?.close();
  if (opts.resultsPath) {
    writeFileSync(opts.resultsPath, JSON.stringify(buildResults(sim), null, 2));
  }
  if (opts.saveReplayPath && !existsSync(opts.saveReplayPath)) {
    writeFileSync(opts.saveReplayPath, JSON.stringify({ seed: opts.seed, config: opts.config, results: buildResults(sim) }, null, 2));
  }
}

function buildResults(sim: Sim): Record<string, unknown> {
  const scores = sim.players.map((p) => {
    if (sim.winner === null) return 0;
    return p.team === sim.winner ? 1 : 0;
  });
  return {
    scores,
    winner: sim.winner === Team.TeamA ? "Shades" : sim.winner === Team.TeamB ? "Nymphs" : "Draw",
    players: sim.players.map((p, slot) => ({
      slot,
      name: p.name,
      team: p.team === Team.TeamA ? "Shades" : "Nymphs",
      score: scores[slot],
    })),
    ticks: sim.tickCount,
  };
}

function writeGameLogs(sim: Sim) {
  const dir = `logs/${Date.now()}`;
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/full.log`, sim.generateFullLog());
  for (let i = 0; i < sim.players.length; i++) {
    const name = playerSpriteName(i).replace(/ /g, "_").toLowerCase();
    writeFileSync(`${dir}/${name}.log`, sim.generatePlayerLog(i));
  }
  console.log(`Game logs written to ${dir}/`);
}

function readJsonObject(path: string): Record<string, unknown> {
  const parsed = JSON.parse(readFileSync(path, "utf-8")) as unknown;
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`Expected JSON object in ${path}`);
  }
  return parsed as Record<string, unknown>;
}

function readTokens(raw: Record<string, unknown>, path: string): string[] {
  if (!Array.isArray(raw.tokens) || raw.tokens.some(t => typeof t !== "string" || t.length === 0)) {
    throw new Error(`Tournament config "${path}" must include non-empty string array "tokens"`);
  }
  return raw.tokens as string[];
}

function readOptionalInteger(raw: unknown, fallback: number, label: string): number {
  if (raw === undefined) return fallback;
  if (typeof raw !== "number" || !Number.isInteger(raw)) throw new Error(`${label} must be an integer`);
  return raw;
}

function parseIntegerParam(raw: string | null): number | null {
  if (raw === null || raw === "") return null;
  const value = Number(raw);
  return Number.isInteger(value) ? value : null;
}

function parseMode(raw: string): ServerMode {
  if (raw === "freeplay" || raw === "tournament" || raw === "replay") return raw;
  throw new Error(`Unknown mode "${raw}"`);
}

function listeningPids(port: number): number[] {
  if (!Number.isInteger(port) || port <= 0) return [];
  try {
    const out = execFileSync("lsof", ["-ti", `tcp:${port}`, "-sTCP:LISTEN"], { encoding: "utf-8" }).trim();
    if (!out) return [];
    return out
      .split(/\s+/)
      .map(pid => Number(pid))
      .filter(pid => Number.isInteger(pid) && pid > 0 && pid !== process.pid);
  } catch {
    return [];
  }
}

function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function killExistingPortListener(port: number): void {
  const pids = listeningPids(port);
  if (pids.length === 0) return;

  console.log(`Port ${port} already has listener(s): ${pids.join(", ")}. Terminating before startup.`);
  for (const pid of pids) {
    try { process.kill(pid, "SIGTERM"); } catch { /* process may already be gone */ }
  }

  for (let i = 0; i < 20; i++) {
    if (listeningPids(port).length === 0) return;
    sleepSync(50);
  }

  const remaining = listeningPids(port);
  if (remaining.length === 0) return;
  console.log(`Port ${port} still occupied by ${remaining.join(", ")}. Forcing termination.`);
  for (const pid of remaining) {
    try { process.kill(pid, "SIGKILL"); } catch { /* process may already be gone */ }
  }
}

function sanitizeName(name: string): string {
  return name.replace(/\s+/g, "_").trim() || "unknown";
}

function sendHtml(res: ServerResponse, file: string) {
  const path = join(__dirname, "clients", file);
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(readFileSync(path, "utf-8"));
}

function sendScript(res: ServerResponse, file: string) {
  const path = join(__dirname, "clients", file);
  res.writeHead(200, { "Content-Type": "application/javascript; charset=utf-8" });
  res.end(readFileSync(path, "utf-8"));
}

function sendJson(res: ServerResponse, status: number, value: object) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(value));
}

function sendText(res: ServerResponse, status: number, value: string) {
  res.writeHead(status, { "Content-Type": "text/plain; charset=utf-8" });
  res.end(value);
}

main();

/**
 * Automated match tester — runs LLM bots vs smart bots and reports win rates.
 *
 * Usage:
 *   tsx test_harness.ts [--matches N] [--config fast|medium] [--llm-bots N]
 *                       [--smart-bots N] [--port PORT] [--replay-dir DIR]
 */

import { WebSocketServer, WebSocket } from "ws";
import { createServer, type Server as HttpServer } from "http";
import { spawn, type ChildProcess } from "child_process";
import { argv } from "process";
import { mkdirSync } from "fs";
import { Phase, Team, Role, type InputState, type GameConfig } from "../types.js";
import { DEFAULT_GAME_CONFIG, TARGET_FPS, LOBBY_WAIT_TICKS, playerCountFromConfig } from "../constants.js";
import { decodeInputMask, emptyInput, isInputPacket, isChatPacket, blobToMask, blobToChat } from "../protocol.js";
import { Sim } from "../sim.js";
import { render } from "../rendering/renderer.js";
import { ReplayRecorder } from "../replay.js";
import { buildGlobalFrame } from "../rendering/globalViewer.js";

// ---------------------------------------------------------------------------
// Config presets
// ---------------------------------------------------------------------------

const CONFIGS: Record<string, GameConfig> = {
  tiny: {
    ...DEFAULT_GAME_CONFIG,
    rounds: [{ durationSecs: 1, hostages: 1 }],
  },
  short: {
    ...DEFAULT_GAME_CONFIG,
    rounds: [{ durationSecs: 30, hostages: 1 }],
  },
  empty: {
    ...DEFAULT_GAME_CONFIG,
    rounds: [{ durationSecs: 30, hostages: 1 }],
    obstacleCount: 0,
  },
  simple: {
    // Simple test: 6 players (all 4 key roles + 1 Shades + 1 Nymphs grunt),
    // LLMs all in RoomA together, no obstacles, 60s round.
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
    groupNamePrefixInRoomA: "llm_",
  },
  empty3: {
    ...DEFAULT_GAME_CONFIG,
    rounds: [
      { durationSecs: 45, hostages: 2 },
      { durationSecs: 45, hostages: 2 },
      { durationSecs: 45, hostages: 2 },
    ],
    obstacleCount: 0,
  },
  fast: DEFAULT_GAME_CONFIG,
  medium: {
    ...DEFAULT_GAME_CONFIG,
    rounds: [
      { durationSecs: 180, hostages: 1 },
      { durationSecs: 120, hostages: 1 },
      { durationSecs: 60, hostages: 1 },
    ],
  },
};

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------

function parseCliArgs() {
  const args: Record<string, string> = {};
  for (let i = 2; i < argv.length; i++) {
    if (argv[i].startsWith("--") && i + 1 < argv.length) {
      args[argv[i].slice(2)] = argv[i + 1];
      i++;
    }
  }
  return {
    matches: parseInt(args["matches"] ?? "5"),
    configName: args["config"] ?? "fast",
    llmBots: parseInt(args["llm-bots"] ?? "1"),
    smartBots: parseInt(args["smart-bots"] ?? "5"),
    port: parseInt(args["port"] ?? "9090"),
    replayDir: args["replay-dir"] ?? null,
    model: args["model"] ?? undefined,
    botScript: args["bot-script"] ?? "../bots/llm_bot.ts",
    botPrefix: args["bot-prefix"] ?? "llm_",
  };
}

// ---------------------------------------------------------------------------
// Match result
// ---------------------------------------------------------------------------

interface MatchResult {
  matchIndex: number;
  seed: number;
  winner: "TeamA" | "TeamB" | "none";
  llmTeam: "TeamA" | "TeamB";
  llmRole: string;
  llmWon: boolean;
  durationTicks: number;
}

// ---------------------------------------------------------------------------
// Embedded server — runs one match
// ---------------------------------------------------------------------------

interface ClientState {
  ws: WebSocket;
  playerIndex: number;
  inputMask: number;
  prevInputMask: number;
  name: string;
}

const PENDING = 0x7fffffff;

function runMatch(
  seed: number,
  config: GameConfig,
  port: number,
  smartBotCount: number,
  llmBotCount: number,
  replayPath: string | null,
  llmModel: string | undefined,
): Promise<{ winner: Team | null; llmTeam: Team | null; llmRole: Role | null; ticks: number }> {
  return new Promise((resolve, reject) => {
    const sim = new Sim(config, seed);
    const clients = new Map<WebSocket, ClientState>();
    const recorder = replayPath ? new ReplayRecorder(seed, replayPath, JSON.stringify({ seed, config })) : null;

    const httpServer = createServer();
    const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });
    const globalWss = new WebSocketServer({ noServer: true, perMessageDeflate: false });
    const globalViewers = new Set<WebSocket>();

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

    // Spawn bot processes
    const children: ChildProcess[] = [];
    const url = `ws://localhost:${port}/player`;

    httpServer.listen(port, "localhost", () => {
      const smartProc = spawn("npx", ["tsx", "../bots/smart_bots.ts", String(smartBotCount), url], {
        stdio: ["ignore", "pipe", "pipe"],
        cwd: import.meta.dirname,
      });
      children.push(smartProc);

      for (let i = 0; i < llmBotCount; i++) {
        const llmArgs = ["tsx", "../bots/llm_bot.ts", "--name", `llm_${i + 1}`, "--url", url];
        if (llmModel) llmArgs.push("--model", llmModel);
        const llmProc = spawn("npx", llmArgs, {
          stdio: ["ignore", "pipe", "pipe"],
          cwd: import.meta.dirname,
        });
        llmProc.stdout?.on("data", (d: Buffer) => {
          const msg = d.toString().trim();
          if (msg) process.stdout.write(`  [llm_${i + 1}] ${msg}\n`);
        });
        llmProc.stderr?.on("data", (d: Buffer) => {
          const msg = d.toString().trim();
          if (msg && !msg.includes("ExperimentalWarning")) process.stderr.write(`  [llm_${i + 1}] ${msg}\n`);
        });
        children.push(llmProc);
      }
    });

    // Game loop
    let resultCaptured = false;
    let llmPlayerIndex = -1;
    let llmTeamCapture: Team | null = null;
    let llmRoleCapture: Role | null = null;
    const frameDuration = 1000 / TARGET_FPS;
    let lastTick = performance.now();

    function gameLoop() {
      const now = performance.now();
      if (now - lastTick < frameDuration) {
        setTimeout(gameLoop, Math.max(1, frameDuration - (now - lastTick)));
        return;
      }
      lastTick = now;

      for (const [, client] of clients) {
        if (client.playerIndex === PENDING) {
          client.playerIndex = sim.addPlayer(client.name);
          recorder?.writeJoin(client.playerIndex, client.name);
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

      try { sim.step(inputs, prevInputs); } catch (e) { console.error("  step error:", e); }
      recorder?.recordTick(inputMasks);

      // Capture LLM bot info once roles are assigned
      if (llmPlayerIndex === -1 && sim.phase === Phase.Playing) {
        for (const [, c] of clients) {
          if (c.name.startsWith("llm_") && c.playerIndex !== PENDING && c.playerIndex < sim.players.length) {
            llmPlayerIndex = c.playerIndex;
            llmTeamCapture = sim.players[c.playerIndex].team;
            llmRoleCapture = sim.players[c.playerIndex].role;
            break;
          }
        }
      }

      // Detect game end
      if (sim.phase === Phase.Reveal && !resultCaptured) {
        resultCaptured = true;
        const winner = sim.winner;
        const ticks = sim.tickCount;

        setTimeout(() => {
          recorder?.close();
          for (const child of children) { child.kill("SIGTERM"); }
          for (const [ws] of clients) { ws.close(); }
          wss.close();
          httpServer.close(() => {
            resolve({ winner, llmTeam: llmTeamCapture, llmRole: llmRoleCapture, ticks });
          });
        }, 500);
      }

      // Send frames
      for (const [ws, client] of clients) {
        if (client.playerIndex >= 0 && client.playerIndex < sim.players.length) {
          try { ws.send(render(sim, client.playerIndex)); } catch { /* */ }
        }
        client.prevInputMask = client.inputMask;
      }
      if (globalViewers.size > 0) {
        const frame = buildGlobalFrame(sim);
        for (const ws of globalViewers) {
          try { ws.send(frame); } catch { /* */ }
        }
      }

      if (!resultCaptured) {
        setTimeout(gameLoop, Math.max(1, frameDuration - (performance.now() - lastTick)));
      }
    }

    setTimeout(gameLoop, 100);

    // Safety timeout — if game doesn't end in reasonable time
    const totalRoundSecs = config.rounds.reduce((s, r) => s + r.durationSecs, 0);
    const maxWaitMs = (totalRoundSecs + 60) * 1000;
    setTimeout(() => {
      if (!resultCaptured) {
        resultCaptured = true;
        console.error("  Match timed out!");
        recorder?.close();
        for (const child of children) child.kill("SIGKILL");
        for (const [ws] of clients) ws.close();
        wss.close();
        httpServer.close(() => {
          resolve({ winner: null, llmTeam: llmTeamCapture, llmRole: llmRoleCapture, ticks: sim.tickCount });
        });
      }
    }, maxWaitMs);
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const opts = parseCliArgs();
  const config = CONFIGS[opts.configName];
  if (!config) {
    console.error(`Unknown config: ${opts.configName}. Available: ${Object.keys(CONFIGS).join(", ")}`);
    process.exit(1);
  }

  if (opts.replayDir) mkdirSync(opts.replayDir, { recursive: true });

  const totalPlayers = opts.smartBots + opts.llmBots;
  const expectedPlayers = playerCountFromConfig(config);
  if (totalPlayers < expectedPlayers) {
    console.error(`Need at least ${expectedPlayers} players, got ${totalPlayers}`);
    process.exit(1);
  }

  const totalRoundSecs = config.rounds.reduce((s, r) => s + r.durationSecs, 0);
  console.log(`Running ${opts.matches} matches | config=${opts.configName} (${config.rounds.map(r => r.durationSecs + "s").join("/")}) | ${opts.llmBots} LLM + ${opts.smartBots} smart bots`);
  console.log(`Estimated time per match: ~${totalRoundSecs + 30}s\n`);

  const results: MatchResult[] = [];

  for (let i = 0; i < opts.matches; i++) {
    const seed = 0xb1770 + i * 7919;
    const replayPath = opts.replayDir ? `${opts.replayDir}/match_${i}_seed_${seed}.bin` : null;

    console.log(`Match ${i + 1}/${opts.matches} (seed=${seed})...`);

    const { winner, llmTeam: lt, llmRole: lr, ticks } = await runMatch(
      seed, config, opts.port + i, opts.smartBots, opts.llmBots, replayPath, opts.model,
    );

    const llmTeam = lt === Team.TeamA ? "TeamA" as const : lt === Team.TeamB ? "TeamB" as const : "TeamA" as const;
    const llmRole = lr !== null ? Role[lr] : "unknown";
    const winStr = winner === Team.TeamA ? "TeamA" : winner === Team.TeamB ? "TeamB" : "none";
    const llmWon = (winner === Team.TeamA && llmTeam === "TeamA") ||
                   (winner === Team.TeamB && llmTeam === "TeamB");

    results.push({
      matchIndex: i,
      seed,
      winner: winStr,
      llmTeam,
      llmRole,
      llmWon,
      durationTicks: ticks,
    });

    console.log(`  Winner: ${winStr} | LLM: ${llmRole} on ${llmTeam} | LLM won: ${llmWon} | ${ticks} ticks`);

    // Small delay between matches for port cleanup
    await new Promise(r => setTimeout(r, 1000));
  }

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log(`RESULTS: ${opts.matches} matches (config=${opts.configName})`);
  console.log("=".repeat(60));

  const teamAWins = results.filter(r => r.winner === "TeamA").length;
  const teamBWins = results.filter(r => r.winner === "TeamB").length;
  const noWinner = results.filter(r => r.winner === "none").length;
  const llmWins = results.filter(r => r.llmWon).length;

  console.log(`TeamA (Shades) wins: ${teamAWins}/${opts.matches} (${pct(teamAWins, opts.matches)})`);
  console.log(`TeamB (Nymphs) wins: ${teamBWins}/${opts.matches} (${pct(teamBWins, opts.matches)})`);
  console.log(`No winner:           ${noWinner}/${opts.matches} (${pct(noWinner, opts.matches)})`);
  console.log();

  console.log(`LLM bot's team won: ${llmWins}/${opts.matches} (${pct(llmWins, opts.matches)})`);

  const keyRoles = results.filter(r => ["Hades", "Persephone", "Cerberus", "Demeter"].includes(r.llmRole));
  const keyRoleWins = keyRoles.filter(r => r.llmWon).length;
  console.log(`LLM had key role: ${keyRoles.length}/${opts.matches}`);
  if (keyRoles.length > 0) {
    console.log(`LLM key role wins: ${keyRoleWins}/${keyRoles.length} (${pct(keyRoleWins, keyRoles.length)})`);
  }

  console.log("\nPer-match breakdown:");
  for (const r of results) {
    console.log(`  #${r.matchIndex + 1} seed=${r.seed} winner=${r.winner} llm=${r.llmRole}/${r.llmTeam} won=${r.llmWon}`);
  }
}

function pct(n: number, total: number): string {
  if (total === 0) return "0%";
  return (n / total * 100).toFixed(0) + "%";
}

main().catch(e => { console.error(e); process.exit(1); });

/**
 * Automated match tester — runs all-LLM-bot matches and reports win rates.
 *
 * Usage:
 *   tsx test_harness.ts [CONFIG_NAME] [--matches N] [--config NAME]
 *                       [--port PORT] [--replay-dir DIR] [--model MODEL]
 *
 * Player count is derived from the config preset (sum of role counts).
 * All players are LLM bots.
 *
 * Available config presets (defined in game/config_presets.ts):
 *   default, fast, tiny, short, empty, simple, empty3, medium, medium6, medium12, medium12_half
 *
 * Default config is medium12_half: dense enough to exercise real policy behavior
 * without the long wall-clock time of a full medium12 match.
 */

import { WebSocketServer, WebSocket } from "ws";
import { createServer, type Server as HttpServer } from "http";
import { spawn, type ChildProcess } from "child_process";
import { argv } from "process";
import { mkdirSync, readFileSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import { Phase, Team, Role, type InputState, type GameConfig } from "../game/types.js";
import { DEFAULT_GAME_CONFIG, TARGET_FPS, LOBBY_WAIT_TICKS, playerCountFromConfig } from "../game/constants.js";
import { decodeInputMask, emptyInput, isInputPacket, isChatPacket, blobToMask, blobToChat } from "../game/protocol.js";
import { Sim } from "../game/sim.js";
import { render } from "../rendering/renderer.js";
import { ReplayRecorder } from "../replay.js";
import { buildGlobalFrame } from "../rendering/globalViewer.js";
import { CONFIGS } from "../game/config_presets.js";

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------

function parseCliArgs() {
  const args: Record<string, string> = {};
  let positionalConfig: string | null = null;
  for (let i = 2; i < argv.length; i++) {
    if (argv[i].startsWith("--") && i + 1 < argv.length) {
      args[argv[i].slice(2)] = argv[i + 1];
      i++;
    } else if (!argv[i].startsWith("--") && !positionalConfig) {
      positionalConfig = argv[i];
    }
  }
  return {
    matches: parseInt(args["matches"] ?? "1"),
    configName: args["config"] ?? positionalConfig ?? "medium12_half",
    port: parseInt(args["port"] ?? "9090"),
    replayDir: args["replay-dir"] ?? null,
    model: args["model"] ?? undefined,
    botScript: args["bot-script"] ?? "../bots/llm_bot_v2.ts",
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
  botCount: number,
  replayPath: string | null,
  llmModel: string | undefined,
  botScript: string,
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
            if (p && p.inWhisper >= 0) {
              sim.addWhisperChat(p.inWhisper, client.playerIndex, text);
            } else {
              sim.addShout(client.playerIndex, text);
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

    httpServer.listen(port, "0.0.0.0", () => {
      for (let i = 0; i < botCount; i++) {
        const llmArgs = ["tsx", botScript, "--name", `llm_${i + 1}`, "--url", url];
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
        }, 10000);
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
    // Account for lobby wait, role reveal, hostage-select (15s per round), exchange animations (3s),
    // reveal/gameover phases, and LLM-induced slowdown (sim may run slower than real time).
    const overhead = 60 + config.rounds.length * 25 + 30;
    const maxWaitMs = Math.ceil((totalRoundSecs + overhead) * 1.5) * 1000;
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

  const botCount = playerCountFromConfig(config);
  const totalRoundSecs = config.rounds.reduce((s, r) => s + r.durationSecs, 0);
  console.log(`Running ${opts.matches} matches | config=${opts.configName} (${config.rounds.map(r => r.durationSecs + "s").join("/")}) | ${botCount} LLM bots`);
  console.log(`Estimated time per match: ~${totalRoundSecs + 30}s\n`);

  const results: MatchResult[] = [];

  for (let i = 0; i < opts.matches; i++) {
    const seed = 0xb1770 + i * 7919;
    const replayPath = opts.replayDir ? `${opts.replayDir}/match_${i}_seed_${seed}.bin` : null;

    console.log(`Match ${i + 1}/${opts.matches} (seed=${seed})...`);

    const { winner, llmTeam: lt, llmRole: lr, ticks } = await runMatch(
      seed, config, opts.port + i, botCount, replayPath, opts.model, opts.botScript,
    );

    const winStr = winner === Team.TeamA ? "TeamA" : winner === Team.TeamB ? "TeamB" : "none";

    results.push({
      matchIndex: i,
      seed,
      winner: winStr,
      llmTeam: lt === Team.TeamA ? "TeamA" : lt === Team.TeamB ? "TeamB" : "TeamA",
      llmRole: lr !== null ? Role[lr] : "unknown",
      llmWon: (winner === Team.TeamA && lt === Team.TeamA) || (winner === Team.TeamB && lt === Team.TeamB),
      durationTicks: ticks,
    });

    console.log(`  Winner: ${winStr} | ${ticks} ticks`);

    // Small delay between matches for port cleanup
    await new Promise(r => setTimeout(r, 1000));
  }

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log(`RESULTS: ${opts.matches} matches (config=${opts.configName}, ${botCount} bots)`);
  console.log("=".repeat(60));

  const teamAWins = results.filter(r => r.winner === "TeamA").length;
  const teamBWins = results.filter(r => r.winner === "TeamB").length;
  const noWinner = results.filter(r => r.winner === "none").length;

  console.log(`TeamA (Shades) wins: ${teamAWins}/${opts.matches} (${pct(teamAWins, opts.matches)})`);
  console.log(`TeamB (Nymphs) wins: ${teamBWins}/${opts.matches} (${pct(teamBWins, opts.matches)})`);
  console.log(`No winner:           ${noWinner}/${opts.matches} (${pct(noWinner, opts.matches)})`);

  console.log("\nPer-match breakdown:");
  for (const r of results) {
    console.log(`  #${r.matchIndex + 1} seed=${r.seed} winner=${r.winner}`);
  }
}

function pct(n: number, total: number): string {
  if (total === 0) return "0%";
  return (n / total * 100).toFixed(0) + "%";
}

main().catch(e => { console.error(e); process.exit(1); });

import assert from "node:assert/strict";
import { Sim } from "../game/sim.js";
import {
  PROTOCOL_BYTES,
  SCREEN_HEIGHT,
  SCREEN_WIDTH,
  characterName,
} from "../game/constants.js";
import { PACKED_FRAME_BYTES } from "../bots/bot_utils.js";
import { Role, Team, type GameConfig } from "../game/types.js";
import { render } from "../rendering/renderer.js";
import { parseWhisperStatus } from "../bots/frame_parser.js";

function configForPlayers(count: number): GameConfig {
  return {
    roles: [{ role: Role.Shades, team: Team.TeamA, count }],
    rounds: [{ durationSecs: 60, hostages: 0 }],
    obstacleCount: 0,
  };
}

function unpackFrame(packed: Buffer): Uint8Array {
  assert.equal(packed.length, PACKED_FRAME_BYTES);
  const frame = new Uint8Array(SCREEN_WIDTH * SCREEN_HEIGHT);
  for (let i = 0; i < PROTOCOL_BYTES; i++) {
    frame[i * 2] = packed[i] & 0x0f;
    frame[i * 2 + 1] = (packed[i] >> 4) & 0x0f;
  }
  return frame;
}

function testWhisperOccupantsUseSharedHeaderRegion() {
  const sim = new Sim(configForPlayers(3), 123);
  for (let i = 0; i < 3; i++) sim.addPlayer(`p${i}`);
  sim.startGame();
  sim.startRound();

  sim.createWhisper(0);
  const whisperId = sim.players[0].inWhisper;
  const whisper = sim.whispers.get(whisperId);
  assert.ok(whisper);

  whisper.occupants.add(1);
  sim.players[1].inWhisper = whisperId;
  sim.players[1].whisperEntryTick = sim.tickCount;

  const status = parseWhisperStatus(unpackFrame(render(sim, 0)));
  assert.equal(status.occupantCount, 2);
  assert.deepEqual(status.occupants.map(o => o.shape), [sim.players[0].shape, sim.players[1].shape]);
  assert.deepEqual(status.occupantColors, [sim.playerColor(0), sim.playerColor(1)]);
}

function testWhisperPendingEntryUsesSharedFooterRegion() {
  const sim = new Sim(configForPlayers(3), 456);
  for (let i = 0; i < 3; i++) sim.addPlayer(`p${i}`);
  sim.startGame();
  sim.startRound();

  sim.createWhisper(0);
  const whisper = sim.whispers.get(sim.players[0].inWhisper);
  assert.ok(whisper);
  whisper.pendingEntry.push(1);

  const status = parseWhisperStatus(unpackFrame(render(sim, 0)));
  assert.equal(status.pendingEntry, true);
  assert.equal(status.pendingEntryName, characterName(sim.playerColor(1), sim.players[1].shape));
}

testWhisperOccupantsUseSharedHeaderRegion();
testWhisperPendingEntryUsesSharedFooterRegion();

console.log("whisper region tests passed");

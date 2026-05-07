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
import { FRAME_REGIONS } from "../rendering/frameRegions.js";
import { parseWhisperMessages, parseWhisperStatus } from "../bots/frame_parser.js";

function configForPlayers(count: number): GameConfig {
  return {
    roles: [{ role: Role.Shades, team: Team.TeamA, count }],
    rounds: [{ durationSecs: 60, psychopomps: 0 }],
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

function testWhisperOfferIndicatorPersistsWithMenuOpen() {
  const sim = new Sim(configForPlayers(2), 457);
  for (let i = 0; i < 2; i++) sim.addPlayer(`p${i}`);
  sim.startGame();
  sim.startRound();

  sim.createWhisper(0);
  const whisper = sim.whispers.get(sim.players[0].inWhisper);
  assert.ok(whisper);
  whisper.occupants.add(1);
  sim.players[1].inWhisper = sim.players[0].inWhisper;
  whisper.colorOffers.add(1);
  sim.players[0].whisperMenuOpen = true;

  const status = parseWhisperStatus(unpackFrame(render(sim, 0)));
  assert.equal(status.pendingColorOffer, true, "color offer indicator should remain parseable while the whisper menu is open");
}

function testWhisperOccupantsCanUseSparsePersistentSlots() {
  const sim = new Sim(configForPlayers(2), 458);
  for (let i = 0; i < 2; i++) sim.addPlayer(`p${i}`);
  sim.startGame();
  sim.startRound();

  sim.createWhisper(0);
  const whisper = sim.whispers.get(sim.players[0].inWhisper);
  assert.ok(whisper);
  whisper.occupants.add(1);
  sim.players[1].inWhisper = sim.players[0].inWhisper;
  whisper.colorOffers.add(1);

  const frame = unpackFrame(render(sim, 0));
  const firstSlot = FRAME_REGIONS.whisper.occupantSlot(0);
  for (let y = firstSlot.y; y < firstSlot.y + firstSlot.h; y++) {
    for (let x = firstSlot.x; x < firstSlot.x + firstSlot.w; x++) {
      frame[y * SCREEN_WIDTH + x] = 0;
    }
  }

  const status = parseWhisperStatus(frame);
  assert.equal(status.pendingColorOffer, true);
  assert.equal(status.occupantCount, 1);
  assert.deepEqual(status.occupants.map(o => o.shape), [sim.players[1].shape]);
  assert.deepEqual(status.occupantColors, [sim.playerColor(1)]);
}

function testWhisperSystemMessageDoesNotLookLikePendingEntry() {
  const sim = new Sim(configForPlayers(4), 789);
  for (let i = 0; i < 4; i++) sim.addPlayer(`p${i}`);
  sim.startGame();
  sim.startRound();

  sim.createWhisper(0);
  const whisper = sim.whispers.get(sim.players[0].inWhisper);
  assert.ok(whisper);
  assert.equal(whisper.pendingEntry.length, 0);

  // Player 2 has palette color 8 in the default roster. A rich-text system
  // message at the bottom of the whisper log used to be enough to trip the
  // pending-entry parser, even with no actual pending entry in the engine.
  whisper.messages.push({ type: "system", senderIndex: -1, tick: sim.tickCount, text: `\x01${String.fromCharCode(2)} offered color` });

  const status = parseWhisperStatus(unpackFrame(render(sim, 0)));
  assert.equal(status.pendingEntry, false);
  assert.equal(status.pendingEntryName, null);
}

function testExchangeSystemMessagesAreGroupFacts() {
  const sim = new Sim(configForPlayers(3), 790);
  for (let i = 0; i < 3; i++) sim.addPlayer(`p${i}`);
  sim.startGame();
  sim.startRound();

  sim.createWhisper(0);
  const whisper = sim.whispers.get(sim.players[0].inWhisper);
  assert.ok(whisper);
  whisper.occupants.add(1);
  sim.players[1].inWhisper = sim.players[0].inWhisper;
  whisper.messages.push({
    type: "system",
    senderIndex: -1,
    tick: sim.tickCount,
    text: `COLOR XCHG: \x01${String.fromCharCode(0)}, \x01${String.fromCharCode(1)}`,
  });

  const messages = parseWhisperMessages(unpackFrame(render(sim, 0)));
  assert.equal(
    messages.some(m => m.type === "system" && m.text.includes("COLOR XCHG")),
    true,
    "group exchange system message should parse as system text",
  );
}

testWhisperOccupantsUseSharedHeaderRegion();
testWhisperPendingEntryUsesSharedFooterRegion();
testWhisperOfferIndicatorPersistsWithMenuOpen();
testWhisperOccupantsCanUseSparsePersistentSlots();
testWhisperSystemMessageDoesNotLookLikePendingEntry();
testExchangeSystemMessagesAreGroupFacts();

console.log("whisper region tests passed");

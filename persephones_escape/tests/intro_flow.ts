import assert from "node:assert/strict";
import { Sim } from "../game/sim.js";
import {
  BUTTON_A, BUTTON_B, BUTTON_LEFT, BUTTON_RIGHT,
  TARGET_FPS, playerCountFromConfig,
} from "../game/constants.js";
import { decodeInputMask, emptyInput } from "../game/protocol.js";
import { Phase, Role, Team, type GameConfig, type InputState } from "../game/types.js";

function configForPlayers(count: number): GameConfig {
  return {
    roles: [{ role: Role.Shades, team: Team.TeamA, count }],
    rounds: [{ durationSecs: 10, psychopomps: 0 }],
    obstacleCount: 0,
  };
}

function makeSim(count = 3): Sim {
  const config = configForPlayers(count);
  assert.equal(playerCountFromConfig(config), count);
  const sim = new Sim(config, 123);
  for (let i = 0; i < count; i++) {
    assert.equal(sim.addPlayer(`p${i}`), i);
  }
  return sim;
}

function blankInputs(sim: Sim): InputState[] {
  return sim.players.map(() => emptyInput());
}

function step(sim: Sim, masks: number[], prev: InputState[]): InputState[] {
  const inputs = sim.players.map((_, i) => decodeInputMask(masks[i] ?? 0));
  sim.step(inputs, prev);
  return inputs;
}

function release(sim: Sim, prev: InputState[]): InputState[] {
  return step(sim, [], prev);
}

function advanceToIntro(sim: Sim): InputState[] {
  let prev = blankInputs(sim);
  for (let t = 0; t < TARGET_FPS - 1; t++) {
    prev = step(sim, [], prev);
    assert.equal(sim.phase, Phase.Lobby);
  }
  prev = step(sim, [], prev);
  assert.equal(sim.phase, Phase.RosterReveal);
  assert.equal(sim.introPanel, 0);
  assert.equal(sim.revealTimer, 15 * TARGET_FPS);
  return prev;
}

function tap(sim: Sim, masks: number[], prev: InputState[]): InputState[] {
  prev = step(sim, masks, prev);
  return release(sim, prev);
}

function testLobbyStartsOneSecondAfterExpectedPlayersJoin() {
  const config = configForPlayers(3);
  const sim = new Sim(config, 123);
  sim.addPlayer("p0");
  sim.addPlayer("p1");

  let prev = blankInputs(sim);
  for (let t = 0; t < TARGET_FPS * 2; t++) {
    prev = step(sim, [], prev);
    assert.equal(sim.phase, Phase.Lobby);
    assert.equal(sim.lobbyCountdown, 0);
  }

  sim.addPlayer("p2");
  for (let t = 0; t < TARGET_FPS - 1; t++) {
    prev = step(sim, [], prev);
    assert.equal(sim.phase, Phase.Lobby);
  }

  prev = step(sim, [], prev);
  assert.equal(sim.phase, Phase.RosterReveal);
  assert.equal(sim.revealTimer, 15 * TARGET_FPS);
}

function testIntroTimesOutAfterFifteenSecondsTotal() {
  const sim = makeSim();
  let prev = advanceToIntro(sim);

  for (let t = 0; t < 15 * TARGET_FPS - 1; t++) {
    prev = step(sim, [], prev);
    assert.equal(sim.phase, Phase.RosterReveal);
  }

  prev = step(sim, [], prev);
  assert.equal(sim.phase, Phase.Playing);
}

function testIntroNavigationButtons() {
  const sim = makeSim();
  let prev = advanceToIntro(sim);

  prev = tap(sim, [BUTTON_A], prev);
  assert.equal(sim.phase, Phase.RoleReveal);
  assert.equal(sim.introPanel, 1);

  prev = tap(sim, [BUTTON_RIGHT], prev);
  assert.equal(sim.introPanel, 2);

  prev = tap(sim, [BUTTON_LEFT], prev);
  assert.equal(sim.introPanel, 1);

  prev = tap(sim, [BUTTON_B], prev);
  assert.equal(sim.phase, Phase.RosterReveal);
  assert.equal(sim.introPanel, 0);
}

function testSimultaneousForwardInputOnlyAdvancesOnePanel() {
  const sim = makeSim();
  let prev = advanceToIntro(sim);

  prev = tap(sim, [BUTTON_A, BUTTON_A, BUTTON_A], prev);
  assert.equal(sim.phase, Phase.RoleReveal);
  assert.equal(sim.introPanel, 1);
}

function testFinalPanelAllConfirmStartsRound() {
  const sim = makeSim();
  let prev = advanceToIntro(sim);

  prev = tap(sim, [BUTTON_A], prev);
  prev = tap(sim, [BUTTON_A], prev);
  prev = tap(sim, [BUTTON_A], prev);
  assert.equal(sim.phase, Phase.RoleReveal);
  assert.equal(sim.introPanel, 3);

  prev = tap(sim, [BUTTON_A, BUTTON_A], prev);
  assert.equal(sim.phase, Phase.RoleReveal);
  assert.equal(sim.introPanel, 3);

  prev = tap(sim, [0, 0, BUTTON_A], prev);
  assert.equal(sim.phase, Phase.Playing);
}

testLobbyStartsOneSecondAfterExpectedPlayersJoin();
testIntroTimesOutAfterFifteenSecondsTotal();
testIntroNavigationButtons();
testSimultaneousForwardInputOnlyAdvancesOnePanel();
testFinalPanelAllConfirmStartsRound();

console.log("intro flow tests passed");

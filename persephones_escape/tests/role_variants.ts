import assert from "node:assert/strict";
import { Sim } from "../game/sim.js";
import { Role, Room, Team, type GameConfig } from "../game/types.js";
import { TEAM_A_COLOR, TEAM_B_COLOR } from "../game/constants.js";

function configForPlayers(count: number): GameConfig {
  return {
    roles: [{ role: Role.Shades, team: Team.TeamA, count }],
    rounds: [{ durationSecs: 1, psychopomps: 0 }],
    obstacleCount: 0,
  };
}

function makeSim(count: number): Sim {
  const sim = new Sim(configForPlayers(count), 1234);
  for (let i = 0; i < count; i++) {
    const pi = sim.addPlayer(`p${i}`);
    assert.equal(pi, i);
    sim.players[i].room = i % 2 === 0 ? Room.RoomA : Room.RoomB;
  }
  return sim;
}

function share(sim: Sim, a: number, b: number) {
  sim.players[a].sharedWith.add(b);
  sim.players[b].sharedWith.add(a);
}

function testSpyReveal() {
  const sim = makeSim(2);
  sim.players[0].role = Role.Spy;
  sim.players[0].team = Team.TeamA;

  assert.equal(sim.colorRevealTeamColor(0), TEAM_B_COLOR);
  assert.equal(sim.roleRevealTeam(0, 1), Team.TeamB);

  share(sim, 0, 1);
  assert.equal(sim.roleRevealTeam(0, 1), Team.TeamA);
}

function testEchoSubstitutesWhenPrimaryMissing() {
  const sim = makeSim(4);
  sim.players[0].role = Role.EchoOfHades;
  sim.players[0].team = Team.TeamA;
  sim.players[1].role = Role.Cerberus;
  sim.players[1].team = Team.TeamA;
  sim.players[2].role = Role.Persephone;
  sim.players[2].team = Team.TeamB;
  sim.players[3].role = Role.Demeter;
  sim.players[3].team = Team.TeamB;
  sim.players[0].room = Room.RoomA;
  sim.players[2].room = Room.RoomA;
  share(sim, 0, 1);

  sim.checkWinCondition();
  assert.equal(sim.winner, Team.TeamA);
  assert.deepEqual(sim.effectiveRoleHolders(Role.Hades), [0]);
}

function testEchoInactiveWhenPrimaryPresent() {
  const sim = makeSim(5);
  sim.players[0].role = Role.Hades;
  sim.players[0].team = Team.TeamA;
  sim.players[1].role = Role.EchoOfHades;
  sim.players[1].team = Team.TeamA;
  sim.players[2].role = Role.Cerberus;
  sim.players[2].team = Team.TeamA;
  sim.players[3].role = Role.Persephone;
  sim.players[3].team = Team.TeamB;
  sim.players[4].role = Role.Demeter;
  sim.players[4].team = Team.TeamB;
  sim.players[0].room = Room.RoomA;
  sim.players[3].room = Room.RoomA;
  share(sim, 1, 2);

  sim.checkWinCondition();
  assert.equal(sim.winner, null);
  assert.deepEqual(sim.effectiveRoleHolders(Role.Hades), [0]);
}

function testMissingRequiredRolePreventsWin() {
  const sim = makeSim(3);
  sim.players[0].role = Role.Hades;
  sim.players[0].team = Team.TeamA;
  sim.players[1].role = Role.Persephone;
  sim.players[1].team = Team.TeamB;
  sim.players[2].role = Role.Demeter;
  sim.players[2].team = Team.TeamB;
  sim.players[0].room = Room.RoomA;
  sim.players[1].room = Room.RoomA;

  sim.checkWinCondition();
  assert.equal(sim.winner, null);
  assert.deepEqual(sim.effectiveRoleHolders(Role.Cerberus), []);
}

testSpyReveal();
testEchoSubstitutesWhenPrimaryMissing();
testEchoInactiveWhenPrimaryPresent();
testMissingRequiredRolePreventsWin();

console.log("role variant tests passed");

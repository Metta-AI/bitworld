import assert from "node:assert/strict";
import { Sim } from "../game/sim.js";
import { Phase, Role, Team, type GameConfig } from "../game/types.js";

const config: GameConfig = {
  roles: [{ role: Role.Shades, team: Team.TeamA, count: 6 }],
  rounds: [{ durationSecs: 1, hostages: 1 }],
  obstacleCount: 0,
  fastTimers: true,
};

const sim = new Sim(config, 456);
for (let i = 0; i < 6; i++) assert.equal(sim.addPlayer(`p${i}`), i);

sim.phase = Phase.Playing;
sim.setLeader(sim.players[0].room, 0);
sim.setLeader(sim.players[1].room, 1);

sim.createWhisper(0);
const leaderWhisper = sim.players[0].inWhisper;
sim.addToWhisper(leaderWhisper, 2);

sim.beginHostageSelect();
assert.equal(sim.phase, Phase.HostageSelect);
assert.equal(sim.players[0].inWhisper, -1, "hostage select ejects the leader from chat");
assert.equal(sim.players[2].inWhisper, leaderWhisper, "hostage select leaves non-leaders in existing whisper");
assert.equal(sim.whispers.get(leaderWhisper)?.occupants.has(2), true);

sim.hostagesSelectedA = [2];
sim.hostagesSelectedB = [3];
sim.players[2].selectedAsHostage = true;
sim.players[3].selectedAsHostage = true;
sim.beginLeaderSummit();

assert.equal(sim.phase, Phase.LeaderSummit);
assert.equal(sim.players[2].inWhisper, leaderWhisper, "leader summit leaves non-leader whispers alive");
assert.equal(sim.shoutMessagesA.at(-1)?.text.startsWith("LEAVING:"), true);
assert.equal(sim.shoutMessagesB.at(-1)?.text.startsWith("LEAVING:"), true);

sim.endLeaderSummit();
assert.equal(sim.phase, Phase.HostageExchange);
sim.finalizeExchange();

assert.equal(sim.shoutMessagesA.at(-1)?.text.startsWith("ARRIVED:"), true);
assert.equal(sim.shoutMessagesB.at(-1)?.text.startsWith("ARRIVED:"), true);

console.log("hostage chat tests passed");

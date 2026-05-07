import assert from "node:assert/strict";
import { DEFAULT_GAME_CONFIG } from "../game/constants.js";
import { Sim } from "../game/sim.js";

const sim = new Sim(DEFAULT_GAME_CONFIG, 123);
sim.addPlayer("p0");
sim.addPlayer("p1");

const colorRoom = { colorOffers: new Set<number>([0, 1]), messages: [] as any[], occupants: new Set<number>([0, 1]) };
(sim as any).executeColorSwap(colorRoom, 0, 1);
(sim as any).executeColorSwap(colorRoom, 0, 1);
assert.equal(colorRoom.messages.filter(m => String(m.text).includes("COLOR XCHG")).length, 1);
assert.deepEqual(sim.whisperColorOfferers(0), []);
assert.deepEqual(sim.whisperColorOfferers(1), []);

const roleRoom = { revealOffers: new Set<number>([0, 1]), messages: [] as any[], occupants: new Set<number>([0, 1]) };
(sim as any).executeRoleSwap(roleRoom, 0, 1);
(sim as any).executeRoleSwap(roleRoom, 0, 1);
assert.equal(roleRoom.messages.filter(m => String(m.text).includes("ROLE XCHG")).length, 1);
assert.deepEqual(sim.whisperShareOfferers(0), []);
assert.deepEqual(sim.whisperShareOfferers(1), []);

console.log("exchange_dedup ok");

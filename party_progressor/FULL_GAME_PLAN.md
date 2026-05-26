# Party Progressor Current State And Next Plan

## Summary

Party Progressor is now a cooperative side-scrolling expedition RPG. Players
choose tank, DPS, or healer roles, push right through escalating biome bands,
carry and spend expedition supplies, build camps, survive weather and terrain
pressure, and finish by defeating the Gate Titan and holding the final gate.

TribalCog remains an inspiration source for runtime PNG art, biome identity,
terrain/weather ideas, wildlife, resources, and settlement-sim texture, but
Party Progressor is not a TribalCog clone. It should feel like the
adventure-mode counterpart to a settlement sim: one party on the ground, making
local tactical decisions and turning shared survival into visible expedition
progress.

The game is well past the original greenfield plan. The next pass should focus
on polish endurance: long-run playability, readable observations, bot finish
rate, terrain/encounter tuning, and keeping the current systems understandable
instead of adding another large layer of mechanics.

Implementation update, 2026-05-25: the current pass widened biome regions by
50%, split the sprite-protocol map into clipped chunks for faster global
rendering, added armor equipment and an armor HUD, expanded the named monster
set to 44 species, added cone, line, trap, support, and swarm attack families,
reduced excess water while preserving long river chokepoints, and turned rescue
guides into temporary followers who thank the party when brought back to camp.
The follow-up asset pass makes the current imagegen workflow the preferred
source for new Party Progressor monster art, keeps TribalCog TSV prompts as a
fallback path, and wires 12 project-local generated monster sprites into the
runtime before falling back to borrowed TribalCog wolf/goblin/bear silhouettes.

Design iteration, 2026-05-25: regional detours now matter more. Completing
three real milestones inside a biome segment grants biome mastery, a persistent
party boon that shows in the HUD/score contract and changes later survival,
movement, cooldown, and combat math for that biome. This is meant to make the
best route a judgment call instead of a pure rightward sprint.

## Design Pillars

- Cooperative progression: the party shares a frontier and wins by moving
  deeper together.
- Role synergy: tank, DPS, and healer should each matter during travel,
  staging, fights, rescues, boss pressure, and final-gate completion.
- Terrain meaning: biomes affect movement, routing, hazards, enemies, shelter
  choices, and party formation.
- Expedition objectives: camps, relics, rescues, lairs, waystations, the boss,
  and the final gate create meaningful milestones beyond raw distance.
- Bot readability: every important decision should be visible through sprite
  labels, HUD text, object labels, status badges, or deterministic score fields.
- Small controls, rich outcomes: movement, attack, select, special, and chat
  should cover the whole game.

## Current Play Loop

1. Spawn at the origin camp.
2. Walk into the tank, DPS, or healer guild lane to choose a starting role.
3. Push right through repeating biome bands while staying close enough to help
   teammates.
4. Harvest resources and pick up one carried expedition item when hands are
   empty.
5. Build and upgrade forward camps to create recovery, role-swap, and shelter
   anchors.
6. Complete relic beacons, rescues, shrines, lairs, and biome waystations when
   their payoff is worth the detour.
7. Survive biome pressure from mire, cold, heat, fog, poison, slow, chill, and
   late-run exhaustion.
8. Defeat biome enemies, river ambushes, and the Gate Titan with role focus and
   formation bonuses.
9. Rally tank, DPS, and healer at the final gate for the expedition completion
   bonus.

The best run should not be pure speed. It should be a route decision: when to
push, when to harvest, when to build, when to recover, when to fight, and when
to skip danger to preserve momentum.

Biome mastery is the current answer to "why take the detour?" Clearing three
local problems in a region, such as a camp, waystation, lair, rescue, shrine,
or beacon, turns that biome from hostile territory into known ground. Mastery
then becomes a visible long-term reward: faster travel through the biome,
faster role-power recovery while in it, extra damage against local threats,
reduced status drag, and protection from that biome's survival pressure.

## Current Runtime Contract

Party Progressor's supported player surface is sprite protocol on the canonical
`/player` route.

- Player route: `/player`.
- Global route: `/global`.
- Reward route: `/reward`.
- Local browser route:
  `/client/player?address=ws://127.0.0.1:<port>/player&name=human`.
- Player input: sprite protocol `0x84` button mask packets.
- Player chat: sprite protocol `0x81` length-prefixed printable ASCII.
- Viewport: map layer `0x05` is authoritative; clients and bots must read it.
- Player viewport: 11 by 11 native tiles, 352 by 352 pixels.
- There is no separate Party Progressor `/sprite_player` player surface.

The Coworld player runner contract is:

- Read `COWORLD_PLAYER_WS_URL` when it is present.
- Accept `--name`, `--token`, and `--slot` for local and fallback runs.
- Preserve any runner-provided `slot`, `token`, and `name` query params.
- Connect bot players to `/player`, not a game-specific alternate route.

## Current World

The expedition is deterministic, tile-based, and side-scrolling. The world
starts with a safe origin and then repeats biome cycles across a long rightward
run. Each biome segment is now 21 tiles wide, which makes regions feel like
places rather than small blips, and the generated world is 596 by 18 tiles. The
current biome set is:

- Origin: safe spawn and starter role guilds.
- Forest: early food/wood sustain and fast early wildlife pressure.
- Plains: open travel, rally grouping, stone/food access, and role recharge.
- Swamp: rain, mud, shallow water, plank routes, bridge waystations, and mire.
- Desert: dust, sand/dunes, cactus shade, oasis sheltering, and heat.
- Snow: snow weather, hearth shelters, durable threats, shared warmth, and cold.
- Cave: fog, stone/gold, lantern staging, bats/slimes/brutes, and light choices.
- Ruins: final fog, ward staging, wraith/gate pressure, boss, and final gate.

Terrain is layered:

- Ground controls speed, biome visuals, and rough-terrain pressure.
- Elevation shades the map, slows travel, blocks visibility, and changes combat
  damage when attackers have high or low ground.
- Blocking props add dense terrain and biome identity without breaking the main
  expedition lane.
- Visibility shadows hide occluded tiles behind high terrain and dense blockers.
- Biome-backed RGBA rendering keeps transparent TribalCog-derived sprites from
  becoming black backgrounds in player observations.

Rivers are now expedition barriers rather than decorative puddles. Long
north-south rivers and forks carve across rightward progress, deep water blocks
ordinary movement, shallow fringes show the edge, and narrow bridge rows create
chokepoints. Crossing a registered bridge can trigger a one-time biome ambush
on the banks.

The sprite-protocol map is sent as chunk sprites instead of one full-world
sprite. `MapObjectId` remains a tiny camera anchor for old bot/client camera
tracking, while visible chunks occupy the current viewport. Both HTML and
native global clients clip sprite rasterization to the viewport before drawing,
which keeps the bird's-eye view responsive as the world grows.

## Current Roles And Combat

Roles are intentionally simple, with one normal attack and one role power:

- Tank: high HP, slower movement, guard special, damage blocking, biome-pressure
  sheltering for nearby teammates, and safer staging around harsh weather.
- DPS: fastest movement, stronger pressure, five-tile beam special in the
  facing direction, and faster relic/objective contribution in key moments.
- Healer: medium movement, hold-to-complete pulse special, healing, poison/slow/
  chill cleanse, downed-player rescue pressure, and passive triage support.
- Unarmed: fallback starter state until role gear is chosen.

Role gear is reusable. Origin role gear is walk-in simple for unarmed players
and arranged in separate lanes. Forward camp role gear is explicit and requires
select for already-roled players, with empty-hand checks so using carried
supplies near gear does not accidentally swap roles.

Party combat teaches the same language throughout the run:

- Enemy windups and lunges have visible sprite-protocol attack effects.
- Monster threat badges preview poison, slow, chill, and isolation danger.
- Recent mixed-role attacks on the same target create a visible focus window.
- Tank/DPS/healer trio formation creates a visible `TRIO` state and faster
  role-power recovery.
- The Gate Titan uses the same trio and focus language, including stagger
  windows when all three roles coordinate.

The monster ecology now covers 44 named species using generated and curated
silhouettes. Biomes seed local variants so the game reads as different dungeon
ecology rather than a few recolors. Wolves, bears, goblins, scorpions, slimes,
yetis, bats, wraiths, defenders, and boss-class enemies all feed the expedition
pressure model.

Twelve tactical monsters now have project-local imagegen sprites:

- Pack Alpha, Thorn Mender, Banner Goblin, and Net Thrower establish early
  pack-leader, support, rally, and trap silhouettes.
- Bog Witch and Leech Swarm make swamp fights visibly about poison, support,
  and isolation pressure.
- Fire Scorpion and Sand Burrower distinguish desert line attacks from trap
  ambushes.
- Ice Shaman and Snow Stalker make snow support and ambusher roles readable.
- Crystal Seer and Ruin Necromancer give cave/ruin support casters their own
  silhouettes instead of relying on tinted goblin/wraith fallbacks.

The preferred art workflow is documented in `docs/asset_pipeline.md`: generate
source art with imagegen on a flat chroma-key background, remove the key with
the shared imagegen helper, crop into 32x32 runtime sprites with
`scripts/prepare_monster_assets.py`, then keep final sprites under
`data/generated/monsters/`. `data/prompts/monster_assets.tsv` preserves the
older TribalCog prompt format as a fallback and migration source.

New tactical families add encounter shape:

- Pack leaders increase danger around nearby allies.
- Support casters heal and rally nearby non-boss monsters.
- Trap users punish crossing lanes and slow players.
- Line attackers fire narrow beams down lanes.
- Cone attackers claim broader frontal space.
- Swarms pressure isolated players and keep moving while pulsing.

## Current Items, Camps, And Objectives

Party Progressor uses a stacked carry inventory plus separate equipment. The
player observation tiles carried inventory along the lower HUD row with numeric
count badges where relevant. Armor is equipped in head, chest, and trinket
slots, and the top-right player HUD shows equipped armor as icons.

Current carried items and field uses:

- Wood: camp delivery, rally staging, and swamp plank placement.
- Food: carried eating, feeding wounded/statused teammates, meal shelters, and
  emergency survival buffering.
- Stone: camp delivery, ward staging, and cutting short steps through steep
  elevation.
- Gold: fortification, late-run camp funding salvage, and portable cave/ruin
  light while carried.

Current armor items and field uses:

- Scout Hood and Leather Vest: movement bonuses for faster route control.
- Iron Helm and Scale Mail: HP or mitigation for frontline durability.
- Fur Hood and Frost Cloak: cold-weather protection and faster recovery.
- Venom Charm: faster status cleanup after poison-heavy encounters.
- Lantern Charm: fog protection in cave and ruin travel.
- Rally Horn: faster role-power recovery during grouped pushes.

Camps are the core forward infrastructure:

- Base camps cost wood and stone, heal slightly, mark progress, create role
  swap points, and become shelters.
- Activated camps reveal local shortcuts, clear some blockers, reduce rough
  terrain, and soften nearby elevation.
- Extra supplies specialize camps into fortified, provisioned, warded, rally,
  and aid staging points.
- Shelters protect from biome pressure, accelerate status cleanup, and give
  wounded players a recovery anchor.

Biome mastery now links these objectives into a more legible local story. A
single shrine or lair is useful, but solving enough local problems earns a
persistent mastery boon:

- Forest mastery turns early foraging into a real supply advantage.
- Plains mastery reinforces rally pacing and role-power uptime.
- Swamp mastery makes mud and water routes less punishing after the party has
  built local knowledge.
- Desert and snow mastery reduce harsh-weather survival tax.
- Cave and ruin mastery reduce fog/exhaustion pressure and help late fights.

Objective types are visible primarily through world sprites, semantic sprite
labels, and compact prompts:

- Relic beacons: cooperative attunement, relic shards, route survey, terrain
  softening, local threat pacification, and final-gate prerequisites.
- Shrines: optional score, recovery, food, cleansing, and blessing sanctuaries.
- Rescues: cooperative hold, food/heal payoff, guide route reveal, a temporary
  follower who can be brought back to camp, and healer acceleration.
- Lairs: attackable side objectives, supply caches, local pacification, and a
  temporary hunt damage window.
- Waystations: biome-specific route/shelter detours such as forage, rally,
  bridge, oasis, hearth, lantern, and ward.
- Final gate: requires boss defeat, relic progress, camp progress, and a visible
  party ritual that completes fastest with tank, DPS, and healer present.

## Current Survival And Readability

Environmental pressure is meant to be readable before damage lands. Players and
bots should see the problem, infer the answer, and act without hidden rules.

Current pressure loops:

- Swamp mire slows exposed players on mud, shallow water, or water; plank
  routes, bridge waystations, camps, and tank guard counter it.
- Snow cold consumes food or carried rations before HP damage; shared warmth,
  hearths, shelters, camps, meal rations, and tank guard counter it.
- Desert heat mirrors cold with food/rations, cactus shade, oasis waystations,
  camps, and tank guard as counters.
- Cave and ruin fog disorients isolated players; grouping, lantern/ward
  waystations, carried gold light, camps, and tank guard counter it.
- Poison, slow, chill, exhaustion, biome pressure, guide, route, hunt, morale,
  ration, triumph, mastery, rally/shade/warmth/light, and guard/blessing are
  modeled as active player effects. The top-right panel is now an icon strip for
  active effects instead of a text explanation block.
- The sprite layer now draws only one urgent in-world effect aura per player,
  preferring harmful effects over boons. Low health, downed state, help,
  regroup, focus, stagger, role, and chat pings still use compact in-world
  status markers where labels are the clearest signal.
- Forest forage is deliberately passive. It can trickle food in the background,
  but it no longer creates a big green plus, a `FORAGE` HUD line, or a status
  badge until the game teaches it through an explicit choice.
- The top-left HUD is sprite-first: a health bar plus small frontier/resource
  icons with numeric counters. Visible prose is reserved for chat, count badges,
  and short teaching prompts that introduce an explicit choice.

Chat is part of the readability layer. Short player messages such as regroup,
help, relic, camp, food, rescue, and lair create temporary in-world ping badges
so coordination is visible in the 11 by 11 observation window.

## Current Bots And Tests

Konrad is the current Party Progressor bot. It parses sprite-v1 packets from
`/player`, reads the dynamic viewport, identifies itself through the selected
player sprite, and uses semantic labels instead of raw pixel guesses where
possible.

Current Konrad capabilities include:

- Role choice by slot/name with tank, DPS, and healer coverage.
- Objective targeting from sprite labels and HUD hints.
- Resource, carried-item, shelter, camp, and role-gear disambiguation.
- Survival responses for mire, cold, heat, fog, poison, slow, chill, wounds,
  isolation, downed teammates, and stale shelters.
- Role-power use from HUD state, including tank guard, DPS beam, and healer
  hold pulse.
- Push recovery, lane correction, stale-target filtering, final-gate rallying,
  and avoidance of chat/resource-label false positives.

Focused test coverage currently protects:

- Role choice, role reuse, movement speed, role powers, party focus, trio
  formation, boss/final gate, and downed rescue.
- Biomes, repeated expedition generation, rivers, bridge ambushes, elevation,
  visibility shadow, weather overlays, and biome-backed observation pixels.
- Carry inventory, stack counts, food use, feed use, plank/step field tools,
  camp upgrades, waystations, lairs, rescues, shrines, beacons, and shelters.
- Sprite-v1 compatibility, viewport parsing, Snappy RGBA sprite definitions,
  canonical `/player` input/chat packets, and player-client route behavior.
- Monster species breadth, rich generated sprites, threat badges, tactical
  status hooks, drops, objective prompts, chat pings, and rendered observation
  preview PNGs.

## Next Phase Plan: Polish Endurance

The next implementation pass should tune and harden the existing game. Do not
add major new systems unless a tuning run proves the current systems cannot
produce a readable, finishable expedition.

### 1. Long-Run Playability

Target behavior: a three-role party should regularly reach late biomes, fight
the Gate Titan, and complete the final gate in deterministic long-run smokes.

Implementation direction:

- Add or formalize a deterministic multi-bot smoke that runs long enough to
  inspect camps, relics, boss, and final-gate completion behavior.
- Save and inspect score snapshots after bot disconnects, preserving the richest
  expedition state.
- Tune `maxTicks`, resource availability, camp costs, relic count, final-gate
  hold time, and boss pressure only when the run proves a specific pacing issue.
- Treat repeated backtracking, shelter orbiting, stale floor-drop chasing,
  unbuildable camp loops, and endgame side-objective sweeps as failures.

Acceptance signal:

- A seeded Konrad smoke produces non-zero frontier, role diversity, camp
  progress, relic progress, and late-run objective progress without ending in a
  local target loop.
- At least one documented seed should complete the final gate or reach the
  final-gate rally state within the intended tick budget.

### 2. Observation And UI Readability

Target behavior: a human opening the canonical player URL should immediately
understand role choice, current objective, carried item, HP, biome pressure,
nearby threats, and whether a held objective is progressing.

Implementation direction:

- Review saved player observation previews for every biome and tune badge,
  weather, objective prompt, and attack-effect density.
- Keep badge labels compact; prefer fewer stronger signals over stacked text.
- Ensure carried inventory stays tiled along the bottom and never over the
  controlled adventurer.
- Keep the top-left HUD sprite-first: health bar, frontier/resource icons, and
  numbers only for quantities.
- Keep material buffs/debuffs dual-coded with sparse in-world auras plus
  top-right effect icons. Longer explanations belong in docs or explicit
  teaching moments, not always-on HUD text.
- Make hold actions visibly fill or animate while active: healer pulse,
  relics, rescues, waystations, lairs, and final gate.

Acceptance signal:

- Observation preview PNGs are opaque, biome-backed, visually distinct by biome,
  and readable at normal browser scale.
- Manual play from spawn to first camp does not require reading source docs to
  choose a role, attack, use special, pick up supplies, or identify the next
  objective.

### 3. Find The Fun Retrenchment

Target behavior: Party Progressor should first be an understandable expedition:
choose a role, push right, rescue villagers, cross chokepoints, survive one
clear problem at a time, and bring the party home stronger. Complexity should
earn its screen space.

Implementation direction:

- Remove or hide passive rules that are not taught in the moment. Forage is the
  model: useful simulation texture, not a player-facing status.
- Keep in-world badges sparse. A player should see role, urgent danger, party
  need, and one meaningful active effect, while the top-right panel shows the
  current armor/effect icon inventory.
- Make rescued villagers behave like companions: they follow in a line behind
  the player instead of stacking on the same tile, then thank the party at camp.
- Reintroduce biome and loot complexity only when it creates a visible decision:
  cross now or route around, spend food or risk pressure, hold a rescue or fight
  the ambush, equip armor or keep a carried tool.

Acceptance signal:

- A first-time player can explain what is happening on screen after 60 seconds:
  their role, their next objective, why they are hurt or slowed, what the
  rescue follower is doing, and what button they should press next.

### 4. Terrain And Encounter Tuning

Target behavior: terrain should make route choices interesting without trapping
humans or bots, and encounters should create tactical pressure without burying
the screen in effects.

Implementation direction:

- Tune forest density, cave/ruin occlusion, elevation ridges, and generated
  blockers against the 11 by 11 viewport.
- Keep long rivers and forks, but verify each crossing has exactly readable
  chokepoint geometry, bank space for ambushes, and a guaranteed recovery route.
- Tune river ambush spawn distance, species, and count so the first crossing
  teaches the system and later crossings escalate without wiping solo players.
- Review monster telegraph/lunge timing for each biome family and reduce clutter
  where attack effects overlap objective prompts.
- Keep the main expedition corridor traversable even when side routes are dense.

Acceptance signal:

- Seeded terrain tests continue to prove water, bridge, elevation, dense forest,
  and visibility-shadow invariants.
- Manual play can identify why movement slowed or line of sight is blocked from
  the visible terrain, not only from HUD text.

### 5. Bot Endurance

Target behavior: Konrad should behave like a readable party member, not an
omniscient solver and not a stuck target chaser.

Implementation direction:

- Strengthen stale-target filtering around old camps, dropped supplies, side
  objectives behind the team frontier, and completed shelters.
- Prefer group recovery over solo shelter recovery when isolation, downed
  teammate, or final-gate rally is active.
- Keep optional objectives opportunistic unless the HUD names them as the next
  step or they are on the forward route.
- Make resource gathering override camp activation only when the HUD or shared
  counters prove the camp cannot be built.
- Keep named bot roles stable around camp role gear and supply delivery.

Acceptance signal:

- Multi-bot smokes no longer spend long stretches orbiting old shelters, stale
  drops, unbuildable camps, or noncritical side objectives.
- DPS, tank, and healer all use their special powers during meaningful fights
  or survival windows in a long run.

### 6. Packaging And Docs Hygiene

Target behavior: Party Progressor should remain easy to run, test, and submit
through Coworld infrastructure.

Implementation direction:

- Keep `cogame_manifest.json` protocols pointed at `docs/sprite_v1.md` and
  `docs/reward_v1.md`.
- Keep `COWORLD_PLAYER_WS_URL`, `--name`, `--token`, and `--slot` in sync with
  the repo bot-player contract.
- Keep generated observation previews and runlogs out of PRs unless a future
  task explicitly requests golden artifacts.
- Use this file as the canonical product/implementation context; avoid adding a
  second overlapping roadmap unless the plan is intentionally split.

Acceptance signal:

- `git diff --check` passes.
- `nim r tests/test_client_routes.nim` passes.
- `nim r tests/test_party_progressor_sim.nim` passes.
- A local player can connect through the canonical browser URL and receive
  sprite-v1 packets from `/player`.

## Local Validation Commands

Run the focused checks:

```sh
nim r tests/test_client_routes.nim
nim r tests/test_party_progressor_sim.nim
```

Build and run locally:

```sh
nim c -o:out/party_progressor party_progressor/party_progressor.nim
./out/party_progressor --address:127.0.0.1 --port:2000
```

Open the player client:

```text
http://127.0.0.1:2000/client/player?address=ws://127.0.0.1:2000/player&name=human
```

If port `2000` is already occupied, use another port consistently in both the
server command and the `address=` query param.

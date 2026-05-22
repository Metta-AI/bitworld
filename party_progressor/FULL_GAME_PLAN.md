# Party Progressor Full Game Plan

## Summary

Party Progressor should be a cooperative side-scrolling expedition RPG. Players
choose complementary roles, push right through dangerous biome zones, complete
objectives, build forward progress, survive escalating encounters, and score by
how far and how meaningfully the party advances.

The game should stay Coworld-compatible and easy to understand from the player
and bot perspective. TribalCog is an inspiration source for runtime PNG art,
biome identity, terrain mechanics, weather flavor, resources, wildlife, and camp
ideas, but Party Progressor is not a TribalCog clone. It should feel like the
adventure-mode counterpart to a settlement sim: one party on the ground, moving
through the world, making local tactical choices, and turning shared survival
into visible expedition progress.

## Design Pillars

- Cooperative progression: the party shares a frontier and wins by moving deeper
  together.
- Role synergy: tank, DPS, and healer should all matter in repeated pushes.
- Terrain meaning: biomes should affect routes, movement, hazards, enemies, and
  planning.
- Expedition objectives: distance alone is not enough; camps, beacons, relics,
  and the final gate create meaningful milestones.
- Bot readability: scoring and visible objects should stay deterministic and
  understandable to tournament bots.
- Borrowed mechanics, distinct shape: TribalCog mechanics should become
  moment-to-moment expedition pressure, not a local RTS economy.

## Target Loop

1. Spawn at the origin camp and choose a role.
2. Move right through biome bands while keeping the party close enough to help.
3. Harvest light shared resources from landmark nodes.
4. Activate forward camps with wood and stone.
5. Use camps as recovery, role-swap, and respawn anchors.
6. Complete biome beacons to earn relic shards.
7. Fight themed enemies and survive weather/terrain pressure.
8. Defeat the late-zone boss.
9. Activate the final gate for a run-completion bonus.

The best run should not be pure speed. It should be a route decision: when to
push, when to harvest, when to activate a camp, when to fight, and when to skip
danger to preserve momentum.

## World And Terrain

The expedition world is organized into horizontal biome bands:

- Origin: safe spawn and starter role gear.
- Forest: early wood/food resources and fast early wildlife pressure.
- Plains: food/stone resources and open travel.
- Swamp: rain, mud, shallow water, bridges, and slower movement.
- Desert: dust, sand, dunes, cactus props, and camp pressure.
- Snow: snow weather, slower travel, durable threats, and survival pressure.
- Cave: fog, cave floor, stone/gold resources, and denser hostile encounters.
- Ruins: final hostile zone, structures, gold/stone, boss, and final gate.

Terrain should remain tile-based and deterministic. Ground tiles and blocking
props are separate concepts:

- Ground tiles carry movement and visual identity.
- Elevation is a separate deterministic tile layer: high ground is visibly
  brighter in sprite observations and slows travel, making ridges and snow/cave
  approaches tactically distinct without changing the control scheme.
- Blocking props create obstacles and biome texture.
- The center lane must remain traversable.
- Deep water and equivalent blockers should never make the generated run
  impossible.
- Biome identity should be readable even when borrowed art has transparent
  pixels.

## Weather And Biome Pressure

Weather is deterministic by biome and tick:

- Rain in swamp.
- Dust in desert.
- Snow in snow biome.
- Fog/dim effects in cave and ruins.
- Clear weather elsewhere.

Weather should have light gameplay impact. It can slightly modify movement,
visibility, healing windows, or hazard timing, but it should not make the
controls feel opaque. The intended pressure is "plan around this biome," not
"fight the input system."

## Roles And Combat

Keep the current role model:

- Tank: higher HP and guard ability.
- DPS: stronger attacks and objective/enemy clearing.
- Healer: pulse healing and expedition sustain.
- Unarmed: fallback starter role.

Role gear should remain reusable. Origin role gear is always available, and
activated forward camps should provide local role swapping so deeper runs are
recoverable.

Enemy families should be simple and readable:

- Wolves: fast early pack pressure.
- Scorpions: desert pressure around dunes and exposed routes.
- Slimes: swamp/cave pressure where footing is already poor.
- Yetis: snow-biome durable threats that compound cold pressure.
- Bats: cave harassment.
- Wraiths and camp defenders: objective and ruin pressure.
- Bears: durable solitary threats.
- Boss: final late-zone objective.

Keep the existing telegraph/lunge combat language so enemy danger stays legible.
Future enemies should first add biome-specific positioning or timing pressure,
not a pile of new controls.

## Resources, Camps, And Objectives

Resources are team-shared and deliberately small:

- Wood.
- Food.
- Stone.
- Relic shards.

Resource nodes are interacted with through the existing attack/action language.
Harvesting a resource also gives the attacker a single carried expedition item
when their hands are empty, or drops that item on the ground if they are already
carrying something. This borrows the readable one-item carry pattern from the
dinner-party hosting game without turning Party Progressor into a crafting sim.
Camps cost wood and stone. Activating a camp should:

- Mark expedition progress.
- Provide local role gear.
- Heal the party slightly.
- Give a score bonus.
- Create a readable regroup point for bots and humans.

Beacon objectives should award relic shards. The final gate should require the
boss to be defeated before completion.

Food is currently mostly a score/resource signal. The next mechanical pass
should make it matter without turning the game into inventory management:

- Auto-consume as shared emergency rations when players are badly injured.
- Buffer cold exposure in the snow biome before HP damage starts landing.
- Fuel stronger camp healing.
- Prevent late-run exhaustion.
- Give healer/tank teams more strategic sustain choices.

## Scoring And Results

Scoring should combine raw frontier distance with milestone progress:

- Frontier tiles.
- Biomes reached.
- Objectives completed.
- Relic shards collected.
- Camps activated.
- Resources collected.
- Boss defeated.
- Final gate completed.

Keep existing diagnostics:

- Personal frontier.
- Role.
- HP/hearts.
- Distance walked.
- Damage done.
- Healing done.
- Damage blocked.
- Messages sent.

The reward endpoint should use the combined team score, while result JSON should
preserve the raw frontier fields for analysis.

## Player Observation And Sprite Protocol

The player client should use the sprite-player protocol as the main interface:

- Canonical route: `/player`.
- Supported player protocol: sprite-player. There is no separate framebuffer
  player surface for Party Progressor.
- Input path: sprite protocol `0x84` input masks.
- Chat path: sprite protocol `0x81` chat messages.
- The map layer viewport is authoritative and sent in protocol message `0x05`.

The local player observation window should be large enough to support expedition
planning. The default target is an 11 by 11 native-tile window, matching 352 by
352 pixels at Party Progressor's 32 by 32 tile size. This is intentionally larger
than the older 128 by 128 screen constants because the player needs to see
routes, nearby objectives, enemies, and teammates before they are already on top
of them.

Clients and bots must not hard-code the old 128 by 128 player view. They should
read viewport width and height from the `0x05` map layer message, keep those
values in local state, and use them for camera-center reasoning and observation
sampling.

## Art And Asset Strategy

Borrow TribalCog runtime PNGs from:

```text
~/Code/games/games/tribalcog/data
```

Party Progressor should load a curated mapping instead of importing the whole
asset tree. The asset manifest should support `TRIBALCOG_DATA_DIR` for machines
where the path differs.

Runtime PNGs are fitted into Party Progressor's 32 by 32 art cell budget at load
time. This is fine for V1 iteration. A future polish pass can replace it with a
generated atlas if packaging, performance, or visual consistency becomes
important.

Borrowed TribalCog sprites often contain transparent pixels. Those pixels must
not render as black in player observations. The map renderer should always draw
an opaque biome-specific tile background before blitting borrowed ground art:

- RGBA sprite protocol map: fill each tile with the biome background color.
- Legacy framebuffer map: fill each tile with the nearest palette biome color.
- Borrowed sprite alpha stays useful for detail edges, but the player always
  sees biome-colored ground underneath.

## UI And Global View

Player HUD should show:

- Frontier.
- HP.
- Role.
- Current biome.
- Current weather.
- Shared resources.
- Relic count.

Global view should show:

- Biome-colored terrain map.
- Players, mobs, pickups, landmarks, camps, and objectives.
- Team score, frontier, biome, weather, and resource summary.
- Selected-player details when a player is clicked.

The global view can stay wider and more supervisory than the player view. The
player view should feel like the party's embodied tactical camera, not a tiny
debug viewport.

## Bots And Tournament Compatibility

Party Progressor must stay compatible with the Coworld tournament runner:

- Read `COGAMES_ENGINE_WS_URL` when it is present.
- Accept `--name`, `--token`, and `--slot` as local and older-runner fallbacks.
- Connect to `/player`.
- Include `slot`, `token`, and `name` query params when provided by the runner.

Bots should treat visible resource/objective landmarks as useful targets, keep
survival and frontier pushing as default behavior, and understand the larger
Party Progressor world dimensions. Bot adapters should parse the sprite protocol
viewport instead of assuming fixed screen constants.

## Current V1 Status

The first full-game implementation pass includes:

- Runtime TribalCog asset mapping and fallback loading.
- Biome bands and deterministic terrain/weather identity.
- Ground movement modifiers and blocking water.
- Biome-flavored props.
- Shared wood, food, stone, and relic shard counters.
- Resource landmarks harvested by attacks.
- Camp activation with forward role gear and healing.
- Beacon objectives and final-gate logic.
- Wolves, camp defenders, bears, and boss scoring.
- Combined team score and expanded result JSON.
- Player/global HUD updates.
- Sprite-player protocol support for the player surface.
- An 11 by 11 native-tile player viewport.
- Biome-backed transparent terrain rendering for sprite observations and the
  legacy framebuffer path.
- In-world role labels for the origin and camp gear picks.
- Role-tinted player sprites: tank reads blue, DPS reads red, healer reads
  green, while unarmed players keep their player-slot identity color.
- DPS cleave on the `B` button, plus tank guard and healer pulse.
- Food auto-healing and snow exposure pressure that consumes food before
  damaging players.
- One-item expedition carrying for harvested wood, food, stone, and gold,
  including visible held-item sprites and select-to-use/drop behavior.
- Deterministic tile elevation with movement slowdown and sprite-map shading.
- Biome-specific monster families: scorpions, slimes, yetis, bats, and wraiths
  join wolves, goblins, bears, and the boss.
- Konrad bot updates for world size, viewport parsing, and new sprite labels.
- Focused sim tests for biome/weather, movement modifiers, resources, camps,
  objectives, boss scoring, player viewport size, and biome-backed transparent
  sprites.
- Sprite protocol fixture tests that parse Party Progressor player packets with
  the same message framing used by existing BitWorld sprite-protocol bots.

## Broader Roadmap

### Near-Term Implementation

- Tune the 11 by 11 viewport after real bot/human observation checks.
- Add stronger in-world affordances for resource nodes, beacon completion, camp
  costs, and final-gate requirements.
- Tune food and snow-exposure pacing with multi-player runs.
- Add player-observation screenshots to smoke tests so black-background
  regressions are visually obvious.
- Expand bot targeting: gather resources when camps are unaffordable, prefer
  beacons after camps, avoid strong enemies when low on HP, and regroup near
  teammates.

### Expedition Depth

- Give each biome one tactical rule that changes party behavior.
- Add optional side objectives that trade time for score or survivability.
- Let camps upgrade from simple checkpoints into expedition infrastructure:
  healing, role swap, weather shelter, or shortcut reveal.
- Add stronger teammate legibility: pings, downed-player indicators, and simple
  "regroup" incentives.
- Make the final gate feel earned by requiring a visible chain of relic, boss,
  and camp progress.

### Polish And Packaging

- Improve visual polish for weather overlays in global protocol views, not only
  the local framebuffer path.
- Consider a generated Party Progressor atlas once the curated TribalCog asset
  set stabilizes.
- Add long-run smoke tests with multiple players and bots.
- Add a small protocol fixture test for `/player` sprite-player behavior.
- Keep manifests, docs, and runner contract references aligned with the
  canonical `/player` route.

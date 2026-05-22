# Party Progressor Full Game Plan

## Summary

Party Progressor should be a cooperative side-scrolling expedition RPG.
Players choose complementary roles, push right through dangerous biome zones,
complete objectives, build forward progress, survive escalating encounters, and
score by how far and how meaningfully the party advances.

The game should stay Coworld-compatible and easy to understand from the player
and bot perspective. TribalCog should be borrowed selectively for runtime PNG
art, biome identity, terrain mechanics, weather flavor, resources, wildlife, and
enemy-camp ideas. Party Progressor should not become a full RTS.

## Design Pillars

- Cooperative progression: the party shares a frontier and wins by moving
  deeper together.
- Role synergy: tank, DPS, and healer should all matter in repeated pushes.
- Terrain meaning: biomes should affect routes, movement, hazards, and enemy
  pressure.
- Expedition objectives: distance alone is not enough; camps, beacons, relics,
  and the final gate create meaningful milestones.
- Bot readability: scoring and visible objects should stay deterministic and
  understandable to tournament bots.

## Target Loop

1. Spawn at the origin camp and choose a role.
2. Move right through biome bands.
3. Harvest light shared resources from landmark nodes.
4. Activate forward camps with wood and stone.
5. Complete biome beacons to earn relic shards.
6. Fight themed enemies and survive weather/terrain pressure.
7. Defeat the late-zone boss.
8. Activate the final gate for a run-completion bonus.

## World And Terrain

The expedition world is organized into horizontal biome bands:

- Origin: safe spawn and starter role gear.
- Forest: early wood/food resources and wolf pressure.
- Plains: food/stone resources and open travel.
- Swamp: rain, mud, shallow water, bridges, and slower movement.
- Desert: dust, sand, dunes, cactus props, and goblin pressure.
- Snow: snow weather, slower travel, bears, and survival pressure.
- Cave: fog, cave floor, stone/gold resources, and denser hostile encounters.
- Ruins: final hostile zone, goblin structures, gold/stone, boss, and final gate.

Terrain should remain tile-based and deterministic. Ground tiles and blocking
props are separate concepts:

- Ground tiles carry movement and visual identity.
- Blocking props create obstacles and biome texture.
- The center lane must remain traversable.
- Deep water and equivalent blockers should never make the generated run
  impossible.

## Weather

Weather is deterministic by biome and tick:

- Rain in swamp.
- Dust in desert.
- Snow in snow biome.
- Fog/dim effects in cave and ruins.
- Clear weather elsewhere.

Weather should have light gameplay impact. It can slightly modify movement,
visibility, or hazard timing, but it should not make the controls feel opaque.

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
- Goblins: camp/ruin defenders.
- Bears: durable solitary threats.
- Boss: final late-zone objective.

Keep the existing telegraph/lunge combat language so enemy danger stays legible.

## Resources, Camps, And Objectives

Resources are team-shared and deliberately small:

- Wood.
- Food.
- Stone.
- Relic shards.

Resource nodes are interacted with through the existing attack/action language.
Camps cost wood and stone. Activating a camp should:

- Mark expedition progress.
- Provide local role gear.
- Heal the party slightly.
- Give a score bonus.

Beacon objectives should award relic shards. The final gate should require the
boss to be defeated before completion.

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

## Art And Asset Strategy

Borrow TribalCog runtime PNGs from:

```text
~/Code/games/games/tribalcog/data
```

Party Progressor should load a curated mapping instead of importing the whole
asset tree. The asset manifest should support `TRIBALCOG_DATA_DIR` for machines
where the path differs.

Runtime PNGs are fitted into Party Progressor's 32 by 32 art cell budget at
load time. This is fine for V1 iteration. A future polish pass can replace it
with a generated atlas if packaging, performance, or visual consistency becomes
important.

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

## Bots And Tournament Compatibility

Party Progressor must stay compatible with the Coworld tournament runner:

- Read `COGAMES_ENGINE_WS_URL`.
- Accept `--name`, `--token`, and `--slot`.
- Connect to `/player` with `slot`, `token`, and `name`.

Bots should treat visible resource/objective landmarks as useful targets, keep
survival and frontier pushing as default behavior, and understand the larger
Party Progressor world dimensions.

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
- Wolves, goblins, bears, and boss scoring.
- Combined team score and expanded result JSON.
- Player/global HUD updates.
- Konrad bot updates for world size and new sprite labels.
- Focused sim tests for biome/weather, movement modifiers, resources, camps,
  objectives, and boss scoring.

## Follow-Up Work

- Balance biome lengths, enemy density, resource placement, camp costs, and
  score weights after real playtests.
- Make food matter mechanically, for example as camp healing fuel, exhaustion
  resistance, or temporary weather mitigation.
- Add clearer in-world affordances for resource nodes, beacon completion, camp
  costs, and final-gate requirements.
- Improve bot strategy beyond sprite classification: gather resources when
  camps are unaffordable, prefer beacons after camps, avoid strong enemies when
  low on HP, and regroup near teammates.
- Add visual polish for weather overlays in global protocol views, not only the
  local framebuffer path.
- Consider a generated Party Progressor atlas once the curated TribalCog asset
  set stabilizes.
- Add long-run smoke tests with multiple players and bots.

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
- Desert: dust, sand, dunes, cactus props, heat pressure, and oasis staging.
- Snow: snow weather, slower travel, durable threats, and cold survival
  pressure.
- Cave: fog disorientation, cave floor, stone/gold resources, lantern staging,
  and denser hostile encounters.
- Ruins: final fog pressure, structures, gold/stone, ward staging, boss, and
  final gate.

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

Mixed-role focus fire should reward party composition without adding extra
buttons. When two or three distinct combat roles have recently attacked the
same enemy, normal attacks should hit harder and the focused target should show
a compact in-world affordance so players understand the opening.

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
- Support later camp specializations, starting with fortification and
  provisioned meal shelters.
- Let role composition shape staging: tanks can ward camps, DPS can rally them,
  and healers can turn them into aid posts with different local benefits.

Beacon objectives should award relic shards. The final gate should require
relic progress, camp progress, and boss defeat before completion.

Food is currently mostly a score/resource signal. The next mechanical pass
should make it matter without turning the game into inventory management:

- Auto-consume as shared emergency rations when players are badly injured.
- Buffer cold exposure in the snow biome before HP damage starts landing.
- Provision meal shelters that fuel stronger camp healing.
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
- Optional shrine side objectives that trade route time for score, emergency
  food, healing, and status cleansing.
- Optional rescue side objectives seeded through biome bands: stranded travelers
  require a short nearby hold, heal the party slightly, and add emergency food,
  with healers completing rescues faster.
- Optional monster lair side objectives seeded through biome bands: parties can
  spend attack time to destroy local dens for supplies, side-objective score,
  and a short pacification of nearby threats.
- Biome waystation side objectives seeded through biome bands: forage, rally,
  bridge, oasis, hearth, lantern, and ward detours complete faster for a hinted
  role, reshape nearby rough terrain into a readable route, and grant
  biome-specific survival payoffs.
- Wolves, camp defenders, bears, and boss scoring.
- Combined team score and expanded result JSON.
- Player/global HUD updates.
- Player and global HUD objective hints that call out the next expedition step:
  role choice, push direction, biome waystations, camp resource needs, relics,
  boss, and final gate.
- Sprite-player protocol support for the player surface.
- An 11 by 11 native-tile player viewport.
- Biome-backed transparent terrain rendering for sprite observations and the
  legacy framebuffer path.
- In-world role labels for the origin and camp gear picks.
- Origin role gear now uses separated starter lanes: tank is up, DPS is forward,
  and healer is down, preventing accidental role swaps while making the opening
  choice clearer.
- Origin role gear now stays reusable for unarmed players but no longer
  silently swaps a player who already chose a role; deeper camp gear remains the
  explicit role-swap surface.
- Role-tinted player sprites: tank reads blue, DPS reads red, healer reads
  green, while unarmed players keep their player-slot identity color.
- Sprite-player role badges now appear above roled players (`TNK`, `DPS`,
  `HEAL`) using non-gear labels, so humans and bots can distinguish party
  composition in crowded fights without confusing badges for role-pickup
  targets.
- Origin and camp role gear now labels both the role and its `B` power: tank
  guard, DPS cleave, and healer pulse.
- DPS cleave on the `B` button, plus tank guard and healer pulse.
- Healer triage support: nearby healers now slowly stabilize low-health
  teammates between pulse casts, making the support role useful during
  sustained pushes.
- Downed rescue windows: defeated players now visibly wait for rescue before
  bleeding out to a camp respawn, giving nearby allies a direct recovery moment
  and preserving carried value when the rescue succeeds.
- Food auto-healing and snow exposure pressure that consumes food before
  damaging players.
- Desert heat exposure now mirrors the snow survival loop: food or carried food
  absorbs a heat pulse before HP damage, while completed oasis waystations and
  camps shelter nearby players.
- Cave and ruin fog now disorients isolated unsheltered players with slow
  pressure, while nearby allies, completed lantern/ward waystations, and camps
  keep the party oriented.
- Activated camps now act as expedition shelters: nearby players are protected
  from snow, desert, and fog exposure, recover poison/slow/chill statuses
  faster, and slowly heal while regrouping.
- Activated camps also reveal short road or bridge shortcuts through nearby
  rough ground, clearing blockers and reducing elevation so camp investment
  permanently improves the expedition route.
- Activated camps can be fortified with extra wood and stone, converting them
  into safer staging points that repeatedly clear nearby non-boss threats and
  show a distinct fort prompt.
- Activated camps can also be provisioned with food into meal shelters, giving
  parties a visible sustain-focused staging choice that heals resting players
  faster and shows a distinct meals prompt.
- Activated camps now support role-linked specializations: tank ward camps hold
  a safer perimeter, DPS rally camps recover role powers faster, and healer aid
  camps cleanse status pressure faster while regrouping.
- Snow hearth waystations become local cold shelters after completion, giving
  snow expeditions a second kind of safe staging choice beyond full camps.
- One-item expedition carrying for harvested wood, food, stone, and gold,
  including visible held-item sprites and select-to-use/drop behavior.
- Deterministic tile elevation with movement slowdown and sprite-map shading.
- Biome-specific monster families: scorpions, slimes, yetis, bats, and wraiths
  join wolves, goblins, bears, and the boss.
- A 32-species monster roster generated from the core creature silhouettes:
  each biome now seeds multiple named local species so forest, swamp, desert,
  snow, cave, and ruins read like distinct dungeon ecology instead of palette
  swaps of the same few enemies.
- Biome monster tactical hooks: slimes slow players, desert creatures poison,
  snow threats chill, bats harass from farther away, and wraith/gate enemies
  punish isolated players so grouping has real value.
- Dynamic sprite-protocol weather overlays: rain, dust, snow, and fog now show
  as translucent deterministic particles in both player and global map views,
  not only in the legacy framebuffer path.
- In-world player affordances for the larger observation window: poison, slow,
  chill, isolation danger, low-health help state, and downed rescue state now
  appear as compact badges next to players, and landmarks show readable labels
  for resources, camp costs, relic beacons, and final-gate requirements, with
  activated camps relabeled as shelters.
- Chat pings now turn short player messages such as regroup, help, relic, camp,
  food, rescue, and lair into temporary compact in-world badges so coordination
  stays readable in the 11 by 11 observation window.
- Monster-side threat telegraphs: poison, slow, chill, and isolation danger now
  appear as compact badges beside threatening enemies before hits land, so the
  player can read biome combat pressure without first taking the status.
- Monster attack phases now have explicit sprite-protocol animation overlays:
  a pulsing warning mark during wind-up and a strike slash during lunge, so all
  32 monster species read as actively attacking rather than only sliding.
- Mixed-role party focus now turns recent tank/DPS/healer attacks on the same
  mob into a visible `FOC` damage window, giving parties a reason to coordinate
  targets beyond each role's individual `B` power.
- Final-gate completion now requires boss defeat, relic progress, and forward
  camp progress, turning the end of the run into a visible expedition chain
  instead of a single late fight.
- Konrad bot updates for world size, viewport parsing, and new sprite labels.
- Konrad bot objective targeting now reads visible Party Progressor landmarks
  semantically: resources and lairs are attack targets, camps/relics/rescues/
  waystations are activation targets, and distant boss-class threats are
  deprioritized behind expedition progress.
- Konrad bot adapters now read visible self health bars and status badges, then
  pivot toward hearts, food, camps, waystations, and regroup/rescue affordances
  while avoiding discretionary combat when wounded or isolated.
- Konrad bot adapters now also treat visible teammate player sprites as regroup
  targets, so isolation pressure drives bots back toward the party instead of
  only toward generic safe landmarks.
- Konrad bot adapters now read carried-item and expedition-objective HUD labels,
  so missing wood/stone gathering overrides premature camp/relic pushes and
  carried resources bias bots toward useful camps instead of redundant harvests.
- Konrad bot startup now understands visible role-choice labels and rotates
  unnamed bots through tank, DPS, and healer preferences by slot or player id,
  while explicit bot names such as tank, dps, or healer override the fallback.
- Player observations now mark the controlled adventurer as the selected player,
  so sprite-player bots can identify themselves in crowded spawn and regroup
  scenes instead of steering a nearby teammate by mistake.
- Konrad's local runner path now accepts `--slot` and `--token` and honors
  `COGAMES_ENGINE_WS_URL`, keeping the sprite-player bot aligned with the
  Coworld tournament runner contract.
- Konrad bot pacing now treats the default unexplored path as a rightward
  expedition push, so distant visible monsters no longer pull bots into opening
  hunt loops before they gather resources, build camps, or advance the frontier;
  close threats still interrupt the push.
- Konrad stuck recovery is now target-aware: frontier push recovery keeps a
  rightward bias, role-choice recovery keeps moving toward the intended gear,
  and one-pixel movement no longer counts as fully stuck.
- Konrad bot combat now reads the B-power HUD line and fires role powers at
  sensible moments: tanks guard and DPS cleave once threats are in reach, while
  healers spend their pulse when the HUD reports low health.
- Konrad bot scanning now treats visible carried-item sprites as teammate state
  instead of world pickups, preventing longer expedition runs from derailing
  into loops around another player's held wood, food, stone, or gold.
- Completed non-camp objectives now leave the sprite observation after their
  payoff lands, so humans and bots do not keep trying to activate already-spent
  relic beacons, shrines, rescues, lairs, or waystations; completed camps remain
  visible as shelters and specialization points.
- Konrad bot targeting now distinguishes harvest landmarks from loose carried
  resource pickups, so players with full hands still harvest useful nodes but
  stop chasing dropped food, wood, stone, or gold they cannot collect.
- Expedition objective hints now surface missing wood and stone whenever global
  camp progress is blocked, even after the party has moved into a later biome;
  Konrad uses those deficits to leave unbuildable camps and resume gathering or
  pushing for resources.
- Konrad now treats a camp that fails to activate after a short close-range
  dwell as temporarily spent, which prevents neutral-input camp orbiting and
  gets the party back to resource search or frontier movement.
- Forward camp role gear now uses explicit role-labeled sprite protocol icons
  instead of masquerading as coin or heart pickups, and already-roled players
  must press select to swap at camp gear. Origin role choice remains walk-in
  simple for unarmed players, while late expedition paths no longer accidentally
  collapse tank/DPS/healer composition when bots cross camp gear.
- Completed camps now become semantically distinct `shelter` objects in the
  sprite protocol. Konrad treats shelters as recovery/regroup targets instead
  of generic camp objectives, so healthy bots push onward while incomplete camps
  remain visible build targets.
- Konrad now treats loose coins and hearts as opportunistic pickups instead of
  expedition objectives: healthy bots only detour for nearby forward loot, while
  low-health bots may still backtrack for heart recovery.
- Konrad push recovery now changes vertical lanes after repeated rightward
  stalls, so bots do not keep retrying the same blocked snow/cave route when an
  alternate lane can carry the expedition forward.
- Konrad now cross-checks `NEXT CAMP` hints against the HUD's shared wood and
  stone counters, so incomplete camps cannot trap bots when the party still
  needs another resource harvest.
- Konrad also treats a failed close-range camp dwell as a temporary resource
  search state, preferring visible wood/stone and suppressing the camp target
  long enough to break repeated camp-orbit loops.
- Konrad shelter recovery is now local and health-gated: wounded bots can use
  nearby shelters, but isolation/regroup pressure sends bots back toward
  teammates instead of letting old camps satisfy regroup on their own.
- Konrad forward-push goals now stay inside the expedition corridor, and bots
  that drift above or below the main lane recover back into that lane before
  resuming side fights, loot, and long-range push objectives.
- Konrad optional side-objective targeting now stays opportunistic unless the
  HUD names that objective as the current expedition step, so relic, shrine,
  rescue, lair, and waystation clusters do not stall the party's forward push.
- Konrad now tracks each bot's personal expedition frontier and filters stale
  loose resource drops, old incomplete camps, and non-immediate monster fights
  behind that frontier, reducing late-run collapses back into already-cleared
  biome bands after a forward push or camp respawn.
- Konrad now reads downed-player status badges from the sprite protocol and
  treats a downed teammate as a rescue target, with healers prioritizing the
  revive route most aggressively.
- Konrad's push-path unstuck now makes a pure vertical sidestep when a detour is
  active, so bots can slide around blocked right edges instead of pressing into
  them forever.
- Focused sim tests for biome/weather, movement modifiers, resources, camps,
  objectives, objective HUD hints, boss scoring, player viewport size, and
  biome-backed transparent sprites.
- Sprite protocol fixture tests that parse Party Progressor player packets with
  the same message framing used by existing BitWorld sprite-protocol bots.
- Rendered player-observation tests that composite sprite protocol packets and
  verify the 11 by 11 view stays opaque, biome-backed, and not black-filled
  across forest, plains, swamp, desert, snow, cave, and ruins.
- Those rendered observation checks now save biome-specific PNG previews under
  `out/party_progressor_observations/`, so viewport framing and black-background
  regressions are visible during manual review.

## Broader Roadmap

### Near-Term Implementation

- Tune the 11 by 11 viewport after real bot/human observation checks.
- Tune in-world affordance density after real observation checks so labels
  remain helpful without cluttering fights.
- Tune food, provisioned-camp, snow-exposure, and desert-heat pacing with
  multi-player runs.
- Use the saved player-observation previews during real human/bot checks to
  tune viewport framing and affordance density.
- Tune attack-overlay density and placement once longer human/bot observation
  checks reveal where lunge effects clutter tight fights.
- Continue bot targeting polish: tune longer-run expedition pacing now that
  bots understand roles, health, regroup, carried resources, and current
  objectives, prefer frontier pushes over distant discretionary fights, and
  recover from blocked push paths without backing out of the expedition.

### Expedition Depth

- Give each biome one tactical rule that changes party behavior.
- Tune the new biome waystation detours so their role hints, route changes, and
  biome-specific payoffs are visible but not mandatory.
- Extend camp infrastructure beyond healing, role swap, weather shelter,
  shortcut reveal, fortification, meal shelters, and role specializations: add
  biome-safe staging choices and tune which camp upgrades should be automatic
  versus explicit player choices.
- Continue teammate legibility beyond low-health help badges, isolation regroup
  labels, downed-player rescue, and chat pings: richer rescue/objective moments.
- Tune final-gate pacing now that relic, boss, and camp progress are all part of
  the visible completion chain.

### Polish And Packaging

- Tune sprite-protocol weather density and color after real play checks.
- Consider a generated Party Progressor atlas once the curated TribalCog asset
  set stabilizes.
- Add long-run smoke tests with multiple players and bots.
- Add a small protocol fixture test for `/player` sprite-player behavior.
- Keep manifests, docs, and runner contract references aligned with the
  canonical `/player` route.

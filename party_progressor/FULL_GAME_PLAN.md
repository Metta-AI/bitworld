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

The final boss should reuse that learned party language instead of introducing
a separate raid UI. The Gate Titan should take extra damage when the attacker
is holding a nearby tank/DPS/healer trio formation and additional extra damage
when all three combat roles are focus-firing it. That makes the late fight read
as a party-check boss while still using the same attack, role power, `TRIO`, and
`FOC` signals players have already learned.

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
Carried supplies should also have a direct expedition use: selecting at an
activated camp should let players turn wood, food, stone, or gold into a
specific camp upgrade instead of only dropping the item.
Gold should also have a field use in the deepest bands: carrying it through
caves and ruins acts as a portable light focus, trading an occupied hand for
temporary fog safety when the party cannot stay grouped.
Wood should have a field use in the swamp: carrying it through mud or shallow
water lets a player lay a short plank bridge, trading the item for a local route
repair instead of waiting for a full bridge waystation or camp shortcut.
Stone should have a field use on ridges: carrying it across steep elevation
lets a player cut a short set of steps, trading the item for a flatter local
route through snow, cave, ruin, or other high ground.
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

Beacon objectives should award relic shards and make the next push easier to
read. Completing a beacon should survey a short route forward, clear local
non-boss threats, and soften nearby rough or steep terrain so relic progress
feels like real expedition knowledge rather than only a counter. The final gate
should require relic progress, camp progress, boss defeat, and a short visible
party ritual before completion. The ritual should complete fastest when tank,
DPS, and healer all hold the gate together.

Rescue objectives should feel like finding people who know the land, not only
like picking up food. Completing a rescue should still heal and resupply the
party, but it should also reveal a short local trail through rough terrain so
detouring to help a stranded traveler can change the next push route.

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
Final-gate completion should be separately visible in result JSON and should
pay a distinct run-completion bonus, so finishing the expedition is more
valuable than only farming earlier milestones.

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
- Completed relic beacons now act as survey points: they still award relic
  shards, but also reveal a short forward route, clear nearby blockers and
  steep elevation, and pacify local non-boss threats around the beacon.
- Relic beacons now require a short visible attunement hold before completion:
  nearby teammates stack progress, DPS contributes extra, and the prompt shows
  live `RELIC` progress instead of treating core relics as instant pickups.
- Relic beacons now also grant a short visible `SURV` survey window: route
  knowledge floors rough/elevated terrain movement to a readable minimum, so
  beacon progress accelerates the next push instead of only improving one tile
  corridor.
- Optional shrine side objectives that trade route time for score, emergency
  food, healing, and status cleansing.
- Completed shrine side objectives now remain useful as small blessing
  sanctuaries: nearby players get local recovery, faster status cleanup, biome
  pressure sheltering, and a visible `BLESS` status in sprite observations.
- Optional rescue side objectives seeded through biome bands: stranded travelers
  require a short nearby hold, heal the party slightly, and add emergency food,
  with healers completing rescues faster.
- Completed rescue side objectives now also reveal a short local trail or
  bridge through nearby rough ground, clear blockers, and soften steep terrain,
  making rescues an expedition-routing payoff instead of only a food/heal
  reward.
- Rescue and waystation holds now stack nearby teammate effort up to a readable
  co-op cap while preserving role specialist bonuses, so grouping on an
  expedition objective completes it faster than solo channeling.
- Grouped objective completions now create a visible morale payoff: when at
  least two players finish a relic beacon, rescue, or waystation together, the
  party gets a short `MOR`/`MORALE` next-push window with faster role-power
  recovery and clean-terrain movement momentum.
- Rescue completions now also give the party a short visible `GUIDE` push:
  clean players move faster, status recovery accelerates slightly, and the
  next route decision reads as local knowledge from the rescued traveler.
- Optional monster lair side objectives seeded through biome bands: parties can
  spend attack time to destroy local dens for supplies, side-objective score,
  a short pacification of nearby threats, a biome-flavored cache of carried
  expedition supplies, and reduced future monster respawn pressure in that
  biome.
- Destroyed monster lairs now also give the party a short visible `HUNT`
  window: normal attacks hit non-boss monsters harder, so clearing a den
  creates an immediate next-fight advantage instead of only changing hidden
  respawn timing.
- Biome waystation side objectives seeded through biome bands: forage, rally,
  bridge, oasis, hearth, lantern, and ward detours complete faster for a hinted
  role, reshape nearby rough terrain into a readable route, and grant
  biome-specific survival payoffs.
- Completed waystations now also grant a short visible `ROUTE` momentum window:
  players can capitalize on the opened path with a rough-terrain movement floor
  and temporary protection from local biome pressure beyond the static shelter.
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
- Tank guard now doubles as a short formation shelter: while active it clears
  visible biome pressure and blocks snow cold, desert heat, cave/ruin fog, and
  swamp mire pulses for the tank and nearby party members, giving tanks a
  direct answer to harsh-weather pushes.
- Healer pulse now cleanses poison, slow, and chill from nearby party members,
  making the support power a direct answer to biome and monster status pressure
  rather than only an HP refill.
- Healer triage support: nearby healers now slowly stabilize low-health
  teammates between pulse casts, making the support role useful during
  sustained pushes.
- Downed rescue windows: defeated players now visibly wait for rescue before
  bleeding out to a camp respawn, giving nearby allies a direct recovery moment
  and preserving carried value when the rescue succeeds.
- Food auto-healing and snow exposure pressure that consumes food before
  damaging isolated players, while nearby allies can share warmth and avoid the
  cold pulse.
- Late-run exhaustion now turns food into a broader expedition pacing resource:
  snow, cave, and ruin travel consume shared or carried rations before applying
  a visible `EXH` slowdown, and carried food or healer pulse can clear the
  exhaustion status.
- Desert heat exposure now mirrors the snow survival loop: food or carried food
  absorbs a heat pulse before HP damage, while completed oasis waystations and
  camps shelter nearby players.
- Desert cactus shade now gives a local heat-safe staging choice, showing a
  compact shade affordance and giving bots a terrain target when heat pressure
  is visible.
- Swamp mire pressure now slows exposed players crossing mud, shallow water, or
  water, while completed bridge waystations and camps turn swamp crossings into
  safer routes.
- Carried wood now doubles as a swamp field tool: selecting while facing rough
  swamp ground lays a short plank bridge, clears blockers/elevation on that
  crossing, consumes the carried wood, and gives bots a `SEL PLANK` response to
  visible mire pressure.
- Carried stone now doubles as an elevation field tool: selecting while facing
  steep ground cuts short steps through the ridge, clears blockers, lowers local
  elevation, and gives bots a `SEL STEPS` response to visible route affordances.
- Cave and ruin fog now disorients isolated unsheltered players with slow
  pressure, while nearby allies, completed lantern/ward waystations, and camps
  keep the party oriented.
- Cave and ruin expeditions now have a portable light choice: a player carrying
  gold clears their own fog pressure and shows a visible `LIT`/`LIGHT`
  affordance, creating a hand-occupying alternative to grouping or static
  shelters.
- Early biome tactics now teach sustain and grouping before and during harsh
  survival bands: forest travel slowly rebuilds a small shared food reserve,
  plains players grouped near allies recharge role powers faster, desert
  players near cactus shade can pause heat attrition, snow players grouped near
  allies get a visible warmth affordance that clears cold pressure, and
  cave/ruin players carrying gold get a visible light affordance that clears
  local fog pressure.
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
- Meal shelters now hand out visible expedition rations: nearby players get a
  timed `MEAL`/`RATION SAFE` state that buffers the next cold, heat, or
  late-run exhaustion pulse without spending shared food or a carried ration.
- Activated camps now support role-linked specializations: tank ward camps hold
  a safer perimeter, DPS rally camps recover role powers faster, and healer aid
  camps cleanse status pressure faster while regrouping.
- Snow hearth waystations become local cold shelters after completion, giving
  snow expeditions a second kind of safe staging choice beyond full camps.
- One-item expedition carrying for harvested wood, food, stone, and gold,
  including visible held-item sprites and select-to-use/drop behavior.
- Carried food is now a direct sustain item: the HUD advertises `SEL EAT`
  when eating will heal or cleanse poison/slow/chill, and eating held food no
  longer drains shared party food stores.
- Carried food can also be fed to a nearby wounded or status-afflicted
  teammate with `SEL FEED`, letting any role turn one held ration into a local
  rescue/sustain choice without adding inventory management.
- Carried camp delivery: selecting at activated camps now turns wood into
  rally staging, food into meal shelters, stone into warded shelters, and gold
  into fortification, so carried supplies create explicit staging choices.
- Deterministic tile elevation with movement slowdown and sprite-map shading.
- Elevation now affects combat as well as travel: attacks from meaningfully
  higher ground hit harder, uphill attacks hit softer, and mobs show `HIGH` or
  `LOW` badges relative to the selected player.
- Biome-specific monster families: scorpions, slimes, yetis, bats, and wraiths
  join wolves, goblins, bears, and the boss.
- A 32-species monster roster generated from the core creature silhouettes:
  each biome now seeds multiple named local species so forest, swamp, desert,
  snow, cave, and ruins read like distinct dungeon ecology instead of palette
  swaps of the same few enemies.
- Biome monster tactical hooks: slimes slow players, desert creatures poison,
  snow threats chill, bats harass from farther away, and wraith/gate enemies
  punish isolated players so grouping has real value.
- Defeated biome monsters now leave expedition supplies that match their
  ecology: wildlife and cold/desert threats can become emergency food, swamp
  goblins and reed threats can leave wood, cave/ruin brutes can leave stone,
  and crystal/wraith threats can leave gold for deep-band lighting. Combat now
  feeds the one-item carry economy instead of only producing coins.
- Dynamic sprite-protocol weather overlays: rain, dust, snow, and fog now show
  as translucent deterministic particles in both player and global map views,
  not only in the legacy framebuffer path.
- In-world player affordances for the larger observation window: poison, slow,
  chill, isolation danger, low-health help state, and downed rescue state now
  appear as compact badges next to players, and landmarks show readable labels
  for resources, camp costs, relic beacons, and final-gate requirements, with
  activated camps relabeled as shelters.
- Environmental survival pressure is now readable before damage lands: exposed
  swamp, snow, desert, cave, and ruin players get `MIRE`, `COLD`, `HEAT`, or
  `FOG` badges plus HUD status text, while nearby allies and completed shelters
  clear the warning where appropriate.
- Objective hold affordances now show live progress for rescue events,
  waystations, lairs, and the final-gate ritual, so the larger observation
  window communicates when party pressure is actually advancing a task.
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
- Mixed-role formation now matters between fights as well: when tank, DPS, and
  healer stay grouped in a local formation, players show a visible `TRIO`
  affordance and recover role-power cooldowns faster, making the intended party
  composition useful during travel, staging, and weather pressure.
- The Gate Titan now uses that same party language as a final-boss raid window:
  normal attacks and DPS cleave hit the boss harder when the attacker is in a
  tank/DPS/healer trio, and harder again when all three roles have recently
  focused the boss, turning the late fight into a composition check without new
  controls.
- Full tank/DPS/healer focus now also staggers the Gate Titan: coordinated hits
  interrupt its current attack phase, add a visible `STAG` badge, and buy the
  party a short survival window before the next boss swing.
- Final-gate completion now requires boss defeat, relic progress, and forward
  camp progress, turning the end of the run into a visible expedition chain
  instead of a single late fight.
- Final-gate activation now has a visible hold ritual after those requirements
  are met, and the ritual accelerates when distinct tank/DPS/healer roles are
  grouped on the gate.
- Completing the final gate now adds an explicit run-completion score bonus and
  appears as `final_gate_completed` in result JSON, making the expedition finish
  visible to scoring, analysis, and tournament result inspection.
- Completing the final gate now also grants a visible party triumph: nearby
  remaining non-boss threats are cleared, players are healed and cleansed, the
  HUD shows `TRIUMPH SAFE`, and a compact `WIN` badge marks the expedition
  finish instead of leaving completion as only a score bit.
- Konrad bot updates for world size, viewport parsing, and new sprite labels.
- Konrad bot objective targeting now reads visible Party Progressor landmarks
  semantically: resources and lairs are attack targets, camps/relics/rescues/
  waystations are activation targets, and distant boss-class threats are
  deprioritized behind expedition progress.
- Konrad bot adapters now read visible self health bars and status badges, then
  pivot toward hearts, food, camps, waystations, and regroup/rescue affordances
  while avoiding discretionary combat when wounded or isolated.
- Konrad bot adapters now also read `MIRE`, `COLD`, `HEAT`, and `FOG` survival
  badges, biasing exposed players toward the right answer for the pressure:
  bridge waystations and shelters for mire, food, shelter, or shared warmth for
  cold, food or shelter for heat, and regrouping, lantern/ward shelter, or
  carried-gold light for fog.
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
  healers spend their pulse when the HUD reports low health or cleansable
  poison/slow/chill pressure.
- Konrad tanks now also fire guard under environmental pressure, so cold, heat,
  mire, fog, and regroup warnings can turn into a visible party-protection
  window instead of only a movement detour.
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
- Konrad camp-building objectives, close camp stalls, and fallback searches now
  treat loose carried-supply drops as staging items, not shared build
  resources, so a blocked camp pushes bots back toward actual wood/stone/gold
  landmarks instead of orbiting floor drops near the construction site.
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
- Konrad now ignores chat bubbles that happen to contain resource words, so
  teammate target/status chatter like `wood` or `food` cannot masquerade as a
  collectible pickup.
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
- Konrad recovery pacing now treats completed shelters, shade stops, and loose
  carried-supply drops as bounded local affordances: after a short close-range
  dwell on a non-resolving stop, the bot temporarily releases that target and
  resumes the expedition push or nearby objective chain instead of ending a
  long run in a shelter or floor-drop orbit.
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
- Tune food, meal-ration duration, snow-exposure, and desert-heat pacing with
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
  labels, downed-player rescue, chat pings, and grouped objective morale:
  richer rescue/objective moments.
- Tune final-boss and final-gate pacing now that relic, camp, trio formation,
  three-role focus, boss stagger, boss defeat, the gate ritual, and the triumph
  payoff are all part of the visible completion chain.

### Polish And Packaging

- Tune sprite-protocol weather density and color after real play checks.
- Consider a generated Party Progressor atlas once the curated TribalCog asset
  set stabilizes.
- Add long-run smoke tests with multiple players and bots.
- Add a small protocol fixture test for `/player` sprite-player behavior.
- Keep manifests, docs, and runner contract references aligned with the
  canonical `/player` route.

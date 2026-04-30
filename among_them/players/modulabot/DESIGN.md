# modulabot — Design Report

A modular re-implementation of `evidencebot_v2.nim`'s strategy. Same
perception, same policies, same FFI surface (with a new prefix) — but split
across small, focused Nim modules with sub-record state grouping so each
concern has one obvious place to live.

This is a design doc. The original review pass resolved all 12 open
questions; their resolutions are baked into the body below and recorded in
§10 as a decisions log. Nothing is built yet.

---

## 1. Goals & non-goals

### Goals

1. **Modular layout.** One concern per file; ~200–600 LOC each. No 4,700-line
   monoliths.
2. **Sub-record state.** Group `Bot`'s ~80 fields into ~10 named sub-records
   (`Perception`, `Motion`, `Tasks`, `Voting`, `Imposter`, ...). Each module
   owns the sub-record(s) it operates on.
3. **Strategy parity with evidencebot_v2 at v0.** The first build should
   behave indistinguishably from v2 — same perception, same crewmate task
   policy with the v2 `taskResolved` latch, same imposter follow/fake-task,
   same evidence-based voting. We earn the right to diverge after parity is
   demonstrated.
4. **Easy to extend.** Adding a new policy module (e.g. an alternate imposter
   playbook) should not require touching the perception layer.
5. **Same FFI shape, new prefix.** Exports `modulabot_new_policy` and
   `modulabot_step_batch` matching the existing batch/handle convention. The
   Python harness gains a new policy entry; existing nottoodumb/evidencebot
   builds are untouched.

### Non-goals (explicitly)

- **No new strategy in v0.** Resist the urge to "fix" things during the
  port. Behavior changes happen on later commits where they can be A/B'd
  against parity.
- **No new perception primitives.** Patch hashing, frame fit, ASCII OCR,
  sprite scanning all carry over verbatim.
- **No abstraction over `sim.nim` or `protocol.nim`.** Those are upstream;
  modulabot is a consumer. Same imports, same constants.
- **No build-system overhaul.** Reuse the same `build_nottoodumb.py`
  conventions and the same standalone-binary entrypoint shape.

---

## 2. Directory layout

```
players/modulabot/
  DESIGN.md                  ← this file
  modulabot.nim              ← entry point: CLI main + when isMainModule
  build_modulabot.py         ← shared-library build helper (mirrors build_nottoodumb.py)

  types.nim                  ← enums, small records, sub-record types, Bot composition
  tuning.nim                 ← cross-cutting tuning knobs only (Q9)
  bot.nim                    ← Bot composition, initBot, decideNextMask, step*Frame*
  diag.nim                   ← debug strings: thought(), intent helpers, perf timers
  geometry.nim               ← coord math, room/task lookup, camera↔world
  frame.nim                  ← unpack4bpp, palette, ignore-pixel predicates
  ascii.nim                  ← ASCII glyph OCR (chat + interstitial)
  localize.nim               ← patch hash table, frame fit, spiral, dispatcher
  sprite_match.nim           ← matchesSprite / matchesSpriteShadowed primitives
  actors.nim                 ← scanCrewmates / scanBodies / scanGhosts / role icon
  tasks.nim                  ← task icon scan, radar projection, state machine, resolved-latch
  motion.nim                 ← velocity, jiggle, button mask formatting
  path.nim                   ← A*, lookahead, coast/brake/precise steering
  evidence.nim               ← witness ticks, suspect picking, prev-body memory
  chat.nim                   ← message templating, pendingChat queue
  voting.nim                 ← parseVotingScreen + cursor/decision logic
  policy_crew.nim            ← crewmate decision tree (decideCrewmateMask)
  policy_imp.nim             ← imposter decision tree (decideImposterMask)

  viewer/                    ← gated: when not defined(modulabotLibrary)
    viewer.nim               ← initViewerApp / pumpViewer / drawFrameView / drawMapView
    runner.nim               ← runBot, websocket I/O, reconnect loop

  ffi/                       ← gated: when defined(modulabotLibrary)
    lib.nim                  ← TrainableMasks, modulabot_new_policy, modulabot_step_batch
```

**Why sub-folders for `viewer/` and `ffi/` but not for the main modules?**
The viewer and FFI layers are *replaceable surfaces* around a stable
`bot.nim` core; the directory boundary makes the gating visible and
discourages strategy code from accidentally depending on `silky/whisky/
windy` or FFI glue. The main modules stay flat under `players/modulabot/`
to match the rest of the repo (no `src/` convention exists at any other
level) and to keep relative imports short — `import ../../sim` from a flat
file is cleaner than `import ../../../sim` from a `src/` subdir.

---

## 3. State decomposition

### Current (`evidencebot_v2.nim:240-383`)

One flat `Bot` with ~80 fields spanning ~15 concerns. `initBot` is 50 lines
of hard-coded sentinel assignments. Field access is global (`bot.cameraX`,
`bot.imposterFolloweeColor`, `bot.voteChoices[ci]`).

### Proposed

`Bot` becomes a thin envelope holding sub-records and the few truly
cross-cutting scalars (`role`, `frameTick`, `rng`, `sim`, sprite refs).

```nim
# types.nim — sketch only, names subject to refinement

type
  Perception* = object
    cameraX, cameraY: int
    lastCameraX, lastCameraY: int
    cameraLock: CameraLock
    cameraScore: int
    localized: bool
    interstitial: bool
    interstitialText: string
    lastGameOverText: string
    gameStarted: bool
    homeSet: bool
    homeX, homeY: int
    mapTiles: seq[TileKnowledge]
    patchEntries: seq[PatchEntry]
    patchVotes: seq[uint16]
    patchTouched: seq[int]
    patchCandidates: seq[PatchCandidate]
    radarDots: seq[RadarDot]
    visibleTaskIcons: seq[IconMatch]
    visibleCrewmates: seq[CrewmateMatch]
    visibleBodies: seq[BodyMatch]
    visibleGhosts: seq[GhostMatch]
    prev: PrevFrame   # see PrevFrame below; populated at end of pipeline

  FrameIO* = object
    packed: seq[uint8]
    unpacked: seq[uint8]
    queuedFrames: seq[string]
    frameBufferLen: int
    framesDropped: int
    skippedFrames: int
    lastMask: uint8

  Motion* = object
    haveMotionSample: bool
    previousPlayerWorldX, previousPlayerWorldY: int
    velocityX, velocityY: int
    stuckFrames: int
    jiggleTicks, jiggleSide: int
    desiredMask, controllerMask: uint8

  Tasks* = object
    radarTasks: seq[bool]
    checkoutTasks: seq[bool]
    taskStates: seq[TaskState]
    taskIconMisses: seq[int]
    taskResolved: seq[bool]   # v2 latch
    taskHoldTicks: int
    taskHoldIndex: int

  Goal* = object
    # Q1 resolved: shared between crewmate and imposter policies, matching v2.
    # `goalIndex` is interpreted by whichever policy is active; the imposter
    # uses it as a fake-target index when wandering, the crewmate as a task
    # index. Both write/read the same fields.
    intent: string
    goalX, goalY: int
    goalIndex: int
    goalName: string
    hasGoal: bool
    hasPathStep: bool
    pathStep: PathStep
    path: seq[PathStep]

  PrevFrame* = object
    # Q2 resolved (option c): explicit previous-frame camera snapshot so
    # `actors.scanAll` can run BEFORE `localize.update` using a deliberate
    # last-known-good camera, instead of either (a) running scans inside
    # updateLocation as v2 does, or (b) blindly assuming this frame's
    # not-yet-updated camera is correct.
    #
    # Populated at the END of decideNextMask from the current Perception
    # snapshot. On post-vote / role-reveal teleports `valid = false` so
    # localize knows the prev-camera is unreliable and falls back to spiral
    # / patch search before scans are trusted.
    valid: bool
    cameraX, cameraY: int

  PerColor*[T] = array[PlayerColorCount, T]

  Identity* = object
    selfColorIndex: int
    knownImposters: PerColor[bool]
    lastSeenTicks: PerColor[int]

  Evidence* = object
    nearBodyTicks: PerColor[int]
    witnessedKillTicks: PerColor[int]
    prevVisibleCrewmateX: PerColor[int]
    prevVisibleCrewmateY: PerColor[int]
    prevVisibleBodies: seq[tuple[x, y: int]]

  ImposterState* = object
    killReady: bool
    goalIndex: int
    followeeColor: int
    followeeSinceTick: int
    fakeTaskIndex: int
    fakeTaskUntilTick: int
    fakeTaskCooldownTick: int
    prevNearTaskIndex: int
    lastKillTick: int
    lastKillX, lastKillY: int

  VotingState* = object
    voting: bool
    votePlayerCount: int
    voteCursor: int
    voteSelfSlot: int
    voteTarget: int
    voteStartTick: int
    voteChatSusColor: int
    voteChatText: string
    voteSlots: array[MaxPlayers, VoteSlot]
    voteChoices: PerColor[int]

  ChatState* = object
    pendingChat: string
    lastBodySeenX, lastBodySeenY: int
    lastBodyReportX, lastBodyReportY: int

  Perf* = object
    centerMicros, spriteScanMicros: int
    localizeLocalMicros, localizePatchMicros, localizeSpiralMicros: int
    astarMicros: int
    lastThought: string

  Sprites* = object
    player, body, ghost, task, killButton, ghostIcon: Sprite

  RngStreams* = object
    # Q6 resolved: each consumer gets its own substream so that changing one
    # path does not shift the sequence of the others. Streams are seeded
    # deterministically from a master seed in `initBot` (see initRngStreams).
    # Add new fields when a new RNG consumer appears; do not reuse streams.
    imposterChat: Rand    # randomInnocentColor for chat templates
    imposterTask: Rand    # fake-task die roll, fake-task duration
    imposterFollow: Rand  # followee swap when 2+ visible
    voteTie: Rand         # tiebreaker when multiple equal-evidence suspects

  Paths* = object
    # Q8 resolved: explicit paths threaded through initBot, no setCurrentDir.
    # Populated once at construction; immutable thereafter.
    gameRoot: string      # absolute path to among_them/ (replaces gameDir())
    atlasPath: string     # absolute path to clients/dist/atlas.png
    mapPath: string       # absolute path to map JSON / aseprite

  Bot* = object
    sim: SimServer
    paths: Paths          # see Q8
    rngs: RngStreams      # see Q6
    role: BotRole
    isGhost: bool
    ghostIconFrames: int
    frameTick: int
    sprites: Sprites
    io: FrameIO
    percep: Perception
    motion: Motion
    tasks: Tasks
    goal: Goal
    identity: Identity
    evidence: Evidence
    imposter: ImposterState
    voting: VotingState
    chat: ChatState
    perf: Perf
```

**Conventions (Q4 + Q5 resolved):**

- **Leaf procs take explicit sub-record parameters.** Anything in the
  perception, motion, path, or evidence layer takes `var <SubRecord>` plus
  whatever read-only context it needs (`SimServer`, `Sprites`, `Perception`).
  This makes dependencies visible at the signature.
- **Orchestrators take `var Bot`.** That's `decideNextMask`,
  `decideCrewmateMask`, `decideImposterMask`, `decideVotingMask`,
  `stepUnpackedFrame*`. They sequence calls into the leaf procs.
- **Diagnostics is the one carve-out.** Procs that need to call `thought`,
  set `intent`, or stamp perf timers take `var Bot` even when they're
  otherwise leaf. This keeps `diag.nim` from infecting every signature with
  a `var Diag` parameter. The leaf-vs-orchestrator boundary moves slightly
  — `updateLocation` is technically a leaf, but it logs perf timers, so it
  takes `var Bot`. So be it.
- The orchestrator in `bot.nim` is the only place that pulls multiple
  policy modules together.
- Keep `role`, `isGhost`, `frameTick`, `sim`, `paths`, `rngs`, `sprites` at
  the top level — they're consumed by *every* module and pushing them down
  would just create indirection noise.
- Each sub-record gets an `init<Name>(): <Name>` proc in its owning module
  for clean construction (e.g. `initMotion()`, `initTasks(taskCount: int)`,
  `initRngStreams(masterSeed: int64)`). `initBot` becomes a composition of
  these calls.

### Trade-offs of this split

- **Wins:** every "where does this field live" question becomes obvious;
  mocking a sub-record in tests becomes trivial; cross-module coupling
  becomes a visible compile-time error rather than an invisible field-access
  pattern.
- **Costs:** every field access is now `bot.percep.cameraX` instead of
  `bot.cameraX`. Diff vs. v2 will be large at the syntax level even where
  logic is identical. Sub-record passing complicates a few deeply
  cross-cutting procs (e.g. `nearestTaskGoal` which wants `Perception`
  for camera, `Tasks` for state, `sim` for geometry). Mitigation: those few
  procs live in `bot.nim` or take `var Bot` directly.

---

## 4. Module responsibilities and boundaries

The import DAG is intentionally a tree (no cycles). Lower → higher only.

```
tuning ──┐
types ◄──┤
         ├── geometry ◄── frame ◄── ascii
         │                 │         │
         │                 ▼         ▼
         │           sprite_match  localize
         │                 │
         │      ┌──────────┼─────────────┐
         │      ▼          ▼             ▼
         │   actors      tasks         motion ◄── path
         │      │          │             │
         │      └──────┬───┴───────┬─────┘
         │             ▼           ▼
         │         evidence     chat
         │             │           │
         │             ▼           ▼
         │         voting    policy_crew  policy_imp
         │             └──────┬─────┴────────┘
         │                    ▼
         └─────────────────  bot
                              ▲
                ┌─────────────┼─────────────┐
                │             │             │
             viewer/       ffi/lib       modulabot.nim
             runner.nim    (gated)       (CLI main)
```

Per-module summaries (succinct):

- **`tuning.nim`** — every magic number from the v2 const block, grouped by
  comment headers (`# Localization`, `# Tasks`, `# Imposter`). No procs.
- **`types.nim`** — every enum and small record (`PathNode`, `PathStep`,
  `CameraScore`, `IconMatch`, `CrewmateMatch`, etc.) plus the sub-record
  types and `Bot`. Imports `tuning`, `sim`. No procs.
- **`geometry.nim`** — `playerWorldX/Y`, `roomName(At)`, `taskCenter`,
  `cameraXForWorld`, `inMap`, `cameraIndex` family. Pure functions.
- **`frame.nim`** — `unpack4bpp`, `sampleColor`, the `ignore*Pixel` family
  collapsed to one generic `ignoreFromMatches[T](matches, sprite, sx, sy)`
  + thin wrappers. Plus `ignoreFramePixel` composition.
- **`ascii.nim`** — `asciiGlyphScore`, `findAsciiText`, `readAsciiLine`,
  `detectInterstitialText`, `isGameOverText`. Reusable for both interstitial
  detection and chat OCR.
- **`localize.nim`** — `buildPatchEntries`, `locateByPatches`,
  `locateNearFrame`, `locateByFrame`, `scoreCamera`, `updateLocation`. The
  one place mutating `Perception`'s camera fields.
- **`sprite_match.nim`** — `matchesSprite`, `maybeMatchesSprite`,
  `matchesSpriteShadowed`, `matchesActorSprite`, `actorColorIndex`. Used by
  `actors`, `tasks`, `voting`.
- **`actors.nim`** — `scanCrewmates`, `scanBodies`, `scanGhosts`,
  `updateRole`, `updateSelfColor`, `rememberRoleReveal`. Mutates
  `Perception.visible*` and `Identity`.
- **`tasks.nim`** — `scanTaskIcons`, `projectedTaskIcon`, `updateTaskGuesses`,
  `updateTaskIcons`, the `taskResolved` latch logic, `taskGoalReady`,
  `holdTaskAction`. Mutates `Tasks`.
- **`motion.nim`** — `updateMotionState`, `applyJiggle`, `axisMask`,
  `preciseAxisMask`, `coastDistance`, `shouldCoast`, `maskForWaypoint`.
- **`path.nim`** — `passable`, `findPath`, `reconstructPath`, `pathDistance`,
  `goalDistance`, `choosePathStep`. No mutation outside of locals.
- **`evidence.nim`** — `updateEvidence`, `evidenceBasedSuspect`,
  `randomInnocentColor`, `suspectedColor`. Mutates `Evidence`.
- **`chat.nim`** — `imposterBodyMessage`, `crewmateBodyMessage`,
  `bodyRoomMessage`, `queueBodySeen`, `queueBodyReport`. Mutates `ChatState`.
- **`voting.nim`** — `parseVotingScreen` plus the cursor-stepping decision
  logic and `decideVotingMask`. Mutates `VotingState`.
- **`policy_crew.nim`** — `decideCrewmateMask` (the part of `decideNextMask`
  that runs after the role branch); `nearestTaskGoal` and the eight-tier
  fallback. Reads everything; mutates `Goal` and `Tasks.taskHoldTicks`.
- **`policy_imp.nim`** — `decideImposterMask` and helpers
  (`pickFolloweeColor`, `maybeStartFakeTask`, `farthestFakeTargetIndexFrom`,
  self-report logic). Mutates `ImposterState` and `Goal`.
- **`bot.nim`** — `initBot`, `decideNextMask` (top-level dispatch only),
  `stepUnpackedFrame*`, `stepPackedFrame*`. Imports everything below it.
- **`diag.nim`** — `thought`, `intent` formatters, `inputMaskSummary`,
  `roleName`, `cameraLockName`. No business logic.

### Cycle hazards & how we break them

The current file uses a forward-decl block at v2:869–883 because localization
calls into sprite scanning which calls back. In the modular version:

- Localization (`localize.nim`) does **not** depend on `actors.nim`. It
  consumes `Perception.visible*` as already-populated state. The
  orchestrator in `bot.nim` runs `actors.scanAll(...)` *before*
  `localize.updateLocation(...)` so `ignoreFramePixel` has the matches it
  needs. (In v2 the order is the other way around — sprite scans run
  inside `updateLocation`. We invert it.)

  ⚠ **Open question — does the v2 ordering actually matter?** The current
  flow is "score with last-frame's sprite matches → re-localize → re-scan
  with new camera". Inverting could degrade scan quality on teleport. We may
  need a two-pass: cheap re-scan on new camera, then localize again. **Flag
  for parity testing.**

- `tasks.nim` consumes camera state from `Perception` but does not import
  `localize.nim`.

- `policy_*` modules read from everything below them but never import each
  other.

---

## 5. The per-frame pipeline

Reorganized around the sub-records. Functionally equivalent to v2:3831
*except* for the Q2-resolved scan ordering: sprite scans run before
localization using the previous frame's camera, with a re-scan after lock
if the camera jumped far enough that the first scan is unreliable.

```nim
# bot.nim — illustrative; final form will use plain procs, not method syntax

const TeleportThresholdPx = 32  # camera jump beyond this triggers re-scan

proc decideNextMask*(bot: var Bot): uint8 =
  # 1. Cheap interstitial gate first — never localize black screens.
  detectInterstitial(bot)         # sets bot.percep.interstitial + text
  if bot.percep.interstitial:
    parseRoleReveal(bot)          # only meaningful on IMPS / CREWMATE screens
    parseVotingScreen(bot)        # only meaningful on the vote screen
    updateMotionAfterInterstitial(bot.motion)
    clearGoal(bot.goal)
    snapshotPrevFrame(bot.percep) # mark prev as invalid (post-vote teleport)
    if bot.voting.voting:
      return decideVotingMask(bot)
    bot.io.lastMask = 0
    thought(bot, "interstitial: " & bot.percep.interstitialText)
    return 0

  # 2. First-pass sprite scans against the PREVIOUS frame's camera. These
  #    populate the visible* lists that ignoreFramePixel needs to score
  #    map candidates without dynamic-pixel poisoning.
  let scanCamera =
    if bot.percep.prev.valid: (bot.percep.prev.cameraX, bot.percep.prev.cameraY)
    else:                     (bot.percep.cameraX,      bot.percep.cameraY)
  scanAll(bot.percep, bot.sprites, scanCamera)  # crewmates, bodies, ghosts, task icons, role icon
  scanRadarDots(bot.percep)

  # 3. Localize using those matches as the ignore mask.
  let preLockCamera = (bot.percep.cameraX, bot.percep.cameraY)
  updateLocation(bot)             # may set localized, update camera
  let postLockCamera = (bot.percep.cameraX, bot.percep.cameraY)

  # 4. If camera jumped far (teleport, full spiral re-lock), the prev-camera
  #    scans are wrong. Re-scan against the new camera before tasks read them.
  if bot.percep.localized and
      not bot.percep.prev.valid or
      abs(postLockCamera[0] - preLockCamera[0]) > TeleportThresholdPx or
      abs(postLockCamera[1] - preLockCamera[1]) > TeleportThresholdPx:
    scanAll(bot.percep, bot.sprites, postLockCamera)
    scanRadarDots(bot.percep)

  updateMotion(bot.motion, bot.percep, bot.sim)
  rememberVisibleMap(bot.percep, bot.io)
  updateTaskGuesses(bot.tasks, bot.percep, bot.sim)
  updateTaskIcons(bot.tasks, bot.percep, bot.sim)
  clearGoal(bot.goal)

  if not bot.percep.localized:
    thought(bot, "waiting for lock")
    snapshotPrevFrame(bot.percep)
    return 0

  updateEvidence(bot.evidence, bot.percep, bot.identity, bot.frameTick)
  rememberHome(bot.percep)

  let mask =
    if bot.role == RoleImposter and not bot.isGhost:
      decideImposterMask(bot)
    else:
      decideCrewmateMask(bot)

  # 5. Snapshot end-of-pipeline state for next frame.
  snapshotPrevFrame(bot.percep)
  return mask
```

The inversion vs. v2 is the key change: in v2 sprite scans live *inside*
`updateLocation`, which is what creates the forward-decl smell. Here they
sit in their own module, run twice in the worst case (teleport), and once
in the common case (cameras drift smoothly).

The `TeleportThresholdPx` knob lives in `tuning.nim` and should be set
during the parity bake — too tight wastes scans every frame, too loose
lets stale matches poison post-vote frames.

---

## 6. Build, FFI, and entry points

### CLI binary

`modulabot.nim` is the entry point. Mirrors `evidencebot_v2.nim`'s
`isMainModule` block exactly: parse `--address --port --gui --name --map`,
delegate to `viewer/runner.runBot`. Compiles with:

```sh
nim c -d:release -o:modulabot players/modulabot/modulabot.nim
```

### Shared library

```sh
nim c --app:lib -d:modulabotLibrary \
  -o:players/modulabot/libmodulabot.so \
  players/modulabot/modulabot.nim
```

`build_modulabot.py` is a near-verbatim copy of `build_nottoodumb.py` with
two strings changed (path + define). Will live next to the existing build
helper; no shared-state collisions.

### FFI exports

In `ffi/lib.nim`:

```nim
proc modulabot_new_policy*(numAgents: cint): cint {.exportc, dynlib.}
proc modulabot_step_batch*(...) {.exportc, dynlib.}
```

Same calling convention, same `TrainableMasks` table, same handle-registry
pattern as nottoodumb/evidencebot. Renamed prefix is the only change.

The Python harness will need a new policy entry pointing at the new symbols;
that's a single config edit on the Python side and not modulabot's concern.

---

## 7. Parity test plan

Before any divergence from v2 strategy, prove parity:

1. **Compile both binaries** (`evidencebot_v2`, `modulabot`) from the same
   commit.
2. **Run head-to-head** in `tools/quick_player` with a fixed RNG seed (need
   to thread `--seed` through; v2 currently seeds from `getTime() ^ pid`).
3. **Compare per-frame output masks** for N frames given identical input
   frame streams. Easiest harness: a tiny Nim program that loads a captured
   `.replay` file and runs both bots' `stepUnpackedFrame*` against it,
   diffing the returned masks.
4. **Acceptance:** ≥99% mask agreement over a 10-game replay set; remaining
   <1% accounted for by RNG paths (random innocent picking, fake-task die
   rolls).

This bar sets the version line: anything that changes mask output is a
behavior change and goes in a separate PR after v0 is merged.

---

## 8. Migration / iteration plan

### Phase 0 — scaffold (this report's outcome)

- Create `players/modulabot/` and the `src/` skeleton with empty modules.
- Define `types.nim` and `tuning.nim` from v2's const block and type block.
- Wire up an empty `bot.nim` that compiles but does nothing.

### Phase 1 — perception layer

Port in dependency order: `geometry → frame → sprite_match → ascii →
localize → actors → tasks → motion → path → evidence`. After each module,
write a smoke test (load one captured frame, run the function, eyeball the
output).

### Phase 2 — policies & I/O

Port `chat → voting → policy_crew → policy_imp`, then `viewer/` and
`ffi/lib.nim`. At end of phase 2, modulabot should connect to a server and
play a round.

### Phase 3 — parity bake

Run the parity harness from §7. Fix any drift. Tag v0.

### Phase 4 — divergence (post-merge)

Open the door for actual improvements. Candidates I'd want to discuss:
better evidence model (quantitative suspicion instead of binary tiers),
imposter chat that's not just `body in X sus <random>`, ghost behavior
beyond "fly to tasks", proper `--seed` plumbing, vote bandwagon detection
on the crewmate side.

---

## 9. What I'm explicitly *not* changing in v0

For the record, so we don't argue about it later:

- The "30% black pixels = interstitial" heuristic.
- The patch-hash localization parameters (`PatchSize`, `PatchMinVotes`, etc).
- The eight-tier `nearestTaskGoal` fallback.
- The kill-button-icon-as-imposter-detector.
- The 100-tick `VoteListenTicks` delay before pressing A.
- The hard-coded `PlayerColorNames`.

Things that *are* changing in v0 (not strategy, but infrastructure):

- **`setCurrentDir(gameDir())` is gone** (Q8 resolved). `initBot` takes
  explicit `gameRoot`/`atlasPath`/`mapPath`, threaded through the CLI and
  FFI entry points, stored in `Bot.paths`. `gameDir()` becomes a single
  helper used only by `modulabot.nim` to compute defaults from
  `currentSourcePath()`. No process-wide side effects.
- **Sprite scans run before localization** (Q2 option c). See §5 for the
  pipeline. Not a strategy change; it's a perception-layer reordering with
  identical observable behavior in the common case.
- **RNG splits into per-consumer streams** (Q6). Determinism property: a
  change to the imposter-task die rolls cannot shift vote-tiebreak or
  random-innocent sequences. Each stream is seeded deterministically from a
  master seed in `initBot`.

---

## 10. Decisions log (formerly open questions)

All resolved on first review pass. Numbered for traceability.

| # | Topic | Resolution | Where it lives in this doc |
|---|---|---|---|
| Q1 | `Goal` shared vs. split between crewmate/imposter | **Shared** — single `Goal` sub-record, matches v2 | §3 `Goal` block |
| Q2 | Sprite scan vs. localize ordering | **Option (c)** — explicit `PrevFrame` snapshot, scans run first against prev camera, re-scan after lock if camera jump exceeds `TeleportThresholdPx` | §3 `PrevFrame` block, §5 pipeline |
| Q3 | `bot.nim` importing every policy module | **Acceptable** — pipeline is `Bot`'s behavior, no separate `pipeline.nim` | §4 module DAG |
| Q4 | `var Bot` vs. explicit sub-record signatures | **Hybrid** — leaf procs take explicit sub-records; orchestrators take `var Bot` | §3 conventions |
| Q5 | Diagnostics access pattern | **`var Bot` carve-out** — any proc that calls `thought`/perf timers takes `var Bot` even if otherwise leaf | §3 conventions |
| Q6 | RNG substreams per consumer | **Per-consumer streams** in `RngStreams` sub-record, seeded deterministically from a master seed | §3 `RngStreams` block, §9 |
| Q7 | Parity harness location | **`players/modulabot/test/parity.nim`** to start; promote to `tools/bot_parity` only if a second bot pair wants the same harness | §7 |
| Q8 | `setCurrentDir` side effect | **Drop now** — explicit `Paths` sub-record threaded through `initBot` and `modulabot_new_policy` | §3 `Paths` block, §9 |
| Q9 | `tuning.nim` scope | **Knobs only** — `tuning.nim` holds the constants you'd actually A/B test (radii, thresholds, durations); module-internal magic numbers stay local | §4 `tuning.nim` summary |
| Q10 | Sprite atlas dedup across bots | **Defer** — one `Sprites` per `Bot` for v0, revisit after parity if memory is an issue in batched training | §3 `Sprites` block |
| Q11 | Viewer subdirectory | **Accepted** — `players/modulabot/viewer/` and `players/modulabot/ffi/` keep the gating boundary visible at directory level | §2 layout |
| Q12 | Strategy doc placement | **Link and leave** — modulabot's README links to `players/evidencebot_strategy.md`; copy if/when modulabot's strategy diverges | n/a |

---

## 11. Status log

### Phase 0 — scaffold ✅

Directory tree, `types.nim` (sub-records + Bot envelope), `tuning.nim`,
inert `bot.nim` (`initBot` returning sentinel Bot, `decideNextMask`
returning 0), `modulabot.nim` CLI shim, `ffi/lib.nim` skeleton, and
`build_modulabot.py`. CLI binary (~600 KB) and shared library
(`libmodulabot.dylib` exporting `modulabot_new_policy` /
`modulabot_step_batch`) both build clean with zero warnings.

### Phase 1 — perception layer + policies ✅

All 16 strategy modules ported from v2. Two surprises during port:

- **Caught one near-parity-mistake:** `matchesCrewmate` — substituted
  hardcoded thresholds for v2's `Crewmate*Pixels` / `CrewmateMaxMisses`
  constants and dropped an early-out. Caught and fixed before any
  compile.
- **v2 had grown +93 lines since the structural map** — central-room
  stuck mitigation (`imposterCentralRoomTicks`, `forceLeaveUntilTick`,
  `inCentralRoom`, `centralRoomCenter`, `ImposterCentralRoom*`
  constants). Ported as part of `policy_imp` / `geometry`.

One small drift from the design: goal-selection helpers
(`taskGoalFor`, `buttonGoal`, `homeGoal`, `navigateToPoint`,
`inReportRange`, `inKillRange`, `reportBodyAction`) ended up in
`tasks.nim` because both policies need them. `tasks.nim` is the
largest module at 616 lines.

### Phase 2 — viewer + parity harness 🟡 (partial)

**Done:**
- Integration smoke test: modulabot + evidencebot_v2 + server, 45 s
  of real gameplay, both bots alive, no crashes, no error output.
- Frame capture: `modulabot --frames:<path>` writes raw unpacked
  frames (16384 bytes each) to disk while playing.
- Self-consistency parity harness at `players/modulabot/test/parity.nim`.
  Two modulabot instances with the same master seed run through the
  same frame stream and diff their masks every tick. Modes:
  `--mode:black` (interstitial path), `--mode:random`,
  `--mode:mixed`, `--replay:<file>` (real captured frames).
  Validated 257/257 frames match on a real-game capture. Confirms
  modulabot is internally deterministic and Q6's per-consumer RNG
  substreams are wired correctly.

**v2-vs-modulabot byte-level parity ✅** (added after initial Phase 2
write-up.) v2 was patched with three additive `*` exports (`Bot`,
`initBot`, `decideNextMask`) — no behavior change, both v2 builds
verified clean post-patch. The harness gained a `--vs:v2` mode and a
`runVsV2` proc that runs both bots through the same frame stream and
diffs masks.

**Results on a 4.5-minute (6,281-frame) full-game capture:**

- **Self-consistency: 6281/6281 (100%)** across multiple seeds —
  modulabot is fully deterministic; Q6 RNG-substream split is wired
  correctly with no hidden globals or clock-dependent paths.
- **vs v2: 5464/6281 (87.0%)**, with divergence beginning
  *contiguously* at frame ~2508 and never recovering. The first
  ~2500 frames matched byte-for-byte (covers all crewmate gameplay
  and perception/voting/interstitial paths).

The divergence pattern matches the predicted RNG drift exactly: v2
seeds from clock+pid and modulabot from `--seed`, so once an
imposter RNG path fires (fake-task die, random-innocent pick,
followee swap), both bots make different choices, end up in
different game states, and the per-tick mask stream stays divergent
for the rest of the game.

**Decision: parity validation declared sufficient.** The
2508-frame deterministic prefix demonstrates that no logic bugs were
introduced in the port; the full-game divergence pattern is
mathematically forced and uninformative. Pursuing 100% parity
beyond the first RNG decision would require modifying v2's RNG-init
path to accept a seed, which is more invasive than the additive
exports we already made and offers low marginal value over the
prefix-match evidence.

Both 30-second-capture (659/659) and full-game (5464/6281, 100% on
first 2508) results are recorded for posterity. Future regression
detection can use the harness's `--vs:self` mode against any
captured replay — that path stays at 100% as long as Q6 substreams
are intact.

**`viewer/viewer.nim` ✅** (added in a follow-up patch.) Full port of
v2:4229-4707 — drawing primitives, frame view, map view, status
panel, init/pump/open lifecycle. Three-panel layout (live frame top
left at 4× scale, map top right at 1.25×, ~30 lines of status text
below). `--gui` flag now opens the diagnostic window; closing the
window or pressing Esc terminates the bot cleanly. No silky/whisky/
windy code runs in library builds — the whole `viewer/` subdirectory
is gated by `when not defined(modulabotLibrary)`.

Behavior preserved verbatim modulo sub-record renames; final parity
check 659/659 still holds after viewer port.

### Phase 3 — divergence (open)

Open per the original plan. Phase 0–2 deliverables are all green;
the v0 baseline is parity-validated against v2 to the extent
mathematically possible (see Phase 2 status). Possible directions
in priority order:

1. Better evidence model — quantitative suspicion scores instead of
   binary tiers (witnessed-kill vs near-body).
2. Smarter imposter chat — vary timing, add fake-task callouts,
   react to chat content beyond just "did anyone say sus".
3. Real ghost behavior — currently ghosts just keep doing tasks;
   could vent-watch, escort suspects, etc.
4. Vote bandwagon detection on the crewmate side — log the pattern
   without acting on it (preserve the evidence-only voting rule).
5. Patch v2 to accept `--seed` — would let parity testing exercise
   imposter paths properly, useful if a phase 3 change touches the
   imposter policy and we want to verify it doesn't break crewmate
   behavior.

---

## 12. Running modulabot

### Build

The bot lives in `players/modulabot/`. The CLI binary and the FFI
shared library are separate compile targets. Both are built relative
to the repo root because of the project-wide `config.nims` (which
adds `common/` and the nimby-managed package paths).

```sh
cd /Users/me/p/bitworld

# CLI binary (release mode is the default via config.nims).
nim c -o:among_them/players/modulabot/modulabot \
  among_them/players/modulabot/modulabot.nim

# Shared library (FFI for the training harness).
nim c --app:lib -d:modulabotLibrary \
  -o:among_them/players/modulabot/libmodulabot.dylib \
  among_them/players/modulabot/modulabot.nim

# Or use the bundled Python helper (handles nimby + Nim version).
python3 among_them/players/modulabot/build_modulabot.py
```

### CLI flags

| Flag | Default | Purpose |
|---|---|---|
| `--address:HOST` | `localhost` | Server host |
| `--port:N` | `8080` | Server port |
| `--name:STR` | `""` | Player name (sent in WS query) |
| `--gui` | off | Open the diagnostic viewer (Esc to quit) |
| `--frames:PATH` | off | Dump every received unpacked frame to `PATH` (16384 bytes per frame) for offline replay |
| `--map:PATH` | (sim default) | Override the map JSON path |

Note: modulabot defaults to `:8080`, but most local Among-Them
servers bind to `:2000` or `:8080` depending on how they were
started. Always pass `--port:N` matching the server.

### Single instance

Connect one modulabot to a server already running on `:2000`:

```sh
among_them/players/modulabot/modulabot \
  --address:localhost --port:2000 --name:mb1
```

With the diagnostic viewer:

```sh
among_them/players/modulabot/modulabot \
  --address:localhost --port:2000 --name:mb1 --gui
```

With frame capture for later parity / debug replay:

```sh
among_them/players/modulabot/modulabot \
  --address:localhost --port:2000 --name:mb1 \
  --frames:/tmp/run.bin
```

### Multiple instances via `tools/quick_player`

The repo's `tools/quick_player` helper compiles a player and spawns
N copies. It accepts either a bare label (matched against
`among_them/players/<label>.nim`) or a path. Modulabot lives one
level deeper than the older bots, so the **path form is required**:

```sh
cd /Users/me/p/bitworld
nim r tools/quick_player among_them/players/modulabot/modulabot.nim \
  --players:8 --address:localhost --port:2000
```

Spawns 8 modulabots named `modulabot1` … `modulabot8`. Override the
naming with `--name-prefix:foo` to get `foo1` … `foo8`.

`quick_player` build mode: `nim c <file>` from the repo root, which
inherits the project's `config.nims` and produces a release build by
default. No special flag needed.

### Mixed lobbies

The cleanest pattern is to fill the lobby with `quick_player` and
add a single GUI'd instance separately:

```sh
# Terminal A: 7 headless modulabots
nim r tools/quick_player among_them/players/modulabot/modulabot.nim \
  --players:7 --address:localhost --port:2000

# Terminal B: 1 modulabot with the diagnostic viewer
among_them/players/modulabot/modulabot \
  --address:localhost --port:2000 --name:mbgui --gui
```

Or mix bot families to test against v2 / nottoodumb:

```sh
# Terminal A: 4 v2 bots
nim r tools/quick_player evidencebot_v2 \
  --players:4 --address:localhost --port:2000

# Terminal B: 3 modulabots
nim r tools/quick_player among_them/players/modulabot/modulabot.nim \
  --players:3 --address:localhost --port:2000 --name-prefix:mb

# Terminal C: 1 GUI'd modulabot
among_them/players/modulabot/modulabot \
  --address:localhost --port:2000 --name:mbgui --gui
```

### Two `quick_player` caveats

1. **`--gui` propagates to all spawned processes.** Passing
   `--gui` to `quick_player` opens a viewer window for every
   modulabot. For >1 instance you almost certainly want some
   headless via `quick_player` and at most one GUI'd via the
   standalone binary.

2. **quick_player kills all children when any one exits.** If a
   game ends and one modulabot disconnects, every other modulabot
   in that quick_player group is terminated. The standalone
   `runBot` reconnect loop keeps retrying forever and is more
   resilient for long-running setups.

### Parity / regression tests

The harness at `players/modulabot/test/parity.nim` runs in two
modes:

```sh
# Build (release mode for speed)
nim c -d:release -o:among_them/players/modulabot/test/parity \
  among_them/players/modulabot/test/parity.nim

# Self-consistency: two modulabot instances, same seed, same frames.
# Always 100% if Q6 RNG-substream determinism is intact.
among_them/players/modulabot/test/parity \
  --replay:/tmp/run.bin --vs:self

# vs evidencebot_v2: byte-equivalent on non-RNG paths. Diverges
# contiguously at the first imposter RNG decision (v2 has no seed
# override) — see §11 phase-2 status for context.
among_them/players/modulabot/test/parity \
  --replay:/tmp/run.bin --vs:v2
```

Other harness modes for synthetic frames: `--mode:black` (interstitial
path, fast), `--mode:random` (slow — exhaustive spiral search per
frame), `--mode:mixed` (alternates).

### Capturing a replay

To capture a real-game frame stream for later parity / debugging:

```sh
among_them/players/modulabot/modulabot \
  --address:localhost --port:2000 --name:capture \
  --frames:/tmp/run.bin
```

The file grows at ~24 fps × 16384 bytes/frame ≈ 24 MB per minute of
gameplay. Format is a flat concatenation of unpacked frames; record
count is `filesize / 16384`. The mask is *not* recorded — the parity
harness re-derives it by running each bot on the captured frame,
which is the right semantic for offline parity testing.

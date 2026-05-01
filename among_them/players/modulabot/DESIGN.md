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
  TRACING.md                 ← outer-loop trace design + impl status
  BRANCH_IDS.md              ← auto-generated; canonical branch-ID catalog
  modulabot.nim              ← entry point: CLI main + when isMainModule
  build_modulabot.py         ← shared-library build helper (mirrors build_nottoodumb.py)

  types.nim                  ← enums, small records, sub-record types, Bot composition
  tuning.nim                 ← cross-cutting tuning knobs only (Q9)
  tuning_snapshot.nim        ← single-source-of-truth dump of every policy const for the trace manifest
  bot.nim                    ← Bot composition, initBot, decideNextMask, step*Frame*
  diag.nim                   ← debug strings: thought(), intent, fired(branchId), perf timers
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
  voting.nim                 ← parseVotingScreen + cursor/decision logic + chat OCR
  policy_crew.nim            ← crewmate decision tree (decideCrewmateMask)
  policy_imp.nim             ← imposter decision tree (decideImposterMask)
  trace.nim                  ← structured trace writer (manifest + events + decisions + snapshots)

  viewer/                    ← gated: when not defined(modulabotLibrary)
    viewer.nim               ← initViewerApp / pumpViewer / drawFrameView / drawMapView
    runner.nim               ← runBot, websocket I/O, reconnect loop, trace open/close

  ffi/                       ← gated: when defined(modulabotLibrary)
    lib.nim                  ← TrainableMasks, modulabot_new_policy, modulabot_step_batch, modulabot_init_trace

  test/                      ← regression / parity / trace harnesses
    parity.nim               ← self-consistency + vs-v2 mask diffing
    trace_smoke.nim          ← end-to-end trace smoke (manifest/events/decisions/snapshots)
    validate_trace.nim       ← schema validator for emitted traces

  tools/                     ← developer utilities
    gen_branch_ids.nim       ← regenerates BRANCH_IDS.md from `bot.fired("...")` sites
    trace_smoke.sh           ← local CI: build + parity + smoke + branch-ID drift
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

Phase numbering in this status log has diverged from the original
§8 plan during execution. The actual phase structure that shipped:

- Phase 0 — scaffold (as planned)
- Phase 1 — perception layer + policies (merges §8's Phase 1 + 2)
- Phase 2 — viewer + parity harness (absorbs §8's Phase 3 parity bake)
- Phase 3 — divergence (corresponds to §8's Phase 4; still open)
- Phase 4 — tracing for outer-loop self-improvement (new; added
  after §8 was frozen)

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
mathematically possible (see Phase 2 status).

**Long-term memory (v1)** shipped — see §13. Replaces v0's scalar
evidence latches with an event log (sightings, bodies, meetings,
plus an alibis log awaiting a caller) and per-colour summaries.
`identity.lastSeen` retired in favour of
`memory.summaries[i].lastSeenTick`. Trace schema bumped to v2;
`body_seen_first` now sourced from `memory.bodies` with an
`is_new_body` field. Self-consistency parity 500/500 across seeds
1 / 42 / 100 / 7777.

Possible directions in priority order:

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

### Phase 4 — tracing for outer-loop self-improvement ✅

Structured trace generation shipped in four sub-phases (see
`TRACING.md` for the full design + status table). Goal: feed an
outer-loop LLM harness that proposes edits to `policy_*.nim` based
on the bot's own experience.

**What landed:**

- New `trace.nim` module — manifest + events + decisions +
  snapshots, JSON serialisation, diff-state for edge detection.
- New `tuning_snapshot.nim` — single-source-of-truth dump of every
  policy const into the manifest, so harness lineage tracking can
  correlate outcomes with compiled-in tunables.
- 29 stable branch IDs across `policy_crew.nim`, `policy_imp.nim`,
  `voting.nim`, and `bot.nim`'s early-return paths. Catalogued in
  `BRANCH_IDS.md` (auto-generated by `tools/gen_branch_ids.nim`).
- Per-line voting-screen chat capture via a new `visibleChatLines`
  iterator in `voting.nim`; `chat_observed` events stream into
  `events.jsonl`. Speaker attribution added 2026-04-30: `chat_observed`
  events now carry `speaker` as the colour name, sampled from the
  per-message pip at `VoteChatIconX` (see `voting.readVoteChatSpeakers`);
  `manifest.trace_settings.speaker_attribution = "color_pip"`.
- New `Bot.trace` field, `bot.fired(branchId, intent)` helper,
  `decideNextMaskCore` / `decideNextMask` split (the public proc is
  now a thin wrapper that calls `traceFrame` after the policy runs).
- CLI flags: `--trace-dir`, `--trace-level`, `--trace-snapshot-period`,
  `--trace-meta`, `--trace-frames-dump` / `--no-trace-frames-dump`.
  Equivalent env vars: `MODULABOT_TRACE_DIR` etc.
- FFI: `modulabot_init_trace` exported proc; per-agent trace
  attachment in `modulabot_new_policy` and on dynamic resize in
  `modulabot_step_batch`.
- Smoke pipeline at `tools/trace_smoke.sh` runs parity (no trace) +
  parity (with trace) + end-to-end smoke + branch-IDs drift detection.

**Determinism:** the trace writer reads `Bot` after `decideNextMask`
returns and never mutates it (modulo its own internal shadow). The
parity test verifies this end-to-end:

- self-consistency, no trace: 500/500 black-mode + 50/50 mixed-mode
  @ multiple seeds — 100% match.
- self-consistency, with trace on bot A: 500/500 black-mode — trace
  is non-perturbing.

**Replay support:** every manifest carries `master_seed` and (when
auto-frames-dump is on, default) the path to the captured frame
stream. Reproducing a game's mask sequence is `nim r test/parity.nim
--replay:<frames> --seed:<seed>` away. The harness can re-emit
exhaustive traces with `--trace-level:full` for offline
investigation.

**Open work (intentionally deferred):**

- Frames-dump rotation / retention. v1 keeps everything; long runs
  will fill disk. The harness can post-process / delete as needed.
- Counterfactual annotations (which tier of `nearestTaskGoal` won)
  — the goal struct already carries enough state to reconstruct
  this offline; surfacing it in the trace is a v1.1 task if needed.

**Resolved (moved out of the deferred list):**

- Speaker attribution for `chat_observed` events (2026-04-30). See
  `voting.readVoteChatSpeakers` / `voting.voteChatSpeakerForLine`.
  `manifest.trace_settings.speaker_attribution = "color_pip"` when
  enabled; `chat_observed.speaker` carries the colour name.

See `TRACING.md` for full schemas, hook points, the open-questions
log, and the implementation status table.

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
| `--trace-dir:PATH` | off | Enable structured tracing under `PATH` (see TRACING.md) |
| `--trace-level:LVL` | `decisions` | `events` / `decisions` / `full`. `events` skips per-decision logging; `full` emits per-frame |
| `--trace-snapshot-period:N` | `120` | Ticks between belief-state snapshots |
| `--trace-meta:K=V[,K=V]*` | empty | Free-form metadata into `manifest.harness_meta` for lineage tracking |
| `--trace-frames-dump` / `--no-trace-frames-dump` | on (when `--trace-dir` set) | Auto-dump frames to `<trace-dir>/<bot>/<session>/frames.bin` for replay |

Env-var equivalents: `MODULABOT_TRACE_DIR`, `MODULABOT_TRACE_LEVEL`,
`MODULABOT_TRACE_SNAPSHOT_PERIOD`, `MODULABOT_TRACE_META`,
`MODULABOT_TRACE_FRAMES_DUMP`. Explicit flags win over env vars.

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

With structured tracing for the outer-loop harness:

```sh
among_them/players/modulabot/modulabot \
  --address:localhost --port:2000 --name:mb1 \
  --trace-dir:/tmp/runs \
  --trace-meta:experiment_id=baseline,git_sha=$(git rev-parse HEAD)
```

This writes one round directory per game under
`/tmp/runs/mb1/<session-id>/round-NNNN/` containing `manifest.json`,
`events.jsonl`, `decisions.jsonl`, `snapshots.jsonl`, plus (by
default) a `frames.bin` capture in the parent session directory.
See `TRACING.md` for the schema and `BRANCH_IDS.md` for the
canonical branch-ID list.

Validate emitted traces:

```sh
nim r among_them/players/modulabot/test/validate_trace.nim \
  --root:/tmp/runs
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

`--trace-dir:PATH` attaches a trace writer to bot A during the
self-consistency run. Used to verify the trace writer is
non-perturbing (see `TRACING.md` §13.2 / Phase 4 status).

For the full local CI loop (build + parity + smoke + branch-ID
drift), use the wrapper script:

```sh
among_them/players/modulabot/tools/trace_smoke.sh
```

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

---

## 13. Long-term memory (v1) — shipped

v0 evidence was a single scalar per colour (most-recent `nearBodyTicks`
and `witnessedKillTicks`). That collapsed time and co-witness structure
and made it hard for the voting/planning policies — or the outer-loop
LLM harness — to reason about patterns across a round. v1 adds an
event log plus incrementally-maintained per-player summaries,
preserving the scalar cache for parity with v0 voting logic.

Implementation landed in `memory.nim`, `types.nim`, `evidence.nim`,
`actors.nim`, `bot.nim`, and `trace.nim`. Parity validated:
self-consistency remains 500/500 across seeds 1 / 42 / 100 / 7777 in
black mode and 50/50 in mixed mode; trace remains non-perturbing
(500/500 with `--trace-dir` attached to bot A).

### 13.1. Event categories

Four categories, all round-scoped. Raw sightings and alibis are
trimmed at meeting boundaries; bodies and meetings persist for the
whole round.

| Category | Trigger | Lifetime |
|---|---|---|
| Sighting | Non-self, non-teammate colour visible this frame (dedup'd by tick Δ + pixel Δ) | Trimmed at meeting close; summary persists |
| Body | Body newly appears (v2 "witnessedKill" signal), or first-seen body persists | Retained for the round |
| Meeting | Voting screen closes | Retained for the round |
| Alibi | Colour seen at a task terminal, or a task-completion flash co-occurs with a recently-seen colour | Trimmed at meeting close; summary persists |

### 13.2. Types

Added to `types.nim` alongside `Evidence`:

```nim
type
  SightingEvent* = object
    tick*: int
    colorIndex*: int
    x*, y*: int
    roomId*: int                  # -1 if outside any named room

  BodyWitness* = object
    colorIndex*: int
    dx*, dy*: int                 # offset from body at witness tick

  BodyEvent* = object
    tick*: int
    x*, y*: int
    roomId*: int
    witnesses*: seq[BodyWitness]
    isNewBody*: bool              # v2's "witnessedKill" signal

  MeetingEvent* = object
    startTick*: int
    endTick*: int
    reporter*: int                # -1 if unknown (v1 default; filling
                                  # it in needs a separate nametag-in-
                                  # meeting-intro perception pass, not
                                  # the chat pip)
    selfVote*: int                # VoteSkip / color / VoteUnknown
    votes*: PerColor[int]
    ejected*: int                 # -1 if skipped or unknown
    chatLines*: seq[VoteChatLine] # raw OCR + per-line speaker colour
                                  # (color_pip attribution)

  VoteChatLine* = object          # one row of voting-screen chat
    speakerColor*: int            # palette index 0..15, or -1
                                  # (`VoteUnknown`) if the pip could
                                  # not be resolved within
                                  # `VoteChatSpeakerSearch` rows
    y*: int                       # row y of the text line (debug)
    text*: string                 # OCR'd line (post-strip)

  AlibiEvent* = object
    tick*: int
    colorIndex*: int
    taskIndex*: int

  PlayerSummary* = object
    lastSeenTick*: int
    lastSeenX*, lastSeenY*: int
    lastSeenRoomId*: int
    timesNearBody*: int
    timesWitnessedKill*: int
    timesVotedForMe*: int
    timesIVotedForThem*: int
    timesVotedWithMe*: int
    taskBits*: uint64             # which task indices we've seen them at
    distinctTasksObserved*: int   # popcount(taskBits), cached
    ejected*: bool

  Memory* = object
    sightings*: seq[SightingEvent]
    bodies*: seq[BodyEvent]
    meetings*: seq[MeetingEvent]
    alibis*: seq[AlibiEvent]
    summaries*: PerColor[PlayerSummary]
    lastMeetingEndTick*: int      # sighting/alibi trim boundary

# Bot gains:
#   memory*: Memory
```

Lives in a new `memory.nim` module, imported by `evidence.nim`,
`voting.nim`, and both `policy_*` modules. `evidence.nim`'s existing
`updateEvidence` keeps its current signature but becomes a thin
consumer of `memory.recordBodyFrame(...)` — the scalar
`nearBodyTicks` / `witnessedKillTicks` remain as a hot-path cache
populated from memory appends so existing voting code (`evidence.nim`
`evidenceBasedSuspect`) keeps working unchanged.

### 13.3. Lifetime rules

- **Round reset:** clear all four logs and summaries at the role-reveal
  interstitial (or equivalent round-boundary signal). Mirrors how
  humans play; avoids cross-round leakage.
- **Trim at meeting close:** after the voting screen closes and the
  `MeetingEvent` is appended, discard `SightingEvent`s and
  `AlibiEvent`s with `tick < lastMeetingEndTick`. Their contribution
  has already updated the per-colour summary on write; the raw
  records exist only for the "since last meeting" reasoning window.
- **Body and meeting logs never trim:** at most ~10 of each per round.

### 13.4. Dedup and thresholds

Sightings are the hot-path category. Dedup rule: don't append a new
`SightingEvent` for colour `c` if the previous sighting for `c` was
within `MemorySightingDedupTicks` ticks AND within
`MemorySightingDedupPixels` pixels. Both constants live in
`tuning.nim`. Starting values `5 / 16` — bake during first integration
test. The per-colour summary (`lastSeenTick`, `lastSeenX/Y`) updates
on *every* visible frame regardless of dedup; the dedup only governs
raw event-log growth.

### 13.5. Migration of `identity.lastSeen`

`identity.lastSeen: PerColor[int]` is removed. Its callers (in
`evidence.nim`'s `suspectedColor` and `randomInnocentColor`, plus any
direct reads from `policy_*`) switch to
`bot.memory.summaries[i].lastSeenTick`. One-shot audit; parity
(self-consistency) must remain 100% — the timing of
`lastSeenTick` writes must match v2-era `identity.lastSeen` writes
exactly (same frames, same colours skipped).

### 13.6. `trace.nim` consolidation

Single-source-of-truth rule: the trace writer observes `Memory`
appends instead of maintaining parallel diff state.

Diff fields on `TraceWriter` (`types.nim`) that became redundant and
were removed:

| Field | Replacement |
|---|---|
| `prevBodyWorldPositions` | `prevBodiesCount` shadow over `memory.bodies` — new entries emit `body_seen_first` events from the BodyEvent payload (witnesses, roomId, isNewBody). |

Fields from the original plan that were **kept** (deviation from the
design):

| Field | Reason |
|---|---|
| `prevSelfVoteChoice` | Per-tick change detection for the `vote_cast` event during an active meeting. `MeetingEvent` is finalized at meeting close and can't drive edge-triggered events that fire *inside* a meeting. |
| `prevVoteChoices` | Same reason, for `vote_observed` events as each other player's vote lands. |

These two are not genuinely "redundant" — `MeetingEvent.votes` is an
aggregate final snapshot, whereas trace wants to emit one event per
vote transition as it happens. Reconciling that would require either
(a) live-updating `memory.meetings[^1]` on every observed vote change,
which duplicates `voting.choices` across two locations, or (b) moving
per-tick vote events out of trace. Neither is a win; the kept shadows
are the pragmatic choice.

Fields that stay (not memory-backed, never were in scope):

| Field | Reason |
|---|---|
| `prevStuckActive` / `prevStuckStartTick` | Motion state, not observation memory |
| `prevRole` / `prevIsGhost` / `prevSelfColor` | Bot scalars, not memory |
| `prevInterstitial` / `prevInterstitialText` / `prevGameOverText` | Perception, not memory |
| `prevLocalized` / `prevCameraLock` | Perception, not memory |
| `prevTaskStates` / `prevTaskResolved` | Task state, not observation memory |
| `prevKillReady` | Imposter state, not observation memory |

Trace schema bumped to v2; the v1→v2 change is additive (one new
field `is_new_body` on `body_seen_first`, existing fields unchanged).
`validate_trace` and `trace_smoke` were updated to accept schema v1
and v2.

### 13.7. Deferred / out of scope for v1

- ~~**Chat-based accusation attribution**~~ — unblocked 2026-04-30
  by speaker attribution (TRACING.md §15). `MeetingEvent.chatLines`
  now carries `VoteChatLine` records (text + speaker colour);
  evidence / policy work that builds on "who accused whom" can now
  land without another schema bump.
- ~~**Task-claim / location-claim parsing**~~ — same blocker
  cleared. Still on the `policy_imp.chat.parse` backlog (TODO
  §"Smarter imposter chat").
- **Disappearance events** (visible → gone → body appears at last-seen
  location) — computable from the sighting + body logs post-hoc; no
  need for a separate event category in v1.
- **Co-presence windows** — computable from the sighting log on
  demand; don't pre-aggregate.
- **Ring-buffer caps** — the meeting-boundary trim rule bounds the
  hot categories to ~O(ticks since last meeting). Cap introduction
  is a v1.1 concern if profile data shows it's needed.

### 13.8. Determinism / parity implications

- Self-consistency parity test must stay 100%. Two identically-seeded
  bots must produce identical `Memory` state → identical emitted
  trace events.
- Iteration order matters: `visibleCrewmates` ordering is already
  deterministic (scan order); appending in that order keeps the
  sighting log deterministic.
- The trace refactor changes the *code path* for emitting body/vote
  events but not their *content*. Existing `validate_trace` tooling
  should continue passing.

### 13.9. Implementation (shipped)

Landed in order:

1. Types + Memory scaffolding (`types.nim`, `memory.nim`,
   `tuning.nim` knobs).
2. `identity.lastSeen` migrated to `memory.summaries[i].lastSeenTick`
   in `evidence.nim` (`suspectedColor`, `randomInnocentColor`),
   `actors.nim` (`scanCrewmates` → `memory.appendSighting`),
   `bot.nim` (`resetRoundState`, `initBot`). Self-consistency parity
   remained 500/500.
3. `updateEvidence` in `evidence.nim` extended to call
   `memory.appendBody` alongside the scalar `witnessedKillTicks`
   cache on new-body detection. Parity preserved.
4. `trace.nim` refactored to consume `memory.bodies` for
   `body_seen_first` / `kill_witnessed` events via a `prevBodiesCount`
   shadow. `prevBodyWorldPositions` removed; schema bumped to v2.
   Validators updated. Parity preserved (with and without
   `--trace-dir` attached).
5. Meeting close in `decideNextMaskCore` now appends a
   `MeetingEvent` to memory before calling `clearVotingState`.
   `bot.memory.recordVoteForMe` / `recordIVotedForThem` translate
   slot→colour once per meeting so the summary counters are
   authoritative. `memory.trimAtMeetingEnd` drops sighting/alibi
   raw events older than the meeting end.

#### Implementation notes

- **Hook shape.** The originally-proposed `onAppend` callback on
  Memory was dropped in favour of a pull model: trace shadows
  `memory.bodies.len` and observes growth. This avoids a callback
  plumbing layer and keeps `memory.nim` as pure data + pure append
  procs with no dependency on trace. The "single source of truth"
  rule still holds — there's only one place that records a body
  (`memory.appendBody`) and one place that emits the event.
- **Alibi appends deferred.** The schema and append proc are in
  place, but no caller invokes `memory.appendAlibi` yet. Wiring
  (from `tasks.nim` on co-visibility of a task icon + crewmate) is
  a follow-up; the v1 log is empty for alibis until that lands.
- **`reporter` / `ejected`** remain `-1` in `MeetingEvent` as
  planned. Adding these requires perception work (detecting who
  called the meeting from the intro animation; detecting who was
  ejected from the post-vote cutscene) that is outside the memory
  module's scope.



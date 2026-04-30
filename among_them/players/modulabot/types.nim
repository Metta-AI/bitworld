## Modulabot type definitions.
##
## Phase 0 scope: every type the rest of the codebase will need to refer to
## *by name*. No procs, no business logic. The shape locked down here is
## what the per-module ports in phase 1 will fill in.
##
## Layout decisions are recorded in DESIGN.md §3. Notable conventions:
##
## - `Bot` is a thin envelope holding sub-records. Cross-cutting top-level
##   fields (`role`, `isGhost`, `frameTick`, `sim`, `paths`, `rngs`,
##   `sprites`) stay flat because every layer reads them.
## - Field names inside sub-records drop the prefix that became implicit
##   from the sub-record name. e.g. v2's `bot.taskHoldTicks` becomes
##   `bot.tasks.holdTicks`, `bot.imposterFolloweeColor` becomes
##   `bot.imposter.followeeColor`.
## - `voting` is a sub-record; the boolean that v2 called `bot.voting`
##   becomes `bot.voting.active`.

import std/random
import ../../sim
import ../../../common/server

const
  PlayerColorCount* = PlayerColors.len
    ## Number of distinct player colour palettes. Used to size all
    ## per-colour arrays.

type
  TileKnowledge* = enum
    TileUnknown
    TileOpen
    TileWall

  CameraLock* = enum
    NoLock
    LocalFrameMapLock
    FrameMapLock

  TaskState* = enum
    TaskNotDoing
    TaskMaybe
    TaskMandatory
    TaskCompleted

  BotRole* = enum
    RoleUnknown
    RoleCrewmate
    RoleImposter

  PathStep* = object
    ## One waypoint along an A* path. `found = false` indicates the
    ## absence of a usable step (caller should idle).
    found*: bool
    x*: int
    y*: int

  PatchEntry* = object
    ## One entry in the static map's patch-hash lookup. Built once at
    ## construction; immutable thereafter.
    hash*: uint64
    cameraX*: int
    cameraY*: int

  PatchCandidate* = object
    ## Top-N camera offset by patch-hash vote. Re-populated each frame.
    votes*: int
    cameraX*: int
    cameraY*: int

  RadarDot* = object
    x*: int
    y*: int

  IconMatch* = object
    x*: int
    y*: int

  CrewmateMatch* = object
    x*: int
    y*: int
    colorIndex*: int
    flipH*: bool

  BodyMatch* = object
    x*: int
    y*: int

  GhostMatch* = object
    x*: int
    y*: int
    flipH*: bool

  VoteSlot* = object
    colorIndex*: int
    alive*: bool

  PerColor*[T] = array[PlayerColorCount, T]

  PrevFrame* = object
    ## Q2 resolved (option c). Snapshot of the previous frame's camera so
    ## actor-sprite scans can run BEFORE localization without depending on
    ## this frame's not-yet-updated camera. `valid = false` means we just
    ## came out of an interstitial / teleport; the snapshot is unreliable
    ## and the orchestrator should not trust it.
    valid*: bool
    cameraX*: int
    cameraY*: int

  Perception* = object
    ## Everything the bot believes about the world from the current frame.
    ## Mutated by `localize`, `actors`, `tasks`, plus a final
    ## `snapshotPrevFrame` at end of the per-frame pipeline.
    cameraX*, cameraY*: int
    lastCameraX*, lastCameraY*: int
    cameraLock*: CameraLock
    cameraScore*: int
    localized*: bool
    interstitial*: bool
    interstitialText*: string
    lastGameOverText*: string
    gameStarted*: bool
    homeSet*: bool
    homeX*, homeY*: int
    mapTiles*: seq[TileKnowledge]
    patchEntries*: seq[PatchEntry]
    patchVotes*: seq[uint16]
    patchTouched*: seq[int]
    patchCandidates*: seq[PatchCandidate]
    radarDots*: seq[RadarDot]
    visibleTaskIcons*: seq[IconMatch]
    visibleCrewmates*: seq[CrewmateMatch]
    visibleBodies*: seq[BodyMatch]
    visibleGhosts*: seq[GhostMatch]
    prev*: PrevFrame

  FrameIO* = object
    ## Wire-protocol buffers and frame-drain accounting. Owned by the
    ## websocket runner / FFI step glue, not by the strategy layers.
    packed*: seq[uint8]
    unpacked*: seq[uint8]
    queuedFrames*: seq[string]
    frameBufferLen*: int
    framesDropped*: int
    skippedFrames*: int
    lastMask*: uint8

  Motion* = object
    ## Velocity inference and anti-stuck jiggle. `desiredMask` is what the
    ## policy wanted; `controllerMask` is what the controller produced
    ## after coast/brake; the final emitted mask may further differ if
    ## jiggle is applied on top.
    haveMotionSample*: bool
    previousPlayerWorldX*, previousPlayerWorldY*: int
    velocityX*, velocityY*: int
    stuckFrames*: int
    jiggleTicks*, jiggleSide*: int
    desiredMask*, controllerMask*: uint8

  Tasks* = object
    ## Task-state model. Length of every seq tracks `sim.tasks.len`.
    radar*: seq[bool]            ## v2: bot.radarTasks
    checkout*: seq[bool]         ## v2: bot.checkoutTasks
    states*: seq[TaskState]      ## v2: bot.taskStates
    iconMisses*: seq[int]        ## v2: bot.taskIconMisses
    resolved*: seq[bool]         ## v2 latch (v2: bot.taskResolved)
    holdTicks*: int              ## v2: bot.taskHoldTicks
    holdIndex*: int              ## v2: bot.taskHoldIndex; -1 = no hold

  Goal* = object
    ## Q1 resolved: shared between crewmate and imposter policies.
    ## `index` is interpreted by the active policy (task index for crew,
    ## fake-target index for imposter wandering).
    x*, y*: int
    index*: int
    name*: string
    has*: bool
    hasPathStep*: bool
    pathStep*: PathStep
    path*: seq[PathStep]

  Identity* = object
    selfColor*: int                       ## v2: bot.selfColorIndex; -1 unknown
    knownImposters*: PerColor[bool]
    lastSeen*: PerColor[int]              ## tick of last sighting per colour

  Evidence* = object
    ## Per-colour witness bookkeeping for the crewmate accusation policy.
    nearBodyTicks*: PerColor[int]
    witnessedKillTicks*: PerColor[int]
    prevCrewmateX*: PerColor[int]         ## -1 = not visible last frame
    prevCrewmateY*: PerColor[int]
    prevBodies*: seq[tuple[x: int, y: int]]

  ImposterState* = object
    killReady*: bool
    goalIndex*: int                       ## current fake-target wander index
    followeeColor*: int                   ## -1 = not following
    followeeSinceTick*: int
    fakeTaskIndex*: int                   ## -1 = not currently fake-tasking
    fakeTaskUntilTick*: int
    fakeTaskCooldownTick*: int
    prevNearTaskIndex*: int               ## task we were "passing by" last frame; -1 = none
    lastKillTick*: int
    lastKillX*, lastKillY*: int
    # Central-room stuck detection. Counts ticks of "in central room with
    # >= ImposterCentralRoomMinCrewmates visible non-teammates"; once it
    # exceeds the stuck threshold, sets `forceLeaveUntilTick` and the
    # imposter routes to the farthest fake target until the timer
    # expires. Prevents the end-game lobby orbit pathology.
    centralRoomTicks*: int
    forceLeaveUntilTick*: int
    # Vent escape state. When a body is visible and no non-teammate crewmate
    # can see the imposter, the bot navigates to the nearest vent and presses
    # B to teleport away. `ventTargetIndex` caches the chosen vent across
    # frames so the approach path stays stable; -1 = no active vent target.
    # `ventCooldownTick` prevents re-venting immediately after a teleport
    # (the server enforces its own 30-tick cooldown, but we add a conservative
    # bot-side gate to avoid spamming ButtonB on every frame while in range).
    ventTargetIndex*: int
    ventCooldownTick*: int

  VotingState* = object
    ## Voting-screen UI state machine. `active` is true while we believe
    ## the meeting screen is up.
    active*: bool                         ## v2: bot.voting
    playerCount*: int
    cursor*: int                          ## VoteUnknown / VoteSkip / 0..N-1
    selfSlot*: int
    target*: int
    startTick*: int
    chatSusColor*: int
    chatText*: string
    chatLines*: seq[string]               ## per-line OCR cache, populated
                                          ## alongside chatText; used by
                                          ## the trace writer to emit
                                          ## chat_observed events without
                                          ## a second OCR pass.
    slots*: array[MaxPlayers, VoteSlot]
    choices*: PerColor[int]               ## what each colour voted for

  ChatState* = object
    pendingChat*: string                  ## flushed on next interstitial
    lastBodySeenX*, lastBodySeenY*: int
    lastBodyReportX*, lastBodyReportY*: int

  Diag* = object
    ## Human-readable activity description. Distinct from Perf timings.
    intent*: string                       ## set by policy: "doing task", "flee body", ...
    lastThought*: string                  ## last raw debug log line
    branchId*: string                     ## stable ID of the policy branch
                                          ## that fired this frame; see
                                          ## TRACING.md §8 for the canonical
                                          ## list. Reset to "" at the top of
                                          ## decideNextMask; every code
                                          ## path must call bot.fired(...)
                                          ## before returning.

  Perf* = object
    ## Per-frame timing micros for the viewer. Reset at each frame's
    ## start by their owning module.
    centerMicros*: int
    spriteScanMicros*: int
    localizeLocalMicros*: int
    localizePatchMicros*: int
    localizeSpiralMicros*: int
    astarMicros*: int

  Sprites* = object
    ## Static reference sprites for matching. Each Bot owns its own copy
    ## (Q10 deferred); a future cache would live in a sibling module.
    player*: Sprite
    body*: Sprite
    ghost*: Sprite
    task*: Sprite
    killButton*: Sprite
    ghostIcon*: Sprite

  RngStreams* = object
    ## Q6 resolved: per-consumer substreams seeded deterministically from a
    ## master seed in `initRngStreams`. Decoupling means a code change to
    ## one consumer cannot shift the sequence of the others — useful for
    ## parity testing across versions.
    imposterChat*: Rand                   ## randomInnocentColor for chat
    imposterTask*: Rand                   ## fake-task die roll, duration
    imposterFollow*: Rand                 ## followee swap
    voteTie*: Rand                        ## tiebreaker between equal-evidence suspects

  Paths* = object
    ## Q8 resolved: explicit paths threaded through `initBot`; replaces the
    ## old `setCurrentDir(gameDir())` global side effect. All fields are
    ## absolute paths populated once at construction.
    gameRoot*: string                     ## .../bitworld/among_them
    atlasPath*: string                    ## .../bitworld/clients/dist/atlas.png
    mapPath*: string                      ## empty = let sim use DefaultMapPath

  TraceLevel* = enum
    ## Verbosity tier for the trace writer. See TRACING.md §10.
    tlOff
    tlEvents
    tlDecisions
    tlFull

  ManifestCounters* = object
    ## Accumulated per-round statistics; flushed into manifest.json at
    ## round end. Updated incrementally by the trace writer; never read
    ## by policy code.
    ticksTotal*: int
    ticksLocalized*: int
    framesDropped*: int
    meetingsAttended*: int
    votesCast*: int
    skipsVoted*: int
    killsExecuted*: int
    killsWitnessed*: int
    bodiesSeenFirst*: int
    bodiesReported*: int
    tasksCompleted*: int
    chatsSent*: int
    chatsObserved*: int
    stuckEpisodes*: int
    branchTransitions*: int
    eventsEmitted*: int
    snapshotsEmitted*: int

  TraceWriter* = ref object
    ## Append-only structured trace writer. Owns all file handles and
    ## diff state for emitting events.jsonl, decisions.jsonl,
    ## snapshots.jsonl, and manifest.json. Implementation lives in
    ## `trace.nim`; this type is in `types.nim` only because `Bot` must
    ## hold a nilable reference to it.
    ##
    ## All fields are private to the trace writer; nothing else should
    ## read or write them. The asterisk on the field is for cross-module
    ## visibility, not a public-API claim.
    rootDir*: string
    botName*: string
    sessionId*: string
    level*: TraceLevel
    snapshotPeriod*: int
    captureFrames*: bool
    harnessMeta*: string                  ## raw harness-meta JSON object text
    bootedUnixMs*: int64                  ## set once at openTrace
    # Round bookkeeping
    nextRoundId*: int                     ## next roundId to allocate
    roundOpen*: bool
    roundId*: int
    roundDir*: string
    roundStartedUnixMs*: int64
    roundStartTick*: int
    startedMidRound*: bool
    # File handles (nil when closed)
    eventsFile*: File
    decisionsFile*: File
    snapshotsFile*: File
    framesFile*: File
    # Per-decision shadow
    prevBranchId*: string
    prevBranchEnterTick*: int
    # Per-event shadow (Phase 1 minimum set)
    prevLocalized*: bool
    prevCameraLock*: CameraLock
    prevSelfColor*: int
    prevRole*: BotRole
    prevIsGhost*: bool
    prevKillReady*: bool
    prevInterstitial*: bool
    prevInterstitialText*: string
    prevGameOverText*: string
    prevTaskStates*: seq[TaskState]
    prevTaskResolved*: seq[bool]
    prevSelfVoteChoice*: int
    prevVoteChoices*: PerColor[int]
    prevStuckActive*: bool
    prevStuckStartTick*: int
    prevBodyWorldPositions*: seq[tuple[x, y: int]]
    # Meeting bookkeeping
    meetingActive*: bool
    meetingIndex*: int                    ## 1-indexed within round
    meetingStartTick*: int
    meetingVoteCast*: bool
    meetingSelfQueuedNormalized*: string  ## normalized self chat to dedupe
    meetingSeenChat*: seq[string]         ## normalized lines already emitted
    # Per-frame snapshot scheduling
    lastSnapshotTick*: int
    # Soft warnings (one-shot per round)
    warnedEmptyBranchId*: bool
    # Counters
    counters*: ManifestCounters
    # Final-manifest record (built up across the round)
    config*: string                       ## inline JSON string
    tuningSnapshot*: string               ## inline JSON string
    masterSeed*: int64
    framesPath*: string                   ## passed-through external --frames if any

  Bot* = object
    ## Top-level bot state. Cross-cutting scalars stay flat; everything
    ## else lives in a sub-record. See DESIGN.md §3 for rationale.
    sim*: SimServer
    paths*: Paths
    rngs*: RngStreams
    role*: BotRole
    isGhost*: bool
    ghostIconFrames*: int
    frameTick*: int
    sprites*: Sprites
    io*: FrameIO
    percep*: Perception
    motion*: Motion
    tasks*: Tasks
    goal*: Goal
    identity*: Identity
    evidence*: Evidence
    imposter*: ImposterState
    voting*: VotingState
    chat*: ChatState
    diag*: Diag
    perf*: Perf
    trace*: TraceWriter                   ## nil when tracing disabled.
                                          ## Populated by the runner / FFI
                                          ## init when --trace-dir is set.

  # Voting cursor sentinel values. v2 used module-level constants
  # (`VoteUnknown = -1`, `VoteSkip = -2`); they're tightly coupled to
  # VotingState's `cursor`/`target`/`selfSlot` semantics so they live here
  # alongside the type that uses them.
const
  VoteUnknown* = -1
  VoteSkip* = -2

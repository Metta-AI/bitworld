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
    ##
    ## `frameAdvance` (FFI-only) is the number of server ticks elapsed
    ## between the previous frame and this one, as reported by the
    ## cogames bitworld_runner when it drains a burst of buffered frames.
    ## It's 1 in normal operation (websocket CLI) and for tests. Velocity
    ## inference divides the world-position delta by this to produce a
    ## per-tick velocity that matches what a single-frame sample would
    ## see. Without this, a frame burst of 5 ticks would make velocity
    ## look 5x too large and trip the teleport-detection path.
    haveMotionSample*: bool
    previousPlayerWorldX*, previousPlayerWorldY*: int
    velocityX*, velocityY*: int
    stuckFrames*: int
    jiggleTicks*, jiggleSide*: int
    desiredMask*, controllerMask*: uint8
    frameAdvance*: int

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

  Evidence* = object
    ## Per-colour witness bookkeeping for the crewmate accusation
    ## policy. These scalars are a hot-path cache mirror of
    ## `memory.summaries`; they are populated from inside
    ## `updateEvidence` alongside the richer memory appends so that
    ## existing voting code (`evidenceBasedSuspect`) keeps the exact
    ## scalar semantics it had pre-memory. See DESIGN.md §13.6.
    nearBodyTicks*: PerColor[int]
    witnessedKillTicks*: PerColor[int]
    prevCrewmateX*: PerColor[int]         ## -1 = not visible last frame
    prevCrewmateY*: PerColor[int]
    prevBodies*: seq[tuple[x: int, y: int]]

  # -----------------------------------------------------------------
  # Long-term memory (DESIGN.md §13)
  # -----------------------------------------------------------------

  SightingEvent* = object
    ## One observation of a non-self, non-teammate crewmate. Appended
    ## by the actor scan; dedup'd in-module against
    ## `Memory.lastSightingIndex[colorIndex]`.
    tick*: int
    colorIndex*: int
    x*, y*: int
    roomId*: int                          ## -1 if outside any named room

  BodyWitness* = object
    ## One crewmate within witness radius of a body at the frame the
    ## body was first recorded.
    colorIndex*: int
    dx*, dy*: int                         ## offset from body

  BodyEvent* = object
    ## First-seen record of a distinct body. Round-lifetime dedup by
    ## position (see memory.appendBody).
    tick*: int
    x*, y*: int
    roomId*: int
    witnesses*: seq[BodyWitness]
    isNewBody*: bool                      ## v2's "witnessedKill" signal

  VoteChatLine* = object
    ## One OCR'd voting-screen chat line plus its attributed speaker.
    ## `speakerColor` is -1 when speaker-pip detection failed (sprite
    ## obscured, palette ambiguity) — callers should fall back to
    ## prior-line attribution (multi-line messages share one sprite)
    ## or treat as unknown. Introduced in Sprint 2.1
    ## (`LLM_SPRINTS.md §2.1`). Prior to v3 this was a bare
    ## `seq[string]` with speaker attribution deferred.
    speakerColor*: int                    ## player color index, -1 unknown
    text*: string

  MeetingEvent* = object
    ## One completed meeting, appended at meeting close (voting screen
    ## just went away). `votes` matches the live semantics of
    ## `VotingState.choices` — each entry is a slot index, `VoteSkip`,
    ## or `VoteUnknown`. Consumers translate slot → colour themselves.
    startTick*: int
    endTick*: int
    reporter*: int                        ## -1 if unknown (v1 default)
    selfVote*: int                        ## slot index / VoteSkip /
                                          ## VoteUnknown
    votes*: PerColor[int]
    ejected*: int                         ## -1 if skipped or unknown
                                          ## (Sprint 2.4 will populate)
    chatLines*: seq[VoteChatLine]         ## raw OCR + attributed speakers

  AlibiEvent* = object
    ## Positive-innocence signal: a colour seen at or near a task
    ## terminal. v1 populates on task-icon co-visibility; richer
    ## rules (task-completion flash correlation) are v1.1.
    tick*: int
    colorIndex*: int
    taskIndex*: int

  SelfKeyframe* = object
    ## One room-transition keyframe for the bot's own position.
    ## Feeds `my_location_history` in imposter LLM contexts so the
    ## model can build alibi claims consistent with where the bot
    ## actually went. Appended on every transition from one
    ## named room to another; cap-bounded by
    ## `MemorySelfKeyframeCap`. Introduced in Sprint 2.2
    ## (`LLM_SPRINTS.md §2.2`). Cleared only at round reset — NOT
    ## at meeting boundaries, because the imposter needs the full
    ## pre-meeting history.
    tick*: int
    roomId*: int

  PlayerSummary* = object
    ## Per-colour aggregate updated incrementally on each append.
    ## Replaces `Identity.lastSeen` and supersets it with location
    ## and derived counts.
    lastSeenTick*: int
    lastSeenX*, lastSeenY*: int
    lastSeenRoomId*: int
    timesNearBody*: int
    timesWitnessedKill*: int
    timesVotedForMe*: int
    timesIVotedForThem*: int
    timesVotedWithMe*: int
    taskBits*: uint64                     ## which task indices seen
    distinctTasksObserved*: int           ## popcount(taskBits), cached
    ejected*: bool

  Memory* = object
    ## Round-scoped long-term evidence memory. See DESIGN.md §13.
    ##
    ## Lifetime rules:
    ##   * `resetForNewRound` clears everything at role reveal /
    ##     game-over edges.
    ##   * `trimAtMeetingEnd` drops `sightings` and `alibis` with
    ##     `tick < lastMeetingEndTick`; `bodies` and `meetings`
    ##     persist for the whole round.
    ##   * Summaries update incrementally on each append regardless
    ##     of dedup/trim — so queries like "last time I saw X" stay
    ##     accurate even after the raw log is trimmed.
    sightings*: seq[SightingEvent]
    bodies*: seq[BodyEvent]
    meetings*: seq[MeetingEvent]
    alibis*: seq[AlibiEvent]
    summaries*: PerColor[PlayerSummary]
    lastSightingIndex*: PerColor[int]     ## -1 if no sighting this
                                          ## round; index into
                                          ## `sightings` for dedup.
                                          ## Stale after trim — but
                                          ## dedup only cares about
                                          ## *recent* entries so
                                          ## false-positive dedup
                                          ## after trim is safe
                                          ## (we'd just append more
                                          ## aggressively for a few
                                          ## frames).
    lastMeetingEndTick*: int              ## sighting/alibi trim
                                          ## boundary; -1 if no
                                          ## meeting yet this round.
    selfKeyframes*: seq[SelfKeyframe]     ## bot's own room-transition
                                          ## history; Sprint 2.2.
                                          ## Never trimmed mid-round.
    lastSelfRoomId*: int                  ## last room the keyframe
                                          ## logger saw us in; -1
                                          ## means "not yet recorded".

  # -----------------------------------------------------------------
  # LLM voting integration (LLM_VOTING.md)
  # -----------------------------------------------------------------
  #
  # Design: LLM_VOTING.md §1-§12. Implementation plan amended from the
  # pure-Nim design to the "Option B" hybrid — Nim owns the state
  # machine and context assembly; the Python wrapper performs the HTTP
  # call to Anthropic/Bedrock and feeds JSON responses back via the FFI.
  # This avoids SigV4 in Nim and lets us reuse Softmax's existing
  # AnthropicBedrock credential chain in the cogames runner.
  #
  # Without `-d:modTalksLlm`, every field is still present (Nim's
  # compile-time gating does not extend into object layouts cleanly
  # without introducing `{.compileTime.}` trickery that would cascade
  # through existing parity tests). The fields carry negligible cost
  # when unused; the gate is on the *call sites* in bot.nim /
  # voting.nim / llm.nim rather than on the storage.

  LlmVotingStage* = enum
    lvsIdle,                ## not in a meeting / LLM layer disabled
    lvsFormingHypothesis,   ## crewmate: first LLM call in flight
    lvsFormingStrategy,     ## imposter: strategy call in flight
    lvsListening,           ## waiting; no LLM call in flight
    lvsAccusing,            ## accusation / preemptive chat queued
    lvsReacting,            ## reaction loop; 0 or 1 calls in flight
    lvsVoting               ## vote decided; done with LLM this meeting

  LlmCallKind* = enum
    lckNone
    lckHypothesis          ## crewmate Stage 1
    lckAccuse              ## crewmate Stage 2 (chat generation)
    lckReact               ## crewmate Stage 3 (belief-update + chat)
    lckStrategize          ## imposter Stage 1
    lckImposterReact       ## imposter Stage 2
    lckPersuade            ## crewmate Stage 4 (optional)

  LlmSuspect* = object
    colorIndex*: int
    likelihood*: float32
    reasoning*: string

  LlmHypothesis* = object
    ## Latest crewmate hypothesis. `valid = false` before the first
    ## response arrives (or after a fallback).
    suspects*: seq[LlmSuspect]          ## sorted by likelihood desc
    confidence*: string                 ## "high" | "medium" | "low"
    keyEvidence*: seq[string]
    valid*: bool

  LlmImposterStrategy* = object
    ## Latest imposter strategy. `valid = false` before Stage 1
    ## returns or on fallback.
    bestTarget*: int                    ## color index; -1 = not set
    strategy*: string                   ## "bandwagon"|"preemptive"|"deflect"
    timing*: string                     ## "early"|"mid"|"late"
    valid*: bool

  LlmChatEntry* = object
    ## One observed chat line during the current meeting. Speaker
    ## attribution is deferred (LLM_VOTING.md Q-LLM9) — `speakerColor`
    ## stays -1 until the speaker-pip detector lands. `mine` is the
    ## one attribution we can make confidently: lines whose OCR matches
    ## something we queued ourselves this meeting.
    speakerColor*: int                  ## color index or -1 unknown
    line*: string
    tickObserved*: int
    mine*: bool                         ## true if this was our own msg

  LlmRequestSlot* = object
    ## One outgoing LLM request waiting to be dequeued by the Python
    ## wrapper. `pending = false` means the slot is empty (either
    ## never filled or already consumed).
    pending*: bool
    callKind*: LlmCallKind
    stage*: LlmVotingStage
    contextJson*: string                ## full JSON context + schema
    contextBytes*: int                  ## byte size of `contextJson` at
                                        ## dispatch time; preserved even
                                        ## after `llmTakePendingRequest`
                                        ## clears `contextJson` so the
                                        ## trace decision event can
                                        ## record the original size.
    dispatchedTick*: int                ## bot.frameTick when queued
    dispatchedWallMs*: int64            ## wall-clock ms when queued; used by
                                        ## trace to compute real-time latency
                                        ## (frame ticks at 24 fps are too
                                        ## coarse for provider RTT).

  LlmVotingState* = object
    ## Per-meeting LLM state machine. Lifetime mirrors `VotingState` —
    ## `onMeetingStart` populates from empty; `onMeetingEnd` resets to
    ## `lvsIdle`.
    stage*: LlmVotingStage
    # Crewmate branch
    hypothesis*: LlmHypothesis
    # Imposter branch
    imposterStrategy*: LlmImposterStrategy
    # Shared
    voteTarget*: int                    ## color index; -1 = not decided
    chatHistory*: seq[LlmChatEntry]
    myStatements*: seq[string]          ## our own queued lines
    seenLines*: seq[string]             ## normalized seen-set for dedup
    lastReactionTick*: int              ## rate-limit gate
    request*: LlmRequestSlot            ## the single in-flight request slot
    hasUnreadChat*: bool                ## new lines observed since last react
    meetingStartTick*: int              ## copy of voting.startTick on entry
    enabled*: bool                      ## flipped by the FFI when Python
                                        ## confirms it will service requests
                                        ## (see modulabot_enable_llm). Without
                                        ## this the state machine stays Idle.

  LlmMockEntry* = object
    ## One scripted LLM response for deterministic testing
    ## (Sprint 3.1). Consumed in strict FIFO order by `llmMockPump`
    ## — a `kind` mismatch between the pending request and the next
    ## entry is treated as a fixture authoring error, not a
    ## recoverable case. The mock loader is lenient: unknown fields
    ## are ignored so fixture files can carry annotations the bot
    ## doesn't need.
    kind*: LlmCallKind
    responseJson*: string               ## stringified JSON the bot
                                        ## would have received from
                                        ## the provider; empty when
                                        ## `errored = true`.
    errored*: bool

  LlmMock* = object
    ## Scripted-response queue. `enabled` is flipped by
    ## `llmMockEnable`; when true, `tickLlmVoting` short-circuits
    ## each pending dispatch by calling `onLlmResponse` with the
    ## next fixture entry. This bypasses the Python wrapper and
    ## the real provider, keeping regression tests fully
    ## deterministic (Sprint 3.1, 3.2).
    enabled*: bool
    entries*: seq[LlmMockEntry]
    cursor*: int                        ## next entry index to consume
    mismatchCount*: int                 ## diagnostic — expected-vs-actual
                                        ## kind mismatches seen this session

  LlmSessionCounters* = object
    ## Session-lifetime tally of LLM activity. Unlike
    ## `ManifestCounters` (per-round), these accumulate across the
    ## whole process lifetime so the harness can see totals even if
    ## a single round has little LLM activity. Zeroed at `initBot`
    ## and never reset; printed into every round manifest under
    ## `summary_counters.llm` (the manifest carries a point-in-time
    ## snapshot).
    totalDispatched*: int               ## dispatchCall invocations
    totalCompleted*: int                ## onLlmResponse errored=false
    totalErrored*: int                  ## onLlmResponse errored=true or
                                        ## parse/validation failure
    totalFallbacks*: int                ## times the state machine degraded
                                        ## to evidenceBasedSuspect
    totalChatQueued*: int               ## LLM-generated lines that reached
                                        ## ChatState.pendingChat
    byKindDispatched*: array[LlmCallKind, int]
    byKindCompleted*: array[LlmCallKind, int]
    byKindErrored*: array[LlmCallKind, int]

  LlmState* = object
    ## Process-lifetime LLM bookkeeping. Distinct from
    ## `LlmVotingState` which is per-meeting. Populated by
    ## `llmEnable` at FFI init and touched by `dispatchCall` /
    ## `onLlmResponse` for counter maintenance.
    ##
    ## LLM_VOTING.md §7.6 also described an `LlmConfig` (provider,
    ## model, timeouts). Deferred to Sprint 5 — the Python wrapper
    ## currently owns provider selection end-to-end and the Nim side
    ## doesn't need to know yet.
    counters*: LlmSessionCounters
    layerActiveAckTick*: int            ## bot.frameTick when Python called
                                        ## modulabot_enable_llm; -1 if never
    mock*: LlmMock                      ## deterministic scripted-response
                                        ## queue (Sprint 3.1). `mock.enabled`
                                        ## short-circuits real dispatch.

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
    chatLines*: seq[VoteChatLine]         ## per-line OCR cache + attributed
                                          ## speakers; populated alongside
                                          ## chatText. Used by the trace
                                          ## writer and `llm.nim` without a
                                          ## second OCR pass.
    resultEjected*: int                   ## Result-frame detection (Sprint
                                          ## 2.4). -1 = not yet detected /
                                          ## unknown, -2 = skipped ("NO ONE
                                          ## DIED"), otherwise the ejected
                                          ## player's color index. Populated
                                          ## by `detectResultEjection` on the
                                          ## first post-vote interstitial
                                          ## frame; consumed by the meeting
                                          ## finalizer in `bot.nim`. Survives
                                          ## `clearVotingState` (cleared only
                                          ## on round reset) so the value is
                                          ## still readable at MeetingEvent
                                          ## append time.
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
    # Memory shadow — last-observed length of the round-lifetime
    # body log, used by trace to detect new appends in O(1).
    # Replaces v1's `prevBodyWorldPositions` diff state
    # (DESIGN.md §13.6). `meeting_ended` is still emitted from the
    # interstitial-edge detector (voting.active true→false), which
    # happens in the same frame as the `memory.appendMeeting`
    # call, so a separate meeting-growth shadow is unnecessary.
    prevBodiesCount*: int
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
    # LLM layer awareness. `llmCompiledIn` is set once at
    # `openTrace` based on `when defined(modTalksLlm)`; `llmLayerActive`
    # is flipped by `setLlmLayerActive` when the FFI
    # `modulabot_enable_llm` fires. Both appear in the manifest under
    # `trace_settings` so the harness can trivially slice runs.
    llmCompiledIn*: bool
    llmLayerActive*: bool
    # Sprint 5.1 — optional dump of every dispatched LLM context to
    # disk under `<round_dir>/llm_contexts/`. Used by the prompt-eval
    # harness. Off by default; flipped on by `MODTALKS_LLM_CAPTURE=1`
    # at trace-writer construction.
    captureLlmContexts*: bool
    llmCaptureSeq*: int                   ## monotonic counter for
                                          ## llm_contexts/ filenames

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
    memory*: Memory
    imposter*: ImposterState
    voting*: VotingState
    chat*: ChatState
    llmVoting*: LlmVotingState            ## LLM voting state machine
                                          ## (LLM_VOTING.md). Populated
                                          ## regardless of -d:modTalksLlm;
                                          ## the gate is on call sites.
    llm*: LlmState                        ## Process-lifetime LLM counters +
                                          ## layer-active ack. Populated
                                          ## unconditionally; observers must
                                          ## check `trace.llmCompiledIn` to
                                          ## know whether any non-zero
                                          ## counter value is meaningful.
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

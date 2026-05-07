type
  TileKnowledge = enum
    TileUnknown
    TileOpen
    TileWall

  CameraLock = enum
    NoLock
    LocalFrameMapLock
    FrameMapLock

  TaskState = enum
    TaskNotDoing
    TaskMaybe
    TaskMandatory
    TaskCompleted

  BotRole = enum
    RoleUnknown
    RoleCrewmate
    RoleImposter

  PathNode = object
    priority: int
    index: int

  PathStep = object
    found: bool
    x: int
    y: int

  CameraScore = object
    score: int
    errors: int
    compared: int

  PatchEntry = object
    hash: uint64
    cameraX: int
    cameraY: int

  PatchCandidate = object
    votes: int
    cameraX: int
    cameraY: int

  RadarDot = object
    x: int
    y: int

  IconMatch = object
    x: int
    y: int

  CrewmateMatch = object
    x: int
    y: int
    colorIndex: int
    flipH: bool

  BodyMatch = object
    x: int
    y: int

  GhostMatch = object
    x: int
    y: int
    flipH: bool

  VoteSlot = object
    colorIndex: int
    alive: bool

  Bot = object
    sim: SimServer
    playerSprite: Sprite
    bodySprite: Sprite
    ghostSprite: Sprite
    taskSprite: Sprite
    killButtonSprite: Sprite
    ghostIconSprite: Sprite
    rng: Rand
    role: BotRole
    isGhost: bool
    ghostIconFrames: int
    imposterKillReady: bool
    imposterGoalIndex: int
    # Follow-and-fake-task state for the imposter.
    # imposterFolloweeColor: color index of the crewmate we're currently
    #   tailing, or -1 if none. We hold this color until the swap window
    #   elapses or the followee leaves view.
    # imposterFolloweeSinceTick: tick we started following the current
    #   followee. Combined with ImposterFollowSwapMinTicks to gate swaps.
    # imposterFakeTaskIndex: task index the imposter is fake-doing, or -1.
    # imposterFakeTaskUntilTick: tick at which the current fake-task ends.
    # imposterFakeTaskCooldownTick: tick before which we won't start another
    #   fake task (prevents back-to-back fake-tasking that looks robotic).
    # imposterPrevNearTaskIndex: task index we were within fake-task radius
    #   of last frame, or -1. We only roll the start-fake-task die on the
    #   tick we *enter* a task's radius, not every frame we're inside it.
    imposterFolloweeColor: int
    imposterFolloweeSinceTick: int
    imposterFakeTaskIndex: int
    imposterFakeTaskUntilTick: int
    imposterFakeTaskCooldownTick: int
    imposterPrevNearTaskIndex: int
    # Self-report state. When the imposter presses A on a lone crewmate we
    # remember (tick, world position) so the next frame's body-visible
    # branch can recognise "this is the body I just made" and prefer
    # reporting it over fleeing.
    imposterLastKillTick: int
    imposterLastKillX: int
    imposterLastKillY: int
    packed: seq[uint8]
    unpacked: seq[uint8]
    mapTiles: seq[TileKnowledge]
    patchEntries: seq[PatchEntry]
    patchVotes: seq[uint16]
    patchTouched: seq[int]
    patchCandidates: seq[PatchCandidate]
    cameraX: int
    cameraY: int
    lastCameraX: int
    lastCameraY: int
    cameraLock: CameraLock
    cameraScore: int
    localized: bool
    interstitial: bool
    interstitialText: string
    lastGameOverText: string
    gameStarted: bool
    homeSet: bool
    homeX: int
    homeY: int
    haveMotionSample: bool
    previousPlayerWorldX: int
    previousPlayerWorldY: int
    velocityX: int
    velocityY: int
    stuckFrames: int
    jiggleTicks: int
    jiggleSide: int
    desiredMask: uint8
    controllerMask: uint8
    taskHoldTicks: int
    taskHoldIndex: int
    frameTick: int
    centerMicros: int
    spriteScanMicros: int
    localizeLocalMicros: int
    localizePatchMicros: int
    localizeSpiralMicros: int
    astarMicros: int
    queuedFrames: seq[string]
    frameBufferLen: int
    framesDropped: int
    skippedFrames: int
    lastMask: uint8
    lastThought: string
    pendingChat: string
    lastBodySeenX: int
    lastBodySeenY: int
    lastBodyReportX: int
    lastBodyReportY: int
    lastSeenTicks: array[PlayerColorCount, int]
    selfColorIndex: int
    knownImposters: array[PlayerColorCount, bool]
    # Evidence tracking for the crewmate accusation policy.
    # nearBodyTicks[ci]      = last frameTick a non-self color was seen
    #                          within WitnessNearBodyRadius of any visible body
    # witnessedKillTicks[ci] = same, but only at the frame a body first appears
    #                          (likely killer)
    # prevVisibleCrewmate{X,Y} = last frame's per-color crewmate world position,
    #                            -1 if not visible last frame; used to recognise
    #                            "fresh body next to where colorN was"
    # prevVisibleBodies      = last frame's body world positions, for new-body
    #                          detection
    nearBodyTicks: array[PlayerColorCount, int]
    witnessedKillTicks: array[PlayerColorCount, int]
    prevVisibleCrewmateX: array[PlayerColorCount, int]
    prevVisibleCrewmateY: array[PlayerColorCount, int]
    prevVisibleBodies: seq[tuple[x: int, y: int]]
    voting: bool
    votePlayerCount: int
    voteCursor: int
    voteSelfSlot: int
    voteTarget: int
    voteStartTick: int
    voteChatSusColor: int
    voteChatText: string
    voteSlots: array[MaxPlayers, VoteSlot]
    voteChoices: array[PlayerColorCount, int]
    intent: string
    goalX: int
    goalY: int
    goalIndex: int
    goalName: string
    hasGoal: bool
    hasPathStep: bool
    pathStep: PathStep
    path: seq[PathStep]
    radarDots: seq[RadarDot]
    radarTasks: seq[bool]
    checkoutTasks: seq[bool]
    taskStates: seq[TaskState]
    taskIconMisses: seq[int]
    # v2: per-task latch. Set true once we've definitively resolved a task
    # this round — either confirmed it isn't ours (clear-view inspection
    # with no icon) or completed it ourselves. Resolved tasks are skipped
    # by `updateTaskGuesses` so radar projection ambiguity can't re-flag
    # them; the bot will never visit the same station twice looking for
    # work that isn't there.
    taskResolved: seq[bool]
    visibleTaskIcons: seq[IconMatch]
    visibleCrewmates: seq[CrewmateMatch]
    visibleBodies: seq[BodyMatch]
    visibleGhosts: seq[GhostMatch]

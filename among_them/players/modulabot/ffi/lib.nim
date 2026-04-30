## FFI exports for the CoGames training harness.
##
## Phase 0: handles + dimensions are validated, but `step_batch` writes
## "idle" (action 0) for every agent because `decideNextMask` returns 0.
## Phase 1 doesn't need to change this file at all — once
## `decideNextMask` returns real masks, the existing `actionIndexForMask`
## lookup will translate them into the action table.
##
## Symbol prefix is `modulabot_*` (Q3 in the FFI naming question
## resolved). The Python side picks up the new policy by adding an entry
## pointing at these symbols; existing `nottoodumb_*` builds are
## untouched.

when defined(modulabotLibrary):
  import std/strutils
  import protocol      # for Button* constants, ScreenWidth/Height
  import ../types
  import ../bot
  import ../trace

  const ModulabotAbiVersion* = 1
    ## Bumped whenever the FFI surface (symbols, signatures, action table)
    ## changes. The Python wrapper checks this against its own constant and
    ## refuses to load a mismatched library. Keep in sync with
    ## `build_modulabot.py:MODULABOT_ABI_VERSION`.

  const TrainableMasks = [
    0'u8,
    ButtonA,
    ButtonB,
    ButtonUp,
    ButtonDown,
    ButtonLeft,
    ButtonRight,
    ButtonUp or ButtonA,
    ButtonDown or ButtonA,
    ButtonLeft or ButtonA,
    ButtonRight or ButtonA,
    ButtonUp or ButtonB,
    ButtonDown or ButtonB,
    ButtonLeft or ButtonB,
    ButtonRight or ButtonB,
    ButtonUp or ButtonLeft,
    ButtonUp or ButtonRight,
    ButtonDown or ButtonLeft,
    ButtonDown or ButtonRight,
    ButtonUp or ButtonLeft or ButtonA,
    ButtonUp or ButtonRight or ButtonA,
    ButtonDown or ButtonLeft or ButtonA,
    ButtonDown or ButtonRight or ButtonA,
    ButtonUp or ButtonLeft or ButtonB,
    ButtonUp or ButtonRight or ButtonB,
    ButtonDown or ButtonLeft or ButtonB,
    ButtonDown or ButtonRight or ButtonB,
  ]

  type ModulabotPolicy = ref object
    bots: seq[Bot]

  var ModulabotPolicies: seq[ModulabotPolicy]

  proc actionIndexForMask(mask: uint8): int32 =
    for i, m in TrainableMasks:
      if m == mask:
        return int32(i)
    int32(0)

  proc stepUnpackedFramePtr(bot: var Bot, frame: ptr UncheckedArray[uint8],
                            frameLen: int): uint8 =
    if frame.isNil or frameLen != ScreenWidth * ScreenHeight:
      return bot.io.lastMask
    if bot.io.unpacked.len != frameLen:
      bot.io.unpacked.setLen(frameLen)
    for i in 0 ..< frameLen:
      bot.io.unpacked[i] = frame[i] and 0x0f
    inc bot.frameTick
    result = bot.decideNextMask()
    bot.io.lastMask = result

  proc modulabot_abi_version*(): cint {.exportc, dynlib.} =
    ## Returns the shared-library ABI version expected by Python wrappers.
    cint(ModulabotAbiVersion)

  # Trace-init plumbing for the Python harness. Optional: callers that
  # want tracing call `modulabot_init_trace` BEFORE `modulabot_new_policy`,
  # and the new policy will attach a trace writer per agent.
  type TraceInit = object
    rootDir: string
    level: TraceLevel
    snapshotPeriod: int
    captureFrames: bool
    harnessMeta: string

  var PendingTraceInit: TraceInit
  var TraceInitArmed = false

  proc parseTraceLevelInt(level: cint): TraceLevel =
    case int(level)
    of 0: tlOff
    of 1: tlEvents
    of 2: tlDecisions
    of 3: tlFull
    else: tlDecisions

  proc modulabot_init_trace*(
      rootDir: cstring,
      level: cint,
      snapshotPeriod: cint,
      captureFrames: cint,
      harnessMeta: cstring): cint {.exportc, dynlib.} =
    ## Arms a pending trace configuration. The next call to
    ## `modulabot_new_policy` will attach a trace writer (with one
    ## independent `TraceWriter` per agent) using these settings.
    ## Returns 0 on success, non-zero on failure (e.g. unset rootDir).
    if rootDir.isNil:
      return 1
    let root = $rootDir
    if root.len == 0:
      return 1
    PendingTraceInit = TraceInit(
      rootDir:        root,
      level:          parseTraceLevelInt(level),
      snapshotPeriod: max(0, int(snapshotPeriod)),
      captureFrames:  captureFrames != 0,
      harnessMeta:    (if harnessMeta.isNil: "" else: $harnessMeta)
    )
    TraceInitArmed = true
    cint(0)

  proc attachTraceForAgent(bot: var Bot, agentIndex: int) =
    if not TraceInitArmed: return
    if PendingTraceInit.level == tlOff: return
    bot.trace = openTrace(
      rootDir        = PendingTraceInit.rootDir,
      botName        = "ffi-agent-" & intToStr(agentIndex, 3),
      level          = PendingTraceInit.level,
      snapshotPeriod = PendingTraceInit.snapshotPeriod,
      captureFrames  = PendingTraceInit.captureFrames,
      harnessMeta    = PendingTraceInit.harnessMeta,
      masterSeed     = 0,
      framesPath     = "",
      configJson     = """{"transport":"ffi"}"""
    )
    bot.trace.beginRound(bot, isMidRound = false)

  proc modulabot_new_policy*(numAgents: cint): cint {.exportc, dynlib.} =
    ## Creates a persistent Nim-backed Modulabot policy and returns its handle.
    let count = max(1, int(numAgents))
    var policy = ModulabotPolicy(bots: newSeq[Bot](count))
    for i in 0 ..< count:
      policy.bots[i] = initBot()
      attachTraceForAgent(policy.bots[i], i)
    ModulabotPolicies.add(policy)
    cint(ModulabotPolicies.len - 1)

  proc modulabot_step_batch*(
    handle: cint,
    agentIds: ptr UncheckedArray[int32],
    numAgentIds: cint,
    numAgents: cint,
    frameStack: cint,
    height: cint,
    width: cint,
    observations: pointer,
    actions: pointer
  ) {.exportc, dynlib.} =
    ## Steps a batch of unpacked pixel observations into action indices.
    if handle < 0 or int(handle) >= ModulabotPolicies.len:
      return
    if observations.isNil or actions.isNil or agentIds.isNil:
      return
    if frameStack <= 0 or height != ScreenHeight or width != ScreenWidth:
      return

    let
      policy = ModulabotPolicies[int(handle)]
      obs = cast[ptr UncheckedArray[uint8]](observations)
      outs = cast[ptr UncheckedArray[int32]](actions)
      frameLen = int(height) * int(width)
      rowStride = int(frameStack) * frameLen
      latestOffset = (int(frameStack) - 1) * frameLen

    if policy.bots.len < int(numAgents):
      let oldLen = policy.bots.len
      policy.bots.setLen(int(numAgents))
      for i in oldLen ..< policy.bots.len:
        policy.bots[i] = initBot()
        attachTraceForAgent(policy.bots[i], i)

    for row in 0 ..< int(numAgentIds):
      let agentId = int(agentIds[row])
      if agentId < 0 or agentId >= policy.bots.len:
        outs[row] = 0
        continue
      let frame = cast[ptr UncheckedArray[uint8]](
        cast[uint](obs) + uint(row * rowStride + latestOffset)
      )
      let mask = policy.bots[agentId].stepUnpackedFramePtr(frame, frameLen)
      outs[row] = actionIndexForMask(mask)

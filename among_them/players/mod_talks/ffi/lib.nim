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
  when defined(modTalksLlm):
    import ../llm

  const ModulabotAbiVersion* = 3
    ## Bumped whenever the FFI surface (symbols, signatures, action table)
    ## changes. The Python wrapper checks this against its own constant and
    ## refuses to load a mismatched library. Keep in sync with
    ## `build_modulabot.py:MODULABOT_ABI_VERSION`.
    ##
    ## v3 (2026-04-30): added the `frameAdvances` pointer parameter to
    ## `modulabot_step_batch`, matching the nottoodumb calling convention
    ## (the Python wrapper was passing this argument in v1/v2 but the Nim
    ## side silently ignored it, corrupting the observations pointer
    ## alignment and freezing all bots at noop). Existing v2 binaries
    ## must be rebuilt.
    ##
    ## v2 (LLM voting integration): added `modulabot_take_chat`,
    ## `modulabot_enable_llm`, `modulabot_take_llm_request`,
    ## `modulabot_set_llm_response`. All four are safe to call against
    ## a non-LLM build — they no-op when `-d:modTalksLlm` is not set.

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
                            frameLen: int; frameAdvance: int = 1): uint8 =
    if frame.isNil or frameLen != ScreenWidth * ScreenHeight:
      return bot.io.lastMask
    if bot.io.unpacked.len != frameLen:
      bot.io.unpacked.setLen(frameLen)
    for i in 0 ..< frameLen:
      bot.io.unpacked[i] = frame[i] and 0x0f
    # frame_advance > 1 means we're processing a frame that's `advance`
    # ticks newer than the last one we saw (bitworld_runner drained a
    # burst of queued frames). Advance frameTick by that much to keep
    # tick-based timers (kill cooldown, vote listen window, lastSeenTick)
    # in sync with the game's real clock. Velocity inference is
    # compensated in `updateMotionState` via `motion.frameAdvance`.
    let advance = max(1, frameAdvance)
    bot.frameTick += advance
    bot.motion.frameAdvance = advance
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
    frameAdvances: pointer,
    observations: pointer,
    actions: pointer
  ) {.exportc, dynlib.} =
    ## Steps a batch of unpacked pixel observations into action indices.
    ##
    ## `frameAdvances` is a `cint` array of length `numAgentIds` telling us
    ## how many game ticks to advance each agent by. The cogames BitWorld
    ## runner may deliver frames at a rate different from 1-per-call when
    ## websocket traffic bursts or stalls. mod_talks uses this to keep
    ## `bot.frameTick` in sync with real game time (so tick-based timers
    ## like kill cooldown and voting listen windows don't drift) and to
    ## compensate motion-inferred velocity (so a 5-tick burst doesn't
    ## look like a 5x teleport).
    ##
    ## **Invariant: this signature must stay in lockstep with the Python
    ## wrapper in `cogames/amongthem_policy.py`.** An earlier version of
    ## this FFI omitted `frameAdvances` while the Python side still passed
    ## it, which silently corrupted the `observations` argument alignment
    ## (Nim read the frame_advances int32 array as pixel data, froze all
    ## bots at noop). Fixed 2026-04-30.
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

    let advancesPtr =
      if frameAdvances.isNil: nil
      else: cast[ptr UncheckedArray[int32]](frameAdvances)
    for row in 0 ..< int(numAgentIds):
      let agentId = int(agentIds[row])
      if agentId < 0 or agentId >= policy.bots.len:
        outs[row] = 0
        continue
      let frame = cast[ptr UncheckedArray[uint8]](
        cast[uint](obs) + uint(row * rowStride + latestOffset)
      )
      let advance =
        if advancesPtr.isNil: 1
        else: int(advancesPtr[row])
      let mask = policy.bots[agentId].stepUnpackedFramePtr(frame, frameLen, advance)
      outs[row] = actionIndexForMask(mask)

  # --------------------------------------------------------------------
  # Chat + LLM plumbing
  # --------------------------------------------------------------------
  #
  # Four entry points, all safe to call regardless of whether the
  # library was built with `-d:modTalksLlm`. In the non-LLM build they
  # return sentinel "nothing to do" values, so the Python wrapper can
  # call them unconditionally without breaking parity-path behaviour.

  proc copyToBuffer(text: string, buffer: pointer, bufferLen: cint): cint =
    ## Copies up to `bufferLen - 1` bytes from `text` into the
    ## caller-provided buffer, NUL-terminates, and returns the written
    ## length (excluding NUL). Returns 0 when there's nothing to copy.
    if buffer.isNil or bufferLen <= 0 or text.len == 0:
      return cint(0)
    let dst = cast[ptr UncheckedArray[byte]](buffer)
    let maxLen = min(text.len, int(bufferLen) - 1)
    for i in 0 ..< maxLen:
      dst[i] = byte(text[i])
    dst[maxLen] = 0
    cint(maxLen)

  proc modulabot_take_chat*(
      handle: cint,
      agentId: cint,
      buffer: pointer,
      bufferLen: cint): cint {.exportc, dynlib.} =
    ## Drains one chat message from the agent's `ChatState.pendingChat`
    ## if one is queued. Writes an ASCII string into `buffer` (NUL-
    ## terminated) and returns its length. Returns 0 when nothing is
    ## queued.
    ##
    ## Matches the shape of `nottoodumb_take_chat` so the Python
    ## wrapper's code path is identical.
    ##
    ## This is available in every build — non-LLM builds can still
    ## produce chat via the existing body-report template path
    ## (`chat.nim`).
    if handle < 0 or int(handle) >= ModulabotPolicies.len:
      return cint(0)
    let policy = ModulabotPolicies[int(handle)]
    if int(agentId) < 0 or int(agentId) >= policy.bots.len:
      return cint(0)
    let text = policy.bots[int(agentId)].chat.pendingChat
    if text.len == 0:
      return cint(0)
    let written = copyToBuffer(text, buffer, bufferLen)
    # Drain the queue atomically — once the caller has taken it, we
    # never re-emit the same line (matches the semantics of
    # ChatState.pendingChat being consumed on send).
    policy.bots[int(agentId)].chat.pendingChat = ""
    written

  proc modulabot_enable_llm*(
      handle: cint,
      agentId: cint): cint {.exportc, dynlib.} =
    ## Called once by the Python wrapper at load time to confirm the
    ## LLM layer is available (provider client constructed, credentials
    ## valid). Flips `llmVoting.enabled = true`. Returns 0 on success
    ## even in non-LLM builds — the call is a no-op there and the
    ## return value just tells Python "ack received".
    if handle < 0 or int(handle) >= ModulabotPolicies.len:
      return cint(1)
    let policy = ModulabotPolicies[int(handle)]
    if int(agentId) < 0 or int(agentId) >= policy.bots.len:
      return cint(1)
    when defined(modTalksLlm):
      llmEnable(policy.bots[int(agentId)])
    cint(0)

  proc modulabot_take_llm_request*(
      handle: cint,
      agentId: cint,
      kindBuffer: pointer,
      kindBufferLen: cint,
      contextBuffer: pointer,
      contextBufferLen: cint): cint {.exportc, dynlib.} =
    ## Atomically dequeues any pending LLM request for the agent.
    ## Writes the call-kind name (e.g. `"hypothesis"`, `"accuse"`,
    ## `"imposter_react"`) into `kindBuffer` and the JSON context into
    ## `contextBuffer`, both NUL-terminated. Returns the length of the
    ## context written, or 0 when no request is pending.
    ##
    ## The request slot flips to "in-flight" on dequeue; the matching
    ## `modulabot_set_llm_response` call must be made (with errored=1
    ## on HTTP failure) before the state machine will dispatch another
    ## request. This mirrors the LlmCall semantics from LLM_VOTING.md
    ## §6 without the thread/channel plumbing.
    ##
    ## No-op in non-LLM builds.
    if handle < 0 or int(handle) >= ModulabotPolicies.len:
      return cint(0)
    let policy = ModulabotPolicies[int(handle)]
    if int(agentId) < 0 or int(agentId) >= policy.bots.len:
      return cint(0)
    when defined(modTalksLlm):
      let taken = llmTakePendingRequest(policy.bots[int(agentId)])
      if taken.kind == lckNone:
        return cint(0)
      discard copyToBuffer(llmCallKindName(taken.kind), kindBuffer, kindBufferLen)
      return copyToBuffer(taken.contextJson, contextBuffer, contextBufferLen)
    else:
      cint(0)

  proc modulabot_set_llm_response*(
      handle: cint,
      agentId: cint,
      kind: cstring,
      response: cstring,
      errored: cint): cint {.exportc, dynlib.} =
    ## Feeds an LLM response back into the state machine. `kind` must
    ## match the kind string returned by the earlier
    ## `modulabot_take_llm_request` call (the state machine uses it to
    ## validate we're applying the right response type to the current
    ## stage). `errored != 0` means the HTTP call failed / timed out /
    ## produced invalid JSON; the state machine falls back gracefully.
    ##
    ## No-op in non-LLM builds; returns 0.
    if handle < 0 or int(handle) >= ModulabotPolicies.len:
      return cint(1)
    let policy = ModulabotPolicies[int(handle)]
    if int(agentId) < 0 or int(agentId) >= policy.bots.len:
      return cint(1)
    when defined(modTalksLlm):
      let kindStr = if kind.isNil: "" else: $kind
      let respStr = if response.isNil: "" else: $response
      let parsed = parseLlmCallKind(kindStr)
      onLlmResponse(policy.bots[int(agentId)], parsed, respStr, errored != 0)
    cint(0)

  proc modulabot_role*(
      handle: cint,
      agentId: cint): cint {.exportc, dynlib.} =
    ## Returns the bot's inferred role. 0 = unknown/crewmate,
    ## 2 = imposter (match nottoodumb's enum so the Python wrapper
    ## can reuse the constant NOTTOODUMB_ROLE_IMPOSTER = 2).
    ## Useful for the Python wrapper to drive role-dependent logic
    ## (e.g. system prompt selection) without re-inspecting frames.
    if handle < 0 or int(handle) >= ModulabotPolicies.len:
      return cint(0)
    let policy = ModulabotPolicies[int(handle)]
    if int(agentId) < 0 or int(agentId) >= policy.bots.len:
      return cint(0)
    case policy.bots[int(agentId)].role
    of RoleImposter: cint(2)
    of RoleCrewmate: cint(1)
    of RoleUnknown:  cint(0)

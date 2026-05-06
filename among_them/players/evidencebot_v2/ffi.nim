when defined(evidencebotLibrary):
  const TrainableMasks = [
    0'u8,
    ButtonA,
    ButtonB,
    ButtonUp,
    ButtonUp or ButtonA,
    ButtonUp or ButtonB,
    ButtonDown,
    ButtonDown or ButtonA,
    ButtonDown or ButtonB,
    ButtonLeft,
    ButtonLeft or ButtonA,
    ButtonLeft or ButtonB,
    ButtonRight,
    ButtonRight or ButtonA,
    ButtonRight or ButtonB,
    ButtonUp or ButtonLeft,
    ButtonUp or ButtonLeft or ButtonA,
    ButtonUp or ButtonLeft or ButtonB,
    ButtonUp or ButtonRight,
    ButtonUp or ButtonRight or ButtonA,
    ButtonUp or ButtonRight or ButtonB,
    ButtonDown or ButtonLeft,
    ButtonDown or ButtonLeft or ButtonA,
    ButtonDown or ButtonLeft or ButtonB,
    ButtonDown or ButtonRight,
    ButtonDown or ButtonRight or ButtonA,
    ButtonDown or ButtonRight or ButtonB
  ]

  type NotTooDumbPolicy = ref object
    bots: seq[Bot]

  var NotTooDumbPolicies: seq[NotTooDumbPolicy]

  proc actionIndexForMask(mask: uint8): int32 =
    ## Maps a BitWorld button mask to the CoGames trainable action index.
    for i, value in TrainableMasks:
      if value == mask:
        return i.int32
    0'i32

  proc stepUnpackedFramePtr(
    bot: var Bot,
    frame: ptr UncheckedArray[uint8],
    frameLen: int
  ): uint8 =
    ## Steps the bot from one pointer-backed unpacked framebuffer.
    if frameLen != ScreenWidth * ScreenHeight:
      return 0
    if bot.unpacked.len != frameLen:
      bot.unpacked.setLen(frameLen)
    for i in 0 ..< frameLen:
      bot.unpacked[i] = frame[i] and 0x0f
    inc bot.frameTick
    result = bot.decideNextMask()
    bot.lastMask = result

  proc nottoodumb_new_policy*(numAgents: cint): cint {.exportc, dynlib.} =
    ## Creates a persistent Nim-backed NotTooDumb policy and returns its handle.
    let count = max(1, int(numAgents))
    var policy = NotTooDumbPolicy(bots: newSeq[Bot](count))
    for i in 0 ..< count:
      policy.bots[i] = initBot()
    NotTooDumbPolicies.add(policy)
    cint(NotTooDumbPolicies.len - 1)

  proc nottoodumb_step_batch*(
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
    ## Steps a batch of unpacked pixel observations into CoGames action indices.
    if handle < 0 or int(handle) >= NotTooDumbPolicies.len:
      return
    if observations.isNil or actions.isNil or agentIds.isNil:
      return
    if frameStack <= 0 or height != ScreenHeight or width != ScreenWidth:
      return

    let
      policy = NotTooDumbPolicies[int(handle)]
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

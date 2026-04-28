import ../common/protocol
import ../among_them/sim
import std/os

const
  FramePixels = ScreenWidth * ScreenHeight
  StepActive = 0.cint
  StepTerminal = 1.cint
  StepTruncated = 2.cint

type
  NativeEnv = ref object
    sim: SimServer
    inputs: seq[InputState]
    prevInputs: seq[InputState]
    rewardSnapshot: seq[int]
    renderStateScratch: seq[uint8]
    playerCount: int
    seed: int
    maxTicks: int
    imposterCount: int
    tasksPerPlayer: int
    taskCompleteTicks: int
    killCooldownTicks: int

var
  envs: seq[NativeEnv]
  lastError = ""

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir()

proc gameDir(): string =
  repoRoot() / "among_them"

proc setLastError(message: string): cint =
  lastError = message
  -1

proc validHandle(handle: cint): bool =
  handle >= 0 and int(handle) < envs.len and not envs[int(handle)].isNil

proc copyObservations(env: var NativeEnv, observations: ptr uint8) =
  if observations.isNil:
    raise newException(ValueError, "Observation pointer is nil.")

  let output = cast[ptr UncheckedArray[uint8]](observations)
  for playerIndex in 0 ..< env.playerCount:
    discard env.sim.render(playerIndex)
    if env.sim.fb.indices.len != FramePixels:
      raise newException(ValueError, "Unexpected Among Them frame size.")
    copyMem(
      addr output[playerIndex * FramePixels],
      unsafeAddr env.sim.fb.indices[0],
      FramePixels
    )

proc copyRewardDeltas(env: var NativeEnv, rewards: ptr cfloat, outputBase = 0) =
  if rewards.isNil:
    raise newException(ValueError, "Reward pointer is nil.")

  let output = cast[ptr UncheckedArray[cfloat]](rewards)
  for playerIndex in 0 ..< env.playerCount:
    let reward = env.sim.players[playerIndex].reward
    output[outputBase + playerIndex] = cfloat(reward - env.rewardSnapshot[playerIndex])
    env.rewardSnapshot[playerIndex] = reward

proc copyStateObservations(env: var NativeEnv, observations: ptr uint8, outputBase = 0) =
  if observations.isNil:
    raise newException(ValueError, "Observation pointer is nil.")

  if env.renderStateScratch.len != RenderStateFeatures:
    env.renderStateScratch = newSeq[uint8](RenderStateFeatures)
  let output = cast[ptr UncheckedArray[uint8]](observations)
  for playerIndex in 0 ..< env.playerCount:
    env.sim.writeRenderStateObservation(playerIndex, env.renderStateScratch)
    copyMem(
      addr output[outputBase + playerIndex * RenderStateFeatures],
      unsafeAddr env.renderStateScratch[0],
      RenderStateFeatures
    )

proc stepStatus(env: NativeEnv): cint =
  if env.sim.phase != GameOver:
    return StepActive
  if env.sim.timeLimitReached: StepTruncated
  else: StepTerminal

proc applyActionMasks(env: var NativeEnv, actionMasks: ptr uint8, actionRepeat: cint): cint =
  if actionMasks.isNil:
    raise newException(ValueError, "Action pointer is nil.")
  if actionRepeat <= 0:
    raise newException(ValueError, "actionRepeat must be positive.")

  let actions = cast[ptr UncheckedArray[uint8]](actionMasks)
  for _ in 0 ..< int(actionRepeat):
    for playerIndex in 0 ..< env.playerCount:
      env.prevInputs[playerIndex] = env.inputs[playerIndex]
      env.inputs[playerIndex] = decodeInputMask(actions[playerIndex])
    env.sim.step(env.inputs, env.prevInputs)
    result = env.stepStatus()
    if result != StepActive:
      return

proc addNativePlayers(env: var NativeEnv) =
  env.inputs = newSeq[InputState](env.playerCount)
  env.prevInputs = newSeq[InputState](env.playerCount)
  env.rewardSnapshot = newSeq[int](env.playerCount)
  for playerIndex in 0 ..< env.playerCount:
    discard env.sim.addPlayer("player" & $(playerIndex + 1))
  doAssert env.sim.players.len == env.playerCount
  env.sim.step(env.inputs, env.prevInputs)
  for playerIndex in 0 ..< env.playerCount:
    env.rewardSnapshot[playerIndex] = env.sim.players[playerIndex].reward

proc initNativeEnv(env: var NativeEnv) =
  let previousDir = getCurrentDir()
  setCurrentDir(gameDir())
  try:
    var config = defaultGameConfig()
    config.seed = env.seed
    config.maxTicks = env.maxTicks
    config.minPlayers = env.playerCount
    if env.imposterCount >= 0:
      config.imposterCount = env.imposterCount
    config.imposterCount = min(
      config.imposterCount,
      max(0, env.playerCount - 1)
    )
    if env.tasksPerPlayer >= 0:
      config.tasksPerPlayer = env.tasksPerPlayer
    if env.taskCompleteTicks >= 0:
      config.taskCompleteTicks = env.taskCompleteTicks
    if env.killCooldownTicks >= 0:
      config.killCooldownTicks = env.killCooldownTicks
    env.sim = initSimServer(config)
  finally:
    setCurrentDir(previousDir)
  env.addNativePlayers()

proc resetNativeEnv(env: var NativeEnv) =
  env.sim.resetToLobby()
  env.sim.rewardAccounts = @[]
  env.sim.voteState = VoteState(ejectedPlayer: -1)
  env.sim.winner = Crewmate
  env.sim.gameOverTimer = 0
  env.addNativePlayers()

proc bitworld_at_last_error*(): cstring {.cdecl, exportc, dynlib.} =
  lastError.cstring

proc bitworld_at_tick_count*(handle: cint): cint {.cdecl, exportc, dynlib.} =
  if validHandle(handle):
    return cint(envs[int(handle)].sim.tickCount)
  setLastError("Invalid Among Them native env handle.")

proc bitworld_at_game_hash*(handle: cint): uint64 {.cdecl, exportc, dynlib.} =
  if validHandle(handle):
    return envs[int(handle)].sim.gameHash()
  discard setLastError("Invalid Among Them native env handle.")

proc bitworld_at_create*(
  seed, playerCount, maxTicks: cint,
  imposterCount, tasksPerPlayer, taskCompleteTicks, killCooldownTicks: cint
): cint {.cdecl, exportc, dynlib.} =
  try:
    if playerCount <= 0:
      return setLastError("playerCount must be positive.")
    if playerCount > MaxPlayers:
      return setLastError("playerCount must be <= " & $MaxPlayers & ".")
    if maxTicks < 0:
      return setLastError("maxTicks must be non-negative.")

    var env = NativeEnv(
      seed: int(seed),
      playerCount: int(playerCount),
      maxTicks: int(maxTicks),
      imposterCount: int(imposterCount),
      tasksPerPlayer: int(tasksPerPlayer),
      taskCompleteTicks: int(taskCompleteTicks),
      killCooldownTicks: int(killCooldownTicks),
    )
    env.initNativeEnv()
    envs.add(env)
    cint(envs.high)
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_reset*(
  handle: cint,
  observations: ptr uint8,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if not validHandle(handle):
      return setLastError("Invalid Among Them native env handle.")

    var env = envs[int(handle)]
    env.resetNativeEnv()
    env.copyObservations(observations)
    let output = cast[ptr UncheckedArray[cfloat]](rewards)
    for playerIndex in 0 ..< env.playerCount:
      output[playerIndex] = 0.0
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_reset_state*(
  handle: cint,
  observations: ptr uint8,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if not validHandle(handle):
      return setLastError("Invalid Among Them native env handle.")

    var env = envs[int(handle)]
    env.resetNativeEnv()
    env.copyStateObservations(observations)
    let output = cast[ptr UncheckedArray[cfloat]](rewards)
    for playerIndex in 0 ..< env.playerCount:
      output[playerIndex] = 0.0
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_step*(
  handle: cint,
  actionMasks: ptr uint8,
  actionRepeat: cint,
  observations: ptr uint8,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if not validHandle(handle):
      return setLastError("Invalid Among Them native env handle.")

    var env = envs[int(handle)]
    let status = env.applyActionMasks(actionMasks, actionRepeat)
    env.copyObservations(observations)
    env.copyRewardDeltas(rewards)
    status
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_step_state*(
  handle: cint,
  actionMasks: ptr uint8,
  actionRepeat: cint,
  observations: ptr uint8,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if not validHandle(handle):
      return setLastError("Invalid Among Them native env handle.")

    var env = envs[int(handle)]
    let status = env.applyActionMasks(actionMasks, actionRepeat)
    env.copyStateObservations(observations)
    env.copyRewardDeltas(rewards)
    status
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_reset_state_batch*(
  handles: ptr cint,
  envCount: cint,
  playerCount: cint,
  observations: ptr uint8,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if handles.isNil:
      return setLastError("Handle pointer is nil.")
    if envCount <= 0:
      return setLastError("envCount must be positive.")
    if playerCount <= 0:
      return setLastError("playerCount must be positive.")
    if playerCount > MaxPlayers:
      return setLastError("playerCount must be <= " & $MaxPlayers & ".")

    let
      playerCountInt = int(playerCount)
      handleArray = cast[ptr UncheckedArray[cint]](handles)
      rewardOutput = cast[ptr UncheckedArray[cfloat]](rewards)
    for envIndex in 0 ..< int(envCount):
      if not validHandle(handleArray[envIndex]):
        return setLastError("Invalid Among Them native env handle.")
      var env = envs[int(handleArray[envIndex])]
      if env.playerCount != playerCountInt:
        return setLastError("Unexpected player count in batch reset.")
      env.resetNativeEnv()
      let outputBase = envIndex * playerCountInt
      env.copyStateObservations(observations, outputBase * RenderStateFeatures)
      for playerIndex in 0 ..< playerCountInt:
        rewardOutput[outputBase + playerIndex] = 0.0
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_step_state_batch*(
  handles: ptr cint,
  envCount: cint,
  playerCount: cint,
  actionMasks: ptr uint8,
  actionRepeat: cint,
  statuses: ptr cint,
  observations: ptr uint8,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if handles.isNil:
      return setLastError("Handle pointer is nil.")
    if actionMasks.isNil:
      return setLastError("Action pointer is nil.")
    if statuses.isNil:
      return setLastError("Status pointer is nil.")
    if envCount <= 0:
      return setLastError("envCount must be positive.")
    if playerCount <= 0:
      return setLastError("playerCount must be positive.")
    if playerCount > MaxPlayers:
      return setLastError("playerCount must be <= " & $MaxPlayers & ".")

    let
      playerCountInt = int(playerCount)
      handleArray = cast[ptr UncheckedArray[cint]](handles)
      actions = cast[ptr UncheckedArray[uint8]](actionMasks)
      statusOutput = cast[ptr UncheckedArray[cint]](statuses)
    for envIndex in 0 ..< int(envCount):
      if not validHandle(handleArray[envIndex]):
        return setLastError("Invalid Among Them native env handle.")
      var env = envs[int(handleArray[envIndex])]
      if env.playerCount != playerCountInt:
        return setLastError("Unexpected player count in batch step.")
      let outputBase = envIndex * playerCountInt
      statusOutput[envIndex] = env.applyActionMasks(
        cast[ptr uint8](addr actions[outputBase]),
        actionRepeat
      )
      env.copyStateObservations(observations, outputBase * RenderStateFeatures)
      env.copyRewardDeltas(rewards, outputBase)
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_observe_state*(
  handle: cint,
  observations: ptr uint8
): cint {.cdecl, exportc, dynlib.} =
  try:
    if not validHandle(handle):
      return setLastError("Invalid Among Them native env handle.")

    var env = envs[int(handle)]
    env.copyStateObservations(observations)
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_step_rewards*(
  handle: cint,
  actionMasks: ptr uint8,
  actionRepeat: cint,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if not validHandle(handle):
      return setLastError("Invalid Among Them native env handle.")

    var env = envs[int(handle)]
    let status = env.applyActionMasks(actionMasks, actionRepeat)
    env.copyRewardDeltas(rewards)
    status
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_close*(handle: cint) {.cdecl, exportc, dynlib.} =
  if validHandle(handle):
    envs[int(handle)] = nil

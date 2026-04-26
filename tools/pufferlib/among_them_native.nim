import ../../common/protocol
import ../../among_them/sim
import std/os

const
  FramePixels = ScreenWidth * ScreenHeight
  StateFeatures* = 96

type
  NativeEnv = ref object
    sim: SimServer
    inputs: seq[InputState]
    prevInputs: seq[InputState]
    rewardSnapshot: seq[int]
    playerCount: int
    seed: int

var
  envs: seq[NativeEnv]
  lastError = ""

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir().parentDir()

proc gameDir(): string =
  repoRoot() / "among_them"

proc setLastError(message: string): cint =
  lastError = message
  -1

proc validHandle(handle: cint): bool =
  handle >= 0 and int(handle) < envs.len and not envs[int(handle)].isNil

proc currentReward(env: NativeEnv, playerIndex: int): int =
  if playerIndex >= 0 and playerIndex < env.sim.players.len:
    env.sim.players[playerIndex].reward
  else:
    0

proc unpackFrame(frame: seq[uint8], target: ptr uint8, offset: int) =
  if frame.len != ProtocolBytes:
    raise newException(ValueError, "Unexpected Among Them frame size.")

  let output = cast[ptr UncheckedArray[uint8]](target)
  for i in 0 ..< ProtocolBytes:
    let value = frame[i]
    output[offset + i * 2] = value and 0x0f
    output[offset + i * 2 + 1] = value shr 4

proc copyObservations(env: var NativeEnv, observations: ptr uint8) =
  if observations.isNil:
    raise newException(ValueError, "Observation pointer is nil.")

  for playerIndex in 0 ..< env.playerCount:
    env.sim.render(playerIndex).unpackFrame(
      observations,
      playerIndex * FramePixels
    )

proc copyRewardDeltas(env: var NativeEnv, rewards: ptr cfloat, outputBase = 0) =
  if rewards.isNil:
    raise newException(ValueError, "Reward pointer is nil.")

  let output = cast[ptr UncheckedArray[cfloat]](rewards)
  for playerIndex in 0 ..< env.playerCount:
    let reward = env.currentReward(playerIndex)
    output[outputBase + playerIndex] = cfloat(reward - env.rewardSnapshot[playerIndex])
    env.rewardSnapshot[playerIndex] = reward

proc norm(value, scale: int): cfloat =
  cfloat(value) / cfloat(scale)

proc relNorm(value, scale: int): cfloat =
  cfloat(value) / cfloat(scale)

proc copyStateObservations(env: var NativeEnv, observations: ptr cfloat, outputBase = 0) =
  if observations.isNil:
    raise newException(ValueError, "Observation pointer is nil.")

  let output = cast[ptr UncheckedArray[cfloat]](observations)
  for playerIndex in 0 ..< env.playerCount:
    let
      base = outputBase + playerIndex * StateFeatures
      player = env.sim.players[playerIndex]
      taskCount = max(1, env.sim.tasks.len)
      maxSpeed = max(1, env.sim.config.maxSpeed)
      killCooldownTicks = max(1, env.sim.config.killCooldownTicks)
      taskCompleteTicks = max(1, env.sim.config.taskCompleteTicks)
    var i = 0

    template put(value: cfloat) =
      output[base + i] = value
      inc i

    put norm(player.x, MapWidth)
    put norm(player.y, MapHeight)
    put relNorm(player.velX, maxSpeed)
    put relNorm(player.velY, maxSpeed)
    put(if player.alive: 1.0 else: 0.0)
    put(if player.role == Imposter: 1.0 else: 0.0)
    put norm(player.killCooldown, killCooldownTicks)
    put norm(player.taskProgress, taskCompleteTicks)
    put(if player.activeTask >= 0: norm(player.activeTask + 1, taskCount) else: 0.0)
    put norm(player.buttonCallsUsed, max(1, env.sim.config.buttonCalls))
    put norm(ord(env.sim.phase), max(1, ord(high(GamePhase))))

    for otherIndex in 0 ..< 5:
      if otherIndex < env.sim.players.len:
        let other = env.sim.players[otherIndex]
        put relNorm(other.x - player.x, MapWidth)
        put relNorm(other.y - player.y, MapHeight)
        put(if other.alive: 1.0 else: 0.0)
        put(if other.role == Imposter: 1.0 else: 0.0)
        put norm(other.killCooldown, killCooldownTicks)
      else:
        for _ in 0 ..< 5:
          put 0.0

    for taskIndex in 0 ..< 15:
      if taskIndex < env.sim.tasks.len:
        let task = env.sim.tasks[taskIndex]
        put relNorm(task.x + task.w div 2 - player.x, MapWidth)
        put relNorm(task.y + task.h div 2 - player.y, MapHeight)
        put(if player.hasTask(taskIndex): 1.0 else: 0.0)
        put(if playerIndex < task.completed.len and task.completed[playerIndex]: 1.0 else: 0.0)
      else:
        for _ in 0 ..< 4:
          put 0.0

proc applyActionMasks(env: var NativeEnv, actionMasks: ptr uint8, actionRepeat: cint) =
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

proc initNativeEnv(env: var NativeEnv) =
  let previousDir = getCurrentDir()
  setCurrentDir(gameDir())
  try:
    var config = defaultGameConfig()
    config.seed = env.seed
    config.minPlayers = env.playerCount
    config.imposterCount = min(
      config.imposterCount,
      max(0, env.playerCount - 1)
    )
    env.sim = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

  env.inputs = newSeq[InputState](env.playerCount)
  env.prevInputs = newSeq[InputState](env.playerCount)
  env.rewardSnapshot = newSeq[int](env.playerCount)
  for playerIndex in 0 ..< env.playerCount:
    discard env.sim.addPlayer("player" & $(playerIndex + 1))
  env.sim.step(env.inputs, env.prevInputs)
  for playerIndex in 0 ..< env.playerCount:
    env.rewardSnapshot[playerIndex] = env.currentReward(playerIndex)

proc bitworld_at_last_error*(): cstring {.cdecl, exportc, dynlib.} =
  lastError.cstring

proc bitworld_at_create*(seed, playerCount: cint): cint {.cdecl, exportc, dynlib.} =
  try:
    if playerCount <= 0:
      return setLastError("playerCount must be positive.")

    var env = NativeEnv(seed: int(seed), playerCount: int(playerCount))
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
    env.initNativeEnv()
    env.copyObservations(observations)
    let output = cast[ptr UncheckedArray[cfloat]](rewards)
    for playerIndex in 0 ..< env.playerCount:
      output[playerIndex] = 0.0
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_reset_state*(
  handle: cint,
  observations: ptr cfloat,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if not validHandle(handle):
      return setLastError("Invalid Among Them native env handle.")

    var env = envs[int(handle)]
    env.initNativeEnv()
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
    env.applyActionMasks(actionMasks, actionRepeat)
    env.copyObservations(observations)
    env.copyRewardDeltas(rewards)
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_step_state*(
  handle: cint,
  actionMasks: ptr uint8,
  actionRepeat: cint,
  observations: ptr cfloat,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if not validHandle(handle):
      return setLastError("Invalid Among Them native env handle.")

    var env = envs[int(handle)]
    env.applyActionMasks(actionMasks, actionRepeat)
    env.copyStateObservations(observations)
    env.copyRewardDeltas(rewards)
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_reset_state_batch*(
  handles: ptr cint,
  envCount: cint,
  playerCount: cint,
  observations: ptr cfloat,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if handles.isNil:
      return setLastError("Handle pointer is nil.")
    if envCount <= 0:
      return setLastError("envCount must be positive.")
    if playerCount <= 0:
      return setLastError("playerCount must be positive.")

    let handleArray = cast[ptr UncheckedArray[cint]](handles)
    let rewardOutput = cast[ptr UncheckedArray[cfloat]](rewards)
    for envIndex in 0 ..< int(envCount):
      let handle = handleArray[envIndex]
      if not validHandle(handle):
        return setLastError("Invalid Among Them native env handle.")
      var env = envs[int(handle)]
      if env.playerCount != int(playerCount):
        return setLastError("Unexpected player count in batch reset.")
      env.initNativeEnv()
      env.copyStateObservations(observations, envIndex * int(playerCount) * StateFeatures)
      for playerIndex in 0 ..< int(playerCount):
        rewardOutput[envIndex * int(playerCount) + playerIndex] = 0.0
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_step_state_batch*(
  handles: ptr cint,
  envCount: cint,
  playerCount: cint,
  actionMasks: ptr uint8,
  actionRepeat: cint,
  observations: ptr cfloat,
  rewards: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if handles.isNil:
      return setLastError("Handle pointer is nil.")
    if actionMasks.isNil:
      return setLastError("Action pointer is nil.")
    if envCount <= 0:
      return setLastError("envCount must be positive.")
    if playerCount <= 0:
      return setLastError("playerCount must be positive.")

    let
      handleArray = cast[ptr UncheckedArray[cint]](handles)
      actions = cast[ptr UncheckedArray[uint8]](actionMasks)
    for envIndex in 0 ..< int(envCount):
      let handle = handleArray[envIndex]
      if not validHandle(handle):
        return setLastError("Invalid Among Them native env handle.")
      var env = envs[int(handle)]
      if env.playerCount != int(playerCount):
        return setLastError("Unexpected player count in batch step.")
      env.applyActionMasks(
        cast[ptr uint8](addr actions[envIndex * int(playerCount)]),
        actionRepeat
      )
      env.copyStateObservations(observations, envIndex * int(playerCount) * StateFeatures)
      env.copyRewardDeltas(rewards, envIndex * int(playerCount))
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
    env.applyActionMasks(actionMasks, actionRepeat)
    env.copyRewardDeltas(rewards)
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_close*(handle: cint) {.cdecl, exportc, dynlib.} =
  if validHandle(handle):
    envs[int(handle)] = nil

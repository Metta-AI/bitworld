import ../../common/protocol
import ../../among_them/sim
import std/os

const
  FramePixels = ScreenWidth * ScreenHeight

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

proc copyRewardDeltas(env: var NativeEnv, rewards: ptr cfloat) =
  if rewards.isNil:
    raise newException(ValueError, "Reward pointer is nil.")

  let output = cast[ptr UncheckedArray[cfloat]](rewards)
  for playerIndex in 0 ..< env.playerCount:
    let reward = env.currentReward(playerIndex)
    output[playerIndex] = cfloat(reward - env.rewardSnapshot[playerIndex])
    env.rewardSnapshot[playerIndex] = reward

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
    if actionMasks.isNil:
      return setLastError("Action pointer is nil.")
    if actionRepeat <= 0:
      return setLastError("actionRepeat must be positive.")

    var env = envs[int(handle)]
    let actions = cast[ptr UncheckedArray[uint8]](actionMasks)
    for _ in 0 ..< int(actionRepeat):
      for playerIndex in 0 ..< env.playerCount:
        env.prevInputs[playerIndex] = env.inputs[playerIndex]
        env.inputs[playerIndex] = decodeInputMask(actions[playerIndex])
      env.sim.step(env.inputs, env.prevInputs)
    env.copyObservations(observations)
    env.copyRewardDeltas(rewards)
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_close*(handle: cint) {.cdecl, exportc, dynlib.} =
  if validHandle(handle):
    envs[int(handle)] = nil

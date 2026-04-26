import ../common/protocol
import ../among_them/sim
import std/[os, tables]

const
  FramePixels = ScreenWidth * ScreenHeight
  StepActive = 0.cint
  StepTerminal = 1.cint
  StepTruncated = 2.cint
  StateTaskFeatureOffset = 36
  StateTaskCount = 15
  StateTaskFeatures = 4
  ActionCount = 27
  StateTeacherFeatureOffset = StateTaskFeatureOffset + StateTaskCount * StateTaskFeatures
  StateFeatures* = StateTeacherFeatureOffset + ActionCount
  NoPathDistance = high(int) div 4
  PathLookahead = 18
  TaskInnerMargin = 6
  CoastLookaheadTicks = 8
  CoastArrivalPadding = 1
  SteerDeadband = 2
  BrakeDeadband = 1

type
  NativeEnv = ref object
    sim: SimServer
    inputs: seq[InputState]
    prevInputs: seq[InputState]
    rewardSnapshot: seq[int]
    taskDistanceMaps: seq[seq[int]]
    taskDistanceMapKey: string
    playerCount: int
    seed: int
    maxTicks: int

var
  envs: seq[NativeEnv]
  taskDistanceMapCache: Table[string, seq[seq[int]]]
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

proc buildTaskDistanceMap(sim: SimServer, taskIndex: int): seq[int] =
  result = newSeq[int](MapWidth * MapHeight)
  for index in 0 ..< result.len:
    result[index] = NoPathDistance

  let task = sim.tasks[taskIndex]
  var queue = newSeq[int](MapWidth * MapHeight)
  var tail = 0
  template push(x, y: int, distance: int) =
    let index = mapIndex(x, y)
    if result[index] > distance:
      result[index] = distance
      queue[tail] = index
      inc tail

  for y in max(0, task.y + TaskInnerMargin) ..< min(MapHeight, task.y + task.h - TaskInnerMargin):
    for x in max(0, task.x + TaskInnerMargin) ..< min(MapWidth, task.x + task.w - TaskInnerMargin):
      if sim.canOccupy(x, y):
        push(x, y, 0)
  if tail == 0:
    for y in max(0, task.y) ..< min(MapHeight, task.y + task.h):
      for x in max(0, task.x) ..< min(MapWidth, task.x + task.w):
        if sim.canOccupy(x, y):
          push(x, y, 0)

  var head = 0
  while head < tail:
    let
      currentIndex = queue[head]
      currentDistance = result[currentIndex]
      x = currentIndex mod MapWidth
      y = currentIndex div MapWidth
    inc head
    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nx = x + delta[0]
        ny = y + delta[1]
      if not sim.canOccupy(nx, ny):
        continue
      let nextIndex = mapIndex(nx, ny)
      if result[nextIndex] <= currentDistance + 1:
        continue
      result[nextIndex] = currentDistance + 1
      queue[tail] = nextIndex
      inc tail

proc taskDistanceMapKey(sim: SimServer): string =
  result = newStringOfCap(sim.tasks.len * 32)
  for task in sim.tasks:
    result.add($task.x)
    result.add(",")
    result.add($task.y)
    result.add(",")
    result.add($task.w)
    result.add(",")
    result.add($task.h)
    result.add(";")

proc ensureTaskDistanceMaps(env: NativeEnv) =
  let key = env.sim.taskDistanceMapKey()
  if env.taskDistanceMapKey == key and env.taskDistanceMaps.len == env.sim.tasks.len:
    return
  if not taskDistanceMapCache.hasKey(key):
    var maps = newSeq[seq[int]](env.sim.tasks.len)
    for taskIndex in 0 ..< env.sim.tasks.len:
      maps[taskIndex] = env.sim.buildTaskDistanceMap(taskIndex)
    taskDistanceMapCache[key] = maps
  env.taskDistanceMaps = taskDistanceMapCache[key]
  env.taskDistanceMapKey = key

proc taskCompleted(env: NativeEnv, playerIndex, taskIndex: int): bool =
  taskIndex >= 0 and
    taskIndex < env.sim.tasks.len and
    playerIndex < env.sim.tasks[taskIndex].completed.len and
    env.sim.tasks[taskIndex].completed[playerIndex]

proc playerInTask(env: NativeEnv, playerIndex, taskIndex: int): bool =
  if taskIndex < 0 or taskIndex >= env.sim.tasks.len:
    return false
  let
    player = env.sim.players[playerIndex]
    task = env.sim.tasks[taskIndex]
    px = player.x + CollisionW div 2
    py = player.y + CollisionH div 2
  px >= task.x and px < task.x + task.w and py >= task.y and py < task.y + task.h

proc nearestAssignedTask(env: NativeEnv, playerIndex: int): int =
  env.ensureTaskDistanceMaps()
  let player = env.sim.players[playerIndex]
  var bestDistance = NoPathDistance
  for taskIndex in player.assignedTasks:
    if taskIndex < 0 or taskIndex >= env.taskDistanceMaps.len:
      continue
    if env.taskCompleted(playerIndex, taskIndex):
      continue
    let distance = env.taskDistanceMaps[taskIndex][mapIndex(player.x, player.y)]
    if distance < bestDistance:
      bestDistance = distance
      result = taskIndex
  if bestDistance == NoPathDistance:
    result = -1

proc coastDistance(velocity: int, config: GameConfig): int =
  var speed = abs(velocity)
  for _ in 0 ..< CoastLookaheadTicks:
    if speed <= 0:
      break
    result += speed
    speed = (speed * config.frictionNum) div config.frictionDen

proc shouldCoast(delta, velocity: int, config: GameConfig): bool =
  if delta > 0 and velocity > 0:
    return delta <= coastDistance(velocity, config) + CoastArrivalPadding
  if delta < 0 and velocity < 0:
    return -delta <= coastDistance(velocity, config) + CoastArrivalPadding

proc axisMask(delta, velocity: int, negativeMask, positiveMask: uint8, config: GameConfig): uint8 =
  if delta > SteerDeadband:
    if shouldCoast(delta, velocity, config):
      return 0
    if velocity > 1 and delta <= abs(velocity) + BrakeDeadband:
      return negativeMask
    return positiveMask
  if delta < -SteerDeadband:
    if shouldCoast(delta, velocity, config):
      return 0
    if velocity < -1 and -delta <= abs(velocity) + BrakeDeadband:
      return positiveMask
    return negativeMask
  if velocity > 0:
    return negativeMask
  if velocity < 0:
    return positiveMask
  0

proc pathWaypoint(env: NativeEnv, taskIndex, startX, startY: int): tuple[found: bool, x, y: int] =
  if taskIndex < 0 or taskIndex >= env.taskDistanceMaps.len:
    return
  var
    x = startX
    y = startY
    distance = env.taskDistanceMaps[taskIndex][mapIndex(x, y)]
  if distance >= NoPathDistance:
    return
  result = (true, x, y)
  for _ in 0 ..< PathLookahead:
    var
      bestX = x
      bestY = y
      bestDistance = distance
    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nx = x + delta[0]
        ny = y + delta[1]
      if not env.sim.canOccupy(nx, ny):
        continue
      let nextDistance = env.taskDistanceMaps[taskIndex][mapIndex(nx, ny)]
      if nextDistance < bestDistance:
        bestX = nx
        bestY = ny
        bestDistance = nextDistance
    if bestDistance >= distance:
      break
    x = bestX
    y = bestY
    distance = bestDistance
    result = (true, x, y)

proc taskTeacherMask(env: NativeEnv, playerIndex: int): uint8 =
  if playerIndex < 0 or playerIndex >= env.sim.players.len:
    return 0
  let player = env.sim.players[playerIndex]
  if env.sim.phase != Playing or not player.alive or player.role != Crewmate:
    return 0

  let taskIndex = env.nearestAssignedTask(playerIndex)
  if taskIndex < 0:
    return 0
  if env.playerInTask(playerIndex, taskIndex):
    return ButtonA

  let waypoint = env.pathWaypoint(taskIndex, player.x, player.y)
  if not waypoint.found:
    return 0
  let
    dx = waypoint.x - player.x
    dy = waypoint.y - player.y
  result = result or axisMask(dx, player.velX, ButtonLeft, ButtonRight, env.sim.config)
  result = result or axisMask(dy, player.velY, ButtonUp, ButtonDown, env.sim.config)

proc actionIndexForMask(mask: uint8): int =
  let direction = mask and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)
  var directionIndex = 0
  case direction
  of ButtonUp: directionIndex = 1
  of ButtonDown: directionIndex = 2
  of ButtonLeft: directionIndex = 3
  of ButtonRight: directionIndex = 4
  of ButtonUp or ButtonLeft: directionIndex = 5
  of ButtonUp or ButtonRight: directionIndex = 6
  of ButtonDown or ButtonLeft: directionIndex = 7
  of ButtonDown or ButtonRight: directionIndex = 8
  else: directionIndex = 0

  let buttonIndex =
    if (mask and ButtonA) != 0:
      1
    elif (mask and ButtonB) != 0:
      2
    else:
      0
  directionIndex * 3 + buttonIndex

proc copyStateObservations(env: var NativeEnv, observations: ptr cfloat, outputBase = 0) =
  if observations.isNil:
    raise newException(ValueError, "Observation pointer is nil.")

  env.ensureTaskDistanceMaps()
  let output = cast[ptr UncheckedArray[cfloat]](observations)
  for playerIndex in 0 ..< env.playerCount:
    let
      base = outputBase + playerIndex * StateFeatures
      player = env.sim.players[playerIndex]
      teacherAction = env.taskTeacherMask(playerIndex).actionIndexForMask()
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

    for actionIndex in 0 ..< ActionCount:
      put(if actionIndex == teacherAction: 1.0 else: 0.0)

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

proc initNativeEnv(env: var NativeEnv) =
  let previousDir = getCurrentDir()
  setCurrentDir(gameDir())
  try:
    var config = defaultGameConfig()
    config.seed = env.seed
    config.maxTicks = env.maxTicks
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

proc bitworld_at_tick_count*(handle: cint): cint {.cdecl, exportc, dynlib.} =
  if validHandle(handle):
    return cint(envs[int(handle)].sim.tickCount)
  setLastError("Invalid Among Them native env handle.")

proc bitworld_at_game_hash*(handle: cint): uint64 {.cdecl, exportc, dynlib.} =
  if validHandle(handle):
    return envs[int(handle)].sim.gameHash()
  discard setLastError("Invalid Among Them native env handle.")

proc bitworld_at_create*(seed, playerCount, maxTicks: cint): cint {.cdecl, exportc, dynlib.} =
  try:
    if playerCount <= 0:
      return setLastError("playerCount must be positive.")
    if maxTicks < 0:
      return setLastError("maxTicks must be non-negative.")

    var env = NativeEnv(
      seed: int(seed),
      playerCount: int(playerCount),
      maxTicks: int(maxTicks)
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
  observations: ptr cfloat,
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
  statuses: ptr cint,
  observations: ptr cfloat,
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

    let
      handleArray = cast[ptr UncheckedArray[cint]](handles)
      actions = cast[ptr UncheckedArray[uint8]](actionMasks)
      statusOutput = cast[ptr UncheckedArray[cint]](statuses)
    for envIndex in 0 ..< int(envCount):
      let handle = handleArray[envIndex]
      if not validHandle(handle):
        return setLastError("Invalid Among Them native env handle.")
      var env = envs[int(handle)]
      if env.playerCount != int(playerCount):
        return setLastError("Unexpected player count in batch step.")
      statusOutput[envIndex] = env.applyActionMasks(
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
    let status = env.applyActionMasks(actionMasks, actionRepeat)
    env.copyRewardDeltas(rewards)
    status
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_close*(handle: cint) {.cdecl, exportc, dynlib.} =
  if validHandle(handle):
    envs[int(handle)] = nil
    taskDistanceMapCache.clear()

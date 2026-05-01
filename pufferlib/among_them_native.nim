import ../common/protocol
import ../among_them/sim
import std/[math, os]

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

proc copyTaskDistances(env: var NativeEnv, distances: ptr cfloat, outputBase = 0) =
  if distances.isNil:
    raise newException(ValueError, "Distance pointer is nil.")
  let output = cast[ptr UncheckedArray[cfloat]](distances)
  let maxDist = cfloat(sqrt(float(MapWidth * MapWidth + MapHeight * MapHeight)))
  for playerIndex in 0 ..< env.playerCount:
    let player = env.sim.players[playerIndex]
    if not player.alive or player.role != Crewmate or env.sim.phase != Playing:
      output[outputBase + playerIndex] = 1.0
      continue
    let px = float(player.x)
    let py = float(player.y)
    var nearest = maxDist
    for taskIndex in player.assignedTasks:
      if taskIndex < 0 or taskIndex >= env.sim.tasks.len:
        continue
      let task = env.sim.tasks[taskIndex]
      if playerIndex < task.completed.len and task.completed[playerIndex]:
        continue
      let tx = float(task.x + task.w div 2)
      let ty = float(task.y + task.h div 2)
      let dist = sqrt((px - tx) * (px - tx) + (py - ty) * (py - ty))
      if dist < nearest:
        nearest = dist
    output[outputBase + playerIndex] = cfloat(nearest / float(maxDist))

proc copyOnTaskFlags(env: var NativeEnv, flags: ptr cfloat, outputBase = 0) =
  if flags.isNil:
    raise newException(ValueError, "Flags pointer is nil.")
  let output = cast[ptr UncheckedArray[cfloat]](flags)
  for playerIndex in 0 ..< env.playerCount:
    let player = env.sim.players[playerIndex]
    if not player.alive or player.role != Crewmate or env.sim.phase != Playing:
      output[outputBase + playerIndex] = 0.0
      continue
    let
      px = player.x + CollisionW div 2
      py = player.y + CollisionH div 2
    var onTask = false
    for taskIndex in player.assignedTasks:
      if taskIndex < 0 or taskIndex >= env.sim.tasks.len:
        continue
      let task = env.sim.tasks[taskIndex]
      if playerIndex < task.completed.len and task.completed[playerIndex]:
        continue
      if px >= task.x and px < task.x + task.w and
          py >= task.y and py < task.y + task.h:
        onTask = true
        break
    output[outputBase + playerIndex] = if onTask: 1.0 else: 0.0

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
    if fileExists("config.json"):
      config.update(readFile("config.json"))
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

proc bitworld_at_create*(seed, playerCount, maxTicks: cint): cint {.cdecl, exportc, dynlib.} =
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

proc bitworld_at_task_distances*(
  handle: cint,
  distances: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if not validHandle(handle):
      return setLastError("Invalid Among Them native env handle.")
    var env = envs[int(handle)]
    env.copyTaskDistances(distances)
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_task_distances_batch*(
  handles: ptr cint,
  envCount: cint,
  playerCount: cint,
  distances: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if handles.isNil:
      return setLastError("Handle pointer is nil.")
    if envCount <= 0:
      return setLastError("envCount must be positive.")
    if playerCount <= 0:
      return setLastError("playerCount must be positive.")
    let
      playerCountInt = int(playerCount)
      handleArray = cast[ptr UncheckedArray[cint]](handles)
    for envIndex in 0 ..< int(envCount):
      if not validHandle(handleArray[envIndex]):
        return setLastError("Invalid Among Them native env handle.")
      var env = envs[int(handleArray[envIndex])]
      if env.playerCount != playerCountInt:
        return setLastError("Unexpected player count in batch distance query.")
      env.copyTaskDistances(distances, envIndex * playerCountInt)
    0
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_on_task_batch*(
  handles: ptr cint,
  envCount: cint,
  playerCount: cint,
  flags: ptr cfloat
): cint {.cdecl, exportc, dynlib.} =
  try:
    if handles.isNil:
      return setLastError("Handle pointer is nil.")
    if envCount <= 0:
      return setLastError("envCount must be positive.")
    if playerCount <= 0:
      return setLastError("playerCount must be positive.")
    let
      playerCountInt = int(playerCount)
      handleArray = cast[ptr UncheckedArray[cint]](handles)
    for envIndex in 0 ..< int(envCount):
      if not validHandle(handleArray[envIndex]):
        return setLastError("Invalid Among Them native env handle.")
      var env = envs[int(handleArray[envIndex])]
      if env.playerCount != playerCountInt:
        return setLastError("Unexpected player count in batch on_task query.")
      env.copyOnTaskFlags(flags, envIndex * playerCountInt)
    0
  except CatchableError as e:
    setLastError(e.msg)

const
  ## Episode stats buffer layout (flat cfloat array).
  ## Global stats (indices 0-7):
  STAT_WINNER* = 0           ## 0=Crewmate, 1=Imposter
  STAT_GAME_TICKS* = 1       ## Ticks elapsed since game start
  STAT_TOTAL_KILLS* = 2      ## Bodies on the ground
  STAT_TOTAL_EJECTIONS* = 3  ## Players removed by vote
  STAT_CREWMATE_TASKS_DONE* = 4  ## Tasks completed by all crewmates
  STAT_CREWMATE_TASKS_TOTAL* = 5 ## Total assigned crewmate tasks
  STAT_TIME_LIMIT_REACHED* = 6   ## 1 if game ended by max ticks
  STAT_IMPOSTER_COUNT* = 7       ## Number of imposters in this game
  ## Per-player stats start at index 8, stride 6 per player:
  STAT_PLAYER_BASE* = 8
  STAT_PLAYER_STRIDE* = 6
  ## Per-player offsets:
  STAT_P_ROLE* = 0            ## 0=Crewmate, 1=Imposter
  STAT_P_ALIVE* = 1           ## 1=alive at game end, 0=dead
  STAT_P_TASKS_DONE* = 2      ## Tasks this player completed
  STAT_P_TASKS_ASSIGNED* = 3  ## Tasks assigned to this player
  STAT_P_REWARD* = 4          ## Cumulative reward
  STAT_P_KILL_COOLDOWN* = 5   ## Remaining kill cooldown (proxy for recent kill)

proc episodeStatsSize*(playerCount: int): int =
  STAT_PLAYER_BASE + playerCount * STAT_PLAYER_STRIDE

proc copyEpisodeStats(env: var NativeEnv, output: ptr cfloat) =
  let buf = cast[ptr UncheckedArray[cfloat]](output)
  let sim = env.sim

  buf[STAT_WINNER] = if sim.winner == Imposter: 1.0 else: 0.0
  buf[STAT_GAME_TICKS] = cfloat(sim.gameTicksElapsed())
  buf[STAT_TOTAL_KILLS] = cfloat(sim.bodies.len)

  var ejections = 0
  var crewTasksDone = 0
  var crewTasksTotal = 0
  var imposterCount = 0

  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    let base = STAT_PLAYER_BASE + i * STAT_PLAYER_STRIDE
    buf[base + STAT_P_ROLE] = if p.role == Imposter: 1.0 else: 0.0
    buf[base + STAT_P_ALIVE] = if p.alive: 1.0 else: 0.0
    buf[base + STAT_P_REWARD] = cfloat(p.reward)
    buf[base + STAT_P_KILL_COOLDOWN] = cfloat(p.killCooldown)

    if p.role == Imposter:
      inc imposterCount
      buf[base + STAT_P_TASKS_DONE] = 0.0
      buf[base + STAT_P_TASKS_ASSIGNED] = 0.0
    else:
      var done = 0
      for taskIndex in p.assignedTasks:
        if taskIndex >= 0 and taskIndex < sim.tasks.len:
          if i < sim.tasks[taskIndex].completed.len and
              sim.tasks[taskIndex].completed[i]:
            inc done
      buf[base + STAT_P_TASKS_DONE] = cfloat(done)
      buf[base + STAT_P_TASKS_ASSIGNED] = cfloat(p.assignedTasks.len)
      crewTasksDone += done
      crewTasksTotal += p.assignedTasks.len

    if not p.alive and p.role != Imposter:
      discard  # killed crewmate — already counted in bodies
    elif not p.alive and p.role == Imposter:
      inc ejections  # dead imposter = ejected by vote (kills don't target imposters)

  buf[STAT_TOTAL_EJECTIONS] = cfloat(ejections)
  buf[STAT_CREWMATE_TASKS_DONE] = cfloat(crewTasksDone)
  buf[STAT_CREWMATE_TASKS_TOTAL] = cfloat(crewTasksTotal)
  buf[STAT_TIME_LIMIT_REACHED] = if sim.timeLimitReached: 1.0 else: 0.0
  buf[STAT_IMPOSTER_COUNT] = cfloat(imposterCount)

proc bitworld_at_episode_stats*(
  handle: cint,
  output: ptr cfloat,
  bufferSize: cint
): cint {.cdecl, exportc, dynlib.} =
  try:
    if not validHandle(handle):
      return setLastError("Invalid Among Them native env handle.")
    var env = envs[int(handle)]
    let needed = episodeStatsSize(env.playerCount)
    if int(bufferSize) < needed:
      return setLastError("Episode stats buffer too small: need " & $needed & " floats.")
    env.copyEpisodeStats(output)
    cint(needed)
  except CatchableError as e:
    setLastError(e.msg)

proc bitworld_at_close*(handle: cint) {.cdecl, exportc, dynlib.} =
  if validHandle(handle):
    envs[int(handle)] = nil

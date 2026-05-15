import
  std/[json, locks, monotimes, os, strutils, tables, times],
  mummy,
  bitworld/clients, protocol, sim, global, replays

const
  UnassignedPlayerIndex = 0x7fffffff
  SpritePlayerWebSocketPath = "/sprite_player"

type
  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    playerViewers: Table[WebSocket, PlayerViewerState]
    globalViewers: Table[WebSocket, GlobalViewerState]
    rewardViewers: Table[WebSocket, bool]
    closedSockets: seq[WebSocket]
    tokens: seq[string]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerNames = initTable[WebSocket, string]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.closedSockets = @[]
  appState.tokens = @[]

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc serveClientHtml(request: Request, route: string): bool =
  if request.httpMethod != "GET":
    return false
  let filePath = clientStaticPath(route, GlobalClientRoute)
  if filePath.len == 0:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(route, GlobalClientRoute)
  headers["Cache-Control"] = "no-cache"
  if not fileExists(filePath):
    request.respond(404, headers, "Missing static client: " & route)
    return true
  try:
    request.respond(200, headers, readFile(filePath))
  except IOError as e:
    request.respond(500, headers, "Could not read static client: " & e.msg)
  true

proc serveStaticClientHtml(request: Request): bool =
  request.serveClientHtml(request.path)

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerIdentity(request: Request): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  let parts = request.remoteAddress.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  request.remoteAddress

var replayMode: bool = false

proc httpHandler(request: Request) =
  if request.path == "/healthz" and request.httpMethod in ["GET", "HEAD"]:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == ReplayWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif (request.path == SpritePlayerWebSocketPath or
      request.path == WebSocketPath) and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    {.gcsafe.}:
      if replayMode:
        # In replay mode, player connections become global viewers
        let websocket = request.upgradeToWebSocket()
        withLock appState.lock:
          appState.globalViewers[websocket] = initGlobalViewerState()
        return
      let token = request.queryParams.getOrDefault("token", "")
      var allowed = true
      withLock appState.lock:
        if appState.tokens.len > 0:
          allowed = token in appState.tokens
      if not allowed:
        var headers: HttpHeaders
        headers["Content-Type"] = "text/plain; charset=utf-8"
        request.respond(403, headers, "invalid token")
        return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerViewers[websocket] = initPlayerViewerState()
        appState.playerNames[websocket] = request.playerIdentity()
        appState.playerIndices[websocket] = UnassignedPlayerIndex
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
  elif (request.path == SpritePlayerWebSocketPath or
      request.path == WebSocketPath or
      request.path == GlobalWebSocketPath or
      request.path == ReplayWebSocketPath or
      request.path == "/admin") and
      request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    discard request.serveClientHtml(GlobalClientRoute)
  elif (request.path == GlobalWebSocketPath or request.path == "/admin") and
      request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path == RewardWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.rewardViewers[websocket] = true
  elif request.serveStaticClientHtml():
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    request.respond(200, headers, "Bit World sprite protocol server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind != BinaryMessage:
      return
    if message.data.len == 2:
      let header = message.data[0].uint8
      if header == 0x00 or header == 0x84:
        {.gcsafe.}:
          withLock appState.lock:
            appState.inputMasks[websocket] = message.data[1].uint8
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket notin appState.playerIndices:
    appState.playerNames.del(websocket)
    appState.inputMasks.del(websocket)
    appState.lastAppliedMasks.del(websocket)
    return
  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.playerNames.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    let removedPlayerId = sim.players[removedIndex].id
    sim.players.delete(removedIndex)
    var remainingBullets: seq[Bullet] = @[]
    for bullet in sim.bullets:
      if bullet.ownerId != removedPlayerId:
        remainingBullets.add(bullet)
    sim.bullets = move(remainingBullets)
    for _, value in appState.playerIndices.mpairs:
      if value > removedIndex and value != UnassignedPlayerIndex:
        dec value

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc writeResults(sim: SimServer, path: string) =
  if path.len == 0:
    return
  var names = newJArray()
  var scores = newJArray()
  for player in sim.players:
    names.add(%player.name)
    scores.add(%player.score)
  let results = %*{"names": names, "scores": scores}
  let dir = path.parentDir()
  if dir.len > 0:
    createDir(dir)
  writeFile(path, $results & "\n")

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  seed = 0xA57E2,
  durationTicks = 0,
  resultsPath = "",
  tokens: seq[string] = @[],
  saveReplayPath = "",
  loadReplayPath = "",
  coopSpawnPercent = DefaultCoopSpawnPercent,
  coopScoreMultiplier = DefaultCoopScoreMultiplier,
  planetCount = DefaultPlanetCount
) =
  initAppState()
  appState.tokens = tokens
  replayMode = loadReplayPath.len > 0

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    tcpNoDelay = true
  )
  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()

  var
    actualSeed = seed
    replayWriter: ReplayWriter
    replayPlayer: ReplayPlayer

  if loadReplayPath.len > 0:
    let data = loadReplay(loadReplayPath)
    replayPlayer = initReplayPlayer(data)
    let replayConfig = parseJson(data.configJson)
    if replayConfig.hasKey("seed") and replayConfig["seed"].kind == JInt:
      actualSeed = replayConfig["seed"].getInt()

  var
    sim = initSimServer(actualSeed, coopSpawnPercent, coopScoreMultiplier, planetCount)
    lastTick = getMonoTime()
    tickCount = 0

  if saveReplayPath.len > 0:
    let configJson = $(%*{"seed": seed})
    replayWriter = openReplayWriter(saveReplayPath, configJson)

  while true:
    if durationTicks > 0 and tickCount >= durationTicks:
      if replayWriter.enabled:
        closeReplayWriter(replayWriter)
      sim.writeResults(resultsPath)
      quit(0)

    if loadReplayPath.len > 0:
      # Replay mode
      if not replayPlayer.playing:
        # Send final frame to any connected viewers then exit
        var viewers: seq[WebSocket] = @[]
        var states: seq[GlobalViewerState] = @[]
        {.gcsafe.}:
          withLock appState.lock:
            for ws, state in appState.globalViewers.pairs:
              viewers.add(ws)
              states.add(state)
        for i in 0 ..< viewers.len:
          var nextState: GlobalViewerState
          let packet = sim.buildSpriteProtocolUpdates(states[i], nextState)
          if packet.len > 0:
            try:
              viewers[i].send(blobFromBytes(packet), BinaryMessage)
            except:
              discard
        sleep(500)
        if replayWriter.enabled:
          closeReplayWriter(replayWriter)
        sim.writeResults(resultsPath)
        quit(0)

      stepReplay(replayPlayer, sim)
      inc tickCount

      # Send to global/replay viewers
      var
        globalViewers: seq[WebSocket] = @[]
        globalStates: seq[GlobalViewerState] = @[]
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.closedSockets:
            appState.globalViewers.del(websocket)
            appState.rewardViewers.del(websocket)
          appState.closedSockets.setLen(0)
          for websocket, state in appState.globalViewers.pairs:
            globalViewers.add(websocket)
            globalStates.add(state)

      for i in 0 ..< globalViewers.len:
        var nextState: GlobalViewerState
        let packet = sim.buildSpriteProtocolUpdates(globalStates[i], nextState)
        if packet.len == 0:
          continue
        try:
          globalViewers[i].send(blobFromBytes(packet), BinaryMessage)
          {.gcsafe.}:
            withLock appState.lock:
              if globalViewers[i] in appState.globalViewers:
                appState.globalViewers[globalViewers[i]] = nextState
        except:
          {.gcsafe.}:
            withLock appState.lock:
              appState.globalViewers.del(globalViewers[i])

      runFrameLimiter(lastTick)
      continue

    # Live mode
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerStates: seq[PlayerViewerState] = @[]
      inputs: seq[PlayerInput]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      rewardViewers: seq[WebSocket] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          if replayWriter.enabled:
            let idx = appState.playerIndices.getOrDefault(websocket, UnassignedPlayerIndex)
            if idx != UnassignedPlayerIndex and idx >= 0:
              replayWriter.writeLeave(tickTime(sim.tickCount), idx)
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] != UnassignedPlayerIndex:
            continue
          let name = appState.playerNames.getOrDefault(websocket, "unknown")
          let playerIndex = sim.addPlayer(name)
          appState.playerIndices[websocket] = playerIndex
          if replayWriter.enabled:
            replayWriter.writeJoin(
              tickTime(sim.tickCount), playerIndex, name, 0, "")

        inputs = newSeq[PlayerInput](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          sockets.add(websocket)
          playerIndices.add(playerIndex)
          playerStates.add(
            appState.playerViewers.getOrDefault(
              websocket,
              initPlayerViewerState()
            )
          )
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let
            currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            previousMask =
              appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = playerInputFromMasks(
            currentMask,
            previousMask
          )
          if replayWriter.enabled and currentMask != previousMask:
            # Grow lastMasks if needed
            while replayWriter.lastMasks.len <= playerIndex:
              replayWriter.lastMasks.add(0)
            if currentMask != replayWriter.lastMasks[playerIndex]:
              replayWriter.writeInput(ReplayInput(
                time: tickTime(sim.tickCount),
                player: uint8(playerIndex),
                keys: currentMask
              ))
              replayWriter.lastMasks[playerIndex] = currentMask
          appState.lastAppliedMasks[websocket] = currentMask

        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          globalStates.add(state)
        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)

    sim.step(inputs)
    inc tickCount

    if replayWriter.enabled:
      replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())

    let rewardPacket = sim.buildRewardPacket()
    for i in 0 ..< sockets.len:
      var nextState: PlayerViewerState
      let packet = sim.buildSpriteProtocolPlayerUpdates(
        playerIndices[i],
        playerStates[i],
        nextState
      )
      try:
        sockets[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i] in appState.playerViewers:
              appState.playerViewers[sockets[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])
    for websocket in rewardViewers:
      try:
        websocket.send(rewardPacket, TextMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(websocket)
    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      let packet = sim.buildSpriteProtocolUpdates(globalStates[i], nextState)
      if packet.len == 0:
        continue
      try:
        globalViewers[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              appState.globalViewers[globalViewers[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(globalViewers[i])

    runFrameLimiter(lastTick)

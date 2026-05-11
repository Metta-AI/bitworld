import
  std/[locks, monotimes, os, strutils, tables, times],
  mummy,
  bitworld/clients, protocol, sim, global

const
  HealthzPath = "/healthz"
  UnassignedPlayerIndex = 0x7fffffff

type
  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    chatMessages: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    playerViewers: Table[WebSocket, PlayerViewerState]
    globalViewers: Table[WebSocket, GlobalViewerState]
    rewardViewers: Table[WebSocket, bool]
    closedSockets: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

var appState: WebSocketAppState

proc initAppState() =
  ## Initializes the shared websocket state.
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerNames = initTable[WebSocket, string]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.closedSockets = @[]

proc isWebSocketUpgrade(request: Request): bool =
  ## Returns true when a GET request is a websocket upgrade.
  request.headers["Sec-WebSocket-Key"].len > 0

proc serveClientHtml(request: Request, route: string): bool =
  ## Serves one static client file for a known client route.
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
  ## Serves one static client asset if the route matches.
  request.serveClientHtml(request.path)

proc serveHealthz(request: Request): bool =
  ## Serves the container health check endpoint.
  if request.path != HealthzPath or request.httpMethod notin ["GET", "HEAD"]:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, "healthy")
  true

proc cleanPlayerName(name: string): string =
  ## Returns a protocol-safe player display name.
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerIdentity(request: Request): string =
  ## Returns the websocket player identity for rewards and displays.
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  let parts = request.remoteAddress.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  request.remoteAddress

proc httpHandler(request: Request) =
  ## Handles HTTP routes and websocket upgrades.
  if request.serveHealthz():
    discard
  elif request.path == WebSocketPath and
      request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerViewers[websocket] = initPlayerViewerState()
        appState.playerNames[websocket] = request.playerIdentity()
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
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
    request.respond(200, headers, "Bit World global protocol server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  ## Handles websocket lifecycle and input messages.
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.globalViewers and
            websocket notin appState.rewardViewers:
          appState.playerIndices[websocket] = UnassignedPlayerIndex
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind != BinaryMessage:
      return
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.globalViewers:
          appState.globalViewers[websocket].applyGlobalViewerMessage(
            message.data
          )
        elif websocket in appState.playerViewers:
          if isInputPacket(message.data):
            appState.inputMasks[websocket] = blobToMask(message.data)
          elif isChatPacket(message.data):
            appState.chatMessages[websocket] = blobToChat(message.data)
          else:
            var
              mask = appState.inputMasks.getOrDefault(websocket, 0)
              chatText = ""
            appState.playerViewers[websocket].applyPlayerViewerMessage(
              message.data,
              mask,
              chatText
            )
            appState.inputMasks[websocket] = mask
            if chatText.len > 0:
              appState.chatMessages[websocket] = chatText
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  ## Removes a websocket and keeps live player indices consistent.
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket in appState.chatMessages:
    appState.chatMessages.del(websocket)
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
    sim.removePlayerById(removedPlayerId)
    sim.players.delete(removedIndex)
    for _, value in appState.playerIndices.mpairs:
      if value > removedIndex and value != UnassignedPlayerIndex:
        dec value

proc playerInputFromMasks(currentMask, previousMask: uint8): PlayerInput =
  ## Builds a player input state from current and previous button masks.
  let decoded = decodeInputMask(currentMask)
  result.up = decoded.up
  result.down = decoded.down
  result.left = decoded.left
  result.right = decoded.right
  result.attackPressed =
    (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
  result.sendHeld = decoded.b

proc rewardAddress(address: string): string =
  ## Returns the reward protocol identity for one address.
  let parts = address.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  address

proc buildRewardPacket(sim: SimServer): string =
  ## Builds one reward protocol packet for the current tick.
  for player in sim.players:
    result.add("reward ")
    result.add(player.name.rewardAddress())
    result.add(" ")
    result.add($player.score)
    result.add("\n")

proc writeScoreFile(sim: SimServer, path: string) =
  ## Writes the current score JSON if a path is configured.
  if path.len == 0:
    return
  let dir = path.parentDir()
  if dir.len > 0:
    createDir(dir)
  writeFile(path, sim.playerScoresJson() & "\n")

proc writeScoresIfNeeded(
  sim: SimServer,
  path: string,
  lastRevision: var int
) =
  ## Writes scores when score-visible state changed.
  if path.len == 0:
    return
  if sim.scoreRevision == lastRevision:
    return
  sim.writeScoreFile(path)
  lastRevision = sim.scoreRevision

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  ## Runs the mummy server on its own thread.
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  ## Sleeps to keep the server near the target frame rate.
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  seed = 0x1A7E7,
  simConfig = defaultSimConfig(),
  saveScoresPath = ""
) =
  ## Runs the Planet Wars server loop.
  initAppState()
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
    sim = initSimServer(seed, simConfig)
    lastTick = getMonoTime()
    lastScoreRevision = -1
  sim.writeScoresIfNeeded(saveScoresPath, lastScoreRevision)
  while true:
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
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)
        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] != UnassignedPlayerIndex:
            continue
          let name = appState.playerNames.getOrDefault(websocket, "unknown")
          appState.playerIndices[websocket] = sim.addPlayer(name)
        for websocket, chatText in appState.chatMessages.pairs:
          let playerIndex = appState.playerIndices.getOrDefault(
            websocket,
            -1
          )
          sim.addChatMessage(playerIndex, chatText)
        appState.chatMessages.clear()
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
          appState.lastAppliedMasks[websocket] = currentMask
        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          globalStates.add(state)
        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)
    sim.step(inputs)
    sim.writeScoresIfNeeded(saveScoresPath, lastScoreRevision)
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

import
  std/[locks, monotimes, nativesockets, os, strutils, tables, times],
  curly, mummy,
  bitworld/clients, protocol, sim, global, profile, replays

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

const
  BotVoteFrameStride = 6

type
  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  WebSocketAppState = object
    lock: Lock
    replayServerMode: bool
    replayLoaded: bool
    pendingReplayUri: string
    resetRequested: bool
    kickRequests: seq[string]
    kickedIdentities: Table[string, bool]
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    chatMessages: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    globalViewers: Table[WebSocket, GlobalViewerState]
    playerViewers: Table[WebSocket, PlayerViewerState]
    rewardViewers: Table[WebSocket, bool]
    closedSockets: seq[WebSocket]
    spectators: seq[WebSocket]
    nextAnonymousPlayer: int
    config: GameConfig

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

const
  HealthPath = "/healthz"
  AdminWebSocketPath = "/admin"
  ControlRestartPath = "/control/restart"
  ControlKickPath = "/control/kick"

proc liveProgressMaxTick(config: GameConfig): int =
  ## Returns the live viewer tick-bar budget.
  if config.maxTicks > 0:
    config.maxTicks
  else:
    MaxTicks

proc isWebSocketUpgrade(request: Request): bool =
  ## Returns true when the GET request is a websocket upgrade.
  request.headers["Sec-WebSocket-Key"].len > 0

proc serveClientHtml(request: Request, route: string): bool =
  ## Serves one static client file for a known client route.
  if request.httpMethod != "GET":
    return false
  let filePath = clientStaticPath(route)
  if filePath.len == 0:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(route)
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

proc replayFilePath(uri: string): string =
  ## Resolves one local replay URI to a host path.
  const FilePrefix = "file://"
  if uri.startsWith(FilePrefix):
    return uri[FilePrefix.len .. ^1]
  if "://" in uri:
    return ""
  uri

let replayDownloadPool = newCurlPool(1)

proc loadReplayUri(uri: string): ReplayData =
  ## Loads a replay from a local file URI or HTTP(S) URL.
  if uri.startsWith("http://") or uri.startsWith("https://"):
    let response = replayDownloadPool.get(uri)
    if response.code != 200:
      raise newException(
        IOError,
        "Replay download failed: " & $response.code
      )
    return parseReplayBytes(response.body)
  let path = replayFilePath(uri)
  if path.len == 0:
    raise newException(IOError, "Unsupported replay URI: " & uri)
  loadReplay(path)

proc readableReplayUri(uri: string): bool =
  ## Returns true when a replay URI can be opened by this server.
  if uri.len == 0:
    return false
  if uri.startsWith("http://") or uri.startsWith("https://"):
    return true
  let path = replayFilePath(uri)
  path.len > 0 and fileExists(path)

proc rewardAddress(address: string): string =
  ## Formats one reward address as host:port.
  let parts = address.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  address

proc isThrottledBotAddress(address: string): bool =
  ## Returns true for bots that can pause while waiting on LLM calls.
  address.startsWith("italkalot-")

proc shouldSendPlayerFrame(
  sim: SimServer,
  address: string,
  isPlayerViewer: bool
): bool {.measure.} =
  ## Returns true when a player socket should receive this frame.
  if isPlayerViewer:
    return true
  if sim.phase == Voting and address.isThrottledBotAddress():
    return sim.tickCount mod BotVoteFrameStride == 0
  true

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.replayServerMode = false
  appState.replayLoaded = false
  appState.pendingReplayUri = ""
  appState.resetRequested = false
  appState.kickRequests = @[]
  appState.kickedIdentities = initTable[string, bool]()
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.closedSockets = @[]
  appState.spectators = @[]
  appState.nextAnonymousPlayer = 1
  appState.config = defaultGameConfig()

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  ## Removes a websocket and keeps live player indices consistent.
  for i in countdown(appState.spectators.high, 0):
    if appState.spectators[i] == websocket:
      appState.spectators.delete(i)
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket notin appState.playerIndices:
    appState.inputMasks.del(websocket)
    appState.lastAppliedMasks.del(websocket)
    appState.chatMessages.del(websocket)
    appState.playerAddresses.del(websocket)
    appState.playerSlots.del(websocket)
    appState.playerTokens.del(websocket)
    return
  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.chatMessages.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.removePlayerAt(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc cleanPlayerName(name: string): string =
  ## Returns a protocol-safe player display name.
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc generatedPlayerName*(index: int): string =
  ## Returns the generated display name for an anonymous player index.
  "Player" & $index

proc anonymousPlayerIdentity*(
  nextIndex: var int,
  existingNames: openArray[string]
): string =
  ## Returns a unique generated identity for one nameless player.
  if nextIndex <= 0:
    nextIndex = 1
  while true:
    result = generatedPlayerName(nextIndex)
    inc nextIndex
    var taken = false
    for name in existingNames:
      if name == result:
        taken = true
        break
    if not taken:
      return

proc nextAnonymousPlayerIdentity(): string =
  ## Returns a unique generated identity from current server state.
  {.gcsafe.}:
    withLock appState.lock:
      var existingNames: seq[string] = @[]
      for _, address in appState.playerAddresses.pairs:
        existingNames.add(address)
      for identity in appState.kickedIdentities.keys:
        existingNames.add(identity)
      result = anonymousPlayerIdentity(
        appState.nextAnonymousPlayer,
        existingNames
      )

proc playerIdentity(request: Request, slot: int, token: string): string =
  ## Returns the websocket player identity for rewards and displays.
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
      if result.len > 0:
        return
  result = nextAnonymousPlayerIdentity()

proc playerSlot(request: Request): int =
  ## Returns the requested player slot or -1 for automatic assignment.
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerToken(request: Request): string =
  ## Returns the player join token.
  request.queryParams.getOrDefault("token", "").strip()

proc controlHeaders(): HttpHeaders =
  ## Returns headers for admin-panel control requests.
  result["Content-Type"] = "text/plain; charset=utf-8"
  result["Cache-Control"] = "no-cache"
  result["Access-Control-Allow-Origin"] = "*"
  result["Access-Control-Allow-Methods"] = "POST, OPTIONS"
  result["Access-Control-Allow-Headers"] = "Content-Type"

proc respondControl(request: Request, status: int, body: string) =
  ## Sends a plain text control response.
  request.respond(status, controlHeaders(), body)

proc replayControlsDisabled(): bool =
  ## Returns true when live match controls are disabled.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.replayLoaded

proc replayServerModeEnabled(): bool =
  ## Returns true when the process is serving Coworld replay sessions.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.replayServerMode

proc disconnectWebSocket(websocket: WebSocket) =
  ## Tears down a player connection immediately.
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc identityIsKicked(identity: string): bool =
  ## Returns true when an identity is blocked from rejoining this match.
  let rewardIdentity = identity.rewardAddress()
  {.gcsafe.}:
    withLock appState.lock:
      result =
        identity in appState.kickedIdentities or
        rewardIdentity in appState.kickedIdentities

proc respondKicked(request: Request) =
  ## Rejects a kicked player before upgrading to a WebSocket.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(409, headers, "player was kicked\n")

proc respondReplayRequestError(request: Request, status: int, body: string) =
  ## Rejects a replay websocket request before upgrade.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(status, headers, body)

proc respondForbiddenPlayer(request: Request, reason: string) =
  ## Rejects an invalid player join before upgrading to a WebSocket.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc configuredPlayerJoinError(
  config: GameConfig,
  address: string,
  slot: int,
  token: string
): string =
  ## Returns a rejection reason for bad configured roster credentials.
  if config.playerJoinAllowed(address, slot, token):
    return ""
  if slot >= MaxPlayers:
    return "Player slot must be between 0 and 15."
  if slot >= config.slots.len:
    if config.closedRoster:
      return "Player slot is outside configured roster."
    return ""
  if slot >= 0 and config.slots[slot].token.len > 0 and
      token != config.slots[slot].token:
    return "Player token does not match configured slot " & $slot & "."
  "Player credentials do not match configured roster."

proc replayRequestUri(request: Request): string =
  ## Returns the replay artifact URI requested by a Coworld replay client.
  request.queryParams.getOrDefault("uri", "").strip()

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlot()
      token = request.playerToken()
      identity = request.playerIdentity(slot, token)
    {.gcsafe.}:
      withLock appState.lock:
        let joinError = appState.config.configuredPlayerJoinError(
          identity,
          slot,
          token
        )
        if joinError.len > 0:
          request.respondForbiddenPlayer(joinError)
          return
    if identity.identityIsKicked():
      request.respondKicked()
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
    echo "player connected: ", identity
  elif request.path == SpritePlayerWebSocketPath and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    let
      slot = request.playerSlot()
      token = request.playerToken()
      identity = request.playerIdentity(slot, token)
    if identity.identityIsKicked():
      request.respondKicked()
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerViewers[websocket] = initPlayerViewerState()
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
    echo "player connected: ", identity
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path == ReplayWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let replayServerMode = replayServerModeEnabled()
    if replayServerMode:
      let uri = request.replayRequestUri()
      if uri.len == 0:
        request.respondReplayRequestError(400, "missing replay uri\n")
        return
      if not uri.readableReplayUri():
        request.respondReplayRequestError(404, "replay uri is not readable\n")
        return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
        if replayServerMode:
          appState.pendingReplayUri = request.replayRequestUri()
  elif request.path == AdminWebSocketPath and request.httpMethod == "GET" and
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
  elif (request.path == ControlRestartPath or request.path == ControlKickPath) and
      request.httpMethod == "OPTIONS":
    request.respondControl(204, "")
  elif request.path == ControlRestartPath and request.httpMethod == "POST":
    if replayControlsDisabled():
      request.respondControl(409, "match controls are disabled for replays\n")
    else:
      {.gcsafe.}:
        withLock appState.lock:
          appState.resetRequested = true
      request.respondControl(202, "restart queued\n")
  elif request.path == ControlKickPath and request.httpMethod == "POST":
    if replayControlsDisabled():
      request.respondControl(409, "match controls are disabled for replays\n")
    else:
      let identity = request.queryParams.getOrDefault(
        "identity",
        ""
      ).cleanPlayerName()
      if identity.len == 0:
        request.respondControl(400, "missing identity\n")
      else:
        {.gcsafe.}:
          withLock appState.lock:
            appState.kickRequests.add(identity)
        request.respondControl(202, "kick queued\n")
  elif request.serveStaticClientHtml():
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Among Them server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    var closeKickedSocket = false
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.globalViewers and
            websocket notin appState.rewardViewers:
          let
            address = appState.playerAddresses.getOrDefault(websocket, "")
            identity = address.rewardAddress()
            isKicked =
              address in appState.kickedIdentities or
                identity in appState.kickedIdentities
          if isKicked:
            appState.playerAddresses.del(websocket)
            appState.playerSlots.del(websocket)
            appState.playerTokens.del(websocket)
            appState.inputMasks.del(websocket)
            appState.lastAppliedMasks.del(websocket)
            appState.chatMessages.del(websocket)
            closeKickedSocket = true
          elif appState.replayLoaded:
            appState.playerIndices[websocket] = -1
          else:
            appState.playerIndices[websocket] = 0x7fffffff
          if websocket in appState.playerIndices:
            appState.inputMasks[websocket] = 0
            appState.lastAppliedMasks[websocket] = 0
    if closeKickedSocket:
      websocket.disconnectWebSocket()
  of MessageEvent:
    if message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data
            )
          elif websocket in appState.playerViewers and
              not appState.replayLoaded:
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
          elif isInputPacket(message.data) and
              not appState.replayLoaded and
              websocket in appState.playerIndices:
            let mask = blobToMask(message.data)
            if mask == 255'u8:
              appState.resetRequested = true
              appState.inputMasks[websocket] = 0
              appState.lastAppliedMasks[websocket] = 0
            else:
              appState.inputMasks[websocket] = mask
          elif isChatPacket(message.data) and
              not appState.replayLoaded and
              websocket in appState.playerIndices:
            appState.chatMessages[websocket] = blobToChat(message.data)
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        let alreadyClosed = websocket in appState.closedSockets
        appState.closedSockets.add(websocket)
        if not alreadyClosed and websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc rewardAccountFor(sim: SimServer, address: string): int =
  ## Returns the reward account index for one address.
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc addStatLine(
  packet: var string,
  name, identity: string,
  value: int
) =
  ## Appends one metric line to a reward protocol packet.
  packet.add(name)
  packet.add(' ')
  packet.add(identity)
  packet.add(' ')
  packet.add($value)
  packet.add('\n')

proc buildRewardPacket(sim: SimServer): string {.measure.} =
  ## Builds one reward protocol packet for the current tick.
  for player in sim.players:
    let
      identity = player.address.rewardAddress()
      accountIndex = sim.rewardAccountFor(player.address)
    result.addStatLine("reward", identity, player.reward)
    if accountIndex >= 0:
      let account = sim.rewardAccounts[accountIndex]
      result.addStatLine("wins_imposter", identity, account.winsImposter)
      result.addStatLine("wins_crewmate", identity, account.winsCrewmate)
      result.addStatLine("games_imposter", identity, account.gamesImposter)
      result.addStatLine("games_crewmate", identity, account.gamesCrewmate)
      result.addStatLine("kills", identity, account.kills)
      result.addStatLine("tasks", identity, account.tasks)
      result.addStatLine("vote_players", identity, account.votePlayers)
      result.addStatLine("vote_skip", identity, account.voteSkip)
      result.addStatLine("vote_timeout", identity, account.voteTimeout)

let uploadPool = newCurlPool(1)

proc uploadReplayFiles(replayPath, scoresPath: string) =
  ## Uploads replay and scores files to games_server if configured.
  let
    uploadUrl = getEnv("REPLAY_UPLOAD_URL")
    uploadToken = getEnv("REPLAY_UPLOAD_TOKEN")
  if uploadUrl.len == 0 or uploadToken.len == 0:
    return
  let headers = @[
    ("Authorization", "Bearer " & uploadToken),
    ("Content-Type", "application/octet-stream"),
  ]
  if replayPath.len > 0 and fileExists(replayPath):
    let resp = uploadPool.post(uploadUrl, headers, readFile(replayPath))
    if resp.code != 200:
      echo "ERROR: replay upload failed: ", resp.code, " ", resp.body
      return
    echo "Replay uploaded: ", replayPath
  if scoresPath.len > 0 and fileExists(scoresPath):
    let scoreHeaders = @[
      ("Authorization", "Bearer " & uploadToken),
      ("Content-Type", "application/json"),
    ]
    let resp = uploadPool.post(uploadUrl & "/scores", scoreHeaders, readFile(scoresPath))
    if resp.code != 200:
      echo "ERROR: scores upload failed: ", resp.code, " ", resp.body
      return
    echo "Scores uploaded: ", scoresPath

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  saveScoresPath = "",
  replayServerMode = false
) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      loadReplay(loadReplayPath)
    else:
      ReplayData()
  var config =
    if replayLoaded:
      var replayConfig = defaultGameConfig()
      replayConfig.update(replayData.configJson)
      replayConfig
    else:
      initialConfig
  var
    replayWriter = openReplayWriter(saveReplayPath, config.configJson())
    replayPlayer =
      if replayLoaded:
        initReplayPlayer(replayData)
      else:
        ReplayPlayer()
  startProfileTrace()
  defer:
    finishProfileTrace()
    replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded
  appState.replayServerMode = replayServerMode
  appState.config = config

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4
  )
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()

  var
    sim = initSimServer(config)
    lastTick = getMonoTime()
    prevInputs: seq[InputState]
    liveSpeedIndex = 0
    gamesPlayed = 0

  while true:
    var
      pendingReplayUri = ""
      sockets: seq[WebSocket] = @[]
      socketsToClose: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerAddresses: seq[string] = @[]
      inputs: seq[InputState]
      spectatorList: seq[WebSocket] = @[]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      rewardViewers: seq[WebSocket] = @[]
      playerViewerFlags: seq[bool] = @[]
      playerViewerStates: seq[PlayerViewerState] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]
      shouldReset = false
      quitAfterFrame = false

    {.gcsafe.}:
      withLock appState.lock:
        pendingReplayUri = appState.pendingReplayUri
        appState.pendingReplayUri = ""
    if pendingReplayUri.len > 0:
      replayData = loadReplayUri(pendingReplayUri)
      var replayConfig = defaultGameConfig()
      replayConfig.update(replayData.configJson)
      config = replayConfig
      sim = initSimServer(config)
      replayPlayer = initReplayPlayer(replayData)
      replayLoaded = true
      {.gcsafe.}:
        withLock appState.lock:
          appState.replayLoaded = true
          appState.config = config

    {.gcsafe.}:
      withLock appState.lock:
        if not replayLoaded and appState.resetRequested:
          shouldReset = true
          appState.resetRequested = false
          appState.chatMessages.clear()
        for websocket in appState.closedSockets:
          if not replayLoaded and websocket in appState.playerIndices:
            let playerIndex = appState.playerIndices[websocket]
            if playerIndex >= 0 and playerIndex < sim.players.len:
              replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
              if playerIndex < replayWriter.lastMasks.len:
                replayWriter.lastMasks.delete(playerIndex)
              if playerIndex < prevInputs.len:
                prevInputs.delete(playerIndex)
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)
        if not replayLoaded and appState.kickRequests.len > 0:
          let requestedKicks = appState.kickRequests
          appState.kickRequests = @[]
          var socketsToKick: seq[WebSocket] = @[]
          for websocket, address in appState.playerAddresses.pairs:
            let identity = address.rewardAddress()
            for requestedIdentity in requestedKicks:
              if address == requestedIdentity or identity == requestedIdentity:
                appState.kickedIdentities[address] = true
                appState.kickedIdentities[identity] = true
                if websocket notin socketsToKick:
                  socketsToKick.add(websocket)
          for websocket in socketsToKick:
            if websocket in appState.playerIndices:
              let playerIndex = appState.playerIndices[websocket]
              if playerIndex >= 0 and playerIndex < sim.players.len:
                replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
                if playerIndex < replayWriter.lastMasks.len:
                  replayWriter.lastMasks.delete(playerIndex)
                if playerIndex < prevInputs.len:
                  prevInputs.delete(playerIndex)
            sim.removePlayer(websocket)
            socketsToClose.add(websocket)
        if not replayLoaded and sim.phase != Lobby and sim.players.len == 0:
          sim.resetToLobby()
          prevInputs = @[]
          replayWriter.lastMasks = @[]

        if not replayLoaded:
          var newSockets: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              newSockets.add(websocket)
          for websocket in newSockets:
            let address = appState.playerAddresses.getOrDefault(
              websocket,
              "unknown"
            )
            let
              slot = appState.playerSlots.getOrDefault(websocket, -1)
              token = appState.playerTokens.getOrDefault(websocket, "")
            let identity = address.rewardAddress()
            if address in appState.kickedIdentities or
                identity in appState.kickedIdentities:
              sim.removePlayer(websocket)
              socketsToClose.add(websocket)
            elif sim.phase == Lobby and
                (sim.canAddPlayer() or slot >= 0 or token.len > 0):
              try:
                appState.playerIndices[websocket] = sim.addPlayer(
                  address,
                  slot,
                  token
                )
              except AmongThemError:
                sim.removePlayer(websocket)
                socketsToClose.add(websocket)
                continue
              appState.playerSlots[websocket] =
                sim.players[appState.playerIndices[websocket]].joinOrder
              replayWriter.writeJoin(
                tickTime(sim.tickCount),
                appState.playerIndices[websocket],
                address,
                slot,
                token
              )
              while replayWriter.lastMasks.len < sim.players.len:
                replayWriter.lastMasks.add(0)
            else:
              if websocket in appState.playerViewers:
                appState.playerIndices[websocket] = -1
              else:
                appState.spectators.add(websocket)
                appState.playerIndices.del(websocket)

        if not replayLoaded:
          inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          sockets.add(websocket)
          playerIndices.add(playerIndex)
          playerAddresses.add(
            appState.playerAddresses.getOrDefault(websocket, "")
          )
          let isPlayerViewer = websocket in appState.playerViewers
          playerViewerFlags.add(isPlayerViewer)
          if isPlayerViewer:
            playerViewerStates.add(appState.playerViewers[websocket])
          else:
            playerViewerStates.add(initPlayerViewerState())
          if replayLoaded:
            continue
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = decodeInputMask(currentMask)
          if playerIndex < replayWriter.lastMasks.len and
              currentMask != replayWriter.lastMasks[playerIndex]:
            replayWriter.writeInput(ReplayInput(
              time: tickTime(sim.tickCount),
              player: uint8(playerIndex),
              keys: currentMask
            ))
            replayWriter.lastMasks[playerIndex] = currentMask
          appState.lastAppliedMasks[websocket] = currentMask
        if not replayLoaded:
          for websocket, message in appState.chatMessages.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(
              websocket,
              -1
            )
            sim.addVotingChat(playerIndex, message)
          appState.chatMessages.clear()
        spectatorList = appState.spectators
        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          globalStates.add(state)
          if state.replaySeekTick >= 0:
            replaySeekTicks.add(state.replaySeekTick)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1
        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)

    for websocket in socketsToClose:
      websocket.disconnectWebSocket()

    if shouldReset:
      let rewardAccounts = sim.rewardAccounts
      inc config.seed
      sim = initSimServer(config)
      sim.rewardAccounts = rewardAccounts
      prevInputs = @[]
      replayWriter.lastMasks = @[]
      sockets.setLen(0)
      playerIndices.setLen(0)
      playerAddresses.setLen(0)
      spectatorList.setLen(0)
      rewardViewers.setLen(0)
      playerViewerFlags.setLen(0)
      playerViewerStates.setLen(0)
      {.gcsafe.}:
        withLock appState.lock:
          appState.kickedIdentities.clear()
          var reconnectSockets: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            reconnectSockets.add(websocket)
          for websocket in appState.spectators:
            reconnectSockets.add(websocket)
          appState.spectators = @[]
          for websocket in reconnectSockets:
            let address = appState.playerAddresses.getOrDefault(
              websocket,
              "unknown"
            )
            let
              slot = appState.playerSlots.getOrDefault(websocket, -1)
              token = appState.playerTokens.getOrDefault(websocket, "")
            if not sim.canAddPlayer() and slot < 0 and token.len == 0:
              if websocket in appState.playerViewers:
                appState.playerIndices[websocket] = -1
              else:
                appState.spectators.add(websocket)
                appState.playerIndices.del(websocket)
              continue
            try:
              appState.playerIndices[websocket] = sim.addPlayer(
                address,
                slot,
                token
              )
            except AmongThemError:
              sim.removePlayer(websocket)
              socketsToClose.add(websocket)
              continue
            appState.playerSlots[websocket] =
              sim.players[appState.playerIndices[websocket]].joinOrder
            appState.inputMasks[websocket] = 0
            appState.lastAppliedMasks[websocket] = 0
            let isPlayerViewer = websocket in appState.playerViewers
            sockets.add(websocket)
            playerIndices.add(appState.playerIndices[websocket])
            playerAddresses.add(address)
            playerViewerFlags.add(isPlayerViewer)
            if isPlayerViewer:
              appState.playerViewers[websocket] = initPlayerViewerState()
              playerViewerStates.add(appState.playerViewers[websocket])
            else:
              playerViewerStates.add(initPlayerViewerState())
          replayWriter.lastMasks.setLen(sim.players.len)
          for websocket in appState.rewardViewers.keys:
            rewardViewers.add(websocket)

      let rewardPacket = sim.buildRewardPacket()
      for i in 0 ..< sockets.len:
        if not sim.shouldSendPlayerFrame(
          playerAddresses[i],
          playerViewerFlags[i]
        ):
          continue
        let framePacket =
          if playerViewerFlags[i]:
            var nextState: PlayerViewerState
            let packet = sim.buildSpriteProtocolPlayerUpdates(
              playerIndices[i],
              playerViewerStates[i],
              nextState
            )
            {.gcsafe.}:
              withLock appState.lock:
                if sockets[i] in appState.playerViewers:
                  appState.playerViewers[sockets[i]] = nextState
            packet
          else:
            sim.render(playerIndices[i])
        let frameBlob = blobFromBytes(framePacket)
        sockets[i].send(frameBlob, BinaryMessage)
      for websocket in rewardViewers:
        websocket.send(rewardPacket, TextMessage)
      runFrameLimiter(lastTick)
      continue

    if replayLoaded:
      for seekTick in replaySeekTicks:
        replayPlayer.applyReplaySeek(sim, seekTick)
      for command in replayCommands:
        replayPlayer.applyReplayCommand(sim, command)
      if replayPlayer.playing:
        for _ in 0 ..< replayPlayer.replaySpeed():
          if replayPlayer.playing:
            replayPlayer.stepReplay(sim)
        if replayPlayer.looping and not replayPlayer.playing:
          replayPlayer.seekReplay(sim, 0)
          replayPlayer.playing = true
    else:
      for command in replayCommands:
        liveSpeedIndex.applySpeedCommand(command)
      var stepPrevInputs = prevInputs
      for _ in 0 ..< playbackSpeed(liveSpeedIndex):
        let phaseBeforeStep = sim.phase
        sim.step(inputs, stepPrevInputs)
        stepPrevInputs = inputs
        replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
        if config.maxGames > 0 and phaseBeforeStep != GameOver and
            sim.phase == GameOver:
          inc gamesPlayed
          if gamesPlayed >= config.maxGames:
            quitAfterFrame = true
            break
        if sim.needsReregister:
          break
      prevInputs = inputs

    let rewardPacket = sim.buildRewardPacket()

    if not replayLoaded and sim.needsReregister:
      sim.needsReregister = false
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            appState.playerIndices[websocket] = 0x7fffffff
          for websocket in appState.spectators:
            appState.playerIndices[websocket] = 0x7fffffff
          for websocket in appState.playerViewers.keys:
            appState.playerViewers[websocket] = initPlayerViewerState()
          appState.spectators = @[]

    for i in 0 ..< sockets.len:
      if not sim.shouldSendPlayerFrame(
        playerAddresses[i],
        playerViewerFlags[i]
      ):
        continue
      let framePacket =
        if playerViewerFlags[i]:
          var nextState: PlayerViewerState
          let packet = sim.buildSpriteProtocolPlayerUpdates(
            playerIndices[i],
            playerViewerStates[i],
            nextState
          )
          {.gcsafe.}:
            withLock appState.lock:
              if sockets[i] in appState.playerViewers:
                appState.playerViewers[sockets[i]] = nextState
          packet
        elif replayLoaded:
          sim.buildReplayFramePacket()
        else:
          sim.render(playerIndices[i])
      let frameBlob = blobFromBytes(framePacket)
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    if spectatorList.len > 0:
      let specBlob = blobFromBytes(sim.buildSpectatorFrame())
      for ws in spectatorList:
        try:
          ws.send(specBlob, BinaryMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              sim.removePlayer(ws)

    for websocket in rewardViewers:
      try:
        websocket.send(rewardPacket, TextMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(websocket)

    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      let packet = sim.buildSpriteProtocolUpdates(
        globalStates[i],
        nextState,
        sim.tickCount,
        replayPlayer.playing,
        if replayLoaded: replayPlayer.replaySpeed()
        else: playbackSpeed(liveSpeedIndex),
        if replayLoaded: replayPlayer.replayMaxTick()
        else: liveProgressMaxTick(config),
        replayPlayer.looping,
        replayLoaded
      )
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

    if profileShouldDump(sim.gameTicksElapsed()):
      finishProfileTrace()

    if quitAfterFrame:
      replayWriter.closeReplayWriter()
      if saveScoresPath.len > 0:
        writeFile(saveScoresPath, sim.playerResultsJson() & "\n")
      uploadReplayFiles(saveReplayPath, saveScoresPath)
      httpServer.close()
      joinThread(serverThread)
      break

    runFrameLimiter(lastTick)

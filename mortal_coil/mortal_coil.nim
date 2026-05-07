import mummy
import protocol, server
import std/[locks, monotimes, os, parseopt, random, strutils, tables, times]
import bitworld/clients

const
  TargetFps = 24.0
  WebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  BackgroundColor = 1'u8
  MaxPlayers = 8
  MinPlayers = 4
  LobbyCountdownTicks = 24 * 10

type
  GamePhase = enum
    PhaseLobby
    PhaseSetup
    PhaseFact
    PhaseConflict
    PhasePower
    PhaseEnd

  Player = object
    name: string
    colorIndex: int
    ready: bool

  SimServer = object
    players: seq[Player]
    phase: GamePhase
    tick: int
    lobbyCountdown: int
    fb: Framebuffer
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]
    rng: Rand

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    chatMessages: Table[WebSocket, string]
    closedSockets: seq[WebSocket]
    globalViewers: Table[WebSocket, bool]

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
  appState.chatMessages = initTable[WebSocket, string]()
  appState.closedSockets = @[]
  appState.globalViewers = initTable[WebSocket, bool]()

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)

proc addPlayer(sim: var SimServer, name: string): int =
  if sim.players.len >= MaxPlayers:
    return -1
  let idx = sim.players.len
  sim.players.add(Player(
    name: if name.len > 0: name else: "Player" & $(idx + 1),
    colorIndex: (idx mod 8) + 3,
    ready: false
  ))
  idx

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket notin appState.playerIndices:
    return
  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.playerNames.del(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc fillRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  for py in y ..< y + h:
    for px in x ..< x + w:
      fb.putPixel(px, py, color)

proc renderLobby(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let title = "mortal coil"
  sim.fb.blitText(sim.letterSprites, title, 20, 10)

  let waiting = "waiting"
  sim.fb.blitText(sim.letterSprites, waiting, 34, 30)

  let countText = $sim.players.len & " of " & $MinPlayers
  sim.fb.blitText(sim.letterSprites, countText, 34, 42)

  for i, player in sim.players:
    let y = 56 + i * 8
    sim.fb.fillRect(10, y, 4, 4, uint8(player.colorIndex))
    let displayName = if player.name.len > 16: player.name[0..15] else: player.name
    sim.fb.blitText(sim.letterSprites, displayName, 18, y)

  if sim.players.len >= MinPlayers and sim.lobbyCountdown > 0:
    let seconds = (sim.lobbyCountdown + 23) div 24
    let startText = "start in " & $seconds
    sim.fb.blitText(sim.letterSprites, startText, 28, 118)

proc renderGame(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let phaseText = case sim.phase
    of PhaseLobby: "lobby"
    of PhaseSetup: "setup"
    of PhaseFact: "facts"
    of PhaseConflict: "conflict"
    of PhasePower: "power"
    of PhaseEnd: "end"
  sim.fb.blitText(sim.letterSprites, phaseText, 4, 4)

proc render(sim: var SimServer) =
  case sim.phase
  of PhaseLobby:
    sim.renderLobby()
  else:
    sim.renderGame()

proc step(sim: var SimServer, inputs: seq[InputState]) =
  inc sim.tick
  case sim.phase
  of PhaseLobby:
    if sim.players.len >= MinPlayers:
      if sim.lobbyCountdown <= 0:
        sim.lobbyCountdown = LobbyCountdownTicks
      else:
        dec sim.lobbyCountdown
        if sim.lobbyCountdown <= 0:
          sim.phase = PhaseSetup
    else:
      sim.lobbyCountdown = 0
  else:
    discard

proc buildFramePacket(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.render()
  sim.fb.packFramebuffer()
  result = newSeq[uint8](ProtocolBytes)
  for i in 0 ..< ProtocolBytes:
    result[i] = sim.fb.packed[i]

proc buildGlobalPacket(sim: var SimServer): seq[uint8] =
  sim.render()
  sim.fb.packFramebuffer()
  result = newSeq[uint8](ProtocolBytes)
  for i in 0 ..< ProtocolBytes:
    result[i] = sim.fb.packed[i]

proc initSim(seed: int): SimServer =
  result.phase = PhaseLobby
  result.tick = 0
  result.lobbyCountdown = 0
  result.rng = initRand(seed)
  result.fb = initFramebuffer()

  let dataDir = clientsDir() / "data"
  result.digitSprites = loadDigitSprites(dataDir / "numbers.png")
  result.letterSprites = loadLetterSprites(dataDir / "letters.png")
  loadPalette(dataDir / "pallete.png")

proc playerIdentity(request: Request): string =
  let uri = request.uri
  let qPos = uri.find('?')
  if qPos < 0:
    return "player"
  let query = uri[qPos + 1 .. ^1]
  for param in query.split('&'):
    let kv = param.split('=', 1)
    if kv.len == 2 and kv[0] == "name":
      return kv[1]
  "player"

proc serveClientHtml(request: Request, route: string): bool =
  if request.httpMethod != "GET":
    return false
  let filePath = clientStaticPath(route)
  if filePath.len == 0:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(route)
  headers["Cache-Control"] = "no-cache"
  if not fileExists(filePath):
    request.respond(404, headers, "Not found: " & route)
    return true
  try:
    request.respond(200, headers, readFile(filePath))
  except IOError as e:
    request.respond(500, headers, "Error: " & e.msg)
  true

proc serveStaticClientHtml(request: Request): bool =
  request.serveClientHtml(request.path)

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET" and
      request.headers["Sec-WebSocket-Key"].len == 0:
    discard request.serveClientHtml(PlayerClientRoute)
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      request.headers["Sec-WebSocket-Key"].len == 0:
    discard request.serveClientHtml(GlobalClientRoute)
  elif request.path == WebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerNames[websocket] = request.playerIdentity()
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = true
  elif request.serveStaticClientHtml():
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Mortal Coil server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.globalViewers:
          appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if isInputPacket(message.data):
            appState.inputMasks[websocket] = blobToMask(message.data)
          elif isChatPacket(message.data):
            appState.chatMessages[websocket] = blobToChat(message.data)
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(milliseconds = int(1000.0 / TargetFps))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop(host = DefaultHost, port = DefaultPort, seed = 0) =
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

  echo "Mortal Coil running on ", host, ":", port
  echo "  Player: http://", host, ":", port, "/player"
  echo "  Global: http://", host, ":", port, "/global"

  var
    sim = initSim(seed)
    lastTick = getMonoTime()

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]
      globalViewers: seq[WebSocket] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
          appState.globalViewers.del(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == 0x7fffffff:
            let name = appState.playerNames.getOrDefault(websocket, "")
            let idx = sim.addPlayer(name)
            if idx >= 0:
              appState.playerIndices[websocket] = idx
              echo "Player joined: ", sim.players[idx].name

        inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let
            currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = inputStateFromMasks(currentMask, previousMask)
          appState.lastAppliedMasks[websocket] = currentMask
          sockets.add(websocket)
          playerIndices.add(playerIndex)

        for websocket in appState.globalViewers.keys:
          globalViewers.add(websocket)

    sim.step(inputs)

    for i in 0 ..< sockets.len:
      let frameBlob = blobFromBytes(sim.buildFramePacket(playerIndices[i]))
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    if globalViewers.len > 0:
      let globalBlob = blobFromBytes(sim.buildGlobalPacket())
      for viewer in globalViewers:
        try:
          viewer.send(globalBlob, BinaryMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              appState.globalViewers.del(viewer)

    runFrameLimiter(lastTick)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    seed = 0
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      of "seed": seed = parseInt(val)
      else: discard
    else: discard
  runServerLoop(address, port, seed)

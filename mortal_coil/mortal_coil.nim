import mummy
import protocol, server, soul, data, output, render_utils, world, magical_facts, situation, conflict
import std/[exitprocs, locks, monotimes, os, osproc, parseopt, random, strutils, tables, times]
import windy
import bitworld/clients

const
  TargetFps = 24.0
  WebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  BackgroundColor = 1'u8
  MaxPlayers = 8
  DefaultMinPlayers = 4
  LobbyCountdownTicks = 24 * 5
  ClientScreenOnlyWidth = 384
  ClientScreenOnlyHeight = 384
  ClientWindowMargin = 50
  PlayerClientSourceRelative = "clients" / "player_client.nim"

type
  SimServer = object
    players: seq[Player]
    phase: GamePhase
    tick: int
    lobbyCountdown: int
    minPlayers: int
    currentTurn: int
    chatLog: seq[ChatEntry]
    factChoice: FactChoice
    factTimer: int
    worldStep: WorldStep
    worldTimer: int
    world: World
    situationStep: SituationStep
    situationTimer: int
    situation: Situation
    situations: seq[Situation]
    sceneState: SceneState
    sceneTimer: int
    sceneTurnOrder: seq[int]
    sceneTurnIndex: int
    conflict: Conflict
    conflictState: ConflictState
    conflictTimer: int
    fb: Framebuffer
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]
    rng: Rand
    prevInputs: seq[InputState]
    chatScroll: int
    chatConfirmed: seq[bool]
    chatInterrupted: seq[bool]

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

proc addPlayer(sim: var SimServer, name: string, kind: PlayerKind = PlayerHuman): int =
  if sim.players.len >= MaxPlayers:
    return -1
  let idx = sim.players.len
  sim.players.add(Player(
    name: if name.len > 0: name else: "Player" & $(idx + 1),
    colorIndex: (idx mod 8) + 3,
    ready: false,
    kind: kind,
    soul: newSoul(),
    cursor: 0,
    magicTokens: 4
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

proc startFactTurn(sim: var SimServer) =
  magical_facts.startFactTurn(sim.factChoice, sim.factTimer)

proc renderLobby(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let title = "mortal coil"
  sim.fb.blitText(sim.letterSprites, title, 20, 10)

  let countText = $sim.players.len & " of " & $sim.minPlayers
  sim.fb.blitText(sim.letterSprites, sim.digitSprites, countText, 34, 30)

  for i, player in sim.players:
    let y = 44 + i * 8
    sim.fb.fillRect(10, y, 4, 4, uint8(player.colorIndex))
    let displayName = if player.name.len > 16: player.name[0..15] else: player.name
    sim.fb.blitText(sim.letterSprites, displayName, 18, y)

  if sim.players.len >= sim.minPlayers and sim.lobbyCountdown > 0:
    let seconds = (sim.lobbyCountdown + 23) div 24
    let startText = "start in " & $seconds
    sim.fb.blitText(sim.letterSprites, sim.digitSprites, startText, 28, 118)

proc renderWorld(sim: var SimServer) =
  world.renderWorld(sim.fb, sim.letterSprites, sim.digitSprites, sim.world, sim.worldStep)

proc renderSituation(sim: var SimServer) =
  situation.renderSituation(sim.fb, sim.letterSprites, sim.digitSprites,
    sim.players, sim.currentTurn, sim.situationStep, sim.situation, sim.sceneState)

proc renderConflictPhase(sim: var SimServer) =
  conflict.renderConflict(sim.fb, sim.letterSprites, sim.digitSprites,
    sim.players, sim.currentTurn, sim.conflictState, sim.conflict)

proc renderFact(sim: var SimServer) =
  magical_facts.renderFact(sim.fb, sim.letterSprites, sim.digitSprites,
    sim.players, sim.currentTurn, sim.factChoice, sim.chatLog, sim.chatScroll)

proc renderGame(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let phaseText = case sim.phase
    of PhaseLobby: "lobby"
    of PhaseWorld: "the world"
    of PhaseMagicalFacts: "magical facts"
    of PhaseSituation: "situation"
    of PhaseConflict: "conflict"
    of PhasePower: "power"
    of PhaseEnd: "end"
  sim.fb.blitText(sim.letterSprites, phaseText, 4, 4)

proc render(sim: var SimServer) =
  case sim.phase
  of PhaseLobby:
    sim.renderLobby()
  of PhaseWorld:
    sim.renderWorld()
  of PhaseMagicalFacts:
    sim.renderFact()
  of PhaseSituation:
    sim.renderSituation()
  of PhaseConflict:
    sim.renderConflictPhase()
  else:
    sim.renderGame()

proc step(sim: var SimServer, inputs: seq[InputState]) =
  inc sim.tick
  case sim.phase
  of PhaseLobby:
    if sim.players.len >= sim.minPlayers:
      if sim.lobbyCountdown <= 0:
        sim.lobbyCountdown = LobbyCountdownTicks
      else:
        dec sim.lobbyCountdown
        if sim.lobbyCountdown <= 0:
          sim.phase = PhaseWorld
          sim.worldStep = WorldGazing
          sim.worldTimer = 1
    else:
      sim.lobbyCountdown = 0
  of PhaseWorld:
    let result = stepWorld(sim.worldStep, sim.worldTimer, sim.world, sim.players)
    if result == WorldDone:
      sim.phase = PhaseMagicalFacts
      sim.currentTurn = 0
      sim.chatLog = @[]
      sim.startFactTurn()
      logMagicalFactsPhase()
  of PhaseMagicalFacts:
    if sim.players.len == 0:
      sim.phase = PhaseLobby
      return
    let factsResult = stepMagicalFacts(sim.players, sim.currentTurn,
      sim.factChoice, sim.factTimer, sim.chatLog, sim.chatScroll,
      sim.chatConfirmed, sim.chatInterrupted, sim.world, sim.rng,
      inputs, sim.prevInputs)
    if factsResult == FactsDone:
      sim.currentTurn = 0
      sim.phase = PhaseSituation
      sim.situationStep = SituationGazing
      sim.situationTimer = 1
      return
  of PhaseSituation:
    let sitResult = stepSituation(sim.players, sim.currentTurn,
      sim.situationStep, sim.situationTimer, sim.situation, sim.situations,
      sim.sceneState, sim.sceneTimer, sim.sceneTurnOrder, sim.sceneTurnIndex,
      sim.world, sim.chatLog, sim.rng, inputs, sim.prevInputs)
    if sitResult == SituationDone:
      sim.phase = PhaseConflict
      sim.conflictState = ConflictState(step: ConflictGazing, round: 0)
      sim.conflictTimer = 1
  of PhaseConflict:
    let conflictResult = stepConflict(sim.players, sim.currentTurn,
      sim.conflictState, sim.conflictTimer, sim.conflict,
      sim.world, sim.situation, sim.chatLog, sim.rng, inputs, sim.prevInputs)
    if conflictResult == ConflictDone:
      var allSpent = true
      for p in sim.players:
        if p.magicTokens > 0:
          allSpent = false
          break
      if allSpent:
        sim.phase = PhaseEnd
      else:
        sim.phase = PhaseMagicalFacts
        sim.currentTurn = 0
        sim.startFactTurn()
        logMagicalFactsPhase()
  else:
    discard
  sim.prevInputs = inputs

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

proc initSim(seed: int, minPlayers: int): SimServer =
  result.phase = PhaseLobby
  result.tick = 0
  result.lobbyCountdown = 0
  result.minPlayers = minPlayers
  result.currentTurn = 0
  result.chatLog = @[]
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

proc serveGlobalViewer(request: Request): bool =
  if request.httpMethod != "GET":
    return false
  let route = request.path
  if route != GlobalClientRoute and route != GlobalClientHtmlRoute and
     route != CoworldGlobalClientRoute:
    return false
  let filePath = clientStaticPath(PlayerClientRoute)
  if filePath.len == 0 or not fileExists(filePath):
    return false
  var html = readFile(filePath)
  html = html.replace("/player", "/global")
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, html)
  true

proc serveStaticClientHtml(request: Request): bool =
  ## Serves one static client asset if the route matches.
  if request.serveGlobalViewer():
    return true
  request.serveClientHtml(request.path)

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET" and
      request.headers["Sec-WebSocket-Key"].len > 0:
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerNames[websocket] = request.playerIdentity()
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      request.headers["Sec-WebSocket-Key"].len > 0:
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

var
  clientProcesses: seq[Process]
  guiCleanupStarted = false

proc primaryScreen(): Screen =
  let screens = getScreens()
  if screens.len > 0:
    for screen in screens:
      if screen.primary:
        return screen
    return screens[0]
  Screen(left: 0, right: 1920, top: 0, bottom: 1080, primary: true)

proc clientLaunches(players: int): seq[tuple[title: string, x, y: int]] =
  let screen = primaryScreen()
  let rowCounts =
    case players
    of 1: @[1]
    of 2: @[2]
    of 3: @[3]
    of 4: @[2, 2]
    of 5: @[3, 2]
    of 6: @[3, 3]
    of 7: @[4, 3]
    of 8: @[4, 4]
    else: @[4, 4]

  let
    totalHeight =
      rowCounts.len * ClientScreenOnlyHeight +
      max(0, rowCounts.len - 1) * ClientWindowMargin
    startY = screen.top + (screen.bottom - screen.top - totalHeight) div 2

  for rowIndex, rowCount in rowCounts:
    let
      rowWidth =
        rowCount * ClientScreenOnlyWidth +
        max(0, rowCount - 1) * ClientWindowMargin
      startX = screen.left + (screen.right - screen.left - rowWidth) div 2
      y = startY + rowIndex * (ClientScreenOnlyHeight + ClientWindowMargin)

    for col in 0 ..< rowCount:
      let playerNumber = result.len + 1
      result.add((
        title: "Mortal Coil Player " & $playerNumber,
        x: startX + col * (ClientScreenOnlyWidth + ClientWindowMargin),
        y: y
      ))

proc stopClientProcesses() =
  if guiCleanupStarted:
    return
  guiCleanupStarted = true
  for i in countdown(clientProcesses.high, 0):
    if clientProcesses[i].isNil:
      continue
    try:
      if clientProcesses[i].peekExitCode() == -1:
        clientProcesses[i].terminate()
        for _ in 0 ..< 20:
          if clientProcesses[i].peekExitCode() != -1:
            break
          sleep(100)
        if clientProcesses[i].peekExitCode() == -1:
          clientProcesses[i].kill()
    except CatchableError:
      discard
    try:
      clientProcesses[i].close()
    except CatchableError:
      discard
  clientProcesses.setLen(0)

proc guiCleanupAtExit() {.noconv.} =
  stopClientProcesses()

proc guiControlCHook() {.noconv.} =
  stopClientProcesses()
  quit(130)

proc exePathFor(sourceRelative: string): string =
  let exeName = sourceRelative.splitFile().name.addFileExt(ExeExts[0])
  repoDir() / "out" / exeName

proc launchGuiClients(address: string, port: int, players: int) =
  let
    clientExe = exePathFor(PlayerClientSourceRelative)
    clientWorkDir = repoDir() / "clients"
    connectAddress =
      if address == "0.0.0.0" or address == "::": "127.0.0.1"
      else: address
    launches = clientLaunches(players)

  if not fileExists(clientExe):
    echo "GUI: player_client not compiled. Run: nim c ", PlayerClientSourceRelative
    return

  addExitProc(guiCleanupAtExit)
  setControlCHook(guiControlCHook)

  for i, launch in launches:
    let wsUrl = "ws://" & connectAddress & ":" & $port &
      "/player?name=player" & $(i + 1)
    let args = @[
      "--address:" & wsUrl,
      "--screen-only",
      "--title:" & launch.title,
      "--joystick:" & $(i + 1),
      "--x:" & $launch.x,
      "--y:" & $launch.y,
      "--reconnect:1"
    ]
    try:
      clientProcesses.add(startProcess(
        clientExe,
        workingDir = clientWorkDir,
        args = args,
        options = {poParentStreams}
      ))
      echo "  GUI: launched ", launch.title
    except CatchableError as e:
      echo "  GUI: failed to start player ", i + 1, ": ", e.msg

proc runServerLoop(host = DefaultHost, port = DefaultPort, seed = 0,
                   gui = false, players = DefaultMinPlayers, bots = 0) =
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
  echo "  Player: http://", host, ":", port, PlayerClientRoute
  echo "  Global: http://", host, ":", port, GlobalClientRoute

  if gui:
    launchGuiClients(host, port, players)

  var
    sim = initSim(seed, players)
    lastTick = getMonoTime()

  for i in 0 ..< bots:
    let botName = "bot" & $(i + 1)
    discard sim.addPlayer(botName, PlayerBot)

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

        for websocket, msg in appState.chatMessages.pairs:
          let playerIndex = appState.playerIndices.getOrDefault(websocket, -1)
          if playerIndex >= 0 and playerIndex < sim.players.len:
            if msg.startsWith("/passions "):
              let passionStr = msg["/passions ".len .. ^1]
              sim.players[playerIndex].soul.passions = passionStr.split(",")
              for i in 0 ..< sim.players[playerIndex].soul.passions.len:
                sim.players[playerIndex].soul.passions[i] =
                  sim.players[playerIndex].soul.passions[i].strip()
        appState.chatMessages.clear()

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
    gui = false
    players = DefaultMinPlayers
    bots = 0
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      of "seed": seed = parseInt(val)
      of "gui": gui = true
      of "players": players = parseInt(val)
      of "bots": bots = parseInt(val)
      else: discard
    else: discard
  runServerLoop(address, port, seed, gui, players, bots)

import mummy
import protocol, server, soul, data, render_utils, world, magical_facts, situation, conflict
import sprite_viewer
import std/[exitprocs, locks, monotimes, os, osproc, parseopt, random, strutils, tables, times]
import windy
import bitworld/clients

const
  TargetFps = 24.0
  WebSocketPath = "/player"
  BackgroundColor = 0'u8
  MaxPlayers = 8
  DefaultMinPlayers = 4
  LobbyCountdownTicks = 24 * 5
  ClientScreenOnlyWidth = 384
  ClientScreenOnlyHeight = 384
  ClientWindowMargin = 50
  PlayerClientSourceRelative = "clients" / "global_client.nim"
  HealthzPath = "/healthz"

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
    chapter: int
    fb: Framebuffer
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
    playerViewers: Table[WebSocket, SpriteViewerState]
    globalViewers: Table[WebSocket, SpriteViewerState]
    rewardViewers: Table[WebSocket, bool]

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
  appState.playerViewers = initTable[WebSocket, SpriteViewerState]()
  appState.globalViewers = initTable[WebSocket, SpriteViewerState]()
  appState.rewardViewers = initTable[WebSocket, bool]()

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)

proc addPlayer(sim: var SimServer, name: string, kind: PlayerKind = PlayerHuman): int =
  if sim.players.len >= MaxPlayers:
    return -1
  let idx = sim.players.len
  sim.players.add(Player(
    name: if name.len > 1: name[0..0].toUpperAscii & name[1..^1]
          elif name.len == 1: name.toUpperAscii
          else: "Player" & $(idx + 1),
    colorIndex: (idx mod 8) + 3,
    ready: false,
    kind: kind,
    soul: newSoul(),
    cursor: 0,
    power: 4
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
  appState.playerViewers.del(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc startFactTurn(sim: var SimServer) =
  magical_facts.startFactTurn(sim.factChoice, sim.factTimer)

proc renderLobby(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let title = "Mortal Coil"
  sim.fb.drawText(title, 20, 10)

  let countText = $sim.players.len & " of " & $sim.minPlayers
  sim.fb.drawText(countText, 34, 30)

  for i, player in sim.players:
    let y = 44 + i * 8
    sim.fb.fillRect(10, y, 4, 4, uint8(player.colorIndex))
    let displayName = if player.name.len > 16: player.name[0..15] else: player.name
    sim.fb.drawText(displayName, 18, y)

  if sim.players.len >= sim.minPlayers and sim.lobbyCountdown > 0:
    let seconds = (sim.lobbyCountdown + 23) div 24
    let startText = "Start in " & $seconds
    sim.fb.drawText(startText, 28, 118)

proc renderWorld(sim: var SimServer) =
  world.renderWorld(sim.fb, sim.world, sim.worldStep)

proc renderSituation(sim: var SimServer) =
  situation.renderSituation(sim.fb, sim.players, sim.currentTurn,
    sim.situationStep, sim.situation, sim.sceneState)

proc renderConflictPhase(sim: var SimServer) =
  conflict.renderConflict(sim.fb, sim.players, sim.currentTurn,
    sim.conflictState, sim.conflict, sim.chapter)

proc renderFact(sim: var SimServer) =
  magical_facts.renderFact(sim.fb, sim.players, sim.currentTurn,
    sim.factChoice, sim.chatLog, sim.chatScroll)

proc renderGame(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let phaseText = case sim.phase
    of PhaseLobby: "Lobby"
    of PhaseWorld: "The World"
    of PhaseMagicalFacts: "Magical Facts"
    of PhaseSituation: "Situation"
    of PhaseConflict: "Chapter " & $sim.chapter
    of PhasePower: "Power"
    of PhaseEnd: "End"
  sim.fb.drawText(phaseText, 4, 4)

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
      sim.currentTurn = 0
      sim.chatLog = @[]
      sim.chapter = 1
      sim.phase = PhaseConflict
      sim.conflictState = ConflictState(step: ConflictGazing, round: 0)
      sim.conflictTimer = 1
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
      sim.chapter = 1
      sim.phase = PhaseConflict
      sim.conflictState = ConflictState(step: ConflictGazing, round: 0)
      sim.conflictTimer = 1
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
      sim.world, sim.situation, sim.chatLog, sim.rng, inputs, sim.prevInputs,
      sim.chapter)
    if conflictResult == ConflictDone:
      var allSpent = true
      for p in sim.players:
        if p.power > 0:
          allSpent = false
          break
      if allSpent:
        sim.phase = PhaseEnd
      else:
        sim.currentTurn = 0
        sim.chapter += 1
        sim.phase = PhaseConflict
        sim.conflictState = ConflictState(step: ConflictGazing, round: 0)
        sim.conflictTimer = 1
  else:
    discard
  sim.prevInputs = inputs

proc buildTextSprites(sim: SimServer): seq[TextSprite] =
  var nextId = 1
  let white = WhiteColor
  let grey = 5'u8

  template sprite(sx, sy: int, stext, slabel: string, scolor: uint8 = white) =
    result.add(TextSprite(id: nextId, x: sx, y: sy, text: stext, label: slabel, color: scolor))
    inc nextId

  # Always show phase + players as labels on a hidden sprite
  var meta = "phase:" & $sim.phase
  var playerList = ""
  for i, p in sim.players:
    if i > 0: playerList.add(" ")
    playerList.add(p.name & "(" & $p.power & ")")
  meta.add("\nplayers:" & playerList)

  case sim.phase
  of PhaseLobby:
    meta.add("\ncount:" & $sim.players.len & "/" & $sim.minPlayers)
    sprite(20, 10, "Mortal Coil", meta, grey)
    sprite(34, 30, $sim.players.len & " of " & $sim.minPlayers, "count:" & $sim.players.len & "/" & $sim.minPlayers)
    for i, player in sim.players:
      let y = 44 + i * 8
      sprite(18, y, player.name, "player:" & player.name, uint8(player.colorIndex))
    if sim.lobbyCountdown > 0:
      let s = (sim.lobbyCountdown + 23) div 24
      sprite(28, 118, "Start in " & $s, "countdown:" & $s)

  of PhaseWorld:
    meta.add("\nstep:" & $sim.worldStep)
    if sim.world.title.len > 0:
      meta.add("\ntitle:" & sim.world.title)
      sprite(4, 4, sim.world.title, meta, grey)
    else:
      sprite(4, 4, "The World", meta, grey)
    if sim.world.description.len > 0:
      sprite(4, 20, sim.world.description, "text:" & sim.world.description)

  of PhaseMagicalFacts:
    meta.add("\nstep:" & $sim.factChoice.step)
    if sim.currentTurn >= 0 and sim.currentTurn < sim.players.len:
      meta.add("\nturn:" & sim.players[sim.currentTurn].name)
    sprite(4, 4, "Magical Facts", meta, grey)

  of PhaseSituation:
    meta.add("\nstep:" & $sim.situationStep)
    if sim.currentTurn >= 0 and sim.currentTurn < sim.players.len:
      meta.add("\nturn:" & sim.players[sim.currentTurn].name)
    if sim.situationStep == SituationChoices:
      let turnName = if sim.currentTurn >= 0 and sim.currentTurn < sim.players.len:
          sim.players[sim.currentTurn].name else: "?"
      let turnColor = if sim.currentTurn >= 0 and sim.currentTurn < sim.players.len:
          uint8(sim.players[sim.currentTurn].colorIndex) else: white
      sprite(4, 4, turnName & "'s turn:", meta, turnColor)
      let maxW = ScreenWidth - 4
      var optY = 12
      if sim.sceneState.header.len > 0:
        sprite(4, optY, sim.sceneState.header, "header:" & sim.sceneState.header)
        optY += textHeight(sim.sceneState.header, maxW) + 2
      for i, opt in sim.sceneState.choice.options:
        let sel = sim.sceneState.choice.selected == i
        let cur = sim.sceneState.choice.cursor == i
        let prefix = if sel: "> " elif cur: "* " else: "  "
        let text = prefix & opt
        optY += 5
        sprite(4, optY, text, "option" & $(i+1) & ":" & opt)
        optY += textHeight(text, maxW) + 1
      if sim.sceneState.choice.extraOption.len > 0:
        optY += 5
        let ei = sim.sceneState.choice.options.len
        let sel = sim.sceneState.choice.selected == ei
        let cur = sim.sceneState.choice.cursor == ei
        let prefix = if sel: "> " elif cur: "* " else: "  "
        sprite(4, optY, prefix & sim.sceneState.choice.extraOption,
          "option" & $(ei+1) & ":" & sim.sceneState.choice.extraOption)
      sprite(0, 0, "", "cursor:" & $sim.sceneState.choice.cursor & "\nselected:" & $sim.sceneState.choice.selected)
    else:
      if sim.situation.title.len > 0:
        sprite(4, 4, "Situation: " & sim.situation.title, meta, grey)
      else:
        sprite(4, 4, "Situation", meta, grey)
      if sim.situation.description.len > 0:
        sprite(4, 20, sim.situation.description, "text:" & sim.situation.description)

  of PhaseConflict:
    meta.add("\nchapter:" & $sim.chapter)
    meta.add("\nstep:" & $sim.conflictState.step)
    if sim.currentTurn >= 0 and sim.currentTurn < sim.players.len:
      meta.add("\nturn:" & sim.players[sim.currentTurn].name)
    if sim.conflictState.step == ConflictChoices:
      let turnName = if sim.currentTurn >= 0 and sim.currentTurn < sim.players.len:
          sim.players[sim.currentTurn].name else: "?"
      let turnColor = if sim.currentTurn >= 0 and sim.currentTurn < sim.players.len:
          uint8(sim.players[sim.currentTurn].colorIndex) else: white
      sprite(4, 4, turnName & "'s turn:", meta, turnColor)
      let maxW = ScreenWidth - 4
      var optY = 12
      if sim.conflictState.sceneState.header.len > 0:
        sprite(4, optY, sim.conflictState.sceneState.header, "header:" & sim.conflictState.sceneState.header)
        optY += textHeight(sim.conflictState.sceneState.header, maxW) + 2
      for i, opt in sim.conflictState.sceneState.choice.options:
        let sel = sim.conflictState.sceneState.choice.selected == i
        let cur = sim.conflictState.sceneState.choice.cursor == i
        let prefix = if sel: "> " elif cur: "* " else: "  "
        let text = prefix & opt
        optY += 5
        sprite(4, optY, text, "option" & $(i+1) & ":" & opt)
        optY += textHeight(text, maxW) + 1
      if sim.conflictState.sceneState.choice.extraOption.len > 0:
        optY += 5
        let ei = sim.conflictState.sceneState.choice.options.len
        let sel = sim.conflictState.sceneState.choice.selected == ei
        let cur = sim.conflictState.sceneState.choice.cursor == ei
        let prefix = if sel: "> " elif cur: "* " else: "  "
        sprite(4, optY, prefix & sim.conflictState.sceneState.choice.extraOption,
          "option" & $(ei+1) & ":" & sim.conflictState.sceneState.choice.extraOption)
      sprite(0, 0, "", "cursor:" & $sim.conflictState.sceneState.choice.cursor &
        "\nselected:" & $sim.conflictState.sceneState.choice.selected)
    elif sim.conflictState.step == ConflictOutcome:
      sprite(4, 4, "Chapter " & $sim.chapter, meta, grey)
      sprite(4, 20, sim.conflictState.outcome, "outcome:" & sim.conflictState.outcome)
    elif sim.conflictState.step == ConflictResolution:
      sprite(4, 4, "Chapter " & $sim.chapter, meta, grey)
      sprite(4, 20, sim.conflictState.resolution, "resolution:" & sim.conflictState.resolution)
    else:
      let title = if sim.conflict.title.len > 0: sim.conflict.title
                  else: "Chapter " & $sim.chapter
      sprite(4, 4, title, meta, grey)
      if sim.conflict.description.len > 0:
        sprite(4, 20, sim.conflict.description, "text:" & sim.conflict.description)

  of PhaseEnd:
    sprite(4, 4, "End", meta, grey)
  of PhasePower:
    sprite(4, 4, "Power", meta, grey)

proc buildRewardPacket(sim: SimServer): string =
  for player in sim.players:
    result.add("individuality " & player.name & " " & $player.individuality & "\n")
    result.add("cooperativity " & player.name & " " & $player.cooperativity & "\n")
    result.add("exploitativity " & player.name & " " & $player.exploitativity & "\n")
    result.add("vicariousness " & player.name & " " & $player.vicariousness & "\n")

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
  loadPalette(dataDir / "pallete.png")
  loadFont()

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

proc isClientRoute(route: string): bool =
  case route
  of PlayerClientRoute, PlayerClientHtmlRoute, CoworldPlayerClientRoute,
      GlobalClientRoute, GlobalClientHtmlRoute, CoworldGlobalClientRoute,
      SnappyClientRoute, SnappyClientPath, CoworldSnappyClientRoute:
    true
  else:
    false

proc serveClientFile(request: Request, route: string): bool =
  if request.httpMethod != "GET":
    return false
  if not isClientRoute(route):
    return false
  let filePath = clientStaticPath(route, GlobalClientRoute)
  if filePath.len == 0:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(route, GlobalClientRoute)
  headers["Cache-Control"] = "no-cache"
  if not fileExists(filePath):
    request.respond(404, headers, "Not found: " & route)
    return true
  try:
    request.respond(200, headers, readFile(filePath))
  except IOError as e:
    request.respond(500, headers, "Error: " & e.msg)
  true

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET" and
      request.headers["Sec-WebSocket-Key"].len > 0:
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerViewers[websocket] = SpriteViewerState()
        appState.playerNames[websocket] = request.playerIdentity()
        appState.playerIndices[websocket] = 0x7fffffff
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
  elif request.path == SpritePlayerWebSocketPath and request.httpMethod == "GET" and
      request.headers["Sec-WebSocket-Key"].len > 0:
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerViewers[websocket] = SpriteViewerState()
        appState.playerNames[websocket] = request.playerIdentity()
        appState.playerIndices[websocket] = 0x7fffffff
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
  elif request.path == "/global" and request.httpMethod == "GET" and
      request.headers["Sec-WebSocket-Key"].len > 0:
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = SpriteViewerState()
  elif request.path == "/reward" and request.httpMethod == "GET" and
      request.headers["Sec-WebSocket-Key"].len > 0:
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.rewardViewers[websocket] = true
  elif request.path == HealthzPath and request.httpMethod in ["GET", "HEAD"]:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "healthy")
  elif request.serveClientFile(request.path):
    discard
  elif request.path == "/" and request.httpMethod == "GET":
    discard request.serveClientFile(GlobalClientRoute)
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
    discard
  of MessageEvent:
    if message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if isSpritePlayerInput(message.data):
            let mask = spritePlayerInputMask(message.data)
            if mask != 0:
              echo "  input: mask=", mask, " from=", websocket in appState.playerIndices
            appState.inputMasks[websocket] = mask
          elif isInputPacket(message.data):
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
  echo "  Player: http://", host, ":", port, GlobalClientRoute

  var
    sim = initSim(seed, players)
    lastTick = getMonoTime()

  for i in 0 ..< bots:
    let botName = "Bot" & $(i + 1)
    discard sim.addPlayer(botName, PlayerBot)

  while true:
    var
      inputs: seq[InputState]
      rewardViewers: seq[WebSocket] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
          appState.globalViewers.del(websocket)
          appState.rewardViewers.del(websocket)
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

        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)

    sim.step(inputs)

    let sprites = sim.buildTextSprites()
    {.gcsafe.}:
      withLock appState.lock:
        for ws in appState.playerViewers.keys:
          var state = appState.playerViewers[ws]
          let packet = buildSpritePacket(sprites, state)
          appState.playerViewers[ws] = state
          if packet.len > 0:
            try:
              ws.send(blobFromBytes(packet), BinaryMessage)
            except:
              appState.closedSockets.add(ws)
        for ws in appState.globalViewers.keys:
          var state = appState.globalViewers[ws]
          let packet = buildSpritePacket(sprites, state)
          appState.globalViewers[ws] = state
          if packet.len > 0:
            try:
              ws.send(blobFromBytes(packet), BinaryMessage)
            except:
              appState.closedSockets.add(ws)

    if rewardViewers.len > 0:
      let rewardPacket = sim.buildRewardPacket()
      for viewer in rewardViewers:
        try:
          viewer.send(rewardPacket, TextMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              appState.rewardViewers.del(viewer)

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

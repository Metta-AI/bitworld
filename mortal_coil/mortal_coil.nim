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
  FactReadTicks = 24 * 3
  FactAcceptTicks = 24 * 1
  CharWidth = 6
  CharHeight = 6
  TextMargin = 4

  PresetFacts = [
    "fire heals the undead",
    "silver burns shapeshifters",
    "ghosts fear running water",
    "moonlight reveals hidden doors",
    "blood opens sealed gates",
    "iron blocks teleportation",
    "shadows carry whispers",
    "mirrors trap spirits",
    "salt wards off demons",
    "bells silence magic",
    "gold attracts dragons",
    "bone dust fuels curses",
    "starlight mends wounds",
    "thunder wakes the dead",
    "amber preserves memories",
    "frost shatters illusions",
    "vines obey the fey",
    "ash blinds seers",
    "coral amplifies song",
    "obsidian cuts fate",
  ]

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

  ChatEntry = object
    name: string
    colorIndex: uint8
    text: string

  Vote = enum
    VotePending
    VotePass
    VoteVeto

  FactStep = enum
    FactReading
    FactSelected
    FactVoting
    FactVoteResult
    FactShowChat

  FactChoice = object
    options: array[3, string]
    selected: int
    step: FactStep
    votes: seq[Vote]
    voteTimers: seq[int]
    voteResultTimer: int

  SimServer = object
    players: seq[Player]
    phase: GamePhase
    tick: int
    lobbyCountdown: int
    currentTurn: int
    chatLog: seq[ChatEntry]
    factChoice: FactChoice
    factTimer: int
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

proc randomFactChoice(sim: var SimServer): FactChoice =
  var indices: seq[int] = @[]
  for i in 0 ..< PresetFacts.len:
    indices.add(i)
  sim.rng.shuffle(indices)
  result.options[0] = PresetFacts[indices[0]]
  result.options[1] = PresetFacts[indices[1]]
  result.options[2] = PresetFacts[indices[2]]
  result.selected = -1
  result.step = FactReading

proc startFactTurn(sim: var SimServer) =
  sim.factChoice = sim.randomFactChoice()
  sim.factTimer = FactReadTicks

proc fillRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  for py in y ..< y + h:
    for px in x ..< x + w:
      fb.putPixel(px, py, color)

proc renderLobby(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let title = "mortal coil"
  sim.fb.blitText(sim.letterSprites, title, 20, 10)

  let countText = $sim.players.len & " of " & $MinPlayers
  sim.fb.blitText(sim.letterSprites, sim.digitSprites, countText, 34, 30)

  for i, player in sim.players:
    let y = 44 + i * 8
    sim.fb.fillRect(10, y, 4, 4, uint8(player.colorIndex))
    let displayName = if player.name.len > 16: player.name[0..15] else: player.name
    sim.fb.blitText(sim.letterSprites, displayName, 18, y)

  if sim.players.len >= MinPlayers and sim.lobbyCountdown > 0:
    let seconds = (sim.lobbyCountdown + 23) div 24
    let startText = "start in " & $seconds
    sim.fb.blitText(sim.letterSprites, sim.digitSprites, startText, 28, 118)

proc charsFromX(x: int): int =
  (ScreenWidth - x) div CharWidth

proc blitTextWrapped(sim: var SimServer, text: string, x, y: int, lineHeight: int): int =
  let maxChars = charsFromX(x)
  var row = 0
  var pos = 0
  while pos < text.len:
    let remaining = text.len - pos
    let lineLen = min(remaining, maxChars)
    let line = text[pos ..< pos + lineLen]
    sim.fb.blitText(sim.letterSprites, line, x, y + row * lineHeight)
    pos += lineLen
    inc row
    if y + row * lineHeight + CharHeight > ScreenHeight:
      break
  row

proc blitTextWrappedTinted(sim: var SimServer, text: string, x, y: int, lineHeight: int, tint: uint8): int =
  let maxChars = charsFromX(x)
  var row = 0
  var pos = 0
  while pos < text.len:
    let remaining = text.len - pos
    let lineLen = min(remaining, maxChars)
    let line = text[pos ..< pos + lineLen]
    sim.fb.blitTextTinted(sim.letterSprites, line, x, y + row * lineHeight, tint)
    pos += lineLen
    inc row
    if y + row * lineHeight + CharHeight > ScreenHeight:
      break
  row

proc renderVotePanel(sim: var SimServer) =
  let voterCount = sim.players.len - 1
  if voterCount <= 0:
    return
  let boxW = ScreenWidth - TextMargin * 2
  let boxH = 16
  let totalH = voterCount * (boxH + 2)
  var voteY = ScreenHeight - totalH
  for i in 0 ..< sim.players.len:
    if i == sim.currentTurn:
      continue
    if voteY + boxH > ScreenHeight:
      break
    let color = uint8(sim.players[i].colorIndex)
    sim.fb.fillRect(TextMargin, voteY, boxW, 1, color)
    sim.fb.fillRect(TextMargin, voteY + boxH - 1, boxW, 1, color)
    sim.fb.fillRect(TextMargin, voteY, 1, boxH, color)
    sim.fb.fillRect(TextMargin + boxW - 1, voteY, 1, boxH, color)
    case sim.factChoice.votes[i]
    of VotePending:
      let passX = TextMargin + (boxW - 4 * CharWidth) div 2
      sim.fb.blitText(sim.letterSprites, "pass", passX, voteY + 2)
      let vetoX = TextMargin + (boxW - 4 * CharWidth) div 2
      sim.fb.blitText(sim.letterSprites, "veto", vetoX, voteY + 9)
    of VotePass:
      let passX = TextMargin + (boxW - 4 * CharWidth) div 2
      sim.fb.blitTextTinted(sim.letterSprites, "pass", passX, voteY + 5, color)
    of VoteVeto:
      let vetoX = TextMargin + (boxW - 4 * CharWidth) div 2
      sim.fb.blitTextTinted(sim.letterSprites, "veto", vetoX, voteY + 5, color)
    voteY += boxH + 2

proc renderFactChoices(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let player = sim.players[sim.currentTurn]
  let header = player.name & " proposes"
  discard sim.blitTextWrappedTinted(header, TextMargin, 4, 8, uint8(player.colorIndex))
  let color = uint8(player.colorIndex)
  let textX = TextMargin + 8

  var y = 20
  for i in 0 ..< 3:
    let selected = sim.factChoice.step >= FactSelected and sim.factChoice.selected == i
    if selected:
      sim.fb.fillRect(TextMargin, y, 6, 6, color)
    else:
      sim.fb.fillRect(TextMargin + 1, y + 1, 4, 4, color)
    let lines = sim.blitTextWrapped(sim.factChoice.options[i], textX, y, 8)
    y += lines * 8 + 2

  let selectedSkip = sim.factChoice.step >= FactSelected and sim.factChoice.selected >= 3
  if y + CharHeight <= ScreenHeight:
    if selectedSkip:
      sim.fb.fillRect(TextMargin, y, 6, 6, color)
    else:
      sim.fb.fillRect(TextMargin + 1, y + 1, 4, 4, color)
    sim.fb.blitText(sim.letterSprites, "skip", textX, y)

  if sim.factChoice.step in {FactVoting, FactVoteResult}:
    sim.renderVotePanel()

proc renderFactChat(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  sim.fb.blitText(sim.letterSprites, "facts", TextMargin, 4)

  var y = 14
  let maxEntries = (ScreenHeight - y) div 8
  let startIdx = max(0, sim.chatLog.len - maxEntries)
  for i in startIdx ..< sim.chatLog.len:
    if y + CharHeight > ScreenHeight:
      break
    let entry = sim.chatLog[i]
    let maxNameChars = min(entry.name.len, charsFromX(TextMargin) - 1)
    let displayName = entry.name[0 ..< maxNameChars]
    sim.fb.blitTextTinted(sim.letterSprites, displayName, TextMargin, y, entry.colorIndex)
    let textX = TextMargin + (maxNameChars + 1) * CharWidth
    let maxTextChars = charsFromX(textX)
    if maxTextChars > 0 and entry.text.len > 0:
      let firstLine = if entry.text.len > maxTextChars: entry.text[0 ..< maxTextChars] else: entry.text
      sim.fb.blitText(sim.letterSprites, firstLine, textX, y)
      y += 8
      var pos = maxTextChars
      let wrapChars = charsFromX(TextMargin)
      while pos < entry.text.len:
        if y + CharHeight > ScreenHeight:
          break
        let lineLen = min(entry.text.len - pos, wrapChars)
        let line = entry.text[pos ..< pos + lineLen]
        sim.fb.blitText(sim.letterSprites, line, TextMargin, y)
        pos += lineLen
        y += 8
    else:
      y += 8

proc renderFact(sim: var SimServer) =
  case sim.factChoice.step
  of FactReading, FactSelected, FactVoting, FactVoteResult:
    sim.renderFactChoices()
  of FactShowChat:
    sim.renderFactChat()

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
  of PhaseFact:
    sim.renderFact()
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
          sim.phase = PhaseFact
          sim.currentTurn = 0
          sim.chatLog = @[]
          sim.startFactTurn()
    else:
      sim.lobbyCountdown = 0
  of PhaseFact:
    if sim.players.len == 0:
      sim.phase = PhaseSetup
      return
    dec sim.factTimer
    if sim.factChoice.step == FactVoting:
      var allVoted = true
      for i in 0 ..< sim.factChoice.votes.len:
        if sim.factChoice.votes[i] == VotePending:
          dec sim.factChoice.voteTimers[i]
          if sim.factChoice.voteTimers[i] <= 0:
            if sim.rng.rand(3) <= 1:
              sim.factChoice.votes[i] = VotePass
            else:
              sim.factChoice.votes[i] = VoteVeto
          else:
            allVoted = false
        # already voted
      if allVoted:
        sim.factChoice.step = FactVoteResult
        sim.factChoice.voteResultTimer = FactAcceptTicks
    elif sim.factChoice.step == FactVoteResult:
      dec sim.factChoice.voteResultTimer
      if sim.factChoice.voteResultTimer <= 0:
        var vetoCount = 0
        for v in sim.factChoice.votes:
          if v == VoteVeto:
            inc vetoCount
        let player = sim.players[sim.currentTurn]
        let factText = sim.factChoice.options[sim.factChoice.selected]
        if vetoCount * 2 >= sim.factChoice.votes.len:
          sim.chatLog.add(ChatEntry(
            name: player.name,
            colorIndex: uint8(player.colorIndex),
            text: "vetoed"
          ))
        else:
          sim.chatLog.add(ChatEntry(
            name: player.name,
            colorIndex: uint8(player.colorIndex),
            text: factText
          ))
        sim.factChoice.step = FactShowChat
        sim.factTimer = FactAcceptTicks * 4
    elif sim.factTimer > 0:
      discard
    elif sim.factChoice.step == FactReading:
      let pick = sim.rng.rand(3)
      sim.factChoice.selected = pick
      sim.factChoice.step = FactSelected
      sim.factTimer = FactAcceptTicks
    elif sim.factChoice.step == FactSelected:
      if sim.factChoice.selected >= 0 and sim.factChoice.selected < 3:
        sim.factChoice.step = FactVoting
        sim.factChoice.votes = @[]
        sim.factChoice.voteTimers = @[]
        for i in 0 ..< sim.players.len:
          if i == sim.currentTurn:
            sim.factChoice.votes.add(VotePass)
            sim.factChoice.voteTimers.add(0)
          else:
            sim.factChoice.votes.add(VotePending)
            sim.factChoice.voteTimers.add(24 * (sim.rng.rand(3) + 1))
      else:
        let player = sim.players[sim.currentTurn]
        sim.chatLog.add(ChatEntry(
          name: player.name,
          colorIndex: uint8(player.colorIndex),
          text: "skip"
        ))
        sim.factChoice.step = FactShowChat
        sim.factTimer = FactAcceptTicks * 4
    elif sim.factChoice.step == FactShowChat:
      sim.currentTurn += 1
      if sim.currentTurn >= sim.players.len:
        sim.phase = PhaseSetup
        return
      sim.startFactTurn()
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

proc serveStaticClientHtml(request: Request): bool =
  ## Serves one static client asset. Page routes (/client/*.html) are not
  ## served here: each page lives at its websocket URL (/player, /global),
  ## which dual-serves HTML on a plain GET and upgrades on a
  ## Sec-WebSocket-Key request. Page and websocket share a URL so reverse-
  ## proxy prefix routing works without page-side awareness.
  let path = request.path
  if path == PlayerClientRoute or path == GlobalClientRoute or
      path == AdminClientRoute or path == RewardClientRoute:
    return false
  request.serveClientHtml(path)

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

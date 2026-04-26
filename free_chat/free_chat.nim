import
  std/[json, locks, monotimes, os, parseopt, strutils, tables, times],
  mummy, pixie,
  ../client/aseprite,
  server
import protocol except TileSize

const
  FancyTileSize = 12
  WorldWidthTiles = 20
  WorldHeightTiles = 20
  WorldWidthPixels = WorldWidthTiles * FancyTileSize
  WorldHeightPixels = WorldHeightTiles * FancyTileSize
  MotionScale = 256
  Accel = 136
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeed = 1280
  StopThreshold = 20
  MinPlayerSpawnSpacing = 24
  TargetFps = 24
  WebSocketPath = "/player"
  FloorBackdropColor = 3'u8
  BubbleFillColor = 1'u8
  BubbleBorderColor = 14'u8
  MessageCharsPerLine = 16
  MessageLineCount = 3
  MessageMaxChars = MessageCharsPerLine * MessageLineCount
  AsciiGlyphW = 7
  AsciiGlyphH = 9

type
  RunConfig = object
    address: string
    port: int
    seed: int

  SheetSpriteKind = enum
    SheetFloor
    SheetCounter
    SheetDirtyReturn
    SheetCleanRack
    SheetWashStation

  PropKind = enum
    PropNone
    PropWall
    PropBench
    PropSignLeft
    PropSignRight
    PropFountain

  Player = object
    name: string
    x: int
    y: int
    sprite: Sprite
    facing: Facing
    velX: int
    velY: int
    carryX: int
    carryY: int
    message: string
    publishedCount: int

  PlayerInput = object
    upHeld: bool
    downHeld: bool
    leftHeld: bool
    rightHeld: bool
    upPressed: bool
    downPressed: bool
    leftPressed: bool
    rightPressed: bool
    bPressed: bool
    attackPressed: bool
    selectPressed: bool

  SimServer = object
    players: seq[Player]
    blockedTiles: seq[bool]
    props: seq[PropKind]
    sheetSprites: array[SheetSpriteKind, Sprite]
    playerSprites: seq[Sprite]
    asciiSprites: seq[Sprite]
    fb: Framebuffer

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    chatMessages: Table[WebSocket, string]
    closedSockets: seq[WebSocket]
    rewardViewers: Table[WebSocket, bool]
    resetRequested: bool

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

proc tileIndex(tx, ty: int): int =
  ty * WorldWidthTiles + tx

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "client" / "data"

proc palettePath(): string =
  clientDataDir() / "pallete.png"

proc sheetPath(): string =
  repoDir() / "free_chat" / "data" / "spritesheet.png"

proc asciiPath(): string =
  repoDir() / "free_chat" / "data" / "ascii.aseprite"

proc inTileBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc worldClampPixel(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc distanceSquared(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc fillRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  if w <= 0 or h <= 0:
    return
  for py in y ..< y + h:
    for px in x ..< x + w:
      fb.putPixel(px, py, color)

proc strokeRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  if w <= 0 or h <= 0:
    return
  for px in x ..< x + w:
    fb.putPixel(px, y, color)
    fb.putPixel(px, y + h - 1, color)
  for py in y ..< y + h:
    fb.putPixel(x, py, color)
    fb.putPixel(x + w - 1, py, color)

proc lineCountForText(text: string): int =
  max(1, (text.len + MessageCharsPerLine - 1) div MessageCharsPerLine)

proc sliceMessageLine(text: string, lineIndex: int): string =
  let startIndex = lineIndex * MessageCharsPerLine
  if startIndex >= text.len:
    return ""
  let endIndex = min(text.len, startIndex + MessageCharsPerLine)
  text[startIndex ..< endIndex]

proc asciiIndex(ch: char): int =
  ord(ch) - ord(' ')

proc loadAsciiSprites(path: string): seq[Sprite] =
  if not fileExists(path):
    raise newException(IOError, "Missing ASCII sprite sheet: " & path)
  let
    image = readAsepriteImage(path)
    rowStride = 9
    cols = image.width div AsciiGlyphW
    rows = image.height div rowStride
    background = nearestPaletteIndex(image[0, 0])
  result = @[]
  for row in 0 ..< rows:
    for col in 0 ..< cols:
      var sprite = Sprite(width: AsciiGlyphW, height: AsciiGlyphH)
      sprite.pixels = newSeq[uint8](AsciiGlyphW * AsciiGlyphH)
      let
        baseX = col * AsciiGlyphW
        baseY = row * rowStride
      for y in 0 ..< AsciiGlyphH:
        for x in 0 ..< AsciiGlyphW:
          let colorIndex = nearestPaletteIndex(image[baseX + x, baseY + y])
          sprite.pixels[sprite.spriteIndex(x, y)] =
            if colorIndex == background:
              TransparentColorIndex
            else:
              colorIndex
      result.add(sprite)

proc blitAsciiText(
  fb: var Framebuffer,
  asciiSprites: seq[Sprite],
  text: string,
  screenX, screenY: int
) =
  var offsetX = 0
  for ch in text:
    let idx = asciiIndex(ch)
    if idx >= 0 and idx < asciiSprites.len:
      fb.blitSprite(asciiSprites[idx], screenX + offsetX, screenY, 0, 0)
    offsetX += AsciiGlyphW

proc sheetCellSprite(sheet: Image, cellX, cellY: int): Sprite =
  spriteFromImage(
    sheet.subImage(cellX * FancyTileSize, cellY * FancyTileSize, FancyTileSize, FancyTileSize)
  )

proc defaultPlayerSprite(sim: SimServer): Sprite =
  sim.playerSprites[0]

proc playerSprite(sim: SimServer, playerIndex: int): Sprite =
  sim.playerSprites[playerIndex mod sim.playerSprites.len]

proc propSprite(sim: SimServer, prop: PropKind): Sprite =
  case prop
  of PropNone, PropWall, PropBench:
    sim.sheetSprites[SheetCounter]
  of PropSignLeft:
    sim.sheetSprites[SheetDirtyReturn]
  of PropSignRight:
    sim.sheetSprites[SheetCleanRack]
  of PropFountain:
    sim.sheetSprites[SheetWashStation]

proc addProp(sim: var SimServer, kind: PropKind, tx, ty: int, blocked = true) =
  if not inTileBounds(tx, ty):
    return
  sim.props[tileIndex(tx, ty)] = kind
  sim.blockedTiles[tileIndex(tx, ty)] = blocked

proc initPlaza(sim: var SimServer) =
  for tx in 0 ..< WorldWidthTiles:
    sim.addProp(PropWall, tx, 0)
    sim.addProp(PropWall, tx, WorldHeightTiles - 1)

  for ty in 1 ..< WorldHeightTiles - 1:
    sim.addProp(PropWall, 0, ty)
    sim.addProp(PropWall, WorldWidthTiles - 1, ty)

  for tx in 4 .. 6:
    sim.addProp(PropBench, tx, 5)
    sim.addProp(PropBench, tx, 14)
  for tx in 13 .. 15:
    sim.addProp(PropBench, tx, 5)
    sim.addProp(PropBench, tx, 14)

  sim.addProp(PropSignLeft, 3, 3)
  sim.addProp(PropSignRight, 16, 3)

  for ty in 8 .. 11:
    sim.addProp(PropFountain, 9, ty)
    sim.addProp(PropFountain, 10, ty)

proc canOccupy(sim: SimServer, x, y, width, height: int): bool =
  if x < 0 or y < 0 or x + width > WorldWidthPixels or y + height > WorldHeightPixels:
    return false

  let
    startTx = x div FancyTileSize
    startTy = y div FancyTileSize
    endTx = (x + width - 1) div FancyTileSize
    endTy = (y + height - 1) div FancyTileSize

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.blockedTiles[tileIndex(tx, ty)]:
        return false
  true

proc findPlayerSpawn(sim: SimServer): tuple[x, y: int] =
  let
    centerTx = WorldWidthTiles div 2
    centerTy = WorldHeightTiles - 4
    minSpacingSq = MinPlayerSpawnSpacing * MinPlayerSpawnSpacing
    playerSprite = sim.defaultPlayerSprite()

  for radius in 0 .. 7:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          tx = centerTx + dx
          ty = centerTy + dy
        if not inTileBounds(tx, ty):
          continue
        let
          px = tx * FancyTileSize
          py = ty * FancyTileSize
        if not sim.canOccupy(px, py, playerSprite.width, playerSprite.height):
          continue
        var tooClose = false
        for player in sim.players:
          if distanceSquared(px, py, player.x, player.y) < minSpacingSq:
            tooClose = true
            break
        if not tooClose:
          return (px, py)

  (centerTx * FancyTileSize, centerTy * FancyTileSize)

proc addPlayer(sim: var SimServer, name: string): int =
  let
    spawn = sim.findPlayerSpawn()
    playerSprite = sim.playerSprite(sim.players.len)
  sim.players.add Player(
    name: name,
    x: spawn.x,
    y: spawn.y,
    sprite: playerSprite,
    facing: FaceDown
  )
  sim.players.high

proc initSimServer(seed: int): SimServer =
  discard seed
  let sheetImage = readImage(sheetPath())
  result.fb = initFramebuffer()
  result.blockedTiles = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  result.props = newSeq[PropKind](WorldWidthTiles * WorldHeightTiles)
  loadPalette(palettePath())
  result.sheetSprites[SheetFloor] = sheetImage.sheetCellSprite(0, 0)
  result.sheetSprites[SheetCounter] = sheetImage.sheetCellSprite(2, 0)
  result.sheetSprites[SheetDirtyReturn] = sheetImage.sheetCellSprite(3, 0)
  result.sheetSprites[SheetCleanRack] = sheetImage.sheetCellSprite(4, 0)
  result.sheetSprites[SheetWashStation] = sheetImage.sheetCellSprite(5, 0)
  result.playerSprites = @[
    sheetImage.sheetCellSprite(0, 1),
    sheetImage.sheetCellSprite(1, 1),
    sheetImage.sheetCellSprite(2, 1),
    sheetImage.sheetCellSprite(3, 1)
  ]
  result.asciiSprites = loadAsciiSprites(asciiPath())
  result.initPlaza()

proc applyMomentumAxis(
  sim: SimServer,
  player: var Player,
  carry: var int,
  velocity: int,
  horizontal: bool
) =
  carry += velocity
  while abs(carry) >= MotionScale:
    let step = (if carry < 0: -1 else: 1)
    if horizontal:
      if sim.canOccupy(player.x + step, player.y, player.sprite.width, player.sprite.height):
        player.x += step
        carry -= step * MotionScale
      else:
        carry = 0
        break
    else:
      if sim.canOccupy(player.x, player.y + step, player.sprite.width, player.sprite.height):
        player.y += step
        carry -= step * MotionScale
      else:
        carry = 0
        break

proc applyMovementInput(sim: var SimServer, playerIndex: int, input: PlayerInput) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  var inputX = 0
  var inputY = 0
  if input.leftHeld:
    dec inputX
  if input.rightHeld:
    inc inputX
  if input.upHeld:
    dec inputY
  if input.downHeld:
    inc inputY

  if inputX != 0:
    sim.players[playerIndex].velX =
      clamp(sim.players[playerIndex].velX + inputX * Accel, -MaxSpeed, MaxSpeed)
  else:
    sim.players[playerIndex].velX =
      (sim.players[playerIndex].velX * FrictionNum) div FrictionDen
    if abs(sim.players[playerIndex].velX) < StopThreshold:
      sim.players[playerIndex].velX = 0

  if inputY != 0:
    sim.players[playerIndex].velY =
      clamp(sim.players[playerIndex].velY + inputY * Accel, -MaxSpeed, MaxSpeed)
  else:
    sim.players[playerIndex].velY =
      (sim.players[playerIndex].velY * FrictionNum) div FrictionDen
    if abs(sim.players[playerIndex].velY) < StopThreshold:
      sim.players[playerIndex].velY = 0

  if inputX < 0:
    sim.players[playerIndex].facing = FaceLeft
  elif inputX > 0:
    sim.players[playerIndex].facing = FaceRight
  elif inputY < 0:
    sim.players[playerIndex].facing = FaceUp
  elif inputY > 0:
    sim.players[playerIndex].facing = FaceDown

  sim.applyMomentumAxis(
    sim.players[playerIndex],
    sim.players[playerIndex].carryX,
    sim.players[playerIndex].velX,
    true
  )
  sim.applyMomentumAxis(
    sim.players[playerIndex],
    sim.players[playerIndex].carryY,
    sim.players[playerIndex].velY,
    false
  )

proc drawMessageBubble(
  sim: var SimServer,
  text: string,
  worldX, worldY, cameraX, cameraY: int
) =
  if text.len == 0:
    return

  let
    lineCount = text.lineCountForText()
    longestLineLen =
      block:
        var width = 0
        for lineIndex in 0 ..< lineCount:
          width = max(width, text.sliceMessageLine(lineIndex).len)
        width
    bubbleWidth = min(ScreenWidth - 2, longestLineLen * AsciiGlyphW + 4)
    bubbleHeight = lineCount * AsciiGlyphH + 4
    anchorX = worldX - cameraX
    anchorY = worldY - cameraY
    bubbleX = clamp(anchorX - bubbleWidth div 2, 1, ScreenWidth - bubbleWidth - 1)
    bubbleY = max(1, anchorY - bubbleHeight - 5)
    pointerX = clamp(anchorX, bubbleX + 2, bubbleX + bubbleWidth - 3)

  sim.fb.fillRect(bubbleX, bubbleY, bubbleWidth, bubbleHeight, BubbleFillColor)
  sim.fb.strokeRect(bubbleX, bubbleY, bubbleWidth, bubbleHeight, BubbleBorderColor)
  sim.fb.putPixel(pointerX, bubbleY + bubbleHeight, BubbleBorderColor)
  sim.fb.putPixel(pointerX - 1, bubbleY + bubbleHeight - 1, BubbleBorderColor)
  sim.fb.putPixel(pointerX + 1, bubbleY + bubbleHeight - 1, BubbleBorderColor)
  for lineIndex in 0 ..< lineCount:
    sim.fb.blitAsciiText(
      sim.asciiSprites,
      text.sliceMessageLine(lineIndex),
      bubbleX + 2,
      bubbleY + 2 + lineIndex * AsciiGlyphH
    )

proc renderWorld(sim: var SimServer, cameraX, cameraY: int) =
  let
    startTx = max(0, cameraX div FancyTileSize)
    startTy = max(0, cameraY div FancyTileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + ScreenWidth - 1) div FancyTileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + ScreenHeight - 1) div FancyTileSize)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        worldX = tx * FancyTileSize
        worldY = ty * FancyTileSize
        floorSprite = sim.sheetSprites[SheetFloor]
      sim.fb.blitSprite(floorSprite, worldX, worldY, cameraX, cameraY)

      let prop = sim.props[tileIndex(tx, ty)]
      if prop != PropNone:
        sim.fb.blitSprite(sim.propSprite(prop), worldX, worldY, cameraX, cameraY)

proc renderPlayers(sim: var SimServer, cameraX, cameraY: int) =
  for player in sim.players:
    sim.fb.blitSprite(player.sprite, player.x, player.y, cameraX, cameraY)

  for player in sim.players:
    if player.message.len > 0:
      sim.drawMessageBubble(
        player.message,
        player.x + player.sprite.width div 2,
        player.y - 2,
        cameraX,
        cameraY
      )

proc render(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(FloorBackdropColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let player = sim.players[playerIndex]
  let
    cameraX = worldClampPixel(
      player.x + player.sprite.width div 2 - ScreenWidth div 2,
      WorldWidthPixels - ScreenWidth
    )
    cameraY = worldClampPixel(
      player.y + player.sprite.height div 2 - ScreenHeight div 2,
      WorldHeightPixels - ScreenHeight
    )

  sim.renderWorld(cameraX, cameraY)
  sim.renderPlayers(cameraX, cameraY)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildRewardPacket(sim: SimServer): string =
  for player in sim.players:
    result.add("reward ")
    result.add(player.name)
    result.add(" ")
    result.add($player.publishedCount)
    result.add("\n")

proc step(sim: var SimServer, inputs: openArray[PlayerInput]) =
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: PlayerInput()
    sim.applyMovementInput(playerIndex, input)

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerNames = initTable[WebSocket, string]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.closedSockets = @[]
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.resetRequested = false

proc playerInputFromMasks(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.upHeld = decoded.up
  result.downHeld = decoded.down
  result.leftHeld = decoded.left
  result.rightHeld = decoded.right
  result.upPressed = (currentMask and ButtonUp) != 0 and (previousMask and ButtonUp) == 0
  result.downPressed = (currentMask and ButtonDown) != 0 and (previousMask and ButtonDown) == 0
  result.leftPressed = (currentMask and ButtonLeft) != 0 and (previousMask and ButtonLeft) == 0
  result.rightPressed = (currentMask and ButtonRight) != 0 and (previousMask and ButtonRight) == 0
  result.bPressed = (currentMask and ButtonB) != 0 and (previousMask and ButtonB) == 0
  result.attackPressed = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
  result.selectPressed = (currentMask and ButtonSelect) != 0 and (previousMask and ButtonSelect) == 0

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.playerNames.del(websocket)
  appState.chatMessages.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc cleanChatMessage(message: string): string =
  let trimmed = message.strip()
  for ch in trimmed:
    if result.len >= MessageMaxChars:
      return
    if ch >= ' ' and ch <= '~':
      result.add(ch)

proc playerIdentity(request: Request): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  let parts = request.remoteAddress.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  request.remoteAddress

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerNames[websocket] = request.playerIdentity()
  elif request.path == "/reward" and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.rewardViewers[websocket] = true
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "BitWorld WebSocket server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.rewardViewers:
          appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if isInputPacket(message.data):
            let mask = blobToMask(message.data)
            if mask == 255'u8:
              appState.resetRequested = true
              appState.inputMasks[websocket] = 0
              appState.lastAppliedMasks[websocket] = 0
            else:
              appState.inputMasks[websocket] = mask
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
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop(
  host = DefaultHost,
  port = DefaultPort,
  seed = 0
) =
  initAppState()

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    tcpNoDelay = true
  )

  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc, ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    currentSeed = seed
    sim = initSimServer(currentSeed)
    lastTick = getMonoTime()

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[PlayerInput]
      shouldReset = false
      rewardViewers: seq[WebSocket] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        if appState.resetRequested:
          shouldReset = true
          appState.resetRequested = false
          for _, value in appState.playerIndices.mpairs:
            value = 0x7fffffff
          for _, value in appState.inputMasks.mpairs:
            value = 0
          for _, value in appState.lastAppliedMasks.mpairs:
            value = 0
          appState.chatMessages.clear()
        else:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              let name = appState.playerNames.getOrDefault(websocket, "unknown")
              appState.playerIndices[websocket] = sim.addPlayer(name)

          for websocket, message in appState.chatMessages.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(websocket, -1)
            if playerIndex >= 0 and playerIndex < sim.players.len:
              sim.players[playerIndex].message = cleanChatMessage(message)
              if sim.players[playerIndex].message.len > 0:
                inc sim.players[playerIndex].publishedCount
          appState.chatMessages.clear()

          inputs = newSeq[PlayerInput](sim.players.len)
          for websocket, playerIndex in appState.playerIndices.pairs:
            if playerIndex < 0 or playerIndex >= inputs.len:
              continue
            let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
            inputs[playerIndex] = playerInputFromMasks(currentMask, previousMask)
            appState.lastAppliedMasks[websocket] = currentMask
            sockets.add(websocket)
            playerIndices.add(playerIndex)

        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)

    if shouldReset:
      inc currentSeed
      sim = initSimServer(currentSeed)
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              let name = appState.playerNames.getOrDefault(websocket, "unknown")
              appState.playerIndices[websocket] = sim.addPlayer(name)
            sockets.add(websocket)
            playerIndices.add(appState.playerIndices[websocket])
      for i in 0 ..< sockets.len:
        let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
        sockets[i].send(frameBlob, BinaryMessage)
      let rewardPacket = sim.buildRewardPacket()
      for websocket in rewardViewers:
        websocket.send(rewardPacket, TextMessage)
      runFrameLimiter(lastTick)
      continue

    sim.step(inputs)

    for i in 0 ..< sockets.len:
      let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    let rewardPacket = sim.buildRewardPacket()
    for websocket in rewardViewers:
      websocket.send(rewardPacket, TextMessage)

    runFrameLimiter(lastTick)

proc readConfigString(node: JsonNode, name: string, value: var string) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(ValueError, "Config field " & name & " must be a string.")
  value = item.getStr()

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(ValueError, "Config field " & name & " must be an integer.")
  value = item.getInt()

proc update(config: var RunConfig, jsonText: string) =
  if jsonText.len == 0:
    return
  let node = parseJson(jsonText)
  if node.kind != JObject:
    raise newException(ValueError, "Config must be a JSON object.")
  node.readConfigString("address", config.address)
  node.readConfigInt("port", config.port)
  node.readConfigInt("seed", config.seed)

when isMainModule:
  var
    config = RunConfig(address: DefaultHost, port: DefaultPort, seed: 0)
    configJson = ""
    configPath = ""
    pendingOption = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      pendingOption = ""
      case key
      of "address":
        if val.len > 0:
          config.address = val
        else:
          pendingOption = "address"
      of "port":
        if val.len > 0:
          config.port = parseInt(val)
        else:
          pendingOption = "port"
      of "config":
        configJson = val
      of "config-file":
        configPath = val
      else: discard
    of cmdArgument:
      case pendingOption
      of "address":
        config.address = key
      of "port":
        config.port = parseInt(key)
      else: discard
      pendingOption = ""
    else: discard
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  runServerLoop(config.address, config.port, seed = config.seed)

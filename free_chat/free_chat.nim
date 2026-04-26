import mummy, pixie
import protocol except TileSize
import server
import std/[locks, monotimes, os, parseopt, strutils, tables, times]

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
  FpsScale = 1000
  TargetFps = 24 * FpsScale
  WebSocketPath = "/player"
  FloorBackdropColor = 3'u8
  PanelFillColor = 1'u8
  PanelBorderColor = 12'u8
  HighlightFillColor = 10'u8
  HighlightBorderColor = 14'u8
  BubbleFillColor = 1'u8
  BubbleBorderColor = 14'u8
  CaretColor = 14'u8
  MessageCharsPerLine = 8
  MessageLineCount = 2
  MessageMaxChars = MessageCharsPerLine * MessageLineCount
  EditorChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ .?!"
  EditorCols = 6
  EditorRows = EditorChars.len div EditorCols
  DraftBoxX = 4
  DraftBoxY = 2
  DraftBoxW = 56
  DraftBoxH = 16
  GridBoxX = 6
  GridBoxY = 19
  GridBoxW = 52
  GridBoxH = 43
  EditorCellW = 8
  EditorCellH = 8

type
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
    x: int
    y: int
    sprite: Sprite
    facing: Facing
    velX: int
    velY: int
    carryX: int
    carryY: int
    message: string
    draft: string
    editing: bool
    selectedCharIndex: int

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
    letterSprites: seq[Sprite]
    fb: Framebuffer

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    closedSockets: seq[WebSocket]

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

proc lettersPath(): string =
  clientDataDir() / "letters.png"

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

proc panelRect(fb: var Framebuffer, x, y, w, h: int) =
  fb.fillRect(x, y, w, h, PanelFillColor)
  fb.strokeRect(x, y, w, h, PanelBorderColor)

proc lineCountForText(text: string): int =
  max(1, (text.len + MessageCharsPerLine - 1) div MessageCharsPerLine)

proc sliceMessageLine(text: string, lineIndex: int): string =
  let startIndex = lineIndex * MessageCharsPerLine
  if startIndex >= text.len:
    return ""
  let endIndex = min(text.len, startIndex + MessageCharsPerLine)
  text[startIndex ..< endIndex]

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

proc editorIndexForChar(ch: char): int =
  let target =
    if ch >= 'a' and ch <= 'z':
      chr(ord(ch) - ord('a') + ord('A'))
    else:
      ch
  for i in 0 ..< EditorChars.len:
    if EditorChars[i] == target:
      return i
  0

proc addPlayer(sim: var SimServer): int =
  let
    spawn = sim.findPlayerSpawn()
    playerSprite = sim.playerSprite(sim.players.len)
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    sprite: playerSprite,
    facing: FaceDown,
    selectedCharIndex: editorIndexForChar('A')
  )
  sim.players.high

proc initSimServer(): SimServer =
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
  result.letterSprites = loadLetterSprites(lettersPath())
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

proc stopPlayer(player: var Player) =
  player.velX = 0
  player.velY = 0
  player.carryX = 0
  player.carryY = 0

proc applyMovementInput(sim: var SimServer, playerIndex: int, input: PlayerInput) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].editing:
    sim.players[playerIndex].stopPlayer()
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

proc selectedEditorChar(player: Player): char =
  EditorChars[player.selectedCharIndex.clamp(0, EditorChars.high)]

proc openEditor(player: var Player) =
  player.editing = true
  player.draft = ""
  player.selectedCharIndex = editorIndexForChar('A')
  player.stopPlayer()

proc commitEditor(player: var Player) =
  player.message = player.draft.strip(chars = {' '})
  player.editing = false
  player.stopPlayer()

proc moveEditorSelection(player: var Player, dx, dy: int) =
  var
    col = player.selectedCharIndex mod EditorCols
    row = player.selectedCharIndex div EditorCols
  col = clamp(col + dx, 0, EditorCols - 1)
  row = clamp(row + dy, 0, EditorRows - 1)
  player.selectedCharIndex = row * EditorCols + col

proc advanceDraft(player: var Player) =
  if player.draft.len >= MessageMaxChars:
    return
  player.draft.add(player.selectedEditorChar())

proc rewindDraft(player: var Player) =
  if player.draft.len == 0:
    return
  player.draft.setLen(player.draft.len - 1)

proc applyChatInput(sim: var SimServer, playerIndex: int, input: PlayerInput) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  var player = sim.players[playerIndex]
  if not player.editing:
    if input.selectPressed:
      player.openEditor()
  else:
    if input.selectPressed:
      player.commitEditor()

  if player.editing:
    if input.upPressed:
      player.moveEditorSelection(0, -1)
    if input.downPressed:
      player.moveEditorSelection(0, 1)
    if input.leftPressed:
      player.moveEditorSelection(-1, 0)
    if input.rightPressed:
      player.moveEditorSelection(1, 0)
    if input.bPressed:
      player.rewindDraft()
    if input.attackPressed:
      player.advanceDraft()

  sim.players[playerIndex] = player

proc drawEditorGlyph(sim: var SimServer, ch: char, x, y: int) =
  if ch == ' ':
    sim.fb.fillRect(x + 1, y + 4, 4, 1, CaretColor)
  else:
    let idx = letterIndex(ch)
    if idx >= 0 and idx < sim.letterSprites.len:
      sim.fb.blitSprite(sim.letterSprites[idx], x, y, 0, 0)

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
    bubbleWidth = min(ScreenWidth - 2, longestLineLen * 6 + 4)
    bubbleHeight = lineCount * 6 + 4
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
    sim.fb.blitText(
      sim.letterSprites,
      text.sliceMessageLine(lineIndex),
      bubbleX + 2,
      bubbleY + 2 + lineIndex * 6
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

proc renderEditor(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let player = sim.players[playerIndex]
  if not player.editing:
    return

  sim.fb.panelRect(DraftBoxX, DraftBoxY, DraftBoxW, DraftBoxH)
  let draftX = DraftBoxX + 4
  let draftY = DraftBoxY + 3
  let draftLineCount = player.draft.lineCountForText()
  for lineIndex in 0 ..< draftLineCount:
    let lineText = player.draft.sliceMessageLine(lineIndex)
    if lineText.len > 0:
      sim.fb.blitText(sim.letterSprites, lineText, draftX, draftY + lineIndex * 6)

  if player.draft.len < MessageMaxChars:
    let
      caretRow = player.draft.len div MessageCharsPerLine
      caretCol = player.draft.len mod MessageCharsPerLine
      caretX = draftX + caretCol * 6
      caretY = draftY + caretRow * 6 + 5
    sim.fb.fillRect(caretX, caretY, 5, 1, CaretColor)

  sim.fb.panelRect(GridBoxX, GridBoxY, GridBoxW, GridBoxH)
  for index in 0 ..< EditorChars.len:
    let
      col = index mod EditorCols
      row = index div EditorCols
      cellX = GridBoxX + 2 + col * EditorCellW
      cellY = GridBoxY + 2 + row * EditorCellH

    if index == player.selectedCharIndex:
      sim.fb.fillRect(cellX - 1, cellY - 1, 8, 8, HighlightFillColor)
      sim.fb.strokeRect(cellX - 1, cellY - 1, 8, 8, HighlightBorderColor)

    sim.drawEditorGlyph(EditorChars[index], cellX, cellY)

proc buildFramePacket(sim: var SimServer, playerIndex: int): seq[uint8] =
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
  sim.renderEditor(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc step(sim: var SimServer, inputs: openArray[PlayerInput]) =
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: PlayerInput()
    sim.applyChatInput(playerIndex, input)
    sim.applyMovementInput(playerIndex, input)

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]

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
  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc httpHandler(request: Request) =
  if request.uri == WebSocketPath and request.httpMethod == "GET":
    discard request.upgradeToWebSocket()
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Free Chat WebSocket server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerIndices[websocket] = 0x7fffffff
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage and message.data.len == InputPacketBytes:
      {.gcsafe.}:
        withLock appState.lock:
          appState.inputMasks[websocket] = blobToMask(message.data)
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime, targetFps: int) =
  if targetFps <= 0:
    previousTick = getMonoTime()
    return
  let frameDuration = initDuration(microseconds = (1_000_000 * FpsScale) div targetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop(
  host = DefaultHost,
  port = DefaultPort,
  targetFps = TargetFps
) =
  initAppState()

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    wsNoDelay = true
  )

  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc, ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    sim = initSimServer()
    lastTick = getMonoTime()

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[PlayerInput]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == 0x7fffffff:
            appState.playerIndices[websocket] = sim.addPlayer()

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

    sim.step(inputs)

    for i in 0 ..< sockets.len:
      let frameBlob = blobFromBytes(sim.buildFramePacket(playerIndices[i]))
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    runFrameLimiter(lastTick, targetFps)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    targetFps = TargetFps
    pendingOption = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      pendingOption = ""
      case key
      of "address":
        if val.len > 0:
          address = val
        else:
          pendingOption = "address"
      of "port":
        if val.len > 0:
          port = parseInt(val)
        else:
          pendingOption = "port"
      of "fps":
        if val.len > 0:
          targetFps = parseInt(val) * FpsScale
        else:
          pendingOption = "fps"
      else: discard
    of cmdArgument:
      case pendingOption
      of "address":
        address = key
      of "port":
        port = parseInt(key)
      of "fps":
        targetFps = parseInt(key) * FpsScale
      else: discard
      pendingOption = ""
    else: discard
  runServerLoop(address, port, targetFps)

import mummy, pixie
import protocol except TileSize
import server
import sim
import std/[json, locks, monotimes, os, parseopt, strutils, tables, times]

const
  TargetFps = 24
  WebSocketPath = "/player"
  FloorBackdropColor = 3'u8
  ProgressBarWidth = 6

type
  RunConfig = object
    address: string
    port: int
    seed: int

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    closedSockets: seq[WebSocket]
    rewardViewers: Table[WebSocket, bool]
    stateViewers: Table[WebSocket, bool]
    resetRequested: bool

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "clients" / "data"

proc palettePath(): string =
  clientDataDir() / "pallete.png"

proc numbersPath(): string =
  clientDataDir() / "numbers.png"

proc lettersPath(): string =
  clientDataDir() / "letters.png"

proc worldClampPixel(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc makeOutlinedSprite(fill, outline: uint8, size: int): Sprite =
  result.width = size
  result.height = size
  result.pixels = newSeq[uint8](size * size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      if x == 0 or y == 0 or x == size - 1 or y == size - 1:
        result.pixels[y * size + x] = outline
      else:
        result.pixels[y * size + x] = fill

proc objectSprite(kind: WorldObjectKind, depleted: bool, material: ItemKind): Sprite =
  case kind
  of GatherNodeObj:
    if depleted:
      makeOutlinedSprite(5, 1, MbTileSize)
    else:
      case material
      of WoodItem: makeOutlinedSprite(11, 4, MbTileSize)
      of StoneItem: makeOutlinedSprite(6, 5, MbTileSize)
      of HardwoodItem: makeOutlinedSprite(3, 4, MbTileSize)
      of CopperItem: makeOutlinedSprite(9, 5, MbTileSize)
      of IronwoodItem: makeOutlinedSprite(2, 1, MbTileSize)
      of IronItem: makeOutlinedSprite(14, 1, MbTileSize)
      else: makeOutlinedSprite(7, 1, MbTileSize)
  of CraftStationObj:
    makeOutlinedSprite(6, 0, MbTileSize)
  of SellStallObj:
    makeOutlinedSprite(9, 4, MbTileSize)
  of BuyStallObj:
    makeOutlinedSprite(12, 4, MbTileSize)
  of GathererStallObj:
    makeOutlinedSprite(11, 3, MbTileSize)
  of CrafterStallObj:
    makeOutlinedSprite(8, 2, MbTileSize)

proc roleTint(role: Role): uint8 =
  case role
  of NoRole: 6'u8
  of Gatherer: 11'u8
  of Crafter: 12'u8

proc signalColor(icon: int): uint8 =
  case icon
  of 0: 4'u8
  of 1: 6'u8
  of 2: 9'u8
  of 3: 14'u8
  else: 7'u8

proc renderTerrain(sim: var SimServer, cameraX, cameraY: int) =
  let
    startTx = max(0, cameraX div MbTileSize)
    startTy = max(0, cameraY div MbTileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + ScreenWidth - 1) div MbTileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + ScreenHeight - 1) div MbTileSize)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        worldX = tx * MbTileSize
        worldY = ty * MbTileSize
        screenX = worldX - cameraX
        screenY = worldY - cameraY
        tileKind = sim.tileKinds[tileIndex(tx, ty)]
      let color =
        case tileKind
        of GrassTile: 3'u8
        of PathTile: 5'u8
        of WallTile: 1'u8
      for py in 0 ..< MbTileSize:
        for px in 0 ..< MbTileSize:
          sim.fb.putPixel(screenX + px, screenY + py, color)

proc renderObjects(sim: var SimServer, cameraX, cameraY: int) =
  for obj in sim.objects:
    let sprite = objectSprite(obj.kind, obj.depleted, obj.material)
    sim.fb.blitSprite(
      sprite,
      obj.tx * MbTileSize,
      obj.ty * MbTileSize,
      cameraX,
      cameraY
    )

proc renderSelection(sim: var SimServer, playerIndex, cameraX, cameraY: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let target = sim.players[playerIndex].interactionTile()
  if not inTileBounds(target.tx, target.ty):
    return
  let
    worldX = target.tx * MbTileSize
    worldY = target.ty * MbTileSize
    screenX = worldX - cameraX
    screenY = worldY - cameraY
  for px in 0 ..< MbTileSize:
    sim.fb.putPixel(screenX + px, screenY, 10)
    sim.fb.putPixel(screenX + px, screenY + MbTileSize - 1, 10)
  for py in 1 ..< MbTileSize - 1:
    sim.fb.putPixel(screenX, screenY + py, 10)
    sim.fb.putPixel(screenX + MbTileSize - 1, screenY + py, 10)

proc renderPlayers(sim: var SimServer, cameraX, cameraY: int) =
  for player in sim.players:
    let tint = roleTint(player.role)
    sim.fb.blitSpriteTinted(player.sprite, player.x, player.y, cameraX, cameraY, tint)

    if player.signalIcon >= 0:
      let
        iconX = player.x + player.sprite.width div 2 - 1
        iconY = player.y - 4
        color = signalColor(player.signalIcon)
        screenX = iconX - cameraX
        screenY = iconY - cameraY
      for py in 0 ..< 3:
        for px in 0 ..< 3:
          sim.fb.putPixel(screenX + px, screenY + py, color)

proc drawProgressBar(sim: var SimServer, progress, total, screenX, screenY: int) =
  let filledWidth = max(1, min(ProgressBarWidth, (progress * ProgressBarWidth + total - 1) div total))
  for px in 0 ..< ProgressBarWidth:
    sim.fb.putPixel(screenX + px, screenY, 1)
    sim.fb.putPixel(screenX + px, screenY + 1, 1)
  for px in 0 ..< filledWidth:
    sim.fb.putPixel(screenX + px, screenY, 10)
    sim.fb.putPixel(screenX + px, screenY + 1, 14)

proc renderNumber(
  fb: var Framebuffer,
  digitSprites: array[10, Sprite],
  value, screenX, screenY: int
) =
  let text = $max(0, value)
  var x = screenX
  for ch in text:
    let digit = ord(ch) - ord('0')
    fb.blitSprite(digitSprites[digit], x, screenY, 0, 0)
    x += digitSprites[digit].width

proc renderHud(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]

  sim.fb.renderNumber(sim.digitSprites, player.gold, 1, 1)

  if sim.letterSprites.len > 0:
    let roleName = roleShortName(player.role)
    sim.fb.blitText(sim.letterSprites, roleName, ScreenWidth - roleName.len * 6 - 1, 1)

  let invY = 9
  sim.fb.renderNumber(sim.digitSprites, player.inv.wood, 1, invY)
  if sim.letterSprites.len > 0:
    sim.fb.blitText(sim.letterSprites, "W", 1 + 18, invY)
  sim.fb.renderNumber(sim.digitSprites, player.inv.stone, 40, invY)
  if sim.letterSprites.len > 0:
    sim.fb.blitText(sim.letterSprites, "S", 40 + 18, invY)
  let gearCount = player.equippedGearCount()
  if sim.letterSprites.len > 0:
    let gearText = "G" & $gearCount
    sim.fb.blitText(sim.letterSprites, gearText, 70, invY)

  let invY2 = 17
  let t2Wood = player.inv.hardwood
  let t2Ore = player.inv.copper
  if t2Wood > 0 or t2Ore > 0:
    sim.fb.renderNumber(sim.digitSprites, t2Wood, 1, invY2)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "H", 1 + 18, invY2)
    sim.fb.renderNumber(sim.digitSprites, t2Ore, 40, invY2)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "C", 40 + 18, invY2)

  let invY3 = 25
  let t3Wood = player.inv.ironwood
  let t3Ore = player.inv.iron
  if t3Wood > 0 or t3Ore > 0:
    sim.fb.renderNumber(sim.digitSprites, t3Wood, 1, invY3)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "I", 1 + 18, invY3)
    sim.fb.renderNumber(sim.digitSprites, t3Ore, 40, invY3)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "R", 40 + 18, invY3)

  if sim.letterSprites.len > 0 and player.state == Idle:
    var labelObjIndex = -1
    let target = player.interactionTile()
    if inTileBounds(target.tx, target.ty):
      labelObjIndex = sim.objectIndexAt(target.tx, target.ty)
    if labelObjIndex < 0:
      let standing = player.standingTile()
      if inTileBounds(standing.tx, standing.ty):
        labelObjIndex = sim.objectIndexAt(standing.tx, standing.ty)
    if labelObjIndex >= 0:
      let obj = sim.objects[labelObjIndex]
      let label = obj.objectLabel()
      let labelX = (ScreenWidth - label.len * 6) div 2
      sim.fb.blitText(sim.letterSprites, label, labelX, ScreenHeight - 14)
      let canGather = obj.kind == GatherNodeObj and not obj.depleted and player.role == Gatherer and
                      player.canGatherMaterial(obj.material)
      let canCraft = obj.kind == CraftStationObj and player.role == Crafter and player.inv.hasCraftMaterials()
      if canGather or canCraft:
        let hint = "HOLD A"
        let hintX = (ScreenWidth - hint.len * 6) div 2
        sim.fb.blitText(sim.letterSprites, hint, hintX, ScreenHeight - 7)
      elif obj.kind == GatherNodeObj and not obj.depleted:
        var hint = ""
        if player.role != Gatherer:
          hint = "NEED GATHERER"
        elif not player.canGatherMaterial(obj.material):
          hint = "NEED T" & $(materialTier(obj.material) - 1) & " GEAR"
        if hint.len > 0:
          let hintX = (ScreenWidth - hint.len * 6) div 2
          sim.fb.blitText(sim.letterSprites, hint, hintX, ScreenHeight - 7)
      elif obj.kind == CraftStationObj:
        var hint = ""
        if player.role != Crafter:
          hint = "NEED CRAFTER"
        elif not player.inv.hasCraftMaterials():
          hint = "NEED MATERIALS"
        if hint.len > 0:
          let hintX = (ScreenWidth - hint.len * 6) div 2
          sim.fb.blitText(sim.letterSprites, hint, hintX, ScreenHeight - 7)

  if player.state == Gathering:
    sim.drawProgressBar(player.actionProgress, player.effectiveGatherWork(), 50, ScreenHeight - 5)
  elif player.state == Crafting:
    let gear = player.craftableItem()
    sim.drawProgressBar(player.actionProgress, craftWorkForTier(gearTier(gear)), 50, ScreenHeight - 5)

  if player.state == AtSellStall:
    for px in 0 ..< ScreenWidth:
      for py in ScreenHeight - 20 ..< ScreenHeight:
        sim.fb.putPixel(px, py, 0)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "SELL", 2, ScreenHeight - 18)
      let sellable = player.inv.sellableItems()
      if sellable.len > 0:
        let cursor = player.sellItemCursor mod max(1, sellable.len)
        let itemName = itemShortName(sellable[cursor])
        sim.fb.blitText(sim.letterSprites, itemName, 2, ScreenHeight - 11)
    sim.fb.renderNumber(sim.digitSprites, player.sellPrice, 50, ScreenHeight - 11)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "G", 50 + 24, ScreenHeight - 11)

  if player.state == AtBuyStall:
    for px in 0 ..< ScreenWidth:
      for py in ScreenHeight - 20 ..< ScreenHeight:
        sim.fb.putPixel(px, py, 0)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "BUY", 2, ScreenHeight - 18)
      let itemName = itemShortName(ItemKind(player.buyItemCursor mod (ord(high(ItemKind)) + 1)))
      sim.fb.blitText(sim.letterSprites, itemName, 2, ScreenHeight - 11)
    sim.fb.renderNumber(sim.digitSprites, player.buyQuantity, 50, ScreenHeight - 11)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "X", 50 + 18, ScreenHeight - 11)

proc render*(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(FloorBackdropColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
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

  sim.renderTerrain(cameraX, cameraY)
  sim.renderObjects(cameraX, cameraY)
  sim.renderSelection(playerIndex, cameraX, cameraY)
  sim.renderPlayers(cameraX, cameraY)
  sim.renderHud(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc loadRenderAssets*(sim: var SimServer) =
  loadPalette(palettePath())
  sim.fb = initFramebuffer()
  sim.digitSprites = loadDigitSprites(numbersPath())
  if fileExists(lettersPath()):
    sim.letterSprites = loadLetterSprites(lettersPath())

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerNames = initTable[WebSocket, string]()
  appState.closedSockets = @[]
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.stateViewers = initTable[WebSocket, bool]()
  appState.resetRequested = false

proc playerInputFromMasks(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.up = decoded.up
  result.down = decoded.down
  result.left = decoded.left
  result.right = decoded.right
  result.aPressed = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
  result.aHeld = (currentMask and ButtonA) != 0
  result.bPressed = (currentMask and ButtonB) != 0 and (previousMask and ButtonB) == 0
  result.selectPressed = (currentMask and ButtonSelect) != 0 and (previousMask and ButtonSelect) == 0

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket in appState.stateViewers:
    appState.stateViewers.del(websocket)
  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.playerNames.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value
    for listing in sim.npcListings.mitems:
      if listing.sellerIndex == removedIndex:
        listing.sellerIndex = -1
      elif listing.sellerIndex > removedIndex:
        dec listing.sellerIndex

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

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerNames[websocket] = request.playerIdentity()
  elif request.path == "/state" and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerNames[websocket] = request.playerIdentity()
        appState.stateViewers[websocket] = true
  elif request.path == "/reward" and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.rewardViewers[websocket] = true
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Marketboard WebSocket server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.rewardViewers and
           websocket notin appState.stateViewers:
          appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
        elif websocket in appState.stateViewers:
          appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage and isInputPacket(message.data):
      {.gcsafe.}:
        withLock appState.lock:
          let mask = blobToMask(message.data)
          if mask == 255'u8:
            appState.resetRequested = true
            appState.inputMasks[websocket] = 0
            appState.lastAppliedMasks[websocket] = 0
          else:
            appState.inputMasks[websocket] = mask
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

  sim.loadRenderAssets()

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[PlayerInput]
      shouldReset = false
      rewardViewers: seq[WebSocket] = @[]
      stateViewerSockets: seq[WebSocket] = @[]
      stateViewerIndices: seq[int] = @[]

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
        else:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              let name = appState.playerNames.getOrDefault(websocket, "unknown")
              appState.playerIndices[websocket] = sim.addPlayer(name)

          inputs = newSeq[PlayerInput](sim.players.len)
          for websocket, playerIndex in appState.playerIndices.pairs:
            if playerIndex < 0 or playerIndex >= inputs.len:
              continue
            let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
            inputs[playerIndex] = playerInputFromMasks(currentMask, previousMask)
            appState.lastAppliedMasks[websocket] = currentMask
            if websocket in appState.stateViewers:
              stateViewerSockets.add(websocket)
              stateViewerIndices.add(playerIndex)
            else:
              sockets.add(websocket)
              playerIndices.add(playerIndex)

        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)

    if shouldReset:
      inc currentSeed
      sim = initSimServer(currentSeed)
      sim.loadRenderAssets()
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              let name = appState.playerNames.getOrDefault(websocket, "unknown")
              appState.playerIndices[websocket] = sim.addPlayer(name)
            if websocket in appState.stateViewers:
              stateViewerSockets.add(websocket)
              stateViewerIndices.add(appState.playerIndices[websocket])
            else:
              sockets.add(websocket)
              playerIndices.add(appState.playerIndices[websocket])
      for i in 0 ..< sockets.len:
        let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
        sockets[i].send(frameBlob, BinaryMessage)
      for i in 0 ..< stateViewerSockets.len:
        stateViewerSockets[i].send(sim.buildStateJson(stateViewerIndices[i]), TextMessage)
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

    for i in 0 ..< stateViewerSockets.len:
      try:
        stateViewerSockets[i].send(sim.buildStateJson(stateViewerIndices[i]), TextMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(stateViewerSockets[i])

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

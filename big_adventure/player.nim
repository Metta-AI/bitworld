import pixie, protocol, server, whisky
import std/[options, os, parseopt, strutils]

const
  SheetTileSize = TileSize
  WebSocketPath = "/ws"
  PlayerCenterX = ScreenWidth div 2
  PlayerCenterY = ScreenHeight div 2
  HudHeight = 6
  WanderDuration = 24
  GameOverX = 20
  GameOverTopY = 26
  GameOverBottomY = 34
  MapWidthTiles = 256
  MapHeightTiles = 256
  MapCenterTileX = MapWidthTiles div 2
  MapCenterTileY = MapHeightTiles div 2
  CameraDeltaLimit = 4
  MinWallMatchScore = 2
  PathSearchRadiusTiles = 40
  TargetSearchPaddingTiles = 12

type
  DetectedKind = enum
    SnakeKind
    CoinKind
    HeartKind
    WallKind

  TileKnowledge = enum
    TileUnknown
    TileOpen
    TileWall

  DetectedObject = object
    kind: DetectedKind
    x: int
    y: int
    width: int
    height: int

  PathStep = object
    found: bool
    nextTx: int
    nextTy: int

  Bot = object
    wallSprite: Sprite
    playerSprite: Sprite
    snakeSprite: Sprite
    coinSprite: Sprite
    heartSprite: Sprite
    letterSprites: seq[Sprite]
    packed: seq[uint8]
    unpacked: seq[uint8]
    worldTiles: seq[TileKnowledge]
    playerWorldX: int
    playerWorldY: int
    lastVisibleWalls: seq[DetectedObject]
    haveWallFrame: bool
    wanderDir: int
    wanderTicks: int
    previousAttack: bool
    lastThought: string

proc dataDir(): string =
  getAppDir() / "data"

proc repoDir(): string =
  getAppDir() / ".."

proc clientDataDir(): string =
  repoDir() / "client" / "data"

proc sheetPath(): string =
  dataDir() / "spritesheet.png"

proc loadClientPalette() =
  loadPalette(clientDataDir() / "pallete.png")

proc loadClientLetterSprites(): seq[Sprite] =
  loadLetterSprites(clientDataDir() / "letters.png")

proc sheetSprite(sheet: Image, cellX, cellY: int): Sprite =
  spriteFromImage(
    sheet.subImage(cellX * SheetTileSize, cellY * SheetTileSize, SheetTileSize, SheetTileSize)
  )

proc unpack4bpp(packed: openArray[uint8], unpacked: var seq[uint8]) =
  let targetLen = packed.len * 2
  if unpacked.len != targetLen:
    unpacked.setLen(targetLen)

  for i, byte in packed:
    unpacked[i * 2] = byte and 0x0F
    unpacked[i * 2 + 1] = (byte shr 4) and 0x0F

proc mapIndex(tx, ty: int): int =
  ty * MapWidthTiles + tx

proc inMapBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < MapWidthTiles and ty < MapHeightTiles

proc playerTileX(bot: Bot): int =
  bot.playerWorldX div TileSize

proc playerTileY(bot: Bot): int =
  bot.playerWorldY div TileSize

proc cameraX(bot: Bot): int =
  bot.playerWorldX + bot.playerSprite.width div 2 - ScreenWidth div 2

proc cameraY(bot: Bot): int =
  bot.playerWorldY + bot.playerSprite.height div 2 - ScreenHeight div 2

proc tileKnowledge(bot: Bot, tx, ty: int): TileKnowledge =
  if not inMapBounds(tx, ty):
    return TileWall
  bot.worldTiles[mapIndex(tx, ty)]

proc rememberTile(bot: var Bot, tx, ty: int, knowledge: TileKnowledge) =
  if not inMapBounds(tx, ty):
    return

  let index = mapIndex(tx, ty)
  case knowledge
  of TileWall:
    bot.worldTiles[index] = TileWall
  of TileOpen:
    if bot.worldTiles[index] == TileUnknown:
      bot.worldTiles[index] = TileOpen
  of TileUnknown:
    discard

proc resetBehavior(bot: var Bot) =
  bot.wanderDir = 0
  bot.wanderTicks = 0
  bot.previousAttack = false
  bot.lastThought = ""

proc resetWorldModel(bot: var Bot) =
  if bot.worldTiles.len != MapWidthTiles * MapHeightTiles:
    bot.worldTiles = newSeq[TileKnowledge](MapWidthTiles * MapHeightTiles)
  for i in 0 ..< bot.worldTiles.len:
    bot.worldTiles[i] = TileUnknown
  bot.playerWorldX = MapCenterTileX * TileSize
  bot.playerWorldY = MapCenterTileY * TileSize
  bot.lastVisibleWalls.setLen(0)
  bot.haveWallFrame = false

proc resetSession(bot: var Bot) =
  bot.resetBehavior()
  bot.resetWorldModel()

proc initBot(): Bot =
  loadClientPalette()
  let sheet = readImage(sheetPath())
  result.wallSprite = sheet.sheetSprite(0, 0)
  result.playerSprite = sheet.sheetSprite(1, 0)
  result.snakeSprite = sheet.sheetSprite(2, 0)
  result.coinSprite = sheet.sheetSprite(2, 1)
  result.heartSprite = sheet.sheetSprite(0, 1)
  result.letterSprites = loadClientLetterSprites()
  result.packed = newSeq[uint8](ProtocolBytes)
  result.unpacked = newSeq[uint8](ScreenWidth * ScreenHeight)
  result.worldTiles = newSeq[TileKnowledge](MapWidthTiles * MapHeightTiles)
  result.resetSession()

proc matchesSprite(
  frame: openArray[uint8],
  sprite: Sprite,
  x, y: int
): bool =
  if x < 0 or y < 0 or x + sprite.width > ScreenWidth or y + sprite.height > ScreenHeight:
    return false

  var matchedOpaque = 0
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(sx, sy)]
      if colorIndex == TransparentColorIndex:
        continue
      inc matchedOpaque
      if frame[(y + sy) * ScreenWidth + (x + sx)] != colorIndex:
        return false
  matchedOpaque > 0

proc matchesText(
  frame: openArray[uint8],
  letterSprites: openArray[Sprite],
  text: string,
  x, y: int
): bool =
  var offsetX = 0
  for ch in text:
    if ch == ' ':
      offsetX += 6
      continue
    let idx = letterIndex(ch)
    if idx < 0 or idx >= letterSprites.len:
      return false
    if not matchesSprite(frame, letterSprites[idx], x + offsetX, y):
      return false
    offsetX += 6
  true

proc isGameOverFrame(bot: Bot): bool =
  matchesText(bot.unpacked, bot.letterSprites, "GAME", GameOverX, GameOverTopY) and
    matchesText(bot.unpacked, bot.letterSprites, "OVER", GameOverX, GameOverBottomY)

proc addUnique(result: var seq[DetectedObject], candidate: DetectedObject) =
  for existing in result:
    if abs(existing.x - candidate.x) <= 1 and abs(existing.y - candidate.y) <= 1 and existing.kind == candidate.kind:
      return
  result.add(candidate)

proc scanForObjects(
  frame: openArray[uint8],
  sprite: Sprite,
  kind: DetectedKind
): seq[DetectedObject] =
  for y in HudHeight ..< ScreenHeight - sprite.height + 1:
    for x in 0 ..< ScreenWidth - sprite.width + 1:
      if matchesSprite(frame, sprite, x, y):
        result.addUnique(DetectedObject(
          kind: kind,
          x: x,
          y: y,
          width: sprite.width,
          height: sprite.height
        ))

proc nearestToCenter(
  objects: openArray[DetectedObject]
): tuple[found: bool, obj: DetectedObject, distance: int] =
  result.distance = high(int)
  for obj in objects:
    let
      cx = obj.x + obj.width div 2
      cy = obj.y + obj.height div 2
      distance = abs(cx - PlayerCenterX) + abs(cy - PlayerCenterY)
    if distance < result.distance:
      result.found = true
      result.obj = obj
      result.distance = distance

proc moveMaskForDirection(dx, dy: int): uint8 =
  if abs(dx) >= abs(dy):
    if dx < 0:
      return ButtonLeft
    if dx > 0:
      return ButtonRight
    if dy < 0:
      return ButtonUp
    if dy > 0:
      return ButtonDown
  else:
    if dy < 0:
      return ButtonUp
    if dy > 0:
      return ButtonDown
    if dx < 0:
      return ButtonLeft
    if dx > 0:
      return ButtonRight
  0

proc wanderMask(bot: var Bot): uint8 =
  if bot.wanderTicks <= 0:
    bot.wanderDir = (bot.wanderDir + 1) mod 4
    bot.wanderTicks = WanderDuration
  dec bot.wanderTicks
  case bot.wanderDir
  of 0: ButtonRight
  of 1: ButtonDown
  of 2: ButtonLeft
  of 3: ButtonUp
  else: 0

proc movementName(mask: uint8): string =
  if (mask and ButtonLeft) != 0: return "west"
  if (mask and ButtonRight) != 0: return "east"
  if (mask and ButtonUp) != 0: return "north"
  if (mask and ButtonDown) != 0: return "south"
  "still"

proc kindName(kind: DetectedKind): string =
  case kind
  of SnakeKind: "snake"
  of CoinKind: "coin"
  of HeartKind: "heart"
  of WallKind: "wall"

proc think(bot: var Bot, thought: string) =
  if thought != bot.lastThought:
    bot.lastThought = thought
    echo thought

proc inAttackRange(obj: DetectedObject): bool =
  let
    cx = obj.x + obj.width div 2
    cy = obj.y + obj.height div 2
    dx = cx - PlayerCenterX
    dy = cy - PlayerCenterY
  if abs(dx) >= abs(dy):
    abs(dx) <= 9 and abs(dy) <= 5
  else:
    abs(dy) <= 9 and abs(dx) <= 5

proc estimateCameraDelta(
  bot: Bot,
  walls: openArray[DetectedObject]
): tuple[trusted: bool, dx: int, dy: int] =
  if not bot.haveWallFrame or bot.lastVisibleWalls.len == 0 or walls.len == 0:
    return (false, 0, 0)

  var previousWallGrid = newSeq[bool](ScreenWidth * ScreenHeight)
  for wall in bot.lastVisibleWalls:
    if wall.x >= 0 and wall.y >= 0 and wall.x < ScreenWidth and wall.y < ScreenHeight:
      previousWallGrid[wall.y * ScreenWidth + wall.x] = true

  var bestScore = -1
  for dy in -CameraDeltaLimit .. CameraDeltaLimit:
    for dx in -CameraDeltaLimit .. CameraDeltaLimit:
      var score = 0
      for wall in walls:
        let
          previousX = wall.x + dx
          previousY = wall.y + dy
        if previousX < 0 or previousY < 0 or previousX >= ScreenWidth or previousY >= ScreenHeight:
          continue
        if previousWallGrid[previousY * ScreenWidth + previousX]:
          inc score
      if score > bestScore:
        bestScore = score
        result = (score >= MinWallMatchScore, dx, dy)

proc rememberVisibleTerrain(bot: var Bot, walls: openArray[DetectedObject]) =
  var wallGrid = newSeq[bool](ScreenWidth * ScreenHeight)
  for wall in walls:
    if wall.x >= 0 and wall.y >= 0 and wall.x < ScreenWidth and wall.y < ScreenHeight:
      wallGrid[wall.y * ScreenWidth + wall.x] = true

  let
    camX = bot.cameraX()
    camY = bot.cameraY()
    startTx = max(0, camX div TileSize)
    startTy = max(0, camY div TileSize)
    endTx = min(MapWidthTiles - 1, (camX + ScreenWidth - 1) div TileSize)
    endTy = min(MapHeightTiles - 1, (camY + ScreenHeight - 1) div TileSize)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        screenX = tx * TileSize - camX
        screenY = ty * TileSize - camY
      if screenX < 0 or screenY < HudHeight:
        continue
      if screenX + TileSize > ScreenWidth or screenY + TileSize > ScreenHeight:
        continue
      if wallGrid[screenY * ScreenWidth + screenX]:
        bot.rememberTile(tx, ty, TileWall)
      else:
        bot.rememberTile(tx, ty, TileOpen)

proc updateWorldModel(bot: var Bot, walls: openArray[DetectedObject]) =
  let delta = bot.estimateCameraDelta(walls)
  if delta.trusted:
    bot.playerWorldX += delta.dx
    bot.playerWorldY += delta.dy
  bot.rememberVisibleTerrain(walls)
  bot.lastVisibleWalls = @walls
  bot.haveWallFrame = true

proc objectWorldCenter(bot: Bot, obj: DetectedObject): tuple[x: int, y: int] =
  (
    bot.cameraX() + obj.x + obj.width div 2,
    bot.cameraY() + obj.y + obj.height div 2
  )

proc canTraverse(bot: Bot, tx, ty: int): bool =
  bot.tileKnowledge(tx, ty) != TileWall

proc reconstructStep(
  parents: openArray[int],
  width, minTx, minTy, startIndex, goalIndex: int
): PathStep =
  var stepIndex = goalIndex
  while parents[stepIndex] != -1 and parents[stepIndex] != startIndex:
    stepIndex = parents[stepIndex]
  result.found = true
  result.nextTx = minTx + (stepIndex mod width)
  result.nextTy = minTy + (stepIndex div width)

proc findPathStep(bot: Bot, targetTx, targetTy: int): PathStep =
  let
    startTx = bot.playerTileX()
    startTy = bot.playerTileY()
  if not inMapBounds(targetTx, targetTy) or not bot.canTraverse(targetTx, targetTy):
    return
  if startTx == targetTx and startTy == targetTy:
    return PathStep(found: true, nextTx: startTx, nextTy: startTy)

  let
    minTx = max(0, min(startTx, targetTx) - TargetSearchPaddingTiles)
    minTy = max(0, min(startTy, targetTy) - TargetSearchPaddingTiles)
    maxTx = min(MapWidthTiles - 1, max(startTx, targetTx) + TargetSearchPaddingTiles)
    maxTy = min(MapHeightTiles - 1, max(startTy, targetTy) + TargetSearchPaddingTiles)
    width = maxTx - minTx + 1
    height = maxTy - minTy + 1
    area = width * height

  var
    parents = newSeq[int](area)
    queue = newSeq[int](area)
    head = 0
    tail = 0
    goalIndex = -1

  for i in 0 ..< parents.len:
    parents[i] = -2

  let startIndex = (startTy - minTy) * width + (startTx - minTx)
  parents[startIndex] = -1
  queue[tail] = startIndex
  inc tail

  while head < tail:
    let currentIndex = queue[head]
    inc head
    let
      tx = minTx + (currentIndex mod width)
      ty = minTy + (currentIndex div width)
    if tx == targetTx and ty == targetTy:
      goalIndex = currentIndex
      break

    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nextTx = tx + delta[0]
        nextTy = ty + delta[1]
      if nextTx < minTx or nextTy < minTy or nextTx > maxTx or nextTy > maxTy:
        continue
      if not bot.canTraverse(nextTx, nextTy):
        continue
      let nextIndex = (nextTy - minTy) * width + (nextTx - minTx)
      if parents[nextIndex] != -2:
        continue
      parents[nextIndex] = currentIndex
      queue[tail] = nextIndex
      inc tail

  if goalIndex >= 0:
    return reconstructStep(parents, width, minTx, minTy, startIndex, goalIndex)

proc hasUnknownNeighbor(bot: Bot, tx, ty: int): bool =
  for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
    if bot.tileKnowledge(tx + delta[0], ty + delta[1]) == TileUnknown:
      return true
  false

proc findExplorationStep(bot: Bot): PathStep =
  let
    startTx = bot.playerTileX()
    startTy = bot.playerTileY()
    minTx = max(0, startTx - PathSearchRadiusTiles)
    minTy = max(0, startTy - PathSearchRadiusTiles)
    maxTx = min(MapWidthTiles - 1, startTx + PathSearchRadiusTiles)
    maxTy = min(MapHeightTiles - 1, startTy + PathSearchRadiusTiles)
    width = maxTx - minTx + 1
    height = maxTy - minTy + 1
    area = width * height

  var
    parents = newSeq[int](area)
    queue = newSeq[int](area)
    head = 0
    tail = 0

  for i in 0 ..< parents.len:
    parents[i] = -2

  let startIndex = (startTy - minTy) * width + (startTx - minTx)
  parents[startIndex] = -1
  queue[tail] = startIndex
  inc tail

  while head < tail:
    let currentIndex = queue[head]
    inc head
    let
      tx = minTx + (currentIndex mod width)
      ty = minTy + (currentIndex div width)
    if currentIndex != startIndex and (
      bot.tileKnowledge(tx, ty) == TileUnknown or bot.hasUnknownNeighbor(tx, ty)
    ):
      return reconstructStep(parents, width, minTx, minTy, startIndex, currentIndex)

    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nextTx = tx + delta[0]
        nextTy = ty + delta[1]
      if nextTx < minTx or nextTy < minTy or nextTx > maxTx or nextTy > maxTy:
        continue
      if not bot.canTraverse(nextTx, nextTy):
        continue
      let nextIndex = (nextTy - minTy) * width + (nextTx - minTx)
      if parents[nextIndex] != -2:
        continue
      parents[nextIndex] = currentIndex
      queue[tail] = nextIndex
      inc tail

proc stepMaskForPath(bot: Bot, step: PathStep): uint8 =
  if not step.found:
    return 0
  let
    startTx = bot.playerTileX()
    startTy = bot.playerTileY()
  if step.nextTx < startTx:
    return ButtonLeft
  if step.nextTx > startTx:
    return ButtonRight
  if step.nextTy < startTy:
    return ButtonUp
  if step.nextTy > startTy:
    return ButtonDown
  0

proc decideNextMask(bot: var Bot): uint8 =
  let walls = scanForObjects(bot.unpacked, bot.wallSprite, WallKind)
  bot.updateWorldModel(walls)

  let
    snakes = scanForObjects(bot.unpacked, bot.snakeSprite, SnakeKind)
    coins = scanForObjects(bot.unpacked, bot.coinSprite, CoinKind)
    hearts = scanForObjects(bot.unpacked, bot.heartSprite, HeartKind)

  var selected = nearestToCenter(snakes)
  if not selected.found:
    selected = nearestToCenter(coins)
  if not selected.found:
    selected = nearestToCenter(hearts)

  if selected.found:
    let
      target = selected.obj
      targetWorld = bot.objectWorldCenter(target)
      targetTx = targetWorld.x div TileSize
      targetTy = targetWorld.y div TileSize
      pathStep = bot.findPathStep(targetTx, targetTy)
      pathMask = bot.stepMaskForPath(pathStep)
      targetCenterX = target.x + target.width div 2
      targetCenterY = target.y + target.height div 2
      dx = targetCenterX - PlayerCenterX
      dy = targetCenterY - PlayerCenterY
      aimMask = moveMaskForDirection(dx, dy)

    bot.wanderTicks = 0

    if target.kind == SnakeKind and inAttackRange(target):
      if not bot.previousAttack:
        result = aimMask or ButtonA
        bot.think("seeing snake at (" & $targetTx & ", " & $targetTy & "), attacking")
        bot.previousAttack = true
      else:
        bot.think("holding position after swing, watching snake")
        bot.previousAttack = false
      return

    result = if pathMask != 0: pathMask else: aimMask
    if pathMask != 0:
      bot.think(
        "seeing " & kindName(target.kind) & " at (" & $targetTx & ", " & $targetTy &
        "), pathing " & movementName(result)
      )
    else:
      bot.think(
        "seeing " & kindName(target.kind) & " at (" & $targetTx & ", " & $targetTy &
        "), moving " & movementName(result)
      )
    bot.previousAttack = false
    return

  let exploreStep = bot.findExplorationStep()
  result = bot.stepMaskForPath(exploreStep)
  if result != 0:
    bot.think("mapping the world, exploring " & movementName(result))
  else:
    result = bot.wanderMask()
    bot.think("no path in memory yet, wandering " & movementName(result))
  bot.previousAttack = false

proc runBot(host = DefaultHost, port = DefaultPort) =
  var bot = initBot()
  let url = "ws://" & host & ":" & $port & WebSocketPath

  while true:
    try:
      let ws = newWebSocket(url)
      bot.resetSession()
      var lastMask = 0xFF'u8
      echo "Connected to ", url

      while true:
        let message = ws.receiveMessage()
        if message.isNone:
          continue

        case message.get.kind
        of BinaryMessage:
          if message.get.data.len != ProtocolBytes:
            continue
          blobToBytes(message.get.data, bot.packed)
          unpack4bpp(bot.packed, bot.unpacked)
          if bot.isGameOverFrame():
            bot.think("game over detected, reconnecting")
            bot.resetSession()
            ws.close()
            break
          let nextMask = bot.decideNextMask()
          if nextMask != lastMask:
            ws.send(blobFromMask(nextMask), BinaryMessage)
            lastMask = nextMask
        of Ping:
          ws.send(message.get.data, Pong)
        of TextMessage, Pong:
          discard
    except Exception as e:
      echo "Bot reconnecting after error: ", e.msg
      sleep(250)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      else: discard
    else: discard
  runBot(address, port)

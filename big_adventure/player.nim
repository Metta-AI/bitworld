import pixie, protocol, server, silky, whisky, windy
import std/[heapqueue, math, monotimes, options, os, parseopt, strutils, times]

const
  SheetTileSize = TileSize
  WebSocketPath = "/player"
  PlayerCenterX = ScreenWidth div 2
  PlayerCenterY = ScreenHeight div 2
  HudHeight = 6
  WanderDuration = 72
  GameOverX = 20
  GameOverTopY = 26
  GameOverBottomY = 34
  MapWidthTiles = 256
  MapHeightTiles = 256
  MapCenterTileX = MapWidthTiles div 2
  MapCenterTileY = MapHeightTiles div 2
  CameraDeltaLimit = 4
  MinWallMatchScore = 2
  PlayerDefaultPort = 2000
  BlockedMoveConfirmFrames = 8
  BossFleeSearchRadiusTiles = 18
  UnknownTileCost = 8
  WallFollowDuration = 18
  ViewerWindowWidth = 1560
  ViewerWindowHeight = 960
  ViewerMargin = 16.0'f
  ViewerFrameScale = 5.0'f
  ViewerMapScale = 2.25'f
  ViewerBackground = rgbx(17, 20, 28, 255)
  ViewerPanel = rgbx(33, 38, 50, 255)
  ViewerPanelAlt = rgbx(25, 30, 41, 255)
  ViewerText = rgbx(226, 231, 240, 255)
  ViewerWallBox = rgbx(248, 248, 252, 255)
  ViewerMutedText = rgbx(146, 155, 172, 255)
  ViewerUnknown = rgbx(25, 29, 39, 255)
  ViewerOpen = rgbx(66, 83, 92, 255)
  ViewerWall = rgbx(214, 108, 65, 255)
  ViewerFrontier = rgbx(247, 196, 88, 255)
  ViewerViewport = rgbx(142, 193, 255, 180)
  ViewerPlayer = rgbx(120, 255, 170, 255)
  ViewerGoal = rgbx(255, 132, 146, 255)
  ViewerRemembered = rgbx(255, 214, 92, 255)
  ViewerBoss = rgbx(224, 111, 139, 255)
  ViewerSnake = rgbx(124, 214, 48, 255)
  ViewerCoin = rgbx(255, 220, 110, 255)
  ViewerHeart = rgbx(255, 95, 123, 255)

type
  DetectedKind = enum
    BossKind
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

  SearchNode = object
    priority: int
    index: int

  RememberedObject = object
    kind: DetectedKind
    worldX: int
    worldY: int
    width: int
    height: int
    lastSeenTick: int

  ViewerApp = ref object
    window: Window
    silky: Silky

  Bot = object
    wallSprite: Sprite
    playerSprite: Sprite
    bossSprite: Sprite
    snakeSprite: Sprite
    coinSprite: Sprite
    heartSprite: Sprite
    letterSprites: seq[Sprite]
    packed: seq[uint8]
    unpacked: seq[uint8]
    worldTiles: seq[TileKnowledge]
    playerWorldX: int
    playerWorldY: int
    lastResolvedWorldX: int
    lastResolvedWorldY: int
    lastWorldDeltaTrusted: bool
    blockedTileX: int
    blockedTileY: int
    blockedMoveFrames: int
    lastVisibleWalls: seq[DetectedObject]
    lastVisibleObjects: seq[DetectedObject]
    rememberedObjects: seq[RememberedObject]
    haveWallFrame: bool
    wanderDir: int
    wanderTicks: int
    wallFollowMask: uint8
    wallFollowTicks: int
    previousAttack: bool
    lastThought: string
    frameTick: int
    goalWorldX: int
    goalWorldY: int
    goalNextTx: int
    goalNextTy: int
    hasGoal: bool
    hasNextStep: bool
    goalLabel: string
    intentLabel: string
    attackIntent: string
    lastMask: uint8

proc dataDir(): string =
  getCurrentDir() / "data"

proc repoDir(): string =
  getCurrentDir() / ".."

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

proc sheetRegionSprite(sheet: Image, x, y, width, height: int): Sprite =
  spriteFromImage(sheet.subImage(x, y, width, height))

proc atlasPath(): string =
  repoDir() / "client" / "dist" / "atlas.png"

proc unpack4bpp(packed: openArray[uint8], unpacked: var seq[uint8]) =
  let targetLen = packed.len * 2
  if unpacked.len != targetLen:
    unpacked.setLen(targetLen)

  for i, byte in packed:
    unpacked[i * 2] = byte and 0x0F
    unpacked[i * 2 + 1] = (byte shr 4) and 0x0F

proc mapIndex(tx, ty: int): int =
  ty * MapWidthTiles + tx

proc distanceSquared(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc `<`(a, b: SearchNode): bool =
  if a.priority == b.priority:
    return a.index < b.index
  a.priority < b.priority

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
  bot.wallFollowMask = 0
  bot.wallFollowTicks = 0
  bot.previousAttack = false
  bot.lastThought = ""
  bot.hasGoal = false
  bot.hasNextStep = false
  bot.goalLabel = ""
  bot.intentLabel = ""
  bot.attackIntent = ""
  bot.lastMask = 0
  bot.blockedMoveFrames = 0
  bot.lastWorldDeltaTrusted = false

proc resetWorldModel(bot: var Bot) =
  if bot.worldTiles.len != MapWidthTiles * MapHeightTiles:
    bot.worldTiles = newSeq[TileKnowledge](MapWidthTiles * MapHeightTiles)
  for i in 0 ..< bot.worldTiles.len:
    bot.worldTiles[i] = TileUnknown
  bot.playerWorldX = MapCenterTileX * TileSize
  bot.playerWorldY = MapCenterTileY * TileSize
  bot.lastResolvedWorldX = bot.playerWorldX
  bot.lastResolvedWorldY = bot.playerWorldY
  bot.blockedTileX = -1
  bot.blockedTileY = -1
  bot.lastVisibleWalls.setLen(0)
  bot.lastVisibleObjects.setLen(0)
  bot.rememberedObjects.setLen(0)
  bot.haveWallFrame = false
  bot.frameTick = 0

proc resetSession(bot: var Bot) =
  bot.resetBehavior()
  bot.resetWorldModel()

proc initBot(): Bot =
  loadClientPalette()
  let sheet = readImage(sheetPath())
  result.wallSprite = sheet.sheetSprite(0, 0)
  result.playerSprite = sheet.sheetSprite(1, 0)
  result.snakeSprite = sheet.sheetSprite(2, 0)
  result.bossSprite = sheet.sheetRegionSprite(0, 2 * SheetTileSize, 2 * SheetTileSize, 2 * SheetTileSize)
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

proc maskTargetTile(bot: Bot, mask: uint8): tuple[valid: bool, tx: int, ty: int] =
  result.tx = bot.playerTileX()
  result.ty = bot.playerTileY()
  if (mask and ButtonLeft) != 0:
    dec result.tx
    result.valid = true
  elif (mask and ButtonRight) != 0:
    inc result.tx
    result.valid = true
  elif (mask and ButtonUp) != 0:
    dec result.ty
    result.valid = true
  elif (mask and ButtonDown) != 0:
    inc result.ty
    result.valid = true

proc maskBlocked(bot: Bot, mask: uint8): bool =
  let target = bot.maskTargetTile(mask)
  target.valid and bot.tileKnowledge(target.tx, target.ty) == TileWall

proc oppositeMask(mask: uint8): uint8 =
  if (mask and ButtonLeft) != 0: return ButtonRight
  if (mask and ButtonRight) != 0: return ButtonLeft
  if (mask and ButtonUp) != 0: return ButtonDown
  if (mask and ButtonDown) != 0: return ButtonUp
  0

proc sideMasks(primaryMask: uint8, dx, dy: int): array[2, uint8] =
  if (primaryMask and (ButtonLeft or ButtonRight)) != 0:
    if dy < 0:
      return [ButtonUp, ButtonDown]
    if dy > 0:
      return [ButtonDown, ButtonUp]
    return [ButtonUp, ButtonDown]

  if dx < 0:
    return [ButtonLeft, ButtonRight]
  if dx > 0:
    return [ButtonRight, ButtonLeft]
  [ButtonLeft, ButtonRight]

proc setGoalPreview(bot: var Bot, worldX, worldY: int, label: string, moveMask: uint8) =
  bot.hasGoal = true
  bot.goalWorldX = worldX
  bot.goalWorldY = worldY
  bot.goalLabel = label
  let next = bot.maskTargetTile(moveMask)
  bot.hasNextStep = next.valid
  if next.valid:
    bot.goalNextTx = next.tx
    bot.goalNextTy = next.ty

proc steerMask(bot: var Bot, desiredMask: uint8, dx, dy: int): uint8 =
  if desiredMask == 0:
    bot.wallFollowMask = 0
    bot.wallFollowTicks = 0
    return 0

  if not bot.maskBlocked(desiredMask):
    bot.wallFollowMask = 0
    bot.wallFollowTicks = 0
    return desiredMask

  if bot.wallFollowTicks > 0 and bot.wallFollowMask != 0 and not bot.maskBlocked(bot.wallFollowMask):
    dec bot.wallFollowTicks
    return bot.wallFollowMask

  for sideMask in sideMasks(desiredMask, dx, dy):
    if not bot.maskBlocked(sideMask):
      bot.wallFollowMask = sideMask
      bot.wallFollowTicks = WallFollowDuration
      return sideMask

  let reverseMask = oppositeMask(desiredMask)
  if reverseMask != 0 and not bot.maskBlocked(reverseMask):
    bot.wallFollowMask = reverseMask
    bot.wallFollowTicks = WallFollowDuration div 2
    return reverseMask

  bot.wallFollowMask = 0
  bot.wallFollowTicks = 0
  0

proc wanderMask(bot: var Bot): uint8 =
  for _ in 0 ..< 4:
    if bot.wanderTicks <= 0:
      bot.wanderDir = (bot.wanderDir + 1) mod 4
      bot.wanderTicks = WanderDuration
    dec bot.wanderTicks

    let mask =
      case bot.wanderDir
      of 0: ButtonRight
      of 1: ButtonDown
      of 2: ButtonLeft
      of 3: ButtonUp
      else: 0

    let target = bot.maskTargetTile(mask)
    if not target.valid or bot.tileKnowledge(target.tx, target.ty) != TileWall:
      return mask
    bot.wanderTicks = 0
  0

proc movementName(mask: uint8): string =
  if (mask and ButtonLeft) != 0: return "west"
  if (mask and ButtonRight) != 0: return "east"
  if (mask and ButtonUp) != 0: return "north"
  if (mask and ButtonDown) != 0: return "south"
  "still"

proc kindName(kind: DetectedKind): string =
  case kind
  of BossKind: "boss"
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

proc objectPriority(kind: DetectedKind): int =
  case kind
  of CoinKind, HeartKind: 0
  of SnakeKind: 1
  of BossKind: 2
  of WallKind: 4

proc objectWorldCenter(bot: Bot, obj: DetectedObject): tuple[x: int, y: int] =
  (
    bot.cameraX() + obj.x + obj.width div 2,
    bot.cameraY() + obj.y + obj.height div 2
  )

proc rememberVisibleObject(bot: var Bot, obj: DetectedObject) =
  let
    world = bot.objectWorldCenter(obj)
    threshold = max(TileSize, max(obj.width, obj.height))
    thresholdSq = threshold * threshold
  for remembered in bot.rememberedObjects.mitems:
    if remembered.kind == obj.kind and
        distanceSquared(remembered.worldX, remembered.worldY, world.x, world.y) <= thresholdSq:
      remembered.worldX = world.x
      remembered.worldY = world.y
      remembered.width = obj.width
      remembered.height = obj.height
      remembered.lastSeenTick = bot.frameTick
      return

  bot.rememberedObjects.add RememberedObject(
    kind: obj.kind,
    worldX: world.x,
    worldY: world.y,
    width: obj.width,
    height: obj.height,
    lastSeenTick: bot.frameTick
  )

proc isRememberedOnScreen(bot: Bot, remembered: RememberedObject): bool =
  let
    camX = bot.cameraX()
    camY = bot.cameraY()
    left = camX
    top = camY + HudHeight
    right = camX + ScreenWidth
    bottom = camY + ScreenHeight
  remembered.worldX >= left and remembered.worldX < right and
    remembered.worldY >= top and remembered.worldY < bottom

proc syncRememberedObjects(bot: var Bot, objects: openArray[DetectedObject]) =
  var updated: seq[RememberedObject] = @[]
  for remembered in bot.rememberedObjects:
    var keep = true
    if bot.isRememberedOnScreen(remembered):
      keep = false
      for obj in objects:
        let
          world = bot.objectWorldCenter(obj)
          threshold = max(TileSize, max(obj.width, obj.height))
          thresholdSq = threshold * threshold
        if remembered.kind == obj.kind and
            distanceSquared(remembered.worldX, remembered.worldY, world.x, world.y) <= thresholdSq:
          keep = true
          break
    if keep:
      updated.add remembered

  bot.rememberedObjects = move(updated)
  for obj in objects:
    bot.rememberVisibleObject(obj)

proc nearestVisibleTarget(
  objects: openArray[DetectedObject]
): tuple[found: bool, obj: DetectedObject, distance: int] =
  var bestPriority = high(int)
  result.distance = high(int)
  for obj in objects:
    if obj.kind == BossKind:
      continue
    let
      priority = objectPriority(obj.kind)
      cx = obj.x + obj.width div 2
      cy = obj.y + obj.height div 2
      distance = abs(cx - PlayerCenterX) + abs(cy - PlayerCenterY)
    if priority < bestPriority or (priority == bestPriority and distance < result.distance):
      bestPriority = priority
      result.found = true
      result.obj = obj
      result.distance = distance

proc nearestRememberedTarget(
  bot: Bot
): tuple[found: bool, remembered: RememberedObject, distance: int] =
  var bestPriority = high(int)
  result.distance = high(int)
  for remembered in bot.rememberedObjects:
    if remembered.kind in {WallKind, BossKind}:
      continue
    let
      priority = objectPriority(remembered.kind)
      distance = abs(remembered.worldX - bot.playerWorldX) + abs(remembered.worldY - bot.playerWorldY)
    if priority < bestPriority or (priority == bestPriority and distance < result.distance):
      bestPriority = priority
      result.found = true
      result.remembered = remembered
      result.distance = distance

proc setGoalTarget(bot: var Bot, worldX, worldY: int, label: string, step = PathStep()) =
  bot.hasGoal = true
  bot.goalWorldX = worldX
  bot.goalWorldY = worldY
  bot.goalLabel = label
  bot.hasNextStep = step.found
  if step.found:
    bot.goalNextTx = step.nextTx
    bot.goalNextTy = step.nextTy

proc clearGoal(bot: var Bot) =
  bot.hasGoal = false
  bot.hasNextStep = false
  bot.goalLabel = ""

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

      let
        centerX = screenX + TileSize div 2
        centerY = screenY + TileSize div 2

      var sawWall = false
      for wall in walls:
        if centerX >= wall.x and centerX < wall.x + wall.width and
            centerY >= wall.y and centerY < wall.y + wall.height:
          sawWall = true
          break

      if sawWall:
        bot.rememberTile(tx, ty, TileWall)
      else:
        bot.rememberTile(tx, ty, TileOpen)

proc updateWorldModel(bot: var Bot, walls: openArray[DetectedObject]) =
  let delta = bot.estimateCameraDelta(walls)
  bot.lastWorldDeltaTrusted = delta.trusted
  if delta.trusted:
    bot.playerWorldX += delta.dx
    bot.playerWorldY += delta.dy
  bot.rememberVisibleTerrain(walls)
  bot.lastVisibleWalls = @walls
  bot.haveWallFrame = true

proc traversalCost(bot: Bot, tx, ty: int, allowUnknown: bool): int =
  case bot.tileKnowledge(tx, ty)
  of TileWall:
    -1
  of TileOpen:
    1
  of TileUnknown:
    if allowUnknown: UnknownTileCost else: -1

proc heuristicDistance(ax, ay, bx, by: int): int =
  abs(ax - bx) + abs(ay - by)

proc reconstructStep(
  parents: openArray[int],
  startIndex, goalIndex: int
): PathStep =
  var stepIndex = goalIndex
  while parents[stepIndex] != -1 and parents[stepIndex] != startIndex:
    stepIndex = parents[stepIndex]
  result.found = true
  result.nextTx = stepIndex mod MapWidthTiles
  result.nextTy = stepIndex div MapWidthTiles

proc findPathStep(bot: Bot, targetTx, targetTy: int, allowUnknown = true): PathStep =
  let
    startTx = bot.playerTileX()
    startTy = bot.playerTileY()
    startIndex = mapIndex(startTx, startTy)
    goalIndex = mapIndex(targetTx, targetTy)
    area = MapWidthTiles * MapHeightTiles
  if not inMapBounds(targetTx, targetTy):
    return
  if bot.traversalCost(targetTx, targetTy, allowUnknown) < 0:
    return
  if startTx == targetTx and startTy == targetTy:
    return PathStep(found: true, nextTx: startTx, nextTy: startTy)

  var
    parents = newSeq[int](area)
    bestCosts = newSeq[int](area)
    closed = newSeq[bool](area)
    openSet: HeapQueue[SearchNode]

  for i in 0 ..< parents.len:
    parents[i] = -2
    bestCosts[i] = high(int)

  parents[startIndex] = -1
  bestCosts[startIndex] = 0
  openSet.push(SearchNode(
    priority: heuristicDistance(startTx, startTy, targetTx, targetTy),
    index: startIndex
  ))

  while openSet.len > 0:
    let current = openSet.pop()
    if closed[current.index]:
      continue
    if current.index == goalIndex:
      return reconstructStep(parents, startIndex, goalIndex)

    closed[current.index] = true
    let
      tx = current.index mod MapWidthTiles
      ty = current.index div MapWidthTiles

    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nextTx = tx + delta[0]
        nextTy = ty + delta[1]
      if not inMapBounds(nextTx, nextTy):
        continue
      let stepCost = bot.traversalCost(nextTx, nextTy, allowUnknown)
      if stepCost < 0:
        continue
      let nextIndex = mapIndex(nextTx, nextTy)
      if closed[nextIndex]:
        continue
      let tentativeCost = bestCosts[current.index] + stepCost
      if tentativeCost >= bestCosts[nextIndex]:
        continue
      bestCosts[nextIndex] = tentativeCost
      parents[nextIndex] = current.index
      openSet.push(SearchNode(
        priority: tentativeCost + heuristicDistance(nextTx, nextTy, targetTx, targetTy),
        index: nextIndex
      ))

proc hasUnknownNeighbor(bot: Bot, tx, ty: int): bool =
  for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
    if bot.tileKnowledge(tx + delta[0], ty + delta[1]) == TileUnknown:
      return true
  false

proc findExplorationGoal(bot: Bot): tuple[found: bool, tx: int, ty: int] =
  let
    startTx = bot.playerTileX()
    startTy = bot.playerTileY()
    area = MapWidthTiles * MapHeightTiles

  var
    queue = newSeq[int](area)
    visited = newSeq[bool](area)
    head = 0
    tail = 0

  let startIndex = mapIndex(startTx, startTy)
  if bot.tileKnowledge(startTx, startTy) == TileWall:
    return
  visited[startIndex] = true
  queue[tail] = startIndex
  inc tail

  while head < tail:
    let currentIndex = queue[head]
    inc head
    let
      tx = currentIndex mod MapWidthTiles
      ty = currentIndex div MapWidthTiles
    if bot.tileKnowledge(tx, ty) == TileOpen and bot.hasUnknownNeighbor(tx, ty):
      return (true, tx, ty)

    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nextTx = tx + delta[0]
        nextTy = ty + delta[1]
      if not inMapBounds(nextTx, nextTy):
        continue
      if bot.tileKnowledge(nextTx, nextTy) != TileOpen:
        continue
      let nextIndex = mapIndex(nextTx, nextTy)
      if visited[nextIndex]:
        continue
      visited[nextIndex] = true
      queue[tail] = nextIndex
      inc tail

proc findExplorationStep(bot: Bot): PathStep =
  let frontier = bot.findExplorationGoal()
  if frontier.found:
    return bot.findPathStep(frontier.tx, frontier.ty, false)

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

proc movementTargetTile(bot: Bot, mask: uint8): tuple[valid: bool, tx: int, ty: int] =
  bot.maskTargetTile(mask)

proc learnBlockedMovement(bot: var Bot) =
  bot.blockedMoveFrames = 0
  bot.blockedTileX = -1
  bot.blockedTileY = -1
  bot.lastResolvedWorldX = bot.playerWorldX
  bot.lastResolvedWorldY = bot.playerWorldY

proc nearestVisibleObject(
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

proc fleeTargetTile(
  bot: Bot,
  threats: openArray[DetectedObject]
): tuple[found: bool, tx: int, ty: int, directMask: uint8] =
  let
    playerTx = bot.playerTileX()
    playerTy = bot.playerTileY()
  var
    awayX = 0
    awayY = 0
    bestScore = low(int)

  for threat in threats:
    let
      world = bot.objectWorldCenter(threat)
      threatTx = world.x div TileSize
      threatTy = world.y div TileSize
    awayX += playerTx - threatTx
    awayY += playerTy - threatTy

  if awayX == 0 and awayY == 0:
    awayY = -1

  result.directMask = moveMaskForDirection(awayX, awayY)

  let
    minTx = max(0, playerTx - BossFleeSearchRadiusTiles)
    minTy = max(0, playerTy - BossFleeSearchRadiusTiles)
    maxTx = min(MapWidthTiles - 1, playerTx + BossFleeSearchRadiusTiles)
    maxTy = min(MapHeightTiles - 1, playerTy + BossFleeSearchRadiusTiles)

  for ty in minTy .. maxTy:
    for tx in minTx .. maxTx:
      if tx == playerTx and ty == playerTy:
        continue
      let tileCost = bot.traversalCost(tx, ty, true)
      if tileCost < 0:
        continue

      var nearestThreatDistance = high(int)
      for threat in threats:
        let
          world = bot.objectWorldCenter(threat)
          threatTx = world.x div TileSize
          threatTy = world.y div TileSize
        nearestThreatDistance = min(
          nearestThreatDistance,
          heuristicDistance(tx, ty, threatTx, threatTy)
        )

      let
        projection = (tx - playerTx) * awayX + (ty - playerTy) * awayY
        knowledgeBonus =
          case bot.tileKnowledge(tx, ty)
          of TileOpen: 6
          of TileUnknown: 0
          of TileWall: -1000
        score = nearestThreatDistance * 100 + projection * 6 + knowledgeBonus

      if score > bestScore:
        bestScore = score
        result = (true, tx, ty, result.directMask)

proc fleeFromBoss(bot: var Bot, bosses: openArray[DetectedObject]): uint8 =
  var
    awayX = 0
    awayY = 0
  for boss in bosses:
    let world = bot.objectWorldCenter(boss)
    awayX += bot.playerWorldX - world.x
    awayY += bot.playerWorldY - world.y

  let
    desiredMask = moveMaskForDirection(awayX, awayY)
    fleeMask = bot.steerMask(desiredMask, awayX, awayY)
    goalWorldX = bot.playerWorldX + (if awayX < 0: -TileSize * 4 elif awayX > 0: TileSize * 4 else: 0)
    goalWorldY = bot.playerWorldY + (if awayY < 0: -TileSize * 4 elif awayY > 0: TileSize * 4 else: 0)

  if fleeMask != 0:
    bot.setGoalPreview(goalWorldX, goalWorldY, "avoid visible boss", fleeMask)
    bot.intentLabel = "run away from visible boss"
    bot.attackIntent = "avoid boss"
    bot.previousAttack = false
    bot.think("boss spotted, retreating " & movementName(fleeMask))
    return fleeMask

  result = bot.wanderMask()
  if result != 0:
    bot.setGoalPreview(goalWorldX, goalWorldY, "avoid visible boss", result)
  else:
    bot.clearGoal()
  bot.intentLabel = "run away from visible boss"
  bot.attackIntent = "avoid boss"
  bot.previousAttack = false
  bot.think("boss spotted, sliding around the wall")

proc inMeleeTileRange(bot: Bot, targetTx, targetTy: int): bool =
  let
    dx = abs(targetTx - bot.playerTileX())
    dy = abs(targetTy - bot.playerTileY())
  dx <= 1 and dy <= 1

proc decideNextMask(bot: var Bot): uint8 =
  let walls = scanForObjects(bot.unpacked, bot.wallSprite, WallKind)
  bot.updateWorldModel(walls)
  bot.learnBlockedMovement()

  let
    bosses = scanForObjects(bot.unpacked, bot.bossSprite, BossKind)
    snakes = scanForObjects(bot.unpacked, bot.snakeSprite, SnakeKind)
    coins = scanForObjects(bot.unpacked, bot.coinSprite, CoinKind)
    hearts = scanForObjects(bot.unpacked, bot.heartSprite, HeartKind)
  bot.lastVisibleObjects = @[]
  bot.lastVisibleObjects.add(bosses)
  bot.lastVisibleObjects.add(snakes)
  bot.lastVisibleObjects.add(coins)
  bot.lastVisibleObjects.add(hearts)
  bot.syncRememberedObjects(bot.lastVisibleObjects)
  bot.clearGoal()
  bot.intentLabel = ""
  bot.attackIntent = "not attacking"

  let visibleBoss = nearestVisibleObject(bosses)
  if visibleBoss.found:
    bot.wanderTicks = 0
    return bot.fleeFromBoss(bosses)

  let selected = nearestVisibleTarget(bot.lastVisibleObjects)

  if selected.found:
    let
      target = selected.obj
      targetWorld = bot.objectWorldCenter(target)
      targetTx = targetWorld.x div TileSize
      targetTy = targetWorld.y div TileSize
      targetCenterX = target.x + target.width div 2
      targetCenterY = target.y + target.height div 2
      dx = targetCenterX - PlayerCenterX
      dy = targetCenterY - PlayerCenterY
      aimMask = moveMaskForDirection(dx, dy)
      moveMask = bot.steerMask(aimMask, dx, dy)

    bot.setGoalPreview(targetWorld.x, targetWorld.y, "visible " & kindName(target.kind), moveMask)

    if target.kind in {BossKind, SnakeKind} and
        inAttackRange(target) and
        bot.inMeleeTileRange(targetTx, targetTy):
      bot.wanderTicks = 0
      if not bot.previousAttack:
        result = aimMask or ButtonA
        bot.intentLabel = "attack visible " & kindName(target.kind)
        bot.attackIntent = "swing now"
        bot.think("seeing " & kindName(target.kind) & " at (" & $targetTx & ", " & $targetTy & "), attacking")
        bot.previousAttack = true
      else:
        bot.intentLabel = "hold spacing on visible " & kindName(target.kind)
        bot.attackIntent = "attack ready after current swing"
        bot.think("holding position after swing, watching snake")
        bot.previousAttack = false
      return

    if moveMask != 0:
      bot.wanderTicks = 0
      result = moveMask
      bot.intentLabel = "move to visible " & kindName(target.kind)
      bot.attackIntent = "close distance"
      bot.think(
        "seeing " & kindName(target.kind) & " at (" & $targetTx & ", " & $targetTy &
        "), moving " & movementName(result)
      )
      bot.previousAttack = false
      return

    if aimMask != 0:
      result = bot.wanderMask()
      bot.setGoalPreview(targetWorld.x, targetWorld.y, "visible " & kindName(target.kind), result)
      bot.intentLabel = "slide around wall toward visible " & kindName(target.kind)
      bot.attackIntent = "wall in the way"
      bot.think(
        "seeing " & kindName(target.kind) & " at (" & $targetTx & ", " & $targetTy &
        "), wall ahead, sliding " & movementName(result)
      )
      if result != 0:
        bot.previousAttack = false
        return
    bot.previousAttack = false

  let rememberedTarget = bot.nearestRememberedTarget()
  if rememberedTarget.found:
    let
      targetTx = rememberedTarget.remembered.worldX div TileSize
      targetTy = rememberedTarget.remembered.worldY div TileSize
      dx = rememberedTarget.remembered.worldX - bot.playerWorldX
      dy = rememberedTarget.remembered.worldY - bot.playerWorldY
      desiredMask = moveMaskForDirection(dx, dy)
      moveMask = bot.steerMask(desiredMask, dx, dy)
    bot.setGoalPreview(
      rememberedTarget.remembered.worldX,
      rememberedTarget.remembered.worldY,
      "remembered " & kindName(rememberedTarget.remembered.kind),
      moveMask
    )
    if moveMask != 0:
      bot.wanderTicks = 0
      result = moveMask
      bot.intentLabel = "track remembered " & kindName(rememberedTarget.remembered.kind)
      bot.attackIntent = "reacquire target"
      bot.think(
        "tracking remembered " & kindName(rememberedTarget.remembered.kind) &
        " at (" & $targetTx & ", " & $targetTy & "), moving " & movementName(result)
      )
      bot.previousAttack = false
      return

  result = bot.wanderMask()
  if result != 0:
    bot.setGoalPreview(
      bot.playerWorldX,
      bot.playerWorldY,
      "explore nearby space",
      result
    )
    bot.intentLabel = "explore nearby space"
    bot.attackIntent = "no target in range"
    bot.think("mapping the world, exploring " & movementName(result))
  else:
    bot.clearGoal()
    bot.intentLabel = "hold position"
    bot.attackIntent = "boxed in by walls"
    bot.think("no open tile next to player right now")
  bot.previousAttack = false

proc sampleColor(index: uint8): ColorRGBX =
  if index == TransparentColorIndex:
    return rgbx(0, 0, 0, 0)
  Palette[index].rgbx

proc kindColor(kind: DetectedKind): ColorRGBX =
  case kind
  of BossKind: ViewerBoss
  of SnakeKind: ViewerSnake
  of CoinKind: ViewerCoin
  of HeartKind: ViewerHeart
  of WallKind: ViewerWall

proc inputMaskSummary(mask: uint8): string =
  var parts: seq[string] = @[]
  if (mask and ButtonUp) != 0: parts.add("up")
  if (mask and ButtonDown) != 0: parts.add("down")
  if (mask and ButtonLeft) != 0: parts.add("left")
  if (mask and ButtonRight) != 0: parts.add("right")
  if (mask and ButtonA) != 0: parts.add("attack")
  if (mask and ButtonB) != 0: parts.add("b")
  if (mask and ButtonSelect) != 0: parts.add("select")
  if parts.len == 0:
    return "idle"
  parts.join(", ")

proc mapPos(mapX, mapY, tileScale: float32, tx, ty: int): Vec2 =
  vec2(mapX + tx.float32 * tileScale, mapY + ty.float32 * tileScale)

proc drawOutline(sk: Silky, pos, size: Vec2, color: ColorRGBX, thickness = 1.0) =
  sk.drawRect(pos, vec2(size.x, thickness), color)
  sk.drawRect(vec2(pos.x, pos.y + size.y - thickness), vec2(size.x, thickness), color)
  sk.drawRect(pos, vec2(thickness, size.y), color)
  sk.drawRect(vec2(pos.x + size.x - thickness, pos.y), vec2(thickness, size.y), color)

proc drawFrameView(sk: Silky, bot: Bot, x, y: float32) =
  let
    pixelScale = ViewerFrameScale
    frameSize = vec2(ScreenWidth.float32 * pixelScale, ScreenHeight.float32 * pixelScale)
  sk.drawRect(vec2(x, y), frameSize, ViewerPanelAlt)
  for py in 0 ..< ScreenHeight:
    for px in 0 ..< ScreenWidth:
      let index = bot.unpacked[py * ScreenWidth + px]
      if index == TransparentColorIndex:
        continue
      sk.drawRect(
        vec2(x + px.float32 * pixelScale, y + py.float32 * pixelScale),
        vec2(pixelScale, pixelScale),
        sampleColor(index)
      )

  for wall in bot.lastVisibleWalls:
    let
      pos = vec2(x + wall.x.float32 * pixelScale, y + wall.y.float32 * pixelScale)
      size = vec2(wall.width.float32 * pixelScale, wall.height.float32 * pixelScale)
    sk.drawOutline(pos, size, ViewerWallBox, 2)

  for obj in bot.lastVisibleObjects:
    let
      pos = vec2(x + obj.x.float32 * pixelScale, y + obj.y.float32 * pixelScale)
      size = vec2(obj.width.float32 * pixelScale, obj.height.float32 * pixelScale)
    sk.drawOutline(pos, size, kindColor(obj.kind), 2)

  let
    attackRadius = vec2(18.0'f * pixelScale, 18.0'f * pixelScale)
    attackPos = vec2(
      x + (PlayerCenterX.float32 - 9.0'f) * pixelScale,
      y + (PlayerCenterY.float32 - 9.0'f) * pixelScale
    )
    playerPos = vec2(
      x + PlayerCenterX.float32 * pixelScale - 3,
      y + PlayerCenterY.float32 * pixelScale - 3
    )
    attackColor = if (bot.lastMask and ButtonA) != 0: ViewerGoal else: ViewerViewport
  sk.drawOutline(attackPos, attackRadius, attackColor, 2)
  sk.drawRect(playerPos, vec2(7, 7), ViewerPlayer)

proc knownBounds(bot: Bot): tuple[found: bool, minTx, minTy, maxTx, maxTy: int] =
  result.minTx = high(int)
  result.minTy = high(int)
  result.maxTx = low(int)
  result.maxTy = low(int)
  for ty in 0 ..< MapHeightTiles:
    for tx in 0 ..< MapWidthTiles:
      if bot.tileKnowledge(tx, ty) == TileUnknown:
        continue
      result.found = true
      if tx < result.minTx: result.minTx = tx
      if ty < result.minTy: result.minTy = ty
      if tx > result.maxTx: result.maxTx = tx
      if ty > result.maxTy: result.maxTy = ty

proc drawArrow(sk: Silky, fromPos, toPos: Vec2, color: ColorRGBX) =
  let
    dx = toPos.x - fromPos.x
    dy = toPos.y - fromPos.y
    length = sqrt(dx * dx + dy * dy)
  if length < 0.001:
    return
  let
    dirX = dx / length
    dirY = dy / length
    normalX = -dirY
    normalY = dirX
    tip = toPos
    base = vec2(toPos.x - dirX * 10, toPos.y - dirY * 10)
    left = vec2(base.x + normalX * 4, base.y + normalY * 4)
    right = vec2(base.x - normalX * 4, base.y - normalY * 4)
    segments = max(1, int(length / 10))
  for i in 0 ..< segments:
    let t = i.float32 / segments.float32
    sk.drawRect(
      vec2(fromPos.x + dx * t - 1, fromPos.y + dy * t - 1),
      vec2(3, 3),
      color
    )
  sk.drawTriangle(
    [tip, left, right],
    [vec2(8, 8), vec2(8, 8), vec2(8, 8)],
    [color, color, color]
  )

proc drawMapView(sk: Silky, bot: Bot, x, y: float32) =
  let
    tileScale = ViewerMapScale
    mapSize = vec2(MapWidthTiles.float32 * tileScale, MapHeightTiles.float32 * tileScale)
  sk.drawRect(vec2(x, y), mapSize, ViewerUnknown)

  for ty in 0 ..< MapHeightTiles:
    for tx in 0 ..< MapWidthTiles:
      let knowledge = bot.tileKnowledge(tx, ty)
      if knowledge == TileUnknown:
        continue
      let color =
        case knowledge
        of TileOpen: ViewerOpen
        of TileWall: ViewerWall
        of TileUnknown: ViewerUnknown
      sk.drawRect(mapPos(x, y, tileScale, tx, ty), vec2(tileScale, tileScale), color)
      if bot.hasUnknownNeighbor(tx, ty):
        sk.drawRect(mapPos(x, y, tileScale, tx, ty), vec2(tileScale, tileScale), ViewerFrontier)

  for remembered in bot.rememberedObjects:
    let
      tileX = remembered.worldX div TileSize
      tileY = remembered.worldY div TileSize
      markerPos = mapPos(x, y, tileScale, tileX, tileY)
    sk.drawRect(markerPos, vec2(max(2.0, tileScale), max(2.0, tileScale)), kindColor(remembered.kind))

  for obj in bot.lastVisibleObjects:
    let
      world = bot.objectWorldCenter(obj)
      tileX = world.x div TileSize
      tileY = world.y div TileSize
      markerPos = mapPos(x, y, tileScale, tileX, tileY)
      markerSize = vec2(max(4.0'f, tileScale + 2), max(4.0'f, tileScale + 2))
    sk.drawOutline(markerPos - vec2(1, 1), markerSize, ViewerText, 1)

  let
    playerMapX = x + (bot.playerWorldX.float32 / TileSize.float32) * tileScale
    playerMapY = y + (bot.playerWorldY.float32 / TileSize.float32) * tileScale
  sk.drawRect(vec2(playerMapX - 2, playerMapY - 2), vec2(5, 5), ViewerPlayer)

  if bot.hasNextStep:
    let
      stepPos = mapPos(x, y, tileScale, bot.goalNextTx, bot.goalNextTy)
      stepCenter = stepPos + vec2(tileScale * 0.5, tileScale * 0.5)
    sk.drawOutline(stepPos, vec2(tileScale, tileScale), ViewerGoal, 2)
    sk.drawArrow(vec2(playerMapX, playerMapY), stepCenter, ViewerGoal)

  if bot.hasGoal:
    let
      goalMapX = x + (bot.goalWorldX.float32 / TileSize.float32) * tileScale
      goalMapY = y + (bot.goalWorldY.float32 / TileSize.float32) * tileScale
    sk.drawRect(vec2(goalMapX - 3, goalMapY - 3), vec2(7, 7), ViewerGoal)

  let
    viewportX = x + (bot.cameraX().float32 / TileSize.float32) * tileScale
    viewportY = y + (bot.cameraY().float32 / TileSize.float32) * tileScale
    viewportW = ScreenWidth.float32 * tileScale / TileSize.float32
    viewportH = ScreenHeight.float32 * tileScale / TileSize.float32
  sk.drawOutline(vec2(viewportX, viewportY), vec2(viewportW, viewportH), ViewerViewport, 1)

  let bounds = bot.knownBounds()
  if bounds.found:
    let
      boundsPos = mapPos(x, y, tileScale, bounds.minTx, bounds.minTy)
      boundsSize = vec2(
        (bounds.maxTx - bounds.minTx + 1).float32 * tileScale,
        (bounds.maxTy - bounds.minTy + 1).float32 * tileScale
      )
    sk.drawOutline(boundsPos, boundsSize, ViewerRemembered, 1)

proc rememberedSummary(bot: Bot): string =
  var
    bosses = 0
    snakes = 0
    coins = 0
    hearts = 0
  for remembered in bot.rememberedObjects:
    case remembered.kind
    of BossKind: inc bosses
    of SnakeKind: inc snakes
    of CoinKind: inc coins
    of HeartKind: inc hearts
    of WallKind: discard
  "memory bosses=" & $bosses & " snakes=" & $snakes & " coins=" & $coins & " hearts=" & $hearts

proc visibleSummary(bot: Bot): string =
  var
    walls = 0
    bosses = 0
    snakes = 0
    coins = 0
    hearts = 0
  for obj in bot.lastVisibleObjects:
    case obj.kind
    of BossKind: inc bosses
    of SnakeKind: inc snakes
    of CoinKind: inc coins
    of HeartKind: inc hearts
    of WallKind: discard
  walls = bot.lastVisibleWalls.len
  "visible walls=" & $walls & " bosses=" & $bosses & " snakes=" & $snakes &
    " coins=" & $coins & " hearts=" & $hearts

proc terrainSummary(bot: Bot): string =
  var
    openTiles = 0
    wallTiles = 0
    frontierTiles = 0
  for ty in 0 ..< MapHeightTiles:
    for tx in 0 ..< MapWidthTiles:
      case bot.tileKnowledge(tx, ty)
      of TileUnknown:
        discard
      of TileOpen:
        inc openTiles
        if bot.hasUnknownNeighbor(tx, ty):
          inc frontierTiles
      of TileWall:
        inc wallTiles
        if bot.hasUnknownNeighbor(tx, ty):
          inc frontierTiles
  let knownTiles = openTiles + wallTiles
  "map known=" & $knownTiles & " open=" & $openTiles & " walls=" & $wallTiles &
    " edges=" & $frontierTiles

proc initViewerApp(): ViewerApp =
  result = ViewerApp()
  result.window = newWindow(
    title = "Big Adventure Viewer",
    size = ivec2(ViewerWindowWidth, ViewerWindowHeight),
    style = Decorated,
    visible = true
  )
  makeContextCurrent(result.window)
  when not defined(useDirectX):
    loadExtensions()
  result.silky = newSilky(result.window, atlasPath())

proc pumpViewer(
  viewer: ViewerApp,
  bot: Bot,
  connected: bool,
  url: string
) =
  if viewer.isNil:
    return

  pollEvents()
  if viewer.window.buttonPressed[KeyEscape]:
    viewer.window.closeRequested = true
  if viewer.window.closeRequested:
    return

  let
    frameSize = viewer.window.size
    sk = viewer.silky
    framePos = vec2(ViewerMargin, ViewerMargin + 28)
    mapPos = vec2(framePos.x + ScreenWidth.float32 * ViewerFrameScale + 24, ViewerMargin + 28)
    mapSize = vec2(MapWidthTiles.float32 * ViewerMapScale, MapHeightTiles.float32 * ViewerMapScale)
    infoPos = vec2(mapPos.x + mapSize.x + 24, ViewerMargin + 28)
    infoSize = vec2(frameSize.x.float32 - infoPos.x - ViewerMargin, frameSize.y.float32 - infoPos.y - ViewerMargin)

  sk.beginUI(viewer.window, frameSize)
  sk.clearScreen(ViewerBackground)

  discard sk.drawText(
    "Default",
    "Big Adventure Bot Viewer",
    vec2(ViewerMargin, ViewerMargin),
    ViewerText
  )
  discard sk.drawText("Default", "Live frame + attack box", vec2(framePos.x, framePos.y - 18), ViewerMutedText)
  discard sk.drawText("Default", "Remembered world + edges", vec2(mapPos.x, mapPos.y - 18), ViewerMutedText)
  discard sk.drawText("Default", "Intent + memory", vec2(infoPos.x, infoPos.y - 18), ViewerMutedText)

  sk.drawRect(framePos - vec2(8, 8), vec2(ScreenWidth.float32 * ViewerFrameScale + 16, ScreenHeight.float32 * ViewerFrameScale + 16), ViewerPanel)
  sk.drawRect(mapPos - vec2(8, 8), mapSize + vec2(16, 16), ViewerPanel)
  sk.drawRect(infoPos - vec2(8, 8), infoSize + vec2(16, 16), ViewerPanel)

  viewer.silky.drawFrameView(bot, framePos.x, framePos.y)
  viewer.silky.drawMapView(bot, mapPos.x, mapPos.y)

  let infoText =
    "status: " & (if connected: "connected" else: "reconnecting") & "\n" &
    "url: " & url & "\n" &
    "intent: " & (if bot.intentLabel.len > 0: bot.intentLabel else: "waiting for first frame") & "\n" &
    "attack: " & bot.attackIntent & "\n" &
    "next input: " & inputMaskSummary(bot.lastMask) & "\n" &
    "player tile: (" & $bot.playerTileX() & ", " & $bot.playerTileY() & ")\n" &
    "camera px: (" & $bot.cameraX() & ", " & $bot.cameraY() & ")\n" &
    "goal: " & (if bot.hasGoal: bot.goalLabel else: "none") & "\n" &
    (if bot.hasNextStep: "next step tile: (" & $bot.goalNextTx & ", " & $bot.goalNextTy & ")\n" else: "") &
    (if bot.hasGoal: "goal world: (" & $bot.goalWorldX & ", " & $bot.goalWorldY & ")\n" else: "") &
    visibleSummary(bot) & "\n" &
    terrainSummary(bot) & "\n" &
    rememberedSummary(bot) & "\n" &
    "last thought: " & (if bot.lastThought.len > 0: bot.lastThought else: "waiting for frame")

  discard sk.drawText(
    "Default",
    infoText,
    infoPos,
    ViewerText,
    infoSize.x,
    infoSize.y
  )

  let legendTop = infoPos.y + 250
  discard sk.drawText("Default", "Legend", vec2(infoPos.x, legendTop), ViewerMutedText)
  for index, item in [
    (ViewerWall, "known wall"),
    (ViewerFrontier, "possible edge / frontier"),
    (ViewerSnake, "snake memory"),
    (ViewerBoss, "boss memory"),
    (ViewerViewport, "camera / attack box"),
    (ViewerGoal, "goal + next-step arrow")
  ]:
    let rowY = legendTop + 22 + index.float32 * 22
    sk.drawRect(vec2(infoPos.x, rowY + 2), vec2(12, 12), item[0])
    discard sk.drawText("Default", item[1], vec2(infoPos.x + 18, rowY), ViewerText)

  sk.endUi()
  viewer.window.swapBuffers()

proc viewerOpen(viewer: ViewerApp): bool =
  viewer.isNil or not viewer.window.closeRequested

proc runBot(host = DefaultHost, port = PlayerDefaultPort, gui = false) =
  var bot = initBot()
  let url = "ws://" & host & ":" & $port & WebSocketPath
  var viewer =
    if gui: initViewerApp()
    else: nil
  var connected = false

  while viewer.viewerOpen():
    try:
      let ws = newWebSocket(url)
      bot.resetSession()
      var lastMask = 0xFF'u8
      connected = true
      echo "Connected to ", url

      while viewer.viewerOpen():
        if gui:
          viewer.pumpViewer(bot, connected, url)
          if not viewer.viewerOpen():
            ws.close()
            break

        let message = ws.receiveMessage(if gui: 10 else: -1)
        if message.isNone:
          continue

        case message.get.kind
        of BinaryMessage:
          if message.get.data.len != ProtocolBytes:
            continue
          blobToBytes(message.get.data, bot.packed)
          unpack4bpp(bot.packed, bot.unpacked)
          inc bot.frameTick
          if bot.isGameOverFrame():
            bot.think("game over detected, reconnecting")
            bot.resetSession()
            ws.close()
            break
          let nextMask = bot.decideNextMask()
          bot.lastMask = nextMask
          if nextMask != lastMask:
            ws.send(blobFromMask(nextMask), BinaryMessage)
            lastMask = nextMask
        of Ping:
          ws.send(message.get.data, Pong)
        of TextMessage, Pong:
          discard
    except Exception as e:
      connected = false
      echo "Bot reconnecting after error: ", e.msg
      if gui:
        let reconnectStart = getMonoTime()
        while viewer.viewerOpen() and (getMonoTime() - reconnectStart).inMilliseconds < 250:
          viewer.pumpViewer(bot, connected, url)
          sleep(10)
      else:
        sleep(250)

when isMainModule:
  var
    address = DefaultHost
    port = PlayerDefaultPort
    gui = false
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      of "gui": gui = true
      else: discard
    else: discard
  runBot(address, port, gui)

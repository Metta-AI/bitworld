import
  std/[heapqueue, options, os, parseopt, random, strutils, times],
  supersnappy, whisky,
  protocol, ../../sim

const
  PlayerDefaultPort = 2000
  PlayerSpriteSlots = 64
  SelectedPlayerSpriteSlots = 64
  SwooshSpriteSlots = 8
  TerrainSpriteSlots = 5
  MaxDrainMessages = 256
  PathCellSize = 8
  PathGridWidth = WorldWidthPixels div PathCellSize
  PathGridHeight = WorldHeightPixels div PathCellSize
  MoveDeadband = 5
  GoalArrivalRadius = 18
  AttackReach = 46
  AttackAlignSlack = 22
  AttackCooldownTicks = 7
  ObstaclePad = 8
  PathLookaheadCells = 4
  StuckFrameThreshold = 14
  JiggleDuration = 12
  SkipTargetTicks = 72
  ExploreStep = 17
  MoveMask = ButtonUp or ButtonDown or ButtonLeft or ButtonRight

type
  SpriteKind = enum
    SpriteUnknown
    SpriteMap
    SpritePlayer
    SpriteMob
    SpriteTroll
    SpriteBoss
    SpriteCoin
    SpriteHeart
    SpriteSwoosh
    SpriteTerrain
    SpriteHud
    SpriteText

  TargetKind = enum
    TargetExplore
    TargetCoin
    TargetHeart
    TargetMob
    TargetTroll
    TargetBoss

  SpriteInfo = object
    defined: bool
    width: int
    height: int
    label: string
    kind: SpriteKind
    pixels: seq[uint8]

  ObjectState = object
    present: bool
    x: int
    y: int
    z: int
    layer: int
    spriteId: int

  Target = object
    found: bool
    kind: TargetKind
    objectId: int
    x: int
    y: int
    label: string

  PathNode = object
    priority: int
    index: int

  PathStep = object
    found: bool
    nextTx: int
    nextTy: int

  Bot = object
    sprites: seq[SpriteInfo]
    objects: seq[ObjectState]
    rng: Rand
    cameraX: int
    cameraY: int
    playerWorldX: int
    playerWorldY: int
    playerCenterWorldX: int
    playerCenterWorldY: int
    previousPlayerX: int
    previousPlayerY: int
    havePlayerSample: bool
    selfObjectId: int
    frameTick: int
    exploreIndex: int
    hasExploreGoal: bool
    exploreX: int
    exploreY: int
    stuckFrames: int
    jiggleTicks: int
    jiggleMask: uint8
    attackCooldown: int
    currentTargetId: int
    currentTargetKind: TargetKind
    currentTargetX: int
    currentTargetY: int
    currentTargetDistance: int
    currentTargetLabel: string
    skipTargetId: int
    skipTicks: int
    coinCount: int
    heartCount: int
    killCount: int
    intent: string
    lastMask: uint8
    nextChatTick: int
    lastChat: string

proc `<`(a, b: PathNode): bool =
  ## Orders path nodes by priority for the heap.
  if a.priority == b.priority:
    return a.index < b.index
  a.priority < b.priority

proc gridIndex(tx, ty: int): int =
  ## Returns the flat path grid index.
  ty * PathGridWidth + tx

proc inGrid(tx, ty: int): bool =
  ## Returns true when a path cell coordinate is inside the world.
  tx >= 0 and ty >= 0 and tx < PathGridWidth and ty < PathGridHeight

proc distanceSquared(ax, ay, bx, by: int): int =
  ## Returns squared distance between two points.
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc manhattan(ax, ay, bx, by: int): int =
  ## Returns Manhattan distance between two points.
  abs(ax - bx) + abs(ay - by)

proc tileCenterX(tx: int): int =
  ## Returns the world X coordinate for the center of a path cell.
  tx * PathCellSize + PathCellSize div 2

proc tileCenterY(ty: int): int =
  ## Returns the world Y coordinate for the center of a path cell.
  ty * PathCellSize + PathCellSize div 2

proc clampTileX(x: int): int =
  ## Converts a world X coordinate into a clamped path cell coordinate.
  clamp(x div PathCellSize, 0, PathGridWidth - 1)

proc clampTileY(y: int): int =
  ## Converts a world Y coordinate into a clamped path cell coordinate.
  clamp(y div PathCellSize, 0, PathGridHeight - 1)

proc classifySprite(spriteId: int, label: string): SpriteKind =
  ## Classifies a sprite from its id and optional protocol label.
  let lower = label.toLowerAscii()
  if spriteId == MapSpriteId or lower == "map":
    SpriteMap
  elif spriteId >= PlayerSpriteBase and
      spriteId < PlayerSpriteBase + PlayerSpriteSlots:
    SpritePlayer
  elif spriteId >= SelectedPlayerSpriteBase and
      spriteId < SelectedPlayerSpriteBase + SelectedPlayerSpriteSlots:
    SpritePlayer
  elif spriteId == MobSpriteId or lower.startsWith("ghost"):
    SpriteMob
  elif spriteId == TrollSpriteId or lower.startsWith("troll"):
    SpriteTroll
  elif spriteId == BossSpriteId or lower.startsWith("pigman"):
    SpriteBoss
  elif spriteId == CoinSpriteId or lower == "coin":
    SpriteCoin
  elif spriteId == HeartSpriteId or lower == "heart":
    SpriteHeart
  elif spriteId >= SwooshSpriteBase and
      spriteId < SwooshSpriteBase + SwooshSpriteSlots:
    SpriteSwoosh
  elif spriteId >= TerrainSpriteBase and
      spriteId < TerrainSpriteBase + TerrainSpriteSlots:
    SpriteTerrain
  elif spriteId == PlayerHudSpriteId:
    SpriteHud
  elif label.len > 0:
    SpriteText
  else:
    SpriteUnknown

proc targetKindForSprite(kind: SpriteKind): TargetKind =
  ## Converts a monster sprite kind into a target kind.
  case kind
  of SpriteTroll:
    TargetTroll
  of SpriteBoss:
    TargetBoss
  else:
    TargetMob

proc targetLabel(kind: TargetKind): string =
  ## Returns a short readable label for one target kind.
  case kind
  of TargetExplore:
    "explore"
  of TargetCoin:
    "coin"
  of TargetHeart:
    "heart"
  of TargetMob:
    "hunt"
  of TargetTroll:
    "fight"
  of TargetBoss:
    "boss"

proc ensureSprite(bot: var Bot, spriteId: int) =
  ## Ensures the sprite table can hold a sprite id.
  if spriteId >= bot.sprites.len:
    bot.sprites.setLen(spriteId + 1)

proc ensureObject(bot: var Bot, objectId: int) =
  ## Ensures the object table can hold an object id.
  if objectId >= bot.objects.len:
    bot.objects.setLen(objectId + 1)

proc spriteInfo(bot: Bot, spriteId: int): SpriteInfo =
  ## Returns sprite metadata or an empty sprite info.
  if spriteId >= 0 and spriteId < bot.sprites.len:
    return bot.sprites[spriteId]
  SpriteInfo()

proc readU16(blob: string, offset: int): int =
  ## Reads one little endian unsigned 16 bit value.
  int(uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8))

proc readI16(blob: string, offset: int): int =
  ## Reads one little endian signed 16 bit value.
  let value = uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc readU32(blob: string, offset: int): int =
  ## Reads one little endian unsigned 32 bit value.
  int(uint32(blob[offset].uint8) or
    (uint32(blob[offset + 1].uint8) shl 8) or
    (uint32(blob[offset + 2].uint8) shl 16) or
    (uint32(blob[offset + 3].uint8) shl 24))

proc applySpritePacket(bot: var Bot, packet: string): bool =
  ## Applies one or more server sprite protocol messages.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset].uint8
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        return false
      let
        spriteId = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10
      if compressedLen < 0 or offset + compressedLen + 2 > packet.len:
        return false
      let compressed =
        if compressedLen > 0:
          packet.substr(offset, offset + compressedLen - 1)
        else:
          ""
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len:
        return false
      let label =
        if labelLen > 0:
          packet.substr(offset, offset + labelLen - 1)
        else:
          ""
      offset += labelLen
      let rawPixels = supersnappy.uncompress(compressed)
      var pixels = newSeq[uint8](rawPixels.len)
      for i, ch in rawPixels:
        pixels[i] = ch.uint8
      if pixels.len != width * height * 4:
        pixels.setLen(0)
      bot.ensureSprite(spriteId)
      bot.sprites[spriteId] = SpriteInfo(
        defined: true,
        width: width,
        height: height,
        label: label,
        kind: classifySprite(spriteId, label),
        pixels: pixels
      )
    of 0x02:
      if offset + 11 > packet.len:
        return false
      let
        objectId = packet.readU16(offset)
        x = packet.readI16(offset + 2)
        y = packet.readI16(offset + 4)
        z = packet.readI16(offset + 6)
        layer = int(packet[offset + 8].uint8)
        spriteId = packet.readU16(offset + 9)
      offset += 11
      bot.ensureObject(objectId)
      bot.objects[objectId] = ObjectState(
        present: true,
        x: x,
        y: y,
        z: z,
        layer: layer,
        spriteId: spriteId
      )
    of 0x03:
      if offset + 2 > packet.len:
        return false
      let objectId = packet.readU16(offset)
      offset += 2
      if objectId >= 0 and objectId < bot.objects.len:
        bot.objects[objectId].present = false
    of 0x04:
      for item in bot.objects.mitems:
        item.present = false
    of 0x05:
      if offset + 5 > packet.len:
        return false
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return false
      offset += 3
    else:
      return false
  true

proc updateCamera(bot: var Bot) =
  ## Updates the world camera from the map object.
  if MapObjectId < bot.objects.len and bot.objects[MapObjectId].present:
    bot.cameraX = -bot.objects[MapObjectId].x
    bot.cameraY = -bot.objects[MapObjectId].y

proc visibleBounds(sprite: SpriteInfo): SpriteBounds =
  ## Measures the visible bounds of one decoded RGBA sprite.
  if sprite.width <= 0 or sprite.height <= 0 or
      sprite.pixels.len != sprite.width * sprite.height * 4:
    return SpriteBounds(x: 0, y: 0, w: sprite.width, h: sprite.height)

  var
    minX = sprite.width
    minY = sprite.height
    maxX = -1
    maxY = -1
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let offset = (y * sprite.width + x) * 4 + 3
      if sprite.pixels[offset] == 0'u8:
        continue
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
  if maxX < minX or maxY < minY:
    return SpriteBounds()
  SpriteBounds(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1)

proc lowerCenterBounds(bounds: SpriteBounds): SpriteBounds =
  ## Returns the lower trunk-like part of a visible sprite.
  if bounds.w <= 0 or bounds.h <= 0:
    return bounds
  let
    width = max(6, bounds.w div 3)
    height = max(6, bounds.h div 4)
  SpriteBounds(
    x: bounds.x + (bounds.w - width) div 2,
    y: bounds.y + bounds.h - height,
    w: width,
    h: height
  )

proc terrainBounds(sprite: SpriteInfo): SpriteBounds =
  ## Returns a collision-like terrain bound from true sprite pixels.
  let bounds = sprite.visibleBounds()
  let lower = sprite.label.toLowerAscii()
  if lower == "terraintree" or lower == "terrainevergreen":
    return bounds.lowerCenterBounds()
  bounds

proc objectVisibleCenter(
  objectState: ObjectState,
  sprite: SpriteInfo
): tuple[x: int, y: int] =
  ## Returns the visible center of one object in screen coordinates.
  let bounds = sprite.visibleBounds()
  (
    x: objectState.x + bounds.x + bounds.w div 2,
    y: objectState.y + bounds.y + bounds.h div 2
  )

proc objectFootCenter(
  objectState: ObjectState,
  sprite: SpriteInfo
): tuple[x: int, y: int] =
  ## Returns the foot box center of one player in screen coordinates.
  let bounds = sprite.visibleBounds()
  (
    x: objectState.x + bounds.x + bounds.w div 2,
    y: objectState.y + bounds.y + bounds.h - PlayerFootSize div 2
  )

proc updatePlayerPosition(bot: var Bot) =
  ## Tracks the local player feet as the object nearest screen center.
  var
    bestDistance = high(int)
    bestX = bot.cameraX + ScreenWidth div 2
    bestY = bot.cameraY + ScreenHeight div 2
    bestCenterX = bestX
    bestCenterY = bestY
    bestId = -1
  for objectId in 0 ..< bot.objects.len:
    let objectState = bot.objects[objectId]
    if not objectState.present:
      continue
    if objectId < PlayerObjectBase or objectId >= MobObjectBase:
      continue
    let sprite = bot.spriteInfo(objectState.spriteId)
    if sprite.kind != SpritePlayer:
      continue
    let
      screenCenter = objectState.objectVisibleCenter(sprite)
      screenFeet = objectState.objectFootCenter(sprite)
      distance = distanceSquared(
        screenCenter.x,
        screenCenter.y,
        ScreenWidth div 2,
        ScreenHeight div 2
      )
    if distance < bestDistance:
      bestDistance = distance
      bestX = bot.cameraX + screenFeet.x
      bestY = bot.cameraY + screenFeet.y
      bestCenterX = bot.cameraX + screenCenter.x
      bestCenterY = bot.cameraY + screenCenter.y
      bestId = objectId
  bot.playerWorldX = bestX
  bot.playerWorldY = bestY
  bot.playerCenterWorldX = bestCenterX
  bot.playerCenterWorldY = bestCenterY
  bot.selfObjectId = bestId

proc isBlocked(blocked: openArray[bool], tx, ty: int): bool =
  ## Returns true when a tile cannot be used for pathing.
  if not inGrid(tx, ty):
    return true
  blocked[gridIndex(tx, ty)]

proc resetBlocked(blocked: var seq[bool]) =
  ## Clears the blocked tile grid.
  if blocked.len != PathGridWidth * PathGridHeight:
    blocked.setLen(PathGridWidth * PathGridHeight)
  for i in 0 ..< blocked.len:
    blocked[i] = false

proc markBlocked(blocked: var seq[bool], x, y, w, h: int) =
  ## Marks all path cells overlapped by a world rectangle.
  if w <= 0 or h <= 0:
    return
  let
    minTx = clampTileX(max(0, x - ObstaclePad))
    minTy = clampTileY(max(0, y - ObstaclePad))
    maxTx = clampTileX(min(WorldWidthPixels - 1, x + w + ObstaclePad - 1))
    maxTy = clampTileY(min(WorldHeightPixels - 1, y + h + ObstaclePad - 1))
  for ty in minTy .. maxTy:
    for tx in minTx .. maxTx:
      blocked[gridIndex(tx, ty)] = true

proc targetCenter(
  bot: Bot,
  objectState: ObjectState,
  sprite: SpriteInfo
): tuple[x: int, y: int] =
  ## Converts an object visible center into world coordinates.
  let bounds = sprite.visibleBounds()
  (
    x: bot.cameraX + objectState.x + bounds.x + bounds.w div 2,
    y: bot.cameraY + objectState.y + bounds.y + bounds.h div 2
  )

proc scanWorld(
  bot: Bot,
  blocked: var seq[bool],
  pickups: var seq[Target],
  mobs: var seq[Target]
) =
  ## Extracts terrain, pickups, and monsters from protocol objects.
  blocked.resetBlocked()
  pickups.setLen(0)
  mobs.setLen(0)
  for objectId in 0 ..< bot.objects.len:
    let objectState = bot.objects[objectId]
    if not objectState.present:
      continue
    let sprite = bot.spriteInfo(objectState.spriteId)
    if not sprite.defined:
      continue
    case sprite.kind
    of SpriteTerrain:
      let bounds = sprite.terrainBounds()
      blocked.markBlocked(
        bot.cameraX + objectState.x + bounds.x,
        bot.cameraY + objectState.y + bounds.y,
        bounds.w,
        bounds.h
      )
    of SpriteCoin:
      let center = bot.targetCenter(objectState, sprite)
      pickups.add(Target(
        found: true,
        kind: TargetCoin,
        objectId: objectId,
        x: center.x,
        y: center.y,
        label: TargetCoin.targetLabel()
      ))
    of SpriteHeart:
      let center = bot.targetCenter(objectState, sprite)
      pickups.add(Target(
        found: true,
        kind: TargetHeart,
        objectId: objectId,
        x: center.x,
        y: center.y,
        label: TargetHeart.targetLabel()
      ))
    of SpriteMob, SpriteTroll, SpriteBoss:
      let
        kind = targetKindForSprite(sprite.kind)
        center = bot.targetCenter(objectState, sprite)
      mobs.add(Target(
        found: true,
        kind: kind,
        objectId: objectId,
        x: center.x,
        y: center.y,
        label: kind.targetLabel()
      ))
    else:
      discard

proc nearestOpenTile(
  blocked: openArray[bool],
  tx,
  ty: int
): tuple[found: bool, tx: int, ty: int] =
  ## Finds the nearest pathable tile around a requested tile.
  if inGrid(tx, ty) and not blocked.isBlocked(tx, ty):
    return (true, tx, ty)
  for radius in 1 .. 6:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if abs(dx) != radius and abs(dy) != radius:
          continue
        let
          nx = tx + dx
          ny = ty + dy
        if inGrid(nx, ny) and not blocked.isBlocked(nx, ny):
          return (true, nx, ny)
  (false, tx, ty)

proc heuristicDistance(ax, ay, bx, by: int): int =
  ## Returns the A-star tile heuristic.
  abs(ax - bx) + abs(ay - by)

proc reconstructStep(
  parents: openArray[int],
  startIndex,
  goalIndex: int
): PathStep =
  ## Reconstructs a short lookahead step from a parent grid.
  var path: seq[int] = @[goalIndex]
  while path[^1] != startIndex:
    let nextIndex = parents[path[^1]]
    if nextIndex < 0 or nextIndex == path[^1]:
      return
    path.add(nextIndex)
  let stepIndex = path[max(0, path.high - PathLookaheadCells)]
  PathStep(
    found: true,
    nextTx: stepIndex mod PathGridWidth,
    nextTy: stepIndex div PathGridWidth
  )

proc findPathStep(
  blocked: openArray[bool],
  startX,
  startY,
  goalX,
  goalY: int
): PathStep =
  ## Finds the first pathing tile toward a world goal.
  let
    startTx = clampTileX(startX)
    startTy = clampTileY(startY)
    openGoal = blocked.nearestOpenTile(clampTileX(goalX), clampTileY(goalY))
  if not openGoal.found:
    return
  let
    goalTx = openGoal.tx
    goalTy = openGoal.ty
    startIndex = gridIndex(startTx, startTy)
    goalIndex = gridIndex(goalTx, goalTy)
    area = PathGridWidth * PathGridHeight
  if startTx == goalTx and startTy == goalTy:
    return PathStep(found: true, nextTx: startTx, nextTy: startTy)

  var
    parents = newSeq[int](area)
    costs = newSeq[int](area)
    closed = newSeq[bool](area)
    openSet: HeapQueue[PathNode]
  for i in 0 ..< area:
    parents[i] = -2
    costs[i] = high(int)

  parents[startIndex] = startIndex
  costs[startIndex] = 0
  openSet.push(PathNode(
    priority: heuristicDistance(startTx, startTy, goalTx, goalTy),
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
      tx = current.index mod PathGridWidth
      ty = current.index div PathGridWidth
    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nextTx = tx + delta[0]
        nextTy = ty + delta[1]
      if not inGrid(nextTx, nextTy):
        continue
      if blocked.isBlocked(nextTx, nextTy):
        continue
      let nextIndex = gridIndex(nextTx, nextTy)
      if closed[nextIndex]:
        continue
      let tentative = costs[current.index] + 1
      if tentative >= costs[nextIndex]:
        continue
      costs[nextIndex] = tentative
      parents[nextIndex] = current.index
      openSet.push(PathNode(
        priority: tentative +
          heuristicDistance(nextTx, nextTy, goalTx, goalTy),
        index: nextIndex
      ))

proc randomMoveMask(rng: var Rand): uint8 =
  ## Chooses a short random movement mask.
  case rng.rand(3)
  of 0:
    ButtonUp
  of 1:
    ButtonDown
  of 2:
    ButtonLeft
  else:
    ButtonRight

proc updateStuck(bot: var Bot) =
  ## Updates stuck detection using the previous movement mask.
  if not bot.havePlayerSample:
    bot.previousPlayerX = bot.playerWorldX
    bot.previousPlayerY = bot.playerWorldY
    bot.havePlayerSample = true
    return

  let moved = distanceSquared(
    bot.playerWorldX,
    bot.playerWorldY,
    bot.previousPlayerX,
    bot.previousPlayerY
  )
  if (bot.lastMask and MoveMask) != 0 and moved <= 1:
    inc bot.stuckFrames
  else:
    bot.stuckFrames = 0
  bot.previousPlayerX = bot.playerWorldX
  bot.previousPlayerY = bot.playerWorldY

  if bot.stuckFrames >= StuckFrameThreshold:
    bot.jiggleTicks = JiggleDuration
    bot.jiggleMask = bot.rng.randomMoveMask()
    if bot.currentTargetId >= 0:
      bot.skipTargetId = bot.currentTargetId
      bot.skipTicks = SkipTargetTicks
    bot.stuckFrames = 0
    bot.hasExploreGoal = false

proc targetScore(bot: Bot, target: Target): int =
  ## Scores a target where lower is better.
  let distance = manhattan(
    bot.playerWorldX,
    bot.playerWorldY,
    target.x,
    target.y
  )
  case target.kind
  of TargetCoin:
    distance
  of TargetHeart:
    distance + 35
  of TargetMob:
    distance + (if distance < 90: -95 else: 130)
  of TargetTroll:
    distance + (if distance < 105: -85 else: 155)
  of TargetBoss:
    distance + (if distance < 120: -70 else: 220)
  of TargetExplore:
    distance + 400

proc refreshExploreGoal(bot: var Bot, blocked: openArray[bool]) =
  ## Picks a new open tile to sweep the map.
  if bot.hasExploreGoal and
      distanceSquared(
        bot.playerWorldX,
        bot.playerWorldY,
        bot.exploreX,
        bot.exploreY
      ) > GoalArrivalRadius * GoalArrivalRadius:
    return

  let area = PathGridWidth * PathGridHeight
  for attempt in 0 ..< area:
    let
      index = (bot.exploreIndex + attempt * ExploreStep) mod area
      tx = index mod PathGridWidth
      ty = index div PathGridWidth
    if blocked.isBlocked(tx, ty):
      continue
    bot.exploreIndex = (index + ExploreStep) mod area
    bot.exploreX = tileCenterX(tx)
    bot.exploreY = tileCenterY(ty)
    bot.hasExploreGoal = true
    return

  bot.exploreX = WorldWidthPixels div 2
  bot.exploreY = WorldHeightPixels div 2
  bot.hasExploreGoal = true

proc chooseTarget(
  bot: var Bot,
  blocked: openArray[bool],
  pickups,
  mobs: openArray[Target]
): Target =
  ## Chooses the next pickup, monster, or exploration target.
  var bestScore = high(int)
  for pickup in pickups:
    if bot.skipTicks > 0 and pickup.objectId == bot.skipTargetId:
      continue
    let score = bot.targetScore(pickup)
    if score < bestScore:
      bestScore = score
      result = pickup
  for mob in mobs:
    if bot.skipTicks > 0 and mob.objectId == bot.skipTargetId:
      continue
    let score = bot.targetScore(mob)
    if score < bestScore:
      bestScore = score
      result = mob
  if result.found:
    return

  bot.refreshExploreGoal(blocked)
  result = Target(
    found: true,
    kind: TargetExplore,
    objectId: -1,
    x: bot.exploreX,
    y: bot.exploreY,
    label: TargetExplore.targetLabel()
  )

proc nearestMob(bot: Bot, mobs: openArray[Target]): Target =
  ## Finds the nearest monster target.
  var bestDistance = high(int)
  for mob in mobs:
    let distance = distanceSquared(
      bot.playerWorldX,
      bot.playerWorldY,
      mob.x,
      mob.y
    )
    if distance < bestDistance:
      bestDistance = distance
      result = mob

proc containsTarget(targets: openArray[Target], objectId: int): bool =
  ## Returns true when a target id is still visible.
  for target in targets:
    if target.objectId == objectId:
      return true

proc rememberTarget(bot: var Bot, target: Target) =
  ## Stores the active target for debug and stuck recovery.
  bot.currentTargetId = target.objectId
  bot.currentTargetKind = target.kind
  bot.currentTargetX = target.x
  bot.currentTargetY = target.y
  bot.currentTargetLabel = target.label
  bot.currentTargetDistance = manhattan(
    bot.playerWorldX,
    bot.playerWorldY,
    target.x,
    target.y
  )

proc updateTargetResult(
  bot: var Bot,
  pickups,
  mobs: openArray[Target]
) =
  ## Infers successful pickups and kills from target disappearance.
  if bot.currentTargetId < 0:
    return
  let stillPresent =
    case bot.currentTargetKind
    of TargetCoin, TargetHeart:
      pickups.containsTarget(bot.currentTargetId)
    of TargetMob, TargetTroll, TargetBoss:
      mobs.containsTarget(bot.currentTargetId)
    of TargetExplore:
      true
  if stillPresent:
    return
  case bot.currentTargetKind
  of TargetCoin:
    if bot.currentTargetDistance < 64:
      inc bot.coinCount
      echo "coin collected id=", bot.currentTargetId,
        " total=", bot.coinCount
  of TargetHeart:
    if bot.currentTargetDistance < 64:
      inc bot.heartCount
      echo "heart collected id=", bot.currentTargetId,
        " total=", bot.heartCount
  of TargetMob, TargetTroll, TargetBoss:
    if bot.currentTargetDistance < 96:
      inc bot.killCount
      echo "monster down id=", bot.currentTargetId,
        " total=", bot.killCount
  of TargetExplore:
    discard
  bot.currentTargetId = -1

proc faceMask(dx, dy: int): uint8 =
  ## Returns a direction mask that faces a target point.
  if abs(dx) > abs(dy):
    if dx < 0:
      ButtonLeft
    else:
      ButtonRight
  else:
    if dy < 0:
      ButtonUp
    else:
      ButtonDown

proc steerMask(bot: Bot, x, y: int): uint8 =
  ## Builds movement buttons to steer toward a world point.
  let
    dx = x - bot.playerWorldX
    dy = y - bot.playerWorldY
  if abs(dx) > MoveDeadband:
    if dx < 0:
      result = result or ButtonLeft
    else:
      result = result or ButtonRight
  if abs(dy) > MoveDeadband:
    if dy < 0:
      result = result or ButtonUp
    else:
      result = result or ButtonDown

proc canAttack(bot: Bot, target: Target): bool =
  ## Returns true when a target is close enough for a swing.
  let
    dx = target.x - bot.playerCenterWorldX
    dy = target.y - bot.playerCenterWorldY
  (abs(dx) <= AttackReach and abs(dy) <= AttackAlignSlack) or
    (abs(dy) <= AttackReach and abs(dx) <= AttackAlignSlack)

proc attackMask(bot: var Bot, target: Target): uint8 =
  ## Builds a facing and attack pulse toward a monster.
  result = faceMask(
    target.x - bot.playerCenterWorldX,
    target.y - bot.playerCenterWorldY
  )
  if bot.attackCooldown == 0:
    result = result or ButtonA
    bot.attackCooldown = AttackCooldownTicks

proc decideNextMask(bot: var Bot): uint8 =
  ## Chooses the next controller mask from sprite protocol state.
  bot.updateCamera()
  bot.updatePlayerPosition()
  if bot.attackCooldown > 0:
    dec bot.attackCooldown
  if bot.skipTicks > 0:
    dec bot.skipTicks
    if bot.skipTicks == 0:
      bot.skipTargetId = -1

  var
    blocked: seq[bool]
    pickups: seq[Target]
    mobs: seq[Target]
  bot.scanWorld(blocked, pickups, mobs)
  bot.updateTargetResult(pickups, mobs)
  bot.updateStuck()

  if bot.jiggleTicks > 0:
    dec bot.jiggleTicks
    bot.intent = "unstuck"
    return bot.jiggleMask

  let closeMob = bot.nearestMob(mobs)
  if closeMob.found and bot.canAttack(closeMob):
    bot.rememberTarget(closeMob)
    bot.intent = closeMob.label
    return bot.attackMask(closeMob)

  let target = bot.chooseTarget(blocked, pickups, mobs)
  bot.rememberTarget(target)
  bot.intent = target.label
  if target.kind in {TargetMob, TargetTroll, TargetBoss} and
      bot.canAttack(target):
    return bot.attackMask(target)

  let step = findPathStep(
    blocked,
    bot.playerWorldX,
    bot.playerWorldY,
    target.x,
    target.y
  )
  if step.found:
    let
      startTx = clampTileX(bot.playerWorldX)
      startTy = clampTileY(bot.playerWorldY)
    if step.nextTx == startTx and step.nextTy == startTy:
      return bot.steerMask(target.x, target.y)
    return bot.steerMask(tileCenterX(step.nextTx), tileCenterY(step.nextTy))

  if target.objectId >= 0:
    bot.skipTargetId = target.objectId
    bot.skipTicks = SkipTargetTicks
  bot.hasExploreGoal = false
  bot.steerMask(target.x, target.y)

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc playerInputBlob(mask: uint8): string =
  ## Builds a sprite protocol player input packet.
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

proc maskSummary(mask: uint8): string =
  ## Returns a compact debug string for pressed keys.
  if (mask and ButtonUp) != 0:
    result.add("U")
  if (mask and ButtonDown) != 0:
    result.add("D")
  if (mask and ButtonLeft) != 0:
    result.add("L")
  if (mask and ButtonRight) != 0:
    result.add("R")
  if (mask and ButtonA) != 0:
    result.add("A")
  if (mask and ButtonB) != 0:
    result.add("B")
  if result.len == 0:
    result = "."

proc echoDebug(bot: Bot, mask: uint8, force = false) =
  ## Prints one useful navigation debug line.
  if not force and bot.frameTick mod 24 != 0:
    return
  echo "step=", bot.frameTick,
    " keys=", mask.maskSummary(),
    " pos=", bot.playerWorldX, ",", bot.playerWorldY,
    " intent=", bot.intent,
    " target=", bot.currentTargetLabel,
    "#", bot.currentTargetId,
    "@", bot.currentTargetX, ",", bot.currentTargetY,
    " d=", bot.currentTargetDistance,
    " coins=", bot.coinCount,
    " hearts=", bot.heartCount,
    " kills=", bot.killCount

proc chatBlob(text: string): string =
  ## Builds a sprite protocol text input packet.
  var bytes: seq[uint8] = @[0x81'u8]
  bytes.addU16(text.len)
  for ch in text:
    bytes.add(uint8(ord(ch)))
  blobFromBytes(bytes)

proc queryEscape(value: string): string =
  ## Escapes a query string component.
  const Hex = "0123456789ABCDEF"
  for ch in value:
    if ch.isAlphaNumeric() or ch in {'-', '_', '.', '~'}:
      result.add(ch)
    else:
      let byte = ord(ch)
      result.add('%')
      result.add(Hex[(byte shr 4) and 0x0f])
      result.add(Hex[byte and 0x0f])

proc initBot(): Bot =
  ## Builds the initial bot state.
  result.rng = initRand(getTime().toUnix() xor int64(getCurrentProcessId()))
  result.selfObjectId = -1
  result.currentTargetId = -1
  result.skipTargetId = -1
  result.exploreIndex = result.rng.rand(
    PathGridWidth * PathGridHeight - 1
  )
  result.nextChatTick = 72

proc acceptServerMessage(
  ws: WebSocket,
  message: Message,
  bot: var Bot
): bool =
  ## Handles one websocket message and updates sprite state.
  case message.kind
  of BinaryMessage:
    result = bot.applySpritePacket(message.data)
    if result:
      inc bot.frameTick
  of Ping:
    ws.send(message.data, Pong)
  of TextMessage, Pong:
    discard

proc receiveUpdates(ws: WebSocket, bot: var Bot): bool =
  ## Receives and applies all queued sprite protocol updates.
  let firstMessage = ws.receiveMessage(-1)
  if firstMessage.isNone:
    return false
  if ws.acceptServerMessage(firstMessage.get, bot):
    result = true
  var drained = 0
  while drained < MaxDrainMessages:
    let message = ws.receiveMessage(0)
    if message.isNone:
      break
    if ws.acceptServerMessage(message.get, bot):
      result = true
    inc drained

proc nextChat(bot: var Bot): string =
  ## Returns an optional short status chat message.
  if bot.frameTick < bot.nextChatTick:
    return ""
  bot.nextChatTick = bot.frameTick + 144
  result = bot.intent.toUpperAscii()
  if result.len == 0 or result == bot.lastChat:
    return ""
  bot.lastChat = result

proc runBot(
  host = DefaultHost,
  port = PlayerDefaultPort,
  name = "konrad",
  chat = false,
  maxSteps = 0
) =
  ## Connects to the Party Progressor player endpoint.
  let url =
    if name.len > 0:
      "ws://" & host & ":" & $port & WebSocketPath &
        "?name=" & name.queryEscape()
    else:
      "ws://" & host & ":" & $port & WebSocketPath

  while true:
    try:
      var bot = initBot()
      let ws = newWebSocket(url)
      var lastMask = 0xff'u8
      while true:
        if not ws.receiveUpdates(bot):
          continue
        let nextMask = bot.decideNextMask()
        bot.echoDebug(nextMask, nextMask != lastMask)
        bot.lastMask = nextMask
        if nextMask != lastMask:
          ws.send(playerInputBlob(nextMask), BinaryMessage)
          lastMask = nextMask
        if chat:
          let text = bot.nextChat()
          if text.len > 0:
            ws.send(chatBlob(text), BinaryMessage)
        if maxSteps > 0 and bot.frameTick >= maxSteps:
          bot.echoDebug(nextMask, true)
          echo "done steps=", bot.frameTick,
            " coins=", bot.coinCount,
            " hearts=", bot.heartCount,
            " kills=", bot.killCount
          ws.close()
          return
    except CatchableError:
      sleep(250)

when isMainModule:
  var
    address = DefaultHost
    port = PlayerDefaultPort
    name = "konrad"
    chat = false
    maxSteps = 0
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "port":
        port = parseInt(val)
      of "name":
        name = val
      of "chat":
        chat = true
      of "max-steps":
        maxSteps = parseInt(val)
      else:
        discard
    else:
      discard
  runBot(address, port, name, chat, maxSteps)

import
  std/[options, os, parseopt, strutils],
  whisky,
  protocol,
  pathfinding

# ---------------------------------------------------------------------------
# Stag Hunt constants (mirrored from stag_hunt/stag_hunt.nim; not imported to
# avoid pulling the server's mummy/sprite-cache machinery into the bot).
# ---------------------------------------------------------------------------

const
  CoordinatorDefaultPort = DefaultPort
  CoordinatorWebSocketPath = "/player"
  MaxDrainMessages = 256

  TargetFps = 24
  WorldWidthTiles = 32
  WorldHeightTiles = 32
  StagTileSize = 12   # stag_hunt overrides the protocol's 6 px tile
  WorldWidthPixels = WorldWidthTiles * StagTileSize
  WorldHeightPixels = WorldHeightTiles * StagTileSize
  PlayerViewportWidth = ScreenWidth
  PlayerViewportHeight = ScreenHeight

  # Sprite ids.
  TreeSpriteId = 1
  RockSpriteId = 2
  BackgroundSpriteId = 3
  PreySpriteBase = 10            # + kind ord (Rabbit..Elephant = 0..4)
  PreySpriteCount = 5
  PlayerSpriteBase = 100         # + colorSlot * 4 + facing.ord (0..31)
  PlayerSpriteCount = 32

  # Object id bases.
  TileObjectBase = 1000          # + tileIndex
  PlayerObjectBase = 5000        # + array index
  BackgroundObjectBase = 8000    # + tileIndex
  PreyObjectBase = 10000         # + array index

  MaxPlayers = 64                # generous upper bound for object scan
  MaxPrey = 64                   # generous upper bound for object scan

  IndicatorObjectBase = 9000
  IndicatorSpriteBase = 20

  # Strategy tuning.
  AllyChebyshevRadius = 6        # "nearby" allies counted within this radius
  PreferredReachChebyshev = 12   # prefer big prey only within this radius
  DebugIntervalTicks = TargetFps # one debug line per second

type
  PreyKind = enum
    Rabbit
    Boar
    Stag
    Moose
    Elephant

  SpriteKind = enum
    SpriteUnknown
    SpriteBackground
    SpriteTree
    SpriteRock
    SpritePrey
    SpritePlayer
    SpriteIndicator

  SpriteInfo = object
    defined: bool
    width: int
    height: int
    label: string
    kind: SpriteKind
    preyKind: PreyKind
    colorSlot: int
    facing: int

  ObjectState = object
    present: bool
    x: int
    y: int
    z: int
    layer: int
    spriteId: int

  PlayerSight = object
    found: bool
    objectId: int
    tileX: int
    tileY: int
    pixelX: int
    pixelY: int

  PreySight = object
    found: bool
    objectId: int
    kind: PreyKind
    tileX: int
    tileY: int

  Bot = object
    sprites: seq[SpriteInfo]
    objects: seq[ObjectState]
    cameraX: int
    cameraY: int
    cameraKnown: bool
    frameTick: int
    selfObjectId: int
    selfTileX: int
    selfTileY: int
    selfFound: bool
    intent: string
    obstacleMap: ObstacleMap
    # Anti-stuck / cycle detection state
    posHistory: array[4, tuple[x, y: int]]
    posHistoryIdx: int
    posHistoryCount: int
    stuckCount: int
    lastSentNonZero: bool
    # Adjacent-wait state
    adjacentWaitTicks: int
    lastAdjacentPreyId: int

# ---------------------------------------------------------------------------
# Sprite_v1 protocol parsing (mirrors skurge.nim closely).
# ---------------------------------------------------------------------------

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

proc ensureSprite(bot: var Bot, spriteId: int) =
  ## Grows the sprite table so it can hold one sprite id.
  if spriteId >= bot.sprites.len:
    bot.sprites.setLen(spriteId + 1)

proc ensureObject(bot: var Bot, objectId: int) =
  ## Grows the object table so it can hold one object id.
  if objectId >= bot.objects.len:
    bot.objects.setLen(objectId + 1)

proc classifySprite(spriteId: int, label: string): SpriteInfo =
  ## Classifies one stag_hunt sprite id by its number and label.
  result.kind = SpriteUnknown
  if spriteId == BackgroundSpriteId:
    result.kind = SpriteBackground
    return
  if spriteId == TreeSpriteId:
    result.kind = SpriteTree
    return
  if spriteId == RockSpriteId:
    result.kind = SpriteRock
    return
  if spriteId >= PreySpriteBase and
      spriteId < PreySpriteBase + PreySpriteCount:
    result.kind = SpritePrey
    result.preyKind = PreyKind(spriteId - PreySpriteBase)
    return
  if spriteId >= PlayerSpriteBase and
      spriteId < PlayerSpriteBase + PlayerSpriteCount:
    let offset = spriteId - PlayerSpriteBase
    result.kind = SpritePlayer
    result.colorSlot = offset div 4
    result.facing = offset mod 4
    return
  if spriteId >= IndicatorSpriteBase and spriteId < IndicatorSpriteBase + 3:
    result.kind = SpriteIndicator
    return
  discard label

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
      # Skip pixel data; the bot only uses sprite metadata, not pixels.
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
      var info = classifySprite(spriteId, label)
      info.defined = true
      info.width = width
      info.height = height
      info.label = label
      bot.ensureSprite(spriteId)
      bot.sprites[spriteId] = info
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
      bot.cameraKnown = false
      bot.selfFound = false
      bot.selfObjectId = -1
    of 0x05:
      if offset + 5 > packet.len:
        return false
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return false
      offset += 3
    of 0x07:
      # Server-assigned identity: u16 selfObjectId.
      if offset + 2 > packet.len:
        return false
      bot.selfObjectId = packet.readU16(offset)
      offset += 2
    else:
      return false
  true

# ---------------------------------------------------------------------------
# Camera derivation and scene queries.
# ---------------------------------------------------------------------------

proc spriteInfo(bot: Bot, spriteId: int): SpriteInfo =
  ## Returns sprite metadata or a blank record.
  if spriteId >= 0 and spriteId < bot.sprites.len:
    return bot.sprites[spriteId]
  SpriteInfo()

proc objectPresent(bot: Bot, objectId: int): bool =
  objectId >= 0 and objectId < bot.objects.len and bot.objects[objectId].present

proc deriveCamera(bot: var Bot) =
  ## Derives the world camera offset from any visible background tile.
  bot.cameraKnown = false
  let scanEnd = min(bot.objects.len, BackgroundObjectBase +
    WorldWidthTiles * WorldHeightTiles)
  for objectId in BackgroundObjectBase ..< scanEnd:
    if not bot.objects[objectId].present:
      continue
    let
      tileIndex = objectId - BackgroundObjectBase
      tx = tileIndex mod WorldWidthTiles
      ty = tileIndex div WorldWidthTiles
      obj = bot.objects[objectId]
    bot.cameraX = tx * StagTileSize - obj.x
    bot.cameraY = ty * StagTileSize - obj.y
    bot.cameraKnown = true
    return

proc chebyshev(ax, ay, bx, by: int): int =
  ## Returns the chebyshev (king-move) distance between two tile coords.
  max(abs(ax - bx), abs(ay - by))

proc visiblePlayers(bot: Bot): seq[PlayerSight] =
  ## Returns every player object currently visible.
  let scanEnd = min(bot.objects.len, PlayerObjectBase + MaxPlayers)
  for objectId in PlayerObjectBase ..< scanEnd:
    if not bot.objects[objectId].present:
      continue
    let obj = bot.objects[objectId]
    let info = bot.spriteInfo(obj.spriteId)
    if info.kind != SpritePlayer:
      continue
    let
      worldX = bot.cameraX + obj.x
      worldY = bot.cameraY + obj.y
    result.add PlayerSight(
      found: true,
      objectId: objectId,
      tileX: worldX div StagTileSize,
      tileY: worldY div StagTileSize,
      pixelX: worldX,
      pixelY: worldY
    )

proc visiblePrey(bot: Bot): seq[PreySight] =
  ## Returns every prey object currently visible.
  let scanEnd = min(bot.objects.len, PreyObjectBase + MaxPrey)
  for objectId in PreyObjectBase ..< scanEnd:
    if not bot.objects[objectId].present:
      continue
    let obj = bot.objects[objectId]
    let info = bot.spriteInfo(obj.spriteId)
    if info.kind != SpritePrey:
      continue
    let
      worldX = bot.cameraX + obj.x
      worldY = bot.cameraY + obj.y
    result.add PreySight(
      found: true,
      objectId: objectId,
      kind: info.preyKind,
      tileX: worldX div StagTileSize,
      tileY: worldY div StagTileSize
    )

proc findSelf(bot: var Bot, players: openArray[PlayerSight]) =
  ## Looks up the bot's own player via the server-supplied identity packet
  ## (0x07). The server tells us our own object id each frame; we just match
  ## it against the visible PlayerSights.
  bot.selfFound = false
  if bot.selfObjectId < 0:
    return
  for player in players:
    if player.objectId == bot.selfObjectId:
      bot.selfTileX = player.tileX
      bot.selfTileY = player.tileY
      bot.selfFound = true
      return

# ---------------------------------------------------------------------------
# Strategy: pick prey our local coalition can plausibly catch.
# ---------------------------------------------------------------------------

proc preyMinPlayers(kind: PreyKind): int =
  ## Mirrors stag_hunt.nim preyMinPlayers.
  case kind
  of Rabbit: 1
  of Boar: 2
  of Stag: 2
  of Moose: 3
  of Elephant: 4

proc preyReward(kind: PreyKind): int =
  ## Mirrors the score rewards in stag_hunt.nim; bigger is better.
  case kind
  of Rabbit: 1
  of Boar: 3
  of Stag: 5
  of Moose: 10
  of Elephant: 18

proc nearbyAllyCount(
  bot: Bot,
  players: openArray[PlayerSight]
): int =
  ## Counts self plus other visible players within AllyChebyshevRadius.
  if not bot.selfFound:
    return 0
  result = 1
  for player in players:
    if player.tileX == bot.selfTileX and player.tileY == bot.selfTileY:
      continue
    if chebyshev(player.tileX, player.tileY,
        bot.selfTileX, bot.selfTileY) <= AllyChebyshevRadius:
      inc result

proc catchableKinds(nearbyCount: int): set[PreyKind] =
  ## Returns the set of prey kinds catchable with the given coalition size.
  for kind in PreyKind:
    if preyMinPlayers(kind) <= nearbyCount:
      result.incl(kind)

proc kindsLabel(kinds: set[PreyKind]): string =
  ## Returns a comma-separated kind list for debug output.
  for kind in PreyKind:
    if kind in kinds:
      if result.len > 0:
        result.add(',')
      result.add($kind)
  if result.len == 0:
    result = "none"

proc chooseTarget(
  bot: Bot,
  prey: openArray[PreySight],
  kinds: set[PreyKind]
): PreySight =
  ## Picks the best prey: prefer the highest-reward kind within reasonable
  ## reach, breaking ties by chebyshev distance; otherwise the nearest of
  ## any catchable kind.
  if not bot.selfFound:
    return PreySight()

  var
    nearbyBest = PreySight()
    nearbyBestReward = -1
    nearbyBestDist = high(int)
    fallbackBest = PreySight()
    fallbackBestDist = high(int)

  for p in prey:
    if p.kind notin kinds:
      continue
    let d = chebyshev(p.tileX, p.tileY, bot.selfTileX, bot.selfTileY)
    if d < fallbackBestDist or
        (d == fallbackBestDist and preyReward(p.kind) >
          preyReward(fallbackBest.kind)):
      fallbackBest = p
      fallbackBestDist = d
    if d <= PreferredReachChebyshev:
      let reward = preyReward(p.kind)
      if reward > nearbyBestReward or
          (reward == nearbyBestReward and d < nearbyBestDist):
        nearbyBest = p
        nearbyBestReward = reward
        nearbyBestDist = d

  if nearbyBest.found:
    return nearbyBest
  fallbackBest

proc cardinallyAdjacent(ax, ay, bx, by: int): bool =
  ## Returns true when (ax,ay) is exactly one step N/S/E/W from (bx,by).
  let dx = abs(ax - bx)
  let dy = abs(ay - by)
  (dx == 1 and dy == 0) or (dx == 0 and dy == 1)

type
  OccupiedSides = object
    n, s, e, w: bool

proc occupiedSidesOf(
  preyX, preyY: int,
  players: openArray[PlayerSight]
): OccupiedSides =
  for player in players:
    if player.tileX == preyX and player.tileY == preyY - 1:
      result.n = true
    elif player.tileX == preyX and player.tileY == preyY + 1:
      result.s = true
    elif player.tileX == preyX + 1 and player.tileY == preyY:
      result.e = true
    elif player.tileX == preyX - 1 and player.tileY == preyY:
      result.w = true

proc bestCaptureSide(
  selfX, selfY, preyX, preyY: int,
  kind: PreyKind,
  players: openArray[PlayerSight]
): tuple[x, y: int, found: bool] =
  let sides = occupiedSidesOf(preyX, preyY, players)
  let selfIsN = (selfX == preyX and selfY == preyY - 1)
  let selfIsS = (selfX == preyX and selfY == preyY + 1)
  let selfIsE = (selfX == preyX + 1 and selfY == preyY)
  let selfIsW = (selfX == preyX - 1 and selfY == preyY)
  case kind
  of Stag:
    if sides.n and not sides.s and not selfIsN:
      return (preyX, preyY + 1, true)
    if sides.s and not sides.n and not selfIsS:
      return (preyX, preyY - 1, true)
    if sides.e and not sides.w and not selfIsE:
      return (preyX - 1, preyY, true)
    if sides.w and not sides.e and not selfIsW:
      return (preyX + 1, preyY, true)
    if selfIsN and not sides.s:
      return (preyX, preyY + 1, true)
    if selfIsS and not sides.n:
      return (preyX, preyY - 1, true)
    if selfIsE and not sides.w:
      return (preyX - 1, preyY, true)
    if selfIsW and not sides.e:
      return (preyX + 1, preyY, true)
  of Boar:
    if (sides.n or selfIsN) and not sides.e and not selfIsE:
      return (preyX + 1, preyY, true)
    if (sides.n or selfIsN) and not sides.w and not selfIsW:
      return (preyX - 1, preyY, true)
    if (sides.s or selfIsS) and not sides.e and not selfIsE:
      return (preyX + 1, preyY, true)
    if (sides.s or selfIsS) and not sides.w and not selfIsW:
      return (preyX - 1, preyY, true)
    if (sides.e or selfIsE) and not sides.n and not selfIsN:
      return (preyX, preyY - 1, true)
    if (sides.e or selfIsE) and not sides.s and not selfIsS:
      return (preyX, preyY + 1, true)
    if (sides.w or selfIsW) and not sides.n and not selfIsN:
      return (preyX, preyY - 1, true)
    if (sides.w or selfIsW) and not sides.s and not selfIsS:
      return (preyX, preyY + 1, true)
  of Moose, Elephant:
    if not sides.n and not selfIsN:
      return (preyX, preyY - 1, true)
    if not sides.s and not selfIsS:
      return (preyX, preyY + 1, true)
    if not sides.e and not selfIsE:
      return (preyX + 1, preyY, true)
    if not sides.w and not selfIsW:
      return (preyX - 1, preyY, true)
  of Rabbit:
    discard
  (0, 0, false)

proc updateStuckState(bot: var Bot, mask: uint8) =
  ## Updates stuck/cycle detection state based on current position.
  if not bot.selfFound:
    return
  # Record position changes into ring buffer
  let lastIdx = (bot.posHistoryIdx + bot.posHistoryCount - 1 + 4) mod 4
  let posChanged = bot.posHistoryCount == 0 or
    bot.selfTileX != bot.posHistory[lastIdx].x or
    bot.selfTileY != bot.posHistory[lastIdx].y
  if posChanged:
    bot.posHistory[bot.posHistoryIdx] = (bot.selfTileX, bot.selfTileY)
    bot.posHistoryIdx = (bot.posHistoryIdx + 1) mod 4
    if bot.posHistoryCount < 4:
      inc bot.posHistoryCount
    bot.stuckCount = 0
  elif mask != 0:
    inc bot.stuckCount
  bot.lastSentNonZero = mask != 0

proc updateObstacleMap(bot: var Bot) =
  if not bot.cameraKnown: return
  let scanEnd = min(bot.objects.len, BackgroundObjectBase + WorldWidthTiles * WorldHeightTiles)
  for objectId in BackgroundObjectBase ..< scanEnd:
    if not bot.objects[objectId].present: continue
    let
      tileIndex = objectId - BackgroundObjectBase
      tx = tileIndex mod WorldWidthTiles
      ty = tileIndex div WorldWidthTiles
      obj = bot.objects[objectId]
      info = bot.spriteInfo(obj.spriteId)
    if not info.defined: continue
    case info.kind
    of SpriteTree, SpriteRock:
      bot.obstacleMap.markTile(tx, ty, TileBlocked)
    of SpriteBackground:
      bot.obstacleMap.markTile(tx, ty, TileClear)
    else:
      discard

proc navigate(bot: var Bot, targetX, targetY: int): uint8 =
  if bot.stuckCount >= 15:
    let mask = unstickStep(bot.obstacleMap, bot.selfTileX, bot.selfTileY, bot.frameTick)
    bot.updateStuckState(mask)
    return mask
  let mask = pathStep(bot.obstacleMap, bot.selfTileX, bot.selfTileY, targetX, targetY)
  bot.updateStuckState(mask)
  mask

proc findKillSpot(bot: Bot): tuple[x, y: int, found: bool] =
  const IndicatorTileOffset = (StagTileSize - 4) div 2
  for preyIdx in 0 ..< MaxPrey:
    for sideOrd in 0 ..< 4:
      let objectId = IndicatorObjectBase + preyIdx * 4 + sideOrd
      if not bot.objectPresent(objectId): continue
      let
        obj = bot.objects[objectId]
        info = bot.spriteInfo(obj.spriteId)
      if not info.defined or info.kind != SpriteIndicator: continue
      if obj.spriteId != IndicatorSpriteBase: continue  # only 1-dot
      let
        worldX = bot.cameraX + obj.x - IndicatorTileOffset
        worldY = bot.cameraY + obj.y - IndicatorTileOffset
        tileX = worldX div StagTileSize
        tileY = worldY div StagTileSize
        dx = abs(bot.selfTileX - tileX)
        dy = abs(bot.selfTileY - tileY)
      if (dx + dy) <= 2:
        return (tileX, tileY, true)
  (0, 0, false)

proc decideNextMask(bot: var Bot): uint8 =
  ## Chooses the next controller mask from the current sprite scene.
  bot.deriveCamera()
  if not bot.cameraKnown:
    bot.intent = "no camera"
    return 0

  let players = bot.visiblePlayers()
  bot.findSelf(players)
  if not bot.selfFound:
    bot.intent = "no self"
    return 0
  bot.updateObstacleMap()

  # Priority 1: kill spot
  let killSpot = bot.findKillSpot()
  if killSpot.found:
    bot.intent = "kill spot at (" & $killSpot.x & "," & $killSpot.y & ")"
    if bot.selfTileX == killSpot.x and bot.selfTileY == killSpot.y:
      bot.updateStuckState(0)
      return 0
    return bot.navigate(killSpot.x, killSpot.y)

  let
    prey = bot.visiblePrey()
    nearby = bot.nearbyAllyCount(players)
    kinds = catchableKinds(nearby)
    target = bot.chooseTarget(prey, kinds)

  if not target.found:
    bot.intent = "no catchable prey (allies=" & $nearby & ") exploring"
    return bot.navigate(MapWidth div 2, MapHeight div 2)

  # Adjacent — hold or reposition to capture side
  if cardinallyAdjacent(bot.selfTileX, bot.selfTileY, target.tileX, target.tileY):
    if bot.lastAdjacentPreyId == target.objectId:
      inc bot.adjacentWaitTicks
    else:
      bot.lastAdjacentPreyId = target.objectId
      bot.adjacentWaitTicks = 1
    if bot.adjacentWaitTicks >= 12 and target.kind != Rabbit:
      let side = bestCaptureSide(
        bot.selfTileX, bot.selfTileY,
        target.tileX, target.tileY,
        target.kind, players
      )
      if side.found:
        bot.intent = "reposition->capture " & $target.kind &
          " side=(" & $side.x & "," & $side.y & ")" &
          " allies=" & $nearby & " wait=" & $bot.adjacentWaitTicks
        return bot.navigate(side.x, side.y)
    bot.intent = "hold beside " & $target.kind & " allies=" & $nearby
    bot.updateStuckState(0)
    return 0
  else:
    bot.adjacentWaitTicks = 0
    bot.lastAdjacentPreyId = -1

  # Strategic positioning for multi-player prey within close range
  let dist = abs(bot.selfTileX - target.tileX) + abs(bot.selfTileY - target.tileY)
  if target.kind != Rabbit and dist <= 4:
    let side = bestCaptureSide(
      bot.selfTileX, bot.selfTileY,
      target.tileX, target.tileY,
      target.kind, players
    )
    if side.found:
      bot.intent = "approach->capture " & $target.kind &
        " side=(" & $side.x & "," & $side.y & ") allies=" & $nearby
      return bot.navigate(side.x, side.y)

  bot.intent = "approach " & $target.kind &
    " at (" & $target.tileX & "," & $target.tileY & ")" &
    " allies=" & $nearby
  bot.navigate(target.tileX, target.tileY)

# ---------------------------------------------------------------------------
# Debug logging and IO helpers.
# ---------------------------------------------------------------------------

proc maskSummary(mask: uint8): string =
  ## Returns a compact human-readable input mask.
  if (mask and ButtonUp) != 0: result.add("U")
  if (mask and ButtonDown) != 0: result.add("D")
  if (mask and ButtonLeft) != 0: result.add("L")
  if (mask and ButtonRight) != 0: result.add("R")
  if (mask and ButtonA) != 0: result.add("A")
  if (mask and ButtonB) != 0: result.add("B")
  if result.len == 0: result = "."

proc echoDebug(bot: Bot, mask: uint8, force = false) =
  ## Prints occasional bot status for local tuning.
  if not force and bot.frameTick mod DebugIntervalTicks != 0:
    return
  let players = bot.visiblePlayers()
  let prey = bot.visiblePrey()
  let nearby =
    if bot.selfFound: bot.nearbyAllyCount(players)
    else: 0
  let kinds = catchableKinds(nearby)
  let target = bot.chooseTarget(prey, kinds)
  let selfStr =
    if bot.selfFound:
      "(" & $bot.selfTileX & "," & $bot.selfTileY & ")"
    else:
      "?"
  var targetStr = "none"
  var distStr = "-"
  if target.found and bot.selfFound:
    targetStr = $target.kind & "@(" & $target.tileX & "," & $target.tileY & ")"
    distStr = $chebyshev(
      bot.selfTileX, bot.selfTileY, target.tileX, target.tileY)
  echo "step=", bot.frameTick,
    " self=", selfStr,
    " nearby=", nearby,
    " catchable=", kindsLabel(kinds),
    " target=", targetStr,
    " dist=", distStr,
    " keys=", mask.maskSummary(),
    " intent=", bot.intent

proc playerInputBlob(mask: uint8): string =
  ## Builds a sprite_v1 controller input packet.
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

# ---------------------------------------------------------------------------
# Websocket connection and main loop.
# ---------------------------------------------------------------------------

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

proc withPath(url, path: string): string =
  ## Adds a websocket path when the supplied URL has no path.
  let schemePos = url.find("://")
  if schemePos < 0:
    return url
  let pathStart = url.find('/', schemePos + 3)
  if pathStart >= 0:
    return url
  url & path

proc addQueryParam(url, key, value: string): string =
  ## Appends one escaped query parameter to a URL.
  if value.len == 0:
    return url
  result = url
  if '?' in result:
    result.add('&')
  else:
    result.add('?')
  result.add(key)
  result.add('=')
  result.add(value.queryEscape())

proc connectUrl(address, url, name: string, port: int): string =
  ## Builds the player websocket URL.
  if url.len > 0:
    result = url.withPath(CoordinatorWebSocketPath)
  else:
    result = "ws://" & address & ":" & $port & CoordinatorWebSocketPath
  result = result.addQueryParam("name", name)

proc initBot(): Bot =
  result.selfFound = false
  result.cameraKnown = false
  result.selfObjectId = -1
  result.posHistoryIdx = 0
  result.posHistoryCount = 0
  result.stuckCount = 0
  result.lastSentNonZero = false
  result.adjacentWaitTicks = 0
  result.lastAdjacentPreyId = -1

proc acceptServerMessage(
  ws: WebSocket,
  message: Message,
  bot: var Bot
): bool =
  ## Handles one websocket message from the game server.
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
  ## Receives and applies all currently queued sprite updates.
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

proc runBot(
  address = DefaultHost,
  port = CoordinatorDefaultPort,
  url = "",
  name = "coordinator"
) =
  ## Connects coordinator to Stag Hunt and runs the coalition policy.
  let endpoint = connectUrl(address, url, name, port)
  while true:
    try:
      echo "coordinator connecting to ", endpoint
      var bot = initBot()
      let ws = newWebSocket(endpoint)
      var lastMask = 0xff'u8
      while true:
        if not ws.receiveUpdates(bot):
          continue
        let mask = bot.decideNextMask()
        bot.echoDebug(mask, mask != lastMask)
        if mask != lastMask:
          ws.send(playerInputBlob(mask), BinaryMessage)
          lastMask = mask
    except CatchableError as e:
      echo "coordinator reconnecting after error: ", e.msg
      sleep(250)

when isMainModule:
  var
    address = DefaultHost
    port = CoordinatorDefaultPort
    url = ""
    name = "coordinator"

  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = value
      of "port": port = parseInt(value)
      of "url": url = value
      of "name": name = value
      else:
        raise newException(ValueError, "Unknown option: --" & key)
    of cmdArgument, cmdShortOption:
      raise newException(ValueError, "Unexpected argument: " & key)
    of cmdEnd:
      discard

  runBot(address, port, url, name)

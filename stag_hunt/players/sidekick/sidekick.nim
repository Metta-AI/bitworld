import
  std/[options, os, parseopt, strutils],
  whisky,
  protocol,
  pathfinding

const
  StagTileSize = 12
  TargetFps = 24
  WorldWidthTiles = 32
  WorldHeightTiles = 32
  PlayerViewportWidth = ScreenWidth
  PlayerViewportHeight = ScreenHeight

  BackgroundSpriteId = 3
  TreeSpriteId = 1
  RockSpriteId = 2
  PreySpriteBase = 10
  PlayerSpriteBase = 100
  PlayerSpriteEnd = PlayerSpriteBase + 8 * 4

  PlayerObjectBase = 5000
  BackgroundObjectBase = 8000
  PreyObjectBase = 10000

  MaxPlayerSlots = 64
  MaxPreySlots = 256
  MaxBackgroundIndex = WorldWidthTiles * WorldHeightTiles

  IndicatorObjectBase = 9000
  IndicatorSpriteBase = 20
  MaxPreyCount = 64
  MaxDrainMessages = 256
  ConnectRetryDelayMs = 250
  WebSocketPath = "/player"

  FollowDistance = 1
  StillFramesThreshold = 25  # 5 steps * 5 frames/step = 25 frames

type
  TrackedPlayer = object
    objectId: int
    lastTileX: int
    lastTileY: int
    stillFrames: int
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

  ObjectState = object
    present: bool
    x: int
    y: int
    spriteId: int

  PreySight = object
    found: bool
    objectId: int
    kind: PreyKind
    tileX: int
    tileY: int

  PlayerSight = object
    found: bool
    objectId: int
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
    haveSelf: bool
    lastMask: uint8
    posHistory: array[4, tuple[x, y: int]]
    posHistoryIdx: int
    posHistoryCount: int
    stuckCount: int
    lastSentNonZero: bool
    obstacleMap: ObstacleMap
    priorityList: seq[TrackedPlayer]
    followTarget: int  # objectId of currently-followed player, -1 if none

proc readU16(blob: string, offset: int): int =
  int(uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8))

proc readI16(blob: string, offset: int): int =
  let value = uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc readU32(blob: string, offset: int): int =
  int(uint32(blob[offset].uint8) or
    (uint32(blob[offset + 1].uint8) shl 8) or
    (uint32(blob[offset + 2].uint8) shl 16) or
    (uint32(blob[offset + 3].uint8) shl 24))

proc ensureSprite(bot: var Bot, spriteId: int) =
  if spriteId >= bot.sprites.len:
    bot.sprites.setLen(spriteId + 1)

proc ensureObject(bot: var Bot, objectId: int) =
  if objectId >= bot.objects.len:
    bot.objects.setLen(objectId + 1)

proc classifySprite(spriteId: int): SpriteKind =
  if spriteId == BackgroundSpriteId:
    return SpriteBackground
  if spriteId == TreeSpriteId:
    return SpriteTree
  if spriteId == RockSpriteId:
    return SpriteRock
  if spriteId >= PreySpriteBase and spriteId < PreySpriteBase + 5:
    return SpritePrey
  if spriteId >= PlayerSpriteBase and spriteId < PlayerSpriteEnd:
    return SpritePlayer
  if spriteId >= IndicatorSpriteBase and spriteId < IndicatorSpriteBase + 3:
    return SpriteIndicator
  SpriteUnknown

proc applySpritePacket(bot: var Bot, packet: string): bool =
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
      bot.ensureSprite(spriteId)
      bot.sprites[spriteId] = SpriteInfo(
        defined: true,
        width: width,
        height: height,
        label: label,
        kind: classifySprite(spriteId)
      )
    of 0x02:
      if offset + 11 > packet.len:
        return false
      let
        objectId = packet.readU16(offset)
        x = packet.readI16(offset + 2)
        y = packet.readI16(offset + 4)
        spriteId = packet.readU16(offset + 9)
      offset += 11
      bot.ensureObject(objectId)
      bot.objects[objectId] = ObjectState(
        present: true,
        x: x,
        y: y,
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
      bot.haveSelf = false
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
      if offset + 2 > packet.len:
        return false
      bot.selfObjectId = packet.readU16(offset)
      offset += 2
    else:
      return false
  true

proc spriteInfo(bot: Bot, spriteId: int): SpriteInfo =
  if spriteId >= 0 and spriteId < bot.sprites.len:
    return bot.sprites[spriteId]
  SpriteInfo()

proc objectPresent(bot: Bot, objectId: int): bool =
  objectId >= 0 and objectId < bot.objects.len and bot.objects[objectId].present

proc updateCamera(bot: var Bot) =
  bot.cameraKnown = false
  for i in 0 ..< MaxBackgroundIndex:
    let objectId = BackgroundObjectBase + i
    if not bot.objectPresent(objectId):
      continue
    let
      state = bot.objects[objectId]
      tx = i mod WorldWidthTiles
      ty = i div WorldWidthTiles
    bot.cameraX = tx * StagTileSize - state.x
    bot.cameraY = ty * StagTileSize - state.y
    bot.cameraKnown = true
    return

proc visiblePlayers(bot: Bot): seq[PlayerSight] =
  for i in 0 ..< MaxPlayerSlots:
    let objectId = PlayerObjectBase + i
    if not bot.objectPresent(objectId):
      continue
    let
      state = bot.objects[objectId]
      sprite = bot.spriteInfo(state.spriteId)
    if not sprite.defined or sprite.kind != SpritePlayer:
      continue
    let
      worldX = bot.cameraX + state.x
      worldY = bot.cameraY + state.y
      tileX = worldX div StagTileSize
      tileY = worldY div StagTileSize
    result.add(PlayerSight(
      found: true,
      objectId: objectId,
      tileX: tileX,
      tileY: tileY
    ))

proc visiblePrey(bot: Bot): seq[PreySight] =
  for i in 0 ..< MaxPreySlots:
    let objectId = PreyObjectBase + i
    if not bot.objectPresent(objectId):
      continue
    let
      state = bot.objects[objectId]
      sprite = bot.spriteInfo(state.spriteId)
    if not sprite.defined or sprite.kind != SpritePrey:
      continue
    let
      worldX = bot.cameraX + state.x
      worldY = bot.cameraY + state.y
      tileX = (worldX + StagTileSize div 2) div StagTileSize
      tileY = (worldY + StagTileSize div 2) div StagTileSize
      kindOrd = state.spriteId - PreySpriteBase
      preyKind = if kindOrd >= 0 and kindOrd <= 4: PreyKind(kindOrd) else: Rabbit
    result.add(PreySight(
      found: true,
      objectId: objectId,
      kind: preyKind,
      tileX: tileX,
      tileY: tileY
    ))

proc identifySelf(bot: var Bot, players: openArray[PlayerSight]) =
  bot.haveSelf = false
  if bot.selfObjectId < 0:
    return
  for p in players:
    if p.objectId == bot.selfObjectId:
      bot.haveSelf = true
      bot.selfTileX = p.tileX
      bot.selfTileY = p.tileY
      return

proc isCardinallyAdjacent(ax, ay, bx, by: int): bool =
  let dx = abs(ax - bx)
  let dy = abs(ay - by)
  (dx == 1 and dy == 0) or (dx == 0 and dy == 1)

proc updateStuckState(bot: var Bot, mask: uint8) =
  if not bot.haveSelf:
    return
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
  for i in 0 ..< MaxBackgroundIndex:
    let objectId = BackgroundObjectBase + i
    if not bot.objectPresent(objectId): continue
    let
      state = bot.objects[objectId]
      sprite = bot.spriteInfo(state.spriteId)
      tx = i mod WorldWidthTiles
      ty = i div WorldWidthTiles
    if not sprite.defined: continue
    case sprite.kind
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
  const IndicatorTileOffset = (12 - 4) div 2
  for preyIdx in 0 ..< MaxPreyCount:
    for sideOrd in 0 ..< 4:
      let objectId = IndicatorObjectBase + preyIdx * 4 + sideOrd
      if not bot.objectPresent(objectId): continue
      let state = bot.objects[objectId]
      let sprite = bot.spriteInfo(state.spriteId)
      if not sprite.defined or sprite.kind != SpriteIndicator: continue
      if state.spriteId != IndicatorSpriteBase: continue
      let
        worldX = bot.cameraX + state.x - IndicatorTileOffset
        worldY = bot.cameraY + state.y - IndicatorTileOffset
        tileX = worldX div 12
        tileY = worldY div 12
        dx = abs(bot.selfTileX - tileX)
        dy = abs(bot.selfTileY - tileY)
      if (dx + dy) <= 2:
        return (tileX, tileY, true)
  (0, 0, false)

proc findTrackedIndex(bot: Bot, objectId: int): int =
  for i in 0 ..< bot.priorityList.len:
    if bot.priorityList[i].objectId == objectId:
      return i
  -1

proc updatePriorityList(bot: var Bot, players: openArray[PlayerSight]) =
  ## Update tracked players with current positions, add new ones at bottom,
  ## and demote players who have been still too long.

  # Update existing tracked players and add new ones
  for p in players:
    if p.objectId == bot.selfObjectId:
      continue
    let idx = bot.findTrackedIndex(p.objectId)
    if idx < 0:
      # New player — add at bottom of priority list
      bot.priorityList.add(TrackedPlayer(
        objectId: p.objectId,
        lastTileX: p.tileX,
        lastTileY: p.tileY,
        stillFrames: 0
      ))
    else:
      # Existing player — check if they moved
      if bot.priorityList[idx].lastTileX != p.tileX or
         bot.priorityList[idx].lastTileY != p.tileY:
        bot.priorityList[idx].lastTileX = p.tileX
        bot.priorityList[idx].lastTileY = p.tileY
        bot.priorityList[idx].stillFrames = 0
      else:
        inc bot.priorityList[idx].stillFrames

  # Demote players who have been still for too long
  var i = 0
  while i < bot.priorityList.len:
    if bot.priorityList[i].stillFrames >= StillFramesThreshold:
      # Demote to bottom: remove and re-add at end with reset counter
      var demoted = bot.priorityList[i]
      demoted.stillFrames = 0
      bot.priorityList.delete(i)
      bot.priorityList.add(demoted)
      # If we were following this player, clear followTarget so we pick next
      if bot.followTarget == demoted.objectId:
        bot.followTarget = -1
      # Don't increment i since we deleted at i
    else:
      inc i

proc bestFollowTarget(bot: var Bot, players: openArray[PlayerSight]): PlayerSight =
  ## Pick the highest-priority visible player to follow.
  # Build set of currently visible objectIds (excluding self)
  for tracked in bot.priorityList:
    if tracked.objectId == bot.selfObjectId:
      continue
    # Check if this tracked player is currently visible
    for p in players:
      if p.objectId == tracked.objectId:
        bot.followTarget = p.objectId
        return p
  # No tracked player visible — fall back to nothing
  bot.followTarget = -1
  PlayerSight()

proc preyAdjacentTo(player: PlayerSight, prey: openArray[PreySight]): PreySight =
  for p in prey:
    if isCardinallyAdjacent(player.tileX, player.tileY, p.tileX, p.tileY):
      return p
  PreySight()

proc bestFlankSide(
  selfX, selfY, preyX, preyY: int,
  kind: PreyKind,
  allyX, allyY: int
): tuple[x, y: int, found: bool] =
  let
    allyIsN = (allyX == preyX and allyY == preyY - 1)
    allyIsS = (allyX == preyX and allyY == preyY + 1)
    allyIsE = (allyX == preyX + 1 and allyY == preyY)
    allyIsW = (allyX == preyX - 1 and allyY == preyY)
  case kind
  of Stag:
    if allyIsN: return (preyX, preyY + 1, true)
    if allyIsS: return (preyX, preyY - 1, true)
    if allyIsE: return (preyX - 1, preyY, true)
    if allyIsW: return (preyX + 1, preyY, true)
  of Boar:
    if allyIsN: return (preyX + 1, preyY, true)
    if allyIsS: return (preyX - 1, preyY, true)
    if allyIsE: return (preyX, preyY + 1, true)
    if allyIsW: return (preyX, preyY - 1, true)
  of Moose, Elephant:
    if not allyIsS: return (preyX, preyY + 1, true)
    if not allyIsN: return (preyX, preyY - 1, true)
    if not allyIsE: return (preyX + 1, preyY, true)
    if not allyIsW: return (preyX - 1, preyY, true)
  of Rabbit:
    discard
  (0, 0, false)

proc decideMask(bot: var Bot): uint8 =
  bot.updateCamera()
  if not bot.cameraKnown:
    return 0
  let players = bot.visiblePlayers()
  bot.identifySelf(players)
  if not bot.haveSelf:
    return 0
  bot.updateObstacleMap()

  # Priority 1: kill spot
  let killSpot = bot.findKillSpot()
  if killSpot.found:
    if bot.selfTileX == killSpot.x and bot.selfTileY == killSpot.y:
      bot.updateStuckState(0)
      return 0
    return bot.navigate(killSpot.x, killSpot.y)

  bot.updatePriorityList(players)
  let ally = bot.bestFollowTarget(players)
  if not ally.found:
    # No one to follow -- wander toward center
    return bot.navigate(MapWidth div 2, MapHeight div 2)

  let prey = bot.visiblePrey()
  let allyPrey = preyAdjacentTo(ally, prey)

  if allyPrey.found:
    let flank = bestFlankSide(
      bot.selfTileX, bot.selfTileY,
      allyPrey.tileX, allyPrey.tileY,
      allyPrey.kind,
      ally.tileX, ally.tileY
    )
    if flank.found:
      if bot.selfTileX == flank.x and bot.selfTileY == flank.y:
        bot.updateStuckState(0)
        return 0
      return bot.navigate(flank.x, flank.y)

  let dist = abs(bot.selfTileX - ally.tileX) + abs(bot.selfTileY - ally.tileY)
  if dist <= FollowDistance:
    bot.updateStuckState(0)
    return 0

  bot.navigate(ally.tileX, ally.tileY)

proc playerInputBlob(mask: uint8): string =
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

proc queryEscape(value: string): string =
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
  let schemePos = url.find("://")
  if schemePos < 0:
    return url
  let pathStart = url.find('/', schemePos + 3)
  if pathStart >= 0:
    return url
  url & path

proc addQueryParam(url, key, value: string): string =
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
  if url.len > 0:
    result = url.withPath(WebSocketPath)
  else:
    result = "ws://" & address & ":" & $port & WebSocketPath
  result = result.addQueryParam("name", name)

proc initBot(): Bot =
  result.selfObjectId = -1
  result.lastMask = 0xff'u8
  result.posHistoryIdx = 0
  result.posHistoryCount = 0
  result.stuckCount = 0
  result.lastSentNonZero = false
  result.priorityList = @[]
  result.followTarget = -1

proc acceptServerMessage(
  ws: WebSocket,
  message: Message,
  bot: var Bot
): bool =
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
  port = DefaultPort,
  url = "",
  name = "sidekick"
) =
  let endpoint = connectUrl(address, url, name, port)
  while true:
    try:
      echo "sidekick connecting to ", endpoint
      var bot = initBot()
      let ws = newWebSocket(endpoint)
      var lastMask = 0xff'u8
      while true:
        if not ws.receiveUpdates(bot):
          continue
        let mask = bot.decideMask()
        if mask != lastMask:
          ws.send(playerInputBlob(mask), BinaryMessage)
          lastMask = mask
    except CatchableError as e:
      echo "sidekick reconnecting after error: ", e.msg
      sleep(ConnectRetryDelayMs)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    url = ""
    name = "sidekick"

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

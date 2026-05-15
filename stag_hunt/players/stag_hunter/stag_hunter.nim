import
  std/[options, os, parseopt, random, strutils],
  whisky,
  protocol,
  pathfinding

const
  StagTileSize = 12
  TargetFps = 24
  WorldWidthTiles = 32
  WorldHeightTiles = 32

  BackgroundSpriteId = 3
  TreeSpriteId = 1
  RockSpriteId = 2
  PreySpriteBase = 10
  PlayerSpriteBase = 100
  PlayerSpriteEnd = PlayerSpriteBase + 8 * 4

  PlayerObjectBase = 5000
  BackgroundObjectBase = 8000
  PreyObjectBase = 10000
  IndicatorObjectBase = 9000
  IndicatorSpriteBase = 20

  MaxPlayerSlots = 64
  MaxPreySlots = 256
  MaxPreyCount = 64
  MaxBackgroundIndex = WorldWidthTiles * WorldHeightTiles
  MaxDrainMessages = 256
  ConnectRetryDelayMs = 250
  WebSocketPath = "/player"


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

  BotMode = enum
    ModeExplore
    ModeHunt

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
    mode: BotMode
    exploreTargetX: int
    exploreTargetY: int
    exploreTargetAge: int
    obstacleMap: ObstacleMap
    posHistory: array[4, tuple[x, y: int]]
    posHistoryIdx: int
    posHistoryCount: int
    stuckCount: int
    lastSentNonZero: bool

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
  if spriteId == BackgroundSpriteId: return SpriteBackground
  if spriteId == TreeSpriteId: return SpriteTree
  if spriteId == RockSpriteId: return SpriteRock
  if spriteId >= PreySpriteBase and spriteId < PreySpriteBase + 5: return SpritePrey
  if spriteId >= PlayerSpriteBase and spriteId < PlayerSpriteEnd: return SpritePlayer
  if spriteId >= IndicatorSpriteBase and spriteId < IndicatorSpriteBase + 3: return SpriteIndicator
  SpriteUnknown

proc applySpritePacket(bot: var Bot, packet: string): bool =
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset].uint8
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len: return false
      let
        spriteId = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10
      if compressedLen < 0 or offset + compressedLen + 2 > packet.len: return false
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len: return false
      offset += labelLen
      bot.ensureSprite(spriteId)
      bot.sprites[spriteId] = SpriteInfo(
        defined: true, width: width, height: height,
        kind: classifySprite(spriteId)
      )
    of 0x02:
      if offset + 11 > packet.len: return false
      let
        objectId = packet.readU16(offset)
        x = packet.readI16(offset + 2)
        y = packet.readI16(offset + 4)
        spriteId = packet.readU16(offset + 9)
      offset += 11
      bot.ensureObject(objectId)
      bot.objects[objectId] = ObjectState(present: true, x: x, y: y, spriteId: spriteId)
    of 0x03:
      if offset + 2 > packet.len: return false
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
      if offset + 5 > packet.len: return false
      offset += 5
    of 0x06:
      if offset + 3 > packet.len: return false
      offset += 3
    of 0x07:
      if offset + 2 > packet.len: return false
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
    result.add(PlayerSight(
      found: true, objectId: objectId,
      tileX: worldX div StagTileSize,
      tileY: worldY div StagTileSize
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
      kindOrd = state.spriteId - PreySpriteBase
      preyKind = if kindOrd >= 0 and kindOrd <= 4: PreyKind(kindOrd) else: Rabbit
    result.add(PreySight(
      found: true, objectId: objectId, kind: preyKind,
      tileX: (worldX + StagTileSize div 2) div StagTileSize,
      tileY: (worldY + StagTileSize div 2) div StagTileSize
    ))

proc identifySelf(bot: var Bot, players: openArray[PlayerSight]) =
  bot.haveSelf = false
  if bot.selfObjectId < 0: return
  for p in players:
    if p.objectId == bot.selfObjectId:
      bot.haveSelf = true
      bot.selfTileX = p.tileX
      bot.selfTileY = p.tileY
      return

proc updateStuckState(bot: var Bot, mask: uint8) =
  if not bot.haveSelf: return
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

proc pickExploreTarget(bot: var Bot) =
  const margin = 4
  let quadrant = (bot.frameTick div 120) mod 4
  case quadrant
  of 0: bot.exploreTargetX = margin + 4; bot.exploreTargetY = margin + 4
  of 1: bot.exploreTargetX = WorldWidthTiles - margin - 4; bot.exploreTargetY = margin + 4
  of 2: bot.exploreTargetX = WorldWidthTiles - margin - 4; bot.exploreTargetY = WorldHeightTiles - margin - 4
  of 3: bot.exploreTargetX = margin + 4; bot.exploreTargetY = WorldHeightTiles - margin - 4
  else: discard
  bot.exploreTargetAge = 0

proc findStag(prey: openArray[PreySight]): PreySight =
  for p in prey:
    if p.kind == Stag:
      return p
  PreySight()

proc pickClearCardinalNeighbor(
  map: ObstacleMap, preyX, preyY: int
): tuple[x, y: int, found: bool] =
  const offsets = [(0, -1), (0, 1), (-1, 0), (1, 0)]
  var candidates: array[4, tuple[x, y: int]]
  var count = 0
  for off in offsets:
    let nx = preyX + off[0]
    let ny = preyY + off[1]
    if inBounds(nx, ny) and map.getTile(nx, ny) != TileBlocked:
      candidates[count] = (nx, ny)
      inc count
  if count == 0:
    return (0, 0, false)
  let pick = candidates[rand(count - 1)]
  (pick.x, pick.y, true)

proc findKillSpot(bot: Bot): tuple[x, y: int, found: bool] =
  ## Scan for 1-dot indicator adjacent to self — stepping there completes a capture.
  const IndicatorTileOffset = (StagTileSize - 4) div 2  # 4px indicator centered in 12px tile
  for preyIdx in 0 ..< MaxPreyCount:
    for sideOrd in 0 ..< 4:
      let objectId = IndicatorObjectBase + preyIdx * 4 + sideOrd
      if not bot.objectPresent(objectId): continue
      let state = bot.objects[objectId]
      let sprite = bot.spriteInfo(state.spriteId)
      if not sprite.defined or sprite.kind != SpriteIndicator: continue
      # Only care about 1-dot (immediate kill)
      if state.spriteId != IndicatorSpriteBase: continue
      let
        worldX = bot.cameraX + state.x - IndicatorTileOffset
        worldY = bot.cameraY + state.y - IndicatorTileOffset
        tileX = worldX div StagTileSize
        tileY = worldY div StagTileSize
        dx = abs(bot.selfTileX - tileX)
        dy = abs(bot.selfTileY - tileY)
      # Adjacent (1 step away) or already there
      if (dx + dy) <= 2:
        return (tileX, tileY, true)
  (0, 0, false)

proc decideMask(bot: var Bot): uint8 =
  bot.updateCamera()
  if not bot.cameraKnown: return 0
  let players = bot.visiblePlayers()
  bot.identifySelf(players)
  if not bot.haveSelf: return 0
  bot.updateObstacleMap()

  # Priority 1: step into a kill spot (1-dot indicator nearby)
  let killSpot = bot.findKillSpot()
  if killSpot.found:
    if bot.selfTileX == killSpot.x and bot.selfTileY == killSpot.y:
      bot.updateStuckState(0)
      return 0
    return bot.navigate(killSpot.x, killSpot.y)

  let prey = bot.visiblePrey()
  let stag = findStag(prey)

  # Hunt mode: stag visible — go to a random clear side of it
  if stag.found:
    bot.mode = ModeHunt

    # Already on a cardinal neighbor of the stag — hold position
    let dx = abs(bot.selfTileX - stag.tileX)
    let dy = abs(bot.selfTileY - stag.tileY)
    if (dx == 1 and dy == 0) or (dx == 0 and dy == 1):
      bot.updateStuckState(0)
      return 0

    let spot = pickClearCardinalNeighbor(bot.obstacleMap, stag.tileX, stag.tileY)
    if spot.found:
      return bot.navigate(spot.x, spot.y)
    return bot.navigate(stag.tileX, stag.tileY)

  # Explore mode: patrol quadrants to find a stag
  bot.mode = ModeExplore
  inc bot.exploreTargetAge
  let atTarget = (bot.selfTileX == bot.exploreTargetX and
                  bot.selfTileY == bot.exploreTargetY)
  if atTarget or bot.exploreTargetAge > 200 or bot.stuckCount > 30:
    bot.pickExploreTarget()

  bot.navigate(bot.exploreTargetX, bot.exploreTargetY)

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
  if schemePos < 0: return url
  let pathStart = url.find('/', schemePos + 3)
  if pathStart >= 0: return url
  url & path

proc addQueryParam(url, key, value: string): string =
  if value.len == 0: return url
  result = url
  if '?' in result: result.add('&')
  else: result.add('?')
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
  result.mode = ModeExplore
  result.exploreTargetX = MapWidth div 2
  result.exploreTargetY = MapHeight div 2
  result.exploreTargetAge = 0
  result.posHistoryIdx = 0
  result.posHistoryCount = 0
  result.stuckCount = 0
  result.lastSentNonZero = false

proc acceptServerMessage(ws: WebSocket, message: Message, bot: var Bot): bool =
  case message.kind
  of BinaryMessage:
    result = bot.applySpritePacket(message.data)
    if result: inc bot.frameTick
  of Ping:
    ws.send(message.data, Pong)
  of TextMessage, Pong:
    discard

proc receiveUpdates(ws: WebSocket, bot: var Bot): bool =
  let firstMessage = ws.receiveMessage(-1)
  if firstMessage.isNone: return false
  if ws.acceptServerMessage(firstMessage.get, bot):
    result = true
  var drained = 0
  while drained < MaxDrainMessages:
    let message = ws.receiveMessage(0)
    if message.isNone: break
    if ws.acceptServerMessage(message.get, bot):
      result = true
    inc drained

proc runBot(
  address = DefaultHost,
  port = DefaultPort,
  url = "",
  name = "stag_hunter"
) =
  let endpoint = connectUrl(address, url, name, port)
  while true:
    try:
      echo "stag_hunter connecting to ", endpoint
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
      echo "stag_hunter reconnecting after error: ", e.msg
      sleep(ConnectRetryDelayMs)

when isMainModule:
  randomize()
  var
    address = DefaultHost
    port = DefaultPort
    url = ""
    name = "stag_hunter"

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

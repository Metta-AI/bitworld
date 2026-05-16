import
  std/[os, parseopt, strutils],
  whisky,
  protocol,
  pathfinding

const
  # Stag Hunt world constants (mirrored from stag_hunt/stag_hunt.nim).
  StagTileSize = 12   # stag_hunt overrides the protocol's 6 px tile
  WorldWidthTiles = 32
  WorldHeightTiles = 32

  PlayerViewportWidth = ScreenWidth
  PlayerViewportHeight = ScreenHeight

  TargetFps = 24
  WebSocketPath = "/player"
  MaxDrainMessages = 256

  # Sprite ids we care about.
  RabbitSpriteId = 10           # PreySpriteBase + Rabbit.ord (0)
  PlayerSpriteBase = 100
  PlayerSpriteCount = 32        # 8 colors * 4 facings

  # Object id bases.
  BackgroundObjectBase = 8000
  PlayerObjectBase = 5000
  PreyObjectBase = 10000

  # Indicator objects for capture readiness.
  IndicatorObjectBase = 9000
  IndicatorSpriteBase = 20
  MaxPreyCount = 64

  MaxPlayers = 64
  MaxPrey = 128

type
  SpriteInfo = object
    defined: bool
    width: int
    height: int
    label: string
    spriteId: int

  ObjectState = object
    present: bool
    x: int
    y: int
    z: int
    layer: int
    spriteId: int

  PreySight = object
    found: bool
    objectId: int
    spriteId: int
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
    selfKnown: bool
    lastMask: uint8
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
      # We don't need pixels; just skip past the compressed payload.
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
        spriteId: spriteId
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
      bot.cameraKnown = false
      bot.selfKnown = false
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

proc objectPresent(bot: Bot, objectId: int): bool =
  ## Returns true when one object exists in the current sprite scene.
  objectId >= 0 and objectId < bot.objects.len and bot.objects[objectId].present

proc updateCamera(bot: var Bot): bool =
  ## Derives camera world-pixel offset from any visible background tile.
  ## Each grass tile has objectId = BackgroundObjectBase + ty*32 + tx, and
  ## was drawn at screenX = tx*StagTileSize - cameraX.
  for objectId in BackgroundObjectBase ..<
      (BackgroundObjectBase + WorldWidthTiles * WorldHeightTiles):
    if not bot.objectPresent(objectId):
      continue
    let
      tileIndex = objectId - BackgroundObjectBase
      tx = tileIndex mod WorldWidthTiles
      ty = tileIndex div WorldWidthTiles
      obj = bot.objects[objectId]
    bot.cameraX = tx * StagTileSize - obj.x
    bot.cameraY = ty * StagTileSize - obj.y
    bot.cameraKnown = true
    return true
  bot.cameraKnown = false
  false

proc spriteIsPlayer(bot: Bot, spriteId: int): bool =
  ## Returns true when a sprite id is in the player sprite range.
  spriteId >= PlayerSpriteBase and
    spriteId < PlayerSpriteBase + PlayerSpriteCount

proc spriteIsRabbit(spriteId: int): bool =
  ## Returns true when a sprite id matches a rabbit prey sprite.
  spriteId == RabbitSpriteId

proc objectScreenCenter(
  bot: Bot,
  obj: ObjectState
): tuple[x, y: int] =
  ## Returns the screen-space center pixel of one object.
  var width = StagTileSize
  var height = StagTileSize
  if obj.spriteId >= 0 and obj.spriteId < bot.sprites.len:
    let sprite = bot.sprites[obj.spriteId]
    if sprite.defined:
      width = sprite.width
      height = sprite.height
  (obj.x + width div 2, obj.y + height div 2)

proc screenToTile(
  bot: Bot,
  screenX, screenY: int
): tuple[tx, ty: int] =
  ## Converts a screen-space pixel into a world tile.
  let
    worldX = bot.cameraX + screenX
    worldY = bot.cameraY + screenY
  (worldX div StagTileSize, worldY div StagTileSize)

proc findSelf(bot: var Bot): bool =
  ## Locates self in the current frame using the server-supplied identity
  ## packet (0x07). The server tells us our own object id, we just look it
  ## up and read its screen position.
  if not bot.cameraKnown or bot.selfObjectId < 0:
    bot.selfKnown = false
    return false
  if not bot.objectPresent(bot.selfObjectId):
    bot.selfKnown = false
    return false
  let
    obj = bot.objects[bot.selfObjectId]
    center = bot.objectScreenCenter(obj)
    tile = bot.screenToTile(center.x, center.y)
  bot.selfTileX = tile.tx
  bot.selfTileY = tile.ty
  bot.selfKnown = true
  true

proc visibleRabbits(bot: Bot): seq[PreySight] =
  ## Returns all currently visible rabbits as world tiles.
  for objectId in PreyObjectBase ..< PreyObjectBase + MaxPrey:
    if not bot.objectPresent(objectId):
      continue
    let obj = bot.objects[objectId]
    if not spriteIsRabbit(obj.spriteId):
      continue
    let
      center = bot.objectScreenCenter(obj)
      tile = bot.screenToTile(center.x, center.y)
    result.add(PreySight(
      found: true,
      objectId: objectId,
      spriteId: obj.spriteId,
      tileX: tile.tx,
      tileY: tile.ty
    ))

proc manhattan(ax, ay, bx, by: int): int =
  ## Returns Manhattan distance between two tiles.
  abs(ax - bx) + abs(ay - by)

proc nearestRabbit(bot: Bot, rabbits: openArray[PreySight]): PreySight =
  ## Returns the closest rabbit to self by Manhattan distance.
  if not bot.selfKnown:
    return PreySight()
  var bestDist = high(int)
  for rabbit in rabbits:
    let d = manhattan(bot.selfTileX, bot.selfTileY, rabbit.tileX, rabbit.tileY)
    if d < bestDist:
      bestDist = d
      result = rabbit


proc updateStuckState(bot: var Bot, mask: uint8) =
  ## Updates stuck/cycle detection state based on current position.
  if not bot.selfKnown:
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
  ## Scans visible background tile objects and marks tree/rock as blocked,
  ## grass as clear.
  if not bot.cameraKnown: return
  for objectId in BackgroundObjectBase ..< (BackgroundObjectBase + WorldWidthTiles * WorldHeightTiles):
    if not bot.objectPresent(objectId): continue
    let
      tileIndex = objectId - BackgroundObjectBase
      tx = tileIndex mod WorldWidthTiles
      ty = tileIndex div WorldWidthTiles
      obj = bot.objects[objectId]
    if obj.spriteId == 1 or obj.spriteId == 2:  # TreeSpriteId or RockSpriteId
      bot.obstacleMap.markTile(tx, ty, TileBlocked)
    elif obj.spriteId == 3:  # BackgroundSpriteId (grass)
      bot.obstacleMap.markTile(tx, ty, TileClear)

proc findKillSpot(bot: Bot): tuple[x, y: int, found: bool] =
  ## Scans indicator objects for 1-dot indicators (instant kill spots)
  ## within manhattan distance 2 of self.
  const IndicatorTileOffset = (12 - 4) div 2  # 4px indicator centered in 12px tile
  for preyIdx in 0 ..< MaxPreyCount:
    for sideOrd in 0 ..< 4:
      let objectId = IndicatorObjectBase + preyIdx * 4 + sideOrd
      if not bot.objectPresent(objectId): continue
      let obj = bot.objects[objectId]
      if obj.spriteId != IndicatorSpriteBase: continue  # only 1-dot (instant kill)
      let
        worldX = bot.cameraX + obj.x - IndicatorTileOffset
        worldY = bot.cameraY + obj.y - IndicatorTileOffset
        tileX = worldX div 12
        tileY = worldY div 12
        dx = abs(bot.selfTileX - tileX)
        dy = abs(bot.selfTileY - tileY)
      if (dx + dy) <= 2:
        return (tileX, tileY, true)
  (0, 0, false)

proc navigate(bot: var Bot, targetX, targetY: int): uint8 =
  if bot.stuckCount >= 15:
    let mask = unstickStep(bot.obstacleMap, bot.selfTileX, bot.selfTileY, bot.frameTick)
    bot.updateStuckState(mask)
    return mask
  let mask = pathStep(bot.obstacleMap, bot.selfTileX, bot.selfTileY, targetX, targetY)
  bot.updateStuckState(mask)
  mask

proc decideNextMask(bot: var Bot): tuple[mask: uint8, target: PreySight] =
  ## Chooses the next controller mask using BFS pathfinding.
  discard bot.updateCamera()
  discard bot.findSelf()
  if not bot.cameraKnown or not bot.selfKnown:
    return (0'u8, PreySight())
  bot.updateObstacleMap()

  # Priority 1: step into kill spot
  let killSpot = bot.findKillSpot()
  if killSpot.found:
    if bot.selfTileX == killSpot.x and bot.selfTileY == killSpot.y:
      bot.updateStuckState(0)
      return (0'u8, PreySight())
    return (bot.navigate(killSpot.x, killSpot.y), PreySight())

  let
    rabbits = bot.visibleRabbits()
    target = bot.nearestRabbit(rabbits)
  if not target.found:
    let mask = bot.navigate(WorldWidthTiles div 2, WorldHeightTiles div 2)
    return (mask, target)

  # Adjacent — hold
  let manh = manhattan(bot.selfTileX, bot.selfTileY, target.tileX, target.tileY)
  if manh == 1:
    bot.updateStuckState(0)
    return (0'u8, target)

  (bot.navigate(target.tileX, target.tileY), target)

proc playerInputBlob(mask: uint8): string =
  ## Builds a sprite_v1 player input packet.
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

proc maskSummary(mask: uint8): string =
  ## Returns a compact human-readable input mask.
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

proc echoDebug(
  bot: Bot,
  mask: uint8,
  target: PreySight,
  force = false
) =
  ## Prints occasional bot status for local tuning.
  if not force and bot.frameTick mod TargetFps != 0:
    return
  let
    selfTile =
      if bot.selfKnown:
        $bot.selfTileX & "," & $bot.selfTileY
      else:
        "?"
    targetTile =
      if target.found:
        $target.tileX & "," & $target.tileY
      else:
        "-"
    distance =
      if bot.selfKnown and target.found:
        $manhattan(bot.selfTileX, bot.selfTileY, target.tileX, target.tileY)
      else:
        "-"
  echo "step=", bot.frameTick,
    " keys=", mask.maskSummary(),
    " self=", selfTile,
    " rabbit=", targetTile,
    " dist=", distance

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

proc connectUrl(address, url, name, token: string, port, slot: int): string =
  ## Builds the player websocket URL for Stag Hunt.
  if url.len > 0:
    result = url.withPath(WebSocketPath)
  else:
    result = "ws://" & address & ":" & $port & WebSocketPath
  result = result.addQueryParam("name", name)
  if slot >= 0:
    result = result.addQueryParam("slot", $slot)
  if token.len > 0:
    result = result.addQueryParam("token", token)

proc initBot(): Bot =
  ## Creates a fresh rabbiteer bot state.
  result.selfObjectId = -1
  result.cameraKnown = false
  result.selfKnown = false
  result.lastMask = 0xff'u8
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
  port = DefaultPort,
  url = "",
  name = "rabbiteer",
  token = "",
  slot = -1
) =
  ## Connects rabbiteer to Stag Hunt and chases visible rabbits forever.
  let endpoint = connectUrl(address, url, name, token, port, slot)
  while true:
    try:
      echo "rabbiteer connecting to ", endpoint
      var bot = initBot()
      let ws = newWebSocket(endpoint)
      var lastMask = 0xff'u8
      while true:
        if not ws.receiveUpdates(bot):
          continue
        let decision = bot.decideNextMask()
        let mask = decision.mask
        bot.echoDebug(mask, decision.target, mask != lastMask)
        if mask != lastMask:
          ws.send(playerInputBlob(mask), BinaryMessage)
          lastMask = mask
    except CatchableError as e:
      echo "rabbiteer reconnecting after error: ", e.msg
      sleep(250)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    url = ""
    name = "rabbiteer"
    token = ""
    slot = -1

  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = value
      of "port": port = parseInt(value)
      of "url": url = value
      of "name": name = value
      of "token": token = value
      of "slot": slot = parseInt(value)
      else:
        raise newException(ValueError, "Unknown option: --" & key)
    of cmdArgument, cmdShortOption:
      raise newException(ValueError, "Unexpected argument: " & key)
    of cmdEnd:
      discard

  runBot(address, port, url, name, token, slot)

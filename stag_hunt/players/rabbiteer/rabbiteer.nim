import
  std/[os, parseopt, strutils],
  whisky,
  protocol

const
  # Stag Hunt world constants (mirrored from stag_hunt/stag_hunt.nim).
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
    else:
      return false
  true

proc objectPresent(bot: Bot, objectId: int): bool =
  ## Returns true when one object exists in the current sprite scene.
  objectId >= 0 and objectId < bot.objects.len and bot.objects[objectId].present

proc updateCamera(bot: var Bot): bool =
  ## Derives camera world-pixel offset from any visible background tile.
  ## Each grass tile has objectId = BackgroundObjectBase + ty*32 + tx, and
  ## was drawn at screenX = tx*TileSize - cameraX.
  for objectId in BackgroundObjectBase ..<
      (BackgroundObjectBase + WorldWidthTiles * WorldHeightTiles):
    if not bot.objectPresent(objectId):
      continue
    let
      tileIndex = objectId - BackgroundObjectBase
      tx = tileIndex mod WorldWidthTiles
      ty = tileIndex div WorldWidthTiles
      obj = bot.objects[objectId]
    bot.cameraX = tx * TileSize - obj.x
    bot.cameraY = ty * TileSize - obj.y
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
  var width = TileSize
  var height = TileSize
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
  (worldX div TileSize, worldY div TileSize)

proc findSelf(bot: var Bot): bool =
  ## Picks the player whose tile is closest to the viewport center as self.
  if not bot.cameraKnown:
    return false
  let
    viewCenterX = PlayerViewportWidth div 2
    viewCenterY = PlayerViewportHeight div 2
  var
    bestObjectId = -1
    bestDistanceSq = high(int)
    bestTileX = 0
    bestTileY = 0
  for objectId in PlayerObjectBase ..< PlayerObjectBase + MaxPlayers:
    if not bot.objectPresent(objectId):
      continue
    let obj = bot.objects[objectId]
    if not bot.spriteIsPlayer(obj.spriteId):
      continue
    let
      center = bot.objectScreenCenter(obj)
      dx = center.x - viewCenterX
      dy = center.y - viewCenterY
      distSq = dx * dx + dy * dy
    if distSq < bestDistanceSq:
      bestDistanceSq = distSq
      bestObjectId = objectId
      let tile = bot.screenToTile(center.x, center.y)
      bestTileX = tile.tx
      bestTileY = tile.ty
  if bestObjectId < 0:
    bot.selfKnown = false
    return false
  bot.selfObjectId = bestObjectId
  bot.selfTileX = bestTileX
  bot.selfTileY = bestTileY
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

proc chebyshev(ax, ay, bx, by: int): int =
  ## Returns Chebyshev (king-move) distance between two tiles.
  max(abs(ax - bx), abs(ay - by))

proc manhattan(ax, ay, bx, by: int): int =
  ## Returns Manhattan distance between two tiles.
  abs(ax - bx) + abs(ay - by)

proc nearestRabbit(bot: Bot, rabbits: openArray[PreySight]): PreySight =
  ## Returns the closest rabbit to self by Chebyshev distance.
  if not bot.selfKnown:
    return PreySight()
  var bestDist = high(int)
  for rabbit in rabbits:
    let d = chebyshev(bot.selfTileX, bot.selfTileY, rabbit.tileX, rabbit.tileY)
    if d < bestDist:
      bestDist = d
      result = rabbit

proc stepMaskToward(
  selfX, selfY, targetX, targetY: int
): uint8 =
  ## Greedy one-axis step mask toward a target tile. Picks the axis with
  ## the greater remaining delta so the server (single-axis movement)
  ## still converges.
  let
    dx = targetX - selfX
    dy = targetY - selfY
  if dx == 0 and dy == 0:
    return 0
  if abs(dx) >= abs(dy):
    if dx < 0:
      return ButtonLeft
    if dx > 0:
      return ButtonRight
  if dy < 0:
    return ButtonUp
  if dy > 0:
    return ButtonDown
  if dx < 0:
    return ButtonLeft
  if dx > 0:
    return ButtonRight
  0

proc decideNextMask(bot: var Bot): tuple[mask: uint8, target: PreySight] =
  ## Chooses the next controller mask: chase the nearest visible rabbit.
  discard bot.updateCamera()
  discard bot.findSelf()
  if not bot.cameraKnown or not bot.selfKnown:
    return (0'u8, PreySight())
  let
    rabbits = bot.visibleRabbits()
    target = bot.nearestRabbit(rabbits)
  if not target.found:
    return (0'u8, target)
  # Adjacent on a cardinal side -> stop; server captures within ~1 tick.
  let
    cheb = chebyshev(bot.selfTileX, bot.selfTileY, target.tileX, target.tileY)
    manh = manhattan(bot.selfTileX, bot.selfTileY, target.tileX, target.tileY)
  if cheb == 1 and manh == 1:
    return (0'u8, target)
  (stepMaskToward(
    bot.selfTileX, bot.selfTileY, target.tileX, target.tileY
  ), target)

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
        $chebyshev(bot.selfTileX, bot.selfTileY, target.tileX, target.tileY)
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

proc connectUrl(
  address, url, name: string,
  port: int
): string =
  ## Builds the player websocket URL for Stag Hunt.
  if url.len > 0:
    result = url.withPath(WebSocketPath)
  else:
    result = "ws://" & address & ":" & $port & WebSocketPath
  result = result.addQueryParam("name", name)

proc initBot(): Bot =
  ## Creates a fresh rabbiteer bot state.
  result.selfObjectId = -1
  result.cameraKnown = false
  result.selfKnown = false
  result.lastMask = 0xff'u8

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
  name = "rabbiteer"
) =
  ## Connects rabbiteer to Stag Hunt and chases visible rabbits forever.
  let endpoint = connectUrl(address, url, name, port)
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

  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = value
      of "port":
        port = parseInt(value)
      of "url":
        url = value
      of "name":
        name = value
      else:
        raise newException(ValueError, "Unknown option: --" & key)
    of cmdArgument, cmdShortOption:
      raise newException(ValueError, "Unexpected argument: " & key)
    of cmdEnd:
      discard

  runBot(address, port, url, name)

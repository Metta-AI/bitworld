import
  std/[options, os, parseopt, strutils],
  whisky,
  protocol

const
  # Stag Hunt world geometry (mirrors stag_hunt/stag_hunt.nim).
  TargetFps = 24
  WorldWidthTiles = 32
  WorldHeightTiles = 32
  PlayerViewportWidth = ScreenWidth   # 128
  PlayerViewportHeight = ScreenHeight # 128

  # Sprite ids (must match stag_hunt server).
  BackgroundSpriteId = 3
  TreeSpriteId = 1
  RockSpriteId = 2
  PreySpriteBase = 10        # + PreyKind.ord (0..4)
  PlayerSpriteBase = 100     # + colorSlot*4 + facing.ord (range 100..131)
  PlayerSpriteEnd = PlayerSpriteBase + 8 * 4

  # Object id bases. TileObjectBase (1000) is unused — tree/rock objects
  # are ignored entirely; we only need background tiles (for camera derivation),
  # players, and prey.
  PlayerObjectBase = 5000    # + array index
  BackgroundObjectBase = 8000 # + tileIndex (always present per cell)
  PreyObjectBase = 10000     # + array index

  MaxPlayerSlots = 64        # generous upper bound for player array indices
  MaxPreySlots = 256         # generous upper bound for prey array indices
  MaxBackgroundIndex = WorldWidthTiles * WorldHeightTiles
  MaxDrainMessages = 256
  ConnectRetryDelayMs = 250
  WebSocketPath = "/player"

type
  SpriteKind = enum
    SpriteUnknown
    SpriteBackground
    SpriteTree
    SpriteRock
    SpritePrey
    SpritePlayer

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
    tileX: int
    tileY: int

  PlayerSight = object
    found: bool
    objectId: int
    tileX: int
    tileY: int
    screenX: int
    screenY: int

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
    lastDebugTargetId: int
    lastDebugDistance: int

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

proc classifySprite(spriteId: int): SpriteKind =
  ## Classifies one Stag Hunt sprite id by numeric range.
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
  SpriteUnknown

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
      # We don't need to decompress pixels; skip past them.
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
    else:
      return false
  true

proc spriteInfo(bot: Bot, spriteId: int): SpriteInfo =
  ## Returns sprite metadata or an empty sprite.
  if spriteId >= 0 and spriteId < bot.sprites.len:
    return bot.sprites[spriteId]
  SpriteInfo()

proc objectPresent(bot: Bot, objectId: int): bool =
  ## Returns true when one object exists in the current frame.
  objectId >= 0 and objectId < bot.objects.len and bot.objects[objectId].present

proc updateCamera(bot: var Bot) =
  ## Derives world-camera offset from any visible background tile object.
  ## A background tile id encodes its world tile index, so given its screen
  ## position we can recover (cameraX, cameraY).
  bot.cameraKnown = false
  for i in 0 ..< MaxBackgroundIndex:
    let objectId = BackgroundObjectBase + i
    if not bot.objectPresent(objectId):
      continue
    let
      state = bot.objects[objectId]
      tx = i mod WorldWidthTiles
      ty = i div WorldWidthTiles
    bot.cameraX = tx * TileSize - state.x
    bot.cameraY = ty * TileSize - state.y
    bot.cameraKnown = true
    return

proc visiblePrey(bot: Bot): seq[PreySight] =
  ## Returns all currently visible prey objects in world tile coordinates.
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
    # Prey sprites jitter +/-1 pixel during alertFlash. Round to nearest tile.
    let
      tileX = (worldX + TileSize div 2) div TileSize
      tileY = (worldY + TileSize div 2) div TileSize
    result.add(PreySight(
      found: true,
      objectId: objectId,
      tileX: tileX,
      tileY: tileY
    ))

proc visiblePlayers(bot: Bot): seq[PlayerSight] =
  ## Returns all visible player objects with world tile and screen coordinates.
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
      tileX = worldX div TileSize
      tileY = worldY div TileSize
    result.add(PlayerSight(
      found: true,
      objectId: objectId,
      tileX: tileX,
      tileY: tileY,
      screenX: state.x,
      screenY: state.y
    ))

proc chebyshevDistance(ax, ay, bx, by: int): int =
  ## Returns the Chebyshev (king-move) distance between two tile points.
  max(abs(ax - bx), abs(ay - by))

proc identifySelf(bot: var Bot, players: openArray[PlayerSight]) =
  ## Picks our own player object — the one closest to viewport center.
  ## The server centers the camera on us; near map edges clampCamera shifts
  ## the camera, but we still occupy the tile nearest the viewport middle.
  bot.haveSelf = false
  if players.len == 0:
    return
  let
    centerWorldX = bot.cameraX + PlayerViewportWidth div 2
    centerWorldY = bot.cameraY + PlayerViewportHeight div 2
    centerTileX = centerWorldX div TileSize
    centerTileY = centerWorldY div TileSize
  var
    bestDistance = high(int)
    bestIndex = -1
  for i, p in players:
    let d = chebyshevDistance(p.tileX, p.tileY, centerTileX, centerTileY)
    if d < bestDistance:
      bestDistance = d
      bestIndex = i
  if bestIndex < 0:
    return
  let self = players[bestIndex]
  bot.haveSelf = true
  bot.selfObjectId = self.objectId
  bot.selfTileX = self.tileX
  bot.selfTileY = self.tileY

proc stepMask(selfX, selfY, targetX, targetY: int): uint8 =
  ## Returns a single-button d-pad mask toward (targetX, targetY).
  ## The server only accepts one direction at a time, so we pick the axis
  ## with greater remaining distance.
  let
    dx = targetX - selfX
    dy = targetY - selfY
  if dx == 0 and dy == 0:
    return 0
  let
    ax = abs(dx)
    ay = abs(dy)
  if ax >= ay:
    if dx > 0:
      return ButtonRight
    if dx < 0:
      return ButtonLeft
  if dy > 0:
    return ButtonDown
  if dy < 0:
    return ButtonUp
  0

proc isCardinallyAdjacent(selfX, selfY, targetX, targetY: int): bool =
  ## Returns true when self is one tile from target along a single axis.
  let
    dx = abs(targetX - selfX)
    dy = abs(targetY - selfY)
  (dx == 1 and dy == 0) or (dx == 0 and dy == 1)

proc chooseTarget(
  selfX, selfY: int,
  prey: openArray[PreySight]
): PreySight =
  ## Picks the visible prey with smallest Chebyshev distance to self.
  ## Ties broken by lowest object id for determinism.
  var bestDistance = high(int)
  for p in prey:
    let d = chebyshevDistance(selfX, selfY, p.tileX, p.tileY)
    if d < bestDistance:
      bestDistance = d
      result = p
    elif d == bestDistance and result.found and p.objectId < result.objectId:
      result = p

proc decideMask(bot: var Bot): tuple[mask: uint8, target: PreySight, distance: int] =
  ## Builds the next input mask using current sprite scene state.
  bot.updateCamera()
  if not bot.cameraKnown:
    return (0'u8, PreySight(), -1)
  let players = bot.visiblePlayers()
  bot.identifySelf(players)
  if not bot.haveSelf:
    return (0'u8, PreySight(), -1)
  let prey = bot.visiblePrey()
  if prey.len == 0:
    return (0'u8, PreySight(), -1)
  let target = chooseTarget(bot.selfTileX, bot.selfTileY, prey)
  if not target.found:
    return (0'u8, PreySight(), -1)
  let distance = chebyshevDistance(
    bot.selfTileX, bot.selfTileY, target.tileX, target.tileY
  )
  # On a cardinal side already — stand still, wait for kill or for prey to bolt.
  if isCardinallyAdjacent(
    bot.selfTileX, bot.selfTileY, target.tileX, target.tileY
  ):
    return (0'u8, target, distance)
  let mask = stepMask(
    bot.selfTileX, bot.selfTileY, target.tileX, target.tileY
  )
  (mask, target, distance)

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
  if result.len == 0:
    result = "."

proc echoDebug(
  bot: Bot,
  mask: uint8,
  target: PreySight,
  distance: int,
  force: bool
) =
  ## Prints occasional bot status for tuning.
  if not force and bot.frameTick mod TargetFps != 0:
    return
  let
    selfTile =
      if bot.haveSelf:
        $bot.selfTileX & "," & $bot.selfTileY
      else:
        "?"
    targetTile =
      if target.found:
        $target.tileX & "," & $target.tileY
      else:
        "?"
    distStr =
      if distance >= 0: $distance else: "?"
  echo "step=", bot.frameTick,
    " self=", selfTile,
    " target=", targetTile,
    " dist=", distStr,
    " keys=", mask.maskSummary(),
    " camera=", bot.cameraX, ",", bot.cameraY

proc playerInputBlob(mask: uint8): string =
  ## Builds a sprite_v1 player input packet for the stag_hunt server.
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

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
    result = url.withPath(WebSocketPath)
  else:
    result = "ws://" & address & ":" & $port & WebSocketPath
  result = result.addQueryParam("name", name)

proc initBot(): Bot =
  ## Creates a fresh nearest-hunter bot state.
  result.selfObjectId = -1
  result.lastMask = 0xff'u8
  result.lastDebugTargetId = -1
  result.lastDebugDistance = -1

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
  name = "nearest_hunter"
) =
  ## Connects to a stag_hunt server and pursues the closest visible prey.
  let endpoint = connectUrl(address, url, name, port)
  while true:
    try:
      echo "nearest_hunter connecting to ", endpoint
      var bot = initBot()
      let ws = newWebSocket(endpoint)
      var lastMask = 0xff'u8
      while true:
        if not ws.receiveUpdates(bot):
          continue
        let (mask, target, distance) = bot.decideMask()
        bot.echoDebug(mask, target, distance, mask != lastMask)
        if mask != lastMask:
          ws.send(playerInputBlob(mask), BinaryMessage)
          lastMask = mask
    except CatchableError as e:
      echo "nearest_hunter reconnecting after error: ", e.msg
      sleep(ConnectRetryDelayMs)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    url = ""
    name = "nearest_hunter"

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

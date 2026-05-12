import
  std/[algorithm, os, parseopt, random, strutils, tables, times, uri],
  supersnappy, whisky,
  protocol

when not defined(botHeadless):
  import pixie, scales, silky, windy

const
  EngineWsEnv = "COGAMES_ENGINE_WS_URL"
  DefaultPlayerAddress = "ws://localhost:8080/player"
  PlayerWebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  BoardWidthCells = 250
  BoardHeightCells = 250
  CellPixels = 9
  BaseTerrainY = BoardHeightCells * 31 div 50
  LineClearLength = 8
  LaneStartX = BoardWidthCells div 2 - LineClearLength div 2
  MaxDrainMessages = 64
  DebugInterval = 60
  BrightMinChannel = 30
  BrightMaxChannel = 70
  SupportedGapBonus = 1400
  PocketFillBonus = 2400
  HoleReductionBonus = 4500
  HoleIncreasePenalty = 5200
  RowCompletionBonus = 24000
  OutsideLanePenalty = 750
  BumpinessPenalty = 80
  HeightPenalty = 10

when defined(botHeadless):
  type ViewerApp = ref object
else:
  const
    ViewerWindowWidth = 1120
    ViewerWindowHeight = 900
    ViewerMargin = 16.0'f
    ViewerMapScale = 1.25'f
    ViewerViewportScale = 8.0'f
    ViewerCellPad = 0.35'f
    ViewerBackground = rgbx(16, 19, 25, 255)
    ViewerPanel = rgbx(30, 35, 45, 255)
    ViewerPanelAlt = rgbx(22, 26, 34, 255)
    ViewerGrid = rgbx(41, 48, 61, 255)
    ViewerTerrain = rgbx(91, 102, 116, 255)
    ViewerSettled = rgbx(70, 145, 185, 255)
    ViewerActive = rgbx(124, 255, 165, 255)
    ViewerTarget = rgbx(255, 213, 91, 255)
    ViewerLane = rgbx(255, 255, 255, 28)
    ViewerText = rgbx(226, 231, 240, 255)
    ViewerMutedText = rgbx(148, 157, 174, 255)

  type ViewerApp = ref object
    window: Window
    silky: Silky
    contentScale: float32

type
  RgbaColor = tuple[r, g, b, a: uint8]

  Cell = object
    x: int
    y: int

  SpriteImage = object
    width: int
    height: int
    label: string
    pixels: seq[uint8]

  GlobalObject = object
    id: int
    x: int
    y: int
    z: int
    layer: int
    spriteId: int

  PieceKind = enum
    PieceI
    PieceO
    PieceT
    PieceL
    PieceJ
    PieceS
    PieceZ

  ActivePiece = object
    found: bool
    kind: PieceKind
    rotation: int
    originX: int
    originY: int
    cells: seq[Cell]

  Placement = object
    found: bool
    rotation: int
    x: int
    y: int
    score: int

  Bot = object
    rng: Rand
    frameTick: int
    map: SpriteImage
    playerFrame: SpriteImage
    frameObjects: Table[int, GlobalObject]
    frameWidth: int
    frameHeight: int
    sprites: Table[int, SpriteImage]
    objects: Table[int, GlobalObject]
    mapWidth: int
    mapHeight: int
    mapScale: int
    ownColor: RgbaColor
    hasOwnColor: bool
    lastMask: uint8
    active: ActivePiece
    logicalTerrain: seq[bool]
    logicalWidth: int
    logicalHeight: int
    target: Placement
    targetRow: int
    intent: string

proc readU16(data: string, offset: int): int =
  ## Reads one little endian unsigned 16 bit value.
  int(uint16(data[offset].uint8) or
    (uint16(data[offset + 1].uint8) shl 8))

proc readU32(data: string, offset: int): int =
  ## Reads one little endian unsigned 32 bit value.
  int(uint32(data[offset].uint8) or
    (uint32(data[offset + 1].uint8) shl 8) or
    (uint32(data[offset + 2].uint8) shl 16) or
    (uint32(data[offset + 3].uint8) shl 24))

proc readI16(data: string, offset: int): int =
  ## Reads one little endian signed 16 bit value.
  let value = data.readU16(offset)
  if value >= 0x8000:
    value - 0x10000
  else:
    value

proc colorKey(color: RgbaColor): int =
  ## Packs one RGBA color into a table key.
  (int(color.r) shl 24) or
    (int(color.g) shl 16) or
    (int(color.b) shl 8) or
    int(color.a)

proc colorFromKey(key: int): RgbaColor =
  ## Unpacks one color table key into RGBA channels.
  (
    r: uint8((key shr 24) and 0xff),
    g: uint8((key shr 16) and 0xff),
    b: uint8((key shr 8) and 0xff),
    a: uint8(key and 0xff)
  )

proc rgbaAt(image: SpriteImage, x, y: int): RgbaColor =
  ## Reads one RGBA pixel from an image.
  if x < 0 or y < 0 or x >= image.width or y >= image.height:
    return (r: 0'u8, g: 0'u8, b: 0'u8, a: 0'u8)
  let offset = (y * image.width + x) * 4
  (
    r: image.pixels[offset],
    g: image.pixels[offset + 1],
    b: image.pixels[offset + 2],
    a: image.pixels[offset + 3]
  )

proc highChannel(color: RgbaColor): int =
  ## Returns the highest RGB channel in a color.
  max(int(color.r), max(int(color.g), int(color.b)))

proc scaledColorDistance(color, base: RgbaColor): int =
  ## Compares one stained color against a full-bright base color.
  let
    colorHigh = color.highChannel()
    baseHigh = base.highChannel()
  if colorHigh <= 0 or baseHigh <= 0:
    return high(int)
  result += abs(int(color.r) - int(base.r) * colorHigh div baseHigh)
  result += abs(int(color.g) - int(base.g) * colorHigh div baseHigh)
  result += abs(int(color.b) - int(base.b) * colorHigh div baseHigh)

proc looksLikeOwnColor(color, ownColor: RgbaColor): bool =
  ## Returns true when a stained map color matches the bot color.
  color.a >= 20'u8 and color.highChannel() >= 24 and
    color.scaledColorDistance(ownColor) <= 90

proc isBackground(color: RgbaColor): bool =
  ## Returns true for the black empty-map color.
  color.r <= 2'u8 and color.g <= 2'u8 and color.b <= 2'u8

proc looksLikePlayerColor(color: RgbaColor): bool =
  ## Returns true for the bright HSV player block colors.
  if color.a != 255'u8:
    return false
  let
    low = min(int(color.r), min(int(color.g), int(color.b)))
    high = max(int(color.r), max(int(color.g), int(color.b)))
  high >= 245 and low >= BrightMinChannel and
    low <= BrightMaxChannel and high - low >= 170

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

proc pieceCells(kind: PieceKind, rotation: int): array[4, Cell] =
  ## Returns piece cells using the server's piece coordinate system.
  case kind
  of PieceI:
    case rotation and 3
    of 0: [Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 2, y: 1), Cell(x: 3, y: 1)]
    of 1: [Cell(x: 2, y: 0), Cell(x: 2, y: 1), Cell(x: 2, y: 2), Cell(x: 2, y: 3)]
    of 2: [Cell(x: 0, y: 2), Cell(x: 1, y: 2), Cell(x: 2, y: 2), Cell(x: 3, y: 2)]
    else: [Cell(x: 1, y: 0), Cell(x: 1, y: 1), Cell(x: 1, y: 2), Cell(x: 1, y: 3)]
  of PieceO:
    [Cell(x: 1, y: 0), Cell(x: 2, y: 0), Cell(x: 1, y: 1), Cell(x: 2, y: 1)]
  of PieceT:
    case rotation and 3
    of 0: [Cell(x: 1, y: 0), Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 2, y: 1)]
    of 1: [Cell(x: 1, y: 0), Cell(x: 1, y: 1), Cell(x: 2, y: 1), Cell(x: 1, y: 2)]
    of 2: [Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 2, y: 1), Cell(x: 1, y: 2)]
    else: [Cell(x: 1, y: 0), Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 1, y: 2)]
  of PieceL:
    case rotation and 3
    of 0: [Cell(x: 0, y: 0), Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 2, y: 1)]
    of 1: [Cell(x: 1, y: 0), Cell(x: 2, y: 0), Cell(x: 1, y: 1), Cell(x: 1, y: 2)]
    of 2: [Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 2, y: 1), Cell(x: 2, y: 2)]
    else: [Cell(x: 1, y: 0), Cell(x: 1, y: 1), Cell(x: 0, y: 2), Cell(x: 1, y: 2)]
  of PieceJ:
    case rotation and 3
    of 0: [Cell(x: 2, y: 0), Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 2, y: 1)]
    of 1: [Cell(x: 1, y: 0), Cell(x: 1, y: 1), Cell(x: 1, y: 2), Cell(x: 2, y: 2)]
    of 2: [Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 2, y: 1), Cell(x: 0, y: 2)]
    else: [Cell(x: 0, y: 0), Cell(x: 1, y: 0), Cell(x: 1, y: 1), Cell(x: 1, y: 2)]
  of PieceS:
    case rotation and 3
    of 0: [Cell(x: 1, y: 0), Cell(x: 2, y: 0), Cell(x: 0, y: 1), Cell(x: 1, y: 1)]
    of 1: [Cell(x: 1, y: 0), Cell(x: 1, y: 1), Cell(x: 2, y: 1), Cell(x: 2, y: 2)]
    of 2: [Cell(x: 1, y: 1), Cell(x: 2, y: 1), Cell(x: 0, y: 2), Cell(x: 1, y: 2)]
    else: [Cell(x: 0, y: 0), Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 1, y: 2)]
  of PieceZ:
    case rotation and 3
    of 0: [Cell(x: 0, y: 0), Cell(x: 1, y: 0), Cell(x: 1, y: 1), Cell(x: 2, y: 1)]
    of 1: [Cell(x: 2, y: 0), Cell(x: 1, y: 1), Cell(x: 2, y: 1), Cell(x: 1, y: 2)]
    of 2: [Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 1, y: 2), Cell(x: 2, y: 2)]
    else: [Cell(x: 1, y: 0), Cell(x: 0, y: 1), Cell(x: 1, y: 1), Cell(x: 0, y: 2)]

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc inputBlob(mask: uint8): string =
  ## Builds a sprite protocol player input packet.
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

proc chatBlob(text: string): string =
  ## Builds a sprite protocol text input packet.
  var bytes = @[0x81'u8]
  bytes.addU16(text.len)
  for ch in text:
    bytes.add(uint8(ord(ch)))
  blobFromBytes(bytes)

proc representativeColor(sprite: SpriteImage): RgbaColor =
  ## Returns the brightest non-transparent color in one sprite.
  if sprite.pixels.len < 4:
    return
  var bestValue = -1
  for i in countup(0, sprite.pixels.len - 4, 4):
    if sprite.pixels[i + 3] < 20'u8:
      continue
    let value =
      int(sprite.pixels[i]) +
      int(sprite.pixels[i + 1]) +
      int(sprite.pixels[i + 2])
    if value > bestValue:
      bestValue = value
      result = (
        r: sprite.pixels[i],
        g: sprite.pixels[i + 1],
        b: sprite.pixels[i + 2],
        a: sprite.pixels[i + 3]
      )

proc blitSprite(
  image: var SpriteImage,
  sprite: SpriteImage,
  x,
  y: int
) =
  ## Blits one RGBA sprite into an RGBA image.
  if image.pixels.len != image.width * image.height * 4:
    return
  if sprite.pixels.len != sprite.width * sprite.height * 4:
    return
  for sy in 0 ..< sprite.height:
    let dstY = y + sy
    if dstY < 0 or dstY >= image.height:
      continue
    for sx in 0 ..< sprite.width:
      let dstX = x + sx
      if dstX < 0 or dstX >= image.width:
        continue
      let
        srcOffset = (sy * sprite.width + sx) * 4
        alpha = sprite.pixels[srcOffset + 3]
      if alpha == 0'u8:
        continue
      let dstOffset = (dstY * image.width + dstX) * 4
      image.pixels[dstOffset] = sprite.pixels[srcOffset]
      image.pixels[dstOffset + 1] = sprite.pixels[srcOffset + 1]
      image.pixels[dstOffset + 2] = sprite.pixels[srcOffset + 2]
      image.pixels[dstOffset + 3] = alpha

proc sortedObjects(objects: Table[int, GlobalObject]): seq[GlobalObject] =
  ## Returns protocol objects in draw order.
  for item in objects.values:
    result.add(item)
  result.sort(proc(a, b: GlobalObject): int =
    result = cmp(a.z, b.z)
    if result == 0:
      result = cmp(a.y, b.y)
    if result == 0:
      result = cmp(a.id, b.id)
  )

proc logicalMapScale(width, height: int): int =
  ## Returns the physical pixels used for one logical board cell.
  if width <= 0 or height <= 0:
    return 1
  let
    xScale = width div BoardWidthCells
    yScale = height div BoardHeightCells
  if xScale == yScale and xScale > 1 and
      width mod BoardWidthCells == 0 and
      height mod BoardHeightCells == 0:
    return xScale
  if width >= BoardWidthCells * CellPixels and
      height >= BoardHeightCells * CellPixels:
    return CellPixels
  1

proc logicalMapWidth(width, scale: int): int =
  ## Converts a physical map width into logical board cells.
  if scale <= 1:
    return width
  max(1, width div scale)

proc logicalMapHeight(height, scale: int): int =
  ## Converts a physical map height into logical board cells.
  if scale <= 1:
    return height
  max(1, height div scale)

proc logicalCell(item: GlobalObject, scale: int): Cell =
  ## Converts a physical sprite-object position to a logical cell.
  if scale <= 1:
    return Cell(x: item.x, y: item.y)
  Cell(x: item.x div scale, y: item.y div scale)

proc putLogicalCell(
  image: var SpriteImage,
  cell: Cell,
  color: RgbaColor
) =
  ## Writes one reconstructed logical map cell.
  if cell.x < 0 or cell.y < 0 or
      cell.x >= image.width or cell.y >= image.height:
    return
  let dstOffset = (cell.y * image.width + cell.x) * 4
  image.pixels[dstOffset] = color.r
  image.pixels[dstOffset + 1] = color.g
  image.pixels[dstOffset + 2] = color.b
  image.pixels[dstOffset + 3] = color.a

proc rebuildGlobalMap(bot: var Bot) =
  ## Rebuilds a dense map image from global protocol sprites and objects.
  if bot.mapWidth <= 0 or bot.mapHeight <= 0:
    return
  let
    scale = logicalMapScale(bot.mapWidth, bot.mapHeight)
    mapWidth = bot.mapWidth.logicalMapWidth(scale)
    mapHeight = bot.mapHeight.logicalMapHeight(scale)
  if bot.mapScale != scale:
    bot.mapScale = scale
    echo "stacker global map scale=", scale
  bot.map = SpriteImage(
    width: mapWidth,
    height: mapHeight,
    label: "global",
    pixels: newSeq[uint8](mapWidth * mapHeight * 4)
  )
  for i in countup(0, bot.map.pixels.len - 4, 4):
    bot.map.pixels[i + 3] = 255'u8

  for item in bot.objects.sortedObjects():
    if item.spriteId notin bot.sprites:
      continue
    let sprite = bot.sprites[item.spriteId]
    if scale > 1:
      let
        cell = item.logicalCell(scale)
        color = sprite.representativeColor()
      bot.map.putLogicalCell(cell, color)
      continue
    for sy in 0 ..< sprite.height:
      let dstY = item.y + sy
      if dstY < 0 or dstY >= bot.map.height:
        continue
      for sx in 0 ..< sprite.width:
        let dstX = item.x + sx
        if dstX < 0 or dstX >= bot.map.width:
          continue
        let srcOffset = (sy * sprite.width + sx) * 4
        if sprite.pixels[srcOffset + 3] == 0:
          continue
        let dstOffset = (dstY * bot.map.width + dstX) * 4
        bot.map.pixels[dstOffset] = sprite.pixels[srcOffset]
        bot.map.pixels[dstOffset + 1] = sprite.pixels[srcOffset + 1]
        bot.map.pixels[dstOffset + 2] = sprite.pixels[srcOffset + 2]
        bot.map.pixels[dstOffset + 3] = sprite.pixels[srcOffset + 3]

proc rebuildPlayerFrame(bot: var Bot) =
  ## Rebuilds the bot's current player viewport from sprite objects.
  if bot.frameWidth <= 0 or bot.frameHeight <= 0:
    return
  bot.playerFrame = SpriteImage(
    width: bot.frameWidth,
    height: bot.frameHeight,
    label: "viewport",
    pixels: newSeq[uint8](bot.frameWidth * bot.frameHeight * 4)
  )
  for i in countup(0, bot.playerFrame.pixels.len - 4, 4):
    bot.playerFrame.pixels[i + 3] = 255'u8
  for item in bot.frameObjects.sortedObjects():
    if item.spriteId notin bot.sprites:
      continue
    bot.playerFrame.blitSprite(bot.sprites[item.spriteId], item.x, item.y)

proc updateOwnColor(bot: var Bot) =
  ## Finds this player's bright HSV color from the player frame.
  if bot.hasOwnColor or bot.playerFrame.pixels.len == 0:
    return
  var counts: seq[tuple[key: int, count: int]]
  for i in countup(0, bot.playerFrame.pixels.len - 4, 4):
    let color = (
      r: bot.playerFrame.pixels[i],
      g: bot.playerFrame.pixels[i + 1],
      b: bot.playerFrame.pixels[i + 2],
      a: bot.playerFrame.pixels[i + 3]
    )
    if not color.looksLikePlayerColor():
      continue
    let key = color.colorKey()
    var found = false
    for item in counts.mitems:
      if item.key == key:
        inc item.count
        found = true
        break
    if not found:
      counts.add((key: key, count: 1))
  var best = (key: 0, count: 0)
  for item in counts:
    if item.count > best.count:
      best = item
  if best.count >= 4:
    bot.ownColor = best.key.colorFromKey()
    bot.hasOwnColor = true
    echo "stacker color rgb=",
      bot.ownColor.r, ",", bot.ownColor.g, ",", bot.ownColor.b

proc applySpritePacket(
  bot: var Bot,
  packet: string,
  playerFrame: bool
): bool =
  ## Applies global protocol messages from a player or map socket.
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
        return false
      let image = SpriteImage(
        width: width,
        height: height,
        label: label,
        pixels: pixels
      )
      bot.sprites[spriteId] = image
      discard spriteId
    of 0x02:
      if offset + 11 > packet.len:
        return false
      let item = GlobalObject(
        id: packet.readU16(offset),
        x: packet.readI16(offset + 2),
        y: packet.readI16(offset + 4),
        z: packet.readI16(offset + 6),
        layer: packet[offset + 8].int,
        spriteId: packet.readU16(offset + 9)
      )
      offset += 11
      if playerFrame:
        bot.frameObjects[item.id] = item
      else:
        bot.objects[item.id] = item
    of 0x03:
      if offset + 2 > packet.len:
        return false
      if playerFrame:
        bot.frameObjects.del(packet.readU16(offset))
      else:
        bot.objects.del(packet.readU16(offset))
      offset += 2
    of 0x04:
      if playerFrame:
        bot.frameObjects.clear()
      else:
        bot.objects.clear()
    of 0x05:
      if offset + 5 > packet.len:
        return false
      if playerFrame:
        bot.frameWidth = packet.readU16(offset + 1)
        bot.frameHeight = packet.readU16(offset + 3)
      else:
        bot.mapWidth = packet.readU16(offset + 1)
        bot.mapHeight = packet.readU16(offset + 3)
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return false
      offset += 3
    else:
      return false
  if playerFrame:
    bot.rebuildPlayerFrame()
    bot.updateOwnColor()
  else:
    bot.rebuildGlobalMap()
  true

proc acceptServerMessage(
  ws: WebSocket,
  message: Message,
  bot: var Bot,
  playerFrame: bool
): bool =
  ## Handles one websocket message and updates bot sprite state.
  case message.kind
  of BinaryMessage:
    result = bot.applySpritePacket(message.data, playerFrame)
  of Ping:
    ws.send(message.data, Pong)
  of TextMessage, Pong:
    discard

proc receiveUpdates(
  ws: WebSocket,
  bot: var Bot,
  playerFrame: bool,
  timeout: int
): bool =
  ## Receives and applies queued sprite protocol updates.
  let firstMessage = ws.receiveMessage(timeout)
  if firstMessage.isNone:
    return false
  if ws.acceptServerMessage(firstMessage.get, bot, playerFrame):
    result = true
  var drained = 0
  while drained < MaxDrainMessages:
    let message = ws.receiveMessage(0)
    if message.isNone:
      break
    if ws.acceptServerMessage(message.get, bot, playerFrame):
      result = true
    inc drained

proc sameCell(a, b: Cell): bool =
  ## Returns true when two cells have the same coordinates.
  a.x == b.x and a.y == b.y

proc containsCell(cells: openArray[Cell], cell: Cell): bool =
  ## Returns true when a cell list contains one coordinate.
  for item in cells:
    if item.sameCell(cell):
      return true

proc sortCells(cells: var seq[Cell]) =
  ## Sorts cells from top to bottom, then left to right.
  cells.sort(proc(a, b: Cell): int =
    result = cmp(a.y, b.y)
    if result == 0:
      result = cmp(a.x, b.x)
  )

proc matchPiece(
  cells: openArray[Cell],
  kind: PieceKind,
  rotation: int,
  originX: var int,
  originY: var int
): bool =
  ## Matches four map cells against one piece rotation.
  if cells.len != 4:
    return false
  var
    minCellX = high(int)
    minCellY = high(int)
    minOffsetX = high(int)
    minOffsetY = high(int)
  let offsets = pieceCells(kind, rotation)
  for cell in cells:
    minCellX = min(minCellX, cell.x)
    minCellY = min(minCellY, cell.y)
  for offset in offsets:
    minOffsetX = min(minOffsetX, offset.x)
    minOffsetY = min(minOffsetY, offset.y)
  originX = minCellX - minOffsetX
  originY = minCellY - minOffsetY
  for offset in offsets:
    if not cells.containsCell(Cell(
      x: originX + offset.x,
      y: originY + offset.y
    )):
      return false
  true

proc inferPieceFromCells(cells: openArray[Cell]): ActivePiece =
  ## Infers the piece kind and rotation from four occupied cells.
  for kind in PieceKind:
    for rotation in 0 .. 3:
      var
        originX = 0
        originY = 0
      if cells.matchPiece(kind, rotation, originX, originY):
        return ActivePiece(
          found: true,
          kind: kind,
          rotation: rotation,
          originX: originX,
          originY: originY,
          cells: @cells
        )

proc findOwnCells(bot: Bot): seq[Cell] =
  ## Returns all global-map cells matching the bot's own color.
  if not bot.hasOwnColor or bot.map.pixels.len == 0:
    return
  for y in 0 ..< bot.map.height:
    for x in 0 ..< bot.map.width:
      if bot.map.rgbaAt(x, y).looksLikeOwnColor(bot.ownColor):
        result.add(Cell(x: x, y: y))

proc ownMaskIndex(image: SpriteImage, x, y: int): int =
  ## Returns a flat pixel index for the map.
  y * image.width + x

proc activePiece(bot: Bot): ActivePiece =
  ## Finds the highest own-color connected component as the active piece.
  let ownCells = bot.findOwnCells()
  if ownCells.len < 4 or bot.map.width <= 0 or bot.map.height <= 0:
    return
  var
    own = newSeq[bool](bot.map.width * bot.map.height)
    visited = newSeq[bool](bot.map.width * bot.map.height)
  for cell in ownCells:
    own[bot.map.ownMaskIndex(cell.x, cell.y)] = true

  var bestComponent: seq[Cell]
  var bestMinY = high(int)
  for cell in ownCells:
    let startIndex = bot.map.ownMaskIndex(cell.x, cell.y)
    if visited[startIndex]:
      continue
    var
      queue = @[cell]
      head = 0
      component: seq[Cell]
      minY = cell.y
    visited[startIndex] = true
    while head < queue.len:
      let current = queue[head]
      inc head
      component.add(current)
      minY = min(minY, current.y)
      for delta in [Cell(x: -1, y: 0), Cell(x: 1, y: 0),
          Cell(x: 0, y: -1), Cell(x: 0, y: 1)]:
        let next = Cell(x: current.x + delta.x, y: current.y + delta.y)
        if next.x < 0 or next.y < 0 or
            next.x >= bot.map.width or next.y >= bot.map.height:
          continue
        let index = bot.map.ownMaskIndex(next.x, next.y)
        if not own[index] or visited[index]:
          continue
        visited[index] = true
        queue.add(next)
    if component.len >= 4 and minY < bestMinY:
      bestMinY = minY
      bestComponent = component

  if bestComponent.len < 4:
    return
  bestComponent.sortCells()
  if bestComponent.len > 4:
    bestComponent.setLen(4)
  inferPieceFromCells(bestComponent)

proc occupiedMap(bot: var Bot, active: ActivePiece): seq[bool] =
  ## Builds an occupancy grid with the active piece removed.
  result = newSeq[bool](bot.map.width * bot.map.height)
  for y in 0 ..< bot.map.height:
    for x in 0 ..< bot.map.width:
      let color = bot.map.rgbaAt(x, y)
      result[bot.map.ownMaskIndex(x, y)] = not color.isBackground()
  for cell in active.cells:
    if cell.x >= 0 and cell.y >= 0 and
        cell.x < bot.map.width and cell.y < bot.map.height:
      result[bot.map.ownMaskIndex(cell.x, cell.y)] = false
  bot.logicalTerrain = result
  bot.logicalWidth = bot.map.width
  bot.logicalHeight = bot.map.height

proc isOccupied(occupied: openArray[bool], width, height, x, y: int): bool =
  ## Returns true when a map cell is blocked.
  if x < 0 or x >= width or y >= height:
    return true
  if y < 0:
    return false
  occupied[y * width + x]

proc canPlace(
  occupied: openArray[bool],
  width,
  height,
  x,
  y: int,
  kind: PieceKind,
  rotation: int
): bool =
  ## Returns true when a piece can be placed at one origin.
  for cell in pieceCells(kind, rotation):
    if occupied.isOccupied(width, height, x + cell.x, y + cell.y):
      return false
  true

proc rowCount(occupied: openArray[bool], width, row, startX: int): int =
  ## Counts filled cells in one eight-wide scoring segment.
  for x in startX ..< startX + LineClearLength:
    if occupied[row * width + x]:
      inc result

proc inLane(x: int): bool =
  ## Returns true when a column is inside the target clearing lane.
  x >= LaneStartX and x < LaneStartX + LineClearLength

proc playfieldBottom(height: int): int =
  ## Returns the last playable row above the fixed floor line.
  min(BaseTerrainY - 1, height - 2)

proc occupiedAt(
  occupied: openArray[bool],
  width,
  height,
  x,
  y: int
): bool =
  ## Returns true when an in-bounds map cell is occupied.
  if x < 0 or y < 0 or x >= width or y >= height:
    return false
  occupied[y * width + x]

proc supportedGap(
  occupied: openArray[bool],
  width,
  height,
  x,
  y: int
): bool =
  ## Returns true when an empty lane cell can be usefully filled.
  if not x.inLane() or y < 0 or y > height.playfieldBottom:
    return false
  if occupied.occupiedAt(width, height, x, y):
    return false
  if y == height.playfieldBottom:
    return true
  occupied.occupiedAt(width, height, x, y + 1)

proc cellGapScore(
  occupied: openArray[bool],
  width,
  height,
  x,
  y: int
): int =
  ## Scores how much one candidate cell fills a useful gap.
  if not occupied.supportedGap(width, height, x, y):
    return 0
  let
    leftFilled = x == LaneStartX or
      occupied.occupiedAt(width, height, x - 1, y)
    rightFilled = x == LaneStartX + LineClearLength - 1 or
      occupied.occupiedAt(width, height, x + 1, y)
  result += SupportedGapBonus
  if leftFilled and rightFilled:
    result += PocketFillBonus
  elif leftFilled or rightFilled:
    result += PocketFillBonus div 2

proc laneHoles(occupied: openArray[bool], width, height: int): int =
  ## Counts covered holes in the target lane.
  let bottomRow = height.playfieldBottom
  for x in LaneStartX ..< LaneStartX + LineClearLength:
    var seenBlock = false
    for y in 0 .. bottomRow:
      if occupied.occupiedAt(width, height, x, y):
        seenBlock = true
      elif seenBlock:
        inc result

proc columnTop(occupied: openArray[bool], width, height, x: int): int =
  ## Returns the first occupied row in one target lane column.
  let bottomRow = height.playfieldBottom
  for y in 0 .. bottomRow:
    if occupied.occupiedAt(width, height, x, y):
      return y
  bottomRow + 1

proc aggregateLaneHeight(
  occupied: openArray[bool],
  width,
  height: int
): int =
  ## Counts the total pile height across the target lane.
  let bottomRow = height.playfieldBottom
  for x in LaneStartX ..< LaneStartX + LineClearLength:
    result += bottomRow + 1 - occupied.columnTop(width, height, x)

proc laneBumpiness(occupied: openArray[bool], width, height: int): int =
  ## Counts adjacent column height differences in the target lane.
  let bottomRow = height.playfieldBottom
  var previous = bottomRow + 1 -
    occupied.columnTop(width, height, LaneStartX)
  for x in LaneStartX + 1 ..< LaneStartX + LineClearLength:
    let current = bottomRow + 1 - occupied.columnTop(width, height, x)
    result += abs(current - previous)
    previous = current

proc rowPotential(
  occupied: openArray[bool],
  width,
  height,
  row: int
): int =
  ## Scores how promising one row is for the next placement.
  if row < 0 or row > height.playfieldBottom:
    return low(int)
  let filled = occupied.rowCount(width, row, LaneStartX)
  if filled >= LineClearLength:
    return low(int)
  for x in LaneStartX ..< LaneStartX + LineClearLength:
    if occupied.supportedGap(width, height, x, row):
      result += 350
  result += filled * 120
  result -= abs(height.playfieldBottom - row) * 3

proc targetHoleRow(occupied: openArray[bool], width, height: int): int =
  ## Finds the most useful incomplete row in the central lane.
  let bottomRow = height.playfieldBottom
  var bestScore = low(int)
  result = bottomRow
  for y in countdown(bottomRow, 0):
    let score = occupied.rowPotential(width, height, y)
    if score > bestScore:
      bestScore = score
      result = y
  if bestScore == low(int):
    result = bottomRow

proc placedCells(x, y: int, kind: PieceKind, rotation: int): seq[Cell] =
  ## Returns absolute cells for one candidate placement.
  for cell in pieceCells(kind, rotation):
    result.add(Cell(x: x + cell.x, y: y + cell.y))

proc scorePlacement(
  occupied: openArray[bool],
  width,
  height: int,
  active: ActivePiece,
  placement: Placement,
  targetRow: int
): int =
  ## Scores a candidate by filling gaps and avoiding covered holes.
  var test = newSeq[bool](occupied.len)
  for i in 0 ..< occupied.len:
    test[i] = occupied[i]
  let
    beforeHoles = occupied.laneHoles(width, height)
    beforeBumpiness = occupied.laneBumpiness(width, height)
    beforeHeight = occupied.aggregateLaneHeight(width, height)
  let cells = placedCells(
    placement.x,
    placement.y,
    active.kind,
    placement.rotation
  )
  for cell in cells:
    if cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height:
      test[cell.y * width + cell.x] = true
      if cell.x.inLane:
        result += 300
        result += occupied.cellGapScore(width, height, cell.x, cell.y)
      else:
        result -= OutsideLanePenalty
      result -= abs(cell.y - targetRow) * 6
      result += cell.y div 2

  var rows: seq[int]
  for cell in cells:
    if cell.y < 0 or cell.y >= height - 1:
      continue
    if cell.y in rows:
      continue
    rows.add(cell.y)
    let
      before = occupied.rowCount(width, cell.y, LaneStartX)
      after = test.rowCount(width, cell.y, LaneStartX)
    if after >= LineClearLength:
      result += RowCompletionBonus
    if cell.y == targetRow:
      result += (after - before) * 800
    result += (after - before) * 950
    result += after * 80

  let
    afterHoles = test.laneHoles(width, height)
    afterBumpiness = test.laneBumpiness(width, height)
    afterHeight = test.aggregateLaneHeight(width, height)
  if afterHoles <= beforeHoles:
    result += (beforeHoles - afterHoles) * HoleReductionBonus
  else:
    result -= (afterHoles - beforeHoles) * HoleIncreasePenalty
  if afterBumpiness <= beforeBumpiness:
    result += (beforeBumpiness - afterBumpiness) * BumpinessPenalty
  else:
    result -= (afterBumpiness - beforeBumpiness) * BumpinessPenalty
  result -= max(0, afterHeight - beforeHeight) * HeightPenalty

proc choosePlacement(bot: var Bot, active: ActivePiece): Placement =
  ## Chooses where the current piece should land.
  if not active.found or bot.map.pixels.len == 0:
    return
  let occupied = bot.occupiedMap(active)
  bot.targetRow = occupied.targetHoleRow(bot.map.width, bot.map.height)
  for rotation in 0 .. 3:
    for x in LaneStartX - 6 .. LaneStartX + LineClearLength + 4:
      var y = max(0, active.originY)
      if not occupied.canPlace(
        bot.map.width,
        bot.map.height,
        x,
        y,
        active.kind,
        rotation
      ):
        continue
      while occupied.canPlace(
        bot.map.width,
        bot.map.height,
        x,
        y + 1,
        active.kind,
        rotation
      ):
        inc y
      var candidate = Placement(
        found: true,
        rotation: rotation,
        x: x,
        y: y
      )
      candidate.score = occupied.scorePlacement(
        bot.map.width,
        bot.map.height,
        active,
        candidate,
        bot.targetRow
      )
      if not result.found or candidate.score > result.score:
        result = candidate
  bot.target = result

proc maskSummary(mask: uint8): string =
  ## Returns a compact debug string for pressed controls.
  if (mask and ButtonUp) != 0:
    result.add("U")
  if (mask and ButtonDown) != 0:
    result.add("D")
  if (mask and ButtonLeft) != 0:
    result.add("L")
  if (mask and ButtonRight) != 0:
    result.add("R")
  if (mask and ButtonSelect) != 0:
    result.add("S")
  if (mask and ButtonA) != 0:
    result.add("A")
  if result.len == 0:
    result = "."

proc decideMask(bot: var Bot): uint8 =
  ## Chooses the next held button mask.
  bot.active = ActivePiece()
  bot.target = Placement()
  if not bot.hasOwnColor or bot.map.pixels.len == 0:
    bot.intent = "waiting"
    return ButtonDown
  let active = bot.activePiece()
  if not active.found:
    bot.intent = "finding piece"
    return ButtonDown
  bot.active = active
  let placement = bot.choosePlacement(active)
  if not placement.found:
    bot.intent = "dropping"
    return ButtonDown

  if active.rotation != placement.rotation:
    bot.intent = "rotate"
    if (bot.lastMask and ButtonA) == 0:
      return ButtonA
    return 0

  if active.originX < placement.x:
    bot.intent = "right"
    return ButtonRight
  if active.originX > placement.x:
    bot.intent = "left"
    return ButtonLeft

  bot.intent = "fill row " & $bot.targetRow
  result = ButtonDown
  if active.originY >= placement.y - 1:
    result = result or ButtonSelect

proc echoDebug(bot: Bot, mask: uint8) =
  ## Prints one periodic debug line.
  if bot.frameTick mod DebugInterval != 0:
    return
  echo "step=", bot.frameTick,
    " keys=", mask.maskSummary(),
    " intent=", bot.intent,
    " targetRow=", bot.targetRow,
    " target=", bot.target.x, ",", bot.target.y,
    " rot=", bot.target.rotation,
    " score=", bot.target.score

proc ownActiveViewportCells(bot: Bot): seq[Cell] =
  ## Returns screen-space cells for the bot's visible active piece.
  if not bot.hasOwnColor:
    return
  for item in bot.frameObjects.values:
    if item.z < 30 or item.z >= 40:
      continue
    if item.spriteId notin bot.sprites:
      continue
    let color = bot.sprites[item.spriteId].representativeColor()
    if not color.looksLikeOwnColor(bot.ownColor):
      continue
    let cell = Cell(x: item.x, y: item.y)
    if not result.containsCell(cell):
      result.add(cell)

proc viewportCamera(bot: Bot): tuple[found: bool, cameraX: int, cameraY: int] =
  ## Infers the viewport camera from active world and screen cells.
  if not bot.active.found:
    return
  let screenCells = bot.ownActiveViewportCells()
  if screenCells.len == 0:
    return
  for worldCell in bot.active.cells:
    for screenCell in screenCells:
      let
        cameraX = worldCell.x * CellPixels - screenCell.x
        cameraY = worldCell.y * CellPixels - screenCell.y
      var matches = 0
      for activeCell in bot.active.cells:
        let expected = Cell(
          x: activeCell.x * CellPixels - cameraX,
          y: activeCell.y * CellPixels - cameraY
        )
        if screenCells.containsCell(expected):
          inc matches
      if matches == bot.active.cells.len:
        return (found: true, cameraX: cameraX, cameraY: cameraY)

when defined(botHeadless):
  proc initViewerApp(): ViewerApp =
    ## Builds a headless placeholder viewer.
    ViewerApp()

  proc viewerOpen(viewer: ViewerApp): bool =
    ## Returns true while the bot should keep running.
    true

  proc pumpViewer(
    viewer: ViewerApp,
    bot: Bot,
    connected: bool,
    url: string
  ) =
    ## Ignores viewer updates in headless builds.
    discard
else:
  proc gameDir(): string =
    ## Returns the Infinite Blocks game directory.
    let
      sourceDir = currentSourcePath().parentDir().parentDir().parentDir()
      cwd = getCurrentDir()
      candidates = [
        sourceDir,
        cwd,
        cwd.parentDir(),
        cwd.parentDir().parentDir()
      ]
    for candidate in candidates:
      if fileExists(candidate / "infinite_blocks.nim"):
        return candidate
    sourceDir

  proc atlasPath(): string =
    ## Returns the shared Silky atlas path.
    gameDir() / ".." / "clients" / "dist" / "atlas.png"

  proc viewerOpen(viewer: ViewerApp): bool =
    ## Returns true while the diagnostic viewer should stay open.
    viewer.isNil or not viewer.window.closeRequested

  proc refreshDisplayScale(viewer: ViewerApp) =
    ## Updates viewer UI scaling after moving between displays.
    if viewer.isNil:
      return
    let scale = viewer.window.displayScale()
    if abs(scale - viewer.contentScale) <= 0.001'f:
      return
    viewer.contentScale = scale
    viewer.silky.uiScale = scale
    let logicalSize = (viewer.window.size.vec2 / scale).ivec2
    viewer.window.size = logicalSize.scaledWindowSize(scale)

  proc viewerColor(color: RgbaColor): ColorRGBX =
    ## Converts an RGBA tuple to a viewer color.
    rgbx(color.r, color.g, color.b, color.a)

  proc drawOutline(
    sk: Silky,
    pos,
    size: Vec2,
    color: ColorRGBX,
    thickness = 1.0'f
  ) =
    ## Draws an unfilled rectangle.
    sk.drawRect(pos, vec2(size.x, thickness), color)
    sk.drawRect(
      vec2(pos.x, pos.y + size.y - thickness),
      vec2(size.x, thickness),
      color
    )
    sk.drawRect(pos, vec2(thickness, size.y), color)
    sk.drawRect(
      vec2(pos.x + size.x - thickness, pos.y),
      vec2(thickness, size.y),
      color
    )

  proc drawLogicalCell(
    sk: Silky,
    origin: Vec2,
    cell: Cell,
    color: ColorRGBX,
    scale = ViewerMapScale
  ) =
    ## Draws one bot-logical board cell.
    sk.drawRect(
      vec2(
        origin.x + cell.x.float32 * scale + ViewerCellPad,
        origin.y + cell.y.float32 * scale + ViewerCellPad
      ),
      vec2(
        max(1.0'f, scale - ViewerCellPad * 2),
        max(1.0'f, scale - ViewerCellPad * 2)
      ),
      color
    )

  proc drawLogicalTerrain(sk: Silky, bot: Bot, origin: Vec2) =
    ## Draws the bot's logical terrain, active piece, and target.
    let
      width = max(1, bot.logicalWidth)
      height = max(1, bot.logicalHeight)
      scale = ViewerMapScale
      boardSize = vec2(width.float32 * scale, height.float32 * scale)
    sk.drawRect(origin, boardSize, ViewerPanelAlt)
    sk.drawRect(
      vec2(origin.x + LaneStartX.float32 * scale, origin.y),
      vec2(LineClearLength.float32 * scale, boardSize.y),
      ViewerLane
    )
    for x in countup(0, width, 10):
      sk.drawRect(
        vec2(origin.x + x.float32 * scale, origin.y),
        vec2(1, boardSize.y),
        ViewerGrid
      )
    for y in countup(0, height, 10):
      sk.drawRect(
        vec2(origin.x, origin.y + y.float32 * scale),
        vec2(boardSize.x, 1),
        ViewerGrid
      )
    if bot.logicalTerrain.len == width * height:
      for y in 0 ..< height:
        for x in 0 ..< width:
          if not bot.logicalTerrain[y * width + x]:
            continue
          let color =
            if y == BaseTerrainY:
              ViewerTerrain
            else:
              ViewerSettled
          sk.drawLogicalCell(origin, Cell(x: x, y: y), color)
    if bot.target.found:
      for cell in placedCells(
        bot.target.x,
        bot.target.y,
        bot.active.kind,
        bot.target.rotation
      ):
        sk.drawLogicalCell(origin, cell, ViewerTarget)
        sk.drawOutline(
          vec2(
            origin.x + cell.x.float32 * scale,
            origin.y + cell.y.float32 * scale
          ),
          vec2(scale, scale),
          ViewerBackground
        )
    if bot.active.found:
      for cell in bot.active.cells:
        sk.drawLogicalCell(origin, cell, ViewerActive)

  proc drawViewportCell(
    sk: Silky,
    origin: Vec2,
    screenX,
    screenY: int,
    color: ColorRGBX
  ) =
    ## Draws an outline around one cell in the player viewport.
    let scale = ViewerViewportScale
    sk.drawOutline(
      vec2(
        origin.x + screenX.float32 * scale,
        origin.y + screenY.float32 * scale
      ),
      vec2(CellPixels.float32 * scale, CellPixels.float32 * scale),
      color,
      2.0'f
    )

  proc drawViewport(sk: Silky, bot: Bot, origin: Vec2) =
    ## Draws the live player viewport and bot overlays.
    let
      width = max(1, bot.playerFrame.width)
      height = max(1, bot.playerFrame.height)
      scale = ViewerViewportScale
      size = vec2(width.float32 * scale, height.float32 * scale)
    sk.drawRect(origin, size, ViewerPanelAlt)
    if bot.playerFrame.pixels.len == width * height * 4:
      for y in 0 ..< height:
        for x in 0 ..< width:
          let color = bot.playerFrame.rgbaAt(x, y)
          if color.a == 0'u8:
            continue
          sk.drawRect(
            vec2(origin.x + x.float32 * scale, origin.y + y.float32 * scale),
            vec2(scale, scale),
            color.viewerColor()
          )

    let camera = bot.viewportCamera()
    if not camera.found:
      return
    if bot.target.found:
      for cell in placedCells(
        bot.target.x,
        bot.target.y,
        bot.active.kind,
        bot.target.rotation
      ):
        sk.drawViewportCell(
          origin,
          cell.x * CellPixels - camera.cameraX,
          cell.y * CellPixels - camera.cameraY,
          ViewerTarget
        )
    if bot.active.found:
      for cell in bot.active.cells:
        sk.drawViewportCell(
          origin,
          cell.x * CellPixels - camera.cameraX,
          cell.y * CellPixels - camera.cameraY,
          ViewerActive
        )

  proc initViewerApp(): ViewerApp =
    ## Opens the stacker diagnostic viewer window.
    result = ViewerApp()
    result.window = newWindow(
      title = "Infinite Blocks Stacker Viewer",
      size = ivec2(ViewerWindowWidth, ViewerWindowHeight),
      style = DecoratedResizable,
      visible = true
    )
    makeContextCurrent(result.window)
    when not defined(useDirectX):
      loadExtensions()
    result.silky = newSilky(result.window, atlasPath())
    result.contentScale = result.window.displayScale()
    result.silky.uiScale = result.contentScale
    result.window.size =
      ivec2(ViewerWindowWidth, ViewerWindowHeight).
        scaledWindowSize(result.contentScale)

  proc pumpViewer(
    viewer: ViewerApp,
    bot: Bot,
    connected: bool,
    url: string
  ) =
    ## Pumps and renders one diagnostic viewer frame.
    if viewer.isNil:
      return
    pollEvents()
    if viewer.window.buttonPressed[KeyEscape]:
      viewer.window.closeRequested = true
    if viewer.window.closeRequested:
      return
    viewer.refreshDisplayScale()
    let
      frameSize = viewer.window.size
      logicalWidth = frameSize.x.float32 / viewer.silky.uiScale
      logicalHeight = frameSize.y.float32 / viewer.silky.uiScale
      viewportPos = vec2(ViewerMargin, ViewerMargin + 28)
      viewportSize = vec2(
        max(1, bot.playerFrame.width).float32 * ViewerViewportScale,
        max(1, bot.playerFrame.height).float32 * ViewerViewportScale
      )
      mapPos = vec2(
        viewportPos.x + viewportSize.x + 32,
        ViewerMargin + 28
      )
      mapSize = vec2(
        BoardWidthCells.float32 * ViewerMapScale,
        BoardHeightCells.float32 * ViewerMapScale
      )
      infoPos = vec2(mapPos.x, mapPos.y + mapSize.y + 32)
      infoSize = vec2(
        logicalWidth - infoPos.x - ViewerMargin,
        logicalHeight - infoPos.y - ViewerMargin
      )
      sk = viewer.silky
    sk.beginUi(viewer.window, frameSize)
    sk.clearScreen(ViewerBackground)
    discard sk.drawText(
      "Default",
      "Infinite Blocks Stacker",
      vec2(ViewerMargin, ViewerMargin),
      ViewerText
    )
    discard sk.drawText(
      "Default",
      "Live viewport",
      vec2(viewportPos.x, viewportPos.y - 18),
      ViewerMutedText
    )
    discard sk.drawText(
      "Default",
      "Logical map",
      vec2(mapPos.x, mapPos.y - 18),
      ViewerMutedText
    )
    sk.drawRect(
      viewportPos - vec2(8, 8),
      viewportSize + vec2(16, 16),
      ViewerPanel
    )
    sk.drawRect(mapPos - vec2(8, 8), mapSize + vec2(16, 16), ViewerPanel)
    sk.drawRect(infoPos - vec2(8, 8), infoSize + vec2(16, 16), ViewerPanel)
    sk.drawViewport(bot, viewportPos)
    sk.drawLogicalTerrain(bot, mapPos)
    let
      activeText =
        if bot.active.found:
          $bot.active.kind & " rot=" & $bot.active.rotation &
            " origin=" & $bot.active.originX & "," & $bot.active.originY
        else:
          "none"
      targetText =
        if bot.target.found:
          "rot=" & $bot.target.rotation &
            " origin=" & $bot.target.x & "," & $bot.target.y &
            " score=" & $bot.target.score
        else:
          "none"
      infoText =
        "status: " & (if connected: "connected" else: "reconnecting") &
          "\n" &
        "tick: " & $bot.frameTick & "\n" &
        "intent: " & bot.intent & "\n" &
        "keys: " & bot.lastMask.maskSummary() & "\n" &
        "own color known: " & $bot.hasOwnColor & "\n" &
        "map scale: " & $bot.mapScale & "\n" &
        "logical size: " & $bot.logicalWidth & "x" &
          $bot.logicalHeight & "\n" &
        "active: " & activeText & "\n" &
        "target row: " & $bot.targetRow & "\n" &
        "target: " & targetText & "\n" &
        "lane x: " & $LaneStartX & ".." &
          $(LaneStartX + LineClearLength - 1) & "\n" &
        "legend:\n" &
        "  gray = floor\n" &
        "  blue = settled terrain\n" &
        "  green = active piece\n" &
        "  yellow = planned placement\n" &
        "url: " & url
    discard sk.drawText(
      "Default",
      infoText,
      infoPos,
      ViewerText,
      infoSize.x,
      infoSize.y
    )
    sk.endUi()
    viewer.window.swapBuffers()

proc setQueryParam(query, key, value: string): string =
  ## Returns a query string with one encoded parameter replaced or appended.
  if value.len == 0:
    return query
  let encoded = key & "=" & value.queryEscape()
  var found = false
  for part in query.split('&'):
    if part.len == 0:
      continue
    let equals = part.find('=')
    let partKey =
      if equals >= 0:
        part[0 ..< equals]
      else:
        part
    if result.len > 0:
      result.add('&')
    if partKey == key:
      result.add(encoded)
      found = true
    else:
      result.add(part)
  if not found:
    if result.len > 0:
      result.add('&')
    result.add(encoded)

proc ensurePlayerPath(url: string): string =
  ## Adds the player path when an injected URL contains only scheme and host.
  let scheme = url.find("://")
  let start =
    if scheme >= 0:
      scheme + 3
    else:
      0
  for i in start ..< url.len:
    if url[i] == '/':
      if url.endsWith("/sprite_player"):
        return url[0 ..< url.len - "/sprite_player".len] &
          PlayerWebSocketPath
      return url
  url & PlayerWebSocketPath

proc normalizePlayerUrl(
  url,
  name: string,
  slot: int,
  token: string
): string =
  ## Normalizes a player WebSocket URL and merges player auth parameters.
  var
    base = url
    query = ""
    fragment = ""
  let hash = base.find('#')
  if hash >= 0:
    fragment = base[hash .. ^1]
    base = base[0 ..< hash]
  let question = base.find('?')
  if question >= 0:
    query = base[question + 1 .. ^1]
    base = base[0 ..< question]
  base = base.ensurePlayerPath()
  query = query.setQueryParam("name", name)
  if slot >= 0:
    query = query.setQueryParam("slot", $slot)
  query = query.setQueryParam("token", token)
  result = base
  if query.len > 0:
    result.add('?')
    result.add(query)
  result.add(fragment)

proc spriteUrl(
  host: string,
  port: int,
  name: string,
  slot: int,
  token: string
): string =
  ## Builds the default player websocket URL.
  let playerName =
    if name.len > 0:
      name
    else:
      "stacker"
  normalizePlayerUrl(
    "ws://" & host & ":" & $port & PlayerWebSocketPath,
    playerName,
    slot,
    token
  )

proc deriveGlobalUrl(playerUrl: string): string =
  ## Derives a global URL from an explicit player URL.
  var parsed = parseUri(playerUrl)
  parsed.path = GlobalWebSocketPath
  parsed.query = ""
  $parsed

proc isWebSocketUrl(value: string): bool =
  ## Returns true when a value is a complete WebSocket URL.
  value.startsWith("ws://") or value.startsWith("wss://")

proc redactedUrl(url: string): string =
  ## Returns a log-safe WebSocket URL.
  const Key = "token="
  let tokenStart = url.find(Key)
  if tokenStart < 0:
    return url
  let valueStart = tokenStart + Key.len
  var valueEnd = valueStart
  while valueEnd < url.len and url[valueEnd] notin {'&', '#'}:
    inc valueEnd
  let suffix =
    if valueEnd < url.len:
      url[valueEnd .. ^1]
    else:
      ""
  url[0 ..< valueStart] & "<redacted>" & suffix

proc initBot(): Bot =
  ## Builds the initial bot state.
  result.rng = initRand(getTime().toUnix() xor int64(getCurrentProcessId()))
  result.sprites = initTable[int, SpriteImage]()
  result.frameObjects = initTable[int, GlobalObject]()
  result.objects = initTable[int, GlobalObject]()
  result.lastMask = 0xff'u8
  result.targetRow = BaseTerrainY - 1

proc runBot(
  address = DefaultPlayerAddress,
  name = "",
  token = "",
  slot = -1,
  maxSteps = 0,
  gui = false
) =
  ## Connects to Infinite Blocks and plays through sprite protocol.
  let
    playerUrl = address.normalizePlayerUrl(name, slot, token)
    mapUrl = address.deriveGlobalUrl()
  echo "stacker player websocket: ", playerUrl.redactedUrl()
  echo "stacker global websocket: ", mapUrl.redactedUrl()
  flushFile(stdout)
  var
    bot = initBot()
    viewer =
      if gui:
        initViewerApp()
      else:
        nil
    connected = false

  while viewer.viewerOpen():
    try:
      bot = initBot()
      let
        playerWs = newWebSocket(playerUrl)
        globalWs = newWebSocket(mapUrl)
      connected = true
      playerWs.send(chatBlob("stacker online"), BinaryMessage)
      discard playerWs.receiveUpdates(bot, true, -1)
      discard globalWs.receiveUpdates(bot, false, -1)
      var lastMask = 0xff'u8
      while viewer.viewerOpen():
        if gui:
          viewer.pumpViewer(bot, connected, playerUrl)
          if not viewer.viewerOpen():
            playerWs.close()
            globalWs.close()
            return
        if not globalWs.receiveUpdates(bot, false, if gui: 10 else: -1):
          continue
        inc bot.frameTick
        discard playerWs.receiveUpdates(bot, true, 0)
        let nextMask = bot.decideMask()
        bot.echoDebug(nextMask)
        bot.lastMask = nextMask
        if nextMask != lastMask:
          playerWs.send(inputBlob(nextMask), BinaryMessage)
          lastMask = nextMask
        if maxSteps > 0 and bot.frameTick >= maxSteps:
          playerWs.close()
          globalWs.close()
          return
        if gui:
          viewer.pumpViewer(bot, connected, playerUrl)
    except CatchableError as e:
      echo "stacker reconnecting: ", e.msg
      connected = false
      if gui:
        let startTime = epochTime()
        while viewer.viewerOpen() and epochTime() - startTime < 0.25:
          viewer.pumpViewer(bot, connected, playerUrl)
          sleep(10)
      else:
        sleep(250)

when isMainModule:
  var
    address = getEnv(EngineWsEnv)
    name = ""
    token = ""
    slot = -1
    maxSteps = 0
    gui = false
    legacyPort = 0
  if address.len == 0:
    address = DefaultPlayerAddress
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address", "url", "player-url", "socket":
        address = val
      of "port":
        legacyPort = parseInt(val)
      of "name":
        name = val
      of "token":
        token = val
      of "slot":
        slot = parseInt(val)
      of "max-steps":
        maxSteps = parseInt(val)
      of "gui":
        gui = true
      else:
        discard
    of cmdShortOption:
      case key
      of "p":
        raise newException(
          ValueError,
          "Use --address:ws://host:port/player instead of -p."
        )
      else:
        discard
    else:
      discard
  if not address.isWebSocketUrl():
    if legacyPort > 0:
      address = spriteUrl(address, legacyPort, name, slot, token)
      name = ""
      token = ""
      slot = -1
    else:
      raise newException(
        ValueError,
        "--address must be a full WebSocket URL like ws://localhost:8080/player."
      )
  runBot(address, name, token, slot, maxSteps, gui)

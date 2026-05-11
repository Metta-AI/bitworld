import
  std/[algorithm, os, parseopt, random, strutils, tables, times, uri],
  supersnappy, whisky,
  protocol

const
  PlayerDefaultPort = 2000
  PlayerWebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  BoardWidthCells = 250
  BoardHeightCells = 250
  BaseTerrainY = BoardHeightCells * 31 div 50
  LineClearLength = 8
  LaneStartX = BoardWidthCells div 2 - LineClearLength div 2
  MaxDrainMessages = 64
  DebugInterval = 60
  BrightMinChannel = 30
  BrightMaxChannel = 70

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
    sprites: Table[int, SpriteImage]
    objects: Table[int, GlobalObject]
    mapWidth: int
    mapHeight: int
    ownColor: RgbaColor
    hasOwnColor: bool
    lastMask: uint8
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

proc rebuildGlobalMap(bot: var Bot) =
  ## Rebuilds a dense map image from global protocol sprites and objects.
  if bot.mapWidth <= 0 or bot.mapHeight <= 0:
    return
  bot.map = SpriteImage(
    width: bot.mapWidth,
    height: bot.mapHeight,
    label: "global",
    pixels: newSeq[uint8](bot.mapWidth * bot.mapHeight * 4)
  )
  for i in countup(0, bot.map.pixels.len - 4, 4):
    bot.map.pixels[i + 3] = 255'u8

  var items: seq[GlobalObject] = @[]
  for item in bot.objects.values:
    items.add(item)
  items.sort(proc(a, b: GlobalObject): int =
    result = cmp(a.z, b.z)
    if result == 0:
      result = cmp(a.y, b.y)
    if result == 0:
      result = cmp(a.id, b.id)
  )

  for item in items:
    if item.spriteId notin bot.sprites:
      continue
    let sprite = bot.sprites[item.spriteId]
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
      if playerFrame:
        bot.playerFrame = image
        bot.updateOwnColor()
      else:
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
      if not playerFrame:
        bot.objects[item.id] = item
    of 0x03:
      if offset + 2 > packet.len:
        return false
      if not playerFrame:
        bot.objects.del(packet.readU16(offset))
      offset += 2
    of 0x04:
      if not playerFrame:
        bot.objects.clear()
    of 0x05:
      if offset + 5 > packet.len:
        return false
      if not playerFrame:
        bot.mapWidth = packet.readU16(offset + 1)
        bot.mapHeight = packet.readU16(offset + 3)
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return false
      offset += 3
    else:
      return false
  if not playerFrame:
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
      if bot.map.rgbaAt(x, y) == bot.ownColor:
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

proc occupiedMap(bot: Bot, active: ActivePiece): seq[bool] =
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

proc targetHoleRow(occupied: openArray[bool], width, height: int): int =
  ## Finds the lowest incomplete row in the central eight-wide lane.
  let bottomRow = min(BaseTerrainY - 1, height - 2)
  for y in countdown(bottomRow, 0):
    if occupied.rowCount(width, y, LaneStartX) < LineClearLength:
      return y
  bottomRow

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
  ## Scores a candidate by filling holes in an eight-cell lane.
  var test = newSeq[bool](occupied.len)
  for i in 0 ..< occupied.len:
    test[i] = occupied[i]
  let cells = placedCells(
    placement.x,
    placement.y,
    active.kind,
    placement.rotation
  )
  for cell in cells:
    if cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height:
      test[cell.y * width + cell.x] = true
      if cell.x >= LaneStartX and cell.x < LaneStartX + LineClearLength:
        result += 300
      else:
        result -= 600
      result -= abs(cell.y - targetRow) * 4
      result += cell.y

  for cell in cells:
    if cell.y < 0 or cell.y >= height - 1:
      continue
    let
      before = occupied.rowCount(width, cell.y, LaneStartX)
      after = test.rowCount(width, cell.y, LaneStartX)
    if after >= LineClearLength:
      result += 20000
    result += (after - before) * 700
    result += after * 80

  for x in LaneStartX ..< LaneStartX + LineClearLength:
    var seenBlock = false
    for y in 0 ..< height - 1:
      if test[y * width + x]:
        seenBlock = true
      elif seenBlock:
        result -= 80

proc choosePlacement(bot: var Bot, active: ActivePiece): Placement =
  ## Chooses where the current piece should land.
  if not active.found or bot.map.pixels.len == 0:
    return
  let occupied = bot.occupiedMap(active)
  bot.targetRow = occupied.targetHoleRow(bot.map.width, bot.map.height)
  for rotation in 0 .. 3:
    for x in LaneStartX - 4 .. LaneStartX + LineClearLength:
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
  if not bot.hasOwnColor or bot.map.pixels.len == 0:
    bot.intent = "waiting"
    return ButtonDown
  let active = bot.activePiece()
  if not active.found:
    bot.intent = "finding piece"
    return ButtonDown
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

proc spriteUrl(host: string, port: int, name: string): string =
  ## Builds the default player websocket URL.
  result = "ws://" & host & ":" & $port & PlayerWebSocketPath
  if name.len > 0:
    result.add("?name=" & name.queryEscape())

proc globalUrl(host: string, port: int): string =
  ## Builds the default global websocket URL.
  "ws://" & host & ":" & $port & GlobalWebSocketPath

proc deriveGlobalUrl(playerUrl: string): string =
  ## Derives a global URL from an explicit player URL.
  var parsed = parseUri(playerUrl)
  parsed.path = GlobalWebSocketPath
  parsed.query = ""
  $parsed

proc initBot(): Bot =
  ## Builds the initial bot state.
  result.rng = initRand(getTime().toUnix() xor int64(getCurrentProcessId()))
  result.sprites = initTable[int, SpriteImage]()
  result.objects = initTable[int, GlobalObject]()
  result.lastMask = 0xff'u8
  result.targetRow = BaseTerrainY - 1

proc runBot(
  host = "localhost",
  port = PlayerDefaultPort,
  name = "stacker",
  explicitUrl = "",
  maxSteps = 0
) =
  ## Connects to Infinite Blocks and plays through sprite protocol.
  let
    playerUrl =
      if explicitUrl.len > 0:
        explicitUrl
      else:
        spriteUrl(host, port, name)
    mapUrl =
      if explicitUrl.len > 0:
        explicitUrl.deriveGlobalUrl()
      else:
        globalUrl(host, port)

  while true:
    try:
      var bot = initBot()
      let
        playerWs = newWebSocket(playerUrl)
        globalWs = newWebSocket(mapUrl)
      playerWs.send(chatBlob("stacker online"), BinaryMessage)
      discard playerWs.receiveUpdates(bot, true, -1)
      discard globalWs.receiveUpdates(bot, false, -1)
      var lastMask = 0xff'u8
      while true:
        if not globalWs.receiveUpdates(bot, false, -1):
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
    except CatchableError as e:
      echo "stacker reconnecting: ", e.msg
      sleep(250)

when isMainModule:
  var
    address = "localhost"
    port = PlayerDefaultPort
    name = "stacker"
    explicitUrl = ""
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
      of "url":
        explicitUrl = val
      of "max-steps":
        maxSteps = parseInt(val)
      else:
        discard
    else:
      discard
  runBot(address, port, name, explicitUrl, maxSteps)

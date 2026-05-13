import
  std/algorithm,
  supersnappy,
  ../common/pixelfonts,
  protocol, sim

const
  NeutralPlanetSpriteBase = 100
  PlanetSelectedSpriteBase = 120
  PlanetOriginSpriteBase = 130
  PlayerPlanetSpriteBase = 1000
  PlayerShipSpriteBase = 2000
  PlayerCursorSpriteBase = 5000
  PlanetTextSpriteBase = 10000
  HudSpriteId = 18000
  WaitingSpriteId = 18002
  ChatSpriteBase = 18010
  PlanetObjectBase = 2000
  PlanetSelectedObjectBase = 2100
  PlanetOriginObjectBase = 2200
  PlanetTextObjectBase = 2300
  ShipObjectBase = 3000
  CursorObjectBase = 12000
  CursorZBase = WorldHeightPixels * 2
  PlanetTextZBase = WorldHeightPixels * 3
  ChatBubbleZBase = WorldHeightPixels * 4
  HudObjectId = 4000
  WaitingObjectId = 4002
  ChatObjectBase = 4010
  PlanetSpritePad = 4
  ShipSpriteSize = 5
  CursorSpriteSize = 5
  ChatBubblePad = 3
  ChatBubblePointerHeight = 3
  ChatBubbleGapY = 4
  ChatBubbleMaxTextWidth = 96
  TextOutlinePad = 1
  HudY = 24
  PlayerUiHeight = 48

type
  RgbaSprite = object
    width: int
    height: int
    pixels: seq[uint8]

  WorldSpriteObject = object
    id: int
    x: int
    y: int
    z: int
    spriteId: int

  GlobalViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    mouseX*: int
    mouseY*: int
    mouseLayer*: int
    mouseDown*: bool
    clickPending*: bool
    selectedPlanetId*: int

  PlayerViewerState* = object
    initialized*: bool
    objectIds*: seq[int]

proc initGlobalViewerState*(): GlobalViewerState =
  ## Returns the default state for one global protocol viewer.
  result.mouseLayer = MapLayerId
  result.selectedPlanetId = -1

proc initPlayerViewerState*(): PlayerViewerState =
  ## Returns the default state for one sprite player viewer.
  discard

proc rgbaSpriteIndex(sprite: RgbaSprite, x, y: int): int =
  ## Returns the byte offset for one RGBA sprite pixel.
  (y * sprite.width + x) * 4

proc newRgbaSprite(width, height: int): RgbaSprite =
  ## Allocates a transparent RGBA sprite.
  result.width = width
  result.height = height
  result.pixels = newSeq[uint8](width * height * 4)

proc putRgbaPixel(sprite: var RgbaSprite, x, y: int, color: RgbaColor) =
  ## Writes one full-color RGBA pixel into a sprite.
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return
  let offset = sprite.rgbaSpriteIndex(x, y)
  sprite.pixels[offset] = color.r
  sprite.pixels[offset + 1] = color.g
  sprite.pixels[offset + 2] = color.b
  sprite.pixels[offset + 3] = color.a

proc withAlpha(color: RgbaColor, alpha: uint8): RgbaColor =
  ## Returns a color with a replaced alpha channel.
  RgbaColor(r: color.r, g: color.g, b: color.b, a: alpha)

proc fillRect(
  sprite: var RgbaSprite,
  x,
  y,
  width,
  height: int,
  color: RgbaColor
) =
  ## Fills one clipped rectangle.
  for py in y ..< y + height:
    for px in x ..< x + width:
      sprite.putRgbaPixel(px, py, color)

proc strokeRect(
  sprite: var RgbaSprite,
  x,
  y,
  width,
  height: int,
  color: RgbaColor
) =
  ## Strokes one clipped rectangle.
  for px in x ..< x + width:
    sprite.putRgbaPixel(px, y, color)
    sprite.putRgbaPixel(px, y + height - 1, color)
  for py in y ..< y + height:
    sprite.putRgbaPixel(x, py, color)
    sprite.putRgbaPixel(x + width - 1, py, color)

proc drawHSpan(sprite: var RgbaSprite, x0, x1, y: int, color: RgbaColor) =
  ## Draws one horizontal span into an RGBA sprite.
  let
    startX = min(x0, x1)
    endX = max(x0, x1)
  for x in startX .. endX:
    sprite.putRgbaPixel(x, y, color)

proc plotCircleOctants(
  sprite: var RgbaSprite,
  cx,
  cy,
  x,
  y: int,
  color: RgbaColor
) =
  ## Plots all octants for one circle point.
  sprite.putRgbaPixel(cx + x, cy + y, color)
  sprite.putRgbaPixel(cx - x, cy + y, color)
  sprite.putRgbaPixel(cx + x, cy - y, color)
  sprite.putRgbaPixel(cx - x, cy - y, color)
  sprite.putRgbaPixel(cx + y, cy + x, color)
  sprite.putRgbaPixel(cx - y, cy + x, color)
  sprite.putRgbaPixel(cx + y, cy - x, color)
  sprite.putRgbaPixel(cx - y, cy - x, color)

proc drawCircleFill(
  sprite: var RgbaSprite,
  cx,
  cy,
  radius: int,
  color: RgbaColor
) =
  ## Draws a filled circle into an RGBA sprite.
  var
    x = radius
    y = 0
    decision = 1 - radius
  while x >= y:
    sprite.drawHSpan(cx - x, cx + x, cy + y, color)
    sprite.drawHSpan(cx - x, cx + x, cy - y, color)
    sprite.drawHSpan(cx - y, cx + y, cy + x, color)
    sprite.drawHSpan(cx - y, cx + y, cy - x, color)
    inc y
    if decision < 0:
      decision += 2 * y + 1
    else:
      dec x
      decision += 2 * (y - x) + 1

proc drawCircleRing(
  sprite: var RgbaSprite,
  cx,
  cy,
  radius,
  thickness: int,
  color: RgbaColor
) =
  ## Draws a circle ring into an RGBA sprite.
  for ringRadius in countdown(radius, max(0, radius - thickness + 1)):
    var
      x = ringRadius
      y = 0
      decision = 1 - ringRadius
    while x >= y:
      sprite.plotCircleOctants(cx, cy, x, y, color)
      inc y
      if decision < 0:
        decision += 2 * y + 1
      else:
        dec x
        decision += 2 * (y - x) + 1

proc addU8(packet: var seq[uint8], value: uint8) =
  ## Appends one unsigned byte to a global protocol packet.
  packet.add(value)

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addU32(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 32 bit value.
  let v = uint32(value)
  for shift in countup(0, 24, 8):
    packet.add(uint8((v shr shift) and 0xff'u32))

proc addI16(packet: var seq[uint8], value: int) =
  ## Appends one little endian signed 16 bit value.
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addViewport(packet: var seq[uint8], layer, width, height: int) =
  ## Appends a global protocol viewport message.
  packet.addU8(0x05)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addLayer(packet: var seq[uint8], layer, layerType, flags: int) =
  ## Appends a global protocol layer definition message.
  packet.addU8(0x06)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerType))
  packet.addU8(uint8(flags))

proc addClearObjects(packet: var seq[uint8]) =
  ## Appends a global protocol object clear message.
  packet.addU8(0x04)

proc addSprite(
  packet: var seq[uint8],
  spriteId,
  width,
  height: int,
  pixels: openArray[uint8],
  label = ""
) =
  ## Appends a global protocol sprite definition message.
  packet.addU8(0x01)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  var raw = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    raw[i] = pixels[i]
  let compressed = supersnappy.compress(raw)
  packet.addU32(compressed.len)
  for byte in compressed:
    packet.addU8(byte)
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc addObject(
  packet: var seq[uint8],
  objectId,
  x,
  y,
  z,
  layer,
  spriteId: int
) =
  ## Appends a global protocol object definition message.
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addDeleteObject(packet: var seq[uint8], objectId: int) =
  ## Appends a global protocol object delete message.
  packet.addU8(0x03)
  packet.addU16(objectId)

proc objectVisible(
  x,
  y,
  width,
  height,
  viewportWidth,
  viewportHeight: int
): bool =
  ## Returns true when an object intersects the current viewport.
  if width <= 0 or height <= 0:
    return false
  x < viewportWidth and
    y < viewportHeight and
    x + width > 0 and
    y + height > 0

proc addWorldObject(
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  objectId,
  x,
  y,
  z,
  spriteId,
  spriteWidth,
  spriteHeight,
  viewportWidth,
  viewportHeight: int
) =
  ## Queues one visible world object.
  if not objectVisible(
    x,
    y,
    spriteWidth,
    spriteHeight,
    viewportWidth,
    viewportHeight
  ):
    return
  currentIds.add(objectId)
  objects.add(WorldSpriteObject(
    id: objectId,
    x: x,
    y: y,
    z: z,
    spriteId: spriteId
  ))

proc flushWorldObjects(packet: var seq[uint8], objects: var seq[WorldSpriteObject]) =
  ## Sends queued world objects in stable draw order.
  objects.sort(
    proc(a, b: WorldSpriteObject): int =
      result = cmp(a.z, b.z)
      if result == 0:
        result = cmp(a.y, b.y)
      if result == 0:
        result = cmp(a.id, b.id)
  )
  for i, item in objects:
    packet.addObject(item.id, item.x, item.y, i, MapLayerId, item.spriteId)

proc planetSpriteRadius(size: PlanetSize): int =
  ## Returns the rendered sprite radius for one planet size.
  planetRadius(size) + PlanetSpritePad

proc scaleColor(color: RgbaColor, percent: int): RgbaColor =
  ## Returns a color scaled by a percentage.
  RgbaColor(
    r: uint8(clamp(int(color.r) * percent div 100, 0, 255)),
    g: uint8(clamp(int(color.g) * percent div 100, 0, 255)),
    b: uint8(clamp(int(color.b) * percent div 100, 0, 255)),
    a: color.a
  )

proc mixColor(a, b: RgbaColor, bPercent: int): RgbaColor =
  ## Returns a linear mix of two colors.
  let percent = clamp(bPercent, 0, 100)
  RgbaColor(
    r: uint8((int(a.r) * (100 - percent) + int(b.r) * percent) div 100),
    g: uint8((int(a.g) * (100 - percent) + int(b.g) * percent) div 100),
    b: uint8((int(a.b) * (100 - percent) + int(b.b) * percent) div 100),
    a: max(a.a, b.a)
  )

proc neutralPlanetSpriteId(size: PlanetSize): int =
  ## Returns the sprite id for one neutral planet sprite.
  NeutralPlanetSpriteBase + ord(size)

proc playerPlanetSpriteId(playerId: int, size: PlanetSize): int =
  ## Returns the sprite id for one player-owned planet sprite.
  PlayerPlanetSpriteBase + playerId * 8 + ord(size)

proc planetSelectedSpriteId(size: PlanetSize): int =
  ## Returns the sprite id for one selected planet ring.
  PlanetSelectedSpriteBase + ord(size)

proc planetOriginSpriteId(size: PlanetSize): int =
  ## Returns the sprite id for one origin planet ring.
  PlanetOriginSpriteBase + ord(size)

proc playerShipSpriteId(playerId, direction: int): int =
  ## Returns the sprite id for one player's ship and direction.
  PlayerShipSpriteBase + playerId * 4 + direction

proc playerCursorSpriteId(playerId: int): int =
  ## Returns the sprite id for one player's cursor.
  PlayerCursorSpriteBase + playerId

proc shipDirection(ship: Ship): int =
  ## Returns the dominant direction index for one moving ship.
  let
    dx = ship.endX - ship.startX
    dy = ship.endY - ship.startY
  if abs(dx) >= abs(dy):
    if dx >= 0:
      0
    else:
      1
  else:
    if dy >= 0:
      2
    else:
      3

proc buildPlanetSprite(size: PlanetSize, color: RgbaColor): RgbaSprite =
  ## Builds one planet base sprite.
  let
    radius = planetRadius(size)
    spriteRadius = planetSpriteRadius(size)
    center = spriteRadius
    dim = spriteRadius * 2 + 1
    border = color.scaleColor(42)
    shade = color.scaleColor(72)
    highlight = color.mixColor(ScoreColor, 42)
  result = newRgbaSprite(dim, dim)
  result.drawCircleFill(center, center, radius + 1, color)
  result.drawCircleRing(center, center, radius + 1, 1, border)
  result.drawCircleRing(center, center, max(1, radius - 2), 1, shade)
  result.putRgbaPixel(center - radius div 2, center - radius div 2, highlight)

proc buildPlanetRingSprite(size: PlanetSize, color: RgbaColor): RgbaSprite =
  ## Builds one planet ring overlay sprite.
  let
    spriteRadius = planetSpriteRadius(size)
    center = spriteRadius
    dim = spriteRadius * 2 + 1
  result = newRgbaSprite(dim, dim)
  result.drawCircleRing(center, center, spriteRadius - 1, 1, color)

proc buildShipSprite(color: RgbaColor, direction: int): RgbaSprite =
  ## Builds one small directional ship sprite.
  result = newRgbaSprite(ShipSpriteSize, ShipSpriteSize)
  let c = ShipSpriteSize div 2
  case direction
  of 0:
    result.putRgbaPixel(c + 2, c, ScoreColor)
    result.putRgbaPixel(c + 1, c, color)
    result.putRgbaPixel(c, c - 1, color)
    result.putRgbaPixel(c, c, color)
    result.putRgbaPixel(c, c + 1, color)
  of 1:
    result.putRgbaPixel(c - 2, c, ScoreColor)
    result.putRgbaPixel(c - 1, c, color)
    result.putRgbaPixel(c, c - 1, color)
    result.putRgbaPixel(c, c, color)
    result.putRgbaPixel(c, c + 1, color)
  of 2:
    result.putRgbaPixel(c, c + 2, ScoreColor)
    result.putRgbaPixel(c, c + 1, color)
    result.putRgbaPixel(c - 1, c, color)
    result.putRgbaPixel(c, c, color)
    result.putRgbaPixel(c + 1, c, color)
  else:
    result.putRgbaPixel(c, c - 2, ScoreColor)
    result.putRgbaPixel(c, c - 1, color)
    result.putRgbaPixel(c - 1, c, color)
    result.putRgbaPixel(c, c, color)
    result.putRgbaPixel(c + 1, c, color)

proc buildCursorSprite(color: RgbaColor): RgbaSprite =
  ## Builds a 5 by 5 cross cursor with a transparent center.
  result = newRgbaSprite(CursorSpriteSize, CursorSpriteSize)
  let center = CursorSpriteSize div 2
  for i in 0 ..< CursorSpriteSize:
    if i == center:
      continue
    result.putRgbaPixel(i, center, color)
    result.putRgbaPixel(center, i, color)

proc buildBackgroundSprite(sim: SimServer): RgbaSprite =
  ## Builds the starfield background sprite.
  result = newRgbaSprite(WorldWidthPixels, WorldHeightPixels)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      result.putRgbaPixel(x, y, BackgroundColor)
  for star in sim.stars:
    result.putRgbaPixel(star.x, star.y, star.color)

proc blitGlyph(
  sprite: var RgbaSprite,
  glyph: PixelGlyph,
  baseX,
  baseY: int,
  color: RgbaColor
) =
  ## Blits a single-color Tiny5 glyph into a sprite.
  for y in 0 ..< glyph.height:
    for x in 0 ..< glyph.width:
      if glyph.glyphPixel(x, y):
        sprite.putRgbaPixel(baseX + x, baseY + y, color)

proc blitGlyphOutline(
  sprite: var RgbaSprite,
  glyph: PixelGlyph,
  baseX,
  baseY: int
) =
  ## Blits the black outline around one Tiny5 glyph.
  for y in 0 ..< glyph.height:
    for x in 0 ..< glyph.width:
      if not glyph.glyphPixel(x, y):
        continue
      for oy in -1 .. 1:
        for ox in -1 .. 1:
          if ox == 0 and oy == 0:
            continue
          sprite.putRgbaPixel(
            baseX + x + ox,
            baseY + y + oy,
            BlackColor
          )

proc buildTextSprite(
  sim: SimServer,
  lines: openArray[string],
  color: RgbaColor,
  outlined = false
): RgbaSprite =
  ## Builds a compact Tiny5 protocol text sprite.
  let
    lineHeight = sim.textFont.lineHeight()
    pad = if outlined: TextOutlinePad else: 0
  var width = 1
  for line in lines:
    width = max(width, sim.textFont.textWidth(line))
  result = newRgbaSprite(
    width + pad * 2,
    max(1, lines.len * lineHeight - sim.textFont.spacing) + pad * 2
  )
  for lineIndex, line in lines:
    let baseY = pad + lineIndex * lineHeight
    var baseX = pad
    if outlined:
      for ch in line:
        let glyph = sim.textFont.glyphAt(ch)
        result.blitGlyphOutline(glyph, baseX, baseY)
        baseX += sim.textFont.glyphAdvance(ch)
    baseX = pad
    for ch in line:
      let glyph = sim.textFont.glyphAt(ch)
      result.blitGlyph(glyph, baseX, baseY, color)
      baseX += sim.textFont.glyphAdvance(ch)

proc textSliceForWidth(
  font: PixelFont,
  text: string,
  maxWidth: int
): string =
  ## Returns the longest text prefix that fits a pixel width.
  var width = 0
  for ch in text:
    let advance = font.glyphAdvance(ch)
    if result.len > 0 and width + advance > maxWidth:
      return
    if result.len == 0 and advance > maxWidth:
      return
    result.add(ch)
    width += advance

proc buildChatBubbleSprite(
  sim: SimServer,
  text: string,
  alpha: uint8
): RgbaSprite =
  ## Builds one Tiny5 chat bubble sprite.
  let
    line = sim.textFont.textSliceForWidth(text, ChatBubbleMaxTextWidth)
    textWidth = max(6, sim.textFont.textWidth(line))
    bodyWidth = textWidth + ChatBubblePad * 2
    bodyHeight = sim.textFont.height + ChatBubblePad * 2
    pointerX = bodyWidth div 2
    fillAlpha = uint8(int(alpha) * 190 div 255)
    fillColor = BlackColor.withAlpha(fillAlpha)
    lineColor = BlackColor.withAlpha(alpha)
    textColor = ScoreColor.withAlpha(alpha)
  result = newRgbaSprite(
    bodyWidth,
    bodyHeight + ChatBubblePointerHeight
  )
  result.fillRect(0, 0, bodyWidth, bodyHeight, fillColor)
  result.strokeRect(0, 0, bodyWidth, bodyHeight, lineColor)
  for y in 0 ..< ChatBubblePointerHeight:
    let span = ChatBubblePointerHeight - y - 1
    for x in pointerX - span .. pointerX + span:
      result.putRgbaPixel(x, bodyHeight + y, lineColor)
  var baseX = ChatBubblePad
  for ch in line:
    let glyph = sim.textFont.glyphAt(ch)
    result.blitGlyph(
      glyph,
      baseX,
      ChatBubblePad,
      textColor
    )
    baseX += sim.textFont.glyphAdvance(ch)

proc readProtocolI16(blob: string, offset: int): int =
  ## Reads one little endian signed 16 bit value from a string.
  let value = uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState,
  message: string
) =
  ## Applies one or more global protocol client messages.
  var offset = 0
  while offset < message.len:
    let messageType = message[offset].uint8
    inc offset
    case messageType
    of 0x82:
      if offset + 4 > message.len:
        return
      state.mouseX = readProtocolI16(message, offset)
      state.mouseY = readProtocolI16(message, offset + 2)
      offset += 4
      if offset < message.len and message[offset].uint8 notin
          {0x81'u8, 0x82'u8, 0x83'u8, 0x84'u8}:
        state.mouseLayer = int(message[offset].uint8)
        inc offset
      else:
        state.mouseLayer = MapLayerId
    of 0x83:
      if offset + 2 > message.len:
        return
      let
        code = message[offset].uint8
        down = message[offset + 1].uint8
      offset += 2
      if code == 0x01'u8:
        state.mouseDown = down == 1'u8
        if state.mouseDown:
          state.clickPending = true
    of 0x81:
      if offset + 2 > message.len:
        return
      let length = int(uint16(message[offset].uint8) or
        (uint16(message[offset + 1].uint8) shl 8))
      offset += 2
      if offset + length > message.len:
        return
      offset += length
    of 0x84:
      if offset + 1 > message.len:
        return
      inc offset
    else:
      return

proc applyPlayerViewerMessage*(
  state: var PlayerViewerState,
  message: string,
  inputMask: var uint8,
  chatText: var string
) =
  ## Applies sprite-player input messages.
  discard state
  var offset = 0
  while offset < message.len:
    let messageType = message[offset].uint8
    inc offset
    case messageType
    of 0x81:
      if offset + 2 > message.len:
        return
      let length = int(uint16(message[offset].uint8) or
        (uint16(message[offset + 1].uint8) shl 8))
      offset += 2
      if offset + length > message.len:
        return
      for i in 0 ..< length:
        let value = message[offset + i].uint8
        if value >= 32'u8 and value < 127'u8:
          chatText.add(message[offset + i])
      offset += length
    of 0x82:
      if offset + 4 > message.len:
        return
      offset += 4
      if offset < message.len and message[offset].uint8 notin
          {0x81'u8, 0x82'u8, 0x83'u8, 0x84'u8}:
        inc offset
    of 0x83:
      if offset + 2 > message.len:
        return
      offset += 2
    of 0x84:
      if offset + 1 > message.len:
        return
      inputMask = message[offset].uint8 and 0x7f'u8
      inc offset
    else:
      return

proc selectPlanetAt(sim: SimServer, worldX, worldY: int): int =
  ## Returns the clicked planet id, or minus one.
  var
    bestId = -1
    bestDistance = high(int)
  for planet in sim.planets:
    let
      dx = planet.x - worldX
      dy = planet.y - worldY
      distance = dx * dx + dy * dy
      radius = planet.radius + PlanetSpritePad
    if distance <= radius * radius and distance < bestDistance:
      bestId = planet.id
      bestDistance = distance
  bestId

proc addCommonSpriteDefinitions(packet: var seq[uint8], sim: SimServer) =
  ## Adds sprite definitions shared by global and player views.
  let background = sim.buildBackgroundSprite()
  packet.addSprite(
    MapSpriteId,
    background.width,
    background.height,
    background.pixels,
    "starfield"
  )
  for size in PlanetSize:
    let planet = buildPlanetSprite(size, NeutralPlanetColor)
    packet.addSprite(
      neutralPlanetSpriteId(size),
      planet.width,
      planet.height,
      planet.pixels,
      "neutral planet"
    )
    let
      selected = buildPlanetRingSprite(size, SelectionColor)
      origin = buildPlanetRingSprite(size, OriginColor)
    packet.addSprite(
      planetSelectedSpriteId(size),
      selected.width,
      selected.height,
      selected.pixels,
      "selected planet"
    )
    packet.addSprite(
      planetOriginSpriteId(size),
      origin.width,
      origin.height,
      origin.pixels,
      "origin planet"
    )
  discard sim

proc addPlayerSpriteDefinitions(packet: var seq[uint8], sim: SimServer) =
  ## Adds dynamic full-color sprite definitions for all players.
  for player in sim.players:
    for size in PlanetSize:
      let planet = buildPlanetSprite(size, player.color)
      packet.addSprite(
        playerPlanetSpriteId(player.id, size),
        planet.width,
        planet.height,
        planet.pixels,
        "player planet"
      )
    for direction in 0 ..< 4:
      let ship = buildShipSprite(player.color, direction)
      packet.addSprite(
        playerShipSpriteId(player.id, direction),
        ship.width,
        ship.height,
        ship.pixels,
        "player ship"
      )
    let cursor = buildCursorSprite(player.color)
    packet.addSprite(
      playerCursorSpriteId(player.id),
      cursor.width,
      cursor.height,
      cursor.pixels,
      "player cursor"
    )

proc buildSpriteProtocolInit(sim: SimServer): seq[uint8] =
  ## Builds the initial global viewer snapshot.
  result = @[]
  result.addClearObjects()
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, WorldWidthPixels, WorldHeightPixels)
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, ScreenWidth, 48)
  result.addCommonSpriteDefinitions(sim)

proc buildSpriteProtocolPlayerInit(sim: SimServer): seq[uint8] =
  ## Builds the initial sprite player snapshot.
  result = @[]
  result.addClearObjects()
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, ScreenWidth, ScreenHeight)
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, ScreenWidth, PlayerUiHeight)
  result.addCommonSpriteDefinitions(sim)

proc addTextObject(
  sim: SimServer,
  packet: var seq[uint8],
  currentIds: var seq[int],
  objectId,
  spriteId,
  x,
  y,
  z,
  layer: int,
  lines: openArray[string],
  color: RgbaColor,
  outlined = false,
  label = "text"
) =
  ## Adds one dynamic text sprite and object.
  let text = sim.buildTextSprite(lines, color, outlined)
  packet.addSprite(
    spriteId,
    text.width,
    text.height,
    text.pixels,
    label
  )
  packet.addObject(objectId, x, y, z, layer, spriteId)
  currentIds.add(objectId)

proc addPlanetObjects(
  sim: SimServer,
  packet: var seq[uint8],
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  viewerId,
  selectedIndex,
  originIndex,
  selectedPlanetId,
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds planet base, ring, and ship-count objects.
  for i, planet in sim.planets:
    let
      spriteRadius = planetSpriteRadius(planet.size)
      width = spriteRadius * 2 + 1
      sx = planet.x - spriteRadius - cameraX
      sy = planet.y - spriteRadius - cameraY
      spriteId =
        if planet.ownerId == 0:
          neutralPlanetSpriteId(planet.size)
        else:
          playerPlanetSpriteId(planet.ownerId, planet.size)
    objects.addWorldObject(
      currentIds,
      PlanetObjectBase + planet.id,
      sx,
      sy,
      planet.y,
      spriteId,
      width,
      width,
      viewportWidth,
      viewportHeight
    )
    if i == originIndex:
      objects.addWorldObject(
        currentIds,
        PlanetOriginObjectBase + planet.id,
        sx,
        sy,
        planet.y + 1,
        planetOriginSpriteId(planet.size),
        width,
        width,
        viewportWidth,
        viewportHeight
      )
    if i == selectedIndex or planet.id == selectedPlanetId:
      objects.addWorldObject(
        currentIds,
        PlanetSelectedObjectBase + planet.id,
        sx,
        sy,
        planet.y + 2,
        planetSelectedSpriteId(planet.size),
        width,
        width,
        viewportWidth,
        viewportHeight
      )
    let
      text = sim.buildTextSprite([$planet.ships], ScoreColor, true)
      textX = planet.x - text.width div 2 - cameraX
      textY = planet.y - text.height div 2 - cameraY
    if objectVisible(
      textX,
      textY,
      text.width,
      text.height,
      viewportWidth,
      viewportHeight
    ):
      packet.addSprite(
        PlanetTextSpriteBase + planet.id,
        text.width,
        text.height,
        text.pixels,
        "ships " & $planet.ships
      )
      objects.addWorldObject(
        currentIds,
        PlanetTextObjectBase + planet.id,
        textX,
        textY,
        PlanetTextZBase + planet.y,
        PlanetTextSpriteBase + planet.id,
        text.width,
        text.height,
        viewportWidth,
        viewportHeight
      )
  discard viewerId

proc addShipObjects(
  sim: SimServer,
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  viewerId,
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds moving ship objects.
  for i, ship in sim.ships:
    let
      pos = currentShipPosition(ship)
      sx = pos.x - ShipSpriteSize div 2 - cameraX
      sy = pos.y - ShipSpriteSize div 2 - cameraY
    objects.addWorldObject(
      currentIds,
      ShipObjectBase + i,
      sx,
      sy,
      pos.y + 20,
      playerShipSpriteId(ship.ownerId, ship.shipDirection()),
      ShipSpriteSize,
      ShipSpriteSize,
      viewportWidth,
      viewportHeight
    )
  discard viewerId

proc addCursorObjects(
  sim: SimServer,
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds all visible player cursors.
  for player in sim.players:
    let
      sx = player.cursorX - CursorSpriteSize div 2 - cameraX
      sy = player.cursorY - CursorSpriteSize div 2 - cameraY
    objects.addWorldObject(
      currentIds,
      CursorObjectBase + player.id,
      sx,
      sy,
      CursorZBase + player.cursorY,
      playerCursorSpriteId(player.id),
      CursorSpriteSize,
      CursorSpriteSize,
      viewportWidth,
      viewportHeight
    )

proc chatMessageAlpha(sim: SimServer, message: ChatMessage): uint8 =
  ## Returns the fade alpha for one chat message.
  let age = clamp(sim.tickCount - message.tick, 0, ChatBubbleTicks)
  uint8(((ChatBubbleTicks - age) * 255) div ChatBubbleTicks)

proc addChatBubbleObjects(
  sim: SimServer,
  packet: var seq[uint8],
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds cursor-anchored chat bubble objects.
  for message in sim.chatMessages:
    let alpha = sim.chatMessageAlpha(message)
    if alpha == 0:
      continue
    for player in sim.players:
      if player.id != message.playerId:
        continue
      let
        bubble = sim.buildChatBubbleSprite(
          message.text,
          alpha
        )
        sx = player.cursorX - bubble.width div 2 - cameraX
        sy = player.cursorY - bubble.height - ChatBubbleGapY - cameraY
        spriteId = ChatSpriteBase + player.id
      packet.addSprite(
        spriteId,
        bubble.width,
        bubble.height,
        bubble.pixels,
        "chat " & message.text
      )
      objects.addWorldObject(
        currentIds,
        ChatObjectBase + player.id,
        sx,
        sy,
        ChatBubbleZBase + player.cursorY,
        spriteId,
        bubble.width,
        bubble.height,
        viewportWidth,
        viewportHeight
      )
      break

proc addWorldObjects(
  sim: SimServer,
  packet: var seq[uint8],
  currentIds: var seq[int],
  viewerId,
  selectedIndex,
  originIndex,
  selectedPlanetId,
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds all visible world objects to a protocol packet.
  var objects: seq[WorldSpriteObject] = @[]
  currentIds.add(MapObjectId)
  packet.addObject(
    MapObjectId,
    -cameraX,
    -cameraY,
    low(int16),
    MapLayerId,
    MapSpriteId
  )
  sim.addPlanetObjects(
    packet,
    objects,
    currentIds,
    viewerId,
    selectedIndex,
    originIndex,
    selectedPlanetId,
    cameraX,
    cameraY,
    viewportWidth,
    viewportHeight
  )
  sim.addShipObjects(
    objects,
    currentIds,
    viewerId,
    cameraX,
    cameraY,
    viewportWidth,
    viewportHeight
  )
  sim.addCursorObjects(
    objects,
    currentIds,
    cameraX,
    cameraY,
    viewportWidth,
    viewportHeight
  )
  sim.addChatBubbleObjects(
    packet,
    objects,
    currentIds,
    cameraX,
    cameraY,
    viewportWidth,
    viewportHeight
  )
  packet.flushWorldObjects(objects)

proc addPlayerHud(
  sim: SimServer,
  packet: var seq[uint8],
  currentIds: var seq[int],
  playerIndex: int
) =
  ## Adds the player score HUD.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    player = sim.players[playerIndex]
    planets = sim.countOwnedPlanets(player.id)
  sim.addTextObject(
    packet,
    currentIds,
    HudObjectId,
    HudSpriteId,
    2,
    HudY,
    high(int16),
    TopLeftLayerId,
    ["SCORE " & $player.score, "PLANETS " & $planets],
    ScoreColor,
    true
  )

proc addWaitingText(
  sim: SimServer,
  packet: var seq[uint8],
  currentIds: var seq[int]
) =
  ## Adds centered waiting text to an unassigned player view.
  let text = sim.buildTextSprite(["WAITING"], ScoreColor, true)
  packet.addSprite(
    WaitingSpriteId,
    text.width,
    text.height,
    text.pixels,
    "waiting"
  )
  packet.addObject(
    WaitingObjectId,
    max(0, (ScreenWidth - text.width) div 2),
    max(0, (ScreenHeight - text.height) div 2),
    high(int16),
    MapLayerId,
    WaitingSpriteId
  )
  currentIds.add(WaitingObjectId)

proc buildSpriteProtocolPlayerUpdates*(
  sim: SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] =
  ## Builds sprite protocol updates for one playable player view.
  result = @[]
  nextState = state
  if not nextState.initialized:
    result = sim.buildSpriteProtocolPlayerInit()
    nextState.initialized = true
  result.addPlayerSpriteDefinitions(sim)
  var currentIds: seq[int] = @[]
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.addWaitingText(result, currentIds)
  else:
    var ownedSim = sim
    ownedSim.ensureSelection(playerIndex)
    let
      player = ownedSim.players[playerIndex]
      cameraX = worldClampPixel(
        player.cursorX - ScreenWidth div 2,
        WorldWidthPixels - ScreenWidth
      )
      cameraY = worldClampPixel(
        player.cursorY - ScreenHeight div 2,
        WorldHeightPixels - ScreenHeight
      )
    ownedSim.addWorldObjects(
      result,
      currentIds,
      player.id,
      player.selectedPlanet,
      player.originPlanet,
      -1,
      cameraX,
      cameraY,
      ScreenWidth,
      ScreenHeight
    )
    ownedSim.addPlayerHud(result, currentIds, playerIndex)
  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc buildSpriteProtocolUpdates*(
  sim: SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[uint8] =
  ## Builds global viewer object updates for the current tick.
  result = @[]
  nextState = state
  if nextState.clickPending:
    if nextState.mouseLayer == MapLayerId:
      nextState.selectedPlanetId =
        sim.selectPlanetAt(nextState.mouseX, nextState.mouseY)
    nextState.clickPending = false
  if not nextState.initialized:
    result = sim.buildSpriteProtocolInit()
    nextState.initialized = true
  result.addPlayerSpriteDefinitions(sim)
  var currentIds: seq[int] = @[]
  sim.addWorldObjects(
    result,
    currentIds,
    0,
    -1,
    -1,
    nextState.selectedPlanetId,
    0,
    0,
    WorldWidthPixels,
    WorldHeightPixels
  )
  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

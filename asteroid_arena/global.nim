import
  supersnappy,
  sim

const
  ScreenWidth = 128
  ScreenHeight = 128

  MapSpriteId = 1
  MapObjectId = 1
  ShipSpriteBase = 100
  AsteroidSpriteBase = 600
  BulletSpriteBase = 900
  ExplosionSpriteBase = 950
  ShieldSpriteBase = 980
  CaptureSpriteBase = 985
  ChatSpriteBase = 700
  HudSpriteId = 990
  RespawnSpriteId = 991

  AsteroidObjectBase = 1000
  ShipObjectBase = 2000
  BulletObjectBase = 3000
  ExplosionObjectBase = 4000
  CaptureObjectBase = 5000
  ChatObjectBase = 6000
  HudObjectId = 8000
  RespawnObjectId = 8001

  ChatPad = 2
  ChatPointerHeight = 2
  ChatGapY = 3
  ChatGlyphWidth = 4
  ChatGlyphHeight = 5

  CaptureProgressColor = RgbaColor(r: 0xFF, g: 0xFF, b: 0x40, a: 255)

type
  RgbaSprite = object
    width, height: int
    pixels: seq[uint8]

  SpriteCacheEntry = object
    spriteId: int
    width: int
    height: int
    pixels: seq[uint8]

  GlobalViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    spriteCache*: seq[SpriteCacheEntry]

  PlayerViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    spriteCache*: seq[SpriteCacheEntry]

proc initGlobalViewerState*(): GlobalViewerState =
  discard

proc initPlayerViewerState*(): PlayerViewerState =
  discard

proc newRgbaSprite(width, height: int): RgbaSprite =
  result.width = width
  result.height = height
  result.pixels = newSeq[uint8](width * height * 4)

proc putRgbaPixel(sprite: var RgbaSprite, x, y: int, color: RgbaColor) =
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return
  let offset = (y * sprite.width + x) * 4
  sprite.pixels[offset] = color.r
  sprite.pixels[offset + 1] = color.g
  sprite.pixels[offset + 2] = color.b
  sprite.pixels[offset + 3] = color.a

proc drawHSpan(sprite: var RgbaSprite, x0, x1, y: int, color: RgbaColor) =
  let
    startX = min(x0, x1)
    endX = max(x0, x1)
  for x in startX .. endX:
    sprite.putRgbaPixel(x, y, color)

proc drawLine(sprite: var RgbaSprite, x0, y0, x1, y1: int, color: RgbaColor) =
  var
    currentX = x0
    currentY = y0
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    stepX = if x0 < x1: 1 else: -1
    stepY = if y0 < y1: 1 else: -1
    error = dx + dy
  while true:
    sprite.putRgbaPixel(currentX, currentY, color)
    if currentX == x1 and currentY == y1:
      break
    let twiceError = error * 2
    if twiceError >= dy:
      error += dy
      currentX += stepX
    if twiceError <= dx:
      error += dx
      currentY += stepY

proc drawCircleFill(
  sprite: var RgbaSprite,
  cx, cy, radius: int,
  color: RgbaColor
) =
  if radius <= 0:
    sprite.putRgbaPixel(cx, cy, color)
    return
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
  cx, cy, radius, thickness: int,
  color: RgbaColor
) =
  for ringRadius in countdown(radius, max(0, radius - thickness + 1)):
    var
      x = ringRadius
      y = 0
      decision = 1 - ringRadius
    while x >= y:
      sprite.putRgbaPixel(cx + x, cy + y, color)
      sprite.putRgbaPixel(cx - x, cy + y, color)
      sprite.putRgbaPixel(cx + x, cy - y, color)
      sprite.putRgbaPixel(cx - x, cy - y, color)
      sprite.putRgbaPixel(cx + y, cy + x, color)
      sprite.putRgbaPixel(cx - y, cy + x, color)
      sprite.putRgbaPixel(cx + y, cy - x, color)
      sprite.putRgbaPixel(cx - y, cy - x, color)
      inc y
      if decision < 0:
        decision += 2 * y + 1
      else:
        dec x
        decision += 2 * (y - x) + 1

proc addU8(packet: var seq[uint8], value: uint8) =
  packet.add(value)

proc addU16(packet: var seq[uint8], value: int) =
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addU32(packet: var seq[uint8], value: int) =
  let v = uint32(value)
  for shift in countup(0, 24, 8):
    packet.add(uint8((v shr shift) and 0xff'u32))

proc addI16(packet: var seq[uint8], value: int) =
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addViewport(packet: var seq[uint8], layer, width, height: int) =
  packet.addU8(0x05)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addLayer(packet: var seq[uint8], layer, layerType, flags: int) =
  packet.addU8(0x06)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerType))
  packet.addU8(uint8(flags))

proc addSprite(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label = ""
) =
  packet.addU8(0x01)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  var raw = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    raw[i] = pixels[i]
  let compressed = supersnappy.compress(raw)
  packet.addU32(compressed.len)
  for b in compressed:
    packet.addU8(b)
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc addSpriteCached(
  packet: var seq[uint8],
  cache: var seq[SpriteCacheEntry],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label = ""
) =
  for item in cache.mitems:
    if item.spriteId != spriteId:
      continue
    if item.width == width and item.height == height and
        item.pixels.len == pixels.len:
      var unchanged = true
      for i in 0 ..< pixels.len:
        if item.pixels[i] != pixels[i]:
          unchanged = false
          break
      if unchanged:
        return
    packet.addSprite(spriteId, width, height, pixels, label)
    item.width = width
    item.height = height
    item.pixels.setLen(pixels.len)
    for i in 0 ..< pixels.len:
      item.pixels[i] = pixels[i]
    return
  packet.addSprite(spriteId, width, height, pixels, label)
  var entry = SpriteCacheEntry(spriteId: spriteId, width: width, height: height)
  entry.pixels = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    entry.pixels[i] = pixels[i]
  cache.add(entry)

proc addObject(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addDeleteObject(packet: var seq[uint8], objectId: int) =
  packet.addU8(0x03)
  packet.addU16(objectId)

proc buildBackgroundSprite(sim: SimServer, width, height: int): RgbaSprite =
  result = newRgbaSprite(width, height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      result.putRgbaPixel(x, y, BackgroundColor)
  for star in sim.stars:
    if star.x < width and star.y < height:
      result.putRgbaPixel(star.x, star.y, star.color)

proc buildPlayerBackgroundSprite(
  sim: SimServer,
  cameraPixelX, cameraPixelY: int
): RgbaSprite =
  result = newRgbaSprite(ScreenWidth, ScreenHeight)
  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      result.putRgbaPixel(x, y, BackgroundColor)
  for star in sim.stars:
    var
      sx = star.x - cameraPixelX
      sy = star.y - cameraPixelY
    while sx < 0: sx += WorldWidthPixels
    while sx >= WorldWidthPixels: sx -= WorldWidthPixels
    while sy < 0: sy += WorldHeightPixels
    while sy >= WorldHeightPixels: sy -= WorldHeightPixels
    if sx < ScreenWidth and sy < ScreenHeight:
      result.putRgbaPixel(sx, sy, star.color)

proc buildShipSprite(color: RgbaColor, direction: int, thrust: bool): RgbaSprite =
  let
    size = 9
    center = size div 2
    fx = forwardX(direction)
    fy = forwardY(direction)
    sx = sideX(direction)
    sy = sideY(direction)
    noseX = center + fx * ShipNoseOffsetPixels div DirectionScale
    noseY = center + fy * ShipNoseOffsetPixels div DirectionScale
    tailX = center - fx * ShipTailOffsetPixels div DirectionScale
    tailY = center - fy * ShipTailOffsetPixels div DirectionScale
    leftX = tailX + sx * ShipWingOffsetPixels div DirectionScale
    leftY = tailY + sy * ShipWingOffsetPixels div DirectionScale
    rightX = tailX - sx * ShipWingOffsetPixels div DirectionScale
    rightY = tailY - sy * ShipWingOffsetPixels div DirectionScale
  result = newRgbaSprite(size, size)
  if thrust:
    let
      flameX = center - fx * (ShipTailOffsetPixels + 2) div DirectionScale
      flameY = center - fy * (ShipTailOffsetPixels + 2) div DirectionScale
    result.drawLine(leftX, leftY, flameX, flameY, ThrusterColor)
    result.drawLine(rightX, rightY, flameX, flameY, ThrusterColor)
  result.drawLine(noseX, noseY, leftX, leftY, color)
  result.drawLine(leftX, leftY, rightX, rightY, color)
  result.drawLine(rightX, rightY, noseX, noseY, color)
  result.putRgbaPixel(center, center, BulletFlashColor)

proc asteroidSpriteSize(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 8
  of AsteroidMedium: 12
  of AsteroidLarge: 16

proc buildAsteroidSprite(asteroid: Asteroid): RgbaSprite =
  let
    dim = asteroidSpriteSize(asteroid.size)
    center = dim div 2
    radius = asteroidRadius(asteroid.size)
    fillColor = if asteroid.cooperative: CoopAsteroidFillColor else: AsteroidFillColor
    outlineColor = if asteroid.cooperative: CoopAsteroidOutlineColor else: AsteroidOutlineColor
  result = newRgbaSprite(dim, dim)
  result.drawCircleFill(center, center, max(1, radius - 2), fillColor)
  var
    firstX, firstY: int
    previousX, previousY: int
  for vertexIndex in 0 ..< 8:
    let
      direction = normalizedDirection((vertexIndex + asteroid.rotation) * 2)
      vertexRadius = asteroid.rockVertexRadius(vertexIndex)
      vertexX = center + forwardX(direction) * vertexRadius div DirectionScale
      vertexY = center + forwardY(direction) * vertexRadius div DirectionScale
    if vertexIndex == 0:
      firstX = vertexX
      firstY = vertexY
    else:
      result.drawLine(previousX, previousY, vertexX, vertexY, outlineColor)
    previousX = vertexX
    previousY = vertexY
  result.drawLine(previousX, previousY, firstX, firstY, outlineColor)

proc buildBulletSprite(color: RgbaColor): RgbaSprite =
  result = newRgbaSprite(3, 3)
  result.putRgbaPixel(1, 1, color)
  result.putRgbaPixel(1, 0, BulletFlashColor)

proc buildExplosionSprite(explosion: Explosion): RgbaSprite =
  let
    elapsed = explosion.maxTtl - explosion.ttl
    ringRadius = max(1, 1 + (elapsed * explosion.radius) div max(1, explosion.maxTtl))
    dim = (ringRadius + 2) * 2 + 1
    center = dim div 2
  result = newRgbaSprite(dim, dim)
  result.drawCircleRing(center, center, ringRadius, 1, explosion.color)
  if elapsed * 2 < explosion.maxTtl:
    result.putRgbaPixel(center, center, ExplosionCoreColor)

proc buildShieldSprite(): RgbaSprite =
  let
    radius = ShipCollisionRadius + 2
    dim = radius * 2 + 3
    center = dim div 2
  result = newRgbaSprite(dim, dim)
  result.drawCircleRing(center, center, radius, 1, ShieldColor)

proc dimColor(color: RgbaColor): RgbaColor =
  RgbaColor(
    r: uint8(int(color.r) div 3),
    g: uint8(int(color.g) div 3),
    b: uint8(int(color.b) div 3),
    a: color.a
  )

proc buildCaptureSprite(sim: SimServer, cp: CapturePoint): RgbaSprite =
  let
    capRadius = cp.captureRadius()
    dim = capRadius * 2 + 1
    center = capRadius
  var color = RgbaColor(r: 255, g: 255, b: 255, a: 255)
  if cp.owners.len > 0:
    for player in sim.players:
      if player.id == cp.owners[0]:
        color = player.color
        break
  result = newRgbaSprite(dim, dim)
  result.drawCircleFill(center, center, cp.radius, dimColor(color))
  result.drawCircleRing(center, center, cp.radius, 1, color)
  result.drawCircleRing(center, center, capRadius, 1, dimColor(color))
  if cp.progress > 0 and cp.owners.len == 0:
    let progressRadius = max(cp.radius + 2, cp.progress * (capRadius - cp.radius - 2) div CaptureTicksRequired + cp.radius + 2)
    result.drawCircleRing(center, center, progressRadius, 1, CaptureProgressColor)

proc shipSpriteId(playerIndex, direction: int, thrust: bool): int =
  ShipSpriteBase + playerIndex * 32 + direction * 2 + (if thrust: 1 else: 0)

proc asteroidSpriteId(asteroid: Asteroid): int =
  AsteroidSpriteBase + asteroid.id mod 256

proc bulletSpriteId(playerIndex: int): int =
  BulletSpriteBase + playerIndex

proc explosionSpriteId(index: int): int =
  ExplosionSpriteBase + index

# Simple 3x5 digit font for HUD
const DigitPatterns: array[10, array[5, uint8]] = [
  [0b111'u8, 0b101, 0b101, 0b101, 0b111],  # 0
  [0b010'u8, 0b110, 0b010, 0b010, 0b111],  # 1
  [0b111'u8, 0b001, 0b111, 0b100, 0b111],  # 2
  [0b111'u8, 0b001, 0b111, 0b001, 0b111],  # 3
  [0b101'u8, 0b101, 0b111, 0b001, 0b001],  # 4
  [0b111'u8, 0b100, 0b111, 0b001, 0b111],  # 5
  [0b111'u8, 0b100, 0b111, 0b101, 0b111],  # 6
  [0b111'u8, 0b001, 0b010, 0b010, 0b010],  # 7
  [0b111'u8, 0b101, 0b111, 0b101, 0b111],  # 8
  [0b111'u8, 0b101, 0b111, 0b001, 0b111],  # 9
]

proc drawDigit(sprite: var RgbaSprite, digit, x, y: int, color: RgbaColor) =
  if digit < 0 or digit > 9:
    return
  for row in 0 ..< 5:
    for col in 0 ..< 3:
      if (DigitPatterns[digit][row] and (0b100'u8 shr col)) != 0:
        sprite.putRgbaPixel(x + col, y + row, color)

proc drawNumber(sprite: var RgbaSprite, value, x, y: int, color: RgbaColor) =
  let text = $max(0, value)
  var cx = x
  for ch in text:
    sprite.drawDigit(ord(ch) - ord('0'), cx, y, color)
    cx += 4

proc numberWidth(value: int): int =
  let text = $max(0, value)
  text.len * 4 - 1

proc buildHudSprite(score: int, color: RgbaColor): RgbaSprite =
  let
    width = max(12, numberWidth(score) + 4)
    height = 9
  result = newRgbaSprite(width, height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      result.putRgbaPixel(x, y, HudBackdropColor)
  for x in 0 ..< width:
    result.putRgbaPixel(x, 0, HudBorderColor)
    result.putRgbaPixel(x, height - 1, HudBorderColor)
  for y in 0 ..< height:
    result.putRgbaPixel(0, y, HudBorderColor)
    result.putRgbaPixel(width - 1, y, HudBorderColor)
  result.drawNumber(score, 2, 2, color)

proc buildRespawnSprite(respawnTicks: int): RgbaSprite =
  let
    seconds = if respawnTicks > 0: 1 + (respawnTicks - 1) div TargetFps else: 0
    width = 24
    height = 9
  result = newRgbaSprite(width, height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      result.putRgbaPixel(x, y, HudBackdropColor)
  for x in 0 ..< width:
    result.putRgbaPixel(x, 0, HudBorderColor)
    result.putRgbaPixel(x, height - 1, HudBorderColor)
  for y in 0 ..< height:
    result.putRgbaPixel(0, y, HudBorderColor)
    result.putRgbaPixel(width - 1, y, HudBorderColor)
  if seconds > 0:
    result.drawNumber(seconds, 2, 2, HudBorderColor)

const ChatFont: array[95, array[5, uint8]] = [
  [0b000'u8, 0b000, 0b000, 0b000, 0b000],  # space
  [0b010'u8, 0b010, 0b010, 0b000, 0b010],  # !
  [0b101'u8, 0b101, 0b000, 0b000, 0b000],  # "
  [0b101'u8, 0b111, 0b101, 0b111, 0b101],  # #
  [0b011'u8, 0b110, 0b010, 0b011, 0b110],  # $
  [0b101'u8, 0b001, 0b010, 0b100, 0b101],  # %
  [0b010'u8, 0b101, 0b010, 0b101, 0b011],  # &
  [0b010'u8, 0b010, 0b000, 0b000, 0b000],  # '
  [0b001'u8, 0b010, 0b010, 0b010, 0b001],  # (
  [0b100'u8, 0b010, 0b010, 0b010, 0b100],  # )
  [0b101'u8, 0b010, 0b101, 0b000, 0b000],  # *
  [0b000'u8, 0b010, 0b111, 0b010, 0b000],  # +
  [0b000'u8, 0b000, 0b000, 0b010, 0b100],  # ,
  [0b000'u8, 0b000, 0b111, 0b000, 0b000],  # -
  [0b000'u8, 0b000, 0b000, 0b000, 0b010],  # .
  [0b001'u8, 0b001, 0b010, 0b100, 0b100],  # /
  [0b111'u8, 0b101, 0b101, 0b101, 0b111],  # 0
  [0b010'u8, 0b110, 0b010, 0b010, 0b111],  # 1
  [0b111'u8, 0b001, 0b111, 0b100, 0b111],  # 2
  [0b111'u8, 0b001, 0b111, 0b001, 0b111],  # 3
  [0b101'u8, 0b101, 0b111, 0b001, 0b001],  # 4
  [0b111'u8, 0b100, 0b111, 0b001, 0b111],  # 5
  [0b111'u8, 0b100, 0b111, 0b101, 0b111],  # 6
  [0b111'u8, 0b001, 0b010, 0b010, 0b010],  # 7
  [0b111'u8, 0b101, 0b111, 0b101, 0b111],  # 8
  [0b111'u8, 0b101, 0b111, 0b001, 0b111],  # 9
  [0b000'u8, 0b010, 0b000, 0b010, 0b000],  # :
  [0b000'u8, 0b010, 0b000, 0b010, 0b100],  # ;
  [0b001'u8, 0b010, 0b100, 0b010, 0b001],  # <
  [0b000'u8, 0b111, 0b000, 0b111, 0b000],  # =
  [0b100'u8, 0b010, 0b001, 0b010, 0b100],  # >
  [0b111'u8, 0b001, 0b011, 0b000, 0b010],  # ?
  [0b111'u8, 0b101, 0b111, 0b100, 0b111],  # @
  [0b010'u8, 0b101, 0b111, 0b101, 0b101],  # A
  [0b110'u8, 0b101, 0b110, 0b101, 0b110],  # B
  [0b011'u8, 0b100, 0b100, 0b100, 0b011],  # C
  [0b110'u8, 0b101, 0b101, 0b101, 0b110],  # D
  [0b111'u8, 0b100, 0b110, 0b100, 0b111],  # E
  [0b111'u8, 0b100, 0b110, 0b100, 0b100],  # F
  [0b011'u8, 0b100, 0b101, 0b101, 0b011],  # G
  [0b101'u8, 0b101, 0b111, 0b101, 0b101],  # H
  [0b111'u8, 0b010, 0b010, 0b010, 0b111],  # I
  [0b001'u8, 0b001, 0b001, 0b101, 0b010],  # J
  [0b101'u8, 0b101, 0b110, 0b101, 0b101],  # K
  [0b100'u8, 0b100, 0b100, 0b100, 0b111],  # L
  [0b101'u8, 0b111, 0b111, 0b101, 0b101],  # M
  [0b101'u8, 0b111, 0b111, 0b111, 0b101],  # N
  [0b010'u8, 0b101, 0b101, 0b101, 0b010],  # O
  [0b110'u8, 0b101, 0b110, 0b100, 0b100],  # P
  [0b010'u8, 0b101, 0b101, 0b111, 0b011],  # Q
  [0b110'u8, 0b101, 0b110, 0b101, 0b101],  # R
  [0b011'u8, 0b100, 0b010, 0b001, 0b110],  # S
  [0b111'u8, 0b010, 0b010, 0b010, 0b010],  # T
  [0b101'u8, 0b101, 0b101, 0b101, 0b111],  # U
  [0b101'u8, 0b101, 0b101, 0b101, 0b010],  # V
  [0b101'u8, 0b101, 0b111, 0b111, 0b101],  # W
  [0b101'u8, 0b101, 0b010, 0b101, 0b101],  # X
  [0b101'u8, 0b101, 0b010, 0b010, 0b010],  # Y
  [0b111'u8, 0b001, 0b010, 0b100, 0b111],  # Z
  [0b011'u8, 0b010, 0b010, 0b010, 0b011],  # [
  [0b100'u8, 0b100, 0b010, 0b001, 0b001],  # \
  [0b110'u8, 0b010, 0b010, 0b010, 0b110],  # ]
  [0b010'u8, 0b101, 0b000, 0b000, 0b000],  # ^
  [0b000'u8, 0b000, 0b000, 0b000, 0b111],  # _
  [0b100'u8, 0b010, 0b000, 0b000, 0b000],  # `
  [0b000'u8, 0b011, 0b101, 0b101, 0b011],  # a
  [0b100'u8, 0b110, 0b101, 0b101, 0b110],  # b
  [0b000'u8, 0b011, 0b100, 0b100, 0b011],  # c
  [0b001'u8, 0b011, 0b101, 0b101, 0b011],  # d
  [0b000'u8, 0b010, 0b111, 0b100, 0b011],  # e
  [0b001'u8, 0b010, 0b111, 0b010, 0b010],  # f
  [0b000'u8, 0b011, 0b101, 0b011, 0b110],  # g
  [0b100'u8, 0b110, 0b101, 0b101, 0b101],  # h
  [0b010'u8, 0b000, 0b010, 0b010, 0b010],  # i
  [0b010'u8, 0b000, 0b010, 0b010, 0b100],  # j
  [0b100'u8, 0b101, 0b110, 0b101, 0b101],  # k
  [0b110'u8, 0b010, 0b010, 0b010, 0b010],  # l
  [0b000'u8, 0b101, 0b111, 0b101, 0b101],  # m
  [0b000'u8, 0b110, 0b101, 0b101, 0b101],  # n
  [0b000'u8, 0b010, 0b101, 0b101, 0b010],  # o
  [0b000'u8, 0b110, 0b101, 0b110, 0b100],  # p
  [0b000'u8, 0b011, 0b101, 0b011, 0b001],  # q
  [0b000'u8, 0b011, 0b100, 0b100, 0b100],  # r
  [0b000'u8, 0b011, 0b010, 0b110, 0b000],  # s (simplified)
  [0b010'u8, 0b111, 0b010, 0b010, 0b001],  # t
  [0b000'u8, 0b101, 0b101, 0b101, 0b011],  # u
  [0b000'u8, 0b101, 0b101, 0b101, 0b010],  # v
  [0b000'u8, 0b101, 0b111, 0b111, 0b101],  # w (simplified)
  [0b000'u8, 0b101, 0b010, 0b010, 0b101],  # x
  [0b000'u8, 0b101, 0b011, 0b001, 0b110],  # y
  [0b000'u8, 0b111, 0b010, 0b100, 0b111],  # z
  [0b001'u8, 0b010, 0b100, 0b010, 0b001],  # {
  [0b010'u8, 0b010, 0b010, 0b010, 0b010],  # |
  [0b100'u8, 0b010, 0b001, 0b010, 0b100],  # }
  [0b000'u8, 0b011, 0b110, 0b000, 0b000],  # ~
]

proc chatTextWidth(text: string): int =
  if text.len == 0: return 0
  text.len * ChatGlyphWidth - 1

proc drawChatChar(sprite: var RgbaSprite, ch: char, x, y: int, color: RgbaColor) =
  let idx = ord(ch) - 32
  if idx < 0 or idx >= ChatFont.len:
    return
  for row in 0 ..< ChatGlyphHeight:
    for col in 0 ..< 3:
      if (ChatFont[idx][row] and (0b100'u8 shr col)) != 0:
        sprite.putRgbaPixel(x + col, y + row, color)

proc drawChatText(sprite: var RgbaSprite, text: string, x, y: int, color: RgbaColor) =
  var dx = x
  for ch in text:
    sprite.drawChatChar(ch, dx, y, color)
    dx += ChatGlyphWidth

proc buildChatBubbleSprite(text: string, color: RgbaColor): RgbaSprite =
  let
    textWidth = max(ChatGlyphWidth, chatTextWidth(text))
    bodyWidth = textWidth + ChatPad * 2
    bodyHeight = ChatGlyphHeight + ChatPad * 2
    totalHeight = bodyHeight + ChatPointerHeight
  result = newRgbaSprite(bodyWidth, totalHeight)
  let
    borderColor = color
    fillColor = HudBackdropColor
    textColor = RgbaColor(r: 255, g: 255, b: 255, a: 255)
  for y in 0 ..< bodyHeight:
    for x in 0 ..< bodyWidth:
      if x == 0 or x == bodyWidth - 1 or y == 0 or y == bodyHeight - 1:
        result.putRgbaPixel(x, y, borderColor)
      else:
        result.putRgbaPixel(x, y, fillColor)
  let pointerX = bodyWidth div 2
  for py in 0 ..< ChatPointerHeight:
    result.putRgbaPixel(pointerX - py, bodyHeight + py, borderColor)
    result.putRgbaPixel(pointerX + py, bodyHeight + py, borderColor)
  result.drawChatText(text, ChatPad, ChatPad, textColor)

proc buildScoreboardSprite(sim: SimServer): RgbaSprite =
  if sim.players.len == 0:
    return newRgbaSprite(1, 1)
  let
    lineHeight = 7
    padding = 2
    swatchSize = 5
    gap = 2
    height = sim.players.len * lineHeight + padding * 2
  var maxScoreWidth = 0
  for player in sim.players:
    let w = chatTextWidth($player.score)
    if w > maxScoreWidth:
      maxScoreWidth = w
  let width = padding + swatchSize + gap + maxScoreWidth + padding + 2
  result = newRgbaSprite(width, height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      result.putRgbaPixel(x, y, HudBackdropColor)
  for x in 0 ..< width:
    result.putRgbaPixel(x, 0, HudBorderColor)
    result.putRgbaPixel(x, height - 1, HudBorderColor)
  for y in 0 ..< height:
    result.putRgbaPixel(0, y, HudBorderColor)
    result.putRgbaPixel(width - 1, y, HudBorderColor)
  for i, player in sim.players:
    let ty = padding + i * lineHeight + 1
    for sy in 0 ..< swatchSize:
      for sx in 0 ..< swatchSize:
        result.putRgbaPixel(padding + sx, ty + sy, player.color)
    result.drawChatText($player.score, padding + swatchSize + gap, ty, RgbaColor(r: 255, g: 255, b: 255, a: 255))

proc buildSpriteProtocolUpdates*(
  sim: SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[uint8] =
  result = @[]
  nextState = state

  if not nextState.initialized:
    result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    result.addViewport(MapLayerId, WorldWidthPixels, WorldHeightPixels)
    result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
    result.addViewport(TopLeftLayerId, 128, 128)
    let background = sim.buildBackgroundSprite(WorldWidthPixels, WorldHeightPixels)
    result.addSpriteCached(
      nextState.spriteCache,
      MapSpriteId,
      background.width,
      background.height,
      background.pixels,
      "starfield"
    )
    nextState.initialized = true

  var currentIds: seq[int] = @[]

  # Background object
  currentIds.add(MapObjectId)
  result.addObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)

  # Ship sprites and objects
  for playerIndex, player in sim.players:
    if not player.alive:
      continue
    if player.invulnTicks > 0 and ((player.invulnTicks div 2) mod 2 == 0):
      continue
    let
      thrust = player.thrustTicks > 0
      sprId = shipSpriteId(playerIndex, player.facing, thrust)
      ship = buildShipSprite(player.color, player.facing, thrust)
      sx = player.x div MotionScale - ship.width div 2
      sy = player.y div MotionScale - ship.height div 2
      objId = ShipObjectBase + playerIndex
    result.addSpriteCached(nextState.spriteCache, sprId, ship.width, ship.height, ship.pixels, "ship")
    result.addObject(objId, sx, sy, sy + 100, MapLayerId, sprId)
    currentIds.add(objId)

    if player.invulnTicks > 0:
      let
        shield = buildShieldSprite()
        shieldSprId = ShieldSpriteBase + playerIndex
        shieldObjId = ShipObjectBase + 100 + playerIndex
        shieldX = player.x div MotionScale - shield.width div 2
        shieldY = player.y div MotionScale - shield.height div 2
      result.addSpriteCached(nextState.spriteCache, shieldSprId, shield.width, shield.height, shield.pixels, "shield")
      result.addObject(shieldObjId, shieldX, shieldY, sy + 101, MapLayerId, shieldSprId)
      currentIds.add(shieldObjId)

  # Chat bubbles above ships
  for playerIndex, player in sim.players:
    if player.message.len == 0 or player.messageTicks <= 0:
      continue
    if not player.alive:
      continue
    let
      bubble = buildChatBubbleSprite(player.message, player.color)
      sx = player.x div MotionScale - bubble.width div 2
      sy = player.y div MotionScale - 9 div 2 - bubble.height - ChatGapY
      sprId = ChatSpriteBase + playerIndex
      objId = ChatObjectBase + playerIndex
    result.addSpriteCached(nextState.spriteCache, sprId, bubble.width, bubble.height, bubble.pixels, "chat")
    result.addObject(objId, sx, sy, sy + 300, MapLayerId, sprId)
    currentIds.add(objId)

  # Asteroid sprites and objects
  for i, asteroid in sim.asteroids:
    let
      sprId = asteroidSpriteId(asteroid)
      spr = buildAsteroidSprite(asteroid)
      sx = asteroid.x div MotionScale - spr.width div 2
      sy = asteroid.y div MotionScale - spr.height div 2
      objId = AsteroidObjectBase + (asteroid.id mod 1000)
    result.addSpriteCached(nextState.spriteCache, sprId, spr.width, spr.height, spr.pixels, "asteroid")
    result.addObject(objId, sx, sy, sy, MapLayerId, sprId)
    currentIds.add(objId)

  # Bullet sprites and objects
  for i, bullet in sim.bullets:
    let
      playerIndex = sim.playerIndexById(bullet.ownerId)
      sprId = bulletSpriteId(max(0, playerIndex))
      spr = buildBulletSprite(bullet.color)
      sx = bullet.x div MotionScale - 1
      sy = bullet.y div MotionScale - 1
      objId = BulletObjectBase + i
    result.addSpriteCached(nextState.spriteCache, sprId, spr.width, spr.height, spr.pixels, "bullet")
    result.addObject(objId, sx, sy, sy + 50, MapLayerId, sprId)
    currentIds.add(objId)

  # Explosion sprites and objects
  for i, explosion in sim.explosions:
    let
      sprId = explosionSpriteId(i)
      spr = buildExplosionSprite(explosion)
      sx = explosion.x div MotionScale - spr.width div 2
      sy = explosion.y div MotionScale - spr.height div 2
      objId = ExplosionObjectBase + i
    result.addSpriteCached(nextState.spriteCache, sprId, spr.width, spr.height, spr.pixels, "explosion")
    result.addObject(objId, sx, sy, sy + 200, MapLayerId, sprId)
    currentIds.add(objId)

  for i, cp in sim.capturePoints:
    let
      sprId = CaptureSpriteBase + i
      spr = buildCaptureSprite(sim, cp)
      sx = cp.x div MotionScale - spr.width div 2
      sy = cp.y div MotionScale - spr.height div 2
      objId = CaptureObjectBase + i
      label = if cp.owners.len > 0: "capture owned" else: "capture"
    result.addSpriteCached(nextState.spriteCache, sprId, spr.width, spr.height, spr.pixels, label)
    result.addObject(objId, sx, sy, -100, MapLayerId, sprId)
    currentIds.add(objId)

  # Scoreboard
  if sim.players.len > 0:
    let scoreboard = buildScoreboardSprite(sim)
    result.addSpriteCached(nextState.spriteCache, HudSpriteId, scoreboard.width, scoreboard.height, scoreboard.pixels, "scores")
    result.addObject(HudObjectId, 1, 1, high(int16), TopLeftLayerId, HudSpriteId)
    currentIds.add(HudObjectId)

  # Delete objects that disappeared
  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc buildSpriteProtocolPlayerUpdates*(
  sim: SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] =
  result = @[]
  nextState = state

  if not nextState.initialized:
    result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    result.addViewport(MapLayerId, ScreenWidth, ScreenHeight)
    result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
    result.addViewport(TopLeftLayerId, ScreenWidth, 12)
    nextState.initialized = true

  var currentIds: seq[int] = @[]

  if playerIndex < 0 or playerIndex >= sim.players.len:
    # No player assigned yet
    for objectId in state.objectIds:
      if objectId notin currentIds:
        result.addDeleteObject(objectId)
    nextState.objectIds = currentIds
    return

  let
    player = sim.players[playerIndex]
    cameraX = player.x
    cameraY = player.y
    cameraPixelX = cameraX div MotionScale - ScreenWidth div 2
    cameraPixelY = cameraY div MotionScale - ScreenHeight div 2

  # Background sprite with wrapped stars
  let background = sim.buildPlayerBackgroundSprite(cameraPixelX, cameraPixelY)
  result.addSpriteCached(
    nextState.spriteCache,
    MapSpriteId,
    background.width,
    background.height,
    background.pixels,
    "starfield"
  )
  currentIds.add(MapObjectId)
  result.addObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)

  # Ships
  for pi, p in sim.players:
    if not p.alive:
      continue
    # Blink other ships during invuln, but always show the viewer's own ship
    if pi != playerIndex and p.invulnTicks > 0 and ((p.invulnTicks div 2) mod 2 == 0):
      continue
    let
      thrust = p.thrustTicks > 0
      sprId = shipSpriteId(pi, p.facing, thrust)
      ship = buildShipSprite(p.color, p.facing, thrust)
      screenX = ScreenWidth div 2 + wrappedDelta(p.x, cameraX, WorldWidthUnits) div MotionScale
      screenY = ScreenHeight div 2 + wrappedDelta(p.y, cameraY, WorldHeightUnits) div MotionScale
      sx = screenX - ship.width div 2
      sy = screenY - ship.height div 2
    if sx > -ship.width and sx < ScreenWidth and sy > -ship.height and sy < ScreenHeight:
      let objId = ShipObjectBase + pi
      result.addSpriteCached(nextState.spriteCache, sprId, ship.width, ship.height, ship.pixels, "ship")
      result.addObject(objId, sx, sy, sy + 100, MapLayerId, sprId)
      currentIds.add(objId)

      if p.invulnTicks > 0:
        let
          shield = buildShieldSprite()
          shieldSprId = ShieldSpriteBase + pi
          shieldObjId = ShipObjectBase + 100 + pi
          shieldX = screenX - shield.width div 2
          shieldY = screenY - shield.height div 2
        result.addSpriteCached(nextState.spriteCache, shieldSprId, shield.width, shield.height, shield.pixels, "shield")
        result.addObject(shieldObjId, shieldX, shieldY, sy + 101, MapLayerId, shieldSprId)
        currentIds.add(shieldObjId)

  # Chat bubbles above ships
  for pi, p in sim.players:
    if p.message.len == 0 or p.messageTicks <= 0:
      continue
    if not p.alive:
      continue
    let
      bubble = buildChatBubbleSprite(p.message, p.color)
      screenX = ScreenWidth div 2 + wrappedDelta(p.x, cameraX, WorldWidthUnits) div MotionScale
      screenY = ScreenHeight div 2 + wrappedDelta(p.y, cameraY, WorldHeightUnits) div MotionScale
      bx = screenX - bubble.width div 2
      by = screenY - 9 div 2 - bubble.height - ChatGapY
    if bx > -bubble.width and bx < ScreenWidth and by > -bubble.height and by < ScreenHeight:
      let
        sprId = ChatSpriteBase + pi
        objId = ChatObjectBase + pi
      result.addSpriteCached(nextState.spriteCache, sprId, bubble.width, bubble.height, bubble.pixels, "chat")
      result.addObject(objId, bx, by, by + 300, MapLayerId, sprId)
      currentIds.add(objId)

  # Asteroids
  for i, asteroid in sim.asteroids:
    let
      screenX = ScreenWidth div 2 + wrappedDelta(asteroid.x, cameraX, WorldWidthUnits) div MotionScale
      screenY = ScreenHeight div 2 + wrappedDelta(asteroid.y, cameraY, WorldHeightUnits) div MotionScale
      spr = buildAsteroidSprite(asteroid)
      sx = screenX - spr.width div 2
      sy = screenY - spr.height div 2
    if sx > -spr.width and sx < ScreenWidth and sy > -spr.height and sy < ScreenHeight:
      let
        sprId = asteroidSpriteId(asteroid)
        objId = AsteroidObjectBase + (asteroid.id mod 1000)
      result.addSpriteCached(nextState.spriteCache, sprId, spr.width, spr.height, spr.pixels, "asteroid")
      result.addObject(objId, sx, sy, sy, MapLayerId, sprId)
      currentIds.add(objId)

  # Bullets
  for i, bullet in sim.bullets:
    let
      screenX = ScreenWidth div 2 + wrappedDelta(bullet.x, cameraX, WorldWidthUnits) div MotionScale
      screenY = ScreenHeight div 2 + wrappedDelta(bullet.y, cameraY, WorldHeightUnits) div MotionScale
    if screenX >= -1 and screenX < ScreenWidth + 1 and screenY >= -1 and screenY < ScreenHeight + 1:
      let
        pIdx = sim.playerIndexById(bullet.ownerId)
        sprId = bulletSpriteId(max(0, pIdx))
        spr = buildBulletSprite(bullet.color)
        sx = screenX - 1
        sy = screenY - 1
        objId = BulletObjectBase + i
      result.addSpriteCached(nextState.spriteCache, sprId, spr.width, spr.height, spr.pixels, "bullet")
      result.addObject(objId, sx, sy, sy + 50, MapLayerId, sprId)
      currentIds.add(objId)

  # Explosions
  for i, explosion in sim.explosions:
    let
      screenX = ScreenWidth div 2 + wrappedDelta(explosion.x, cameraX, WorldWidthUnits) div MotionScale
      screenY = ScreenHeight div 2 + wrappedDelta(explosion.y, cameraY, WorldHeightUnits) div MotionScale
      spr = buildExplosionSprite(explosion)
      sx = screenX - spr.width div 2
      sy = screenY - spr.height div 2
    if sx > -spr.width and sx < ScreenWidth and sy > -spr.height and sy < ScreenHeight:
      let
        sprId = explosionSpriteId(i)
        objId = ExplosionObjectBase + i
      result.addSpriteCached(nextState.spriteCache, sprId, spr.width, spr.height, spr.pixels, "explosion")
      result.addObject(objId, sx, sy, sy + 200, MapLayerId, sprId)
      currentIds.add(objId)

  for i, cp in sim.capturePoints:
    let
      screenX = ScreenWidth div 2 + wrappedDelta(cp.x, cameraX, WorldWidthUnits) div MotionScale
      screenY = ScreenHeight div 2 + wrappedDelta(cp.y, cameraY, WorldHeightUnits) div MotionScale
      spr = buildCaptureSprite(sim, cp)
      sx = screenX - spr.width div 2
      sy = screenY - spr.height div 2
    if sx > -spr.width and sx < ScreenWidth and sy > -spr.height and sy < ScreenHeight:
      let
        sprId = CaptureSpriteBase + i
        objId = CaptureObjectBase + i
        label = if cp.owners.len > 0: "capture owned" else: "capture"
      result.addSpriteCached(nextState.spriteCache, sprId, spr.width, spr.height, spr.pixels, label)
      result.addObject(objId, sx, sy, -100, MapLayerId, sprId)
      currentIds.add(objId)

  # HUD
  let hud = buildHudSprite(player.score, player.color)
  result.addSpriteCached(nextState.spriteCache, HudSpriteId, hud.width, hud.height, hud.pixels, "hud")
  result.addObject(HudObjectId, 1, 1, high(int16), TopLeftLayerId, HudSpriteId)
  currentIds.add(HudObjectId)

  # Respawn overlay
  if not player.alive:
    let respawn = buildRespawnSprite(player.respawnTicks)
    result.addSpriteCached(
      nextState.spriteCache,
      RespawnSpriteId,
      respawn.width,
      respawn.height,
      respawn.pixels,
      "respawn"
    )
    result.addObject(
      RespawnObjectId,
      (ScreenWidth - respawn.width) div 2,
      (ScreenHeight - respawn.height) div 2,
      high(int16),
      MapLayerId,
      RespawnSpriteId
    )
    currentIds.add(RespawnObjectId)

  # Delete objects that disappeared
  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

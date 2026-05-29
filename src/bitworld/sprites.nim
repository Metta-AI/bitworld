import
  std/math,
  pixie

type
  RgbaColor* = ColorRGBA
    ## A straight 32-bit RGBA color.

  RgbaSprite* = object
    ## A simple 32-bit RGBA sprite used by the sprite protocol.
    width*, height*: int
    pixels*: seq[uint8]

  SpriteBounds* = object
    ## The bounding box for non-transparent pixels.
    found*: bool
    minX*, minY*, maxX*, maxY*: int

proc newRgbaSprite*(width, height: int): RgbaSprite =
  ## Allocates one transparent RGBA sprite.
  result.width = max(0, width)
  result.height = max(0, height)
  result.pixels = newSeq[uint8](result.width * result.height * 4)

proc transparentRgbaSprite*(width, height: int): RgbaSprite =
  ## Builds one fully transparent RGBA sprite.
  newRgbaSprite(width, height)

proc blankRgbaSprite*(width, height: int): RgbaSprite =
  ## Builds one fully transparent RGBA sprite.
  newRgbaSprite(width, height)

proc rgbaSpriteIndex*(sprite: RgbaSprite, x, y: int): int =
  ## Returns one RGBA byte offset inside a sprite.
  (y * sprite.width + x) * 4

proc pixelOffset*(sprite: RgbaSprite, x, y: int): int =
  ## Returns one RGBA byte offset inside a sprite.
  sprite.rgbaSpriteIndex(x, y)

proc rgbaSpriteAt*(sprite: RgbaSprite, x, y: int): RgbaColor =
  ## Reads one RGBA pixel from a sprite.
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return rgba(0, 0, 0, 0)
  let offset = sprite.rgbaSpriteIndex(x, y)
  rgba(
    sprite.pixels[offset],
    sprite.pixels[offset + 1],
    sprite.pixels[offset + 2],
    sprite.pixels[offset + 3]
  )

proc rgbaPixel*(sprite: RgbaSprite, x, y: int): RgbaColor =
  ## Reads one RGBA pixel from a sprite.
  sprite.rgbaSpriteAt(x, y)

proc putRgbaPixel*(
  sprite: var RgbaSprite,
  x,
  y: int,
  color: RgbaColor
) =
  ## Writes one RGBA pixel into a sprite.
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return
  let offset = sprite.rgbaSpriteIndex(x, y)
  sprite.pixels[offset] = color.r
  sprite.pixels[offset + 1] = color.g
  sprite.pixels[offset + 2] = color.b
  sprite.pixels[offset + 3] = color.a

proc putRgbaSpritePixel*(
  sprite: var RgbaSprite,
  x,
  y: int,
  color: RgbaColor
) =
  ## Writes one RGBA pixel into a sprite.
  sprite.putRgbaPixel(x, y, color)

proc putPixel*(
  sprite: var RgbaSprite,
  x,
  y: int,
  color: RgbaColor
) =
  ## Writes one RGBA pixel into a sprite.
  sprite.putRgbaPixel(x, y, color)

proc solidRgbaSprite*(
  width,
  height: int,
  color: RgbaColor
): RgbaSprite =
  ## Builds one solid RGBA sprite.
  result = newRgbaSprite(width, height)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      result.putRgbaPixel(x, y, color)

proc outlineRgbaSprite*(
  width,
  height: int,
  color: RgbaColor
): RgbaSprite =
  ## Builds a transparent rectangle outline sprite.
  result = newRgbaSprite(width, height)
  if width <= 0 or height <= 0:
    return
  for x in 0 ..< width:
    result.putRgbaPixel(x, 0, color)
    result.putRgbaPixel(x, height - 1, color)
  for y in 0 ..< height:
    result.putRgbaPixel(0, y, color)
    result.putRgbaPixel(width - 1, y, color)

proc imageRgbaSprite*(image: Image): RgbaSprite =
  ## Converts a Pixie image to an RGBA sprite.
  result = newRgbaSprite(image.width, image.height)
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      result.putRgbaPixel(x, y, image[x, y])

proc cellRgbaSprite*(
  image: Image,
  cellX,
  cellY,
  size: int
): RgbaSprite =
  ## Slices one square cell from a Pixie image.
  result = newRgbaSprite(size, size)
  let
    baseX = cellX * size
    baseY = cellY * size
  for y in 0 ..< size:
    for x in 0 ..< size:
      result.putRgbaPixel(x, y, image[baseX + x, baseY + y])

proc pixelsMatch*(a, b: openArray[uint8]): bool =
  ## Returns true when two RGBA pixel payloads match.
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc copyPixels*(pixels: openArray[uint8]): seq[uint8] =
  ## Copies one RGBA pixel payload.
  result = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    result[i] = pixels[i]

proc withAlpha*(color: RgbaColor, alpha: uint8): RgbaColor =
  ## Returns a color with a replaced alpha channel.
  rgba(color.r, color.g, color.b, alpha)

proc scaleColor*(color: RgbaColor, percent: int): RgbaColor =
  ## Returns a color scaled by a percentage.
  rgba(
    uint8(clamp(int(color.r) * percent div 100, 0, 255)),
    uint8(clamp(int(color.g) * percent div 100, 0, 255)),
    uint8(clamp(int(color.b) * percent div 100, 0, 255)),
    color.a
  )

proc mixColor*(a, b: RgbaColor, bPercent: int): RgbaColor =
  ## Returns a linear mix of two colors.
  let percent = clamp(bPercent, 0, 100)
  rgba(
    uint8((int(a.r) * (100 - percent) + int(b.r) * percent) div 100),
    uint8((int(a.g) * (100 - percent) + int(b.g) * percent) div 100),
    uint8((int(a.b) * (100 - percent) + int(b.b) * percent) div 100),
    max(a.a, b.a)
  )

proc stainColor*(source, tint: RgbaColor): RgbaColor =
  ## Applies a tint while preserving source alpha.
  if source.a == 0'u8:
    return rgba(0, 0, 0, 0)
  let strength = max(int(source.r), max(int(source.g), int(source.b)))
  rgba(
    uint8(int(tint.r) * strength div 255),
    uint8(int(tint.g) * strength div 255),
    uint8(int(tint.b) * strength div 255),
    source.a
  )

proc clamp01(value: float): float =
  ## Clamps one floating-point value into the unit interval.
  if value < 0.0:
    return 0.0
  if value > 1.0:
    return 1.0
  value

proc wrapHue(value: float): float =
  ## Wraps one hue value into the unit interval.
  result = value
  while result < 0.0:
    result += 1.0
  while result >= 1.0:
    result -= 1.0

proc mixHue(source, target, amount: float): float =
  ## Mixes between two hue values on the shortest color-wheel path.
  var delta = target - source
  if delta > 0.5:
    delta -= 1.0
  elif delta < -0.5:
    delta += 1.0
  wrapHue(source + delta * amount.clamp01())

proc colorToHsv(color: RgbaColor): tuple[h, s, v: float] =
  ## Converts one RGB color to HSV values in the unit interval.
  let
    r = float(color.r) / 255.0
    g = float(color.g) / 255.0
    b = float(color.b) / 255.0
    maxValue = max(r, max(g, b))
    minValue = min(r, min(g, b))
    delta = maxValue - minValue
  result.v = maxValue
  if maxValue <= 0.0:
    return
  result.s = delta / maxValue
  if delta <= 0.0:
    return
  if maxValue == r:
    result.h = ((g - b) / delta) / 6.0
  elif maxValue == g:
    result.h = (((b - r) / delta) + 2.0) / 6.0
  else:
    result.h = (((r - g) / delta) + 4.0) / 6.0
  result.h = result.h.wrapHue()

proc hsvToColor(h, s, v: float, alpha: uint8): RgbaColor =
  ## Converts HSV values in the unit interval to one RGBA color.
  let
    hue = h.wrapHue() * 6.0
    sector = int(floor(hue))
    fraction = hue - float(sector)
    value = v.clamp01()
    saturation = s.clamp01()
    p = value * (1.0 - saturation)
    q = value * (1.0 - saturation * fraction)
    t = value * (1.0 - saturation * (1.0 - fraction))
  var
    r = value
    g = t
    b = p
  case sector mod 6
  of 0:
    r = value
    g = t
    b = p
  of 1:
    r = q
    g = value
    b = p
  of 2:
    r = p
    g = value
    b = t
  of 3:
    r = p
    g = q
    b = value
  of 4:
    r = t
    g = p
    b = value
  else:
    r = value
    g = p
    b = q
  rgba(
    uint8(round(r * 255.0).clamp(0.0, 255.0)),
    uint8(round(g * 255.0).clamp(0.0, 255.0)),
    uint8(round(b * 255.0).clamp(0.0, 255.0)),
    alpha
  )

proc hsvTinted*(
  sprite: RgbaSprite,
  targetHue,
  hueMix,
  saturationScale,
  valueScale: float
): RgbaSprite =
  ## Builds one HSV-tinted copy of an RGBA sprite.
  result = newRgbaSprite(sprite.width, sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let
        offset = sprite.rgbaSpriteIndex(x, y)
        alpha = sprite.pixels[offset + 3]
      if alpha == 0:
        continue
      let hsv = rgba(
        sprite.pixels[offset],
        sprite.pixels[offset + 1],
        sprite.pixels[offset + 2],
        alpha
      ).colorToHsv()
      result.putRgbaPixel(
        x,
        y,
        hsvToColor(
          hsv.h.mixHue(targetHue, hueMix),
          hsv.s * saturationScale,
          hsv.v * valueScale,
          alpha
        )
      )

proc drawHorizontal*(
  sprite: var RgbaSprite,
  x0,
  x1,
  y: int,
  color: RgbaColor
) =
  ## Draws one clipped horizontal stroke.
  if y < 0 or y >= sprite.height:
    return
  let
    left = max(0, min(x0, x1))
    right = min(sprite.width - 1, max(x0, x1))
  if left > right:
    return
  for x in left .. right:
    sprite.putRgbaPixel(x, y, color)

proc drawHSpan*(
  sprite: var RgbaSprite,
  x0,
  x1,
  y: int,
  color: RgbaColor
) =
  ## Draws one clipped horizontal span.
  sprite.drawHorizontal(x0, x1, y, color)

proc drawVertical*(
  sprite: var RgbaSprite,
  x,
  y0,
  y1: int,
  color: RgbaColor
) =
  ## Draws one clipped vertical stroke.
  if x < 0 or x >= sprite.width:
    return
  let
    top = max(0, min(y0, y1))
    bottom = min(sprite.height - 1, max(y0, y1))
  if top > bottom:
    return
  for y in top .. bottom:
    sprite.putRgbaPixel(x, y, color)

proc fillRect*(
  sprite: var RgbaSprite,
  x,
  y,
  width,
  height: int,
  color: RgbaColor
) =
  ## Draws one clipped filled rectangle into a sprite.
  if width <= 0 or height <= 0:
    return
  let
    left = max(0, x)
    top = max(0, y)
    right = min(sprite.width, x + width)
    bottom = min(sprite.height, y + height)
  if left >= right or top >= bottom:
    return
  for py in top ..< bottom:
    for px in left ..< right:
      sprite.putRgbaPixel(px, py, color)

proc strokeRect*(
  sprite: var RgbaSprite,
  x,
  y,
  width,
  height: int,
  color: RgbaColor
) =
  ## Draws one rectangle outline into a sprite.
  if width <= 0 or height <= 0:
    return
  let
    x1 = x + width - 1
    y1 = y + height - 1
  sprite.drawHorizontal(x, x1, y, color)
  sprite.drawHorizontal(x, x1, y1, color)
  sprite.drawVertical(x, y, y1, color)
  sprite.drawVertical(x1, y, y1, color)

proc drawLine*(
  sprite: var RgbaSprite,
  x0,
  y0,
  x1,
  y1: int,
  color: RgbaColor
) =
  ## Draws one clipped Bresenham line into a sprite.
  var
    x = x0
    y = y0
    error = abs(x1 - x0) - abs(y1 - y0)
  let
    stepX =
      if x0 < x1:
        1
      else:
        -1
    stepY =
      if y0 < y1:
        1
      else:
        -1
  while true:
    sprite.putRgbaPixel(x, y, color)
    if x == x1 and y == y1:
      break
    let e2 = error * 2
    if e2 > -abs(y1 - y0):
      error -= abs(y1 - y0)
      x += stepX
    if e2 < abs(x1 - x0):
      error += abs(x1 - x0)
      y += stepY

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

proc drawCircleFill*(
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

proc drawCircleRing*(
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

proc blitRgbaSprite*(
  target: var RgbaSprite,
  source: RgbaSprite,
  x,
  y: int
) =
  ## Blits one RGBA sprite onto another with alpha blending.
  for sy in 0 ..< source.height:
    let ty = y + sy
    if ty < 0 or ty >= target.height:
      continue
    for sx in 0 ..< source.width:
      let tx = x + sx
      if tx < 0 or tx >= target.width:
        continue
      let
        sourceOffset = source.rgbaSpriteIndex(sx, sy)
        sourceAlpha = int(source.pixels[sourceOffset + 3])
      if sourceAlpha <= 0:
        continue
      let targetOffset = target.rgbaSpriteIndex(tx, ty)
      if sourceAlpha == 255 or target.pixels[targetOffset + 3] == 0:
        for i in 0 .. 3:
          target.pixels[targetOffset + i] = source.pixels[sourceOffset + i]
        continue
      let
        targetAlpha = int(target.pixels[targetOffset + 3])
        outAlpha = sourceAlpha + targetAlpha * (255 - sourceAlpha) div 255
      if outAlpha <= 0:
        continue
      for i in 0 .. 2:
        let value =
          (
            int(source.pixels[sourceOffset + i]) * sourceAlpha +
            int(target.pixels[targetOffset + i]) * targetAlpha *
              (255 - sourceAlpha) div 255
          ) div outAlpha
        target.pixels[targetOffset + i] = value.uint8
      target.pixels[targetOffset + 3] = outAlpha.uint8

proc solidBounds*(
  sprite: RgbaSprite,
  alphaThreshold = 0'u8
): SpriteBounds =
  ## Measures the bounds of non-transparent pixels.
  result.minX = sprite.width
  result.minY = sprite.height
  result.maxX = -1
  result.maxY = -1
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      if sprite.rgbaSpriteAt(x, y).a <= alphaThreshold:
        continue
      result.found = true
      result.minX = min(result.minX, x)
      result.minY = min(result.minY, y)
      result.maxX = max(result.maxX, x)
      result.maxY = max(result.maxY, y)
  if not result.found:
    result.minX = 0
    result.minY = 0
    result.maxX = 0
    result.maxY = 0

proc blankMargins*(
  sprite: RgbaSprite,
  alphaThreshold = 0'u8
): tuple[left, top, right, bottom: int] =
  ## Measures transparent margins around non-transparent pixels.
  let bounds = sprite.solidBounds(alphaThreshold)
  if not bounds.found:
    return (
      left: sprite.width,
      top: sprite.height,
      right: sprite.width,
      bottom: sprite.height
    )
  (
    left: bounds.minX,
    top: bounds.minY,
    right: sprite.width - bounds.maxX - 1,
    bottom: sprite.height - bounds.maxY - 1
  )

proc outlinedSprite*(
  sprite: RgbaSprite,
  color: RgbaColor,
  alphaThreshold = 0'u8
): RgbaSprite =
  ## Builds an outline around non-transparent pixels.
  result = newRgbaSprite(sprite.width, sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      if sprite.rgbaSpriteAt(x, y).a <= alphaThreshold:
        continue
      for offset in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
        let
          px = x + offset[0]
          py = y + offset[1]
        if px < 0 or py < 0 or px >= sprite.width or py >= sprite.height:
          continue
        if sprite.rgbaSpriteAt(px, py).a <= alphaThreshold:
          result.putRgbaPixel(px, py, color)

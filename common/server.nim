import mummy
import pixie
import std/os
import protocol

type
  Facing* = enum
    FaceUp
    FaceDown
    FaceLeft
    FaceRight

  Sprite* = object
    width*, height*: int
    pixels*: seq[uint8]

  Framebuffer* = object
    indices*: seq[uint8]
    packed*: seq[uint8]

const
  TransparentColorIndex* = 255'u8

proc newServer*(
  handler: RequestHandler,
  websocketHandler: WebSocketHandler = nil,
  logHandler: LogHandler = nil,
  workerThreads: int,
  maxHeadersLen = 8 * 1024,
  maxBodyLen = 1024 * 1024,
  maxMessageLen = 64 * 1024,
  wsNoDelay: bool,
): mummy.Server =
  discard wsNoDelay
  mummy.newServer(
    handler,
    websocketHandler,
    logHandler,
    workerThreads,
    maxHeadersLen,
    maxBodyLen,
    maxMessageLen,
  )

proc spriteIndex*(sprite: Sprite, x, y: int): int =
  y * sprite.width + x

proc nearestPaletteIndex*(pixel: ColorRGBA): uint8 =
  if pixel.a < 20'u8:
    return TransparentColorIndex

  var best = 0
  var bestDistance = high(int)
  for index in 0 ..< Palette.len:
    let candidate = Palette[index]
    let dr = int(pixel.r) - int(candidate.r)
    let dg = int(pixel.g) - int(candidate.g)
    let db = int(pixel.b) - int(candidate.b)
    let da = int(pixel.a) - int(candidate.a)
    let distance = dr * dr + dg * dg + db * db + da * da
    if distance < bestDistance:
      bestDistance = distance
      best = index
  best.uint8

proc spriteFromImage*(image: Image): Sprite =
  result.width = image.width
  result.height = image.height
  result.pixels = newSeq[uint8](result.width * result.height)
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      result.pixels[result.spriteIndex(x, y)] = nearestPaletteIndex(image[x, y])

proc sliceSpriteStrip*(image: Image, spriteWidth, spriteHeight, count: int): seq[Sprite] =
  result = @[]
  for i in 0 ..< count:
    var sprite = Sprite(width: spriteWidth, height: spriteHeight)
    sprite.pixels = newSeq[uint8](spriteWidth * spriteHeight)
    let baseX = i * spriteWidth
    for y in 0 ..< spriteHeight:
      for x in 0 ..< spriteWidth:
        sprite.pixels[sprite.spriteIndex(x, y)] = nearestPaletteIndex(image[baseX + x, y])
    result.add(sprite)

proc loadDigitSprites*(path: string): array[10, Sprite] =
  if not fileExists(path):
    raise newException(IOError, "Missing digit sprite strip: " & path)

  let image = readImage(path)
  let digits = sliceSpriteStrip(image, 6, 6, 10)
  if digits.len != 10:
    raise newException(IOError, "Digit sprite strip must contain 10 digits: " & path)

  for i in 0 ..< 10:
    result[i] = digits[i]

proc loadLetterSprites*(path: string): seq[Sprite] =
  if not fileExists(path):
    raise newException(IOError, "Missing letter sprite strip: " & path)
  let image = readImage(path)
  sliceSpriteStrip(image, 6, 6, image.width div 6)

proc letterIndex*(ch: char): int =
  if ch >= 'A' and ch <= 'Z': return ord(ch) - ord('A')
  if ch >= 'a' and ch <= 'z': return ord(ch) - ord('a')
  case ch
  of ',': return 26
  of '.': return 27
  of '?': return 28
  of '!': return 29
  of '\'': return 30
  else: return -1

proc readRequiredSprite*(path: string): Sprite =
  if not fileExists(path):
    raise newException(IOError, "Missing sprite asset: " & path)
  spriteFromImage(readImage(path))

proc initFramebuffer*(): Framebuffer =
  result.indices = newSeq[uint8](ScreenWidth * ScreenHeight)
  result.packed = newSeq[uint8](ProtocolBytes)

proc clearFrame*(fb: var Framebuffer, bg: uint8 = 3) =
  for i in 0 ..< fb.indices.len:
    fb.indices[i] = bg

proc putPixel*(fb: var Framebuffer, x, y: int, index: uint8) =
  if x < 0 or y < 0 or x >= ScreenWidth or y >= ScreenHeight or index == TransparentColorIndex:
    return
  fb.indices[y * ScreenWidth + x] = index

proc blitSprite*(fb: var Framebuffer, sprite: Sprite, worldX, worldY, cameraX, cameraY: int, facing = FaceDown) =
  let
    screenX = worldX - cameraX
    screenY = worldY - cameraY
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        var dx = 0
        var dy = 0
        case facing
        of FaceDown:
          dx = x
          dy = y
        of FaceUp:
          dx = sprite.width - 1 - x
          dy = sprite.height - 1 - y
        of FaceLeft:
          dx = y
          dy = sprite.width - 1 - x
        of FaceRight:
          dx = sprite.height - 1 - y
          dy = x
        fb.putPixel(screenX + dx, screenY + dy, colorIndex)

proc blitSpriteTinted*(fb: var Framebuffer, sprite: Sprite, worldX, worldY, cameraX, cameraY: int, tint: uint8, facing = FaceDown) =
  let
    screenX = worldX - cameraX
    screenY = worldY - cameraY
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        var dx = 0
        var dy = 0
        case facing
        of FaceDown:
          dx = x
          dy = y
        of FaceUp:
          dx = sprite.width - 1 - x
          dy = sprite.height - 1 - y
        of FaceLeft:
          dx = y
          dy = sprite.width - 1 - x
        of FaceRight:
          dx = sprite.height - 1 - y
          dy = x
        fb.putPixel(screenX + dx, screenY + dy, tint)

proc blitText*(fb: var Framebuffer, letterSprites: seq[Sprite], text: string, screenX, screenY: int) =
  var offsetX = 0
  for ch in text:
    if ch == ' ':
      offsetX += 6
      continue
    let idx = letterIndex(ch)
    if idx >= 0 and idx < letterSprites.len:
      fb.blitSprite(letterSprites[idx], screenX + offsetX, screenY, 0, 0)
    offsetX += 6

proc packFramebuffer*(fb: var Framebuffer) =
  for i in 0 ..< fb.packed.len:
    let lo = fb.indices[i * 2] and 0x0F
    let hi = fb.indices[i * 2 + 1] and 0x0F
    fb.packed[i] = lo or (hi shl 4)

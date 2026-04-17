import pixie
import std/os

const
  ScreenWidth* = 64
  ScreenHeight* = 64
  TileSize* = 6
  ProtocolBytes* = (ScreenWidth * ScreenHeight) div 2
  InputPacketBytes* = 1
  DefaultHost* = "127.0.0.1"
  DefaultPort* = 1999

  ButtonUp* = 1'u8 shl 0
  ButtonDown* = 1'u8 shl 1
  ButtonLeft* = 1'u8 shl 2
  ButtonRight* = 1'u8 shl 3
  ButtonSelect* = 1'u8 shl 4
  ButtonAttack* = 1'u8 shl 5

type
  InputState* = object
    up*, down*, left*, right*, select*, attack*: bool

var Palette*: array[16, ColorRGBA]

proc loadPalette*(path = "data/pallete.png") =
  if not fileExists(path):
    raise newException(IOError, "Missing palette asset: " & path)

  let image = readImage(path)
  if image.width < Palette.len or image.height < 1:
    raise newException(IOError, "Palette asset must be at least 16x1: " & path)

  for x in 0 ..< Palette.len:
    Palette[x] = image[x, 0]

proc encodeInputMask*(input: InputState): uint8 =
  if input.up:
    result = result or ButtonUp
  if input.down:
    result = result or ButtonDown
  if input.left:
    result = result or ButtonLeft
  if input.right:
    result = result or ButtonRight
  if input.select:
    result = result or ButtonSelect
  if input.attack:
    result = result or ButtonAttack

proc decodeInputMask*(mask: uint8): InputState =
  result.up = (mask and ButtonUp) != 0
  result.down = (mask and ButtonDown) != 0
  result.left = (mask and ButtonLeft) != 0
  result.right = (mask and ButtonRight) != 0
  result.select = (mask and ButtonSelect) != 0
  result.attack = (mask and ButtonAttack) != 0

proc blobFromBytes*(bytes: openArray[uint8]): string =
  result = newString(bytes.len)
  for i, value in bytes:
    result[i] = char(value)

proc blobToBytes*(blob: string, bytes: var seq[uint8]) =
  if bytes.len != blob.len:
    bytes.setLen(blob.len)
  for i in 0 ..< blob.len:
    bytes[i] = blob[i].uint8

proc blobFromMask*(mask: uint8): string =
  result = newString(InputPacketBytes)
  result[0] = char(mask)

proc blobToMask*(blob: string): uint8 =
  if blob.len != InputPacketBytes:
    return 0
  blob[0].uint8

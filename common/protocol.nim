import pixie
import std/os

const
  ScreenWidth* = 128
  ScreenHeight* = 128
  TileSize* = 6
  ProtocolBytes* = (ScreenWidth * ScreenHeight) div 2
  PacketInput* = 0'u8
  PacketChat* = 1'u8
  InputPacketBytes* = 2
  DefaultHost* = "localhost"
  DefaultPort* = 8080

  ButtonUp* = 1'u8 shl 0
  ButtonDown* = 1'u8 shl 1
  ButtonLeft* = 1'u8 shl 2
  ButtonRight* = 1'u8 shl 3
  ButtonSelect* = 1'u8 shl 4
  ButtonA* = 1'u8 shl 5
  ButtonB* = 1'u8 shl 6

type
  InputState* = object
    up*, down*, left*, right*, select*, attack*, b*: bool

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
    result = result or ButtonA
  if input.b:
    result = result or ButtonB

proc decodeInputMask*(mask: uint8): InputState =
  result.up = (mask and ButtonUp) != 0
  result.down = (mask and ButtonDown) != 0
  result.left = (mask and ButtonLeft) != 0
  result.right = (mask and ButtonRight) != 0
  result.select = (mask and ButtonSelect) != 0
  result.attack = (mask and ButtonA) != 0
  result.b = (mask and ButtonB) != 0

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
  ## Builds a button packet from an input mask.
  result = newString(InputPacketBytes)
  result[0] = char(PacketInput)
  result[1] = char(mask)

proc isInputPacket*(blob: string): bool =
  ## Returns true when a blob is a button packet.
  blob.len == InputPacketBytes and blob[0].uint8 == PacketInput

proc isChatPacket*(blob: string): bool =
  ## Returns true when a blob is a chat packet.
  blob.len >= 1 and blob[0].uint8 == PacketChat

proc blobToMask*(blob: string): uint8 =
  ## Reads the input mask from a button packet.
  if not blob.isInputPacket():
    return 0
  blob[1].uint8

proc blobFromChat*(text: string): string =
  ## Builds a chat packet from ASCII text.
  result = newString(text.len + 1)
  result[0] = char(PacketChat)
  for i, ch in text:
    result[i + 1] = ch

proc blobToChat*(blob: string): string =
  ## Reads printable ASCII text from a chat packet.
  if not blob.isChatPacket():
    return ""
  for i in 1 ..< blob.len:
    let value = blob[i].uint8
    if value >= 32'u8 and value < 127'u8:
      result.add(blob[i])

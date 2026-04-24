import protocol

const
  RlWebSocketPath* = "/rl"
  RlResetMask* = 255'u8
  RlFrameMagicA* = 'B'.uint8
  RlFrameMagicB* = 'W'.uint8
  RlFrameVersion* = 1'u8
  RlFrameHeaderBytes* = 9
  RlFramePixels* = ScreenWidth * ScreenHeight
  RlFrameBytes* = RlFrameHeaderBytes + RlFramePixels

type
  RlMetric* = object
    score*, auxValue*: int

proc writeInt32Le*(bytes: var seq[uint8], offset: int, value: int) =
  let encoded = int32(value)
  bytes[offset + 0] = uint8((encoded shr 0) and 0xFF'i32)
  bytes[offset + 1] = uint8((encoded shr 8) and 0xFF'i32)
  bytes[offset + 2] = uint8((encoded shr 16) and 0xFF'i32)
  bytes[offset + 3] = uint8((encoded shr 24) and 0xFF'i32)

proc buildRlFramePacket*(pixels: openArray[uint8], metric: RlMetric, resetCounter = 0'u8): seq[uint8] =
  if pixels.len != RlFramePixels:
    raise newException(ValueError, "RL frame pixel buffer must be " & $RlFramePixels & " bytes")
  result = newSeq[uint8](RlFrameBytes)
  result[0] = RlFrameMagicA
  result[1] = RlFrameMagicB
  result[2] = RlFrameVersion
  result[3] = resetCounter
  result[4] = uint8(min(255, max(0, metric.auxValue)))
  result.writeInt32Le(5, metric.score)
  for i in 0 ..< RlFramePixels:
    result[RlFrameHeaderBytes + i] = pixels[i]

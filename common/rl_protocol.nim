import protocol, server

const
  RlWebSocketPath* = "/rl"
  RlResetMask* = 255'u8
  RlFrameMagicA* = 'B'.uint8
  RlFrameMagicB* = 'W'.uint8
  RlFrameVersion* = 1'u8
  RlFrameHeaderBytes* = 8
  RlFrameBytes* = RlFrameHeaderBytes + ScreenWidth * ScreenHeight

proc writeInt32Le*(bytes: var seq[uint8], offset: int, value: int) =
  let encoded = int32(value)
  bytes[offset + 0] = uint8((encoded shr 0) and 0xFF'i32)
  bytes[offset + 1] = uint8((encoded shr 8) and 0xFF'i32)
  bytes[offset + 2] = uint8((encoded shr 16) and 0xFF'i32)
  bytes[offset + 3] = uint8((encoded shr 24) and 0xFF'i32)

proc buildRlFramePacket*(fb: Framebuffer, score: int, auxValue = 0): seq[uint8] =
  result = newSeq[uint8](RlFrameBytes)
  result[0] = RlFrameMagicA
  result[1] = RlFrameMagicB
  result[2] = RlFrameVersion
  result[3] = uint8(min(255, max(0, auxValue)))
  result.writeInt32Le(4, score)
  for i in 0 ..< fb.indices.len:
    result[RlFrameHeaderBytes + i] = fb.indices[i]

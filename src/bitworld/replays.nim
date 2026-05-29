import
  std/[strutils, times],
  zippy

type
  ReplayError* = object of CatchableError

  ReplayJoinKind* = enum
    rjkNameSlotToken
    rjkAddress

  ReplayHashOrder* = enum
    rhoStop
    rhoError

  ReplaySpec* = object
    magic*: string
    formatVersion*: uint16
    gameName*: string
    gameVersion*: string
    joinKind*: ReplayJoinKind
    allowChat*: bool
    allowCompressed*: bool
    hashOrder*: ReplayHashOrder

  ReplayInput* = object
    time*: uint32
    player*: uint8
    keys*: uint8

  ReplayHash* = object
    tick*: uint32
    hash*: uint64

  ReplayJoin* = object
    time*: uint32
    player*: uint8
    name*: string
    slot*: int
    token*: string
    address*: string

  ReplayLeave* = object
    time*: uint32
    player*: uint8

  ReplayChat* = object
    time*: uint32
    player*: uint8
    message*: string

  ReplayData* = object
    gameName*: string
    gameVersion*: string
    configJson*: string
    joins*: seq[ReplayJoin]
    leaves*: seq[ReplayLeave]
    chats*: seq[ReplayChat]
    inputs*: seq[ReplayInput]
    hashes*: seq[ReplayHash]

  ReplayWriter* = object
    enabled*: bool
    file: File
    lastMasks*: seq[uint8]

const
  ReplayTickHashRecord* = 0x01'u8
  ReplayInputRecord* = 0x02'u8
  ReplayJoinRecord* = 0x03'u8
  ReplayLeaveRecord* = 0x04'u8
  ReplayChatRecord* = 0x05'u8

proc tickTime*(tick, fps: int): uint32 =
  ## Converts one simulation tick to replay milliseconds.
  uint32((int64(tick) * 1000'i64) div int64(fps))

proc writeU8(file: File, value: uint8) =
  ## Writes one unsigned byte.
  file.write(char(value))

proc writeU16(file: File, value: uint16) =
  ## Writes one little endian unsigned 16 bit value.
  file.writeU8(uint8(value and 0xff'u16))
  file.writeU8(uint8(value shr 8))

proc writeU32(file: File, value: uint32) =
  ## Writes one little endian unsigned 32 bit value.
  for shift in countup(0, 24, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u32))

proc writeI16(file: File, value: int) =
  ## Writes one little endian signed 16 bit value.
  file.writeU16(cast[uint16](int16(value)))

proc writeU64(file: File, value: uint64) =
  ## Writes one little endian unsigned 64 bit value.
  for shift in countup(0, 56, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u64))

proc writeReplayString(file: File, value: string) =
  ## Writes one replay string.
  if value.len > high(uint16).int:
    raise newException(ReplayError, "Replay string is too long")
  file.writeU16(uint16(value.len))
  file.write(value)

proc readU8(bytes: string, offset: var int): uint8 =
  ## Reads one unsigned byte from a replay buffer.
  if offset + 1 > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  result = bytes[offset].uint8
  inc offset

proc readU16(bytes: string, offset: var int): uint16 =
  ## Reads one little endian unsigned 16 bit value.
  if offset + 2 > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  result = uint16(bytes[offset].uint8) or
    (uint16(bytes[offset + 1].uint8) shl 8)
  offset += 2

proc readI16(bytes: string, offset: var int): int =
  ## Reads one little endian signed 16 bit value.
  int(cast[int16](bytes.readU16(offset)))

proc readU32(bytes: string, offset: var int): uint32 =
  ## Reads one little endian unsigned 32 bit value.
  if offset + 4 > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  for shift in countup(0, 24, 8):
    result = result or (uint32(bytes[offset].uint8) shl shift)
    inc offset

proc readU64(bytes: string, offset: var int): uint64 =
  ## Reads one little endian unsigned 64 bit value.
  if offset + 8 > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  for shift in countup(0, 56, 8):
    result = result or (uint64(bytes[offset].uint8) shl shift)
    inc offset

proc readReplayString(bytes: string, offset: var int): string =
  ## Reads one replay string.
  let length = int(bytes.readU16(offset))
  if offset + length > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  result = bytes[offset ..< offset + length]
  offset += length

proc isCompressedReplayBytes(bytes: string): bool =
  ## Returns true when bytes look like gzip or zlib compressed data.
  if bytes.len > 18:
    let
      b0 = bytes[0].uint8
      b1 = bytes[1].uint8
      b2 = bytes[2].uint8
      b3 = bytes[3].uint8
    if b0 == 31'u8 and b1 == 139'u8 and b2 == 8'u8 and
        (b3 and 224'u8) == 0'u8:
      return true

  if bytes.len > 6:
    let
      b0 = bytes[0].uint8
      b1 = bytes[1].uint8
    if (b0 and 15'u8) == 8'u8 and (b0 shr 4) <= 7'u8 and
        ((uint16(b0) * 256'u16 + uint16(b1)) mod 31'u16) == 0'u16:
      return true

  false

proc replayPayloadBytes(bytes: string, spec: ReplaySpec): string =
  ## Returns raw replay bytes, decompressing hosted artifacts if enabled.
  if bytes.startsWith(spec.magic):
    return bytes
  if spec.allowCompressed and bytes.isCompressedReplayBytes():
    return uncompress(bytes)
  bytes

proc openReplayWriter*(
  path: string,
  configJson: string,
  spec: ReplaySpec
): ReplayWriter =
  ## Opens one replay file and writes its header.
  if path.len == 0:
    return
  if not open(result.file, path, fmWrite):
    raise newException(IOError, "Could not open replay file: " & path)
  result.enabled = true
  result.lastMasks = @[]
  result.file.write(spec.magic)
  result.file.writeU16(spec.formatVersion)
  result.file.writeReplayString(spec.gameName)
  result.file.writeReplayString(spec.gameVersion)
  result.file.writeU64(uint64(toUnix(getTime())) * 1000'u64)
  result.file.writeReplayString(configJson)

proc closeReplayWriter*(writer: var ReplayWriter) =
  ## Closes a replay writer if it is open.
  if writer.enabled:
    writer.file.flushFile()
    writer.file.close()
    writer.enabled = false

proc flushReplayWriter*(writer: var ReplayWriter) =
  ## Flushes a replay writer if it is open.
  if writer.enabled:
    writer.file.flushFile()

proc writeJoin*(
  writer: var ReplayWriter,
  time: uint32,
  player: int,
  name: string,
  slot: int,
  token: string
) =
  ## Writes one name, slot, and token replay join record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayJoinRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(name)
  writer.file.writeI16(slot)
  writer.file.writeReplayString(token)

proc writeJoin*(
  writer: var ReplayWriter,
  time: uint32,
  player: int,
  address: string
) =
  ## Writes one address replay join record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayJoinRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(address)

proc writeLeave*(writer: var ReplayWriter, time: uint32, player: int) =
  ## Writes one player leave replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayLeaveRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))

proc writeInput*(writer: var ReplayWriter, input: ReplayInput) =
  ## Writes one player input replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayInputRecord)
  writer.file.writeU32(input.time)
  writer.file.writeU8(input.player)
  writer.file.writeU8(input.keys)

proc writeChat*(
  writer: var ReplayWriter,
  time: uint32,
  player: int,
  message: string
) =
  ## Writes one player chat replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayChatRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(message)

proc writeHash*(writer: var ReplayWriter, tick: uint32, hash: uint64) =
  ## Writes one tick hash replay record and flushes the writer.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayTickHashRecord)
  writer.file.writeU32(tick)
  writer.file.writeU64(hash)
  writer.flushReplayWriter()

proc readJoin(bytes: string, offset: var int, spec: ReplaySpec): ReplayJoin =
  ## Reads one replay join record body.
  result.time = bytes.readU32(offset)
  result.player = bytes.readU8(offset)
  case spec.joinKind
  of rjkNameSlotToken:
    result.name = bytes.readReplayString(offset)
    result.slot = bytes.readI16(offset)
    result.token = bytes.readReplayString(offset)
  of rjkAddress:
    result.address = bytes.readReplayString(offset)
    result.name = result.address

proc parseReplayBytes*(bytes: string, spec: ReplaySpec): ReplayData =
  ## Parses one replay file buffer into memory.
  let replayBytes = bytes.replayPayloadBytes(spec)
  var offset = 0
  if replayBytes.len < spec.magic.len:
    raise newException(ReplayError, "Replay file is truncated")
  if replayBytes[0 ..< spec.magic.len] != spec.magic:
    raise newException(ReplayError, "Replay magic does not match")
  offset = spec.magic.len
  let formatVersion = replayBytes.readU16(offset)
  if formatVersion != spec.formatVersion:
    raise newException(ReplayError, "Unsupported replay format version")
  result.gameName = replayBytes.readReplayString(offset)
  result.gameVersion = replayBytes.readReplayString(offset)
  discard replayBytes.readU64(offset)
  result.configJson = replayBytes.readReplayString(offset)
  if result.gameName != spec.gameName:
    raise newException(ReplayError, "Replay game name does not match")
  if result.gameVersion != spec.gameVersion:
    raise newException(ReplayError, "Replay game version does not match")

  var
    lastTick = -1
    lastInputTime = 0'u32
    lastJoinTime = 0'u32
    lastLeaveTime = 0'u32
    lastChatTime = 0'u32
  while offset < replayBytes.len:
    let recordType = replayBytes.readU8(offset)
    case recordType
    of ReplayTickHashRecord:
      let
        tick = replayBytes.readU32(offset)
        hash = replayBytes.readU64(offset)
      if int(tick) <= lastTick:
        case spec.hashOrder
        of rhoStop:
          break
        of rhoError:
          raise newException(ReplayError, "Replay tick hashes move backward")
      lastTick = int(tick)
      result.hashes.add(ReplayHash(tick: tick, hash: hash))
    of ReplayInputRecord:
      let input = ReplayInput(
        time: replayBytes.readU32(offset),
        player: replayBytes.readU8(offset),
        keys: replayBytes.readU8(offset)
      )
      if input.time < lastInputTime:
        raise newException(ReplayError, "Replay input timestamps move backward")
      lastInputTime = input.time
      result.inputs.add(input)
    of ReplayJoinRecord:
      let join = replayBytes.readJoin(offset, spec)
      if join.time < lastJoinTime:
        raise newException(ReplayError, "Replay join timestamps move backward")
      lastJoinTime = join.time
      result.joins.add(join)
    of ReplayLeaveRecord:
      let leave = ReplayLeave(
        time: replayBytes.readU32(offset),
        player: replayBytes.readU8(offset)
      )
      if leave.time < lastLeaveTime:
        raise newException(ReplayError, "Replay leave timestamps move backward")
      lastLeaveTime = leave.time
      result.leaves.add(leave)
    of ReplayChatRecord:
      if not spec.allowChat:
        raise newException(ReplayError, "Replay chat record is not supported")
      let chat = ReplayChat(
        time: replayBytes.readU32(offset),
        player: replayBytes.readU8(offset),
        message: replayBytes.readReplayString(offset)
      )
      if chat.time < lastChatTime:
        raise newException(ReplayError, "Replay chat timestamps move backward")
      lastChatTime = chat.time
      result.chats.add(chat)
    else:
      raise newException(ReplayError, "Unknown replay record type")

proc loadReplay*(path: string, spec: ReplaySpec): ReplayData =
  ## Loads one replay file into memory.
  parseReplayBytes(readFile(path), spec)

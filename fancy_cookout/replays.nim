import std/times

const
  GameName* = "fancy_cookout"
  GameVersion* = "1"
  ReplayMagic* = "BITWORLD"
  ReplayFormatVersion* = 3'u16
  ReplayTickHashRecord* = 0x01'u8
  ReplayInputRecord* = 0x02'u8
  ReplayJoinRecord* = 0x03'u8
  ReplayLeaveRecord* = 0x04'u8
  ReplayFps* = 24

type
  ReplayInput* = object
    time*: uint32
    player*: uint8
    keys*: uint8

  ReplayWriter* = object
    enabled*: bool
    file: File
    lastMasks*: seq[uint8]

proc tickTime*(tick: int): uint32 =
  uint32((int64(tick) * 1000'i64) div int64(ReplayFps))

proc writeU8(file: File, value: uint8) =
  file.write(char(value))

proc writeU16(file: File, value: uint16) =
  file.writeU8(uint8(value and 0xff'u16))
  file.writeU8(uint8(value shr 8))

proc writeU32(file: File, value: uint32) =
  for shift in countup(0, 24, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u32))

proc writeI16(file: File, value: int) =
  file.writeU16(cast[uint16](int16(value)))

proc writeU64(file: File, value: uint64) =
  for shift in countup(0, 56, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u64))

proc writeReplayString(file: File, value: string) =
  file.writeU16(uint16(value.len))
  file.write(value)

proc openReplayWriter*(path, configJson: string): ReplayWriter =
  if path.len == 0:
    return
  if not open(result.file, path, fmWrite):
    raise newException(IOError, "Could not open replay file: " & path)
  result.enabled = true
  result.lastMasks = @[]
  result.file.write(ReplayMagic)
  result.file.writeU16(ReplayFormatVersion)
  result.file.writeReplayString(GameName)
  result.file.writeReplayString(GameVersion)
  result.file.writeU64(uint64(toUnix(getTime())) * 1000'u64)
  result.file.writeReplayString(configJson)

proc closeReplayWriter*(writer: var ReplayWriter) =
  if writer.enabled:
    writer.file.flushFile()
    writer.file.close()
    writer.enabled = false

proc writeJoin*(
  writer: var ReplayWriter,
  time: uint32,
  player: int,
  name: string,
  slot: int,
  token: string
) =
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayJoinRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(name)
  writer.file.writeI16(slot)
  writer.file.writeReplayString(token)

proc writeLeave*(writer: var ReplayWriter, time: uint32, player: int) =
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayLeaveRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))

proc writeInput*(writer: var ReplayWriter, input: ReplayInput) =
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayInputRecord)
  writer.file.writeU32(input.time)
  writer.file.writeU8(input.player)
  writer.file.writeU8(input.keys)

proc writeHash*(writer: var ReplayWriter, tick: uint32, hash: uint64) =
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayTickHashRecord)
  writer.file.writeU32(tick)
  writer.file.writeU64(hash)
  writer.file.flushFile()

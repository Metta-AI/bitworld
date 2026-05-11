import std/times
import sim

type
  ReplayError* = object of CatchableError

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

  ReplayLeave* = object
    time*: uint32
    player*: uint8

  ReplayData* = object
    gameName*: string
    gameVersion*: string
    configJson*: string
    joins*: seq[ReplayJoin]
    leaves*: seq[ReplayLeave]
    inputs*: seq[ReplayInput]
    hashes*: seq[ReplayHash]

  ReplayWriter* = object
    enabled*: bool
    file: File
    lastMasks*: seq[uint8]

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*: int
    leaveIndex*: int
    inputIndex*: int
    hashIndex*: int
    masks*: seq[uint8]
    playing*: bool

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
  if value.len > high(uint16).int:
    raise newException(ReplayError, "Replay string is too long")
  file.writeU16(uint16(value.len))
  file.write(value)

proc readU8(bytes: string, offset: var int): uint8 =
  if offset + 1 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  result = bytes[offset].uint8
  inc offset

proc readU16(bytes: string, offset: var int): uint16 =
  if offset + 2 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  result = uint16(bytes[offset].uint8) or
    (uint16(bytes[offset + 1].uint8) shl 8)
  offset += 2

proc readI16(bytes: string, offset: var int): int =
  int(cast[int16](bytes.readU16(offset)))

proc readU32(bytes: string, offset: var int): uint32 =
  if offset + 4 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  for shift in countup(0, 24, 8):
    result = result or (uint32(bytes[offset].uint8) shl shift)
    inc offset

proc readU64(bytes: string, offset: var int): uint64 =
  if offset + 8 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  for shift in countup(0, 56, 8):
    result = result or (uint64(bytes[offset].uint8) shl shift)
    inc offset

proc readReplayString(bytes: string, offset: var int): string =
  let length = int(bytes.readU16(offset))
  if offset + length > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  result = bytes[offset ..< offset + length]
  offset += length

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

proc parseReplayBytes*(bytes: string): ReplayData =
  var offset = 0
  if bytes.len < ReplayMagic.len:
    raise newException(ReplayError, "Replay file is truncated")
  if bytes[0 ..< ReplayMagic.len] != ReplayMagic:
    raise newException(ReplayError, "Replay magic is not BITWORLD")
  offset = ReplayMagic.len
  let formatVersion = bytes.readU16(offset)
  if formatVersion != ReplayFormatVersion:
    raise newException(ReplayError, "Unsupported replay format version")
  result.gameName = bytes.readReplayString(offset)
  result.gameVersion = bytes.readReplayString(offset)
  discard bytes.readU64(offset)
  result.configJson = bytes.readReplayString(offset)
  if result.gameName != GameName:
    raise newException(ReplayError, "Replay game name does not match")
  if result.gameVersion != GameVersion:
    raise newException(ReplayError, "Replay game version does not match")

  var
    lastTick = -1
    lastInputTime = 0'u32
    lastJoinTime = 0'u32
    lastLeaveTime = 0'u32
  while offset < bytes.len:
    let recordType = bytes.readU8(offset)
    case recordType
    of ReplayTickHashRecord:
      let
        tick = bytes.readU32(offset)
        hash = bytes.readU64(offset)
      if int(tick) <= lastTick:
        break
      lastTick = int(tick)
      result.hashes.add(ReplayHash(tick: tick, hash: hash))
    of ReplayInputRecord:
      let input = ReplayInput(
        time: bytes.readU32(offset),
        player: bytes.readU8(offset),
        keys: bytes.readU8(offset)
      )
      if input.time < lastInputTime:
        raise newException(ReplayError, "Replay input timestamps move backward")
      lastInputTime = input.time
      result.inputs.add(input)
    of ReplayJoinRecord:
      let join = ReplayJoin(
        time: bytes.readU32(offset),
        player: bytes.readU8(offset),
        name: bytes.readReplayString(offset),
        slot: bytes.readI16(offset),
        token: bytes.readReplayString(offset)
      )
      if join.time < lastJoinTime:
        raise newException(ReplayError, "Replay join timestamps move backward")
      lastJoinTime = join.time
      result.joins.add(join)
    of ReplayLeaveRecord:
      let leave = ReplayLeave(
        time: bytes.readU32(offset),
        player: bytes.readU8(offset)
      )
      if leave.time < lastLeaveTime:
        raise newException(ReplayError, "Replay leave timestamps move backward")
      lastLeaveTime = leave.time
      result.leaves.add(leave)
    else:
      raise newException(ReplayError, "Unknown replay record type")

proc loadReplay*(path: string): ReplayData =
  parseReplayBytes(readFile(path))

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.masks = @[]
  result.playing = true

proc ensureReplayPlayer(replay: var ReplayPlayer, player: int) =
  while replay.masks.len <= player:
    replay.masks.add(0)

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  let time = tickTime(sim.tickCount)

  # Apply leaves
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    let idx = int(leave.player)
    if idx >= 0 and idx < sim.players.len:
      sim.players.delete(idx)
      if idx < replay.masks.len:
        replay.masks.delete(idx)
    inc replay.leaveIndex

  # Apply joins
  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    discard sim.addPlayer(join.name)
    replay.ensureReplayPlayer(int(join.player))
    inc replay.joinIndex

  # Apply input changes
  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensureReplayPlayer(int(input.player))
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

  # Build inputs from masks
  var inputs = newSeq[PlayerInput](sim.players.len)
  for i in 0 ..< sim.players.len:
    replay.ensureReplayPlayer(i)
    inputs[i] = playerInputFromMasks(replay.masks[i], 0)

  sim.step(inputs)

  # Check hash
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) > sim.tickCount:
    return
  if int(expected.tick) == sim.tickCount:
    let hash = sim.gameHash()
    if hash != expected.hash:
      raise newException(
        ReplayError,
        "Replay hash mismatch at tick " & $sim.tickCount
      )
    inc replay.hashIndex
    if replay.hashIndex >= replay.data.hashes.len:
      replay.playing = false

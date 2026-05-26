import std/times
import bitworld/protocol, sim

const
  MbGameName* = "marketboard"
  MbGameVersion* = "1"
  MbReplayMagic* = "BITWORLD"
  MbReplayFormatVersion* = 2'u16
  MbReplayFps* = 24
  MbReplayTickHashRecord* = 0x01'u8
  MbReplayInputRecord* = 0x02'u8
  MbReplayJoinRecord* = 0x03'u8
  MbReplayLeaveRecord* = 0x04'u8

type
  MbReplayError* = object of CatchableError

  MbReplayInput* = object
    time*: uint32
    player*: uint8
    keys*: uint8

  MbReplayHash* = object
    tick*: uint32
    hash*: uint64

  MbReplayJoin* = object
    time*: uint32
    player*: uint8
    address*: string

  MbReplayData* = object
    gameName*: string
    gameVersion*: string
    configJson*: string
    joins*: seq[MbReplayJoin]
    inputs*: seq[MbReplayInput]
    hashes*: seq[MbReplayHash]

  MbReplayWriter* = object
    enabled*: bool
    file: File
    lastMasks*: seq[uint8]

  MbReplayPlayer* = object
    data*: MbReplayData
    joinIndex*: int
    inputIndex*: int
    hashIndex*: int
    masks*: seq[uint8]
    prevMasks*: seq[uint8]
    playing*: bool
    looping*: bool
    speedIndex*: int

const
  PlaybackSpeeds* = [1, 2, 3, 4, 8]

proc tickTime*(tick: int): uint32 =
  uint32((int64(tick) * 1000'i64) div int64(MbReplayFps))

proc writeU8(file: File, value: uint8) =
  file.write(char(value))

proc writeU16(file: File, value: uint16) =
  file.writeU8(uint8(value and 0xff'u16))
  file.writeU8(uint8(value shr 8))

proc writeU32(file: File, value: uint32) =
  for shift in countup(0, 24, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u32))

proc writeU64(file: File, value: uint64) =
  for shift in countup(0, 56, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u64))

proc writeReplayString(file: File, value: string) =
  if value.len > high(uint16).int:
    raise newException(MbReplayError, "Replay string is too long")
  file.writeU16(uint16(value.len))
  file.write(value)

proc readU8(bytes: string, offset: var int): uint8 =
  if offset + 1 > bytes.len:
    raise newException(MbReplayError, "Replay file is truncated at byte " & $offset)
  result = bytes[offset].uint8
  inc offset

proc readU16(bytes: string, offset: var int): uint16 =
  if offset + 2 > bytes.len:
    raise newException(MbReplayError, "Replay file is truncated at byte " & $offset)
  result = uint16(bytes[offset].uint8) or (uint16(bytes[offset + 1].uint8) shl 8)
  offset += 2

proc readU32(bytes: string, offset: var int): uint32 =
  if offset + 4 > bytes.len:
    raise newException(MbReplayError, "Replay file is truncated at byte " & $offset)
  for shift in countup(0, 24, 8):
    result = result or (uint32(bytes[offset].uint8) shl shift)
    inc offset

proc readU64(bytes: string, offset: var int): uint64 =
  if offset + 8 > bytes.len:
    raise newException(MbReplayError, "Replay file is truncated at byte " & $offset)
  for shift in countup(0, 56, 8):
    result = result or (uint64(bytes[offset].uint8) shl shift)
    inc offset

proc readReplayString(bytes: string, offset: var int): string =
  let length = int(bytes.readU16(offset))
  if offset + length > bytes.len:
    raise newException(MbReplayError, "Replay file is truncated at byte " & $offset)
  result = bytes[offset ..< offset + length]
  offset += length

proc openMbReplayWriter*(path: string, configJson: string): MbReplayWriter =
  if path.len == 0:
    return
  if not open(result.file, path, fmWrite):
    raise newException(IOError, "Could not open replay file: " & path)
  result.enabled = true
  result.lastMasks = @[]
  result.file.write(MbReplayMagic)
  result.file.writeU16(MbReplayFormatVersion)
  result.file.writeReplayString(MbGameName)
  result.file.writeReplayString(MbGameVersion)
  result.file.writeU64(uint64(toUnix(getTime())) * 1000'u64)
  result.file.writeReplayString(configJson)

proc closeMbReplayWriter*(writer: var MbReplayWriter) =
  if writer.enabled:
    writer.file.flushFile()
    writer.file.close()
    writer.enabled = false

proc writeJoin*(writer: var MbReplayWriter, time: uint32, player: int, address: string) =
  if not writer.enabled:
    return
  writer.file.writeU8(MbReplayJoinRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(address)

proc writeInput*(writer: var MbReplayWriter, input: MbReplayInput) =
  if not writer.enabled:
    return
  writer.file.writeU8(MbReplayInputRecord)
  writer.file.writeU32(input.time)
  writer.file.writeU8(input.player)
  writer.file.writeU8(input.keys)

proc writeHash*(writer: var MbReplayWriter, tick: uint32, hash: uint64) =
  if not writer.enabled:
    return
  writer.file.writeU8(MbReplayTickHashRecord)
  writer.file.writeU32(tick)
  writer.file.writeU64(hash)
  writer.file.flushFile()

proc parseMbReplayBytes*(bytes: string): MbReplayData =
  var offset = 0
  if bytes.len < MbReplayMagic.len:
    raise newException(MbReplayError, "Replay file is truncated")
  if bytes[0 ..< MbReplayMagic.len] != MbReplayMagic:
    raise newException(MbReplayError, "Replay magic is not BITWORLD")
  offset = MbReplayMagic.len
  let formatVersion = bytes.readU16(offset)
  if formatVersion != MbReplayFormatVersion:
    raise newException(MbReplayError, "Unsupported replay format version")
  result.gameName = bytes.readReplayString(offset)
  result.gameVersion = bytes.readReplayString(offset)
  discard bytes.readU64(offset)
  result.configJson = bytes.readReplayString(offset)
  if result.gameName != MbGameName:
    raise newException(MbReplayError, "Replay game name does not match: " & result.gameName)

  var
    lastTick = -1
    lastInputTime = 0'u32
    lastJoinTime = 0'u32
  while offset < bytes.len:
    let recordType = bytes.readU8(offset)
    case recordType
    of MbReplayTickHashRecord:
      let tick = bytes.readU32(offset)
      let hash = bytes.readU64(offset)
      if int(tick) <= lastTick:
        raise newException(MbReplayError, "Replay tick hashes move backward")
      lastTick = int(tick)
      result.hashes.add(MbReplayHash(tick: tick, hash: hash))
    of MbReplayInputRecord:
      let input = MbReplayInput(
        time: bytes.readU32(offset),
        player: bytes.readU8(offset),
        keys: bytes.readU8(offset)
      )
      if input.time < lastInputTime:
        raise newException(MbReplayError, "Replay input timestamps move backward")
      lastInputTime = input.time
      result.inputs.add(input)
    of MbReplayJoinRecord:
      let join = MbReplayJoin(
        time: bytes.readU32(offset),
        player: bytes.readU8(offset),
        address: bytes.readReplayString(offset)
      )
      if join.time < lastJoinTime:
        raise newException(MbReplayError, "Replay join timestamps move backward")
      lastJoinTime = join.time
      result.joins.add(join)
    of MbReplayLeaveRecord:
      discard bytes.readU32(offset)
      discard bytes.readU8(offset)
    else:
      raise newException(MbReplayError, "Unknown replay record type")

proc loadMbReplay*(path: string): MbReplayData =
  parseMbReplayBytes(readFile(path))

proc initMbReplayPlayer*(data: MbReplayData): MbReplayPlayer =
  result.data = data
  result.masks = @[]
  result.prevMasks = @[]
  result.playing = true
  result.looping = false
  result.speedIndex = 0

proc replaySpeed*(replay: MbReplayPlayer): int =
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayMaxTick*(replay: MbReplayPlayer): int =
  if replay.data.hashes.len == 0:
    return 0
  int(replay.data.hashes[^1].tick)

proc resetReplay*(replay: var MbReplayPlayer) =
  replay.joinIndex = 0
  replay.inputIndex = 0
  replay.hashIndex = 0
  replay.masks = @[]
  replay.prevMasks = @[]

proc maskToPlayerInput*(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.up = decoded.up
  result.down = decoded.down
  result.left = decoded.left
  result.right = decoded.right
  result.aPressed = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
  result.aHeld = (currentMask and ButtonA) != 0
  result.bPressed = (currentMask and ButtonB) != 0 and (previousMask and ButtonB) == 0
  result.selectPressed = (currentMask and ButtonSelect) != 0 and (previousMask and ButtonSelect) == 0

proc ensurePlayer(replay: var MbReplayPlayer, player: int) =
  while replay.masks.len <= player:
    replay.masks.add(0)
    replay.prevMasks.add(0)

proc applyReplayEvents(replay: var MbReplayPlayer, sim: var SimServer) =
  let time = tickTime(sim.tickCount)
  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    discard sim.addPlayer(join.address)
    replay.ensurePlayer(int(join.player))
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensurePlayer(int(input.player))
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

proc replayInputs(replay: var MbReplayPlayer, playerCount: int): seq[PlayerInput] =
  result = newSeq[PlayerInput](playerCount)
  for i in 0 ..< playerCount:
    replay.ensurePlayer(i)
    result[i] = maskToPlayerInput(replay.masks[i], replay.prevMasks[i])
    replay.prevMasks[i] = replay.masks[i]

proc checkReplayHash(replay: var MbReplayPlayer, sim: SimServer) =
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    raise newException(MbReplayError, "Replay hash tick is missing")
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    raise newException(MbReplayError, "Replay hash mismatch at tick " & $sim.tickCount)
  inc replay.hashIndex

proc stepReplay*(replay: var MbReplayPlayer, sim: var SimServer) =
  replay.applyReplayEvents(sim)
  let inputs = replay.replayInputs(sim.players.len)
  sim.step(inputs)
  replay.checkReplayHash(sim)

proc seekReplay*(replay: var MbReplayPlayer, sim: var SimServer, tick: int) =
  sim = initSimServer(0)
  replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc applyReplaySeek*(replay: var MbReplayPlayer, sim: var SimServer, tick: int) =
  replay.playing = false
  replay.seekReplay(sim, clamp(tick, 0, replay.replayMaxTick()))

proc applyReplayCommand*(replay: var MbReplayPlayer, sim: var SimServer, command: char) =
  case command
  of ' ':
    replay.playing = not replay.playing
  of 'p':
    replay.playing = true
  of 'P':
    replay.playing = false
  of '+', '=':
    replay.speedIndex = min(replay.speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    replay.speedIndex = max(replay.speedIndex - 1, 0)
  of '1':
    replay.speedIndex = 0
  of '2':
    replay.speedIndex = 1
  of '3':
    replay.speedIndex = 2
  of '4':
    replay.speedIndex = 3
  of '8':
    replay.speedIndex = 4
  of ',', '<':
    replay.playing = false
    replay.seekReplay(sim, 0)
  of 'b':
    replay.playing = false
    replay.seekReplay(sim, max(0, sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.seekReplay(sim, replay.replayMaxTick())
  of 'r':
    replay.looping = not replay.looping
  of '.', '>':
    replay.playing = false
    replay.seekReplay(sim, sim.tickCount + MbReplayFps * 5)
  else:
    discard

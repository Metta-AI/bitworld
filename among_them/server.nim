import
  std/[locks, monotimes, nativesockets, os, strutils, tables, times],
  mummy,
  bitworld/clients, protocol, sim, global

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  WebSocketAppState = object
    lock: Lock
    replayLoaded: bool
    resetRequested: bool
    kickRequests: seq[string]
    kickedIdentities: Table[string, bool]
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    chatMessages: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    globalViewers: Table[WebSocket, GlobalViewerState]
    playerViewers: Table[WebSocket, PlayerViewerState]
    rewardViewers: Table[WebSocket, bool]
    closedSockets: seq[WebSocket]
    spectators: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

  ReplayError* = object of CatchableError

  ReplayInput = object
    time: uint32
    player: uint8
    keys: uint8

  ReplayHash = object
    tick: uint32
    hash: uint64

  ReplayJoin = object
    time: uint32
    player: uint8
    name: string
    slot: int
    token: string

  ReplayLeave = object
    time: uint32
    player: uint8

  ReplayData = object
    gameName: string
    gameVersion: string
    configJson: string
    joins: seq[ReplayJoin]
    leaves: seq[ReplayLeave]
    inputs: seq[ReplayInput]
    hashes: seq[ReplayHash]

  ReplayWriter = object
    enabled: bool
    file: File
    lastMasks: seq[uint8]

  ReplayPlayer = object
    data: ReplayData
    joinIndex: int
    leaveIndex: int
    inputIndex: int
    hashIndex: int
    masks: seq[uint8]
    lastAppliedMasks: seq[uint8]
    playing: bool
    looping: bool
    speedIndex: int

const
  PlaybackSpeeds = [1, 2, 3, 4, 8]
  HealthPath = "/health"
  ControlRestartPath = "/control/restart"
  ControlKickPath = "/control/kick"

proc liveProgressMaxTick(config: GameConfig): int =
  ## Returns the live viewer tick-bar budget.
  if config.maxTicks > 0:
    config.maxTicks
  else:
    MaxTicks

proc serveStaticClientHtml(request: Request): bool =
  ## Serves one static client file if the route matches.
  if request.httpMethod != "GET":
    return false
  let filePath = clientStaticPath(request.path)
  if filePath.len == 0:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(request.path)
  headers["Cache-Control"] = "no-cache"
  if not fileExists(filePath):
    request.respond(404, headers, "Missing static client: " & request.path)
    return true
  try:
    request.respond(200, headers, readFile(filePath))
  except IOError as e:
    request.respond(500, headers, "Could not read static client: " & e.msg)
  true

proc tickTime(tick: int): uint32 =
  ## Converts a simulation tick to replay milliseconds.
  uint32((int64(tick) * 1000'i64) div int64(ReplayFps))

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
  ## Writes a replay UTF-8 string.
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
  ## Reads a replay UTF-8 string.
  let length = int(bytes.readU16(offset))
  if offset + length > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  result = bytes[offset ..< offset + length]
  offset += length

proc openReplayWriter(path: string, configJson: string): ReplayWriter =
  ## Opens a replay file and writes the header.
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

proc closeReplayWriter(writer: var ReplayWriter) =
  ## Closes a replay writer if it is open.
  if writer.enabled:
    writer.file.flushFile()
    writer.file.close()
    writer.enabled = false

proc flushReplayWriter(writer: var ReplayWriter) =
  ## Flushes a replay writer if it is open.
  if writer.enabled:
    writer.file.flushFile()

proc writeJoin(
  writer: var ReplayWriter,
  time: uint32,
  player: int,
  name: string,
  slot: int,
  token: string
) =
  ## Writes one player join replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayJoinRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(name)
  writer.file.writeI16(slot)
  writer.file.writeReplayString(token)

proc writeLeave(writer: var ReplayWriter, time: uint32, player: int) =
  ## Writes one player leave replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayLeaveRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))

proc writeInput(writer: var ReplayWriter, input: ReplayInput) =
  ## Writes one player input replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayInputRecord)
  writer.file.writeU32(input.time)
  writer.file.writeU8(input.player)
  writer.file.writeU8(input.keys)

proc writeHash(writer: var ReplayWriter, tick: uint32, hash: uint64) =
  ## Writes one tick hash replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayTickHashRecord)
  writer.file.writeU32(tick)
  writer.file.writeU64(hash)
  writer.flushReplayWriter()

proc loadReplay(path: string): ReplayData =
  ## Loads a replay file into memory.
  let bytes = readFile(path)
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

  var lastTick = -1
  var lastInputTime = 0'u32
  var lastJoinTime = 0'u32
  var lastLeaveTime = 0'u32
  while offset < bytes.len:
    let recordType = bytes.readU8(offset)
    case recordType
    of ReplayTickHashRecord:
      let
        tick = bytes.readU32(offset)
        hash = bytes.readU64(offset)
      if int(tick) <= lastTick:
        raise newException(ReplayError, "Replay tick hashes move backward")
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
proc initReplayPlayer(data: ReplayData): ReplayPlayer =
  ## Builds replay playback state.
  result.data = data
  result.masks = @[]
  result.lastAppliedMasks = @[]
  result.playing = true
  result.looping = false
  result.speedIndex = 0

proc replaySpeed(replay: ReplayPlayer): int =
  ## Returns the current integer replay speed.
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayMaxTick(replay: ReplayPlayer): int =
  ## Returns the final tick available in the replay.
  if replay.data.hashes.len == 0:
    return 0
  int(replay.data.hashes[^1].tick)

proc resetReplay(replay: var ReplayPlayer) =
  ## Resets replay playback cursors.
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.inputIndex = 0
  replay.hashIndex = 0
  replay.masks = @[]
  replay.lastAppliedMasks = @[]

proc ensureReplayPlayer(replay: var ReplayPlayer, player: int) =
  ## Expands replay input tables for one player.
  while replay.masks.len <= player:
    replay.masks.add(0)
    replay.lastAppliedMasks.add(0)

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies replay joins and inputs for the current tick.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    if int(leave.player) < 0 or int(leave.player) >= sim.players.len:
      raise newException(ReplayError, "Replay player leave is invalid")
    sim.players.delete(int(leave.player))
    if int(leave.player) < replay.masks.len:
      replay.masks.delete(int(leave.player))
    if int(leave.player) < replay.lastAppliedMasks.len:
      replay.lastAppliedMasks.delete(int(leave.player))
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, join.slot, join.token)
    replay.ensureReplayPlayer(int(join.player))
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensureReplayPlayer(int(input.player))
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

proc replayPrevInputs(replay: var ReplayPlayer, playerCount: int): seq[InputState] =
  ## Builds previous replay inputs for the current tick.
  result = newSeq[InputState](playerCount)
  for playerIndex in 0 ..< playerCount:
    replay.ensureReplayPlayer(playerIndex)
    result[playerIndex] = decodeInputMask(replay.lastAppliedMasks[playerIndex])

proc replayInputs(replay: var ReplayPlayer, playerCount: int): seq[InputState] =
  ## Builds replay inputs for the current tick.
  result = newSeq[InputState](playerCount)
  for playerIndex in 0 ..< playerCount:
    replay.ensureReplayPlayer(playerIndex)
    result[playerIndex] = decodeInputMask(replay.masks[playerIndex])
    replay.lastAppliedMasks[playerIndex] = replay.masks[playerIndex]

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## Checks the recorded hash for the current tick.
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    raise newException(ReplayError, "Replay hash tick is missing")
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    raise newException(
      ReplayError,
      "Replay hash mismatch at tick " & $sim.tickCount
    )
  inc replay.hashIndex

proc stepReplay(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances replay by one simulation tick.
  replay.applyReplayEvents(sim)
  let prevInputs = replay.replayPrevInputs(sim.players.len)
  let inputs = replay.replayInputs(sim.players.len)
  sim.step(inputs, prevInputs)
  replay.checkReplayHash(sim)

proc seekReplay(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Seeks replay playback to a target tick.
  sim = initSimServer(sim.config)
  replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc applyReplaySeek(
  replay: var ReplayPlayer,
  sim: var SimServer,
  tick: int
) =
  ## Seeks replay playback and pauses on the target tick.
  replay.playing = false
  replay.seekReplay(sim, clamp(tick, 0, replay.replayMaxTick()))

proc applyReplayCommand(
  replay: var ReplayPlayer,
  sim: var SimServer,
  command: char
) =
  ## Applies one global viewer replay command.
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
    replay.seekReplay(sim, sim.tickCount + ReplayFps * 5)
  else:
    discard

proc applySpeedCommand(speedIndex: var int, command: char) =
  ## Applies one live playback speed command.
  case command
  of '+', '=':
    speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    speedIndex = max(speedIndex - 1, 0)
  of '1':
    speedIndex = 0
  of '2':
    speedIndex = 1
  of '3':
    speedIndex = 2
  of '4':
    speedIndex = 3
  of '8':
    speedIndex = 4
  else:
    discard

proc playbackSpeed(speedIndex: int): int =
  ## Returns the live playback speed for an index.
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]

proc rewardAddress(address: string): string =
  ## Formats one reward address as host:port.
  let parts = address.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  address

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.replayLoaded = false
  appState.resetRequested = false
  appState.kickRequests = @[]
  appState.kickedIdentities = initTable[string, bool]()
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.closedSockets = @[]
  appState.spectators = @[]

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  for i in countdown(appState.spectators.high, 0):
    if appState.spectators[i] == websocket:
      appState.spectators.delete(i)
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket notin appState.playerIndices:
    appState.inputMasks.del(websocket)
    appState.lastAppliedMasks.del(websocket)
    appState.chatMessages.del(websocket)
    appState.playerAddresses.del(websocket)
    appState.playerSlots.del(websocket)
    appState.playerTokens.del(websocket)
    return
  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.chatMessages.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc cleanPlayerName(name: string): string =
  ## Returns a protocol-safe player display name.
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerIdentity(request: Request): string =
  ## Returns the websocket player identity for rewards and displays.
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  request.remoteAddress

proc playerSlot(request: Request): int =
  ## Returns the requested player slot or -1 for automatic assignment.
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerToken(request: Request): string =
  ## Returns the player join token.
  request.queryParams.getOrDefault("token", "").strip()

proc controlHeaders(): HttpHeaders =
  ## Returns headers for stats-page control requests.
  result["Content-Type"] = "text/plain; charset=utf-8"
  result["Cache-Control"] = "no-cache"
  result["Access-Control-Allow-Origin"] = "*"
  result["Access-Control-Allow-Methods"] = "POST, OPTIONS"
  result["Access-Control-Allow-Headers"] = "Content-Type"

proc respondControl(request: Request, status: int, body: string) =
  ## Sends a plain text control response.
  request.respond(status, controlHeaders(), body)

proc replayControlsDisabled(): bool =
  ## Returns true when live match controls are disabled.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.replayLoaded

proc disconnectWebSocket(websocket: WebSocket) =
  ## Tears down a player connection immediately.
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc identityIsKicked(identity: string): bool =
  ## Returns true when an identity is blocked from rejoining this match.
  let rewardIdentity = identity.rewardAddress()
  {.gcsafe.}:
    withLock appState.lock:
      result =
        identity in appState.kickedIdentities or
        rewardIdentity in appState.kickedIdentities

proc respondKicked(request: Request) =
  ## Rejects a kicked player before upgrading to a WebSocket.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(409, headers, "player was kicked\n")

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == WebSocketPath and request.httpMethod == "GET":
    let
      identity = request.playerIdentity()
      slot = request.playerSlot()
      token = request.playerToken()
    if identity.identityIsKicked():
      request.respondKicked()
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
  elif request.path == Player2WebSocketPath and request.httpMethod == "GET":
    let
      identity = request.playerIdentity()
      slot = request.playerSlot()
      token = request.playerToken()
    if identity.identityIsKicked():
      request.respondKicked()
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerViewers[websocket] = initPlayerViewerState()
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path == "/reward" and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.rewardViewers[websocket] = true
  elif (request.path == ControlRestartPath or request.path == ControlKickPath) and
      request.httpMethod == "OPTIONS":
    request.respondControl(204, "")
  elif request.path == ControlRestartPath and request.httpMethod == "POST":
    if replayControlsDisabled():
      request.respondControl(409, "match controls are disabled for replays\n")
    else:
      {.gcsafe.}:
        withLock appState.lock:
          appState.resetRequested = true
      request.respondControl(202, "restart queued\n")
  elif request.path == ControlKickPath and request.httpMethod == "POST":
    if replayControlsDisabled():
      request.respondControl(409, "match controls are disabled for replays\n")
    else:
      let identity = request.queryParams.getOrDefault(
        "identity",
        ""
      ).cleanPlayerName()
      if identity.len == 0:
        request.respondControl(400, "missing identity\n")
      else:
        {.gcsafe.}:
          withLock appState.lock:
            appState.kickRequests.add(identity)
        request.respondControl(202, "kick queued\n")
  elif request.serveStaticClientHtml():
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Among Them server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    var closeKickedSocket = false
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.globalViewers and
            websocket notin appState.rewardViewers:
          let
            address = appState.playerAddresses.getOrDefault(websocket, "")
            identity = address.rewardAddress()
            isKicked =
              address in appState.kickedIdentities or
                identity in appState.kickedIdentities
          if isKicked:
            appState.playerAddresses.del(websocket)
            appState.playerSlots.del(websocket)
            appState.playerTokens.del(websocket)
            appState.inputMasks.del(websocket)
            appState.lastAppliedMasks.del(websocket)
            appState.chatMessages.del(websocket)
            closeKickedSocket = true
          elif appState.replayLoaded:
            appState.playerIndices[websocket] = -1
          else:
            appState.playerIndices[websocket] = 0x7fffffff
          if websocket in appState.playerIndices:
            appState.inputMasks[websocket] = 0
            appState.lastAppliedMasks[websocket] = 0
    if closeKickedSocket:
      websocket.disconnectWebSocket()
  of MessageEvent:
    if message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data
            )
          elif websocket in appState.playerViewers and
              not appState.replayLoaded:
            var
              mask = appState.inputMasks.getOrDefault(websocket, 0)
              chatText = ""
            appState.playerViewers[websocket].applyPlayerViewerMessage(
              message.data,
              mask,
              chatText
            )
            appState.inputMasks[websocket] = mask
            if chatText.len > 0:
              appState.chatMessages[websocket] = chatText
          elif isInputPacket(message.data) and
              not appState.replayLoaded and
              websocket in appState.playerIndices:
            let mask = blobToMask(message.data)
            if mask == 255'u8:
              appState.resetRequested = true
              appState.inputMasks[websocket] = 0
              appState.lastAppliedMasks[websocket] = 0
            else:
              appState.inputMasks[websocket] = mask
          elif isChatPacket(message.data) and
              not appState.replayLoaded and
              websocket in appState.playerIndices:
            appState.chatMessages[websocket] = blobToChat(message.data)
  of ErrorEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc rewardAccountFor(sim: SimServer, address: string): int =
  ## Returns the reward account index for one address.
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc addStatLine(
  packet: var string,
  name, identity: string,
  value: int
) =
  ## Appends one metric line to a reward protocol packet.
  packet.add(name)
  packet.add(' ')
  packet.add(identity)
  packet.add(' ')
  packet.add($value)
  packet.add('\n')

proc buildRewardPacket(sim: SimServer): string =
  ## Builds one reward protocol packet for the current tick.
  for player in sim.players:
    let
      identity = player.address.rewardAddress()
      accountIndex = sim.rewardAccountFor(player.address)
    result.addStatLine("reward", identity, player.reward)
    if accountIndex >= 0:
      let account = sim.rewardAccounts[accountIndex]
      result.addStatLine("wins_imposter", identity, account.winsImposter)
      result.addStatLine("wins_crewmate", identity, account.winsCrewmate)
      result.addStatLine("games_imposter", identity, account.gamesImposter)
      result.addStatLine("games_crewmate", identity, account.gamesCrewmate)
      result.addStatLine("kills", identity, account.kills)
      result.addStatLine("tasks", identity, account.tasks)

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  saveScoresPath = ""
) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  let replayLoaded = loadReplayPath.len > 0
  let replayData =
    if replayLoaded:
      loadReplay(loadReplayPath)
    else:
      ReplayData()
  var config =
    if replayLoaded:
      var replayConfig = defaultGameConfig()
      replayConfig.update(replayData.configJson)
      replayConfig
    else:
      initialConfig
  var
    replayWriter = openReplayWriter(saveReplayPath, config.configJson())
    replayPlayer =
      if replayLoaded:
        initReplayPlayer(replayData)
      else:
        ReplayPlayer()
  defer:
    replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4
  )
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()

  var
    sim = initSimServer(config)
    lastTick = getMonoTime()
    prevInputs: seq[InputState]
    liveSpeedIndex = 0
    gamesPlayed = 0

  while true:
    var
      sockets: seq[WebSocket] = @[]
      socketsToClose: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]
      spectatorList: seq[WebSocket] = @[]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      rewardViewers: seq[WebSocket] = @[]
      playerViewerFlags: seq[bool] = @[]
      playerViewerStates: seq[PlayerViewerState] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]
      shouldReset = false
      quitAfterFrame = false

    {.gcsafe.}:
      withLock appState.lock:
        if not replayLoaded and appState.resetRequested:
          shouldReset = true
          appState.resetRequested = false
          appState.chatMessages.clear()
        for websocket in appState.closedSockets:
          if not replayLoaded and websocket in appState.playerIndices:
            let playerIndex = appState.playerIndices[websocket]
            if playerIndex >= 0 and playerIndex < sim.players.len:
              replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
              if playerIndex < replayWriter.lastMasks.len:
                replayWriter.lastMasks.delete(playerIndex)
              if playerIndex < prevInputs.len:
                prevInputs.delete(playerIndex)
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)
        if not replayLoaded and appState.kickRequests.len > 0:
          let requestedKicks = appState.kickRequests
          appState.kickRequests = @[]
          var socketsToKick: seq[WebSocket] = @[]
          for websocket, address in appState.playerAddresses.pairs:
            let identity = address.rewardAddress()
            for requestedIdentity in requestedKicks:
              if address == requestedIdentity or identity == requestedIdentity:
                appState.kickedIdentities[address] = true
                appState.kickedIdentities[identity] = true
                if websocket notin socketsToKick:
                  socketsToKick.add(websocket)
          for websocket in socketsToKick:
            if websocket in appState.playerIndices:
              let playerIndex = appState.playerIndices[websocket]
              if playerIndex >= 0 and playerIndex < sim.players.len:
                replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
                if playerIndex < replayWriter.lastMasks.len:
                  replayWriter.lastMasks.delete(playerIndex)
                if playerIndex < prevInputs.len:
                  prevInputs.delete(playerIndex)
            sim.removePlayer(websocket)
            socketsToClose.add(websocket)
        if not replayLoaded and sim.phase != Lobby and sim.players.len == 0:
          sim.resetToLobby()
          prevInputs = @[]
          replayWriter.lastMasks = @[]

        if not replayLoaded:
          var newSockets: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              newSockets.add(websocket)
          for websocket in newSockets:
            let address = appState.playerAddresses.getOrDefault(
              websocket,
              "unknown"
            )
            let
              slot = appState.playerSlots.getOrDefault(websocket, -1)
              token = appState.playerTokens.getOrDefault(websocket, "")
            let identity = address.rewardAddress()
            if address in appState.kickedIdentities or
                identity in appState.kickedIdentities:
              sim.removePlayer(websocket)
              socketsToClose.add(websocket)
            elif sim.playerAddressOccupied(address):
              sim.removePlayer(websocket)
              socketsToClose.add(websocket)
            elif sim.phase == Lobby and sim.canAddPlayer():
              try:
                appState.playerIndices[websocket] = sim.addPlayer(
                  address,
                  slot,
                  token
                )
              except AmongThemError:
                sim.removePlayer(websocket)
                socketsToClose.add(websocket)
                continue
              appState.playerSlots[websocket] =
                sim.players[appState.playerIndices[websocket]].joinOrder
              replayWriter.writeJoin(
                tickTime(sim.tickCount),
                appState.playerIndices[websocket],
                address,
                slot,
                token
              )
              while replayWriter.lastMasks.len < sim.players.len:
                replayWriter.lastMasks.add(0)
            else:
              if websocket in appState.playerViewers:
                appState.playerIndices[websocket] = -1
              else:
                appState.spectators.add(websocket)
                appState.playerIndices.del(websocket)

        if not replayLoaded:
          inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          sockets.add(websocket)
          playerIndices.add(playerIndex)
          let isPlayerViewer = websocket in appState.playerViewers
          playerViewerFlags.add(isPlayerViewer)
          if isPlayerViewer:
            playerViewerStates.add(appState.playerViewers[websocket])
          else:
            playerViewerStates.add(initPlayerViewerState())
          if replayLoaded:
            continue
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = decodeInputMask(currentMask)
          if playerIndex < replayWriter.lastMasks.len and
              currentMask != replayWriter.lastMasks[playerIndex]:
            replayWriter.writeInput(ReplayInput(
              time: tickTime(sim.tickCount),
              player: uint8(playerIndex),
              keys: currentMask
            ))
            replayWriter.lastMasks[playerIndex] = currentMask
          appState.lastAppliedMasks[websocket] = currentMask
        if not replayLoaded:
          for websocket, message in appState.chatMessages.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(
              websocket,
              -1
            )
            sim.addVotingChat(playerIndex, message)
          appState.chatMessages.clear()
        spectatorList = appState.spectators
        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          globalStates.add(state)
          if state.replaySeekTick >= 0:
            replaySeekTicks.add(state.replaySeekTick)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1
        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)

    for websocket in socketsToClose:
      websocket.disconnectWebSocket()

    if shouldReset:
      let rewardAccounts = sim.rewardAccounts
      inc config.seed
      sim = initSimServer(config)
      sim.rewardAccounts = rewardAccounts
      prevInputs = @[]
      replayWriter.lastMasks = @[]
      sockets.setLen(0)
      playerIndices.setLen(0)
      spectatorList.setLen(0)
      rewardViewers.setLen(0)
      playerViewerFlags.setLen(0)
      playerViewerStates.setLen(0)
      {.gcsafe.}:
        withLock appState.lock:
          appState.kickedIdentities.clear()
          var reconnectSockets: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            reconnectSockets.add(websocket)
          for websocket in appState.spectators:
            reconnectSockets.add(websocket)
          appState.spectators = @[]
          for websocket in reconnectSockets:
            if not sim.canAddPlayer():
              if websocket in appState.playerViewers:
                appState.playerIndices[websocket] = -1
              else:
                appState.spectators.add(websocket)
                appState.playerIndices.del(websocket)
              continue
            let address = appState.playerAddresses.getOrDefault(
              websocket,
              "unknown"
            )
            let
              slot = appState.playerSlots.getOrDefault(websocket, -1)
              token = appState.playerTokens.getOrDefault(websocket, "")
            try:
              appState.playerIndices[websocket] = sim.addPlayer(
                address,
                slot,
                token
              )
            except AmongThemError:
              sim.removePlayer(websocket)
              socketsToClose.add(websocket)
              continue
            appState.playerSlots[websocket] =
              sim.players[appState.playerIndices[websocket]].joinOrder
            appState.inputMasks[websocket] = 0
            appState.lastAppliedMasks[websocket] = 0
            let isPlayerViewer = websocket in appState.playerViewers
            sockets.add(websocket)
            playerIndices.add(appState.playerIndices[websocket])
            playerViewerFlags.add(isPlayerViewer)
            if isPlayerViewer:
              appState.playerViewers[websocket] = initPlayerViewerState()
              playerViewerStates.add(appState.playerViewers[websocket])
            else:
              playerViewerStates.add(initPlayerViewerState())
          replayWriter.lastMasks.setLen(sim.players.len)
          for websocket in appState.rewardViewers.keys:
            rewardViewers.add(websocket)

      let rewardPacket = sim.buildRewardPacket()
      for i in 0 ..< sockets.len:
        let framePacket =
          if playerViewerFlags[i]:
            var nextState: PlayerViewerState
            let packet = sim.buildSpriteProtocolPlayerUpdates(
              playerIndices[i],
              playerViewerStates[i],
              nextState
            )
            {.gcsafe.}:
              withLock appState.lock:
                if sockets[i] in appState.playerViewers:
                  appState.playerViewers[sockets[i]] = nextState
            packet
          else:
            sim.render(playerIndices[i])
        let frameBlob = blobFromBytes(framePacket)
        sockets[i].send(frameBlob, BinaryMessage)
      for websocket in rewardViewers:
        websocket.send(rewardPacket, TextMessage)
      runFrameLimiter(lastTick)
      continue

    if replayLoaded:
      for seekTick in replaySeekTicks:
        replayPlayer.applyReplaySeek(sim, seekTick)
      for command in replayCommands:
        replayPlayer.applyReplayCommand(sim, command)
      if replayPlayer.playing:
        for _ in 0 ..< replayPlayer.replaySpeed():
          if replayPlayer.playing:
            replayPlayer.stepReplay(sim)
        if replayPlayer.looping and not replayPlayer.playing:
          replayPlayer.seekReplay(sim, 0)
          replayPlayer.playing = true
    else:
      for command in replayCommands:
        liveSpeedIndex.applySpeedCommand(command)
      var stepPrevInputs = prevInputs
      for _ in 0 ..< playbackSpeed(liveSpeedIndex):
        let phaseBeforeStep = sim.phase
        sim.step(inputs, stepPrevInputs)
        stepPrevInputs = inputs
        replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
        if config.maxGames > 0 and phaseBeforeStep != GameOver and
            sim.phase == GameOver:
          inc gamesPlayed
          if gamesPlayed >= config.maxGames:
            quitAfterFrame = true
            break
        if sim.needsReregister:
          break
      prevInputs = inputs

    let rewardPacket = sim.buildRewardPacket()

    if not replayLoaded and sim.needsReregister:
      sim.needsReregister = false
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            appState.playerIndices[websocket] = 0x7fffffff
          for websocket in appState.spectators:
            appState.playerIndices[websocket] = 0x7fffffff
          for websocket in appState.playerViewers.keys:
            appState.playerViewers[websocket] = initPlayerViewerState()
          appState.spectators = @[]

    for i in 0 ..< sockets.len:
      let framePacket =
        if playerViewerFlags[i]:
          var nextState: PlayerViewerState
          let packet = sim.buildSpriteProtocolPlayerUpdates(
            playerIndices[i],
            playerViewerStates[i],
            nextState
          )
          {.gcsafe.}:
            withLock appState.lock:
              if sockets[i] in appState.playerViewers:
                appState.playerViewers[sockets[i]] = nextState
          packet
        elif replayLoaded:
          sim.buildReplayFramePacket()
        else:
          sim.render(playerIndices[i])
      let frameBlob = blobFromBytes(framePacket)
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    if spectatorList.len > 0:
      let specBlob = blobFromBytes(sim.buildSpectatorFrame())
      for ws in spectatorList:
        try:
          ws.send(specBlob, BinaryMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              sim.removePlayer(ws)

    for websocket in rewardViewers:
      try:
        websocket.send(rewardPacket, TextMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(websocket)

    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      let packet = sim.buildSpriteProtocolUpdates(
        globalStates[i],
        nextState,
        sim.tickCount,
        replayPlayer.playing,
        if replayLoaded: replayPlayer.replaySpeed()
        else: playbackSpeed(liveSpeedIndex),
        if replayLoaded: replayPlayer.replayMaxTick()
        else: liveProgressMaxTick(config),
        replayPlayer.looping,
        replayLoaded
      )
      if packet.len == 0:
        continue
      try:
        globalViewers[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              appState.globalViewers[globalViewers[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(globalViewers[i])

    if quitAfterFrame:
      if saveScoresPath.len > 0:
        writeFile(saveScoresPath, sim.playerResultsJson() & "\n")
      httpServer.close()
      joinThread(serverThread)
      break

    runFrameLimiter(lastTick)

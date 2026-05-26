import mummy
import bitworld/client
import bitworld/protocol, sim, global
import std/[json, locks, monotimes, os, strutils, tables, times]

const
  HealthzPath = "/healthz"
  DebugAsciiPath = "/debug/ascii"
  DefaultMaxTicks* = TargetFps * 60 * 5
  DefaultMaxGames* = 0

type
  WebSocketAppState = object
    lock: Lock
    replayLoaded: bool
    resetRequested: bool
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerViewers: Table[WebSocket, PlayerViewerState]
    chatMessages: Table[WebSocket, string]
    globalViewers: Table[WebSocket, GlobalViewerState]
    rewardViewers: Table[WebSocket, bool]
    closedSockets: seq[WebSocket]
    tokens: seq[string]
    debugAscii: string

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
    address: string

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
  address: string
) =
  ## Writes one player join replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayJoinRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(address)

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
        address: bytes.readReplayString(offset)
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
var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.replayLoaded = false
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.closedSockets = @[]
  appState.tokens = @[]
  appState.debugAscii = "PLAYER none\n"

proc isWebSocketUpgrade(request: Request): bool =
  ## Returns true when a GET request is a websocket upgrade.
  request.headers["Sec-WebSocket-Key"].len > 0

proc serveClientHtml(request: Request, route: string): bool =
  ## Serves one static client file for a known client route.
  if request.httpMethod != "GET":
    return false
  let filePath = clientStaticPath(route)
  if filePath.len == 0:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(route)
  headers["Cache-Control"] = "no-cache"
  if not fileExists(filePath):
    request.respond(404, headers, "Missing static client: " & route)
    return true
  try:
    request.respond(200, headers, readFile(filePath))
  except IOError as e:
    request.respond(500, headers, "Could not read static client: " & e.msg)
  true

proc serveStaticClientHtml(request: Request): bool =
  ## Serves one static client asset if the route matches.
  request.serveClientHtml(request.path)

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  ## Builds an input state from the current and previous button masks.
  result = decodeInputMask(currentMask)
  result.attack = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0

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
  case replay.speedIndex
  of 0: 1
  of 1: 2
  of 2: 4
  else: 8

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
    discard sim.addPlayer(join.address)
    replay.ensureReplayPlayer(int(join.player))
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensureReplayPlayer(int(input.player))
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

proc replayInputs(replay: var ReplayPlayer, playerCount: int): seq[InputState] =
  ## Builds replay inputs for the current tick.
  result = newSeq[InputState](playerCount)
  for playerIndex in 0 ..< playerCount:
    replay.ensureReplayPlayer(playerIndex)
    result[playerIndex] = inputStateFromMasks(
      replay.masks[playerIndex],
      replay.lastAppliedMasks[playerIndex]
    )
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
  let inputs = replay.replayInputs(sim.players.len)
  sim.step(inputs)
  replay.checkReplayHash(sim)

proc seekReplay(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Seeks replay playback to a target tick.
  sim = initSimServer(sim.seed)
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
    replay.speedIndex = min(replay.speedIndex + 1, 3)
  of '-', '_':
    replay.speedIndex = max(replay.speedIndex - 1, 0)
  of '1':
    replay.speedIndex = 0
  of '2':
    replay.speedIndex = 1
  of '4':
    replay.speedIndex = 2
  of '8':
    replay.speedIndex = 3
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

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket in appState.chatMessages:
    appState.chatMessages.del(websocket)
  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    inc sim.scoreRevision
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc forgetWebSocketRole(websocket: WebSocket) =
  ## Clears all route-specific state for one websocket.
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.chatMessages.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)

proc playerSlot(request: Request): int =
  ## Returns the requested player slot or -1 for automatic assignment.
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return int.high
  if result < 0:
    return int.high

proc playerToken(request: Request): string =
  ## Returns the player join token.
  request.queryParams.getOrDefault("token", "").strip()

proc playerJoinAllowed(slot: int, token: string): bool =
  ## Returns true when the requested slot token is accepted.
  if appState.tokens.len == 0:
    return true
  if slot < 0 or slot >= appState.tokens.len:
    return false
  token == appState.tokens[slot]

proc respondForbidden(request: Request, body: string) =
  ## Rejects an unauthorized request before WebSocket upgrade.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, body)

proc registerPlayerSocket(
  websocket: WebSocket,
  address: string,
  slot: int,
  token: string
) =
  ## Registers a websocket as a player-only sprite endpoint.
  websocket.forgetWebSocketRole()
  appState.playerViewers[websocket] = initPlayerViewerState()
  appState.playerAddresses[websocket] = address
  appState.playerSlots[websocket] = slot
  appState.playerTokens[websocket] = token
  appState.playerIndices[websocket] =
    if appState.replayLoaded:
      -1
    else:
      0x7fffffff
  appState.inputMasks[websocket] = 0
  appState.lastAppliedMasks[websocket] = 0

proc registerGlobalSocket(websocket: WebSocket) =
  ## Registers a websocket as a global-only sprite endpoint.
  websocket.forgetWebSocketRole()
  appState.globalViewers[websocket] = initGlobalViewerState()

proc registerRewardSocket(websocket: WebSocket) =
  ## Registers a websocket as a reward-only endpoint.
  websocket.forgetWebSocketRole()
  appState.rewardViewers[websocket] = true

proc cleanPlayerName(name: string): string =
  ## Normalizes one player name for display and rewards.
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc cleanChatMessage(message: string): string =
  ## Normalizes a submitted speech bubble message.
  let trimmed = message.strip()
  for ch in trimmed:
    if result.len >= MessageMaxChars:
      return
    if ch >= ' ' and ch <= '~':
      result.add(ch)

proc playerIdentity(request: Request): string =
  ## Returns the stable identity for one player request.
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  let parts = request.remoteAddress.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  request.remoteAddress

proc serveHealthz(request: Request): bool =
  ## Serves the container health check endpoint.
  if request.path != HealthzPath or request.httpMethod notin ["GET", "HEAD"]:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, "healthy")
  true

proc serveDebugAscii(request: Request): bool =
  ## Serves a deterministic text render of the latest player observation.
  if request.path != DebugAsciiPath or request.httpMethod notin ["GET", "HEAD"]:
    return false
  var body = ""
  {.gcsafe.}:
    withLock appState.lock:
      body = appState.debugAscii
  if body.len == 0:
    body = "PLAYER none\n"
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, body)
  true

proc httpHandler(request: Request) =
  if request.serveHealthz():
    discard
  elif request.serveDebugAscii():
    discard
  elif request.path == WebSocketPath and
      request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    discard request.serveClientHtml(PlayerClientRoute)
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    discard request.serveClientHtml(GlobalClientRoute)
  elif request.path == RewardWebSocketPath and request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    discard request.serveClientHtml(RewardClientRoute)
  elif request.path == WebSocketPath and
      request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      address = request.playerIdentity()
      slot = request.playerSlot()
      token = request.playerToken()
    var allowed = false
    {.gcsafe.}:
      withLock appState.lock:
        allowed = playerJoinAllowed(slot, token)
    if not allowed:
      request.respondForbidden("player token rejected\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerPlayerSocket(address, slot, token)
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalSocket()
  elif request.path == RewardWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerRewardSocket()
  elif request.serveStaticClientHtml():
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Bit World WebSocket server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.playerViewers and
            websocket notin appState.playerIndices:
          if appState.replayLoaded:
            appState.playerIndices[websocket] = -1
          else:
            appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
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
            if message.data.len == 1 and message.data[0].uint8 == 255'u8:
              appState.resetRequested = true
              return
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
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc rewardAddress(address: string): string =
  let parts = address.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  address

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc buildRewardPacket(sim: SimServer): string =
  ## Builds one reward protocol packet for the current tick.
  let score = sim.teamScore()
  for player in sim.players:
    result.add("reward ")
    result.add(player.address.rewardAddress())
    result.add(" ")
    result.add($score)
    result.add("\n")

proc writeScoreFile(sim: SimServer, path: string) =
  ## Writes the current score JSON if a path is configured.
  if path.len == 0:
    return
  let dir = path.parentDir()
  if dir.len > 0:
    createDir(dir)
  writeFile(path, sim.playerScoresJson() & "\n")

proc writeScoresIfNeeded(
  sim: SimServer,
  path: string,
  lastRevision: var int,
  savedPlayerCount: var int
) =
  ## Writes scores when score-visible state changed.
  if path.len == 0:
    return
  if sim.scoreRevision == lastRevision:
    return
  if sim.players.len == 0 and lastRevision >= 0:
    lastRevision = sim.scoreRevision
    return
  if sim.players.len < savedPlayerCount:
    lastRevision = sim.scoreRevision
    return
  sim.writeScoreFile(path)
  savedPlayerCount = sim.players.len
  lastRevision = sim.scoreRevision

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  seed = 0xB1770,
  saveReplayPath = "",
  loadReplayPath = "",
  saveScoresPath = "",
  tokens: seq[string] = @[],
  maxTicks = DefaultMaxTicks,
  maxGames = DefaultMaxGames
) =
  initAppState()
  appState.tokens = tokens
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  let replayLoaded = loadReplayPath.len > 0
  let replayData =
    if replayLoaded:
      loadReplay(loadReplayPath)
    else:
      ReplayData()
  var currentSeed = seed
  if replayLoaded:
    let node = parseJson(replayData.configJson)
    if node.kind != JObject:
      raise newException(ReplayError, "Replay config must be a JSON object")
    if node.hasKey("seed"):
      if node["seed"].kind != JInt:
        raise newException(ReplayError, "Replay config field seed must be an integer")
      currentSeed = node["seed"].getInt()
  var
    replayWriter = openReplayWriter(
      saveReplayPath,
      $(%*{
        "seed": currentSeed,
        "maxTicks": maxTicks,
        "maxGames": maxGames
      })
    )
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
    workerThreads = 4,
    tcpNoDelay = true
  )

  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc, ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    sim = initSimServer(currentSeed)
    lastTick = getMonoTime()
    lastScoreRevision = -1
    savedScorePlayerCount = 0
    runTicks = 0
    gamesStarted = 1
  sim.writeScoresIfNeeded(saveScoresPath, lastScoreRevision, savedScorePlayerCount)
  var initialDebugAscii = sim.debugAsciiSnapshot()
  {.gcsafe.}:
    withLock appState.lock:
      appState.debugAscii = initialDebugAscii

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerStates: seq[PlayerViewerState] = @[]
      inputs: seq[InputState]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      rewardViewers: seq[WebSocket] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]
      shouldReset =
        not replayLoaded and maxTicks > 0 and runTicks >= maxTicks

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          if not replayLoaded and websocket in appState.playerIndices:
            let playerIndex = appState.playerIndices[websocket]
            if playerIndex >= 0 and playerIndex < sim.players.len:
              replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
              if playerIndex < replayWriter.lastMasks.len:
                replayWriter.lastMasks.delete(playerIndex)
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        if not replayLoaded and appState.resetRequested:
          shouldReset = true

        if not replayLoaded and shouldReset:
          appState.resetRequested = false
          for _, value in appState.playerIndices.mpairs:
            value = 0x7fffffff
          for _, value in appState.inputMasks.mpairs:
            value = 0
          for _, value in appState.lastAppliedMasks.mpairs:
            value = 0
          appState.chatMessages.clear()
          for websocket in appState.playerViewers.keys:
            appState.playerViewers[websocket] = initPlayerViewerState()

        if not replayLoaded and not shouldReset:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] != 0x7fffffff:
              continue
            let address = appState.playerAddresses.getOrDefault(
              websocket,
              "unknown"
            )
            appState.playerIndices[websocket] = sim.addPlayer(address)
            replayWriter.writeJoin(
              tickTime(sim.tickCount),
              appState.playerIndices[websocket],
              address
            )
            while replayWriter.lastMasks.len < sim.players.len:
              replayWriter.lastMasks.add(0)

        if not replayLoaded:
          for websocket, message in appState.chatMessages.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(
              websocket,
              -1
            )
            if playerIndex >= 0 and playerIndex < sim.players.len:
              let cleaned = cleanChatMessage(message)
              sim.setPlayerMessage(playerIndex, cleaned)
              if cleaned.len > 0:
                inc sim.players[playerIndex].messagesSent
          appState.chatMessages.clear()

        for websocket, playerIndex in appState.playerIndices.pairs:
          sockets.add(websocket)
          playerIndices.add(playerIndex)
          playerStates.add(
            appState.playerViewers.getOrDefault(
              websocket,
              initPlayerViewerState()
            )
          )
        if not replayLoaded:
          inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if replayLoaded:
            continue
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = inputStateFromMasks(currentMask, previousMask)
          if playerIndex < replayWriter.lastMasks.len and
              currentMask != replayWriter.lastMasks[playerIndex]:
            replayWriter.writeInput(ReplayInput(
              time: tickTime(sim.tickCount),
              player: uint8(playerIndex),
              keys: currentMask
            ))
            replayWriter.lastMasks[playerIndex] = currentMask
          appState.lastAppliedMasks[websocket] = currentMask
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

    if shouldReset and maxGames > 0 and gamesStarted >= maxGames:
      httpServer.close()
      joinThread(serverThread)
      break

    if shouldReset:
      inc gamesStarted
      inc currentSeed
      sim = initSimServer(currentSeed)
      runTicks = 0
      lastScoreRevision = -1
      savedScorePlayerCount = 0
      replayWriter.lastMasks.setLen(0)
      sockets.setLen(0)
      playerIndices.setLen(0)
      playerStates.setLen(0)
      rewardViewers.setLen(0)
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            let address = appState.playerAddresses.getOrDefault(
              websocket,
              "unknown"
            )
            appState.playerIndices[websocket] = sim.addPlayer(address)
            appState.inputMasks[websocket] = 0
            appState.lastAppliedMasks[websocket] = 0
            if websocket in appState.playerViewers:
              appState.playerViewers[websocket] = initPlayerViewerState()
            sockets.add(websocket)
            playerIndices.add(appState.playerIndices[websocket])
            playerStates.add(
              appState.playerViewers.getOrDefault(
                websocket,
                initPlayerViewerState()
              )
            )
          replayWriter.lastMasks.setLen(sim.players.len)
          for websocket in appState.rewardViewers.keys:
            rewardViewers.add(websocket)

      sim.writeScoresIfNeeded(saveScoresPath, lastScoreRevision, savedScorePlayerCount)
      let debugAscii = sim.debugAsciiSnapshot()
      {.gcsafe.}:
        withLock appState.lock:
          appState.debugAscii = debugAscii
      let rewardPacket = sim.buildRewardPacket()
      for i in 0 ..< sockets.len:
        var nextState: PlayerViewerState
        let packet = sim.buildSpriteProtocolPlayerUpdates(
          playerIndices[i],
          playerStates[i],
          nextState
        )
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i] in appState.playerViewers:
              appState.playerViewers[sockets[i]] = nextState
        sockets[i].send(blobFromBytes(packet), BinaryMessage)
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
      sim.step(inputs)
      inc runTicks
      replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())

    sim.writeScoresIfNeeded(saveScoresPath, lastScoreRevision, savedScorePlayerCount)
    let debugAscii = sim.debugAsciiSnapshot()
    {.gcsafe.}:
      withLock appState.lock:
        appState.debugAscii = debugAscii
    let rewardPacket = sim.buildRewardPacket()

    for i in 0 ..< sockets.len:
      var nextState: PlayerViewerState
      let framePacket = sim.buildSpriteProtocolPlayerUpdates(
        playerIndices[i],
        playerStates[i],
        nextState
      )
      try:
        sockets[i].send(blobFromBytes(framePacket), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i] in appState.playerViewers:
              appState.playerViewers[sockets[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

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
        if replayLoaded: sim.tickCount else: -1,
        replayPlayer.playing,
        replayPlayer.replaySpeed(),
        replayPlayer.replayMaxTick(),
        replayPlayer.looping
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

    runFrameLimiter(lastTick)

when defined(partyProgressorServerSelfTest):
  proc testScoreFilePreservesLastPlayerSnapshot() =
    let path = getTempDir() / "party_progressor_score_selftest.json"
    if fileExists(path):
      removeFile(path)
    let oldDir = getCurrentDir()
    setCurrentDir(currentSourcePath().parentDir())
    var
      sim = initSimServer(0x5150)
      lastRevision = -1
      savedPlayerCount = 0
    setCurrentDir(oldDir)
    sim.writeScoresIfNeeded(path, lastRevision, savedPlayerCount)
    doAssert fileExists(path)
    doAssert parseJson(readFile(path))["names"].len == 0

    let
      playerIndex = sim.addPlayer("selftest-a")
      secondPlayerIndex = sim.addPlayer("selftest-b")
    sim.players[playerIndex].distanceWalked = 42
    sim.players[secondPlayerIndex].distanceWalked = 84
    sim.writeScoresIfNeeded(path, lastRevision, savedPlayerCount)
    let activeScores = parseJson(readFile(path))
    doAssert activeScores["names"].len == 2
    doAssert activeScores["names"][0].getStr() == "selftest-a"
    doAssert activeScores["names"][1].getStr() == "selftest-b"

    sim.players.setLen(1)
    inc sim.scoreRevision
    sim.writeScoresIfNeeded(path, lastRevision, savedPlayerCount)
    var preservedScores = parseJson(readFile(path))
    doAssert preservedScores["names"].len == 2
    doAssert preservedScores["distance_walked"][1].getInt() == 84

    sim.players.setLen(0)
    inc sim.scoreRevision
    sim.writeScoresIfNeeded(path, lastRevision, savedPlayerCount)
    preservedScores = parseJson(readFile(path))
    doAssert preservedScores["names"].len == 2
    doAssert preservedScores["distance_walked"][0].getInt() == 42

    removeFile(path)

  testScoreFilePreservesLastPlayerSnapshot()
  echo "Party Progressor server score tests passed"

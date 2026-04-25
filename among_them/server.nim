import mummy
import protocol, sim, global
import std/[locks, monotimes, os, tables, times]

type
  WebSocketAppState = object
    lock: Lock
    replayLoaded: bool
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    spriteViewers: Table[WebSocket, SpriteViewerState]
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
    address: string

  ReplayLeave = object
    time: uint32
    player: uint8

  ReplayData = object
    gameName: string
    gameVersion: string
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

proc openReplayWriter(path: string): ReplayWriter =
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
proc initReplayPlayer(data: ReplayData): ReplayPlayer =
  ## Builds replay playback state.
  result.data = data
  result.masks = @[]
  result.lastAppliedMasks = @[]
  result.playing = true
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
    replay.playing = true
    replay.seekReplay(sim, 0)
  of '.', '>':
    replay.playing = false
    replay.seekReplay(sim, sim.tickCount + ReplayFps * 5)
  else:
    discard

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.replayLoaded = false
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.spriteViewers = initTable[WebSocket, SpriteViewerState]()
  appState.closedSockets = @[]
  appState.spectators = @[]

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  for i in countdown(appState.spectators.high, 0):
    if appState.spectators[i] == websocket:
      appState.spectators.delete(i)
  if websocket in appState.spriteViewers:
    appState.spriteViewers.del(websocket)
  if websocket notin appState.playerIndices:
    return
  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.playerAddresses.del(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc httpHandler(request: Request) =
  if request.uri == WebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerAddresses[websocket] = request.remoteAddress
  elif request.uri == SpriteWebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.spriteViewers[websocket] = initSpriteViewerState()
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
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.spriteViewers:
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
          if websocket in appState.spriteViewers:
            appState.spriteViewers[websocket].applySpriteViewerMessage(
              message.data
            )
          elif message.data.len == InputPacketBytes and
              not appState.replayLoaded:
            appState.inputMasks[websocket] = blobToMask(message.data)
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

proc runFrameLimiter(previousTick: var MonoTime, targetFps: float) =
  let frameDuration = initDuration(milliseconds = int(1000.0 / targetFps))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  config = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = ""
) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  let replayLoaded = loadReplayPath.len > 0
  var
    replayWriter = openReplayWriter(saveReplayPath)
    replayPlayer =
      if replayLoaded:
        initReplayPlayer(loadReplay(loadReplayPath))
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

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]
      spectatorList: seq[WebSocket] = @[]
      spriteViewers: seq[WebSocket] = @[]
      spriteStates: seq[SpriteViewerState] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]

    {.gcsafe.}:
      withLock appState.lock:
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

        if not replayLoaded:
          var newSockets: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              newSockets.add(websocket)
          for websocket in newSockets:
            if sim.phase == Lobby:
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
            else:
              appState.spectators.add(websocket)
              appState.playerIndices.del(websocket)

        if not replayLoaded:
          inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          sockets.add(websocket)
          playerIndices.add(playerIndex)
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
        spectatorList = appState.spectators
        for websocket, state in appState.spriteViewers.pairs:
          spriteViewers.add(websocket)
          spriteStates.add(state)
          if state.replaySeekTick >= 0:
            replaySeekTicks.add(state.replaySeekTick)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.spriteViewers[websocket].replayCommands.setLen(0)
          appState.spriteViewers[websocket].replaySeekTick = -1

    if replayLoaded:
      for seekTick in replaySeekTicks:
        replayPlayer.applyReplaySeek(sim, seekTick)
      for command in replayCommands:
        replayPlayer.applyReplayCommand(sim, command)
      if replayPlayer.playing:
        for _ in 0 ..< replayPlayer.replaySpeed():
          if replayPlayer.playing:
            replayPlayer.stepReplay(sim)
    else:
      sim.step(inputs, prevInputs)
      prevInputs = inputs
      replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())

    if not replayLoaded and sim.needsReregister:
      sim.needsReregister = false
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            appState.playerIndices[websocket] = 0x7fffffff
          for websocket in appState.spectators:
            appState.playerIndices[websocket] = 0x7fffffff
          appState.spectators = @[]

    for i in 0 ..< sockets.len:
      let framePacket =
        if replayLoaded:
          sim.buildReplayFramePacket()
        else:
          sim.buildFramePacket(playerIndices[i])
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

    for i in 0 ..< spriteViewers.len:
      var nextState: SpriteViewerState
      let packet = sim.buildSpriteProtocolUpdates(
        spriteStates[i],
        nextState,
        if replayLoaded: sim.tickCount else: -1,
        replayPlayer.playing,
        replayPlayer.replaySpeed(),
        replayPlayer.replayMaxTick()
      )
      if packet.len == 0:
        continue
      try:
        spriteViewers[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if spriteViewers[i] in appState.spriteViewers:
              appState.spriteViewers[spriteViewers[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(spriteViewers[i])

    runFrameLimiter(lastTick, sim.config.targetFps)

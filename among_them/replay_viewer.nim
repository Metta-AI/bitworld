import
  std/[os, parseopt, uri],
  protocol, windy,
  global, replays, sim,
  ../clients/global_client

when not defined(emscripten):
  import std/monotimes

type
  ReplayViewer = ref object
    app: GlobalApp
    sim: SimServer
    replay: ReplayPlayer
    state: GlobalViewerState
    inputPackets: seq[string]
    loaded: bool

proc clientDistDir(): string =
  ## Returns the shared client distribution directory.
  clientDataDir().parentDir() / "dist"

proc addInputPacket(viewer: ReplayViewer, packet: string) =
  ## Queues one local global protocol client packet.
  viewer.inputPackets.add(packet)

proc initReplayViewer(): ReplayViewer =
  ## Creates a replay viewer with an in-memory global transport.
  result = ReplayViewer()
  result.state = initGlobalViewerState()
  result.sim = initSimServer(defaultGameConfig())
  let viewer = result
  result.app = initGlobalApp(
    options = GlobalOptions(
      title: "Among Them Replay Viewer",
      atlasPath: clientDistDir() / "atlas.png",
      palettePath: clientDataDir() / "pallete.png",
      packetSink: proc(packet: string) =
        viewer.addInputPacket(packet)
    )
  )
  result.app.setStatus("Drop a replay file")

proc resetLoadedState(viewer: ReplayViewer, data: ReplayData) =
  ## Resets simulation and viewer state around loaded replay data.
  var config = defaultGameConfig()
  config.update(data.configJson)
  viewer.sim = initSimServer(config)
  viewer.replay = initReplayPlayer(data)
  viewer.state = initGlobalViewerState()
  viewer.inputPackets.setLen(0)
  viewer.loaded = true
  viewer.app.resetProtocolState()
  viewer.app.setStatus("")

proc loadReplayBytes(
  viewer: ReplayViewer,
  name: string,
  bytes: string
) =
  ## Loads replay bytes and reports any parsing error in the overlay.
  try:
    viewer.resetLoadedState(parseReplayBytes(bytes))
  except CatchableError as e:
    viewer.loaded = false
    viewer.app.setStatus("Could not load replay: " & e.msg)
    echo "Could not load replay ", name, ": ", e.msg

proc loadReplayPath(viewer: ReplayViewer, path: string) =
  ## Loads a native replay file from disk.
  if path.len == 0:
    return
  try:
    viewer.loadReplayBytes(path, readFile(path))
  except CatchableError as e:
    viewer.app.setStatus("Could not read replay: " & e.msg)

proc replayUrl(windowUrl: string): string =
  ## Returns the replay query parameter from one URL.
  let parsed = parseUri(windowUrl)
  for key, value in decodeQuery(parsed.query):
    if key == "replay":
      return value

proc downloadReplay(viewer: ReplayViewer, url: string) =
  ## Downloads a replay file and loads it when the response arrives.
  if url.len == 0:
    return
  viewer.app.setStatus("Downloading replay")
  let request = startHttpRequest(url)
  request.onError = proc(message: string) =
    viewer.loaded = false
    viewer.app.setStatus("Could not download replay: " & message)
  request.onResponse = proc(response: HttpResponse) =
    if response.code < 200 or response.code >= 300:
      viewer.loaded = false
      viewer.app.setStatus("Could not download replay: HTTP " & $response.code)
      return
    viewer.loadReplayBytes(url, response.body)

proc installFileDrop(viewer: ReplayViewer) =
  ## Hooks browser and desktop file drops into replay loading.
  viewer.app.setFileDropCallback(
    proc(fileName, fileData: string) =
      viewer.loadReplayBytes(fileName, fileData)
  )

proc drainInput(viewer: ReplayViewer) =
  ## Applies queued local global viewer input packets.
  for packet in viewer.inputPackets:
    viewer.state.applyGlobalViewerMessage(packet)
  viewer.inputPackets.setLen(0)

proc applyPendingReplayControls(viewer: ReplayViewer) =
  ## Applies replay controls emitted by the previous viewer update.
  if not viewer.loaded:
    viewer.state.replayCommands.setLen(0)
    viewer.state.replaySeekTick = -1
    return
  if viewer.state.replaySeekTick >= 0:
    viewer.replay.applyReplaySeek(viewer.sim, viewer.state.replaySeekTick)
  for command in viewer.state.replayCommands:
    viewer.replay.applyReplayCommand(viewer.sim, command)
  viewer.state.replayCommands.setLen(0)
  viewer.state.replaySeekTick = -1

proc stepLoadedReplay(viewer: ReplayViewer) =
  ## Advances the loaded replay according to its transport state.
  if not viewer.loaded or not viewer.replay.playing:
    return
  try:
    for _ in 0 ..< viewer.replay.replaySpeed():
      if viewer.replay.playing:
        viewer.replay.stepReplay(viewer.sim)
    if viewer.replay.looping and not viewer.replay.playing:
      viewer.replay.seekReplay(viewer.sim, 0)
      viewer.replay.playing = true
  except CatchableError as e:
    viewer.replay.playing = false
    viewer.app.setStatus("Replay stopped: " & e.msg)

proc buildPacket(viewer: ReplayViewer): seq[uint8] =
  ## Builds the next global protocol packet for the current replay state.
  var nextState: GlobalViewerState
  result = viewer.sim.buildSpriteProtocolUpdates(
    viewer.state,
    nextState,
    if viewer.loaded: viewer.sim.tickCount else: -1,
    viewer.loaded and viewer.replay.playing,
    if viewer.loaded: viewer.replay.replaySpeed() else: 1,
    if viewer.loaded: viewer.replay.replayMaxTick() else: -1,
    viewer.loaded and viewer.replay.looping,
    viewer.loaded
  )
  viewer.state = nextState

proc tick(viewer: ReplayViewer) =
  ## Pumps one replay viewer frame.
  viewer.app.handleInput()
  viewer.drainInput()
  viewer.applyPendingReplayControls()
  viewer.stepLoadedReplay()
  let packet = viewer.buildPacket()
  if packet.len > 0:
    viewer.app.parseMessage(blobFromBytes(packet))
  viewer.app.maybeFit()
  viewer.app.draw()

proc parseReplayPathArg(): string =
  ## Returns the optional native replay path command line argument.
  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      if key == "load-replay":
        return value
    of cmdArgument:
      return key
    else:
      discard

proc runReplayViewer*() =
  ## Runs the Among Them replay viewer.
  let viewer = initReplayViewer()
  when not defined(emscripten):
    var lastTick = getMonoTime()
  viewer.installFileDrop()
  viewer.loadReplayPath(parseReplayPathArg())
  viewer.downloadReplay(replayUrl(viewer.app.windowUrl()))
  while viewer.app.windowOpen:
    pollEvents()
    viewer.tick()
    when not defined(emscripten):
      runFrameLimiter(lastTick)
  viewer.app.shutdown()

when isMainModule:
  runReplayViewer()

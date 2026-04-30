import std/[monotimes, os, parseopt, strformat, times]
import pixie, silky, windy
import protocol, server, sim, replays, marketboard

const
  PixelScale = 4
  WindowWidth = ScreenWidth * PixelScale
  WindowHeight = ScreenHeight * PixelScale
  AtlasPath = "replay_atlas.png"

type
  ReplayViewerApp = ref object
    window: Window
    silky: Silky
    sim: SimServer
    replay: MbReplayPlayer
    loaded: bool
    followPlayer: int
    unpacked: seq[uint8]
    statusText: string

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "clients" / "data"

proc palettePath(): string =
  clientDataDir() / "pallete.png"

proc unpack4bpp(packed: openArray[uint8], unpacked: var seq[uint8]) =
  let targetLen = packed.len * 2
  if unpacked.len != targetLen:
    unpacked.setLen(targetLen)
  for i, b in packed:
    unpacked[i * 2] = b and 0x0F
    unpacked[i * 2 + 1] = (b shr 4) and 0x0F

proc sampleColor(index: uint8): ColorRGBX =
  let swatch = Palette[index.int and 0x0F]
  rgbx(swatch.r, swatch.g, swatch.b, swatch.a)

proc initViewer(): ReplayViewerApp =
  result = ReplayViewerApp()
  result.sim = initSimServer(0)
  result.followPlayer = 0
  result.unpacked = newSeq[uint8](ScreenWidth * ScreenHeight)
  result.statusText = "Drop a .mbreplay file or pass --load path"

  loadPalette(palettePath())
  result.sim.loadRenderAssets()

  let builder = newAtlasBuilder(64, 2)
  builder.write(AtlasPath)

  result.window = newWindow("Marketboard Replay Viewer",
    ivec2(WindowWidth.int32, WindowHeight.int32),
    style = DecoratedResizable, visible = true)
  result.window.runeInputEnabled = true
  makeContextCurrent(result.window)
  when not defined(useDirectX):
    loadExtensions()
  result.silky = newSilky(result.window, AtlasPath)

proc loadReplay(viewer: ReplayViewerApp, path: string) =
  if path.len == 0:
    return
  try:
    let data = loadMbReplay(path)
    viewer.sim = initSimServer(0)
    viewer.sim.loadRenderAssets()
    viewer.replay = initMbReplayPlayer(data)
    viewer.followPlayer = 0
    viewer.loaded = true
    viewer.statusText = ""
    echo "Loaded replay: ", path
  except CatchableError as e:
    viewer.loaded = false
    viewer.statusText = "Error: " & e.msg
    echo "Could not load replay ", path, ": ", e.msg

proc renderFrame(viewer: ReplayViewerApp) =
  let playerIndex =
    if viewer.loaded and viewer.sim.players.len > 0:
      viewer.followPlayer mod viewer.sim.players.len
    else:
      -1

  let packed = viewer.sim.render(playerIndex)
  unpack4bpp(packed, viewer.unpacked)

  let frameSize = viewer.window.size
  viewer.silky.beginUi(viewer.window, frameSize)
  viewer.silky.clearScreen(rgbx(0, 0, 0, 255))

  let
    logicalWidth = int(frameSize.x.float32 / viewer.silky.uiScale)
    logicalHeight = int(frameSize.y.float32 / viewer.silky.uiScale)
    pixelScale = min(logicalWidth div ScreenWidth, logicalHeight div ScreenHeight)
    viewportWidth = ScreenWidth * pixelScale
    viewportHeight = ScreenHeight * pixelScale
    originX = (logicalWidth - viewportWidth) div 2
    originY = (logicalHeight - viewportHeight) div 2

  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let index = viewer.unpacked[y * ScreenWidth + x]
      if index == TransparentColorIndex:
        continue
      let px = originX + x * pixelScale
      let py = originY + y * pixelScale
      viewer.silky.drawRect(
        vec2(px.float32, py.float32),
        vec2(pixelScale.float32, pixelScale.float32),
        sampleColor(index)
      )

  viewer.silky.endUi()
  viewer.window.swapBuffers()

proc handleKeyboard(viewer: ReplayViewerApp) =
  viewer.window.onRune = proc(rune: Rune) =
    if not viewer.loaded:
      return
    let ch = char(rune.uint32 and 0x7F)
    case ch
    of '[':
      viewer.followPlayer = max(0, viewer.followPlayer - 1)
    of ']':
      if viewer.sim.players.len > 0:
        viewer.followPlayer = min(viewer.sim.players.len - 1, viewer.followPlayer + 1)
    else:
      viewer.replay.applyReplayCommand(viewer.sim, ch)

proc stepReplay(viewer: ReplayViewerApp) =
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
    viewer.statusText = "Replay error: " & e.msg
    echo "Replay stopped: ", e.msg

proc tick(viewer: ReplayViewerApp) =
  viewer.stepReplay()
  viewer.renderFrame()

proc parseReplayPathArg(): string =
  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      if key == "load":
        return value
    of cmdArgument:
      return key
    else:
      discard

proc runReplayViewer() =
  let viewer = initViewer()
  viewer.handleKeyboard()

  let replayPath = parseReplayPathArg()
  if replayPath.len > 0:
    viewer.loadReplay(replayPath)

  viewer.window.onFileDrop = proc(fileName, fileData: string) =
    try:
      let data = parseMbReplayBytes(fileData)
      viewer.sim = initSimServer(0)
      viewer.sim.loadRenderAssets()
      viewer.replay = initMbReplayPlayer(data)
      viewer.followPlayer = 0
      viewer.loaded = true
      viewer.statusText = ""
      echo "Loaded replay: ", fileName
    except CatchableError as e:
      viewer.loaded = false
      viewer.statusText = "Error: " & e.msg
      echo "Could not load replay ", fileName, ": ", e.msg

  var lastTick = getMonoTime()
  let frameDuration = initDuration(microseconds = 1_000_000 div MbReplayFps)

  while not viewer.window.closeRequested:
    pollEvents()
    viewer.tick()

    let elapsed = getMonoTime() - lastTick
    if elapsed < frameDuration:
      sleep(int((frameDuration - elapsed).inMilliseconds))
    lastTick = getMonoTime()

  try:
    removeFile(AtlasPath)
  except CatchableError:
    discard

when isMainModule:
  runReplayViewer()

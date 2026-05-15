import pixie, vmath, silky, windy
import protocol
import server

const
  ViewerScale = 4
  ViewerWidth = ScreenWidth * ViewerScale
  ViewerHeight = ScreenHeight * ViewerScale
  ViewerBackground = rgbx(17, 20, 28, 255)

type
  Viewer* = ref object
    window*: Window
    silky*: Silky

proc initViewer*(title: string): Viewer =
  result = Viewer()
  result.window = newWindow(
    title = title,
    size = ivec2(ViewerWidth.int32, ViewerHeight.int32),
    style = Decorated,
    visible = true
  )
  makeContextCurrent(result.window)
  when not defined(useDirectX):
    loadExtensions()
  result.silky = newSilky(result.window, "")

proc viewerOpen*(viewer: Viewer): bool =
  if viewer == nil:
    return true
  not viewer.window.closeRequested

proc drawFrame*(viewer: Viewer, unpacked: openArray[uint8]) =
  if viewer == nil:
    return
  let frameSize = viewer.window.size
  viewer.silky.beginUi(viewer.window, frameSize)
  viewer.silky.clearScreen(ViewerBackground)

  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let index = unpacked[y * ScreenWidth + x]
      if index == 0:
        continue
      let swatch = Palette[index.int]
      viewer.silky.drawRect(
        vec2((x * ViewerScale).float32, (y * ViewerScale).float32),
        vec2(ViewerScale.float32, ViewerScale.float32),
        rgbx(swatch.r, swatch.g, swatch.b, swatch.a)
      )

proc endFrame*(viewer: Viewer) =
  if viewer == nil:
    return
  viewer.silky.endUi()
  viewer.window.swapBuffers()

proc pumpViewer*(viewer: Viewer) =
  if viewer == nil:
    return
  pollEvents()

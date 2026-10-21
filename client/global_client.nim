import
  std/[algorithm, math, monotimes, os, tables, times, uri],
  chroma, paddy, pixie, bitworld/spriteprotocol, bitworld/scales, silky, supersnappy, windy

type
  GlobalLayer = object
    id, kind, flags, width, height: int
    textureId: GLuint
    image: Image
    dirty: bool

  GlobalSprite = object
    width, height: int
    label: string
    pixels: seq[uint8]
    indices: seq[uint8]
      ## Index plane kept for indexed sprites so a later palette swap
      ## can reuse it; empty for RGBA sprites.
    palette: seq[uint8]

  GlobalObject = object
    id, x, y, z, layer, spriteId: int

  MousePoint = object
    x, y, layer: int

  GlobalOptions* = object
    title*: string
    reconnectDelayMilliseconds*: int64
    atlasPath*: string
    palettePath*: string
    packetSink*: proc(packet: string)
    playerMode*: bool
    hasWindowPos*: bool
    windowPos*: IVec2
    selectedGamepadIndex*: int

  NetworkState = object
    ws: WebSocketHandle
    url: string
    connected: bool
    connecting: bool
    lastConnectAttemptAt: MonoTime
    reconnectDelayMilliseconds: int64
    errorMessage: string

  RawRenderer = object
    program: GLuint
    vao: GLuint
    vertexBuffer: GLuint
    samplerLocation: GLint

  GlobalApp* = ref object
    window: Window
    silky: Silky
    renderer: RawRenderer
    network: NetworkState
    packetSink: proc(packet: string)
    statusMessage: string
    layers: Table[int, GlobalLayer]
    sprites: Table[int, GlobalSprite]
    objects: Table[int, GlobalObject]
    zoom: float32
    panX, panY: float32
    autoFit: bool
    activeMouseLayer: int
    draggingMap: bool
    dragX, dragY: float32
    playerMode: bool
    selectedGamepadIndex: int
    heldButtons: uint8
    typing: bool
    textBuffer: string
    contentScale: float32

const
  AtlasPath = "dist/atlas.png"
  PalettePath = "data/pallete.png"
  TargetFps = 60.0
  WindowWidth = 900
  WindowHeight = 640
  ZoomableFlag = SpriteLayerZoomableFlag
  UiFlag = SpriteLayerUiFlag
  MapLayerKind = SpriteLayerMap
  FullScreenLayerKind = SpriteLayerFullScreen
when not defined(emscripten):
  const NetworkPollPasses = 8
when defined(emscripten):
  const
    VertexShaderSource = """
#version 300 es
precision mediump float;
layout (location = 0) in vec2 vertexPos;
layout (location = 1) in vec2 vertexUv;
out vec2 uv;
void main()
{
  uv = vertexUv;
  gl_Position = vec4(vertexPos, 0.0, 1.0);
}
"""
    FragmentShaderSource = """
#version 300 es
precision mediump float;
in vec2 uv;
uniform sampler2D layerTexture;
out vec4 fragColor;
void main()
{
  fragColor = texture(layerTexture, uv);
}
"""
else:
  const
    VertexShaderSource = """
#version 410
layout (location = 0) in vec2 vertexPos;
layout (location = 1) in vec2 vertexUv;
out vec2 uv;
void main()
{
  uv = vertexUv;
  gl_Position = vec4(vertexPos, 0.0, 1.0);
}
"""
    FragmentShaderSource = """
#version 410
in vec2 uv;
uniform sampler2D layerTexture;
out vec4 fragColor;
void main()
{
  fragColor = texture(layerTexture, uv);
}
"""

proc shaderLog(shader: GLuint): string =
  ## Returns the OpenGL compile log for one shader.
  var length: GLint
  glGetShaderiv(shader, GL_INFO_LOG_LENGTH, length.addr)
  result = newString(max(1, length.int))
  glGetShaderInfoLog(shader, length, nil, result.cstring)

proc programLog(program: GLuint): string =
  ## Returns the OpenGL link log for one program.
  var length: GLint
  glGetProgramiv(program, GL_INFO_LOG_LENGTH, length.addr)
  result = newString(max(1, length.int))
  glGetProgramInfoLog(program, length, nil, result.cstring)

proc compileShader(kind: GLenum, source: string): GLuint =
  ## Compiles one OpenGL shader from source.
  result = glCreateShader(kind)
  let sources = allocCStringArray([source])
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  deallocCStringArray(sources)
  var status: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, status.addr)
  if status == 0:
    raise newException(ValueError, "Shader compile failed: " & shaderLog(result))

proc initRawRenderer(): RawRenderer =
  ## Creates the OpenGL state used to draw global layer textures.
  let
    vertexShader = compileShader(GL_VERTEX_SHADER, VertexShaderSource)
    fragmentShader = compileShader(GL_FRAGMENT_SHADER, FragmentShaderSource)
  result.program = glCreateProgram()
  glAttachShader(result.program, vertexShader)
  glAttachShader(result.program, fragmentShader)
  glLinkProgram(result.program)
  var status: GLint
  glGetProgramiv(result.program, GL_LINK_STATUS, status.addr)
  if status == 0:
    raise newException(
      ValueError,
      "Shader link failed: " & programLog(result.program)
    )
  result.samplerLocation =
    glGetUniformLocation(result.program, "layerTexture")
  glGenVertexArrays(1, result.vao.addr)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindVertexArray(result.vao)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  glBufferData(GL_ARRAY_BUFFER, 0, nil, GL_STREAM_DRAW)
  glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 4 * 4, nil)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, 4 * 4, cast[pointer](2 * 4))
  glEnableVertexAttribArray(1)
  glBindVertexArray(0)

proc readU16(data: string, offset: int): int =
  ## Reads a little endian unsigned 16 bit integer.
  ord(data[offset]) or (ord(data[offset + 1]) shl 8)

proc readU32(data: string, offset: int): int =
  ## Reads a little endian unsigned 32 bit integer.
  int(
    uint32(data[offset].uint8) or
    (uint32(data[offset + 1].uint8) shl 8) or
    (uint32(data[offset + 2].uint8) shl 16) or
    (uint32(data[offset + 3].uint8) shl 24)
  )

proc readI16(data: string, offset: int): int =
  ## Reads a little endian signed 16 bit integer.
  let value = data.readU16(offset)
  if value >= 0x8000:
    value - 0x10000
  else:
    value

proc spriteObjectContainsPoint*(
  objectX, objectY, spriteWidth, spriteHeight, pointX, pointY: int
): bool =
  ## Returns true when a layer-local point is inside a sprite object's bounds.
  pointX >= objectX and pointY >= objectY and
    pointX < objectX + spriteWidth and pointY < objectY + spriteHeight

proc writeI16(bytes: var seq[uint8], offset, value: int) =
  ## Writes a clamped little endian signed 16 bit integer.
  let clamped = max(-32768, min(32767, value)) and 0xffff
  bytes[offset] = uint8(clamped and 0xff)
  bytes[offset + 1] = uint8(clamped shr 8)

proc addressPath(address: string): string =
  ## Returns the path component from a websocket address.
  parseUri(address).path

proc addressUsesPlayerMode(address: string): bool =
  ## Returns true when the address targets the player endpoint.
  address.addressPath() == "/player"

proc sendBytes(app: GlobalApp, bytes: openArray[uint8]) =
  ## Sends one binary packet when connected.
  let packet = blobFromBytes(bytes)
  if app.packetSink != nil:
    app.packetSink(packet)
  when not defined(emscripten):
    if app.packetSink == nil and app.network.connected:
      app.network.ws.send(packet, BinaryMessage)

proc closeNetwork(app: GlobalApp) =
  ## Closes the native websocket connection.
  when not defined(emscripten):
    app.network.ws.close()

proc sendPlayerButtons(app: GlobalApp) =
  ## Sends the current player button mask for sprite player mode.
  if not app.playerMode:
    return
  app.sendBytes([0x84'u8, app.heldButtons and 0x7f'u8])

proc layerIndex(app: GlobalApp, id: int): GlobalLayer =
  ## Returns an existing layer or a default zoomable map layer.
  if id in app.layers:
    app.layers[id]
  else:
    GlobalLayer(
      id: id,
      kind: MapLayerKind,
      flags: ZoomableFlag,
      width: 1,
      height: 1
    )

proc isMapLayer(layer: GlobalLayer): bool =
  ## Returns true when a layer uses map coordinates.
  (layer.flags and ZoomableFlag) != 0 or layer.kind == MapLayerKind

proc isFullScreenLayer(layer: GlobalLayer): bool =
  ## Returns true when a layer is screen-fitted without pan or zoom.
  layer.kind == FullScreenLayerKind

proc isUiLayer(layer: GlobalLayer): bool =
  ## Returns true when a layer uses screen UI coordinates.
  (layer.flags and UiFlag) != 0

proc uiZoom(app: GlobalApp, logicalW, logicalH: float32): float32 =
  ## Returns the integer UI zoom that fits every UI layer.
  var sizes: seq[tuple[width, height: int]]
  for layer in app.layers.values:
    if layer.isUiLayer:
      sizes.add((layer.width, layer.height))
  uiZoomForLayers(logicalW, logicalH, sizes)

proc layerDrawRank(layer: GlobalLayer): int =
  ## Returns a coarse draw rank where base layers stay behind UI overlays.
  if layer.isMapLayer:
    0
  elif layer.isFullScreenLayer:
    1
  elif layer.isUiLayer:
    2
  else:
    2

proc mapLayer(app: GlobalApp): GlobalLayer =
  ## Returns the first map layer.
  for layer in app.layers.values:
    if layer.isMapLayer:
      return layer
  GlobalLayer(
    id: 0,
    kind: MapLayerKind,
    flags: ZoomableFlag,
    width: 1,
    height: 1
  )

proc fit(app: GlobalApp) =
  ## Fits the map layer into the current window.
  let
    layer = app.mapLayer()
    size = app.window.size
    width = max(1, layer.width).float32
    height = max(1, layer.height).float32
    logicalW = size.x.float32 / app.silky.uiScale
    logicalH = size.y.float32 / app.silky.uiScale
  app.zoom = max(0.1'f, min(logicalW / width, logicalH / height))
  app.panX = floor((logicalW - width * app.zoom) * 0.5)
  app.panY = floor((logicalH - height * app.zoom) * 0.5)

proc maybeFit*(app: GlobalApp) =
  ## Fits the map when auto-fit mode is enabled.
  if app.autoFit:
    app.fit()

proc zoomMapAt(app: GlobalApp, mouseLogical: IVec2, scrollY: float32) =
  ## Zooms the map at one screen coordinate, even when UI overlays are under it.
  let layer = app.mapLayer()
  if not layer.isMapLayer:
    return
  app.autoFit = false
  let
    beforeX = (mouseLogical.x.float32 - app.panX) / app.zoom
    beforeY = (mouseLogical.y.float32 - app.panY) / app.zoom
    factor =
      if scrollY > 0:
        1.015'f
      else:
        1.0'f / 1.015'f
  app.zoom = min(64.0'f, max(0.1'f, app.zoom * factor))
  app.panX = mouseLogical.x.float32 - beforeX * app.zoom
  app.panY = mouseLogical.y.float32 - beforeY * app.zoom

proc refreshDisplayScale(app: GlobalApp) =
  ## Updates UI scaling after the window moves between displays.
  let scale = app.window.displayScale()
  if abs(scale - app.contentScale) <= 0.001'f:
    return
  app.contentScale = scale
  app.silky.uiScale = scale
  when not defined(emscripten):
    let logicalSize = (app.window.size.vec2 / scale).ivec2
    app.window.size = logicalSize.scaledWindowSize(scale)
  app.maybeFit()

proc layerScreenRect(
  app: GlobalApp,
  layer: GlobalLayer,
  logicalW, logicalH: float32
): tuple[x, y, w, h: float32] =
  ## Returns the screen rectangle for one layer.
  if layer.isFullScreenLayer:
    let
      scale = max(
        0.000001'f,
        min(
          logicalW / max(1, layer.width).float32,
          logicalH / max(1, layer.height).float32
        )
      )
      w = layer.width.float32 * scale
      h = layer.height.float32 * scale
    return (
      x: floor((logicalW - w) * 0.5'f),
      y: floor((logicalH - h) * 0.5'f),
      w: w,
      h: h
    )

  if layer.isMapLayer:
    return (
      x: app.panX,
      y: app.panY,
      w: layer.width.float32 * app.zoom,
      h: layer.height.float32 * app.zoom
    )

  let
    zoom = app.uiZoom(logicalW, logicalH)
    w = layer.width.float32 * zoom
    h = layer.height.float32 * zoom
  case layer.kind
  of 1:
    (x: 0.0'f, y: 0.0'f, w: w, h: h)
  of 2:
    (x: logicalW - w, y: 0.0'f, w: w, h: h)
  of 3:
    (x: logicalW - w, y: logicalH - h, w: w, h: h)
  of 4:
    (x: 0.0'f, y: logicalH - h, w: w, h: h)
  of 5:
    (x: (logicalW - w) * 0.5, y: 0.0'f, w: w, h: h)
  of 6:
    (x: logicalW - w, y: (logicalH - h) * 0.5, w: w, h: h)
  of 7:
    (x: 0.0'f, y: (logicalH - h) * 0.5, w: w, h: h)
  of 8:
    (x: (logicalW - w) * 0.5, y: logicalH - h, w: w, h: h)
  else:
    (x: 0.0'f, y: 0.0'f, w: w, h: h)

proc orderedLayerIds(app: GlobalApp): seq[int] =
  ## Returns layer ids in draw order.
  result = @[]
  for id in app.layers.keys:
    result.add(id)
  result.sort(
    proc(a, b: int): int =
      let
        la = app.layers[a]
        lb = app.layers[b]
      result = cmp(la.layerDrawRank(), lb.layerDrawRank())
      if result == 0:
        result = cmp(la.kind, lb.kind)
      if result == 0:
        result = cmp(la.id, lb.id)
  )

proc orderedObjects(app: GlobalApp, layerId: int): seq[GlobalObject] =
  ## Returns objects for a layer in draw order.
  result = @[]
  for item in app.objects.values:
    if item.layer == layerId:
      result.add(item)
  result.sort(
    proc(a, b: GlobalObject): int =
      result = cmp(a.z, b.z)
      if result == 0:
        result = cmp(a.y, b.y)
      if result == 0:
        result = cmp(a.id, b.id)
  )

proc allocateLayerImage(app: GlobalApp, layer: var GlobalLayer) =
  ## Allocates an image buffer and texture for one layer.
  if layer.width <= 0 or layer.height <= 0:
    return
  if layer.image != nil and
    layer.image.width == layer.width and layer.image.height == layer.height:
      return
  layer.image = newImage(layer.width, layer.height)
  if layer.textureId == 0:
    glGenTextures(1, layer.textureId.addr)
  glBindTexture(GL_TEXTURE_2D, layer.textureId)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_RGBA8.GLint,
    layer.width.GLsizei,
    layer.height.GLsizei,
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    cast[pointer](layer.image.data[0].addr)
  )
  glBindTexture(GL_TEXTURE_2D, 0)
  layer.dirty = true

proc clearLayerImage(layer: GlobalLayer) =
  ## Clears one layer image to transparent black.
  for i in 0 ..< layer.image.data.len:
    layer.image.data[i] = rgbx(0, 0, 0, 0)

proc buildLayerImage(app: GlobalApp, layer: var GlobalLayer) =
  ## Rasterizes all objects for one layer into its image buffer.
  app.allocateLayerImage(layer)
  if layer.image == nil:
    return
  layer.clearLayerImage()
  let objects = app.orderedObjects(layer.id)
  for item in objects:
    if item.spriteId notin app.sprites:
      continue
    let sprite = app.sprites[item.spriteId]
    let
      startX = max(0, -item.x)
      startY = max(0, -item.y)
      endX = min(sprite.width, layer.width - item.x)
      endY = min(sprite.height, layer.height - item.y)
    if startX >= endX or startY >= endY:
      continue
    for y in startY ..< endY:
      let layerY = item.y + y
      for x in startX ..< endX:
        let layerX = item.x + x
        let pixelOffset = (y * sprite.width + x) * 4
        if sprite.pixels[pixelOffset + 3] == 0:
          continue
        layer.image.data[layerY * layer.width + layerX] =
          rgbx(
            sprite.pixels[pixelOffset],
            sprite.pixels[pixelOffset + 1],
            sprite.pixels[pixelOffset + 2],
            sprite.pixels[pixelOffset + 3]
          )
  layer.dirty = true

proc uploadLayerImage(app: GlobalApp, layer: GlobalLayer) =
  ## Uploads one layer image into its OpenGL texture.
  if not layer.dirty or layer.image == nil or layer.textureId == 0:
    return
  discard app
  glBindTexture(GL_TEXTURE_2D, layer.textureId)
  glTexSubImage2D(
    GL_TEXTURE_2D,
    0,
    0,
    0,
    layer.width.GLsizei,
    layer.height.GLsizei,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    cast[pointer](layer.image.data[0].addr)
  )
  glBindTexture(GL_TEXTURE_2D, 0)

proc drawLayerTexture(
  renderer: RawRenderer,
  layer: GlobalLayer,
  rect: tuple[x, y, w, h: float32],
  logicalW, logicalH: float32
) =
  ## Draws one layer texture as a screen-space quad.
  if layer.textureId == 0 or rect.w <= 0 or rect.h <= 0:
    return
  let
    x0 = rect.x / logicalW * 2.0'f - 1.0'f
    y0 = 1.0'f - rect.y / logicalH * 2.0'f
    x1 = (rect.x + rect.w) / logicalW * 2.0'f - 1.0'f
    y1 = 1.0'f - (rect.y + rect.h) / logicalH * 2.0'f
  var vertices = [
    x0, y1, 0.0'f, 1.0'f,
    x1, y1, 1.0'f, 1.0'f,
    x1, y0, 1.0'f, 0.0'f,
    x1, y0, 1.0'f, 0.0'f,
    x0, y0, 0.0'f, 0.0'f,
    x0, y1, 0.0'f, 1.0'f
  ]
  glUseProgram(renderer.program)
  glBindVertexArray(renderer.vao)
  glBindBuffer(GL_ARRAY_BUFFER, renderer.vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    vertices.len * sizeof(float32),
    vertices[0].addr,
    GL_STREAM_DRAW
  )
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, layer.textureId)
  glUniform1i(renderer.samplerLocation, 0)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  glDrawArrays(GL_TRIANGLES, 0, 6)
  glDisable(GL_BLEND)
  glBindTexture(GL_TEXTURE_2D, 0)
  glBindVertexArray(0)
  glUseProgram(0)

proc drawLayer(
  app: GlobalApp,
  layer: GlobalLayer,
  logicalW, logicalH: float32
) =
  ## Draws one global protocol layer.
  if layer.width <= 0 or layer.height <= 0:
    return
  var mutableLayer = layer
  let rect = app.layerScreenRect(layer, logicalW, logicalH)
  app.buildLayerImage(mutableLayer)
  app.uploadLayerImage(mutableLayer)
  mutableLayer.dirty = false
  app.layers[layer.id] = mutableLayer
  let objects = app.orderedObjects(layer.id)
  if layer.isUiLayer and objects.len == 0:
    return
  app.renderer.drawLayerTexture(mutableLayer, rect, logicalW, logicalH)

proc drawTextEntry(app: GlobalApp, logicalW, logicalH: float32) =
  ## Draws the player text entry overlay when typing.
  if not app.typing:
    return
  let
    margin = 16.0'f
    padding = 8.0'f
    height = 34.0'f
    width = min(720.0'f, max(180.0'f, logicalW - margin * 2.0'f))
    x = floor((logicalW - width) * 0.5'f)
    y = max(0.0'f, logicalH - height - 24.0'f)
    fill = rgbx(0, 0, 0, 220)
    line = rgbx(255, 255, 255, 130)
  app.silky.drawRect(vec2(x, y), vec2(width, height), fill)
  app.silky.drawRect(vec2(x, y), vec2(width, 1), line)
  app.silky.drawRect(vec2(x, y + height - 1), vec2(width, 1), line)
  app.silky.drawRect(vec2(x, y), vec2(1, height), line)
  app.silky.drawRect(vec2(x + width - 1, y), vec2(1, height), line)
  discard app.silky.drawText(
    "Default",
    app.textBuffer,
    vec2(x + padding, y + 7.0'f),
    rgbx(255, 255, 255, 255),
    width - padding * 2.0'f,
    height - padding * 2.0'f,
    clip = true,
    wordWrap = false
  )

proc statusText(app: GlobalApp): string =
  ## Returns the connection status text.
  if app.statusMessage.len > 0:
    return app.statusMessage
  if app.network.connected:
    ""
  elif app.network.connecting:
    "connecting..."
  elif app.network.reconnectDelayMilliseconds > 0:
    "reconnecting..."
  else:
    "disconnected..."

proc draw*(app: GlobalApp) =
  ## Draws the full global viewer.
  let
    frameSize = app.window.size
    logicalW = frameSize.x.float32 / app.silky.uiScale
    logicalH = frameSize.y.float32 / app.silky.uiScale
  app.silky.beginUi(app.window, frameSize)
  app.silky.clearScreen(rgbx(0, 0, 0, 255))
  for id in app.orderedLayerIds():
    app.drawLayer(app.layers[id], logicalW, logicalH)
  app.drawTextEntry(logicalW, logicalH)
  let status = app.statusText()
  if status.len > 0:
    discard app.silky.drawText(
      "Default",
      status,
      vec2(0, 0),
      rgbx(232, 232, 232, 255),
      logicalW,
      logicalH,
      clip = false,
      hAlign = CenterAlign,
      vAlign = MiddleAlign
    )
  app.silky.endUi()
  app.window.swapBuffers()

proc parseMessage*(app: GlobalApp, data: string) =
  ## Parses one or more global protocol messages.
  var offset = 0

  proc require(bytes: int) =
    ## Raises when a packet does not have enough bytes left.
    if offset + bytes > data.len:
      app.closeNetwork()
      raise newException(ValueError, "Truncated global protocol packet")

  while offset < data.len:
    let message = ord(data[offset])
    inc offset
    case message
    of 0x01:
      require(10)
      let
        id = data.readU16(offset)
        width = data.readU16(offset + 2)
        height = data.readU16(offset + 4)
        compressedSize = data.readU32(offset + 6)
        size = width * height * 4
      offset += 10
      if width <= 0 or height <= 0 or size < 0:
        app.closeNetwork()
        return
      require(compressedSize)
      var compressed = newSeq[uint8](compressedSize)
      for i in 0 ..< compressedSize:
        compressed[i] = data[offset + i].uint8
      offset += compressedSize
      var sprite = GlobalSprite(width: width, height: height)
      try:
        sprite.pixels = supersnappy.uncompress(compressed)
      except SnappyError:
        app.closeNetwork()
        return
      if sprite.pixels.len != size:
        app.closeNetwork()
        return
      require(2)
      let labelLength = data.readU16(offset)
      offset += 2
      require(labelLength)
      var label = newString(labelLength)
      for i in 0 ..< labelLength:
        label[i] = data[offset + i]
      offset += labelLength
      sprite.label = label
      app.sprites[id] = sprite
    of 0x08:
      require(11)
      var def = SpritePacketSpriteDef(
        id: data.readU16(offset),
        width: data.readU16(offset + 2),
        height: data.readU16(offset + 4),
        encoding: data.readU8(offset + 6)
      )
      let payloadSize = data.readU32(offset + 7)
      offset += 11
      if def.width <= 0 or def.height <= 0:
        app.closeNetwork()
        return
      require(payloadSize)
      def.compressedPixels = newSeq[uint8](payloadSize)
      for i in 0 ..< payloadSize:
        def.compressedPixels[i] = data[offset + i].uint8
      offset += payloadSize
      require(2)
      let labelLength = data.readU16(offset)
      offset += 2
      require(labelLength)
      def.label = newString(labelLength)
      for i in 0 ..< labelLength:
        def.label[i] = data[offset + i]
      offset += labelLength
      var source: DecodedSprite
      let sourceId = def.paletteSwapSourceId()
      if sourceId >= 0 and app.sprites.hasKey(sourceId):
        source = DecodedSprite(
          width: app.sprites[sourceId].width,
          height: app.sprites[sourceId].height,
          indices: app.sprites[sourceId].indices,
          palette: app.sprites[sourceId].palette
        )
      var decoded: DecodedSprite
      try:
        decoded = def.decodeSprite(source)
      except SpriteProtocolError:
        app.closeNetwork()
        return
      # Renderers need pixels; a pixel-free definition is a protocol
      # error here, matching the legacy Define Sprite branch.
      if decoded.pixels.len != def.width * def.height * 4:
        app.closeNetwork()
        return
      app.sprites[def.id] = GlobalSprite(
        width: def.width,
        height: def.height,
        label: def.label,
        pixels: decoded.pixels,
        indices: decoded.indices,
        palette: decoded.palette
      )
    of 0x02:
      require(11)
      let item = GlobalObject(
        id: data.readU16(offset),
        x: data.readI16(offset + 2),
        y: data.readI16(offset + 4),
        z: data.readI16(offset + 6),
        layer: ord(data[offset + 8]),
        spriteId: data.readU16(offset + 9)
      )
      offset += 11
      app.objects[item.id] = item
    of 0x03:
      require(2)
      app.objects.del(data.readU16(offset))
      offset += 2
    of 0x04:
      app.objects.clear()
    of 0x05:
      require(5)
      let
        layerId = ord(data[offset])
        width = data.readU16(offset + 1)
        height = data.readU16(offset + 3)
      offset += 5
      if width <= 0 or height <= 0:
        app.closeNetwork()
        return
      var layer = app.layerIndex(layerId)
      layer.width = width
      layer.height = height
      layer.image = nil
      layer.dirty = true
      app.layers[layerId] = layer
      app.maybeFit()
    of 0x06:
      require(3)
      let
        layerId = ord(data[offset])
        kind = ord(data[offset + 1])
        flags = ord(data[offset + 2])
      offset += 3
      if kind < 0 or kind > FullScreenLayerKind:
        app.closeNetwork()
        return
      var layer = app.layerIndex(layerId)
      layer.kind = kind
      layer.flags = flags
      app.layers[layerId] = layer
      app.maybeFit()
    else:
      app.closeNetwork()
      return

proc connectNetwork(app: GlobalApp) =
  ## Opens the global websocket connection.
  when not defined(emscripten):
    app.network.connected = false
    app.network.connecting = true
    app.network.errorMessage = ""
    app.network.lastConnectAttemptAt = getMonoTime()

    let ws = openWebSocket(app.network.url, noDelay = true)
    app.network.ws = ws

    ws.onOpen = proc() =
      if app.network.ws != ws:
        return
      app.network.connected = true
      app.network.connecting = false
      app.network.errorMessage = ""
      app.sendPlayerButtons()

    ws.onMessage = proc(msg: string, kind: WebSocketMessageKind) =
      if app.network.ws != ws:
        return
      if kind == BinaryMessage:
        try:
          app.parseMessage(msg)
        except ValueError as e:
          app.network.errorMessage = e.msg

    ws.onError = proc(msg: string) =
      if app.network.ws != ws:
        return
      app.network.connected = false
      app.network.connecting = false
      app.network.lastConnectAttemptAt = getMonoTime()
      app.network.errorMessage = msg

    ws.onClose = proc() =
      if app.network.ws != ws:
        return
      app.network.connected = false
      app.network.connecting = false
      app.network.lastConnectAttemptAt = getMonoTime()

proc reconnectNetwork(app: GlobalApp) =
  ## Closes the current socket and starts a new connection.
  if app.packetSink != nil:
    return
  app.closeNetwork()
  app.connectNetwork()

proc tickNetwork(app: GlobalApp) =
  ## Reconnects after disconnects when configured.
  if app.network.connected or app.network.connecting:
    return
  if app.network.reconnectDelayMilliseconds <= 0:
    return
  let elapsed =
    (getMonoTime() - app.network.lastConnectAttemptAt).inMilliseconds
  if elapsed >= app.network.reconnectDelayMilliseconds:
    app.connectNetwork()

proc pollNetwork*() =
  ## Pumps Windy network callbacks.
  when defined(emscripten):
    discard
  else:
    for i in 0 ..< NetworkPollPasses:
      pollHttp()

proc mapPoint(app: GlobalApp, mouse: IVec2): MousePoint =
  ## Converts a window mouse position into map coordinates.
  let layer = app.mapLayer()
  MousePoint(
    x: floor((mouse.x.float32 / app.silky.uiScale - app.panX) / app.zoom).int,
    y: floor((mouse.y.float32 / app.silky.uiScale - app.panY) / app.zoom).int,
    layer: layer.id
  )

proc screenLayerPoint(
  app: GlobalApp,
  layer: GlobalLayer,
  mouse: IVec2,
  logicalW, logicalH: float32
): MousePoint =
  ## Converts a window mouse position into layer-local coordinates.
  let
    rect = app.layerScreenRect(layer, logicalW, logicalH)
    mx = mouse.x.float32 / app.silky.uiScale
    my = mouse.y.float32 / app.silky.uiScale
  MousePoint(
    x: floor((mx - rect.x) * layer.width.float32 / rect.w).int,
    y: floor((my - rect.y) * layer.height.float32 / rect.h).int,
    layer: layer.id
  )

proc layerHasObjects(app: GlobalApp, layer: GlobalLayer): bool =
  ## Returns true when one or more objects are on a layer.
  for item in app.objects.values:
    if item.layer == layer.id:
      return true

proc mousePoint(app: GlobalApp, preferredLayer = -1): MousePoint =
  ## Returns the topmost protocol mouse point under the cursor.
  let
    mouse = app.window.mousePos
    logicalW = app.window.size.x.float32 / app.silky.uiScale
    logicalH = app.window.size.y.float32 / app.silky.uiScale
    mx = mouse.x.float32 / app.silky.uiScale
    my = mouse.y.float32 / app.silky.uiScale

  if preferredLayer >= 0 and preferredLayer in app.layers:
    let layer = app.layers[preferredLayer]
    if layer.isMapLayer:
      return app.mapPoint(mouse)
    if layer.isUiLayer:
      return app.screenLayerPoint(layer, mouse, logicalW, logicalH)
    if layer.isFullScreenLayer and app.layerHasObjects(layer):
      return app.screenLayerPoint(layer, mouse, logicalW, logicalH)

  var ids = app.orderedLayerIds()
  ids.sort(
    proc(a, b: int): int =
      let
        la = app.layers[a]
        lb = app.layers[b]
      result = cmp(lb.layerDrawRank(), la.layerDrawRank())
      if result == 0:
        result = cmp(lb.kind, la.kind)
      if result == 0:
        result = cmp(lb.id, la.id)
  )
  for id in ids:
    let layer = app.layers[id]
    if not layer.isUiLayer:
      continue
    let rect = app.layerScreenRect(layer, logicalW, logicalH)
    if mx >= rect.x and my >= rect.y and
      mx < rect.x + rect.w and my < rect.y + rect.h:
        let point = app.screenLayerPoint(layer, mouse, logicalW, logicalH)
        for item in app.objects.values:
          if item.layer != layer.id or item.spriteId notin app.sprites:
            continue
          let sprite = app.sprites[item.spriteId]
          if spriteObjectContainsPoint(
            item.x,
            item.y,
            sprite.width,
            sprite.height,
            point.x,
            point.y
          ):
            return point

  for id in ids:
    let layer = app.layers[id]
    if not layer.isFullScreenLayer or not app.layerHasObjects(layer):
      continue
    return app.screenLayerPoint(layer, mouse, logicalW, logicalH)

  app.mapPoint(mouse)

proc sendMousePosition(app: GlobalApp, preferredLayer = -1) =
  ## Sends the current mouse position.
  let point = app.mousePoint(preferredLayer)
  var bytes = newSeq[uint8](6)
  bytes[0] = 0x82
  bytes.writeI16(1, point.x)
  bytes.writeI16(3, point.y)
  bytes[5] = uint8(point.layer and 0xff)
  app.sendBytes(bytes)

proc sendMouseButton(app: GlobalApp, down: bool, preferredLayer = -1) =
  ## Sends the current mouse position and left button state.
  let point = app.mousePoint(preferredLayer)
  var bytes = newSeq[uint8](9)
  bytes[0] = 0x82
  bytes.writeI16(1, point.x)
  bytes.writeI16(3, point.y)
  bytes[5] = uint8(point.layer and 0xff)
  bytes[6] = 0x83
  bytes[7] = 0x01
  bytes[8] = if down: 1'u8 else: 0'u8
  app.sendBytes(bytes)

proc sendInputText(app: GlobalApp, text: string) =
  ## Sends an ASCII input text packet.
  var ascii: seq[uint8] = @[]
  for ch in text:
    if ch >= ' ' and ch <= '~':
      ascii.add(ch.uint8)
      if ascii.len == uint16.high.int:
        break
  if ascii.len == 0:
    return
  var bytes = newSeq[uint8](3 + ascii.len)
  bytes[0] = 0x81
  bytes[1] = uint8(ascii.len and 0xff)
  bytes[2] = uint8((ascii.len shr 8) and 0xff)
  for i, value in ascii:
    bytes[i + 3] = value
  app.sendBytes(bytes)

proc updatePlayerButtons(app: GlobalApp) =
  ## Sends player buttons when the held keyboard mask changes.
  let down = app.window.buttonDown
  var next = 0'u8
  if down[KeyUp]:
    next = next or ButtonUp
  if down[KeyDown]:
    next = next or ButtonDown
  if down[KeyLeft]:
    next = next or ButtonLeft
  if down[KeyRight]:
    next = next or ButtonRight
  if down[KeySpace]:
    next = next or ButtonSelect
  if down[KeyZ]:
    next = next or ButtonA
  if down[KeyX]:
    next = next or ButtonB
  let gamepads = pollGamepads()
  if app.selectedGamepadIndex >= 0 and
      app.selectedGamepadIndex < gamepads.len:
    let
      pad = gamepads[app.selectedGamepadIndex]
      lx = pad.axis(GamepadLStickX)
      ly = pad.axis(GamepadLStickY)
      deadZone = 0.35'f
    if pad.button(GamepadUp) or ly >= deadZone:
      next = next or ButtonUp
    if pad.button(GamepadDown) or ly <= -deadZone:
      next = next or ButtonDown
    if pad.button(GamepadLeft) or lx <= -deadZone:
      next = next or ButtonLeft
    if pad.button(GamepadRight) or lx >= deadZone:
      next = next or ButtonRight
    if pad.button(GamepadStart):
      next = next or ButtonSelect
    if pad.button(GamepadA):
      next = next or ButtonA
    if pad.button(GamepadB):
      next = next or ButtonB
  if next == app.heldButtons:
    return
  app.heldButtons = next
  app.sendPlayerButtons()

proc startTyping(app: GlobalApp) =
  ## Starts local player text entry and releases held buttons.
  app.typing = true
  app.textBuffer.setLen(0)
  app.window.runeInputEnabled = true
  if app.heldButtons != 0:
    app.heldButtons = 0
    app.sendPlayerButtons()

proc stopTyping(app: GlobalApp, send: bool) =
  ## Stops local player text entry and optionally sends it.
  if send:
    app.sendInputText(app.textBuffer)
  app.typing = false
  app.textBuffer.setLen(0)
  app.window.runeInputEnabled = false

proc deleteTextChar(app: GlobalApp) =
  ## Deletes the last local text entry byte.
  if app.textBuffer.len > 0:
    app.textBuffer.setLen(app.textBuffer.len - 1)

proc normalizeRune(rune: Rune): char =
  ## Converts a printable rune into one ASCII character.
  let text = $rune
  if text.len != 1:
    return '\0'
  let ch = text[0]
  if ch >= ' ' and ch <= '~':
    ch
  else:
    '\0'

proc handleInput*(app: GlobalApp) =
  ## Handles keyboard, mouse, pan, and zoom input.
  let
    pressed = app.window.buttonPressed
    released = app.window.buttonReleased
    down = app.window.buttonDown
    mouse = app.window.mousePos
    mouseLogical = ivec2(
      int32(round(mouse.x.float32 / app.silky.uiScale)),
      int32(round(mouse.y.float32 / app.silky.uiScale))
    )

  let reconnectPressed = pressed[KeyEscape] and not down[KeyLeftSuper]

  if app.playerMode:
    if app.typing:
      if pressed[KeyEnter]:
        app.stopTyping(true)
      elif pressed[KeyEscape]:
        app.stopTyping(false)
      elif pressed[KeyBackspace]:
        app.deleteTextChar()
    else:
      if reconnectPressed:
        app.reconnectNetwork()
      elif pressed[KeyEnter]:
        app.startTyping()
      else:
        app.updatePlayerButtons()
  elif reconnectPressed:
    app.reconnectNetwork()

  if pressed[MouseLeft]:
    let point = app.mousePoint()
    app.activeMouseLayer = point.layer
    let layer = app.layerIndex(point.layer)
    app.draggingMap = layer.isMapLayer
    if app.draggingMap:
      app.autoFit = false
      app.dragX = mouseLogical.x.float32 - app.panX
      app.dragY = mouseLogical.y.float32 - app.panY
    app.sendMouseButton(true, app.activeMouseLayer)

  if down[MouseLeft] and app.draggingMap:
    app.panX = mouseLogical.x.float32 - app.dragX
    app.panY = mouseLogical.y.float32 - app.dragY

  if app.window.mousePos != app.window.mousePrevPos:
    app.sendMousePosition(app.activeMouseLayer)

  if released[MouseLeft]:
    app.sendMouseButton(false, app.activeMouseLayer)
    app.draggingMap = false
    app.activeMouseLayer = -1

  if app.window.scrollDelta.y != 0:
    app.zoomMapAt(mouseLogical, app.window.scrollDelta.y)

  if pressed[DoubleClick]:
    let
      point = app.mousePoint()
      layer = app.layerIndex(point.layer)
    if layer.isMapLayer:
      app.autoFit = true
      app.fit()

proc windowOpen*(app: GlobalApp): bool =
  ## Returns true while the global window should stay open.
  not app.window.closeRequested

proc runFrameLimiter*(previousTick: var MonoTime) =
  ## Sleeps to keep the global client near the target frame rate.
  let frameDuration =
    initDuration(milliseconds = int(round(1000.0 / TargetFps)))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

when isMainModule:
  import std/[parseopt, strutils]

  proc parseReconnectDelay(value: string): int64 =
    ## Parses reconnect seconds as milliseconds.
    if value.len == 0:
      return 0
    max(0, int64(parseFloat(value) * 1000.0))

  proc parseSelectedGamepad(value: string): int =
    ## Parses a one-based gamepad index.
    let parsed = parseInt(value)
    if parsed <= 0:
      return 0
    parsed - 1

proc initGlobalApp*(
  address = DefaultGlobalAddress,
  options = GlobalOptions()
): GlobalApp =
  ## Creates the native global client app.
  let
    palettePath =
      if options.palettePath.len > 0:
        options.palettePath
      else:
        PalettePath
    atlasPath =
      if options.atlasPath.len > 0:
        options.atlasPath
      else:
        AtlasPath
  loadPalette(palettePath)
  result = GlobalApp()
  let title = if options.title.len > 0: options.title else: "Global Viewer"
  when defined(emscripten):
    result.window = newWindow(
      title = title,
      size = ivec2(WindowWidth, WindowHeight),
      visible = true
    )
  else:
    result.window = newWindow(
      title = title,
      size = ivec2(WindowWidth, WindowHeight),
      style = DecoratedResizable,
      visible = true
    )
  makeContextCurrent(result.window)
  when not defined(useDirectX) and not defined(emscripten):
    loadExtensions()
  initGamepads()
  result.silky = newSilky(result.window, atlasPath)
  result.renderer = initRawRenderer()
  result.contentScale = result.window.displayScale()
  result.silky.uiScale = result.contentScale
  when not defined(emscripten):
    result.window.size =
      ivec2(WindowWidth, WindowHeight).scaledWindowSize(result.contentScale)
  if options.hasWindowPos:
    result.window.pos = options.windowPos
  result.layers = initTable[int, GlobalLayer]()
  result.sprites = initTable[int, GlobalSprite]()
  result.objects = initTable[int, GlobalObject]()
  result.zoom = 1.0'f
  result.autoFit = true
  result.activeMouseLayer = -1
  result.packetSink = options.packetSink
  result.playerMode =
    options.playerMode or address.addressUsesPlayerMode()
  result.selectedGamepadIndex = max(0, options.selectedGamepadIndex)
  result.network.url = address
  result.network.reconnectDelayMilliseconds =
    options.reconnectDelayMilliseconds
  let app = result
  result.window.onResize = proc() =
    app.refreshDisplayScale()
  result.window.runeInputEnabled = false
  result.window.onRune = proc(rune: Rune) =
    let ch = normalizeRune(rune)
    if ch == '\0':
      return
    if app.playerMode and app.typing:
      app.textBuffer.add(ch)
  if result.packetSink == nil:
    result.connectNetwork()
  else:
    result.network.connected = true
  result.fit()

proc setStatus*(app: GlobalApp, message: string) =
  ## Sets the overlay status message.
  app.statusMessage = message

proc setFileDropCallback*(app: GlobalApp, callback: FileDropCallback) =
  ## Sets the browser and desktop file drop callback.
  app.window.onFileDrop = callback

proc windowUrl*(app: GlobalApp): string =
  ## Returns the current window URL when the platform provides one.
  app.window.url

proc resetProtocolState*(app: GlobalApp) =
  ## Clears all parsed global protocol state.
  app.layers.clear()
  app.sprites.clear()
  app.objects.clear()
  app.zoom = 1.0'f
  app.panX = 0
  app.panY = 0
  app.autoFit = true

proc shutdown*(app: GlobalApp) =
  ## Closes the global websocket.
  if app.packetSink == nil:
    app.closeNetwork()

proc runGlobalClient*(
  address = DefaultGlobalAddress,
  options = GlobalOptions()
) =
  ## Runs the native global client.
  let app = initGlobalApp(address, options)
  when not defined(emscripten):
    var lastTick = getMonoTime()
  while app.windowOpen:
    pollEvents()
    pollNetwork()
    app.refreshDisplayScale()
    when not defined(emscripten):
      if app.window.buttonPressed[KeyEscape] and
        app.window.buttonDown[KeyLeftSuper]:
          app.window.closeRequested = true
    app.handleInput()
    app.tickNetwork()
    app.maybeFit()
    app.draw()
    when not defined(emscripten):
      runFrameLimiter(lastTick)
  app.shutdown()

when isMainModule:
  var
    address = DefaultGlobalAddress
    options = GlobalOptions()
    windowX = 0
    windowY = 0
    windowXSet = false
    windowYSet = false
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "x", "window-x":
        windowX = parseInt(val)
        windowXSet = true
      of "y", "window-y":
        windowY = parseInt(val)
        windowYSet = true
      of "player":
        options.playerMode = true
      of "title":
        options.title = val
      of "palette", "palette-path":
        options.palettePath = val
      of "joystick", "gamepad", "controller":
        options.selectedGamepadIndex = parseSelectedGamepad(val)
      of "reconnect":
        options.reconnectDelayMilliseconds = parseReconnectDelay(val)
      else:
        discard
    else:
      discard
  if windowXSet or windowYSet:
    options.hasWindowPos = true
    options.windowPos = ivec2(
      if windowXSet: windowX.int32 else: 0'i32,
      if windowYSet: windowY.int32 else: 0'i32
    )
  runGlobalClient(address, options)

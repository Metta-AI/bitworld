import std/[monotimes, os, parseopt, strutils]
import pixie, supersnappy, windy
import protocol, sim, replays
import ../clients/global_client

const
  MapLayerId = 0
  MapLayerKind = 0
  ZoomableFlag = 1
  TileSize = MbTileSize
  MapPixelW = WorldWidthTiles * TileSize
  MapPixelH = WorldHeightTiles * TileSize

  TileGrassSpriteId = 1
  TilePathSpriteId = 2
  TileWallSpriteId = 3
  ObjectSpriteBase = 10
  PlayerSpriteBase = 100
  TileObjectBase = 0
  WorldObjectObjBase = 3000
  PlayerObjectBase = 4000

type
  FullmapViewer = ref object
    app: GlobalApp
    sim: SimServer
    replay: MbReplayPlayer
    loaded: bool
    initialized: bool
    inputPackets: seq[string]

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "clients" / "data"

proc clientDistDir(): string =
  repoDir() / "clients" / "dist"

proc addU8(packet: var seq[uint8], value: uint8) =
  packet.add(value)

proc addU16(packet: var seq[uint8], value: int) =
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addU32(packet: var seq[uint8], value: int) =
  let v = uint32(value)
  for shift in countup(0, 24, 8):
    packet.add(uint8((v shr shift) and 0xff'u32))

proc addI16(packet: var seq[uint8], value: int) =
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addViewport(packet: var seq[uint8], layer, width, height: int) =
  packet.addU8(0x05)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addLayer(packet: var seq[uint8], layer, layerType, flags: int) =
  packet.addU8(0x06)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerType))
  packet.addU8(uint8(flags))

proc addSprite(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label: string = ""
) =
  packet.addU8(0x01)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  var raw = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    raw[i] = pixels[i]
  let compressed = supersnappy.compress(raw)
  packet.addU32(compressed.len)
  for b in compressed:
    packet.addU8(b)
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc addObject(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addDeleteObject(packet: var seq[uint8], objectId: int) =
  packet.addU8(0x03)
  packet.addU16(objectId)

proc addClearObjects(packet: var seq[uint8]) =
  packet.addU8(0x04)

proc makeRgbaTile(paletteColor: uint8): seq[uint8] =
  let rgba = Palette[paletteColor and 0x0f]
  result = newSeq[uint8](TileSize * TileSize * 4)
  for i in 0 ..< TileSize * TileSize:
    let offset = i * 4
    result[offset] = rgba.r
    result[offset + 1] = rgba.g
    result[offset + 2] = rgba.b
    result[offset + 3] = rgba.a

proc makeRgbaOutlined(fill, outline: uint8, size: int): seq[uint8] =
  let fillRgba = Palette[fill and 0x0f]
  let outRgba = Palette[outline and 0x0f]
  result = newSeq[uint8](size * size * 4)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let offset = (y * size + x) * 4
      let isEdge = x == 0 or y == 0 or x == size - 1 or y == size - 1
      let c = if isEdge: outRgba else: fillRgba
      result[offset] = c.r
      result[offset + 1] = c.g
      result[offset + 2] = c.b
      result[offset + 3] = c.a

proc makeRgbaPlayer(paletteColor: uint8): seq[uint8] =
  let rgba = Palette[paletteColor and 0x0f]
  let bg = ColorRGBA(r: 0, g: 0, b: 0, a: 0)
  result = newSeq[uint8](7 * 7 * 4)
  for y in 0 ..< 7:
    for x in 0 ..< 7:
      let offset = (y * 7 + x) * 4
      let visible =
        (y == 0 and x >= 2 and x <= 4) or
        (y >= 1 and y <= 2 and x >= 1 and x <= 5) or
        (y >= 3 and y <= 4 and x >= 2 and x <= 4) or
        (y >= 5 and y <= 6 and (x == 1 or x == 2 or x == 4 or x == 5))
      let c = if visible: rgba else: bg
      result[offset] = c.r
      result[offset + 1] = c.g
      result[offset + 2] = c.b
      result[offset + 3] = c.a

proc objectSpriteId(obj: WorldObject): int =
  case obj.kind
  of GatherNodeObj:
    if obj.depleted: ObjectSpriteBase + 10
    else:
      case obj.material
      of WoodItem: ObjectSpriteBase
      of StoneItem: ObjectSpriteBase + 1
      of HardwoodItem: ObjectSpriteBase + 2
      of CopperItem: ObjectSpriteBase + 3
      of IronwoodItem: ObjectSpriteBase + 4
      of IronItem: ObjectSpriteBase + 5
      else: ObjectSpriteBase + 6
  of CraftStationObj:
    case obj.craftTier
    of 2: ObjectSpriteBase + 8
    of 3: ObjectSpriteBase + 9
    else: ObjectSpriteBase + 7
  of SellStallObj: ObjectSpriteBase + 11
  of BuyStallObj: ObjectSpriteBase + 12
  of GathererStallObj: ObjectSpriteBase + 13
  of CrafterStallObj: ObjectSpriteBase + 14
  of CancelStallObj: ObjectSpriteBase + 15

proc roleTint(role: Role): uint8 =
  case role
  of NoRole: 6'u8
  of Gatherer: 11'u8
  of Crafter: 12'u8

proc buildInitPacket(viewer: FullmapViewer): seq[uint8] =
  var packet: seq[uint8]
  packet.addLayer(MapLayerId, MapLayerKind, ZoomableFlag)
  packet.addViewport(MapLayerId, MapPixelW, MapPixelH)

  # Tile sprites
  packet.addSprite(TileGrassSpriteId, TileSize, TileSize, makeRgbaTile(3))
  packet.addSprite(TilePathSpriteId, TileSize, TileSize, makeRgbaTile(13))
  packet.addSprite(TileWallSpriteId, TileSize, TileSize, makeRgbaTile(1))

  # Object sprites
  packet.addSprite(ObjectSpriteBase, TileSize, TileSize, makeRgbaOutlined(11, 4, TileSize), "Wood")
  packet.addSprite(ObjectSpriteBase + 1, TileSize, TileSize, makeRgbaOutlined(6, 5, TileSize), "Stone")
  packet.addSprite(ObjectSpriteBase + 2, TileSize, TileSize, makeRgbaOutlined(3, 4, TileSize), "Hardwood")
  packet.addSprite(ObjectSpriteBase + 3, TileSize, TileSize, makeRgbaOutlined(9, 5, TileSize), "Copper")
  packet.addSprite(ObjectSpriteBase + 4, TileSize, TileSize, makeRgbaOutlined(2, 1, TileSize), "Ironwood")
  packet.addSprite(ObjectSpriteBase + 5, TileSize, TileSize, makeRgbaOutlined(14, 1, TileSize), "Iron")
  packet.addSprite(ObjectSpriteBase + 6, TileSize, TileSize, makeRgbaOutlined(7, 1, TileSize), "Unknown")
  packet.addSprite(ObjectSpriteBase + 7, TileSize, TileSize, makeRgbaOutlined(6, 0, TileSize), "Craft T1")
  packet.addSprite(ObjectSpriteBase + 8, TileSize, TileSize, makeRgbaOutlined(8, 0, TileSize), "Craft T2")
  packet.addSprite(ObjectSpriteBase + 9, TileSize, TileSize, makeRgbaOutlined(14, 0, TileSize), "Craft T3")
  packet.addSprite(ObjectSpriteBase + 10, TileSize, TileSize, makeRgbaOutlined(5, 1, TileSize), "Depleted")
  packet.addSprite(ObjectSpriteBase + 11, TileSize, TileSize, makeRgbaOutlined(9, 4, TileSize), "Sell")
  packet.addSprite(ObjectSpriteBase + 12, TileSize, TileSize, makeRgbaOutlined(12, 4, TileSize), "Buy")
  packet.addSprite(ObjectSpriteBase + 13, TileSize, TileSize, makeRgbaOutlined(11, 3, TileSize), "Gatherer Stall")
  packet.addSprite(ObjectSpriteBase + 14, TileSize, TileSize, makeRgbaOutlined(8, 2, TileSize), "Crafter Stall")
  packet.addSprite(ObjectSpriteBase + 15, TileSize, TileSize, makeRgbaOutlined(4, 1, TileSize), "Cancel")

  # Player sprites per role
  packet.addSprite(PlayerSpriteBase, 7, 7, makeRgbaPlayer(roleTint(NoRole)), "Player")
  packet.addSprite(PlayerSpriteBase + 1, 7, 7, makeRgbaPlayer(roleTint(Gatherer)), "Gatherer")
  packet.addSprite(PlayerSpriteBase + 2, 7, 7, makeRgbaPlayer(roleTint(Crafter)), "Crafter")

  # Place tile objects
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      let tileId = TileObjectBase + ty * WorldWidthTiles + tx
      let spriteId = case viewer.sim.tileKinds[tileIndex(tx, ty)]
        of GrassTile: TileGrassSpriteId
        of PathTile: TilePathSpriteId
        of WallTile: TileWallSpriteId
      packet.addObject(tileId, tx * TileSize, ty * TileSize, 0, MapLayerId, spriteId)

  # Place world objects
  for i, obj in viewer.sim.objects:
    let objId = WorldObjectObjBase + i
    packet.addObject(objId, obj.tx * TileSize, obj.ty * TileSize, 1, MapLayerId, objectSpriteId(obj))

  packet

proc buildTickPacket(viewer: FullmapViewer): seq[uint8] =
  var packet: seq[uint8]

  # Update world objects (depleted state may change)
  for i, obj in viewer.sim.objects:
    let objId = WorldObjectObjBase + i
    packet.addObject(objId, obj.tx * TileSize, obj.ty * TileSize, 1, MapLayerId, objectSpriteId(obj))

  # Update players
  for i, player in viewer.sim.players:
    let objId = PlayerObjectBase + i
    let spriteId = case player.role
      of NoRole: PlayerSpriteBase
      of Gatherer: PlayerSpriteBase + 1
      of Crafter: PlayerSpriteBase + 2
    packet.addObject(objId, player.x, player.y, 2, MapLayerId, spriteId)

  packet

proc addInputPacket(viewer: FullmapViewer, packet: string) =
  viewer.inputPackets.add(packet)

proc initFullmapViewer*(): FullmapViewer =
  result = FullmapViewer()
  result.sim = initSimServer(0)
  let viewer = result
  result.app = initGlobalApp(
    options = GlobalOptions(
      title: "Marketboard Fullmap Viewer",
      atlasPath: clientDistDir() / "atlas.png",
      palettePath: clientDataDir() / "pallete.png",
      # TODO: re-enable once global_client supports these fields
      # windowWidth: 1200,
      # windowHeight: 900,
      # zoomFactor: 1.08,
      packetSink: proc(packet: string) =
        viewer.addInputPacket(packet)
    )
  )
  result.app.setStatus("Drop a .mbreplay file or pass --load path")

proc loadReplay*(viewer: FullmapViewer, path: string) =
  if not fileExists(path):
    viewer.app.setStatus("File not found: " & path)
    return
  try:
    let data = loadMbReplay(path)
    viewer.sim = initSimServer(0)
    viewer.replay = initMbReplayPlayer(data)
    viewer.loaded = true
    viewer.initialized = false
    viewer.inputPackets.setLen(0)
    viewer.app.resetProtocolState()
    viewer.app.setStatus("")
  except CatchableError as e:
    viewer.loaded = false
    viewer.app.setStatus("Could not load: " & e.msg)

proc tick*(viewer: FullmapViewer) =
  viewer.app.handleInput()

  if viewer.loaded:
    if viewer.replay.playing:
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

    if not viewer.initialized:
      viewer.initialized = true
      let packet = viewer.buildInitPacket()
      if packet.len > 0:
        viewer.app.parseMessage(blobFromBytes(packet))

    let packet = viewer.buildTickPacket()
    if packet.len > 0:
      viewer.app.parseMessage(blobFromBytes(packet))

  viewer.app.maybeFit()
  viewer.app.draw()

proc windowOpen*(viewer: FullmapViewer): bool =
  viewer.app.windowOpen

proc installFileDrop*(viewer: FullmapViewer) =
  viewer.app.setFileDropCallback(
    proc(fileName, fileData: string) =
      try:
        let data = parseMbReplayBytes(fileData)
        viewer.sim = initSimServer(0)
        viewer.replay = initMbReplayPlayer(data)
        viewer.loaded = true
        viewer.initialized = false
        viewer.inputPackets.setLen(0)
        viewer.app.resetProtocolState()
        viewer.app.setStatus("")
      except CatchableError as e:
        viewer.loaded = false
        viewer.app.setStatus("Could not load: " & e.msg)
  )

when isMainModule:
  var replayPath = ""
  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      if key == "load" or key == "load-replay":
        replayPath = value
    of cmdArgument:
      replayPath = key
    else: discard

  let viewer = initFullmapViewer()
  viewer.installFileDrop()
  if replayPath.len > 0:
    viewer.loadReplay(replayPath)

  var lastTick = getMonoTime()
  while viewer.windowOpen():
    pollEvents()
    viewer.tick()
    runFrameLimiter(lastTick)

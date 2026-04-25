import protocol, sim
import ../common/server

const
  ReplayScrubberSpriteId = 4004
  ReplayScrubberObjectId = 4004
  ReplayScrubberWidth = 84
  ReplayScrubberHeight = 5
  ReplayScrubberTrackY = 2
  ReplayScrubberY = 8
  ReplayCenterBottomLayerId = 8
  ReplayBottomLeftLayerId = 9
  ReplayCenterBottomLayerType = 8
  ReplayBottomLeftLayerType = 4
  ReplayTickSpriteId = 4002
  ReplayControlsSpriteId = 4003
  ReplayTickObjectId = 4002
  ReplayControlsObjectId = 4003

type
  SpriteViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    mouseX*: int
    mouseY*: int
    mouseLayer*: int
    mouseDown*: bool
    selectedJoinOrder*: int
    clickPending*: bool
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]

proc initSpriteViewerState*(): SpriteViewerState =
  ## Returns the default state for one sprite protocol viewer.
  result.mouseLayer = MapLayerId
  result.selectedJoinOrder = -1
  result.replaySeekTick = -1
  result.replayCommands = @[]
proc spriteColor(color: uint8): uint8 =
  ## Converts a game palette index to a sprite protocol pixel.
  color + 1'u8

proc playerColorIndex(color: uint8): int =
  ## Returns the player color slot for a palette color.
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return i
  0

proc addU8(packet: var seq[uint8], value: uint8) =
  ## Appends one unsigned byte to a sprite protocol packet.
  packet.add(value)

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addI16(packet: var seq[uint8], value: int) =
  ## Appends one little endian signed 16 bit value.
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addViewport(packet: var seq[uint8], layer, width, height: int) =
  ## Appends a sprite protocol viewport message.
  packet.addU8(0x05)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addLayer(packet: var seq[uint8], layer, layerType, flags: int) =
  ## Appends a sprite protocol layer definition message.
  packet.addU8(0x06)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerType))
  packet.addU8(uint8(flags))

proc addSprite(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8]
) =
  ## Appends a sprite protocol sprite definition message.
  packet.addU8(0x01)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  for pixel in pixels:
    packet.addU8(pixel)

proc addObject(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  ## Appends a sprite protocol object definition message.
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addDeleteObject(packet: var seq[uint8], objectId: int) =
  ## Appends a sprite protocol object delete message.
  packet.addU8(0x03)
  packet.addU16(objectId)

proc readProtocolI16(blob: string, offset: int): int =
  ## Reads one little endian signed 16 bit value from a string.
  let value = uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc applySpriteViewerMessage*(
  state: var SpriteViewerState,
  message: string
) =
  ## Applies one or more sprite protocol client messages.
  var offset = 0
  while offset < message.len:
    let messageType = message[offset].uint8
    inc offset
    case messageType
    of 0x82:
      if offset + 4 > message.len:
        return
      state.mouseX = readProtocolI16(message, offset)
      state.mouseY = readProtocolI16(message, offset + 2)
      offset += 4
      if offset < message.len and message[offset].uint8 notin
          {0x81'u8, 0x82'u8, 0x83'u8}:
        state.mouseLayer = int(message[offset].uint8)
        inc offset
      else:
        state.mouseLayer = MapLayerId
    of 0x83:
      if offset + 2 > message.len:
        return
      let
        code = message[offset].uint8
        down = message[offset + 1].uint8
      offset += 2
      if code == 0x01'u8:
        state.mouseDown = down == 1'u8
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of 0x81:
      if offset + 2 > message.len:
        return
      let length = int(uint16(message[offset].uint8) or
        (uint16(message[offset + 1].uint8) shl 8))
      offset += 2
      if offset + length > message.len:
        return
      for i in 0 ..< length:
        state.replayCommands.add(message[offset + i])
      offset += length
    else:
      return

proc isSolid(sprite: Sprite, x, y: int, flipH: bool): bool =
  let srcX = if flipH: sprite.width - 1 - x else: x
  if srcX < 0 or srcX >= sprite.width or y < 0 or y >= sprite.height:
    return false
  sprite.pixels[sprite.spriteIndex(srcX, y)] != TransparentColorIndex

proc buildSpriteProtocolActorSprite(
  sprite: Sprite,
  tint: uint8,
  flipH: bool,
  selected: bool = false
): seq[uint8] =
  ## Builds an outlined, tinted actor sprite for the global viewer.
  let
    outWidth = sprite.width + 2
    outHeight = sprite.height + 2
    outline = if selected: 8'u8 else: OutlineColor
  result = newSeq[uint8](outWidth * outHeight)

  proc outIndex(x, y: int): int =
    y * outWidth + x

  for y in -1 .. sprite.height:
    for x in -1 .. sprite.width:
      if sprite.isSolid(x, y, flipH):
        continue
      let adjacent =
        sprite.isSolid(x - 1, y, flipH) or
        sprite.isSolid(x + 1, y, flipH) or
        sprite.isSolid(x, y - 1, flipH) or
        sprite.isSolid(x, y + 1, flipH)
      if adjacent:
        result[outIndex(x + 1, y + 1)] = spriteColor(outline)

  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let srcX = if flipH: sprite.width - 1 - x else: x
      let colorIndex = sprite.pixels[sprite.spriteIndex(srcX, y)]
      if colorIndex == TransparentColorIndex:
        continue
      let drawColor = if colorIndex == BodyColor: tint else: colorIndex
      result[outIndex(x + 1, y + 1)] = spriteColor(drawColor)

proc buildSpriteProtocolBodySprite(
  bodySprite: Sprite,
  boneSprite: Sprite,
  tint: uint8
): seq[uint8] =
  ## Builds an outlined dead body sprite for the global viewer.
  let
    outWidth = bodySprite.width + 2
    outHeight = bodySprite.height + 2
  result = newSeq[uint8](outWidth * outHeight)

  proc outIndex(x, y: int): int =
    y * outWidth + x

  proc bodySolid(x, y: int): bool =
    if x < 0 or x >= bodySprite.width or
        y < 0 or y >= bodySprite.height:
      return false
    bodySprite.pixels[bodySprite.spriteIndex(x, y)] !=
      TransparentColorIndex or
      boneSprite.pixels[boneSprite.spriteIndex(x, y)] !=
      TransparentColorIndex

  for y in -1 .. bodySprite.height:
    for x in -1 .. bodySprite.width:
      if bodySolid(x, y):
        continue
      let adjacent =
        bodySolid(x - 1, y) or
        bodySolid(x + 1, y) or
        bodySolid(x, y - 1) or
        bodySolid(x, y + 1)
      if adjacent:
        result[outIndex(x + 1, y + 1)] = spriteColor(OutlineColor)

  for y in 0 ..< bodySprite.height:
    for x in 0 ..< bodySprite.width:
      if bodySprite.pixels[bodySprite.spriteIndex(x, y)] !=
          TransparentColorIndex:
        result[outIndex(x + 1, y + 1)] = spriteColor(tint)
      let boneColor = boneSprite.pixels[boneSprite.spriteIndex(x, y)]
      if boneColor != TransparentColorIndex:
        result[outIndex(x + 1, y + 1)] = spriteColor(boneColor)

proc buildSpriteProtocolRawSprite(sprite: Sprite): seq[uint8] =
  ## Builds a raw sprite protocol sprite from a game sprite.
  result = newSeq[uint8](sprite.width * sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        result[sprite.spriteIndex(x, y)] = spriteColor(colorIndex)

proc putTextSpritePixel(
  pixels: var seq[uint8],
  width, height, x, y: int,
  color: uint8
) =
  ## Puts one protocol pixel into a text sprite.
  if x < 0 or y < 0 or x >= width or y >= height:
    return
  pixels[y * width + x] = spriteColor(color)

proc buildSpriteProtocolTextSprite(
  sim: SimServer,
  lines: openArray[string],
  color: uint8
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a transparent multi-line text sprite.
  result.width = 1
  for line in lines:
    result.width = max(result.width, line.len * 6)
  result.height = max(1, lines.len * 8 - 1)
  result.pixels = newSeq[uint8](result.width * result.height)
  for lineIndex, line in lines:
    let baseY = lineIndex * 8
    var baseX = 0
    for ch in line:
      if ch == ' ':
        baseX += 6
        continue
      let letter = letterIndex(ch)
      if letter >= 0 and letter < sim.letterSprites.len:
        let sprite = sim.letterSprites[letter]
        for y in 0 ..< sprite.height:
          for x in 0 ..< sprite.width:
            if sprite.pixels[sprite.spriteIndex(x, y)] !=
                TransparentColorIndex:
              result.pixels.putTextSpritePixel(
                result.width,
                result.height,
                baseX + x,
                baseY + y,
                color
              )
      elif ch >= '0' and ch <= '9':
        let sprite = sim.digitSprites[ord(ch) - ord('0')]
        for y in 0 ..< sprite.height:
          for x in 0 ..< sprite.width:
            if sprite.pixels[sprite.spriteIndex(x, y)] !=
                TransparentColorIndex:
              result.pixels.putTextSpritePixel(
                result.width,
                result.height,
                baseX + x,
                baseY + y,
                color
              )
      baseX += 6

proc spritePixelsFromPackedFrame(packed: openArray[uint8]): seq[uint8] =
  ## Converts a packed Bitworld frame into protocol sprite pixels.
  result = newSeq[uint8](ScreenWidth * ScreenHeight)
  var j = 0
  for byte in packed:
    result[j] = spriteColor(byte and 0x0f)
    inc j
    result[j] = spriteColor((byte shr 4) and 0x0f)
    inc j

proc buildSpriteProtocolInit(sim: SimServer): seq[uint8] =
  ## Builds the initial global viewer snapshot.
  result = @[]
  var mapPixels = newSeq[uint8](sim.mapPixels.len)
  for i in 0 ..< sim.mapPixels.len:
    mapPixels[i] = spriteColor(sim.mapPixels[i])
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, MapWidth, MapHeight)
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, 128, 16)
  result.addLayer(BottomRightLayerId, BottomRightLayerType, UiLayerFlag)
  result.addViewport(BottomRightLayerId, ScreenWidth, ScreenHeight)
  result.addSprite(MapSpriteId, MapWidth, MapHeight, mapPixels)
  result.addObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)
  let taskPixels = buildSpriteProtocolRawSprite(sim.taskIconSprite)
  result.addSprite(
    TaskSpriteId,
    sim.taskIconSprite.width,
    sim.taskIconSprite.height,
    taskPixels
  )
  for i in 0 ..< PlayerColors.len:
    let
      playerRight = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        false
      )
      playerLeft = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        true
      )
      ghostRight = buildSpriteProtocolActorSprite(
        sim.ghostSprite,
        PlayerColors[i],
        false
      )
      ghostLeft = buildSpriteProtocolActorSprite(
        sim.ghostSprite,
        PlayerColors[i],
        true
      )
      selectedPlayerRight = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        false,
        true
      )
      selectedPlayerLeft = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        true,
        true
      )
      selectedGhostRight = buildSpriteProtocolActorSprite(
        sim.ghostSprite,
        PlayerColors[i],
        false,
        true
      )
      selectedGhostLeft = buildSpriteProtocolActorSprite(
        sim.ghostSprite,
        PlayerColors[i],
        true,
        true
      )
      bodyPixels = buildSpriteProtocolBodySprite(
        sim.bodySprite,
        sim.boneSprite,
        PlayerColors[i]
      )
    result.addSprite(
      PlayerSpriteBase + i * 2,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      playerRight
    )
    result.addSprite(
      PlayerSpriteBase + i * 2 + 1,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      playerLeft
    )
    result.addSprite(
      GhostSpriteBase + i * 2,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      ghostRight
    )
    result.addSprite(
      GhostSpriteBase + i * 2 + 1,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      ghostLeft
    )
    result.addSprite(
      SelectedPlayerSpriteBase + i * 2,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      selectedPlayerRight
    )
    result.addSprite(
      SelectedPlayerSpriteBase + i * 2 + 1,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      selectedPlayerLeft
    )
    result.addSprite(
      SelectedGhostSpriteBase + i * 2,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      selectedGhostRight
    )
    result.addSprite(
      SelectedGhostSpriteBase + i * 2 + 1,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      selectedGhostLeft
    )
    result.addSprite(
      BodySpriteBase + i,
      sim.bodySprite.width + 2,
      sim.bodySprite.height + 2,
      bodyPixels
    )

proc spriteObjectId(player: Player): int =
  ## Returns the stable sprite protocol object id for a player.
  PlayerObjectBase + player.joinOrder

proc spritePlayerX(player: Player): int =
  ## Returns the global viewer x position for a player sprite.
  player.x - SpriteDrawOffX - 1

proc spritePlayerY(player: Player): int =
  ## Returns the global viewer y position for a player sprite.
  player.y - SpriteDrawOffY - 1

proc spriteBodyObjectId(index: int): int =
  ## Returns the sprite protocol object id for a dead body.
  BodyObjectBase + index

proc spriteTaskObjectId(index: int): int =
  ## Returns the sprite protocol object id for a task bubble.
  TaskObjectBase + index

proc spriteActorSpriteId(player: Player, selectedJoinOrder: int): int =
  ## Returns the sprite id for a player in the global viewer.
  let
    colorIndex = player.joinOrder mod PlayerColors.len
    side = if player.flipH: 1 else: 0
    selected = player.joinOrder == selectedJoinOrder
  if player.alive and selected:
    SelectedPlayerSpriteBase + colorIndex * 2 + side
  elif player.alive:
    PlayerSpriteBase + colorIndex * 2 + side
  elif selected:
    SelectedGhostSpriteBase + colorIndex * 2 + side
  else:
    GhostSpriteBase + colorIndex * 2 + side

proc selectSpritePlayer(sim: SimServer, mouseX, mouseY: int): int =
  ## Returns the join order of the topmost player under the mouse.
  result = -1
  var bestY = low(int)
  for player in sim.players:
    let
      x = player.spritePlayerX()
      y = player.spritePlayerY()
      w = sim.playerSprite.width + 2
      h = sim.playerSprite.height + 2
    if mouseX >= x and mouseX < x + w and
        mouseY >= y and mouseY < y + h and
        player.y >= bestY:
      bestY = player.y
      result = player.joinOrder

proc selectedPlayerIndex(sim: SimServer, joinOrder: int): int =
  ## Returns the player index for a join order.
  for i in 0 ..< sim.players.len:
    if sim.players[i].joinOrder == joinOrder:
      return i
  -1

proc roleName(role: PlayerRole): string =
  ## Returns a display name for a player role.
  case role
  of Crewmate:
    return "CREWMATE"
  of Imposter:
    return "IMPOSTER"

proc replayCommandAt(layer, x, y: int): char =
  ## Returns the replay transport command under a UI coordinate.
  if layer != ReplayBottomLeftLayerId:
    return '\0'
  let
    localX = x - 2
    localY = y - 1
  if localY >= 0 and localY < 8:
    if localX >= 0 and localX < 36:
      return ','
    if localX >= 42:
      return ' '
    return '\0'
  if localY < 8 or localY >= 16:
    return '\0'
  if localX >= 0 and localX < 12:
    return '1'
  if localX >= 18 and localX < 30:
    return '2'
  if localX >= 36 and localX < 48:
    return '4'
  if localX >= 54 and localX < 66:
    return '8'
  '\0'

proc replayScrubTickAt(
  layer, x, y, maxTick: int,
  requireInside = true
): int =
  ## Returns the replay tick under the scrubber pointer.
  if layer != ReplayCenterBottomLayerId or maxTick < 0:
    return -1
  let
    scrubberX = max(0, (ScreenWidth - ReplayScrubberWidth) div 2)
    localX = x - scrubberX
    localY = y - ReplayScrubberY
  if requireInside and (
      localX < 0 or localX >= ReplayScrubberWidth or
      localY < 0 or localY >= ReplayScrubberHeight
    ):
    return -1
  if ReplayScrubberWidth <= 1:
    return 0
  let clampedX = clamp(localX, 0, ReplayScrubberWidth - 1)
  clamp((clampedX * maxTick) div (ReplayScrubberWidth - 1), 0, maxTick)

proc buildReplayScrubberSprite(
  tick, maxTick: int
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a compact replay scrubber sprite.
  result.width = ReplayScrubberWidth
  result.height = ReplayScrubberHeight
  result.pixels = newSeq[uint8](ReplayScrubberWidth * ReplayScrubberHeight)
  let knobX =
    if maxTick > 0:
      clamp(
        (tick * (ReplayScrubberWidth - 1)) div maxTick,
        0,
        ReplayScrubberWidth - 1
      )
    else:
      0

  for x in 0 ..< ReplayScrubberWidth:
    result.pixels[
      ReplayScrubberTrackY * ReplayScrubberWidth + x
    ] = spriteColor(1'u8)
  for x in 0 .. knobX:
    result.pixels[
      ReplayScrubberTrackY * ReplayScrubberWidth + x
    ] = spriteColor(10'u8)
  for y in 0 ..< ReplayScrubberHeight:
    result.pixels[y * ReplayScrubberWidth + knobX] = spriteColor(2'u8)
  if knobX > 0:
    result.pixels[
      ReplayScrubberTrackY * ReplayScrubberWidth + knobX - 1
    ] = spriteColor(2'u8)
  if knobX < ReplayScrubberWidth - 1:
    result.pixels[
      ReplayScrubberTrackY * ReplayScrubberWidth + knobX + 1
    ] = spriteColor(2'u8)

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: SpriteViewerState,
  nextState: var SpriteViewerState,
  replayTick = -1,
  replayPlaying = false,
  replaySpeed = 1,
  replayMaxTick = -1
): seq[uint8] =
  ## Builds global viewer object updates for the current tick.
  result = @[]
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  if nextState.clickPending:
    let seekTick = replayScrubTickAt(
      nextState.mouseLayer,
      nextState.mouseX,
      nextState.mouseY,
      replayMaxTick
    )
    if replayTick >= 0 and seekTick >= 0:
      nextState.scrubbingReplay = true
      nextState.replaySeekTick = seekTick
    elif replayTick >= 0:
      let command = replayCommandAt(
        nextState.mouseLayer,
        nextState.mouseX,
        nextState.mouseY
      )
      if command != '\0':
        nextState.replayCommands.add(command)
      elif nextState.mouseLayer == MapLayerId:
        nextState.selectedJoinOrder =
          sim.selectSpritePlayer(nextState.mouseX, nextState.mouseY)
    elif nextState.mouseLayer == MapLayerId:
      nextState.selectedJoinOrder =
        sim.selectSpritePlayer(nextState.mouseX, nextState.mouseY)
    nextState.clickPending = false
  if replayTick >= 0 and nextState.mouseDown and nextState.scrubbingReplay:
    let seekTick = replayScrubTickAt(
      nextState.mouseLayer,
      nextState.mouseX,
      nextState.mouseY,
      replayMaxTick
    )
    if seekTick >= 0:
      nextState.replaySeekTick = seekTick
  if not nextState.initialized:
    result = sim.buildSpriteProtocolInit()
    result.addLayer(
      ReplayCenterBottomLayerId,
      ReplayCenterBottomLayerType,
      UiLayerFlag
    )
    result.addViewport(ReplayCenterBottomLayerId, ScreenWidth, 16)
    result.addLayer(
      ReplayBottomLeftLayerId,
      ReplayBottomLeftLayerType,
      UiLayerFlag
    )
    result.addViewport(ReplayBottomLeftLayerId, ScreenWidth, 16)
    nextState.initialized = true

  var currentIds: seq[int] = @[]
  for player in sim.players:
    let objectId = player.spriteObjectId()
    currentIds.add(objectId)
    result.addObject(
      objectId,
      player.spritePlayerX(),
      player.spritePlayerY(),
      player.y,
      MapLayerId,
      player.spriteActorSpriteId(nextState.selectedJoinOrder)
    )

  for i in 0 ..< sim.bodies.len:
    let
      body = sim.bodies[i]
      objectId = spriteBodyObjectId(i)
    currentIds.add(objectId)
    result.addObject(
      objectId,
      body.x - SpriteDrawOffX - 1,
      body.y - SpriteDrawOffY - 1,
      body.y,
      MapLayerId,
      BodySpriteBase + playerColorIndex(body.color)
    )

  if sim.config.showTaskBubbles:
    let bob = [0, 0, -1, -1, -1, 0, 0, 1, 1, 1]
    for i in 0 ..< sim.tasks.len:
      let
        task = sim.tasks[i]
        objectId = spriteTaskObjectId(i)
        bobY = bob[(sim.tickCount div 3) mod bob.len]
      currentIds.add(objectId)
      result.addObject(
        objectId,
        task.x + task.w div 2 - SpriteSize div 2,
        task.y - SpriteSize - 2 + bobY,
        30000,
        MapLayerId,
        TaskSpriteId
      )

  let playerIndex = sim.selectedPlayerIndex(nextState.selectedJoinOrder)
  if playerIndex >= 0:
    let
      player = sim.players[playerIndex]
      text = sim.buildSpriteProtocolTextSprite(
        [
          "ADDRESS " & player.address,
          "ROLE " & roleName(player.role)
        ],
        2'u8
      )
      viewport = spritePixelsFromPackedFrame(
        sim.buildFramePacket(playerIndex)
      )
    currentIds.add(SelectedTextObjectId)
    currentIds.add(SelectedViewportObjectId)
    result.addSprite(
      SelectedTextSpriteId,
      text.width,
      text.height,
      text.pixels
    )
    result.addObject(
      SelectedTextObjectId,
      2,
      2,
      0,
      TopLeftLayerId,
      SelectedTextSpriteId
    )
    result.addSprite(
      SelectedViewportSpriteId,
      ScreenWidth,
      ScreenHeight,
      viewport
    )
    result.addObject(
      SelectedViewportObjectId,
      0,
      0,
      0,
      BottomRightLayerId,
      SelectedViewportSpriteId
    )

  if replayTick >= 0:
    let
      tickText = sim.buildSpriteProtocolTextSprite(
        ["TICK " & $replayTick],
        2'u8
      )
      scrubber = buildReplayScrubberSprite(replayTick, replayMaxTick)
      controlText = sim.buildSpriteProtocolTextSprite(
        [
          "REWIND " &
            (if replayPlaying: "PAUSE " & $replaySpeed & "X" else: "PLAY"),
          "1X 2X 4X 8X"
        ],
        2'u8
      )
    currentIds.add(ReplayTickObjectId)
    currentIds.add(ReplayControlsObjectId)
    currentIds.add(ReplayScrubberObjectId)
    result.addSprite(
      ReplayTickSpriteId,
      tickText.width,
      tickText.height,
      tickText.pixels
    )
    result.addObject(
      ReplayTickObjectId,
      max(0, (ScreenWidth - tickText.width) div 2),
      0,
      0,
      ReplayCenterBottomLayerId,
      ReplayTickSpriteId
    )
    result.addSprite(
      ReplayScrubberSpriteId,
      scrubber.width,
      scrubber.height,
      scrubber.pixels
    )
    result.addObject(
      ReplayScrubberObjectId,
      max(0, (ScreenWidth - ReplayScrubberWidth) div 2),
      ReplayScrubberY,
      0,
      ReplayCenterBottomLayerId,
      ReplayScrubberSpriteId
    )
    result.addSprite(
      ReplayControlsSpriteId,
      controlText.width,
      controlText.height,
      controlText.pixels
    )
    result.addObject(
      ReplayControlsObjectId,
      2,
      1,
      0,
      ReplayBottomLeftLayerId,
      ReplayControlsSpriteId
    )

  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

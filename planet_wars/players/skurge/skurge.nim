import
  std/[options, os, parseopt, random, strutils, times],
  supersnappy, whisky,
  protocol, ../../sim

const
  SkurgeDefaultPort = DefaultPort
  MaxDrainMessages = 256
  NeutralPlanetSpriteBase = 100
  PlayerPlanetSpriteBase = 1000
  PlayerShipSpriteBase = 2000
  PlanetObjectBase = 2000
  PlanetSelectedObjectBase = 2100
  PlanetOriginObjectBase = 2200
  PlanetTextObjectBase = 2300
  PlanetSpriteStride = 8
  CursorDeadband = 5
  OriginSelectInterval = 15
  RetargetTicks = 240
  SweepArrivalRadius = 12
  OriginReserveShips = 1
  SendBurstMinShips = 4
  SendBurstMaxShips = 12
  NeutralBurstExtraShips = 3
  EnemyBurstExtraShips = 6
  SendBurstPaddingTicks = TargetFps div 2
  EnemyTargetPenalty = 100_000
  SweepPoints = [
    (x: 18, y: 18),
    (x: WorldWidthPixels - 18, y: 18),
    (x: WorldWidthPixels - 18, y: WorldHeightPixels - 18),
    (x: 18, y: WorldHeightPixels - 18),
    (x: WorldWidthPixels div 2, y: WorldHeightPixels div 2)
  ]

type
  SpriteKind = enum
    SpriteUnknown
    SpriteMap
    SpriteNeutralPlanet
    SpritePlayerPlanet
    SpriteRing
    SpriteShip
    SpriteText

  SpriteInfo = object
    defined: bool
    width: int
    height: int
    label: string
    kind: SpriteKind
    ownerId: int
    pixels: seq[uint8]
    color: RgbaColor

  ObjectState = object
    present: bool
    x: int
    y: int
    z: int
    layer: int
    spriteId: int

  PlanetSight = object
    found: bool
    id: int
    ownerId: int
    ships: int
    x: int
    y: int
    selected: bool
    origin: bool

  Bot = object
    sprites: seq[SpriteInfo]
    objects: seq[ObjectState]
    rng: Rand
    cameraX: int
    cameraY: int
    frameTick: int
    ownPlayerId: int
    ownColor: RgbaColor
    colorKnown: bool
    colorAnnounced: bool
    selectedPlanetId: int
    originPlanetId: int
    lastSelectedPlanetId: int
    selectionStuckTicks: int
    currentTargetId: int
    targetStartedTick: int
    avoidedTargetId: int
    avoidUntilTick: int
    sendTargetId: int
    sendOriginId: int
    sendUntilTick: int
    sweepIndex: int
    intent: string
    lastMask: uint8

proc readU16(blob: string, offset: int): int =
  ## Reads one little endian unsigned 16 bit value.
  int(uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8))

proc readI16(blob: string, offset: int): int =
  ## Reads one little endian signed 16 bit value.
  let value = uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc readU32(blob: string, offset: int): int =
  ## Reads one little endian unsigned 32 bit value.
  int(uint32(blob[offset].uint8) or
    (uint32(blob[offset + 1].uint8) shl 8) or
    (uint32(blob[offset + 2].uint8) shl 16) or
    (uint32(blob[offset + 3].uint8) shl 24))

proc ensureSprite(bot: var Bot, spriteId: int) =
  ## Grows the sprite table so it can hold one sprite id.
  if spriteId >= bot.sprites.len:
    bot.sprites.setLen(spriteId + 1)

proc ensureObject(bot: var Bot, objectId: int) =
  ## Grows the object table so it can hold one object id.
  if objectId >= bot.objects.len:
    bot.objects.setLen(objectId + 1)

proc spriteInfo(bot: Bot, spriteId: int): SpriteInfo =
  ## Returns sprite metadata or an empty sprite.
  if spriteId >= 0 and spriteId < bot.sprites.len:
    return bot.sprites[spriteId]
  SpriteInfo()

proc classifySprite(
  spriteId: int,
  label: string
): tuple[kind: SpriteKind, ownerId: int] =
  ## Classifies one Planet Wars sprite id.
  let lower = label.toLowerAscii()
  if spriteId == MapSpriteId:
    return (SpriteMap, 0)
  if spriteId >= NeutralPlanetSpriteBase and
      spriteId < NeutralPlanetSpriteBase + PlanetSpriteStride:
    return (SpriteNeutralPlanet, 0)
  if spriteId >= PlayerPlanetSpriteBase and
      spriteId < PlayerShipSpriteBase:
    return (
      SpritePlayerPlanet,
      (spriteId - PlayerPlanetSpriteBase) div PlanetSpriteStride
    )
  if lower.contains("selected") or lower.contains("origin"):
    return (SpriteRing, 0)
  if lower.contains("ship") and not lower.startsWith("ships "):
    return (SpriteShip, 0)
  if label.len > 0:
    return (SpriteText, 0)
  (SpriteUnknown, 0)

proc dominantColor(
  pixels: openArray[uint8],
  width,
  height: int
): RgbaColor =
  ## Returns the average visible color in one RGBA sprite.
  if width <= 0 or height <= 0 or pixels.len != width * height * 4:
    return RgbaColor()
  var
    r = 0
    g = 0
    b = 0
    a = 0
    count = 0
  for y in 0 ..< height:
    for x in 0 ..< width:
      let offset = (y * width + x) * 4
      if pixels[offset + 3] < 128'u8:
        continue
      let bright =
        pixels[offset] > 235'u8 and
        pixels[offset + 1] > 235'u8 and
        pixels[offset + 2] > 235'u8
      if bright:
        continue
      r += int(pixels[offset])
      g += int(pixels[offset + 1])
      b += int(pixels[offset + 2])
      a += int(pixels[offset + 3])
      inc count
  if count == 0:
    return RgbaColor()
  RgbaColor(
    r: uint8(r div count),
    g: uint8(g div count),
    b: uint8(b div count),
    a: uint8(a div count)
  )

proc colorHex(color: RgbaColor): string =
  ## Returns one color as a readable RGB hex string.
  const Hex = "0123456789abcdef"
  result = "#"
  for value in [color.r, color.g, color.b]:
    let byte = int(value)
    result.add(Hex[(byte shr 4) and 0x0f])
    result.add(Hex[byte and 0x0f])

proc applySpritePacket(bot: var Bot, packet: string): bool =
  ## Applies one or more server sprite protocol messages.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset].uint8
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        return false
      let
        spriteId = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10
      if compressedLen < 0 or offset + compressedLen + 2 > packet.len:
        return false
      let compressed =
        if compressedLen > 0:
          packet.substr(offset, offset + compressedLen - 1)
        else:
          ""
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len:
        return false
      let label =
        if labelLen > 0:
          packet.substr(offset, offset + labelLen - 1)
        else:
          ""
      offset += labelLen
      let rawPixels = supersnappy.uncompress(compressed)
      var pixels = newSeq[uint8](rawPixels.len)
      for i, ch in rawPixels:
        pixels[i] = ch.uint8
      if pixels.len != width * height * 4:
        pixels.setLen(0)
      let classified = classifySprite(spriteId, label)
      bot.ensureSprite(spriteId)
      bot.sprites[spriteId] = SpriteInfo(
        defined: true,
        width: width,
        height: height,
        label: label,
        kind: classified.kind,
        ownerId: classified.ownerId,
        pixels: pixels,
        color: dominantColor(pixels, width, height)
      )
    of 0x02:
      if offset + 11 > packet.len:
        return false
      let
        objectId = packet.readU16(offset)
        x = packet.readI16(offset + 2)
        y = packet.readI16(offset + 4)
        z = packet.readI16(offset + 6)
        layer = int(packet[offset + 8].uint8)
        spriteId = packet.readU16(offset + 9)
      offset += 11
      bot.ensureObject(objectId)
      bot.objects[objectId] = ObjectState(
        present: true,
        x: x,
        y: y,
        z: z,
        layer: layer,
        spriteId: spriteId
      )
    of 0x03:
      if offset + 2 > packet.len:
        return false
      let objectId = packet.readU16(offset)
      offset += 2
      if objectId >= 0 and objectId < bot.objects.len:
        bot.objects[objectId].present = false
    of 0x04:
      for item in bot.objects.mitems:
        item.present = false
    of 0x05:
      if offset + 5 > packet.len:
        return false
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return false
      offset += 3
    else:
      return false
  true

proc updateCamera(bot: var Bot) =
  ## Updates the visible map camera from the map object.
  if MapObjectId < bot.objects.len and bot.objects[MapObjectId].present:
    bot.cameraX = -bot.objects[MapObjectId].x
    bot.cameraY = -bot.objects[MapObjectId].y

proc objectPresent(bot: Bot, objectId: int): bool =
  ## Returns true when one object exists in the current sprite scene.
  objectId >= 0 and objectId < bot.objects.len and bot.objects[objectId].present

proc parseShips(label: string): int =
  ## Parses a dynamic ship-count sprite label.
  const Prefix = "ships "
  if not label.startsWith(Prefix):
    return -1
  try:
    parseInt(label.substr(Prefix.len))
  except ValueError:
    -1

proc planetShips(bot: Bot, planetId: int): int =
  ## Returns the visible ship count for one planet id.
  let textId = PlanetTextObjectBase + planetId
  if not bot.objectPresent(textId):
    return -1
  let sprite = bot.spriteInfo(bot.objects[textId].spriteId)
  sprite.label.parseShips()

proc planetSight(bot: Bot, planetId: int): PlanetSight =
  ## Reads one visible planet from protocol objects.
  let objectId = PlanetObjectBase + planetId
  if not bot.objectPresent(objectId):
    return PlanetSight()
  let
    objectState = bot.objects[objectId]
    sprite = bot.spriteInfo(objectState.spriteId)
  if not sprite.defined or
      sprite.kind notin {SpriteNeutralPlanet, SpritePlayerPlanet}:
    return PlanetSight()
  PlanetSight(
    found: true,
    id: planetId,
    ownerId: sprite.ownerId,
    ships: bot.planetShips(planetId),
    x: bot.cameraX + objectState.x + sprite.width div 2,
    y: bot.cameraY + objectState.y + sprite.height div 2,
    selected: bot.objectPresent(PlanetSelectedObjectBase + planetId),
    origin: bot.objectPresent(PlanetOriginObjectBase + planetId)
  )

proc visiblePlanets(bot: Bot): seq[PlanetSight] =
  ## Returns all currently visible planets.
  for planetId in 1 .. MaxPlanetCount:
    let planet = bot.planetSight(planetId)
    if planet.found:
      result.add(planet)

proc updateIdentity(bot: var Bot, planets: openArray[PlanetSight]) =
  ## Recognizes Skurge's player id and color from the origin planet.
  for planet in planets:
    if not planet.origin or planet.ownerId <= 0:
      continue
    if bot.ownPlayerId <= 0:
      bot.ownPlayerId = planet.ownerId
    if bot.ownPlayerId != planet.ownerId:
      continue
    let sprite = bot.spriteInfo(bot.objects[PlanetObjectBase + planet.id].spriteId)
    bot.ownColor = sprite.color
    bot.colorKnown = true
    return

proc selectedPlanetId(planets: openArray[PlanetSight]): int =
  ## Returns the currently selected visible planet id.
  for planet in planets:
    if planet.selected:
      return planet.id
  -1

proc originPlanetId(planets: openArray[PlanetSight]): int =
  ## Returns the currently visible origin planet id.
  for planet in planets:
    if planet.origin:
      return planet.id
  -1

proc findPlanet(
  planets: openArray[PlanetSight],
  planetId: int
): PlanetSight =
  ## Finds one visible planet by id.
  for planet in planets:
    if planet.id == planetId:
      return planet
  PlanetSight()

proc distanceSquared(ax, ay, bx, by: int): int =
  ## Returns squared distance between two points.
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc shipScore(planet: PlanetSight): int =
  ## Returns a comparable ship score for targeting.
  if planet.ships < 0:
    return 99
  planet.ships

proc chooseOrigin(
  bot: Bot,
  planets: openArray[PlanetSight]
): PlanetSight =
  ## Chooses the strongest visible owned planet as a launch origin.
  var bestShips = -1
  for planet in planets:
    if planet.ownerId != bot.ownPlayerId:
      continue
    let ships =
      if planet.ships < 0:
        0
      else:
        planet.ships
    if ships > bestShips:
      result = planet
      bestShips = ships

proc cursorWorld(bot: Bot): tuple[x, y: int] =
  ## Estimates the hidden cursor world position from the viewport camera.
  (
    bot.cameraX + ScreenWidth div 2,
    bot.cameraY + ScreenHeight div 2
  )

proc chooseTarget(
  bot: var Bot,
  planets: openArray[PlanetSight]
): PlanetSight =
  ## Chooses the next visible non-owned planet to pressure.
  var neutralVisible = false
  for planet in planets:
    if planet.ownerId == 0 and
        not (planet.id == bot.avoidedTargetId and
          bot.frameTick < bot.avoidUntilTick):
      neutralVisible = true
      break
  if bot.currentTargetId > 0 and
      bot.frameTick - bot.targetStartedTick < RetargetTicks:
    let current = planets.findPlanet(bot.currentTargetId)
    if current.found and current.ownerId != bot.ownPlayerId and
        (current.ownerId == 0 or not neutralVisible):
      return current
  var bestScore = high(int)
  let
    selected = planets.findPlanet(bot.selectedPlanetId)
    cursor = bot.cursorWorld()
    baseX =
      if selected.found:
        selected.x
      else:
        cursor.x
    baseY =
      if selected.found:
        selected.y
      else:
        cursor.y
  for planet in planets:
    if planet.ownerId == bot.ownPlayerId:
      continue
    if planet.id == bot.avoidedTargetId and bot.frameTick < bot.avoidUntilTick:
      continue
    let ownerPenalty =
      if planet.ownerId == 0:
        0
      else:
        EnemyTargetPenalty
    let score =
      ownerPenalty +
      planet.shipScore() * 24 +
      distanceSquared(baseX, baseY, planet.x, planet.y) +
      planet.id
    if score < bestScore:
      result = planet
      bestScore = score
  if result.found:
    bot.currentTargetId = result.id
    bot.targetStartedTick = bot.frameTick

proc activeSendTarget(
  bot: Bot,
  planets: openArray[PlanetSight]
): PlanetSight =
  ## Returns the current burst target while the send burst is active.
  if bot.sendTargetId <= 0 or bot.frameTick >= bot.sendUntilTick:
    return PlanetSight()
  planets.findPlanet(bot.sendTargetId)

proc activeSendOrigin(
  bot: Bot,
  planets: openArray[PlanetSight]
): PlanetSight =
  ## Returns the current burst origin while it remains visible and owned.
  if bot.sendOriginId <= 0:
    return PlanetSight()
  let origin = planets.findPlanet(bot.sendOriginId)
  if origin.found and origin.ownerId == bot.ownPlayerId:
    return origin
  PlanetSight()

proc burstShipCount(origin, target: PlanetSight): int =
  ## Estimates how many ships should be sent in one held burst.
  let available =
    if origin.ships < 0:
      SendBurstMaxShips
    else:
      max(0, origin.ships - OriginReserveShips)
  if available <= 0:
    return 0
  let
    targetShips =
      if target.ships < 0:
        SendBurstMinShips
      else:
        max(1, target.ships)
    extraShips =
      if target.ownerId == 0:
        NeutralBurstExtraShips
      else:
        EnemyBurstExtraShips
    wanted = max(SendBurstMinShips, targetShips + extraShips)
  min(available, min(SendBurstMaxShips, wanted))

proc burstTickCount(shipCount: int): int =
  ## Converts a planned ship count into held-send ticks.
  if shipCount <= 0:
    return 0
  max(TargetFps, shipCount * BaseSendRepeatInterval + SendBurstPaddingTicks)

proc startSendBurst(
  bot: var Bot,
  origin,
  target: PlanetSight
) =
  ## Starts a held send burst from one origin to one target.
  let shipCount = burstShipCount(origin, target)
  if shipCount <= 0:
    bot.sendUntilTick = bot.frameTick
    return
  bot.sendTargetId = target.id
  bot.sendOriginId = origin.id
  bot.sendUntilTick = bot.frameTick + burstTickCount(shipCount)

proc axisSteerMask(dx, dy, deadband: int): uint8 =
  ## Returns a single-axis movement mask toward one delta.
  if abs(dx) <= deadband and abs(dy) <= deadband:
    return 0
  if abs(dx) >= abs(dy):
    if dx < -deadband:
      return ButtonLeft
    if dx > deadband:
      return ButtonRight
  if dy < -deadband:
    return ButtonUp
  if dy > deadband:
    return ButtonDown
  if dx < -deadband:
    return ButtonLeft
  if dx > deadband:
    return ButtonRight

proc steerMask(bot: Bot, targetX, targetY: int): uint8 =
  ## Builds d-pad input toward one world point.
  let
    cursor = bot.cursorWorld()
    dx = targetX - cursor.x
    dy = targetY - cursor.y
  axisSteerMask(dx, dy, CursorDeadband)

proc steerBetween(fromX, fromY, targetX, targetY: int): uint8 =
  ## Builds d-pad input from one known point toward another.
  let
    dx = targetX - fromX
    dy = targetY - fromY
  axisSteerMask(dx, dy, 1)

proc steerToPlanet(
  bot: Bot,
  planets: openArray[PlanetSight],
  target: PlanetSight
): uint8 =
  ## Steers toward a planet, using selected planet position as fallback.
  result = bot.steerMask(target.x, target.y)
  if result != 0 or bot.selectedPlanetId == target.id:
    return
  let selected = planets.findPlanet(bot.selectedPlanetId)
  if selected.found:
    return steerBetween(selected.x, selected.y, target.x, target.y)

proc sweepMask(bot: var Bot): uint8 =
  ## Moves the cursor through the map when no target is visible.
  let
    point = SweepPoints[bot.sweepIndex mod SweepPoints.len]
    cursor = bot.cursorWorld()
  if distanceSquared(cursor.x, cursor.y, point.x, point.y) <=
      SweepArrivalRadius * SweepArrivalRadius:
    inc bot.sweepIndex
  let nextPoint = SweepPoints[bot.sweepIndex mod SweepPoints.len]
  bot.intent = "sweep " & $bot.sweepIndex
  bot.steerMask(nextPoint.x, nextPoint.y)

proc decideNextMask(bot: var Bot): uint8 =
  ## Chooses the next controller mask from semantic sprite state.
  bot.updateCamera()
  let planets = bot.visiblePlanets()
  bot.updateIdentity(planets)
  bot.selectedPlanetId = planets.selectedPlanetId()
  bot.originPlanetId = planets.originPlanetId()
  if bot.selectedPlanetId == bot.lastSelectedPlanetId:
    inc bot.selectionStuckTicks
  else:
    bot.lastSelectedPlanetId = bot.selectedPlanetId
    bot.selectionStuckTicks = 0

  if bot.colorKnown and not bot.colorAnnounced:
    echo "skurge color ", bot.ownColor.colorHex(),
      " player=", bot.ownPlayerId
    bot.colorAnnounced = true

  if bot.ownPlayerId <= 0:
    bot.intent = "finding color"
    return bot.sweepMask()

  let activeTarget = bot.activeSendTarget(planets)
  var origin =
    if activeTarget.found:
      bot.activeSendOrigin(planets)
    else:
      PlanetSight()
  if not origin.found:
    origin = bot.chooseOrigin(planets)
  if origin.found and origin.id != bot.originPlanetId:
    bot.intent = "select origin " & $origin.id
    if bot.selectedPlanetId == origin.id:
      if bot.frameTick mod OriginSelectInterval == 0:
        return ButtonA
      return 0
    return bot.steerToPlanet(planets, origin)

  let target =
    if activeTarget.found:
      activeTarget
    else:
      bot.chooseTarget(planets)
  if not target.found:
    bot.currentTargetId = -1
    return bot.sweepMask()
  bot.currentTargetId = target.id

  if activeTarget.found:
    bot.intent = "burst planet " & $target.id
  elif target.ownerId == 0:
    bot.intent = "spam neutral " & $target.id
  elif target.ownerId == bot.ownPlayerId:
    bot.intent = "reinforce planet " & $target.id
  else:
    bot.intent = "attack planet " & $target.id
  if bot.selectedPlanetId != target.id:
    if bot.selectionStuckTicks > RetargetTicks:
      bot.avoidedTargetId = target.id
      bot.avoidUntilTick = bot.frameTick + RetargetTicks
      bot.currentTargetId = -1
      bot.intent = "skip planet " & $target.id
      return bot.sweepMask()
    return bot.steerToPlanet(planets, target)

  if origin.found and origin.ships >= 0 and
      origin.ships <= OriginReserveShips:
    bot.intent = "wait ships"
    bot.sendUntilTick = bot.frameTick
    return 0

  if not activeTarget.found:
    bot.startSendBurst(origin, target)
  if bot.frameTick < bot.sendUntilTick:
    return ButtonB
  0

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc playerInputBlob(mask: uint8): string =
  ## Builds a sprite protocol player input packet.
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

proc chatBlob(text: string): string =
  ## Builds a sprite protocol text input packet.
  var bytes: seq[uint8] = @[0x81'u8]
  bytes.addU16(text.len)
  for ch in text:
    bytes.add(uint8(ord(ch)))
  blobFromBytes(bytes)

proc maskSummary(mask: uint8): string =
  ## Returns a compact human-readable input mask.
  if (mask and ButtonUp) != 0:
    result.add("U")
  if (mask and ButtonDown) != 0:
    result.add("D")
  if (mask and ButtonLeft) != 0:
    result.add("L")
  if (mask and ButtonRight) != 0:
    result.add("R")
  if (mask and ButtonA) != 0:
    result.add("A")
  if (mask and ButtonB) != 0:
    result.add("B")
  if result.len == 0:
    result = "."

proc echoDebug(bot: Bot, mask: uint8, force = false) =
  ## Prints occasional bot status for local tuning.
  if not force and bot.frameTick mod TargetFps != 0:
    return
  echo "step=", bot.frameTick,
    " keys=", mask.maskSummary(),
    " camera=", bot.cameraX, ",", bot.cameraY,
    " self=", bot.ownPlayerId,
    " origin=", bot.originPlanetId,
    " selected=", bot.selectedPlanetId,
    " target=", bot.currentTargetId,
    " intent=", bot.intent

proc queryEscape(value: string): string =
  ## Escapes a query string component.
  const Hex = "0123456789ABCDEF"
  for ch in value:
    if ch.isAlphaNumeric() or ch in {'-', '_', '.', '~'}:
      result.add(ch)
    else:
      let byte = ord(ch)
      result.add('%')
      result.add(Hex[(byte shr 4) and 0x0f])
      result.add(Hex[byte and 0x0f])

proc withPath(url, path: string): string =
  ## Adds a websocket path when the supplied URL has no path.
  let schemePos = url.find("://")
  if schemePos < 0:
    return url
  let pathStart = url.find('/', schemePos + 3)
  if pathStart >= 0:
    return url
  url & path

proc addQueryParam(url, key, value: string): string =
  ## Appends one escaped query parameter to a URL.
  if value.len == 0:
    return url
  result = url
  if '?' in result:
    result.add('&')
  else:
    result.add('?')
  result.add(key)
  result.add('=')
  result.add(value.queryEscape())

proc connectUrl(
  address,
  url,
  name,
  token: string,
  port,
  slot: int
): string =
  ## Builds the player websocket URL.
  if url.len > 0:
    result = url.withPath(WebSocketPath)
  else:
    result = "ws://" & address & ":" & $port & WebSocketPath
  result = result.addQueryParam("name", name)
  if slot >= 0:
    result = result.addQueryParam("slot", $slot)
  result = result.addQueryParam("token", token)

proc initBot(): Bot =
  ## Creates a fresh Skurge bot state.
  result.rng = initRand(getTime().toUnix() xor int64(getCurrentProcessId()))
  result.ownPlayerId = -1
  result.selectedPlanetId = -1
  result.originPlanetId = -1
  result.lastSelectedPlanetId = -1
  result.currentTargetId = -1
  result.targetStartedTick = -RetargetTicks
  result.avoidedTargetId = -1
  result.sendTargetId = -1
  result.sendOriginId = -1
  result.sweepIndex = result.rng.rand(SweepPoints.high)
  result.lastMask = 0xff'u8

proc acceptServerMessage(
  ws: WebSocket,
  message: Message,
  bot: var Bot
): bool =
  ## Handles one websocket message from the game server.
  case message.kind
  of BinaryMessage:
    result = bot.applySpritePacket(message.data)
    if result:
      inc bot.frameTick
  of Ping:
    ws.send(message.data, Pong)
  of TextMessage, Pong:
    discard

proc receiveUpdates(ws: WebSocket, bot: var Bot): bool =
  ## Receives and applies all currently queued sprite updates.
  let firstMessage = ws.receiveMessage(-1)
  if firstMessage.isNone:
    return false
  if ws.acceptServerMessage(firstMessage.get, bot):
    result = true
  var drained = 0
  while drained < MaxDrainMessages:
    let message = ws.receiveMessage(0)
    if message.isNone:
      break
    if ws.acceptServerMessage(message.get, bot):
      result = true
    inc drained

proc runBot(
  address = DefaultHost,
  port = SkurgeDefaultPort,
  url = "",
  name = "skurge",
  token = "",
  slot = -1,
  maxSteps = 0,
  chat = false
) =
  ## Connects Skurge to Planet Wars and runs the attack policy.
  let endpoint = connectUrl(address, url, name, token, port, slot)
  while true:
    try:
      echo "skurge connecting to ", endpoint
      var bot = initBot()
      let ws = newWebSocket(endpoint)
      var lastMask = 0xff'u8
      if chat:
        ws.send(chatBlob("skurge online"), BinaryMessage)
      while true:
        if not ws.receiveUpdates(bot):
          continue
        let mask = bot.decideNextMask()
        bot.echoDebug(mask, mask != lastMask)
        if mask != lastMask:
          ws.send(playerInputBlob(mask), BinaryMessage)
          lastMask = mask
        if maxSteps > 0 and bot.frameTick >= maxSteps:
          bot.echoDebug(mask, true)
          ws.close()
          return
    except CatchableError as e:
      echo "skurge reconnecting after error: ", e.msg
      sleep(250)

when isMainModule:
  var
    address = DefaultHost
    port = SkurgeDefaultPort
    url = ""
    name = "skurge"
    token = ""
    slot = -1
    maxSteps = 0
    chat = false

  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = value
      of "port":
        port = parseInt(value)
      of "url":
        url = value
      of "name":
        name = value
      of "token":
        token = value
      of "slot":
        slot = parseInt(value)
      of "max-steps":
        maxSteps = parseInt(value)
      of "chat":
        chat = true
      else:
        raise newException(ValueError, "Unknown option: --" & key)
    of cmdArgument, cmdShortOption:
      raise newException(ValueError, "Unexpected argument: " & key)
    of cmdEnd:
      discard

  runBot(address, port, url, name, token, slot, maxSteps, chat)

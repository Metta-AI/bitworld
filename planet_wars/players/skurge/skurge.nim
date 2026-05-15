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
  PlayerCursorSpriteBase = 5000
  PlanetTextSpriteBase = 10000
  PlanetObjectBase = 2000
  PlanetSelectedObjectBase = 2100
  PlanetOriginObjectBase = 2200
  PlanetTextObjectBase = 2300
  CursorObjectBase = 12000
  PlanetSpriteStride = 8
  CursorSpriteSize = 5
  CursorDeadband = 3
  OriginSelectInterval = 8
  RetargetTicks = TargetFps * 3
  SweepArrivalRadius = 18
  HomePreferredShips = 20
  OriginReserveShips = 1
  SendBurstMaxShips = 999
  SendBurstUnknownOriginShips = 72
  SendBurstMaxHoldTicks = TargetFps * 3
  SendBurstPaddingTicks = TargetFps div 3
  NearbyTargetDistance = 104
  EnemyTakeMargin = 4
  TargetShipScoreWeight = 8
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
    SpriteCursor
    SpriteText

  BotMode = enum
    ModeHome
    ModeExplore

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
    knownPlanets: seq[PlanetSight]
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
    mode: BotMode
    launchOriginId: int
    launchOriginShips: int
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
  if spriteId >= PlayerCursorSpriteBase and
      spriteId < PlanetTextSpriteBase:
    return (SpriteCursor, spriteId - PlayerCursorSpriteBase)
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
      bot.knownPlanets.setLen(0)
      bot.frameTick = 0
      bot.ownPlayerId = -1
      bot.colorKnown = false
      bot.colorAnnounced = false
      bot.selectedPlanetId = -1
      bot.originPlanetId = -1
      bot.lastSelectedPlanetId = -1
      bot.selectionStuckTicks = 0
      bot.currentTargetId = -1
      bot.targetStartedTick = -RetargetTicks
      bot.avoidedTargetId = -1
      bot.avoidUntilTick = 0
      bot.mode = ModeHome
      bot.launchOriginId = -1
      bot.launchOriginShips = 0
      bot.sendTargetId = -1
      bot.sendOriginId = -1
      bot.sendUntilTick = 0
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

proc rememberPlanets(bot: var Bot, planets: openArray[PlanetSight]) =
  ## Updates remembered planet sightings from the current viewport.
  if bot.knownPlanets.len <= MaxPlanetCount:
    bot.knownPlanets.setLen(MaxPlanetCount + 1)
  for planet in planets:
    if planet.id >= 0 and planet.id < bot.knownPlanets.len:
      bot.knownPlanets[planet.id] = planet

proc knownPlanetSights(bot: Bot): seq[PlanetSight] =
  ## Returns all remembered planet sightings.
  for planet in bot.knownPlanets:
    if planet.found:
      result.add(planet)

proc updateIdentity(bot: var Bot, planets: openArray[PlanetSight]) =
  ## Recognizes Skurge's player id and color from the origin planet.
  for planet in planets:
    if not planet.origin or planet.ownerId <= 0:
      continue
    if bot.ownPlayerId <= 0:
      bot.ownPlayerId = planet.ownerId
      bot.colorAnnounced = false
      bot.currentTargetId = -1
      bot.sendTargetId = -1
      bot.sendOriginId = -1
      bot.sendUntilTick = bot.frameTick
    if bot.ownPlayerId != planet.ownerId:
      continue
    let sprite = bot.spriteInfo(
      bot.objects[PlanetObjectBase + planet.id].spriteId
    )
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

proc originShipScore(planet: PlanetSight): int =
  ## Returns a comparable ship score for owned launch planets.
  if planet.ships < 0:
    return SendBurstUnknownOriginShips
  planet.ships

proc homeShipScore(planet: PlanetSight): int =
  ## Returns a conservative ship score for choosing a home origin.
  if planet.ships < 0:
    return 0
  planet.ships

proc chooseHomeOrigin(
  bot: Bot,
  planets: openArray[PlanetSight]
): PlanetSight =
  ## Chooses the best owned planet to return home to.
  var
    bestPreferredShips = -1
    bestFallbackShips = -1
  for planet in planets:
    if planet.ownerId != bot.ownPlayerId:
      continue
    let ships = planet.homeShipScore()
    if ships >= HomePreferredShips and ships > bestPreferredShips:
      result = planet
      bestPreferredShips = ships
    if bestPreferredShips < 0 and ships > bestFallbackShips:
      result = planet
      bestFallbackShips = ships

proc cursorWorld(bot: Bot): tuple[x, y: int] =
  ## Reads Skurge's visible cursor world position.
  if bot.ownPlayerId > 0:
    let objectId = CursorObjectBase + bot.ownPlayerId
    if bot.objectPresent(objectId):
      let
        objectState = bot.objects[objectId]
        sprite = bot.spriteInfo(objectState.spriteId)
        width =
          if sprite.defined:
            sprite.width
          else:
            CursorSpriteSize
        height =
          if sprite.defined:
            sprite.height
          else:
            CursorSpriteSize
      return (
        bot.cameraX + objectState.x + width div 2,
        bot.cameraY + objectState.y + height div 2
      )
  (
    bot.cameraX + PlayerViewportWidth div 2,
    bot.cameraY + PlayerViewportHeight div 2
  )

proc plannedOriginShips(bot: Bot, origin: PlanetSight): int =
  ## Returns the ship count this explore run should spend.
  if bot.launchOriginId == origin.id and bot.launchOriginShips > 0:
    return bot.launchOriginShips
  origin.originShipScore()

proc targetScore(origin, target: PlanetSight): int =
  ## Scores one candidate target by distance and visible ship count.
  distanceSquared(origin.x, origin.y, target.x, target.y) +
    target.shipScore() * TargetShipScoreWeight +
    target.id

proc weakEnemyTarget(
  bot: Bot,
  origin: PlanetSight,
  planets: openArray[PlanetSight],
  nearbyOnly: bool
): PlanetSight =
  ## Chooses a nearby enemy that the origin can probably take.
  let
    originShips = bot.plannedOriginShips(origin)
    available = max(1, originShips - OriginReserveShips)
    nearbyDistanceSquared = NearbyTargetDistance * NearbyTargetDistance
  var bestScore = high(int)
  for planet in planets:
    if planet.ownerId <= 0 or planet.ownerId == bot.ownPlayerId:
      continue
    let distance = distanceSquared(origin.x, origin.y, planet.x, planet.y)
    if nearbyOnly and distance > nearbyDistanceSquared:
      continue
    if planet.ships >= 0 and planet.ships + EnemyTakeMargin > available:
      continue
    if planet.id == bot.avoidedTargetId and bot.frameTick < bot.avoidUntilTick:
      continue
    let score = origin.targetScore(planet)
    if score < bestScore:
      result = planet
      bestScore = score

proc neutralTarget(
  bot: Bot,
  origin: PlanetSight,
  planets: openArray[PlanetSight],
  nearbyOnly: bool
): PlanetSight =
  ## Chooses a neutral planet near the current origin.
  let nearbyDistanceSquared = NearbyTargetDistance * NearbyTargetDistance
  var bestScore = high(int)
  for planet in planets:
    if planet.ownerId != 0:
      continue
    let distance = distanceSquared(origin.x, origin.y, planet.x, planet.y)
    if nearbyOnly and distance > nearbyDistanceSquared:
      continue
    if planet.id == bot.avoidedTargetId and bot.frameTick < bot.avoidUntilTick:
      continue
    let score = origin.targetScore(planet)
    if score < bestScore:
      result = planet
      bestScore = score

proc anyEnemyTarget(
  bot: Bot,
  origin: PlanetSight,
  planets: openArray[PlanetSight]
): PlanetSight =
  ## Chooses any enemy when no weak enemy or neutral is known.
  var bestScore = high(int)
  for planet in planets:
    if planet.ownerId <= 0 or planet.ownerId == bot.ownPlayerId:
      continue
    if planet.id == bot.avoidedTargetId and bot.frameTick < bot.avoidUntilTick:
      continue
    let score = origin.targetScore(planet)
    if score < bestScore:
      result = planet
      bestScore = score

proc chooseTargetFromOrigin(
  bot: var Bot,
  planets: openArray[PlanetSight],
  origin: PlanetSight
): PlanetSight =
  ## Chooses the best outward target from one owned origin.
  if bot.currentTargetId > 0 and
      bot.frameTick - bot.targetStartedTick < RetargetTicks:
    let current = planets.findPlanet(bot.currentTargetId)
    if current.found and current.ownerId != bot.ownPlayerId:
      return current
  result = bot.weakEnemyTarget(origin, planets, true)
  if not result.found:
    result = bot.neutralTarget(origin, planets, true)
  if not result.found:
    result = bot.weakEnemyTarget(origin, planets, false)
  if not result.found:
    result = bot.neutralTarget(origin, planets, false)
  if not result.found:
    result = bot.anyEnemyTarget(origin, planets)
  if result.found:
    bot.currentTargetId = result.id
    bot.targetStartedTick = bot.frameTick

proc burstShipCount(origin, target: PlanetSight): int =
  ## Estimates how many ships should be sent in one held burst.
  let available =
    if origin.ships < 0:
      SendBurstUnknownOriginShips
    else:
      max(1, origin.ships - OriginReserveShips)
  discard target
  min(available, SendBurstMaxShips)

proc botSendRepeatInterval(holdTicks: int): int =
  ## Returns the game's send interval while B is held.
  max(
    MinSendRepeatInterval,
    BaseSendRepeatInterval - holdTicks div SendAccelerationTicks
  )

proc burstTickCount(shipCount: int): int =
  ## Converts a planned ship count into held-send ticks.
  let plannedShips = max(1, shipCount)
  var
    sent = 0
    holdTicks = 0
    cooldown = 0
  while sent < plannedShips and holdTicks < SendBurstMaxHoldTicks:
    inc holdTicks
    if cooldown > 0:
      dec cooldown
    if cooldown == 0:
      inc sent
      cooldown = botSendRepeatInterval(holdTicks)
  min(SendBurstMaxHoldTicks, holdTicks + SendBurstPaddingTicks)

proc startSendBurst(
  bot: var Bot,
  origin,
  target: PlanetSight
) =
  ## Starts a held send burst from one origin to one target.
  let shipCount = burstShipCount(origin, target)
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

proc steerToPlanet(
  bot: Bot,
  planets: openArray[PlanetSight],
  target: PlanetSight
): uint8 =
  ## Steers the visible cursor toward one planet.
  discard planets
  if bot.selectedPlanetId == target.id:
    return
  bot.steerMask(target.x, target.y)

proc sweepMask(
  bot: var Bot,
  planets: openArray[PlanetSight]
): uint8 =
  ## Moves the cursor through the map when no target is visible.
  discard planets
  let
    point = SweepPoints[bot.sweepIndex mod SweepPoints.len]
    cursor = bot.cursorWorld()
  if distanceSquared(cursor.x, cursor.y, point.x, point.y) <=
      SweepArrivalRadius * SweepArrivalRadius:
    inc bot.sweepIndex
  let nextPoint = SweepPoints[bot.sweepIndex mod SweepPoints.len]
  bot.intent = "sweep " & $bot.sweepIndex
  bot.steerMask(nextPoint.x, nextPoint.y)

proc opportunisticSendMask(
  bot: Bot,
  planets: openArray[PlanetSight],
  mask: uint8
): uint8 =
  ## Holds send while steering if the current origin still has ships.
  if mask == 0 or bot.selectedPlanetId == bot.originPlanetId:
    return mask
  let origin = planets.findPlanet(bot.originPlanetId)
  if origin.found and origin.ownerId == bot.ownPlayerId and
      (origin.ships < 0 or origin.ships > OriginReserveShips):
    return mask or ButtonB
  mask

proc decideNextMask(bot: var Bot): uint8 =
  ## Chooses the next controller mask from semantic sprite state.
  bot.updateCamera()
  let visiblePlanets = bot.visiblePlanets()
  bot.rememberPlanets(visiblePlanets)
  let knownPlanets = bot.knownPlanetSights()
  bot.updateIdentity(visiblePlanets)
  bot.selectedPlanetId = visiblePlanets.selectedPlanetId()
  let visibleOriginId = visiblePlanets.originPlanetId()
  if visibleOriginId > 0:
    bot.originPlanetId = visibleOriginId
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
    return bot.sweepMask(visiblePlanets)

  if bot.mode == ModeHome:
    bot.sendTargetId = -1
    bot.sendOriginId = -1
    bot.sendUntilTick = 0
    bot.currentTargetId = -1
    let origin = bot.chooseHomeOrigin(knownPlanets)
    if not origin.found:
      bot.intent = "finding owned planet"
      return bot.opportunisticSendMask(
        knownPlanets,
        bot.sweepMask(visiblePlanets)
      )
    if origin.ships >= 0 and origin.ships <= OriginReserveShips:
      let mask = bot.sweepMask(visiblePlanets)
      bot.intent = "waiting home ships " & $origin.id
      return bot.opportunisticSendMask(knownPlanets, mask)
    bot.launchOriginId = origin.id
    bot.launchOriginShips = origin.homeShipScore()
    if bot.originPlanetId != origin.id:
      bot.intent = "home origin " & $origin.id &
        " ships " & $bot.launchOriginShips
      if bot.selectedPlanetId == origin.id:
        if bot.frameTick mod OriginSelectInterval == 0:
          return ButtonA
        return 0
      return bot.opportunisticSendMask(
        knownPlanets,
        bot.steerToPlanet(visiblePlanets, origin)
      )
    bot.mode = ModeExplore

  var origin = knownPlanets.findPlanet(bot.launchOriginId)
  if not origin.found or origin.ownerId != bot.ownPlayerId:
    bot.mode = ModeHome
    bot.intent = "lost launch origin"
    return bot.opportunisticSendMask(
      knownPlanets,
      bot.sweepMask(visiblePlanets)
    )
  if origin.ships >= 0:
    bot.launchOriginShips = origin.ships
  if bot.sendTargetId > 0 and bot.frameTick >= bot.sendUntilTick:
    bot.mode = ModeHome
    bot.sendTargetId = -1
    bot.sendOriginId = -1
    bot.sendUntilTick = 0
    bot.intent = "return home"
    return bot.opportunisticSendMask(
      knownPlanets,
      bot.sweepMask(visiblePlanets)
    )

  var target = PlanetSight()
  if bot.sendTargetId > 0 and bot.frameTick < bot.sendUntilTick:
    target = knownPlanets.findPlanet(bot.sendTargetId)
    if target.found and target.ownerId == bot.ownPlayerId and
        target.ships >= HomePreferredShips:
      bot.mode = ModeHome
      bot.intent = "advance from captured " & $target.id
      return bot.opportunisticSendMask(
        knownPlanets,
        bot.sweepMask(visiblePlanets)
      )
  if not target.found:
    target = bot.chooseTargetFromOrigin(knownPlanets, origin)
  if not target.found:
    bot.intent = "explore from " & $origin.id
    return bot.opportunisticSendMask(
      knownPlanets,
      bot.sweepMask(visiblePlanets)
    )
  bot.currentTargetId = target.id

  if bot.selectedPlanetId != target.id:
    if bot.selectionStuckTicks > RetargetTicks:
      bot.avoidedTargetId = target.id
      bot.avoidUntilTick = bot.frameTick + RetargetTicks
      bot.currentTargetId = -1
      bot.sendTargetId = -1
      bot.sendUntilTick = 0
      bot.intent = "skip planet " & $target.id
      return bot.opportunisticSendMask(
        knownPlanets,
        bot.sweepMask(visiblePlanets)
      )
    bot.intent = "outward target " & $target.id
    return bot.opportunisticSendMask(
      knownPlanets,
      bot.steerToPlanet(visiblePlanets, target)
    )

  if bot.sendTargetId != target.id or bot.frameTick >= bot.sendUntilTick:
    bot.startSendBurst(origin, target)
  if origin.ships >= 0 and origin.ships <= OriginReserveShips:
    bot.mode = ModeHome
    bot.intent = "origin drained"
    return bot.opportunisticSendMask(
      knownPlanets,
      bot.sweepMask(visiblePlanets)
    )
  if bot.frameTick < bot.sendUntilTick:
    if target.ownerId == 0:
      bot.intent = "drain neutral " & $target.id
    else:
      bot.intent = "drain enemy " & $target.id
    return ButtonB

  bot.mode = ModeHome
  bot.intent = "return home"
  bot.opportunisticSendMask(knownPlanets, bot.sweepMask(visiblePlanets))

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
  result.mode = ModeHome
  result.launchOriginId = -1
  result.launchOriginShips = 0
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

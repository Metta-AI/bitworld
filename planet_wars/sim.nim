import
  std/[json, os, random, strutils],
  ../common/pixelfonts

type
  RgbaColor* = object
    r*: uint8
    g*: uint8
    b*: uint8
    a*: uint8

const
  GameName* = "planet_wars"
  GameVersion* = "1"
  WorldWidthPixels* = 192
  WorldHeightPixels* = 192
  DefaultPlanetCount* = 18
  MinPlanetCount* = 1
  MaxPlanetCount* = 48
  DensePlanetCount* = 36
  PlanetSpawnMargin* = 12
  PlanetSpacing* = 10
  BaseFps* = 24
  TargetFps* = 60
  ShipSpeedPixelsPerSecond* = 48
  BaseSendRepeatInterval* = 13
  MinSendRepeatInterval* = 3
  SendAccelerationTicks* = 30
  ShipLaneOffsetMax* = 3
  ScoreIntervalTicks* = TargetFps
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  RewardWebSocketPath* = "/reward"
  MotionScale* = 256
  CursorAccel* = 30
  CursorFrictionNum* = 232
  CursorFrictionDen* = 256
  CursorMaxSpeed* = 282
  CursorStopThreshold* = 5
  BackgroundColor* = RgbaColor(r: 5'u8, g: 7'u8, b: 18'u8, a: 255'u8)
  NeutralPlanetColor* = RgbaColor(
    r: 102'u8,
    g: 112'u8,
    b: 136'u8,
    a: 255'u8
  )
  SelectionColor* = RgbaColor(
    r: 255'u8,
    g: 231'u8,
    b: 82'u8,
    a: 255'u8
  )
  OriginColor* = RgbaColor(r: 84'u8, g: 244'u8, b: 232'u8, a: 255'u8)
  ScoreColor* = RgbaColor(r: 248'u8, g: 250'u8, b: 255'u8, a: 255'u8)
  BlackColor* = RgbaColor(r: 0'u8, g: 0'u8, b: 0'u8, a: 255'u8)
  StarColors* = [
    RgbaColor(r: 168'u8, g: 211'u8, b: 255'u8, a: 255'u8),
    RgbaColor(r: 255'u8, g: 246'u8, b: 194'u8, a: 255'u8),
    RgbaColor(r: 213'u8, g: 225'u8, b: 255'u8, a: 255'u8)
  ]
  MapSpriteId* = 1
  MapObjectId* = 1
  MapLayerId* = 0
  MapLayerType* = 0
  TopLeftLayerId* = 1
  TopLeftLayerType* = 1
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  ChatVisibleLines* = 3
  ChatMaxChars* = 40

type
  PlanetWarsError* = object of CatchableError

  SimConfig* = object
    planetCount*: int

  PlanetSize* = enum
    PlanetSmall
    PlanetMedium
    PlanetLarge

  Planet* = object
    id*: int
    x*: int
    y*: int
    radius*: int
    size*: PlanetSize
    ownerId*: int
    ships*: int
    growthInterval*: int
    growthTicks*: int

  Ship* = object
    ownerId*: int
    color*: RgbaColor
    targetPlanet*: int
    startX*: int
    startY*: int
    endX*: int
    endY*: int
    progress*: int
    duration*: int

  Star* = object
    x*: int
    y*: int
    color*: RgbaColor

  Player* = object
    id*: int
    name*: string
    color*: RgbaColor
    colorHue*: int
    score*: int
    selectedPlanet*: int
    originPlanet*: int
    sendCooldown*: int
    sendHoldTicks*: int
    cursorX*: int
    cursorY*: int
    cursorVelX*: int
    cursorVelY*: int
    cursorCarryX*: int
    cursorCarryY*: int

  ChatMessage* = object
    playerId*: int
    text*: string
    color*: RgbaColor

  PlayerInput* = object
    up*: bool
    down*: bool
    left*: bool
    right*: bool
    attackPressed*: bool
    sendHeld*: bool

  SimServer* = object
    config*: SimConfig
    players*: seq[Player]
    planets*: seq[Planet]
    ships*: seq[Ship]
    stars*: seq[Star]
    rng*: Rand
    nextPlayerId*: int
    scoreTicks*: int
    tickCount*: int
    scoreRevision*: int
    textFont*: PixelFont
    chatMessages*: seq[ChatMessage]

proc repoDir*(): string =
  ## Returns the Bit World repository directory from the game cwd.
  getCurrentDir() / ".."

proc clientDataDir*(): string =
  ## Returns the shared client data directory.
  repoDir() / "clients" / "data"

proc tiny5Path*(): string =
  ## Returns the shared Tiny5 pixel font path.
  let path = getCurrentDir() / "tiny5.aseprite"
  if fileExists(path):
    return path
  repoDir() / "among_them" / "tiny5.aseprite"

proc loadTiny5Font*(): PixelFont =
  ## Loads the shared Tiny5 variable-width pixel font.
  readPixelFont(tiny5Path())

proc defaultSimConfig*(): SimConfig =
  ## Returns the default Planet Wars simulation config.
  SimConfig(planetCount: DefaultPlanetCount)

proc checkedPlanetCount*(planetCount: int): int =
  ## Returns a supported planet count or raises a game error.
  if planetCount < MinPlanetCount or planetCount > MaxPlanetCount:
    raise newException(
      PlanetWarsError,
      "planetCount must be between " & $MinPlanetCount & " and " &
        $MaxPlanetCount & "."
    )
  planetCount

proc worldClampPixel*(x, maxValue: int): int =
  ## Clamps a coordinate to the world pixel bounds.
  max(0, min(maxValue, x))

proc scaledTicks(ticksAtBaseFps: int): int =
  ## Converts a 24 Hz tick duration to the current simulation rate.
  max(1, (ticksAtBaseFps * TargetFps + BaseFps - 1) div BaseFps)

proc planetRadius*(size: PlanetSize): int =
  ## Returns the gameplay radius for one planet size.
  case size
  of PlanetSmall:
    5
  of PlanetMedium:
    6
  of PlanetLarge:
    8

proc initialShips(size: PlanetSize, rng: var Rand): int =
  ## Returns a randomized neutral ship count for one planet.
  case size
  of PlanetSmall:
    4 + rng.rand(3)
  of PlanetMedium:
    7 + rng.rand(4)
  of PlanetLarge:
    11 + rng.rand(5)

proc growthInterval(size: PlanetSize, rng: var Rand): int =
  ## Returns a randomized growth interval for one planet.
  case size
  of PlanetSmall:
    scaledTicks(42 + rng.rand(12))
  of PlanetMedium:
    scaledTicks(30 + rng.rand(10))
  of PlanetLarge:
    scaledTicks(20 + rng.rand(8))

proc randomPlanetSize(rng: var Rand): PlanetSize =
  ## Returns a randomized planet size.
  case rng.rand(99)
  of 0 .. 44:
    PlanetSmall
  of 45 .. 79:
    PlanetMedium
  else:
    PlanetLarge

proc planetsOverlap(a, b: Planet): bool =
  ## Returns true when two generated planets are too close together.
  let
    dx = a.x - b.x
    dy = a.y - b.y
    minDistance = a.radius + b.radius + PlanetSpacing
  dx * dx + dy * dy < minDistance * minDistance

proc randomConfiguredPlanetSize(
  rng: var Rand,
  planetCount: int
): PlanetSize =
  ## Returns a random planet size for the configured map density.
  if planetCount > DensePlanetCount:
    return PlanetSmall
  randomPlanetSize(rng)

proc addGeneratedPlanet(
  sim: var SimServer,
  size: PlanetSize,
  x,
  y: int
): bool =
  ## Adds one generated planet when it does not overlap existing planets.
  let planet = Planet(
    id: sim.planets.len + 1,
    x: x,
    y: y,
    radius: planetRadius(size),
    size: size,
    ownerId: 0,
    ships: initialShips(size, sim.rng),
    growthInterval: growthInterval(size, sim.rng)
  )
  for existing in sim.planets:
    if planet.planetsOverlap(existing):
      return false
  sim.planets.add planet
  true

proc densePlanetPositions(sim: var SimServer): seq[tuple[x, y: int]] =
  ## Returns shuffled grid positions for dense planet fallback.
  let
    radius = planetRadius(PlanetSmall)
    step = radius * 2 + PlanetSpacing
    minCoord = PlanetSpawnMargin + radius
    maxX = WorldWidthPixels - PlanetSpawnMargin - radius - 1
    maxY = WorldHeightPixels - PlanetSpawnMargin - radius - 1
  for y in countup(minCoord, maxY, step):
    for x in countup(minCoord, maxX, step):
      result.add((x: x, y: y))
  shuffle(sim.rng, result)

proc fillDensePlanets(sim: var SimServer, planetCount: int) =
  ## Fills remaining dense map slots with small planets on a grid.
  var positions = sim.densePlanetPositions()
  for position in positions:
    if sim.planets.len >= planetCount:
      return
    discard sim.addGeneratedPlanet(PlanetSmall, position.x, position.y)

proc markScoresChanged(sim: var SimServer) =
  ## Marks score-visible game state as changed.
  inc sim.scoreRevision

proc generatePlanets(sim: var SimServer) =
  ## Generates non-overlapping planets in the world.
  let planetCount = sim.config.planetCount.checkedPlanetCount()
  var attempts = 0
  while sim.planets.len < planetCount and
      attempts < max(800, planetCount * 320):
    inc attempts
    let
      size = sim.rng.randomConfiguredPlanetSize(planetCount)
      radius = planetRadius(size)
      xSpan = WorldWidthPixels - (PlanetSpawnMargin + radius) * 2
      ySpan = WorldHeightPixels - (PlanetSpawnMargin + radius) * 2
      x = PlanetSpawnMargin + radius + sim.rng.rand(xSpan)
      y = PlanetSpawnMargin + radius + sim.rng.rand(ySpan)
    discard sim.addGeneratedPlanet(size, x, y)
  if sim.planets.len < planetCount:
    sim.fillDensePlanets(planetCount)
  if sim.planets.len < planetCount:
    raise newException(
      PlanetWarsError,
      "Could only place " & $sim.planets.len & " of " & $planetCount &
        " requested planets."
    )

proc generateStars(sim: var SimServer) =
  ## Generates decorative star positions for the protocol background.
  for _ in 0 ..< 120:
    sim.stars.add Star(
      x: sim.rng.rand(WorldWidthPixels - 1),
      y: sim.rng.rand(WorldHeightPixels - 1),
      color: StarColors[sim.rng.rand(StarColors.high)]
    )

proc colorFromHsv*(hue, saturation, value: int): RgbaColor =
  ## Converts HSV values to an opaque RGB color.
  let
    h = ((hue mod 360) + 360) mod 360
    s = max(0, min(100, saturation))
    v = max(0, min(100, value)) * 255 div 100
    c = v * s div 100
    x = c * (60 - abs((h mod 120) - 60)) div 60
    m = v - c
  var
    r = 0
    g = 0
    b = 0
  case h div 60
  of 0:
    r = c
    g = x
  of 1:
    r = x
    g = c
  of 2:
    g = c
    b = x
  of 3:
    g = x
    b = c
  of 4:
    r = x
    b = c
  else:
    r = c
    b = x
  RgbaColor(
    r: uint8(r + m),
    g: uint8(g + m),
    b: uint8(b + m),
    a: 255'u8
  )

proc hueDistance(a, b: int): int =
  ## Returns the shortest circular distance between two hues.
  let distance = abs(a - b) mod 360
  min(distance, 360 - distance)

proc randomBrightPlayerColor*(
  sim: var SimServer
): tuple[hue: int, color: RgbaColor] =
  ## Returns a random bright HSV color away from existing players.
  var
    bestHue = sim.rng.rand(359)
    bestDistance = -1
  for _ in 0 ..< 24:
    let hue = sim.rng.rand(359)
    var minDistance = 360
    for player in sim.players:
      minDistance = min(minDistance, hue.hueDistance(player.colorHue))
    if sim.players.len == 0 or minDistance > bestDistance:
      bestHue = hue
      bestDistance = minDistance
    if minDistance >= 32:
      break
  let
    saturation = 82 + sim.rng.rand(16)
    value = 92 + sim.rng.rand(8)
  (hue: bestHue, color: colorFromHsv(bestHue, saturation, value))

proc ownerBaseColor*(sim: SimServer, ownerId: int): RgbaColor =
  ## Returns the full color for a planet or ship owner.
  if ownerId == 0:
    return NeutralPlanetColor
  for player in sim.players:
    if player.id == ownerId:
      return player.color
  NeutralPlanetColor

proc ownerVisibleColor*(sim: SimServer, viewerId, ownerId: int): RgbaColor =
  ## Returns a viewer-specific owner color.
  discard viewerId
  sim.ownerBaseColor(ownerId)

proc findPlanetIndexById*(sim: SimServer, planetId: int): int =
  ## Finds a planet index by its stable id.
  for i, planet in sim.planets:
    if planet.id == planetId:
      return i
  -1

proc countOwnedPlanets*(sim: SimServer, playerId: int): int =
  ## Counts planets owned by one player id.
  for planet in sim.planets:
    if planet.ownerId == playerId:
      inc result

proc totalPlayerShips*(sim: SimServer, playerId: int): int =
  ## Counts all ships owned by one player in planets and in transit.
  for planet in sim.planets:
    if planet.ownerId == playerId:
      result += max(0, planet.ships)
  for ship in sim.ships:
    if ship.ownerId == playerId:
      inc result

proc claimPlanetForPlayer(sim: var SimServer, playerId: int): int =
  ## Assigns one neutral planet to a joining player.
  var neutralIndices: seq[int] = @[]
  for i, planet in sim.planets:
    if planet.ownerId == 0:
      neutralIndices.add i
  let claimedIndex =
    if neutralIndices.len > 0:
      neutralIndices[sim.rng.rand(neutralIndices.high)]
    else:
      sim.rng.rand(sim.planets.high)
  sim.planets[claimedIndex].ownerId = playerId
  sim.planets[claimedIndex].ships = max(sim.planets[claimedIndex].ships, 10)
  sim.planets[claimedIndex].growthTicks = 0
  sim.markScoresChanged()
  claimedIndex

proc addPlayer*(sim: var SimServer, name: string): int =
  ## Adds a player and returns its index.
  inc sim.nextPlayerId
  let
    playerId = sim.nextPlayerId
    claimedPlanet = sim.claimPlanetForPlayer(playerId)
    planet = sim.planets[claimedPlanet]
    playerColor = sim.randomBrightPlayerColor()
  sim.players.add Player(
    id: playerId,
    name: name,
    color: playerColor.color,
    colorHue: playerColor.hue,
    selectedPlanet: claimedPlanet,
    originPlanet: claimedPlanet,
    cursorX: planet.x,
    cursorY: planet.y
  )
  sim.markScoresChanged()
  sim.players.high

proc removePlayerById*(sim: var SimServer, playerId: int) =
  ## Removes ownership and ships for one disconnected player id.
  for planet in sim.planets.mitems:
    if planet.ownerId == playerId:
      planet.ownerId = 0
  var remainingShips: seq[Ship] = @[]
  for ship in sim.ships:
    if ship.ownerId != playerId:
      remainingShips.add ship
  sim.ships = move(remainingShips)
  sim.markScoresChanged()

proc cleanChatMessage*(message: string): string =
  ## Returns a printable, bounded chat message.
  let trimmed = message.strip()
  for ch in trimmed:
    if result.len >= ChatMaxChars:
      return
    if ch >= ' ' and ch <= '~':
      result.add(ch)

proc addChatMessage*(sim: var SimServer, playerIndex: int, message: string) =
  ## Adds one visible chat line from a connected player.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let text = cleanChatMessage(message)
  if text.len == 0:
    return
  while sim.chatMessages.len >= ChatVisibleLines:
    sim.chatMessages.delete(0)
  sim.chatMessages.add ChatMessage(
    playerId: sim.players[playerIndex].id,
    text: text,
    color: sim.players[playerIndex].color
  )

proc nearestPlanetIndex*(sim: SimServer, worldX, worldY: int): int =
  ## Returns the planet nearest to a world position.
  if sim.planets.len == 0:
    return -1
  var
    bestIndex = 0
    bestDistance = high(int)
  for i, planet in sim.planets:
    let
      dx = planet.x - worldX
      dy = planet.y - worldY
      distance = dx * dx + dy * dy
    if distance < bestDistance:
      bestDistance = distance
      bestIndex = i
  bestIndex

proc applyCursorMomentumAxis(
  player: var Player,
  carry: var int,
  velocity: int,
  horizontal: bool
) =
  ## Applies subpixel cursor motion on one axis.
  carry += velocity
  while abs(carry) >= MotionScale:
    let step = if carry < 0: -1 else: 1
    if horizontal:
      let nextX = worldClampPixel(player.cursorX + step, WorldWidthPixels - 1)
      if nextX == player.cursorX:
        carry = 0
        break
      player.cursorX = nextX
    else:
      let nextY = worldClampPixel(player.cursorY + step, WorldHeightPixels - 1)
      if nextY == player.cursorY:
        carry = 0
        break
      player.cursorY = nextY
    carry -= step * MotionScale

proc shipDuration*(startX, startY, endX, endY: int): int =
  ## Returns the travel duration for one ship.
  let
    dx = abs(endX - startX)
    dy = abs(endY - startY)
    travel = max(dx, dy)
  max(
    1,
    (travel * TargetFps + ShipSpeedPixelsPerSecond - 1) div
      ShipSpeedPixelsPerSecond
  )

proc sendRepeatInterval(holdTicks: int): int =
  ## Returns the repeat interval for held send input.
  max(
    MinSendRepeatInterval,
    BaseSendRepeatInterval - holdTicks div SendAccelerationTicks
  )

proc randomShipLaneOffset(
  sim: var SimServer,
  originPlanet,
  targetPlanet: Planet
): tuple[x, y: int] =
  ## Returns a small lane offset so ship streams do not overlap perfectly.
  let laneRadius = min(
    ShipLaneOffsetMax,
    max(0, min(originPlanet.radius, targetPlanet.radius) - 2)
  )
  if laneRadius <= 0:
    return (0, 0)
  for _ in 0 ..< 16:
    let
      dx = sim.rng.rand(laneRadius * 2) - laneRadius
      dy = sim.rng.rand(laneRadius * 2) - laneRadius
    if (dx != 0 or dy != 0) and dx * dx + dy * dy <= laneRadius * laneRadius:
      return (dx, dy)
  (laneRadius, 0)

proc currentShipPosition*(ship: Ship): tuple[x: int, y: int] =
  ## Returns the current world position for one ship.
  if ship.duration <= 0:
    return (ship.endX, ship.endY)
  (
    ship.startX + ((ship.endX - ship.startX) * ship.progress) div
      ship.duration,
    ship.startY + ((ship.endY - ship.startY) * ship.progress) div
      ship.duration
  )

proc sendShip*(sim: var SimServer, playerIndex: int): bool =
  ## Sends one ship from the selected origin to the selected target.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let
    originIndex = sim.players[playerIndex].originPlanet
    targetIndex = sim.players[playerIndex].selectedPlanet
  if originIndex < 0 or originIndex >= sim.planets.len or
      targetIndex < 0 or targetIndex >= sim.planets.len:
    return false
  if originIndex == targetIndex:
    return false
  if sim.planets[originIndex].ownerId != sim.players[playerIndex].id:
    return false
  if sim.planets[originIndex].ships <= 1:
    return false
  let
    originPlanet = sim.planets[originIndex]
    targetPlanet = sim.planets[targetIndex]
    laneOffset = sim.randomShipLaneOffset(originPlanet, targetPlanet)
    startX = originPlanet.x + laneOffset.x
    startY = originPlanet.y + laneOffset.y
    endX = targetPlanet.x + laneOffset.x
    endY = targetPlanet.y + laneOffset.y
  dec sim.planets[originIndex].ships
  sim.ships.add Ship(
    ownerId: sim.players[playerIndex].id,
    color: sim.players[playerIndex].color,
    targetPlanet: targetPlanet.id,
    startX: startX,
    startY: startY,
    endX: endX,
    endY: endY,
    duration: shipDuration(startX, startY, endX, endY)
  )
  sim.markScoresChanged()
  true

proc resolveShipArrival(sim: var SimServer, ship: Ship) =
  ## Applies a ship arrival to its target planet.
  let targetIndex = sim.findPlanetIndexById(ship.targetPlanet)
  if targetIndex < 0 or targetIndex >= sim.planets.len:
    return
  if sim.planets[targetIndex].ownerId == ship.ownerId:
    inc sim.planets[targetIndex].ships
  else:
    dec sim.planets[targetIndex].ships
    if sim.planets[targetIndex].ships < 0:
      sim.planets[targetIndex].ownerId = ship.ownerId
      sim.planets[targetIndex].ships = -sim.planets[targetIndex].ships
      sim.planets[targetIndex].growthTicks = 0
  sim.markScoresChanged()

proc stepShips(sim: var SimServer) =
  ## Advances all ships and resolves arrivals.
  var activeShips: seq[Ship] = @[]
  for ship in sim.ships:
    var updated = ship
    inc updated.progress
    if updated.progress >= updated.duration:
      sim.resolveShipArrival(updated)
    else:
      activeShips.add updated
  sim.ships = move(activeShips)

proc stepGrowth(sim: var SimServer) =
  ## Grows ships on owned planets.
  var changed = false
  for planet in sim.planets.mitems:
    if planet.ownerId == 0:
      continue
    inc planet.growthTicks
    if planet.growthTicks >= planet.growthInterval:
      planet.growthTicks = 0
      if planet.ships < 9999:
        inc planet.ships
        changed = true
  if changed:
    sim.markScoresChanged()

proc stepScore(sim: var SimServer) =
  ## Awards score from owned planet count.
  inc sim.scoreTicks
  if sim.scoreTicks < ScoreIntervalTicks:
    return
  sim.scoreTicks = 0
  for player in sim.players.mitems:
    let ownedCount = sim.countOwnedPlanets(player.id)
    player.score += ownedCount * ownedCount
  sim.markScoresChanged()

proc ensureSelection*(sim: var SimServer, playerIndex: int) =
  ## Repairs one player's cursor and selected planet.
  if playerIndex < 0 or playerIndex >= sim.players.len or sim.planets.len == 0:
    return
  if sim.players[playerIndex].cursorX == 0 and
      sim.players[playerIndex].cursorY == 0:
    let seedIndex =
      if sim.players[playerIndex].selectedPlanet >= 0 and
          sim.players[playerIndex].selectedPlanet < sim.planets.len:
        sim.players[playerIndex].selectedPlanet
      else:
        0
    sim.players[playerIndex].cursorX = sim.planets[seedIndex].x
    sim.players[playerIndex].cursorY = sim.planets[seedIndex].y
  sim.players[playerIndex].selectedPlanet = sim.nearestPlanetIndex(
    sim.players[playerIndex].cursorX,
    sim.players[playerIndex].cursorY
  )
  if sim.players[playerIndex].originPlanet < 0 or
      sim.players[playerIndex].originPlanet >= sim.planets.len:
    sim.players[playerIndex].originPlanet =
      sim.players[playerIndex].selectedPlanet

proc applyInput*(sim: var SimServer, playerIndex: int, input: PlayerInput) =
  ## Applies one player's input to cursor and ship commands.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.ensureSelection(playerIndex)
  if sim.players[playerIndex].sendCooldown > 0:
    dec sim.players[playerIndex].sendCooldown
  var
    inputX = 0
    inputY = 0
  if input.left and not input.right:
    inputX = -1
  elif input.right and not input.left:
    inputX = 1
  elif input.up and not input.down:
    inputY = -1
  elif input.down and not input.up:
    inputY = 1
  if inputX != 0:
    sim.players[playerIndex].cursorVelX = clamp(
      sim.players[playerIndex].cursorVelX + inputX * CursorAccel,
      -CursorMaxSpeed,
      CursorMaxSpeed
    )
  else:
    sim.players[playerIndex].cursorVelX =
      (sim.players[playerIndex].cursorVelX * CursorFrictionNum) div
      CursorFrictionDen
    if abs(sim.players[playerIndex].cursorVelX) < CursorStopThreshold:
      sim.players[playerIndex].cursorVelX = 0
  if inputY != 0:
    sim.players[playerIndex].cursorVelY = clamp(
      sim.players[playerIndex].cursorVelY + inputY * CursorAccel,
      -CursorMaxSpeed,
      CursorMaxSpeed
    )
  else:
    sim.players[playerIndex].cursorVelY =
      (sim.players[playerIndex].cursorVelY * CursorFrictionNum) div
      CursorFrictionDen
    if abs(sim.players[playerIndex].cursorVelY) < CursorStopThreshold:
      sim.players[playerIndex].cursorVelY = 0
  applyCursorMomentumAxis(
    sim.players[playerIndex],
    sim.players[playerIndex].cursorCarryX,
    sim.players[playerIndex].cursorVelX,
    true
  )
  applyCursorMomentumAxis(
    sim.players[playerIndex],
    sim.players[playerIndex].cursorCarryY,
    sim.players[playerIndex].cursorVelY,
    false
  )
  sim.players[playerIndex].selectedPlanet = sim.nearestPlanetIndex(
    sim.players[playerIndex].cursorX,
    sim.players[playerIndex].cursorY
  )
  let selectedIndex = sim.players[playerIndex].selectedPlanet
  if input.attackPressed and selectedIndex >= 0 and
      selectedIndex < sim.planets.len:
    if sim.planets[selectedIndex].ownerId == sim.players[playerIndex].id:
      sim.players[playerIndex].originPlanet = selectedIndex
  if input.sendHeld:
    inc sim.players[playerIndex].sendHoldTicks
    if sim.players[playerIndex].sendCooldown == 0:
      if sim.sendShip(playerIndex):
        sim.players[playerIndex].sendCooldown =
          sendRepeatInterval(sim.players[playerIndex].sendHoldTicks)
  else:
    sim.players[playerIndex].sendHoldTicks = 0

proc step*(sim: var SimServer, inputs: openArray[PlayerInput]) =
  ## Advances one deterministic game tick.
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len:
        inputs[playerIndex]
      else:
        PlayerInput()
    sim.applyInput(playerIndex, input)
  sim.stepGrowth()
  sim.stepShips()
  sim.stepScore()
  inc sim.tickCount

proc initSimServer*(
  seed: int,
  config = defaultSimConfig()
): SimServer =
  ## Creates a fresh simulation server.
  result.config = config
  result.config.planetCount = config.planetCount.checkedPlanetCount()
  result.rng = initRand(seed)
  result.textFont = loadTiny5Font()
  result.chatMessages = @[]
  result.generatePlanets()
  result.generateStars()
  result.markScoresChanged()

proc playerScoresJson*(sim: SimServer): string =
  ## Builds the current per-player score JSON.
  var
    names = newJArray()
    scores = newJArray()
    planets = newJArray()
    ships = newJArray()
    results = newJObject()
  for player in sim.players:
    names.add(%player.name)
    scores.add(%player.score)
    planets.add(%sim.countOwnedPlanets(player.id))
    ships.add(%sim.totalPlayerShips(player.id))
  results["names"] = names
  results["scores"] = scores
  results["planets"] = planets
  results["ships"] = ships
  $results

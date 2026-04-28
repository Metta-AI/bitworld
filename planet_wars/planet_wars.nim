import mummy
import protocol, server
import std/[json, locks, monotimes, os, parseopt, random, strutils, tables, times]

const
  WorldWidthPixels = 192
  WorldHeightPixels = 192
  PlanetCount = 18
  PlanetSpawnMargin = 12
  PlanetSpacing = 10
  ShipSpeedPixels = 2
  BaseSendRepeatInterval = 5
  MinSendRepeatInterval = 1
  SendAccelerationTicks = 12
  ShipLaneOffsetMax = 3
  ScoreIntervalTicks = 24
  TargetFps = 24
  WebSocketPath = "/player"
  MotionScale = 256
  CursorAccel = 76
  CursorFrictionNum = 200
  CursorFrictionDen = 256
  CursorMaxSpeed = 704
  CursorStopThreshold = 12

  BackgroundColor = 12'u8
  NeutralPlanetColor = 1'u8
  FriendlyBorderColor = 11'u8
  EnemyBorderColor = 3'u8
  SelectionColor = 8'u8
  OriginColor = 14'u8
  ScoreColor = 2'u8
  StarColors = [13'u8, 15'u8, 2'u8]
  PlayerColors = [3'u8, 4'u8, 6'u8, 7'u8, 8'u8, 9'u8, 10'u8, 11'u8, 13'u8, 14'u8, 15'u8]

type
  RunConfig = object
    address: string
    port: int
    seed: int

  PlanetSize = enum
    PlanetSmall
    PlanetMedium
    PlanetLarge

  Planet = object
    id: int
    x: int
    y: int
    radius: int
    size: PlanetSize
    ownerId: int
    ships: int
    growthInterval: int
    growthTicks: int

  Ship = object
    ownerId: int
    color: uint8
    targetPlanet: int
    startX: int
    startY: int
    endX: int
    endY: int
    progress: int
    duration: int

  Star = object
    x: int
    y: int
    color: uint8

  Player = object
    id: int
    name: string
    color: uint8
    score: int
    selectedPlanet: int
    originPlanet: int
    sendCooldown: int
    sendHoldTicks: int
    cursorX: int
    cursorY: int
    cursorVelX: int
    cursorVelY: int
    cursorCarryX: int
    cursorCarryY: int

  PlayerInput = object
    up: bool
    down: bool
    left: bool
    right: bool
    attackPressed: bool
    sendHeld: bool

  SimServer = object
    players: seq[Player]
    planets: seq[Planet]
    ships: seq[Ship]
    stars: seq[Star]
    digitSprites: array[10, Sprite]
    fb: Framebuffer
    rng: Rand
    nextPlayerId: int
    scoreTicks: int

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    closedSockets: seq[WebSocket]
    rewardViewers: Table[WebSocket, bool]
    resetRequested: bool

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "clients" / "data"

proc worldClampPixel(x, maxValue: int): int =
  max(0, min(maxValue, x))

proc planetRadius(size: PlanetSize): int =
  case size
  of PlanetSmall: 5
  of PlanetMedium: 6
  of PlanetLarge: 8

proc initialShips(size: PlanetSize, rng: var Rand): int =
  case size
  of PlanetSmall: 4 + rng.rand(3)
  of PlanetMedium: 7 + rng.rand(4)
  of PlanetLarge: 11 + rng.rand(5)

proc growthInterval(size: PlanetSize, rng: var Rand): int =
  case size
  of PlanetSmall: 42 + rng.rand(12)
  of PlanetMedium: 30 + rng.rand(10)
  of PlanetLarge: 20 + rng.rand(8)

proc randomPlayerColor(sim: var SimServer): uint8 =
  var available: seq[uint8] = @[]
  for color in PlayerColors:
    var used = false
    for player in sim.players:
      if player.color == color:
        used = true
        break
    if not used:
      available.add(color)

  if available.len == 0:
    return PlayerColors[sim.rng.rand(PlayerColors.high)]
  available[sim.rng.rand(available.high)]

proc ownerBaseColor(sim: SimServer, ownerId: int): uint8 =
  if ownerId == 0:
    return NeutralPlanetColor
  for player in sim.players:
    if player.id == ownerId:
      return player.color
  NeutralPlanetColor

proc ownerVisibleColor(sim: SimServer, viewerId, ownerId: int): uint8 =
  if ownerId == 0:
    return NeutralPlanetColor
  if ownerId == viewerId:
    return FriendlyBorderColor
  sim.ownerBaseColor(ownerId)

proc planetScreenRect(planet: Planet, cameraX, cameraY: int): tuple[minX, maxX, minY, maxY: int] =
  (
    planet.x - planet.radius - 3 - cameraX,
    planet.x + planet.radius + 3 - cameraX,
    planet.y - planet.radius - 3 - cameraY,
    planet.y + planet.radius + 3 - cameraY
  )

proc isPlanetVisible(planet: Planet, cameraX, cameraY: int): bool =
  let rect = planet.planetScreenRect(cameraX, cameraY)
  rect.maxX >= 0 and rect.minX < ScreenWidth and rect.maxY >= 0 and rect.minY < ScreenHeight

proc blitSolidSprite(
  fb: var Framebuffer,
  sprite: Sprite,
  screenX, screenY: int,
  color: uint8
) =
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      if sprite.pixels[sprite.spriteIndex(x, y)] != TransparentColorIndex:
        fb.putPixel(screenX + x, screenY + y, color)

proc renderNumber(
  fb: var Framebuffer,
  digitSprites: array[10, Sprite],
  value, screenX, screenY: int,
  color: uint8
): int =
  let text = $max(0, value)
  var x = screenX
  for ch in text:
    let digit = ord(ch) - ord('0')
    fb.blitSolidSprite(digitSprites[digit], x, screenY, color)
    x += digitSprites[digit].width
  x - screenX

proc renderCenteredNumber(
  fb: var Framebuffer,
  digitSprites: array[10, Sprite],
  value, centerX, centerY: int,
  color: uint8
) =
  let text = $max(0, value)
  let width = text.len * digitSprites[0].width
  discard fb.renderNumber(digitSprites, value, centerX - width div 2, centerY - digitSprites[0].height div 2, color)

proc drawHSpan(fb: var Framebuffer, x0, x1, y: int, color: uint8) =
  let
    startX = min(x0, x1)
    endX = max(x0, x1)
  for x in startX .. endX:
    fb.putPixel(x, y, color)

proc plotCircleOctants(fb: var Framebuffer, cx, cy, x, y: int, color: uint8) =
  fb.putPixel(cx + x, cy + y, color)
  fb.putPixel(cx - x, cy + y, color)
  fb.putPixel(cx + x, cy - y, color)
  fb.putPixel(cx - x, cy - y, color)
  fb.putPixel(cx + y, cy + x, color)
  fb.putPixel(cx - y, cy + x, color)
  fb.putPixel(cx + y, cy - x, color)
  fb.putPixel(cx - y, cy - x, color)

proc drawCircleFill(fb: var Framebuffer, cx, cy, radius: int, color: uint8) =
  var
    x = radius
    y = 0
    decision = 1 - radius
  while x >= y:
    fb.drawHSpan(cx - x, cx + x, cy + y, color)
    fb.drawHSpan(cx - x, cx + x, cy - y, color)
    fb.drawHSpan(cx - y, cx + y, cy + x, color)
    fb.drawHSpan(cx - y, cx + y, cy - x, color)
    inc y
    if decision < 0:
      decision += 2 * y + 1
    else:
      dec x
      decision += 2 * (y - x) + 1

proc drawCircleRing(fb: var Framebuffer, cx, cy, radius, thickness: int, color: uint8) =
  for ringRadius in countdown(radius, max(0, radius - thickness + 1)):
    var
      x = ringRadius
      y = 0
      decision = 1 - ringRadius
    while x >= y:
      fb.plotCircleOctants(cx, cy, x, y, color)
      inc y
      if decision < 0:
        decision += 2 * y + 1
      else:
        dec x
        decision += 2 * (y - x) + 1

proc drawShipTriangle(fb: var Framebuffer, x, y, dx, dy: int, color: uint8) =
  if abs(dx) >= abs(dy):
    if dx >= 0:
      fb.putPixel(x + 2, y, ScoreColor)
      fb.putPixel(x + 1, y, color)
      fb.putPixel(x, y - 1, color)
      fb.putPixel(x, y, color)
      fb.putPixel(x, y + 1, color)
    else:
      fb.putPixel(x - 2, y, ScoreColor)
      fb.putPixel(x - 1, y, color)
      fb.putPixel(x, y - 1, color)
      fb.putPixel(x, y, color)
      fb.putPixel(x, y + 1, color)
  else:
    if dy >= 0:
      fb.putPixel(x, y + 2, ScoreColor)
      fb.putPixel(x, y + 1, color)
      fb.putPixel(x - 1, y, color)
      fb.putPixel(x, y, color)
      fb.putPixel(x + 1, y, color)
    else:
      fb.putPixel(x, y - 2, ScoreColor)
      fb.putPixel(x, y - 1, color)
      fb.putPixel(x - 1, y, color)
      fb.putPixel(x, y, color)
      fb.putPixel(x + 1, y, color)

proc randomPlanetSize(rng: var Rand): PlanetSize =
  case rng.rand(99)
  of 0 .. 44: PlanetSmall
  of 45 .. 79: PlanetMedium
  else: PlanetLarge

proc planetsOverlap(a, b: Planet): bool =
  let
    dx = a.x - b.x
    dy = a.y - b.y
    minDistance = a.radius + b.radius + PlanetSpacing
  dx * dx + dy * dy < minDistance * minDistance

proc generatePlanets(sim: var SimServer) =
  var attempts = 0
  while sim.planets.len < PlanetCount and attempts < 800:
    inc attempts
    let size = randomPlanetSize(sim.rng)
    let radius = planetRadius(size)
    let planet = Planet(
      id: sim.planets.len + 1,
      x: PlanetSpawnMargin + radius + sim.rng.rand(WorldWidthPixels - (PlanetSpawnMargin + radius) * 2),
      y: PlanetSpawnMargin + radius + sim.rng.rand(WorldHeightPixels - (PlanetSpawnMargin + radius) * 2),
      radius: radius,
      size: size,
      ownerId: 0,
      ships: initialShips(size, sim.rng),
      growthInterval: growthInterval(size, sim.rng)
    )
    var blocked = false
    for existing in sim.planets:
      if planet.planetsOverlap(existing):
        blocked = true
        break
    if not blocked:
      sim.planets.add planet

proc generateStars(sim: var SimServer) =
  for _ in 0 ..< 120:
    sim.stars.add Star(
      x: sim.rng.rand(WorldWidthPixels - 1),
      y: sim.rng.rand(WorldHeightPixels - 1),
      color: StarColors[sim.rng.rand(StarColors.high)]
    )

proc initSimServer(seed: int): SimServer =
  result.rng = initRand(seed)
  result.fb = initFramebuffer()
  loadPalette(clientDataDir() / "pallete.png")
  result.digitSprites = loadDigitSprites(clientDataDir() / "numbers.png")
  result.generatePlanets()
  result.generateStars()

proc findPlanetIndexById(sim: SimServer, planetId: int): int =
  for i, planet in sim.planets:
    if planet.id == planetId:
      return i
  -1

proc claimPlanetForPlayer(sim: var SimServer, playerId: int): int =
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
  claimedIndex

proc addPlayer(sim: var SimServer, name: string): int =
  inc sim.nextPlayerId
  let playerId = sim.nextPlayerId
  let claimedPlanet = sim.claimPlanetForPlayer(playerId)
  sim.players.add Player(
    id: playerId,
    name: name,
    color: sim.randomPlayerColor(),
    selectedPlanet: claimedPlanet,
    originPlanet: claimedPlanet
  )
  sim.players.high

proc removePlayerById(sim: var SimServer, playerId: int) =
  for planet in sim.planets.mitems:
    if planet.ownerId == playerId:
      planet.ownerId = 0
  var remainingShips: seq[Ship] = @[]
  for ship in sim.ships:
    if ship.ownerId != playerId:
      remainingShips.add ship
  sim.ships = move(remainingShips)

proc nearestPlanetIndex(sim: SimServer, worldX, worldY: int): int =
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

proc countOwnedPlanets(sim: SimServer, playerId: int): int =
  for planet in sim.planets:
    if planet.ownerId == playerId:
      inc result

proc applyCursorMomentumAxis(
  player: var Player,
  carry: var int,
  velocity: int,
  horizontal: bool
) =
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

proc shipDuration(startX, startY, endX, endY: int): int =
  let
    dx = abs(endX - startX)
    dy = abs(endY - startY)
    travel = max(dx, dy)
  max(1, (travel + ShipSpeedPixels - 1) div ShipSpeedPixels)

proc sendRepeatInterval(holdTicks: int): int =
  max(MinSendRepeatInterval, BaseSendRepeatInterval - holdTicks div SendAccelerationTicks)

proc randomShipLaneOffset(
  sim: var SimServer,
  originPlanet, targetPlanet: Planet
): tuple[x, y: int] =
  let laneRadius = min(ShipLaneOffsetMax, max(0, min(originPlanet.radius, targetPlanet.radius) - 2))
  if laneRadius <= 0:
    return (0, 0)

  for _ in 0 ..< 16:
    let
      dx = sim.rng.rand(laneRadius * 2) - laneRadius
      dy = sim.rng.rand(laneRadius * 2) - laneRadius
    if (dx != 0 or dy != 0) and dx * dx + dy * dy <= laneRadius * laneRadius:
      return (dx, dy)

  (laneRadius, 0)

proc currentShipPosition(ship: Ship): tuple[x: int, y: int] =
  if ship.duration <= 0:
    return (ship.endX, ship.endY)
  (
    ship.startX + ((ship.endX - ship.startX) * ship.progress) div ship.duration,
    ship.startY + ((ship.endY - ship.startY) * ship.progress) div ship.duration
  )

proc sendShip(sim: var SimServer, playerIndex: int): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let
    originIndex = sim.players[playerIndex].originPlanet
    targetIndex = sim.players[playerIndex].selectedPlanet
  if originIndex < 0 or originIndex >= sim.planets.len or targetIndex < 0 or targetIndex >= sim.planets.len:
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
  dec sim.planets[originIndex].ships
  let
    startX = originPlanet.x + laneOffset.x
    startY = originPlanet.y + laneOffset.y
    endX = targetPlanet.x + laneOffset.x
    endY = targetPlanet.y + laneOffset.y
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
  true

proc resolveShipArrival(sim: var SimServer, ship: Ship) =
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

proc stepShips(sim: var SimServer) =
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
  for planet in sim.planets.mitems:
    if planet.ownerId == 0:
      continue
    inc planet.growthTicks
    if planet.growthTicks >= planet.growthInterval:
      planet.growthTicks = 0
      if planet.ships < 9999:
        inc planet.ships

proc stepScore(sim: var SimServer) =
  inc sim.scoreTicks
  if sim.scoreTicks < ScoreIntervalTicks:
    return
  sim.scoreTicks = 0
  for player in sim.players.mitems:
    let ownedCount = sim.countOwnedPlanets(player.id)
    player.score += ownedCount * ownedCount

proc ensureSelection(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len or sim.planets.len == 0:
    return
  if sim.players[playerIndex].cursorX == 0 and sim.players[playerIndex].cursorY == 0:
    let seedIndex =
      if sim.players[playerIndex].selectedPlanet >= 0 and sim.players[playerIndex].selectedPlanet < sim.planets.len:
        sim.players[playerIndex].selectedPlanet
      else:
        0
    sim.players[playerIndex].cursorX = sim.planets[seedIndex].x
    sim.players[playerIndex].cursorY = sim.planets[seedIndex].y
  if sim.players[playerIndex].selectedPlanet < 0 or sim.players[playerIndex].selectedPlanet >= sim.planets.len:
    sim.players[playerIndex].selectedPlanet = sim.nearestPlanetIndex(
      sim.players[playerIndex].cursorX,
      sim.players[playerIndex].cursorY
    )
  else:
    sim.players[playerIndex].selectedPlanet = sim.nearestPlanetIndex(
      sim.players[playerIndex].cursorX,
      sim.players[playerIndex].cursorY
    )
  if sim.players[playerIndex].originPlanet < 0 or sim.players[playerIndex].originPlanet >= sim.planets.len:
    sim.players[playerIndex].originPlanet = sim.players[playerIndex].selectedPlanet

proc applyInput(sim: var SimServer, playerIndex: int, input: PlayerInput) =
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
      (sim.players[playerIndex].cursorVelX * CursorFrictionNum) div CursorFrictionDen
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
      (sim.players[playerIndex].cursorVelY * CursorFrictionNum) div CursorFrictionDen
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
  if input.attackPressed and selectedIndex >= 0 and selectedIndex < sim.planets.len:
    if sim.planets[selectedIndex].ownerId == sim.players[playerIndex].id:
      sim.players[playerIndex].originPlanet = selectedIndex

  if input.sendHeld:
    inc sim.players[playerIndex].sendHoldTicks
    if sim.players[playerIndex].sendCooldown == 0:
      if sim.sendShip(playerIndex):
        sim.players[playerIndex].sendCooldown = sendRepeatInterval(sim.players[playerIndex].sendHoldTicks)
  else:
    sim.players[playerIndex].sendHoldTicks = 0

proc drawPlanet(
  sim: var SimServer,
  viewer: Player,
  planet: Planet,
  cameraX, cameraY: int,
  selected, origin: bool
) =
  let
    screenX = planet.x - cameraX
    screenY = planet.y - cameraY
    fillColor =
      if planet.ownerId == 0: NeutralPlanetColor
      else: sim.ownerVisibleColor(viewer.id, planet.ownerId)
    borderColor =
      if planet.ownerId == 0: NeutralPlanetColor
      elif planet.ownerId == viewer.id: FriendlyBorderColor
      else: EnemyBorderColor

  sim.fb.drawCircleFill(screenX, screenY, planet.radius + 1, fillColor)
  sim.fb.drawCircleRing(screenX, screenY, planet.radius + 1, 1, borderColor)
  if origin:
    sim.fb.drawCircleRing(screenX, screenY, planet.radius + 2, 1, OriginColor)
  if selected:
    sim.fb.drawCircleRing(screenX, screenY, planet.radius + 4, 1, SelectionColor)
  sim.fb.renderCenteredNumber(sim.digitSprites, planet.ships, screenX, screenY, ScoreColor)

proc renderBackground(sim: var SimServer, cameraX, cameraY: int) =
  for star in sim.stars:
    sim.fb.putPixel(star.x - cameraX, star.y - cameraY, star.color)

proc renderShips(sim: var SimServer, viewer: Player, cameraX, cameraY: int) =
  for ship in sim.ships:
    let
      pos = currentShipPosition(ship)
      screenX = pos.x - cameraX
      screenY = pos.y - cameraY
      shipColor = sim.ownerVisibleColor(viewer.id, ship.ownerId)
    sim.fb.drawShipTriangle(screenX, screenY, ship.endX - ship.startX, ship.endY - ship.startY, shipColor)

proc renderHud(sim: var SimServer, player: Player) =
  discard sim.fb.renderNumber(sim.digitSprites, player.score, 0, 0, ScoreColor)

proc cameraForPlayer(sim: SimServer, player: Player): tuple[x: int, y: int] =
  (
    worldClampPixel(player.cursorX - ScreenWidth div 2, WorldWidthPixels - ScreenWidth),
    worldClampPixel(player.cursorY - ScreenHeight div 2, WorldHeightPixels - ScreenHeight)
  )

proc render(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(BackgroundColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return sim.fb.packed

  sim.ensureSelection(playerIndex)
  let
    player = sim.players[playerIndex]
    camera = sim.cameraForPlayer(player)

  sim.renderBackground(camera.x, camera.y)
  for i, planet in sim.planets:
    if planet.isPlanetVisible(camera.x, camera.y):
      sim.drawPlanet(
        player,
        planet,
        camera.x,
        camera.y,
        selected = i == player.selectedPlanet,
        origin = i == player.originPlanet
      )
  sim.renderShips(player, camera.x, camera.y)
  sim.renderHud(player)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildRewardPacket(sim: SimServer): string =
  for player in sim.players:
    result.add("reward ")
    result.add(player.name)
    result.add(" ")
    result.add($player.score)
    result.add("\n")

proc step(sim: var SimServer, inputs: openArray[PlayerInput]) =
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: PlayerInput()
    sim.applyInput(playerIndex, input)
  sim.stepGrowth()
  sim.stepShips()
  sim.stepScore()

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerNames = initTable[WebSocket, string]()
  appState.closedSockets = @[]
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.resetRequested = false

proc playerInputFromMasks(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.up = decoded.up
  result.down = decoded.down
  result.left = decoded.left
  result.right = decoded.right
  result.attackPressed = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
  result.sendHeld = decoded.b

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.playerNames.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    let removedPlayerId = sim.players[removedIndex].id
    sim.removePlayerById(removedPlayerId)
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerIdentity(request: Request): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  let parts = request.remoteAddress.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  request.remoteAddress

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerNames[websocket] = request.playerIdentity()
  elif request.path == "/reward" and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.rewardViewers[websocket] = true
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "BitWorld WebSocket server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.rewardViewers:
          appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage and isInputPacket(message.data):
      {.gcsafe.}:
        withLock appState.lock:
          let mask = blobToMask(message.data)
          if mask == 255'u8:
            appState.resetRequested = true
            appState.inputMasks[websocket] = 0
            appState.lastAppliedMasks[websocket] = 0
          else:
            appState.inputMasks[websocket] = mask
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop(
  host = DefaultHost,
  port = DefaultPort,
  seed = 0x1A7E7
) =
  initAppState()

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    tcpNoDelay = true
  )

  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc, ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    currentSeed = seed
    sim = initSimServer(currentSeed)
    lastTick = getMonoTime()

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[PlayerInput]
      shouldReset = false
      rewardViewers: seq[WebSocket] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        if appState.resetRequested:
          shouldReset = true
          appState.resetRequested = false
          for _, value in appState.playerIndices.mpairs:
            value = 0x7fffffff
          for _, value in appState.inputMasks.mpairs:
            value = 0
          for _, value in appState.lastAppliedMasks.mpairs:
            value = 0
        else:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              let name = appState.playerNames.getOrDefault(websocket, "unknown")
              appState.playerIndices[websocket] = sim.addPlayer(name)

          inputs = newSeq[PlayerInput](sim.players.len)
          for websocket, playerIndex in appState.playerIndices.pairs:
            if playerIndex < 0 or playerIndex >= inputs.len:
              continue
            let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
            inputs[playerIndex] = playerInputFromMasks(currentMask, previousMask)
            appState.lastAppliedMasks[websocket] = currentMask
            sockets.add(websocket)
            playerIndices.add(playerIndex)

        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)

    if shouldReset:
      inc currentSeed
      sim = initSimServer(currentSeed)
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              let name = appState.playerNames.getOrDefault(websocket, "unknown")
              appState.playerIndices[websocket] = sim.addPlayer(name)
            sockets.add(websocket)
            playerIndices.add(appState.playerIndices[websocket])
      for i in 0 ..< sockets.len:
        let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
        sockets[i].send(frameBlob, BinaryMessage)
      let rewardPacket = sim.buildRewardPacket()
      for websocket in rewardViewers:
        websocket.send(rewardPacket, TextMessage)
      runFrameLimiter(lastTick)
      continue

    sim.step(inputs)

    for i in 0 ..< sockets.len:
      let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    let rewardPacket = sim.buildRewardPacket()
    for websocket in rewardViewers:
      websocket.send(rewardPacket, TextMessage)

    runFrameLimiter(lastTick)

proc readConfigString(node: JsonNode, name: string, value: var string) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(ValueError, "Config field " & name & " must be a string.")
  value = item.getStr()

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(ValueError, "Config field " & name & " must be an integer.")
  value = item.getInt()

proc update(config: var RunConfig, jsonText: string) =
  if jsonText.len == 0:
    return
  let node = parseJson(jsonText)
  if node.kind != JObject:
    raise newException(ValueError, "Config must be a JSON object.")
  node.readConfigString("address", config.address)
  node.readConfigInt("port", config.port)
  node.readConfigInt("seed", config.seed)

when isMainModule:
  var
    config = RunConfig(address: DefaultHost, port: DefaultPort, seed: 0x1A7E7)
    configJson = ""
    configPath = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": config.address = val
      of "port": config.port = parseInt(val)
      of "config": configJson = val
      of "config-file": configPath = val
      else: discard
    else: discard
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  runServerLoop(config.address, config.port, seed = config.seed)

import mummy
import protocol, server
import std/[locks, monotimes, os, parseopt, random, strutils, tables, times]

const
  WorldWidthTiles = 32
  WorldHeightTiles = 32
  WorldWidthPixels = WorldWidthTiles * TileSize
  WorldHeightPixels = WorldHeightTiles * TileSize

  VisibleTilesX = (ScreenWidth + TileSize - 1) div TileSize
  VisibleTilesY = (ScreenHeight + TileSize - 1) div TileSize

  PlayerMoveCooldownTicks = 5
  PreyThinkIntervalTicks = 10

  PreyFleeRadius = 3
  PreyFleeProb1 = 75
  PreyFleeProb2 = 50
  PreyFleeProb3 = 25
  PreyWanderProb = 30

  MaxEnergy = 200
  StartEnergy = 120
  MoveEnergyCost = 2
  PassiveRechargeInterval = 18

  CatchFlashTicks = 8
  AlertFlashTicks = 6

  RabbitEnergyReward = 25
  RabbitScoreReward = 1
  BoarEnergyReward = 60
  BoarScoreReward = 3
  StagEnergyReward = 90
  StagScoreReward = 5
  MooseEnergyReward = 140
  MooseScoreReward = 10
  MammothEnergyReward = 220
  MammothScoreReward = 18

  # Prey only appear once enough players are connected to catch them.
  # Per-kind target populations; values for kinds that need more players
  # than are currently connected are simply skipped.
  TargetRabbits = 12
  TargetBoars = 6
  TargetStags = 6
  TargetMooses = 3
  TargetMammoths = 2

  RespawnIntervalTicks = 60
  CatchupSpawnCooldown = 3

  ObstacleDensityPerMille = 110

  TargetFps = 24.0
  WebSocketPath = "/player"
  BackgroundColor = 10'u8

type
  PreyKind = enum
    Rabbit
    Boar
    Stag
    Moose
    Mammoth

  TileKind = enum
    TileEmpty
    TileTree
    TileRock

  Player = object
    id: int
    tileX: int
    tileY: int
    facing: Facing
    energy: int
    score: int
    moveCooldown: int
    catchFlash: int
    rechargeCounter: int
    colorIndex: int

  Prey = object
    id: int
    kind: PreyKind
    tileX: int
    tileY: int
    thinkCooldown: int
    alertFlash: int

  SimServer = object
    players: seq[Player]
    prey: seq[Prey]
    tiles: seq[TileKind]
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]
    fb: Framebuffer
    rng: Rand
    nextPlayerId: int
    nextPreyId: int
    tickCount: int
    respawnCooldown: int

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    closedSockets: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

var appState: WebSocketAppState

proc repoDir(): string = getCurrentDir() / ".."
proc clientDataDir(): string = repoDir() / "client" / "data"
proc palettePath(): string = clientDataDir() / "pallete.png"
proc numbersPath(): string = clientDataDir() / "numbers.png"
proc lettersPath(): string = clientDataDir() / "letters.png"

proc tileIndex(tx, ty: int): int = ty * WorldWidthTiles + tx

proc inTileBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc tileIsBlocked(sim: SimServer, tx, ty: int): bool =
  if not inTileBounds(tx, ty):
    return true
  sim.tiles[tileIndex(tx, ty)] != TileEmpty

proc playerAt(sim: SimServer, tx, ty: int, exceptIndex: int = -1): int =
  for i, p in sim.players:
    if i == exceptIndex:
      continue
    if p.tileX == tx and p.tileY == ty:
      return i
  -1

proc preyAt(sim: SimServer, tx, ty: int, exceptIndex: int = -1): int =
  for i, p in sim.prey:
    if i == exceptIndex:
      continue
    if p.tileX == tx and p.tileY == ty:
      return i
  -1

proc canOccupy(
  sim: SimServer,
  tx, ty: int,
  exceptPlayerIndex: int = -1,
  exceptPreyIndex: int = -1
): bool =
  if tileIsBlocked(sim, tx, ty):
    return false
  if playerAt(sim, tx, ty, exceptPlayerIndex) >= 0:
    return false
  if preyAt(sim, tx, ty, exceptPreyIndex) >= 0:
    return false
  true

proc chebyshevDistance(ax, ay, bx, by: int): int =
  max(abs(ax - bx), abs(ay - by))

proc signOf(v: int): int =
  if v < 0: -1
  elif v > 0: 1
  else: 0

proc parsePatternChar(c: char, playerBody, playerAccent: uint8): uint8 =
  case c
  of '.':
    TransparentColorIndex
  of 'P':
    playerBody
  of 'Q':
    playerAccent
  of '0' .. '9':
    uint8(ord(c) - ord('0'))
  of 'a' .. 'f':
    uint8(ord(c) - ord('a') + 10)
  else:
    TransparentColorIndex

proc drawPattern(
  fb: var Framebuffer,
  pattern: openArray[string],
  baseX, baseY: int,
  playerBody: uint8 = 0,
  playerAccent: uint8 = 0,
  facing: Facing = FaceDown
) =
  let h = pattern.len
  if h == 0:
    return
  let w = pattern[0].len
  for y in 0 ..< h:
    for x in 0 ..< w:
      let color = parsePatternChar(pattern[y][x], playerBody, playerAccent)
      if color == TransparentColorIndex:
        continue
      var dx = x
      var dy = y
      case facing
      of FaceDown:
        discard
      of FaceUp:
        dx = w - 1 - x
        dy = h - 1 - y
      of FaceLeft:
        dx = y
        dy = w - 1 - x
      of FaceRight:
        dx = h - 1 - y
        dy = x
      fb.putPixel(baseX + dx, baseY + dy, color)

# ---------------------------------------------------------------------------
# Sprite patterns.
# '.' transparent; 0-9 a-f are palette indices; P/Q = player body/accent.
# Palette (DB16): 0 black, 1 gray, 2 white, 3 red, 4 pink, 5 dk-brown,
# 6 tan, 7 orange, 8 yellow, 9 dk-teal, a dk-green, b green, c navy,
# d dk-blue, e blue, f lt-blue.
# ---------------------------------------------------------------------------

const
  PlayerPattern = [
    "..PP..",
    ".PPPP.",
    ".PQQP.",
    "PPPPPP",
    ".PPPP.",
    ".P..P.",
  ]

  RabbitPattern = [
    ".2..2.",
    ".2..2.",
    ".4224.",
    "222222",
    ".2002.",
    ".2..2.",
  ]

  BoarPattern = [
    "......",
    ".6555.",
    "655552",
    "555555",
    ".5..5.",
    ".5..5.",
  ]

  StagPattern = [
    "5.55.5",
    ".5..5.",
    ".6666.",
    ".6006.",
    "666666",
    ".6..6.",
  ]

  MoosePattern = [
    "5.55.5",
    "5.55.5",
    "555555",
    "500005",
    "555555",
    ".5..5.",
  ]

  MammothPattern = [
    ".1111.",
    "111111",
    "111111",
    "122221",
    "112211",
    ".1..1.",
  ]

  TreePattern = [
    "..bb..",
    ".bbbb.",
    "bbbbbb",
    ".abba.",
    "..55..",
    "..55..",
  ]

  RockPattern = [
    "..11..",
    ".1111.",
    "111991",
    "111111",
    ".1111.",
    "..00..",
  ]

proc drawPreyPattern(
  fb: var Framebuffer,
  kind: PreyKind,
  baseX, baseY: int
) =
  case kind
  of Rabbit: fb.drawPattern(RabbitPattern, baseX, baseY)
  of Boar: fb.drawPattern(BoarPattern, baseX, baseY)
  of Stag: fb.drawPattern(StagPattern, baseX, baseY)
  of Moose: fb.drawPattern(MoosePattern, baseX, baseY)
  of Mammoth: fb.drawPattern(MammothPattern, baseX, baseY)

# ---------------------------------------------------------------------------
# World generation
# ---------------------------------------------------------------------------

proc clearSpawnArea(sim: var SimServer, cx, cy, radius: int) =
  for ty in cy - radius .. cy + radius:
    for tx in cx - radius .. cx + radius:
      if inTileBounds(tx, ty):
        sim.tiles[tileIndex(tx, ty)] = TileEmpty

proc generateWorld(sim: var SimServer) =
  sim.tiles = newSeq[TileKind](WorldWidthTiles * WorldHeightTiles)
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      if tx == 0 or ty == 0 or tx == WorldWidthTiles - 1 or ty == WorldHeightTiles - 1:
        sim.tiles[tileIndex(tx, ty)] = TileRock
        continue
      if sim.rng.rand(999) < ObstacleDensityPerMille:
        if sim.rng.rand(1) == 0:
          sim.tiles[tileIndex(tx, ty)] = TileTree
        else:
          sim.tiles[tileIndex(tx, ty)] = TileRock

  let cx = WorldWidthTiles div 2
  let cy = WorldHeightTiles div 2
  sim.clearSpawnArea(cx, cy, 3)

  for _ in 0 ..< 6:
    let
      bx = 4 + sim.rng.rand(WorldWidthTiles - 8)
      by = 4 + sim.rng.rand(WorldHeightTiles - 8)
    sim.clearSpawnArea(bx, by, 1)

proc findOpenTileNear(
  sim: var SimServer,
  nearX, nearY, radius: int
): tuple[tx, ty: int, ok: bool] =
  for _ in 0 ..< 96:
    let
      dx = sim.rng.rand(radius * 2 + 1) - radius
      dy = sim.rng.rand(radius * 2 + 1) - radius
      tx = nearX + dx
      ty = nearY + dy
    if sim.canOccupy(tx, ty):
      return (tx, ty, true)
  (0, 0, false)

proc addPlayer(sim: var SimServer): int =
  let
    cx = WorldWidthTiles div 2
    cy = WorldHeightTiles div 2
    spawn = sim.findOpenTileNear(cx, cy, 4)
    (tx, ty) = if spawn.ok: (spawn.tx, spawn.ty) else: (cx, cy)

  sim.players.add Player(
    id: sim.nextPlayerId,
    tileX: tx,
    tileY: ty,
    facing: FaceDown,
    energy: StartEnergy,
    colorIndex: sim.nextPlayerId mod 8
  )
  inc sim.nextPlayerId
  sim.players.high

proc addPrey(sim: var SimServer, kind: PreyKind) =
  let
    cx = 1 + sim.rng.rand(WorldWidthTiles - 3)
    cy = 1 + sim.rng.rand(WorldHeightTiles - 3)
    spot = sim.findOpenTileNear(cx, cy, 10)
  if not spot.ok:
    return
  sim.prey.add Prey(
    id: sim.nextPreyId,
    kind: kind,
    tileX: spot.tx,
    tileY: spot.ty,
    thinkCooldown: sim.rng.rand(PreyThinkIntervalTicks)
  )
  inc sim.nextPreyId

proc countKind(sim: SimServer, kind: PreyKind): int =
  for p in sim.prey:
    if p.kind == kind:
      inc result

proc preyMinPlayers(kind: PreyKind): int =
  case kind
  of Rabbit: 1
  of Boar: 2
  of Stag: 2
  of Moose: 3
  of Mammoth: 4

proc preyCatchable(kind: PreyKind, playerCount: int): bool =
  preyMinPlayers(kind) <= playerCount

proc targetFor(kind: PreyKind): int =
  case kind
  of Rabbit: TargetRabbits
  of Boar: TargetBoars
  of Stag: TargetStags
  of Moose: TargetMooses
  of Mammoth: TargetMammoths

proc catchableTargetTotal(playerCount: int): int =
  for kind in PreyKind:
    if preyCatchable(kind, playerCount):
      result += targetFor(kind)

proc cullUncatchablePrey(sim: var SimServer) =
  let playerCount = sim.players.len
  var kept: seq[Prey] = @[]
  for p in sim.prey:
    if preyCatchable(p.kind, playerCount):
      kept.add(p)
  sim.prey = kept

proc maintainPrey(sim: var SimServer) =
  let playerCount = sim.players.len
  if playerCount == 0:
    return

  sim.cullUncatchablePrey()

  dec sim.respawnCooldown
  if sim.respawnCooldown > 0:
    return

  var spawnedKind = PreyKind.low
  var spawned = false
  for kind in PreyKind:
    if preyCatchable(kind, playerCount) and sim.countKind(kind) < targetFor(kind):
      sim.addPrey(kind)
      spawnedKind = kind
      spawned = true
      break

  if not spawned:
    sim.respawnCooldown = RespawnIntervalTicks
    return

  # Catch up quickly when we're well below the target population.
  let
    target = catchableTargetTotal(playerCount)
    have = sim.prey.len
  if target - have >= 4:
    sim.respawnCooldown = CatchupSpawnCooldown
  else:
    sim.respawnCooldown = RespawnIntervalTicks

proc initSim(): SimServer =
  result.rng = initRand(0x57A617)
  result.fb = initFramebuffer()
  loadPalette(palettePath())
  result.digitSprites = loadDigitSprites(numbersPath())
  result.letterSprites = loadLetterSprites(lettersPath())
  result.generateWorld()
  result.respawnCooldown = RespawnIntervalTicks

  # No initial spawn; maintainPrey populates once players connect so we
  # never spawn prey no one can catch.

# ---------------------------------------------------------------------------
# Player input / movement
# ---------------------------------------------------------------------------

proc applyPlayerInput(sim: var SimServer, playerIndex: int, input: InputState) =
  template p: untyped = sim.players[playerIndex]

  inc p.rechargeCounter
  if p.rechargeCounter >= PassiveRechargeInterval:
    p.rechargeCounter = 0
    if p.energy < MaxEnergy:
      inc p.energy

  if p.catchFlash > 0:
    dec p.catchFlash

  if p.moveCooldown > 0:
    dec p.moveCooldown
    return

  var dx = 0
  var dy = 0
  if input.up: dy = -1
  elif input.down: dy = 1
  elif input.left: dx = -1
  elif input.right: dx = 1

  if dx == 0 and dy == 0:
    return

  if dx > 0: p.facing = FaceRight
  elif dx < 0: p.facing = FaceLeft
  elif dy > 0: p.facing = FaceDown
  elif dy < 0: p.facing = FaceUp

  if p.energy < MoveEnergyCost:
    return

  let nx = p.tileX + dx
  let ny = p.tileY + dy
  if sim.canOccupy(nx, ny, exceptPlayerIndex = playerIndex):
    p.tileX = nx
    p.tileY = ny
    p.energy -= MoveEnergyCost
    p.moveCooldown = PlayerMoveCooldownTicks

# ---------------------------------------------------------------------------
# Prey AI
# ---------------------------------------------------------------------------

proc tryPreyMove(sim: var SimServer, preyIndex, dx, dy: int): bool =
  template p: untyped = sim.prey[preyIndex]
  let nx = p.tileX + dx
  let ny = p.tileY + dy
  if sim.canOccupy(nx, ny, exceptPreyIndex = preyIndex):
    p.tileX = nx
    p.tileY = ny
    return true
  false

proc thinkPrey(sim: var SimServer, preyIndex: int) =
  template p: untyped = sim.prey[preyIndex]

  if p.alertFlash > 0:
    dec p.alertFlash

  if p.thinkCooldown > 0:
    dec p.thinkCooldown
    return
  p.thinkCooldown = PreyThinkIntervalTicks

  var nearestDist = high(int)
  var nearestX = 0
  var nearestY = 0
  for pl in sim.players:
    let d = chebyshevDistance(p.tileX, p.tileY, pl.tileX, pl.tileY)
    if d < nearestDist:
      nearestDist = d
      nearestX = pl.tileX
      nearestY = pl.tileY

  let alerted = nearestDist > 0 and nearestDist <= PreyFleeRadius

  if alerted:
    p.alertFlash = AlertFlashTicks
    let fleeProb =
      case nearestDist
      of 1: PreyFleeProb1
      of 2: PreyFleeProb2
      else: PreyFleeProb3
    if sim.rng.rand(99) < fleeProb:
      let dx = signOf(p.tileX - nearestX)
      let dy = signOf(p.tileY - nearestY)
      if dx != 0 or dy != 0:
        if sim.tryPreyMove(preyIndex, dx, dy):
          return
        if dx != 0 and sim.tryPreyMove(preyIndex, dx, 0):
          return
        if dy != 0 and sim.tryPreyMove(preyIndex, 0, dy):
          return
        # perpendicular fallback
        if dx != 0 and sim.tryPreyMove(preyIndex, 0, 1):
          return
        if dx != 0 and sim.tryPreyMove(preyIndex, 0, -1):
          return
        if dy != 0 and sim.tryPreyMove(preyIndex, 1, 0):
          return
        if dy != 0 and sim.tryPreyMove(preyIndex, -1, 0):
          return
    return

  if sim.rng.rand(99) < PreyWanderProb:
    let dx = sim.rng.rand(2) - 1
    let dy = sim.rng.rand(2) - 1
    if dx == 0 and dy == 0:
      return
    discard sim.tryPreyMove(preyIndex, dx, dy)

# ---------------------------------------------------------------------------
# Capture detection
# ---------------------------------------------------------------------------

type
  PlayerSides = object
    n, s, e, w: int

proc sidesAround(sim: SimServer, prey: Prey): PlayerSides =
  result = PlayerSides(n: -1, s: -1, e: -1, w: -1)
  for i, pl in sim.players:
    if pl.tileX == prey.tileX and pl.tileY == prey.tileY - 1:
      result.n = i
    elif pl.tileX == prey.tileX and pl.tileY == prey.tileY + 1:
      result.s = i
    elif pl.tileX == prey.tileX - 1 and pl.tileY == prey.tileY:
      result.w = i
    elif pl.tileX == prey.tileX + 1 and pl.tileY == prey.tileY:
      result.e = i

proc sideCount(sides: PlayerSides): int =
  (if sides.n >= 0: 1 else: 0) +
    (if sides.s >= 0: 1 else: 0) +
    (if sides.e >= 0: 1 else: 0) +
    (if sides.w >= 0: 1 else: 0)

proc isCaptured(sides: PlayerSides, kind: PreyKind): bool =
  let
    n = sides.n >= 0
    s = sides.s >= 0
    e = sides.e >= 0
    w = sides.w >= 0
  case kind
  of Rabbit:
    n or s or e or w
  of Boar:
    (n and e) or (n and w) or (s and e) or (s and w)
  of Stag:
    (n and s) or (e and w)
  of Moose:
    sides.sideCount >= 3
  of Mammoth:
    n and s and e and w

proc rewardsFor(kind: PreyKind): tuple[energy, score: int] =
  case kind
  of Rabbit: (RabbitEnergyReward, RabbitScoreReward)
  of Boar: (BoarEnergyReward, BoarScoreReward)
  of Stag: (StagEnergyReward, StagScoreReward)
  of Moose: (MooseEnergyReward, MooseScoreReward)
  of Mammoth: (MammothEnergyReward, MammothScoreReward)

proc applyCaptures(sim: var SimServer) =
  var removed: seq[int] = @[]
  for i in 0 ..< sim.prey.len:
    let sides = sim.sidesAround(sim.prey[i])
    if isCaptured(sides, sim.prey[i].kind):
      let reward = rewardsFor(sim.prey[i].kind)
      for idx in [sides.n, sides.s, sides.e, sides.w]:
        if idx >= 0 and idx < sim.players.len:
          sim.players[idx].energy = min(MaxEnergy, sim.players[idx].energy + reward.energy)
          sim.players[idx].score += reward.score
          sim.players[idx].catchFlash = CatchFlashTicks
      removed.add(i)
  for i in countdown(removed.high, 0):
    sim.prey.delete(removed[i])

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc playerBodyColor(colorIndex: int): uint8 =
  case colorIndex mod 8
  of 0: 3'u8   # red
  of 1: 14'u8  # blue
  of 2: 7'u8   # orange
  of 3: 4'u8   # pink
  of 4: 8'u8   # yellow
  of 5: 11'u8  # bright green
  of 6: 15'u8  # light blue
  else: 2'u8   # white

proc playerAccentColor(colorIndex: int): uint8 =
  case colorIndex mod 8
  of 0: 5'u8
  of 1: 13'u8
  of 2: 5'u8
  of 3: 3'u8
  of 4: 7'u8
  of 5: 10'u8
  of 6: 13'u8
  else: 1'u8

proc renderTerrain(sim: var SimServer, cameraX, cameraY: int) =
  sim.fb.clearFrame(BackgroundColor)

  let
    startTx = max(0, cameraX div TileSize)
    startTy = max(0, cameraY div TileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + ScreenWidth - 1) div TileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + ScreenHeight - 1) div TileSize)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let kind = sim.tiles[tileIndex(tx, ty)]
      if kind == TileEmpty:
        # Add subtle grass specks via hash of tile coords
        let h = uint32(tx * 73856093) xor uint32(ty * 19349663)
        if (h and 0xF'u32) == 0'u32:
          let px = tx * TileSize - cameraX + int((h shr 4) and 3'u32) + 1
          let py = ty * TileSize - cameraY + int((h shr 6) and 3'u32) + 1
          sim.fb.putPixel(px, py, 11'u8)
        continue
      let
        baseX = tx * TileSize - cameraX
        baseY = ty * TileSize - cameraY
      case kind
      of TileTree:
        sim.fb.drawPattern(TreePattern, baseX, baseY)
      of TileRock:
        sim.fb.drawPattern(RockPattern, baseX, baseY)
      else:
        discard

proc renderPrey(sim: var SimServer, prey: Prey, cameraX, cameraY: int) =
  let
    baseX = prey.tileX * TileSize - cameraX
    baseY = prey.tileY * TileSize - cameraY

  # alert wiggle
  var offsetX = 0
  if prey.alertFlash > 0:
    if (prey.alertFlash and 1) == 1:
      offsetX = 1
    else:
      offsetX = -1

  sim.fb.drawPreyPattern(prey.kind, baseX + offsetX, baseY)

proc renderPlayer(sim: var SimServer, player: Player, cameraX, cameraY: int) =
  let
    baseX = player.tileX * TileSize - cameraX
    baseY = player.tileY * TileSize - cameraY
    body = playerBodyColor(player.colorIndex)
    accent = playerAccentColor(player.colorIndex)

  if player.catchFlash > 0 and (player.catchFlash and 1) == 1:
    sim.fb.drawPattern(PlayerPattern, baseX, baseY, 2'u8, 0'u8, player.facing)
  else:
    sim.fb.drawPattern(PlayerPattern, baseX, baseY, body, accent, player.facing)

proc renderNumber(
  fb: var Framebuffer,
  digitSprites: array[10, Sprite],
  value, screenX, screenY: int
) =
  let text = $max(0, value)
  var x = screenX
  for ch in text:
    let digit = ord(ch) - ord('0')
    fb.blitSprite(digitSprites[digit], x, screenY, 0, 0)
    x += digitSprites[digit].width

proc renderHud(sim: var SimServer, playerIndex: int) =
  let player = sim.players[playerIndex]

  sim.fb.renderNumber(sim.digitSprites, min(9999, player.score), 0, 0)

  # Energy bar (bottom left-ish). 40px wide, 3 tall.
  let barX = 12
  let barY = ScreenHeight - 4
  let barW = 40
  let fillW = (player.energy * barW) div MaxEnergy
  for x in 0 ..< barW:
    sim.fb.putPixel(barX + x, barY, 0'u8)
    sim.fb.putPixel(barX + x, barY + 1, 0'u8)
    sim.fb.putPixel(barX + x, barY + 2, 0'u8)
  for x in 0 ..< fillW:
    let color: uint8 =
      if player.energy < MaxEnergy div 4: 3'u8
      elif player.energy < MaxEnergy div 2: 7'u8
      else: 11'u8
    sim.fb.putPixel(barX + x, barY, color)
    sim.fb.putPixel(barX + x, barY + 1, color)
    sim.fb.putPixel(barX + x, barY + 2, color)

  # small "E" icon next to bar
  let iconX = 2
  let iconY = barY - 1
  for dy in 0 ..< 5:
    sim.fb.putPixel(iconX, iconY + dy, 2'u8)
  sim.fb.putPixel(iconX + 1, iconY, 2'u8)
  sim.fb.putPixel(iconX + 2, iconY, 2'u8)
  sim.fb.putPixel(iconX + 1, iconY + 2, 2'u8)
  sim.fb.putPixel(iconX + 1, iconY + 4, 2'u8)
  sim.fb.putPixel(iconX + 2, iconY + 4, 2'u8)

proc clampCamera(value, worldMax, viewMax: int): int =
  if worldMax <= viewMax:
    return (worldMax - viewMax) div 2
  value.clamp(0, worldMax - viewMax)

proc buildFramePacket(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(BackgroundColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let player = sim.players[playerIndex]
  let
    centerX = player.tileX * TileSize + TileSize div 2
    centerY = player.tileY * TileSize + TileSize div 2
    cameraX = clampCamera(centerX - ScreenWidth div 2, WorldWidthPixels, ScreenWidth)
    cameraY = clampCamera(centerY - ScreenHeight div 2, WorldHeightPixels, ScreenHeight)

  sim.renderTerrain(cameraX, cameraY)

  for prey in sim.prey:
    let
      visX = prey.tileX * TileSize >= cameraX - TileSize and
        prey.tileX * TileSize <= cameraX + ScreenWidth
      visY = prey.tileY * TileSize >= cameraY - TileSize and
        prey.tileY * TileSize <= cameraY + ScreenHeight
    if visX and visY:
      sim.renderPrey(prey, cameraX, cameraY)

  for other in sim.players:
    let
      visX = other.tileX * TileSize >= cameraX - TileSize and
        other.tileX * TileSize <= cameraX + ScreenWidth
      visY = other.tileY * TileSize >= cameraY - TileSize and
        other.tileY * TileSize <= cameraY + ScreenHeight
    if visX and visY:
      sim.renderPlayer(other, cameraX, cameraY)

  sim.renderHud(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

# ---------------------------------------------------------------------------
# Game step
# ---------------------------------------------------------------------------

proc step(sim: var SimServer, inputs: openArray[InputState]) =
  inc sim.tickCount
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len: inputs[playerIndex] else: InputState()
    sim.applyPlayerInput(playerIndex, input)

  for preyIndex in 0 ..< sim.prey.len:
    sim.thinkPrey(preyIndex)

  sim.applyCaptures()
  sim.maintainPrey()

# ---------------------------------------------------------------------------
# WebSocket plumbing (modelled on big_adventure)
# ---------------------------------------------------------------------------

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET":
    discard request.upgradeToWebSocket()
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Stag Hunt WebSocket server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerIndices[websocket] = 0x7fffffff
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage and isInputPacket(message.data):
      {.gcsafe.}:
        withLock appState.lock:
          appState.inputMasks[websocket] = blobToMask(message.data)
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(milliseconds = int(1000.0 / TargetFps))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop(host = DefaultHost, port = DefaultPort) =
  initAppState()

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4
  )

  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()

  var
    sim = initSim()
    lastTick = getMonoTime()

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == 0x7fffffff:
            appState.playerIndices[websocket] = sim.addPlayer()

        inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let
            currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = inputStateFromMasks(currentMask, previousMask)
          appState.lastAppliedMasks[websocket] = currentMask
          sockets.add(websocket)
          playerIndices.add(playerIndex)

    sim.step(inputs)

    for i in 0 ..< sockets.len:
      let frameBlob = blobFromBytes(sim.buildFramePacket(playerIndices[i]))
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    runFrameLimiter(lastTick)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      else: discard
    else: discard
  runServerLoop(address, port)

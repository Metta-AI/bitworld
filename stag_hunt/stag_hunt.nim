import mummy
import pixie
import supersnappy
import bitworld/clients
import protocol, server
import std/[locks, monotimes, os, parseopt, random, sequtils, sets, strutils, tables, times]

const
  # Stag Hunt picks its own world tile size rather than inherit the
  # protocol's 6 px default. Bigger pixels per tile = recognizable art
  # at the cost of fewer visible tiles per viewport (~10 across instead
  # of ~21).
  StagTileSize = 12

  WorldWidthTiles = 32
  WorldHeightTiles = 32
  WorldWidthPixels = WorldWidthTiles * StagTileSize
  WorldHeightPixels = WorldHeightTiles * StagTileSize

  PlayerMoveCooldownTicks = 5
  PreyThinkIntervalTicks = 10

  PreyFleeRadius = 3
  PreyFleeProb1 = 75
  PreyFleeProb2 = 50
  PreyFleeProb3 = 25
  PreyWanderProb = 30

  MaxEnergy = 200
  PassiveRechargeMax = 100
  StartEnergy = 120
  MoveEnergyCost = 2
  PassiveRechargeInterval = 18

  KillGlowTicks = 20         # yellow halo on the killers
  CorpseLifetimeTicks = 48   # how long a corpse blob lingers on the tile
  AlertFlashTicks = 6

  RabbitEnergyReward = 25
  RabbitScoreReward = 1
  BoarEnergyReward = 90
  BoarScoreReward = 3
  StagEnergyReward = 60
  StagScoreReward = 5
  MooseEnergyReward = 140
  MooseScoreReward = 10
  ElephantEnergyReward = 220
  ElephantScoreReward = 18

  # Prey only appear once enough players are connected to catch them.
  # Per-kind target populations; values for kinds that need more players
  # than are currently connected are simply skipped.
  TargetRabbits = 12
  TargetBoars = 6
  TargetStags = 6
  TargetMooses = 3
  TargetElephants = 2

  RespawnIntervalTicks = 60
  CatchupSpawnCooldown = 3

  ObstacleDensityPerMille = 110

  TargetFps = 24.0
  WebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  HealthzPath = "/healthz"
  UnassignedPlayerIndex = 0x7fffffff

  # Sprite v1 layer/sprite/object layout
  MapLayerId = 0
  MapLayerKind = 0
  MapLayerFlags = 1

  PlayerViewportWidth = ScreenWidth   # 128
  PlayerViewportHeight = ScreenHeight # 128

  TreeSpriteId = 1
  RockSpriteId = 2
  CorpseSpriteId = 4         # one shared "dead prey" blob
  KillGlowSpriteId = 5       # one shared yellow halo
  PreySpriteBase = 10        # + PreyKind.ord (0..4)
  PlayerSpriteBase = 100     # + colorSlot * 4 + facing.ord  (0..31)

  TileObjectBase = 1000      # + tileIndex
  PlayerObjectBase = 5000    # + array index
  CorpseObjectBase = 6000    # + array index
  KillGlowObjectBase = 7000  # + player array index
  IndicatorObjectBase = 9000 # + preyIndex * 4 + sideOrd
  PreyObjectBase = 10000     # + array index

  TerrainZ = 0
  BackgroundSpriteId = 3
  BackgroundObjectBase = 8000

  PlayerSpriteSize = 12
  RabbitSpriteSize = 10
  BoarSpriteSize = 12
  StagSpriteSize = 12
  MooseSpriteSize = 14       # antlers overlap upward (bottom-left anchored)
  ElephantSpriteSize = 14    # overlaps neighboring tiles

  CorpseSpriteSize = 12
  KillGlowSpriteSize = 16
  IndicatorSpriteSize = 4
  IndicatorSpriteBase = 20   # 20, 21, 22 for 1-dot, 2-dot, 3-dot

  DigitSpriteBase = 30       # ids 30-39 for digits 0-9
  ScoreIconSpriteId = 40
  EnergyIconSpriteId = 41
  OverlayBgSpriteId = 42
  DividerSpriteId = 43
  DigitSpriteWidth = 3
  DigitSpriteHeight = 5
  HudObjectBase = 11000
  OverlayObjectBase = 12000
  HudZ = 9999
  OverlayZ = 10000

type
  PreyKind = enum
    Rabbit
    Boar
    Stag
    Moose
    Elephant

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
    killGlow: int
    rechargeCounter: int
    colorIndex: int
    overlayActive: bool
    selectWasDown: bool

  Prey = object
    id: int
    kind: PreyKind
    tileX: int
    tileY: int
    thinkCooldown: int
    alertFlash: int

  Corpse = object
    tileX: int
    tileY: int
    ticksRemaining: int

  RgbaSprite = object
    width: int
    height: int
    pixels: seq[uint8]

  ViewerState = object
    initialized: bool

  SimServer = object
    players: seq[Player]
    prey: seq[Prey]
    corpses: seq[Corpse]
    tiles: seq[TileKind]
    rng: Rand
    nextPlayerId: int
    nextPreyId: int
    tickCount: int
    respawnCooldown: int
    treeSprite: RgbaSprite
    rockSprite: RgbaSprite
    backgroundSprite: RgbaSprite
    corpseSprite: RgbaSprite
    killGlowSprite: RgbaSprite
    preySprites: array[5, RgbaSprite]      # by PreyKind.ord
    playerSprites: array[8 * 4, RgbaSprite] # by colorSlot * 4 + facing.ord
    indicatorSprites: array[3, RgbaSprite]  # 1-dot, 2-dot, 3-dot
    digitSprites: array[10, RgbaSprite]
    scoreIconSprite: RgbaSprite
    energyIconSprite: RgbaSprite
    overlayBgSprite: RgbaSprite
    dividerSprite: RgbaSprite

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerStates: Table[WebSocket, ViewerState]
    globalViewers: HashSet[WebSocket]
    globalStates: Table[WebSocket, ViewerState]
    closedSockets: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

var appState: WebSocketAppState

proc repoDir(): string = getCurrentDir() / ".."
proc clientDataDir(): string = repoDir() / "clients" / "data"
proc palettePath(): string = clientDataDir() / "pallete.png"
proc spriteDir(): string = getCurrentDir() / "stag_hunt" / "sprites" / "12px"

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

proc newRgbaSprite(width, height: int): RgbaSprite =
  RgbaSprite(
    width: width,
    height: height,
    pixels: newSeq[uint8](width * height * 4)
  )

proc putRgbaPixel(sprite: var RgbaSprite, x, y: int, color: ColorRGBA) =
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return
  let base = (y * sprite.width + x) * 4
  sprite.pixels[base + 0] = color.r
  sprite.pixels[base + 1] = color.g
  sprite.pixels[base + 2] = color.b
  sprite.pixels[base + 3] = color.a

proc paletteRgba(index: uint8): ColorRGBA =
  if index == TransparentColorIndex:
    return ColorRGBA(r: 0, g: 0, b: 0, a: 0)
  if int(index) >= Palette.len:
    return ColorRGBA(r: 0, g: 0, b: 0, a: 0)
  Palette[int(index)]

proc patternToRgbaSprite(
  pattern: openArray[string],
  playerBody: uint8 = 0,
  playerAccent: uint8 = 0,
  facing: Facing = FaceDown
): RgbaSprite =
  let h = pattern.len
  if h == 0:
    return newRgbaSprite(0, 0)
  let w = pattern[0].len
  result = newRgbaSprite(w, h)
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
      result.putRgbaPixel(dx, dy, paletteRgba(color))

# ---------------------------------------------------------------------------
# Sprite patterns.
# '.' transparent; 0-9 a-f are palette indices; P/Q = player body/accent.
# Palette (DB16): 0 black, 1 gray, 2 white, 3 red, 4 pink, 5 dk-brown,
# 6 tan, 7 orange, 8 yellow, 9 dk-teal, a dk-green, b green, c navy,
# d dk-blue, e blue, f lt-blue.
# ---------------------------------------------------------------------------

const
  # Character sprite sizes form a hierarchy: rabbit smaller than the tile
  # (and jiggles inside it), boar/stag tile-sized, moose and elephant
  # overlap neighboring tiles. Mechanically every prey still occupies
  # exactly one tile.

  # Player: 12x12 (tile-sized), outlined. Faces down by default; sprite is
  # rotated for other facings. Symmetric left/right.
  PlayerPattern = @[
    "............",
    "....0000....",
    "...0QQQQ0...",
    "..0QQQQQQ0..",
    "..0Q4444Q0..",
    "..0Q4004Q0..",
    "..0Q4444Q0..",
    "...044440...",
    "..0PPPPPP0..",
    ".0PPPPPPPP0.",
    ".0P0PPPP0P0.",
    "...00..00...",
  ]

  # Rabbit: 10x10, white body with long pink-inner ears and a dark eye.
  RabbitPattern = @[
    ".00....00.",
    "0220.0220.",
    "0240.0240.",
    "0220.0220.",
    "0220022200",
    "022222220.",
    "02002222.0",
    ".0222220..",
    "..0220.0..",
    "..00...0..",
  ]

  # Boar: 12x12 chunky dark-brown side-on, tan snout to the right, tusks.
  BoarPattern = @[
    "............",
    "............",
    "...0000000..",
    "..05555560..",
    ".055555560..",
    "0555055560..",
    "0555505560.0",
    "055555560.2.",
    "0555555560..",
    ".05055505...",
    "..0.0.0.0...",
    "............",
  ]

  # Stag: 12x12 tan body, branching dark-brown antlers above head.
  StagPattern = @[
    "5...5..5..5.",
    ".5.5.55.55..",
    "..555.5.5...",
    "..050050....",
    "..050050....",
    ".06666660...",
    "06606066060.",
    "06666666660.",
    "06666666660.",
    ".06606606600",
    "..0..0..0.0.",
    "............",
  ]

  MoosePattern = @[
    "5..5..5..5..5.",
    ".5.55.5.55.5..",
    "..555.5..555..",
    "...5555555....",
    "...050050.....",
    "..0aaaaaaa0...",
    "..0aa000aa0...",
    ".0aaaaaaaaaa0.",
    ".0aaaaaaaaa0..",
    ".0aaa00aaaa0..",
    ".0aaaaaaaaaa0.",
    "..0a.0..0.a0..",
    "..0a.0..0.a0..",
    "...0.0..0..0..",
  ]

  ElephantPattern = @[
    ".....000000...",
    "...011111110..",
    "..0111111111..",
    ".01111001111..",
    "011111001111..",
    "01111111111110",
    "01111111111110",
    "01111111111110",
    ".0111100011110",
    ".0111000011110",
    ".01100..011110",
    ".010....01110.",
    "..2......020..",
    "..........2...",
  ]

  # Tree: 12x12 bushy green canopy with a thick brown trunk.
  TreePattern = [
    "....00......",
    "...0bb0.....",
    "..0babbb0...",
    ".0bbabbab0..",
    "0babbabbab0.",
    "0bbabbbabb0.",
    "0bababbabb0.",
    ".0babbabb0..",
    "..0abbab0...",
    "....55......",
    "....55......",
    "....50......",
  ]

  # Rock: 12x12 rounded boulder, gray, with highlight + base shadow.
  RockPattern = [
    "............",
    "....0000....",
    "...011110...",
    "..01122110..",
    ".0112211110.",
    "011112211110",
    "011111111110",
    ".01111011110",
    "..0111110...",
    "...01010....",
    "....000.....",
    "............",
  ]

  # Grass: 12x12 dark-green field with sparse highlights. Tiles cleanly
  # because the highlight pattern has no edge artifacts.
  GrassPattern = [
    "aaaaabaaaaaa",
    "aaaaaaaaabaa",
    "abaaaaaaaaaa",
    "aaaaaabaaaba",
    "aaaaaaaaaaaa",
    "aaabaaaaaaaa",
    "aaaaaaababaa",
    "abaaaaaaaaaa",
    "aaaaaaabaaaa",
    "aaaabaaaaaaa",
    "abaaaaaaabaa",
    "aaaaabaaaaaa",
  ]

  CorpsePattern = [
    "..00000000..",
    ".0555555550.",
    "055555555550",
    "055555555550",
    "055555555550",
    "055555555550",
    "055555555550",
    "055555555550",
    "055555555550",
    "055555555550",
    ".0555555550.",
    "..00000000..",
  ]

  # Kill glow: 16x16 yellow ring centered on a 12 px player. Center is
  # transparent so the player sprite shows through.
  KillGlowPattern = [
    "....88888888....",
    "...8........8...",
    "..8..........8..",
    ".8............8.",
    "8..............8",
    "8..............8",
    "8..............8",
    "8..............8",
    "8..............8",
    "8..............8",
    "8..............8",
    "8..............8",
    ".8............8.",
    "..8..........8..",
    "...8........8...",
    "....88888888....",
  ]

  # Indicator dots: 4x4 yellow dots showing how many more players needed.
  Indicator1Pattern = [
    "....",
    ".88.",
    ".88.",
    "....",
  ]

  Indicator2Pattern = [
    ".8..",
    "....",
    "....",
    "..8.",
  ]

  Indicator3Pattern = [
    ".8.8",
    "....",
    "....",
    "8...",
  ]

  DigitPatterns: array[10, array[5, string]] = [
    ["222", "2.2", "2.2", "2.2", "222"],
    [".2.", "22.", ".2.", ".2.", "222"],
    ["222", "..2", "222", "2..", "222"],
    ["222", "..2", "222", "..2", "222"],
    ["2.2", "2.2", "222", "..2", "..2"],
    ["222", "2..", "222", "..2", "222"],
    ["222", "2..", "222", "2.2", "222"],
    ["222", "..2", "..2", "..2", "..2"],
    ["222", "2.2", "222", "2.2", "222"],
    ["222", "2.2", "222", "..2", "222"],
  ]

  ScoreIconPattern = [
    ".8.",
    "888",
    ".8.",
    "8.8",
    "...",
  ]

  EnergyIconPattern = [
    ".bb",
    ".b.",
    "bb.",
    ".b.",
    "b..",
  ]

proc loadPngSprite(path: string): RgbaSprite =
  let img = readImage(path)
  result = newRgbaSprite(img.width, img.height)
  for y in 0 ..< img.height:
    for x in 0 ..< img.width:
      let c = img[x, y]
      let base = (y * img.width + x) * 4
      result.pixels[base + 0] = c.r
      result.pixels[base + 1] = c.g
      result.pixels[base + 2] = c.b
      result.pixels[base + 3] = c.a

proc tryLoadPngSprite(path: string): RgbaSprite =
  if fileExists(path):
    try:
      return loadPngSprite(path)
    except:
      discard
  RgbaSprite()

proc preyPattern(kind: PreyKind): seq[string] =
  case kind
  of Rabbit: RabbitPattern
  of Boar: BoarPattern
  of Stag: StagPattern
  of Moose: MoosePattern
  of Elephant: ElephantPattern

proc preySpriteSize(kind: PreyKind): int =
  case kind
  of Rabbit: RabbitSpriteSize
  of Boar: BoarSpriteSize
  of Stag: StagSpriteSize
  of Moose: MooseSpriteSize
  of Elephant: ElephantSpriteSize

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
  of Elephant: 4

proc preyCatchable(kind: PreyKind, playerCount: int): bool =
  preyMinPlayers(kind) <= playerCount

proc targetFor(kind: PreyKind): int =
  case kind
  of Rabbit: TargetRabbits
  of Boar: TargetBoars
  of Stag: TargetStags
  of Moose: TargetMooses
  of Elephant: TargetElephants

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

proc buildSpriteCache(sim: var SimServer)

proc initSim(): SimServer =
  result.rng = initRand(0x57A617)
  loadPalette(palettePath())
  result.generateWorld()
  result.respawnCooldown = RespawnIntervalTicks
  result.buildSpriteCache()

  # No initial spawn; maintainPrey populates once players connect so we
  # never spawn prey no one can catch.

# ---------------------------------------------------------------------------
# Player input / movement
# ---------------------------------------------------------------------------

proc applyPlayerInput(sim: var SimServer, playerIndex: int, input: InputState) =
  template p: untyped = sim.players[playerIndex]

  if input.select and not p.selectWasDown:
    p.overlayActive = not p.overlayActive
  p.selectWasDown = input.select

  inc p.rechargeCounter
  if p.rechargeCounter >= PassiveRechargeInterval:
    p.rechargeCounter = 0
    if p.energy < PassiveRechargeMax:
      inc p.energy

  if p.killGlow > 0:
    dec p.killGlow

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
        # diagonal escape: combine flee axis with perpendicular
        if dy != 0:
          if sim.tryPreyMove(preyIndex, 1, dy):
            return
          if sim.tryPreyMove(preyIndex, -1, dy):
            return
        if dx != 0:
          if sim.tryPreyMove(preyIndex, dx, 1):
            return
          if sim.tryPreyMove(preyIndex, dx, -1):
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
  of Elephant:
    n and s and e and w

proc rewardsFor(kind: PreyKind): tuple[energy, score: int] =
  case kind
  of Rabbit: (RabbitEnergyReward, RabbitScoreReward)
  of Boar: (BoarEnergyReward, BoarScoreReward)
  of Stag: (StagEnergyReward, StagScoreReward)
  of Moose: (MooseEnergyReward, MooseScoreReward)
  of Elephant: (ElephantEnergyReward, ElephantScoreReward)

proc applyCaptures(sim: var SimServer) =
  var removed: seq[int] = @[]
  for i in 0 ..< sim.prey.len:
    let sides = sim.sidesAround(sim.prey[i])
    if isCaptured(sides, sim.prey[i].kind):
      let reward = rewardsFor(sim.prey[i].kind)
      var participants: seq[int] = @[]
      for idx in [sides.n, sides.s, sides.e, sides.w]:
        if idx >= 0 and idx < sim.players.len:
          sim.players[idx].energy = min(MaxEnergy, sim.players[idx].energy + reward.energy)
          sim.players[idx].score += reward.score
          sim.players[idx].killGlow = KillGlowTicks
          participants.add(sim.players[idx].id)
      sim.corpses.add Corpse(
        tileX: sim.prey[i].tileX,
        tileY: sim.prey[i].tileY,
        ticksRemaining: CorpseLifetimeTicks
      )
      echo "tick=", sim.tickCount, " caught ", sim.prey[i].kind,
        " +", reward.score, " for players=", participants,
        " scores=", sim.players.mapIt(it.score)
      removed.add(i)
  for i in countdown(removed.high, 0):
    sim.prey.delete(removed[i])

proc ageCorpses(sim: var SimServer) =
  var kept: seq[Corpse] = @[]
  for c in sim.corpses:
    if c.ticksRemaining > 1:
      var alive = c
      dec alive.ticksRemaining
      kept.add(alive)
  sim.corpses = kept

# ---------------------------------------------------------------------------
# Sprite v1 protocol bytes
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

proc addLayer(packet: var seq[uint8], layer, kind, flags: int) =
  packet.addU8(0x06'u8)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(kind))
  packet.addU8(uint8(flags))

proc addViewport(packet: var seq[uint8], layer, width, height: int) =
  packet.addU8(0x05'u8)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addSprite(
  packet: var seq[uint8],
  spriteId: int,
  sprite: RgbaSprite,
  label: string
) =
  packet.addU8(0x01'u8)
  packet.addU16(spriteId)
  packet.addU16(sprite.width)
  packet.addU16(sprite.height)
  let compressed = supersnappy.compress(sprite.pixels)
  packet.addU32(compressed.len)
  for byte in compressed:
    packet.addU8(byte)
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc addObject(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  packet.addU8(0x02'u8)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addClearObjects(packet: var seq[uint8]) =
  packet.addU8(0x04'u8)

proc addIdentity(packet: var seq[uint8], objectId: int) =
  # 0x07 = "you are object N". Sent in every per-player frame so bots
  # know which player object is their own (the global frame has no
  # identity packet — viewers don't need one).
  packet.addU8(0x07'u8)
  packet.addU16(objectId)

# ---------------------------------------------------------------------------
# Sprite cache
# ---------------------------------------------------------------------------

proc playerSpriteId(colorSlot: int, facing: Facing): int =
  PlayerSpriteBase + (colorSlot and 7) * 4 + facing.ord

proc preySpriteId(kind: PreyKind): int =
  PreySpriteBase + kind.ord

proc recolorPng(
  source: RgbaSprite,
  bodyColor, accentColor: ColorRGBA,
): RgbaSprite =
  ## Recolors a PNG sprite by replacing placeholder colors with player colors.
  ## Placeholder colors: #0044ff -> bodyColor, #00227f -> accentColor.
  let w = source.width
  let h = source.height
  result = newRgbaSprite(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let srcBase = (y * w + x) * 4
      let r = source.pixels[srcBase + 0]
      let g = source.pixels[srcBase + 1]
      let b = source.pixels[srcBase + 2]
      let a = source.pixels[srcBase + 3]
      if r == 0 and g == 68 and b == 255:
        # #0044ff -> body color
        result.pixels[srcBase + 0] = bodyColor.r
        result.pixels[srcBase + 1] = bodyColor.g
        result.pixels[srcBase + 2] = bodyColor.b
        result.pixels[srcBase + 3] = a
      elif r == 0 and g == 34 and b == 127:
        # #00227f -> accent color
        result.pixels[srcBase + 0] = accentColor.r
        result.pixels[srcBase + 1] = accentColor.g
        result.pixels[srcBase + 2] = accentColor.b
        result.pixels[srcBase + 3] = a
      else:
        result.pixels[srcBase + 0] = r
        result.pixels[srcBase + 1] = g
        result.pixels[srcBase + 2] = b
        result.pixels[srcBase + 3] = a

proc buildSpriteCache(sim: var SimServer) =
  let dir = spriteDir()

  let treeFile = tryLoadPngSprite(dir / "tree.png")
  sim.treeSprite = if treeFile.width > 0: treeFile else: patternToRgbaSprite(TreePattern)

  let rockFile = tryLoadPngSprite(dir / "rock.png")
  sim.rockSprite = if rockFile.width > 0: rockFile else: patternToRgbaSprite(RockPattern)

  let grassFile = tryLoadPngSprite(dir / "grass.png")
  sim.backgroundSprite = if grassFile.width > 0: grassFile else: patternToRgbaSprite(GrassPattern)

  let corpseFile = tryLoadPngSprite(dir / "ded.png")
  sim.corpseSprite = if corpseFile.width > 0: corpseFile else: patternToRgbaSprite(CorpsePattern)

  sim.killGlowSprite = patternToRgbaSprite(KillGlowPattern)

  const preyFileNames: array[5, string] = ["rabbit", "boar", "stag", "moose", "elephant"]
  for kind in PreyKind:
    let pngSprite = tryLoadPngSprite(dir / preyFileNames[kind.ord] & ".png")
    sim.preySprites[kind.ord] =
      if pngSprite.width > 0: pngSprite
      else: patternToRgbaSprite(preyPattern(kind))

  let hunterFile = tryLoadPngSprite(dir / "hunter.png")
  for colorSlot in 0 ..< 8:
    let body = playerBodyColor(colorSlot)
    let accent = playerAccentColor(colorSlot)
    for facing in Facing:
      if hunterFile.width > 0:
        sim.playerSprites[colorSlot * 4 + facing.ord] =
          recolorPng(hunterFile, paletteRgba(body), paletteRgba(accent))
      else:
        sim.playerSprites[colorSlot * 4 + facing.ord] =
          patternToRgbaSprite(PlayerPattern, body, accent, facing)

  sim.indicatorSprites[0] = patternToRgbaSprite(Indicator1Pattern)
  sim.indicatorSprites[1] = patternToRgbaSprite(Indicator2Pattern)
  sim.indicatorSprites[2] = patternToRgbaSprite(Indicator3Pattern)

  for d in 0 ..< 10:
    sim.digitSprites[d] = patternToRgbaSprite(DigitPatterns[d])
  sim.scoreIconSprite = patternToRgbaSprite(ScoreIconPattern)
  sim.energyIconSprite = patternToRgbaSprite(EnergyIconPattern)

  # Overlay background: solid dark navy fill
  sim.overlayBgSprite = newRgbaSprite(PlayerViewportWidth, PlayerViewportHeight)
  let bgColor = ColorRGBA(r: 26, g: 28, b: 44, a: 255)
  for y in 0 ..< PlayerViewportHeight:
    for x in 0 ..< PlayerViewportWidth:
      sim.overlayBgSprite.putRgbaPixel(x, y, bgColor)

  # Vertical divider: 1px wide, viewport height
  sim.dividerSprite = newRgbaSprite(1, PlayerViewportHeight)
  let divColor = ColorRGBA(r: 86, g: 108, b: 134, a: 255)
  for y in 0 ..< PlayerViewportHeight:
    sim.dividerSprite.putRgbaPixel(0, y, divColor)

proc addSpriteProtocolInit(
  packet: var seq[uint8],
  sim: SimServer,
  viewportWidth, viewportHeight: int
) =
  packet.addLayer(MapLayerId, MapLayerKind, MapLayerFlags)
  packet.addViewport(MapLayerId, viewportWidth, viewportHeight)
  packet.addSprite(BackgroundSpriteId, sim.backgroundSprite, "grass")
  packet.addSprite(TreeSpriteId, sim.treeSprite, "tree")
  packet.addSprite(RockSpriteId, sim.rockSprite, "rock")
  packet.addSprite(CorpseSpriteId, sim.corpseSprite, "corpse")
  packet.addSprite(KillGlowSpriteId, sim.killGlowSprite, "kill glow")
  for kind in PreyKind:
    packet.addSprite(preySpriteId(kind), sim.preySprites[kind.ord], $kind)
  for colorSlot in 0 ..< 8:
    for facing in Facing:
      packet.addSprite(
        playerSpriteId(colorSlot, facing),
        sim.playerSprites[colorSlot * 4 + facing.ord],
        "player " & $colorSlot & " " & $facing
      )
  for i in 0 ..< 3:
    packet.addSprite(
      IndicatorSpriteBase + i,
      sim.indicatorSprites[i],
      "indicator " & $(i + 1)
    )
  for d in 0 ..< 10:
    packet.addSprite(DigitSpriteBase + d, sim.digitSprites[d], "digit " & $d)
  packet.addSprite(ScoreIconSpriteId, sim.scoreIconSprite, "score icon")
  packet.addSprite(EnergyIconSpriteId, sim.energyIconSprite, "energy icon")
  packet.addSprite(OverlayBgSpriteId, sim.overlayBgSprite, "overlay bg")
  packet.addSprite(DividerSpriteId, sim.dividerSprite, "divider")

# ---------------------------------------------------------------------------
# Frame builders
# ---------------------------------------------------------------------------

proc clampCamera(value, worldMax, viewMax: int): int =
  if worldMax <= viewMax:
    return (worldMax - viewMax) div 2
  value.clamp(0, worldMax - viewMax)

proc playerCamera(player: Player): tuple[x, y: int] =
  let
    centerX = player.tileX * StagTileSize + StagTileSize div 2
    centerY = player.tileY * StagTileSize + StagTileSize div 2
  (
    clampCamera(centerX - PlayerViewportWidth div 2, WorldWidthPixels, PlayerViewportWidth),
    clampCamera(centerY - PlayerViewportHeight div 2, WorldHeightPixels, PlayerViewportHeight)
  )

proc addTerrainObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  let
    startTx = max(0, cameraX div StagTileSize)
    startTy = max(0, cameraY div StagTileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + viewportWidth - 1) div StagTileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + viewportHeight - 1) div StagTileSize)
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        index = tileIndex(tx, ty)
        kind = sim.tiles[index]
        screenX = tx * StagTileSize - cameraX
        screenY = ty * StagTileSize - cameraY
      packet.addObject(
        BackgroundObjectBase + index,
        screenX, screenY, TerrainZ,
        MapLayerId, BackgroundSpriteId
      )
      let spriteId =
        case kind
        of TileTree: TreeSpriteId
        of TileRock: RockSpriteId
        of TileEmpty: 0
      if spriteId == 0:
        continue
      packet.addObject(
        TileObjectBase + index,
        screenX, screenY, screenY + 1,
        MapLayerId, spriteId
      )

proc addPreyObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  for i in 0 ..< sim.prey.len:
    let
      prey = sim.prey[i]
      size = preySpriteSize(prey.kind)
    var screenX: int
    var screenY: int
    if prey.kind == Moose:
      # Bottom-left anchored: sprite aligns at bottom of tile, antlers extend up
      screenX = prey.tileX * StagTileSize - cameraX
      screenY = prey.tileY * StagTileSize - cameraY - (size - StagTileSize)
    else:
      let centerOffset = -((size - StagTileSize) div 2)
      screenX = prey.tileX * StagTileSize - cameraX + centerOffset
      screenY = prey.tileY * StagTileSize - cameraY + centerOffset
    if prey.kind == Rabbit:
      # Idle bob: a single pixel rise every ~16 ticks, dephased per rabbit
      # so they don't all bounce in lockstep. Stops while alertFlash plays
      # its own wiggle.
      if prey.alertFlash == 0:
        let phase = ((sim.tickCount + i * 7) shr 4) and 1
        if phase == 1:
          screenY -= 1
    if prey.alertFlash > 0:
      if (prey.alertFlash and 1) == 1:
        screenX += 1
      else:
        screenX -= 1
    if screenX + size <= 0 or screenY + size <= 0:
      continue
    if screenX >= viewportWidth or screenY >= viewportHeight:
      continue
    packet.addObject(
      PreyObjectBase + i,
      screenX, screenY, screenY + 2,
      MapLayerId, preySpriteId(prey.kind)
    )

proc addCorpseObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  for i, c in sim.corpses:
    let
      screenX = c.tileX * StagTileSize - cameraX
      screenY = c.tileY * StagTileSize - cameraY
    if screenX + CorpseSpriteSize <= 0 or screenY + CorpseSpriteSize <= 0:
      continue
    if screenX >= viewportWidth or screenY >= viewportHeight:
      continue
    packet.addObject(
      CorpseObjectBase + i,
      screenX, screenY, screenY + 1,
      MapLayerId, CorpseSpriteId
    )

proc validIndicatorSides(kind: PreyKind, sides: PlayerSides): array[4, bool] =
  ## Returns which unoccupied sides (N,S,E,W) are valid positions to complete a capture.
  ## Index: 0=N, 1=S, 2=E, 3=W
  let n = sides.n >= 0
  let s = sides.s >= 0
  let e = sides.e >= 0
  let w = sides.w >= 0
  case kind
  of Rabbit:
    # Single player captures — if anyone is adjacent it's already dead
    result = [false, false, false, false]
  of Boar:
    # Need perpendicular: (N and E), (N and W), (S and E), (S and W)
    if n or s:
      result[2] = not e  # E is valid
      result[3] = not w  # W is valid
    if e or w:
      result[0] = not n  # N is valid
      result[1] = not s  # S is valid
  of Stag:
    # Need opposing: (N and S) or (E and W)
    if n: result[1] = not s
    if s: result[0] = not n
    if e: result[3] = not w
    if w: result[2] = not e
  of Moose:
    # Need 3+; any unoccupied side is valid
    result[0] = not n
    result[1] = not s
    result[2] = not e
    result[3] = not w
  of Elephant:
    # Need all 4; any unoccupied side is valid
    result[0] = not n
    result[1] = not s
    result[2] = not e
    result[3] = not w

proc addIndicatorObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  for i in 0 ..< sim.prey.len:
    let prey = sim.prey[i]
    let sides = sim.sidesAround(prey)
    let occupied = sideCount(sides)
    if occupied == 0:
      continue
    let needed = preyMinPlayers(prey.kind) - occupied
    if needed <= 0:
      continue
    let valid = validIndicatorSides(prey.kind, sides)
    # Clamp to 1..3 (max indicator sprite)
    let dots = max(min(needed, 3), 1)
    let spriteId = IndicatorSpriteBase + dots - 1
    # Center the 4x4 indicator in the 12x12 tile
    let indicatorOffset = (StagTileSize - IndicatorSpriteSize) div 2
    # Cardinal directions: N=0, S=1, E=2, W=3
    type SideInfo = tuple[sideOrd: int, dx, dy: int]
    let sideInfos: array[4, SideInfo] = [
      (0, 0, -1),
      (1, 0, 1),
      (2, 1, 0),
      (3, -1, 0),
    ]
    for info in sideInfos:
      if not valid[info.sideOrd]:
        continue
      let tx = prey.tileX + info.dx
      let ty = prey.tileY + info.dy
      if not inTileBounds(tx, ty):
        continue
      if sim.tiles[tileIndex(tx, ty)] != TileEmpty:
        continue
      let screenX = tx * StagTileSize - cameraX + indicatorOffset
      let screenY = ty * StagTileSize - cameraY + indicatorOffset
      if screenX + IndicatorSpriteSize <= 0 or screenY + IndicatorSpriteSize <= 0:
        continue
      if screenX >= viewportWidth or screenY >= viewportHeight:
        continue
      packet.addObject(
        IndicatorObjectBase + i * 4 + info.sideOrd,
        screenX, screenY, screenY + 2,
        MapLayerId, spriteId
      )

proc addPlayerObjects(
  packet: var seq[uint8],
  sim: SimServer,
  cameraX, cameraY, viewportWidth, viewportHeight: int
) =
  const glowOffset = -((KillGlowSpriteSize - PlayerSpriteSize) div 2)
  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      # Player sprite matches the tile size, so no centering offset.
      screenX = player.tileX * StagTileSize - cameraX
      screenY = player.tileY * StagTileSize - cameraY
    if screenX + PlayerSpriteSize <= 0 or screenY + PlayerSpriteSize <= 0:
      continue
    if screenX >= viewportWidth or screenY >= viewportHeight:
      continue
    packet.addObject(
      PlayerObjectBase + i,
      screenX, screenY, screenY + 3,
      MapLayerId, playerSpriteId(player.colorIndex, player.facing)
    )
    # Glowing yellow halo around recent killers. The ring's center is
    # transparent so the player sprite still shows through; pulse by
    # toggling between visible and hidden every 3 ticks for a soft blink.
    if player.killGlow > 0 and (player.killGlow div 3) mod 2 == 0:
      packet.addObject(
        KillGlowObjectBase + i,
        screenX + glowOffset, screenY + glowOffset, screenY + 4,
        MapLayerId, KillGlowSpriteId
      )

proc addHudObjects(packet: var seq[uint8], score, energy: int) =
  var objIdx = 0
  packet.addObject(HudObjectBase + objIdx, 1, 1, HudZ, MapLayerId, ScoreIconSpriteId)
  inc objIdx
  let scoreStr = $max(0, score)
  var sx = 5
  for ch in scoreStr:
    let digit = ord(ch) - ord('0')
    packet.addObject(HudObjectBase + objIdx, sx, 1, HudZ, MapLayerId, DigitSpriteBase + digit)
    inc objIdx
    sx += DigitSpriteWidth + 1
  packet.addObject(HudObjectBase + objIdx, 1, 7, HudZ, MapLayerId, EnergyIconSpriteId)
  inc objIdx
  let energyStr = $max(0, energy)
  var ex = 5
  for ch in energyStr:
    let digit = ord(ch) - ord('0')
    packet.addObject(HudObjectBase + objIdx, ex, 7, HudZ, MapLayerId, DigitSpriteBase + digit)
    inc objIdx
    ex += DigitSpriteWidth + 1

proc addOverlayDigits(packet: var seq[uint8], x, y, num: int, objIdx: var int) =
  let s = $max(0, num)
  var dx = x
  for ch in s:
    let digit = ord(ch) - ord('0')
    packet.addObject(OverlayObjectBase + objIdx, dx, y, OverlayZ, MapLayerId, DigitSpriteBase + digit)
    inc objIdx
    dx += DigitSpriteWidth + 1

proc addOverlayObjects(packet: var seq[uint8], sim: SimServer, playerIndex: int) =
  var objIdx = 0

  # Background
  packet.addObject(OverlayObjectBase + objIdx, 0, 0, OverlayZ, MapLayerId, OverlayBgSpriteId)
  inc objIdx

  # Left column: animals (5 entries, each ~24px tall)
  const animalStartY = 4
  const animalRowH = 24
  const animalX = 4
  for kind in PreyKind:
    let row = kind.ord
    let by = animalStartY + row * animalRowH
    # Animal sprite
    packet.addObject(OverlayObjectBase + objIdx, animalX, by, OverlayZ, MapLayerId, preySpriteId(kind))
    inc objIdx
    # Score icon + digits
    let infoX = animalX + 16
    packet.addObject(OverlayObjectBase + objIdx, infoX, by + 2, OverlayZ, MapLayerId, ScoreIconSpriteId)
    inc objIdx
    let (energy, score) = rewardsFor(kind)
    packet.addOverlayDigits(infoX + 5, by + 2, score, objIdx)
    # Energy icon + digits
    packet.addObject(OverlayObjectBase + objIdx, infoX, by + 9, OverlayZ, MapLayerId, EnergyIconSpriteId)
    inc objIdx
    packet.addOverlayDigits(infoX + 5, by + 9, energy, objIdx)

  # Vertical divider
  const dividerX = 52
  packet.addObject(OverlayObjectBase + objIdx, dividerX, 0, OverlayZ, MapLayerId, DividerSpriteId)
  inc objIdx

  # Right column: player scores
  const playerStartX = 56
  const playerStartY = 4
  const playerRowH = 12
  for i in 0 ..< sim.players.len:
    let by = playerStartY + i * playerRowH
    if by + playerRowH > PlayerViewportHeight:
      break
    let p = sim.players[i]
    # Player sprite
    packet.addObject(OverlayObjectBase + objIdx, playerStartX, by, OverlayZ, MapLayerId,
      playerSpriteId(p.colorIndex, FaceDown))
    inc objIdx
    # Score
    packet.addObject(OverlayObjectBase + objIdx, playerStartX + 14, by + 2, OverlayZ, MapLayerId, ScoreIconSpriteId)
    inc objIdx
    packet.addOverlayDigits(playerStartX + 20, by + 2, p.score, objIdx)

proc buildPlayerFrame(
  sim: SimServer,
  playerIndex: int,
  state: ViewerState,
  nextState: var ViewerState
): seq[uint8] =
  nextState = state
  if not nextState.initialized:
    result.addSpriteProtocolInit(sim, PlayerViewportWidth, PlayerViewportHeight)
    nextState.initialized = true
  result.addClearObjects()
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  result.addIdentity(PlayerObjectBase + playerIndex)
  if sim.players[playerIndex].overlayActive:
    result.addOverlayObjects(sim, playerIndex)
    return
  let (cameraX, cameraY) = playerCamera(sim.players[playerIndex])
  result.addTerrainObjects(sim, cameraX, cameraY, PlayerViewportWidth, PlayerViewportHeight)
  result.addCorpseObjects(sim, cameraX, cameraY, PlayerViewportWidth, PlayerViewportHeight)
  result.addPreyObjects(sim, cameraX, cameraY, PlayerViewportWidth, PlayerViewportHeight)
  result.addIndicatorObjects(sim, cameraX, cameraY, PlayerViewportWidth, PlayerViewportHeight)
  result.addPlayerObjects(sim, cameraX, cameraY, PlayerViewportWidth, PlayerViewportHeight)
  result.addHudObjects(sim.players[playerIndex].score, sim.players[playerIndex].energy)

proc buildGlobalFrame(
  sim: SimServer,
  state: ViewerState,
  nextState: var ViewerState
): seq[uint8] =
  nextState = state
  if not nextState.initialized:
    result.addSpriteProtocolInit(sim, WorldWidthPixels, WorldHeightPixels)
    nextState.initialized = true
  result.addClearObjects()
  result.addTerrainObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addCorpseObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addPreyObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addIndicatorObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)
  result.addPlayerObjects(sim, 0, 0, WorldWidthPixels, WorldHeightPixels)

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
  sim.ageCorpses()
  sim.maintainPrey()

# ---------------------------------------------------------------------------
# WebSocket plumbing (modelled on big_adventure)
# ---------------------------------------------------------------------------

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerStates = initTable[WebSocket, ViewerState]()
  appState.globalViewers = initHashSet[WebSocket]()
  appState.globalStates = initTable[WebSocket, ViewerState]()
  appState.closedSockets = @[]

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.globalViewers:
    appState.globalViewers.excl(websocket)
    appState.globalStates.del(websocket)
    return

  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.playerStates.del(websocket)

  if removedIndex >= 0 and removedIndex != UnassignedPlayerIndex and
      removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex and value != UnassignedPlayerIndex:
        dec value

proc serveHealthz(request: Request): bool =
  if request.path != HealthzPath or request.httpMethod notin ["GET", "HEAD"]:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, "healthy")
  true

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc isStaticRoute(route: string): bool =
  case route
  of PlayerClientRoute, PlayerClientHtmlRoute, CoworldPlayerClientRoute,
      GlobalClientRoute, GlobalClientHtmlRoute, CoworldGlobalClientRoute,
      SnappyClientRoute, SnappyClientPath, CoworldSnappyClientRoute:
    true
  else:
    false

proc serveClientFile(request: Request, route: string): bool =
  if request.httpMethod != "GET":
    return false
  let filePath = clientStaticPath(route, GlobalClientRoute)
  if filePath.len == 0:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(route, GlobalClientRoute)
  headers["Cache-Control"] = "no-cache"
  if not fileExists(filePath):
    request.respond(404, headers, "Missing static client: " & route)
    return true
  try:
    request.respond(200, headers, readFile(filePath))
  except IOError as e:
    request.respond(500, headers, "Could not read static client: " & e.msg)
  true

proc httpHandler(request: Request) =
  if request.serveHealthz():
    discard
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    discard request.serveClientFile(GlobalClientRoute)
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    discard request.serveClientFile(GlobalClientRoute)
  elif request.path == WebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerIndices[websocket] = UnassignedPlayerIndex
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
        appState.playerStates[websocket] = ViewerState()
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers.incl(websocket)
        appState.globalStates[websocket] = ViewerState()
  elif request.path.isStaticRoute():
    discard request.serveClientFile(request.path)
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
    discard
  of MessageEvent:
    # Accept bitscreen_v1 (0x00) and sprite_v1 (0x84) 2-byte input packets.
    if message.kind == BinaryMessage and message.data.len == 2 and
        (
          message.data[0].uint8 == PacketInput or
          message.data[0].uint8 == 0x84'u8
        ):
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.playerIndices:
            appState.inputMasks[websocket] = message.data[1].uint8 and 0x7f'u8
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
    workerThreads = 4,
    tcpNoDelay = true
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
      playerSockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerStates: seq[ViewerState] = @[]
      globalSockets: seq[WebSocket] = @[]
      globalStates: seq[ViewerState] = @[]
      inputs: seq[InputState]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == UnassignedPlayerIndex:
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
          playerSockets.add(websocket)
          playerIndices.add(playerIndex)
          playerStates.add(appState.playerStates.getOrDefault(websocket, ViewerState()))

        for websocket in appState.globalViewers:
          globalSockets.add(websocket)
          globalStates.add(appState.globalStates.getOrDefault(websocket, ViewerState()))

    sim.step(inputs)

    for i in 0 ..< playerSockets.len:
      var nextState: ViewerState
      let bytes = sim.buildPlayerFrame(playerIndices[i], playerStates[i], nextState)
      try:
        playerSockets[i].send(blobFromBytes(bytes), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if playerSockets[i] in appState.playerStates:
              appState.playerStates[playerSockets[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(playerSockets[i])

    for i in 0 ..< globalSockets.len:
      var nextState: ViewerState
      let bytes = sim.buildGlobalFrame(globalStates[i], nextState)
      try:
        globalSockets[i].send(blobFromBytes(bytes), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalSockets[i] in appState.globalStates:
              appState.globalStates[globalSockets[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(globalSockets[i])

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

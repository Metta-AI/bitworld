import mummy, pixie, whisky
import protocol, server
import std/[algorithm, json, locks, monotimes, net, os, osproc, parseopt, random,
            strutils, tables, times]

const
  WorldWidthTiles = 64
  WorldHeightTiles = 64
  WorldTileSize = 4
  WorldWidthPixels = WorldWidthTiles * WorldTileSize
  WorldHeightPixels = WorldHeightTiles * WorldTileSize
  MotionScale = 256
  Accel = 100
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeed = 900
  StopThreshold = 16
  MinPlayerSpawnSpacing = 16
  FpsScale = 1000
  TargetFps = 24 * FpsScale
  WebSocketPath = "/player"
  ResetInputMask = 255'u8
  PendingPlayerIndex = high(int)
  PlayerSize = 4
  SelectEscapeCount = 3
  SelectEscapeWindowMs = 800
  GameServerReadyTimeoutMs = 5000
  GameServerPollMs = 100

  ColorGrass = 5'u8
  ColorGrassDark = 13'u8
  ColorRoad = 6'u8
  ColorWater = 9'u8
  ColorWaterDeep = 8'u8
  ColorTree = 4'u8
  ColorTreeTrunk = 7'u8
  ColorVillageFloor = 6'u8
  ColorVillageWall = 7'u8
  ColorVillageRoof = 2'u8
  ColorVillageDoor = 14'u8
  ColorTextBg = 1'u8
  ColorSelectHighlight = 14'u8

type
  RunConfig = object
    address: string
    port: int
    targetFps: int
    seed: int

  TileKind = enum
    TileGrass
    TileGrassDark
    TileRoad
    TileWater
    TileWaterDeep
    TileTree
    TileVillage

  Village = object
    folder: string
    lines: seq[string]
    tx, ty: int
    port: int

  GameProcess = object
    process: Process
    port: int
    ready: bool

  ProxyState = enum
    ProxyIdle
    ProxyConnecting
    ProxyActive

  ProxyConn = object
    state: ProxyState
    villageIndex: int
    ws: whisky.WebSocket
    latestFrame: seq[uint8]
    hasFrame: bool
    selectTimes: seq[MonoTime]

  Player = object
    x, y: int
    velX, velY: int
    carryX, carryY: int
    facing: Facing
    colorIndex: uint8
    inVillage: int
    confirmReady: bool
    rewardTotal: int
    lastRewardVillage: int

  SimServer = object
    tiles: seq[TileKind]
    villages: seq[Village]
    players: seq[Player]
    letterSprites: seq[Sprite]
    fb: Framebuffer
    rng: Rand
    gameProcesses: Table[int, GameProcess]
    proxies: Table[int, ProxyConn]

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[mummy.WebSocket, uint8]
    lastAppliedMasks: Table[mummy.WebSocket, uint8]
    playerIndices: Table[mummy.WebSocket, int]
    closedSockets: seq[mummy.WebSocket]
    rewardViewers: Table[mummy.WebSocket, bool]
    resetRequested: bool

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "client" / "data"

proc palettePath(): string =
  clientDataDir() / "pallete.png"

proc lettersPath(): string =
  clientDataDir() / "letters.png"

proc tileIndex(tx, ty: int): int =
  ty * WorldWidthTiles + tx

proc inBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc tileAt(sim: SimServer, tx, ty: int): TileKind =
  if not inBounds(tx, ty):
    return TileWater
  sim.tiles[tileIndex(tx, ty)]

proc isBlocked(kind: TileKind): bool =
  kind in {TileWater, TileWaterDeep, TileTree}

proc canOccupy(sim: SimServer, px, py: int): bool =
  if px < 0 or py < 0 or px + PlayerSize > WorldWidthPixels or py + PlayerSize > WorldHeightPixels:
    return false
  let
    startTx = px div WorldTileSize
    startTy = py div WorldTileSize
    endTx = (px + PlayerSize - 1) div WorldTileSize
    endTy = (py + PlayerSize - 1) div WorldTileSize
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.tileAt(tx, ty).isBlocked():
        return false
  true

proc distSq(ax, ay, bx, by: int): int =
  let dx = ax - bx
  let dy = ay - by
  dx * dx + dy * dy

proc generateLakes(sim: var SimServer) =
  for _ in 0 .. 5:
    let
      cx = sim.rng.rand(10 .. WorldWidthTiles - 11)
      cy = sim.rng.rand(10 .. WorldHeightTiles - 11)
      rx = sim.rng.rand(3 .. 7)
      ry = sim.rng.rand(3 .. 6)
    for ty in cy - ry .. cy + ry:
      for tx in cx - rx .. cx + rx:
        if not inBounds(tx, ty): continue
        let
          dx = tx - cx
          dy = ty - cy
          rxSq = rx * rx
          rySq = ry * ry
          distNumerator = dx * dx * rySq + dy * dy * rxSq
          distDenominator = rxSq * rySq
        if distNumerator * 10 < distDenominator * 6:
          sim.tiles[tileIndex(tx, ty)] = TileWaterDeep
        elif distNumerator * 100 < distDenominator * (100 + sim.rng.rand(0 .. 30)):
          sim.tiles[tileIndex(tx, ty)] = TileWater

proc generateRiver(sim: var SimServer) =
  var
    x = sim.rng.rand(15 .. WorldWidthTiles - 16)
    y = 0
  while y < WorldHeightTiles:
    for dx in -1 .. 1:
      if inBounds(x + dx, y):
        sim.tiles[tileIndex(x + dx, y)] = TileWater
    let drift = sim.rng.rand(-1 .. 1)
    x = clamp(x + drift, 2, WorldWidthTiles - 3)
    inc y

proc generateTrees(sim: var SimServer) =
  for _ in 0 .. 250:
    let
      tx = sim.rng.rand(0 .. WorldWidthTiles - 1)
      ty = sim.rng.rand(0 .. WorldHeightTiles - 1)
    if sim.tiles[tileIndex(tx, ty)] == TileGrass:
      sim.tiles[tileIndex(tx, ty)] = TileTree

proc generateGrassVariation(sim: var SimServer) =
  for _ in 0 .. 300:
    let
      tx = sim.rng.rand(0 .. WorldWidthTiles - 1)
      ty = sim.rng.rand(0 .. WorldHeightTiles - 1)
    if sim.tiles[tileIndex(tx, ty)] == TileGrass:
      sim.tiles[tileIndex(tx, ty)] = TileGrassDark

proc placeRoad(sim: var SimServer, x0, y0, x1, y1: int) =
  var x = x0
  var y = y0
  while x != x1 or y != y1:
    for dy in -1 .. 0:
      for dx in -1 .. 0:
        if inBounds(x + dx, y + dy):
          sim.tiles[tileIndex(x + dx, y + dy)] = TileRoad
    if abs(x1 - x) > abs(y1 - y):
      if x < x1: inc x else: dec x
    else:
      if y < y1: inc y else: dec y

proc placeVillage(sim: var SimServer, v: Village) =
  let
    hw = 3
    hh = 2
  for ty in v.ty - hh .. v.ty + hh:
    for tx in v.tx - hw .. v.tx + hw:
      if inBounds(tx, ty):
        sim.tiles[tileIndex(tx, ty)] = TileVillage
  for ty in v.ty - hh - 1 .. v.ty + hh + 1:
    for tx in v.tx - hw - 1 .. v.tx + hw + 1:
      if inBounds(tx, ty) and sim.tiles[tileIndex(tx, ty)] in {TileWater, TileWaterDeep, TileTree}:
        sim.tiles[tileIndex(tx, ty)] = TileGrass

const
  SkipFolders = ["client", "overworld", "tools", "docs", "common"]

proc humanizeFolderName(folder: string): seq[string] =
  for part in folder.split('_'):
    if part.len == 0: continue
    result.add(part.toUpperAscii())

proc discoverGames(): seq[tuple[folder: string, lines: seq[string]]] =
  let gameDir = repoDir()
  for kind, path in walkDir(gameDir):
    if kind != pcDir: continue
    let folder = lastPathPart(path)
    if folder in SkipFolders: continue
    if folder.startsWith("."): continue
    let entryFile = path / (folder & ".nim")
    if not fileExists(entryFile): continue
    result.add((folder: folder, lines: humanizeFolderName(folder)))
  result.sort(proc(a, b: tuple[folder: string, lines: seq[string]]): int = cmp(a.folder, b.folder))

proc initVillages(): seq[Village] =
  let games = discoverGames()
  let count = games.len
  if count == 0: return @[]

  let
    marginX = 8
    marginY = 8
    usableW = WorldWidthTiles - marginX * 2
    usableH = WorldHeightTiles - marginY * 2

  var cols = 1
  while cols * cols < count: inc cols
  let rows = (count + cols - 1) div cols

  let
    spacingX = usableW div max(cols, 1)
    spacingY = usableH div max(rows, 1)

  for i, game in games:
    let
      col = i mod cols
      row = i div cols
      tx = marginX + spacingX div 2 + col * spacingX
      ty = marginY + spacingY div 2 + row * spacingY
    result.add Village(
      folder: game.folder,
      lines: game.lines,
      tx: tx, ty: ty,
      port: 8081 + i,
    )

proc initSimServer(seed: int): SimServer =
  result.rng = initRand(seed)
  result.tiles = newSeq[TileKind](WorldWidthTiles * WorldHeightTiles)
  result.fb = initFramebuffer()
  loadPalette(palettePath())
  result.letterSprites = loadLetterSprites(lettersPath())
  result.villages = initVillages()
  result.gameProcesses = initTable[int, GameProcess]()
  result.proxies = initTable[int, ProxyConn]()

  for i in 0 ..< result.tiles.len:
    result.tiles[i] = TileGrass

  result.generateRiver()
  result.generateLakes()
  result.generateGrassVariation()
  result.generateTrees()

  for v in result.villages:
    result.placeVillage(v)

  for i in 0 ..< result.villages.len:
    for j in i + 1 ..< result.villages.len:
      let
        vi = result.villages[i]
        vj = result.villages[j]
        dx = abs(vi.tx - vj.tx)
        dy = abs(vi.ty - vj.ty)
      if dx + dy < 35:
        result.placeRoad(vi.tx, vi.ty, vj.tx, vj.ty)

  if result.villages.len > 0:
    var
      bestIdx = 0
      bestDist = high(int)
      cx = WorldWidthTiles div 2
      cy = WorldHeightTiles div 2
    for i, v in result.villages:
      let d = abs(v.tx - cx) + abs(v.ty - cy)
      if d < bestDist:
        bestDist = d
        bestIdx = i
    result.placeRoad(cx, cy, result.villages[bestIdx].tx, result.villages[bestIdx].ty)

proc tileColor(kind: TileKind): uint8 =
  case kind
  of TileGrass: ColorGrass
  of TileGrassDark: ColorGrassDark
  of TileRoad: ColorRoad
  of TileWater: ColorWater
  of TileWaterDeep: ColorWaterDeep
  of TileTree: ColorTree
  of TileVillage: ColorVillageFloor

proc villageAt(sim: SimServer, px, py: int): int =
  let
    centerX = px + PlayerSize div 2
    centerY = py + PlayerSize div 2
    tx = centerX div WorldTileSize
    ty = centerY div WorldTileSize
  for i, v in sim.villages:
    if abs(tx - v.tx) <= 2 and abs(ty - v.ty) <= 1:
      return i
  -1

proc findPlayerSpawn(sim: SimServer): tuple[x, y: int] =
  let
    centerX = (WorldWidthTiles div 2) * WorldTileSize
    centerY = (WorldHeightTiles div 2) * WorldTileSize
    minSpacingSq = MinPlayerSpawnSpacing * MinPlayerSpawnSpacing
  for radius in 0 .. 10:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          px = centerX + dx * WorldTileSize
          py = centerY + dy * WorldTileSize
        if not sim.canOccupy(px, py):
          continue
        var tooClose = false
        for p in sim.players:
          if distSq(px, py, p.x, p.y) < minSpacingSq:
            tooClose = true
            break
        if not tooClose:
          return (px, py)
  (centerX, centerY)

const PlayerColors = [14'u8, 11'u8, 2'u8, 10'u8, 3'u8, 15'u8]

proc addPlayer(sim: var SimServer): int =
  let spawn = sim.findPlayerSpawn()
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    facing: FaceDown,
    colorIndex: PlayerColors[sim.players.len mod PlayerColors.len],
    inVillage: -1,
    lastRewardVillage: -1,
  )
  sim.players.high

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState, attackPressed: bool) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  template player: untyped = sim.players[playerIndex]
  let nearbyVillage = sim.villageAt(player.x, player.y)

  if nearbyVillage < 0:
    player.lastRewardVillage = -1

  if attackPressed and player.inVillage < 0 and nearbyVillage >= 0:
    if nearbyVillage != player.lastRewardVillage:
      inc player.rewardTotal
      player.lastRewardVillage = nearbyVillage
    player.inVillage = nearbyVillage
    player.confirmReady = false
    player.velX = 0
    player.velY = 0
    return

  var inputX = 0
  var inputY = 0
  if input.left: dec inputX
  if input.right: inc inputX
  if input.up: dec inputY
  if input.down: inc inputY

  if inputX != 0:
    player.velX = clamp(player.velX + inputX * Accel, -MaxSpeed, MaxSpeed)
  else:
    player.velX = (player.velX * FrictionNum) div FrictionDen
    if abs(player.velX) < StopThreshold:
      player.velX = 0

  if inputY != 0:
    player.velY = clamp(player.velY + inputY * Accel, -MaxSpeed, MaxSpeed)
  else:
    player.velY = (player.velY * FrictionNum) div FrictionDen
    if abs(player.velY) < StopThreshold:
      player.velY = 0

  if inputX < 0: player.facing = FaceLeft
  elif inputX > 0: player.facing = FaceRight
  elif inputY < 0: player.facing = FaceUp
  elif inputY > 0: player.facing = FaceDown

  player.carryX += player.velX
  while abs(player.carryX) >= MotionScale:
    let step = (if player.carryX < 0: -1 else: 1)
    if sim.canOccupy(player.x + step, player.y):
      player.x += step
      player.carryX -= step * MotionScale
    else:
      player.carryX = 0
      player.velX = 0
      break

  player.carryY += player.velY
  while abs(player.carryY) >= MotionScale:
    let step = (if player.carryY < 0: -1 else: 1)
    if sim.canOccupy(player.x, player.y + step):
      player.y += step
      player.carryY -= step * MotionScale
    else:
      player.carryY = 0
      player.velY = 0
      break

proc worldClamp(v, maxV: int): int =
  clamp(v, 0, maxV)

proc fillRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  for py in y ..< y + h:
    for px in x ..< x + w:
      fb.putPixel(px, py, color)

proc renderWorld(sim: var SimServer, cameraX, cameraY: int) =
  let
    startTx = max(0, cameraX div WorldTileSize)
    startTy = max(0, cameraY div WorldTileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + ScreenWidth - 1) div WorldTileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + ScreenHeight - 1) div WorldTileSize)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        kind = sim.tiles[tileIndex(tx, ty)]
        screenX = tx * WorldTileSize - cameraX
        screenY = ty * WorldTileSize - cameraY
        color = tileColor(kind)

      if kind == TileTree:
        sim.fb.fillRect(screenX, screenY, WorldTileSize, WorldTileSize, ColorGrass)
        sim.fb.putPixel(screenX + 1, screenY, ColorTree)
        sim.fb.putPixel(screenX + 2, screenY, ColorTree)
        sim.fb.putPixel(screenX, screenY + 1, ColorTree)
        sim.fb.putPixel(screenX + 1, screenY + 1, ColorTree)
        sim.fb.putPixel(screenX + 2, screenY + 1, ColorTree)
        sim.fb.putPixel(screenX + 3, screenY + 1, ColorTree)
        sim.fb.putPixel(screenX + 1, screenY + 2, ColorTree)
        sim.fb.putPixel(screenX + 2, screenY + 2, ColorTree)
        sim.fb.putPixel(screenX + 1, screenY + 3, ColorTreeTrunk)
        sim.fb.putPixel(screenX + 2, screenY + 3, ColorTreeTrunk)
      elif kind == TileVillage:
        sim.fb.fillRect(screenX, screenY, WorldTileSize, WorldTileSize, ColorVillageFloor)
      else:
        sim.fb.fillRect(screenX, screenY, WorldTileSize, WorldTileSize, color)

proc renderVillageBuildings(sim: var SimServer, cameraX, cameraY: int) =
  for v in sim.villages:
    let
      bx = v.tx * WorldTileSize - 10 - cameraX
      by = v.ty * WorldTileSize - 6 - cameraY
      bw = 20
      bh = 14

    sim.fb.fillRect(bx + 1, by + 4, bw - 2, bh - 4, ColorVillageWall)

    for px in bx .. bx + bw - 1:
      let roofY = by + 3 - max(0, min(3, 3 - abs(px - (bx + bw div 2)) div 3))
      for py in roofY .. by + 4:
        sim.fb.putPixel(px, py, ColorVillageRoof)

    sim.fb.fillRect(bx + bw div 2 - 1, by + bh - 4, 3, 4, ColorVillageDoor)

proc renderVillageLabels(sim: var SimServer, cameraX, cameraY: int) =
  for v in sim.villages:
    let
      lineCount = v.lines.len
      baseY = v.ty * WorldTileSize - 14 - (lineCount - 1) * 7 - cameraY
    for i, line in v.lines:
      let
        textWidth = line.len * 6
        labelX = v.tx * WorldTileSize - textWidth div 2 - cameraX
        labelY = baseY + i * 7
      sim.fb.blitText(sim.letterSprites, line, labelX, labelY)

proc renderPlayers(sim: var SimServer, cameraX, cameraY: int) =
  for p in sim.players:
    let
      sx = p.x - cameraX
      sy = p.y - cameraY
    sim.fb.fillRect(sx, sy, PlayerSize, PlayerSize, p.colorIndex)
    case p.facing
    of FaceDown:
      sim.fb.putPixel(sx + 1, sy + 3, 1)
      sim.fb.putPixel(sx + 2, sy + 3, 1)
    of FaceUp:
      sim.fb.putPixel(sx + 1, sy, 1)
      sim.fb.putPixel(sx + 2, sy, 1)
    of FaceLeft:
      sim.fb.putPixel(sx, sy + 1, 1)
      sim.fb.putPixel(sx, sy + 2, 1)
    of FaceRight:
      sim.fb.putPixel(sx + 3, sy + 1, 1)
      sim.fb.putPixel(sx + 3, sy + 2, 1)

proc renderSelectionUI(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]
  if player.inVillage < 0:
    return
  let v = sim.villages[player.inVillage]

  let
    lineCount = v.lines.len
    boxH = 10 + lineCount * 7 + 10
    boxY = 32 - boxH div 2
  sim.fb.fillRect(8, boxY, 48, boxH, ColorTextBg)
  for px in 8 .. 55:
    sim.fb.putPixel(px, boxY, ColorSelectHighlight)
    sim.fb.putPixel(px, boxY + boxH - 1, ColorSelectHighlight)
  for py in boxY .. boxY + boxH - 1:
    sim.fb.putPixel(8, py, ColorSelectHighlight)
    sim.fb.putPixel(55, py, ColorSelectHighlight)

  for i, line in v.lines:
    let
      textWidth = line.len * 6
      textX = 32 - textWidth div 2
    sim.fb.blitText(sim.letterSprites, line, textX, boxY + 3 + i * 7)
  sim.fb.blitText(sim.letterSprites, "ENTER?", 14, boxY + boxH - 10)

proc render(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(ColorGrass)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let player = sim.players[playerIndex]
  let
    cameraX = worldClamp(
      player.x + PlayerSize div 2 - ScreenWidth div 2,
      WorldWidthPixels - ScreenWidth
    )
    cameraY = worldClamp(
      player.y + PlayerSize div 2 - ScreenHeight div 2,
      WorldHeightPixels - ScreenHeight
    )

  sim.renderWorld(cameraX, cameraY)
  sim.renderVillageBuildings(cameraX, cameraY)
  sim.renderVillageLabels(cameraX, cameraY)
  sim.renderPlayers(cameraX, cameraY)
  sim.renderSelectionUI(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildRewardPacket(sim: SimServer): string =
  for i in 0 ..< sim.players.len:
    result.add("reward ")
    result.add($i)
    result.add(" ")
    result.add($sim.players[i].rewardTotal)
    result.add("\n")

# --- Game process management ---

proc isGameRunning(sim: SimServer, villageIndex: int): bool =
  if villageIndex notin sim.gameProcesses:
    return false
  let gp = sim.gameProcesses[villageIndex]
  if gp.process.isNil:
    return false
  try:
    gp.process.peekExitCode() == -1
  except CatchableError:
    false

proc waitForPort(port: int): bool =
  let
    startedAt = getMonoTime()
    timeout = initDuration(milliseconds = GameServerReadyTimeoutMs)
  while getMonoTime() - startedAt < timeout:
    var socket: Socket
    try:
      socket = newSocket()
      socket.connect("127.0.0.1", Port(port))
      socket.close()
      return true
    except CatchableError:
      if not socket.isNil:
        try: socket.close()
        except CatchableError: discard
      sleep(GameServerPollMs)
  false

proc ensureGameRunning(sim: var SimServer, villageIndex: int): bool =
  if sim.isGameRunning(villageIndex):
    return true

  let v = sim.villages[villageIndex]
  let exePath = repoDir() / v.folder / v.folder
  if not fileExists(exePath):
    echo "Game executable not found: ", exePath
    return false

  let workDir = repoDir() / v.folder
  let portArg = "--port:" & $v.port
  echo "Starting game server: ", v.folder, " on port ", v.port
  try:
    let process = startProcess(
      exePath,
      workingDir = workDir,
      args = [portArg],
      options = {poParentStreams},
    )
    sim.gameProcesses[villageIndex] = GameProcess(
      process: process,
      port: v.port,
      ready: false,
    )
  except CatchableError as e:
    echo "Failed to start ", v.folder, ": ", e.msg
    return false

  if not waitForPort(v.port):
    echo "Game server ", v.folder, " did not become ready"
    return false

  sim.gameProcesses[villageIndex].ready = true
  echo "Game server ", v.folder, " ready on port ", v.port
  true

# --- Proxy connection management ---

proc closeProxy(sim: var SimServer, playerIndex: int) =
  if playerIndex notin sim.proxies:
    return
  let proxy = sim.proxies[playerIndex]
  if not proxy.ws.isNil:
    try: proxy.ws.close()
    except CatchableError: discard
  sim.proxies.del(playerIndex)

proc connectProxy(sim: var SimServer, playerIndex: int, villageIndex: int): bool =
  sim.closeProxy(playerIndex)
  let v = sim.villages[villageIndex]
  let url = "ws://127.0.0.1:" & $v.port & WebSocketPath
  try:
    let ws = whisky.newWebSocket(url)
    sim.proxies[playerIndex] = ProxyConn(
      state: ProxyActive,
      villageIndex: villageIndex,
      ws: ws,
      latestFrame: newSeq[uint8](ProtocolBytes),
      hasFrame: false,
      selectTimes: @[],
    )
    return true
  except CatchableError as e:
    echo "Proxy connect failed for ", v.folder, ": ", e.msg
    return false

proc checkSelectEscape(proxy: var ProxyConn, selectPressed: bool): bool =
  if not selectPressed:
    return false
  let now = getMonoTime()
  proxy.selectTimes.add(now)
  let cutoff = now - initDuration(milliseconds = SelectEscapeWindowMs)
  var fresh: seq[MonoTime]
  for t in proxy.selectTimes:
    if t >= cutoff:
      fresh.add(t)
  proxy.selectTimes = fresh
  proxy.selectTimes.len >= SelectEscapeCount

proc proxyTick(sim: var SimServer, playerIndex: int, inputMask: uint8, selectPressed: bool): bool =
  if playerIndex notin sim.proxies:
    return false
  var proxy = sim.proxies[playerIndex]

  if proxy.state != ProxyActive or proxy.ws.isNil:
    return false

  if proxy.checkSelectEscape(selectPressed):
    sim.closeProxy(playerIndex)
    return false

  try:
    let maskWithoutSelect = inputMask and (not ButtonSelect)
    proxy.ws.send(blobFromMask(maskWithoutSelect), BinaryMessage)
  except CatchableError:
    sim.closeProxy(playerIndex)
    return false

  try:
    while true:
      let msg = proxy.ws.receiveMessage(1)
      if msg.isNone:
        break
      if msg.get.kind == BinaryMessage and msg.get.data.len == ProtocolBytes:
        blobToBytes(msg.get.data, proxy.latestFrame)
        proxy.hasFrame = true
      elif msg.get.kind == Ping:
        proxy.ws.send(msg.get.data, Pong)
  except CatchableError:
    sim.closeProxy(playerIndex)
    return false

  sim.proxies[playerIndex] = proxy
  true

proc proxyFrame(sim: SimServer, playerIndex: int): seq[uint8] =
  if playerIndex in sim.proxies and sim.proxies[playerIndex].hasFrame:
    return sim.proxies[playerIndex].latestFrame
  newSeq[uint8](ProtocolBytes)

# --- Main loop ---

proc step(sim: var SimServer, inputs: seq[InputState], attackPressed: seq[bool]) =
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    let atkPressed =
      if playerIndex < attackPressed.len: attackPressed[playerIndex]
      else: false

    if sim.players[playerIndex].inVillage >= 0:
      if not input.attack:
        sim.players[playerIndex].confirmReady = true
      if input.b:
        sim.players[playerIndex].inVillage = -1
      continue

    sim.applyInput(playerIndex, input, atkPressed)

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[mummy.WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[mummy.WebSocket, uint8]()
  appState.playerIndices = initTable[mummy.WebSocket, int]()
  appState.closedSockets = @[]
  appState.rewardViewers = initTable[mummy.WebSocket, bool]()
  appState.resetRequested = false

proc removePlayer(sim: var SimServer, websocket: mummy.WebSocket) =
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket notin appState.playerIndices:
    return
  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)


  sim.closeProxy(removedIndex)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    # Reindex player indices
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value
    # Reindex proxy connections
    var newProxies = initTable[int, ProxyConn]()
    for idx, proxy in sim.proxies:
      if idx > removedIndex:
        newProxies[idx - 1] = proxy
      elif idx < removedIndex:
        newProxies[idx] = proxy
    sim.proxies = newProxies

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET":
    discard request.upgradeToWebSocket()
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
  websocket: mummy.WebSocket,
  event: WebSocketEvent,
  message: mummy.Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.rewardViewers:
          appState.playerIndices[websocket] = PendingPlayerIndex
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage and message.data.len == InputPacketBytes:
      {.gcsafe.}:
        withLock appState.lock:
          let mask = blobToMask(message.data)
          if mask == ResetInputMask:
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

proc runFrameLimiter(previousTick: var MonoTime, targetFps: int) =
  if targetFps <= 0:
    previousTick = getMonoTime()
    return
  let frameDuration = initDuration(microseconds = (1_000_000 * FpsScale) div targetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop(
  host = DefaultHost,
  port = DefaultPort,
  targetFps = TargetFps,
  seed = 0xDEAD
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
      sockets: seq[mummy.WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]
      attackFlags: seq[bool]
      selectFlags: seq[bool]
      masks: seq[uint8]
      shouldReset = false
      rewardViewers: seq[mummy.WebSocket] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        if appState.resetRequested:
          shouldReset = true
          appState.resetRequested = false
          for _, value in appState.playerIndices.mpairs:
            value = PendingPlayerIndex
          for _, value in appState.inputMasks.mpairs:
            value = 0
          for _, value in appState.lastAppliedMasks.mpairs:
            value = 0
        else:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == PendingPlayerIndex:
              appState.playerIndices[websocket] = sim.addPlayer()


          inputs = newSeq[InputState](sim.players.len)
          attackFlags = newSeq[bool](sim.players.len)
          selectFlags = newSeq[bool](sim.players.len)
          masks = newSeq[uint8](sim.players.len)
          for websocket, playerIndex in appState.playerIndices.pairs:
            if playerIndex < 0 or playerIndex >= inputs.len:
              continue
            let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
            inputs[playerIndex] = decodeInputMask(currentMask)
            attackFlags[playerIndex] = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
            selectFlags[playerIndex] = (currentMask and ButtonSelect) != 0 and (previousMask and ButtonSelect) == 0
            masks[playerIndex] = currentMask
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
            if appState.playerIndices[websocket] == PendingPlayerIndex:
              appState.playerIndices[websocket] = sim.addPlayer()
            sockets.add(websocket)
            playerIndices.add(appState.playerIndices[websocket])
      for i in 0 ..< sockets.len:
        let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
        sockets[i].send(frameBlob, BinaryMessage)
      let rewardPacket = sim.buildRewardPacket()
      for websocket in rewardViewers:
        websocket.send(rewardPacket, TextMessage)
      runFrameLimiter(lastTick, targetFps)
      continue


    # Handle enter-village transitions (only on fresh A press after release)
    for i in 0 ..< sockets.len:
      let pi = playerIndices[i]
      if pi < 0 or pi >= sim.players.len:
        continue
      let player = sim.players[pi]

      if player.inVillage >= 0 and player.confirmReady and pi notin sim.proxies:
        if attackFlags[pi]:
          let vi = player.inVillage
          if sim.ensureGameRunning(vi):
            if sim.connectProxy(pi, vi):
              sim.players[pi].inVillage = -1

    # Tick proxied players and overworld
    var proxiedPlayers: seq[int]
    for i in 0 ..< sockets.len:
      let pi = playerIndices[i]
      if pi in sim.proxies:
        let sel = selectFlags[pi]
        if sim.proxyTick(pi, masks[pi], sel):
          proxiedPlayers.add(pi)

    sim.step(inputs, attackFlags)

    # Send frames
    for i in 0 ..< sockets.len:
      let pi = playerIndices[i]
      var frameBlob: string
      if pi in proxiedPlayers:
        frameBlob = blobFromBytes(sim.proxyFrame(pi))
      else:
        frameBlob = blobFromBytes(sim.render(pi))
      sockets[i].send(frameBlob, BinaryMessage)

    let rewardPacket = sim.buildRewardPacket()
    for websocket in rewardViewers:
      websocket.send(rewardPacket, TextMessage)

    runFrameLimiter(lastTick, targetFps)

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
  if node.hasKey("fps"):
    var fps = 0
    node.readConfigInt("fps", fps)
    if fps < 0:
      raise newException(ValueError, "Config field fps must not be negative.")
    config.targetFps = fps * FpsScale
  node.readConfigInt("seed", config.seed)

when isMainModule:
  var
    config = RunConfig(address: DefaultHost, port: DefaultPort, targetFps: TargetFps, seed: 0xDEAD)
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
  runServerLoop(config.address, config.port, targetFps = config.targetFps, seed = config.seed)

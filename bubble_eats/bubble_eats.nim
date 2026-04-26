import mummy
import protocol
import server
import std/[algorithm, locks, monotimes, os, parseopt, random, strutils, tables, times]

const
  SubpixelScale = 16
  WorldWidthPixels = 1000
  WorldHeightPixels = 1000
  WorldWidthSubpixels = WorldWidthPixels * SubpixelScale
  WorldHeightSubpixels = WorldHeightPixels * SubpixelScale

  BlobWidth = 24
  BlobHeight = 18
  BlobShadowWidth = 18
  BlobShadowHeight = 6
  BlobHalfWidthSubpixels = (BlobWidth div 2) * SubpixelScale
  BlobHalfHeightSubpixels = (BlobHeight div 2) * SubpixelScale
  SpawnSpacingPixels = 28

  PillWidth = 8
  PillHeight = 5
  PillShadowWidth = 10
  PillShadowHeight = 4
  PillSpawnHeightMin = 40
  PillSpawnHeightMax = 84
  PillFallSpeedMin = 4
  PillFallSpeedMax = 7
  InitialLandedPillCount = 220
  TargetPillCount = 280
  MaxPillCount = 320
  PillSpacingPixels = 12
  EatDistancePixels = 14

  LinkAcquireDistancePixels = 20
  LinkRestDistancePixels = 18
  MagnetDistancePixels = 28
  LinkAcquireDistance = LinkAcquireDistancePixels * SubpixelScale
  LinkRestDistance = LinkRestDistancePixels * SubpixelScale
  MagnetDistance = MagnetDistancePixels * SubpixelScale
  SeparationDistance = 16 * SubpixelScale
  LinkAcquireDistanceSq = LinkAcquireDistance * LinkAcquireDistance
  MagnetDistanceSq = MagnetDistance * MagnetDistance
  SeparationDistanceSq = SeparationDistance * SeparationDistance
  EatDistanceSq = EatDistancePixels * EatDistancePixels

  BaseMaxSpeed = 36
  LinkSpeedBonus = 8
  InputAccel = 5
  GroupAssistBase = 2
  DragNumerator = 14
  DragDenominator = 16
  StopThreshold = 1
  ForceScale = 1000
  BreakThreshold = 36
  BreakDecay = 2
  BreakBurst = 20
  UnlinkCooldownTicks = 24

  BlinkTicks = 5
  FrownTicks = 12
  ChewTicks = 18
  AutoBlinkMin = 48
  AutoBlinkMax = 140

  TargetFps = 24
  WebSocketPath = "/player"
  FieldColor = 15'u8
  FieldAccentColor = 11'u8
  FieldPebbleColor = 1'u8
  ShadowColor = 1'u8
  EyeWhite = 2'u8
  EyePupil = 0'u8
  MouthColor = 0'u8
  MouthHighlight = 4'u8

  BlobRowWidths: array[BlobHeight, int] = [
    12, 16, 18, 20, 22, 22, 22, 24, 24,
    24, 24, 24, 22, 22, 22, 20, 18, 16
  ]
  BlobShadowRowWidths: array[BlobShadowHeight, int] = [10, 16, 18, 18, 16, 10]
  PillRowWidths: array[PillHeight, int] = [4, 6, 8, 8, 6]
  PillShadowRowWidths: array[PillShadowHeight, int] = [6, 8, 10, 8]

type
  BlobPalette = object
    body: uint8
    highlight: uint8
    outline: uint8

  PillKind = enum
    PillRed
    PillBlue
    PillYellow
    PillGreen

  Pill = object
    id: int
    x: int
    y: int
    z: int
    fallSpeed: int
    kind: PillKind

  PlayerInput = object
    inputX: int
    inputY: int
    blinkPressed: bool
    frownPressed: bool

  Player = object
    id: int
    x: int
    y: int
    velX: int
    velY: int
    lookX: int
    lookY: int
    score: int
    chewTicks: int
    blinkTicks: int
    frownTicks: int
    autoBlinkTimer: int
    detachCharge: int
    unlinkCooldown: int
    colorIndex: int
    componentSize: int

  Link = object
    aId: int
    bId: int

  RenderKind = enum
    RenderPill
    RenderPlayer

  RenderEntry = object
    sortY: int
    kind: RenderKind
    index: int

  SimServer = object
    players: seq[Player]
    pills: seq[Pill]
    links: seq[Link]
    digitSprites: array[10, Sprite]
    fb: Framebuffer
    rng: Rand
    nextPlayerId: int
    nextPillId: int
    pillSpawnCooldown: int

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

proc isqrt(value: int): int =
  if value <= 0:
    return 0
  var
    x = value
    y = (x + 1) div 2
  while y < x:
    x = y
    y = (x + value div x) div 2
  x

proc ceilSqrt(value: int): int =
  result = isqrt(value)
  if result * result < value:
    inc result

proc roundDiv(numerator, denominator: int): int =
  if denominator <= 0:
    return 0
  if numerator >= 0:
    (numerator + denominator div 2) div denominator
  else:
    -((-numerator + denominator div 2) div denominator)

proc mulDivRound(a, b, denominator: int): int =
  roundDiv(a * b, denominator)

proc scaledVector(dx, dy, scale: int): tuple[x, y: int] =
  let distance = ceilSqrt(dx * dx + dy * dy)
  if distance <= 0:
    return (x: 0, y: 0)
  (x: mulDivRound(dx, scale, distance), y: mulDivRound(dy, scale, distance))

proc clampVectorLength(x, y: var int, maxLength: int) =
  let lengthSq = x * x + y * y
  if lengthSq <= maxLength * maxLength:
    return
  let length = ceilSqrt(lengthSq)
  if length <= 0:
    return
  x = mulDivRound(x, maxLength, length)
  y = mulDivRound(y, maxLength, length)

var appState: WebSocketAppState

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "client" / "data"

proc palettePath(): string =
  clientDataDir() / "pallete.png"

proc numbersPath(): string =
  clientDataDir() / "numbers.png"

proc signOf(value: int): int =
  if value < 0:
    -1
  elif value > 0:
    1
  else:
    0

proc clampVelocity(velX, velY: var int, maxSpeed: int) =
  clampVectorLength(velX, velY, maxSpeed)

proc applyDrag(value: var int) =
  value = (value * DragNumerator) div DragDenominator
  if abs(value) <= StopThreshold:
    value = 0

proc pairKey(a, b: int): int64 =
  let
    lo = min(a, b)
    hi = max(a, b)
  (int64(lo) shl 32) or int64(uint32(hi))

proc blobPaletteFor(colorIndex: int): BlobPalette =
  case colorIndex mod 8
  of 0: BlobPalette(body: 3, highlight: 4, outline: 5)
  of 1: BlobPalette(body: 14, highlight: 15, outline: 13)
  of 2: BlobPalette(body: 10, highlight: 11, outline: 9)
  of 3: BlobPalette(body: 8, highlight: 2, outline: 6)
  of 4: BlobPalette(body: 7, highlight: 8, outline: 6)
  of 5: BlobPalette(body: 4, highlight: 2, outline: 3)
  of 6: BlobPalette(body: 15, highlight: 2, outline: 1)
  else: BlobPalette(body: 9, highlight: 14, outline: 12)

proc pillColors(kind: PillKind): tuple[body, highlight, outline: uint8] =
  case kind
  of PillRed:
    (3'u8, 2'u8, 5'u8)
  of PillBlue:
    (14'u8, 15'u8, 13'u8)
  of PillYellow:
    (8'u8, 2'u8, 6'u8)
  of PillGreen:
    (11'u8, 15'u8, 10'u8)

proc distanceSquared(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc vectorsOpposed(ax, ay, bx, by: int): bool =
  let
    dot = ax * bx + ay * by
    lenASq = ax * ax + ay * ay
    lenBSq = bx * bx + by * by
  if dot >= 0 or lenASq <= 0 or lenBSq <= 0:
    return false
  dot * dot * 10_000 >= 2_025 * lenASq * lenBSq

proc desiredVector(input: PlayerInput): tuple[x, y: int] =
  if input.inputX != 0 and input.inputY != 0:
    (input.inputX * 11, input.inputY * 11)
  else:
    (input.inputX * 16, input.inputY * 16)

proc worldClampPixel(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc playerPixelX(player: Player): int =
  player.x div SubpixelScale

proc playerPixelY(player: Player): int =
  player.y div SubpixelScale

proc playerGroundY(player: Player): int =
  player.playerPixelY() + BlobHeight div 2 - 1

proc playerTopLeft(player: Player): tuple[x, y: int] =
  (
    player.playerPixelX() - BlobWidth div 2,
    player.playerPixelY() - BlobHeight div 2
  )

proc blobInside(localX, localY: int): bool =
  if localX < 0 or localY < 0 or localX >= BlobWidth or localY >= BlobHeight:
    return false
  let width = BlobRowWidths[localY]
  let startX = (BlobWidth - width) div 2
  localX >= startX and localX < startX + width

proc pillInside(localX, localY: int): bool =
  if localX < 0 or localY < 0 or localX >= PillWidth or localY >= PillHeight:
    return false
  let width = PillRowWidths[localY]
  let startX = (PillWidth - width) div 2
  localX >= startX and localX < startX + width

proc drawRowShape(
  fb: var Framebuffer,
  rowWidths: openArray[int],
  maxWidth, leftX, topY: int,
  color: uint8
) =
  for localY, width in rowWidths:
    let startX = leftX + (maxWidth - width) div 2
    for localX in 0 ..< width:
      fb.putPixel(startX + localX, topY + localY, color)

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

proc noiseHash(x, y: int): uint32 =
  var n = uint32((x * 73856093) xor (y * 19349663) xor 0x9e3779b9'u32.int)
  n = n xor (n shr 13)
  n *= 1274126177'u32
  n xor (n shr 16)

proc renderGround(sim: var SimServer, cameraX, cameraY: int) =
  sim.fb.clearFrame(FieldColor)

  let
    startCellX = max(0, cameraX div 4 - 1)
    startCellY = max(0, cameraY div 4 - 1)
    endCellX = min(WorldWidthPixels div 4, (cameraX + ScreenWidth) div 4 + 1)
    endCellY = min(WorldHeightPixels div 4, (cameraY + ScreenHeight) div 4 + 1)

  for cellY in startCellY .. endCellY:
    for cellX in startCellX .. endCellX:
      let
        hash = noiseHash(cellX, cellY)
        screenX = cellX * 4 - cameraX
        screenY = cellY * 4 - cameraY
      if (hash and 0x3'u32) == 0'u32:
        sim.fb.putPixel(screenX + 1, screenY + 1, FieldAccentColor)
      if (hash and 0x1F'u32) == 1'u32:
        sim.fb.putPixel(screenX + 2, screenY + 2, FieldPebbleColor)
      if (hash and 0x7F'u32) == 2'u32:
        sim.fb.putPixel(screenX, screenY + 3, 8)

proc drawBlobEyes(
  sim: var SimServer,
  screenX, screenY, lookX, lookY: int,
  blinking: bool
) =
  let
    leftEyeX = screenX + 7
    rightEyeX = screenX + 15
    eyeY = screenY + 6
    pupilShiftX = lookX.clamp(-1, 1)
    pupilShiftY = lookY.clamp(-1, 1)

  if blinking:
    for dx in 0 .. 2:
      sim.fb.putPixel(leftEyeX + dx, eyeY + 1, MouthColor)
      sim.fb.putPixel(rightEyeX + dx, eyeY + 1, MouthColor)
    return

  for dy in 0 .. 1:
    for dx in 0 .. 2:
      sim.fb.putPixel(leftEyeX + dx, eyeY + dy, EyeWhite)
      sim.fb.putPixel(rightEyeX + dx, eyeY + dy, EyeWhite)

  sim.fb.putPixel(leftEyeX + 1 + pupilShiftX, eyeY + (if pupilShiftY > 0: 1 else: 0), EyePupil)
  sim.fb.putPixel(rightEyeX + 1 + pupilShiftX, eyeY + (if pupilShiftY > 0: 1 else: 0), EyePupil)

proc drawBlobMouth(sim: var SimServer, player: Player, screenX, screenY: int) =
  let
    mouthX = screenX + 9
    mouthY = screenY + 12

  if player.chewTicks > 0:
    if (player.chewTicks div 3) mod 2 == 0:
      for dx in 0 .. 5:
        sim.fb.putPixel(mouthX + dx, mouthY + 1, MouthColor)
      for dx in 1 .. 4:
        sim.fb.putPixel(mouthX + dx, mouthY + 2, MouthHighlight)
    else:
      for dx in 1 .. 4:
        sim.fb.putPixel(mouthX + dx, mouthY + 1, MouthColor)
        sim.fb.putPixel(mouthX + dx, mouthY + 2, MouthColor)
    return

  if player.frownTicks > 0:
    sim.fb.putPixel(mouthX, mouthY + 2, MouthColor)
    sim.fb.putPixel(mouthX + 1, mouthY + 1, MouthColor)
    sim.fb.putPixel(mouthX + 2, mouthY + 1, MouthColor)
    sim.fb.putPixel(mouthX + 3, mouthY + 1, MouthColor)
    sim.fb.putPixel(mouthX + 4, mouthY + 1, MouthColor)
    sim.fb.putPixel(mouthX + 5, mouthY + 2, MouthColor)
  else:
    sim.fb.putPixel(mouthX, mouthY + 1, MouthColor)
    sim.fb.putPixel(mouthX + 1, mouthY + 2, MouthColor)
    sim.fb.putPixel(mouthX + 2, mouthY + 2, MouthColor)
    sim.fb.putPixel(mouthX + 3, mouthY + 2, MouthColor)
    sim.fb.putPixel(mouthX + 4, mouthY + 2, MouthColor)
    sim.fb.putPixel(mouthX + 5, mouthY + 1, MouthColor)

proc renderBlob(sim: var SimServer, player: Player, cameraX, cameraY: int) =
  let
    palette = blobPaletteFor(player.colorIndex)
    topLeft = player.playerTopLeft()
    screenX = topLeft.x - cameraX
    screenY = topLeft.y - cameraY
    shadowLeft = player.playerPixelX() - BlobShadowWidth div 2 - cameraX
    shadowTop = player.playerGroundY() - BlobShadowHeight div 2 - cameraY

  sim.fb.drawRowShape(
    BlobShadowRowWidths,
    BlobShadowWidth,
    shadowLeft,
    shadowTop,
    ShadowColor
  )

  for localY in 0 ..< BlobHeight:
    for localX in 0 ..< BlobWidth:
      if not blobInside(localX, localY):
        continue

      var color = palette.body
      if not blobInside(localX - 1, localY) or
          not blobInside(localX + 1, localY) or
          not blobInside(localX, localY - 1) or
          not blobInside(localX, localY + 1):
        color = palette.outline
      elif localY <= 6 and localX >= 4 and localX <= 9:
        color = palette.highlight
      elif localY <= 4 and localX >= 3 and localX <= 7:
        color = palette.highlight

      sim.fb.putPixel(screenX + localX, screenY + localY, color)

  sim.drawBlobEyes(screenX, screenY, player.lookX, player.lookY, player.blinkTicks > 0)
  sim.drawBlobMouth(player, screenX, screenY)

  let
    bubbleCount = max(1, min(9, player.componentSize))
    counterX = screenX + BlobWidth div 2 - sim.digitSprites[0].width div 2
    counterY = screenY - 6
  sim.fb.renderNumber(sim.digitSprites, bubbleCount, counterX, counterY)

proc renderPill(sim: var SimServer, pill: Pill, cameraX, cameraY: int) =
  let
    colors = pill.kind.pillColors()
    shadowLeft = pill.x - PillShadowWidth div 2 - cameraX
    shadowTop = pill.y - PillShadowHeight div 2 - cameraY
    topLeftX = pill.x - PillWidth div 2 - cameraX
    topLeftY = pill.y - PillHeight - pill.z - cameraY

  sim.fb.drawRowShape(PillShadowRowWidths, PillShadowWidth, shadowLeft, shadowTop, ShadowColor)

  for localY in 0 ..< PillHeight:
    for localX in 0 ..< PillWidth:
      if not pillInside(localX, localY):
        continue

      var color = colors.body
      if not pillInside(localX - 1, localY) or
          not pillInside(localX + 1, localY) or
          not pillInside(localX, localY - 1) or
          not pillInside(localX, localY + 1):
        color = colors.outline
      elif localY <= 1 and localX >= 4:
        color = colors.highlight

      sim.fb.putPixel(topLeftX + localX, topLeftY + localY, color)

proc buildIndexById(sim: SimServer): Table[int, int] =
  result = initTable[int, int]()
  for i, player in sim.players:
    result[player.id] = i

proc isLinked(sim: SimServer, aId, bId: int): bool =
  let key = pairKey(aId, bId)
  for link in sim.links:
    if pairKey(link.aId, link.bId) == key:
      return true
  false

proc addLink(sim: var SimServer, aId, bId: int) =
  if aId == bId or sim.isLinked(aId, bId):
    return
  let
    lo = min(aId, bId)
    hi = max(aId, bId)
  sim.links.add(Link(aId: lo, bId: hi))

proc filterActiveLinks(sim: var SimServer) =
  let idToIndex = sim.buildIndexById()
  var
    kept: seq[Link] = @[]
    seen = initTable[int64, bool]()

  for link in sim.links:
    if link.aId == link.bId:
      continue
    if not idToIndex.hasKey(link.aId) or not idToIndex.hasKey(link.bId):
      continue
    let key = pairKey(link.aId, link.bId)
    if seen.hasKey(key):
      continue
    seen[key] = true
    kept.add(link)

  sim.links = kept

proc buildAdjacency(sim: SimServer, idToIndex: Table[int, int]): seq[seq[int]] =
  result = newSeq[seq[int]](sim.players.len)
  for link in sim.links:
    if idToIndex.hasKey(link.aId) and idToIndex.hasKey(link.bId):
      let
        a = idToIndex[link.aId]
        b = idToIndex[link.bId]
      result[a].add(b)
      result[b].add(a)

proc computeComponents(sim: SimServer): seq[seq[int]] =
  let
    idToIndex = sim.buildIndexById()
    adjacency = sim.buildAdjacency(idToIndex)
  var seen = newSeq[bool](sim.players.len)

  for startIndex in 0 ..< sim.players.len:
    if seen[startIndex]:
      continue

    var
      stack = @[startIndex]
      component: seq[int] = @[]
    seen[startIndex] = true

    while stack.len > 0:
      let current = stack[^1]
      stack.setLen(stack.len - 1)
      component.add(current)
      for nextIndex in adjacency[current]:
        if seen[nextIndex]:
          continue
        seen[nextIndex] = true
        stack.add(nextIndex)
    result.add(component)

proc assignComponentSizes(sim: var SimServer, components: openArray[seq[int]]) =
  for player in sim.players.mitems:
    player.componentSize = 1
  for component in components:
    for playerIndex in component:
      sim.players[playerIndex].componentSize = component.len

proc randomBlinkTimer(sim: var SimServer): int =
  AutoBlinkMin + sim.rng.rand(AutoBlinkMax - AutoBlinkMin)

proc clampPlayerToWorld(player: var Player) =
  let
    minX = BlobHalfWidthSubpixels
    maxX = WorldWidthSubpixels - BlobHalfWidthSubpixels
    minY = BlobHalfHeightSubpixels
    maxY = WorldHeightSubpixels - BlobHalfHeightSubpixels

  if player.x < minX:
    player.x = minX
    if player.velX < 0:
      player.velX = 0
  elif player.x > maxX:
    player.x = maxX
    if player.velX > 0:
      player.velX = 0

  if player.y < minY:
    player.y = minY
    if player.velY < 0:
      player.velY = 0
  elif player.y > maxY:
    player.y = maxY
    if player.velY > 0:
      player.velY = 0

proc findPlayerSpawn(sim: SimServer): tuple[x, y: int] =
  let
    centerX = WorldWidthSubpixels div 2
    centerY = WorldHeightSubpixels div 2
    step = SpawnSpacingPixels * SubpixelScale
    minSpacingSq = (SpawnSpacingPixels * SubpixelScale) * (SpawnSpacingPixels * SubpixelScale)

  for ring in 0 .. 10:
    for dy in -ring .. ring:
      for dx in -ring .. ring:
        if ring > 0 and max(abs(dx), abs(dy)) != ring:
          continue

        let
          px = centerX + dx * step
          py = centerY + dy * step
        if px < BlobHalfWidthSubpixels or px > WorldWidthSubpixels - BlobHalfWidthSubpixels:
          continue
        if py < BlobHalfHeightSubpixels or py > WorldHeightSubpixels - BlobHalfHeightSubpixels:
          continue

        var tooClose = false
        for player in sim.players:
          if distanceSquared(px, py, player.x, player.y) < minSpacingSq:
            tooClose = true
            break
        if not tooClose:
          return (px, py)

  (centerX, centerY)

proc addPlayer(sim: var SimServer): int =
  let spawn = sim.findPlayerSpawn()
  sim.players.add Player(
    id: sim.nextPlayerId,
    x: spawn.x,
    y: spawn.y,
    autoBlinkTimer: sim.randomBlinkTimer(),
    colorIndex: sim.nextPlayerId,
    componentSize: 1
  )
  inc sim.nextPlayerId
  sim.players.high

proc randomPillKind(sim: var SimServer): PillKind =
  PillKind(sim.rng.rand(ord(high(PillKind))))

proc pillSpawnPoint(sim: var SimServer): tuple[x, y: int, ok: bool] =
  let minSpacingSq = PillSpacingPixels * PillSpacingPixels
  for _ in 0 ..< 48:
    let
      px = 16 + sim.rng.rand(WorldWidthPixels - 32)
      py = 16 + sim.rng.rand(WorldHeightPixels - 32)
    var tooClose = false
    for pill in sim.pills:
      if distanceSquared(px, py, pill.x, pill.y) < minSpacingSq:
        tooClose = true
        break
    if tooClose:
      continue
    return (px, py, true)
  (0, 0, false)

proc addPill(sim: var SimServer, airborne: bool) =
  if sim.pills.len >= MaxPillCount:
    return
  let spot = sim.pillSpawnPoint()
  if not spot.ok:
    return

  sim.pills.add Pill(
    id: sim.nextPillId,
    x: spot.x,
    y: spot.y,
    z: if airborne: PillSpawnHeightMin + sim.rng.rand(PillSpawnHeightMax - PillSpawnHeightMin) else: 0,
    fallSpeed: PillFallSpeedMin + sim.rng.rand(PillFallSpeedMax - PillFallSpeedMin),
    kind: sim.randomPillKind()
  )
  inc sim.nextPillId

proc initSimServer(): SimServer =
  result.fb = initFramebuffer()
  result.rng = initRand(0xB177E45)
  loadPalette(palettePath())
  result.digitSprites = loadDigitSprites(numbersPath())
  result.pillSpawnCooldown = 2
  for _ in 0 ..< InitialLandedPillCount:
    result.addPill(false)

proc updateExpressionTimers(sim: var SimServer, inputs: openArray[PlayerInput]) =
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len:
        inputs[playerIndex]
      else:
        PlayerInput()

    if input.blinkPressed:
      sim.players[playerIndex].blinkTicks = BlinkTicks
      sim.players[playerIndex].autoBlinkTimer = sim.randomBlinkTimer()
    if input.frownPressed:
      sim.players[playerIndex].frownTicks = FrownTicks
    if sim.players[playerIndex].chewTicks > 0:
      dec sim.players[playerIndex].chewTicks
    if sim.players[playerIndex].blinkTicks > 0:
      dec sim.players[playerIndex].blinkTicks
    if sim.players[playerIndex].frownTicks > 0:
      dec sim.players[playerIndex].frownTicks
    if sim.players[playerIndex].unlinkCooldown > 0:
      dec sim.players[playerIndex].unlinkCooldown

    dec sim.players[playerIndex].autoBlinkTimer
    if sim.players[playerIndex].autoBlinkTimer <= 0:
      sim.players[playerIndex].blinkTicks = max(sim.players[playerIndex].blinkTicks, BlinkTicks)
      sim.players[playerIndex].autoBlinkTimer = sim.randomBlinkTimer()

proc refreshLinks(sim: var SimServer) =
  sim.filterActiveLinks()
  for i in 0 ..< sim.players.len:
    for j in i + 1 ..< sim.players.len:
      if sim.players[i].unlinkCooldown > 0 or sim.players[j].unlinkCooldown > 0:
        continue
      if distanceSquared(
        sim.players[i].x,
        sim.players[i].y,
        sim.players[j].x,
        sim.players[j].y
      ) <= LinkAcquireDistanceSq:
        sim.addLink(sim.players[i].id, sim.players[j].id)

proc freePlayerFromComponent(sim: var SimServer, playerId: int, component: seq[int]) =
  let idToIndex = sim.buildIndexById()
  if not idToIndex.hasKey(playerId):
    return

  let playerIndex = idToIndex[playerId]
  var
    centroidX = 0
    centroidY = 0
    count = 0
  for otherIndex in component:
    if sim.players[otherIndex].id == playerId:
      continue
    centroidX += sim.players[otherIndex].x
    centroidY += sim.players[otherIndex].y
    inc count

  var kept: seq[Link] = @[]
  for link in sim.links:
    if link.aId != playerId and link.bId != playerId:
      kept.add(link)
  sim.links = kept

  sim.players[playerIndex].detachCharge = 0
  sim.players[playerIndex].unlinkCooldown = UnlinkCooldownTicks

  if count <= 0:
    return

  centroidX = centroidX div count
  centroidY = centroidY div count
  var
    dx = sim.players[playerIndex].x - centroidX
    dy = sim.players[playerIndex].y - centroidY
  if dx == 0 and dy == 0:
    dx = SubpixelScale
  let burst = scaledVector(dx, dy, BreakBurst)
  sim.players[playerIndex].velX += burst.x
  sim.players[playerIndex].velY += burst.y

proc updateDetachCharges(sim: var SimServer, components: openArray[seq[int]], inputs: openArray[PlayerInput]) =
  var playersToFree: seq[int] = @[]

  for component in components:
    if component.len <= 1:
      let playerIndex = component[0]
      sim.players[playerIndex].detachCharge = max(0, sim.players[playerIndex].detachCharge - BreakDecay)
      continue

    for playerIndex in component:
      let mine =
        if playerIndex < inputs.len:
          inputs[playerIndex].desiredVector()
        else:
          (x: 0, y: 0)

      var
        otherX = 0
        otherY = 0
      for otherIndex in component:
        if otherIndex == playerIndex or otherIndex >= inputs.len:
          continue
        let other = inputs[otherIndex].desiredVector()
        otherX += other.x
        otherY += other.y

      if (mine.x == 0 and mine.y == 0) or (otherX == 0 and otherY == 0):
        sim.players[playerIndex].detachCharge = max(0, sim.players[playerIndex].detachCharge - BreakDecay)
      else:
        if vectorsOpposed(mine.x, mine.y, otherX, otherY):
          inc sim.players[playerIndex].detachCharge
        else:
          sim.players[playerIndex].detachCharge = max(0, sim.players[playerIndex].detachCharge - BreakDecay)

      if sim.players[playerIndex].detachCharge >= BreakThreshold:
        var alreadyQueued = false
        for queuedId in playersToFree:
          if queuedId == sim.players[playerIndex].id:
            alreadyQueued = true
            break
        if not alreadyQueued:
          playersToFree.add(sim.players[playerIndex].id)

  for playerId in playersToFree:
    for component in components:
      var inComponent = false
      for playerIndex in component:
        if sim.players[playerIndex].id == playerId:
          inComponent = true
          break
      if inComponent:
        sim.freePlayerFromComponent(playerId, component)
        break

proc applyMovement(sim: var SimServer, components: openArray[seq[int]], inputs: openArray[PlayerInput]) =
  for component in components:
    var
      sumDesiredX = 0
      sumDesiredY = 0
    for playerIndex in component:
      let desired =
        if playerIndex < inputs.len:
          inputs[playerIndex].desiredVector()
        else:
          (x: 0, y: 0)
      sumDesiredX += desired.x
      sumDesiredY += desired.y

    let
      componentSize = component.len
      averageDesiredX =
        if componentSize > 0:
          sumDesiredX div componentSize
        else:
          0
      averageDesiredY =
        if componentSize > 0:
          sumDesiredY div componentSize
        else:
          0
      alignmentDenominator = max(1, componentSize * 16)
      alignmentNumerator = min(alignmentDenominator, isqrt(sumDesiredX * sumDesiredX + sumDesiredY * sumDesiredY))
      groupBoost = mulDivRound(max(0, componentSize - 1) * GroupAssistBase, alignmentNumerator, alignmentDenominator)

    for playerIndex in component:
      let desired =
        if playerIndex < inputs.len:
          inputs[playerIndex].desiredVector()
        else:
          (x: 0, y: 0)

      if desired.x == 0:
        applyDrag(sim.players[playerIndex].velX)
      else:
        sim.players[playerIndex].velX += desired.x * InputAccel div 16

      if desired.y == 0:
        applyDrag(sim.players[playerIndex].velY)
      else:
        sim.players[playerIndex].velY += desired.y * InputAccel div 16

      if groupBoost > 0:
        sim.players[playerIndex].velX += averageDesiredX * groupBoost div 16
        sim.players[playerIndex].velY += averageDesiredY * groupBoost div 16

      clampVelocity(
        sim.players[playerIndex].velX,
        sim.players[playerIndex].velY,
        BaseMaxSpeed + max(0, componentSize - 1) * LinkSpeedBonus
      )

      if desired.x != 0 or desired.y != 0:
        sim.players[playerIndex].lookX = signOf(desired.x)
        sim.players[playerIndex].lookY = signOf(desired.y)
      else:
        sim.players[playerIndex].lookX = signOf(sim.players[playerIndex].velX)
        sim.players[playerIndex].lookY = signOf(sim.players[playerIndex].velY)

proc buildLinkedPairTable(sim: SimServer): Table[int64, bool] =
  result = initTable[int64, bool]()
  for link in sim.links:
    result[pairKey(link.aId, link.bId)] = true

proc applyPairForces(sim: var SimServer, linkedPairs: Table[int64, bool]) =
  for i in 0 ..< sim.players.len:
    for j in i + 1 ..< sim.players.len:
      let
        dx = sim.players[j].x - sim.players[i].x
        dy = sim.players[j].y - sim.players[i].y
        distSq = dx * dx + dy * dy
      if distSq <= 0:
        sim.players[i].x -= 1
        sim.players[j].x += 1
        continue

      let linked = linkedPairs.hasKey(pairKey(sim.players[i].id, sim.players[j].id))
      if not linked and distSq > MagnetDistanceSq:
        continue

      let dist = ceilSqrt(distSq)

      if linked:
        let impulse = max(
          -3 * ForceScale,
          min(
            3 * ForceScale,
            mulDivRound(dist - LinkRestDistance, ForceScale, SubpixelScale * 12)
          )
        )
        let
          shiftX = mulDivRound(dx, impulse, dist * ForceScale)
          shiftY = mulDivRound(dy, impulse, dist * ForceScale)
        sim.players[i].velX += shiftX
        sim.players[i].velY += shiftY
        sim.players[j].velX -= shiftX
        sim.players[j].velY -= shiftY
      else:
        let impulse = min(
          2 * ForceScale,
          mulDivRound(max(0, MagnetDistance - dist), ForceScale, SubpixelScale * 40)
        )
        let
          shiftX = mulDivRound(dx, impulse, dist * ForceScale)
          shiftY = mulDivRound(dy, impulse, dist * ForceScale)
        sim.players[i].velX += shiftX
        sim.players[i].velY += shiftY
        sim.players[j].velX -= shiftX
        sim.players[j].velY -= shiftY

proc blendLinkedVelocities(sim: var SimServer, components: openArray[seq[int]]) =
  for component in components:
    if component.len <= 1:
      continue

    var
      avgVelX = 0
      avgVelY = 0
    for playerIndex in component:
      avgVelX += sim.players[playerIndex].velX
      avgVelY += sim.players[playerIndex].velY
    avgVelX = avgVelX div component.len
    avgVelY = avgVelY div component.len

    for playerIndex in component:
      sim.players[playerIndex].velX = (sim.players[playerIndex].velX * 3 + avgVelX) div 4
      sim.players[playerIndex].velY = (sim.players[playerIndex].velY * 3 + avgVelY) div 4

proc movePlayers(sim: var SimServer) =
  for player in sim.players.mitems:
    player.x += player.velX
    player.y += player.velY
    player.clampPlayerToWorld()

proc resolveSpacing(sim: var SimServer, linkedPairs: Table[int64, bool]) =
  for i in 0 ..< sim.players.len:
    for j in i + 1 ..< sim.players.len:
      let
        dx = sim.players[j].x - sim.players[i].x
        dy = sim.players[j].y - sim.players[i].y
        distSq = dx * dx + dy * dy
        linked = linkedPairs.hasKey(pairKey(sim.players[i].id, sim.players[j].id))
      if not linked and distSq >= SeparationDistanceSq:
        continue

      let
        safeDx = if dx == 0 and dy == 0: SubpixelScale else: dx
        safeDy = if dx == 0 and dy == 0: 0 else: dy
        distance = ceilSqrt(safeDx * safeDx + safeDy * safeDy)
        targetDistance = if linked: LinkRestDistance else: SeparationDistance
      if distance <= 0:
        continue

      let adjust = targetDistance - distance
      if not linked and adjust <= 0:
        continue

      let
        adjustScaled = roundDiv(adjust * ForceScale, 2)
        shiftX = mulDivRound(safeDx, adjustScaled, distance * ForceScale)
        shiftY = mulDivRound(safeDy, adjustScaled, distance * ForceScale)

      sim.players[i].x -= shiftX
      sim.players[i].y -= shiftY
      sim.players[j].x += shiftX
      sim.players[j].y += shiftY
      sim.players[i].clampPlayerToWorld()
      sim.players[j].clampPlayerToWorld()

proc updatePills(sim: var SimServer) =
  for pill in sim.pills.mitems:
    if pill.z > 0:
      pill.z = max(0, pill.z - pill.fallSpeed)

  if sim.pills.len >= TargetPillCount:
    sim.pillSpawnCooldown = max(1, sim.pillSpawnCooldown)
    return

  dec sim.pillSpawnCooldown
  if sim.pillSpawnCooldown > 0:
    return

  sim.addPill(true)
  sim.pillSpawnCooldown = 2 + sim.rng.rand(4)

proc collectPills(sim: var SimServer) =
  var remaining: seq[Pill] = @[]

  for pill in sim.pills:
    if pill.z > 0:
      remaining.add(pill)
      continue

    var
      bestPlayerIndex = -1
      bestDistanceSq = EatDistanceSq + 1
    for playerIndex, player in sim.players:
      let distSq = distanceSquared(
        player.playerPixelX(),
        player.playerGroundY(),
        pill.x,
        pill.y
      )
      if distSq <= EatDistanceSq and distSq < bestDistanceSq:
        bestDistanceSq = distSq
        bestPlayerIndex = playerIndex

    if bestPlayerIndex >= 0:
      inc sim.players[bestPlayerIndex].score
      sim.players[bestPlayerIndex].chewTicks = ChewTicks
    else:
      remaining.add(pill)

  sim.pills = remaining

proc render(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(FieldColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let
    player = sim.players[playerIndex]
    cameraX = worldClampPixel(player.playerPixelX() - ScreenWidth div 2, WorldWidthPixels - ScreenWidth)
    cameraY = worldClampPixel(player.playerPixelY() - ScreenHeight div 2, WorldHeightPixels - ScreenHeight)

  sim.renderGround(cameraX, cameraY)

  var renderEntries: seq[RenderEntry] = @[]
  for pillIndex, pill in sim.pills:
    let visibleX = pill.x >= cameraX - PillShadowWidth and pill.x <= cameraX + ScreenWidth + PillShadowWidth
    let visibleY = pill.y >= cameraY - PillSpawnHeightMax and pill.y <= cameraY + ScreenHeight + PillShadowHeight
    if visibleX and visibleY:
      renderEntries.add(RenderEntry(sortY: pill.y, kind: RenderPill, index: pillIndex))
  for otherIndex, otherPlayer in sim.players:
    let topLeft = otherPlayer.playerTopLeft()
    if topLeft.x > cameraX + ScreenWidth or topLeft.x + BlobWidth < cameraX or
        topLeft.y > cameraY + ScreenHeight or topLeft.y + BlobHeight < cameraY:
      continue
    renderEntries.add(RenderEntry(sortY: otherPlayer.playerGroundY(), kind: RenderPlayer, index: otherIndex))

  renderEntries.sort(proc (a, b: RenderEntry): int = cmp(a.sortY, b.sortY))
  for entry in renderEntries:
    case entry.kind
    of RenderPill:
      sim.renderPill(sim.pills[entry.index], cameraX, cameraY)
    of RenderPlayer:
      sim.renderBlob(sim.players[entry.index], cameraX, cameraY)

  sim.fb.renderNumber(sim.digitSprites, min(999, player.score), 0, 0)
  sim.fb.renderNumber(
    sim.digitSprites,
    max(1, min(9, player.componentSize)),
    ScreenWidth - sim.digitSprites[0].width,
    0
  )
  if player.detachCharge > 0:
    let barWidth = min(12, player.detachCharge * 12 div BreakThreshold)
    for x in 0 ..< 12:
      sim.fb.putPixel(26 + x, 1, 1)
      sim.fb.putPixel(26 + x, 2, 1)
    for x in 0 ..< barWidth:
      sim.fb.putPixel(26 + x, 1, 7)
      sim.fb.putPixel(26 + x, 2, 8)

  sim.fb.packFramebuffer()
  sim.fb.packed

proc step(sim: var SimServer, inputs: openArray[PlayerInput]) =
  sim.updateExpressionTimers(inputs)
  sim.refreshLinks()

  var components = sim.computeComponents()
  sim.assignComponentSizes(components)
  sim.updateDetachCharges(components, inputs)

  sim.refreshLinks()
  components = sim.computeComponents()
  sim.assignComponentSizes(components)

  sim.applyMovement(components, inputs)
  let linkedPairs = sim.buildLinkedPairTable()
  sim.applyPairForces(linkedPairs)
  sim.blendLinkedVelocities(components)
  sim.movePlayers()
  sim.resolveSpacing(linkedPairs)
  sim.collectPills()
  sim.updatePills()

  sim.refreshLinks()
  components = sim.computeComponents()
  sim.assignComponentSizes(components)

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]

proc playerInputFromMasks(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.inputX =
    (if decoded.left: -1 else: 0) +
    (if decoded.right: 1 else: 0)
  result.inputY =
    (if decoded.up: -1 else: 0) +
    (if decoded.down: 1 else: 0)
  result.blinkPressed = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
  result.frownPressed = (currentMask and ButtonB) != 0 and (previousMask and ButtonB) == 0

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    let removedId = sim.players[removedIndex].id
    sim.players.delete(removedIndex)

    var keptLinks: seq[Link] = @[]
    for link in sim.links:
      if link.aId != removedId and link.bId != removedId:
        keptLinks.add(link)
    sim.links = keptLinks

    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc httpHandler(request: Request) =
  if request.uri == WebSocketPath and request.httpMethod == "GET":
    discard request.upgradeToWebSocket()
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Bubble Eats WebSocket server")

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
    if message.kind == BinaryMessage and message.data.len == InputPacketBytes:
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
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
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
    wsNoDelay = true
  )

  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc, ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    sim = initSimServer()
    lastTick = getMonoTime()

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[PlayerInput]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == 0x7fffffff:
            appState.playerIndices[websocket] = sim.addPlayer()

        inputs = newSeq[PlayerInput](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let
            currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = playerInputFromMasks(currentMask, previousMask)
          appState.lastAppliedMasks[websocket] = currentMask
          sockets.add(websocket)
          playerIndices.add(playerIndex)

    sim.step(inputs)

    for i in 0 ..< sockets.len:
      let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
      sockets[i].send(frameBlob, BinaryMessage)

    runFrameLimiter(lastTick)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "port":
        port = parseInt(val)
      else:
        discard
    else:
      discard
  runServerLoop(address, port)

import mummy, pixie
import protocol, server
import std/[locks, math, monotimes, os, parseopt, strutils, tables, times]

const
  MapWidth = 476
  MapHeight = 267
  SpriteSize = 6
  CollisionW = 3
  CollisionH = 2
  SpriteDrawOffX = 1
  SpriteDrawOffY = 4
  MotionScale = 256
  Accel = 38
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeed = 352
  StopThreshold = 8
  TargetFps = 24.0
  SpaceColor = 0'u8
  BodyColor = 2'u8
  OutlineColor = 0'u8
  KillRange = 10
  KillCooldownTicks = 120
  TaskCompleteTicks = 72
  TaskBarWidth = 7
  VentRange = 8
  TaskBarY = -3
  ProgressEmpty = 1'u8
  ProgressFilled = 10'u8
  PlayerColors = [3'u8, 7, 8, 14, 4, 11, 13, 15]
  ShadowMap = [
    0'u8,  #  0 black       -> black
    12,    #  1 gray         -> dark navy
    9,     #  2 white        -> dark teal
    5,     #  3 red          -> dark brown
    5,     #  4 pink         -> dark brown
    0,     #  5 dark brown   -> black
    5,     #  6 brown        -> dark brown
    5,     #  7 orange       -> dark brown
    5,     #  8 yellow       -> dark brown
    12,    #  9 dark teal    -> dark navy
    9,     # 10 green        -> dark teal
    9,     # 11 lime         -> dark teal
    0,     # 12 dark navy    -> black
    12,    # 13 blue         -> dark navy
    12,    # 14 light blue   -> dark navy
    9,     # 15 pale blue    -> dark teal
  ]
  WebSocketPath = "/ws"

type
  PlayerRole = enum
    Crewmate
    Imposter

  TaskStation = object
    name: string
    x, y, w, h: int
    completed: seq[bool]

  Vent = object
    x, y, w, h: int
    group: char
    groupIndex: int

  Body = object
    x, y: int
    color: uint8

  Player = object
    x, y: int
    velX, velY: int
    carryX, carryY: int
    flipH: bool
    role: PlayerRole
    alive: bool
    killCooldown: int
    joinOrder: int
    color: uint8
    taskProgress: int
    activeTask: int
    ventCooldown: int

  SimServer = object
    players: seq[Player]
    bodies: seq[Body]
    playerSprite: Sprite
    bodySprite: Sprite
    boneSprite: Sprite
    killButtonSprite: Sprite
    taskIconSprite: Sprite
    tasks: seq[TaskStation]
    vents: seq[Vent]
    mapPixels: seq[uint8]
    walkMask: seq[bool]
    wallMask: seq[bool]
    fb: Framebuffer
    shadowBuf: seq[bool]
    nextJoinOrder: int
    tickCount: int

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

proc isImposterByJoinOrder(joinOrder: int): bool =
  if joinOrder == 1:
    return true
  if joinOrder >= 5 and (joinOrder - 1) mod 5 == 0:
    return true
  false

proc clientDataDir(): string =
  getCurrentDir() / ".." / "client" / "data"

proc mapIndex(x, y: int): int =
  y * MapWidth + x

proc isWalkable(sim: SimServer, x, y: int): bool =
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return false
  sim.walkMask[mapIndex(x, y)]

proc canOccupy(sim: SimServer, x, y: int): bool =
  for dy in 0 ..< CollisionH:
    for dx in 0 ..< CollisionW:
      if not sim.isWalkable(x + dx, y + dy):
        return false
  true

proc findSpawn(sim: SimServer): tuple[x, y: int] =
  let
    buttonX = 268
    buttonY = 60
    spawnRadius = 14
    n = max(1, sim.players.len + 1)
    angle = float(sim.players.len) * 2.0 * 3.14159265 / float(n)
    px = buttonX + int(float(spawnRadius) * cos(angle))
    py = buttonY + int(float(spawnRadius) * sin(angle))
  if sim.canOccupy(px, py):
    return (px, py)
  (buttonX, buttonY)

proc addPlayer(sim: var SimServer): int =
  let
    spawn = sim.findSpawn()
    order = sim.nextJoinOrder
    role = if isImposterByJoinOrder(order): Imposter else: Crewmate
  inc sim.nextJoinOrder
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    role: role,
    alive: true,
    killCooldown: KillCooldownTicks,
    joinOrder: order,
    color: PlayerColors[order mod PlayerColors.len],
    activeTask: -1
  )
  for task in sim.tasks.mitems:
    task.completed.add(false)
  sim.players.high

proc applyMomentumAxis(
  sim: SimServer,
  player: var Player,
  carry: var int,
  velocity: int,
  horizontal: bool
) =
  carry += velocity
  while abs(carry) >= MotionScale:
    let step = if carry < 0: -1 else: 1
    let
      nx = if horizontal: player.x + step else: player.x
      ny = if horizontal: player.y else: player.y + step
    if sim.canOccupy(nx, ny):
      if horizontal:
        player.x = nx
      else:
        player.y = ny
      carry -= step * MotionScale
    else:
      carry = 0
      break

proc playerColor(index: int): uint8 =
  PlayerColors[index mod PlayerColors.len]

proc distSq(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc tryKill(sim: var SimServer, killerIndex: int) =
  let killer = sim.players[killerIndex]
  if killer.role != Imposter or not killer.alive:
    return
  if killer.killCooldown > 0:
    return
  let
    kx = killer.x + CollisionW div 2
    ky = killer.y + CollisionH div 2
    rangeSq = KillRange * KillRange
  var
    bestDist = high(int)
    bestTarget = -1
  for i in 0 ..< sim.players.len:
    if i == killerIndex or not sim.players[i].alive:
      continue
    if sim.players[i].role == Imposter:
      continue
    let
      tx = sim.players[i].x + CollisionW div 2
      ty = sim.players[i].y + CollisionH div 2
      d = distSq(kx, ky, tx, ty)
    if d <= rangeSq and d < bestDist:
      bestDist = d
      bestTarget = i
  if bestTarget >= 0:
    sim.players[bestTarget].alive = false
    sim.bodies.add Body(
      x: sim.players[bestTarget].x,
      y: sim.players[bestTarget].y,
      color: sim.players[bestTarget].color
    )
    sim.players[killerIndex].killCooldown = KillCooldownTicks

proc tryVent(sim: var SimServer, playerIndex: int) =
  ## Teleport an imposter to the next vent in the same group.
  let p = sim.players[playerIndex]
  if p.role != Imposter or not p.alive:
    return
  if p.ventCooldown > 0:
    return
  let
    px = p.x + CollisionW div 2
    py = p.y + CollisionH div 2
    rangeSq = VentRange * VentRange
  for i in 0 ..< sim.vents.len:
    let v = sim.vents[i]
    let
      vx = v.x + v.w div 2
      vy = v.y + v.h div 2
    if distSq(px, py, vx, vy) <= rangeSq:
      var nextIdx = -1
      for j in 0 ..< sim.vents.len:
        if j == i:
          continue
        if sim.vents[j].group == v.group:
          if sim.vents[j].groupIndex == v.groupIndex + 1:
            nextIdx = j
            break
      if nextIdx < 0:
        for j in 0 ..< sim.vents.len:
          if sim.vents[j].group == v.group and
              sim.vents[j].groupIndex == 1:
            nextIdx = j
            break
      if nextIdx >= 0:
        let dest = sim.vents[nextIdx]
        sim.players[playerIndex].x =
          dest.x + dest.w div 2 - CollisionW div 2
        sim.players[playerIndex].y =
          dest.y + dest.h div 2 - CollisionH div 2
        sim.players[playerIndex].velX = 0
        sim.players[playerIndex].velY = 0
        sim.players[playerIndex].carryX = 0
        sim.players[playerIndex].carryY = 0
        sim.players[playerIndex].ventCooldown = 30
      return

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if not sim.players[playerIndex].alive:
    return
  template player: untyped = sim.players[playerIndex]

  var
    inputX = 0
    inputY = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1
  if input.up:
    inputY -= 1
  if input.down:
    inputY += 1

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

  if inputX < 0:
    player.flipH = true
  elif inputX > 0:
    player.flipH = false

  sim.applyMomentumAxis(player, player.carryX, player.velX, true)
  sim.applyMomentumAxis(player, player.carryY, player.velY, false)

  if input.b:
    if player.role == Imposter:
      sim.tryVent(playerIndex)

  if input.attack:
    if player.role == Imposter:
      sim.tryKill(playerIndex)
    elif player.role == Crewmate:
      let
        px = player.x + CollisionW div 2
        py = player.y + CollisionH div 2
      var inTask = -1
      for t in 0 ..< sim.tasks.len:
        let task = sim.tasks[t]
        if playerIndex < task.completed.len and task.completed[playerIndex]:
          continue
        if px >= task.x and px < task.x + task.w and
            py >= task.y and py < task.y + task.h:
          inTask = t
          break
      if inTask >= 0 and inputX == 0 and inputY == 0:
        if player.activeTask != inTask:
          player.activeTask = inTask
          player.taskProgress = 0
        inc player.taskProgress
        if player.taskProgress >= TaskCompleteTicks:
          sim.tasks[inTask].completed[playerIndex] = true
          player.activeTask = -1
          player.taskProgress = 0
      else:
        player.activeTask = -1
        player.taskProgress = 0
  else:
    player.activeTask = -1
    player.taskProgress = 0

proc isSolid(sprite: Sprite, x, y: int, flipH: bool): bool =
  let srcX = if flipH: sprite.width - 1 - x else: x
  if srcX < 0 or srcX >= sprite.width or y < 0 or y >= sprite.height:
    return false
  sprite.pixels[sprite.spriteIndex(srcX, y)] != TransparentColorIndex

proc blitSpriteOutlined(
  fb: var Framebuffer,
  sprite: Sprite,
  screenX, screenY: int,
  tint: uint8,
  flipH: bool
) =
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
        fb.putPixel(screenX + x, screenY + y, OutlineColor)

  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let srcX = if flipH: sprite.width - 1 - x else: x
      let colorIndex = sprite.pixels[sprite.spriteIndex(srcX, y)]
      if colorIndex == TransparentColorIndex:
        continue
      let drawColor = if colorIndex == BodyColor: tint else: colorIndex
      fb.putPixel(screenX + x, screenY + y, drawColor)

proc blitSpriteTintAll(
  fb: var Framebuffer,
  sprite: Sprite,
  screenX, screenY: int,
  tint: uint8
) =
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        fb.putPixel(screenX + x, screenY + y, tint)

proc blitSpriteRaw(
  fb: var Framebuffer,
  sprite: Sprite,
  screenX, screenY: int
) =
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        fb.putPixel(screenX + x, screenY + y, colorIndex)

proc blitSpriteShadowed(
  fb: var Framebuffer,
  sprite: Sprite,
  screenX, screenY: int
) =
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        fb.putPixel(screenX + x, screenY + y, ShadowMap[colorIndex and 0x0F])

proc isWall(sim: SimServer, mx, my: int): bool =
  if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
    return true
  sim.wallMask[mapIndex(mx, my)]

proc castShadows(sim: var SimServer, originMx, originMy, cameraX, cameraY: int) =
  for i in 0 ..< sim.shadowBuf.len:
    sim.shadowBuf[i] = false
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let
        mx = cameraX + sx
        my = cameraY + sy
        dx = mx - originMx
        dy = my - originMy
        steps = max(abs(dx), abs(dy))
      if steps == 0:
        continue
      var shadowed = false
      for s in 1 .. steps:
        let
          rx = originMx + dx * s div steps
          ry = originMy + dy * s div steps
        if sim.isWall(rx, ry):
          shadowed = true
          break
      if shadowed:
        sim.shadowBuf[sy * ScreenWidth + sx] = true

proc buildFramePacket(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(SpaceColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let
    player = sim.players[playerIndex]
    spriteX = player.x - SpriteDrawOffX
    spriteY = player.y - SpriteDrawOffY
    centerX = spriteX + SpriteSize div 2
    centerY = spriteY + SpriteSize div 2
    cameraX = clamp(
      centerX - ScreenWidth div 2,
      0,
      max(0, MapWidth - ScreenWidth)
    )
    cameraY = clamp(
      centerY - ScreenHeight div 2,
      0,
      max(0, MapHeight - ScreenHeight)
    )

  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let
        mx = cameraX + x
        my = cameraY + y
      if mx < MapWidth and my < MapHeight:
        sim.fb.putPixel(x, y, sim.mapPixels[mapIndex(mx, my)])

  let
    originMx = player.x + CollisionW div 2
    originMy = player.y + CollisionH div 2
  sim.castShadows(originMx, originMy, cameraX, cameraY)

  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      if sim.shadowBuf[sy * ScreenWidth + sx]:
        let idx = sy * ScreenWidth + sx
        sim.fb.indices[idx] = ShadowMap[sim.fb.indices[idx] and 0x0F]

  for body in sim.bodies:
    let
      bsx = body.x - SpriteDrawOffX - cameraX
      bsy = body.y - SpriteDrawOffY - cameraY
      bcx = body.x + CollisionW div 2 - cameraX
      bcy = body.y + CollisionH div 2 - cameraY
    if bcx < 0 or bcx >= ScreenWidth or bcy < 0 or bcy >= ScreenHeight:
      continue
    if sim.shadowBuf[bcy * ScreenWidth + bcx]:
      continue
    for y in -1 .. sim.bodySprite.height:
      for x in -1 .. sim.bodySprite.width:
        let solidHere =
          (x >= 0 and x < sim.bodySprite.width and y >= 0 and y < sim.bodySprite.height) and
          (sim.bodySprite.pixels[sim.bodySprite.spriteIndex(x, y)] != TransparentColorIndex or
           sim.boneSprite.pixels[sim.boneSprite.spriteIndex(x, y)] != TransparentColorIndex)
        if solidHere:
          continue
        var adj = false
        for d in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
          let
            nx = x + d[0]
            ny = y + d[1]
          if nx >= 0 and nx < sim.bodySprite.width and ny >= 0 and ny < sim.bodySprite.height:
            if sim.bodySprite.pixels[sim.bodySprite.spriteIndex(nx, ny)] != TransparentColorIndex or
               sim.boneSprite.pixels[sim.boneSprite.spriteIndex(nx, ny)] != TransparentColorIndex:
              adj = true
              break
        if adj:
          sim.fb.putPixel(bsx + x, bsy + y, OutlineColor)
    sim.fb.blitSpriteTintAll(sim.bodySprite, bsx, bsy, body.color)
    sim.fb.blitSpriteRaw(sim.boneSprite, bsx, bsy)

  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    let
      p = sim.players[i]
      sx = p.x - SpriteDrawOffX - cameraX
      sy = p.y - SpriteDrawOffY - cameraY
    if i != playerIndex:
      let
        pcx = p.x + CollisionW div 2 - cameraX
        pcy = p.y + CollisionH div 2 - cameraY
      if pcx < 0 or pcx >= ScreenWidth or pcy < 0 or pcy >= ScreenHeight:
        continue
      if sim.shadowBuf[pcy * ScreenWidth + pcx]:
        continue
    sim.fb.blitSpriteOutlined(sim.playerSprite, sx, sy, p.color, p.flipH)

  if player.role == Crewmate:
    for t in 0 ..< sim.tasks.len:
      let
        task = sim.tasks[t]
        bob = [0, 0, -1, -1, -1, 0, 0, 1, 1, 1]
        bobY = bob[(sim.tickCount div 3) mod bob.len]
        iconSx = task.x + task.w div 2 - SpriteSize div 2 - cameraX
        iconSy = task.y - SpriteSize - 2 + bobY - cameraY
      if playerIndex < task.completed.len and task.completed[playerIndex]:
        continue
      let
        tcx = task.x + task.w div 2 - cameraX
        tcy = task.y + task.h div 2 - cameraY
      if tcx < 0 or tcx >= ScreenWidth or tcy < 0 or tcy >= ScreenHeight:
        continue
      if sim.shadowBuf[tcy * ScreenWidth + tcx]:
        continue
      sim.fb.blitSpriteRaw(sim.taskIconSprite, iconSx, iconSy)

  if player.role == Crewmate and player.activeTask >= 0 and player.taskProgress > 0:
    let
      barX = player.x - SpriteDrawOffX - cameraX
      barY = player.y - SpriteDrawOffY - cameraY + TaskBarY
      filled = player.taskProgress * TaskBarWidth div TaskCompleteTicks
    for bx in 0 ..< TaskBarWidth:
      let c = if bx < filled: ProgressFilled else: ProgressEmpty
      sim.fb.putPixel(barX + bx, barY, c)

  if player.role == Imposter and player.alive:
    let
      iconX = 1
      iconY = ScreenHeight - SpriteSize - 1
    if player.killCooldown > 0:
      sim.fb.blitSpriteShadowed(sim.killButtonSprite, iconX, iconY)
    else:
      sim.fb.blitSpriteRaw(sim.killButtonSprite, iconX, iconY)

  sim.fb.packFramebuffer()
  sim.fb.packed

proc initSimServer(): SimServer =
  result.fb = initFramebuffer()
  loadPalette(clientDataDir() / "pallete.png")

  let sheet = readImage("spritesheet.png")
  result.playerSprite = spriteFromImage(
    sheet.subImage(0, 0, SpriteSize, SpriteSize)
  )
  result.bodySprite = spriteFromImage(
    sheet.subImage(SpriteSize, 0, SpriteSize, SpriteSize)
  )
  result.boneSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 2, 0, SpriteSize, SpriteSize)
  )
  result.killButtonSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 3, 0, SpriteSize, SpriteSize)
  )
  result.taskIconSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 4, 0, SpriteSize, SpriteSize)
  )

  result.tasks = @[
    TaskStation(name: "Empty Garbage", x: 278, y: 233, w: 8, h: 8),
    TaskStation(name: "Upload Data (Comms)", x: 334, y: 209, w: 8, h: 8),
    TaskStation(name: "Fix Wires (Storage)", x: 287, y: 132, w: 8, h: 8),
    TaskStation(name: "Fix Wires (Electrical)", x: 221, y: 12, w: 8, h: 8),
    TaskStation(name: "Upload Data (Electrical)", x: 175, y: 140, w: 8, h: 8),
    TaskStation(name: "Calibrate Distributor", x: 215, y: 141, w: 8, h: 8),
    TaskStation(name: "Submit Scan", x: 200, y: 116, w: 8, h: 8),
    TaskStation(name: "Divert Power", x: 193, y: 141, w: 8, h: 8),
    TaskStation(name: "Inspect Sample", x: 211, y: 107, w: 8, h: 8),
    TaskStation(name: "Upload Data (Admin)", x: 298, y: 132, w: 8, h: 8),
    TaskStation(name: "Align Engine (Lower)", x: 93, y: 159, w: 8, h: 8),
    TaskStation(name: "Align Engine (Upper)", x: 101, y: 35, w: 8, h: 8),
    TaskStation(name: "Swipe Card", x: 332, y: 153, w: 8, h: 8),
    TaskStation(name: "Upload Data (Cafeteria)", x: 302, y: 13, w: 8, h: 8),
    TaskStation(name: "Empty Garbage (Upper)", x: 315, y: 25, w: 8, h: 8),
  ]

  result.vents = @[
    Vent(x: 300, y: 167, w: 6, h: 5, group: 'A', groupIndex: 1),
    Vent(x: 368, y: 132, w: 6, h: 5, group: 'A', groupIndex: 2),
    Vent(x: 317, y: 71, w: 6, h: 5, group: 'A', groupIndex: 3),
    Vent(x: 362, y: 35, w: 6, h: 5, group: 'B', groupIndex: 1),
    Vent(x: 437, y: 107, w: 6, h: 5, group: 'B', groupIndex: 2),
    Vent(x: 370, y: 211, w: 6, h: 5, group: 'C', groupIndex: 1),
    Vent(x: 437, y: 131, w: 6, h: 5, group: 'C', groupIndex: 2),
    Vent(x: 168, y: 110, w: 6, h: 5, group: 'D', groupIndex: 1),
    Vent(x: 176, y: 149, w: 6, h: 5, group: 'D', groupIndex: 2),
    Vent(x: 148, y: 137, w: 6, h: 5, group: 'D', groupIndex: 3),
    Vent(x: 44, y: 60, w: 6, h: 5, group: 'E', groupIndex: 1),
    Vent(x: 66, y: 136, w: 6, h: 5, group: 'E', groupIndex: 2),
    Vent(x: 121, y: 204, w: 6, h: 5, group: 'E', groupIndex: 3),
    Vent(x: 55, y: 98, w: 6, h: 5, group: 'F', groupIndex: 1),
    Vent(x: 121, y: 42, w: 6, h: 5, group: 'F', groupIndex: 2),
  ]

  let mapImage = readImage("skeld.png")
  result.mapPixels = newSeq[uint8](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      result.mapPixels[mapIndex(x, y)] = nearestPaletteIndex(mapImage[x, y])

  let walkImage = readImage("skeld.floor.png")
  result.walkMask = newSeq[bool](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let pixel = walkImage[x, y]
      result.walkMask[mapIndex(x, y)] = pixel.r > 128 and pixel.a > 128

  let wallImage = readImage("skeld.walls.png")
  result.wallMask = newSeq[bool](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let pixel = wallImage[x, y]
      result.wallMask[mapIndex(x, y)] = pixel.r > 100 and pixel.a > 128

  result.shadowBuf = newSeq[bool](ScreenWidth * ScreenHeight)
  result.bodies = @[]
  result.players = @[]
  result.nextJoinOrder = 0

proc step(sim: var SimServer, inputs: openArray[InputState]) =
  inc sim.tickCount
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].alive and
        sim.players[playerIndex].role == Imposter:
      if sim.players[playerIndex].killCooldown > 0:
        dec sim.players[playerIndex].killCooldown
      if sim.players[playerIndex].ventCooldown > 0:
        dec sim.players[playerIndex].ventCooldown
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input)

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]

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
  if request.uri == WebSocketPath and request.httpMethod == "GET":
    discard request.upgradeToWebSocket()
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Among Them server")

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
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)
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

proc runServerLoop*(host = DefaultHost, port = DefaultPort) =
  initAppState()
  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()

  var
    sim = initSimServer()
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
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = decodeInputMask(currentMask)
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

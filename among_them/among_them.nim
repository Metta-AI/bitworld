import mummy, pixie
import protocol, server
import std/[locks, math, monotimes, os, parseopt, random, strutils, tables,
  times]

const
  MapWidth = 476
  MapHeight = 267
  SpriteSize = 6
  CollisionW = 3
  CollisionH = 2
  SpriteDrawOffX = 1
  SpriteDrawOffY = 4
  MotionScale = 256
  Accel = 76
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeed = 704
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
  ReportRange = 10
  VoteResultTicks = 72
  MinPlayers = 5
  VoteTimerTicks = 240
  GameOverTicks = 360
  TasksPerPlayer = 4
  ShowTaskArrows = true
  ButtonX = 262
  ButtonY = 57
  ButtonW = 14
  ButtonH = 17
  MapSpriteId = 1
  MapObjectId = 1
  PlayerSpriteBase = 100
  GhostSpriteBase = 300
  BodySpriteBase = 500
  PlayerObjectBase = 1000
  BodyObjectBase = 2000
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
  SpriteWebSocketPath = "/sprite"

type
  PlayerRole = enum
    Crewmate
    Imposter

  GamePhase = enum
    Lobby
    Playing
    Voting
    VoteResult
    GameOver

  VoteState = object
    votes: seq[int]
    cursor: seq[int]
    resultTimer: int
    voteTimer: int
    ejectedPlayer: int

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
    assignedTasks: seq[int]

  SimServer = object
    players: seq[Player]
    bodies: seq[Body]
    playerSprite: Sprite
    bodySprite: Sprite
    boneSprite: Sprite
    killButtonSprite: Sprite
    taskIconSprite: Sprite
    ghostSprite: Sprite
    tasks: seq[TaskStation]
    vents: seq[Vent]
    mapPixels: seq[uint8]
    walkMask: seq[bool]
    wallMask: seq[bool]
    fb: Framebuffer
    shadowBuf: seq[bool]
    nextJoinOrder: int
    tickCount: int
    phase: GamePhase
    voteState: VoteState
    letterSprites: seq[Sprite]
    digitSprites: array[10, Sprite]
    winner: PlayerRole
    gameOverTimer: int
    needsReregister: bool

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    spriteViewers: Table[WebSocket, SpriteViewerState]
    closedSockets: seq[WebSocket]
    spectators: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

  SpriteViewerState = object
    initialized: bool
    objectIds: seq[int]

proc clientDataDir(): string =
  getCurrentDir() / ".." / "client" / "data"

proc mapIndex(x, y: int): int =
  y * MapWidth + x

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

proc addViewport(packet: var seq[uint8], width, height: int) =
  ## Appends a sprite protocol viewport message.
  packet.addU8(0x05)
  packet.addU16(width)
  packet.addU16(height)

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
  objectId, x, y, z, spriteId: int
) =
  ## Appends a sprite protocol object definition message.
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU16(spriteId)

proc addDeleteObject(packet: var seq[uint8], objectId: int) =
  ## Appends a sprite protocol object delete message.
  packet.addU8(0x03)
  packet.addU16(objectId)

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
  inc sim.nextJoinOrder
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    role: Crewmate,
    alive: true,
    killCooldown: KillCooldownTicks,
    joinOrder: order,
    color: PlayerColors[order mod PlayerColors.len],
    activeTask: -1
  )
  for task in sim.tasks.mitems:
    task.completed.add(false)
  sim.players.high

proc hasTask(player: Player, taskIdx: int): bool =
  for t in player.assignedTasks:
    if t == taskIdx:
      return true
  false

proc startGame(sim: var SimServer) =
  randomize()
  let impIdx = rand(sim.players.len - 1)
  sim.players[impIdx].role = Imposter
  for i in 0 ..< sim.players.len:
    if sim.players[i].role == Imposter:
      continue
    var indices: seq[int] = @[]
    for t in 0 ..< sim.tasks.len:
      indices.add(t)
    shuffle(indices)
    sim.players[i].assignedTasks = indices[0 ..< min(TasksPerPlayer, indices.len)]
  sim.phase = Playing

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

proc startVote(sim: var SimServer) =
  sim.phase = Voting
  let n = sim.players.len
  sim.voteState.votes = newSeq[int](n)
  sim.voteState.cursor = newSeq[int](n)
  sim.voteState.voteTimer = VoteTimerTicks
  for i in 0 ..< n:
    sim.voteState.votes[i] = -1
    var firstAlive = 0
    for j in 0 ..< n:
      if sim.players[j].alive:
        firstAlive = j
        break
    sim.voteState.cursor[i] = firstAlive

proc tryReport(sim: var SimServer, reporterIndex: int, bodyLimit: int) =
  if sim.phase != Playing:
    return
  let p = sim.players[reporterIndex]
  if not p.alive:
    return
  let
    px = p.x + CollisionW div 2
    py = p.y + CollisionH div 2
    rangeSq = ReportRange * ReportRange
  for bi in 0 ..< bodyLimit:
    let body = sim.bodies[bi]
    let
      bx = body.x + CollisionW div 2
      by = body.y + CollisionH div 2
    if distSq(px, py, bx, by) <= rangeSq:
      sim.startVote()
      return

proc tryCallButton(sim: var SimServer, callerIndex: int) =
  if sim.phase != Playing:
    return
  let p = sim.players[callerIndex]
  if not p.alive:
    return
  let
    px = p.x + CollisionW div 2
    py = p.y + CollisionH div 2
  if px >= ButtonX and px < ButtonX + ButtonW and
      py >= ButtonY and py < ButtonY + ButtonH:
    sim.startVote()

proc applyGhostMovement(sim: var SimServer, playerIndex: int, input: InputState) =
  template player: untyped = sim.players[playerIndex]
  var inputX = 0
  var inputY = 0
  if input.left: inputX -= 1
  if input.right: inputX += 1
  if input.up: inputY -= 1
  if input.down: inputY += 1

  if inputX != 0:
    player.velX = clamp(player.velX + inputX * Accel, -MaxSpeed, MaxSpeed)
  else:
    player.velX = (player.velX * FrictionNum) div FrictionDen
    if abs(player.velX) < StopThreshold: player.velX = 0

  if inputY != 0:
    player.velY = clamp(player.velY + inputY * Accel, -MaxSpeed, MaxSpeed)
  else:
    player.velY = (player.velY * FrictionNum) div FrictionDen
    if abs(player.velY) < StopThreshold: player.velY = 0

  if inputX < 0: player.flipH = true
  elif inputX > 0: player.flipH = false

  player.carryX += player.velX
  while abs(player.carryX) >= MotionScale:
    let step = if player.carryX < 0: -1 else: 1
    player.x += step
    player.carryX -= step * MotionScale
  player.carryY += player.velY
  while abs(player.carryY) >= MotionScale:
    let step = if player.carryY < 0: -1 else: 1
    player.y += step
    player.carryY -= step * MotionScale

  if player.role == Crewmate and input.attack:
    let
      px = player.x + CollisionW div 2
      py = player.y + CollisionH div 2
    var inTask = -1
    for t in 0 ..< sim.tasks.len:
      if not player.hasTask(t): continue
      let task = sim.tasks[t]
      if playerIndex < task.completed.len and task.completed[playerIndex]: continue
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

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState, prevInput: InputState, bodiesBeforeTick: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if not sim.players[playerIndex].alive:
    sim.applyGhostMovement(playerIndex, input)
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
    let freshA = input.attack and not prevInput.attack
    if freshA:
      sim.tryReport(playerIndex, bodiesBeforeTick)
      if sim.phase == Voting:
        return
      sim.tryCallButton(playerIndex)
      if sim.phase == Voting:
        return
    if player.role == Imposter:
      if freshA:
        sim.tryKill(playerIndex)
    elif player.role == Crewmate:
      let
        px = player.x + CollisionW div 2
        py = player.y + CollisionH div 2
      var inTask = -1
      for t in 0 ..< sim.tasks.len:
        if not player.hasTask(t):
          continue
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

proc buildSpriteProtocolActorSprite(
  sprite: Sprite,
  tint: uint8,
  flipH: bool
): seq[uint8] =
  ## Builds an outlined, tinted actor sprite for the global viewer.
  let
    outWidth = sprite.width + 2
    outHeight = sprite.height + 2
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
        result[outIndex(x + 1, y + 1)] = spriteColor(OutlineColor)

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

proc buildSpriteProtocolInit(sim: SimServer): seq[uint8] =
  ## Builds the initial global viewer snapshot.
  result = @[]
  var mapPixels = newSeq[uint8](sim.mapPixels.len)
  for i in 0 ..< sim.mapPixels.len:
    mapPixels[i] = spriteColor(sim.mapPixels[i])
  result.addViewport(MapWidth, MapHeight)
  result.addSprite(MapSpriteId, MapWidth, MapHeight, mapPixels)
  result.addObject(MapObjectId, 0, 0, low(int16), MapSpriteId)
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

proc spriteActorSpriteId(player: Player): int =
  ## Returns the sprite id for a player in the global viewer.
  let
    colorIndex = player.joinOrder mod PlayerColors.len
    side = if player.flipH: 1 else: 0
  if player.alive:
    PlayerSpriteBase + colorIndex * 2 + side
  else:
    GhostSpriteBase + colorIndex * 2 + side

proc buildSpriteProtocolUpdates(
  sim: SimServer,
  state: SpriteViewerState,
  nextState: var SpriteViewerState
): seq[uint8] =
  ## Builds global viewer object updates for the current tick.
  result = @[]
  nextState = state
  if not nextState.initialized:
    result = sim.buildSpriteProtocolInit()
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
      player.spriteActorSpriteId()
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
      BodySpriteBase + playerColorIndex(body.color)
    )

  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

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

proc allVotesCast(sim: SimServer): bool =
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive and sim.voteState.votes[i] == -1:
      return false
  true

proc tallyVotes(sim: var SimServer) =
  var counts = newSeq[int](sim.players.len)
  var skipCount = 0
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive:
      let v = sim.voteState.votes[i]
      if v >= 0 and v < counts.len:
        inc counts[v]
      elif v == -2 or v == -1:
        inc skipCount
  var maxVotes = skipCount
  var maxPlayer = -1
  var tied = false
  for i in 0 ..< counts.len:
    if counts[i] > maxVotes:
      maxVotes = counts[i]
      maxPlayer = i
      tied = false
    elif counts[i] == maxVotes and counts[i] > 0:
      tied = true
  if tied or maxVotes == 0:
    sim.voteState.ejectedPlayer = -1
  else:
    sim.voteState.ejectedPlayer = maxPlayer
  sim.phase = VoteResult
  sim.voteState.resultTimer = VoteResultTicks

proc applyVoteResult(sim: var SimServer) =
  let ej = sim.voteState.ejectedPlayer
  if ej >= 0 and ej < sim.players.len:
    sim.players[ej].alive = false
  sim.bodies.setLen(0)
  sim.phase = Playing

proc moveCursor(sim: var SimServer, playerIndex: int, delta: int) =
  let n = sim.players.len
  if n == 0:
    return
  let total = n + 1
  var cur = sim.voteState.cursor[playerIndex]
  for step in 1 .. total:
    cur = (cur + delta + total) mod total
    if cur == n or sim.players[cur].alive:
      break
  sim.voteState.cursor[playerIndex] = cur

proc buildLobbyFrame(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(0)
  let n = sim.players.len
  let needed = max(0, MinPlayers - n)
  sim.fb.blitText(sim.letterSprites, "WAITING", 11, 4)
  if needed > 0:
    sim.fb.blitText(sim.letterSprites, "NEED MORE!", 2, 14)
  else:
    sim.fb.blitText(sim.letterSprites, "READY!", 14, 14)
  let startY = 26
  for i in 0 ..< n:
    let
      col = i mod 6
      row = i div 6
      sx = 5 + col * 9
      sy = startY + row * 9
    sim.fb.blitSpriteOutlined(sim.playerSprite, sx, sy, sim.players[i].color, false)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildSpectatorFrame(sim: var SimServer): seq[uint8] =
  sim.fb.clearFrame(0)
  sim.fb.blitText(sim.letterSprites, "GAME IN", 11, 22)
  sim.fb.blitText(sim.letterSprites, "PROGRESS", 8, 32)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildVoteFrame(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(0)
  let n = sim.players.len
  if n == 0:
    sim.fb.packFramebuffer()
    return sim.fb.packed
  let
    cellW = 10
    cellH = 10
    cols = min(n, ScreenWidth div cellW)
    rows = (n + cols - 1) div cols
    totalW = cols * cellW
    totalH = rows * cellH + 8
    startX = (ScreenWidth - totalW) div 2
    startY = (ScreenHeight - totalH) div 2

  for idx in 0 ..< n:
    let
      pi = idx
      col = idx mod cols
      row = idx div cols
      cx = startX + col * cellW
      cy = startY + row * cellH
    if sim.players[pi].alive:
      sim.fb.blitSpriteOutlined(sim.playerSprite, cx + 2, cy, sim.players[pi].color, false)
    else:
      sim.fb.blitSpriteTintAll(sim.playerSprite, cx + 2, cy, 1'u8)
      sim.fb.blitText(sim.letterSprites, "X", cx + 2, cy)
    if pi == playerIndex:
      sim.fb.putPixel(cx + 4, cy - 2, sim.players[pi].color)
      sim.fb.putPixel(cx + 5, cy - 2, sim.players[pi].color)
    if sim.players[pi].alive and
        playerIndex >= 0 and playerIndex < sim.voteState.cursor.len and
        sim.voteState.cursor[playerIndex] == pi:
      for bx in 0 ..< cellW:
        sim.fb.putPixel(cx + bx, cy - 1, 2'u8)
        sim.fb.putPixel(cx + bx, cy + cellH - 2, 2'u8)
      for by in 0 ..< cellH:
        sim.fb.putPixel(cx, cy + by - 1, 2'u8)
        sim.fb.putPixel(cx + cellW - 1, cy + by - 1, 2'u8)
    var voterRow = 0
    for vi in 0 ..< n:
      if sim.voteState.votes[vi] == pi:
        let
          dotX = cx + 1 + (voterRow mod 4) * 2
          dotY = cy + 7 + (voterRow div 4) * 2
        sim.fb.putPixel(dotX, dotY, sim.players[vi].color)
        sim.fb.putPixel(dotX + 1, dotY, sim.players[vi].color)
        sim.fb.putPixel(dotX, dotY + 1, sim.players[vi].color)
        sim.fb.putPixel(dotX + 1, dotY + 1, sim.players[vi].color)
        inc voterRow

  let skipY = startY + rows * cellH + 1
  let skipW = 24
  let skipX = (ScreenWidth - skipW) div 2
  sim.fb.blitText(sim.letterSprites, "SKIP", skipX, skipY)
  if playerIndex >= 0 and playerIndex < sim.voteState.cursor.len and
      sim.voteState.cursor[playerIndex] == n:
    for bx in 0 ..< skipW:
      sim.fb.putPixel(skipX + bx, skipY - 1, 2'u8)
      sim.fb.putPixel(skipX + bx, skipY + 6, 2'u8)
    for by in 0 ..< 8:
      sim.fb.putPixel(skipX - 1, skipY + by - 1, 2'u8)
      sim.fb.putPixel(skipX + skipW, skipY + by - 1, 2'u8)
  var skipVoterRow = 0
  for vi in 0 ..< n:
    if sim.voteState.votes[vi] == -2:
      let
        dotX = skipX + skipW + 2 + (skipVoterRow mod 4) * 2
        dotY = skipY + (skipVoterRow div 4) * 2
      sim.fb.putPixel(dotX, dotY, sim.players[vi].color)
      sim.fb.putPixel(dotX + 1, dotY, sim.players[vi].color)
      sim.fb.putPixel(dotX, dotY + 1, sim.players[vi].color)
      sim.fb.putPixel(dotX + 1, dotY + 1, sim.players[vi].color)
      inc skipVoterRow

  let
    barY = ScreenHeight - 2
    barW = ScreenWidth - 4
    filled = sim.voteState.voteTimer * barW div VoteTimerTicks
  for bx in 0 ..< barW:
    let c = if bx < filled: 10'u8 else: 1'u8
    sim.fb.putPixel(2 + bx, barY, c)
    sim.fb.putPixel(2 + bx, barY + 1, c)

  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildResultFrame(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(0)
  let ej = sim.voteState.ejectedPlayer
  if ej >= 0 and ej < sim.players.len:
    let
      sx = ScreenWidth div 2 - SpriteSize div 2
      sy = ScreenHeight div 2 - SpriteSize div 2
    sim.fb.blitSpriteOutlined(sim.playerSprite, sx, sy, sim.players[ej].color, false)
  else:
    sim.fb.blitText(sim.letterSprites, "NO ONE", 14, 24)
    sim.fb.blitText(sim.letterSprites, "DIED", 20, 34)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc totalTasksRemaining(sim: SimServer): int =
  for i in 0 ..< sim.players.len:
    if sim.players[i].role != Crewmate:
      continue
    for t in sim.players[i].assignedTasks:
      if t < sim.tasks.len and i < sim.tasks[t].completed.len and
          not sim.tasks[t].completed[i]:
        inc result

proc allTasksDone(sim: SimServer): bool =
  sim.totalTasksRemaining() == 0

proc checkWinCondition(sim: var SimServer) =
  var aliveCrewmates = 0
  var aliveImposters = 0
  for p in sim.players:
    if p.alive:
      if p.role == Crewmate:
        inc aliveCrewmates
      else:
        inc aliveImposters
  if aliveImposters == 0 and sim.players.len > 0:
    sim.phase = GameOver
    sim.winner = Crewmate
    sim.gameOverTimer = GameOverTicks
  elif aliveImposters >= aliveCrewmates and sim.players.len > 0:
    sim.phase = GameOver
    sim.winner = Imposter
    sim.gameOverTimer = GameOverTicks
  elif sim.allTasksDone() and sim.players.len > 0:
    sim.phase = GameOver
    sim.winner = Crewmate
    sim.gameOverTimer = GameOverTicks

proc buildGameOverFrame(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(0)
  let title =
    if sim.winner == Crewmate: "CREW WINS"
    else: "IMPS WIN"
  let titleW = title.len * 6
  let titleX = (ScreenWidth - titleW) div 2
  sim.fb.blitText(sim.letterSprites, title, titleX, 2)
  let n = sim.players.len
  let rowH = 8
  let startY = 12
  for i in 0 ..< n:
    let
      p = sim.players[i]
      y = startY + i * rowH
      roleStr = if p.role == Imposter: "IMP" else: "CREW"
    sim.fb.blitSpriteOutlined(sim.playerSprite, 2, y, p.color, false)
    sim.fb.blitText(sim.letterSprites, roleStr, 10, y)
    if not p.alive:
      for lx in 10 ..< 10 + roleStr.len * 6:
        sim.fb.putPixel(lx, y + 3, 3'u8)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildFramePacket(sim: var SimServer, playerIndex: int): seq[uint8] =
  if sim.phase == Lobby:
    return sim.buildLobbyFrame(playerIndex)
  if sim.phase == GameOver:
    return sim.buildGameOverFrame(playerIndex)
  if sim.phase == Voting:
    return sim.buildVoteFrame(playerIndex)
  if sim.phase == VoteResult:
    return sim.buildResultFrame(playerIndex)
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
    viewerIsGhost = not player.alive
    originMx = player.x + CollisionW div 2
    originMy = player.y + CollisionH div 2
  sim.castShadows(originMx, originMy, cameraX, cameraY)

  if not viewerIsGhost:
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
    if not viewerIsGhost and sim.shadowBuf[bcy * ScreenWidth + bcx]:
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

  var drawOrder = newSeq[int](sim.players.len)
  for i in 0 ..< sim.players.len:
    drawOrder[i] = i
  for i in 1 ..< drawOrder.len:
    let key = drawOrder[i]
    var j = i - 1
    while j >= 0 and sim.players[drawOrder[j]].y > sim.players[key].y:
      drawOrder[j + 1] = drawOrder[j]
      dec j
    drawOrder[j + 1] = key

  for i in drawOrder:
    let
      p = sim.players[i]
      sx = p.x - SpriteDrawOffX - cameraX
      sy = p.y - SpriteDrawOffY - cameraY
    if p.alive:
      if i != playerIndex:
        let
          pcx = p.x + CollisionW div 2 - cameraX
          pcy = p.y + CollisionH div 2 - cameraY
        if pcx < 0 or pcx >= ScreenWidth or pcy < 0 or pcy >= ScreenHeight:
          continue
        if not viewerIsGhost and sim.shadowBuf[pcy * ScreenWidth + pcx]:
          continue
      sim.fb.blitSpriteOutlined(sim.playerSprite, sx, sy, p.color, p.flipH)
    elif viewerIsGhost:
      sim.fb.blitSpriteOutlined(sim.ghostSprite, sx, sy, p.color, p.flipH)

  if player.role == Crewmate:
    for t in 0 ..< sim.tasks.len:
      if not player.hasTask(t):
        continue
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
      if not viewerIsGhost and sim.shadowBuf[tcy * ScreenWidth + tcx]:
        continue
      sim.fb.blitSpriteRaw(sim.taskIconSprite, iconSx, iconSy)

  if player.role == Crewmate and ShowTaskArrows:
    let radarColor = 8'u8
    let margin = 0
    for t in 0 ..< sim.tasks.len:
      if not player.hasTask(t):
        continue
      let task = sim.tasks[t]
      if playerIndex < task.completed.len and task.completed[playerIndex]:
        continue
      let
        tcx = task.x + task.w div 2 - cameraX
        tcy = task.y + task.h div 2 - cameraY
      if tcx >= 0 and tcx < ScreenWidth and tcy >= 0 and tcy < ScreenHeight:
        continue
      let
        px = float(player.x + CollisionW div 2 - cameraX)
        py = float(player.y + CollisionH div 2 - cameraY)
        dx = float(tcx) - px
        dy = float(tcy) - py
      if abs(dx) < 0.5 and abs(dy) < 0.5:
        continue
      var ex, ey: float
      let
        minX = float(margin)
        maxX = float(ScreenWidth - 1 - margin)
        minY = float(margin)
        maxY = float(ScreenHeight - 1 - margin)
      if abs(dx) > abs(dy):
        if dx > 0:
          ex = maxX
        else:
          ex = minX
        ey = py + dy * (ex - px) / dx
        ey = clamp(ey, minY, maxY)
      else:
        if dy > 0:
          ey = maxY
        else:
          ey = minY
        ex = px + dx * (ey - py) / dy
        ex = clamp(ex, minX, maxX)
      sim.fb.putPixel(int(ex), int(ey), radarColor)

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

  let remaining = sim.totalTasksRemaining()
  let numStr = $remaining
  var dx = ScreenWidth - 1
  for i in countdown(numStr.high, 0):
    let d = ord(numStr[i]) - ord('0')
    dx -= sim.digitSprites[d].width
    sim.fb.blitSprite(sim.digitSprites[d], dx, 0, 0, 0)

  sim.fb.packFramebuffer()
  sim.fb.packed

proc initSimServer(): SimServer =
  result.fb = initFramebuffer()
  loadPalette(clientDataDir() / "pallete.png")
  result.letterSprites = loadLetterSprites(clientDataDir() / "letters.png")
  result.digitSprites = loadDigitSprites(clientDataDir() / "numbers.png")

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
  result.ghostSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 6, 0, SpriteSize, SpriteSize)
  )

  result.tasks = @[
    TaskStation(name: "Empty Garbage", x: 278, y: 233, w: 8, h: 8),
    TaskStation(name: "Upload Data (Comms)", x: 334, y: 212, w: 8, h: 8),
    TaskStation(name: "Fix Wires (Storage)", x: 287, y: 132, w: 8, h: 8),
    TaskStation(name: "Fix Wires (Electrical)", x: 222, y: 15, w: 8, h: 8),
    TaskStation(name: "Upload Data (Electrical)", x: 175, y: 145, w: 8, h: 8),
    TaskStation(name: "Calibrate Distributor", x: 215, y: 146, w: 8, h: 8),
    TaskStation(name: "Submit Scan", x: 200, y: 116, w: 8, h: 8),
    TaskStation(name: "Divert Power", x: 193, y: 146, w: 8, h: 8),
    TaskStation(name: "Inspect Sample", x: 211, y: 107, w: 8, h: 8),
    TaskStation(name: "Upload Data (Admin)", x: 298, y: 132, w: 8, h: 8),
    TaskStation(name: "Align Engine (Lower)", x: 93, y: 163, w: 8, h: 8),
    TaskStation(name: "Align Engine (Upper)", x: 101, y: 40, w: 8, h: 8),
    TaskStation(name: "Swipe Card", x: 332, y: 153, w: 8, h: 8),
    TaskStation(name: "Upload Data (Cafeteria)", x: 300, y: 14, w: 8, h: 8),
    TaskStation(name: "Empty Garbage (Upper)", x: 313, y: 27, w: 8, h: 8),
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

proc resetToLobby(sim: var SimServer) =
  sim.phase = Lobby
  sim.bodies = @[]
  sim.players = @[]
  sim.nextJoinOrder = 0
  sim.tickCount = 0
  sim.needsReregister = true
  for task in sim.tasks.mitems:
    task.completed = @[]

proc step(sim: var SimServer, inputs: openArray[InputState], prevInputs: openArray[InputState]) =
  inc sim.tickCount

  if sim.phase == Lobby:
    if sim.players.len >= MinPlayers:
      sim.startGame()
    return

  if sim.phase == GameOver:
    dec sim.gameOverTimer
    if sim.gameOverTimer <= 0:
      sim.resetToLobby()
    return

  if sim.phase == VoteResult:
    dec sim.voteState.resultTimer
    if sim.voteState.resultTimer <= 0:
      sim.applyVoteResult()
      sim.checkWinCondition()
    return

  if sim.phase == Voting:
    dec sim.voteState.voteTimer
    if sim.voteState.voteTimer <= 0:
      sim.tallyVotes()
      return
    for i in 0 ..< sim.players.len:
      if not sim.players[i].alive:
        continue
      let input =
        if i < inputs.len: inputs[i]
        else: InputState()
      let prev =
        if i < prevInputs.len: prevInputs[i]
        else: InputState()
      if (input.up and not prev.up) or (input.left and not prev.left):
        sim.moveCursor(i, -1)
      if (input.down and not prev.down) or (input.right and not prev.right):
        sim.moveCursor(i, 1)
      if input.attack and not prev.attack:
        let cur = sim.voteState.cursor[i]
        if cur == sim.players.len:
          sim.voteState.votes[i] = -2
        else:
          sim.voteState.votes[i] = cur
        if sim.allVotesCast():
          sim.tallyVotes()
    return

  let bodiesBeforeTick = sim.bodies.len
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
    let prev =
      if playerIndex < prevInputs.len: prevInputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input, prev, bodiesBeforeTick)

  sim.checkWinCondition()

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.spriteViewers = initTable[WebSocket, SpriteViewerState]()
  appState.closedSockets = @[]
  appState.spectators = @[]

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  for i in countdown(appState.spectators.high, 0):
    if appState.spectators[i] == websocket:
      appState.spectators.delete(i)
  if websocket in appState.spriteViewers:
    appState.spriteViewers.del(websocket)
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
  elif request.uri == SpriteWebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.spriteViewers[websocket] = SpriteViewerState()
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
        if websocket notin appState.spriteViewers:
          appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage and message.data.len == InputPacketBytes:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket notin appState.spriteViewers:
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
  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    tcpNoDelay = true
  )
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
    prevInputs: seq[InputState]

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]

    var spectatorList: seq[WebSocket] = @[]
    var
      spriteViewers: seq[WebSocket] = @[]
      spriteStates: seq[SpriteViewerState] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)
        var newSockets: seq[WebSocket] = @[]
        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == 0x7fffffff:
            newSockets.add(websocket)
        for websocket in newSockets:
          if sim.phase == Lobby:
            appState.playerIndices[websocket] = sim.addPlayer()
          else:
            appState.spectators.add(websocket)
            appState.playerIndices.del(websocket)
        inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = decodeInputMask(currentMask)
          appState.lastAppliedMasks[websocket] = currentMask
          sockets.add(websocket)
          playerIndices.add(playerIndex)
        spectatorList = appState.spectators
        for websocket, state in appState.spriteViewers.pairs:
          spriteViewers.add(websocket)
          spriteStates.add(state)

    sim.step(inputs, prevInputs)
    prevInputs = inputs

    if sim.needsReregister:
      sim.needsReregister = false
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            appState.playerIndices[websocket] = 0x7fffffff
          for websocket in appState.spectators:
            appState.playerIndices[websocket] = 0x7fffffff
          appState.spectators = @[]

    for i in 0 ..< sockets.len:
      let frameBlob = blobFromBytes(sim.buildFramePacket(playerIndices[i]))
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    if spectatorList.len > 0:
      let specBlob = blobFromBytes(sim.buildSpectatorFrame())
      for ws in spectatorList:
        try:
          ws.send(specBlob, BinaryMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              sim.removePlayer(ws)

    for i in 0 ..< spriteViewers.len:
      var nextState: SpriteViewerState
      let packet = sim.buildSpriteProtocolUpdates(spriteStates[i], nextState)
      if packet.len == 0:
        continue
      try:
        spriteViewers[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if spriteViewers[i] in appState.spriteViewers:
              appState.spriteViewers[spriteViewers[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(spriteViewers[i])

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

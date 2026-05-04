# This bot uses /player2 don't copy it as reference its experimental.
import
  std/[heapqueue, options, os, parseopt, random, strutils, times],
  pixie, silky, whisky, windy,
  supersnappy,
  protocol, ../sim

const
  PlayerScreenX = ScreenWidth div 2
  PlayerScreenY = ScreenHeight div 2
  PlayerWorldOffX = SpriteDrawOffX + PlayerScreenX - SpriteSize div 2
  PlayerWorldOffY = SpriteDrawOffY + PlayerScreenY - SpriteSize div 2
  PlayerDefaultPort = 2000
  Player2TaskArrowObjectBase = 7000
  ProtocolVoteIconObjectBase = 9300
  MaxDrainMessages = 512
  PathLookahead = 18
  TaskInnerMargin = 6
  TaskPreciseApproachRadius = 12
  CoastLookaheadTicks = 8
  CoastArrivalPadding = 1
  SteerDeadband = 2
  BrakeDeadband = 1
  StuckFrameThreshold = 8
  JiggleDuration = 16
  TaskHoldPadding = 8
  HomeSearchRadius = 20
  VoteListenTicks = 80
  VoteSkipPulseGap = 2
  ViewerWindowWidth = 1780
  ViewerWindowHeight = 980
  ViewerMargin = 16.0'f
  ViewerFrameScale = 4.0'f
  ViewerMapScale = 1.1'f
  ViewerBackground = rgbx(17, 20, 28, 255)
  ViewerPanel = rgbx(33, 38, 50, 255)
  ViewerPanelAlt = rgbx(25, 30, 41, 255)
  ViewerText = rgbx(226, 231, 240, 255)
  ViewerMutedText = rgbx(146, 155, 172, 255)
  ViewerViewport = rgbx(142, 193, 255, 180)
  ViewerButton = rgbx(255, 196, 88, 255)
  ViewerPlayer = rgbx(120, 255, 170, 255)
  ViewerCrew = rgbx(82, 168, 255, 255)
  ViewerImp = rgbx(255, 84, 96, 255)
  ViewerTask = rgbx(255, 132, 146, 255)
  ViewerTaskDone = rgbx(146, 155, 172, 255)
  ViewerPath = rgbx(119, 218, 255, 230)
  ViewerWalk = rgbx(46, 61, 75, 255)
  ViewerWall = rgbx(86, 50, 56, 255)
  ViewerUnknown = rgbx(22, 26, 36, 255)
  ViewerRadarLine = rgbx(255, 220, 92, 210)
  PlayerColorNames = [
    "red",
    "orange",
    "yellow",
    "light blue",
    "pink",
    "lime",
    "blue",
    "pale blue",
    "gray",
    "white",
    "dark brown",
    "brown",
    "dark teal",
    "green",
    "dark navy",
    "black"
  ]

type
  SpriteKind = enum
    SpriteUnknown
    SpriteMap
    SpriteTask
    SpriteArrow
    SpritePlayer
    SpriteGhost
    SpriteBody
    SpriteImposter
    SpriteImposterCooldown
    SpriteGhostIcon
    SpriteScreen
    SpriteCounter
    SpriteProgress
    SpriteText

  SpriteInfo = object
    defined: bool
    width: int
    height: int
    label: string
    kind: SpriteKind
    colorIndex: int
    pixels: seq[uint8]

  ObjectState = object
    present: bool
    x: int
    y: int
    z: int
    layer: int
    spriteId: int

  BotRole = enum
    RoleCrewmate
    RoleImposter

  TaskState = enum
    TaskUnknown
    TaskMandatory
    TaskCompleted

  PathNode = object
    priority: int
    index: int

  PathStep = object
    found: bool
    x: int
    y: int

  Goal = object
    found: bool
    index: int
    x: int
    y: int
    name: string
    state: TaskState

  PlayerSight = object
    joinOrder: int
    x: int
    y: int
    colorIndex: int
    ghost: bool

  BodySight = object
    x: int
    y: int
    colorIndex: int

  ViewerApp = ref object
    window: Window
    silky: Silky

  Bot = object
    sim: SimServer
    sprites: seq[SpriteInfo]
    objects: seq[ObjectState]
    rng: Rand
    role: BotRole
    isGhost: bool
    killReady: bool
    roleIconLabel: string
    localized: bool
    interstitial: bool
    interstitialText: string
    cameraX: int
    cameraY: int
    playerX: int
    playerY: int
    previousPlayerX: int
    previousPlayerY: int
    velocityX: int
    velocityY: int
    haveMotionSample: bool
    stuckFrames: int
    jiggleTicks: int
    jiggleSide: int
    taskStates: seq[TaskState]
    taskVisible: seq[bool]
    taskArrow: seq[bool]
    taskHoldIndex: int
    taskHoldTicks: int
    goalIndex: int
    imposterGoalIndex: int
    homeSet: bool
    homeX: int
    homeY: int
    hasGoal: bool
    goalX: int
    goalY: int
    goalName: string
    path: seq[PathStep]
    pathStep: PathStep
    visiblePlayers: seq[PlayerSight]
    visibleBodies: seq[BodySight]
    lastSeenTicks: seq[int]
    selfJoinOrder: int
    selfColorIndex: int
    lastBodySeenX: int
    lastBodySeenY: int
    pendingChat: string
    frameTick: int
    voteStartTick: int
    votePlayerCount: int
    voteStep: int
    voteDone: bool
    intent: string
    desiredMask: uint8
    controllerMask: uint8
    lastMask: uint8

proc mapIndexSafe(x, y: int): int =
  ## Returns the map pixel index.
  y * MapWidth + x

proc tileWidth(): int =
  ## Returns the path grid width in pixels.
  MapWidth

proc taskCenter(task: TaskStation): tuple[x: int, y: int] =
  ## Returns the center point for a task rectangle.
  (task.x + task.w div 2, task.y + task.h div 2)

proc atlasPath(): string =
  ## Returns the shared Silky atlas path.
  gameDir() / ".." / "clients" / "dist" / "atlas.png"

proc sampleColor(index: uint8): ColorRGBX =
  ## Converts one palette index to a viewer color.
  Palette[index and 0x0f].rgbx

proc colorFromRgbaBytes(
  pixels: openArray[uint8],
  offset: int
): ColorRGBX =
  ## Converts protocol RGBA bytes into a viewer color.
  rgbx(
    pixels[offset],
    pixels[offset + 1],
    pixels[offset + 2],
    pixels[offset + 3]
  )

proc `<`(a, b: PathNode): bool =
  ## Orders path nodes for Nim heapqueue.
  if a.priority == b.priority:
    return a.index < b.index
  a.priority < b.priority

proc colorIndexFromName(name: string): int =
  ## Returns the player color index for a protocol color name.
  let lower = name.toLowerAscii()
  for i, value in PlayerColorNames:
    if value == lower:
      return i
  -1

proc actorColorName(label, prefix: string): string =
  ## Extracts a player color name from an actor sprite label.
  result = label.substr(prefix.len).toLowerAscii()
  if result.endsWith(" right"):
    result.setLen(result.len - " right".len)
  elif result.endsWith(" left"):
    result.setLen(result.len - " left".len)
  result = result.strip()

proc classifySprite(label: string): tuple[kind: SpriteKind, colorIndex: int] =
  ## Classifies a sprite definition by its stable debugger label.
  let lower = label.toLowerAscii()
  result = (kind: SpriteUnknown, colorIndex: -1)
  if lower == "map":
    result.kind = SpriteMap
  elif lower == "task bubble":
    result.kind = SpriteTask
  elif lower == "task arrow":
    result.kind = SpriteArrow
  elif lower == "imposter icon":
    result.kind = SpriteImposter
  elif lower == "imposter icon cooldown":
    result.kind = SpriteImposterCooldown
  elif lower == "ghost icon":
    result.kind = SpriteGhostIcon
  elif lower == "player screen":
    result.kind = SpriteScreen
  elif lower.startsWith("task counter "):
    result.kind = SpriteCounter
  elif lower.startsWith("progress bar "):
    result.kind = SpriteProgress
  elif lower.startsWith("body "):
    result.kind = SpriteBody
    result.colorIndex = colorIndexFromName(lower.substr("body ".len))
  elif lower.startsWith("player "):
    result.kind = SpritePlayer
    result.colorIndex = colorIndexFromName(
      actorColorName(lower, "player ")
    )
  elif lower.startsWith("ghost "):
    result.kind = SpriteGhost
    result.colorIndex = colorIndexFromName(
      actorColorName(lower, "ghost ")
    )
  elif lower.startsWith("selected player "):
    result.kind = SpritePlayer
    result.colorIndex = colorIndexFromName(
      actorColorName(lower, "selected player ")
    )
  elif lower.startsWith("selected ghost "):
    result.kind = SpriteGhost
    result.colorIndex = colorIndexFromName(
      actorColorName(lower, "selected ghost ")
    )
  elif label.len > 0:
    result.kind = SpriteText

proc ensureSprite(bot: var Bot, spriteId: int) =
  ## Ensures the sprite table can hold a sprite id.
  if spriteId >= bot.sprites.len:
    bot.sprites.setLen(spriteId + 1)

proc ensureObject(bot: var Bot, objectId: int) =
  ## Ensures the object table can hold an object id.
  if objectId >= bot.objects.len:
    bot.objects.setLen(objectId + 1)

proc spriteInfo(bot: Bot, spriteId: int): SpriteInfo =
  ## Returns sprite metadata or an empty value for unknown sprites.
  if spriteId >= 0 and spriteId < bot.sprites.len:
    return bot.sprites[spriteId]
  SpriteInfo(kind: SpriteUnknown, colorIndex: -1)

proc objectSprite(bot: Bot, objectState: ObjectState): SpriteInfo =
  ## Returns sprite metadata for an object.
  bot.spriteInfo(objectState.spriteId)

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
      let classified = classifySprite(label)
      let rawPixels = supersnappy.uncompress(compressed)
      var pixels = newSeq[uint8](rawPixels.len)
      for i, ch in rawPixels:
        pixels[i] = ch.uint8
      if pixels.len != width * height * 4:
        pixels.setLen(0)
      bot.ensureSprite(spriteId)
      bot.sprites[spriteId] = SpriteInfo(
        defined: true,
        width: width,
        height: height,
        label: label,
        kind: classified.kind,
        colorIndex: classified.colorIndex,
        pixels: pixels
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

proc objectWorldX(bot: Bot, objectState: ObjectState): int =
  ## Converts an actor object X position into map coordinates.
  objectState.x + bot.cameraX + SpriteDrawOffX + 1

proc objectWorldY(bot: Bot, objectState: ObjectState): int =
  ## Converts an actor object Y position into map coordinates.
  objectState.y + bot.cameraY + SpriteDrawOffY + 1

proc roomNameAt(bot: Bot, x, y: int): string =
  ## Returns the room containing one world point.
  for room in bot.sim.rooms:
    if x >= room.x and x < room.x + room.w and
        y >= room.y and y < room.y + room.h:
      return room.name
  "unknown"

proc resetGameKnowledge(bot: var Bot) =
  ## Resets state that belongs to one round.
  bot.role = RoleCrewmate
  bot.isGhost = false
  bot.killReady = false
  bot.roleIconLabel = ""
  bot.taskStates = newSeq[TaskState](bot.sim.tasks.len)
  bot.taskVisible = newSeq[bool](bot.sim.tasks.len)
  bot.taskArrow = newSeq[bool](bot.sim.tasks.len)
  bot.taskHoldIndex = -1
  bot.taskHoldTicks = 0
  bot.goalIndex = -1
  bot.imposterGoalIndex = -1
  bot.homeSet = false
  bot.visiblePlayers.setLen(0)
  bot.visibleBodies.setLen(0)
  bot.pendingChat = ""
  bot.voteStartTick = -1
  bot.voteStep = 0
  bot.voteDone = false

proc rememberHome(bot: var Bot) =
  ## Records the bot's first reliable playing position as home.
  if bot.homeSet or not bot.localized or bot.interstitial:
    return
  bot.homeX = bot.playerX
  bot.homeY = bot.playerY
  bot.homeSet = true

proc updateMotion(bot: var Bot) =
  ## Updates local velocity and stuck detection from exact map position.
  if not bot.localized:
    bot.haveMotionSample = false
    bot.velocityX = 0
    bot.velocityY = 0
    return
  if bot.haveMotionSample:
    bot.velocityX = bot.playerX - bot.previousPlayerX
    bot.velocityY = bot.playerY - bot.previousPlayerY
    let moving = (bot.lastMask and (
      ButtonUp or ButtonDown or ButtonLeft or ButtonRight
    )) != 0
    if moving and abs(bot.velocityX) + abs(bot.velocityY) == 0:
      inc bot.stuckFrames
    else:
      bot.stuckFrames = 0
    if bot.stuckFrames >= StuckFrameThreshold:
      bot.stuckFrames = 0
      bot.jiggleTicks = JiggleDuration
      bot.jiggleSide = 1 - bot.jiggleSide
  else:
    bot.velocityX = 0
    bot.velocityY = 0
    bot.stuckFrames = 0
  bot.haveMotionSample = true
  bot.previousPlayerX = bot.playerX
  bot.previousPlayerY = bot.playerY

proc updateTaskStates(bot: var Bot) =
  ## Updates exact task state from task bubble and task arrow objects.
  if bot.role == RoleImposter or not bot.localized or bot.interstitial:
    return
  for i in 0 ..< bot.sim.tasks.len:
    if bot.taskVisible[i] or bot.taskArrow[i]:
      bot.taskStates[i] = TaskMandatory
    elif bot.taskStates[i] == TaskMandatory and
        bot.taskHoldIndex != i:
      bot.taskStates[i] = TaskCompleted

proc sameBody(ax, ay, bx, by: int): bool =
  ## Returns true when two body sightings are probably the same body.
  if bx == low(int) or by == low(int):
    return false
  abs(ax - bx) + abs(ay - by) <= 6

proc playerColorName(colorIndex: int): string =
  ## Returns the visible player color name.
  if colorIndex >= 0 and colorIndex < PlayerColorNames.len:
    return PlayerColorNames[colorIndex]
  "unknown"

proc inputMaskSummary(mask: uint8): string =
  ## Returns a human-readable input mask.
  var parts: seq[string] = @[]
  if (mask and ButtonUp) != 0:
    parts.add("up")
  if (mask and ButtonDown) != 0:
    parts.add("down")
  if (mask and ButtonLeft) != 0:
    parts.add("left")
  if (mask and ButtonRight) != 0:
    parts.add("right")
  if (mask and ButtonA) != 0:
    parts.add("a")
  if (mask and ButtonB) != 0:
    parts.add("b")
  if (mask and ButtonSelect) != 0:
    parts.add("select")
  if parts.len == 0:
    return "idle"
  parts.join(", ")

proc suspectedColor(
  bot: Bot
): tuple[found: bool, colorIndex: int, tick: int] =
  ## Returns the most recently seen non-self crewmate color.
  var bestTick = -1
  for i, tick in bot.lastSeenTicks:
    if i == bot.selfColorIndex:
      continue
    if tick > bestTick:
      bestTick = tick
      result = (found: true, colorIndex: i, tick: tick)

proc bodyRoomMessage(bot: Bot, x, y: int): string =
  ## Builds the voting chat message for one body sighting.
  let room = bot.roomNameAt(x + CollisionW div 2, y + CollisionH div 2)
  result =
    if room == "unknown":
      "body"
    else:
      "body in " & room
  let suspect = bot.suspectedColor()
  if suspect.found:
    result.add(" sus ")
    result.add(playerColorName(suspect.colorIndex))

proc queueBodySeen(bot: var Bot, x, y: int) =
  ## Stores one body report message until voting begins.
  if sameBody(x, y, bot.lastBodySeenX, bot.lastBodySeenY):
    return
  bot.lastBodySeenX = x
  bot.lastBodySeenY = y
  bot.pendingChat = bot.bodyRoomMessage(x, y)

proc visibleVoteCount(bot: Bot): int =
  ## Counts voting candidate actor objects.
  for objectId, objectState in bot.objects:
    if not objectState.present:
      continue
    if objectId >= ProtocolVoteIconObjectBase:
      let info = bot.objectSprite(objectState)
      if info.kind in {SpritePlayer, SpriteBody}:
        result = max(result, objectId - ProtocolVoteIconObjectBase + 1)

proc analyzeObjects(bot: var Bot) =
  ## Rebuilds semantic state from the current object table.
  bot.localized = false
  bot.interstitial = false
  bot.interstitialText = ""
  bot.killReady = false
  bot.roleIconLabel = ""
  bot.visiblePlayers.setLen(0)
  bot.visibleBodies.setLen(0)
  if bot.taskVisible.len != bot.sim.tasks.len:
    bot.taskVisible = newSeq[bool](bot.sim.tasks.len)
  if bot.taskArrow.len != bot.sim.tasks.len:
    bot.taskArrow = newSeq[bool](bot.sim.tasks.len)
  for i in 0 ..< bot.taskVisible.len:
    bot.taskVisible[i] = false
    bot.taskArrow[i] = false

  var
    sawGhostIcon = false
    sawImposterIcon = false
    sawCooldownIcon = false
  for objectState in bot.objects:
    if not objectState.present:
      continue
    let info = bot.objectSprite(objectState)
    case info.kind
    of SpriteMap:
      bot.localized = true
      bot.cameraX = -objectState.x
      bot.cameraY = -objectState.y
      bot.playerX = bot.cameraX + PlayerWorldOffX
      bot.playerY = bot.cameraY + PlayerWorldOffY
    of SpriteScreen:
      bot.interstitial = true
    of SpriteText:
      if info.label.len > 0:
        if bot.interstitialText.len > 0:
          bot.interstitialText.add(" ")
        bot.interstitialText.add(info.label)
    of SpriteGhostIcon:
      sawGhostIcon = true
      bot.roleIconLabel = info.label
    of SpriteImposter:
      sawImposterIcon = true
      bot.roleIconLabel = info.label
    of SpriteImposterCooldown:
      sawCooldownIcon = true
      bot.roleIconLabel = info.label
    else:
      discard

  if bot.interstitialText.contains("CREW WINS") or
      bot.interstitialText.contains("IMPS WIN"):
    bot.resetGameKnowledge()

  if bot.localized and not bot.interstitial:
    bot.role =
      if sawImposterIcon or sawCooldownIcon:
        RoleImposter
      else:
        RoleCrewmate
    bot.killReady = sawImposterIcon
    bot.isGhost = sawGhostIcon

  if not bot.localized:
    bot.updateMotion()
    return

  for objectId, objectState in bot.objects:
    if not objectState.present:
      continue
    let info = bot.objectSprite(objectState)
    if info.kind == SpriteTask:
      let taskIndex = objectId - TaskObjectBase
      if taskIndex >= 0 and taskIndex < bot.taskVisible.len:
        bot.taskVisible[taskIndex] = true
    elif info.kind == SpriteArrow:
      let taskIndex = objectId - Player2TaskArrowObjectBase
      if taskIndex >= 0 and taskIndex < bot.taskArrow.len:
        bot.taskArrow[taskIndex] = true
    elif info.kind in {SpritePlayer, SpriteGhost} and
        objectId >= PlayerObjectBase:
      let sight = PlayerSight(
        joinOrder: objectId - PlayerObjectBase,
        x: bot.objectWorldX(objectState),
        y: bot.objectWorldY(objectState),
        colorIndex: info.colorIndex,
        ghost: info.kind == SpriteGhost
      )
      if abs(sight.x - bot.playerX) <= 1 and
          abs(sight.y - bot.playerY) <= 1:
        bot.selfJoinOrder = sight.joinOrder
        bot.selfColorIndex = sight.colorIndex
      bot.visiblePlayers.add(sight)
    elif info.kind == SpriteBody and objectId >= BodyObjectBase:
      bot.visibleBodies.add BodySight(
        x: bot.objectWorldX(objectState),
        y: bot.objectWorldY(objectState),
        colorIndex: info.colorIndex
      )

  for player in bot.visiblePlayers:
    if player.joinOrder == bot.selfJoinOrder:
      continue
    if abs(player.x - bot.playerX) <= 1 and
        abs(player.y - bot.playerY) <= 1:
      continue
    if player.colorIndex >= 0 and player.colorIndex < bot.lastSeenTicks.len:
      bot.lastSeenTicks[player.colorIndex] = bot.frameTick
  if bot.role == RoleCrewmate and not bot.isGhost:
    for body in bot.visibleBodies:
      bot.queueBodySeen(body.x, body.y)
      break
  bot.updateTaskStates()
  bot.rememberHome()
  bot.updateMotion()

proc passable(bot: Bot, x, y: int): bool =
  ## Returns true when a collision-sized body can occupy a pixel.
  if x < 0 or y < 0 or x + CollisionW >= MapWidth or
      y + CollisionH >= MapHeight:
    return false
  for dy in 0 ..< CollisionH:
    for dx in 0 ..< CollisionW:
      if not bot.sim.walkMask[mapIndexSafe(x + dx, y + dy)]:
        return false
  true

proc heuristic(ax, ay, bx, by: int): int =
  ## Returns Manhattan distance.
  abs(ax - bx) + abs(ay - by)

proc reconstructPath(
  parents: openArray[int],
  startIndex,
  goalIndex: int
): seq[PathStep] =
  ## Reconstructs a complete path from a parent table.
  var stepIndex = goalIndex
  while stepIndex != startIndex and stepIndex >= 0:
    result.add PathStep(
      found: true,
      x: stepIndex mod tileWidth(),
      y: stepIndex div tileWidth()
    )
    stepIndex = parents[stepIndex]
  for i in 0 ..< result.len div 2:
    swap(result[i], result[result.high - i])

proc findPath(bot: Bot, goalX, goalY: int): seq[PathStep] =
  ## Finds a complete A* pixel path toward a goal.
  let
    startX = bot.playerX
    startY = bot.playerY
    area = MapWidth * MapHeight
    startIndex = mapIndexSafe(startX, startY)
    goalIndex = mapIndexSafe(goalX, goalY)
  if not bot.passable(startX, startY) or not bot.passable(goalX, goalY):
    return
  var
    parents = newSeq[int](area)
    costs = newSeq[int](area)
    closed = newSeq[bool](area)
    openSet: HeapQueue[PathNode]
  for i in 0 ..< area:
    parents[i] = -2
    costs[i] = high(int)
  parents[startIndex] = -1
  costs[startIndex] = 0
  openSet.push PathNode(
    priority: heuristic(startX, startY, goalX, goalY),
    index: startIndex
  )
  while openSet.len > 0:
    let current = openSet.pop()
    if closed[current.index]:
      continue
    if current.index == goalIndex:
      return reconstructPath(parents, startIndex, goalIndex)
    closed[current.index] = true
    let
      x = current.index mod tileWidth()
      y = current.index div tileWidth()
    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nx = x + delta[0]
        ny = y + delta[1]
      if not bot.passable(nx, ny):
        continue
      let nextIndex = mapIndexSafe(nx, ny)
      if closed[nextIndex]:
        continue
      let newCost = costs[current.index] + 1
      if newCost >= costs[nextIndex]:
        continue
      costs[nextIndex] = newCost
      parents[nextIndex] = current.index
      openSet.push PathNode(
        priority: newCost + heuristic(nx, ny, goalX, goalY),
        index: nextIndex
      )

proc pathDistance(bot: Bot, goalX, goalY: int): int =
  ## Returns A* distance to a goal.
  if bot.playerX == goalX and bot.playerY == goalY:
    return 0
  let path = bot.findPath(goalX, goalY)
  if path.len == 0:
    return high(int)
  path.len

proc goalDistance(bot: Bot, goalX, goalY: int): int =
  ## Returns the distance metric for choosing goals.
  if bot.isGhost:
    return heuristic(bot.playerX, bot.playerY, goalX, goalY)
  bot.pathDistance(goalX, goalY)

proc taskGoalFor(bot: Bot, index: int, state: TaskState): Goal =
  ## Returns a reachable task goal inside one task rectangle.
  if index < 0 or index >= bot.sim.tasks.len:
    return
  let
    task = bot.sim.tasks[index]
    center = task.taskCenter()
  var
    bestDistance = high(int)
    bestX = 0
    bestY = 0

  proc iconVisibleAt(x, y: int): bool =
    ## Returns true when the full task icon would be visible.
    let
      cameraX = x - PlayerWorldOffX
      cameraY = y - PlayerWorldOffY
      iconWorldX = task.x + task.w div 2 - SpriteSize div 2
      iconWorldY = task.y - SpriteSize - 2
    for bobY in -1 .. 1:
      let
        iconX = iconWorldX - cameraX
        iconY = iconWorldY + bobY - cameraY
      if iconX < 0 or iconY < 0 or
          iconX + SpriteSize > ScreenWidth or
          iconY + SpriteSize > ScreenHeight:
        return false
    true

  template considerRange(x0, y0, x1, y1: int, requireIcon: bool) =
    for y in max(task.y, y0) ..< min(task.y + task.h, y1):
      for x in max(task.x, x0) ..< min(task.x + task.w, x1):
        if not bot.isGhost and not bot.passable(x, y):
          continue
        if requireIcon and not iconVisibleAt(x, y):
          continue
        let distance = heuristic(center.x, center.y, x, y)
        if distance < bestDistance:
          bestDistance = distance
          bestX = x
          bestY = y

  considerRange(
    task.x + TaskInnerMargin,
    task.y + TaskInnerMargin,
    task.x + task.w - TaskInnerMargin,
    task.y + task.h - TaskInnerMargin,
    true
  )
  if bestDistance == high(int):
    considerRange(
      task.x + TaskInnerMargin,
      task.y + TaskInnerMargin,
      task.x + task.w - TaskInnerMargin,
      task.y + task.h - TaskInnerMargin,
      false
    )
  if bestDistance == high(int):
    considerRange(task.x, task.y, task.x + task.w, task.y + task.h, false)
  if bestDistance == high(int):
    return
  Goal(
    found: true,
    index: index,
    x: bestX,
    y: bestY,
    name: task.name,
    state: state
  )

proc buttonGoal(bot: Bot): Goal =
  ## Returns a reachable point inside the emergency button rectangle.
  let
    button = bot.sim.gameMap.button
    centerX = button.x + button.w div 2
    centerY = button.y + button.h div 2
  var
    bestDistance = high(int)
    bestX = 0
    bestY = 0
  for y in button.y ..< button.y + button.h:
    for x in button.x ..< button.x + button.w:
      if not bot.isGhost and not bot.passable(x, y):
        continue
      let distance = heuristic(centerX, centerY, x, y)
      if distance < bestDistance:
        bestDistance = distance
        bestX = x
        bestY = y
  if bestDistance == high(int):
    return
  Goal(found: true, index: -1, x: bestX, y: bestY, name: "Button")

proc homeGoal(bot: Bot): Goal =
  ## Returns the remembered home position near the cafeteria table.
  if not bot.homeSet:
    return bot.buttonGoal()
  if bot.isGhost or bot.passable(bot.homeX, bot.homeY):
    return Goal(
      found: true,
      index: -1,
      x: bot.homeX,
      y: bot.homeY,
      name: "Home"
    )
  var
    bestDistance = high(int)
    bestX = 0
    bestY = 0
  for y in max(0, bot.homeY - HomeSearchRadius) ..
      min(MapHeight - 1, bot.homeY + HomeSearchRadius):
    for x in max(0, bot.homeX - HomeSearchRadius) ..
        min(MapWidth - 1, bot.homeX + HomeSearchRadius):
      if not bot.passable(x, y):
        continue
      let distance = heuristic(bot.homeX, bot.homeY, x, y)
      if distance < bestDistance:
        bestDistance = distance
        bestX = x
        bestY = y
  if bestDistance == high(int):
    return bot.buttonGoal()
  Goal(found: true, index: -1, x: bestX, y: bestY, name: "Home")

proc fakeTargetCount(bot: Bot): int =
  ## Returns the number of imposter fake targets.
  bot.sim.tasks.len + 1

proc fakeTargetGoalFor(bot: Bot, index: int): Goal =
  ## Returns an imposter fake task or button goal.
  if index == bot.sim.tasks.len:
    return bot.buttonGoal()
  bot.taskGoalFor(index, TaskUnknown)

proc fakeTargetCenter(bot: Bot, index: int): tuple[x: int, y: int] =
  ## Returns the center point for a fake target.
  if index == bot.sim.tasks.len:
    let button = bot.sim.gameMap.button
    return (button.x + button.w div 2, button.y + button.h div 2)
  bot.sim.tasks[index].taskCenter()

proc randomFakeTargetIndex(bot: var Bot): int =
  ## Returns a random fake target index for imposters.
  let count = bot.fakeTargetCount()
  if count <= 0:
    return -1
  bot.rng.rand(count - 1)

proc farthestFakeTargetIndexFrom(bot: Bot, originX, originY: int): int =
  ## Returns the fake target farthest from an origin.
  var bestDistance = low(int)
  result = -1
  for i in 0 ..< bot.fakeTargetCount():
    let center = bot.fakeTargetCenter(i)
    let distance = heuristic(originX, originY, center.x, center.y)
    if distance > bestDistance:
      bestDistance = distance
      result = i

proc nearestBody(bot: Bot): tuple[found: bool, x: int, y: int] =
  ## Returns the nearest visible dead body.
  var bestDistance = high(int)
  for body in bot.visibleBodies:
    let distance = heuristic(bot.playerX, bot.playerY, body.x, body.y)
    if distance < bestDistance:
      bestDistance = distance
      result = (found: true, x: body.x, y: body.y)

proc nearestVisibleCrewmate(
  bot: Bot
): tuple[found: bool, sight: PlayerSight, count: int] =
  ## Returns the nearest visible non-self alive crewmate.
  var bestDistance = high(int)
  for player in bot.visiblePlayers:
    if player.ghost:
      continue
    if player.joinOrder == bot.selfJoinOrder:
      continue
    if abs(player.x - bot.playerX) <= 1 and
        abs(player.y - bot.playerY) <= 1:
      continue
    inc result.count
    let distance = heuristic(bot.playerX, bot.playerY, player.x, player.y)
    if distance < bestDistance:
      bestDistance = distance
      result.found = true
      result.sight = player

proc inRange(bot: Bot, targetX, targetY, range: int): bool =
  ## Returns true when the bot is within a square-distance range.
  let
    ax = bot.playerX + CollisionW div 2
    ay = bot.playerY + CollisionH div 2
    bx = targetX + CollisionW div 2
    by = targetY + CollisionH div 2
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy <= range * range

proc coastDistance(velocity: int): int =
  ## Returns how many pixels current velocity will carry without input.
  var speed = abs(velocity)
  for _ in 0 ..< CoastLookaheadTicks:
    if speed <= 0:
      break
    result += speed
    speed = (speed * FrictionNum) div FrictionDen

proc shouldCoast(delta, velocity: int): bool =
  ## Returns true when existing velocity should reach the target.
  if delta > 0 and velocity > 0:
    return delta <= coastDistance(velocity) + CoastArrivalPadding
  if delta < 0 and velocity < 0:
    return -delta <= coastDistance(velocity) + CoastArrivalPadding

proc axisMask(delta, velocity: int, negativeMask, positiveMask: uint8): uint8 =
  ## Returns steering for one axis with coasting and braking.
  if delta > SteerDeadband:
    if shouldCoast(delta, velocity):
      return 0
    if velocity > 1 and delta <= abs(velocity) + BrakeDeadband:
      return negativeMask
    return positiveMask
  if delta < -SteerDeadband:
    if shouldCoast(delta, velocity):
      return 0
    if velocity < -1 and -delta <= abs(velocity) + BrakeDeadband:
      return positiveMask
    return negativeMask
  if velocity > 0:
    return negativeMask
  if velocity < 0:
    return positiveMask
  0

proc preciseAxisMask(
  delta,
  velocity: int,
  negativeMask,
  positiveMask: uint8
): uint8 =
  ## Returns exact final-approach steering with coasting.
  if delta > 0:
    if shouldCoast(delta, velocity):
      return 0
    if velocity > 1 and delta <= abs(velocity) + BrakeDeadband:
      return negativeMask
    return positiveMask
  if delta < 0:
    if shouldCoast(delta, velocity):
      return 0
    if velocity < -1 and -delta <= abs(velocity) + BrakeDeadband:
      return positiveMask
    return negativeMask
  if velocity > 0:
    return negativeMask
  if velocity < 0:
    return positiveMask
  0

proc maskForWaypoint(bot: Bot, waypoint: PathStep): uint8 =
  ## Converts a lookahead waypoint into a controller mask.
  if not waypoint.found:
    return 0
  let
    dx = waypoint.x - bot.playerX
    dy = waypoint.y - bot.playerY
  result = result or axisMask(dx, bot.velocityX, ButtonLeft, ButtonRight)
  result = result or axisMask(dy, bot.velocityY, ButtonUp, ButtonDown)

proc preciseMaskForGoal(bot: Bot, goalX, goalY: int): uint8 =
  ## Converts a nearby goal into exact final-approach steering.
  let
    dx = goalX - bot.playerX
    dy = goalY - bot.playerY
  result = result or preciseAxisMask(
    dx,
    bot.velocityX,
    ButtonLeft,
    ButtonRight
  )
  result = result or preciseAxisMask(
    dy,
    bot.velocityY,
    ButtonUp,
    ButtonDown
  )

proc choosePathStep(bot: Bot): PathStep =
  ## Returns a short lookahead waypoint from the current path.
  if bot.path.len == 0:
    return
  bot.path[min(bot.path.high, PathLookahead)]

proc hasMovement(mask: uint8): bool =
  ## Returns true when an input mask contains movement.
  (mask and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) != 0

proc applyJiggle(bot: var Bot, mask: uint8): uint8 =
  ## Adds a short perpendicular correction while keeping intent held.
  result = mask
  if bot.jiggleTicks <= 0 or not mask.hasMovement():
    return
  dec bot.jiggleTicks
  let
    vertical = (mask and (ButtonUp or ButtonDown)) != 0
    horizontal = (mask and (ButtonLeft or ButtonRight)) != 0
  if vertical and not horizontal:
    if bot.jiggleSide == 0:
      result = result or ButtonLeft
    else:
      result = result or ButtonRight
  elif horizontal and not vertical:
    if bot.jiggleSide == 0:
      result = result or ButtonUp
    else:
      result = result or ButtonDown
  elif bot.jiggleSide == 0:
    result = result or ButtonLeft
  else:
    result = result or ButtonRight

proc navigateToPoint(bot: var Bot, x, y: int, name: string): uint8 =
  ## Navigates toward one world point and returns the input mask.
  bot.hasGoal = true
  bot.goalX = x
  bot.goalY = y
  bot.goalName = name
  if bot.isGhost:
    bot.path.setLen(0)
    bot.pathStep = PathStep()
    bot.intent = "ghost direct to " & name
    return bot.preciseMaskForGoal(x, y)
  bot.path = bot.findPath(x, y)
  bot.pathStep = bot.choosePathStep()
  bot.intent = "A* to " & name & " path=" & $bot.path.len
  if heuristic(bot.playerX, bot.playerY, x, y) <= TaskPreciseApproachRadius:
    bot.intent = "precise approach to " & name
    return bot.preciseMaskForGoal(x, y)
  if bot.pathStep.found:
    return bot.applyJiggle(bot.maskForWaypoint(bot.pathStep))
  bot.preciseMaskForGoal(x, y)

proc taskReadyAtGoal(bot: Bot, index, goalX, goalY: int): bool =
  ## Returns true when a task can be held at a selected goal.
  if index < 0 or index >= bot.sim.tasks.len:
    return false
  let
    task = bot.sim.tasks[index]
    x = bot.playerX
    y = bot.playerY
    innerX0 = task.x + TaskInnerMargin
    innerY0 = task.y + TaskInnerMargin
    innerX1 = task.x + task.w - TaskInnerMargin
    innerY1 = task.y + task.h - TaskInnerMargin
  if x < task.x or x >= task.x + task.w or
      y < task.y or y >= task.y + task.h:
    return false
  if abs(bot.velocityX) + abs(bot.velocityY) > 1:
    return false
  if x >= innerX0 and x < innerX1 and y >= innerY0 and y < innerY1:
    return true
  heuristic(x, y, goalX, goalY) <= 1

proc holdTaskAction(bot: var Bot): uint8 =
  ## Holds only the action button while completing a task.
  let name =
    if bot.taskHoldIndex >= 0 and bot.taskHoldIndex < bot.sim.tasks.len:
      bot.sim.tasks[bot.taskHoldIndex].name
    else:
      "task"
  bot.intent = "doing task at " & name & " hold=" & $bot.taskHoldTicks
  if bot.taskHoldTicks > 0:
    dec bot.taskHoldTicks
  if bot.taskHoldTicks == 0:
    if bot.taskHoldIndex >= 0 and
        bot.taskHoldIndex < bot.taskStates.len:
      if bot.taskVisible[bot.taskHoldIndex] or
          bot.taskArrow[bot.taskHoldIndex]:
        bot.taskStates[bot.taskHoldIndex] = TaskMandatory
      else:
        bot.taskStates[bot.taskHoldIndex] = TaskCompleted
    bot.taskHoldIndex = -1
  ButtonA

proc freshA(bot: Bot): uint8 =
  ## Returns an action press only after releasing any previous action.
  if (bot.lastMask and ButtonA) != 0:
    return 0
  ButtonA

proc nearestTaskGoal(bot: Bot): Goal =
  ## Returns the closest known active task.
  var bestDistance = high(int)
  for i in 0 ..< bot.sim.tasks.len:
    if not bot.taskVisible[i]:
      continue
    let goal = bot.taskGoalFor(i, TaskMandatory)
    if not goal.found:
      continue
    let distance = bot.goalDistance(goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal
  if result.found:
    return
  if bot.goalIndex >= 0 and bot.goalIndex < bot.sim.tasks.len and
      bot.taskStates[bot.goalIndex] == TaskMandatory:
    let goal = bot.taskGoalFor(bot.goalIndex, TaskMandatory)
    if goal.found:
      return goal
  bestDistance = high(int)
  for i in 0 ..< bot.sim.tasks.len:
    if bot.taskStates[i] != TaskMandatory:
      continue
    let goal = bot.taskGoalFor(i, TaskMandatory)
    if not goal.found:
      continue
    let distance = bot.goalDistance(goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal
  if result.found:
    return
  return bot.homeGoal()

proc decideCrewmateMask(bot: var Bot): uint8 =
  ## Chooses crewmate movement, reporting, and task actions.
  if not bot.localized:
    bot.intent = "not localized"
    return 0
  if bot.taskHoldTicks > 0:
    return bot.holdTaskAction()
  if not bot.isGhost:
    let body = bot.nearestBody()
    if body.found:
      if bot.inRange(body.x, body.y, bot.sim.config.reportRange):
        bot.intent = "report body"
        return bot.freshA()
      bot.intent = "move to body"
      return bot.navigateToPoint(body.x, body.y, "Body")
  let goal = bot.nearestTaskGoal()
  if not goal.found:
    bot.intent = "idle"
    return 0
  bot.goalIndex = goal.index
  if goal.index >= 0 and bot.taskReadyAtGoal(goal.index, goal.x, goal.y):
    bot.taskHoldIndex = goal.index
    bot.taskHoldTicks = bot.sim.config.taskCompleteTicks + TaskHoldPadding
    return bot.holdTaskAction()
  bot.navigateToPoint(goal.x, goal.y, goal.name)

proc decideImposterMask(bot: var Bot): uint8 =
  ## Chooses imposter movement and kill behavior.
  bot.taskHoldTicks = 0
  bot.taskHoldIndex = -1
  let body = bot.nearestBody()
  if body.found:
    bot.imposterGoalIndex = bot.farthestFakeTargetIndexFrom(body.x, body.y)
    let flee = bot.fakeTargetGoalFor(bot.imposterGoalIndex)
    if flee.found:
      return bot.navigateToPoint(flee.x, flee.y, flee.name)
  let crewmate = bot.nearestVisibleCrewmate()
  if crewmate.found:
    let targetName = playerColorName(crewmate.sight.colorIndex)
    if bot.killReady and
        bot.inRange(
          crewmate.sight.x,
          crewmate.sight.y,
          bot.sim.config.killRange
        ):
      bot.imposterGoalIndex = bot.farthestFakeTargetIndexFrom(
        bot.playerX,
        bot.playerY
      )
      bot.intent = "kill " & targetName
      return bot.freshA()
    let actionName =
      if bot.killReady:
        "chase " & targetName & " to kill"
      else:
        "shadow " & targetName & " on cooldown"
    return bot.navigateToPoint(
      crewmate.sight.x,
      crewmate.sight.y,
      actionName
    )
  if bot.imposterGoalIndex < 0 or
      bot.imposterGoalIndex >= bot.fakeTargetCount():
    bot.imposterGoalIndex = bot.randomFakeTargetIndex()
  var goal = bot.fakeTargetGoalFor(bot.imposterGoalIndex)
  if not goal.found:
    bot.imposterGoalIndex = bot.randomFakeTargetIndex()
    goal = bot.fakeTargetGoalFor(bot.imposterGoalIndex)
  if not goal.found:
    bot.intent = "idle imposter"
    return 0
  if heuristic(bot.playerX, bot.playerY, goal.x, goal.y) <= 2:
    bot.imposterGoalIndex = bot.randomFakeTargetIndex()
  bot.navigateToPoint(goal.x, goal.y, goal.name)

proc decideVotingMask(bot: var Bot): uint8 =
  ## Votes skip with edge-triggered navigation and action input.
  let count = bot.visibleVoteCount()
  if bot.voteStartTick < 0:
    bot.voteStartTick = bot.frameTick
    bot.votePlayerCount = count
    bot.voteStep = 0
    bot.voteDone = false
  if bot.pendingChat.len > 0:
    bot.intent = "chatting body report"
    return 0
  if bot.voteDone:
    bot.intent = "vote done"
    return 0
  let listened = bot.frameTick - bot.voteStartTick
  if listened < VoteListenTicks:
    bot.intent = "listening vote chat"
    return 0
  let totalSteps = max(bot.votePlayerCount, count)
  if bot.voteStep < totalSteps:
    if bot.frameTick mod VoteSkipPulseGap == 0:
      inc bot.voteStep
      bot.intent = "voting cursor to skip"
      return ButtonRight
    bot.intent = "release vote cursor"
    return 0
  let mask = bot.freshA()
  bot.intent = "vote skip"
  if mask == ButtonA:
    bot.voteDone = true
  mask

proc decideNextMask(bot: var Bot): uint8 =
  ## Chooses the next input mask from semantic sprite protocol state.
  bot.analyzeObjects()
  bot.hasGoal = false
  if bot.interstitial:
    if bot.interstitialText.contains("SKIP"):
      result = bot.decideVotingMask()
      bot.desiredMask = result
      bot.controllerMask = result
      return
    bot.intent = "interstitial"
    bot.voteStartTick = -1
    bot.desiredMask = 0
    bot.controllerMask = 0
    return 0
  bot.voteStartTick = -1
  if bot.role == RoleImposter:
    result = bot.decideImposterMask()
  else:
    result = bot.decideCrewmateMask()
  bot.desiredMask = result
  bot.controllerMask = result

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

proc acceptServerMessage(
  ws: WebSocket,
  message: Message,
  bot: var Bot
): bool =
  ## Handles one websocket message and updates sprite state.
  case message.kind
  of BinaryMessage:
    result = bot.applySpritePacket(message.data)
    inc bot.frameTick
  of Ping:
    ws.send(message.data, Pong)
  of TextMessage, Pong:
    discard

proc receiveUpdates(ws: WebSocket, bot: var Bot, gui: bool): bool =
  ## Receives and applies all currently queued sprite protocol updates.
  let firstMessage = ws.receiveMessage(if gui: 10 else: -1)
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

proc initBot(mapPath = ""): Bot =
  ## Builds a bot and loads map data for navigation.
  setCurrentDir(gameDir())
  var config = defaultGameConfig()
  if mapPath.len > 0:
    config.mapPath = mapPath
  result.sim = initSimServer(config)
  result.rng = initRand(getTime().toUnix() xor int64(getCurrentProcessId()))
  result.taskStates = newSeq[TaskState](result.sim.tasks.len)
  result.taskVisible = newSeq[bool](result.sim.tasks.len)
  result.taskArrow = newSeq[bool](result.sim.tasks.len)
  result.lastSeenTicks = newSeq[int](PlayerColorNames.len)
  for item in result.lastSeenTicks.mitems:
    item = -1
  result.role = RoleCrewmate
  result.taskHoldIndex = -1
  result.goalIndex = -1
  result.imposterGoalIndex = -1
  result.selfJoinOrder = -1
  result.selfColorIndex = -1
  result.lastBodySeenX = low(int)
  result.lastBodySeenY = low(int)
  result.voteStartTick = -1

proc drawOutline(
  sk: Silky,
  pos,
  size: Vec2,
  color: ColorRGBX,
  thickness = 1.0'f
) =
  ## Draws an unfilled rectangle.
  sk.drawRect(pos, vec2(size.x, thickness), color)
  sk.drawRect(
    vec2(pos.x, pos.y + size.y - thickness),
    vec2(size.x, thickness),
    color
  )
  sk.drawRect(pos, vec2(thickness, size.y), color)
  sk.drawRect(
    vec2(pos.x + size.x - thickness, pos.y),
    vec2(thickness, size.y),
    color
  )

proc drawLine(sk: Silky, a, b: Vec2, color: ColorRGBX) =
  ## Draws a simple pixel-like line.
  let
    dx = b.x - a.x
    dy = b.y - a.y
    steps = max(1, int(max(abs(dx), abs(dy)) / 4.0'f))
  for i in 0 .. steps:
    let t = i.float32 / steps.float32
    sk.drawRect(
      vec2(a.x + dx * t - 1.0'f, a.y + dy * t - 1.0'f),
      vec2(3, 3),
      color
    )

proc taskStateColor(state: TaskState): ColorRGBX =
  ## Returns a viewer color for one task state.
  case state
  of TaskUnknown:
    ViewerTask
  of TaskMandatory:
    ViewerButton
  of TaskCompleted:
    ViewerTaskDone

proc actorViewerColor(sight: PlayerSight): ColorRGBX =
  ## Returns a viewer color for one visible actor.
  if sight.ghost:
    return ViewerMutedText
  ViewerCrew

proc screenPos(bot: Bot, worldX, worldY: int): tuple[x: int, y: int] =
  ## Converts a world point into screen pixels.
  (x: worldX - bot.cameraX, y: worldY - bot.cameraY)

proc drawSprite(
  sk: Silky,
  sprite: SpriteInfo,
  x,
  y,
  scale: float32
) =
  ## Draws one decoded protocol sprite.
  if sprite.width <= 0 or sprite.height <= 0:
    return
  if sprite.pixels.len != sprite.width * sprite.height * 4:
    return
  let pixelSize = vec2(max(1.0'f, scale), max(1.0'f, scale))
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let offset = (sy * sprite.width + sx) * 4
      if sprite.pixels[offset + 3] == 0:
        continue
      sk.drawRect(
        vec2(x + sx.float32 * scale, y + sy.float32 * scale),
        pixelSize,
        colorFromRgbaBytes(sprite.pixels, offset)
      )

proc drawScreenObjects(
  sk: Silky,
  bot: Bot,
  x,
  y,
  scale: float32,
  kinds: set[SpriteKind]
) =
  ## Draws decoded protocol objects in screen coordinates.
  for objectState in bot.objects:
    if not objectState.present:
      continue
    let sprite = bot.objectSprite(objectState)
    if sprite.kind notin kinds:
      continue
    sk.drawSprite(
      sprite,
      x + objectState.x.float32 * scale,
      y + objectState.y.float32 * scale,
      scale
    )

proc drawMapObjects(
  sk: Silky,
  bot: Bot,
  x,
  y,
  scale: float32,
  kinds: set[SpriteKind]
) =
  ## Draws decoded protocol objects in map coordinates.
  if not bot.localized:
    return
  for objectState in bot.objects:
    if not objectState.present:
      continue
    let sprite = bot.objectSprite(objectState)
    if sprite.kind notin kinds:
      continue
    sk.drawSprite(
      sprite,
      x + (bot.cameraX + objectState.x).float32 * scale,
      y + (bot.cameraY + objectState.y).float32 * scale,
      scale
    )

proc drawScreenView(sk: Silky, bot: Bot, x, y: float32) =
  ## Draws the reconstructed local camera view.
  let scale = ViewerFrameScale
  sk.drawRect(
    vec2(x, y),
    vec2(ScreenWidth.float32 * scale, ScreenHeight.float32 * scale),
    ViewerPanelAlt
  )
  if not bot.localized or bot.interstitial:
    discard sk.drawText(
      "Default",
      "interstitial",
      vec2(x + 10, y + 12),
      ViewerText
    )
    return
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let
        mx = bot.cameraX + sx
        my = bot.cameraY + sy
        color =
          if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
            sampleColor(MapVoidColor)
          else:
            sampleColor(bot.sim.mapPixels[mapIndexSafe(mx, my)])
      sk.drawRect(
        vec2(x + sx.float32 * scale, y + sy.float32 * scale),
        vec2(scale, scale),
        color
      )

  let
    killBox = bot.sim.config.killRange.float32 * scale
    selfPos = vec2(
      x + PlayerScreenX.float32 * scale,
      y + PlayerScreenY.float32 * scale
    )
  if bot.role == RoleImposter:
    sk.drawOutline(
      selfPos - vec2(killBox, killBox),
      vec2(killBox * 2, killBox * 2),
      if bot.killReady: ViewerImp else: ViewerMutedText,
      1
    )
  sk.drawRect(selfPos - vec2(4, 4), vec2(8, 8), ViewerPlayer)

  for i in 0 ..< bot.sim.tasks.len:
    let task = bot.sim.tasks[i]
    if i < bot.taskStates.len and bot.taskStates[i] == TaskCompleted:
      continue
    let
      taskPos = bot.screenPos(task.x, task.y)
      iconX = task.x + task.w div 2 - SpriteSize div 2 - bot.cameraX
      iconY = task.y - SpriteSize - 2 - bot.cameraY
    if taskPos.x + task.w >= 0 and taskPos.y + task.h >= 0 and
        taskPos.x < ScreenWidth and taskPos.y < ScreenHeight:
      sk.drawOutline(
        vec2(x + taskPos.x.float32 * scale, y + taskPos.y.float32 * scale),
        vec2(task.w.float32 * scale, task.h.float32 * scale),
        taskStateColor(bot.taskStates[i]),
        1
      )
    if i < bot.taskVisible.len and bot.taskVisible[i]:
      sk.drawOutline(
        vec2(x + iconX.float32 * scale, y + iconY.float32 * scale),
        vec2(SpriteSize.float32 * scale, SpriteSize.float32 * scale),
        ViewerButton,
        2
      )

  sk.drawScreenObjects(
    bot,
    x,
    y,
    scale,
    {SpriteTask, SpriteArrow, SpriteProgress}
  )
  sk.drawScreenObjects(bot, x, y, scale, {SpriteBody})
  sk.drawScreenObjects(bot, x, y, scale, {SpritePlayer, SpriteGhost})
  sk.drawScreenObjects(
    bot,
    x,
    y,
    scale,
    {
      SpriteImposter,
      SpriteImposterCooldown,
      SpriteGhostIcon,
      SpriteCounter
    }
  )

  for body in bot.visibleBodies:
    let pos = bot.screenPos(body.x - SpriteDrawOffX, body.y - SpriteDrawOffY)
    sk.drawOutline(
      vec2(x + pos.x.float32 * scale, y + pos.y.float32 * scale),
      vec2((SpriteSize + 2).float32 * scale, (SpriteSize + 2).float32 * scale),
      ViewerImp,
      2
    )

  for sight in bot.visiblePlayers:
    let
      pos = bot.screenPos(
        sight.x - SpriteDrawOffX - 1,
        sight.y - SpriteDrawOffY - 1
      )
      color =
        if sight.joinOrder == bot.selfJoinOrder:
          ViewerPlayer
        else:
          sight.actorViewerColor()
    sk.drawOutline(
      vec2(x + pos.x.float32 * scale, y + pos.y.float32 * scale),
      vec2((SpriteSize + 2).float32 * scale, (SpriteSize + 2).float32 * scale),
      color,
      2
    )

  let targetCrewmate = bot.nearestVisibleCrewmate()
  if targetCrewmate.found:
    let target = bot.screenPos(
      targetCrewmate.sight.x,
      targetCrewmate.sight.y
    )
    let targetPos = vec2(
      x + target.x.float32 * scale,
      y + target.y.float32 * scale
    )
    sk.drawLine(
      selfPos,
      targetPos,
      if bot.inRange(
        targetCrewmate.sight.x,
        targetCrewmate.sight.y,
        bot.sim.config.killRange
      ):
        ViewerImp
      else:
        ViewerRadarLine
    )

proc drawMapView(sk: Silky, bot: Bot, x, y: float32) =
  ## Draws the map, actors, path, and semantic goals.
  let scale = ViewerMapScale
  sk.drawRect(
    vec2(x, y),
    vec2(MapWidth.float32 * scale, MapHeight.float32 * scale),
    ViewerUnknown
  )
  for my in countup(0, MapHeight - 1, 2):
    for mx in countup(0, MapWidth - 1, 2):
      let
        idx = mapIndexSafe(mx, my)
        color =
          if bot.sim.wallMask[idx]:
            ViewerWall
          elif bot.sim.walkMask[idx]:
            ViewerWalk
          else:
            sampleColor(bot.sim.mapPixels[idx])
      sk.drawRect(
        vec2(x + mx.float32 * scale, y + my.float32 * scale),
        vec2(max(1.0'f, scale * 2), max(1.0'f, scale * 2)),
        color
      )
  for i in 0 ..< bot.sim.tasks.len:
    let
      task = bot.sim.tasks[i]
      center = task.taskCenter()
      state =
        if i < bot.taskStates.len:
          bot.taskStates[i]
        else:
          TaskUnknown
      size =
        if i < bot.taskVisible.len and bot.taskVisible[i]:
          9.0'f
        elif i < bot.taskArrow.len and bot.taskArrow[i]:
          7.0'f
        else:
          5.0'f
    sk.drawRect(
      vec2(
        x + center.x.float32 * scale - size * 0.5,
        y + center.y.float32 * scale - size * 0.5
      ),
      vec2(size, size),
      taskStateColor(state)
    )
    if i < bot.taskArrow.len and bot.taskArrow[i] and bot.localized:
      sk.drawLine(
        vec2(x + bot.playerX.float32 * scale, y + bot.playerY.float32 * scale),
        vec2(x + center.x.float32 * scale, y + center.y.float32 * scale),
        ViewerRadarLine
      )

  let button = bot.sim.gameMap.button
  sk.drawOutline(
    vec2(x + button.x.float32 * scale, y + button.y.float32 * scale),
    vec2(button.w.float32 * scale, button.h.float32 * scale),
    ViewerButton,
    1
  )
  if bot.localized and not bot.interstitial:
    sk.drawOutline(
      vec2(x + bot.cameraX.float32 * scale, y + bot.cameraY.float32 * scale),
      vec2(ScreenWidth.float32 * scale, ScreenHeight.float32 * scale),
      ViewerViewport,
      1
    )
    let playerPos = vec2(
      x + bot.playerX.float32 * scale,
      y + bot.playerY.float32 * scale
    )
    sk.drawRect(playerPos - vec2(3, 3), vec2(7, 7), ViewerPlayer)
    if bot.role == RoleImposter:
      let range = bot.sim.config.killRange.float32 * scale
      sk.drawOutline(
        playerPos - vec2(range, range),
        vec2(range * 2, range * 2),
        if bot.killReady: ViewerImp else: ViewerMutedText,
        1
      )
  sk.drawMapObjects(bot, x, y, scale, {SpriteTask, SpriteProgress})
  sk.drawMapObjects(bot, x, y, scale, {SpriteBody})
  sk.drawMapObjects(bot, x, y, scale, {SpritePlayer, SpriteGhost})
  for sight in bot.visiblePlayers:
    let color =
      if sight.joinOrder == bot.selfJoinOrder:
        ViewerPlayer
      else:
        sight.actorViewerColor()
    sk.drawOutline(
      vec2(
        x + (sight.x - SpriteDrawOffX - 1).float32 * scale,
        y + (sight.y - SpriteDrawOffY - 1).float32 * scale
      ),
      vec2((SpriteSize + 2).float32 * scale, (SpriteSize + 2).float32 * scale),
      color,
      2
    )
  for body in bot.visibleBodies:
    sk.drawOutline(
      vec2(
        x + (body.x - SpriteDrawOffX - 1).float32 * scale,
        y + (body.y - SpriteDrawOffY - 1).float32 * scale
      ),
      vec2((SpriteSize + 2).float32 * scale, (SpriteSize + 2).float32 * scale),
      ViewerImp,
      2
    )
  if bot.hasGoal:
    sk.drawRect(
      vec2(x + bot.goalX.float32 * scale - 4, y + bot.goalY.float32 * scale - 4),
      vec2(9, 9),
      ViewerTask
    )
  if bot.path.len > 0:
    var previous = vec2(
      x + bot.playerX.float32 * scale,
      y + bot.playerY.float32 * scale
    )
    for i in countup(0, bot.path.high, 8):
      let current = vec2(
        x + bot.path[i].x.float32 * scale,
        y + bot.path[i].y.float32 * scale
      )
      sk.drawLine(previous, current, ViewerPath)
      previous = current
    if bot.hasGoal:
      sk.drawLine(
        previous,
        vec2(x + bot.goalX.float32 * scale, y + bot.goalY.float32 * scale),
        ViewerPath
      )

proc initViewerApp(): ViewerApp =
  ## Opens the diagnostic viewer window.
  loadPalette(clientDataDir() / "pallete.png")
  result = ViewerApp()
  result.window = newWindow(
    title = "Among Them Notsus Viewer",
    size = ivec2(ViewerWindowWidth, ViewerWindowHeight),
    style = Decorated,
    visible = true
  )
  makeContextCurrent(result.window)
  when not defined(useDirectX):
    loadExtensions()
  result.silky = newSilky(result.window, atlasPath())

proc viewerOpen(viewer: ViewerApp): bool =
  ## Returns true when the diagnostic viewer should keep running.
  viewer.isNil or not viewer.window.closeRequested

proc pumpViewer(
  viewer: ViewerApp,
  bot: Bot,
  connected: bool,
  url: string
) =
  ## Pumps and renders one viewer frame.
  if viewer.isNil:
    return
  pollEvents()
  if viewer.window.buttonPressed[KeyEscape]:
    viewer.window.closeRequested = true
  if viewer.window.closeRequested:
    return
  let
    frameSize = viewer.window.size
    framePos = vec2(ViewerMargin, ViewerMargin + 28)
    mapPos = vec2(
      framePos.x + ScreenWidth.float32 * ViewerFrameScale + 24,
      ViewerMargin + 28
    )
    mapSize = vec2(
      MapWidth.float32 * ViewerMapScale,
      MapHeight.float32 * ViewerMapScale
    )
    infoPos = vec2(
      ViewerMargin,
      framePos.y + ScreenHeight.float32 * ViewerFrameScale + 28
    )
    infoSize = vec2(frameSize.x.float32 - ViewerMargin * 2, 360)
    sk = viewer.silky
  sk.beginUI(viewer.window, frameSize)
  sk.clearScreen(ViewerBackground)
  discard sk.drawText(
    "Default",
    "Among Them Notsus Viewer",
    vec2(ViewerMargin, ViewerMargin),
    ViewerText
  )
  discard sk.drawText(
    "Default",
    "Semantic camera",
    vec2(framePos.x, framePos.y - 18),
    ViewerMutedText
  )
  discard sk.drawText(
    "Default",
    "Map",
    vec2(mapPos.x, mapPos.y - 18),
    ViewerMutedText
  )
  sk.drawRect(
    framePos - vec2(8, 8),
    vec2(
      ScreenWidth.float32 * ViewerFrameScale + 16,
      ScreenHeight.float32 * ViewerFrameScale + 16
    ),
    ViewerPanel
  )
  sk.drawRect(mapPos - vec2(8, 8), mapSize + vec2(16, 16), ViewerPanel)
  sk.drawRect(infoPos - vec2(8, 8), infoSize + vec2(16, 16), ViewerPanel)
  sk.drawScreenView(bot, framePos.x, framePos.y)
  sk.drawMapView(bot, mapPos.x, mapPos.y)

  discard connected
  discard url
  let infoText =
    "intent: " & bot.intent & "\n" &
    "buttons pressed: " & inputMaskSummary(bot.lastMask) & "\n" &
    "kill off cooldown: " & $bot.killReady
  discard sk.drawText(
    "Default",
    infoText,
    infoPos,
    ViewerText,
    infoSize.x,
    infoSize.y
  )
  sk.endUi()
  viewer.window.swapBuffers()

proc runBot(
  host = DefaultHost,
  port = PlayerDefaultPort,
  gui = false,
  name = "",
  mapPath = ""
) =
  ## Connects to an Among Them sprite player endpoint.
  var bot = initBot(mapPath)
  let url =
    if name.len > 0:
      "ws://" & host & ":" & $port & Player2WebSocketPath &
        "?name=" & name.queryEscape()
    else:
      "ws://" & host & ":" & $port & Player2WebSocketPath
  let viewer =
    if gui:
      initViewerApp()
    else:
      nil
  var connected = false
  while viewer.viewerOpen():
    try:
      let ws = newWebSocket(url)
      var lastMask = 0xff'u8
      connected = true
      while viewer.viewerOpen():
        if gui:
          viewer.pumpViewer(bot, connected, url)
          if not viewer.viewerOpen():
            ws.close()
            break
        if not ws.receiveUpdates(bot, gui):
          continue
        let nextMask = bot.decideNextMask()
        bot.lastMask = nextMask
        if nextMask != lastMask:
          ws.send(playerInputBlob(nextMask), BinaryMessage)
          lastMask = nextMask
        if bot.interstitial and bot.pendingChat.len > 0 and
            bot.interstitialText.contains("SKIP"):
          ws.send(chatBlob(bot.pendingChat), BinaryMessage)
          bot.pendingChat = ""
        if gui:
          viewer.pumpViewer(bot, connected, url)
    except CatchableError:
      connected = false
      if gui:
        let reconnectStart = epochTime()
        while viewer.viewerOpen() and epochTime() - reconnectStart < 0.25:
          viewer.pumpViewer(bot, connected, url)
          sleep(10)
      else:
        sleep(250)

when isMainModule:
  var
    address = DefaultHost
    port = PlayerDefaultPort
    gui = false
    name = ""
    mapPath = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "port":
        port = parseInt(val)
      of "gui":
        gui = true
      of "name":
        name = val
      of "map":
        mapPath = val
      else:
        discard
    else:
      discard
  if mapPath.len > 0 and not mapPath.isAbsolute():
    mapPath = absolutePath(mapPath)
  runBot(address, port, gui, name, mapPath)

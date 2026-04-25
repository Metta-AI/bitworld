import pixie, protocol, ../sim, ../../common/server, silky, whisky, windy
import std/[heapqueue, monotimes, options, os, parseopt, strutils, times]

const
  PlayerScreenX = ScreenWidth div 2
  PlayerScreenY = ScreenHeight div 2
  PlayerWorldOffX = SpriteDrawOffX + PlayerScreenX - SpriteSize div 2
  PlayerWorldOffY = SpriteDrawOffY + PlayerScreenY - SpriteSize div 2
  FullFrameFitMaxErrors = 180
  LocalFrameFitMaxErrors = 120
  FrameFitMinCompared = 12000
  LocalFrameSearchRadius = 8
  PlayerIgnoreRadius = 9
  PlayerDefaultPort = DefaultPort
  ViewerWindowWidth = 1820
  ViewerWindowHeight = 1060
  ViewerMargin = 16.0'f
  ViewerFrameScale = 4.0'f
  ViewerMapScale = 1.25'f
  ViewerBackground = rgbx(17, 20, 28, 255)
  ViewerPanel = rgbx(33, 38, 50, 255)
  ViewerPanelAlt = rgbx(25, 30, 41, 255)
  ViewerText = rgbx(226, 231, 240, 255)
  ViewerMutedText = rgbx(146, 155, 172, 255)
  ViewerViewport = rgbx(142, 193, 255, 180)
  ViewerButton = rgbx(255, 196, 88, 255)
  ViewerPlayer = rgbx(120, 255, 170, 255)
  ViewerTask = rgbx(255, 132, 146, 255)
  ViewerTaskGuess = rgbx(255, 220, 92, 255)
  ViewerRadarLine = rgbx(255, 220, 92, 210)
  ViewerPath = rgbx(119, 218, 255, 230)
  ViewerWalk = rgbx(46, 61, 75, 255)
  ViewerWall = rgbx(86, 50, 56, 255)
  ViewerUnknown = rgbx(22, 26, 36, 255)
  RadarTaskColor = 8'u8
  RadarPeripheryMargin = 1
  RadarMatchTolerance = 2
  TaskIconSearchRadius = 2
  TaskClearScreenMargin = 8
  TaskIconMissThreshold = 3
  PathLookahead = 18
  TaskInnerMargin = 4
  SteerDeadband = 2
  BrakeDeadband = 1
  StuckFrameThreshold = 8
  JiggleDuration = 16
  TaskHoldPadding = 8

type
  TileKnowledge = enum
    TileUnknown
    TileOpen
    TileWall

  CameraLock = enum
    NoLock
    LocalFrameMapLock
    FrameMapLock

  TaskState = enum
    TaskNotDoing
    TaskMaybe
    TaskMandatory
    TaskCompleted

  PathNode = object
    priority: int
    index: int

  PathStep = object
    found: bool
    x: int
    y: int

  CameraScore = object
    score: int
    errors: int
    compared: int

  RadarDot = object
    x: int
    y: int

  IconMatch = object
    x: int
    y: int

  ViewerApp = ref object
    window: Window
    silky: Silky

  Bot = object
    sim: SimServer
    playerSprite: Sprite
    taskSprite: Sprite
    packed: seq[uint8]
    unpacked: seq[uint8]
    mapTiles: seq[TileKnowledge]
    cameraX: int
    cameraY: int
    lastCameraX: int
    lastCameraY: int
    cameraLock: CameraLock
    cameraScore: int
    localized: bool
    haveMotionSample: bool
    previousPlayerWorldX: int
    previousPlayerWorldY: int
    velocityX: int
    velocityY: int
    stuckFrames: int
    jiggleTicks: int
    jiggleSide: int
    desiredMask: uint8
    controllerMask: uint8
    taskHoldTicks: int
    taskHoldIndex: int
    frameTick: int
    centerMicros: int
    astarMicros: int
    lastMask: uint8
    lastThought: string
    intent: string
    goalX: int
    goalY: int
    goalIndex: int
    goalName: string
    hasGoal: bool
    hasPathStep: bool
    pathStep: PathStep
    path: seq[PathStep]
    radarDots: seq[RadarDot]
    radarTasks: seq[bool]
    taskStates: seq[TaskState]
    taskIconMisses: seq[int]
    visibleTaskIcons: seq[IconMatch]

proc gameDir(): string =
  ## Returns the Among Them game directory.
  currentSourcePath().parentDir().parentDir()

proc atlasPath(): string =
  ## Returns the shared Silky atlas path.
  gameDir() / ".." / "client" / "dist" / "atlas.png"

proc unpack4bpp(packed: openArray[uint8], unpacked: var seq[uint8]) =
  ## Expands one packed 4 bit framebuffer into palette indices.
  let targetLen = packed.len * 2
  if unpacked.len != targetLen:
    unpacked.setLen(targetLen)
  for i, byte in packed:
    unpacked[i * 2] = byte and 0x0f
    unpacked[i * 2 + 1] = (byte shr 4) and 0x0f

proc sampleColor(index: uint8): ColorRGBX =
  ## Converts one palette index to a Silky color.
  Palette[index and 0x0f].rgbx

proc mapIndexSafe(x, y: int): int =
  ## Returns the map pixel index.
  y * MapWidth + x

proc minCameraX(): int =
  ## Returns the smallest possible centered camera X.
  -ScreenWidth div 2 - SpriteSize

proc maxCameraX(): int =
  ## Returns the largest possible centered camera X.
  MapWidth - ScreenWidth div 2 + SpriteSize

proc minCameraY(): int =
  ## Returns the smallest possible centered camera Y.
  -ScreenHeight div 2 - SpriteSize

proc maxCameraY(): int =
  ## Returns the largest possible centered camera Y.
  MapHeight - ScreenHeight div 2 + SpriteSize

proc inMap(x, y: int): bool =
  ## Returns true when a world pixel is inside the Skeld map.
  x >= 0 and y >= 0 and x < MapWidth and y < MapHeight

proc playerWorldX(bot: Bot): int =
  ## Returns the inferred player collision X coordinate.
  bot.cameraX + PlayerWorldOffX

proc playerWorldY(bot: Bot): int =
  ## Returns the inferred player collision Y coordinate.
  bot.cameraY + PlayerWorldOffY

proc taskCenter(task: TaskStation): tuple[x: int, y: int] =
  ## Returns the center pixel for a task station.
  (task.x + task.w div 2, task.y + task.h div 2)

proc `<`(a, b: PathNode): bool =
  ## Orders path nodes for Nim heapqueue.
  if a.priority == b.priority:
    return a.index < b.index
  a.priority < b.priority

proc tileWidth(): int =
  ## Returns the path grid width in pixels.
  MapWidth

proc ignoreTaskIconPixel(bot: Bot, sx, sy: int): bool =
  ## Returns true when a frame pixel belongs to a matched task icon.
  for icon in bot.visibleTaskIcons:
    let
      ix = sx - icon.x
      iy = sy - icon.y
    if ix < 0 or iy < 0 or
        ix >= bot.taskSprite.width or
        iy >= bot.taskSprite.height:
      continue
    if bot.taskSprite.pixels[bot.taskSprite.spriteIndex(ix, iy)] !=
        TransparentColorIndex:
      return true

proc ignoreFramePixel(bot: Bot, frameColor: uint8, sx, sy: int): bool =
  ## Returns true for dynamic screen pixels that are not map evidence.
  if frameColor == RadarTaskColor:
    return true
  if bot.ignoreTaskIconPixel(sx, sy):
    return true
  abs(sx - PlayerScreenX) <= PlayerIgnoreRadius and
    abs(sy - PlayerScreenY) <= PlayerIgnoreRadius

proc scoreCamera(bot: Bot, cameraX, cameraY, maxErrors: int): CameraScore =
  ## Counts map-fit errors for a full 128x128 frame rectangle.
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let frameColor = bot.unpacked[sy * ScreenWidth + sx]
      if bot.ignoreFramePixel(frameColor, sx, sy):
        continue
      let
        mx = cameraX + sx
        my = cameraY + sy
        mapColor =
          if inMap(mx, my):
            bot.sim.mapPixels[mapIndexSafe(mx, my)]
          else:
            SpaceColor
      if frameColor == mapColor:
        inc result.compared
      elif ShadowMap[mapColor and 0x0f] == frameColor:
        inc result.compared
      else:
        inc result.compared
        inc result.errors
        if result.errors > maxErrors:
          result.score = -result.errors
          return
  result.score = result.compared - result.errors * ScreenWidth

proc acceptCameraScore(score: CameraScore, maxErrors: int): bool =
  ## Returns true when a camera score is good enough to trust.
  score.errors <= maxErrors and score.compared >= FrameFitMinCompared

proc setCameraLock(
  bot: var Bot,
  x,
  y: int,
  score: CameraScore,
  lock: CameraLock
) =
  ## Stores one accepted camera lock.
  bot.cameraX = x
  bot.cameraY = y
  bot.cameraScore = score.score
  bot.cameraLock = lock
  bot.localized = true

proc scanTaskIcons(bot: var Bot)

proc locateNearFrame(bot: var Bot): bool =
  ## Tracks camera by scanning near the previous accepted camera.
  if not bot.localized:
    return false
  var
    bestScore = CameraScore(score: low(int), errors: high(int), compared: 0)
    bestX = bot.cameraX
    bestY = bot.cameraY
  let
    minX = max(minCameraX(), bot.cameraX - LocalFrameSearchRadius)
    maxX = min(maxCameraX(), bot.cameraX + LocalFrameSearchRadius)
    minY = max(minCameraY(), bot.cameraY - LocalFrameSearchRadius)
    maxY = min(maxCameraY(), bot.cameraY + LocalFrameSearchRadius)
  for y in minY .. maxY:
    for x in minX .. maxX:
      let score = bot.scoreCamera(x, y, LocalFrameFitMaxErrors)
      if score.errors < bestScore.errors or
          (score.errors == bestScore.errors and
          score.compared > bestScore.compared):
        bestScore = score
        bestX = x
        bestY = y
        if bestScore.errors == 0 and
            bestScore.compared >= FrameFitMinCompared:
          break
    if bestScore.errors == 0 and bestScore.compared >= FrameFitMinCompared:
      break
  if not acceptCameraScore(bestScore, LocalFrameFitMaxErrors):
    return false
  bot.setCameraLock(bestX, bestY, bestScore, LocalFrameMapLock)
  true

proc locateByFrame(bot: var Bot): bool =
  ## Locates the camera by fitting the full screen rectangle to the map.
  var
    bestScore = CameraScore(
      score: low(int),
      errors: high(int),
      compared: 0
    )
    bestX = 0
    bestY = 0
  for y in minCameraY() .. maxCameraY():
    for x in minCameraX() .. maxCameraX():
      let score = bot.scoreCamera(x, y, FullFrameFitMaxErrors)
      if score.errors < bestScore.errors or
          (score.errors == bestScore.errors and
          score.compared > bestScore.compared):
        bestScore = score
        bestX = x
        bestY = y
        if bestScore.errors == 0 and bestScore.compared >= FrameFitMinCompared:
          break
    if bestScore.errors == 0 and bestScore.compared >= FrameFitMinCompared:
      break
  if not acceptCameraScore(bestScore, FullFrameFitMaxErrors):
    bot.cameraLock = NoLock
    bot.cameraScore = bestScore.score
    bot.localized = false
    return false
  bot.setCameraLock(bestX, bestY, bestScore, FrameMapLock)
  true

proc updateLocation(bot: var Bot) =
  ## Updates the camera and player world estimate from the frame.
  bot.lastCameraX = bot.cameraX
  bot.lastCameraY = bot.cameraY
  bot.scanTaskIcons()
  if bot.locateNearFrame():
    return
  discard bot.locateByFrame()

proc rememberVisibleMap(bot: var Bot) =
  ## Copies visible walk and wall knowledge into the coarse map model.
  if not bot.localized:
    return
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let
        mx = bot.cameraX + sx
        my = bot.cameraY + sy
      if not inMap(mx, my):
        continue
      let idx = mapIndexSafe(mx, my)
      if bot.sim.wallMask[idx]:
        bot.mapTiles[idx] = TileWall
      elif bot.sim.walkMask[idx]:
        bot.mapTiles[idx] = TileOpen

proc isRadarPeriphery(x, y: int): bool =
  ## Returns true for pixels in the task radar strip.
  x <= RadarPeripheryMargin or y <= RadarPeripheryMargin or
    x >= ScreenWidth - 1 - RadarPeripheryMargin or
    y >= ScreenHeight - 1 - RadarPeripheryMargin

proc addRadarDot(dots: var seq[RadarDot], x, y: int) =
  ## Adds one radar dot unless a nearby dot is already present.
  for dot in dots:
    if abs(dot.x - x) <= 1 and abs(dot.y - y) <= 1:
      return
  dots.add(RadarDot(x: x, y: y))

proc scanRadarDots(bot: var Bot) =
  ## Scans screen periphery for yellow task radar pixels.
  bot.radarDots.setLen(0)
  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      if not isRadarPeriphery(x, y):
        continue
      if bot.unpacked[y * ScreenWidth + x] == RadarTaskColor:
        bot.radarDots.addRadarDot(x, y)

proc matchesSprite(
  frame: openArray[uint8],
  sprite: Sprite,
  x,
  y: int
): bool =
  ## Returns true if a sprite exactly matches the frame.
  if x < 0 or y < 0 or x + sprite.width > ScreenWidth or
      y + sprite.height > ScreenHeight:
    return false
  var matchedOpaque = 0
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let color = sprite.pixels[sprite.spriteIndex(sx, sy)]
      if color == TransparentColorIndex:
        continue
      inc matchedOpaque
      if frame[(y + sy) * ScreenWidth + x + sx] != color:
        return false
  matchedOpaque > 0

proc addIconMatch(matches: var seq[IconMatch], x, y: int) =
  ## Adds one icon match unless a nearby icon already exists.
  for match in matches:
    if abs(match.x - x) <= 1 and abs(match.y - y) <= 1:
      return
  matches.add(IconMatch(x: x, y: y))

proc scanTaskIcons(bot: var Bot) =
  ## Scans the current frame for visible task icons.
  bot.visibleTaskIcons.setLen(0)
  for y in 0 .. ScreenHeight - bot.taskSprite.height:
    for x in 0 .. ScreenWidth - bot.taskSprite.width:
      if matchesSprite(bot.unpacked, bot.taskSprite, x, y):
        bot.visibleTaskIcons.addIconMatch(x, y)

proc projectedRadarDot(
  bot: Bot,
  task: TaskStation
): tuple[visible: bool, x: int, y: int] =
  ## Projects an offscreen task center to its expected radar edge pixel.
  if not bot.localized:
    return
  let
    center = task.taskCenter()
    tcx = center.x - bot.cameraX
    tcy = center.y - bot.cameraY
  if tcx >= 0 and tcx < ScreenWidth and tcy >= 0 and tcy < ScreenHeight:
    return (true, tcx, tcy)
  let
    px = float(bot.playerWorldX() + CollisionW div 2 - bot.cameraX)
    py = float(bot.playerWorldY() + CollisionH div 2 - bot.cameraY)
    dx = float(tcx) - px
    dy = float(tcy) - py
  if abs(dx) < 0.5 and abs(dy) < 0.5:
    return
  let
    minX = 0.0
    maxX = float(ScreenWidth - 1)
    minY = 0.0
    maxY = float(ScreenHeight - 1)
  var
    ex: float
    ey: float
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
  (false, int(ex), int(ey))

proc updateTaskGuesses(bot: var Bot) =
  ## Updates ephemeral task candidates from radar dots.
  if bot.taskStates.len != bot.sim.tasks.len:
    bot.taskStates = newSeq[TaskState](bot.sim.tasks.len)
  if bot.radarTasks.len != bot.sim.tasks.len:
    bot.radarTasks = newSeq[bool](bot.sim.tasks.len)
  for i in 0 ..< bot.radarTasks.len:
    bot.radarTasks[i] = false
  if not bot.localized:
    return
  bot.scanRadarDots()
  if bot.radarDots.len == 0:
    return
  for i in 0 ..< bot.sim.tasks.len:
    let projected = bot.projectedRadarDot(bot.sim.tasks[i])
    if projected.visible:
      continue
    for dot in bot.radarDots:
      if abs(dot.x - projected.x) <= RadarMatchTolerance and
          abs(dot.y - projected.y) <= RadarMatchTolerance:
        if bot.taskStates[i] != TaskCompleted:
          bot.radarTasks[i] = true

proc projectedTaskIcon(
  bot: Bot,
  task: TaskStation,
  bobY: int
): tuple[visible: bool, x: int, y: int] =
  ## Returns the expected screen position for a visible task icon.
  if not bot.localized:
    return
  let
    iconX = task.x + task.w div 2 - SpriteSize div 2 - bot.cameraX
    iconY = task.y - SpriteSize - 2 + bobY - bot.cameraY
  if iconX + SpriteSize < 0 or iconY + SpriteSize < 0 or
      iconX >= ScreenWidth or iconY >= ScreenHeight:
    return
  (true, iconX, iconY)

proc taskIconRenderable(bot: Bot, task: TaskStation): bool =
  ## Returns true when the server could render the task icon.
  let
    center = task.taskCenter()
    sx = center.x - bot.cameraX
    sy = center.y - bot.cameraY
  sx >= 0 and sx < ScreenWidth and sy >= 0 and sy < ScreenHeight

proc taskIconSafelyVisible(bot: Bot, task: TaskStation): bool =
  ## Returns true when missing an icon is reliable evidence.
  if not bot.taskIconRenderable(task):
    return false
  let
    taskX = task.x - bot.cameraX
    taskY = task.y - bot.cameraY
  if taskX < 0 or taskY < 0 or
      taskX + task.w > ScreenWidth or
      taskY + task.h > ScreenHeight:
    return false
  for bobY in -1 .. 1:
    let projected = bot.projectedTaskIcon(task, bobY)
    if not projected.visible:
      return false
    if projected.x < TaskClearScreenMargin or
        projected.y < TaskClearScreenMargin or
        projected.x + SpriteSize > ScreenWidth - TaskClearScreenMargin or
        projected.y + SpriteSize > ScreenHeight - TaskClearScreenMargin:
      return false
  true

proc taskIconVisibleFor(bot: Bot, task: TaskStation): bool =
  ## Returns true if a visible task station has its icon on screen.
  if not bot.taskIconRenderable(task):
    return false
  for bobY in -1 .. 1:
    let projected = bot.projectedTaskIcon(task, bobY)
    if not projected.visible:
      continue
    for icon in bot.visibleTaskIcons:
      if abs(icon.x - projected.x) <= TaskIconSearchRadius and
          abs(icon.y - projected.y) <= TaskIconSearchRadius:
        return true

proc updateTaskIcons(bot: var Bot) =
  ## Updates task states from visible task icons.
  if bot.taskStates.len != bot.sim.tasks.len:
    bot.taskStates = newSeq[TaskState](bot.sim.tasks.len)
  if bot.taskIconMisses.len != bot.sim.tasks.len:
    bot.taskIconMisses = newSeq[int](bot.sim.tasks.len)
  if not bot.localized:
    return
  bot.scanTaskIcons()
  for i in 0 ..< bot.sim.tasks.len:
    let task = bot.sim.tasks[i]
    if bot.taskIconVisibleFor(task):
      bot.taskStates[i] = TaskMandatory
      bot.taskIconMisses[i] = 0
    elif bot.taskHoldTicks == 0 and
        (bot.taskStates[i] == TaskMandatory or
        (i < bot.radarTasks.len and bot.radarTasks[i])) and
        bot.taskIconSafelyVisible(task) and
        bot.taskHoldIndex != i:
      inc bot.taskIconMisses[i]
      if bot.taskIconMisses[i] >= TaskIconMissThreshold:
        bot.taskStates[i] = TaskCompleted
        bot.taskIconMisses[i] = 0
    else:
      bot.taskIconMisses[i] = 0

proc thought(bot: var Bot, text: string) =
  ## Emits changed bot thoughts to stdout.
  if text != bot.lastThought:
    bot.lastThought = text
    echo text

proc movementName(mask: uint8): string =
  ## Returns a compact movement label for one input mask.
  if (mask and ButtonLeft) != 0:
    return "left"
  if (mask and ButtonRight) != 0:
    return "right"
  if (mask and ButtonUp) != 0:
    return "up"
  if (mask and ButtonDown) != 0:
    return "down"
  "idle"

proc hasMovement(mask: uint8): bool =
  ## Returns true when an input mask contains directional movement.
  (mask and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) != 0

proc updateMotionState(bot: var Bot) =
  ## Tracks current frame-to-frame player velocity.
  if not bot.localized:
    bot.haveMotionSample = false
    bot.velocityX = 0
    bot.velocityY = 0
    bot.stuckFrames = 0
    bot.jiggleTicks = 0
    return

  let
    x = bot.playerWorldX()
    y = bot.playerWorldY()
  if bot.haveMotionSample and bot.lastMask.hasMovement():
    bot.velocityX = x - bot.previousPlayerWorldX
    bot.velocityY = y - bot.previousPlayerWorldY
    let moved = abs(bot.velocityX) + abs(bot.velocityY)
    if moved == 0:
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
  bot.previousPlayerWorldX = x
  bot.previousPlayerWorldY = y

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

proc inputMaskSummary(mask: uint8): string =
  ## Returns a human-readable input mask.
  var parts: seq[string] = @[]
  if (mask and ButtonUp) != 0: parts.add("up")
  if (mask and ButtonDown) != 0: parts.add("down")
  if (mask and ButtonLeft) != 0: parts.add("left")
  if (mask and ButtonRight) != 0: parts.add("right")
  if (mask and ButtonA) != 0: parts.add("a")
  if (mask and ButtonB) != 0: parts.add("b")
  if (mask and ButtonSelect) != 0: parts.add("select")
  if parts.len == 0:
    return "idle"
  parts.join(", ")

proc taskStateCount(bot: Bot, state: TaskState): int =
  ## Returns the number of tasks in one state.
  for taskState in bot.taskStates:
    if taskState == state:
      inc result

proc radarTaskCount(bot: Bot): int =
  ## Returns the number of current radar task candidates.
  for radarTask in bot.radarTasks:
    if radarTask:
      inc result

proc cameraLockName(lock: CameraLock): string =
  ## Returns a human-readable camera lock name.
  case lock
  of NoLock: "none"
  of LocalFrameMapLock: "local frame"
  of FrameMapLock: "frame map"

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
  ## Returns Manhattan distance for path search.
  abs(ax - bx) + abs(ay - by)

proc reconstructPath(
  parents: openArray[int],
  startIndex,
  goalIndex: int
): seq[PathStep] =
  ## Reconstructs a complete path from a parent table.
  var stepIndex = goalIndex
  while stepIndex != startIndex and stepIndex >= 0:
    result.add(PathStep(
      found: true,
      x: stepIndex mod tileWidth(),
      y: stepIndex div tileWidth()
    ))
    stepIndex = parents[stepIndex]
  for i in 0 ..< result.len div 2:
    swap(result[i], result[result.high - i])

proc findPath(bot: Bot, goalX, goalY: int): seq[PathStep] =
  ## Finds a complete A* pixel path toward a goal.
  let
    startX = bot.playerWorldX()
    startY = bot.playerWorldY()
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
  openSet.push(PathNode(
    priority: heuristic(startX, startY, goalX, goalY),
    index: startIndex
  ))
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
      openSet.push(PathNode(
        priority: newCost + heuristic(nx, ny, goalX, goalY),
        index: nextIndex
      ))

proc pathDistance(bot: Bot, goalX, goalY: int): int =
  ## Returns the real A* path distance to a goal.
  if bot.playerWorldX() == goalX and bot.playerWorldY() == goalY:
    return 0
  let path = bot.findPath(goalX, goalY)
  if path.len == 0:
    return high(int)
  path.len

proc taskGoalFor(
  bot: Bot,
  index: int,
  state: TaskState
): tuple[found: bool, index: int, x: int, y: int, name: string, state: TaskState] =
  ## Returns a task goal for one passable task index.
  if index < 0 or index >= bot.sim.tasks.len:
    return
  let
    task = bot.sim.tasks[index]
    center = task.taskCenter()
  if not bot.passable(center.x, center.y):
    return
  (true, index, center.x, center.y, task.name, state)

proc nearestTaskGoal(
  bot: Bot
): tuple[found: bool, index: int, x: int, y: int, name: string, state: TaskState] =
  ## Returns the closest known active task station center.
  var bestDistance = high(int)
  for i in 0 ..< bot.sim.tasks.len:
    if not bot.taskIconVisibleFor(bot.sim.tasks[i]):
      continue
    let goal = bot.taskGoalFor(i, TaskMandatory)
    if not goal.found:
      continue
    let distance = bot.pathDistance(goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal
  if result.found:
    return
  if bot.goalIndex >= 0 and
      bot.goalIndex < bot.sim.tasks.len and
      bot.taskStates.len == bot.sim.tasks.len and
      bot.taskStates[bot.goalIndex] == TaskMandatory:
    let goal = bot.taskGoalFor(bot.goalIndex, TaskMandatory)
    if goal.found:
      return goal
  bestDistance = high(int)
  for i in 0 ..< bot.sim.tasks.len:
    if bot.taskStates.len == bot.sim.tasks.len and
        bot.taskStates[i] != TaskMandatory:
      continue
    let goal = bot.taskGoalFor(i, TaskMandatory)
    if not goal.found:
      continue
    let distance = bot.pathDistance(goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal
  if result.found:
    return
  if bot.goalIndex >= 0 and
      bot.goalIndex < bot.sim.tasks.len and
      bot.radarTasks.len == bot.sim.tasks.len and
      bot.radarTasks[bot.goalIndex]:
    let goal = bot.taskGoalFor(bot.goalIndex, TaskMaybe)
    if goal.found:
      return goal
  bestDistance = high(int)
  for i in 0 ..< bot.sim.tasks.len:
    if bot.radarTasks.len != bot.sim.tasks.len or not bot.radarTasks[i]:
      continue
    let goal = bot.taskGoalFor(i, TaskMaybe)
    if not goal.found:
      continue
    let distance = bot.pathDistance(goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal

proc axisMask(delta, velocity: int, negativeMask, positiveMask: uint8): uint8 =
  ## Returns steering for one axis with simple momentum braking.
  if delta > SteerDeadband:
    if velocity > 1 and delta <= abs(velocity) + BrakeDeadband:
      return negativeMask
    return positiveMask
  if delta < -SteerDeadband:
    if velocity < -1 and -delta <= abs(velocity) + BrakeDeadband:
      return positiveMask
    return negativeMask
  if velocity > 0:
    return negativeMask
  if velocity < 0:
    return positiveMask
  0

proc maskForWaypoint(bot: Bot, waypoint: PathStep): uint8 =
  ## Converts a lookahead waypoint into a momentum-aware controller mask.
  if not waypoint.found:
    return 0
  let
    dx = waypoint.x - bot.playerWorldX()
    dy = waypoint.y - bot.playerWorldY()
  result = result or axisMask(dx, bot.velocityX, ButtonLeft, ButtonRight)
  result = result or axisMask(dy, bot.velocityY, ButtonUp, ButtonDown)

proc choosePathStep(bot: Bot): PathStep =
  ## Returns a short lookahead waypoint from the current path.
  if bot.path.len == 0:
    return
  let index = min(bot.path.high, PathLookahead)
  bot.path[index]

proc taskReady(bot: Bot, task: TaskStation): bool =
  ## Returns true when the player can safely hold action for a task.
  let
    x = bot.playerWorldX()
    y = bot.playerWorldY()
    innerX0 = task.x + TaskInnerMargin
    innerY0 = task.y + TaskInnerMargin
    innerX1 = task.x + task.w - TaskInnerMargin
    innerY1 = task.y + task.h - TaskInnerMargin
  if x < innerX0 or x >= innerX1 or y < innerY0 or y >= innerY1:
    return false
  abs(bot.velocityX) + abs(bot.velocityY) <= 1

proc holdTaskAction(bot: var Bot, name: string): uint8 =
  ## Holds only the action button while completing a task.
  bot.intent = "doing task at " & name & " hold=" & $bot.taskHoldTicks
  bot.desiredMask = ButtonA
  bot.controllerMask = ButtonA
  bot.hasPathStep = false
  bot.path.setLen(0)
  if bot.taskHoldTicks > 0:
    dec bot.taskHoldTicks
  if bot.taskHoldTicks == 0 and
      bot.taskHoldIndex >= 0 and
      bot.taskHoldIndex < bot.taskStates.len:
    bot.taskStates[bot.taskHoldIndex] = TaskCompleted
    bot.taskHoldIndex = -1
  bot.thought("at task " & name & ", holding action")
  ButtonA

proc decideNextMask(bot: var Bot): uint8 =
  ## Updates perception and chooses the next input mask.
  let centerStart = getMonoTime()
  bot.updateLocation()
  bot.centerMicros = int((getMonoTime() - centerStart).inMicroseconds)
  bot.astarMicros = 0
  bot.updateMotionState()
  bot.rememberVisibleMap()
  bot.updateTaskGuesses()
  bot.updateTaskIcons()
  bot.hasGoal = false
  bot.hasPathStep = false
  bot.path.setLen(0)
  bot.desiredMask = 0
  bot.controllerMask = 0
  bot.intent = "localizing"
  if not bot.localized:
    bot.thought("waiting for a reliable map lock")
    return 0
  if bot.taskHoldTicks > 0:
    return bot.holdTaskAction(
      if bot.goalName.len > 0:
        bot.goalName
      else:
        "task"
    )
  let goal = bot.nearestTaskGoal()
  if not goal.found:
    bot.intent = "localized, no task goal"
    bot.thought("localized near (" & $bot.playerWorldX() & ", " &
      $bot.playerWorldY() & ")")
    return 0
  bot.hasGoal = true
  bot.goalX = goal.x
  bot.goalY = goal.y
  bot.goalIndex = goal.index
  bot.goalName = goal.name
  if goal.state == TaskMandatory and
      goal.index >= 0 and
      goal.index < bot.sim.tasks.len and
      bot.taskReady(bot.sim.tasks[goal.index]):
    bot.taskHoldTicks = bot.sim.config.taskCompleteTicks + TaskHoldPadding
    bot.taskHoldIndex = goal.index
    return bot.holdTaskAction(goal.name)
  let astarStart = getMonoTime()
  bot.path = bot.findPath(goal.x, goal.y)
  bot.astarMicros = int((getMonoTime() - astarStart).inMicroseconds)
  bot.pathStep = bot.choosePathStep()
  bot.hasPathStep = bot.pathStep.found
  bot.intent = "A* to " & goal.name & " path=" & $bot.path.len &
    " state=" & $goal.state
  bot.desiredMask = bot.maskForWaypoint(bot.pathStep)
  bot.controllerMask = bot.desiredMask
  let mask = bot.applyJiggle(bot.controllerMask)
  bot.thought(
    "map lock " & cameraLockName(bot.cameraLock) & " at camera (" &
    $bot.cameraX & ", " & $bot.cameraY & "), next " &
    movementName(mask)
  )
  mask

proc sheetSprite(sheet: Image, cellX, cellY: int): Sprite =
  ## Extracts one 12x12 sprite from the local sprite sheet.
  spriteFromImage(
    sheet.subImage(cellX * SpriteSize, cellY * SpriteSize, SpriteSize, SpriteSize)
  )

proc initBot(): Bot =
  ## Builds a bot and loads all map and sprite data.
  setCurrentDir(gameDir())
  result.sim = initSimServer(defaultGameConfig())
  let sheet = readImage("spritesheet.png")
  result.playerSprite = sheet.sheetSprite(0, 0)
  result.taskSprite = sheet.sheetSprite(4, 0)
  result.packed = newSeq[uint8](ProtocolBytes)
  result.unpacked = newSeq[uint8](ScreenWidth * ScreenHeight)
  result.mapTiles = newSeq[TileKnowledge](MapWidth * MapHeight)
  result.radarTasks = newSeq[bool](result.sim.tasks.len)
  result.taskStates = newSeq[TaskState](result.sim.tasks.len)
  result.taskIconMisses = newSeq[int](result.sim.tasks.len)
  result.cameraX = clamp(ButtonX - 48, 0, MapWidth - ScreenWidth)
  result.cameraY = clamp(ButtonY - 66, 0, MapHeight - ScreenHeight)
  result.lastCameraX = result.cameraX
  result.lastCameraY = result.cameraY
  result.taskHoldIndex = -1
  result.goalIndex = -1
  result.cameraLock = NoLock
  result.intent = "waiting for first frame"

proc drawOutline(sk: Silky, pos, size: Vec2, color: ColorRGBX, thickness = 1.0) =
  ## Draws an unfilled rectangle.
  sk.drawRect(pos, vec2(size.x, thickness), color)
  sk.drawRect(vec2(pos.x, pos.y + size.y - thickness), vec2(size.x, thickness), color)
  sk.drawRect(pos, vec2(thickness, size.y), color)
  sk.drawRect(vec2(pos.x + size.x - thickness, pos.y), vec2(thickness, size.y), color)

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
  ## Returns a map marker color for a task state.
  case state
  of TaskNotDoing:
    ViewerTask
  of TaskMaybe:
    ViewerTaskGuess
  of TaskMandatory:
    ViewerButton
  of TaskCompleted:
    ViewerMutedText

proc drawFrameView(sk: Silky, bot: Bot, x, y: float32) =
  ## Draws the latest 128x128 game frame.
  let pixelScale = ViewerFrameScale
  sk.drawRect(
    vec2(x, y),
    vec2(ScreenWidth.float32 * pixelScale, ScreenHeight.float32 * pixelScale),
    ViewerPanelAlt
  )
  for py in 0 ..< ScreenHeight:
    for px in 0 ..< ScreenWidth:
      let index = bot.unpacked[py * ScreenWidth + px]
      sk.drawRect(
        vec2(x + px.float32 * pixelScale, y + py.float32 * pixelScale),
        vec2(pixelScale, pixelScale),
        sampleColor(index)
      )
  let
    buttonX = ButtonX - bot.cameraX
    buttonY = ButtonY - bot.cameraY
  if buttonX + ButtonW >= 0 and buttonY + ButtonH >= 0 and
      buttonX < ScreenWidth and buttonY < ScreenHeight:
    sk.drawOutline(
      vec2(x + buttonX.float32 * pixelScale, y + buttonY.float32 * pixelScale),
      vec2(ButtonW.float32 * pixelScale, ButtonH.float32 * pixelScale),
      ViewerButton,
      2
    )
  sk.drawRect(
    vec2(
      x + PlayerScreenX.float32 * pixelScale - 3,
      y + PlayerScreenY.float32 * pixelScale - 3
    ),
    vec2(7, 7),
    ViewerPlayer
  )
  let playerPos = vec2(
    x + PlayerScreenX.float32 * pixelScale,
    y + PlayerScreenY.float32 * pixelScale
  )
  for dot in bot.radarDots:
    let dotPos = vec2(
      x + dot.x.float32 * pixelScale + pixelScale * 0.5,
      y + dot.y.float32 * pixelScale + pixelScale * 0.5
    )
    sk.drawLine(playerPos, dotPos, ViewerRadarLine)
    sk.drawRect(dotPos - vec2(4, 4), vec2(9, 9), ViewerTaskGuess)
  for icon in bot.visibleTaskIcons:
    sk.drawOutline(
      vec2(
        x + icon.x.float32 * pixelScale,
        y + icon.y.float32 * pixelScale
      ),
      vec2(
        bot.taskSprite.width.float32 * pixelScale,
        bot.taskSprite.height.float32 * pixelScale
      ),
      ViewerButton,
      2
    )

proc drawMapView(sk: Silky, bot: Bot, x, y: float32) =
  ## Draws the map, inferred viewport, and known task stations.
  let scale = ViewerMapScale
  sk.drawRect(
    vec2(x, y),
    vec2(MapWidth.float32 * scale, MapHeight.float32 * scale),
    ViewerUnknown
  )
  for my in countup(0, MapHeight - 1, 2):
    for mx in countup(0, MapWidth - 1, 2):
      let idx = mapIndexSafe(mx, my)
      let color =
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
        if bot.taskStates.len == bot.sim.tasks.len:
          bot.taskStates[i]
        else:
          TaskNotDoing
    sk.drawRect(
      vec2(x + center.x.float32 * scale - 3, y + center.y.float32 * scale - 3),
      vec2(7, 7),
      taskStateColor(state)
    )
  if bot.taskStates.len == bot.sim.tasks.len:
    for i in 0 ..< bot.sim.tasks.len:
      let isRadarTask =
        bot.radarTasks.len == bot.sim.tasks.len and bot.radarTasks[i]
      if bot.taskStates[i] != TaskMandatory and not isRadarTask:
        continue
      let
        center = bot.sim.tasks[i].taskCenter()
        color =
          if bot.taskStates[i] == TaskMandatory:
            taskStateColor(TaskMandatory)
          else:
            taskStateColor(TaskMaybe)
        pos = vec2(
          x + center.x.float32 * scale - 5,
          y + center.y.float32 * scale - 5
        )
      sk.drawOutline(pos, vec2(11, 11), color, 2)
      if bot.localized:
        sk.drawLine(
          vec2(
            x + bot.playerWorldX().float32 * scale,
            y + bot.playerWorldY().float32 * scale
          ),
          pos + vec2(5, 5),
          ViewerRadarLine
        )
  sk.drawOutline(
    vec2(
      x + ButtonX.float32 * scale,
      y + ButtonY.float32 * scale
    ),
    vec2(ButtonW.float32 * scale, ButtonH.float32 * scale),
    ViewerButton,
    1
  )
  if bot.localized:
    sk.drawOutline(
      vec2(x + bot.cameraX.float32 * scale, y + bot.cameraY.float32 * scale),
      vec2(ScreenWidth.float32 * scale, ScreenHeight.float32 * scale),
      ViewerViewport,
      1
    )
    sk.drawRect(
      vec2(
        x + bot.playerWorldX().float32 * scale - 2,
        y + bot.playerWorldY().float32 * scale - 2
      ),
      vec2(5, 5),
      ViewerPlayer
    )
  if bot.hasGoal:
    sk.drawRect(
      vec2(x + bot.goalX.float32 * scale - 4, y + bot.goalY.float32 * scale - 4),
      vec2(9, 9),
      ViewerTask
    )
  if bot.path.len > 0:
    var previous = vec2(
      x + bot.playerWorldX().float32 * scale,
      y + bot.playerWorldY().float32 * scale
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
  if bot.hasPathStep:
    sk.drawRect(
      vec2(
        x + bot.pathStep.x.float32 * scale - 2,
        y + bot.pathStep.y.float32 * scale - 2
      ),
      vec2(5, 5),
      ViewerButton
    )

proc initViewerApp(): ViewerApp =
  ## Opens the diagnostic viewer window.
  result = ViewerApp()
  result.window = newWindow(
    title = "Among Them Bot Viewer",
    size = ivec2(ViewerWindowWidth, ViewerWindowHeight),
    style = Decorated,
    visible = true
  )
  makeContextCurrent(result.window)
  when not defined(useDirectX):
    loadExtensions()
  result.silky = newSilky(result.window, atlasPath())

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
    mapSize = vec2(MapWidth.float32 * ViewerMapScale, MapHeight.float32 * ViewerMapScale)
    infoPos = vec2(ViewerMargin, framePos.y + ScreenHeight.float32 * ViewerFrameScale + 28)
    infoSize = vec2(frameSize.x.float32 - ViewerMargin * 2, 300)
    sk = viewer.silky
  sk.beginUI(viewer.window, frameSize)
  sk.clearScreen(ViewerBackground)
  discard sk.drawText("Default", "Among Them Bot Viewer", vec2(ViewerMargin, ViewerMargin), ViewerText)
  discard sk.drawText("Default", "Live frame", vec2(framePos.x, framePos.y - 18), ViewerMutedText)
  discard sk.drawText("Default", "Map lock", vec2(mapPos.x, mapPos.y - 18), ViewerMutedText)
  sk.drawRect(
    framePos - vec2(8, 8),
    vec2(ScreenWidth.float32 * ViewerFrameScale + 16, ScreenHeight.float32 * ViewerFrameScale + 16),
    ViewerPanel
  )
  sk.drawRect(mapPos - vec2(8, 8), mapSize + vec2(16, 16), ViewerPanel)
  sk.drawRect(infoPos - vec2(8, 8), infoSize + vec2(16, 16), ViewerPanel)
  sk.drawFrameView(bot, framePos.x, framePos.y)
  sk.drawMapView(bot, mapPos.x, mapPos.y)
  let goalText =
    if bot.hasGoal:
      let ready =
        bot.goalIndex >= 0 and
        bot.goalIndex < bot.sim.tasks.len and
        bot.taskReady(bot.sim.tasks[bot.goalIndex])
      "goal: " & bot.goalName &
        " dist=" & $heuristic(
          bot.playerWorldX(),
          bot.playerWorldY(),
          bot.goalX,
          bot.goalY
        ) &
        " ready=" & $ready & "\n"
    else:
      "goal: none\n"
  let infoText =
    "status: " & (if connected: "connected" else: "reconnecting") & "\n" &
    "url: " & url & "\n" &
    "client tick: " & $bot.frameTick & "\n" &
    "BUTTONS HELD: " & inputMaskSummary(bot.lastMask) & "\n" &
    "timing center: " & $bot.centerMicros & "us (" &
      $(bot.centerMicros div 1000) & "ms)\n" &
    "timing A*: " & $bot.astarMicros & "us (" &
      $(bot.astarMicros div 1000) & "ms)\n" &
    "lock: " & cameraLockName(bot.cameraLock) & " score=" & $bot.cameraScore & "\n" &
    "camera: (" & $bot.cameraX & ", " & $bot.cameraY & ")\n" &
    "player: (" & $bot.playerWorldX() & ", " & $bot.playerWorldY() & ")\n" &
    "velocity: (" & $bot.velocityX & ", " & $bot.velocityY & ")\n" &
    "radar dots: " & $bot.radarDots.len &
      " radar tasks=" & $bot.radarTaskCount() &
      " task icons=" & $bot.visibleTaskIcons.len & "\n" &
    "tasks mandatory=" & $bot.taskStateCount(TaskMandatory) &
      " completed=" & $bot.taskStateCount(TaskCompleted) & "\n" &
    goalText &
    "intent: " & bot.intent & "\n" &
    "path pixels: " & $bot.path.len & "\n" &
    "desired: " & inputMaskSummary(bot.desiredMask) & "\n" &
    "controller: " & inputMaskSummary(bot.controllerMask) & "\n" &
    "stuck: " & $bot.stuckFrames & " jiggle=" & $bot.jiggleTicks & "\n" &
    "last thought: " & (if bot.lastThought.len > 0: bot.lastThought else: "waiting")
  discard sk.drawText("Default", infoText, infoPos, ViewerText, infoSize.x, infoSize.y)
  sk.endUi()
  viewer.window.swapBuffers()

proc viewerOpen(viewer: ViewerApp): bool =
  ## Returns true when the diagnostic viewer should keep running.
  viewer.isNil or not viewer.window.closeRequested

proc runBot(host = DefaultHost, port = PlayerDefaultPort, gui = false) =
  ## Connects to an Among Them server and processes player frames.
  var bot = initBot()
  let url = "ws://" & host & ":" & $port & WebSocketPath
  var
    viewer =
      if gui: initViewerApp()
      else: nil
    connected = false
  while viewer.viewerOpen():
    try:
      let ws = newWebSocket(url)
      var lastMask = 0xff'u8
      connected = true
      echo "Connected to ", url
      while viewer.viewerOpen():
        if gui:
          viewer.pumpViewer(bot, connected, url)
          if not viewer.viewerOpen():
            ws.close()
            break
        let message = ws.receiveMessage(if gui: 10 else: -1)
        if message.isNone:
          continue
        case message.get.kind
        of BinaryMessage:
          if message.get.data.len != ProtocolBytes:
            continue
          blobToBytes(message.get.data, bot.packed)
          unpack4bpp(bot.packed, bot.unpacked)
          inc bot.frameTick
          let nextMask = bot.decideNextMask()
          bot.lastMask = nextMask
          if nextMask != lastMask:
            ws.send(blobFromMask(nextMask), BinaryMessage)
            lastMask = nextMask
        of Ping:
          ws.send(message.get.data, Pong)
        of TextMessage, Pong:
          discard
    except Exception as e:
      connected = false
      echo "Bot reconnecting after error: ", e.msg
      if gui:
        let reconnectStart = getMonoTime()
        while viewer.viewerOpen() and
            (getMonoTime() - reconnectStart).inMilliseconds < 250:
          viewer.pumpViewer(bot, connected, url)
          sleep(10)
      else:
        sleep(250)

when isMainModule:
  var
    address = DefaultHost
    port = PlayerDefaultPort
    gui = false
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
      else:
        discard
    else:
      discard
  runBot(address, port, gui)

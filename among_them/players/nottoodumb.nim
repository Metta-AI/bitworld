import pixie, protocol, ../sim, ../../common/server, silky, whisky, windy
import std/[heapqueue, monotimes, options, os, parseopt, strutils, times]

const
  PlayerScreenX = ScreenWidth div 2
  PlayerScreenY = ScreenHeight div 2
  PlayerWorldOffX = SpriteDrawOffX + PlayerScreenX - SpriteSize div 2
  PlayerWorldOffY = SpriteDrawOffY + PlayerScreenY - SpriteSize div 2
  LocalSearchRadius = 12
  WideSearchStep = 2
  ButtonSearchMinScore = 520
  MapSearchMinScore = 360
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
  PathLookahead = 10
  TaskReachDistance = 5

type
  TileKnowledge = enum
    TileUnknown
    TileOpen
    TileWall

  CameraLock = enum
    NoLock
    ButtonLock
    LocalMapLock
    WideMapLock

  PathNode = object
    priority: int
    index: int

  PathStep = object
    found: bool
    x: int
    y: int

  RadarDot = object
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
    frameTick: int
    lastMask: uint8
    lastThought: string
    intent: string
    goalX: int
    goalY: int
    goalName: string
    hasGoal: bool
    hasPathStep: bool
    pathStep: PathStep
    path: seq[PathStep]
    radarDots: seq[RadarDot]
    taskGuesses: seq[bool]

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

proc scoreCamera(bot: Bot, cameraX, cameraY: int): int =
  ## Scores how well a camera position matches the current frame.
  if cameraX < 0 or cameraY < 0 or
      cameraX + ScreenWidth > MapWidth or
      cameraY + ScreenHeight > MapHeight:
    return low(int)
  for sy in countup(2, ScreenHeight - 3, 4):
    for sx in countup(2, ScreenWidth - 3, 4):
      let frameColor = bot.unpacked[sy * ScreenWidth + sx]
      if frameColor == 0'u8:
        continue
      let mapColor = bot.sim.mapPixels[mapIndexSafe(cameraX + sx, cameraY + sy)]
      if frameColor == mapColor:
        result += 3
      elif ShadowMap[mapColor and 0x0f] == frameColor:
        inc result
      else:
        dec result

proc scoreButtonAt(bot: Bot, screenX, screenY: int): int =
  ## Scores the emergency button template at one screen position.
  if screenX < 0 or screenY < 0 or
      screenX + ButtonW > ScreenWidth or
      screenY + ButtonH > ScreenHeight:
    return low(int)
  for by in 0 ..< ButtonH:
    for bx in 0 ..< ButtonW:
      let
        mapColor = bot.sim.mapPixels[mapIndexSafe(ButtonX + bx, ButtonY + by)]
        frameColor = bot.unpacked[(screenY + by) * ScreenWidth + screenX + bx]
      if frameColor == mapColor:
        result += 3
      elif ShadowMap[mapColor and 0x0f] == frameColor:
        inc result
      else:
        dec result

proc locateByButton(bot: var Bot): bool =
  ## Locates the camera by scanning for the emergency button.
  var
    bestScore = low(int)
    bestX = 0
    bestY = 0
  for y in 0 .. ScreenHeight - ButtonH:
    for x in 0 .. ScreenWidth - ButtonW:
      let score = bot.scoreButtonAt(x, y)
      if score > bestScore:
        bestScore = score
        bestX = x
        bestY = y
  if bestScore < ButtonSearchMinScore:
    return false
  bot.cameraX = clamp(ButtonX - bestX, 0, MapWidth - ScreenWidth)
  bot.cameraY = clamp(ButtonY - bestY, 0, MapHeight - ScreenHeight)
  bot.cameraScore = bestScore
  bot.cameraLock = ButtonLock
  bot.localized = true
  true

proc locateNearLast(bot: var Bot): bool =
  ## Tracks the camera using a local map search around the last lock.
  if not bot.localized:
    return false
  var
    bestScore = low(int)
    bestX = bot.cameraX
    bestY = bot.cameraY
  for y in max(0, bot.lastCameraY - LocalSearchRadius) ..
      min(MapHeight - ScreenHeight, bot.lastCameraY + LocalSearchRadius):
    for x in max(0, bot.lastCameraX - LocalSearchRadius) ..
        min(MapWidth - ScreenWidth, bot.lastCameraX + LocalSearchRadius):
      let score = bot.scoreCamera(x, y)
      if score > bestScore:
        bestScore = score
        bestX = x
        bestY = y
  if bestScore < MapSearchMinScore:
    return false
  bot.cameraX = bestX
  bot.cameraY = bestY
  bot.cameraScore = bestScore
  bot.cameraLock = LocalMapLock
  bot.localized = true
  true

proc locateWide(bot: var Bot): bool =
  ## Locates the camera with a coarse whole-map search.
  var
    bestScore = low(int)
    bestX = 0
    bestY = 0
  for y in countup(0, MapHeight - ScreenHeight, WideSearchStep):
    for x in countup(0, MapWidth - ScreenWidth, WideSearchStep):
      let score = bot.scoreCamera(x, y)
      if score > bestScore:
        bestScore = score
        bestX = x
        bestY = y
  if bestScore < MapSearchMinScore:
    bot.cameraLock = NoLock
    bot.cameraScore = bestScore
    return false
  bot.cameraX = bestX
  bot.cameraY = bestY
  bot.cameraScore = bestScore
  bot.cameraLock = WideMapLock
  bot.localized = true
  true

proc updateLocation(bot: var Bot) =
  ## Updates the camera and player world estimate from the frame.
  bot.lastCameraX = bot.cameraX
  bot.lastCameraY = bot.cameraY
  if bot.locateByButton():
    return
  if bot.locateNearLast():
    return
  discard bot.locateWide()

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
  ## Marks task candidates whose expected radar dots match yellow pixels.
  if bot.taskGuesses.len != bot.sim.tasks.len:
    bot.taskGuesses = newSeq[bool](bot.sim.tasks.len)
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
        bot.taskGuesses[i] = true

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

proc taskGuessCount(bot: Bot): int =
  ## Returns the number of task stations guessed from radar dots.
  for guessed in bot.taskGuesses:
    if guessed:
      inc result

proc cameraLockName(lock: CameraLock): string =
  ## Returns a human-readable camera lock name.
  case lock
  of NoLock: "none"
  of ButtonLock: "button"
  of LocalMapLock: "local map"
  of WideMapLock: "wide map"

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

proc nearestTaskGoal(bot: Bot): tuple[found: bool, x: int, y: int, name: string] =
  ## Returns the closest known task station center.
  var bestDistance = high(int)
  for i in 0 ..< bot.sim.tasks.len:
    let task = bot.sim.tasks[i]
    if bot.taskGuesses.len == bot.sim.tasks.len and not bot.taskGuesses[i]:
      continue
    let center = task.taskCenter()
    if not bot.passable(center.x, center.y):
      continue
    let distance = heuristic(bot.playerWorldX(), bot.playerWorldY(), center.x, center.y)
    if distance < bestDistance:
      bestDistance = distance
      result = (true, center.x, center.y, task.name)
  if result.found:
    return
  for task in bot.sim.tasks:
    let center = task.taskCenter()
    if not bot.passable(center.x, center.y):
      continue
    let distance = heuristic(bot.playerWorldX(), bot.playerWorldY(), center.x, center.y)
    if distance < bestDistance:
      bestDistance = distance
      result = (true, center.x, center.y, task.name)

proc maskForStep(bot: Bot, step: PathStep): uint8 =
  ## Converts a path step into a controller mask.
  if not step.found:
    return 0
  let
    dx = step.x - bot.playerWorldX()
    dy = step.y - bot.playerWorldY()
  if abs(dx) >= abs(dy):
    if dx < 0: return ButtonLeft
    if dx > 0: return ButtonRight
  else:
    if dy < 0: return ButtonUp
    if dy > 0: return ButtonDown
  0

proc choosePathStep(bot: Bot): PathStep =
  ## Returns a short lookahead waypoint from the current path.
  if bot.path.len == 0:
    return
  let index = min(bot.path.high, PathLookahead)
  bot.path[index]

proc nearGoal(bot: Bot): bool =
  ## Returns true when the player is close enough to work on the goal.
  if not bot.hasGoal:
    return false
  heuristic(
    bot.playerWorldX(),
    bot.playerWorldY(),
    bot.goalX,
    bot.goalY
  ) <= TaskReachDistance

proc decideNextMask(bot: var Bot): uint8 =
  ## Updates perception and chooses the next input mask.
  bot.updateLocation()
  bot.rememberVisibleMap()
  bot.updateTaskGuesses()
  bot.hasGoal = false
  bot.hasPathStep = false
  bot.path.setLen(0)
  bot.intent = "localizing"
  if not bot.localized:
    bot.thought("waiting for a reliable map lock")
    return 0
  let goal = bot.nearestTaskGoal()
  if not goal.found:
    bot.intent = "localized, no task goal"
    bot.thought("localized near (" & $bot.playerWorldX() & ", " &
      $bot.playerWorldY() & ")")
    return 0
  bot.hasGoal = true
  bot.goalX = goal.x
  bot.goalY = goal.y
  bot.goalName = goal.name
  if bot.nearGoal():
    bot.intent = "doing task at " & goal.name
    bot.thought("at task " & goal.name & ", holding action")
    return ButtonA
  bot.path = bot.findPath(goal.x, goal.y)
  bot.pathStep = bot.choosePathStep()
  bot.hasPathStep = bot.pathStep.found
  bot.intent = "A* to " & goal.name & " path=" & $bot.path.len
  let mask = bot.maskForStep(bot.pathStep)
  bot.thought(
    "map lock " & cameraLockName(bot.cameraLock) & " at camera (" &
    $bot.cameraX & ", " & $bot.cameraY & "), next " & movementName(mask)
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
  result.taskGuesses = newSeq[bool](result.sim.tasks.len)
  result.cameraX = clamp(ButtonX - 48, 0, MapWidth - ScreenWidth)
  result.cameraY = clamp(ButtonY - 66, 0, MapHeight - ScreenHeight)
  result.lastCameraX = result.cameraX
  result.lastCameraY = result.cameraY
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
  for task in bot.sim.tasks:
    let center = task.taskCenter()
    sk.drawRect(
      vec2(x + center.x.float32 * scale - 3, y + center.y.float32 * scale - 3),
      vec2(7, 7),
      ViewerTask
    )
  if bot.taskGuesses.len == bot.sim.tasks.len:
    for i in 0 ..< bot.sim.tasks.len:
      if not bot.taskGuesses[i]:
        continue
      let center = bot.sim.tasks[i].taskCenter()
      let pos = vec2(
        x + center.x.float32 * scale - 5,
        y + center.y.float32 * scale - 5
      )
      sk.drawOutline(pos, vec2(11, 11), ViewerTaskGuess, 2)
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
    infoSize = vec2(frameSize.x.float32 - ViewerMargin * 2, 160)
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
  let infoText =
    "status: " & (if connected: "connected" else: "reconnecting") & "\n" &
    "url: " & url & "\n" &
    "lock: " & cameraLockName(bot.cameraLock) & " score=" & $bot.cameraScore & "\n" &
    "camera: (" & $bot.cameraX & ", " & $bot.cameraY & ")\n" &
    "player: (" & $bot.playerWorldX() & ", " & $bot.playerWorldY() & ")\n" &
    "radar dots: " & $bot.radarDots.len & " task guesses=" &
      $bot.taskGuessCount() & "\n" &
    "intent: " & bot.intent & "\n" &
    "path pixels: " & $bot.path.len & "\n" &
    "next input: " & inputMaskSummary(bot.lastMask) & "\n" &
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

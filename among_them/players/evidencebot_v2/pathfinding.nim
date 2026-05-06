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

proc goalDistance(bot: Bot, goalX, goalY: int): int =
  ## Returns the distance metric for choosing the next goal.
  if bot.isGhost:
    return heuristic(bot.playerWorldX(), bot.playerWorldY(), goalX, goalY)
  bot.pathDistance(goalX, goalY)

proc taskGoalFor(
  bot: Bot,
  index: int,
  state: TaskState
): tuple[found: bool, index: int, x: int, y: int, name: string, state: TaskState] =
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
        if not bot.passable(x, y):
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
    considerRange(
      task.x,
      task.y,
      task.x + task.w,
      task.y + task.h,
      false
    )
  if bestDistance == high(int):
    return
  (true, index, bestX, bestY, task.name, state)

proc buttonGoal(
  bot: Bot
): tuple[found: bool, index: int, x: int, y: int, name: string, state: TaskState] =
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
      if not bot.passable(x, y):
        continue
      let distance = heuristic(centerX, centerY, x, y)
      if distance < bestDistance:
        bestDistance = distance
        bestX = x
        bestY = y
  if bestDistance == high(int):
    return
  (true, -1, bestX, bestY, "Button", TaskMaybe)

proc homeGoal(
  bot: Bot
): tuple[found: bool, index: int, x: int, y: int, name: string, state: TaskState] =
  ## Returns this bot's remembered cafeteria home point.
  if not bot.homeSet:
    return bot.buttonGoal()
  if bot.isGhost or bot.passable(bot.homeX, bot.homeY):
    return (true, -1, bot.homeX, bot.homeY, "Home", TaskMaybe)
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
  (true, -1, bestX, bestY, "Home", TaskMaybe)

proc fakeTargetCount(bot: Bot): int =
  ## Returns the number of imposter fake target areas.
  bot.sim.tasks.len + 1

proc fakeTargetGoalFor(
  bot: Bot,
  index: int
): tuple[found: bool, index: int, x: int, y: int, name: string, state: TaskState] =
  ## Returns an imposter fake goal for a task or the button.
  if index == bot.sim.tasks.len:
    return bot.buttonGoal()
  bot.taskGoalFor(index, TaskMaybe)

proc randomFakeTargetIndex(bot: var Bot): int =
  ## Returns a random imposter fake target index.
  let count = bot.fakeTargetCount()
  if count == 0:
    return -1
  bot.rng.rand(count - 1)

proc fakeTargetCenter(
  bot: Bot,
  index: int
): tuple[x: int, y: int] =
  ## Returns the center point for an imposter fake target.
  if index == bot.sim.tasks.len:
    let button = bot.sim.gameMap.button
    return (button.x + button.w div 2, button.y + button.h div 2)
  bot.sim.tasks[index].taskCenter()

proc farthestFakeTargetIndexFrom(bot: Bot, originX, originY: int): int =
  ## Returns the fake target farthest from an origin point.
  var bestDistance = low(int)
  result = -1
  for i in 0 ..< bot.fakeTargetCount():
    let center = bot.fakeTargetCenter(i)
    let distance = heuristic(originX, originY, center.x, center.y)
    if distance > bestDistance:
      bestDistance = distance
      result = i

proc farthestFakeTargetIndex(bot: Bot): int =
  ## Returns the fake target farthest from the current player location.
  bot.farthestFakeTargetIndexFrom(bot.playerWorldX(), bot.playerWorldY())

proc visibleCrewmateWorld(
  bot: Bot,
  crewmate: CrewmateMatch
): tuple[x: int, y: int] =
  ## Converts one visible crewmate match into world coordinates.
  (
    bot.cameraX + crewmate.x + SpriteDrawOffX,
    bot.cameraY + crewmate.y + SpriteDrawOffY
  )

proc loneVisibleCrewmate(
  bot: Bot
): tuple[found: bool, crewmate: CrewmateMatch] =
  ## Returns the only visible crewmate not known as an imposter.
  for crewmate in bot.visibleCrewmates:
    if bot.knownImposterColor(crewmate.colorIndex):
      continue
    if result.found:
      result.found = false
      return
    result.found = true
    result.crewmate = crewmate

proc visibleBodyWorld(bot: Bot, body: BodyMatch): tuple[x: int, y: int] =
  ## Converts one visible body match into world coordinates.
  (
    bot.cameraX + body.x + SpriteDrawOffX,
    bot.cameraY + body.y + SpriteDrawOffY
  )

proc nearestBody(bot: Bot): tuple[found: bool, x: int, y: int] =
  ## Returns the nearest visible body in world coordinates.
  var bestDistance = high(int)
  for body in bot.visibleBodies:
    let world = bot.visibleBodyWorld(body)
    let distance = heuristic(
      bot.playerWorldX(),
      bot.playerWorldY(),
      world.x,
      world.y
    )
    if distance < bestDistance:
      bestDistance = distance
      result = (true, world.x, world.y)

proc sameBody(ax, ay, bx, by: int): bool =
  ## Returns true when two body sightings are probably the same body.
  if bx == low(int) or by == low(int):
    return false
  heuristic(ax, ay, bx, by) <= BodySearchRadius + 4

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
    let distance = bot.goalDistance(goal.x, goal.y)
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
    let distance = bot.goalDistance(goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal
  if result.found:
    return
  if bot.goalIndex >= 0 and
      bot.goalIndex < bot.sim.tasks.len and
      bot.taskStates.len == bot.sim.tasks.len and
      bot.taskStates[bot.goalIndex] != TaskCompleted and
      bot.checkoutTasks.len == bot.sim.tasks.len and
      bot.checkoutTasks[bot.goalIndex]:
    let goal = bot.taskGoalFor(bot.goalIndex, TaskMaybe)
    if goal.found:
      return goal
  bestDistance = high(int)
  for i in 0 ..< bot.sim.tasks.len:
    if bot.checkoutTasks.len != bot.sim.tasks.len or
        not bot.checkoutTasks[i]:
      continue
    if bot.taskStates.len == bot.sim.tasks.len and
        bot.taskStates[i] == TaskCompleted:
      continue
    let goal = bot.taskGoalFor(i, TaskMaybe)
    if not goal.found:
      continue
    let distance = bot.goalDistance(goal.x, goal.y)
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
    let distance = bot.goalDistance(goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal
  if result.found:
    return
  if bot.buttonFallbackReady():
    return bot.homeGoal()

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

proc preciseAxisMask(delta, velocity: int, negativeMask, positiveMask: uint8): uint8 =
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
  ## Converts a lookahead waypoint into a momentum-aware controller mask.
  if not waypoint.found:
    return 0
  let
    dx = waypoint.x - bot.playerWorldX()
    dy = waypoint.y - bot.playerWorldY()
  result = result or axisMask(dx, bot.velocityX, ButtonLeft, ButtonRight)
  result = result or axisMask(dy, bot.velocityY, ButtonUp, ButtonDown)

proc preciseMaskForGoal(bot: Bot, goalX, goalY: int): uint8 =
  ## Converts a nearby goal into exact final-approach steering.
  let
    dx = goalX - bot.playerWorldX()
    dy = goalY - bot.playerWorldY()
  result = result or preciseAxisMask(dx, bot.velocityX, ButtonLeft, ButtonRight)
  result = result or preciseAxisMask(dy, bot.velocityY, ButtonUp, ButtonDown)

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

proc taskReadyAtGoal(bot: Bot, index, goalX, goalY: int): bool =
  ## Returns true when a task can be held at a selected goal.
  if index < 0 or index >= bot.sim.tasks.len:
    return false
  let
    task = bot.sim.tasks[index]
    x = bot.playerWorldX()
    y = bot.playerWorldY()
  if x < task.x or x >= task.x + task.w or
      y < task.y or y >= task.y + task.h:
    return false
  if abs(bot.velocityX) + abs(bot.velocityY) > 1:
    return false
  bot.taskReady(task) or heuristic(x, y, goalX, goalY) <= 1

proc taskGoalReady(
  bot: Bot,
  goal: tuple[
    found: bool,
    index: int,
    x: int,
    y: int,
    name: string,
    state: TaskState
  ]
): bool =
  ## Returns true when the selected goal is ready for task action.
  if not goal.found:
    return false
  bot.taskReadyAtGoal(goal.index, goal.x, goal.y)

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
    let task = bot.sim.tasks[bot.taskHoldIndex]
    if not bot.taskIconVisibleFor(task) and bot.taskIconClearAreaVisible(task):
      bot.taskStates[bot.taskHoldIndex] = TaskCompleted
      if bot.checkoutTasks.len == bot.sim.tasks.len:
        bot.checkoutTasks[bot.taskHoldIndex] = false
      # v2: latch resolved on successful completion. Even if a radar dot
      # later projects onto this station, we won't be lured back.
      if bot.taskResolved.len == bot.sim.tasks.len:
        bot.taskResolved[bot.taskHoldIndex] = true
    else:
      bot.taskStates[bot.taskHoldIndex] = TaskMandatory
    bot.taskHoldIndex = -1
  bot.thought("at task " & name & ", holding action")
  ButtonA

proc reportBodyAction(bot: var Bot, x, y: int): uint8 =
  ## Presses action to report a visible dead body.
  bot.intent = "reporting dead body"
  bot.desiredMask = ButtonA
  bot.controllerMask = ButtonA
  bot.hasPathStep = false
  bot.path.setLen(0)
  bot.taskHoldTicks = 0
  bot.taskHoldIndex = -1
  bot.queueBodyReport(x, y)
  bot.thought("reporting dead body")
  ButtonA

proc navigateToPoint(
  bot: var Bot,
  x,
  y: int,
  name: string,
  preciseRadius = TaskPreciseApproachRadius
): uint8 =
  ## Navigates toward one world point and returns the input mask.
  bot.hasGoal = true
  bot.goalX = x
  bot.goalY = y
  bot.goalName = name
  if bot.isGhost:
    bot.path.setLen(0)
    bot.hasPathStep = false
    bot.astarMicros = 0
    bot.intent = "ghost direct to " & name
    bot.desiredMask = bot.preciseMaskForGoal(x, y)
  else:
    let astarStart = getMonoTime()
    bot.path = bot.findPath(x, y)
    bot.astarMicros = int((getMonoTime() - astarStart).inMicroseconds)
    bot.pathStep = bot.choosePathStep()
    bot.hasPathStep = bot.pathStep.found
    bot.intent = "A* to " & name & " path=" & $bot.path.len
    if heuristic(bot.playerWorldX(), bot.playerWorldY(), x, y) <=
        preciseRadius:
      bot.intent = "precise approach to " & name
      bot.desiredMask = bot.preciseMaskForGoal(x, y)
    else:
      bot.desiredMask = bot.maskForWaypoint(bot.pathStep)
  bot.controllerMask = bot.desiredMask
  let mask = bot.applyJiggle(bot.controllerMask)
  let prefix =
    if bot.role == RoleImposter:
      "imposter "
    elif bot.isGhost:
      "ghost "
    else:
      "map lock "
  bot.thought(
    prefix & cameraLockName(bot.cameraLock) & " at camera (" &
    $bot.cameraX & ", " & $bot.cameraY & "), next " &
    movementName(mask)
  )
  mask

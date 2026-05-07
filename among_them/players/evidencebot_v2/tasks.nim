proc projectedRadarDot(
  bot: Bot,
  task: TaskStation
): tuple[visible: bool, x: int, y: int] =
  ## Projects an offscreen task icon to its expected radar edge pixel.
  if not bot.localized:
    return
  let
    iconSx = task.x + task.w div 2 - SpriteSize div 2 - bot.cameraX
    iconSy = task.y - SpriteSize - 2 - bot.cameraY
    iconX = iconSx + SpriteSize div 2
    iconY = iconSy + SpriteSize div 2
  if iconSx + SpriteSize > 0 and iconSy + SpriteSize > 0 and
      iconSx < ScreenWidth and iconSy < ScreenHeight:
    return (true, iconX, iconY)
  let
    px = float(bot.playerWorldX() + CollisionW div 2 - bot.cameraX)
    py = float(bot.playerWorldY() + CollisionH div 2 - bot.cameraY)
    dx = float(iconX) - px
    dy = float(iconY) - py
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
  ##
  ## v2: tasks marked `taskResolved[i]` are excluded from radar speculation
  ## entirely. Once we've physically verified a task isn't ours (or finished
  ## it), no amount of radar projection ambiguity can lure us back.
  if bot.taskStates.len != bot.sim.tasks.len:
    bot.taskStates = newSeq[TaskState](bot.sim.tasks.len)
  if bot.radarTasks.len != bot.sim.tasks.len:
    bot.radarTasks = newSeq[bool](bot.sim.tasks.len)
  if bot.checkoutTasks.len != bot.sim.tasks.len:
    bot.checkoutTasks = newSeq[bool](bot.sim.tasks.len)
  if bot.taskResolved.len != bot.sim.tasks.len:
    bot.taskResolved = newSeq[bool](bot.sim.tasks.len)
  for i in 0 ..< bot.radarTasks.len:
    bot.radarTasks[i] = false
  if not bot.localized:
    return
  bot.scanRadarDots()
  if bot.radarDots.len == 0:
    return
  for i in 0 ..< bot.sim.tasks.len:
    if bot.taskResolved[i]:
      continue
    let projected = bot.projectedRadarDot(bot.sim.tasks[i])
    if projected.visible:
      continue
    for dot in bot.radarDots:
      if abs(dot.x - projected.x) <= RadarMatchTolerance and
          abs(dot.y - projected.y) <= RadarMatchTolerance:
        bot.radarTasks[i] = true
        bot.checkoutTasks[i] = true
        if bot.taskStates[i] == TaskCompleted:
          bot.taskStates[i] = TaskMaybe

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

proc taskIconInspectRect(
  bot: Bot,
  task: TaskStation
): tuple[x: int, y: int, w: int, h: int] =
  ## Returns the expected screen rectangle for inspecting a task icon.
  (
    task.x + task.w div 2 - TaskIconInspectSize div 2 - bot.cameraX,
    task.y - TaskIconInspectSize - bot.cameraY,
    TaskIconInspectSize,
    TaskIconInspectSize
  )

proc taskIconRenderable(bot: Bot, task: TaskStation): bool =
  ## Returns true when the server could render the task icon.
  let
    center = task.taskCenter()
    sx = center.x - bot.cameraX
    sy = center.y - bot.cameraY
  sx >= 0 and sx < ScreenWidth and sy >= 0 and sy < ScreenHeight

proc taskIconClearAreaVisible(bot: Bot, task: TaskStation): bool =
  ## Returns true when the whole icon inspection area is visible.
  let rect = bot.taskIconInspectRect(task)
  rect.x >= TaskClearScreenMargin and
    rect.y >= TaskClearScreenMargin and
    rect.x + rect.w + TaskClearScreenMargin <= ScreenWidth and
    rect.y + rect.h + TaskClearScreenMargin <= ScreenHeight

proc taskIconMaybeVisibleFor(bot: Bot, task: TaskStation): bool =
  ## Returns true when expected icon pixels look plausibly present.
  let
    baseX = task.x + task.w div 2 - SpriteSize div 2 - bot.cameraX
    baseY = task.y - SpriteSize - 2 - bot.cameraY
  for bobY in -1 .. 1:
    let expectedY = baseY + bobY
    for dy in -TaskIconExpectedSearchRadius .. TaskIconExpectedSearchRadius:
      for dx in -TaskIconExpectedSearchRadius .. TaskIconExpectedSearchRadius:
        if maybeMatchesSprite(
          bot.unpacked,
          bot.taskSprite,
          baseX + dx,
          expectedY + dy
        ):
          return true

proc taskIconVisibleFor(bot: Bot, task: TaskStation): bool =
  ## Returns true if a visible task station has its icon on screen.
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
  ##
  ## v2 changes vs evidencebot:
  ##   1. Eager checkout cleanup. When the inspection area is fully visible
  ##      and no icon (strict or fuzzy) matches, immediately clear
  ##      `checkoutTasks[i]` instead of waiting `TaskIconMissThreshold` frames.
  ##      Checkout flags are pure speculation from radar projection — once
  ##      we've physically verified the icon isn't there, the speculation is
  ##      resolved and there's no value in lingering. This turns "stand for
  ##      24 ticks at a wrong task" into "glance at it and move on".
  ##   2. Decouple miss counting from radar match. The original gate skipped
  ##      counting whenever any radar dot still projected onto this task,
  ##      which meant ambiguous radar geometry could lock the bot at a wrong
  ##      task forever (the dot keeps re-flagging it as we move). The miss
  ##      counter still protects `TaskMandatory` against momentary occlusion
  ##      via the 24-frame threshold; that's enough caution.
  ##   3. Latch `taskResolved[i]` whenever we definitively resolve a task.
  ##      Two trigger paths: (a) the eager checkout cleanup above, which
  ##      means we got a clear look and confirmed the icon isn't ours;
  ##      (b) the slow `TaskMandatory` -> `TaskCompleted` transition, which
  ##      means we either finished the task or the icon was a stale false
  ##      positive that's now definitively gone. Combined with the
  ##      `updateTaskGuesses` skip, the bot will never re-investigate a
  ##      station it's already physically inspected this round.
  if bot.taskStates.len != bot.sim.tasks.len:
    bot.taskStates = newSeq[TaskState](bot.sim.tasks.len)
  if bot.taskIconMisses.len != bot.sim.tasks.len:
    bot.taskIconMisses = newSeq[int](bot.sim.tasks.len)
  if bot.checkoutTasks.len != bot.sim.tasks.len:
    bot.checkoutTasks = newSeq[bool](bot.sim.tasks.len)
  if bot.taskResolved.len != bot.sim.tasks.len:
    bot.taskResolved = newSeq[bool](bot.sim.tasks.len)
  if not bot.localized:
    return
  bot.scanTaskIcons()
  for i in 0 ..< bot.sim.tasks.len:
    let task = bot.sim.tasks[i]
    if bot.taskIconVisibleFor(task):
      bot.taskStates[i] = TaskMandatory
      bot.taskIconMisses[i] = 0
      # If a task icon genuinely renders, it's ours. Clear any stale
      # resolved latch — this can happen if perception had a transient
      # false negative earlier and we've now reconfirmed the icon.
      if bot.taskResolved.len == bot.sim.tasks.len:
        bot.taskResolved[i] = false
    elif bot.taskHoldTicks == 0 and
        bot.taskIconClearAreaVisible(task) and
        not bot.taskIconMaybeVisibleFor(task) and
        bot.taskHoldIndex != i:
      # Clear view + no icon (strict) + no icon (fuzzy) = definitive
      # confirmation this station is not ours (or we already finished it).
      # TaskMandatory still uses the 24-frame counter so a passing crewmate
      # occluding the icon for a few frames doesn't drop the task to
      # Completed prematurely.
      if bot.taskStates[i] == TaskMandatory:
        inc bot.taskIconMisses[i]
        if bot.taskIconMisses[i] >= TaskIconMissThreshold:
          bot.taskStates[i] = TaskCompleted
          bot.checkoutTasks[i] = false
          bot.taskIconMisses[i] = 0
          bot.taskResolved[i] = true
      elif not bot.taskResolved[i]:
        # Aggressive latch: any clear-view confirmation of "no icon"
        # marks the task resolved-not-mine for the rest of the round,
        # whether or not radar ever flagged it. The bot will never
        # detour to investigate this station again.
        bot.taskResolved[i] = true
        bot.checkoutTasks[i] = false
        bot.taskIconMisses[i] = 0
    else:
      bot.taskIconMisses[i] = 0


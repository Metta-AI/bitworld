proc thought(bot: var Bot, text: string) =
  ## Stores changed bot thoughts for the GUI.
  if text != bot.lastThought:
    bot.lastThought = text

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

proc checkoutTaskCount(bot: Bot): int =
  ## Returns the number of persistent checkout task candidates.
  for checkoutTask in bot.checkoutTasks:
    if checkoutTask:
      inc result

proc buttonFallbackReady(bot: Bot): bool =
  ## Returns true when home is the only useful remaining goal.
  bot.radarDots.len == 0 and
    bot.radarTaskCount() == 0 and
    bot.checkoutTaskCount() == 0 and
    bot.taskStateCount(TaskMandatory) == 0

proc rememberHome(bot: var Bot) =
  ## Records the first reliable round position as this bot's home.
  if not bot.localized or bot.interstitial:
    return
  bot.gameStarted = true
  if bot.homeSet:
    return
  bot.homeX = bot.playerWorldX()
  bot.homeY = bot.playerWorldY()
  bot.homeSet = true

proc roleName(role: BotRole): string =
  ## Returns a human-readable role name.
  case role
  of RoleUnknown: "unknown"
  of RoleCrewmate: "crewmate"
  of RoleImposter: "imposter"

proc knownImposterColor(bot: Bot, colorIndex: int): bool =
  ## Returns true if the color was shown as an imposter teammate.
  colorIndex >= 0 and
    colorIndex < bot.knownImposters.len and
    bot.knownImposters[colorIndex]

proc playerColorName(colorIndex: int): string =
  ## Returns the visible player color name.
  if colorIndex >= 0 and colorIndex < PlayerColorNames.len:
    PlayerColorNames[colorIndex]
  else:
    "unknown"

proc knownImposterSummary(bot: Bot): string =
  ## Returns a compact debug string for known imposter colors.
  for i, known in bot.knownImposters:
    if not known:
      continue
    if result.len > 0:
      result.add(", ")
    result.add(playerColorName(i))
  if result.len == 0:
    result = "none"

proc cameraLockName(lock: CameraLock): string =
  ## Returns a human-readable camera lock name.
  case lock
  of NoLock: "none"
  of LocalFrameMapLock: "local frame"
  of FrameMapLock: "frame map"


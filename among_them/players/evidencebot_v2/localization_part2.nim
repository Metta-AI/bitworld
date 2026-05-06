proc reseedLocalizationAtHome(bot: var Bot) =
  ## Re-seeds localization around the remembered home point.
  if bot.homeSet:
    bot.cameraX = cameraXForWorld(bot.homeX)
    bot.cameraY = cameraYForWorld(bot.homeY)
  else:
    bot.cameraX = bot.sim.buttonCameraX()
    bot.cameraY = bot.sim.buttonCameraY()
  bot.lastCameraX = bot.cameraX
  bot.lastCameraY = bot.cameraY
  bot.cameraLock = NoLock
  bot.cameraScore = 0
  bot.localized = false
  bot.haveMotionSample = false
  bot.velocityX = 0
  bot.velocityY = 0
  bot.stuckFrames = 0
  bot.jiggleTicks = 0
  bot.jiggleSide = 0
  bot.desiredMask = 0
  bot.controllerMask = 0
  bot.taskHoldTicks = 0
  bot.taskHoldIndex = -1
  bot.goalIndex = -1
  bot.goalName = ""
  bot.hasGoal = false
  bot.hasPathStep = false
  bot.path.setLen(0)

proc isInterstitialScreen(bot: Bot): bool =
  ## Returns true when a black modal screen hides the map.
  var black = 0
  for color in bot.unpacked:
    if color == SpaceColor:
      inc black
  black * 100 >= bot.unpacked.len * InterstitialBlackPercent

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
  ## Locates the camera by spiraling out from the best prior.
  let patchStart = getMonoTime()
  if bot.locateByPatches():
    bot.localizePatchMicros = int((getMonoTime() - patchStart).inMicroseconds)
    bot.localizeSpiralMicros = 0
    return true
  bot.localizePatchMicros = int((getMonoTime() - patchStart).inMicroseconds)
  let spiralStart = getMonoTime()
  var
    bestScore = CameraScore(
      score: low(int),
      errors: high(int),
      compared: 0
    )
    bestX =
      if bot.gameStarted:
        bot.cameraX
      else:
        bot.sim.buttonCameraX()
    bestY =
      if bot.gameStarted:
        bot.cameraY
      else:
        bot.sim.buttonCameraY()
  let
    minX = minCameraX()
    maxX = maxCameraX()
    minY = minCameraY()
    maxY = maxCameraY()
    seedX = clamp(bestX, minX, maxX)
    seedY = clamp(bestY, minY, maxY)
    maxRadius = max(
      max(abs(seedX - minX), abs(seedX - maxX)),
      max(abs(seedY - minY), abs(seedY - maxY))
    )
  bestX = seedX
  bestY = seedY

  template tryCamera(x, y: int): bool =
    ## Scores one camera candidate if the player could be there.
    if x < minX or x > maxX or y < minY or y > maxY:
      false
    elif not cameraCanHoldPlayer(x, y):
      false
    else:
      let score = bot.scoreCamera(x, y, FullFrameFitMaxErrors)
      if score.errors < bestScore.errors or
          (score.errors == bestScore.errors and
          score.compared > bestScore.compared):
        bestScore = score
        bestX = x
        bestY = y
        bestScore.errors == 0 and
          bestScore.compared >= FrameFitMinCompared
      else:
        false

  var done = tryCamera(seedX, seedY)
  for radius in 1 .. maxRadius:
    if done:
      break
    for dx in -radius .. radius:
      if tryCamera(seedX + dx, seedY - radius):
        done = true
        break
      if tryCamera(seedX + dx, seedY + radius):
        done = true
        break
    if done:
      break
    for dy in -radius + 1 .. radius - 1:
      if tryCamera(seedX - radius, seedY + dy):
        done = true
        break
      if tryCamera(seedX + radius, seedY + dy):
        done = true
        break
  if not acceptCameraScore(bestScore, FullFrameFitMaxErrors):
    bot.cameraLock = NoLock
    bot.cameraScore = bestScore.score
    bot.localized = false
    bot.localizeSpiralMicros =
      int((getMonoTime() - spiralStart).inMicroseconds)
    return false
  bot.setCameraLock(bestX, bestY, bestScore, FrameMapLock)
  bot.localizeSpiralMicros =
    int((getMonoTime() - spiralStart).inMicroseconds)
  true

proc updateLocation(bot: var Bot) =
  ## Updates the camera and player world estimate from the frame.
  let wasInterstitial = bot.interstitial
  bot.spriteScanMicros = 0
  bot.localizeLocalMicros = 0
  bot.localizePatchMicros = 0
  bot.localizeSpiralMicros = 0
  bot.lastCameraX = bot.cameraX
  bot.lastCameraY = bot.cameraY
  bot.interstitial = bot.isInterstitialScreen()
  if bot.interstitial:
    bot.interstitialText = bot.detectInterstitialText()
    bot.visibleTaskIcons.setLen(0)
    bot.visibleCrewmates.setLen(0)
    bot.visibleBodies.setLen(0)
    bot.visibleGhosts.setLen(0)
    if bot.interstitialText.isGameOverText() and
        bot.lastGameOverText != bot.interstitialText:
      bot.resetRoundState()
      bot.lastGameOverText = bot.interstitialText
    elif not bot.parseVotingScreen():
      bot.rememberRoleReveal()
    return
  bot.interstitialText = ""
  bot.lastGameOverText = ""
  if bot.voting:
    bot.clearVotingState()
  if wasInterstitial:
    bot.reseedLocalizationAtHome()
  let spriteStart = getMonoTime()
  bot.updateRole()
  bot.updateSelfColor()
  bot.scanBodies()
  bot.scanGhosts()
  bot.scanCrewmates()
  if bot.role == RoleImposter and not bot.isGhost:
    bot.visibleTaskIcons.setLen(0)
  else:
    bot.scanTaskIcons()
  bot.spriteScanMicros = int((getMonoTime() - spriteStart).inMicroseconds)
  let localStart = getMonoTime()
  if bot.locateNearFrame():
    bot.localizeLocalMicros =
      int((getMonoTime() - localStart).inMicroseconds)
    return
  bot.localizeLocalMicros =
    int((getMonoTime() - localStart).inMicroseconds)
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


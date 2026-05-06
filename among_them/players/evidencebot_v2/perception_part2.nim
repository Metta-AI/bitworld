proc addBodyMatch(matches: var seq[BodyMatch], x, y: int) =
  ## Adds one body match unless a nearby match already exists.
  for match in matches:
    if abs(match.x - x) <= BodySearchRadius and
        abs(match.y - y) <= BodySearchRadius:
      return
  matches.add(BodyMatch(x: x, y: y))

proc scanBodies(bot: var Bot) =
  ## Scans the current frame for visible dead bodies.
  bot.visibleBodies.setLen(0)
  for y in 0 .. ScreenHeight - bot.bodySprite.height:
    for x in 0 .. ScreenWidth - bot.bodySprite.width:
      if bot.matchesActorSprite(
        bot.bodySprite,
        x,
        y,
        false,
        BodyMaxMisses,
        BodyMinStablePixels,
        BodyMinTintPixels
      ):
        bot.visibleBodies.addBodyMatch(x, y)

proc addGhostMatch(matches: var seq[GhostMatch], x, y: int, flipH: bool) =
  ## Adds one ghost match unless a nearby match already exists.
  for match in matches:
    if abs(match.x - x) <= GhostSearchRadius and
        abs(match.y - y) <= GhostSearchRadius:
      return
  matches.add(GhostMatch(x: x, y: y, flipH: flipH))

proc scanGhosts(bot: var Bot) =
  ## Scans the current frame for visible ghosts.
  bot.visibleGhosts.setLen(0)
  for y in 0 .. ScreenHeight - bot.ghostSprite.height:
    for x in 0 .. ScreenWidth - bot.ghostSprite.width:
      if bot.matchesActorSprite(
        bot.ghostSprite,
        x,
        y,
        false,
        GhostMaxMisses,
        GhostMinStablePixels,
        GhostMinTintPixels
      ):
        bot.visibleGhosts.addGhostMatch(x, y, false)
      elif bot.matchesActorSprite(
        bot.ghostSprite,
        x,
        y,
        true,
        GhostMaxMisses,
        GhostMinStablePixels,
        GhostMinTintPixels
      ):
        bot.visibleGhosts.addGhostMatch(x, y, true)

proc scanTaskIcons(bot: var Bot) =
  ## Scans expected task icon positions for visible task icons.
  bot.visibleTaskIcons.setLen(0)
  if not bot.localized:
    return
  for task in bot.sim.tasks:
    let
      baseX = task.x + task.w div 2 - SpriteSize div 2 - bot.cameraX
      baseY = task.y - SpriteSize - 2 - bot.cameraY
    for bobY in -1 .. 1:
      let expectedY = baseY + bobY
      for dy in -TaskIconExpectedSearchRadius .. TaskIconExpectedSearchRadius:
        for dx in -TaskIconExpectedSearchRadius .. TaskIconExpectedSearchRadius:
          let
            x = baseX + dx
            y = expectedY + dy
          if matchesSprite(bot.unpacked, bot.taskSprite, x, y):
            bot.visibleTaskIcons.addIconMatch(x, y)

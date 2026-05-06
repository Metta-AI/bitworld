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

proc ignoreCrewmatePixel(bot: Bot, sx, sy: int): bool =
  ## Returns true when a frame pixel belongs to a matched crewmate.
  for crewmate in bot.visibleCrewmates:
    let
      ix = sx - crewmate.x
      iy = sy - crewmate.y
    if ix < 0 or iy < 0 or
        ix >= bot.playerSprite.width or
        iy >= bot.playerSprite.height:
      continue
    let srcX =
      if crewmate.flipH:
        bot.playerSprite.width - 1 - ix
      else:
        ix
    if bot.playerSprite.pixels[bot.playerSprite.spriteIndex(srcX, iy)] !=
        TransparentColorIndex:
      return true

proc ignoreBodyPixel(bot: Bot, sx, sy: int): bool =
  ## Returns true when a frame pixel belongs to a matched dead body.
  for body in bot.visibleBodies:
    let
      ix = sx - body.x
      iy = sy - body.y
    if ix < 0 or iy < 0 or
        ix >= bot.bodySprite.width or
        iy >= bot.bodySprite.height:
      continue
    if bot.bodySprite.pixels[bot.bodySprite.spriteIndex(ix, iy)] !=
        TransparentColorIndex:
      return true

proc ignoreGhostPixel(bot: Bot, sx, sy: int): bool =
  ## Returns true when a frame pixel belongs to a matched ghost.
  for ghost in bot.visibleGhosts:
    let
      ix = sx - ghost.x
      iy = sy - ghost.y
    if ix < 0 or iy < 0 or
        ix >= bot.ghostSprite.width or
        iy >= bot.ghostSprite.height:
      continue
    let srcX =
      if ghost.flipH:
        bot.ghostSprite.width - 1 - ix
      else:
        ix
    if bot.ghostSprite.pixels[bot.ghostSprite.spriteIndex(srcX, iy)] !=
        TransparentColorIndex:
      return true

proc ignoreKillIconPixel(bot: Bot, sx, sy: int): bool =
  ## Returns true when a frame pixel belongs to the imposter kill icon.
  if bot.role != RoleImposter:
    return false
  let
    ix = sx - KillIconX
    iy = sy - KillIconY
  if ix < 0 or iy < 0 or
      ix >= bot.killButtonSprite.width or
      iy >= bot.killButtonSprite.height:
    return false
  bot.killButtonSprite.pixels[
    bot.killButtonSprite.spriteIndex(ix, iy)
  ] != TransparentColorIndex

proc ignoreGhostIconPixel(bot: Bot, sx, sy: int): bool =
  ## Returns true when a frame pixel belongs to the fixed ghost icon.
  if not bot.isGhost and bot.ghostIconFrames == 0:
    return false
  let
    ix = sx - KillIconX
    iy = sy - KillIconY
  if ix < 0 or iy < 0 or
      ix >= bot.ghostIconSprite.width or
      iy >= bot.ghostIconSprite.height:
    return false
  bot.ghostIconSprite.pixels[
    bot.ghostIconSprite.spriteIndex(ix, iy)
  ] != TransparentColorIndex

proc ignoreFramePixel(bot: Bot, frameColor: uint8, sx, sy: int): bool =
  ## Returns true for dynamic screen pixels that are not map evidence.
  if frameColor == RadarTaskColor:
    return true
  if bot.ignoreKillIconPixel(sx, sy):
    return true
  if bot.ignoreGhostIconPixel(sx, sy):
    return true
  if bot.ignoreBodyPixel(sx, sy):
    return true
  if bot.ignoreGhostPixel(sx, sy):
    return true
  if bot.ignoreTaskIconPixel(sx, sy):
    return true
  if bot.ignoreCrewmatePixel(sx, sy):
    return true
  abs(sx - PlayerScreenX) <= PlayerIgnoreRadius and
    abs(sy - PlayerScreenY) <= PlayerIgnoreRadius

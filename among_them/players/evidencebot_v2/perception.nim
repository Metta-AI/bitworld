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

proc spriteMisses(
  frame: openArray[uint8],
  sprite: Sprite,
  x,
  y: int
): tuple[misses: int, opaque: int] =
  ## Counts opaque sprite pixels that do not match the frame.
  var
    misses = 0
    opaque = 0
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let color = sprite.pixels[sprite.spriteIndex(sx, sy)]
      if color == TransparentColorIndex:
        continue
      inc opaque
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        inc misses
      elif frame[fy * ScreenWidth + fx] == color:
        discard
      else:
        inc misses
  (misses, opaque)

proc matchesSprite(
  frame: openArray[uint8],
  sprite: Sprite,
  x,
  y: int
): bool =
  ## Returns true if a sprite stringently matches the frame.
  let score = spriteMisses(frame, sprite, x, y)
  score.opaque > 0 and score.misses <= TaskIconMaxMisses

proc maybeMatchesSprite(
  frame: openArray[uint8],
  sprite: Sprite,
  x,
  y: int
): bool =
  ## Returns true when a sprite may be present but imperfect.
  let score = spriteMisses(frame, sprite, x, y)
  score.opaque > 0 and score.misses <= TaskIconMaybeMisses

proc matchesSpriteShadowed(
  frame: openArray[uint8],
  sprite: Sprite,
  x,
  y: int
): bool =
  ## Returns true if a shadowed sprite matches the frame.
  var
    misses = 0
    opaque = 0
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let color = sprite.pixels[sprite.spriteIndex(sx, sy)]
      if color == TransparentColorIndex:
        continue
      inc opaque
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        inc misses
      elif frame[fy * ScreenWidth + fx] == ShadowMap[color and 0x0f]:
        discard
      else:
        inc misses
      if misses > KillIconMaxMisses:
        return false
  opaque > 0 and misses <= KillIconMaxMisses

proc updateRole(bot: var Bot) =
  ## Updates the known role from fixed status icons.
  let ghostScore = spriteMisses(
    bot.unpacked,
    bot.ghostIconSprite,
    KillIconX,
    KillIconY
  )
  if ghostScore.opaque > 0 and ghostScore.misses <= GhostIconMaxMisses:
    inc bot.ghostIconFrames
    bot.imposterKillReady = false
    if bot.ghostIconFrames >= GhostIconFrameThreshold:
      bot.isGhost = true
      if bot.role == RoleUnknown:
        bot.role = RoleCrewmate
    return
  elif not bot.isGhost:
    bot.ghostIconFrames = 0

  let lit = matchesSprite(
    bot.unpacked,
    bot.killButtonSprite,
    KillIconX,
    KillIconY
  )
  let shaded = matchesSpriteShadowed(
    bot.unpacked,
    bot.killButtonSprite,
    KillIconX,
    KillIconY
  )
  bot.imposterKillReady = lit
  if lit or shaded:
    bot.role = RoleImposter
  elif bot.role == RoleUnknown:
    bot.role = RoleCrewmate

proc addIconMatch(matches: var seq[IconMatch], x, y: int) =
  ## Adds one icon match unless a nearby icon already exists.
  for match in matches:
    if abs(match.x - x) <= 1 and abs(match.y - y) <= 1:
      return
  matches.add(IconMatch(x: x, y: y))

proc stableCrewmateColor(color: uint8): bool =
  ## Returns true for non-body crewmate sprite pixels.
  color != TransparentColorIndex and
    color != TintColor and
    color != ShadeTintColor

proc playerBodyColor(color: uint8): bool =
  ## Returns true when a frame color can be a crewmate body.
  for playerColor in PlayerColors:
    if color == playerColor:
      return true
    if color == ShadowMap[playerColor and 0x0f]:
      return true

proc playerColorIndex(color: uint8): int =
  ## Returns the tracked player color index for a palette color.
  for i, playerColor in PlayerColors:
    if color == playerColor:
      return i
  -1

proc crewmatePixelMatches(spriteColor, frameColor: uint8): bool =
  ## Returns true when one crewmate sprite pixel matches the frame.
  if spriteColor == TintColor or spriteColor == ShadeTintColor:
    return playerBodyColor(frameColor)
  frameColor == spriteColor

proc crewmateColorIndex(bot: Bot, x, y: int, flipH: bool): int =
  ## Returns the most likely visible color for a crewmate match.
  var counts: array[PlayerColorCount, int]
  for sy in 0 ..< bot.playerSprite.height:
    for sx in 0 ..< bot.playerSprite.width:
      let srcX =
        if flipH:
          bot.playerSprite.width - 1 - sx
        else:
          sx
      let color = bot.playerSprite.pixels[
        bot.playerSprite.spriteIndex(srcX, sy)
      ]
      if color != TintColor:
        continue
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        continue
      let index = playerColorIndex(bot.unpacked[fy * ScreenWidth + fx])
      if index >= 0:
        inc counts[index]
  var bestCount = 0
  result = -1
  for i, count in counts:
    if count > bestCount:
      bestCount = count
      result = i

proc matchesCrewmate(
  bot: Bot,
  x,
  y: int,
  flipH: bool
): bool =
  ## Returns true when stable crewmate pixels match the frame.
  var
    bodyMatched = 0
    bodyPixels = 0
    matchedStable = 0
    misses = 0
    stablePixels = 0
  for sy in 0 ..< bot.playerSprite.height:
    for sx in 0 ..< bot.playerSprite.width:
      let srcX =
        if flipH:
          bot.playerSprite.width - 1 - sx
        else:
          sx
      let color = bot.playerSprite.pixels[
        bot.playerSprite.spriteIndex(srcX, sy)
      ]
      if color == TransparentColorIndex:
        continue
      if stableCrewmateColor(color):
        inc stablePixels
      else:
        inc bodyPixels
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        inc misses
      elif crewmatePixelMatches(color, bot.unpacked[fy * ScreenWidth + fx]):
        if stableCrewmateColor(color):
          inc matchedStable
        else:
          inc bodyMatched
      else:
        inc misses
      if misses > CrewmateMaxMisses:
        return false
  stablePixels >= CrewmateMinStablePixels and
    matchedStable >= CrewmateMinStablePixels and
    bodyPixels >= CrewmateMinBodyPixels and
    bodyMatched >= CrewmateMinBodyPixels

proc addCrewmateMatch(
  matches: var seq[CrewmateMatch],
  x,
  y: int,
  colorIndex: int,
  flipH: bool
) =
  ## Adds one crewmate match unless a nearby match already exists.
  for i in 0 ..< matches.len:
    if abs(matches[i].x - x) <= CrewmateSearchRadius and
        abs(matches[i].y - y) <= CrewmateSearchRadius:
      if matches[i].colorIndex < 0 and colorIndex >= 0:
        matches[i].colorIndex = colorIndex
      return
  matches.add(CrewmateMatch(
    x: x,
    y: y,
    colorIndex: colorIndex,
    flipH: flipH
  ))

proc scanCrewmates(bot: var Bot) =
  ## Scans the current frame for crewmates by stable sprite pixels.
  bot.visibleCrewmates.setLen(0)
  for y in 0 .. ScreenHeight - bot.playerSprite.height:
    for x in 0 .. ScreenWidth - bot.playerSprite.width:
      if abs(x + SpriteSize div 2 - PlayerScreenX) <= PlayerIgnoreRadius and
          abs(y + SpriteSize div 2 - PlayerScreenY) <= PlayerIgnoreRadius:
        continue
      if bot.matchesCrewmate(x, y, false):
        let colorIndex = bot.crewmateColorIndex(x, y, false)
        bot.visibleCrewmates.addCrewmateMatch(x, y, colorIndex, false)
      elif bot.matchesCrewmate(x, y, true):
        let colorIndex = bot.crewmateColorIndex(x, y, true)
        bot.visibleCrewmates.addCrewmateMatch(x, y, colorIndex, true)
  for crewmate in bot.visibleCrewmates:
    if crewmate.colorIndex >= 0 and
        crewmate.colorIndex < bot.lastSeenTicks.len:
      bot.lastSeenTicks[crewmate.colorIndex] = bot.frameTick

proc updateSelfColor(bot: var Bot) =
  ## Learns the local player's color from the centered player sprite.
  let
    x = PlayerScreenX - bot.playerSprite.width div 2
    y = PlayerScreenY - bot.playerSprite.height div 2
  var colorIndex = -1
  if bot.matchesCrewmate(x, y, false):
    colorIndex = bot.crewmateColorIndex(x, y, false)
  elif bot.matchesCrewmate(x, y, true):
    colorIndex = bot.crewmateColorIndex(x, y, true)
  if colorIndex >= 0 and colorIndex < PlayerColorCount:
    bot.selfColorIndex = colorIndex

proc rememberRoleReveal(bot: var Bot) =
  ## Learns team colors from the role reveal interstitial screen.
  if bot.interstitialText == "CREWMATE":
    if bot.role == RoleUnknown:
      bot.role = RoleCrewmate
    return
  if bot.interstitialText != "IMPS":
    return
  bot.role = RoleImposter
  for y in 0 .. ScreenHeight - bot.playerSprite.height:
    for x in 0 .. ScreenWidth - bot.playerSprite.width:
      if bot.matchesCrewmate(x, y, false):
        let colorIndex = bot.crewmateColorIndex(x, y, false)
        bot.visibleCrewmates.addCrewmateMatch(x, y, colorIndex, false)
      elif bot.matchesCrewmate(x, y, true):
        let colorIndex = bot.crewmateColorIndex(x, y, true)
        bot.visibleCrewmates.addCrewmateMatch(x, y, colorIndex, true)
  for crewmate in bot.visibleCrewmates:
    if crewmate.colorIndex >= 0 and
        crewmate.colorIndex < bot.knownImposters.len:
      bot.knownImposters[crewmate.colorIndex] = true


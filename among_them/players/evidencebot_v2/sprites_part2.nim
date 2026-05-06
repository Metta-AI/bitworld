proc matchesActorSprite(
  bot: Bot,
  sprite: Sprite,
  x,
  y: int,
  flipH: bool,
  maxMisses,
  minStablePixels,
  minTintPixels: int
): bool =
  ## Returns true when a tinted actor sprite matches the frame.
  var
    tintMatched = 0
    tintPixels = 0
    stableMatched = 0
    misses = 0
    stablePixels = 0
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let srcX =
        if flipH:
          sprite.width - 1 - sx
        else:
          sx
      let color = sprite.pixels[sprite.spriteIndex(srcX, sy)]
      if color == TransparentColorIndex:
        continue
      if stableCrewmateColor(color):
        inc stablePixels
      else:
        inc tintPixels
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        inc misses
      elif crewmatePixelMatches(color, bot.unpacked[fy * ScreenWidth + fx]):
        if stableCrewmateColor(color):
          inc stableMatched
        else:
          inc tintMatched
      else:
        inc misses
      if misses > maxMisses:
        return false
  stablePixels >= minStablePixels and
    stableMatched >= minStablePixels and
    tintPixels >= minTintPixels and
    tintMatched >= minTintPixels

proc actorColorIndex(
  bot: Bot,
  sprite: Sprite,
  x,
  y: int,
  flipH: bool
): int =
  ## Returns the most likely tint color for an actor sprite.
  var counts: array[PlayerColorCount, int]
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let srcX =
        if flipH:
          sprite.width - 1 - sx
        else:
          sx
      let color = sprite.pixels[sprite.spriteIndex(srcX, sy)]
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
  result = VoteUnknown
  for i, count in counts:
    if count > bestCount:
      bestCount = count
      result = i

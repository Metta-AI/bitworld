proc scoreCamera(bot: Bot, cameraX, cameraY, maxErrors: int): CameraScore =
  ## Counts map-fit errors for a full 128x128 frame rectangle.
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let frameColor = bot.unpacked[sy * ScreenWidth + sx]
      if bot.ignoreFramePixel(frameColor, sx, sy):
        continue
      let
        mx = cameraX + sx
        my = cameraY + sy
        mapColor =
          if inMap(mx, my):
            bot.sim.mapPixels[mapIndexSafe(mx, my)]
          else:
            MapVoidColor
      if frameColor == mapColor:
        inc result.compared
      elif ShadowMap[mapColor and 0x0f] == frameColor:
        inc result.compared
      else:
        inc result.compared
        inc result.errors
        if result.errors > maxErrors:
          result.score = -result.errors
          return
  result.score = result.compared - result.errors * ScreenWidth

proc patchHashAdd(hash: uint64, color: uint8): uint64 =
  ## Adds one color to an 8 by 8 patch hash.
  hash * PatchHashBase + uint64(color and 0x0f) + 1'u64

proc patchMapColor(bot: Bot, x, y: int): uint8 =
  ## Returns the map color used by patch localization.
  if inMap(x, y):
    bot.sim.mapPixels[mapIndexSafe(x, y)]
  else:
    MapVoidColor

proc mapPatchHash(bot: Bot, x, y: int): uint64 =
  ## Hashes one 8 by 8 map patch.
  result = PatchHashSeed
  for py in 0 ..< PatchSize:
    for px in 0 ..< PatchSize:
      result = patchHashAdd(result, bot.patchMapColor(x + px, y + py))

proc framePatchHash(
  bot: Bot,
  sx,
  sy: int,
  hash: var uint64
): bool =
  ## Hashes one clean 8 by 8 frame patch.
  hash = PatchHashSeed
  for py in 0 ..< PatchSize:
    for px in 0 ..< PatchSize:
      let
        x = sx + px
        y = sy + py
        color = bot.unpacked[y * ScreenWidth + x]
      if bot.ignoreFramePixel(color, x, y):
        return false
      hash = patchHashAdd(hash, color)
  true

proc buildPatchEntries(bot: var Bot) =
  ## Builds a map patch hash index for fast localization.
  let
    minX = minCameraX()
    maxX = maxCameraX() + ScreenWidth - PatchSize
    minY = minCameraY()
    maxY = maxCameraY() + ScreenHeight - PatchSize
    width = maxCameraX() - minCameraX() + 1
    height = maxCameraY() - minCameraY() + 1
  bot.patchEntries = @[]
  bot.patchEntries.setLen((maxX - minX + 1) * (maxY - minY + 1))
  var i = 0
  for y in minY .. maxY:
    for x in minX .. maxX:
      bot.patchEntries[i] = PatchEntry(
        hash: bot.mapPatchHash(x, y),
        cameraX: x,
        cameraY: y
      )
      inc i
  bot.patchEntries.sort()
  bot.patchVotes = newSeq[uint16](width * height)
  bot.patchTouched = @[]
  bot.patchCandidates = @[]

proc patchHashRange(
  entries: openArray[PatchEntry],
  hash: uint64
): tuple[first, last: int] =
  ## Returns the sorted range with a matching patch hash.
  var
    lo = 0
    hi = entries.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if entries[mid].hash < hash:
      lo = mid + 1
    else:
      hi = mid
  result.first = lo
  hi = entries.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if entries[mid].hash > hash:
      hi = mid
    else:
      lo = mid + 1
  result.last = lo

proc addPatchVote(bot: var Bot, x, y: int) =
  ## Adds one patch vote for a camera candidate.
  if x < minCameraX() or x > maxCameraX() or
      y < minCameraY() or y > maxCameraY():
    return
  if not cameraCanHoldPlayer(x, y):
    return
  let index = cameraIndex(x, y)
  if bot.patchVotes[index] == 0:
    bot.patchTouched.add(index)
  bot.patchVotes[index] = bot.patchVotes[index] + 1

proc collectPatchCandidates(bot: var Bot) =
  ## Collects the best voted camera candidates.
  bot.patchCandidates.setLen(0)
  for index in bot.patchTouched:
    let votes = bot.patchVotes[index].int
    if votes < PatchMinVotes:
      continue
    bot.patchCandidates.add(PatchCandidate(
      votes: votes,
      cameraX: cameraIndexX(index),
      cameraY: cameraIndexY(index)
    ))
  bot.patchCandidates.sort(cmpPatchCandidate)
  if bot.patchCandidates.len > PatchTopCandidates:
    bot.patchCandidates.setLen(PatchTopCandidates)

proc clearPatchVotes(bot: var Bot) =
  ## Clears patch vote counters touched by the last localization pass.
  for index in bot.patchTouched:
    bot.patchVotes[index] = 0
  bot.patchTouched.setLen(0)

proc acceptCameraScore(score: CameraScore, maxErrors: int): bool

proc setCameraLock(
  bot: var Bot,
  x,
  y: int,
  score: CameraScore,
  lock: CameraLock
)

proc locateByPatches(bot: var Bot): bool =
  ## Locates the camera using 8 by 8 map patch votes.
  if bot.patchEntries.len == 0:
    return false
  bot.clearPatchVotes()
  for py in 0 ..< PatchGridH:
    for px in 0 ..< PatchGridW:
      let
        sx = px * PatchSize
        sy = py * PatchSize
      var hash = 0'u64
      if not bot.framePatchHash(sx, sy, hash):
        continue
      let range = patchHashRange(bot.patchEntries, hash)
      if range.last - range.first > PatchMaxMatches:
        continue
      for i in range.first ..< range.last:
        let
          entry = bot.patchEntries[i]
          x = entry.cameraX - sx
          y = entry.cameraY - sy
        bot.addPatchVote(x, y)
  bot.collectPatchCandidates()
  var
    bestScore = CameraScore(score: low(int), errors: high(int), compared: 0)
    bestX = 0
    bestY = 0
  for candidate in bot.patchCandidates:
    let score = bot.scoreCamera(
      candidate.cameraX,
      candidate.cameraY,
      FullFrameFitMaxErrors
    )
    if score.errors < bestScore.errors or
        (score.errors == bestScore.errors and
        score.compared > bestScore.compared):
      bestScore = score
      bestX = candidate.cameraX
      bestY = candidate.cameraY
  bot.clearPatchVotes()
  if not acceptCameraScore(bestScore, FullFrameFitMaxErrors):
    return false
  bot.setCameraLock(bestX, bestY, bestScore, FrameMapLock)
  true

proc acceptCameraScore(score: CameraScore, maxErrors: int): bool =
  ## Returns true when a camera score is good enough to trust.
  score.errors <= maxErrors and score.compared >= FrameFitMinCompared

proc setCameraLock(
  bot: var Bot,
  x,
  y: int,
  score: CameraScore,
  lock: CameraLock
) =
  ## Stores one accepted camera lock.
  bot.cameraX = x
  bot.cameraY = y
  bot.cameraScore = score.score
  bot.cameraLock = lock
  bot.localized = true

proc scanTaskIcons(bot: var Bot)

proc scanCrewmates(bot: var Bot)

proc rememberRoleReveal(bot: var Bot)

proc scanBodies(bot: var Bot)

proc scanGhosts(bot: var Bot)

proc updateRole(bot: var Bot)

proc updateSelfColor(bot: var Bot)

proc parseVotingScreen(bot: var Bot): bool

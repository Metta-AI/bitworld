proc suspectedColor(
  bot: Bot
): tuple[found: bool, name: string, tick: int, colorIndex: int] =
  ## Returns the most recently seen crewmate color.
  var bestTick = 0
  for i, tick in bot.lastSeenTicks:
    if i == bot.selfColorIndex:
      continue
    if bot.knownImposterColor(i):
      continue
    if tick > bestTick and i < PlayerColorNames.len:
      bestTick = tick
      result = (true, playerColorName(i), tick, i)

proc updateEvidence(bot: var Bot) =
  ## Stamps colors that were seen near visible bodies this frame.
  ##
  ## Two tiers of evidence:
  ##   nearBodyTicks[ci]      — visible non-self, non-teammate color is within
  ##                            WitnessNearBodyRadius of any visible body
  ##   witnessedKillTicks[ci] — same, but only at the frame a body newly
  ##                            appears. A body that was already visible last
  ##                            frame doesn't generate fresh kill-witness
  ##                            evidence; a body that wasn't there last frame
  ##                            does, and any non-self crewmate next to it is
  ##                            the most likely killer.
  ##
  ## Bodies don't move, so a "new body" is one that has no previous-frame body
  ## within ~SpriteSize pixels.
  var bodyWorlds: seq[tuple[x: int, y: int]] = @[]
  for body in bot.visibleBodies:
    bodyWorlds.add(bot.visibleBodyWorld(body))

  # Resolve visible crewmate world positions, skipping self/teammates.
  var
    cmCount = 0
    cmColors: array[PlayerColorCount, int]
    cmX: array[PlayerColorCount, int]
    cmY: array[PlayerColorCount, int]
  for crewmate in bot.visibleCrewmates:
    let ci = crewmate.colorIndex
    if ci < 0 or ci >= PlayerColorCount:
      continue
    if ci == bot.selfColorIndex:
      continue
    if bot.knownImposterColor(ci):
      continue
    let world = bot.visibleCrewmateWorld(crewmate)
    cmColors[cmCount] = ci
    cmX[cmCount] = world.x
    cmY[cmCount] = world.y
    inc cmCount

  let nearR2 = WitnessNearBodyRadius * WitnessNearBodyRadius

  # Tier 1: crewmate currently visible within radius of any visible body.
  for k in 0 ..< cmCount:
    for body in bodyWorlds:
      let
        dx = cmX[k] - body.x
        dy = cmY[k] - body.y
      if dx * dx + dy * dy <= nearR2:
        bot.nearBodyTicks[cmColors[k]] = bot.frameTick
        break

  # Tier 2: any *new* body (no body within ~SpriteSize last frame) gives the
  # near crewmate(s) the stronger witnessedKill stamp.
  let kill2 = SpriteSize * SpriteSize
  for body in bodyWorlds:
    var isNew = true
    for prev in bot.prevVisibleBodies:
      let
        dx = body.x - prev.x
        dy = body.y - prev.y
      if dx * dx + dy * dy <= kill2:
        isNew = false
        break
    if not isNew:
      continue
    for k in 0 ..< cmCount:
      let
        dx = cmX[k] - body.x
        dy = cmY[k] - body.y
      if dx * dx + dy * dy <= nearR2:
        bot.witnessedKillTicks[cmColors[k]] = bot.frameTick

  # Persist this frame's positions for next frame's diff.
  for i in 0 ..< PlayerColorCount:
    bot.prevVisibleCrewmateX[i] = -1
    bot.prevVisibleCrewmateY[i] = -1
  for k in 0 ..< cmCount:
    bot.prevVisibleCrewmateX[cmColors[k]] = cmX[k]
    bot.prevVisibleCrewmateY[cmColors[k]] = cmY[k]
  bot.prevVisibleBodies = bodyWorlds

proc evidenceBasedSuspect(
  bot: Bot
): tuple[found: bool, name: string, colorIndex: int] =
  ## Returns the strongest evidence-backed suspect, or found=false if none.
  ##
  ## Strict: only returns a suspect if we have firsthand evidence (witnessed
  ## a kill or saw the player next to a body). Returns found=false otherwise
  ## so the crewmate stays neutral instead of accusing on vibes.
  var
    bestTick = 0
    suspect = -1

  # Tier 1: most recent witnessed kill wins.
  for i, t in bot.witnessedKillTicks:
    if i == bot.selfColorIndex:
      continue
    if bot.knownImposterColor(i):
      continue
    if t > bestTick:
      bestTick = t
      suspect = i

  # Tier 2: fall back to most recent near-body sighting.
  if suspect < 0:
    for i, t in bot.nearBodyTicks:
      if i == bot.selfColorIndex:
        continue
      if bot.knownImposterColor(i):
        continue
      if t > bestTick:
        bestTick = t
        suspect = i

  if suspect < 0 or suspect >= PlayerColorNames.len:
    return (false, "", -1)
  (true, playerColorName(suspect), suspect)

proc randomInnocentColor(bot: var Bot): int =
  ## Picks a random non-self, non-teammate color we've seen alive this game.
  ##
  ## Used by the imposter to deflect blame. Prefers players we've actually
  ## seen (lastSeenTicks > 0) so we don't accuse a color that isn't even in
  ## the game; falls back to all non-self/non-teammate colors otherwise.
  var
    seenCount = 0
    anyCount = 0
    seenCandidates: array[PlayerColorCount, int]
    anyCandidates: array[PlayerColorCount, int]
  for i in 0 ..< PlayerColorCount:
    if i == bot.selfColorIndex:
      continue
    if bot.knownImposterColor(i):
      continue
    anyCandidates[anyCount] = i
    inc anyCount
    if bot.lastSeenTicks[i] > 0:
      seenCandidates[seenCount] = i
      inc seenCount
  if seenCount > 0:
    return seenCandidates[bot.rng.rand(seenCount - 1)]
  if anyCount > 0:
    return anyCandidates[bot.rng.rand(anyCount - 1)]
  -1

proc suspectSummary(bot: Bot): string =
  ## Returns a short debug summary for the current suspect.
  let suspect = bot.suspectedColor()
  if not suspect.found:
    return "none"
  suspect.name & " seen=" & $suspect.tick

proc imposterBodyMessage(bot: var Bot, base: string): string =
  ## Imposter chat: "body in <room> sus <random innocent>". Random target
  ## is the deflection — the most-recently-seen suspect is often the actual
  ## victim (a tell), so we deliberately pick someone else.
  let ci = bot.randomInnocentColor()
  if ci >= 0 and ci < PlayerColorNames.len:
    return base & " sus " & PlayerColorNames[ci]
  base

proc crewmateBodyMessage(bot: Bot, base: string): string =
  ## Crewmate chat: only accuses with firsthand evidence. Stays neutral
  ## otherwise so other bots can't manipulate our vote by chatting first.
  let suspect = bot.evidenceBasedSuspect()
  if not suspect.found:
    return base
  base & " sus " & suspect.name

proc bodyRoomMessage(bot: var Bot, x, y: int): string =
  ## Builds a short chat line that names a body's room.
  ##
  ## Branches by role:
  ##   IMPOSTER — random non-imposter color (always accuses someone)
  ##   CREWMATE — only accuses with firsthand evidence (witnessed kill or
  ##              saw a player next to a body); otherwise stays neutral
  let room = bot.roomNameAt(x + CollisionW div 2, y + CollisionH div 2)
  let base =
    if room == "unknown":
      "body"
    else:
      "body in " & room
  if bot.role == RoleImposter:
    return bot.imposterBodyMessage(base)
  bot.crewmateBodyMessage(base)

proc queueBodySeen(bot: var Bot, x, y: int) =
  ## Stores the room for a discovered body until voting opens.
  if sameBody(x, y, bot.lastBodySeenX, bot.lastBodySeenY):
    return
  bot.lastBodySeenX = x
  bot.lastBodySeenY = y
  bot.pendingChat = bot.bodyRoomMessage(x, y)

proc queueBodyReport(bot: var Bot, x, y: int) =
  ## Stores the room for a reported body until voting opens.
  if sameBody(x, y, bot.lastBodyReportX, bot.lastBodyReportY):
    return
  bot.lastBodyReportX = x
  bot.lastBodyReportY = y
  bot.pendingChat = bot.bodyRoomMessage(x, y)

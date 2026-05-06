proc voteSlotForColor(bot: Bot, colorIndex: int): int =
  ## Returns the voting slot index for one player color.
  for i in 0 ..< bot.votePlayerCount:
    if bot.voteSlots[i].colorIndex == colorIndex:
      return i
  VoteUnknown

proc voteTargetName(bot: Bot, target: int): string =
  ## Returns a short display name for a voting target.
  if target == VoteSkip:
    return "skip"
  if target >= 0 and target < bot.votePlayerCount:
    return playerColorName(bot.voteSlots[target].colorIndex)
  "unknown"

proc voteSummary(bot: Bot): string =
  ## Returns a compact summary of parsed votes.
  for i, choice in bot.voteChoices:
    if choice == VoteUnknown:
      continue
    if result.len > 0:
      result.add(", ")
    result.add(playerColorName(i))
    result.add("->")
    result.add(bot.voteTargetName(choice))
  if result.len == 0:
    result = "none"

proc selfVoteChoice(bot: Bot): int =
  ## Returns the parsed vote choice for the local player.
  if bot.selfColorIndex >= 0 and bot.selfColorIndex < bot.voteChoices.len:
    return bot.voteChoices[bot.selfColorIndex]
  if bot.voteSelfSlot >= 0 and bot.voteSelfSlot < bot.votePlayerCount:
    let colorIndex = bot.voteSlots[bot.voteSelfSlot].colorIndex
    if colorIndex >= 0 and colorIndex < bot.voteChoices.len:
      return bot.voteChoices[colorIndex]
  VoteUnknown

proc nextVoteSelectable(bot: Bot, cursor, direction: int): int =
  ## Returns the next selectable voting cursor slot.
  let total = bot.votePlayerCount + 1
  if total <= 0:
    return VoteUnknown
  var cur = cursor
  for step in 1 .. total:
    cur = (cur + direction + total) mod total
    if cur == bot.votePlayerCount:
      return cur
    if cur >= 0 and cur < bot.votePlayerCount and bot.voteSlots[cur].alive:
      return cur
  VoteUnknown

proc voteStepsTo(bot: Bot, target, direction: int): int =
  ## Counts cursor steps in one direction to a target.
  if bot.voteCursor == VoteUnknown:
    return high(int)
  var cur = bot.voteCursor
  for step in 0 .. bot.votePlayerCount + 1:
    if cur == target:
      return step
    cur = bot.nextVoteSelectable(cur, direction)
    if cur == VoteUnknown:
      return high(int)
  high(int)

proc voteMoveDirection(bot: Bot, target: int): int =
  ## Chooses the shortest voting cursor direction toward a target.
  let
    leftSteps = bot.voteStepsTo(target, -1)
    rightSteps = bot.voteStepsTo(target, 1)
  if leftSteps < rightSteps:
    -1
  else:
    1

proc desiredVotingTarget(bot: Bot): int =
  ## Chooses the voting target.
  ##
  ## IMPOSTER — keep the original behaviour: bandwagon onto chat-named sus
  ##   if any (deflection blends in), then fall back to most-recently-seen,
  ##   else skip.
  ##
  ## CREWMATE — ignore chat entirely. Only vote for a player when we have
  ##   firsthand evidence (witnessed kill or saw them next to a body).
  ##   Otherwise vote skip — staying neutral is worth more than guessing,
  ##   and immune to manipulation by an imposter who chats first.
  if bot.role == RoleImposter:
    if bot.voteChatSusColor >= 0:
      let slot = bot.voteSlotForColor(bot.voteChatSusColor)
      if slot >= 0 and slot != bot.voteSelfSlot and bot.voteSlots[slot].alive:
        return slot
    let suspect = bot.suspectedColor()
    if suspect.found:
      let slot = bot.voteSlotForColor(suspect.colorIndex)
      if slot >= 0 and slot != bot.voteSelfSlot and bot.voteSlots[slot].alive:
        return slot
    return bot.votePlayerCount

  # Crewmate: evidence-only.
  let suspect = bot.evidenceBasedSuspect()
  if suspect.found:
    let slot = bot.voteSlotForColor(suspect.colorIndex)
    if slot >= 0 and slot != bot.voteSelfSlot and bot.voteSlots[slot].alive:
      return slot
  bot.votePlayerCount

proc decideVotingMask(bot: var Bot): uint8 =
  ## Chooses voting-screen input from parsed vote state.
  bot.hasGoal = false
  bot.hasPathStep = false
  bot.path.setLen(0)
  bot.voteTarget = bot.desiredVotingTarget()
  let ownVote = bot.selfVoteChoice()
  if ownVote != VoteUnknown:
    bot.desiredMask = 0
    bot.controllerMask = 0
    bot.intent = "voted " & bot.voteTargetName(ownVote)
    bot.thought(bot.intent)
    return 0
  if bot.voteCursor != bot.voteTarget:
    let direction = bot.voteMoveDirection(bot.voteTarget)
    let mask =
      if direction < 0:
        ButtonLeft
      else:
        ButtonRight
    bot.desiredMask =
      if bot.lastMask == mask:
        0
      else:
        mask
    bot.controllerMask = bot.desiredMask
    bot.intent = "voting cursor to " & bot.voteTargetName(bot.voteTarget)
    bot.thought(bot.intent)
    return bot.desiredMask
  let listenedTicks =
    if bot.voteStartTick >= 0:
      bot.frameTick - bot.voteStartTick
    else:
      0
  if listenedTicks < VoteListenTicks:
    bot.desiredMask = 0
    bot.controllerMask = 0
    bot.intent = "ready, listening in vote chat " &
      $listenedTicks & "/" & $VoteListenTicks
    bot.thought(bot.intent)
    return 0
  bot.desiredMask =
    if bot.lastMask == ButtonA:
      0
    else:
      ButtonA
  bot.controllerMask = bot.desiredMask
  bot.intent = "voting for " & bot.voteTargetName(bot.voteTarget)
  bot.thought(bot.intent)
  bot.desiredMask

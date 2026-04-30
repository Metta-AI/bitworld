## Evidence-based suspect picking. Witness-tick bookkeeping for the
## crewmate accusation policy.
##
## Phase 1 port from v2:2508-2530 (identity helpers), v2:2835-2867
## (body / suspect helpers), v2:2870-3013 (evidence + suspect picking),
## v2:3015-3020 (debug summary), and v2:2815-2826 (loneVisibleCrewmate).
##
## This module is the heart of the crewmate accusation policy: it
## records who was where when bodies appeared and turns those
## observations into a binary "we have evidence" / "we don't" decision.
## Voting falls back to skip in the latter case — the bot's defining
## refusal to bandwagon on chat.

import std/random

import ../../sim

import types
import geometry
import path  # for `heuristic`

# ---------------------------------------------------------------------------
# Identity helpers
# ---------------------------------------------------------------------------

const
  PlayerColorNames* = [
    "red",
    "orange",
    "yellow",
    "light blue",
    "pink",
    "lime",
    "blue",
    "pale blue",
    "gray",
    "white",
    "dark brown",
    "brown",
    "dark teal",
    "green",
    "dark navy",
    "black"
  ]
  WitnessNearBodyRadius* = KillRange * 2
    ## A non-self crewmate within this many world pixels of a body is
    ## "next to" it for accusation purposes. Wide enough to forgive a
    ## step or two of motion, tight enough not to implicate anyone
    ## passing through the room.

proc playerColorName*(colorIndex: int): string =
  ## Human-readable colour name for chat messages and debug strings.
  if colorIndex >= 0 and colorIndex < PlayerColorNames.len:
    PlayerColorNames[colorIndex]
  else:
    "unknown"

proc knownImposterColor*(bot: Bot, colorIndex: int): bool =
  ## True if the colour was shown as an imposter teammate during the
  ## role-reveal interstitial.
  colorIndex >= 0 and
    colorIndex < bot.identity.knownImposters.len and
    bot.identity.knownImposters[colorIndex]

# ---------------------------------------------------------------------------
# Body / crewmate visibility queries
# ---------------------------------------------------------------------------

proc nearestBody*(bot: Bot): tuple[found: bool, x: int, y: int] =
  ## Returns the nearest visible body in world coordinates, or
  ## found=false if none visible.
  var bestDistance = high(int)
  for body in bot.percep.visibleBodies:
    let world = bot.percep.visibleBodyWorld(body)
    let distance = heuristic(
      bot.percep.playerWorldX(),
      bot.percep.playerWorldY(),
      world.x,
      world.y
    )
    if distance < bestDistance:
      bestDistance = distance
      result = (true, world.x, world.y)

proc sameBody*(ax, ay, bx, by: int): bool =
  ## True when two body sightings are probably the same body. Uses a
  ## generous threshold (BodySearchRadius + 4) to absorb sprite
  ## anchor jitter between frames.
  if bx == low(int) or by == low(int):
    return false
  heuristic(ax, ay, bx, by) <= 1 + 4   # BodySearchRadius is 1; inlined here.

proc loneVisibleCrewmate*(bot: Bot): tuple[found: bool,
                                          crewmate: CrewmateMatch] =
  ## Returns the only visible non-teammate crewmate, or found=false
  ## if zero or more-than-one are visible. Used by the imposter to
  ## gate kill attempts (no kill when witnesses are present).
  for crewmate in bot.percep.visibleCrewmates:
    if bot.knownImposterColor(crewmate.colorIndex):
      continue
    if result.found:
      result.found = false
      return
    result.found = true
    result.crewmate = crewmate

# ---------------------------------------------------------------------------
# Suspect picking
# ---------------------------------------------------------------------------

proc suspectedColor*(bot: Bot): tuple[found: bool, name: string,
                                     tick: int, colorIndex: int] =
  ## Returns the most recently seen non-self, non-teammate colour.
  ## Used by the imposter to bandwagon on chat; the crewmate's vote
  ## logic uses `evidenceBasedSuspect` instead.
  var bestTick = 0
  for i, tick in bot.identity.lastSeen:
    if i == bot.identity.selfColor:
      continue
    if bot.knownImposterColor(i):
      continue
    if tick > bestTick and i < PlayerColorNames.len:
      bestTick = tick
      result = (true, playerColorName(i), tick, i)

# ---------------------------------------------------------------------------
# Evidence accumulation
# ---------------------------------------------------------------------------

proc updateEvidence*(bot: var Bot) =
  ## Stamps colours that were seen near visible bodies this frame.
  ##
  ## Two tiers of evidence:
  ##   nearBodyTicks[ci]      — visible non-self, non-teammate colour
  ##                            is within `WitnessNearBodyRadius` of
  ##                            any visible body
  ##   witnessedKillTicks[ci] — same, but only at the frame a body
  ##                            newly appears. Bodies don't move, so
  ##                            a sudden appearance with a player next
  ##                            to it is the strongest signal we get.
  ##
  ## Verbatim from v2:2870-2949 modulo the sub-record renames.
  var bodyWorlds: seq[tuple[x: int, y: int]] = @[]
  for body in bot.percep.visibleBodies:
    bodyWorlds.add(bot.percep.visibleBodyWorld(body))

  # Resolve visible crewmate world positions, skipping self/teammates.
  var
    cmCount = 0
    cmColors: array[PlayerColorCount, int]
    cmX: array[PlayerColorCount, int]
    cmY: array[PlayerColorCount, int]
  for crewmate in bot.percep.visibleCrewmates:
    let ci = crewmate.colorIndex
    if ci < 0 or ci >= PlayerColorCount:
      continue
    if ci == bot.identity.selfColor:
      continue
    if bot.knownImposterColor(ci):
      continue
    let world = bot.percep.visibleCrewmateWorld(crewmate)
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
        bot.evidence.nearBodyTicks[cmColors[k]] = bot.frameTick
        break

  # Tier 2: any *new* body (no body within ~SpriteSize last frame)
  # gives the near crewmate(s) the stronger witnessedKill stamp.
  let kill2 = SpriteSize * SpriteSize
  for body in bodyWorlds:
    var isNew = true
    for prev in bot.evidence.prevBodies:
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
        bot.evidence.witnessedKillTicks[cmColors[k]] = bot.frameTick

  # Persist this frame's positions for next frame's diff.
  for i in 0 ..< PlayerColorCount:
    bot.evidence.prevCrewmateX[i] = -1
    bot.evidence.prevCrewmateY[i] = -1
  for k in 0 ..< cmCount:
    bot.evidence.prevCrewmateX[cmColors[k]] = cmX[k]
    bot.evidence.prevCrewmateY[cmColors[k]] = cmY[k]
  bot.evidence.prevBodies = bodyWorlds

# ---------------------------------------------------------------------------
# Suspect resolution for voting
# ---------------------------------------------------------------------------

proc evidenceBasedSuspect*(bot: Bot): tuple[found: bool, name: string,
                                            colorIndex: int] =
  ## Returns the strongest evidence-backed suspect. found=false means
  ## no firsthand evidence — vote skip.
  var
    bestTick = 0
    suspect = -1

  # Tier 1: most recent witnessed kill wins.
  for i, t in bot.evidence.witnessedKillTicks:
    if i == bot.identity.selfColor:
      continue
    if bot.knownImposterColor(i):
      continue
    if t > bestTick:
      bestTick = t
      suspect = i

  # Tier 2: fall back to most recent near-body sighting.
  if suspect < 0:
    for i, t in bot.evidence.nearBodyTicks:
      if i == bot.identity.selfColor:
        continue
      if bot.knownImposterColor(i):
        continue
      if t > bestTick:
        bestTick = t
        suspect = i

  if suspect < 0 or suspect >= PlayerColorNames.len:
    return (false, "", -1)
  (true, playerColorName(suspect), suspect)

# ---------------------------------------------------------------------------
# Imposter helpers
# ---------------------------------------------------------------------------

proc randomInnocentColor*(bot: var Bot): int =
  ## Picks a random non-self, non-teammate colour we've seen alive
  ## this game. Prefers actually-seen colours (lastSeen > 0); falls
  ## back to all non-self/non-teammate colours otherwise.
  ##
  ## Pulls from `bot.rngs.imposterChat` (Q6: per-consumer substream).
  var
    seenCount = 0
    anyCount = 0
    seenCandidates: array[PlayerColorCount, int]
    anyCandidates: array[PlayerColorCount, int]
  for i in 0 ..< PlayerColorCount:
    if i == bot.identity.selfColor:
      continue
    if bot.knownImposterColor(i):
      continue
    anyCandidates[anyCount] = i
    inc anyCount
    if bot.identity.lastSeen[i] > 0:
      seenCandidates[seenCount] = i
      inc seenCount
  if seenCount > 0:
    return seenCandidates[bot.rngs.imposterChat.rand(seenCount - 1)]
  if anyCount > 0:
    return anyCandidates[bot.rngs.imposterChat.rand(anyCount - 1)]
  -1

proc suspectSummary*(bot: Bot): string =
  ## Short debug string for the most-recently-seen suspect.
  let suspect = bot.suspectedColor()
  if not suspect.found:
    return "none"
  suspect.name & " seen=" & $suspect.tick

proc knownImposterSummary*(bot: Bot): string =
  ## Compact debug string for known imposter colours.
  for i, known in bot.identity.knownImposters:
    if not known:
      continue
    if result.len > 0:
      result.add(", ")
    result.add(playerColorName(i))
  if result.len == 0:
    result = "none"

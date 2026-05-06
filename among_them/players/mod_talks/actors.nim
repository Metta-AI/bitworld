## Actor sprite scanning: live crewmates, dead bodies, ghosts, the role
## icon (kill button / ghost UI), task icons, radar dots, and self-colour.
##
## Phase 1 port from v2:1374-1395 (radar), v2:1473-1508 (role icon),
## v2:1510-1515 (icon dedup), v2:1643-1695 (crewmate scan / self-colour /
## role reveal), v2:2069-2125 (body / ghost), v2:2127-2144 (task icons).
##
## All scanners take `var Bot` and write to one or more `Perception` /
## `Identity` sub-records. They are mutating leaves; the orchestrator in
## `bot.nim` calls them via the `scanAll` proc near the end of this
## file. The `scanCamera` parameter on `scanAll` is the resolved Q2
## option-c contract: scans run against either prev-frame camera (first
## pass) or the just-locked current camera (re-scan after teleport).

import protocol
import ../../sim
import ../../../common/server

import types
import geometry
import frame
import sprite_match
import memory

const
  GhostIconMaxMisses* = 3
  GhostIconFrameThreshold* = 2
    ## Frames of ghost-icon evidence before flipping `bot.isGhost = true`.
  RadarPeripheryMargin* = 1
    ## Width (in pixels) of the screen-edge strip scanned for radar dots.
  CrewmateSearchRadius* = 1
    ## Dedup radius for `addCrewmateMatch` overlap checks.
  BodySearchRadius* = 1
  BodyMaxMisses* = 9
  BodyMinStablePixels* = 6
  BodyMinTintPixels* = 6
  GhostSearchRadius* = 1
  GhostMaxMisses* = 9
  GhostMinStablePixels* = 6
  GhostMinTintPixels* = 6
  TaskIconExpectedSearchRadius* = 3
    ## How many pixels around a task's expected icon position we sweep
    ## for a strict sprite match.

# ---------------------------------------------------------------------------
# Match-list dedup helpers
# ---------------------------------------------------------------------------

proc addIconMatch*(matches: var seq[IconMatch], x, y: int) =
  ## Adds a task-icon match unless a within-1-pixel duplicate exists.
  for match in matches:
    if abs(match.x - x) <= 1 and abs(match.y - y) <= 1:
      return
  matches.add(IconMatch(x: x, y: y))

proc addCrewmateMatch*(matches: var seq[CrewmateMatch],
                     x, y: int, colorIndex: int, flipH: bool) =
  ## Adds one crewmate match unless an overlapping match already
  ## exists. If a previous nearby match has unknown colour and the new
  ## one resolved a colour, we promote the existing entry instead of
  ## adding a duplicate.
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

proc addBodyMatch*(matches: var seq[BodyMatch], x, y: int) =
  for match in matches:
    if abs(match.x - x) <= BodySearchRadius and
        abs(match.y - y) <= BodySearchRadius:
      return
  matches.add(BodyMatch(x: x, y: y))

proc addGhostMatch*(matches: var seq[GhostMatch],
                  x, y: int, flipH: bool) =
  for match in matches:
    if abs(match.x - x) <= GhostSearchRadius and
        abs(match.y - y) <= GhostSearchRadius:
      return
  matches.add(GhostMatch(x: x, y: y, flipH: flipH))

proc addRadarDot*(dots: var seq[RadarDot], x, y: int) =
  for dot in dots:
    if abs(dot.x - x) <= 1 and abs(dot.y - y) <= 1:
      return
  dots.add(RadarDot(x: x, y: y))

# ---------------------------------------------------------------------------
# Role detection from HUD icons
# ---------------------------------------------------------------------------

proc updateRole*(bot: var Bot) =
  ## Updates role and ghost state from the fixed HUD icon slot. Reads
  ## the unpacked frame at (KillIconX, KillIconY); writes
  ## `bot.role`, `bot.isGhost`, `bot.ghostIconFrames`,
  ## `bot.imposter.killReady`. Verbatim port of v2:1473-1508 modulo the
  ## sub-record renames.
  let ghostScore = spriteMisses(
    bot.io.unpacked, bot.sprites.ghostIcon, KillIconX, KillIconY)
  if ghostScore.opaque > 0 and ghostScore.misses <= GhostIconMaxMisses:
    inc bot.ghostIconFrames
    bot.imposter.killReady = false
    if bot.ghostIconFrames >= GhostIconFrameThreshold:
      bot.isGhost = true
      if bot.role == RoleUnknown:
        bot.role = RoleCrewmate
    return
  elif not bot.isGhost:
    bot.ghostIconFrames = 0

  let lit = matchesSprite(
    bot.io.unpacked, bot.sprites.killButton, KillIconX, KillIconY)
  let shaded = matchesSpriteShadowed(
    bot.io.unpacked, bot.sprites.killButton, KillIconX, KillIconY)
  bot.imposter.killReady = lit
  if lit or shaded:
    bot.role = RoleImposter
  elif bot.role == RoleUnknown:
    bot.role = RoleCrewmate

# ---------------------------------------------------------------------------
# Crewmate / body / ghost scans
# ---------------------------------------------------------------------------

proc scanCrewmates*(bot: var Bot) =
  ## Scans the current frame for crewmates by stable sprite pixels.
  ## Skips the player-sprite-centred area (we recover self colour from
  ## a separate fixed-position pass in `updateSelfColor`).
  bot.percep.visibleCrewmates.setLen(0)
  let sprite = bot.sprites.player
  for y in 0 .. ScreenHeight - sprite.height:
    for x in 0 .. ScreenWidth - sprite.width:
      if abs(x + SpriteSize div 2 - PlayerScreenX) <= PlayerIgnoreRadius and
          abs(y + SpriteSize div 2 - PlayerScreenY) <= PlayerIgnoreRadius:
        continue
      if matchesCrewmate(bot.io.unpacked, sprite, x, y, false):
        let ci = crewmateColorIndex(bot.io.unpacked, sprite, x, y, false)
        bot.percep.visibleCrewmates.addCrewmateMatch(x, y, ci, false)
      elif matchesCrewmate(bot.io.unpacked, sprite, x, y, true):
        let ci = crewmateColorIndex(bot.io.unpacked, sprite, x, y, true)
        bot.percep.visibleCrewmates.addCrewmateMatch(x, y, ci, true)
  for crewmate in bot.percep.visibleCrewmates:
    if crewmate.colorIndex < 0 or
        crewmate.colorIndex >= PlayerColorCount:
      continue
    # Skip known imposter teammates — we don't track alibi / suspect
    # state for them.
    if crewmate.colorIndex < bot.identity.knownImposters.len and
        bot.identity.knownImposters[crewmate.colorIndex]:
      continue
    # Skip self (we shouldn't normally see our own sprite scan-
    # matched, but dead-ghost edge cases can surface it).
    if crewmate.colorIndex == bot.identity.selfColor:
      continue
    let world = bot.percep.visibleCrewmateWorld(crewmate)
    let roomId = bot.sim.roomIdAt(world.x, world.y)
    discard bot.memory.appendSighting(
      bot.frameTick, crewmate.colorIndex, world.x, world.y, roomId)

proc updateSelfColor*(bot: var Bot) =
  ## Reads the centred player sprite's tint and stores the resulting
  ## colour index in `bot.identity.selfColor`. No-op if the sprite
  ## doesn't match (e.g. player is dead / invisible).
  let
    sprite = bot.sprites.player
    x = PlayerScreenX - sprite.width div 2
    y = PlayerScreenY - sprite.height div 2
  var colorIndex = -1
  if matchesCrewmate(bot.io.unpacked, sprite, x, y, false):
    colorIndex = crewmateColorIndex(bot.io.unpacked, sprite, x, y, false)
  elif matchesCrewmate(bot.io.unpacked, sprite, x, y, true):
    colorIndex = crewmateColorIndex(bot.io.unpacked, sprite, x, y, true)
  if colorIndex >= 0 and colorIndex < PlayerColorCount:
    bot.identity.selfColor = colorIndex

proc rememberRoleReveal*(bot: var Bot) =
  ## On the role-reveal interstitial: set role from the title text and,
  ## if imposter, walk the frame for visible teammate crewmates and
  ## stamp their colours into `bot.identity.knownImposters`.
  if bot.percep.interstitialText == "CREWMATE":
    if bot.role == RoleUnknown:
      bot.role = RoleCrewmate
    return
  if bot.percep.interstitialText != "IMPS":
    return
  bot.role = RoleImposter
  let sprite = bot.sprites.player
  for y in 0 .. ScreenHeight - sprite.height:
    for x in 0 .. ScreenWidth - sprite.width:
      if matchesCrewmate(bot.io.unpacked, sprite, x, y, false):
        let ci = crewmateColorIndex(bot.io.unpacked, sprite, x, y, false)
        bot.percep.visibleCrewmates.addCrewmateMatch(x, y, ci, false)
      elif matchesCrewmate(bot.io.unpacked, sprite, x, y, true):
        let ci = crewmateColorIndex(bot.io.unpacked, sprite, x, y, true)
        bot.percep.visibleCrewmates.addCrewmateMatch(x, y, ci, true)
  for crewmate in bot.percep.visibleCrewmates:
    if crewmate.colorIndex >= 0 and
        crewmate.colorIndex < bot.identity.knownImposters.len:
      bot.identity.knownImposters[crewmate.colorIndex] = true

proc scanBodies*(bot: var Bot) =
  ## Scans the current frame for visible dead bodies.
  bot.percep.visibleBodies.setLen(0)
  let sprite = bot.sprites.body
  for y in 0 .. ScreenHeight - sprite.height:
    for x in 0 .. ScreenWidth - sprite.width:
      if matchesActorSprite(bot.io.unpacked, sprite, x, y, false,
                            BodyMaxMisses, BodyMinStablePixels,
                            BodyMinTintPixels):
        bot.percep.visibleBodies.addBodyMatch(x, y)

proc scanGhosts*(bot: var Bot) =
  ## Scans the current frame for visible ghosts (other players, not
  ## self — self-ghost state is detected via the HUD icon in
  ## `updateRole`).
  bot.percep.visibleGhosts.setLen(0)
  let sprite = bot.sprites.ghost
  for y in 0 .. ScreenHeight - sprite.height:
    for x in 0 .. ScreenWidth - sprite.width:
      if matchesActorSprite(bot.io.unpacked, sprite, x, y, false,
                            GhostMaxMisses, GhostMinStablePixels,
                            GhostMinTintPixels):
        bot.percep.visibleGhosts.addGhostMatch(x, y, false)
      elif matchesActorSprite(bot.io.unpacked, sprite, x, y, true,
                              GhostMaxMisses, GhostMinStablePixels,
                              GhostMinTintPixels):
        bot.percep.visibleGhosts.addGhostMatch(x, y, true)

# ---------------------------------------------------------------------------
# Task icon scan (fixed-position, expected-location)
# ---------------------------------------------------------------------------

proc scanTaskIcons*(bot: var Bot) =
  ## Scans expected task-icon positions for a strict sprite match.
  ## Costs much less than a global icon search and is more reliable —
  ## an icon's screen position is fully determined by the task's world
  ## position and the current camera lock.
  ##
  ## Reads `bot.percep.cameraX/Y` (must be valid; gated by
  ## `bot.percep.localized`).
  bot.percep.visibleTaskIcons.setLen(0)
  if not bot.percep.localized:
    return
  let sprite = bot.sprites.task
  for task in bot.sim.tasks:
    let
      baseX = task.x + task.w div 2 - SpriteSize div 2 - bot.percep.cameraX
      baseY = task.y - SpriteSize - 2 - bot.percep.cameraY
    for bobY in -1 .. 1:
      let expectedY = baseY + bobY
      for dy in -TaskIconExpectedSearchRadius .. TaskIconExpectedSearchRadius:
        for dx in -TaskIconExpectedSearchRadius .. TaskIconExpectedSearchRadius:
          let
            x = baseX + dx
            y = expectedY + dy
          if matchesSprite(bot.io.unpacked, sprite, x, y):
            bot.percep.visibleTaskIcons.addIconMatch(x, y)

# ---------------------------------------------------------------------------
# Radar dots
# ---------------------------------------------------------------------------

proc isRadarPeriphery*(x, y: int): bool =
  ## True for pixels in the screen-edge strip that hosts the task radar.
  x <= RadarPeripheryMargin or y <= RadarPeripheryMargin or
    x >= ScreenWidth - 1 - RadarPeripheryMargin or
    y >= ScreenHeight - 1 - RadarPeripheryMargin

proc scanRadarDots*(bot: var Bot) =
  ## Walks the screen-edge strip for yellow radar pixels.
  bot.percep.radarDots.setLen(0)
  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      if not isRadarPeriphery(x, y):
        continue
      if bot.io.unpacked[y * ScreenWidth + x] == RadarTaskColor:
        bot.percep.radarDots.addRadarDot(x, y)

# ---------------------------------------------------------------------------
# Combined scan entry point (called by the orchestrator)
# ---------------------------------------------------------------------------

proc scanAll*(bot: var Bot) =
  ## Runs every actor / radar / icon scan in sequence. The orchestrator
  ## calls this once before localization (using last-frame's camera
  ## inside `scanTaskIcons`) and again after localization if the camera
  ## jumped further than `TeleportThresholdPx`. See DESIGN.md §5.
  ##
  ## Order preserved from v2's `updateLocation` (v2:1338-1346):
  ## role → self → bodies → ghosts → crewmates → task icons. Imposters
  ## skip the task-icon scan because they never do real tasks; the
  ## visibleTaskIcons list is cleared instead.
  updateRole(bot)
  updateSelfColor(bot)
  scanBodies(bot)
  scanGhosts(bot)
  scanCrewmates(bot)
  if bot.role == RoleImposter and not bot.isGhost:
    bot.percep.visibleTaskIcons.setLen(0)
  else:
    scanTaskIcons(bot)

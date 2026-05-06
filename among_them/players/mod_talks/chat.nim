## Chat message templating and queueing.
##
## Phase 1 port from v2:3022-3070. The asymmetry between the crewmate
## and imposter chat templates is the design's defining feature: the
## crewmate only accuses on firsthand evidence (deferring to skip
## otherwise), while the imposter pre-loads a deflection accusing a
## random innocent. Both templates live in this one module so the
## asymmetry is visible at a glance.

import ../../sim

import types
import geometry
import evidence

proc imposterBodyMessage*(bot: var Bot, base: string): string =
  ## Imposter chat: `body in <room> sus <random innocent>`. Random
  ## target is the deflection — the most-recently-seen suspect is
  ## often the actual victim (a tell), so we deliberately avoid them.
  let ci = bot.randomInnocentColor()
  if ci >= 0 and ci < PlayerColorNames.len:
    return base & " sus " & PlayerColorNames[ci]
  base

proc crewmateBodyMessage*(bot: Bot, base: string): string =
  ## Crewmate chat: only accuses with firsthand evidence. Stays
  ## neutral otherwise so chat-first imposters can't manipulate our
  ## vote.
  let suspect = bot.evidenceBasedSuspect()
  if not suspect.found:
    return base
  base & " sus " & suspect.name

proc bodyRoomMessage*(bot: var Bot, x, y: int): string =
  ## Builds the role-appropriate body-sighting chat line. Used by
  ## both the "I saw a body" and "I'm reporting a body" queueings.
  let room = bot.sim.roomNameAt(x + CollisionW div 2, y + CollisionH div 2)
  let base =
    if room == "unknown":
      "body"
    else:
      "body in " & room
  if bot.role == RoleImposter:
    return bot.imposterBodyMessage(base)
  bot.crewmateBodyMessage(base)

proc queueBodySeen*(bot: var Bot, x, y: int) =
  ## Stores the room for a discovered body until voting opens. Dedup
  ## via `sameBody` against the last seen position.
  if sameBody(x, y, bot.chat.lastBodySeenX, bot.chat.lastBodySeenY):
    return
  bot.chat.lastBodySeenX = x
  bot.chat.lastBodySeenY = y
  bot.chat.pendingChat = bot.bodyRoomMessage(x, y)

proc queueBodyReport*(bot: var Bot, x, y: int) =
  ## Stores the room for a reported body until voting opens. Used
  ## when the bot itself is pressing A to call a meeting.
  if sameBody(x, y, bot.chat.lastBodyReportX, bot.chat.lastBodyReportY):
    return
  bot.chat.lastBodyReportX = x
  bot.chat.lastBodyReportY = y
  bot.chat.pendingChat = bot.bodyRoomMessage(x, y)

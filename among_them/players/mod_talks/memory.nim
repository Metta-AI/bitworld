## Long-term evidence memory for voting and planning decisions.
##
## Implements the round-scoped event log plus per-colour summaries
## defined in DESIGN.md §13. Four event categories:
##
##   * Sightings — per-frame observations of non-self, non-teammate
##     crewmates. Dedup'd by tick Δ + pixel Δ; trimmed at meeting
##     close.
##   * Bodies — first-seen records of distinct bodies. Dedup'd round-
##     lifetime by position; never trimmed.
##   * Meetings — one entry per completed meeting, appended at meeting
##     close with votes / ejection / chat lines. Never trimmed.
##   * Alibis — positive-innocence signals: colour seen at a task
##     terminal. Per-(colour, task) dedup; trimmed at meeting close.
##
## This module is pure data + pure append procs. It does not call into
## the trace writer; `trace.nim` observes memory growth via its own
## shadow (`prevBodiesCount`, `prevMeetingsCount`) to avoid a circular
## import and to keep tracing zero-cost when disabled.
##
## Every append proc returns `bool` so callers can gate trace emission
## on "was it actually recorded". Summaries update regardless of
## dedup; the return bool governs only the raw log.

import std/bitops

import ../../sim

import types
import tuning

# ---------------------------------------------------------------------------
# Construction / round lifecycle
# ---------------------------------------------------------------------------

proc initMemory*(): Memory =
  ## Returns a zeroed memory with `-1` sentinels where 0 would be a
  ## valid value. All per-colour arrays are zero-default except for
  ## `lastSightingIndex` which uses `-1` for "no sighting yet".
  for i in 0 ..< PlayerColorCount:
    result.lastSightingIndex[i] = -1
    result.summaries[i].lastSeenX = low(int)
    result.summaries[i].lastSeenY = low(int)
    result.summaries[i].lastSeenRoomId = -1
  result.lastMeetingEndTick = -1
  result.sightings = @[]
  result.bodies = @[]
  result.meetings = @[]
  result.alibis = @[]

proc resetForNewRound*(m: var Memory) =
  ## Clears everything. Called at round boundaries (game-over edge,
  ## role-reveal). Per DESIGN.md §13.3 memory does not persist across
  ## rounds.
  m = initMemory()

proc trimAtMeetingEnd*(m: var Memory, tick: int) =
  ## Discards raw `SightingEvent`s and `AlibiEvent`s older than
  ## `tick`. `bodies` and `meetings` persist. Per-colour summaries
  ## are unaffected; they've already absorbed each event at append
  ## time. After trimming, `lastSightingIndex` entries pointing at
  ## dropped indices become stale — we reset them on trim to avoid
  ## O(n) corrections and accept a brief window where dedup is less
  ## aggressive.
  m.lastMeetingEndTick = tick
  var keptSightings: seq[SightingEvent] = @[]
  for s in m.sightings:
    if s.tick >= tick:
      keptSightings.add(s)
  m.sightings = keptSightings
  var keptAlibis: seq[AlibiEvent] = @[]
  for a in m.alibis:
    if a.tick >= tick:
      keptAlibis.add(a)
  m.alibis = keptAlibis
  # Rebuild lastSightingIndex to point at latest kept entry per
  # colour, or -1 if none survives the trim.
  for i in 0 ..< PlayerColorCount:
    m.lastSightingIndex[i] = -1
  for idx, s in m.sightings:
    if s.colorIndex >= 0 and s.colorIndex < PlayerColorCount:
      m.lastSightingIndex[s.colorIndex] = idx

# ---------------------------------------------------------------------------
# Room lookup helper
# ---------------------------------------------------------------------------

proc roomIdAt*(sim: SimServer, x, y: int): int =
  ## Returns the sim.rooms index containing `(x, y)`, or -1 if the
  ## point lies outside every named room. Memory uses this over
  ## `roomNameAt` because integer ids are cheaper to compare and
  ## serialise than strings.
  for i, room in sim.rooms:
    if x >= room.x and x < room.x + room.w and
        y >= room.y and y < room.y + room.h:
      return i
  -1

# ---------------------------------------------------------------------------
# Sighting append
# ---------------------------------------------------------------------------

proc appendSighting*(m: var Memory, tick, colorIndex, x, y,
                     roomId: int): bool =
  ## Records one sighting. Always updates the per-colour summary.
  ## Returns true when the raw `SightingEvent` was appended (i.e. the
  ## dedup window did not suppress it), false when only the summary
  ## was updated.
  if colorIndex < 0 or colorIndex >= PlayerColorCount:
    return false

  # Summary always updates.
  template s: untyped = m.summaries[colorIndex]
  s.lastSeenTick = tick
  s.lastSeenX = x
  s.lastSeenY = y
  s.lastSeenRoomId = roomId

  # Dedup against the most recent sighting for this colour.
  let lastIdx = m.lastSightingIndex[colorIndex]
  if lastIdx >= 0 and lastIdx < m.sightings.len:
    let last = m.sightings[lastIdx]
    let
      dTick = tick - last.tick
      dx = x - last.x
      dy = y - last.y
    if dTick <= MemorySightingDedupTicks and
        abs(dx) <= MemorySightingDedupPixels and
        abs(dy) <= MemorySightingDedupPixels:
      return false

  m.sightings.add(SightingEvent(
    tick: tick,
    colorIndex: colorIndex,
    x: x,
    y: y,
    roomId: roomId
  ))
  m.lastSightingIndex[colorIndex] = m.sightings.len - 1
  true

# ---------------------------------------------------------------------------
# Body append
# ---------------------------------------------------------------------------

proc appendBody*(m: var Memory, tick, x, y, roomId: int,
                 witnesses: seq[BodyWitness],
                 isNewBody: bool): bool =
  ## Records a first-seen body. Round-lifetime dedup: if we already
  ## have a body within `MemoryBodyDedupPx` of `(x, y)`, nothing is
  ## appended and `false` is returned. Witness summary counts are
  ## only incremented when a new event is appended to avoid
  ## double-counting persistent sightings.
  for existing in m.bodies:
    let
      dx = x - existing.x
      dy = y - existing.y
    if dx * dx + dy * dy <= MemoryBodyDedupPx * MemoryBodyDedupPx:
      return false

  m.bodies.add(BodyEvent(
    tick: tick,
    x: x,
    y: y,
    roomId: roomId,
    witnesses: witnesses,
    isNewBody: isNewBody
  ))
  for w in witnesses:
    if w.colorIndex < 0 or w.colorIndex >= PlayerColorCount:
      continue
    inc m.summaries[w.colorIndex].timesNearBody
    if isNewBody:
      inc m.summaries[w.colorIndex].timesWitnessedKill
  true

# ---------------------------------------------------------------------------
# Meeting append
# ---------------------------------------------------------------------------

proc appendMeeting*(m: var Memory, event: MeetingEvent) =
  ## Records one completed meeting. Always appends (meetings are
  ## rare, no dedup needed). Updates per-colour vote counters and
  ## the `ejected` flag for the ejected colour if known.
  m.meetings.add(event)
  # Self-vs-others vote accounting.
  let selfTarget = event.selfVote
  for voterColor, target in event.votes:
    if target == VoteUnknown:
      continue
    if voterColor < 0 or voterColor >= PlayerColorCount:
      continue
    # Did this voter vote for *me* this meeting?
    if selfTarget != VoteUnknown and target == selfTarget and selfTarget >= 0:
      # target is a slot index; we treat self as the voter when
      # target matches selfVote's slot. The match is "did voter's
      # vote land on the same slot I'd voted for" — used as a
      # co-voting signal. Counted under timesVotedWithMe.
      inc m.summaries[voterColor].timesVotedWithMe
    # timesVotedForMe: requires knowing self's slot. Callers should
    # populate via a helper that knows the slot->color map;
    # MeetingEvent alone can't disambiguate so we skip here.
    # timesIVotedForThem: similarly color-dependent; callers do it.
  # Ejection bookkeeping.
  if event.ejected >= 0 and event.ejected < PlayerColorCount:
    m.summaries[event.ejected].ejected = true

proc recordVoteForMe*(m: var Memory, voterColor: int) =
  ## Called by the caller when it knows a voter's target matched
  ## *our* colour. The MeetingEvent holds slot indices and doesn't
  ## know which slot is self without extra state, so the caller
  ## performs the translation and bumps the counter here.
  if voterColor < 0 or voterColor >= PlayerColorCount:
    return
  inc m.summaries[voterColor].timesVotedForMe

proc recordIVotedForThem*(m: var Memory, targetColor: int) =
  ## Companion to `recordVoteForMe`: caller translates the self-vote
  ## slot into a colour index and bumps the counter here.
  if targetColor < 0 or targetColor >= PlayerColorCount:
    return
  inc m.summaries[targetColor].timesIVotedForThem

# ---------------------------------------------------------------------------
# Alibi append
# ---------------------------------------------------------------------------

proc appendAlibi*(m: var Memory, tick, colorIndex, taskIndex: int): bool =
  ## Records a positive-innocence signal. Per-(colour, task) dedup
  ## suppresses repeats within `MemoryAlibiCooldownTicks`.
  if colorIndex < 0 or colorIndex >= PlayerColorCount:
    return false
  if taskIndex < 0 or taskIndex >= 64:
    return false

  # Dedup: scan backward from end; logs are short (meeting-boundary
  # trimmed) so this is cheap.
  for i in countdown(m.alibis.high, 0):
    let a = m.alibis[i]
    if tick - a.tick > MemoryAlibiCooldownTicks:
      break
    if a.colorIndex == colorIndex and a.taskIndex == taskIndex:
      return false

  m.alibis.add(AlibiEvent(
    tick: tick,
    colorIndex: colorIndex,
    taskIndex: taskIndex
  ))
  let bit = 1'u64 shl taskIndex
  template s: untyped = m.summaries[colorIndex]
  if (s.taskBits and bit) == 0:
    s.taskBits = s.taskBits or bit
    s.distinctTasksObserved = countSetBits(s.taskBits)
  true

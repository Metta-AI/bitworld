## Vote-bandwagon detector unit test.
##
## Exercises the pure helper `trace.tallyBandwagon` — the counter
## that backs the `vote_bandwagon_detected` trace event emitted by
## `detectAndEmitEvents`. Scenarios:
##
##   1. Three distinct voters on the same target inside the window
##      → count 3, voters in observation order.
##   2. Two voters on the same target but one falls outside the
##      window → only the in-window vote counts.
##   3. Votes on a different target are ignored.
##   4. Votes at the window boundary (`delta == WindowTicks`) are
##      included; just beyond it are excluded.
##   5. Empty tally → count 0.
##
## Exit 0 on full pass, 1 on any mismatch.

import std/strformat

import ../trace
import ../tuning
import ../types

var failures = 0

template expect(cond: bool, msg: string) =
  if not cond:
    echo "FAIL: ", msg
    inc failures

proc scenarioThreeVoters() =
  let tally = @[
    VoteTallyEntry(voter: 0, targetCode: 5, tick: 100),
    VoteTallyEntry(voter: 1, targetCode: 5, tick: 120),
    VoteTallyEntry(voter: 2, targetCode: 5, tick: 150)
  ]
  let r = tallyBandwagon(tally, 5, 150)
  expect(r.count == 3, &"three voters count: got {r.count}")
  expect(r.firstTick == 100, &"three voters first_tick: got {r.firstTick}")
  expect(r.voters == @[0, 1, 2],
         &"three voters order: got {r.voters}")

proc scenarioOutOfWindow() =
  # First vote is beyond the window (tick 0 vs tick 200, delta 200
  # > VoteBandwagonWindowTicks=120). Only the in-window vote counts.
  let tally = @[
    VoteTallyEntry(voter: 0, targetCode: 5, tick: 0),
    VoteTallyEntry(voter: 1, targetCode: 5, tick: 180)
  ]
  let r = tallyBandwagon(tally, 5, 200)
  expect(r.count == 1, &"out-of-window count: got {r.count}")
  expect(r.voters == @[1], &"out-of-window voters: got {r.voters}")

proc scenarioDifferentTarget() =
  let tally = @[
    VoteTallyEntry(voter: 0, targetCode: 5, tick: 100),
    VoteTallyEntry(voter: 1, targetCode: 7, tick: 110),
    VoteTallyEntry(voter: 2, targetCode: 7, tick: 120)
  ]
  let r = tallyBandwagon(tally, 7, 120)
  expect(r.count == 2, &"other-target count: got {r.count}")
  expect(r.voters == @[1, 2], &"other-target voters: got {r.voters}")
  let rOther = tallyBandwagon(tally, 5, 120)
  expect(rOther.count == 1,
         &"other-target reverse count: got {rOther.count}")

proc scenarioBoundary() =
  # Δ = VoteBandwagonWindowTicks is in-window (comparison is `>`, not `>=`).
  let w = VoteBandwagonWindowTicks
  let tally = @[
    VoteTallyEntry(voter: 0, targetCode: 5, tick: 100),
    VoteTallyEntry(voter: 1, targetCode: 5, tick: 100 + w),
    VoteTallyEntry(voter: 2, targetCode: 5, tick: 100 + w + 1)
  ]
  let atBoundary = tallyBandwagon(tally, 5, 100 + w)
  expect(atBoundary.count == 2,
         &"boundary count: got {atBoundary.count}")
  let justPast = tallyBandwagon(tally, 5, 100 + w + 1)
  expect(justPast.count == 2,
         &"just-past boundary count (oldest dropped): got {justPast.count}")
  expect(justPast.voters == @[1, 2],
         &"just-past voters: got {justPast.voters}")

proc scenarioEmpty() =
  let tally: seq[VoteTallyEntry] = @[]
  let r = tallyBandwagon(tally, 5, 100)
  expect(r.count == 0, &"empty count: got {r.count}")
  expect(r.voters.len == 0, &"empty voters: got {r.voters}")

when isMainModule:
  scenarioThreeVoters()
  scenarioOutOfWindow()
  scenarioDifferentTarget()
  scenarioBoundary()
  scenarioEmpty()
  if failures == 0:
    echo "vote_bandwagon: OK (5 scenarios passed)"
  else:
    echo &"vote_bandwagon: FAIL ({failures} mismatches)"
    quit(1)

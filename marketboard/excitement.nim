import std/[algorithm, math]
import sim

const
  SnapshotInterval* = 24

type
  TickSnapshot* = object
    tick*: int
    marketCap*: int
    playerGolds*: seq[int]
    playerRoles*: seq[Role]

  ExcitementTracker* = object
    snapshots*: seq[TickSnapshot]
    roleChanges*: int
    lastRoles: seq[Role]

proc recordTick*(tracker: var ExcitementTracker, sim: SimServer) =
  var snap = TickSnapshot(tick: sim.tickCount)
  snap.marketCap = sim.totalMarketCap()
  snap.playerGolds = newSeq[int](sim.players.len)
  snap.playerRoles = newSeq[Role](sim.players.len)
  for i, p in sim.players:
    snap.playerGolds[i] = sim.rewardScore(i)
    snap.playerRoles[i] = p.role

  if tracker.lastRoles.len == sim.players.len:
    for i in 0 ..< sim.players.len:
      if snap.playerRoles[i] != tracker.lastRoles[i] and
          snap.playerRoles[i] != NoRole and tracker.lastRoles[i] != NoRole:
        inc tracker.roleChanges
  tracker.lastRoles = snap.playerRoles
  tracker.snapshots.add snap

proc giniCoefficient(values: seq[int]): float =
  if values.len == 0:
    return 0.0
  let n = values.len
  var total = 0
  for v in values:
    total += v
  if total == 0:
    return 0.0
  var sumDiff = 0.0
  for i in 0 ..< n:
    for j in 0 ..< n:
      sumDiff += abs(float(values[i] - values[j]))
  sumDiff / (2.0 * float(n) * float(total))

proc marketCapVolatility(tracker: ExcitementTracker): float =
  if tracker.snapshots.len < 3:
    return 0.0
  var deltas: seq[float]
  for i in 1 ..< tracker.snapshots.len:
    let prev = tracker.snapshots[i - 1].marketCap
    if prev > 0:
      deltas.add(abs(float(tracker.snapshots[i].marketCap - prev) / float(prev)))
  if deltas.len == 0:
    return 0.0
  var sum = 0.0
  for d in deltas:
    sum += d
  sum / float(deltas.len)

proc wealthInequalitySwing(tracker: ExcitementTracker): float =
  if tracker.snapshots.len < 10:
    return 0.0
  let quarter = tracker.snapshots.len div 4
  let earlyGini = giniCoefficient(tracker.snapshots[quarter].playerGolds)
  let lateGini = giniCoefficient(tracker.snapshots[^(quarter + 1)].playerGolds)
  abs(lateGini - earlyGini)

proc crashRecoveryScore(tracker: ExcitementTracker): float =
  if tracker.snapshots.len < 10:
    return 0.0
  var peakCap = tracker.snapshots[0].marketCap
  var events = 0.0
  var inCrash = false
  var crashFloor = 0
  for snap in tracker.snapshots:
    if snap.marketCap > peakCap:
      peakCap = snap.marketCap
    if not inCrash and peakCap > 0 and
        float(peakCap - snap.marketCap) / float(peakCap) > 0.2:
      inCrash = true
      crashFloor = snap.marketCap
    if inCrash and crashFloor > 0 and
        float(snap.marketCap - crashFloor) / float(crashFloor) > 0.15:
      events += 1.0
      inCrash = false
      peakCap = snap.marketCap
  events

proc marketCapInflections(tracker: ExcitementTracker): float =
  if tracker.snapshots.len < 5:
    return 0.0
  var changes = 0
  var prevDelta = 0
  for i in 1 ..< tracker.snapshots.len:
    let delta = tracker.snapshots[i].marketCap - tracker.snapshots[i - 1].marketCap
    if delta != 0 and prevDelta != 0:
      if (delta > 0) != (prevDelta > 0):
        inc changes
    if delta != 0:
      prevDelta = delta
  float(changes)

proc excitementScore*(tracker: ExcitementTracker): float =
  result += marketCapVolatility(tracker) * 100.0
  result += wealthInequalitySwing(tracker) * 50.0
  result += float(tracker.roleChanges) * 5.0
  result += crashRecoveryScore(tracker) * 30.0
  result += marketCapInflections(tracker) * 2.0

proc topMoments*(tracker: ExcitementTracker, count: int): seq[int] =
  if tracker.snapshots.len < 3:
    return @[]
  type Scored = tuple[tick: int, score: float]
  var scored: seq[Scored]
  for i in 1 ..< tracker.snapshots.len - 1:
    let prev = tracker.snapshots[i - 1].marketCap
    let curr = tracker.snapshots[i].marketCap
    let next = tracker.snapshots[i + 1].marketCap
    let volatility = abs(float(curr - prev)) + abs(float(next - curr))
    var roleSwitch = 0.0
    if i > 0 and tracker.snapshots[i].playerRoles.len ==
        tracker.snapshots[i - 1].playerRoles.len:
      for j in 0 ..< tracker.snapshots[i].playerRoles.len:
        if tracker.snapshots[i].playerRoles[j] !=
            tracker.snapshots[i - 1].playerRoles[j]:
          roleSwitch += 10.0
    scored.add (tick: tracker.snapshots[i].tick, score: volatility + roleSwitch)
  scored.sort(proc(a, b: Scored): int = cmp(b.score, a.score))
  let n = min(count, scored.len)
  for i in 0 ..< n:
    result.add scored[i].tick

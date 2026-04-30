# Radar Hit Counting for Task Goal Selection

**Date:** 2026-04-29
**Status:** Approved design, ready for implementation plan
**Affects:** `among_them/players/lively_lecun/` (task_memory.go, task_radar.go, task_stations.go, agent.go)

## Problem

Crew agents brute-force the map — visiting task stations in distance order — more
often than expected. Diagnosis points at the radar pipeline: `TaskMemory` ends
up with most or all stations in `RadarExcluded`, after which goal selection
falls back to nearest-unvisited.

The current pipeline has two structural flaws:

1. **Ray-casting nearest-along-bearing is lossy.** `NearestStationAlongBearing`
   takes each detected arrow, projects a ray from the player through it, and
   picks the closest *forward* station within `perpBudget=32 px` perpendicular.
   When two assigned stations lie on the same viewport edge, the nearer one
   squelches the farther. Edge-case geometry (corner arrows, dominant-axis
   flipping near diagonals) produces no match at all, which counts as a miss
   for *every* station.

2. **`RadarExcluded` is terminal.** After `noArrowK=6` arrow-less ticks, a
   Maybe demotes to RadarExcluded, and since the recent change to remove the
   promotion path, there's no way back. A real station that misses a few ticks
   due to the matching failures above is permanently out of contention.

The net effect: stations cascade into `RadarExcluded`, the Maybe pool shrinks,
and the agent wanders the map in distance order looking for visual
confirmation.

## Design

Replace per-arrow "find the station behind this ray" with per-station "does a
radar pixel appear where this station's arrow should be?" Track cumulative
radar hits per station and use them to rank unconfirmed candidates.

### State changes

Each `TaskMemory` entry gains:

- `RadarHits int` — cumulative count of ticks where a detected radar arrow
  matched this station's predicted arrow position.

Removed:

- `RadarExcluded` state — with cumulative hit counts, low-evidence Maybes
  naturally sort to the bottom; a separate terminal exclusion state is
  redundant and the "terminal after 6 missed ticks" behavior is exactly the
  over-aggressive filtering that caused the bug.
- `noArrowStreak`, `noArrowK`, `offScreenMargin` — the radar-derived
  demotion to `RadarExcluded` disappears with the state itself.
- `NearestStationAlongBearing` — the per-arrow lookup is replaced by the
  per-station forward prediction. The function becomes dead code and is
  deleted (no caller outside this module).

Retained: `Known`, `Maybe`, `SeenNo` states and the on-screen-no-icon
machinery (`onScreenNoIconStreak`, `onScreenNoIconK`, `onScreenMargin`)
that demotes Maybe → SeenNo after visual inspection. Promotion paths
unchanged — visual icon detection flips Maybe → Known; on-screen without
the icon flips Maybe → SeenNo.

### Per-tick radar matching (inverted)

For each `Maybe` station, predict where its radar arrow *should* appear this
tick, mirroring the server's logic at `sim.nim:2444-2472`:

- Compute delta = station_world - player_world.
- If |delta.x| and |delta.y| are both small enough that the station is on
  screen, the station produces no arrow. Skip (neutral — no hit, no penalty).
- Otherwise determine dominant axis (larger |delta| wins).
- Clamp dominant axis to the viewport border; scale perpendicular axis
  proportionally; clamp perpendicular to viewport bounds.
- The result is the predicted screen-space (sx, sy) of this station's arrow
  pixel.

Then for each detected radar-arrow pixel in the frame, check each station's
predicted position. If the arrow is within **τ = 3 pixels** (Chebyshev /
L∞ distance: max(|dx|, |dy|) ≤ 3) of a predicted position, increment that
station's `RadarHits`. A single arrow may credit multiple stations if their predicted
positions are close — this is acceptable; we can't disambiguate, and the
cumulative count remains useful evidence.

No decay. Counts only grow. If staleness becomes an issue (e.g., a false
positive accumulates early and persistently outranks real stations), revisit
with an exponential decay per tick.

### Goal selection

For crew agents with no `Known` tasks in visual range:

1. If any `Known` stations exist → pick closest Known. *(unchanged)*
2. Else among `Maybe`:
   - Let `top = max(RadarHits)` across all Maybe stations.
   - If `top > 0`: candidate set = all Maybes with `RadarHits ≥ 0.8 * top`.
     Pick the closest station in that set.
   - If `top == 0`: fall back to closest Maybe. *(covers initial exploration
     before any radar evidence accumulates)*
3. `SeenNo` stations never chosen.

The 80% gate lets a moderately-supported closer station win over a slightly-
more-supported far one, but keeps a barely-supported close station from
dominating.

### Migration

On first tick after deploy, all existing entries coalesce to Maybe or Known or
SeenNo based on current state machine. Any `RadarExcluded` entry becomes
`Maybe` with `RadarHits = 0`. The `noArrowStreak` field becomes dead data;
remove it.

## Testing

New tests in `task_memory_test.go` and (if extracted) a `radar_match_test.go`:

- `TestRadarMatching_HitsPredictedPosition` — station off-screen with known
  delta; synthetic frame with an arrow pixel at the predicted position;
  verify `RadarHits` increments by 1.
- `TestRadarMatching_MissBeyondTolerance` — arrow 4 px from predicted position;
  no hit.
- `TestRadarMatching_SharedArrowCreditsBoth` — two stations whose predicted
  positions are within τ of the same arrow pixel; both increment.
- `TestRadarMatching_OnScreenNeutral` — station on-screen (no arrow expected);
  detected radar arrows elsewhere don't affect this station's count.
- `TestGoalSelection_EightyPercentGate` — three Maybes with hits {10, 9, 5};
  verify selection restricted to the first two and resolved by distance.
- `TestGoalSelection_TopZeroFallsBackToDistance` — all Maybes at 0 hits; pick
  closest.
- `TestGoalSelection_KnownBeatsMaybe` — one Known, several high-hit Maybes;
  Known wins regardless of radar counts.

Remove obsolete tests:

- Anything asserting `RadarExcluded` state or the `noArrowK`/`onScreenNoIconK`
  demotion behavior, since that state is gone.

## Open questions

None — tiebreaker confirmed (80% gate, closest wins), on-screen semantics
confirmed (neutral), decay deferred (no decay for v1).

## Non-goals

- Server-side radar prediction accuracy — we mirror sim.nim:2444-2472 exactly,
  not improve it.
- Impostor goal selection — this affects crew task pursuit only.
- Dynamic τ — fixed at 3 pixels for v1; revisit if match rate is poor.

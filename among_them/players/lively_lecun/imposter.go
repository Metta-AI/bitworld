package main

import (
	"log"
	"math/rand"
)

// Imposter decision constants ported from nottoodumb.nim:35-80.
const (
	// killRange in sim.nim:37 default. distSq ≤ 400 world-px to attempt a
	// ButtonA kill (sim.nim:1185-1218 tryKill).
	imposterKillRangeSq = 20 * 20

	// nottoodumb.nim:79 KillApproachRadius. Nav tolerance when chasing
	// down a target the last few tiles.
	imposterKillApproach = 3

	// Fake-target cycle: pick a new random station every N frames if we
	// haven't made progress. Prevents the agent from standing still when
	// a target becomes unreachable.
	imposterFakeRotateFrames = 240 // ~10s @ 24fps

	// Witness range (world-px, Manhattan): any *other* alive crewmate
	// within this distance of the kill target counts as a witness and
	// blocks the A-press. 48 world-px is roughly one viewport-quadrant —
	// close enough that the sim's visibility check (sim.nim:2573
	// screenPointVisible) would render them to the witness.
	imposterWitnessRange = 48

	// Chase-persistence window: once we've latched onto a target color,
	// keep pursuing it for this many frames after we last saw it on
	// screen. Absorbs the 1-2 frame sprite dropouts that cause
	// chase→fake→chase oscillation.
	imposterChaseStickyFrames = 12
)

// ImposterBrain holds mutable imposter state: which fake task is the
// current cover goal, and a dedicated RNG so two imposter agents in the
// same process don't lockstep on goal picks.
type ImposterBrain struct {
	rng        *rand.Rand
	fakeIdx    int    // current TaskStations index as fake goal, -1 if none
	fakeChosen uint64 // frame we last picked a fake target
	lastKillF  uint64 // frame of last recorded kill attempt (for logging)

	// Chase persistence: after picking a chase target we remember its
	// color and last-seen world coord for imposterChaseStickyFrames,
	// so brief sprite dropouts or a second crewmate drifting through
	// view don't reset the goal to a random fake station.
	chaseColor   uint8
	chaseSeen    Point  // last world coord of the target
	chaseSeenF   uint64 // frame target was last seen; 0 = not chasing
}

// NewImposterBrain seeds a deterministic-per-agent RNG. Caller should
// choose a unique seed per Agent (e.g. memory-address-derived) so multi-
// agent runs don't all pick the same fake target.
func NewImposterBrain(seed int64) *ImposterBrain {
	return &ImposterBrain{
		rng:     rand.New(rand.NewSource(seed)),
		fakeIdx: -1,
	}
}

// stepImposter decides an alive-imposter's next action. Returns
// (mask, handled). When handled is false, the caller falls back to the
// crewmate pipeline (used during initial frames before we can decide).
//
// Priority order (nottoodumb.nim:3170-3220):
//  1. Flee visible body: nav to the fake task farthest from the body.
//  2. If kill-ready and a single non-self crewmate is visible within
//     kill range, press ButtonA. Else nav toward them.
//  3. Otherwise pick a fake station and nav there to camouflage.
func (a *Agent) stepImposter(pixels []uint8, cam Camera, player Point) (uint8, bool) {
	if a.imposter == nil {
		a.imposter = NewImposterBrain(int64(a.frames) ^ int64(uintptrOfAgent(a)))
	}
	brain := a.imposter

	// 1. Body in view: flee. Pick the farthest station from the body as
	// our new goal. Never press A on a body as imposter (self-report).
	bodies := FindBodies(pixels)
	if len(bodies) > 0 {
		body := BodyWorld(bodies[0], cam)
		// Pick farthest TaskStation from the body.
		bestIdx := -1
		bestDist := -1
		for i, ts := range TaskStations {
			d := manhattan(ts.Center, body)
			if d > bestDist {
				bestDist, bestIdx = d, i
			}
		}
		if bestIdx >= 0 {
			goal := TaskStations[bestIdx].Center
			if a.nav.Goal() != goal {
				if a.nav.SetGoal(goal) {
					brain.fakeIdx = bestIdx
					brain.fakeChosen = a.frames
					a.radarGoal = false
					a.bodyGoal = false
					log.Printf("imposter: flee body %v to %s @ %v (frame %d)",
						body, TaskStations[bestIdx].Name, goal, a.frames)
				}
			}
			a.logBranch("imp-flee")
			navMask, _ := a.nav.Next(player)
			if navMask == Unreachable {
				a.nav.Clear()
				return 0, true
			}
			return navMask, true
		}
	}

	// 2. Kill / chase branch (requires killReady).
	//
	// The plan (how_to_make_a_bot.md:371-383) reads:
	//   - If exactly one non-imposter is visible and kill is ready, move
	//     toward them and press A in kill range.
	//   - Never kill when two or more possible witnesses are visible.
	//
	// Our stricter reading: a "witness" is another live crewmate whose
	// sprite is on screen *and* close to the kill target. A second
	// crewmate at the far edge of the viewport can't realistically see
	// a kill if it happens on the other side of the screen, so we don't
	// need to wait for them to leave. We also persist the chase target
	// across brief sprite dropouts to avoid chase→fake oscillation.
	if a.status.KillReady() {
		mates := FindCrewmates(pixels)
		if target, ok := pickKillCandidate(mates, cam, player, brain); ok {
			tgt := CrewmateWorld(target, cam)
			dx := tgt.X - player.X
			dy := tgt.Y - player.Y
			distSq := dx*dx + dy*dy
			brain.chaseColor = target.Color
			brain.chaseSeen = tgt
			brain.chaseSeenF = a.frames
			if distSq <= imposterKillRangeSq {
				if a.frames-brain.lastKillF > 4 {
					log.Printf("imposter: kill color=%d at %v (player %v, dist²=%d)",
						target.Color, tgt, player, distSq)
					brain.lastKillF = a.frames
				}
				// Drop the victim from suspect memory so vote-phase
				// Pick() returns an *alive* crewmate color we've seen
				// recently. Dead slots are excluded by findColor, so
				// without this the imposter's vote would fall to SKIP
				// after most kills (since the freshly-killed color was
				// always the most recent sighting).
				a.suspect.Forget(target.Color)
				a.nav.Clear()
				a.logBranch("imp-kill")
				return ButtonA, true
			}
			if a.nav.Goal() != tgt {
				a.nav.SetGoal(tgt)
				a.radarGoal = false
				a.bodyGoal = false
				log.Printf("imposter: chase color=%d to %v (player %v, dist²=%d)",
					target.Color, tgt, player, distSq)
			}
			a.logBranch("imp-chase")
			navMask, _ := a.nav.Next(player)
			if navMask == Unreachable {
				a.nav.Clear()
				return 0, true
			}
			return navMask, true
		}
		// Sticky chase: we picked a target recently but lost sight this
		// frame. Keep nav'ing to the last known coord for a few frames
		// before reverting to fake-task. This avoids reseeding the fake
		// target every time a witness briefly drifts through view.
		if brain.chaseSeenF != 0 && a.frames-brain.chaseSeenF <= imposterChaseStickyFrames {
			if a.nav.Goal() != brain.chaseSeen {
				a.nav.SetGoal(brain.chaseSeen)
				a.radarGoal = false
				a.bodyGoal = false
			}
			a.logBranch("imp-chase")
			navMask, _ := a.nav.Next(player)
			if navMask != Unreachable {
				return navMask, true
			}
			a.nav.Clear()
			brain.chaseSeenF = 0
		}
	} else {
		// On cooldown — discard stale chase state so we don't resume
		// chasing the moment killReady latches back on, which would be
		// pointed at wherever that color was seconds earlier.
		brain.chaseSeenF = 0
	}

	// 3. Fake task camouflage. Pick a station if we don't have one or if
	// enough time has passed without progress.
	if brain.fakeIdx < 0 || brain.fakeIdx >= len(TaskStations) ||
		a.frames-brain.fakeChosen > imposterFakeRotateFrames {
		brain.fakeIdx = brain.rng.Intn(len(TaskStations))
		brain.fakeChosen = a.frames
		goal := TaskStations[brain.fakeIdx].Center
		a.nav.SetGoal(goal)
		a.radarGoal = false
		a.bodyGoal = false
		log.Printf("imposter: fake target %s @ %v (frame %d)",
			TaskStations[brain.fakeIdx].Name, goal, a.frames)
	}
	if !a.nav.HasGoal() {
		goal := TaskStations[brain.fakeIdx].Center
		a.nav.SetGoal(goal)
	}
	// If we've arrived at the fake target, cycle to the next one.
	navMask, arrived := a.nav.Next(player)
	if navMask == Unreachable {
		a.nav.Clear()
		brain.fakeIdx = -1
		return 0, true
	}
	if arrived {
		brain.fakeIdx = brain.rng.Intn(len(TaskStations))
		brain.fakeChosen = a.frames
		a.nav.SetGoal(TaskStations[brain.fakeIdx].Center)
		log.Printf("imposter: reached fake target; next=%s (frame %d)",
			TaskStations[brain.fakeIdx].Name, a.frames)
	}
	a.logBranch("imp-fake")
	return navMask, true
}

// pickKillCandidate chooses the best crewmate from mates for a kill or
// kill-chase. A candidate qualifies if no *other* crewmate in mates is
// within imposterWitnessRange (Manhattan) of it. Among qualifying
// candidates we prefer the closest to the player so the chase/kill path
// is shortest. If a previously-latched chase color is still a qualifying
// candidate, pick it (keeps pursuit on the same victim across frames).
// Returns (match, true) on success, zero match + false when nothing is
// safely killable this frame.
func pickKillCandidate(mates []CrewmateMatch, cam Camera, player Point, brain *ImposterBrain) (CrewmateMatch, bool) {
	if len(mates) == 0 {
		return CrewmateMatch{}, false
	}
	// Resolve world positions once.
	worlds := make([]Point, len(mates))
	for i, m := range mates {
		worlds[i] = CrewmateWorld(m, cam)
	}
	// For each mate, count how many *other* mates are within witness range.
	safe := make([]bool, len(mates))
	for i := range mates {
		safe[i] = true
		for j := range mates {
			if i == j {
				continue
			}
			if manhattan(worlds[i], worlds[j]) <= imposterWitnessRange {
				safe[i] = false
				break
			}
		}
	}
	// Prefer the latched chase color if still safe.
	if brain.chaseSeenF != 0 {
		for i, m := range mates {
			if safe[i] && m.Color == brain.chaseColor {
				return m, true
			}
		}
	}
	// Otherwise pick the closest safe candidate to the player.
	bestI := -1
	bestD := -1
	for i := range mates {
		if !safe[i] {
			continue
		}
		d := manhattan(worlds[i], player)
		if bestI < 0 || d < bestD {
			bestI, bestD = i, d
		}
	}
	if bestI < 0 {
		return CrewmateMatch{}, false
	}
	return mates[bestI], true
}

// uintptrOfAgent returns a process-unique non-zero value per Agent so
// multi-agent processes diverge on fake-target RNG seeds. Done via the
// Agent pointer (nil-guarded by the caller, which always has a receiver).
func uintptrOfAgent(a *Agent) uintptr {
	return uintptrFrom(a)
}

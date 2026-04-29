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
)

// ImposterBrain holds mutable imposter state: which fake task is the
// current cover goal, and a dedicated RNG so two imposter agents in the
// same process don't lockstep on goal picks.
type ImposterBrain struct {
	rng        *rand.Rand
	fakeIdx    int    // current TaskStations index as fake goal, -1 if none
	fakeChosen uint64 // frame we last picked a fake target
	lastKillF  uint64 // frame of last recorded kill attempt (for logging)
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

	// 2. Lone-crewmate kill check. Must be: kill-ready, exactly one
	// non-self crewmate visible.
	if a.status.KillReady() {
		mates := FindCrewmates(pixels)
		if len(mates) == 1 {
			tgt := CrewmateWorld(mates[0], cam)
			dx := tgt.X - player.X
			dy := tgt.Y - player.Y
			distSq := dx*dx + dy*dy
			if distSq <= imposterKillRangeSq {
				if a.frames-brain.lastKillF > 4 {
					log.Printf("imposter: kill color=%d at %v (player %v, dist²=%d)",
						mates[0].Color, tgt, player, distSq)
					brain.lastKillF = a.frames
				}
				a.nav.Clear()
				a.logBranch("imp-kill")
				return ButtonA, true
			}
			// Chase.
			if a.nav.Goal() != tgt {
				a.nav.SetGoal(tgt)
				a.radarGoal = false
				a.bodyGoal = false
				log.Printf("imposter: chase color=%d to %v (player %v, dist²=%d)",
					mates[0].Color, tgt, player, distSq)
			}
			a.logBranch("imp-chase")
			navMask, _ := a.nav.Next(player)
			if navMask == Unreachable {
				a.nav.Clear()
				return 0, true
			}
			return navMask, true
		}
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

// uintptrOfAgent returns a process-unique non-zero value per Agent so
// multi-agent processes diverge on fake-target RNG seeds. Done via the
// Agent pointer (nil-guarded by the caller, which always has a receiver).
func uintptrOfAgent(a *Agent) uintptr {
	return uintptrFrom(a)
}

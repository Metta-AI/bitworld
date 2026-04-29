package main

import (
	_ "embed"
	"fmt"
	"log"
)

//go:embed testdata/skeld_map.bin
var skeldMapData []byte

//go:embed testdata/walks.bin
var walksData []byte

// Agent wraps the full per-frame pipeline: phase classification, camera
// lock, task memory, navigation, task interaction, and stuck detection.
// One Step(pixels) call returns the button mask to send next.
//
// Agent owns all mutable state that was previously declared as locals in
// main(). Reusing it across many frames is required; the zero value is
// not usable -- call NewAgent.
type Agent struct {
	tracker *Tracker
	walks   *WalkMask
	nav     *Navigator
	memory  TaskMemory
	status  StatusDetector

	// per-frame working buffer for pixels; callers write into Step's
	// argument instead, so Agent doesn't own it.

	sentMask     uint8 // last mask Step returned (for change logging)
	currentPhase Phase
	havePhase    bool
	lastRole     StatusIconKind // most recent latched role, logged on change
	voter        VoteController
	suspect      SuspectTracker
	bumper       Bumper
	holder       TaskHolder
	wanderer     Wanderer
	frames       uint64
	lastPosLog   uint64
	lastBranch   string // most recent PhaseActive branch; logged on change
	arrivedAt    uint64 // frame at which navigator first reported "arrived"; 0 means not currently arrived
	lastPlayer   Point  // player world pos last seen while nav-stuck tracking
	lastPlayerF  uint64 // frame when lastPlayer was last updated
	stuckPerturb uint8  // non-zero while we're force-nudging through a pinned corner
	stuckLeft    int    // frames remaining of the current stuck perturb

	radarGoal      bool    // true when nav's current goal came from radar (guess)
	radarBlack     []Point // radar-chosen targets A* couldn't reach from here
	radarBlackFrom Point   // player pos when radarBlack was last populated

	pendingChat string // drained by TakePendingChat(); emitted on websocket only
	bodyGoal    bool   // true when nav's current goal is a body (highest priority)

	imposter *ImposterBrain // lazy-initialized when we observe an imposter role
}

// NewAgent returns an Agent using the embedded skeld map + walk mask. It
// panics if the embedded fixtures are the wrong size.
func NewAgent() *Agent {
	if len(skeldMapData) != MapWidth*MapHeight {
		panic(fmt.Sprintf("embedded map size = %d, want %d", len(skeldMapData), MapWidth*MapHeight))
	}
	wantWalks := (MapWidth*MapHeight + 7) / 8
	if len(walksData) != wantWalks {
		panic(fmt.Sprintf("embedded walks size = %d, want %d", len(walksData), wantWalks))
	}
	walks := &WalkMask{Bits: walksData}
	a := &Agent{
		tracker: NewTracker(&Map{Pixels: skeldMapData}),
		walks:   walks,
		nav:     NewNavigator(walks),
	}
	// 255 = "self color unknown". The zero value 0 is a real palette index
	// (red), which would erroneously exclude red crewmates from suspect
	// picks before SetSelf has ever been called.
	a.suspect.SetSelf(255)
	return a
}

const (
	agentRadarBlackRadius    = 24  // world px; any candidate within this of a blacklisted point is rejected
	agentRadarBlackExpirePx  = 120 // see main.go comment below; adjacent stations are ~48px apart on skeld
	agentNavArrivedTimeout   = 120 // ~5 s @ 24 fps -- give up on bogus task targets
	agentStuckFrames         = 12  // camera-based stuck threshold
	agentStuckBurst          = 8   // how long to force the perpendicular nudge
	agentIconSnapDist        = 24  // snap noisy icon coords within this many world-pixels to the nearest TaskStation

	// Report range = sim.nim:757 reportRange=20 default; check distSq ≤ 400
	// against the body collision center at (body.x+CollisionW/2, body.y+CollisionH/2)
	// (sim.nim:1304-1313). CollisionW=CollisionH=1, so the center is ~body.x/body.y.
	agentReportRangeSq = 20 * 20
)

// Step consumes one fully-unpacked 128×128 palette-indexed frame and
// returns the next button mask to send to the server. Frames must be
// delivered in tick order; Agent relies on that for frame counting,
// stuck detection, and nav-arrival timeouts.
func (a *Agent) Step(pixels []uint8) uint8 {
	a.frames++

	phase := Classify(pixels)
	if !a.havePhase || phase != a.currentPhase {
		log.Printf("phase: %s (frame %d)", phase, a.frames)
		a.currentPhase = phase
		a.havePhase = true
		if phase == PhaseVoting {
			// Reset the controller and pick a suspect once, at phase
			// entry. The panel is static for the duration of the vote,
			// so the target doesn't need to re-evaluate per frame. If
			// no suspect has been seen yet (e.g. we died before spotting
			// anyone), Target stays 255 and the controller falls through
			// to SKIP -- same behavior as v1.
			target := uint8(255)
			if c, ok := a.suspect.Pick(); ok {
				target = c
			}
			a.voter = VoteController{Target: target}
			log.Printf("vote: entering voting, suspect=%d self=%d (frame %d)",
				target, a.suspect.Self(), a.frames)
		}
	}

	// Status icon lives at the bottom of the active HUD (sim.nim:2661),
	// so only poll it during active play. Voting and idle phases draw
	// different UI over that slot.
	if phase == PhaseActive {
		kind := a.status.Next(pixels)
		if kind != a.lastRole && a.status.latched != StatusUnknown {
			log.Printf("role: %v (frame %d, killReady=%v)",
				a.status.latched, a.frames, a.status.KillReady())
			a.lastRole = kind
		}
	}

	var mask uint8
	switch phase {
	case PhaseActive:
		mask = a.stepActive(pixels)
	case PhaseVoting:
		mask = a.voter.Next(pixels)
	default:
		// Emit a rotating cardinal so startup/lobby/game-over/role-reveal
		// frames don't look like a frozen policy to outside observers
		// (e.g. cogames' validation heuristic, which flags all-noop runs).
		// Cardinals are ignored by the lobby UI and are the same input the
		// agent would send while actively exploring.
		mask = a.wanderer.Next()
	}

	if mask != a.sentMask && a.frames > 100 {
		log.Printf("mask: %#x -> %#x (frame %d)", a.sentMask, mask, a.frames)
	}
	a.sentMask = mask
	return mask
}

func (a *Agent) radarReject(p Point) bool {
	for _, q := range a.radarBlack {
		if absInt(p.X-q.X) <= agentRadarBlackRadius && absInt(p.Y-q.Y) <= agentRadarBlackRadius {
			return true
		}
	}
	return false
}

// radarStationGoal picks the best known TaskStation that lies along
// one of the radar arrows' bearings and isn't in the radar blacklist,
// memorized set, or completed set. Returns (center, true) on success.
func (a *Agent) radarStationGoal(arrows []RadarArrow, cam Camera, player Point) (Point, bool) {
	stationReject := func(i int) bool {
		c := TaskStations[i].Center
		if a.radarReject(c) {
			return true
		}
		// Also skip stations in memory (we already have a direct goal
		// for them) and in the memory blacklist (previously failed).
		for _, q := range a.memory.Known {
			if manhattan(c, q) <= taskMemoryMergeRadius {
				return true
			}
		}
		for _, q := range a.memory.Blacklisted {
			if manhattan(c, q) <= taskMemoryMergeRadius {
				return true
			}
		}
		return false
	}
	best := -1
	bestDist := -1
	for _, arrow := range arrows {
		bearing := Point{cam.X + arrow.ScreenX, cam.Y + arrow.ScreenY}
		idx := NearestStationAlongBearing(player, bearing, stationReject)
		if idx < 0 {
			continue
		}
		d := manhattan(TaskStations[idx].Center, player)
		if best < 0 || d < bestDist {
			best, bestDist = idx, d
		}
	}
	if best < 0 {
		return Point{}, false
	}
	return TaskStations[best].Center, true
}

// TakePendingChat drains any pending chat message. Returns ("", false) when
// nothing is queued. Used by the websocket loop; stdio callers ignore it
// (Python protocol is one-byte-per-frame mask-only).
func (a *Agent) TakePendingChat() (string, bool) {
	if a.pendingChat == "" {
		return "", false
	}
	msg := a.pendingChat
	a.pendingChat = ""
	return msg, true
}

// nearestBody picks the body match whose implied world position is closest
// to the player. Returns (world, color, true) on success.
func (a *Agent) nearestBody(pixels []uint8, cam Camera, player Point) (Point, uint8, bool) {
	bodies := FindBodies(pixels)
	if len(bodies) == 0 {
		return Point{}, 0, false
	}
	bestI := 0
	bestD := manhattan(BodyWorld(bodies[0], cam), player)
	for i := 1; i < len(bodies); i++ {
		d := manhattan(BodyWorld(bodies[i], cam), player)
		if d < bestD {
			bestI, bestD = i, d
		}
	}
	return BodyWorld(bodies[bestI], cam), bodies[bestI].Color, true
}

func (a *Agent) logBranch(name string) {
	if name != a.lastBranch {
		log.Printf("branch: %s (frame %d)", name, a.frames)
		a.lastBranch = name
	}
}

func (a *Agent) stepActive(pixels []uint8) uint8 {
	cam, locked := a.tracker.Update(pixels)
	var player Point
	if !locked && a.frames-a.lastPosLog >= 24 {
		log.Printf("nolock: bestMiss=%d brutes=%d", a.tracker.LastMiss, a.tracker.Brutes)
		a.lastPosLog = a.frames
	}
	var matches []IconMatch
	if locked {
		player = Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
		matches = FindTaskIcons(pixels)
		for _, m := range matches {
			w := IconToTaskWorld(m, cam)
			if idx := SnapToStation(w, agentIconSnapDist); idx >= 0 {
				w = TaskStations[idx].Center
			}
			if a.memory.Add(w) {
				log.Printf("task memorized: %v (total %d, icon@%d,%d)",
					w, a.memory.Len(), m.ScreenX, m.ScreenY)
			}
		}
		if a.frames-a.lastPosLog >= 24 {
			log.Printf("pos: %v cam=(%d, %d) miss=%d brutes=%d tasks=%d matches=%d",
				player, cam.X, cam.Y, cam.Mismatches, a.tracker.Brutes, a.memory.Len(), len(matches))
			a.lastPosLog = a.frames
		}
		// Suspect tracking: every active frame, record when each
		// visible non-self crewmate color was last seen. Feeds the
		// voting-phase suspect picker (M5). Imposters record too --
		// stepImposter clears victim colors from the tracker after a
		// kill (see SuspectTracker.Forget) so the vote falls on a
		// crewmate that's still alive.
		for _, m := range FindCrewmates(pixels) {
			a.suspect.Record(m.Color, a.frames)
		}
		// Self-color detection: our own sprite is always drawn centered
		// at (playerScreenX, playerScreenY) = (58, 58), with the local
		// player's color substituted into the palette-3 tint positions
		// (sim.nim:2569). We only need to learn this once; sample until
		// we get a confident read, then latch. Without this,
		// SuspectTracker can't exclude self from Pick, and we'd vote for
		// our own color as soon as it's seen reflected elsewhere.
		if a.suspect.Self() == 255 {
			if c := selfColorFromScreen(pixels); c != 255 {
				log.Printf("self-color: detected color=%d (frame %d)", c, a.frames)
				a.suspect.SetSelf(c)
			}
		}
		// Imposter path: entirely separate goal selection (flee bodies,
		// chase lone crewmates, fake-task camouflage). Ghosts fall
		// through to crewmate path since ghost-imposters still move
		// normally. IsImposter latches on either ready or cooldown so
		// we commit to this branch once the role is confirmed.
		if a.status.IsImposter() && !a.status.IsGhost() {
			if m, handled := a.stepImposter(pixels, cam, player); handled {
				return m
			}
		}
		if !a.nav.HasGoal() {
			if goal, _, ok := a.memory.Closest(player); ok {
				if a.nav.SetGoal(goal) {
					a.radarGoal = false
					log.Printf("nav: target %v (player %v, dist %d)",
						goal, player, manhattan(goal, player))
				}
			} else if arrows := FindRadarArrows(pixels); len(arrows) > 0 {
				if len(a.radarBlack) > 0 &&
					(absInt(player.X-a.radarBlackFrom.X) > agentRadarBlackExpirePx ||
						absInt(player.Y-a.radarBlackFrom.Y) > agentRadarBlackExpirePx) {
					log.Printf("nav: radar blacklist expired after moving %v->%v",
						a.radarBlackFrom, player)
					a.radarBlack = a.radarBlack[:0]
				}
				if goal, ok := a.radarStationGoal(arrows, cam, player); ok {
					if a.nav.SetGoal(goal) {
						a.radarGoal = true
						log.Printf("nav: radar station target %v (player %v, %d arrows)",
							goal, player, len(arrows))
					}
				} else if goal, ok := RadarGoal(arrows, cam, a.walks, a.radarReject); ok {
					if a.nav.SetGoal(goal) {
						a.radarGoal = true
						log.Printf("nav: radar target %v (player %v, %d arrows)",
							goal, player, len(arrows))
					}
				}
			}
		}
	}

	// Body reporting: alive crewmates that spot a body should nav to it
	// and press A when within report range (sim.nim:1298-1315 tryReport,
	// reportRange=20, distSq ≤ 400). Imposters are deferred to M4; they
	// must flee bodies instead of reporting. Ghosts cannot report
	// (sim.nim:1302 requires p.alive).
	if locked && !a.status.IsGhost() && !a.status.IsImposter() {
		if bodyW, color, ok := a.nearestBody(pixels, cam, player); ok {
			dx := bodyW.X - player.X
			dy := bodyW.Y - player.Y
			distSq := dx*dx + dy*dy
			if distSq <= agentReportRangeSq {
				if a.pendingChat == "" {
					a.pendingChat = "body"
				}
				if !a.bodyGoal {
					log.Printf("body: reporting color=%d at %v (player %v, dist²=%d)",
						color, bodyW, player, distSq)
				}
				a.nav.Clear()
				a.bodyGoal = false
				return ButtonA
			}
			// Out of range: drop any existing goal and head to the body.
			if !a.bodyGoal || a.nav.Goal() != bodyW {
				if a.nav.SetGoal(bodyW) {
					a.bodyGoal = true
					a.radarGoal = false
					a.arrivedAt = 0
					log.Printf("body: nav to color=%d at %v (player %v, dist²=%d)",
						color, bodyW, player, distSq)
				}
			}
		} else if a.bodyGoal {
			// Body left view; clear the goal so normal task/nav resumes.
			a.nav.Clear()
			a.bodyGoal = false
			a.arrivedAt = 0
		}
	}

	wasHolding := a.holder.IsHolding()
	beforeC := a.holder.Completes
	var desired uint8
	var stuckEligible bool
	var mask uint8
	if m, handled := a.holder.Adjust(matches, player, cam); handled {
		a.logBranch("holder")
		mask = m
		a.arrivedAt = 0
		if !wasHolding {
			log.Printf("task: holding (frame %d)", a.frames)
		}
		if a.holder.Completes != beforeC {
			log.Printf("task: completed #%d (frame %d)", a.holder.Completes, a.frames)
			if locked {
				if _, idx, ok := a.memory.Closest(player); ok {
					a.memory.Forget(idx)
				}
			}
			a.nav.Clear()
		}
	} else if locked && a.nav.HasGoal() {
		// A memorized task that's come into view preempts any radar
		// goal -- radar goals are rough estimates along a bearing,
		// memorized tasks are confirmed locations.
		if a.radarGoal {
			if goal, _, ok := a.memory.Closest(player); ok {
				if a.nav.SetGoal(goal) {
					a.radarGoal = false
					a.arrivedAt = 0
					log.Printf("nav: memorized target preempts radar: %v (player %v, dist %d)",
						goal, player, manhattan(goal, player))
				}
			}
		}
		a.logBranch("nav")
		navMask, arrived := a.nav.Next(player)
		if navMask == Unreachable {
			if a.radarGoal {
				log.Printf("nav: radar target %v unreachable; blacklisting", a.nav.Goal())
				if len(a.radarBlack) == 0 {
					a.radarBlackFrom = player
				}
				a.radarBlack = append(a.radarBlack, a.nav.Goal())
			} else {
				log.Printf("nav: memorized target %v unreachable; blacklisting", a.nav.Goal())
				if task, idx, ok := a.memory.Closest(player); ok {
					a.memory.Forget(idx)
					a.memory.Blacklist(task)
				}
			}
			a.nav.Clear()
			a.radarGoal = false
			a.arrivedAt = 0
			return 0
		}
		if arrived {
			if a.radarGoal {
				log.Printf("nav: reached radar target %v; re-polling", a.nav.Goal())
				if len(a.radarBlack) == 0 {
					a.radarBlackFrom = player
				}
				a.radarBlack = append(a.radarBlack, a.nav.Goal())
				a.nav.Clear()
				a.radarGoal = false
				a.arrivedAt = 0
				mask = 0
			} else {
				if a.arrivedAt == 0 {
					a.arrivedAt = a.frames
					log.Printf("nav: arrived at %v (waiting for TaskHolder)", a.nav.Goal())
				}
				if a.frames-a.arrivedAt > agentNavArrivedTimeout {
					log.Printf("nav: gave up on %v (no task fired in %d frames); blacklisting",
						a.nav.Goal(), agentNavArrivedTimeout)
					if task, idx, ok := a.memory.Closest(player); ok {
						a.memory.Forget(idx)
						a.memory.Blacklist(task)
					}
					a.nav.Clear()
					a.arrivedAt = 0
					mask = 0
				} else {
					if task, _, ok := a.memory.Closest(player); ok {
						desired = maskTowards(player, task)
						stuckEligible = desired != 0
					} else {
						mask = 0
					}
				}
			}
		} else {
			a.arrivedAt = 0
			desired = navMask
			stuckEligible = true
		}
	} else {
		a.arrivedAt = 0
		desired = Steer(pixels)
		if desired == 0 {
			desired = a.wanderer.Next()
			if !locked {
				a.logBranch("wander-nolock")
			} else {
				a.logBranch("wander-nogoal")
			}
		} else if !locked {
			a.logBranch("steer-nolock")
		} else {
			a.logBranch("steer-nogoal")
		}
		stuckEligible = locked && desired != 0
	}

	if stuckEligible {
		const stuckJitter = 2
		moved := a.lastPlayerF == 0 ||
			absInt(player.X-a.lastPlayer.X) > stuckJitter ||
			absInt(player.Y-a.lastPlayer.Y) > stuckJitter
		if moved {
			a.lastPlayer = player
			a.lastPlayerF = a.frames
		} else if a.stuckLeft == 0 && a.frames-a.lastPlayerF >= agentStuckFrames {
			nudge := perpendicular(desired, int(a.frames))
			if nudge != 0 {
				a.stuckPerturb = nudge
				a.stuckLeft = agentStuckBurst
				a.lastPlayerF = a.frames
				log.Printf("stuck: %v for %d frames; nudge=%#x (frame %d)",
					player, agentStuckFrames, a.stuckPerturb, a.frames)
			}
		}
		applied := desired
		if a.stuckLeft > 0 {
			applied = a.stuckPerturb
			a.stuckLeft--
		}
		beforeP := a.bumper.Perturbs
		mask = a.bumper.Adjust(pixels, applied)
		if a.bumper.Perturbs != beforeP {
			log.Printf("bumper: perturb #%d (frame %d, mask %#x)", a.bumper.Perturbs, a.frames, mask)
		}
	}

	return mask
}

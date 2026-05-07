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
	memory  *TaskMemory
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
	arrivedAt       uint64 // frame at which navigator first reported "arrived"; 0 means not currently arrived
	arrivedLoggedAt Point  // last goal we emitted an "arrived at" log for; used to debounce against holder flicker

	// After A* reports Unreachable we back off from station-nav for a few
	// frames so we don't churn through every station's state. The suspend
	// lifts when the player moves meaningfully or the counter expires.
	navSuspendLeft  int
	navSuspendPos   Point
	lastPlayer   Point  // player world pos last seen while nav-stuck tracking
	lastPlayerF  uint64 // frame when lastPlayer was last updated
	stuckPerturb uint8  // non-zero while we're force-nudging through a pinned corner
	stuckLeft    int    // frames remaining of the current stuck perturb

	// prevPlayer/prevPlayerF measure per-frame player displacement for the
	// coast-to-stop logic. Unlike lastPlayer (which gates stuck detection
	// and only updates on >2 px movement), this updates every locked
	// frame so |Δplayer| is a proper speed estimate.
	prevPlayer  Point
	prevPlayerF uint64

	// goalStation is the TaskStations index of the current nav goal when
	// it came from TaskMemory.BestGoal. -1 means the current goal is not a
	// task station (body, imposter target, etc.) or there's no goal.
	goalStation int

	pendingChat string // drained by TakePendingChat(); emitted on websocket only
	bodyGoal    bool   // true when nav's current goal is a body (highest priority)

	imposter *ImposterBrain // lazy-initialized when we observe an imposter role

	// aliveOthers is the number of alive non-self players as of the
	// last readable voting panel. -1 = unknown (pre-first-vote).
	// Imposter endgame detection reads this minus our kills-this-round.
	aliveOthers int

	// idleStreak counts consecutive PhaseIdle frames. Once it exceeds
	// agentIdleResetFrames we treat it as a real game boundary (lobby,
	// game-over, or role-reveal screen) and reset latched role state,
	// which would otherwise stick across games and run stepImposter
	// when the server has reassigned us as a crewmate in a new round.
	idleStreak    uint32
	didIdleReset  bool
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
		tracker:     NewTracker(&Map{Pixels: skeldMapData}),
		walks:       walks,
		nav:         NewNavigator(walks),
		memory:      NewTaskMemory(),
		goalStation: -1,
	}
	// 255 = "self color unknown". The zero value 0 is a real palette index
	// (red), which would erroneously exclude red crewmates from suspect
	// picks before SetSelf has ever been called.
	a.suspect.SetSelf(255)
	a.aliveOthers = -1
	return a
}

const (
	agentNavArrivedTimeout = 120 // ~5 s @ 24 fps -- give up on bogus task targets
	agentStuckFrames       = 12  // camera-based stuck threshold
	agentStuckBurst        = 8   // how long to force the perpendicular nudge
	agentIconSnapDist      = 24  // snap noisy icon coords within this many world-pixels to the nearest TaskStation

	// After A* reports Unreachable we suspend station goal selection for
	// this many frames, or until the player moves agentNavSuspendClearPx
	// or more world-pixels away from where the failure occurred. Without
	// this, a stuck player at a non-walkable cell churns BestGoal every
	// frame and demotes every station in turn.
	agentNavSuspendFrames  = 24
	agentNavSuspendClearPx = 16

	// Report range = sim.nim:757 reportRange=20 default; check distSq ≤ 400
	// against the body collision center at (body.x+CollisionW/2, body.y+CollisionH/2)
	// (sim.nim:1304-1313). CollisionW=CollisionH=1, so the center is ~body.x/body.y.
	agentReportRangeSq = 20 * 20

	// Coast-to-stop near a goal. Players have momentum (sim.nim:26-30:
	// Accel=76, FrictionNum=144/256, MaxSpeed=704, StopThreshold=8 on a
	// carryX/velX*MotionScale=256 accumulator). Friction decays velocity
	// ~44% per tick, so from near top speed it takes ~8 ticks and ~22
	// world-px to coast to a stop. Inside agentCoastRadius of the goal,
	// if player speed (|Δplayer|/frame, Manhattan) is ≥ agentCoastSpeed,
	// we emit mask=0 so friction brakes us. This stops orbit-around-goal
	// as well as head-on overshoot -- tangential speed decays just as
	// radial does. Below the threshold, normal steering resumes so we
	// converge from a near-stop onto the station center.
	agentCoastRadius = 12
	agentCoastSpeed  = 3

	// Consecutive PhaseIdle frames that must accumulate before we treat
	// it as a real game boundary and reset role state. A single idle
	// frame can appear from camera-lock dropouts or a blanked frame
	// (see TestAgent_GhostStillPlays), so we want a margin. ~2s at
	// 24fps is long enough to clearly separate from transient
	// mis-classification, short enough that lobby/game-over reliably
	// exceed it.
	agentIdleResetFrames = 48
)

// Step consumes one fully-unpacked 128×128 palette-indexed frame and
// returns the next button mask to send to the server. Frames must be
// delivered in tick order; Agent relies on that for frame counting,
// stuck detection, and nav-arrival timeouts.
func (a *Agent) Step(pixels []uint8) uint8 {
	a.frames++

	phase := Classify(pixels)
	if phase == PhaseIdle {
		a.idleStreak++
	} else {
		a.idleStreak = 0
		a.didIdleReset = false
	}
	// Sustained idle (lobby, game-over, role-reveal) signals a game
	// boundary. Reset latched role state so we don't carry an imposter
	// latch from a prior game into a new one where we've been reassigned
	// as a crewmate. One-shot per idle streak so a long lobby doesn't
	// spam re-clears.
	if phase == PhaseIdle && !a.didIdleReset && a.idleStreak >= agentIdleResetFrames {
		a.didIdleReset = true
		if a.status.latched != StatusUnknown {
			log.Printf("reset: role latched=%v cleared after %d idle frames (frame %d)",
				a.status.latched, a.idleStreak, a.frames)
		}
		a.status.latched = StatusUnknown
		a.status.ghostFrames = 0
		a.status.killReady = false
		a.lastRole = StatusUnknown
		a.imposter = nil
		a.aliveOthers = -1
		a.nav.Clear()
		a.bodyGoal = false
		a.goalStation = -1
		a.memory.Reset()
	}
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
			// Harvest alive-count from the voting panel. This feeds the
			// imposter endgame rule (kill aggressively when ≤1 crewmate
			// would remain after this kill).
			if layout := parseVoteLayout(pixels); layout != nil {
				n := 0
				for i := 0; i < layout.n; i++ {
					if layout.slotCells[i].alive {
						n++
					}
				}
				// Minus 1 for ourselves. layout doesn't mark self, but
				// self is always an alive slot during voting.
				if n > 0 {
					a.aliveOthers = n - 1
				}
			}
			// Reset the imposter's kill counter: it's tracked per round
			// (between votes) for aliveOthers bookkeeping.
			if a.imposter != nil {
				a.imposter.killsThisRound = 0
			}
			log.Printf("vote: entering voting, suspect=%d self=%d alive_others=%d (frame %d)",
				target, a.suspect.Self(), a.aliveOthers, a.frames)
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

func (a *Agent) countKnown() int {
	n := 0
	for i := range TaskStations {
		if a.memory.State(i) == TaskKnown {
			n++
		}
	}
	return n
}

// shouldCoast returns true when the player is close enough to goal that
// momentum will carry us in and moving fast enough that a steer input
// this frame would overshoot. It's speed-based (not direction-based) so
// an agent orbiting the goal -- tangential velocity, no radial progress
// -- also brakes.
func shouldCoast(player, goal Point, speed int) bool {
	if speed < agentCoastSpeed {
		return false
	}
	return absInt(player.X-goal.X) <= agentCoastRadius &&
		absInt(player.Y-goal.Y) <= agentCoastRadius
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
	var speed int // Manhattan px since previous locked frame; 0 while !locked or first lock
	if !locked && a.frames-a.lastPosLog >= 24 {
		log.Printf("nolock: bestMiss=%d brutes=%d", a.tracker.LastMiss, a.tracker.Brutes)
		a.lastPosLog = a.frames
	}
	var matches []IconMatch
	var arrows []RadarArrow
	if locked {
		player = Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
		if a.prevPlayerF != 0 && a.frames-a.prevPlayerF == 1 {
			speed = absInt(player.X-a.prevPlayer.X) + absInt(player.Y-a.prevPlayer.Y)
		}
		a.prevPlayer = player
		a.prevPlayerF = a.frames
		matches = FindTaskIcons(pixels)
		arrows = FindRadarArrows(pixels)
		a.memory.Update(player, cam, matches, arrows)
		if a.frames-a.lastPosLog >= 24 {
			log.Printf("pos: %v cam=(%d, %d) miss=%d brutes=%d known=%d matches=%d arrows=%d",
				player, cam.X, cam.Y, cam.Mismatches, a.tracker.Brutes,
				a.countKnown(), len(matches), len(arrows))
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
		// Goal selection: pick the best station by (state-priority, distance).
		// Only crewmates chase task stations. Imposters that fall through
		// from stepImposter (e.g. imp-fake-nowhere) should wander via
		// Steer/wanderer rather than picking a task station -- otherwise
		// A* failures from unreachable-from-here spots loop forever,
		// demoting every station in turn.
		// Expire nav-suspend when the player has moved far enough that
		// A* reachability has likely changed (e.g. we wandered off the
		// non-walkable spot).
		if a.navSuspendLeft > 0 {
			if absInt(player.X-a.navSuspendPos.X) >= agentNavSuspendClearPx ||
				absInt(player.Y-a.navSuspendPos.Y) >= agentNavSuspendClearPx {
				a.navSuspendLeft = 0
			} else {
				a.navSuspendLeft--
			}
		}
		if idx := a.memory.BestGoal(player); idx >= 0 && !a.bodyGoal &&
			a.navSuspendLeft == 0 &&
			!(a.status.IsImposter() && !a.status.IsGhost()) {
			c := TaskStations[idx].Center
			if !a.nav.HasGoal() {
				if a.nav.SetGoal(c) {
					a.goalStation = idx
					log.Printf("nav: target %v [station %d, tier %d] (player %v, dist %d)",
						c, idx, a.memory.Priority(idx), player, manhattan(c, player))
				}
			} else if a.goalStation >= 0 &&
				a.memory.Priority(idx) < a.memory.Priority(a.goalStation) &&
				idx != a.goalStation {
				if a.nav.SetGoal(c) {
					log.Printf("nav: preempt station %d (tier %d) -> %d (tier %d) at %v",
						a.goalStation, a.memory.Priority(a.goalStation),
						idx, a.memory.Priority(idx), c)
					a.goalStation = idx
					a.arrivedAt = 0
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
					a.goalStation = -1
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
			if a.goalStation >= 0 {
				a.memory.Mark(a.goalStation, TaskSeenNo)
			}
			a.nav.Clear()
			a.goalStation = -1
		}
	} else if locked && a.nav.HasGoal() {
		a.logBranch("nav")
		var navMask uint8
		var arrived bool
		if a.status.IsGhost() {
			// Ghosts pass through walls (sim.nim:1334 containGhost only
			// clamps to the map rect). A* paths thread through walled
			// corridors and create zigzags that cancel vertical travel,
			// leaving a ghost drifting slowly off-axis. Steer straight at
			// the goal instead.
			goal := a.nav.Goal()
			if manhattan(player, goal) <= navArrivedRadius {
				arrived = true
			} else {
				navMask = maskTowards(player, goal)
			}
		} else {
			navMask, arrived = a.nav.Next(player)
		}
		if navMask == Unreachable {
			if a.goalStation >= 0 {
				log.Printf("nav: station %d at %v unreachable; demoting to seen_no",
					a.goalStation, a.nav.Goal())
				a.memory.Mark(a.goalStation, TaskSeenNo)
			} else {
				log.Printf("nav: goal %v unreachable", a.nav.Goal())
			}
			a.nav.Clear()
			a.goalStation = -1
			a.arrivedAt = 0
			a.navSuspendLeft = agentNavSuspendFrames
			a.navSuspendPos = player
			return 0
		}
		if arrived {
			if a.arrivedAt == 0 {
				a.arrivedAt = a.frames
			}
			if a.arrivedLoggedAt != a.nav.Goal() {
				a.arrivedLoggedAt = a.nav.Goal()
				log.Printf("nav: arrived at %v (waiting for TaskHolder)", a.nav.Goal())
			}
			if a.frames-a.arrivedAt > agentNavArrivedTimeout {
				log.Printf("nav: gave up on %v (no task fired in %d frames); demoting to seen_no",
					a.nav.Goal(), agentNavArrivedTimeout)
				if a.goalStation >= 0 {
					a.memory.Mark(a.goalStation, TaskSeenNo)
				}
				a.nav.Clear()
				a.goalStation = -1
				a.arrivedAt = 0
				mask = 0
			} else if a.goalStation >= 0 {
				// Arrived at the nav cell but TaskHolder hasn't engaged
				// yet; jitter toward the exact station center so a tiny
				// offset doesn't leave us idle. Coast (emit 0) when we're
				// already close and moving fast so momentum settles us
				// instead of overshooting or orbiting.
				center := TaskStations[a.goalStation].Center
				if shouldCoast(player, center, speed) {
					mask = 0
				} else {
					desired = maskTowards(player, center)
					stuckEligible = desired != 0
				}
			} else {
				mask = 0
			}
		} else {
			a.arrivedAt = 0
			if shouldCoast(player, a.nav.Goal(), speed) {
				mask = 0
			} else {
				desired = navMask
				stuckEligible = true
			}
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

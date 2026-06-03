package main

import (
	"log"
	"time"
)

// Agent is the core decision loop that ties together all layers.
type Agent struct {
	world    *World
	nav      *Navigator
	suspect  *SuspectTracker
	wanderer Wanderer
	imposter *ImposterBrain
	voter    *VoteController

	walkMap    *WalkMap
	frames     uint64
	phase      Phase
	sentMask   uint8
	selfColor  string
	isImposter bool
	isGhost    bool
	idleStreak uint32

	lastPlayer  Point
	lastPlayerF uint64
	prevPlayer  Point
	prevPlayerF uint64
	stuckLeft   int
	stuckPerturb uint8

	arrivedAt uint64
	bodyGoal  bool

	pendingChat string
	labelsSeen  map[string]bool
}

// NewAgent creates a new Agent with initialized sub-components.
func NewAgent() *Agent {
	return &Agent{
		world:   NewWorld(),
		suspect: NewSuspectTracker(),
	}
}

// ProcessMessage applies a protocol message to the world and handles special cases.
func (a *Agent) ProcessMessage(msg Message) {
	a.world.Apply(msg)

	// Log sprite labels for diagnostics (first 50 unique labels).
	if ds, ok := msg.(*DefineSprite); ok && ds.Label != "" {
		if a.labelsSeen == nil {
			a.labelsSeen = make(map[string]bool)
		}
		if !a.labelsSeen[ds.Label] && len(a.labelsSeen) < 50 {
			a.labelsSeen[ds.Label] = true
			log.Printf("sprite-label: id=%d %dx%d %q", ds.SpriteID, ds.Width, ds.Height, ds.Label)
		}
	}

	// If DefineSprite with label "walkability map", extract WalkMap and create Navigator.
	if ds, ok := msg.(*DefineSprite); ok {
		if ds.Label == "walkability map" {
			wm := ExtractWalkMap(ds.Pixels, int(ds.Width), int(ds.Height))
			if wm != nil {
				a.walkMap = wm
				a.nav = NewNavigator(wm)
				log.Printf("agent: walkmap extracted %dx%d", wm.Width, wm.Height)
			}
		}
	}
}

// Step is called once per frame after messages are processed.
// Returns the button bitmask to send.
func (a *Agent) Step() uint8 {
	a.frames++

	perc := NewPerception(a.world)
	newPhase := perc.Phase()

	// Detect phase changes
	if newPhase != a.phase {
		log.Printf("agent: phase %d -> %d (frame %d)", a.phase, newPhase, a.frames)

		// On entering voting phase: pick suspect, create vote controller
		if newPhase == PhaseVoting {
			target, ok := a.suspect.Pick()
			if ok {
				log.Printf("agent: voting for %s", target)
				a.voter = NewVoteController(target)
			} else {
				log.Printf("agent: no suspect, will skip vote")
				a.voter = NewVoteController("")
			}
		}

		// Reset nav on phase transition
		if a.nav != nil {
			a.nav.Clear()
		}
		a.bodyGoal = false

		a.phase = newPhase
	}

	// Idle streak
	if newPhase == PhaseIdle {
		a.idleStreak++
	} else {
		a.idleStreak = 0
	}

	// Role detection
	if perc.IsImposter() && !a.isImposter {
		a.isImposter = true
		log.Printf("agent: role detected as IMPOSTER")
		a.imposter = NewImposterBrain(time.Now().UnixNano())
		a.imposter.roleDetectedF = a.frames
	}

	// Dispatch by phase
	var mask uint8
	switch a.phase {
	case PhaseActive:
		mask = a.stepActive(perc)
	case PhaseVoting:
		if a.voter != nil {
			mask = a.voter.Next(perc)
		}
	case PhaseIdle:
		mask = a.wanderer.Next()
	}

	a.sentMask = mask
	return mask
}

// stepActive handles the active game phase.
func (a *Agent) stepActive(perc *Perception) uint8 {
	// Get self position
	player, found := perc.SelfPosition()
	if !found {
		return a.wanderer.Next()
	}

	// Track speed (delta from previous frame)
	a.prevPlayer = a.lastPlayer
	a.prevPlayerF = a.lastPlayerF
	a.lastPlayer = player
	a.lastPlayerF = a.frames

	// Record visible players in suspect tracker
	for _, p := range perc.Players() {
		a.suspect.Record(p.Color, a.frames)
	}

	// Detect self color if unknown
	if a.selfColor == "" {
		color := perc.SelfColor()
		if color != "" {
			a.selfColor = color
			a.suspect.SetSelf(color)
			log.Printf("agent: self color = %s", color)
		}
	}

	// Imposter behavior
	if a.isImposter && a.imposter != nil && a.nav != nil {
		mask, handled := a.imposter.StepImposter(perc, a.nav, player, a.frames, a.selfColor, a.suspect)
		if handled {
			return a.applyStuck(mask, player)
		}
	}

	// Body reporting (crewmate only)
	if !a.isImposter {
		bodies := perc.Bodies()
		if len(bodies) > 0 {
			closest := bodies[0]
			closestDist := manhattan(player, closest.Pos)
			for _, b := range bodies[1:] {
				d := manhattan(player, b.Pos)
				if d < closestDist {
					closest = b
					closestDist = d
				}
			}

			dx := player.X - closest.Pos.X
			dy := player.Y - closest.Pos.Y
			distSq := dx*dx + dy*dy

			if distSq <= 20*20 {
				// Within report range, press A
				a.pendingChat = "body"
				a.bodyGoal = false
				if a.nav != nil {
					a.nav.Clear()
				}
				return ButtonA
			}

			// Navigate to body
			if a.nav != nil {
				if !a.bodyGoal {
					a.nav.SetGoal(closest.Pos)
					a.bodyGoal = true
				}
				mask, arrived := a.nav.Next(player)
				if arrived {
					a.pendingChat = "body"
					a.bodyGoal = false
					a.nav.Clear()
					return ButtonA
				}
				if mask != 0 && mask != Unreachable {
					return a.applyStuck(mask, player)
				}
			}
		}
	}

	// Task navigation
	if !a.bodyGoal && a.nav != nil {
		if !a.nav.HasGoal() {
			// Pick closest visible task
			tasks := perc.Tasks()
			if len(tasks) > 0 {
				closest := tasks[0]
				closestDist := manhattan(player, closest.Pos)
				for _, t := range tasks[1:] {
					d := manhattan(player, t.Pos)
					if d < closestDist {
						closest = t
						closestDist = d
					}
				}
				a.nav.SetGoal(closest.Pos)
				a.arrivedAt = 0
			}
		}

		if a.nav.HasGoal() {
			// Coast-to-stop: if close and moving fast, release buttons
			speed := a.currentSpeed()
			goalDist := manhattan(player, a.nav.Goal())
			if goalDist <= 12 && speed >= 3 {
				return 0
			}

			mask, arrived := a.nav.Next(player)
			if arrived {
				a.arrivedAt = a.frames
				a.nav.Clear()
				return ButtonA
			}
			if mask != 0 && mask != Unreachable {
				return a.applyStuck(mask, player)
			}
			// Unreachable: clear and try something else
			if mask == Unreachable {
				a.nav.Clear()
			}
		}
	}

	// Fallback
	return a.wanderer.Next()
}

// currentSpeed computes approximate speed in pixels/frame from last two positions.
func (a *Agent) currentSpeed() int {
	if a.lastPlayerF == 0 || a.prevPlayerF == 0 || a.lastPlayerF == a.prevPlayerF {
		return 0
	}
	dx := absInt(a.lastPlayer.X - a.prevPlayer.X)
	dy := absInt(a.lastPlayer.Y - a.prevPlayer.Y)
	return dx + dy
}

// applyStuck detects if the player is stuck and applies a perpendicular nudge.
func (a *Agent) applyStuck(mask uint8, player Point) uint8 {
	// If currently perturbing, continue the nudge
	if a.stuckLeft > 0 {
		a.stuckLeft--
		return a.stuckPerturb
	}

	// Check if player hasn't moved > 2px in recent frames
	if a.prevPlayerF > 0 && a.frames-a.prevPlayerF <= 12 {
		dx := absInt(player.X - a.prevPlayer.X)
		dy := absInt(player.Y - a.prevPlayer.Y)
		if dx+dy <= 2 && a.frames > 12 {
			// Stuck: apply perpendicular nudge for 8 frames
			a.stuckPerturb = perpendicular(mask, uint8(a.frames))
			a.stuckLeft = 8
			return a.stuckPerturb
		}
	}

	return mask
}

// perpendicular returns a perpendicular direction to the given movement mask.
func perpendicular(mask uint8, seed uint8) uint8 {
	vertical := mask&(ButtonUp|ButtonDown) != 0
	horizontal := mask&(ButtonLeft|ButtonRight) != 0

	if vertical && !horizontal {
		// Moving vertically, nudge horizontally
		if seed%2 == 0 {
			return ButtonLeft
		}
		return ButtonRight
	}
	if horizontal && !vertical {
		// Moving horizontally, nudge vertically
		if seed%2 == 0 {
			return ButtonUp
		}
		return ButtonDown
	}
	// Diagonal or no movement: pick something
	if seed%2 == 0 {
		return ButtonUp
	}
	return ButtonRight
}

// TakePendingChat drains any pending chat message.
func (a *Agent) TakePendingChat() (string, bool) {
	if a.pendingChat == "" {
		return "", false
	}
	msg := a.pendingChat
	a.pendingChat = ""
	return msg, true
}

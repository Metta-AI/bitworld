package main

import (
	"log"
	"math/rand"
)

const (
	killRangeSq        = 400
	witnessRange       = 48
	chaseStickyFrames  = 12
	postKillVentFrames = 6
	killCooldownTicks  = 1200
	huntingWindow      = 240
)

// CrewSighting records where and when a crew member was last seen.
type CrewSighting struct {
	Pos   Point
	Frame uint64
}

// ImposterBrain handles imposter-specific behavior: hunting, killing, venting.
type ImposterBrain struct {
	rng            *rand.Rand
	lastKillF      uint64
	roleDetectedF  uint64
	killsThisRound int
	chaseColor     string
	chaseSeen      Point
	chaseSeenF     uint64
	lastVentF      uint64
	sightings      map[string]CrewSighting
	huntingLogged  bool
}

// NewImposterBrain creates a new ImposterBrain with the given RNG seed.
func NewImposterBrain(seed int64) *ImposterBrain {
	return &ImposterBrain{
		rng:       rand.New(rand.NewSource(seed)),
		sightings: make(map[string]CrewSighting),
	}
}

// CooldownRemaining returns the number of frames until kill is available.
func (ib *ImposterBrain) CooldownRemaining(frames uint64) uint64 {
	lastRelevant := ib.lastKillF
	if ib.roleDetectedF > lastRelevant {
		lastRelevant = ib.roleDetectedF
	}
	if frames < lastRelevant+killCooldownTicks {
		return lastRelevant + killCooldownTicks - frames
	}
	return 0
}

// IsHunting returns true if the kill cooldown is about to expire (within hunting window).
func (ib *ImposterBrain) IsHunting(frames uint64) bool {
	rem := ib.CooldownRemaining(frames)
	return rem > 0 && rem <= huntingWindow
}

// RecordSighting records a crew member sighting.
func (ib *ImposterBrain) RecordSighting(color string, pos Point, frame uint64) {
	ib.sightings[color] = CrewSighting{Pos: pos, Frame: frame}
}

// StepImposter executes imposter logic and returns (mask, handled).
// If handled is false, the caller should fall through to normal behavior.
func (ib *ImposterBrain) StepImposter(perc *Perception, nav *Navigator, player Point, frames uint64, selfColor string, suspect *SuspectTracker) (uint8, bool) {
	players := perc.Players()
	vents := perc.Vents()

	// Record sightings of other players
	for _, p := range players {
		if p.Color != selfColor && p.Color != "" {
			ib.RecordSighting(p.Color, p.Pos, frames)
		}
	}

	// 1. Post-kill vent: within postKillVentFrames of a kill, find nearest vent
	if ib.lastKillF > 0 && frames-ib.lastKillF <= postKillVentFrames {
		for _, v := range vents {
			dx := player.X - v.Pos.X
			dy := player.Y - v.Pos.Y
			distSq := dx*dx + dy*dy
			if distSq <= 16*16 {
				log.Printf("imposter: venting after kill")
				ib.lastVentF = frames
				return ButtonB, true
			}
		}
	}

	// 2. Flee visible bodies
	bodies := perc.Bodies()
	if len(bodies) > 0 {
		// Find closest body
		closestBody := bodies[0]
		closestDist := manhattan(player, closestBody.Pos)
		for _, b := range bodies[1:] {
			d := manhattan(player, b.Pos)
			if d < closestDist {
				closestBody = b
				closestDist = d
			}
		}
		// Navigate away from it (opposite direction)
		if closestDist < 60 {
			awayX := player.X + (player.X - closestBody.Pos.X)
			awayY := player.Y + (player.Y - closestBody.Pos.Y)
			awayPoint := Point{awayX, awayY}
			if nav != nil {
				nav.SetGoal(awayPoint)
				mask, _ := nav.Next(player)
				if mask != 0 && mask != Unreachable {
					return mask, true
				}
			}
			// Simple flee
			return maskTowards(closestBody.Pos, player), true
		}
	}

	// 3. Kill/chase when kill is ready
	if perc.KillReady() {
		// Find unwitnessed target
		var target *PlayerInfo
		for i := range players {
			p := &players[i]
			if p.Color == selfColor || p.Color == "" {
				continue
			}
			// Check if witnessed: any other player within witnessRange Manhattan of target
			witnessed := false
			for j := range players {
				other := &players[j]
				if other.Color == selfColor || other.Color == p.Color || other.Color == "" {
					continue
				}
				if manhattan(p.Pos, other.Pos) < witnessRange {
					witnessed = true
					break
				}
			}
			if !witnessed {
				target = p
				break
			}
		}

		if target != nil {
			dx := player.X - target.Pos.X
			dy := player.Y - target.Pos.Y
			distSq := dx*dx + dy*dy

			if distSq <= killRangeSq {
				// Kill!
				log.Printf("imposter: killing %s at (%d,%d)", target.Color, target.Pos.X, target.Pos.Y)
				ib.lastKillF = frames
				ib.killsThisRound++
				ib.chaseColor = ""
				suspect.Forget(target.Color)
				return ButtonA, true
			}

			// Chase target
			ib.chaseColor = target.Color
			ib.chaseSeen = target.Pos
			ib.chaseSeenF = frames

			if !ib.huntingLogged {
				log.Printf("imposter: hunting %s", target.Color)
				ib.huntingLogged = true
			}

			if nav != nil {
				nav.SetGoal(target.Pos)
				mask, _ := nav.Next(player)
				if mask != 0 && mask != Unreachable {
					return mask, true
				}
			}
			return maskTowards(player, target.Pos), true
		}

		// Sticky chase: pursue last seen target within chaseStickyFrames
		if ib.chaseColor != "" && frames-ib.chaseSeenF <= chaseStickyFrames {
			if nav != nil {
				nav.SetGoal(ib.chaseSeen)
				mask, _ := nav.Next(player)
				if mask != 0 && mask != Unreachable {
					return mask, true
				}
			}
			return maskTowards(player, ib.chaseSeen), true
		}

		// Reset chase if expired
		if ib.chaseColor != "" && frames-ib.chaseSeenF > chaseStickyFrames {
			ib.chaseColor = ""
			ib.huntingLogged = false
		}
	}

	// Fall through: agent handles wandering/tasks
	return 0, false
}

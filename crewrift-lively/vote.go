package main

import "log"

// VoteController navigates the voting cursor to a target color and presses A.
// Uses edge-triggered input (press/release alternation).
type VoteController struct {
	Target    string
	Voted     bool
	VotedSkip bool
	primed    bool
	pressed   bool
	giveUp    bool
	moves     int
	maxMoves  int
}

// NewVoteController creates a VoteController targeting the given color.
func NewVoteController(target string) *VoteController {
	return &VoteController{
		Target:   target,
		maxMoves: 18,
	}
}

// Next returns the next button mask for the voting phase.
func (vc *VoteController) Next(perc *Perception) uint8 {
	// First call: release all buttons to prime
	if !vc.primed {
		vc.primed = true
		vc.pressed = false
		return 0
	}

	// Edge-triggered: if we pressed last time, release this time
	if vc.pressed {
		vc.pressed = false
		return 0
	}

	// Already voted
	if vc.Voted || vc.VotedSkip {
		return 0
	}

	// Give up or empty target: navigate to skip
	if vc.giveUp || vc.Target == "" {
		if perc.CursorOnSkip() {
			vc.pressed = true
			vc.VotedSkip = true
			log.Printf("vote: skip vote cast")
			return ButtonA
		}
		vc.pressed = true
		vc.moves++
		return ButtonRight
	}

	// Too many moves: give up and skip
	if vc.moves > vc.maxMoves {
		vc.giveUp = true
		vc.pressed = true
		return ButtonRight
	}

	// Cursor is on target player
	if perc.CursorOnPlayer(vc.Target) {
		vc.pressed = true
		vc.Voted = true
		log.Printf("vote: voted for %s", vc.Target)
		return ButtonA
	}

	// Navigate toward target
	vc.pressed = true
	vc.moves++
	return ButtonRight
}

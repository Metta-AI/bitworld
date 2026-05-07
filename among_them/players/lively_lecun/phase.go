package main

type Phase uint8

const (
	PhaseIdle Phase = iota
	PhaseActive
	PhaseVoting
)

func (p Phase) String() string {
	switch p {
	case PhaseIdle:
		return "idle"
	case PhaseActive:
		return "active"
	case PhaseVoting:
		return "voting"
	default:
		return "unknown"
	}
}

// Classify groups the six game phases into three behavior buckets:
//
//	PhaseActive  - Playing. Reactive movement.
//	PhaseVoting  - Voting. Vote-skip behavior.
//	PhaseIdle    - Lobby, RoleReveal, VoteResult, GameOver. No input.
//
// Detection is structural: count pixels in fixed regions and compare
// against thresholds with wide margins from measured fixture data.
// pixels must be ScreenWidth*ScreenHeight long; otherwise returns PhaseIdle.
func Classify(pixels []uint8) Phase {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return PhaseIdle
	}
	if isVoting(pixels) {
		return PhaseVoting
	}
	if isActive(pixels) {
		return PhaseActive
	}
	return PhaseIdle
}

// isVoting looks for the two-row vote-timer bar at the bottom of the screen,
// which is painted entirely in palette indices 1 (dark blue) and 10 (yellow).
// Measured ratio in fixtures: 97% in voting, ≤1% elsewhere.
func isVoting(pixels []uint8) bool {
	const (
		firstRow = ScreenHeight - 2
		lastRow  = ScreenHeight
		thresh   = 80 // percent
	)
	var match, total int
	for y := firstRow; y < lastRow; y++ {
		row := pixels[y*ScreenWidth : (y+1)*ScreenWidth]
		for _, v := range row {
			total++
			if v == 1 || v == 10 {
				match++
			}
		}
	}
	return match*100 >= total*thresh
}

// isActive distinguishes Playing from the other phases via upper-half ink
// volume. Playing fills the screen with map content and shadows; every other
// phase clears to black and adds only sparse UI. Measured upper-half non-zero:
// 8103 for Playing vs ≤363 for everything else — pick a threshold in the gap.
func isActive(pixels []uint8) bool {
	const (
		upperRows = ScreenHeight / 2
		thresh    = 2000
	)
	var nz int
	for _, v := range pixels[:upperRows*ScreenWidth] {
		if v != 0 {
			nz++
		}
	}
	return nz > thresh
}

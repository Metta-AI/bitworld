package main

// SuspectTracker records the most recent frame at which each player color
// was seen by FindCrewmates. Used by the voting-phase controller to pick
// a suspect when no imposter has been positively identified.
//
// Colors are 4-bit palette indices (0..15). lastSeen[c] == 0 means "never
// seen"; callers should treat frame 0 as "never" too (agents always
// increment a.frames before Step calls, so a real sighting is always >0).
type SuspectTracker struct {
	lastSeen [16]uint64
	self     uint8 // our own color, or 255 if unknown. Excluded from Pick.
}

// Record marks color c as seen at frame f. If c > 15 the call is a no-op
// (defensive; color 255 means "clipped sprite" in CrewmateMatch).
func (s *SuspectTracker) Record(c uint8, f uint64) {
	if c > 15 {
		return
	}
	if f > s.lastSeen[c] {
		s.lastSeen[c] = f
	}
}

// SetSelf stores our own color so Pick can exclude it. 255 clears.
func (s *SuspectTracker) SetSelf(c uint8) { s.self = c }

// Self returns the stored own-color, or 255 if not known.
func (s *SuspectTracker) Self() uint8 { return s.self }

// selfColorFromScreen reads the palette-3 tint positions of the player's
// own sprite, which always sits at (playerScreenX, playerScreenY) during
// active play (sim.nim:2569). Returns the majority color found in tint
// positions, or 255 if no tint pixel is visible (e.g. if we're in an
// unexpected phase where the self sprite isn't drawn).
//
// Reuses the same template-offset tables FindCrewmates populates.
func selfColorFromScreen(pixels []uint8) uint8 {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return 255
	}
	ensureCrewmateTables()
	if len(crewmateBody) == 0 {
		return 255
	}
	// Gate: the actual player sprite must be present at the self anchor.
	// An all-zero frame would otherwise "detect" color 0 from the
	// (palette 0) tint positions.
	if !matchesCrewmate(pixels, playerScreenX, playerScreenY, false) &&
		!matchesCrewmate(pixels, playerScreenX, playerScreenY, true) {
		return 255
	}
	var counts [16]int
	seen := 0
	for _, tp := range crewmateBody {
		if tp.shadow {
			continue
		}
		x := playerScreenX + tp.dx
		y := playerScreenY + tp.dy
		if x < 0 || y < 0 || x >= ScreenWidth || y >= ScreenHeight {
			continue
		}
		c := pixels[y*ScreenWidth+x]
		if c > 15 {
			continue
		}
		counts[c]++
		seen++
	}
	// Require a reasonably confident read: the unshadowed tint positions
	// on the player sprite number ~14 pixels; we want >=8 to match to
	// avoid locking in a false-positive color from a nearby sprite's
	// bleed-through.
	if seen < 8 {
		return 255
	}
	best, bestN := uint8(255), 0
	for c, n := range counts {
		if n > bestN {
			bestN, best = n, uint8(c)
		}
	}
	// Majority must dominate — if the single top color isn't at least
	// half of the observed tint pixels, treat as ambiguous.
	if bestN*2 < seen {
		return 255
	}
	return best
}

// Pick returns the color seen most recently, excluding self. Returns
// (255, false) when no color has been recorded.
func (s *SuspectTracker) Pick() (uint8, bool) {
	best := uint8(255)
	bestF := uint64(0)
	for c := uint8(0); c < 16; c++ {
		if c == s.self {
			continue
		}
		f := s.lastSeen[c]
		if f > bestF {
			best, bestF = c, f
		}
	}
	if bestF == 0 {
		return 255, false
	}
	return best, true
}

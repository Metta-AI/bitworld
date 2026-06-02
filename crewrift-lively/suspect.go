package main

// SuspectTracker tracks when each player color was last seen.
// Used during voting to pick a suspect to vote for.
type SuspectTracker struct {
	lastSeen map[string]uint64
	self     string
}

// NewSuspectTracker creates a new SuspectTracker.
func NewSuspectTracker() *SuspectTracker {
	return &SuspectTracker{
		lastSeen: make(map[string]uint64),
	}
}

// Record notes that a player color was seen at the given frame.
// Skips empty strings and self color.
func (s *SuspectTracker) Record(color string, frame uint64) {
	if color == "" || color == s.self {
		return
	}
	s.lastSeen[color] = frame
}

// SetSelf sets the self color so it is excluded from tracking.
func (s *SuspectTracker) SetSelf(color string) {
	s.self = color
}

// Self returns the self color.
func (s *SuspectTracker) Self() string {
	return s.self
}

// Forget removes a color from tracking (e.g., after ejection).
func (s *SuspectTracker) Forget(color string) {
	delete(s.lastSeen, color)
}

// Pick returns the most recently seen player color, excluding self.
// Returns ("", false) if no candidates.
func (s *SuspectTracker) Pick() (string, bool) {
	var best string
	var bestFrame uint64
	for color, frame := range s.lastSeen {
		if color == s.self {
			continue
		}
		if frame > bestFrame || best == "" {
			best = color
			bestFrame = frame
		}
	}
	if best == "" {
		return "", false
	}
	return best, true
}

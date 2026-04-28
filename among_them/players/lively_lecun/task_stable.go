package main

// StabilityFilter tracks palette-9 blob detections across frames and only
// promotes a candidate to "confirmed task" once it has been observed at the
// same world position for stabilityRequired consecutive frames. This filters
// out orange-tinted player sprites (which move) from real task icons (which
// are fixed in the world).

const (
	stabilityRequired = 30 // ~1.25s at 24fps: real tasks never move, players
	//                        rarely pause this long. 5 frames was too lax --
	//                        a whole cluster of players standing still at
	//                        spawn got falsely confirmed.
	stabilityRadius = 4 // max drift (Chebyshev) to consider "same position"
	stabilityMaxAge = 3 // frames a candidate can go unobserved before eviction
)

type candidate struct {
	pos   Point
	seen  int // consecutive frames observed
	age   int // frames since last observation (reset to 0 each match)
}

type StabilityFilter struct {
	candidates []candidate
}

// Update takes this frame's detected icon world positions and returns any
// newly confirmed task positions (observed stably for stabilityRequired frames).
func (sf *StabilityFilter) Update(detected []Point) []Point {
	matched := make([]bool, len(sf.candidates))
	used := make([]bool, len(detected))
	var confirmed []Point

	// Match detections to existing candidates.
	for i := range sf.candidates {
		bestJ := -1
		bestD := stabilityRadius + 1
		for j, d := range detected {
			if used[j] {
				continue
			}
			dist := chebyshev(sf.candidates[i].pos, d)
			if dist < bestD {
				bestD = dist
				bestJ = j
			}
		}
		if bestJ >= 0 {
			matched[i] = true
			used[bestJ] = true
			sf.candidates[i].age = 0
			sf.candidates[i].seen++
			if sf.candidates[i].seen >= stabilityRequired {
				confirmed = append(confirmed, sf.candidates[i].pos)
				// Mark for removal by setting seen to -1.
				sf.candidates[i].seen = -1
			}
		}
	}

	// Age unmatched candidates; evict stale ones.
	n := 0
	for i := range sf.candidates {
		if sf.candidates[i].seen == -1 {
			continue // confirmed and consumed
		}
		if !matched[i] {
			sf.candidates[i].age++
			if sf.candidates[i].age > stabilityMaxAge {
				continue // evict
			}
		}
		sf.candidates[n] = sf.candidates[i]
		n++
	}
	sf.candidates = sf.candidates[:n]

	// Add new candidates from unmatched detections.
	for j, d := range detected {
		if !used[j] {
			sf.candidates = append(sf.candidates, candidate{pos: d, seen: 1, age: 0})
		}
	}

	return confirmed
}

func chebyshev(a, b Point) int {
	dx := absInt(a.X - b.X)
	dy := absInt(a.Y - b.Y)
	if dx > dy {
		return dx
	}
	return dy
}

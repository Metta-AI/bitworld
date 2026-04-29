package main

// TaskMemory is the agent's running set of remembered task locations in
// world coordinates. Entries within taskMemoryMergeRadius of an existing
// one are deduped on Add. A second set holds "blacklisted" task locations
// -- ones that were previously memorized and then forgotten because we
// couldn't reach or complete them. Add skips candidates close to any
// blacklisted entry so we don't loop re-memorizing the same bad icon.
type TaskMemory struct {
	Known       []Point
	Blacklisted []Point
}

const taskMemoryMergeRadius = 12

// Add records `p` if no existing entry is within taskMemoryMergeRadius
// (Chebyshev distance) and `p` isn't within taskMemoryMergeRadius of a
// blacklisted entry. Returns true when a new entry was inserted.
func (m *TaskMemory) Add(p Point) bool {
	for _, q := range m.Known {
		if absInt(q.X-p.X) <= taskMemoryMergeRadius &&
			absInt(q.Y-p.Y) <= taskMemoryMergeRadius {
			return false
		}
	}
	for _, q := range m.Blacklisted {
		if absInt(q.X-p.X) <= taskMemoryMergeRadius &&
			absInt(q.Y-p.Y) <= taskMemoryMergeRadius {
			return false
		}
	}
	m.Known = append(m.Known, p)
	return true
}

// Blacklist records `p` as a known-bad task location so future Add calls
// in its neighborhood are rejected. Useful when A* reports the goal as
// unreachable or the agent arrives but can never trigger OnTask.
func (m *TaskMemory) Blacklist(p Point) {
	for _, q := range m.Blacklisted {
		if absInt(q.X-p.X) <= taskMemoryMergeRadius &&
			absInt(q.Y-p.Y) <= taskMemoryMergeRadius {
			return
		}
	}
	m.Blacklisted = append(m.Blacklisted, p)
}

// Closest returns (point, index, ok). ok is false when memory is empty.
func (m *TaskMemory) Closest(from Point) (Point, int, bool) {
	if len(m.Known) == 0 {
		return Point{}, -1, false
	}
	bestI := 0
	bestD := manhattan(from, m.Known[0])
	for i := 1; i < len(m.Known); i++ {
		d := manhattan(from, m.Known[i])
		if d < bestD {
			bestI, bestD = i, d
		}
	}
	return m.Known[bestI], bestI, true
}

// Forget removes the entry at index `i`.
func (m *TaskMemory) Forget(i int) {
	m.Known = append(m.Known[:i], m.Known[i+1:]...)
}

// Len returns the number of remembered tasks.
func (m *TaskMemory) Len() int { return len(m.Known) }

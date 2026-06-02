package main

const (
	navLookahead     = 8
	navOffPathReplan = 20
	navArrivedRadius = 4
	navGoalSnapRadius = 16
	Unreachable      uint8 = 0xFF
)

// Navigator steers the bot toward a goal using A* pathfinding.
type Navigator struct {
	walkMap  *WalkMap
	goal     Point
	haveGoal bool
	path     []Point
	pathIdx  int
}

// NewNavigator creates a Navigator bound to the given WalkMap.
func NewNavigator(wm *WalkMap) *Navigator {
	return &Navigator{walkMap: wm}
}

// SetGoal sets the navigation goal, snapping to nearest walkable cell within radius.
// Returns false if no walkable cell is found near the goal.
func (n *Navigator) SetGoal(goal Point) bool {
	snapped, ok := nearestWalkable(n.walkMap, goal, navGoalSnapRadius)
	if !ok {
		return false
	}
	n.goal = snapped
	n.haveGoal = true
	n.path = nil
	n.pathIdx = 0
	return true
}

// Clear resets the navigator state.
func (n *Navigator) Clear() {
	n.haveGoal = false
	n.path = nil
	n.pathIdx = 0
	n.goal = Point{}
}

// HasGoal returns whether the navigator has an active goal.
func (n *Navigator) HasGoal() bool {
	return n.haveGoal
}

// Goal returns the current goal point.
func (n *Navigator) Goal() Point {
	return n.goal
}

// Next computes the next movement mask toward the goal.
// Returns (mask, arrived). mask is 0 if no goal or arrived.
// mask is Unreachable if path planning fails.
func (n *Navigator) Next(player Point) (mask uint8, arrived bool) {
	if !n.haveGoal {
		return 0, false
	}

	// Check arrival
	if manhattan(player, n.goal) <= navArrivedRadius {
		return 0, true
	}

	// Replan if no path
	if n.path == nil {
		n.path = AStar(player, n.goal, n.walkMap.Walkable, n.walkMap.Width, n.walkMap.Height)
		n.pathIdx = 0
		if n.path == nil {
			return Unreachable, false
		}
	}

	// Advance pathIdx to closest cell in a 32-cell forward window
	bestDist := manhattan(player, n.path[n.pathIdx])
	bestIdx := n.pathIdx
	limit := n.pathIdx + 32
	if limit > len(n.path) {
		limit = len(n.path)
	}
	for i := n.pathIdx + 1; i < limit; i++ {
		d := manhattan(player, n.path[i])
		if d < bestDist {
			bestDist = d
			bestIdx = i
		}
	}
	n.pathIdx = bestIdx

	// Check if drifted too far from path
	if bestDist > navOffPathReplan {
		n.path = AStar(player, n.goal, n.walkMap.Walkable, n.walkMap.Width, n.walkMap.Height)
		n.pathIdx = 0
		if n.path == nil {
			return Unreachable, false
		}
	}

	// Pick target
	targetIdx := n.pathIdx + navLookahead
	if targetIdx >= len(n.path) {
		targetIdx = len(n.path) - 1
	}
	target := n.path[targetIdx]

	return maskTowards(player, target), false
}

// maskTowards returns the button bitmask to move from `from` toward `to`.
func maskTowards(from, to Point) uint8 {
	var mask uint8
	if to.X > from.X {
		mask |= ButtonRight
	} else if to.X < from.X {
		mask |= ButtonLeft
	}
	if to.Y > from.Y {
		mask |= ButtonDown
	} else if to.Y < from.Y {
		mask |= ButtonUp
	}
	return mask
}

// nearestWalkable finds the nearest walkable cell to p within the given radius.
// If p itself is walkable, returns p. Otherwise spirals outward.
func nearestWalkable(wm *WalkMap, p Point, radius int) (Point, bool) {
	if wm.Walkable(p.X, p.Y) {
		return p, true
	}
	for r := 1; r <= radius; r++ {
		// Check all cells at Manhattan distance r (ring)
		for dx := -r; dx <= r; dx++ {
			for dy := -r; dy <= r; dy++ {
				if absInt(dx)+absInt(dy) > r {
					continue
				}
				if absInt(dx)+absInt(dy) == 0 {
					continue
				}
				nx, ny := p.X+dx, p.Y+dy
				if wm.Walkable(nx, ny) {
					return Point{nx, ny}, true
				}
			}
		}
	}
	return Point{}, false
}

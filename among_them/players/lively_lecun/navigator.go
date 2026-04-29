package main

// Navigator turns a target world coordinate into a button mask by planning
// an A* path across the loaded walkMask and steering toward a lookahead
// cell on that path. The zero value is not usable; call NewNavigator.
type Navigator struct {
	Walk *WalkMask

	goal     Point
	haveGoal bool

	path    []Point
	pathIdx int // last-confirmed index into path
}

// Tunables. lookahead picks a path cell a few steps ahead of the player so
// the produced mask is stable when the player is close to two perpendicular
// path cells. offPathReplan triggers a full A* replan when the player has
// drifted further than this many cells from the closest path point --
// usually because Bumper perturbed us off course or the lock briefly drifted.
// arrived is the proximity at which we stop steering and let TaskHolder /
// idle handle the final settling.
const (
	navLookahead     = 8
	navOffPathReplan = 20
	navArrivedRadius = 4
)

func NewNavigator(w *WalkMask) *Navigator {
	return &Navigator{Walk: w}
}

// SetGoal selects a new world target. When the requested cell isn't
// walkable (e.g. a task icon implies a box center that lands on the
// surrounding furniture), the goal snaps to the nearest walkable cell
// within navGoalSnapRadius. Returns false only when even the snapped goal
// can't be found.
const navGoalSnapRadius = 16

func (n *Navigator) SetGoal(goal Point) bool {
	if n.Walk == nil {
		n.haveGoal = false
		n.path = nil
		return false
	}
	snapped, ok := nearestWalkable(n.Walk, goal, navGoalSnapRadius)
	if !ok {
		n.haveGoal = false
		n.path = nil
		return false
	}
	n.goal = snapped
	n.haveGoal = true
	n.path = nil
	n.pathIdx = 0
	return true
}

// Clear forgets the current goal.
func (n *Navigator) Clear() {
	n.haveGoal = false
	n.path = nil
	n.pathIdx = 0
}

// HasGoal reports whether SetGoal has succeeded and Clear hasn't been called.
func (n *Navigator) HasGoal() bool { return n.haveGoal }

// Goal returns the current goal (only meaningful when HasGoal()).
func (n *Navigator) Goal() Point { return n.goal }

// Unreachable is returned for the mask when the goal can't be reached from
// the player's current cell (A* found no path). Callers should treat this
// as a permanent failure for this goal and pick a different one; unlike
// (0, false) it isn't "waiting for direction" noise.
const Unreachable uint8 = 0xFF

// Next inspects the current player position and returns:
//   - mask: the button bits to press this frame (0 means "no input";
//     Unreachable means the goal has no path from here)
//   - arrived: true when the player is within navArrivedRadius of the goal
//
// When no goal is set, returns (0, false).
func (n *Navigator) Next(player Point) (mask uint8, arrived bool) {
	if !n.haveGoal {
		return 0, false
	}
	if manhattan(player, n.goal) <= navArrivedRadius {
		return 0, true
	}
	if n.path == nil {
		n.replan(player)
		if n.path == nil {
			return Unreachable, false
		}
	}

	// Advance pathIdx to the closest cell on the path within a small
	// search window forward from the previously confirmed position. This
	// O(window) update is cheap and preserves monotone progress.
	bestI, bestD := n.pathIdx, manhattan(n.path[n.pathIdx], player)
	end := n.pathIdx + 32
	if end > len(n.path) {
		end = len(n.path)
	}
	for i := n.pathIdx + 1; i < end; i++ {
		d := manhattan(n.path[i], player)
		if d < bestD {
			bestI, bestD = i, d
		}
	}
	n.pathIdx = bestI

	if bestD > navOffPathReplan {
		n.replan(player)
		if n.path == nil {
			return Unreachable, false
		}
		n.pathIdx = 0
	}

	targetIdx := n.pathIdx + navLookahead
	if targetIdx >= len(n.path) {
		targetIdx = len(n.path) - 1
	}
	target := n.path[targetIdx]
	return maskTowards(player, target), false
}

func (n *Navigator) replan(from Point) {
	// The player's "center" is the cam-center world coord; the sprite is
	// 16 wide, so the reported center often lands on the foot-row wall
	// pixels of narrow corridors. A* refuses to start from a non-walkable
	// cell, which made every radar goal look unreachable. Snap the start
	// to the closest walkable cell before planning.
	start := from
	if !n.Walk.Walkable(start.X, start.Y) {
		if snapped, ok := nearestWalkable(n.Walk, from, navGoalSnapRadius); ok {
			start = snapped
		}
	}
	n.path = AStar(start, n.goal, n.Walk.Walkable, MapWidth, MapHeight)
	n.pathIdx = 0
}

func maskTowards(from, to Point) uint8 {
	var m uint8
	if to.X > from.X {
		m |= ButtonRight
	} else if to.X < from.X {
		m |= ButtonLeft
	}
	if to.Y > from.Y {
		m |= ButtonDown
	} else if to.Y < from.Y {
		m |= ButtonUp
	}
	return m
}

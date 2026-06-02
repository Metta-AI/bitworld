package main

// AStar finds a path from start to goal using A* with 8-directional movement.
// Returns nil if no path is found or start/goal is not walkable.
// Returns []Point{start} if start == goal.
// Diagonal movement requires both adjacent cardinal cells to be walkable (no corner-cutting).
func AStar(start, goal Point, walkable func(int, int) bool, width, height int) []Point {
	if !walkable(start.X, start.Y) || !walkable(goal.X, goal.Y) {
		return nil
	}
	if start == goal {
		return []Point{start}
	}

	const maxExpansions = 50000

	type node struct {
		pt     Point
		g      int
		f      int
		parent int // index into closed list, or -1
	}

	// directions: dx, dy, cost
	type dir struct {
		dx, dy, cost int
	}
	dirs := [8]dir{
		{1, 0, 10}, {-1, 0, 10}, {0, 1, 10}, {0, -1, 10},
		{1, 1, 14}, {1, -1, 14}, {-1, 1, 14}, {-1, -1, 14},
	}

	heuristic := func(a, b Point) int {
		dx := absInt(a.X - b.X)
		dy := absInt(a.Y - b.Y)
		// Octile distance
		if dx > dy {
			return 14*dy + 10*(dx-dy)
		}
		return 14*dx + 10*(dy-dx)
	}

	// closed set: map from point to index in closed slice
	closed := make(map[Point]int)
	// open list (simple slice scan)
	open := make([]node, 0, 256)

	h := heuristic(start, goal)
	open = append(open, node{pt: start, g: 0, f: h, parent: -1})

	// closed slice stores settled nodes for path reconstruction
	closedNodes := make([]node, 0, 256)

	expansions := 0
	for len(open) > 0 {
		if expansions >= maxExpansions {
			return nil
		}
		expansions++

		// Find node with lowest f in open list
		bestIdx := 0
		for i := 1; i < len(open); i++ {
			if open[i].f < open[bestIdx].f {
				bestIdx = i
			}
		}

		current := open[bestIdx]
		// Remove from open (swap with last)
		open[bestIdx] = open[len(open)-1]
		open = open[:len(open)-1]

		// Skip if already closed
		if _, exists := closed[current.pt]; exists {
			continue
		}

		// Add to closed
		closedIdx := len(closedNodes)
		closed[current.pt] = closedIdx
		closedNodes = append(closedNodes, current)

		// Goal reached?
		if current.pt == goal {
			// Reconstruct path
			var path []Point
			idx := closedIdx
			for idx >= 0 {
				path = append(path, closedNodes[idx].pt)
				idx = closedNodes[idx].parent
			}
			// Reverse
			for i, j := 0, len(path)-1; i < j; i, j = i+1, j-1 {
				path[i], path[j] = path[j], path[i]
			}
			return path
		}

		// Expand neighbors
		for _, d := range dirs {
			nx, ny := current.pt.X+d.dx, current.pt.Y+d.dy
			if nx < 0 || ny < 0 || nx >= width || ny >= height {
				continue
			}
			if !walkable(nx, ny) {
				continue
			}
			// Diagonal: check no corner-cutting
			if d.dx != 0 && d.dy != 0 {
				if !walkable(current.pt.X+d.dx, current.pt.Y) || !walkable(current.pt.X, current.pt.Y+d.dy) {
					continue
				}
			}

			np := Point{nx, ny}
			if _, exists := closed[np]; exists {
				continue
			}

			ng := current.g + d.cost
			nh := heuristic(np, goal)
			open = append(open, node{pt: np, g: ng, f: ng + nh, parent: closedIdx})
		}
	}

	return nil
}

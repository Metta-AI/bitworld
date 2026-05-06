package main

import "container/heap"

// Point is a (x, y) cell in world coordinates.
type Point struct {
	X, Y int
}

// Walkable reports whether the cell (x, y) can be stood on. The signature
// matches WalkMask.Walkable so the real game grid plugs in directly; tests
// pass small synthetic grids via a closure.
type Walkable func(x, y int) bool

// AStar finds a 4-connected shortest path from start to goal across an
// w×h grid where walkable(x, y) reports passability. Returns nil when no
// path exists, otherwise a path that begins at start and ends at goal
// (inclusive of both).
//
// Edge cost is 1; heuristic is Manhattan distance, which is admissible and
// consistent for 4-connected unit-cost movement.
func AStar(start, goal Point, walkable Walkable, w, h int) []Point {
	if !inBounds(start, w, h) || !inBounds(goal, w, h) {
		return nil
	}
	if !walkable(start.X, start.Y) || !walkable(goal.X, goal.Y) {
		return nil
	}
	if start == goal {
		return []Point{start}
	}

	n := w * h
	gScore := make([]int32, n)
	from := make([]int32, n)
	seen := make([]bool, n)
	for i := range gScore {
		gScore[i] = -1
		from[i] = -1
	}

	si := int32(start.Y*w + start.X)
	gi := int32(goal.Y*w + goal.X)
	gScore[si] = 0

	pq := &astarPQ{}
	heap.Init(pq)
	heap.Push(pq, astarItem{idx: si, f: int32(manhattan(start, goal))})

	dirs := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

	for pq.Len() > 0 {
		cur := heap.Pop(pq).(astarItem)
		if seen[cur.idx] {
			continue // stale pq entry; a better g found earlier
		}
		seen[cur.idx] = true
		if cur.idx == gi {
			return reconstructPath(from, si, gi, w)
		}
		cg := gScore[cur.idx]
		cx, cy := int(cur.idx)%w, int(cur.idx)/w
		for _, d := range dirs {
			nx, ny := cx+d[0], cy+d[1]
			if nx < 0 || ny < 0 || nx >= w || ny >= h {
				continue
			}
			if !walkable(nx, ny) {
				continue
			}
			ni := int32(ny*w + nx)
			if seen[ni] {
				continue
			}
			ng := cg + 1
			if gScore[ni] == -1 || ng < gScore[ni] {
				gScore[ni] = ng
				from[ni] = cur.idx
				h := manhattan(Point{nx, ny}, goal)
				heap.Push(pq, astarItem{idx: ni, f: ng + int32(h)})
			}
		}
	}
	return nil
}

func reconstructPath(from []int32, start, goal int32, w int) []Point {
	// Walk parents from goal back to start, then reverse.
	var rev []Point
	for i := goal; ; i = from[i] {
		rev = append(rev, Point{int(i) % w, int(i) / w})
		if i == start {
			break
		}
	}
	for l, r := 0, len(rev)-1; l < r; l, r = l+1, r-1 {
		rev[l], rev[r] = rev[r], rev[l]
	}
	return rev
}

func inBounds(p Point, w, h int) bool {
	return p.X >= 0 && p.Y >= 0 && p.X < w && p.Y < h
}

func manhattan(a, b Point) int {
	return absInt(a.X-b.X) + absInt(a.Y-b.Y)
}

// astarItem is what's stored in the open set.
type astarItem struct {
	idx int32 // cell index = y*w + x
	f   int32 // g + heuristic
}

type astarPQ []astarItem

func (pq astarPQ) Len() int            { return len(pq) }
func (pq astarPQ) Less(i, j int) bool  { return pq[i].f < pq[j].f }
func (pq astarPQ) Swap(i, j int)       { pq[i], pq[j] = pq[j], pq[i] }
func (pq *astarPQ) Push(x interface{}) { *pq = append(*pq, x.(astarItem)) }
func (pq *astarPQ) Pop() interface{} {
	old := *pq
	n := len(old)
	v := old[n-1]
	*pq = old[:n-1]
	return v
}

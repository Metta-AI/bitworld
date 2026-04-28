package main

// Tunables for on-screen task-icon detection. The task sprite is 12x12
// (sim.nim's SpriteSize), but only some of its pixels are palette-9 --
// sprites mix palettes -- so flood-fill produces fragmented blobs that we
// post-merge into a single centroid per sprite.
const (
	taskBlobMinSize     = 3  // ignore blobs of fewer pixels (noise / 1-px artifacts)
	taskBlobMergeRadius = 12 // sprite size: blobs within this Manhattan distance fold together
	taskBlobEdgeMargin  = 2  // skip blobs that touch the screen edge (clipped icons)
)

// DetectTaskIcons returns the centroids (screen coordinates) of likely
// task-icon sprites in `pixels`, after merging palette-taskIconColor blobs
// that are within taskBlobMergeRadius of one another.
func DetectTaskIcons(pixels []uint8) []Point {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return nil
	}
	raw := paletteBlobs(pixels, taskIconColor)
	return mergeBlobs(raw, taskBlobMergeRadius)
}

type blob struct {
	sumX, sumY, n int
	minX, minY    int
	maxX, maxY    int
}

func (b blob) center() Point { return Point{b.sumX / b.n, b.sumY / b.n} }

// paletteBlobs returns one blob per 4-connected palette-`color` region in
// `pixels`, dropping regions smaller than taskBlobMinSize and those that
// touch the screen edge.
func paletteBlobs(pixels []uint8, color uint8) []blob {
	visited := make([]bool, ScreenWidth*ScreenHeight)
	var blobs []blob
	var stack []int
	for sy := 0; sy < ScreenHeight; sy++ {
		for sx := 0; sx < ScreenWidth; sx++ {
			i := sy*ScreenWidth + sx
			if visited[i] || pixels[i] != color {
				continue
			}
			b := blob{minX: sx, minY: sy, maxX: sx, maxY: sy}
			stack = append(stack[:0], i)
			visited[i] = true
			for len(stack) > 0 {
				k := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				kx, ky := k%ScreenWidth, k/ScreenWidth
				b.sumX += kx
				b.sumY += ky
				b.n++
				if kx < b.minX {
					b.minX = kx
				}
				if kx > b.maxX {
					b.maxX = kx
				}
				if ky < b.minY {
					b.minY = ky
				}
				if ky > b.maxY {
					b.maxY = ky
				}
				for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
					nx, ny := kx+d[0], ky+d[1]
					if nx < 0 || ny < 0 || nx >= ScreenWidth || ny >= ScreenHeight {
						continue
					}
					ni := ny*ScreenWidth + nx
					if visited[ni] || pixels[ni] != color {
						continue
					}
					visited[ni] = true
					stack = append(stack, ni)
				}
			}
			if b.n < taskBlobMinSize {
				continue
			}
			// Drop blobs that hug a screen edge -- a clipped icon's centroid
			// is biased and the matching task is presumably near another
			// edge, so we'll see it cleanly the next frame.
			if b.minX < taskBlobEdgeMargin || b.minY < taskBlobEdgeMargin ||
				b.maxX >= ScreenWidth-taskBlobEdgeMargin ||
				b.maxY >= ScreenHeight-taskBlobEdgeMargin {
				continue
			}
			blobs = append(blobs, b)
		}
	}
	return blobs
}

// mergeBlobs unions blobs whose centroids are within mergeRadius (Chebyshev
// distance) of one another and returns one centroid per merged group.
// Implementation is union-find over centroid pairs; n is small (handful of
// blobs per frame) so the O(n^2) pair scan is fine.
func mergeBlobs(in []blob, mergeRadius int) []Point {
	if len(in) == 0 {
		return nil
	}
	n := len(in)
	parent := make([]int, n)
	for i := range parent {
		parent[i] = i
	}
	var find func(int) int
	find = func(i int) int {
		if parent[i] != i {
			parent[i] = find(parent[i])
		}
		return parent[i]
	}
	for i := 0; i < n; i++ {
		ci := in[i].center()
		for j := i + 1; j < n; j++ {
			cj := in[j].center()
			if absInt(ci.X-cj.X) <= mergeRadius && absInt(ci.Y-cj.Y) <= mergeRadius {
				a, b := find(i), find(j)
				if a != b {
					parent[a] = b
				}
			}
		}
	}
	sumX := map[int]int{}
	sumY := map[int]int{}
	cnt := map[int]int{}
	for i := 0; i < n; i++ {
		r := find(i)
		c := in[i].center()
		sumX[r] += c.X
		sumY[r] += c.Y
		cnt[r]++
	}
	out := make([]Point, 0, len(cnt))
	for r, c := range cnt {
		out = append(out, Point{sumX[r] / c, sumY[r] / c})
	}
	return out
}

// IconScreenToTaskWorld converts an icon centroid in screen coordinates
// to the approximate world position of the task box. Per sim.nim:2316-2319
// the icon center sits SpriteSize/2 + 2 pixels above the task's top edge;
// we add 10 (= 8 + a small offset) so the goal lands inside the box rather
// than on its top edge, giving the navigator a small margin.
func IconScreenToTaskWorld(iconCenter Point, cam Camera) Point {
	return Point{
		X: iconCenter.X + cam.X,
		Y: iconCenter.Y + cam.Y + 10,
	}
}

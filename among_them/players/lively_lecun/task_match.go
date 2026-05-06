package main

import _ "embed"

// taskIconTemplate is the 12×12 palette-indexed task-icon sprite, baked
// from among_them/spritesheet.png at tile index 4 (sim.nim:2430-2432).
// Values are palette indices 0–15; 255 marks transparent pixels we skip
// when matching.
//
// For reference, the pattern is:
//
//	. . . . . 0 0 . . . . .
//	. . . . 0 7 7 0 . . . .
//	. . . 0 7 7 7 7 0 . . .
//	. . . 0 7 0 0 7 0 . . .
//	. . . 0 7 0 0 7 0 . . .
//	. . 0 7 7 0 0 7 7 0 . .
//	. . 0 7 7 0 0 7 7 0 . .
//	. . 0 7 7 7 7 7 7 0 . .
//	. 0 7 7 7 0 0 7 7 7 0 .
//	. 0 7 7 7 0 0 7 7 7 0 .
//	. 0 7 7 7 7 7 7 7 7 0 .
//	. . 0 0 0 0 0 0 0 0 . .
//
// (palette 7 = orange RGB 255,163,0; palette 0 = black outline; . = transparent).
//
//go:embed testdata/task_icon.bin
var taskIconTemplate []byte

const (
	taskIconW = 12
	taskIconH = 12

	// Seed color: the icon's fill color (palette 7 = orange). We scan for
	// pa7 pixels as cheap candidates, then bitmap-test each seed.
	taskIconFillColor = 7

	// Bob range: the sprite's Y offset cycles through [-1, 0, 1] (sim.nim:2312).
	// We test one small slide in each axis to accommodate that plus any
	// off-by-one in our seed position.
	iconMatchWobble = 2

	// Non-transparent template pixels: 62 out of 144 template entries.
	iconTemplateOpaque = 62

	// Minimum fraction of the visible portion of the template that must
	// match for a location to count. Keeps false positives down while
	// still accepting clipped sprites at the screen edge.
	iconMatchMinRatioNum = 60
	iconMatchMinRatioDen = 62

	// Minimum number of non-transparent template pixels that must actually
	// fall inside the viewport. A sprite barely peeking in from the edge
	// gives too few pixels for a reliable match -- the dedup radius and
	// false-positive defenses rely on seeing most of the sprite.
	iconMatchMinTested = 24
)

// IconMatch is an exact 12×12 task-icon match in screen space.
type IconMatch struct {
	// Top-left corner of the 12×12 sprite on screen.
	ScreenX, ScreenY int
}

// FindTaskIcons returns exact-match task-icon locations in `pixels`. Seed
// search uses pa7 pixels (cheap O(N)); each unique seed triggers a 12×12
// bitmap comparison against the template.
func FindTaskIcons(pixels []uint8) []IconMatch {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return nil
	}
	if len(taskIconTemplate) != taskIconW*taskIconH {
		return nil // embedded asset missing or corrupt
	}

	tried := make(map[int]struct{})
	var out []IconMatch

	// Scan every pa7 pixel; each acts as a seed. Because the icon's central
	// columns are all pa7, the same sprite contributes many seed pixels --
	// we dedup match attempts by top-left corner.
	for sy := 0; sy < ScreenHeight; sy++ {
		for sx := 0; sx < ScreenWidth; sx++ {
			if pixels[sy*ScreenWidth+sx] != taskIconFillColor {
				continue
			}
			// Try each wobble offset around this seed as the sprite's top-left.
			// Allow tlx/tly outside the viewport: scoreMatch clips to the
			// visible portion so we match icons clipped at the screen edge.
			for dy := -iconMatchWobble; dy <= iconMatchWobble; dy++ {
				for dx := -iconMatchWobble; dx <= iconMatchWobble; dx++ {
					tlx, tly := sx-taskIconW/2+dx, sy-taskIconH/2+dy
					if tlx+taskIconW <= 0 || tly+taskIconH <= 0 ||
						tlx >= ScreenWidth || tly >= ScreenHeight {
						continue
					}
					// Key only uses the on-screen portion for dedup.
					key := (tly+taskIconH)*ScreenWidth + (tlx + taskIconW)
					if _, ok := tried[key]; ok {
						continue
					}
					tried[key] = struct{}{}
					score, tested := scoreMatch(pixels, tlx, tly)
					if tested < iconMatchMinTested {
						continue
					}
					if score*iconMatchMinRatioDen < tested*iconMatchMinRatioNum {
						continue
					}
					out = append(out, IconMatch{ScreenX: tlx, ScreenY: tly})
				}
			}
		}
	}

	// Dedup overlapping matches (a single icon can pass at multiple nearby
	// top-lefts). Keep the first, drop any within 6 px of an earlier keeper.
	deduped := out[:0]
	for _, m := range out {
		keep := true
		for _, k := range deduped {
			if absInt(m.ScreenX-k.ScreenX) < 6 && absInt(m.ScreenY-k.ScreenY) < 6 {
				keep = false
				break
			}
		}
		if keep {
			deduped = append(deduped, m)
		}
	}
	return deduped
}

// scoreMatch counts how many non-transparent template pixels equal the
// frame's pixel at the aligned location. Template pixels whose aligned
// frame coord lies outside the viewport are skipped -- so a sprite that's
// half-clipped at the screen edge returns a lower `tested` count, not a
// penalty. Returns (score, tested): score is matches, tested is the number
// of visible non-transparent template pixels actually compared.
func scoreMatch(pixels []uint8, tlx, tly int) (score, tested int) {
	for dy := 0; dy < taskIconH; dy++ {
		fy := tly + dy
		if fy < 0 || fy >= ScreenHeight {
			continue
		}
		for dx := 0; dx < taskIconW; dx++ {
			t := taskIconTemplate[dy*taskIconW+dx]
			if t == 255 {
				continue
			}
			fx := tlx + dx
			if fx < 0 || fx >= ScreenWidth {
				continue
			}
			tested++
			if pixels[fy*ScreenWidth+fx] == t {
				score++
			}
		}
	}
	return score, tested
}

// IconToTaskWorld converts the top-left of a matched icon sprite into the
// implied task box's top-left world coord.
//
// Geometry (sim.nim:2316-2319):
//
//	iconSx = task.x + task.w/2 - SpriteSize/2 - cameraX
//	iconSy = task.y - SpriteSize - 2 + bobY - cameraY
//
// Solving for (task.x, task.y) given the icon top-left (iconSx, iconSy)
// and the camera:
//
//	task.x = iconSx + cameraX + SpriteSize/2 - task.w/2  (task.w/2 == SpriteSize/2 for 16-wide sprites on 12-wide icons, so this gets close)
//	task.y = iconSy + cameraY + SpriteSize + 2 - bobY
//
// All 40 in-game task rects are 16 wide. (task.w/2 - SpriteSize/2) = 2, so
// task.x = iconSx + cameraX - 2. bobY has magnitude 1 so it folds into our
// arrival tolerance. We target the box's center: (task.x + 8, task.y + 8).
func IconToTaskWorld(m IconMatch, cam Camera) Point {
	return Point{
		X: m.ScreenX + cam.X - 2 + 8,  // = iconSx + cameraX + 6 = task center X
		Y: m.ScreenY + cam.Y + 12 + 2 + 8, // = iconSy + cameraY + 22 = task center Y
	}
}

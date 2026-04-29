package main

import _ "embed"

// bodySpriteTemplate is the 12×12 palette-indexed body sprite, baked by
// cmd/extract_sprites/main.go from spritesheet.aseprite tile 1. Values 0..15
// are palette indices; 255 marks transparent pixels.
//
// The sim blits this via blitSpriteOutlined (sim.nim:2553), which substitutes
// palette 3 (TintColor) with the body's player color and palette 9
// (ShadeTintColor) with ShadowMap[color & 0x0f]. Palettes 0 (outline) and
// 2 (eye highlight) are stable across all body colors, so that's what we
// match on. The tint pixels we ignore entirely — they identify *which*
// player died, not *whether* a body is there.
//
//go:embed testdata/body_sprite.bin
var bodySpriteTemplate []byte

const (
	bodySpriteW = 12
	bodySpriteH = 12

	// Palette indices we match exactly. Palette 3/9 are tint wildcards
	// (sim.nim:1177-1183 actorColor) and are ignored.
	bodyStableBlack = 0
	bodyStableWhite = 2
	bodyTint        = 3
	bodyTintShadow  = 9

	// Seed color: palette 2 (white) only appears in the 12-pixel skull
	// region near the top of the sprite. Using it as a seed avoids the
	// false positives we'd get from palette-0 outline (every black pixel
	// on screen would match).
	bodySeedColor = bodyStableWhite

	// Miss budget across stable opaque pixels (palette 0 + palette 2 =
	// 52 total). 8 misses is ~15%, a similar tolerance to the task
	// icon's 2/62. Must be wide enough that one player standing on top
	// of the body doesn't disqualify the match.
	bodyMatchMaxMiss = 8

	// Minimum stable pixels that must fall inside the viewport. A body
	// barely peeking in from the screen edge is too ambiguous to trust
	// as a report target.
	bodyMatchMinTested = 32

	// Dedup radius (screen-px): two body matches whose top-lefts are
	// closer than this collapse into one. Bodies cannot overlap in the
	// sim, so this is just noise rejection from the matcher itself.
	bodyDedupRadius = 6
)

// BodyMatch is an exact body-sprite match in screen space. Color is the
// best-guess player color inferred from the tint pixels, or 255 if no
// tint pixels landed in the viewport (typically because the body is
// clipped off-screen).
type BodyMatch struct {
	ScreenX, ScreenY int
	Color            uint8
}

// stablePixels lists (dx, dy, palette) for every non-tint opaque pixel
// in bodySpriteTemplate, precomputed once. Filled lazily in FindBodies
// to avoid an init() for a test-dependency ordering headache.
var bodyStable []bodyStablePx
var bodyTintPx []bodyTintPxSpec

type bodyStablePx struct {
	dx, dy int
	pal    uint8
}

type bodyTintPxSpec struct {
	dx, dy int
	shadow bool // true = palette 9 (shadowed tint)
}

func ensureBodyTables() {
	if bodyStable != nil {
		return
	}
	if len(bodySpriteTemplate) != bodySpriteW*bodySpriteH {
		return
	}
	stable := make([]bodyStablePx, 0, 60)
	tint := make([]bodyTintPxSpec, 0, 24)
	for dy := 0; dy < bodySpriteH; dy++ {
		for dx := 0; dx < bodySpriteW; dx++ {
			p := bodySpriteTemplate[dy*bodySpriteW+dx]
			switch p {
			case 255:
				continue
			case bodyTint:
				tint = append(tint, bodyTintPxSpec{dx, dy, false})
			case bodyTintShadow:
				tint = append(tint, bodyTintPxSpec{dx, dy, true})
			default:
				stable = append(stable, bodyStablePx{dx, dy, p})
			}
		}
	}
	bodyStable = stable
	bodyTintPx = tint
}

// FindBodies returns every body-sprite match in the frame. Each match's
// ScreenX/ScreenY is the sprite top-left; the body's world coord is at
// (cam.X + ScreenX + SpriteDrawOffX, cam.Y + ScreenY + SpriteDrawOffY) —
// inverting the blit formula at sim.nim:2549-2550.
//
// The seed scan uses palette-2 pixels: palette 2 (white) appears only in
// the body's 12-pixel skull region (rows 2-6), so every pa2 pixel on
// screen is either part of a body or very sparse noise. For each seed,
// we try it as each of the 12 known pa2 template positions (wobble ±1
// in case of off-by-one noise).
func FindBodies(pixels []uint8) []BodyMatch {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return nil
	}
	ensureBodyTables()
	if len(bodyStable) == 0 {
		return nil
	}

	// Precompute the template's palette-2 offsets so we can try each
	// seed as each possible skull pixel.
	type pa2Off struct{ dx, dy int }
	var pa2Offs []pa2Off
	for _, sp := range bodyStable {
		if sp.pal == bodyStableWhite {
			pa2Offs = append(pa2Offs, pa2Off{sp.dx, sp.dy})
		}
	}

	tried := make(map[int]struct{})
	var out []BodyMatch
	for sy := 0; sy < ScreenHeight; sy++ {
		for sx := 0; sx < ScreenWidth; sx++ {
			if pixels[sy*ScreenWidth+sx] != bodySeedColor {
				continue
			}
			for _, off := range pa2Offs {
				tlx, tly := sx-off.dx, sy-off.dy
				if tlx <= -bodySpriteW || tly <= -bodySpriteH ||
					tlx >= ScreenWidth || tly >= ScreenHeight {
					continue
				}
				key := (tly+bodySpriteH)*ScreenWidth + (tlx + bodySpriteW)
				if _, ok := tried[key]; ok {
					continue
				}
				tried[key] = struct{}{}
				miss, tested := bodyScore(pixels, tlx, tly)
				if tested < bodyMatchMinTested {
					continue
				}
				if miss > bodyMatchMaxMiss {
					continue
				}
				out = append(out, BodyMatch{
					ScreenX: tlx,
					ScreenY: tly,
					Color:   bodyTintColor(pixels, tlx, tly),
				})
			}
		}
	}

	// Dedup: multiple adjacent top-lefts can pass for a single body; keep
	// the first and drop anything inside bodyDedupRadius.
	deduped := out[:0]
	for _, m := range out {
		keep := true
		for _, k := range deduped {
			if absInt(m.ScreenX-k.ScreenX) < bodyDedupRadius &&
				absInt(m.ScreenY-k.ScreenY) < bodyDedupRadius {
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

// bodyScore counts stable-pixel misses for a body sprite placed at (tlx, tly).
// Stable = palette-0 outline + palette-2 highlight; tint pixels (3 / 9) are
// skipped since they depend on the body's color. Pixels clipped off-screen
// are skipped (not counted as misses), mirroring scoreMatch's behavior in
// task_match.go:140-162.
func bodyScore(pixels []uint8, tlx, tly int) (miss, tested int) {
	for _, sp := range bodyStable {
		fx := tlx + sp.dx
		fy := tly + sp.dy
		if fx < 0 || fy < 0 || fx >= ScreenWidth || fy >= ScreenHeight {
			continue
		}
		tested++
		if pixels[fy*ScreenWidth+fx] != sp.pal {
			miss++
		}
	}
	return miss, tested
}

// bodyTintColor infers the body's player color by majority-vote over the
// tint pixels (palette 3 positions in the template). Returns 255 if no tint
// pixels are visible. The shadow pixels (palette 9 positions) are ignored
// here since they'd need an inverse ShadowMap; the raw tint pixels alone
// are enough for identification.
func bodyTintColor(pixels []uint8, tlx, tly int) uint8 {
	var counts [16]int
	any := false
	for _, tp := range bodyTintPx {
		if tp.shadow {
			continue
		}
		fx := tlx + tp.dx
		fy := tly + tp.dy
		if fx < 0 || fy < 0 || fx >= ScreenWidth || fy >= ScreenHeight {
			continue
		}
		c := pixels[fy*ScreenWidth+fx]
		if c > 15 {
			continue
		}
		counts[c]++
		any = true
	}
	if !any {
		return 255
	}
	best, bestN := uint8(0), -1
	for i, n := range counts {
		if n > bestN {
			bestN = n
			best = uint8(i)
		}
	}
	return best
}

// BodyWorld converts a body sprite match to its body collision-box center
// in world coordinates. Inverting sim.nim:2549-2551:
//
//	bsx = body.x - SpriteDrawOffX - cameraX  =>  body.x = bsx + SpriteDrawOffX + cameraX
//	bsy = body.y - SpriteDrawOffY - cameraY  =>  body.y = bsy + SpriteDrawOffY + cameraY
//
// The report test (sim.nim:1310-1313) uses the body's collision center
// (body.x + CollisionW/2, body.y + CollisionH/2) — with CollisionW=CollisionH=1
// (sim.nim:21-22), that's effectively (body.x, body.y). We target that directly.
const (
	bodySpriteDrawOffX = 2 // SpriteDrawOffX in sim.nim:23
	bodySpriteDrawOffY = 8 // SpriteDrawOffY in sim.nim:24
)

func BodyWorld(m BodyMatch, cam Camera) Point {
	return Point{
		X: m.ScreenX + bodySpriteDrawOffX + cam.X,
		Y: m.ScreenY + bodySpriteDrawOffY + cam.Y,
	}
}

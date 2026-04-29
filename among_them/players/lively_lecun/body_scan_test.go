package main

import "testing"

// paintBody renders the body sprite template at (tlx, tly) with the given
// player color, writing into a fresh 128×128 black frame. Mirrors
// blitSpriteOutlined + actorColor (sim.nim:1177-1183, 1532-1546): tint
// (palette 3) → color, shade (palette 9) → shadowMap[color].
func paintBody(tlx, tly int, color uint8) []uint8 {
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	for dy := 0; dy < bodySpriteH; dy++ {
		for dx := 0; dx < bodySpriteW; dx++ {
			p := bodySpriteTemplate[dy*bodySpriteW+dx]
			if p == 255 {
				continue
			}
			fx, fy := tlx+dx, tly+dy
			if fx < 0 || fy < 0 || fx >= ScreenWidth || fy >= ScreenHeight {
				continue
			}
			v := p
			switch p {
			case bodyTint:
				v = color
			case bodyTintShadow:
				v = shadowMap[color&0x0f]
			}
			pixels[fy*ScreenWidth+fx] = v
		}
	}
	return pixels
}

func TestFindBodies_Empty(t *testing.T) {
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	if got := FindBodies(pixels); len(got) != 0 {
		t.Fatalf("empty frame: got %d matches, want 0 (first=%+v)", len(got), got[0])
	}
}

func TestFindBodies_One(t *testing.T) {
	const tlx, tly = 40, 50
	pixels := paintBody(tlx, tly, 7) // orange
	got := FindBodies(pixels)
	if len(got) != 1 {
		t.Fatalf("got %d matches, want 1: %+v", len(got), got)
	}
	if got[0].ScreenX != tlx || got[0].ScreenY != tly {
		t.Fatalf("got (%d,%d), want (%d,%d)", got[0].ScreenX, got[0].ScreenY, tlx, tly)
	}
	if got[0].Color != 7 {
		t.Fatalf("color: got %d, want 7", got[0].Color)
	}
}

// Two bodies must both be found, and the dedup radius must not collapse
// distinct sprites.
func TestFindBodies_Two(t *testing.T) {
	a := paintBody(10, 20, 7)
	// Overlay second body at a non-overlapping location.
	b := paintBody(80, 100, 11)
	for i := range a {
		if b[i] != 0 {
			a[i] = b[i]
		}
	}
	got := FindBodies(a)
	if len(got) != 2 {
		t.Fatalf("got %d matches, want 2: %+v", len(got), got)
	}
}

// Noise tolerance: up to bodyMatchMaxMiss stable-pixel corruptions still
// match. Flip 3 outline pixels; match should still succeed.
func TestFindBodies_ToleratesNoise(t *testing.T) {
	pixels := paintBody(30, 30, 3)
	// Corrupt 3 palette-0 pixels at known positions.
	pixels[(30+0)*ScreenWidth+(30+5)] = 15
	pixels[(30+1)*ScreenWidth+(30+4)] = 15
	pixels[(30+7)*ScreenWidth+(30+3)] = 15
	got := FindBodies(pixels)
	if len(got) != 1 {
		t.Fatalf("noisy: got %d matches, want 1", len(got))
	}
}

// BodyWorld must invert the blit coordinate transform.
func TestBodyWorld(t *testing.T) {
	m := BodyMatch{ScreenX: 10, ScreenY: 20}
	cam := Camera{X: 100, Y: 200}
	w := BodyWorld(m, cam)
	// body.x = ScreenX + SpriteDrawOffX + cam.X = 10 + 2 + 100 = 112
	// body.y = ScreenY + SpriteDrawOffY + cam.Y = 20 + 8 + 200 = 228
	if w.X != 112 || w.Y != 228 {
		t.Fatalf("world: got %+v, want {112 228}", w)
	}
}

// A body entirely off-screen should not match (prefilter rejects
// top-lefts whose anchor pixels are clipped).
func TestFindBodies_OffscreenNoMatch(t *testing.T) {
	pixels := paintBody(-20, -20, 7)
	if got := FindBodies(pixels); len(got) != 0 {
		t.Fatalf("offscreen: got %d matches, want 0", len(got))
	}
}

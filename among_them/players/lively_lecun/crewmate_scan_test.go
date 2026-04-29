package main

import "testing"

// paintCrewmate renders the player sprite at (tlx, tly) with the given
// color, over a fresh black frame. Mirrors blitSpriteOutlined (sim.nim
// :1532-1546) + actorColor (sim.nim:1177-1183).
func paintCrewmate(tlx, tly int, color uint8, flipH bool) []uint8 {
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	overlayCrewmate(pixels, tlx, tly, color, flipH)
	return pixels
}

func overlayCrewmate(pixels []uint8, tlx, tly int, color uint8, flipH bool) {
	for dy := 0; dy < playerSpriteH; dy++ {
		for dx := 0; dx < playerSpriteW; dx++ {
			srcX := dx
			if flipH {
				srcX = playerSpriteW - 1 - dx
			}
			p := playerSpriteTemplate[dy*playerSpriteW+srcX]
			if p == 255 {
				continue
			}
			v := p
			switch p {
			case playerTint:
				v = color
			case playerTintShadow:
				v = shadowMap[color&0x0f]
			}
			fx, fy := tlx+dx, tly+dy
			if fx < 0 || fy < 0 || fx >= ScreenWidth || fy >= ScreenHeight {
				continue
			}
			pixels[fy*ScreenWidth+fx] = v
		}
	}
}

func TestFindCrewmates_Empty(t *testing.T) {
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	if got := FindCrewmates(pixels); len(got) != 0 {
		t.Fatalf("empty frame: got %d matches, want 0", len(got))
	}
}

func TestFindCrewmates_One(t *testing.T) {
	pixels := paintCrewmate(20, 30, 7, false) // orange
	got := FindCrewmates(pixels)
	if len(got) != 1 {
		t.Fatalf("got %d, want 1: %+v", len(got), got)
	}
	if got[0].ScreenX != 20 || got[0].ScreenY != 30 {
		t.Fatalf("pos: got (%d,%d), want (20,30)",
			got[0].ScreenX, got[0].ScreenY)
	}
	if got[0].Color != 7 {
		t.Fatalf("color: got %d, want 7", got[0].Color)
	}
	if got[0].FlipH {
		t.Fatalf("flipH: got true, want false")
	}
}

func TestFindCrewmates_Flipped(t *testing.T) {
	pixels := paintCrewmate(40, 40, 11, true)
	got := FindCrewmates(pixels)
	if len(got) != 1 {
		t.Fatalf("got %d, want 1", len(got))
	}
	if !got[0].FlipH {
		t.Fatalf("expected flipH=true")
	}
	if got[0].Color != 11 {
		t.Fatalf("color: got %d, want 11", got[0].Color)
	}
}

func TestFindCrewmates_SelfExcluded(t *testing.T) {
	// Paint the player's own sprite at the known self position.
	pixels := paintCrewmate(playerScreenX, playerScreenY, 13, false)
	got := FindCrewmates(pixels)
	if len(got) != 0 {
		t.Fatalf("self-sprite should be excluded; got %d matches: %+v",
			len(got), got)
	}
}

// Multiple crewmates in the same frame should all match (within the
// self-exclusion zone).
func TestFindCrewmates_Multiple(t *testing.T) {
	pixels := paintCrewmate(10, 10, 7, false)
	overlayCrewmate(pixels, 90, 80, 11, true)
	overlayCrewmate(pixels, 40, 100, 3, false)
	got := FindCrewmates(pixels)
	if len(got) != 3 {
		t.Fatalf("got %d, want 3: %+v", len(got), got)
	}
}

func TestCrewmateWorld(t *testing.T) {
	m := CrewmateMatch{ScreenX: 10, ScreenY: 20}
	cam := Camera{X: 100, Y: 200}
	w := CrewmateWorld(m, cam)
	if w.X != 112 || w.Y != 228 {
		t.Fatalf("world: got %+v, want {112 228}", w)
	}
}

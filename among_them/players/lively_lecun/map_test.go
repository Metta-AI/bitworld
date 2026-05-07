package main

import (
	"os"
	"path/filepath"
	"testing"
)

func loadMapForTest(t *testing.T) *Map {
	t.Helper()
	m, err := LoadMap(filepath.Join("testdata", "skeld_map.bin"))
	if err != nil {
		t.Fatalf("load map: %v", err)
	}
	return m
}

func TestLoadMap_Dimensions(t *testing.T) {
	m := loadMapForTest(t)
	if len(m.Pixels) != MapWidth*MapHeight {
		t.Fatalf("len = %d, want %d", len(m.Pixels), MapWidth*MapHeight)
	}
}

func TestLoadMap_PaletteRange(t *testing.T) {
	m := loadMapForTest(t)
	for i, v := range m.Pixels {
		if v >= 16 {
			t.Fatalf("pixel %d has palette index %d (must be < 16)", i, v)
			break
		}
	}
}

func TestLoadMap_AtBounds(t *testing.T) {
	m := loadMapForTest(t)
	if got := m.At(-1, 0); got != 0 {
		t.Errorf("At(-1, 0) = %d, want 0", got)
	}
	if got := m.At(0, -1); got != 0 {
		t.Errorf("At(0, -1) = %d, want 0", got)
	}
	if got := m.At(MapWidth, 0); got != 0 {
		t.Errorf("At(MapWidth, 0) = %d, want 0", got)
	}
	if got := m.At(0, MapHeight); got != 0 {
		t.Errorf("At(0, MapHeight) = %d, want 0", got)
	}
}

func TestLoadMap_MissingFile(t *testing.T) {
	if _, err := LoadMap(filepath.Join("testdata", "no_such_map.bin")); err == nil {
		t.Error("expected error for missing file")
	}
}

func TestLoadMap_WrongSize(t *testing.T) {
	tmp, err := os.CreateTemp(t.TempDir(), "fakemap-*.bin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tmp.Write([]byte{1, 2, 3}); err != nil {
		t.Fatal(err)
	}
	tmp.Close()
	if _, err := LoadMap(tmp.Name()); err == nil {
		t.Error("expected error for wrong-size map file")
	}
}

// Ground-truth test: pull the camera and player coords for the playing
// fixture out of fixtures.tsv and verify the map at (cameraX+sx, cameraY+sy)
// matches the screen frame at (sx, sy) for sample points away from the
// player sprite. This anchors the M4 localizer's correctness assumption.
func TestMapMatchesPlayingFixture(t *testing.T) {
	m := loadMapForTest(t)
	pixels := loadPhaseFixture(t, "playing")
	meta := loadFixtureMeta(t)
	cam, ok := meta["playing"]
	if !ok {
		t.Fatal("fixtures.tsv missing 'playing' entry")
	}
	// Sample 9 points spread across the screen, skipping the 16x16 player
	// box at the center where the sprite occludes the map.
	hits, samples := 0, 0
	for _, sx := range []int{8, 32, 96, 120} {
		for _, sy := range []int{8, 32, 96, 120} {
			samples++
			screen := pixels[sy*ScreenWidth+sx]
			mp := m.At(cam.CameraX+sx, cam.CameraY+sy)
			if screen == mp {
				hits++
			}
		}
	}
	// Allow ~10% mismatch from sprite/shadow overlay, but a clean match
	// is the point of this test.
	if hits < samples*9/10 {
		t.Errorf("only %d/%d sample pixels matched at recorded camera (cam=%v)", hits, samples, cam)
	}
	t.Logf("map/screen agreement: %d/%d at camera (%d,%d)", hits, samples, cam.CameraX, cam.CameraY)
}

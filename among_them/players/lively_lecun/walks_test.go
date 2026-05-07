package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func loadWalkMaskForTest(t *testing.T) *WalkMask {
	t.Helper()
	w, err := LoadWalkMask(filepath.Join("testdata", "walks.bin"))
	if err != nil {
		t.Fatalf("load walks: %v", err)
	}
	return w
}

func TestLoadWalkMask_Size(t *testing.T) {
	w := loadWalkMaskForTest(t)
	wantBytes := (MapWidth*MapHeight + 7) / 8
	if len(w.Bits) != wantBytes {
		t.Fatalf("len(Bits) = %d, want %d", len(w.Bits), wantBytes)
	}
}

func TestLoadWalkMask_OutOfBounds(t *testing.T) {
	w := loadWalkMaskForTest(t)
	for _, p := range [][2]int{{-1, 0}, {0, -1}, {MapWidth, 0}, {0, MapHeight}, {-100, -100}} {
		if w.Walkable(p[0], p[1]) {
			t.Errorf("Walkable(%d, %d) = true for OOB", p[0], p[1])
		}
	}
}

// Replays testdata/walks_probe.tsv -- the Nim capture tool wrote ground-truth
// walkability for hand-picked points. Verifies our bit-unpacking matches.
func TestWalkMask_ProbeAgreement(t *testing.T) {
	w := loadWalkMaskForTest(t)
	f, err := os.Open(filepath.Join("testdata", "walks_probe.tsv"))
	if err != nil {
		t.Fatalf("open probe: %v", err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	first := true
	probes := 0
	for sc.Scan() {
		if first {
			first = false
			continue
		}
		parts := strings.Split(sc.Text(), "\t")
		if len(parts) != 3 {
			t.Fatalf("bad probe line: %q", sc.Text())
		}
		x := mustAtoi(t, parts[0])
		y := mustAtoi(t, parts[1])
		want, err := strconv.ParseBool(parts[2])
		if err != nil {
			t.Fatalf("bad bool %q: %v", parts[2], err)
		}
		if got := w.Walkable(x, y); got != want {
			t.Errorf("Walkable(%d, %d) = %v, want %v", x, y, got, want)
		}
		probes++
	}
	if probes == 0 {
		t.Fatal("no probes read")
	}
	t.Logf("verified %d probe points", probes)
}

func TestWalkMask_FixturePositionsAreWalkable(t *testing.T) {
	w := loadWalkMaskForTest(t)
	for name, meta := range loadFixtureMeta(t) {
		if !w.Walkable(meta.PlayerX, meta.PlayerY) {
			t.Errorf("fixture %s: player (%d, %d) reported unwalkable", name, meta.PlayerX, meta.PlayerY)
		}
	}
}

func TestLoadWalkMask_WrongSize(t *testing.T) {
	tmp, err := os.CreateTemp(t.TempDir(), "fakewalks-*.bin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tmp.Write([]byte{1, 2, 3}); err != nil {
		t.Fatal(err)
	}
	tmp.Close()
	if _, err := LoadWalkMask(tmp.Name()); err == nil {
		t.Error("expected error for wrong-size walks file")
	}
}

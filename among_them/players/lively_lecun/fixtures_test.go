package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// FixtureMeta is the ground-truth camera + player position for a captured
// playing-phase frame, parsed from testdata/fixtures.tsv.
type FixtureMeta struct {
	CameraX, CameraY int
	PlayerX, PlayerY int
}

func loadFixtureMeta(t *testing.T) map[string]FixtureMeta {
	t.Helper()
	f, err := os.Open(filepath.Join("testdata", "fixtures.tsv"))
	if err != nil {
		t.Fatalf("open fixtures.tsv: %v", err)
	}
	defer f.Close()
	out := map[string]FixtureMeta{}
	sc := bufio.NewScanner(f)
	first := true
	for sc.Scan() {
		line := sc.Text()
		if first {
			first = false
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 5 {
			t.Fatalf("fixtures.tsv malformed line: %q", line)
		}
		fm := FixtureMeta{
			CameraX: mustAtoi(t, fields[1]),
			CameraY: mustAtoi(t, fields[2]),
			PlayerX: mustAtoi(t, fields[3]),
			PlayerY: mustAtoi(t, fields[4]),
		}
		out[fields[0]] = fm
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("scan fixtures.tsv: %v", err)
	}
	return out
}

func mustAtoi(t *testing.T, s string) int {
	t.Helper()
	n, err := strconv.Atoi(s)
	if err != nil {
		t.Fatalf("parse int %q: %v", s, err)
	}
	return n
}

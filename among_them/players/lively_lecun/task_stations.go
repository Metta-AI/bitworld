package main

// TaskStation is the world-space center of a fixed task spawn from
// sim.nim:2440-2481. Every station's box is 16x16; we record the center
// (x+8, y+8) so it lines up with IconToTaskWorld's output. Positions are
// hard-coded in the sim; only the per-player task *subset* is randomized.
type TaskStation struct {
	Name   string
	Center Point
}

// TaskStations is the full list of 41 task-box centers from sim.nim. The
// order matches sim.nim's `result.tasks = @[...]` so station index is
// stable across runs.
var TaskStations = []TaskStation{
	{"Empty Garbage", Point{554 + 8, 465 + 8}},
	{"Upload Data From Communications", Point{667 + 8, 419 + 8}},
	{"Fix Wires", Point{574 + 8, 269 + 8}},
	{"Fix Wires", Point{444 + 8, 31 + 8}},
	{"Fix Wires", Point{510 + 8, 322 + 8}},
	{"Fix Wires", Point{392 + 8, 296 + 8}},
	{"Fix Wires", Point{838 + 8, 222 + 8}},
	{"Download Data", Point{352 + 8, 293 + 8}},
	{"Calibrate Distributor", Point{428 + 8, 295 + 8}},
	{"Submit Scan", Point{400 + 8, 234 + 8}},
	{"Divert Power", Point{372 + 8, 293 + 8}},
	{"Divert Power", Point{760 + 8, 95 + 8}},
	{"Divert Power", Point{868 + 8, 196 + 8}},
	{"Divert Power", Point{186 + 8, 328 + 8}},
	{"Divert Power", Point{202 + 8, 82 + 8}},
	{"Divert Power", Point{297 + 8, 206 + 8}},
	{"Divert Power", Point{146 + 8, 209 + 8}},
	{"Start Reactor", Point{123 + 8, 244 + 8}},
	{"Unlock Manifolds", Point{107 + 8, 186 + 8}},
	{"Divert Power", Point{764 + 8, 349 + 8}},
	{"Prime Shields", Point{703 + 8, 419 + 8}},
	{"Divert Power", Point{715 + 8, 196 + 8}},
	{"Clear Asteroids", Point{731 + 8, 95 + 8}},
	{"Inspect Sample", Point{416 + 8, 222 + 8}},
	{"Upload Data", Point{597 + 8, 267 + 8}},
	{"Align Engine Output", Point{162 + 8, 398 + 8}},
	{"Align Engine Output", Point{162 + 8, 156 + 8}},
	{"Swipe Card", Point{670 + 8, 306 + 8}},
	{"Download Data", Point{612 + 8, 39 + 8}},
	{"Chart Course", Point{896 + 8, 225 + 8}},
	{"Stabilize Steering", Point{888 + 8, 250 + 8}},
	{"Download Data", Point{888 + 8, 196 + 8}},
	{"Download Data", Point{626 + 8, 432 + 8}},
	{"Fuel Engines", Point{486 + 8, 419 + 8}},
	{"Fuel Engines", Point{186 + 8, 393 + 8}},
	{"Fuel Engines", Point{186 + 8, 151 + 8}},
	{"Clean O2 Filter", Point{667 + 8, 197 + 8}},
	{"Download Data", Point{723 + 8, 63 + 8}},
	{"Empty Garbage", Point{630 + 8, 60 + 8}},
	{"Empty Garbage", Point{651 + 8, 212 + 8}},
}

// SnapToStation returns the known station whose center is closest to `p`
// within maxDist (Manhattan). Returns -1 when no station is close enough.
// Use this to reconcile a noisy radar-derived target or a memorized icon
// coord with the canonical spawn list.
func SnapToStation(p Point, maxDist int) int {
	best := -1
	bestD := maxDist + 1
	for i, s := range TaskStations {
		d := manhattan(s.Center, p)
		if d < bestD {
			best, bestD = i, d
		}
	}
	return best
}

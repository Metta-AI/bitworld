package main

// Vent is a world-space vent entry. Vents ported from
// among_them/map.json. Pressing ButtonB while an imposter's collision
// center is within VentRange (sim.nim:42, default 16 world-px) of a
// vent's center teleports the imposter to the next vent in the same
// group (sim.nim:1220-1262 tryVent). Venting imposes a 30-tick
// cooldown server-side, so repeated ButtonB presses after teleport
// are no-ops until the cooldown clears.
type Vent struct {
	Center Point
	Group  string
}

// ventRangeSq mirrors sim.nim: `rangeSq = VentRange * VentRange` with
// VentRange=16. Matched against distSq between the player's collision
// center and the vent's center (sim.nim:1228-1236).
const ventRangeSq = 16 * 16

// Vents is the full vent list from map.json. Centers are (x+w/2, y+h/2);
// each vent is 12x10 so centers are (x+6, y+5).
var Vents = []Vent{
	{Point{600 + 6, 334 + 5}, "A"},
	{Point{736 + 6, 264 + 5}, "A"},
	{Point{634 + 6, 142 + 5}, "A"},
	{Point{724 + 6, 70 + 5}, "B"},
	{Point{874 + 6, 214 + 5}, "B"},
	{Point{740 + 6, 422 + 5}, "C"},
	{Point{874 + 6, 262 + 5}, "C"},
	{Point{336 + 6, 220 + 5}, "D"},
	{Point{352 + 6, 298 + 5}, "D"},
	{Point{296 + 6, 274 + 5}, "D"},
	{Point{88 + 6, 120 + 5}, "E"},
	{Point{132 + 6, 272 + 5}, "E"},
	{Point{242 + 6, 408 + 5}, "E"},
	{Point{110 + 6, 196 + 5}, "F"},
	{Point{242 + 6, 84 + 5}, "F"},
}

// nearestVentInRange returns (index, true) for the closest vent whose
// center is within ventRangeSq world-px of player (Euclidean-sq),
// matching the server's tryVent check. Returns (-1, false) when no
// vent is close enough.
func nearestVentInRange(player Point) (int, bool) {
	best := -1
	bestDist := ventRangeSq + 1
	for i, v := range Vents {
		dx := v.Center.X - player.X
		dy := v.Center.Y - player.Y
		d := dx*dx + dy*dy
		if d <= ventRangeSq && d < bestDist {
			bestDist = d
			best = i
		}
	}
	return best, best >= 0
}

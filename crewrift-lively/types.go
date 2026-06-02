package main

// Point represents a 2D integer coordinate.
type Point struct{ X, Y int }

// manhattan returns the Manhattan distance between two points.
func manhattan(a, b Point) int {
	return absInt(a.X-b.X) + absInt(a.Y-b.Y)
}

// absInt returns the absolute value of an integer.
func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

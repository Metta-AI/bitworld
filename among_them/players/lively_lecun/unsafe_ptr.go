package main

import "unsafe"

// uintptrFrom returns the raw pointer value as a uintptr. It's deliberately
// segregated into its own file so the unsafe import doesn't leak into
// cleaner logic files. Only used to derive a per-Agent RNG seed so
// multi-agent processes don't lockstep on identical decisions.
func uintptrFrom(a *Agent) uintptr {
	return uintptr(unsafe.Pointer(a))
}

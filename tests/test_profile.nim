import bitworld/profile

proc measuredValue(value: int): int {.measure.} =
  ## Returns a value from a measured procedure.
  value

echo "Testing profile shim"
doAssert not profileEnabled(), "profiling should be disabled by default"
doAssert not profileShouldDump(1000), "disabled profiling should never dump"
doAssert measuredValue(7) == 7, "disabled measure pragma should pass through"

var blockRan = false
profileBlock "test block":
  blockRan = true
doAssert blockRan, "disabled profile block should run its body"

startProfileTrace()
finishProfileTrace()

echo "All tests passed"

import
  windy,
  bitworld/scales

echo "Testing scaled window size"
let scaled = ivec2(10, 20).scaledWindowSize(2.0'f)
doAssert scaled == ivec2(20, 40)

let fractional = ivec2(10, 20).scaledWindowSize(1.5'f)
doAssert fractional == ivec2(15, 30)

echo "All tests passed"

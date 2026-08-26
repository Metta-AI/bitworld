import
  windy,
  bitworld/scales

echo "Testing scaled window size"
let scaled = ivec2(10, 20).scaledWindowSize(2.0'f)
doAssert scaled == ivec2(20, 40)

let fractional = ivec2(10, 20).scaledWindowSize(1.5'f)
doAssert fractional == ivec2(15, 30)

echo "Testing UI zoom fits small views"
doAssert uiLayerZoom(900, 640, 320, 91) == 1
doAssert uiLayerZoom(1920, 1080, 320, 91) == 3
doAssert uiLayerZoom(640, 360, 272, 102) == 1
doAssert uiLayerZoom(1920, 1080, 272, 102) == 3
doAssert uiZoomForLayers(
  900, 640,
  [(width: 320, height: 91), (width: 272, height: 102)]
) == 1.0'f
doAssert uiZoomForLayers(1920, 1080, []) == 3.0'f

echo "All tests passed"

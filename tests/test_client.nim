import
  std/[os, strutils],
  bitworld/client

proc assertEndsWith(value, suffix: string) =
  doAssert value.endsWith(suffix), value & " should end with " & suffix

proc testCanonicalCoworldClientRoutes() =
  ## Tests the Coworld client routes required by the Metta package spec.
  echo "Testing canonical Coworld client routes"
  doAssert coworldClientStaticRoute(CoworldPlayerClientRoute) == PlayerClientRoute
  doAssert coworldClientStaticRoute(CoworldGlobalClientRoute) == GlobalClientRoute
  doAssert coworldClientStaticRoute(CoworldReplayClientRoute) == GlobalClientRoute
  doAssert coworldClientStaticRoute(CoworldAdminClientRoute) == AdminClientRoute
  doAssert coworldClientStaticRoute(CoworldRewardClientRoute) == RewardClientRoute
  doAssert coworldClientStaticRoute(CoworldSnappyClientRoute) == SnappyClientRoute
  doAssert coworldClientStaticRoute(CoworldQrcodeClientRoute) == QrcodeClientRoute
  doAssert coworldClientStaticRoute(ReplayClientRoute) == GlobalClientRoute
  doAssert coworldClientStaticRoute("/client/replay.html") == "/client/replay.html"
  doAssert clientStaticPath("/client/replay.html") == ""
  assertEndsWith(clientStaticPath("/client/replay"), "client" / GlobalClientHtml)

proc testClientStaticPaths() =
  ## Tests that public routes resolve to packaged static files.
  echo "Testing client static paths"
  assertEndsWith(clientStaticPath(CoworldPlayerClientRoute), "client" / PlayerClientHtml)
  assertEndsWith(clientStaticPath(CoworldGlobalClientRoute), "client" / GlobalClientHtml)
  assertEndsWith(clientStaticPath(CoworldReplayClientRoute), "client" / GlobalClientHtml)
  assertEndsWith(clientStaticPath(CoworldAdminClientRoute), "client" / AdminClientHtml)
  assertEndsWith(clientStaticPath(CoworldRewardClientRoute), "client" / RewardClientHtml)
  assertEndsWith(clientStaticPath(CoworldSnappyClientRoute), "client" / SnappyClientJs)
  assertEndsWith(clientStaticPath(CoworldQrcodeClientRoute), "client" / QrcodeClientJs)
  doAssert clientStaticContentType(CoworldReplayClientRoute) == "text/html; charset=utf-8"
  doAssert clientStaticContentType(CoworldSnappyClientRoute) == "application/javascript; charset=utf-8"
  doAssert clientStaticContentType(CoworldQrcodeClientRoute) == "application/javascript; charset=utf-8"

proc testReplayClientPreservesUri() =
  ## Tests that the shared replay client forwards Coworld replay URIs.
  echo "Testing replay client URI forwarding"
  let html = readClientHtml(CoworldReplayClientRoute)
  doAssert """["name","slot","token","uri"]""" in html

proc testGlobalClientFullScreenLayers() =
  ## Tests that the shared global/replay client understands full screen layers.
  echo "Testing global client full screen layers"
  let html = readClientHtml(CoworldReplayClientRoute)
  doAssert "FullScreenLayerType=9" in html
  doAssert "function isFullScreenLayer" in html
  doAssert "function layerHasObjects" in html
  doAssert "if(isFullScreenLayer(layer))return 1" in html
  doAssert "Math.max(.000001,Math.min" in html
  doAssert "isFullScreenLayer(layer)||!layerHasObjects(layer)" in html
  doAssert "layerDrawRank" in html

proc testGlobalClientWheelZoomTargetsMap() =
  ## Tests that UI overlays do not block hosted replay map zoom.
  echo "Testing global client wheel zoom target"
  let html = readClientHtml(CoworldReplayClientRoute)
  doAssert "function zoomMapAt(clientX,clientY,deltaY)" in html
  doAssert "const layer=mapLayer();\n  if(!layer)return;" in html
  doAssert "zoomMapAt(event.clientX,event.clientY,event.deltaY);" in html
  doAssert "addEventListener(\"wheel\",event=>{\n  event.preventDefault();\n  const point=mousePoint(event);" notin html

proc testGlobalClientRefitsOnMapViewportChange() =
  ## Tests that a map viewport size change refits even after pan or zoom.
  echo "Testing global client refits on map viewport change"
  let html = readClientHtml(CoworldGlobalClientRoute)
  doAssert "const sizeChanged=layer.width!==width||layer.height!==height;" in html
  doAssert "const wasMap=isMapLayer(layer);" in html
  doAssert "if(wasMap&&sizeChanged)fit();" in html
  doAssert "else maybeFit();" in html

proc testPlayerClientSpeaksSpriteProtocol() =
  ## Tests the shared player client covers the sprite protocol used by bots.
  echo "Testing player client sprite protocol support"
  let html = readClientHtml(CoworldPlayerClientRoute)
  doAssert "new Uint8Array([0x84" in html
  doAssert "b[0]=0x81" in html
  doAssert "k.KeyZ||k.KeyJ" in html
  doAssert "?32:0" in html
  doAssert "k.KeyX||k.KeyK" in html
  doAssert "?64:0" in html
  doAssert "FullScreenLayerType=9" in html
  doAssert "function isFullScreenLayer" in html
  doAssert "if(isFullScreenLayer(layer))return 1" in html
  doAssert "Math.max(.000001,Math.min" in html
  doAssert "function layerScreenPos" in html
  doAssert "layerDrawRank" in html
  for messageType in ["0x01", "0x02", "0x03", "0x04", "0x05", "0x06", "0x07"]:
    doAssert ("type===" & messageType) in html,
      "missing sprite protocol parser case " & messageType

proc testEmbeddedClientBodies() =
  ## Tests that static client bodies are embedded in the library.
  echo "Testing embedded client bodies"
  doAssert clientStaticBody(PlayerClientRoute).startsWith("<!doctype html>")
  doAssert clientStaticBody(GlobalClientRoute).startsWith("<!doctype html>")
  doAssert clientStaticBody(AdminClientRoute).startsWith("<!doctype html>")
  doAssert clientStaticBody(RewardClientRoute).startsWith("<!doctype html>")
  doAssert clientStaticBody(SnappyClientRoute).len > 0
  doAssert clientStaticBody(QrcodeClientRoute).len > 0
  doAssert clientStaticBody("/clients/player").startsWith("<!doctype html>")
  doAssert clientStaticBody("/clients/replay").startsWith("<!doctype html>")

testCanonicalCoworldClientRoutes()
testClientStaticPaths()
testReplayClientPreservesUri()
testGlobalClientFullScreenLayers()
testGlobalClientWheelZoomTargetsMap()
testGlobalClientRefitsOnMapViewportChange()
testPlayerClientSpeaksSpriteProtocol()
testEmbeddedClientBodies()
echo "All tests passed"

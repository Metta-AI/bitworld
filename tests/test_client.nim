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
  doAssert coworldClientStaticRoute(CoworldSpriteRendererClientRoute) ==
    SpriteRendererClientRoute
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
  assertEndsWith(
    clientStaticPath(CoworldSpriteRendererClientRoute),
    "client" / SpriteRendererClientJs
  )
  doAssert clientStaticContentType(CoworldReplayClientRoute) == "text/html; charset=utf-8"
  doAssert clientStaticContentType(CoworldSnappyClientRoute) == "application/javascript; charset=utf-8"
  doAssert clientStaticContentType(CoworldQrcodeClientRoute) == "application/javascript; charset=utf-8"
  doAssert clientStaticContentType(CoworldSpriteRendererClientRoute) ==
    "application/javascript; charset=utf-8"

proc testReplayClientPreservesUri() =
  ## Tests that the shared replay client forwards Coworld replay URIs.
  echo "Testing replay client URI forwarding"
  let html = readClientHtml(CoworldReplayClientRoute)
  doAssert """["name","slot","token","uri"]""" in html

proc testGlobalClientUsesSharedRenderer() =
  ## Tests that the shared global/replay client delegates rendering to the
  ## shared Sprite v1 renderer module.
  echo "Testing global client shared renderer wiring"
  let html = readClientHtml(CoworldReplayClientRoute)
  doAssert "<script src=\"sprite_renderer.js\"></script>" in html
  doAssert "BitworldSpriteRenderer.create(" in html
  doAssert "function zoomMapAt" notin html
  doAssert "function putSpritePixel" notin html
  doAssert "function parse" notin html

proc testGlobalClientWaitsForFreshFrame() =
  ## Tests that reconnecting does not reveal the previous connection's frame.
  echo "Testing global client reconnect frame gating"
  let html = readClientHtml(CoworldReplayClientRoute)
  doAssert "waitingForFrame=true" in html
  doAssert "socket.readyState===WebSocket.OPEN&&!waitingForFrame" in html
  doAssert "waitingForFrame=false;\n      renderer.ingest(bytes);" in html
  doAssert "if(socket===ws){\n      setStatus(\"\");" notin html

proc testSharedRendererFullScreenLayers() =
  ## Tests that the shared renderer understands full screen layers.
  echo "Testing shared renderer full screen layers"
  let renderer = clientStaticBody(CoworldSpriteRendererClientRoute)
  doAssert "FullScreenLayerType = 9" in renderer
  doAssert "function isFullScreenLayer" in renderer
  doAssert "function layerHasObjects" in renderer
  doAssert "if (isFullScreenLayer(layer)) return 1" in renderer
  doAssert "Math.max(0.000001, Math.min(" in renderer
  doAssert "!isFullScreenLayer(layer) || !layerHasObjects(layer)" in renderer
  doAssert "layerDrawRank" in renderer

proc testSharedRendererWheelZoomTargetsMap() =
  ## Tests that UI overlays do not block hosted replay map zoom.
  echo "Testing shared renderer wheel zoom target"
  let renderer = clientStaticBody(CoworldSpriteRendererClientRoute)
  doAssert "function zoomMapAt(clientX, clientY, deltaY)" in renderer
  doAssert "const layer = mapLayer();\n      if (!layer) return;" in renderer
  let html = readClientHtml(CoworldReplayClientRoute)
  doAssert "action:\"wheel\"" in html

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
  doAssert clientStaticBody(SpriteRendererClientRoute).len > 0
  doAssert "BitworldSpriteRenderer" in clientStaticBody(SpriteRendererClientRoute)
  doAssert clientStaticBody("/clients/player").startsWith("<!doctype html>")
  doAssert clientStaticBody("/clients/replay").startsWith("<!doctype html>")

testCanonicalCoworldClientRoutes()
testClientStaticPaths()
testReplayClientPreservesUri()
testGlobalClientUsesSharedRenderer()
testGlobalClientWaitsForFreshFrame()
testSharedRendererFullScreenLayers()
testSharedRendererWheelZoomTargetsMap()
testPlayerClientSpeaksSpriteProtocol()
testEmbeddedClientBodies()
echo "All tests passed"

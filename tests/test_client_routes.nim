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
  doAssert clientStaticContentType(CoworldReplayClientRoute) == "text/html; charset=utf-8"
  doAssert clientStaticContentType(CoworldSnappyClientRoute) == "application/javascript; charset=utf-8"

proc testReplayClientPreservesUri() =
  ## Tests that the shared replay client forwards Coworld replay URIs.
  echo "Testing replay client URI forwarding"
  let html = readFile(clientStaticPath(CoworldReplayClientRoute))
  doAssert """["name","slot","token","uri"]""" in html

proc testPlayerClientSpeaksSpriteProtocol() =
  ## Tests the shared player client covers the sprite protocol used by bots.
  echo "Testing player client sprite protocol support"
  let html = readFile(clientStaticPath(CoworldPlayerClientRoute))
  doAssert "new Uint8Array([0x84" in html
  doAssert "b[0]=0x81" in html
  doAssert "k.KeyZ||k.KeyJ" in html
  doAssert "?32:0" in html
  doAssert "k.KeyX||k.KeyK" in html
  doAssert "?64:0" in html
  for messageType in ["0x01", "0x02", "0x03", "0x04", "0x05", "0x06", "0x07"]:
    doAssert ("type===" & messageType) in html,
      "missing sprite protocol parser case " & messageType

testCanonicalCoworldClientRoutes()
testClientStaticPaths()
testReplayClientPreservesUri()
testPlayerClientSpeaksSpriteProtocol()
echo "All tests passed"

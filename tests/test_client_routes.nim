import
  std/[os, strutils],
  bitworld/clients

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
  doAssert coworldClientStaticRoute("/clients/replay.html") == "/clients/replay.html"
  doAssert clientStaticPath("/clients/replay.html") == ""
  doAssert clientStaticPath("/client/replay") == ""

proc testClientStaticPaths() =
  ## Tests that public routes resolve to packaged static files.
  echo "Testing client static paths"
  assertEndsWith(clientStaticPath(CoworldPlayerClientRoute), "clients" / PlayerClientHtml)
  assertEndsWith(clientStaticPath(CoworldGlobalClientRoute), "clients" / GlobalClientHtml)
  assertEndsWith(clientStaticPath(CoworldReplayClientRoute), "clients" / GlobalClientHtml)
  assertEndsWith(clientStaticPath(CoworldAdminClientRoute), "clients" / AdminClientHtml)
  assertEndsWith(clientStaticPath(CoworldRewardClientRoute), "clients" / RewardClientHtml)
  assertEndsWith(clientStaticPath(CoworldSnappyClientRoute), "clients" / SnappyClientJs)
  doAssert clientStaticContentType(CoworldReplayClientRoute) == "text/html; charset=utf-8"
  doAssert clientStaticContentType(CoworldSnappyClientRoute) == "application/javascript; charset=utf-8"

testCanonicalCoworldClientRoutes()
testClientStaticPaths()
echo "All tests passed"

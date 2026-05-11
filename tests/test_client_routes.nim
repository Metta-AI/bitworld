import
  std/[os, strutils],
  bitworld/clients

proc assertEndsWith(value, suffix: string) =
  doAssert value.endsWith(suffix), value & " should end with " & suffix

proc testCoworldClientRouteAliases() =
  ## Tests the Coworld client routes required by the Metta package spec.
  echo "Testing Coworld client route aliases"
  doAssert canonicalClientRoute("/clients/player") == PlayerClientRoute
  doAssert canonicalClientRoute("/clients/global") == GlobalClientRoute
  doAssert canonicalClientRoute("/clients/replay") == GlobalClientRoute
  doAssert canonicalClientRoute("/clients/admin") == AdminClientRoute
  doAssert canonicalClientRoute("/clients/rewards") == RewardClientRoute
  doAssert canonicalClientRoute("/clients/snappyjs.min.js") == SnappyClientRoute
  doAssert canonicalClientRoute("/clients/qrcode.min.js") == QrcodeClientRoute

proc testClientStaticPaths() =
  ## Tests that public routes resolve to packaged static files.
  echo "Testing client static paths"
  assertEndsWith(clientStaticPath("/clients/player"), "clients" / PlayerClientHtml)
  assertEndsWith(clientStaticPath("/clients/global"), "clients" / GlobalClientHtml)
  assertEndsWith(clientStaticPath("/clients/replay"), "clients" / GlobalClientHtml)
  assertEndsWith(clientStaticPath("/clients/admin"), "clients" / AdminClientHtml)
  assertEndsWith(clientStaticPath("/clients/rewards"), "clients" / RewardClientHtml)
  assertEndsWith(clientStaticPath("/clients/snappyjs.min.js"), "clients" / SnappyClientJs)
  doAssert clientStaticContentType("/clients/replay") == "text/html; charset=utf-8"
  doAssert clientStaticContentType("/clients/snappyjs.min.js") == "application/javascript; charset=utf-8"

testCoworldClientRouteAliases()
testClientStaticPaths()
echo "All tests passed"

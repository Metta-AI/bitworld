import
  std/os,
  mummy

const
  PlayerClientRoute* = "/client/player"
  GlobalClientRoute* = "/client/global"
  AdminClientRoute* = "/client/admin"
  RewardClientRoute* = "/client/reward"
  PlayerClientPath* = PlayerClientRoute
  GlobalClientPath* = GlobalClientRoute
  AdminClientPath* = AdminClientRoute
  RewardClientPath* = RewardClientRoute
  RewardsClientPath* = "/client/rewards"
  PlayerClientHtmlRoute* = "/client/player.html"
  GlobalClientHtmlRoute* = "/client/global.html"
  AdminClientHtmlRoute* = "/client/admin.html"
  RewardClientHtmlRoute* = "/client/rewards.html"
  SnappyClientRoute* = "/snappyjs.min.js"
  QrcodeClientRoute* = "/qrcode.min.js"
  SpriteRendererClientRoute* = "/sprite_renderer.js"
  ReplayClientRoute* = "/client/replay"
  SnappyClientPath* = "/client/snappyjs.min.js"
  QrcodeClientPath* = "/client/qrcode.min.js"
  SpriteRendererClientPath* = "/client/sprite_renderer.js"
  CoworldPlayerClientRoute* = "/clients/player"
  CoworldGlobalClientRoute* = "/clients/global"
  CoworldReplayClientRoute* = "/clients/replay"
  CoworldAdminClientRoute* = "/clients/admin"
  CoworldRewardClientRoute* = "/clients/rewards"
  CoworldSnappyClientRoute* = "/clients/snappyjs.min.js"
  CoworldQrcodeClientRoute* = "/clients/qrcode.min.js"
  CoworldSpriteRendererClientRoute* = "/clients/sprite_renderer.js"
  PlayerClientHtml* = "player_client.html"
  GlobalClientHtml* = "global_client.html"
  AdminClientHtml* = "admin_client.html"
  RewardClientHtml* = "reward_client.html"
  SnappyClientJs* = "snappyjs.min.js"
  QrcodeClientJs* = "qrcode.min.js"
  SpriteRendererClientJs* = "sprite_renderer.js"
  EmbeddedPlayerClientHtml* = staticRead("../../client/player_client.html")
  EmbeddedGlobalClientHtml* = staticRead("../../client/global_client.html")
  EmbeddedAdminClientHtml* = staticRead("../../client/admin_client.html")
  EmbeddedRewardClientHtml* = staticRead("../../client/reward_client.html")
  EmbeddedSnappyClientJs* = staticRead("../../client/snappyjs.min.js")
  EmbeddedQrcodeClientJs* = staticRead("../../client/qrcode.min.js")
  EmbeddedSpriteRendererClientJs* = staticRead("../../client/sprite_renderer.js")

proc repoDir*(): string =
  ## Returns the Bit World repository directory.
  currentSourcePath().parentDir().parentDir().parentDir()

proc clientDir*(): string =
  ## Returns the shared client directory. Resolved at runtime relative
  ## to CWD so it works both from the repo root (./client) and from a
  ## packaged install (../client next to the chdir'd binary), mirroring
  ## clientDataDir()'s strategy. OSError is trapped so callers can keep
  ## a tight {.raises: [IOError].} contract.
  when defined(emscripten):
    "client"
  else:
    try:
      let cwd = getCurrentDir()
      let sibling = cwd / ".." / "client"
      if dirExists(sibling):
        sibling
      elif dirExists(repoDir() / "client"):
        repoDir() / "client"
      else:
        cwd / "client"
    except OSError:
      "client"

proc clientRoute*(route: string, playerRoute = PlayerClientRoute): string =
  ## Maps public client aliases to the underlying shared client route.
  case route
  of PlayerClientRoute, PlayerClientHtmlRoute,
      "/client/player_client.html", CoworldPlayerClientRoute:
    playerRoute
  of ReplayClientRoute, CoworldReplayClientRoute,
      GlobalClientRoute, GlobalClientHtmlRoute,
      "/client/global_client.html", CoworldGlobalClientRoute:
    GlobalClientRoute
  of AdminClientRoute, AdminClientHtmlRoute, CoworldAdminClientRoute:
    AdminClientRoute
  of RewardClientRoute, RewardsClientPath,
      RewardClientHtmlRoute, "/client/reward.html",
      "/client/reward_client.html", CoworldRewardClientRoute:
    RewardClientRoute
  of SnappyClientPath, CoworldSnappyClientRoute:
    SnappyClientRoute
  of QrcodeClientPath, CoworldQrcodeClientRoute:
    QrcodeClientRoute
  of SpriteRendererClientPath, CoworldSpriteRendererClientRoute:
    SpriteRendererClientRoute
  else:
    route

proc coworldClientStaticRoute*(route: string): string =
  ## Returns the packaged static asset route for one canonical Coworld route.
  clientRoute(route)

proc clientHtmlPath*(route: string, playerRoute = PlayerClientRoute): string =
  ## Returns the local HTML file for a served client route.
  case clientRoute(route, playerRoute)
  of PlayerClientRoute:
    clientDir() / PlayerClientHtml
  of GlobalClientRoute:
    clientDir() / GlobalClientHtml
  of RewardClientRoute:
    clientDir() / RewardClientHtml
  of AdminClientRoute:
    clientDir() / AdminClientHtml
  else:
    ""

proc clientStaticPath*(route: string, playerRoute = PlayerClientRoute): string =
  ## Returns the local static client file for a served client route.
  case clientRoute(route, playerRoute)
  of SnappyClientRoute:
    clientDir() / SnappyClientJs
  of QrcodeClientRoute:
    clientDir() / QrcodeClientJs
  of SpriteRendererClientRoute:
    clientDir() / SpriteRendererClientJs
  else:
    clientHtmlPath(route, playerRoute)

proc clientStaticContentType*(
  route: string,
  playerRoute = PlayerClientRoute
): string =
  ## Returns the content type for a served static client file.
  case clientRoute(route, playerRoute)
  of SnappyClientRoute, QrcodeClientRoute, SpriteRendererClientRoute:
    "application/javascript; charset=utf-8"
  else:
    "text/html; charset=utf-8"

proc clientStaticBody*(
  route: string,
  playerRoute = PlayerClientRoute
): string =
  ## Returns the embedded static client body for one route.
  case clientRoute(route, playerRoute)
  of PlayerClientRoute:
    EmbeddedPlayerClientHtml
  of GlobalClientRoute:
    EmbeddedGlobalClientHtml
  of AdminClientRoute:
    EmbeddedAdminClientHtml
  of RewardClientRoute:
    EmbeddedRewardClientHtml
  of SnappyClientRoute:
    EmbeddedSnappyClientJs
  of QrcodeClientRoute:
    EmbeddedQrcodeClientJs
  of SpriteRendererClientRoute:
    EmbeddedSpriteRendererClientJs
  else:
    ""

proc readClientHtml*(
  route: string,
  playerRoute = PlayerClientRoute
): string {.raises: [IOError].} =
  ## Reads the embedded HTML for a served client route.
  let body = clientStaticBody(route, playerRoute)
  if body.len == 0:
    raise newException(IOError, "unknown client route: " & route)
  body

proc serveClientFile*(
  request: Request,
  route: string,
  playerRoute = PlayerClientRoute
): bool =
  ## Serves one embedded static client file.
  if request.httpMethod != "GET":
    return false
  let body = clientStaticBody(route, playerRoute)
  if body.len == 0:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(route, playerRoute)
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, body)
  true

proc serveClientRoute*(
  request: Request,
  playerRoute = PlayerClientRoute
): bool =
  ## Serves the embedded static client file for the request path.
  request.serveClientFile(request.path, playerRoute)

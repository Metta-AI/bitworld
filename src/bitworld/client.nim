import std/os

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
  SnappyClientPath* = "/client/snappyjs.min.js"
  QrcodeClientPath* = "/client/qrcode.min.js"
  CoworldPlayerClientRoute* = PlayerClientRoute
  CoworldGlobalClientRoute* = GlobalClientRoute
  CoworldReplayClientRoute* = "/client/replay"
  CoworldAdminClientRoute* = AdminClientRoute
  CoworldRewardClientRoute* = RewardsClientPath
  CoworldSnappyClientRoute* = SnappyClientPath
  CoworldQrcodeClientRoute* = QrcodeClientPath
  PlayerClientHtml* = "player_client.html"
  GlobalClientHtml* = "global_client.html"
  AdminClientHtml* = "admin_client.html"
  RewardClientHtml* = "reward_client.html"
  SnappyClientJs* = "snappyjs.min.js"
  QrcodeClientJs* = "qrcode.min.js"

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
  of PlayerClientRoute, PlayerClientHtmlRoute:
    playerRoute
  of CoworldReplayClientRoute, GlobalClientRoute,
      GlobalClientHtmlRoute, "/client/global_client.html":
    GlobalClientRoute
  of AdminClientRoute, AdminClientHtmlRoute:
    AdminClientRoute
  of RewardClientRoute, RewardsClientPath,
      RewardClientHtmlRoute, "/client/reward.html",
      "/client/reward_client.html":
    RewardClientRoute
  of SnappyClientPath:
    SnappyClientRoute
  of QrcodeClientPath:
    QrcodeClientRoute
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
  else:
    clientHtmlPath(route, playerRoute)

proc clientStaticContentType*(
  route: string,
  playerRoute = PlayerClientRoute
): string =
  ## Returns the content type for a served static client file.
  case clientRoute(route, playerRoute)
  of SnappyClientRoute, QrcodeClientRoute:
    "application/javascript; charset=utf-8"
  else:
    "text/html; charset=utf-8"

proc readClientHtml*(
  route: string,
  playerRoute = PlayerClientRoute
): string {.raises: [IOError].} =
  ## Reads the HTML for a served client route.
  readFile(clientHtmlPath(route, playerRoute))

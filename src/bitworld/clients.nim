import std/os

const
  PlayerClientRoute* = "/client/player.html"
  GlobalClientRoute* = "/client/global.html"
  AdminClientRoute* = "/client/admin.html"
  RewardClientRoute* = "/client/rewards.html"
  SnappyClientRoute* = "/snappyjs.min.js"
  QrcodeClientRoute* = "/qrcode.min.js"
  CoworldPlayerClientRoute* = "/clients/player"
  CoworldGlobalClientRoute* = "/clients/global"
  CoworldReplayClientRoute* = "/clients/replay"
  CoworldAdminClientRoute* = "/clients/admin"
  CoworldRewardClientRoute* = "/clients/rewards"
  CoworldSnappyClientRoute* = "/clients/snappyjs.min.js"
  CoworldQrcodeClientRoute* = "/clients/qrcode.min.js"
  PlayerClientHtml* = "player_client.html"
  GlobalClientHtml* = "global_client.html"
  AdminClientHtml* = "admin_client.html"
  RewardClientHtml* = "reward_client.html"
  SnappyClientJs* = "snappyjs.min.js"
  QrcodeClientJs* = "qrcode.min.js"

proc repoDir*(): string =
  ## Returns the Bit World repository directory.
  currentSourcePath().parentDir().parentDir().parentDir()

proc clientsDir*(): string =
  ## Returns the shared clients directory. Resolved at runtime relative
  ## to CWD so it works both from the repo root (./clients) and from a
  ## packaged install (../clients next to the chdir'd binary), mirroring
  ## clientDataDir()'s strategy. OSError is trapped so callers can keep
  ## a tight {.raises: [IOError].} contract.
  when defined(emscripten):
    "clients"
  else:
    try:
      let cwd = getCurrentDir()
      let sibling = cwd / ".." / "clients"
      if dirExists(sibling): sibling
      else: cwd / "clients"
    except OSError:
      "clients"

proc coworldClientStaticRoute*(route: string): string =
  ## Returns the packaged static asset route for one canonical Coworld route.
  case route
  of CoworldPlayerClientRoute:
    PlayerClientRoute
  of CoworldGlobalClientRoute:
    GlobalClientRoute
  of CoworldReplayClientRoute:
    GlobalClientRoute
  of CoworldAdminClientRoute:
    AdminClientRoute
  of CoworldRewardClientRoute:
    RewardClientRoute
  of CoworldSnappyClientRoute:
    SnappyClientRoute
  of CoworldQrcodeClientRoute:
    QrcodeClientRoute
  else:
    route

proc clientHtmlPath*(route: string): string =
  ## Returns the local HTML file for a served client route.
  case coworldClientStaticRoute(route)
  of PlayerClientRoute:
    clientsDir() / PlayerClientHtml
  of GlobalClientRoute:
    clientsDir() / GlobalClientHtml
  of RewardClientRoute:
    clientsDir() / RewardClientHtml
  of AdminClientRoute:
    clientsDir() / AdminClientHtml
  else:
    ""

proc clientStaticPath*(route: string): string =
  ## Returns the local static client file for a served client route.
  case coworldClientStaticRoute(route)
  of SnappyClientRoute:
    clientsDir() / SnappyClientJs
  of QrcodeClientRoute:
    clientsDir() / QrcodeClientJs
  else:
    clientHtmlPath(route)

proc clientStaticContentType*(route: string): string =
  ## Returns the content type for a served static client file.
  case coworldClientStaticRoute(route)
  of SnappyClientRoute, QrcodeClientRoute:
    "application/javascript; charset=utf-8"
  else:
    "text/html; charset=utf-8"

proc readClientHtml*(route: string): string {.raises: [IOError].} =
  ## Reads the HTML for a served client route.
  readFile(clientHtmlPath(route))

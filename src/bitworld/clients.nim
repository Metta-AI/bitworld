import std/os

const
  PlayerClientRoute* = "/client/player.html"
  GlobalClientRoute* = "/client/global.html"
  RewardClientRoute* = "/client/rewards.html"
  SnappyClientRoute* = "/client/snappyjs.min.js"
  StatsClientRoute* = "/client/stats.html"
  PlayerClientHtml* = "player_client.html"
  GlobalClientHtml* = "global_client.html"
  RewardClientHtml* = "reward_client.html"
  SnappyClientJs* = "snappyjs.min.js"
  StatsClientHtml* = "stats.html"

proc repoDir*(): string =
  ## Returns the Bit World repository directory.
  currentSourcePath().parentDir().parentDir().parentDir()

proc clientsDir*(): string =
  ## Returns the shared clients directory.
  repoDir() / "clients"

proc clientHtmlPath*(route: string): string =
  ## Returns the local HTML file for a served client route.
  case route
  of PlayerClientRoute:
    clientsDir() / PlayerClientHtml
  of GlobalClientRoute:
    clientsDir() / GlobalClientHtml
  of RewardClientRoute:
    clientsDir() / RewardClientHtml
  of StatsClientRoute:
    clientsDir() / StatsClientHtml
  else:
    ""

proc clientStaticPath*(route: string): string =
  ## Returns the local static client file for a served client route.
  case route
  of SnappyClientRoute:
    clientsDir() / SnappyClientJs
  else:
    clientHtmlPath(route)

proc clientStaticContentType*(route: string): string =
  ## Returns the content type for a served static client file.
  case route
  of SnappyClientRoute:
    "application/javascript; charset=utf-8"
  else:
    "text/html; charset=utf-8"

proc readClientHtml*(route: string): string {.raises: [IOError].} =
  ## Reads the HTML for a served client route.
  readFile(clientHtmlPath(route))

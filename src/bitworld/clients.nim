import std/os

const
  PlayerClientRoute* = "/client/player.html"
  GlobalClientRoute* = "/client/global.html"
  RewardClientRoute* = "/client/rewards.html"
  PlayerClientHtml* = "player_client.html"
  GlobalClientHtml* = "global_client.html"
  RewardClientHtml* = "reward_client.html"

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
  else:
    ""

proc readClientHtml*(route: string): string {.raises: [IOError].} =
  ## Reads the HTML for a served client route.
  readFile(clientHtmlPath(route))

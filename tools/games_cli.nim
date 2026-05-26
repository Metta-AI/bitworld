## CLI for bitworld's local games_server. Wraps the existing HTTP form
## endpoints so a session can launch/inspect/stop games without using the
## web UI. Run with `nim r tools/games_cli.nim <subcommand> [args]`.
##
## Subcommands:
##   launch <manifest> [--bot NAME[=N]]... [--bots N] [--json]
##   list [--json]
##   stop <game-name>
##   logs <container-name> [--tail N]
##   health <game-name> [--json]
##   manifests [--json]
##   bots <manifest> [--json]

import
  std/[httpclient, json, os, osproc, strutils, uri]

const
  DefaultServerUrl = "http://127.0.0.1:2080"
  GameContainerLabel = "bitworld.games_server=among_them"
  PortLabel = "bitworld.games_server.port"
  GameManifestLabel = "bitworld.games_server.manifest"

proc die(msg: string) {.noreturn.} =
  stderr.writeLine "games_cli: " & msg
  quit(1)

proc serverUrl(): string =
  getEnv("GAMES_SERVER_URL", DefaultServerUrl).strip(chars = {'/'})

proc repoRoot(): string =
  ## Returns the Bitworld repo root used to find the server upload area.
  let envRoot = getEnv("GAMES_SERVER_REPO_ROOT", "")
  if envRoot.len > 0:
    return envRoot
  currentSourcePath().parentDir().parentDir()

proc uploadGamesDir(): string =
  ## Returns the games_server upload directory for Coworld manifests.
  getEnv("GAMES_SERVER_UPLOAD_GAMES_DIR", repoRoot() / "games_server" / "games")

proc manifestPathCandidates(manifest: string): seq[string] =
  ## Returns upload-area candidates for one manifest key or path.
  let uploadDir = uploadGamesDir()
  result.add(uploadDir / manifest)
  result.add(uploadDir / manifest / "coworld_manifest.json")
  result.add(manifest)
  result.add(manifest / "coworld_manifest.json")

proc findManifestPath(manifest: string): string =
  ## Finds an uploaded manifest path without exiting.
  for path in manifestPathCandidates(manifest):
    if path.len > 0 and fileExists(path):
      return path

proc resolveManifestPath(manifest: string): string =
  ## Resolves a manifest only from the games_server upload area.
  result = findManifestPath(manifest)
  if result.len > 0:
    return
  die("manifest not found: " & manifest)

proc manifestKey(manifest: string): string =
  ## Server-side key relative to the uploaded manifest area when possible.
  var path = manifest.strip()
  let found = findManifestPath(path)
  if found.len > 0:
    path = found
  else:
    return path.replace("\\", "/")
  let prefix = uploadGamesDir() & DirSep
  if path.startsWith(prefix):
    return path[prefix.len .. ^1].replace("\\", "/")
  path.replace("\\", "/")

proc playerIds(manifestPath: string): seq[string] =
  ## Reads `player[].id` from a v2 Coworld manifest.
  let node = parseJson(readFile(manifestPath))
  if node.kind != JObject or not node.hasKey("player") or
      node["player"].kind != JArray:
    return
  for player in node["player"]:
    if player.kind == JObject and player.hasKey("id") and
        player["id"].kind == JString:
      result.add(player["id"].getStr())

proc botCountField(playerId: string): string =
  ## Mirrors `botCountField` in games_server.nim: keep alphanumeric, `_`,
  ## `-`, then append `Bots`.
  for c in playerId:
    if c.isAlphaNumeric() or c == '_' or c == '-':
      result.add(c)
  result.add("Bots")

type BotSpec = object
  name: string
  count: int

proc parseBotSpec(raw: string, defaultCount: int): BotSpec =
  let parts = raw.split({'=', ':'}, maxsplit = 1)
  if parts.len == 1:
    BotSpec(name: parts[0], count: defaultCount)
  else:
    BotSpec(name: parts[0], count: parseInt(parts[1].strip()))

proc urlEncodeForm(fields: seq[(string, string)]): string =
  ## URL-encodes a form body. `encodeUrl` on Nim turns space into `+`
  ## which is the correct form-encoding for `application/x-www-form-urlencoded`.
  var parts: seq[string]
  for (key, value) in fields:
    parts.add(encodeUrl(key) & "=" & encodeUrl(value))
  parts.join("&")

proc postForm(path: string, fields: seq[(string, string)]): Response =
  ## POSTs a form body and returns the raw response (no redirect follow).
  var client = newHttpClient(maxRedirects = 0)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/x-www-form-urlencoded"
  })
  client.request(serverUrl() & path, httpMethod = HttpPost,
    body = urlEncodeForm(fields))

proc parseCreatedName(location: string): string =
  ## Reads the new container name out of the create redirect Location
  ## header, which is shaped like `/?notice=created+<name>`.
  const Prefix = "/?notice=created+"
  let idx = location.find(Prefix)
  if idx < 0:
    return ""
  decodeUrl(location[idx + Prefix.len .. ^1]).strip()

proc dockerLines(args: openArray[string]): seq[string] =
  ## Runs `docker <args>` and returns stdout lines (strip trailing blanks).
  let (output, code) = execCmdEx("docker " & args.join(" "))
  if code != 0:
    die("docker " & args.join(" ") & " failed:\n" & output)
  for line in output.splitLines():
    if line.len > 0:
      result.add(line)

proc gameNames(): seq[string] =
  ## Returns names of game containers managed by games_server.
  dockerLines(["ps", "--filter", "label=" & GameContainerLabel,
    "--format", "{{.Names}}"])

proc inspectLabel(name, label: string): string =
  let (output, code) = execCmdEx(
    "docker inspect --format '{{ index .Config.Labels \"" & label &
    "\" }}' " & name
  )
  if code != 0:
    die("docker inspect " & name & " failed:\n" & output)
  output.strip()

proc containerStatus(name: string): string =
  let (output, code) = execCmdEx(
    "docker inspect --format '{{.State.Status}}' " & name)
  if code != 0:
    die("docker inspect " & name & " failed:\n" & output)
  output.strip()

proc containerPort(name: string): int =
  let label = inspectLabel(name, PortLabel)
  if label.len == 0:
    return 0
  parseInt(label)

# --- subcommands --------------------------------------------------------

proc cmdManifests(asJson: bool) =
  let
    uploadDir = uploadGamesDir()
    prefix = uploadDir & DirSep
  var entries: seq[string]
  if dirExists(uploadDir):
    for path in walkFiles(uploadDir / "*.json"):
      let key = path[prefix.len .. ^1].replace("\\", "/")
      if key notin entries:
        entries.add(key)
    for path in walkFiles(uploadDir / "*" / "coworld_manifest.json"):
      let key = path[prefix.len .. ^1].replace("\\", "/")
      if key notin entries:
        entries.add(key)
  if asJson:
    echo($(%entries))
  else:
    if entries.len == 0:
      echo "(no manifests)"
    else:
      for name in entries:
        echo name

proc cmdBots(manifest: string, asJson: bool) =
  let path = resolveManifestPath(manifest)
  let ids = playerIds(path)
  if asJson:
    var node = newJArray()
    for id in ids:
      node.add(%*{"id": id, "field": botCountField(id)})
    echo($node)
  else:
    if ids.len == 0:
      echo "(no v2 player entries in manifest)"
      return
    for id in ids:
      echo id & "  (form field: " & botCountField(id) & ")"

proc cmdLaunch(manifest: string, bots: seq[BotSpec], asJson: bool) =
  let key = manifestKey(manifest)
  var ids: seq[string]
  try:
    ids = playerIds(resolveManifestPath(manifest))
  except CatchableError:
    discard
  var fields = @[("manifest", key)]
  var resolved: seq[BotSpec]
  if bots.len == 0 and ids.len > 0:
    # No explicit bot spec: send 0 for each known type — server accepts that.
    for id in ids:
      resolved.add(BotSpec(name: id, count: 0))
  for spec in bots:
    if spec.name == "all" or spec.name == "*":
      if ids.len == 0:
        die("--bots requires an uploaded manifest key with player entries")
      for id in ids:
        resolved.add(BotSpec(name: id, count: spec.count))
    else:
      if ids.len > 0 and spec.name notin ids:
        die("unknown player id '" & spec.name & "'. known: " & ids.join(", "))
      resolved.add(spec)
  for spec in resolved:
    fields.add((botCountField(spec.name), $spec.count))
  let resp = postForm("/games/create", fields)
  if resp.status.startsWith("302") or resp.status.startsWith("303"):
    let name = parseCreatedName(resp.headers.getOrDefault("location"))
    if name.len == 0:
      die("create succeeded but no game name in redirect: " &
        resp.headers.getOrDefault("location"))
    let port = containerPort(name)
    if asJson:
      echo($(%*{"name": name, "port": port}))
    else:
      echo "launched: " & name
      echo "port:     " & (if port > 0: $port else: "(unknown)")
      echo "viewer:   http://127.0.0.1:" & $port & "/client/global"
  else:
    die("create failed: HTTP " & resp.status & "\n" & resp.body)

proc cmdList(asJson: bool) =
  let names = gameNames()
  if asJson:
    var arr = newJArray()
    for name in names:
      arr.add(%*{
        "name": name,
        "port": containerPort(name),
        "status": containerStatus(name),
        "manifest": inspectLabel(name, GameManifestLabel)
      })
    echo($arr)
  else:
    if names.len == 0:
      echo "(no game containers)"
      return
    for name in names:
      let port = containerPort(name)
      let portStr = if port > 0: $port else: "?"
      echo name & "  port=" & portStr & "  status=" & containerStatus(name)

proc cmdStop(name: string) =
  let resp = postForm("/games/stop", @[("name", name)])
  if not (resp.status.startsWith("302") or resp.status.startsWith("303") or
      resp.status.startsWith("200")):
    die("stop failed: HTTP " & resp.status & "\n" & resp.body)
  echo "stopped: " & name

proc cmdLogs(name: string, tail: int) =
  let args = if tail > 0:
      @["logs", "--tail", $tail, name]
    else:
      @["logs", name]
  let (output, _) = execCmdEx("docker " & args.join(" "))
  stdout.write(output)

proc cmdHealth(name: string, asJson: bool) =
  let port = containerPort(name)
  if port <= 0:
    die("no port label on " & name)
  let url = "http://127.0.0.1:" & $port & "/healthz"
  var client = newHttpClient(timeout = 1000)
  defer: client.close()
  var ok = false
  var body = ""
  try:
    body = client.getContent(url)
    ok = true
  except CatchableError as e:
    body = e.msg
  if asJson:
    echo($(%*{
      "name": name, "port": port, "url": url, "ok": ok, "body": body
    }))
  else:
    if ok:
      echo "healthy: " & name & "  (port " & $port & ", body: " & body & ")"
    else:
      die("unhealthy: " & name & " — " & body)

# --- arg parsing --------------------------------------------------------

proc usage() {.noreturn.} =
  echo """usage: nim r tools/games_cli.nim <command> [args]

commands:
  launch <manifest> [--bot NAME=N]... [--bots N] [--json]
  list [--json]
  stop <game-name>
  logs <container-name> [--tail N]
  health <game-name> [--json]
  manifests [--json]
  bots <manifest> [--json]

env:
  GAMES_SERVER_URL      base URL (default http://127.0.0.1:2080)
  GAMES_SERVER_REPO_ROOT  bitworld repo root for upload lookup
  GAMES_SERVER_UPLOAD_GAMES_DIR  uploaded manifest directory
"""
  quit(0)

proc consumeValue(name, inline: string, params: seq[string], idx: var int): string =
  ## Returns the value for a flag, accepting `--flag=value`, `--flag:value`,
  ## or `--flag value` forms.
  if inline.len > 0:
    return inline
  if idx + 1 >= params.len:
    die("--" & name & " requires a value")
  inc idx
  params[idx]

proc main() =
  let params = commandLineParams()
  var args: seq[string]
  var asJson = false
  var botSpecs: seq[BotSpec]
  var defaultCount = -1
  var tail = 0
  var i = 0
  while i < params.len:
    let p = params[i]
    if p == "--" or (not p.startsWith("-")):
      args.add(p)
      inc i
      continue
    var name = p
    var inline = ""
    name.removePrefix("--")
    name.removePrefix("-")
    let eq = name.find({'=', ':'})
    if eq >= 0:
      inline = name[eq + 1 .. ^1]
      name = name[0 .. eq - 1]
    case name
    of "json", "j":
      asJson = true
    of "bot":
      botSpecs.add(parseBotSpec(
        consumeValue(name, inline, params, i), 1))
    of "bots":
      defaultCount = parseInt(consumeValue(name, inline, params, i))
    of "tail":
      tail = parseInt(consumeValue(name, inline, params, i))
    of "help", "h":
      usage()
    else:
      die("unknown flag --" & name)
    inc i
  if args.len == 0:
    usage()
  if defaultCount >= 0:
    botSpecs.add(BotSpec(name: "all", count: defaultCount))
  let cmd = args[0]
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  case cmd
  of "launch":
    if rest.len < 1: die("launch requires <manifest>")
    cmdLaunch(rest[0], botSpecs, asJson)
  of "list":
    cmdList(asJson)
  of "stop":
    if rest.len < 1: die("stop requires <game-name>")
    cmdStop(rest[0])
  of "logs":
    if rest.len < 1: die("logs requires <container-name>")
    cmdLogs(rest[0], tail)
  of "health":
    if rest.len < 1: die("health requires <game-name>")
    cmdHealth(rest[0], asJson)
  of "manifests":
    cmdManifests(asJson)
  of "bots":
    if rest.len < 1: die("bots requires <manifest>")
    cmdBots(rest[0], asJson)
  of "help", "-h", "--help": usage()
  else: die("unknown command: " & cmd)

when isMainModule:
  main()

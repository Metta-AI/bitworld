import
  std/[algorithm, math, os, parseopt, strutils, tables, times],
  mummy,
  bitworld/multiruns

const
  DefaultHost = "0.0.0.0"
  DefaultPort = 2082
  RunPath = "/run"
  ScoresPath = "/scores"
  DownloadPath = "/download"
  ReplayPlayPath = "/replays/play"
  GlobalClientPath = "/client/global"
  PageCss = """
body {
  margin: 0;
  background: #9090bb;
  color: #000020;
  font-family: Verdana, Helvetica, Arial, sans-serif;
  font-size: 11px;
}
a {
  color: #0000c0;
  text-decoration: none;
}
a:hover {
  color: #e23e3e;
  text-decoration: underline;
}
.page {
  width: min(1120px, calc(100vw - 24px));
  margin: 12px auto;
  padding: 12px;
  border: 1px solid #000;
  background: #f8f8f8;
}
.title {
  margin: 0;
  font: bold 26px/1.15 "Trebuchet MS", Verdana, sans-serif;
}
.runTitle {
  margin: 14px 0 6px;
  color: #000020;
  font: bold 20px/1.15 "Trebuchet MS", Verdana, sans-serif;
}
.small {
  font-size: 11px;
}
table {
  width: 100%;
  margin: 0 0 12px;
  border-collapse: collapse;
}
td,
th {
  padding: 4px;
  border: 1px solid #707096;
  vertical-align: top;
}
form {
  margin: 0;
}
th.sortable {
  cursor: pointer;
}
.head {
  background: #9090bb;
  color: #eeeeff;
  font-weight: 700;
}
.cat {
  background: #7676a8;
  color: #fff788;
  font-weight: 700;
}
.row1 {
  background: #e8e8e8;
}
.row2 {
  background: #f1f1f1;
}
.right {
  text-align: right;
}
.center {
  text-align: center;
}
.nowrap {
  white-space: nowrap;
}
.ok {
  color: #006000;
  font-weight: 700;
}
.bad {
  color: #a00000;
  font-weight: 700;
}
.warn {
  color: #806000;
  font-weight: 700;
}
.clip {
  display: block;
  max-width: 240px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.button {
  display: inline-block;
  box-sizing: border-box;
  min-width: 58px;
  height: 19px;
  margin: 0;
  border: 1px solid #303050;
  border-radius: 0;
  appearance: none;
  -webkit-appearance: none;
  background: #eeeeff;
  color: #000020;
  cursor: pointer;
  font: 11px/13px Verdana, Helvetica, Arial, sans-serif;
  padding: 2px 8px;
  text-align: center;
  text-decoration: none;
  vertical-align: middle;
}
.button:hover {
  text-decoration: none;
}
.filterTable input[type="number"] {
  width: 72px;
  margin: 0 6px 0 2px;
  border: 1px solid #707096;
  background: #fff;
  color: #000020;
  font: 11px Verdana, Helvetica, Arial, sans-serif;
}
.filterChecks {
  display: flex;
  flex-wrap: wrap;
  gap: 2px 10px;
  max-height: 80px;
  overflow: auto;
}
.filterChecks label {
  white-space: nowrap;
}
.filterActions {
  display: flex;
  gap: 8px;
  align-items: center;
}
.filterDetails summary {
  cursor: pointer;
  font-weight: 700;
}
.chartCat {
  box-sizing: border-box;
  width: 100%;
  margin: 0 0 8px;
  padding: 2px 4px;
  background: #7676a8;
  color: #fff788;
  font-weight: 700;
}
.histPanel {
  margin: 0 0 14px;
}
.histBot {
  margin: 0 0 2px;
  color: #000020;
  font: bold 15px/1.2 "Trebuchet MS", Verdana, sans-serif;
}
.histSvg {
  display: block;
  width: 100%;
  height: auto;
  overflow: visible;
}
.histAxis,
.histTick {
  stroke: #000020;
  stroke-width: 1;
}
.histBar {
  fill: #9090bb;
  stroke: #707096;
  stroke-width: 1;
}
.histText {
  fill: #000020;
  font: 11px Verdana, Helvetica, Arial, sans-serif;
}
.histCount {
  fill: #000020;
  font: 11px Verdana, Helvetica, Arial, sans-serif;
}
.footer {
  margin: 12px 0 0;
}
"""
  SortScript = """
<script>
function cellValue(row, index) {
  return row.children[index].getAttribute("data-sort") ||
    row.children[index].textContent;
}
function sortTable(id, index) {
  var table = document.getElementById(id);
  var body = table.tBodies[0];
  var rows = Array.prototype.slice.call(body.rows);
  rows.sort(function (a, b) {
    var av = cellValue(a, index);
    var bv = cellValue(b, index);
    var an = parseFloat(av);
    var bn = parseFloat(bv);
    if (!isNaN(an) && !isNaN(bn)) return bn - an;
    return av.localeCompare(bv);
  });
  rows.forEach(function (row) { body.appendChild(row); });
}
</script>
"""

type
  MultiServerError = object of CatchableError

  MultiServerConfig = object
    address: string
    port: int

  RunCounts = object
    total: int
    running: int
    finished: int
    failed: int
    queued: int

  FilterOptions = object
    names: seq[string]
    players: seq[string]
    roles: seq[string]
    wins: seq[string]
    texts: seq[ScoreTextValues]

  RunView = object
    meta: RunMeta
    runDir: string
    games: seq[GameMeta]
    containers: seq[ContainerInfo]
    allRecords: seq[ScoreRecord]
    records: seq[ScoreRecord]
    aggregates: seq[PlayerAggregate]
    filter: ScoreFilter
    filters: FilterOptions
    numberFields: seq[string]
    counts: RunCounts

proc esc(text: string): string =
  ## Escapes HTML special characters.
  result = text
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")

proc htmlHeaders(): HttpHeaders =
  ## Builds standard HTML response headers.
  result["Content-Type"] = "text/html; charset=utf-8"
  result["Cache-Control"] = "no-cache"

proc contentHeaders(contentType: string): HttpHeaders =
  ## Builds standard content response headers.
  result["Content-Type"] = contentType
  result["Cache-Control"] = "no-cache"

proc redirectHeaders(location: string): HttpHeaders =
  ## Builds redirect headers.
  result = htmlHeaders()
  result["Location"] = location

proc hexValue(c: char): int =
  ## Converts one hex digit to its integer value.
  case c
  of '0' .. '9':
    ord(c) - ord('0')
  of 'a' .. 'f':
    10 + ord(c) - ord('a')
  of 'A' .. 'F':
    10 + ord(c) - ord('A')
  else:
    -1

proc decodeUrlComponent(value: string): string =
  ## Decodes a URL form component.
  var i = 0
  while i < value.len:
    if value[i] == '+':
      result.add(' ')
      inc i
    elif value[i] == '%' and i + 2 < value.len:
      let
        high = hexValue(value[i + 1])
        low = hexValue(value[i + 2])
      if high >= 0 and low >= 0:
        result.add(char(high * 16 + low))
        i += 3
      else:
        result.add(value[i])
        inc i
    else:
      result.add(value[i])
      inc i

proc parseUrlPairs(s: string): seq[(string, string)] =
  ## Parses URL encoded key/value pairs.
  for part in s.split('&'):
    if part.len == 0:
      continue
    let eq = part.find('=')
    if eq < 0:
      result.add((decodeUrlComponent(part), ""))
    else:
      result.add((
        decodeUrlComponent(part[0 ..< eq]),
        decodeUrlComponent(part[eq + 1 .. ^1])
      ))

proc parseFormBody(request: Request): seq[(string, string)] =
  ## Parses an application/x-www-form-urlencoded request body.
  parseUrlPairs(request.body)

proc formValue(form: seq[(string, string)], key: string): string =
  ## Returns the first form value for a key.
  for (formKey, value) in form:
    if formKey == key:
      return value

proc queryValue(request: Request, key: string): string =
  ## Reads one query string value.
  let queryStart = request.uri.find('?')
  if queryStart < 0 or queryStart + 1 >= request.uri.len:
    return
  for (queryKey, value) in parseUrlPairs(request.uri[queryStart + 1 .. ^1]):
    if queryKey == key:
      return value

proc queryPairs(request: Request): seq[(string, string)] =
  ## Reads all query string pairs.
  let queryStart = request.uri.find('?')
  if queryStart < 0 or queryStart + 1 >= request.uri.len:
    return
  parseUrlPairs(request.uri[queryStart + 1 .. ^1])

proc parseOptionalFloat(value: string): tuple[ok: bool, value: float] =
  ## Parses one optional filter float.
  let text = value.strip()
  if text.len == 0:
    return
  try:
    result = (true, parseFloat(text))
  except ValueError:
    result = (false, 0.0)

proc setMinRange(scoreRange: var ScoreRange, value: string) =
  ## Applies a minimum value to a score range.
  let parsed = parseOptionalFloat(value)
  if parsed.ok:
    scoreRange.hasMin = true
    scoreRange.minValue = parsed.value

proc setMaxRange(scoreRange: var ScoreRange, value: string) =
  ## Applies a maximum value to a score range.
  let parsed = parseOptionalFloat(value)
  if parsed.ok:
    scoreRange.hasMax = true
    scoreRange.maxValue = parsed.value

proc addFilterText(values: var seq[string], value: string) =
  ## Adds one checked text filter value.
  let text = value.strip()
  if text.len > 0:
    values.add(text)

proc applyScoreFilterRange(
  filter: var ScoreFilter,
  name,
  bound,
  value: string
) =
  ## Applies one named numeric score filter bound.
  let key = canonicalScoreField(name)
  case key
  of "score":
    if bound == "min":
      filter.score.setMinRange(value)
    else:
      filter.score.setMaxRange(value)
  of "tasks":
    if bound == "min":
      filter.tasks.setMinRange(value)
    else:
      filter.tasks.setMaxRange(value)
  of "kills":
    if bound == "min":
      filter.kills.setMinRange(value)
    else:
      filter.kills.setMaxRange(value)
  of "imposter":
    if bound == "min":
      filter.imposter.setMinRange(value)
    else:
      filter.imposter.setMaxRange(value)
  of "crew":
    if bound == "min":
      filter.crew.setMinRange(value)
    else:
      filter.crew.setMaxRange(value)
  of "vote_players":
    if bound == "min":
      filter.votePlayers.setMinRange(value)
    else:
      filter.votePlayers.setMaxRange(value)
  of "vote_skip":
    if bound == "min":
      filter.voteSkip.setMinRange(value)
    else:
      filter.voteSkip.setMaxRange(value)
  of "vote_timeout":
    if bound == "min":
      filter.voteTimeout.setMinRange(value)
    else:
      filter.voteTimeout.setMaxRange(value)
  else:
    var scoreRange = filter.scoreFilterNumberRange(key)
    if bound == "min":
      scoreRange.setMinRange(value)
    else:
      scoreRange.setMaxRange(value)
    filter.setScoreFilterNumberRange(key, scoreRange)

proc setScoreFilterRange(
  filter: var ScoreFilter,
  key,
  value: string
) =
  ## Applies one numeric score filter query pair.
  if key.endsWith("_min"):
    filter.applyScoreFilterRange(
      key[0 ..< key.len - "_min".len],
      "min",
      value
    )
  elif key.endsWith("_max"):
    filter.applyScoreFilterRange(
      key[0 ..< key.len - "_max".len],
      "max",
      value
    )

proc parseScoreFilter(pairs: openArray[(string, string)]): ScoreFilter =
  ## Parses score filter query pairs.
  for (key, value) in pairs:
    if key.startsWith("text_") and key.len > "text_".len:
      result.addScoreFilterTextValue(key["text_".len .. ^1], value)
      continue
    case key
    of "name":
      result.names.addFilterText(value)
    of "player":
      result.players.addFilterText(value)
    of "role":
      result.roles.addFilterText(value)
    of "win":
      if value == "true" or value == "false":
        result.wins.add(value)
    else:
      result.setScoreFilterRange(key, value)

proc hostName(request: Request): string =
  ## Extracts the browser-visible host without a port.
  let raw = request.headers["Host"].strip()
  if raw.len == 0:
    return "localhost"
  if raw[0] == '[':
    let endAt = raw.find(']')
    if endAt > 0:
      return raw[0 .. endAt]
  let colon = raw.find(':')
  if colon > 0:
    return raw[0 ..< colon]
  raw

proc runFolderPath(runId: string): string =
  ## Returns a validated run folder path.
  let clean = cleanFileName(runId)
  if clean.len == 0 or clean != runId or not runId.startsWith(RunPrefix):
    raise newException(MultiServerError, "invalid run id")
  result = multiRunsRoot() / clean
  if not dirExists(result):
    raise newException(MultiServerError, "run not found")

proc artifactPath(runId, name: string): string =
  ## Returns a validated artifact file path.
  let clean = cleanFileName(name)
  if clean.len == 0 or clean != name:
    raise newException(MultiServerError, "invalid artifact name")
  result = runFolderPath(runId) / clean
  if not fileExists(result):
    raise newException(MultiServerError, "artifact not found")

proc fmtCreated(created: int64): string =
  ## Formats a Unix timestamp for display.
  if created <= 0:
    return "unknown"
  fromUnix(created).utc().format("yyyy-MM-dd HH:mm:ss") & " UTC"

proc fmtFloat(value: float): string =
  ## Formats one score value for display.
  formatFloat(value, ffDecimal, 2)

proc fmtPercent(count, total: int): string =
  ## Formats one count over total as an integer percentage.
  if total <= 0:
    return "0%"
  let percent = floor(count.float * 100.0 / total.float + 0.5).int
  $percent & "%"

proc perGame(total, games: int): float =
  ## Returns a per-game rate for one aggregate stat.
  if games <= 0:
    return 0
  total.float / games.float

proc addUnique(values: var seq[string], value: string) =
  ## Adds one non-empty string when it is not already present.
  if value.len == 0:
    return
  for existing in values:
    if existing == value:
      return
  values.add(value)

proc addTextOption(
  options: var seq[ScoreTextValues],
  name,
  value: string
) =
  ## Adds one custom text filter option.
  let key = canonicalScoreField(name)
  if key.len == 0:
    return
  for i in 0 ..< options.len:
    if options[i].name == key:
      options[i].values.addUnique(value)
      return
  var item = ScoreTextValues(name: key)
  item.values.addUnique(value)
  options.add(item)

proc scoreFilterTextValues(
  filter: ScoreFilter,
  name: string
): seq[string] =
  ## Returns checked values for one custom text filter.
  let key = canonicalScoreField(name)
  for item in filter.textValues:
    if item.name == key:
      return item.values

proc runDirs(): seq[string] =
  ## Lists durable multi-run folders newest first.
  let root = multiRunsRoot()
  if not dirExists(root):
    return
  for kind, path in walkDir(root):
    if kind == pcDir and path.extractFilename().startsWith(RunPrefix):
      result.add(path)
  result.sort(proc(a, b: string): int = cmp(b.extractFilename(), a.extractFilename()))

proc containersByRun(runId = ""): Table[string, seq[ContainerInfo]] =
  ## Groups observed Docker containers by run id.
  for container in listMultiRunContainers(runId):
    if container.runId.len > 0:
      result.mgetOrPut(container.runId, @[]).add(container)

proc gameContainer(
  containers: openArray[ContainerInfo],
  gameIndex: int
): ContainerInfo =
  ## Finds the observed game container for one game index.
  for container in containers:
    if container.kind == GameKind and container.gameIndex == gameIndex:
      return container

proc hasScores(runDir: string, game: GameMeta): bool =
  ## Returns true when a game's score file exists.
  fileExists(runDir / game.results.extractFilename())

proc runCounts(
  meta: RunMeta,
  runDir: string,
  games: openArray[GameMeta],
  containers: openArray[ContainerInfo]
): RunCounts =
  ## Counts running, finished, failed, and queued games for a run.
  result.total = max(meta.totalGames, games.len)
  for game in games:
    let container = containers.gameContainer(game.gameIndex)
    if container.name.len > 0 and container.isActiveContainer():
      inc result.running
    elif container.name.len == 0 and game.status == "running":
      inc result.running
    elif game.status == "failed" or (
      container.name.len > 0 and not container.normalExit()
    ):
      inc result.failed
    elif game.status == "finished" or runDir.hasScores(game) or
        (container.name.len > 0 and container.normalExit()):
      inc result.finished
  result.queued = max(
    0,
    result.total - result.running - result.finished - result.failed
  )

proc filterOptions(records: openArray[ScoreRecord]): FilterOptions =
  ## Builds checkbox filter options from score records.
  for record in records:
    result.names.addUnique(record.row.name)
    result.players.addUnique(record.player)
    result.roles.addUnique(record.role)
    result.wins.addUnique($record.row.win)
    for field in record.row.texts:
      result.texts.addTextOption(field.name, field.value)
  result.names.sort()
  result.players.sort()
  result.roles.sort()
  result.wins.sort()
  for i in 0 ..< result.texts.len:
    result.texts[i].values.sort()

proc buildRunView(
  runDir: string,
  grouped: Table[string, seq[ContainerInfo]],
  includeAggregates: bool,
  filter: ScoreFilter = ScoreFilter()
): RunView =
  ## Builds one run view from durable files and Docker labels.
  let
    meta = readRunMeta(runDir)
    containers = grouped.getOrDefault(meta.runId)
    games = readGameMetas(runDir)
    allRecords =
      if includeAggregates:
        scoreRecords(runDir)
      else:
        @[]
    records =
      if includeAggregates:
        filterScoreRecords(allRecords, filter)
      else:
        @[]
    aggregates =
      if includeAggregates:
        aggregateScoreRecords(records)
      else:
        @[]
    numberFields =
      if includeAggregates:
        scoreNumberFieldNames(allRecords)
      else:
        @[]
  result = RunView(
    meta: meta,
    runDir: runDir,
    games: games,
    containers: containers,
    allRecords: allRecords,
    records: records,
    aggregates: aggregates,
    filter: filter,
    filters: filterOptions(allRecords),
    numberFields: numberFields,
    counts: runCounts(meta, runDir, games, containers)
  )

proc buildRunIndexViews(): seq[RunView] =
  ## Builds lightweight run summaries for the index page.
  let grouped = initTable[string, seq[ContainerInfo]]()
  for dir in runDirs():
    result.add(buildRunView(dir, grouped, false))

proc buildRunDetailView(runId: string, filter: ScoreFilter): RunView =
  ## Builds one detailed run page view.
  let
    runDir = runFolderPath(runId)
    grouped = containersByRun(runDir.extractFilename())
  buildRunView(runDir, grouped, true, filter)

proc statusClass(status: string): string =
  ## Returns a CSS class for a status label.
  case status
  of "finished":
    "ok"
  of "failed":
    "bad"
  of "running":
    "warn"
  else:
    ""

proc sortableHeader(tableId: string, index: int, heading: string): string =
  ## Renders one sortable header without changing table header styling.
  "<th class=\"head sortable\" onclick=\"sortTable('" & esc(tableId) & "'," &
    $index & ")\">" & esc(heading) & "</th>"

proc categoryRow(title: string, colspan: int): string =
  ## Renders one table-attached category row like the games server.
  "<tr><td class=\"cat\" colspan=\"" & $colspan & "\">" &
    esc(title) & "</td></tr>"

proc displayStatus(
  runDir: string,
  game: GameMeta,
  container: ContainerInfo
): string =
  ## Returns the best current status for one game.
  if container.name.len > 0 and container.isActiveContainer():
    return "running"
  if game.status == "failed" or (
    container.name.len > 0 and not container.normalExit()
  ):
    return "failed"
  if game.status == "finished" or runDir.hasScores(game) or
      (container.name.len > 0 and container.normalExit()):
    return "finished"
  game.status

proc scoresUrl(runId, name: string): string =
  ## Builds a local scores URL.
  ScoresPath & "?run=" & runId.encodeUrlComponent() &
    "&name=" & name.encodeUrlComponent()

proc runUrl(runId: string): string =
  ## Builds a local run detail URL.
  RunPath & "?run=" & runId.encodeUrlComponent()

proc addQueryParam(parts: var seq[string], key, value: string) =
  ## Adds one encoded query parameter.
  parts.add(key.encodeUrlComponent() & "=" & value.encodeUrlComponent())

proc addRangeQuery(
  parts: var seq[string],
  prefix: string,
  scoreRange: ScoreRange
) =
  ## Adds numeric range values to a filter query.
  if scoreRange.hasMin:
    parts.addQueryParam(prefix & "_min", $scoreRange.minValue)
  if scoreRange.hasMax:
    parts.addQueryParam(prefix & "_max", $scoreRange.maxValue)

proc scoreFilterQuery(filter: ScoreFilter): string =
  ## Builds a query string fragment for a score filter.
  var parts: seq[string]
  for value in filter.names:
    parts.addQueryParam("name", value)
  for value in filter.players:
    parts.addQueryParam("player", value)
  for value in filter.roles:
    parts.addQueryParam("role", value)
  for value in filter.wins:
    parts.addQueryParam("win", value)
  parts.addRangeQuery("score", filter.score)
  parts.addRangeQuery("tasks", filter.tasks)
  parts.addRangeQuery("kills", filter.kills)
  parts.addRangeQuery("imposter", filter.imposter)
  parts.addRangeQuery("crew", filter.crew)
  parts.addRangeQuery("vote_players", filter.votePlayers)
  parts.addRangeQuery("vote_skip", filter.voteSkip)
  parts.addRangeQuery("vote_timeout", filter.voteTimeout)
  for item in filter.numberRanges:
    parts.addRangeQuery(item.name, item.scoreRange)
  for item in filter.textValues:
    for value in item.values:
      parts.addQueryParam("text_" & item.name, value)
  parts.join("&")

proc runUrl(runId: string, filter: ScoreFilter): string =
  ## Builds a local run detail URL with score filters.
  result = runUrl(runId)
  let query = scoreFilterQuery(filter)
  if query.len > 0:
    result.add("&" & query)

proc replayForm(runId, name: string): string =
  ## Renders a replay-launch form for one completed game.
  result.add("<form method=\"post\" action=\"" & ReplayPlayPath &
    "\" target=\"_blank\">")
  result.add("<input type=\"hidden\" name=\"run\" value=\"" & esc(runId) &
    "\">")
  result.add("<input type=\"hidden\" name=\"name\" value=\"" & esc(name) &
    "\">")
  result.add("<button class=\"button\" type=\"submit\">replay</button>")
  result.add("</form>")

proc scoreRangeValue(value: float): string =
  ## Formats one score filter input value.
  let text = $value
  if text.endsWith(".0"):
    result = text[0 ..< text.len - 2]
  else:
    result = text

proc rangeInputCells(
  label,
  prefix: string,
  scoreRange: ScoreRange
): string =
  ## Renders one numeric min/max filter cell pair.
  let
    minValue =
      if scoreRange.hasMin:
        scoreRangeValue(scoreRange.minValue)
      else:
        ""
    maxValue =
      if scoreRange.hasMax:
        scoreRangeValue(scoreRange.maxValue)
      else:
        ""
  result.add("<td class=\"head\">" & esc(label) & "</td><td>")
  result.add("min <input type=\"number\" step=\"any\" name=\"" &
    esc(prefix) & "_min\" value=\"" & esc(minValue) & "\">")
  result.add("max <input type=\"number\" step=\"any\" name=\"" &
    esc(prefix) & "_max\" value=\"" & esc(maxValue) & "\">")
  result.add("</td>")

proc valueChecked(values: openArray[string], value: string): bool =
  ## Returns true when one checkbox value is selected.
  value in values

proc renderCheckRow(
  label,
  param: string,
  values,
  checkedValues: openArray[string]
): string =
  ## Renders one checkbox filter row.
  let collapsed = values.len > 16
  result.add("<tr><td class=\"head\">" & esc(label) &
    "</td><td colspan=\"3\">")
  if collapsed:
    result.add("<details class=\"filterDetails\"")
    if checkedValues.len > 0:
      result.add(" open")
    result.add("><summary>" & $values.len & " values</summary>")
  result.add("<div class=\"filterChecks\">")
  if values.len == 0:
    result.add("-")
  for value in values:
    result.add("<label><input type=\"checkbox\" name=\"" & esc(param) &
      "\" value=\"" & esc(value) & "\"")
    if checkedValues.valueChecked(value):
      result.add(" checked")
    result.add("> " & esc(value) & "</label>")
  result.add("</div>")
  if collapsed:
    result.add("</details>")
  result.add("</td></tr>")

proc renderFilterForm(view: RunView): string =
  ## Renders the score row filter form for one run.
  result.add("<form method=\"get\" action=\"" & RunPath &
    "\"><input type=\"hidden\" name=\"run\" value=\"" &
    esc(view.meta.runId) & "\">")
  result.add("<table class=\"filterTable\"><thead>")
  result.add(categoryRow("Filters", 4))
  result.add("</thead><tbody>")
  result.add(renderCheckRow(
    "Player",
    "player",
    view.filters.players,
    view.filter.players
  ))
  result.add(renderCheckRow("Role", "role", view.filters.roles, view.filter.roles))
  result.add(renderCheckRow("Win", "win", view.filters.wins, view.filter.wins))
  result.add(renderCheckRow("Name", "name", view.filters.names, view.filter.names))
  for field in view.filters.texts:
    result.add(renderCheckRow(
      scoreFieldLabel(field.name),
      "text_" & field.name,
      field.values,
      view.filter.scoreFilterTextValues(field.name)
    ))
  result.add("<tr>")
  result.add(rangeInputCells("Score", "score", view.filter.score))
  result.add(rangeInputCells("Tasks", "tasks", view.filter.tasks))
  result.add("</tr><tr>")
  result.add(rangeInputCells("Kills", "kills", view.filter.kills))
  result.add(rangeInputCells("Imposter", "imposter", view.filter.imposter))
  result.add("</tr><tr>")
  result.add(rangeInputCells("Crew", "crew", view.filter.crew))
  result.add(rangeInputCells("Votes", "vote_players", view.filter.votePlayers))
  result.add("</tr><tr>")
  result.add(rangeInputCells("Skips", "vote_skip", view.filter.voteSkip))
  result.add(rangeInputCells(
    "Timeouts",
    "vote_timeout",
    view.filter.voteTimeout
  ))
  result.add("</tr>")
  var fieldIndex = 0
  while fieldIndex < view.numberFields.len:
    result.add("<tr>")
    let first = view.numberFields[fieldIndex]
    result.add(rangeInputCells(
      scoreFieldLabel(first),
      first,
      view.filter.scoreFilterNumberRange(first)
    ))
    inc fieldIndex
    if fieldIndex < view.numberFields.len:
      let second = view.numberFields[fieldIndex]
      result.add(rangeInputCells(
        scoreFieldLabel(second),
        second,
        view.filter.scoreFilterNumberRange(second)
      ))
      inc fieldIndex
    else:
      result.add("<td></td><td></td>")
    result.add("</tr>")
  result.add("<tr><td colspan=\"4\"><div class=\"filterActions\">")
  result.add("<button class=\"button\" type=\"submit\">Apply</button>")
  result.add("<a class=\"button\" href=\"" & runUrl(view.meta.runId) &
    "\">Clear</a>")
  result.add("</div></td></tr>")
  result.add("</tbody></table></form>")

proc renderRunSummary(views: openArray[RunView]): string =
  ## Renders the top-level run summary table.
  result.add("<table id=\"runs\"><thead>")
  result.add(categoryRow("Runs", 8))
  result.add("<tr>")
  for i, heading in ["Run", "Game", "Created", "Running", "Finished",
      "Failed", "Queued", "Total"]:
    result.add(sortableHeader("runs", i, heading))
  result.add("</tr></thead><tbody>")
  if views.len == 0:
    result.add("<tr class=\"row1\"><td colspan=\"8\">No multi runs found.</td></tr>")
  for i, view in views:
    let row = if i mod 2 == 0: "row1" else: "row2"
    result.add("<tr class=\"" & row & "\">")
    result.add("<td><a href=\"" & runUrl(view.meta.runId) & "\">" &
      esc(view.meta.runId) & "</a></td>")
    result.add("<td>" & esc(view.meta.gameName) & "</td>")
    result.add("<td class=\"nowrap\">" & esc(fmtCreated(view.meta.created)) &
      "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $view.counts.running &
      "\">" & $view.counts.running & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $view.counts.finished &
      "\">" & $view.counts.finished & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $view.counts.failed &
      "\">" & $view.counts.failed & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $view.counts.queued &
      "\">" & $view.counts.queued & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $view.counts.total &
      "\">" & $view.counts.total & "</td>")
    result.add("</tr>")
  result.add("</tbody></table>")

proc runPlayerNames(view: RunView): seq[string] =
  ## Returns player names used as score columns for one run.
  for record in view.records:
    result.addUnique(record.player)
  if result.len == 0 and not scoreFilterActive(view.filter):
    for aggregate in view.aggregates:
      result.addUnique(aggregate.player)
  if result.len == 0 and not scoreFilterActive(view.filter):
    for game in view.games:
      for slot in game.slots:
        result.addUnique(slot.player)

proc gameHasFilteredRows(view: RunView, gameIndex: int): bool =
  ## Returns true when a game should be shown under the active filter.
  if not scoreFilterActive(view.filter):
    return true
  for record in view.records:
    if record.gameIndex == gameIndex:
      return true

proc shownGameCount(view: RunView): int =
  ## Counts games shown under the active score-row filter.
  for game in view.games:
    if view.gameHasFilteredRows(game.gameIndex):
      inc result

proc gamesTitle(view: RunView): string =
  ## Builds the games table title with visible and total game counts.
  let
    shown = view.shownGameCount()
    total = max(view.counts.total, view.games.len)
  "Games " & $shown & "/" & $total & " " & fmtPercent(shown, total)

proc renderGamesTable(view: RunView): string =
  ## Renders one run's game table.
  let
    tableId = "games_" & view.meta.runId
    players = runPlayerNames(view)
    fixedHeadings = ["Game", "Status", "Exit", "Port", "Replay", "Scores"]
  result.add("<table id=\"" & esc(tableId) & "\"><thead>")
  result.add(categoryRow(view.gamesTitle(), fixedHeadings.len + players.len))
  result.add("<tr>")
  for i, heading in fixedHeadings:
    result.add(sortableHeader(tableId, i, heading))
  for i, player in players:
    result.add(sortableHeader(tableId, fixedHeadings.len + i, player))
  result.add("</tr></thead><tbody>")
  if view.games.len == 0:
    result.add("<tr class=\"row1\"><td colspan=\"" &
      $(fixedHeadings.len + players.len) & "\">No games found.</td></tr>")
  var shown = 0
  for i, game in view.games:
    if not view.gameHasFilteredRows(game.gameIndex):
      continue
    inc shown
    let
      row = if shown mod 2 == 1: "row1" else: "row2"
      container = view.containers.gameContainer(game.gameIndex)
      status = displayStatus(view.runDir, game, container)
      replayName = game.replay.extractFilename()
      scoreName = game.results.extractFilename()
      gameScores = averageGameScores(view.records, game.gameIndex)
    result.add("<tr class=\"" & row & "\">")
    result.add("<td class=\"right\" data-sort=\"" & $game.gameIndex & "\">" &
      $game.gameIndex & "</td>")
    result.add("<td class=\"" & statusClass(status) & "\">" &
      esc(status) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $game.exitCode & "\">" &
      $game.exitCode & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $game.port & "\">" &
      $game.port & "</td>")
    if fileExists(view.runDir / replayName):
      result.add("<td>" & replayForm(view.meta.runId, replayName) & "</td>")
    else:
      result.add("<td>-</td>")
    if fileExists(view.runDir / scoreName):
      result.add("<td><a href=\"" & scoresUrl(view.meta.runId, scoreName) &
        "\">scores</a></td>")
    else:
      result.add("<td>-</td>")
    for player in players:
      if gameScores.hasKey(player):
        let score = gameScores[player]
        result.add("<td class=\"right\" data-sort=\"" & $score & "\">" &
          fmtFloat(score) & "</td>")
      else:
        result.add("<td>-</td>")
    result.add("</tr>")
  if view.games.len > 0 and shown == 0:
    result.add("<tr class=\"row1\"><td colspan=\"" &
      $(fixedHeadings.len + players.len) & "\">No games found.</td></tr>")
  result.add("</tbody></table>")

proc renderPlayerTable(view: RunView): string =
  ## Renders one run's aggregate player score table.
  let tableId = "players_" & view.meta.runId
  var headings = @[
    "Player",
    "Wins/Game",
    "Tasks/Game",
    "Kills/Game",
    "Imposter/Game",
    "Crew/Game",
    "Votes/Game",
    "Skips/Game",
    "Timeouts/Game"
  ]
  for field in view.numberFields:
    headings.add(scoreFieldLabel(field) & "/Game")
  for heading in ["Avg Score", "Score SD", "Min Score", "Max Score"]:
    headings.add(heading)
  result.add("<table id=\"" & esc(tableId) & "\"><thead>")
  result.add(categoryRow("Players", headings.len))
  result.add("<tr>")
  for i, heading in headings:
    result.add(sortableHeader(tableId, i, heading))
  result.add("</tr></thead><tbody>")
  if view.aggregates.len == 0:
    result.add("<tr class=\"row1\"><td colspan=\"" & $headings.len &
      "\">Scores pending.</td></tr>")
  for i, player in view.aggregates:
    let row = if i mod 2 == 0: "row1" else: "row2"
    result.add("<tr class=\"" & row & "\">")
    result.add("<td>" & esc(player.player) & "</td>")
    let
      winRate = perGame(player.wins, player.games)
      taskRate = perGame(player.tasksSum, player.games)
      killRate = perGame(player.killsSum, player.games)
      imposterRate = perGame(player.imposterSum, player.games)
      crewRate = perGame(player.crewSum, player.games)
      voteRate = perGame(player.votePlayersSum, player.games)
      skipRate = perGame(player.voteSkipSum, player.games)
      timeoutRate = perGame(player.voteTimeoutSum, player.games)
      scoreAvg = player.scoreAverage()
      scoreDev = player.scoreStdDev()
    result.add("<td class=\"right\" data-sort=\"" & $winRate & "\">" &
      fmtFloat(winRate) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $taskRate & "\">" &
      fmtFloat(taskRate) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $killRate & "\">" &
      fmtFloat(killRate) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $imposterRate & "\">" &
      fmtFloat(imposterRate) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $crewRate & "\">" &
      fmtFloat(crewRate) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $voteRate & "\">" &
      fmtFloat(voteRate) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $skipRate & "\">" &
      fmtFloat(skipRate) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $timeoutRate & "\">" &
      fmtFloat(timeoutRate) & "</td>")
    for field in view.numberFields:
      let fieldRate = player.scoreNumberAverage(field)
      result.add("<td class=\"right\" data-sort=\"" & $fieldRate & "\">" &
        fmtFloat(fieldRate) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $scoreAvg & "\">" &
      fmtFloat(scoreAvg) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $scoreDev & "\">" &
      fmtFloat(scoreDev) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $player.scoreMin & "\">" &
      fmtFloat(player.scoreMin) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $player.scoreMax & "\">" &
      fmtFloat(player.scoreMax) & "</td>")
    result.add("</tr>")
  result.add("</tbody></table>")

proc maxHistogramCount(histograms: openArray[ScoreHistogram]): int =
  ## Returns the largest bucket count across all histograms.
  for histogram in histograms:
    for count in histogram.bins:
      result = max(result, count)

proc histogramBucketMax(histogram: ScoreHistogram): int =
  ## Returns the last bucket lower bound for one score histogram.
  if histogram.bins.len == 0:
    return histogram.bucketMin - ScoreHistogramBinSize
  histogram.bucketMin + (histogram.bins.len - 1) * ScoreHistogramBinSize

proc svgNum(value: float): string =
  ## Formats one SVG coordinate.
  formatFloat(value, ffDecimal, 2)

proc niceCountStep(maxCount: int): int =
  ## Returns a readable y-axis step for score counts.
  if maxCount <= 5:
    return 1
  let
    raw = maxCount.float / 5.0
    magnitude = pow(10.0, floor(log10(raw))).int
  for step in [1, 2, 5, 10]:
    let candidate = step * magnitude
    if candidate.float >= raw:
      return candidate
  10 * magnitude

proc yAxisLimit(maxCount: int): int =
  ## Returns a rounded y-axis maximum for score histograms.
  let step = niceCountStep(maxCount)
  max(step, int(ceil(maxCount.float / step.float)) * step)

proc renderScoreHistogramSvg(
  histogram: ScoreHistogram,
  labels: openArray[string],
  maxCount: int
): string =
  ## Renders one raw score histogram as SVG.
  const
    Width = 1080.0
    Height = 260.0
    PaddingLeft = 48.0
    PaddingRight = 12.0
    PaddingTop = 20.0
    PaddingBottom = 50.0
    TickLength = 4.0
  let
    chartWidth = Width - PaddingLeft - PaddingRight
    chartHeight = Height - PaddingTop - PaddingBottom
    baseline = PaddingTop + chartHeight
    yLimit = yAxisLimit(maxCount)
    step = niceCountStep(maxCount)
    bucketWidth = chartWidth / max(labels.len, 1).float
    gap = min(6.0, bucketWidth * 0.4)
    barWidth = max(1.0, bucketWidth - gap)
  var rotateLabels = labels.len > 20
  for label in labels:
    if label.len > 6:
      rotateLabels = true
  result.add("<svg class=\"histSvg\" viewBox=\"0 0 " & svgNum(Width) &
    " " & svgNum(Height) & "\" role=\"img\" aria-label=\"" &
    esc(histogram.player) & " score histogram\">")
  result.add("<title>" & esc(histogram.player) &
    " score histogram</title>")
  result.add("<line class=\"histAxis\" x1=\"" & svgNum(PaddingLeft) &
    "\" y1=\"" & svgNum(PaddingTop - TickLength) &
    "\" x2=\"" & svgNum(PaddingLeft) &
    "\" y2=\"" & svgNum(baseline) & "\"></line>")
  result.add("<line class=\"histAxis\" x1=\"" & svgNum(PaddingLeft) &
    "\" y1=\"" & svgNum(baseline) &
    "\" x2=\"" & svgNum(Width - PaddingRight) &
    "\" y2=\"" & svgNum(baseline) & "\"></line>")
  for i in 0 .. yLimit div step:
    let
      value = i * step
      y = baseline - value.float / yLimit.float * chartHeight
    result.add("<line class=\"histTick\" x1=\"" &
      svgNum(PaddingLeft - TickLength) &
      "\" y1=\"" & svgNum(y) &
      "\" x2=\"" & svgNum(PaddingLeft) &
      "\" y2=\"" & svgNum(y) & "\"></line>")
    result.add("<text class=\"histText\" x=\"" &
      svgNum(PaddingLeft - 8.0) &
      "\" y=\"" & svgNum(y + 4.0) &
      "\" text-anchor=\"end\">" & $value & "</text>")
  for i, label in labels:
    let
      x = PaddingLeft + (i.float + 0.5) * bucketWidth
      labelY =
        if rotateLabels:
          baseline + 36.0
        else:
          baseline + 18.0
    result.add("<line class=\"histTick\" x1=\"" & svgNum(x) &
      "\" y1=\"" & svgNum(baseline) &
      "\" x2=\"" & svgNum(x) &
      "\" y2=\"" & svgNum(baseline + TickLength) & "\"></line>")
    if rotateLabels:
      result.add("<text class=\"histText\" x=\"" & svgNum(x) &
        "\" y=\"" & svgNum(labelY) &
        "\" text-anchor=\"end\" transform=\"rotate(-35 " &
        svgNum(x) & " " & svgNum(labelY) & ")\">" &
        esc(label) & "</text>")
    else:
      result.add("<text class=\"histText\" x=\"" & svgNum(x) &
        "\" y=\"" & svgNum(labelY) &
        "\" text-anchor=\"middle\">" & esc(label) & "</text>")
  for i, count in histogram.bins:
    let
      x = PaddingLeft + i.float * bucketWidth + gap / 2.0
      height = count.float / yLimit.float * chartHeight
      y = baseline - height
      labelX = x + barWidth / 2.0
      labelY =
        if count > 0:
          max(PaddingTop + 12.0, y - 5.0)
        else:
          baseline - 5.0
      label =
        if i < labels.len:
          labels[i]
        else:
          ""
    result.add("<rect class=\"histBar\" x=\"" & svgNum(x) &
      "\" y=\"" & svgNum(y) &
      "\" width=\"" & svgNum(barWidth) &
      "\" height=\"" & svgNum(height) & "\">")
    result.add("<title>" & esc(label) & ": " & $count &
      " scores</title></rect>")
    result.add("<text class=\"histCount\" x=\"" & svgNum(labelX) &
      "\" y=\"" & svgNum(labelY) &
      "\" text-anchor=\"middle\">" & $count & "</text>")
  result.add("</svg>")

proc renderScoreHistograms(view: RunView): string =
  ## Renders raw score histograms by bot/player kind for one run.
  let
    histograms = scoreHistograms(view.records)
    maxCount = maxHistogramCount(histograms)
  result.add("<div id=\"histograms_" & esc(view.meta.runId) &
    "\" class=\"chartCat\">Score Histograms</div>")
  if histograms.len == 0:
    result.add("<p class=\"small\">Scores pending.</p>")
    return
  let
    bucketMin = histograms[0].bucketMin
    bucketMax = histogramBucketMax(histograms[0])
    labels = scoreHistogramLabels(bucketMin, bucketMax)
  for histogram in histograms:
    result.add("<div class=\"histPanel\">")
    result.add("<h3 class=\"histBot\">" & esc(histogram.player) & "</h3>")
    result.add(renderScoreHistogramSvg(histogram, labels, maxCount))
    result.add("</div>")

proc renderRun(view: RunView): string =
  ## Renders one full run section.
  result.add("<h2 id=\"run-" & esc(view.meta.runId) &
    "\" class=\"runTitle\">" & esc(view.meta.runId) & "</h2>")
  result.add("<p class=\"small\">")
  result.add("game " & esc(view.meta.gameName))
  result.add(" | total " & $view.counts.total)
  result.add(" | running " & $view.counts.running)
  result.add(" | finished " & $view.counts.finished)
  result.add(" | failed " & $view.counts.failed)
  result.add(" | queued " & $view.counts.queued)
  result.add(" | " & esc(view.runDir))
  result.add("</p>")
  result.add(renderFilterForm(view))
  result.add(renderGamesTable(view))
  result.add(renderPlayerTable(view))
  result.add(renderScoreHistograms(view))

proc renderIndexPage(): string =
  ## Renders the lightweight multi-run index page.
  let views = buildRunIndexViews()
  result.add("<!doctype html><html><head><meta charset=\"utf-8\">")
  result.add("<title>CoGame Multi Run</title>")
  result.add("<style>" & PageCss & "</style>")
  result.add(SortScript)
  result.add("</head><body><div class=\"page\">")
  result.add("<table><tr><td><h1 class=\"title\">CoGame Multi Run</h1>")
  result.add("<p>Many games, one queue.</p></td>")
  result.add("<td class=\"right\"><a href=\"/\">Refresh</a></td></tr></table>")
  result.add(renderRunSummary(views))
  result.add("<p class=\"footer small\">Replay root: " & esc(replayRoot()) &
    "</p>")
  result.add("</div></body></html>")

proc renderRunPage(runId: string, filter: ScoreFilter): string =
  ## Renders one multi-run detail page.
  let view = buildRunDetailView(runId, filter)
  result.add("<!doctype html><html><head><meta charset=\"utf-8\">")
  result.add("<title>CoGame Multi Run " & esc(view.meta.runId) & "</title>")
  result.add("<style>" & PageCss & "</style>")
  result.add(SortScript)
  result.add("</head><body><div class=\"page\">")
  result.add("<table><tr><td><h1 class=\"title\">CoGame Multi Run</h1>")
  result.add("<p><a href=\"/\">Runs</a> | " & esc(view.meta.runId) &
    "</p></td>")
  result.add("<td class=\"right\"><a href=\"" &
    runUrl(view.meta.runId, view.filter) &
    "\">Refresh</a></td></tr></table>")
  result.add(renderRun(view))
  result.add("<p class=\"footer small\">Replay root: " & esc(replayRoot()) &
    "</p>")
  result.add("</div></body></html>")

proc renderScoresPage(runId, name: string): string =
  ## Renders one raw scores file as a simple table.
  let path = artifactPath(runId, name)
  let scores = parseScores(path)
  let
    numberFields = scoreNumberFieldNames(scores)
    textFields = scoreTextFieldNames(scores)
  var headings = @[
    "Name",
    "Win",
    "Tasks",
    "Kills",
    "Imposter",
    "Crew",
    "Votes",
    "Skips",
    "Timeouts"
  ]
  for field in textFields:
    headings.add(scoreFieldLabel(field))
  for field in numberFields:
    headings.add(scoreFieldLabel(field))
  headings.add("Score")
  result.add("<!doctype html><html><head><meta charset=\"utf-8\">")
  result.add("<title>Scores " & esc(name) & "</title>")
  result.add("<style>" & PageCss & "</style>")
  result.add(SortScript)
  result.add("</head><body><div class=\"page\">")
  result.add("<h1 class=\"title\">Scores</h1>")
  result.add("<p><a href=\"" & runUrl(runId) & "\">Back</a> | " &
    esc(runId) & " | " & esc(name) & "</p>")
  result.add("<table id=\"scores\"><thead>")
  result.add(categoryRow("Scores", headings.len))
  result.add("<tr>")
  for i, heading in headings:
    result.add(sortableHeader("scores", i, heading))
  result.add("</tr></thead><tbody>")
  for i, row in scores:
    let className = if i mod 2 == 0: "row1" else: "row2"
    result.add("<tr class=\"" & className & "\">")
    result.add("<td>" & esc(row.name) & "</td>")
    result.add("<td>" & $row.win & "</td>")
    result.add("<td class=\"right\">" & $row.tasks & "</td>")
    result.add("<td class=\"right\">" & $row.kills & "</td>")
    result.add("<td class=\"right\">" & $row.imposter & "</td>")
    result.add("<td class=\"right\">" & $row.crew & "</td>")
    result.add("<td class=\"right\">" & $row.votePlayers & "</td>")
    result.add("<td class=\"right\">" & $row.voteSkip & "</td>")
    result.add("<td class=\"right\">" & $row.voteTimeout & "</td>")
    for field in textFields:
      result.add("<td>" & esc(row.scoreTextFieldValue(field)) & "</td>")
    for field in numberFields:
      let value = row.scoreNumberFieldValue(field)
      result.add("<td class=\"right\" data-sort=\"" & $value & "\">" &
        fmtFloat(value) & "</td>")
    result.add("<td class=\"right\" data-sort=\"" & $row.score & "\">" &
      fmtFloat(row.score) & "</td>")
    result.add("</tr>")
  result.add("</tbody></table></div></body></html>")

proc manifestHostPath(meta: RunMeta): string =
  ## Resolves a run's manifest path on the host filesystem.
  if meta.manifest.len == 0:
    raise newException(MultiServerError, "run manifest is missing")
  if meta.manifest.isAbsolute():
    result = meta.manifest
  else:
    result = repoRoot() / meta.manifest
  if not fileExists(result):
    raise newException(
      MultiServerError,
      "run manifest does not exist: " & result
    )

proc gameByReplay(runDir, name: string): GameMeta =
  ## Finds durable game metadata for one replay file name.
  for game in readGameMetas(runDir):
    if game.replay.extractFilename() == name:
      return game
  raise newException(MultiServerError, "replay metadata not found")

proc replayGlobalUrl(request: Request, port: int): string =
  ## Builds the browser URL for a replay server global view.
  "http://" & request.hostName() & ":" & $port & GlobalClientPath

proc startReplayServer(runId, name: string): int =
  ## Starts one replay server container for a multi-run replay.
  if not name.endsWith(".bitreplay"):
    raise newException(MultiServerError, "artifact is not a replay")
  let
    runDir = runFolderPath(runId)
    path = artifactPath(runId, name)
    runMeta = readRunMeta(runDir)
    gameMeta = gameByReplay(runDir, name)
    manifestPath = manifestHostPath(runMeta)
    game = readGameManifest(manifestPath)
    port = findOpenPort()
    created = getTime().toUnix()
  discard path
  discard requireDocker(@["pull", game.imageUri])
  discard requireDocker(replayDockerArgs(
    runDir,
    game,
    gameMeta,
    port,
    created
  ))
  result = port

proc respondHtml(request: Request, status: int, body: string) =
  ## Sends an HTML response.
  request.respond(status, htmlHeaders(), body)

proc respondContent(
  request: Request,
  status: int,
  contentType,
  body: string
) =
  ## Sends a content response.
  request.respond(status, contentHeaders(contentType), body)

proc respondRedirect(request: Request, location: string) =
  ## Sends a redirect response.
  request.respond(303, redirectHeaders(location), "")

proc indexHandler(request: Request) =
  ## Handles the dashboard route.
  request.respondHtml(200, renderIndexPage())

proc runHandler(request: Request) =
  ## Handles one run detail route.
  let
    pairs = request.queryPairs()
    runId = request.queryValue("run")
    filter = parseScoreFilter(pairs)
  request.respondHtml(200, renderRunPage(runId, filter))

proc scoresHandler(request: Request) =
  ## Handles a score table route.
  let
    runId = request.queryValue("run")
    name = request.queryValue("name")
  request.respondHtml(200, renderScoresPage(runId, name))

proc downloadHandler(request: Request) =
  ## Handles artifact download routes.
  let
    runId = request.queryValue("run")
    name = request.queryValue("name")
    path = artifactPath(runId, name)
    contentType =
      if name.endsWith(".bitreplay"):
        "application/octet-stream"
      elif name.endsWith(".json"):
        "application/json; charset=utf-8"
      else:
        "text/plain; charset=utf-8"
  request.respondContent(200, contentType, readFile(path))

proc replayPlayHandler(request: Request) =
  ## Handles replay play form submissions.
  let form = request.parseFormBody()
  let
    runId = form.formValue("run")
    name = form.formValue("name")
    port = startReplayServer(runId, name)
  request.respondRedirect(request.replayGlobalUrl(port))

proc errorHandler(request: Request, e: ref Exception) =
  ## Handles server errors with a simple HTML page.
  request.respondHtml(
    500,
    "<!doctype html><html><body><div class=\"page\"><h1>Error</h1><pre>" &
      esc(e.msg) & "</pre><p><a href=\"/\">Back</a></p></div></body></html>"
  )

proc httpHandlerUnsafe(request: Request) =
  ## Routes one HTTP request.
  try:
    if request.path == "/" or request.path == "":
      request.indexHandler()
    elif request.path == RunPath:
      request.runHandler()
    elif request.path == ScoresPath:
      request.scoresHandler()
    elif request.path == DownloadPath:
      request.downloadHandler()
    elif request.path == ReplayPlayPath and request.httpMethod == "POST":
      request.replayPlayHandler()
    else:
      request.respondHtml(404, renderIndexPage())
  except MultiServerError as e:
    request.errorHandler(e)
  except CatchableError as e:
    request.errorHandler(e)

proc makeHandler(): RequestHandler =
  ## Builds a mummy request handler.
  result = proc(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      request.httpHandlerUnsafe()

proc parseArgs(): MultiServerConfig =
  ## Parses command-line options for the server.
  result.address = DefaultHost
  result.port = DefaultPort
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "":
        discard
      of "address":
        result.address = val
      of "port":
        result.port = parsePositiveInt(val, "--port")
      else:
        raise newException(MultiServerError, "unknown option: --" & key)
    of cmdShortOption:
      raise newException(MultiServerError, "unknown option: -" & key)
    else:
      discard

proc runServer(config: MultiServerConfig) =
  ## Runs the multi-run observer server.
  let server = newServer(makeHandler(), workerThreads = 1)
  echo "Multi-run server listening on http://", config.address, ":",
    config.port
  echo "Replay root: ", replayRoot()
  server.serve(Port(config.port), config.address)

when isMainModule:
  try:
    runServer(parseArgs())
  except MultiServerError as e:
    echo e.msg
    quit(1)

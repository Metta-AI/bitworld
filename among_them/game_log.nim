## Per-tick dense game log emitter.
##
## When `COGAME_LOG_URI` is set the game emits one JSON line per simulation
## tick that captures the game phase plus per-agent state (location, alive
## flag, imposter kill cooldown, and assigned tasks). The sink supports
## either an `http(s)://` URL (POST batches of newline-separated lines) or a
## plain or `file://` path (append). When `COGAME_LOG_URI` is unset, lines
## are written to stdout (one line per write, flushed immediately) — this is
## the local-dev fallback so the operator sees logs without having to wire
## up a URI.

import std/[json, os, strutils]
import curly
import sim

const
  DefaultFlushBytes = 16 * 1024
  DefaultFlushLines = 30

let logHttpPool = newCurlPool(1)

type
  GameLogSinkKind* = enum
    glsDisabled
    glsStdout
    glsFile
    glsHttp

  GameLogSink* = ref object
    kind*: GameLogSinkKind
    httpUrl*: string
    filePath*: string
    file*: File
    fileOpen*: bool
    buffer*: string
    bufferedLines*: int
    flushBytes*: int
    flushLines*: int

proc enabled*(sink: GameLogSink): bool {.inline.} =
  sink != nil and sink.kind != glsDisabled

proc isHttpUri(uri: string): bool =
  uri.startsWith("http://") or uri.startsWith("https://")

proc stripFileScheme(uri: string): string =
  const Prefix = "file://"
  if uri.startsWith(Prefix): uri[Prefix.len .. ^1] else: uri

proc disabledGameLogSink*(): GameLogSink =
  ## Returns a sink that drops all writes. Used in replay and replay-server
  ## modes, where re-emitting per-tick state would just be noise.
  GameLogSink(kind: glsDisabled)

proc openGameLogSink*(rawUri: string): GameLogSink =
  ## Opens a log sink. An empty URI falls back to stdout so local dev runs
  ## without `COGAME_LOG_URI` still get visible per-tick output.
  result = GameLogSink(
    kind: glsStdout,
    flushBytes: DefaultFlushBytes,
    flushLines: DefaultFlushLines
  )
  if rawUri.len == 0:
    return
  if isHttpUri(rawUri):
    result.kind = glsHttp
    result.httpUrl = rawUri
    return
  let path = stripFileScheme(rawUri)
  if path.len == 0:
    raise newException(IOError, "empty file path from COGAME_LOG_URI")
  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)
  result.file = open(path, fmAppend)
  result.fileOpen = true
  result.filePath = path
  result.kind = glsFile

proc flushGameLogSink*(sink: GameLogSink) =
  ## Flushes any buffered log content to the destination.
  if sink == nil:
    return
  case sink.kind
  of glsDisabled, glsStdout:
    return
  of glsHttp:
    if sink.buffer.len == 0:
      return
    let headers = @[
      ("Content-Type", "text/plain"),
      ("User-Agent", "among_them/1.0"),
    ]
    try:
      let resp = logHttpPool.post(sink.httpUrl, headers, sink.buffer)
      if resp.code >= 400:
        stderr.writeLine "COGAME_LOG_URI POST failed: " &
          $resp.code & " " & resp.body
    except CatchableError as e:
      stderr.writeLine "COGAME_LOG_URI POST error: " & e.msg
    sink.buffer.setLen(0)
    sink.bufferedLines = 0
  of glsFile:
    if sink.buffer.len == 0:
      return
    try:
      sink.file.write(sink.buffer)
      sink.file.flushFile()
    except IOError as e:
      stderr.writeLine "COGAME_LOG_URI write error: " & e.msg
    sink.buffer.setLen(0)
    sink.bufferedLines = 0

proc closeGameLogSink*(sink: GameLogSink) =
  if sink == nil or sink.kind == glsDisabled:
    return
  sink.flushGameLogSink()
  if sink.fileOpen:
    try: sink.file.close()
    except CatchableError: discard
    sink.fileOpen = false
  sink.kind = glsDisabled

proc writeGameLogLine*(sink: GameLogSink, line: string) =
  ## Appends one log line. Buffered modes flush when thresholds are exceeded.
  if sink == nil:
    return
  case sink.kind
  of glsDisabled:
    return
  of glsStdout:
    if line.len > 0 and line[^1] == '\n':
      stdout.write(line)
    else:
      stdout.writeLine(line)
    stdout.flushFile()
  of glsFile, glsHttp:
    sink.buffer.add line
    if line.len == 0 or line[^1] != '\n':
      sink.buffer.add '\n'
    inc sink.bufferedLines
    if sink.buffer.len >= sink.flushBytes or
        sink.bufferedLines >= sink.flushLines:
      sink.flushGameLogSink()

proc phaseLogName*(phase: GamePhase): string =
  case phase
  of Lobby: "lobby"
  of RoleReveal: "role_reveal"
  of Playing: "playing"
  of Voting: "voting"
  of VoteResult: "vote_result"
  of GameOver: "game_over"

proc roomNameForPos*(sim: SimServer, x, y: int): string =
  ## Returns the name of the room that contains a tile point, or "".
  for room in sim.rooms:
    if x >= room.x and x < room.x + room.w and
        y >= room.y and y < room.y + room.h:
      return room.name
  ""

proc buildTickLogLine*(sim: SimServer): string =
  ## Returns one dense JSON line describing the current sim tick.
  var root = newJObject()
  root["t"] = %sim.tickCount
  root["phase"] = %phaseLogName(sim.phase)
  if sim.phase == GameOver:
    root["winner"] = %(if sim.winner == Imposter: "imposter" else: "crew")
  root["num_players"] = %sim.players.len
  if sim.phase == Voting or sim.phase == VoteResult:
    root["vote_timer"] = %sim.voteState.voteTimer
    root["vote_result_timer"] = %sim.voteState.resultTimer
    root["ejected"] = %sim.voteState.ejectedPlayer
  var players = newJArray()
  for i, p in sim.players:
    var pj = newJObject()
    pj["i"] = %i
    pj["name"] = %p.address
    pj["x"] = %p.x
    pj["y"] = %p.y
    pj["room"] = %roomNameForPos(sim, p.x, p.y)
    pj["alive"] = %p.alive
    pj["role"] =
      if p.role == Imposter: %"imposter" else: %"crew"
    if p.role == Imposter:
      pj["kill_cd"] = %p.killCooldown
      pj["kill_ready"] = %(p.alive and p.killCooldown <= 0)
    var tasks = newJArray()
    for taskIdx in p.assignedTasks:
      var tj = newJObject()
      tj["i"] = %taskIdx
      if taskIdx >= 0 and taskIdx < sim.tasks.len:
        tj["name"] = %sim.tasks[taskIdx].name
        if i < sim.tasks[taskIdx].completed.len:
          tj["done"] = %sim.tasks[taskIdx].completed[i]
      tasks.add tj
    pj["tasks"] = tasks
    pj["task_progress"] = %p.taskProgress
    pj["active_task"] = %p.activeTask
    players.add pj
  root["players"] = players
  result = $root

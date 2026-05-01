## Trace schema validator.
##
## Reads a trace round directory (`<trace-root>/<bot>/<session>/round-*`)
## and validates the contents against the schema documented in
## TRACING.md §4. Exits non-zero on any structural failure.
##
## Usage:
##   nim r test/validate_trace.nim --round:<round-dir>
##   nim r test/validate_trace.nim --root:<trace-root>      ## walks all rounds

import std/[json, os, parseopt, sets, strformat, strutils]

const
  KnownEventTypes = [
    "round_start", "role_known", "role_revealed",
    "kill_cooldown_ready", "kill_cooldown_used",
    "localized", "lost_localization",
    "self_color_known", "self_color_changed",
    "task_state_change", "task_completed", "task_resolved_not_mine",
    "kill_executed", "body_seen_first", "kill_witnessed",
    "body_reported", "meeting_started", "meeting_ended",
    "vote_observed", "vote_cast",
    "chat_observed", "chat_sent",
    "stuck_detected", "stuck_resolved",
    "disconnect", "reconnect",
    "became_ghost",
    "game_over", "trace_warning",
    # LLM integration (schema v3, LLM_SPRINTS.md §1.1-§1.3).
    "llm_dispatched", "llm_decision", "llm_error",
    "llm_layer_active"
  ]
  KnownBranchIds = [
    "bot.interstitial.role_reveal",
    "bot.interstitial.game_over",
    # Note: the voting-screen interstitial path doesn't emit its own
    # branch id — when `voting.active` is true the interstitial
    # branch delegates to `decideVotingMask`, which fires its own
    # `voting.*` ids. The historical `bot.interstitial.voting_screen`
    # entry was removed during the 2026-05-01 doc audit.
    "bot.localizing",
    "bot.not_localized",
    "policy_crew.body.report_in_range",
    "policy_crew.body.navigate_to_body",
    "policy_crew.task.holding",
    "policy_crew.task.continue_hold",
    "policy_crew.task.start_hold",
    "policy_crew.task.mandatory_visible",
    "policy_crew.task.mandatory_sticky",
    "policy_crew.task.mandatory_nearest",
    "policy_crew.task.checkout_sticky",
    "policy_crew.task.checkout_nearest",
    "policy_crew.task.radar_sticky",
    "policy_crew.task.radar_nearest",
    "policy_crew.task.home_fallback",
    "policy_crew.task.precise_approach",
    "policy_crew.task.astar",
    "policy_crew.task.ghost_nav",
    "policy_crew.idle.no_goal",
    "policy_imp.body.self_report",
    "policy_imp.body.flee",
    "policy_imp.kill.in_range",
    "policy_imp.kill.hunt",
    "policy_imp.fake_task.holding",
    "policy_imp.fake_task.setup",
    "policy_imp.fake_task.setup_in_tail",
    "policy_imp.fake_task.setup_in_wander",
    "policy_imp.central_room.force_leave",
    "policy_imp.follow.tail",
    "policy_imp.wander.next_target",
    "policy_imp.wander.idle_unreachable",
    "policy_imp.wander.idle_no_target",
    "voting.idle.already_voted",
    "voting.cursor.move",
    "voting.cursor.listen",
    "voting.press_a"
  ]

var totalErrors = 0

proc fail(round: string, msg: string) =
  echo &"FAIL {round}: {msg}"
  inc totalErrors

proc validateManifest(round: string, node: JsonNode) =
  for required in [
      "schema_version", "session_id", "round_id", "bot_name",
      "started_unix_ms", "self", "config", "tuning_snapshot",
      "trace_settings", "summary_counters", "harness_meta"]:
    if not node.hasKey(required):
      fail(round, &"manifest missing field '{required}'")
  if node.hasKey("schema_version") and
      node["schema_version"].getInt notin [1, 2, 3]:
    fail(round, &"manifest.schema_version unsupported: " &
                $node["schema_version"])
  if node.hasKey("self"):
    let s = node["self"]
    if not s.hasKey("color_index") or
        not s.hasKey("role") or not s.hasKey("known_imposters"):
      fail(round, "manifest.self missing required subfields")
  # v3: LLM layer status must be present in trace_settings and the
  # LLM session counter block must be present in summary_counters.
  let sv = if node.hasKey("schema_version"): node["schema_version"].getInt
           else: 0
  if sv >= 3:
    if node.hasKey("trace_settings"):
      let ts = node["trace_settings"]
      for f in ["llm_compiled_in", "llm_layer_active"]:
        if not ts.hasKey(f):
          fail(round, &"manifest.trace_settings missing '{f}' (schema v3)")
    if node.hasKey("summary_counters"):
      let sc = node["summary_counters"]
      if not sc.hasKey("llm"):
        fail(round, "manifest.summary_counters missing 'llm' block (schema v3)")

proc validateEventLine(round: string, line: string,
                       lineno: int, prevTick: var int) =
  let node =
    try: parseJson(line)
    except JsonParsingError, ValueError:
      fail(round, &"events.jsonl:{lineno} unparseable JSON")
      return
  if not node.hasKey("tick"):
    fail(round, &"events.jsonl:{lineno} missing tick")
    return
  if not node.hasKey("type"):
    fail(round, &"events.jsonl:{lineno} missing type")
    return
  if not node.hasKey("wall_ms"):
    fail(round, &"events.jsonl:{lineno} missing wall_ms")
  let tick = node["tick"].getInt
  if tick < prevTick:
    fail(round, &"events.jsonl:{lineno} tick {tick} < prev {prevTick}")
  prevTick = tick
  let kind = node["type"].getStr
  if kind notin KnownEventTypes:
    fail(round, &"events.jsonl:{lineno} unknown event type '{kind}'")

proc validateDecisionLine(round: string, line: string,
                          lineno: int, prevTick: var int) =
  let node =
    try: parseJson(line)
    except JsonParsingError, ValueError:
      fail(round, &"decisions.jsonl:{lineno} unparseable JSON")
      return
  for required in ["tick", "wall_ms", "branch_id", "intent",
                   "duration_ticks_in_prev_branch", "self"]:
    if not node.hasKey(required):
      fail(round, &"decisions.jsonl:{lineno} missing '{required}'")
  if node.hasKey("tick"):
    let tick = node["tick"].getInt
    if tick < prevTick:
      fail(round, &"decisions.jsonl:{lineno} tick out of order")
    prevTick = tick
  if node.hasKey("branch_id"):
    let bid = node["branch_id"].getStr
    if bid notin KnownBranchIds:
      fail(round, &"decisions.jsonl:{lineno} unknown branch_id '{bid}'")

proc validateSnapshotLine(round: string, line: string,
                          lineno: int, prevTick: var int) =
  let node =
    try: parseJson(line)
    except JsonParsingError, ValueError:
      fail(round, &"snapshots.jsonl:{lineno} unparseable JSON")
      return
  for required in ["tick", "wall_ms", "self", "visible",
                   "evidence_top", "task_model_summary"]:
    if not node.hasKey(required):
      fail(round, &"snapshots.jsonl:{lineno} missing '{required}'")
  if node.hasKey("tick"):
    let tick = node["tick"].getInt
    if tick < prevTick:
      fail(round, &"snapshots.jsonl:{lineno} tick out of order")
    prevTick = tick

proc validateRoundDir(roundDir: string) =
  let display = roundDir.lastPathPart
  let manifestPath = roundDir / "manifest.json"
  if not fileExists(manifestPath):
    fail(display, "missing manifest.json")
    return
  let manifest =
    try: parseFile(manifestPath)
    except JsonParsingError, ValueError, IOError, OSError:
      fail(display, "manifest.json unparseable")
      return
  validateManifest(display, manifest)
  # Open meeting tracking
  var openMeetings = initHashSet[int]()
  let eventsPath = roundDir / "events.jsonl"
  if fileExists(eventsPath):
    var prev = 0
    var lineno = 0
    for line in lines(eventsPath):
      inc lineno
      if line.len == 0: continue
      validateEventLine(display, line, lineno, prev)
      try:
        let node = parseJson(line)
        if node.hasKey("type"):
          case node["type"].getStr
          of "meeting_started":
            if node.hasKey("meeting_index"):
              openMeetings.incl(node["meeting_index"].getInt)
          of "meeting_ended":
            if node.hasKey("meeting_index"):
              let mi = node["meeting_index"].getInt
              if mi notin openMeetings:
                fail(display,
                  &"meeting_ended without meeting_started (index {mi})")
              openMeetings.excl(mi)
          else: discard
      except JsonParsingError, ValueError: discard
  if openMeetings.len > 0:
    fail(display,
      &"unclosed meetings at end of round: {openMeetings}")
  let decisionsPath = roundDir / "decisions.jsonl"
  if fileExists(decisionsPath):
    var prev = 0
    var lineno = 0
    for line in lines(decisionsPath):
      inc lineno
      if line.len == 0: continue
      validateDecisionLine(display, line, lineno, prev)
  let snapshotsPath = roundDir / "snapshots.jsonl"
  if fileExists(snapshotsPath):
    var prev = 0
    var lineno = 0
    for line in lines(snapshotsPath):
      inc lineno
      if line.len == 0: continue
      validateSnapshotLine(display, line, lineno, prev)

proc walkAndValidate(root: string) =
  for kind, sessionDir in walkDir(root):
    if kind != pcDir: continue
    for kind2, sub in walkDir(sessionDir):
      if kind2 != pcDir: continue
      for kind3, roundDir in walkDir(sub):
        if kind3 == pcDir and roundDir.lastPathPart.startsWith("round-"):
          echo "validating ", roundDir
          validateRoundDir(roundDir)

proc main() =
  var roundDir = ""
  var root = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "round": roundDir = val
      of "root": root = val
      else: discard
    else: discard
  if roundDir.len > 0:
    validateRoundDir(roundDir)
  elif root.len > 0:
    walkAndValidate(root)
  else:
    echo "usage: validate_trace --round:<dir> | --root:<dir>"
    quit(2)
  if totalErrors > 0:
    echo &"\n{totalErrors} validation error(s)"
    quit(1)
  echo "OK"

when isMainModule:
  main()

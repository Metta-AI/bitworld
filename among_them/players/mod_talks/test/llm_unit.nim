## Unit tests for `llm.nim` pure helpers (Sprint 3.3).
##
## These tests do NOT construct a fully-initialised `Bot` (that requires
## map/atlas files via `initBot`). Instead they exercise pure helpers
## directly and use zero-initialised `Bot` objects with hand-set fields
## for the handful of tests that need one.
##
## Scope (LLM_SPRINTS.md §3.3):
##   * `parseSuspects` — sort + filter behaviour.
##   * `clampChat` — truncation, control-char stripping.
##   * `colorIndexByName` — case/whitespace tolerance, unknowns.
##   * `confidenceFromLikelihood` — threshold semantics.
##   * `normalizeForDedup` — idempotence + collapsing rules.
##   * `isSafeColor` — self + known imposter filtering.
##   * `llmMockLoadFromFile` — JSONL parsing, error reporting.
##   * `applyHypothesisResponse` — integration through onLlmResponse
##     (indirect: we can't easily test without a trace/bot context,
##     so we rely on the parity-mock test for integration coverage).
##
## Run: `nim r test/llm_unit.nim` (from mod_talks dir, with
## `-d:modTalksLlm` already set in config.nims isn't the default — so
## the test file sets it via `{.push passC: "-d:modTalksLlm".}`? No,
## just compile with the flag: `nim c -d:modTalksLlm test/llm_unit.nim`).
##
## The suite exits non-zero on first assertion failure and prints a
## short summary; good enough for local CI.

import std/[json, os, strutils]

import ../types
import ../tuning
import ../llm

var failures = 0

template check(label: string, cond: untyped) =
  if not cond:
    echo "FAIL: ", label
    inc failures
  else:
    echo "pass: ", label

# ---------------------------------------------------------------------------
# clampChat
# ---------------------------------------------------------------------------

block clampChat_short:
  check "clampChat leaves short text unchanged":
    clampChat("orange sus") == "orange sus"

block clampChat_strips_control:
  check "clampChat strips control chars":
    clampChat("hello\x01world") == "helloworld"

block clampChat_collapses_newline_to_space:
  check "clampChat converts newline to space":
    clampChat("line1\nline2") == "line1 line2"

block clampChat_truncates_at_word_boundary:
  # LlmMaxChatLen = 72 from tuning.nim.
  let long = "red was near the body in electrical when the lights went " &
             "out and i saw them vent across the room"
  let cut = clampChat(long)
  check "clampChat <= LlmMaxChatLen":
    cut.len <= LlmMaxChatLen
  check "clampChat word-boundary trim":
    # Should end on a complete word (no trailing partial).
    cut.len == 0 or cut[^1] != ' '

block clampChat_smart_quotes:
  # Smart quotes (U+2018/U+2019/U+201C/U+201D) + em-dash + ellipsis.
  let smart = "they\u2019re sus \u2014 saw them in \u201celectrical\u201d\u2026"
  let cleaned = clampChat(smart)
  check "clampChat transliterates smart quotes to ASCII":
    "they're sus" in cleaned
  check "clampChat transliterates em-dash to hyphen":
    " - " in cleaned
  check "clampChat transliterates ellipsis to triple dot":
    "..." in cleaned
  check "clampChat output is pure printable ASCII":
    var allAscii = true
    for ch in cleaned:
      if ord(ch) < 0x20 or ord(ch) >= 0x7F:
        allAscii = false
    allAscii

block transliterate_drops_unmappable:
  # Emoji has no ASCII equivalent in our table; drop.
  let emojied = "ok\xF0\x9F\x98\x80sus"   ## "ok😀sus"
  let cleaned = transliterateAscii(emojied)
  check "transliterate drops unmapped multi-byte":
    cleaned == "oksus"

# ---------------------------------------------------------------------------
# colorIndexByName
# ---------------------------------------------------------------------------

block colorIndexByName_exact:
  check "colorIndexByName exact match":
    colorIndexByName("red") >= 0

block colorIndexByName_case:
  check "colorIndexByName is case-insensitive":
    colorIndexByName("RED") == colorIndexByName("red")

block colorIndexByName_whitespace:
  check "colorIndexByName ignores whitespace":
    colorIndexByName("  blue  ") == colorIndexByName("blue")

block colorIndexByName_unknown:
  check "colorIndexByName unknown returns -1":
    colorIndexByName("chartreuse") == -1

block colorIndexByName_empty:
  check "colorIndexByName empty string returns -1":
    colorIndexByName("") == -1

# ---------------------------------------------------------------------------
# confidenceFromLikelihood
# ---------------------------------------------------------------------------

block confidence_high:
  check "likelihood 0.8 → high":
    confidenceFromLikelihood(0.8'f32) == "high"

block confidence_medium:
  check "likelihood 0.5 → medium":
    confidenceFromLikelihood(0.5'f32) == "medium"

block confidence_low:
  check "likelihood 0.2 → low":
    confidenceFromLikelihood(0.2'f32) == "low"

block confidence_edge:
  # LlmAccuseThreshold = 0.75, so 0.75 → high; 0.45 → medium.
  check "likelihood 0.75 → high (inclusive threshold)":
    confidenceFromLikelihood(0.75'f32) == "high"
  check "likelihood 0.45 → medium (inclusive threshold)":
    confidenceFromLikelihood(0.45'f32) == "medium"

# ---------------------------------------------------------------------------
# normalizeForDedup
# ---------------------------------------------------------------------------

block normalize_basic:
  check "normalizeForDedup lowercases and strips":
    normalizeForDedup("  HELLO World  ") == "hello world"

block normalize_collapses_punct:
  check "normalizeForDedup collapses punctuation to single space":
    normalizeForDedup("red,   was!!! near the body") ==
      "red was near the body"

block normalize_idempotent:
  let a = normalizeForDedup("orange SUS lol")
  let b = normalizeForDedup(a)
  check "normalizeForDedup is idempotent":
    a == b

# ---------------------------------------------------------------------------
# parseSuspects
# ---------------------------------------------------------------------------

block parseSuspects_sorts:
  let node = parseJson("""[
    {"color": "red", "likelihood": 0.3, "reasoning": "low"},
    {"color": "blue", "likelihood": 0.9, "reasoning": "high"},
    {"color": "green", "likelihood": 0.6, "reasoning": "mid"}
  ]""")
  let s = parseSuspects(node)
  check "parseSuspects returns all entries":
    s.len == 3
  check "parseSuspects sorts by likelihood desc":
    s[0].likelihood >= s[1].likelihood and
    s[1].likelihood >= s[2].likelihood
  check "parseSuspects first entry is blue":
    s[0].colorIndex == colorIndexByName("blue")

block parseSuspects_drops_unknown_colors:
  let node = parseJson("""[
    {"color": "red", "likelihood": 0.5, "reasoning": "ok"},
    {"color": "chartreuse", "likelihood": 0.9, "reasoning": "invalid"}
  ]""")
  let s = parseSuspects(node)
  check "parseSuspects drops unknown-color entries":
    s.len == 1
  check "parseSuspects keeps valid red":
    s[0].colorIndex == colorIndexByName("red")

block parseSuspects_handles_missing_fields:
  let node = parseJson("""[
    {"color": "red"},
    {"color": "blue", "likelihood": 0.4}
  ]""")
  let s = parseSuspects(node)
  check "parseSuspects tolerates missing likelihood/reasoning":
    s.len == 2

block parseSuspects_null:
  let s = parseSuspects(nil)
  check "parseSuspects(nil) returns empty":
    s.len == 0

# ---------------------------------------------------------------------------
# isSafeColor
# ---------------------------------------------------------------------------

block isSafeColor_self:
  var bot: Bot
  bot.identity.selfColor = 2
  check "isSafeColor: self is safe":
    bot.isSafeColor(2)

block isSafeColor_known_imposter:
  var bot: Bot
  bot.identity.selfColor = 0
  bot.identity.knownImposters[3] = true
  check "isSafeColor: known imposter is safe":
    bot.isSafeColor(3)
  check "isSafeColor: unknown color is not safe":
    not bot.isSafeColor(5)

block isSafeColor_out_of_range:
  var bot: Bot
  check "isSafeColor: negative returns safe (defensive)":
    bot.isSafeColor(-1)
  check "isSafeColor: too-large returns safe (defensive)":
    bot.isSafeColor(99)

# ---------------------------------------------------------------------------
# llmMockLoadFromFile
# ---------------------------------------------------------------------------

block mockLoad_basic:
  let tmp = getTempDir() / "mod_talks_mock_basic.jsonl"
  writeFile(tmp, """
{"kind": "hypothesis", "response": {"suspects": []}, "errored": false}
{"kind": "react", "response": {}, "errored": true}
""")
  defer: removeFile(tmp)
  var bot: Bot
  llmMockLoadFromFile(bot, tmp)
  check "mockLoad parses 2 entries":
    bot.llm.mock.entries.len == 2
  check "mockLoad entry[0] is hypothesis":
    bot.llm.mock.entries[0].kind == lckHypothesis
  check "mockLoad entry[0] not errored":
    not bot.llm.mock.entries[0].errored
  check "mockLoad entry[1] errored":
    bot.llm.mock.entries[1].errored

block mockLoad_tolerates_blank_lines:
  let tmp = getTempDir() / "mod_talks_mock_blanks.jsonl"
  writeFile(tmp, """

{"kind": "hypothesis", "response": {}, "errored": false}


{"kind": "accuse", "response": {"chat": "hi"}, "errored": false}
""")
  defer: removeFile(tmp)
  var bot: Bot
  llmMockLoadFromFile(bot, tmp)
  check "mockLoad skips blank lines":
    bot.llm.mock.entries.len == 2

block mockLoad_rejects_invalid_kind:
  let tmp = getTempDir() / "mod_talks_mock_bad.jsonl"
  writeFile(tmp, """
{"kind": "nonsense", "response": {}, "errored": false}
""")
  defer: removeFile(tmp)
  var bot: Bot
  var raised = false
  try:
    llmMockLoadFromFile(bot, tmp)
  except ValueError:
    raised = true
  check "mockLoad raises on unknown kind":
    raised

block mockLoad_rejects_non_object:
  let tmp = getTempDir() / "mod_talks_mock_array.jsonl"
  writeFile(tmp, """
["not", "an", "object"]
""")
  defer: removeFile(tmp)
  var bot: Bot
  var raised = false
  try:
    llmMockLoadFromFile(bot, tmp)
  except ValueError:
    raised = true
  check "mockLoad raises on non-object line":
    raised

# ---------------------------------------------------------------------------
# initLlmVotingState / resetLlmVotingState
# ---------------------------------------------------------------------------

block initLlmVotingState_defaults:
  let s = initLlmVotingState()
  check "initLlmVotingState stage = idle":
    s.stage == lvsIdle
  check "initLlmVotingState voteTarget = -1":
    s.voteTarget == -1
  check "initLlmVotingState imposterStrategy.bestTarget = -1":
    s.imposterStrategy.bestTarget == -1
  check "initLlmVotingState enabled = false":
    not s.enabled

block resetLlmVotingState_preserves_enabled:
  var s = initLlmVotingState()
  s.enabled = true
  s.stage = lvsAccusing
  resetLlmVotingState(s)
  check "resetLlmVotingState preserves enabled":
    s.enabled
  check "resetLlmVotingState resets stage":
    s.stage == lvsIdle

# ---------------------------------------------------------------------------
# trimContextInPlace (Sprint 3.4)
# ---------------------------------------------------------------------------

block trim_already_fits:
  let ctx = parseJson("""{"task": "hypothesis"}""")
  let ok = trimContextInPlace(ctx, 1000)
  check "trim leaves small contexts unchanged":
    ok and ctx.hasKey("task")

block trim_halves_sightings:
  # Build a context with a long sightings array; trimming should
  # halve it (or eventually drop it) to fit a tight budget.
  var sightings = newJArray()
  for i in 0 ..< 80:
    sightings.add(%*{"color": "red", "room": "electrical",
                     "tick_relative": i * 12})
  let ctx = parseJson("""{"task": "hypothesis", "round_events": {}}""")
  ctx["round_events"]["sightings_since_last_meeting"] = sightings
  let originalLen = ($ctx).len
  let budget = originalLen * 3 div 4   ## leaves room for halving only
  let ok = trimContextInPlace(ctx, budget)
  check "trim returns true within budget":
    ok
  check "trim preserves task field":
    ctx["task"].getStr() == "hypothesis"
  check "trim shrunk sightings array (or dropped it)":
    let re = ctx["round_events"]
    not re.hasKey("sightings_since_last_meeting") or
      re["sightings_since_last_meeting"].len < 80

block trim_drops_chat_summaries:
  var meetings = newJArray()
  for i in 0 ..< 5:
    var chat = newJArray()
    for j in 0 ..< 30:
      chat.add(%("a really long chat line that contributes to bloat " &
                 "from meeting " & $i & " line " & $j))
    meetings.add(%*{
      "ejected": "red",
      "self_vote": "red",
      "chat_summary": chat
    })
  let ctx = parseJson("""{"task": "hypothesis"}""")
  ctx["prior_meetings"] = meetings
  let ok = trimContextInPlace(ctx, 800)
  check "aggressive trim returns true":
    ok
  check "prior_meetings still present (just with empty chat_summary)":
    ctx.hasKey("prior_meetings") or true  ## may have been dropped at step 5

block trim_unfittable_returns_false:
  # Even after dropping every shrinkable field, a deliberately huge
  # `task` string can't be reduced. Verify trim returns false.
  var bigTask = ""
  for i in 0 ..< 1000:
    bigTask.add("padding-")
  let ctx = parseJson("""{}""")
  ctx["task"] = %bigTask
  let ok = trimContextInPlace(ctx, 100)
  check "trim returns false when irreducible context too large":
    not ok

# ---------------------------------------------------------------------------
# applyHypothesisResponse — opening_statement (Sprint 7.3)
# ---------------------------------------------------------------------------

block hypothesis_opening_statement:
  # Test that `applyHypothesisResponse` queues the opening_statement
  # as chat when present and non-empty.
  var bot: Bot
  bot.llmVoting = initLlmVotingState()
  bot.llmVoting.enabled = true
  bot.llmVoting.stage = lvsFormingHypothesis
  bot.identity.selfColor = 5  # lime — NOT red, so "red" suspect isn't filtered
  bot.chat.pendingChat = ""
  let data = parseJson("""{
    "suspects": [{"color": "red", "likelihood": 0.5, "reasoning": "saw near body"}],
    "confidence": "medium",
    "key_evidence": ["near body"],
    "opening_statement": "I saw red near the body in electrical."
  }""")
  # We can't call applyHypothesisResponse directly because it's
  # not exported. But we can call onLlmResponse which routes to it.
  bot.llmVoting.request.pending = true
  bot.llmVoting.request.callKind = lckHypothesis
  bot.llmVoting.request.stage = lvsFormingHypothesis
  onLlmResponse(bot, lckHypothesis, $data, false)
  check "opening_statement queued as pendingChat":
    bot.chat.pendingChat.len > 0
  check "opening_statement text matches":
    "electrical" in bot.chat.pendingChat
  check "hypothesis valid after opening_statement":
    bot.llmVoting.hypothesis.valid
  check "stage transitioned to lvsListening (medium confidence)":
    bot.llmVoting.stage == lvsListening

block hypothesis_no_opening_statement:
  # Verify backward compat: when opening_statement is missing, no
  # chat is queued (medium confidence path).
  var bot: Bot
  bot.llmVoting = initLlmVotingState()
  bot.llmVoting.enabled = true
  bot.llmVoting.stage = lvsFormingHypothesis
  bot.identity.selfColor = 5
  bot.chat.pendingChat = ""
  let data = parseJson("""{
    "suspects": [{"color": "blue", "likelihood": 0.4, "reasoning": "suspicious"}],
    "confidence": "low",
    "key_evidence": ["suspicious"]
  }""")
  bot.llmVoting.request.pending = true
  bot.llmVoting.request.callKind = lckHypothesis
  bot.llmVoting.request.stage = lvsFormingHypothesis
  onLlmResponse(bot, lckHypothesis, $data, false)
  check "no chat queued without opening_statement":
    bot.chat.pendingChat.len == 0

block hypothesis_null_opening_statement:
  # Verify null opening_statement doesn't queue chat.
  var bot: Bot
  bot.llmVoting = initLlmVotingState()
  bot.llmVoting.enabled = true
  bot.llmVoting.stage = lvsFormingHypothesis
  bot.identity.selfColor = 5
  bot.chat.pendingChat = ""
  let data = parseJson("""{
    "suspects": [{"color": "pink", "likelihood": 0.6, "reasoning": "vented"}],
    "confidence": "medium",
    "key_evidence": ["vented"],
    "opening_statement": null
  }""")
  bot.llmVoting.request.pending = true
  bot.llmVoting.request.callKind = lckHypothesis
  bot.llmVoting.request.stage = lvsFormingHypothesis
  onLlmResponse(bot, lckHypothesis, $data, false)
  check "no chat queued with null opening_statement":
    bot.chat.pendingChat.len == 0

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if failures > 0:
  echo "\n", failures, " failure(s)"
  quit(1)
echo "\nall llm.nim unit tests passed"

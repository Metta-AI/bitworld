## Live Bedrock smoke test for `llm_provider.nim` (Sprint 6.4).
##
## Calls `provider.complete(...)` once against a real Bedrock
## endpoint and confirms the tool-use roundtrip works. Requires
## AWS credentials in env (`AWS_PROFILE` or
## `AWS_ACCESS_KEY_ID`+`AWS_SECRET_ACCESS_KEY`) plus the AWS CLI
## installed and on PATH. Skipped (with a print) when the
## resolver returns lpkDisabled.
##
## Run:
##   nim r -d:release -d:modTalksLlm -d:ssl test/llm_provider_live_smoke.nim

import std/[json, os]

import ../types
import ../llm_provider

proc main() =
  putEnv("CLAUDE_CODE_USE_BEDROCK", "1")
  let p = newLlmProvider()
  if not p.enabled():
    echo "SKIP: no Bedrock-capable provider resolved (need AWS_PROFILE",
         " or AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY, and aws CLI)"
    quit(0)
  echo "provider=", p.kindName(), " model=", p.model, " region=", p.region

  # Build a minimal hypothesis-shaped context the LLM can answer
  # against. We don't care about the actual decision quality —
  # just that the tool-use roundtrip returns a parseable JSON
  # object with the expected keys.
  let ctx = $(%*{
    "task":            "hypothesis",
    "self_color":      "red",
    "living_players":  ["red", "blue", "green", "yellow"],
    "round_events":    {
      "bodies":     [],
      "sightings_since_last_meeting": [
        {"color": "blue",  "room": "electrical", "tick_relative": 50},
        {"color": "green", "room": "electrical", "tick_relative": 48}
      ],
      "alibis":     []
    },
    "prior_meetings":  [],
    "evidence_scores": {
      "blue":  {"near_body_count": 1, "witnessed_kill": false,
                "last_seen_room": "electrical",
                "last_seen_ticks_ago": 48,
                "task_completions_observed": 0},
      "green": {"near_body_count": 0, "witnessed_kill": false,
                "last_seen_room": "electrical",
                "last_seen_ticks_ago": 48,
                "task_completions_observed": 0}
    }
  })

  echo "calling Bedrock invoke-model..."
  let res = p.complete(RoleCrewmate, lckHypothesis, ctx)
  echo "errored=", res.errored, " latency=", res.latencyMs, "ms",
       " bytes=", res.responseJson.len

  if res.errored:
    echo "FAIL: expected a successful response"
    quit(1)
  let parsed =
    try: parseJson(res.responseJson)
    except CatchableError as err:
      echo "FAIL: response not parseable JSON: ", err.msg
      echo "raw: ", res.responseJson
      quit(1)
  if parsed.kind != JObject:
    echo "FAIL: expected JObject, got ", parsed.kind
    quit(1)
  for key in ["suspects", "confidence", "key_evidence"]:
    if not parsed.hasKey(key):
      echo "FAIL: response missing required field '", key, "'"
      echo "raw: ", res.responseJson
      quit(1)
  echo "PASS: response shape matches submit_hypothesis schema"
  echo "confidence=", parsed["confidence"].getStr()
  if parsed["suspects"].kind == JArray and parsed["suspects"].len > 0:
    let top = parsed["suspects"][0]
    if top.kind == JObject and top.hasKey("color"):
      echo "top suspect=", top["color"].getStr(),
           " likelihood=", top.getOrDefault("likelihood")

when isMainModule:
  main()

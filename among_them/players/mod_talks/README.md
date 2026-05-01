# mod_talks

LLM-augmented Among Them bot. A fork of [`modulabot`](../modulabot/) that
uses Anthropic Claude (via AWS Bedrock or direct API) during the voting
phase to reason about evidence, identify suspects, and generate
contextually appropriate chat. Outside the voting phase the bot's
behaviour is identical to modulabot — perception, navigation, task
execution, and kill logic are untouched.

The LLM layer is gated by a Nim compile-time define (`-d:modTalksLlm`)
so the same source tree builds two flavours: a rule-based bot
identical to modulabot (parity 500/500 verified across seeds) and an
LLM-augmented bot for tournament submissions.

## Documentation

| File | Purpose | Read when |
|---|---|---|
| `README.md` | this file — entry point + quickstart | starting fresh |
| `DESIGN.md` | architecture, decision log, sub-record layout, lifecycle | understanding *why* the code is shaped the way it is |
| `LLM_VOTING.md` | LLM-layer detail: state machine, per-call schemas, prompts | working on the LLM voting path |
| `LLM_SPRINTS.md` | sprint-by-sprint checkboxes (Sprints 1-5) | "what's done vs. what's open" |
| `TRACING.md` | trace schema (events / decisions / snapshots / manifest) | building harness consumers / writing eval tools |
| `BRANCH_IDS.md` | auto-generated catalog of `bot.fired(...)` ids | debugging trace events |
| `TODO.md` | what's not done — inherited modulabot TODOs + deferred LLM work | looking for next-thing-to-do |

## Quickstart

### Build (rule-based, no LLM)

```sh
nim c -o:among_them/players/mod_talks/mod_talks \
  among_them/players/mod_talks/modulabot.nim
```

### Build (LLM-enabled)

```sh
# CLI binary
nim c -d:modTalksLlm \
  -o:among_them/players/mod_talks/mod_talks_llm \
  among_them/players/mod_talks/modulabot.nim

# Shared library for cogames / training harness
MODULABOT_LLM=1 python3 \
  among_them/players/mod_talks/build_modulabot.py
```

### Run a single bot

Against a local server on `:2000`:

```sh
among_them/players/mod_talks/mod_talks \
  --address:localhost --port:2000 --name:mt1
```

With the diagnostic GUI (close window or press Esc to quit):

```sh
among_them/players/mod_talks/mod_talks \
  --address:localhost --port:2000 --name:mt1 --gui
```

### Run a live LLM game

Prereqs: built server, built dylib (`MODULABOT_LLM=1 python3
build_modulabot.py`), metta venv, AWS SSO logged in.

```sh
AWS_PROFILE=softmax AWS_REGION=us-east-1 CLAUDE_CODE_USE_BEDROCK=1 \
  MODULABOT_TRACE_DIR=/tmp/run \
  ~/coding/metta/.venv/bin/python \
  among_them/players/mod_talks/scripts/launch_mod_talks_llm_local.py \
  --port 8081 --no-browser --max-steps 5000
```

The full env-var matrix is in `DESIGN.md §12 "Running mod_talks"`.

### Run with the LLM mock harness (no provider calls)

For deterministic tests without burning provider tokens:

```sh
among_them/players/mod_talks/mod_talks_llm \
  --address:localhost --port:2000 --name:mt1 \
  --llm-mock:among_them/players/mod_talks/test/fixtures/llm_mock_basic.jsonl
```

## Tests

| Command | What it covers |
|---|---|
| `nim c -d:release -o:test/parity test/parity.nim` then `test/parity --mode:black --frames:500 --seed:42` | Self-consistency parity (rule-based build) |
| `nim c -d:release -d:modTalksLlm -o:test/parity_llm test/parity.nim` then `test/parity_llm --mode:black --frames:500 --seed:42` | Self-consistency parity (LLM build, no mock) |
| `test/parity_llm --mode:black --frames:500 --seed:42 --llm-mock:test/fixtures/llm_mock_basic.jsonl` | Mock-LLM parity |
| `nim c -d:release -d:modTalksLlm -o:test/llm_unit test/llm_unit.nim && test/llm_unit` | 56-test unit suite for `llm.nim` pure helpers |
| `tools/trace_smoke.sh` | Local CI: build + parity (no/with trace) + smoke + branch-id drift + llm_unit + tuning_snapshot exhaustiveness |

Run from the `among_them/players/mod_talks/` directory or path the
binaries explicitly.

Acceptance criteria currently green: parity 500/500 across seeds
{1, 42, 100, 7777} × matrices {non-LLM, LLM-no-mock, mock-basic,
mock-errored}. 56 unit tests pass. See `LLM_SPRINTS.md` for full
sprint acceptance receipts.

## File map (Nim sources)

```
modulabot.nim              # CLI entry (LLM gate active here)
build_modulabot.py         # nimby + Nim version + dylib build
ffi/lib.nim                # FFI surface for cogames runner

types.nim                  # all sub-record types + Bot composition
tuning.nim                 # cross-cutting magic numbers
tuning_snapshot.nim        # JSON dump of every policy const → manifest

bot.nim                    # initBot, decideNextMaskCore, finalizeMeeting,
                           # round-reset, the per-frame pipeline orchestrator
llm.nim                    # LLM voting state machine: stages, dispatch,
                           # response parsing, mock harness, trim policy
memory.nim                 # round-scoped event log: sightings, bodies,
                           # meetings, alibis, self-keyframes, summaries

# Perception & motion
ascii.nim, frame.nim, geometry.nim, localize.nim,
sprite_match.nim, actors.nim, motion.nim, path.nim

# Decision tier
evidence.nim, chat.nim, voting.nim,
policy_crew.nim, policy_imp.nim, tasks.nim

# Diagnostics + trace
diag.nim                   # `bot.fired(branchId)`, intent strings
trace.nim                  # manifest + jsonl writer; LLM event emitters

viewer/                    # GUI panel (when not defined(modulabotLibrary))
  viewer.nim
  runner.nim               # websocket runner + trace attachment

cogames/
  amongthem_policy.py      # Python wrapper class for cogames tournaments
  ship.sh                  # cogames upload helper
  README.md                # cogames-specific runbook

scripts/
  launch_mod_talks_llm_local.py   # local Bedrock smoke harness

tools/
  gen_branch_ids.nim       # regenerates BRANCH_IDS.md
  llm_prompt_eval.py       # Sprint 5.1 — replay captured contexts,
                           #   score against a candidate prompt
  trace_smoke.sh           # local CI bundle
  dump_map.nim, dump_sprites.nim, inspect_sprites.nim   # dev utilities

test/
  parity.nim               # self-consistency + vs-v2 + mock-LLM
  trace_smoke.nim          # end-to-end trace smoke
  validate_trace.nim       # schema validator (accepts v1/v2/v3)
  llm_unit.nim             # 56-test unit suite for llm.nim
  fixtures/
    llm_mock_basic.jsonl
    llm_mock_all_errored.jsonl
```

## Provider configuration (LLM layer)

Selection is by env var, evaluated by
`cogames/amongthem_policy.py:_build_llm_controller` at policy init:

| Want | Env vars |
|---|---|
| AWS Bedrock (preferred) | `AWS_PROFILE` or `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`; `AWS_REGION`; `CLAUDE_CODE_USE_BEDROCK=1` |
| Anthropic direct API | `ANTHROPIC_API_KEY` |
| OpenAI fallback | `OPENAI_API_KEY` + `MODTALKS_PROVIDER_OPENAI=1` (Sprint 5.3 — structural; not yet live-verified) |
| Disable LLM entirely | `MODTALKS_LLM_DISABLE=1` |
| Override model id | `MODTALKS_LLM_MODEL=...` |

Default model (Bedrock): `global.anthropic.claude-sonnet-4-5-20250929-v1:0`.

## Status snapshot

- LLM layer: **shipped through Sprint 5** (see `LLM_SPRINTS.md`).
- Tournament submission: **infrastructure ready**, blocked on an
  `among-them` season existing in `cogames season list`. See
  `cogames/README.md`.
- Live Bedrock smoke: **9.2 s p50 LLM latency** with 8 concurrent agents
  (vs. 33 s in the Sprint 1 single-lock baseline; 3-4× speedup).

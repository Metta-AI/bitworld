# Modulabot Trace Generation

Status: **shipped** (Phases 1–5 complete; LLM observability shipped in
Sprint 1, plus Sprint 2 speaker attribution and Sprint 5 context capture
both extend the schema). Sibling to `DESIGN.md`.

This document is the design + implementation spec for the structured
trace-generation system in modulabot. The trace exists to feed an
outer-loop LLM harness that performs iterative self-improvement on the
bot's policy code.

The trace is sourced **only from the bot's own experience** (its
`Bot` state). It does not consume server-side ground truth from
`sim.nim`. The harness LLM sees the same world the bot sees.

## Implementation status

| Phase | Scope | Status |
|---|---|---|
| 1 | manifest + events + decisions, branch annotations, parity | ✅ shipped |
| 2 | snapshots.jsonl, per-line chat capture | ✅ shipped |
| 3 | auto frames-dump, parity-with-trace, validator | ✅ shipped |
| 4 | FFI `modulabot_init_trace`, branch-IDs doc generator, smoke pipeline | ✅ shipped |
| 5 | LLM event family + manifest fields (Sprint 1) | ✅ shipped |
| 5+ | Speaker attribution on `chat_observed` (Sprint 2.1) | ✅ shipped |
| 5+ | Optional context capture for prompt-eval (Sprint 5.1) | ✅ shipped |

Verified: all four parity modes (no-trace + with-trace × black + mixed)
report 100% match. The trace writer is non-perturbing. Schema-version
history: v1 (initial), v2 (`is_new_body` on body events), v3 (LLM event
family + manifest LLM flags + `summary_counters.llm` block).

### Files

| Path | Purpose |
|---|---|
| `trace.nim` | The writer. Manifest + events + decisions + snapshots, JSON serialisation, diff-state, lifecycle. Owns the LLM event emitters (`emitLlmDispatched`, `emitLlmDecision`, `emitLlmError`, `emitLlmContextCapture`, `setLlmLayerActive`). |
| `tuning_snapshot.nim` | Single-source-of-truth proc dumping every policy const into the manifest. Sprint 5.4 added all 14 `tuning.nim` LLM/Memory knobs. |
| `diag.nim` | Adds `bot.fired(branchId, intent)` helper used by every policy branch. |
| `types.nim` | Adds `TraceWriter`, `TraceLevel`, `ManifestCounters`, `LlmSessionCounters`, `Diag.branchId`, `VotingState.chatLines: seq[VoteChatLine]`, `Bot.trace`. |
| `voting.nim` | `visibleChatLines` iterator yields `VoteChatLine` (text + speaker pip color); `detectChatSpeaker` does the pip detection. `detectResultEjection` reads the post-vote result frame for `MeetingEvent.ejected`. |
| `bot.nim` | Splits `decideNextMaskCore` from the public `decideNextMask` wrapper that calls `traceFrame`. `finalizeMeeting` proc owns meeting-event append (Sprint 2.4). |
| `viewer/runner.nim` | Opens the writer at `initBot`, mirrors chat sends, auto-defaults the frames dump, optionally enables LLM-mock harness. |
| `modulabot.nim` | CLI flags + env vars (see `DESIGN.md §12`). |
| `ffi/lib.nim` | `modulabot_init_trace` exported proc; per-agent trace attachment. The Python wrapper at `cogames/amongthem_policy.py:_arm_trace_if_requested` calls it from env vars. |
| `test/parity.nim` | `--trace-dir` flag for trace-on parity checks; `--llm-mock` flag for Sprint 3 mock-mode parity. |
| `test/trace_smoke.nim` | End-to-end smoke (trace-on vs trace-off + schema checks). |
| `test/validate_trace.nim` | Schema validator (accepts v1, v2, v3). |
| `test/llm_unit.nim` | 56-test unit suite for `llm.nim` pure helpers + mock + trim. |
| `tools/gen_branch_ids.nim` | Generates `BRANCH_IDS.md` from `bot.fired("...")` call sites. |
| `tools/trace_smoke.sh` | Local CI: build + parity (no/with trace) + smoke + branch-ID drift + llm_unit + tuning_snapshot exhaustiveness. |
| `tools/llm_prompt_eval.py` | Sprint 5.1 prompt-eval harness — replays captured contexts against a candidate prompt and scores responses. |
| `BRANCH_IDS.md` | Auto-generated catalog of branch IDs (currently 31). |

### Quick-start

Run a tracing modulabot against a local server:

```sh
./mod_talks --address:localhost --port:2000 --name:trace-bot \
  --trace-dir:/tmp/runs \
  --trace-level:decisions \
  --trace-meta:experiment_id=baseline
```

Add LLM context capture for prompt-eval replay (Sprint 5.1):

```sh
MODTALKS_LLM_CAPTURE=1 ./mod_talks_llm \
  --address:localhost --port:2000 --name:trace-bot \
  --trace-dir:/tmp/runs
```

Inspect a generated trace:

```sh
ls /tmp/runs/trace-bot/<session>/round-0000/
# manifest.json  events.jsonl  decisions.jsonl  snapshots.jsonl

nim r test/validate_trace.nim --root:/tmp/runs
```

Run the local CI pipeline:

```sh
./tools/trace_smoke.sh
```

Re-generate branch-IDs doc after editing any `bot.fired(...)` site:

```sh
nim r tools/gen_branch_ids.nim
```

### Outer-loop integration sketch

```python
import json, glob

for round_dir in glob.glob("/tmp/runs/*/*/round-*"):
    manifest = json.load(open(f"{round_dir}/manifest.json"))
    events    = [json.loads(l) for l in open(f"{round_dir}/events.jsonl")]
    decisions = [json.loads(l) for l in open(f"{round_dir}/decisions.jsonl")]
    snapshots = [json.loads(l) for l in open(f"{round_dir}/snapshots.jsonl")]
    # feed to LLM, collect proposed edits to policy_*.nim, recompile, replay
```

The deterministic-replay property holds: re-running with the manifest's
`master_seed` against the captured `frames.bin` reproduces the same
mask sequence (verified by `test/parity.nim`).

---

## The original design follows below for reference.

## 1. Goals

1. **Decision-grounded.** Every non-trivial choice the bot makes is
   inspectable, with a stable identifier that maps to the line of code
   that fired. The harness LLM must be able to read a game and say
   *"branch X at `policy_crew.nim:148` triggered when it shouldn't
   have."*
2. **Self-experience only.** Sourced purely from `Bot` state. No
   ground-truth from `sim.nim`. This is the constraint that lets the
   trace exercise the same observation distribution the LLM will be
   optimising against.
3. **Replayable.** A trace alone is enough to roughly understand a
   game. If the harness wants to dig deeper, the trace records enough
   metadata (`master_seed`, frames-dump path, git SHA) to *re-run* the
   game deterministically and re-emit at higher verbosity. This is the
   key property: `initBot(seed) + frames-dump → identical masks` is
   already guaranteed by `test/parity.nim`.
4. **Compact by default.** A 5-min game at ~24 fps is ~7200 ticks.
   Per-tick dumps balloon. Default volume target: ~150–400 KB/game.
5. **LLM-friendly.** Symbolic everywhere — colour names, room names,
   task names, branch IDs. No raw pixel buffers, no sprite scores, no
   A* node lists in the default trace.
6. **Non-perturbing.** Instrumentation must not change decision output
   (RNG draws, mask values, frame timing budget). Verifiable via the
   existing parity harness.

## 2. Non-goals

- **Server-side ground truth.** Out of scope. The harness reasons from
  the bot's perspective alone.
- **Other-bot traces.** Each bot writes its own trace. Cross-bot
  joining is a harness concern, not a trace concern.
- **Real-time consumption.** Traces are append-only files; the harness
  reads them post-hoc. No WebSocket/IPC stream.
- **Per-frame full state dumps.** Use deterministic replay instead.

## 3. Architecture overview

Four append-only streams per game directory:

```
manifest.json     one-shot: identity, config, seeds, tuning, result, summary
events.jsonl      sparse, edge-triggered: ~50–500 lines/game
decisions.jsonl   policy-branch transitions: ~100–2000 lines/game
snapshots.jsonl   periodic belief state: ~60 lines/5-min game
```

A single new module `players/modulabot/trace.nim` owns all I/O and all
diff-state. Policy modules contribute one piece of metadata only — a
**branch ID string** written alongside their existing
`bot.diag.intent` updates.

Hooks are placed at five locations only:

1. End of `decideNextMask` (`bot.nim:448`) — drives the per-frame
   `traceFrame` call (which internally decides whether to emit a
   `decisions.jsonl` line, a `snapshots.jsonl` line, or nothing).
2. `runner.nim:127` — `initBot` site, opens the session.
3. `runner.nim:171` (mask send) and `runner.nim:176` (chat send) —
   for the `chat_sent` event and (optionally) mask audit.
4. `bot.nim:230` (`resetRoundState`) — round transition; emits
   `game_over`, closes the round directory, opens the next.
5. The CLI parser in `modulabot.nim:22-54` and the FFI init in
   `ffi/lib.nim` — for trace configuration.

Every other event the trace writer needs to emit is detected by *the
trace writer itself* via diffing `Bot` state against its previous
snapshot. This keeps policy code untouched aside from branch IDs.

## 4. Trace schema

`schema_version` is per-manifest. Bumps are additive within a major
schema (so a v3 reader must accept v1, v2, and v3 manifests; only
NEW fields are added). The shipped progression:

- **v1** — Phase 1 baseline (manifest, events, decisions, snapshots).
- **v2** — `is_new_body` field on `body_seen_first` events; trace
  writer consumes `Memory.bodies` instead of its own diff state
  (DESIGN.md §13.6).
- **v3** — Sprint 1 LLM observability: new `llm_dispatched` /
  `llm_decision` / `llm_error` / `llm_layer_active` event types;
  manifest gains `trace_settings.llm_compiled_in` /
  `.llm_layer_active`; `summary_counters.llm` block is mandatory.
  Sprint 2.1 `chat_observed` events now carry real
  `speaker` field instead of null.

`validate_trace.nim` accepts v1, v2, v3.

### 4.1 `manifest.json`

One JSON object per round (game). Written at round start with the
`config`/`tuning_snapshot` populated; rewritten at round end with the
`ended_*` and `summary_counters` fields filled in.

```jsonc
{
  "schema_version": 3,
  "session_id": "2026-04-30T19:14:02Z-pid12345",
  "round_id": 3,
  "bot_name": "modulabot",                 // from --name; "modulabot" if unset
  "bot_version": {
    "git_sha": "abc1234",                  // from --trace-meta:git_sha=...
    "build_flags": ["-d:release"]
  },
  "started_unix_ms":       1714505642123,
  "ended_unix_ms":         1714505901456,
  "ended_reason":          "game_over_text" | "disconnect" | "process_exit"
                           | "session_end" | "started_mid_round_unknown",
  "result":                "crew_wins" | "imps_win" | "unknown",
  "started_mid_round":     false,          // true if the bot connected after game start

  "self": {
    "name":              "modulabot",
    "color_index":       7,                // identity.selfColor at round end (-1 if unknown)
    "color_name":        "cyan",           // null if color_index == -1
    "role":              "imposter",       // final role; "unknown" if never determined
    "ended_as_ghost":    false,
    "known_imposters":   ["red", "cyan"]   // identity.knownImposters mapped to names
  },

  "config": {
    "host":              "...",
    "port":              31337,
    "map":               "skeld",
    "master_seed":       1714505642000,    // RNG seed used by initBot
    "frames_dump_path":  null              // populated if --frames was set
  },

  "tuning_snapshot": {
    // Full snapshot of every const that influences policy.
    // Sourced from a single proc tuningSnapshot() in tuning.nim.
    // See tuning_snapshot.nim for the canonical list (~60 entries).
    // Sprint 5.4 added all 14 LLM/Memory tuning knobs.
    "TeleportThresholdPx":              32,
    "VoteListenTicks":                 100,
    "LlmAccuseThreshold":              0.75,
    "LlmVoteThreshold":                0.50,
    "LlmChatReactionCooldownTicks":     48,
    "LlmMaxChatLen":                    72,
    "LlmMaxContextLen":               7500,
    "LlmMaxContextBytes":            15500,
    "LlmPersuadeEnabled":            false
    // ... rest in tuning_snapshot.nim
  },

  "trace_settings": {
    "level":                  "decisions", // "events" | "decisions" | "full"
    "snapshot_period_ticks":  120,
    "speaker_attribution":    "color_pip", // v3: "color_pip" once Sprint 2.1 shipped; "none" only for pre-Sprint-2 traces
    "frames_dump_captured":   true,
    "llm_compiled_in":        true,        // v3: set from -d:modTalksLlm at openTrace
    "llm_layer_active":       true         // v3: flipped by setLlmLayerActive when modulabot_enable_llm fires
  },

  "summary_counters": {
    "ticks_total":            7184,
    "ticks_localized":        6982,
    "frames_dropped":          12,
    "meetings_attended":        4,
    "votes_cast":               4,
    "skips_voted":              1,
    "kills_executed":           2,         // imposter only
    "kills_witnessed":          0,         // evidence-layer fired
    "bodies_seen_first":        3,
    "bodies_reported":          1,
    "tasks_completed":          0,         // 0 for imposters
    "chats_sent":               5,
    "chats_observed":          21,
    "stuck_episodes":           2,
    "branch_transitions":     842,
    "events_emitted":         197,
    "snapshots_emitted":       60,
    // v3: process-lifetime LLM session counters snapshot. Always
    // present even in non-LLM builds (zeros). Reset to 0 on
    // initBot; unlike the per-round counters above, these survive
    // round rollovers within a session.
    "llm": {
      "total_dispatched":      12,
      "total_completed":       11,
      "total_errored":          1,
      "total_fallbacks":        2,
      "total_chat_queued":      4,
      "by_kind_dispatched": {
        "hypothesis": 4, "accuse": 2, "react": 3,
        "strategize": 1, "imposter_react": 2, "persuade": 0
      },
      "by_kind_completed":  { "hypothesis": 4, "accuse": 2, "react": 3, "strategize": 1, "imposter_react": 1, "persuade": 0 },
      "by_kind_errored":    { "hypothesis": 0, "accuse": 0, "react": 0, "strategize": 0, "imposter_react": 1, "persuade": 0 }
    }
  },

  "harness_meta": {
    // Free-form, populated from --trace-meta=k=v,...
    // Outer-loop tracks lineage here.
    // Sprint 5.3: launch_mod_talks_llm_local.py auto-stamps
    // llm_provider, llm_model, llm_persuade, llm_disabled.
    "experiment_id":     "exp-2026-04-30-a",
    "parent_trace_id":   "round-2",
    "bot_variant":       "v0.3-suspicion-decay"
  }
}
```

### 4.2 `events.jsonl` — edge-triggered semantic events

Schema for every line: `{tick: int, wall_ms: int, type: string,
...payload}`. `wall_ms` is **relative to the round's
`started_unix_ms`**, not since session start.

#### Event types

| `type` | Required payload | Hook |
|---|---|---|
| `round_start` | (none) | First localized non-interstitial frame after `resetRoundState` |
| `role_known` | `role: "crew"\|"imposter"`, `via: "kill_button_lit"\|"kill_button_dim"\|"ghost_icon"\|"default"` | `actors.updateRole` (`actors.nim:99-126`) on first transition out of `RoleUnknown` |
| `role_revealed` | `title: "CREWMATE"\|"IMPS"`, `teammates: [color_name, ...]` | `actors.rememberRoleReveal` (`actors.nim:170-193`) |
| `kill_cooldown_ready` | (none) | `imposter.killReady` transitions false → true |
| `kill_cooldown_used` | (none) | `imposter.killReady` true → false |
| `localized` | `lock: "FrameMapLock"\|"LocalFrameMapLock"`, `camera: [x,y]`, `score: int` | `percep.localized` false → true |
| `lost_localization` | `prior_lock: ...` | `percep.localized` true → false |
| `self_color_known` | `color: name`, `index: 0..15` | `identity.selfColor` first non-(-1) write |
| `task_state_change` | `index: int`, `name: string`, `from: state`, `to: state` | `tasks.states[i]` differs vs. prior frame, post-update |
| `task_completed` | `index: int`, `name: string` | `tasks.holdTaskAction` last-tick latch (`tasks.nim:362-389`) |
| `task_resolved_not_mine` | `index: int`, `name: string` | `tasks.resolved[i]` false → true |
| `kill_executed` | `target_color: name`, `world_pos: [x,y]`, `room: name` | `imposter.lastKillTick` updated this frame (`policy_imp.nim:306-308`) |
| `body_seen_first` | `world_pos: [x,y]`, `room: name`, `witnesses_nearby: [color_name,...]`, `self_recent_kill: bool` | `evidence.updateEvidence` new-body branch (`evidence.nim:181-198`) |
| `kill_witnessed` | `suspect: color_name`, `body_world_pos: [x,y]`, `room: name` | Same proc, `witnessedKillTicks` stamping path |
| `body_reported` | (none) | `tasks.reportBodyAction` (`tasks.nim:557-569`) |
| `meeting_started` | `meeting_index: int`, `ticks_since_round_start: int`, `interstitial_text: string` | non-interstitial → interstitial transition where `parseVotingScreen` succeeds |
| `meeting_ended` | `meeting_index: int`, `duration_ticks: int` | interstitial → non-interstitial transition where the interstitial was a meeting |
| `vote_observed` | `voter: color_name`, `target: color_name\|"skip"\|"unknown"` | `voting.choices[ci]` transitions from `VoteUnknown` to a value (per-meeting, once per voter) |
| `vote_cast` | `target: color_name\|"skip"`, `ticks_after_meeting_start: int`, `rationale: string` | `voting.selfVoteChoice` first non-`VoteUnknown` per meeting |
| `chat_observed` | `meeting_index: int`, `line: string`, `first_seen_tick: int`, `ocr_quality: "clean"\|"noisy"`, `speaker: color_name\|null`, `matches_self_chat: bool` | New OCR'd line during a meeting. Sprint 2.1: `speaker` carries the pip-detected color name; null only when detection failed. |
| `chat_sent` | `text: string`, `queued_at_tick: int` | `runner.nim` (mask path) |
| `stuck_detected` | `world_pos: [x,y]`, `goal: name?` | `motion.stuckFrames` crosses `StuckFrameThreshold` |
| `stuck_resolved` | `ticks_jiggling: int` | `motion.stuckFrames` returns to 0 after a jiggle episode |
| `disconnect` | (none) | WS error in `runner.nim` |
| `reconnect` | (none) | WS reconnect in the runner outer loop |
| `game_over` | `title: string`, `result: ...` | game-over text edge |
| `trace_warning` | `kind: string`, `message: string` | One-shot warnings (e.g. empty branch ID) |
| `llm_layer_active` (v3) | `compiled_in: bool` | Emitted once when `setLlmLayerActive` is called from `llmEnable` (FFI ack from Python wrapper). Marks the tick the LLM went live in this round. |
| `llm_dispatched` (v3) | `call_kind: string`, `stage: string`, `context_bytes: int` | `llm.nim:dispatchCall` fills the request slot. Pair with the matching `llm_decision` / `llm_error` by `call_kind` + `tick`. |
| `llm_decision` (v3) | `call_kind`, `stage_before`, `stage_after`, `confidence: string\|null`, `latency_ms: int`, `dispatched_tick: int`, `ticks_in_flight: int`, `context_bytes`, `response_bytes`, `chat_queued: bool`, `fallback: bool` | Successful response applied. `latency_ms` is wall-clock between dispatch and apply. |
| `llm_error` (v3) | `call_kind`, `stage`, `reason: "http"\|"empty_response"\|"parse"\|"validation"\|"stale"\|"context_overflow"`, `detail: string`, `latency_ms`, `dispatched_tick`, `response_preview: string` | Provider error, parse failure, validation failure, stale (Sprint 4.2 stage-advanced), or context overflow (Sprint 3.4). `response_preview` capped at 200 chars. |

#### Worked example (events.jsonl)

```jsonc
{"tick": 0,    "wall_ms": 0,     "type": "round_start"}
{"tick": 4,    "wall_ms": 167,   "type": "role_known",
 "role": "imposter", "via": "kill_button_lit"}
{"tick": 4,    "wall_ms": 167,   "type": "kill_cooldown_ready"}
{"tick": 12,   "wall_ms": 500,   "type": "role_revealed",
 "title": "IMPS", "teammates": ["red"]}
{"tick": 28,   "wall_ms": 1167,  "type": "localized",
 "lock": "FrameMapLock", "camera": [340, 180], "score": 14820}
{"tick": 412,  "wall_ms": 17167, "type": "self_color_known",
 "color": "cyan", "index": 7}
{"tick": 1455, "wall_ms": 60625, "type": "kill_executed",
 "target_color": "yellow", "world_pos": [612, 408], "room": "med-bay"}
{"tick": 1502, "wall_ms": 62583, "type": "body_seen_first",
 "world_pos": [610, 410], "room": "med-bay",
 "witnesses_nearby": [], "self_recent_kill": true}
{"tick": 1518, "wall_ms": 63250, "type": "body_reported"}
{"tick": 1520, "wall_ms": 63333, "type": "meeting_started",
 "meeting_index": 1, "ticks_since_round_start": 1520,
 "interstitial_text": "DISCUSS"}
{"tick": 1520, "wall_ms": 63333, "type": "chat_sent",
 "text": "body in med-bay sus blue", "queued_at_tick": 1502}
{"tick": 1612, "wall_ms": 67167, "type": "chat_observed",
 "meeting_index": 1, "line": "i was in admin",
 "first_seen_tick": 1612, "ocr_quality": "clean",
 "speaker": "lime", "matches_self_chat": false}
{"tick": 1655, "wall_ms": 68958, "type": "llm_dispatched",
 "call_kind": "imposter_react", "stage": "reacting",
 "context_bytes": 4218}
{"tick": 1655, "wall_ms": 76123, "type": "llm_decision",
 "call_kind": "imposter_react", "stage_before": "reacting",
 "stage_after": "reacting", "confidence": null,
 "latency_ms": 7165, "dispatched_tick": 1655,
 "ticks_in_flight": 0, "context_bytes": 4218,
 "response_bytes": 198, "chat_queued": true, "fallback": false}
{"tick": 1701, "wall_ms": 70875, "type": "vote_cast",
 "target": "blue", "ticks_after_meeting_start": 181,
 "rationale": "chat_sus_color"}
{"tick": 1812, "wall_ms": 75500, "type": "meeting_ended",
 "meeting_index": 1, "duration_ticks": 292}
{"tick": 7180, "wall_ms": 299167, "type": "game_over",
 "title": "IMPS WIN", "result": "imps_win"}
```

### 4.3 `decisions.jsonl` — policy-branch transitions

One line per branch *enter*. The previous branch's duration is
attached to the *new* line as `duration_ticks_in_prev_branch` —
this gives both edges (entry tick implicit; exit tick implicit via
the next line) without doubling line count.

```jsonc
{
  "tick":     4123,
  "wall_ms":  171792,
  "branch_id":                       "policy_crew.task.astar",
  "intent":                          "A* to upload-data path=14 state=Mandatory",
  "thought":                         "crewmate FrameMapLock at camera (340,180), next up",
  "from":                            "policy_crew.task.precise_approach",
  "duration_ticks_in_prev_branch":  47,
  "mask":                            "Up",
  "self": {
    "world_pos":   [342, 188],
    "room":        "admin",
    "camera_lock": "FrameMapLock"
  },
  "goal": {
    "name":      "upload-data",
    "index":     6,
    "world_pos": [488, 320],
    "path_len":  14
  }
}
```

Field notes:

- `branch_id` — see §8 for the canonical naming scheme.
- `intent` — copy of `bot.diag.intent` at the moment the branch
  fired (verbatim, freeform, human-readable).
- `thought` — copy of `bot.diag.lastThought`. May be empty/stale.
- `from` — `branch_id` of the prior branch in this round; `null`
  on the first line after `round_start`.
- `mask` — symbolic mask name (`"Up"`, `"Up+A"`, `"None"`, etc.) or
  the integer if not pretty-printable.
- `self.camera_lock` — `"NoLock"`, `"LocalFrameMapLock"`, or
  `"FrameMapLock"`.
- `goal` — emitted only when `bot.goal.has`. If goal is set without
  a path step, `path_len` is omitted.

`--trace-level:full` switches `decisions.jsonl` to **per-frame**
emission (every `decideNextMask` call writes a line, even if
`branch_id` is unchanged). This is for offline replay-investigation;
it is not the default.

### 4.4 `snapshots.jsonl` — periodic belief state

Emitted every `--trace-snapshot-period` ticks (default 120 ≈ 5s)
**and** on every `meeting_started` event. Captures slow-evolving
belief state that is not derivable from the event stream.

```jsonc
{
  "tick":    3600,
  "wall_ms": 150000,
  "self": {
    "role":           "imposter",
    "is_ghost":       false,
    "color":          "cyan",
    "world_pos":      [488, 320],
    "room":           "electrical",
    "kill_ready":     true,
    "task_hold_ticks": 0,
    "localized":      true,
    "camera_lock":    "FrameMapLock",
    "camera_score":   15240
  },
  "visible": {
    "crewmates": [
      {"color": "blue",  "world_pos": [490, 330]},
      {"color": "green", "world_pos": [520, 300]}
    ],
    "bodies":   [],
    "ghosts":   []
  },
  "evidence_top": [
    {"color": "blue",  "witnessed_kill_age_ticks": null,
                       "near_body_age_ticks":    240},
    {"color": "green", "witnessed_kill_age_ticks": null,
                       "near_body_age_ticks":   null}
  ],
  "task_model_summary": {
    "completed": 3, "mandatory": 2, "maybe": 4,
    "not_doing": 7, "resolved_not_mine": 4
  },
  "imposter_state": {
    "followee_color":     "blue",
    "followee_since_tick": 3480,
    "fake_task_index":     null,
    "central_room_ticks":  0,
    "last_kill_tick":      1455
  },
  "voting":              null,
  "stuck_frames":        0,
  "frames_dropped_total": 5
}
```

`evidence_top` is capped at 5 entries, sorted by recency (most-recent
witnessed kill first; ties broken by near-body recency). Entries with
both ages `null` are excluded.

`imposter_state` is `null` when `role != "imposter"`. `voting` is
non-null only on snapshots emitted at `meeting_started`.

## 5. Disk layout

```
<trace-root>/<bot-name>/<session-id>/<round-id>/
  manifest.json
  events.jsonl
  decisions.jsonl
  snapshots.jsonl
  frames.bin           # optional, --trace-frames-dump (default on)
  frames.bin.gz        # optional, --trace-frames-compress
```

- `<trace-root>` — `--trace-dir` value.
- `<bot-name>` — from `--name`, or `"modulabot"` if unset. This
  segment is always present so multi-bot harnesses don't collide.
- `<session-id>` — ISO8601 UTC + PID, e.g. `2026-04-30T19-14-02Z-12345`
  (colons replaced with hyphens for filesystem safety).
- `<round-id>` — zero-padded round counter, e.g. `0003`. `0000` is
  reserved for "started mid-round" partial games.

A `_session.json` may optionally be written at `<trace-root>/<bot-name>/<session-id>/`
holding session-level metadata (start/end time, number of rounds,
configuration). Deferred to v1.1 unless harness needs it earlier.

## 6. Hook points

### 6.1 Frame-end hook

**Location**: end of `decideNextMask` in `bot.nim:448`, immediately
before `snapshotPrevFrame`.

```nim
# pseudocode
result = mask
if bot.trace != nil:
  bot.trace.traceFrame(bot, mask)
snapshotPrevFrame(bot)
```

`traceFrame` does all diff detection internally:

1. Detect events by diffing `Bot` state against the writer's `prev*`
   shadow fields (see §7.2). Emit `events.jsonl` lines.
2. Detect branch transitions by comparing `bot.diag.branchId` against
   `prevBranchId`. Emit `decisions.jsonl` line on change. (In `full`
   level, emit unconditionally.)
3. If `bot.frameTick - lastSnapshotTick >= snapshotPeriod`, emit a
   `snapshots.jsonl` line.
4. Update shadow state.

### 6.2 Round transition hook

**Location**: `bot.nim:230-…` (`resetRoundState`).

Trace writer detects the game-over edge in its frame hook (by diffing
`percep.lastGameOverText` against its shadow), so no direct call from
`resetRoundState` is required. Sequence at the round transition:

1. The frame containing the game-over interstitial: emit `game_over`
   event in `traceFrame`.
2. After `traceFrame` returns and `decideNextMask` returns mask 0,
   the writer notices `prevGameOverText != ""` and immediately closes
   files, finalises the manifest, then opens a new round directory.
3. Subsequent frames write to the new round.

### 6.3 Chat-observed hook

**Location**: inside `traceFrame` when `bot.percep.interstitial and
bot.voting.active`.

To avoid a second OCR pass, the existing call chain in
`voting.parseVotingCandidate` (`voting.nim:323`) is refactored to
populate a new field `bot.voting.chatLines: seq[string]` alongside
`chatText`. `readVoteChatText` becomes a thin wrapper over a new
`visibleChatLines` iterator that both consumers use.

The trace writer maintains per-meeting state:

```nim
type MeetingChatState = object
  meetingIndex:        int
  seenLinesNormalized: HashSet[string]
  selfQueuedNormalized: string
```

On every voting-screen frame, for each line in `bot.voting.chatLines`:

- Normalise via existing `voting.normalizeChatText`
  (`voting.nim:217-230`).
- If not in `seenLinesNormalized`, add and emit `chat_observed`.
- `matches_self_chat` is true when the normalised line equals
  `selfQueuedNormalized` (set when the bot last queued a chat).

`speaker` was always `null` in v1/v2; Sprint 2.1 (schema v3) populates
it from `voting.detectChatSpeaker` (pip-color detection). Falls back
to null only when detection is below `VoteChatPipMinPixels` confidence
threshold — rare for normal chat, common for blank/black frames.

`ocr_quality` is `"clean"` when the line has no `?` glyphs,
`"noisy"` otherwise.

### 6.4 Session lifecycle hooks

| Site | Action |
|---|---|
| `runner.nim:127` (`var bot = initBot(paths)`) | If trace flags set, attach `bot.trace = openTrace(...)`. |
| `runner.nim:171` (mask send) | No-op for trace; already covered by §6.1. |
| `runner.nim:176` (chat send) | Trace writer mirrors the queued chat into shadow `selfQueuedNormalized` and emits `chat_sent`. |
| Disconnect / outer-loop end | Emit `disconnect` event; do **not** close the round (the same round may continue after reconnect). |
| `quit`/SIGINT (via `addQuitProc`) | Best-effort flush + finalise current round with `ended_reason: "process_exit"`. |

### 6.5 FFI parity

`ffi/lib.nim:81-123` (`modulabot_step_batch`) is a CoGames training
harness entry point. The same `traceFrame` hook works there. Trace
configuration in FFI mode is via a new `modulabot_init_trace(root,
level, period)` exported proc; opt-in only.

## 7. Required code changes (summary)

### 7.1 New module: `players/modulabot/trace.nim`

Owns: file handles, all diff state, JSON serialisation, timestamps,
manifest accumulator, per-meeting chat state.

```nim
type
  TraceLevel*  = enum tlOff, tlEvents, tlDecisions, tlFull
  TraceWriter* = ref object
    rootDir*:        string
    botName*:        string
    sessionId*:      string
    roundId*:        int
    level*:          TraceLevel
    snapshotPeriod*: int
    captureFrames*:  bool
    harnessMeta*:    JsonNode
    # files
    manifestPath:    string
    eventsFile:      File
    decisionsFile:   File
    snapshotsFile:   File
    framesFile:      File
    # round timing
    roundStartedUnixMs: int64
    lastSnapshotTick:   int
    # diff shadows
    prevBranchId:        string
    prevBranchEnterTick: int
    prevLocalized:       bool
    prevCameraLock:      CameraLock
    prevSelfColor:       int
    prevRole:            BotRole
    prevIsGhost:         bool
    prevKillReady:       bool
    prevInterstitial:    bool
    prevGameOverText:    string
    prevTaskStates:      seq[TaskState]
    prevTaskResolved:    seq[bool]
    prevVoteChoices:     PerColor[int]
    prevSelfVoteChoice:  int
    prevStuckFrames:     int
    prevBodies:          seq[BodyMatch]
    # chat
    meetingChat:         MeetingChatState
    meetingsObserved:    int
    # accumulators for manifest
    counters:            ManifestCounters

proc openTrace*(root, botName: string, level: TraceLevel,
                snapshotPeriod: int, captureFrames: bool,
                harnessMeta: JsonNode): TraceWriter
proc beginRound*(t: TraceWriter, bot: var Bot)
proc traceFrame*(t: TraceWriter, bot: var Bot, mask: uint8)
proc endRound*(t: TraceWriter, bot: var Bot, reason: string)
proc closeTrace*(t: TraceWriter)
```

### 7.2 `types.nim` — minimal additions

```nim
# in Diag
type Diag* = object
  intent*:     string
  lastThought*: string
  branchId*:   string    # NEW

# in VotingState
type VotingState* = object
  # ... existing fields ...
  chatLines*: seq[string]   # NEW (cached from visibleChatLines)
```

`Bot` gains a `trace*: TraceWriter` field (nilable; `nil` when
tracing is off).

### 7.3 `diag.nim` — small helper

```nim
proc fired*(bot: var Bot, branchId, intent: string) =
  bot.diag.branchId = branchId
  if bot.diag.intent != intent:
    bot.diag.intent = intent
```

Optionally a two-arg variant that only sets `branchId` when the
intent doesn't change.

### 7.4 Branch-ID annotations

Every site that currently writes `bot.diag.intent = "..."` is
replaced with `bot.fired("<branch_id>", "...")`. The full list (~25
sites) is enumerated in §8.

This is the only invasive change to policy code. It is mechanical,
testable via parity, and reversible.

### 7.5 `voting.nim` — line-level chat capture

Refactor `readVoteChatText` to use a new `visibleChatLines` iterator;
have `parseVotingCandidate` cache `bot.voting.chatLines`. Single OCR
pass; no behaviour change.

### 7.6 `bot.nim` — frame-end hook

Add `if bot.trace != nil: bot.trace.traceFrame(bot, mask)` between
the end of policy dispatch and `snapshotPrevFrame` at line 448.

Round transitions are detected by the writer; no edit to
`resetRoundState` itself.

### 7.7 `runner.nim` — open / close

Open the trace at `runner.nim:127` after `initBot`. On
`bot.chat.pendingChat` flush at line 176, mirror into
`t.meetingChat.selfQueuedNormalized` and emit `chat_sent`.

Register `addQuitProc` to finalise on process exit.

### 7.8 `modulabot.nim` — CLI flags

Add (see §10).

### 7.9 `tuning.nim` (or new `tuning_snapshot.nim`)

```nim
proc tuningSnapshot*(): JsonNode =
  result = %*{
    "TeleportThresholdPx": TeleportThresholdPx,
    "PathLookahead":       PathLookahead,
    # ... canonical, exhaustive list ...
  }
```

This is the *only* place the manifest's `tuning_snapshot` is
constructed. New tunables added later must extend this proc.

### 7.10 `ffi/lib.nim` — opt-in trace init

```nim
proc modulabot_init_trace*(root: cstring, level: cint,
                           snapshotPeriod: cint): cint
  {.cdecl, exportc, dynlib.}
```

Returns 0 on success, non-zero on failure. Idempotent per process.

## 8. Branch ID convention

### 8.1 Naming scheme

`<file_stem>.<category>.<specific>` — dot-separated, lower-snake.
The `<file_stem>` segment makes the source location unambiguous;
`<category>` groups branches that share a high-level intent;
`<specific>` distinguishes tiers within the cascade.

### 8.2 Canonical list

| Branch ID | Source site | Description |
|---|---|---|
| `bot.interstitial.role_reveal` | `bot.nim` interstitial branch | inside CREWMATE/IMPS interstitial |
| `bot.interstitial.game_over` | `bot.nim` interstitial branch | game-over title detected |
| `bot.localizing` | `bot.nim` post-interstitial path | actively running localization |
| `bot.not_localized` | `bot.nim` post-interstitial path | localization failed; mask 0 |
| `policy_crew.body.report_in_range` | `policy_crew.nim` | nearby body, in report range |
| `policy_crew.body.navigate_to_body` | `policy_crew.nim` | nearby body, navigating to it |
| `policy_crew.task.holding` | shared via `tasks.holdTaskAction` (`tasks.nim`) | holding A on real task |
| `policy_crew.task.mandatory_visible` | `policy_crew.nim` | visible mandatory icon |
| `policy_crew.task.mandatory_sticky` | `policy_crew.nim` | sticky mandatory |
| `policy_crew.task.mandatory_nearest` | `policy_crew.nim` | nearest mandatory |
| `policy_crew.task.checkout_sticky` | `policy_crew.nim` | sticky checkout |
| `policy_crew.task.checkout_nearest` | `policy_crew.nim` | nearest checkout |
| `policy_crew.task.radar_sticky` | `policy_crew.nim` | sticky radar |
| `policy_crew.task.radar_nearest` | `policy_crew.nim` | nearest radar |
| `policy_crew.task.home_fallback` | `policy_crew.nim` | home/button fallback |
| `policy_crew.task.precise_approach` | `policy_crew.nim` | within precise radius |
| `policy_crew.task.astar` | `policy_crew.nim` | A* navigation step |
| `policy_crew.task.continue_hold` | `policy_crew.nim` | continuing A-hold on a task |
| `policy_crew.task.ghost_nav` | `policy_crew.nim` | ghost navigation |
| `policy_crew.idle.no_goal` | `policy_crew.nim` | no goal selectable |
| `policy_imp.body.self_report` | `policy_imp.nim` | self-report own kill |
| `policy_imp.body.flee` | `policy_imp.nim` | flee from someone else's discovery |
| `policy_imp.kill.in_range` | `policy_imp.nim` | press A on kill |
| `policy_imp.kill.hunt` | `policy_imp.nim` | hunt lone crewmate (out of range) |
| `policy_imp.fake_task.holding` | `policy_imp.nim` | holding A on fake station |
| `policy_imp.fake_task.setup` | `policy_imp.nim` | starting a fake-task hold |
| `policy_imp.fake_task.setup_in_tail` | `policy_imp.nim` | fake-task hold during tail |
| `policy_imp.fake_task.setup_in_wander` | `policy_imp.nim` | fake-task hold during wander |
| `policy_imp.central_room.force_leave` | `policy_imp.nim` | forced exit from central room |
| `policy_imp.follow.tail` | `policy_imp.nim` | tailing followee |
| `policy_imp.wander.next_target` | `policy_imp.nim` | wandering to next fake target |
| `policy_imp.wander.idle_unreachable` | `policy_imp.nim` | idle, unreachable target |
| `policy_imp.wander.idle_no_target` | `policy_imp.nim` | idle, no target |
| `voting.idle.already_voted` | `voting.nim` | already voted; idle |
| `voting.cursor.move` | `voting.nim` | cursor moving toward target |
| `voting.cursor.listen` | `voting.nim` | cursor on target, listening for chat |
| `voting.press_a` | `voting.nim` | pressing A to vote |

`BRANCH_IDS.md` is the auto-generated source-of-truth — it carries
exact line numbers and is regenerated by
`nim r tools/gen_branch_ids.nim`. The table above is a stable
reference; line numbers are deliberately omitted to avoid stale-link
churn from unrelated edits.

### 8.3 Documentation generation

A pre-commit hook or manual `tools/gen_branch_ids.py` script greps
the source for `bot.fired(` calls and produces
`players/modulabot/BRANCH_IDS.md` mapping each ID to its `file:line`.
This catches drift when a developer adds or renames a branch.

### 8.4 Stability invariant

Every code path through `decideNextMask` *must* call `bot.fired(...)`
exactly once before returning. The trace writer warns once per round
if it observes an empty `branchId`. CI parity test (§13) fails if
warnings fire.

## 9. Determinism & replay

The bot is already replayable: `initBot(masterSeed) + frames-dump
→ identical mask sequence`, exercised by `test/parity.nim`. The trace
preserves this property and exploits it.

### 9.1 Non-perturbation invariants

- The trace writer reads `Bot` state only after `decideNextMask`
  returns; it never mutates `Bot`.
- `bot.fired(...)` writes to `bot.diag.branchId` and `bot.diag.intent`.
  Neither field is read by any policy code today; the parity test
  must be extended to confirm this remains true.
- The trace writer makes no RNG calls. If it ever needs randomness
  (e.g. sampling), it must use a private `Rand` seeded outside
  `bot.rngs`.
- The trace writer makes no calls to OCR or perception that aren't
  already cached on `Bot`.
- I/O cost is non-zero but bounded; see §11.

### 9.2 Re-tracing from frames dump

Every manifest carries `master_seed` and (when frames capture is on)
`frames_dump_path`. To re-investigate:

1. Read `manifest.json` → extract `master_seed` and `frames_dump_path`.
2. Run `nim r test/parity.nim --replay:<frames> --seed:<seed>
   --trace-dir:<path> --trace-level:full`.
3. The bot replays bit-exact; a per-frame trace is produced.

### 9.3 Caveats

- `wall_ms` reflects **the time at which the trace was emitted**, not
  the original game time. A replayed trace will have different
  `wall_ms` values. This is documented in §14 (risks).
- The harness can derive original wall times from the original
  manifest's `started_unix_ms` plus the per-frame tick if needed; the
  bot's `frameTick` is reliably reproducible.

## 10. Configuration surface

### 10.1 CLI flags (added to `modulabot.nim:22-54`)

| Flag | Default | Description |
|---|---|---|
| `--trace-dir:<path>` | unset (off) | Root directory for trace output. Setting this enables tracing. |
| `--trace-level:events\|decisions\|full` | `decisions` | Verbosity. `events` skips per-decision logging; `decisions` is the recommended default; `full` emits per-frame decisions. |
| `--trace-snapshot-period:<n>` | `120` | Ticks between belief-state snapshots. |
| `--trace-frames-dump` / `--no-trace-frames-dump` | on (when trace-dir set) | Capture raw frames alongside the trace for offline replay. Disambiguated from existing `--frames`. |
| `--trace-frames-compress` | off | gzip the frames dump on close. |
| `--trace-meta:k=v,k=v,...` | empty | Free-form metadata into `manifest.harness_meta`. |

### 10.2 Environment variables

| Env var | Equivalent flag |
|---|---|
| `MODULABOT_TRACE_DIR` | `--trace-dir` |
| `MODULABOT_TRACE_LEVEL` | `--trace-level` |
| `MODULABOT_TRACE_SNAPSHOT_PERIOD` | `--trace-snapshot-period` |
| `MODULABOT_TRACE_FRAMES_DUMP` | `--trace-frames-dump` |
| `MODULABOT_TRACE_FRAMES_COMPRESS` | `--trace-frames-compress` |
| `MODULABOT_TRACE_META` | `--trace-meta` |

Resolution order: explicit flag > env var > default. Env vars exist
for harness convenience (one `export` for many child processes).

### 10.3 Tuning snapshot extraction

Defined once, in `tuning_snapshot.nim` (new file):

```nim
import json
import tuning, voting, motion, evidence, policy_imp, policy_crew, tasks, actors

proc tuningSnapshot*(): JsonNode =
  %*{
    # tuning.nim
    "TeleportThresholdPx":              TeleportThresholdPx,
    # voting.nim
    "VoteListenTicks":                  VoteListenTicks,
    "VoteChatChars":                    VoteChatChars,
    # motion.nim
    "StuckFrameThreshold":              StuckFrameThreshold,
    "JiggleDuration":                   JiggleDuration,
    # evidence.nim
    "WitnessNearBodyRadius":            WitnessNearBodyRadius,
    # policy_imp.nim
    "ImposterFollowSwapMinTicks":       ImposterFollowSwapMinTicks,
    "ImposterCentralRoomStuckTicks":    ImposterCentralRoomStuckTicks,
    "ImposterSelfReportRadius":         ImposterSelfReportRadius,
    "ImposterSelfReportRecentTicks":    ImposterSelfReportRecentTicks,
    # tasks.nim
    "TaskPreciseApproachRadius":        TaskPreciseApproachRadius,
    "TaskIconMissThreshold":            TaskIconMissThreshold,
    # actors.nim
    "GhostIconFrameThreshold":          GhostIconFrameThreshold,
    # path.nim
    "PathLookahead":                    PathLookahead
  }
```

Exhaustiveness is enforced by code review and by a CI grep that
warns if a `const` declaration is added under any policy module
without a corresponding key here.

## 11. Performance budget

Frame budget is ~42 ms at 24 fps. Trace overhead must stay well under
10% of budget (4 ms) and ideally under 1 ms typical.

- **JSON serialisation**: Nim's `std/json` is allocating but fast
  enough at this volume. Snapshot lines (~600 B) serialise in <0.5 ms;
  decision lines (<400 B) faster. Acceptable.
- **File I/O**: `writeLine` + `flushFile` per emission. SSD write
  latency is typically <1 ms for small writes. The OS page cache
  absorbs bursts.
- **Diff cost**: O(N_tasks + N_colors + N_visible) per frame; small
  constants. Negligible.
- **Frames dump**: 16384 B per tick written sequentially; OS write
  cache absorbs. Negligible CPU.

If profiling reveals hot spots, options in order of preference:

1. Buffer events in memory and flush at meeting boundaries (loses
   only the last few events on crash).
2. Move serialisation to a worker thread with a bounded channel
   (introduces concurrency complexity).
3. Switch to a more compact format (msgpack, protobuf) — last resort,
   harms LLM-friendliness.

Decision: ship synchronous flush; revisit only if measured frame
times degrade.

## 12. Error handling & lifecycle

### 12.1 Trace writer exceptions

Every public `traceX` call wraps its body in `try/except: discard`
with a single one-shot stderr warning per session. The bot must
*never* crash because of trace I/O.

### 12.2 Disk full / permission errors

Detected at `openTrace` (creating directories) — log to stderr,
disable tracing for the session, continue running.

Detected mid-game — same: stderr warning, set
`bot.trace = nil`, continue.

### 12.3 Disconnect / reconnect

The runner's outer reconnect loop persists `bot` across
reconnections. The trace persists too; rounds are *not* closed on
disconnect. A `disconnect` event is emitted, then a `reconnect`
event when WS reopens. If the disconnect was actually game-over and
the server dropped us, the next `resetRoundState` will close the
round normally.

### 12.4 Process exit

`addQuitProc(proc () = closeTraceIfOpen())` ensures graceful
finalisation on `quit`/SIGINT. SIGKILL truncates; the manifest's
`ended_reason` will be missing on the last round in that case. The
harness must tolerate truncated last rounds.

### 12.5 Mid-round connect

If `initBot` happens after a game has already started (no `round_start`
edge has fired), the writer opens round `0000` with
`started_mid_round: true` and `ended_reason: "started_mid_round_unknown"`
until either a normal `game_over` or a session end. Subsequent rounds
start at `0001`.

## 13. Testing plan

### 13.1 Determinism (parity)

`test/parity.nim` extended with `--trace-dir:/tmp/parity-trace`. Runs
two bots through identical frames + seeds and confirms:

1. Mask sequences identical (already tested).
2. `decisions.jsonl` line count and `branch_id` sequence identical.
3. `events.jsonl` event types and ordering identical (timestamps
   excluded from comparison).

A diff-mode flag prints the first divergence with surrounding
context.

### 13.2 Trace-on vs. trace-off equivalence

Same parity harness compares `trace-off` and `trace-on` runs. Mask
sequences must be identical. This is the strongest guarantee that
the trace writer is non-perturbing.

### 13.3 Schema validation

A small Python tool (or `nim r tools/validate_trace.nim`) reads a
generated trace and validates:

- Manifest has all required fields, valid types.
- Every event line has `tick`, `wall_ms`, `type`.
- `tick` monotonically non-decreasing across events / decisions /
  snapshots.
- Every `meeting_started` is followed eventually by `meeting_ended`
  in the same round.
- Every `vote_cast` has a corresponding `meeting_started` open at
  that tick.
- Every emitted `branch_id` exists in the canonical list (§8.2).

CI runs this against a golden trace produced by replaying a recorded
frames dump.

### 13.4 Smoke run

A `make trace-smoke` target runs a single 60-second game with
`--trace-level:decisions` against a local server, then validates the
output. Used as the human-readable check during development.

## 14. Risks & open issues

These were identified during the final design pass. Each has an
explicit decision or mitigation; nothing here is unresolved enough to
block implementation.

### 14.1 `bot.frameTick` accumulates across reconnects

`var bot = initBot(paths)` lives outside the reconnect loop in
`runner.nim:127`. So `frameTick` does not reset on reconnect within a
session. **Decision**: trace `wall_ms` is round-relative, computed as
`nowMs - roundStartedUnixMs`. `tick` remains the bot's internal
`frameTick` (session-monotonic). Document that `tick` values are
*not* round-relative; the harness should normalise via
`tick - round_start_tick` if needed.

### 14.2 Game-over text edge missed under noise

If the OCR misreads `CREW WINS`/`IMPS WIN` for a frame, the edge
detection could double-fire. **Mitigation**: edge condition is
`prevGameOverText == "" and currentGameOverText != ""`. Once fired,
`prevGameOverText` is set to the new text; flickers between two
recognised titles within the same interstitial cannot re-trigger.

### 14.3 Branch-ID drift

A developer adds a branch but forgets to assign a `branchId`.
**Mitigations**: (a) the trace writer emits a one-shot warning and
records `branch_id: ""` so the harness sees it; (b) the parity test
fails on warnings; (c) the `gen_branch_ids.py` doc-generation script
is part of CI.

### 14.4 Replay `wall_ms` differs from original

A re-run from a frames dump produces a fresh trace with
trace-emission `wall_ms`, not the original game's. **Decision**: this
is intentional. The original trace's manifest carries
`started_unix_ms`; re-runs are for *behavioural* inspection, not
historical reconstruction.

### 14.5 Snapshot at meeting boundary collides with periodic snapshot

If `frameTick` mod `snapshotPeriod == 0` coincides with a
`meeting_started`, two snapshots fire in the same tick. **Decision**:
allow it. Both lines are valid; the harness can dedupe by `tick` if
desired. Specify ordering: events first, then decisions, then
snapshots, deterministically.

### 14.6 Frames dump volume

~117 MB/game uncompressed, ~5–10 MB gzipped. A 50-game outer-loop
run is ~6 GB / 250 MB. **Decision**: keep frames dumps for the last
K games (configurable, default `K = 10`); the harness can flag
specific games for retention via a sentinel file
`<round-dir>/RETAIN`.

This rotation is implemented as a v1.1 cron-style sweep, not in the
hot path. v1 ships without rotation; document the disk-cost
expectation.

### 14.7 OCR'd chat lines now carry speaker attribution (Sprint 2.1)

Originally documented as a v1 limitation. Resolved: schema v3
emits real `speaker` color names from
`voting.detectChatSpeaker`. Falls back to `null` only when the
pip detector confidence is below `VoteChatPipMinPixels` (rare in
practice — multi-line messages always self-attribute because the
sim renders one sprite per message and each text row of the
message overlaps the sprite vertically).

### 14.8 The `decideNextMask` early-return paths

Some branches (`bot.nim:357-389`, `bot.nim:432-435`) return early
without traversing the full pipeline. Each must call `bot.fired(...)`
before returning. Listed as `bot.interstitial.*` and
`bot.not_localized` in §8.2.

### 14.9 `selfColor` reset semantics

`identity.selfColor` is set once and not cleared by `resetRoundState`
(verify during implementation; if false, document and adjust). The
trace emits `self_color_known` only on the first non-(-1) write per
session. If the value can change mid-session, add a
`self_color_changed` event in v1.1.

### 14.10 OS path-segment compatibility

Session ID uses ISO8601 with `T`, `-`, and `Z`. Avoid `:` (colon)
which is invalid on Windows. Spec: replace `:` with `-` in the
serialised session ID.

### 14.11 Trace writer is single-threaded

Confirmed: `decideNextMask`, `runner` frame intake, and trace I/O are
all on the main thread. No locks needed. If a future async I/O
optimisation is added, this assumption changes.

### 14.12 Volume estimates depend on policy churn

The 100–2000 lines/game estimate for `decisions.jsonl` is a guess.
The actual volume scales with how often the policy switches branches,
which is itself a function of stuck-frames, kill-cooldown timing, and
chat dynamics. Worst-case (rapid oscillation between two branches) is
~7200 lines/game = ~3 MB. **Mitigation**: post-implementation, gather
real distributions; if extreme, add a "min ticks in branch" debounce
before emitting (configurable; default 1).

## 15. v2 / future work

- **Chat speaker attribution — SHIPPED in Sprint 2.1.**
  `voting.detectChatSpeaker` samples pixels in
  `[VoteChatPipX0..VoteChatPipX1, textY..textY+TextLineHeight]`
  for `PlayerColors` palette matches and returns the dominant
  color index. Manifest `trace_settings.speaker_attribution` is
  now `"color_pip"`; `chat_observed.speaker` is populated.
- **Cross-game lineage in a session.** Optional `_session.json`
  with rolled-up counters and a list of round IDs.
- **Frames-dump rotation.** Cron-style sweeper that compresses and
  optionally deletes old frames dumps based on retention policy.
- **Streaming trace.** A thin proxy that tails JSONL and exposes it
  as a WebSocket stream for real-time harness dashboards.
- **Counterfactual annotations.** Per-decision logging of *rejected*
  alternatives — what tier-2 task was considered before tier-1 fired?
  Requires policy-code changes; deferred.
- **LLM-targeted summary.** End-of-game `summary.md` generated from
  the trace, hand-tuned for context-window economy. Could be done
  outside the bot in the harness.

## 16. Implementation phases

### Phase 1 — minimal viable trace

1. `types.nim` adds `Diag.branchId` and `VotingState.chatLines`.
2. `diag.nim` adds `bot.fired(branchId, intent)`.
3. New module `trace.nim` with manifest + events + decisions
   (no snapshots yet).
4. Hooks: `bot.nim` frame-end, `runner.nim` open/close,
   `bot.nim` round transition (via game-over diff).
5. Minimal CLI flags: `--trace-dir`, `--trace-level`, `--trace-meta`.
6. Annotate ~25 branch sites with `bot.fired(...)`.
7. Parity test confirms zero divergence with trace on vs. off.

Deliverable: a single game produces a manifest + events + decisions
trio that an LLM can read.

### Phase 2 — snapshots & chat

8. Add `snapshots.jsonl` and the periodic emitter.
9. Refactor `voting.nim` to expose `visibleChatLines`; cache
   `bot.voting.chatLines`.
10. Add `chat_observed` event.
11. Add `--trace-snapshot-period`.

Deliverable: full v1 trace.

### Phase 3 — replay & frames

12. `--trace-frames-dump` (default on); reuse existing `--frames`
    plumbing via `runner.nim:107-114`.
13. Extend `test/parity.nim` with `--trace-dir` and trace-comparison
    mode.
14. `tools/validate_trace.{py,nim}` schema validator.

Deliverable: a recorded game can be replayed end-to-end at
`--trace-level:full` to produce an exhaustive offline trace.

### Phase 4 — FFI & tooling

15. `modulabot_init_trace` exported from `ffi/lib.nim`.
16. `gen_branch_ids.py` + `BRANCH_IDS.md` generation.
17. `make trace-smoke` target.

Deliverable: harness-ready, documented, CI-validated tracing.

### Phase 5 — LLM observability + capture (Sprint 1, 2.1, 5.1)

Layered on top of Phases 1-4 by the mod_talks LLM sprint sequence.
Schema bumped to v3; all v3 additions are backward-compatible.

18. **Sprint 1.** New event types `llm_dispatched` /
    `llm_decision` / `llm_error` / `llm_layer_active` emitted from
    `llm.nim` via the `emitLlm*` procs in `trace.nim`. Manifest
    gains `trace_settings.llm_compiled_in` (set from
    `-d:modTalksLlm` at `openTrace`) and `.llm_layer_active`
    (flipped by `setLlmLayerActive` when the FFI ack fires). New
    `summary_counters.llm` block snapshots process-lifetime LLM
    counters. `MODULABOT_TRACE_DIR` plumbed through the FFI path
    via `cogames/amongthem_policy.py:_arm_trace_if_requested`.
19. **Sprint 2.1.** `chat_observed` events carry real
    `speaker` (color name) from `voting.detectChatSpeaker`.
    `trace_settings.speaker_attribution` flipped from `"none"`
    to `"color_pip"`.
20. **Sprint 5.1.** Optional context-capture pipeline:
    `MODTALKS_LLM_CAPTURE=1` writes dispatched contexts to
    `<round>/llm_contexts/ctx_<seq>_<kind>_t<tick>.json` for
    offline replay through `tools/llm_prompt_eval.py`. Off by
    default; production traces stay light.

Deliverable: every LLM dispatch and decision is observable in
the trace; the same captured contexts can be replayed against
candidate prompts to score response quality.

---

## Appendix A — Estimated volume per 5-min game

Schema-v1 baseline (LLM layer disabled or unused):

| Stream | Lines | Bytes/line | Total |
|---|---|---|---|
| `manifest.json` | 1 | ~3 KB | 3 KB |
| `events.jsonl` | 100–300 | ~250 B | 25–75 KB |
| `decisions.jsonl` | 500–1500 | ~400 B | 200–600 KB |
| `snapshots.jsonl` | 60 | ~600 B | 36 KB |
| **Trace total (typical)** | | | **~150–400 KB** |
| `frames.bin` (optional) | n/a | 16 KB/tick | ~115 MB |
| `frames.bin.gz` | n/a | n/a | ~5–10 MB |

Fifty games of trace data fit in ~10–20 MB. Fifty games with frames
dumps fit in ~250 MB compressed. Both are manageable for a
self-improvement loop.

### Schema-v3 additions (with LLM layer active)

When `-d:modTalksLlm` is on AND a provider responds during the run,
the trace gains LLM events on top of the v1 baseline:

| Stream addition | Per game (typical) | Bytes/line | Total |
|---|---|---|---|
| `llm_dispatched` events | 1–10 | ~100 B | 0.1–1 KB |
| `llm_decision` events | 1–10 | ~300 B | 0.3–3 KB |
| `llm_error` events | 0–3 | ~250 B | 0–0.8 KB |
| `llm_layer_active` event | 1 | ~80 B | 80 B |
| `llm_contexts/` (Sprint 5.1, opt-in) | 1–10 | 1–8 KB | 1–80 KB |
| Manifest LLM blocks | — | — | adds ~0.5 KB to manifest.json |

In practice the LLM-layer overhead is dominated by the optional
context-capture (`MODTALKS_LLM_CAPTURE=1`); decision/error events
themselves are negligible compared to `decisions.jsonl`.

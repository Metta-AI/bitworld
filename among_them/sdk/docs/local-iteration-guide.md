# Among Them SDK — Local Iteration & Testing Guide

Last updated: May 6, 2026

## 1. What this guide covers

The dev loop: edit your SDK module or directives, run a real 8-player Among
Them game on your laptop against `nottoodumb` opponents, read the output,
debug, repeat. Pair it with [`README.md`](../README.md) (pitch + 5-line
hello), [`docs/python-guide.md`](python-guide.md) (API reference), and
[`docs/tournament-submission.md`](tournament-submission.md) (cogames
upload path).

## 2. The standing local-game setup

Every local game in this guide is **1 SDK-controlled player + 7
`nottoodumb` opponents**, hard-wired in
[`among_them/sdk/examples/eight_player_game.py`](../examples/eight_player_game.py)
(see the loop `for i in range(1, 8): ... nottoodumb` and the headline
config `minPlayers=8`). `nottoodumb` is the right default opponent because
it's a real Nim policy bot with the same shape as tournament opponents
— its image is published as `ghcr.io/treeform/bitworld-nottoodumb:latest`
([`coplayer_manifest.json`](../../players/nottoodumb/coplayer_manifest.json))
and it's part of the cogames among-them pool. So the same opponent you
beat (or lose to) locally is what you'll see on the leaderboard.

The example does not currently take an `--opponent` flag — there's
nothing to override, the default *is* nottoodumb. Don't go looking for
one.

## 3. One-time prerequisites

Verify each step before continuing.

**Python 3.11+ and uv.**

```bash
python3 --version    # >= 3.11
uv --version         # any recent
```

**Nim toolchain.** The build helpers install Nim 2.2.4 via
[`nimby`](https://github.com/treeform/nimby) on first run. To pre-install:

```bash
uv run --project /Users/aaln/experiments/softmax/bitworld/among_them/sdk \
    python /Users/aaln/experiments/softmax/bitworld/among_them/players/build_evidencebot_v2.py
nim --version       # should print 2.2.4
```

That one command does three things: installs Nim 2.2.4 if missing,
syncs `nimby.lock` Nim deps, and produces
`among_them/players/libevidencebot_v2.dylib` (the FFI .dylib the SDK's
default policy loads). The matching `.abi` stamp lives next to it.

**Build the `nottoodumb` binary.** There is **no** dedicated
`build_nottoodumb*.py` helper — the deleted one was replaced with an
in-place `nim c` invocation that
[`eight_player_game.py:ensure_native_binary`](../examples/eight_player_game.py)
runs for you on first launch. The compile flags it uses are exactly:

```bash
cd /Users/aaln/experiments/softmax/bitworld
nim c -d:release -d:ssl -d:botHeadless \
    among_them/players/nottoodumb/nottoodumb.nim
```

The repo's [`config.nims`](../../../config.nims) sets `--outdir:./out` and
`--nimcache:./nimcache`, so the binary lands at
`bitworld/out/nottoodumb`. The same call also handles
`among_them/among_them.nim` → `bitworld/out/among_them` (the local game
server). If `nim c` fails with "package X not found", run the
`build_evidencebot_v2.py` step above first — it owns the `nimby sync`.

**First-time SDK install.**

```bash
unset VIRTUAL_ENV
cd /Users/aaln/experiments/softmax/bitworld/among_them/sdk
uv sync
```

`unset VIRTUAL_ENV` is mandatory if your shell has any other venv
active — `uv` will silently install into the wrong project otherwise.

**Verify with the test suite.**

```bash
uv run --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk \
    pytest -q
```

Recent runs are 25 passed + 1 skipped (the `SDKPolicy` constructor test
skips when `mettagrid` isn't installed locally — see
[`tests/test_cogames_packaging.py`](../tests/test_cogames_packaging.py)).

## 4. The 60-second dev loop

The cycle:

1. Edit a module file — your custom `Voter` class, an entry in
   [`examples/personas.py`](../examples/personas.py), or your own copy of
   `eight_player_game.py`.
2. Run `uv run python examples/eight_player_game.py` (with whatever
   `--instructions` / `--module` flags you're tuning).
3. Read the printed final block: scores, override-engine stats,
   resolved `Directives`.
4. Tweak. Re-run. Repeat.

One concrete cycle:

```bash
cd /Users/aaln/experiments/softmax/bitworld/among_them/sdk
uv run python examples/eight_player_game.py \
    --instructions "Be aggressive about reporting bodies."
# Look at the final RESULT block:
#   overrides:  reports_passed=12 reports_suppressed=0
# Now suppress the same with the opposite directive:
uv run python examples/eight_player_game.py \
    --instructions "Never report bodies."
# Expected:
#   overrides:  reports_passed=0  reports_suppressed=12
```

If those two stat lines look identical you've got a bug — the
`_DirectiveOverrideEngine` should swing on `report_eagerness`. Confirm
the parse in isolation with the directive-debug recipe in §7.

## 5. Running an 8-player local game

Canonical command:

```bash
unset VIRTUAL_ENV
cd /Users/aaln/experiments/softmax/bitworld/among_them/sdk
uv run python examples/eight_player_game.py
```

Flags actually exposed by [`parse_args` in
`eight_player_game.py`](../examples/eight_player_game.py):

| Flag | Meaning |
| --- | --- |
| `--instructions "<text>"` | Natural-language directives. Deterministic regex parse unless `--use-llm`. |
| `--cognitive key=value` | Repeatable. Same shape as `Agent.create(cognitive={...})`. |
| `--module slot=type[:k=v,...]` | Repeatable. e.g. `--module voter=scripted:threshold=0.7`. |
| `--bundle-config <path>` | Path to a hand-written `among_them_sdk_config.json`. Wins over the three above. |
| `--rounds-max N` | Number of full games (server `maxGames`). Default 1. |
| `--seed N` | RNG seed for the SDK agent. Default 42. |
| `--server-port N` | Bind the server here. `0` = pick a free port. Default 0. |
| `--imposter-count N` | Default 2. |
| `--tasks-per-player N` | Default 6. |
| `--vote-timer-ticks N` | Voting duration in ticks @ 24fps. Default 360 = 15s. |
| `--max-ticks N` | SDK disconnects after this many frames. Default 8000 (~5.5 min). |
| `--game-timeout N` | Wall-clock seconds before the harness gives up. Default 600. |
| `--use-llm` | Allow the SDK to LLM-parse `--instructions`. Default off. |
| `--log-root <path>` | Where per-process `.log` files go. Default `<repo>/logs/eight_player_game`. |

Three worked invocations:

(a) Default — bare command, ships SDK defaults:

```bash
uv run python examples/eight_player_game.py
```

(b) With instructions:

```bash
uv run python examples/eight_player_game.py \
    --instructions "Be aggressive about reporting bodies"
```

(c) With a bundled persona config. There's no `--persona NAME` flag.
The packager-friendly path is to package the persona into a JSON config
first, then load it with `--bundle-config`:

```bash
cd /Users/aaln/experiments/softmax/bitworld/among_them/sdk
uv run python -m among_them_sdk.package \
    --from-agent examples/personas.py:_build_paranoid \
    --policy-name dev-paranoid \
    --out /tmp/paranoid_config.json
uv run python examples/eight_player_game.py \
    --bundle-config /tmp/paranoid_config.json
```

The packager prints `[package] resolved directives:` plus the JSON it
wrote — that's the same shape `--bundle-config` consumes. See
[`docs/tournament-submission.md`](tournament-submission.md) for the full
packaging path.

## 6. What you'll see

A successful run prints, in order:

1. **Build banner** — `[build] evidencebot_v2 lib OK: …`,
   `[build] among_them -> …/out/among_them`,
   `[build] nottoodumb -> …/out/nottoodumb` (or just an OK line if cached).
2. **Setup line** —
   `[setup] logs -> /Users/.../logs/eight_player_game/<timestamp>`.
3. **Server boot** —
   `[server] launching on 127.0.0.1:<port> (config={'minPlayers': 8, ...})`
   then `[server] OK — listening on 127.0.0.1:<port> (PID <pid>)`.
4. **Seven nottoodumb connections** —
   `[player 1/7] nottoodumb1 (PID <pid>) -> ws://127.0.0.1:<port>` … 7×.
5. **SDK policy load** —
   `[sdk]    policy=LocalSDKPolicy (directives=susp=…, report=…, chat=…, vote=…, modules=…)`
   then `[sdk]    connecting -> ws://127.0.0.1:<port>/player?name=sdkbot`.
6. **Per-30s status pings** —
   `[status] server up; bots alive=7/7; sdk frames so far=<n>`.
7. **Final RESULT block** — a `player / role / kills / tasks / reward /
   win` table from `scores.json`, then an `SDK agent` section with
   `summary`, pretty-printed `directives`, the override-engine line
   (`overrides: reports_passed=… reports_suppressed=…`), and frame /
   mask / top-action counts. Final three lines point at the
   `logs:`, `scores:`, and `replay:` paths.

The `overrides` line is the headline metric: it tells you whether your
`Reporter` / `Voter` / `Chatter` overrides actually fired (see
[`policy/cogames.py:_OverrideStats`](../src/among_them_sdk/policy/cogames.py)).

Per-process logs live in the printed `logs:` directory:

* `server.log` — the local Among Them server's stdout/stderr.
* `player_1_nottoodumb1.log` … `player_7_nottoodumb7.log`.
* `sdk.log` — your SDK player's pre-amble (instructions, resolved
  directives, bundle config) plus a `# done:` or `# error:` trailer.
* `scores.json` — `names`, `scores`, `win`, `tasks`, `kills` per slot
  (the same JSON `fetch_results_json` reads).
* `replay.bitreplay` — full replay; open via the `replay_viewer` Nim
  binary if you build it.

## 7. Iterating faster

**K parallel games.**
[`win_rate_loop.py`](../examples/win_rate_loop.py) and
[`ab_test_instructions.py`](../examples/ab_test_instructions.py) both
run against **`LocalSim`** — synthetic frame driver, no real game, no
win/loss signal. Useful for sanity-checking directive parsing, **not**
for "did we win". For real win-rate, wrap `eight_player_game.py`:

```bash
for i in 1 2 3 4 5; do
  uv run python examples/eight_player_game.py \
      --instructions "$VARIANT" --seed $((100+i)) \
      --log-root /tmp/loop > /tmp/loop/$i.out
done
# aggregate from each /tmp/loop/<timestamp>/scores.json
```

For real-game A/B, run the loop twice with different `--instructions`
and diff the per-game `scores.json` files.

**Quick directive sanity-check (no game).**

```bash
uv run python examples/debug_directives.py "be paranoid"
```

This calls the same `parse_instructions` the agent uses and prints the
resolved Directives JSON. Use it before every game to confirm your
phrasing actually hit the regex/LLM rules you expected.

## 8. Writing your own module against nottoodumb

A custom `Voter` (the same shape applies to `Reporter` and `Chatter`):

```python
from among_them_sdk import Vote, Voter, VotingContext

class GrudgeVoter(Voter):
    def vote(self, ctx: VotingContext) -> Vote:
        if not ctx.suspects:
            return Vote.skip("no suspects")
        top = max(ctx.suspects, key=lambda s: s.score)
        if top.score < 0.4:
            return Vote.skip(f"low conf {top.score:.2f}")
        return Vote(target=top.player_id, reason=f"grudge {top.score:.2f}")
```

For the **LiveGame** path (full `Agent` shape, fires on synthesized
meetings), wire it the same way `examples/custom_voter.py` does:

```python
from among_them_sdk import Agent, LiveGame
agent = Agent.create(voter=GrudgeVoter(), use_llm_for_instructions=False)
result, transcript = LiveGame(host="127.0.0.1", port=<port>).run_agent(agent)
```

For the **`LocalSDKPolicy`** path (the override engine
`eight_player_game.py` actually runs against nottoodumb), pack the
voter into a `CogamesBundleConfig` and either pass it via
`--bundle-config` or build it inline. Caveat from
[`policy/cogames.py`](../src/among_them_sdk/policy/cogames.py): the Nim
FFI surface is action-indices-out only, so on the cogames code path
**`Voter` and `Chatter` overrides don't fire — only `Reporter` does**
(it gates report-flavoured action indices). They still show up in
`engine.stats.voter_advisories` for inspection but don't change the
game. To actually drive votes locally, use `Agent.create(...).run(
runtime=LiveGame(...))` (the `Agent` path).

To run one game with your custom module against 7 nottoodumb, simplest
path: drop the class into a file your example can import, call it from
a 10-line wrapper that mirrors `eight_player_game.py`'s server +
nottoodumb spawning, and join with `LiveGame.run_agent(agent)`.

## 9. Inspecting + debugging

**Resolved directives.**

```python
print(agent.directives.model_dump_json(indent=2))
# or for SDKPolicy:
print(json.dumps(sdk_policy.directives.model_dump(), indent=2, default=str))
```

The 8-player example dumps these to `sdk.log` automatically.

**`RunResult` shape.** From
[`runtime.py`](../src/among_them_sdk/runtime.py): `ticks`, `actions`,
`meetings`, `votes`, `reports`, `chat_messages`, `summary`, `raw`. For
`LiveGame.run_local_sdk_policy` the per-action `actions` list is empty
(use the transcript histogram); `votes` and `reports` are also empty
because the FFI doesn't surface them — see the architectural note at the
top of `policy/cogames.py`. For `LiveGame.run_agent(agent)` (the
`Agent`-driven path with synthetic meetings) `votes` / `reports` /
`chat_messages` are populated.

**Structured logs.** [`tracing.py`](../src/among_them_sdk/tracing.py)
emits structlog JSONL on stdout. Crank the level:

```python
import logging
logging.getLogger("among_them_sdk").setLevel(logging.DEBUG)
logging.getLogger("among_them_sdk.live_game").setLevel(logging.DEBUG)
```

That second one is the LiveGame frame loop — connect/close, frames
received, mask sends.

**Per-player log tails.**

```bash
tail -f /Users/aaln/experiments/softmax/bitworld/logs/eight_player_game/<ts>/server.log
tail -f /Users/aaln/experiments/softmax/bitworld/logs/eight_player_game/<ts>/sdk.log
```

`sdk.log` carries your `# instructions:`, `# directives:`, and
`# bundle config:` headers up front — useful when an old config sneaks
into a run.

**Validate the bundle config without running a game.**

```bash
uv run python -m among_them_sdk.package \
    --instructions "your tuning string" \
    --cognitive suspicion_threshold=0.7 \
    --out /tmp/dev_config.json
cat /tmp/dev_config.json
```

The packager prints the resolved Directives and writes the bundle JSON
in the same shape `SDKPolicy` will load. If a hand-written config
parses here, it'll parse inside the cogames Docker too.

**Spotting Nim FFI silent out-of-range actions.** The risk in
[`policy/cogames.py`](../src/among_them_sdk/policy/cogames.py) (`Phase 2
gap`): an out-of-range index from the `.dylib` becomes `None` from
`BITWORLD_ACTION_NAMES[idx]` and is silently skipped by
`_DirectiveOverrideEngine.apply_per_tick`. To catch it, watch the
`top actions (idx, count)` line in the final block — every index there
should map to a name in
[`policy/evidencebot_v2.py:BITWORLD_ACTION_NAMES`](../src/among_them_sdk/policy/evidencebot_v2.py).
Anything out of range is the FFI emitting garbage; rebuild the .dylib
(see §12).

**Debugger.** Plain `breakpoint()` inside your `Voter` /
`Reporter` works because `LiveGame` runs on the calling thread (sdk
runner is a Python thread the example spawns; pdb is fine inside it).
Don't break inside a frame handler that holds the FFI handle for
> a few seconds — the websocket is ping-disabled but the server can
still time you out from the game side.

## 10. Testing changes

```bash
cd /Users/aaln/experiments/softmax/bitworld/among_them/sdk
uv run pytest -q                                    # full suite (25 pass + 1 skip)
uv run pytest tests/test_module_override.py -v      # custom Voter / Reporter tests
uv run pytest tests/test_cogames_packaging.py -v    # bundle config + override engine
uv run ruff check src/                              # lint
```

Add a test for your module by following the
[`test_module_override.py`](../tests/test_module_override.py) shape — it
uses `LocalSim`, not `LiveGame`, so it's hermetic and fast:

```python
from among_them_sdk import Agent, LocalSim, Vote, Voter, VotingContext

class StickyVoter(Voter):
    def vote(self, ctx: VotingContext) -> Vote:
        return Vote(target="P00", reason="sticky")

def test_sticky_voter_replaces_default():
    agent = Agent.create(voter=StickyVoter(), use_llm_for_instructions=False)
    result = agent.run(rounds=1, runtime=LocalSim(ticks_per_round=12, meeting_every=4, seed=1))
    assert all(v.target == "P00" for v in result.votes)
```

For real-game smoke tests, point a pytest fixture at
`LiveGame(host="127.0.0.1", port=<port>)` after spawning the server +
nottoodumb the same way the example does. Re-running the cogames
packaging tests catches regressions in your bundle config schema.

## 11. From local to tournament

When the directive + module mix wins (or at least doesn't actively
lose) locally:

```bash
cd /Users/aaln/experiments/softmax/bitworld/among_them/sdk
uv run python -m among_them_sdk.package \
    --instructions "<your tuned string>" \
    --cognitive suspicion_threshold=0.65 \
    --policy-name "$USER-sdk-tuned"
```

Then run the printed `cogames upload --dry-run` line from
[`docs/tournament-submission.md`](tournament-submission.md) §3 to
validate inside Docker. The local nottoodumb you've been beating is
also one of the tournament opponents (its image is in the
among-them pool — see
[`coplayer_manifest.json`](../../players/nottoodumb/coplayer_manifest.json)),
so a stable local edge usually carries — but cogames mixes in other
opponents too, so don't read 1-game wins as a leaderboard guarantee.

## 12. Common iteration pitfalls

* **`uv` synced the wrong project.** Symptom: `ModuleNotFoundError:
  among_them_sdk` after a clean install. Fix: `unset VIRTUAL_ENV`, then
  `uv sync` from `among_them/sdk` *or* pass
  `uv --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk sync`.
  Don't run `uv sync` from the repo root unless you mean to sync the
  repo-root project (which doesn't include the SDK).
* **`OSError: cannot load libevidencebot_v2`.** The .dylib is missing
  or stale. Rebuild:
  `python /Users/aaln/experiments/softmax/bitworld/among_them/players/build_evidencebot_v2.py`.
  Check `among_them/players/libevidencebot_v2.dylib.abi` — it should
  contain `1`.
* **`nottoodumb binary not found`** or the example dies with
  `nim c ... failed`. Either Nim isn't 2.2.4 (run
  `build_evidencebot_v2.py` once, it installs Nim via nimby), or the
  `nimby.lock` deps aren't synced (same fix). Manual rebuild:
  `nim c -d:release -d:ssl -d:botHeadless among_them/players/nottoodumb/nottoodumb.nim`
  from the repo root.
* **Port already in use.** Use `--server-port N` to pin one. Stale
  `among_them` server processes also linger after Ctrl+C in some
  shells — `pkill -f out/among_them` clears them.
* **Nim cache stale after editing `evidencebot_v2.nim`.**
  `config.nims` puts the cache at
  `/Users/aaln/experiments/softmax/bitworld/nimcache/`. Blow it away
  (`rm -rf nimcache/`) and re-run `build_evidencebot_v2.py`.
* **`overrides: reports_passed=0 reports_suppressed=0`.** The Reporter
  override never fired. Either (a) your directive thresholds didn't
  flip the parsed `report_eagerness` — confirm with `debug_directives.py
  "<your text>"`, or (b) the inner Nim bot didn't emit a `report_*`
  action this game (rare; bump `--rounds-max 3`).
* **Used `examples/hello.py` for substantive iteration.** `hello.py`
  uses `LocalSim` — it doesn't run a real game, doesn't connect to
  nottoodumb, and has no win/loss. For substantive iteration always
  use `eight_player_game.py`.

## 13. Cheat sheet

```bash
# 0. one-time, from anywhere
unset VIRTUAL_ENV
python /Users/aaln/experiments/softmax/bitworld/among_them/players/build_evidencebot_v2.py
uv sync --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk

# 1. directive sanity-check (no game)
uv run --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk \
    python examples/debug_directives.py "be aggressive about reporting"

# 2. one real 8-player game (1 SDK + 7 nottoodumb), defaults
uv run --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk \
    python examples/eight_player_game.py

# 3. same with your tuning string
uv run --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk \
    python examples/eight_player_game.py \
        --instructions "Trust nobody. Report bodies aggressively."

# 4. with a bundled persona config
uv run --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk \
    python -m among_them_sdk.package \
        --from-agent examples/personas.py:_build_paranoid \
        --out /tmp/cfg.json --policy-name dev
uv run --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk \
    python examples/eight_player_game.py --bundle-config /tmp/cfg.json

# 5. tail the SDK log mid-game
tail -f /Users/aaln/experiments/softmax/bitworld/logs/eight_player_game/$(ls -t /Users/aaln/experiments/softmax/bitworld/logs/eight_player_game | head -1)/sdk.log

# 6. test
uv run --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk pytest -q

# 7. lint
uv run --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk ruff check src/

# 8. when ready, package for cogames
uv run --directory /Users/aaln/experiments/softmax/bitworld/among_them/sdk \
    python -m among_them_sdk.package \
        --instructions "<your tuned string>" \
        --policy-name "$USER-sdk-tuned"
```

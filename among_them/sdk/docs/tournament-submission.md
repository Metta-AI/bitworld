# Submitting an SDK policy to the Among Them tournament

Last updated: May 6, 2026

This guide is the SDK-flavoured companion to
[`among_them/players/SUBMIT_TO_TOURNAMENT.md`](../../players/SUBMIT_TO_TOURNAMENT.md).
Read that first for the cogames basics; this doc only covers what's
different when you ship an `Agent.create(...)`-style policy through the
SDK instead of editing `evidencebot_v2_policy.py` directly.

## What gets uploaded

Cogames builds your bundle in an Alpine Docker container during
validation. The container:

* Has Nim 2.2.4 + a C toolchain (the build script auto-installs Nim).
* **Has no API keys.** No OpenAI, no Anthropic, no AI Gateway.
* **Has no outbound network.** Anything that hits a remote host fails.
* Imports your policy via the class path you pass to `cogames upload -p`.
* Calls `__init__(policy_env_info, device='cpu')` per game (no kwargs).
* Calls `step_batch(raw_observations, raw_actions)` per tick.

That last point is why `Agent.create(instructions="...")` can't drive
the tournament directly — there's no constructor seam to pass it. The
SDK ships a different entrypoint for the tournament:
`among_them_sdk.policy.cogames.SDKPolicy`.

## How `SDKPolicy` works

`SDKPolicy` is a `MultiAgentPolicy` subclass that **composes**
`EvidenceBotV2NimPolicy` rather than replacing it. Per tick:

1. Pass observations to `EvidenceBotV2NimPolicy.step_batch` — the inner
   Nim policy decides every action exactly as it would in a vanilla
   `evidencebot_v2` submission.
2. Apply SDK directives + module overrides to the resulting action
   indices (see `_DirectiveOverrideEngine` in
   `src/among_them_sdk/policy/cogames.py`).

Step 2 is where SDK semantics show up in the tournament. Concretely:

| SDK feature                  | Lands at upload time? |
|------------------------------|-----------------------|
| Pre-resolved `Directives`    | **Yes** — bundled JSON. |
| `--instructions "..."` (deterministic regex parse) | Yes. |
| `--instructions "..."` (LLM-resolved) | Yes, *if* the LLM ran at packaging time and the resolved Directives shipped in the bundle. The validator never calls an LLM. |
| `cognitive={...}` overrides  | Yes, via the bundle JSON. |
| Custom `Voter` / `Reporter` / `Chatter` Python classes | Yes, **only if** their source ships in the upload bundle. The bundle config's `modules` table resolves to the class instance at construct time. |
| `LLMVoter` / `LLMChatter`    | **No.** No keys, no network. Stays as scripted fallback. |
| `LiveGame` runtime hooks     | **No.** Cogames runs `step_batch`, not `Agent.run`. |
| Per-tick `pre_tick` / `post_tick` hooks | **No.** No Agent in scope. |
| Memory introspection (`agent.memory.suspects`) | **No.** No Agent. |

## Architectural caveat (read before relying on overrides)

The Nim FFI surface is **action-indices-out only**. It does not surface
the bot's internal voting / reporting / chat / kill decisions — only
"what action mask did this tick emit". So the override engine works at
the action-index level: it can suppress a `report_*` action it sees the
inner Nim policy emit, and it can advise a `Voter` decision the bot is
about to take, but it **cannot inject** a vote or report the inner Nim
policy didn't already decide to take. This is the same gap documented
in `src/among_them_sdk/policy/evidencebot_v2.py` and is tracked as a
Phase 2 Nim FFI extension in
[`among_them/players/sdk/DESIGN.md`](../../players/sdk/DESIGN.md) §8.

In practice that means a `Reporter` override is degraded to a *gate*
("don't report things the Nim bot wants to report") and not a *trigger*
("report things the Nim bot wouldn't").

## The full happy path

### 1. Build your policy locally with `Agent.create`

```python
from among_them_sdk import Agent, ScriptedChatter

agent = Agent.create(
    instructions=(
        "Report bodies aggressively when you have direct evidence. "
        "Vote on evidence only — never follow the majority. Trust no one "
        "after meeting 2."
    ),
    cognitive={"suspicion_threshold": 0.65, "report_eagerness": "high"},
    chatter=ScriptedChatter(tone="suspicious"),
)
```

Iterate locally with `LiveGame` (see
[`examples/eight_player_game.py`](../examples/eight_player_game.py)) —
that example runs `LocalSDKPolicy`, which uses the **same override
engine** as `SDKPolicy`, so what you see locally is what the tournament
runs.

### 2. Package the bundle

The `among_them_sdk.package` CLI extracts your already-resolved
`Directives` + module specs from the agent and writes them to a JSON
file next to the cogames policy module:

```bash
cd among_them/sdk

# Option A — package directly from a script that builds an Agent
python -m among_them_sdk.package \
    --from-agent examples/personas.py:_build_aggressive \
    --policy-name "$USER-sdk-aggressive"

# Option B — inline (for hand-written configs)
python -m among_them_sdk.package \
    --instructions "Trust nobody. Report bodies aggressively." \
    --cognitive suspicion_threshold=0.65 \
    --module voter=scripted:threshold=0.65 \
    --module chatter=scripted:tone=suspicious \
    --policy-name "$USER-sdk-paranoid"
```

The packager:

1. Validates the schema of your directives + module specs.
2. Writes `among_them_sdk_config.json` next to
   `src/among_them_sdk/policy/cogames.py` (cogames flattens this into
   the bundle root next to `cogames.py` at upload time).
3. Prints the exact `cogames upload` command with every `-f` flag set.

### 3. Run the printed `cogames upload` command

The full bundle list (from `SUBMIT_TO_TOURNAMENT.md` plus the SDK):

```bash
cogames upload \
  -p class=among_them_sdk.policy.cogames.SDKPolicy \
  -f among_them/players/evidencebot_v2_policy.py \
  -f among_them/players/build_evidencebot_v2.py \
  -f among_them/players/evidencebot_v2.nim \
  -f among_them/players/evidencebot_v2 \
  -f among_them/sim.nim \
  -f common \
  -f src/bitworld \
  -f nimby.lock \
  -f among_them/sdk/src/among_them_sdk \
  -f among_them/sdk/pyproject.toml \
  -n "$USER-sdk-aggressive" \
  --season among-them
```

Add `--dry-run` to validate the bundle in Docker without uploading. Add
`--skip-validation` only if Docker is broken on your machine and you
want to push anyway.

### 4. Confirm the validator finds your config

The validator's stdout shows `SDKPolicy loaded config from <path>`
when the JSON file landed at the right place. If you see
`no among_them_sdk_config.json found near …; using defaults` instead,
double-check that `-f among_them/sdk/src/among_them_sdk` was on the
upload line — that directory contains both `cogames.py` and the
generated `among_them_sdk_config.json`.

## Worked example — `aggressive_imposter` from `personas.py`

```python
# examples/personas.py — already in the repo
from among_them_sdk import Agent, SilentChatter

def _build_aggressive() -> Agent:
    return Agent.create(
        instructions=(
            "Kill aggressively. Never report bodies. Skip votes unless "
            "you must blame someone."
        ),
        cognitive={"kill_eagerness": "high", "report_eagerness": "low"},
        chatter=SilentChatter(),
        use_llm_for_instructions=False,
    )
```

```bash
cd among_them/sdk
python -m among_them_sdk.package \
    --from-agent examples/personas.py:_build_aggressive \
    --policy-name "$USER-sdk-aggressive-imposter"
```

The CLI prints the resolved directives and the upload command. Run the
upload command from the **repo root** (`bitworld/`) so the relative
`-f` paths resolve. The validator runs the bundle, the SDK overrides
suppress every report the Nim bot would have emitted, and your policy
lands on the leaderboard.

## Things to sanity-check first

1. `python -m among_them_sdk.package --from-agent <script>:<attr>` runs
   without errors and writes a `directives` block (not just
   `instructions`). If the bundle ships only `instructions`, the
   validator parses it with the deterministic regex — that's a lossy
   mapping for richer prompts, so always prefer the resolved
   directives.
2. `cogames upload --dry-run` prints `Policy loaded successfully`
   somewhere in its output — that means `SDKPolicy.__init__` ran inside
   Docker without crashing on a missing import.
3. `among_them_sdk_config.json` lives next to `cogames.py` in the
   uploaded bundle. The packager writes it there by default; if you
   moved it, update `--out`.

## What to do when overrides aren't enough

If you need the SDK to *trigger* an action the inner Nim bot wouldn't
have taken (vote a specific player, report a body the bot didn't
notice, send a chat message), you're hitting the FFI surface gap. Three
options:

1. Tune the inner Nim bot's constants (the eagerness directives already
   nudge `ScriptedReporter`'s threshold; that's the lever today).
2. Subclass `EvidenceBotV2NimPolicy` and add a Python pre-tick that
   patches the action stream — but you'll be reasoning about indices
   without the perception state that produced them.
3. Wait on (or contribute to) the Phase 2 FFI extension that surfaces
   the bot's internal decisions to Python overrides. Tracked in
   `among_them/players/sdk/DESIGN.md` §8.

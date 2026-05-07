# among-them-sdk

A Python SDK for authoring [Among Them](../README.md) policy bots. Wraps the
production scripted policy (`evidencebot_v2`) via FFI and exposes
module-level overrides plus a natural-language **instructions** API.

> **Status:** Phase 0 + Phase 1 of the
> [DESIGN.md spec](../players/sdk/DESIGN.md). Pure-Python fallback,
> `RemoteServer` runtime, skill loaders, and Langfuse integration are
> intentionally out of scope for this milestone.

## Install

```bash
cd among_them/sdk
uv sync          # creates a .venv and installs the package + dev deps
# OR:
pip install -e ".[test]"
```

### FFI requirement (no pure-Python fallback)

The default policy is the Nim-built `evidencebot_v2` shared library. The SDK
will auto-build it the first time it loads, but you must have:

* **Nim 2.2.4** on `PATH` (`nim --version`). The build script can install
  it via `nimby` if it's missing — see
  [`build_evidencebot_v2.py`](../players/build_evidencebot_v2.py).
* A C toolchain (clang / gcc / msvc) reachable to Nim.
* The full monorepo checked out — the FFI loader walks up to
  `among_them/players/` from the SDK source. Set
  `AMONG_THEM_PLAYERS_DIR=/path/to/among_them/players` to override.

If the toolchain is missing, every entry point that touches the FFI raises
`among_them_sdk.ffi.FFIError` with a clear message naming the missing dep.

### Optional: Cyborg framework

The SDK opportunistically reuses primitives from
[`cyborg-policy-framework`](/Users/aaln/experiments/softmax/policies/policies/cyborg-policy-framework)
when it's checked out at the default path (or `CYBORG_FRAMEWORK_PATH` is
set). Cyborg has no `pyproject.toml`, so we add it to `sys.path` lazily and
fall back to local equivalents if it isn't reachable. See
[`_cyborg.py`](src/among_them_sdk/_cyborg.py) for the contract.

## Hello world

```python
from among_them_sdk import Agent

agent = Agent.create()                       # evidencebot_v2 via FFI, LocalSim
result = agent.run(rounds=1)
print(result.summary)
```

That's it. No API keys. No config. The first run builds the .dylib.

## Instructions — the headline feature

```python
from among_them_sdk import Agent

agent = Agent.create(
    instructions=(
        "Report bodies aggressively. Trust no one after meeting 2. "
        "Vote with the majority unless you have direct evidence."
    ),
    cognitive={"suspicion_threshold": 0.6, "report_eagerness": "high"},
)

print(agent.directives.model_dump_json(indent=2))
```

The string is parsed into a typed `Directives` Pydantic model at agent
creation time. If `OPENAI_API_KEY` (or `ANTHROPIC_API_KEY`,
`AI_GATEWAY_API_KEY`) is set, the SDK calls a small LLM to translate
freeform text into structured directives. Otherwise it falls back to a
deterministic regex/keyword parser. Either way you get the same Pydantic
type — and the scripted modules consult `agent.directives` while making
decisions.

## Module overrides

```python
from among_them_sdk import Agent, LLMVoter

agent = Agent.create(voter=LLMVoter(model="gpt-5.5"))   # voting only
```

```python
from among_them_sdk import Agent, Vote, Voter, VotingContext

class GrudgeVoter(Voter):
    def vote(self, ctx: VotingContext) -> Vote:
        top = max(ctx.suspects, key=lambda s: s.score)
        return Vote(target=top.player_id, reason=f"grudge ({top.score:.2f})")

agent = Agent.create(voter=GrudgeVoter())
```

Slots: `perception`, `memory`, `voter`, `navigator`, `chatter`, `reporter`.
Replace one or all of them — everything else stays scripted.

## Architectural note (read before extending)

The Nim FFI exposes only `abi_version`, `new_policy`, `step_batch`. Per
tick: pixel frames in, action *indices* out. The .so does not surface its
internal voting / reporting / chat decisions, so module overrides cannot
literally replace the bot's voting function inside Nim. Instead the SDK
runs `evidencebot_v2` as the default low-level action producer; the
runtime layer surfaces explicit voting / reporting / chat events to your
modules. When you pass `voter=LLMVoter()`, the runtime calls that voter at
meeting time while the FFI continues to handle every-tick navigation.

This is honest about the FFI surface. Future work (Phase 2+) will extend
the Nim exports so we can intercept inside the .so.

## Tournament submission

Ship your SDK policy to the Among Them leaderboard via cogames using
`SDKPolicy` + a bundled JSON config:

```bash
cd among_them/sdk
python -m among_them_sdk.package \
    --from-agent examples/personas.py:_build_aggressive \
    --policy-name "$USER-sdk-aggressive"
```

The packaging CLI writes `among_them_sdk_config.json` next to the
policy module and prints the exact `cogames upload` command to run.
Full happy path + Phase 2 caveats: [`docs/tournament-submission.md`](docs/tournament-submission.md).

## Going further

For a deeper, hands-on walkthrough — module overrides, hooks, runtimes,
provider routing, troubleshooting, and copy-pasteable recipes — see
[`docs/python-guide.md`](docs/python-guide.md). For the dev loop
(edit → run an 8-player local game vs `nottoodumb` → debug → iterate),
see [`docs/local-iteration-guide.md`](docs/local-iteration-guide.md).
For the design map of where LLMs do (and should) live in the SDK — chat
decomposition, tool-loop patterns, tournament-safe artifacts — see
[`docs/llm-integration.md`](docs/llm-integration.md).

## Examples

* [`examples/hello.py`](examples/hello.py) — 5-line default
* [`examples/instructions.py`](examples/instructions.py) — directives API
* [`examples/custom_voter.py`](examples/custom_voter.py) — Python override
* [`examples/llm_chatter.py`](examples/llm_chatter.py) — LLM mix-in
* [`examples/tournament.py`](examples/tournament.py) — parallel agents

## Tests

```bash
uv run pytest tests/test_ffi_load.py tests/test_agent_default.py -v
```

Both must pass on a machine with a working Nim toolchain. The other tests
(`test_instructions.py`, `test_module_override.py`) run hermetically.

## Layout

```
among_them/sdk/
├── pyproject.toml
├── src/among_them_sdk/
│   ├── __init__.py            # public surface re-exports
│   ├── agent.py               # Agent.create, send, run, stream
│   ├── runner.py              # parallel fan-out
│   ├── runtime.py             # LocalSim / Subprocess / RemoteServer (stub)
│   ├── ffi.py                 # ctypes wrapper + auto-build
│   ├── _cyborg.py             # cyborg framework bridge
│   ├── policy/evidencebot_v2.py
│   ├── modules/               # Voter, Chatter, Reporter, Navigator, Memory, Perception
│   ├── cognition/             # Directives, LLM, ToolLoop, @tool
│   ├── hooks.py
│   ├── config.py
│   ├── extensions.py
│   └── tracing.py
├── examples/
└── tests/
```

See [`../players/sdk/DESIGN.md`](../players/sdk/DESIGN.md) for the full
design rationale and Phase 2+ roadmap.

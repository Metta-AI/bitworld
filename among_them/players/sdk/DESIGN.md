# among-them-sdk — Python SDK Design

> A Cursor‑SDK‑style developer experience for authoring **Among Them** policy
> bots in Python: pure scripted, pure LLM, or any mix of the two — same API,
> same harness, same observability.

---

## 1. Executive summary

Today, writing a competitive Among Them bot means either (a) writing Nim and
shipping a recompiled `.dylib` for the CoGames pipeline
(`among_them/players/build_evidencebot_v2.py:28-51`), or (b) re‑implementing the
WebSocket protocol and perception loop in Python under `bot-policies/sidecar/`
(`among_them/bot-policies/sidecar/bot.py:37-53`). Neither path lets a developer
"just write the brain" — both force them to own the protocol, the localization
math, the bitmask actuator, and a custom build/launch story.

**among-them-sdk** is a Python package (`pip install among-them-sdk`) that
ships a competitive scripted policy out of the box and lets authors **swap any
cognitive module for a Python function or an LLM call without touching the
perception/actuation pipeline**. It borrows naming and DX directly from the
Cursor TypeScript SDK (`Agent.create`, `agent.send`, `run.stream`,
`hooks.json`, `skills/`, subagents) and the OpenAI Agents SDK (`Runner`,
`tool` decorator, lifecycle hooks, tracing).

**Success criteria for DX**

1. **5‑line hello world** that runs a competitive bot in local sim with zero
   config beyond `pip install among-them-sdk`.
2. **One‑line LLM mix‑in**: `voting=LLMVoter("gpt-5.5")` swaps voting only;
   everything else stays scripted.
3. **No Nim required** for pure‑Python authors; **Nim policy reuse**
   available via an FFI runtime when authors want the optimized core.
4. **One config knob to pick the runtime**: in‑process local sim, subprocess
   tournament harness, or remote `games_server` connection.
5. **Tracing that "just works"**: every tick, decision, and LLM call is
   observable in Langfuse and on disk via structlog.

**Five‑line hello world**

```python
from among_them import Agent

agent = Agent.create()                     # default = evidencebot_v2-equivalent
agent.run_local(n_games=10, render=False)  # in-process sim, no LLM, no API keys
```

---

## 2. External research summary

I surveyed five agent SDKs and codified the patterns we should adopt.

**Cursor TypeScript SDK** (`@cursor/sdk`) — `Agent.create({ apiKey, model,
local|cloud })` → `agent.send(prompt)` → `run.stream()`. Runtime is a single
field swap (`local: { cwd }` vs `cloud: { repos, autoCreatePR }`). Skills,
hooks, MCP, and subagents are all filesystem‑driven (`.cursor/skills/`,
`.cursor/hooks.json`, `.cursor/mcp.json`). DX gut feel: opinionated, minimal
ceremony, runtime swap is the killer feature.

**Anthropic Claude Agent SDK** (`claude-agent-sdk`) — top‑level `query(prompt,
options=ClaudeAgentOptions(...))` async generator; subagents declared inline as
`AgentDefinition`s; hooks are typed callbacks (`PreToolUse`, `PostToolUse`,
`SessionStart`, …) registered via `HookMatcher`. Skills loaded from
`.claude/skills/*/SKILL.md`. DX gut feel: heavy on filesystem conventions,
strong hook taxonomy, weak ergonomic story for stateful long‑running agents.

**Vercel AI SDK** — `new ToolLoopAgent({ model, tools, stopWhen })` with the
loop, context, and stop conditions handled internally; `tool({ description,
inputSchema, execute })` is the canonical tool factory; `prepareStep`
intercepts every loop iteration. Provider model strings are AI Gateway
addresses (e.g. `"openai/gpt-5.5"`). DX gut feel: best‑in‑class tool loop,
provider unification.

**OpenAI Agents SDK (Python)** — `Agent(name, instructions, tools, handoffs,
model)` + `Runner.run_sync(agent, prompt)`; tools are `@function_tool`
decorators, automatic Pydantic schema; sessions are first‑class; built‑in
tracing; handoffs are an explicit primitive. DX gut feel: smallest primitive
set, "Python‑first" — what a Python‑native game SDK should imitate.

**LangGraph + Pydantic AI** — LangGraph is graph/state‑machine flavored
(`StateGraph`, nodes, edges) — too heavyweight for a tick loop. Pydantic AI
gives typed agents, dependency injection (`deps_type`), and `@agent.tool`
decorators — worth borrowing the typed‑deps idea so cognitive modules can be
constructor‑injected.

**What to steal**

- `Agent.create(...)` factory + `agent.send(...)` + `run.stream()` from Cursor
  SDK — primary external surface.
- `Runner.run_sync(agent, ...)` and lifecycle hooks (`AgentHooks`,
  `RunHooks`) from OpenAI Agents SDK — Python‑idiomatic batch orchestration.
- `ToolLoopAgent`/`stopWhen`/`prepareStep` semantics from Vercel AI SDK for
  the LLM‑driven decision loops (voting, chat).
- `tool()` factory + Pydantic schemas (Vercel/OpenAI) for any LLM tool we
  expose.
- Filesystem conventions (`.among-them/hooks.json`, `among_them/skills/`,
  `among-them.toml`) from Cursor + Claude Agent SDK.
- `AgentDefinition` for declaring subagents inline (Claude Agent SDK).
- AI Gateway model strings (Vercel) so model choice is a single string, not a
  provider import.
- Pydantic AI's `deps_type` idea for typed dependency injection of cognitive
  modules.

**What NOT to steal**

- LangGraph's explicit graph DSL — wrong abstraction for a tick loop.
- Claude Agent SDK's permission‑prompt flow — irrelevant for a game policy.
- Cursor SDK's "cloud VM with PR" runtime — we don't need PRs; cloud means
  "submitted to `games_server`."
- OpenAI Agents SDK's `handoffs` as a top‑level primitive — overkill; we model
  this with subagents instead.
- Heavy tracing UIs as the only observability story — we'll be Langfuse‑first
  but offer a zero‑dependency stdlog default.

**Naming we adopt**: `Agent.create`, `agent.send`, `run.stream`, `Runner`,
`@tool`, `hooks.json`, `skills/`, `subagents`, `local`/`remote` runtime keys.

---

## 3. Current state + pain points

A policy author today walks into a thicket. The cliff notes from a thorough
read of the existing code:

- **Two parallel author paths exist.** The CoGames/tournament path runs Nim
  via ctypes (`among_them/players/evidencebot_v2_policy.py:56-122`, ABI version
  pinned at `EVIDENCEBOT_V2_ABI_VERSION = 1` in
  `among_them/players/build_evidencebot_v2.py:25`). The "smart bot" path runs
  Python that re‑implements the wire protocol
  (`among_them/bot-policies/sidecar/bot.py:37-53`). Neither path lets a Python
  author drop into the modular Nim pipeline directly.
- **The Nim pipeline is already modular** — `decideNextMaskCore` orchestrates
  perception → localization → tasks/motion/evidence → policy
  (`among_them/players/modulabot/bot.nim:355-501`); imposter/crewmate ladders
  live in `policy_imp.nim` / `policy_crew.nim`
  (`among_them/players/modulabot/policy_imp.nim:1-67`,
  `among_them/players/modulabot/policy_crew.nim:35-50`). A Python SDK should
  mirror this pipeline 1:1.
- **LLM seams already exist, but only in Nim.** `mod_talks` adds an
  `LlmDispatcher` for non‑blocking subprocess/HTTP completion
  (`among_them/players/mod_talks/llm_dispatch.nim:46-119`) and an
  `LlmVotingState` machine (`among_them/players/mod_talks/llm.nim:64-75`),
  guarded by `when defined(modTalksLlm)` (`among_them/players/mod_talks/llm.nim:16-22`).
  Python can and should reuse the **structured JSON context** they emit
  (`among_them/players/mod_talks/LLM_VOTING.md:54-73`).
- **The Python sidecar already has a clean cognitive split**: `Trigger` →
  `WorkingMemory` → `Narrator` (context builder) → `Advisor` (LLM) →
  `Directive` actuator (`among_them/bot-policies/sidecar/triggers.py:69-99`,
  `among_them/bot-policies/sidecar/memory.py:60-73`,
  `among_them/bot-policies/sidecar/advisor.py:14-61`). This is the right
  template for the SDK's cognitive layering — just generalized and packaged.
- **Server‑side launch is via Docker manifests** —
  `coplayer_manifest.json` scanned per game
  (`games_server/games_server.nim:543-553`), Docker containers spun up by
  `startWaitingBots` (`games_server/games_server.nim:1695-1742`), capped at 16
  players (`games_server/games_server.nim:14`). The SDK must produce a manifest
  + container/script entry point that `games_server` can launch unmodified.
- **Pain points authors hit today**: localization CPU
  (`among_them/players/how_to_make_a_bot.md:119-141`), interstitial detection
  (`among_them/players/how_to_make_a_bot.md:166-179`), task completion timing
  (`among_them/players/how_to_make_a_bot.md:292-307`), ABI mismatches forcing
  rebuilds (`among_them/players/evidencebot_v2_policy.py:173-199`), duplicated
  protocol constants between Python and Nim (`among_them/bot-policies/sidecar/bot.py:37-44`
  vs `common/protocol.nim:4-25`), and SSL `-d:ssl` requirement for HTTPS in
  Nim LLM provider (`among_them/players/mod_talks/llm_provider.nim:49-59`).

The SDK's job is to absorb every one of these pain points into the default
configuration, so authors only write what they want to change.

---

## 4. Proposed Python SDK API

### 4.1 Top‑level surface

```python
from among_them import Agent, Runner, tool, hooks
from among_them.modules import Perception, Memory, Voter, Navigator, Chatter
from among_them.providers import LLM, AIGateway
from among_them.runtimes import LocalSim, Subprocess, RemoteServer
```

Three objects matter:

- **`Agent`** — the policy. Stateful across ticks of a single game. Created
  via `Agent.create(...)`. Composes cognitive modules.
- **`Runner`** — orchestration. Picks a runtime, runs N games (sequential or
  parallel), collects results, drives tracing. Borrowed from OpenAI Agents SDK.
- **`Module`** — the constructor‑injectable unit of cognition. `Perception`,
  `Memory`, `Voter`, `Navigator`, `Chatter`, `Reporter` are the canonical six.

### 4.2 `Agent.create()` shape

```python
@dataclass
class AgentConfig:
    role_hint: Literal["auto", "crewmate", "imposter"] = "auto"
    perception: Perception = ScriptedPerception()       # localization, sprites
    memory:     Memory     = WorkingMemory()            # tiered memory + diff log
    voter:      Voter      = ScriptedVoter()            # default = evidence ladder
    navigator:  Navigator  = ScriptedNavigator()        # path/motion masks
    chatter:    Chatter    = SilentChatter()            # default: emit nothing
    reporter:   Reporter   = ScriptedReporter()         # body-report heuristic
    hooks:      AgentHooks = AgentHooks()
    skills_dir: Path | None = Path("among_them/skills")
    trace:      Tracer     = StructlogTracer()

class Agent:
    @classmethod
    def create(cls, **overrides) -> "Agent": ...
    async def send(self, observation: Frame) -> Decision: ...
    async def connect(self, runtime: Runtime) -> "Run": ...
```

The defaults are **the entire evidencebot_v2 policy ported to Python** — no
LLM, no API key, competitive at submission time. Every override is a one‑line
swap.

### 4.3 Runtime abstraction

Borrowing Cursor SDK's `local | cloud` split. Three runtimes, one type:

```python
class Runtime(Protocol):
    async def stream_observations(self) -> AsyncIterator[Frame]: ...
    async def submit_action(self, mask: ActionMask) -> None: ...

LocalSim(seed=42, n_players=8, role_assignment="auto")          # in-process
Subprocess(binary="evidencebot", config_dir=...)                 # for tournaments
RemoteServer(url="wss://games.softmax.dev/player", token=...)    # live games
```

```python
agent = Agent.create()
run = await agent.connect(LocalSim())     # or RemoteServer(...)
async for event in run.stream():
    print(event)                          # Tick | MeetingStart | Vote | Kill | GameOver
```

This means **the same Agent runs in unit tests, tournaments, and the live
server** without code changes. `LocalSim` reuses the `MultiAgentPolicy` ABI
already defined in `among_them/players/evidencebot_v2_policy.py:99-117`.

### 4.4 Modular cognition

Each module is an `abc.ABC` with one obvious method. Replacement is a
constructor kwarg:

```python
class Voter(ABC):
    async def vote(self, ctx: VotingContext) -> Vote: ...

class Navigator(ABC):
    def step(self, state: BotState) -> ActionMask: ...

class Perception(ABC):
    def perceive(self, frame: Frame, state: BotState) -> Percept: ...

# ... Memory, Chatter, Reporter analogous
```

This is the Pydantic‑AI / OpenAI Agents SDK pattern (typed deps as
constructor args), specialized to our six modules. The pipeline that consumes
them mirrors `decideNextMaskCore`
(`among_them/players/modulabot/bot.nim:355-501`):

```
Frame ─▶ Perception ─▶ Memory ─▶ (Reporter | Voter | Chatter | Navigator) ─▶ ActionMask
```

### 4.5 LLM mix‑in (the headline feature)

```python
from among_them.providers import LLM

agent = Agent.create(
    voter=LLMVoter(LLM("gpt-5.5"), prompt="among_them/skills/voting.md"),
    chatter=LLMChatter(LLM("anthropic/claude-opus-4.7"), tone="suspicious"),
)
```

`LLMVoter` and `LLMChatter` are concrete `Voter`/`Chatter` subclasses that
internally run a **`ToolLoop`** (Vercel AI SDK pattern). The agent stays
scripted everywhere else; only voting and chat go through an LLM.

### 4.6 Tool‑loop pattern

For LLM‑driven decisions we ship a thin `ToolLoop`:

```python
@tool
def accuse(player_id: str, reason: str) -> Vote:
    """Vote to eject a player. `reason` will be posted in chat."""
    return Vote(target=player_id, reason=reason)

@tool
def skip() -> Vote:
    """Skip voting this round."""
    return Vote.SKIP

class LLMVoter(Voter):
    def __init__(self, llm: LLM, tools: list = (accuse, skip)):
        self._loop = ToolLoop(llm=llm, tools=tools, stop_when=stop_on_vote)

    async def vote(self, ctx: VotingContext) -> Vote:
        return await self._loop.run(prompt=ctx.to_prompt())
```

`ToolLoop.run` returns when any registered tool's return type matches
`stop_when` — exactly the `stopWhen` semantics from Vercel AI SDK. Tools are
declared with the `@tool` decorator (Pydantic schema auto‑generated); this
matches the OpenAI Agents SDK `@function_tool` and Vercel AI SDK `tool()` we
researched.

### 4.7 Provider abstraction

One unified `LLM` class, AI‑Gateway‑style model strings:

```python
LLM("gpt-5.5")                          # OpenAI direct
LLM("anthropic/claude-opus-4.7")        # AI Gateway routed
LLM("bedrock/anthropic.claude-3-5-sonnet")
LLM("local/llama3:70b")                  # via Ollama / vLLM
```

Internally we wrap `openai`, `anthropic`, and `httpx`. Default routing is via
**Vercel AI Gateway** when `AI_GATEWAY_API_KEY` is set — directly informed by
the `mod_talks` `LlmDispatcher` design
(`among_them/players/mod_talks/llm_dispatch.nim:46-119`) which already
multiplexes provider kinds. Output is always typed (`pydantic.BaseModel` with
JSON‑mode forcing for structured fields).

### 4.8 Extension model — **entry points (decision)**

I picked **Python entry points** over decorator registries or a `Module`
plugin protocol. Justification:

1. `pip install among-them-evilbot` should drop a new agent profile into
   `among-them list-profiles` without import side effects.
2. Tournament submission already uses Docker manifests
   (`games_server/games_server.nim:543-553`); pip‑installable, entry‑point‑
   declared profiles are the Python equivalent and play cleanly with the
   tournament packager.
3. Decorators force authors to import a registry module; entry points don't.

```toml
# pyproject.toml of a third-party bot
[project.entry-points."among_them.profiles"]
evilbot = "evilbot.profile:EvilBotProfile"

[project.entry-points."among_them.modules.voter"]
hothead = "evilbot.voter:HotheadVoter"
```

Then:

```python
agent = Agent.create(profile="evilbot")
agent = Agent.create(voter="hothead")     # by entry-point name
```

A `Module` ABC subclass is still the implementation contract — entry points
just publish them.

### 4.9 Hooks

A typed callback table on `AgentHooks`, plus a filesystem fallback at
`.among-them/hooks.json` (Cursor‑style). The events match the cognitive
pipeline plus protocol events:

```python
class AgentHooks:
    pre_tick:    Callable[[Frame, BotState], None] | None = None
    post_tick:   Callable[[Decision, BotState], None] | None = None
    on_vote:     Callable[[Vote, VotingContext], None] | None = None
    on_kill:     Callable[[KillEvent], None] | None = None
    on_meeting:  Callable[[MeetingEvent], None] | None = None
    on_message:  Callable[[ChatMessage], None] | None = None
    on_llm_call: Callable[[LLMCall], None] | None = None
```

Hooks can also be registered as entry points
(`among_them.hooks.pre_tick = "mybot.hooks:my_pre_tick"`), so observability and
analytics packages compose cleanly.

### 4.10 Skills directory

Mirroring Cursor's `.cursor/skills/` and Claude Agent SDK's
`.claude/skills/*/SKILL.md`. We adopt **`among_them/skills/*.md`** with
front‑matter metadata. The SDK auto‑injects matching skills into the LLM
prompt when their **front‑matter triggers** match the current event:

```markdown
---
name: voting-strategy
trigger: on_vote
applies_to: [crewmate]
---
When the body location overlaps with someone's last reported position by ≤3
tiles within ≤5 ticks, vote them out. Otherwise, skip.
```

This is identical in spirit to the existing strategy markdown
(`among_them/players/evidencebot_strategy.md`) but loaded automatically.

### 4.11 Subagents

Cursor‑style: a parent agent spawns a focused child reasoner. We use this for
"should I report this body?" and "draft an accusation":

```python
reporter_subagent = Subagent(
    name="report-decider",
    model=LLM("gpt-5.5"),
    prompt="Decide whether to report a body given the evidence list.",
)

agent = Agent.create(
    reporter=LLMReporter(subagent=reporter_subagent),
)
```

Subagents share the parent's `Tracer` and `Memory` snapshot but have isolated
LLM context. This is a thin wrapper around `ToolLoop` + a forked memory
slice — directly inspired by Claude Agent SDK's `AgentDefinition`.

### 4.12 Tracing / observability

Two backends, one API:

- **Default**: `structlog` JSONL on disk — zero dependency, works in CI.
- **Opt‑in**: **Langfuse**, configured via `LANGFUSE_*` env vars or
  `among-them.toml`. Every `Tick`, `Decision`, `LLMCall`, and `Vote` becomes a
  Langfuse span; LLM calls auto‑attach prompt/completion. We integrate via
  the [`langfuse`](https://langfuse.com) Python SDK.
- **Bridge**: emit OpenTelemetry traces too, so anyone with an OTel collector
  gets data without Langfuse.

The `Tracer` interface and existing per‑frame trace points
(`among_them/players/modulabot/bot.nim:507-516`) are reused — the Python
tracer wraps them when the runtime is `Subprocess` to a Nim binary.

### 4.13 Config + secrets

Three layers, in increasing precedence:

1. `among-them.toml` at the repo root (committable defaults).
2. Environment variables (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
   `AI_GATEWAY_API_KEY`, `AMONG_THEM_PROFILE`, `LANGFUSE_PUBLIC_KEY`).
3. Constructor kwargs to `Agent.create(...)`.

`among-them.toml` example:

```toml
[agent]
profile = "evidencebot_v2"

[agent.voter]
type   = "llm"
model  = "openai/gpt-5.5"

[runtime]
default = "local-sim"

[runtime.remote]
url = "wss://games.softmax.dev/player"

[tracing]
backend  = "langfuse"
sampling = 0.2
```

Secrets never appear in `among-them.toml`; the loader actively rejects keys
matching `*_API_KEY`.

---

## 5. Six progressive code samples

### (a) Default bot in local sim — 5 lines, zero config

```python
from among_them import Agent

agent = Agent.create()
agent.run_local(n_games=10)
```

### (b) Default bot + OpenAI brain on chat only

```python
from among_them import Agent
from among_them.modules import LLMChatter
from among_them.providers import LLM

agent = Agent.create(
    chatter=LLMChatter(LLM("openai/gpt-5.5"), tone="paranoid")
)
agent.run_local(n_games=10)
```

### (c) Custom voting heuristic — pure Python function

```python
from among_them import Agent, Voter, Vote

class GrudgeVoter(Voter):
    """Vote whoever was nearest the most recent body."""
    async def vote(self, ctx):
        nearest = min(ctx.suspects, key=lambda s: s.distance_to_body)
        return Vote(target=nearest.id, reason=f"You were 2 tiles from {ctx.body.victim}.")

agent = Agent.create(voter=GrudgeVoter())
agent.run_local(n_games=20)
```

### (d) Full LLM imposter policy — tool loop

```python
from among_them import Agent, tool, ToolLoop, LLMVoter, LLMChatter
from among_them.providers import LLM
from among_them.modules import LLMNavigator

@tool
def go_to(room: str) -> "Move":
    """Move to a named room."""
    return Move(room=room)

@tool
def kill(player_id: str) -> "Kill":
    """Kill a specific player. Only callable when alone with them."""
    return Kill(target=player_id)

@tool
def fake_task(task_id: str) -> "FakeTask":
    """Pretend to do a task at this location."""
    return FakeTask(task_id=task_id)

llm = LLM("anthropic/claude-opus-4.7")

agent = Agent.create(
    role_hint="imposter",
    navigator=LLMNavigator(ToolLoop(llm=llm, tools=[go_to, kill, fake_task])),
    voter=LLMVoter(llm),
    chatter=LLMChatter(llm, tone="defensive"),
)
agent.run_local(n_games=50)
```

### (e) User‑defined extension via `pip install` + entry point

In `evilbot/pyproject.toml`:

```toml
[project]
name = "among-them-evilbot"
dependencies = ["among-them-sdk>=0.4"]

[project.entry-points."among_them.profiles"]
evilbot = "evilbot.profile:EvilBotProfile"
```

In `evilbot/profile.py`:

```python
from among_them import AgentProfile
from .voter import HotheadVoter
from .chatter import GaslightChatter

class EvilBotProfile(AgentProfile):
    name = "evilbot"
    voter   = HotheadVoter()
    chatter = GaslightChatter(model="openai/gpt-5.5")
```

End user, after `pip install among-them-evilbot`:

```python
from among_them import Agent
agent = Agent.create(profile="evilbot")
agent.run_local()
```

### (f) Tournament — N parallel agents against `games_server`

```python
import asyncio
from among_them import Agent, Runner, RemoteServer

profiles = ["default", "evilbot", "grudge_voter", "llm_imposter"]
agents = [Agent.create(profile=p) for p in profiles]

runner = Runner(
    agents=agents,
    runtime=RemoteServer(url="wss://games.softmax.dev/player"),
    parallelism=4,
    n_games_per_agent=25,
)
asyncio.run(runner.run())
print(runner.leaderboard())     # win-rate, kills/game, eject-correctness
```

---

## 6. Packaging

**Layout** (monorepo location: `among_them/players/sdk/` for the design,
`packages/among-them-sdk/` for the published package — eventually pulled out
into its own repo):

```
packages/among-them-sdk/
├── pyproject.toml
├── src/among_them/
│   ├── __init__.py            # re-export Agent, Runner, tool, hooks
│   ├── agent.py
│   ├── runner.py
│   ├── tool.py
│   ├── hooks.py
│   ├── modules/               # Perception, Memory, Voter, Navigator, Chatter, Reporter
│   ├── providers/             # LLM, AIGateway, OpenAI, Anthropic, Bedrock, Local
│   ├── runtimes/              # LocalSim, Subprocess, RemoteServer
│   ├── skills/                # bundled default skill markdown
│   ├── tracing.py             # structlog + Langfuse + OTel bridges
│   └── ffi/                   # ctypes wrapper around modulabot/evidencebot_v2 .so
└── tests/
```

**`pyproject.toml`** (the shape, not full):

```toml
[project]
name = "among-them-sdk"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "httpx>=0.27",
    "pydantic>=2.7",
    "anyio>=4.4",
    "structlog>=24",
    "websockets>=12",
    "tomli>=2",
]

[project.optional-dependencies]
openai     = ["openai>=1.40"]
anthropic  = ["anthropic>=0.30"]
bedrock    = ["boto3>=1.34"]
langfuse   = ["langfuse>=2.40"]
viz        = ["rich>=13"]

[project.scripts]
among-them = "among_them.cli:main"

[project.entry-points."among_them.profiles"]
default        = "among_them.profiles:DefaultProfile"
evidencebot_v2 = "among_them.profiles:EvidenceBotV2Profile"
```

**Python**: 3.11 minimum (we want `tomllib`, generic syntax, `asyncio.TaskGroup`).
**No mandatory ML deps** — `numpy` only when the FFI runtime is selected.

---

## 7. Open questions

1. **In‑process Nim FFI vs subprocess for the default scripted policy?**
   *Recommendation:* in‑process via ctypes + `evidencebot_v2.dylib`
   (`among_them/players/evidencebot_v2_policy.py:99-117`) for performance, with
   a pure‑Python fallback that we keep parity‑tested. The pure‑Python fallback
   is non‑negotiable for `pip install` UX without a Nim toolchain.

2. **Async vs sync top‑level API?** *Recommendation:* async‑first (matches
   Claude Agent SDK and the WebSocket runtime), with `Agent.run_local_sync()`
   sugar for scripts and notebooks.

3. **Pin‑down LLM tool‑loop semantics: turn‑based vs streaming?**
   *Recommendation:* turn‑based by default for voting (low latency budget,
   often <1 sec), streaming for chat where the user perceives the typing.

4. **Skill auto‑loading: prompt prefix vs RAG?** *Recommendation:* prefix for
   the first 1–2 skill markdowns matched by event, fall back to RAG (with a
   bundled Sentence Transformers backend) when more than 8 skills are
   registered. Keep the API identical.

5. **Where do Nim‑side LLM calls (`mod_talks`) fit?** *Recommendation:* drop
   them. Long‑term, all LLM cognition runs Python‑side (the SDK is the source
   of truth). The Nim core stays pure scripted; if Nim needs an LLM result, it
   reads it from a Python‑written shared‑memory channel — extending the
   `LlmDispatcher` FFI seam already at
   `among_them/players/mod_talks/llm_dispatch.nim:46-82`.

6. **AI Gateway hard requirement, or optional?** *Recommendation:* optional
   but default‑on when `AI_GATEWAY_API_KEY` is present; we don't want pip
   users to need a Vercel account to run hello‑world.

7. **License + repo location.** *Recommendation:* MIT, eventually a separate
   repo (`among-them-sdk`) for clean external contributions. For Phase 0–2
   live in this monorepo under `packages/among-them-sdk/`.

---

## 8. Phased rollout

**Phase 0 — Scaffold (1 week).** *DoD:* `pip install -e .` works; `Agent`,
`Runner`, `LocalSim`, `tool`, `hooks` exist as typed stubs; default profile
returns no‑op masks; smoke test in CI.

**Phase 1 — Scripted policy parity (3 weeks).** *DoD:* a pure‑Python port of
`evidencebot_v2`'s perception, voting, and navigation passes a parity test
against the Nim FFI on 1000 fixed seeds; Subprocess runtime can launch a
compiled Nim binary and stream its decisions; `among_them/skills/` shipping
2–3 default skills.

**Phase 2 — LLM mix‑ins (2 weeks).** *DoD:* `LLMVoter` and `LLMChatter` ship;
`LLM("openai/...")` and `LLM("anthropic/...")` work; AI Gateway routing works
when env var present; `ToolLoop` battle‑tested on the imposter sample (d).
Langfuse tracing is enabled by default when keys are set.

**Phase 3 — Extension model (1 week).** *DoD:* third‑party `pip install
among-them-evilbot` profile loads via entry point; `among-them list-profiles`
CLI; `among-them.toml` config layering works; skill auto‑loading hits
front‑matter triggers.

**Phase 4 — Cloud + tournament (3 weeks).** *DoD:* `RemoteServer` runtime
talks to live `games_server` over WebSocket and survives a full tournament;
`Runner` parallelism with `RemoteServer` confirmed; SDK emits a
`coplayer_manifest.json` (`games_server/games_server.nim:543-553`) so that
`startWaitingBots` (`games_server/games_server.nim:1695-1742`) launches
SDK‑authored bots in containers without Nim‑specific scaffolding;
end‑to‑end tournament demo with 4 SDK profiles + 4 legacy Nim bots.

After Phase 4 the SDK is the recommended path for all new Among Them bots and
the legacy `bot-policies/sidecar/` tree can be archived.

---

## 9. Implementation status (Phase 0 + Phase 1)

**Implemented at** `among_them/sdk/` (sibling to this design doc, package
name `among_them_sdk`). Core surface — `Agent`, `Runner`, `LocalSim`,
module ABCs, the FFI loader, the cognition layer, and the natural-language
`instructions=` API — is shipping. The default policy is `evidencebot_v2`
loaded via FFI; there is **no pure-Python fallback** in this milestone.

What deviated from this design:

- **No async API yet.** Phase 0/1 ships a sync `Agent.run(rounds=N)` that
  satisfies the 5-line hello world; async + `connect(runtime)` arrives
  with Phase 4 streaming.
- **Module overrides run *above* the FFI**, not inside it. The Nim shared
  library exposes only `abi_version`, `new_policy`, and `step_batch`, so
  the SDK cannot literally replace `decideVotingMask` inside the bot.
  Instead, the runtime calls user-supplied modules at meeting / report /
  chat events while the FFI handles every-tick navigation. See the
  architectural note at the top of
  `among_them_sdk.policy.evidencebot_v2`.
- **Cyborg framework is bridged via `sys.path`**, not a path-installable
  dependency — cyborg has no `pyproject.toml`. The SDK reuses cyborg's
  `Directive`/`Command`/`CommandKind` types when the path is reachable
  and falls back to local equivalents otherwise.
- **Skill auto-loading and the AgentDefinition subagent shape are
  deferred to Phase 3.**
- **Langfuse + OTel emission are deferred to Phase 4.** The default
  structlog tracer is wired up; `tracing.enable_langfuse()` raises
  `NotImplementedError` for now.

Required tests (`test_ffi_load.py`, `test_agent_default.py`) plus
`test_instructions.py` and `test_module_override.py` all pass under
`uv run pytest tests/`. See `among_them/sdk/README.md` for quickstart.

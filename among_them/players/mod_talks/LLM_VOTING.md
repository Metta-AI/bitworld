# mod_talks — LLM Voting Integration Design

This is the detailed design for the LLM-powered voting phase described at a
high level in `DESIGN.md §14`. It specifies the full per-role pipeline,
the multi-frame state machine, prompt and context structure, new types, and
integration points in existing modules.

## Implementation status

**Shipped through Sprint 5.** Most of this document is implemented. Where
the doc and the code disagree, **the code is authoritative**; the doc
captures the original intent + rationale, plus enough detail to read the
implementation. Treat this as design history, not as a runnable spec.

The sprint-by-sprint history with checkboxes is in `LLM_SPRINTS.md`.
Short summary:

- **Sprints 1-5 shipped:** Nim state machine (`llm.nim`), `Bot` types
  (`LlmVotingState`, `LlmState`, `LlmMock`, `VoteChatLine`,
  `SelfKeyframe`), FFI surface, Anthropic Bedrock + direct Python wrapper
  with `_OpenAIController` fallback skeleton, mock-LLM harness,
  trace observability (schema v3, optional context capture), concurrent
  dispatch (3-4× faster than the Sprint 1 baseline), per-call-kind
  timeouts, stale-response detection, Anthropic tool-use, retry/backoff,
  UTF-8 transliteration, prompt-eval harness, runtime persuasion toggle,
  multi-provider lineage in manifest harness_meta. Compile-time gate
  `-d:modTalksLlm` with parity preserved in the non-LLM build.
- **Deferred follow-ups (need access / budget, not code):** 40+ game
  persuasion A/B campaign (Sprint 5.2); live OpenAI verification
  (Sprint 5.3 — needs `OPENAI_API_KEY`).
- **Cancelled:** Sprint 4.6 FFI prefix rename (low-impact churn —
  see `DESIGN.md §1.5`).

Where this doc's prescriptions disagree with the implementation:

- **§6 "side-channel thread in Nim" — superseded.** The Sprint 4
  implementation moves concurrency to the Python wrapper's
  `ThreadPoolExecutor` (`AmongThemPolicy._executor`). The Nim side
  has a single `LlmRequestSlot`; the Python wrapper polls it,
  dispatches futures, and feeds JSON responses back via
  `modulabot_set_llm_response`. See `LLM_SPRINTS.md §4.1`.
- **§11 "mock-LLM mode" — implementation diverged.** The plan
  proposed a Python-side mock; the Sprint 3 implementation runs
  the mock entirely in Nim (`llmMockEnable` / `llmMockPump`) so
  `parity.nim` doesn't need Python. Same code path is exercised
  as live runs minus HTTP.
- **§12 Q-LLM1/Q-LLM6 "Bedrock auth pending investigation" —
  resolved.** The Python wrapper uses `anthropic.AnthropicBedrock`
  with the standard boto3 credential chain. See
  `cogames/amongthem_policy.py:_AnthropicController._init_client`.

---

## 1. Goals and constraints

### Goals

1. **Evidence-grounded reasoning.** The crewmate uses its full `Memory` log —
   sightings, bodies, prior meeting outcomes, alibis — to form a suspicion
   hypothesis rather than relying solely on the binary `nearBodyTicks` /
   `witnessedKillTicks` score used by modulabot.
2. **Reactive chat.** Both roles read what other players say during voting and
   update their behavior accordingly: crewmates ask for evidence or challenge
   inconsistencies; imposters identify and amplify bandwagon targets.
3. **Contextually appropriate messages.** Chat should vary in phrasing and
   timing, react to specific claims, and not be identifiable as a bot from
   its message cadence or template pattern.
4. **Graceful degradation.** If the LLM is unavailable, times out, or returns
   invalid output, the bot falls back to modulabot's rule-based behavior
   transparently. The LLM is an enhancement, not a hard dependency.
5. **Non-perturbing to non-voting behavior.** The LLM layer touches only
   `voting.nim`, `chat.nim`, and a new `llm.nim`. Perception, navigation,
   task execution, and kill logic are unchanged.

### Hard constraints

- **No blocking the control loop.** The voting phase runs frame-by-frame at
  ~24 fps. LLM calls must be issued asynchronously (or on a side thread) and
  their results consumed on a subsequent frame. The control loop never waits.
- **One pending chat at a time.** The existing `ChatState.pendingChat`
  mechanism queues a single string. The LLM layer must respect this and not
  overwrite a message that hasn't been sent yet.
- **Role secrecy for imposters.** The imposter LLM context must never include
  the word "imposter" in any string that could appear in a chat message or be
  inferred from message timing.
- **Compile-time opt-in.** `when defined(modTalksLlm)` gates every LLM call
  site. Without the flag, the compiled binary is bit-for-bit identical to
  modulabot. This keeps the parity harness and CoGames submission unaffected
  until the integration is ready.
- **Speaker attribution (Q-LLM9 resolved, Sprint 2.1 shipped).** Original
  intent was that speaker attribution should land BEFORE writing `llm.nim`.
  In practice we shipped it as Sprint 2.1, after the Sprint 1 integration
  proved the rest of the LLM plumbing worked. Detection lives in
  `voting.detectChatSpeaker` (samples PlayerColors palette pixels in the
  chat-row pip rectangle and returns the dominant color index).
  `LlmChatEntry.speakerColor` carries the result through to the LLM
  context. Multi-line messages auto-attribute because the sim renders
  one 12×12 sprite per message and each text row of the message overlaps
  the sprite vertically.

---

## 2. Voting phase overview

From the game's perspective, a voting phase begins when the voting screen
appears (interstitial gate in `bot.nim:decideNextMaskCore`) and ends when
`VotingState.voting` transitions back to false. The existing `decideVotingMask`
drives the cursor to the chosen target after `VoteListenTicks` (currently 100
ticks ≈ 4 seconds at 24 fps) and presses A.

The LLM layer introduces a **multi-stage state machine** that runs alongside
the frame loop. It does not replace `decideVotingMask`; it feeds a chosen
target and queued chat messages into the structures that `decideVotingMask`
already consults.

**Crewmate state machine:**

```
Meeting called (crewmate)
      │
      ▼
 ┌─────────────────────────────────────────────────────────────┐
 │  FORMING_HYPOTHESIS                                         │
 │  Async: call LLM with full memory context                   │
 │  Result: ranked suspect list + confidence                   │
 └──────────────┬──────────────────────────────────────────────┘
                │ result arrives
                ▼
         ┌─────────────┐
         │  confidence? │
         └──────┬───────┘
        high ◄──┘──► not high
         │                │
         ▼                ▼
   ┌──────────┐     ┌──────────┐
   │ ACCUSING │     │ LISTENING│
   │ queue    │     │ silent;  │
   │ accusation     │ wait for │
   │ chat msg │     │ others   │
   └────┬─────┘     └────┬─────┘
        │                │
        └────────┬────────┘
                 │ new chat line(s) observed
                 ▼
        ┌─────────────────────┐
        │  REACTING           │◄─────────────┐
        │  Async: belief-     │              │
        │  update call        │    more chat │
        │  Result: updated    │    lines     │
        │  scores + action    │              │
        └────────┬────────────┘              │
                 │                           │
          ┌──────┴──────┐                    │
          │  action?    │                    │
          └──────┬──────┘                    │
         speak / │ask          silent        │
                 ▼                           │
        ┌────────────────┐                   │
        │ queue chat msg │                   │
        └────────┬───────┘                   │
                 └───────────────────────────┘
                 │
                 │ confidence high OR VoteListenTicks elapsed
                 ▼
        ┌─────────────────┐
        │  VOTING         │
        │  set voteTarget │
        │  optionally     │
        │  queue persuade │
        └─────────────────┘
```

**Imposter state machine:**

```
Meeting called (imposter)
      │
      ▼
 ┌─────────────────────────────────────────────────────────────┐
 │  FORMING_STRATEGY                                           │
 │  Async: call LLM with full context + safe_colors            │
 │  Result: best_target, strategy, timing, initial_chat        │
 └──────────────┬──────────────────────────────────────────────┘
                │ result arrives
                ▼
         ┌──────────────────────┐
         │  strategy?           │
         └──┬───────────┬───────┘
     bandwagon        preemptive
     (wait)           (speak first)
         │                │
         ▼                ▼
   ┌──────────┐     ┌──────────┐
   │ LISTENING│     │ ACCUSING │
   │ wait for │     │ queue    │
   │ others   │     │ preemptive
   │          │     │ msg      │
   └────┬─────┘     └────┬─────┘
        │                │
        └────────┬────────┘
                 │ new chat line(s) observed
                 ▼
        ┌─────────────────────┐
        │  REACTING           │◄─────────────┐
        │  Async: strategic-  │              │
        │  react call         │    more chat │
        │  Result: action     │    lines     │
        │  (corroborate /     │              │
        │   deflect / silent) │              │
        └────────┬────────────┘              │
                 │                           │
          ┌──────┴──────┐                    │
          │  action?    │────────────────────┘
          └──────┬──────┘         silent
        speak    │
                 ▼
        ┌────────────────┐
        │ queue chat msg │
        └────────┬───────┘
                 │
                 │ VoteListenTicks elapsed
                 ▼
        ┌─────────────────┐
        │  VOTING         │
        │  vote best_target│
        └─────────────────┘
```

The imposter follows a simpler variant of the same machine (see §4).

---

## 3. Crewmate pipeline

### 3.1 Stage 1 — Hypothesis formation

**Trigger:** `LlmVotingState.stage` transitions to `Forming` on the first frame
that `VotingState.voting == true` and `LlmVotingState.stage == Idle`.

**Action:** Dispatch an async LLM call (see §6 for the call mechanism). Do not
block. On this frame and subsequent frames while the call is in flight, the bot
sends no chat and holds the vote cursor at skip.

**Context assembled from bot state:**

```json
{
  "task": "hypothesis",
  "role_hint": "crewmate",
  "self_color": "<name>",
  "living_players": ["<color>", ...],
  "round_events": {
    "bodies": [
      {
        "room": "<room name>",
        "tick_relative": <ticks before meeting>,
        "witnesses_near": ["<color>", ...]
      }
    ],
    "sightings_since_last_meeting": [
      {
        "color": "<color>",
        "room": "<room name>",
        "tick_relative": <ticks before meeting>
      }
    ],
    "alibis": [
      {
        "color": "<color>",
        "task_room": "<room>",
        "tick_relative": <ticks before meeting>
      }
    ]
  },
  "prior_meetings": [
    {
      "ejected": "<color>" | null,
      "self_vote": "<color>" | "skip",
      "chat_summary": ["<line>", ...]
    }
  ],
  "evidence_scores": {
    "<color>": {
      "near_body_count": <int>,
      "witnessed_kill": <bool>,
      "last_seen_room": "<room>",
      "last_seen_ticks_ago": <int>,
      "task_completions_observed": <int>
    }
  }
}
```

All timestamps are expressed as ticks-before-the-meeting rather than absolute
ticks so the LLM doesn't need to reason about the tick counter.

**Expected LLM response:**

```json
{
  "suspects": [
    {
      "color": "<color>",
      "likelihood": 0.0–1.0,
      "reasoning": "<one sentence>"
    }
  ],
  "confidence": "high" | "medium" | "low",
  "key_evidence": ["<short string>", ...]
}
```

`suspects` must be sorted by `likelihood` descending. Every living player must
appear. `confidence` maps to likelihood thresholds:

| Confidence | Criteria |
|---|---|
| `high` | top suspect likelihood ≥ `LlmAccuseThreshold` (default 0.75) |
| `medium` | top suspect likelihood ≥ 0.45 |
| `low` | top suspect likelihood < 0.45 or insufficient evidence |

**On result arrival:** store in `LlmVotingState.hypothesis`. Transition:
- confidence `high` → `Accusing`
- confidence `medium` or `low` → `Listening`

**On timeout or error:** transition to `Listening` with empty hypothesis.
`evidenceBasedSuspect` provides the fallback vote target if `VOTING` is reached
with no LLM hypothesis.

---

### 3.2 Stage 2 — Initial accusation (crewmate, high confidence only)

**Trigger:** Stage transitions to `Accusing`.

**Action:** Dispatch a second async LLM call to generate a chat message. This
is intentionally a separate call from hypothesis formation so that the
hypothesis result can be used as input and so the two latencies don't compound.

**Context:**

```json
{
  "task": "accuse",
  "suspect": "<color>",
  "likelihood": 0.0–1.0,
  "key_evidence": ["<string>", ...]
}
```

**Expected response:**

```json
{
  "chat": "<accusation message, ≤ LlmMaxChatLen chars>"
}
```

The message should:
- Name the suspect by color.
- Cite at least one specific piece of evidence (room, timing, or behavior).
- Be phrased as a statement of belief, not a demand.
- Vary in phrasing across games (the LLM handles this naturally).

**On result:** queue `chat` via `ChatState.pendingChat`. Transition to
`Reacting` to listen for responses.

---

### 3.3 Stage 3 — Chat interaction loop

**Trigger:** New chat lines observed via `voting.visibleChatLines` while stage
is `Listening` or `Reacting`.

The bot maintains `LlmVotingState.chatHistory`: a seq of `(speaker_color_or_null, line)` tuples appended each frame as new lines appear. This is the running conversation transcript.

When new lines arrive:

1. Append them to `chatHistory`.
2. Check `LlmVotingState.lastReactionTick`. If fewer than
   `LlmChatReactionCooldownMs` have elapsed since the last reaction call,
   skip (rate limiting — do not hammer the LLM on every frame).
3. If cooling down has expired and the new lines contain a claim about a player
   (a name/color mention, or words like "sus", "was", "saw", "vent"):
   dispatch a belief-update call.

**Belief update context:**

```json
{
  "task": "react",
  "current_hypothesis": {
    "suspects": [...],
    "confidence": "..."
  },
  "chat_since_last_update": [
    {"speaker": "<color>" | null, "line": "<text>"},
    ...
  ],
  "my_prior_statements": ["<line>", ...]
}
```

**Expected response:**

```json
{
  "suspects": [...updated suspect list...],
  "confidence": "high" | "medium" | "low",
  "action": "speak" | "ask" | "silent",
  "chat": "<message or null>"
}
```

`action` semantics:

| Action | When to use |
|---|---|
| `speak` | A claim was made that you can directly support or challenge based on your memory |
| `ask` | You need more information before updating your belief — request it specifically |
| `silent` | Nothing actionable; don't contribute noise |

On result:
- Update `LlmVotingState.hypothesis` with the new `suspects` and `confidence`.
- If `action != "silent"` and `chat != null` and `ChatState.pendingChat == ""`:
  queue the message.
- Update `LlmVotingState.lastReactionTick`.

The `Reacting` stage loops until confidence hits `high` (→ `Voting`) or
`VoteListenTicks` elapses (→ `Voting` with whatever confidence is current).

---

### 3.4 Stage 4 — Vote and optional persuasion

**Trigger:** Either:
- `LlmVotingState.hypothesis.confidence == "high"` at any point after Stage 1.
- `bot.frameTick - VotingState.voteStartTick >= VoteListenTicks`.

**Action:**

1. Determine vote target:
   - If hypothesis is non-empty and top suspect likelihood ≥ `LlmVoteThreshold`
     (default 0.50): vote for `suspects[0].color`.
   - Otherwise: fall back to `evidenceBasedSuspect` result.
   - If `evidenceBasedSuspect` also yields no confident target: skip vote.

2. Write target to `LlmVotingState.voteTarget`. `decideVotingMask` reads this
   (when set) instead of calling `evidenceBasedSuspect` directly.

3. Optional persuasion message: if confidence is `high` and at least one
   other player has not yet voted (visible from `VotingState.voteSlots`),
   dispatch a short chat-generation call: "convince others to vote for
   `voteTarget` in one sentence." Queue on result if `pendingChat` is empty.

---

## 4. Imposter pipeline

The imposter uses the LLM for **full strategic reasoning** throughout the
voting phase — not just for phrasing a corroboration message, but for
deciding who to target, when to speak, how to deflect accusations, and
whether to speak at all.

The imposter knows who the other imposters are (`Identity.knownImposters`).
This is passed to the LLM as `safe_colors` — the word "imposter" never
appears in any context or generated text (see §5.3).

---

### 4.1 Stage 1 — Strategy formation

**Trigger:** Meeting start. Dispatch an async LLM call immediately, mirroring
the crewmate's hypothesis-formation call but with the imposter's perspective
and goals.

**Context:**

```json
{
  "task": "strategize",
  "safe_colors": ["<fellow imposter colors — must never be targeted>"],
  "self_color": "<color>",
  "living_players": ["<color>", ...],
  "my_location_history": [
    {"room": "<room>", "tick_relative": <int>},
    ...
  ],
  "bodies_this_round": [
    {"room": "<room>", "tick_relative": <int>, "near_players": ["<color>", ...]}
  ],
  "evidence_scores": {
    "<color>": {
      "near_body_count": <int>,
      "witnessed_kill": <bool>,
      "last_seen_room": "<room>",
      "task_completions_observed": <int>
    }
  },
  "prior_meetings": [
    {
      "ejected": "<color>" | null,
      "my_vote": "<color>" | "skip",
      "chat_summary": ["<line>", ...]
    }
  ],
  "my_prior_statements": ["<line>", ...]
}
```

**Expected LLM response:**

```json
{
  "best_target": "<color>",
  "strategy": "bandwagon" | "preemptive" | "deflect",
  "timing": "early" | "mid" | "late",
  "reasoning": "<one sentence — internal only, not emitted as chat>",
  "initial_chat": "<opening message or null>"
}
```

Field semantics:

| Field | Meaning |
|---|---|
| `best_target` | The non-safe crewmate most plausibly framed as suspicious. Must not be a `safe_colors` player. |
| `strategy` | `bandwagon` — wait for others to accuse, then pile on. `preemptive` — speak first with a fabricated accusation. `deflect` — the bot is already under suspicion; redirect attention away. |
| `timing` | When to make the first substantive statement. `early` = speak before most others; `mid` = after 2–3 others have spoken; `late` = wait until votes are visible. |
| `initial_chat` | Optional opening message to send immediately (e.g. a deflection, an alibi, or a preemptive accusation). `null` = stay silent initially. |

**On result arrival:** store in `LlmVotingState.imposterStrategy`. If
`strategy == "preemptive"` or `initial_chat` is non-null: transition to
`Accusing` and queue `initial_chat`. Otherwise transition to `Listening`.

**On timeout or error:** transition to `Listening`. Fall back to the
previous rule-based bandwagon logic (wait for `LlmBandwagonMinAccusers`
accusations against a non-imposter, then vote for that player silently).

---

### 4.2 Stage 2 — Reactive reasoning loop

**Trigger:** New chat lines arrive while stage is `Listening` or `Reacting`.

The imposter's reaction call is fundamentally different from the crewmate's
belief-update call. The crewmate is updating a suspicion hypothesis. The
imposter is deciding how to manipulate the conversation toward a desired
outcome while not arousing suspicion.

**Reaction context:**

```json
{
  "task": "imposter_react",
  "strategy": "<from Stage 1>",
  "best_target": "<color>",
  "safe_colors": ["<color>", ...],
  "self_color": "<color>",
  "my_location_history": [{"room": "<room>", "tick_relative": <int>}, ...],
  "bodies_this_round": [{"room": "<room>", "tick_relative": <int>}],
  "full_chat_log": [
    {"speaker": "<color>" | null, "line": "<text>", "tick_relative": <int>},
    ...
  ],
  "my_prior_statements": ["<line>", ...]
}
```

Note: `full_chat_log` contains the **complete** conversation so far
(not just lines since the last update). This is how Q-LLM8 is addressed:
the LLM sees every claim that has been made and must not contradict any of
them. See §5.3 for the system prompt instruction that enforces this.

**Expected response:**

```json
{
  "action": "corroborate" | "deflect" | "accuse" | "silent",
  "chat": "<message or null>",
  "reasoning": "<internal only>"
}
```

Action semantics:

| Action | When appropriate |
|---|---|
| `corroborate` | Another player has accused `best_target`; add supporting false evidence consistent with the chat log and own location history. |
| `deflect` | This bot or a `safe_colors` ally is being accused; redirect attention to `best_target` or cast doubt on the accuser's credibility. |
| `accuse` | Nobody has accused `best_target` yet and `timing` says it's time to speak; make a preemptive or early accusation. |
| `silent` | Nothing actionable; speaking now would draw attention or contradict an earlier statement. |

**On result:** if `action != "silent"` and `chat != null` and
`ChatState.pendingChat == ""`: queue the message. Update
`LlmVotingState.lastReactionTick`.

The `Reacting` stage loops until `VoteListenTicks` elapses.

---

### 4.3 Stage 3 — Vote

Vote for `imposterStrategy.best_target`.

If `best_target` is no longer a living player (was ejected earlier this
meeting, or died): use the rule-based fallback — vote for any non-safe
crewmate with the highest `nearBodyTicks` score, or skip.

If the strategy call timed out and there is no `best_target`: skip vote.
Voting randomly against an uninvestigated crewmate risks drawing attention
more than skipping.

---

## 5. Prompt architecture

### 5.1 System prompt (shared)

The system prompt is injected once per LLM call and frames the bot's character.
It is role-agnostic in its framing:

```
You are a player in a social deduction game. Players perform tasks on a
spaceship. One or more players are secretly saboteurs. When a body is found
or an emergency button is pressed, all players vote to eject someone.

Your job is to reason carefully about the evidence you have observed and
communicate naturally with other players. Be concise — chat messages should
be one or two sentences at most. Use specific evidence (who you saw where,
when) rather than vague accusations. Do not reveal that you are an AI.

Respond ONLY with valid JSON matching the schema provided in the user message.
Do not include any text outside the JSON object.
```

The final line is critical: structured output from the LLM must be parseable.
If the provider supports native structured-output / function-calling mode, use
that instead (see Q-LLM4).

### 5.2 Crewmate system prompt addendum

Appended to the system prompt when role is crewmate:

```
You are a crewmate — you are not a saboteur. Reason honestly. If you have
strong evidence against someone, say so clearly. If you are uncertain, say so
and ask others for information. Do not accuse randomly. Base every accusation
on something specific you observed.
```

### 5.3 Imposter system prompt addendum

Appended when role is imposter:

```
You are trying to avoid ejection and get an innocent player (your target)
ejected instead. You have a list of safe allies (safe_colors) who you must
never accuse, vote against, or take any action that would draw suspicion
toward them.

Your core constraints:
1. Every statement you make must be consistent with the full_chat_log you
   are given. Read every prior message carefully and do not contradict any
   claim that has already been made — by you or by anyone else — unless you
   are explicitly deflecting a false accusation against yourself.
2. Only claim to have seen or been somewhere that is in your location history.
   Do not fabricate locations.
3. Never name or hint at any safe_colors player as suspicious.
4. Sound like a natural player: vary phrasing, react to specific things others
   said, and don't over-explain.

When asked to strategize: assess the full situation and decide the best
target (a non-safe player who can be plausibly framed), the right strategy
(bandwagon, preemptive accusation, or deflection if you are under suspicion),
and the right timing.

When asked to react: choose the action (corroborate, deflect, accuse, or
stay silent) that best advances ejecting your target while keeping you safe.
Prioritize staying silent over speaking if you cannot say something consistent
with the chat log.
```

Note that "imposter" does not appear anywhere in the addendum. The player is
described as having "safe allies" and a "target." This framing is sufficient
for the LLM to reason strategically without using terminology that could leak
into generated chat.

### 5.4 Per-call task schemas

Each call type passes a JSON schema in the user message so the LLM knows the
exact output shape expected. With Q-LLM4 resolved to use provider structured
output / tool-use, these schemas are registered as tool definitions at the
provider level — the LLM is constrained to emit valid JSON matching the schema
server-side, not just instructed to do so via prompt.

The six task types and their output schemas:

**`hypothesis`** (crewmate Stage 1):
```json
{
  "suspects": [{"color": "string", "likelihood": "float 0-1", "reasoning": "string"}],
  "confidence": "high|medium|low",
  "key_evidence": ["string"]
}
```

**`accuse`** (crewmate Stage 2):
```json
{"chat": "string"}
```

**`react`** (crewmate Stage 3):
```json
{
  "suspects": [{"color": "string", "likelihood": "float 0-1", "reasoning": "string"}],
  "confidence": "high|medium|low",
  "action": "speak|ask|silent",
  "chat": "string|null"
}
```

**`strategize`** (imposter Stage 1):
```json
{
  "best_target": "string",
  "strategy": "bandwagon|preemptive|deflect",
  "timing": "early|mid|late",
  "reasoning": "string",
  "initial_chat": "string|null"
}
```

**`imposter_react`** (imposter Stage 2):
```json
{
  "action": "corroborate|deflect|accuse|silent",
  "chat": "string|null",
  "reasoning": "string"
}
```

**`persuade`** (crewmate Stage 4, optional):
```json
{"chat": "string"}
```

The `reasoning` fields in imposter responses are internal — they are recorded
in the `llm_decision` trace event but never emitted as chat.

---

## 6. Async call architecture

> **AMENDMENT (Sprint 4.1) — superseded by Python-side concurrency.**
> The original design called for a side-channel thread inside Nim
> (`Thread[LlmClient]` + `Channel[LlmRequest]`). The Sprint 1
> implementation deferred this in favour of letting the Python wrapper
> own all HTTP I/O ("Option B"): Nim exposes a single
> `LlmRequestSlot`, the Python wrapper polls it and dispatches.
> Sprint 4.1 then added a `ThreadPoolExecutor` on the Python side so
> N agents dispatch concurrently. The text below describes the
> original intent and remains useful as design rationale, but the
> implementation lives in
> `cogames/amongthem_policy.py:AmongThemPolicy._dispatch_llm` /
> `_gather_llm_futures` rather than in `llm.nim`.

The voting phase runs frame-by-frame. A synchronous HTTP call inside
`decideVotingMask` would freeze the control loop for the LLM's round-trip
latency (typically 200–2000 ms). This is unacceptable.

The solution is a **side-channel thread** that owns all LLM I/O:

```
Main thread (game loop)                 LLM thread
─────────────────────────               ─────────────────────
frame N: dispatch(context, callId)  →   enqueue call
frame N+1 … N+K: poll(callId)       ←   in-flight
frame N+K+1: result = poll(callId)  ←   result ready → dequeue
```

**Implementation sketch (`llm.nim`):**

```nim
type
  LlmCallId* = int
  LlmStatus* = enum lsPending, lsDone, lsError, lsTimeout

  LlmCall* = object
    id: LlmCallId
    status: LlmStatus
    responseJson: string       # raw JSON on lsDone
    errorMsg: string           # on lsError

  LlmClient* = object
    thread: Thread[LlmClient]
    requestQueue: Channel[LlmRequest]
    resultQueue: Channel[LlmCall]
    nextId: LlmCallId
    timeoutMs: int

proc dispatchLlmCall*(client: var LlmClient; contextJson: string): LlmCallId
proc pollLlmResult*(client: var LlmClient; id: LlmCallId): LlmCall
  # Returns call with lsPending if not yet done.
```

The thread reads from `requestQueue`, performs the HTTP call (using
`src/bitworld/ais/` provider wrappers — see note below), and posts to
`resultQueue`. The main thread polls `pollLlmResult` each frame and acts on
the result when `status == lsDone`.

**Provider wrappers (status):** `src/bitworld/ais/` contains `claude.nim`,
`openai.nim`, `gemini.nim`, `xai.nim`. The Sprint 5.3 implementation
chose to dispatch from Python instead — `_AnthropicController` and
`_OpenAIController` in `cogames/amongthem_policy.py`, selected via
`_build_llm_controller`. This avoided porting SigV4 signing into Nim.

**Selected provider: AWS Bedrock + `claude-sonnet-4-5-20250929-v1:0`**
(Q-LLM1 + Q-LLM6 resolved). Implemented via
`anthropic.AnthropicBedrock` in the Python wrapper, which uses the
standard boto3 credential chain (`AWS_PROFILE`, `AWS_REGION`,
`AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`, IAM role env vars).
`CLAUDE_CODE_USE_BEDROCK=1` forces Bedrock even when an Anthropic API
key is present. Direct `anthropic.Anthropic` API is the fallback.
OpenAI fallback (Sprint 5.3) is structural — turn on via
`OPENAI_API_KEY` + `MODTALKS_PROVIDER_OPENAI=1` once the credentials
are available.

---

## 7. New types

### 7.1 `LlmVotingStage`

```nim
# types.nim
type
  LlmVotingStage* = enum
    lvsIdle,                # not in a meeting
    lvsFormingHypothesis,   # crewmate: first LLM call in flight
    lvsFormingStrategy,     # imposter: strategy call in flight
    lvsListening,           # waiting; no LLM call in flight
    lvsAccusing,            # accusation/preemptive chat call in flight or just sent
    lvsReacting,            # reaction loop; 0 or 1 calls in flight
    lvsVoting               # vote decided; done with LLM for this meeting
```

### 7.2 `LlmSuspect`

```nim
type
  LlmSuspect* = object
    colorIndex*: int
    likelihood*: float32
    reasoning*: string
```

### 7.3 `LlmHypothesis`

```nim
type
  LlmHypothesis* = object
    suspects*: seq[LlmSuspect]     # sorted by likelihood desc
    confidence*: string            # "high" | "medium" | "low"
    keyEvidence*: seq[string]
    valid*: bool                   # false = no hypothesis yet or error
```

### 7.4 `LlmChatEntry`

```nim
type
  LlmChatEntry* = object
    speakerColorIndex*: int   # color index; -1 only if attribution fails on a specific line
    line*: string
    tickObserved*: int
```

Speaker attribution is a prerequisite for the LLM integration (Q-LLM9
resolved), so `-1` should be rare — only a fallback for lines where the pip
pixel is ambiguous, not the normal case.

### 7.5 `LlmVotingState`

```nim
type
  LlmImposterStrategy* = object
    bestTarget*: int       # color index; -1 = not set
    strategy*: string      # "bandwagon" | "preemptive" | "deflect"
    timing*: string        # "early" | "mid" | "late"
    valid*: bool

  LlmVotingState* = object
    stage*: LlmVotingStage
    # Crewmate fields
    hypothesis*: LlmHypothesis
    # Imposter fields
    imposterStrategy*: LlmImposterStrategy
    # Shared
    voteTarget*: int            # color index; -1 = not decided / skip
    chatHistory*: seq[LlmChatEntry]
    myStatements*: seq[string]  # lines this bot queued this meeting
    pendingCallId*: LlmCallId   # -1 = no call in flight
    lastReactionTick*: int
    # Call frequency is governed solely by LlmChatReactionCooldownMs —
    # there is no per-meeting hard cap (Q-LLM7 resolved).
```

Added to `Bot` alongside `VotingState`:

```nim
# types.nim — Bot object
llmVoting*: LlmVotingState
```

### 7.6 `LlmConfig` — superseded by env-var configuration

The original plan was a Nim-side `LlmConfig` carrying provider /
model / credentials. That never landed: the Python wrapper owns
provider selection end-to-end (Sprint 5.3
`_build_llm_controller`), and the Nim side doesn't actually need to
know which provider answered the call. The actual `LlmState` shape
that shipped:

```nim
# types.nim — see actual definition for full doc
type
  LlmSessionCounters* = object  # process-lifetime tally
    totalDispatched*, totalCompleted*, totalErrored*: int
    totalFallbacks*, totalChatQueued*: int
    byKindDispatched*, byKindCompleted*, byKindErrored*:
      array[LlmCallKind, int]

  LlmMock* = object             # Sprint 3.1 — scripted-response queue
    enabled*: bool
    entries*: seq[LlmMockEntry]
    cursor*, mismatchCount*: int

  LlmState* = object
    counters*: LlmSessionCounters
    layerActiveAckTick*: int    # tick when modulabot_enable_llm fired
    mock*: LlmMock              # zero-cost when `mock.enabled = false`

# Bot field:
llm*: LlmState
```

Provider lineage now lives in the trace manifest's `harness_meta`
(Sprint 5.3): `llm_provider`, `llm_model`, `llm_persuade`,
`llm_disabled`. The launcher
(`scripts/launch_mod_talks_llm_local.py`) auto-stamps these so the
prompt-eval harness can group runs by configuration.

---

## 8. Integration points in existing modules

> Original design table follows. The as-shipped table is in
> `DESIGN.md §14.5`. Where they disagree, `DESIGN.md §14.5` is
> authoritative. The mismatches are mostly in `bot.nim` (the
> "starts the side-channel thread" step never landed because
> Sprint 4.1 moved concurrency to Python) and the new types
> added in Sprint 2-5 (`VoteChatLine`, `SelfKeyframe`, `LlmMock`,
> `LlmRequestSlot`, `LlmSessionCounters`).

| Module | Change |
|---|---|
| `types.nim` | Add `LlmVotingStage`, `LlmSuspect`, `LlmHypothesis`, `LlmChatEntry`, `LlmVotingState`, `LlmConfig`, `LlmState` to the Bot composition |
| `voting.nim` | In `decideVotingMask`: if `when defined(modTalksLlm)` and `bot.llmVoting.voteTarget >= 0`, use `llmVoting.voteTarget` as the cursor target instead of `evidenceBasedSuspect`. In the voting entry path: call `llmVoting.onMeetingStart(bot)` to trigger Stage 1. Each frame: call `llmVoting.tick(bot)` to advance the state machine (dispatch calls, poll results, queue chat). |
| `chat.nim` | No change to existing procs. `llm.nim` queues messages through `ChatState.pendingChat` via the existing `queueChat` path. Add a guard: if `pendingChat != ""` do not overwrite — the LLM layer must check this before queuing. |
| `bot.nim` | In `resetRoundState`: call `initLlmVotingState(bot.llmVoting)` to clear meeting state. In `initBot`: call `initLlmState(bot.llm, config)` which starts the side-channel thread. |
| `evidence.nim` | `evidenceBasedSuspect` is unchanged. It is called as a fallback when `llmVoting.voteTarget == -1`. |
| `tuning.nim` | Add: `LlmAccuseThreshold`, `LlmVoteThreshold`, `LlmChatReactionCooldownMs`, `LlmMaxChatLen`. No per-meeting call cap (Q-LLM7). `LlmBandwagonMinAccusers` removed — bandwagon detection is now handled by the LLM strategy call. |
| `tuning_snapshot.nim` | Add entries for all new LLM tuning knobs so they appear in the trace manifest. |
| `trace.nim` | Add `llm_decision` event type: `{call_type, stage, result_confidence, latency_ms, fallback, context_hash}`. Emit on each `lsDone` or fallback transition. |
| `llm.nim` (new) | Full implementation: context assembly, thread management, HTTP dispatch, response parsing, error handling. See §6. |

---

## 9. Timing analysis

The voting screen is visible for approximately `VotingScreenDurationTicks` ≈
300 ticks at 24 fps (about 12.5 seconds). `VoteListenTicks = 100` (about 4
seconds) is how long the current rule-based bot waits before pressing A.

The LLM pipeline must complete its key decisions within this window:

| Stage | Target latency | Notes |
|---|---|---|
| Hypothesis formation (Stage 1) | < 2 000 ms | Dispatched on meeting-start frame; result should arrive before the 4-second listening window closes |
| Accusation chat gen (Stage 2) | < 1 000 ms | Short prompt; follows immediately after Stage 1 result |
| Reaction call (Stage 3, per update) | < 1 500 ms | Rate-limited; at most one call per `LlmChatReactionCooldownMs` (default 2 000 ms) |
| Vote persuasion (Stage 4) | < 1 000 ms | Optional; dispatched only if confidence is high and time permits |

If the hypothesis call has not returned by the time `VoteListenTicks` elapses,
the bot falls back to `evidenceBasedSuspect` immediately — it does not wait for
the LLM. The call result is discarded.

**Call frequency:** There is no per-meeting hard cap on LLM calls (Q-LLM7
resolved). Call frequency is governed entirely by `LlmChatReactionCooldownMs`
(default 2 000 ms). At this rate, approximately 3–4 reaction calls fit within
a 12-second voting window — one hypothesis/strategy call plus 2–3 reactions.
The imposter's strategy call fires at the same time as the crewmate's
hypothesis call, so both roles have a similar call budget in practice.

---

## 10. Failure modes and fallbacks

| Failure | Detection | Fallback |
|---|---|---|
| Hypothesis call timeout | `pollLlmResult` returns `lsTimeout` | Stage → `Listening`; vote = `evidenceBasedSuspect` at `VoteListenTicks` |
| Hypothesis call HTTP error | `lsError` | Same as timeout |
| Response JSON parse error | `json.parseJson` throws | Log `llm_error` trace event; treat as timeout fallback |
| `suspects` list missing living players | Validation | Discard response; fallback |
| Vote target color not in living players | Validation | Discard `voteTarget`; use `evidenceBasedSuspect` |
| Chat message exceeds `LlmMaxChatLen` | Validation | Truncate at word boundary |
| Chat message is empty string | Validation | Do not queue; log |
| Side-channel thread crashes | Thread join check at `decideVotingMask` entry | Disable LLM for the rest of the session; log |
| `LlmEnabled = false` at compile time | `when defined(modTalksLlm)` | All LLM paths dead-coded out; identical to modulabot |

---

## 11. Parity and regression testing — shipped (Sprint 3)

The `-d:modTalksLlm` compile flag is the primary regression guard:
without it, the binary is bit-for-bit modulabot. `test/parity.nim`
verifies this on every commit; parity 500/500 across seeds
{1, 42, 100, 7777}.

The Sprint 3 mock-LLM harness adds three more matrices on top of
that baseline. All four are exercised by `tools/trace_smoke.sh`
and individually runnable:

1. **Mock LLM CLI flag.** `--llm-mock:PATH` on `modulabot.nim`
   loads a JSONL fixture (`{"kind", "response", "errored"}` per
   line) into `bot.llm.mock`. `tickLlmVoting` calls
   `llmMockPump` after dispatch, which delivers entries to
   `onLlmResponse` in strict FIFO. Bypasses Python and the live
   provider entirely. Implementation in `llm.nim:llmMockEnable` /
   `llmMockPump`.

2. **Parity harness `--llm-mock:PATH`.** `test/parity.nim` loads
   the same fixture into both bot instances. They consume entries
   in lockstep; masks must match frame-for-frame. Verified
   500/500 across seeds {1, 42, 100, 7777} on
   `test/fixtures/llm_mock_basic.jsonl`.

3. **Fallback parity.** Every entry in
   `test/fixtures/llm_mock_all_errored.jsonl` is errored; the
   resulting masks must equal the non-LLM baseline (rule-based
   fallback path). Verified 500/500 across the same seed set.

4. **Trace validation.** `test/validate_trace.nim` accepts the
   schema-v3 LLM event family (`llm_dispatched`, `llm_decision`,
   `llm_error`, `llm_layer_active`) and the new manifest fields
   (`trace_settings.llm_compiled_in` / `.llm_layer_active`,
   `summary_counters.llm`).

5. **Unit tests.** `test/llm_unit.nim` (Sprint 3.3) — 56 tests
   covering pure helpers, mock loader, trim policy, response
   parsers, and the new `transliterateAscii` (Sprint 4.5). Run
   with `nim r -d:modTalksLlm test/llm_unit.nim`.

---

## 12. Open questions (Q-LLM*) — closed

All nine questions resolved on 2026-04-30 (design Q&A) and shipped
through Sprints 1-5. This table is the historical record; the table
*Resolution* column reflects what actually shipped, not what was
proposed at design time.

| # | Question | Resolution (as shipped) | Where in code |
|---|---|---|---|
| Q-LLM1 | Provider and model? | **AWS Bedrock via `anthropic.AnthropicBedrock`**, model `global.anthropic.claude-sonnet-4-5-20250929-v1:0`. Direct Anthropic API is the fallback. OpenAI fallback added in Sprint 5.3 (structural only — needs creds for live verification). | `cogames/amongthem_policy.py:_AnthropicController._init_client`, `_OpenAIController`, `_build_llm_controller` |
| Q-LLM2 | Side-channel thread vs. `asyncdispatch`? | **Neither — Python-side ThreadPoolExecutor** (Sprint 4.1). Nim has a single `LlmRequestSlot`; the Python wrapper polls it and dispatches concurrent futures. | `cogames/amongthem_policy.py:AmongThemPolicy._executor`, `_dispatch_llm`, `_gather_llm_futures` |
| Q-LLM3 | Timeout budget for hypothesis/strategy call? | **20 s for forming-stage calls, 15 s for react, 10 s for accuse/persuade** (Sprint 4.2). Per-kind table; was originally a flat 2 s budget but provider latency made the tighter budgets unrealistic. | `cogames/amongthem_policy.py:PER_KIND_TIMEOUT_SECONDS` |
| Q-LLM4 | Structured output vs. post-parse validation? | **Anthropic tool-use** (Sprint 4.3) with one tool per `LlmCallKind`. Schema-in-prompt path retained as fallback for unknown kinds and tool-use responses missing the expected block. | `cogames/amongthem_policy.py:_LLM_TOOL_DEFINITIONS`, `_AnthropicController.complete` |
| Q-LLM5 | Imposter LLM scope — corroboration only or full strategic reasoning? | **Full strategic reasoning.** The imposter uses the LLM for `strategize` (target / strategy / timing / opening chat) plus `imposter_react` (corroborate / deflect / accuse / silent each turn). | `llm.nim:buildStrategizeContext`, `buildImposterReactContext`, `applyStrategizeResponse` |
| Q-LLM6 | API key / credential management? | **boto3 credential chain.** `AnthropicBedrock` reads `AWS_PROFILE` / `AWS_REGION` / env-var creds / `~/.aws/credentials` automatically. `CLAUDE_CODE_USE_BEDROCK=1` forces Bedrock when both Anthropic and AWS creds are present. | `cogames/amongthem_policy.py:_AnthropicController._init_client` |
| Q-LLM7 | Per-meeting call budget cap? | **No hard cap.** Call frequency governed by `LlmChatReactionCooldownTicks`. | `llm.nim:tickLlmVoting` |
| Q-LLM8 | Prevent imposter from contradicting witnessed events? | **`full_chat_log` in every `imposter_react` context** plus system-prompt instructions to read every prior message and stay silent if no consistent claim is possible. | `llm.nim:buildImposterReactContext`, `cogames/amongthem_policy.py:_SYSTEM_PROMPT_IMPOSTER` |
| Q-LLM9 | Speaker attribution as prerequisite? | **Implemented Sprint 2.1, after the rest of the LLM layer landed.** Plan said "first"; reality was Sprint 1 shipped without it and Sprint 2.1 added it once the integration was running. | `voting.detectChatSpeaker`, `LlmChatEntry.speakerColor` |

# Learnings — LLM Agents for Persephone's Escape

Notes from the process of getting LLM-driven bots to actually win a match of
Persephone's Escape (a Two Rooms and a Boom variant). The final working setup
is a task-list / event-buffer architecture; the first three architectures
failed in instructive ways.

## The goal

Three LLM bots (Claude Haiku) placed on the same team (Shades), sharing a
room with three dumb random-walk "smart bots". Win condition is Hades
mutually role-exchanging with Cerberus inside a chatroom. Since all LLM bots
are on TeamA, the two key roles are always LLMs, and the grunt LLM just
needs to stay out of the way.

Everything connects over a 128×128 4-bit pixel framebuffer delivered via
websocket. The LLM does not see sim state directly — it sees what the client
sees. Input is a byte of button masks per frame at 24 fps.

## Architectures tried (in order)

### 1. One-shot command per tick

> "Here's the game state. Reply with exactly one command like `move_to 50 50`
> or `role_offer`."

Failed because:
- LLM round-trip is ~500–1500 ms, far longer than one tick (~42 ms).
- The bot spends most of its life waiting for the next LLM response. During
  that time no button is pressed → the character stands still or drifts.
- The LLM can't plan: it has no persistent state, every call is a fresh
  decision based on a single snapshot. Decisions flip-flop.

### 2. Policy object (persistent flags)

> "Emit a JSON object with flags like `autoGrantEntry: true`,
> `pursueColorOrder: [7, 10]`. The bot applies them every frame until you
> change them."

Better. The executor ran continuously, interpreting the flags. But:
- The flag surface grew to ~10 booleans + arrays, and their *interactions*
  were hard to reason about ("if `autoOfferRole` is true but
  `autoAcceptRoleOffer` is false, and I'm in a chatroom, and pending_role_offer
  just flipped to true...").
- One-shot flags (`autoOfferColor: true` fires once then clears) were
  conceptually weird — the LLM didn't know whether its flag was still armed
  or had already fired.
- No way to express "walk to (10, 10), then once there do X". The LLM
  squeezed everything into disconnected flags.

### 3. Task list with append / prepend / cancel

> "Emit an ordered task list. Each task kind has its own lifecycle (ONCE /
> SEQUENCE / LOOP). You can prepend urgent work or cancel the current task."

Close. Problems:
- `prepend` / `cancel` put too much burden on the LLM to reason about
  ordering ("If I prepend this, does the currently-running task get
  cancelled? Does it pause and resume?"). Users (well, Kyle) pushed back:
  *"too much thinking required"*.
- ID-tracking per task felt unnecessary. Tasks are short-lived enough that
  `kind + params` is a usable identifier.

### 4. Task list with only `append` + `clear` ⭐ (working)

> "Emit `{ clear: 'non_loop', append: [tasks...] }`. Tasks run top-to-bottom,
> self-terminate on done/fail/timeout, loops are singletons per kind."

Clean surface. The LLM just picks the next 1–3 things to do, optionally
wiping ONCE/SEQUENCE work while keeping its background loops.

## Things that made it click

### Task categories

- **ONCE**: `shout`, `chat`, `exit_chatroom`. Fires one action then removes
  itself.
- **SEQUENCE**: `walk_to`, `pursue_chat`, `pursue_exchange`. Multi-frame,
  self-terminates on success / failure / timeout. Owns internal state (e.g.
  "did I create my own chatroom or request entry?").
- **LOOP**: `loop_auto_grant`, `loop_auto_accept_role`,
  `loop_auto_accept_color`, `loop_read_global`. Singleton per kind —
  appending a new one replaces the old. These cover reactive behaviors that
  should "always be on once armed".

### Phase routing lives in the executor, not the LLM

- Chatroom tasks auto-skip in overworld; movement tasks auto-skip in
  chatroom; nothing runs during `waiting_entry`. The LLM can append
  whatever, the executor does the right thing at the right time.
- This collapses a huge surface of "oh I forgot to check phase" bugs.

### High-level sequences dominate over low-level commands

`pursue_exchange { targetColor, exchange: "role" | "color", timeLimitTicks }`
handles the whole pipeline: walk → chatroom → offer → auto-accept. The LLM
doesn't need to micromanage `approach`, `open_chatroom`, `offer_color`,
`accept_color`, `offer_role`, `accept_role`. It just says *"go exchange
roles with color 7"*.

### Structured event buffer

Every frame, task lifecycle events (`started`, `fired`, `succeeded`,
`failed`, `replaced`) are pushed to a buffer. The buffer is included in the
next LLM prompt, then flushed. This matters because:

- The LLM only sees a snapshot at prompt time; without event history, it
  can't tell whether a task from its previous response ran or got dropped.
- It dramatically reduces the LLM's tendency to re-queue already-completed
  work.
- It catches cases where a task *fails* silently (timeout, precondition
  false). The LLM sees the failure and can pivot.

### A stupid meetup protocol beats sophisticated pursuit

The minimap has fog-of-war and rasterises ~5 world units per cell. When
two players are very close, the viewer's own dot overwrites theirs, so the
target appears to vanish. Trying to chase each other was unreliable.

Workaround: each LLM shouts a fixed meetup coordinate like `"meet at 50
50"`. All teammates set `walk_to(50, 50)` + `pursue_exchange(partnerColor,
"role")`. Whoever arrives first creates a chatroom. Others arriving press
A, request entry, get auto-granted by the `loop_auto_grant` loop. Once
inside, the role-offer dance plays out. Five frames of A-presses beats
trying to solve fog-of-war-aware pursuit.

## Things I got wrong and had to fix

### Minimap self-dot overwrites other players

The minimap draws the viewer's dot LAST, so it covers any other player on
the same cell. `pursue_chat` checks `minimapDots.find(color === target)` —
fails when you're literally on top of them.

Fix: track `lastSawTargetTick` inside the task. If target isn't visible but
was seen in the last 12 ticks, press A anyway (we're probably overlapping
them).

### Pending-entry indicator was clobbered by the chatroom renderer

The renderer drew "! [sprite] WANTS IN" at the top of the chatroom message
area, then drew the chat messages last — overwriting the indicator. Parsers
saw no color-8 pixels, concluded no pending entry, `loop_auto_grant` never
fired.

Fix: draw pending-entry indicator *after* messages in `renderChatroomView`.

### Chatroom menu B-button is a toggle

`chatMenuSequence` always starts with B to open the menu. If the menu was
already open (e.g. from a half-run prior sequence), the first B closes it
and the rest of the sequence misfires into world-movement. Sequences have
to assume the menu starts closed and leave it closed. The executor drains
the entire action queue one-frame-at-a-time; nothing else can inject
between sequence frames, so once we're careful about the precondition it
holds.

### `pursue_chat`'s "created my own chatroom" flag mislabeled join-via-request

Pressing A near someone in a chatroom *requests* entry; pressing A alone
creates a new chatroom. Both code paths went through the same task
transition. If the task set `createdOwnChatroomTick` but the sim actually
treated the press as a request, the task would later exit an innocent
chatroom (thinking the target "didn't show up").

Fix: observe the `waiting_entry` phase. If we entered that phase after
pressing A, we requested entry — clear the `createdOwnChatroomTick` flag.

### `pursue_exchange` reports success by timeout

The task currently fires `done("offer completed (timeout-success)")` 30
ticks after sending its offer, regardless of whether the exchange actually
happened. That meant the event log showed `succeeded` even when the LLM
hadn't won — I saw the LLM prompt-text confidently claim "victory
achieved" while sim reported no winner.

Sim ground truth is either a `sharedWith` set entry, a "roles exchanged!"
system message, or the offer clearing from both sides. This still needs to
be replaced with a real signal. (Tracked as follow-up.)

### Team-biased role assignment is the only way for LLMs to reliably be
the key pair

With random role assignment in a 6-player game, the probability that both
key roles for a team land on LLM-controlled players is low. Without
symmetric cooperation mechanics, the test is almost unwinnable — not for
the reason you think (LLM is bad), but because the smart-bot random walk
can't complete a role exchange at all. Patching `assignRoles` to bias
LLM-prefixed names onto TeamA first made wins possible.

### No obstacles for the easy config

The default obstacle layout creates narrow corridors which the naive
`moveToward(dx, dy)` movement gets pinned against. `obstacleCount: 0` in
the test config removes that variable while debugging the agent layer.

### Grouping LLMs in the same room

Random room assignment meant the Hades LLM and Cerberus LLM often started
in different rooms (cross-room exchange is impossible within a single
round). `groupNamePrefixInRoomA: "llm_"` puts all LLM-prefixed players in
RoomA, so they're always mutually reachable.

## Debug infrastructure that paid off

- `debug_tasks.ts` / `debug_policy_flow.ts` / `debug_chatmenu.ts`: real Sim,
  real renderer, real frame parser, no LLM. Drives two players through the
  end-to-end flow and asserts `sharedWith` at the end. Catches all the
  non-LLM bugs (menu sequence, chatroom entry grant flow, R.OFFER wiring,
  pending-entry detection) in seconds. Way more useful than any unit test.

- Frame-dump debugging for parser bugs. Rendered a known sim state, dumped
  raw pixel values by row/column, then manually traced OCR failures. E.g.
  discovered `fb.drawText("#", ...)` silently drops the character because
  `#` isn't in the font.

- White-box observability in the task layer: every task returns a
  `{ kind, reason? }` result that flows into the event log. When a task
  fails, the reason explains *why* — makes the event buffer self-debugging.

## Things I'd do differently next time

- **Build the deterministic integration test FIRST**, before the LLM-in-the-loop
  test. The integration test found 90% of the bugs in seconds; every bug
  I tried to find in a live LLM game took 2+ minutes (the round-trip of a
  60-second match) and was noisier.

- **Don't trust the LLM's self-narration**. The LLM-facing event log must
  reflect ground truth, not the task's optimistic guesses. A task that
  *thinks* it succeeded but the sim disagrees will confidently lie in the
  next prompt.

- **Keep the LLM's action surface tiny**. My first "commands" list had ~15
  verbs; the final task vocabulary has 8 kinds. The more primitives, the
  more ways the LLM finds to get stuck.

- **Exploit that agents are symmetric when it's useful**. Meet-at-a-point
  plus `pursue_exchange` sidesteps the hardest coordination problem
  (finding each other) by letting the environment do the work.

- **The sim-level `autoGrantChatroomEntry` flag could be a default-on test
  config knob**. The grant-dance is rich social-deduction content for
  humans but mostly a coordination tax for LLMs. A flag to skip it would
  make the easy-mode config much more forgiving.

## What actually won a game

A single LLM bot (Cerberus, TeamA Shades) emitted something like:

```json
{
  "append": [
    { "kind": "loop_auto_grant" },
    { "kind": "loop_auto_accept_role" },
    { "kind": "loop_read_global", "intervalTicks": 72 },
    { "kind": "shout", "text": "llm team meet at 50 50" },
    { "kind": "walk_to", "x": 50, "y": 50, "timeLimitTicks": 240 },
    { "kind": "pursue_exchange", "targetColor": 9, "exchange": "role", "timeLimitTicks": 720 }
  ]
}
```

Hades did approximately the same thing with its own target color. They
converged near (50, 50), one created a chatroom, the other requested
entry, `loop_auto_grant` fired, both sent `R.OFFER` via the
`pursue_exchange` pipeline, `loop_auto_accept_role` fired on whichever
side received the offer first, and the sim recorded `sharedWith`. Global
viewer displayed "SHADES WIN!" and "Hades found Cerberus".

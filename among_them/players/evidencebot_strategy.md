# EvidenceBot Strategy

This document describes the strategy implemented by `evidencebot.nim` and
the changes layered on top by `evidencebot_v2.nim`. Both bots share the
same perception stack and policy skeleton; v2 differs from v1 only in the
crewmate task-handling pipeline.

The bot is *vision-only*: it receives raw 128×128 4-bit framebuffers from
the server over WebSocket and emits NES-style button masks. There is no
training and no privileged game-state access — every decision is
recovered from pixels plus the static map definition (loaded once from
the same JSON file the server uses).

---

## 1. Architecture

Per-frame pipeline (`decideNextMask`, `evidencebot.nim:3769`):

1. `updateLocation` — interstitial / voting detection, sprite scans,
   camera localization
2. `updateMotionState` — measure velocity from camera deltas
3. `rememberVisibleMap`, `updateTaskGuesses`, `updateTaskIcons` — refresh
   world model
4. `updateEvidence` — stamp witness ticks for visible crewmates near
   bodies
5. `rememberHome` — record initial spawn for the round
6. Branch on role / state into a behaviour policy that returns a button
   mask

The "intelligence" comes entirely from precise computer vision of the
rendered screen plus the static map data.

### What the bot knows for free

Loaded from the map JSON via `initSimServer` (`evidencebot.nim:3918`,
backed by `sim.nim:566`):

- Every task station's world rectangle, name, and centre
  (`bot.sim.tasks`).
- Every walkable / wall pixel — used by A\*.
- Every room's bounding rect and name (used for `body in <room>`
  chat).
- The emergency button rectangle, the home point, the vents list.

### What the bot has to recover from pixels

- Where the camera is on the map (`updateLocation`).
- Which tasks are assigned to *this* player (icon scanning).
- Which tasks are still incomplete (icons + radar dots).
- Other players' colours, positions, alive / dead status.
- Voting screen state (cursor, slots, votes cast, chat content).

---

## 2. Perception

### Camera localization

Three tiers, ordered by cost:

- **Local frame search** (`locateNearFrame`, `:1125`) — score camera
  offsets within `LocalFrameSearchRadius = 8` of the last known camera by
  counting pixel mismatches against the precomputed map (`scoreCamera`,
  `:642`). Cheap and sticky.
- **Patch-hash global search** (`locateByPatches`, `:799`) — at startup
  the entire map is hashed into 8×8 patch fingerprints
  (`buildPatchEntries`, `:706`); each frame's 8×8 patches vote for camera
  offsets that match. Top candidates are full-scored.
- **Spiral fallback** (`locateByFrame`, `:1157`) — full spiral search
  around the last / button position if patch voting fails.

Acceptance gate: `errors <= maxErrors AND compared >= FrameFitMinCompared`
(`:844`). Dynamic pixels (other crewmates, bodies, the kill button, radar
dots, the player's own sprite) are masked out before scoring
(`ignoreFramePixel`, `:623`) so they don't poison localization.

### Sprite scanning

Each frame the bot scans for:

- **Crewmates** (`scanCrewmates`, `:1582`) — sliding-window match on the
  player sprite tinted with each colour, both flipped and unflipped.
- **The bot's own colour** (`updateSelfColor`, `:1601`) by reading the
  centred player sprite.
- **Bodies** (`scanBodies`, `:2016`) and **ghosts** (`scanGhosts`,
  `:2040`).
- **Task icons** floating above stations (`scanTaskIcons`, `:2066`) at
  expected screen positions derived from the camera lock.
- **HUD role icons** — kill button lit / dim → imposter (`updateRole`,
  `:1412`); ghost icon → ghost.
- **Radar dots** (`scanRadarDots`, `:1326`) on the screen periphery; each
  task's offscreen direction is back-projected to the screen edge
  (`projectedRadarDot`, `:2085`) and matched to dots within
  `RadarMatchTolerance = 2` pixels.

### Voting screen

`parseVotingScreen` (`:1995`) detects the meeting UI by trying every
plausible player count and validating the SKIP label, then parses each
cell's sprite, the cursor outline, the local-player marker, voter dots
per target, and the chat panel. ASCII glyphs are matched against a
sprite atlas (`asciiGlyphScore`, `:882`). Chat text is scanned for
`<colour> ... sus` patterns (`chatSusColorIndex`, `:1912`).

### Task state model

Three signals merge into a per-task `TaskState`
(`updateTaskIcons`, `:2230`):

| State | How it gets set | How it gets cleared |
|---|---|---|
| `TaskNotDoing` | initial | — |
| `TaskMaybe` | radar dot matches the task's projection (`:2155`); also reverts from `TaskCompleted` if a radar dot hits it again | 24 consecutive clean-view frames with no icon (and no radar match, in v1) |
| `TaskMandatory` | task icon directly visible (`:2244`) | same 24-frame miss counter, OR completion verified after holding A |
| `TaskCompleted` | hold-A confirmed icon disappeared (`:3370`); OR Mandatory miss counter expired | radar dot rematches → flips back to `TaskMaybe` (v1 only; v2 latches resolved tasks) |

A parallel `checkoutTasks[]` boolean (`:370`, `:2154`) is sticky: it
records every task that has ever had a radar dot project onto it this
round.

---

## 3. Navigation

- **A\*** on the pixel-level walk mask (`findPath`, `:2464`) using
  Manhattan heuristic.
- **Lookahead waypoint** ~18 steps ahead (`PathLookahead`,
  `choosePathStep`, `:3305`).
- **Momentum-aware steering** (`axisMask`, `:3247`) — the agent models
  friction (`coastDistance`, `:3231`) and will *coast* (no input) or
  actively *brake* (push opposite) when current velocity will overshoot
  the target. A precise final-approach mode kicks in within
  `TaskPreciseApproachRadius = 12` pixels (`preciseAxisMask`, `:3267`).
- **Anti-stuck jiggle** (`updateMotionState` / `applyJiggle`, `:2286` /
  `:2320`) — if no movement registers for `StuckFrameThreshold = 8`
  frames despite directional input, a perpendicular nudge is added for
  `JiggleDuration = 16` ticks, alternating sides. Handles snags on
  doorframes.

---

## 4. Crewmate strategy

In `decideNextMask` (`:3811`) when role is crewmate and not ghost.

### Priority 1 — Report bodies

If any body is visible (`nearestBody`, `:2728`):

- Queue a chat line `body in <room>` (deduped via `sameBody`).
- If within report range and standing still → press A to report.
- Otherwise navigate toward the body.

### Priority 2 — Do tasks (`nearestTaskGoal`, `:3144`)

An eight-tier fallback chooses the closest reachable task:

1. Tasks whose icon is **currently visible** — definitively assigned,
   definitively here.
2. Sticky: the previously selected mandatory task, if still mandatory.
3. Any task in `TaskMandatory` state.
4. Sticky: previously selected task that's still in `checkoutTasks`.
5. Any non-completed `checkoutTasks` task.
6. Sticky: previously selected radar task.
7. Any current `radarTasks` task.
8. Fallback: home (cafeteria spawn) if nothing else is known.

Tiers 1–3 are reliable (icon evidence). Tiers 4–7 are speculation from
radar-dot projection.

When at the goal and stationary (`taskGoalReady`, `:3340`), the bot
holds A for `taskCompleteTicks + TaskHoldPadding = 8` ticks
(`holdTaskAction`, `:3356`), then verifies the icon disappeared before
marking `TaskCompleted`.

### Evidence collection (`updateEvidence`, `:2763`)

Two tiers of memory keyed by player colour:

| Tier | Field | Trigger |
|---|---|---|
| Weak | `nearBodyTicks[ci]` | crewmate `ci` visible within `WitnessNearBodyRadius = 2 × KillRange` of any visible body |
| Strong | `witnessedKillTicks[ci]` | same, but only at the frame the body **first appears** (no body within `SpriteSize²` last frame) |

A "new body" is a body sighting with no nearby body in
`prevVisibleBodies`. Bodies don't move, so a sudden appearance with a
player next to it indicates the killer.

### Voting (`desiredVotingTarget`, `:3040`)

This is the principle that gives the bot its name: **the crewmate vote
ignores chat entirely and only accuses on firsthand evidence.**

- `evidenceBasedSuspect` (`:2844`) returns the strongest tier (witnessed
  kill > near body); if none, `found = false` and the bot votes **skip**.
- Chat from `crewmateBodyMessage` (`:2924`) only appends `sus <colour>`
  when evidence exists.
- `VoteListenTicks = 100` ticks of waiting before pressing A so chat
  and vote panels can fully load.

Rationale (`:3046–3050`): "ignore chat entirely. Only vote for a player
when we have firsthand evidence ... Otherwise vote skip — staying
neutral is worth more than guessing, and immune to manipulation by an
imposter who chats first."

---

## 5. Imposter strategy

`decideImposterMask` (`:3558`), strict priority order:

### Priority 1 — Body in view

- **Self-report sub-case** (`:3601`): if `imposterLastKillTick` is within
  `ImposterSelfReportRecentTicks = 30` and the body's position matches
  `imposterLastKill{X,Y}` within `KillRange + 8`, and we're in report
  range and stationary → press A to report **our own kill**. The trick:
  `pendingChat` is already filled with a deflection
  (`body in X sus <random innocent>`); that chat fires first when the
  meeting opens, framing the imposter as the helpful finder.
- **Flee sub-case**: otherwise, pick the fake target *farthest* from the
  body (`farthestFakeTargetIndexFrom`, `:2683`) and route there. Cancels
  any active fake task.

### Priority 2 — Kill in range

If a *lone* non-teammate crewmate is visible (`loneVisibleCrewmate`,
`:2708`), kill button is lit, and target is in kill range → press A.
Records `imposterLastKill{Tick,X,Y}` and starts a fake-task cooldown so
the bot doesn't suspiciously start "tasking" right after killing.

### Priority 3 — Hunt lone crewmate

Same lone-crewmate condition but out of range → close in with a tight
`KillApproachRadius = 3` precise approach.

### Priority 4 — Continue active fake task

If `imposterFakeTaskUntilTick` is in the future, navigate to the task
centre; once within `TaskPreciseApproachRadius`, stand still and hold A.
The sim ignores the input from imposters but visually it looks identical
to crewmate task completion.

### Priority 5 — Follow a crewmate

`pickFolloweeColor` (`:3464`) tails one visible non-teammate:

- Stick with the same followee for at least
  `ImposterFollowSwapMinTicks = 240` ticks.
- When ≥2 crewmates are visible and the swap window has elapsed,
  randomly switch — prevents the giveaway "imposter glued to one
  player" pattern.
- Resume the same followee if they leave and return view.
- While following, occasionally roll the **fake-task die**
  (`maybeStartFakeTask`, `:3535`): only on the tick we *enter* a
  task's `ImposterFakeTaskNearRadius = 80` radius, with probability
  `1 / 12`, lasting `90–180` ticks, with a `240`-tick cooldown after.

### Priority 6 — Wander

No crewmate visible → pick a random "fake target" (any task or the
emergency button), with the same passing-by fake-task roll. If we
arrive, pick another. Produces wandering that visits real task
locations.

### Imposter chat (`imposterBodyMessage`, `:2915`)

On any body sighting, build `body in <room> sus <random innocent>`. The
random target is deliberately *not* the most-recently-seen colour
(likely the actual victim — naming them would tell on yourself). The
chat is queued in `pendingChat` so it sends as soon as voting opens.

### Imposter voting

- Bandwagon: if chat has named someone "sus", vote for them (blends in).
- Else vote for the most-recently-seen suspect.
- Else skip.

The imposter is deliberately *less* principled than the crewmate — it
weaponizes chat manipulation and herd voting precisely because the
crewmate logic ignores chat and stays neutral.

---

## 6. Ghost behaviour

When `isGhost` is true the bot still pursues task goals (relevant in
modes where ghosts complete tasks):

- Skips A\* and uses straight-line precise steering (`:3404–3409`).
- Uses Manhattan heuristic instead of A\* path length for goal selection
  (`goalDistance`, `:2526`).

---

## 7. State management

- **Round resets** (`resetRoundState`, `:1007`) — triggered by detecting
  `CREW WINS` / `IMPS WIN` ASCII text. Clears localization, role,
  evidence, fake-task state, body memory, voting, etc.
- **Role reveal** (`rememberRoleReveal`, `:1614`) — on the `IMPS`
  interstitial it scans visible crewmates and stamps them all into
  `knownImposters[]` so the imposter never targets or accuses
  teammates.
- **Home memory** (`rememberHome`, `:2383`) — the first reliable in-game
  position is remembered as a fallback rally point when nothing else is
  worth doing.

---

## 8. Strategy summary

Two distinct policies share one perception stack:

**As a crewmate the bot is principled and quiet.** It optimizes pure
task throughput, reports bodies it stumbles on, and votes only on
firsthand visual evidence. The thesis is that in a population of bots
that bandwagon on chat, an evidence-only voter is unmanipulable and
statistically correct more often than guessers.

**As an imposter the bot is theatrical and adversarial.** It exploits
exactly the chat-bandwagon weakness that its crewmate self refuses to
indulge: pre-loading deflection chat naming a random innocent,
self-reporting its own kills to look helpful, mimicking task completion
at random stations, swapping followees in groups to avoid the
lone-stalker tell, and avoiding "task right after kill" tells with
explicit cooldowns.

The asymmetry is the design: the crewmate is a hard target for
social-engineering bots, and the imposter is a social engineer.

---

## 9. v2 changes

v2 targets two distinct pathologies in v1:

**Crewmate task loitering.** Significant time was spent at task
stations that weren't the bot's own. Three causes, all in the crewmate
task pipeline:

- **Slow false-positive cleanup.** Dropping a wrong `checkoutTasks[]`
  flag required `TaskIconMissThreshold = 24` consecutive clean-view
  frames.
- **Radar dot ambiguity locking the cleanup.** The miss counter was
  gated on `not radarTasks[i]`. Ambiguous radar projection (multiple
  tasks lying along the same bearing) could keep re-flagging the wrong
  station as the player moved, perpetually resetting the counter.
- **No memory of what's already been ruled out.** Even after eventually
  clearing a flag, a later radar dot could re-flag the same wrong
  station and send the bot back.

**Imposter end-game orbit.** When all crewmates had finished tasks and
were standing in the cafeteria around the emergency button, the
imposter's follow loop could circle the same group of players
indefinitely. With ≥2 crewmates always in view the lone-crewmate kill
condition never fired, and the bot never tried to reset the situation
by leaving and forcing the group to fragment.

Changes 1–3 fix the first; change 4 fixes the second. None of the
perception, A\*, voting, or evidence logic is touched.

### Change 1 — eager checkout cleanup

`updateTaskIcons` (`evidencebot_v2.nim:2253`). When the inspection rect
is fully visible (`taskIconClearAreaVisible`) and **neither** strict nor
fuzzy icon match fires (`taskIconVisibleFor`, `taskIconMaybeVisibleFor`),
the speculative `checkoutTasks[i]` flag is dropped on the same frame
instead of waiting 24 frames. `TaskMandatory` cleanup still uses the
24-frame counter so a passing crewmate occluding the icon for a few
frames doesn't drop a real task to `TaskCompleted` prematurely.

### Change 2 — drop the radar gate on miss counting

Same proc. The `not bot.radarTasks[i]` gate is removed from the cleanup
condition. A radar dot still projecting onto a task no longer prevents
the bot from reaching cleanup. Removes the worst pathology in v1, where
ambiguous radar geometry could lock the bot at a wrong task indefinitely.

### Change 3 — `taskResolved[]` per-task latch

A new `seq[bool]` on `Bot` (`evidencebot_v2.nim:373–379`). Once set for
a task index, that station is treated as definitively resolved for the
round.

**Three triggers set the latch:**

1. **Eager not-mine confirmation** (`updateTaskIcons:2306`) — full
   inspection rect on screen, neither strict nor fuzzy icon match.
2. **Slow Mandatory→Completed transition** (`updateTaskIcons:2300`) —
   24-frame counter expires for a previously-Mandatory task.
3. **Successful task hold verification** (`holdTaskAction:3422`) —
   completed via the fast path (icon disappeared after
   `taskCompleteTicks` of holding A).

**One trigger clears the latch** (`updateTaskIcons:2294`):

- An icon genuinely renders again at the station. Real icons override
  the latch in case perception had a transient false negative.

**Latch is enforced in `updateTaskGuesses` (`:2161–2162`)** — resolved
tasks are skipped before any radar dot matching. They cannot be
re-flagged into `radarTasks[]` or `checkoutTasks[]`, and a
`TaskCompleted` state cannot be flipped back to `TaskMaybe`.

### Combined effect

- A station the bot drives past in clear view is logged as not-mine on
  the same frame and never re-evaluated.
- A station the bot completes is logged as done and never re-evaluated.
- The bot's effective task list shrinks monotonically through the round;
  in the limit, only genuine outstanding assignments remain candidates.

The `taskResolved[]` array is reset cleanly in `resetRoundState` so
each new round starts fresh, and is initialized in `initBot`.

### Change 4 — imposter central-room stuck detection

End-game gathers used to stall v1 indefinitely: when every crewmate had
finished tasks and was idling in the cafeteria around the emergency
button, the imposter's priority-5 follow loop would orbit the same
group forever. With ≥2 crewmates always in view, the lone-crewmate kill
condition could never fire, so the bot just rotated followees in place.

v2 adds:

- Two new `Bot` fields (`imposterCentralRoomTicks`,
  `imposterForceLeaveUntilTick`) tracking how long we've been idling in
  the central room with a crowd, and how long a forced-leave window is
  active.
- Three constants tuning the trigger and the duration:
  `ImposterCentralRoomStuckTicks = 360` (~12 s before a leave is
  forced), `ImposterCentralRoomLeaveTicks = 240` (~8 s leave window),
  `ImposterCentralRoomMinCrewmates = 2`.
- Three helpers near the existing `roomNameAt`: `centralRoomCenter`,
  `centralRoomName`, `inCentralRoom`. The central room is whichever
  room contains the emergency button.
- A counter at the top of `decideImposterMask`. Each frame it
  increments while the bot is in the central room and ≥2 non-teammate
  crewmates are visible; it resets the moment any condition breaks, or
  while the leave window is already active.
- A new **priority 4.5** between the existing fake-task continuation
  (4) and the follow loop (5). When the leave window is active, the
  imposter navigates to the fake target *farthest from the central
  room* and rides it out — so it actually leaves, instead of just
  picking another fake target that might be on the cafeteria's
  doorstep.

Triggering the leave also clears any active fake task, since a fake
task in the central room would defeat the purpose. Priorities 1–3
(body / kill / hunt) remain ahead of 4.5, so a real opportunity always
wins.

The interaction with the follow logic in priority 5 is naturally
self-limiting: the leave window expires, the bot returns, and if the
crowd hasn't dispersed the counter starts over. The bot oscillates
between "in the cafeteria with the crowd" and "wandering the map" —
which is also the period when a crewmate is most likely to peel off
alone, giving the imposter a real kill window.

---

## 10. File reference

| File | Purpose |
|---|---|
| `evidencebot.nim` | Original bot. Stable. |
| `evidencebot_v2.nim` | Same perception and policy, with the four improvements above. Crewmate task throughput should be measurably higher; the imposter no longer perma-orbits end-game gathers; voting / evidence behaviour is byte-identical to v1. |
| `evidencebot_strategy.md` | This document. |

Both bots compile to standalone binaries (CLI mode) or shared
libraries (the `evidencebotLibrary` define gates the FFI exports used
by the CoGames training harness). They are independent compile units;
there is no symbol collision between the two builds.

# Smart Bot for Among Them — Architecture & Build Plan

This guide describes how to build an LLM-augmented bot for BitWorld's Among Them
game, layering memory, strategic reasoning, and cross-game learning on top of the
existing `nottoodumb.nim` perception and navigation pipeline.

The core insight: `nottoodumb.nim` already solves the **hard visual problem** —
localization, task detection, navigation, voting UI parsing. What it lacks is
**strategic reasoning** — deception, social modeling, adaptive play, and learning
from experience. That is exactly what the CvC memory/brain architecture provides.

---

## Part 1 — What nottoodumb.nim Already Does Well

The existing bot is a ~4000-line Nim program that handles the entire visual-client
pipeline. Do not rewrite this. Build on top of it.

### Perception Pipeline (keep as-is)
- Receives 128×128 packed 4-bit framebuffer over WebSocket
- Unpacks to palette indices, detects interstitial screens (≥30% black pixels)
- Localizes camera via patch-hash voting + local temporal search + spiral fallback
- Masks dynamic pixels (players, bodies, ghosts, task icons, radar, kill icon)
- Scans for crewmates by stable sprite pixels + body tint
- Scans for dead bodies, ghosts, and task icons at expected positions
- Reads radar dots on screen periphery
- Parses voting screen: player slots, cursor, self marker, vote dots, chat text
- Reads ASCII text for interstitials (CREW WINS, IMPS WIN, CREWMATE, IMPS)

### Navigation (keep as-is)
- A* pathfinding on walk mask with collision-aware pixel-level movement
- Momentum-aware steering: hold direction, coast, brake, precise approach
- Jiggle detection when stuck (perpendicular nudge while holding intent)
- Ghost mode: direct flight without walk mask constraint

### Task Execution (keep as-is)
- Task state machine: NotDoing → Maybe → Mandatory → Completed
- Stand in task rect, verify icon area visible, hold ButtonA without movement
- Radar dots create checkout tasks; icon visibility confirms mandatory status
- Priority: visible mandatory > existing mandatory > closest mandatory > checkout > radar > home

### What Is Missing
1. **No opponent modeling** — treats all non-self, non-imposter-teammate colors equally
2. **No deception as imposter** — random fake targets, basic "flee from bodies"
3. **No adaptive voting** — votes for most recently seen player or chat `sus` target
4. **No learning** — every game starts from scratch with zero strategic memory
5. **No situational awareness** — cannot reason about "3 players left, should I call meeting?"
6. **No coordinated imposter play** — kills opportunistically, no setup or alibi

---

## Part 2 — Memory Architecture (from CvC Harness)

The CvC debugger policy uses a three-tier memory system that maps cleanly onto Among Them.

### Tier 1: Working Memory (volatile, per-frame)

Replaced every frame. Contains the current snapshot of everything the bot perceives.

| CvC Field | Among Them Equivalent |
|---|---|
| `position` | `(playerWorldX, playerWorldY)` — inferred from camera |
| `tick` | `frameTick` — local client tick |
| `gear` / `role` | `BotRole` — crewmate, imposter, or ghost |
| `inventory` / `cargo` | Task progress — mandatory/completed/checkout counts |
| `hub_resources` | N/A (no shared economy), but could track task bar progress |
| `nav_target` | `(goalX, goalY)` + `goalName` |
| `visible_entities` | `visibleCrewmates`, `visibleBodies`, `visibleGhosts` |
| `active_directive` | Current LLM directive (role strategy, target, reasoning) |

**Among Them additions:**
```
WorkingMemory:
  selfColor: int              # own player color index
  selfRoom: string            # current room name
  isGhost: bool               # dead and floating
  isImposter: bool            # know we're the killer
  killReady: bool             # kill cooldown expired (kill icon visible)
  voting: bool                # in voting interstitial
  gamePhase: enum             # pregame | playing | voting | results | gameover
  aliveCount: int             # estimated living players
  visiblePlayerColors: set    # who we can see right now
  taskProgress: float         # estimated crew task completion (0.0-1.0)
```

### Tier 2: Episodic Memory (ring buffer, categorized events)

Append-only ring buffer of game events with landmark protection. Events in the
CvC system use "halls" (categories). For Among Them:

| Hall | Events |
|---|---|
| `sightings` | "saw Red in Electrical at t=142", "saw body in MedBay at t=200" |
| `kills` | "killed Blue in Reactor at t=180" (imposter only) |
| `meetings` | "meeting called at t=210", "voted Red at t=230", "Red was ejected" |
| `movement` | "entered Electrical at t=130", "left Navigation at t=155" |
| `social` | "Red and Yellow were together in Cafeteria", "Blue was alone in Reactor" |
| `suspicion` | "Blue accused Red of being sus", "alibi: I was in MedBay with Green" |

**Landmark events** (protected from eviction):
- Body discovered
- Player ejected
- Kill executed
- Self accused
- Game result (win/loss)

**Implementation:**
```nim
type
  EventHall = enum
    HallSightings, HallKills, HallMeetings,
    HallMovement, HallSocial, HallSuspicion

  GameEvent = object
    tick: int
    hall: EventHall
    text: string
    landmark: bool
    data: JsonNode  # optional structured data

  EpisodicMemory = object
    events: Deque[GameEvent]
    maxEvents: int  # ~200 for a typical game
```

### Tier 3: Strategic Memory (facts with temporal supersession)

Key-value facts that persist within a game and get updated as evidence changes.

| Fact Key Pattern | Example Value | Category |
|---|---|---|
| `player:red:last_seen` | `{room: "Electrical", tick: 142}` | map |
| `player:red:sus_score` | `0.7` | strategy |
| `player:red:alibi` | `"with Green in MedBay t=100-120"` | social |
| `player:blue:status` | `"dead"` or `"alive"` or `"ejected"` | map |
| `body:medbay:reported` | `true` | map |
| `self:alibi` | `"doing tasks in Electrical t=130-145"` | strategy |
| `self:kill_cooldown_ready` | `tick_when_ready` | strategy |
| `meeting:last_result` | `"Red ejected, was imposter"` | strategy |
| `strategy:current` | `"blend in, complete tasks near others"` | strategy |
| `failure:last_ejection_cause` | `"accused of being near body"` | failure |

**Temporal supersession:** When a new sighting of Red arrives, the old
`player:red:last_seen` is superseded (moved to history), not deleted. This lets
the LLM see the trajectory: "Red was in Electrical, then MedBay, then Reactor."

---

## Part 3 — Brain Architecture

The brain sits between perception (nottoodumb's existing pipeline) and output
(input mask). It replaces the simple goal-selection logic with layered reasoning.

### Decision Hierarchy

```
┌───────────────────────────────────────────────────┐
│  LLM Strategic Advisor (async, every N seconds)   │
│  "Who should I vote for? Should I call meeting?   │
│   Where should I kill? What's my alibi?"          │
└───────────────────┬───────────────────────────────┘
                    │ StrategicDirective
                    ▼
┌───────────────────────────────────────────────────┐
│  Scripted Brain (per-frame, deterministic)        │
│  "Navigate to target, hold A, flee from body,     │
│   report body, execute voting cursor movement"    │
└───────────────────┬───────────────────────────────┘
                    │ InputMask
                    ▼
┌───────────────────────────────────────────────────┐
│  Momentum Controller (per-frame, physics-aware)   │
│  "Hold left, coast, brake, jiggle if stuck"       │
└───────────────────────────────────────────────────┘
```

### Scripted Brain (Fast Path — Every Frame)

Handles deterministic per-frame execution. This is what nottoodumb.nim already
does, enhanced with directive awareness:

**Crewmate behavior:**
1. If LLM directive says "go to specific room" → navigate there
2. Else follow existing task priority: visible mandatory > mandatory > checkout > radar > home
3. If body visible → report (navigate to body, press A)
4. If ghost → navigate directly to task goals (no walls)

**Imposter behavior (LLM-enhanced):**
1. If LLM directive says "kill target=Blue" → stalk Blue, kill when alone
2. If LLM directive says "fake tasks in Electrical" → navigate there, stand still
3. If LLM directive says "call meeting" → navigate to button, press A
4. If body visible + others nearby → "discover" body, report it (self-report plays)
5. If body visible + alone → flee to directive's flee target
6. Default: existing fake-target wandering

**Voting behavior (LLM-enhanced):**
1. If LLM directive says "vote target=Red" → navigate cursor to Red
2. If LLM directive says "vote skip" → navigate to skip
3. Chat: send LLM-generated accusation or defense text
4. Default: existing sus-color or skip logic

### LLM Strategic Advisor (Slow Path — Async)

Runs in a background thread (or on a timer), consults the LLM at strategic
decision points. Mirrors the CvC BackgroundHarness pattern.

**When to consult:**

| Trigger | Priority | Description |
|---|---|---|
| `body_discovered` | 100 | Found a dead body — report or flee? |
| `meeting_called` | 90 | Voting starts — who to accuse/defend? |
| `kill_opportunity` | 80 | Alone with a crewmate, kill ready |
| `accused_in_chat` | 70 | Someone said our color is sus |
| `ejection_result` | 60 | Player was ejected — update model |
| `room_transition` | 30 | Entered a new room (lower priority) |
| `periodic` | 10 | Every ~100 frames if nothing else triggers |

**Directive format (JSON):**
```json
{
  "strategy": "blend_in | hunt | accuse | defend | fake_tasks | self_report",
  "target_player": "red",
  "target_room": "Electrical",
  "vote_target": "red",
  "chat_message": "I saw Red near the body in MedBay",
  "reasoning": "Red was last seen near MedBay and the body was found there. Accusing Red deflects suspicion from us.",
  "hold": true,
  "until": "vote_complete"
}
```

---

## Part 4 — Event Detection & Triggers

Port the CvC `EventDetector` pattern. Compare consecutive frames and fire
triggers on state changes.

### Detectable Events

```
Previous Frame → Current Frame → Detected Event
─────────────────────────────────────────────────
not interstitial → interstitial     → meeting_called / game_over
interstitial → not interstitial     → round_start
0 bodies → 1+ bodies               → body_discovered
kill icon invisible → visible       → kill_cooldown_ready
N crewmates → N-1 crewmates        → player_missing (possible kill)
voting no result → ejection text    → player_ejected
no chat sus → chat mentions color   → player_accused
alone with 1 target + kill ready    → kill_opportunity
position unchanged 30+ frames       → stuck_detected
same room 200+ frames               → idle_in_room
```

### Debounce & Priority Resolution

Same as CvC: only one trigger fires per evaluation cycle. Highest priority wins.
Debounce prevents the same trigger from re-firing for N frames.

---

## Part 5 — Narrator (Context Builder)

Compresses all three memory tiers into a compact LLM prompt (~800 tokens).

### Sections

**[WORKING MEMORY]**
```
Tick: 342 | Phase: playing | Room: Electrical
Role: IMPOSTER | Ghost: no | Kill ready: yes
Players alive: 6 | Visible: Red, Green
Task bar: ~40% complete
Current goal: fake tasks in Electrical
```

**[RECENT EVENTS]** (last 10 from episodic)
```
t=310: entered Electrical
t=290: saw Red in MedBay *
t=275: killed Blue in Reactor (alone) *
t=250: meeting ended, Yellow was ejected (was crewmate)
t=220: voted for Yellow (deflection)
t=200: meeting called by Green
t=190: saw body in Navigation
t=150: entered Reactor with Blue
t=130: left Cafeteria
t=100: game start, assigned IMPOSTER with Yellow *
```

**[PLAYER MODEL]** (from strategic memory)
```
Red: alive, last seen MedBay t=290, sus_score=0.2 (quiet, does tasks)
Green: alive, last seen Electrical t=342, sus_score=0.1 (witness risk)
Blue: DEAD (we killed in Reactor t=275), body unreported
Yellow: EJECTED (we accused, was crewmate — successful deflection)
Pink: alive, not seen since t=180, sus_score=0.0
Lime: alive, last seen Navigation t=160, sus_score=0.3 (near body)
```

**[STRATEGIC SUMMARY]**
```
Kill cooldown: ready
Bodies unreported: 1 (Blue in Reactor)
Meetings remaining: estimate 2-3
Our alibi: "doing tasks in Electrical since t=310"
Risk level: MEDIUM (Green is nearby, Blue's body may be found)
```

---

## Part 6 — Cross-Game Learning

### Game Memory Dumps

After each game, dump the full memory to a JSON file:

```json
{
  "game_id": "a1b2c3d4",
  "result": "imposter_win",
  "role": "imposter",
  "kills": 2,
  "ejected": false,
  "meetings_survived": 3,
  "successful_accusations": 1,
  "strategies_used": ["fake_tasks", "self_report", "blame_nearest"],
  "failures": ["almost caught near body in round 2"],
  "episodic_events": [...],
  "strategic_facts": [...],
  "llm_call_log": [...]
}
```

### Learning Synthesis

Before each new game, load recent game dumps and synthesize into a compact
prior-learnings block for the system prompt:

```
[PRIOR GAME LEARNINGS]
Games played: 12 | Win rate: 58%
As imposter (5 games): 3 wins, 2 losses
  - Self-reporting works well when 5+ players remain
  - Killing in Electrical is risky (high traffic room)
  - Blaming the "quiet" player who hasn't spoken in chat often succeeds
As crewmate (7 games): 4 wins, 3 losses
  - Players alone in low-traffic rooms are likely imposters
  - Completing tasks in groups of 2-3 is safest
  - Voting patterns: aggressive accusers are often imposters
Best strategy as imposter: fake tasks near others, kill isolated targets, self-report
Worst failure: killing with 2 witnesses visible (missed the second player)
```

### Post-Game Analysis

Optionally run a more capable model (e.g., Opus) on the full memory dump to
produce structured learnings. This mirrors the CvC `post_game_analysis.py` pattern.

---

## Part 7 — System Prompt

The LLM sees a system prompt that encodes game rules, its role, and prior
learnings. This is generated once at game start.

```
You are an AI player in Among Them, a social deduction game.
You are: {IMPOSTER | CREWMATE}. Your color is: {color}.

GAME RULES:
- {minPlayers} players, {imposterCount} imposters
- Crewmates win by completing all tasks or ejecting all imposters
- Imposters win by killing until imposters >= crewmates
- Bodies can be reported to call emergency meetings
- During meetings, players discuss and vote to eject someone
- Chat is only active during voting

YOUR CAPABILITIES:
- You receive perception summaries every few seconds
- You issue strategic directives: where to go, who to target, what to say
- Your scripted controller handles navigation and physics
- You do NOT control frame-by-frame inputs directly

{prior_learnings}

Respond ONLY with JSON:
{
  "strategy": "blend_in | hunt | accuse | defend | fake_tasks | self_report | report_body | skip_vote",
  "target_player": "color or null",
  "target_room": "room name or null",
  "vote_target": "color or skip or null",
  "chat_message": "text to send during voting or null",
  "reasoning": "brief explanation of your strategic thinking"
}
```

---

## Part 8 — Implementation Plan

### Phase 1: Infrastructure (Nim + External Process)

The LLM cannot run inside Nim directly. Use one of these patterns:

**Option A: Nim bot + Python sidecar (recommended)**
- `nottoodumb.nim` handles perception, navigation, physics (fast path)
- Python process runs LLM + memory + narrator (slow path)
- Communication via Unix socket, named pipe, or local HTTP
- Nim sends perception snapshots, Python sends back directives
- Non-blocking: Nim continues with scripted behavior while waiting

**Option B: Nim bot + subprocess LLM calls**
- Nim shells out to `curl` or a small Python script for LLM calls
- Simpler but higher latency per call
- Suitable for prototyping

**Option C: Full rewrite in Python**
- Port perception pipeline to Python (numpy for frame processing)
- Significant effort, but allows unified codebase
- Risk: Python may be too slow for per-frame localization

### Phase 2: Memory System (Python side)

1. Implement `WorkingMemory` dataclass — updated from Nim perception snapshots
2. Implement `EpisodicMemory` with ring buffer and landmark protection
3. Implement `StrategicMemory` with key-value facts and supersession
4. Implement `GameMemory` container holding all three tiers
5. Write serialization to JSON for game dumps

### Phase 3: Event Detection (Python side)

1. Port `EventDetector` pattern — diff consecutive snapshots
2. Implement trigger priority table
3. Implement debounce logic
4. Wire triggers to LLM consultation decisions

### Phase 4: Narrator (Python side)

1. Implement `build_context()` — compress all memory tiers to ~800 tokens
2. Working memory section: current state, role, room, visible players
3. Episodic section: last 10 events with landmarks
4. Strategic section: player models, risk assessment, alibi tracking
5. Performance section: task completion rate, kill efficiency

### Phase 5: LLM Integration (Python side)

1. Create `LLMProvider` abstraction (Anthropic, OpenRouter, Bedrock)
2. Implement conversation history management (sliding window of 30)
3. Implement directive parsing from JSON responses
4. Implement system prompt with role-specific instructions

### Phase 6: Brain Enhancement (Nim side)

1. Add directive receiver — read directives from Python sidecar
2. Enhance imposter goal selection with LLM targets
3. Enhance voting with LLM vote/chat targets
4. Add meeting-call decision (navigate to button, press A when LLM says)
5. Add self-report behavior (report a body you created)
6. Add alibi-aware movement (stay near others when not killing)

### Phase 7: Cross-Game Learning (Python side)

1. Implement game dump serialization at game end
2. Implement `load_prior_games()` from dump directory
3. Implement `synthesize_learnings()` for system prompt injection
4. Optionally: post-game analysis with a larger model

### Phase 8: Advanced Strategies

1. **Player tracking model** — maintain position estimates for all players,
   decay confidence over time. "Red was in MedBay 30 seconds ago, probably
   still nearby."
2. **Alibi construction** — as imposter, deliberately be seen doing tasks
   before sneaking away to kill. Record which players saw you where.
3. **Accusation strategy** — as imposter, build a case against an innocent.
   "I saw Blue near the body." Requires manufacturing believable chat.
4. **Defense strategy** — as crewmate accused of being sus, cite alibi events
   from episodic memory. "I was in Electrical doing wiring at that time."
5. **Vote manipulation** — as imposter, identify the weakest social position
   (quiet player, player with weak alibi) and direct accusations there.
6. **Endgame awareness** — "3 players left, if I kill one more we win.
   But if they vote me out first, we lose. Should I play safe or go for it?"

---

## Part 9 — Communication Protocol (Nim ↔ Python)

### Snapshot Message (Nim → Python, every frame or every N frames)

```json
{
  "type": "snapshot",
  "tick": 342,
  "phase": "playing",
  "room": "Electrical",
  "role": "imposter",
  "is_ghost": false,
  "kill_ready": true,
  "player_x": 405,
  "player_y": 312,
  "camera_x": 341,
  "camera_y": 248,
  "camera_locked": true,
  "visible_crewmates": [
    {"color": 0, "x": 380, "y": 290, "room": "Electrical"},
    {"color": 13, "x": 420, "y": 305, "room": "Electrical"}
  ],
  "visible_bodies": [],
  "visible_ghosts": [],
  "task_states": {
    "mandatory": 2,
    "completed": 3,
    "checkout": 1,
    "total": 6
  },
  "voting": false,
  "vote_cursor": -1,
  "vote_slots": [],
  "vote_chat_text": "",
  "home_x": 510,
  "home_y": 115,
  "intent": "fake tasks Electrical",
  "stuck_frames": 0
}
```

### Directive Message (Python → Nim)

```json
{
  "type": "directive",
  "strategy": "hunt",
  "target_player_color": 0,
  "target_room": "Reactor",
  "vote_target_color": 13,
  "chat_message": "I saw green near the body",
  "navigate_to": [225, 250],
  "hold": true,
  "until": "kill_executed",
  "reasoning": "Red is alone in Reactor, kill cooldown ready, no witnesses"
}
```

### Event Message (Nim → Python, on state changes)

```json
{
  "type": "event",
  "event": "body_discovered",
  "tick": 200,
  "data": {
    "body_x": 380,
    "body_y": 195,
    "room": "Navigation",
    "nearby_colors": [0, 13]
  }
}
```

---

## Part 10 — Best Practices

### From nottoodumb.nim (Perception)
1. **Never localize on interstitials.** Black-pixel percentage ≥ 30% = interstitial.
2. **Mask dynamic pixels** before map matching — players, bodies, ghosts, icons, radar.
3. **Accept shadows** during localization. `ShadowMap[mapColor]` handles dark rooms.
4. **Reseed after voting.** Sim resets players to home after meetings.
5. **Local search first.** Full spiral is the fallback, not the common path.
6. **Task icons are above the task rectangle.** Check the icon area, not the rect.
7. **Radar is evidence, not proof.** Checkout list, not mandatory status.
8. **Hold A without movement** for task completion. Mixing movement resets the task.

### From CvC Harness (Strategy)
1. **Never block the game loop on LLM.** Use async background thread or non-blocking I/O.
2. **Budget LLM calls.** Max ~50 per game. Each call costs ~2-4 seconds wall-clock.
3. **Event-driven, not periodic.** Consult on body discovery, meeting start, kill opportunity — not every 5 seconds.
4. **Directives expire.** Set `expires_tick` so stale directives don't persist.
5. **Memory tiers have different lifetimes.** Working = 1 frame, episodic = full game (ring buffer), strategic = until superseded.
6. **Landmarks are sacred.** Never evict "killed Blue in Reactor" to make room for "entered hallway."
7. **Narrator compresses, doesn't dump.** The LLM gets ~800 tokens of context, not raw memory.
8. **Cross-game learning compounds.** 10+ games of prior data makes the LLM significantly better.
9. **Guard against LLM thrashing.** If the LLM keeps changing strategy every call, add hold/until locks.
10. **Scripted fallback is the baseline.** LLM overrides should improve on the scripted behavior, not replace it entirely. If the LLM is down, the bot should still play reasonably.

### Social Deduction Specific
1. **Track who was where.** The #1 advantage an LLM bot has is perfect recall of sightings.
2. **Construct alibis proactively.** As imposter, be seen by others before killing.
3. **Chat is power.** Voting chat is the only communication channel. Use it surgically.
4. **Model other players' information.** "Green couldn't have seen me kill because Green was in Nav."
5. **Accusation timing matters.** Too early = suspicious. Wait for others to speak first, then build on chat evidence.
6. **Self-reports are high risk/high reward.** "I found the body!" deflects suspicion but draws attention.
7. **Vote with the majority.** As imposter, voting with the group avoids standing out.
8. **Silence is suspicious.** Both for the bot and for modeling others. Track who speaks and who doesn't.

---

## Part 11 — File Structure

```
among_them/players/
├── nottoodumb.nim          # Existing bot (perception, nav, physics)
├── smart_bot.nim           # Enhanced bot: adds sidecar communication + directive handling
├── sidecar/
│   ├── __init__.py
│   ├── main.py             # Sidecar entry point (socket server)
│   ├── memory.py           # Three-tier memory (working, episodic, strategic)
│   ├── brain.py            # Strategic brain: event detection → LLM → directive
│   ├── triggers.py         # Event detector (snapshot diffs → triggers)
│   ├── narrator.py         # Context builder (memory → compressed LLM prompt)
│   ├── advisor.py          # LLM provider + conversation + directive parsing
│   ├── learnings.py        # Cross-game learning (dump → synthesize → inject)
│   ├── player_model.py     # Per-player state tracking and suspicion scoring
│   └── prompts/
│       ├── system.md       # System prompt template
│       ├── imposter.md     # Imposter-specific strategy guidance
│       └── crewmate.md     # Crewmate-specific strategy guidance
├── runs/                   # Game memory dumps (JSON)
│   ├── a1b2c3d4_memory.json
│   └── ...
└── SMART_BOT_GUIDE.md      # This document
```

---

## Part 12 — Suggested Build Order

1. **Get nottoodumb.nim running** against a local server. Verify perception works.
2. **Add snapshot export.** Write a `toJson` proc that serializes the Bot struct
   to the snapshot format above. Write it to stdout or a socket every N frames.
3. **Build the Python sidecar** with a socket server that reads snapshots.
4. **Implement WorkingMemory** — parse snapshots, store current state.
5. **Implement EpisodicMemory** — record events from snapshot diffs.
6. **Implement StrategicMemory** — player tracking facts.
7. **Implement EventDetector** — fire triggers on state changes.
8. **Implement Narrator** — compress memory to LLM context.
9. **Wire up a single LLM call** — body_discovered trigger → LLM → directive.
10. **Implement directive handling in Nim** — read directives, override goals.
11. **Enhance voting** — LLM chooses vote target and chat message.
12. **Enhance imposter behavior** — LLM chooses kill targets and alibis.
13. **Add cross-game learning** — dump memory at game end, load at game start.
14. **Iterate.** Play 20+ games, review memory dumps, tune triggers and prompts.

Do not start with clever LLM strategy. Start with reliable perception export
and memory recording. Strategy is easy once the memory layer stops lying.

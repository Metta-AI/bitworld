# How To Make An Among Them Bot

This guide explains how to write a screen-reading bot for Among Them. The best
reference implementation right now is `nottoodumb.nim` in this directory. It is
not small anymore, but it contains the hard-won answers to most of the problems
that make this game tricky.

The important lesson is this: do not think of the bot as just A* plus task
locations. The bot is a visual client. It must keep itself localized on the map,
ignore things that are not the map, understand interstitial screens, handle
momentum, and keep a careful task state model.

## Useful Files

- `among_them/players/nottoodumb.nim`: Current main bot.
- `among_them/sim.nim`: Simulation, map constants, task list, sprites, roles,
  movement, voting, rendering.
- `common/protocol.nim`: Packed frame and input/chat packet protocol.
- `among_them/README.md`: Server and quick player commands.
- `tools/quick_player`: Starts many copies of a bot.

## Run Commands

Start a server:

```sh
cd /Users/me/p/bitworld/among_them
nim r among_them.nim --address:0.0.0.0 --port:2000 --config:'{"minPlayers":8,"imposterCount":2,"tasksPerPlayer":6,"voteTimerTicks":360}'
```

Start one bot with the debug viewer:

```sh
cd /Users/me/p/bitworld/among_them/players
nim r nottoodumb.nim --address:0.0.0.0 --port:2000 --gui --name:player1
```


Start many bots:

```sh
cd /Users/me/p/bitworld
nim r tools/quick_player nottoodumb --players:8 --address:localhost --port:2000
```

View a player's perspective from the browser:

Open `bitworld/clients/index.html?address=ws://localhost:2000/player` in your browser.

View the global map from the browser:

Open `bitworld/clients/global_client.html?address=ws://localhost:2000/player` in your browser.


## Protocol Basics

Players connect to:

```text
ws://HOST:PORT/player?name=player1
```

The server sends a 128 by 128 packed 4-bit framebuffer. `ProtocolBytes` is
`(ScreenWidth * ScreenHeight) div 2`. Unpack each byte into two palette indices.
The current bot does this in `unpack4bpp`.

The bot sends inputs with `blobFromMask(mask)`. The mask uses these bits:

- `ButtonUp`
- `ButtonDown`
- `ButtonLeft`
- `ButtonRight`
- `ButtonSelect`
- `ButtonA`
- `ButtonB`

For chat during voting, send `blobFromChat(text)`. The server only accepts
voting chat while the sim is in the voting phase.

Only send a new input packet when the mask changes. This keeps the network and
server clean and makes held buttons behave like held buttons.

## Basic Bot Shape

The current bot follows this loop:

1. Connect to `/player`.
2. Receive a binary frame.
3. Unpack the 4-bit framebuffer.
4. Increment a local client tick.
5. Detect whether the screen is an interstitial.
6. If interstitial, parse voting, role reveal, or game-over text.
7. If not interstitial, update role, self color, visible actors, and task icons.
8. Localize the camera on the map.
9. Update task guesses and task states.
10. Choose a goal.
11. Choose an input mask.
12. Send the mask.
13. Draw debug information if `--gui` is enabled.

Keep this as a pipeline. It is much easier to debug than a tangle of callbacks.

## Import The Sim, But Still Read The Screen

The bot imports `../sim`. This is intentional. The bot can use:

- Map size and screen size constants.
- The task station list.
- The walk mask and wall mask.
- Sprites loaded from the same sprite sheet.
- Button location.
- Palette and shadow behavior.

The bot should still treat the framebuffer as the source of truth for what it
can currently see. The sim gives geometry. The screen tells you current role,
task icons, radar dots, bodies, other players, voting screens, and game-over
state.

## Localization Is The Hardest Part

The bot must infer camera coordinates from the 128 by 128 frame. Once it knows
camera coordinates, the player position is:

```text
playerWorldX = cameraX + PlayerWorldOffX
playerWorldY = cameraY + PlayerWorldOffY
```

The current approach is:

1. Score a candidate camera by comparing the frame pixels to the map pixels.
2. Ignore dynamic pixels that are not map evidence.
3. Accept both normal map pixels and shadowed map pixels.
4. Search near the previous camera first.
5. If local search fails, do a full spiral search from the best seed.
6. Seed from the button before the game starts.
7. Seed from the remembered home position after voting or result screens.

Do not scan the full map with a naive top-left nested loop every frame. That was
one of the worst CPU problems. A full-frame scan can be hundreds of milliseconds
if it starts in the wrong place. The local temporal search usually solves the
next frame in a tiny area.

## What To Ignore During Map Matching

Map matching fails if dynamic things are counted as map errors. The bot masks
these before scoring:

- The local player sprite around the screen center.
- Other crewmates.
- Dead bodies.
- Ghosts.
- Task icons.
- Radar pixels.
- Kill button icon.
- Ghost status icon.

This is especially important when several crewmates overlap or stand in the
same room. Without masking, the bot decides the map does not match and starts a
slow full search.

Also handle shadows. If a frame pixel does not match the map pixel, check
whether `ShadowMap[mapColor]` matches. Electrical and other dark rooms are hard
without this.

## Interstitial Detection

Voting, vote results, role reveal, and game-over screens are not map frames.
Never try to localize on them.

The current bot uses a black-pixel percentage:

```text
black pixels >= 30 percent of the screen
```

This replaced the fragile "four corners are black" rule. That rule broke when
chat text, borders, or UI marks touched the corners or when gameplay showed
black off-map padding.

The sim now uses `MapVoidColor` for off-map gameplay areas, not black. Black is
therefore much safer as an interstitial signal.

When entering an interstitial:

- Clear visible task icons, crewmates, bodies, and ghosts.
- Do not draw gameplay debug lines.
- Do not localize.
- Parse ASCII text for `CREW WINS`, `IMPS WIN`, `CREWMATE`, and `IMPS`.
- Parse voting if the voting screen is visible.

When leaving an interstitial:

- Clear voting state.
- Reseed localization from remembered home, or from the button if home is not
  known.
- Clear stale path, goal, task hold, velocity, and jiggle state.

This reseed matters because the sim resets players to home after voting.

## Home And The Button

At game start, each player is arranged around the cafeteria button. The bot
records the first reliable localized position as `homeX` and `homeY`.

Use home as the fallback goal when:

- No mandatory task is known.
- No checkout task is known.
- No radar task is visible.
- All known tasks look done.

Do not make every bot stand on the exact button pixel. Returning to each bot's
own home spreads them around the table and avoids a pileup.

## Task Detection

Tasks have two separate visual concepts:

- The task rectangle is where the player must stand.
- The task icon is drawn above the task rectangle.

A major recurring bug was clearing tasks too early because the bot checked the
task rectangle instead of the icon area above it. To mark a task completed or
not needed, the full expected icon rectangle must be visible with margin, and
the icon must be absent for enough frames.

Use task states:

- `TaskNotDoing`: No evidence yet.
- `TaskMaybe`: Radar or checkout evidence says maybe.
- `TaskMandatory`: A task icon is visible or otherwise confirmed.
- `TaskCompleted`: The icon was safely inspected and is gone.

Key rules:

- Seeing a task icon always wakes that task back to `TaskMandatory`.
- A completed task should not be reactivated by radar alone.
- Radar is evidence, not proof.
- Radar dots should add tasks to a checkout list, not permanently mark them
  mandatory.
- Only remove a checkout task after visually verifying the expected icon area.

The current bot detects task icons only at expected task locations. This is much
more reliable than globally scanning the whole screen for sprite-like pixels.

## Radar Dots

The yellow pixels on the screen edge point toward offscreen task icons. The bot
projects every known task icon position to the edge of the screen and compares
that projection with visible yellow radar dots.

Use radar to answer:

```text
Which tasks should I go check?
```

Do not use radar to answer:

```text
Which tasks are definitely assigned?
Which tasks are definitely completed?
```

The radar changes as the player moves. Treat it as ephemeral. Once a radar dot
points at a task, put that task in the checkout list. Keep it there until the
icon area is actually checked.

## Choosing A Task

Priority order should be:

1. Visible mandatory task icons on the current screen.
2. Existing mandatory task goal, to avoid oscillation.
3. Closest mandatory task.
4. Existing checkout goal, to avoid oscillation.
5. Closest checkout task.
6. Existing radar goal.
7. Closest radar task.
8. Home fallback.

The oscillation bug happened when the bot kept switching between two similarly
close tasks every frame. If a current goal is still valid, keep it unless a
higher-priority visible mandatory task appears.

Visible task icons are more important than radar. If an icon is on screen, the
radar may not show it because the radar only points to offscreen tasks.

## Completing A Task

To do a task:

1. Navigate to a passable pixel inside the task rectangle.
2. Prefer an inner pixel so one-pixel drift does not leave the task.
3. Make sure the task icon area is visible.
4. Stop moving.
5. Hold only `ButtonA`.
6. Do not release A until the task completion timer has elapsed.
7. Do not press movement while holding A.

The task resets if movement input is held while pressing A. Several bugs came
from "tapping" A or mixing A with movement. Treat task completion as a special
state where the controller output is exactly `ButtonA`.

After the hold, only mark the task completed if the icon is gone and the icon
area is fully visible. Otherwise put it back to `TaskMandatory`.

## Movement And Navigation

The sim has acceleration, velocity, carry, friction, and collision. It is not a
grid-step game. Sending up for one frame does not mean "move one tile up."

Use A* on the walk mask for living players. The current bot uses pixel-level
A* with `walkMask` and one-pixel collision. Pick a lookahead point from the path
instead of steering to the immediate next pixel.

Then steer with momentum:

- If far from the waypoint, hold the direction.
- If current velocity will carry you to the target, coast.
- If about to overshoot, brake with the opposite direction.
- Near the goal, use a more precise controller.

The bot also uses a short jiggle when it appears stuck. The useful version keeps
the intended direction held and adds a perpendicular direction briefly. Earlier
versions that stopped pressing the intended direction just wiggled in place.

Ghosts are different. Ghosts can fly directly toward goals and should not use
A* as if they were constrained by the walk mask.

## Collision And Map Edges

Collision is one pixel wide and one pixel tall. The sim also tries to slide when
movement hits an obstacle: if moving right is blocked, it may test the adjacent
up or down pixel to slide along the wall.

The viewport is centered on the player. When the player sees beyond the map,
the sim fills off-map pixels with `MapVoidColor`, not black. This avoids
confusing off-map gameplay with black interstitial screens.

Walls are not additionally shadowed. They are already dark enough, and extra
shadowing made localization harder.

## Roles

Assume crewmate by default. Only switch to imposter when the kill icon is seen.
Only switch to ghost when the fixed ghost status icon is seen for enough frames.

Earlier self-ghost detection tried to infer ghost state from the player sprite.
That was unreliable because other ghosts, task icons, or overlapping players
could be mistaken for self. The sim now draws a fixed ghost icon in the same UI
slot as the imposter kill icon. Use that.

Role reveal screens can also teach role information:

- `CREWMATE`: keep or set crewmate.
- `IMPS`: mark self as imposter and remember teammate colors shown on screen.

## Crewmates, Bodies, And Suspects

Detect other crewmates by stable sprite pixels and body tint. The outline and
visor are stable, while body colors vary. Store the last tick when each color
was seen.

When a crewmate sees a body:

1. Queue a short chat message such as `body in Electrical`.
2. Add `sus COLOR` if there is a recent non-self, non-known-imposter color.
3. Move into report range.
4. Press A to report.
5. Send the queued chat once voting begins.

Do not spam body messages during gameplay. The server ignores chat until voting,
so queue the message and send it once inside the voting interstitial.

Imposters handle bodies differently. If an imposter sees a body, pick a far fake
goal and leave the area.

## Imposter Behavior

An imposter needs to look like it is doing tasks:

- Pick a random fake target from all task areas plus the button.
- Walk there like a crewmate.
- When arriving, pick another fake target.
- If a body is visible, flee toward the farthest fake target.
- If exactly one non-imposter crewmate is visible and kill is ready, move toward
  them and press A in kill range.
- Never kill when two or more possible witnesses are visible.
- After killing, choose the farthest fake target from the current location.

Known imposter teammate colors should not count as kill targets or suspects.

## Voting

Voting is an interstitial, not a map screen. The bot parses the voting grid:

- Player count.
- Player slot colors.
- Alive or body sprite.
- Cursor position.
- Self marker.
- Vote dots.
- Skip button.
- Visible chat text.

The current voting behavior:

1. Prefer a color mentioned as `sus` in chat.
2. Otherwise vote for the bot's own most recent suspect.
3. Otherwise vote skip.
4. Move the cursor with left or right.
5. Wait a short listen period before pressing A.
6. Once the bot has voted, release input.

Because the voting cursor moves on edge presses, alternate between the direction
mask and idle if necessary. Holding the same direction can fail to create a new
edge.

## Debug Viewer

The debug viewer is essential. It should show:

- Intent.
- Room.
- Client tick.
- Buttons held.
- Timing for centering and A*.
- Interstitial text.
- Camera lock and score.
- Role, ghost state, kill readiness, known imposters.
- Camera and player coordinates.
- Home.
- Velocity.
- Visible crewmates, bodies, ghosts.
- Suspect.
- Radar dots, radar tasks, checkout tasks, task icons.
- Mandatory and completed task counts.
- Goal and ready state.
- Path pixels.
- Desired and controller masks.
- Stuck and jiggle counters.
- Voting parse state.

Draw the evidence too:

- Current camera viewport on the map.
- Player position.
- Home position.
- Task rectangles.
- Lines from task rectangles to expected icon areas.
- Task icon detection rectangles.
- Radar lines.
- A* path.
- Visible crewmate, body, and ghost boxes.

Most serious bugs were obvious only after adding the right debug line or box.

## Performance

The most expensive operation is localization. Track timing separately:

- `centerMicros` for screen centering and map lock.
- `astarMicros` for path planning.

If CPU is high, first check whether the bot is localizing every frame with a
full scan. Common reasons:

- It is trying to localize an interstitial.
- Too many dynamic pixels are counted as map errors.
- Shadows are not accepted.
- Off-map pixels use the wrong color.
- The local seed is wrong after voting.
- The bot is not masking other players or task icons.

The local temporal search should handle normal movement. Full spiral search
should be a fallback, not the common path.

## The Problems That Cost The Most Time

Localization was the biggest issue. Full-map scans were too slow, especially
when started from the wrong seed. Temporal local search and spiral search from
a good seed fixed most of it.

Interstitial detection was fragile. Corner checks broke when UI elements or
chat changed the screen. Counting black pixels worked better, but only after
gameplay off-map space stopped using black.

Task clearing was too eager. The icon is above the task rectangle. The bot must
see the full expected icon area before it decides the task is not there.

Radar was given too much authority. Radar should create checkout tasks, not
final task truth. Only task icons should make a task mandatory, and only visual
inspection should clear a task.

Movement was treated like discrete grid input at first. The sim has momentum,
so the bot must hold directions, coast, brake, and account for velocity.

Task completion failed when A was tapped or mixed with movement. The correct
behavior is to stand still and hold only A until the task completes.

Goal oscillation happened when two tasks had similar distance. Keep the current
valid goal unless a higher-priority visible mandatory task appears.

Ghost detection from sprites was unreliable. A fixed ghost UI icon was much
more robust.

Post-vote behavior broke because the sim reset players home while the bot kept
an old localization seed. Reseed from home when leaving interstitial screens.

Chat and voting screens interfered with interstitial detection. Keep voting UI
mostly black and do not attempt map parsing while the screen is an interstitial.

## Suggested Build Order For A New Bot

1. Connect to `/player` and show received frames.
2. Unpack 4-bit frames correctly.
3. Send input masks and verify held buttons.
4. Import `sim.nim` and load map, sprites, tasks, and walk mask.
5. Add a debug viewer before adding complex behavior.
6. Implement interstitial detection and do nothing on interstitials.
7. Implement map localization with dynamic pixel masking.
8. Add local temporal search, then full spiral fallback.
9. Add task icon detection at expected task locations.
10. Add radar checkout tasks.
11. Add A* and momentum-aware steering.
12. Add task hold behavior.
13. Add body detection and reporting.
14. Add voting parse and vote behavior.
15. Add imposter behavior.
16. Add ghost behavior.
17. Profile and tighten thresholds.

Do not start with clever strategy. Start with seeing, localizing, and drawing
what the bot believes. Strategy is easy once the perception layer stops lying.

---

## Running the Smart Bot with the Debugger GUI

This section walks through running the Python smart bot (with LLM brain) in a
full multiplayer game alongside other AI players, with the real-time browser
debugger attached.

### Quick Start (One Command)

The fastest way to launch everything — server, Nim opponents, smart bot, and
debugger — is the launcher script:

```sh
cd among_them/bot-policies
./run_debug_game.sh
```

It starts the game server, spawns Nim AI opponents, launches the Python smart
bot with the LLM brain and debugger, and opens the debugger + global view in
your browser. Press `Ctrl+C` to stop everything cleanly.

Override defaults with environment variables:

```sh
NIM_BOTS=7 MIN_PLAYERS=8 IMPOSTERS=2 PROVIDER=anthropic ./run_debug_game.sh
```

| Variable | Default | Description |
|---|---|---|
| `HOST` | `localhost` | Server bind address |
| `PORT` | `8080` | Server port |
| `NIM_BOTS` | `4` | Number of Nim AI opponents |
| `MIN_PLAYERS` | `5` | Players needed to start the game |
| `IMPOSTERS` | `1` | Number of imposters |
| `TASKS` | `4` | Tasks per player |
| `PROVIDER` | `bedrock` | LLM provider: `bedrock`, `anthropic`, `openrouter` |
| `MODEL` | (default) | Override LLM model name |
| `DEBUG_PORT` | `9090` | Debug WebSocket port (HTTP = port + 1) |
| `OPEN_BROWSER` | `1` | Set to `0` to skip auto-opening browser tabs |

### Manual Setup (Step-by-Step)

If you prefer to run each piece in its own terminal:

### Prerequisites

You need three things installed:

1. **Nim compiler** — to build the game server and Nim AI opponents.
2. **Python 3.12+** — already in the repo venv at `.venv/`.
3. **Python dependencies** — Pillow, websockets, numpy, boto3, httpx.

Install the Python packages (from the repo root):

```sh
cd /Users/aaln/experiments/softmax/bitworld
python3 -m ensurepip --upgrade
python3 -m pip install Pillow websockets numpy boto3 httpx python-dotenv
```

If you want the LLM brain to work, you also need AWS credentials configured
for the `softmax` profile (used by Bedrock), or set `ANTHROPIC_API_KEY` /
`OPENROUTER_API_KEY` environment variables and use `--provider anthropic` or
`--provider openrouter` instead.

### Step 1 — Start the Game Server

Open a terminal and start the Among Them server:

```sh
cd /Users/aaln/experiments/softmax/bitworld/among_them
nim r among_them.nim --address:localhost --port:8080 \
  --config:'{"minPlayers":5,"imposterCount":1,"tasksPerPlayer":4,"voteTimerTicks":720}'
```

`minPlayers` controls how many players must join before the game starts.
Set it lower (3-5) for quick testing.

### Step 2 — Launch Nim AI Opponents

In a second terminal, start the Nim bots to fill the lobby:

```sh
cd /Users/aaln/experiments/softmax/bitworld
nim r tools/quick_player nottoodumb --players:4 --address:localhost --port:8080
```

This compiles `nottoodumb.nim` and spawns 4 copies. They will connect to the
server and wait in the lobby. Adjust `--players:N` to match your `minPlayers`
minus 1 (leaving one slot for the Python smart bot).

### Step 3 — Launch the Python Smart Bot with Debugger

In a third terminal, start the Python bot with the LLM brain and debugger GUI:

```sh
cd /Users/aaln/experiments/softmax/bitworld/among_them/bot-policies
python3 -m sidecar.bot \
  --brain \
  --provider bedrock \
  --name smartbot \
  --host localhost \
  --port 8080 \
  --debug
```

You should see:

```
INFO: Brain enabled: provider=bedrock model=default
INFO: Debug GUI will be at http://localhost:9091
INFO: Connecting to ws://localhost:8080/player?name=smartbot
INFO: Loaded sprites from .../spritesheet.png
INFO: Loaded map data from .../skeld2.aseprite (952x534, 253280 walkable pixels)
INFO: Connected to game server
INFO: Debug GUI:  http://localhost:9091
INFO: Debug WS:   ws://localhost:9090
```

### Step 4 — Open the Debugger Dashboard

Open your browser and go to:

```
http://localhost:9091
```

The debugger has six panels:

| Panel | What it shows |
|---|---|
| **Game View** | The bot's 128x128 viewport rendered in real time |
| **Brain** | Current strategy directive, reasoning, and trigger alerts |
| **LLM Calls** | Expandable log of every LLM call — context sent, response received, latency, tokens |
| **Memory** | Episodic events timeline + strategic facts key-value store |
| **Player Model** | Per-player suspicion bars, alive/dead status, last room |
| **Status & Intent** | Phase, role, tick counter, LLM budget, and scrolling intent history |

The dashboard auto-reconnects if the bot restarts.

### Step 5 (Optional) — Watch as a Human Player

To spectate or play alongside the bots, open the player client in another
browser tab:

```
http://localhost:8080/client/player.html?address=ws://localhost:8080/player&name=spectator
```

Or view the god-mode global map:

```
http://localhost:8080/client/global.html?address=ws://localhost:8080/global
```

### CLI Reference

The Python bot accepts these flags:

| Flag | Default | Description |
|---|---|---|
| `--host` | `localhost` | Game server hostname |
| `--port` | `8080` | Game server port |
| `--name` | `pybot` | Bot player name shown in-game |
| `--brain` | off | Enable the LLM strategic brain |
| `--provider` | `bedrock` | LLM provider: `bedrock`, `anthropic`, or `openrouter` |
| `--model` | (default) | Override the LLM model name |
| `--debug` | off | Start the debugger GUI server |
| `--debug-port` | `9090` | WebSocket port for debug events (HTTP is +1) |

### Running Without the LLM

You can run the bot without any LLM calls — it will use its scripted decision
logic (task completion, body reporting, voting heuristics):

```sh
python3 -m sidecar.bot --name smartbot --debug
```

The debugger still works and shows the perception pipeline, intent changes,
and memory events. The Brain and LLM panels will be empty.

### Troubleshooting

**"Map data not loaded — localization will not work"**
Pillow is not installed, or the bot can't find `skeld2.aseprite`. Make sure
you run from `among_them/bot-policies/` and that Pillow is in your Python
environment.

**"Brain module not available"**
The `--brain` flag was set but the sidecar modules failed to import. Check that
boto3/httpx are installed and that `sidecar/prompts/system.md` exists.

**Debugger shows "Reconnecting..."**
The bot process isn't running, or the `--debug` flag was not passed. Check
that the bot is running and the debug port (default 9090) is not blocked.

**Game never starts**
The lobby needs `minPlayers` connected players. Check that enough Nim bots
are running. Use `--config:'{"minPlayers":3}'` for quick tests.

**Bot just stands still**
If the bot connects but doesn't move, it is probably not localized. Open the
debugger — the Game View panel will show what the bot sees, and the view
info bar will show `loc: no`. This usually means the map data didn't load.

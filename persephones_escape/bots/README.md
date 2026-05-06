# Bots

AI players for Persephone's Escape. All bots connect via WebSocket and receive the same 128x128 pixel frames as human players.

## Bot Types

### `llm_bot.ts` — LLM Bot
The primary bot. Uses Claude (via AWS Bedrock Converse API) to reason about game state and issue task commands. Maintains a continuous conversation with the LLM, injecting game state updates as harness blocks. The LLM responds with structured tool calls to update its task list. A task execution engine then translates high-level goals (e.g. "pursue_exchange with player X") into frame-by-frame button inputs.

```bash
npx tsx bots/llm_bot.ts --name llm_1 --url ws://localhost:8080/player --model sonnet --region us-west-2
```

### `winner_bot.ts` — Winner Bot
Hardcoded policy bot with no LLM. Approaches the nearest player, opens a whisper, and immediately offers/accepts role exchanges. Useful as a baseline or for testing role exchange mechanics.

### `smart_bots.ts` — Smart Bots
Scripted bots with role-aware heuristics. Used only in unit tests (not real games). They follow simple policies: approach players, form whispers, exchange information based on team alignment.

### `bots.ts` — Idle Bots
Minimal bots that connect and send idle inputs. Used to fill player slots without any gameplay logic.

## Shared Modules

### `game_knowledge.ts`
Tracks what the bot knows: match facts, roster-derived identity data, learned transient state, self state, strategy memory, and notes. Provides update helpers that parse frames into the shared `GameKnowledge` model used by policies, tasks, and LLM harness prompts.

### `tasks.ts`
Task execution engine. Translates high-level task definitions into button sequences each frame. Supports:
- `pursue_exchange` — walk to a target, open/join a whisper, then either exchange color, exchange role, or just establish the whisper
- `loop_auto_grant` — automatically grant whisper entry requests
- `loop_auto_accept_color` — automatically accept incoming color offers
- `open_whisper` — create or join a whisper near a target
- `move_to` — navigate to coordinates
- `shout` / `start_chat` — open global/whisper via comm menu

### `frame_parser.ts`
Parses the 128x128 pixel frame into structured data: player positions, sprites, minimap dots, HUD text, whisper occupants, hostage grid, chat messages.

### `bot_utils.ts`
Low-level utilities: frame unpacking, input sending, movement helpers, menu navigation sequences.

### `bot_common.ts`
Shared CLI argument parsing and the `BotController` interface.

### `policy.ts`
Policy evaluation layer for the LLM bot. The LLM sets persistent policies (movement targets, auto-responses) and the policy engine evaluates them every frame in priority order, independent of LLM response latency.

### `llm_harness.ts`
Formats game state into the harness block text that gets injected into the LLM conversation. Handles context like event descriptions, strategic context, and available actions.

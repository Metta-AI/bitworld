# Persephone's Escape

A social deduction game based on Two Rooms and a Boom, themed around the myth of Persephone. Players are split across two disjoint rooms (Underworld and Mortal Realm) and must communicate, trade information, and manipulate hostage swaps to achieve their team's win condition.

The game runs as a WebSocket server rendering 128x128 pixel frames to connected clients. See RULES.md for full game rules and GUIDE.md for the client interface.

## Architecture

```
coworld_manifest.json Coworld package manifest for certification
server.ts          WebSocket server — accepts player/global viewer connections
game/
  cogame_manifest.json Cogame manifest with config/results schemas
  sim.ts           Core game simulation (physics, phases, whispers, hostage logic)
  types.ts         Shared types (GameConfig, Phase, Role, Team, etc.)
  constants.ts     Game constants (FPS, dimensions, button codes)
  config_presets.ts Named config presets (tiny, short, medium, debug2r, etc.)
  menu_defs.ts     Menu definitions consumed by sim, renderer, and bots
  protocol.ts      Binary frame encoding/decoding
  util.ts          Shared utilities
rendering/
  renderer.ts      128x128 framebuffer renderer (world, whisper, info, shout views)
  framebuffer.ts   Pixel framebuffer with text/sprite drawing primitives
  globalViewer.ts  Global spectator view (all players, both rooms)
clients/           Browser clients served by /player, /global, and /replay
bots/              AI players (see bots/README.md)
player/            Coworld baseline player container entrypoint
tests/             Test harness and debug scripts
replay.ts          Binary replay recorder
```

## Running

```bash
# Start the game server
npx tsx server.ts --port=8080 --config=medium12

# Connect idle bots (fill seats)
npx tsx bots/bots.ts 12 ws://localhost:8080/player

# Run LLM bots via test harness
npx tsx tests/test_harness.ts --config medium12 --llm 12 --matches 1
```

## Coworld

Persephone's Escape includes Coworld/Cogame manifests and a separate tournament mode for the platform contract. Freeplay remains the default local mode. Tournament mode is selected automatically when `COGAME_CONFIG_PATH` is set, or explicitly with:

```bash
npx tsx server.ts --mode=tournament
```

Tournament configs must include `"mode": "tournament"` and runner-managed `tokens`. The Coworld manifest is `coworld_manifest.json`; the Cogame manifest is `game/cogame_manifest.json`. The upstream contract is documented in [Metta's Coworld spec](https://github.com/Metta-AI/metta/blob/main/packages/coworld/COWORLD_README.md).

## Game Flow

1. Players connect and enter a lobby
2. Once enough players join, the game starts with role assignment and room placement
3. Each round: players move, form private whispers, trade info (color/role reveals), and shout in room chat
4. Between rounds: leaders select hostages to swap rooms, then a leader summit occurs
5. After the final round: reveal phase determines the winner based on Hades/Persephone positioning and whether Cerberus/Demeter role exchanges occurred

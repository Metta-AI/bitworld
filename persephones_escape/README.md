# Persephone's Escape

A social deduction game based on Two Rooms and a Boom, themed around the myth of Persephone. Players are split across two disjoint rooms (Underworld and Mortal Realm) and must communicate, trade information, and manipulate hostage swaps to achieve their team's win condition.

The game runs as a WebSocket server rendering 128x128 pixel frames to connected clients. See RULES.md for full game rules and GUIDE.md for the client interface.

## Architecture

```
server.ts          WebSocket server — accepts player/global viewer connections
game/
  sim.ts           Core game simulation (physics, phases, whispers, hostage logic)
  types.ts         Shared types (GameConfig, Phase, Role, Team, etc.)
  constants.ts     Game constants (FPS, dimensions, button codes)
  config_presets.ts Named config presets (tiny, short, medium, debug2r, etc.)
  menu_defs.ts     Menu definitions consumed by sim, renderer, and bots
  protocol.ts      Binary frame encoding/decoding
  util.ts          Shared utilities
rendering/
  renderer.ts      128x128 framebuffer renderer (world, whisper, info, global chat views)
  framebuffer.ts   Pixel framebuffer with text/sprite drawing primitives
  globalViewer.ts  Global spectator view (all players, both rooms)
bots/              AI players (see bots/README.md)
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

## Game Flow

1. Players connect and enter a lobby
2. Once enough players join, the game starts with role assignment and room placement
3. Each round: players move, form private whispers, trade info (color/role reveals), shout in global chat
4. Between rounds: leaders select hostages to swap rooms, then a leader summit occurs
5. After the final round: reveal phase determines the winner based on Hades/Persephone positioning and whether Cerberus/Demeter role exchanges occurred

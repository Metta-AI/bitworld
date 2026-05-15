# Stag Hunt Bot Debugging & Improvement Prompt

## Context

You're working on `/Users/malcolm/dev/bitworld/stag_hunt`. This is a cooperative hunting game where players surround prey on cardinal sides to capture them. The game uses a sprite_v1 protocol over WebSocket (not a framebuffer).

### Capture rules
- Rabbit: 1 player on any cardinal side
- Boar: 2 players on perpendicular sides (L-shape)
- Stag: 2 players on opposing sides (N+S or E+W)
- Moose: 3+ cardinal sides occupied
- Elephant: all 4 cardinal sides

### Key server constants (in stag_hunt.nim)
- PlayerMoveCooldownTicks = 5 (server only moves a player every 5 frames at 24fps)
- World is 32x32 tiles, tile size 12px, viewport 128x128px
- Indicator dots (yellow) show which empty sides would help complete a capture

### Indicator dot logic (already in server)
The server shows dots on tiles adjacent to prey where a player stepping there would help complete a capture. The number of dots shows how many MORE players are needed. This is computed by `validIndicatorSides` in stag_hunt.nim. **Verify**: with 2 players next to an elephant, remaining sides should show 2-dot indicators (need 2 more), not 3-dot. Check `addIndicatorObjects` — it uses `preyMinPlayers(kind) - occupied` for the dot count, which should already be correct (4-2=2 dots).

### Bot architecture
Each bot connects as a WebSocket client to `/player?name=botname`. The server sends sprite_v1 frames (sprite definitions + object placements). Bots parse these to derive:
- Camera position (from background tile objects)
- Self position (from identity packet 0x07 + matching PlayerSight)
- Visible prey (from PreyObjectBase range, sprite id tells kind)
- Visible players (from PlayerObjectBase range)

Bots send a 2-byte input packet: `[0x84, mask]` where mask has bits for U/D/L/R.

### The bugs observed
1. **Bots stand still** — even with prey visible, bots don't pursue
2. **Bots cluster near walls** — explore logic should push them toward center but doesn't seem to work
3. **Bots don't exploit indicator dots** — when a yellow dot is right next to them (meaning "step here to help capture"), they ignore it

### Known fixed issue
The stuck detection thresholds were too low (2/5 frames) given the server's 5-frame move cooldown. They've been bumped to 12/24. But the bots STILL aren't pursuing prey, which suggests a deeper issue.

### Suspected root causes to investigate
1. **Camera derivation might be wrong** — if `updateCamera`/`deriveCamera` computes wrong cameraX/cameraY, all tile positions are wrong and bots think they're somewhere they're not
2. **Identity packet timing** — the 0x04 (clear objects) resets selfObjectId to -1, then 0x07 sets it again. If the bot processes clear but doesn't process identity in the same packet, it might think it has no self
3. **Prey tile rounding** — prey sprites jitter during alertFlash. The bots round to nearest tile but maybe incorrectly
4. **The `stepMask`/`moveMaskTowards` function** — maybe it returns 0 in edge cases

## Approach: Test each bot type in isolation

### Phase 1: Rabbiteer (simplest)
1. Kill all bots. Start server + just 1 rabbiteer.
2. Manually connect a browser client to see the world.
3. Watch rabbiteer's stdout debug output (remove `> /dev/null`).
4. Check: does it correctly identify its position? Does it see rabbits? Does it output a non-zero mask toward them?
5. If it's outputting correct masks but not moving: the issue is server-side (input not being applied, or the mask format is wrong).
6. If it's not seeing prey: camera derivation is broken.

Run: `./out/rabbiteer --port:8090 --name:rabbiteer 2>&1 | head -100`

### Phase 2: Stag hunter (needs another player)
1. Start rabbiteer + stag_hunter together.
2. Watch stag_hunter output — does it find stags? Does it see allies?

### Phase 3: Sidekick (needs another player to follow)
1. Start with rabbiteer + sidekick.
2. Does sidekick follow rabbiteer?

## Key improvement: "Step into indicator dot" heuristic

Add to ALL bots: before any other decision, check if there's a visible indicator dot object adjacent to self. Indicator objects use:
- ObjectId range: IndicatorObjectBase (9000) + preyIndex*4 + sideOrd
- Sprites: IndicatorSpriteBase (20), 21, 22

If the bot sees an indicator object on an adjacent tile (1 dot = instant capture!), it should immediately step there. This is a universal win — any bot benefits from this regardless of strategy.

Implementation: scan objects in range 9000-9999 for indicator sprites (id 20-22). Convert their screen position to world tile. If any is cardinally adjacent to self, step there. Prefer 1-dot indicators (immediate capture).

## Files

- Server: `stag_hunt/stag_hunt.nim`
- Bots: `stag_hunt/players/{coordinator,nearest_hunter,rabbiteer,sidekick,stag_hunter}/<name>.nim`
- Protocol: `common/protocol.nim` (button constants, InputState)
- Server framework: `common/server.nim` (Facing, TransparentColorIndex, Framebuffer)

## Build & run

```bash
# Compile
nim c -d:release -o:out/stag_hunt stag_hunt/stag_hunt.nim
nim c -d:release -o:out/rabbiteer stag_hunt/players/rabbiteer/rabbiteer.nim
# etc for each bot

# Run server
./out/stag_hunt --port:8090 --address:0.0.0.0

# Run one bot with visible output
./out/rabbiteer --port:8090 --name:rabbiteer

# Browser client
# http://localhost:8090/player
```

## Deliverables

1. Identify and fix why bots aren't pursuing prey
2. Add "step into indicator dot" heuristic to all bots
3. Verify indicator dot count is correct (2 of 4 sides occupied on elephant = 2 dots, not 3)
4. Make bots avoid lingering near walls when not actively chasing
5. Report back: what was actually broken, what you fixed, general architectural observations

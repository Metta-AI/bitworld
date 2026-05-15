# Asteroid Arena

Multiplayer arcade game with cooperative objectives. Players pilot ships,
destroy asteroids, and compete for score in a wrapping 256x256 world.

## Objectives

### Standard Asteroids

Grey asteroids spawn continuously. Any player can destroy them solo with
bullets. Scoring per asteroid size:

- Small: 1 point
- Medium: 2 points
- Large: 4 points

### Cooperative Asteroids (Red)

Red asteroids require hits from 2 different players to break. A single
player's bullets register but don't destroy it. Once a second player lands
a hit, the asteroid breaks and both players score:

- Each player receives `asteroidScore * coopScoreMultiplier / 100`
- Default multiplier is 150 (1.5x per player, 3x total vs solo)
- Fragments from red asteroids remain red (also require cooperation)

### Capture Points (Planets)

Static planets are placed at game start. They never despawn. Each planet
spawns with a random body radius (8-14 pixels) and a capture radius at
2.5x its body size. Bullets and asteroids that hit the planet body are
destroyed. Ships fly over planets freely.

**Capturing (neutral planet):**
- 2 or more players must be within capture radius simultaneously
- Progress builds 1 tick per frame while 2+ players are in range
- A single player in range does nothing
- Progress decays when no one is in range
- Once progress reaches the threshold, all players in range become owners
- Owners receive an immediate capture bonus

**Holding (owned planet):**
- Owners score periodically while the planet is held
- Score scales with planet size: `captureScore * radius / minRadius * coopScoreMultiplier / 100`
- A max-size planet (radius 14) gives 1.75x the score of a min-size planet (radius 8)

**Losing ownership:**
- When a player dies, they are removed from all planets they own
- If the last owner dies, the planet becomes neutral immediately
- This means killing all owners is a valid strategy to free a planet

**Contesting (taking an owned planet):**
- Contesters must outnumber defenders currently in range
- Minimum 2 contesters required regardless of defender count
- Owners defend by staying in range — 1 defender blocks 1 attacker
- Once progress reaches zero, the planet becomes neutral again
- The planet must be fully neutral before new players can capture it

## Ship Controls

- Up: thrust forward
- Down: reverse thrust
- Left/Right: rotate facing
- A: fire
- B: brake

## Configuration

All values configurable via JSON config:

| Field | Default | Description |
|-------|---------|-------------|
| `seed` | 677410 | Random seed |
| `duration` | 90 | Game duration in seconds (0 = infinite) |
| `coopSpawnPercent` | 50 | Percent of large asteroids that spawn as cooperative (red) |
| `coopScoreMultiplier` | 150 | Percent multiplier for cooperative scoring (150 = 1.5x) |
| `planetCount` | 3 | Number of capture point planets |

## Running

```bash
cd asteroid_arena
../out/asteroid_arena --address:0.0.0.0 --port:8080 --duration:0
```

Open `http://localhost:8080/global` to spectate.

## Endpoints

| Path | Purpose |
|------|---------|
| `/global` | Spectator view (full 256x256 world) |
| `/sprite_player` | Player view (128x128 centered on ship) |
| `/player` | Player view (alias for sprite_player) |
| `/admin` | Admin view (same as global) |
| `/replay` | Replay playback view |
| `/reward` | Text score stream |
| `/healthz` | Container health check |

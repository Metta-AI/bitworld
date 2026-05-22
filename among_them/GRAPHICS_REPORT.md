# Among Them — Graphics & View Rendering Report

A reference for writing a pixel-parser that converts an agent's screen into a
symbolic view.

---

## 1. High-level architecture

The server (`among_them/sim.nim`) owns the authoritative world state and renders
each agent's personal 128×128 view server-side every tick. The client
(`client/player_client.nim`) only decodes and displays a ready-made
framebuffer — it does no game logic. The frame crosses the wire as a **4bpp
packed byte array** (8192 bytes = 128·128/2), so every pixel parser starts by
unpacking two 4-bit palette indices per byte.

Tick rate: **24 FPS**. Frame protocol constants are in `common/protocol.nim:4-17`.

---

## 2. The framebuffer (screen) format

- **Resolution:** 128×128 pixels (`ScreenWidth=ScreenHeight=128`).
- **Palette:** 16 fixed colors, indexed 0–15, loaded once from
  `client/data/pallete.png` (16×1, RGBA). Palette table lives in
  `common/protocol.nim:31-42`.
- **Packing:** The server fills `Framebuffer.indices` (128·128 bytes, one 4-bit
  index per pixel), then `packFramebuffer` packs two pixels per byte: low
  nibble = even x, high nibble = odd x (`common/server.nim:171-175`). Pixel at
  `(x,y)` ⇒ byte `(y*128 + x)/2`; low nibble if `x` even, high nibble if `x` odd.
- **Transparent sentinel:** index `255` means "don't draw" inside sprite data
  only — it never appears in a finished frame.

### 2.1 The 16-color palette (logical names, from `sim.nim:96-131` and `ShadowMap`)

```
 0 black        1 gray         2 white        3 red
 4 pink         5 dark brown   6 brown        7 orange
 8 yellow       9 dark teal   10 green       11 lime
12 dark navy   13 blue        14 light blue  15 pale blue
```

These names come from `ShadowMap`'s comments. They are also the pool
`PlayerColors` permutes over to pick per-player tints (`sim.nim:96-113`):

```
PlayerColors = [3, 7, 8, 14, 4, 11, 13, 15, 1, 2, 5, 6, 9, 10, 12, 0]
  = red, orange, yellow, light-blue, pink, lime, blue, pale-blue,
    gray, white, dark-brown, brown, dark-teal, green, dark-navy, black
```

Player N's color is `PlayerColors[joinOrder mod 16]`.

### 2.2 Special color constants

| Name             | Index | Role (`sim.nim:33-68`)                                   |
| ---------------- | ----- | -------------------------------------------------------- |
| `SpaceColor`     | 0     | Background / "space outside the map" fill                |
| `MapVoidColor`   | 12    | Fill when agent's camera view goes past map bounds       |
| `TintColor`      | 3     | Sprite-pixel wildcard → replaced by player color         |
| `ShadeTintColor` | 9     | Sprite-pixel wildcard → replaced by `ShadowMap[tint]`    |
| `OutlineColor`   | 0     | Character outlines (black)                               |
| `TextColor`      | 2     | UI text (white)                                          |
| `ProgressEmpty`  | 1     | Task bar empty cell (gray)                               |
| `ProgressFilled` | 10    | Task bar filled cell (green)                             |

`ShadowMap[i]` darkens any palette color for shadowed tiles
(`sim.nim:114-131`). A shadowed tile `c` is replaced with
`ShadowMap[c & 0xF]`. This is reversible: you can detect "was this tile in
light or shadow?" by checking whether a pixel's palette index is in
`ShadowMap`'s range.

---

## 3. World & map data

### 3.1 Map geometry (`sim.nim:19-20`)

- **World dimensions:** 952×534 pixels. This is the Skeld level.
- **Map source:** `among_them/skeld2.aseprite`, three layers selected by JSON
  (`map.json`):
  - **Layer 0 — `map`:** rendered RGB image, converted to palette indices
    (`sim.mapPixels[MapWidth*MapHeight]`).
  - **Layer 1 — `walk`:** alpha mask → `sim.walkMask[]` (walkable floor).
  - **Layer 2 — `walls`:** alpha mask → `sim.wallMask[]` (shadow casters and
    line-of-sight blockers).
- Code: `loadMapLayers` (`sim.nim:673-688`); mask construction
  (`sim.nim:2997-3007`).

### 3.2 Entities attached to the map (`map.json`)

- **Emergency button rect** `{x:524,y:114,w:28,h:34}` — attack action inside
  this rect opens a meeting if `buttonCallsUsed < buttonCalls`.
- **Meeting home point** `(536,120)` — where everyone teleports back to after
  a meeting; spawn ring of radius 28 around it (`sim.nim:1046-1058`).
- **40 task stations** — each a 16×16 world rect with a name (e.g.
  `"Fix Wires"`, `"Fuel Engines"`). See full list in `map.json`. The action
  rect is exactly where an attack press counts as "doing the task".
- **15 vents** — each 12×10, grouped A–F, indexed 1..N. Vent teleport cycles
  through the group in order.
- **27 named rooms** — non-overlapping axis-aligned rects covering the floor.
  These are purely for bot/AI labeling and chat; they are *not* rendered into
  pixels.

### 3.3 Motion & collision (`sim.nim:8-60`, `applyMomentumAxis`)

- Player hitbox: `CollisionW × CollisionH = 1×1` (a single tile, yes really).
- Sprite vs hitbox offset: `SpriteDrawOffX=2, SpriteDrawOffY=8`. Draw position
  of player sprite = `(player.x - 2, player.y - 8)`.
- Internally velocities use subpixel `motionScale=256`, `accel=76`,
  `friction=144/256`, `maxSpeed=704`.

---

## 4. Sprites

### 4.1 Sprite sheet (`among_them/spritesheet.png`, 128×128, palette-indexed)

A single horizontal strip of **12×12 cells** (`SpriteSize=12`). Only the
columns shown are actually used — loaded in `initSimServer` at
`sim.nim:2954-2975`:

| X column | Sprite field       | Used as                                                     |
| -------- | ------------------ | ----------------------------------------------------------- |
| 0        | `playerSprite`     | Living player (crewmate silhouette)                         |
| 12       | `bodySprite`       | Corpse (dead player on ground / voting icon when eliminated)|
| 24       | `boneSprite`       | (loaded but never blitted in current code)                  |
| 36       | `killButtonSprite` | Bottom-left HUD icon for imposters; shadowed while on cooldown |
| 48       | `taskIconSprite`   | Bobbing exclamation-mark icon above a task station          |
| 60       | (skipped)          | —                                                           |
| 72       | `ghostSprite`      | Dead player's floating ghost (viewer-is-ghost only)         |
| 84       | `ghostIconSprite`  | Bottom-left HUD icon when the viewer is a ghost             |

All sprites are 12×12 pixels of palette-indexed data.
`TransparentColorIndex (255)` cells don't draw.

### 4.2 How an actor sprite is tinted (`blitSpriteOutlined`, `sim.nim:1659-1673`)

For each opaque pixel `c` in the sprite:

- `c == TintColor (3)` → replaced by the player's `color`.
- `c == ShadeTintColor (9)` → replaced by `ShadowMap[color & 0xF]` (darker
  shade of the player color).
- Otherwise → `c` drawn literally (usually white `2`, black `0`, red `3` for
  the visor).

Result: **a parser can detect a player by matching the fixed (non-wildcard)
pixels of the sprite (outline, visor, backpack hint) and read the dominant
tint-pixel color to recover the player's palette index** — exactly what
`nottoodumb.nim:1315-1343` does (`crewmateColorIndex` and `matchesCrewmate`).

### 4.3 Flipping

Players have `flipH`: set to `true` when moving left, `false` when moving
right (`sim.nim:1604-1607`, `1516-1517`). Flipped = sprite mirrored on X. The
parser must try both orientations.

---

## 5. Fonts / text rendering

### 5.1 Tiny UI font — `among_them/tiny5.aseprite`

Loaded once (`sim.nim:2952`) into `PixelFont`. Decoder is in
`common/pixelfonts.nim:90-142`:

- **Source format:** Aseprite/PNG with each glyph stacked left-to-right; a
  **yellow marker row** in the last image row marks each glyph's width (pixel
  is yellow iff `r>180 & g>160 & b<120`).
- **Glyphs:** printable ASCII 32..126 (`PrintableAsciiCount=95`). Each glyph
  is variable-width, height = `image.height - 1`.
- **Kerning:** fixed 1-pixel spacing between glyphs (`DefaultGlyphSpacing=1`).
- **Color:** always palette index `2` (white) when drawn by the sim
  (`TextColor=2`).
- **Line height constant used by chat/UI:** `TextLineHeight = 7`.

`PixelFont` supplies `textWidth`, `glyphAdvance`, `drawText`, and critically
also **OCR helpers** (`bestGlyph`, `readRun`, `findText`) which already
implement "read a variable-width glyph at (x,y) against a uniform
background" — exactly the tool you want to plug straight into a parser.

### 5.2 Where text appears on screen

| Phase / item       | Text content                                                               | Approx position            |
| ------------------ | -------------------------------------------------------------------------- | -------------------------- |
| Lobby              | `"WAITING"` at (11,4), `"NEED MORE!"` at (2,14) or `"READY!"` at (14,14)   | top                        |
| RoleReveal         | `"IMPS"` or `"CREWMATE"` centered at y=14                                 | top                        |
| Playing (HUD)      | remaining-tasks count (just digits)                                        | right-justified at y=0     |
| VoteResult         | `"NO ONE"` @ (46,54), `"DIED"` @ (52,64) when no eject                    | center                     |
| GameOver           | `"DRAW"` / `"CREW WINS"` / `"IMPS WIN"` centered at y=2 + per-player `"CREW"` / `"IMP"` rows | full screen        |
| Vote screen        | `"SKIP"` label centered below the grid                                     | variable                   |
| Vote chat          | up to `VoteChatVisibleMessages=6` chat rows, each a 12×12 player icon at x=1 + wrapped text starting at x=14, wrapped at `VoteChatTextPixels = 128 − 14 − 1 = 113` pixels, `VoteChatCharsPerLine=32`, `VoteChatLineCount=10`, `VoteChatMaxChars=320` | lower half |

All of these use the same tiny5 font on palette-2 white over black
(`SpaceColor=0`).

### 5.3 Other image-font files

- `among_them/ascii.png` and `client/data/ascii.png` (126×54) are a
  **separate** chat ASCII sprite sheet used only by the *native* desktop
  client for typing into the chat input box (7×9 cells, `ChatGlyphW=7,
  ChatGlyphH=9, ChatRowStride=9` — `client/player_client.nim:56-62`). It is
  drawn *on top of* the 128×128 framebuffer, **not inside it**, so a pixel
  parser that consumes only the server-sent 8192-byte frame never sees these
  glyphs.
- `among_them/vanta9.*` and `among_them/skeld.aseprite` are legacy assets
  (not loaded by the current code path).

---

## 6. The agent's view — what the server actually paints

Server dispatcher: `SimServer.render(playerIndex)` in `sim.nim:2632-2815`. The
six game phases each produce a very different 128×128 image. Parser must
first determine phase.

### 6.1 Phase enum values (`sim.nim:143-149`)

`Lobby=0, Playing=1, Voting=2, VoteResult=3, GameOver=4, RoleReveal=5`.

### 6.2 Phase `Lobby` — `buildLobbyFrame`

- Clear to color 0.
- `"WAITING"` at (11,4), `"NEED MORE!"` or `"READY!"` at y=14.
- Player icons in a 6-wide grid starting at (5,26), 9-pixel stride:
  `(5 + col*9, 26 + row*9)`, each is a `playerSprite` tinted with that
  player's color.

### 6.3 Phase `RoleReveal` — `buildRoleRevealFrame`

- Clear 0.
- Title `"IMPS"` (if viewer is imposter) or `"CREWMATE"` centered at y=14.
- Then a row of icons: if imposter, only imposters are shown; else all
  players. Cell 16×18, starting y=42, centered horizontally; each cell: a
  `playerSprite` at `(startX + col*16 + 2, startY + row*18)`.

### 6.4 Phase `Playing` — the main game view (the one agents actually navigate in)

This is the only phase with real world vision. Pipeline:

1. **Clear** to `MapVoidColor=12`.
2. **Camera:** centered on player sprite center:

   ```
   cameraX = (player.x - SpriteDrawOffX) + SpriteSize/2 - ScreenWidth/2
           = player.x - 2 + 6 - 64 = player.x - 60
   cameraY = player.y - 8 + 6 - 64 = player.y - 66
   originMx = player.x + 0 (since CollisionW=1, /2=0)
   originMy = player.y
   viewerIsGhost = not player.alive
   ```

   So **the agent stands approximately at screen (60, 66)** and the visible
   world window is `[cameraX, cameraX+128) × [cameraY, cameraY+128)`.
3. **Blit static map pixels** for every `(x,y)` where
   `(cameraX+x, cameraY+y)` is inside `[0,952)×[0,534)`, copying
   `sim.mapPixels[mx,my]` directly. Everything else stays `MapVoidColor=12`.
4. **Shadow (line-of-sight) pass — `castShadows`:**
   - Origin is the player's (x,y) in world coords.
   - For each screen pixel, a **Bresenham-like integer raycast** from
     `(originMx, originMy)` to `(mx, my)` with `steps = max(|dx|,|dy|)` marks
     the pixel shadowed **iff any step hits a wall** (`sim.wallMask[mx,my]`
     true).
   - Walls themselves are **not** darkened (you can still see the wall edge),
     only floor/empty tiles behind walls are (`sim.nim:2666-2679`).
   - **Only living viewers are shadowed; ghosts see the whole world with no
     LOS restriction** (`view.viewerIsGhost`).
   - Effective view radius: there is **no circular cap** — LOS extends the
     full 64 pixels to each edge of the 128×128 window. The only cutoff is
     the screen itself.
5. **Shadowed floor pixels** are recolored via `ShadowMap[idx & 0xF]` (so
   "shadow" is not a separate color channel — it's a remapping inside the
   same 16-color palette).
6. **Visible bodies** (corpses): each `Body{x,y,color}` is drawn with
   `bodySprite` tinted, iff the body's center is on-screen AND unshadowed (or
   the viewer is a ghost).
7. **Visible players:** sorted bottom-up by world y for correct overlap; each
   player drawn with `playerSprite` tinted `p.color`, flipped by `p.flipH`.
   Self is always drawn; others only if their center pixel passes
   `screenPointVisible`. Dead players drawn with `ghostSprite` if and only if
   viewer is a ghost; otherwise invisible.
8. **Task icons (crewmates only):** for every assigned, incomplete task, if
   the icon sprite rect intersects the screen, blit `taskIconSprite` at
   `(task.cx - 6, task.y - 12 + bobY)`, where

   ```
   bob cycle = [0,0,-1,-1,-1,0,0,1,1,1]   indexed by (tickCount/3) mod 10
   ```

   (`bobY=0` while the player is actively doing that task). If the icon is
   off-screen AND `showTaskArrows=true`, a single pixel of color 8 (yellow)
   is drawn on the edge of the screen in the direction of the task (like a
   compass pip).
9. **Active task progress bar:** centered below the icon, `TaskBarWidth=14`
   pixels, `TaskBarGap=1` below the icon. Filled cells use color 10 (green /
   `ProgressFilled`), empty use 1 (gray / `ProgressEmpty`).
10. **HUD corner icon** at
    `(1, ScreenHeight - SpriteSize - 1) = (1, 115)`:
    - Ghost viewer: `ghostIconSprite` (raw).
    - Living imposter: `killButtonSprite`. If `killCooldown > 0` it is drawn
      *shadowed* via `blitSpriteShadowed` (every pixel remapped through
      `ShadowMap`); otherwise drawn raw. **This single sprite reveals both "I
      am the imposter" and the kill cooldown state.**
    - Crewmate: no HUD icon.
11. **Top-right remaining-task counter:** digits of `totalTasksRemaining()`
    drawn right-justified at y=0 with tiny5, color 2.

Note on colors:

- Light blue crewmates are palette 14; this **looks identical** to the map's
  `MapVoidColor=12` darkened only through the `ShadowMap[14]=12` shadow
  mapping — so a shadowed dark-navy or light-blue crewmate body silhouette
  becomes indistinguishable from void. `ShadowMap` makes palette entries
  1/13/14 → 12, meaning a dark area has ambiguous provenance; the parser
  should use the wall mask / shadow geometry, not raw color, to decide.

### 6.5 Phase `Voting` — `buildVoteFrame` (`sim.nim:1950-2047`)

- Clear 0.
- Grid of player cells: `cellW=16, cellH=17`, up to 8 columns, `startY=2`,
  horizontally centered:
  - Alive player: `playerSprite` tinted at `(cellX + 2, cellY + 1)`.
  - Dead player: `bodySprite` tinted instead.
  - The viewer gets a **"self marker"** drawn 2 pixels above the cell:
    `putSelfMarker` paints a 2-pixel dot using the viewer's color (special
    case for black).
  - The cursor cell (the candidate this viewer is selecting) gets a
    **1-pixel white border** (color 2) around the whole cell.
  - **Vote dots:** for every voter who has already voted for *this* target,
    a 1×1 dot of the voter's color is drawn in a compact row at
    `(cellX + 1 + (i%8)*2, cellY + SpriteSize + 2 + i/8)` (`putVoteDot`, with
    black-voter special case using colors 12+2).
- `"SKIP"` label centered below the grid. Voters who voted skip put their
  dots to the right of it.
- Chat area beginning at `skipY + 10`, drawn by `drawVoteChat` (player icon
  at x=1, text starting at x=14, wrapping, newest at bottom).
- **Vote timer bar** — a 2-pixel-tall bar along y=126–127, width =
  `ScreenWidth − 4 = 124`, filled proportionally with color 10, empty with
  color 1.

### 6.6 Phase `VoteResult` — `buildResultFrame`

- Clear 0.
- If someone was ejected: their `playerSprite` drawn **centered** at
  `(62, 62)` (screen-center minus 6).
- If tie/skip: text `"NO ONE"` (46,54) and `"DIED"` (52,64).

### 6.7 Phase `GameOver` — `buildGameOverFrame`

- Clear 0.
- Title centered at y=2.
- Two-column list of players (up to 8 per column). Each row `rowH=14`, col
  width = 64 (ScreenWidth/2):
  - 12×12 player icon at `(col*64 + 4, rowY + 1)`.
  - Text `"IMP"` or `"CREW"` at `(col*64 + 19, rowY + 4)`.
  - **Strikethrough:** for dead players, a horizontal line of color 3 (red)
    at `y + 3` across the width of the role text.

---

## 7. Line-of-sight and visibility summary

**There is no view radius.** The visible window is always the full 128×128,
centered on the agent. Visibility further restrictions:

1. **Outside 952×534 world rect →** painted `MapVoidColor=12`.
2. **Walls between agent and target (LOS) →** the floor/ground is shadowed
   (recolored via `ShadowMap`); the wall itself is not. `castShadows` uses
   integer ray steps with `max(|dx|,|dy|)` — same algorithm in both render
   and `screenPointVisible` filter.
3. **Other entities (players, bodies) need their center tile unshadowed** —
   otherwise they are not drawn at all (`sim.nim:2685-2708`).
4. **Ghosts bypass 1–3 for the sprite-visibility check** but still observe
   the same `MapVoidColor` outside-bounds behavior. Ghosts can also see other
   dead players' ghost sprites (living viewers cannot).
5. **Screen clipping:** anything whose drawn rect intersects the 128×128 view
   is painted, clipped by `putPixel` bounds checks in
   `common/server.nim:105-108`.

Practical implication for a symbolic parser: the agent observes roughly a
Chebyshev-distance-64 square window (128/2=64 each side) of the map, further
carved down by raycast shadows, and its own sprite center is at screen
`(60, 66)`. Walls are always visible even when surrounded by shadow (useful
for mapping).

---

## 8. Map of pixel → symbol for a parser

Given an unpacked `frame[128*128]` of palette indices and assuming you also
have access to the static map assets, the parser can reconstruct a rich
symbolic view:

1. **Determine phase**
   - Search for distinctive glyph runs using `pixelfonts.findText`
     (`"WAITING"`, `"IMPS"`, `"CREWMATE"`, `"SKIP"`, `"CREW WINS"`,
     `"IMPS WIN"`, `"DRAW"`, `"NO ONE"`).
   - If none match, and the bottom-right shows only digits plus no grid-of-
     icons, you are in `Playing`.

2. **In Playing — localize the camera**
   - Look at the cross-hair of the agent at screen `(60, 66)` where
     `playerSprite` must be drawn (always on top). The pixel-accurate player
     sprite extends from `(58, 60)` to `(69, 71)`. Match the `playerSprite`
     outline (index 0 / `OutlineColor`) against the frame at that location.
   - From the visible tile colors, correlate a 32×32 grid of sample points
     against `sim.mapPixels` — this is exactly what `bench_scan.nim` does:
     `PatchSize=8`, `PatchGridW=16, PatchGridH=16`, hashing 8×8 patches and
     voting for `(cameraX, cameraY)`. This recovers global world
     coordinates.
   - Cross-check with the static rooms table in `map.json` to assign a room
     name.

3. **Parse non-self players / bodies / ghosts**
   - Iterate candidate screen positions. For each candidate `(x,y)` and each
     `flipH`, match the sprite's stable (non-wildcard-3/9) pixels against
     the frame (`crewmatePixelMatches`, `nottoodumb.nim:1309-1313`).
   - Among matching positions, count histogram of frame colors at the
     wildcard-3 pixels → dominant color = player color index →
     `PlayerColors.find` recovers the player slot.
   - Body = `bodySprite`, Ghost = `ghostSprite`, each with the same tint
     scheme.

4. **Parse HUD icon at (1,115)**
   - Match `killButtonSprite` (raw vs shadowed variant via `ShadowMap[c]`
     remap) → imposter + cooldown flag.
   - Match `ghostIconSprite` → viewer is a ghost.
   - Neither → crewmate.

5. **Parse task icons**
   - Match `taskIconSprite` (plain, no tinting) at any of the 40 known task
     positions minus `cameraY`, across the 10-element bob cycle — cheap. If
     found, that task is assigned + incomplete + visible.
   - A single yellow (color 8) pixel on the screen border = off-screen task
     arrow; reverse the line to find direction.
   - 14-pixel bar of alternating colors 1/10 directly beneath a task icon =
     active task progress.

6. **Parse top-right digits** with `pixelfonts.readRun` → remaining task
   count.

7. **Parse voting / game-over screens** using the known cell grids (see
   §6.5/§6.7) — each 16×17 cell gives you one player's
   alive/dead/selected/voted-for state, plus the color from the sprite's
   tint pixels.

All sprite data needed for matching is in `among_them/spritesheet.png`, all
font data in `among_them/tiny5.aseprite`, and all palette data in
`client/data/pallete.png`. The map and its masks live in
`among_them/skeld2.aseprite` (layers 0/1/2) and the symbolic annotations
(task names, rooms, vents, button, home) live entirely in
`among_them/map.json`.

---

## 9. Files to consult in-code

| Concern                                      | File                                                 |
| -------------------------------------------- | ---------------------------------------------------- |
| Frame protocol, palette, 4bpp packing        | `common/protocol.nim`, `common/server.nim`           |
| Tiny font OCR helpers                        | `common/pixelfonts.nim`                              |
| All sim rendering (authoritative)            | `among_them/sim.nim:1659-2815`                       |
| Map JSON schema & loader                     | `among_them/sim.nim:494-688`, `among_them/map.json`  |
| Client that displays frames                  | `client/player_client.nim`                          |
| Reference pixel parser                       | `among_them/players/nottoodumb.nim` (sprite match, camera lock via patch voting, radar parsing, vote-screen reader) |
| Map-scan benchmark for camera localization   | `among_them/bench_scan.nim`                          |

With these you have every parameter needed — palette, screen size, sprite
offsets, LOS algorithm, tint algorithm, task/vent/room rects, HUD icon
positions — to convert an 8192-byte server frame into
`{phase, (worldX,worldY), roomName, visiblePlayers[{color,x,y,flipH,state}],
visibleBodies[], visibleTaskIcons[{taskId}], hudRole, killCooldown,
remainingTasks, activeProgress, ...}`.

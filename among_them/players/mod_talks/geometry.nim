## Coordinate / camera math.
##
## Pure functions: world↔screen, camera bounds, room and task lookup, and
## the camera↔patch-vote-index conversions used by the localizer's
## patch-hash table.
##
## Phase 1 port from v2:406-504. Notable adaptations:
##
## - `playerWorldX/Y` and `roomName` take `Perception` instead of `Bot` —
##   they read camera state plus a `localized` flag, and that's exactly
##   what `Perception` exposes.
## - The geometry constants (`PlayerScreenX/Y`, `PlayerWorldOffX/Y`)
##   live here because they are derived from screen + sprite geometry and
##   are read by every layer above (frame, localize, actors). Exported.
## - The `<` PatchEntry / `cmpPatchCandidate` comparators stay with the
##   localizer (`localize.nim`) where they are exclusively used.

import protocol
import ../../sim
import types

const
  PlayerScreenX* = ScreenWidth div 2
  PlayerScreenY* = ScreenHeight div 2
  PlayerWorldOffX* = SpriteDrawOffX + PlayerScreenX - SpriteSize div 2
  PlayerWorldOffY* = SpriteDrawOffY + PlayerScreenY - SpriteSize div 2

proc mapIndexSafe*(x, y: int): int =
  ## Returns the map pixel linear index. The "safe" name is preserved
  ## from v2 even though no bounds-check is performed; callers use
  ## `inMap` first when needed.
  y * MapWidth + x

proc minCameraX*(): int =
  ## Smallest possible centred camera X (allows half-screen + sprite
  ## overhang off the left edge).
  -ScreenWidth div 2 - SpriteSize

proc maxCameraX*(): int =
  ## Largest possible centred camera X.
  MapWidth - ScreenWidth div 2 + SpriteSize

proc minCameraY*(): int =
  ## Smallest possible centred camera Y.
  -ScreenHeight div 2 - SpriteSize

proc maxCameraY*(): int =
  ## Largest possible centred camera Y.
  MapHeight - ScreenHeight div 2 + SpriteSize

proc cameraIndex*(x, y: int): int =
  ## Returns the linear vote-table index for one camera offset. Used by
  ## the patch-hash table in `localize`.
  (y - minCameraY()) * (maxCameraX() - minCameraX() + 1) +
    (x - minCameraX())

proc cameraIndexX*(index: int): int =
  ## Returns the camera X coordinate for one vote-table index.
  minCameraX() + index mod (maxCameraX() - minCameraX() + 1)

proc cameraIndexY*(index: int): int =
  ## Returns the camera Y coordinate for one vote-table index.
  minCameraY() + index div (maxCameraX() - minCameraX() + 1)

proc buttonCameraX*(sim: SimServer): int =
  ## Initial camera X guess centred on the emergency button. Used as
  ## the seed for spiral search before the first lock.
  let button = sim.gameMap.button
  clamp(
    button.x + button.w div 2 - PlayerWorldOffX,
    minCameraX(),
    maxCameraX()
  )

proc buttonCameraY*(sim: SimServer): int =
  ## Initial camera Y guess centred on the emergency button.
  let button = sim.gameMap.button
  clamp(
    button.y + button.h div 2 - PlayerWorldOffY,
    minCameraY(),
    maxCameraY()
  )

proc cameraXForWorld*(x: int): int =
  ## Camera X that centres one world X on the player.
  clamp(x - PlayerWorldOffX, minCameraX(), maxCameraX())

proc cameraYForWorld*(y: int): int =
  ## Camera Y that centres one world Y on the player.
  clamp(y - PlayerWorldOffY, minCameraY(), maxCameraY())

proc inMap*(x, y: int): bool =
  ## True when a world pixel is inside the map rectangle.
  x >= 0 and y >= 0 and x < MapWidth and y < MapHeight

proc cameraCanHoldPlayer*(cameraX, cameraY: int): bool =
  ## True when a camera candidate centres a player position that is
  ## inside the map. Localization rejects candidates that don't.
  inMap(cameraX + PlayerWorldOffX, cameraY + PlayerWorldOffY)

proc playerWorldX*(p: Perception): int =
  ## Inferred player collision X coordinate.
  p.cameraX + PlayerWorldOffX

proc playerWorldY*(p: Perception): int =
  ## Inferred player collision Y coordinate.
  p.cameraY + PlayerWorldOffY

proc roomNameAt*(sim: SimServer, x, y: int): string =
  ## Room containing one world point, or "unknown".
  for room in sim.rooms:
    if x >= room.x and x < room.x + room.w and
        y >= room.y and y < room.y + room.h:
      return room.name
  "unknown"

proc roomName*(p: Perception, sim: SimServer): string =
  ## Room containing the inferred player position. Returns "unknown"
  ## when not localized — callers can rely on that to gate room-based
  ## chat / decisions.
  if not p.localized:
    return "unknown"
  let
    px = p.playerWorldX() + CollisionW div 2
    py = p.playerWorldY() + CollisionH div 2
  sim.roomNameAt(px, py)

proc taskCenter*(task: TaskStation): tuple[x: int, y: int] =
  ## Centre pixel for a task station rectangle.
  (task.x + task.w div 2, task.y + task.h div 2)

proc visibleCrewmateWorld*(p: Perception,
                          crewmate: CrewmateMatch): tuple[x: int, y: int] =
  ## Converts one visible crewmate match (screen-coord) to world
  ## coordinates using the current camera lock.
  (p.cameraX + crewmate.x + SpriteDrawOffX,
   p.cameraY + crewmate.y + SpriteDrawOffY)

proc visibleBodyWorld*(p: Perception,
                      body: BodyMatch): tuple[x: int, y: int] =
  ## Converts one visible body match (screen-coord) to world
  ## coordinates.
  (p.cameraX + body.x + SpriteDrawOffX,
   p.cameraY + body.y + SpriteDrawOffY)

# ---------------------------------------------------------------------------
# Central-room helpers (used by the imposter's stuck-detection)
# ---------------------------------------------------------------------------

proc centralRoomCenter*(sim: SimServer): tuple[x: int, y: int] =
  ## Reference point for the central room (the emergency button room).
  let button = sim.gameMap.button
  (button.x + button.w div 2, button.y + button.h div 2)

proc centralRoomName*(sim: SimServer): string =
  ## Room name containing the emergency button.
  let center = sim.centralRoomCenter()
  sim.roomNameAt(center.x, center.y)

proc inCentralRoom*(p: Perception, sim: SimServer): bool =
  ## True when the player is currently inside the central room. Used
  ## by the imposter to detect "stuck in cafeteria" situations.
  if not p.localized:
    return false
  let central = sim.centralRoomName()
  central != "unknown" and p.roomName(sim) == central

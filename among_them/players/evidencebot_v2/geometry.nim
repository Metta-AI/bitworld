proc gameDir(): string =
  ## Returns the Among Them game directory.
  currentSourcePath().parentDir().parentDir()

proc atlasPath(): string =
  ## Returns the shared Silky atlas path.
  gameDir() / ".." / "clients" / "dist" / "atlas.png"

proc unpack4bpp(packed: openArray[uint8], unpacked: var seq[uint8]) =
  ## Expands one packed 4 bit framebuffer into palette indices.
  let targetLen = packed.len * 2
  if unpacked.len != targetLen:
    unpacked.setLen(targetLen)
  for i, byte in packed:
    unpacked[i * 2] = byte and 0x0f
    unpacked[i * 2 + 1] = (byte shr 4) and 0x0f

proc sampleColor(index: uint8): ColorRGBX =
  ## Converts one palette index to a Silky color.
  Palette[index and 0x0f].rgbx

proc mapIndexSafe(x, y: int): int =
  ## Returns the map pixel index.
  y * MapWidth + x

proc minCameraX(): int =
  ## Returns the smallest possible centered camera X.
  -ScreenWidth div 2 - SpriteSize

proc maxCameraX(): int =
  ## Returns the largest possible centered camera X.
  MapWidth - ScreenWidth div 2 + SpriteSize

proc minCameraY(): int =
  ## Returns the smallest possible centered camera Y.
  -ScreenHeight div 2 - SpriteSize

proc maxCameraY(): int =
  ## Returns the largest possible centered camera Y.
  MapHeight - ScreenHeight div 2 + SpriteSize

proc cameraIndex(x, y: int): int =
  ## Returns the patch vote index for one camera.
  (y - minCameraY()) * (maxCameraX() - minCameraX() + 1) +
    (x - minCameraX())

proc cameraIndexX(index: int): int =
  ## Returns the camera X coordinate for one vote index.
  minCameraX() + index mod (maxCameraX() - minCameraX() + 1)

proc cameraIndexY(index: int): int =
  ## Returns the camera Y coordinate for one vote index.
  minCameraY() + index div (maxCameraX() - minCameraX() + 1)

proc buttonCameraX(sim: SimServer): int =
  ## Returns the initial camera X guess around the emergency button.
  let button = sim.gameMap.button
  clamp(
    button.x + button.w div 2 - PlayerWorldOffX,
    minCameraX(),
    maxCameraX()
  )

proc buttonCameraY(sim: SimServer): int =
  ## Returns the initial camera Y guess around the emergency button.
  let button = sim.gameMap.button
  clamp(
    button.y + button.h div 2 - PlayerWorldOffY,
    minCameraY(),
    maxCameraY()
  )

proc cameraXForWorld(x: int): int =
  ## Returns the camera X that centers one world X on the player.
  clamp(x - PlayerWorldOffX, minCameraX(), maxCameraX())

proc cameraYForWorld(y: int): int =
  ## Returns the camera Y that centers one world Y on the player.
  clamp(y - PlayerWorldOffY, minCameraY(), maxCameraY())

proc inMap(x, y: int): bool =
  ## Returns true when a world pixel is inside the Skeld map.
  x >= 0 and y >= 0 and x < MapWidth and y < MapHeight

proc cameraCanHoldPlayer(cameraX, cameraY: int): bool =
  ## Returns true when a camera candidate can center a real player.
  inMap(cameraX + PlayerWorldOffX, cameraY + PlayerWorldOffY)

proc playerWorldX(bot: Bot): int =
  ## Returns the inferred player collision X coordinate.
  bot.cameraX + PlayerWorldOffX

proc playerWorldY(bot: Bot): int =
  ## Returns the inferred player collision Y coordinate.
  bot.cameraY + PlayerWorldOffY

proc roomName(bot: Bot): string =
  ## Returns the room containing the inferred player position.
  if not bot.localized:
    return "unknown"
  let
    px = bot.playerWorldX() + CollisionW div 2
    py = bot.playerWorldY() + CollisionH div 2
  for room in bot.sim.rooms:
    if px >= room.x and px < room.x + room.w and
        py >= room.y and py < room.y + room.h:
      return room.name
  "unknown"

proc roomNameAt(bot: Bot, x, y: int): string =
  ## Returns the room containing one world point.
  for room in bot.sim.rooms:
    if x >= room.x and x < room.x + room.w and
        y >= room.y and y < room.y + room.h:
      return room.name
  "unknown"

proc taskCenter(task: TaskStation): tuple[x: int, y: int] =
  ## Returns the center pixel for a task station.
  (task.x + task.w div 2, task.y + task.h div 2)

proc `<`(a, b: PathNode): bool =
  ## Orders path nodes for Nim heapqueue.
  if a.priority == b.priority:
    return a.index < b.index
  a.priority < b.priority

proc `<`(a, b: PatchEntry): bool =
  ## Orders patch entries by hash and scan order.
  if a.hash == b.hash:
    if a.cameraY == b.cameraY:
      a.cameraX < b.cameraX
    else:
      a.cameraY < b.cameraY
  else:
    a.hash < b.hash

proc cmpPatchCandidate(a, b: PatchCandidate): int =
  ## Sorts patch candidates by votes and scan order.
  if a.votes != b.votes:
    return cmp(b.votes, a.votes)
  if a.cameraY != b.cameraY:
    return cmp(a.cameraY, b.cameraY)
  cmp(a.cameraX, b.cameraX)

proc tileWidth(): int =
  ## Returns the path grid width in pixels.
  MapWidth

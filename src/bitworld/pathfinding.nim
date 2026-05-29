import bitworld/spriteprotocol

const
  MapWidth* = 32
  MapHeight* = 32
  MapSize = MapWidth * MapHeight
  BfsQueueSize = MapSize

type
  TileStatus* = enum
    TileUnknown
    TileClear
    TileBlocked

  ObstacleMap* = object
    cells*: array[MapSize, TileStatus]

  BfsEntry = object
    x, y: int16

proc tileIndex*(x, y: int): int {.inline.} =
  y * MapWidth + x

proc inBounds*(x, y: int): bool {.inline.} =
  x >= 0 and x < MapWidth and y >= 0 and y < MapHeight

proc markTile*(map: var ObstacleMap, x, y: int, status: TileStatus) =
  if inBounds(x, y):
    map.cells[tileIndex(x, y)] = status

proc getTile*(map: ObstacleMap, x, y: int): TileStatus =
  if not inBounds(x, y):
    return TileBlocked
  map.cells[tileIndex(x, y)]

proc bfsNextStep*(
  map: ObstacleMap,
  fromX, fromY, toX, toY: int
): uint8 =
  ## Returns button mask for the first step on shortest path from (fromX,fromY)
  ## to (toX,toY), avoiding blocked tiles. Treats unknown tiles as passable.
  ## Returns 0 if already at target or no path exists.
  if fromX == toX and fromY == toY:
    return 0

  if not inBounds(fromX, fromY) or not inBounds(toX, toY):
    return 0

  var
    visited: array[MapSize, bool]
    parent: array[MapSize, int16]
    queue: array[BfsQueueSize, BfsEntry]
    qHead = 0
    qTail = 0

  let startIdx = tileIndex(fromX, fromY)
  let goalIdx = tileIndex(toX, toY)

  visited[startIdx] = true
  parent[startIdx] = -1
  queue[qTail] = BfsEntry(x: int16(fromX), y: int16(fromY))
  inc qTail

  const dx = [0'i16, 0, -1, 1]
  const dy = [-1'i16, 1, 0, 0]

  var found = false

  while qHead < qTail:
    let cur = queue[qHead]
    inc qHead

    for i in 0 ..< 4:
      let nx = int(cur.x) + int(dx[i])
      let ny = int(cur.y) + int(dy[i])
      if not inBounds(nx, ny):
        continue
      let nIdx = tileIndex(nx, ny)
      if visited[nIdx]:
        continue
      if map.cells[nIdx] == TileBlocked:
        continue
      visited[nIdx] = true
      parent[nIdx] = int16(tileIndex(int(cur.x), int(cur.y)))
      queue[qTail] = BfsEntry(x: int16(nx), y: int16(ny))
      inc qTail
      if nIdx == goalIdx:
        found = true
        break
    if found:
      break

  if not found:
    return 0

  # Trace back from goal to find the first step after start
  var cur = goalIdx
  while true:
    let p = int(parent[cur])
    if p == startIdx:
      break
    if p < 0:
      return 0
    cur = p

  # cur is now the tile adjacent to start on the shortest path
  let stepX = cur mod MapWidth
  let stepY = cur div MapWidth
  let sdx = stepX - fromX
  let sdy = stepY - fromY

  if sdx == 1: return ButtonRight
  if sdx == -1: return ButtonLeft
  if sdy == 1: return ButtonDown
  if sdy == -1: return ButtonUp
  0

proc greedyStep*(fromX, fromY, toX, toY: int): uint8 =
  ## Fallback greedy single-step toward target (no obstacle avoidance).
  let dx = toX - fromX
  let dy = toY - fromY
  if dx == 0 and dy == 0: return 0
  if abs(dx) >= abs(dy):
    if dx > 0: return ButtonRight
    if dx < 0: return ButtonLeft
  if dy > 0: return ButtonDown
  if dy < 0: return ButtonUp
  0

proc unstickStep*(map: ObstacleMap, fromX, fromY, tick: int): uint8 =
  ## Pick a walkable cardinal neighbor, cycling through directions each tick.
  const offsets = [(0, -1, ButtonUp), (1, 0, ButtonRight),
                   (0, 1, ButtonDown), (-1, 0, ButtonLeft)]
  for i in 0 ..< 4:
    let idx = (tick + i) mod 4
    let nx = fromX + offsets[idx][0]
    let ny = fromY + offsets[idx][1]
    if inBounds(nx, ny) and map.cells[tileIndex(nx, ny)] != TileBlocked:
      return uint8(offsets[idx][2])
  0

proc pathStep*(
  map: ObstacleMap,
  fromX, fromY, toX, toY: int
): uint8 =
  ## Primary navigation: BFS if possible, greedy fallback.
  let mask = bfsNextStep(map, fromX, fromY, toX, toY)
  if mask != 0:
    return mask
  greedyStep(fromX, fromY, toX, toY)

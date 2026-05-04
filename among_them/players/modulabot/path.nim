## A* pathfinding on the walk mask + path lookahead.
##
## Phase 1 port from v2:2539-2637, plus `choosePathStep` from v2:3385.
##
## All procs read state but do not mutate it. Path output is a
## `seq[PathStep]` consumed by `motion.maskForWaypoint`. The orchestrator
## stores the chosen path in `bot.goal.path` / `bot.goal.pathStep`.

import std/heapqueue

import ../../sim

import types
import geometry

const
  PathLookahead* = 18
    ## Steps ahead in the A* path to aim at. Smaller = more reactive
    ## (and more thrashy on snags); larger = smoother but more
    ## overshoot-prone. Set to match v2.

# ---------------------------------------------------------------------------
# Internal node type for the priority queue.
# ---------------------------------------------------------------------------

type
  PathNode = object
    priority: int
    index: int

proc `<`(a, b: PathNode): bool =
  ## Heap order: lower priority first; tie-break by node index for
  ## stable ordering across runs.
  if a.priority == b.priority:
    return a.index < b.index
  a.priority < b.priority

# ---------------------------------------------------------------------------
# Walk-mask passability
# ---------------------------------------------------------------------------

proc tileWidth*(): int =
  ## Pixel width of the path grid. Equal to `MapWidth` because A* runs
  ## at one pixel per node.
  MapWidth

proc passable*(sim: SimServer, x, y: int): bool =
  ## True when a collision-sized body can occupy world pixel (x, y)
  ## without intersecting walls or leaving the map.
  if x < 0 or y < 0 or x + CollisionW >= MapWidth or
      y + CollisionH >= MapHeight:
    return false
  for dy in 0 ..< CollisionH:
    for dx in 0 ..< CollisionW:
      if not sim.walkMask[mapIndexSafe(x + dx, y + dy)]:
        return false
  true

# ---------------------------------------------------------------------------
# A* pathfinder
# ---------------------------------------------------------------------------

proc heuristic*(ax, ay, bx, by: int): int =
  ## Manhattan distance for path search. Admissible because the four-
  ## connected grid moves cost 1 per step.
  abs(ax - bx) + abs(ay - by)

proc reconstructPath(parents: openArray[int],
                    startIndex, goalIndex: int): seq[PathStep] =
  ## Builds the start→goal path from a parent table, reversing in
  ## place. Identical to v2:2554-2569.
  var stepIndex = goalIndex
  while stepIndex != startIndex and stepIndex >= 0:
    result.add(PathStep(
      found: true,
      x: stepIndex mod tileWidth(),
      y: stepIndex div tileWidth()
    ))
    stepIndex = parents[stepIndex]
  for i in 0 ..< result.len div 2:
    swap(result[i], result[result.high - i])

proc findPath*(percep: Perception, sim: SimServer,
              goalX, goalY: int): seq[PathStep] =
  ## Finds a complete A* pixel path from the player's current position
  ## to (goalX, goalY). Returns an empty seq when no path exists or
  ## either endpoint is impassable. Verbatim port of v2:2571-2622.
  let
    startX = percep.playerWorldX()
    startY = percep.playerWorldY()
    area = MapWidth * MapHeight
    startIndex = mapIndexSafe(startX, startY)
    goalIndex = mapIndexSafe(goalX, goalY)
  if not sim.passable(startX, startY) or not sim.passable(goalX, goalY):
    return
  var
    parents = newSeq[int](area)
    costs = newSeq[int](area)
    closed = newSeq[bool](area)
    openSet: HeapQueue[PathNode]
  for i in 0 ..< area:
    parents[i] = -2
    costs[i] = high(int)
  parents[startIndex] = -1
  costs[startIndex] = 0
  openSet.push(PathNode(
    priority: heuristic(startX, startY, goalX, goalY),
    index: startIndex
  ))
  while openSet.len > 0:
    let current = openSet.pop()
    if closed[current.index]:
      continue
    if current.index == goalIndex:
      return reconstructPath(parents, startIndex, goalIndex)
    closed[current.index] = true
    let
      x = current.index mod tileWidth()
      y = current.index div tileWidth()
    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nx = x + delta[0]
        ny = y + delta[1]
      if not sim.passable(nx, ny):
        continue
      let nextIndex = mapIndexSafe(nx, ny)
      if closed[nextIndex]:
        continue
      let newCost = costs[current.index] + 1
      if newCost >= costs[nextIndex]:
        continue
      costs[nextIndex] = newCost
      parents[nextIndex] = current.index
      openSet.push(PathNode(
        priority: newCost + heuristic(nx, ny, goalX, goalY),
        index: nextIndex
      ))

proc pathDistance*(percep: Perception, sim: SimServer,
                  goalX, goalY: int): int =
  ## Real A* path length, or `high(int)` when unreachable. Used by the
  ## crewmate task picker.
  if percep.playerWorldX() == goalX and percep.playerWorldY() == goalY:
    return 0
  let path = findPath(percep, sim, goalX, goalY)
  if path.len == 0:
    return high(int)
  path.len

proc goalDistance*(percep: Perception, sim: SimServer, isGhost: bool,
                  goalX, goalY: int): int =
  ## Distance metric for goal comparison. Ghosts use Manhattan because
  ## they fly through walls; living crewmates use real path length.
  if isGhost:
    return heuristic(percep.playerWorldX(), percep.playerWorldY(),
                     goalX, goalY)
  pathDistance(percep, sim, goalX, goalY)

# ---------------------------------------------------------------------------
# Lookahead waypoint
# ---------------------------------------------------------------------------

proc choosePathStep*(path: seq[PathStep]): PathStep =
  ## Returns a short-lookahead waypoint from the current path. Returns
  ## an unfound `PathStep` (default-zero) when the path is empty.
  if path.len == 0:
    return
  let index = min(path.high, PathLookahead)
  path[index]

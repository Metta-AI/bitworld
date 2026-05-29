import
  bitworld/pathfinding,
  bitworld/spriteprotocol

echo "Testing pathfinding map access"
var map: ObstacleMap
doAssert map.getTile(0, 0) == TileUnknown
doAssert map.getTile(-1, 0) == TileBlocked
map.markTile(1, 0, TileBlocked)
doAssert map.getTile(1, 0) == TileBlocked

echo "Testing BFS step selection"
doAssert bfsNextStep(map, 0, 0, 2, 0) == ButtonDown
map.markTile(1, 0, TileClear)
doAssert bfsNextStep(map, 0, 0, 2, 0) == ButtonRight
doAssert bfsNextStep(map, 0, 0, 0, 0) == 0

echo "Testing fallback steps"
doAssert greedyStep(0, 0, 3, 1) == ButtonRight
doAssert greedyStep(0, 0, 1, 3) == ButtonDown
doAssert unstickStep(map, 0, 0, 0) in [
  ButtonDown,
  ButtonRight
]
doAssert pathStep(map, 0, 0, 2, 0) == ButtonRight

echo "All tests passed"

import
  std/[json, os],
  ../common/protocol,
  ../party_progressor/sim

const RootDir = currentSourcePath.parentDir.parentDir

proc initPartyProgressorForTest(seed = 1234): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "party_progressor")
  try:
    result = initSimServer(seed)
  finally:
    setCurrentDir(previousDir)

proc hasPickup(sim: SimServer, kind: PickupKind): bool =
  for pickup in sim.pickups:
    if pickup.kind == kind:
      return true

proc firstPickup(sim: SimServer, kind: PickupKind): Pickup =
  for pickup in sim.pickups:
    if pickup.kind == kind:
      return pickup
  raise newException(ValueError, "missing pickup: " & $kind)

proc testSafeOriginAndReusableRoles() =
  var sim = initPartyProgressorForTest()
  let playerIndex = sim.addPlayer("player1")
  doAssert sim.players[playerIndex].x < SafeZoneRightPixels,
    "player should spawn inside the safe origin"
  doAssert sim.hasPickup(PickupTankGear)
  doAssert sim.hasPickup(PickupDpsGear)
  doAssert sim.hasPickup(PickupHealerGear)

  let tankGear = sim.firstPickup(PickupTankGear)
  sim.players[playerIndex].x = tankGear.x
  sim.players[playerIndex].y = tankGear.y
  sim.step([InputState()])

  doAssert sim.players[playerIndex].role == RoleTank
  doAssert sim.players[playerIndex].maxHp == TankPlayerHp
  doAssert sim.hasPickup(PickupTankGear),
    "role gear must stay available for other players"

proc testFrontierScoreIsShared() =
  var sim = initPartyProgressorForTest()
  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + 5 * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.step([InputState()])

  let
    frontier = sim.frontierTiles()
    scores = parseJson(sim.playerScoresJson())
  doAssert frontier >= 5,
    "frontier should advance when a player reaches farther right"
  doAssert scores["scores"][0].getInt() == frontier
  doAssert scores["frontier_tiles"][0].getInt() == frontier
  doAssert scores["personal_frontier_tiles"][0].getInt() == frontier

proc testMobHpScalesByProgressZone() =
  let
    nearHp = mobMaxHp(SnakeMob, SafeZoneRightPixels + WorldTileSize)
    farHp = mobMaxHp(SnakeMob, SafeZoneRightPixels + 4 * ZoneWidthPixels)
  doAssert farHp > nearHp,
    "combat should get harder farther from the origin"

testSafeOriginAndReusableRoles()
testFrontierScoreIsShared()
testMobHpScalesByProgressZone()
echo "All tests passed"

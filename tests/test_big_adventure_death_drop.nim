import
  std/os,
  ../common/protocol,
  ../common/server,
  ../big_adventure/sim

const RootDir = currentSourcePath.parentDir.parentDir

proc initBigAdventureForTest(seed = 1234): SimServer =
  ## Initializes Big Adventure from its asset directory.
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "big_adventure")
  try:
    result = initSimServer(seed)
  finally:
    setCurrentDir(previousDir)

proc hasCoinPickup(sim: SimServer, value: int): bool =
  ## Returns true when a coin pickup with the given value exists.
  for pickup in sim.pickups:
    if pickup.kind == PickupCoin and pickup.value == value:
      return true

proc testPlayerDropsCarriedCoinsOnDeath() =
  ## Checks that player death drops all carried coins before reset.
  var sim = initBigAdventureForTest()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)

  let
    attacker = sim.addPlayer("attacker")
    victim = sim.addPlayer("victim")
    dropValue = 17
  sim.players[attacker].x = WorldWidthPixels div 2
  sim.players[attacker].y = WorldHeightPixels div 2
  sim.players[attacker].facing = FaceRight
  sim.players[attacker].bounds = sim.playerBoundsFor(sim.players[attacker])

  sim.players[victim].x = sim.players[attacker].x + 24
  sim.players[victim].y = sim.players[attacker].y
  sim.players[victim].bounds = sim.playerBoundsFor(sim.players[victim])
  sim.players[victim].lives = 1
  sim.players[victim].coins = dropValue

  sim.step([InputState(attack: true), InputState()])

  doAssert sim.players[victim].lives == MaxPlayerLives,
    "dead player should respawn with full lives"
  doAssert sim.players[victim].coins == 0,
    "dead player should lose carried coins"
  doAssert sim.hasCoinPickup(dropValue),
    "death should drop one coin pickup worth all carried coins"

proc testMobsAvoidPlayerStart() =
  ## Checks that initial mobs do not spawn near the player start area.
  let sim = initBigAdventureForTest()
  let
    centerX = (WorldWidthTiles div 2) * WorldTileSize + WorldTileSize div 2
    centerY = (WorldHeightTiles div 2) * WorldTileSize + WorldTileSize div 2
    safeRadiusSq = MobSpawnSafeRadius * MobSpawnSafeRadius

  doAssert sim.mobs.len > 0, "test world should start with mobs"
  for mob in sim.mobs:
    let
      mobX = boundsCenterX(mob.x, mob.bounds)
      mobY = boundsCenterY(mob.y, mob.bounds)
    doAssert distanceSquared(mobX, mobY, centerX, centerY) > safeRadiusSq,
      "initial mob should not spawn near player start"

proc testMobSightRadiusIsSmaller() =
  ## Checks that mobs only chase players once they are close by.
  doAssert MobSightRadius == (WorldTileSize * 3) div 2,
    "mob sight radius should be half of the earlier three-tile radius"

testPlayerDropsCarriedCoinsOnDeath()
testMobsAvoidPlayerStart()
testMobSightRadiusIsSmaller()
echo "All tests passed"

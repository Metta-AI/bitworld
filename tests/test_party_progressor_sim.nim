import
  std/[json, os],
  ../common/protocol,
  ../common/server,
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

proc hasPickup(sim: SimServer, kind: PickupKind, value: int): bool =
  for pickup in sim.pickups:
    if pickup.kind == kind and pickup.value == value:
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

proc clearTerrain(sim: var SimServer) =
  for tile in sim.tiles.mitems:
    tile = false

proc fillGround(sim: var SimServer, ground: GroundKind, biome = BiomeOrigin) =
  for item in sim.groundKinds.mitems:
    item = ground
  for item in sim.biomeKinds.mitems:
    item = biome

proc firstTileForBiome(biome: BiomeKind): int =
  for tx in 0 ..< WorldWidthTiles:
    if biomeForTileX(tx) == biome:
      return tx
  raise newException(ValueError, "missing biome: " & $biome)

proc testPlayerDropsCarriedCoinsOnDeath() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)

  let
    playerIndex = sim.addPlayer("player1")
    dropValue = 9
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].lives = 1
  sim.players[playerIndex].coins = dropValue
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])

  sim.mobs.add(Mob(
    kind: SnakeMob,
    x: sim.players[playerIndex].x,
    y: sim.players[playerIndex].y,
    sprite: sim.mobSprite,
    bounds: sim.mobBounds,
    hp: 1,
    attackPhase: MobLunge,
    attackTicks: MobLungeTicks - 1,
    attackFacing: FaceRight
  ))

  sim.step([InputState()])

  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp,
    "dead player should respawn with full hp"
  doAssert sim.players[playerIndex].coins == 0,
    "dead player should lose carried coins"
  doAssert sim.hasPickup(PickupCoin, dropValue),
    "death should drop one coin pickup worth all carried coins"

proc testMobTelegraphsBeforeLunging() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])

  sim.mobs.add(Mob(
    kind: SnakeMob,
    x: sim.players[playerIndex].x + 2,
    y: sim.players[playerIndex].y,
    sprite: sim.mobSprite,
    bounds: sim.mobBounds,
    hp: 1,
    attackCooldown: 0
  ))

  sim.step([InputState()])

  doAssert sim.mobs[0].attackPhase == MobTelegraph,
    "mob should enter a visible telegraph phase before lunging"
  doAssert sim.mobs[0].mobDrawY() != sim.mobs[0].y,
    "telegraphing mob should visibly bounce"

proc testMobChasesNearbyPlayers() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)

  let playerIndex = sim.addPlayer("player1")
  let
    mobX = SafeZoneRightPixels + WorldTileSize
    mobY = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].x = mobX + MobSightRadius - 4
  sim.players[playerIndex].y = mobY
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])

  sim.mobs.add(Mob(
    kind: SnakeMob,
    x: mobX,
    y: mobY,
    sprite: sim.mobSprite,
    bounds: sim.mobBounds,
    hp: 1,
    attackCooldown: 20,
    wanderCooldown: 0
  ))

  sim.step([InputState()])

  doAssert sim.mobs[0].x > mobX,
    "mob inside sight radius should chase toward the player"
  doAssert sim.mobs[0].wanderCooldown == MobChaseCooldown,
    "chasing mob should use the short chase cooldown"

proc testPlayerSpeedIsSlower() =
  doAssert MaxSpeed == 264,
    "player max speed should match the borrowed Big Adventure tuning"

proc testBiomeGroundsAndWeather() =
  var sim = initPartyProgressorForTest()
  let
    swampTx = firstTileForBiome(BiomeSwamp)
    desertTx = firstTileForBiome(BiomeDesert)
    centerTy = WorldHeightTiles div 2
  doAssert sim.tileBiomeKind(0, centerTy) == BiomeOrigin
  doAssert sim.tileBiomeKind(swampTx, centerTy) == BiomeSwamp
  doAssert sim.tileGroundKind(swampTx, centerTy) == GroundBridge
  doAssert sim.tileBiomeKind(desertTx, centerTy).weatherForBiome() ==
    WeatherDust
  doAssert groundSpeedPercent(GroundMud) < groundSpeedPercent(GroundRoad)

proc testTerrainMovementModifiersAffectPlayers() =
  var roadSim = initPartyProgressorForTest()
  roadSim.clearTerrain()
  roadSim.mobs.setLen(0)
  roadSim.pickups.setLen(0)
  roadSim.fillGround(GroundRoad)
  let roadPlayer = roadSim.addPlayer("road")
  roadSim.players[roadPlayer].x = SafeZoneRightPixels + WorldTileSize
  roadSim.players[roadPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  roadSim.players[roadPlayer].bounds =
    roadSim.playerBoundsFor(roadSim.players[roadPlayer])
  let startRoadX = roadSim.players[roadPlayer].x
  for _ in 0 ..< 30:
    roadSim.step([InputState(right: true)])
  let roadDistance = roadSim.players[roadPlayer].x - startRoadX

  var mudSim = initPartyProgressorForTest()
  mudSim.clearTerrain()
  mudSim.mobs.setLen(0)
  mudSim.pickups.setLen(0)
  mudSim.fillGround(GroundMud)
  let mudPlayer = mudSim.addPlayer("mud")
  mudSim.players[mudPlayer].x = SafeZoneRightPixels + WorldTileSize
  mudSim.players[mudPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  mudSim.players[mudPlayer].bounds =
    mudSim.playerBoundsFor(mudSim.players[mudPlayer])
  let startMudX = mudSim.players[mudPlayer].x
  for _ in 0 ..< 30:
    mudSim.step([InputState(right: true)])
  let mudDistance = mudSim.players[mudPlayer].x - startMudX

  doAssert roadDistance > mudDistance,
    "road movement should outpace mud movement"

proc testResourceHarvestAndCampActivation() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].facing = FaceRight
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  let hit = sim.attackRect(sim.players[playerIndex])
  sim.landmarks.add(Landmark(
    tx: clamp((hit.x + hit.w div 2) div WorldTileSize, 0, WorldWidthTiles - 1),
    ty: clamp((hit.y + hit.h div 2) div WorldTileSize, 0, WorldHeightTiles - 1),
    kind: LandmarkWood,
    hp: 1,
    done: false
  ))

  sim.step([InputState(attack: true)])
  doAssert sim.wood == 1
  doAssert sim.resourcesCollected == 1
  doAssert sim.landmarks[0].done

  sim.landmarks.setLen(0)
  sim.pickups.setLen(0)
  sim.wood = CampWoodCost
  sim.stone = CampStoneCost
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkCamp,
    hp: 1,
    done: false
  ))
  sim.step([InputState()])
  doAssert sim.campsActivated == 1
  doAssert sim.wood == 0 and sim.stone == 0
  doAssert sim.hasPickup(PickupTankGear)
  doAssert sim.hasPickup(PickupDpsGear)
  doAssert sim.hasPickup(PickupHealerGear)

proc testBeaconAndBossScoring() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkBeacon,
    hp: 1,
    done: false
  ))
  sim.step([InputState()])

  doAssert sim.objectivesCompleted == 1
  doAssert sim.relicShards == 1
  doAssert sim.teamScore() ==
    sim.frontierTiles() + ObjectiveScoreValue + RelicScoreValue

  sim.landmarks.setLen(0)
  sim.mobs.setLen(0)
  sim.players[playerIndex].facing = FaceRight
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  let hit = sim.attackRect(sim.players[playerIndex])
  sim.mobs.add(Mob(
    kind: BossMob,
    x: hit.x,
    y: hit.y,
    sprite: sim.bossSprite,
    bounds: sim.bossBounds,
    hp: 1,
    attackCooldown: 99
  ))
  sim.step([InputState(attack: true)])
  doAssert sim.bossDefeated
  doAssert sim.teamScore() >=
    sim.frontierTiles() + ObjectiveScoreValue + RelicScoreValue +
      BossScoreValue

testSafeOriginAndReusableRoles()
testFrontierScoreIsShared()
testMobHpScalesByProgressZone()
testPlayerDropsCarriedCoinsOnDeath()
testMobTelegraphsBeforeLunging()
testMobChasesNearbyPlayers()
testPlayerSpeedIsSlower()
testBiomeGroundsAndWeather()
testTerrainMovementModifiersAffectPlayers()
testResourceHarvestAndCampActivation()
testBeaconAndBossScoring()
echo "All tests passed"

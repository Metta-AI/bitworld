import
  std/[json, os, sequtils, strutils, tables],
  supersnappy,
  ../common/protocol,
  ../common/server,
  ../party_progressor/global,
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
  if sim.elevations.len != sim.groundKinds.len:
    sim.elevations.setLen(sim.groundKinds.len)
  for item in sim.elevations.mitems:
    item = 0

proc firstTileForBiome(biome: BiomeKind): int =
  for tx in 0 ..< WorldWidthTiles:
    if biomeForTileX(tx) == biome:
      return tx
  raise newException(ValueError, "missing biome: " & $biome)

proc readU16(bytes: openArray[uint8], offset: int): int =
  int(uint16(bytes[offset]) or (uint16(bytes[offset + 1]) shl 8))

proc readU32(bytes: openArray[uint8], offset: int): int =
  int(uint32(bytes[offset]) or
    (uint32(bytes[offset + 1]) shl 8) or
    (uint32(bytes[offset + 2]) shl 16) or
    (uint32(bytes[offset + 3]) shl 24))

proc packetBytesToString(bytes: openArray[uint8], start, length: int): string =
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(bytes[start + i])

proc firstSpriteRawPixels(
  packet: openArray[uint8],
  wantedSpriteId: int
): tuple[width, height: int, pixels: string] =
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01'u8:
      let
        spriteId = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10
      let compressed = packet.packetBytesToString(offset, compressedLen)
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2 + labelLen
      if spriteId == wantedSpriteId:
        return (width, height, supersnappy.uncompress(compressed))
    of 0x02'u8:
      offset += 11
    of 0x03'u8:
      offset += 2
    of 0x04'u8:
      discard
    of 0x05'u8:
      offset += 5
    of 0x06'u8:
      offset += 3
    else:
      raise newException(ValueError, "unknown sprite protocol message")
  raise newException(ValueError, "missing sprite id: " & $wantedSpriteId)

proc firstViewport(
  packet: openArray[uint8],
  wantedLayerId: int
): tuple[width, height: int] =
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01'u8:
      let compressedLen = packet.readU32(offset + 6)
      offset += 10 + compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2 + labelLen
    of 0x02'u8:
      offset += 11
    of 0x03'u8:
      offset += 2
    of 0x04'u8:
      discard
    of 0x05'u8:
      let
        layerId = int(packet[offset])
        width = packet.readU16(offset + 1)
        height = packet.readU16(offset + 3)
      offset += 5
      if layerId == wantedLayerId:
        return (width, height)
    of 0x06'u8:
      offset += 3
    else:
      raise newException(ValueError, "unknown sprite protocol message")
  raise newException(ValueError, "missing viewport for layer: " & $wantedLayerId)

type
  ParsedSprite = object
    width, height: int
    label: string

  ParsedObject = object
    x, y, z, layer, spriteId: int

  ParsedPacket = object
    sprites: Table[int, ParsedSprite]
    objects: Table[int, ParsedObject]
    layers: Table[int, tuple[layerType, flags: int]]
    viewports: Table[int, tuple[width, height: int]]

proc parseSpriteProtocolPacket(packet: openArray[uint8]): ParsedPacket =
  ## Mirrors the packet framing used by existing sprite-protocol bot parsers.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01'u8:
      if offset + 10 > packet.len:
        raise newException(ValueError, "truncated sprite header")
      let
        spriteId = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10
      if offset + compressedLen + 2 > packet.len:
        raise newException(ValueError, "truncated sprite pixels")
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len:
        raise newException(ValueError, "truncated sprite label")
      let label = packet.packetBytesToString(offset, labelLen)
      offset += labelLen
      result.sprites[spriteId] = ParsedSprite(
        width: width,
        height: height,
        label: label
      )
    of 0x02'u8:
      if offset + 11 > packet.len:
        raise newException(ValueError, "truncated object")
      let
        objectId = packet.readU16(offset)
        x = int(cast[int16](uint16(packet.readU16(offset + 2))))
        y = int(cast[int16](uint16(packet.readU16(offset + 4))))
        z = int(cast[int16](uint16(packet.readU16(offset + 6))))
        layer = int(packet[offset + 8])
        spriteId = packet.readU16(offset + 9)
      offset += 11
      result.objects[objectId] = ParsedObject(
        x: x,
        y: y,
        z: z,
        layer: layer,
        spriteId: spriteId
      )
    of 0x03'u8:
      if offset + 2 > packet.len:
        raise newException(ValueError, "truncated delete")
      result.objects.del(packet.readU16(offset))
      offset += 2
    of 0x04'u8:
      result.objects.clear()
    of 0x05'u8:
      if offset + 5 > packet.len:
        raise newException(ValueError, "truncated viewport")
      let
        layerId = int(packet[offset])
        width = packet.readU16(offset + 1)
        height = packet.readU16(offset + 3)
      offset += 5
      result.viewports[layerId] = (width: width, height: height)
    of 0x06'u8:
      if offset + 3 > packet.len:
        raise newException(ValueError, "truncated layer")
      let
        layerId = int(packet[offset])
        layerType = int(packet[offset + 1])
        flags = int(packet[offset + 2])
      offset += 3
      result.layers[layerId] = (layerType: layerType, flags: flags)
    of 0x07'u8:
      if offset + 2 > packet.len:
        raise newException(ValueError, "truncated identity")
      offset += 2
    else:
      raise newException(ValueError, "unknown sprite protocol message")

proc objectSpriteLabels(parsed: ParsedPacket): seq[string] =
  for obj in parsed.objects.values:
    if parsed.sprites.hasKey(obj.spriteId):
      result.add(parsed.sprites[obj.spriteId].label)

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

proc testSpritePlayerViewportAndBiomeBackground() =
  var sim = initPartyProgressorForTest()
  let playerIndex = sim.addPlayer("player1")
  sim.clearTerrain()
  sim.fillGround(GroundGrass, BiomeDesert)
  sim.rgbaGroundSprites[GroundGrass] = RgbaSprite(
    width: WorldTileSize,
    height: WorldTileSize,
    pixels: newSeq[uint8](WorldTileSize * WorldTileSize * 4)
  )

  var nextState: PlayerViewerState
  let packet = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  )
  let viewport = packet.firstViewport(MapLayerId)
  doAssert viewport.width == PlayerViewportWidth
  doAssert viewport.height == PlayerViewportHeight

  let mapSprite = packet.firstSpriteRawPixels(MapSpriteId)
  doAssert mapSprite.width == WorldWidthPixels
  doAssert mapSprite.height == WorldHeightPixels
  let
    pixelOffset = 0
    color = BiomeDesert.biomeBackgroundRgbaColor()
  doAssert mapSprite.pixels[pixelOffset].uint8 == color.r
  doAssert mapSprite.pixels[pixelOffset + 1].uint8 == color.g
  doAssert mapSprite.pixels[pixelOffset + 2].uint8 == color.b
  doAssert mapSprite.pixels[pixelOffset + 3].uint8 == color.a

proc testSpriteProtocolPacketMatchesReferenceParsers() =
  var sim = initPartyProgressorForTest()
  let playerIndex = sim.addPlayer("player1")

  var nextState: PlayerViewerState
  let packet = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  )
  let parsed = packet.parseSpriteProtocolPacket()
  doAssert parsed.layers.hasKey(MapLayerId)
  doAssert parsed.viewports[MapLayerId].width == PlayerViewportWidth
  doAssert parsed.viewports[MapLayerId].height == PlayerViewportHeight
  doAssert parsed.sprites[MapSpriteId].label == "map"
  for obj in parsed.objects.values:
    doAssert parsed.sprites.hasKey(obj.spriteId),
      "object references undefined sprite " & $obj.spriteId

  let visibleLabels = parsed.objectSpriteLabels()
  doAssert "role tank" in visibleLabels
  doAssert "role dps" in visibleLabels
  doAssert "role heal" in visibleLabels
  for species in AllMobSpecies:
    doAssert parsed.sprites.values.toSeq.anyIt(it.label == species.speciesLabel()),
      "missing generated monster sprite " & species.speciesLabel()

  let tankGear = sim.firstPickup(PickupTankGear)
  sim.players[playerIndex].x = tankGear.x
  sim.players[playerIndex].y = tankGear.y
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  sim.step([InputState()])

  var tankState: PlayerViewerState
  let tankPacket = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    tankState
  )
  let tankParsed = tankPacket.parseSpriteProtocolPacket()
  let playerObject =
    tankParsed.objects[PlayerObjectBase + sim.players[playerIndex].id]
  doAssert "blue" in tankParsed.sprites[playerObject.spriteId].label,
    "tank role should visibly retint the player sprite"

proc testBiomeMonsterSpeciesBreadth() =
  var sim = initPartyProgressorForTest()
  var seen: seq[MobSpecies] = @[]
  for mob in sim.mobs:
    if mob.species != SpeciesNone and mob.species notin seen:
      seen.add(mob.species)

  doAssert seen.len == AllMobSpecies.len,
    "initial expedition should seed all 32 named monster species"
  for species in AllMobSpecies:
    doAssert species in seen,
      "missing seeded monster species " & species.speciesLabel()
  for biome in [
    BiomeForest,
    BiomePlains,
    BiomeSwamp,
    BiomeDesert,
    BiomeSnow,
    BiomeCave,
    BiomeRuins
  ]:
    doAssert biome.monsterSpeciesForBiome().len >= 4,
      biome.biomeLabel() & " should have multiple distinct monster species"

proc addLungingSpecies(
  sim: var SimServer,
  species: MobSpecies,
  playerIndex: int
) =
  let kind = species.speciesKind()
  sim.mobs.add(Mob(
    kind: kind,
    species: species,
    x: sim.players[playerIndex].x,
    y: sim.players[playerIndex].y,
    sprite: sim.mobSpriteFor(kind),
    bounds: sim.mobBoundsFor(kind),
    hp: mobMaxHp(kind, sim.players[playerIndex].x),
    attackCooldown: 0,
    attackPhase: MobLunge,
    attackTicks: 0,
    attackFacing: FaceRight
  ))

proc testMonsterTacticalHooksAndStatuses() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.bossDefeated = true
  sim.fillGround(GroundGrass)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + 2 * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp
  sim.players[playerIndex].invulnTicks = 0

  sim.addLungingSpecies(SpeciesMudSlime, playerIndex)
  sim.updateMobs()
  doAssert sim.players[playerIndex].slowTicks > 0
  doAssert sim.players[playerIndex].statusSpeedPercent() < 100

  sim.mobs.setLen(0)
  sim.players[playerIndex].slowTicks = 0
  sim.players[playerIndex].invulnTicks = 0
  sim.addLungingSpecies(SpeciesDuneScorpion, playerIndex)
  sim.updateMobs()
  doAssert sim.players[playerIndex].poisonTicks > 0

  sim.mobs.setLen(0)
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp
  sim.players[playerIndex].invulnTicks = 30
  sim.tickCount = StatusPoisonIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp - 1,
    "poison should damage through ordinary hit invulnerability"

  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp
  sim.players[playerIndex].poisonTicks = StatusPoisonTicks
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood
  sim.tickCount = StatusPoisonIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].poisonTicks == 0
  doAssert not sim.players[playerIndex].carrying,
    "carried food should cleanse poison before poison damage lands"

  sim.mobs.setLen(0)
  sim.players[playerIndex].invulnTicks = 0
  sim.applyMobHitStatus(Mob(species: SpeciesSnowWolf), playerIndex)
  doAssert sim.players[playerIndex].chillTicks > 0
  doAssert sim.players[playerIndex].statusSpeedPercent() < 100

  let wraith = Mob(
    kind: WraithMob,
    species: SpeciesRuinWraith,
    x: sim.players[playerIndex].x
  )
  doAssert sim.mobHitDamage(wraith, playerIndex) == 3,
    "wraiths should punish isolated players with extra damage"

  let allyIndex = sim.addPlayer("ally")
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp
  sim.players[playerIndex].invulnTicks = 0
  sim.players[allyIndex].x = sim.players[playerIndex].x + WorldTileSize
  sim.players[allyIndex].y = sim.players[playerIndex].y
  sim.players[allyIndex].bounds = sim.playerBoundsFor(sim.players[allyIndex])
  doAssert sim.mobHitDamage(wraith, playerIndex) == 2,
    "nearby allies should prevent the wraith isolation penalty"

  let bat = Mob(kind: BatMob, species: SpeciesCaveBat)
  doAssert bat.mobSightRange() == MobSightRadius * 2

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

proc testElevationSlowsHighGround() =
  var lowSim = initPartyProgressorForTest()
  lowSim.clearTerrain()
  lowSim.mobs.setLen(0)
  lowSim.pickups.setLen(0)
  lowSim.fillGround(GroundGrass)
  let lowPlayer = lowSim.addPlayer("low")
  lowSim.players[lowPlayer].x = SafeZoneRightPixels + WorldTileSize
  lowSim.players[lowPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  lowSim.players[lowPlayer].bounds =
    lowSim.playerBoundsFor(lowSim.players[lowPlayer])
  let startLowX = lowSim.players[lowPlayer].x
  for _ in 0 ..< 30:
    lowSim.step([InputState(right: true)])
  let lowDistance = lowSim.players[lowPlayer].x - startLowX

  var highSim = initPartyProgressorForTest()
  highSim.clearTerrain()
  highSim.mobs.setLen(0)
  highSim.pickups.setLen(0)
  highSim.fillGround(GroundGrass)
  for item in highSim.elevations.mitems:
    item = 5
  let highPlayer = highSim.addPlayer("high")
  highSim.players[highPlayer].x = SafeZoneRightPixels + WorldTileSize
  highSim.players[highPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  highSim.players[highPlayer].bounds =
    highSim.playerBoundsFor(highSim.players[highPlayer])
  let startHighX = highSim.players[highPlayer].x
  for _ in 0 ..< 30:
    highSim.step([InputState(right: true)])
  let highDistance = highSim.players[highPlayer].x - startHighX

  doAssert elevationSpeedPercent(5) < elevationSpeedPercent(0)
  doAssert lowDistance > highDistance,
    "high elevation should slow travel even on the same ground"

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
  doAssert sim.players[playerIndex].carrying
  doAssert sim.players[playerIndex].carriedItem == CarryWood

  sim.step([InputState(select: true)])
  doAssert not sim.players[playerIndex].carrying
  doAssert sim.hasPickup(PickupWood),
    "select should drop the carried expedition item as a floor pickup"
  let woodPickup = sim.firstPickup(PickupWood)
  sim.players[playerIndex].x = woodPickup.x
  sim.players[playerIndex].y = woodPickup.y
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  sim.step([InputState()])
  doAssert sim.players[playerIndex].carrying
  doAssert sim.players[playerIndex].carriedItem == CarryWood

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

  sim.landmarks.setLen(0)
  sim.mobs.setLen(0)
  sim.bossDefeated = true
  sim.relicShards = FinalGateRelicCost - 1
  sim.objectivesCompleted = 0
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkFinalGate,
    hp: 1,
    done: false
  ))
  sim.step([InputState()])
  doAssert not sim.landmarks[0].done,
    "final gate should require relic progress as well as boss defeat"
  sim.relicShards = FinalGateRelicCost
  sim.step([InputState()])
  doAssert sim.landmarks[0].done

proc testDpsCleaveSpecialDamagesNearbyMobs() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.bossDefeated = true
  sim.fillGround(GroundGrass)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].facing = FaceRight
  sim.players[playerIndex].applyRole(RoleDps)
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])

  for dx in [8, 24]:
    sim.mobs.add(Mob(
      kind: SnakeMob,
      x: sim.players[playerIndex].x + dx,
      y: sim.players[playerIndex].y,
      sprite: sim.mobSpriteFor(SnakeMob),
      bounds: sim.mobBoundsFor(SnakeMob),
      hp: 5,
      attackCooldown: 99
    ))

  sim.step([InputState(b: true)])

  doAssert sim.players[playerIndex].abilityCooldown > 0
  doAssert sim.players[playerIndex].attackTicks > 0
  doAssert sim.mobs.len == 2
  doAssert sim.mobs[0].hp == 5 - DpsCleaveDamage
  doAssert sim.mobs[1].hp == 5 - DpsCleaveDamage

proc testFoodAndColdSurvivalPressure() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.fillGround(GroundSnow, BiomeSnow)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].lives =
    sim.players[playerIndex].maxHp - FoodHealAmount
  sim.food = 1
  sim.step([InputState()])

  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp
  doAssert sim.food == 0

  sim.players[playerIndex].lives = 3
  sim.players[playerIndex].invulnTicks = 0
  sim.tickCount = ColdExposureIntervalTicks - 1
  sim.step([InputState()])

  doAssert sim.players[playerIndex].lives == 2,
    "snow exposure should damage players when no food is available"

  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp - FoodHealAmount
  sim.players[playerIndex].invulnTicks = 0
  sim.food = 0
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood
  sim.step([InputState()])

  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp,
    "carried food should be usable as emergency rations"
  doAssert not sim.players[playerIndex].carrying

testSafeOriginAndReusableRoles()
testFrontierScoreIsShared()
testMobHpScalesByProgressZone()
testPlayerDropsCarriedCoinsOnDeath()
testMobTelegraphsBeforeLunging()
testMobChasesNearbyPlayers()
testPlayerSpeedIsSlower()
testBiomeGroundsAndWeather()
testSpritePlayerViewportAndBiomeBackground()
testSpriteProtocolPacketMatchesReferenceParsers()
testBiomeMonsterSpeciesBreadth()
testMonsterTacticalHooksAndStatuses()
testTerrainMovementModifiersAffectPlayers()
testElevationSlowsHighGround()
testResourceHarvestAndCampActivation()
testBeaconAndBossScoring()
testDpsCleaveSpecialDamagesNearbyMobs()
testFoodAndColdSurvivalPressure()
echo "All tests passed"

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

  doAssert sim.players[playerIndex].lives == 0
  doAssert sim.playerDowned(playerIndex),
    "defeated player should enter a rescue window before respawn"
  doAssert sim.players[playerIndex].coins == dropValue,
    "downed player should keep coins unless the rescue window expires"
  doAssert not sim.hasPickup(PickupCoin, dropValue),
    "downed player should not drop coins before bleeding out"

  for _ in 0 ..< DownedRespawnTicks:
    sim.step([InputState()])

  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp,
    "bled-out player should respawn with full hp"
  doAssert sim.players[playerIndex].coins == 0,
    "bled-out player should lose carried coins"
  doAssert sim.hasPickup(PickupCoin, dropValue),
    "bleed-out should drop one coin pickup worth all carried coins"

proc testDownedPlayerCanBeRescuedByNearbyAlly() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)

  let
    playerIndex = sim.addPlayer("player1")
    allyIndex = sim.addPlayer("ally")
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].lives = 1
  sim.players[playerIndex].coins = 7
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[allyIndex].x = sim.players[playerIndex].x + WorldTileSize
  sim.players[allyIndex].y = sim.players[playerIndex].y
  sim.players[allyIndex].bounds = sim.playerBoundsFor(sim.players[allyIndex])

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

  sim.step([InputState(), InputState()])
  doAssert sim.playerDowned(playerIndex)

  for _ in 0 ..< DownedRescueTicks:
    sim.step([InputState(), InputState()])

  doAssert not sim.playerDowned(playerIndex)
  doAssert sim.players[playerIndex].lives == DownedReviveHp
  doAssert sim.players[playerIndex].coins == 7,
    "rescued player should keep carried coin value"
  doAssert not sim.hasPickup(PickupCoin, 7),
    "rescue should prevent the bleed-out coin drop"

proc testCampActivationDoesNotHalfReviveDownedPlayers() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.wood = CampWoodCost
  sim.stone = CampStoneCost

  let
    downedIndex = sim.addPlayer("downed")
    allyIndex = sim.addPlayer("ally")
  sim.players[allyIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[allyIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[allyIndex].bounds = sim.playerBoundsFor(sim.players[allyIndex])
  sim.players[downedIndex].x = sim.players[allyIndex].x + WorldTileSize
  sim.players[downedIndex].y = sim.players[allyIndex].y
  sim.players[downedIndex].bounds = sim.playerBoundsFor(sim.players[downedIndex])
  sim.players[downedIndex].lives = 0
  sim.players[downedIndex].downedTicks = DownedRespawnTicks
  sim.landmarks.add(Landmark(
    tx: sim.players[allyIndex].x div WorldTileSize,
    ty: sim.players[allyIndex].y div WorldTileSize,
    kind: LandmarkCamp,
    hp: 1,
    done: false
  ))

  sim.step([InputState(), InputState()])

  doAssert sim.landmarks[0].done
  doAssert sim.playerDowned(downedIndex),
    "camp healing should not create a live player with a stale downed timer"
  doAssert sim.players[downedIndex].lives == 0

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

proc testSpriteProtocolWeatherOverlays() =
  var playerSim = initPartyProgressorForTest()
  playerSim.clearTerrain()
  playerSim.mobs.setLen(0)
  playerSim.pickups.setLen(0)
  playerSim.landmarks.setLen(0)
  playerSim.fillGround(GroundSnow, BiomeSnow)
  let playerIndex = playerSim.addPlayer("player1")
  playerSim.players[playerIndex].x = firstTileForBiome(BiomeSnow) * WorldTileSize
  playerSim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  playerSim.players[playerIndex].bounds =
    playerSim.playerBoundsFor(playerSim.players[playerIndex])

  var nextPlayerState: PlayerViewerState
  let playerPacket = playerSim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextPlayerState
  )
  let playerLabels = playerPacket.parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "weather snow" in playerLabels,
    "sprite player observations should show snow weather overlays"

  var globalSim = initPartyProgressorForTest()
  globalSim.clearTerrain()
  globalSim.mobs.setLen(0)
  globalSim.pickups.setLen(0)
  globalSim.landmarks.setLen(0)
  globalSim.fillGround(GroundSand, BiomeDesert)
  var nextGlobalState: GlobalViewerState
  let globalPacket = globalSim.buildSpriteProtocolUpdates(
    initGlobalViewerState(),
    nextGlobalState
  )
  let globalLabels = globalPacket.parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "weather dust" in globalLabels,
    "global sprite observations should show biome weather overlays"

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
  doAssert visibleLabels.anyIt(it.contains("NEXT PICK ROLE TANK DPS HEAL")),
    "local HUD should tell new players to choose a role"
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

proc testExpeditionObjectiveHudGuidesNextStep() =
  var sim = initPartyProgressorForTest()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  let playerIndex = sim.addPlayer("player1")
  doAssert sim.expeditionObjectiveHint(playerIndex) ==
    "NEXT PICK ROLE TANK DPS HEAL"

  sim.players[playerIndex].applyRole(RoleTank)
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT PUSH RIGHT"

  sim.players[playerIndex].x = firstTileForBiome(BiomePlains) * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT RALLY T"

  for landmark in sim.landmarks.mitems:
    if sim.tileBiomeKind(landmark.tx, landmark.ty) == BiomePlains and
        landmark.kind == LandmarkWaystation:
      landmark.done = true
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT GATHER W2 S1"

  sim.wood = CampWoodCost
  sim.stone = CampStoneCost
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT BUILD CAMP"

  for landmark in sim.landmarks.mitems:
    if sim.tileBiomeKind(landmark.tx, landmark.ty) == BiomePlains and
        landmark.kind == LandmarkCamp:
      landmark.done = true
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT RELIC 0/3"

  sim.relicShards = FinalGateRelicCost
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT CAMP 0/2"

  sim.campsActivated = FinalGateCampCost
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT DEFEAT BOSS"

  sim.bossDefeated = true
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT OPEN GATE"

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
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp
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

proc testSpriteProtocolShowsStatusAndObjectiveAffordances() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + 2 * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].poisonTicks = StatusPoisonTicks
  sim.players[playerIndex].slowTicks = StatusSlowTicks
  sim.players[playerIndex].chillTicks = StatusChillTicks
  sim.players[playerIndex].lives = max(1, sim.players[playerIndex].maxHp div 2)
  let downedIndex = sim.addPlayer("downed")
  sim.players[downedIndex].x = sim.players[playerIndex].x + WorldTileSize
  sim.players[downedIndex].y = sim.players[playerIndex].y + WorldTileSize
  sim.players[downedIndex].bounds = sim.playerBoundsFor(sim.players[downedIndex])
  sim.players[downedIndex].lives = 0
  sim.players[downedIndex].downedTicks = DownedRespawnTicks

  sim.mobs.add(Mob(
    kind: WraithMob,
    species: SpeciesRuinWraith,
    x: sim.players[playerIndex].x + WorldTileSize,
    y: sim.players[playerIndex].y,
    sprite: sim.mobSpriteFor(WraithMob),
    bounds: sim.mobBoundsFor(WraithMob),
    hp: mobMaxHp(WraithMob, sim.players[playerIndex].x),
    attackCooldown: 99
  ))
  doAssert sim.playerIsolationThreatened(playerIndex)

  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkCamp,
    hp: 1,
    done: false
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 1,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkFinalGate,
    hp: 1,
    done: false
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 1,
    ty: sim.players[playerIndex].y div WorldTileSize + 1,
    kind: LandmarkShrine,
    hp: 1,
    done: false
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 2,
    ty: sim.players[playerIndex].y div WorldTileSize + 1,
    kind: LandmarkRescue,
    hp: 1,
    done: false
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 3,
    ty: sim.players[playerIndex].y div WorldTileSize + 1,
    kind: LandmarkLair,
    hp: LairHp,
    done: false
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 4,
    ty: sim.players[playerIndex].y div WorldTileSize + 1,
    kind: LandmarkWaystation,
    hp: 1,
    done: false
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 2,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkCamp,
    hp: 1,
    done: true
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 3,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkCamp,
    hp: 1,
    done: true,
    progress: 1
  ))

  var nextState: PlayerViewerState
  let packet = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  )
  let labels = packet.parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status poison" in labels
  doAssert "status slow" in labels
  doAssert "status chill" in labels
  doAssert "status alone" in labels
  doAssert "status help" in labels
  doAssert "status down" in labels
  doAssert "prompt camp w2 s1" in labels
  doAssert "prompt shelter" in labels
  doAssert "prompt fort" in labels
  doAssert "prompt shrine f2" in labels
  doAssert "prompt rescue f2" in labels
  doAssert "prompt lair" in labels
  doAssert "prompt forage h" in labels
  doAssert "prompt gate c2 boss r3" in labels

  let spriteLabels = packet.parseSpriteProtocolPacket().sprites.values.toSeq.mapIt(
    it.label
  )
  doAssert "prompt bridge t" in spriteLabels
  doAssert "prompt oasis h" in spriteLabels
  doAssert "prompt hearth h" in spriteLabels
  doAssert "prompt lantern d" in spriteLabels
  doAssert "prompt ward t" in spriteLabels

proc testChatPingsShowCompactStatusBadges() =
  doAssert playerPingForMessage("regroup at camp") == PingRegroup
  doAssert playerPingForMessage("need help") == PingHelp
  doAssert playerPingForMessage("take relic") == PingObjective
  doAssert playerPingForMessage("food here") == PingFood
  doAssert playerPingForMessage("rescue now") == PingRescue
  doAssert playerPingForMessage("clear lair") == PingLair

  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + 2 * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])

  sim.setPlayerMessage(playerIndex, "rescue now")
  doAssert sim.players[playerIndex].pingKind == PingRescue
  doAssert sim.players[playerIndex].pingTicks == PingDurationTicks
  sim.setPlayerMessage(playerIndex, "ok")
  doAssert sim.players[playerIndex].pingKind == PingNone
  doAssert sim.players[playerIndex].pingTicks == 0
  sim.setPlayerMessage(playerIndex, "rescue now")

  var nextState: PlayerViewerState
  let packet = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  )
  let labels = packet.parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status ping rescue" in labels

  for _ in 0 ..< PingDurationTicks:
    sim.step([InputState()])

  doAssert sim.players[playerIndex].pingKind == PingNone
  doAssert sim.players[playerIndex].pingTicks == 0

proc testSpriteProtocolShowsMonsterThreatTelegraphs() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + 2 * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  doAssert sim.players[playerIndex].statusLabel() == "ok"

  let threats = [
    SpeciesDuneScorpion,
    SpeciesMudSlime,
    SpeciesSnowWolf,
    SpeciesRuinWraith
  ]
  for i, species in threats:
    let kind = species.speciesKind()
    sim.mobs.add(Mob(
      kind: kind,
      species: species,
      x: sim.players[playerIndex].x + WorldTileSize + i * 18,
      y: sim.players[playerIndex].y - WorldTileSize + i * 20,
      sprite: sim.mobSpriteFor(kind),
      bounds: sim.mobBoundsFor(kind),
      hp: mobMaxHp(kind, sim.players[playerIndex].x),
      attackCooldown: 99
    ))

  var nextState: PlayerViewerState
  let labels = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status poison" in labels
  doAssert "status slow" in labels
  doAssert "status chill" in labels
  doAssert "status alone" in labels

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
  let
    campTx = sim.players[playerIndex].x div WorldTileSize
    campTy = sim.players[playerIndex].y div WorldTileSize
  for ty in campTy - CampShortcutHalfHeightTiles ..
      campTy + CampShortcutHalfHeightTiles:
    for tx in campTx - CampShortcutBackTiles ..
        campTx + CampShortcutForwardTiles:
      if tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles:
        let index = tileIndex(tx, ty)
        sim.groundKinds[index] = GroundMud
        sim.biomeKinds[index] = BiomeSwamp
        sim.elevations[index] = 5
        sim.tiles[index] = true
  sim.groundKinds[tileIndex(campTx + CampShortcutForwardTiles, campTy)] =
    GroundWater
  sim.landmarks.add(Landmark(
    tx: campTx,
    ty: campTy,
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
  for ty in campTy - CampShortcutHalfHeightTiles ..
      campTy + CampShortcutHalfHeightTiles:
    for tx in campTx - CampShortcutBackTiles ..
        campTx + CampShortcutForwardTiles:
      if tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles:
        let index = tileIndex(tx, ty)
        doAssert sim.tileGroundKind(tx, ty) == GroundBridge,
          "swamp camp shortcut should reveal a bridge corridor"
        doAssert sim.elevations[index] <= 1,
          "camp shortcut should cut high elevation into an easier route"
        doAssert not sim.tiles[index],
          "camp shortcut should clear blocking props from the corridor"

proc testCampFortificationConsumesResourcesAndDefendsStagingArea() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  sim.wood = CampFortificationWoodCost
  sim.stone = CampFortificationStoneCost
  sim.mobSpawnCooldown = 999

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  let
    campTx = sim.players[playerIndex].x div WorldTileSize
    campTy = sim.players[playerIndex].y div WorldTileSize
    campX = campTx * WorldTileSize
    campY = campTy * WorldTileSize
  sim.landmarks.add(Landmark(
    tx: campTx,
    ty: campTy,
    kind: LandmarkCamp,
    hp: 1,
    done: true
  ))
  sim.mobs.add(Mob(
    kind: WolfMob,
    species: SpeciesForestWolf,
    x: campX,
    y: campY + WorldTileSize,
    sprite: sim.mobSpriteFor(WolfMob),
    bounds: sim.mobBoundsFor(WolfMob),
    hp: 4,
    attackCooldown: 99
  ))
  sim.mobs.add(Mob(
    kind: WolfMob,
    species: SpeciesDireWolf,
    x: campX + CampFortificationRadius + WorldTileSize * 4,
    y: campY,
    sprite: sim.mobSpriteFor(WolfMob),
    bounds: sim.mobBoundsFor(WolfMob),
    hp: 4,
    attackCooldown: 99
  ))
  sim.mobs.add(Mob(
    kind: BossMob,
    species: SpeciesNone,
    x: campX,
    y: campY + WorldTileSize,
    sprite: sim.bossSprite,
    bounds: sim.bossBounds,
    hp: BossHp,
    attackCooldown: 99
  ))

  sim.step([InputState()])

  doAssert sim.landmarks[0].campIsFortified()
  doAssert sim.wood == 0 and sim.stone == 0
  doAssert sim.mobs.len == 2,
    "fortified camps should clear nearby non-boss threats only"
  doAssert sim.mobs.anyIt(it.species == SpeciesDireWolf)
  doAssert sim.mobs.anyIt(it.kind == BossMob)

  sim.mobs.add(Mob(
    kind: SlimeMob,
    species: SpeciesMudSlime,
    x: campX,
    y: campY - WorldTileSize,
    sprite: sim.mobSpriteFor(SlimeMob),
    bounds: sim.mobBoundsFor(SlimeMob),
    hp: 4,
    attackCooldown: 99
  ))
  sim.step([InputState()])

  doAssert sim.mobs.len == 2,
    "fortified camps should continue defending the staging area"
  doAssert sim.mobs.allIt(it.kind == BossMob or it.species == SpeciesDireWolf)

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
  doAssert not sim.landmarks[0].done,
    "final gate should require camp progress as well as relics and boss defeat"
  sim.campsActivated = FinalGateCampCost
  sim.step([InputState()])
  doAssert sim.landmarks[0].done

proc testShrineSideObjectiveScoringAndSustain() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  sim.food = 0

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp - 2
  sim.players[playerIndex].poisonTicks = StatusPoisonTicks
  sim.players[playerIndex].slowTicks = StatusSlowTicks
  sim.players[playerIndex].chillTicks = StatusChillTicks
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkShrine,
    hp: 1,
    done: false
  ))

  sim.step([InputState()])

  doAssert sim.landmarks[0].done
  doAssert sim.sideObjectivesCompleted == 1
  doAssert sim.food == ShrineFoodBonus
  doAssert sim.players[playerIndex].lives ==
    sim.players[playerIndex].maxHp - 1
  doAssert sim.players[playerIndex].poisonTicks == 0
  doAssert sim.players[playerIndex].slowTicks == 0
  doAssert sim.players[playerIndex].chillTicks == 0
  doAssert sim.teamScore() == sim.frontierTiles() + SideObjectiveScoreValue
  let scores = parseJson(sim.playerScoresJson())
  doAssert scores["side_objectives_completed"][0].getInt() == 1

proc testRescueSideObjectiveRequiresHoldAndRewardsParty() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  sim.food = 0

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp - 2
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkRescue,
    hp: 1,
    done: false
  ))

  sim.step([InputState()])

  doAssert not sim.landmarks[0].done,
    "rescue events should require a short hold instead of instant pickup"
  doAssert sim.landmarks[0].progress == 1
  doAssert sim.sideObjectivesCompleted == 0

  for _ in 1 ..< RescueEventTicks:
    sim.step([InputState()])

  doAssert sim.landmarks[0].done
  doAssert sim.sideObjectivesCompleted == 1
  doAssert sim.food == RescueFoodBonus
  doAssert sim.players[playerIndex].lives ==
    sim.players[playerIndex].maxHp - 1
  doAssert sim.teamScore() == sim.frontierTiles() + SideObjectiveScoreValue

proc testHealerCompletesRescueEventsFaster() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].applyRole(RoleHealer)
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkRescue,
    hp: 1,
    done: false
  ))

  for _ in 0 ..< RescueEventTicks div HealerRescueEventStep:
    sim.step([InputState()])

  doAssert sim.landmarks[0].done,
    "healer should complete rescue detours twice as quickly"

proc testMonsterLairAttackRewardsAndPacifiesThreats() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  sim.food = 0
  sim.stone = 0
  sim.mobSpawnCooldown = 999

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].applyRole(RoleDps)
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].facing = FaceRight
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])
  let hit = sim.attackRect(sim.players[playerIndex])
  let
    lairTx = clamp((hit.x + hit.w div 2) div WorldTileSize, 0, WorldWidthTiles - 1)
    lairTy = clamp((hit.y + hit.h div 2) div WorldTileSize, 0, WorldHeightTiles - 1)
    lairX = lairTx * WorldTileSize
    lairY = lairTy * WorldTileSize
  sim.landmarks.add(Landmark(
    tx: lairTx,
    ty: lairTy,
    kind: LandmarkLair,
    hp: LairHp,
    done: false
  ))
  sim.mobs.add(Mob(
    kind: WolfMob,
    species: SpeciesForestWolf,
    x: lairX,
    y: lairY + WorldTileSize * 2,
    sprite: sim.mobSpriteFor(WolfMob),
    bounds: sim.mobBoundsFor(WolfMob),
    hp: 4,
    attackCooldown: 99
  ))
  sim.mobs.add(Mob(
    kind: WolfMob,
    species: SpeciesDireWolf,
    x: lairX + LairPacifyRadius + WorldTileSize * 4,
    y: lairY,
    sprite: sim.mobSpriteFor(WolfMob),
    bounds: sim.mobBoundsFor(WolfMob),
    hp: 4,
    attackCooldown: 99
  ))
  sim.mobs.add(Mob(
    kind: BossMob,
    species: SpeciesNone,
    x: lairX,
    y: lairY + WorldTileSize * 2,
    sprite: sim.bossSprite,
    bounds: sim.bossBounds,
    hp: BossHp,
    attackCooldown: 99
  ))

  sim.step([InputState(attack: true)])

  doAssert not sim.landmarks[0].done
  doAssert sim.landmarks[0].hp == LairHp - 3,
    "DPS attacks should visibly damage lairs without instantly clearing them"
  doAssert sim.sideObjectivesCompleted == 0

  sim.players[playerIndex].attackTicks = 0
  sim.players[playerIndex].attackResolved = false
  sim.step([InputState(attack: true)])

  doAssert sim.landmarks[0].done
  doAssert sim.sideObjectivesCompleted == 1
  doAssert sim.food == LairFoodBonus
  doAssert sim.stone == LairStoneBonus
  doAssert sim.mobs.len == 2,
    "destroyed lairs should pacify nearby threats without deleting bosses; remaining=" &
      $sim.mobs.len
  doAssert sim.mobs.anyIt(it.species == SpeciesDireWolf)
  doAssert sim.mobs.anyIt(it.kind == BossMob)
  doAssert sim.teamScore() == sim.frontierTiles() + SideObjectiveScoreValue

proc testBiomeWaystationsCreateRoleDetoursAndShelters() =
  doAssert waystationActivationStep(BiomeSwamp, RoleTank) ==
    BiomeWaystationFastStep
  doAssert waystationActivationStep(BiomeSwamp, RoleDps) == 1
  doAssert BiomeSwamp.waystationPromptLabel() == "BRIDGE T"
  doAssert BiomeSnow.waystationPromptLabel() == "HEARTH H"

  let seededSim = initPartyProgressorForTest()
  doAssert seededSim.landmarks.countIt(it.kind == LandmarkWaystation) == BiomeCount,
    "one waystation should be seeded into each adventure biome"

  var swampSim = initPartyProgressorForTest()
  swampSim.clearTerrain()
  swampSim.mobs.setLen(0)
  swampSim.pickups.setLen(0)
  swampSim.landmarks.setLen(0)
  swampSim.fillGround(GroundMud, BiomeSwamp)
  swampSim.mobSpawnCooldown = 999

  let swampPlayer = swampSim.addPlayer("tank")
  swampSim.players[swampPlayer].applyRole(RoleTank)
  swampSim.players[swampPlayer].x = SafeZoneRightPixels + WorldTileSize
  swampSim.players[swampPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  swampSim.players[swampPlayer].bounds =
    swampSim.playerBoundsFor(swampSim.players[swampPlayer])
  let
    bridgeTx = swampSim.players[swampPlayer].x div WorldTileSize
    bridgeTy = swampSim.players[swampPlayer].y div WorldTileSize
  for ty in bridgeTy - BiomeWaystationRouteHalfHeightTiles ..
      bridgeTy + BiomeWaystationRouteHalfHeightTiles:
    for tx in bridgeTx - BiomeWaystationRouteBackTiles ..
        bridgeTx + BiomeWaystationRouteForwardTiles:
      if tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles:
        let index = tileIndex(tx, ty)
        swampSim.groundKinds[index] = GroundWater
        swampSim.biomeKinds[index] = BiomeSwamp
        swampSim.elevations[index] = 5
        swampSim.tiles[index] = true
  swampSim.landmarks.add(Landmark(
    tx: bridgeTx,
    ty: bridgeTy,
    kind: LandmarkWaystation,
    hp: 1,
    done: false
  ))

  for _ in 0 ..< BiomeWaystationTicks div BiomeWaystationFastStep:
    swampSim.step([InputState()])

  doAssert swampSim.landmarks[0].done
  doAssert swampSim.sideObjectivesCompleted == 1
  doAssert swampSim.stone == 1
  for ty in bridgeTy - BiomeWaystationRouteHalfHeightTiles ..
      bridgeTy + BiomeWaystationRouteHalfHeightTiles:
    for tx in bridgeTx - BiomeWaystationRouteBackTiles ..
        bridgeTx + BiomeWaystationRouteForwardTiles:
      if tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles:
        let index = tileIndex(tx, ty)
        doAssert swampSim.tileGroundKind(tx, ty) == GroundBridge,
          "swamp waystations should turn local water into a bridge route"
        doAssert swampSim.elevations[index] <= 1,
          "waystations should make nearby elevation easier to cross"
        doAssert not swampSim.tiles[index],
          "waystations should clear blockers from their local route"

  var snowSim = initPartyProgressorForTest()
  snowSim.clearTerrain()
  snowSim.mobs.setLen(0)
  snowSim.pickups.setLen(0)
  snowSim.landmarks.setLen(0)
  snowSim.fillGround(GroundSnow, BiomeSnow)
  snowSim.mobSpawnCooldown = 999
  snowSim.food = 0

  let snowPlayer = snowSim.addPlayer("healer")
  snowSim.players[snowPlayer].applyRole(RoleHealer)
  snowSim.players[snowPlayer].x = firstTileForBiome(BiomeSnow) * WorldTileSize
  snowSim.players[snowPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  snowSim.players[snowPlayer].bounds =
    snowSim.playerBoundsFor(snowSim.players[snowPlayer])
  snowSim.players[snowPlayer].lives =
    snowSim.players[snowPlayer].maxHp - BiomeWaystationHealAmount
  snowSim.players[snowPlayer].chillTicks = StatusChillTicks
  snowSim.landmarks.add(Landmark(
    tx: snowSim.players[snowPlayer].x div WorldTileSize,
    ty: snowSim.players[snowPlayer].y div WorldTileSize,
    kind: LandmarkWaystation,
    hp: 1,
    done: false
  ))

  for _ in 0 ..< BiomeWaystationTicks div BiomeWaystationFastStep:
    snowSim.step([InputState()])

  doAssert snowSim.landmarks[0].done
  doAssert snowSim.sideObjectivesCompleted == 1
  doAssert snowSim.food == BiomeWaystationFoodBonus
  doAssert snowSim.players[snowPlayer].lives == snowSim.players[snowPlayer].maxHp
  doAssert snowSim.players[snowPlayer].chillTicks == 0
  doAssert snowSim.playerNearExpeditionShelter(snowPlayer),
    "completed snow hearths should become local cold shelters"

  snowSim.food = 0
  let shelteredHp = snowSim.players[snowPlayer].lives
  for _ in 0 ..< ColdExposureIntervalTicks:
    snowSim.step([InputState()])
  doAssert snowSim.players[snowPlayer].lives == shelteredHp,
    "snow hearth shelter should prevent cold exposure damage"

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

proc testHealerTriageAndHelpAffordance() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  sim.food = 0

  let woundedIndex = sim.addPlayer("wounded")
  sim.players[woundedIndex].x = SafeZoneRightPixels + 2 * WorldTileSize
  sim.players[woundedIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[woundedIndex].bounds =
    sim.playerBoundsFor(sim.players[woundedIndex])
  sim.players[woundedIndex].lives = max(
    1,
    sim.players[woundedIndex].maxHp div 2
  )

  let healerIndex = sim.addPlayer("healer")
  sim.players[healerIndex].x =
    sim.players[woundedIndex].x + WorldTileSize
  sim.players[healerIndex].y = sim.players[woundedIndex].y
  sim.players[healerIndex].applyRole(RoleHealer)
  sim.players[healerIndex].bounds =
    sim.playerBoundsFor(sim.players[healerIndex])

  doAssert sim.playerNeedsHelp(woundedIndex)
  let before = sim.players[woundedIndex].lives
  sim.tickCount = HealerTriageIntervalTicks - 1
  sim.step([InputState(), InputState()])
  doAssert sim.players[woundedIndex].lives ==
    before + HealerTriageHealAmount,
    "nearby healer should passively triage low-health teammates"
  doAssert sim.players[healerIndex].healingDone == HealerTriageHealAmount

  sim.players[woundedIndex].lives = before
  sim.players[healerIndex].x =
    sim.players[woundedIndex].x + HealerTriageRadius + WorldTileSize
  sim.players[healerIndex].bounds =
    sim.playerBoundsFor(sim.players[healerIndex])
  sim.tickCount = HealerTriageIntervalTicks - 1
  sim.step([InputState(), InputState()])
  doAssert sim.players[woundedIndex].lives == before,
    "triage should require the healer to stay near the wounded teammate"

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

proc testCampShelterAndRecoveryInfrastructure() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundSnow, BiomeSnow)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + 2 * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].invulnTicks = 0
  sim.food = 0
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkCamp,
    hp: 1,
    done: true
  ))

  doAssert sim.playerNearActivatedCamp(playerIndex)

  sim.players[playerIndex].lives = 3
  sim.tickCount = ColdExposureIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == 3,
    "activated camp shelters should block snow exposure damage"

  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp
  sim.players[playerIndex].poisonTicks = StatusPoisonTicks
  sim.players[playerIndex].slowTicks = StatusSlowTicks
  sim.players[playerIndex].chillTicks = StatusChillTicks
  sim.tickCount = StatusPoisonIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp,
    "camp shelter should prevent poison pulse damage while recovering"
  doAssert sim.players[playerIndex].poisonTicks <
    StatusPoisonTicks - CampStatusRecoveryTicks,
    "camp shelter should cleanse poison faster than ordinary ticking"
  doAssert sim.players[playerIndex].slowTicks <
    StatusSlowTicks - 1,
    "camp shelter should speed slow recovery"
  doAssert sim.players[playerIndex].chillTicks <
    StatusChillTicks - 1,
    "camp shelter should speed chill recovery"

  sim.players[playerIndex].poisonTicks = 0
  sim.players[playerIndex].slowTicks = 0
  sim.players[playerIndex].chillTicks = 0
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp - 1
  sim.tickCount = CampRecoveryIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp,
    "camp shelter should slowly heal resting players"

  sim.players[playerIndex].x += CampShelterRadius + WorldTileSize
  sim.players[playerIndex].lives = 3
  sim.players[playerIndex].invulnTicks = 0
  sim.tickCount = ColdExposureIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == 2,
    "snow exposure should still damage players away from camp shelter"

testSafeOriginAndReusableRoles()
testFrontierScoreIsShared()
testMobHpScalesByProgressZone()
testPlayerDropsCarriedCoinsOnDeath()
testDownedPlayerCanBeRescuedByNearbyAlly()
testCampActivationDoesNotHalfReviveDownedPlayers()
testMobTelegraphsBeforeLunging()
testMobChasesNearbyPlayers()
testPlayerSpeedIsSlower()
testBiomeGroundsAndWeather()
testSpritePlayerViewportAndBiomeBackground()
testSpriteProtocolWeatherOverlays()
testSpriteProtocolPacketMatchesReferenceParsers()
testExpeditionObjectiveHudGuidesNextStep()
testBiomeMonsterSpeciesBreadth()
testMonsterTacticalHooksAndStatuses()
testSpriteProtocolShowsStatusAndObjectiveAffordances()
testChatPingsShowCompactStatusBadges()
testSpriteProtocolShowsMonsterThreatTelegraphs()
testTerrainMovementModifiersAffectPlayers()
testElevationSlowsHighGround()
testResourceHarvestAndCampActivation()
testCampFortificationConsumesResourcesAndDefendsStagingArea()
testBeaconAndBossScoring()
testShrineSideObjectiveScoringAndSustain()
testRescueSideObjectiveRequiresHoldAndRewardsParty()
testHealerCompletesRescueEventsFaster()
testMonsterLairAttackRewardsAndPacifiesThreats()
testBiomeWaystationsCreateRoleDetoursAndShelters()
testDpsCleaveSpecialDamagesNearbyMobs()
testHealerTriageAndHelpAffordance()
testFoodAndColdSurvivalPressure()
testCampShelterAndRecoveryInfrastructure()
echo "All tests passed"

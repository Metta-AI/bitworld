import
  std/[algorithm, json, os, sequtils, strutils, tables],
  pixie,
  supersnappy,
  ../common/protocol,
  ../common/server,
  ../party_progressor/global,
  ../party_progressor/sim

const
  RootDir = currentSourcePath.parentDir.parentDir
  ObservationPreviewDir = RootDir / "out" / "party_progressor_observations"

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

proc firstForwardPickup(sim: SimServer, kind: PickupKind): Pickup =
  for pickup in sim.pickups:
    if pickup.kind == kind and pickup.x >= SafeZoneRightPixels:
      return pickup
  raise newException(ValueError, "missing forward pickup: " & $kind)

proc testSafeOriginAndReusableRoles() =
  var sim = initPartyProgressorForTest()
  let playerIndex = sim.addPlayer("player1")
  doAssert sim.players[playerIndex].x < SafeZoneRightPixels,
    "player should spawn inside the safe origin"
  doAssert sim.hasPickup(PickupTankGear)
  doAssert sim.hasPickup(PickupDpsGear)
  doAssert sim.hasPickup(PickupHealerGear)

  let
    tankGear = sim.firstPickup(PickupTankGear)
    dpsGear = sim.firstPickup(PickupDpsGear)
    healerGear = sim.firstPickup(PickupHealerGear)
  doAssert tankGear.y < dpsGear.y and healerGear.y > dpsGear.y,
    "starter role gear should read as up/tank, center/dps, down/healer"
  doAssert dpsGear.x >= tankGear.x + WorldTileSize,
    "DPS starter gear should sit in a separate lane to prevent accidental swaps"
  sim.players[playerIndex].x = tankGear.x
  sim.players[playerIndex].y = tankGear.y
  sim.step([InputState()])

  doAssert sim.players[playerIndex].role == RoleTank
  doAssert sim.players[playerIndex].maxHp == TankPlayerHp
  doAssert sim.hasPickup(PickupTankGear),
    "role gear must stay available for other players"

  sim.players[playerIndex].x = dpsGear.x
  sim.players[playerIndex].y = dpsGear.y
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.step([InputState()])
  doAssert sim.players[playerIndex].role == RoleTank,
    "origin role gear should not silently swap an already-role player"

  let secondPlayerIndex = sim.addPlayer("player2")
  sim.players[secondPlayerIndex].x = dpsGear.x
  sim.players[secondPlayerIndex].y = dpsGear.y
  sim.players[secondPlayerIndex].bounds =
    sim.playerBoundsFor(sim.players[secondPlayerIndex])
  sim.step([InputState(), InputState()])
  doAssert sim.players[secondPlayerIndex].role == RoleDps,
    "origin role gear must stay reusable for unarmed players"

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

proc holdSpecial(
  sim: var SimServer,
  playerIndex: int,
  ticks = HealerPulseHoldTicks
) =
  var inputs = newSeq[InputState](sim.players.len)
  inputs[playerIndex].b = true
  for _ in 0 ..< ticks:
    sim.step(inputs)

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
    pixels: string

  ParsedObject = object
    x, y, z, layer, spriteId: int

  ParsedPacket = object
    sprites: Table[int, ParsedSprite]
    objects: Table[int, ParsedObject]
    layers: Table[int, tuple[layerType, flags: int]]
    viewports: Table[int, tuple[width, height: int]]

  RenderedObservation = object
    width, height: int
    pixels: seq[uint8]

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
      let pixels = supersnappy.uncompress(
        packet.packetBytesToString(offset, compressedLen)
      )
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
        label: label,
        pixels: pixels
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

proc assertCurrentSpriteV1Packet(packet: openArray[uint8]) =
  ## Validates Party Progressor emits the current shared sprite_v1 wire format.
  var
    offset = 0
    sawSprite = false
    sawLayer = false
    sawPlayerViewport = false
  while offset < packet.len:
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01'u8:
      if offset + 10 > packet.len:
        raise newException(ValueError, "truncated sprite header")
      let
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      doAssert width > 0 and height > 0,
        "sprite_v1 sprites must have non-zero dimensions"
      doAssert compressedLen > 0,
        "sprite_v1 sprites must send a Snappy-compressed RGBA payload"
      offset += 10
      if offset + compressedLen + 2 > packet.len:
        raise newException(ValueError, "truncated sprite payload")
      let pixels = supersnappy.uncompress(
        packet.packetBytesToString(offset, compressedLen)
      )
      doAssert pixels.len == width * height * 4,
        "sprite_v1 sprite payloads must decompress to RGBA pixels"
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len:
        raise newException(ValueError, "truncated sprite label")
      offset += labelLen
      sawSprite = true
    of 0x02'u8:
      if offset + 11 > packet.len:
        raise newException(ValueError, "truncated object")
      offset += 11
    of 0x03'u8:
      if offset + 2 > packet.len:
        raise newException(ValueError, "truncated delete")
      offset += 2
    of 0x04'u8:
      discard
    of 0x05'u8:
      if offset + 5 > packet.len:
        raise newException(ValueError, "truncated viewport")
      let
        layerId = int(packet[offset])
        width = packet.readU16(offset + 1)
        height = packet.readU16(offset + 3)
      offset += 5
      if layerId == MapLayerId:
        doAssert width == PlayerViewportWidth,
          "sprite player map viewport should stay on the 11x11 tile view"
        doAssert height == PlayerViewportHeight,
          "sprite player map viewport should stay on the 11x11 tile view"
        sawPlayerViewport = true
    of 0x06'u8:
      if offset + 3 > packet.len:
        raise newException(ValueError, "truncated layer")
      offset += 3
      sawLayer = true
    else:
      raise newException(
        ValueError,
        "Party Progressor /player emitted reserved sprite_v1 server message " &
          $messageType
      )

  doAssert sawSprite, "sprite_v1 packet should define sprites"
  doAssert sawLayer, "sprite_v1 packet should define layers"
  doAssert sawPlayerViewport, "sprite_v1 packet should define the player viewport"

proc objectSpriteLabels(parsed: ParsedPacket): seq[string] =
  for obj in parsed.objects.values:
    if parsed.sprites.hasKey(obj.spriteId):
      result.add(parsed.sprites[obj.spriteId].label)

proc firstSpriteByLabel(parsed: ParsedPacket, label: string): ParsedSprite =
  for sprite in parsed.sprites.values:
    if sprite.label == label:
      return sprite
  raise newException(ValueError, "missing sprite label: " & label)

proc spriteColorStats(
  sprite: ParsedSprite
): tuple[opaque, buckets, largestBucket: int] =
  var buckets: Table[int, int]
  for offset in countup(0, sprite.pixels.len - 4, 4):
    let
      r = int(uint8(ord(sprite.pixels[offset])))
      g = int(uint8(ord(sprite.pixels[offset + 1])))
      b = int(uint8(ord(sprite.pixels[offset + 2])))
      a = int(uint8(ord(sprite.pixels[offset + 3])))
    if a == 0:
      continue
    inc result.opaque
    let bucket = ((r div 18) shl 16) or ((g div 18) shl 8) or (b div 18)
    buckets[bucket] = buckets.getOrDefault(bucket) + 1
  result.buckets = buckets.len
  for count in buckets.values:
    result.largestBucket = max(result.largestBucket, count)

proc rgbaByte(pixels: string, index: int): uint8 =
  uint8(ord(pixels[index]))

proc blendObservationPixel(
  target: var seq[uint8],
  targetIndex: int,
  sourceR,
  sourceG,
  sourceB,
  sourceA: uint8
) =
  let sourceAlpha = int(sourceA)
  if sourceAlpha == 0:
    return
  let targetAlpha = int(target[targetIndex + 3])
  if sourceAlpha == 255 or targetAlpha == 0:
    target[targetIndex] = sourceR
    target[targetIndex + 1] = sourceG
    target[targetIndex + 2] = sourceB
    target[targetIndex + 3] = sourceA
    return
  let outAlpha = sourceAlpha + targetAlpha * (255 - sourceAlpha) div 255
  let source = [sourceR, sourceG, sourceB]
  for channel in 0 ..< source.len:
    let value = (
      int(source[channel]) * sourceAlpha * 255 +
      int(target[targetIndex + channel]) * targetAlpha * (255 - sourceAlpha)
    ) div max(1, outAlpha * 255)
    target[targetIndex + channel] = clamp(value, 0, 255).uint8
  target[targetIndex + 3] = outAlpha.uint8

proc blendObservationPixel(
  target: var seq[uint8],
  targetIndex: int,
  source: string,
  sourceIndex: int
) =
  target.blendObservationPixel(
    targetIndex,
    source.rgbaByte(sourceIndex),
    source.rgbaByte(sourceIndex + 1),
    source.rgbaByte(sourceIndex + 2),
    source.rgbaByte(sourceIndex + 3)
  )

proc blendObservationPixel(
  target: var seq[uint8],
  targetIndex: int,
  source: openArray[uint8],
  sourceIndex: int
) =
  target.blendObservationPixel(
    targetIndex,
    source[sourceIndex],
    source[sourceIndex + 1],
    source[sourceIndex + 2],
    source[sourceIndex + 3]
  )

proc renderPacketLayer(
  parsed: ParsedPacket,
  layerId: int,
  viewport: tuple[width, height: int]
): seq[uint8] =
  result = newSeq[uint8](viewport.width * viewport.height * 4)
  let ordered = parsed.objects.pairs.toSeq.sortedByIt((
    it[1].z,
    it[1].y,
    it[0]
  ))
  for item in ordered:
    let obj = item[1]
    if obj.layer != layerId or not parsed.sprites.hasKey(obj.spriteId):
      continue
    let sprite = parsed.sprites[obj.spriteId]
    if sprite.pixels.len != sprite.width * sprite.height * 4:
      continue
    let
      sx0 = max(0, -obj.x)
      sy0 = max(0, -obj.y)
      sx1 = min(sprite.width, viewport.width - obj.x)
      sy1 = min(sprite.height, viewport.height - obj.y)
    if sx0 >= sx1 or sy0 >= sy1:
      continue
    for sy in sy0 ..< sy1:
      for sx in sx0 ..< sx1:
        result.blendObservationPixel(
          ((obj.y + sy) * viewport.width + obj.x + sx) * 4,
          sprite.pixels,
          (sy * sprite.width + sx) * 4
        )

proc renderSpriteProtocolObservation(parsed: ParsedPacket): RenderedObservation =
  let orderedLayers = parsed.layers.pairs.toSeq.sortedByIt((
    it[1].layerType,
    it[0]
  ))
  for item in orderedLayers:
    let layerId = item[0]
    if not parsed.viewports.hasKey(layerId):
      continue
    let viewport = parsed.viewports[layerId]
    result.width = max(result.width, viewport.width)
    result.height = max(result.height, viewport.height)
  if result.width <= 0 or result.height <= 0:
    raise newException(ValueError, "missing observation viewport")
  result.pixels = newSeq[uint8](result.width * result.height * 4)
  for item in orderedLayers:
    let layerId = item[0]
    if not parsed.viewports.hasKey(layerId):
      continue
    let
      viewport = parsed.viewports[layerId]
      layerPixels = parsed.renderPacketLayer(layerId, viewport)
    for y in 0 ..< viewport.height:
      for x in 0 ..< viewport.width:
        result.pixels.blendObservationPixel(
          (y * result.width + x) * 4,
          layerPixels,
          (y * viewport.width + x) * 4
        )

proc observationStats(
  observation: RenderedObservation
): tuple[opaque, transparent, black, colorBuckets: int] =
  var buckets: Table[int, bool]
  for offset in countup(0, observation.pixels.len - 4, 4):
    let
      r = int(observation.pixels[offset])
      g = int(observation.pixels[offset + 1])
      b = int(observation.pixels[offset + 2])
      a = int(observation.pixels[offset + 3])
    if a == 255:
      inc result.opaque
    elif a == 0:
      inc result.transparent
    if a > 0 and r == 0 and g == 0 and b == 0:
      inc result.black
    if a > 0:
      buckets[
        ((r div 24) shl 16) or ((g div 24) shl 8) or (b div 24)
      ] = true
  result.colorBuckets = buckets.len

proc observationAverageColor(
  observation: RenderedObservation
): tuple[r, g, b: int] =
  var count = 0
  for offset in countup(0, observation.pixels.len - 4, 4):
    let a = int(observation.pixels[offset + 3])
    if a == 0:
      continue
    result.r += int(observation.pixels[offset])
    result.g += int(observation.pixels[offset + 1])
    result.b += int(observation.pixels[offset + 2])
    inc count
  if count > 0:
    result.r = result.r div count
    result.g = result.g div count
    result.b = result.b div count

proc observationImage(observation: RenderedObservation): Image =
  result = newImage(observation.width, observation.height)
  for y in 0 ..< observation.height:
    for x in 0 ..< observation.width:
      let offset = (y * observation.width + x) * 4
      result[x, y] = rgba(
        observation.pixels[offset],
        observation.pixels[offset + 1],
        observation.pixels[offset + 2],
        observation.pixels[offset + 3]
      )

proc writeObservationPreview(
  biome: BiomeKind,
  observation: RenderedObservation
): string =
  result = ObservationPreviewDir /
    ("player_observation_" & biome.biomeLabel() & ".png")
  createDir(result.splitFile.dir)
  observation.observationImage().writeFile(result)

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
  doAssert MaxSpeed == 320,
    "players should move faster than the borrowed Big Adventure tuning"
  doAssert DpsMovementSpeedPercent > HealerMovementSpeedPercent
  doAssert HealerMovementSpeedPercent > TankMovementSpeedPercent

proc testBiomeGroundsAndWeather() =
  var sim = initPartyProgressorForTest()
  let
    swampTx = firstTileForBiome(BiomeSwamp)
    desertTx = firstTileForBiome(BiomeDesert)
    centerTy = WorldHeightTiles div 2
  doAssert sim.tileBiomeKind(0, centerTy) == BiomeOrigin
  doAssert sim.tileBiomeKind(swampTx, centerTy) == BiomeSwamp
  doAssert sim.tileGroundKind(swampTx, centerTy) != GroundBridge,
    "swamp center lane should not be a continuous bridge"
  doAssert sim.tileBiomeKind(desertTx, centerTy).weatherForBiome() ==
    WeatherDust
  doAssert groundSpeedPercent(GroundMud) < groundSpeedPercent(GroundRoad)

proc testProceduralExpeditionRepeatsBiomeSegments() =
  doAssert ExpeditionCycleCount >= 4
  doAssert WorldWidthTiles ==
    SafeZoneRightTiles + ExpeditionBiomeSpanTiles * BiomeCount * ExpeditionCycleCount
  for cycle in 0 ..< ExpeditionCycleCount:
    for zone in 0 ..< BiomeCount:
      let
        segment = cycle * BiomeCount + zone
        tx = SafeZoneRightTiles + segment * ExpeditionBiomeSpanTiles
      doAssert biomeForTileX(tx) == biomeForSegmentIndex(zone),
        "rightward expedition should repeat all biome bands in each cycle"
  let sim = initPartyProgressorForTest()
  doAssert sim.landmarks.countIt(it.kind == LandmarkWaystation) ==
    BiomeCount * ExpeditionCycleCount
  doAssert sim.landmarks.anyIt(
    it.kind == LandmarkFinalGate and it.tx > SafeZoneRightTiles +
      ExpeditionBiomeSpanTiles * BiomeCount * 3
  ), "final gate should sit far beyond the first biome pass"

proc testProceduralLandformsAndVisibilityShadow() =
  let seeded = initPartyProgressorForTest()
  let waterTiles = seeded.groundKinds.countIt(it == GroundWater)
  doAssert waterTiles > WorldHeightTiles,
    "procedural expedition should contain lakes and rivers"
  doAssert waterTiles < WorldHeightTiles * BiomeCount * ExpeditionCycleCount,
    "procedural expedition should leave most of the narrow route as land"
  doAssert seeded.groundKinds.countIt(it == GroundBridge) > BiomeCount,
    "rivers should have bridge crossings on the travel route"
  let expectedRiverSystems =
    (ExpeditionCycleCount * BiomeCount + RiverSystemStrideSegments - 1) div
      RiverSystemStrideSegments
  doAssert seeded.riverCrossings.len >= expectedRiverSystems,
    "river systems should create repeated chokepoint crossings"
  let centerTy = WorldHeightTiles div 2
  doAssert seeded.riverCrossings.countIt(it.ty < centerTy) > 0,
    "river chokepoints should sometimes pull the route upward"
  doAssert seeded.riverCrossings.countIt(it.ty > centerTy) > 0,
    "river chokepoints should sometimes pull the route downward"
  doAssert seeded.riverCrossings.allIt(abs(it.ty - centerTy) >= 2),
    "river chokepoints should not collapse back onto the center lane"
  var
    lastSide = 0
    sideChanges = 0
  for crossing in seeded.riverCrossings:
    let side = if crossing.ty < centerTy: -1 else: 1
    if lastSide != 0 and side != lastSide:
      inc sideChanges
    lastSide = side
  doAssert sideChanges >= 2,
    "repeated river crossings should force a visible up/down zig-zag"
  for i in 0 ..< min(6, seeded.riverCrossings.len):
    let crossing = seeded.riverCrossings[i]
    doAssert seeded.tileGroundKind(crossing.tx, crossing.ty) == GroundBridge,
      "registered river crossings should sit on bridge tiles"
    for dx in -RiverShallowHalfWidthTiles .. RiverShallowHalfWidthTiles:
      doAssert seeded.tileGroundKind(crossing.tx + dx, crossing.ty) ==
        GroundBridge,
        "bridge crossings should span the whole river width"
    var waterAbove = false
    var waterBelow = false
    for dx in -(RiverShallowHalfWidthTiles + 2) ..
        RiverShallowHalfWidthTiles + 2:
      if seeded.tileGroundKind(crossing.tx + dx, crossing.ty - 1) ==
          GroundWater:
        waterAbove = true
      if seeded.tileGroundKind(crossing.tx + dx, crossing.ty + 1) ==
          GroundWater:
        waterBelow = true
    doAssert waterAbove,
      "river crossings should be narrow, with deep water immediately above"
    doAssert waterBelow,
      "river crossings should be narrow, with deep water immediately below"
    var bridgeRows = 0
    for ty in crossing.firstTy .. crossing.lastTy:
      var rowHasBridge = false
      for dx in -RiverShallowHalfWidthTiles .. RiverShallowHalfWidthTiles:
        if seeded.tileGroundKind(crossing.tx + dx, ty) == GroundBridge:
          rowHasBridge = true
      if rowHasBridge:
        inc bridgeRows
    doAssert bridgeRows == 1,
      "river crossings should be one-tile chokepoints instead of bridge bands"
  doAssert seeded.elevations.countIt(it >= 4) > BiomeCount,
    "procedural ridges should create meaningful high elevation"
  let
    forestBlockers = seeded.terrainProps.countIt(
      seeded.tileBiomeKind(it.tx, it.ty) == BiomeForest and
        abs(it.ty - centerTy) > LaneHalfHeightTiles
    )
  doAssert forestBlockers > ExpeditionBiomeSpanTiles,
    "forest segments should grow dense off-route terrain and occluders"

  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  let playerIndex = sim.addPlayer("shadow")
  let
    fromTx = SafeZoneRightTiles + 2
    fromTy = centerTy
    ridgeTx = fromTx + 2
    toTx = fromTx + 4
  sim.players[playerIndex].x = fromTx * WorldTileSize
  sim.players[playerIndex].y = fromTy * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.elevations[tileIndex(ridgeTx, fromTy)] = 5
  doAssert sim.tileBlocksSight(ridgeTx, fromTy)
  doAssert not sim.tileVisibleFrom(fromTx, fromTy, toTx, fromTy),
    "high elevation should occlude tiles behind it"

  var nextState: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  ).parseSpriteProtocolPacket()
  doAssert "visibility shadow" in parsed.sprites.values.toSeq.mapIt(it.label),
    "sprite player should receive a visibility shadow overlay"
  let shadow = parsed.firstSpriteByLabel("visibility shadow")
  doAssert shadow.pixels.anyIt(it.ord != 0),
    "visibility shadow sprite should contain non-transparent pixels"

proc testRiverCrossingAmbushesTriggerOnce() =
  var sim = initPartyProgressorForTest()
  doAssert sim.riverCrossings.len > 0,
    "procedural rivers should expose ambush crossings"
  sim.mobs.setLen(0)
  sim.bossDefeated = true
  sim.mobSpawnCooldown = TargetFps * 10
  let
    playerIndex = sim.addPlayer("river scout")
    crossingIndex = 0
    crossing = sim.riverCrossings[crossingIndex]
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  let bounds = sim.players[playerIndex].bounds
  sim.players[playerIndex].x =
    crossing.tx * WorldTileSize + WorldTileSize div 2 -
      bounds.x - bounds.w div 2
  sim.players[playerIndex].y =
    crossing.ty * WorldTileSize + WorldTileSize div 2 -
      bounds.y - bounds.h div 2
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp

  sim.step([InputState()])
  doAssert sim.riverCrossings[crossingIndex].triggered,
    "stepping onto a river bridge should trigger its ambush"
  doAssert sim.mobs.len >= RiverAmbushMobCount,
    "river ambushes should spawn multiple biome enemies"
  let mobCountAfterTrigger = sim.mobs.len
  sim.step([InputState()])
  doAssert sim.mobs.len == mobCountAfterTrigger,
    "river ambushes should only trigger once per crossing"

proc testEarlyBiomeForageAndRallyTactics() =
  var forestSim = initPartyProgressorForTest()
  forestSim.clearTerrain()
  forestSim.mobs.setLen(0)
  forestSim.pickups.setLen(0)
  forestSim.landmarks.setLen(0)
  forestSim.fillGround(GroundGrass, BiomeForest)
  forestSim.food = 0
  let forestPlayer = forestSim.addPlayer("forager")
  forestSim.players[forestPlayer].x =
    firstTileForBiome(BiomeForest) * WorldTileSize
  forestSim.players[forestPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  forestSim.players[forestPlayer].bounds =
    forestSim.playerBoundsFor(forestSim.players[forestPlayer])
  doAssert forestSim.playerBiomeTacticKind(forestPlayer) == BiomeTacticForage
  forestSim.tickCount = ForestForageIntervalTicks - 1
  forestSim.step([InputState()])
  doAssert forestSim.food == 1,
    "forest foraging should trickle a small shared food reserve"
  forestSim.food = ForestForageFoodCap
  forestSim.tickCount = ForestForageIntervalTicks - 1
  forestSim.step([InputState()])
  doAssert forestSim.food == ForestForageFoodCap,
    "forest foraging should stop at its small reserve cap"

  var forageState: PlayerViewerState
  let forageParsed = forestSim.buildSpriteProtocolPlayerUpdates(
    forestPlayer,
    initPlayerViewerState(),
    forageState
  ).parseSpriteProtocolPacket()
  let forageLabels = forageParsed.objectSpriteLabels()
  doAssert "status forage" in forageLabels
  let forageSpriteLabels = forageParsed.sprites.values.toSeq.mapIt(it.label)
  doAssert forageSpriteLabels.anyIt(it.contains("FORAGE")),
    "forest tactic should be visible in the HUD status text"

  var plainsSim = initPartyProgressorForTest()
  plainsSim.clearTerrain()
  plainsSim.mobs.setLen(0)
  plainsSim.pickups.setLen(0)
  plainsSim.landmarks.setLen(0)
  plainsSim.fillGround(GroundRoad, BiomePlains)
  let
    rallyPlayer = plainsSim.addPlayer("rally")
    allyPlayer = plainsSim.addPlayer("ally")
    plainsX = firstTileForBiome(BiomePlains) * WorldTileSize
    plainsY = (WorldHeightTiles div 2) * WorldTileSize
  plainsSim.players[rallyPlayer].x = plainsX
  plainsSim.players[rallyPlayer].y = plainsY
  plainsSim.players[rallyPlayer].applyRole(RoleDps)
  plainsSim.players[rallyPlayer].abilityCooldown = 6
  plainsSim.players[rallyPlayer].bounds =
    plainsSim.playerBoundsFor(plainsSim.players[rallyPlayer])
  plainsSim.players[allyPlayer].x = plainsX + WorldTileSize
  plainsSim.players[allyPlayer].y = plainsY
  plainsSim.players[allyPlayer].bounds =
    plainsSim.playerBoundsFor(plainsSim.players[allyPlayer])
  doAssert plainsSim.playerBiomeTacticKind(rallyPlayer) == BiomeTacticRally
  plainsSim.step([InputState(), InputState()])
  doAssert plainsSim.players[rallyPlayer].abilityCooldown ==
    6 - 1 - PlainsRallyCooldownStep,
    "plains rally should recharge role powers faster when allies group up"

  var rallyState: PlayerViewerState
  let rallyLabels = plainsSim.buildSpriteProtocolPlayerUpdates(
    rallyPlayer,
    initPlayerViewerState(),
    rallyState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status rally" in rallyLabels

  plainsSim.players[rallyPlayer].abilityCooldown = 6
  plainsSim.players[allyPlayer].x += PlainsRallyAllyRadius + WorldTileSize
  plainsSim.players[allyPlayer].bounds =
    plainsSim.playerBoundsFor(plainsSim.players[allyPlayer])
  doAssert plainsSim.playerBiomeTacticKind(rallyPlayer) == BiomeTacticNone
  plainsSim.step([InputState(), InputState()])
  doAssert plainsSim.players[rallyPlayer].abilityCooldown == 5,
    "plains rally cooldown gain should require a nearby ally"

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

  let mapSprite = packet.firstSpriteRawPixels(MapChunkSpriteBase)
  doAssert mapSprite.width == min(MapChunkTileWidth, WorldWidthTiles) * WorldTileSize
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

proc assertSurvivalPressureObservation(
  biome: BiomeKind,
  ground: GroundKind,
  expectedPressure: SurvivalPressureKind,
  expectedSpriteLabel: string
) =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(ground, biome)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = firstTileForBiome(biome) * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])

  doAssert sim.survivalPressureKind(playerIndex) == expectedPressure
  doAssert sim.survivalPressureLabel(playerIndex) ==
    expectedPressure.survivalPressureLabel()

  var nextState: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  ).parseSpriteProtocolPacket()
  let labels = parsed.objectSpriteLabels()
  doAssert expectedSpriteLabel in labels,
    "sprite observations should show " & expectedSpriteLabel & " pressure"
  let statusText = expectedPressure.survivalPressureLabel().toUpperAscii()
  doAssert parsed.sprites.values.toSeq.anyIt(it.label.contains("OK " & statusText)),
    "HUD status line should include the active survival pressure"

proc testSpriteProtocolShowsSurvivalPressureAffordances() =
  assertSurvivalPressureObservation(
    BiomeSwamp,
    GroundMud,
    SurvivalMire,
    "status mire"
  )
  assertSurvivalPressureObservation(
    BiomeSnow,
    GroundSnow,
    SurvivalCold,
    "status cold"
  )
  assertSurvivalPressureObservation(
    BiomeDesert,
    GroundSand,
    SurvivalHeat,
    "status heat"
  )
  assertSurvivalPressureObservation(
    BiomeCave,
    GroundCave,
    SurvivalFog,
    "status fog"
  )

  var groupedSim = initPartyProgressorForTest()
  groupedSim.clearTerrain()
  groupedSim.mobs.setLen(0)
  groupedSim.pickups.setLen(0)
  groupedSim.landmarks.setLen(0)
  groupedSim.fillGround(GroundCave, BiomeCave)
  let
    soloIndex = groupedSim.addPlayer("solo")
    allyIndex = groupedSim.addPlayer("ally")
  groupedSim.players[soloIndex].x = firstTileForBiome(BiomeCave) * WorldTileSize
  groupedSim.players[soloIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  groupedSim.players[soloIndex].bounds =
    groupedSim.playerBoundsFor(groupedSim.players[soloIndex])
  groupedSim.players[allyIndex].x =
    groupedSim.players[soloIndex].x + WorldTileSize
  groupedSim.players[allyIndex].y = groupedSim.players[soloIndex].y
  groupedSim.players[allyIndex].bounds =
    groupedSim.playerBoundsFor(groupedSim.players[allyIndex])
  doAssert groupedSim.survivalPressureKind(soloIndex) == SurvivalSafe,
    "nearby allies should clear fog survival pressure before slow lands"

  var shelteredSim = initPartyProgressorForTest()
  shelteredSim.clearTerrain()
  shelteredSim.mobs.setLen(0)
  shelteredSim.pickups.setLen(0)
  shelteredSim.landmarks.setLen(0)
  shelteredSim.fillGround(GroundSnow, BiomeSnow)
  let shelteredIndex = shelteredSim.addPlayer("sheltered")
  shelteredSim.players[shelteredIndex].x =
    firstTileForBiome(BiomeSnow) * WorldTileSize
  shelteredSim.players[shelteredIndex].y =
    (WorldHeightTiles div 2) * WorldTileSize
  shelteredSim.players[shelteredIndex].bounds =
    shelteredSim.playerBoundsFor(shelteredSim.players[shelteredIndex])
  shelteredSim.landmarks.add(Landmark(
    tx: shelteredSim.players[shelteredIndex].x div WorldTileSize,
    ty: shelteredSim.players[shelteredIndex].y div WorldTileSize,
    kind: LandmarkCamp,
    hp: 1,
    done: true
  ))
  doAssert shelteredSim.survivalPressureKind(shelteredIndex) == SurvivalSafe,
    "activated camps should clear visible cold survival pressure"

proc testRenderedPlayerObservationHasBiomeBackedPixels() =
  var averageBuckets: Table[int, bool]
  for biome in [
    BiomeForest,
    BiomePlains,
    BiomeSwamp,
    BiomeDesert,
    BiomeSnow,
    BiomeCave,
    BiomeRuins
  ]:
    var sim = initPartyProgressorForTest()
    sim.clearTerrain()
    sim.mobs.setLen(0)
    sim.pickups.setLen(0)
    sim.landmarks.setLen(0)
    sim.fillGround(
      case biome
      of BiomePlains:
        GroundFertile
      of BiomeSwamp:
        GroundMud
      of BiomeDesert:
        GroundSand
      of BiomeSnow:
        GroundSnow
      of BiomeCave:
        GroundCave
      of BiomeRuins:
        GroundRuins
      else:
        GroundGrass,
      biome
    )
    let playerIndex = sim.addPlayer("player-" & biome.biomeLabel())
    sim.players[playerIndex].x =
      min(
        WorldWidthPixels - WorldTileSize,
        max(WorldTileSize, firstTileForBiome(biome) * WorldTileSize)
      )
    sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
    sim.players[playerIndex].bounds =
      sim.playerBoundsFor(sim.players[playerIndex])

    var nextState: PlayerViewerState
    let observation = sim.buildSpriteProtocolPlayerUpdates(
      playerIndex,
      initPlayerViewerState(),
      nextState
    ).parseSpriteProtocolPacket().renderSpriteProtocolObservation()
    let
      stats = observation.observationStats()
      pixelCount = observation.width * observation.height
      average = observation.observationAverageColor()
    doAssert observation.width == PlayerViewportWidth
    doAssert observation.height == PlayerViewportHeight
    doAssert stats.opaque == pixelCount,
      "rendered player observation should be fully opaque for " &
        biome.biomeLabel()
    doAssert stats.transparent == 0
    doAssert stats.black < pixelCount div 12,
      "rendered player observation should not regress to black-backed art for " &
        biome.biomeLabel()
    doAssert stats.colorBuckets >= 4,
      "rendered player observation should contain visible terrain/sprite detail"
    let previewPath = writeObservationPreview(biome, observation)
    doAssert fileExists(previewPath),
      "rendered observation preview should be written for " &
        biome.biomeLabel()
    doAssert getFileSize(previewPath) > 0,
      "rendered observation preview should not be empty for " &
        biome.biomeLabel()
    averageBuckets[
      ((average.r div 24) shl 16) or
      ((average.g div 24) shl 8) or
      (average.b div 24)
    ] = true
  doAssert averageBuckets.len >= 5,
    "biome-backed rendered observations should produce distinct color families"

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
  for i, pickup in sim.pickups.pairs:
    if pickup.kind.isRoleGear():
      let objectId = PickupObjectBase + i
      doAssert parsed.objects.hasKey(objectId)
      let spriteLabel = parsed.sprites[parsed.objects[objectId].spriteId].label
      doAssert spriteLabel.startsWith("role "),
        "role gear icons must not masquerade as coin or heart pickups"
  doAssert visibleLabels.anyIt(it == "role tank gear")
  doAssert visibleLabels.anyIt(it == "role dps gear")
  doAssert visibleLabels.anyIt(it == "role heal gear")
  doAssert parsed.firstSpriteByLabel("role tank gear").pixels !=
    parsed.firstSpriteByLabel("role dps gear").pixels,
    "tank and dps role guilds should use distinct building icons"
  doAssert parsed.firstSpriteByLabel("role heal gear").pixels !=
    parsed.firstSpriteByLabel("role dps gear").pixels,
    "healer and dps role guilds should use distinct building icons"
  doAssert visibleLabels.anyIt(it.contains("role tank guard"))
  doAssert visibleLabels.anyIt(it.contains("role dps beam"))
  doAssert visibleLabels.anyIt(it.contains("role heal hold"))
  doAssert visibleLabels.anyIt(it.contains("NEXT WALK INTO TANK DPS HEAL")),
    "local HUD should tell new players to walk into role gear"
  let localPlayerObject =
    parsed.objects[PlayerObjectBase + sim.players[playerIndex].id]
  doAssert parsed.sprites[localPlayerObject.spriteId].label.startsWith(
      "selected player"
    ),
    "player observations should mark the controlled player for bots"
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
  let tankLabels = tankParsed.objectSpriteLabels()
  doAssert "status role tank" in tankLabels,
    "tank role should show an explicit non-gear role badge"
  doAssert not tankLabels.anyIt(it == "role tank"),
    "player role badges must not masquerade as role-pickup targets"

  sim.players[playerIndex].applyRole(RoleDps)
  let dpsLabels = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    tankState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status role dps" in dpsLabels

  sim.players[playerIndex].applyRole(RoleHealer)
  let healerLabels = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    tankState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status role healer" in healerLabels

proc testSpriteProtocolMatchesCurrentSharedClientContract() =
  var sim = initPartyProgressorForTest()
  let playerIndex = sim.addPlayer("protocol")
  var nextState: PlayerViewerState
  let packet = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  )

  packet.assertCurrentSpriteV1Packet()
  let viewport = packet.firstViewport(MapLayerId)
  doAssert viewport.width == PlayerViewportWidth
  doAssert viewport.height == PlayerViewportHeight

  var
    playerState = initPlayerViewerState()
    inputMask = 0'u8
    chatText = ""
  playerState.applyPlayerViewerMessage(
    blobFromBytes([0x84'u8, ButtonA or ButtonB]),
    inputMask,
    chatText
  )
  doAssert inputMask == (ButtonA or ButtonB),
    "sprite client z/x input should arrive as 0x84 A/B bits"
  doAssert chatText.len == 0

  playerState.applyPlayerViewerMessage(
    blobFromBytes([
      0x81'u8,
      5'u8,
      0'u8,
      uint8(ord('h')),
      uint8(ord('e')),
      uint8(ord('l')),
      uint8(ord('l')),
      uint8(ord('o'))
    ]),
    inputMask,
    chatText
  )
  doAssert chatText == "hello",
    "sprite client chat should arrive as 0x81 length-prefixed ASCII"

proc testGlobalSpriteViewFollowsPartyProgress() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  let playerIndex = sim.addPlayer("global")

  var nextState: GlobalViewerState
  let initial = sim.buildSpriteProtocolUpdates(
    initGlobalViewerState(),
    nextState
  ).parseSpriteProtocolPacket()
  doAssert initial.viewports[MapLayerId].width == GlobalViewportWidth
  doAssert initial.viewports[MapLayerId].height == GlobalViewportHeight
  doAssert initial.objects[MapObjectId].x == 0

  sim.players[playerIndex].x = SafeZoneRightPixels + GlobalViewportWidth
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])

  var followedState: GlobalViewerState
  let followed = sim.buildSpriteProtocolUpdates(
    nextState,
    followedState
  ).parseSpriteProtocolPacket()
  doAssert followed.objects[MapObjectId].x < 0,
    "global map should pan as the party moves right"
  let playerObject = followed.objects[
    PlayerObjectBase + sim.players[playerIndex].id
  ]
  doAssert playerObject.x >= 0 and playerObject.x < GlobalViewportWidth,
    "global player object should remain visible inside the bird's-eye viewport"

proc testCarriedInventoryTilesAcrossBottomOfPlayerView() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  let playerIndex = sim.addPlayer("carrier")
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood

  var nextState: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  ).parseSpriteProtocolPacket()
  let carryObject = parsed.objects[CarryObjectBase + sim.players[playerIndex].id]
  doAssert carryObject.y >= PlayerViewportHeight - WorldTileSize - 4,
    "carried inventory should render in the bottom HUD row"
  doAssert carryObject.x < PlayerViewportWidth div 3,
    "carried inventory should tile from the lower-left inventory strip"
  doAssert parsed.sprites[carryObject.spriteId].label == "food"

proc testCarriedFoodStacksAndShowsCount() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  let playerIndex = sim.addPlayer("forager")
  let player = sim.players[playerIndex]
  sim.pickups.add(Pickup(
    x: player.x,
    y: player.y,
    kind: PickupFood,
    value: 0
  ))
  sim.pickups.add(Pickup(
    x: player.x,
    y: player.y,
    kind: PickupFood,
    value: 0
  ))

  sim.step([InputState()])

  doAssert sim.players[playerIndex].carryCount(CarryFood) == 2,
    "repeated wheat/food pickups should stack instead of blocking collection"
  doAssert sim.pickups.len == 0,
    "stacked food pickups should be removed from the ground"
  doAssert sim.carryHudLabel(playerIndex) == "food x2 sel drop"

  var nextState: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  ).parseSpriteProtocolPacket()
  let carryObject = parsed.objects[CarryObjectBase + sim.players[playerIndex].id]
  doAssert carryObject.y >= PlayerViewportHeight - WorldTileSize - 4,
    "stacked inventory should stay in the bottom HUD row"
  doAssert parsed.sprites[carryObject.spriteId].label == "food"
  doAssert "carry food x2" in parsed.sprites.values.toSeq.mapIt(it.label),
    "stacked inventory should expose a visible count badge"

  sim.players[playerIndex].lives =
    sim.players[playerIndex].maxHp - FoodHealAmount
  sim.step([InputState(select: true)])
  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp
  doAssert sim.players[playerIndex].carryCount(CarryFood) == 1,
    "using food should consume one stacked item, not the whole stack"
  doAssert sim.players[playerIndex].carrying

proc testRoleSpecialAbilitiesShowColoredSpriteEffects() =
  for item in [
    (role: RoleTank, label: "ability tank effect"),
    (role: RoleDps, label: "ability dps effect"),
    (role: RoleHealer, label: "ability healer effect")
  ]:
    var sim = initPartyProgressorForTest()
    sim.clearTerrain()
    sim.mobs.setLen(0)
    sim.pickups.setLen(0)
    sim.landmarks.setLen(0)
    sim.fillGround(GroundGrass)
    let playerIndex = sim.addPlayer(item.role.roleLabel())
    sim.players[playerIndex].applyRole(item.role)
    if item.role == RoleHealer:
      sim.holdSpecial(playerIndex)
    else:
      sim.step([InputState(b: true)])

    doAssert sim.players[playerIndex].abilityTicks > 0
    var nextState: PlayerViewerState
    let labels = sim.buildSpriteProtocolPlayerUpdates(
      playerIndex,
      initPlayerViewerState(),
      nextState
    ).parseSpriteProtocolPacket().objectSpriteLabels()
    doAssert item.label in labels,
      "X/special should display the " & item.label & " pulse"
    if item.role == RoleDps:
      doAssert "ability dps beam horizontal" in labels or
        "ability dps beam vertical" in labels,
        "DPS special should show a straight beam effect"

proc testGeneratedMonsterSpritesStayRichlyColored() =
  var sim = initPartyProgressorForTest()
  let playerIndex = sim.addPlayer("player1")
  var nextState: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  ).parseSpriteProtocolPacket()
  for label in [
    "forest wolf",
    "brown bear",
    "prairie goblin",
    "frost yeti",
    "gate titan"
  ]:
    let
      sprite = parsed.firstSpriteByLabel(label)
      stats = sprite.spriteColorStats()
    doAssert stats.buckets >= 5,
      label & " should retain multiple color/detail buckets"
    doAssert stats.largestBucket * 100 < max(1, stats.opaque) * 85,
      label & " should not collapse into a single flat tint"

proc testExpeditionObjectiveHudGuidesNextStep() =
  var sim = initPartyProgressorForTest()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  let playerIndex = sim.addPlayer("player1")
  doAssert sim.expeditionObjectiveHint(playerIndex) ==
    "NEXT WALK INTO TANK DPS HEAL"

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
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT CLEAR LAIR"

  for landmark in sim.landmarks.mitems:
    if sim.tileBiomeKind(landmark.tx, landmark.ty) == BiomePlains and
        landmark.kind == LandmarkLair:
      landmark.done = true
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT RELIC 0/3"

  sim.relicShards = FinalGateRelicCost
  sim.wood = 0
  sim.stone = 0
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT GATHER W2 S1"
  sim.wood = CampWoodCost
  sim.stone = CampStoneCost
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT CAMP 0/2"

  sim.campsActivated = FinalGateCampCost
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT DEFEAT BOSS"

  sim.bossDefeated = true
  doAssert sim.expeditionObjectiveHint(playerIndex) == "NEXT HOLD GATE 0%"

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
  doAssert SpeciesDuneScorpion.attackStyle() == AttackRanged
  doAssert SpeciesFrostYeti.attackStyle() == AttackSlam
  doAssert SpeciesMudSlime.attackStyle() == AttackAura
  doAssert SpeciesSnowWolf.attackStyle() == AttackLunge

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

proc testDefeatedBiomeMonstersDropExpeditionSupplies() =
  doAssert SpeciesFrostYeti.speciesSupplyDrop() == CarryFood
  doAssert SpeciesBogGoblin.speciesSupplyDrop() == CarryWood
  doAssert SpeciesStoneGoblin.speciesSupplyDrop() == CarryStone
  doAssert SpeciesRuinWraith.speciesSupplyDrop() == CarryGold
  doAssert SpeciesGateTitan.speciesSupplyDrop() == CarryNone

  proc defeatSpecies(species: MobSpecies): SimServer =
    result = initPartyProgressorForTest()
    result.clearTerrain()
    result.mobs.setLen(0)
    result.pickups.setLen(0)
    result.landmarks.setLen(0)
    result.bossDefeated = true
    result.mobSpawnCooldown = 999
    result.fillGround(GroundGrass)

    let playerIndex = result.addPlayer("hunter")
    result.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
    result.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
    result.players[playerIndex].facing = FaceRight
    result.players[playerIndex].applyRole(RoleDps)
    result.players[playerIndex].bounds =
      result.playerBoundsFor(result.players[playerIndex])

    let
      kind = species.speciesKind()
      hit = result.attackRect(result.players[playerIndex])
    result.mobs.add(Mob(
      kind: kind,
      species: species,
      x: hit.x,
      y: hit.y,
      sprite: result.mobSpriteFor(kind),
      bounds: result.mobBoundsFor(kind),
      hp: 1,
      attackCooldown: 99
    ))
    result.step([InputState(attack: true)])

  var foodSim = defeatSpecies(SpeciesFrostYeti)
  doAssert foodSim.mobs.len == 0
  doAssert foodSim.hasPickup(PickupFood),
    "defeated snow wildlife should leave emergency food"

  var woodSim = defeatSpecies(SpeciesBogGoblin)
  doAssert woodSim.hasPickup(PickupWood),
    "defeated swamp goblins should leave camp/plank wood"

  var stoneSim = defeatSpecies(SpeciesStoneGoblin)
  doAssert stoneSim.hasPickup(PickupStone),
    "defeated cave goblins should leave step/camp stone"

  var goldSim = defeatSpecies(SpeciesRuinWraith)
  doAssert goldSim.hasPickup(PickupGold),
    "defeated ruin wraiths should leave portable light gold"

proc testExpandedMonsterFamiliesAndArmorDrops() =
  doAssert AllMobSpecies.len == 44,
    "party progressor should keep the expanded biome monster roster"
  doAssert SpeciesPackAlpha.attackStyle() == AttackCone
  doAssert SpeciesFireScorpion.attackStyle() == AttackLine
  doAssert SpeciesNetThrower.attackStyle() == AttackTrap
  doAssert SpeciesBogWitch.attackStyle() == AttackSupport
  doAssert SpeciesLeechSwarm.attackStyle() == AttackSwarm
  doAssert SpeciesPackAlpha.speciesLeadsPack()
  doAssert SpeciesBogWitch.speciesSupportsPack()
  doAssert SpeciesLeechSwarm.speciesSwarms()
  doAssert SpeciesFireScorpion.speciesArmorDrop() == ArmorScaleMail
  doAssert SpeciesCrystalSeer.speciesArmorDrop() == ArmorLanternCharm

proc testArmorPickupEquipsAndShowsHud() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.bossDefeated = true
  sim.fillGround(GroundGrass)
  let playerIndex = sim.addPlayer("armored")
  sim.players[playerIndex].applyRole(RoleTank)
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  let oldMax = sim.players[playerIndex].maxHp
  sim.pickups.add(Pickup(
    x: sim.players[playerIndex].x,
    y: sim.players[playerIndex].y,
    kind: PickupArmor,
    value: ord(ArmorScaleMail)
  ))
  sim.step([InputState()])
  doAssert sim.pickups.len == 0
  doAssert sim.players[playerIndex].armor[ArmorChest] == ArmorScaleMail
  doAssert sim.players[playerIndex].maxHp == oldMax +
    ArmorScaleMail.armorMaxHpBonus()

  var nextState: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  ).parseSpriteProtocolPacket()
  doAssert parsed.sprites.values.toSeq.anyIt(it.label.contains("scale mail")),
    "player HUD should expose equipped armor and its bonus"

proc testSpriteProtocolShowsStatusAndObjectiveAffordances() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass, BiomeForest)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + 2 * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].poisonTicks = StatusPoisonTicks
  sim.players[playerIndex].slowTicks = StatusSlowTicks
  sim.players[playerIndex].chillTicks = StatusChillTicks
  sim.players[playerIndex].lives = max(1, sim.players[playerIndex].maxHp div 2)
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood
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
    progress: CampFortifiedFlag
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 4,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkCamp,
    hp: 1,
    done: true,
    progress: CampProvisionedFlag
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 5,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkCamp,
    hp: 1,
    done: true,
    progress: CampFortifiedFlag + CampProvisionedFlag
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 1,
    ty: sim.players[playerIndex].y div WorldTileSize + 2,
    kind: LandmarkCamp,
    hp: 1,
    done: true,
    progress: CampWardedFlag
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 2,
    ty: sim.players[playerIndex].y div WorldTileSize + 2,
    kind: LandmarkCamp,
    hp: 1,
    done: true,
    progress: CampRallyFlag
  ))
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize + 3,
    ty: sim.players[playerIndex].y div WorldTileSize + 2,
    kind: LandmarkCamp,
    hp: 1,
    done: true,
    progress: CampAidFlag
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
  doAssert "camp" in labels
  doAssert "shelter" in labels
  doAssert "prompt camp w2 s1" in labels
  doAssert "prompt shelter" in labels
  doAssert "prompt fort" in labels
  doAssert "prompt meals" in labels
  doAssert "prompt fort meal" in labels
  doAssert "prompt ward" in labels
  doAssert "prompt rally" in labels
  doAssert "prompt aid" in labels
  doAssert "prompt shrine f2" in labels
  doAssert "prompt rescue f2" in labels
  doAssert "prompt lair" in labels
  doAssert "prompt forage h" in labels
  doAssert "prompt gate c0/2 r0/3" in labels

  let spriteLabels = packet.parseSpriteProtocolPacket().sprites.values.toSeq.mapIt(
    it.label
  )
  doAssert spriteLabels.anyIt(it.contains("CARRY FOOD SEL EAT"))
  doAssert "prompt bridge t" in spriteLabels
  doAssert "prompt oasis h" in spriteLabels
  doAssert "prompt hearth h" in spriteLabels
  doAssert "prompt lantern d" in spriteLabels
  doAssert "prompt ward t" in spriteLabels

proc testSpriteProtocolShowsObjectiveProgressPrompts() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass, BiomeSwamp)
  sim.bossDefeated = true
  sim.relicShards = FinalGateRelicCost
  sim.campsActivated = FinalGateCampCost

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  let
    baseTx = sim.players[playerIndex].x div WorldTileSize
    baseTy = sim.players[playerIndex].y div WorldTileSize
  sim.landmarks.add(Landmark(
    tx: baseTx,
    ty: baseTy,
    kind: LandmarkRescue,
    hp: 1,
    done: false,
    progress: RescueEventTicks div 2
  ))
  sim.landmarks.add(Landmark(
    tx: baseTx + 1,
    ty: baseTy,
    kind: LandmarkWaystation,
    hp: 1,
    done: false,
    progress: BiomeWaystationTicks div 2
  ))
  sim.landmarks.add(Landmark(
    tx: baseTx + 2,
    ty: baseTy,
    kind: LandmarkBeacon,
    hp: 1,
    done: false,
    progress: BeaconAttunementTicks div 2
  ))
  sim.landmarks.add(Landmark(
    tx: baseTx + 3,
    ty: baseTy,
    kind: LandmarkLair,
    hp: LairHp div 2,
    done: false
  ))
  sim.landmarks.add(Landmark(
    tx: baseTx + 4,
    ty: baseTy,
    kind: LandmarkFinalGate,
    hp: 1,
    done: false,
    progress: FinalGateRitualTicks div 2
  ))

  var nextState: PlayerViewerState
  let labels = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "prompt rescue 50%" in labels
  doAssert "prompt bridge t 50%" in labels
  doAssert "prompt relic 50%" in labels
  doAssert "prompt lair 50%" in labels
  doAssert "prompt gate 50%" in labels

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
  sim.mobs[0].attackPhase = MobTelegraph
  sim.mobs[0].attackTicks = MobTelegraphTicks div 2
  sim.mobs[0].attackFacing = FaceRight
  sim.mobs[1].attackPhase = MobLunge
  sim.mobs[1].attackTicks = MobLungeTicks div 2
  sim.mobs[1].attackFacing = FaceRight
  sim.mobs[2].attackPhase = MobLunge
  sim.mobs[2].attackTicks = MobLungeTicks div 2
  sim.mobs[2].attackFacing = FaceRight

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
  doAssert "mob dart warning" in labels
  doAssert "mob aura pulse" in labels
  doAssert "mob lunge strike" in labels

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

proc setupElevationCombatScenario(
  playerElevation,
  mobElevation: int
): SimServer =
  result = initPartyProgressorForTest()
  result.clearTerrain()
  result.mobs.setLen(0)
  result.pickups.setLen(0)
  result.landmarks.setLen(0)
  result.fillGround(GroundGrass)
  result.mobSpawnCooldown = 999

  let playerIndex = result.addPlayer("player1")
  result.players[playerIndex].x = SafeZoneRightPixels + 2 * WorldTileSize
  result.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  result.players[playerIndex].facing = FaceRight
  result.players[playerIndex].applyRole(RoleDps)
  result.players[playerIndex].bounds =
    result.playerBoundsFor(result.players[playerIndex])

  let
    hit = result.attackRect(result.players[playerIndex])
    mobSprite = result.mobSpriteFor(BearMob)
    mobBounds = result.mobBoundsFor(BearMob)
  result.mobs.add(Mob(
    kind: BearMob,
    species: SpeciesBrownBear,
    x: hit.x,
    y: hit.y,
    sprite: mobSprite,
    bounds: mobBounds,
    hp: 20,
    attackCooldown: 99
  ))

  let
    playerTx = clamp(
      boundsCenterX(result.players[playerIndex].x, result.players[playerIndex].bounds) div
        WorldTileSize,
      0,
      WorldWidthTiles - 1
    )
    playerTy = clamp(
      boundsCenterY(result.players[playerIndex].y, result.players[playerIndex].bounds) div
        WorldTileSize,
      0,
      WorldHeightTiles - 1
    )
    mobTx = clamp(
      boundsCenterX(result.mobs[0].x, result.mobs[0].bounds) div WorldTileSize,
      0,
      WorldWidthTiles - 1
    )
    mobTy = clamp(
      boundsCenterY(result.mobs[0].y, result.mobs[0].bounds) div WorldTileSize,
      0,
      WorldHeightTiles - 1
    )
  result.elevations[tileIndex(playerTx, playerTy)] = playerElevation
  result.elevations[tileIndex(mobTx, mobTy)] = mobElevation

proc testElevationCombatAdvantageAndBadges() =
  var highPlayerSim = setupElevationCombatScenario(4, 1)
  let playerIndex = 0
  doAssert highPlayerSim.playerAttackDamage(
    highPlayerSim.players[playerIndex],
    highPlayerSim.mobs[0]
  ) == 3 + HighGroundDamageBonus
  let highPlayerHp = highPlayerSim.mobs[0].hp
  highPlayerSim.step([InputState(attack: true)])
  doAssert highPlayerSim.mobs[0].hp ==
    highPlayerHp - (3 + HighGroundDamageBonus),
    "attacking from high ground should increase player damage"

  var lowPlayerSim = setupElevationCombatScenario(1, 4)
  doAssert lowPlayerSim.playerAttackDamage(
    lowPlayerSim.players[playerIndex],
    lowPlayerSim.mobs[0]
  ) == 3 - LowGroundDamagePenalty
  let lowPlayerHp = lowPlayerSim.mobs[0].hp
  lowPlayerSim.step([InputState(attack: true)])
  doAssert lowPlayerSim.mobs[0].hp ==
    lowPlayerHp - (3 - LowGroundDamagePenalty),
    "attacking uphill should reduce player damage"

  doAssert lowPlayerSim.mobHitDamage(lowPlayerSim.mobs[0], playerIndex) ==
    2 + HighGroundDamageBonus,
    "mobs should also hit harder from high ground"
  doAssert highPlayerSim.mobHitDamage(highPlayerSim.mobs[0], playerIndex) ==
    max(1, 2 - LowGroundDamagePenalty),
    "mobs attacking uphill should hit softer"

  var highMobState: PlayerViewerState
  let highMobLabels = lowPlayerSim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    highMobState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status high ground" in highMobLabels,
    "player observations should badge mobs with high-ground threat"

  var lowMobState: PlayerViewerState
  let lowMobLabels = highPlayerSim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    lowMobState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status low ground" in lowMobLabels,
    "player observations should badge mobs with low-ground vulnerability"

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

  var goldSim = initPartyProgressorForTest()
  goldSim.clearTerrain()
  goldSim.mobs.setLen(0)
  goldSim.pickups.setLen(0)
  goldSim.landmarks.setLen(0)
  goldSim.fillGround(GroundGrass)
  let goldPlayer = goldSim.addPlayer("gold")
  goldSim.players[goldPlayer].x = SafeZoneRightPixels + WorldTileSize
  goldSim.players[goldPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  goldSim.players[goldPlayer].facing = FaceRight
  goldSim.players[goldPlayer].bounds =
    goldSim.playerBoundsFor(goldSim.players[goldPlayer])
  let goldHit = goldSim.attackRect(goldSim.players[goldPlayer])
  goldSim.landmarks.add(Landmark(
    tx: clamp(
      (goldHit.x + goldHit.w div 2) div WorldTileSize,
      0,
      WorldWidthTiles - 1
    ),
    ty: clamp(
      (goldHit.y + goldHit.h div 2) div WorldTileSize,
      0,
      WorldHeightTiles - 1
    ),
    kind: LandmarkGold,
    hp: 1,
    done: false
  ))
  goldSim.step([InputState(attack: true)])
  doAssert goldSim.wood == 1
  doAssert goldSim.stone == 2
  doAssert goldSim.players[goldPlayer].carriedItem == CarryGold,
    "gold should be both a held camp upgrade and shared camp-funding salvage"

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
  sim.players[playerIndex].applyRole(RoleTank)
  sim.players[playerIndex].carrying = false
  sim.players[playerIndex].carriedItem = CarryNone
  let forwardHealerGear = sim.firstForwardPickup(PickupHealerGear)
  sim.players[playerIndex].x = forwardHealerGear.x
  sim.players[playerIndex].y = forwardHealerGear.y
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.step([InputState()])
  doAssert sim.players[playerIndex].role == RoleTank,
    "forward camp role gear should not swap roles from incidental overlap"
  sim.step([InputState(select: true)])
  doAssert sim.players[playerIndex].role == RoleHealer,
    "forward camp role gear should support explicit select-to-swap"
  sim.players[playerIndex].applyRole(RoleDps)
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood
  sim.players[playerIndex].lives = max(1, sim.players[playerIndex].maxHp - 2)
  sim.players[playerIndex].x = forwardHealerGear.x
  sim.players[playerIndex].y = forwardHealerGear.y
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.step([InputState(select: true)])
  doAssert sim.players[playerIndex].role == RoleDps,
    "carried-item select actions near camp gear should not also swap roles"
  doAssert not sim.players[playerIndex].carrying,
    "carried-item select should still resolve the intended held-food action"
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

proc testCarriedFoodCanBeEatenForRecovery() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp - 1
  sim.players[playerIndex].poisonTicks = StatusPoisonTicks
  sim.players[playerIndex].slowTicks = StatusSlowTicks
  sim.players[playerIndex].chillTicks = StatusChillTicks
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood
  sim.food = 3

  doAssert sim.carryHudLabel(playerIndex) == "food sel eat"
  sim.step([InputState(select: true)])
  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp
  doAssert sim.players[playerIndex].poisonTicks == 0
  doAssert sim.players[playerIndex].slowTicks == 0
  doAssert sim.players[playerIndex].chillTicks == 0
  doAssert sim.players[playerIndex].healingDone == 1
  doAssert sim.food == 3,
    "eating a carried food item should not drain shared party food"
  doAssert not sim.players[playerIndex].carrying

  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp
  sim.players[playerIndex].slowTicks = StatusSlowTicks
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood
  doAssert sim.carryHudLabel(playerIndex) == "food sel eat"
  sim.step([InputState(select: true)])
  doAssert sim.players[playerIndex].slowTicks == 0,
    "eaten carried food should cleanse statuses even at full health"
  doAssert sim.food == 3
  doAssert not sim.players[playerIndex].carrying

  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood
  doAssert sim.carryHudLabel(playerIndex) == "food sel drop",
    "carried food should only advertise eating when it will help"

proc testCarriedFoodCanBeFedToNearbyTeammate() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)

  let
    feederIndex = sim.addPlayer("feeder")
    allyIndex = sim.addPlayer("ally")
    baseX = 5 * WorldTileSize
    baseY = 5 * WorldTileSize
  sim.players[feederIndex].x = baseX
  sim.players[feederIndex].y = baseY
  sim.players[feederIndex].bounds =
    sim.playerBoundsFor(sim.players[feederIndex])
  sim.players[allyIndex].x = baseX + WorldTileSize
  sim.players[allyIndex].y = baseY
  sim.players[allyIndex].bounds =
    sim.playerBoundsFor(sim.players[allyIndex])
  sim.players[feederIndex].carrying = true
  sim.players[feederIndex].carriedItem = CarryFood
  sim.players[allyIndex].lives =
    sim.players[allyIndex].maxHp - FoodHealAmount
  sim.players[allyIndex].poisonTicks = StatusPoisonTicks
  sim.players[allyIndex].slowTicks = StatusSlowTicks
  sim.players[allyIndex].chillTicks = StatusChillTicks
  sim.players[allyIndex].exhaustionTicks = StatusExhaustionTicks
  sim.food = 2

  doAssert sim.playerCanFeedCarriedFood(feederIndex)
  doAssert sim.carryHudLabel(feederIndex) == "food sel feed"
  sim.step([InputState(select: true), InputState()])
  doAssert sim.players[allyIndex].lives == sim.players[allyIndex].maxHp
  doAssert sim.players[allyIndex].poisonTicks == 0
  doAssert sim.players[allyIndex].slowTicks == 0
  doAssert sim.players[allyIndex].chillTicks == 0
  doAssert sim.players[allyIndex].exhaustionTicks == 0
  doAssert sim.players[feederIndex].healingDone == FoodHealAmount
  doAssert sim.food == 2,
    "feeding carried food should not drain shared party food"
  doAssert not sim.players[feederIndex].carrying

  sim.players[feederIndex].carrying = true
  sim.players[feederIndex].carriedItem = CarryFood
  sim.players[allyIndex].lives = sim.players[allyIndex].maxHp - 1
  sim.players[allyIndex].x = baseX + CarriedFoodShareRadius + WorldTileSize
  sim.players[allyIndex].bounds =
    sim.playerBoundsFor(sim.players[allyIndex])
  doAssert not sim.playerCanFeedCarriedFood(feederIndex)
  doAssert sim.carryHudLabel(feederIndex) == "food sel drop",
    "carried food should only advertise feeding near a teammate it can help"

proc testCarriedWoodCanPlankSwampCrossings() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundMud, BiomeSwamp)

  let
    playerIndex = sim.addPlayer("planker")
    startTx = firstTileForBiome(BiomeSwamp) + 2
    startTy = WorldHeightTiles div 2
  sim.players[playerIndex].x = startTx * WorldTileSize
  sim.players[playerIndex].y = startTy * WorldTileSize
  sim.players[playerIndex].facing = FaceRight
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryWood
  for tx in startTx ..< startTx + SwampPlankForwardTiles:
    let index = tileIndex(tx, startTy)
    sim.biomeKinds[index] = BiomeSwamp
    sim.groundKinds[index] =
      if tx == startTx + 1: GroundWater else: GroundMud
    sim.elevations[index] = 5
    sim.tiles[index] = true

  doAssert sim.playerCanLaySwampPlank(playerIndex),
    "carried wood should advertise a field plank on rough swamp tiles"
  doAssert sim.carryHudLabel(playerIndex) == "wood sel plank"
  sim.step([InputState(select: true)])
  doAssert not sim.players[playerIndex].carrying,
    "laying a swamp plank should consume the carried wood"
  for tx in startTx ..< startTx + SwampPlankForwardTiles:
    let index = tileIndex(tx, startTy)
    doAssert sim.tileGroundKind(tx, startTy) == GroundBridge,
      "swamp planks should turn mud and water into bridge ground"
    doAssert sim.elevations[index] <= 1,
      "swamp planks should flatten a local crossing"
    doAssert not sim.tiles[index],
      "swamp planks should clear blocking props from the crossing"
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalSafe,
    "standing on the new plank should clear mire pressure"
  sim.tickCount = SwampMireIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].slowTicks == 0,
    "swamp planks should block mire slow pulses on the bridged tile"

  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryWood
  doAssert not sim.playerCanLaySwampPlank(playerIndex),
    "already-bridged swamp ground should not consume wood as another plank"
  doAssert sim.carryHudLabel(playerIndex) == "wood sel drop"

proc testCarriedStoneCanCutElevationSteps() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundSnow, BiomeSnow)

  let
    playerIndex = sim.addPlayer("stepper")
    startTx = firstTileForBiome(BiomeSnow) + 2
    startTy = WorldHeightTiles div 2
  sim.players[playerIndex].x = startTx * WorldTileSize
  sim.players[playerIndex].y = startTy * WorldTileSize
  sim.players[playerIndex].facing = FaceRight
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryStone
  for tx in startTx ..< startTx + StoneStepForwardTiles:
    let index = tileIndex(tx, startTy)
    sim.biomeKinds[index] = BiomeSnow
    sim.groundKinds[index] = GroundSnow
    sim.elevations[index] = 5
    sim.tiles[index] = true

  let beforeSpeed = sim.speedPercentAt(
    startTx * WorldTileSize + WorldTileSize div 2,
    startTy * WorldTileSize + WorldTileSize div 2
  )
  doAssert sim.playerCanLayStoneSteps(playerIndex),
    "carried stone should advertise steps on steep elevation"
  doAssert sim.carryHudLabel(playerIndex) == "stone sel steps"
  sim.step([InputState(select: true)])
  doAssert not sim.players[playerIndex].carrying,
    "laying steps should consume the carried stone"
  for tx in startTx ..< startTx + StoneStepForwardTiles:
    let index = tileIndex(tx, startTy)
    doAssert sim.tileGroundKind(tx, startTy) == GroundSnow,
      "stone steps should preserve biome ground identity"
    doAssert sim.elevations[index] <= StoneStepMaxElevation,
      "stone steps should cut steep elevation into a traversable route"
    doAssert not sim.tiles[index],
      "stone steps should clear blocking props from the route"
  let afterSpeed = sim.speedPercentAt(
    startTx * WorldTileSize + WorldTileSize div 2,
    startTy * WorldTileSize + WorldTileSize div 2
  )
  doAssert afterSpeed > beforeSpeed,
    "stone steps should make steep elevation faster to cross"

  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryStone
  doAssert not sim.playerCanLayStoneSteps(playerIndex),
    "already-cut elevation should not consume another carried stone"
  doAssert sim.carryHudLabel(playerIndex) == "stone sel drop"

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

proc testCampProvisioningConsumesFoodAndImprovesRecovery() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundSnow, BiomeSnow)
  sim.food = CampProvisionFoodCost
  sim.mobSpawnCooldown = 999

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = firstTileForBiome(BiomeSnow) * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkCamp,
    hp: 1,
    done: true
  ))

  sim.step([InputState()])

  doAssert sim.landmarks[0].campIsProvisioned()
  doAssert not sim.landmarks[0].campIsFortified()
  doAssert sim.playerNearProvisionedCamp(playerIndex)
  doAssert sim.food == 0
  doAssert sim.players[playerIndex].rationTicks == CampMealRationTicks
  doAssert sim.players[playerIndex].statusLabel().contains("ration")
  doAssert sim.playerHasWeatherRation(playerIndex)
  var mealNextState: PlayerViewerState
  let mealParsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    mealNextState
  ).parseSpriteProtocolPacket()
  let mealLabels = mealParsed.objectSpriteLabels()
  doAssert "status ration" in mealLabels
  doAssert mealParsed.sprites.values.toSeq.anyIt(it.label.contains("RATION SAFE")),
    "HUD status text should make meal rations readable"

  sim.players[playerIndex].lives =
    sim.players[playerIndex].maxHp - CampProvisionedRecoveryHealAmount
  sim.tickCount = CampRecoveryIntervalTicks - 1
  sim.step([InputState()])

  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp,
    "provisioned camps should recover resting players faster than shelters"

  sim.players[playerIndex].y += CampShelterRadius * 4
  doAssert not sim.playerNearActivatedCamp(playerIndex)
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalSafe,
    "meal rations should suppress visible snow pressure during the next push"
  sim.food = 0
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp
  sim.tickCount = ColdExposureIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp,
    "meal rations should absorb cold exposure before shared food or damage"
  doAssert sim.food == 0

  sim.players[playerIndex].rationTicks = 1
  sim.tickCount = 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].rationTicks == 0
  doAssert not sim.playerHasWeatherRation(playerIndex)
  doAssert sim.biomeAtPixel(boundsCenterX(
    sim.players[playerIndex].x,
    sim.players[playerIndex].bounds
  )) == BiomeSnow
  doAssert not sim.playerNearExpeditionShelter(playerIndex)
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalCold,
    "snow pressure should return after meal rations expire"

proc testCarriedSuppliesUpgradeActivatedCamps() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  sim.mobSpawnCooldown = 999
  sim.bossDefeated = true

  let
    playerIndex = sim.addPlayer("player1")
    campTx = SafeZoneRightTiles + 2
    campTy = WorldHeightTiles div 2
    campX = campTx * WorldTileSize
    campY = campTy * WorldTileSize
  sim.players[playerIndex].x = campX
  sim.players[playerIndex].y = campY
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.landmarks.add(Landmark(
    tx: campTx,
    ty: campTy,
    kind: LandmarkCamp,
    hp: 1,
    done: true
  ))

  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryWood
  sim.step([InputState(select: true)])
  doAssert sim.landmarks[0].campIsRally(),
    "delivered wood should create a rally camp"
  doAssert not sim.players[playerIndex].carrying
  doAssert not sim.hasPickup(PickupWood)

  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryStone
  sim.step([InputState(select: true)])
  doAssert sim.landmarks[0].campIsWarded(),
    "delivered stone should create a ward camp"
  doAssert not sim.players[playerIndex].carrying
  doAssert not sim.hasPickup(PickupStone)

  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood
  doAssert sim.carryHudLabel(playerIndex) == "food sel camp"
  sim.step([InputState(select: true)])
  doAssert sim.landmarks[0].campIsProvisioned(),
    "delivered food should create a meal shelter"
  doAssert not sim.players[playerIndex].carrying
  doAssert not sim.hasPickup(PickupFood)

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
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryGold
  sim.step([InputState(select: true)])
  doAssert sim.landmarks[0].campIsFortified(),
    "delivered gold should fortify the camp"
  doAssert sim.mobs.len == 0,
    "gold-fortified camps should immediately secure nearby non-boss threats"
  doAssert not sim.players[playerIndex].carrying
  doAssert not sim.hasPickup(PickupGold)

proc testRoleSpecializedCampsCreateDistinctStagingBenefits() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)
  sim.stone = CampWardStoneCost
  sim.wood = CampRallyWoodCost
  sim.food = CampAidFoodCost
  sim.bossDefeated = true
  sim.mobSpawnCooldown = 999

  let
    tankIndex = sim.addPlayer("tank")
    dpsIndex = sim.addPlayer("dps")
    healerIndex = sim.addPlayer("healer")
    baseX = SafeZoneRightPixels + WorldTileSize
    baseY = (WorldHeightTiles div 2) * WorldTileSize

  sim.players[tankIndex].applyRole(RoleTank)
  sim.players[dpsIndex].applyRole(RoleDps)
  sim.players[healerIndex].applyRole(RoleHealer)
  sim.players[tankIndex].x = baseX
  sim.players[dpsIndex].x = baseX + WorldTileSize * 8
  sim.players[healerIndex].x = baseX + WorldTileSize * 15
  for playerIndex in [tankIndex, dpsIndex, healerIndex]:
    sim.players[playerIndex].y = baseY
    sim.players[playerIndex].bounds =
      sim.playerBoundsFor(sim.players[playerIndex])
    sim.landmarks.add(Landmark(
      tx: sim.players[playerIndex].x div WorldTileSize,
      ty: sim.players[playerIndex].y div WorldTileSize,
      kind: LandmarkCamp,
      hp: 1,
      done: true
    ))

  sim.step([InputState(), InputState(), InputState()])

  doAssert sim.landmarks[0].campIsWarded()
  doAssert not sim.landmarks[0].campIsFortified()
  doAssert sim.landmarks[1].campIsRally()
  doAssert sim.landmarks[2].campIsAid()
  doAssert sim.stone == 0 and sim.wood == 0 and sim.food == 0

  sim.players[dpsIndex].abilityCooldown = 4
  sim.players[healerIndex].slowTicks = StatusSlowTicks
  sim.mobs.add(Mob(
    kind: WolfMob,
    species: SpeciesForestWolf,
    x: sim.landmarks[0].tx * WorldTileSize,
    y: sim.landmarks[0].ty * WorldTileSize + WorldTileSize,
    sprite: sim.mobSpriteFor(WolfMob),
    bounds: sim.mobBoundsFor(WolfMob),
    hp: 4,
    attackCooldown: 99
  ))

  sim.step([InputState(), InputState(), InputState()])

  doAssert sim.mobs.len == 0,
    "tank-warded camps should defend a staging area without generic fortifying"
  doAssert sim.players[dpsIndex].abilityCooldown == 2,
    "DPS rally camps should recover role ability cooldown faster"
  doAssert sim.players[healerIndex].slowTicks <=
    StatusSlowTicks - CampStatusRecoveryTicks - CampAidStatusRecoveryTicks,
    "healer aid camps should cleanse statuses faster than ordinary shelters"

proc testBeaconAndBossScoring() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].applyRole(RoleDps)
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
  let beaconTrailIndex = tileIndex(
    sim.landmarks[0].tx + BeaconSurveyForwardTiles,
    sim.landmarks[0].ty
  )
  let beaconRoughIndex = tileIndex(
    sim.landmarks[0].tx + BeaconSurveyForwardTiles + 2,
    sim.landmarks[0].ty
  )
  sim.tiles[beaconTrailIndex] = true
  sim.elevations[beaconTrailIndex] = 4
  sim.groundKinds[beaconRoughIndex] = GroundMud
  sim.elevations[beaconRoughIndex] = 4
  sim.mobs.add(Mob(
    kind: WolfMob,
    species: SpeciesForestWolf,
    x: sim.landmarks[0].tx * WorldTileSize,
    y: sim.landmarks[0].ty * WorldTileSize,
    sprite: sim.mobSpriteFor(WolfMob),
    bounds: sim.mobBoundsFor(WolfMob),
    hp: WolfHp,
    attackCooldown: 99
  ))
  sim.step([InputState()])

  doAssert not sim.landmarks[0].done,
    "relic beacons should require a short attunement hold"
  doAssert sim.landmarks[0].progress == DpsBeaconAttunementStep,
    "DPS beacon attunement should advance by " & $DpsBeaconAttunementStep &
      " on the first tick, got " & $sim.landmarks[0].progress
  doAssert sim.objectivesCompleted == 0
  doAssert sim.relicShards == 0
  var attuneState: PlayerViewerState
  let attuneLabels = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    attuneState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert attuneLabels.anyIt(it.startsWith("prompt relic ")),
    "sprite observations should show relic attunement progress"

  let beaconDpsHoldTicks =
    (BeaconAttunementTicks + DpsBeaconAttunementStep - 1) div
      DpsBeaconAttunementStep
  for _ in 1 ..< beaconDpsHoldTicks:
    sim.step([InputState()])

  doAssert sim.objectivesCompleted == 1
  doAssert sim.relicShards == 1
  doAssert sim.players[playerIndex].surveyTicks == BeaconSurveyTicks
  doAssert sim.players[playerIndex].statusLabel().contains("survey")
  doAssert sim.groundKinds[beaconTrailIndex] == GroundRoad,
    "relic beacons should survey a short route forward"
  doAssert not sim.tiles[beaconTrailIndex],
    "relic beacon surveys should clear local route blockers"
  doAssert sim.elevations[beaconTrailIndex] <= 1,
    "relic beacon surveys should soften steep route terrain"
  doAssert sim.mobs.allIt(it.species != SpeciesForestWolf),
    "relic beacon surveys should clear nearby non-boss threats"
  let
    roughX = (sim.landmarks[0].tx + BeaconSurveyForwardTiles + 2) *
      WorldTileSize
    roughY = sim.landmarks[0].ty * WorldTileSize
    ordinaryTrailSpeed = sim.speedPercentAt(roughX, roughY)
    surveyedTrailSpeed = sim.playerMovementSpeedPercent(
      sim.players[playerIndex],
      roughX,
      roughY
    )
  doAssert ordinaryTrailSpeed < BeaconSurveyMinSpeedPercent
  doAssert surveyedTrailSpeed >= BeaconSurveyMinSpeedPercent,
    "survey knowledge should make rough/elevated route pushes readable"
  doAssert sim.teamScore() ==
    sim.frontierTiles() + ObjectiveScoreValue + RelicScoreValue
  var beaconNextState: PlayerViewerState
  let beaconParsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    beaconNextState
  ).parseSpriteProtocolPacket()
  let beaconLabels = beaconParsed.objectSpriteLabels()
  doAssert "status survey" in beaconLabels
  doAssert beaconParsed.sprites.values.toSeq.anyIt(it.label.contains("SURVEY SAFE")),
    "HUD status text should make beacon survey knowledge readable"
  doAssert "beacon" notin beaconLabels
  doAssert "prompt relic" notin beaconLabels

  sim.players[playerIndex].surveyTicks = 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].surveyTicks == 0,
    "beacon survey knowledge should expire after the next route window"

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
  sim.mobs.add(Mob(
    kind: WolfMob,
    species: SpeciesForestWolf,
    x: sim.landmarks[0].tx * WorldTileSize + WorldTileSize,
    y: sim.landmarks[0].ty * WorldTileSize,
    sprite: sim.mobSpriteFor(WolfMob),
    bounds: sim.mobBoundsFor(WolfMob),
    hp: WolfHp,
    attackCooldown: 999
  ))
  sim.step([InputState()])
  doAssert not sim.landmarks[0].done,
    "final gate should require a visible ritual hold"
  doAssert sim.landmarks[0].progress == 1
  doAssert sim.mobs.allIt(it.species != SpeciesForestWolf),
    "starting the final-gate hold should clear local non-boss pressure"
  for _ in 1 ..< (FinalGateRitualTicks - 1):
    sim.step([InputState()])
  doAssert sim.landmarks[0].progress == FinalGateRitualTicks - 1
  sim.players[playerIndex].lives = 1
  sim.players[playerIndex].poisonTicks = StatusPoisonTicks
  sim.players[playerIndex].slowTicks = StatusSlowTicks
  sim.players[playerIndex].chillTicks = StatusChillTicks
  sim.players[playerIndex].exhaustionTicks = StatusExhaustionTicks
  sim.mobs.add(Mob(
    kind: WolfMob,
    species: SpeciesForestWolf,
    x: sim.landmarks[0].tx * WorldTileSize + WorldTileSize,
    y: sim.landmarks[0].ty * WorldTileSize,
    sprite: sim.mobSpriteFor(WolfMob),
    bounds: sim.mobBoundsFor(WolfMob),
    hp: WolfHp,
    attackCooldown: 999
  ))
  sim.step([InputState()])
  doAssert sim.landmarks[0].done
  doAssert sim.finalGateCompleted()
  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp,
    "final gate triumph should restore the completing player"
  doAssert sim.players[playerIndex].poisonTicks == 0
  doAssert sim.players[playerIndex].slowTicks == 0
  doAssert sim.players[playerIndex].chillTicks == 0
  doAssert sim.players[playerIndex].exhaustionTicks == 0
  doAssert sim.players[playerIndex].triumphTicks == FinalGateTriumphTicks
  doAssert sim.players[playerIndex].invulnTicks >= FinalGateTriumphTicks
  doAssert sim.players[playerIndex].statusLabel().contains("triumph")
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalSafe
  doAssert sim.mobs.allIt(it.species != SpeciesForestWolf),
    "final gate triumph should clear local non-boss pressure"
  doAssert sim.expeditionObjectiveHint(playerIndex) == "EXPEDITION COMPLETE"
  var finalNextState: PlayerViewerState
  let finalParsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    finalNextState
  ).parseSpriteProtocolPacket()
  let finalLabels = finalParsed.objectSpriteLabels()
  doAssert "status triumph" in finalLabels
  doAssert finalParsed.sprites.values.toSeq.anyIt(it.label.contains("TRIUMPH SAFE")),
    "HUD status text should make final-gate triumph readable"
  doAssert sim.teamScore() ==
    sim.frontierTiles() +
      ObjectiveScoreValue +
      FinalGateRelicCost * RelicScoreValue +
      FinalGateCampCost * CampScoreValue +
      BossScoreValue +
      FinalGateScoreValue
  let finalScores = parseJson(sim.playerScoresJson())
  doAssert finalScores["final_gate_completed"][0].getBool()
  doAssert finalScores["status_effects"][0].getStr().contains("triumph")
  doAssert finalScores["triumph_ticks"][0].getInt() == FinalGateTriumphTicks

proc testFinalGateRitualAcceleratesWithPartyRoles() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.bossDefeated = true
  sim.relicShards = FinalGateRelicCost
  sim.campsActivated = FinalGateCampCost
  sim.fillGround(GroundGrass, BiomeRuins)

  let
    gateTx = SafeZoneRightTiles + 3
    gateTy = WorldHeightTiles div 2
    gateX = gateTx * WorldTileSize
    gateY = gateTy * WorldTileSize
    tankIndex = sim.addPlayer("tank")
    dpsIndex = sim.addPlayer("dps")
    healerIndex = sim.addPlayer("healer")
  sim.landmarks.add(Landmark(
    tx: gateTx,
    ty: gateTy,
    kind: LandmarkFinalGate,
    hp: 1,
    done: false
  ))
  for item in [
    (index: tankIndex, role: RoleTank, y: gateY - 8),
    (index: dpsIndex, role: RoleDps, y: gateY),
    (index: healerIndex, role: RoleHealer, y: gateY + 8)
  ]:
    sim.players[item.index].x = gateX
    sim.players[item.index].y = item.y
    sim.players[item.index].applyRole(item.role)
    sim.players[item.index].bounds =
      sim.playerBoundsFor(sim.players[item.index])

  doAssert finalGateRitualStep(1) == 1
  doAssert finalGateRitualStep(2) == FinalGateTwoRoleStep
  doAssert finalGateRitualStep(3) == FinalGateThreeRoleStep
  doAssert sim.distinctRolesNearLandmark(
    sim.landmarks[0],
    FinalGateActivationRadius
  ) == 3

  for _ in 1 ..< (FinalGateRitualTicks div FinalGateThreeRoleStep):
    sim.step([InputState(), InputState(), InputState()])
  doAssert not sim.landmarks[0].done
  doAssert sim.expeditionObjectiveHint(tankIndex).startsWith("NEXT HOLD GATE "),
    sim.expeditionObjectiveHint(tankIndex)

  sim.step([InputState(), InputState(), InputState()])
  doAssert sim.landmarks[0].done,
    "all three roles holding the gate should complete the ritual faster"

proc testFinalGateObjectiveOverridesRuinsCleanup() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass, BiomeRuins)
  sim.bossDefeated = true
  sim.relicShards = FinalGateRelicCost
  sim.campsActivated = FinalGateCampCost

  let playerIndex = sim.addPlayer("player")
  sim.players[playerIndex].applyRole(RoleTank)
  sim.players[playerIndex].x = SafeZoneRightPixels + WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  let
    playerTx = sim.players[playerIndex].x div WorldTileSize
    playerTy = sim.players[playerIndex].y div WorldTileSize
  sim.landmarks.add(Landmark(
    tx: playerTx,
    ty: playerTy,
    kind: LandmarkWaystation,
    hp: 1,
    done: false
  ))
  sim.landmarks.add(Landmark(
    tx: playerTx + 1,
    ty: playerTy,
    kind: LandmarkLair,
    hp: LairHp,
    done: false
  ))
  sim.landmarks.add(Landmark(
    tx: playerTx + 2,
    ty: playerTy,
    kind: LandmarkFinalGate,
    hp: 1,
    done: false
  ))

  doAssert sim.expeditionObjectiveHint(playerIndex).startsWith("NEXT HOLD GATE "),
    "final gate should override optional ruins cleanup once prerequisites are met"

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
  doAssert sim.playerNearBlessedShrine(playerIndex)
  doAssert sim.playerNearExpeditionShelter(playerIndex),
    "completed shrines should become local expedition sanctuaries"
  doAssert sim.playerBiomeTacticKind(playerIndex) == BiomeTacticBlessing
  doAssert sim.teamScore() == sim.frontierTiles() + SideObjectiveScoreValue
  let scores = parseJson(sim.playerScoresJson())
  doAssert scores["side_objectives_completed"][0].getInt() == 1

  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp - 1
  sim.players[playerIndex].poisonTicks = 1
  sim.players[playerIndex].slowTicks = 1
  sim.players[playerIndex].chillTicks = 1
  sim.tickCount = CampRecoveryIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp,
    "completed shrine blessings should provide local recovery"
  doAssert sim.players[playerIndex].poisonTicks == 0
  doAssert sim.players[playerIndex].slowTicks == 0
  doAssert sim.players[playerIndex].chillTicks == 0

  sim.fillGround(GroundSnow, BiomeSnow)
  sim.food = 0
  sim.players[playerIndex].lives = 3
  sim.players[playerIndex].invulnTicks = 0
  sim.tickCount = ColdExposureIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == 3,
    "completed shrine blessings should shelter local biome pressure"

  var state: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    state
  ).parseSpriteProtocolPacket()
  let labels = parsed.objectSpriteLabels()
  doAssert "status blessing" in labels,
    "sprite observations should show when a shrine blessing is active"
  doAssert "shrine" notin labels
  doAssert "prompt shrine f2" notin labels

proc testRescueSideObjectiveRequiresHoldAndRewardsParty() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundMud, BiomeSwamp)
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
  let trailIndex = tileIndex(
    sim.landmarks[0].tx + RescueTrailForwardTiles,
    sim.landmarks[0].ty
  )
  sim.tiles[trailIndex] = true
  sim.elevations[trailIndex] = 4

  sim.step([InputState()])

  doAssert not sim.landmarks[0].done,
    "rescue events should require a short hold instead of instant pickup"
  doAssert sim.landmarks[0].progress == 1
  doAssert sim.sideObjectivesCompleted == 0
  doAssert sim.tiles[trailIndex]
  doAssert sim.elevations[trailIndex] == 4

  for _ in 1 ..< RescueEventTicks:
    sim.step([InputState()])

  doAssert sim.landmarks[0].done
  doAssert sim.sideObjectivesCompleted == 1
  doAssert sim.food == RescueFoodBonus
  doAssert sim.players[playerIndex].lives ==
    sim.players[playerIndex].maxHp - 1
  doAssert sim.players[playerIndex].guideTicks == RescueGuideTicks
  doAssert sim.players[playerIndex].statusLabel().contains("guide")
  doAssert sim.players[playerIndex].statusSpeedPercent() ==
    RescueGuideSpeedPercent
  doAssert sim.teamScore() == sim.frontierTiles() + SideObjectiveScoreValue
  doAssert sim.groundKinds[trailIndex] == GroundBridge,
    "rescued travelers should reveal a local route through rough biome ground"
  doAssert not sim.tiles[trailIndex],
    "rescue trails should clear local blockers"
  doAssert sim.elevations[trailIndex] <= 1,
    "rescue trails should soften nearby steep terrain"
  var rescueNextState: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    rescueNextState
  ).parseSpriteProtocolPacket()
  let labels = parsed.objectSpriteLabels()
  doAssert "status guide" in labels,
    "sprite observations should show when rescue guide knowledge is active"
  doAssert parsed.sprites.values.toSeq.anyIt(it.label.contains("GUIDE SAFE")),
    "HUD status text should make rescue guide knowledge readable"
  doAssert "rescue" notin labels
  doAssert "prompt rescue f2" notin labels

  sim.players[playerIndex].slowTicks = StatusSlowTicks
  sim.step([InputState()])
  doAssert sim.players[playerIndex].slowTicks <=
    StatusSlowTicks - 1 - RescueGuideStatusRecoveryTicks,
    "guide knowledge should help the party recover from route pressure"

  sim.players[playerIndex].slowTicks = 0
  sim.players[playerIndex].guideTicks = 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].guideTicks == 0,
    "rescue guide knowledge should expire after the next push window"

proc testRescueGuideFollowsAndThanksAtCamp() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundGrass, BiomeForest)
  sim.food = 0

  let playerIndex = sim.addPlayer("guide")
  sim.players[playerIndex].x = SafeZoneRightPixels + 2 * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkRescue,
    hp: 1,
    done: false
  ))
  for _ in 0 ..< RescueEventTicks:
    sim.step([InputState()])

  doAssert sim.guides.len == 1,
    "completed rescues should spawn a visible guide follower"
  sim.players[playerIndex].x = 2 * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.step([InputState()])
  doAssert sim.guides.len == 1
  doAssert sim.guides[0].done
  doAssert sim.guides[0].thanksTicks > 0

  var nextState: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  ).parseSpriteProtocolPacket()
  let labels = parsed.objectSpriteLabels()
  doAssert "guide" in labels
  doAssert "guide thank you" in labels,
    "dropped-off rescue guides should visibly thank the party"

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

proc placeTestPlayer(
  sim: var SimServer,
  playerIndex: int,
  role: PlayerRole,
  x,
  y: int
) =
  sim.players[playerIndex].applyRole(role)
  sim.players[playerIndex].x = x
  sim.players[playerIndex].y = y
  sim.players[playerIndex].bounds = sim.playerBoundsFor(sim.players[playerIndex])

proc testCooperativeObjectiveHoldsStackPartyEffort() =
  doAssert objectiveHoldStep(
    LandmarkRescue,
    BiomeForest,
    RoleHealer
  ) == HealerRescueEventStep
  doAssert objectiveHoldStep(
    LandmarkWaystation,
    BiomeSwamp,
    RoleTank
  ) == BiomeWaystationFastStep
  doAssert objectiveHoldStep(
    LandmarkBeacon,
    BiomeRuins,
    RoleDps
  ) == DpsBeaconAttunementStep

  var beaconSim = initPartyProgressorForTest()
  beaconSim.clearTerrain()
  beaconSim.mobs.setLen(0)
  beaconSim.pickups.setLen(0)
  beaconSim.landmarks.setLen(0)
  beaconSim.fillGround(GroundGrass, BiomeRuins)
  beaconSim.bossDefeated = true
  beaconSim.mobSpawnCooldown = 999

  let
    beaconTx = SafeZoneRightTiles + 2
    beaconTy = WorldHeightTiles div 2
    beaconX = beaconTx * WorldTileSize
    beaconY = beaconTy * WorldTileSize
    beaconTank = beaconSim.addPlayer("tank")
    beaconDps = beaconSim.addPlayer("dps")
    beaconHealer = beaconSim.addPlayer("healer")
    coopStep = CooperativeObjectiveHoldMaxStep
  beaconSim.placeTestPlayer(beaconTank, RoleTank, beaconX, beaconY - 6)
  beaconSim.placeTestPlayer(beaconDps, RoleDps, beaconX, beaconY)
  beaconSim.placeTestPlayer(beaconHealer, RoleHealer, beaconX, beaconY + 6)
  beaconSim.landmarks.add(Landmark(
    tx: beaconTx,
    ty: beaconTy,
    kind: LandmarkBeacon,
    hp: 1,
    done: false
  ))

  beaconSim.step([InputState(), InputState(), InputState()])
  doAssert beaconSim.landmarks[0].progress == coopStep,
    "nearby teammates should stack relic attunement up to the co-op cap"
  doAssert not beaconSim.landmarks[0].done
  for _ in 1 ..< ((BeaconAttunementTicks + coopStep - 1) div coopStep):
    beaconSim.step([InputState(), InputState(), InputState()])
  doAssert beaconSim.landmarks[0].done
  doAssert beaconSim.relicShards == 1
  doAssert beaconSim.players[beaconDps].surveyTicks == BeaconSurveyTicks
  doAssert beaconSim.players[beaconTank].moraleTicks == ObjectiveMoraleTicks
  doAssert beaconSim.players[beaconTank].statusLabel().contains("morale")
  doAssert beaconSim.players[beaconTank].statusSpeedPercent() ==
    ObjectiveMoraleSpeedPercent
  var moraleNextState: PlayerViewerState
  let moraleParsed = beaconSim.buildSpriteProtocolPlayerUpdates(
    beaconTank,
    initPlayerViewerState(),
    moraleNextState
  ).parseSpriteProtocolPacket()
  let moraleLabels = moraleParsed.objectSpriteLabels()
  doAssert "status morale" in moraleLabels
  doAssert moraleParsed.sprites.values.toSeq.anyIt(it.label.contains("MORALE")),
    "HUD status text should make grouped objective morale readable"
  let moraleScores = parseJson(beaconSim.playerScoresJson())
  doAssert moraleScores["morale_ticks"][0].getInt() == ObjectiveMoraleTicks
  beaconSim.players[beaconTank].abilityCooldown = 3
  beaconSim.step([InputState(), InputState(), InputState()])
  doAssert beaconSim.players[beaconTank].abilityCooldown < 2,
    "objective morale should help recover role powers on the next push"
  beaconSim.players[beaconTank].moraleTicks = 1
  beaconSim.step([InputState(), InputState(), InputState()])
  doAssert beaconSim.players[beaconTank].moraleTicks == 0,
    "objective morale should expire after its next-push window"

  var rescueSim = initPartyProgressorForTest()
  rescueSim.clearTerrain()
  rescueSim.mobs.setLen(0)
  rescueSim.pickups.setLen(0)
  rescueSim.landmarks.setLen(0)
  rescueSim.fillGround(GroundGrass, BiomeForest)
  rescueSim.bossDefeated = true
  rescueSim.mobSpawnCooldown = 999

  let
    rescueTx = SafeZoneRightTiles + 2
    rescueTy = WorldHeightTiles div 2
    rescueX = rescueTx * WorldTileSize
    rescueY = rescueTy * WorldTileSize
    tankIndex = rescueSim.addPlayer("tank")
    dpsIndex = rescueSim.addPlayer("dps")
    healerIndex = rescueSim.addPlayer("healer")
  rescueSim.placeTestPlayer(tankIndex, RoleTank, rescueX, rescueY - 6)
  rescueSim.placeTestPlayer(dpsIndex, RoleDps, rescueX, rescueY)
  rescueSim.placeTestPlayer(healerIndex, RoleHealer, rescueX, rescueY + 6)
  rescueSim.landmarks.add(Landmark(
    tx: rescueTx,
    ty: rescueTy,
    kind: LandmarkRescue,
    hp: 1,
    done: false
  ))

  rescueSim.step([InputState(), InputState(), InputState()])
  doAssert rescueSim.landmarks[0].progress == coopStep,
    "nearby teammates should stack rescue hold progress up to the co-op cap"
  doAssert not rescueSim.landmarks[0].done
  for _ in 1 ..< ((RescueEventTicks + coopStep - 1) div coopStep):
    rescueSim.step([InputState(), InputState(), InputState()])
  doAssert rescueSim.landmarks[0].done,
    "a grouped party should complete rescue holds faster than a solo player"
  doAssert rescueSim.players[tankIndex].moraleTicks == ObjectiveMoraleTicks,
    "grouped rescue completions should grant visible party morale"

  var waypointSim = initPartyProgressorForTest()
  waypointSim.clearTerrain()
  waypointSim.mobs.setLen(0)
  waypointSim.pickups.setLen(0)
  waypointSim.landmarks.setLen(0)
  waypointSim.fillGround(GroundMud, BiomeSwamp)
  waypointSim.bossDefeated = true
  waypointSim.mobSpawnCooldown = 999

  let
    waypointTx = SafeZoneRightTiles + 3
    waypointTy = WorldHeightTiles div 2
    waypointX = waypointTx * WorldTileSize
    waypointY = waypointTy * WorldTileSize
    waypointTank = waypointSim.addPlayer("tank")
    waypointDps = waypointSim.addPlayer("dps")
    waypointHealer = waypointSim.addPlayer("healer")
  waypointSim.placeTestPlayer(waypointTank, RoleTank, waypointX, waypointY - 6)
  waypointSim.placeTestPlayer(waypointDps, RoleDps, waypointX, waypointY)
  waypointSim.placeTestPlayer(
    waypointHealer,
    RoleHealer,
    waypointX,
    waypointY + 6
  )
  waypointSim.landmarks.add(Landmark(
    tx: waypointTx,
    ty: waypointTy,
    kind: LandmarkWaystation,
    hp: 1,
    done: false
  ))

  waypointSim.step([InputState(), InputState(), InputState()])
  doAssert waypointSim.landmarks[0].progress == coopStep,
    "nearby teammates should stack waystation hold progress up to the co-op cap"
  for _ in 1 ..< ((BiomeWaystationTicks + coopStep - 1) div coopStep):
    waypointSim.step([InputState(), InputState(), InputState()])
  doAssert waypointSim.landmarks[0].done,
    "a grouped party should complete waystations faster than a solo player"
  doAssert waypointSim.players[waypointTank].moraleTicks == ObjectiveMoraleTicks,
    "grouped waystation completions should grant visible party morale"

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
  doAssert sim.players[playerIndex].huntTicks == LairHunterTicks
  doAssert sim.players[playerIndex].statusLabel().contains("hunt")
  doAssert sim.hasPickup(PickupWood)
  doAssert sim.hasPickup(PickupFood)
  doAssert sim.mobs.len == 2,
    "destroyed lairs should pacify nearby threats without deleting bosses; remaining=" &
      $sim.mobs.len
  doAssert sim.mobs.anyIt(it.species == SpeciesDireWolf)
  doAssert sim.mobs.anyIt(it.kind == BossMob)
  doAssert sim.completedLairCountInBiome(BiomeOrigin) == 1
  doAssert lairRespawnCooldownBonus(1) == LairRespawnCooldownBonus
  let huntDamage = sim.playerAttackDamage(
    sim.players[playerIndex],
    sim.mobs.filterIt(it.kind != BossMob)[0]
  )
  sim.players[playerIndex].huntTicks = 0
  doAssert huntDamage == sim.playerAttackDamage(
    sim.players[playerIndex],
    sim.mobs.filterIt(it.kind != BossMob)[0]
  ) + LairHunterDamageBonus,
    "lair hunter window should make the next non-boss fights easier"
  sim.players[playerIndex].huntTicks = 0
  let bossDamageWithoutHunt = sim.playerAttackDamage(
    sim.players[playerIndex],
    sim.mobs.filterIt(it.kind == BossMob)[0]
  )
  sim.players[playerIndex].huntTicks = LairHunterTicks
  doAssert sim.playerAttackDamage(
    sim.players[playerIndex],
    sim.mobs.filterIt(it.kind == BossMob)[0]
  ) == bossDamageWithoutHunt,
    "lair hunter window should not bypass the final-boss party check"
  var lairNextState: PlayerViewerState
  let labels = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    lairNextState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status hunt" in labels,
    "sprite observations should show the lair-hunter payoff"
  sim.players[playerIndex].huntTicks = 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].huntTicks == 0,
    "lair hunter window should expire after the next fight window"

  sim.teamFrontier = lairX
  sim.mobSpawnCooldown = 0
  sim.players[playerIndex].attackTicks = 0
  sim.players[playerIndex].attackResolved = false
  sim.step([InputState()])
  doAssert sim.mobSpawnCooldown >= 24 + LairRespawnCooldownBonus,
    "cleared lairs should slow future respawns in their biome"
  doAssert sim.teamScore() == sim.frontierTiles() + SideObjectiveScoreValue

proc testBiomeWaystationsCreateRoleDetoursAndShelters() =
  doAssert waystationActivationStep(BiomeSwamp, RoleTank) ==
    BiomeWaystationFastStep
  doAssert waystationActivationStep(BiomeSwamp, RoleDps) == 1
  doAssert BiomeSwamp.waystationPromptLabel() == "BRIDGE T"
  doAssert BiomeSnow.waystationPromptLabel() == "HEARTH H"

  let seededSim = initPartyProgressorForTest()
  doAssert seededSim.landmarks.countIt(it.kind == LandmarkWaystation) ==
      BiomeCount * ExpeditionCycleCount,
    "one waystation should be seeded into each procedural adventure segment"

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
  doAssert swampSim.players[swampPlayer].routeTicks == BiomeWaystationRouteTicks
  doAssert swampSim.players[swampPlayer].statusLabel().contains("route")
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

  let
    roughTx = bridgeTx + BiomeWaystationRouteForwardTiles + 2
    roughX = roughTx * WorldTileSize
    roughY = bridgeTy * WorldTileSize
    roughIndex = tileIndex(roughTx, bridgeTy)
  swampSim.groundKinds[roughIndex] = GroundMud
  swampSim.biomeKinds[roughIndex] = BiomeSwamp
  swampSim.elevations[roughIndex] = 4
  swampSim.players[swampPlayer].x = roughX
  swampSim.players[swampPlayer].y = roughY
  swampSim.players[swampPlayer].bounds =
    swampSim.playerBoundsFor(swampSim.players[swampPlayer])
  doAssert not swampSim.playerNearExpeditionShelter(swampPlayer),
    "route momentum should be checked beyond the static waystation shelter"
  doAssert swampSim.survivalPressureKind(swampPlayer) == SurvivalSafe,
    "waystation route knowledge should protect the immediate next push"
  doAssert swampSim.speedPercentAt(roughX, roughY) <
    BiomeWaystationRouteMinSpeedPercent
  doAssert swampSim.playerMovementSpeedPercent(
    swampSim.players[swampPlayer],
    roughX,
    roughY
  ) >= BiomeWaystationRouteMinSpeedPercent,
    "waystation route knowledge should keep rough pushes readable"
  swampSim.players[swampPlayer].slowTicks = 0
  swampSim.tickCount = SwampMireIntervalTicks - 1
  swampSim.step([InputState()])
  doAssert swampSim.players[swampPlayer].slowTicks == 0,
    "waystation route knowledge should block immediate mire pulses"
  var routeState: PlayerViewerState
  let routeParsed = swampSim.buildSpriteProtocolPlayerUpdates(
    swampPlayer,
    initPlayerViewerState(),
    routeState
  ).parseSpriteProtocolPacket()
  let routeLabels = routeParsed.objectSpriteLabels()
  doAssert "status route" in routeLabels
  doAssert routeParsed.sprites.values.toSeq.anyIt(it.label.contains("ROUTE SAFE")),
    "HUD status text should make waystation route knowledge readable"
  swampSim.players[swampPlayer].routeTicks = 1
  swampSim.step([InputState()])
  doAssert swampSim.players[swampPlayer].routeTicks == 0
  doAssert swampSim.survivalPressureKind(swampPlayer) == SurvivalMire,
    "waystation route knowledge should expire back to local biome pressure"

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

proc testDpsBeamSpecialDamagesMobsInFacingLine() =
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

  for dx in [8, WorldTileSize * DpsBeamTiles - 8]:
    sim.mobs.add(Mob(
      kind: SnakeMob,
      x: sim.players[playerIndex].x + dx,
      y: sim.players[playerIndex].y,
      sprite: sim.mobSpriteFor(SnakeMob),
      bounds: sim.mobBoundsFor(SnakeMob),
      hp: 5,
      attackCooldown: 99
    ))
  sim.mobs.add(Mob(
    kind: SnakeMob,
    x: sim.players[playerIndex].x + WorldTileSize,
    y: sim.players[playerIndex].y + WorldTileSize * 2,
    sprite: sim.mobSpriteFor(SnakeMob),
    bounds: sim.mobBoundsFor(SnakeMob),
    hp: 5,
    attackCooldown: 99
  ))
  sim.mobs.add(Mob(
    kind: SnakeMob,
    x: sim.players[playerIndex].x + WorldTileSize * (DpsBeamTiles + 1),
    y: sim.players[playerIndex].y,
    sprite: sim.mobSpriteFor(SnakeMob),
    bounds: sim.mobBoundsFor(SnakeMob),
    hp: 5,
    attackCooldown: 99
  ))

  sim.step([InputState(b: true)])

  doAssert sim.players[playerIndex].abilityCooldown > 0
  doAssert sim.players[playerIndex].attackTicks > 0
  doAssert sim.mobs.len == 4
  doAssert sim.mobs[0].hp == 5 - DpsBeamDamage
  doAssert sim.mobs[1].hp == 5 - DpsBeamDamage
  doAssert sim.mobs[2].hp == 5,
    "DPS beam should not splash targets outside the line"
  doAssert sim.mobs[3].hp == 5,
    "DPS beam should stop after five tiles"

proc testPartyFocusRewardsMixedRoleAttacksAndShowsBadge() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.bossDefeated = true
  sim.fillGround(GroundGrass)

  let
    tankIndex = sim.addPlayer("tank")
    dpsIndex = sim.addPlayer("dps")
    healerIndex = sim.addPlayer("healer")
    baseX = SafeZoneRightPixels + WorldTileSize
    baseY = (WorldHeightTiles div 2) * WorldTileSize
  for item in [
    (index: tankIndex, role: RoleTank, y: baseY - 12),
    (index: dpsIndex, role: RoleDps, y: baseY),
    (index: healerIndex, role: RoleHealer, y: baseY + 12)
  ]:
    sim.players[item.index].x = baseX
    sim.players[item.index].y = item.y
    sim.players[item.index].facing = FaceRight
    sim.players[item.index].applyRole(item.role)
    sim.players[item.index].bounds =
      sim.playerBoundsFor(sim.players[item.index])

  let
    dpsHit = sim.attackRect(sim.players[dpsIndex])
    mobSprite = sim.mobSpriteFor(BearMob)
    mobBounds = sim.mobBoundsFor(BearMob)
  sim.mobs.add(Mob(
    kind: BearMob,
    species: SpeciesBrownBear,
    x: dpsHit.x,
    y: dpsHit.y,
    sprite: mobSprite,
    bounds: mobBounds,
    hp: 24,
    attackCooldown: 99
  ))
  sim.mobs[0].attackerIds = @[
    sim.players[tankIndex].id,
    sim.players[dpsIndex].id
  ]
  sim.mobs[0].attackerTicks = @[sim.tickCount, sim.tickCount]

  doAssert sim.mobs[0].partyFocusRoleCount(sim.players, sim.tickCount) == 2
  doAssert sim.mobs[0].partyFocusDamageBonus(sim.players, sim.tickCount) ==
    PartyFocusTwoRoleDamageBonus
  var focusNextState: PlayerViewerState
  let labels = sim.buildSpriteProtocolPlayerUpdates(
    dpsIndex,
    initPlayerViewerState(),
    focusNextState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status party focus" in labels,
    "focused mobs should advertise the mixed-role damage window"

  let twoRoleHp = sim.mobs[0].hp
  sim.step([InputState(), InputState(attack: true), InputState()])
  doAssert sim.mobs.len == 1
  doAssert sim.mobs[0].hp ==
    twoRoleHp - (3 + PartyFocusTwoRoleDamageBonus),
    "two mixed roles should add a small normal-attack focus bonus"

  sim.players[dpsIndex].attackTicks = 0
  sim.players[dpsIndex].attackResolved = false
  sim.mobs[0].x = dpsHit.x
  sim.mobs[0].y = dpsHit.y
  sim.mobs[0].attackerIds = @[
    sim.players[tankIndex].id,
    sim.players[dpsIndex].id,
    sim.players[healerIndex].id
  ]
  sim.mobs[0].attackerTicks = @[
    sim.tickCount,
    sim.tickCount,
    sim.tickCount
  ]

  doAssert sim.mobs[0].partyFocusRoleCount(sim.players, sim.tickCount) == 3
  doAssert sim.mobs[0].partyFocusDamageBonus(sim.players, sim.tickCount) ==
    PartyFocusThreeRoleDamageBonus
  let threeRoleHp = sim.mobs[0].hp
  sim.step([InputState(), InputState(attack: true), InputState()])
  doAssert sim.mobs.len == 1
  doAssert sim.mobs[0].hp ==
    threeRoleHp - (3 + PartyFocusThreeRoleDamageBonus),
    "all three roles should create the strongest focus-fire damage bonus"

proc testGateTitanRaidWindowRewardsFormationAndFocus() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.bossDefeated = false
  sim.mobSpawnCooldown = 999
  sim.fillGround(GroundRuins, BiomeRuins)

  let
    tankIndex = sim.addPlayer("tank")
    dpsIndex = sim.addPlayer("dps")
    healerIndex = sim.addPlayer("healer")
    baseX = SafeZoneRightPixels + WorldTileSize
    baseY = (WorldHeightTiles div 2) * WorldTileSize
  for item in [
    (index: tankIndex, role: RoleTank, y: baseY - 12),
    (index: dpsIndex, role: RoleDps, y: baseY),
    (index: healerIndex, role: RoleHealer, y: baseY + 12)
  ]:
    sim.players[item.index].x = baseX
    sim.players[item.index].y = item.y
    sim.players[item.index].facing = FaceRight
    sim.players[item.index].applyRole(item.role)
    sim.players[item.index].bounds =
      sim.playerBoundsFor(sim.players[item.index])

  let dpsHit = sim.attackRect(sim.players[dpsIndex])
  sim.mobs.add(Mob(
    kind: BossMob,
    species: SpeciesGateTitan,
    x: dpsHit.x,
    y: dpsHit.y,
    sprite: sim.bossSprite,
    bounds: sim.bossBounds,
    hp: BossHp,
    attackCooldown: 0,
    attackPhase: MobTelegraph,
    attackTicks: MobTelegraphTicks - 1
  ))

  doAssert sim.playerInTrioFormation(dpsIndex)
  doAssert sim.bossRaidDamageBonus(dpsIndex, sim.mobs[0]) ==
    BossTrioDamageBonus

  sim.mobs[0].attackerIds = @[
    sim.players[tankIndex].id,
    sim.players[dpsIndex].id,
    sim.players[healerIndex].id
  ]
  sim.mobs[0].attackerTicks = @[
    sim.tickCount,
    sim.tickCount,
    sim.tickCount
  ]
  doAssert sim.bossRaidDamageBonus(dpsIndex, sim.mobs[0]) ==
    BossTrioDamageBonus + BossFocusDamageBonus

  let raidHp = sim.mobs[0].hp
  sim.step([InputState(), InputState(attack: true), InputState()])
  doAssert sim.mobs.len == 1
  doAssert sim.mobs[0].hp ==
    raidHp - (
      3 + PartyFocusThreeRoleDamageBonus + BossTrioDamageBonus +
        BossFocusDamageBonus
    ),
    "the gate titan should take extra damage from trio formation and focus"
  doAssert sim.mobs[0].bossStaggered(),
    "three-role focus should stagger the gate titan"
  doAssert sim.mobs[0].attackPhase == MobIdle
  doAssert sim.mobs[0].attackTicks == 0
  doAssert sim.mobs[0].attackCooldown >= BossStaggerAttackCooldown
  doAssert sim.mobs[0].staggerTicks == BossStaggerTicks - 1
  var staggerNextState: PlayerViewerState
  let staggerLabels = sim.buildSpriteProtocolPlayerUpdates(
    dpsIndex,
    initPlayerViewerState(),
    staggerNextState
  ).parseSpriteProtocolPacket().objectSpriteLabels()
  doAssert "status stagger" in staggerLabels,
    "staggered gate titans should advertise the raid payoff"

  sim.mobs[0].staggerTicks = 1
  sim.mobs[0].attackCooldown = 0
  sim.step([InputState(), InputState(), InputState()])
  doAssert sim.mobs[0].staggerTicks == 0
  doAssert sim.mobs[0].attackPhase == MobIdle,
    "boss stagger should hold the titan idle through its last tick"

  sim.players[dpsIndex].attackTicks = 0
  sim.players[dpsIndex].attackResolved = false
  sim.players[healerIndex].x += TrioFormationRadius + WorldTileSize
  sim.players[healerIndex].bounds =
    sim.playerBoundsFor(sim.players[healerIndex])
  sim.mobs[0].x = dpsHit.x
  sim.mobs[0].y = dpsHit.y
  sim.mobs[0].hp = BossHp
  sim.mobs[0].staggerTicks = 0
  sim.mobs[0].attackCooldown = 99
  sim.mobs[0].attackPhase = MobIdle
  sim.mobs[0].attackTicks = 0
  sim.mobs[0].attackerIds.setLen(0)
  sim.mobs[0].attackerTicks.setLen(0)

  doAssert not sim.playerInTrioFormation(dpsIndex)
  doAssert sim.bossRaidDamageBonus(dpsIndex, sim.mobs[0]) == 0
  sim.step([InputState(), InputState(attack: true), InputState()])
  doAssert sim.mobs.len == 1
  doAssert sim.mobs[0].hp == BossHp - 3,
    "uncoordinated boss hits should keep the ordinary DPS damage budget"
  doAssert sim.mobs[0].staggerTicks == 0,
    "uncoordinated boss hits should not stagger the gate titan"

proc testMixedRoleFormationRechargesPowersAndShowsBadge() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.bossDefeated = true
  sim.mobSpawnCooldown = 999
  sim.fillGround(GroundGrass, BiomeForest)

  let
    tankIndex = sim.addPlayer("tank")
    dpsIndex = sim.addPlayer("dps")
    healerIndex = sim.addPlayer("healer")
    baseX = SafeZoneRightPixels + WorldTileSize
    baseY = (WorldHeightTiles div 2) * WorldTileSize
  for item in [
    (index: tankIndex, role: RoleTank, y: baseY - 12),
    (index: dpsIndex, role: RoleDps, y: baseY),
    (index: healerIndex, role: RoleHealer, y: baseY + 12)
  ]:
    sim.players[item.index].x = baseX
    sim.players[item.index].y = item.y
    sim.players[item.index].applyRole(item.role)
    sim.players[item.index].bounds =
      sim.playerBoundsFor(sim.players[item.index])

  doAssert sim.playerInTrioFormation(tankIndex)
  doAssert sim.playerInTrioFormation(dpsIndex)
  doAssert sim.playerInTrioFormation(healerIndex)
  doAssert sim.playerPartyTacticLabel(dpsIndex) == "trio"

  sim.players[dpsIndex].abilityCooldown = 10
  var state: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    dpsIndex,
    initPlayerViewerState(),
    state
  ).parseSpriteProtocolPacket()
  doAssert "status trio" in parsed.objectSpriteLabels(),
    "grouped tank/DPS/healer parties should show the trio formation badge"
  doAssert parsed.sprites.values.toSeq.anyIt(it.label.contains("TRIO")),
    "HUD status text should make the trio formation readable"

  sim.step([InputState(), InputState(), InputState()])
  doAssert sim.players[dpsIndex].abilityCooldown ==
    10 - 1 - TrioFormationCooldownStep,
    "trio formation should recover role powers faster between fights"

  sim.players[dpsIndex].abilityCooldown = 10
  sim.players[healerIndex].x += TrioFormationRadius + WorldTileSize
  sim.players[healerIndex].bounds =
    sim.playerBoundsFor(sim.players[healerIndex])
  doAssert not sim.playerInTrioFormation(dpsIndex)
  sim.step([InputState(), InputState(), InputState()])
  doAssert sim.players[dpsIndex].abilityCooldown == 9,
    "role power recovery should return to normal when the formation breaks"

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

  sim.players[healerIndex].x = sim.players[woundedIndex].x + WorldTileSize
  sim.players[healerIndex].y = sim.players[woundedIndex].y
  sim.players[healerIndex].abilityCooldown = 0
  sim.players[healerIndex].bounds =
    sim.playerBoundsFor(sim.players[healerIndex])
  sim.players[woundedIndex].lives = sim.players[woundedIndex].maxHp
  sim.players[woundedIndex].poisonTicks = StatusPoisonTicks
  sim.players[woundedIndex].slowTicks = StatusSlowTicks
  sim.players[woundedIndex].chillTicks = StatusChillTicks
  sim.step([InputState(), InputState(b: true)])
  doAssert sim.players[woundedIndex].poisonTicks > 0,
    "healer pulse should require holding special before it fires"
  sim.holdSpecial(healerIndex, HealerPulseHoldTicks - 1)
  doAssert sim.players[woundedIndex].lives == sim.players[woundedIndex].maxHp
  doAssert sim.players[woundedIndex].poisonTicks == 0
  doAssert sim.players[woundedIndex].slowTicks == 0
  doAssert sim.players[woundedIndex].chillTicks == 0
  doAssert sim.players[healerIndex].abilityCooldown > 0,
    "healer pulse should spend cooldown when cleansing party statuses"

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

proc testLateRunExhaustionUsesRationsAndShowsStatus() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundSnow, BiomeSnow)

  let
    playerIndex = sim.addPlayer("hungry")
    allyIndex = sim.addPlayer("warm")
    snowX = firstTileForBiome(BiomeSnow) * WorldTileSize
    snowY = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].x = snowX
  sim.players[playerIndex].y = snowY
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[allyIndex].x = snowX + WorldTileSize
  sim.players[allyIndex].y = snowY
  sim.players[allyIndex].bounds =
    sim.playerBoundsFor(sim.players[allyIndex])
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalSafe,
    "nearby allies should let the exhaustion test avoid cold damage"

  sim.food = 1
  sim.tickCount = ExhaustionIntervalTicks - 1
  sim.step([InputState(), InputState()])
  doAssert sim.food == 0,
    "late-run exhaustion should consume a shared ration before slowing players"
  doAssert sim.players[playerIndex].exhaustionTicks == 0

  sim.tickCount = ExhaustionIntervalTicks - 1
  sim.step([InputState(), InputState()])
  doAssert sim.players[playerIndex].exhaustionTicks > 0,
    "late-run travel without food should create exhaustion pressure"
  doAssert sim.players[playerIndex].statusLabel().contains("exhaust")
  doAssert sim.players[playerIndex].statusSpeedPercent() <=
    StatusExhaustionSpeedPercent

  var nextState: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    nextState
  ).parseSpriteProtocolPacket()
  let labels = parsed.objectSpriteLabels()
  doAssert "status exhaust" in labels
  doAssert parsed.sprites.values.toSeq.anyIt(it.label.contains("EXHAUST SAFE WARMTH")),
    "HUD status text should make ration exhaustion readable"

  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood
  doAssert sim.carryHudLabel(playerIndex) == "food sel eat"
  sim.step([InputState(select: true), InputState()])
  doAssert sim.players[playerIndex].exhaustionTicks == 0,
    "carried food should clear exhaustion as an explicit ration choice"
  doAssert not sim.players[playerIndex].carrying

  sim.players[playerIndex].exhaustionTicks = StatusExhaustionTicks
  sim.players[allyIndex].applyRole(RoleHealer)
  sim.players[allyIndex].abilityCooldown = 0
  sim.holdSpecial(allyIndex)
  doAssert sim.players[playerIndex].exhaustionTicks == 0,
    "healer pulse should cleanse exhaustion like other expedition statuses"

proc testSnowSharedWarmthClearsColdPressure() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundSnow, BiomeSnow)

  let
    playerIndex = sim.addPlayer("warm")
    allyIndex = sim.addPlayer("ally")
    snowX = firstTileForBiome(BiomeSnow) * WorldTileSize
    snowY = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].x = snowX
  sim.players[playerIndex].y = snowY
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[allyIndex].x = snowX + WorldTileSize
  sim.players[allyIndex].y = snowY
  sim.players[allyIndex].bounds =
    sim.playerBoundsFor(sim.players[allyIndex])
  sim.players[playerIndex].lives = 3
  sim.food = 0

  doAssert sim.survivalPressureKind(playerIndex) == SurvivalSafe,
    "nearby allies should clear visible snow cold pressure"
  doAssert sim.playerBiomeTacticKind(playerIndex) == BiomeTacticWarmth,
    "snow grouping should show a shared warmth tactic"
  sim.tickCount = ColdExposureIntervalTicks - 1
  sim.step([InputState(), InputState()])
  doAssert sim.players[playerIndex].lives == 3,
    "shared warmth should block cold exposure damage"

  var state: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    state
  ).parseSpriteProtocolPacket()
  let labels = parsed.objectSpriteLabels()
  doAssert "status warmth" in labels
  doAssert "status cold" notin labels
  doAssert parsed.sprites.values.toSeq.anyIt(it.label.contains("OK SAFE WARMTH")),
    "HUD status text should make snow warmth readable"

  sim.players[allyIndex].x += SnowWarmthAllyRadius + WorldTileSize
  sim.players[allyIndex].bounds =
    sim.playerBoundsFor(sim.players[allyIndex])
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalCold
  doAssert sim.playerBiomeTacticKind(playerIndex) == BiomeTacticNone
  sim.players[playerIndex].invulnTicks = 0
  sim.tickCount = ColdExposureIntervalTicks - 1
  sim.step([InputState(), InputState()])
  doAssert sim.players[playerIndex].lives == 2,
    "snow cold should resume when the party spreads out"

proc testDesertHeatSurvivalPressureAndOasisShelter() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundSand, BiomeDesert)

  let playerIndex = sim.addPlayer("player1")
  sim.players[playerIndex].x = firstTileForBiome(BiomeDesert) * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp
  sim.food = 1
  sim.tickCount = HeatExposureIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp
  doAssert sim.food == 0,
    "desert heat should consume shared food before damaging players"

  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryFood
  sim.players[playerIndex].invulnTicks = 0
  sim.tickCount = HeatExposureIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == sim.players[playerIndex].maxHp
  doAssert not sim.players[playerIndex].carrying,
    "desert heat should consume carried food before damaging players"

  sim.players[playerIndex].lives = 3
  sim.players[playerIndex].invulnTicks = 0
  sim.tickCount = HeatExposureIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == 2,
    "desert heat should damage exposed players when no food is available"

  sim.players[playerIndex].lives = 3
  sim.players[playerIndex].invulnTicks = 0
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkWaystation,
    hp: 1,
    done: true
  ))
  doAssert sim.playerNearExpeditionShelter(playerIndex),
    "completed desert oasis waystations should count as survival shelters"
  sim.tickCount = HeatExposureIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == 3,
    "desert oasis shelter should block heat exposure damage"

proc testDesertCactusShadeClearsHeatPressure() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.terrainProps.setLen(0)
  sim.fillGround(GroundSand, BiomeDesert)

  let
    shadeTx = firstTileForBiome(BiomeDesert) + 1
    shadeTy = WorldHeightTiles div 2
    playerIndex = sim.addPlayer("shaded")
  sim.terrainProps.add(TerrainProp(
    tx: shadeTx,
    ty: shadeTy,
    kind: TerrainCactus
  ))
  sim.players[playerIndex].x = shadeTx * WorldTileSize
  sim.players[playerIndex].y = shadeTy * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].lives = 3
  sim.food = 0

  doAssert sim.playerNearDesertShade(playerIndex),
    "desert cactus props should create local shade"
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalSafe,
    "cactus shade should clear visible heat pressure"
  doAssert sim.playerBiomeTacticKind(playerIndex) == BiomeTacticShade
  sim.tickCount = HeatExposureIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == 3,
    "cactus shade should block desert heat pulses"

  var state: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    state
  ).parseSpriteProtocolPacket()
  let labels = parsed.objectSpriteLabels()
  doAssert "status shade" in labels
  doAssert "status heat" notin labels
  doAssert parsed.sprites.values.toSeq.anyIt(it.label.contains("OK SAFE SHADE")),
    "HUD status text should make cactus shade readable"

  sim.players[playerIndex].x += DesertShadeRadius + WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  doAssert not sim.playerNearDesertShade(playerIndex)
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalHeat
  doAssert sim.playerBiomeTacticKind(playerIndex) == BiomeTacticNone
  sim.players[playerIndex].invulnTicks = 0
  sim.tickCount = HeatExposureIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].lives == 2,
    "desert heat should resume away from cactus shade"

proc testSwampMireSurvivalPressureAndBridgeShelter() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundMud, BiomeSwamp)

  let playerIndex = sim.addPlayer("mired")
  sim.players[playerIndex].x = firstTileForBiome(BiomeSwamp) * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])

  doAssert sim.survivalPressureKind(playerIndex) == SurvivalMire,
    "swamp mud should warn exposed players about mire pressure"
  sim.tickCount = SwampMireIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].slowTicks >= SwampMireTicks - 1,
    "swamp mire should slow exposed players crossing mud"

  sim.players[playerIndex].slowTicks = 0
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkWaystation,
    hp: 1,
    done: true
  ))
  doAssert sim.playerNearExpeditionShelter(playerIndex),
    "completed swamp bridge waystations should count as mire shelters"
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalSafe
  sim.tickCount = SwampMireIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].slowTicks == 0,
    "swamp bridge shelters should block mire slow pulses"

  var roadSim = initPartyProgressorForTest()
  roadSim.clearTerrain()
  roadSim.mobs.setLen(0)
  roadSim.pickups.setLen(0)
  roadSim.landmarks.setLen(0)
  roadSim.fillGround(GroundRoad, BiomeSwamp)
  let roadPlayer = roadSim.addPlayer("road")
  roadSim.players[roadPlayer].x = firstTileForBiome(BiomeSwamp) * WorldTileSize
  roadSim.players[roadPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  roadSim.players[roadPlayer].bounds =
    roadSim.playerBoundsFor(roadSim.players[roadPlayer])
  doAssert roadSim.survivalPressureKind(roadPlayer) == SurvivalSafe,
    "dry swamp roads should clear mire pressure"
  roadSim.tickCount = SwampMireIntervalTicks - 1
  roadSim.step([InputState()])
  doAssert roadSim.players[roadPlayer].slowTicks == 0,
    "dry swamp roads should not apply mire slow pulses"

proc testTankGuardBlocksBiomePressure() =
  var desertSim = initPartyProgressorForTest()
  desertSim.clearTerrain()
  desertSim.mobs.setLen(0)
  desertSim.pickups.setLen(0)
  desertSim.landmarks.setLen(0)
  desertSim.fillGround(GroundSand, BiomeDesert)

  let
    tankIndex = desertSim.addPlayer("tank")
    allyIndex = desertSim.addPlayer("ally")
    desertX = firstTileForBiome(BiomeDesert) * WorldTileSize
    desertY = (WorldHeightTiles div 2) * WorldTileSize
  desertSim.players[tankIndex].applyRole(RoleTank)
  desertSim.players[tankIndex].x = desertX
  desertSim.players[tankIndex].y = desertY
  desertSim.players[tankIndex].bounds =
    desertSim.playerBoundsFor(desertSim.players[tankIndex])
  desertSim.players[tankIndex].guardTicks = TankGuardTicks
  desertSim.players[allyIndex].x = desertX + WorldTileSize
  desertSim.players[allyIndex].y = desertY
  desertSim.players[allyIndex].bounds =
    desertSim.playerBoundsFor(desertSim.players[allyIndex])
  desertSim.players[allyIndex].lives = 3
  desertSim.food = 0

  doAssert desertSim.playerProtectedByTankGuard(allyIndex),
    "active tank guard should cover nearby teammates"
  doAssert desertSim.survivalPressureKind(allyIndex) == SurvivalSafe,
    "tank guard should clear visible desert heat pressure"
  doAssert desertSim.playerBiomeTacticKind(allyIndex) == BiomeTacticGuard,
    "tank guard should show as the active survival tactic"
  desertSim.tickCount = HeatExposureIntervalTicks - 1
  desertSim.step([InputState(), InputState()])
  doAssert desertSim.players[allyIndex].lives == 3,
    "tank guard should block heat exposure damage for nearby teammates"

  var state: PlayerViewerState
  let parsed = desertSim.buildSpriteProtocolPlayerUpdates(
    allyIndex,
    initPlayerViewerState(),
    state
  ).parseSpriteProtocolPacket()
  let labels = parsed.objectSpriteLabels()
  doAssert "status guard" in labels
  doAssert "status heat" notin labels
  doAssert parsed.sprites.values.toSeq.anyIt(it.label.contains("OK SAFE GUARD")),
    "HUD status text should make tank-guard survival readable"

  desertSim.players[tankIndex].guardTicks = 0
  doAssert desertSim.survivalPressureKind(allyIndex) == SurvivalHeat
  desertSim.players[allyIndex].invulnTicks = 0
  desertSim.tickCount = HeatExposureIntervalTicks - 1
  desertSim.step([InputState(), InputState()])
  doAssert desertSim.players[allyIndex].lives == 2,
    "desert heat should resume once tank guard drops"

  var swampSim = initPartyProgressorForTest()
  swampSim.clearTerrain()
  swampSim.mobs.setLen(0)
  swampSim.pickups.setLen(0)
  swampSim.landmarks.setLen(0)
  swampSim.fillGround(GroundMud, BiomeSwamp)

  let
    swampTank = swampSim.addPlayer("tank")
    swampX = firstTileForBiome(BiomeSwamp) * WorldTileSize
    swampY = (WorldHeightTiles div 2) * WorldTileSize
  swampSim.players[swampTank].applyRole(RoleTank)
  swampSim.players[swampTank].x = swampX
  swampSim.players[swampTank].y = swampY
  swampSim.players[swampTank].bounds =
    swampSim.playerBoundsFor(swampSim.players[swampTank])
  swampSim.players[swampTank].guardTicks = TankGuardTicks

  doAssert swampSim.playerProtectedByTankGuard(swampTank),
    "tank guard should also protect the tank holding formation"
  doAssert swampSim.survivalPressureKind(swampTank) == SurvivalSafe
  doAssert swampSim.playerBiomeTacticKind(swampTank) == BiomeTacticGuard
  swampSim.tickCount = SwampMireIntervalTicks - 1
  swampSim.step([InputState()])
  doAssert swampSim.players[swampTank].slowTicks == 0,
    "tank guard should block swamp mire slow pressure while active"

  swampSim.players[swampTank].guardTicks = 0
  doAssert swampSim.survivalPressureKind(swampTank) == SurvivalMire
  swampSim.tickCount = SwampMireIntervalTicks - 1
  swampSim.step([InputState()])
  doAssert swampSim.players[swampTank].slowTicks >= SwampMireTicks - 1,
    "swamp mire should resume once tank guard drops"

proc testFogBiomeDisorientationRequiresGroupOrLantern() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundCave, BiomeCave)

  let playerIndex = sim.addPlayer("solo")
  sim.players[playerIndex].x = firstTileForBiome(BiomeCave) * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.tickCount = FogDisorientationIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].slowTicks >= FogDisorientationTicks - 1,
    "cave fog should slow isolated unsheltered players"

  sim.players[playerIndex].slowTicks = 0
  let allyIndex = sim.addPlayer("ally")
  sim.players[allyIndex].x = sim.players[playerIndex].x + WorldTileSize
  sim.players[allyIndex].y = sim.players[playerIndex].y
  sim.players[allyIndex].bounds = sim.playerBoundsFor(sim.players[allyIndex])
  sim.tickCount = FogDisorientationIntervalTicks - 1
  sim.step([InputState(), InputState()])
  doAssert sim.players[playerIndex].slowTicks == 0,
    "nearby allies should keep cave fog pressure from disorienting players"

  sim.players[playerIndex].slowTicks = 0
  sim.players[allyIndex].x += IsolationThreatRadius + WorldTileSize
  sim.players[allyIndex].bounds = sim.playerBoundsFor(sim.players[allyIndex])
  sim.landmarks.add(Landmark(
    tx: sim.players[playerIndex].x div WorldTileSize,
    ty: sim.players[playerIndex].y div WorldTileSize,
    kind: LandmarkWaystation,
    hp: 1,
    done: true
  ))
  doAssert sim.playerNearExpeditionShelter(playerIndex),
    "completed cave lantern waystations should count as fog shelters"
  sim.tickCount = FogDisorientationIntervalTicks - 1
  sim.step([InputState(), InputState()])
  doAssert sim.players[playerIndex].slowTicks == 0,
    "cave lantern shelters should block fog disorientation"

  var ruinsSim = initPartyProgressorForTest()
  ruinsSim.clearTerrain()
  ruinsSim.mobs.setLen(0)
  ruinsSim.pickups.setLen(0)
  ruinsSim.landmarks.setLen(0)
  ruinsSim.fillGround(GroundRuins, BiomeRuins)
  let ruinsPlayer = ruinsSim.addPlayer("ruins")
  ruinsSim.players[ruinsPlayer].x = firstTileForBiome(BiomeRuins) * WorldTileSize
  ruinsSim.players[ruinsPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  ruinsSim.players[ruinsPlayer].bounds =
    ruinsSim.playerBoundsFor(ruinsSim.players[ruinsPlayer])
  ruinsSim.tickCount = FogDisorientationIntervalTicks - 1
  ruinsSim.step([InputState()])
  doAssert ruinsSim.players[ruinsPlayer].slowTicks >=
    FogDisorientationTicks - 1,
    "ruin fog should also disorient isolated unsheltered players"

proc testCarriedGoldLightsCaveAndRuins() =
  var sim = initPartyProgressorForTest()
  sim.clearTerrain()
  sim.mobs.setLen(0)
  sim.pickups.setLen(0)
  sim.landmarks.setLen(0)
  sim.fillGround(GroundCave, BiomeCave)

  let playerIndex = sim.addPlayer("light")
  sim.players[playerIndex].x = firstTileForBiome(BiomeCave) * WorldTileSize
  sim.players[playerIndex].y = (WorldHeightTiles div 2) * WorldTileSize
  sim.players[playerIndex].bounds =
    sim.playerBoundsFor(sim.players[playerIndex])
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = CarryGold

  doAssert sim.playerHasCaveLight(playerIndex),
    "carried gold should act as a light focus in cave biomes"
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalSafe,
    "carried gold light should clear visible cave fog pressure"
  doAssert sim.playerBiomeTacticKind(playerIndex) == BiomeTacticLight
  sim.tickCount = FogDisorientationIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].slowTicks == 0,
    "carried gold light should block cave fog disorientation"

  var state: PlayerViewerState
  let parsed = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    initPlayerViewerState(),
    state
  ).parseSpriteProtocolPacket()
  let labels = parsed.objectSpriteLabels()
  doAssert "status light" in labels
  doAssert "status fog" notin labels
  doAssert parsed.sprites.values.toSeq.anyIt(it.label.contains("OK SAFE LIGHT")),
    "HUD status text should make carried light readable"

  sim.players[playerIndex].slowTicks = 0
  sim.players[playerIndex].carrying = false
  sim.players[playerIndex].carriedItem = CarryNone
  doAssert not sim.playerHasCaveLight(playerIndex)
  doAssert sim.survivalPressureKind(playerIndex) == SurvivalFog
  doAssert sim.playerBiomeTacticKind(playerIndex) == BiomeTacticNone
  sim.tickCount = FogDisorientationIntervalTicks - 1
  sim.step([InputState()])
  doAssert sim.players[playerIndex].slowTicks >= FogDisorientationTicks - 1,
    "cave fog should resume when the player is no longer carrying light"

  var ruinsSim = initPartyProgressorForTest()
  ruinsSim.clearTerrain()
  ruinsSim.mobs.setLen(0)
  ruinsSim.pickups.setLen(0)
  ruinsSim.landmarks.setLen(0)
  ruinsSim.fillGround(GroundRuins, BiomeRuins)
  let ruinsPlayer = ruinsSim.addPlayer("ruin-light")
  ruinsSim.players[ruinsPlayer].x =
    firstTileForBiome(BiomeRuins) * WorldTileSize
  ruinsSim.players[ruinsPlayer].y = (WorldHeightTiles div 2) * WorldTileSize
  ruinsSim.players[ruinsPlayer].bounds =
    ruinsSim.playerBoundsFor(ruinsSim.players[ruinsPlayer])
  ruinsSim.players[ruinsPlayer].carrying = true
  ruinsSim.players[ruinsPlayer].carriedItem = CarryGold
  doAssert ruinsSim.playerHasCaveLight(ruinsPlayer),
    "carried gold light should also work in ruins"
  doAssert ruinsSim.survivalPressureKind(ruinsPlayer) == SurvivalSafe
  doAssert ruinsSim.playerBiomeTacticKind(ruinsPlayer) == BiomeTacticLight

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
testProceduralExpeditionRepeatsBiomeSegments()
testProceduralLandformsAndVisibilityShadow()
testRiverCrossingAmbushesTriggerOnce()
testEarlyBiomeForageAndRallyTactics()
testSpritePlayerViewportAndBiomeBackground()
testSpriteProtocolWeatherOverlays()
testSpriteProtocolShowsSurvivalPressureAffordances()
testRenderedPlayerObservationHasBiomeBackedPixels()
testSpriteProtocolPacketMatchesReferenceParsers()
testSpriteProtocolMatchesCurrentSharedClientContract()
testGlobalSpriteViewFollowsPartyProgress()
testCarriedInventoryTilesAcrossBottomOfPlayerView()
testCarriedFoodStacksAndShowsCount()
testRoleSpecialAbilitiesShowColoredSpriteEffects()
testGeneratedMonsterSpritesStayRichlyColored()
testExpeditionObjectiveHudGuidesNextStep()
testBiomeMonsterSpeciesBreadth()
testMonsterTacticalHooksAndStatuses()
testDefeatedBiomeMonstersDropExpeditionSupplies()
testExpandedMonsterFamiliesAndArmorDrops()
testArmorPickupEquipsAndShowsHud()
testSpriteProtocolShowsStatusAndObjectiveAffordances()
testSpriteProtocolShowsObjectiveProgressPrompts()
testChatPingsShowCompactStatusBadges()
testSpriteProtocolShowsMonsterThreatTelegraphs()
testTerrainMovementModifiersAffectPlayers()
testElevationSlowsHighGround()
testElevationCombatAdvantageAndBadges()
testResourceHarvestAndCampActivation()
testCarriedFoodCanBeEatenForRecovery()
testCarriedFoodCanBeFedToNearbyTeammate()
testCarriedWoodCanPlankSwampCrossings()
testCarriedStoneCanCutElevationSteps()
testCampFortificationConsumesResourcesAndDefendsStagingArea()
testCampProvisioningConsumesFoodAndImprovesRecovery()
testCarriedSuppliesUpgradeActivatedCamps()
testRoleSpecializedCampsCreateDistinctStagingBenefits()
testBeaconAndBossScoring()
testFinalGateRitualAcceleratesWithPartyRoles()
testFinalGateObjectiveOverridesRuinsCleanup()
testShrineSideObjectiveScoringAndSustain()
testRescueSideObjectiveRequiresHoldAndRewardsParty()
testRescueGuideFollowsAndThanksAtCamp()
testHealerCompletesRescueEventsFaster()
testCooperativeObjectiveHoldsStackPartyEffort()
testMonsterLairAttackRewardsAndPacifiesThreats()
testBiomeWaystationsCreateRoleDetoursAndShelters()
testDpsBeamSpecialDamagesMobsInFacingLine()
testPartyFocusRewardsMixedRoleAttacksAndShowsBadge()
testGateTitanRaidWindowRewardsFormationAndFocus()
testMixedRoleFormationRechargesPowersAndShowsBadge()
testHealerTriageAndHelpAffordance()
testFoodAndColdSurvivalPressure()
testLateRunExhaustionUsesRationsAndShowsStatus()
testSnowSharedWarmthClearsColdPressure()
testDesertHeatSurvivalPressureAndOasisShelter()
testDesertCactusShadeClearsHeatPressure()
testSwampMireSurvivalPressureAndBridgeShelter()
testTankGuardBlocksBiomePressure()
testFogBiomeDisorientationRequiresGroupOrLantern()
testCarriedGoldLightsCaveAndRuins()
testCampShelterAndRecoveryInfrastructure()
echo "All tests passed"

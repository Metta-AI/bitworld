import
  std/os,
  ../common/protocol,
  ../common/server,
  ../big_adventure/global,
  ../big_adventure/sim

const
  RootDir = currentSourcePath.parentDir.parentDir
  ScorePanelDigitSpriteBaseForTest = 18300
  ScorePanelPipSpriteBaseForTest = 18400
  ScorePanelNameSpriteBaseForTest = 18500
  ScorePanelPipObjectBaseForTest = 14000
  ScorePanelDigitObjectBaseForTest = 15000
  ScorePanelNameObjectBaseForTest = 17000
  ScorePanelMaxScoreCharsForTest = 16

type
  SpritePacketObject = object
    id: int
    x: int
    y: int
    spriteId: int

proc readU16(packet: openArray[uint8], offset: int): int =
  ## Reads one little endian unsigned 16 bit value from a packet.
  int(uint16(packet[offset]) or (uint16(packet[offset + 1]) shl 8))

proc readU32(packet: openArray[uint8], offset: int): int =
  ## Reads one little endian unsigned 32 bit value from a packet.
  int(uint32(packet[offset]) or
    (uint32(packet[offset + 1]) shl 8) or
    (uint32(packet[offset + 2]) shl 16) or
    (uint32(packet[offset + 3]) shl 24))

proc spritePacketSpriteIds(packet: openArray[uint8]): seq[int] =
  ## Returns all sprite ids defined in one sprite protocol packet.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01'u8:
      doAssert offset + 10 <= packet.len
      result.add packet.readU16(offset)
      let compressedLen = packet.readU32(offset + 6)
      offset += 10 + compressedLen
      doAssert offset + 2 <= packet.len
      let labelLen = packet.readU16(offset)
      offset += 2 + labelLen
    of 0x02'u8:
      doAssert offset + 11 <= packet.len
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
      doAssert false, "unknown sprite protocol message"

proc spritePacketObjects(packet: openArray[uint8]): seq[SpritePacketObject] =
  ## Returns all objects defined in one sprite protocol packet.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01'u8:
      doAssert offset + 10 <= packet.len
      let compressedLen = packet.readU32(offset + 6)
      offset += 10 + compressedLen
      doAssert offset + 2 <= packet.len
      let labelLen = packet.readU16(offset)
      offset += 2 + labelLen
    of 0x02'u8:
      doAssert offset + 11 <= packet.len
      result.add SpritePacketObject(
        id: packet.readU16(offset),
        x: packet.readU16(offset + 2),
        y: packet.readU16(offset + 4),
        spriteId: packet.readU16(offset + 9)
      )
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
      doAssert false, "unknown sprite protocol message"

proc spritePacketObjectIds(packet: openArray[uint8]): seq[int] =
  ## Returns all object ids defined in one sprite protocol packet.
  for item in packet.spritePacketObjects():
    result.add item.id

proc findObject(
  objects: openArray[SpritePacketObject],
  objectId: int
): SpritePacketObject =
  ## Returns one object by id or fails the test.
  for item in objects:
    if item.id == objectId:
      return item
  doAssert false, "missing sprite protocol object"

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

proc testPlayerSpeedIsSlower() =
  ## Checks that player top speed is 25 percent slower.
  doAssert MaxSpeed == 264, "player max speed should be 25 percent slower"

proc testGlobalScorePanelRenders() =
  ## Checks that the global view includes the coin score panel.
  var sim = initBigAdventureForTest()
  let
    red = sim.addPlayer("red")
    blue = sim.addPlayer("blue")
    redId = sim.players[red].id
    blueId = sim.players[blue].id
  sim.players[red].coins = 4
  sim.players[blue].coins = 12

  var nextState: GlobalViewerState
  let packet = sim.buildSpriteProtocolUpdates(
    initGlobalViewerState(),
    nextState
  )
  let
    objects = packet.spritePacketObjects()
    objectIds = packet.spritePacketObjectIds()
    spriteIds = packet.spritePacketSpriteIds()
    redNameObject = ScorePanelNameObjectBaseForTest + redId
    blueNameObject = ScorePanelNameObjectBaseForTest + blueId
    bluePipObject = ScorePanelPipObjectBaseForTest + blueId
    blueFirstDigit = ScorePanelDigitObjectBaseForTest +
      blueId * ScorePanelMaxScoreCharsForTest
    blueSecondDigit = blueFirstDigit + 1
  doAssert redNameObject in objectIds,
    "global view should include the red name object"
  doAssert blueNameObject in objectIds,
    "global view should include the blue name object"
  doAssert bluePipObject in objectIds,
    "global view should include the blue pip object"
  doAssert blueFirstDigit in objectIds,
    "global view should include the first blue score digit"
  doAssert blueSecondDigit in objectIds,
    "global view should include the second blue score digit"
  doAssert objects.findObject(blueNameObject).y <
    objects.findObject(redNameObject).y,
    "highest score should be first in the score panel"
  doAssert ScorePanelDigitSpriteBaseForTest + 1 in spriteIds,
    "global view should define the score digit sprite"
  doAssert ScorePanelPipSpriteBaseForTest + blueId in spriteIds,
    "global view should define the blue score pip sprite"
  doAssert ScorePanelNameSpriteBaseForTest + redId in spriteIds,
    "global view should define the red score name sprite"

  var cachedState: GlobalViewerState
  let cachedPacket = sim.buildSpriteProtocolUpdates(nextState, cachedState)
  let cachedSpriteIds = cachedPacket.spritePacketSpriteIds()
  doAssert ScorePanelDigitSpriteBaseForTest + 1 notin cachedSpriteIds,
    "unchanged score digit sprites should not be sent again"
  doAssert ScorePanelPipSpriteBaseForTest + blueId notin cachedSpriteIds,
    "unchanged score pip sprites should not be sent again"
  doAssert ScorePanelNameSpriteBaseForTest + redId notin cachedSpriteIds,
    "unchanged score name sprites should not be sent again"

testPlayerDropsCarriedCoinsOnDeath()
testMobsAvoidPlayerStart()
testMobSightRadiusIsSmaller()
testPlayerSpeedIsSlower()
testGlobalScorePanelRenders()
echo "All tests passed"

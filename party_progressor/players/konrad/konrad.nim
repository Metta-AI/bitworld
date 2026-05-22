import
  std/[heapqueue, options, os, parseopt, random, strutils, times],
  supersnappy, whisky,
  protocol, ../../sim

const
  PlayerDefaultPort = 2000
  PlayerSpriteSlots = 64
  SelectedPlayerSpriteSlots = 64
  SwooshSpriteSlots = 8
  TerrainSpriteSlots = 16
  LandmarkSpriteSlots = 11
  PlayerHudObjectId = 7000
  StatusHudObjectId = PlayerHudObjectId + 2
  PlayerHealthObjectBase = 10000
  CarryObjectBase = 12000
  StatusBadgeObjectBase = 13000
  StatusBadgeSlots = 7
  LowHealthPercent = 50
  MaxDrainMessages = 256
  PathCellSize = 8
  PathGridWidth = WorldWidthPixels div PathCellSize
  PathGridHeight = WorldHeightPixels div PathCellSize
  MoveDeadband = 5
  GoalArrivalRadius = 18
  AttackReach = 46
  AttackAlignSlack = 22
  AttackCooldownTicks = 7
  ActivationStallDistance = 18
  CampActivationStallTicks = 48
  CampResourceSearchTicks = TargetFps * 6
  ShelterReturnRadius = WorldTileSize * 4
  ObstaclePad = 8
  PathLookaheadCells = 4
  RoleChoiceFallbackTicks = 180
  StuckFrameThreshold = 14
  JiggleDuration = 12
  SkipTargetTicks = 72
  ExploreStep = 17
  RoleLabelToGearOffset = WorldTileSize div 2
  OpportunisticLootRadius = WorldTileSize * 3
  OpportunisticResourceRadius = WorldTileSize * 4
  OpportunisticObjectiveRadius = WorldTileSize * 5
  BacktrackLootSlack = WorldTileSize
  FrontierLootBacktrackSlack = WorldTileSize * 6
  FrontierCampBacktrackSlack = WorldTileSize * 6
  ExploreDetourResetTicks = TargetFps * 3
  ExploreDetourOffsets = [0, 8, -8, 12, -12, 4, -4, 16, -16, 2, -2, 6, -6]
  ExpeditionLaneMinPathTy =
    ((WorldHeightTiles div 2 - LaneHalfHeightTiles) * WorldTileSize) div
      PathCellSize
  ExpeditionLaneMaxPathTy =
    (((WorldHeightTiles div 2 + LaneHalfHeightTiles + 1) * WorldTileSize) - 1) div
      PathCellSize
  ExpeditionLaneMinY = ExpeditionLaneMinPathTy * PathCellSize + PathCellSize div 2
  ExpeditionLaneMaxY = ExpeditionLaneMaxPathTy * PathCellSize + PathCellSize div 2
  ExpeditionLaneRecoverySlack = WorldTileSize div 2
  ExpeditionLaneRecoveryLead = WorldTileSize * 3
  MoveMask = ButtonUp or ButtonDown or ButtonLeft or ButtonRight

type
  SpriteKind = enum
    SpriteUnknown
    SpriteMap
    SpritePlayer
    SpriteMob
    SpriteTroll
    SpriteBoss
    SpriteCoin
    SpriteHeart
    SpriteSwoosh
    SpriteTerrain
    SpriteHud
    SpriteText

  TargetKind = enum
    TargetExplore
    TargetRegroup
    TargetTankRole
    TargetDpsRole
    TargetHealerRole
    TargetCoin
    TargetHeart
    TargetWood
    TargetFood
    TargetStone
    TargetGold
    TargetCamp
    TargetShelter
    TargetRelic
    TargetGate
    TargetShrine
    TargetRescue
    TargetLair
    TargetWaystation
    TargetMob
    TargetTroll
    TargetBoss

  CarryKind = enum
    CarryNone
    CarryWood
    CarryFood
    CarryStone
    CarryGold

  RolePreference = enum
    PreferAnyRole
    PreferTankRole
    PreferDpsRole
    PreferHealerRole

  SpriteInfo = object
    defined: bool
    width: int
    height: int
    label: string
    kind: SpriteKind
    pixels: seq[uint8]

  ObjectState = object
    present: bool
    x: int
    y: int
    z: int
    layer: int
    spriteId: int

  Target = object
    found: bool
    kind: TargetKind
    objectId: int
    x: int
    y: int
    label: string

  PathNode = object
    priority: int
    index: int

  PathStep = object
    found: bool
    nextTx: int
    nextTy: int

  Bot = object
    sprites: seq[SpriteInfo]
    objects: seq[ObjectState]
    rng: Rand
    cameraX: int
    cameraY: int
    viewportWidth: int
    viewportHeight: int
    playerWorldX: int
    playerWorldY: int
    playerCenterWorldX: int
    playerCenterWorldY: int
    frontierX: int
    previousPlayerX: int
    previousPlayerY: int
    havePlayerSample: bool
    selfObjectId: int
    frameTick: int
    exploreIndex: int
    hasExploreGoal: bool
    exploreX: int
    exploreY: int
    exploreDetourIndex: int
    lastExploreStuckTick: int
    stuckFrames: int
    jiggleTicks: int
    jiggleMask: uint8
    attackCooldown: int
    currentTargetId: int
    currentTargetKind: TargetKind
    currentTargetX: int
    currentTargetY: int
    currentTargetDistance: int
    currentTargetLabel: string
    targetCloseTicks: int
    skipTargetId: int
    skipTicks: int
    coinCount: int
    heartCount: int
    killCount: int
    lowHealth: bool
    needsRegroup: bool
    carriedItem: CarryKind
    objectiveHint: string
    sharedWood: int
    sharedStone: int
    needWood: int
    needStone: int
    campResourceSearchTicks: int
    needsRole: bool
    hasRole: bool
    roleLabel: string
    abilityReady: bool
    abilityLabel: string
    preferredRole: RolePreference
    intent: string
    lastMask: uint8
    nextChatTick: int
    lastChat: string

proc `<`(a, b: PathNode): bool =
  ## Orders path nodes by priority for the heap.
  if a.priority == b.priority:
    return a.index < b.index
  a.priority < b.priority

proc gridIndex(tx, ty: int): int =
  ## Returns the flat path grid index.
  ty * PathGridWidth + tx

proc inGrid(tx, ty: int): bool =
  ## Returns true when a path cell coordinate is inside the world.
  tx >= 0 and ty >= 0 and tx < PathGridWidth and ty < PathGridHeight

proc distanceSquared(ax, ay, bx, by: int): int =
  ## Returns squared distance between two points.
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc manhattan(ax, ay, bx, by: int): int =
  ## Returns Manhattan distance between two points.
  abs(ax - bx) + abs(ay - by)

proc tileCenterX(tx: int): int =
  ## Returns the world X coordinate for the center of a path cell.
  tx * PathCellSize + PathCellSize div 2

proc tileCenterY(ty: int): int =
  ## Returns the world Y coordinate for the center of a path cell.
  ty * PathCellSize + PathCellSize div 2

proc clampTileX(x: int): int =
  ## Converts a world X coordinate into a clamped path cell coordinate.
  clamp(x div PathCellSize, 0, PathGridWidth - 1)

proc clampTileY(y: int): int =
  ## Converts a world Y coordinate into a clamped path cell coordinate.
  clamp(y div PathCellSize, 0, PathGridHeight - 1)

proc classifySprite(spriteId: int, label: string): SpriteKind =
  ## Classifies a sprite from its id and optional protocol label.
  let lower = label.toLowerAscii()
  if spriteId == MapSpriteId or lower == "map":
    SpriteMap
  elif spriteId >= PlayerSpriteBase and
      spriteId < PlayerSpriteBase + PlayerSpriteSlots:
    SpritePlayer
  elif spriteId >= SelectedPlayerSpriteBase and
      spriteId < SelectedPlayerSpriteBase + SelectedPlayerSpriteSlots:
    SpritePlayer
  elif spriteId >= MobSpeciesSpriteBase and
      spriteId < MobSpeciesSpriteBase + MobSpeciesSpriteSlots:
    SpriteMob
  elif spriteId == MobSpriteId or lower.startsWith("ghost") or
      lower.startsWith("wolf") or lower.startsWith("scorpion") or
      lower.startsWith("cave bat"):
    SpriteMob
  elif spriteId == TrollSpriteId or lower.startsWith("troll") or
      lower.startsWith("goblin") or lower.startsWith("swamp slime") or
      lower.startsWith("ruin wraith"):
    SpriteTroll
  elif spriteId == BossSpriteId or lower.startsWith("pigman") or
      lower.startsWith("bear") or lower.startsWith("yeti"):
    SpriteBoss
  elif spriteId == CoinSpriteId or lower == "coin" or
      lower in ["camp", "beacon", "final gate", "shrine", "rescue", "lair",
        "waystation", "shelter", "wood", "food", "stone", "gold"]:
    SpriteCoin
  elif spriteId == HeartSpriteId or lower == "heart":
    SpriteHeart
  elif spriteId >= SwooshSpriteBase and
      spriteId < SwooshSpriteBase + SwooshSpriteSlots:
    SpriteSwoosh
  elif spriteId >= TerrainSpriteBase and
      spriteId < TerrainSpriteBase + TerrainSpriteSlots:
    SpriteTerrain
  elif spriteId >= LandmarkSpriteBase and
      spriteId < LandmarkSpriteBase + LandmarkSpriteSlots:
    SpriteCoin
  elif spriteId == PlayerHudSpriteId:
    SpriteHud
  elif label.len > 0:
    SpriteText
  else:
    SpriteUnknown

proc targetKindForSprite(kind: SpriteKind): TargetKind =
  ## Converts a monster sprite kind into a target kind.
  case kind
  of SpriteTroll:
    TargetTroll
  of SpriteBoss:
    TargetBoss
  else:
    TargetMob

proc targetKindForSprite(sprite: SpriteInfo): TargetKind =
  ## Converts one visible sprite into a semantic bot target.
  case sprite.label.toLowerAscii()
  of "wood":
    TargetWood
  of "food":
    TargetFood
  of "stone":
    TargetStone
  of "gold":
    TargetGold
  of "camp":
    TargetCamp
  of "shelter":
    TargetShelter
  of "beacon":
    TargetRelic
  of "final gate":
    TargetGate
  of "shrine":
    TargetShrine
  of "rescue":
    TargetRescue
  of "lair":
    TargetLair
  of "waystation":
    TargetWaystation
  else:
    case sprite.kind
    of SpriteHeart:
      TargetHeart
    of SpriteCoin:
      TargetCoin
    else:
      sprite.kind.targetKindForSprite()

proc roleTargetKindForLabel(label: string): TargetKind =
  ## Converts visible role-choice text into a bot target.
  let lower = label.toLowerAscii()
  if lower.startsWith("role tank"):
    TargetTankRole
  elif lower.startsWith("role dps"):
    TargetDpsRole
  elif lower.startsWith("role heal"):
    TargetHealerRole
  else:
    TargetExplore

proc targetKindForPreference(preference: RolePreference): TargetKind =
  ## Converts one preferred party role into its target kind.
  case preference
  of PreferTankRole:
    TargetTankRole
  of PreferDpsRole:
    TargetDpsRole
  of PreferHealerRole:
    TargetHealerRole
  else:
    TargetExplore

proc rolePreferenceForIndex(index: int): RolePreference =
  ## Rotates unnamed bots through a balanced tank, DPS, healer party.
  case ((index mod 3) + 3) mod 3
  of 0:
    PreferTankRole
  of 1:
    PreferDpsRole
  else:
    PreferHealerRole

proc rolePreferenceFromName(name: string): RolePreference =
  ## Reads explicit role intent from local bot names.
  let lower = name.toLowerAscii()
  if lower.contains("tank") or lower.contains("guard"):
    PreferTankRole
  elif lower.contains("dps") or lower.contains("cleave") or
      lower.contains("damage"):
    PreferDpsRole
  elif lower.contains("heal") or lower.contains("pulse") or
      lower.contains("support"):
    PreferHealerRole
  else:
    PreferAnyRole

proc rolePreferenceFromSlot(slot: string): RolePreference =
  ## Reads runner slot fallback into a stable party role.
  if slot.len == 0:
    return PreferAnyRole
  try:
    return rolePreferenceForIndex(parseInt(slot))
  except ValueError:
    result = PreferAnyRole

proc rolePreferenceFor(name, slot: string): RolePreference =
  ## Chooses a role preference from explicit name, then runner slot.
  result = rolePreferenceFromName(name)
  if result == PreferAnyRole:
    result = rolePreferenceFromSlot(slot)

proc targetLabel(kind: TargetKind): string =
  ## Returns a short readable label for one target kind.
  case kind
  of TargetExplore:
    "push"
  of TargetRegroup:
    "regroup"
  of TargetTankRole:
    "tank role"
  of TargetDpsRole:
    "dps role"
  of TargetHealerRole:
    "healer role"
  of TargetCoin:
    "coin"
  of TargetHeart:
    "heart"
  of TargetWood:
    "wood"
  of TargetFood:
    "food"
  of TargetStone:
    "stone"
  of TargetGold:
    "gold"
  of TargetCamp:
    "camp"
  of TargetShelter:
    "shelter"
  of TargetRelic:
    "relic"
  of TargetGate:
    "gate"
  of TargetShrine:
    "shrine"
  of TargetRescue:
    "rescue"
  of TargetLair:
    "lair"
  of TargetWaystation:
    "waypoint"
  of TargetMob:
    "hunt"
  of TargetTroll:
    "fight"
  of TargetBoss:
    "boss"

proc isAttackTarget(kind: TargetKind): bool =
  kind in {
    TargetWood,
    TargetFood,
    TargetStone,
    TargetGold,
    TargetLair,
    TargetMob,
    TargetTroll,
    TargetBoss
  }

proc ensureSprite(bot: var Bot, spriteId: int) =
  ## Ensures the sprite table can hold a sprite id.
  if spriteId >= bot.sprites.len:
    bot.sprites.setLen(spriteId + 1)

proc ensureObject(bot: var Bot, objectId: int) =
  ## Ensures the object table can hold an object id.
  if objectId >= bot.objects.len:
    bot.objects.setLen(objectId + 1)

proc spriteInfo(bot: Bot, spriteId: int): SpriteInfo =
  ## Returns sprite metadata or an empty sprite info.
  if spriteId >= 0 and spriteId < bot.sprites.len:
    return bot.sprites[spriteId]
  SpriteInfo()

proc readU16(blob: string, offset: int): int =
  ## Reads one little endian unsigned 16 bit value.
  int(uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8))

proc readI16(blob: string, offset: int): int =
  ## Reads one little endian signed 16 bit value.
  let value = uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc readU32(blob: string, offset: int): int =
  ## Reads one little endian unsigned 32 bit value.
  int(uint32(blob[offset].uint8) or
    (uint32(blob[offset + 1].uint8) shl 8) or
    (uint32(blob[offset + 2].uint8) shl 16) or
    (uint32(blob[offset + 3].uint8) shl 24))

proc applySpritePacket(bot: var Bot, packet: string): bool =
  ## Applies one or more server sprite protocol messages.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset].uint8
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        return false
      let
        spriteId = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10
      if compressedLen < 0 or offset + compressedLen + 2 > packet.len:
        return false
      let compressed =
        if compressedLen > 0:
          packet.substr(offset, offset + compressedLen - 1)
        else:
          ""
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len:
        return false
      let label =
        if labelLen > 0:
          packet.substr(offset, offset + labelLen - 1)
        else:
          ""
      offset += labelLen
      let rawPixels = supersnappy.uncompress(compressed)
      var pixels = newSeq[uint8](rawPixels.len)
      for i, ch in rawPixels:
        pixels[i] = ch.uint8
      if pixels.len != width * height * 4:
        pixels.setLen(0)
      bot.ensureSprite(spriteId)
      bot.sprites[spriteId] = SpriteInfo(
        defined: true,
        width: width,
        height: height,
        label: label,
        kind: classifySprite(spriteId, label),
        pixels: pixels
      )
    of 0x02:
      if offset + 11 > packet.len:
        return false
      let
        objectId = packet.readU16(offset)
        x = packet.readI16(offset + 2)
        y = packet.readI16(offset + 4)
        z = packet.readI16(offset + 6)
        layer = int(packet[offset + 8].uint8)
        spriteId = packet.readU16(offset + 9)
      offset += 11
      bot.ensureObject(objectId)
      bot.objects[objectId] = ObjectState(
        present: true,
        x: x,
        y: y,
        z: z,
        layer: layer,
        spriteId: spriteId
      )
    of 0x03:
      if offset + 2 > packet.len:
        return false
      let objectId = packet.readU16(offset)
      offset += 2
      if objectId >= 0 and objectId < bot.objects.len:
        bot.objects[objectId].present = false
    of 0x04:
      for item in bot.objects.mitems:
        item.present = false
    of 0x05:
      if offset + 5 > packet.len:
        return false
      let
        layer = int(packet[offset].uint8)
        width = packet.readU16(offset + 1)
        height = packet.readU16(offset + 3)
      if layer == MapLayerId:
        bot.viewportWidth = width
        bot.viewportHeight = height
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return false
      offset += 3
    else:
      return false
  true

proc updateCamera(bot: var Bot) =
  ## Updates the world camera from the map object.
  if MapObjectId < bot.objects.len and bot.objects[MapObjectId].present:
    bot.cameraX = -bot.objects[MapObjectId].x
    bot.cameraY = -bot.objects[MapObjectId].y

proc visibleBounds(sprite: SpriteInfo): SpriteBounds =
  ## Measures the visible bounds of one decoded RGBA sprite.
  if sprite.width <= 0 or sprite.height <= 0 or
      sprite.pixels.len != sprite.width * sprite.height * 4:
    return SpriteBounds(x: 0, y: 0, w: sprite.width, h: sprite.height)

  var
    minX = sprite.width
    minY = sprite.height
    maxX = -1
    maxY = -1
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let offset = (y * sprite.width + x) * 4 + 3
      if sprite.pixels[offset] == 0'u8:
        continue
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
  if maxX < minX or maxY < minY:
    return SpriteBounds()
  SpriteBounds(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1)

proc lowerCenterBounds(bounds: SpriteBounds): SpriteBounds =
  ## Returns the lower trunk-like part of a visible sprite.
  if bounds.w <= 0 or bounds.h <= 0:
    return bounds
  let
    width = max(6, bounds.w div 3)
    height = max(6, bounds.h div 4)
  SpriteBounds(
    x: bounds.x + (bounds.w - width) div 2,
    y: bounds.y + bounds.h - height,
    w: width,
    h: height
  )

proc terrainBounds(sprite: SpriteInfo): SpriteBounds =
  ## Returns a collision-like terrain bound from true sprite pixels.
  let bounds = sprite.visibleBounds()
  let lower = sprite.label.toLowerAscii()
  if lower == "terraintree" or lower == "terrainevergreen":
    return bounds.lowerCenterBounds()
  bounds

proc objectVisibleCenter(
  objectState: ObjectState,
  sprite: SpriteInfo
): tuple[x: int, y: int] =
  ## Returns the visible center of one object in screen coordinates.
  let bounds = sprite.visibleBounds()
  (
    x: objectState.x + bounds.x + bounds.w div 2,
    y: objectState.y + bounds.y + bounds.h div 2
  )

proc objectFootCenter(
  objectState: ObjectState,
  sprite: SpriteInfo
): tuple[x: int, y: int] =
  ## Returns the foot box center of one player in screen coordinates.
  let bounds = sprite.visibleBounds()
  (
    x: objectState.x + bounds.x + bounds.w div 2,
    y: objectState.y + bounds.y + bounds.h - PlayerFootSize div 2
  )

proc updatePlayerPosition(bot: var Bot) =
  ## Tracks the local player feet as the object nearest screen center.
  var
    bestDistance = high(int)
    bestSelected = false
    viewportCenterX = bot.viewportWidth div 2
    viewportCenterY = bot.viewportHeight div 2
    bestX = bot.cameraX + viewportCenterX
    bestY = bot.cameraY + viewportCenterY
    bestCenterX = bestX
    bestCenterY = bestY
    bestId = -1
  for objectId in 0 ..< bot.objects.len:
    let objectState = bot.objects[objectId]
    if not objectState.present:
      continue
    if objectId < PlayerObjectBase or objectId >= MobObjectBase:
      continue
    let sprite = bot.spriteInfo(objectState.spriteId)
    if sprite.kind != SpritePlayer:
      continue
    let
      selected = sprite.label.toLowerAscii().startsWith("selected player")
      screenCenter = objectState.objectVisibleCenter(sprite)
      screenFeet = objectState.objectFootCenter(sprite)
      distance = distanceSquared(
        screenCenter.x,
        screenCenter.y,
        viewportCenterX,
        viewportCenterY
      )
    if (selected and not bestSelected) or
        (selected == bestSelected and distance < bestDistance):
      bestSelected = selected
      bestDistance = distance
      bestX = bot.cameraX + screenFeet.x
      bestY = bot.cameraY + screenFeet.y
      bestCenterX = bot.cameraX + screenCenter.x
      bestCenterY = bot.cameraY + screenCenter.y
      bestId = objectId
  bot.playerWorldX = bestX
  bot.playerWorldY = bestY
  bot.playerCenterWorldX = bestCenterX
  bot.playerCenterWorldY = bestCenterY
  bot.selfObjectId = bestId
  bot.frontierX = max(bot.frontierX, bestX)

proc parseHealthLabel(label: string): tuple[found: bool, current: int, maximum: int] =
  ## Parses compact health sprite labels such as "health 2/9".
  let lower = label.toLowerAscii()
  if not lower.startsWith("health "):
    return
  let parts = lower.substr("health ".len).split("/")
  if parts.len != 2:
    return
  try:
    let
      current = parseInt(parts[0].strip())
      maximum = parseInt(parts[1].strip())
    if maximum <= 0:
      return
    return (true, current, maximum)
  except ValueError:
    discard

proc carryKindFromLabel(label: string): CarryKind =
  ## Reads a carried resource name from HUD or carried-item sprite labels.
  let lower = label.toLowerAscii()
  if lower.contains("wood"):
    CarryWood
  elif lower.contains("food"):
    CarryFood
  elif lower.contains("stone"):
    CarryStone
  elif lower.contains("gold"):
    CarryGold
  else:
    CarryNone

proc tokenNumber(tokens: openArray[string], key: string): int =
  ## Reads compact objective tokens such as W2 or S1.
  for raw in tokens:
    let token = raw.strip()
    if not token.startsWith(key) or token.len <= key.len:
      continue
    try:
      return parseInt(token.substr(key.len))
    except ValueError:
      discard

proc hasTokenKey(tokens: openArray[string], key: string): bool =
  ## Returns true when a compact HUD token with the given prefix exists.
  for raw in tokens:
    let token = raw.strip()
    if token.startsWith(key) and token.len > key.len:
      return true

proc updateCampNeedsFromSharedResources(bot: var Bot) =
  ## Uses the HUD resource counters as the authoritative camp resource gate.
  if bot.sharedWood < 0 or bot.sharedStone < 0:
    return
  if bot.objectiveHint.startsWith("next camp") or
      bot.objectiveHint.startsWith("next build camp"):
    bot.needWood = max(bot.needWood, max(0, CampWoodCost - bot.sharedWood))
    bot.needStone = max(bot.needStone, max(0, CampStoneCost - bot.sharedStone))

proc readStatusHud(bot: var Bot, label: string) =
  ## Reads resource objective and carried item hints from the local HUD label.
  let lower = label.toLowerAscii()
  if lower.startsWith("unarmed "):
    bot.roleLabel = "unarmed"
    bot.needsRole = true
  elif lower.startsWith("tank "):
    bot.roleLabel = "tank"
    bot.hasRole = true
  elif lower.startsWith("dps "):
    bot.roleLabel = "dps"
    bot.hasRole = true
  elif lower.startsWith("healer "):
    bot.roleLabel = "healer"
    bot.hasRole = true
  if lower.contains("b choose role") or
      lower.contains("next walk into tank dps heal"):
    bot.needsRole = true
  for part in lower.split("|"):
    let section = part.strip()
    if section.startsWith("carry "):
      bot.carriedItem = section.carryKindFromLabel()
    elif section.startsWith("next "):
      bot.objectiveHint = section
      let tokens = section.splitWhitespace()
      bot.needWood = tokens.tokenNumber("w")
      bot.needStone = tokens.tokenNumber("s")
    elif section.startsWith("b "):
      bot.abilityLabel = section.substr(2).strip()
      bot.abilityReady = not section.contains(" cd")
    else:
      let tokens = section.splitWhitespace()
      if tokens.hasTokenKey("w") and tokens.hasTokenKey("s"):
        bot.sharedWood = tokens.tokenNumber("w")
        bot.sharedStone = tokens.tokenNumber("s")
  bot.updateCampNeedsFromSharedResources()

proc updateSelfAffordances(bot: var Bot) =
  ## Reads visible self health and status badges generated by the server.
  bot.lowHealth = false
  bot.needsRegroup = false
  bot.carriedItem = CarryNone
  bot.objectiveHint = ""
  bot.sharedWood = -1
  bot.sharedStone = -1
  bot.needWood = 0
  bot.needStone = 0
  bot.needsRole = false
  bot.hasRole = false
  bot.roleLabel = ""
  bot.abilityReady = false
  bot.abilityLabel = ""
  if StatusHudObjectId < bot.objects.len and bot.objects[StatusHudObjectId].present:
    let statusSprite = bot.spriteInfo(bot.objects[StatusHudObjectId].spriteId)
    bot.readStatusHud(statusSprite.label)
  if bot.selfObjectId < PlayerObjectBase:
    return
  let playerId = bot.selfObjectId - PlayerObjectBase
  let carryObjectId = CarryObjectBase + playerId
  if carryObjectId < bot.objects.len and bot.objects[carryObjectId].present:
    let carried = bot.spriteInfo(bot.objects[carryObjectId].spriteId).label.carryKindFromLabel()
    if carried != CarryNone:
      bot.carriedItem = carried
  let healthObjectId = PlayerHealthObjectBase + playerId
  if healthObjectId < bot.objects.len and bot.objects[healthObjectId].present:
    let healthSprite = bot.spriteInfo(bot.objects[healthObjectId].spriteId)
    let health = parseHealthLabel(healthSprite.label)
    if health.found and health.current * 100 <= health.maximum * LowHealthPercent:
      bot.lowHealth = true

  for badgeIndex in 0 ..< StatusBadgeSlots:
    let objectId = StatusBadgeObjectBase + playerId * StatusBadgeSlots + badgeIndex
    if objectId >= bot.objects.len or not bot.objects[objectId].present:
      continue
    let label = bot.spriteInfo(bot.objects[objectId].spriteId).label.toLowerAscii()
    case label
    of "status help":
      bot.lowHealth = true
    of "status alone":
      bot.needsRegroup = true
    else:
      discard

proc isBlocked(blocked: openArray[bool], tx, ty: int): bool =
  ## Returns true when a tile cannot be used for pathing.
  if not inGrid(tx, ty):
    return true
  blocked[gridIndex(tx, ty)]

proc resetBlocked(blocked: var seq[bool]) =
  ## Clears the blocked tile grid.
  if blocked.len != PathGridWidth * PathGridHeight:
    blocked.setLen(PathGridWidth * PathGridHeight)
  for i in 0 ..< blocked.len:
    blocked[i] = false

proc markBlocked(blocked: var seq[bool], x, y, w, h: int) =
  ## Marks all path cells overlapped by a world rectangle.
  if w <= 0 or h <= 0:
    return
  let
    minTx = clampTileX(max(0, x - ObstaclePad))
    minTy = clampTileY(max(0, y - ObstaclePad))
    maxTx = clampTileX(min(WorldWidthPixels - 1, x + w + ObstaclePad - 1))
    maxTy = clampTileY(min(WorldHeightPixels - 1, y + h + ObstaclePad - 1))
  for ty in minTy .. maxTy:
    for tx in minTx .. maxTx:
      blocked[gridIndex(tx, ty)] = true

proc isCarryOverlayObject(objectId: int): bool =
  ## Carry sprites are player affordances, not collectible world resources.
  objectId >= CarryObjectBase and objectId < StatusBadgeObjectBase

proc isLooseCarryPickupObject(objectId: int): bool =
  ## Ground carry pickups use pickup object ids; landmarks use landmark ids.
  objectId >= PickupObjectBase and objectId < ChatObjectBase

proc targetDistance(bot: Bot, target: Target): int =
  ## Returns the current Manhattan distance to one target.
  manhattan(
    bot.playerWorldX,
    bot.playerWorldY,
    target.x,
    target.y
  )

proc isOpportunisticLoosePickup(bot: Bot, target: Target): bool =
  ## Keeps loose loot useful without letting old drops break expedition pacing.
  bot.targetDistance(target) <= OpportunisticLootRadius and
    target.x >= bot.playerWorldX - BacktrackLootSlack and
    target.x >= bot.frontierX - FrontierLootBacktrackSlack

proc targetCenter(
  bot: Bot,
  objectState: ObjectState,
  sprite: SpriteInfo
): tuple[x: int, y: int] =
  ## Converts an object visible center into world coordinates.
  let bounds = sprite.visibleBounds()
  (
    x: bot.cameraX + objectState.x + bounds.x + bounds.w div 2,
    y: bot.cameraY + objectState.y + bounds.y + bounds.h div 2
  )

proc scanWorld(
  bot: Bot,
  blocked: var seq[bool],
  pickups: var seq[Target],
  allies: var seq[Target],
  mobs: var seq[Target]
) =
  ## Extracts terrain, pickups, teammates, and monsters from protocol objects.
  blocked.resetBlocked()
  pickups.setLen(0)
  allies.setLen(0)
  mobs.setLen(0)

  var downedPlayerIds: seq[bool]
  for objectId in 0 ..< bot.objects.len:
    let objectState = bot.objects[objectId]
    if not objectState.present:
      continue
    if objectId < StatusBadgeObjectBase:
      continue
    let sprite = bot.spriteInfo(objectState.spriteId)
    if sprite.kind != SpriteText or
        sprite.label.toLowerAscii() != "status down":
      continue
    let playerId = (objectId - StatusBadgeObjectBase) div StatusBadgeSlots
    while downedPlayerIds.len <= playerId:
      downedPlayerIds.add(false)
    downedPlayerIds[playerId] = true

  for objectId in 0 ..< bot.objects.len:
    let objectState = bot.objects[objectId]
    if not objectState.present:
      continue
    let sprite = bot.spriteInfo(objectState.spriteId)
    if not sprite.defined:
      continue
    if objectId.isCarryOverlayObject():
      continue
    case sprite.kind
    of SpritePlayer:
      if objectId == bot.selfObjectId:
        continue
      if objectId < PlayerObjectBase or objectId >= MobObjectBase:
        continue
      let
        playerId = objectId - PlayerObjectBase
        screenFeet = objectState.objectFootCenter(sprite)
        x = bot.cameraX + screenFeet.x
        y = bot.cameraY + screenFeet.y
      allies.add(Target(
        found: true,
        kind:
          if playerId >= 0 and playerId < downedPlayerIds.len and
              downedPlayerIds[playerId]:
            TargetRescue
          else:
            TargetRegroup,
        objectId: objectId,
        x: x,
        y: y,
        label:
          if playerId >= 0 and playerId < downedPlayerIds.len and
              downedPlayerIds[playerId]:
            TargetRescue.targetLabel()
          else:
            TargetRegroup.targetLabel()
      ))
    of SpriteTerrain:
      let bounds = sprite.terrainBounds()
      blocked.markBlocked(
        bot.cameraX + objectState.x + bounds.x,
        bot.cameraY + objectState.y + bounds.y,
        bounds.w,
        bounds.h
      )
    of SpriteCoin:
      let
        kind = sprite.targetKindForSprite()
        center = bot.targetCenter(objectState, sprite)
      pickups.add(Target(
        found: true,
        kind: kind,
        objectId: objectId,
        x: center.x,
        y: center.y,
        label: kind.targetLabel()
      ))
    of SpriteHeart:
      let center = bot.targetCenter(objectState, sprite)
      pickups.add(Target(
        found: true,
        kind: TargetHeart,
        objectId: objectId,
        x: center.x,
        y: center.y,
        label: TargetHeart.targetLabel()
      ))
    of SpriteText:
      let kind = sprite.label.roleTargetKindForLabel()
      if kind != TargetExplore:
        let center = bot.targetCenter(objectState, sprite)
        pickups.add(Target(
          found: true,
          kind: kind,
          objectId: objectId,
          x: center.x,
          y: center.y + RoleLabelToGearOffset,
          label: kind.targetLabel()
        ))
    of SpriteMob, SpriteTroll, SpriteBoss:
      let
        kind = sprite.targetKindForSprite()
        center = bot.targetCenter(objectState, sprite)
      mobs.add(Target(
        found: true,
        kind: kind,
        objectId: objectId,
        x: center.x,
        y: center.y,
        label: kind.targetLabel()
      ))
    else:
      discard

proc nearestOpenTile(
  blocked: openArray[bool],
  tx,
  ty: int
): tuple[found: bool, tx: int, ty: int] =
  ## Finds the nearest pathable tile around a requested tile.
  if inGrid(tx, ty) and not blocked.isBlocked(tx, ty):
    return (true, tx, ty)
  for radius in 1 .. 6:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if abs(dx) != radius and abs(dy) != radius:
          continue
        let
          nx = tx + dx
          ny = ty + dy
        if inGrid(nx, ny) and not blocked.isBlocked(nx, ny):
          return (true, nx, ny)
  (false, tx, ty)

proc heuristicDistance(ax, ay, bx, by: int): int =
  ## Returns the A-star tile heuristic.
  abs(ax - bx) + abs(ay - by)

proc reconstructStep(
  parents: openArray[int],
  startIndex,
  goalIndex: int
): PathStep =
  ## Reconstructs a short lookahead step from a parent grid.
  var path: seq[int] = @[goalIndex]
  while path[^1] != startIndex:
    let nextIndex = parents[path[^1]]
    if nextIndex < 0 or nextIndex == path[^1]:
      return
    path.add(nextIndex)
  let stepIndex = path[max(0, path.high - PathLookaheadCells)]
  PathStep(
    found: true,
    nextTx: stepIndex mod PathGridWidth,
    nextTy: stepIndex div PathGridWidth
  )

proc findPathStep(
  blocked: openArray[bool],
  startX,
  startY,
  goalX,
  goalY: int
): PathStep =
  ## Finds the first pathing tile toward a world goal.
  let
    startTx = clampTileX(startX)
    startTy = clampTileY(startY)
    openGoal = blocked.nearestOpenTile(clampTileX(goalX), clampTileY(goalY))
  if not openGoal.found:
    return
  let
    goalTx = openGoal.tx
    goalTy = openGoal.ty
    startIndex = gridIndex(startTx, startTy)
    goalIndex = gridIndex(goalTx, goalTy)
    area = PathGridWidth * PathGridHeight
  if startTx == goalTx and startTy == goalTy:
    return PathStep(found: true, nextTx: startTx, nextTy: startTy)

  var
    parents = newSeq[int](area)
    costs = newSeq[int](area)
    closed = newSeq[bool](area)
    openSet: HeapQueue[PathNode]
  for i in 0 ..< area:
    parents[i] = -2
    costs[i] = high(int)

  parents[startIndex] = startIndex
  costs[startIndex] = 0
  openSet.push(PathNode(
    priority: heuristicDistance(startTx, startTy, goalTx, goalTy),
    index: startIndex
  ))

  while openSet.len > 0:
    let current = openSet.pop()
    if closed[current.index]:
      continue
    if current.index == goalIndex:
      return reconstructStep(parents, startIndex, goalIndex)
    closed[current.index] = true

    let
      tx = current.index mod PathGridWidth
      ty = current.index div PathGridWidth
    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nextTx = tx + delta[0]
        nextTy = ty + delta[1]
      if not inGrid(nextTx, nextTy):
        continue
      if blocked.isBlocked(nextTx, nextTy):
        continue
      let nextIndex = gridIndex(nextTx, nextTy)
      if closed[nextIndex]:
        continue
      let tentative = costs[current.index] + 1
      if tentative >= costs[nextIndex]:
        continue
      costs[nextIndex] = tentative
      parents[nextIndex] = current.index
      openSet.push(PathNode(
        priority: tentative +
          heuristicDistance(nextTx, nextTy, goalTx, goalTy),
        index: nextIndex
      ))

proc randomMoveMask(rng: var Rand): uint8 =
  ## Chooses a short random movement mask.
  case rng.rand(3)
  of 0:
    ButtonUp
  of 1:
    ButtonDown
  of 2:
    ButtonLeft
  else:
    ButtonRight

proc currentExploreDetourOffset(bot: Bot): int =
  ## Returns the preferred vertical lane offset after a failed push.
  ExploreDetourOffsets[
    clamp(bot.exploreDetourIndex, 0, ExploreDetourOffsets.high)
  ]

proc advanceExploreDetour(bot: var Bot) =
  ## Rotates the next push goal onto a different lane after a stall.
  bot.exploreDetourIndex =
    (bot.exploreDetourIndex + 1) mod ExploreDetourOffsets.len
  if bot.exploreDetourIndex == 0:
    bot.exploreDetourIndex = 1
  bot.lastExploreStuckTick = bot.frameTick

proc resetExploreDetourIfCalm(bot: var Bot) =
  ## Lets successful movement settle back to the natural straight-ahead lane.
  if bot.exploreDetourIndex == 0 or bot.lastExploreStuckTick <= 0:
    return
  if bot.frameTick - bot.lastExploreStuckTick >= ExploreDetourResetTicks:
    bot.exploreDetourIndex = 0

proc exploreDyOrder(bot: Bot): seq[int] =
  ## Returns the vertical search order for the next rightward push target.
  let preferred = bot.currentExploreDetourOffset()
  if preferred != 0:
    result.add(preferred)
  for dy in ExploreDetourOffsets:
    if dy != preferred:
      result.add(dy)

proc clampExpeditionLanePathTy(ty: int): int =
  ## Keeps long push goals inside the main playable expedition corridor.
  clamp(ty, ExpeditionLaneMinPathTy, ExpeditionLaneMaxPathTy)

proc outsideExpeditionLane(bot: Bot): bool =
  bot.playerWorldY < ExpeditionLaneMinY - ExpeditionLaneRecoverySlack or
    bot.playerWorldY > ExpeditionLaneMaxY + ExpeditionLaneRecoverySlack

proc expeditionLaneRecoveryTarget(bot: Bot): Target =
  ## Pulls a bot back into the navigable corridor after side fights or loot.
  if not bot.outsideExpeditionLane():
    return
  Target(
    found: true,
    kind: TargetExplore,
    objectId: -1,
    x: min(WorldWidthPixels - 1, bot.playerWorldX + ExpeditionLaneRecoveryLead),
    y: clamp(bot.playerWorldY, ExpeditionLaneMinY, ExpeditionLaneMaxY),
    label: TargetExplore.targetLabel()
  )

proc exploreDetourVerticalMask(bot: Bot): uint8 =
  ## Turns the active push detour into an immediate unstuck nudge.
  let offset = bot.currentExploreDetourOffset()
  if offset > 0:
    ButtonDown
  elif offset < 0:
    ButtonUp
  else:
    0

proc isRoleTarget(kind: TargetKind): bool =
  kind in {TargetTankRole, TargetDpsRole, TargetHealerRole}

proc isCarryResourceTarget(kind: TargetKind): bool =
  kind in {TargetWood, TargetFood, TargetStone, TargetGold}

proc directedUnstuckMask(bot: var Bot): uint8 =
  ## Chooses a recovery nudge that still respects the current target.
  if bot.currentTargetKind == TargetExplore and
      bot.exploreDetourVerticalMask() != 0:
    return bot.exploreDetourVerticalMask()
  let vertical =
    if bot.rng.rand(1) == 0:
      ButtonUp
    else:
      ButtonDown
  if bot.currentTargetKind == TargetExplore:
    return ButtonRight or vertical
  if bot.currentTargetKind.isRoleTarget():
    return vertical or (
      if bot.currentTargetX >= bot.playerWorldX:
        ButtonRight
      else:
        ButtonLeft
    )
  if bot.currentTargetId >= 0:
    let horizontal =
      if bot.currentTargetX >= bot.playerWorldX:
        ButtonRight
      else:
        ButtonLeft
    return horizontal or vertical
  bot.rng.randomMoveMask()

proc updateStuck(bot: var Bot) =
  ## Updates stuck detection using the previous movement mask.
  if not bot.havePlayerSample:
    bot.previousPlayerX = bot.playerWorldX
    bot.previousPlayerY = bot.playerWorldY
    bot.havePlayerSample = true
    return

  let moved = distanceSquared(
    bot.playerWorldX,
    bot.playerWorldY,
    bot.previousPlayerX,
    bot.previousPlayerY
  )
  if (bot.lastMask and MoveMask) != 0 and moved == 0:
    inc bot.stuckFrames
  else:
    bot.stuckFrames = 0
  bot.previousPlayerX = bot.playerWorldX
  bot.previousPlayerY = bot.playerWorldY

  if bot.stuckFrames >= StuckFrameThreshold:
    if bot.currentTargetKind == TargetExplore:
      bot.advanceExploreDetour()
    bot.jiggleTicks = JiggleDuration
    bot.jiggleMask = bot.directedUnstuckMask()
    if bot.currentTargetId >= 0 and not bot.currentTargetKind.isRoleTarget():
      bot.skipTargetId = bot.currentTargetId
      bot.skipTicks = SkipTargetTicks
    bot.stuckFrames = 0
    bot.hasExploreGoal = false

proc choosingRole(bot: Bot): bool =
  bot.needsRole or bot.objectiveHint.startsWith("next walk into tank dps heal") or
    (
      not bot.hasRole and bot.frameTick <= RoleChoiceFallbackTicks and
      (bot.preferredRole != PreferAnyRole or bot.selfObjectId >= PlayerObjectBase)
    )

proc inferredRolePreference(bot: Bot): RolePreference =
  ## Uses configured preference, then self id, to form a balanced party.
  if bot.preferredRole != PreferAnyRole:
    return bot.preferredRole
  if bot.selfObjectId >= PlayerObjectBase:
    return rolePreferenceForIndex(bot.selfObjectId - PlayerObjectBase - 1)
  PreferAnyRole

proc preferredRoleTarget(bot: Bot): TargetKind =
  bot.inferredRolePreference().targetKindForPreference()

proc objectiveHintIsWaystation(bot: Bot): bool =
  ## Waystation objective text uses biome-specific verbs instead of "waypoint".
  for biome in BiomeKind:
    if bot.objectiveHint == "next " & biome.waystationPromptLabel().toLowerAscii():
      return true

proc currentObjectiveTarget(bot: Bot, kind: TargetKind): bool =
  ## Returns true when the HUD says this landmark kind is the main task.
  case kind
  of TargetRelic:
    bot.objectiveHint.startsWith("next relic")
  of TargetGate:
    bot.objectiveHint.startsWith("next open gate")
  of TargetBoss:
    bot.objectiveHint.startsWith("next defeat boss")
  of TargetCamp:
    bot.objectiveHint.startsWith("next build camp") or
      bot.objectiveHint.startsWith("next camp")
  of TargetWaystation:
    bot.objectiveHintIsWaystation()
  else:
    false

proc optionalExpeditionTarget(kind: TargetKind): bool =
  kind in {
    TargetRelic,
    TargetShrine,
    TargetRescue,
    TargetLair,
    TargetWaystation
  }

proc isOpportunisticObjective(bot: Bot, target: Target): bool =
  ## Keeps side objectives useful without letting stale clusters stop progress.
  bot.currentObjectiveTarget(target.kind) or (
    bot.targetDistance(target) <= OpportunisticObjectiveRadius and
    target.x >= bot.playerWorldX - BacktrackLootSlack
  )

proc isUsefulLooseCarryPickup(bot: Bot, target: Target): bool =
  ## Treats dropped expedition resources as local pickups, not old objectives.
  bot.targetDistance(target) <= OpportunisticResourceRadius and
    target.x >= bot.playerWorldX - BacktrackLootSlack and
    target.x >= bot.frontierX - FrontierLootBacktrackSlack

proc campTooFarBehindFrontier(bot: Bot, target: Target): bool =
  ## Keeps old incomplete camps from pulling bots out of the forward push.
  bot.frontierX > 0 and target.x < bot.frontierX - FrontierCampBacktrackSlack

proc canConsiderPickupTarget(bot: Bot, target: Target): bool =
  ## During role choice, ignore generic gear and non-preferred role labels.
  if bot.carriedItem != CarryNone and target.kind.isCarryResourceTarget() and
      target.objectId.isLooseCarryPickupObject():
    return false
  if target.kind.isCarryResourceTarget() and
      target.objectId.isLooseCarryPickupObject() and
      not bot.isUsefulLooseCarryPickup(target):
    return false
  if target.kind == TargetCamp and bot.campTooFarBehindFrontier(target):
    return false
  if target.kind.optionalExpeditionTarget() and
      not bot.isOpportunisticObjective(target):
    return false
  if target.kind == TargetCamp and bot.campResourceSearchTicks > 0:
    return false
  if target.kind == TargetCamp and (bot.needWood > 0 or bot.needStone > 0):
    return false
  if target.kind == TargetShelter:
    if not bot.lowHealth:
      return false
    if bot.targetDistance(target) > ShelterReturnRadius:
      return false
  if target.kind == TargetCoin and not bot.isOpportunisticLoosePickup(target):
    return false
  if target.kind == TargetHeart and
      not (bot.lowHealth or bot.needsRegroup) and
      not bot.isOpportunisticLoosePickup(target):
    return false
  if target.kind.isRoleTarget() and not bot.choosingRole():
    return false
  if target.kind in {TargetCoin, TargetHeart} and
      target.x <= SafeZoneRightPixels + WorldTileSize * 2:
    return false
  if not bot.choosingRole():
    return true
  if target.kind in {TargetCoin, TargetHeart}:
    return false
  if target.kind.isRoleTarget():
    let preferred = bot.preferredRoleTarget()
    return preferred == TargetExplore or target.kind == preferred
  true

proc isImmediateThreat(bot: Bot, target: Target): bool =
  bot.targetDistance(target) <= WorldTileSize

proc canConsiderThreatTarget(bot: Bot, target: Target): bool =
  ## Keeps fights forward unless the monster is already on top of the bot.
  if target.kind notin {TargetMob, TargetTroll, TargetBoss}:
    return true
  if bot.isImmediateThreat(target):
    return true
  target.x >= bot.playerWorldX - BacktrackLootSlack and
    target.x >= bot.frontierX - FrontierLootBacktrackSlack

proc isPlayerRescueTarget(target: Target): bool =
  target.kind == TargetRescue and
    target.objectId >= PlayerObjectBase and target.objectId < MobObjectBase

proc targetScore(bot: Bot, target: Target): int =
  ## Scores a target where lower is better.
  let distance = bot.targetDistance(target)
  case target.kind
  of TargetRegroup:
    distance + (if bot.needsRegroup: (if bot.lowHealth: -120 else: -260) elif bot.lowHealth: 20 else: 340)
  of TargetTankRole, TargetDpsRole, TargetHealerRole:
    let preferred = bot.preferredRoleTarget()
    if not bot.choosingRole():
      distance + 260
    elif preferred == TargetExplore:
      distance - 180
    elif target.kind == preferred:
      distance - 430
    else:
      distance + 520
  of TargetCoin:
    distance + (if bot.choosingRole(): 320 else: 90)
  of TargetHeart:
    distance + (
      if bot.choosingRole():
        320
      elif bot.lowHealth:
        -210
      elif bot.needsRegroup:
        -40
      else:
        15
    )
  of TargetWood:
    if bot.needWood > 0 or bot.campResourceSearchTicks > 0:
      distance - 260
    elif bot.carriedItem == CarryWood:
      distance + 170
    else:
      distance - 120
  of TargetFood:
    if bot.carriedItem == CarryFood:
      distance + (if bot.lowHealth: -20 else: 90)
    else:
      distance + (if bot.lowHealth or bot.objectiveHint.contains("heal food"): -150 elif bot.needsRegroup: -115 else: -95)
  of TargetStone:
    if bot.needStone > 0 or bot.campResourceSearchTicks > 0:
      distance - 260
    elif bot.carriedItem == CarryStone:
      distance + 170
    else:
      distance - 120
  of TargetGold:
    if bot.needStone > 0:
      distance - 170
    elif bot.carriedItem == CarryGold:
      distance + 160
    else:
      distance - 55
  of TargetCamp:
    if bot.needWood > 0 or bot.needStone > 0:
      distance + 900
    elif bot.objectiveHint.startsWith("next build camp") or
        bot.objectiveHint.startsWith("next camp"):
      distance - 230
    elif bot.carriedItem in {CarryWood, CarryFood, CarryStone, CarryGold}:
      distance - 170
    else:
      distance + (if bot.lowHealth or bot.needsRegroup: -180 else: -100)
  of TargetShelter:
    distance + (if bot.lowHealth: -210 else: 520)
  of TargetRelic:
    if bot.objectiveHint.startsWith("next relic"):
      distance - 170
    elif bot.needWood > 0 or bot.needStone > 0:
      distance + 120
    else:
      distance - 85
  of TargetWaystation:
    distance + (if bot.lowHealth or bot.needsRegroup: -165 else: -65)
  of TargetRescue:
    if target.isPlayerRescueTarget():
      distance + (
        if bot.lowHealth:
          -260
        elif bot.roleLabel == "healer":
          -720
        else:
          -620
      )
    else:
      distance + (if bot.needsRegroup: -120 else: -50)
  of TargetShrine:
    distance - 20
  of TargetGate:
    distance + (if bot.objectiveHint.startsWith("next open gate"): -210 else: 10)
  of TargetLair:
    distance + (if bot.lowHealth or bot.needsRegroup: 420 elif distance < 100: -45 else: 180)
  of TargetMob:
    distance + (if bot.lowHealth: 340 elif bot.needsRegroup: 240 elif distance < 90: -70 else: 620)
  of TargetTroll:
    distance + (if bot.lowHealth: 400 elif bot.needsRegroup: 280 elif distance < 105: -60 else: 700)
  of TargetBoss:
    distance + (if bot.lowHealth: 560 elif bot.needsRegroup: 440 elif distance < 120: -45 else: 900)
  of TargetExplore:
    distance + 120

proc hasPlayerRescueTarget(targets: openArray[Target]): bool =
  for target in targets:
    if target.isPlayerRescueTarget():
      return true

proc refreshExploreGoal(bot: var Bot, blocked: openArray[bool]) =
  ## Picks a new open tile that keeps the expedition pushing right.
  bot.resetExploreDetourIfCalm()
  if bot.hasExploreGoal and
      bot.exploreX > bot.playerWorldX + GoalArrivalRadius and
      distanceSquared(
        bot.playerWorldX,
        bot.playerWorldY,
        bot.exploreX,
        bot.exploreY
      ) > GoalArrivalRadius * GoalArrivalRadius:
    return

  let
    currentTx = clampTileX(bot.playerWorldX)
    currentTy = clampTileY(bot.playerWorldY)
  for step in [36, 28, 20, 12, 6]:
    let tx = min(PathGridWidth - 1, currentTx + step)
    for dy in bot.exploreDyOrder():
      let ty = clampExpeditionLanePathTy(currentTy + dy)
      if not inGrid(tx, ty) or blocked.isBlocked(tx, ty):
        continue
      bot.exploreIndex = gridIndex(tx, ty)
      bot.exploreX = tileCenterX(tx)
      bot.exploreY = tileCenterY(ty)
      bot.hasExploreGoal = true
      return

  for attempt in 0 ..< PathGridWidth:
    let
      tx = (bot.exploreIndex + attempt * ExploreStep) mod PathGridWidth
      forwardTx = max(currentTx + 1, tx)
    if forwardTx >= PathGridWidth:
      break
    for ty in ExpeditionLaneMinPathTy .. ExpeditionLaneMaxPathTy:
      if blocked.isBlocked(forwardTx, ty):
        continue
      bot.exploreIndex = gridIndex(forwardTx, ty)
      bot.exploreX = tileCenterX(forwardTx)
      bot.exploreY = tileCenterY(ty)
      bot.hasExploreGoal = true
      return

  let area = PathGridWidth * PathGridHeight
  for attempt in 0 ..< area:
    let
      index = (bot.exploreIndex + attempt * ExploreStep) mod area
      tx = index mod PathGridWidth
      ty = index div PathGridWidth
    if blocked.isBlocked(tx, ty):
      continue
    bot.exploreIndex = (index + ExploreStep) mod area
    bot.exploreX = tileCenterX(tx)
    bot.exploreY = tileCenterY(ty)
    bot.hasExploreGoal = true
    return

  bot.exploreX = WorldWidthPixels div 2
  bot.exploreY = WorldHeightPixels div 2
  bot.hasExploreGoal = true

proc chooseTarget(
  bot: var Bot,
  blocked: openArray[bool],
  pickups,
  allies,
  mobs: openArray[Target]
): Target =
  ## Chooses the next pickup, teammate, monster, or exploration target.
  let laneRecovery = bot.expeditionLaneRecoveryTarget()
  if laneRecovery.found:
    return laneRecovery

  var bestScore = high(int)
  let rescueVisible = allies.hasPlayerRescueTarget()
  for pickup in pickups:
    if bot.skipTicks > 0 and pickup.objectId == bot.skipTargetId:
      continue
    if not bot.canConsiderPickupTarget(pickup):
      continue
    let score = bot.targetScore(pickup)
    if score < bestScore:
      bestScore = score
      result = pickup
  if bot.needsRegroup or bot.lowHealth or rescueVisible:
    for ally in allies:
      if bot.skipTicks > 0 and ally.objectId == bot.skipTargetId:
        continue
      let score = bot.targetScore(ally)
      if score < bestScore:
        bestScore = score
        result = ally
  bot.refreshExploreGoal(blocked)
  let pushTarget = Target(
    found: true,
    kind: TargetExplore,
    objectId: -1,
    x: bot.exploreX,
    y: bot.exploreY,
    label: TargetExplore.targetLabel()
  )
  let pushScore = bot.targetScore(pushTarget)
  if pushScore < bestScore:
    bestScore = pushScore
    result = pushTarget
  if not bot.choosingRole():
    for mob in mobs:
      if bot.skipTicks > 0 and mob.objectId == bot.skipTargetId:
        continue
      if not bot.canConsiderThreatTarget(mob):
        continue
      let score = bot.targetScore(mob)
      if score < bestScore:
        bestScore = score
        result = mob
  if result.found:
    return

  result = pushTarget

proc nearestMob(bot: Bot, mobs: openArray[Target]): Target =
  ## Finds the nearest monster target.
  var bestDistance = high(int)
  for mob in mobs:
    let distance = distanceSquared(
      bot.playerWorldX,
      bot.playerWorldY,
      mob.x,
      mob.y
    )
    if distance < bestDistance:
      bestDistance = distance
      result = mob

proc containsTarget(targets: openArray[Target], objectId: int): bool =
  ## Returns true when a target id is still visible.
  for target in targets:
    if target.objectId == objectId:
      return true

proc rememberTarget(bot: var Bot, target: Target) =
  ## Stores the active target for debug and stuck recovery.
  let targetDistance = manhattan(
    bot.playerWorldX,
    bot.playerWorldY,
    target.x,
    target.y
  )
  if target.objectId == bot.currentTargetId and
      target.kind == bot.currentTargetKind and
      targetDistance <= ActivationStallDistance:
    inc bot.targetCloseTicks
  else:
    bot.targetCloseTicks = 0
  bot.currentTargetId = target.objectId
  bot.currentTargetKind = target.kind
  bot.currentTargetX = target.x
  bot.currentTargetY = target.y
  bot.currentTargetLabel = target.label
  bot.currentTargetDistance = targetDistance
  if target.kind == TargetCamp and
      bot.targetCloseTicks >= CampActivationStallTicks:
    bot.skipTargetId = target.objectId
    bot.skipTicks = CampResourceSearchTicks
    bot.campResourceSearchTicks = CampResourceSearchTicks
    bot.targetCloseTicks = 0
    bot.hasExploreGoal = false

proc updateTargetResult(
  bot: var Bot,
  pickups,
  allies,
  mobs: openArray[Target]
) =
  ## Infers successful pickups and kills from target disappearance.
  if bot.currentTargetId < 0:
    return
  let stillPresent =
    case bot.currentTargetKind
    of TargetTankRole,
        TargetDpsRole,
        TargetHealerRole,
        TargetCoin,
        TargetHeart,
        TargetWood,
        TargetFood,
        TargetStone,
        TargetGold,
        TargetCamp,
        TargetShelter,
        TargetRelic,
        TargetGate,
        TargetShrine,
        TargetRescue,
        TargetLair,
        TargetWaystation:
      pickups.containsTarget(bot.currentTargetId)
    of TargetRegroup:
      allies.containsTarget(bot.currentTargetId)
    of TargetMob, TargetTroll, TargetBoss:
      mobs.containsTarget(bot.currentTargetId)
    of TargetExplore:
      true
  if stillPresent:
    return
  case bot.currentTargetKind
  of TargetTankRole, TargetDpsRole, TargetHealerRole:
    if bot.currentTargetDistance < 96:
      echo "role chosen kind=", bot.currentTargetKind,
        " id=", bot.currentTargetId
  of TargetCoin:
    if bot.currentTargetDistance < 64:
      inc bot.coinCount
      echo "coin collected id=", bot.currentTargetId,
        " total=", bot.coinCount
  of TargetHeart:
    if bot.currentTargetDistance < 64:
      inc bot.heartCount
      echo "heart collected id=", bot.currentTargetId,
        " total=", bot.heartCount
  of TargetWood,
      TargetFood,
      TargetStone,
      TargetGold,
      TargetCamp,
      TargetShelter,
      TargetRelic,
      TargetGate,
      TargetShrine,
      TargetRescue,
      TargetLair,
      TargetWaystation:
    if bot.currentTargetDistance < 96:
      echo "objective done kind=", bot.currentTargetKind,
        " id=", bot.currentTargetId
  of TargetRegroup:
    discard
  of TargetMob, TargetTroll, TargetBoss:
    if bot.currentTargetDistance < 96:
      inc bot.killCount
      echo "monster down id=", bot.currentTargetId,
        " total=", bot.killCount
  of TargetExplore:
    discard
  bot.currentTargetId = -1

proc faceMask(dx, dy: int): uint8 =
  ## Returns a direction mask that faces a target point.
  if abs(dx) > abs(dy):
    if dx < 0:
      ButtonLeft
    else:
      ButtonRight
  else:
    if dy < 0:
      ButtonUp
    else:
      ButtonDown

proc steerMask(bot: Bot, x, y: int): uint8 =
  ## Builds movement buttons to steer toward a world point.
  let
    dx = x - bot.playerWorldX
    dy = y - bot.playerWorldY
  if abs(dx) > MoveDeadband:
    if dx < 0:
      result = result or ButtonLeft
    else:
      result = result or ButtonRight
  if abs(dy) > MoveDeadband:
    if dy < 0:
      result = result or ButtonUp
    else:
      result = result or ButtonDown

proc canAttack(bot: Bot, target: Target): bool =
  ## Returns true when a target is close enough for a swing.
  let
    dx = target.x - bot.playerCenterWorldX
    dy = target.y - bot.playerCenterWorldY
  (abs(dx) <= AttackReach and abs(dy) <= AttackAlignSlack) or
    (abs(dy) <= AttackReach and abs(dx) <= AttackAlignSlack)

proc roleAbilityAttackMask(bot: Bot, target: Target): uint8 =
  ## Returns B when the current role power should be fired into a fight.
  if not bot.abilityReady or target.kind notin {
      TargetLair, TargetMob, TargetTroll, TargetBoss}:
    return 0
  let distance = distanceSquared(
    bot.playerCenterWorldX,
    bot.playerCenterWorldY,
    target.x,
    target.y
  )
  if distance > (AttackReach * 2) * (AttackReach * 2):
    return 0
  case bot.roleLabel
  of "tank", "dps":
    ButtonB
  else:
    0

proc recoveryAbilityMask(bot: Bot): uint8 =
  ## Lets healers spend their pulse as soon as the HUD reports real danger.
  if bot.abilityReady and bot.roleLabel == "healer" and bot.lowHealth:
    ButtonB
  else:
    0

proc attackMask(bot: var Bot, target: Target): uint8 =
  ## Builds a facing and attack pulse toward a monster.
  result = faceMask(
    target.x - bot.playerCenterWorldX,
    target.y - bot.playerCenterWorldY
  )
  if bot.attackCooldown == 0:
    result = result or ButtonA
    result = result or bot.roleAbilityAttackMask(target)
    bot.attackCooldown = AttackCooldownTicks

proc decideNextMask(bot: var Bot): uint8 =
  ## Chooses the next controller mask from sprite protocol state.
  bot.updateCamera()
  bot.updatePlayerPosition()
  bot.updateSelfAffordances()
  if bot.attackCooldown > 0:
    dec bot.attackCooldown
  if bot.skipTicks > 0:
    dec bot.skipTicks
    if bot.skipTicks == 0:
      bot.skipTargetId = -1
  if bot.campResourceSearchTicks > 0:
    dec bot.campResourceSearchTicks

  var
    blocked: seq[bool]
    pickups: seq[Target]
    allies: seq[Target]
    mobs: seq[Target]
  bot.scanWorld(blocked, pickups, allies, mobs)
  bot.updateTargetResult(pickups, allies, mobs)
  bot.updateStuck()

  let recoveryMask = bot.recoveryAbilityMask()
  if recoveryMask != 0:
    bot.intent = "heal"
    return recoveryMask

  if bot.jiggleTicks > 0:
    dec bot.jiggleTicks
    bot.intent = "unstuck"
    return bot.jiggleMask

  let closeMob = bot.nearestMob(mobs)
  if closeMob.found and bot.canAttack(closeMob):
    bot.rememberTarget(closeMob)
    bot.intent = closeMob.label
    return bot.attackMask(closeMob)

  let target = bot.chooseTarget(blocked, pickups, allies, mobs)
  bot.rememberTarget(target)
  bot.intent = target.label
  if target.kind.isAttackTarget() and bot.canAttack(target):
    return bot.attackMask(target)

  let step = findPathStep(
    blocked,
    bot.playerWorldX,
    bot.playerWorldY,
    target.x,
    target.y
  )
  if step.found:
    let
      startTx = clampTileX(bot.playerWorldX)
      startTy = clampTileY(bot.playerWorldY)
    if step.nextTx == startTx and step.nextTy == startTy:
      return bot.steerMask(target.x, target.y)
    return bot.steerMask(tileCenterX(step.nextTx), tileCenterY(step.nextTy))

  if target.objectId >= 0:
    bot.skipTargetId = target.objectId
    bot.skipTicks = SkipTargetTicks
  bot.hasExploreGoal = false
  bot.steerMask(target.x, target.y)

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc playerInputBlob(mask: uint8): string =
  ## Builds a sprite protocol player input packet.
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

proc maskSummary(mask: uint8): string =
  ## Returns a compact debug string for pressed keys.
  if (mask and ButtonUp) != 0:
    result.add("U")
  if (mask and ButtonDown) != 0:
    result.add("D")
  if (mask and ButtonLeft) != 0:
    result.add("L")
  if (mask and ButtonRight) != 0:
    result.add("R")
  if (mask and ButtonA) != 0:
    result.add("A")
  if (mask and ButtonB) != 0:
    result.add("B")
  if result.len == 0:
    result = "."

proc echoDebug(bot: Bot, mask: uint8, force = false) =
  ## Prints one useful navigation debug line.
  if not force and bot.frameTick mod 24 != 0:
    return
  echo "step=", bot.frameTick,
    " keys=", mask.maskSummary(),
    " pos=", bot.playerWorldX, ",", bot.playerWorldY,
    " role=", (if bot.roleLabel.len > 0: bot.roleLabel else: "?"),
    " intent=", bot.intent,
    " target=", bot.currentTargetLabel,
    "#", bot.currentTargetId,
    "@", bot.currentTargetX, ",", bot.currentTargetY,
    " d=", bot.currentTargetDistance,
    " coins=", bot.coinCount,
    " hearts=", bot.heartCount,
    " kills=", bot.killCount

proc chatBlob(text: string): string =
  ## Builds a sprite protocol text input packet.
  var bytes: seq[uint8] = @[0x81'u8]
  bytes.addU16(text.len)
  for ch in text:
    bytes.add(uint8(ord(ch)))
  blobFromBytes(bytes)

proc queryEscape(value: string): string =
  ## Escapes a query string component.
  const Hex = "0123456789ABCDEF"
  for ch in value:
    if ch.isAlphaNumeric() or ch in {'-', '_', '.', '~'}:
      result.add(ch)
    else:
      let byte = ord(ch)
      result.add('%')
      result.add(Hex[(byte shr 4) and 0x0f])
      result.add(Hex[byte and 0x0f])

proc addQueryParam(url: var string, key, value: string) =
  ## Appends one escaped query parameter when a value is available.
  if value.len == 0:
    return
  if url.contains("?"):
    url.add("&")
  else:
    url.add("?")
  url.add(key)
  url.add("=")
  url.add(value.queryEscape())

proc localPlayerUrl(host: string, port: int, name, token, slot: string): string =
  ## Builds the local /player websocket URL with runner-compatible fallbacks.
  result = "ws://" & host & ":" & $port & WebSocketPath
  result.addQueryParam("name", name)
  result.addQueryParam("token", token)
  result.addQueryParam("slot", slot)

proc initBot(preferredRole = PreferAnyRole): Bot =
  ## Builds the initial bot state.
  result.rng = initRand(getTime().toUnix() xor int64(getCurrentProcessId()))
  result.viewportWidth = ScreenWidth
  result.viewportHeight = ScreenHeight
  result.selfObjectId = -1
  result.currentTargetId = -1
  result.skipTargetId = -1
  result.preferredRole = preferredRole
  result.exploreIndex = result.rng.rand(
    PathGridWidth * PathGridHeight - 1
  )
  result.nextChatTick = 72

proc acceptServerMessage(
  ws: WebSocket,
  message: Message,
  bot: var Bot
): bool =
  ## Handles one websocket message and updates sprite state.
  case message.kind
  of BinaryMessage:
    result = bot.applySpritePacket(message.data)
    if result:
      inc bot.frameTick
  of Ping:
    ws.send(message.data, Pong)
  of TextMessage, Pong:
    discard

proc receiveUpdates(ws: WebSocket, bot: var Bot): bool =
  ## Receives and applies all queued sprite protocol updates.
  let firstMessage = ws.receiveMessage(-1)
  if firstMessage.isNone:
    return false
  if ws.acceptServerMessage(firstMessage.get, bot):
    result = true
  var drained = 0
  while drained < MaxDrainMessages:
    let message = ws.receiveMessage(0)
    if message.isNone:
      break
    if ws.acceptServerMessage(message.get, bot):
      result = true
    inc drained

proc nextChat(bot: var Bot): string =
  ## Returns an optional short status chat message.
  if bot.frameTick < bot.nextChatTick:
    return ""
  bot.nextChatTick = bot.frameTick + 144
  result = bot.intent.toUpperAscii()
  if result.len == 0 or result == bot.lastChat:
    return ""
  bot.lastChat = result

proc runBot(
  host = DefaultHost,
  port = PlayerDefaultPort,
  name = "konrad",
  token = "",
  slot = "",
  chat = false,
  maxSteps = 0
) =
  ## Connects to the Party Progressor player endpoint.
  let url =
    if getEnv("COGAMES_ENGINE_WS_URL").len > 0:
      getEnv("COGAMES_ENGINE_WS_URL")
    else:
      localPlayerUrl(host, port, name, token, slot)
  let preferredRole = rolePreferenceFor(name, slot)

  while true:
    try:
      var bot = initBot(preferredRole)
      let ws = newWebSocket(url)
      var lastMask = 0xff'u8
      while true:
        if not ws.receiveUpdates(bot):
          continue
        let nextMask = bot.decideNextMask()
        bot.echoDebug(nextMask, nextMask != lastMask)
        bot.lastMask = nextMask
        if nextMask != lastMask:
          ws.send(playerInputBlob(nextMask), BinaryMessage)
          lastMask = nextMask
        if chat:
          let text = bot.nextChat()
          if text.len > 0:
            ws.send(chatBlob(text), BinaryMessage)
        if maxSteps > 0 and bot.frameTick >= maxSteps:
          bot.echoDebug(nextMask, true)
          echo "done steps=", bot.frameTick,
            " coins=", bot.coinCount,
            " hearts=", bot.heartCount,
            " kills=", bot.killCount
          ws.close()
          return
    except CatchableError:
      sleep(250)

when defined(konradTargetSelfTest):
  var bot = initBot()
  bot.playerWorldX = 0
  bot.playerWorldY = 0
  doAssert SpriteInfo(
    defined: true,
    label: "wood",
    kind: SpriteCoin
  ).targetKindForSprite() == TargetWood
  doAssert SpriteInfo(
    defined: true,
    label: "lair",
    kind: SpriteCoin
  ).targetKindForSprite() == TargetLair
  doAssert SpriteInfo(
    defined: true,
    label: "shelter",
    kind: SpriteCoin
  ).targetKindForSprite() == TargetShelter
  doAssert TargetWood.isAttackTarget()
  doAssert TargetLair.isAttackTarget()
  doAssert not TargetCamp.isAttackTarget()
  doAssert rolePreferenceFor("tank-bot", "") == PreferTankRole
  doAssert rolePreferenceFor("konrad", "1") == PreferDpsRole
  doAssert rolePreferenceFor("healer", "1") == PreferHealerRole
  doAssert "role heal pulse".roleTargetKindForLabel() == TargetHealerRole
  bot.carriedItem = CarryWood
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetFood,
    objectId: PickupObjectBase + 9
  ))
  doAssert bot.canConsiderPickupTarget(Target(
    kind: TargetFood,
    objectId: LandmarkObjectBase + 1
  ))
  bot.carriedItem = CarryNone
  bot.playerWorldX = 1280
  bot.playerWorldY = 300
  bot.frontierX = 1536
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetStone,
    objectId: PickupObjectBase + 10,
    x: 1280,
    y: 430
  ))
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetStone,
    objectId: PickupObjectBase + 11,
    x: bot.frontierX - FrontierLootBacktrackSlack - 1,
    y: 300
  ))
  doAssert bot.canConsiderPickupTarget(Target(
    kind: TargetStone,
    objectId: PickupObjectBase + 12,
    x: bot.frontierX - FrontierLootBacktrackSlack,
    y: 300
  ))
  bot.needWood = 1
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetCamp,
    objectId: LandmarkObjectBase + 2
  ))
  bot.needWood = 0
  bot.needStone = 0
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetCamp,
    objectId: LandmarkObjectBase + 2,
    x: bot.frontierX - FrontierCampBacktrackSlack - 1,
    y: 300
  ))
  doAssert bot.canConsiderPickupTarget(Target(
    kind: TargetCamp,
    objectId: LandmarkObjectBase + 2,
    x: bot.frontierX - FrontierCampBacktrackSlack,
    y: 300
  ))
  bot.playerWorldX = 0
  bot.playerWorldY = 0
  bot.frontierX = 0
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetShelter,
    objectId: LandmarkObjectBase + 3
  ))
  bot.needsRegroup = true
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetShelter,
    objectId: LandmarkObjectBase + 3
  ))
  bot.needsRegroup = false
  bot.lowHealth = true
  doAssert bot.canConsiderPickupTarget(Target(
    kind: TargetShelter,
    objectId: LandmarkObjectBase + 3,
    x: ShelterReturnRadius,
    y: 0
  ))
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetShelter,
    objectId: LandmarkObjectBase + 3,
    x: ShelterReturnRadius + 1,
    y: 0
  ))
  bot.lowHealth = false
  bot.readStatusHud("tank plains|clear w1 f0 s0 r0|b guard|next camp 0/2 w1 s1")
  doAssert bot.sharedWood == 1
  doAssert bot.sharedStone == 0
  doAssert bot.needWood == 1
  doAssert bot.needStone == 1
  bot.readStatusHud("tank plains|clear w1 f0 s0 r0|b guard|next camp 0/2")
  doAssert bot.needWood == 1
  doAssert bot.needStone == 1
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetCamp,
    objectId: LandmarkObjectBase + 4
  ))
  doAssert bot.targetScore(Target(
    found: true,
    kind: TargetWood,
    x: 80,
    y: 0
  )) < bot.targetScore(Target(
    found: true,
    kind: TargetCamp,
    x: 80,
    y: 0
  ))
  bot.readStatusHud("tank plains|clear w2 f0 s1 r0|b guard|next camp 0/2")
  doAssert bot.needWood == 0
  doAssert bot.needStone == 0
  doAssert bot.canConsiderPickupTarget(Target(
    kind: TargetCamp,
    objectId: LandmarkObjectBase + 4
  ))
  bot.needWood = 0
  bot.needStone = 0
  doAssert bot.targetScore(Target(
    found: true,
    kind: TargetRelic,
    x: 96,
    y: 0
  )) < bot.targetScore(Target(
    found: true,
    kind: TargetBoss,
    x: 96,
    y: 0
  ))
  bot.objectiveHint = "next walk into tank dps heal"
  bot.preferredRole = PreferTankRole
  bot.needsRole = true
  doAssert bot.canConsiderPickupTarget(Target(kind: TargetTankRole))
  doAssert not bot.canConsiderPickupTarget(Target(kind: TargetDpsRole))
  doAssert not bot.canConsiderPickupTarget(Target(kind: TargetHeart))
  bot.needsRole = false
  bot.hasRole = true
  bot.objectiveHint = ""
  doAssert not bot.canConsiderPickupTarget(Target(kind: TargetTankRole))
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetCoin,
    x: SafeZoneRightPixels
  ))
  bot.playerWorldX = 520
  bot.playerWorldY = 0
  doAssert bot.canConsiderPickupTarget(Target(
    kind: TargetCoin,
    x: 580,
    y: 0
  ))
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetCoin,
    x: 340,
    y: 0
  ))
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetHeart,
    x: 340,
    y: 0
  ))
  bot.lowHealth = true
  doAssert bot.canConsiderPickupTarget(Target(
    kind: TargetHeart,
    x: 340,
    y: 0
  ))
  bot.lowHealth = false
  bot.playerWorldX = 0
  bot.needsRole = true
  bot.hasRole = false
  doAssert bot.targetScore(Target(
    found: true,
    kind: TargetTankRole,
    x: 96,
    y: 0
  )) < bot.targetScore(Target(
    found: true,
    kind: TargetDpsRole,
    x: 16,
    y: 0
  ))
  doAssert bot.targetScore(Target(
    found: true,
    kind: TargetTankRole,
    x: 96,
    y: 0
  )) < bot.targetScore(Target(
    found: true,
    kind: TargetCoin,
    x: 16,
    y: 0
  ))
  bot.preferredRole = PreferAnyRole
  bot.selfObjectId = PlayerObjectBase + 3
  doAssert bot.preferredRoleTarget() == TargetHealerRole
  bot.objectiveHint = ""
  bot.needsRole = false
  let
    selectedSpriteId = 9010
    unselectedSpriteId = 9011
    selectedObjectId = PlayerObjectBase + 10
    unselectedObjectId = PlayerObjectBase + 11
  bot.ensureSprite(selectedSpriteId)
  bot.sprites[selectedSpriteId] = SpriteInfo(
    defined: true,
    width: 16,
    height: 24,
    label: "selected player blue1",
    kind: SpritePlayer
  )
  bot.ensureSprite(unselectedSpriteId)
  bot.sprites[unselectedSpriteId] = SpriteInfo(
    defined: true,
    width: 16,
    height: 24,
    label: "player red1",
    kind: SpritePlayer
  )
  bot.ensureObject(selectedObjectId)
  bot.objects[selectedObjectId] = ObjectState(
    present: true,
    x: 80,
    y: 80,
    spriteId: selectedSpriteId
  )
  bot.ensureObject(unselectedObjectId)
  bot.objects[unselectedObjectId] = ObjectState(
    present: true,
    x: bot.viewportWidth div 2,
    y: bot.viewportHeight div 2,
    spriteId: unselectedSpriteId
  )
  bot.updatePlayerPosition()
  doAssert bot.selfObjectId == selectedObjectId
  bot.objects[selectedObjectId].present = false
  bot.objects[unselectedObjectId].present = false
  let parsedHealth = parseHealthLabel("health 2/9")
  doAssert parsedHealth.found
  doAssert parsedHealth.current == 2
  doAssert parsedHealth.maximum == 9
  let
    playerId = 2
    healthSpriteId = 9000
    statusSpriteId = 9001
    hudStatusSpriteId = 9003
    healthObjectId = PlayerHealthObjectBase + playerId
    statusObjectId = StatusBadgeObjectBase + playerId * StatusBadgeSlots
  bot.selfObjectId = PlayerObjectBase + playerId
  bot.ensureSprite(healthSpriteId)
  bot.sprites[healthSpriteId] = SpriteInfo(
    defined: true,
    label: "health 2/9",
    kind: SpriteText
  )
  bot.ensureObject(healthObjectId)
  bot.objects[healthObjectId] = ObjectState(
    present: true,
    spriteId: healthSpriteId
  )
  bot.ensureSprite(statusSpriteId)
  bot.sprites[statusSpriteId] = SpriteInfo(
    defined: true,
    label: "status alone",
    kind: SpriteText
  )
  bot.ensureObject(statusObjectId)
  bot.objects[statusObjectId] = ObjectState(
    present: true,
    spriteId: statusSpriteId
  )
  bot.ensureSprite(hudStatusSpriteId)
  bot.sprites[hudStatusSpriteId] = SpriteInfo(
    defined: true,
    label: "tank snow|snow w0 f0 s0 r0|b guard|carry wood e2 ok|next gather w1 s1",
    kind: SpriteText
  )
  bot.ensureObject(StatusHudObjectId)
  bot.objects[StatusHudObjectId] = ObjectState(
    present: true,
    spriteId: hudStatusSpriteId
  )
  bot.updateSelfAffordances()
  doAssert bot.lowHealth
  doAssert bot.needsRegroup
  doAssert bot.hasRole
  doAssert not bot.needsRole
  doAssert bot.roleLabel == "tank"
  doAssert bot.abilityReady
  doAssert bot.abilityLabel == "guard"
  doAssert bot.carriedItem == CarryWood
  doAssert bot.needWood == 1
  doAssert bot.needStone == 1
  bot.readStatusHud("dps snow|snow w0 f0 s0 r0|b cleave cd12|carry none")
  doAssert bot.roleLabel == "dps"
  doAssert not bot.abilityReady
  doAssert bot.abilityLabel == "cleave cd12"
  bot.roleLabel = "tank"
  bot.abilityReady = true
  bot.attackCooldown = 0
  bot.playerCenterWorldX = 80
  bot.playerCenterWorldY = 300
  let tankAttack = bot.attackMask(Target(
    found: true,
    kind: TargetMob,
    x: 104,
    y: 300
  ))
  doAssert (tankAttack and ButtonA) != 0
  doAssert (tankAttack and ButtonB) != 0
  bot.attackCooldown = 0
  bot.abilityReady = false
  let plainAttack = bot.attackMask(Target(
    found: true,
    kind: TargetMob,
    x: 104,
    y: 300
  ))
  doAssert (plainAttack and ButtonA) != 0
  doAssert (plainAttack and ButtonB) == 0
  bot.roleLabel = "healer"
  bot.abilityReady = true
  bot.lowHealth = true
  doAssert bot.recoveryAbilityMask() == ButtonB
  doAssert bot.targetScore(Target(
    found: true,
    kind: TargetWood,
    x: 96,
    y: 0
  )) < bot.targetScore(Target(
    found: true,
    kind: TargetCamp,
    x: 16,
    y: 0
  ))
  let
    allySpriteId = 9002
    allyObjectId = PlayerObjectBase + playerId + 1
  bot.ensureSprite(allySpriteId)
  bot.sprites[allySpriteId] = SpriteInfo(
    defined: true,
    width: 16,
    height: 24,
    kind: SpritePlayer
  )
  bot.ensureObject(allyObjectId)
  bot.objects[allyObjectId] = ObjectState(
    present: true,
    x: 96,
    y: 0,
    spriteId: allySpriteId
  )
  let
    carrySpriteId = 9006
    carryOverlayObjectId = CarryObjectBase + playerId + 1
  bot.ensureSprite(carrySpriteId)
  bot.sprites[carrySpriteId] = SpriteInfo(
    defined: true,
    width: 16,
    height: 16,
    label: "wood",
    kind: SpriteCoin
  )
  bot.ensureObject(carryOverlayObjectId)
  bot.objects[carryOverlayObjectId] = ObjectState(
    present: true,
    x: 64,
    y: 0,
    spriteId: carrySpriteId
  )
  let
    roleSpriteId = 9004
    roleObjectId = 9005
  bot.ensureSprite(roleSpriteId)
  bot.sprites[roleSpriteId] = SpriteInfo(
    defined: true,
    width: 48,
    height: 8,
    label: "role dps cleave",
    kind: SpriteText
  )
  bot.ensureObject(roleObjectId)
  bot.objects[roleObjectId] = ObjectState(
    present: true,
    x: 80,
    y: 8,
    spriteId: roleSpriteId
  )
  var
    blocked: seq[bool]
    pickups: seq[Target]
    allies: seq[Target]
    mobs: seq[Target]
  bot.scanWorld(blocked, pickups, allies, mobs)
  doAssert allies.len == 1
  doAssert allies[0].kind == TargetRegroup
  var sawDpsRole = false
  for pickup in pickups:
    if pickup.kind == TargetDpsRole:
      sawDpsRole = true
    doAssert pickup.objectId != carryOverlayObjectId
  doAssert sawDpsRole
  let
    downSpriteId = 9008
    downObjectId =
      StatusBadgeObjectBase + (allyObjectId - PlayerObjectBase) * StatusBadgeSlots
  bot.ensureSprite(downSpriteId)
  bot.sprites[downSpriteId] = SpriteInfo(
    defined: true,
    width: 32,
    height: 8,
    label: "status down",
    kind: SpriteText
  )
  bot.ensureObject(downObjectId)
  bot.objects[downObjectId] = ObjectState(
    present: true,
    x: 112,
    y: 0,
    spriteId: downSpriteId
  )
  bot.scanWorld(blocked, pickups, allies, mobs)
  doAssert allies.len == 1
  doAssert allies[0].kind == TargetRescue
  bot.needsRegroup = false
  bot.lowHealth = false
  doAssert bot.targetScore(allies[0]) < bot.targetScore(Target(
    found: true,
    kind: TargetMob,
    x: 40,
    y: 0
  ))
  bot.objects[downObjectId].present = false
  bot.lowHealth = true
  doAssert bot.targetScore(Target(
    found: true,
    kind: TargetHeart,
    x: 120,
    y: 0
  )) < bot.targetScore(Target(
    found: true,
    kind: TargetMob,
    x: 40,
    y: 0
  ))
  bot.lowHealth = false
  bot.needsRegroup = true
  doAssert bot.targetScore(Target(
    found: true,
    kind: TargetRegroup,
    x: 96,
    y: 0
  )) < bot.targetScore(Target(
    found: true,
    kind: TargetWaystation,
    x: 96,
    y: 0
  ))
  doAssert bot.targetScore(Target(
    found: true,
    kind: TargetWaystation,
    x: 96,
    y: 0
  )) < bot.targetScore(Target(
    found: true,
    kind: TargetTroll,
    x: 48,
    y: 0
  ))
  bot.needsRegroup = false
  bot.playerWorldX = 1200
  bot.playerWorldY = 190
  bot.frontierX = 1458
  doAssert not bot.canConsiderThreatTarget(Target(
    found: true,
    kind: TargetMob,
    x: 1154,
    y: 190
  ))
  doAssert bot.canConsiderThreatTarget(Target(
    found: true,
    kind: TargetMob,
    x: 1180,
    y: 190
  ))
  bot.frontierX = 0
  bot.playerWorldX = 1000
  bot.playerWorldY = 300
  bot.objectiveHint = ""
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetRelic,
    objectId: LandmarkObjectBase + 20,
    x: bot.playerWorldX + OpportunisticObjectiveRadius + 1,
    y: bot.playerWorldY
  ))
  doAssert bot.canConsiderPickupTarget(Target(
    kind: TargetShrine,
    objectId: LandmarkObjectBase + 21,
    x: bot.playerWorldX + OpportunisticObjectiveRadius,
    y: bot.playerWorldY
  ))
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetRescue,
    objectId: LandmarkObjectBase + 22,
    x: bot.playerWorldX - BacktrackLootSlack - 1,
    y: bot.playerWorldY
  ))
  bot.objectiveHint = "next relic 0/3"
  doAssert bot.canConsiderPickupTarget(Target(
    kind: TargetRelic,
    objectId: LandmarkObjectBase + 23,
    x: bot.playerWorldX + OpportunisticObjectiveRadius + 1,
    y: bot.playerWorldY
  ))
  bot.objectiveHint = "next forage h"
  doAssert bot.canConsiderPickupTarget(Target(
    kind: TargetWaystation,
    objectId: LandmarkObjectBase + 24,
    x: bot.playerWorldX + OpportunisticObjectiveRadius + 1,
    y: bot.playerWorldY
  ))
  bot.lowHealth = false
  bot.needsRegroup = false
  bot.needsRole = false
  bot.hasRole = true
  bot.objectiveHint = ""
  bot.carriedItem = CarryNone
  bot.needWood = 0
  bot.needStone = 0
  bot.playerWorldX = 80
  bot.playerWorldY = 300
  bot.hasExploreGoal = false
  blocked.resetBlocked()
  pickups.setLen(0)
  allies.setLen(0)
  pickups = @[Target(
    found: true,
    kind: TargetRelic,
    objectId: LandmarkObjectBase + 25,
    x: bot.playerWorldX + OpportunisticObjectiveRadius + 80,
    y: bot.playerWorldY,
    label: "relic"
  )]
  mobs = @[Target(
    found: true,
    kind: TargetMob,
    objectId: 42,
    x: 320,
    y: 332,
    label: "hunt"
  )]
  let pushChoice = bot.chooseTarget(blocked, pickups, allies, mobs)
  doAssert pushChoice.kind == TargetExplore
  doAssert pushChoice.x > bot.playerWorldX
  pickups.setLen(0)

  bot.hasExploreGoal = false
  bot.playerWorldX = 420
  bot.playerWorldY = ExpeditionLaneMinY - ExpeditionLaneRecoverySlack - 8
  let laneRecovery = bot.expeditionLaneRecoveryTarget()
  doAssert laneRecovery.found
  doAssert laneRecovery.kind == TargetExplore
  doAssert laneRecovery.x > bot.playerWorldX
  doAssert laneRecovery.y == ExpeditionLaneMinY
  let laneChoice = bot.chooseTarget(blocked, pickups, allies, mobs)
  doAssert laneChoice.kind == TargetExplore
  doAssert laneChoice.y == ExpeditionLaneMinY
  bot.hasExploreGoal = false
  bot.refreshExploreGoal(blocked)
  doAssert bot.exploreY >= ExpeditionLaneMinY
  doAssert bot.exploreY <= ExpeditionLaneMaxY

  bot.hasExploreGoal = false
  bot.playerWorldX = 80
  bot.playerWorldY = 300
  mobs = @[Target(
    found: true,
    kind: TargetMob,
    objectId: 43,
    x: 104,
    y: 300,
    label: "hunt"
  )]
  let closeThreatChoice = bot.chooseTarget(blocked, pickups, allies, mobs)
  doAssert closeThreatChoice.kind == TargetMob

  bot.currentTargetKind = TargetExplore
  bot.currentTargetId = -1
  bot.currentTargetX = 400
  bot.currentTargetY = 300
  bot.playerWorldX = 80
  bot.playerWorldY = 300
  let pushUnstuck = bot.directedUnstuckMask()
  doAssert (pushUnstuck and ButtonRight) != 0
  doAssert (pushUnstuck and ButtonLeft) == 0

  bot.exploreDetourIndex = 0
  bot.lastExploreStuckTick = 0
  bot.hasExploreGoal = true
  bot.currentTargetKind = TargetExplore
  bot.currentTargetId = -1
  bot.currentTargetX = 400
  bot.currentTargetY = 300
  bot.playerWorldX = 80
  bot.playerWorldY = 300
  bot.previousPlayerX = 80
  bot.previousPlayerY = 300
  bot.havePlayerSample = true
  bot.lastMask = ButtonRight
  bot.stuckFrames = StuckFrameThreshold - 1
  bot.frameTick = 500
  bot.updateStuck()
  doAssert bot.exploreDetourIndex != 0
  doAssert bot.lastExploreStuckTick == 500
  doAssert not bot.hasExploreGoal
  doAssert (bot.jiggleMask and ButtonRight) == 0
  doAssert (bot.jiggleMask and ButtonDown) != 0
  blocked.resetBlocked()
  bot.refreshExploreGoal(blocked)
  doAssert bot.exploreY > bot.playerWorldY
  bot.frameTick = 500 + ExploreDetourResetTicks
  bot.resetExploreDetourIfCalm()
  doAssert bot.exploreDetourIndex == 0

  bot.currentTargetKind = TargetDpsRole
  bot.currentTargetId = 7
  bot.currentTargetX = 40
  let roleUnstuck = bot.directedUnstuckMask()
  doAssert (roleUnstuck and ButtonLeft) != 0
  doAssert (roleUnstuck and ButtonRight) == 0

  bot.skipTargetId = -1
  bot.skipTicks = 0
  bot.currentTargetId = 99
  bot.currentTargetKind = TargetCamp
  bot.campResourceSearchTicks = 0
  bot.playerWorldX = 80
  bot.playerWorldY = 300
  for _ in 0 .. CampActivationStallTicks:
    bot.rememberTarget(Target(
      found: true,
      kind: TargetCamp,
      objectId: 99,
      x: 84,
      y: 304,
      label: "camp"
    ))
  doAssert bot.skipTargetId == 99
  doAssert bot.skipTicks == CampResourceSearchTicks
  doAssert bot.campResourceSearchTicks == CampResourceSearchTicks
  doAssert not bot.canConsiderPickupTarget(Target(
    kind: TargetCamp,
    objectId: 99
  ))
  doAssert bot.targetScore(Target(
    found: true,
    kind: TargetStone,
    x: 120,
    y: 300
  )) < bot.targetScore(Target(
    found: true,
    kind: TargetCamp,
    x: 84,
    y: 304
  ))

  bot.havePlayerSample = true
  bot.previousPlayerX = 10
  bot.previousPlayerY = 10
  bot.playerWorldX = 11
  bot.playerWorldY = 10
  bot.lastMask = ButtonRight
  bot.stuckFrames = StuckFrameThreshold - 1
  bot.updateStuck()
  doAssert bot.stuckFrames == 0
  echo "Konrad target tests passed"

elif isMainModule:
  var
    address = DefaultHost
    port = PlayerDefaultPort
    name = "konrad"
    token = ""
    slot = ""
    chat = false
    maxSteps = 0
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "port":
        port = parseInt(val)
      of "name":
        name = val
      of "token":
        token = val
      of "slot":
        slot = val
      of "chat":
        chat = true
      of "max-steps":
        maxSteps = parseInt(val)
      else:
        discard
    else:
      discard
  runBot(address, port, name, token, slot, chat, maxSteps)

import std/[json, os, random, strutils]
import bitworld/aseprite
import pixie, bitworld/protocol
import bitworld/[pixelfonts, server]

const
  ArtCellSize* = 32
  WorldTileSize* = ArtCellSize
  SheetTileSize* = ArtCellSize
  GameName* = "party_progressor"
  GameVersion* = "1"
  ReplayMagic* = "BITWORLD"
  ReplayFormatVersion* = 3'u16
  ReplayTickHashRecord* = 0x01'u8
  ReplayInputRecord* = 0x02'u8
  ReplayJoinRecord* = 0x03'u8
  ReplayLeaveRecord* = 0x04'u8
  ReplayFps* = 60
  SafeZoneRightTiles* = 8
  BiomeCount* = 7
  ExpeditionBiomeSpanTiles* = 21
  ExpeditionCycleCount* = 4
  WorldWidthTiles* =
    SafeZoneRightTiles + ExpeditionBiomeSpanTiles * BiomeCount * ExpeditionCycleCount
  WorldHeightTiles* = 18
  WorldWidthPixels* = WorldWidthTiles * WorldTileSize
  WorldHeightPixels* = WorldHeightTiles * WorldTileSize
  PlayerViewportTiles* = 11
  PlayerViewportWidth* = PlayerViewportTiles * WorldTileSize
  PlayerViewportHeight* = PlayerViewportTiles * WorldTileSize
  GlobalViewportTiles* = 64
  GlobalViewportWidth* = GlobalViewportTiles * WorldTileSize
  GlobalViewportHeight* = WorldHeightPixels
  SafeZoneRightPixels* = SafeZoneRightTiles * WorldTileSize
  ZoneWidthTiles* = 8
  ZoneWidthPixels* = ZoneWidthTiles * WorldTileSize
  LaneHalfHeightTiles* = 4
  RiverSystemStrideSegments* = 4
  RiverSystemSpanSegments* = 1
  RiverDeepHalfWidthTiles* = 0
  RiverShallowHalfWidthTiles* = 1
  RiverAmbushMobCount* = 3
  RiverAmbushBankOffsetTiles* = 5
  TargetMobCount* = 108
  TerrainPatchDivisor* = 52
  MinMobSpacing* = 24
  MinPlayerSpawnSpacing* = 24
  SwooshDistanceDivisor* = 3
  SwooshPlacementOffset* = 6
  MotionScale* = 256
  Accel* = 46
  FrictionNum* = 200
  FrictionDen* = 256
  MaxSpeed* = 320
  StopThreshold* = 8
  PlayerFootSize* = 8
  PlayerSeparationPasses* = 4
  BasePlayerHp* = 5
  TankPlayerHp* = 9
  HealerPlayerHp* = 6
  UnarmedPlayerHp* = 4
  MaxPlayerLives* = TankPlayerHp
  SnakeHp* = 3
  TrollHp* = 6
  BossHp* = 18
  WolfHp* = 4
  BearHp* = 10
  GoblinHp* = 5
  ScorpionHp* = 4
  SlimeHp* = 5
  YetiHp* = 12
  BatHp* = 3
  WraithHp* = 8
  MobSpeciesSpriteBase* = 760
  MobSpeciesSpriteSlots* = 128
  TrollCoinValue* = 10
  BossCoinValue* = 100
  ObjectiveScoreValue* = 25
  SideObjectiveScoreValue* = 20
  CampScoreValue* = 10
  RelicScoreValue* = 40
  BossScoreValue* = 150
  FinalGateScoreValue* = 250
  BiomeMasteryScoreValue* = 40
  BiomeMasteryRequiredMilestones* = 3
  BiomeMasteryStatusRecoveryTicks* = 1
  BiomeMasteryCooldownStep* = 1
  BiomeMasteryDamageBonus* = 1
  BiomeMasteryMinSpeedPercent* = 96
  FinalGateRelicCost* = 3
  FinalGateCampCost* = 2
  BeaconSurveyRadius* = WorldTileSize * 3
  BeaconSurveyBackTiles* = 1
  BeaconSurveyForwardTiles* = 5
  BeaconSurveyHalfHeightTiles* = 1
  ShrineFoodBonus* = 2
  ShrineHealAmount* = 1
  ShrineBlessingRadius* = WorldTileSize * 2
  RescueFoodBonus* = 2
  RescueHealAmount* = 1
  LairHp* = 6
  LairFoodBonus* = 1
  LairStoneBonus* = 1
  LairPacifyRadius* = WorldTileSize * 3
  LairHunterDamageBonus* = 1
  BiomeWaystationFastStep* = 2
  BiomeWaystationFoodBonus* = 1
  BiomeWaystationHealAmount* = 1
  BiomeWaystationPacifyRadius* = WorldTileSize * 3
  BiomeWaystationShelterRadius* = WorldTileSize * 2
  BiomeWaystationRouteBackTiles* = 1
  BiomeWaystationRouteForwardTiles* = 5
  BiomeWaystationRouteHalfHeightTiles* = 1
  CampWoodCost* = 2
  CampStoneCost* = 1
  CampFortifiedFlag* = 1
  CampProvisionedFlag* = 2
  CampWardedFlag* = 4
  CampRallyFlag* = 8
  CampAidFlag* = 16
  CampFortificationWoodCost* = 1
  CampFortificationStoneCost* = 1
  CampProvisionFoodCost* = 2
  CampWardStoneCost* = 1
  CampRallyWoodCost* = 1
  CampAidFoodCost* = 1
  CampFortificationRadius* = WorldTileSize * 3
  CampWardedDefenseRadius* = WorldTileSize * 4
  ResourceNodeHp* = 2
  LandmarkActivationRadius* = 20
  FinalGateActivationRadius* = WorldTileSize * 2
  FinalGateRallyPacifyRadius* = WorldTileSize * 3
  FinalGateTriumphRadius* = WorldTileSize * 6
  TankGuardRadius* = 44
  HealerPulseRadius* = 46
  DpsBeamTiles* = 5
  DpsBeamWidth* = 18
  DpsBeamDamage* = 2
  TargetFps* = 60
  BiomeMasteryMoraleTicks* = TargetFps * 14
  LairHunterTicks* = TargetFps * 10
  LairRespawnCooldownBonus* = TargetFps * 2
  BiomeWaystationTicks* = TargetFps
  BiomeWaystationRouteTicks* = TargetFps * 10
  BiomeWaystationRouteMinSpeedPercent* = 88
  BeaconAttunementTicks* = TargetFps
  DpsBeaconAttunementStep* = 2
  CooperativeObjectiveHoldMaxStep* = 4
  FinalGateRitualTicks* = TargetFps * 2
  FinalGateTriumphTicks* = TargetFps * 12
  ObjectiveMoraleTicks* = TargetFps * 8
  ObjectiveMoraleSpeedPercent* = 106
  ObjectiveMoraleCooldownStep* = 1
  BeaconSurveyTicks* = TargetFps * 10
  BeaconSurveyMinSpeedPercent* = 90
  FinalGateTwoRoleStep* = 2
  FinalGateThreeRoleStep* = 3
  RoleAbilityCooldown* = 36
  RoleAbilityEffectTicks* = 18
  HealerPulseHoldTicks* = TargetFps div 2
  MaxPlayerMana* = 10
  TankGuardManaCost* = 3
  DpsBeamManaCost* = 4
  HealerPulseManaCost* = 5
  ManaRegenIntervalTicks* = TargetFps div 2
  TankMovementSpeedPercent* = 96
  DpsMovementSpeedPercent* = 116
  HealerMovementSpeedPercent* = 106
  UnarmedMovementSpeedPercent* = 104
  PingDurationTicks* = TargetFps * 4
  DownedRespawnTicks* = TargetFps * 4
  DownedRescueTicks* = TargetFps * 2
  DownedRescueRadius* = WorldTileSize * 2
  DownedReviveHp* = 2
  HealerDownedRescueStep* = 2
  RescueEventTicks* = TargetFps * 2
  HealerRescueEventStep* = 2
  RescueTrailBackTiles* = 1
  RescueTrailForwardTiles* = 4
  RescueTrailHalfHeightTiles* = 1
  RescueGuideTicks* = TargetFps * 10
  RescueGuideSpeedPercent* = 112
  RescueGuideStatusRecoveryTicks* = 1
  PickupCollectionRadius* = WorldTileSize
  TankGuardTicks* = 24
  TankDamageReductionPct* = 50
  HealerPulseAmount* = 2
  HealerTriageRadius* = WorldTileSize * 2
  HealerTriageIntervalTicks* = TargetFps * 2
  HealerTriageHealAmount* = 1
  LowHealthHelpThresholdPercent* = 50
  FoodHealAmount* = 2
  CarriedFoodShareRadius* = WorldTileSize * 2
  ColdExposureIntervalTicks* = TargetFps * 3
  HeatExposureIntervalTicks* = TargetFps * 4
  FogDisorientationIntervalTicks* = TargetFps * 5
  FogDisorientationTicks* = TargetFps
  ExhaustionIntervalTicks* = TargetFps * 7
  StatusExhaustionTicks* = TargetFps * 4
  SwampMireIntervalTicks* = TargetFps * 4
  SwampMireTicks* = TargetFps
  CampShelterRadius* = WorldTileSize * 2
  CampRecoveryIntervalTicks* = TargetFps * 2
  CampRecoveryHealAmount* = 1
  CampProvisionedRecoveryHealAmount* = 2
  CampMealRationTicks* = TargetFps * 18
  CampStatusRecoveryTicks* = TargetFps div 2
  CampAidStatusRecoveryTicks* = TargetFps div 2
  CampRallyAbilityCooldownStep* = 1
  ForestForageIntervalTicks* = TargetFps * 5
  ForestForageFoodCap* = 2
  PlainsRallyAllyRadius* = WorldTileSize * 3
  PlainsRallyCooldownStep* = 1
  TrioFormationRadius* = WorldTileSize * 3
  TrioFormationCooldownStep* = 1
  SnowWarmthAllyRadius* = WorldTileSize * 3
  DesertShadeRadius* = WorldTileSize * 2
  SwampPlankForwardTiles* = 3
  StoneStepForwardTiles* = 3
  StoneStepMaxElevation* = 1
  CampShortcutBackTiles* = 2
  CampShortcutForwardTiles* = 8
  CampShortcutHalfHeightTiles* = 1
  StatusSlowTicks* = TargetFps * 2
  StatusChillTicks* = TargetFps * 3
  StatusPoisonTicks* = TargetFps * 4
  StatusPoisonIntervalTicks* = TargetFps
  StatusSlowSpeedPercent* = 62
  StatusChillSpeedPercent* = 78
  StatusExhaustionSpeedPercent* = 72
  IsolationThreatRadius* = WorldTileSize * 3
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  RewardWebSocketPath* = "/reward"
  BackgroundColor* = 12'u8
  HealthBarGray* = 1'u8
  HealthBarGreen* = 10'u8
  HealthBarYellow* = 8'u8
  HealthBarRed* = 3'u8
  RadarRange* = 128
  RadarColorSnake* = 10'u8
  RadarColorBoss* = 3'u8
  PlayerColors* = [2'u8, 7, 8, 14, 4, 11, 13, 15]
  MessageCharsPerLine* = 24
  MessageLineCount* = 4
  MessageMaxChars* = MessageCharsPerLine * MessageLineCount
  MapSpriteId* = 1
  MapObjectId* = 1
  MapChunkTileWidth* = 8
  MapChunkWidthPixels* = MapChunkTileWidth * WorldTileSize
  MapChunkCount* =
    (WorldWidthTiles + MapChunkTileWidth - 1) div MapChunkTileWidth
  MapChunkSpriteBase* = 20000
  MapChunkObjectBase* = 21000
  MapLayerId* = 0
  MapLayerType* = 0
  TopLeftLayerId* = 1
  TopLeftLayerType* = 1
  TopRightLayerId* = 2
  TopRightLayerType* = 2
  BottomRightLayerId* = 3
  BottomRightLayerType* = 3
  ReplayCenterBottomLayerId* = 8
  ReplayBottomLeftLayerId* = 9
  ReplayCenterBottomLayerType* = 8
  ReplayBottomLeftLayerType* = 4
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  PlayerSpriteBase* = 100
  SelectedPlayerSpriteBase* = 200
  MobSpriteId* = 300
  BossSpriteId* = 301
  CoinSpriteId* = 302
  HeartSpriteId* = 303
  SwooshSpriteBase* = 304
  TrollSpriteId* = 312
  TerrainSpriteBase* = 320
  LandmarkSpriteBase* = 360
  SelectedTextSpriteId* = 400
  SelectedViewportSpriteId* = 401
  ReplayTickSpriteId* = 402
  ReplayControlsSpriteId* = 403
  ChatSpriteBase* = 500
  PlayerHudSpriteId* = 600
  PlayerObjectBase* = 1000
  MobObjectBase* = 2000
  PickupObjectBase* = 3000
  SelectedTextObjectId* = 4000
  SelectedViewportObjectId* = 4001
  ReplayTickObjectId* = 4002
  ReplayControlsObjectId* = 4003
  ChatObjectBase* = 5000
  AttackObjectBase* = 6000
  PlayerHudObjectId* = 7000
  TerrainObjectBase* = 8000
  LandmarkObjectBase* = 9000
  CoopAttackWindow* = TargetFps
  MobSightRadius* = (WorldTileSize * 3) div 2
  MobChaseCooldown* = 4
  MobSpawnWanderCooldown* = 16
  MobSpawnWanderJitter* = 36
  MobWanderCooldown* = 16
  MobWanderJitter* = 40
  MobTelegraphTicks* = TargetFps
  MobTelegraphBounces* = 2
  MobTelegraphLift* = 4
  MobLungeTicks* = 10
  MobLungeStep* = 2
  PartyFocusTwoRoleDamageBonus* = 1
  PartyFocusThreeRoleDamageBonus* = 2
  BossTrioDamageBonus* = 1
  BossFocusDamageBonus* = 2
  BossStaggerTicks* = TargetFps * 2
  BossStaggerAttackCooldown* = TargetFps
  ElevationCombatThreshold* = 2
  HighGroundDamageBonus* = 1
  LowGroundDamagePenalty* = 1
  TribalAssetManifestName* = "tribalcog_assets.json"

type
  PlayerForm* = enum
    MalePlayer
    FemalePlayer

  PlayerPose* = enum
    PlayerFront
    PlayerSide
    PlayerBack

  PlayerRole* = enum
    RoleUnarmed
    RoleTank
    RoleDps
    RoleHealer

  PlayerPingKind* = enum
    PingNone
    PingRegroup
    PingHelp
    PingObjective
    PingCamp
    PingFood
    PingRescue
    PingLair

  CarryKind* = enum
    CarryNone
    CarryWood
    CarryFood
    CarryStone
    CarryGold

  ArmorSlot* = enum
    ArmorHead
    ArmorChest
    ArmorTrinket

  ArmorKind* = enum
    ArmorNone
    ArmorScoutHood
    ArmorIronHelm
    ArmorFurHood
    ArmorLeatherVest
    ArmorScaleMail
    ArmorFrostCloak
    ArmorVenomCharm
    ArmorLanternCharm
    ArmorRallyHorn

  TerrainKind* = enum
    TerrainTree
    TerrainEvergreen
    TerrainRock
    TerrainLog
    TerrainStump
    TerrainBush
    TerrainCactus
    TerrainWheat
    TerrainFish
    TerrainStone
    TerrainGold
    TerrainCave
    TerrainGoblinHut
    TerrainGoblinTotem
    TerrainAltar
    TerrainCamp

  RgbaSprite* = object
    width*, height*: int
    pixels*: seq[uint8]

  SpriteBounds* = object
    x*, y*, w*, h*: int

  PlayerArt* = object
    sprites*: array[PlayerPose, Sprite]
    rgbaSprites*: array[PlayerPose, RgbaSprite]
    masks*: array[PlayerPose, Sprite]
    bounds*: array[PlayerPose, SpriteBounds]
    swoosh*: Sprite
    rgbaSwoosh*: RgbaSprite
    swooshBounds*: SpriteBounds

  Actor* = object
    id*: int
    address*: string
    x*, y*: int
    form*: PlayerForm
    sprite*: Sprite
    bounds*: SpriteBounds
    facing*: Facing
    attackTicks*: int
    attackResolved*: bool
    message*: string
    pingKind*: PlayerPingKind
    pingTicks*: int
    velX*: int
    velY*: int
    carryX*: int
    carryY*: int
    role*: PlayerRole
    maxHp*: int
    mana*: int
    abilityCooldown*: int
    abilityTicks*: int
    abilityHoldTicks*: int
    guardTicks*: int
    personalFrontier*: int
    damageDone*: int
    healingDone*: int
    damageBlocked*: int
    messagesSent*: int
    lives*: int
    invulnTicks*: int
    coins*: int
    distanceWalked*: int
    carrying*: bool
    carriedItem*: CarryKind
    carryCounts*: array[CarryKind, int]
    armor*: array[ArmorSlot, ArmorKind]
    carrySelectLockTicks*: int
    slowTicks*: int
    chillTicks*: int
    poisonTicks*: int
    exhaustionTicks*: int
    routeTicks*: int
    surveyTicks*: int
    guideTicks*: int
    huntTicks*: int
    triumphTicks*: int
    rationTicks*: int
    moraleTicks*: int
    downedTicks*: int
    rescueTicks*: int

  PickupKind* = enum
    PickupCoin
    PickupHeart
    PickupTankGear
    PickupDpsGear
    PickupHealerGear
    PickupWood
    PickupFood
    PickupStone
    PickupGold
    PickupArmor

  MobKind* = enum
    SnakeMob
    TrollMob
    BossMob
    WolfMob
    BearMob
    GoblinMob
    ScorpionMob
    SlimeMob
    YetiMob
    BatMob
    WraithMob

  MobSpecies* = enum
    SpeciesNone
    SpeciesGrassSnake
    SpeciesForestWolf
    SpeciesDireWolf
    SpeciesPackAlpha
    SpeciesThornBoar
    SpeciesThornMender
    SpeciesBrownBear
    SpeciesPlainsWolf
    SpeciesPrairieGoblin
    SpeciesBannerGoblin
    SpeciesNetThrower
    SpeciesPlainsBear
    SpeciesHornedBuck
    SpeciesMudSlime
    SpeciesReedSlime
    SpeciesBogGoblin
    SpeciesBogWitch
    SpeciesLeechSwarm
    SpeciesMarshWraith
    SpeciesDuneScorpion
    SpeciesGlassScorpion
    SpeciesFireScorpion
    SpeciesSandViper
    SpeciesDustHyena
    SpeciesSandBurrower
    SpeciesTombScarab
    SpeciesSnowWolf
    SpeciesFrostYeti
    SpeciesIceTroll
    SpeciesIceShaman
    SpeciesWhiteBear
    SpeciesSnowBat
    SpeciesSnowStalker
    SpeciesCaveBat
    SpeciesCrystalBat
    SpeciesCrystalSeer
    SpeciesCaveSlime
    SpeciesStoneGoblin
    SpeciesDeepMaw
    SpeciesRuinWraith
    SpeciesAshWraith
    SpeciesBoneGoblin
    SpeciesRuinNecromancer
    SpeciesGateTitan

  MobAttackPhase* = enum
    MobIdle
    MobTelegraph
    MobLunge

  MobAttackStyle* = enum
    AttackLunge
    AttackRanged
    AttackSlam
    AttackAura
    AttackCone
    AttackLine
    AttackTrap
    AttackSupport
    AttackSwarm

  BiomeKind* = enum
    BiomeOrigin
    BiomeForest
    BiomePlains
    BiomeSwamp
    BiomeDesert
    BiomeSnow
    BiomeCave
    BiomeRuins

  WeatherKind* = enum
    WeatherClear
    WeatherRain
    WeatherDust
    WeatherSnow
    WeatherFog

  SurvivalPressureKind* = enum
    SurvivalSafe
    SurvivalMire
    SurvivalCold
    SurvivalHeat
    SurvivalFog

  BiomeTacticKind* = enum
    BiomeTacticNone
    BiomeTacticMastery
    BiomeTacticForage
    BiomeTacticRally
    BiomeTacticShade
    BiomeTacticWarmth
    BiomeTacticLight
    BiomeTacticGuard
    BiomeTacticBlessing

  PlayerEffectVisualKind* = enum
    EffectVisualPoison
    EffectVisualSlow
    EffectVisualChill
    EffectVisualExhaustion
    EffectVisualMire
    EffectVisualCold
    EffectVisualHeat
    EffectVisualFog
    EffectVisualRoute
    EffectVisualSurvey
    EffectVisualGuide
    EffectVisualHunt
    EffectVisualTriumph
    EffectVisualRation
    EffectVisualMorale
    EffectVisualMastery
    EffectVisualGuard
    EffectVisualBlessing
    EffectVisualForage
    EffectVisualRally
    EffectVisualShade
    EffectVisualWarmth
    EffectVisualLight
    EffectVisualTrio

  PlayerEffectInfo* = object
    key*, label*, description*: string
    harmful*: bool
    visual*: PlayerEffectVisualKind

  GroundKind* = enum
    GroundGrass
    GroundRoad
    GroundFertile
    GroundMud
    GroundShallowWater
    GroundWater
    GroundSand
    GroundDune
    GroundSnow
    GroundCave
    GroundRuins
    GroundBridge

  LandmarkKind* = enum
    LandmarkWood
    LandmarkFood
    LandmarkStone
    LandmarkGold
    LandmarkCamp
    LandmarkBeacon
    LandmarkFinalGate
    LandmarkShrine
    LandmarkRescue
    LandmarkLair
    LandmarkWaystation

  Pickup* = object
    x*, y*: int
    kind*: PickupKind
    value*: int

  Mob* = object
    kind*: MobKind
    species*: MobSpecies
    x*, y*: int
    sprite*: Sprite
    bounds*: SpriteBounds
    wanderCooldown*: int
    hp*: int
    attackCooldown*: int
    attackPhase*: MobAttackPhase
    attackTicks*: int
    staggerTicks*: int
    attackFacing*: Facing
    attackerIds*: seq[int]
    attackerTicks*: seq[int]

  TerrainProp* = object
    tx*, ty*: int
    kind*: TerrainKind

  Landmark* = object
    tx*, ty*: int
    kind*: LandmarkKind
    hp*: int
    done*: bool
    progress*: int

  RiverCrossing* = object
    tx*, ty*: int
    firstTy*, lastTy*: int
    triggered*: bool

  GuideFollower* = object
    x*, y*: int
    targetPlayerId*: int
    thanksTicks*: int
    done*: bool

  SimServer* = object
    players*: seq[Actor]
    mobs*: seq[Mob]
    pickups*: seq[Pickup]
    tiles*: seq[bool]
    groundKinds*: seq[GroundKind]
    biomeKinds*: seq[BiomeKind]
    elevations*: seq[int]
    terrainKinds*: seq[TerrainKind]
    terrainProps*: seq[TerrainProp]
    landmarks*: seq[Landmark]
    riverCrossings*: seq[RiverCrossing]
    guides*: seq[GuideFollower]
    playerArts*: array[PlayerForm, PlayerArt]
    playerSprite*: Sprite
    terrainSprite*: Sprite
    rgbaTerrainSprite*: RgbaSprite
    groundSprites*: array[GroundKind, Sprite]
    rgbaGroundSprites*: array[GroundKind, RgbaSprite]
    terrainSprites*: array[TerrainKind, Sprite]
    rgbaTerrainSprites*: array[TerrainKind, RgbaSprite]
    terrainBounds*: array[TerrainKind, SpriteBounds]
    landmarkSprites*: array[LandmarkKind, Sprite]
    rgbaLandmarkSprites*: array[LandmarkKind, RgbaSprite]
    landmarkBounds*: array[LandmarkKind, SpriteBounds]
    roleGearSprites*: array[PickupKind, Sprite]
    roleGearRgbaSprites*: array[PickupKind, RgbaSprite]
    roleGearBounds*: array[PickupKind, SpriteBounds]
    armorSprites*: array[ArmorKind, Sprite]
    armorRgbaSprites*: array[ArmorKind, RgbaSprite]
    armorBounds*: array[ArmorKind, SpriteBounds]
    mobSpeciesSprites*: array[MobSpecies, Sprite]
    mobSpeciesRgbaSprites*: array[MobSpecies, RgbaSprite]
    mobSpeciesBounds*: array[MobSpecies, SpriteBounds]
    mobSpeciesGeneratedSprites*: array[MobSpecies, bool]
    mobSprite*: Sprite
    rgbaMobSprite*: RgbaSprite
    mobBounds*: SpriteBounds
    trollSprite*: Sprite
    rgbaTrollSprite*: RgbaSprite
    trollBounds*: SpriteBounds
    bossSprite*: Sprite
    rgbaBossSprite*: RgbaSprite
    bossBounds*: SpriteBounds
    heartSprite*: Sprite
    rgbaHeartSprite*: RgbaSprite
    heartBounds*: SpriteBounds
    coinSprite*: Sprite
    rgbaCoinSprite*: RgbaSprite
    coinBounds*: SpriteBounds
    textFont*: PixelFont
    fb*: Framebuffer
    rng*: Rand
    seed*: int
    tickCount*: int
    scoreRevision*: int
    mobSpawnCooldown*: int
    nextPlayerId*: int
    teamFrontier*: int
    maxBiomeReached*: int
    objectivesCompleted*: int
    sideObjectivesCompleted*: int
    campsActivated*: int
    biomeMastered*: array[BiomeKind, bool]
    resourcesCollected*: int
    wood*: int
    food*: int
    stone*: int
    relicShards*: int
    bossDefeated*: bool

const
  CarryInventoryKinds*: array[4, CarryKind] = [
    CarryWood,
    CarryFood,
    CarryStone,
    CarryGold
  ]

  AllMobSpecies*: array[44, MobSpecies] = [
    SpeciesGrassSnake,
    SpeciesForestWolf,
    SpeciesDireWolf,
    SpeciesPackAlpha,
    SpeciesThornBoar,
    SpeciesThornMender,
    SpeciesBrownBear,
    SpeciesPlainsWolf,
    SpeciesPrairieGoblin,
    SpeciesBannerGoblin,
    SpeciesNetThrower,
    SpeciesPlainsBear,
    SpeciesHornedBuck,
    SpeciesMudSlime,
    SpeciesReedSlime,
    SpeciesBogGoblin,
    SpeciesBogWitch,
    SpeciesLeechSwarm,
    SpeciesMarshWraith,
    SpeciesDuneScorpion,
    SpeciesGlassScorpion,
    SpeciesFireScorpion,
    SpeciesSandViper,
    SpeciesDustHyena,
    SpeciesSandBurrower,
    SpeciesTombScarab,
    SpeciesSnowWolf,
    SpeciesFrostYeti,
    SpeciesIceTroll,
    SpeciesIceShaman,
    SpeciesWhiteBear,
    SpeciesSnowBat,
    SpeciesSnowStalker,
    SpeciesCaveBat,
    SpeciesCrystalBat,
    SpeciesCrystalSeer,
    SpeciesCaveSlime,
    SpeciesStoneGoblin,
    SpeciesDeepMaw,
    SpeciesRuinWraith,
    SpeciesAshWraith,
    SpeciesBoneGoblin,
    SpeciesRuinNecromancer,
    SpeciesGateTitan
  ]

proc roleLabel*(role: PlayerRole): string =
  case role
  of RoleUnarmed:
    "unarmed"
  of RoleTank:
    "tank"
  of RoleDps:
    "dps"
  of RoleHealer:
    "healer"

proc biomeLabel*(biome: BiomeKind): string =
  case biome
  of BiomeOrigin: "origin"
  of BiomeForest: "forest"
  of BiomePlains: "plains"
  of BiomeSwamp: "swamp"
  of BiomeDesert: "desert"
  of BiomeSnow: "snow"
  of BiomeCave: "cave"
  of BiomeRuins: "ruins"

proc weatherLabel*(weather: WeatherKind): string =
  case weather
  of WeatherClear: "clear"
  of WeatherRain: "rain"
  of WeatherDust: "dust"
  of WeatherSnow: "snow"
  of WeatherFog: "fog"

proc speciesLabel*(species: MobSpecies): string =
  case species
  of SpeciesNone: "monster"
  of SpeciesGrassSnake: "grass snake"
  of SpeciesForestWolf: "forest wolf"
  of SpeciesDireWolf: "dire wolf"
  of SpeciesPackAlpha: "pack alpha"
  of SpeciesThornBoar: "thorn boar"
  of SpeciesThornMender: "thorn mender"
  of SpeciesBrownBear: "brown bear"
  of SpeciesPlainsWolf: "plains wolf"
  of SpeciesPrairieGoblin: "prairie goblin"
  of SpeciesBannerGoblin: "banner goblin"
  of SpeciesNetThrower: "net thrower"
  of SpeciesPlainsBear: "plains bear"
  of SpeciesHornedBuck: "horned buck"
  of SpeciesMudSlime: "mud slime"
  of SpeciesReedSlime: "reed slime"
  of SpeciesBogGoblin: "bog goblin"
  of SpeciesBogWitch: "bog witch"
  of SpeciesLeechSwarm: "leech swarm"
  of SpeciesMarshWraith: "marsh wraith"
  of SpeciesDuneScorpion: "dune scorpion"
  of SpeciesGlassScorpion: "glass scorpion"
  of SpeciesFireScorpion: "fire scorpion"
  of SpeciesSandViper: "sand viper"
  of SpeciesDustHyena: "dust hyena"
  of SpeciesSandBurrower: "sand burrower"
  of SpeciesTombScarab: "tomb scarab"
  of SpeciesSnowWolf: "snow wolf"
  of SpeciesFrostYeti: "frost yeti"
  of SpeciesIceTroll: "ice troll"
  of SpeciesIceShaman: "ice shaman"
  of SpeciesWhiteBear: "white bear"
  of SpeciesSnowBat: "snow bat"
  of SpeciesSnowStalker: "snow stalker"
  of SpeciesCaveBat: "cave bat"
  of SpeciesCrystalBat: "crystal bat"
  of SpeciesCrystalSeer: "crystal seer"
  of SpeciesCaveSlime: "cave slime"
  of SpeciesStoneGoblin: "stone goblin"
  of SpeciesDeepMaw: "deep maw"
  of SpeciesRuinWraith: "ruin wraith"
  of SpeciesAshWraith: "ash wraith"
  of SpeciesBoneGoblin: "bone goblin"
  of SpeciesRuinNecromancer: "ruin necromancer"
  of SpeciesGateTitan: "gate titan"

proc speciesAssetSlug*(species: MobSpecies): string =
  ## Returns the project-local asset slug for a monster species.
  species.speciesLabel().replace(" ", "_")

proc speciesAssetKey*(species: MobSpecies): string =
  "monster_" & species.speciesAssetSlug()

proc speciesAssetPath*(species: MobSpecies): string =
  "generated/monsters/" & species.speciesAssetSlug() & ".png"

proc speciesKind*(species: MobSpecies): MobKind =
  case species
  of SpeciesNone:
    SnakeMob
  of SpeciesGrassSnake, SpeciesSandViper:
    SnakeMob
  of SpeciesForestWolf, SpeciesDireWolf, SpeciesPlainsWolf,
      SpeciesPackAlpha, SpeciesDustHyena, SpeciesSnowWolf, SpeciesSnowStalker:
    WolfMob
  of SpeciesThornBoar, SpeciesBrownBear, SpeciesPlainsBear,
      SpeciesHornedBuck, SpeciesWhiteBear, SpeciesDeepMaw:
    BearMob
  of SpeciesPrairieGoblin, SpeciesBogGoblin, SpeciesStoneGoblin,
      SpeciesBoneGoblin, SpeciesBannerGoblin, SpeciesNetThrower:
    GoblinMob
  of SpeciesMudSlime, SpeciesReedSlime, SpeciesCaveSlime, SpeciesLeechSwarm:
    SlimeMob
  of SpeciesMarshWraith, SpeciesRuinWraith, SpeciesAshWraith,
      SpeciesBogWitch, SpeciesCrystalSeer, SpeciesRuinNecromancer,
      SpeciesThornMender, SpeciesIceShaman:
    WraithMob
  of SpeciesDuneScorpion, SpeciesGlassScorpion, SpeciesFireScorpion,
      SpeciesTombScarab, SpeciesSandBurrower:
    ScorpionMob
  of SpeciesFrostYeti:
    YetiMob
  of SpeciesIceTroll:
    TrollMob
  of SpeciesSnowBat, SpeciesCaveBat, SpeciesCrystalBat:
    BatMob
  of SpeciesGateTitan:
    BossMob

proc defaultSpeciesForKind*(kind: MobKind): MobSpecies =
  case kind
  of SnakeMob: SpeciesGrassSnake
  of TrollMob: SpeciesIceTroll
  of BossMob: SpeciesGateTitan
  of WolfMob: SpeciesForestWolf
  of BearMob: SpeciesBrownBear
  of GoblinMob: SpeciesPrairieGoblin
  of ScorpionMob: SpeciesDuneScorpion
  of SlimeMob: SpeciesMudSlime
  of YetiMob: SpeciesFrostYeti
  of BatMob: SpeciesCaveBat
  of WraithMob: SpeciesRuinWraith

proc speciesTint*(species: MobSpecies): tuple[r, g, b, a: uint8] =
  case species
  of SpeciesGrassSnake: (r: 84'u8, g: 172'u8, b: 82'u8, a: 255'u8)
  of SpeciesForestWolf: (r: 92'u8, g: 126'u8, b: 96'u8, a: 255'u8)
  of SpeciesDireWolf: (r: 88'u8, g: 92'u8, b: 104'u8, a: 255'u8)
  of SpeciesPackAlpha: (r: 62'u8, g: 78'u8, b: 72'u8, a: 255'u8)
  of SpeciesThornBoar: (r: 127'u8, g: 103'u8, b: 68'u8, a: 255'u8)
  of SpeciesThornMender: (r: 95'u8, g: 150'u8, b: 87'u8, a: 255'u8)
  of SpeciesBrownBear: (r: 134'u8, g: 91'u8, b: 58'u8, a: 255'u8)
  of SpeciesPlainsWolf: (r: 169'u8, g: 148'u8, b: 88'u8, a: 255'u8)
  of SpeciesPrairieGoblin: (r: 174'u8, g: 191'u8, b: 78'u8, a: 255'u8)
  of SpeciesBannerGoblin: (r: 206'u8, g: 96'u8, b: 62'u8, a: 255'u8)
  of SpeciesNetThrower: (r: 154'u8, g: 171'u8, b: 112'u8, a: 255'u8)
  of SpeciesPlainsBear: (r: 170'u8, g: 135'u8, b: 78'u8, a: 255'u8)
  of SpeciesHornedBuck: (r: 192'u8, g: 151'u8, b: 96'u8, a: 255'u8)
  of SpeciesMudSlime: (r: 82'u8, g: 145'u8, b: 96'u8, a: 255'u8)
  of SpeciesReedSlime: (r: 70'u8, g: 177'u8, b: 126'u8, a: 255'u8)
  of SpeciesBogGoblin: (r: 97'u8, g: 151'u8, b: 84'u8, a: 255'u8)
  of SpeciesBogWitch: (r: 95'u8, g: 78'u8, b: 126'u8, a: 255'u8)
  of SpeciesLeechSwarm: (r: 54'u8, g: 112'u8, b: 98'u8, a: 255'u8)
  of SpeciesMarshWraith: (r: 94'u8, g: 132'u8, b: 126'u8, a: 255'u8)
  of SpeciesDuneScorpion: (r: 225'u8, g: 176'u8, b: 66'u8, a: 255'u8)
  of SpeciesGlassScorpion: (r: 229'u8, g: 205'u8, b: 116'u8, a: 255'u8)
  of SpeciesFireScorpion: (r: 232'u8, g: 88'u8, b: 52'u8, a: 255'u8)
  of SpeciesSandViper: (r: 204'u8, g: 161'u8, b: 76'u8, a: 255'u8)
  of SpeciesDustHyena: (r: 164'u8, g: 132'u8, b: 92'u8, a: 255'u8)
  of SpeciesSandBurrower: (r: 187'u8, g: 114'u8, b: 55'u8, a: 255'u8)
  of SpeciesTombScarab: (r: 141'u8, g: 103'u8, b: 58'u8, a: 255'u8)
  of SpeciesSnowWolf: (r: 194'u8, g: 222'u8, b: 234'u8, a: 255'u8)
  of SpeciesFrostYeti: (r: 212'u8, g: 236'u8, b: 248'u8, a: 255'u8)
  of SpeciesIceTroll: (r: 142'u8, g: 201'u8, b: 219'u8, a: 255'u8)
  of SpeciesIceShaman: (r: 118'u8, g: 188'u8, b: 232'u8, a: 255'u8)
  of SpeciesWhiteBear: (r: 235'u8, g: 236'u8, b: 228'u8, a: 255'u8)
  of SpeciesSnowBat: (r: 164'u8, g: 188'u8, b: 224'u8, a: 255'u8)
  of SpeciesSnowStalker: (r: 150'u8, g: 194'u8, b: 215'u8, a: 255'u8)
  of SpeciesCaveBat: (r: 112'u8, g: 90'u8, b: 158'u8, a: 255'u8)
  of SpeciesCrystalBat: (r: 120'u8, g: 182'u8, b: 217'u8, a: 255'u8)
  of SpeciesCrystalSeer: (r: 108'u8, g: 218'u8, b: 212'u8, a: 255'u8)
  of SpeciesCaveSlime: (r: 96'u8, g: 174'u8, b: 154'u8, a: 255'u8)
  of SpeciesStoneGoblin: (r: 128'u8, g: 132'u8, b: 136'u8, a: 255'u8)
  of SpeciesDeepMaw: (r: 93'u8, g: 78'u8, b: 118'u8, a: 255'u8)
  of SpeciesRuinWraith: (r: 122'u8, g: 126'u8, b: 144'u8, a: 255'u8)
  of SpeciesAshWraith: (r: 92'u8, g: 96'u8, b: 104'u8, a: 255'u8)
  of SpeciesBoneGoblin: (r: 205'u8, g: 198'u8, b: 168'u8, a: 255'u8)
  of SpeciesRuinNecromancer: (r: 143'u8, g: 83'u8, b: 153'u8, a: 255'u8)
  of SpeciesGateTitan: (r: 188'u8, g: 80'u8, b: 112'u8, a: 255'u8)
  of SpeciesNone: (r: 255'u8, g: 255'u8, b: 255'u8, a: 255'u8)

proc monsterSpeciesForBiome*(biome: BiomeKind): seq[MobSpecies] =
  case biome
  of BiomeForest:
    @[SpeciesGrassSnake, SpeciesForestWolf, SpeciesDireWolf,
      SpeciesPackAlpha, SpeciesThornBoar, SpeciesThornMender,
      SpeciesBrownBear]
  of BiomePlains:
    @[SpeciesPlainsWolf, SpeciesPrairieGoblin, SpeciesPlainsBear,
      SpeciesBannerGoblin, SpeciesNetThrower, SpeciesHornedBuck]
  of BiomeSwamp:
    @[SpeciesMudSlime, SpeciesReedSlime, SpeciesBogGoblin,
      SpeciesBogWitch, SpeciesLeechSwarm, SpeciesMarshWraith]
  of BiomeDesert:
    @[SpeciesDuneScorpion, SpeciesGlassScorpion, SpeciesSandViper,
      SpeciesFireScorpion, SpeciesDustHyena, SpeciesSandBurrower,
      SpeciesTombScarab]
  of BiomeSnow:
    @[SpeciesSnowWolf, SpeciesFrostYeti, SpeciesIceTroll,
      SpeciesIceShaman, SpeciesWhiteBear, SpeciesSnowBat,
      SpeciesSnowStalker]
  of BiomeCave:
    @[SpeciesCaveBat, SpeciesCrystalBat, SpeciesCaveSlime,
      SpeciesCrystalSeer, SpeciesStoneGoblin, SpeciesDeepMaw]
  of BiomeRuins:
    @[SpeciesRuinWraith, SpeciesAshWraith, SpeciesBoneGoblin,
      SpeciesRuinNecromancer, SpeciesGateTitan]
  else:
    @[SpeciesGrassSnake]

proc randomMonsterSpeciesForBiome(
  rng: var Rand,
  biome: BiomeKind
): MobSpecies =
  let species = biome.monsterSpeciesForBiome()
  species[rng.rand(species.high)]

proc speciesAppliesSlow*(species: MobSpecies): bool =
  species in {
    SpeciesMudSlime,
    SpeciesReedSlime,
    SpeciesCaveSlime,
    SpeciesLeechSwarm,
    SpeciesNetThrower,
    SpeciesSandBurrower
  }

proc speciesAppliesPoison*(species: MobSpecies): bool =
  species in {
    SpeciesDuneScorpion,
    SpeciesGlassScorpion,
    SpeciesFireScorpion,
    SpeciesSandViper,
    SpeciesTombScarab,
    SpeciesBogWitch
  }

proc speciesAppliesChill*(species: MobSpecies): bool =
  species in {
    SpeciesSnowWolf,
    SpeciesFrostYeti,
    SpeciesIceTroll,
    SpeciesIceShaman,
    SpeciesWhiteBear,
    SpeciesSnowBat,
    SpeciesSnowStalker
  }

proc speciesHarasses*(species: MobSpecies): bool =
  species in {
    SpeciesSnowBat,
    SpeciesCaveBat,
    SpeciesCrystalBat,
    SpeciesLeechSwarm,
    SpeciesSnowStalker
  }

proc speciesPunishesIsolation*(species: MobSpecies): bool =
  species in {
    SpeciesMarshWraith,
    SpeciesRuinWraith,
    SpeciesAshWraith,
    SpeciesRuinNecromancer,
    SpeciesBogWitch,
    SpeciesCrystalSeer,
    SpeciesGateTitan
  }

proc speciesLeadsPack*(species: MobSpecies): bool =
  species in {SpeciesPackAlpha, SpeciesBannerGoblin, SpeciesGateTitan}

proc speciesSupportsPack*(species: MobSpecies): bool =
  species in {
    SpeciesThornMender,
    SpeciesBannerGoblin,
    SpeciesBogWitch,
    SpeciesIceShaman,
    SpeciesCrystalSeer,
    SpeciesRuinNecromancer
  }

proc speciesSwarms*(species: MobSpecies): bool =
  species in {SpeciesLeechSwarm, SpeciesTombScarab, SpeciesSnowBat}

proc attackStyle*(species: MobSpecies): MobAttackStyle =
  ## Keeps monster families tactically distinct while sharing one attack phase FSM.
  case species
  of SpeciesDuneScorpion,
      SpeciesGlassScorpion,
      SpeciesSandViper,
      SpeciesTombScarab,
      SpeciesPrairieGoblin,
      SpeciesStoneGoblin,
      SpeciesBoneGoblin,
      SpeciesCaveBat,
      SpeciesCrystalBat,
      SpeciesSnowBat:
    AttackRanged
  of SpeciesFireScorpion,
      SpeciesIceShaman,
      SpeciesCrystalSeer:
    AttackLine
  of SpeciesThornBoar,
      SpeciesBrownBear,
      SpeciesPlainsBear,
      SpeciesHornedBuck,
      SpeciesFrostYeti,
      SpeciesIceTroll,
      SpeciesWhiteBear,
      SpeciesDeepMaw,
      SpeciesGateTitan:
    AttackSlam
  of SpeciesPackAlpha:
    AttackCone
  of SpeciesNetThrower,
      SpeciesSandBurrower,
      SpeciesSnowStalker:
    AttackTrap
  of SpeciesThornMender,
      SpeciesBannerGoblin,
      SpeciesBogWitch,
      SpeciesRuinNecromancer:
    AttackSupport
  of SpeciesLeechSwarm:
    AttackSwarm
  of SpeciesMudSlime,
      SpeciesReedSlime,
      SpeciesCaveSlime,
      SpeciesMarshWraith,
      SpeciesRuinWraith,
      SpeciesAshWraith:
    AttackAura
  else:
    AttackLunge

proc speciesSupplyDrop*(species: MobSpecies): CarryKind =
  ## Returns the expedition supply a defeated biome monster can leave behind.
  case species
  of SpeciesGrassSnake,
      SpeciesForestWolf,
      SpeciesDireWolf,
      SpeciesPackAlpha,
      SpeciesThornBoar,
      SpeciesBrownBear,
      SpeciesPlainsWolf,
      SpeciesPlainsBear,
      SpeciesHornedBuck,
      SpeciesMudSlime,
      SpeciesDuneScorpion,
      SpeciesGlassScorpion,
      SpeciesFireScorpion,
      SpeciesSandViper,
      SpeciesDustHyena,
      SpeciesSandBurrower,
      SpeciesSnowWolf,
      SpeciesFrostYeti,
      SpeciesIceTroll,
      SpeciesIceShaman,
      SpeciesWhiteBear,
      SpeciesSnowBat,
      SpeciesSnowStalker,
      SpeciesCaveBat,
      SpeciesCaveSlime:
    CarryFood
  of SpeciesPrairieGoblin,
      SpeciesBannerGoblin,
      SpeciesNetThrower,
      SpeciesReedSlime,
      SpeciesBogGoblin,
      SpeciesThornMender:
    CarryWood
  of SpeciesStoneGoblin,
      SpeciesDeepMaw,
      SpeciesBoneGoblin,
      SpeciesLeechSwarm:
    CarryStone
  of SpeciesMarshWraith,
      SpeciesBogWitch,
      SpeciesTombScarab,
      SpeciesCrystalBat,
      SpeciesCrystalSeer,
      SpeciesRuinWraith,
      SpeciesAshWraith,
      SpeciesRuinNecromancer:
    CarryGold
  of SpeciesNone,
      SpeciesGateTitan:
    CarryNone

proc landmarkLabel*(kind: LandmarkKind): string =
  case kind
  of LandmarkWood: "wood"
  of LandmarkFood: "food"
  of LandmarkStone: "stone"
  of LandmarkGold: "gold"
  of LandmarkCamp: "camp"
  of LandmarkBeacon: "beacon"
  of LandmarkFinalGate: "final gate"
  of LandmarkShrine: "shrine"
  of LandmarkRescue: "rescue"
  of LandmarkLair: "lair"
  of LandmarkWaystation: "waystation"

proc carryLabel*(kind: CarryKind): string =
  case kind
  of CarryNone: "none"
  of CarryWood: "wood"
  of CarryFood: "food"
  of CarryStone: "stone"
  of CarryGold: "gold"

proc armorLabel*(kind: ArmorKind): string =
  case kind
  of ArmorNone: "none"
  of ArmorScoutHood: "scout hood"
  of ArmorIronHelm: "iron helm"
  of ArmorFurHood: "fur hood"
  of ArmorLeatherVest: "leather vest"
  of ArmorScaleMail: "scale mail"
  of ArmorFrostCloak: "frost cloak"
  of ArmorVenomCharm: "venom charm"
  of ArmorLanternCharm: "lantern charm"
  of ArmorRallyHorn: "rally horn"

proc armorSlot*(kind: ArmorKind): ArmorSlot =
  case kind
  of ArmorScoutHood, ArmorIronHelm, ArmorFurHood:
    ArmorHead
  of ArmorLeatherVest, ArmorScaleMail, ArmorFrostCloak:
    ArmorChest
  of ArmorVenomCharm, ArmorLanternCharm, ArmorRallyHorn:
    ArmorTrinket
  of ArmorNone:
    ArmorTrinket

proc armorBonusLabel*(kind: ArmorKind): string =
  case kind
  of ArmorNone: ""
  of ArmorScoutHood: "+speed"
  of ArmorIronHelm: "+hp"
  of ArmorFurHood: "warm"
  of ArmorLeatherVest: "+speed"
  of ArmorScaleMail: "+guard"
  of ArmorFrostCloak: "cold"
  of ArmorVenomCharm: "venom"
  of ArmorLanternCharm: "light"
  of ArmorRallyHorn: "rally"

proc armorMaxHpBonus*(kind: ArmorKind): int =
  case kind
  of ArmorIronHelm:
    1
  of ArmorScaleMail:
    2
  else:
    0

proc armorSpeedPercentBonus*(kind: ArmorKind): int =
  case kind
  of ArmorScoutHood:
    8
  of ArmorLeatherVest:
    5
  of ArmorScaleMail:
    -6
  else:
    0

proc armorDamageReductionPct*(kind: ArmorKind): int =
  case kind
  of ArmorScaleMail:
    20
  of ArmorIronHelm:
    8
  else:
    0

proc armorStatusRecoveryStep*(kind: ArmorKind): int =
  case kind
  of ArmorVenomCharm, ArmorFurHood, ArmorFrostCloak:
    1
  else:
    0

proc armorProtectsPressure*(kind: ArmorKind, pressure: SurvivalPressureKind): bool =
  case pressure
  of SurvivalCold:
    kind in {ArmorFurHood, ArmorFrostCloak}
  of SurvivalFog:
    kind == ArmorLanternCharm
  else:
    false

proc armorRoleCooldownStep*(kind: ArmorKind): int =
  if kind == ArmorRallyHorn: 1 else: 0

proc equippedMaxHpBonus*(player: Actor): int =
  for kind in player.armor:
    result += kind.armorMaxHpBonus()

proc equippedSpeedPercentBonus*(player: Actor): int =
  for kind in player.armor:
    result += kind.armorSpeedPercentBonus()

proc equippedDamageReductionPct*(player: Actor): int =
  for kind in player.armor:
    result += kind.armorDamageReductionPct()
  result = clamp(result, 0, 65)

proc equippedStatusRecoveryStep*(player: Actor): int =
  for kind in player.armor:
    result += kind.armorStatusRecoveryStep()

proc equippedRoleCooldownStep*(player: Actor): int =
  for kind in player.armor:
    result += kind.armorRoleCooldownStep()

proc hasArmorProtection*(player: Actor, pressure: SurvivalPressureKind): bool =
  for kind in player.armor:
    if kind.armorProtectsPressure(pressure):
      return true
  false

proc armorHudLabel*(player: Actor): string =
  var pieces: seq[string] = @[]
  for slot in ArmorSlot:
    let kind = player.armor[slot]
    if kind != ArmorNone:
      pieces.add(kind.armorLabel() & " " & kind.armorBonusLabel())
  if pieces.len == 0:
    "armor none"
  else:
    "armor " & pieces.join(" | ")

proc armorFromPickupValue*(value: int): ArmorKind =
  if value > ord(ArmorNone) and value <= ord(high(ArmorKind)):
    ArmorKind(value)
  else:
    ArmorScoutHood

proc speciesArmorDrop*(species: MobSpecies): ArmorKind =
  case species
  of SpeciesPackAlpha:
    ArmorScoutHood
  of SpeciesThornMender:
    ArmorLeatherVest
  of SpeciesBannerGoblin:
    ArmorRallyHorn
  of SpeciesNetThrower:
    ArmorIronHelm
  of SpeciesBogWitch:
    ArmorVenomCharm
  of SpeciesLeechSwarm:
    ArmorLeatherVest
  of SpeciesSandBurrower:
    ArmorFurHood
  of SpeciesFireScorpion:
    ArmorScaleMail
  of SpeciesIceShaman:
    ArmorFrostCloak
  of SpeciesSnowStalker:
    ArmorScoutHood
  of SpeciesCrystalSeer:
    ArmorLanternCharm
  of SpeciesRuinNecromancer:
    ArmorRallyHorn
  else:
    ArmorNone

proc statusLabel*(player: Actor): string =
  if player.downedTicks > 0:
    return "down"
  var labels: seq[string] = @[]
  if player.triumphTicks > 0:
    labels.add("triumph")
  if player.rationTicks > 0:
    labels.add("ration")
  if player.moraleTicks > 0:
    labels.add("morale")
  if player.poisonTicks > 0:
    labels.add("poison")
  if player.slowTicks > 0:
    labels.add("slow")
  if player.chillTicks > 0:
    labels.add("chill")
  if player.exhaustionTicks > 0:
    labels.add("exhaust")
  if player.routeTicks > 0:
    labels.add("route")
  if player.surveyTicks > 0:
    labels.add("survey")
  if player.guideTicks > 0:
    labels.add("guide")
  if player.huntTicks > 0:
    labels.add("hunt")
  if labels.len == 0:
    return "ok"
  labels.join("/")

proc survivalPressureLabel*(kind: SurvivalPressureKind): string =
  case kind
  of SurvivalSafe: "safe"
  of SurvivalMire: "mire"
  of SurvivalCold: "cold"
  of SurvivalHeat: "heat"
  of SurvivalFog: "fog"

proc biomeTacticLabel*(kind: BiomeTacticKind): string =
  case kind
  of BiomeTacticNone: ""
  of BiomeTacticMastery: "mastery"
  of BiomeTacticForage: "forage"
  of BiomeTacticRally: "rally"
  of BiomeTacticShade: "shade"
  of BiomeTacticWarmth: "warmth"
  of BiomeTacticLight: "light"
  of BiomeTacticGuard: "guard"
  of BiomeTacticBlessing: "bless"

proc pingLabel*(kind: PlayerPingKind): string =
  case kind
  of PingNone: "none"
  of PingRegroup: "regroup"
  of PingHelp: "help"
  of PingObjective: "objective"
  of PingCamp: "camp"
  of PingFood: "food"
  of PingRescue: "rescue"
  of PingLair: "lair"

proc playerPingForMessage*(message: string): PlayerPingKind =
  ## Converts short chat phrases into compact expedition pings.
  let lower = message.strip().toLowerAscii()
  if lower.len == 0:
    return PingNone
  if lower.contains("regroup") or lower.contains("group") or
      lower.contains("together"):
    return PingRegroup
  if lower.contains("help") or lower.contains("down") or
      lower.contains("heal"):
    return PingHelp
  if lower.contains("relic") or lower.contains("beacon") or
      lower.contains("objective") or lower.contains("gate"):
    return PingObjective
  if lower.contains("camp") or lower.contains("shelter") or
      lower.contains("fort"):
    return PingCamp
  if lower.contains("food") or lower.contains("eat"):
    return PingFood
  if lower.contains("rescue") or lower.contains("save"):
    return PingRescue
  if lower.contains("lair") or lower.contains("den"):
    return PingLair
  PingNone

proc waystationLabel*(biome: BiomeKind): string =
  case biome
  of BiomeForest: "forage"
  of BiomePlains: "rally"
  of BiomeSwamp: "bridge"
  of BiomeDesert: "oasis"
  of BiomeSnow: "hearth"
  of BiomeCave: "lantern"
  of BiomeRuins: "ward"
  of BiomeOrigin: "waystation"

proc waystationPromptLabel*(biome: BiomeKind): string =
  case biome
  of BiomeForest: "FORAGE H"
  of BiomePlains: "RALLY T"
  of BiomeSwamp: "BRIDGE T"
  of BiomeDesert: "OASIS H"
  of BiomeSnow: "HEARTH H"
  of BiomeCave: "LANTERN D"
  of BiomeRuins: "WARD T"
  of BiomeOrigin: "WAYPOINT"

proc preferredWaystationRole*(biome: BiomeKind): PlayerRole =
  case biome
  of BiomeForest, BiomeDesert, BiomeSnow:
    RoleHealer
  of BiomePlains, BiomeSwamp, BiomeRuins:
    RoleTank
  of BiomeCave:
    RoleDps
  of BiomeOrigin:
    RoleUnarmed

proc statusSpeedPercent*(player: Actor): int =
  if player.triumphTicks > 0:
    return 100
  result = 100
  if player.slowTicks > 0:
    result = min(result, StatusSlowSpeedPercent)
  if player.chillTicks > 0:
    result = min(result, StatusChillSpeedPercent)
  if player.exhaustionTicks > 0:
    result = min(result, StatusExhaustionSpeedPercent)
  if player.guideTicks > 0 and result == 100:
    result = RescueGuideSpeedPercent
  if player.moraleTicks > 0 and result == 100:
    result = ObjectiveMoraleSpeedPercent

proc roleMaxHp(role: PlayerRole): int =
  case role
  of RoleUnarmed:
    UnarmedPlayerHp
  of RoleTank:
    TankPlayerHp
  of RoleDps:
    BasePlayerHp
  of RoleHealer:
    HealerPlayerHp

proc roleAttackDamage(role: PlayerRole): int =
  case role
  of RoleUnarmed:
    1
  of RoleTank:
    1
  of RoleDps:
    3
  of RoleHealer:
    1

proc roleMovementSpeedPercent*(role: PlayerRole): int =
  case role
  of RoleUnarmed:
    UnarmedMovementSpeedPercent
  of RoleTank:
    TankMovementSpeedPercent
  of RoleDps:
    DpsMovementSpeedPercent
  of RoleHealer:
    HealerMovementSpeedPercent

proc roleAbilityLabel*(role: PlayerRole): string =
  case role
  of RoleUnarmed:
    "choose role"
  of RoleTank:
    "guard"
  of RoleDps:
    "beam"
  of RoleHealer:
    "heal"

proc roleAbilityManaCost*(role: PlayerRole): int =
  ## Returns the mana cost for one role's special action.
  case role
  of RoleTank:
    TankGuardManaCost
  of RoleDps:
    DpsBeamManaCost
  of RoleHealer:
    HealerPulseManaCost
  else:
    0

proc roleForPickup(kind: PickupKind): PlayerRole =
  case kind
  of PickupTankGear:
    RoleTank
  of PickupDpsGear:
    RoleDps
  of PickupHealerGear:
    RoleHealer
  else:
    RoleUnarmed

proc isRoleGear*(kind: PickupKind): bool =
  kind in {PickupTankGear, PickupDpsGear, PickupHealerGear}

proc carryForPickup*(kind: PickupKind): CarryKind =
  case kind
  of PickupWood:
    CarryWood
  of PickupFood:
    CarryFood
  of PickupStone:
    CarryStone
  of PickupGold:
    CarryGold
  else:
    CarryNone

proc pickupForCarry*(kind: CarryKind): PickupKind =
  case kind
  of CarryWood:
    PickupWood
  of CarryFood:
    PickupFood
  of CarryStone:
    PickupStone
  of CarryGold:
    PickupGold
  of CarryNone:
    PickupCoin

proc isCarryPickup*(kind: PickupKind): bool =
  kind.carryForPickup() != CarryNone

proc carryForLandmark*(kind: LandmarkKind): CarryKind =
  case kind
  of LandmarkWood:
    CarryWood
  of LandmarkFood:
    CarryFood
  of LandmarkStone:
    CarryStone
  of LandmarkGold:
    CarryGold
  of LandmarkCamp, LandmarkBeacon, LandmarkFinalGate, LandmarkShrine,
      LandmarkRescue, LandmarkLair, LandmarkWaystation:
    CarryNone

proc landmarkForCarry*(kind: CarryKind): LandmarkKind =
  case kind
  of CarryWood:
    LandmarkWood
  of CarryFood:
    LandmarkFood
  of CarryStone:
    LandmarkStone
  of CarryGold:
    LandmarkGold
  of CarryNone:
    LandmarkFood

proc storedCarryTotal*(player: Actor): int =
  for item in CarryInventoryKinds:
    result += player.carryCounts[item]

proc carryCount*(player: Actor, item: CarryKind): int =
  if item == CarryNone:
    return 0
  if not player.carrying and player.carriedItem == CarryNone:
    return 0
  result = player.carryCounts[item]
  if result == 0 and player.storedCarryTotal() == 0 and player.carrying and
      player.carriedItem == item:
    result = 1

proc hasCarry*(player: Actor, item: CarryKind): bool =
  player.carryCount(item) > 0

proc activeCarryItem*(player: Actor): CarryKind =
  if player.carriedItem != CarryNone and player.carryCount(player.carriedItem) > 0:
    return player.carriedItem
  for item in CarryInventoryKinds:
    if player.carryCount(item) > 0:
      return item
  CarryNone

proc syncCarrySelection*(player: var Actor) =
  if player.carriedItem != CarryNone and player.carryCounts[player.carriedItem] > 0:
    player.carrying = true
    return
  for item in CarryInventoryKinds:
    if player.carryCounts[item] > 0:
      player.carrying = true
      player.carriedItem = item
      return
  player.carrying = false
  player.carriedItem = CarryNone

proc normalizeCarry*(player: var Actor) =
  if not player.carrying and player.carriedItem == CarryNone:
    for item in CarryKind:
      player.carryCounts[item] = 0
    return
  if player.storedCarryTotal() == 0 and player.carrying and
      player.carriedItem != CarryNone:
    player.carryCounts[player.carriedItem] = 1
  player.syncCarrySelection()

proc clearCarryInventory*(player: var Actor) =
  for item in CarryKind:
    player.carryCounts[item] = 0
  player.carrying = false
  player.carriedItem = CarryNone

proc carryInventoryLabel*(player: Actor): string =
  var labels: seq[string] = @[]
  for item in CarryInventoryKinds:
    let count = player.carryCount(item)
    if count <= 0:
      continue
    var label = item.carryLabel()
    if count > 1:
      label.add(" x")
      label.add($count)
    labels.add(label)
  if labels.len == 0:
    "none"
  else:
    labels.join(",")

proc dataDir*(): string =
  getCurrentDir() / "data"

proc repoDir*(): string =
  getCurrentDir() / ".."

proc clientDataDir*(): string =
  repoDir() / "client" / "data"

proc sheetPath*(): string =
  ## Returns the new 32 by 32 Aseprite sheet path.
  let path = dataDir() / "spritesheat.aseprite"
  if fileExists(path):
    return path
  dataDir() / "spritesheet.aseprite"

proc loadClientPalette*() =
  loadPalette(clientDataDir() / "pallete.png")

proc loadTiny5Font*(): PixelFont =
  ## Loads the shared Tiny5 variable-width pixel font.
  readTiny5Font()

proc rgbaSpriteIndex*(sprite: RgbaSprite, x, y: int): int =
  ## Returns the byte offset for one RGBA sprite pixel.
  (y * sprite.width + x) * 4

proc rgbaSpriteFromImage(image: Image): RgbaSprite =
  ## Copies a Pixie image into a straight RGBA sprite.
  result.width = image.width
  result.height = image.height
  result.pixels = newSeq[uint8](result.width * result.height * 4)
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let
        pixel = image[x, y]
        index = result.rgbaSpriteIndex(x, y)
      result.pixels[index] = pixel.r
      result.pixels[index + 1] = pixel.g
      result.pixels[index + 2] = pixel.b
      result.pixels[index + 3] = pixel.a

proc sheetSprite(sheet: Image, cellX, cellY: int): Sprite =
  ## Slices one 32 by 32 cell as a palette-indexed sprite.
  spriteFromImage(
    sheet.subImage(
      cellX * ArtCellSize,
      cellY * ArtCellSize,
      ArtCellSize,
      ArtCellSize
    )
  )

proc sheetRgbaSprite(sheet: Image, cellX, cellY: int): RgbaSprite =
  ## Slices one 32 by 32 cell as a true-color sprite.
  rgbaSpriteFromImage(
    sheet.subImage(
      cellX * ArtCellSize,
      cellY * ArtCellSize,
      ArtCellSize,
      ArtCellSize
    )
  )

proc transparentCell(): Image =
  result = newImage(ArtCellSize, ArtCellSize)
  for y in 0 ..< ArtCellSize:
    for x in 0 ..< ArtCellSize:
      result[x, y] = rgba(0, 0, 0, 0)

proc imageAlphaBounds(image: Image): SpriteBounds =
  var
    minX = image.width
    minY = image.height
    maxX = -1
    maxY = -1
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      if image[x, y].a < 20'u8:
        continue
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
  if maxX < minX or maxY < minY:
    return SpriteBounds(x: 0, y: 0, w: image.width, h: image.height)
  SpriteBounds(
    x: minX,
    y: minY,
    w: maxX - minX + 1,
    h: maxY - minY + 1
  )

proc fittedArtCell(image: Image, cropAlpha = true): Image =
  ## Fits large runtime PNGs into the game's 32 by 32 sprite budget.
  result = transparentCell()
  let bounds =
    if cropAlpha:
      image.imageAlphaBounds()
    else:
      SpriteBounds(x: 0, y: 0, w: image.width, h: image.height)
  if bounds.w <= 0 or bounds.h <= 0:
    return
  var drawW: int
  var drawH: int
  if bounds.w >= bounds.h:
    drawW = ArtCellSize
    drawH = max(1, (bounds.h * ArtCellSize) div bounds.w)
  else:
    drawH = ArtCellSize
    drawW = max(1, (bounds.w * ArtCellSize) div bounds.h)
  let
    offsetX = (ArtCellSize - drawW) div 2
    offsetY = (ArtCellSize - drawH) div 2
  for y in 0 ..< drawH:
    for x in 0 ..< drawW:
      let
        sx = bounds.x + min(bounds.w - 1, (x * bounds.w) div drawW)
        sy = bounds.y + min(bounds.h - 1, (y * bounds.h) div drawH)
      result[offsetX + x, offsetY + y] = image[sx, sy]

proc loadTribalAssetManifest*(): JsonNode =
  ## Reads the optional runtime PNG mapping used for TribalCog borrowing.
  let path = dataDir() / TribalAssetManifestName
  if not fileExists(path):
    return newJObject()
  try:
    result = parseJson(readFile(path))
  except CatchableError:
    result = newJObject()
  if result.kind != JObject:
    result = newJObject()

proc tribalCogDataDir*(): string =
  ## Returns the runtime asset directory for borrowed TribalCog PNGs.
  result = getEnv("TRIBALCOG_DATA_DIR")
  if result.len > 0:
    return result
  let sibling = repoDir().parentDir() / "games" / "games" / "tribalcog" / "data"
  if dirExists(sibling):
    return sibling
  result = getHomeDir() / "Code" / "games" / "games" / "tribalcog" / "data"

proc assetRelativePath(
  manifest: JsonNode,
  key,
  fallbackRelativePath: string
): string =
  if manifest.kind == JObject and manifest.hasKey("assets"):
    let assets = manifest["assets"]
    if assets.kind == JObject and assets.hasKey(key) and
        assets[key].kind == JString:
      return assets[key].getStr()
  fallbackRelativePath

proc resolveAssetPath(
  manifest: JsonNode,
  key,
  fallbackRelativePath: string
): string =
  let relativePath = manifest.assetRelativePath(key, fallbackRelativePath)
  for path in [dataDir() / relativePath, tribalCogDataDir() / relativePath]:
    if fileExists(path):
      return path
  ""

proc loadFittedAssetImage(
  manifest: JsonNode,
  key,
  fallbackRelativePath: string,
  fallbackImage: Image,
  cropAlpha = true
): Image =
  let path = manifest.resolveAssetPath(key, fallbackRelativePath)
  if path.len > 0:
    try:
      return readImage(path).fittedArtCell(cropAlpha)
    except CatchableError:
      discard
  fallbackImage.fittedArtCell(cropAlpha)

proc loadAssetPair(
  manifest: JsonNode,
  key,
  fallbackRelativePath: string,
  fallbackImage: Image,
  cropAlpha = true
): tuple[sprite: Sprite, rgba: RgbaSprite] =
  let image = loadFittedAssetImage(
    manifest,
    key,
    fallbackRelativePath,
    fallbackImage,
    cropAlpha
  )
  (spriteFromImage(image), rgbaSpriteFromImage(image))

proc visibleBounds*(sprite: Sprite): SpriteBounds =
  ## Measures the exact visible bounds of a palette sprite.
  var
    minX = sprite.width
    minY = sprite.height
    maxX = -1
    maxY = -1
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      if sprite.pixels[sprite.spriteIndex(x, y)] == TransparentColorIndex:
        continue
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
  if maxX < minX or maxY < minY:
    return SpriteBounds()
  SpriteBounds(
    x: minX,
    y: minY,
    w: maxX - minX + 1,
    h: maxY - minY + 1
  )

proc visibleBounds*(sprite: RgbaSprite): SpriteBounds =
  ## Measures the exact visible bounds of a true-color sprite.
  var
    minX = sprite.width
    minY = sprite.height
    maxX = -1
    maxY = -1
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      if sprite.pixels[sprite.rgbaSpriteIndex(x, y) + 3] == 0'u8:
        continue
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
  if maxX < minX or maxY < minY:
    return SpriteBounds()
  SpriteBounds(
    x: minX,
    y: minY,
    w: maxX - minX + 1,
    h: maxY - minY + 1
  )

proc lowerCenterBounds(bounds: SpriteBounds): SpriteBounds =
  ## Returns a small trunk-like collision box from visible bounds.
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

proc terrainCollisionBounds*(
  sprite: RgbaSprite,
  kind: TerrainKind
): SpriteBounds =
  ## Measures collision bounds for one terrain prop sprite.
  let bounds = sprite.visibleBounds()
  case kind
  of TerrainTree, TerrainEvergreen, TerrainCactus, TerrainBush,
      TerrainWheat:
    bounds.lowerCenterBounds()
  of TerrainFish, TerrainAltar, TerrainCamp:
    SpriteBounds()
  of TerrainRock, TerrainLog, TerrainStump, TerrainStone, TerrainGold,
      TerrainCave, TerrainGoblinHut, TerrainGoblinTotem:
    bounds

proc loadPlayerArt(sheet: Image, row: int): PlayerArt =
  ## Loads one adventurer row from the new art sheet.
  result.sprites[PlayerFront] = sheet.sheetSprite(0, row)
  result.sprites[PlayerSide] = sheet.sheetSprite(1, row)
  result.sprites[PlayerBack] = sheet.sheetSprite(2, row)
  result.rgbaSprites[PlayerFront] = sheet.sheetRgbaSprite(0, row)
  result.rgbaSprites[PlayerSide] = sheet.sheetRgbaSprite(1, row)
  result.rgbaSprites[PlayerBack] = sheet.sheetRgbaSprite(2, row)
  result.swoosh = sheet.sheetSprite(3, row)
  result.rgbaSwoosh = sheet.sheetRgbaSprite(3, row)
  result.masks[PlayerFront] = sheet.sheetSprite(4, row)
  result.masks[PlayerSide] = sheet.sheetSprite(5, row)
  result.masks[PlayerBack] = sheet.sheetSprite(6, row)
  result.bounds[PlayerFront] = result.rgbaSprites[PlayerFront].visibleBounds()
  result.bounds[PlayerSide] = result.rgbaSprites[PlayerSide].visibleBounds()
  result.bounds[PlayerBack] = result.rgbaSprites[PlayerBack].visibleBounds()
  result.swooshBounds = result.rgbaSwoosh.visibleBounds()

proc playerPoseForFacing*(facing: Facing): PlayerPose =
  ## Returns the drawn player pose for a movement facing.
  case facing
  of FaceUp:
    PlayerBack
  of FaceDown:
    PlayerFront
  of FaceLeft, FaceRight:
    PlayerSide

proc playerFormForId(playerId: int): PlayerForm =
  ## Splits players evenly between male and female adventurers.
  if playerId mod 2 == 0:
    FemalePlayer
  else:
    MalePlayer

proc terrainPropSprite*(sim: SimServer, kind: TerrainKind): Sprite =
  ## Returns the sprite for one terrain prop kind.
  sim.terrainSprites[kind]

proc groundSprite*(sim: SimServer, kind: GroundKind): Sprite =
  ## Returns the sprite for one ground tile kind.
  sim.groundSprites[kind]

proc groundRgbaSprite*(sim: SimServer, kind: GroundKind): RgbaSprite =
  ## Returns the true-color sprite for one ground tile kind.
  sim.rgbaGroundSprites[kind]

proc terrainPropRgbaSprite*(sim: SimServer, kind: TerrainKind): RgbaSprite =
  ## Returns the true-color sprite for one terrain prop kind.
  sim.rgbaTerrainSprites[kind]

proc terrainPropBounds*(sim: SimServer, kind: TerrainKind): SpriteBounds =
  ## Returns the collision bounds for one terrain prop kind.
  sim.terrainBounds[kind]

proc landmarkSprite*(sim: SimServer, kind: LandmarkKind): Sprite =
  ## Returns the sprite for one expedition landmark kind.
  sim.landmarkSprites[kind]

proc landmarkRgbaSprite*(sim: SimServer, kind: LandmarkKind): RgbaSprite =
  ## Returns the true-color sprite for one expedition landmark kind.
  sim.rgbaLandmarkSprites[kind]

proc landmarkBounds*(sim: SimServer, kind: LandmarkKind): SpriteBounds =
  ## Returns the collision/interaction bounds for a landmark kind.
  sim.landmarkBounds[kind]

proc pickupSprite*(sim: SimServer, kind: PickupKind): Sprite =
  ## Returns the sprite for one pickup kind.
  case kind
  of PickupCoin:
    sim.coinSprite
  of PickupHeart:
    sim.heartSprite
  of PickupTankGear, PickupDpsGear, PickupHealerGear:
    sim.roleGearSprites[kind]
  of PickupWood, PickupFood, PickupStone, PickupGold:
    sim.landmarkSprite(kind.carryForPickup().landmarkForCarry())
  of PickupArmor:
    sim.armorSprites[ArmorScoutHood]

proc pickupRgbaSprite*(sim: SimServer, kind: PickupKind): RgbaSprite =
  ## Returns the true-color sprite for one pickup kind.
  case kind
  of PickupCoin:
    sim.rgbaCoinSprite
  of PickupHeart:
    sim.rgbaHeartSprite
  of PickupTankGear, PickupDpsGear, PickupHealerGear:
    sim.roleGearRgbaSprites[kind]
  of PickupWood, PickupFood, PickupStone, PickupGold:
    sim.landmarkRgbaSprite(kind.carryForPickup().landmarkForCarry())
  of PickupArmor:
    sim.armorRgbaSprites[ArmorScoutHood]

proc pickupBounds*(sim: SimServer, kind: PickupKind): SpriteBounds =
  ## Returns the collision bounds for one pickup kind.
  case kind
  of PickupCoin:
    sim.coinBounds
  of PickupHeart:
    sim.heartBounds
  of PickupTankGear, PickupDpsGear, PickupHealerGear:
    sim.roleGearBounds[kind]
  of PickupWood, PickupFood, PickupStone, PickupGold:
    sim.landmarkBounds(kind.carryForPickup().landmarkForCarry())
  of PickupArmor:
    sim.armorBounds[ArmorScoutHood]

proc playerSpriteFor*(sim: SimServer, player: Actor): Sprite =
  ## Returns the current drawn sprite for one player.
  sim.playerArts[player.form].sprites[player.facing.playerPoseForFacing()]

proc playerRgbaSpriteFor*(sim: SimServer, player: Actor): RgbaSprite =
  ## Returns the current true-color sprite for one player.
  sim.playerArts[player.form].rgbaSprites[player.facing.playerPoseForFacing()]

proc footBounds*(bounds: SpriteBounds): SpriteBounds =
  ## Returns the small foot collision box for a player sprite.
  if bounds.w <= 0 or bounds.h <= 0:
    return bounds
  SpriteBounds(
    x: bounds.x + (bounds.w - PlayerFootSize) div 2,
    y: bounds.y + bounds.h - PlayerFootSize,
    w: PlayerFootSize,
    h: PlayerFootSize
  )

proc playerCollisionBoundsFor*(
  sim: SimServer,
  form: PlayerForm,
  facing: Facing
): SpriteBounds =
  ## Returns the 8 by 8 foot collision box for one player pose.
  sim.playerArts[form].bounds[facing.playerPoseForFacing()].footBounds()

proc playerBoundsFor*(sim: SimServer, player: Actor): SpriteBounds =
  ## Returns the current collision bounds for one player.
  sim.playerCollisionBoundsFor(player.form, player.facing)

proc playerMaskFor*(sim: SimServer, player: Actor): Sprite =
  ## Returns the current recolor mask for one player.
  sim.playerArts[player.form].masks[player.facing.playerPoseForFacing()]

proc playerSwooshFor*(sim: SimServer, player: Actor): Sprite =
  ## Returns the attack sprite for one player's form.
  sim.playerArts[player.form].swoosh

proc playerRgbaSwooshFor*(sim: SimServer, player: Actor): RgbaSprite =
  ## Returns the true-color attack sprite for one player's form.
  sim.playerArts[player.form].rgbaSwoosh

proc mobBoundsFor*(sim: SimServer, kind: MobKind): SpriteBounds =
  ## Returns the collision bounds for one mob kind.
  case kind
  of SnakeMob, WolfMob, ScorpionMob, BatMob:
    sim.mobBounds
  of TrollMob, GoblinMob, SlimeMob, WraithMob:
    sim.trollBounds
  of BossMob, BearMob, YetiMob:
    sim.bossBounds

proc mobBoundsFor*(sim: SimServer, species: MobSpecies): SpriteBounds =
  ## Returns collision bounds for one species-specific mob sprite.
  if species != SpeciesNone and sim.mobSpeciesBounds[species].w > 0:
    return sim.mobSpeciesBounds[species]
  sim.mobBoundsFor(species.speciesKind())

proc mobSpriteFor*(sim: SimServer, kind: MobKind): Sprite =
  ## Returns the rendered sprite for one mob kind.
  case kind
  of SnakeMob, WolfMob, ScorpionMob, BatMob:
    sim.mobSprite
  of TrollMob, GoblinMob, SlimeMob, WraithMob:
    sim.trollSprite
  of BossMob, BearMob, YetiMob:
    sim.bossSprite

proc mobSpriteFor*(sim: SimServer, species: MobSpecies): Sprite =
  ## Returns the rendered sprite for one monster species.
  if species != SpeciesNone and sim.mobSpeciesBounds[species].w > 0:
    return sim.mobSpeciesSprites[species]
  sim.mobSpriteFor(species.speciesKind())

proc mobSpeciesRgbaSprite*(sim: SimServer, species: MobSpecies): RgbaSprite =
  ## Returns the true-color sprite for one monster species.
  if species != SpeciesNone and sim.mobSpeciesBounds[species].w > 0:
    return sim.mobSpeciesRgbaSprites[species]
  case species.speciesKind()
  of SnakeMob, WolfMob, ScorpionMob, BatMob:
    sim.rgbaMobSprite
  of TrollMob, GoblinMob, SlimeMob, WraithMob:
    sim.rgbaTrollSprite
  of BossMob, BearMob, YetiMob:
    sim.rgbaBossSprite

proc mobSpeciesHasGeneratedSprite*(sim: SimServer, species: MobSpecies): bool =
  species != SpeciesNone and sim.mobSpeciesGeneratedSprites[species]

proc tileIndex*(tx, ty: int): int =
  ty * WorldWidthTiles + tx

proc inTileBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc biomeForSegmentIndex*(segmentIndex: int): BiomeKind =
  let zone = ((max(0, segmentIndex) mod BiomeCount) + BiomeCount) mod BiomeCount
  case zone
  of 0: BiomeForest
  of 1: BiomePlains
  of 2: BiomeSwamp
  of 3: BiomeDesert
  of 4: BiomeSnow
  of 5: BiomeCave
  else: BiomeRuins

proc adventureSegmentIndexForTileX*(tx: int): int =
  ## Returns the rightward procedural segment index after the safe origin.
  if tx < SafeZoneRightTiles:
    return -1
  (tx - SafeZoneRightTiles) div ExpeditionBiomeSpanTiles

proc adventureCycleForTileX*(tx: int): int =
  let segment = adventureSegmentIndexForTileX(tx)
  if segment < 0:
    0
  else:
    segment div BiomeCount

proc biomeForTileX*(tx: int): BiomeKind =
  ## Maps rightward expedition progress to repeated procedural biome bands.
  if tx < SafeZoneRightTiles:
    return BiomeOrigin
  biomeForSegmentIndex(tx.adventureSegmentIndexForTileX())

proc weatherForBiome*(biome: BiomeKind): WeatherKind =
  ## Returns the deterministic weather identity for one biome.
  case biome
  of BiomeSwamp:
    WeatherRain
  of BiomeDesert:
    WeatherDust
  of BiomeSnow:
    WeatherSnow
  of BiomeCave, BiomeRuins:
    WeatherFog
  else:
    WeatherClear

proc biomeProgressValue*(biome: BiomeKind): int =
  ## Returns a compact reached-biome score value.
  case biome
  of BiomeOrigin: 0
  of BiomeForest: 1
  of BiomePlains: 2
  of BiomeSwamp: 3
  of BiomeDesert: 4
  of BiomeSnow: 5
  of BiomeCave: 6
  of BiomeRuins: 7

proc biomeBackgroundRgbaColor*(
  biome: BiomeKind
): tuple[r, g, b, a: uint8] =
  ## Returns the opaque tile backing color for transparent TribalCog PNG pixels.
  case biome
  of BiomeOrigin:
    (r: 58'u8, g: 112'u8, b: 66'u8, a: 255'u8)
  of BiomeForest:
    (r: 42'u8, g: 94'u8, b: 52'u8, a: 255'u8)
  of BiomePlains:
    (r: 142'u8, g: 146'u8, b: 78'u8, a: 255'u8)
  of BiomeSwamp:
    (r: 44'u8, g: 84'u8, b: 82'u8, a: 255'u8)
  of BiomeDesert:
    (r: 190'u8, g: 145'u8, b: 78'u8, a: 255'u8)
  of BiomeSnow:
    (r: 211'u8, g: 224'u8, b: 232'u8, a: 255'u8)
  of BiomeCave:
    (r: 72'u8, g: 66'u8, b: 76'u8, a: 255'u8)
  of BiomeRuins:
    (r: 92'u8, g: 89'u8, b: 96'u8, a: 255'u8)

proc biomeBackgroundPaletteColor*(biome: BiomeKind): uint8 =
  ## Returns the nearest existing 4-bit palette color for the biome backing.
  case biome
  of BiomeOrigin, BiomeForest, BiomeSwamp:
    10'u8
  of BiomePlains:
    8'u8
  of BiomeDesert:
    7'u8
  of BiomeSnow:
    2'u8
  of BiomeCave:
    5'u8
  of BiomeRuins:
    13'u8

proc groundBlocks(kind: GroundKind): bool =
  kind == GroundWater

proc baseGroundForBiome(biome: BiomeKind): GroundKind =
  case biome
  of BiomeOrigin, BiomeForest:
    GroundGrass
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

proc groundSpeedPercent*(kind: GroundKind): int =
  ## Returns movement speed as a percent for the current ground.
  case kind
  of GroundRoad:
    115
  of GroundBridge:
    105
  of GroundMud:
    60
  of GroundShallowWater:
    55
  of GroundSnow:
    80
  of GroundDune:
    85
  of GroundCave, GroundRuins:
    90
  else:
    100

proc weatherSpeedPercent*(weather: WeatherKind): int =
  ## Keeps weather meaningful but light enough to remain readable.
  case weather
  of WeatherRain:
    92
  of WeatherDust:
    94
  of WeatherSnow:
    90
  of WeatherFog:
    96
  else:
    100

proc worldClampPixel*(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc rectsOverlap*(ax, ay, aw, ah, bx, by, bw, bh: int): bool =
  ax < bx + bw and
  ax + aw > bx and
  ay < by + bh and
  ay + ah > by

proc boundsCenterX*(x: int, bounds: SpriteBounds): int =
  ## Returns the world x center for one collision bounds.
  x + bounds.x + bounds.w div 2

proc boundsCenterY*(y: int, bounds: SpriteBounds): int =
  ## Returns the world y center for one collision bounds.
  y + bounds.y + bounds.h div 2

proc boundsOverlap*(
  ax, ay: int,
  a: SpriteBounds,
  bx, by: int,
  b: SpriteBounds
): bool =
  ## Returns true when two sprite bounds overlap in world space.
  if a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0:
    return false
  rectsOverlap(
    ax + a.x,
    ay + a.y,
    a.w,
    a.h,
    bx + b.x,
    by + b.y,
    b.w,
    b.h
  )

proc rectOverlapsBounds*(
  x, y, w, h: int,
  bx, by: int,
  bounds: SpriteBounds
): bool =
  ## Returns true when a rectangle overlaps sprite bounds.
  if bounds.w <= 0 or bounds.h <= 0:
    return false
  rectsOverlap(
    x,
    y,
    w,
    h,
    bx + bounds.x,
    by + bounds.y,
    bounds.w,
    bounds.h
  )

proc distanceSquared*(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc distanceSquaredActor(a: Actor, b: Actor): int =
  distanceSquared(
    boundsCenterX(a.x, a.bounds),
    boundsCenterY(a.y, a.bounds),
    boundsCenterX(b.x, b.bounds),
    boundsCenterY(b.y, b.bounds)
  )

proc mobZoneX(x: int): int =
  max(0, (x - SafeZoneRightPixels) div ZoneWidthPixels)

proc frontierTilesForX*(x: int): int =
  max(0, (x - SafeZoneRightPixels) div WorldTileSize)

proc frontierTiles*(sim: SimServer): int =
  frontierTilesForX(sim.teamFrontier)

proc tileGroundKind*(sim: SimServer, tx, ty: int): GroundKind =
  if not inTileBounds(tx, ty) or sim.groundKinds.len == 0:
    return GroundGrass
  sim.groundKinds[tileIndex(tx, ty)]

proc tileBiomeKind*(sim: SimServer, tx, ty: int): BiomeKind =
  if not inTileBounds(tx, ty) or sim.biomeKinds.len == 0:
    return biomeForTileX(tx)
  sim.biomeKinds[tileIndex(tx, ty)]

proc tileElevation*(sim: SimServer, tx, ty: int): int =
  if not inTileBounds(tx, ty) or sim.elevations.len == 0:
    return 0
  sim.elevations[tileIndex(tx, ty)]

proc tileBlocksSight*(sim: SimServer, tx, ty: int): bool =
  if not inTileBounds(tx, ty):
    return false
  sim.tileElevation(tx, ty) >= 4 or
    (sim.tiles.len > 0 and sim.tiles[tileIndex(tx, ty)])

proc tileVisibleFrom*(sim: SimServer, fromTx, fromTy, toTx, toTy: int): bool =
  ## Uses a small Bresenham trace so high ridges and blockers hide farther tiles.
  if not inTileBounds(toTx, toTy):
    return false
  if fromTx == toTx and fromTy == toTy:
    return true
  var
    x0 = fromTx
    y0 = fromTy
    x1 = toTx
    y1 = toTy
    dx = abs(x1 - x0)
    sx = if x0 < x1: 1 else: -1
    dy = -abs(y1 - y0)
    sy = if y0 < y1: 1 else: -1
    err = dx + dy
  while true:
    if x0 == x1 and y0 == y1:
      return true
    let e2 = 2 * err
    if e2 >= dy:
      err += dy
      x0 += sx
    if e2 <= dx:
      err += dx
      y0 += sy
    if x0 == x1 and y0 == y1:
      return true
    if sim.tileBlocksSight(x0, y0):
      return false

proc actorTileElevation*(sim: SimServer, actor: Actor): int =
  sim.tileElevation(
    clamp(boundsCenterX(actor.x, actor.bounds) div WorldTileSize, 0, WorldWidthTiles - 1),
    clamp(boundsCenterY(actor.y, actor.bounds) div WorldTileSize, 0, WorldHeightTiles - 1)
  )

proc mobTileElevation*(sim: SimServer, mob: Mob): int =
  sim.tileElevation(
    clamp(boundsCenterX(mob.x, mob.bounds) div WorldTileSize, 0, WorldWidthTiles - 1),
    clamp(boundsCenterY(mob.y, mob.bounds) div WorldTileSize, 0, WorldHeightTiles - 1)
  )

proc elevationDamageModifier*(attackerElevation, defenderElevation: int): int =
  let delta = attackerElevation - defenderElevation
  if delta >= ElevationCombatThreshold:
    HighGroundDamageBonus
  elif delta <= -ElevationCombatThreshold:
    -LowGroundDamagePenalty
  else:
    0

proc playerAttackDamage*(sim: SimServer, player: Actor, mob: Mob): int =
  let
    mobTx = clamp(boundsCenterX(mob.x, mob.bounds) div WorldTileSize, 0, WorldWidthTiles - 1)
    mobTy = clamp(boundsCenterY(mob.y, mob.bounds) div WorldTileSize, 0, WorldHeightTiles - 1)
    mobBiome = sim.tileBiomeKind(mobTx, mobTy)
  max(
    1,
    player.role.roleAttackDamage() +
      elevationDamageModifier(sim.actorTileElevation(player), sim.mobTileElevation(mob)) +
      (if player.huntTicks > 0 and mob.kind != BossMob:
        LairHunterDamageBonus
      else:
        0) +
      (if mobBiome != BiomeOrigin and sim.biomeMastered[mobBiome]:
        BiomeMasteryDamageBonus
      else:
        0)
  )

proc biomeAtPixel*(sim: SimServer, x: int): BiomeKind =
  let tx = clamp(x div WorldTileSize, 0, WorldWidthTiles - 1)
  sim.tileBiomeKind(tx, WorldHeightTiles div 2)

proc weatherAtPixel*(sim: SimServer, x: int): WeatherKind =
  sim.biomeAtPixel(x).weatherForBiome()

proc currentBiome*(sim: SimServer): BiomeKind =
  sim.biomeAtPixel(sim.teamFrontier)

proc currentWeather*(sim: SimServer): WeatherKind =
  sim.currentBiome().weatherForBiome()

proc biomeIsMastered*(sim: SimServer, biome: BiomeKind): bool =
  biome != BiomeOrigin and sim.biomeMastered[biome]

proc masteredBiomeCount*(sim: SimServer): int =
  for biome in BiomeKind:
    if sim.biomeIsMastered(biome):
      inc result

proc masteredBiomeLabels*(sim: SimServer): string =
  var labels: seq[string] = @[]
  for biome in BiomeKind:
    if sim.biomeIsMastered(biome):
      labels.add(biome.biomeLabel())
  if labels.len == 0:
    "none"
  else:
    labels.join(",")

proc masteryHudLabel*(sim: SimServer): string =
  "MAST " & $sim.masteredBiomeCount() & "/" & $BiomeCount

proc landmarkCountsForMastery(kind: LandmarkKind): bool =
  kind in {
    LandmarkCamp,
    LandmarkBeacon,
    LandmarkShrine,
    LandmarkRescue,
    LandmarkLair,
    LandmarkWaystation
  }

proc completedSegmentMilestones*(sim: SimServer, segmentIndex: int): int =
  ## Counts region objectives that make a biome feel solved, not just crossed.
  for landmark in sim.landmarks:
    if not landmark.done or not landmark.kind.landmarkCountsForMastery():
      continue
    if landmark.tx.adventureSegmentIndexForTileX() == segmentIndex:
      inc result

proc incompleteLandmarkInSegment(
  sim: SimServer,
  kind: LandmarkKind,
  segmentIndex: int
): bool =
  for landmark in sim.landmarks:
    if landmark.kind == kind and not landmark.done and
        landmark.tx.adventureSegmentIndexForTileX() == segmentIndex:
      return true
  false

proc incompleteLandmarkExists(
  sim: SimServer,
  kind: LandmarkKind
): bool =
  for landmark in sim.landmarks:
    if landmark.kind == kind and not landmark.done:
      return true
  false

proc completedLairCountInBiome*(sim: SimServer, biome: BiomeKind): int =
  ## Counts cleared dens that should lower future threat pressure in a biome.
  for landmark in sim.landmarks:
    if landmark.kind == LandmarkLair and landmark.done and
        sim.tileBiomeKind(landmark.tx, landmark.ty) == biome:
      inc result

proc lairRespawnCooldownBonus*(clearedLairs: int): int =
  max(0, clearedLairs) * LairRespawnCooldownBonus

proc campResourceHint(sim: SimServer): string =
  ## Returns the shared-resource deficit for the next buildable camp.
  "NEXT GATHER W" & $max(0, CampWoodCost - sim.wood) &
    " S" & $max(0, CampStoneCost - sim.stone)

proc missingCampResources(sim: SimServer): bool =
  sim.wood < CampWoodCost or sim.stone < CampStoneCost

proc finalGateProgressPercent*(progress: int): int =
  ## Returns compact ritual progress for final-gate HUD text.
  clamp((max(0, progress) * 100) div FinalGateRitualTicks, 0, 100)

proc finalGateObjectiveHint(sim: SimServer): string =
  for landmark in sim.landmarks:
    if landmark.kind == LandmarkFinalGate and not landmark.done:
      return "NEXT HOLD GATE " & $landmark.progress.finalGateProgressPercent() & "%"
  "EXPEDITION COMPLETE"

proc finalGateCompleted*(sim: SimServer): bool =
  ## Returns true after the expedition completes the last gate ritual.
  for landmark in sim.landmarks:
    if landmark.kind == LandmarkFinalGate and landmark.done:
      return true
  false

proc expeditionObjectiveHint*(sim: SimServer, playerIndex: int): string =
  ## Returns the short next-action line shown in the local player HUD.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return "NEXT WAIT"
  if sim.finalGateCompleted():
    return "EXPEDITION COMPLETE"
  let player = sim.players[playerIndex]
  if player.lives <= 0:
    if player.downedTicks > 0:
      return "NEXT WAIT FOR RESCUE"
    return "NEXT RESPAWN"
  if player.role == RoleUnarmed:
    return "NEXT WALK INTO TANK DPS HEAL"
  if player.maxHp > 0 and player.lives < player.maxHp and
      player.lives * 100 <= player.maxHp * LowHealthHelpThresholdPercent:
    return "NEXT HEAL FOOD SHELTER"

  let biome = sim.biomeAtPixel(boundsCenterX(player.x, player.bounds))
  let segment = adventureSegmentIndexForTileX(
    clamp(boundsCenterX(player.x, player.bounds) div WorldTileSize, 0, WorldWidthTiles - 1)
  )
  if biome == BiomeOrigin:
    return "NEXT PUSH RIGHT"
  if sim.bossDefeated and sim.relicShards >= FinalGateRelicCost and
      sim.campsActivated >= FinalGateCampCost and
      sim.incompleteLandmarkExists(LandmarkFinalGate):
    return sim.finalGateObjectiveHint()
  if sim.incompleteLandmarkInSegment(LandmarkWaystation, segment):
    return "NEXT " & biome.waystationPromptLabel()
  if sim.incompleteLandmarkInSegment(LandmarkCamp, segment):
    if sim.wood >= CampWoodCost and sim.stone >= CampStoneCost:
      return "NEXT BUILD CAMP"
    return sim.campResourceHint()
  if sim.incompleteLandmarkInSegment(LandmarkLair, segment):
    return "NEXT CLEAR LAIR"
  if sim.relicShards < FinalGateRelicCost and
      sim.incompleteLandmarkExists(LandmarkBeacon):
    return "NEXT RELIC " & $sim.relicShards & "/" & $FinalGateRelicCost
  if sim.campsActivated < FinalGateCampCost:
    if sim.incompleteLandmarkExists(LandmarkCamp) and
        sim.missingCampResources():
      return sim.campResourceHint()
    return "NEXT CAMP " & $sim.campsActivated & "/" & $FinalGateCampCost
  if not sim.bossDefeated:
    return "NEXT DEFEAT BOSS"
  if sim.relicShards < FinalGateRelicCost:
    return "NEXT RELIC " & $sim.relicShards & "/" & $FinalGateRelicCost
  if sim.campsActivated < FinalGateCampCost:
    if sim.incompleteLandmarkExists(LandmarkCamp) and
        sim.missingCampResources():
      return sim.campResourceHint()
    return "NEXT CAMP " & $sim.campsActivated & "/" & $FinalGateCampCost
  if sim.incompleteLandmarkExists(LandmarkFinalGate):
    return sim.finalGateObjectiveHint()
  "EXPEDITION COMPLETE"

proc teamScore*(sim: SimServer): int =
  ## Combines raw distance with expedition milestones.
  sim.frontierTiles() +
    sim.objectivesCompleted * ObjectiveScoreValue +
    sim.sideObjectivesCompleted * SideObjectiveScoreValue +
    sim.campsActivated * CampScoreValue +
    sim.masteredBiomeCount() * BiomeMasteryScoreValue +
    sim.relicShards * RelicScoreValue +
    sim.resourcesCollected +
    (if sim.bossDefeated: BossScoreValue else: 0) +
    (if sim.finalGateCompleted(): FinalGateScoreValue else: 0)

proc elevationSpeedPercent*(elevation: int): int =
  ## Higher ground is visible and tactically slower to traverse.
  case clamp(elevation, 0, 5)
  of 0: 100
  of 1: 98
  of 2: 94
  of 3: 88
  of 4: 82
  else: 76

proc speedPercentAt*(sim: SimServer, x, y: int): int =
  let
    tx = clamp(x div WorldTileSize, 0, WorldWidthTiles - 1)
    ty = clamp(y div WorldTileSize, 0, WorldHeightTiles - 1)
    ground = sim.tileGroundKind(tx, ty)
    weather = sim.tileBiomeKind(tx, ty).weatherForBiome()
    elevation = sim.tileElevation(tx, ty)
  (ground.groundSpeedPercent() *
    weather.weatherSpeedPercent() *
    elevation.elevationSpeedPercent()) div 10_000

proc playerMovementSpeedPercent*(
  sim: SimServer,
  player: Actor,
  x,
  y: int
): int =
  var resultSpeed =
    (sim.speedPercentAt(x, y) *
      player.statusSpeedPercent() *
      clamp(
        player.role.roleMovementSpeedPercent() +
          player.equippedSpeedPercentBonus(),
        60,
        140
      )) div 10_000
  if player.routeTicks > 0:
    resultSpeed = max(resultSpeed, BiomeWaystationRouteMinSpeedPercent)
  if player.surveyTicks > 0:
    resultSpeed = max(resultSpeed, BeaconSurveyMinSpeedPercent)
  let
    tx = clamp(x div WorldTileSize, 0, WorldWidthTiles - 1)
    ty = clamp(y div WorldTileSize, 0, WorldHeightTiles - 1)
    biome = sim.tileBiomeKind(tx, ty)
  if sim.biomeIsMastered(biome):
    resultSpeed = max(resultSpeed, BiomeMasteryMinSpeedPercent)
  resultSpeed

proc canOccupy*(sim: SimServer, x, y: int, bounds: SpriteBounds): bool =
  let
    worldX = x + bounds.x
    worldY = y + bounds.y
  if bounds.w <= 0 or bounds.h <= 0:
    return true
  if worldX < 0 or worldY < 0 or
      worldX + bounds.w > WorldWidthPixels or
      worldY + bounds.h > WorldHeightPixels:
    return false

  let
    startTx = max(0, worldX div WorldTileSize)
    startTy = max(0, worldY div WorldTileSize)
    endTx = min(
      WorldWidthTiles - 1,
      (worldX + bounds.w - 1) div WorldTileSize
    )
    endTy = min(
      WorldHeightTiles - 1,
      (worldY + bounds.h - 1) div WorldTileSize
    )

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.tileGroundKind(tx, ty).groundBlocks():
        return false
      if not sim.tiles[tileIndex(tx, ty)]:
        continue
      let
        kind = sim.terrainKinds[tileIndex(tx, ty)]
        terrainBounds = sim.terrainPropBounds(kind)
        terrainX = tx * WorldTileSize
        terrainY = ty * WorldTileSize
      if boundsOverlap(x, y, bounds, terrainX, terrainY, terrainBounds):
        return false
  true

proc clearSpawnArea*(sim: var SimServer, centerTx, centerTy, radius: int) =
  for ty in centerTy - radius .. centerTy + radius:
    for tx in centerTx - radius .. centerTx + radius:
      if inTileBounds(tx, ty):
        sim.tiles[tileIndex(tx, ty)] = false

proc clearProgressLane*(sim: var SimServer) =
  let centerTy = WorldHeightTiles div 2
  for ty in centerTy - LaneHalfHeightTiles .. centerTy + LaneHalfHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      if inTileBounds(tx, ty):
        sim.tiles[tileIndex(tx, ty)] = false
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 .. SafeZoneRightTiles:
      if inTileBounds(tx, ty):
        sim.tiles[tileIndex(tx, ty)] = false

proc terrainNoise(seed, tx, ty, salt: int): int =
  ## Returns stable local noise without consuming the gameplay RNG stream.
  let value = seed * 1103515245 + tx * 734287 + ty * 912931 + salt * 42349
  abs(value) mod 100

proc setGroundFeature(
  sim: var SimServer,
  tx,
  ty: int,
  ground: GroundKind,
  elevation: int
) =
  if not inTileBounds(tx, ty):
    return
  let index = tileIndex(tx, ty)
  sim.groundKinds[index] = ground
  sim.elevations[index] = clamp(elevation, 0, 5)
  if ground in {GroundWater, GroundShallowWater, GroundBridge}:
    sim.tiles[index] = false

proc clampRiverTx(tx, firstTx, lastTx: int): int =
  let
    lo = max(firstTx + RiverShallowHalfWidthTiles, 1)
    hi = min(lastTx - RiverShallowHalfWidthTiles, WorldWidthTiles - 2)
  if lo > hi:
    return clamp(tx, firstTx, lastTx)
  clamp(tx, lo, hi)

proc setRiverBand(
  sim: var SimServer,
  centerTx,
  ty,
  firstTx,
  lastTx: int,
  bridge: bool
) =
  if not inTileBounds(centerTx, ty):
    return
  for dx in -RiverShallowHalfWidthTiles .. RiverShallowHalfWidthTiles:
    let tx = centerTx + dx
    if tx < firstTx or tx > lastTx or not inTileBounds(tx, ty):
      continue
    let ground =
      if bridge:
        GroundBridge
      elif abs(dx) <= RiverDeepHalfWidthTiles:
        GroundWater
      else:
        GroundShallowWater
    sim.setGroundFeature(tx, ty, ground, 0)

proc buildMainRiverPath(
  sim: SimServer,
  systemIndex,
  firstTx,
  lastTx: int
): seq[tuple[tx, ty: int]] =
  ## Builds a stable north-south river centerline with small local meanders.
  let
    span = max(1, lastTx - firstTx + 1)
    base = firstTx + span div 2 + ((sim.seed + systemIndex * 11) mod 7) - 3
  var tx = clampRiverTx(base, firstTx, lastTx)
  for ty in 1 ..< WorldHeightTiles - 1:
    if ty > 1:
      let roll = terrainNoise(sim.seed, tx, ty, 71 + systemIndex)
      let drift =
        if roll < 28:
          -1
        elif roll > 72:
          1
        else:
          0
      tx = clampRiverTx(tx + drift, firstTx, lastTx)
    result.add((tx: tx, ty: ty))

proc pathTxAtTy(path: seq[tuple[tx, ty: int]], ty: int): int =
  for point in path:
    if point.ty == ty:
      return point.tx
  if path.len == 0:
    return 0
  path[path.len div 2].tx

proc carveRiverPath(
  sim: var SimServer,
  path: seq[tuple[tx, ty: int]],
  firstTx,
  lastTx,
  crossingTy: int
) =
  var
    previousTx = 0
    previousTy = 0
    havePrevious = false
  for point in path:
    let bridge = point.ty == crossingTy
    if havePrevious and point.ty == previousTy and point.tx != previousTx:
      let step = (if point.tx > previousTx: 1 else: -1)
      var tx = previousTx
      while tx != point.tx:
        tx += step
        sim.setRiverBand(tx, point.ty, firstTx, lastTx, bridge)
    elif havePrevious and abs(point.tx - previousTx) > 1:
      let step = (if point.tx > previousTx: 1 else: -1)
      var tx = previousTx
      while tx != point.tx:
        tx += step
        sim.setRiverBand(tx, point.ty, firstTx, lastTx, bridge)
    sim.setRiverBand(point.tx, point.ty, firstTx, lastTx, bridge)
    previousTx = point.tx
    previousTy = point.ty
    havePrevious = true

proc buildRiverBranchPath(
  sim: SimServer,
  mainPath: seq[tuple[tx, ty: int]],
  systemIndex,
  firstTx,
  lastTx,
  startTy,
  dirY,
  sideDir: int
): seq[tuple[tx, ty: int]] =
  ## Builds a fork that splits from the main river and keeps running to an edge.
  if startTy <= 1 or startTy >= WorldHeightTiles - 2 or dirY == 0:
    return
  var
    tx = clampRiverTx(mainPath.pathTxAtTy(startTy), firstTx, lastTx)
    ty = startTy
    steps = 0
  while ty > 0 and ty < WorldHeightTiles - 1:
    result.add((tx: tx, ty: ty))
    ty += dirY
    if ty <= 0 or ty >= WorldHeightTiles - 1:
      break
    let
      push = if steps mod 2 == 0: sideDir else: 0
      roll = terrainNoise(sim.seed, tx, ty, 113 + systemIndex * 5)
      drift =
        if roll < 18:
          -1
        elif roll > 82:
          1
        else:
          0
    tx = clampRiverTx(tx + push + drift, firstTx, lastTx)
    inc steps

proc addRiverCrossing(
  sim: var SimServer,
  path: seq[tuple[tx, ty: int]],
  crossingTy,
  firstTx,
  lastTx: int
) =
  if path.len == 0:
    return
  let crossingTx = path.pathTxAtTy(crossingTy)
  if crossingTx <= 0:
    return
  for crossing in sim.riverCrossings:
    if abs(crossing.tx - crossingTx) <= RiverShallowHalfWidthTiles and
        crossing.ty == crossingTy:
      return
  sim.setRiverBand(crossingTx, crossingTy, firstTx, lastTx, true)
  sim.riverCrossings.add(RiverCrossing(
    tx: crossingTx,
    ty: crossingTy,
    firstTy: 1,
    lastTy: WorldHeightTiles - 2
  ))

proc riverCrossingTyForSystem(systemIndex: int): int =
  ## Alternates bridge rows so the rightward route reads as a zig-zag.
  const offsets = [-3, 3, -2, 2]
  let centerTy = WorldHeightTiles div 2
  clamp(
    centerTy + offsets[systemIndex mod offsets.len],
    centerTy - LaneHalfHeightTiles + 1,
    centerTy + LaneHalfHeightTiles - 1
  )

proc seedLongRiverSystem(
  sim: var SimServer,
  systemIndex,
  firstSegment,
  lastSegment: int
) =
  ## Carves one wide vertical river barrier, plus forked tributaries.
  let
    crossingTy = riverCrossingTyForSystem(systemIndex)
    firstTx = SafeZoneRightTiles + firstSegment * ExpeditionBiomeSpanTiles
    lastTx = min(
      WorldWidthTiles - 1,
      SafeZoneRightTiles + (lastSegment + 1) * ExpeditionBiomeSpanTiles - 1
    )
  if firstTx >= WorldWidthTiles:
    return

  let mainPath = sim.buildMainRiverPath(systemIndex, firstTx, lastTx)
  sim.carveRiverPath(mainPath, firstTx, lastTx, crossingTy)
  sim.addRiverCrossing(mainPath, crossingTy, firstTx, lastTx)

  let sideDir = if (sim.seed + systemIndex) mod 2 == 0: 1 else: -1
  if systemIndex mod 2 == 1:
    let branchDown = sim.buildRiverBranchPath(
      mainPath,
      systemIndex,
      firstTx,
      lastTx,
      max(2, crossingTy - 5),
      1,
      sideDir
    )
    sim.carveRiverPath(branchDown, firstTx, lastTx, crossingTy)
    sim.addRiverCrossing(branchDown, crossingTy, firstTx, lastTx)

  if systemIndex mod 4 == 3:
    let branchUp = sim.buildRiverBranchPath(
      mainPath,
      systemIndex + 31,
      firstTx,
      lastTx,
      min(WorldHeightTiles - 3, crossingTy + 5),
      -1,
      -sideDir
    )
    sim.carveRiverPath(branchUp, firstTx, lastTx, crossingTy)
    sim.addRiverCrossing(branchUp, crossingTy, firstTx, lastTx)

proc seedLongRiverSystems(sim: var SimServer) =
  ## Spreads readable north-south river barriers across the rightward journey.
  sim.riverCrossings.setLen(0)
  let totalSegments = ExpeditionCycleCount * BiomeCount
  var
    firstSegment = 0
    systemIndex = 0
  while firstSegment < totalSegments:
    let lastSegment = min(
      totalSegments - 1,
      firstSegment + RiverSystemSpanSegments - 1
    )
    sim.seedLongRiverSystem(systemIndex, firstSegment, lastSegment)
    firstSegment += RiverSystemStrideSegments
    inc systemIndex

proc seedSegmentLake(
  sim: var SimServer,
  segmentIndex,
  firstTx,
  lastTx: int,
  biome: BiomeKind
) =
  ## Adds off-lane lakes, oases, tarns, cave pools, and ruined cisterns.
  let
    centerTy = WorldHeightTiles div 2
    cx = clamp(
      firstTx + (max(1, lastTx - firstTx) * 3) div 4,
      firstTx + 2,
      lastTx - 2
    )
    cy =
      if segmentIndex mod 2 == 0:
        clamp(centerTy + 5, 2, WorldHeightTiles - 3)
      else:
        clamp(centerTy - 5, 2, WorldHeightTiles - 3)
    rx =
      case biome
      of BiomeSwamp: 1
      else: 2
    ry =
      case biome
      of BiomeSwamp: 1
      else: 1
  for dy in -ry - 1 .. ry + 1:
    for dx in -rx - 1 .. rx + 1:
      let
        tx = cx + dx
        ty = cy + dy
      if tx < firstTx or tx > lastTx:
        continue
      if sim.tileGroundKind(tx, ty) == GroundBridge:
        continue
      let score = dx * dx * ry * ry + dy * dy * rx * rx
      if score <= rx * rx * ry * ry:
        sim.setGroundFeature(tx, ty, GroundWater, 0)
      elif score <= (rx + 1) * (rx + 1) * (ry + 1) * (ry + 1):
        sim.setGroundFeature(tx, ty, GroundShallowWater, 0)

proc seedSegmentRidges(
  sim: var SimServer,
  segmentIndex,
  firstTx,
  lastTx: int,
  biome: BiomeKind
) =
  ## Raises high, sight-blocking side ridges without closing the central lane.
  let centerTy = WorldHeightTiles div 2
  for tx in firstTx .. lastTx:
    let bend = ((tx + segmentIndex * 3 + sim.seed) mod 5) - 2
    for ridgeBase in [centerTy - 5, centerTy + 5]:
      let ty = clamp(ridgeBase + bend div 2, 1, WorldHeightTiles - 2)
      if abs(ty - centerTy) <= LaneHalfHeightTiles:
        continue
      if sim.tileGroundKind(tx, ty) in {
          GroundWater,
          GroundShallowWater,
          GroundBridge
        }:
        continue
      let index = tileIndex(tx, ty)
      sim.elevations[index] = max(sim.elevations[index], 4)
      if biome in {BiomeCave, BiomeRuins, BiomeSnow} or
          terrainNoise(sim.seed, tx, ty, 41) > 44:
        sim.tiles[index] = true

proc seedProceduralLandforms(sim: var SimServer) =
  ## Adds repeated adventure landmarks in the terrain itself: rivers, lakes, ridges.
  sim.seedLongRiverSystems()
  for segmentIndex in 0 ..< ExpeditionCycleCount * BiomeCount:
    let
      firstTx = SafeZoneRightTiles + segmentIndex * ExpeditionBiomeSpanTiles
      lastTx = min(
        WorldWidthTiles - 1,
        firstTx + ExpeditionBiomeSpanTiles - 1
      )
      biome = segmentIndex.biomeForSegmentIndex()
    if firstTx >= WorldWidthTiles:
      break
    sim.seedSegmentLake(segmentIndex, firstTx, lastTx, biome)
    sim.seedSegmentRidges(segmentIndex, firstTx, lastTx, biome)

proc denseTerrainThreshold(biome: BiomeKind, laneDistance: int): int =
  if laneDistance <= LaneHalfHeightTiles:
    if laneDistance < 3:
      return 0
    return case biome
      of BiomeForest:
        20
      of BiomeSwamp:
        14
      of BiomeCave, BiomeRuins:
        12
      of BiomeSnow:
        10
      of BiomePlains:
        8
      of BiomeDesert:
        4
      of BiomeOrigin:
        0
  result =
    case biome
    of BiomeForest:
      58
    of BiomeSwamp:
      46
    of BiomeCave, BiomeRuins:
      42
    of BiomeSnow:
      36
    of BiomePlains:
      32
    of BiomeDesert:
      20
    of BiomeOrigin:
      8
  if laneDistance >= LaneHalfHeightTiles + 3:
    result += 8

proc seedDenseBiomeTerrain*(sim: var SimServer) =
  ## Adds biome-flavored off-route groves, rubble, rocks, and blockers.
  let centerTy = WorldHeightTiles div 2
  for ty in 0 ..< WorldHeightTiles:
    for tx in SafeZoneRightTiles + 1 ..< WorldWidthTiles:
      let
        laneDistance = abs(ty - centerTy)
        biome = sim.tileBiomeKind(tx, ty)
        threshold = denseTerrainThreshold(biome, laneDistance)
      if threshold <= 0:
        continue
      let ground = sim.tileGroundKind(tx, ty)
      if ground in {GroundWater, GroundShallowWater, GroundBridge}:
        continue
      let
        localNoise = terrainNoise(sim.seed, tx, ty, 73)
        groveNoise = terrainNoise(sim.seed, tx div 2, ty div 2, 91)
        index = tileIndex(tx, ty)
      if localNoise < threshold or groveNoise < threshold div 2:
        sim.tiles[index] = true
      if sim.tiles[index] and biome in {BiomeForest, BiomeCave, BiomeRuins} and
          terrainNoise(sim.seed, tx, ty, 127) > 90:
        sim.elevations[index] = max(sim.elevations[index], 4)

proc seedBiomeGrounds*(sim: var SimServer) =
  ## Creates deterministic biome bands, base terrain, roads, and blockers.
  sim.groundKinds.setLen(WorldWidthTiles * WorldHeightTiles)
  sim.biomeKinds.setLen(WorldWidthTiles * WorldHeightTiles)
  sim.elevations.setLen(WorldWidthTiles * WorldHeightTiles)
  let centerTy = WorldHeightTiles div 2
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      let
        index = tileIndex(tx, ty)
        biome = biomeForTileX(tx)
        laneDistance = abs(ty - centerTy)
        noise = terrainNoise(sim.seed, tx, ty, 3)
        ridgeNoise = terrainNoise(sim.seed, tx, ty, 19)
      var ground = biome.baseGroundForBiome()
      var elevation =
        case biome
        of BiomeOrigin, BiomeSwamp:
          0
        of BiomeForest, BiomePlains, BiomeDesert:
          1
        of BiomeSnow, BiomeCave, BiomeRuins:
          2
      if laneDistance > 2:
        inc elevation
      if ridgeNoise > 72:
        inc elevation
      elif ridgeNoise < 18:
        dec elevation
      if tx < SafeZoneRightTiles:
        ground = if laneDistance <= 1: GroundRoad else: GroundGrass
        elevation = 0
      elif laneDistance == 0:
        ground =
          if biome == BiomeSwamp:
            GroundMud
          elif biome == BiomeCave or biome == BiomeRuins:
            GroundRoad
          else:
            GroundRoad
      elif laneDistance <= LaneHalfHeightTiles:
        case biome
        of BiomeSwamp:
          ground =
            if noise < 18:
              GroundShallowWater
            else:
              GroundMud
        of BiomeDesert:
          ground =
            if noise < 35: GroundDune else: GroundSand
        of BiomeSnow:
          ground = GroundSnow
        of BiomeCave:
          ground = GroundCave
        of BiomeRuins:
          ground = GroundRuins
        of BiomePlains:
          ground =
            if noise < 45: GroundFertile else: GroundGrass
        else:
          ground = biome.baseGroundForBiome()
      else:
        case biome
        of BiomeSwamp:
          ground =
            if noise < 20:
              GroundWater
            elif noise < 50:
              GroundShallowWater
            else:
              GroundMud
        of BiomeDesert:
          ground =
            if noise < 55: GroundDune else: GroundSand
        of BiomeSnow:
          ground = GroundSnow
        of BiomeCave:
          ground =
            if noise < 8: GroundWater else: GroundCave
        of BiomeRuins:
          ground = GroundRuins
        else:
          ground = biome.baseGroundForBiome()
      sim.groundKinds[index] = ground
      sim.biomeKinds[index] = biome
      sim.elevations[index] = clamp(elevation, 0, 5)
  sim.seedProceduralLandforms()

proc seedBrush*(sim: var SimServer) =
  let patchCount = max(
    12,
    (WorldWidthTiles * WorldHeightTiles) div TerrainPatchDivisor
  )
  for _ in 0 ..< patchCount:
    let
      baseTx = sim.rng.rand(WorldWidthTiles - 1)
      baseTy = sim.rng.rand(WorldHeightTiles - 1)
      patchW = 1 + sim.rng.rand(4)
      patchH = 1 + sim.rng.rand(4)
    for dy in 0 ..< patchH:
      for dx in 0 ..< patchW:
        let tx = baseTx + dx
        let ty = baseTy + dy
        if inTileBounds(tx, ty) and sim.rng.rand(99) < 72:
          sim.tiles[tileIndex(tx, ty)] = true

proc seedRoleGear*(sim: var SimServer) =
  let centerY = WorldHeightPixels div 2
  sim.pickups.add(Pickup(
    x: WorldTileSize * 2,
    y: centerY - 60,
    kind: PickupTankGear,
    value: 0
  ))
  sim.pickups.add(Pickup(
    x: WorldTileSize * 4,
    y: centerY - 4,
    kind: PickupDpsGear,
    value: 0
  ))
  sim.pickups.add(Pickup(
    x: WorldTileSize * 2,
    y: centerY + 52,
    kind: PickupHealerGear,
    value: 0
  ))

proc randomTerrainKind(rng: var Rand): TerrainKind =
  ## Chooses one terrain prop with more trees than small debris.
  let roll = rng.rand(99)
  if roll < 32:
    TerrainTree
  elif roll < 62:
    TerrainEvergreen
  elif roll < 76:
    TerrainRock
  elif roll < 89:
    TerrainLog
  else:
    TerrainStump

proc randomTerrainKindForBiome(rng: var Rand, biome: BiomeKind): TerrainKind =
  ## Chooses biome-flavored blockers and props.
  let roll = rng.rand(99)
  case biome
  of BiomeForest:
    if roll < 42: TerrainTree
    elif roll < 70: TerrainEvergreen
    elif roll < 84: TerrainBush
    elif roll < 94: TerrainLog
    else: TerrainStump
  of BiomeDesert:
    if roll < 55: TerrainCactus
    elif roll < 72: TerrainRock
    elif roll < 86: TerrainStone
    else: TerrainStump
  of BiomeSnow:
    if roll < 44: TerrainEvergreen
    elif roll < 70: TerrainRock
    elif roll < 86: TerrainLog
    else: TerrainStone
  of BiomeCave:
    if roll < 52: TerrainRock
    elif roll < 78: TerrainStone
    elif roll < 90: TerrainGold
    else: TerrainCave
  of BiomeRuins:
    if roll < 34: TerrainRock
    elif roll < 58: TerrainGoblinTotem
    elif roll < 78: TerrainGoblinHut
    else: TerrainGold
  of BiomePlains:
    if roll < 42: TerrainWheat
    elif roll < 62: TerrainBush
    elif roll < 78: TerrainTree
    else: TerrainRock
  of BiomeSwamp:
    if roll < 38: TerrainBush
    elif roll < 62: TerrainLog
    elif roll < 78: TerrainTree
    else: TerrainRock
  else:
    rng.randomTerrainKind()

proc seedTerrainProps*(sim: var SimServer) =
  ## Creates visual terrain props for every solid terrain tile.
  sim.terrainProps.setLen(0)
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      if sim.tiles[tileIndex(tx, ty)]:
        let kind = sim.rng.randomTerrainKindForBiome(
          sim.tileBiomeKind(tx, ty)
        )
        sim.terrainKinds[tileIndex(tx, ty)] = kind
        sim.terrainProps.add(TerrainProp(
          tx: tx,
          ty: ty,
          kind: kind
        ))

proc landmarkWorldX*(landmark: Landmark): int =
  landmark.tx * WorldTileSize

proc landmarkWorldY*(landmark: Landmark): int =
  landmark.ty * WorldTileSize

proc landmarkIsResource(kind: LandmarkKind): bool =
  kind in {LandmarkWood, LandmarkFood, LandmarkStone, LandmarkGold}

proc biomeSegmentRange*(
  segmentIndex: int
): tuple[biome: BiomeKind, firstTx, lastTx, cycle: int] =
  result.biome = segmentIndex.biomeForSegmentIndex()
  result.firstTx = SafeZoneRightTiles + segmentIndex * ExpeditionBiomeSpanTiles
  result.lastTx = min(
    WorldWidthTiles - 1,
    result.firstTx + ExpeditionBiomeSpanTiles - 1
  )
  result.cycle = max(0, segmentIndex) div BiomeCount

proc adventureSegmentRangeForTileX*(
  tx: int
): tuple[biome: BiomeKind, firstTx, lastTx, cycle: int] =
  let segment = max(0, tx.adventureSegmentIndexForTileX())
  segment.biomeSegmentRange()

proc addLandmark(
  sim: var SimServer,
  kind: LandmarkKind,
  tx,
  ty: int,
  hp = 1
) =
  if not inTileBounds(tx, ty):
    return
  var
    placeTx = tx
    placeTy = ty
  if sim.tileGroundKind(placeTx, placeTy) in {
      GroundWater,
      GroundShallowWater,
      GroundBridge
    }:
    var found = false
    for radius in 1 .. RiverShallowHalfWidthTiles + 3:
      for direction in [-1, 1]:
        let nx = tx + direction * radius
        if inTileBounds(nx, ty) and
            sim.tileGroundKind(nx, ty) notin {
              GroundWater,
              GroundShallowWater,
              GroundBridge
            }:
          placeTx = nx
          found = true
          break
      if found:
        break
    if not found:
      for radius in 1 .. 3:
        for dy in -radius .. radius:
          for dx in -radius .. radius:
            let
              nx = tx + dx
              ny = ty + dy
            if inTileBounds(nx, ny) and
                sim.tileGroundKind(nx, ny) notin {
                  GroundWater,
                  GroundShallowWater,
                  GroundBridge
                }:
              placeTx = nx
              placeTy = ny
              found = true
              break
          if found:
            break
        if found:
          break
  sim.landmarks.add(Landmark(
    tx: placeTx,
    ty: placeTy,
    kind: kind,
    hp: hp,
    done: false,
    progress: 0
  ))
  sim.clearSpawnArea(placeTx, placeTy, 1)
  for py in placeTy - 1 .. placeTy + 1:
    for px in placeTx - 1 .. placeTx + 1:
      if inTileBounds(px, py):
        let
          index = tileIndex(px, py)
          current = sim.groundKinds[index]
        sim.setGroundFeature(px, py, current, min(sim.elevations[index], 1))

proc resourceKindsForBiome(
  biome: BiomeKind
): tuple[first, second: LandmarkKind] =
  case biome
  of BiomeForest:
    (LandmarkWood, LandmarkFood)
  of BiomePlains:
    (LandmarkFood, LandmarkStone)
  of BiomeSwamp:
    (LandmarkWood, LandmarkStone)
  of BiomeDesert:
    (LandmarkWood, LandmarkStone)
  of BiomeSnow:
    (LandmarkFood, LandmarkStone)
  of BiomeCave:
    (LandmarkStone, LandmarkGold)
  of BiomeRuins:
    (LandmarkGold, LandmarkStone)
  else:
    (LandmarkWood, LandmarkFood)

proc lairCacheCarriesForBiome*(biome: BiomeKind): tuple[first, second: CarryKind] =
  ## Returns the practical supplies hidden in one biome's monster den.
  let resources = biome.resourceKindsForBiome()
  (resources.first.carryForLandmark(), resources.second.carryForLandmark())

proc seedLandmarks*(sim: var SimServer) =
  ## Places resources, camps, beacons, and the far expedition gate.
  sim.landmarks.setLen(0)
  let centerTy = WorldHeightTiles div 2
  for segmentIndex in 0 ..< ExpeditionCycleCount * BiomeCount:
    let
      range = segmentIndex.biomeSegmentRange()
      biome = range.biome
      span = max(1, range.lastTx - range.firstTx)
      resources = biome.resourceKindsForBiome()
      upperTy = clamp(centerTy - 3, 1, WorldHeightTiles - 2)
      lowerTy = clamp(centerTy + 3, 1, WorldHeightTiles - 2)
      campTy =
        if biome.biomeProgressValue() mod 2 == 0:
          upperTy
        else:
          lowerTy
      shrineTy =
        if biome.biomeProgressValue() mod 2 == 0:
          lowerTy
        else:
          upperTy
      rescueTy =
        if biome.biomeProgressValue() mod 2 == 0:
          clamp(centerTy + 5, 1, WorldHeightTiles - 2)
        else:
          clamp(centerTy - 5, 1, WorldHeightTiles - 2)
      lairTy =
        if biome.biomeProgressValue() mod 2 == 0:
          clamp(centerTy - 5, 1, WorldHeightTiles - 2)
        else:
          clamp(centerTy + 5, 1, WorldHeightTiles - 2)
      waystationTy =
        if biome.biomeProgressValue() mod 2 == 0:
          clamp(centerTy + 2, 1, WorldHeightTiles - 2)
        else:
          clamp(centerTy - 2, 1, WorldHeightTiles - 2)
    sim.addLandmark(
      resources.first,
      range.firstTx + max(1, span div 4),
      upperTy,
      ResourceNodeHp
    )
    sim.addLandmark(
      resources.second,
      range.firstTx + max(2, span div 2),
      lowerTy,
      ResourceNodeHp
    )
    if biome != BiomeForest or range.cycle > 0:
      sim.addLandmark(
        LandmarkCamp,
        range.firstTx + max(1, span div 3),
        campTy,
        1
      )
    sim.addLandmark(
      LandmarkShrine,
      range.firstTx + max(3, (span * 2) div 3),
      shrineTy,
      1
    )
    sim.addLandmark(
      LandmarkRescue,
      range.firstTx + max(2, (span * 3) div 4),
      rescueTy,
      1
    )
    sim.addLandmark(
      LandmarkLair,
      range.firstTx + max(2, span div 2),
      lairTy,
      LairHp
    )
    sim.addLandmark(
      LandmarkWaystation,
      range.firstTx + max(4, (span * 5) div 6),
      waystationTy,
      1
    )
    sim.addLandmark(
      LandmarkBeacon,
      max(range.firstTx + 2, range.lastTx - 2),
      centerTy,
      1
    )
  sim.addLandmark(
    LandmarkFinalGate,
    WorldWidthTiles - 3,
    centerTy,
    1
  )

proc nextMobAttackCooldown(rng: var Rand, kind: MobKind): int =
  ## Returns the cooldown before the next mob hit.
  case kind
  of SnakeMob, WolfMob, ScorpionMob, BatMob:
    45 + rng.rand(30)
  of TrollMob, GoblinMob, SlimeMob, WraithMob:
    16 + rng.rand(14)
  of BearMob, YetiMob:
    28 + rng.rand(18)
  of BossMob:
    35 + rng.rand(25)

proc mobMaxHp*(kind: MobKind, x: int): int =
  let zone = mobZoneX(x)
  case kind
  of SnakeMob:
    SnakeHp + zone
  of TrollMob:
    TrollHp + zone * 2
  of BossMob:
    BossHp + zone * 3
  of WolfMob:
    WolfHp + zone
  of BearMob:
    BearHp + zone * 2
  of GoblinMob:
    GoblinHp + zone * 2
  of ScorpionMob:
    ScorpionHp + zone
  of SlimeMob:
    SlimeHp + zone
  of YetiMob:
    YetiHp + zone * 2
  of BatMob:
    BatHp + zone
  of WraithMob:
    WraithHp + zone * 2

proc mobDamage(mob: Mob): int =
  let zone = mobZoneX(mob.x)
  case mob.kind
  of SnakeMob, WolfMob, BatMob:
    1 + zone div 4
  of ScorpionMob, SlimeMob, TrollMob, GoblinMob:
    2 + zone div 3
  of BearMob, YetiMob, WraithMob:
    2 + zone div 2
  of BossMob:
    3 + zone div 2

proc canSpawnMobAt*(
  sim: SimServer,
  px, py: int,
  bounds: SpriteBounds
): bool =
  if not sim.canOccupy(px, py, bounds):
    return false

  let mobSpacingSq = MinMobSpacing * MinMobSpacing
  for mob in sim.mobs:
    let
      ax = boundsCenterX(px, bounds)
      ay = boundsCenterY(py, bounds)
      bx = boundsCenterX(mob.x, mob.bounds)
      by = boundsCenterY(mob.y, mob.bounds)
    if distanceSquared(ax, ay, bx, by) < mobSpacingSq:
      return false

  if sim.players.len > 0:
    for player in sim.players:
      let
        ax = boundsCenterX(px, bounds)
        ay = boundsCenterY(py, bounds)
        bx = boundsCenterX(player.x, player.bounds)
        by = boundsCenterY(player.y, player.bounds)
      if distanceSquared(ax, ay, bx, by) <
          MinPlayerSpawnSpacing * MinPlayerSpawnSpacing:
        return false

  true

proc spawnOneMob*(
  sim: var SimServer,
  kind: MobKind,
  sprite: Sprite,
  hp: int
): bool =
  discard sprite
  discard hp
  let species = kind.defaultSpeciesForKind()
  let bounds = sim.mobBoundsFor(species)
  for _ in 0 ..< 128:
    let
      tx = SafeZoneRightTiles + sim.rng.rand(WorldWidthTiles - SafeZoneRightTiles - 1)
      centerTy = WorldHeightTiles div 2
      ty = clamp(centerTy - LaneHalfHeightTiles + sim.rng.rand(LaneHalfHeightTiles * 2), 0, WorldHeightTiles - 1)
      px = tx * WorldTileSize
      py = ty * WorldTileSize
    if sim.canSpawnMobAt(px, py, bounds):
      sim.mobs.add Mob(
        kind: kind,
        species: species,
        x: px,
        y: py,
        sprite: sim.mobSpriteFor(species),
        bounds: bounds,
        wanderCooldown: MobSpawnWanderCooldown +
          sim.rng.rand(MobSpawnWanderJitter),
        hp: mobMaxHp(kind, px),
        attackCooldown: sim.rng.nextMobAttackCooldown(kind)
      )
      return true
  false

proc spawnOneMobInRange*(
  sim: var SimServer,
  species: MobSpecies,
  firstTx,
  lastTx: int
): bool =
  ## Spawns one mob inside a biome range while preserving the main lane.
  if species == SpeciesNone:
    return false
  let kind = species.speciesKind()
  let
    bounds = sim.mobBoundsFor(species)
    lo = clamp(firstTx, SafeZoneRightTiles, WorldWidthTiles - 1)
    hi = clamp(max(firstTx, lastTx), lo, WorldWidthTiles - 1)
  for _ in 0 ..< 128:
    let
      tx = lo + sim.rng.rand(max(0, hi - lo))
      centerTy = WorldHeightTiles div 2
      ty = clamp(
        centerTy - LaneHalfHeightTiles +
          sim.rng.rand(LaneHalfHeightTiles * 2),
        0,
        WorldHeightTiles - 1
      )
      px = tx * WorldTileSize
      py = ty * WorldTileSize
    if sim.canSpawnMobAt(px, py, bounds):
      sim.mobs.add Mob(
        kind: kind,
        species: species,
        x: px,
        y: py,
        sprite: sim.mobSpriteFor(species),
        bounds: bounds,
        wanderCooldown: MobSpawnWanderCooldown +
          sim.rng.rand(MobSpawnWanderJitter),
        hp: mobMaxHp(kind, px),
        attackCooldown: sim.rng.nextMobAttackCooldown(kind)
      )
      return true
  false

proc spawnOneMobInRange*(
  sim: var SimServer,
  kind: MobKind,
  firstTx,
  lastTx: int
): bool =
  sim.spawnOneMobInRange(kind.defaultSpeciesForKind(), firstTx, lastTx)

proc spawnMobs*(
  sim: var SimServer,
  count: int,
  kind: MobKind,
  sprite: Sprite,
  hp: int
) =
  var spawned = 0
  while spawned < count:
    if not sim.spawnOneMob(kind, sprite, hp):
      break
    inc spawned

proc snakeCount*(sim: SimServer): int =
  for mob in sim.mobs:
    if mob.kind != BossMob:
      inc result

proc hasBoss*(sim: SimServer): bool =
  for mob in sim.mobs:
    if mob.kind == BossMob:
      return true

proc seedBiomeMobs*(sim: var SimServer) =
  ## Seeds the expedition with biome-themed encounters.
  for segmentIndex in 0 ..< ExpeditionCycleCount * BiomeCount:
    let
      range = segmentIndex.biomeSegmentRange()
      biome = range.biome
    let species = biome.monsterSpeciesForBiome()
    for item in species:
      discard sim.spawnOneMobInRange(item, range.firstTx, range.lastTx)
    let extras =
      case biome
      of BiomeForest: 3
      of BiomePlains: 3
      of BiomeSwamp: 4
      of BiomeDesert: 4
      of BiomeSnow: 4
      of BiomeCave: 5
      of BiomeRuins: 5
      else: 0
    for _ in 0 ..< extras:
      discard sim.spawnOneMobInRange(
        sim.rng.randomMonsterSpeciesForBiome(biome),
        range.firstTx,
        range.lastTx
      )

proc mobAttackRange*(mob: Mob): int =
  ## Returns the distance where one mob can start an attack.
  let base = max(4, (12 + max(mob.bounds.w, mob.bounds.h)) div 2)
  case mob.species.attackStyle()
  of AttackRanged:
    max(base, WorldTileSize * 2)
  of AttackLine:
    max(base, WorldTileSize * 3)
  of AttackCone:
    max(base, WorldTileSize * 2)
  of AttackTrap:
    max(base, WorldTileSize * 2)
  of AttackSupport:
    max(base, WorldTileSize * 2)
  of AttackSwarm:
    max(base, WorldTileSize + 10)
  of AttackSlam:
    max(base, WorldTileSize + 8)
  of AttackAura:
    max(base, WorldTileSize * 2)
  of AttackLunge:
    base

proc mobSightRange*(mob: Mob): int =
  ## Returns the distance where one mob starts chasing players.
  if mob.species.speciesHarasses():
    return MobSightRadius * 2
  if mob.species.speciesLeadsPack() or mob.species.speciesSupportsPack():
    return (MobSightRadius * 5) div 2
  if mob.species == SpeciesGateTitan:
    return MobSightRadius * 3
  MobSightRadius

proc mobTelegraphOffsetY*(mob: Mob): int =
  ## Returns the visual y offset for one telegraphing mob.
  if mob.attackPhase != MobTelegraph:
    return 0
  let
    stepCount = MobTelegraphBounces * 4
    step = (mob.attackTicks * stepCount) div max(1, MobTelegraphTicks)
  case step mod 4
  of 0:
    -MobTelegraphLift
  of 1:
    0
  of 2:
    MobTelegraphLift
  else:
    0

proc mobDrawY*(mob: Mob): int =
  ## Returns the visual y position for one mob sprite.
  mob.y + mob.mobTelegraphOffsetY()

proc mobMaxHp*(mob: Mob): int =
  ## Returns the maximum hit points for one mob.
  mobMaxHp(mob.kind, mob.x)

proc playerIdIsAlive(players: openArray[Actor], playerId: int): bool =
  ## Returns true when a player id belongs to a living player.
  for player in players:
    if player.id == playerId and player.lives > 0:
      return true
  false

proc pruneMobAttackers(
  mob: var Mob,
  players: openArray[Actor],
  tickCount: int
) =
  ## Removes stale or inactive attackers from one mob.
  let count = min(mob.attackerIds.len, mob.attackerTicks.len)
  var writeIndex = 0
  for i in 0 ..< count:
    if tickCount - mob.attackerTicks[i] > CoopAttackWindow:
      continue
    if not players.playerIdIsAlive(mob.attackerIds[i]):
      continue
    if writeIndex != i:
      mob.attackerIds[writeIndex] = mob.attackerIds[i]
      mob.attackerTicks[writeIndex] = mob.attackerTicks[i]
    inc writeIndex
  mob.attackerIds.setLen(writeIndex)
  mob.attackerTicks.setLen(writeIndex)

proc rememberMobAttacker(mob: var Mob, playerId, tickCount: int) =
  ## Records one recent player attacker on a mob.
  for i in 0 ..< min(mob.attackerIds.len, mob.attackerTicks.len):
    if mob.attackerIds[i] == playerId:
      mob.attackerTicks[i] = tickCount
      return
  mob.attackerIds.add(playerId)
  mob.attackerTicks.add(tickCount)

proc partyFocusRoleCount*(
  mob: Mob,
  players: openArray[Actor],
  tickCount: int
): int =
  ## Counts distinct live combat roles focusing this mob in the co-op window.
  var
    tank = false
    dps = false
    healer = false
  let count = min(mob.attackerIds.len, mob.attackerTicks.len)
  for attackerIndex in 0 ..< count:
    if tickCount - mob.attackerTicks[attackerIndex] > CoopAttackWindow:
      continue
    for player in players:
      if player.id != mob.attackerIds[attackerIndex] or player.lives <= 0:
        continue
      case player.role
      of RoleTank:
        tank = true
      of RoleDps:
        dps = true
      of RoleHealer:
        healer = true
      of RoleUnarmed:
        discard
      break
  result = (if tank: 1 else: 0) + (if dps: 1 else: 0) +
    (if healer: 1 else: 0)

proc partyFocusDamageBonus*(
  mob: Mob,
  players: openArray[Actor],
  tickCount: int
): int =
  ## Returns the normal-attack bonus for mixed-role focus fire.
  let roleCount = mob.partyFocusRoleCount(players, tickCount)
  if roleCount >= 3:
    PartyFocusThreeRoleDamageBonus
  elif roleCount >= 2:
    PartyFocusTwoRoleDamageBonus
  else:
    0

proc bossStaggered*(mob: Mob): bool =
  ## Returns true while coordinated role focus is suppressing boss pressure.
  mob.kind == BossMob and mob.staggerTicks > 0

proc refreshCoopState(
  mob: var Mob,
  players: openArray[Actor],
  tickCount: int
) =
  ## Keeps recent-attacker tracking fresh for stats without hard co-op gates.
  mob.pruneMobAttackers(players, tickCount)

proc findPlayerSpawn*(
  sim: SimServer,
  bounds: SpriteBounds,
  ignorePlayerIndex = -1
): tuple[x, y: int] =
  ## Finds a spawn point for one player.
  let
    centerTx = 2
    centerTy = WorldHeightTiles div 2
    minSpacingSq = MinPlayerSpawnSpacing * MinPlayerSpawnSpacing

  for radius in 0 .. 8:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          tx = centerTx + dx
          ty = centerTy + dy
        if not inTileBounds(tx, ty):
          continue
        let
          px = tx * WorldTileSize
          py = ty * WorldTileSize
        if not sim.canOccupy(px, py, bounds):
          continue
        var tooClose = false
        for i in 0 ..< sim.players.len:
          if i == ignorePlayerIndex:
            continue
          let player = sim.players[i]
          let
            ax = boundsCenterX(px, bounds)
            ay = boundsCenterY(py, bounds)
            bx = boundsCenterX(player.x, player.bounds)
            by = boundsCenterY(player.y, player.bounds)
          if distanceSquared(ax, ay, bx, by) < minSpacingSq:
            tooClose = true
            break
        if not tooClose:
          return (px, py)

  (centerTx * WorldTileSize, centerTy * WorldTileSize)

proc applyRole*(player: var Actor, role: PlayerRole) =
  let oldMax = max(1, player.maxHp)
  let oldHp = max(1, player.lives)
  player.role = role
  player.maxHp = role.roleMaxHp() + player.equippedMaxHpBonus()
  player.lives = min(player.maxHp, max(1, (oldHp * player.maxHp + oldMax - 1) div oldMax))
  player.mana = MaxPlayerMana
  player.abilityTicks = 0
  player.abilityHoldTicks = 0

proc resetPlayerAtSpawn*(sim: var SimServer, playerIndex: int) =
  ## Fully resets one player and puts them back at spawn.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    form = sim.players[playerIndex].form
    bounds = sim.playerCollisionBoundsFor(form, FaceDown)
  var spawn = sim.findPlayerSpawn(bounds, playerIndex)
  var bestCampTx = -1
  for landmark in sim.landmarks:
    if landmark.kind != LandmarkCamp or not landmark.done:
      continue
    if landmark.tx <= bestCampTx:
      continue
    for radius in 0 .. 3:
      var found = false
      for dy in -radius .. radius:
        for dx in -radius .. radius:
          let
            tx = landmark.tx + dx
            ty = landmark.ty + dy
          if not inTileBounds(tx, ty):
            continue
          let
            px = tx * WorldTileSize
            py = ty * WorldTileSize
          if sim.canOccupy(px, py, bounds):
            spawn = (px, py)
            bestCampTx = landmark.tx
            found = true
            break
        if found:
          break
      if found:
        break
  sim.players[playerIndex].x = spawn.x
  sim.players[playerIndex].y = spawn.y
  sim.players[playerIndex].sprite = sim.playerArts[form].sprites[PlayerFront]
  sim.players[playerIndex].bounds = bounds
  sim.players[playerIndex].facing = FaceDown
  sim.players[playerIndex].attackTicks = 0
  sim.players[playerIndex].attackResolved = false
  sim.players[playerIndex].abilityTicks = 0
  sim.players[playerIndex].abilityHoldTicks = 0
  sim.players[playerIndex].message = ""
  sim.players[playerIndex].pingKind = PingNone
  sim.players[playerIndex].pingTicks = 0
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].carryX = 0
  sim.players[playerIndex].carryY = 0
  sim.players[playerIndex].lives = sim.players[playerIndex].maxHp
  sim.players[playerIndex].invulnTicks = 30
  sim.players[playerIndex].coins = 0
  sim.players[playerIndex].clearCarryInventory()
  sim.players[playerIndex].carrySelectLockTicks = 0
  sim.players[playerIndex].slowTicks = 0
  sim.players[playerIndex].chillTicks = 0
  sim.players[playerIndex].poisonTicks = 0
  sim.players[playerIndex].exhaustionTicks = 0
  sim.players[playerIndex].routeTicks = 0
  sim.players[playerIndex].surveyTicks = 0
  sim.players[playerIndex].guideTicks = 0
  sim.players[playerIndex].huntTicks = 0
  sim.players[playerIndex].triumphTicks = 0
  sim.players[playerIndex].rationTicks = 0
  sim.players[playerIndex].moraleTicks = 0
  sim.players[playerIndex].downedTicks = 0
  sim.players[playerIndex].rescueTicks = 0

proc setPlayerMessage*(
  sim: var SimServer,
  playerIndex: int,
  message: string
) =
  ## Updates speech text and raises a short structured ping when recognized.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.players[playerIndex].message = message
  let ping = message.playerPingForMessage()
  sim.players[playerIndex].pingKind = ping
  sim.players[playerIndex].pingTicks =
    if ping == PingNone:
      0
    else:
      PingDurationTicks
  inc sim.scoreRevision

proc addPlayer*(sim: var SimServer, address: string): int =
  ## Adds one player at a valid spawn point.
  inc sim.nextPlayerId
  let form = sim.nextPlayerId.playerFormForId()
  let bounds = sim.playerCollisionBoundsFor(form, FaceDown)
  let spawn = sim.findPlayerSpawn(bounds)
  sim.players.add Actor(
    id: sim.nextPlayerId,
    address: address,
    x: spawn.x,
    y: spawn.y,
    form: form,
    sprite: sim.playerArts[form].sprites[PlayerFront],
    bounds: bounds,
    facing: FaceDown,
    role: RoleUnarmed,
    maxHp: UnarmedPlayerHp,
    mana: MaxPlayerMana,
    lives: UnarmedPlayerHp,
    personalFrontier: SafeZoneRightPixels
  )
  inc sim.scoreRevision
  sim.players.high

proc initSimServer*(seed = 0xB1770): SimServer =
  result.seed = seed
  result.rng = initRand(seed)
  result.tiles = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  result.terrainKinds = newSeq[TerrainKind](WorldWidthTiles * WorldHeightTiles)
  result.fb = initFramebuffer()
  loadClientPalette()
  let sheet = readAsepriteImage(sheetPath())
  let assetManifest = loadTribalAssetManifest()
  result.playerArts[MalePlayer] = sheet.loadPlayerArt(0)
  result.playerArts[FemalePlayer] = sheet.loadPlayerArt(1)
  result.playerSprite = result.playerArts[MalePlayer].sprites[PlayerFront]
  let
    wolfFallback = sheet.subImage(0, 2 * ArtCellSize, ArtCellSize, ArtCellSize)
    goblinFallback = sheet.subImage(1 * ArtCellSize, 2 * ArtCellSize, ArtCellSize, ArtCellSize)
    bearFallback = sheet.subImage(2 * ArtCellSize, 2 * ArtCellSize, ArtCellSize, ArtCellSize)
    wolfAsset = loadAssetPair(
      assetManifest,
      "mob_wolf",
      "oriented/wolf.e.png",
      wolfFallback
    )
    goblinAsset = loadAssetPair(
      assetManifest,
      "mob_goblin",
      "oriented/goblin.e.png",
      goblinFallback
    )
    bearAsset = loadAssetPair(
      assetManifest,
      "mob_bear",
      "oriented/bear.e.png",
      bearFallback
    )
  result.mobSprite = wolfAsset.sprite
  result.rgbaMobSprite = wolfAsset.rgba
  result.mobBounds = result.rgbaMobSprite.visibleBounds()
  result.trollSprite = goblinAsset.sprite
  result.rgbaTrollSprite = goblinAsset.rgba
  result.trollBounds = result.rgbaTrollSprite.visibleBounds()
  result.bossSprite = bearAsset.sprite
  result.rgbaBossSprite = bearAsset.rgba
  result.bossBounds = result.rgbaBossSprite.visibleBounds()

  for species in AllMobSpecies:
    let
      fallbackImage =
        case species.speciesKind()
        of SnakeMob, WolfMob, ScorpionMob, BatMob:
          wolfFallback
        of TrollMob, GoblinMob, SlimeMob, WraithMob:
          goblinFallback
        of BossMob, BearMob, YetiMob:
          bearFallback
      generatedPath = assetManifest.resolveAssetPath(
        species.speciesAssetKey(),
        species.speciesAssetPath()
      )
      asset = loadAssetPair(
        assetManifest,
        species.speciesAssetKey(),
        species.speciesAssetPath(),
        fallbackImage
      )
    result.mobSpeciesSprites[species] = asset.sprite
    result.mobSpeciesRgbaSprites[species] = asset.rgba
    result.mobSpeciesBounds[species] = asset.rgba.visibleBounds()
    result.mobSpeciesGeneratedSprites[species] =
      generatedPath.startsWith(dataDir())
  let
    fallbackGround = sheet.subImage(0, 3 * ArtCellSize, ArtCellSize, ArtCellSize)
    groundAssets: array[GroundKind, tuple[key, path: string]] = [
      GroundGrass: ("ground_grass", "grass.png"),
      GroundRoad: ("ground_road", "road.png"),
      GroundFertile: ("ground_fertile", "fertile.png"),
      GroundMud: ("ground_mud", "mud.png"),
      GroundShallowWater: ("ground_shallow_water", "shallow_water.png"),
      GroundWater: ("ground_water", "water.png"),
      GroundSand: ("ground_sand", "sand.png"),
      GroundDune: ("ground_dune", "dune.png"),
      GroundSnow: ("ground_snow", "snow.png"),
      GroundCave: ("ground_cave", "cave.png"),
      GroundRuins: ("ground_ruins", "dungeon.png"),
      GroundBridge: ("ground_bridge", "bridge.png")
    ]
  for kind in GroundKind:
    let asset = loadAssetPair(
      assetManifest,
      groundAssets[kind].key,
      groundAssets[kind].path,
      fallbackGround,
      false
    )
    result.groundSprites[kind] = asset.sprite
    result.rgbaGroundSprites[kind] = asset.rgba
  result.terrainSprite = result.groundSprites[GroundGrass]
  result.rgbaTerrainSprite = result.rgbaGroundSprites[GroundGrass]

  let
    terrainFallbacks: array[TerrainKind, Image] = [
      TerrainTree: sheet.subImage(1 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainEvergreen: sheet.subImage(2 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainRock: sheet.subImage(3 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainLog: sheet.subImage(4 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainStump: sheet.subImage(5 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainBush: sheet.subImage(1 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainCactus: sheet.subImage(2 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainWheat: sheet.subImage(1 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainFish: sheet.subImage(3 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainStone: sheet.subImage(3 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainGold: sheet.subImage(3 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainCave: sheet.subImage(3 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainGoblinHut: sheet.subImage(4 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainGoblinTotem: sheet.subImage(5 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainAltar: sheet.subImage(0 * ArtCellSize, 4 * ArtCellSize, ArtCellSize, ArtCellSize),
      TerrainCamp: sheet.subImage(4 * ArtCellSize, 3 * ArtCellSize, ArtCellSize, ArtCellSize)
    ]
    terrainAssets: array[TerrainKind, tuple[key, path: string]] = [
      TerrainTree: ("prop_tree", "tree.png"),
      TerrainEvergreen: ("prop_evergreen", "tree.png"),
      TerrainRock: ("prop_rock", "stone.png"),
      TerrainLog: ("prop_log", "wood.png"),
      TerrainStump: ("prop_stump", "wood.png"),
      TerrainBush: ("prop_bush", "bush.png"),
      TerrainCactus: ("prop_cactus", "cactus.png"),
      TerrainWheat: ("prop_wheat", "wheat.png"),
      TerrainFish: ("prop_fish", "fish.png"),
      TerrainStone: ("prop_stone", "stone.png"),
      TerrainGold: ("prop_gold", "gold.png"),
      TerrainCave: ("prop_cave", "cave.png"),
      TerrainGoblinHut: ("prop_goblin_hut", "goblin_hut.png"),
      TerrainGoblinTotem: ("prop_goblin_totem", "goblin_totem.png"),
      TerrainAltar: ("prop_altar", "altar.png"),
      TerrainCamp: ("prop_camp", "lumber_camp.png")
    ]
  for kind in TerrainKind:
    let asset = loadAssetPair(
      assetManifest,
      terrainAssets[kind].key,
      terrainAssets[kind].path,
      terrainFallbacks[kind]
    )
    result.terrainSprites[kind] = asset.sprite
    result.rgbaTerrainSprites[kind] = asset.rgba
    result.terrainBounds[kind] =
      result.rgbaTerrainSprites[kind].terrainCollisionBounds(kind)

  let
    landmarkFallback = sheet.subImage(0, 4 * ArtCellSize, ArtCellSize, ArtCellSize)
    landmarkAssets: array[LandmarkKind, tuple[key, path: string]] = [
      LandmarkWood: ("landmark_wood", "wood.png"),
      LandmarkFood: ("landmark_food", "bushel.png"),
      LandmarkStone: ("landmark_stone", "stone.png"),
      LandmarkGold: ("landmark_gold", "gold.png"),
      LandmarkCamp: ("landmark_camp", "lumber_camp.png"),
      LandmarkBeacon: ("landmark_beacon", "control_point.png"),
      LandmarkFinalGate: ("landmark_final_gate", "altar.png"),
      LandmarkShrine: ("landmark_shrine", "altar.png"),
      LandmarkRescue: ("landmark_rescue", "oriented/gatherer.e.png"),
      LandmarkLair: ("landmark_lair", "goblin_hive.png"),
      LandmarkWaystation: ("landmark_waystation", "control_point.png")
    ]
  for kind in LandmarkKind:
    let asset = loadAssetPair(
      assetManifest,
      landmarkAssets[kind].key,
      landmarkAssets[kind].path,
      landmarkFallback
    )
    result.landmarkSprites[kind] = asset.sprite
    result.rgbaLandmarkSprites[kind] = asset.rgba
    result.landmarkBounds[kind] = result.rgbaLandmarkSprites[kind].visibleBounds()

  for gear in [
    (kind: PickupTankGear, key: "role_tank_guild", path: "guard_tower.png", fallbackX: 3, fallbackY: 3),
    (kind: PickupDpsGear, key: "role_dps_guild", path: "blacksmith.png", fallbackX: 4, fallbackY: 3),
    (kind: PickupHealerGear, key: "role_healer_guild", path: "monastery.png", fallbackX: 0, fallbackY: 4)
  ]:
    let asset = loadAssetPair(
      assetManifest,
      gear.key,
      gear.path,
      sheet.subImage(
        gear.fallbackX * ArtCellSize,
        gear.fallbackY * ArtCellSize,
        ArtCellSize,
        ArtCellSize
      )
    )
    result.roleGearSprites[gear.kind] = asset.sprite
    result.roleGearRgbaSprites[gear.kind] = asset.rgba
    result.roleGearBounds[gear.kind] = result.roleGearRgbaSprites[gear.kind].visibleBounds()

  for armor in [
    (kind: ArmorScoutHood, key: "armor_scout_hood", path: "oriented/scout.e.png", fallbackX: 0, fallbackY: 0),
    (kind: ArmorIronHelm, key: "armor_iron_helm", path: "shield.png", fallbackX: 3, fallbackY: 4),
    (kind: ArmorFurHood, key: "armor_fur_hood", path: "oriented/scout.n.png", fallbackX: 0, fallbackY: 0),
    (kind: ArmorLeatherVest, key: "armor_leather_vest", path: "blacksmith.png", fallbackX: 4, fallbackY: 3),
    (kind: ArmorScaleMail, key: "armor_scale_mail", path: "guard_tower.png", fallbackX: 3, fallbackY: 3),
    (kind: ArmorFrostCloak, key: "armor_frost_cloak", path: "monastery.png", fallbackX: 0, fallbackY: 4),
    (kind: ArmorVenomCharm, key: "armor_venom_charm", path: "goblet.png", fallbackX: 0, fallbackY: 4),
    (kind: ArmorLanternCharm, key: "armor_lantern_charm", path: "lantern.png", fallbackX: 0, fallbackY: 4),
    (kind: ArmorRallyHorn, key: "armor_rally_horn", path: "control_point.png", fallbackX: 0, fallbackY: 4)
  ]:
    let asset = loadAssetPair(
      assetManifest,
      armor.key,
      armor.path,
      sheet.subImage(
        armor.fallbackX * ArtCellSize,
        armor.fallbackY * ArtCellSize,
        ArtCellSize,
        ArtCellSize
      )
    )
    result.armorSprites[armor.kind] = asset.sprite
    result.armorRgbaSprites[armor.kind] = asset.rgba
    result.armorBounds[armor.kind] =
      result.armorRgbaSprites[armor.kind].visibleBounds()
  result.armorSprites[ArmorNone] = result.armorSprites[ArmorScoutHood]
  result.armorRgbaSprites[ArmorNone] = result.armorRgbaSprites[ArmorScoutHood]
  result.armorBounds[ArmorNone] = result.armorBounds[ArmorScoutHood]

  let coinAsset = loadAssetPair(
    assetManifest,
    "pickup_coin",
    "goblet.png",
    sheet.subImage(0, 4 * ArtCellSize, ArtCellSize, ArtCellSize)
  )
  result.coinSprite = coinAsset.sprite
  result.rgbaCoinSprite = coinAsset.rgba
  result.coinBounds = result.rgbaCoinSprite.visibleBounds()
  let heartAsset = loadAssetPair(
    assetManifest,
    "pickup_heart",
    "heart.png",
    sheet.subImage(1 * ArtCellSize, 4 * ArtCellSize, ArtCellSize, ArtCellSize)
  )
  result.heartSprite = heartAsset.sprite
  result.rgbaHeartSprite = heartAsset.rgba
  result.heartBounds = result.rgbaHeartSprite.visibleBounds()
  result.textFont = loadTiny5Font()

  result.seedBiomeGrounds()
  result.seedBrush()
  result.seedDenseBiomeTerrain()
  result.clearProgressLane()
  let startTx = 2
  let startTy = WorldHeightTiles div 2
  result.clearSpawnArea(startTx, startTy, 5)
  result.seedLandmarks()
  result.seedTerrainProps()

  result.players = @[]
  result.teamFrontier = SafeZoneRightPixels
  result.maxBiomeReached = BiomeOrigin.biomeProgressValue()
  result.seedRoleGear()
  result.seedBiomeMobs()
  result.mobSpawnCooldown = 30

proc playerScoresJson*(sim: SimServer): string =
  ## Builds the current per-player score JSON.
  var
    names = newJArray()
    scores = newJArray()
    hearts = newJArray()
    mana = newJArray()
    distanceWalked = newJArray()
    frontierTiles = newJArray()
    personalFrontierTiles = newJArray()
    roles = newJArray()
    damageDone = newJArray()
    healingDone = newJArray()
    damageBlocked = newJArray()
    messagesSent = newJArray()
    carriedItems = newJArray()
    statusEffects = newJArray()
    downedTicks = newJArray()
    triumphTicks = newJArray()
    rationTicks = newJArray()
    moraleTicks = newJArray()
    biomesReached = newJArray()
    objectivesCompleted = newJArray()
    sideObjectivesCompleted = newJArray()
    masteryCount = newJArray()
    masteredBiomes = newJArray()
    relicShards = newJArray()
    campsActivated = newJArray()
    resourcesCollected = newJArray()
    bossDefeated = newJArray()
    finalGateCompleted = newJArray()
    partyWood = newJArray()
    partyFood = newJArray()
    partyStone = newJArray()
    results = newJObject()
  let
    frontierScore = sim.frontierTiles()
    teamScore = sim.teamScore()
  for player in sim.players:
    names.add(%player.address)
    scores.add(%teamScore)
    hearts.add(%player.lives)
    mana.add(%player.mana)
    distanceWalked.add(%player.distanceWalked)
    frontierTiles.add(%frontierScore)
    personalFrontierTiles.add(%frontierTilesForX(player.personalFrontier))
    roles.add(%player.role.roleLabel())
    damageDone.add(%player.damageDone)
    healingDone.add(%player.healingDone)
    damageBlocked.add(%player.damageBlocked)
    messagesSent.add(%player.messagesSent)
    carriedItems.add(%player.carryInventoryLabel())
    statusEffects.add(%player.statusLabel())
    downedTicks.add(%player.downedTicks)
    triumphTicks.add(%player.triumphTicks)
    rationTicks.add(%player.rationTicks)
    moraleTicks.add(%player.moraleTicks)
    biomesReached.add(%sim.maxBiomeReached)
    objectivesCompleted.add(%sim.objectivesCompleted)
    sideObjectivesCompleted.add(%sim.sideObjectivesCompleted)
    masteryCount.add(%sim.masteredBiomeCount())
    masteredBiomes.add(%sim.masteredBiomeLabels())
    relicShards.add(%sim.relicShards)
    campsActivated.add(%sim.campsActivated)
    resourcesCollected.add(%sim.resourcesCollected)
    bossDefeated.add(%sim.bossDefeated)
    finalGateCompleted.add(%sim.finalGateCompleted())
    partyWood.add(%sim.wood)
    partyFood.add(%sim.food)
    partyStone.add(%sim.stone)
  results["names"] = names
  results["scores"] = scores
  results["hearts"] = hearts
  results["mana"] = mana
  results["distance_walked"] = distanceWalked
  results["frontier_tiles"] = frontierTiles
  results["personal_frontier_tiles"] = personalFrontierTiles
  results["roles"] = roles
  results["damage_done"] = damageDone
  results["healing_done"] = healingDone
  results["damage_blocked"] = damageBlocked
  results["messages_sent"] = messagesSent
  results["carried_items"] = carriedItems
  results["status_effects"] = statusEffects
  results["downed_ticks"] = downedTicks
  results["triumph_ticks"] = triumphTicks
  results["ration_ticks"] = rationTicks
  results["morale_ticks"] = moraleTicks
  results["team_score"] = scores
  results["biomes_reached"] = biomesReached
  results["objectives_completed"] = objectivesCompleted
  results["side_objectives_completed"] = sideObjectivesCompleted
  results["mastery_count"] = masteryCount
  results["mastered_biomes"] = masteredBiomes
  results["relic_shards"] = relicShards
  results["camps_activated"] = campsActivated
  results["resources_collected"] = resourcesCollected
  results["boss_defeated"] = bossDefeated
  results["final_gate_completed"] = finalGateCompleted
  results["party_wood"] = partyWood
  results["party_food"] = partyFood
  results["party_stone"] = partyStone
  $results

proc mixHash(hash: var uint64, value: uint64) =
  ## Mixes one integer into a deterministic FNV-1a hash.
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashInt(hash: var uint64, value: int) =
  ## Mixes one signed integer into a deterministic hash.
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashString(hash: var uint64, value: string) =
  ## Mixes one ASCII string into a deterministic hash.
  hash.mixHashInt(value.len)
  for ch in value:
    hash.mixHashInt(ord(ch))

proc gameHash*(sim: SimServer): uint64 =
  ## Returns a deterministic hash of gameplay state.
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(sim.mobSpawnCooldown)
  result.mixHashInt(sim.nextPlayerId)
  result.mixHashInt(sim.teamFrontier)
  result.mixHashInt(sim.maxBiomeReached)
  result.mixHashInt(sim.objectivesCompleted)
  result.mixHashInt(sim.sideObjectivesCompleted)
  result.mixHashInt(sim.campsActivated)
  for biome in BiomeKind:
    result.mixHashInt(ord(sim.biomeMastered[biome]))
  result.mixHashInt(sim.resourcesCollected)
  result.mixHashInt(sim.wood)
  result.mixHashInt(sim.food)
  result.mixHashInt(sim.stone)
  result.mixHashInt(sim.relicShards)
  result.mixHashInt(ord(sim.bossDefeated))
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashInt(player.id)
    result.mixHashInt(player.x)
    result.mixHashInt(player.y)
    result.mixHashInt(ord(player.facing))
    result.mixHashInt(player.attackTicks)
    result.mixHashInt(ord(player.attackResolved))
    result.mixHashInt(ord(player.pingKind))
    result.mixHashInt(player.pingTicks)
    result.mixHashInt(player.velX)
    result.mixHashInt(player.velY)
    result.mixHashInt(player.carryX)
    result.mixHashInt(player.carryY)
    result.mixHashInt(ord(player.role))
    result.mixHashInt(player.maxHp)
    result.mixHashInt(player.mana)
    result.mixHashInt(player.abilityCooldown)
    result.mixHashInt(player.abilityTicks)
    result.mixHashInt(player.abilityHoldTicks)
    result.mixHashInt(player.guardTicks)
    result.mixHashInt(player.personalFrontier)
    result.mixHashInt(player.damageDone)
    result.mixHashInt(player.healingDone)
    result.mixHashInt(player.damageBlocked)
    result.mixHashInt(player.messagesSent)
    result.mixHashString(player.message)
    result.mixHashInt(player.lives)
    result.mixHashInt(player.invulnTicks)
    result.mixHashInt(player.coins)
    result.mixHashInt(ord(player.carrying))
    result.mixHashInt(ord(player.carriedItem))
    for item in CarryInventoryKinds:
      result.mixHashInt(player.carryCount(item))
    for slot in ArmorSlot:
      result.mixHashInt(ord(player.armor[slot]))
    result.mixHashInt(player.carrySelectLockTicks)
    result.mixHashInt(player.slowTicks)
    result.mixHashInt(player.chillTicks)
    result.mixHashInt(player.poisonTicks)
    result.mixHashInt(player.exhaustionTicks)
    result.mixHashInt(player.routeTicks)
    result.mixHashInt(player.surveyTicks)
    result.mixHashInt(player.guideTicks)
    result.mixHashInt(player.huntTicks)
    result.mixHashInt(player.triumphTicks)
    result.mixHashInt(player.rationTicks)
    result.mixHashInt(player.moraleTicks)
    result.mixHashInt(player.downedTicks)
    result.mixHashInt(player.rescueTicks)
  result.mixHashInt(sim.mobs.len)
  for mob in sim.mobs:
    result.mixHashInt(ord(mob.kind))
    result.mixHashInt(ord(mob.species))
    result.mixHashInt(mob.x)
    result.mixHashInt(mob.y)
    result.mixHashInt(mob.wanderCooldown)
    result.mixHashInt(mob.hp)
    result.mixHashInt(mob.attackCooldown)
    result.mixHashInt(ord(mob.attackPhase))
    result.mixHashInt(mob.attackTicks)
    result.mixHashInt(mob.staggerTicks)
    result.mixHashInt(ord(mob.attackFacing))
    result.mixHashInt(mob.attackerIds.len)
    for attackerId in mob.attackerIds:
      result.mixHashInt(attackerId)
    result.mixHashInt(mob.attackerTicks.len)
    for attackerTick in mob.attackerTicks:
      result.mixHashInt(attackerTick)
  result.mixHashInt(sim.pickups.len)
  for pickup in sim.pickups:
    result.mixHashInt(pickup.x)
    result.mixHashInt(pickup.y)
    result.mixHashInt(ord(pickup.kind))
    result.mixHashInt(pickup.value)
  result.mixHashInt(sim.guides.len)
  for guide in sim.guides:
    result.mixHashInt(guide.x)
    result.mixHashInt(guide.y)
    result.mixHashInt(guide.targetPlayerId)
    result.mixHashInt(guide.thanksTicks)
    result.mixHashInt(ord(guide.done))
  result.mixHashInt(sim.landmarks.len)
  for landmark in sim.landmarks:
    result.mixHashInt(landmark.tx)
    result.mixHashInt(landmark.ty)
    result.mixHashInt(ord(landmark.kind))
    result.mixHashInt(landmark.hp)
    result.mixHashInt(ord(landmark.done))
    result.mixHashInt(landmark.progress)
  result.mixHashInt(sim.riverCrossings.len)
  for crossing in sim.riverCrossings:
    result.mixHashInt(crossing.tx)
    result.mixHashInt(crossing.ty)
    result.mixHashInt(crossing.firstTy)
    result.mixHashInt(crossing.lastTy)
    result.mixHashInt(ord(crossing.triggered))
  for tile in sim.tiles:
    result.mixHashInt(ord(tile))
  for ground in sim.groundKinds:
    result.mixHashInt(ord(ground))
  for elevation in sim.elevations:
    result.mixHashInt(elevation)

proc moveActor(sim: SimServer, actor: var Actor, dx, dy: int) =
  if dx != 0:
    let stepX = (if dx < 0: -1 else: 1)
    for _ in 0 ..< abs(dx):
      let nx = actor.x + stepX
      if sim.canOccupy(nx, actor.y, actor.bounds):
        actor.x = nx
      else:
        break

  if dy != 0:
    let stepY = (if dy < 0: -1 else: 1)
    for _ in 0 ..< abs(dy):
      let ny = actor.y + stepY
      if sim.canOccupy(actor.x, ny, actor.bounds):
        actor.y = ny
      else:
        break

proc moveMob(sim: SimServer, mob: var Mob, dx, dy: int) =
  ## Moves one mob through terrain by a small amount.
  var actor = Actor(
    x: mob.x,
    y: mob.y,
    sprite: mob.sprite,
    bounds: mob.bounds
  )
  sim.moveActor(actor, dx, dy)
  mob.x = max(actor.x, SafeZoneRightPixels)
  mob.y = actor.y

proc applyMomentumAxis(
  sim: SimServer,
  actor: var Actor,
  carry: var int,
  velocity: int,
  horizontal: bool
) =
  carry += velocity
  while abs(carry) >= MotionScale:
    let step = (if carry < 0: -1 else: 1)
    if horizontal:
      if sim.canOccupy(actor.x + step, actor.y, actor.bounds):
        actor.x += step
        carry -= step * MotionScale
      else:
        carry = 0
        break
    else:
      if sim.canOccupy(actor.x, actor.y + step, actor.bounds):
        actor.y += step
        carry -= step * MotionScale
      else:
        carry = 0
        break

proc playerFootRect(player: Actor): tuple[x, y, w, h: int] =
  ## Returns one player's world-space foot collision rectangle.
  (
    x: player.x + player.bounds.x,
    y: player.y + player.bounds.y,
    w: player.bounds.w,
    h: player.bounds.h
  )

proc overlapLength(a, aSize, b, bSize: int): int =
  ## Returns the positive overlap length for two one dimensional spans.
  min(a + aSize, b + bSize) - max(a, b)

proc playersFootOverlap(sim: SimServer, a, b: int): bool =
  ## Returns true when two live players overlap by their foot boxes.
  if a < 0 or b < 0 or a >= sim.players.len or b >= sim.players.len:
    return false
  if sim.players[a].lives <= 0 or sim.players[b].lives <= 0:
    return false
  let
    pa = sim.players[a].playerFootRect()
    pb = sim.players[b].playerFootRect()
  rectsOverlap(pa.x, pa.y, pa.w, pa.h, pb.x, pb.y, pb.w, pb.h)

proc movePlayerByTerrain(
  sim: var SimServer,
  playerIndex,
  dx,
  dy: int
): int =
  ## Moves one live player by terrain-valid pixels.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].lives <= 0:
    return

  if dx != 0:
    let stepX = if dx < 0: -1 else: 1
    for _ in 0 ..< abs(dx):
      let nx = sim.players[playerIndex].x + stepX
      if sim.canOccupy(
        nx,
        sim.players[playerIndex].y,
        sim.players[playerIndex].bounds
      ):
        sim.players[playerIndex].x = nx
        inc result
      else:
        break
    if result > 0:
      sim.players[playerIndex].velX = 0
      sim.players[playerIndex].carryX = 0

  if dy != 0:
    let
      previousMoves = result
      stepY = if dy < 0: -1 else: 1
    for _ in 0 ..< abs(dy):
      let ny = sim.players[playerIndex].y + stepY
      if sim.canOccupy(
        sim.players[playerIndex].x,
        ny,
        sim.players[playerIndex].bounds
      ):
        sim.players[playerIndex].y = ny
        inc result
      else:
        break
    if result > previousMoves:
      sim.players[playerIndex].velY = 0
      sim.players[playerIndex].carryY = 0

proc pushPlayerPair(
  sim: var SimServer,
  a,
  b,
  dirX,
  dirY,
  overlap: int
): bool =
  ## Pushes a player pair apart along one axis.
  let
    total = overlap + 1
    first = max(1, total div 2)
    second = max(1, total - first)
  discard sim.movePlayerByTerrain(a, dirX * first, dirY * first)
  discard sim.movePlayerByTerrain(b, -dirX * second, -dirY * second)
  if not sim.playersFootOverlap(a, b):
    return true

  discard sim.movePlayerByTerrain(a, dirX * total, dirY * total)
  if not sim.playersFootOverlap(a, b):
    return true
  discard sim.movePlayerByTerrain(b, -dirX * total, -dirY * total)
  not sim.playersFootOverlap(a, b)

proc separatePlayerPair(sim: var SimServer, a, b: int): bool =
  ## Moves two overlapping players out of each other's foot boxes.
  if not sim.playersFootOverlap(a, b):
    return false
  let
    pa = sim.players[a].playerFootRect()
    pb = sim.players[b].playerFootRect()
    overlapX = overlapLength(pa.x, pa.w, pb.x, pb.w)
    overlapY = overlapLength(pa.y, pa.h, pb.y, pb.h)
    centerAX = pa.x + pa.w div 2
    centerAY = pa.y + pa.h div 2
    centerBX = pb.x + pb.w div 2
    centerBY = pb.y + pb.h div 2
    dirX =
      if centerAX < centerBX or (centerAX == centerBX and a < b):
        -1
      else:
        1
    dirY =
      if centerAY < centerBY or (centerAY == centerBY and a < b):
        -1
      else:
        1

  if overlapX <= overlapY:
    if sim.pushPlayerPair(a, b, dirX, 0, overlapX):
      return true
    return sim.pushPlayerPair(a, b, 0, dirY, overlapY)

  if sim.pushPlayerPair(a, b, 0, dirY, overlapY):
    return true
  sim.pushPlayerPair(a, b, dirX, 0, overlapX)

proc resolvePlayerOverlaps*(sim: var SimServer) =
  ## Pushes live players apart by their 8 by 8 foot boxes.
  for _ in 0 ..< PlayerSeparationPasses:
    var moved = false
    for a in 0 ..< sim.players.len:
      if sim.players[a].lives <= 0:
        continue
      for b in (a + 1) ..< sim.players.len:
        if sim.players[b].lives <= 0:
          continue
        if sim.separatePlayerPair(a, b):
          moved = true
    if not moved:
      break

proc applyHealerPulse(sim: var SimServer, healerIndex: int) =
  let healer = sim.players[healerIndex]
  let radiusSq = HealerPulseRadius * HealerPulseRadius
  for targetIndex in 0 ..< sim.players.len:
    if sim.players[targetIndex].lives <= 0:
      continue
    if distanceSquaredActor(healer, sim.players[targetIndex]) > radiusSq:
      continue
    let before = sim.players[targetIndex].lives
    sim.players[targetIndex].lives = min(
      sim.players[targetIndex].maxHp,
      sim.players[targetIndex].lives + HealerPulseAmount
    )
    let healed = sim.players[targetIndex].lives - before
    let cleansed =
      sim.players[targetIndex].poisonTicks > 0 or
      sim.players[targetIndex].slowTicks > 0 or
      sim.players[targetIndex].chillTicks > 0 or
      sim.players[targetIndex].exhaustionTicks > 0
    if cleansed:
      sim.players[targetIndex].poisonTicks = 0
      sim.players[targetIndex].slowTicks = 0
      sim.players[targetIndex].chillTicks = 0
      sim.players[targetIndex].exhaustionTicks = 0
    if healed > 0:
      sim.players[healerIndex].healingDone += healed
    if healed > 0 or cleansed:
      inc sim.scoreRevision

proc dropMonsterSupply(sim: var SimServer, mob: Mob) =
  ## Drops a carried expedition supply from species that naturally support one.
  let supply = mob.species.speciesSupplyDrop()
  if supply == CarryNone:
    return
  let
    pickupKind = supply.pickupForCarry()
    sprite = sim.pickupSprite(pickupKind)
  sim.pickups.add(Pickup(
    x: mob.x + mob.sprite.width div 2 - sprite.width div 2 + 6,
    y: mob.y + mob.sprite.height div 2 - sprite.height div 2 + 4,
    kind: pickupKind,
    value: 1
  ))
  inc sim.scoreRevision

proc dropMonsterArmor(sim: var SimServer, mob: Mob) =
  ## Drops role-neutral equipment from tactical monster families.
  let armor = mob.species.speciesArmorDrop()
  if armor == ArmorNone:
    return
  let sprite = sim.armorSprites[armor]
  sim.pickups.add(Pickup(
    x: mob.x + mob.sprite.width div 2 - sprite.width div 2 - 6,
    y: mob.y + mob.sprite.height div 2 - sprite.height div 2 - 4,
    kind: PickupArmor,
    value: ord(armor)
  ))
  inc sim.scoreRevision

proc finishDefeatedMobs(sim: var SimServer) =
  var survivors: seq[Mob] = @[]
  for mob in sim.mobs:
    if mob.hp > 0:
      survivors.add(mob)
    else:
      case mob.kind
      of BossMob:
        sim.bossDefeated = true
        inc sim.scoreRevision
        let sprite = sim.pickupSprite(PickupCoin)
        sim.pickups.add(Pickup(
          x: mob.x + mob.sprite.width div 2 - sprite.width div 2,
          y: mob.y + mob.sprite.height div 2 - sprite.height div 2,
          kind: PickupCoin,
          value: BossCoinValue
        ))
        sim.dropMonsterSupply(mob)
        sim.dropMonsterArmor(mob)
      of TrollMob, GoblinMob, BearMob, ScorpionMob, SlimeMob, YetiMob,
          WraithMob:
        let sprite = sim.pickupSprite(PickupCoin)
        sim.pickups.add(Pickup(
          x: mob.x + mob.sprite.width div 2 - sprite.width div 2,
          y: mob.y + mob.sprite.height div 2 - sprite.height div 2,
          kind: PickupCoin,
          value:
            if mob.kind in {BearMob, YetiMob, WraithMob}:
              TrollCoinValue * 2
            else:
              TrollCoinValue
        ))
        sim.dropMonsterSupply(mob)
        sim.dropMonsterArmor(mob)
      of SnakeMob, WolfMob, BatMob:
        let roll = sim.rng.rand(99)
        if roll < 10:
          sim.pickups.add(Pickup(x: mob.x, y: mob.y, kind: PickupHeart, value: 1))
        elif roll < 60:
          sim.pickups.add(Pickup(x: mob.x, y: mob.y, kind: PickupCoin, value: 1))
        sim.dropMonsterSupply(mob)
        sim.dropMonsterArmor(mob)
  sim.mobs = survivors

proc bossRaidDamageBonus*(sim: SimServer, playerIndex: int, mob: Mob): int

proc dpsBeamRect*(player: Actor): tuple[x, y, w, h: int] =
  let
    centerX = boundsCenterX(player.x, player.bounds)
    centerY = boundsCenterY(player.y, player.bounds)
    length = DpsBeamTiles * WorldTileSize
    halfWidth = DpsBeamWidth div 2
  case player.facing
  of FaceLeft:
    (x: centerX - length, y: centerY - halfWidth, w: length, h: DpsBeamWidth)
  of FaceRight:
    (x: centerX, y: centerY - halfWidth, w: length, h: DpsBeamWidth)
  of FaceUp:
    (x: centerX - halfWidth, y: centerY - length, w: DpsBeamWidth, h: length)
  of FaceDown:
    (x: centerX - halfWidth, y: centerY, w: DpsBeamWidth, h: length)

proc applyDpsBeam(sim: var SimServer, playerIndex: int) =
  let player = sim.players[playerIndex]
  let beam = player.dpsBeamRect()
  var hitAny = false
  for mobIndex in 0 ..< sim.mobs.len:
    if not rectOverlapsBounds(
      beam.x,
      beam.y,
      beam.w,
      beam.h,
      sim.mobs[mobIndex].x,
      sim.mobs[mobIndex].y,
      sim.mobs[mobIndex].bounds
    ):
      continue
    sim.mobs[mobIndex].pruneMobAttackers(sim.players, sim.tickCount)
    sim.mobs[mobIndex].rememberMobAttacker(player.id, sim.tickCount)
    let
      mobTx = clamp(
        boundsCenterX(sim.mobs[mobIndex].x, sim.mobs[mobIndex].bounds) div WorldTileSize,
        0,
        WorldWidthTiles - 1
      )
      mobTy = clamp(
        boundsCenterY(sim.mobs[mobIndex].y, sim.mobs[mobIndex].bounds) div WorldTileSize,
        0,
        WorldHeightTiles - 1
      )
      mobBiome = sim.tileBiomeKind(mobTx, mobTy)
    let damage = max(
      1,
      DpsBeamDamage +
        sim.bossRaidDamageBonus(playerIndex, sim.mobs[mobIndex]) +
        elevationDamageModifier(
          sim.actorTileElevation(player),
          sim.mobTileElevation(sim.mobs[mobIndex])
        ) +
        (if mobBiome != BiomeOrigin and sim.biomeMastered[mobBiome]:
          BiomeMasteryDamageBonus
        else:
          0)
    )
    sim.mobs[mobIndex].hp -= damage
    sim.players[playerIndex].damageDone += damage
    hitAny = true
    inc sim.scoreRevision
  if hitAny:
    sim.players[playerIndex].attackTicks =
      max(sim.players[playerIndex].attackTicks, 5)
    sim.players[playerIndex].attackResolved = true
    sim.finishDefeatedMobs()

proc spendRoleAbilityMana(player: var Actor): bool =
  ## Spends mana for the current role's special action if enough is available.
  let cost = player.role.roleAbilityManaCost()
  if cost <= 0:
    return true
  if player.mana < cost:
    player.abilityHoldTicks = 0
    return false
  player.mana -= cost
  true

proc completeHealerPulse(sim: var SimServer, playerIndex: int) =
  if not sim.players[playerIndex].spendRoleAbilityMana():
    return
  inc sim.scoreRevision
  sim.players[playerIndex].abilityTicks = RoleAbilityEffectTicks
  sim.applyHealerPulse(playerIndex)
  sim.players[playerIndex].abilityCooldown = RoleAbilityCooldown
  sim.players[playerIndex].abilityHoldTicks = 0

proc advanceHealerPulseHold(sim: var SimServer, playerIndex: int) =
  if sim.players[playerIndex].abilityCooldown > 0:
    sim.players[playerIndex].abilityHoldTicks = 0
    return
  inc sim.players[playerIndex].abilityHoldTicks
  if sim.players[playerIndex].abilityHoldTicks >= HealerPulseHoldTicks:
    sim.completeHealerPulse(playerIndex)

proc applyRoleAbility(sim: var SimServer, playerIndex: int) =
  if sim.players[playerIndex].abilityCooldown > 0:
    return
  case sim.players[playerIndex].role
  of RoleTank:
    if not sim.players[playerIndex].spendRoleAbilityMana():
      return
    inc sim.scoreRevision
    sim.players[playerIndex].abilityHoldTicks = 0
    sim.players[playerIndex].guardTicks = TankGuardTicks
    sim.players[playerIndex].abilityTicks = RoleAbilityEffectTicks
    sim.players[playerIndex].abilityCooldown = RoleAbilityCooldown
  of RoleDps:
    if not sim.players[playerIndex].spendRoleAbilityMana():
      return
    inc sim.scoreRevision
    sim.players[playerIndex].abilityHoldTicks = 0
    sim.players[playerIndex].abilityTicks = RoleAbilityEffectTicks
    sim.applyDpsBeam(playerIndex)
    sim.players[playerIndex].abilityCooldown = RoleAbilityCooldown
  of RoleHealer:
    sim.advanceHealerPulseHold(playerIndex)
  else:
    discard

proc consumeCarryItem(
  sim: var SimServer,
  playerIndex: int,
  item: CarryKind
): bool
proc dropCarry(sim: var SimServer, playerIndex: int): bool
proc deliverCarryToCamp(sim: var SimServer, playerIndex: int): bool
proc useCarryInField(sim: var SimServer, playerIndex: int): bool
proc applyCarriedFood(
  sim: var SimServer,
  carrierIndex,
  targetIndex: int
): bool

proc carriedFoodWouldHelp*(player: Actor): bool =
  player.lives > 0 and (
    player.lives < player.maxHp or
    player.poisonTicks > 0 or
    player.slowTicks > 0 or
    player.chillTicks > 0 or
    player.exhaustionTicks > 0
  )

proc consumeCarriedFood(sim: var SimServer, playerIndex: int): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if not sim.players[playerIndex].hasCarry(CarryFood):
    return false
  sim.applyCarriedFood(playerIndex, playerIndex)

proc carriedFoodNeedScore(player: Actor): int =
  if not player.carriedFoodWouldHelp():
    return -1
  result = max(0, player.maxHp - player.lives) * 10
  if player.poisonTicks > 0:
    result += 12
  if player.slowTicks > 0:
    result += 8
  if player.chillTicks > 0:
    result += 8
  if player.exhaustionTicks > 0:
    result += 6

proc nearbyCarriedFoodRecipient(
  sim: SimServer,
  playerIndex: int
): int =
  result = -1
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]
  if player.lives <= 0 or not player.hasCarry(CarryFood):
    return
  let radiusSq = CarriedFoodShareRadius * CarriedFoodShareRadius
  var
    bestScore = -1
    bestDistance = high(int)
  for otherIndex in 0 ..< sim.players.len:
    if otherIndex == playerIndex:
      continue
    let other = sim.players[otherIndex]
    if other.lives <= 0:
      continue
    let distance = distanceSquaredActor(player, other)
    if distance > radiusSq:
      continue
    let score = other.carriedFoodNeedScore()
    if score < 0:
      continue
    if score > bestScore or (score == bestScore and distance < bestDistance):
      result = otherIndex
      bestScore = score
      bestDistance = distance

proc playerCanFeedCarriedFood*(
  sim: SimServer,
  playerIndex: int
): bool =
  sim.nearbyCarriedFoodRecipient(playerIndex) >= 0

proc feedCarriedFood(sim: var SimServer, playerIndex: int): bool =
  let recipient = sim.nearbyCarriedFoodRecipient(playerIndex)
  if recipient < 0:
    return false
  sim.applyCarriedFood(playerIndex, recipient)

proc applyCarriedFood(
  sim: var SimServer,
  carrierIndex,
  targetIndex: int
): bool =
  if carrierIndex < 0 or carrierIndex >= sim.players.len or
      targetIndex < 0 or targetIndex >= sim.players.len:
    return false
  if not sim.players[carrierIndex].hasCarry(CarryFood):
    return false
  if not sim.players[targetIndex].carriedFoodWouldHelp():
    return false
  let before = sim.players[targetIndex].lives
  if sim.players[targetIndex].lives < sim.players[targetIndex].maxHp:
    sim.players[targetIndex].lives = min(
      sim.players[targetIndex].maxHp,
      sim.players[targetIndex].lives + FoodHealAmount
    )
  sim.players[targetIndex].poisonTicks = 0
  sim.players[targetIndex].slowTicks = 0
  sim.players[targetIndex].chillTicks = 0
  sim.players[targetIndex].exhaustionTicks = 0
  sim.players[carrierIndex].healingDone +=
    sim.players[targetIndex].lives - before
  discard sim.consumeCarryItem(carrierIndex, CarryFood)
  true

proc applyInput*(sim: var SimServer, playerIndex: int, input: InputState) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  template player: untyped = sim.players[playerIndex]

  if player.lives <= 0:
    player.velX = 0
    player.velY = 0
    player.abilityHoldTicks = 0
    return

  var inputX = 0
  var inputY = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1
  if input.up:
    inputY -= 1
  if input.down:
    inputY += 1

  if inputX != 0:
    player.velX = clamp(player.velX + inputX * Accel, -MaxSpeed, MaxSpeed)
  else:
    player.velX = (player.velX * FrictionNum) div FrictionDen
    if abs(player.velX) < StopThreshold:
      player.velX = 0

  if inputY != 0:
    player.velY = clamp(player.velY + inputY * Accel, -MaxSpeed, MaxSpeed)
  else:
    player.velY = (player.velY * FrictionNum) div FrictionDen
    if abs(player.velY) < StopThreshold:
      player.velY = 0

  if abs(player.velX) > abs(player.velY):
    if player.velX < 0:
      player.facing = FaceLeft
    elif player.velX > 0:
      player.facing = FaceRight
  else:
    if player.velY < 0:
      player.facing = FaceUp
    elif player.velY > 0:
      player.facing = FaceDown

  if inputX < 0:
    player.facing = FaceLeft
  elif inputX > 0:
    player.facing = FaceRight
  elif inputY < 0:
    player.facing = FaceUp
  elif inputY > 0:
    player.facing = FaceDown
  player.bounds = sim.playerBoundsFor(player)

  let
    footX = boundsCenterX(player.x, player.bounds)
    footY = boundsCenterY(player.y, player.bounds)
    speedPct = sim.playerMovementSpeedPercent(player, footX, footY)
  sim.applyMomentumAxis(
    player,
    player.carryX,
    (player.velX * speedPct) div 100,
    true
  )
  sim.applyMomentumAxis(
    player,
    player.carryY,
    (player.velY * speedPct) div 100,
    false
  )
  if input.attack and player.attackTicks == 0:
    player.attackTicks = 5
    player.attackResolved = false
  if input.b:
    if player.role == RoleHealer:
      sim.advanceHealerPulseHold(playerIndex)
    else:
      sim.applyRoleAbility(playerIndex)
  elif player.abilityHoldTicks > 0:
    player.abilityHoldTicks = 0
  if input.select:
    let usedCarryAction =
      sim.consumeCarriedFood(playerIndex) or
        sim.feedCarriedFood(playerIndex) or
        sim.deliverCarryToCamp(playerIndex) or
        sim.useCarryInField(playerIndex) or
        sim.dropCarry(playerIndex)
    if usedCarryAction:
      player.carrySelectLockTicks = 1

proc attackRect*(sim: SimServer, player: Actor): tuple[x, y, w, h: int] =
  let sprite = sim.playerSwooshFor(player)
  let
    width =
      if player.facing in {FaceUp, FaceDown}:
        sprite.width
      else:
        sprite.height
    height =
      if player.facing in {FaceUp, FaceDown}:
        sprite.height
      else:
        sprite.width
    closeX = max(1, width div SwooshDistanceDivisor)
    closeY = max(1, height div SwooshDistanceDivisor)
    playerCenterX = player.x + player.sprite.width div 2
    playerCenterY = player.y + player.sprite.height div 2
  case player.facing
  of FaceUp:
    (
      playerCenterX - width div 2,
      player.y - closeY + SwooshPlacementOffset - 8,
      width,
      height
    )
  of FaceDown:
    (
      playerCenterX - width div 2,
      player.y + player.sprite.height - closeY - SwooshPlacementOffset,
      width,
      height
    )
  of FaceLeft:
    (
      player.x - closeX - SwooshPlacementOffset,
      playerCenterY - height div 2,
      width,
      height
    )
  of FaceRight:
    (
      player.x + player.sprite.width - width + closeX +
        SwooshPlacementOffset,
      playerCenterY - height div 2,
      width,
      height
    )

proc lungeVector(facing: Facing, distance: int): tuple[dx, dy: int] =
  case facing
  of FaceUp: (0, -distance)
  of FaceDown: (0, distance)
  of FaceLeft: (-distance, 0)
  of FaceRight: (distance, 0)

proc chooseFacing(fromX, fromY, toX, toY: int): Facing =
  ## Chooses the dominant cardinal facing from one point to another.
  let
    dx = toX - fromX
    dy = toY - fromY
  if abs(dx) > abs(dy):
    if dx < 0: FaceLeft else: FaceRight
  else:
    if dy < 0: FaceUp else: FaceDown

proc chaseVector(fromX, fromY, toX, toY: int): tuple[dx, dy: int] =
  ## Returns one small walking step from one point toward another.
  let
    deltaX = toX - fromX
    deltaY = toY - fromY
  if deltaX < 0:
    result.dx = -1
  elif deltaX > 0:
    result.dx = 1
  if deltaY < 0:
    result.dy = -1
  elif deltaY > 0:
    result.dy = 1
  if abs(deltaX) > abs(deltaY) * 2:
    result.dy = 0
  elif abs(deltaY) > abs(deltaX) * 2:
    result.dx = 0

proc facingLaneHit(
  fromX,
  fromY,
  toX,
  toY: int,
  facing: Facing,
  maxDistance,
  halfWidth: int
): bool =
  let
    dx = toX - fromX
    dy = toY - fromY
  case facing
  of FaceLeft:
    dx <= 0 and -dx <= maxDistance and abs(dy) <= halfWidth
  of FaceRight:
    dx >= 0 and dx <= maxDistance and abs(dy) <= halfWidth
  of FaceUp:
    dy <= 0 and -dy <= maxDistance and abs(dx) <= halfWidth
  of FaceDown:
    dy >= 0 and dy <= maxDistance and abs(dx) <= halfWidth

proc dropPlayerCoins(sim: var SimServer, player: Actor) =
  ## Drops one coin pickup carrying all of a dead player's coins.
  if player.coins <= 0:
    return
  let
    sprite = sim.pickupSprite(PickupCoin)
    bounds = sim.pickupBounds(PickupCoin)
    centerX = boundsCenterX(player.x, player.bounds)
    centerY = boundsCenterY(player.y, player.bounds)
    x = worldClampPixel(
      centerX - bounds.x - bounds.w div 2,
      WorldWidthPixels - sprite.width
    )
    y = worldClampPixel(
      centerY - bounds.y - bounds.h div 2,
      WorldHeightPixels - sprite.height
    )
  sim.pickups.add(Pickup(
    x: x,
    y: y,
    kind: PickupCoin,
    value: player.coins
  ))

proc pickupPositionForPlayer(
  sim: SimServer,
  player: Actor,
  kind: PickupKind
): tuple[x, y: int] =
  let
    sprite = sim.pickupSprite(kind)
    bounds = sim.pickupBounds(kind)
    centerX = boundsCenterX(player.x, player.bounds)
    centerY = boundsCenterY(player.y, player.bounds)
  (
    x: worldClampPixel(
      centerX - bounds.x - bounds.w div 2,
      WorldWidthPixels - sprite.width
    ),
    y: worldClampPixel(
      centerY - bounds.y - bounds.h div 2,
      WorldHeightPixels - sprite.height
    )
  )

proc consumeCarryItem(
  sim: var SimServer,
  playerIndex: int,
  item: CarryKind
): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if item == CarryNone:
    return false
  sim.players[playerIndex].normalizeCarry()
  if sim.players[playerIndex].carryCounts[item] <= 0:
    return false
  dec sim.players[playerIndex].carryCounts[item]
  sim.players[playerIndex].syncCarrySelection()
  inc sim.scoreRevision
  true

proc giveCarry(sim: var SimServer, playerIndex: int, item: CarryKind): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if item == CarryNone:
    return false
  sim.players[playerIndex].normalizeCarry()
  let wasEmpty = sim.players[playerIndex].activeCarryItem() == CarryNone
  inc sim.players[playerIndex].carryCounts[item]
  if wasEmpty or sim.players[playerIndex].carriedItem == CarryNone:
    sim.players[playerIndex].carriedItem = item
  sim.players[playerIndex].syncCarrySelection()
  inc sim.scoreRevision
  true

proc dropCarry(sim: var SimServer, playerIndex: int): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  sim.players[playerIndex].normalizeCarry()
  let item = sim.players[playerIndex].activeCarryItem()
  if item == CarryNone:
    return false
  let
    kind = item.pickupForCarry()
    pos = sim.pickupPositionForPlayer(sim.players[playerIndex], kind)
    sprite = sim.pickupSprite(kind)
    offset = WorldTileSize
    dropX =
      case sim.players[playerIndex].facing
      of FaceLeft: pos.x - offset
      of FaceRight: pos.x + offset
      else: pos.x
    dropY =
      case sim.players[playerIndex].facing
      of FaceUp: pos.y - offset
      of FaceDown: pos.y + offset
      else: pos.y
  sim.pickups.add(Pickup(
    x: worldClampPixel(dropX, WorldWidthPixels - sprite.width),
    y: worldClampPixel(dropY, WorldHeightPixels - sprite.height),
    kind: kind,
    value: 0
  ))
  discard sim.consumeCarryItem(playerIndex, item)
  true

proc facingTileDirection(facing: Facing): tuple[dx, dy: int] =
  case facing
  of FaceLeft:
    (-1, 0)
  of FaceRight:
    (1, 0)
  of FaceUp:
    (0, -1)
  of FaceDown:
    (0, 1)

proc tileAcceptsSwampPlank(sim: SimServer, tx, ty: int): bool =
  if tx < 0 or ty < 0 or tx >= WorldWidthTiles or ty >= WorldHeightTiles:
    return false
  let index = tileIndex(tx, ty)
  sim.biomeKinds[index] == BiomeSwamp and
    sim.groundKinds[index] in {GroundMud, GroundShallowWater, GroundWater}

proc playerCanLaySwampPlank*(
  sim: SimServer,
  playerIndex: int
): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let player = sim.players[playerIndex]
  if player.lives <= 0 or not player.hasCarry(CarryWood):
    return false
  let
    centerTx = clamp(
      boundsCenterX(player.x, player.bounds) div WorldTileSize,
      0,
      WorldWidthTiles - 1
    )
    centerTy = clamp(
      boundsCenterY(player.y, player.bounds) div WorldTileSize,
      0,
      WorldHeightTiles - 1
    )
    dir = player.facing.facingTileDirection()
  for step in 0 ..< SwampPlankForwardTiles:
    if sim.tileAcceptsSwampPlank(
      centerTx + dir.dx * step,
      centerTy + dir.dy * step
    ):
      return true
  false

proc laySwampPlank(sim: var SimServer, playerIndex: int): bool =
  if not sim.playerCanLaySwampPlank(playerIndex):
    return false
  let player = sim.players[playerIndex]
  let
    centerTx = clamp(
      boundsCenterX(player.x, player.bounds) div WorldTileSize,
      0,
      WorldWidthTiles - 1
    )
    centerTy = clamp(
      boundsCenterY(player.y, player.bounds) div WorldTileSize,
      0,
      WorldHeightTiles - 1
    )
    dir = player.facing.facingTileDirection()
  var changed = false
  for step in 0 ..< SwampPlankForwardTiles:
    let
      tx = centerTx + dir.dx * step
      ty = centerTy + dir.dy * step
    if not sim.tileAcceptsSwampPlank(tx, ty):
      continue
    let index = tileIndex(tx, ty)
    sim.groundKinds[index] = GroundBridge
    sim.elevations[index] = min(sim.elevations[index], 1)
    sim.tiles[index] = false
    changed = true
  if not changed:
    return false
  discard sim.consumeCarryItem(playerIndex, CarryWood)
  true

proc tileAcceptsStoneSteps(sim: SimServer, tx, ty: int): bool =
  if tx < 0 or ty < 0 or tx >= WorldWidthTiles or ty >= WorldHeightTiles:
    return false
  sim.tileElevation(tx, ty) > StoneStepMaxElevation

proc playerCanLayStoneSteps*(
  sim: SimServer,
  playerIndex: int
): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let player = sim.players[playerIndex]
  if player.lives <= 0 or not player.hasCarry(CarryStone):
    return false
  let
    centerTx = clamp(
      boundsCenterX(player.x, player.bounds) div WorldTileSize,
      0,
      WorldWidthTiles - 1
    )
    centerTy = clamp(
      boundsCenterY(player.y, player.bounds) div WorldTileSize,
      0,
      WorldHeightTiles - 1
    )
    dir = player.facing.facingTileDirection()
  for step in 0 ..< StoneStepForwardTiles:
    if sim.tileAcceptsStoneSteps(
      centerTx + dir.dx * step,
      centerTy + dir.dy * step
    ):
      return true
  false

proc layStoneSteps(sim: var SimServer, playerIndex: int): bool =
  if not sim.playerCanLayStoneSteps(playerIndex):
    return false
  let player = sim.players[playerIndex]
  let
    centerTx = clamp(
      boundsCenterX(player.x, player.bounds) div WorldTileSize,
      0,
      WorldWidthTiles - 1
    )
    centerTy = clamp(
      boundsCenterY(player.y, player.bounds) div WorldTileSize,
      0,
      WorldHeightTiles - 1
    )
    dir = player.facing.facingTileDirection()
  var changed = false
  for step in 0 ..< StoneStepForwardTiles:
    let
      tx = centerTx + dir.dx * step
      ty = centerTy + dir.dy * step
    if not sim.tileAcceptsStoneSteps(tx, ty):
      continue
    let index = tileIndex(tx, ty)
    sim.elevations[index] = min(sim.elevations[index], StoneStepMaxElevation)
    sim.tiles[index] = false
    changed = true
  if not changed:
    return false
  discard sim.consumeCarryItem(playerIndex, CarryStone)
  true

proc useCarryInField(sim: var SimServer, playerIndex: int): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  sim.players[playerIndex].normalizeCarry()
  case sim.players[playerIndex].activeCarryItem()
  of CarryWood:
    if sim.laySwampPlank(playerIndex):
      return true
    if sim.players[playerIndex].hasCarry(CarryStone):
      sim.layStoneSteps(playerIndex)
    else:
      false
  of CarryStone:
    if sim.layStoneSteps(playerIndex):
      return true
    if sim.players[playerIndex].hasCarry(CarryWood):
      sim.laySwampPlank(playerIndex)
    else:
      false
  else:
    if sim.players[playerIndex].hasCarry(CarryWood):
      sim.laySwampPlank(playerIndex)
    elif sim.players[playerIndex].hasCarry(CarryStone):
      sim.layStoneSteps(playerIndex)
    else:
      false

proc handlePlayerDeath(sim: var SimServer, playerIndex: int) =
  ## Puts a defeated player into a short rescue window before respawn.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].lives > 0:
    return
  if sim.players[playerIndex].downedTicks > 0:
    return
  sim.players[playerIndex].lives = 0
  sim.players[playerIndex].downedTicks = DownedRespawnTicks
  sim.players[playerIndex].rescueTicks = 0
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].carryX = 0
  sim.players[playerIndex].carryY = 0
  sim.players[playerIndex].attackTicks = 0
  sim.players[playerIndex].attackResolved = false
  sim.players[playerIndex].abilityTicks = 0
  sim.players[playerIndex].abilityHoldTicks = 0
  sim.players[playerIndex].guardTicks = 0
  sim.players[playerIndex].slowTicks = 0
  sim.players[playerIndex].chillTicks = 0
  sim.players[playerIndex].poisonTicks = 0
  sim.players[playerIndex].exhaustionTicks = 0
  sim.players[playerIndex].routeTicks = 0
  sim.players[playerIndex].surveyTicks = 0
  sim.players[playerIndex].guideTicks = 0
  sim.players[playerIndex].huntTicks = 0
  sim.players[playerIndex].triumphTicks = 0
  sim.players[playerIndex].rationTicks = 0
  sim.players[playerIndex].moraleTicks = 0
  inc sim.scoreRevision

proc respawnDownedPlayer(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].lives > 0:
    return
  sim.dropPlayerCoins(sim.players[playerIndex])
  discard sim.dropCarry(playerIndex)
  inc sim.scoreRevision
  sim.resetPlayerAtSpawn(playerIndex)

proc reviveDownedPlayer(sim: var SimServer, playerIndex, rescuerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].downedTicks <= 0:
    return
  sim.players[playerIndex].downedTicks = 0
  sim.players[playerIndex].rescueTicks = 0
  sim.players[playerIndex].lives = min(
    sim.players[playerIndex].maxHp,
    DownedReviveHp
  )
  sim.players[playerIndex].invulnTicks = 60
  sim.players[playerIndex].slowTicks = 0
  sim.players[playerIndex].chillTicks = 0
  sim.players[playerIndex].poisonTicks = 0
  sim.players[playerIndex].exhaustionTicks = 0
  sim.players[playerIndex].routeTicks = 0
  sim.players[playerIndex].surveyTicks = 0
  sim.players[playerIndex].guideTicks = 0
  sim.players[playerIndex].huntTicks = 0
  if rescuerIndex >= 0 and rescuerIndex < sim.players.len and
      sim.players[rescuerIndex].role == RoleHealer:
    sim.players[rescuerIndex].healingDone += sim.players[playerIndex].lives
  inc sim.scoreRevision

proc guardedDamage(sim: var SimServer, playerIndex: int, amount: int): int =
  result = max(1, amount)
  let target = sim.players[playerIndex]
  let radiusSq = TankGuardRadius * TankGuardRadius
  for tankIndex in 0 ..< sim.players.len:
    if tankIndex == playerIndex:
      continue
    let tank = sim.players[tankIndex]
    if tank.lives <= 0 or tank.role != RoleTank or tank.guardTicks <= 0:
      continue
    if distanceSquaredActor(tank, target) > radiusSq:
      continue
    let reduced = max(1, (result * TankDamageReductionPct + 99) div 100)
    let blocked = result - reduced
    if blocked > 0:
      sim.players[tankIndex].damageBlocked += blocked
      inc sim.scoreRevision
    return reduced

proc playerProtectedByTankGuard*(sim: SimServer, playerIndex: int): bool =
  ## Returns true when an active tank guard is holding formation around a player.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let target = sim.players[playerIndex]
  if target.lives <= 0:
    return false
  let radiusSq = TankGuardRadius * TankGuardRadius
  for tankIndex in 0 ..< sim.players.len:
    let tank = sim.players[tankIndex]
    if tank.lives <= 0 or tank.role != RoleTank or tank.guardTicks <= 0:
      continue
    if tankIndex == playerIndex or distanceSquaredActor(tank, target) <= radiusSq:
      return true
  false

proc damagePlayer(sim: var SimServer, playerIndex: int, knockbackDx, knockbackDy, amount: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].lives <= 0 or sim.players[playerIndex].invulnTicks > 0:
    return

  let
    guarded = sim.guardedDamage(playerIndex, amount)
    reductionPct = sim.players[playerIndex].equippedDamageReductionPct()
    damage = max(1, (guarded * (100 - reductionPct) + 99) div 100)
  sim.players[playerIndex].lives = max(0, sim.players[playerIndex].lives - damage)
  sim.players[playerIndex].invulnTicks = 30
  inc sim.scoreRevision

  var actor = Actor(
    x: sim.players[playerIndex].x,
    y: sim.players[playerIndex].y,
    sprite: sim.players[playerIndex].sprite,
    bounds: sim.players[playerIndex].bounds
  )
  sim.moveActor(actor, knockbackDx, knockbackDy)
  sim.players[playerIndex].x = actor.x
  sim.players[playerIndex].y = actor.y
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].carryX = 0
  sim.players[playerIndex].carryY = 0

  if sim.players[playerIndex].lives <= 0:
    sim.handlePlayerDeath(playerIndex)

proc damagePlayerFromStatus(sim: var SimServer, playerIndex, amount: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].lives <= 0:
    return
  sim.players[playerIndex].lives = max(
    0,
    sim.players[playerIndex].lives - max(1, amount)
  )
  inc sim.scoreRevision
  if sim.players[playerIndex].lives <= 0:
    sim.handlePlayerDeath(playerIndex)

proc playerHasNearbyAlly(
  sim: SimServer,
  playerIndex: int,
  radius: int
): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let radiusSq = radius * radius
  for otherIndex in 0 ..< sim.players.len:
    if otherIndex == playerIndex:
      continue
    if sim.players[otherIndex].lives <= 0:
      continue
    if distanceSquaredActor(
      sim.players[playerIndex],
      sim.players[otherIndex]
    ) <= radiusSq:
      return true
  false

proc playerInTrioFormation*(sim: SimServer, playerIndex: int): bool =
  ## Returns true when tank, DPS, and healer are holding a local formation.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if sim.players[playerIndex].lives <= 0:
    return false
  let radiusSq = TrioFormationRadius * TrioFormationRadius
  var
    tank = false
    dps = false
    healer = false
  for other in sim.players:
    if other.lives <= 0:
      continue
    if distanceSquaredActor(sim.players[playerIndex], other) > radiusSq:
      continue
    case other.role
    of RoleTank:
      tank = true
    of RoleDps:
      dps = true
    of RoleHealer:
      healer = true
    of RoleUnarmed:
      discard
  tank and dps and healer

proc playerPartyTacticLabel*(sim: SimServer, playerIndex: int): string =
  if sim.playerInTrioFormation(playerIndex):
    "trio"
  else:
    ""

proc bossRaidDamageBonus*(sim: SimServer, playerIndex: int, mob: Mob): int =
  ## Rewards the final boss fight for using the same formation and focus
  ## language the rest of the expedition teaches.
  if mob.kind != BossMob:
    return 0
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return 0
  if sim.players[playerIndex].lives <= 0 or
      sim.players[playerIndex].role == RoleUnarmed:
    return 0
  if sim.playerInTrioFormation(playerIndex):
    result += BossTrioDamageBonus
  if mob.partyFocusRoleCount(sim.players, sim.tickCount) >= 3:
    result += BossFocusDamageBonus

proc staggerBossFromFocus(sim: var SimServer, mobIndex: int) =
  if mobIndex < 0 or mobIndex >= sim.mobs.len:
    return
  if sim.mobs[mobIndex].kind != BossMob:
    return
  if sim.mobs[mobIndex].partyFocusRoleCount(sim.players, sim.tickCount) < 3:
    return
  let before =
    (
      stagger: sim.mobs[mobIndex].staggerTicks,
      cooldown: sim.mobs[mobIndex].attackCooldown,
      phase: sim.mobs[mobIndex].attackPhase,
      ticks: sim.mobs[mobIndex].attackTicks
    )
  sim.mobs[mobIndex].staggerTicks = max(
    sim.mobs[mobIndex].staggerTicks,
    BossStaggerTicks
  )
  sim.mobs[mobIndex].attackCooldown = max(
    sim.mobs[mobIndex].attackCooldown,
    BossStaggerAttackCooldown
  )
  sim.mobs[mobIndex].attackPhase = MobIdle
  sim.mobs[mobIndex].attackTicks = 0
  if before.stagger != sim.mobs[mobIndex].staggerTicks or
      before.cooldown != sim.mobs[mobIndex].attackCooldown or
      before.phase != sim.mobs[mobIndex].attackPhase or
      before.ticks != sim.mobs[mobIndex].attackTicks:
    inc sim.scoreRevision

proc nearbyDownedRescuer(
  sim: SimServer,
  playerIndex: int
): tuple[index, step: int] =
  result = (index: -1, step: 0)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let radiusSq = DownedRescueRadius * DownedRescueRadius
  for otherIndex in 0 ..< sim.players.len:
    if otherIndex == playerIndex:
      continue
    let rescuer = sim.players[otherIndex]
    if rescuer.lives <= 0:
      continue
    if distanceSquaredActor(rescuer, sim.players[playerIndex]) > radiusSq:
      continue
    let step =
      if rescuer.role == RoleHealer:
        HealerDownedRescueStep
      else:
        1
    if step > result.step:
      result = (index: otherIndex, step: step)

proc playerIsolationThreatened*(sim: SimServer, playerIndex: int): bool =
  ## Returns true when an isolation-punishing enemy is close to an alone player.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if sim.players[playerIndex].lives <= 0:
    return false
  if sim.playerHasNearbyAlly(playerIndex, IsolationThreatRadius):
    return false
  let
    playerCenterX = boundsCenterX(
      sim.players[playerIndex].x,
      sim.players[playerIndex].bounds
    )
    playerCenterY = boundsCenterY(
      sim.players[playerIndex].y,
      sim.players[playerIndex].bounds
    )
    radiusSq = (IsolationThreatRadius * 2) * (IsolationThreatRadius * 2)
  for mob in sim.mobs:
    if not mob.species.speciesPunishesIsolation():
      continue
    let
      mobCenterX = boundsCenterX(mob.x, mob.bounds)
      mobCenterY = boundsCenterY(mob.y, mob.bounds)
    if distanceSquared(
      playerCenterX,
      playerCenterY,
      mobCenterX,
      mobCenterY
    ) <= radiusSq:
      return true
  false

proc playerNeedsHelp*(sim: SimServer, playerIndex: int): bool =
  ## Returns true when a live player is low enough to need teammate support.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let player = sim.players[playerIndex]
  player.lives > 0 and player.maxHp > 0 and player.lives < player.maxHp and
    player.lives * 100 <= player.maxHp * LowHealthHelpThresholdPercent

proc playerDowned*(sim: SimServer, playerIndex: int): bool =
  ## Returns true while a defeated player is waiting for rescue or respawn.
  playerIndex >= 0 and playerIndex < sim.players.len and
    sim.players[playerIndex].lives <= 0 and
    sim.players[playerIndex].downedTicks > 0

proc nearbyHealerIndex(
  sim: SimServer,
  playerIndex: int,
  radius = HealerTriageRadius
): int =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return -1
  let radiusSq = radius * radius
  for healerIndex in 0 ..< sim.players.len:
    if healerIndex == playerIndex:
      continue
    let healer = sim.players[healerIndex]
    if healer.lives <= 0 or healer.role != RoleHealer:
      continue
    if distanceSquaredActor(healer, sim.players[playerIndex]) <= radiusSq:
      return healerIndex
  -1

proc mobHitDamage*(sim: SimServer, mob: Mob, playerIndex: int): int =
  result = mob.mobDamage()
  if playerIndex >= 0 and playerIndex < sim.players.len:
    result = max(
      1,
      result + elevationDamageModifier(
        sim.mobTileElevation(mob),
        sim.actorTileElevation(sim.players[playerIndex])
      )
    )
  if mob.species.speciesPunishesIsolation() and
      not sim.playerHasNearbyAlly(playerIndex, IsolationThreatRadius):
    inc result
  if mob.species.speciesSwarms() and
      not sim.playerHasNearbyAlly(playerIndex, WorldTileSize * 2):
    inc result
  let leaderRadiusSq = (WorldTileSize * 3) * (WorldTileSize * 3)
  for other in sim.mobs:
    if not other.species.speciesLeadsPack():
      continue
    if distanceSquared(
      boundsCenterX(mob.x, mob.bounds),
      boundsCenterY(mob.y, mob.bounds),
      boundsCenterX(other.x, other.bounds),
      boundsCenterY(other.y, other.bounds)
    ) <= leaderRadiusSq:
      inc result
      break

proc applyMobHitStatus*(
  sim: var SimServer,
  mob: Mob,
  playerIndex: int
) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].lives <= 0:
    return
  if mob.species.speciesAppliesSlow():
    sim.players[playerIndex].slowTicks = max(
      sim.players[playerIndex].slowTicks,
      StatusSlowTicks
    )
    inc sim.scoreRevision
  if mob.species.speciesAppliesChill():
    sim.players[playerIndex].chillTicks = max(
      sim.players[playerIndex].chillTicks,
      StatusChillTicks
    )
    inc sim.scoreRevision
  if mob.species.speciesAppliesPoison():
    sim.players[playerIndex].poisonTicks = max(
      sim.players[playerIndex].poisonTicks,
      StatusPoisonTicks
    )
    inc sim.scoreRevision

proc landmarkCenter(
  sim: SimServer,
  landmark: Landmark
): tuple[x, y: int] =
  let bounds = sim.landmarkBounds(landmark.kind)
  (
    x: landmark.landmarkWorldX() + bounds.x + max(1, bounds.w) div 2,
    y: landmark.landmarkWorldY() + bounds.y + max(1, bounds.h) div 2
  )

proc playerNearLandmark(
  sim: SimServer,
  player: Actor,
  landmark: Landmark,
  radius: int
): bool =
  let
    lc = sim.landmarkCenter(landmark)
    pcx = boundsCenterX(player.x, player.bounds)
    pcy = boundsCenterY(player.y, player.bounds)
  distanceSquared(pcx, pcy, lc.x, lc.y) <= radius * radius

proc distinctRolesNearLandmark*(
  sim: SimServer,
  landmark: Landmark,
  radius: int
): int =
  ## Counts distinct live party roles holding one objective.
  var
    tank = false
    dps = false
    healer = false
  for player in sim.players:
    if player.lives <= 0 or not sim.playerNearLandmark(player, landmark, radius):
      continue
    case player.role
    of RoleTank:
      tank = true
    of RoleDps:
      dps = true
    of RoleHealer:
      healer = true
    of RoleUnarmed:
      discard
  result = (if tank: 1 else: 0) + (if dps: 1 else: 0) +
    (if healer: 1 else: 0)

proc campIsFortified*(landmark: Landmark): bool =
  landmark.kind == LandmarkCamp and landmark.done and
    (landmark.progress and CampFortifiedFlag) != 0

proc campIsProvisioned*(landmark: Landmark): bool =
  landmark.kind == LandmarkCamp and landmark.done and
    (landmark.progress and CampProvisionedFlag) != 0

proc campIsWarded*(landmark: Landmark): bool =
  landmark.kind == LandmarkCamp and landmark.done and
    (landmark.progress and CampWardedFlag) != 0

proc campIsRally*(landmark: Landmark): bool =
  landmark.kind == LandmarkCamp and landmark.done and
    (landmark.progress and CampRallyFlag) != 0

proc campIsAid*(landmark: Landmark): bool =
  landmark.kind == LandmarkCamp and landmark.done and
    (landmark.progress and CampAidFlag) != 0

proc playerNearActivatedCamp*(
  sim: SimServer,
  playerIndex: int,
  radius = CampShelterRadius
): bool =
  ## Returns true when a live player is inside an activated camp shelter zone.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if sim.players[playerIndex].lives <= 0:
    return false
  for landmark in sim.landmarks:
    if landmark.kind == LandmarkCamp and landmark.done and
        sim.playerNearLandmark(sim.players[playerIndex], landmark, radius):
      return true
  false

proc playerNearProvisionedCamp*(
  sim: SimServer,
  playerIndex: int,
  radius = CampShelterRadius
): bool =
  ## Returns true when a live player is inside a provisioned camp shelter zone.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if sim.players[playerIndex].lives <= 0:
    return false
  for landmark in sim.landmarks:
    if landmark.campIsProvisioned() and
        sim.playerNearLandmark(sim.players[playerIndex], landmark, radius):
      return true
  false

proc playerHasWeatherRation*(sim: SimServer, playerIndex: int): bool =
  ## Returns true when camp meals are buffering harsh-weather ration pressure.
  playerIndex >= 0 and playerIndex < sim.players.len and
    sim.players[playerIndex].lives > 0 and
    sim.players[playerIndex].rationTicks > 0

proc grantCampRation(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].lives <= 0:
    return
  if sim.players[playerIndex].rationTicks >= CampMealRationTicks:
    return
  sim.players[playerIndex].rationTicks = CampMealRationTicks
  inc sim.scoreRevision

proc playerNearRallyCamp*(
  sim: SimServer,
  playerIndex: int,
  radius = CampShelterRadius
): bool =
  ## Returns true when a live player is inside a DPS rally camp zone.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if sim.players[playerIndex].lives <= 0:
    return false
  for landmark in sim.landmarks:
    if landmark.campIsRally() and
        sim.playerNearLandmark(sim.players[playerIndex], landmark, radius):
      return true
  false

proc playerNearAidCamp*(
  sim: SimServer,
  playerIndex: int,
  radius = CampShelterRadius
): bool =
  ## Returns true when a live player is inside a healer aid camp zone.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if sim.players[playerIndex].lives <= 0:
    return false
  for landmark in sim.landmarks:
    if landmark.campIsAid() and
        sim.playerNearLandmark(sim.players[playerIndex], landmark, radius):
      return true
  false

proc playerNearBlessedShrine*(
  sim: SimServer,
  playerIndex: int,
  radius = ShrineBlessingRadius
): bool =
  ## Returns true when a completed shrine is acting as a local sanctuary.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if sim.players[playerIndex].lives <= 0:
    return false
  for landmark in sim.landmarks:
    if landmark.kind == LandmarkShrine and landmark.done and
        sim.playerNearLandmark(sim.players[playerIndex], landmark, radius):
      return true
  false

proc playerNearExpeditionShelter*(
  sim: SimServer,
  playerIndex: int,
  radius = CampShelterRadius
): bool =
  ## Returns true near a camp shelter or biome survival waystation.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if sim.players[playerIndex].lives <= 0:
    return false
  if sim.playerNearBlessedShrine(playerIndex):
    return true
  for landmark in sim.landmarks:
    if landmark.kind == LandmarkCamp and landmark.done and
        sim.playerNearLandmark(sim.players[playerIndex], landmark, radius):
      return true
    if landmark.kind == LandmarkWaystation and landmark.done:
      let biome = sim.tileBiomeKind(landmark.tx, landmark.ty)
      if biome in {BiomeSwamp, BiomeDesert, BiomeSnow, BiomeCave, BiomeRuins} and
          sim.playerNearLandmark(
            sim.players[playerIndex],
            landmark,
            BiomeWaystationShelterRadius
          ):
        return true
  false

proc addResourceFromLandmark(sim: var SimServer, kind: LandmarkKind) =
  case kind
  of LandmarkWood:
    inc sim.wood
  of LandmarkFood:
    inc sim.food
  of LandmarkStone:
    inc sim.stone
  of LandmarkGold:
    inc sim.wood
    sim.stone += 2
  else:
    discard
  inc sim.resourcesCollected
  inc sim.scoreRevision

proc giveOrDropHarvestCarry(
  sim: var SimServer,
  kind: LandmarkKind,
  playerIndex: int,
  x,
  y: int
) =
  let item = kind.carryForLandmark()
  if item == CarryNone:
    return
  if sim.giveCarry(playerIndex, item):
    return
  let pickupKind = item.pickupForCarry()
  sim.pickups.add(Pickup(
    x: worldClampPixel(x, WorldWidthPixels - sim.pickupSprite(pickupKind).width),
    y: worldClampPixel(y, WorldHeightPixels - sim.pickupSprite(pickupKind).height),
    kind: pickupKind,
    value: 0
  ))
  inc sim.scoreRevision

proc addCarryPickupAt(sim: var SimServer, item: CarryKind, x, y: int) =
  if item == CarryNone:
    return
  let pickupKind = item.pickupForCarry()
  sim.pickups.add(Pickup(
    x: worldClampPixel(x, WorldWidthPixels - sim.pickupSprite(pickupKind).width),
    y: worldClampPixel(y, WorldHeightPixels - sim.pickupSprite(pickupKind).height),
    kind: pickupKind,
    value: 1
  ))
  inc sim.scoreRevision

proc addCampRoleGear(sim: var SimServer, landmark: Landmark) =
  ## Makes activated camps useful as forward role-swap stations.
  let
    x = landmark.landmarkWorldX()
    y = landmark.landmarkWorldY()
  sim.pickups.add(Pickup(
    x: worldClampPixel(x - WorldTileSize, WorldWidthPixels - ArtCellSize),
    y: worldClampPixel(y, WorldHeightPixels - ArtCellSize),
    kind: PickupTankGear,
    value: 0
  ))
  sim.pickups.add(Pickup(
    x: worldClampPixel(x, WorldWidthPixels - ArtCellSize),
    y: worldClampPixel(y - WorldTileSize, WorldHeightPixels - ArtCellSize),
    kind: PickupDpsGear,
    value: 0
  ))
  sim.pickups.add(Pickup(
    x: worldClampPixel(x + WorldTileSize, WorldWidthPixels - ArtCellSize),
    y: worldClampPixel(y, WorldHeightPixels - ArtCellSize),
    kind: PickupHealerGear,
    value: 0
  ))

proc campShortcutGround(
  biome: BiomeKind,
  previous: GroundKind
): GroundKind =
  if previous in {GroundWater, GroundShallowWater} or biome == BiomeSwamp:
    GroundBridge
  else:
    GroundRoad

proc revealCampShortcut(sim: var SimServer, landmark: Landmark) =
  ## Cuts a short visible route through rough ground around an activated camp.
  for ty in landmark.ty - CampShortcutHalfHeightTiles ..
      landmark.ty + CampShortcutHalfHeightTiles:
    for tx in landmark.tx - CampShortcutBackTiles ..
        landmark.tx + CampShortcutForwardTiles:
      if tx < 0 or ty < 0 or tx >= WorldWidthTiles or ty >= WorldHeightTiles:
        continue
      let
        index = tileIndex(tx, ty)
        biome = sim.tileBiomeKind(tx, ty)
      sim.groundKinds[index] = campShortcutGround(
        biome,
        sim.groundKinds[index]
      )
      sim.elevations[index] = min(sim.elevations[index], 1)
      sim.tiles[index] = false
  inc sim.scoreRevision

proc revealWaystationRoute(sim: var SimServer, landmark: Landmark) =
  ## Turns biome detours into short readable paths through local rough ground.
  for ty in landmark.ty - BiomeWaystationRouteHalfHeightTiles ..
      landmark.ty + BiomeWaystationRouteHalfHeightTiles:
    for tx in landmark.tx - BiomeWaystationRouteBackTiles ..
        landmark.tx + BiomeWaystationRouteForwardTiles:
      if tx < 0 or ty < 0 or tx >= WorldWidthTiles or ty >= WorldHeightTiles:
        continue
      let
        index = tileIndex(tx, ty)
        biome = sim.tileBiomeKind(tx, ty)
      sim.groundKinds[index] = campShortcutGround(
        biome,
        sim.groundKinds[index]
      )
      sim.elevations[index] = min(sim.elevations[index], 1)
      sim.tiles[index] = false
  inc sim.scoreRevision

proc revealRescueTrail(sim: var SimServer, landmark: Landmark) =
  ## Lets a rescued traveler guide the party through the next local obstacle.
  for ty in landmark.ty - RescueTrailHalfHeightTiles ..
      landmark.ty + RescueTrailHalfHeightTiles:
    for tx in landmark.tx - RescueTrailBackTiles ..
        landmark.tx + RescueTrailForwardTiles:
      if tx < 0 or ty < 0 or tx >= WorldWidthTiles or ty >= WorldHeightTiles:
        continue
      let
        index = tileIndex(tx, ty)
        biome = sim.tileBiomeKind(tx, ty)
      sim.groundKinds[index] = campShortcutGround(
        biome,
        sim.groundKinds[index]
      )
      sim.elevations[index] = min(sim.elevations[index], 1)
      sim.tiles[index] = false
  inc sim.scoreRevision

proc revealBeaconSurveyRoute(sim: var SimServer, landmark: Landmark) =
  ## Turns a completed relic beacon into a short surveyed route forward.
  for ty in landmark.ty - BeaconSurveyHalfHeightTiles ..
      landmark.ty + BeaconSurveyHalfHeightTiles:
    for tx in landmark.tx - BeaconSurveyBackTiles ..
        landmark.tx + BeaconSurveyForwardTiles:
      if tx < 0 or ty < 0 or tx >= WorldWidthTiles or ty >= WorldHeightTiles:
        continue
      let
        index = tileIndex(tx, ty)
        biome = sim.tileBiomeKind(tx, ty)
      sim.groundKinds[index] = campShortcutGround(
        biome,
        sim.groundKinds[index]
      )
      sim.elevations[index] = min(sim.elevations[index], 1)
      sim.tiles[index] = false
  inc sim.scoreRevision

proc healLivePlayers(sim: var SimServer, amount: int) =
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].lives <= 0:
      continue
    sim.players[playerIndex].lives = min(
      sim.players[playerIndex].maxHp,
      sim.players[playerIndex].lives + amount
    )

proc clearLivePlayerStatuses(sim: var SimServer) =
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].lives <= 0:
      continue
    sim.players[playerIndex].slowTicks = 0
    sim.players[playerIndex].chillTicks = 0
    sim.players[playerIndex].poisonTicks = 0
    sim.players[playerIndex].exhaustionTicks = 0

proc grantBiomeMasteryRewards(sim: var SimServer, biome: BiomeKind) =
  ## Gives biome-specific payoff so optional clears change later route choices.
  case biome
  of BiomeForest:
    sim.food += 2
    inc sim.wood
  of BiomePlains:
    for player in sim.players.mitems:
      if player.lives > 0:
        player.abilityCooldown = 0
  of BiomeSwamp:
    inc sim.stone
    for player in sim.players.mitems:
      if player.lives > 0:
        player.slowTicks = 0
  of BiomeDesert:
    sim.food += 2
    for player in sim.players.mitems:
      if player.lives > 0:
        player.poisonTicks = 0
  of BiomeSnow:
    sim.food += 2
    for player in sim.players.mitems:
      if player.lives > 0:
        player.chillTicks = 0
        player.exhaustionTicks = 0
  of BiomeCave:
    inc sim.stone
    for player in sim.players.mitems:
      if player.lives > 0:
        player.exhaustionTicks = 0
  of BiomeRuins:
    sim.clearLivePlayerStatuses()
  of BiomeOrigin:
    discard
  for player in sim.players.mitems:
    if player.lives > 0:
      player.moraleTicks = max(player.moraleTicks, BiomeMasteryMoraleTicks)

proc tryGrantBiomeMasteryForSegment*(sim: var SimServer, segmentIndex: int) =
  if segmentIndex < 0:
    return
  let biome = segmentIndex.biomeForSegmentIndex()
  if biome == BiomeOrigin or sim.biomeMastered[biome]:
    return
  if sim.completedSegmentMilestones(segmentIndex) < BiomeMasteryRequiredMilestones:
    return
  sim.biomeMastered[biome] = true
  sim.grantBiomeMasteryRewards(biome)
  inc sim.scoreRevision

proc activateShrine(sim: var SimServer) =
  ## Completes one optional side objective and gives the party a sustain bump.
  inc sim.sideObjectivesCompleted
  sim.food += ShrineFoodBonus
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].lives <= 0:
      continue
    sim.players[playerIndex].lives = min(
      sim.players[playerIndex].maxHp,
      sim.players[playerIndex].lives + ShrineHealAmount
    )
    sim.players[playerIndex].slowTicks = 0
    sim.players[playerIndex].chillTicks = 0
    sim.players[playerIndex].poisonTicks = 0
    sim.players[playerIndex].exhaustionTicks = 0
  inc sim.scoreRevision

proc addGuideFollower(
  sim: var SimServer,
  landmark: Landmark,
  targetPlayerIndex: int
)

proc activateRescueEvent(
  sim: var SimServer,
  landmark: Landmark,
  targetPlayerIndex = -1
) =
  ## Completes one stranded-traveler rescue detour for sustain, score, and route help.
  inc sim.sideObjectivesCompleted
  sim.food += RescueFoodBonus
  sim.revealRescueTrail(landmark)
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].lives <= 0:
      continue
    sim.players[playerIndex].lives = min(
      sim.players[playerIndex].maxHp,
      sim.players[playerIndex].lives + RescueHealAmount
    )
    sim.players[playerIndex].guideTicks = max(
      sim.players[playerIndex].guideTicks,
      RescueGuideTicks
    )
  if targetPlayerIndex >= 0:
    sim.addGuideFollower(landmark, targetPlayerIndex)
  sim.tryGrantBiomeMasteryForSegment(landmark.tx.adventureSegmentIndexForTileX())
  inc sim.scoreRevision

proc activeCampDropoffNear(sim: SimServer, player: Actor): bool =
  if boundsCenterX(player.x, player.bounds) < SafeZoneRightPixels:
    return true
  for landmark in sim.landmarks:
    if landmark.kind != LandmarkCamp or not landmark.done:
      continue
    if sim.playerNearLandmark(player, landmark, LandmarkActivationRadius):
      return true
  false

proc addGuideFollower(
  sim: var SimServer,
  landmark: Landmark,
  targetPlayerIndex: int
) =
  if targetPlayerIndex < 0 or targetPlayerIndex >= sim.players.len:
    return
  let center = sim.landmarkCenter(landmark)
  sim.guides.add(GuideFollower(
    x: center.x - ArtCellSize div 2,
    y: center.y - ArtCellSize div 2,
    targetPlayerId: sim.players[targetPlayerIndex].id,
    thanksTicks: 0,
    done: false
  ))
  inc sim.scoreRevision

proc guideTargetIndex(sim: SimServer, guide: GuideFollower): int =
  for i in 0 ..< sim.players.len:
    if sim.players[i].id == guide.targetPlayerId:
      return i
  -1

proc guideLineTarget(target: Actor, slot: int): tuple[x, y: int] =
  let spacing = ArtCellSize * (slot + 1)
  case target.facing
  of FaceRight:
    (x: target.x - spacing, y: target.y)
  of FaceLeft:
    (x: target.x + spacing, y: target.y)
  of FaceDown:
    (x: target.x, y: target.y - spacing)
  of FaceUp:
    (x: target.x, y: target.y + spacing)

proc updateGuides(sim: var SimServer) =
  if sim.guides.len == 0:
    return
  var remaining: seq[GuideFollower] = @[]
  for guideSlot, guide in sim.guides:
    var current = guide
    if current.done:
      dec current.thanksTicks
      if current.thanksTicks > 0:
        remaining.add(current)
      inc sim.scoreRevision
      continue
    let targetIndex = sim.guideTargetIndex(current)
    if targetIndex < 0 or sim.players[targetIndex].lives <= 0:
      continue
    let target = sim.players[targetIndex]
    let lineTarget = guideLineTarget(target, guideSlot)
    if sim.activeCampDropoffNear(target):
      current.x = worldClampPixel(lineTarget.x, WorldWidthPixels - ArtCellSize)
      current.y = worldClampPixel(lineTarget.y, WorldHeightPixels - ArtCellSize)
      current.done = true
      current.thanksTicks = TargetFps * 3
      remaining.add(current)
      inc sim.scoreRevision
      continue
    let
      targetX = lineTarget.x
      targetY = lineTarget.y
      dx = targetX - current.x
      dy = targetY - current.y
      step = 2
    if abs(dx) > WorldTileSize div 2:
      current.x += clamp(dx, -step, step)
    if abs(dy) > WorldTileSize div 3:
      current.y += clamp(dy, -step, step)
    current.x = worldClampPixel(current.x, WorldWidthPixels - ArtCellSize)
    current.y = worldClampPixel(current.y, WorldHeightPixels - ArtCellSize)
    remaining.add(current)
  if remaining.len != sim.guides.len:
    inc sim.scoreRevision
  sim.guides = remaining

proc pacifyMobsNearLandmark(
  sim: var SimServer,
  landmark: Landmark,
  radius: int
): int =
  ## Clears local non-boss threats around a defensive expedition point.
  let
    center = sim.landmarkCenter(landmark)
    radiusSq = radius * radius
  var survivors: seq[Mob] = @[]
  for mob in sim.mobs:
    if mob.kind == BossMob:
      survivors.add(mob)
      continue
    let
      mobCenterX = boundsCenterX(mob.x, mob.bounds)
      mobCenterY = boundsCenterY(mob.y, mob.bounds)
    if distanceSquared(center.x, center.y, mobCenterX, mobCenterY) <= radiusSq:
      inc result
    else:
      survivors.add(mob)
  if result > 0:
    sim.mobs = survivors

proc grantFinalGateTriumph(sim: var SimServer, landmark: Landmark) =
  ## Turns the completed final gate into a visible party-wide finish state.
  discard sim.pacifyMobsNearLandmark(landmark, FinalGateTriumphRadius)
  for player in sim.players.mitems:
    if player.maxHp <= 0:
      continue
    player.lives = player.maxHp
    player.downedTicks = 0
    player.rescueTicks = 0
    player.slowTicks = 0
    player.chillTicks = 0
    player.poisonTicks = 0
    player.exhaustionTicks = 0
    player.triumphTicks = max(player.triumphTicks, FinalGateTriumphTicks)
    player.invulnTicks = max(player.invulnTicks, FinalGateTriumphTicks)
  inc sim.scoreRevision

proc grantObjectiveMorale(sim: var SimServer, participantCount: int) =
  ## Rewards visibly grouped objective holds with short next-push momentum.
  if participantCount < 2:
    return
  var changed = false
  for player in sim.players.mitems:
    if player.lives <= 0:
      continue
    let before = player.moraleTicks
    player.moraleTicks = max(player.moraleTicks, ObjectiveMoraleTicks)
    changed = changed or player.moraleTicks != before
  if changed:
    inc sim.scoreRevision

proc pacifyLairMobs(sim: var SimServer, landmark: Landmark): int =
  ## Clears nearby local threats when a monster lair is destroyed.
  sim.pacifyMobsNearLandmark(landmark, LairPacifyRadius)

proc waystationActivationStep*(biome: BiomeKind, role: PlayerRole): int =
  if role == biome.preferredWaystationRole():
    BiomeWaystationFastStep
  else:
    1

proc objectiveHoldStep*(
  kind: LandmarkKind,
  biome: BiomeKind,
  role: PlayerRole
): int =
  ## Returns one player's contribution to cooperative hold objectives.
  case kind
  of LandmarkRescue:
    if role == RoleHealer:
      HealerRescueEventStep
    else:
      1
  of LandmarkBeacon:
    if role == RoleDps:
      DpsBeaconAttunementStep
    else:
      1
  of LandmarkWaystation:
    waystationActivationStep(biome, role)
  else:
    1

proc finalGateRitualStep*(roleCount: int): int =
  ## Speeds up the final ritual when distinct party roles hold the gate.
  if roleCount >= 3:
    FinalGateThreeRoleStep
  elif roleCount >= 2:
    FinalGateTwoRoleStep
  else:
    1

proc activateWaystation(sim: var SimServer, landmarkIndex: int) =
  if landmarkIndex < 0 or landmarkIndex >= sim.landmarks.len:
    return
  if sim.landmarks[landmarkIndex].done:
    return
  let
    landmark = sim.landmarks[landmarkIndex]
    biome = sim.tileBiomeKind(landmark.tx, landmark.ty)
  sim.landmarks[landmarkIndex].done = true
  inc sim.sideObjectivesCompleted
  sim.revealWaystationRoute(landmark)
  case biome
  of BiomeForest:
    sim.food += BiomeWaystationFoodBonus + 1
    sim.healLivePlayers(BiomeWaystationHealAmount)
  of BiomePlains:
    sim.healLivePlayers(BiomeWaystationHealAmount)
    for player in sim.players.mitems:
      if player.lives > 0:
        player.abilityCooldown = 0
  of BiomeSwamp:
    for player in sim.players.mitems:
      if player.lives > 0:
        player.slowTicks = 0
    inc sim.stone
  of BiomeDesert:
    sim.food += BiomeWaystationFoodBonus + 1
    for player in sim.players.mitems:
      if player.lives > 0:
        player.poisonTicks = 0
    sim.healLivePlayers(BiomeWaystationHealAmount)
  of BiomeSnow:
    sim.food += BiomeWaystationFoodBonus
    for player in sim.players.mitems:
      if player.lives > 0:
        player.chillTicks = 0
        player.exhaustionTicks = 0
    sim.healLivePlayers(BiomeWaystationHealAmount)
  of BiomeCave:
    inc sim.stone
    for player in sim.players.mitems:
      if player.lives > 0:
        player.exhaustionTicks = 0
    discard sim.pacifyMobsNearLandmark(landmark, BiomeWaystationPacifyRadius)
  of BiomeRuins:
    sim.clearLivePlayerStatuses()
    discard sim.pacifyMobsNearLandmark(landmark, BiomeWaystationPacifyRadius)
  of BiomeOrigin:
    sim.healLivePlayers(BiomeWaystationHealAmount)
  for player in sim.players.mitems:
    if player.lives > 0:
      player.routeTicks = max(player.routeTicks, BiomeWaystationRouteTicks)
  sim.tryGrantBiomeMasteryForSegment(landmark.tx.adventureSegmentIndexForTileX())
  inc sim.scoreRevision

proc destroyLair(sim: var SimServer, landmarkIndex: int) =
  if landmarkIndex < 0 or landmarkIndex >= sim.landmarks.len:
    return
  if sim.landmarks[landmarkIndex].done:
    return
  sim.landmarks[landmarkIndex].done = true
  inc sim.sideObjectivesCompleted
  sim.food += LairFoodBonus
  sim.stone += LairStoneBonus
  let
    landmark = sim.landmarks[landmarkIndex]
    center = sim.landmarkCenter(landmark)
    cache = sim.tileBiomeKind(landmark.tx, landmark.ty).lairCacheCarriesForBiome()
  sim.addCarryPickupAt(cache.first, center.x - WorldTileSize div 2, center.y)
  sim.addCarryPickupAt(cache.second, center.x + WorldTileSize div 2, center.y)
  discard sim.pacifyLairMobs(landmark)
  for player in sim.players.mitems:
    if player.lives > 0:
      player.huntTicks = max(player.huntTicks, LairHunterTicks)
  sim.tryGrantBiomeMasteryForSegment(landmark.tx.adventureSegmentIndexForTileX())
  inc sim.scoreRevision

proc fortifyCamp(sim: var SimServer, landmarkIndex: int) =
  if landmarkIndex < 0 or landmarkIndex >= sim.landmarks.len:
    return
  if sim.landmarks[landmarkIndex].kind != LandmarkCamp or
      not sim.landmarks[landmarkIndex].done or
      sim.landmarks[landmarkIndex].campIsFortified():
    return
  sim.landmarks[landmarkIndex].progress =
    sim.landmarks[landmarkIndex].progress or CampFortifiedFlag
  discard sim.pacifyMobsNearLandmark(
    sim.landmarks[landmarkIndex],
    CampFortificationRadius
  )
  inc sim.scoreRevision

proc provisionCamp(sim: var SimServer, landmarkIndex: int) =
  if landmarkIndex < 0 or landmarkIndex >= sim.landmarks.len:
    return
  if sim.landmarks[landmarkIndex].kind != LandmarkCamp or
      not sim.landmarks[landmarkIndex].done or
      sim.landmarks[landmarkIndex].campIsProvisioned():
    return
  sim.landmarks[landmarkIndex].progress =
    sim.landmarks[landmarkIndex].progress or CampProvisionedFlag
  let camp = sim.landmarks[landmarkIndex]
  for playerIndex in 0 ..< sim.players.len:
    if sim.playerNearLandmark(sim.players[playerIndex], camp, CampShelterRadius):
      sim.grantCampRation(playerIndex)
  inc sim.scoreRevision

proc specializeCamp(sim: var SimServer, landmarkIndex: int, flag: int) =
  if landmarkIndex < 0 or landmarkIndex >= sim.landmarks.len:
    return
  if sim.landmarks[landmarkIndex].kind != LandmarkCamp or
      not sim.landmarks[landmarkIndex].done:
    return
  if (sim.landmarks[landmarkIndex].progress and flag) != 0:
    return
  sim.landmarks[landmarkIndex].progress =
    sim.landmarks[landmarkIndex].progress or flag
  inc sim.scoreRevision

proc trySpecializeCampForRole(
  sim: var SimServer,
  landmarkIndex: int,
  role: PlayerRole
) =
  case role
  of RoleTank:
    if not sim.landmarks[landmarkIndex].campIsWarded() and
        sim.stone >= CampWardStoneCost:
      sim.stone -= CampWardStoneCost
      sim.specializeCamp(landmarkIndex, CampWardedFlag)
  of RoleDps:
    if not sim.landmarks[landmarkIndex].campIsRally() and
        sim.wood >= CampRallyWoodCost:
      sim.wood -= CampRallyWoodCost
      sim.specializeCamp(landmarkIndex, CampRallyFlag)
  of RoleHealer:
    if not sim.landmarks[landmarkIndex].campIsAid() and
        sim.food >= CampAidFoodCost:
      sim.food -= CampAidFoodCost
      sim.specializeCamp(landmarkIndex, CampAidFlag)
  else:
    discard

proc campCanAcceptCarry(landmark: Landmark, item: CarryKind): bool =
  if landmark.kind != LandmarkCamp or not landmark.done:
    return false
  case item
  of CarryWood:
    not landmark.campIsRally()
  of CarryFood:
    not landmark.campIsProvisioned()
  of CarryStone:
    not landmark.campIsWarded()
  of CarryGold:
    not landmark.campIsFortified()
  of CarryNone:
    false

proc playerCanDeliverCarryToCamp*(
  sim: SimServer,
  playerIndex: int
): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let player = sim.players[playerIndex]
  if player.activeCarryItem() == CarryNone:
    return false
  for landmark in sim.landmarks:
    if sim.playerNearLandmark(
      player,
      landmark,
      LandmarkActivationRadius
    ):
      for item in CarryInventoryKinds:
        if player.carryCount(item) > 0 and landmark.campCanAcceptCarry(item):
          return true
  false

proc carryHudLabel*(sim: SimServer, playerIndex: int): string =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return "none"
  let player = sim.players[playerIndex]
  let activeItem = player.activeCarryItem()
  if activeItem == CarryNone:
    return "none"
  var item = activeItem
  let action =
    if player.hasCarry(CarryFood) and player.carriedFoodWouldHelp():
      item = CarryFood
      "sel eat"
    elif player.hasCarry(CarryFood) and sim.playerCanFeedCarriedFood(playerIndex):
      item = CarryFood
      "sel feed"
    elif sim.playerCanDeliverCarryToCamp(playerIndex):
      "sel camp"
    elif sim.playerCanLaySwampPlank(playerIndex):
      item = CarryWood
      "sel plank"
    elif sim.playerCanLayStoneSteps(playerIndex):
      item = CarryStone
      "sel steps"
    else:
      "sel drop"
  let count = player.carryCount(item)
  item.carryLabel() & (if count > 1: " x" & $count else: "") & " " & action

proc deliverCarryToCamp(sim: var SimServer, playerIndex: int): bool =
  ## Converts one held supply into an explicit activated-camp upgrade.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  sim.players[playerIndex].normalizeCarry()
  if sim.players[playerIndex].activeCarryItem() == CarryNone:
    return false
  for landmarkIndex in 0 ..< sim.landmarks.len:
    let landmark = sim.landmarks[landmarkIndex]
    if landmark.kind != LandmarkCamp or not landmark.done:
      continue
    if not sim.playerNearLandmark(
      sim.players[playerIndex],
      landmark,
      LandmarkActivationRadius
    ):
      continue
    var item = sim.players[playerIndex].activeCarryItem()
    if not sim.landmarks[landmarkIndex].campCanAcceptCarry(item):
      item = CarryNone
      for candidate in CarryInventoryKinds:
        if sim.players[playerIndex].carryCount(candidate) > 0 and
            sim.landmarks[landmarkIndex].campCanAcceptCarry(candidate):
          item = candidate
          break
    if item == CarryNone:
      continue
    case item
    of CarryWood:
      sim.specializeCamp(landmarkIndex, CampRallyFlag)
    of CarryFood:
      sim.provisionCamp(landmarkIndex)
    of CarryStone:
      sim.specializeCamp(landmarkIndex, CampWardedFlag)
    of CarryGold:
      sim.fortifyCamp(landmarkIndex)
    of CarryNone:
      continue
    discard sim.consumeCarryItem(playerIndex, item)
    return true
  false

proc campDefenseRadius(landmark: Landmark): int =
  if landmark.campIsWarded():
    CampWardedDefenseRadius
  else:
    CampFortificationRadius

proc campDefendsThreats(landmark: Landmark): bool =
  landmark.campIsFortified() or landmark.campIsWarded()

proc applyFortifiedCampDefenses(sim: var SimServer) =
  ## Keeps upgraded camps useful as safe staging points between pushes.
  for landmark in sim.landmarks:
    if not landmark.campDefendsThreats():
      continue
    let cleared = sim.pacifyMobsNearLandmark(
      landmark,
      landmark.campDefenseRadius()
    )
    if cleared > 0:
      inc sim.scoreRevision

proc harvestLandmark(
  sim: var SimServer,
  landmarkIndex,
  playerIndex: int
) =
  if landmarkIndex < 0 or landmarkIndex >= sim.landmarks.len:
    return
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.landmarks[landmarkIndex].done:
    return
  let kind = sim.landmarks[landmarkIndex].kind
  if not kind.landmarkIsResource():
    return
  let
    center = sim.landmarkCenter(sim.landmarks[landmarkIndex])
    pickupKind = kind.carryForLandmark().pickupForCarry()
    pickupSprite = sim.pickupSprite(pickupKind)
  sim.addResourceFromLandmark(kind)
  sim.giveOrDropHarvestCarry(
    kind,
    playerIndex,
    center.x - pickupSprite.width div 2,
    center.y - pickupSprite.height div 2
  )
  sim.landmarks[landmarkIndex].hp -=
    sim.players[playerIndex].role.roleAttackDamage()
  if sim.landmarks[landmarkIndex].hp <= 0:
    sim.landmarks[landmarkIndex].done = true
  inc sim.scoreRevision

proc attackLair(
  sim: var SimServer,
  landmarkIndex,
  playerIndex: int
) =
  if landmarkIndex < 0 or landmarkIndex >= sim.landmarks.len:
    return
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let damage = sim.players[playerIndex].role.roleAttackDamage()
  sim.landmarks[landmarkIndex].hp -= damage
  sim.players[playerIndex].damageDone += damage
  if sim.landmarks[landmarkIndex].hp <= 0:
    sim.destroyLair(landmarkIndex)
  else:
    inc sim.scoreRevision

proc applyLandmarkAttack(
  sim: var SimServer,
  playerIndex: int,
  hit: tuple[x, y, w, h: int]
) =
  for landmarkIndex in 0 ..< sim.landmarks.len:
    let landmark = sim.landmarks[landmarkIndex]
    if landmark.done:
      continue
    let hitLandmark = rectOverlapsBounds(
      hit.x,
      hit.y,
      hit.w,
      hit.h,
      landmark.landmarkWorldX(),
      landmark.landmarkWorldY(),
      sim.landmarkBounds(landmark.kind)
    )
    if not hitLandmark:
      continue
    if landmark.kind.landmarkIsResource():
      sim.harvestLandmark(landmarkIndex, playerIndex)
    elif landmark.kind == LandmarkLair:
      sim.attackLair(landmarkIndex, playerIndex)
    break

proc activateNearbyLandmarks(sim: var SimServer) =
  ## Completes standing objectives and activates forward camps.
  if sim.players.len == 0:
    return
  for landmarkIndex in 0 ..< sim.landmarks.len:
    if sim.landmarks[landmarkIndex].done:
      if sim.landmarks[landmarkIndex].kind == LandmarkCamp:
        var nearCamp = false
        for player in sim.players:
          if player.lives <= 0:
            continue
          if sim.playerNearLandmark(
            player,
            sim.landmarks[landmarkIndex],
            LandmarkActivationRadius
          ):
            nearCamp = true
            break
        if nearCamp:
          for player in sim.players:
            if player.lives <= 0:
              continue
            if sim.playerNearLandmark(
              player,
              sim.landmarks[landmarkIndex],
              LandmarkActivationRadius
            ):
              sim.trySpecializeCampForRole(landmarkIndex, player.role)
        if nearCamp and not sim.landmarks[landmarkIndex].campIsFortified() and
            sim.wood >= CampFortificationWoodCost and
            sim.stone >= CampFortificationStoneCost:
          sim.wood -= CampFortificationWoodCost
          sim.stone -= CampFortificationStoneCost
          sim.fortifyCamp(landmarkIndex)
        if nearCamp and not sim.landmarks[landmarkIndex].campIsProvisioned() and
            sim.food >= CampProvisionFoodCost:
          sim.food -= CampProvisionFoodCost
          sim.provisionCamp(landmarkIndex)
      continue
    let kind = sim.landmarks[landmarkIndex].kind
    if kind.landmarkIsResource():
      continue
    var nearPlayer = false
    var activationStep = 0
    var participantCount = 0
    var primaryParticipantIndex = -1
    for playerIndex, player in sim.players:
      if player.lives <= 0:
        continue
      let radius =
        if kind == LandmarkFinalGate:
          FinalGateActivationRadius
        else:
          LandmarkActivationRadius
      if sim.playerNearLandmark(player, sim.landmarks[landmarkIndex], radius):
        nearPlayer = true
        if primaryParticipantIndex < 0:
          primaryParticipantIndex = playerIndex
        let landmarkBiome = sim.tileBiomeKind(
          sim.landmarks[landmarkIndex].tx,
          sim.landmarks[landmarkIndex].ty
        )
        inc participantCount
        activationStep += objectiveHoldStep(kind, landmarkBiome, player.role)
    if not nearPlayer:
      continue
    activationStep = clamp(
      max(1, activationStep),
      1,
      CooperativeObjectiveHoldMaxStep
    )

    case kind
    of LandmarkCamp:
      if sim.wood < CampWoodCost or sim.stone < CampStoneCost:
        continue
      let segmentIndex = sim.landmarks[landmarkIndex].tx.adventureSegmentIndexForTileX()
      sim.wood -= CampWoodCost
      sim.stone -= CampStoneCost
      sim.landmarks[landmarkIndex].done = true
      inc sim.campsActivated
      let camp = sim.landmarks[landmarkIndex]
      sim.addCampRoleGear(camp)
      sim.revealCampShortcut(camp)
      for playerIndex in 0 ..< sim.players.len:
        if sim.players[playerIndex].lives <= 0:
          continue
        sim.players[playerIndex].lives = min(
          sim.players[playerIndex].maxHp,
          sim.players[playerIndex].lives + 2
        )
      inc sim.scoreRevision
      sim.tryGrantBiomeMasteryForSegment(segmentIndex)
    of LandmarkBeacon:
      let segmentIndex = sim.landmarks[landmarkIndex].tx.adventureSegmentIndexForTileX()
      sim.landmarks[landmarkIndex].progress += max(1, activationStep)
      inc sim.scoreRevision
      if sim.landmarks[landmarkIndex].progress < BeaconAttunementTicks:
        continue
      sim.landmarks[landmarkIndex].done = true
      inc sim.objectivesCompleted
      inc sim.relicShards
      sim.revealBeaconSurveyRoute(sim.landmarks[landmarkIndex])
      discard sim.pacifyMobsNearLandmark(
        sim.landmarks[landmarkIndex],
        BeaconSurveyRadius
      )
      for player in sim.players.mitems:
        if player.lives > 0:
          player.surveyTicks = max(player.surveyTicks, BeaconSurveyTicks)
      sim.grantObjectiveMorale(participantCount)
      inc sim.scoreRevision
      sim.tryGrantBiomeMasteryForSegment(segmentIndex)
    of LandmarkShrine:
      let segmentIndex = sim.landmarks[landmarkIndex].tx.adventureSegmentIndexForTileX()
      sim.landmarks[landmarkIndex].done = true
      sim.activateShrine()
      sim.tryGrantBiomeMasteryForSegment(segmentIndex)
    of LandmarkRescue:
      sim.landmarks[landmarkIndex].progress += max(1, activationStep)
      inc sim.scoreRevision
      if sim.landmarks[landmarkIndex].progress < RescueEventTicks:
        continue
      sim.landmarks[landmarkIndex].done = true
      sim.activateRescueEvent(
        sim.landmarks[landmarkIndex],
        primaryParticipantIndex
      )
      sim.grantObjectiveMorale(participantCount)
    of LandmarkWaystation:
      sim.landmarks[landmarkIndex].progress += max(1, activationStep)
      inc sim.scoreRevision
      if sim.landmarks[landmarkIndex].progress < BiomeWaystationTicks:
        continue
      sim.activateWaystation(landmarkIndex)
      sim.grantObjectiveMorale(participantCount)
    of LandmarkFinalGate:
      if not sim.bossDefeated:
        continue
      if sim.relicShards < FinalGateRelicCost:
        continue
      if sim.campsActivated < FinalGateCampCost:
        continue
      let startingGateHold = sim.landmarks[landmarkIndex].progress == 0
      sim.landmarks[landmarkIndex].progress +=
        sim.distinctRolesNearLandmark(
          sim.landmarks[landmarkIndex],
          FinalGateActivationRadius
        ).finalGateRitualStep()
      if startingGateHold:
        discard sim.pacifyMobsNearLandmark(
          sim.landmarks[landmarkIndex],
          FinalGateRallyPacifyRadius
        )
      inc sim.scoreRevision
      if sim.landmarks[landmarkIndex].progress < FinalGateRitualTicks:
        continue
      sim.landmarks[landmarkIndex].done = true
      inc sim.objectivesCompleted
      sim.grantFinalGateTriumph(sim.landmarks[landmarkIndex])
      inc sim.scoreRevision
    else:
      discard

proc applyAttack(sim: var SimServer) =
  if sim.players.len == 0:
    return

  var
    mobHitCounts = newSeq[int](sim.mobs.len)
    mobKnockbackXs = newSeq[int](sim.mobs.len)
    mobKnockbackYs = newSeq[int](sim.mobs.len)
  for playerIndex in 0 ..< sim.players.len:
    let attackReady =
      sim.players[playerIndex].attackTicks > 0 and
      not sim.players[playerIndex].attackResolved
    if not attackReady:
      continue

    let player = sim.players[playerIndex]
    let hit = sim.attackRect(player)
    var hitMob = false
    for mobIndex in 0 ..< sim.mobs.len:
      if rectOverlapsBounds(
        hit.x,
        hit.y,
        hit.w,
        hit.h,
        sim.mobs[mobIndex].x,
        sim.mobs[mobIndex].y,
        sim.mobs[mobIndex].bounds
      ):
        var dx = 0
        var dy = 0
        case player.facing
        of FaceUp: dy = -4
        of FaceDown: dy = 4
        of FaceLeft: dx = -4
        of FaceRight: dx = 4
        sim.mobs[mobIndex].pruneMobAttackers(sim.players, sim.tickCount)
        sim.mobs[mobIndex].rememberMobAttacker(player.id, sim.tickCount)
        sim.staggerBossFromFocus(mobIndex)
        let damage = sim.playerAttackDamage(player, sim.mobs[mobIndex]) +
          sim.mobs[mobIndex].partyFocusDamageBonus(sim.players, sim.tickCount) +
          sim.bossRaidDamageBonus(playerIndex, sim.mobs[mobIndex])
        mobHitCounts[mobIndex] += damage
        sim.players[playerIndex].damageDone += damage
        inc sim.scoreRevision
        mobKnockbackXs[mobIndex] += dx
        mobKnockbackYs[mobIndex] += dy
        hitMob = true
        break

    if not hitMob:
      sim.applyLandmarkAttack(playerIndex, hit)
    sim.players[playerIndex].attackResolved = true

  for mobIndex in 0 ..< sim.mobs.len:
    if mobHitCounts[mobIndex] == 0:
      continue

    sim.mobs[mobIndex].pruneMobAttackers(sim.players, sim.tickCount)
    sim.mobs[mobIndex].hp -= mobHitCounts[mobIndex]

    let
      knockbackX = mobKnockbackXs[mobIndex].clamp(-4, 4)
      knockbackY = mobKnockbackYs[mobIndex].clamp(-4, 4)
    if knockbackX != 0 or knockbackY != 0:
      var actor = Actor(
        x: sim.mobs[mobIndex].x,
        y: sim.mobs[mobIndex].y,
        sprite: sim.mobs[mobIndex].sprite,
        bounds: sim.mobs[mobIndex].bounds
      )
      sim.moveActor(actor, knockbackX, knockbackY)
      sim.mobs[mobIndex].x = actor.x
      sim.mobs[mobIndex].y = actor.y

  sim.finishDefeatedMobs()

proc equipArmor(sim: var SimServer, playerIndex: int, armor: ArmorKind): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len or armor == ArmorNone:
    return false
  let
    slot = armor.armorSlot()
    oldMax = max(1, sim.players[playerIndex].maxHp)
    oldHp = max(1, sim.players[playerIndex].lives)
  if sim.players[playerIndex].armor[slot] == armor:
    return false
  sim.players[playerIndex].armor[slot] = armor
  sim.players[playerIndex].maxHp =
    sim.players[playerIndex].role.roleMaxHp() +
      sim.players[playerIndex].equippedMaxHpBonus()
  sim.players[playerIndex].lives = min(
    sim.players[playerIndex].maxHp,
    max(1, (oldHp * sim.players[playerIndex].maxHp + oldMax - 1) div oldMax)
  )
  inc sim.scoreRevision
  true

proc collectPickups(sim: var SimServer, inputs: openArray[InputState]) =
  if sim.players.len == 0:
    return

  var remaining: seq[Pickup] = @[]
  for pickup in sim.pickups:
    let bounds = sim.pickupBounds(pickup.kind)
    var collected = false
    for playerIndex in 0 ..< sim.players.len:
      let player = sim.players[playerIndex]
      if player.lives <= 0:
        continue
      let input =
        if playerIndex < inputs.len: inputs[playerIndex]
        else: InputState()
      let
        pickupCenterX = boundsCenterX(pickup.x, bounds)
        pickupCenterY = boundsCenterY(pickup.y, bounds)
        playerCenterX = boundsCenterX(player.x, player.bounds)
        playerCenterY = boundsCenterY(player.y, player.bounds)
        overlapsPlayer = boundsOverlap(
          pickup.x,
          pickup.y,
          bounds,
          player.x,
          player.y,
          player.bounds
        )
        nearPlayer =
          (
            pickup.kind.isCarryPickup() or
              pickup.kind in {PickupCoin, PickupHeart, PickupArmor}
          ) and
            abs(pickupCenterX - playerCenterX) <= PickupCollectionRadius and
            abs(pickupCenterY - playerCenterY) <= PickupCollectionRadius
      if overlapsPlayer or nearPlayer:
        case pickup.kind
        of PickupCoin:
          let value = max(1, pickup.value)
          sim.players[playerIndex].coins += value
          inc sim.scoreRevision
        of PickupHeart:
          if sim.players[playerIndex].lives < sim.players[playerIndex].maxHp:
            inc sim.players[playerIndex].lives
          inc sim.scoreRevision
        of PickupTankGear, PickupDpsGear, PickupHealerGear:
          let nextRole = pickup.kind.roleForPickup()
          let canSwapRole =
            sim.players[playerIndex].role == RoleUnarmed or
              (
                pickup.x >= SafeZoneRightPixels and input.select and
                  player.carrySelectLockTicks == 0
              )
          if not canSwapRole or sim.players[playerIndex].role == nextRole:
            continue
          sim.players[playerIndex].applyRole(nextRole)
          inc sim.scoreRevision
        of PickupWood, PickupFood, PickupStone, PickupGold:
          if input.select:
            continue
          let item = pickup.kind.carryForPickup()
          if sim.giveCarry(playerIndex, item):
            collected = true
          else:
            collected = false
        of PickupArmor:
          collected = sim.equipArmor(
            playerIndex,
            pickup.value.armorFromPickupValue()
          )
        if not pickup.kind.isCarryPickup():
          collected = collected or
            (pickup.kind != PickupArmor and not pickup.kind.isRoleGear())
        break
    if collected:
      continue
    remaining.add(pickup)
  sim.pickups = remaining

proc playerBiome(sim: SimServer, player: Actor): BiomeKind =
  sim.biomeAtPixel(boundsCenterX(player.x, player.bounds))

proc playerGroundKind(sim: SimServer, player: Actor): GroundKind =
  sim.tileGroundKind(
    clamp(
      boundsCenterX(player.x, player.bounds) div WorldTileSize,
      0,
      WorldWidthTiles - 1
    ),
    clamp(
      boundsCenterY(player.y, player.bounds) div WorldTileSize,
      0,
      WorldHeightTiles - 1
    )
  )

proc playerNearDesertShade*(sim: SimServer, playerIndex: int): bool =
  ## Returns true near cactus shade in the desert survival band.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let player = sim.players[playerIndex]
  if player.lives <= 0 or sim.playerBiome(player) != BiomeDesert:
    return false
  let
    pcx = boundsCenterX(player.x, player.bounds)
    pcy = boundsCenterY(player.y, player.bounds)
  for prop in sim.terrainProps:
    if prop.kind != TerrainCactus or
        sim.tileBiomeKind(prop.tx, prop.ty) != BiomeDesert:
      continue
    let
      shadeX = prop.tx * WorldTileSize + WorldTileSize div 2
      shadeY = prop.ty * WorldTileSize + WorldTileSize div 2
    if distanceSquared(pcx, pcy, shadeX, shadeY) <=
        DesertShadeRadius * DesertShadeRadius:
      return true
  false

proc playerHasCaveLight*(sim: SimServer, playerIndex: int): bool =
  ## Returns true when held gold is acting as a cave/ruin light focus.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let player = sim.players[playerIndex]
  if player.lives <= 0 or
      sim.playerBiome(player) notin {BiomeCave, BiomeRuins}:
    return false
  player.hasCarry(CarryGold)

proc playerGuardMitigatesBiomePressure*(
  sim: SimServer,
  playerIndex: int
): bool =
  ## Returns true when tank guard is the active answer to a biome pressure.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  let player = sim.players[playerIndex]
  if player.lives <= 0 or sim.playerNearExpeditionShelter(playerIndex) or
      not sim.playerProtectedByTankGuard(playerIndex):
    return false
  case sim.playerBiome(player)
  of BiomeSwamp:
    sim.playerGroundKind(player) in {GroundMud, GroundShallowWater, GroundWater}
  of BiomeSnow:
    not sim.playerHasNearbyAlly(playerIndex, SnowWarmthAllyRadius)
  of BiomeDesert:
    not sim.playerNearDesertShade(playerIndex)
  of BiomeCave, BiomeRuins:
    not sim.playerHasNearbyAlly(playerIndex, IsolationThreatRadius) and
      not sim.playerHasCaveLight(playerIndex)
  else:
    false

proc survivalPressureKind*(
  sim: SimServer,
  playerIndex: int
): SurvivalPressureKind =
  ## Returns the active environmental pressure a player can currently feel.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return SurvivalSafe
  let player = sim.players[playerIndex]
  if player.lives <= 0 or player.routeTicks > 0 or player.triumphTicks > 0 or
      sim.playerNearExpeditionShelter(playerIndex) or
      sim.playerProtectedByTankGuard(playerIndex):
    return SurvivalSafe
  if sim.biomeIsMastered(sim.playerBiome(player)):
    return SurvivalSafe
  case sim.playerBiome(player)
  of BiomeSwamp:
    if sim.playerGroundKind(player) in {GroundMud, GroundShallowWater, GroundWater}:
      SurvivalMire
    else:
      SurvivalSafe
  of BiomeSnow:
    if sim.playerHasWeatherRation(playerIndex):
      return SurvivalSafe
    if player.hasArmorProtection(SurvivalCold):
      return SurvivalSafe
    if sim.playerHasNearbyAlly(playerIndex, SnowWarmthAllyRadius):
      SurvivalSafe
    else:
      SurvivalCold
  of BiomeDesert:
    if sim.playerHasWeatherRation(playerIndex):
      return SurvivalSafe
    if sim.playerNearDesertShade(playerIndex):
      SurvivalSafe
    else:
      SurvivalHeat
  of BiomeCave, BiomeRuins:
    if player.hasArmorProtection(SurvivalFog):
      return SurvivalSafe
    if sim.playerHasNearbyAlly(playerIndex, IsolationThreatRadius) or
        sim.playerHasCaveLight(playerIndex):
      SurvivalSafe
    else:
      SurvivalFog
  else:
    SurvivalSafe

proc survivalPressureLabel*(sim: SimServer, playerIndex: int): string =
  sim.survivalPressureKind(playerIndex).survivalPressureLabel()

proc playerBiomeTacticKind*(
  sim: SimServer,
  playerIndex: int
): BiomeTacticKind =
  ## Returns an active positive biome rule visible to the player.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return BiomeTacticNone
  if sim.players[playerIndex].lives <= 0:
    return BiomeTacticNone
  if sim.playerGuardMitigatesBiomePressure(playerIndex):
    return BiomeTacticGuard
  if sim.playerNearBlessedShrine(playerIndex):
    return BiomeTacticBlessing
  if sim.biomeIsMastered(sim.playerBiome(sim.players[playerIndex])):
    return BiomeTacticMastery
  case sim.playerBiome(sim.players[playerIndex])
  of BiomeForest:
    BiomeTacticForage
  of BiomePlains:
    if sim.playerHasNearbyAlly(playerIndex, PlainsRallyAllyRadius):
      BiomeTacticRally
    else:
      BiomeTacticNone
  of BiomeDesert:
    if sim.playerNearDesertShade(playerIndex):
      BiomeTacticShade
    else:
      BiomeTacticNone
  of BiomeSnow:
    if sim.playerHasNearbyAlly(playerIndex, SnowWarmthAllyRadius):
      BiomeTacticWarmth
    else:
      BiomeTacticNone
  of BiomeCave, BiomeRuins:
    if sim.playerHasCaveLight(playerIndex):
      BiomeTacticLight
    else:
      BiomeTacticNone
  else:
    BiomeTacticNone

proc playerBiomeTacticLabel*(sim: SimServer, playerIndex: int): string =
  sim.playerBiomeTacticKind(playerIndex).biomeTacticLabel()

proc addPlayerEffect(
  effects: var seq[PlayerEffectInfo],
  key,
  label,
  description: string,
  visual: PlayerEffectVisualKind,
  harmful = false
) =
  effects.add(PlayerEffectInfo(
    key: key,
    label: label,
    description: description,
    harmful: harmful,
    visual: visual
  ))

proc activePlayerEffects*(
  sim: SimServer,
  playerIndex: int
): seq[PlayerEffectInfo] =
  ## Returns every material buff, pressure, and debuff currently affecting a
  ## player, with player-facing text and a visual category for sprite clients.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]
  if player.lives <= 0:
    return

  case sim.survivalPressureKind(playerIndex)
  of SurvivalMire:
    result.addPlayerEffect(
      "mire",
      "MIRE",
      "mud slow",
      EffectVisualMire,
      harmful = true
    )
  of SurvivalCold:
    result.addPlayerEffect(
      "cold",
      "COLD",
      "food or hp",
      EffectVisualCold,
      harmful = true
    )
  of SurvivalHeat:
    result.addPlayerEffect(
      "heat",
      "HEAT",
      "food or hp",
      EffectVisualHeat,
      harmful = true
    )
  of SurvivalFog:
    result.addPlayerEffect(
      "fog",
      "FOG",
      "alone slows",
      EffectVisualFog,
      harmful = true
    )
  of SurvivalSafe:
    discard

  if player.poisonTicks > 0:
    result.addPlayerEffect(
      "poison",
      "POISON",
      "hp drain",
      EffectVisualPoison,
      harmful = true
    )
  if player.slowTicks > 0:
    result.addPlayerEffect(
      "slow",
      "SLOW",
      "move " & $StatusSlowSpeedPercent & "%",
      EffectVisualSlow,
      harmful = true
    )
  if player.chillTicks > 0:
    result.addPlayerEffect(
      "chill",
      "CHILL",
      "move " & $StatusChillSpeedPercent & "%",
      EffectVisualChill,
      harmful = true
    )
  if player.exhaustionTicks > 0:
    result.addPlayerEffect(
      "exhaustion",
      "TIRED",
      "move " & $StatusExhaustionSpeedPercent & "%",
      EffectVisualExhaustion,
      harmful = true
    )

  case sim.playerBiomeTacticKind(playerIndex)
  of BiomeTacticMastery:
    result.addPlayerEffect(
      "mastery",
      "MASTERY",
      "safe fast",
      EffectVisualMastery
    )
  of BiomeTacticForage:
    discard
  of BiomeTacticRally:
    result.addPlayerEffect(
      "rally",
      "RALLY",
      "cooldowns",
      EffectVisualRally
    )
  of BiomeTacticShade:
    result.addPlayerEffect("shade", "SHADE", "heat safe", EffectVisualShade)
  of BiomeTacticWarmth:
    result.addPlayerEffect("warmth", "WARM", "cold safe", EffectVisualWarmth)
  of BiomeTacticLight:
    result.addPlayerEffect("light", "LIGHT", "fog safe", EffectVisualLight)
  of BiomeTacticGuard:
    result.addPlayerEffect(
      "guard",
      "GUARD",
      "blocks hazard",
      EffectVisualGuard
    )
  of BiomeTacticBlessing:
    result.addPlayerEffect(
      "blessing",
      "BLESS",
      "cleanses",
      EffectVisualBlessing
    )
  of BiomeTacticNone:
    discard

  if sim.playerInTrioFormation(playerIndex):
    result.addPlayerEffect("trio", "TRIO", "cooldowns", EffectVisualTrio)
  if player.routeTicks > 0:
    result.addPlayerEffect("route", "ROUTE", "speed floor", EffectVisualRoute)
  if player.surveyTicks > 0:
    result.addPlayerEffect("survey", "SCOUT", "rough speed", EffectVisualSurvey)
  if player.guideTicks > 0:
    result.addPlayerEffect(
      "guide",
      "GUIDE",
      "speed cleanse",
      EffectVisualGuide
    )
  if player.huntTicks > 0:
    result.addPlayerEffect("hunt", "HUNT", "+1 dmg", EffectVisualHunt)
  if player.triumphTicks > 0:
    result.addPlayerEffect("triumph", "WIN", "invuln", EffectVisualTriumph)
  if player.rationTicks > 0:
    result.addPlayerEffect(
      "ration",
      "MEAL",
      "weather buffer",
      EffectVisualRation
    )
  if player.moraleTicks > 0:
    result.addPlayerEffect(
      "morale",
      "MORALE",
      "speed cooldown",
      EffectVisualMorale
    )

proc activePlayerEffectSummary*(
  sim: SimServer,
  playerIndex: int,
  maxEffects = 4
): string =
  ## Returns a compact one-line effect legend for the local HUD.
  let effects = sim.activePlayerEffects(playerIndex)
  if effects.len == 0:
    return "FX none"
  var pieces: seq[string] = @[]
  let visibleCount = min(maxEffects, effects.len)
  for i in 0 ..< visibleCount:
    pieces.add(effects[i].label & " " & effects[i].description)
  if effects.len > visibleCount:
    pieces.add("+" & $(effects.len - visibleCount))
  "FX " & pieces.join(" | ")

proc activePlayerEffectLines*(
  sim: SimServer,
  playerIndex: int
): seq[string] =
  ## Returns a full effect list for the top-right player HUD panel.
  result.add("EFFECTS")
  let effects = sim.activePlayerEffects(playerIndex)
  if effects.len == 0:
    result.add("none")
    return
  for effect in effects:
    result.add(effect.label & " " & effect.description)

proc groundDebugGlyph(kind: GroundKind): char =
  case kind
  of GroundGrass: '.'
  of GroundRoad: '='
  of GroundFertile: ','
  of GroundMud: 'm'
  of GroundShallowWater: '~'
  of GroundWater: 'W'
  of GroundSand: ':'
  of GroundDune: ';'
  of GroundSnow: '*'
  of GroundCave: '`'
  of GroundRuins: '\''
  of GroundBridge: '#'

proc terrainDebugGlyph(kind: TerrainKind): char =
  case kind
  of TerrainTree, TerrainEvergreen: 'T'
  of TerrainRock, TerrainStone: '^'
  of TerrainLog, TerrainStump: '='
  of TerrainBush: '"'
  of TerrainCactus: '!'
  of TerrainWheat: 'w'
  of TerrainFish: 'f'
  of TerrainGold: '$'
  of TerrainCave: 'O'
  of TerrainGoblinHut: 'g'
  of TerrainGoblinTotem: '|'
  of TerrainAltar: 'A'
  of TerrainCamp: 'C'

proc landmarkDebugGlyph(landmark: Landmark): char =
  case landmark.kind
  of LandmarkWood: 'w'
  of LandmarkFood: 'f'
  of LandmarkStone: 's'
  of LandmarkGold: '$'
  of LandmarkCamp: (if landmark.done: 'c' else: 'C')
  of LandmarkBeacon: (if landmark.done: 'b' else: 'B')
  of LandmarkFinalGate: (if landmark.done: 'g' else: 'G')
  of LandmarkShrine: (if landmark.done: 'h' else: 'H')
  of LandmarkRescue: (if landmark.done: 'r' else: 'R')
  of LandmarkLair: (if landmark.done: 'l' else: 'L')
  of LandmarkWaystation: (if landmark.done: 'y' else: 'Y')

proc pickupDebugGlyph(pickup: Pickup): char =
  case pickup.kind
  of PickupCoin: '$'
  of PickupHeart: '+'
  of PickupTankGear: 'T'
  of PickupDpsGear: 'D'
  of PickupHealerGear: 'H'
  of PickupWood: 'w'
  of PickupFood: 'f'
  of PickupStone: 's'
  of PickupGold: '$'
  of PickupArmor: 'a'

proc playerDebugGlyph(player: Actor, controlled: bool): char =
  if controlled:
    return '@'
  if player.lives <= 0:
    return 'x'
  case player.role
  of RoleTank: 'T'
  of RoleDps: 'D'
  of RoleHealer: 'H'
  else: 'P'

proc mobDebugGlyph(mob: Mob): char =
  if mob.kind == BossMob:
    return '!'
  case mob.attackPhase
  of MobTelegraph: '?'
  of MobLunge: '*'
  else: 'M'

proc actorCenterTile(x, y: int, bounds: SpriteBounds): tuple[tx, ty: int] =
  (
    tx: clamp(boundsCenterX(x, bounds) div WorldTileSize, 0, WorldWidthTiles - 1),
    ty: clamp(boundsCenterY(y, bounds) div WorldTileSize, 0, WorldHeightTiles - 1)
  )

proc putDebugGlyph(
  grid: var seq[string],
  tx, ty, startTx, startTy: int,
  glyph: char
) =
  let
    gx = tx - startTx
    gy = ty - startTy
  if gy >= 0 and gy < grid.len and gx >= 0 and gx < grid[gy].len:
    grid[gy][gx] = glyph

proc appendDebugEntityLine(
  text: var string,
  kind, label: string,
  glyph: char,
  tx, ty: int,
  extra = ""
) =
  text.add(kind)
  text.add(" glyph=")
  text.add(glyph)
  text.add(" tile=")
  text.add($tx)
  text.add(",")
  text.add($ty)
  text.add(" label=")
  text.add(label)
  if extra.len > 0:
    text.add(" ")
    text.add(extra)
  text.add("\n")

proc playerDebugAscii*(sim: SimServer, playerIndex: int): string =
  ## Returns a deterministic text render of the player-observation world state.
  let hasPlayer = playerIndex >= 0 and playerIndex < sim.players.len
  var
    centerTx = SafeZoneRightTiles div 2
    centerTy = WorldHeightTiles div 2
  if hasPlayer:
    let tile = actorCenterTile(
      sim.players[playerIndex].x,
      sim.players[playerIndex].y,
      sim.players[playerIndex].bounds
    )
    centerTx = tile.tx
    centerTy = tile.ty
  let
    width = PlayerViewportTiles
    height = PlayerViewportTiles
    startTx = clamp(centerTx - width div 2, 0, max(0, WorldWidthTiles - width))
    startTy = clamp(centerTy - height div 2, 0, max(0, WorldHeightTiles - height))

  if hasPlayer:
    let
      player = sim.players[playerIndex]
      biome = sim.tileBiomeKind(centerTx, centerTy)
      weather = biome.weatherForBiome()
    result.add("PLAYER id=" & $player.id & " name=" & player.address &
      " role=" & player.role.roleLabel() &
      " hp=" & $max(player.lives, 0) & "/" & $player.maxHp &
      " mana=" & $player.mana & "/" & $MaxPlayerMana &
      " ability=" & player.role.roleAbilityLabel() &
      " cost=" & $player.role.roleAbilityManaCost() &
      " cd=" & $player.abilityCooldown &
      " hold=" & $player.abilityHoldTicks &
      " biome=" & biome.biomeLabel() &
      " weather=" & weather.weatherLabel() &
      " effects=\"" & sim.activePlayerEffectSummary(playerIndex) & "\"\n")
  else:
    result.add("PLAYER none\n")
  result.add("PARTY frontier=" & $sim.frontierTiles() &
    " wood=" & $sim.wood &
    " food=" & $sim.food &
    " stone=" & $sim.stone &
    " relic=" & $sim.relicShards &
    " mobs=" & $sim.mobs.len &
    " pickups=" & $sim.pickups.len & "\n")
  result.add("VIEW tile=" & $startTx & "," & $startTy &
    " size=" & $width & "x" & $height &
    " legend=@self T/D/H ally M mob ! boss ? telegraph * lunge W water # bridge/block blank=occluded\n")

  var grid = newSeq[string](height)
  for gy in 0 ..< height:
    grid[gy] = newString(width)
    for gx in 0 ..< width:
      let
        tx = startTx + gx
        ty = startTy + gy
      if not inTileBounds(tx, ty):
        grid[gy][gx] = ' '
      elif hasPlayer and not sim.tileVisibleFrom(centerTx, centerTy, tx, ty):
        grid[gy][gx] = ' '
      else:
        var glyph = sim.tileGroundKind(tx, ty).groundDebugGlyph()
        if sim.tileElevation(tx, ty) >= ElevationCombatThreshold:
          glyph = '^'
        if sim.tiles.len > 0 and sim.tiles[tileIndex(tx, ty)]:
          glyph =
            if sim.terrainKinds.len > tileIndex(tx, ty):
              sim.terrainKinds[tileIndex(tx, ty)].terrainDebugGlyph()
            else:
              '#'
        grid[gy][gx] = glyph

  for landmark in sim.landmarks:
    if not inTileBounds(landmark.tx, landmark.ty):
      continue
    if hasPlayer and not sim.tileVisibleFrom(centerTx, centerTy, landmark.tx, landmark.ty):
      continue
    grid.putDebugGlyph(landmark.tx, landmark.ty, startTx, startTy, landmark.landmarkDebugGlyph())
  for pickup in sim.pickups:
    let
      tx = clamp((pickup.x + WorldTileSize div 2) div WorldTileSize, 0, WorldWidthTiles - 1)
      ty = clamp((pickup.y + WorldTileSize div 2) div WorldTileSize, 0, WorldHeightTiles - 1)
    if hasPlayer and not sim.tileVisibleFrom(centerTx, centerTy, tx, ty):
      continue
    grid.putDebugGlyph(tx, ty, startTx, startTy, pickup.pickupDebugGlyph())
  for guide in sim.guides:
    let
      tx = clamp((guide.x + WorldTileSize div 2) div WorldTileSize, 0, WorldWidthTiles - 1)
      ty = clamp((guide.y + WorldTileSize div 2) div WorldTileSize, 0, WorldHeightTiles - 1)
    if hasPlayer and not sim.tileVisibleFrom(centerTx, centerTy, tx, ty):
      continue
    grid.putDebugGlyph(tx, ty, startTx, startTy, 'r')
  for mob in sim.mobs:
    let tile = actorCenterTile(mob.x, mob.y, mob.bounds)
    if hasPlayer and not sim.tileVisibleFrom(centerTx, centerTy, tile.tx, tile.ty):
      continue
    grid.putDebugGlyph(tile.tx, tile.ty, startTx, startTy, mob.mobDebugGlyph())
  for i in 0 ..< sim.players.len:
    let tile = actorCenterTile(
      sim.players[i].x,
      sim.players[i].y,
      sim.players[i].bounds
    )
    if hasPlayer and not sim.tileVisibleFrom(centerTx, centerTy, tile.tx, tile.ty):
      continue
    grid.putDebugGlyph(
      tile.tx,
      tile.ty,
      startTx,
      startTy,
      sim.players[i].playerDebugGlyph(i == playerIndex)
    )

  result.add("ASCII\n")
  for row in grid:
    result.add(row)
    result.add("\n")
  result.add("ENTITIES\n")
  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      tile = actorCenterTile(player.x, player.y, player.bounds)
    result.appendDebugEntityLine(
      "player#" & $player.id,
      player.role.roleLabel(),
      player.playerDebugGlyph(i == playerIndex),
      tile.tx,
      tile.ty,
      "hp=" & $max(player.lives, 0) & "/" & $player.maxHp &
        " mana=" & $player.mana & "/" & $MaxPlayerMana &
        " cd=" & $player.abilityCooldown
    )
  for i in 0 ..< min(sim.mobs.len, 18):
    let
      mob = sim.mobs[i]
      tile = actorCenterTile(mob.x, mob.y, mob.bounds)
    result.appendDebugEntityLine(
      "mob#" & $i,
      mob.species.speciesLabel(),
      mob.mobDebugGlyph(),
      tile.tx,
      tile.ty,
      "hp=" & $mob.hp & " phase=" & $mob.attackPhase & " style=" & $mob.species.attackStyle()
    )
  for i in 0 ..< min(sim.pickups.len, 18):
    let
      pickup = sim.pickups[i]
      tx = clamp((pickup.x + WorldTileSize div 2) div WorldTileSize, 0, WorldWidthTiles - 1)
      ty = clamp((pickup.y + WorldTileSize div 2) div WorldTileSize, 0, WorldHeightTiles - 1)
    result.appendDebugEntityLine(
      "pickup#" & $i,
      $pickup.kind,
      pickup.pickupDebugGlyph(),
      tx,
      ty,
      "value=" & $pickup.value
    )
  for i in 0 ..< min(sim.landmarks.len, 18):
    let landmark = sim.landmarks[i]
    result.appendDebugEntityLine(
      "landmark#" & $i,
      landmark.kind.landmarkLabel(),
      landmark.landmarkDebugGlyph(),
      landmark.tx,
      landmark.ty,
      "done=" & $landmark.done & " progress=" & $landmark.progress
    )

proc debugAsciiSnapshot*(sim: SimServer): string =
  ## Returns the default readable snapshot for HTTP and agent debugging.
  if sim.players.len == 0:
    sim.playerDebugAscii(-1)
  else:
    sim.playerDebugAscii(0)

proc consumeWeatherRation(sim: var SimServer, playerIndex: int): bool =
  if sim.playerHasWeatherRation(playerIndex):
    return true
  if sim.food > 0:
    dec sim.food
    inc sim.scoreRevision
    return true
  if sim.players[playerIndex].hasCarry(CarryFood):
    discard sim.consumeCarryItem(playerIndex, CarryFood)
    return true
  false

proc playerInLateExhaustionBand(sim: SimServer, playerIndex: int): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  case sim.playerBiome(sim.players[playerIndex])
  of BiomeSnow, BiomeCave, BiomeRuins:
    true
  else:
    false

proc applyEarlyBiomeTactics(sim: var SimServer) =
  if sim.tickCount mod ForestForageIntervalTicks == 0 and
      sim.food < ForestForageFoodCap:
    for player in sim.players:
      if player.lives <= 0:
        continue
      if sim.playerBiome(player) == BiomeForest:
        inc sim.food
        inc sim.scoreRevision
        break

proc applyFoodAndWeatherSurvival(sim: var SimServer) =
  let
    mirePulse = sim.tickCount mod SwampMireIntervalTicks == 0
    coldPulse = sim.tickCount mod ColdExposureIntervalTicks == 0
    heatPulse = sim.tickCount mod HeatExposureIntervalTicks == 0
    fogPulse = sim.tickCount mod FogDisorientationIntervalTicks == 0
    exhaustionPulse = sim.tickCount mod ExhaustionIntervalTicks == 0
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].lives <= 0:
      continue
    if sim.players[playerIndex].triumphTicks > 0:
      continue
    let
      biome = sim.playerBiome(sim.players[playerIndex])
      sheltered = sim.playerNearExpeditionShelter(playerIndex)
      guarded = sim.playerProtectedByTankGuard(playerIndex)
      routed = sim.players[playerIndex].routeTicks > 0
      mastered = sim.biomeIsMastered(biome)
    if sim.food > 0 and
        sim.players[playerIndex].lives <=
          sim.players[playerIndex].maxHp - FoodHealAmount:
      let before = sim.players[playerIndex].lives
      sim.players[playerIndex].lives = min(
        sim.players[playerIndex].maxHp,
        sim.players[playerIndex].lives + FoodHealAmount
      )
      if sim.players[playerIndex].lives > before:
        dec sim.food
        inc sim.scoreRevision
    elif sim.players[playerIndex].lives <=
        sim.players[playerIndex].maxHp - FoodHealAmount:
      discard sim.consumeCarriedFood(playerIndex)

    if coldPulse and biome == BiomeSnow and not mastered and
        not sheltered and not guarded and
        not routed and
        not sim.playerHasNearbyAlly(playerIndex, SnowWarmthAllyRadius):
      if not sim.consumeWeatherRation(playerIndex):
        sim.damagePlayer(playerIndex, 0, 0, 1)
    if heatPulse and biome == BiomeDesert and not mastered and
        not sheltered and not guarded and
        not routed and not sim.playerNearDesertShade(playerIndex):
      if not sim.consumeWeatherRation(playerIndex):
        sim.damagePlayer(playerIndex, 0, 0, 1)
    if fogPulse and biome in {BiomeCave, BiomeRuins} and not mastered and
        not sheltered and not guarded and not routed and
        not sim.playerHasNearbyAlly(playerIndex, IsolationThreatRadius) and
        not sim.playerHasCaveLight(playerIndex):
      let before = sim.players[playerIndex].slowTicks
      sim.players[playerIndex].slowTicks = max(
        sim.players[playerIndex].slowTicks,
        FogDisorientationTicks
      )
      if sim.players[playerIndex].slowTicks != before:
        inc sim.scoreRevision
    if mirePulse and biome == BiomeSwamp and not mastered and
        not sheltered and not guarded and not routed and
        sim.playerGroundKind(sim.players[playerIndex]) in {
          GroundMud,
          GroundShallowWater,
          GroundWater
        }:
      let before = sim.players[playerIndex].slowTicks
      sim.players[playerIndex].slowTicks = max(
        sim.players[playerIndex].slowTicks,
        SwampMireTicks
      )
      if sim.players[playerIndex].slowTicks != before:
        inc sim.scoreRevision

    if exhaustionPulse and sim.playerInLateExhaustionBand(playerIndex) and
        not mastered and
        not sheltered and not guarded and not routed and
        sim.survivalPressureKind(playerIndex) == SurvivalSafe:
      if not sim.consumeWeatherRation(playerIndex):
        let before = sim.players[playerIndex].exhaustionTicks
        sim.players[playerIndex].exhaustionTicks = max(
          sim.players[playerIndex].exhaustionTicks,
          StatusExhaustionTicks
        )
        if sim.players[playerIndex].exhaustionTicks != before:
          inc sim.scoreRevision

proc reduceStatusTicks(value: var int, amount: int): bool =
  if value <= 0:
    return false
  value = max(0, value - max(1, amount))
  true

proc applyStatusEffects(sim: var SimServer) =
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].lives <= 0:
      continue
    if sim.players[playerIndex].triumphTicks > 0:
      continue
    let sheltered = sim.playerNearExpeditionShelter(playerIndex)
    let aidSheltered = sim.playerNearAidCamp(playerIndex)

    if sim.players[playerIndex].poisonTicks > 0 and
        sim.tickCount mod StatusPoisonIntervalTicks == 0:
      if sheltered:
        if reduceStatusTicks(
          sim.players[playerIndex].poisonTicks,
          CampStatusRecoveryTicks +
            (if aidSheltered: CampAidStatusRecoveryTicks else: 0)
        ):
          inc sim.scoreRevision
      elif sim.players[playerIndex].hasCarry(CarryFood):
        discard sim.consumeCarriedFood(playerIndex)
      elif sim.food > 0:
        dec sim.food
        sim.players[playerIndex].poisonTicks = 0
        inc sim.scoreRevision
      else:
        sim.damagePlayerFromStatus(playerIndex, 1)

    if playerIndex >= sim.players.len or sim.players[playerIndex].lives <= 0:
      continue
    let recoveryStep =
      1 + (if sheltered: CampStatusRecoveryTicks else: 0) +
        (if aidSheltered: CampAidStatusRecoveryTicks else: 0) +
        sim.players[playerIndex].equippedStatusRecoveryStep() +
        (if sim.players[playerIndex].guideTicks > 0:
          RescueGuideStatusRecoveryTicks
        else:
          0) +
        (if sim.biomeIsMastered(sim.playerBiome(sim.players[playerIndex])):
          BiomeMasteryStatusRecoveryTicks
        else:
          0)
    if sim.players[playerIndex].slowTicks > 0:
      if reduceStatusTicks(sim.players[playerIndex].slowTicks, recoveryStep):
        inc sim.scoreRevision
    if sim.players[playerIndex].chillTicks > 0:
      if reduceStatusTicks(sim.players[playerIndex].chillTicks, recoveryStep):
        inc sim.scoreRevision
    if sim.players[playerIndex].poisonTicks > 0:
      if reduceStatusTicks(sim.players[playerIndex].poisonTicks, recoveryStep):
        inc sim.scoreRevision
    if sim.players[playerIndex].exhaustionTicks > 0:
      if reduceStatusTicks(
        sim.players[playerIndex].exhaustionTicks,
        recoveryStep
      ):
        inc sim.scoreRevision

proc applyCampRecovery(sim: var SimServer) =
  if sim.tickCount mod CampRecoveryIntervalTicks != 0:
    return
  for playerIndex in 0 ..< sim.players.len:
    let
      nearCamp = sim.playerNearActivatedCamp(playerIndex)
      nearShrine = sim.playerNearBlessedShrine(playerIndex)
      nearProvisioned = nearCamp and sim.playerNearProvisionedCamp(playerIndex)
    if not nearCamp and not nearShrine:
      continue
    if nearProvisioned:
      sim.grantCampRation(playerIndex)
    if sim.players[playerIndex].lives >= sim.players[playerIndex].maxHp:
      continue
    let healAmount =
      if nearProvisioned:
        CampProvisionedRecoveryHealAmount
      else:
        CampRecoveryHealAmount
    sim.players[playerIndex].lives = min(
      sim.players[playerIndex].maxHp,
      sim.players[playerIndex].lives + healAmount
    )
    inc sim.scoreRevision

proc applyHealerTriage(sim: var SimServer) =
  if sim.tickCount mod HealerTriageIntervalTicks != 0:
    return
  for playerIndex in 0 ..< sim.players.len:
    if not sim.playerNeedsHelp(playerIndex):
      continue
    let healerIndex = sim.nearbyHealerIndex(playerIndex)
    if healerIndex < 0:
      continue
    let before = sim.players[playerIndex].lives
    sim.players[playerIndex].lives = min(
      sim.players[playerIndex].maxHp,
      sim.players[playerIndex].lives + HealerTriageHealAmount
    )
    let healed = sim.players[playerIndex].lives - before
    if healed > 0:
      sim.players[healerIndex].healingDone += healed
      inc sim.scoreRevision

proc applyDownedRecovery(sim: var SimServer) =
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].downedTicks <= 0:
      continue
    let rescuer = sim.nearbyDownedRescuer(playerIndex)
    if rescuer.index >= 0:
      sim.players[playerIndex].rescueTicks += rescuer.step
      inc sim.scoreRevision
      if sim.players[playerIndex].rescueTicks >= DownedRescueTicks:
        sim.reviveDownedPlayer(playerIndex, rescuer.index)
        continue
    elif sim.players[playerIndex].rescueTicks > 0:
      dec sim.players[playerIndex].rescueTicks
      inc sim.scoreRevision

    dec sim.players[playerIndex].downedTicks
    if sim.players[playerIndex].downedTicks <= 0:
      sim.respawnDownedPlayer(playerIndex)
    else:
      inc sim.scoreRevision

proc applyMobSupportPulse(sim: var SimServer, source: Mob) =
  ## Lets support monsters visibly restore or rally nearby allies.
  let
    sourceX = boundsCenterX(source.x, source.bounds)
    sourceY = boundsCenterY(source.y, source.bounds)
    radiusSq = (WorldTileSize * 3) * (WorldTileSize * 3)
  for ally in sim.mobs.mitems:
    if ally.hp <= 0 or ally.kind == BossMob:
      continue
    if distanceSquared(
      sourceX,
      sourceY,
      boundsCenterX(ally.x, ally.bounds),
      boundsCenterY(ally.y, ally.bounds)
    ) > radiusSq:
      continue
    let before = ally.hp
    ally.hp = min(ally.mobMaxHp(), ally.hp + 2)
    ally.attackCooldown = min(ally.attackCooldown, MobChaseCooldown)
    if ally.hp != before:
      inc sim.scoreRevision

proc updateMobs*(sim: var SimServer) =
  ## Updates mob chasing, telegraphed attacks, and wandering.
  if sim.players.len == 0:
    return

  for mob in sim.mobs.mitems:
    mob.refreshCoopState(sim.players, sim.tickCount)
    if mob.staggerTicks > 0:
      dec mob.staggerTicks
      mob.attackPhase = MobIdle
      mob.attackTicks = 0
      if mob.staggerTicks == 0:
        inc sim.scoreRevision
      continue
    dec mob.attackCooldown
    if mob.attackCooldown < 0:
      mob.attackCooldown = 0

    var
      targetPlayerIndex = 0
      bestDistance = high(int)
      hasTarget = false
    let
      centerX = boundsCenterX(mob.x, mob.bounds)
      centerY = boundsCenterY(mob.y, mob.bounds)
    for playerIndex in 0 ..< sim.players.len:
      let player = sim.players[playerIndex]
      if player.lives <= 0:
        continue
      let
        playerCenterX = boundsCenterX(player.x, player.bounds)
        playerCenterY = boundsCenterY(player.y, player.bounds)
      if playerCenterX <= SafeZoneRightPixels:
        continue
      let distance = distanceSquared(centerX, centerY, playerCenterX, playerCenterY)
      if distance < bestDistance:
        bestDistance = distance
        targetPlayerIndex = playerIndex
        hasTarget = true
    if not hasTarget:
      continue
    let player = sim.players[targetPlayerIndex]
    let
      playerCenterX = boundsCenterX(player.x, player.bounds)
      playerCenterY = boundsCenterY(player.y, player.bounds)
      attackRange = mob.mobAttackRange()
      sightRange = mob.mobSightRange()

    case mob.attackPhase
    of MobIdle:
      if mob.attackCooldown == 0 and
          bestDistance <= attackRange * attackRange:
        mob.attackFacing = chooseFacing(centerX, centerY, playerCenterX, playerCenterY)
        mob.attackPhase = MobTelegraph
        mob.attackTicks = 0
        continue

      dec mob.wanderCooldown
      if mob.wanderCooldown > 0:
        continue

      if bestDistance <= sightRange * sightRange:
        mob.attackFacing = chooseFacing(centerX, centerY, playerCenterX, playerCenterY)
        let step = chaseVector(centerX, centerY, playerCenterX, playerCenterY)
        mob.wanderCooldown = MobChaseCooldown
        sim.moveMob(mob, step.dx, step.dy)
        continue

      mob.wanderCooldown = MobWanderCooldown +
        sim.rng.rand(MobWanderJitter)
      let direction = sim.rng.rand(4)
      var dx = 0
      var dy = 0
      case direction
      of 0: dx = 1
      of 1: dx = -1
      of 2: dy = 1
      else: dy = -1
      sim.moveMob(mob, dx, dy)

    of MobTelegraph:
      inc mob.attackTicks
      if mob.attackTicks >= MobTelegraphTicks:
        mob.attackPhase = MobLunge
        mob.attackTicks = 0
      continue

    of MobLunge:
      let
        style = mob.species.attackStyle()
        lunge =
          if style == AttackLunge or style == AttackSwarm:
            lungeVector(mob.attackFacing, MobLungeStep)
          else:
            (dx: 0, dy: 0)
      if style == AttackLunge or style == AttackSwarm:
        sim.moveMob(mob, lunge.dx, lunge.dy)
      if style == AttackSupport and mob.attackTicks == 0:
        sim.applyMobSupportPulse(mob)
      if style in {AttackLunge, AttackSwarm} or mob.attackTicks == 0:
        let
          strikeCenterX = boundsCenterX(mob.x, mob.bounds)
          strikeCenterY = boundsCenterY(mob.y, mob.bounds)
          range = mob.mobAttackRange()
          radius =
            case style
            of AttackSlam:
              WorldTileSize + 10
            of AttackAura:
              WorldTileSize * 2
            of AttackSwarm:
              WorldTileSize + 12
            of AttackSupport:
              WorldTileSize
            else:
              range
        for playerIndex in 0 ..< sim.players.len:
          let player = sim.players[playerIndex]
          if player.lives <= 0 or player.invulnTicks != 0:
            continue
          let
            playerCenterX = boundsCenterX(player.x, player.bounds)
            playerCenterY = boundsCenterY(player.y, player.bounds)
            hit =
              case style
              of AttackLunge:
                boundsOverlap(
                  mob.x,
                  mob.y,
                  mob.bounds,
                  player.x,
                  player.y,
                  player.bounds
                )
              of AttackRanged:
                boundsOverlap(
                  mob.x,
                  mob.y,
                  mob.bounds,
                  player.x,
                  player.y,
                  player.bounds
                ) or
                  facingLaneHit(
                    strikeCenterX,
                    strikeCenterY,
                    playerCenterX,
                    playerCenterY,
                    mob.attackFacing,
                    range,
                    WorldTileSize div 2
                  )
              of AttackLine:
                facingLaneHit(
                  strikeCenterX,
                  strikeCenterY,
                  playerCenterX,
                  playerCenterY,
                  mob.attackFacing,
                  range,
                  WorldTileSize div 3
                )
              of AttackCone:
                facingLaneHit(
                  strikeCenterX,
                  strikeCenterY,
                  playerCenterX,
                  playerCenterY,
                  mob.attackFacing,
                  range,
                  WorldTileSize
                )
              of AttackTrap:
                facingLaneHit(
                  strikeCenterX,
                  strikeCenterY,
                  playerCenterX,
                  playerCenterY,
                  mob.attackFacing,
                  range,
                  WorldTileSize div 2
                ) or
                  distanceSquared(
                    strikeCenterX,
                    strikeCenterY,
                    playerCenterX,
                    playerCenterY
                  ) <= (WorldTileSize + 4) * (WorldTileSize + 4)
              of AttackSlam, AttackAura, AttackSupport, AttackSwarm:
                distanceSquared(
                  strikeCenterX,
                  strikeCenterY,
                  playerCenterX,
                  playerCenterY
                ) <= radius * radius
          if hit:
            let knockback =
              if style in {AttackAura, AttackSupport, AttackSwarm}:
                chaseVector(strikeCenterX, strikeCenterY, playerCenterX, playerCenterY)
              else:
                lungeVector(mob.attackFacing, max(1, MobLungeStep))
            sim.damagePlayer(
              playerIndex,
              knockback.dx,
              knockback.dy,
              sim.mobHitDamage(mob, playerIndex)
            )
            sim.applyMobHitStatus(mob, playerIndex)
      inc mob.attackTicks
      if mob.attackTicks >= MobLungeTicks:
        mob.attackPhase = MobIdle
        mob.attackTicks = 0
        mob.attackCooldown = sim.rng.nextMobAttackCooldown(mob.kind)
      continue

proc respawnMobs(sim: var SimServer) =
  if not sim.bossDefeated and not sim.hasBoss():
    discard sim.spawnOneMob(BossMob, sim.bossSprite, BossHp)

  if sim.snakeCount() >= TargetMobCount:
    sim.mobSpawnCooldown = 24
    return

  dec sim.mobSpawnCooldown
  if sim.mobSpawnCooldown > 0:
    return

  let biome = sim.currentBiome()
  let range = adventureSegmentRangeForTileX(sim.teamFrontier div WorldTileSize)
  discard sim.spawnOneMobInRange(
    sim.rng.randomMonsterSpeciesForBiome(biome),
    range.firstTx,
    range.lastTx
  )
  sim.mobSpawnCooldown =
    24 + sim.rng.rand(24) +
      lairRespawnCooldownBonus(sim.completedLairCountInBiome(biome))

proc fillTileBackground(
  fb: var Framebuffer,
  worldX,
  worldY,
  cameraX,
  cameraY: int,
  color: uint8
) =
  ## Fills a tile before drawing transparent borrowed terrain art.
  let
    screenX = worldX - cameraX
    screenY = worldY - cameraY
  for y in 0 ..< WorldTileSize:
    for x in 0 ..< WorldTileSize:
      fb.putPixel(screenX + x, screenY + y, color)

proc renderTerrain*(sim: var SimServer, cameraX, cameraY: int) =
  let
    startTx = max(0, cameraX div WorldTileSize)
    startTy = max(0, cameraY div WorldTileSize)
    endTx = min(
      WorldWidthTiles - 1,
      (cameraX + ScreenWidth - 1) div WorldTileSize
    )
    endTy = min(
      WorldHeightTiles - 1,
      (cameraY + ScreenHeight - 1) div WorldTileSize
    )

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        x = tx * WorldTileSize
        y = ty * WorldTileSize
        ground = sim.tileGroundKind(tx, ty)
        biome = sim.tileBiomeKind(tx, ty)
      sim.fb.fillTileBackground(
        x,
        y,
        cameraX,
        cameraY,
        biome.biomeBackgroundPaletteColor()
      )
      sim.fb.blitSprite(sim.groundSprite(ground), x, y, cameraX, cameraY)
      if sim.tiles[tileIndex(tx, ty)]:
        let sprite = sim.terrainSprites[sim.terrainKinds[tileIndex(tx, ty)]]
        sim.fb.blitSprite(sprite, x, y, cameraX, cameraY)

proc blitActorSprite(
  fb: var Framebuffer,
  sprite, mask: Sprite,
  worldX, worldY, cameraX, cameraY: int,
  tint: uint8,
  flipX = false
) =
  ## Draws one actor sprite while recoloring only its mask pixels.
  let
    screenX = worldX - cameraX
    screenY = worldY - cameraY
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let sourceX =
        if flipX:
          sprite.width - 1 - x
        else:
          x
      let colorIndex = sprite.pixels[sprite.spriteIndex(sourceX, y)]
      if colorIndex == TransparentColorIndex:
        continue
      let
        drawIndex =
          if sourceX < mask.width and y < mask.height and
              mask.pixels[mask.spriteIndex(sourceX, y)] !=
                  TransparentColorIndex:
            tint
          else:
            colorIndex
      fb.putPixel(screenX + x, screenY + y, drawIndex)

proc renderHud*(sim: var SimServer, playerIndex: int) =
  ## Draws the local player HUD with the Tiny5 font.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let
    player = sim.players[playerIndex]
    frontier = sim.frontierTiles()
    hp = max(player.lives, 0)
    lineY = sim.textFont.lineHeight()

  sim.fb.drawText(sim.textFont, "FRONT " & $frontier, 0, 0, 2'u8)
  sim.fb.drawText(sim.textFont, "HP " & $hp & "/" & $player.maxHp, 0, lineY, 2'u8)
  sim.fb.drawText(
    sim.textFont,
    player.role.roleLabel().toUpperAscii() & " AREA " &
      sim.currentBiome().biomeLabel().toUpperAscii(),
    0,
    lineY * 2,
    2'u8
  )
  let elevation = sim.tileElevation(
    clamp(boundsCenterX(player.x, player.bounds) div WorldTileSize, 0, WorldWidthTiles - 1),
    clamp(boundsCenterY(player.y, player.bounds) div WorldTileSize, 0, WorldHeightTiles - 1)
  )
  sim.fb.drawText(
    sim.textFont,
    "WX " & sim.currentWeather().weatherLabel().toUpperAscii() &
      " E" & $elevation,
    0,
    lineY * 3,
    2'u8
  )
  sim.fb.drawText(
    sim.textFont,
    "W" & $sim.wood & " F" & $sim.food & " S" & $sim.stone &
      " R" & $sim.relicShards & " " & sim.masteryHudLabel(),
    0,
    lineY * 4,
    2'u8
  )
  sim.fb.drawText(
    sim.textFont,
    (if player.role == RoleHealer and player.abilityHoldTicks > 0:
      "X HEAL HOLD " &
        $min(100, (player.abilityHoldTicks * 100) div HealerPulseHoldTicks) &
        "%"
    elif player.abilityCooldown > 0:
      "X " & player.role.roleAbilityLabel().toUpperAscii() & " CD " &
        $player.abilityCooldown
    elif player.role == RoleHealer:
      "X HOLD HEAL"
    else:
      "X " & player.role.roleAbilityLabel().toUpperAscii()),
    0,
    lineY * 5,
    2'u8
  )
  sim.fb.drawText(
    sim.textFont,
    "CARRY " & sim.carryHudLabel(playerIndex).toUpperAscii(),
    0,
    lineY * 6,
    2'u8
  )
  sim.fb.drawText(
    sim.textFont,
    "STATUS " & player.statusLabel().toUpperAscii() & " " &
      sim.survivalPressureLabel(playerIndex).toUpperAscii(),
    0,
    lineY * 7,
    2'u8
  )
  sim.fb.drawText(
    sim.textFont,
    sim.expeditionObjectiveHint(playerIndex),
    0,
    lineY * 8,
    2'u8
  )

proc renderHealthBar*(fb: var Framebuffer, screenX, screenY, width, current, maximum: int) =
  if maximum <= 0 or width <= 0:
    return
  let
    filled = max(0, min(width, (current * width + maximum - 1) div maximum))
    ratio = current * 100 div maximum
    barColor =
      if ratio > 50: HealthBarGreen
      elif ratio > 20: HealthBarYellow
      else: HealthBarRed
  for px in screenX ..< screenX + width:
    fb.putPixel(px, screenY, HealthBarGray)
  for px in screenX ..< screenX + filled:
    fb.putPixel(px, screenY, barColor)

proc playerColor*(playerIndex: int): uint8 =
  PlayerColors[playerIndex mod PlayerColors.len]

proc roleAbilityEffectColor(role: PlayerRole): uint8 =
  case role
  of RoleTank:
    HealthBarYellow
  of RoleDps:
    HealthBarRed
  of RoleHealer:
    HealthBarGreen
  of RoleUnarmed:
    2'u8

proc renderRoleAbilityEffect(
  fb: var Framebuffer,
  player: Actor,
  cameraX,
  cameraY: int
) =
  ## Draws the red/yellow/green role-power pulse in legacy framebuffer views.
  if player.lives <= 0 or player.abilityTicks <= 0:
    return
  let
    centerX = boundsCenterX(player.x, player.bounds) - cameraX
    centerY = boundsCenterY(player.y, player.bounds) - cameraY
    color = player.role.roleAbilityEffectColor()
    pulse = RoleAbilityEffectTicks - player.abilityTicks
    radius = 15 + (pulse div 3)
  for dy in -22 .. 22:
    for dx in -22 .. 22:
      let distance = dx * dx + dy * dy
      if distance >= (radius - 1) * (radius - 1) and
          distance <= (radius + 1) * (radius + 1):
        fb.putPixel(centerX + dx, centerY + dy, color)
  case player.role
  of RoleTank:
    for x in -13 .. 13:
      fb.putPixel(centerX + x, centerY - 14, color)
      fb.putPixel(centerX + x, centerY + 14, color)
    for y in -10 .. 10:
      fb.putPixel(centerX - 14, centerY + y, color)
      fb.putPixel(centerX + 14, centerY + y, color)
  of RoleDps:
    for offset in -16 .. 16:
      fb.putPixel(centerX + offset, centerY + offset, color)
      fb.putPixel(centerX + offset, centerY - offset, color)
  of RoleHealer:
    for offset in -17 .. 17:
      fb.putPixel(centerX + offset, centerY, color)
      fb.putPixel(centerX, centerY + offset, color)
  of RoleUnarmed:
    discard

proc renderCarryInventory(sim: var SimServer, playerIndex: int) =
  ## Draws held supplies as bottom inventory slots instead of over the actor.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]
  if player.lives <= 0 or player.activeCarryItem() == CarryNone:
    return
  var slot = 0
  for item in CarryInventoryKinds:
    let count = player.carryCount(item)
    if count <= 0:
      continue
    let
      carrySprite = sim.landmarkSprite(item.landmarkForCarry())
      slotX = 2 + slot * (WorldTileSize + 4)
      slotY = ScreenHeight - carrySprite.height - 2
    for y in slotY - 1 .. slotY + carrySprite.height:
      for x in slotX - 1 .. slotX + carrySprite.width:
        if x == slotX - 1 or x == slotX + carrySprite.width or
            y == slotY - 1 or y == slotY + carrySprite.height:
          sim.fb.putPixel(x, y, 2'u8)
    sim.fb.blitSprite(carrySprite, slotX, slotY, 0, 0)
    if count > 1:
      let
        countText = $count
        countX = min(
          ScreenWidth - sim.textFont.textWidth(countText),
          slotX + carrySprite.width - sim.textFont.textWidth(countText)
        )
        countY = max(0, slotY + carrySprite.height - sim.textFont.height)
      sim.fb.drawText(sim.textFont, countText, countX, countY, 8'u8)
    inc slot

proc renderRadar*(fb: var Framebuffer, sim: SimServer, playerIndex: int, cameraX, cameraY: int) =
  let
    player = sim.players[playerIndex]
    pcx = boundsCenterX(player.x, player.bounds)
    pcy = boundsCenterY(player.y, player.bounds)
    halfW = ScreenWidth div 2
    halfH = ScreenHeight div 2

  proc projectToEdge(dx, dy: int): tuple[x, y: int] =
    if dx == 0 and dy == 0:
      return (0, 0)
    let
      adx = abs(dx)
      ady = abs(dy)
    if adx * halfH > ady * halfW:
      let ex = if dx > 0: ScreenWidth - 1 else: 0
      let ey = halfH + dy * halfW div adx
      (ex, clamp(ey, 0, ScreenHeight - 1))
    else:
      let ey = if dy > 0: ScreenHeight - 1 else: 0
      let ex = halfW + dx * halfH div ady
      (clamp(ex, 0, ScreenWidth - 1), ey)

  for i, mob in sim.mobs:
    let
      mcx = boundsCenterX(mob.x, mob.bounds)
      mcy = boundsCenterY(mob.y, mob.bounds)
      dx = mcx - pcx
      dy = mcy - pcy
    if abs(dx) > RadarRange or abs(dy) > RadarRange:
      continue
    let sx = mcx - cameraX
    let sy = mcy - cameraY
    if sx >= 0 and sx < ScreenWidth and sy >= 0 and sy < ScreenHeight:
      continue
    let color = if mob.kind == BossMob: RadarColorBoss else: RadarColorSnake
    let pos = projectToEdge(dx, dy)
    fb.putPixel(pos.x, pos.y, color)

  for i in 0 ..< sim.players.len:
    if i == playerIndex or sim.players[i].lives <= 0:
      continue
    let
      other = sim.players[i]
      ocx = boundsCenterX(other.x, other.bounds)
      ocy = boundsCenterY(other.y, other.bounds)
      sx = ocx - cameraX
      sy = ocy - cameraY
    if sx >= 0 and sx < ScreenWidth and sy >= 0 and sy < ScreenHeight:
      continue
    let
      dx = ocx - pcx
      dy = ocy - pcy
      pos = projectToEdge(dx, dy)
    fb.putPixel(pos.x, pos.y, playerColor(i))

proc renderWeatherOverlay*(sim: var SimServer, weather: WeatherKind) =
  ## Draws a light deterministic weather layer for the local framebuffer path.
  case weather
  of WeatherRain:
    for i in 0 ..< 18:
      let
        x = (i * 17 + sim.tickCount * 2) mod ScreenWidth
        y = (i * 31 + sim.tickCount * 5) mod ScreenHeight
      sim.fb.putPixel(x, y, 11'u8)
      sim.fb.putPixel(x, y + 1, 11'u8)
  of WeatherSnow:
    for i in 0 ..< 16:
      let
        x = (i * 23 + sim.tickCount div 2) mod ScreenWidth
        y = (i * 19 + sim.tickCount) mod ScreenHeight
      sim.fb.putPixel(x, y, 15'u8)
  of WeatherDust:
    for i in 0 ..< 20:
      let
        x = (i * 29 + sim.tickCount * 3) mod ScreenWidth
        y = (i * 13 + sim.tickCount div 2) mod ScreenHeight
      sim.fb.putPixel(x, y, 9'u8)
  of WeatherFog:
    for y in countup(8, ScreenHeight - 1, 16):
      for x in countup((sim.tickCount + y) mod 12, ScreenWidth - 1, 24):
        sim.fb.putPixel(x, y, 12'u8)
  else:
    discard

proc render*(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(BackgroundColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return sim.fb.packed

  let player = sim.players[playerIndex]

  if player.lives <= 0:
    sim.fb.drawText(sim.textFont, "GAME", 20, 26, 2'u8)
    sim.fb.drawText(sim.textFont, "OVER", 20, 34, 2'u8)
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let
    cameraX = worldClampPixel(player.x + player.sprite.width div 2 - ScreenWidth div 2, WorldWidthPixels - ScreenWidth)
    cameraY = worldClampPixel(player.y + player.sprite.height div 2 - ScreenHeight div 2, WorldHeightPixels - ScreenHeight)

  sim.renderTerrain(cameraX, cameraY)
  for landmark in sim.landmarks:
    if landmark.done and landmark.kind.landmarkIsResource():
      continue
    sim.fb.blitSprite(
      sim.landmarkSprite(landmark.kind),
      landmark.landmarkWorldX(),
      landmark.landmarkWorldY(),
      cameraX,
      cameraY
    )
  for pickup in sim.pickups:
    case pickup.kind
    of PickupCoin, PickupTankGear, PickupDpsGear:
      sim.fb.blitSprite(sim.coinSprite, pickup.x, pickup.y, cameraX, cameraY)
    of PickupHeart, PickupHealerGear:
      sim.fb.blitSprite(sim.heartSprite, pickup.x, pickup.y, cameraX, cameraY)
    of PickupWood, PickupFood, PickupStone, PickupGold:
      sim.fb.blitSprite(
        sim.landmarkSprite(pickup.kind.carryForPickup().landmarkForCarry()),
        pickup.x,
        pickup.y,
        cameraX,
        cameraY
      )
    of PickupArmor:
      sim.fb.blitSprite(
        sim.armorSprites[pickup.value.armorFromPickupValue()],
        pickup.x,
        pickup.y,
        cameraX,
        cameraY
      )
  for mob in sim.mobs:
    sim.fb.blitSprite(mob.sprite, mob.x, mob.mobDrawY(), cameraX, cameraY)
  for i in 0 ..< sim.players.len:
    let otherPlayer = sim.players[i]
    if otherPlayer.lives > 0:
      sim.fb.blitActorSprite(
        sim.playerSpriteFor(otherPlayer),
        sim.playerMaskFor(otherPlayer),
        otherPlayer.x,
        otherPlayer.y,
        cameraX,
        cameraY,
        playerColor(i),
        otherPlayer.facing == FaceLeft
      )
      sim.fb.renderRoleAbilityEffect(otherPlayer, cameraX, cameraY)
  for otherPlayer in sim.players:
    if otherPlayer.lives > 0 and otherPlayer.attackTicks > 0:
      let hit = sim.attackRect(otherPlayer)
      sim.fb.blitSprite(
        sim.playerSwooshFor(otherPlayer),
        hit.x,
        hit.y,
        cameraX,
        cameraY,
        otherPlayer.facing
      )
  for mob in sim.mobs:
    let
      maxHp = mob.mobMaxHp()
      barW = mob.sprite.width
      barX = mob.x - cameraX
      barY = mob.mobDrawY() - cameraY - 2
    sim.fb.renderHealthBar(barX, barY, barW, mob.hp, maxHp)
  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    if p.lives > 0:
      let
        barW = p.sprite.width
        barX = p.x - cameraX
        barY = p.y - cameraY - 2
      sim.fb.renderHealthBar(barX, barY, barW, p.lives, p.maxHp)
  sim.fb.renderRadar(sim, playerIndex, cameraX, cameraY)
  sim.renderWeatherOverlay(sim.weatherAtPixel(player.x))
  sim.renderHud(playerIndex)
  sim.renderCarryInventory(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc addPlayerWalkDistances(
  sim: var SimServer,
  startXs,
  startYs: openArray[int]
) =
  ## Adds actual per-tick player movement to score totals.
  let count = min(sim.players.len, min(startXs.len, startYs.len))
  for i in 0 ..< count:
    if sim.players[i].lives <= 0:
      continue
    let distance =
      abs(sim.players[i].x - startXs[i]) +
      abs(sim.players[i].y - startYs[i])
    if distance <= 0:
      continue
    sim.players[i].distanceWalked += distance
    inc sim.scoreRevision

proc updatePlayerTimersAndFrontier(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if sim.players[i].mana < MaxPlayerMana and
        ManaRegenIntervalTicks > 0 and
        sim.tickCount mod ManaRegenIntervalTicks == 0:
      sim.players[i].mana = min(MaxPlayerMana, sim.players[i].mana + 1)
      inc sim.scoreRevision
    if sim.players[i].abilityCooldown > 0:
      dec sim.players[i].abilityCooldown
      if sim.players[i].abilityCooldown > 0 and sim.playerNearRallyCamp(i):
        sim.players[i].abilityCooldown = max(
          0,
          sim.players[i].abilityCooldown - CampRallyAbilityCooldownStep
        )
      if sim.players[i].abilityCooldown > 0 and
          sim.playerBiomeTacticKind(i) == BiomeTacticRally:
        sim.players[i].abilityCooldown = max(
          0,
          sim.players[i].abilityCooldown - PlainsRallyCooldownStep
        )
      if sim.players[i].abilityCooldown > 0 and sim.playerInTrioFormation(i):
        sim.players[i].abilityCooldown = max(
          0,
          sim.players[i].abilityCooldown - TrioFormationCooldownStep
        )
      if sim.players[i].abilityCooldown > 0 and sim.players[i].moraleTicks > 0:
        sim.players[i].abilityCooldown = max(
          0,
          sim.players[i].abilityCooldown - ObjectiveMoraleCooldownStep
        )
      if sim.players[i].abilityCooldown > 0 and
          sim.biomeIsMastered(sim.playerBiome(sim.players[i])):
        sim.players[i].abilityCooldown = max(
          0,
          sim.players[i].abilityCooldown - BiomeMasteryCooldownStep
        )
      if sim.players[i].abilityCooldown > 0:
        sim.players[i].abilityCooldown = max(
          0,
          sim.players[i].abilityCooldown -
            sim.players[i].equippedRoleCooldownStep()
        )
    if sim.players[i].guardTicks > 0:
      dec sim.players[i].guardTicks
    if sim.players[i].abilityTicks > 0:
      dec sim.players[i].abilityTicks
    if sim.players[i].routeTicks > 0:
      dec sim.players[i].routeTicks
      if sim.players[i].routeTicks == 0:
        inc sim.scoreRevision
    if sim.players[i].surveyTicks > 0:
      dec sim.players[i].surveyTicks
      if sim.players[i].surveyTicks == 0:
        inc sim.scoreRevision
    if sim.players[i].guideTicks > 0:
      dec sim.players[i].guideTicks
      if sim.players[i].guideTicks == 0:
        inc sim.scoreRevision
    if sim.players[i].huntTicks > 0:
      dec sim.players[i].huntTicks
      if sim.players[i].huntTicks == 0:
        inc sim.scoreRevision
    if sim.players[i].triumphTicks > 0:
      dec sim.players[i].triumphTicks
      if sim.players[i].triumphTicks == 0:
        inc sim.scoreRevision
    if sim.players[i].rationTicks > 0:
      dec sim.players[i].rationTicks
      if sim.players[i].rationTicks == 0:
        inc sim.scoreRevision
    if sim.players[i].moraleTicks > 0:
      dec sim.players[i].moraleTicks
      if sim.players[i].moraleTicks == 0:
        inc sim.scoreRevision
    if sim.players[i].pingTicks > 0:
      dec sim.players[i].pingTicks
      if sim.players[i].pingTicks == 0:
        sim.players[i].pingKind = PingNone
      inc sim.scoreRevision
    if sim.players[i].lives <= 0:
      continue
    let centerX = boundsCenterX(sim.players[i].x, sim.players[i].bounds)
    if centerX > sim.players[i].personalFrontier:
      sim.players[i].personalFrontier = centerX
      inc sim.scoreRevision
    if centerX > sim.teamFrontier:
      sim.teamFrontier = centerX
      sim.maxBiomeReached = max(
        sim.maxBiomeReached,
        sim.currentBiome().biomeProgressValue()
      )
      inc sim.scoreRevision

proc centerTileForActor(actor: Actor): tuple[tx, ty: int] =
  (
    tx: clamp(
      boundsCenterX(actor.x, actor.bounds) div WorldTileSize,
      0,
      WorldWidthTiles - 1
    ),
    ty: clamp(
      boundsCenterY(actor.y, actor.bounds) div WorldTileSize,
      0,
      WorldHeightTiles - 1
    )
  )

proc randomRiverAmbushSpecies(
  sim: var SimServer,
  biome: BiomeKind
): MobSpecies =
  let species = biome.monsterSpeciesForBiome()
  if species.len == 0:
    return SpeciesGrassSnake
  for _ in 0 ..< 8:
    let candidate = species[sim.rng.rand(species.high)]
    if candidate != SpeciesGateTitan:
      return candidate
  for candidate in species:
    if candidate != SpeciesGateTitan:
      return candidate
  SpeciesBoneGoblin

proc addRiverAmbushMobAt(
  sim: var SimServer,
  species: MobSpecies,
  tx,
  ty: int,
  target: Actor
): bool =
  if not inTileBounds(tx, ty) or sim.tileGroundKind(tx, ty) == GroundWater:
    return false
  let
    kind = species.speciesKind()
    bounds = sim.mobBoundsFor(species)
    px = tx * WorldTileSize + WorldTileSize div 2 - bounds.x - bounds.w div 2
    py = ty * WorldTileSize + WorldTileSize div 2 - bounds.y - bounds.h div 2
  if not sim.canSpawnMobAt(px, py, bounds):
    return false
  let
    targetCenterX = boundsCenterX(target.x, target.bounds)
    mobCenterX = boundsCenterX(px, bounds)
  sim.mobs.add Mob(
    kind: kind,
    species: species,
    x: px,
    y: py,
    sprite: sim.mobSpriteFor(species),
    bounds: bounds,
    wanderCooldown: 0,
    hp: mobMaxHp(kind, px),
    attackCooldown: sim.rng.nextMobAttackCooldown(kind),
    attackFacing: if targetCenterX < mobCenterX: FaceLeft else: FaceRight,
    attackerIds: @[target.id],
    attackerTicks: @[sim.tickCount]
  )
  true

proc spawnRiverCrossingAmbush(
  sim: var SimServer,
  crossingIndex,
  playerIndex: int
) =
  if crossingIndex < 0 or crossingIndex >= sim.riverCrossings.len or
      playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.riverCrossings[crossingIndex].triggered = true
  let
    crossing = sim.riverCrossings[crossingIndex]
    biome = sim.tileBiomeKind(crossing.tx, crossing.ty)
    target = sim.players[playerIndex]
    candidates = [
      (tx: crossing.tx - RiverAmbushBankOffsetTiles, ty: crossing.ty - 1),
      (tx: crossing.tx + RiverAmbushBankOffsetTiles, ty: crossing.ty + 1),
      (tx: crossing.tx - RiverAmbushBankOffsetTiles, ty: crossing.ty + 1),
      (tx: crossing.tx + RiverAmbushBankOffsetTiles, ty: crossing.ty - 1),
      (tx: crossing.tx - RiverAmbushBankOffsetTiles - 1, ty: crossing.ty),
      (tx: crossing.tx + RiverAmbushBankOffsetTiles + 1, ty: crossing.ty)
    ]
  var spawned = 0
  for candidate in candidates:
    if spawned >= RiverAmbushMobCount:
      break
    let species = sim.randomRiverAmbushSpecies(biome)
    if sim.addRiverAmbushMobAt(species, candidate.tx, candidate.ty, target):
      inc spawned
  if spawned == 0:
    let range = crossing.tx.adventureSegmentRangeForTileX()
    for _ in 0 ..< RiverAmbushMobCount:
      if sim.spawnOneMobInRange(
        sim.randomRiverAmbushSpecies(biome),
        range.firstTx,
        range.lastTx
      ):
        inc spawned
  inc sim.scoreRevision

proc triggerRiverCrossingAmbushes(sim: var SimServer) =
  if sim.riverCrossings.len == 0 or sim.players.len == 0:
    return
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].lives <= 0:
      continue
    let tile = centerTileForActor(sim.players[playerIndex])
    for crossingIndex in 0 ..< sim.riverCrossings.len:
      let crossing = sim.riverCrossings[crossingIndex]
      if crossing.triggered or tile.ty != crossing.ty:
        continue
      if abs(tile.tx - crossing.tx) <= RiverShallowHalfWidthTiles and
          sim.tileGroundKind(tile.tx, tile.ty) == GroundBridge:
        sim.spawnRiverCrossingAmbush(crossingIndex, playerIndex)
        break

proc step*(sim: var SimServer, inputs: openArray[InputState]) =
  inc sim.tickCount
  var
    startXs = newSeq[int](sim.players.len)
    startYs = newSeq[int](sim.players.len)
  for playerIndex in 0 ..< sim.players.len:
    startXs[playerIndex] = sim.players[playerIndex].x
    startYs[playerIndex] = sim.players[playerIndex].y
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].invulnTicks > 0:
      dec sim.players[playerIndex].invulnTicks
    if sim.players[playerIndex].carrySelectLockTicks > 0:
      dec sim.players[playerIndex].carrySelectLockTicks
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input)
  sim.resolvePlayerOverlaps()
  sim.addPlayerWalkDistances(startXs, startYs)
  sim.updatePlayerTimersAndFrontier()
  sim.updateGuides()
  sim.triggerRiverCrossingAmbushes()
  sim.collectPickups(inputs)
  sim.applyEarlyBiomeTactics()
  sim.applyFoodAndWeatherSurvival()
  sim.applyStatusEffects()
  sim.applyCampRecovery()
  sim.applyHealerTriage()
  sim.applyDownedRecovery()
  sim.applyAttack()
  sim.activateNearbyLandmarks()
  sim.applyFortifiedCampDefenses()
  sim.updateMobs()
  sim.resolvePlayerOverlaps()
  sim.respawnMobs()
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].attackTicks > 0:
      dec sim.players[playerIndex].attackTicks
      if sim.players[playerIndex].attackTicks == 0:
        sim.players[playerIndex].attackResolved = false

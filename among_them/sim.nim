import jsony, pixie
import protocol
import ../client/aseprite
import ../common/server
import std/[json, math, os, random, strutils]

const
  GameName* = "among_them"
  GameVersion* = "1"
  ReplayMagic* = "BITWORLD"
  ReplayFormatVersion* = 2'u16
  ReplayTickHashRecord* = 0x01'u8
  ReplayInputRecord* = 0x02'u8
  ReplayJoinRecord* = 0x03'u8
  ReplayLeaveRecord* = 0x04'u8
  ReplayFps* = 24
  MapWidth* = 952
  MapHeight* = 534
  SpriteSize* = 12
  CollisionW* = 1
  CollisionH* = 1
  SpriteDrawOffX* = 2
  SpriteDrawOffY* = 8
  MotionScale* = 256
  Accel* = 76
  FrictionNum* = 144
  FrictionDen* = 256
  MaxSpeed* = 704
  StopThreshold* = 8
  TargetFps* = 24
  SpaceColor* = 0'u8
  TintColor* = 3'u8
  ShadeTintColor* = 9'u8
  OutlineColor* = 0'u8
  KillRange* = 20
  KillCooldownTicks* = 1200
  TaskCompleteTicks* = 72
  TaskBarWidth* = 14
  VentRange* = 16
  TaskBarGap* = 1
  ProgressEmpty* = 1'u8
  ProgressFilled* = 10'u8
  ReportRange* = 20
  VoteResultTicks* = 72
  MinPlayers* = 5
  ImposterCount* = 1
  VoteTimerTicks* = 240
  GameOverTicks* = 360
  TasksPerPlayer* = 4
  ShowTaskArrows* = true
  ButtonCalls* = 1
  TaskReward* = 1
  KillReward* = 10
  WinReward* = 100
  ButtonX* = 524
  ButtonY* = 114
  ButtonW* = 28
  ButtonH* = 34
  MapSpriteId* = 1
  MapObjectId* = 1
  MapLayerId* = 0
  MapLayerType* = 0
  TopLeftLayerId* = 1
  TopLeftLayerType* = 1
  BottomRightLayerId* = 3
  BottomRightLayerType* = 3
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  PlayerSpriteBase* = 100
  GhostSpriteBase* = 300
  BodySpriteBase* = 500
  TaskSpriteId* = 700
  SelectedPlayerSpriteBase* = 800
  SelectedGhostSpriteBase* = 900
  SelectedTextSpriteId* = 4000
  SelectedViewportSpriteId* = 4001
  PlayerObjectBase* = 1000
  BodyObjectBase* = 2000
  TaskObjectBase* = 3000
  SelectedTextObjectId* = 4000
  SelectedViewportObjectId* = 4001
  PlayerColors* = [3'u8, 7, 8, 14, 4, 11, 13, 15]
  ShadowMap* = [
    0'u8,  #  0 black       -> black
    12,    #  1 gray         -> dark navy
    9,     #  2 white        -> dark teal
    5,     #  3 red          -> dark brown
    5,     #  4 pink         -> dark brown
    0,     #  5 dark brown   -> black
    5,     #  6 brown        -> dark brown
    5,     #  7 orange       -> dark brown
    5,     #  8 yellow       -> dark brown
    12,    #  9 dark teal    -> dark navy
    9,     # 10 green        -> dark teal
    9,     # 11 lime         -> dark teal
    0,     # 12 dark navy    -> black
    12,    # 13 blue         -> dark navy
    12,    # 14 light blue   -> dark navy
    9,     # 15 pale blue    -> dark teal
  ]
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"

type
  PlayerRole* = enum
    Crewmate
    Imposter

  AmongThemError* = object of ValueError

  GamePhase* = enum
    Lobby
    Playing
    Voting
    VoteResult
    GameOver

  VoteState* = object
    votes*: seq[int]
    cursor*: seq[int]
    resultTimer*: int
    voteTimer*: int
    ejectedPlayer*: int

  TaskStation* = object
    name*: string
    x*, y*, w*, h*: int
    completed*: seq[bool]

  Vent* = object
    x*, y*, w*, h*: int
    group*: char
    groupIndex*: int

  Body* = object
    x*, y*: int
    color*: uint8

  RewardAccount* = object
    address*: string
    reward*: int

  GameConfig* = object
    motionScale*: int
    accel*: int
    frictionNum*: int
    frictionDen*: int
    maxSpeed*: int
    stopThreshold*: int
    seed*: int
    killRange*: int
    killCooldownTicks*: int
    taskCompleteTicks*: int
    ventRange*: int
    reportRange*: int
    voteResultTicks*: int
    minPlayers*: int
    imposterCount*: int
    voteTimerTicks*: int
    gameOverTicks*: int
    tasksPerPlayer*: int
    showTaskArrows*: bool
    showTaskBubbles*: bool
    buttonCalls*: int

  Player* = object
    x*, y*: int
    velX*, velY*: int
    carryX*, carryY*: int
    flipH*: bool
    role*: PlayerRole
    alive*: bool
    killCooldown*: int
    joinOrder*: int
    address*: string
    color*: uint8
    taskProgress*: int
    activeTask*: int
    ventCooldown*: int
    buttonCallsUsed*: int
    assignedTasks*: seq[int]
    reward*: int

  SimServer* = object
    config*: GameConfig
    players*: seq[Player]
    rewardAccounts*: seq[RewardAccount]
    bodies*: seq[Body]
    playerSprite*: Sprite
    bodySprite*: Sprite
    boneSprite*: Sprite
    killButtonSprite*: Sprite
    taskIconSprite*: Sprite
    ghostSprite*: Sprite
    ghostIconSprite*: Sprite
    tasks*: seq[TaskStation]
    vents*: seq[Vent]
    mapPixels*: seq[uint8]
    walkMask*: seq[bool]
    wallMask*: seq[bool]
    fb*: Framebuffer
    shadowBuf*: seq[bool]
    rng*: Rand
    nextJoinOrder*: int
    tickCount*: int
    phase*: GamePhase
    voteState*: VoteState
    asciiSprites*: seq[Sprite]
    winner*: PlayerRole
    gameOverTimer*: int
    needsReregister*: bool

proc clientDataDir*(): string =
  ## Returns the shared client data directory.
  getCurrentDir() / ".." / "client" / "data"

proc skeld2AsepritePath(): string =
  ## Returns the best available skeld2 aseprite path.
  if fileExists("skeld2.aseprite"):
    "skeld2.aseprite"
  else:
    "/Users/me/p/among_them/skeld2.aseprite"

proc spriteSheetPath(): string =
  ## Returns the best available sprite sheet path.
  if fileExists("spritesheet.aseprite"):
    "spritesheet.aseprite"
  else:
    "spritesheet.png"

proc loadSpriteSheet*(): Image =
  ## Loads the sprite sheet from aseprite when available.
  let path = spriteSheetPath()
  if path.endsWith(".aseprite"):
    readAsepriteImage(path)
  else:
    readImage(path)

proc asepritePixelAt(
  aseprite: AsepriteSprite,
  cel: AsepriteCel,
  i: int
): ColorRGBA =
  ## Converts one decoded aseprite cel pixel to RGBA.
  case aseprite.header.colorDepth
  of DepthRgba:
    let base = i * 4
    rgba(
      cel.data[base],
      cel.data[base + 1],
      cel.data[base + 2],
      cel.data[base + 3]
    )
  of DepthGrayscale:
    let base = i * 2
    rgba(cel.data[base], cel.data[base], cel.data[base], cel.data[base + 1])
  of DepthIndexed:
    let index = cel.data[i].int
    if index == aseprite.header.transparentIndex:
      rgba(0, 0, 0, 0)
    elif index < aseprite.palette.len:
      aseprite.palette[index]
    else:
      rgba(0, 0, 0, 0)

proc asepriteLayerImage(
  aseprite: AsepriteSprite,
  layerIndex: int
): Image =
  ## Renders one normal aseprite layer from the first frame.
  if aseprite.frames.len == 0:
    raise newException(AmongThemError, "skeld2.aseprite has no frames.")
  if layerIndex < 0 or layerIndex >= aseprite.layers.len:
    raise newException(
      AmongThemError,
      "skeld2.aseprite is missing layer " & $(layerIndex + 1) & "."
    )
  result = newImage(aseprite.header.width, aseprite.header.height)
  result.fill(rgba(0, 0, 0, 0))
  for cel in aseprite.frames[0].cels:
    if cel.layerIndex != layerIndex:
      continue
    if cel.kind notin {CelRaw, CelCompressed}:
      continue
    for y in 0 ..< cel.height:
      let dstY = cel.y + y
      if dstY < 0 or dstY >= result.height:
        continue
      for x in 0 ..< cel.width:
        let dstX = cel.x + x
        if dstX < 0 or dstX >= result.width:
          continue
        let pixel = aseprite.asepritePixelAt(cel, y * cel.width + x)
        if pixel.a > 0:
          result[dstX, dstY] = pixel

proc loadSkeld2Layers*(): tuple[mapImage, walkImage, wallImage: Image] =
  ## Loads the skeld2 map, floor mask, and wall mask from aseprite layers.
  let
    path = skeld2AsepritePath()
    sprite = readAseprite(path)
  if sprite.header.width != MapWidth or sprite.header.height != MapHeight:
    raise newException(
      AmongThemError,
      "skeld2.aseprite dimensions must be " &
        $MapWidth & "x" & $MapHeight & "."
    )
  (
    mapImage: sprite.asepriteLayerImage(0),
    walkImage: sprite.asepriteLayerImage(1),
    wallImage: sprite.asepriteLayerImage(2)
  )

proc asciiIndex*(ch: char): int =
  ## Returns the ASCII sheet index for a character.
  ord(ch) - ord(' ')

proc loadAsciiSprites*(path: string): seq[Sprite] =
  ## Loads the fixed seven by nine ASCII glyph sheet.
  if not fileExists(path):
    raise newException(IOError, "Missing ASCII sprite sheet: " & path)
  let
    image = readImage(path)
    glyphWidth = 7
    glyphHeight = 9
    rowStride = 9
    cols = image.width div glyphWidth
    rows = image.height div rowStride
    background = nearestPaletteIndex(image[0, 0])
  result = @[]
  for row in 0 ..< rows:
    for col in 0 ..< cols:
      var sprite = Sprite(width: glyphWidth, height: glyphHeight)
      sprite.pixels = newSeq[uint8](glyphWidth * glyphHeight)
      let
        baseX = col * glyphWidth
        baseY = row * rowStride
      for y in 0 ..< glyphHeight:
        for x in 0 ..< glyphWidth:
          let colorIndex = nearestPaletteIndex(image[baseX + x, baseY + y])
          sprite.pixels[sprite.spriteIndex(x, y)] =
            if colorIndex == background:
              TransparentColorIndex
            else:
              colorIndex
      result.add(sprite)

proc blitAsciiText*(
  fb: var Framebuffer,
  asciiSprites: seq[Sprite],
  text: string,
  screenX, screenY: int
) =
  ## Draws text using the Among Them ASCII glyph sheet.
  var offsetX = 0
  for ch in text:
    let idx = asciiIndex(ch)
    if idx >= 0 and idx < asciiSprites.len:
      fb.blitSprite(asciiSprites[idx], screenX + offsetX, screenY, 0, 0)
    offsetX += 7

proc defaultGameConfig*(): GameConfig =
  ## Returns the default Among Them gameplay config.
  GameConfig(
    motionScale: MotionScale,
    accel: Accel,
    frictionNum: FrictionNum,
    frictionDen: FrictionDen,
    maxSpeed: MaxSpeed,
    stopThreshold: StopThreshold,
    seed: 0xA6019,
    killRange: KillRange,
    killCooldownTicks: KillCooldownTicks,
    taskCompleteTicks: TaskCompleteTicks,
    ventRange: VentRange,
    reportRange: ReportRange,
    voteResultTicks: VoteResultTicks,
    minPlayers: MinPlayers,
    imposterCount: ImposterCount,
    voteTimerTicks: VoteTimerTicks,
    gameOverTicks: GameOverTicks,
    tasksPerPlayer: TasksPerPlayer,
    showTaskArrows: ShowTaskArrows,
    showTaskBubbles: true,
    buttonCalls: ButtonCalls
  )

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  ## Reads one optional integer config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(AmongThemError, "Config field " & name & " must be an integer.")
  value = item.getInt()

proc readConfigBool(node: JsonNode, name: string, value: var bool) =
  ## Reads one optional boolean config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JBool:
    raise newException(AmongThemError, "Config field " & name & " must be a boolean.")
  value = item.getBool()

proc validate(config: GameConfig) =
  ## Raises if a gameplay config has invalid values.
  if config.motionScale <= 0:
    raise newException(AmongThemError, "Config field motionScale must be positive.")
  if config.frictionDen <= 0:
    raise newException(AmongThemError, "Config field frictionDen must be positive.")
  if config.minPlayers < 1:
    raise newException(AmongThemError, "Config field minPlayers must be at least 1.")
  if config.imposterCount < 0:
    raise newException(AmongThemError, "Config field imposterCount must be non-negative.")
  if config.tasksPerPlayer < 0:
    raise newException(AmongThemError, "Config field tasksPerPlayer must be non-negative.")
  if config.buttonCalls < 0:
    raise newException(AmongThemError, "Config field buttonCalls must be non-negative.")
  if config.voteTimerTicks <= 0:
    raise newException(AmongThemError, "Config field voteTimerTicks must be positive.")
  if config.killCooldownTicks < 0 or config.gameOverTicks < 0 or
      config.voteResultTicks < 0:
    raise newException(AmongThemError, "Timer config fields must not be negative.")

proc update*(config: var GameConfig, jsonText: string) =
  ## Updates a gameplay config from a JSON object.
  if jsonText.len == 0:
    return
  var node: JsonNode
  try:
    node = fromJson(jsonText)
  except jsony.JsonError as e:
    raise newException(AmongThemError, "Could not parse config JSON: " & e.msg)
  if node.kind != JObject:
    raise newException(AmongThemError, "Config must be a JSON object.")
  node.readConfigInt("motionScale", config.motionScale)
  node.readConfigInt("accel", config.accel)
  node.readConfigInt("frictionNum", config.frictionNum)
  node.readConfigInt("frictionDen", config.frictionDen)
  node.readConfigInt("maxSpeed", config.maxSpeed)
  node.readConfigInt("stopThreshold", config.stopThreshold)
  node.readConfigInt("seed", config.seed)
  node.readConfigInt("killRange", config.killRange)
  node.readConfigInt("killCooldownTicks", config.killCooldownTicks)
  node.readConfigInt("imposterCooldownTicks", config.killCooldownTicks)
  node.readConfigInt("taskCompleteTicks", config.taskCompleteTicks)
  node.readConfigInt("ventRange", config.ventRange)
  node.readConfigInt("reportRange", config.reportRange)
  node.readConfigInt("voteResultTicks", config.voteResultTicks)
  node.readConfigInt("minPlayers", config.minPlayers)
  node.readConfigInt("imposterCount", config.imposterCount)
  node.readConfigInt("voteTimerTicks", config.voteTimerTicks)
  node.readConfigInt("gameOverTicks", config.gameOverTicks)
  node.readConfigInt("tasksPerPlayer", config.tasksPerPlayer)
  node.readConfigInt("buttonCalls", config.buttonCalls)
  node.readConfigInt("numberOfButtonCalls", config.buttonCalls)
  node.readConfigBool("showTaskArrows", config.showTaskArrows)
  node.readConfigBool("showTaskBubbles", config.showTaskBubbles)
  config.validate()

proc configJson*(config: GameConfig): string =
  ## Returns the complete replay JSON for a gameplay config.
  let node = %*{
    "motionScale": config.motionScale,
    "accel": config.accel,
    "frictionNum": config.frictionNum,
    "frictionDen": config.frictionDen,
    "maxSpeed": config.maxSpeed,
    "stopThreshold": config.stopThreshold,
    "seed": config.seed,
    "killRange": config.killRange,
    "killCooldownTicks": config.killCooldownTicks,
    "imposterCooldownTicks": config.killCooldownTicks,
    "taskCompleteTicks": config.taskCompleteTicks,
    "ventRange": config.ventRange,
    "reportRange": config.reportRange,
    "voteResultTicks": config.voteResultTicks,
    "minPlayers": config.minPlayers,
    "imposterCount": config.imposterCount,
    "voteTimerTicks": config.voteTimerTicks,
    "gameOverTicks": config.gameOverTicks,
    "tasksPerPlayer": config.tasksPerPlayer,
    "buttonCalls": config.buttonCalls,
    "showTaskArrows": config.showTaskArrows,
    "showTaskBubbles": config.showTaskBubbles
  }
  $node

proc mapIndex*(x, y: int): int =
  y * MapWidth + x

proc mixHash(hash: var uint64, value: uint64) =
  ## Mixes one integer into a deterministic FNV-1a hash.
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashInt(hash: var uint64, value: int) =
  ## Mixes one signed integer into a deterministic hash.
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashBool(hash: var uint64, value: bool) =
  ## Mixes one boolean into a deterministic hash.
  hash.mixHashInt(ord(value))

proc gameHash*(sim: SimServer): uint64 =
  ## Returns a deterministic hash of gameplay state.
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(ord(sim.phase))
  result.mixHashInt(ord(sim.winner))
  result.mixHashInt(sim.gameOverTimer)
  result.mixHashBool(sim.needsReregister)
  result.mixHashInt(sim.nextJoinOrder)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashInt(player.x)
    result.mixHashInt(player.y)
    result.mixHashInt(player.velX)
    result.mixHashInt(player.velY)
    result.mixHashInt(player.carryX)
    result.mixHashInt(player.carryY)
    result.mixHashBool(player.flipH)
    result.mixHashInt(ord(player.role))
    result.mixHashBool(player.alive)
    result.mixHashInt(player.killCooldown)
    result.mixHashInt(player.joinOrder)
    result.mixHashInt(int(player.color))
    result.mixHashInt(player.taskProgress)
    result.mixHashInt(player.activeTask)
    result.mixHashInt(player.ventCooldown)
    result.mixHashInt(player.buttonCallsUsed)
    result.mixHashInt(player.reward)
    result.mixHashInt(player.assignedTasks.len)
    for task in player.assignedTasks:
      result.mixHashInt(task)
  result.mixHashInt(sim.bodies.len)
  for body in sim.bodies:
    result.mixHashInt(body.x)
    result.mixHashInt(body.y)
    result.mixHashInt(int(body.color))
  result.mixHashInt(sim.tasks.len)
  for task in sim.tasks:
    result.mixHashInt(task.completed.len)
    for done in task.completed:
      result.mixHashBool(done)
  result.mixHashInt(sim.voteState.votes.len)
  for vote in sim.voteState.votes:
    result.mixHashInt(vote)
  result.mixHashInt(sim.voteState.cursor.len)
  for cursor in sim.voteState.cursor:
    result.mixHashInt(cursor)
  result.mixHashInt(sim.voteState.resultTimer)
  result.mixHashInt(sim.voteState.voteTimer)
  result.mixHashInt(sim.voteState.ejectedPlayer)

proc isWalkable*(sim: SimServer, x, y: int): bool =
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return false
  sim.walkMask[mapIndex(x, y)]

proc canOccupy*(sim: SimServer, x, y: int): bool =
  for dy in 0 ..< CollisionH:
    for dx in 0 ..< CollisionW:
      if not sim.isWalkable(x + dx, y + dy):
        return false
  true

proc findSpawn*(sim: SimServer): tuple[x, y: int] =
  let
    buttonX = 536
    buttonY = 120
    spawnRadius = 28
    n = max(1, sim.players.len + 1)
    angle = float(sim.players.len) * 2.0 * 3.14159265 / float(n)
    px = buttonX + int(float(spawnRadius) * cos(angle))
    py = buttonY + int(float(spawnRadius) * sin(angle))
  if sim.canOccupy(px, py):
    return (px, py)
  (buttonX, buttonY)

proc rewardAccountIndex(sim: SimServer, address: string): int =
  ## Returns the reward account index for an address.
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc addPlayer*(sim: var SimServer, address: string): int =
  let
    spawn = sim.findSpawn()
    order = sim.nextJoinOrder
    rewardAccount = sim.rewardAccountIndex(address)
  inc sim.nextJoinOrder
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    role: Crewmate,
    alive: true,
    killCooldown: sim.config.killCooldownTicks,
    joinOrder: order,
    address: address,
    color: PlayerColors[order mod PlayerColors.len],
    activeTask: -1,
    reward:
      if rewardAccount >= 0: sim.rewardAccounts[rewardAccount].reward
      else: 0
  )
  for task in sim.tasks.mitems:
    task.completed.add(false)
  sim.players.high

proc hasTask*(player: Player, taskIdx: int): bool =
  for t in player.assignedTasks:
    if t == taskIdx:
      return true
  false

proc addReward*(sim: var SimServer, playerIndex, amount: int) =
  ## Adds accumulated reward to a player and its address account.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let address = sim.players[playerIndex].address
  var index = sim.rewardAccountIndex(address)
  if index < 0:
    sim.rewardAccounts.add RewardAccount(address: address, reward: 0)
    index = sim.rewardAccounts.high
  sim.rewardAccounts[index].reward += amount
  sim.players[playerIndex].reward = sim.rewardAccounts[index].reward

proc completeTask*(sim: var SimServer, playerIndex, taskIndex: int) =
  ## Marks one player task complete and awards task reward.
  if taskIndex < 0 or taskIndex >= sim.tasks.len:
    return
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if playerIndex >= sim.tasks[taskIndex].completed.len:
    return
  if playerIndex < sim.tasks[taskIndex].completed.len and
      sim.tasks[taskIndex].completed[playerIndex]:
    return
  sim.tasks[taskIndex].completed[playerIndex] = true
  sim.addReward(playerIndex, TaskReward)

proc startGame*(sim: var SimServer) =
  let imposterCount = min(
    sim.config.imposterCount,
    max(0, sim.players.len - 1)
  )
  for player in sim.players.mitems:
    player.role = Crewmate
    player.assignedTasks = @[]
  var candidates: seq[int] = @[]
  for i in 0 ..< sim.players.len:
    candidates.add(i)
  for j in countdown(candidates.high, 1):
    let k = sim.rng.rand(j)
    swap(candidates[j], candidates[k])
  for i in 0 ..< imposterCount:
    sim.players[candidates[i]].role = Imposter
  for i in 0 ..< sim.players.len:
    if sim.players[i].role == Imposter:
      continue
    var indices: seq[int] = @[]
    for t in 0 ..< sim.tasks.len:
      indices.add(t)
    for j in countdown(indices.high, 1):
      let k = sim.rng.rand(j)
      swap(indices[j], indices[k])
    sim.players[i].assignedTasks =
      indices[0 ..< min(sim.config.tasksPerPlayer, indices.len)]
  sim.phase = Playing

proc applyMomentumAxis(
  sim: SimServer,
  player: var Player,
  carry: var int,
  velocity: int,
  horizontal: bool
) =
  carry += velocity
  while abs(carry) >= sim.config.motionScale:
    let step = if carry < 0: -1 else: 1
    let
      nx = if horizontal: player.x + step else: player.x
      ny = if horizontal: player.y else: player.y + step
    if sim.canOccupy(nx, ny):
      if horizontal:
        player.x = nx
      else:
        player.y = ny
      carry -= step * sim.config.motionScale
    else:
      var slid = false
      if horizontal:
        for slideY in [player.y - 1, player.y + 1]:
          if sim.canOccupy(nx, slideY):
            player.x = nx
            player.y = slideY
            carry -= step * sim.config.motionScale
            slid = true
            break
      else:
        for slideX in [player.x - 1, player.x + 1]:
          if sim.canOccupy(slideX, ny):
            player.x = slideX
            player.y = ny
            carry -= step * sim.config.motionScale
            slid = true
            break
      if not slid:
        carry = 0
        break

proc distSq*(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc actorColor*(colorIndex, tint: uint8): uint8 =
  ## Returns the final color for actor wildcard pixels.
  if colorIndex == TintColor:
    return tint
  if colorIndex == ShadeTintColor:
    return ShadowMap[tint and 0x0f]
  colorIndex

proc tryKill*(sim: var SimServer, killerIndex: int) =
  let killer = sim.players[killerIndex]
  if killer.role != Imposter or not killer.alive:
    return
  if killer.killCooldown > 0:
    return
  let
    kx = killer.x + CollisionW div 2
    ky = killer.y + CollisionH div 2
    rangeSq = sim.config.killRange * sim.config.killRange
  var
    bestDist = high(int)
    bestTarget = -1
  for i in 0 ..< sim.players.len:
    if i == killerIndex or not sim.players[i].alive:
      continue
    if sim.players[i].role == Imposter:
      continue
    let
      tx = sim.players[i].x + CollisionW div 2
      ty = sim.players[i].y + CollisionH div 2
      d = distSq(kx, ky, tx, ty)
    if d <= rangeSq and d < bestDist:
      bestDist = d
      bestTarget = i
  if bestTarget >= 0:
    sim.players[bestTarget].alive = false
    sim.bodies.add Body(
      x: sim.players[bestTarget].x,
      y: sim.players[bestTarget].y,
      color: sim.players[bestTarget].color
    )
    sim.addReward(killerIndex, KillReward)
    sim.players[killerIndex].killCooldown = sim.config.killCooldownTicks

proc tryVent*(sim: var SimServer, playerIndex: int) =
  ## Teleport an imposter to the next vent in the same group.
  let p = sim.players[playerIndex]
  if p.role != Imposter or not p.alive:
    return
  if p.ventCooldown > 0:
    return
  let
    px = p.x + CollisionW div 2
    py = p.y + CollisionH div 2
    rangeSq = sim.config.ventRange * sim.config.ventRange
  for i in 0 ..< sim.vents.len:
    let v = sim.vents[i]
    let
      vx = v.x + v.w div 2
      vy = v.y + v.h div 2
    if distSq(px, py, vx, vy) <= rangeSq:
      var nextIdx = -1
      for j in 0 ..< sim.vents.len:
        if j == i:
          continue
        if sim.vents[j].group == v.group:
          if sim.vents[j].groupIndex == v.groupIndex + 1:
            nextIdx = j
            break
      if nextIdx < 0:
        for j in 0 ..< sim.vents.len:
          if sim.vents[j].group == v.group and
              sim.vents[j].groupIndex == 1:
            nextIdx = j
            break
      if nextIdx >= 0:
        let dest = sim.vents[nextIdx]
        sim.players[playerIndex].x =
          dest.x + dest.w div 2 - CollisionW div 2
        sim.players[playerIndex].y =
          dest.y + dest.h div 2 - CollisionH div 2
        sim.players[playerIndex].velX = 0
        sim.players[playerIndex].velY = 0
        sim.players[playerIndex].carryX = 0
        sim.players[playerIndex].carryY = 0
        sim.players[playerIndex].ventCooldown = 30
      return

proc startVote*(sim: var SimServer) =
  sim.phase = Voting
  let n = sim.players.len
  sim.voteState.votes = newSeq[int](n)
  sim.voteState.cursor = newSeq[int](n)
  sim.voteState.voteTimer = sim.config.voteTimerTicks
  for i in 0 ..< n:
    sim.voteState.votes[i] = -1
    var firstAlive = 0
    for j in 0 ..< n:
      if sim.players[j].alive:
        firstAlive = j
        break
    sim.voteState.cursor[i] = firstAlive

proc tryReport*(sim: var SimServer, reporterIndex: int, bodyLimit: int) =
  if sim.phase != Playing:
    return
  let p = sim.players[reporterIndex]
  if not p.alive:
    return
  let
    px = p.x + CollisionW div 2
    py = p.y + CollisionH div 2
    rangeSq = sim.config.reportRange * sim.config.reportRange
  for bi in 0 ..< bodyLimit:
    let body = sim.bodies[bi]
    let
      bx = body.x + CollisionW div 2
      by = body.y + CollisionH div 2
    if distSq(px, py, bx, by) <= rangeSq:
      sim.startVote()
      return

proc tryCallButton*(sim: var SimServer, callerIndex: int) =
  if sim.phase != Playing:
    return
  let p = sim.players[callerIndex]
  if not p.alive:
    return
  if p.buttonCallsUsed >= sim.config.buttonCalls:
    return
  let
    px = p.x + CollisionW div 2
    py = p.y + CollisionH div 2
  if px >= ButtonX and px < ButtonX + ButtonW and
      py >= ButtonY and py < ButtonY + ButtonH:
    inc sim.players[callerIndex].buttonCallsUsed
    sim.startVote()

proc containGhost(player: var Player) =
  ## Keeps ghost movement inside the map rectangle.
  let
    maxX = MapWidth - CollisionW
    maxY = MapHeight - CollisionH
  if player.x < 0:
    player.x = 0
    player.velX = max(player.velX, 0)
    player.carryX = 0
  elif player.x > maxX:
    player.x = maxX
    player.velX = min(player.velX, 0)
    player.carryX = 0
  if player.y < 0:
    player.y = 0
    player.velY = max(player.velY, 0)
    player.carryY = 0
  elif player.y > maxY:
    player.y = maxY
    player.velY = min(player.velY, 0)
    player.carryY = 0

proc applyGhostMovement*(sim: var SimServer, playerIndex: int, input: InputState) =
  template player: untyped = sim.players[playerIndex]
  var inputX = 0
  var inputY = 0
  if input.left: inputX -= 1
  if input.right: inputX += 1
  if input.up: inputY -= 1
  if input.down: inputY += 1

  if inputX != 0:
    player.velX = clamp(
      player.velX + inputX * sim.config.accel,
      -sim.config.maxSpeed,
      sim.config.maxSpeed
    )
  else:
    player.velX =
      (player.velX * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velX) < sim.config.stopThreshold:
      player.velX = 0

  if inputY != 0:
    player.velY = clamp(
      player.velY + inputY * sim.config.accel,
      -sim.config.maxSpeed,
      sim.config.maxSpeed
    )
  else:
    player.velY =
      (player.velY * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velY) < sim.config.stopThreshold:
      player.velY = 0

  if inputX < 0: player.flipH = true
  elif inputX > 0: player.flipH = false

  player.carryX += player.velX
  while abs(player.carryX) >= sim.config.motionScale:
    let step = if player.carryX < 0: -1 else: 1
    player.x += step
    player.carryX -= step * sim.config.motionScale
  player.carryY += player.velY
  while abs(player.carryY) >= sim.config.motionScale:
    let step = if player.carryY < 0: -1 else: 1
    player.y += step
    player.carryY -= step * sim.config.motionScale
  player.containGhost()

  if player.role == Crewmate and input.attack:
    let
      px = player.x + CollisionW div 2
      py = player.y + CollisionH div 2
    var inTask = -1
    for t in 0 ..< sim.tasks.len:
      if not player.hasTask(t): continue
      let task = sim.tasks[t]
      if playerIndex < task.completed.len and task.completed[playerIndex]: continue
      if px >= task.x and px < task.x + task.w and
          py >= task.y and py < task.y + task.h:
        inTask = t
        break
    if inTask >= 0 and inputX == 0 and inputY == 0:
      if player.activeTask != inTask:
        player.activeTask = inTask
        player.taskProgress = 0
      inc player.taskProgress
      if player.taskProgress >= sim.config.taskCompleteTicks:
        sim.completeTask(playerIndex, inTask)
        player.activeTask = -1
        player.taskProgress = 0
    else:
      player.activeTask = -1
      player.taskProgress = 0
  else:
    player.activeTask = -1
    player.taskProgress = 0

proc applyInput*(sim: var SimServer, playerIndex: int, input: InputState, prevInput: InputState, bodiesBeforeTick: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if not sim.players[playerIndex].alive:
    sim.applyGhostMovement(playerIndex, input)
    return
  template player: untyped = sim.players[playerIndex]

  var
    inputX = 0
    inputY = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1
  if input.up:
    inputY -= 1
  if input.down:
    inputY += 1

  if inputX != 0:
    player.velX = clamp(
      player.velX + inputX * sim.config.accel,
      -sim.config.maxSpeed,
      sim.config.maxSpeed
    )
  else:
    player.velX =
      (player.velX * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velX) < sim.config.stopThreshold:
      player.velX = 0

  if inputY != 0:
    player.velY = clamp(
      player.velY + inputY * sim.config.accel,
      -sim.config.maxSpeed,
      sim.config.maxSpeed
    )
  else:
    player.velY =
      (player.velY * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velY) < sim.config.stopThreshold:
      player.velY = 0

  if inputX < 0:
    player.flipH = true
  elif inputX > 0:
    player.flipH = false

  sim.applyMomentumAxis(player, player.carryX, player.velX, true)
  sim.applyMomentumAxis(player, player.carryY, player.velY, false)

  if input.b:
    if player.role == Imposter:
      sim.tryVent(playerIndex)

  if input.attack:
    let freshA = input.attack and not prevInput.attack
    if freshA:
      sim.tryReport(playerIndex, bodiesBeforeTick)
      if sim.phase == Voting:
        return
      sim.tryCallButton(playerIndex)
      if sim.phase == Voting:
        return
    if player.role == Imposter:
      if freshA:
        sim.tryKill(playerIndex)
    elif player.role == Crewmate:
      let
        px = player.x + CollisionW div 2
        py = player.y + CollisionH div 2
      var inTask = -1
      for t in 0 ..< sim.tasks.len:
        if not player.hasTask(t):
          continue
        let task = sim.tasks[t]
        if playerIndex < task.completed.len and task.completed[playerIndex]:
          continue
        if px >= task.x and px < task.x + task.w and
            py >= task.y and py < task.y + task.h:
          inTask = t
          break
      if inTask >= 0 and inputX == 0 and inputY == 0:
        if player.activeTask != inTask:
          player.activeTask = inTask
          player.taskProgress = 0
        inc player.taskProgress
        if player.taskProgress >= sim.config.taskCompleteTicks:
          sim.completeTask(playerIndex, inTask)
          player.activeTask = -1
          player.taskProgress = 0
      else:
        player.activeTask = -1
        player.taskProgress = 0
  else:
    player.activeTask = -1
    player.taskProgress = 0

proc blitSpriteOutlined(
  fb: var Framebuffer,
  sprite: Sprite,
  screenX, screenY: int,
  tint: uint8,
  flipH: bool
) =
  ## Draws a tinted actor sprite into screen coordinates.
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let srcX = if flipH: sprite.width - 1 - x else: x
      let colorIndex = sprite.pixels[sprite.spriteIndex(srcX, y)]
      if colorIndex == TransparentColorIndex:
        continue
      fb.putPixel(screenX + x, screenY + y, actorColor(colorIndex, tint))

proc blitSpriteRaw(fb: var Framebuffer, sprite: Sprite, screenX, screenY: int) =
  ## Draws a sprite into screen coordinates without a camera.
  fb.blitSprite(sprite, screenX, screenY, 0, 0)

proc blitSpriteShadowed*(
  fb: var Framebuffer,
  sprite: Sprite,
  screenX, screenY: int
) =
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        fb.putPixel(screenX + x, screenY + y, ShadowMap[colorIndex and 0x0F])

proc isWall*(sim: SimServer, mx, my: int): bool =
  if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
    return true
  sim.wallMask[mapIndex(mx, my)]

proc castShadows*(sim: var SimServer, originMx, originMy, cameraX, cameraY: int) =
  for i in 0 ..< sim.shadowBuf.len:
    sim.shadowBuf[i] = false
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let
        mx = cameraX + sx
        my = cameraY + sy
        dx = mx - originMx
        dy = my - originMy
        steps = max(abs(dx), abs(dy))
      if steps == 0:
        continue
      var shadowed = false
      for s in 1 .. steps:
        let
          rx = originMx + dx * s div steps
          ry = originMy + dy * s div steps
        if sim.isWall(rx, ry):
          shadowed = true
          break
      if shadowed:
        sim.shadowBuf[sy * ScreenWidth + sx] = true

proc allVotesCast*(sim: SimServer): bool =
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive and sim.voteState.votes[i] == -1:
      return false
  true

proc tallyVotes*(sim: var SimServer) =
  var counts = newSeq[int](sim.players.len)
  var skipCount = 0
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive:
      let v = sim.voteState.votes[i]
      if v >= 0 and v < counts.len:
        inc counts[v]
      elif v == -2 or v == -1:
        inc skipCount
  var maxVotes = skipCount
  var maxPlayer = -1
  var tied = false
  for i in 0 ..< counts.len:
    if counts[i] > maxVotes:
      maxVotes = counts[i]
      maxPlayer = i
      tied = false
    elif counts[i] == maxVotes and counts[i] > 0:
      tied = true
  if tied or maxVotes == 0:
    sim.voteState.ejectedPlayer = -1
  else:
    sim.voteState.ejectedPlayer = maxPlayer
  sim.phase = VoteResult
  sim.voteState.resultTimer = sim.config.voteResultTicks

proc applyVoteResult*(sim: var SimServer) =
  let ej = sim.voteState.ejectedPlayer
  if ej >= 0 and ej < sim.players.len:
    sim.players[ej].alive = false
  sim.bodies.setLen(0)
  sim.phase = Playing

proc moveCursor*(sim: var SimServer, playerIndex: int, delta: int) =
  let n = sim.players.len
  if n == 0:
    return
  let total = n + 1
  var cur = sim.voteState.cursor[playerIndex]
  for step in 1 .. total:
    cur = (cur + delta + total) mod total
    if cur == n or sim.players[cur].alive:
      break
  sim.voteState.cursor[playerIndex] = cur

proc buildLobbyFrame*(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(0)
  let n = sim.players.len
  let needed = max(0, sim.config.minPlayers - n)
  sim.fb.blitAsciiText(sim.asciiSprites, "WAITING", 11, 4)
  if needed > 0:
    sim.fb.blitAsciiText(sim.asciiSprites, "NEED MORE!", 2, 14)
  else:
    sim.fb.blitAsciiText(sim.asciiSprites, "READY!", 14, 14)
  let startY = 26
  for i in 0 ..< n:
    let
      col = i mod 6
      row = i div 6
      sx = 5 + col * 9
      sy = startY + row * 9
    sim.fb.blitSpriteOutlined(sim.playerSprite, sx, sy, sim.players[i].color, false)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildSpectatorFrame*(sim: var SimServer): seq[uint8] =
  sim.fb.clearFrame(0)
  sim.fb.blitAsciiText(sim.asciiSprites, "GAME IN", 11, 22)
  sim.fb.blitAsciiText(sim.asciiSprites, "PROGRESS", 8, 32)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildReplayFramePacket*(sim: var SimServer): seq[uint8] =
  ## Builds a simple player screen for replay mode.
  sim.fb.clearFrame(SpaceColor)
  sim.fb.blitAsciiText(sim.asciiSprites, "REPLAY", 20, 30)
  sim.fb.blitAsciiText(sim.asciiSprites, "GLOBAL", 20, 38)
  sim.fb.blitAsciiText(sim.asciiSprites, "VIEW", 20, 46)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildVoteFrame*(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(0)
  let n = sim.players.len
  if n == 0:
    sim.fb.packFramebuffer()
    return sim.fb.packed
  let
    cellW = 18
    cellH = 20
    cols = min(n, ScreenWidth div cellW)
    rows = (n + cols - 1) div cols
    totalW = cols * cellW
    totalH = rows * cellH + 8
    startX = (ScreenWidth - totalW) div 2
    startY = (ScreenHeight - totalH) div 2

  for idx in 0 ..< n:
    let
      pi = idx
      col = idx mod cols
      row = idx div cols
      cx = startX + col * cellW
      cy = startY + row * cellH
      spriteX = cx + (cellW - SpriteSize) div 2
      spriteY = cy + 1
    if sim.players[pi].alive:
      sim.fb.blitSpriteOutlined(
        sim.playerSprite,
        spriteX,
        spriteY,
        sim.players[pi].color,
        false
      )
    else:
      sim.fb.blitSpriteOutlined(
        sim.bodySprite,
        spriteX,
        spriteY,
        sim.players[pi].color,
        false
      )
    if pi == playerIndex:
      sim.fb.putPixel(cx + cellW div 2 - 1, cy - 2, sim.players[pi].color)
      sim.fb.putPixel(cx + cellW div 2, cy - 2, sim.players[pi].color)
    if sim.players[pi].alive and
        playerIndex >= 0 and playerIndex < sim.voteState.cursor.len and
        sim.voteState.cursor[playerIndex] == pi:
      for bx in 0 ..< cellW:
        sim.fb.putPixel(cx + bx, cy - 1, 2'u8)
        sim.fb.putPixel(cx + bx, cy + cellH - 2, 2'u8)
      for by in 0 ..< cellH:
        sim.fb.putPixel(cx, cy + by - 1, 2'u8)
        sim.fb.putPixel(cx + cellW - 1, cy + by - 1, 2'u8)
    var voterRow = 0
    for vi in 0 ..< n:
      if sim.voteState.votes[vi] == pi:
        let
          dotX = cx + 2 + (voterRow mod 6) * 2
          dotY = cy + SpriteSize + 3 + (voterRow div 6) * 2
        sim.fb.putPixel(dotX, dotY, sim.players[vi].color)
        sim.fb.putPixel(dotX + 1, dotY, sim.players[vi].color)
        sim.fb.putPixel(dotX, dotY + 1, sim.players[vi].color)
        sim.fb.putPixel(dotX + 1, dotY + 1, sim.players[vi].color)
        inc voterRow

  let skipY = startY + rows * cellH + 1
  let skipW = 28
  let skipX = (ScreenWidth - skipW) div 2
  sim.fb.blitAsciiText(sim.asciiSprites, "SKIP", skipX, skipY)
  if playerIndex >= 0 and playerIndex < sim.voteState.cursor.len and
      sim.voteState.cursor[playerIndex] == n:
    for bx in 0 ..< skipW:
      sim.fb.putPixel(skipX + bx, skipY - 1, 2'u8)
      sim.fb.putPixel(skipX + bx, skipY + 6, 2'u8)
    for by in 0 ..< 8:
      sim.fb.putPixel(skipX - 1, skipY + by - 1, 2'u8)
      sim.fb.putPixel(skipX + skipW, skipY + by - 1, 2'u8)
  var skipVoterRow = 0
  for vi in 0 ..< n:
    if sim.voteState.votes[vi] == -2:
      let
        dotX = skipX + skipW + 2 + (skipVoterRow mod 4) * 2
        dotY = skipY + (skipVoterRow div 4) * 2
      sim.fb.putPixel(dotX, dotY, sim.players[vi].color)
      sim.fb.putPixel(dotX + 1, dotY, sim.players[vi].color)
      sim.fb.putPixel(dotX, dotY + 1, sim.players[vi].color)
      sim.fb.putPixel(dotX + 1, dotY + 1, sim.players[vi].color)
      inc skipVoterRow

  let
    barY = ScreenHeight - 2
    barW = ScreenWidth - 4
    filled = sim.voteState.voteTimer * barW div sim.config.voteTimerTicks
  for bx in 0 ..< barW:
    let c = if bx < filled: 10'u8 else: 1'u8
    sim.fb.putPixel(2 + bx, barY, c)
    sim.fb.putPixel(2 + bx, barY + 1, c)

  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildResultFrame*(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(0)
  let ej = sim.voteState.ejectedPlayer
  if ej >= 0 and ej < sim.players.len:
    let
      sx = ScreenWidth div 2 - SpriteSize div 2
      sy = ScreenHeight div 2 - SpriteSize div 2
    sim.fb.blitSpriteOutlined(sim.playerSprite, sx, sy, sim.players[ej].color, false)
  else:
    sim.fb.blitAsciiText(sim.asciiSprites, "NO ONE", 46, 54)
    sim.fb.blitAsciiText(sim.asciiSprites, "DIED", 52, 64)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc totalTasksRemaining*(sim: SimServer): int =
  for i in 0 ..< sim.players.len:
    if sim.players[i].role != Crewmate:
      continue
    for t in sim.players[i].assignedTasks:
      if t < sim.tasks.len and i < sim.tasks[t].completed.len and
          not sim.tasks[t].completed[i]:
        inc result

proc allTasksDone*(sim: SimServer): bool =
  sim.totalTasksRemaining() == 0

proc finishGame*(sim: var SimServer, winner: PlayerRole) =
  ## Moves to game over and awards all winning players.
  if sim.phase == GameOver:
    return
  sim.phase = GameOver
  sim.winner = winner
  sim.gameOverTimer = sim.config.gameOverTicks
  for i in 0 ..< sim.players.len:
    if sim.players[i].role == winner:
      sim.addReward(i, WinReward)

proc checkWinCondition*(sim: var SimServer) =
  let hasImposters = min(
    sim.config.imposterCount,
    max(0, sim.players.len - 1)
  ) > 0
  var aliveCrewmates = 0
  var aliveImposters = 0
  for p in sim.players:
    if p.alive:
      if p.role == Crewmate:
        inc aliveCrewmates
      else:
        inc aliveImposters
  if hasImposters and aliveImposters == 0 and sim.players.len > 0:
    sim.finishGame(Crewmate)
  elif hasImposters and aliveImposters >= aliveCrewmates and
      sim.players.len > 0:
    sim.finishGame(Imposter)
  elif sim.allTasksDone() and sim.players.len > 0:
    sim.finishGame(Crewmate)

proc buildGameOverFrame*(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(0)
  let title =
    if sim.winner == Crewmate: "CREW WINS"
    else: "IMPS WIN"
  let titleW = title.len * 7
  let titleX = (ScreenWidth - titleW) div 2
  sim.fb.blitAsciiText(sim.asciiSprites, title, titleX, 2)
  let n = sim.players.len
  let
    rowH = 16
    iconX = 8
    textX = 26
    startY = 16
  for i in 0 ..< n:
    let
      p = sim.players[i]
      y = startY + i * rowH
      iconY = y + (rowH - SpriteSize) div 2
      textY = y + (rowH - 6) div 2
      roleStr = if p.role == Imposter: "IMP" else: "CREW"
    sim.fb.blitSpriteOutlined(sim.playerSprite, iconX, iconY, p.color, false)
    sim.fb.blitAsciiText(sim.asciiSprites, roleStr, textX, textY)
    if not p.alive:
      for lx in textX ..< textX + roleStr.len * 7:
        sim.fb.putPixel(lx, textY + 3, 3'u8)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc render*(sim: var SimServer, playerIndex: int): seq[uint8] =
  if sim.phase == Lobby:
    return sim.buildLobbyFrame(playerIndex)
  if sim.phase == GameOver:
    return sim.buildGameOverFrame(playerIndex)
  if sim.phase == Voting:
    return sim.buildVoteFrame(playerIndex)
  if sim.phase == VoteResult:
    return sim.buildResultFrame(playerIndex)
  sim.fb.clearFrame(SpaceColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let
    player = sim.players[playerIndex]
    spriteX = player.x - SpriteDrawOffX
    spriteY = player.y - SpriteDrawOffY
    centerX = spriteX + SpriteSize div 2
    centerY = spriteY + SpriteSize div 2
    cameraX = centerX - ScreenWidth div 2
    cameraY = centerY - ScreenHeight div 2

  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let
        mx = cameraX + x
        my = cameraY + y
      if mx >= 0 and my >= 0 and mx < MapWidth and my < MapHeight:
        sim.fb.putPixel(x, y, sim.mapPixels[mapIndex(mx, my)])

  let
    viewerIsGhost = not player.alive
    originMx = player.x + CollisionW div 2
    originMy = player.y + CollisionH div 2
  sim.castShadows(originMx, originMy, cameraX, cameraY)

  if not viewerIsGhost:
    for sy in 0 ..< ScreenHeight:
      for sx in 0 ..< ScreenWidth:
        let
          mx = cameraX + sx
          my = cameraY + sy
          idx = sy * ScreenWidth + sx
        if not sim.shadowBuf[idx]:
          continue
        if mx >= 0 and my >= 0 and mx < MapWidth and my < MapHeight and
            sim.wallMask[mapIndex(mx, my)]:
          continue
        sim.fb.indices[idx] = ShadowMap[sim.fb.indices[idx] and 0x0F]

  for body in sim.bodies:
    let
      bsx = body.x - SpriteDrawOffX - cameraX
      bsy = body.y - SpriteDrawOffY - cameraY
      bcx = body.x + CollisionW div 2 - cameraX
      bcy = body.y + CollisionH div 2 - cameraY
    if bcx < 0 or bcx >= ScreenWidth or bcy < 0 or bcy >= ScreenHeight:
      continue
    if not viewerIsGhost and sim.shadowBuf[bcy * ScreenWidth + bcx]:
      continue
    sim.fb.blitSpriteOutlined(sim.bodySprite, bsx, bsy, body.color, false)

  var drawOrder = newSeq[int](sim.players.len)
  for i in 0 ..< sim.players.len:
    drawOrder[i] = i
  for i in 1 ..< drawOrder.len:
    let key = drawOrder[i]
    var j = i - 1
    while j >= 0 and sim.players[drawOrder[j]].y > sim.players[key].y:
      drawOrder[j + 1] = drawOrder[j]
      dec j
    drawOrder[j + 1] = key

  for i in drawOrder:
    let
      p = sim.players[i]
      sx = p.x - SpriteDrawOffX - cameraX
      sy = p.y - SpriteDrawOffY - cameraY
    if p.alive:
      if i != playerIndex:
        let
          pcx = p.x + CollisionW div 2 - cameraX
          pcy = p.y + CollisionH div 2 - cameraY
        if pcx < 0 or pcx >= ScreenWidth or pcy < 0 or pcy >= ScreenHeight:
          continue
        if not viewerIsGhost and sim.shadowBuf[pcy * ScreenWidth + pcx]:
          continue
      sim.fb.blitSpriteOutlined(sim.playerSprite, sx, sy, p.color, p.flipH)
    elif viewerIsGhost:
      sim.fb.blitSpriteOutlined(sim.ghostSprite, sx, sy, p.color, p.flipH)

  if player.role == Crewmate:
    for t in 0 ..< sim.tasks.len:
      if not player.hasTask(t):
        continue
      let
        task = sim.tasks[t]
        bob = [0, 0, -1, -1, -1, 0, 0, 1, 1, 1]
        bobY =
          if player.activeTask == t:
            0
          else:
            bob[(sim.tickCount div 3) mod bob.len]
        iconSx = task.x + task.w div 2 - SpriteSize div 2 - cameraX
        iconSy = task.y - SpriteSize - 2 + bobY - cameraY
      if playerIndex < task.completed.len and task.completed[playerIndex]:
        continue
      if iconSx + SpriteSize <= 0 or iconSy + SpriteSize <= 0 or
          iconSx >= ScreenWidth or iconSy >= ScreenHeight:
        continue
      sim.fb.blitSpriteRaw(sim.taskIconSprite, iconSx, iconSy)
      if player.activeTask == t and player.taskProgress > 0:
        let
          barX = iconSx + SpriteSize div 2 - TaskBarWidth div 2
          barY = iconSy + SpriteSize + TaskBarGap
          filled =
            player.taskProgress * TaskBarWidth div sim.config.taskCompleteTicks
        for bx in 0 ..< TaskBarWidth:
          let c = if bx < filled: ProgressFilled else: ProgressEmpty
          sim.fb.putPixel(barX + bx, barY, c)

  if player.role == Crewmate and sim.config.showTaskArrows:
    let radarColor = 8'u8
    let margin = 0
    for t in 0 ..< sim.tasks.len:
      if not player.hasTask(t):
        continue
      let task = sim.tasks[t]
      if playerIndex < task.completed.len and task.completed[playerIndex]:
        continue
      let
        bob = [0, 0, -1, -1, -1, 0, 0, 1, 1, 1]
        bobY =
          if player.activeTask == t:
            0
          else:
            bob[(sim.tickCount div 3) mod bob.len]
        iconX = task.x + task.w div 2 - cameraX
        iconY = task.y - SpriteSize div 2 - 2 + bobY - cameraY
        iconSx = task.x + task.w div 2 - SpriteSize div 2 - cameraX
        iconSy = task.y - SpriteSize - 2 + bobY - cameraY
      if iconSx + SpriteSize > 0 and iconSy + SpriteSize > 0 and
          iconSx < ScreenWidth and iconSy < ScreenHeight:
        continue
      let
        px = float(player.x + CollisionW div 2 - cameraX)
        py = float(player.y + CollisionH div 2 - cameraY)
        dx = float(iconX) - px
        dy = float(iconY) - py
      if abs(dx) < 0.5 and abs(dy) < 0.5:
        continue
      var ex, ey: float
      let
        minX = float(margin)
        maxX = float(ScreenWidth - 1 - margin)
        minY = float(margin)
        maxY = float(ScreenHeight - 1 - margin)
      if abs(dx) > abs(dy):
        if dx > 0:
          ex = maxX
        else:
          ex = minX
        ey = py + dy * (ex - px) / dx
        ey = clamp(ey, minY, maxY)
      else:
        if dy > 0:
          ey = maxY
        else:
          ey = minY
        ex = px + dx * (ey - py) / dy
        ex = clamp(ex, minX, maxX)
      sim.fb.putPixel(int(ex), int(ey), radarColor)

  if not player.alive:
    let
      iconX = 1
      iconY = ScreenHeight - SpriteSize - 1
    sim.fb.blitSpriteRaw(sim.ghostIconSprite, iconX, iconY)
  elif player.role == Imposter:
    let
      iconX = 1
      iconY = ScreenHeight - SpriteSize - 1
    if player.killCooldown > 0:
      sim.fb.blitSpriteShadowed(sim.killButtonSprite, iconX, iconY)
    else:
      sim.fb.blitSpriteRaw(sim.killButtonSprite, iconX, iconY)

  let remaining = sim.totalTasksRemaining()
  let numStr = $remaining
  let dx = ScreenWidth - numStr.len * 7
  sim.fb.blitAsciiText(sim.asciiSprites, numStr, dx, 0)

  sim.fb.packFramebuffer()
  sim.fb.packed

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.rng = initRand(config.seed)
  result.fb = initFramebuffer()
  loadPalette(clientDataDir() / "pallete.png")
  result.asciiSprites = loadAsciiSprites("ascii.png")

  let sheet = loadSpriteSheet()
  result.playerSprite = spriteFromImage(
    sheet.subImage(0, 0, SpriteSize, SpriteSize)
  )
  result.bodySprite = spriteFromImage(
    sheet.subImage(SpriteSize, 0, SpriteSize, SpriteSize)
  )
  result.boneSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 2, 0, SpriteSize, SpriteSize)
  )
  result.killButtonSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 3, 0, SpriteSize, SpriteSize)
  )
  result.taskIconSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 4, 0, SpriteSize, SpriteSize)
  )
  result.ghostSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 6, 0, SpriteSize, SpriteSize)
  )
  result.ghostIconSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 7, 0, SpriteSize, SpriteSize)
  )

  result.tasks = @[
    TaskStation(name: "Empty Garbage", x: 554, y: 465, w: 16, h: 16),
    TaskStation(name: "Upload Data (Comms)", x: 667, y: 419, w: 16, h: 16),
    TaskStation(name: "Fix Wires (Storage)", x: 574, y: 269, w: 16, h: 16),
    TaskStation(name: "Fix Wires (Electrical)", x: 444, y: 31, w: 16, h: 16),
    TaskStation(name: "Upload Data (Electrical)", x: 366, y: 289, w: 16, h: 16),
    TaskStation(name: "Calibrate Distributor", x: 428, y: 295, w: 16, h: 16),
    TaskStation(name: "Submit Scan", x: 400, y: 234, w: 16, h: 16),
    TaskStation(name: "Divert Power", x: 397, y: 295, w: 16, h: 16),
    TaskStation(name: "Inspect Sample", x: 416, y: 222, w: 16, h: 16),
    TaskStation(name: "Upload Data (Admin)", x: 597, y: 267, w: 16, h: 16),
    TaskStation(name: "Align Engine (Lower)", x: 162, y: 398, w: 16, h: 16),
    TaskStation(name: "Align Engine (Upper)", x: 162, y: 156, w: 16, h: 16),
    TaskStation(name: "Swipe Card", x: 670, y: 306, w: 16, h: 16),
    TaskStation(name: "Upload Data (Cafeteria)", x: 612, y: 39, w: 16, h: 16),
    TaskStation(name: "Empty Garbage (Upper)", x: 630, y: 60, w: 16, h: 16),
  ]

  result.vents = @[
    Vent(x: 600, y: 334, w: 12, h: 10, group: 'A', groupIndex: 1),
    Vent(x: 736, y: 264, w: 12, h: 10, group: 'A', groupIndex: 2),
    Vent(x: 634, y: 142, w: 12, h: 10, group: 'A', groupIndex: 3),
    Vent(x: 724, y: 70, w: 12, h: 10, group: 'B', groupIndex: 1),
    Vent(x: 874, y: 214, w: 12, h: 10, group: 'B', groupIndex: 2),
    Vent(x: 740, y: 422, w: 12, h: 10, group: 'C', groupIndex: 1),
    Vent(x: 874, y: 262, w: 12, h: 10, group: 'C', groupIndex: 2),
    Vent(x: 336, y: 220, w: 12, h: 10, group: 'D', groupIndex: 1),
    Vent(x: 352, y: 298, w: 12, h: 10, group: 'D', groupIndex: 2),
    Vent(x: 296, y: 274, w: 12, h: 10, group: 'D', groupIndex: 3),
    Vent(x: 88, y: 120, w: 12, h: 10, group: 'E', groupIndex: 1),
    Vent(x: 132, y: 272, w: 12, h: 10, group: 'E', groupIndex: 2),
    Vent(x: 242, y: 408, w: 12, h: 10, group: 'E', groupIndex: 3),
    Vent(x: 110, y: 196, w: 12, h: 10, group: 'F', groupIndex: 1),
    Vent(x: 242, y: 84, w: 12, h: 10, group: 'F', groupIndex: 2),
  ]

  let (mapImage, walkImage, wallImage) = loadSkeld2Layers()
  result.mapPixels = newSeq[uint8](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      result.mapPixels[mapIndex(x, y)] = nearestPaletteIndex(mapImage[x, y])

  result.walkMask = newSeq[bool](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let pixel = walkImage[x, y]
      result.walkMask[mapIndex(x, y)] = pixel.a > 0

  result.wallMask = newSeq[bool](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let pixel = wallImage[x, y]
      result.wallMask[mapIndex(x, y)] = pixel.a > 0

  result.shadowBuf = newSeq[bool](ScreenWidth * ScreenHeight)
  result.bodies = @[]
  result.players = @[]
  result.nextJoinOrder = 0

proc resetToLobby*(sim: var SimServer) =
  sim.phase = Lobby
  sim.bodies = @[]
  sim.players = @[]
  sim.nextJoinOrder = 0
  sim.tickCount = 0
  sim.needsReregister = true
  for task in sim.tasks.mitems:
    task.completed = @[]

proc step*(sim: var SimServer, inputs: openArray[InputState], prevInputs: openArray[InputState]) =
  inc sim.tickCount

  if sim.phase == Lobby:
    if sim.players.len >= sim.config.minPlayers:
      sim.startGame()
    return

  if sim.phase == GameOver:
    dec sim.gameOverTimer
    if sim.gameOverTimer <= 0:
      sim.resetToLobby()
    return

  if sim.phase == VoteResult:
    dec sim.voteState.resultTimer
    if sim.voteState.resultTimer <= 0:
      sim.applyVoteResult()
      sim.checkWinCondition()
    return

  if sim.phase == Voting:
    dec sim.voteState.voteTimer
    if sim.voteState.voteTimer <= 0:
      sim.tallyVotes()
      return
    for i in 0 ..< sim.players.len:
      if not sim.players[i].alive:
        continue
      let input =
        if i < inputs.len: inputs[i]
        else: InputState()
      let prev =
        if i < prevInputs.len: prevInputs[i]
        else: InputState()
      if (input.up and not prev.up) or (input.left and not prev.left):
        sim.moveCursor(i, -1)
      if (input.down and not prev.down) or (input.right and not prev.right):
        sim.moveCursor(i, 1)
      if input.attack and not prev.attack:
        let cur = sim.voteState.cursor[i]
        if cur == sim.players.len:
          sim.voteState.votes[i] = -2
        else:
          sim.voteState.votes[i] = cur
        if sim.allVotesCast():
          sim.tallyVotes()
    return

  let bodiesBeforeTick = sim.bodies.len
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].alive and
        sim.players[playerIndex].role == Imposter:
      if sim.players[playerIndex].killCooldown > 0:
        dec sim.players[playerIndex].killCooldown
      if sim.players[playerIndex].ventCooldown > 0:
        dec sim.players[playerIndex].ventCooldown
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    let prev =
      if playerIndex < prevInputs.len: prevInputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input, prev, bodiesBeforeTick)

  sim.checkWinCondition()

import jsony, pixie
import protocol
import bitworld/aseprite
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
  DefaultMapPath* = "map.json"
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
  MapVoidColor* = 12'u8
  TintColor* = 3'u8
  ShadeTintColor* = 9'u8
  OutlineColor* = 0'u8
  KillRange* = 20
  KillCooldownTicks* = 1200
  RoleRevealTicks* = 120
  TaskCompleteTicks* = 72
  TaskBarWidth* = 14
  VentRange* = 16
  TaskBarGap* = 1
  ProgressEmpty* = 1'u8
  ProgressFilled* = 10'u8
  ReportRange* = 20
  VoteResultTicks* = 72
  MaxPlayers* = 16
  MinPlayers* = 8
  ImposterCount* = 2
  VoteTimerTicks* = 600
  GameOverTicks* = 360
  MaxTicks* = 0  ## 0 = no limit (event-driven termination only)
  MaxGames* = 0  ## 0 = no limit.
  TasksPerPlayer* = 8
  ShowTaskArrows* = true
  ButtonCalls* = 1
  VoteChatVisibleMessages* = 4
  VoteChatCharsPerLine* = 15
  VoteChatLineCount* = 5
  VoteChatMaxChars* = VoteChatCharsPerLine * VoteChatLineCount
  TaskReward* = 1
  KillReward* = 10
  WinReward* = 100
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
  PlayerColors* = [
    3'u8,
    7,
    8,
    14,
    4,
    11,
    13,
    15,
    1,
    2,
    5,
    6,
    9,
    10,
    12,
    0
  ]
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
  Player2WebSocketPath* = "/player2"
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
    RoleReveal

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

  Room* = object
    name*: string
    x*, y*, w*, h*: int

  MapRect* = object
    x*, y*, w*, h*: int

  MapPoint* = object
    x*, y*: int

  AmongMap* = object
    name*: string
    path*: string
    asepritePath*: string
    width*, height*: int
    mapLayer*, walkLayer*, wallLayer*: int
    button*: MapRect
    home*: MapPoint
    tasks*: seq[TaskStation]
    vents*: seq[Vent]
    rooms*: seq[Room]

  Body* = object
    x*, y*: int
    color*: uint8

  ChatMessage* = object
    color*: uint8
    text*: string

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
    roleRevealTicks*: int
    taskCompleteTicks*: int
    ventRange*: int
    reportRange*: int
    voteResultTicks*: int
    minPlayers*: int
    imposterCount*: int
    voteTimerTicks*: int
    gameOverTicks*: int
    maxTicks*: int
    maxGames*: int
    tasksPerPlayer*: int
    showTaskArrows*: bool
    showTaskBubbles*: bool
    buttonCalls*: int
    mapPath*: string

  Player* = object
    x*, y*: int
    homeX*, homeY*: int
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
    chatMessages*: seq[ChatMessage]
    rewardAccounts*: seq[RewardAccount]
    bodies*: seq[Body]
    playerSprite*: Sprite
    bodySprite*: Sprite
    boneSprite*: Sprite
    killButtonSprite*: Sprite
    taskIconSprite*: Sprite
    ghostSprite*: Sprite
    ghostIconSprite*: Sprite
    gameMap*: AmongMap
    tasks*: seq[TaskStation]
    vents*: seq[Vent]
    rooms*: seq[Room]
    mapPixels*: seq[uint8]
    mapRgba*: seq[uint8]
    walkMask*: seq[bool]
    wallMask*: seq[bool]
    fb*: Framebuffer
    shadowBuf*: seq[bool]
    rng*: Rand
    nextJoinOrder*: int
    tickCount*: int
    gameStartTick*: int
    phase*: GamePhase
    voteState*: VoteState
    asciiSprites*: seq[Sprite]
    winner*: PlayerRole
    gameOverTimer*: int
    roleRevealTimer*: int
    timeLimitReached*: bool
    needsReregister*: bool

  PlayerView* = object
    cameraX*, cameraY*: int
    originMx*, originMy*: int
    viewerIsGhost*: bool

const
  RenderStateHeaderFeatures = 22
  RenderStateGridSize = 32
  RenderStateGridFeatures = RenderStateGridSize * RenderStateGridSize
  RenderStatePlayerSlots = MaxPlayers
  RenderStatePlayerFeatures = 8
  RenderStateBodySlots = MaxPlayers
  RenderStateBodyFeatures = 8
  RenderStateTaskSlots = 15
  RenderStateTaskFeatures = 8
  RenderStateGridOffset = RenderStateHeaderFeatures
  RenderStatePlayerOffset = RenderStateGridOffset + RenderStateGridFeatures
  RenderStateBodyOffset =
    RenderStatePlayerOffset + RenderStatePlayerSlots * RenderStatePlayerFeatures
  RenderStateTaskOffset =
    RenderStateBodyOffset + RenderStateBodySlots * RenderStateBodyFeatures
  RenderStateFeatures* =
    RenderStateTaskOffset + RenderStateTaskSlots * RenderStateTaskFeatures

  RenderHeaderSelfJoin = 1
  RenderHeaderPlayerCount = 2
  RenderHeaderSelfRole = 4
  RenderHeaderSelfScreenX = 5
  RenderHeaderSelfScreenY = 6
  RenderHeaderSelfVelX = 7
  RenderHeaderSelfVelY = 8
  RenderHeaderKillCooldown = 9
  RenderHeaderTaskProgress = 10
  RenderHeaderActiveTask = 11
  RenderHeaderButtonCalls = 12
  RenderHeaderTasksRemaining = 13
  RenderHeaderTickModulo = 15
  RenderHeaderVoteTimer = 18
  RenderHeaderEjectedPlayer = 19
  RenderHeaderWinner = 20
  RenderHeaderTimeLimitCause = 21

  RenderPlayerFlagsFeature = 4
  RenderPlayerVelXFeature = 5
  RenderPlayerVelYFeature = 6
  RenderPlayerAuxFeature = 7

  RenderTaskKindFeature = 0
  RenderTaskFlagsFeature = 3
  RenderTaskProgressFeature = 4
  RenderTaskSourceIdFeature = 7

  RenderKindPlayer = 1'u8
  RenderKindBody = 2'u8
  RenderKindTask = 3'u8

  RenderPlayerPresent = 1'u8
  RenderPlayerSelf = 2'u8
  RenderPlayerAlive = 4'u8
  RenderPlayerRoleImposter = 8'u8
  RenderPlayerFlipH = 16'u8
  RenderPlayerGhost = 32'u8
  RenderPlayerSelected = 64'u8

  RenderTaskAssigned = 1'u8
  RenderTaskIncomplete = 2'u8
  RenderTaskActive = 4'u8
  RenderTaskIconVisible = 8'u8
  RenderTaskArrowVisible = 16'u8
  RenderTaskCompleted = 32'u8

proc gameDir*(): string =
  ## Returns the Among Them game directory.
  when defined(emscripten):
    "among_them"
  else:
    currentSourcePath().parentDir()

proc clientDataDir*(): string =
  ## Returns the shared client data directory.
  when defined(emscripten):
    "clients" / "data"
  else:
    gameDir() / ".." / "clients" / "data"

proc resolveGamePath*(path: string, baseDir = ""): string =
  ## Resolves a game data path against the map file and game directory.
  let trimmed = path.strip()
  if trimmed.len == 0 or trimmed.isAbsolute():
    return trimmed
  if baseDir.len > 0:
    let basePath = baseDir / trimmed
    if fileExists(basePath):
      return basePath
  if fileExists(trimmed):
    return trimmed
  if baseDir.len > 0:
    return baseDir / trimmed
  gameDir() / trimmed

proc resolveMapPath*(path: string): string =
  ## Resolves an Among Them map JSON path.
  let trimmed =
    if path.strip().len == 0:
      DefaultMapPath
    else:
      path.strip()
  if trimmed.isAbsolute() or fileExists(trimmed):
    trimmed
  else:
    gameDir() / trimmed

proc spriteSheetPath(): string =
  ## Returns the best available sprite sheet path.
  if fileExists("spritesheet.aseprite"):
    "spritesheet.aseprite"
  elif fileExists(gameDir() / "spritesheet.aseprite"):
    gameDir() / "spritesheet.aseprite"
  elif fileExists("spritesheet.png"):
    "spritesheet.png"
  else:
    gameDir() / "spritesheet.png"

proc loadSpriteSheet*(): Image =
  ## Loads the sprite sheet from aseprite when available.
  let path = spriteSheetPath()
  if path.endsWith(".aseprite"):
    readAsepriteImage(path)
  else:
    readImage(path)

proc requireObject(node: JsonNode, name: string): JsonNode =
  ## Reads one required JSON object field.
  if node.kind != JObject or not node.hasKey(name):
    raise newException(AmongThemError, "Map is missing object field " & name & ".")
  result = node[name]
  if result.kind != JObject:
    raise newException(AmongThemError, "Map field " & name & " must be an object.")

proc requireArray(node: JsonNode, name: string): JsonNode =
  ## Reads one required JSON array field.
  if node.kind != JObject or not node.hasKey(name):
    raise newException(AmongThemError, "Map is missing array field " & name & ".")
  result = node[name]
  if result.kind != JArray:
    raise newException(AmongThemError, "Map field " & name & " must be an array.")

proc requireString(node: JsonNode, name: string): string =
  ## Reads one required JSON string field.
  if node.kind != JObject or not node.hasKey(name):
    raise newException(AmongThemError, "Map is missing string field " & name & ".")
  let item = node[name]
  if item.kind != JString:
    raise newException(AmongThemError, "Map field " & name & " must be a string.")
  item.getStr()

proc optionalString(node: JsonNode, name, default: string): string =
  ## Reads one optional JSON string field.
  if node.kind != JObject or not node.hasKey(name):
    return default
  let item = node[name]
  if item.kind != JString:
    raise newException(AmongThemError, "Map field " & name & " must be a string.")
  item.getStr()

proc requireInt(node: JsonNode, name: string): int =
  ## Reads one required JSON integer field.
  if node.kind != JObject or not node.hasKey(name):
    raise newException(AmongThemError, "Map is missing integer field " & name & ".")
  let item = node[name]
  if item.kind != JInt:
    raise newException(AmongThemError, "Map field " & name & " must be an integer.")
  item.getInt()

proc optionalInt(node: JsonNode, name: string, default: int): int =
  ## Reads one optional JSON integer field.
  if node.kind != JObject or not node.hasKey(name):
    return default
  let item = node[name]
  if item.kind != JInt:
    raise newException(AmongThemError, "Map field " & name & " must be an integer.")
  item.getInt()

proc readMapRect(node: JsonNode, name: string): MapRect =
  ## Reads one required map rectangle.
  let item = node.requireObject(name)
  MapRect(
    x: item.requireInt("x"),
    y: item.requireInt("y"),
    w: item.requireInt("w"),
    h: item.requireInt("h")
  )

proc readMapPoint(node: JsonNode, name: string): MapPoint =
  ## Reads one required map point.
  let item = node.requireObject(name)
  MapPoint(
    x: item.requireInt("x"),
    y: item.requireInt("y")
  )

proc readTaskStation(node: JsonNode): TaskStation =
  ## Reads one task station from map JSON.
  TaskStation(
    name: node.requireString("name"),
    x: node.requireInt("x"),
    y: node.requireInt("y"),
    w: node.requireInt("w"),
    h: node.requireInt("h")
  )

proc readVent(node: JsonNode): Vent =
  ## Reads one vent from map JSON.
  let group = node.requireString("group")
  if group.len == 0:
    raise newException(AmongThemError, "Map vent group cannot be empty.")
  Vent(
    x: node.requireInt("x"),
    y: node.requireInt("y"),
    w: node.requireInt("w"),
    h: node.requireInt("h"),
    group: group[0],
    groupIndex: node.requireInt("groupIndex")
  )

proc readRoom(node: JsonNode): Room =
  ## Reads one named room rectangle from map JSON.
  Room(
    name: node.requireString("name"),
    x: node.requireInt("x"),
    y: node.requireInt("y"),
    w: node.requireInt("w"),
    h: node.requireInt("h")
  )

proc validateMapRect(name: string, rect: MapRect, width, height: int) =
  ## Raises if one map rectangle is outside the map.
  if rect.w <= 0 or rect.h <= 0:
    raise newException(AmongThemError, "Map " & name & " size must be positive.")
  if rect.x < 0 or rect.y < 0 or
      rect.x + rect.w > width or rect.y + rect.h > height:
    raise newException(AmongThemError, "Map " & name & " is outside the map.")

proc validateMapPoint(name: string, point: MapPoint, width, height: int) =
  ## Raises if one map point is outside the map.
  if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
    raise newException(AmongThemError, "Map " & name & " is outside the map.")

proc validateMap(gameMap: AmongMap) =
  ## Raises if a loaded map has invalid geometry.
  if gameMap.asepritePath.len == 0:
    raise newException(AmongThemError, "Map aseprite path cannot be empty.")
  if gameMap.width != MapWidth or gameMap.height != MapHeight:
    raise newException(
      AmongThemError,
      "Map dimensions must be " & $MapWidth & "x" & $MapHeight & "."
    )
  validateMapRect("button", gameMap.button, gameMap.width, gameMap.height)
  validateMapPoint("home", gameMap.home, gameMap.width, gameMap.height)
  for i, task in gameMap.tasks:
    validateMapRect(
      "task " & $i,
      MapRect(x: task.x, y: task.y, w: task.w, h: task.h),
      gameMap.width,
      gameMap.height
    )
  for i, vent in gameMap.vents:
    if vent.groupIndex < 1:
      raise newException(AmongThemError, "Map vent " & $i & " index must be positive.")
    validateMapRect(
      "vent " & $i,
      MapRect(x: vent.x, y: vent.y, w: vent.w, h: vent.h),
      gameMap.width,
      gameMap.height
    )
  for i, room in gameMap.rooms:
    validateMapRect(
      "room " & $i,
      MapRect(x: room.x, y: room.y, w: room.w, h: room.h),
      gameMap.width,
      gameMap.height
    )

proc loadAmongMap*(path = ""): AmongMap =
  ## Loads an Among Them map JSON file.
  let
    resolvedPath = resolveMapPath(path)
    baseDir = resolvedPath.splitFile().dir
  var node: JsonNode
  try:
    node = parseJson(readFile(resolvedPath))
  except JsonParsingError as e:
    raise newException(AmongThemError, "Could not parse map JSON: " & e.msg)
  except IOError as e:
    raise newException(AmongThemError, "Could not read map JSON: " & e.msg)
  if node.kind != JObject:
    raise newException(AmongThemError, "Map JSON must be an object.")

  let layers = node.requireObject("layers")
  result.name = node.optionalString("name", "Unknown")
  result.path = resolvedPath
  result.width = node.optionalInt("width", MapWidth)
  result.height = node.optionalInt("height", MapHeight)
  result.asepritePath = node.optionalString("asepritePath", "")
  if result.asepritePath.len == 0:
    result.asepritePath = node.requireString("aseprite")
  result.asepritePath = resolveGamePath(result.asepritePath, baseDir)
  result.mapLayer = layers.optionalInt("map", 0)
  result.walkLayer = layers.optionalInt("walk", 1)
  result.wallLayer = layers.optionalInt("walls", 2)
  result.button = node.readMapRect("button")
  result.home = node.readMapPoint("home")

  for item in node.requireArray("tasks"):
    result.tasks.add(item.readTaskStation())
  for item in node.requireArray("vents"):
    result.vents.add(item.readVent())
  for item in node.requireArray("rooms"):
    result.rooms.add(item.readRoom())

  result.validateMap()

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
    raise newException(AmongThemError, "Map aseprite has no frames.")
  if layerIndex < 0 or layerIndex >= aseprite.layers.len:
    raise newException(
      AmongThemError,
      "Map aseprite is missing layer " & $(layerIndex + 1) & "."
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

proc loadMapLayers*(gameMap: AmongMap): tuple[mapImage, walkImage, wallImage: Image] =
  ## Loads the map, floor mask, and wall mask from aseprite layers.
  let
    path = gameMap.asepritePath
    sprite = readAseprite(path)
  if sprite.header.width != gameMap.width or sprite.header.height != gameMap.height:
    raise newException(
      AmongThemError,
      path & " dimensions must be " &
        $gameMap.width & "x" & $gameMap.height & "."
    )
  (
    mapImage: sprite.asepriteLayerImage(gameMap.mapLayer),
    walkImage: sprite.asepriteLayerImage(gameMap.walkLayer),
    wallImage: sprite.asepriteLayerImage(gameMap.wallLayer)
  )

proc loadSkeld2Layers*(): tuple[mapImage, walkImage, wallImage: Image] =
  ## Loads the default Skeld map layers.
  loadMapLayers(loadAmongMap())

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

proc fillRect*(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  ## Fills one clipped rectangle on a framebuffer.
  if w <= 0 or h <= 0:
    return
  for py in y ..< y + h:
    for px in x ..< x + w:
      fb.putPixel(px, py, color)

proc strokeRect*(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  ## Strokes one clipped rectangle on a framebuffer.
  if w <= 0 or h <= 0:
    return
  for px in x ..< x + w:
    fb.putPixel(px, y, color)
    fb.putPixel(px, y + h - 1, color)
  for py in y ..< y + h:
    fb.putPixel(x, py, color)
    fb.putPixel(x + w - 1, py, color)

proc cleanChatMessage*(message: string): string =
  ## Returns a printable, bounded chat message.
  let trimmed = message.strip()
  for ch in trimmed:
    if result.len >= VoteChatMaxChars:
      return
    if ch >= ' ' and ch <= '~':
      result.add(ch)

proc sliceChatLine*(text: string, lineIndex: int): string =
  ## Returns one fixed-width chat line.
  let startIndex = lineIndex * VoteChatCharsPerLine
  if startIndex >= text.len:
    return ""
  let endIndex = min(text.len, startIndex + VoteChatCharsPerLine)
  text[startIndex ..< endIndex]

proc chatLineCount*(text: string): int =
  ## Returns the visible line count for one chat message.
  max(1, min(
    VoteChatLineCount,
    (text.len + VoteChatCharsPerLine - 1) div VoteChatCharsPerLine
  ))

proc chatMessageHeight*(text: string): int =
  ## Returns the pixel height for one chat message row.
  max(SpriteSize, text.chatLineCount() * 9) + 2

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
    roleRevealTicks: RoleRevealTicks,
    taskCompleteTicks: TaskCompleteTicks,
    ventRange: VentRange,
    reportRange: ReportRange,
    voteResultTicks: VoteResultTicks,
    minPlayers: MinPlayers,
    imposterCount: ImposterCount,
    voteTimerTicks: VoteTimerTicks,
    gameOverTicks: GameOverTicks,
    maxTicks: MaxTicks,
    maxGames: MaxGames,
    tasksPerPlayer: TasksPerPlayer,
    showTaskArrows: ShowTaskArrows,
    showTaskBubbles: true,
    buttonCalls: ButtonCalls,
    mapPath: DefaultMapPath
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

proc readConfigString(node: JsonNode, name: string, value: var string) =
  ## Reads one optional string config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(AmongThemError, "Config field " & name & " must be a string.")
  value = item.getStr()

proc validate(config: GameConfig) =
  ## Raises if a gameplay config has invalid values.
  if config.motionScale <= 0:
    raise newException(AmongThemError, "Config field motionScale must be positive.")
  if config.frictionDen <= 0:
    raise newException(AmongThemError, "Config field frictionDen must be positive.")
  if config.minPlayers < 1:
    raise newException(AmongThemError, "Config field minPlayers must be at least 1.")
  if config.minPlayers > MaxPlayers:
    raise newException(AmongThemError, "can't do more than 16 players.")
  if config.imposterCount < 0:
    raise newException(AmongThemError, "Config field imposterCount must be non-negative.")
  if config.tasksPerPlayer < 0:
    raise newException(AmongThemError, "Config field tasksPerPlayer must be non-negative.")
  if config.buttonCalls < 0:
    raise newException(AmongThemError, "Config field buttonCalls must be non-negative.")
  if config.roleRevealTicks < 0:
    raise newException(AmongThemError, "Config field roleRevealTicks must be non-negative.")
  if config.voteTimerTicks <= 0:
    raise newException(AmongThemError, "Config field voteTimerTicks must be positive.")
  if config.killCooldownTicks < 0 or config.gameOverTicks < 0 or
      config.voteResultTicks < 0 or config.maxTicks < 0 or
      config.maxGames < 0:
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
  node.readConfigInt("roleRevealTicks", config.roleRevealTicks)
  node.readConfigInt("taskCompleteTicks", config.taskCompleteTicks)
  node.readConfigInt("ventRange", config.ventRange)
  node.readConfigInt("reportRange", config.reportRange)
  node.readConfigInt("voteResultTicks", config.voteResultTicks)
  node.readConfigInt("minPlayers", config.minPlayers)
  node.readConfigInt("imposterCount", config.imposterCount)
  node.readConfigInt("voteTimerTicks", config.voteTimerTicks)
  node.readConfigInt("gameOverTicks", config.gameOverTicks)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigInt("tasksPerPlayer", config.tasksPerPlayer)
  node.readConfigInt("buttonCalls", config.buttonCalls)
  node.readConfigInt("numberOfButtonCalls", config.buttonCalls)
  node.readConfigBool("showTaskArrows", config.showTaskArrows)
  node.readConfigBool("showTaskBubbles", config.showTaskBubbles)
  node.readConfigString("map", config.mapPath)
  node.readConfigString("mapPath", config.mapPath)
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
    "roleRevealTicks": config.roleRevealTicks,
    "taskCompleteTicks": config.taskCompleteTicks,
    "ventRange": config.ventRange,
    "reportRange": config.reportRange,
    "voteResultTicks": config.voteResultTicks,
    "minPlayers": config.minPlayers,
    "imposterCount": config.imposterCount,
    "voteTimerTicks": config.voteTimerTicks,
    "gameOverTicks": config.gameOverTicks,
    "maxTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "tasksPerPlayer": config.tasksPerPlayer,
    "buttonCalls": config.buttonCalls,
    "mapPath": config.mapPath,
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
  result.mixHashInt(sim.roleRevealTimer)
  result.mixHashInt(sim.gameStartTick)
  result.mixHashBool(sim.timeLimitReached)
  result.mixHashBool(sim.needsReregister)
  result.mixHashInt(sim.nextJoinOrder)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashInt(player.x)
    result.mixHashInt(player.y)
    result.mixHashInt(player.homeX)
    result.mixHashInt(player.homeY)
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

proc homePosition*(sim: SimServer, index, total: int): tuple[x, y: int] =
  ## Returns one deterministic home position around the meeting button.
  let
    homeX = sim.gameMap.home.x
    homeY = sim.gameMap.home.y
    spawnRadius = 28
    n = max(1, total)
    angle = float(index) * 2.0 * 3.14159265 / float(n)
    px = homeX + int(float(spawnRadius) * cos(angle))
    py = homeY + int(float(spawnRadius) * sin(angle))
  if sim.canOccupy(px, py):
    return (px, py)
  (homeX, homeY)

proc resetPlayerToHome*(sim: var SimServer, playerIndex: int) =
  ## Moves one player back to its saved meeting home position.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.players[playerIndex].x = sim.players[playerIndex].homeX
  sim.players[playerIndex].y = sim.players[playerIndex].homeY
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].carryX = 0
  sim.players[playerIndex].carryY = 0
  sim.players[playerIndex].activeTask = -1
  sim.players[playerIndex].taskProgress = 0

proc arrangeHomePositions*(sim: var SimServer) =
  ## Saves and applies evenly spaced home positions for all players.
  let total = sim.players.len
  for i in 0 ..< total:
    let home = sim.homePosition(i, total)
    sim.players[i].homeX = home.x
    sim.players[i].homeY = home.y
    sim.resetPlayerToHome(i)

proc findSpawn*(sim: SimServer): tuple[x, y: int] =
  ## Returns the next lobby spawn position.
  sim.homePosition(sim.players.len, sim.players.len + 1)

proc canAddPlayer*(sim: SimServer): bool =
  ## Returns whether the game has room for another player.
  sim.players.len < MaxPlayers

proc rewardAccountIndex(sim: SimServer, address: string): int =
  ## Returns the reward account index for an address.
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc addPlayer*(sim: var SimServer, address: string): int =
  if not sim.canAddPlayer():
    raise newException(AmongThemError, "can't do more than 16 players.")
  let
    spawn = sim.findSpawn()
    order = sim.nextJoinOrder
    rewardAccount = sim.rewardAccountIndex(address)
  inc sim.nextJoinOrder
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    homeX: spawn.x,
    homeY: spawn.y,
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
  sim.arrangeHomePositions()
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
  sim.arrangeHomePositions()
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
  sim.roleRevealTimer = sim.config.roleRevealTicks
  if sim.roleRevealTimer > 0:
    sim.phase = RoleReveal
    sim.gameStartTick = -1
  else:
    sim.phase = Playing
    sim.gameStartTick = sim.tickCount
  sim.timeLimitReached = false

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
  sim.chatMessages.setLen(0)
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

proc addVotingChat*(sim: var SimServer, playerIndex: int, message: string) =
  ## Adds one visible chat message while voting.
  if sim.phase != Voting:
    return
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if not sim.players[playerIndex].alive:
    return
  let text = cleanChatMessage(message)
  if text.len == 0:
    return
  while sim.chatMessages.len >= VoteChatVisibleMessages:
    sim.chatMessages.delete(0)
  sim.chatMessages.add ChatMessage(
    color: sim.players[playerIndex].color,
    text: text
  )

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
    button = sim.gameMap.button
  if px >= button.x and px < button.x + button.w and
      py >= button.y and py < button.y + button.h:
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

proc playerView*(sim: SimServer, playerIndex: int): PlayerView =
  ## Returns the canonical per-player camera and visibility origin.
  let
    player = sim.players[playerIndex]
    spriteX = player.x - SpriteDrawOffX
    spriteY = player.y - SpriteDrawOffY
    centerX = spriteX + SpriteSize div 2
    centerY = spriteY + SpriteSize div 2
  result.cameraX = centerX - ScreenWidth div 2
  result.cameraY = centerY - ScreenHeight div 2
  result.originMx = player.x + CollisionW div 2
  result.originMy = player.y + CollisionH div 2
  result.viewerIsGhost = not player.alive

proc screenPointInFrame*(view: PlayerView, worldX, worldY: int): bool =
  ## Returns true when a world point lands inside this player's camera frame.
  let
    sx = worldX - view.cameraX
    sy = worldY - view.cameraY
  sx >= 0 and sx < ScreenWidth and sy >= 0 and sy < ScreenHeight

proc screenPointVisible*(sim: SimServer, view: PlayerView, worldX, worldY: int): bool =
  ## Returns true when a world point is visible in this player's rendered view.
  let
    sx = worldX - view.cameraX
    sy = worldY - view.cameraY
  if not screenPointInFrame(view, worldX, worldY):
    return false
  view.viewerIsGhost or not sim.shadowBuf[sy * ScreenWidth + sx]

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
  sim.chatMessages.setLen(0)
  for i in 0 ..< sim.players.len:
    sim.resetPlayerToHome(i)
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

proc buildRoleRevealFrame*(sim: var SimServer, playerIndex: int): seq[uint8] =
  ## Builds the role reveal interstitial frame.
  sim.fb.clearFrame(0)
  let viewerIsImp =
    playerIndex >= 0 and playerIndex < sim.players.len and
    sim.players[playerIndex].role == Imposter
  let title = if viewerIsImp: "IMPS" else: "CREWMATE"
  sim.fb.blitAsciiText(
    sim.asciiSprites,
    title,
    (ScreenWidth - title.len * 7) div 2,
    14
  )
  var shown: seq[int] = @[]
  if viewerIsImp:
    for i in 0 ..< sim.players.len:
      if sim.players[i].role == Imposter:
        shown.add(i)
  else:
    for i in 0 ..< sim.players.len:
      shown.add(i)
  if shown.len == 0:
    sim.fb.packFramebuffer()
    return sim.fb.packed
  let
    cellW = 16
    cellH = 18
    cols = min(shown.len, 8)
    totalW = cols * cellW
    startX = (ScreenWidth - totalW) div 2
    startY = 42
  for slot in 0 ..< shown.len:
    let
      playerIdx = shown[slot]
      col = slot mod cols
      row = slot div cols
      spriteX = startX + col * cellW + (cellW - SpriteSize) div 2
      spriteY = startY + row * cellH
    sim.fb.blitSpriteOutlined(
      sim.playerSprite,
      spriteX,
      spriteY,
      sim.players[playerIdx].color,
      false
    )
  sim.fb.packFramebuffer()
  sim.fb.packed

proc putVoteDot(fb: var Framebuffer, x, y: int, color: uint8) =
  ## Draws one vote marker, including visible black votes.
  if color == SpaceColor:
    fb.putPixel(x - 1, y, 12'u8)
    fb.putPixel(x, y, 2'u8)
  else:
    fb.putPixel(x, y, color)

proc putSelfMarker(fb: var Framebuffer, x, y: int, color: uint8) =
  ## Draws the local voter marker, including visible black players.
  if color == SpaceColor:
    fb.putPixel(x, y, 2'u8)
    fb.putPixel(x + 1, y, 12'u8)
  else:
    fb.putPixel(x, y, color)
    fb.putPixel(x + 1, y, color)

proc drawVoteChat*(sim: var SimServer, chatY: int) =
  ## Draws the visible voting chat messages.
  let
    chatX = 1
    chatW = ScreenWidth - 2
    chatH = ScreenHeight - chatY - 3
    iconX = chatX + 3
    textX = chatX + 20
  if chatH <= 0:
    return
  sim.fb.fillRect(chatX, chatY, chatW, chatH, 0)
  var
    visible: seq[int] = @[]
    usedH = 0
  for i in countdown(sim.chatMessages.high, 0):
    let messageH = sim.chatMessages[i].text.chatMessageHeight()
    if usedH + messageH > chatH - 4:
      break
    visible.add(i)
    usedH += messageH
  var rowY = chatY + 2
  for j in countdown(visible.high, 0):
    let
      message = sim.chatMessages[visible[j]]
      lineCount = message.text.chatLineCount()
      messageH = message.text.chatMessageHeight()
      iconY = rowY + max(0, (lineCount * 9 - SpriteSize) div 2)
    sim.fb.blitSpriteOutlined(
      sim.playerSprite,
      iconX,
      iconY,
      message.color,
      false
    )
    for lineIndex in 0 ..< lineCount:
      sim.fb.blitAsciiText(
        sim.asciiSprites,
        message.text.sliceChatLine(lineIndex),
        textX,
        rowY + lineIndex * 9
      )
    rowY += messageH

proc buildVoteFrame*(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(0)
  let n = sim.players.len
  if n == 0:
    sim.fb.packFramebuffer()
    return sim.fb.packed
  let
    cellW = 16
    cellH = 17
    cols = min(n, 8)
    rows = (n + cols - 1) div cols
    totalW = cols * cellW
    startX = (ScreenWidth - totalW) div 2
    startY = 2

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
      sim.fb.putSelfMarker(
        cx + cellW div 2 - 1,
        cy - 2,
        sim.players[pi].color
      )
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
          dotX = cx + 1 + (voterRow mod 8) * 2
          dotY = cy + SpriteSize + 2 + (voterRow div 8)
        sim.fb.putVoteDot(dotX, dotY, sim.players[vi].color)
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
        dotX = skipX + skipW + 2 + (skipVoterRow mod 8) * 2
        dotY = skipY + (skipVoterRow div 8)
      sim.fb.putVoteDot(dotX, dotY, sim.players[vi].color)
      inc skipVoterRow

  sim.drawVoteChat(skipY + 10)

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

proc finishGame*(sim: var SimServer, winner: PlayerRole, timeLimitReached = false) =
  ## Moves to game over and awards all winning players.
  if sim.phase == GameOver:
    return
  sim.phase = GameOver
  sim.winner = winner
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.timeLimitReached = timeLimitReached
  for i in 0 ..< sim.players.len:
    if sim.players[i].role == winner:
      sim.addReward(i, WinReward)

proc gameTicksElapsed*(sim: SimServer): int =
  ## Returns ticks elapsed since the current game left the lobby.
  if sim.gameStartTick < 0:
    return 0
  max(0, sim.tickCount - sim.gameStartTick)

proc maxTicksReached(sim: SimServer): bool =
  sim.config.maxTicks > 0 and sim.phase in {Playing, Voting, VoteResult} and
    sim.gameTicksElapsed() >= sim.config.maxTicks

proc checkMaxTicks(sim: var SimServer) =
  if sim.maxTicksReached():
    sim.finishGame(Imposter, timeLimitReached = true)

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
    rowH = 14
    rowsPerCol = 8
    colW = ScreenWidth div 2
    iconOffsetX = 4
    textOffsetX = 19
    startY = 16
  for i in 0 ..< n:
    let
      p = sim.players[i]
      col = i div rowsPerCol
      row = i mod rowsPerCol
      baseX = min(col, 1) * colW
      y = startY + row * rowH
      iconX = baseX + iconOffsetX
      textX = baseX + textOffsetX
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

proc renderStatePointShadowed(
  sim: SimServer,
  originMx, originMy, worldX, worldY: int
): bool {.inline.} =
  let
    dx = worldX - originMx
    dy = worldY - originMy
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return false
  for s in 1 .. steps:
    let
      rx = originMx + dx * s div steps
      ry = originMy + dy * s div steps
    if sim.isWall(rx, ry):
      return true
  false

proc renderStateWorldPointVisible(
  sim: SimServer,
  view: PlayerView,
  worldX, worldY: int
): bool {.inline.} =
  if not view.screenPointInFrame(worldX, worldY):
    return false
  view.viewerIsGhost or not sim.renderStatePointShadowed(
    view.originMx,
    view.originMy,
    worldX,
    worldY
  )

proc renderStateProgressByte(progress, totalTicks, barWidth: int): uint8 =
  if progress <= 0 or totalTicks <= 0 or barWidth <= 0:
    return 0'u8
  let filled = clamp(progress * barWidth div totalTicks, 0, barWidth)
  uint8(filled * 255 div barWidth)

proc renderStateVoteTimerByte(sim: SimServer): uint8 =
  if sim.phase != Voting or sim.config.voteTimerTicks <= 0:
    return 0'u8
  renderStateProgressByte(
    sim.voteState.voteTimer,
    sim.config.voteTimerTicks,
    ScreenWidth - 4
  )

proc renderStateKillIconByte(sim: SimServer, playerIndex: int): uint8 =
  if sim.phase != Playing or playerIndex < 0 or playerIndex >= sim.players.len:
    return 0'u8
  let player = sim.players[playerIndex]
  if player.role != Imposter or not player.alive:
    return 0'u8
  if player.killCooldown > 0: 1'u8 else: 255'u8

proc writeRenderStateHeader(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  var
    selfAlive = 0'u8
    selfRole = 0'u8
    selfScreenX = 0'u8
    selfScreenY = 0'u8
    selfVelX = 0'u8
    selfVelY = 0'u8
    killCooldown = 0'u8
    taskProgress = 0'u8
    activeTask = 0'u8
    buttonCallsUsed = 0'u8
    viewerIsGhost = 0'u8
    voteCursor = 0'u8
    skipVotes = 0
    voteTimer = 0'u8
    ejectedPlayer = 0'u8

  if playerIndex >= 0 and playerIndex < sim.players.len:
    let
      player = sim.players[playerIndex]
      view = sim.playerView(playerIndex)
      speedScale = max(1, sim.config.maxSpeed)
    selfAlive = if player.alive: 1'u8 else: 0'u8
    selfRole = uint8(ord(player.role))
    selfScreenX = uint8(clamp(player.x - SpriteDrawOffX - view.cameraX, 0, 255))
    selfScreenY = uint8(clamp(player.y - SpriteDrawOffY - view.cameraY, 0, 255))
    selfVelX = uint8((clamp(player.velX, -speedScale, speedScale) + speedScale) * 255 div (speedScale * 2))
    selfVelY = uint8((clamp(player.velY, -speedScale, speedScale) + speedScale) * 255 div (speedScale * 2))
    if sim.config.killCooldownTicks > 0:
      killCooldown = uint8(clamp(player.killCooldown * 255 div sim.config.killCooldownTicks, 0, 255))
    if sim.config.taskCompleteTicks > 0:
      taskProgress = uint8(clamp(player.taskProgress * 255 div sim.config.taskCompleteTicks, 0, 255))
    activeTask = uint8(player.activeTask + 1)
    buttonCallsUsed = uint8(player.buttonCallsUsed)
    viewerIsGhost = if view.viewerIsGhost: 1'u8 else: 0'u8

  if sim.phase == Voting and playerIndex >= 0 and playerIndex < sim.voteState.cursor.len:
    voteCursor = uint8(clamp(sim.voteState.cursor[playerIndex] + 1, 0, 255))
  if sim.phase == Voting:
    for vote in sim.voteState.votes:
      if vote == -2:
        inc skipVotes
    if sim.config.voteTimerTicks > 0:
      voteTimer = uint8(clamp(sim.voteState.voteTimer * 255 div sim.config.voteTimerTicks, 0, 255))
  if sim.phase == VoteResult:
    ejectedPlayer = uint8(clamp(sim.voteState.ejectedPlayer + 1, 0, 255))

  var offset = 0
  template put(value: uint8) =
    output[offset] = value
    inc offset

  put uint8(ord(sim.phase))
  put uint8(clamp(playerIndex + 1, 0, 255))
  put uint8(sim.players.len)
  put selfAlive
  put selfRole
  put selfScreenX
  put selfScreenY
  put selfVelX
  put selfVelY
  put killCooldown
  put taskProgress
  put activeTask
  put buttonCallsUsed
  put uint8(sim.totalTasksRemaining())
  put viewerIsGhost
  put uint8(sim.tickCount mod 256)
  put voteCursor
  put uint8(skipVotes)
  put voteTimer
  put ejectedPlayer
  put uint8(ord(sim.winner))
  put(if sim.timeLimitReached: 1'u8 else: 0'u8)
  doAssert offset == RenderStateHeaderFeatures

proc writeRenderStateGrid(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  if sim.phase != Playing or playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    view = sim.playerView(playerIndex)
    step = ScreenWidth div RenderStateGridSize
  for gy in 0 ..< RenderStateGridSize:
    for gx in 0 ..< RenderStateGridSize:
      let
        sx = gx * step + step div 2
        sy = gy * step + step div 2
        mx = view.cameraX + sx
        my = view.cameraY + sy
        index = RenderStateGridOffset + gy * RenderStateGridSize + gx
      var color = SpaceColor
      if mx >= 0 and my >= 0 and mx < MapWidth and my < MapHeight:
        let mapIdx = mapIndex(mx, my)
        color = sim.mapPixels[mapIdx] and 0x0F
        if sim.wallMask[mapIdx]:
          color = color or 0x10
        if sim.walkMask[mapIdx]:
          color = color or 0x20
      output[index] = color

proc writeRenderStatePlayerSlot(
  sim: SimServer,
  playerIndex, targetIndex, sx, sy: int,
  flags: uint8,
  output: var openArray[uint8]
) =
  let
    player = sim.players[targetIndex]
    base = RenderStatePlayerOffset + targetIndex * RenderStatePlayerFeatures
    roleFlag =
      if targetIndex == playerIndex or sim.phase == GameOver:
        if player.role == Imposter: RenderPlayerRoleImposter else: 0'u8
      else:
        0'u8
  output[base] = RenderKindPlayer
  output[base + 1] = uint8(clamp(sx, 0, 255))
  output[base + 2] = uint8(clamp(sy, 0, 255))
  output[base + 3] = player.color
  output[base + 4] = flags or roleFlag
  if targetIndex == playerIndex:
    let speedScale = max(1, sim.config.maxSpeed)
    output[base + 5] = uint8((clamp(player.velX, -speedScale, speedScale) + speedScale) * 255 div (speedScale * 2))
    output[base + 6] = uint8((clamp(player.velY, -speedScale, speedScale) + speedScale) * 255 div (speedScale * 2))
    if sim.config.killCooldownTicks > 0:
      output[base + 7] = uint8(clamp(player.killCooldown * 255 div sim.config.killCooldownTicks, 0, 255))

proc writeRenderStatePlayingPlayers(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    view = sim.playerView(playerIndex)
    cameraX = view.cameraX
    cameraY = view.cameraY
  for i in 0 ..< sim.players.len:
    let
      p = sim.players[i]
      sx = p.x - SpriteDrawOffX - cameraX
      sy = p.y - SpriteDrawOffY - cameraY
    var flags = RenderPlayerPresent
    if i == playerIndex:
      flags = flags or RenderPlayerSelf
    if p.alive:
      if i != playerIndex and
          not sim.renderStateWorldPointVisible(
            view,
            p.x + CollisionW div 2,
            p.y + CollisionH div 2
          ):
        continue
      flags = flags or RenderPlayerAlive
    elif view.viewerIsGhost:
      flags = flags or RenderPlayerGhost
    else:
      continue
    if p.flipH:
      flags = flags or RenderPlayerFlipH
    sim.writeRenderStatePlayerSlot(playerIndex, i, sx, sy, flags, output)

proc writeRenderStateUiPlayers(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  let n = sim.players.len
  if n == 0:
    return
  case sim.phase
  of Lobby:
    let startY = 26
    for i in 0 ..< n:
      let
        col = i mod 6
        row = i div 6
        sx = 5 + col * 9
        sy = startY + row * 9
      var flags = RenderPlayerPresent or RenderPlayerAlive
      if i == playerIndex:
        flags = flags or RenderPlayerSelf
      sim.writeRenderStatePlayerSlot(playerIndex, i, sx, sy, flags, output)
  of RoleReveal:
    let viewerIsImp =
      playerIndex >= 0 and playerIndex < sim.players.len and
      sim.players[playerIndex].role == Imposter
    var shown: seq[int] = @[]
    if viewerIsImp:
      for i in 0 ..< n:
        if sim.players[i].role == Imposter:
          shown.add(i)
    else:
      for i in 0 ..< n:
        shown.add(i)
    if shown.len > 0:
      let
        cellW = 16
        cellH = 18
        cols = min(shown.len, 8)
        totalW = cols * cellW
        startX = (ScreenWidth - totalW) div 2
        startY = 42
      for slot in 0 ..< shown.len:
        let
          i = shown[slot]
          col = slot mod cols
          row = slot div cols
          sx = startX + col * cellW + (cellW - SpriteSize) div 2
          sy = startY + row * cellH
        var flags = RenderPlayerPresent or RenderPlayerAlive
        if i == playerIndex:
          flags = flags or RenderPlayerSelf
        sim.writeRenderStatePlayerSlot(playerIndex, i, sx, sy, flags, output)
  of Voting:
    let
      cellW = 16
      cellH = 17
      cols = min(n, 8)
      totalW = cols * cellW
      startX = (ScreenWidth - totalW) div 2
      startY = 2
    for i in 0 ..< n:
      let
        col = i mod cols
        row = i div cols
        cx = startX + col * cellW
        cy = startY + row * cellH
        sx = cx + (cellW - SpriteSize) div 2
        sy = cy + 1
      var flags = RenderPlayerPresent
      if sim.players[i].alive:
        flags = flags or RenderPlayerAlive
      if i == playerIndex:
        flags = flags or RenderPlayerSelf
      if playerIndex >= 0 and playerIndex < sim.voteState.cursor.len and
          sim.voteState.cursor[playerIndex] == i:
        flags = flags or RenderPlayerSelected
      sim.writeRenderStatePlayerSlot(playerIndex, i, sx, sy, flags, output)
      var votes = 0
      for vote in sim.voteState.votes:
        if vote == i:
          inc votes
      output[RenderStatePlayerOffset + i * RenderStatePlayerFeatures + 7] =
        uint8(clamp(votes, 0, 255))
  of VoteResult:
    let ej = sim.voteState.ejectedPlayer
    if ej >= 0 and ej < n:
      var flags = RenderPlayerPresent or RenderPlayerSelected
      if sim.players[ej].alive:
        flags = flags or RenderPlayerAlive
      if ej == playerIndex:
        flags = flags or RenderPlayerSelf
      sim.writeRenderStatePlayerSlot(
        playerIndex,
        ej,
        ScreenWidth div 2 - SpriteSize div 2,
        ScreenHeight div 2 - SpriteSize div 2,
        flags,
        output
      )
  of GameOver:
    let
      rowH = 14
      rowsPerCol = 8
      colW = ScreenWidth div 2
      iconOffsetX = 4
      startY = 16
    for i in 0 ..< n:
      let
        col = i div rowsPerCol
        row = i mod rowsPerCol
        baseX = min(col, 1) * colW
        y = startY + row * rowH
        iconX = baseX + iconOffsetX
        iconY = y + (rowH - SpriteSize) div 2
      var flags = RenderPlayerPresent
      if sim.players[i].alive:
        flags = flags or RenderPlayerAlive
      if i == playerIndex:
        flags = flags or RenderPlayerSelf
      sim.writeRenderStatePlayerSlot(playerIndex, i, iconX, iconY, flags, output)
  of Playing:
    discard

proc writeRenderStateBodies(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  if sim.phase != Playing or playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    view = sim.playerView(playerIndex)
    cameraX = view.cameraX
    cameraY = view.cameraY
  var slot = 0
  for body in sim.bodies:
    if slot >= RenderStateBodySlots:
      break
    if not sim.renderStateWorldPointVisible(
      view,
      body.x + CollisionW div 2,
      body.y + CollisionH div 2
    ):
      continue
    let
      base = RenderStateBodyOffset + slot * RenderStateBodyFeatures
      sx = body.x - SpriteDrawOffX - cameraX
      sy = body.y - SpriteDrawOffY - cameraY
    output[base] = RenderKindBody
    output[base + 1] = uint8(clamp(sx, 0, 255))
    output[base + 2] = uint8(clamp(sy, 0, 255))
    output[base + 3] = body.color
    output[base + 4] = 1
    inc slot

proc writeRenderStateTasks(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  if sim.phase != Playing or playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    player = sim.players[playerIndex]
    view = sim.playerView(playerIndex)
    cameraX = view.cameraX
    cameraY = view.cameraY
  if player.role != Crewmate:
    return
  var slotIndex = 0
  for taskIndex in player.assignedTasks:
    if slotIndex >= RenderStateTaskSlots:
      break
    if taskIndex < 0 or taskIndex >= sim.tasks.len:
      continue
    let
      task = sim.tasks[taskIndex]
      completed =
        playerIndex < task.completed.len and task.completed[playerIndex]
      bob = [0, 0, -1, -1, -1, 0, 0, 1, 1, 1]
      bobY =
        if player.activeTask == taskIndex:
          0
        else:
          bob[(sim.tickCount div 3) mod bob.len]
      iconSx = task.x + task.w div 2 - SpriteSize div 2 - cameraX
      iconSy = task.y - SpriteSize - 2 + bobY - cameraY
      iconCenterX = task.x + task.w div 2
      iconCenterY = task.y - SpriteSize div 2 - 2 + bobY
      iconOnScreen =
        iconSx + SpriteSize > 0 and iconSy + SpriteSize > 0 and
        iconSx < ScreenWidth and iconSy < ScreenHeight
      base = RenderStateTaskOffset + slotIndex * RenderStateTaskFeatures
    var flags = RenderTaskAssigned
    if completed:
      flags = flags or RenderTaskCompleted
    else:
      flags = flags or RenderTaskIncomplete
    if player.activeTask == taskIndex:
      flags = flags or RenderTaskActive
    output[base] = RenderKindTask
    output[base + 3] = flags
    if sim.config.taskCompleteTicks > 0:
      output[base + 4] = uint8(clamp(player.taskProgress * 255 div sim.config.taskCompleteTicks, 0, 255))
    output[base + 7] = uint8(taskIndex + 1)
    if completed:
      continue
    if iconOnScreen:
      flags = flags or RenderTaskIconVisible
      output[base + 1] = uint8(clamp(iconSx, 0, 255))
      output[base + 2] = uint8(clamp(iconSy, 0, 255))
    elif sim.config.showTaskArrows:
      let
        px = float(player.x + CollisionW div 2 - view.cameraX)
        py = float(player.y + CollisionH div 2 - view.cameraY)
        dx = float(iconCenterX - view.cameraX) - px
        dy = float(iconCenterY - view.cameraY) - py
      if abs(dx) >= 0.5 or abs(dy) >= 0.5:
        var ex, ey: float
        let
          minX = 0.0
          maxX = float(ScreenWidth - 1)
          minY = 0.0
          maxY = float(ScreenHeight - 1)
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
        flags = flags or RenderTaskArrowVisible
        output[base + 5] = uint8(int(ex))
        output[base + 6] = uint8(int(ey))
    output[base + 3] = flags
    inc slotIndex

proc render*(sim: var SimServer, playerIndex: int): seq[uint8]

proc clearRenderStateSlot(
  output: var openArray[uint8],
  base, featureCount: int
) =
  for offset in 0 ..< featureCount:
    output[base + offset] = 0

proc writeRawRenderState(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  ## Internal raw state; never exposed directly.
  for i in 0 ..< output.len:
    output[i] = 0
  sim.writeRenderStateHeader(playerIndex, output)
  sim.writeRenderStateGrid(playerIndex, output)
  if sim.phase == Playing:
    sim.writeRenderStatePlayingPlayers(playerIndex, output)
    sim.writeRenderStateBodies(playerIndex, output)
    sim.writeRenderStateTasks(playerIndex, output)
  else:
    sim.writeRenderStateUiPlayers(playerIndex, output)

proc sanitizeRenderStateForPixels(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  ## Pixel-safe contract: keep only what render() drew into sim.fb, with
  ## visible UI values re-quantized to the same pixels.
  let killIcon = sim.renderStateKillIconByte(playerIndex)
  output[RenderHeaderSelfJoin] = 0'u8
  output[RenderHeaderPlayerCount] = 0'u8
  if sim.phase notin {Playing, RoleReveal, GameOver}:
    output[RenderHeaderSelfRole] = 0'u8
  if sim.phase != Playing:
    output[RenderHeaderSelfScreenX] = 0'u8
    output[RenderHeaderSelfScreenY] = 0'u8
  output[RenderHeaderSelfVelX] = 0'u8
  output[RenderHeaderSelfVelY] = 0'u8
  output[RenderHeaderKillCooldown] = 0'u8
  output[RenderHeaderTaskProgress] = 0'u8
  output[RenderHeaderActiveTask] = 0'u8
  output[RenderHeaderButtonCalls] = 0'u8
  output[RenderHeaderTickModulo] = 0'u8
  output[RenderHeaderEjectedPlayer] = 0'u8
  output[RenderHeaderWinner] =
    if sim.phase == GameOver: output[RenderHeaderWinner] else: 0'u8
  output[RenderHeaderTimeLimitCause] = 0'u8
  if sim.phase != Playing:
    output[RenderHeaderTasksRemaining] = 0'u8

  for slot in 0 ..< RenderStatePlayerSlots:
    let base = RenderStatePlayerOffset + slot * RenderStatePlayerFeatures
    let roleFlagVisible =
      sim.phase in {RoleReveal, GameOver} or
      (sim.phase == Playing and slot == playerIndex and killIcon != 0'u8)
    if not roleFlagVisible:
      output[base + RenderPlayerFlagsFeature] =
        output[base + RenderPlayerFlagsFeature] and
        (0xFF'u8 xor RenderPlayerRoleImposter)
    output[base + RenderPlayerVelXFeature] = 0'u8
    output[base + RenderPlayerVelYFeature] = 0'u8
    if sim.phase != Voting:
      output[base + RenderPlayerAuxFeature] = 0'u8

  if sim.phase == Voting:
    output[RenderHeaderVoteTimer] = sim.renderStateVoteTimerByte()
    return

  if sim.phase != Playing:
    return

  output[RenderHeaderSelfRole] =
    if killIcon != 0'u8: output[RenderHeaderSelfRole] else: 0'u8
  output[RenderHeaderKillCooldown] = killIcon

  let gridStep = ScreenWidth div RenderStateGridSize
  for gy in 0 ..< RenderStateGridSize:
    for gx in 0 ..< RenderStateGridSize:
      let
        sx = gx * gridStep + gridStep div 2
        sy = gy * gridStep + gridStep div 2
        index = RenderStateGridOffset + gy * RenderStateGridSize + gx
      output[index] = sim.fb.indices[sy * ScreenWidth + sx] and 0x0F

  if playerIndex >= 0 and playerIndex < RenderStatePlayerSlots:
    let selfBase = RenderStatePlayerOffset + playerIndex * RenderStatePlayerFeatures
    output[selfBase + RenderPlayerAuxFeature] = killIcon

  let taskProgressByte =
    if playerIndex >= 0 and playerIndex < sim.players.len:
      renderStateProgressByte(
        sim.players[playerIndex].taskProgress,
        sim.config.taskCompleteTicks,
        TaskBarWidth
      )
    else:
      0'u8
  for slot in 0 ..< RenderStateTaskSlots:
    let
      base = RenderStateTaskOffset + slot * RenderStateTaskFeatures
      flags = output[base + RenderTaskFlagsFeature]
      visibleFlags = flags and (RenderTaskIconVisible or RenderTaskArrowVisible)
    if output[base + RenderTaskKindFeature] != RenderKindTask or
        visibleFlags == 0'u8:
      output.clearRenderStateSlot(base, RenderStateTaskFeatures)
      continue

    var pixelFlags = RenderTaskAssigned or RenderTaskIncomplete or visibleFlags
    if (flags and RenderTaskActive) != 0'u8:
      pixelFlags = pixelFlags or RenderTaskActive
    output[base + RenderTaskFlagsFeature] = pixelFlags
    output[base + RenderTaskProgressFeature] =
      if (pixelFlags and RenderTaskActive) != 0'u8 and
          (pixelFlags and RenderTaskIconVisible) != 0'u8:
        taskProgressByte
      else:
        0'u8
    output[base + RenderTaskSourceIdFeature] = 0'u8
    if output[RenderHeaderTaskProgress] == 0'u8 and
        output[base + RenderTaskProgressFeature] != 0'u8:
      output[RenderHeaderTaskProgress] =
        output[base + RenderTaskProgressFeature]

proc writeRenderStateObservation*(
  sim: var SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  ## Writes a compact observation constrained to the rendered pixel frame.
  ## The framebuffer is rendered first so grid samples and quantized UI fields
  ## match what a pixel-only client could observe.
  if output.len != RenderStateFeatures:
    raise newException(
      AmongThemError,
      "Render state observation must be " & $RenderStateFeatures & " bytes."
    )
  discard sim.render(playerIndex)
  sim.writeRawRenderState(playerIndex, output)
  sim.sanitizeRenderStateForPixels(playerIndex, output)

proc render*(sim: var SimServer, playerIndex: int): seq[uint8] =
  if sim.phase == Lobby:
    return sim.buildLobbyFrame(playerIndex)
  if sim.phase == RoleReveal:
    return sim.buildRoleRevealFrame(playerIndex)
  if sim.phase == GameOver:
    return sim.buildGameOverFrame(playerIndex)
  if sim.phase == Voting:
    return sim.buildVoteFrame(playerIndex)
  if sim.phase == VoteResult:
    return sim.buildResultFrame(playerIndex)
  sim.fb.clearFrame(MapVoidColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let
    player = sim.players[playerIndex]
    view = sim.playerView(playerIndex)
    cameraX = view.cameraX
    cameraY = view.cameraY

  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let
        mx = cameraX + x
        my = cameraY + y
      if mx >= 0 and my >= 0 and mx < MapWidth and my < MapHeight:
        sim.fb.putPixel(x, y, sim.mapPixels[mapIndex(mx, my)])

  let
    viewerIsGhost = view.viewerIsGhost
  sim.castShadows(view.originMx, view.originMy, cameraX, cameraY)

  if not viewerIsGhost:
    for sy in 0 ..< ScreenHeight:
      for sx in 0 ..< ScreenWidth:
        let
          mx = cameraX + sx
          my = cameraY + sy
          idx = sy * ScreenWidth + sx
        if not sim.shadowBuf[idx]:
          continue
        if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
          continue
        if sim.wallMask[mapIndex(mx, my)]:
          continue
        sim.fb.indices[idx] = ShadowMap[sim.fb.indices[idx] and 0x0F]

  for body in sim.bodies:
    let
      bsx = body.x - SpriteDrawOffX - cameraX
      bsy = body.y - SpriteDrawOffY - cameraY
    if not sim.screenPointVisible(view, body.x + CollisionW div 2, body.y + CollisionH div 2):
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
        if not sim.screenPointVisible(view, p.x + CollisionW div 2, p.y + CollisionH div 2):
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
  result.asciiSprites = loadAsciiSprites(gameDir() / "ascii.png")

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

  result.gameMap = loadAmongMap(config.mapPath)
  result.tasks = result.gameMap.tasks
  result.vents = result.gameMap.vents
  result.rooms = result.gameMap.rooms

  let (mapImage, walkImage, wallImage) = loadMapLayers(result.gameMap)
  result.mapPixels = newSeq[uint8](MapWidth * MapHeight)
  result.mapRgba = newSeq[uint8](MapWidth * MapHeight * 4)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let
        pixel = mapImage[x, y]
        index = mapIndex(x, y)
        offset = index * 4
      result.mapPixels[index] = nearestPaletteIndex(pixel)
      result.mapRgba[offset] = pixel.r
      result.mapRgba[offset + 1] = pixel.g
      result.mapRgba[offset + 2] = pixel.b
      result.mapRgba[offset + 3] = pixel.a

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
  result.chatMessages = @[]
  result.players = @[]
  result.nextJoinOrder = 0
  result.gameStartTick = -1

proc resetToLobby*(sim: var SimServer) =
  sim.phase = Lobby
  sim.bodies = @[]
  sim.chatMessages = @[]
  sim.players = @[]
  sim.nextJoinOrder = 0
  sim.tickCount = 0
  sim.gameStartTick = -1
  sim.roleRevealTimer = 0
  sim.timeLimitReached = false
  sim.needsReregister = true
  for task in sim.tasks.mitems:
    task.completed = @[]

proc step*(sim: var SimServer, inputs: openArray[InputState], prevInputs: openArray[InputState]) =
  inc sim.tickCount

  if sim.phase == Lobby:
    if sim.players.len >= sim.config.minPlayers:
      sim.startGame()
    return

  if sim.phase == RoleReveal:
    dec sim.roleRevealTimer
    if sim.roleRevealTimer <= 0:
      sim.phase = Playing
      sim.gameStartTick = sim.tickCount
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
    sim.checkMaxTicks()
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
    sim.checkMaxTicks()
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
  sim.checkMaxTicks()

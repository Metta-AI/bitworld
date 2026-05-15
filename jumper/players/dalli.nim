import
  std/[monotimes, options, os, parseopt, random, strutils, tables, times],
  supersnappy, whisky,
  protocol

const
  DefaultAddress = "localhost"
  DefaultPort = 8080
  MaxDrainMessages = 64
  ReconnectDelayMs = 250
  WorldTileSize = 32
  LevelWidthTiles = 64
  LevelHeightTiles = 16
  ViewportWidth = 320
  ViewportHeight = 200
  PlayerBoxWidth = 20
  PlayerBoxHeight = 23
  PlayerSpriteOffsetX = 6
  PlayerSpriteOffsetY = 9
  TileObjectBase = 1000
  PlayerObjectBase = 5000
  DebugPlayerBoxObjectBase = 8000
  DebugPlayerBoxSpriteId = 900
  TiledSpriteBase = 300
  FlagGid = 15
  SeesawGid = 54
  SignGid = 60
  ProgressStepPixels = 64
  HoleLookAheadPixels = 112
  HoleMinPixels = 16
  GroundDropPixels = 18
  StuckWaitTicks = 36
  JumpCooldownTicks = 12
  BigJumpDelayMaxFrames = 4
  ObstacleLookAheadPixels = 48
  ObstacleSamplePixels = 4
  MaxObstacleScanHeight = WorldTileSize * 4
  MaxSoloObstacleHeight = WorldTileSize * 2
  BigObstacleHeight = WorldTileSize
  GreetingChanceDen = 900
  ChatCooldownMinTicks = 72
  ChatCooldownJitterTicks = 96
  FallDangerPixels = 128
  FallDangerTicks = 3
  ProgressEchoInterval = initDuration(milliseconds = 250)

  GreetingChats = ["hi", "hey", "hello", "sup"]
  StuckChats = ["help", "here", "plz"]
  PanicChats = ["oo", "oops", "yolo", "nooo..."]

type
  SpriteImage = object
    width, height: int
    label: string
    pixels: seq[uint8]

  ObjectState = object
    id: int
    x, y, z: int
    layer: int
    spriteId: int

  PlayerSight = object
    found: bool
    id: int
    screenX, screenY: int
    worldX, worldY: int
    centerX, centerY: int

  FlagSight = object
    found: bool
    centerX, centerY: int

  ObstacleScan = object
    found: bool
    height: int
    distance: int
    topY: int

  Bot = object
    rng: Rand
    name: string
    frameTick: int
    frameWidth: int
    frameHeight: int
    cameraKnown: bool
    cameraX: int
    cameraY: int
    sprites: Table[int, SpriteImage]
    objects: Table[int, ObjectState]
    lastMask: uint8
    jumpCooldown: int
    bigJumpArmed: bool
    bigJumpDelay: int
    lastWorldX: int
    lastWorldY: int
    maxWorldX: int
    maxProgressStep: int
    stuckTicks: int
    fallTicks: int
    chatCooldown: int
    pendingChat: string
    lastProgressEcho: MonoTime
    intent: string

proc readU16(data: string, offset: int): int =
  ## Reads one little endian unsigned 16 bit value.
  int(uint16(data[offset].uint8) or
    (uint16(data[offset + 1].uint8) shl 8))

proc readI16(data: string, offset: int): int =
  ## Reads one little endian signed 16 bit value.
  let value = uint16(data[offset].uint8) or
    (uint16(data[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc readU32(data: string, offset: int): int =
  ## Reads one little endian unsigned 32 bit value.
  int(uint32(data[offset].uint8) or
    (uint32(data[offset + 1].uint8) shl 8) or
    (uint32(data[offset + 2].uint8) shl 16) or
    (uint32(data[offset + 3].uint8) shl 24))

proc queryEscape(value: string): string =
  ## Escapes one query string component.
  const Hex = "0123456789ABCDEF"
  for ch in value:
    if ch.isAlphaNumeric() or ch in {'-', '_', '.', '~'}:
      result.add(ch)
    else:
      let byte = ord(ch)
      result.add('%')
      result.add(Hex[(byte shr 4) and 0x0f])
      result.add(Hex[byte and 0x0f])

proc appendQueryParam(
  url: var string,
  first: var bool,
  key, value: string
) =
  ## Appends one optional query parameter to a URL.
  if value.len == 0:
    return
  if first:
    url.add('?')
    first = false
  else:
    url.add('&')
  url.add(key.queryEscape())
  url.add('=')
  url.add(value.queryEscape())

proc addQuery(url, name, token: string, slot: int): string =
  ## Appends player query fields to a websocket URL.
  result = url
  var first = not result.contains('?')
  result.appendQueryParam(first, "name", name)
  result.appendQueryParam(first, "token", token)
  if slot >= 0:
    result.appendQueryParam(first, "slot", $slot)

proc spriteTextPacket(text: string): string =
  ## Builds a sprite protocol text input packet.
  var clean = ""
  for ch in text:
    if ch >= ' ' and ch <= '~':
      clean.add(ch)
      if clean.len == uint16.high.int:
        break
  result = newString(clean.len + 3)
  result[0] = char(0x81'u8)
  result[1] = char(clean.len and 0xff)
  result[2] = char((clean.len shr 8) and 0xff)
  for i, ch in clean:
    result[i + 3] = ch

proc playerUrl(
  address: string,
  port: int,
  name, token: string,
  slot: int
): string =
  ## Builds the Jumper player websocket URL.
  if address.startsWith("ws://") or address.startsWith("wss://"):
    return address.addQuery(name, token, slot)
  let host =
    if address.len == 0:
      DefaultAddress
    else:
      address
  ("ws://" & host & ":" & $port & "/player").addQuery(name, token, slot)

proc redactedUrl(url: string): string =
  ## Hides the token query value in a URL for logs.
  const Key = "token="
  let start = url.find(Key)
  if start < 0:
    return url
  let valueStart = start + Key.len
  var valueEnd = valueStart
  while valueEnd < url.len and url[valueEnd] notin {'&', '#'}:
    inc valueEnd
  result = url[0 ..< valueStart] & "<redacted>"
  if valueEnd < url.len:
    result.add(url[valueEnd .. ^1])

proc isTileObjectId(id: int): bool =
  ## Returns true when an object id belongs to a Tiled map cell.
  id >= TileObjectBase and
    id < TileObjectBase + LevelWidthTiles * LevelHeightTiles

proc isPlayerObjectId(id: int): bool =
  ## Returns true when an object id belongs to a player sprite.
  id >= PlayerObjectBase and id < PlayerObjectBase + 256

proc isDebugBoxObjectId(id: int): bool =
  ## Returns true when an object id belongs to a debug player box.
  id >= DebugPlayerBoxObjectBase and id < DebugPlayerBoxObjectBase + 256

proc tileFromObjectId(id: int): tuple[tx, ty: int] =
  ## Returns the Tiled cell coordinate for one tile object id.
  let index = id - TileObjectBase
  (tx: index mod LevelWidthTiles, ty: index div LevelWidthTiles)

proc gidFromSprite(spriteId: int): int =
  ## Returns the Tiled gid encoded by one tile sprite id.
  if spriteId < TiledSpriteBase:
    return 0
  spriteId - TiledSpriteBase

proc isSolidGid(gid: int): bool =
  ## Returns true when a Tiled gid should block Jumper players.
  gid != 0 and
    gid != FlagGid and
    gid != SeesawGid and
    gid != SignGid

proc initBot(name: string): Bot =
  ## Builds the initial Dalli state.
  result.rng = initRand(getTime().toUnix() xor int64(getCurrentProcessId()))
  result.name =
    if name.len > 0:
      name
    else:
      "dalli"
  result.frameWidth = ViewportWidth
  result.frameHeight = ViewportHeight
  result.sprites = initTable[int, SpriteImage]()
  result.objects = initTable[int, ObjectState]()
  result.maxProgressStep = -1
  result.lastWorldX = low(int)
  result.lastWorldY = low(int)
  result.lastProgressEcho = getMonoTime()

proc updateCamera(bot: var Bot) =
  ## Infers the camera from visible tile object ids.
  bot.cameraKnown = false
  for id, item in bot.objects.pairs:
    if not id.isTileObjectId():
      continue
    let tile = id.tileFromObjectId()
    bot.cameraX = tile.tx * WorldTileSize - item.x
    bot.cameraY = tile.ty * WorldTileSize - item.y
    bot.cameraKnown = true
    return

proc applySpritePacket(bot: var Bot, packet: string): bool =
  ## Applies one or more sprite protocol messages.
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
      let raw = supersnappy.uncompress(compressed)
      var pixels = newSeq[uint8](raw.len)
      for i, ch in raw:
        pixels[i] = ch.uint8
      if pixels.len != width * height * 4:
        return false
      bot.sprites[spriteId] = SpriteImage(
        width: width,
        height: height,
        label: label,
        pixels: pixels
      )
    of 0x02:
      if offset + 11 > packet.len:
        return false
      let item = ObjectState(
        id: packet.readU16(offset),
        x: packet.readI16(offset + 2),
        y: packet.readI16(offset + 4),
        z: packet.readI16(offset + 6),
        layer: packet[offset + 8].int,
        spriteId: packet.readU16(offset + 9)
      )
      bot.objects[item.id] = item
      offset += 11
    of 0x03:
      if offset + 2 > packet.len:
        return false
      bot.objects.del(packet.readU16(offset))
      offset += 2
    of 0x04:
      bot.objects.clear()
    of 0x05:
      if offset + 5 > packet.len:
        return false
      bot.frameWidth = packet.readU16(offset + 1)
      bot.frameHeight = packet.readU16(offset + 3)
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return false
      offset += 3
    else:
      return false
  bot.updateCamera()
  true

proc acceptServerMessage(
  ws: WebSocket,
  message: Message,
  bot: var Bot
): bool =
  ## Handles one websocket message from the Jumper server.
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
  ## Receives and applies queued sprite protocol updates.
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

proc tileObject(bot: Bot, tx, ty: int): ObjectState =
  ## Returns the visible tile object for one map cell.
  if tx < 0 or ty < 0 or tx >= LevelWidthTiles or ty >= LevelHeightTiles:
    return ObjectState()
  let id = TileObjectBase + ty * LevelWidthTiles + tx
  bot.objects.getOrDefault(id, ObjectState())

proc solidTile(bot: Bot, tx, ty: int): bool =
  ## Returns true when a visible map cell is solid.
  let item = bot.tileObject(tx, ty)
  if item.id == 0:
    return false
  item.spriteId.gidFromSprite().isSolidGid()

proc solidAt(bot: Bot, worldX, worldY: int): bool =
  ## Returns true when a visible world pixel is inside solid terrain.
  if worldX < 0 or worldY < 0:
    return false
  bot.solidTile(worldX div WorldTileSize, worldY div WorldTileSize)

proc players(bot: Bot): seq[PlayerSight] =
  ## Returns visible player boxes in world coordinates.
  if not bot.cameraKnown:
    return
  var foundDebug = false
  for id, item in bot.objects.pairs:
    if id.isDebugBoxObjectId() and item.spriteId == DebugPlayerBoxSpriteId:
      foundDebug = true
      result.add(PlayerSight(
        found: true,
        id: id - DebugPlayerBoxObjectBase,
        screenX: item.x,
        screenY: item.y,
        worldX: bot.cameraX + item.x,
        worldY: bot.cameraY + item.y,
        centerX: bot.cameraX + item.x + PlayerBoxWidth div 2,
        centerY: bot.cameraY + item.y + PlayerBoxHeight div 2
      ))
  if foundDebug:
    return
  for id, item in bot.objects.pairs:
    if not id.isPlayerObjectId():
      continue
    let
      boxScreenX = item.x + PlayerSpriteOffsetX
      boxScreenY = item.y + PlayerSpriteOffsetY
    result.add(PlayerSight(
      found: true,
      id: id - PlayerObjectBase,
      screenX: boxScreenX,
      screenY: boxScreenY,
      worldX: bot.cameraX + boxScreenX,
      worldY: bot.cameraY + boxScreenY,
      centerX: bot.cameraX + boxScreenX + PlayerBoxWidth div 2,
      centerY: bot.cameraY + boxScreenY + PlayerBoxHeight div 2
    ))

proc ownPlayer(bot: Bot): PlayerSight =
  ## Selects the player closest to the camera center as Dalli.
  let seen = bot.players()
  var bestScore = high(int)
  for player in seen:
    let
      centerScreenX = player.screenX + PlayerBoxWidth div 2
      centerScreenY = player.screenY + PlayerBoxHeight div 2
      dx = centerScreenX - bot.frameWidth div 2
      dy = centerScreenY - bot.frameHeight div 2
      score = dx * dx + dy * dy
    if score < bestScore:
      bestScore = score
      result = player

proc otherPlayers(bot: Bot, own: PlayerSight): seq[PlayerSight] =
  ## Returns visible players other than Dalli.
  for player in bot.players():
    if not own.found or player.id != own.id:
      result.add(player)

proc visibleFlag(bot: Bot): FlagSight =
  ## Returns the visible goal flag, if it is currently in the sprite view.
  for id, item in bot.objects.pairs:
    if not id.isTileObjectId():
      continue
    if item.spriteId.gidFromSprite() != FlagGid:
      continue
    let tile = id.tileFromObjectId()
    return FlagSight(
      found: true,
      centerX: tile.tx * WorldTileSize + WorldTileSize div 2,
      centerY: tile.ty * WorldTileSize + WorldTileSize div 2
    )

proc groundNear(bot: Bot, x, y, maxDrop: int): bool =
  ## Returns true when ground appears close under one world pixel.
  for dy in 0 .. maxDrop:
    if bot.solidAt(x, y + dy):
      return true

proc hasTileSupport(bot: Bot, player: PlayerSight): bool =
  ## Returns true when terrain supports one player box.
  let y = player.worldY + PlayerBoxHeight + 1
  for x in countup(player.worldX + 2, player.worldX + PlayerBoxWidth - 2, 4):
    if bot.groundNear(x, y, 2):
      return true

proc hasPlayerSupport(
  bot: Bot,
  player: PlayerSight,
  others: openArray[PlayerSight]
): bool =
  ## Returns true when another player supports one player box.
  let footY = player.worldY + PlayerBoxHeight
  for other in others:
    if footY >= other.worldY - 1 and footY <= other.worldY + 3 and
        player.worldX < other.worldX + PlayerBoxWidth and
        player.worldX + PlayerBoxWidth > other.worldX:
      return true

proc onGround(
  bot: Bot,
  player: PlayerSight,
  others: openArray[PlayerSight]
): bool =
  ## Returns true when Dalli appears to be standing.
  bot.hasTileSupport(player) or bot.hasPlayerSupport(player, others)

proc holeAhead(bot: Bot, player: PlayerSight): bool =
  ## Returns true when a sustained gap is visible ahead.
  let footY = player.worldY + PlayerBoxHeight + 2
  var gapPixels = 0
  for dx in countup(PlayerBoxWidth + 6, HoleLookAheadPixels, 8):
    let x = player.worldX + dx
    if bot.groundNear(x, footY, GroundDropPixels):
      gapPixels = 0
    else:
      gapPixels += 8
      if gapPixels >= HoleMinPixels:
        return true

proc holeBehind(bot: Bot, player: PlayerSight): bool =
  ## Returns true when a sustained gap is visible behind Dalli.
  let footY = player.worldY + PlayerBoxHeight + 2
  var gapPixels = 0
  for dx in countup(PlayerBoxWidth + 6, HoleLookAheadPixels, 8):
    let x = player.worldX + PlayerBoxWidth - dx
    if bot.groundNear(x, footY, GroundDropPixels):
      gapPixels = 0
    else:
      gapPixels += 8
      if gapPixels >= HoleMinPixels:
        return true

proc scanObstacleColumn(bot: Bot, x, footY: int): ObstacleScan =
  ## Measures one solid column in front of Dalli from feet upward.
  let
    bottomY = footY - 2
    scanTopY = max(0, footY - MaxObstacleScanHeight)
  var hit = false
  for y in countdown(bottomY, scanTopY):
    if bot.solidAt(x, y):
      hit = true
      result.topY = y
    elif hit:
      break

  if hit:
    result.found = true
    result.height = footY - result.topY

proc columnBlocksPlayer(bot: Bot, x: int, player: PlayerSight): bool =
  ## Returns true when a column blocks Dalli's current box path.
  for y in countup(player.worldY + 2, player.worldY + PlayerBoxHeight - 2, 4):
    if bot.solidAt(x, y):
      return true

proc obstacleAhead(bot: Bot, player: PlayerSight): ObstacleScan =
  ## Measures the nearest terrain obstacle in front of Dalli.
  let
    startX = player.worldX + PlayerBoxWidth + 2
    endX = min(
      LevelWidthTiles * WorldTileSize - 1,
      player.worldX + PlayerBoxWidth + ObstacleLookAheadPixels
    )
    footY = player.worldY + PlayerBoxHeight

  for x in countup(startX, endX, ObstacleSamplePixels):
    if not bot.columnBlocksPlayer(x, player):
      continue
    result = bot.scanObstacleColumn(x, footY)
    if result.found:
      result.distance = x - startX
      return

proc visibleHelper(
  bot: Bot,
  player: PlayerSight,
  others: openArray[PlayerSight]
): PlayerSight =
  ## Picks a visible teammate that can be used as a step.
  var bestScore = high(int)
  for other in others:
    let
      dx = abs(other.centerX - player.centerX)
      dy = abs(other.centerY - player.centerY)
      score = dx * 3 + dy
    if dx <= 140 and dy <= 90 and score < bestScore:
      bestScore = score
      result = other

proc updateProgress(bot: var Bot, player: PlayerSight) =
  ## Prints each newly reached 64 pixel progress bucket once.
  if not player.found:
    return
  bot.maxWorldX = max(bot.maxWorldX, player.worldX)
  let progressStep = bot.maxWorldX div ProgressStepPixels
  if progressStep <= bot.maxProgressStep:
    return
  let now = getMonoTime()
  if bot.maxProgressStep >= 0 and
      now - bot.lastProgressEcho < ProgressEchoInterval:
    return
  bot.maxProgressStep = progressStep
  bot.lastProgressEcho = now
  echo bot.name, " max64=", progressStep, " maxX=", bot.maxWorldX
  flushFile(stdout)

proc updateStuck(bot: var Bot, player: PlayerSight) =
  ## Tracks whether Dalli is still making rightward progress.
  if not player.found:
    bot.stuckTicks = 0
    bot.fallTicks = 0
    return
  if bot.lastWorldX != low(int) and player.worldX <= bot.lastWorldX + 1:
    inc bot.stuckTicks
  else:
    bot.stuckTicks = 0
  bot.lastWorldX = player.worldX
  if bot.lastWorldY != low(int) and player.worldY > bot.lastWorldY:
    inc bot.fallTicks
  else:
    bot.fallTicks = 0
  bot.lastWorldY = player.worldY

proc noLandingBelow(bot: Bot, player: PlayerSight): bool =
  ## Returns true when no landing terrain is visible below Dalli.
  let y = player.worldY + PlayerBoxHeight + 2
  for x in countup(player.worldX + 2, player.worldX + PlayerBoxWidth - 2, 4):
    if bot.groundNear(x, y, FallDangerPixels):
      return false
  true

proc fallingDanger(bot: Bot, player: PlayerSight, grounded: bool): bool =
  ## Returns true when Dalli appears to be falling into open air.
  not grounded and bot.fallTicks >= FallDangerTicks and
    bot.noLandingBelow(player)

proc randomChat(bot: var Bot, choices: openArray[string]): string =
  ## Picks one short chat phrase.
  choices[bot.rng.rand(choices.high)]

proc queueChat(bot: var Bot, choices: openArray[string]) =
  ## Queues one rate-limited chat phrase.
  if bot.pendingChat.len > 0 or bot.chatCooldown > 0:
    return
  bot.pendingChat = bot.randomChat(choices)
  bot.chatCooldown =
    ChatCooldownMinTicks + bot.rng.rand(ChatCooldownJitterTicks)

proc maybeGreet(bot: var Bot, others: openArray[PlayerSight]) =
  ## Occasionally greets another visible player.
  if others.len == 0 or bot.chatCooldown > 0 or bot.pendingChat.len > 0:
    return
  if bot.rng.rand(GreetingChanceDen - 1) == 0:
    bot.queueChat(GreetingChats)

proc jumpButton(bot: var Bot, grounded: bool): uint8 =
  ## Returns a one-frame jump press when it is available.
  if not grounded or bot.jumpCooldown > 0:
    return 0
  if (bot.lastMask and ButtonA) != 0:
    return 0
  bot.jumpCooldown = JumpCooldownTicks
  ButtonA

proc resetBigJump(bot: var Bot) =
  ## Clears any pending randomized big jump delay.
  bot.bigJumpArmed = false
  bot.bigJumpDelay = 0

proc bigJumpButton(bot: var Bot, grounded: bool): uint8 =
  ## Returns a jump button after a random big jump delay.
  if not grounded:
    bot.resetBigJump()
    return 0
  if not bot.bigJumpArmed:
    bot.bigJumpArmed = true
    bot.bigJumpDelay = bot.rng.rand(BigJumpDelayMaxFrames)
  if bot.bigJumpDelay > 0:
    dec bot.bigJumpDelay
    return 0
  result = bot.jumpButton(grounded)
  if result != 0:
    bot.resetBigJump()

proc moveToward(targetX, currentX: int): uint8 =
  ## Returns a horizontal input mask aimed at one x coordinate.
  if targetX < currentX - 6:
    ButtonLeft
  elif targetX > currentX + 6:
    ButtonRight
  else:
    0

proc applyForwardJumping(
  bot: var Bot,
  mask: uint8,
  grounded, hole, canJumpObstacle, stuckJump: bool,
  obstacle: ObstacleScan
): uint8 =
  ## Adds any forward jump needed for the current rightward route.
  result = mask
  if hole:
    bot.resetBigJump()
    result = result or bot.jumpButton(grounded)
  elif canJumpObstacle and obstacle.height >= BigObstacleHeight:
    result = result or bot.bigJumpButton(grounded)
  elif canJumpObstacle or stuckJump:
    bot.resetBigJump()
    result = result or bot.jumpButton(grounded)
  else:
    bot.resetBigJump()

proc seekFlagMask(
  bot: var Bot,
  own: PlayerSight,
  flag: FlagSight,
  grounded, hole, canJumpObstacle, stuckJump: bool,
  obstacle: ObstacleScan
): uint8 =
  ## Steers toward the visible goal flag instead of blindly running right.
  result = moveToward(flag.centerX, own.centerX)
  if result == ButtonRight:
    return bot.applyForwardJumping(
      result,
      grounded,
      hole,
      canJumpObstacle,
      stuckJump,
      obstacle
    )
  bot.resetBigJump()
  if result == ButtonLeft and bot.holeBehind(own):
    return bot.applyForwardJumping(
      ButtonRight,
      grounded,
      hole,
      canJumpObstacle,
      stuckJump,
      obstacle
    )
  if result == 0 and flag.centerY < own.centerY - PlayerBoxHeight div 2:
    result = result or bot.jumpButton(grounded)

proc decideMask(bot: var Bot): uint8 =
  ## Decides Dalli's next input mask from sprite protocol state.
  let own = bot.ownPlayer()
  if not own.found:
    bot.intent = "searching"
    bot.resetBigJump()
    return 0

  bot.updateProgress(own)
  bot.updateStuck(own)
  if bot.jumpCooldown > 0:
    dec bot.jumpCooldown
  if bot.chatCooldown > 0:
    dec bot.chatCooldown

  let
    others = bot.otherPlayers(own)
    grounded = bot.onGround(own, others)
    hole = bot.holeAhead(own)
    obstacle = bot.obstacleAhead(own)
    blocked = obstacle.found
    canJumpObstacle =
      blocked and obstacle.height <= MaxSoloObstacleHeight
    helper = bot.visibleHelper(own, others)
    flag = bot.visibleFlag()
    needsHelp = grounded and blocked and not canJumpObstacle
    stuckJump = grounded and bot.stuckTicks >= StuckWaitTicks

  bot.maybeGreet(others)
  if bot.fallingDanger(own, grounded):
    bot.queueChat(PanicChats)

  if flag.found:
    let flagDirection = moveToward(flag.centerX, own.centerX)
    if flagDirection != ButtonRight:
      bot.intent = "flag"
      return bot.seekFlagMask(
        own,
        flag,
        grounded,
        hole,
        canJumpObstacle,
        stuckJump,
        obstacle
      )

  if needsHelp and not helper.found:
    bot.intent = "waiting"
    bot.queueChat(StuckChats)
    bot.resetBigJump()
    return 0

  if needsHelp and helper.found:
    bot.intent = "climb"
    bot.queueChat(StuckChats)
    result = moveToward(helper.centerX, own.centerX)
    if result == 0:
      result = ButtonRight
    if abs(helper.centerX - own.centerX) <= 34:
      result = result or bot.bigJumpButton(grounded)
    else:
      bot.resetBigJump()
    return result

  bot.intent =
    if hole:
      "gap"
    elif blocked:
      if canJumpObstacle:
        "jump"
      else:
        "wall"
    else:
      "run"
  result = ButtonRight
  result = bot.applyForwardJumping(
    result,
    grounded,
    hole,
    canJumpObstacle,
    stuckJump,
    obstacle
  )

proc runBot(
  address: string,
  port: int,
  name, token: string,
  slot, maxSteps: int
) =
  ## Connects Dalli to the Jumper player websocket.
  let endpoint = playerUrl(address, port, name, token, slot)
  while true:
    try:
      var bot = initBot(name)
      echo bot.name, " connecting to ", endpoint.redactedUrl()
      flushFile(stdout)
      let ws = newWebSocket(endpoint)
      echo bot.name, " connected"
      flushFile(stdout)
      var lastMask = 0xff'u8
      while true:
        if not ws.receiveUpdates(bot):
          continue
        let nextMask = bot.decideMask()
        bot.lastMask = nextMask
        if nextMask != lastMask:
          ws.send(blobFromMask(nextMask), BinaryMessage)
          lastMask = nextMask
        if bot.pendingChat.len > 0:
          ws.send(spriteTextPacket(bot.pendingChat), BinaryMessage)
          bot.pendingChat.setLen(0)
        if maxSteps > 0 and bot.frameTick >= maxSteps:
          ws.close()
          return
    except CatchableError as e:
      echo name, " reconnecting: ", e.msg
      flushFile(stdout)
      sleep(ReconnectDelayMs)

when isMainModule:
  var
    address = DefaultAddress
    port = DefaultPort
    name = "dalli"
    token = ""
    slot = -1
    maxSteps = 0
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address", "url", "player-url", "socket":
        address = val
      of "port":
        port = parseInt(val)
      of "name":
        name = val
      of "token":
        token = val
      of "slot":
        slot = parseInt(val)
      of "max-steps":
        maxSteps = parseInt(val)
      of "gui":
        discard
      else:
        discard
    of cmdArgument:
      discard
    of cmdShortOption:
      discard
    of cmdEnd:
      discard
  runBot(address, port, name, token, slot, maxSteps)

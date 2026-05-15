import
  std/[math, options, os, parseopt, random, strutils, tables, times],
  supersnappy, whisky,
  protocol

const
  SpritePlayerPath = "/sprite_player"
  ShipSpriteBase = 100
  AsteroidObjectBase = 1000
  ShipObjectBase = 2000
  BulletObjectBase = 3000
  MaxObjects = 10000
  DirectionCount = 16
  # atan2(DirY[i], DirX[i]) for each of the 16 directions
  DirectionX: array[DirectionCount, float] = [
    0, 98, 181, 236, 256, 236, 181, 98,
    0, -98, -181, -236, -256, -236, -181, -98
  ]
  DirectionY: array[DirectionCount, float] = [
    -256, -236, -181, -98, 0, 98, 181, 236,
    256, 236, 181, 98, 0, -98, -181, -236
  ]

type
  ObjectState = object
    present: bool
    x: int
    y: int
    spriteId: int

  SpriteInfo = object
    defined: bool
    width: int
    height: int
    label: string

  Bot = object
    rng: Rand
    frameTick: int
    objects: seq[ObjectState]
    sprites: seq[SpriteInfo]
    lastMask: uint8
    viewportWidth: int
    viewportHeight: int
    facingAngle: float
    facingKnown: bool
    targetId: int
    targetLockTicks: int

proc ensureObject(bot: var Bot, id: int) =
  if id >= bot.objects.len:
    bot.objects.setLen(id + 1)

proc ensureSprite(bot: var Bot, id: int) =
  if id >= bot.sprites.len:
    bot.sprites.setLen(id + 1)

proc readU16(data: string, offset: int): int =
  if offset + 2 > data.len: return 0
  int(uint16(data[offset].uint8) or (uint16(data[offset + 1].uint8) shl 8))

proc readI16(data: string, offset: int): int =
  let v = uint16(data[offset].uint8) or (uint16(data[offset + 1].uint8) shl 8)
  int(cast[int16](v))

proc readU32(data: string, offset: int): int =
  if offset + 4 > data.len: return 0
  int(uint32(data[offset].uint8) or
    (uint32(data[offset + 1].uint8) shl 8) or
    (uint32(data[offset + 2].uint8) shl 16) or
    (uint32(data[offset + 3].uint8) shl 24))

proc parseMessages(bot: var Bot, data: string): bool =
  if data.len == 0:
    return false
  var offset = 0
  var gotObject = false
  while offset < data.len:
    let msgType = data[offset].uint8
    inc offset
    case msgType
    of 0x01:
      if offset + 10 > data.len: return gotObject
      let
        spriteId = data.readU16(offset)
        width = data.readU16(offset + 2)
        height = data.readU16(offset + 4)
        compLen = data.readU32(offset + 6)
      offset += 10
      if offset + compLen > data.len: return gotObject
      offset += compLen
      if offset + 2 > data.len: return gotObject
      let labelLen = data.readU16(offset)
      offset += 2
      let label =
        if labelLen > 0 and offset + labelLen <= data.len:
          data[offset ..< offset + labelLen]
        else:
          ""
      offset += labelLen
      bot.ensureSprite(spriteId)
      bot.sprites[spriteId] = SpriteInfo(
        defined: true, width: width, height: height, label: label
      )
    of 0x02:
      if offset + 11 > data.len: return gotObject
      let
        objectId = data.readU16(offset)
        x = data.readI16(offset + 2)
        y = data.readI16(offset + 4)
      discard data.readI16(offset + 6)
      discard data[offset + 8].uint8
      let spriteId = data.readU16(offset + 9)
      offset += 11
      if objectId < MaxObjects:
        bot.ensureObject(objectId)
        bot.objects[objectId] = ObjectState(
          present: true, x: x, y: y, spriteId: spriteId
        )
        gotObject = true
    of 0x03:
      if offset + 2 > data.len: return gotObject
      let objectId = data.readU16(offset)
      offset += 2
      if objectId < bot.objects.len:
        bot.objects[objectId].present = false
    of 0x04:
      for obj in bot.objects.mitems:
        obj.present = false
      gotObject = true
    of 0x05:
      if offset + 5 > data.len: return gotObject
      let layer = data[offset].uint8
      if layer == 0:
        bot.viewportWidth = data.readU16(offset + 1)
        bot.viewportHeight = data.readU16(offset + 3)
      offset += 5
    of 0x06:
      if offset + 3 > data.len: return gotObject
      offset += 3
    else:
      return offset > 1
  offset > 1

proc updateFacing(bot: var Bot) =
  # Our ship is always at (60, 60) in the player view (center - sprite half)
  # Find the ship object at exactly that position
  for i in ShipObjectBase ..< min(ShipObjectBase + 100, bot.objects.len):
    if not bot.objects[i].present:
      continue
    let obj = bot.objects[i]
    if abs(obj.x - 60) <= 1 and abs(obj.y - 60) <= 1:
      let dirIndex = (obj.spriteId - ShipSpriteBase) mod 32 div 2
      if dirIndex >= 0 and dirIndex < DirectionCount:
        bot.facingAngle = arctan2(DirectionY[dirIndex], DirectionX[dirIndex])
        bot.facingKnown = true
      return

proc normalizeAngle(a: float): float =
  var r = a
  while r > PI: r -= 2.0 * PI
  while r < -PI: r += 2.0 * PI
  r

proc acquireTarget(bot: var Bot) =
  let
    cx = bot.viewportWidth div 2
    cy = bot.viewportHeight div 2
  # Keep current target if still visible and on-screen
  if bot.targetId >= AsteroidObjectBase and bot.targetId < bot.objects.len and
      bot.objects[bot.targetId].present:
    let obj = bot.objects[bot.targetId]
    if obj.x >= 0 and obj.x < bot.viewportWidth and
        obj.y >= 0 and obj.y < bot.viewportHeight:
      inc bot.targetLockTicks
      return
  var bestDist = high(int)
  bot.targetId = -1
  bot.targetLockTicks = 0
  for i in AsteroidObjectBase ..< min(AsteroidObjectBase + 1000, bot.objects.len):
    if not bot.objects[i].present:
      continue
    let
      obj = bot.objects[i]
    if obj.x < 0 or obj.x >= bot.viewportWidth or
        obj.y < 0 or obj.y >= bot.viewportHeight:
      continue
    let
      dx = obj.x - cx
      dy = obj.y - cy
      dist = dx * dx + dy * dy
    if dist < bestDist and dist > 16:
      bestDist = dist
      bot.targetId = i

proc decideMask(bot: var Bot): uint8 =
  bot.updateFacing()
  bot.acquireTarget()

  let
    cx = bot.viewportWidth div 2
    cy = bot.viewportHeight div 2

  if not bot.facingKnown:
    result = ButtonUp
    return

  if bot.targetId < 0 or bot.targetId >= bot.objects.len or
      not bot.objects[bot.targetId].present:
    result = ButtonUp
    if bot.frameTick mod 120 < 60:
      result = result or ButtonRight
    return

  let
    obj = bot.objects[bot.targetId]
    dx = obj.x - cx
    dy = obj.y - cy
    dist = sqrt(float(dx * dx + dy * dy))
    targetAngle = arctan2(float(dy), float(dx))
    angleDiff = normalizeAngle(targetAngle - bot.facingAngle)

  if abs(angleDiff) > 0.4:
    if angleDiff > 0:
      result = ButtonRight
    else:
      result = ButtonLeft
  else:
    result = ButtonUp or ButtonA
  if bot.frameTick < 100 and bot.frameTick mod 6 == 0:
    echo "f", bot.frameTick, " facing=", bot.facingKnown, " dir=", int(bot.facingAngle*180/PI),
      " tgt(", obj.x, ",", obj.y, ") ang=", int(targetAngle*180/PI),
      " diff=", int(angleDiff*180/PI), " mask=", result

proc playerInputBlob(mask: uint8): string =
  result = newString(2)
  result[0] = char(0x84'u8)
  result[1] = char(mask and 0x7F)

proc queryEscape(value: string): string =
  const Hex = "0123456789ABCDEF"
  for ch in value:
    if ch.isAlphaNumeric() or ch in {'-', '_', '.', '~'}:
      result.add(ch)
    else:
      let byte = ord(ch)
      result.add('%')
      result.add(Hex[(byte shr 4) and 0x0f])
      result.add(Hex[byte and 0x0f])

proc connectUrl(address: string, port: int, name, token: string): string =
  result = "ws://" & address & ":" & $port & SpritePlayerPath
  result.add("?name=" & name.queryEscape())
  if token.len > 0:
    result.add("&token=" & token.queryEscape())

proc runBot(
  address = "localhost",
  port = 8080,
  url = "",
  name = "shooter",
  token = "",
  maxSteps = 0
) =
  let endpoint =
    if url.len > 0: url
    else: connectUrl(address, port, name, token)
  var connected = false
  while true:
    try:
      echo "shooter connecting to ", endpoint
      var bot = Bot(
        rng: initRand(getTime().toUnix() xor int64(getCurrentProcessId())),
        viewportWidth: 128,
        viewportHeight: 128
      )
      let ws = newWebSocket(endpoint)
      connected = true
      while true:
        let msg = ws.receiveMessage(-1)
        if msg.isNone:
          break
        let message = msg.get
        if message.kind != BinaryMessage:
          continue
        if not bot.parseMessages(message.data):
          continue
        inc bot.frameTick
        let mask = bot.decideMask()
        ws.send(playerInputBlob(mask), BinaryMessage)
        bot.lastMask = mask
        if maxSteps > 0 and bot.frameTick >= maxSteps:
          ws.close()
          return
      if connected:
        echo "shooter: game ended"
        return
    except CatchableError as e:
      if connected:
        echo "shooter: disconnected after play: ", e.msg
        return
      echo "shooter reconnecting after error: ", e.msg
      sleep(250)

when isMainModule:
  var
    address = "localhost"
    port = 8080
    url = getEnv("COGAMES_ENGINE_WS_URL")
    name = "shooter"
    token = ""
    maxSteps = 0

  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = value
      of "port": port = parseInt(value)
      of "url": url = value
      of "name": name = value
      of "token": token = value
      of "max-steps": maxSteps = parseInt(value)
      else: discard
    else: discard

  runBot(address, port, url, name, token, maxSteps)

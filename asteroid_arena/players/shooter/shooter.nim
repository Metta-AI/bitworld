import
  std/[math, options, os, parseopt, random, strutils, tables, times],
  supersnappy, whisky,
  protocol

const
  SpritePlayerPath = "/sprite_player"
  AsteroidObjectBase = 1000
  ShipObjectBase = 2000
  BulletObjectBase = 3000
  MaxObjects = 10000
  ScanRange = 60
  AimDeadband = 6

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
  var offset = 0
  var gotObject = false
  while offset < data.len:
    let msgType = data[offset].uint8
    inc offset
    case msgType
    of 0x01: # Define Sprite
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
    of 0x02: # Define Object
      if offset + 11 > data.len: return gotObject
      let
        objectId = data.readU16(offset)
        x = data.readI16(offset + 2)
        y = data.readI16(offset + 4)
      discard data.readI16(offset + 6) # z
      discard data[offset + 8].uint8 # layer
      let spriteId = data.readU16(offset + 9)
      offset += 11
      if objectId < MaxObjects:
        bot.ensureObject(objectId)
        bot.objects[objectId] = ObjectState(
          present: true, x: x, y: y, spriteId: spriteId
        )
        gotObject = true
    of 0x03: # Delete Object
      if offset + 2 > data.len: return gotObject
      let objectId = data.readU16(offset)
      offset += 2
      if objectId < bot.objects.len:
        bot.objects[objectId].present = false
    of 0x04: # Clear Objects
      for obj in bot.objects.mitems:
        obj.present = false
      gotObject = true
    of 0x05: # Set Viewport
      if offset + 5 > data.len: return gotObject
      discard data[offset].uint8 # layer
      bot.viewportWidth = data.readU16(offset + 1)
      bot.viewportHeight = data.readU16(offset + 3)
      offset += 5
    of 0x06: # Define Layer
      if offset + 3 > data.len: return gotObject
      offset += 3
    else:
      return gotObject
  gotObject

proc findNearestAsteroid(bot: Bot): tuple[x, y: int, found: bool] =
  let
    cx = bot.viewportWidth div 2
    cy = bot.viewportHeight div 2
  var
    bestDist = high(int)
    foundX = 0
    foundY = 0
    found = false
  for i in AsteroidObjectBase ..< min(AsteroidObjectBase + 500, bot.objects.len):
    if not bot.objects[i].present:
      continue
    let
      obj = bot.objects[i]
      dx = obj.x - cx
      dy = obj.y - cy
      dist = dx * dx + dy * dy
    if dist < bestDist and dist > 4:
      bestDist = dist
      foundX = obj.x
      foundY = obj.y
      found = true
  (foundX, foundY, found)

proc decideMask(bot: var Bot): uint8 =
  let
    cx = bot.viewportWidth div 2
    cy = bot.viewportHeight div 2
    target = bot.findNearestAsteroid()

  if target.found:
    let
      dx = target.x - cx
      dy = target.y - cy

    if dx > AimDeadband:
      result = result or ButtonRight
    elif dx < -AimDeadband:
      result = result or ButtonLeft
    if dy < -AimDeadband:
      result = result or ButtonUp
    elif dy > AimDeadband:
      result = result or ButtonDown
    result = result or ButtonA
  else:
    result = ButtonUp or ButtonA
    if bot.frameTick mod 48 < 24:
      result = result or ButtonRight

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
  name = "shooter",
  token = "",
  maxSteps = 0
) =
  let endpoint = connectUrl(address, port, name, token)
  while true:
    try:
      echo "shooter connecting to ", endpoint
      var bot = Bot(
        rng: initRand(getTime().toUnix() xor int64(getCurrentProcessId())),
        viewportWidth: 128,
        viewportHeight: 128
      )
      let ws = newWebSocket(endpoint)
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
        if mask != bot.lastMask:
          ws.send(playerInputBlob(mask), BinaryMessage)
          bot.lastMask = mask
        if maxSteps > 0 and bot.frameTick >= maxSteps:
          ws.close()
          return
    except CatchableError as e:
      echo "shooter reconnecting after error: ", e.msg
      sleep(250)

when isMainModule:
  var
    address = "localhost"
    port = 8080
    name = "shooter"
    token = ""
    maxSteps = 0

  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = value
      of "port": port = parseInt(value)
      of "name": name = value
      of "token": token = value
      of "max-steps": maxSteps = parseInt(value)
      else: discard
    else: discard

  runBot(address, port, name, token, maxSteps)

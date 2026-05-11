import
  std/[math, options, os, parseopt, random, strutils, times],
  whisky,
  protocol

const
  FrameBytes = ScreenWidth * ScreenHeight div 2
  BackgroundColor = 12'u8
  HudBackdropColor = 1'u8
  AsteroidFillColor = 13'u8
  AsteroidOutlineColor = 15'u8
  CenterX = ScreenWidth div 2
  CenterY = ScreenHeight div 2
  ScanRadius = 55
  AimDeadband = 8

type
  Bot = object
    rng: Rand
    frameTick: int
    pixels: array[ScreenWidth * ScreenHeight, uint8]
    lastMask: uint8

proc unpackFrame(bot: var Bot, data: string) =
  if data.len != FrameBytes:
    return
  for i in 0 ..< FrameBytes:
    let byte = data[i].uint8
    bot.pixels[i * 2] = byte and 0x0F
    bot.pixels[i * 2 + 1] = (byte shr 4) and 0x0F

proc pixelAt(bot: Bot, x, y: int): uint8 =
  if x < 0 or x >= ScreenWidth or y < 0 or y >= ScreenHeight:
    return BackgroundColor
  bot.pixels[y * ScreenWidth + x]

proc isAsteroid(color: uint8): bool =
  color == AsteroidFillColor or color == AsteroidOutlineColor

proc findNearestAsteroid(bot: Bot): tuple[x, y: int, found: bool] =
  var
    bestDist = high(int)
    foundX = 0
    foundY = 0
    found = false
  let step = 2
  for y in countup(max(0, CenterY - ScanRadius), min(ScreenHeight - 1, CenterY + ScanRadius), step):
    for x in countup(max(0, CenterX - ScanRadius), min(ScreenWidth - 1, CenterX + ScanRadius), step):
      let color = bot.pixelAt(x, y)
      if not color.isAsteroid():
        continue
      if y < 9 and x < 21:
        continue
      let
        dx = x - CenterX
        dy = y - CenterY
        dist = dx * dx + dy * dy
      if dist < bestDist and dist > 3 * 3:
        bestDist = dist
        foundX = x
        foundY = y
        found = true
  (foundX, foundY, found)

proc angleTo(targetX, targetY: int): float =
  arctan2(float(targetY - CenterY), float(targetX - CenterX))

proc decideMask(bot: var Bot): uint8 =
  let target = bot.findNearestAsteroid()

  if target.found:
    let
      dx = target.x - CenterX
      dy = target.y - CenterY
      dist = sqrt(float(dx * dx + dy * dy))
      angle = angleTo(target.x, target.y)

    # The ship faces "up" from the player's perspective (negative Y).
    # We approximate facing from the nose pixel — but since we can't
    # easily determine facing from pixels alone, we use a simpler
    # strategy: turn toward the target and thrust + fire.

    # Use screen-relative steering:
    # If target is to the right of center, turn right. Left, turn left.
    # If target is ahead (above center), thrust. If behind, reverse.
    if dx > AimDeadband:
      result = result or ButtonRight
    elif dx < -AimDeadband:
      result = result or ButtonLeft

    # Thrust toward target
    if dy < -AimDeadband:
      result = result or ButtonUp
    elif dy > AimDeadband:
      result = result or ButtonDown

    # Always shoot when we have a target
    result = result or ButtonA

    # Brake if very close to avoid ramming
    if dist < 8.0:
      result = result or ButtonB
  else:
    # Wander: thrust forward and turn slowly
    result = ButtonUp or ButtonA
    if bot.frameTick mod 48 < 24:
      result = result or ButtonRight

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
  result = "ws://" & address & ":" & $port & "/player"
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
      var bot = Bot(rng: initRand(getTime().toUnix() xor int64(getCurrentProcessId())))
      let ws = newWebSocket(endpoint)
      while true:
        let msg = ws.receiveMessage(-1)
        if msg.isNone:
          break
        let message = msg.get
        if message.kind != BinaryMessage:
          continue
        if message.data.len != FrameBytes:
          continue
        bot.unpackFrame(message.data)
        inc bot.frameTick
        let mask = bot.decideMask()
        if mask != bot.lastMask:
          ws.send(blobFromMask(mask), BinaryMessage)
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

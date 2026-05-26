import
  std/[os, parseopt, strutils, options],
  whisky,
  bitworld/protocol

const
  DefaultAddress = "ws://localhost:8080/player?name=ChefBot"
  SW = 128
  SH = 128
  Tile = 12

type
  Bot = object
    ws: WebSocket
    frame: seq[uint8]
    wanderDir: int  # 0=up 1=right 2=down 3=left

proc unpack(data: string): seq[uint8] =
  result = newSeq[uint8](SW * SH)
  for i in 0 ..< min(data.len, SW * SH div 2):
    let b = data[i].uint8
    result[i * 2] = b and 0x0F
    result[i * 2 + 1] = b shr 4

proc px(f: seq[uint8], x, y: int): uint8 =
  if x < 0 or y < 0 or x >= SW or y >= SH: 0
  else: f[y * SW + x]

proc countColorInArea(f: seq[uint8], sx, sy, w, h: int, color: uint8): int =
  for dy in 0 ..< h:
    for dx in 0 ..< w:
      if f.px(sx + dx, sy + dy) == color:
        inc result

proc isFloorTile(f: seq[uint8], sx, sy: int): bool =
  ## A tile is floor if it's mostly palette 12/13 (the checkerboard)
  var floorPx = 0
  for dy in 0 ..< Tile:
    for dx in 0 ..< Tile:
      let c = f.px(sx + dx, sy + dy)
      if c == 12 or c == 13:
        inc floorPx
  floorPx > Tile * Tile * 2 div 3

proc isStationTile(f: seq[uint8], sx, sy: int): bool =
  ## A tile is a station/wall if it's NOT floor
  not f.isFloorTile(sx, sy)

proc findSelectionCenter(f: seq[uint8]): tuple[x, y: int, found: bool] =
  ## Find the yellow(8) selection indicator center
  var sumX, sumY, count: int
  for y in 0 ..< SH:
    for x in 0 ..< SW:
      if f.px(x, y) == 8:
        sumX += x
        sumY += y
        inc count
  if count >= 4:
    (sumX div count, sumY div count, true)
  else:
    (0, 0, false)

proc playerScreenCenter(f: seq[uint8]): tuple[x, y: int] =
  ## The player is always near the selection indicator.
  ## Selection is at the interaction tile (1 tile in facing direction from player).
  ## Player center = one tile opposite from selection center.
  ## We determine facing by checking which side of the selection has non-floor pixels.
  let sel = f.findSelectionCenter()
  if not sel.found:
    return (SW div 2, SH div 2)

  let sc = (sel.x, sel.y)
  # Check each direction from selection for player sprite (non-floor, non-station cluster)
  # The player is one tile away from selection center in opposite of facing direction.
  # Just check all 4 sides for a dense cluster of non-floor that ISN'T a wall pattern.

  # Above selection
  let aboveColors = f.countColorInArea(sc[0] - 5, sc[1] - 16, 12, 12, 12) +
                    f.countColorInArea(sc[0] - 5, sc[1] - 16, 12, 12, 13)
  # Below
  let belowColors = f.countColorInArea(sc[0] - 5, sc[1] + 5, 12, 12, 12) +
                    f.countColorInArea(sc[0] - 5, sc[1] + 5, 12, 12, 13)
  # Left
  let leftColors = f.countColorInArea(sc[0] - 16, sc[1] - 5, 12, 12, 12) +
                   f.countColorInArea(sc[0] - 16, sc[1] - 5, 12, 12, 13)
  # Right
  let rightColors = f.countColorInArea(sc[0] + 5, sc[1] - 5, 12, 12, 12) +
                    f.countColorInArea(sc[0] + 5, sc[1] - 5, 12, 12, 13)

  # Player sprite has the LEAST floor pixels (it's mostly non-floor colors)
  let minFloor = min([aboveColors, belowColors, leftColors, rightColors])
  if minFloor == aboveColors:
    return (sc[0], sc[1] - Tile)
  elif minFloor == belowColors:
    return (sc[0], sc[1] + Tile)
  elif minFloor == leftColors:
    return (sc[0] - Tile, sc[1])
  else:
    return (sc[0] + Tile, sc[1])

proc decide(bot: var Bot): uint8 =
  let f = bot.frame
  let pc = f.playerScreenCenter()

  # Look at the 4 adjacent tiles from player center
  let
    upSx = pc.x - 6
    upSy = pc.y - 6 - Tile
    downSx = pc.x - 6
    downSy = pc.y - 6 + Tile
    leftSx = pc.x - 6 - Tile
    leftSy = pc.y - 6
    rightSx = pc.x - 6 + Tile
    rightSy = pc.y - 6

  let
    upBlocked = f.isStationTile(upSx, upSy)
    rightBlocked = f.isStationTile(rightSx, rightSy)
    downBlocked = f.isStationTile(downSx, downSy)
    leftBlocked = f.isStationTile(leftSx, leftSy)

  # If blocked in current direction, pick a new one biased toward center
  let blocked = case bot.wanderDir
    of 0: upBlocked
    of 1: rightBlocked
    of 2: downBlocked
    of 3: leftBlocked
    else: false
  if blocked:
    # Bias: prefer directions toward the center of visible screen
    # Player at (pc.x, pc.y). If near top (py < 50), go down. If near left (px < 50), go right.
    if pc.y < SW div 2 and not downBlocked:
      bot.wanderDir = 2  # down
    elif pc.x < SH div 2 and not rightBlocked:
      bot.wanderDir = 1  # right
    elif not downBlocked:
      bot.wanderDir = 2
    elif not rightBlocked:
      bot.wanderDir = 1
    elif not upBlocked:
      bot.wanderDir = 0
    elif not leftBlocked:
      bot.wanderDir = 3

  let
    upIsStation = f.isStationTile(upSx, upSy)
    downIsStation = f.isStationTile(downSx, downSy)
    leftIsStation = f.isStationTile(leftSx, leftSy)
    rightIsStation = f.isStationTile(rightSx, rightSy)

  # Check what we're carrying (look at player area for item colors above player baseline)
  let
    ppx = pc.x - 6
    ppy = pc.y - 6
    red3 = f.countColorInArea(ppx, ppy, 12, 12, 3)
    white2 = f.countColorInArea(ppx, ppy, 12, 12, 2)
    green11 = f.countColorInArea(ppx, ppy, 12, 12, 11)

  let hasItem = red3 > 60 or white2 > 45 or green11 > 70

  # BEHAVIOR:
  # - If carrying an item and adjacent to a station, interact (face it + B)
  # - If not carrying and adjacent to a station, try to pick up (face it + A)
  # - Otherwise, wander toward unexplored areas (rotate direction when stuck)

  if hasItem:
    # Try to interact with an adjacent station
    if upIsStation:
      return ButtonUp or ButtonB
    if downIsStation:
      return ButtonDown or ButtonB
    if leftIsStation:
      return ButtonLeft or ButtonB
    if rightIsStation:
      return ButtonRight or ButtonB
  else:
    # Try to pick up from an adjacent station
    if upIsStation:
      return ButtonUp or ButtonA
    if downIsStation:
      return ButtonDown or ButtonA
    if leftIsStation:
      return ButtonLeft or ButtonA
    if rightIsStation:
      return ButtonRight or ButtonA

  # No station adjacent — wander
  let dirs = [
    (not f.isStationTile(upSx, upSy), ButtonUp),
    (not f.isStationTile(rightSx, rightSy), ButtonRight),
    (not f.isStationTile(downSx, downSy), ButtonDown),
    (not f.isStationTile(leftSx, leftSy), ButtonLeft),
  ]

  # Try preferred wander direction first, then cycle
  for i in 0 ..< 4:
    let idx = (bot.wanderDir + i) mod 4
    if dirs[idx][0]:
      return dirs[idx][1]

  0  # completely stuck

proc connectUrl(address: string, port: int, name, token: string): string =
  result = "ws://" & address & ":" & $port & "/player?name=" & name
  if token.len > 0:
    result.add("&token=" & token)

proc run() =
  var
    address = "localhost"
    port = 8080
    url = getEnv("COWORLD_PLAYER_WS_URL")
    name = "chef"
    token = ""

  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = value
      of "port": port = parseInt(value)
      of "url": url = value
      of "name": name = value
      of "token": token = value
      else: discard
    else: discard

  let endpoint =
    if url.len > 0: url
    else: connectUrl(address, port, name, token)

  echo "chef connecting to ", endpoint
  var ws: WebSocket
  for attempt in 0 ..< 30:
    try:
      ws = newWebSocket(endpoint)
      break
    except:
      if attempt == 29:
        echo "failed to connect after 30 attempts"
        return
      sleep(1000)
  echo "chef connected"

  var bot = Bot(
    ws: ws,
    frame: newSeq[uint8](SW * SH),
    wanderDir: 0
  )

  try:
    while true:
      let mask = bot.decide()
      bot.ws.send(blobFromMask(mask), BinaryMessage)

      let msg = ws.receiveMessage()
      if msg.isNone:
        break
      if msg.get.kind != BinaryMessage:
        continue
      if msg.get.data.len == 8192:
        bot.frame = unpack(msg.get.data)
  except CatchableError:
    discard

when isMainModule:
  run()

import std/[heapqueue, json, math, options, sets]
import whisky
import protocol

const
  ItemNames* = [
    "WoodItem", "StoneItem",
    "WoodHat", "WoodShirt", "WoodGloves", "WoodPants", "WoodShoes",
    "StoneHat", "StoneShirt", "StoneGloves", "StonePants", "StoneShoes"
  ]
  GearSlotCount* = 5
  GearItemNames* = [
    "WoodHat", "WoodShirt", "WoodGloves", "WoodPants", "WoodShoes",
    "StoneHat", "StoneShirt", "StoneGloves", "StonePants", "StoneShoes"
  ]

type
  BotInventory* = object
    counts*: array[12, int]

  BotListing* = object
    sellerIndex*: int
    item*: string
    quantity*: int
    priceEach*: int

  BotObject* = object
    kind*: string
    tx*, ty*: int
    material*: string
    depleted*: bool

  BotOtherPlayer* = object
    index*: int
    name*: string
    x*, y*: int
    role*: string
    state*: string
    signalIcon*: int

  BotPlayer* = object
    index*: int
    name*: string
    x*, y*: int
    tx*, ty*: int
    facing*: string
    role*: string
    gold*: int
    state*: string
    actionProgress*: int
    actionTargetIndex*: int
    sellPrice*: int
    buyQuantity*: int
    buyItemCursor*: int
    signalIcon*: int
    inv*: BotInventory
    equippedGear*: array[GearSlotCount, string]
    equippedGearCount*: int
    listings*: seq[BotListing]

  GameState* = object
    tick*: int
    player*: BotPlayer
    objects*: seq[BotObject]
    players*: seq[BotOtherPlayer]
    npcListings*: seq[BotListing]
    playerListings*: seq[BotListing]

proc itemIndex*(name: string): int =
  for i, n in ItemNames:
    if n == name: return i
  -1

proc wood*(inv: BotInventory): int = inv.counts[0]
proc stone*(inv: BotInventory): int = inv.counts[1]

proc itemCount*(inv: BotInventory, name: string): int =
  let idx = itemIndex(name)
  if idx >= 0: inv.counts[idx] else: 0

proc hasAnyGear*(inv: BotInventory): bool =
  for i in 2 ..< 12:
    if inv.counts[i] > 0: return true
  false

proc isGearItem*(name: string): bool =
  name in GearItemNames

proc parseInventory(node: JsonNode): BotInventory =
  for i, name in ItemNames:
    if node.hasKey(name):
      result.counts[i] = node[name].getInt()

proc parseListing(node: JsonNode): BotListing =
  result.sellerIndex = node.getOrDefault("sellerIndex").getInt(-1)
  result.item = node["item"].getStr()
  result.quantity = node["quantity"].getInt()
  result.priceEach = node["priceEach"].getInt()

proc parseGameState*(jsonStr: string): GameState =
  let root = parseJson(jsonStr)
  result.tick = root["tick"].getInt()

  if root.hasKey("player"):
    let p = root["player"]
    result.player.index = p["index"].getInt()
    result.player.name = p["name"].getStr()
    result.player.x = p["x"].getInt()
    result.player.y = p["y"].getInt()
    result.player.tx = p["tx"].getInt()
    result.player.ty = p["ty"].getInt()
    result.player.facing = p["facing"].getStr()
    result.player.role = p["role"].getStr()
    result.player.gold = p["gold"].getInt()
    result.player.state = p["state"].getStr()
    result.player.actionProgress = p["actionProgress"].getInt()
    result.player.actionTargetIndex = p["actionTargetIndex"].getInt()
    result.player.sellPrice = p["sellPrice"].getInt()
    result.player.buyQuantity = p["buyQuantity"].getInt()
    result.player.buyItemCursor = p["buyItemCursor"].getInt()
    result.player.signalIcon = p["signalIcon"].getInt()
    result.player.inv = parseInventory(p["inv"])
    result.player.equippedGearCount = p["equippedGearCount"].getInt()
    if p.hasKey("equippedGear"):
      var gearIdx = 0
      for g in p["equippedGear"]:
        if gearIdx < GearSlotCount:
          result.player.equippedGear[gearIdx] = g.getStr()
        inc gearIdx
    for l in p["listings"]:
      result.player.listings.add parseListing(l)

  for obj in root["objects"]:
    result.objects.add BotObject(
      kind: obj["kind"].getStr(),
      tx: obj["tx"].getInt(),
      ty: obj["ty"].getInt(),
      material: obj["material"].getStr(),
      depleted: obj["depleted"].getBool()
    )

  for p in root["players"]:
    result.players.add BotOtherPlayer(
      index: p["index"].getInt(),
      name: p["name"].getStr(),
      x: p["x"].getInt(),
      y: p["y"].getInt(),
      role: p["role"].getStr(),
      state: p["state"].getStr(),
      signalIcon: p["signalIcon"].getInt()
    )

  for l in root["npcListings"]:
    result.npcListings.add parseListing(l)

  for l in root["playerListings"]:
    result.playerListings.add parseListing(l)

const BotTileSize = 8

proc connectBot*(host: string, port: int, name: string): WebSocket =
  let url = "ws://" & host & ":" & $port & "/state?name=" & name
  newWebSocket(url)

proc sendInput*(ws: WebSocket, mask: uint8) =
  let packet = blobFromMask(mask)
  ws.send(packet, BinaryMessage)

proc buildMask*(up = false, down = false, left = false, right = false,
                a = false, b = false, select = false): uint8 =
  if up: result = result or ButtonUp
  if down: result = result or ButtonDown
  if left: result = result or ButtonLeft
  if right: result = result or ButtonRight
  if a: result = result or ButtonA
  if b: result = result or ButtonB
  if select: result = result or ButtonSelect

proc receiveState*(ws: WebSocket): Option[GameState] =
  let msgOpt = ws.receiveMessage()
  if msgOpt.isSome:
    let msg = msgOpt.get()
    if msg.kind == TextMessage and msg.data.len > 0:
      return some(parseGameState(msg.data))
  none(GameState)

proc isOnTile*(px, py, tx, ty: int): bool =
  let
    playerTx = (px + 3) div BotTileSize
    playerTy = (py + 3) div BotTileSize
  playerTx == tx and playerTy == ty

proc isAdjacentTo*(px, py, tx, ty: int): bool =
  let
    playerTx = (px + 3) div BotTileSize
    playerTy = (py + 3) div BotTileSize
    dx = abs(playerTx - tx)
    dy = abs(playerTy - ty)
  (dx <= 1 and dy <= 1) and (dx + dy <= 1)

proc manhattanDist*(px, py, tx, ty: int): int =
  let
    playerTx = (px + 3) div BotTileSize
    playerTy = (py + 3) div BotTileSize
  abs(playerTx - tx) + abs(playerTy - ty)

proc walkToward*(px, py, targetTx, targetTy: int): uint8 =
  let
    targetPx = targetTx * BotTileSize
    targetPy = targetTy * BotTileSize
    dx = targetPx - px
    dy = targetPy - py
  if abs(dx) > abs(dy):
    if dx < 0: buildMask(left = true)
    else: buildMask(right = true)
  elif dy != 0:
    if dy < 0: buildMask(up = true)
    else: buildMask(down = true)
  else:
    0'u8

type
  WalkState* = object
    lastX*, lastY*: int
    stuckTicks*: int
    useAltAxis*: bool

proc initWalkState*(): WalkState =
  WalkState()

proc smartWalkToward*(ws: var WalkState, px, py, targetTx, targetTy: int): uint8 =
  if px == ws.lastX and py == ws.lastY:
    inc ws.stuckTicks
    if ws.stuckTicks > 6:
      ws.useAltAxis = not ws.useAltAxis
      ws.stuckTicks = 0
  else:
    ws.stuckTicks = 0
    ws.useAltAxis = false
  ws.lastX = px
  ws.lastY = py

  let
    targetPx = targetTx * BotTileSize
    targetPy = targetTy * BotTileSize
    dx = targetPx - px
    dy = targetPy - py

  if ws.useAltAxis:
    if dy != 0:
      if dy < 0: buildMask(up = true) else: buildMask(down = true)
    elif dx != 0:
      if dx < 0: buildMask(left = true) else: buildMask(right = true)
    else:
      0'u8
  else:
    if abs(dx) > abs(dy):
      if dx < 0: buildMask(left = true) else: buildMask(right = true)
    elif dy != 0:
      if dy < 0: buildMask(up = true) else: buildMask(down = true)
    elif dx != 0:
      if dx < 0: buildMask(left = true) else: buildMask(right = true)
    else:
      0'u8

proc facingMask*(targetTx, targetTy, playerTx, playerTy: int): uint8 =
  let dx = targetTx - playerTx
  let dy = targetTy - playerTy
  if abs(dx) > abs(dy):
    if dx < 0: buildMask(left = true)
    else: buildMask(right = true)
  else:
    if dy < 0: buildMask(up = true)
    else: buildMask(down = true)

proc nearestObject*(state: GameState, kind: string, undepleted = true,
                    material = ""): Option[BotObject] =
  var bestDist = int.high
  var bestObj: BotObject
  var found = false
  for obj in state.objects:
    if obj.kind != kind: continue
    if undepleted and obj.depleted: continue
    if material.len > 0 and obj.material != material: continue
    let dist = manhattanDist(state.player.x, state.player.y, obj.tx, obj.ty)
    if dist < bestDist:
      bestDist = dist
      bestObj = obj
      found = true
  if found: some(bestObj) else: none(BotObject)

proc cheapestListing*(listings: seq[BotListing], item: string): Option[BotListing] =
  var best: BotListing
  var found = false
  for l in listings:
    if l.item != item or l.quantity <= 0: continue
    if not found or l.priceEach < best.priceEach:
      best = l
      found = true
  if found: some(best) else: none(BotListing)

proc allListings*(state: GameState): seq[BotListing] =
  result = state.npcListings & state.playerListings

proc cheapestPrice*(state: GameState, item: string): int =
  let all = state.allListings()
  let listing = cheapestListing(all, item)
  if listing.isSome: listing.get().priceEach else: int.high

proc highestPrice*(state: GameState, item: string): int =
  var best = 0
  for l in state.allListings():
    if l.item == item and l.quantity > 0 and l.priceEach > best:
      best = l.priceEach
  best

proc supplyCount*(state: GameState, item: string): int =
  for l in state.allListings():
    if l.item == item:
      result += l.quantity

proc hasListings*(state: GameState, item: string): bool =
  for l in state.allListings():
    if l.item == item and l.quantity > 0: return true
  false

proc materialCostForGear*(state: GameState): int =
  let woodPrice = cheapestPrice(state, "WoodItem")
  let stonePrice = cheapestPrice(state, "StoneItem")
  let cheapest = min(woodPrice, stonePrice)
  if cheapest >= int.high div 3:
    return int.high
  cheapest * 3

proc gearSlotName*(index: int): string =
  case index
  of 0: "Hat"
  of 1: "Shirt"
  of 2: "Gloves"
  of 3: "Pants"
  of 4: "Shoes"
  else: "Unknown"

proc firstEmptyGearSlot*(player: BotPlayer): int =
  for i in 0 ..< GearSlotCount:
    if player.equippedGear[i] == "" or player.equippedGear[i] == "WoodItem":
      return i
  -1

proc gearItemForSlot*(slot: int, material: string): string =
  let prefix = if material == "Stone": "Stone" else: "Wood"
  case slot
  of 0: prefix & "Hat"
  of 1: prefix & "Shirt"
  of 2: prefix & "Gloves"
  of 3: prefix & "Pants"
  of 4: prefix & "Shoes"
  else: prefix & "Hat"

proc itemCursorIndex*(item: string): int =
  for i, name in ItemNames:
    if name == item: return i
  0

proc hasAffordableGear*(state: GameState, player: BotPlayer): bool =
  let slot = firstEmptyGearSlot(player)
  if slot < 0: return false
  let all = state.allListings()
  for material in ["Wood", "Stone"]:
    let item = gearItemForSlot(slot, material)
    let listing = cheapestListing(all, item)
    if listing.isSome and listing.get().priceEach <= player.gold:
      return true
  false

proc bestGearMaterial*(state: GameState, slot: int, gold: int): string =
  let all = state.allListings()
  for material in ["Wood", "Stone"]:
    let item = gearItemForSlot(slot, material)
    let listing = cheapestListing(all, item)
    if listing.isSome and listing.get().priceEach <= gold:
      return material
  "Wood"

# ── A* Pathfinding ──

const
  MapWidth* = 32
  MapHeight* = 32

type
  TilePos* = tuple[tx, ty: int]

  PathNode = object
    pos: TilePos
    gCost: int
    hCost: int
    parent: int

  Navigator* = object
    path*: seq[TilePos]
    pathIndex*: int
    blocked: set[uint16]
    lastPx, lastPy: int
    stuckTicks: int
    useAltAxis: bool

proc fCost(node: PathNode): int = node.gCost + node.hCost
proc `<`(a, b: PathNode): bool = a.fCost < b.fCost

proc tileKey(tx, ty: int): uint16 =
  uint16(ty * MapWidth + tx)

proc buildCollisionMap*(state: GameState): Navigator =
  # Walls (border)
  for tx in 0 ..< MapWidth:
    result.blocked.incl tileKey(tx, 0)
    result.blocked.incl tileKey(tx, MapHeight - 1)
  for ty in 1 ..< MapHeight - 1:
    result.blocked.incl tileKey(0, ty)
    result.blocked.incl tileKey(MapWidth - 1, ty)
  # Objects with collision (everything except GatherNodeObj)
  for obj in state.objects:
    if obj.kind != "GatherNodeObj":
      result.blocked.incl tileKey(obj.tx, obj.ty)

proc isWalkable(nav: Navigator, tx, ty: int): bool =
  if tx < 0 or ty < 0 or tx >= MapWidth or ty >= MapHeight:
    return false
  tileKey(tx, ty) notin nav.blocked

proc findPath*(nav: Navigator, startTx, startTy, goalTx, goalTy: int): seq[TilePos] =
  if startTx == goalTx and startTy == goalTy:
    return @[(startTx, startTy)]
  # Allow pathfinding TO a blocked tile (we want to get adjacent)
  var openHeap = initHeapQueue[PathNode]()
  openHeap.push PathNode(
    pos: (startTx, startTy),
    gCost: 0,
    hCost: abs(startTx - goalTx) + abs(startTy - goalTy),
    parent: -1
  )
  var closedSet = initHashSet[uint16]()
  var allNodes: seq[PathNode]

  while openHeap.len > 0:
    let current = openHeap.pop()
    let key = tileKey(current.pos.tx, current.pos.ty)
    if key in closedSet:
      continue
    closedSet.incl key
    let currentIdx = allNodes.len
    allNodes.add current

    if current.pos.tx == goalTx and current.pos.ty == goalTy:
      var path: seq[TilePos]
      var idx = currentIdx
      while idx >= 0:
        path.add allNodes[idx].pos
        idx = allNodes[idx].parent
      # Reverse to get start->goal order
      for i in 0 ..< path.len div 2:
        swap(path[i], path[path.len - 1 - i])
      return path

    const dirs = [(0, -1), (0, 1), (-1, 0), (1, 0)]
    for (dx, dy) in dirs:
      let nx = current.pos.tx + dx
      let ny = current.pos.ty + dy
      let nkey = tileKey(nx, ny)
      if nkey in closedSet: continue
      # Allow walking to the goal tile even if blocked (for adjacent interaction)
      let isGoal = (nx == goalTx and ny == goalTy)
      if not isGoal and not nav.isWalkable(nx, ny): continue
      if nx < 0 or ny < 0 or nx >= MapWidth or ny >= MapHeight: continue
      openHeap.push PathNode(
        pos: (nx, ny),
        gCost: current.gCost + 1,
        hCost: abs(nx - goalTx) + abs(ny - goalTy),
        parent: currentIdx
      )
  @[]

proc findPathAdjacent*(nav: Navigator, startTx, startTy, goalTx, goalTy: int): seq[TilePos] =
  ## Find path to a tile adjacent to the goal (for interacting with collision objects).
  var bestPath: seq[TilePos]
  var bestLen = int.high
  const dirs = [(0, -1), (0, 1), (-1, 0), (1, 0)]
  for (dx, dy) in dirs:
    let adjTx = goalTx + dx
    let adjTy = goalTy + dy
    if not nav.isWalkable(adjTx, adjTy): continue
    let path = nav.findPath(startTx, startTy, adjTx, adjTy)
    if path.len > 0 and path.len < bestLen:
      bestPath = path
      bestLen = path.len
  bestPath

proc navigateTo*(nav: var Navigator, state: GameState, targetTx, targetTy: int) =
  ## Compute a path from current player position to target tile.
  nav = buildCollisionMap(state)
  let path = nav.findPath(state.player.tx, state.player.ty, targetTx, targetTy)
  nav.path = path
  nav.pathIndex = if path.len > 1: 1 else: 0

proc navigateAdjacent*(nav: var Navigator, state: GameState, targetTx, targetTy: int) =
  ## Compute a path to a tile adjacent to the target (for collision objects).
  nav = buildCollisionMap(state)
  let path = nav.findPathAdjacent(state.player.tx, state.player.ty, targetTx, targetTy)
  nav.path = path
  nav.pathIndex = if path.len > 1: 1 else: 0

proc followPath*(nav: var Navigator, px, py: int): uint8 =
  if nav.path.len == 0 or nav.pathIndex >= nav.path.len:
    return 0'u8
  let target = nav.path[nav.pathIndex]
  if isOnTile(px, py, target.tx, target.ty):
    inc nav.pathIndex
    nav.stuckTicks = 0
    nav.useAltAxis = false
    if nav.pathIndex >= nav.path.len:
      return 0'u8
    return nav.followPath(px, py)

  if px == nav.lastPx and py == nav.lastPy:
    inc nav.stuckTicks
    if nav.stuckTicks > 6:
      nav.useAltAxis = not nav.useAltAxis
      nav.stuckTicks = 0
  else:
    nav.stuckTicks = 0
    nav.useAltAxis = false
  nav.lastPx = px
  nav.lastPy = py

  let
    targetPx = target.tx * BotTileSize
    targetPy = target.ty * BotTileSize
    dx = targetPx - px
    dy = targetPy - py

  if nav.useAltAxis:
    if dy != 0:
      if dy < 0: buildMask(up = true) else: buildMask(down = true)
    elif dx != 0:
      if dx < 0: buildMask(left = true) else: buildMask(right = true)
    else:
      0'u8
  else:
    walkToward(px, py, target.tx, target.ty)

proc hasPath*(nav: Navigator): bool =
  nav.path.len > 0 and nav.pathIndex < nav.path.len

proc pathTarget*(nav: Navigator): TilePos =
  if nav.path.len > 0:
    nav.path[^1]
  else:
    (0, 0)

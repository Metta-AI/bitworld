import
  std/[json, os, strutils, xmlparser, xmltree]

const
  TiledGidMask = 0x1fffffff

type
  TiledError* = object of CatchableError

  TiledProject* = object
    path*: string
    compatibilityVersion*: int
    folders*: seq[string]

  TiledSession* = object
    path*: string
    activeFile*: string
    project*: string
    mapWidth*: int
    mapHeight*: int
    openFiles*: seq[string]
    recentFiles*: seq[string]

  TiledTileset* = object
    firstGid*: int
    source*: string
    name*: string
    tileWidth*: int
    tileHeight*: int
    tileCount*: int
    columns*: int
    imageSource*: string
    imageWidth*: int
    imageHeight*: int

  TiledLayer* = object
    id*: int
    name*: string
    width*: int
    height*: int
    gids*: seq[int]

  TiledMap* = object
    path*: string
    version*: string
    tiledVersion*: string
    orientation*: string
    renderOrder*: string
    width*: int
    height*: int
    tileWidth*: int
    tileHeight*: int
    infinite*: bool
    tilesets*: seq[TiledTileset]
    layers*: seq[TiledLayer]

  TiledWorkspace* = object
    project*: TiledProject
    session*: TiledSession
    map*: TiledMap

proc tiledError(message: string): ref TiledError =
  ## Builds one Tiled-specific exception.
  newException(TiledError, message)

proc readJson(path: string): JsonNode =
  ## Reads one Tiled JSON file and maps failures to TiledError.
  try:
    parseFile(path)
  except CatchableError as e:
    raise tiledError("Could not read Tiled JSON " & path & ": " & e.msg)

proc requireXml(path: string): XmlNode =
  ## Reads one Tiled XML file and maps failures to TiledError.
  try:
    loadXml(path)
  except CatchableError as e:
    raise tiledError("Could not read Tiled XML " & path & ": " & e.msg)

proc attrText(node: XmlNode, name, source: string): string =
  ## Returns one required XML attribute.
  result = node.attr(name)
  if result.len == 0:
    raise tiledError("Missing XML attribute " & name & " in " & source)

proc attrInt(node: XmlNode, name, source: string): int =
  ## Parses one required integer XML attribute.
  let text = node.attrText(name, source)
  try:
    parseInt(text)
  except ValueError:
    raise tiledError(
      "XML attribute " & name & " in " & source &
        " must be an integer: " & text
    )

proc optJsonString(node: JsonNode, name: string): string =
  ## Reads one optional JSON string field.
  if node.kind == JObject and node.hasKey(name) and node[name].kind == JString:
    return node[name].getStr()
  ""

proc optJsonInt(node: JsonNode, name: string): int =
  ## Reads one optional JSON integer field.
  if node.kind == JObject and node.hasKey(name) and node[name].kind == JInt:
    return node[name].getInt()
  0

proc optJsonStrings(node: JsonNode, name: string): seq[string] =
  ## Reads one optional JSON string array field.
  if node.kind != JObject or not node.hasKey(name) or node[name].kind != JArray:
    return
  for child in node[name].items:
    if child.kind == JString:
      result.add(child.getStr())

proc parseCsvGids(text, source: string, expected: int): seq[int] =
  ## Parses one Tiled CSV gid payload.
  for part in text.split({',', '\n', '\r', '\t', ' '}):
    if part.len == 0:
      continue
    try:
      result.add(parseInt(part) and TiledGidMask)
    except ValueError:
      raise tiledError("Invalid CSV gid in " & source & ": " & part)

  if result.len != expected:
    raise tiledError(
      "Layer data in " & source & " has " & $result.len &
        " gids, expected " & $expected
    )

proc loadTiledProject*(path: string): TiledProject =
  ## Loads one Tiled project JSON file.
  let node = path.readJson()
  result.path = path
  result.compatibilityVersion = node.optJsonInt("compatibilityVersion")
  result.folders = node.optJsonStrings("folders")

proc loadTiledSession*(path: string): TiledSession =
  ## Loads one Tiled session JSON file.
  let node = path.readJson()
  result.path = path
  result.activeFile = node.optJsonString("activeFile")
  result.project = node.optJsonString("project")
  result.mapWidth = node.optJsonInt("map.width")
  result.mapHeight = node.optJsonInt("map.height")
  result.openFiles = node.optJsonStrings("openFiles")
  result.recentFiles = node.optJsonStrings("recentFiles")

proc loadTiledTileset*(path: string, firstGid: int): TiledTileset =
  ## Loads one external Tiled TSX tileset file.
  let root = path.requireXml()
  if root.tag != "tileset":
    raise tiledError("Expected tileset root in " & path)

  result.firstGid = firstGid
  result.source = path
  result.name = root.attrText("name", path)
  result.tileWidth = root.attrInt("tilewidth", path)
  result.tileHeight = root.attrInt("tileheight", path)
  result.tileCount = root.attrInt("tilecount", path)
  result.columns = root.attrInt("columns", path)

  for child in root:
    if child.kind == xnElement and child.tag == "image":
      result.imageSource = child.attrText("source", path)
      result.imageWidth = child.attrInt("width", path)
      result.imageHeight = child.attrInt("height", path)
      return

  raise tiledError("Missing tileset image in " & path)

proc loadTiledMap*(path: string): TiledMap =
  ## Loads one finite orthogonal Tiled TMX map.
  let root = path.requireXml()
  if root.tag != "map":
    raise tiledError("Expected map root in " & path)

  result.path = path
  result.version = root.attr("version")
  result.tiledVersion = root.attr("tiledversion")
  result.orientation = root.attrText("orientation", path)
  result.renderOrder = root.attr("renderorder")
  result.width = root.attrInt("width", path)
  result.height = root.attrInt("height", path)
  result.tileWidth = root.attrInt("tilewidth", path)
  result.tileHeight = root.attrInt("tileheight", path)
  result.infinite = root.attr("infinite") == "1"

  if result.infinite:
    raise tiledError("Infinite maps are not supported yet: " & path)
  if result.orientation != "orthogonal":
    raise tiledError("Only orthogonal maps are supported: " & path)

  let mapDir = path.parentDir()
  for child in root:
    if child.kind != xnElement:
      continue

    case child.tag
    of "tileset":
      let
        firstGid = child.attrInt("firstgid", path)
        source = child.attr("source")
      if source.len == 0:
        raise tiledError("Inline tilesets are not supported yet: " & path)
      result.tilesets.add(loadTiledTileset(mapDir / source, firstGid))
    of "layer":
      var layer = TiledLayer(
        id: child.attrInt("id", path),
        name: child.attrText("name", path),
        width: child.attrInt("width", path),
        height: child.attrInt("height", path)
      )
      if layer.width != result.width or layer.height != result.height:
        raise tiledError("Layer size mismatch in " & path & ": " & layer.name)

      for data in child:
        if data.kind != xnElement or data.tag != "data":
          continue
        if data.attr("encoding") != "csv":
          raise tiledError("Only CSV layer data is supported: " & path)
        if data.attr("compression").len != 0:
          raise tiledError("Compressed layer data is not supported: " & path)
        layer.gids = parseCsvGids(
          data.innerText(),
          path & ":" & layer.name,
          layer.width * layer.height
        )

      if layer.gids.len == 0:
        raise tiledError("Layer has no tile data in " & path & ": " & layer.name)
      result.layers.add(layer)
    else:
      discard

  if result.layers.len == 0:
    raise tiledError("Map has no layers: " & path)

proc layerByName*(map: TiledMap, name: string): TiledLayer =
  ## Returns one map layer by name.
  for layer in map.layers:
    if layer.name == name:
      return layer
  raise tiledError("Missing Tiled layer " & name & " in " & map.path)

proc gidAt*(layer: TiledLayer, x, y: int): int =
  ## Returns one gid from a layer, or zero outside the layer.
  if x < 0 or y < 0 or x >= layer.width or y >= layer.height:
    return 0
  layer.gids[y * layer.width + x]

proc loadTiledWorkspace*(
  projectPath,
  sessionPath,
  mapPath: string
): TiledWorkspace =
  ## Loads Tiled project, session, and map files together.
  result.project = loadTiledProject(projectPath)
  result.session = loadTiledSession(sessionPath)
  result.map = loadTiledMap(mapPath)

  if result.session.activeFile.len > 0 and
      result.session.activeFile != mapPath.extractFilename():
    raise tiledError(
      "Tiled session active file " & result.session.activeFile &
        " does not match " & mapPath.extractFilename()
    )
  if result.session.project.len > 0 and
      result.session.project != projectPath.extractFilename():
    raise tiledError(
      "Tiled session project " & result.session.project &
        " does not match " & projectPath.extractFilename()
    )

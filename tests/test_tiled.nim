import
  std/os,
  bitworld/tiled

let
  rootDir = currentSourcePath().parentDir().parentDir()
  dataDir = rootDir / "tests" / "data" / "jumper"
  workspace = loadTiledWorkspace(
    dataDir / "forest.tiled-project",
    dataDir / "forest.tiled-session",
    dataDir / "forest.tmx"
  )
  layer = workspace.map.layerByName("Tile Layer 1")

echo "Testing Tiled project parsing"
doAssert workspace.project.compatibilityVersion == 1100
doAssert workspace.session.activeFile == "forest.tmx"
doAssert workspace.session.project == "forest.tiled-project"

echo "Testing Tiled map parsing"
doAssert workspace.map.width == 64
doAssert workspace.map.height == 16
doAssert workspace.map.tileWidth == 32
doAssert workspace.map.tileHeight == 32
doAssert workspace.map.tilesets.len == 1
doAssert workspace.map.tilesets[0].imageSource == "spritesheet.aseprite"
doAssert layer.gids.len == workspace.map.width * workspace.map.height

var
  solidTiles = 0
  flagTiles = 0
for gid in layer.gids:
  if gid != 0 and gid != 15:
    inc solidTiles
  elif gid == 15:
    inc flagTiles

doAssert solidTiles > 0
doAssert flagTiles == 1

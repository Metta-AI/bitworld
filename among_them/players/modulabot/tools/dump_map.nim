## Dump skeld2.aseprite layers as RGBA PNGs that modulabot's Python side
## can load and palette-decode.
##
## Build & run:
##   cd ~/coding/bitworld
##   nim c -r --path:. among_them/players/modulabot/tools/dump_map.nim \
##     /path/to/output_dir

import std/[os, strutils]
import pixie

import ../../../sim
import bitworld/aseprite

proc main() =
  if paramCount() < 1:
    echo "usage: dump_map <output_dir>"
    quit(1)
  let outDir = paramStr(1)
  createDir(outDir)

  let (mapImage, walkImage, wallImage) = loadSkeld2Layers()
  writeFile(outDir / "map.png", mapImage.encodeImage(PngFormat))
  writeFile(outDir / "walk.png", walkImage.encodeImage(PngFormat))
  writeFile(outDir / "wall.png", wallImage.encodeImage(PngFormat))
  echo "wrote map.png walk.png wall.png (", mapImage.width, "x",
       mapImage.height, ") to ", outDir

when isMainModule:
  main()

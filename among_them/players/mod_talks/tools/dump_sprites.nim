## Dump spritesheet.aseprite as a PNG so the Python port has access to
## the generic (tint-colour) version of each sprite.
##
## Build & run:
##   cd ~/coding/bitworld
##   nim c -r --path:. among_them/players/modulabot/tools/dump_sprites.nim \
##     /path/to/output_dir

import std/[os, strutils]
import pixie

import ../../../sim
import bitworld/aseprite

proc main() =
  if paramCount() < 1:
    echo "usage: dump_sprites <output_dir>"
    quit(1)
  let outDir = paramStr(1)
  createDir(outDir)

  let sheet = loadSpriteSheet()
  writeFile(outDir / "spritesheet.png", sheet.encodeImage(PngFormat))
  echo "wrote spritesheet.png (", sheet.width, "x", sheet.height, ") to ", outDir

when isMainModule:
  main()

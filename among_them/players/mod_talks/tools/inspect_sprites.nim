## Dump the loaded Nim sprite pixels for comparison with the Python port.

import std/[os, strutils, strformat]
import pixie

import ../../../../common/protocol
import ../../../sim
import ../../../../common/server
import bitworld/aseprite

proc dumpSprite(name: string, sprite: Sprite) =
  echo name, " (", sprite.width, "x", sprite.height, ")"
  for y in 0 ..< sprite.height:
    var row = ""
    for x in 0 ..< sprite.width:
      let c = sprite.pixels[sprite.spriteIndex(x, y)]
      if c == TransparentColorIndex: row.add('.')
      elif c < 10: row.add($c)
      else: row.add(chr(ord('a') + c - 10))
    echo "  ", row
  var uniq: set[uint8] = {}
  for c in sprite.pixels:
    uniq.incl(c)
  echo "  unique: ", uniq

proc main() =
  loadPalette(clientDataDir() / "pallete.png")
  let sheet = loadSpriteSheet()
  dumpSprite("player",  spriteFromImage(sheet.subImage(0,           0, SpriteSize, SpriteSize)))
  dumpSprite("body",    spriteFromImage(sheet.subImage(SpriteSize,  0, SpriteSize, SpriteSize)))
  dumpSprite("kill",    spriteFromImage(sheet.subImage(SpriteSize*3,0, SpriteSize, SpriteSize)))
  dumpSprite("task",    spriteFromImage(sheet.subImage(SpriteSize*4,0, SpriteSize, SpriteSize)))
  dumpSprite("ghost",   spriteFromImage(sheet.subImage(SpriteSize*6,0, SpriteSize, SpriteSize)))
  dumpSprite("ghosti",  spriteFromImage(sheet.subImage(SpriteSize*7,0, SpriteSize, SpriteSize)))

when isMainModule:
  main()

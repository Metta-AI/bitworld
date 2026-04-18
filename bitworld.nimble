version     = "0.1.0"
author      = "Andre von Houck"
description = "Retro 64x64 multiplayer social curriculum AI environment."
license     = "MIT"

srcDir = "."
bin = @[
  "client/client",
  "big_adventure/big_adventure",
  "big_adventure/player",
  "fancy_cookout/fancy_cookout",
  "infinite_blocks/infinite_blocks",
  "planet_wars/planet_wars",
  "tools/quick_run"
]

switch("path", "common")
switch("threads", "on")
switch("mm", "orc")

requires "nim >= 2.2.4"
requires "pixie"
requires "mummy >= 0.4.7"
requires "whisky >= 0.1.3"
requires "silky >= 0.0.2"
requires "windy >= 0.4.4"
requires "paddy >= 0.1.0"

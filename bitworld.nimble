version     = "0.1.0"
author      = "Andre von Houck"
description = "Retro 64x64 multiplayer social curriculum AI environment."
license     = "MIT"

srcDir = "."
bin = @[
  "clients/global_client",
  "clients/player_client",
  "clients/reward_client",
  "asteroid_arena/asteroid_arena",
  "big_adventure/big_adventure",
  "big_adventure/player",
  "brushwalk/brushwalk",
  "bubble_eats/bubble_eats",
  "free_chat/free_chat",
  "fancy_cookout/fancy_cookout",
  "ice_brawl/ice_brawl",
  "infinite_blocks/infinite_blocks",
  "planet_wars/planet_wars",
  "stag_hunt/stag_hunt",
  "overworld/overworld",
  "tools/quick_run",
  "tools/quick_player",
  "tools/ptswap",
  "tag/tag",
  "jumper/jumper",
  "warzone/warzone",
  "among_them/among_them",
  "among_them/replay_viewer",
  "global_ui/global_ui"
]

switch("path", "common")
switch("path", "src")
switch("threads", "on")
switch("mm", "orc")

requires "nim >= 2.2.4"
requires "pixie"
requires "mummy >= 0.4.7"
requires "whisky >= 0.1.3"
requires "silky >= 0.0.2"
requires "windy >= 0.4.4"
requires "paddy >= 0.1.0"

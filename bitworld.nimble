version     = "0.1.0"
author      = "Andre von Houck"
description = "Retro 64x64 multiplayer social curriculum AI environment."
license     = "MIT"

srcDir = "src"
paths = @["src"]
installDirs = @["src", "client", "docs", "games_server", "tools"]

switch("path", "src")
switch("threads", "on")
switch("mm", "orc")

requires "nim >= 2.2.4"
requires "pixie"
requires "mummy >= 0.4.7"
requires "curly >= 1.1.1"
requires "whisky >= 0.1.3"
requires "silky >= 0.0.2"
requires "windy >= 0.4.4"
requires "paddy >= 0.1.0"
requires "supersnappy >= 2.1.3"
requires "flatty >= 0.3.4"
requires "taggy >= 0.0.3"
requires "fluffy >= 1.0.0"
requires "zippy >= 0.10.19"

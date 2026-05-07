version     = "0.1.0"
author      = "Andre von Houck"
description = "A multiplayer social negotiation game of magic and betrayal."
license     = "MIT"

srcDir = "."

bin = @[
  "mortal_coil",
]

switch("path", "../common")
switch("threads", "on")
switch("mm", "orc")

requires "nim >= 2.2.4"
requires "pixie"
requires "mummy >= 0.4.7"
requires "whisky >= 0.1.3"
requires "silky >= 0.0.2"
requires "supersnappy >= 2.1.3"
requires "jsony >= 1.1.5"
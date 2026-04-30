## ASCII glyph OCR.
##
## Thin adapter over `among_them/texts.nim`. The underlying engine
## (variable-width tiny font matching, two-sided miss/extra scoring)
## is shared with italkalot and ivotewell so modulabot stays in sync
## whenever the game font is retuned.
##
## Used to:
##
## 1. Detect interstitial screens by reading their title text
##    (CREWMATE / IMPS / CREW WINS / IMPS WIN).
## 2. Parse chat content on the voting screen (`voting.nim` consumes
##    `readAsciiRun`).
##
## All procs are read-only with respect to bot state.

import protocol
import ../../sim
import ../../texts

import types

proc asciiTextWidth*(bot: Bot, text: string): int =
  ## Returns the variable-width tiny font text width for `text`.
  texts.asciiTextWidth(bot.sim.asciiSprites, text)

proc asciiTextMatches*(bot: Bot, text: string, x, y: int): bool =
  ## True when `text` is visible at the given screen position.
  texts.asciiTextMatches(bot.io.unpacked, bot.sim.asciiSprites, text, x, y)

proc findAsciiText*(bot: Bot, text: string): bool =
  ## Searches the top of the screen (y in 0..20) for a rendered
  ## ASCII phrase. Used for interstitial title detection.
  let maxX = ScreenWidth - bot.asciiTextWidth(text)
  if maxX < 0:
    return false
  for y in 0 .. 20:
    for x in 0 .. maxX:
      if bot.asciiTextMatches(text, x, y):
        return true
  false

proc readAsciiLine*(bot: Bot, y: int): string =
  ## Reads a loose ASCII line at row y across the full screen width.
  texts.readAsciiLine(bot.io.unpacked, bot.sim.asciiSprites, y)

proc readAsciiRun*(bot: Bot, x, y, count: int): string =
  ## Reads a fixed number of variable-width tiny glyphs starting at
  ## `(x, y)`. Delegates to the shared reader so glyph advance and
  ## matching tolerance stay in sync with the game font.
  texts.readAsciiRun(bot.io.unpacked, bot.sim.asciiSprites, x, y, count)

proc detectInterstitialText*(bot: Bot): string =
  ## Reads known interstitial ASCII text from a black screen. Tries
  ## the well-known phrases first (cheap), falls back to a free-form
  ## line read for anything else.
  if bot.findAsciiText("CREW WINS"):
    return "CREW WINS"
  if bot.findAsciiText("IMPS WIN"):
    return "IMPS WIN"
  if bot.findAsciiText("IMPS"):
    return "IMPS"
  if bot.findAsciiText("CREWMATE"):
    return "CREWMATE"
  for y in 0 .. 20:
    let line = bot.readAsciiLine(y)
    if line.len > 0 and line != "??????????????????":
      return line
  ""

proc isGameOverText*(text: string): bool =
  ## True when an interstitial text indicates round end.
  text == "CREW WINS" or text == "IMPS WIN"

## ASCII glyph OCR.
##
## Phase 1 port from v2:885-996. Used to:
##
## 1. Detect interstitial screens by reading their title text
##    (CREWMATE / IMPS / CREW WINS / IMPS WIN).
## 2. Parse chat content on the voting screen (`voting.nim` consumes
##    `readAsciiRun` and friends).
##
## All procs are read-only with respect to bot state. They take `bot:
## Bot` (matching v2) because they read from two different sub-records
## (`io.unpacked` for the frame, `sim.asciiSprites` for the atlas) and
## sub-record purity for read-only helpers buys nothing.

import std/strutils
import protocol
import ../../sim
import ../../../common/server

import types

proc asciiChar*(index: int): char =
  ## Character represented by one ASCII sprite index (offset from
  ## space).
  char(index + ord(' '))

proc asciiGlyphScore*(bot: Bot, glyph: Sprite,
                     screenX, screenY: int): tuple[misses: int, opaque: int] =
  ## Scores one rendered ASCII glyph against the current frame: counts
  ## opaque pixels and how many of them disagree with the live frame.
  for y in 0 ..< glyph.height:
    for x in 0 ..< glyph.width:
      let color = glyph.pixels[glyph.spriteIndex(x, y)]
      if color == TransparentColorIndex:
        continue
      inc result.opaque
      let
        sx = screenX + x
        sy = screenY + y
      if sx < 0 or sx >= ScreenWidth or sy < 0 or sy >= ScreenHeight:
        inc result.misses
        continue
      if bot.io.unpacked[sy * ScreenWidth + sx] != color:
        inc result.misses

proc asciiTextScore*(bot: Bot, text: string,
                    screenX, screenY: int): tuple[misses: int, opaque: int] =
  ## Scores one rendered ASCII text run against the current frame.
  var offsetX = 0
  for ch in text:
    let idx = asciiIndex(ch)
    if idx >= 0 and idx < bot.sim.asciiSprites.len:
      let score = bot.asciiGlyphScore(
        bot.sim.asciiSprites[idx],
        screenX + offsetX,
        screenY
      )
      result.misses += score.misses
      result.opaque += score.opaque
    offsetX += 7

proc asciiTextWidth*(text: string): int =
  ## Returns the fixed-width ASCII text width (7 px per glyph).
  text.len * 7

proc asciiTextMatches*(bot: Bot, text: string, x, y: int): bool =
  ## True when `text` is visible at the given screen position.
  let score = bot.asciiTextScore(text, x, y)
  if score.opaque == 0:
    return false
  score.misses <= max(2, score.opaque div 16)

proc findAsciiText*(bot: Bot, text: string): bool =
  ## Searches the top of the screen (y in 0..20) for a rendered ASCII
  ## phrase. Used for interstitial title detection.
  let maxX = ScreenWidth - asciiTextWidth(text)
  if maxX < 0:
    return false
  for y in 0 .. 20:
    for x in 0 .. maxX:
      if bot.asciiTextMatches(text, x, y):
        return true
  false

proc bestAsciiGlyph*(bot: Bot, x, y: int): char =
  ## Reads the best single ASCII glyph at a fixed character cell.
  ## Returns ' ' for a clean cell and '?' when no glyph fits well
  ## enough.
  var
    bestChar = ' '
    bestMisses = high(int)
    bestOpaque = 0
  for i, glyph in bot.sim.asciiSprites:
    let score = bot.asciiGlyphScore(glyph, x, y)
    if score.opaque == 0:
      continue
    if score.misses < bestMisses:
      bestMisses = score.misses
      bestOpaque = score.opaque
      bestChar = asciiChar(i)
  if bestOpaque == 0:
    return ' '
  if bestMisses <= max(2, bestOpaque div 8):
    return bestChar
  '?'

proc readAsciiLine*(bot: Bot, y: int): string =
  ## Reads a loose ASCII line at row y across the full screen width.
  for x in countup(0, ScreenWidth - 7, 7):
    result.add(bot.bestAsciiGlyph(x, y))
  result = result.strip()

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

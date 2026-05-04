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
##
## `sim.asciiSprites` is a `PixelFont` (see `common/pixelfonts.nim`).
## The server switched from a fixed-width 7-pixel sprite font to a
## variable-width PixelFont; v2-era fixed 7-pixel stepping breaks OCR
## on the new font (each glyph has its own `width + spacing`, and
## narrow characters like `i` take ~2-3 px while wide ones like `M`
## take 6+ px). This module now delegates the pixel-scoring to
## `pixelfonts.textScore` / `findText` / `bestGlyph` / `readRun` which
## already walk the font with correct advance. The previous custom
## scoring here was silently returning garbage (reading rows 20+ of a
## voting screen as `".'',...........,.."` instead of `"SKIP"`), so
## `parseVotingScreen` never matched and no meeting events fired.

import std/strutils
import protocol
import ../../sim
import ../../../common/server
import ../../../common/pixelfonts

import types

const
  # Maximum OCR errors we tolerate per expected text match. The
  # underlying pixelfonts scoring counts both missed foreground pixels
  # AND unexpected foreground pixels (`misses + extras`). Variable-
  # width chars plus the game's occasional 1-pixel jitter tend to
  # produce 1-3 errors on a good match; being generous here lets us
  # handle legitimate noise without admitting false positives (since
  # a wrong glyph usually has 10+ errors).
  TextMatchMaxErrors = 6
  BestGlyphMaxErrors = 6

proc asciiChar*(index: int): char =
  ## Character represented by one ASCII sprite index (offset from
  ## space).
  char(index + ord(' '))

proc asciiTextScore*(bot: Bot, text: string,
                    screenX, screenY: int): PixelGlyphScore =
  ## Scores one rendered ASCII text run against the current frame.
  ## Uses variable-width advance from the PixelFont.
  bot.io.unpacked.textScore(bot.sim.asciiSprites, text, screenX, screenY)

proc asciiTextWidth*(font: PixelFont, text: string): int =
  ## Returns the pixel width of a rendered text string on the current
  ## font. Replaces the old fixed-7px calculation.
  font.textWidth(text)

proc asciiTextWidth*(text: string): int =
  ## Legacy compat shim — returns width assuming the v2 fixed 7px/char.
  ## Only kept for callers that don't have a `Bot`/`PixelFont` on hand.
  ## New code should pass the font.
  text.len * 7

proc asciiTextMatches*(bot: Bot, text: string, x, y: int): bool =
  ## True when `text` is visible at the given screen position.
  bot.io.unpacked.textMatches(
    bot.sim.asciiSprites, text, x, y, maxErrors = TextMatchMaxErrors
  )

proc findAsciiText*(bot: Bot, text: string): bool =
  ## Searches the top of the screen (y in 0..20) for a rendered ASCII
  ## phrase. Used for interstitial title detection.
  let
    font = bot.sim.asciiSprites
    maxX = ScreenWidth - font.textWidth(text)
  if maxX < 0:
    return false
  let yMax = min(20, ScreenHeight - font.height)
  for y in 0 .. yMax:
    for x in 0 .. maxX:
      if bot.io.unpacked.textMatches(
          font, text, x, y, maxErrors = TextMatchMaxErrors):
        return true
  false

proc bestAsciiGlyph*(bot: Bot, x, y: int): char =
  ## Reads the best single ASCII glyph at a fixed character cell.
  ## Returns ' ' for a clean cell and '?' when no glyph fits well
  ## enough.
  bot.io.unpacked.bestGlyph(
    bot.sim.asciiSprites, x, y, maxErrors = BestGlyphMaxErrors
  )

proc readAsciiRun*(bot: Bot, x, y, count: int): string =
  ## Reads up to `count` variable-width glyphs starting at (x, y),
  ## advancing by each glyph's `width + spacing`. Trimmed result.
  ## Replaces the old fixed-7px stepping that silently misaligned
  ## reads against the current PixelFont.
  bot.io.unpacked.readRun(
    bot.sim.asciiSprites, x, y, count,
    maxErrors = BestGlyphMaxErrors,
    stripResult = true
  )

proc readAsciiLine*(bot: Bot, y: int): string =
  ## Reads a loose ASCII line at row y across the full screen width.
  ## Walks variable-width glyphs until the line runs out.
  let font = bot.sim.asciiSprites
  var
    penX = 0
    emitted = newStringOfCap(40)
  while penX <= ScreenWidth - 1:
    let ch = bot.io.unpacked.bestGlyph(
      font, penX, y, maxErrors = BestGlyphMaxErrors
    )
    emitted.add(ch)
    # Advance by this character's width; for '?' we don't know the
    # width so step by a small default to keep scanning.
    let adv =
      if ch == '?': 4
      else: font.glyphAdvance(ch)
    if adv <= 0:
      break
    penX += adv
  emitted.strip()

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
  let font = bot.sim.asciiSprites
  let yMax = min(20, ScreenHeight - font.height)
  for y in 0 .. yMax:
    let line = bot.readAsciiLine(y)
    if line.len == 0:
      continue
    # Avoid returning pure-garbage reads ("??????" etc). A useful
    # line has at least some actual letters.
    var letters = 0
    for ch in line:
      if ch in {'A' .. 'Z', 'a' .. 'z'}:
        inc letters
    if letters >= 2:
      return line
  ""

proc isGameOverText*(text: string): bool =
  ## True when an interstitial text indicates round end.
  text == "CREW WINS" or text == "IMPS WIN"

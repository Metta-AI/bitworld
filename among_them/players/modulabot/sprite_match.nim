## Sprite-matching primitives.
##
## Phase 1 port from v2:1348-1422 (generic matchers) and v2:1468-1727
## (crewmate / actor matchers). Used by `actors`, `tasks`, `voting`.
##
## All matchers take an `openArray[uint8]` frame plus a `Sprite`. They do
## not take `Bot`, even when v2 did, because the only Bot fields they
## read (`unpacked`, `playerSprite`) are easy to pass explicitly and
## exposing them as parameters makes the matchers trivially testable.

import protocol
import ../../sim
import ../../../common/server

import types

const
  TaskIconMaxMisses* = 4
    ## Strict-fit budget for `matchesSprite`. Set to match v2.
  TaskIconMaybeMisses* = 12
    ## Looser-fit budget for `maybeMatchesSprite`.
  KillIconMaxMisses* = 5
    ## Budget for `matchesSpriteShadowed`. Used by HUD icon checks.
  CrewmateMaxMisses* = 8
    ## Acceptance miss budget for `matchesCrewmate`.
  CrewmateMinStablePixels* = 8
    ## Minimum stable (visor / outline) pixels required to accept a
    ## crewmate sprite match.
  CrewmateMinBodyPixels* = 8
    ## Minimum body (tint / shade) pixels required to accept a
    ## crewmate sprite match.

# ---------------------------------------------------------------------------
# Generic frame↔sprite scoring
# ---------------------------------------------------------------------------

proc spriteMisses*(frame: openArray[uint8], sprite: Sprite,
                  x, y: int): tuple[misses: int, opaque: int] =
  ## Counts opaque sprite pixels that disagree with the frame at the
  ## given anchor.
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let color = sprite.pixels[sprite.spriteIndex(sx, sy)]
      if color == TransparentColorIndex:
        continue
      inc result.opaque
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        inc result.misses
      elif frame[fy * ScreenWidth + fx] != color:
        inc result.misses

proc matchesSprite*(frame: openArray[uint8], sprite: Sprite, x, y: int): bool =
  ## True when sprite stringently matches the frame.
  let score = spriteMisses(frame, sprite, x, y)
  score.opaque > 0 and score.misses <= TaskIconMaxMisses

proc maybeMatchesSprite*(frame: openArray[uint8], sprite: Sprite,
                        x, y: int): bool =
  ## True when sprite may be present but imperfect.
  let score = spriteMisses(frame, sprite, x, y)
  score.opaque > 0 and score.misses <= TaskIconMaybeMisses

proc matchesSpriteShadowed*(frame: openArray[uint8], sprite: Sprite,
                           x, y: int): bool =
  ## True when sprite matches via the shadow palette (used for the
  ## ghost icon, which is rendered shadowed onto the HUD).
  ##
  ## Early-exits once misses exceed `KillIconMaxMisses`; preserved
  ## verbatim from v2 because the early-out bound is what makes this
  ## proc affordable on every frame.
  var
    misses = 0
    opaque = 0
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let color = sprite.pixels[sprite.spriteIndex(sx, sy)]
      if color == TransparentColorIndex:
        continue
      inc opaque
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        inc misses
      elif frame[fy * ScreenWidth + fx] != ShadowMap[color and 0x0f]:
        inc misses
      if misses > KillIconMaxMisses:
        return false
  opaque > 0 and misses <= KillIconMaxMisses

# ---------------------------------------------------------------------------
# Crewmate / actor palette helpers
# ---------------------------------------------------------------------------

proc stableCrewmateColor*(color: uint8): bool =
  ## True for non-tint, non-transparent crewmate sprite pixels (the
  ## stable visor / outline pixels that don't depend on player colour).
  color != TransparentColorIndex and
    color != TintColor and
    color != ShadeTintColor

proc playerBodyColor*(color: uint8): bool =
  ## True when a frame colour can plausibly be a crewmate body — either
  ## the raw colour or its shadowed variant.
  for playerColor in PlayerColors:
    if color == playerColor:
      return true
    if color == ShadowMap[playerColor and 0x0f]:
      return true
  false

proc playerColorIndex*(color: uint8): int =
  ## Returns the tracked player colour index for a palette colour, or
  ## -1 if it is not a player colour.
  for i, playerColor in PlayerColors:
    if color == playerColor:
      return i
  -1

proc crewmatePixelMatches*(spriteColor, frameColor: uint8): bool =
  ## True when one crewmate sprite pixel matches the frame. Tint
  ## pixels match any plausible body colour; non-tint pixels match
  ## exactly.
  if spriteColor == TintColor or spriteColor == ShadeTintColor:
    return playerBodyColor(frameColor)
  frameColor == spriteColor

# ---------------------------------------------------------------------------
# Crewmate sprite matchers
# ---------------------------------------------------------------------------

proc crewmateColorIndex*(frame: openArray[uint8], playerSprite: Sprite,
                        x, y: int, flipH: bool): int =
  ## Returns the most likely visible colour index for a crewmate match.
  ## Counts how many tint pixels in the sprite line up with each
  ## player-colour palette index in the frame, returns the winner.
  var counts: array[PlayerColorCount, int]
  for sy in 0 ..< playerSprite.height:
    for sx in 0 ..< playerSprite.width:
      let srcX =
        if flipH:
          playerSprite.width - 1 - sx
        else:
          sx
      let color = playerSprite.pixels[playerSprite.spriteIndex(srcX, sy)]
      if color != TintColor:
        continue
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        continue
      let index = playerColorIndex(frame[fy * ScreenWidth + fx])
      if index >= 0:
        inc counts[index]
  var bestCount = 0
  result = -1
  for i, count in counts:
    if count > bestCount:
      bestCount = count
      result = i

proc matchesCrewmate*(frame: openArray[uint8], playerSprite: Sprite,
                     x, y: int, flipH: bool): bool =
  ## True when stable crewmate pixels (visor / outline) plus body
  ## (tint / shade) pixels match the frame at the given anchor.
  ##
  ## Logic preserved verbatim from v2:1525-1571: counts stable-pixel
  ## hits and body-pixel hits separately, early-exits once misses
  ## exceed `CrewmateMaxMisses`, then enforces both
  ## `CrewmateMinStablePixels` and `CrewmateMinBodyPixels` floors.
  var
    bodyMatched = 0
    bodyPixels = 0
    matchedStable = 0
    misses = 0
    stablePixels = 0
  for sy in 0 ..< playerSprite.height:
    for sx in 0 ..< playerSprite.width:
      let srcX =
        if flipH:
          playerSprite.width - 1 - sx
        else:
          sx
      let color = playerSprite.pixels[playerSprite.spriteIndex(srcX, sy)]
      if color == TransparentColorIndex:
        continue
      if stableCrewmateColor(color):
        inc stablePixels
      else:
        inc bodyPixels
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        inc misses
      elif crewmatePixelMatches(color, frame[fy * ScreenWidth + fx]):
        if stableCrewmateColor(color):
          inc matchedStable
        else:
          inc bodyMatched
      else:
        inc misses
      if misses > CrewmateMaxMisses:
        return false
  stablePixels >= CrewmateMinStablePixels and
    matchedStable >= CrewmateMinStablePixels and
    bodyPixels >= CrewmateMinBodyPixels and
    bodyMatched >= CrewmateMinBodyPixels

# ---------------------------------------------------------------------------
# Tinted actor sprite matchers (for body / ghost detection)
# ---------------------------------------------------------------------------

proc matchesActorSprite*(frame: openArray[uint8], sprite: Sprite,
                        x, y: int, flipH: bool,
                        maxMisses, minStablePixels,
                        minTintPixels: int): bool =
  ## True when a tinted actor sprite (body, ghost) matches the frame.
  ## Generalises `matchesCrewmate` with caller-provided budgets for the
  ## different actor sprite shapes.
  var
    tintMatched = 0
    tintPixels = 0
    stableMatched = 0
    misses = 0
    stablePixels = 0
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let srcX =
        if flipH:
          sprite.width - 1 - sx
        else:
          sx
      let color = sprite.pixels[sprite.spriteIndex(srcX, sy)]
      if color == TransparentColorIndex:
        continue
      if stableCrewmateColor(color):
        inc stablePixels
      else:
        inc tintPixels
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        inc misses
      elif crewmatePixelMatches(color, frame[fy * ScreenWidth + fx]):
        if stableCrewmateColor(color):
          inc stableMatched
        else:
          inc tintMatched
      else:
        inc misses
      if misses > maxMisses:
        return false
  stablePixels >= minStablePixels and
    stableMatched >= minStablePixels and
    tintPixels >= minTintPixels and
    tintMatched >= minTintPixels

proc actorColorIndex*(frame: openArray[uint8], sprite: Sprite,
                     x, y: int, flipH: bool): int =
  ## Returns the most likely tint colour index for an actor sprite.
  var counts: array[PlayerColorCount, int]
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let srcX =
        if flipH:
          sprite.width - 1 - sx
        else:
          sx
      let color = sprite.pixels[sprite.spriteIndex(srcX, sy)]
      if color != TintColor:
        continue
      let
        fx = x + sx
        fy = y + sy
      if fx < 0 or fy < 0 or fx >= ScreenWidth or fy >= ScreenHeight:
        continue
      let index = playerColorIndex(frame[fy * ScreenWidth + fx])
      if index >= 0:
        inc counts[index]
  var bestCount = 0
  result = -1
  for i, count in counts:
    if count > bestCount:
      bestCount = count
      result = i

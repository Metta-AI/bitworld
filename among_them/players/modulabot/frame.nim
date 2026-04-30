## Frame buffer helpers and the dynamic-pixel ignore mask.
##
## Phase 1 port from v2:393-647. The seven near-duplicate `ignore*Pixel`
## predicates collapse around a single `spriteCovers` primitive — call
## that the modulabot delta. Behavior is byte-for-byte equivalent to v2
## modulo the call-site refactor.

import pixie
import protocol
import ../../sim
import ../../../common/server

import types
import geometry

const
  RadarTaskColor* = 8'u8
    ## Palette index used for the offscreen-task radar dots. We mask
    ## these out of map-fit scoring because they are dynamic UI.
  PlayerIgnoreRadius* = 9
    ## Half-extent (in screen pixels) of the centred player sprite mask.
    ## Pixels within this radius of screen centre are excluded from
    ## map-fit scoring without requiring a sprite-shape match.
  KillIconX* = 1
    ## Top-left X of the imposter kill icon / ghost icon HUD slot.
  KillIconY* = ScreenHeight - SpriteSize - 1
    ## Top-left Y of the kill / ghost icon HUD slot.

# ---------------------------------------------------------------------------
# Pixel unpacking & palette
# ---------------------------------------------------------------------------

proc unpack4bpp*(packed: openArray[uint8], unpacked: var seq[uint8]) =
  ## Expands one packed 4-bit framebuffer into one byte per palette
  ## index. Re-sizes `unpacked` if necessary.
  let targetLen = packed.len * 2
  if unpacked.len != targetLen:
    unpacked.setLen(targetLen)
  for i, byte in packed:
    unpacked[i * 2] = byte and 0x0f
    unpacked[i * 2 + 1] = (byte shr 4) and 0x0f

proc sampleColor*(index: uint8): ColorRGBX =
  ## Converts one palette index to a Silky/Pixie color. Used by the
  ## debug viewer to render the bot's framebuffer.
  Palette[index and 0x0f].rgbx

# ---------------------------------------------------------------------------
# Sprite coverage primitive
# ---------------------------------------------------------------------------

proc spriteCovers*(sprite: Sprite, anchorX, anchorY, sx, sy: int,
                   flipH = false): bool =
  ## True when screen pixel (sx, sy) falls inside the non-transparent
  ## footprint of `sprite` anchored top-left at (anchorX, anchorY),
  ## optionally flipped horizontally.
  ##
  ## This is the single primitive the seven v2 ignore predicates were
  ## independently re-implementing. Localized perception-layer fix; no
  ## strategy change.
  let
    ix = sx - anchorX
    iy = sy - anchorY
  if ix < 0 or iy < 0 or ix >= sprite.width or iy >= sprite.height:
    return false
  let srcX = if flipH: sprite.width - 1 - ix else: ix
  sprite.pixels[sprite.spriteIndex(srcX, iy)] != TransparentColorIndex

# ---------------------------------------------------------------------------
# Per-source ignore predicates
# ---------------------------------------------------------------------------
#
# Each takes the full `Bot` because it reads multiple sub-records
# (perception lists + sprites + role state). The "leaf procs take
# explicit sub-records" rule from DESIGN.md §3 is for procs that *write*
# state; these are pure read-many helpers in the inner pixel loop, so
# Bot-as-context is the cleanest signature.

proc ignoreTaskIconPixel*(bot: Bot, sx, sy: int): bool =
  for icon in bot.percep.visibleTaskIcons:
    if bot.sprites.task.spriteCovers(icon.x, icon.y, sx, sy):
      return true
  false

proc ignoreCrewmatePixel*(bot: Bot, sx, sy: int): bool =
  for crewmate in bot.percep.visibleCrewmates:
    if bot.sprites.player.spriteCovers(crewmate.x, crewmate.y, sx, sy,
                                       crewmate.flipH):
      return true
  false

proc ignoreBodyPixel*(bot: Bot, sx, sy: int): bool =
  for body in bot.percep.visibleBodies:
    if bot.sprites.body.spriteCovers(body.x, body.y, sx, sy):
      return true
  false

proc ignoreGhostPixel*(bot: Bot, sx, sy: int): bool =
  for ghost in bot.percep.visibleGhosts:
    if bot.sprites.ghost.spriteCovers(ghost.x, ghost.y, sx, sy, ghost.flipH):
      return true
  false

proc ignoreKillIconPixel*(bot: Bot, sx, sy: int): bool =
  ## Mask out the imposter's HUD kill icon. Only active for imposters.
  if bot.role != RoleImposter:
    return false
  bot.sprites.killButton.spriteCovers(KillIconX, KillIconY, sx, sy)

proc ignoreGhostIconPixel*(bot: Bot, sx, sy: int): bool =
  ## Mask out the ghost-status HUD icon. Active any time we have at
  ## least one frame of ghost-icon evidence (so the icon doesn't poison
  ## scoring while we're still confirming ghost state).
  if not bot.isGhost and bot.ghostIconFrames == 0:
    return false
  bot.sprites.ghostIcon.spriteCovers(KillIconX, KillIconY, sx, sy)

# ---------------------------------------------------------------------------
# Composer
# ---------------------------------------------------------------------------

proc ignoreFramePixel*(bot: Bot, frameColor: uint8, sx, sy: int): bool =
  ## True for dynamic screen pixels that should be excluded from
  ## map-fit scoring. Composes the per-source predicates plus the
  ## radar-color short-circuit and the central player-sprite radius.
  ##
  ## Order is preserved from v2: cheap checks first, expensive
  ## list-iterating checks later. Do not reorder without rerunning the
  ## parity bake.
  if frameColor == RadarTaskColor:
    return true
  if bot.ignoreKillIconPixel(sx, sy):
    return true
  if bot.ignoreGhostIconPixel(sx, sy):
    return true
  if bot.ignoreBodyPixel(sx, sy):
    return true
  if bot.ignoreGhostPixel(sx, sy):
    return true
  if bot.ignoreTaskIconPixel(sx, sy):
    return true
  if bot.ignoreCrewmatePixel(sx, sy):
    return true
  abs(sx - PlayerScreenX) <= PlayerIgnoreRadius and
    abs(sy - PlayerScreenY) <= PlayerIgnoreRadius

## Motion controller: velocity inference, anti-stuck jiggle, button mask
## formatting from a desired waypoint.
##
## Phase 1 port from v2:2350-2364 (mask helpers), v2:2366-2418 (motion
## state + jiggle), v2:3311-3383 (coast / brake / waypoint masks).
##
## Sub-record signatures: this is the layer where Q4 explicit-signature
## convention pays off — `updateMotionState` mutates `Motion`, reads
## `Perception` and a single `lastMask` byte. The caller is the
## orchestrator in `bot.nim`, which has all of those in scope.

import protocol
import ../../sim

import types
import geometry

const
  StuckFrameThreshold* = 8
    ## Frames of zero motion despite directional input before we trigger
    ## the anti-stuck jiggle.
  JiggleDuration* = 16
    ## Ticks the jiggle remains active after triggering.
  CoastLookaheadTicks* = 8
    ## How many friction-decayed ticks `coastDistance` extrapolates.
  CoastArrivalPadding* = 1
    ## Pixels of slack added to coast-arrival check.
  SteerDeadband* = 2
    ## Per-axis deadband below which `axisMask` produces no input.
  BrakeDeadband* = 1
    ## Pixels of slack on the brake-into-velocity check.

# ---------------------------------------------------------------------------
# Mask predicates
# ---------------------------------------------------------------------------

proc movementName*(mask: uint8): string =
  ## Compact movement label for one input mask. Used by the diagnostic
  ## summary string.
  if (mask and ButtonLeft) != 0:
    return "left"
  if (mask and ButtonRight) != 0:
    return "right"
  if (mask and ButtonUp) != 0:
    return "up"
  if (mask and ButtonDown) != 0:
    return "down"
  "idle"

proc hasMovement*(mask: uint8): bool =
  ## True when an input mask contains any directional bit.
  (mask and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) != 0

# ---------------------------------------------------------------------------
# Velocity sampling and jiggle bookkeeping
# ---------------------------------------------------------------------------

proc updateMotionState*(motion: var Motion, percep: Perception,
                       lastMask: uint8) =
  ## Tracks current frame-to-frame player velocity and updates the
  ## anti-stuck counter. Identical control flow to v2:2366-2398.
  ##
  ## NOTE: we intentionally do NOT divide velocity by
  ## `motion.frameAdvance`. Empirically, dividing produced worse
  ## localization stability in the cogames bitworld_runner path
  ## (self-color oscillation increased 4x). The raw delta is what the
  ## downstream coast/brake/stuck-detection code was tuned against and
  ## it's more tolerant of occasional 5-tick bursts than of a velocity
  ## that doesn't match the underlying position delta. `frameAdvance`
  ## is still consumed for `bot.frameTick` bookkeeping in the FFI
  ## (timer-based logic like kill cooldown, vote listen windows).
  if not percep.localized:
    motion.haveMotionSample = false
    motion.velocityX = 0
    motion.velocityY = 0
    motion.stuckFrames = 0
    motion.jiggleTicks = 0
    return

  let
    x = percep.playerWorldX()
    y = percep.playerWorldY()
  if motion.haveMotionSample and lastMask.hasMovement():
    motion.velocityX = x - motion.previousPlayerWorldX
    motion.velocityY = y - motion.previousPlayerWorldY
    let moved = abs(motion.velocityX) + abs(motion.velocityY)
    if moved == 0:
      inc motion.stuckFrames
    else:
      motion.stuckFrames = 0
    if motion.stuckFrames >= StuckFrameThreshold:
      motion.stuckFrames = 0
      motion.jiggleTicks = JiggleDuration
      motion.jiggleSide = 1 - motion.jiggleSide
  else:
    motion.velocityX = 0
    motion.velocityY = 0
    motion.stuckFrames = 0

  motion.haveMotionSample = true
  motion.previousPlayerWorldX = x
  motion.previousPlayerWorldY = y

proc applyJiggle*(motion: var Motion, mask: uint8): uint8 =
  ## Adds a short perpendicular correction while keeping the intended
  ## direction held. Decrements the jiggle timer; returns the original
  ## mask once the timer expires.
  result = mask
  if motion.jiggleTicks <= 0 or not mask.hasMovement():
    return
  dec motion.jiggleTicks
  let
    vertical = (mask and (ButtonUp or ButtonDown)) != 0
    horizontal = (mask and (ButtonLeft or ButtonRight)) != 0
  if vertical and not horizontal:
    if motion.jiggleSide == 0:
      result = result or ButtonLeft
    else:
      result = result or ButtonRight
  elif horizontal and not vertical:
    if motion.jiggleSide == 0:
      result = result or ButtonUp
    else:
      result = result or ButtonDown

# ---------------------------------------------------------------------------
# Coast / brake / steering math
# ---------------------------------------------------------------------------

proc coastDistance*(velocity: int): int =
  ## Pixels current velocity will carry without input under the sim's
  ## friction model. Matches v2's `FrictionNum/FrictionDen` constants.
  var speed = abs(velocity)
  for _ in 0 ..< CoastLookaheadTicks:
    if speed <= 0:
      break
    result += speed
    speed = (speed * FrictionNum) div FrictionDen

proc shouldCoast*(delta, velocity: int): bool =
  ## True when current velocity will carry to within
  ## `CoastArrivalPadding` of the target without further input.
  if delta > 0 and velocity > 0:
    return delta <= coastDistance(velocity) + CoastArrivalPadding
  if delta < 0 and velocity < 0:
    return -delta <= coastDistance(velocity) + CoastArrivalPadding
  false

proc axisMask*(delta, velocity: int,
              negativeMask, positiveMask: uint8): uint8 =
  ## Steering for one axis with coasting and braking. Verbatim from
  ## v2:3327-3345 modulo the explicit `false` return on the missing
  ## fall-through path (kept to silence Nim's "no return" check).
  if delta > SteerDeadband:
    if shouldCoast(delta, velocity):
      return 0
    if velocity > 1 and delta <= abs(velocity) + BrakeDeadband:
      return negativeMask
    return positiveMask
  if delta < -SteerDeadband:
    if shouldCoast(delta, velocity):
      return 0
    if velocity < -1 and -delta <= abs(velocity) + BrakeDeadband:
      return positiveMask
    return negativeMask
  if velocity > 0:
    return negativeMask
  if velocity < 0:
    return positiveMask
  0

proc preciseAxisMask*(delta, velocity: int,
                     negativeMask, positiveMask: uint8): uint8 =
  ## Final-approach steering. Same as `axisMask` but without the
  ## `SteerDeadband` — every pixel of error is corrected. Used inside
  ## `TaskPreciseApproachRadius` of the goal.
  if delta > 0:
    if shouldCoast(delta, velocity):
      return 0
    if velocity > 1 and delta <= abs(velocity) + BrakeDeadband:
      return negativeMask
    return positiveMask
  if delta < 0:
    if shouldCoast(delta, velocity):
      return 0
    if velocity < -1 and -delta <= abs(velocity) + BrakeDeadband:
      return positiveMask
    return negativeMask
  if velocity > 0:
    return negativeMask
  if velocity < 0:
    return positiveMask
  0

proc maskForWaypoint*(percep: Perception, motion: Motion,
                     waypoint: PathStep): uint8 =
  ## Converts a lookahead waypoint into a momentum-aware controller
  ## mask. Returns 0 when the waypoint is not found.
  if not waypoint.found:
    return 0
  let
    dx = waypoint.x - percep.playerWorldX()
    dy = waypoint.y - percep.playerWorldY()
  result = result or axisMask(dx, motion.velocityX, ButtonLeft, ButtonRight)
  result = result or axisMask(dy, motion.velocityY, ButtonUp, ButtonDown)

proc preciseMaskForGoal*(percep: Perception, motion: Motion,
                        goalX, goalY: int): uint8 =
  ## Converts a nearby goal into exact final-approach steering.
  let
    dx = goalX - percep.playerWorldX()
    dy = goalY - percep.playerWorldY()
  result = result or preciseAxisMask(dx, motion.velocityX,
                                     ButtonLeft, ButtonRight)
  result = result or preciseAxisMask(dy, motion.velocityY,
                                     ButtonUp, ButtonDown)

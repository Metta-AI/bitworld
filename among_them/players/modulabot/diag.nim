## Diagnostic helpers: `thought`, `intent`, formatting procs for the
## debug viewer. Q5 resolved: procs that need diagnostic state take
## `var Bot`, not `var Diag`, so the call sites elsewhere (motion,
## tasks, policy modules) stay clean.
##
## Phase 1 port from v2:2372-2392, v2:2451-2463, v2:2501-2537. The
## per-suspect / known-imposter formatters live in `evidence.nim`
## because they need access to identity sub-record helpers.

import std/strutils
import protocol

import types

proc thought*(bot: var Bot, text: string) =
  ## Stores the most recent debug-thought string. Only updates when
  ## changed so the viewer can render a stable line.
  if text != bot.diag.lastThought:
    bot.diag.lastThought = text

proc roleName*(role: BotRole): string =
  case role
  of RoleUnknown: "unknown"
  of RoleCrewmate: "crewmate"
  of RoleImposter: "imposter"

proc cameraLockName*(lock: CameraLock): string =
  case lock
  of NoLock: "none"
  of LocalFrameMapLock: "local frame"
  of FrameMapLock: "frame map"

proc inputMaskSummary*(mask: uint8): string =
  ## Human-readable description of an input mask.
  var parts: seq[string] = @[]
  if (mask and ButtonUp) != 0: parts.add("up")
  if (mask and ButtonDown) != 0: parts.add("down")
  if (mask and ButtonLeft) != 0: parts.add("left")
  if (mask and ButtonRight) != 0: parts.add("right")
  if (mask and ButtonA) != 0: parts.add("a")
  if (mask and ButtonB) != 0: parts.add("b")
  if (mask and ButtonSelect) != 0: parts.add("select")
  if parts.len == 0:
    return "idle"
  parts.join(", ")

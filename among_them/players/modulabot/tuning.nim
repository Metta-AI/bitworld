## Cross-cutting tuning knobs.
##
## Q9 resolved: this module holds *only* constants that we'd actually want
## to A/B test or that are read by more than one module. Algorithm-internal
## magic numbers (patch hash bases, A* deadbands, voting cell layout, ...)
## stay in their owning module's local `const` block.
##
## Phase 0 only seeds the new modulabot-specific knobs. v2's bulk constant
## block will be unpacked into per-module `const` blocks during phase 1
## ports, with anything that crosses module boundaries promoted up here.

const
  TeleportThresholdPx* = 32
    ## Camera jump (in world pixels) above which we re-run actor sprite
    ## scans against the post-lock camera. Below this, the prev-frame
    ## scans are trusted as still accurate. Set during the parity bake.
    ## Too tight wastes scans every frame; too loose lets stale matches
    ## poison post-vote frames. See DESIGN.md §5 for context.

  # -----------------------------------------------------------------
  # Long-term memory (DESIGN.md §13)
  # -----------------------------------------------------------------

  MemorySightingDedupTicks* = 5
    ## A new `SightingEvent` for colour `c` is suppressed if the
    ## previous sighting for `c` fell within this many ticks AND
    ## within `MemorySightingDedupPixels` world-px. Per-colour
    ## summary (lastSeenTick / lastSeenX / lastSeenY) updates on
    ## every visible frame regardless; dedup only bounds raw-log
    ## growth.
  MemorySightingDedupPixels* = 16
    ## Companion to `MemorySightingDedupTicks`. See there.
  MemoryBodyDedupPx* = 6
    ## Round-lifetime body dedup threshold. A body seen more than
    ## this many world-px away from any existing `BodyEvent` is
    ## appended as a distinct discovery. Smaller than
    ## `SpriteSize` on purpose: bodies don't move, so any real
    ## second body is further than a sprite's worth of jitter.
  MemoryAlibiCooldownTicks* = 20
    ## Per-(colour, task) dedup — suppress an `AlibiEvent` for the
    ## same colour + task if one fired within this many ticks.
  MemoryAlibiTaskRadiusPx* = 12
    ## Manhattan distance (world px) from a visible crewmate's centre
    ## to a task station's centre at or below which we treat the
    ## crewmate as "at the task terminal" and emit an `AlibiEvent`.
    ## Task rects are small (~14-18 px on a side) and the crewmate
    ## sprite occupies most of the rect when they're standing on it,
    ## so a slightly-larger-than-rect-half radius covers the usual
    ## doing-the-task pose without picking up crewmates merely
    ## passing through an adjacent corridor.

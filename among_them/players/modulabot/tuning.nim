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

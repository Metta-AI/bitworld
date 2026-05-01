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
  MemorySelfKeyframeCap* = 64
    ## Maximum `SelfKeyframe` entries retained per round. Oldest
    ## trimmed first on overflow. 64 gives ~3.5 transitions/min over
    ## a 18-min game ceiling — comfortable headroom vs. typical
    ## room-change frequency. Feeds `my_location_history` in
    ## imposter contexts (Sprint 2.2).
  MemoryAlibiMatchRadius* = 28
    ## World-pixel radius around a task centre within which a visible
    ## crewmate counts as "at the terminal". 28 ≈ 2.3 × CollisionW —
    ## generous enough to catch a crewmate standing at the interact
    ## prompt on either side of the station, tight enough that a
    ## crewmate just walking past a doorway doesn't score an alibi.
    ## Sprint 2.3 (`LLM_SPRINTS.md §2.3`).

  # -----------------------------------------------------------------
  # LLM voting integration (LLM_VOTING.md)
  # -----------------------------------------------------------------

  LlmAccuseThreshold* = 0.75'f32
    ## Top-suspect likelihood above which the crewmate transitions
    ## from FormingHypothesis directly to Accusing (queue a chat
    ## message naming the suspect). Below, we stay in Listening and
    ## wait for other players to speak first.
  LlmVoteThreshold* = 0.50'f32
    ## Top-suspect likelihood required to vote for that suspect
    ## (crewmate). Below, fall back to `evidenceBasedSuspect`. Below
    ## that, skip.
  LlmChatReactionCooldownTicks* = 48
    ## Minimum gap between two react-call dispatches. At 24 fps this is
    ## 2.0 s; matches LLM_VOTING.md §9's 2 000 ms recommendation. Keeps
    ## reactions from firing every frame when several chat lines land
    ## in quick succession.
  LlmMaxChatLen* = 72
    ## Hard cap on chat message length after LLM generation. Matches
    ## the cogames `AmongThemMeetingDirective` 75-char limit with a
    ## small margin for our own punctuation.
  LlmMaxContextLen* = 7500
    ## Soft target for context-JSON serialization size in bytes
    ## ("aim for ≤ this; trim on the way to it"). The Sprint 3.4 trim
    ## policy uses this as the budget for `trimContextInPlace` —
    ## fields are dropped one tier at a time until the serialized
    ## form fits.
  LlmMaxContextBytes* = 15500
    ## Hard ceiling for the FFI buffer crossing into Python (Sprint
    ## 3.4). The Python-side buffer caps at 16 384 bytes
    ## (`_LLM_CONTEXT_BUFFER_SIZE` in `cogames/amongthem_policy.py`);
    ## this leaves ~900 bytes of safety margin for NUL terminators
    ## and any future header bytes. If the trimmed context still
    ## exceeds this, the dispatch is aborted with an
    ## `llm_error{reason: "context_overflow"}` and the state
    ## machine falls back to rule-based voting.
  LlmPersuadeEnabled* = false
    ## Gate on the optional Stage 4 persuasion call. Off by default to
    ## keep the per-meeting call count low; flip for aggressive
    ## configurations.

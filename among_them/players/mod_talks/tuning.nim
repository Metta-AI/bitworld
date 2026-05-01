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
    ## Cap on serialized context JSON. Protects against runaway
    ## memory/chat-history bloat on long rounds. If the context exceeds
    ## this, we truncate older `chatHistory` entries and older
    ## `memory.sightings` entries before serialising. See
    ## `llm.nim:buildContext`.
  LlmPersuadeEnabled* = false
    ## Gate on the optional Stage 4 persuasion call. Off by default to
    ## keep the per-meeting call count low; flip for aggressive
    ## configurations.

## Canonical tuning snapshot for the trace manifest.
##
## A single proc that returns a JSON object containing every const that
## influences policy. The trace writer dumps this into
## `manifest.tuning_snapshot` so an outer-loop harness can correlate
## game outcomes with the bot's compiled-in tunables.
##
## Adding a new tunable to any policy module also requires extending
## the relevant section here. The TRACING.md design (§7.9, §10.3) calls
## this out as the single point of truth.

import std/json

import tuning
import voting
import motion
import evidence
import policy_imp
import tasks
import actors
import path
import sprite_match
import localize
import frame

proc tuningSnapshot*(): JsonNode =
  ## Returns a JSON object snapshot of every policy-relevant const.
  result = %*{
    # tuning.nim
    "TeleportThresholdPx":              TeleportThresholdPx,
    "MemorySightingDedupTicks":         MemorySightingDedupTicks,
    "MemorySightingDedupPixels":        MemorySightingDedupPixels,
    "MemoryBodyDedupPx":                MemoryBodyDedupPx,
    "MemoryAlibiCooldownTicks":         MemoryAlibiCooldownTicks,
    "MemoryAlibiTaskRadiusPx":          MemoryAlibiTaskRadiusPx,
    # voting.nim
    "VoteCellW":                        VoteCellW,
    "VoteCellH":                        VoteCellH,
    "VoteListenTicks":                  VoteListenTicks,
    "VoteChatTextX":                    VoteChatTextX,
    "VoteChatChars":                    VoteChatChars,
    # motion.nim
    "StuckFrameThreshold":              StuckFrameThreshold,
    "JiggleDuration":                   JiggleDuration,
    "CoastLookaheadTicks":              CoastLookaheadTicks,
    "CoastArrivalPadding":              CoastArrivalPadding,
    "SteerDeadband":                    SteerDeadband,
    "BrakeDeadband":                    BrakeDeadband,
    # evidence.nim
    "WitnessNearBodyRadius":            WitnessNearBodyRadius,
    # policy_imp.nim
    "ImposterFollowSwapMinTicks":       ImposterFollowSwapMinTicks,
    "ImposterFollowApproachRadius":     ImposterFollowApproachRadius,
    "ImposterFakeTaskNearRadius":       ImposterFakeTaskNearRadius,
    "ImposterFakeTaskMinTicks":         ImposterFakeTaskMinTicks,
    "ImposterFakeTaskMaxTicks":         ImposterFakeTaskMaxTicks,
    "ImposterFakeTaskCooldownTicks":    ImposterFakeTaskCooldownTicks,
    "ImposterFakeTaskChance":           ImposterFakeTaskChance,
    "ImposterFakeTaskChanceDenom":      ImposterFakeTaskChanceDenom,
    "ImposterSelfReportRecentTicks":    ImposterSelfReportRecentTicks,
    "ImposterSelfReportRadius":         ImposterSelfReportRadius,
    "ImposterVentCooldownTicks":        ImposterVentCooldownTicks,
    "ImposterCentralRoomStuckTicks":    ImposterCentralRoomStuckTicks,
    "ImposterCentralRoomLeaveTicks":    ImposterCentralRoomLeaveTicks,
    "ImposterCentralRoomMinCrewmates":  ImposterCentralRoomMinCrewmates,
    # tasks.nim
    "HomeSearchRadius":                 HomeSearchRadius,
    "RadarMatchTolerance":              RadarMatchTolerance,
    "TaskIconSearchRadius":             TaskIconSearchRadius,
    "TaskIconInspectSize":              TaskIconInspectSize,
    "TaskClearScreenMargin":            TaskClearScreenMargin,
    "TaskIconMissThreshold":            TaskIconMissThreshold,
    "TaskInnerMargin":                  TaskInnerMargin,
    "TaskHoldPadding":                  TaskHoldPadding,
    "TaskPreciseApproachRadius":        TaskPreciseApproachRadius,
    "KillApproachRadius":               KillApproachRadius,
    # actors.nim
    "GhostIconMaxMisses":               GhostIconMaxMisses,
    "GhostIconFrameThreshold":          GhostIconFrameThreshold,
    "RadarPeripheryMargin":             RadarPeripheryMargin,
    "CrewmateSearchRadius":             CrewmateSearchRadius,
    "BodySearchRadius":                 BodySearchRadius,
    "BodyMaxMisses":                    BodyMaxMisses,
    "BodyMinStablePixels":              BodyMinStablePixels,
    "BodyMinTintPixels":                BodyMinTintPixels,
    "GhostSearchRadius":                GhostSearchRadius,
    "GhostMaxMisses":                   GhostMaxMisses,
    "GhostMinStablePixels":             GhostMinStablePixels,
    "GhostMinTintPixels":               GhostMinTintPixels,
    "TaskIconExpectedSearchRadius":     TaskIconExpectedSearchRadius,
    # path.nim
    "PathLookahead":                    PathLookahead,
    # sprite_match.nim
    "TaskIconMaxMisses":                TaskIconMaxMisses,
    "TaskIconMaybeMisses":              TaskIconMaybeMisses,
    "KillIconMaxMisses":                KillIconMaxMisses,
    "CrewmateMaxMisses":                CrewmateMaxMisses,
    "CrewmateMinStablePixels":          CrewmateMinStablePixels,
    "CrewmateMinBodyPixels":            CrewmateMinBodyPixels,
    # localize.nim
    "FullFrameFitMaxErrors":            FullFrameFitMaxErrors,
    "LocalFrameFitMaxErrors":           LocalFrameFitMaxErrors,
    "FrameFitMinCompared":              FrameFitMinCompared,
    "LocalFrameSearchRadius":           LocalFrameSearchRadius,
    "PatchSize":                        PatchSize,
    "PatchMaxMatches":                  PatchMaxMatches,
    "PatchTopCandidates":               PatchTopCandidates,
    "PatchMinVotes":                    PatchMinVotes,
    "InterstitialBlackPercent":         InterstitialBlackPercent,
    # frame.nim
    "RadarTaskColor":                   int(RadarTaskColor),
    "PlayerIgnoreRadius":               PlayerIgnoreRadius,
    "KillIconX":                        KillIconX
  }

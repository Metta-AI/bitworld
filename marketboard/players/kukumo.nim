# Kukumo -- Lalafell. The hoarder.
# Gathers obsessively, fills inventory before considering a sell trip.
# Extremely patient — won't interrupt a gathering run unless gear appears
# at a price too good to ignore. Pure supply chain, never crafts.

import std/options
import common
import utility

type
  BotState* = object
    util*: UtilityBot
    phase*: string
    ticksInPhase*: int

const KukumoWeights* = PersonalityWeights(
  gatherWoodBias: 1.5,
  gatherStoneBias: 1.5,
  sellUrgency: 0.6,
  gearPriority: 1.2,
  batchPatience: 2.0,
  interruptThreshold: 3.0,
)

proc decide*(bot: var BotState, state: GameState): uint8 =
  bot.util.weights = KukumoWeights
  result = bot.util.decide(state)
  bot.phase = bot.util.phase
  if bot.util.commitment.isSome:
    bot.ticksInPhase = bot.util.commitment.get().ticksActive
  else:
    bot.ticksInPhase = 0

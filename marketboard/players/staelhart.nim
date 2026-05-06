# Staelhart -- The Crafter.
# Buys raw materials from the market, crafts gear, sells it.
# Pure economy engine: never gathers, converts materials into gear.
# Dumps crafted gear quickly to keep gold flowing.

import std/options
import common
import utility

type
  BotState* = object
    util*: UtilityBot
    phase*: string
    ticksInPhase*: int

const StaelhartWeights* = PersonalityWeights(
  gatherWoodBias: 0.0,
  gatherStoneBias: 0.0,
  sellUrgency: 3.0,
  gearPriority: 1.5,
  batchPatience: 0.0,
  interruptThreshold: 2.0,
  craftInterest: 3.0,
  buyMaterialsUrgency: 2.5,
)

proc decide*(bot: var BotState, state: GameState): uint8 =
  bot.util.weights = StaelhartWeights
  result = bot.util.decide(state)
  bot.phase = bot.util.phase
  if bot.util.commitment.isSome:
    bot.ticksInPhase = bot.util.commitment.get().ticksActive
  else:
    bot.ticksInPhase = 0

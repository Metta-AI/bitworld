# K'torra -- The Opportunist.
# Sells frequently, interrupts easily, reacts to market opportunities.
# Fast turnover: gathers 2-3 items then sells immediately.
# Aggressive gear buyer -- always wants the next upgrade.

import std/options
import common
import utility

type
  BotState* = object
    util*: UtilityBot
    phase*: string
    ticksInPhase*: int

const KtorraWeights* = PersonalityWeights(
  gatherWoodBias: 1.0,
  gatherStoneBias: 1.0,
  sellUrgency: 2.0,
  gearPriority: 2.5,
  batchPatience: 0.5,
  interruptThreshold: 1.5,
)

proc decide*(bot: var BotState, state: GameState): uint8 =
  bot.util.weights = KtorraWeights
  result = bot.util.decide(state)
  bot.phase = bot.util.phase
  if bot.util.commitment.isSome:
    bot.ticksInPhase = bot.util.commitment.get().ticksActive
  else:
    bot.ticksInPhase = 0

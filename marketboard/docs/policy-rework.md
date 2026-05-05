# Bot Policy Rework: FSM → Utility System

## Problem

Current bots use FSMs (BotPhase enums with hard-coded transitions). This causes:

1. **Gather-sell-gather-sell loops** — bots sell after 1 item because the FSM transitions to PathToSellStall as soon as `hasSellableMaterials` is true. No concept of "is this trip worth it?"
2. **Game FSM × Bot FSM mapping hell** — the game has PlayerState (Idle, Gathering, Crafting, AtSellStall, AtBuyStall) and the bot has ~30 BotPhase states. Half the bot phases exist just to get into a game state, making debugging an N×M problem.
3. **Rigid behavior** — adding a new stall type or item means rewiring transitions across 7 bot files. New personalities require writing new state machines from scratch.
4. **No planning** — bots react to the current tick, they never think "I need 5 wood to make this trip worth it" or "I should craft ChainHat because that's the gap in the market."

Only ~32% of current bot code is actual decision logic. ~40% is navigation/interaction plumbing, ~26% is state management boilerplate.

## Proposed Architecture: Utility + Commitment

```
Bot = {
  weights: PersonalityWeights   # what makes each bot unique
  commitment: Option[Action]    # what I'm currently doing
  memory: Blackboard            # cached market data, gathered counts, goals
}

each tick:
  score all possible actions given (game_state, memory, weights)
  if commitment is active and still valid and nothing scores 2x better:
    continue executing commitment
  else:
    pick highest-scoring action, commit to it

  return button_press to advance current commitment
```

### Key Concepts

**Actions** — atomic things a bot can commit to:
- GatherMaterial(material, count) — gather N of a material at nearest uncontested node
- SellInventory — walk to sell stall, list all sellable items
- BuyGear(item) — walk to buy stall, purchase specific gear
- BuyMaterials(matA, countA, matB, countB) — buy crafting inputs
- CraftItem(tier) — walk to craft station, craft
- CancelListings — walk to cancel stall, clear stale listings
- SwitchRole(role) — walk to role stall, switch
- Idle/Wait — do nothing (useful when no good option exists)

**Scoring** — each action gets a score based on:
- Expected value (gold gained, gear tier improvement)
- Travel cost (distance to target in ticks)
- Opportunity cost (what am I giving up?)
- Personality weights (per-bot tuning)

**Commitment** — once an action is chosen, stick with it unless:
- It completes
- It becomes invalid (node depleted, item sold out, etc.)
- Another action scores 2x better (interrupt threshold, tunable per personality)

**Executor** — shared code that converts (action + game_state) into button presses:
- Handles all pathfinding, stall interaction, button sequences
- Same executor for every bot personality
- Lives in common.nim, written once

### Scoring Naturally Solves Batching

```
sell_score = (items_to_sell * expected_price) / estimated_travel_ticks
gather_score = (value_of_next_item) / ticks_to_gather
```

With 1 item, sell might score 0.075. With 5 items, sell scores 0.375. Gathering scores ~0.06-0.1 depending on node distance. The crossover happens organically — bots near a stall sell sooner, bots far away batch more. No hard-coded batch size needed.

### Spatial Awareness Comes Free

Distance-to-target is already in the scoring denominator. A node 2 tiles away scores higher than one 10 tiles away. Contested nodes get a penalty (same `leastContestedNode` concept). No special-case code needed.

### Market Visibility Comes Free

Memory/blackboard holds `lastSeenListings`, updated only when at stalls. Scoring functions use cached data. Buy actions can only score high when the bot has recent market knowledge. A bot that hasn't visited a stall recently won't know about new gear — naturally.

## Personality = Weights

Each bot is defined by a weight table, not a state machine:

| Weight | StillForge | Zorori | Solenne |
|--------|-----------|--------|---------|
| gather_wood_bias | 2.0 | 1.0 | 1.0 |
| gather_stone_bias | 0.5 | 1.0 | 1.0 |
| sell_urgency | 1.0 | 0.7 | 1.2 |
| gear_priority | 1.5 | 1.0 | 2.0 |
| craft_interest | 0.0 | 0.0 | 1.5 |
| batch_patience | 0.8 | 1.5 | 1.0 |
| interrupt_threshold | 2.0 | 2.0 | 1.5 |

New personality = new row in the table. Could even be a JSON/config file instead of code.

## Executor Layer

The executor handles the mechanical button-pressing for each action type. This is the ~40% of current code that's pure navigation/interaction boilerplate, extracted once:

```nim
proc executeAction(action: Action, state: GameState, nav: var Navigator): uint8 =
  case action.kind
  of akGather:
    if state.player.state == "Gathering": return holdGatherInput()
    if not atNode(state, action.targetNode): return walkToward(action.targetNode)
    return startGather()
  of akSell:
    if state.player.state == "AtSellStall": return sellSequenceInput(action, state)
    if not atStall(state, "SellStall"): return walkToward(nearestSellStall(state))
    return interactStall()
  # ... etc
```

The executor doesn't decide *what* to do — it only decides *how* to press buttons for the current commitment. Clean separation.

## Implementation Plan

### Phase 1: Framework
- Define Action types, scoring interface, commitment logic in a new `marketboard/players/utility.nim`
- Implement shared executor for all action types
- Port the navigation/interaction code from existing bots

### Phase 2: First Utility Bot
- Create one new bot (new name, new personality) using the utility framework
- Test alongside existing FSM bots in the same simulation
- Validate it can reach T3 gear

### Phase 3: More Personalities
- Add 2-3 more utility bots with different weight profiles
- Tune interrupt thresholds and scoring curves
- Compare performance vs FSM bots

### Phase 4: Retire FSM Bots (optional)
- Once utility bots are proven, phase out old FSM bots
- Or keep them as "dumb" opponents for variety

## New Bot Roster

### Kukumo (Lalafell)
The hoarder. Gathers obsessively, fills inventory before even considering a sell trip. Extremely patient — won't interrupt a gathering run unless gear appears at a price too good to ignore. Prefers whichever material is scarcer on the market, but once committed to a node cluster, stays until it's depleted. Sells in bulk, prices slightly above market to maximize per-trip value.

- High batch_patience, high gather bias, low sell_urgency
- Interrupt threshold: very high (3x) — almost never breaks commitment
- Crafts: never. Pure supply chain.

### K'torra (Miqo'te)
The opportunist. Re-evaluates constantly, always sniffing for the best deal. Will abandon a half-gathered node if gear drops to a good price. Sells frequently in small batches because she's always near a stall anyway. Switches roles if the market shifts — gathers when materials are scarce, crafts when materials are cheap and gear is expensive.

- Low interrupt threshold (1.5x), high gear_priority, moderate everything else
- Sell urgency: high. Would rather sell 2 items now than walk further for 3.
- Crafts: opportunistically, when materials are cheaper to buy than gather

### Staelhart (Roegadyn)
The crafter. Wants to be at a craft station. Buys materials in bulk, crafts full sets, sells below market to move inventory fast. Doesn't gather — views it as beneath him. Will tank prices to clear stock, then buy more materials. Only interrupts crafting to buy his own gear upgrades.

- craft_interest: maximum. gather bias: zero.
- Sell urgency: very high (wants empty inventory to craft more)
- Prices aggressively low — market maker, not profit maximizer
- Interrupt threshold: moderate (2x) — will stop to upgrade own gear

### Arloisaux (Elezen)
The strategist. Thinks in terms of the full production chain. Gathers materials specifically to craft with — doesn't sell raw materials unless the market is starved. Crafts gear for himself first, then for sale. Patient, methodical, won't move until the plan is complete. Treats sell stall visits as a chance to survey the market and adjust strategy.

- Moderate everything, but high "plan coherence" — scores multi-step chains
- Prefers self-sufficiency (gather → craft → equip) over market trading
- Low sell_urgency for raw materials, high for crafted gear
- Interrupt threshold: moderate (2x)

### Raraji (Lalafell)
The undercutter. Lives at the sell stall. Gathers just enough to keep listings active, then camps the market undercutting everyone by 1g. Cancels and relists constantly to stay cheapest. Doesn't care about gear progression — wants gold. Will buy cheap materials to relist at a markup if the spread is good enough.

- Extremely high sell_urgency, low batch_patience
- cancel_aggression: high — relists frequently
- gear_priority: very low (money > power)
- Unique scoring: values gold/tick above gear progression

## Diagnostic Findings (seed=0, 10k ticks, fixed lineup)

### Time Breakdown

Gatherers spend **73-81% of their time walking**. Only 11-17% is productive gathering.

```
StillForge1  travel=81%  gather=12%  sell=2%   buy=0%
Colm1        travel=79%  gather=13%  sell=3%   buy=0%
Rkhenna1     travel=79%  gather=12%  sell=3%   buy=0%
Zorori1      travel=76%  gather=11%  sell=9%   buy=0%
Pipitori1    travel=73%  gather=17%  sell=4%   buy=1%
Solenne1     travel=61%  gather=1%   craft=23% sell=7%  buy=4%
IronWorks1   travel=59%  gather=0%   craft=13% sell=18% buy=3%
```

### Root Causes

1. **Sell-after-1 item**: Every gatherer transitions to PathToSellStall the moment `hasSellableMaterials` is true (1 item). A gather-sell cycle takes ~150-200 ticks (walk to node + gather + walk to stall + sell interaction) for 3g of value.

2. **Enormous walk distances**: StillForge takes 120 ticks to reach its first node, gathers for 47 ticks, then walks 60 ticks back to sell. That's 180 ticks of walking for 1 item.

3. **Phase thrashing**: Zorori flip-flops between PathToNode↔EvaluateSell every tick for 20+ ticks straight, doing nothing productive.

4. **Throughput math**: ~1 item per 150-200 ticks per gatherer. 5 gatherers × 10k ticks ÷ 175 avg = ~285 items total production. Crafters need 3 items per craft, so ~95 crafts total. That's nowhere near enough to gear 7 bots through 3 tiers (need 105 pieces minimum).

### End-State Economy (10k ticks)

- Total gold held: 3,476g (started 3,500g) — almost no gold creation
- Market listings: 138g total value — nearly empty
- Zero Ironwood/Iron on market — T3 economy completely dead
- Solenne selling T1 gear nobody needs (everyone already T1+)
- IronWorks holding 4 unsold gear pieces in inventory
- Gear: 12×T1, 23×T2, 0×T3 — stuck at T2→T3 transition

### What a Utility System Fixes

- **Batching**: `sell_score = items * price / travel_ticks` means 1 item at distance 40 scores 0.075, but 5 items scores 0.375. Gathering another item (score ~0.06) stays higher until the trip is worth making.
- **No thrashing**: commitment prevents re-evaluating every tick. Stay on task.
- **Travel efficiency**: distance is in the scoring denominator — bots naturally minimize walking.
- **Adaptive supply**: scoring by market scarcity means bots shift to what's actually needed.

## Tooling

### diagnose_bots

Full-trace diagnostic tool. Writes two files:
- `tmp/diag_trace.txt` — per-tick phase transitions for all bots
- `tmp/diag_report.txt` — final summary with time breakdowns, economy state, per-bot assets

```
nim c -o:tools/diagnose_bots tools/diagnose_bots.nim
./tools/diagnose_bots --seed:0 --ticks:10000 --interval:2500 --fixed-lineup
```

Flags:
- `--seed:N` — deterministic RNG seed
- `--ticks:N` — simulation length
- `--interval:N` — periodic status dump frequency in trace
- `--fixed-lineup` — one of each bot (otherwise random composition)
- `--filter:name` — only trace matching bots (but prefer grepping the file instead)

Report sections:
- Final State — per-bot role/gold/gear/listings
- Time Breakdown — travel/gather/craft/sell/buy/idle percentages per bot
- Economy Summary — per-bot inventory, all market listings with prices, totals
- Phase Ticks (detailed) — top 10 phases by time spent per bot

### batch_market

Quick validation tool. Runs N matches and reports gear levels.

```
nim c -o:tools/batch_market tools/batch_market.nim
./tools/batch_market --matches:1 --ticks:10000 --fixed-lineup
```

Success criteria: at least one bot at T3 in 10k ticks. If not, bots need to be smarter — don't increase ticks.

## Open Questions

- Should bots have explicit long-term goals ("get T3 gear") that influence scoring, or just let short-term utility naturally lead to progression?
- How to handle multi-step actions like crafting (need materials → buy → craft → sell)? Decompose into sub-actions scored independently, or score the whole chain and commit to the sequence?
- Should the interrupt threshold be fixed (2x) or adaptive (lower when idle, higher when mid-action)?
- How granular should scoring be? Per-tick re-eval or periodic (every 30 ticks)?

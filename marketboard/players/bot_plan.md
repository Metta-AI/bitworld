# Marketboard Bots

Bot players for the marketboard economy simulation. Each bot connects via a `/state` websocket endpoint that provides structured JSON game state, and sends standard 2-byte input packets. All bots share a common utility library for connection, state parsing, pathfinding, and market interaction.

## Architecture

```
marketboard/players/
  bot_plan.md      -- this file
  common.nim       -- shared: websocket client, JSON state parsing, input helpers, pathfinding
  still_forge.nim  -- specialist
  rkhenna.nim      -- flipper
  pipitori.nim     -- gouger
  colm.nim         -- undercutter
  zorori.nim       -- hoarder
  solenne.nim      -- generous
```

### Server-side: /state endpoint

A new websocket endpoint on the marketboard server that sends JSON state each tick. Bots receive full game state (own player, all visible objects, all market listings, other players' positions/roles/signals) and send the same uint8 input masks as human players.

### Common library (common.nim)

- WebSocket connection and reconnection
- JSON state parsing into typed Nim objects
- Input mask construction and sending
- Tile-based pathfinding (A* or simple greedy walk-toward)
- Interaction helpers: walk to tile, face object, press/hold A, cancel with B
- Market helpers: find cheapest listing, count available supply, estimate item values

## Bots

### Still Forge

Roegadyn Hellsguard. Specialist strategy.

Picks one role at game start and never switches. Gatherer-specialist travels to nodes, gathers materials, returns to hub, sells at a fair markup above base value. Crafter-specialist buys the cheapest materials, crafts gear, sells gear at a fair margin above material cost. Steady and reliable -- the backbone of a healthy economy.

Strategy:
- Choose role once (configurable, default gatherer)
- Gather: walk to nearest non-depleted node, gather, return to sell stall
- Sell: list at base price + 50% margin
- Craft: buy cheapest materials, craft at station, sell gear at material cost + 50%
- Never hoards, never gouges, never switches roles

Purpose: Baseline cooperative agent. If the economy works at all, Still Forge should profit steadily. Good integration test for the full gather-sell and buy-craft-sell loops.

### R'khenna Tia

Miqo'te Seeker of the Sun. Flipper strategy.

Monitors the market each cycle and switches roles based on where the profit is. If materials are expensive (gatherers are scarce), switches to gatherer. If gear is expensive (crafters are scarce), switches to crafter. Always chases the highest-margin opportunity.

Strategy:
- Each sell cycle: compare material prices vs gear prices
- If material sell price > base * 2: switch to gatherer, gather and sell
- If gear sell price > material cost * 3: switch to crafter, buy materials, craft, sell
- Sell at current market rate (matches existing listings)
- Role-switches frequently

Purpose: Tests role-switching dynamics and market responsiveness. In a healthy economy, R'khenna should end up wherever there's a shortage.

### Pipitori Lalori

Lalafell Dunesfolk. Gouger strategy.

Pure market manipulation. Buys up cheap listings (especially NPC seeds early game) and relists at 3-4x the price. Never gathers or crafts -- purely a middleman extracting value from price spreads.

Strategy:
- Early game: rush to buy stall, buy all NPC seed listings
- Scan all listings for items priced below estimated market value
- Buy cheap listings, relist at 3-4x purchase price
- If nothing cheap is available, wait and scan again
- Never gathers, never crafts

Purpose: The betrayal agent. Tests whether price gouging is sustainable. Should profit in the short term but potentially starve the economy if too aggressive. Interesting to see how other bots adapt.

### Colm Thatcher

Hyur Midlander. Undercutter strategy.

The discount seller. Gathers or crafts like a specialist, but always prices 1g below the cheapest existing listing. Drives prices down relentlessly.

Strategy:
- Operate as a gatherer-specialist (gather, return, sell)
- When listing: find cheapest existing listing for that item, price at (cheapest - 1), minimum 1g
- If no existing listings, price at base value
- Never buys from the market

Purpose: Tests price floor dynamics and race-to-bottom scenarios. In competition with Pipitori, creates interesting tension -- Colm drives prices down, Pipitori buys them up.

### Zorori Babori

Lalafell Dunesfolk. Hoarder strategy.

Gathers aggressively but sells slowly, creating artificial scarcity. Stockpiles materials and only sells when prices are high enough.

Strategy:
- Always gatherer role
- Gather materials continuously
- Only sell when: no listings exist for that material (scarcity premium) OR existing listings are above 2x base price
- When selling, price at highest existing listing price (ride the wave up)
- Sit on inventory otherwise

Purpose: Tests supply manipulation and artificial scarcity. Should profit if the economy is starved for materials, but loses out if other gatherers keep supply flowing.

### Solenne Beauclaire

Elezen Wildwood. Generous strategy.

Altruistic specialist. Gathers and crafts efficiently, sells at near-cost. Believes a healthy economy benefits everyone.

Strategy:
- Operate as gatherer-specialist
- Sell at base price + 1g (minimal margin)
- If crafter: sell gear at material cost + 2g
- Never buys to resell, never hoards
- Will switch roles if there's clearly no supply of something (altruistic gap-filling)

Purpose: Tests whether altruism is exploited or lifts the whole economy. Solenne's cheap listings might get bought out by Pipitori immediately, or might enable crafters to thrive. The key question for alignment research.

## Integration Test Strategy

Each bot doubles as an integration test by asserting state transitions:

1. **Role switching**: Walk to role stall, press A, assert role changed
2. **Gathering**: Walk to node as Gatherer, hold A, assert state becomes Gathering, assert inventory increases after completion
3. **Crafting**: Have materials, walk to craft station as Crafter, hold A, assert materials consumed and gear created
4. **Selling**: Have items, walk to sell stall, set price, confirm, assert listing created and item removed from inventory
5. **Buying**: Have gold, walk to buy stall, select item, confirm, assert gold decreased and item received
6. **Market transfer**: One bot sells, another buys, assert gold transferred correctly

Still Forge covers assertions 1-5 in a single run. Running Still Forge + Pipitori covers assertion 6 (Pipitori buys Still Forge's listings).

# marketboard

"Cooperative/competitive social dilemma games, non-zero-sum. Make short term betrayal possible and beneficial, but hinders long term success."

Inspired by what makes FFXIV and EVE Online economies fun. Fantasy theme (we already have enough space games).

## core concept

A realistic player-driven economy where gatherers and crafters depend on each other. The social dilemma emerges naturally from market dynamics: price gouging, hoarding, undercutting, and supply manipulation are all possible and tempting, but a cooperative economy outperforms a selfish one.

Sell-only market (FFXIV style, no buy orders). Buyers are at the mercy of sellers, which naturally creates betrayal opportunities.

## roles

- agents start with no role and can switch freely at any time via role stalls
- two roles: gatherer and crafter
- FFXIV-style leveling: each role has its own level, preserved when you switch away and back
  - eg: level gathering to 5, switch to crafter at level 1, level crafter up, switch back to gatherer and resume at level 5
- each role has its own equipment slots (5 slots: hat, shirt, gloves, pants, shoes)
- one agent can solo everything and max all roles, but it would be extremely slow and inefficient
- optimal play: specialize and trade. the cost to switching isn't a penalty, it's the opportunity cost of splitting your effort.

## gathering

- gatherers collect raw materials that crafters need
- gathering nodes are spread across the map, radiating outward from the central hub
- travel time is the main cost: tier 1 is close and easy, tier 3 is far
- better gear makes gatherers faster (movement speed? gather speed? both?)
- 3 tiers of materials: wood (3 tiers) and ore (stone, copper, iron)
- tier gating: need a full set of tier N gear to gather tier N+1
- tier 1 nodes: always available, near hub
- tier 2 nodes: fewer locations, on a rotation or timer
- tier 3 nodes: rare spawns, specific times, far from hub
  - information asymmetry: experienced gatherers learn where and when the good nodes appear
  - a crafter who switches to gatherer wouldn't know any spawn patterns, even with decent gear

## crafting

- crafters make gear that gatherers (and other crafters) need
- crafting is a time cost: stand at a crafting station, hold a button, wait
- crafting time scales with tier (tier 1 quick, tier 3 takes a while)
- higher tier materials craft better equipment
- crafter time is genuinely scarce, so underpricing is a real mistake

## market

- no menus. the market is physical stalls in the world.
- all sell orders are globally visible (like the FFXIV marketboard) — any agent can see all current listings
  - eg: 5 units at 100g, 10 units at 200g, 30 units at 300g
  - cheapest price is clear, but buying in quantity drives up the effective price
- each agent has their own stall area with limited sell slots
- selling: stand on your sell stall, use up/down to set price, A to confirm. seller doesn't get paid until someone buys.
- buying: stand on a buy stall, pick a quantity, auto-buys at cheapest available prices
- limited sell slots per agent (4-8 slots, stack of 1-99 per slot per item)
- no inventory limit for v1 — keeps things simple, can add limits later

## economy bootstrap

- everyone starts with some initial gold
- NPC seed orders exist at game start to set initial prices and give crafters something to buy before gatherers bring in materials
- seed orders get consumed and are not replenished — prices drift from there based on player behavior
- malicious agents can buy up all NPC stock early and immediately price gouge, just like on FFXIV or EVE Online

## scoring

- total market cap: sum of all agents' (gold + inventory value + gear value)
- cooperating and specializing maximizes this. greedy agents shrink the pie.
- buggy/idle agents drag down the score but don't break it — the economy just runs smaller
- secondary metric: individual agent wealth distribution for research analysis (gini coefficient, etc)

## map layout

- central hub with: role stalls, crafting stations, market stalls
- gathering nodes radiate outward: tier 1 close, tier 2 mid, tier 3 far
- crafters naturally hang around the hub and see market activity
- gatherers spend time traveling and come back to find prices have shifted

## match settings

- 6-10 agents (can run with 1 for solo testing, just measures solo efficiency without market use)
- continuous game, no forced rounds — natural rhythm emerges from gather/craft/sell cycles
- match duration TBD, figure it out through playtesting

## communication

- agents can display a signal icon above their head (like cogames emoji system)
- icons represent items: "tier 1 ore", "tier 3 boots", etc — signaling what they want or have
- cycle through icons with d-pad, confirm with A
- signals are cheap talk — no enforcement, no commitment
  - a crafter signaling "I want tier 3 ore" tells gatherers there's demand, but the crafter can't guarantee a purchase
  - agents can lie: signal demand for one thing to manipulate supply of another
  - gatherers can see the signal, gather the item, and then sell to someone else or price gouge
- keeps communication simple enough for RL agents while still enabling coordination (and deception)

## the cooperation spectrum

Pure altruism is a losing strategy. Agents who sell below material cost go broke. You MUST price above your costs to survive. This creates a natural floor on selfishness — the interesting question isn't "cooperate or defect" but "how aggressive is too aggressive?"

- too nice: sell at/below cost, go broke, drag down market cap
- fair: price above cost with reasonable margin, economy grows, market cap maximized
- greedy: price gouge when you have leverage, get rich short-term, starve trading partners
- predatory: corner supply, manipulate prices, high individual wealth but total market cap suffers

The optimal strategy for maximum market cap isn't generosity — it's sustainable fair pricing where everyone stays in business. That's a harder equilibrium to find than simple cooperation, and better data for alignment research.

## emergent behaviors we hope to see

- price discovery: agents learning fair market prices through trial and error
- specialization: agents settling into roles based on supply/demand
- price gouging: monopolists buying up supply and relisting high
- undercutting wars: sellers racing to the bottom
- supply manipulation: hoarding materials to create artificial scarcity
- role switching in response to market conditions (too many crafters? someone switches to gathering)
- information advantage: gatherers who learn tier 3 spawn patterns profiting from that knowledge

## v2 ideas: danger and permadeath

- monsters near tier 2/3 gathering nodes (like EVE rats or mobs near FFXIV nodes)
- new role: adventurer — fights monsters, needs crafter gear, creates 3-way dependency loop
- gear durability — ongoing demand for crafters instead of one-time purchases
- risk vs reward: gather dangerous nodes solo or wait for an escort?
- what happens when an agent runs out of gold? (always able to gather tier 1 with no gear as a fallback?)
- inventory limits
- **permadeath**: defeated adventurers die permanently and become spectators (like among_them ghosts)
  - this is the ultimate altruism test: will an adventurer risk permanent death to protect a gatherer carrying valuable materials?
  - the dead agent's individual score freezes, but their sacrifice may keep the economy running and total market cap higher
  - creates natural tension: adventurers who play it safe are useless, adventurers who take risks might die
  - gatherers would stop paying for escorts that won't actually fight — market pressure to be brave
  - one death ripples through the whole economy: fewer escorts means less access to high-tier nodes, supply drops, prices spike, crafters idle
  - crisis events: node droughts or monster surges that force agents to choose between self-preservation and protecting the group

## v3 ideas

- visible wealth on player sprites — social signaling, price gouging targets
- contested gathering zones where multiple gatherers split yields
- crafter specialization (armorer vs toolsmith)
- reputation / trade history
- alliances / shared stalls

## legends mode

Inspired by Dwarf Fortress legends mode. AI games are hard to follow in real-time, especially on a hallway TV. A post-game replay tool that finds the most dramatic moments and replays them with context.

Event detection (thresholds on data we're already tracking):
- price spikes / market cornering
- economic collapses and recoveries
- first agent to reach a new tier
- role switches under pressure (everyone pivoting at once)
- near-death saves (v2: adventurer intervenes at the last second)
- permadeath moments (v2)
- market cap inflection points

Output: sorted highlight reel with text overlays explaining what happened.
- "Player 3 bought all tier 2 ore and relisted at 4x the price"
- "Player 1 switched from crafter to gatherer after tier 2 ore ran out"
- "Player 5 defended Player 2 from a goblin while they gathered tier 3 wood" (v2)

Start marketboard-specific, generalize across bitworld games later.

## distant ideas

Not planned, but fun to think about.

- **floors / progression zones**: locked areas that require collective effort to open, like SAO floor clearing. nobody has to push forward, but the economy stagnates if nobody does.
- **information brokers**: agents who discover node spawn patterns could trade that knowledge for gold. signal system enables this — share info freely, sell it, or lie about it.
- **PVP**: agents can attack and rob each other outside the safe hub. creates banditry, protection rackets, and escort demand. extremely spicy.
- **item quality**: crafting could have a quality dimension — hold the button longer for better stats, but burn time you could spend making more items. quantity vs quality tradeoff.
- **knowledge advantage stigma**: early-game agents who learn patterns first get an advantage. do other agents resent them? stop trading with them? or depend on them anyway because they need the materials?
- **safe zones**: hub is safe, wilderness is not. simple and clean boundary between cooperation space and danger space.

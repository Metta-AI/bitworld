# Bit World

PICO-8 the console with most games
* fun to make
* easy to make
* people love it.

Big:
* Does not have multiplayer.
* Old school retro constraints.

Plan: Make a PICO-8 like console with multiplayer but make it AI first to vibe games on.

Dead simple API, server sends a visual buffer of 16 colors 64x64 pixels, client sends bitmask of actions, dpad, select and a and b. No SDK necessary. No repo necessary, a single .md file that describes the API. It's possible to one shot whole games, client and policies.

You connect over a URL. We are basically an API and tournament host. Easily run your own servers.

Good for both reinforcement learning and coding agents.

Types of games: cooperative/competitive social dilemma games, non-zero-sum. Make short term betrayal possible and beneficial, but hinders long term success.

# Big Adventure
- Zelda/WoW/Diablo style games
- Players team up to kill monsters.
- Players can steal the loot. (betrayal)
- Players can attack each other. (betrayal)
- But if they team up they can take down high reward bosses. (non zero sum)
- Players need to share loot, coins, health and items.

# Infinite Blocks
- Multiple players dropping bricks
- You can coop and clear lines 8 lines at a time. (non zero sum)
- Each player drops a different color, liens with many colors earn more (non zero sum)
- You can grief and put blocks into other people's thing. (betrayal)
- You can steal other peoples nearly complete lines. (betrayal)
- Huge mountain of badly placed bricks grows and grows.

# Fancy Cookout
- Multiple players cooking food
- You can coop and cook food faster.
- You can grief and put food into other people's thing.
- Only person delivering the food gets the reward.
- You can only cook complex recipes with multiple players. (non zero sum)
- People need to take turns selling food, or you can take it all for yourself. (betrayal)

# Mine World
- Multiple players building blocks
- You can coop and build faster.
- At night monsters spawn and attack players.
- Higher tier resources are possible with multiple players. (non zero sum)
- You can grief and steal other people's resources. (betrayal)

# Planet Wars
- Multiple players controlling planets
- Planets produce ships over time
- Planets can send ships to other planets
- Planets can attack other planets
- Reward based on planets controlled over time per time^2 (non zero sum)
- Cold wars and alliances form (betrayal)
* Variant: you only control one planet and can join or betray the collective. (betrayal)

# Boundless Factory
- Factorio/Shapez/Transport Tycoon style game
- Multiple players placing belts and assemblers
- You can coop and build faster and get more resources.
- You can combine special power of other players to gain higher tier things (non zero sum)
- You can steel other people's resources. (betrayal)

# BitWorld

Bitworld is:

* A simple 128x128 protocol spec with two inputs dpad and text.
* A collection of games.
* Philosophy: `Cooperative/competitive social dilemma games, non-zero-sum. Make short term betrayal possible and beneficial, but hinders long term success.`

Bit World is a retro-inspired multiplayer spec, list of games and a philosophy around multi-agent research. It imagines a large shared protocol where many agents interact with each other using simple protocols, many games and a defined type game.

The project is meant to be a playground for studying coordination, competition, trust, and emergent social behavior in game-like environments. It is especially aimed at experiments involving reinforcement learning agents and coding agents operating in the same world.

## Games

The repo currently includes playable multiplayer prototypes for:

- `Among Them`
- `Asteroid Arena`
- `Big Adventure`
- `Brushwalk`
- `Bubble Eats`
- `Fancy Cookout`
- `Free Chat`
- `Ice Brawl`
- `Infinite Blocks`
- `Planet Wars`
- `Stag Hunt`
- `Tag`
- `Warzone`
- `Overworld`

The core idea is not just combat or progression. Bit World is built around multiplayer interaction:

- Players can cooperate to defeat stronger enemies or accomplish some larger task.
- Alliances are not set but can form, collapse, and reform over time.
- Agents can develop reputations, friendships, rivalries, and strategies.

This makes the game world useful as a sandbox for questions like:

- Do fair groups last longer than selfish ones?
- When does cooperation emerge naturally?
- What incentives cause betrayal?
- How do agents adapt to repeated social interaction?

## Visual Style

Bit World is designed around strict retro display constraints:

- screen resolution: `128 x 128` pixels
- sprite palette: `16` colors per sprite
- visible colors per sprite: `15`, because one palette entry is reserved for alpha/transparency

These limits are part of the design, not just an implementation detail. They help keep the game visually simple, readable, and consistent with its console-inspired direction.

## Controls

The current control concept is intentionally simple:

- `Up`, `Down`, `Left`, `Right`: movement
- `A`: primary action, such as attack
- `B`: secondary action, such as defend
- `Select`: open context-specific menus

`Select` is meant to be flexible. Depending on context, it could be used to:

- manage inventory
- interact with vendors
- trade with another player
- trigger local interaction menus

## Research Focus

Bit World is intended as a shared environment for studying:

- multi-agent cooperation
- resource allocation and fairness
- betrayal and adversarial behavior
- emergent group dynamics
- long-term social strategy

Because players can both help and harm each other, the world can support experiments that are harder to observe in purely cooperative or purely competitive environments.

## Technical Direction

The game is planned as a fast multiplayer system written in Nim, with separate client and server components.

At a high level:

- the client handles player interaction and world presentation
- the server manages the shared multiplayer world
- the game world is large and designed to support many simultaneous players or agents

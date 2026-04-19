# Bit World

Bit World is a retro-inspired multiplayer RPG concept designed for multi-agent research. It imagines a large shared world where many players explore, fight monsters, gather loot, form alliances, and sometimes betray each other.

The project is meant to be a playground for studying coordination, competition, trust, and emergent social behavior in game-like environments. It is especially aimed at experiments involving reinforcement learning agents and coding agents operating in the same world.

## Overview

In Bit World, players begin with very little and gradually build strength by exploring the world, collecting items, and surviving combat. The world starts gently, with beginner-friendly areas and weaker monsters, then expands into more difficult regions that reward stronger coordination and create more opportunities for conflict.

The repo currently includes playable multiplayer prototypes for:

- `Big Adventure`
- `Free Chat`
- `Infinite Blocks`
- `Planet Wars`
- `Fancy Cookout`

The core idea is not just combat or progression. Bit World is built around multiplayer interaction:

- Players can cooperate to defeat stronger enemies.
- Groups can share resources fairly or compete over loot.
- Alliances can form, collapse, and reform over time.
- Agents can develop reputations, friendships, rivalries, and strategies.

This makes the game world useful as a sandbox for questions like:

- Do fair groups last longer than selfish ones?
- When does cooperation emerge naturally?
- What incentives cause betrayal?
- How do agents adapt to repeated social interaction?

## Core Gameplay

Bit World plays like a simplified console-era RPG with a small, readable control set and a large persistent world.

Players can:

- Move through the world and explore new areas
- Fight monsters
- Collect and manage items
- Trade, share, or steal resources
- Interact with vendors and other players
- Form temporary or lasting groups

## Visual Style

Bit World is designed around strict retro display constraints:

- screen resolution: `64 x 64` pixels
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

## Project Status

Bit World is currently at the concept stage. This repository is the starting point for documenting the idea and shaping the project into a more concrete game and research platform.

`Fancy Cookout` now has a first playable kitchen slice focused on dishes: players can pick up dirty plates with `A`, place or drop them with `B`, wash them cooperatively at a sink by holding `B`, and return clean plates to the rack for personal score.

`Free Chat` is a lightweight social demo slice: players wander a shared plaza, press `Select` to open a retro letter grid, use the d-pad to choose characters, press `A` to add, `B` to erase, and press `Select` again to publish the message above their head.

## Tools

Use `tools/quick_run fancy_cookout` to let it pick a random port between `5000` and `10000`, or pass an explicit port like `tools/quick_run fancy_cookout 8080`. You can also launch multiple screen-only clients with `tools/quick_run free_chat --players:4`. `quick_run` compiles the selected Bit World server and the client, waits for the server to come up, and then launches both together on the requested port. It always sets a client title from the game name, and multiplayer runs center the first four clients on screen, bind joysticks `1` through `N`, and suffix titles with `Player 1`, `Player 2`, and so on. It also cleans up all child processes on exit and Ctrl+C.

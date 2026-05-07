# Mortal Coil

A multiplayer social negotiation game of magic and betrayal. Players are sorcerers in a shared world, each driven by hidden passions. They cooperate to define the rules of magic itself, but compete to bend those rules in their favor. Short-term betrayal pays off — but burns the trust you need to survive.

Inspired by Brennan Taylor's tabletop RPG of the same name, adapted into a BitWorld-compatible multiplayer protocol game. See DESIGN.md for the full game design document.

## Run The Server

From the game folder:

```sh
cd /Users/me/p/bitworld/mortal_coil
nim r mortal_coil.nim --address:0.0.0.0 --port:2000
```

Options:

- `--address`: Bind address (default `localhost`).
- `--port`: Server port (default `8080`).
- `--seed`: RNG seed for world generation.

## Browser Clients

The server serves the standard BitWorld clients:

- Player: `http://localhost:2000/player`
- Global viewer (spectate): `http://localhost:2000/global`

Open `/player` in multiple tabs or devices to join as separate players. Open `/global` to watch the game without participating.

## Run AI Players

From the repo root:

```sh
cd /Users/me/p/bitworld
nim r tools/quick_player mortal_coil --players:4 --address:localhost --port:2000
```

## Lobby

The server accepts 4-8 players. The lobby screen shows all connected players and their colors. Once the minimum of 4 players connect, a 10-second countdown begins. When the countdown finishes, the game transitions to the setup phase.

If a player disconnects during the lobby and the count drops below 4, the countdown resets.

## Controls

- D-pad: navigate menus, select targets
- A: confirm action, commit tokens, propose facts
- B: cancel, defend, veto
- Select: open passion menu, view theme document, check token pools
- Enter: open text input (for naming facts, writing prices, declaring goals)
- Escape: close text input

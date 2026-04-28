# Quick Run

`quick_run` is a small developer tool that helps AI and humans iterate on Bit World client-server games quickly.

## What It Does

`quick_run` launches a selected game server and the Bit World client together.

It is designed for development:

- It compiles the server first.
- It waits for the server compile to finish.
- If the server has compile errors, it does not start the client.
- Only after the server compiles successfully does it compile and start the client.

This makes it useful for checking your work because a broken server build stops the whole run immediately instead of opening a client against an invalid or stale server.

It also standardizes the client launch parameters so each run starts with a readable title, and multiplayer runs can open several screen-only clients in a predictable layout.

## Why It Helps

For AI-driven development, `quick_run` keeps the basic test loop simple:

1. Make a change.
2. Run `quick_run`.
3. Let it rebuild the server and client.
4. Watch both programs together.

That means less manual setup and fewer mistakes while iterating on gameplay, networking, rendering, and debugging.

## Failure Behavior

If either side fails, `quick_run` exits cleanly:

- If the server compile fails, the client never starts.
- If the client compile fails, the run stops before launch.
- If the server exits while running, the client is shut down too.
- If the client exits while running, the server is shut down too.
- If there is an error in either the server or the client, logs are printed and the whole run exits.

## Multiplayer Layout

`quick_run` supports `--players:N` for `1` to `4` players.

- With one player, it launches the normal full client chrome and sets the client title to the game name, such as `Fancy Cookout`.
- With multiple players, it launches screen-only clients, centered on the primary monitor with a `50px` gap between windows.
- Two players are arranged side by side.
- Three players are arranged side by side.
- Four players are arranged as a centered `2 x 2` grid.
- Each client is assigned the matching joystick number, so player 1 gets joystick 1, player 2 gets joystick 2, and so on.
- Multiplayer window titles are suffixed per client, such as `Fancy Cookout Player 1` and `Fancy Cookout Player 2`.

## Usage

Run it from the Bit World repo root:

```powershell
.\tools\quick_run.exe fancy_cookout
```

You can also provide an explicit port:

```powershell
.\tools\quick_run.exe fancy_cookout 8080
```

If no port is provided, `quick_run` chooses a random port between `5000` and `10000`.

You can also launch multiple players:

```powershell
.\tools\quick_run.exe free_chat --players:2
.\tools\quick_run.exe fancy_cookout 8080 --players:4
```

Add `--reconnect:5` to pass five-second client reconnects through to every
launched client. Reconnect is off by default.

When `--players:N` is greater than `1`, `quick_run` automatically passes `--screen-only`, `--title:...`, `--joystick:N`, `--x:N`, and `--y:N` to each client.

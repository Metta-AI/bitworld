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

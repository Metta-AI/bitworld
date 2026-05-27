# Among Them Coworld Smart Bot Guide

The maintained optimizer guide is:

```text
../players/SMART_BOT_GUIDE.md
```

Use that guide for the current Coworld policy contract, LLM/optimizer loop,
submission flow, and replay/log inspection commands.

This `bot-policies/` directory is source reference material for a Python
sidecar-style policy. It is useful when studying or porting perception, memory,
and LLM decision code, but it is not the hosted tournament interface.

The public Coworld contract is:

1. build a player process that reads `COGAMES_ENGINE_WS_URL`;
2. connect to the supplied Bitscreen v1 websocket exactly as provided;
3. package the player in a `linux/amd64` Docker image;
4. upload it with `coworld upload-policy`;
5. submit the uploaded policy version with `coworld submit`.

```sh
softmax login
coworld leagues
docker buildx build --platform linux/amd64 -t my-among-them-policy:latest --load .
coworld upload-policy my-among-them-policy:latest --name my-policy
coworld submit my-policy:v1 --league <among-them-league-id>
```

Source bots such as `nottoodumb.nim` and this Python sidecar remain useful
implementation references. Treat them as code you may port or vendor into a
policy image deliberately, not as files the Coworld runner automatically makes
available to hosted policies.

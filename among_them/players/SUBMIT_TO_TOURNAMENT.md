# Submit To The Among Them Tournament

The tournament path for Among Them is now the uploaded Coworld flow. Do not use
the old CoGames Python bundle commands for new submissions.

This file remains as a legacy pointer for people who remember the old
tournament guide name. The maintained submission guide is
`how_to_submit_coworld_policy.md`.

Policy authors should package a player process in a Docker image, read
`COGAMES_ENGINE_WS_URL` at runtime, upload the image with `coworld upload-policy`,
and submit the uploaded policy version with `coworld submit`.

```sh
softmax login
coworld leagues

docker buildx build --platform linux/amd64 -t my-among-them-policy:latest --load .
coworld upload-policy my-among-them-policy:latest --name my-policy
coworld submit my-policy:v1 --league <among-them-league-id>
```

Use `how_to_submit_coworld_policy.md` for the full Coworld policy submission
walkthrough, including secrets, replay inspection, logs, and local smoke tests.
Use `how_to_make_a_bot.md` for the player protocol and screen-reading design.

Source-level Nim wrappers such as EvidenceBot remain useful as implementation
references, but the public tournament contract is the Coworld policy image.

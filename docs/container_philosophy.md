
# Andre's Coworld Docker Proposal

Somehow the world has standardized on Docker. Currently, the AIs can make any Docker container for any language, from Python to JavaScript to niche languages like Nim or Zig. It is the ultimate unit to move processing executables around, because anywhere can run a Docker container. Anyone can consume a Docker container. Docker containers have other niceties as well, like the fact that it can be very small if you transfer only the different layers. It is much better than uploading some sort of executable or some sort of zip file with an executable. This is why we are standardizing on the Docker container to be able to support anything and everything.

Dockers usually live in a container registry. For users they can use any container registry they like to, and so they can upload their Docker to that container registry. When they submit the Docker container to us, we just slurp it from there. We need to mirror their Docker container in case they delete it later, as we want to keep whatever they submitted around forever. This does not work for private Docker containers, so in case they want to submit a private Docker container, they would need to export and upload a zip file of the Docker container and all its layers. That's very similar to slurping from a URL, so not a huge difference, but there is a distinction here.

There is no need to clone a repo or download custom metta tools. In theory, an AI can just read our markdown file that's hosted on our site, and that's all it needs to move forward, because all the tools that we use are pretty normal tools, such as:

* Creating Docker containers
* Embedding a manifest file in the Docker container
* Using HTTP or webSockets
* Submitting as Docker registry container URLs
* Uploading zipped Docker container layers in case it's private

This is everything that AI can trivially understand and do. It does not require downloading something, installing custom tools, authenticating. All that can be done with just with just reading a markdown off our site.

In order to certify what a coworld is, we run an integration test on the Docker container.
Track the manifest file from the Docker container to see what it is: is it a game or a player? What parameters does it take to start, and version information. Then we start the Docker container, and it's a web server. Parameters are passed to the Docker container as environmental variables because that's the process that Docker likes. Everything is done through a web service because it allows us to have multiple endpoints, and almost everything done through web sockets and http requests. Websockets allow us to have bi-directional channels between the running Docker containers.

For instance, we want to certify a Game Docker container. We need to make sure we can run the Docker container, that it starts up, that it has the proper config parameters, which are defined in the game manifest and at startup. We need to make sure that it has the proper endpoints, which we check. We also need to make sure that it writes out the correct files, namely the replay file and the score file that can then later be used to rate the games.

Here is an example of what a Game Certifier will check:
* Read the `coworld_manifest.json` file from the Docker container
* Read the config from `COGAME_CONFIG_URI`
  (may be `file://...` for local Docker dev with bind mounts, an https URL to the orchestrator's `/api/replay/download` handler when the launcher runs on the dashboard EC2, or a short-lived presigned `https://...s3...` URL (the S3 path is the default for `--ecs` using the standard "bitworld-game-configs" bucket name — this enables `--ecs` launches from a developer laptop without extra env vars)
* Serve `GET /healthz`
* Serve player clients at `GET /client/player?...` and player websockets at `WEBSOCKET /player?...`
* Serve a live viewer at `GET /client/global` and `WEBSOCKET /global`
* Write final results to `COGAME_RESULTS_URI` (orchestrator upload proxy with token, file://, or presigned S3 PUT https when --ecs + BITWORLD_REPLAY_S3_BUCKET)
* Write a replay artifact to `COGAME_SAVE_REPLAY_URI` (same options as results)
* Serve replay viewers when started with `COGAME_REPLAY_SERVER=1`

We need similar certification for all the other types of containers as well. A player container should be able to connect to the games that it says that it supports, etc. Reporter containers and various debugging containers and various commissioner containers all have certification checks as well. Any program a user can submit that is runnable needs to be certified and have a valid manifest file.

To test games and players locally. It's the exact same thing. A user just downloads the Docker containers from us. There's no custom tools that they need to install first. Any AI can do it. They can just go read the docs, look at the leaderboard. They can get the Docker URLs there for the game server, for the different players (if they're public), and then can just download and start them all as needed locally.

# Private decision trajectories

`bitworld/decision_trajectory` records training evidence supplied by the game
engine. It is independent of spectator replay and does not infer accepted
moves from model responses or timestamps.

Create one `DecisionTrajectory` with episode, seed-family, game, exact game
version, and source revision. Record each decision **after** applying the
accepted action. Supply the acting seat's private observation, every attempt,
the selected attempt, and the actual executed action. Each model attempt keeps
its exact prompt, native request/response, actual response call ID, model,
decoder settings, and optional learner token/log-probability evidence. A local
scripted teacher uses `aoTeacher` and no platform call ID. Fallbacks use
`asFallback` and an explicit baseline origin; they are never teacher labels.

Finish exactly once with the engine's completed, truncated, or failed status,
outcome, and participant scores. `writeEvents` and `writeCompleteEpisode` create
owner-only POSIX files with exclusive creation and refuse existing destinations. `writeEventsToUri` accepts a
private file URI or a platform-provided signed upload URI. The dedicated runtime
environment name is `COGAME_SAVE_TRAJECTORY_URI`; never reuse the replay URI.
Only `esCompleted` episodes can use `writeCompleteEpisode`.

The output follows the Coworld Python `decision_trajectory` schema. Its
qualification gate still checks completeness, private observations, source
pins, exact inputs, selected/applied actions, and the evidence required for
supervised fine-tuning or reinforcement learning. Using the recorder alone does
not certify a game, a published image, runtime parity, or a stronger learner.

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

## Authenticated player evidence

Construct attempts with `newDecisionAttempt(id, policy, origin)` before assigning
evidence fields. Every absent JSON value starts as JSON null.

Players serialize `DecisionAttempt.attemptEvidenceJson()` on a private,
authenticated channel. Games read it with `readAttemptEvidence()`, then supply
`accepted` and `parsedAction` after their production parser applies the action.
The wire reader rejects missing, extra, incorrectly typed fields and invalid
platform UUIDs. It retains actual prompt/sample token IDs and draw-time behavior
log probabilities; paired sampling arrays must have equal lengths. No reader can
verify a client assertion: platform attribution and checkpoint identity still
require the trusted sidecar/archive join. Never place this envelope in public
replays or spectator frames.

For macro orders, supply `execution = some(ExecutionEvidence(...))` only after
the physical ticks finish. `startTick` is inclusive and `endTick` exclusive;
`tickHz` is positive. `seatControlsBase64` stores exactly four bytes per tick:
signed move x, signed move y, signed aim turn, and unsigned action. The recorder
checks the decoded length. This evidence stays separate from `executed_action`,
which must still equal the engine-normalized selected proposal.

### Native HTTP capture

Call `captureInferenceRequest` before sending a model request, then
`captureInferenceResponse` with the actual response body and identity headers.
The latter preserves failed HTTP bodies and checks served decoding against the
request. The game supplies its retry limit and effective deadline.

After validating and applying an action, `recordExecutedDecision` binds captured
attempts to the engine's policy seat. Engine fallbacks retain rejected attempts
and never select them. Uncaptured external actions retain unknown origin.

`tools/native_fixture.py` provides a bounded HTTP/WebSocket infrastructure
fixture for game-owned `tools/test_native_trajectory.py` scripts. Install Python
`websockets` to run it. It checks accepted replies, retries, fallbacks, private
file permissions, and game-owned replay verification. Its separate provider
archive records actual fixture HTTP calls; synthetic replies are not teacher
data or model-performance evidence.

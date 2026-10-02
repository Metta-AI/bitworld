## Private decision evidence supplied by the authoritative game engine.
## These records are training artifacts, never spectator replay frames.

import std/[json, options, os, strutils]
import runtime
when defined(posix):
  import std/posix

const CogameSaveTrajectoryUriEnv* = "COGAME_SAVE_TRAJECTORY_URI"

type
  AttemptOrigin* = enum
    aoModel, aoTeacher, aoFallback, aoHuman, aoUnknown
  ActionStatus* = enum
    asAccepted, asRejected, asFallback, asMissing
  EpisodeStatus* = enum
    esCompleted, esTruncated, esFailed
  DecisionAttempt* = object
    attemptId*, policy*: string
    model*: Option[string]
    origin*: AttemptOrigin
    prompt*, request*, response*, rawResponse*, parsedAction*, decoder*: JsonNode
    accepted*: bool
    platformCallId*, rejectionReason*, modelIdentity*, tokenizerIdentity*: Option[string]
    chatTemplateSha256*, stopReason*: Option[string]
    latencyMs*: Option[float]
    inputTokens*, outputTokens*: Option[int]
    promptTokenIds*, sampledTokenIds*: Option[seq[int]]
    behaviorLogprobs*: Option[seq[float]]
  DecisionTrajectory* = ref object
    episodeId, seedFamily, game, gameVersion, sourceRevision: string
    decisions: seq[JsonNode]
    summary: JsonNode
    finished: bool

proc originName(origin: AttemptOrigin): string =
  ["model", "teacher", "fallback", "human", "unknown"][ord(origin)]

proc statusName(status: ActionStatus): string =
  ["accepted", "rejected", "fallback", "missing"][ord(status)]

proc jsonOption[T](value: Option[T]): JsonNode =
  if value.isSome: %value.get() else: newJNull()

proc newDecisionTrajectory*(episodeId, seedFamily, game, gameVersion,
    sourceRevision: string): DecisionTrajectory =
  for value in [episodeId, seedFamily, game, gameVersion, sourceRevision]:
    if value.len == 0:
      raise newException(ValueError, "trajectory identity and source/version pins are required")
  DecisionTrajectory(episodeId: episodeId, seedFamily: seedFamily, game: game,
    gameVersion: gameVersion, sourceRevision: sourceRevision)

proc recordDecision*(trajectory: DecisionTrajectory, decisionId, seat: string,
    observation: JsonNode, attempts: seq[DecisionAttempt],
    selectedAttemptId: Option[string], executedAction: JsonNode,
    status: ActionStatus, terminal = false,
    fallbackOrigin = none(string)) =
  ## Call AFTER the engine has validated and applied the selected proposal.
  if trajectory.finished:
    raise newException(ValueError, "cannot record after episode completion")
  if decisionId.len == 0 or seat.len == 0:
    raise newException(ValueError, "decision identity and seat are required")
  for decision in trajectory.decisions:
    if decision["decision_id"].getStr() == decisionId:
      raise newException(ValueError, "duplicate decision identity")
  var encoded = newJArray()
  var selected = 0
  var selectedPrompt = newJNull()
  for index, attempt in attempts:
    if attempt.attemptId.len == 0 or attempt.policy.len == 0:
      raise newException(ValueError, "attempt identity and policy are required")
    for previous in 0 ..< index:
      if attempts[previous].attemptId == attempt.attemptId:
        raise newException(ValueError, "duplicate attempt identity")
    if selectedAttemptId.isSome and attempt.attemptId == selectedAttemptId.get():
      inc selected
      selectedPrompt = attempt.prompt
      if not attempt.accepted or attempt.parsedAction != executedAction:
        raise newException(ValueError, "selected proposal differs from executed action")
    encoded.add(%*{
      "attempt_id": attempt.attemptId, "policy": attempt.policy,
      "origin": originName(attempt.origin), "model": jsonOption(attempt.model),
      "prompt": attempt.prompt, "request": attempt.request,
      "response": attempt.response, "raw_response": attempt.rawResponse,
      "parsed_action": attempt.parsedAction, "accepted": attempt.accepted,
      "decoder": attempt.decoder, "platform_call_id": jsonOption(attempt.platformCallId),
      "rejection_reason": jsonOption(attempt.rejectionReason),
      "model_identity": jsonOption(attempt.modelIdentity),
      "tokenizer_identity": jsonOption(attempt.tokenizerIdentity),
      "chat_template_sha256": jsonOption(attempt.chatTemplateSha256),
      "stop_reason": jsonOption(attempt.stopReason),
      "latency_ms": jsonOption(attempt.latencyMs),
      "input_tokens": jsonOption(attempt.inputTokens),
      "output_tokens": jsonOption(attempt.outputTokens),
      "prompt_token_ids": jsonOption(attempt.promptTokenIds),
      "sampled_token_ids": jsonOption(attempt.sampledTokenIds),
      "behavior_logprobs": jsonOption(attempt.behaviorLogprobs)
    })
  if status == asAccepted and selected != 1:
    raise newException(ValueError, "accepted action needs one selected accepted attempt")
  if status == asFallback and fallbackOrigin.isNone:
    raise newException(ValueError, "fallback action needs its actual origin")
  trajectory.decisions.add(copy(%*{
    "schema_version": "1", "event_type": "decision",
    "episode_id": trajectory.episodeId, "decision_id": decisionId,
    "decision_index": trajectory.decisions.len, "game": trajectory.game,
    "game_version": trajectory.gameVersion, "source_revision": trajectory.sourceRevision,
    "seat": seat, "visibility": "private", "observation": observation,
    "prompt": selectedPrompt,
    "attempts": encoded, "selected_attempt_id": jsonOption(selectedAttemptId),
    "executed_action": executedAction, "action_status": statusName(status),
    "fallback_origin": jsonOption(fallbackOrigin), "terminal": terminal
  }))

proc finish*(trajectory: DecisionTrajectory, status: EpisodeStatus,
    outcome, participantOutcomes: JsonNode) =
  if trajectory.finished:
    raise newException(ValueError, "episode already finished")
  trajectory.summary = copy(%*{
    "schema_version": "1", "event_type": "episode",
    "episode_id": trajectory.episodeId, "seed_family": trajectory.seedFamily,
    "game": trajectory.game, "game_version": trajectory.gameVersion,
    "source_revision": trajectory.sourceRevision,
    "status": ["completed", "truncated", "failed"][ord(status)],
    "outcome": outcome, "participant_outcomes": participantOutcomes
  })
  trajectory.finished = true

proc writePrivate(destination, content: string) =
  let parent = destination.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
    setFilePermissions(parent, {fpUserRead, fpUserWrite, fpUserExec})
  when defined(posix):
    # Creation, overwrite refusal, and privacy are one operation.
    let descriptor = posix.open(destination.cstring,
      O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
    if descriptor < 0:
      let code = osLastError()
      if code == OSErrorCode(EEXIST):
        raise newException(ValueError, "trajectory destination already exists: " & destination)
      raiseOSError(code)
    var output: File
    if not open(output, FileHandle(descriptor), fmWrite):
      let code = osLastError()
      discard posix.close(descriptor)
      raiseOSError(code)
    defer: output.close()
    output.write(content)
  else:
    raise newException(ValueError, "private file trajectories require POSIX exclusive creation")

proc eventsJsonl*(trajectory: DecisionTrajectory): string =
  ## A terminal/truncated/failed summary is retained; the SDK chooses eligibility.
  if not trajectory.finished:
    raise newException(ValueError, "unfinished episode has no terminal evidence")
  var lines: seq[string]
  for decision in trajectory.decisions:
    lines.add($decision)
  lines.add($trajectory.summary)
  lines.join("\n") & "\n"

proc writeEvents*(trajectory: DecisionTrajectory, destination: string) =
  writePrivate(destination, trajectory.eventsJsonl())

proc writeEventsToUri*(trajectory: DecisionTrajectory, destinationUri: string) =
  ## Caller supplies a private, scoped file or signed upload URI, never replay URI.
  if destinationUri.isHttpCogameUri():
    writeCogameUri(destinationUri, trajectory.eventsJsonl(),
      "application/x-ndjson", CogameSaveTrajectoryUriEnv)
  else:
    trajectory.writeEvents(pathFromCogameUri(destinationUri, CogameSaveTrajectoryUriEnv))

proc writeCompleteEpisode*(trajectory: DecisionTrajectory, destination: string) =
  ## Refuse to turn a cutoff into a completed training episode.
  if not trajectory.finished or trajectory.summary["status"].getStr() != "completed":
    raise newException(ValueError, "only completed episodes can be exported")
  if trajectory.decisions.len == 0:
    raise newException(ValueError, "completed episode has no decisions")
  writePrivate(destination, $(%*{"schema_version": "1", "episode": trajectory.summary,
    "decisions": trajectory.decisions}) & "\n")

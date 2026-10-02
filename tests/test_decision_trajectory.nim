import std/[json, options, os, strutils, unittest]
import bitworld/decision_trajectory

proc teacher(): DecisionAttempt =
  DecisionAttempt(attemptId: "d0-a0", policy: "scripted", model: some("scripted"),
    origin: aoTeacher, prompt: %*[{"role": "user", "content": "private"}],
    request: %*{"teacher": "scripted"}, response: %"{\"move\":1}",
    rawResponse: %"{\"move\":1}", parsedAction: %*{"move": 1},
    decoder: %*{"method": "deterministic"}, accepted: true)

proc episode(): DecisionTrajectory =
  newDecisionTrajectory("episode", "seed-family", "fixture", "v1", "source-sha")

suite "private authoritative decision trajectories":
  test "complete engine action and teacher evidence round-trip privately":
    let record = episode()
    let observation = %*{"private_card": "secret"}
    record.recordDecision("d0", "0", observation, @[teacher()], some("d0-a0"),
      %*{"move": 1}, asAccepted, terminal = true)
    observation["private_card"] = %"mutated after recording"
    record.finish(esCompleted, %*{"winner": 0}, %*{"0": 1})
    let destination = getTempDir() / ("bitworld-trajectory-test-" & $getCurrentProcessId()) / "complete.jsonl"
    if fileExists(destination): removeFile(destination)
    record.writeCompleteEpisode(destination)
    let payload = parseFile(destination)
    let decision = payload["decisions"][0]
    check decision["observation"]["private_card"].getStr() == "secret"
    check decision["executed_action"] == decision["attempts"][0]["parsed_action"]
    check decision["attempts"][0]["platform_call_id"].kind == JNull
    check decision["attempts"][0]["origin"].getStr() == "teacher"
    check payload["episode"]["status"].getStr() == "completed"
    check getFilePermissions(destination) == {fpUserRead, fpUserWrite}
    expect ValueError: record.writeCompleteEpisode(destination)
    expect ValueError: record.finish(esCompleted, %*{}, %*{})
    expect ValueError:
      record.recordDecision("d1", "0", %*{}, @[teacher()], some("d0-a0"),
        %*{"move": 1}, asAccepted)
    removeFile(destination)

  test "cutoff remains truncated and cannot become a complete export":
    let record = episode()
    record.finish(esTruncated, %*{"reason": "deadline"}, newJNull())
    expect ValueError:
      record.writeCompleteEpisode(getTempDir() / "must-not-write-truncated.jsonl")

  test "accepted action must be selected and identical to the engine action":
    let record = episode()
    expect ValueError:
      record.recordDecision("d0", "0", %*{}, @[teacher()], none(string),
        %*{"move": 1}, asAccepted)
    expect ValueError:
      record.recordDecision("d0", "0", %*{}, @[teacher()], some("d0-a0"),
        %*{"move": 2}, asAccepted)
    expect ValueError:
      record.recordDecision("d0", "0", %*{}, @[teacher(), teacher()], some("d0-a0"),
        %*{"move": 1}, asAccepted)

  test "fallback and duplicate decisions stay explicit":
    let record = episode()
    expect ValueError:
      record.recordDecision("d0", "0", %*{}, @[], none(string),
        %*{"move": 1}, asFallback)
    record.recordDecision("d0", "0", %*{}, @[], none(string),
      %*{"move": 1}, asFallback, fallbackOrigin = some("scripted-baseline"))
    expect ValueError:
      record.recordDecision("d0", "0", %*{}, @[], none(string),
        %*{"move": 1}, asFallback, fallbackOrigin = some("scripted-baseline"))

  test "private player wire round-trips native sampling without engine claims":
    var attempt = teacher()
    attempt.origin = aoModel
    attempt.platformCallId = some("00000000-0000-4000-8000-000000000001")
    attempt.modelIdentity = some("checkpoint-sha")
    attempt.tokenizerIdentity = some("tokenizer-sha")
    attempt.chatTemplateSha256 = some("template-sha")
    attempt.promptTokenIds = some(@[1, 2])
    attempt.sampledTokenIds = some(@[3, 4])
    attempt.behaviorLogprobs = some(@[-0.5, -0.3])
    attempt.stopReason = some("eos")
    let wire = attempt.attemptEvidenceJson()
    let decoded = readAttemptEvidence(wire)
    check decoded.attemptEvidenceJson() == wire
    check not decoded.accepted
    check decoded.parsedAction.kind == JNull
    wire["accepted"] = %true
    expect ValueError: discard readAttemptEvidence(wire)
    wire.delete("accepted")
    wire["behavior_logprobs"] = %*[-0.5]
    expect ValueError: discard readAttemptEvidence(wire)
    wire["behavior_logprobs"] = %*[-0.5, -0.3]
    wire["platform_call_id"] = %"fabricated"
    expect ValueError: discard readAttemptEvidence(wire)
    wire["platform_call_id"] = newJNull()
    wire["model"] = %42
    expect ValueError: discard readAttemptEvidence(wire)

  test "unanswered model and unknown external attempts have explicit JSON nulls":
    let record = episode()
    var unanswered = newDecisionAttempt("d0-model", "model", aoModel)
    unanswered.prompt = %*[{"role": "user", "content": "private"}]
    unanswered.request = %*{"model": "fixture"}
    unanswered.rejectionReason = some("engine deadline")
    record.recordDecision("d0", "0", %*{}, @[unanswered], none(string),
      %*{"move": 1}, asFallback, fallbackOrigin = some("engine-scripted"))
    var unknown = newDecisionAttempt("d1-human", "external", aoUnknown)
    unknown.accepted = true
    unknown.parsedAction = %*{"move": 2}
    record.recordDecision("d1", "0", %*{}, @[unknown], some("d1-human"),
      unknown.parsedAction, asAccepted, terminal = true)
    record.finish(esCompleted, %*{"winner": 0}, %*{"0": 1})
    let events = record.eventsJsonl().splitLines()
    check parseJson(events[0])["attempts"][0]["raw_response"].kind == JNull
    check parseJson(events[1])["attempts"][0]["decoder"].kind == JNull

suite "served inference and engine binding":
  test "request decoder agrees with served limits and preserves private response":
    var attempt = newDecisionAttempt("a0", "requested-model", aoModel)
    attempt.captureInferenceRequest(%*{"max_tokens": 32, "temperature": 0}, "system", "private-user")
    let response = %*{"model": "actual-checkpoint", "stop_reason": "end_turn",
      "usage": {"input_tokens": 12, "output_tokens": 4},
      "inference_settings": {"max_output_tokens": 32, "temperature": 0,
        "timeout_seconds": 45.0, "max_attempts": 9}}
    attempt.captureInferenceResponse($response, 200, "call", "weights", "tokenizer", "template", 30, 2)
    check attempt.decoder["timeout_seconds"].getFloat() == 30.0
    check attempt.decoder["max_attempts"].getInt() == 2
    check attempt.model.get() == "actual-checkpoint"
    check attempt.rawResponse == response
    check attempt.modelIdentity.get() == "weights"
    let record = episode()
    record.recordExecutedDecision("d0", "0", "engine-bound-policy", %*{"private": 1},
      %*{"move": 2}, @[attempt], aoModel)
    record.finish(esCompleted, %*{}, %*{})
    let decision = parseJson(record.eventsJsonl().splitLines()[0])
    check decision["attempts"][0]["policy"].getStr() == "engine-bound-policy"
    check decision["attempts"][0]["parsed_action"] == decision["executed_action"]
    var bad = response
    bad["inference_settings"]["temperature"] = %1
    expect ValueError:
      attempt.captureInferenceResponse($bad, 200, "", "", "", "", 30, 2)

  test "an engine fallback cannot select an accepted proposal":
    var attempt = teacher()
    attempt.accepted = true
    let record = episode()
    record.recordExecutedDecision("d0", "0", "actual-policy", %*{}, %*{"move": 9}, @[attempt], aoFallback)
    record.finish(esCompleted, %*{}, %*{})
    let decision = parseJson(record.eventsJsonl().splitLines()[0])
    check decision["selected_attempt_id"].kind == JNull
    check not decision["attempts"][0]["accepted"].getBool()
    check decision["action_status"].getStr() == "fallback"

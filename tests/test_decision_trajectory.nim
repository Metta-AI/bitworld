import std/[base64, json, options, os, strutils, tables, unittest]
import bitworld/decision_trajectory

proc teacher(): DecisionAttempt =
  result = newDecisionAttempt("d0-a0", "scripted", aoTeacher)
  result.prompt = %*[{"role": "user", "content": "private"}]
  result.response = %"{\"move\":1}"
  result.parsedAction = %*{"move": 1}
  result.accepted = true

proc episode(): DecisionTrajectory =
  newDecisionTrajectory("episode", "seed-family", "fixture", "v1", "source-sha")

suite "private authoritative decision trajectories":
  test "registered game identity is frozen before the first action":
    putEnv("COWORLD_GAME_NAME", "registered-alias")
    defer: delEnv("COWORLD_GAME_NAME")
    let record = episode()
    putEnv("COWORLD_GAME_NAME", "")
    expect ValueError: discard episode()
    record.recordDecision("d0", "0", %*{}, @[teacher()], some("d0-a0"),
      %*{"move": 1}, asAccepted, terminal = true)
    record.finish(esCompleted, %*{}, %*{})
    let lines = record.eventsJsonl().splitLines()
    check parseJson(lines[0])["game"].getStr() == "registered-alias"
    check parseJson(lines[1])["game"].getStr() == "registered-alias"

  test "runtime engine image is validated and frozen before the first action":
    let digest = "sha256:" & repeat('a', 64)
    putEnv("COWORLD_GAME_IMAGE_DIGEST", digest)
    defer: delEnv("COWORLD_GAME_IMAGE_DIGEST")
    let record = episode()
    putEnv("COWORLD_GAME_IMAGE_DIGEST", "mutable-image:latest")
    expect ValueError: discard episode()
    record.recordDecision("d0", "0", %*{}, @[teacher()], some("d0-a0"),
      %*{"move": 1}, asAccepted, terminal = true)
    record.finish(esCompleted, %*{}, %*{})
    let lines = record.eventsJsonl().splitLines()
    check parseJson(lines[0])["image_digest"].getStr() == digest
    check parseJson(lines[1])["image_digest"].getStr() == digest

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
    attempt.responseHeaders = some({"request-id": "actual-provider-id",
      "X-Softmax-Llm-Call-Id": attempt.platformCallId.get()}.toTable())
    attempt.providerRequestId = some("actual-provider-id")
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
    check decoded.providerRequestId.get() == "actual-provider-id"
    check decoded.responseHeaders.get()["request-id"] == "actual-provider-id"
    attempt.responseHeaders.get()["request-id"] = "later mutation"
    check decoded.responseHeaders.get()["request-id"] == "actual-provider-id"
    wire["behavior_logprobs"] = newJNull()
    let greedy = readAttemptEvidence(wire)
    check greedy.sampledTokenIds.get() == @[3, 4]
    check greedy.behaviorLogprobs.isNone
    wire["behavior_logprobs"] = %*[-0.5, -0.3]
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

  test "actual response headers survive authoritative episode export":
    let record = episode()
    var attempt = teacher()
    attempt.responseHeaders = some({"request-id": "provider-real",
      "X-Trace-Header": "private value"}.toTable())
    attempt.providerRequestId = some("provider-real")
    record.recordDecision("d0", "0", %*{}, @[attempt], some(attempt.attemptId),
      attempt.parsedAction, asAccepted, terminal = true)
    record.finish(esCompleted, %*{}, %*{})
    let encoded = parseJson(record.eventsJsonl().splitLines()[0])["attempts"][0]
    check encoded["response_headers"]["X-Trace-Header"].getStr() == "private value"
    check encoded["provider_request_id"].getStr() == "provider-real"
    let wire = attempt.attemptEvidenceJson()
    wire["response_headers"] = %*{"request-id": 42}
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

  test "macro orders keep authoritative physical ticks separately from parsed action":
    let record = episode()
    let physical = ExecutionEvidence(controlEncoding: ceI8I8I8U8, startTick: 12, endTick: 14, tickHz: 24,
      seatControlsBase64: encode("\xff\x00\x7f\x03\x01\x02\x80\x00"))
    record.recordDecision("d0", "0", %*{}, @[teacher()], some("d0-a0"),
      %*{"move": 1}, asAccepted, execution = some(physical))
    record.finish(esCompleted, %*{"winner": 0}, %*{"0": 1})
    let decision = parseJson(record.eventsJsonl().splitLines()[0])
    check decision["executed_action"] == decision["attempts"][0]["parsed_action"]
    check decision["execution"]["end_tick"].getInt() == 14
    check decode(decision["execution"]["seat_controls_b64"].getStr()) ==
      "\xff\x00\x7f\x03\x01\x02\x80\x00"
    let invalid = episode()
    expect ValueError:
      invalid.recordDecision("d0", "0", %*{}, @[teacher()], some("d0-a0"),
        %*{"move": 1}, asAccepted, execution = some(ExecutionEvidence(
          startTick: 12, endTick: 14, tickHz: 24, seatControlsBase64: encode("four"))))

  test "private corpus artifacts refuse existing files and symlinks":
    let parent = getTempDir() / ("bitworld-private-corpus-" & $getCurrentProcessId())
    let destination = parent / "manifest.json"
    writePrivate(destination, "original private corpus")
    defer:
      removeFile(destination)
      removeDir(parent)
    check getFilePermissions(parent) == {fpUserRead, fpUserWrite, fpUserExec}
    check getFilePermissions(destination) == {fpUserRead, fpUserWrite}
    expect ValueError: writePrivate(destination, "replacement")
    check readFile(destination) == "original private corpus"
    when defined(posix):
      let alias = parent / "alias.json"
      createSymlink(destination, alias)
      defer: removeFile(alias)
      expect ValueError: writePrivate(alias, "replacement through symlink")
      check readFile(destination) == "original private corpus"

  test "private inference mode is game-owned and absent from the player wire":
    var attempt = teacher()
    check attempt.inferenceMode == imTextAction
    let wire = attempt.attemptEvidenceJson()
    check not wire.hasKey("inference_mode")
    wire["inference_mode"] = %"candidate"
    expect ValueError: discard readAttemptEvidence(wire)
    wire.delete("inference_mode")
    check readAttemptEvidence(wire).inferenceMode == imTextAction
    let record = episode()
    record.recordDecision("d0", "0", %*{}, @[attempt], some(attempt.attemptId),
      attempt.parsedAction, asAccepted)
    attempt.inferenceMode = imCandidate
    attempt.attemptId = "d1-a0"
    record.recordDecision("d1", "0", %*{}, @[attempt], some(attempt.attemptId),
      attempt.parsedAction, asAccepted)
    record.finish(esCompleted, %*{"winner": 0}, %*{"0": 1})
    let events = record.eventsJsonl().splitLines()
    check parseJson(events[0])["attempts"][0]["inference_mode"].getStr() == "text_action"
    check parseJson(events[1])["attempts"][0]["inference_mode"].getStr() == "candidate"

  test "partial transport bytes stay private and cannot be treated as complete":
    var partial = newDecisionAttempt("d0-partial", "native", aoModel)
    partial.responseBodyB64 = some(encode("partial\x00\xff"))
    partial.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\nX-Trace: a\r\nX-Trace: b\r\n\r\n"))
    partial.responseComplete = some(false)
    partial.httpStatus = some(200)
    partial.rejectionReason = some("interrupted native transfer")
    let snapshot = readAttemptEvidence(partial.attemptEvidenceJson())
    check decode(snapshot.responseBodyB64.get()) == "partial\x00\xff"
    check snapshot.responseHeadersB64 == partial.responseHeadersB64
    check snapshot.responseComplete == some(false)
    check snapshot.httpStatus == some(200)
    let record = episode()
    record.recordDecision("partial", "0", %*{}, @[snapshot], none(string),
      %*{"move": 0}, asFallback, fallbackOrigin = some("engine-scripted"))
    record.finish(esTruncated, %*{}, %*{})
    let actual = parseJson(record.eventsJsonl().splitLines()[0])["attempts"][0]
    check actual["response_complete"].getBool() == false
    check decode(actual["response_body_b64"].getStr()) == "partial\x00\xff"
    var wire = partial.attemptEvidenceJson()
    wire["response_complete"] = %"true"
    expect ValueError: discard readAttemptEvidence(wire)
    wire = partial.attemptEvidenceJson()
    wire["http_status"] = %0
    expect ValueError: discard readAttemptEvidence(wire)
    wire = partial.attemptEvidenceJson()
    wire["response_body_b64"] = %"Zg"
    expect ValueError: discard readAttemptEvidence(wire)
    wire = partial.attemptEvidenceJson()
    wire["raw_response"] = %"different received bytes"
    expect ValueError: discard readAttemptEvidence(wire)

  test "shipped wire envelopes do not invent newly captured transport evidence":
    var wire = teacher().attemptEvidenceJson()
    for key in ["response_body_b64", "response_headers_b64", "response_complete", "http_status"]:
      wire.delete(key)
    let actual = readAttemptEvidence(wire)
    check actual.responseBodyB64.isNone
    check actual.responseHeadersB64.isNone
    check actual.responseComplete.isNone
    check actual.httpStatus.isNone
    wire.delete("response")
    expect ValueError: discard readAttemptEvidence(wire)

  test "actual joined-reader evidence survives private wire and engine export":
    var attempt = teacher()
    attempt.origin = aoModel
    attempt.responseReaderJoined = some(true)
    let wire = attempt.attemptEvidenceJson()
    check readAttemptEvidence(wire).responseReaderJoined == some(true)
    let record = episode()
    record.recordDecision("d0", "0", %*{}, @[attempt], some(attempt.attemptId),
      attempt.parsedAction, asAccepted)
    record.finish(esCompleted, %*{}, %*{})
    check parseJson(record.eventsJsonl().splitLines()[0])["attempts"][0]["response_reader_joined"].getBool()
    wire["response_reader_joined"] = %false
    check readAttemptEvidence(wire).responseReaderJoined == some(false)
    wire.delete("response_reader_joined")
    check readAttemptEvidence(wire).responseReaderJoined.isNone
    wire["response_reader_joined"] = %"joined"
    expect ValueError: discard readAttemptEvidence(wire)

  test "game-owned scoring survives original failure and selected action joins":
    let record = episode()
    var rejected = newDecisionAttempt("rank-rejected", "policy", aoModel, imCandidate)
    rejected.actionEvidence = some(%*{"protocol": "fixture.score.v1",
      "scoring_result": {"kind": "rejected", "fault": "provider_error"}})
    rejected.rejectionReason = some("original provider failure")
    var selected = newDecisionAttempt("rank-scored", "policy", aoModel, imCandidate)
    selected.actionEvidence = some(%*{"protocol": "fixture.score.v1",
      "scoring_result": {"kind": "scored", "selected_index": 0}})
    selected.parsedAction = %*{"move": 1}
    selected.accepted = true
    record.recordDecision("rank", "0", %*{}, @[rejected, selected],
      some("rank-scored"), selected.parsedAction, asAccepted)
    selected.actionEvidence.get()["scoring_result"]["selected_index"] = %9
    record.finish(esCompleted, %*{}, %*[1])
    let event = parseJson(record.eventsJsonl().splitLines()[0])
    check event["attempts"].len == 2
    check event["attempts"][0]["action_evidence"]["scoring_result"]["kind"].getStr() == "rejected"
    check event["attempts"][1]["action_evidence"]["scoring_result"]["selected_index"].getInt() == 0
    check event["attempts"][1]["response"].kind == JNull
    check event["executed_action"] == event["attempts"][1]["parsed_action"]

  test "scoring cannot acquire generation or sampled token provenance":
    for fault in ["mode", "text", "tokens", "probabilities"]:
      var attempt = newDecisionAttempt("rank", "policy", aoModel, imCandidate)
      attempt.actionEvidence = some(%*{"protocol": "fixture.score.v1"})
      case fault
      of "mode": attempt.inferenceMode = imTextAction
      of "text": attempt.response = %"generated-looking text"
      of "tokens": attempt.sampledTokenIds = some(@[1])
      else: attempt.behaviorLogprobs = some(@[-0.1])
      expect ValueError:
        episode().recordDecision("rank", "0", %*{}, @[attempt], none(string),
          %*{"move": 1}, asFallback, fallbackOrigin = some("actual-scripted"))

  test "private players cannot inject game-owned scoring evidence":
    var attempt = newDecisionAttempt("rank", "policy", aoModel, imCandidate)
    attempt.actionEvidence = some(%*{"protocol": "fixture.score.v1"})
    let wire = attempt.attemptEvidenceJson()
    check not wire.hasKey("action_evidence")
    wire["action_evidence"] = %*{"protocol": "fixture.score.v1"}
    expect ValueError:
      discard readAttemptEvidence(wire)


  test "u8 execution retains one actual control byte per tick":
    let record = episode()
    let attempt = teacher()
    let controls = "\x00\x7f\xfe"
    let physical = ExecutionEvidence(controlEncoding: ceU8,
      startTick: 5, endTick: 8, tickHz: 24, seatControlsBase64: encode(controls))
    record.recordDecision("u8", "0", %*{}, @[attempt], some(attempt.attemptId),
      attempt.parsedAction, asAccepted, execution = some(physical))
    record.finish(esCompleted, %*{}, %*{})
    let event = parseJson(record.eventsJsonl().splitLines()[0])
    check event["execution"]["control_encoding"].getStr() == "u8"
    check decode(event["execution"]["seat_controls_b64"].getStr()) == controls
    for invalid in [encode(controls & controls & controls & controls), "AH/+==="]:
      var padded = physical
      padded.seatControlsBase64 = invalid
      expect ValueError:
        episode().recordDecision("invalid", "0", %*{}, @[attempt],
          some(attempt.attemptId), attempt.parsedAction, asAccepted,
          execution = some(padded))


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



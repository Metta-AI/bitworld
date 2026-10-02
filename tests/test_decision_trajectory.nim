import std/[base64, json, options, os, strutils, unittest]
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
    let physical = ExecutionEvidence(startTick: 12, endTick: 14, tickHz: 24,
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

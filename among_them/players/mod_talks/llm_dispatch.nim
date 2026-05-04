## Non-blocking LLM dispatcher via subprocess polling (Sprint 7.2).
##
## Nim Channels don't work reliably across threads under --mm:orc,
## and blocking the frame loop for 5-9s kills the websocket. This
## dispatcher starts the Bedrock subprocess (or HTTP call) and polls
## `process.running()` each frame. When done, reads the response
## file. No threads, no channels.
##
## For non-Bedrock providers (Anthropic direct, OpenAI), the call
## blocks briefly (~1-3s) which is acceptable — those providers use
## std/httpclient, not subprocess.

import std/[json, options, os, osproc, times]

import types
import tuning
import llm_provider

type
  LlmDispatchRequest* = object
    role*: BotRole
    kind*: LlmCallKind
    contextJson*: string

  LlmDispatchResult* = object
    kind*: LlmCallKind
    responseJson*: string
    errored*: bool
    latencyMs*: int

  LlmDispatcher* = ref object
    provider*:    LlmProvider
    inflight:     bool
    closed:       bool
    # In-flight subprocess state (Bedrock only).
    process:      Process
    respFile:     string
    bodyFile:     string
    kind:         LlmCallKind
    startedAt:    float
    deadline:     float

proc initLlmDispatcher*(provider: LlmProvider): LlmDispatcher =
  LlmDispatcher(provider: provider)

proc submit*(d: LlmDispatcher; req: LlmDispatchRequest): bool =
  if d.isNil or d.closed: return false
  if d.inflight: return false
  if not d.provider.enabled():
    d.inflight = false
    return false  # caller should treat as immediate error

  d.kind = req.kind
  d.startedAt = epochTime()
  let timeout = timeoutSecFor(req.kind)
  d.deadline = d.startedAt + timeout

  if d.provider.kind == lpkBedrock:
    # Start subprocess without blocking.
    let body = d.provider.bedrockBodyPublic(req.role, req.kind, req.contextJson)
    let tmp = getTempDir()
    let suffix = $epochTime() & "-" & $getCurrentProcessId()
    d.bodyFile = tmp / "modtalks_body_" & suffix & ".json"
    d.respFile = tmp / "modtalks_resp_" & suffix & ".json"
    writeFile(d.bodyFile, body)
    let args = @[
      "bedrock-runtime", "invoke-model",
      "--region", d.provider.region,
      "--model-id", d.provider.model,
      "--cli-binary-format", "raw-in-base64-out",
      "--body", "file://" & d.bodyFile,
      d.respFile
    ]
    try:
      d.process = startProcess(
        command = d.provider.awsCli,
        args = args,
        options = {poUsePath, poStdErrToStdOut}
      )
    except CatchableError:
      return false
    d.inflight = true
    return true
  else:
    # Non-Bedrock: call synchronously (typically 1-3s).
    let res = d.provider.complete(req.role, req.kind, req.contextJson)
    d.inflight = false
    # Store result for immediate gather.
    d.kind = req.kind
    # We'll handle this via a flag.
    return false  # not really inflight; caller should call complete directly

proc tryGather*(d: LlmDispatcher): Option[LlmDispatchResult] =
  if d.isNil or d.closed or not d.inflight:
    return none(LlmDispatchResult)

  if d.process.isNil:
    d.inflight = false
    return some(LlmDispatchResult(
      kind: d.kind, responseJson: "", errored: true, latencyMs: 0
    ))

  # Check if subprocess is still running.
  let stillRunning = d.process.running()
  if stillRunning:
    # Check timeout.
    if epochTime() > d.deadline:
      d.process.kill()
      d.process.close()
      d.inflight = false
      try:
        if d.bodyFile.len > 0 and fileExists(d.bodyFile): removeFile(d.bodyFile)
        if d.respFile.len > 0 and fileExists(d.respFile): removeFile(d.respFile)
      except CatchableError: discard
      return some(LlmDispatchResult(
        kind: d.kind, responseJson: "", errored: true,
        latencyMs: int((epochTime() - d.startedAt) * 1000)
      ))
    return none(LlmDispatchResult)

  # Process finished.
  let exitCode = d.process.peekExitCode()
  d.process.close()
  d.inflight = false
  let latency = int((epochTime() - d.startedAt) * 1000)

  var responseJson = ""
  var errored = true
  if exitCode == 0:
    try:
      let resp = readFile(d.respFile)
      let parsed = d.provider.extractToolUsePublic(resp)
      if parsed.found:
        responseJson = parsed.json
        errored = false
    except CatchableError:
      discard

  try:
    if d.bodyFile.len > 0 and fileExists(d.bodyFile): removeFile(d.bodyFile)
    if d.respFile.len > 0 and fileExists(d.respFile): removeFile(d.respFile)
  except CatchableError: discard

  some(LlmDispatchResult(
    kind: d.kind, responseJson: responseJson,
    errored: errored, latencyMs: latency
  ))

proc inflightCount*(d: LlmDispatcher): int =
  if d.isNil or d.closed: 0
  elif d.inflight: 1
  else: 0

proc closeLlmDispatcher*(d: LlmDispatcher) =
  if d.isNil or d.closed: return
  d.closed = true
  if d.inflight and not d.process.isNil:
    try:
      d.process.kill()
      d.process.close()
    except CatchableError: discard
  d.inflight = false

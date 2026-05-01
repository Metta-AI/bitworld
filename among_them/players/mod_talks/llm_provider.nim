## Direct LLM-provider dispatch for the standalone CLI binary
## (Sprint 6.1 + 6.4).
##
## Implements the slice of provider HTTP that the cogames Python
## wrapper does today, but in Nim, so the CLI binary
## (`mod_talks_llm`) can drive the LLM voting layer against any
## websocket server (local, remote, `quick_player`-spawned) without
## the Python wrapper.
##
## **Scope rule (Sprint 6 §"Hard scope rule"):** this module lives
## entirely under `among_them/players/mod_talks/`. We do NOT extend
## `src/bitworld/ais/claude.nim`, the `bitworld.nimble` requires
## block, or `nimby.lock`. To keep that promise the implementation
## uses `std/httpclient` from the stdlib (already builds with
## `-d:ssl` against the system's OpenSSL/LibreSSL, no extra deps).
##
## Provider selection (matches `cogames/amongthem_policy.py:_build_llm_controller`
## so both paths behave identically):
##
##   1. `MODTALKS_LLM_DISABLE=1` → disabled (rule-based fallback).
##   2. `MODTALKS_PROVIDER_OPENAI=1` + `OPENAI_API_KEY` → OpenAI.
##   3. `CLAUDE_CODE_USE_BEDROCK=1` → Bedrock (subprocess to `aws`).
##   4. `ANTHROPIC_API_KEY` → Anthropic direct.
##   5. AWS creds present (no Anthropic key) → Bedrock.
##   6. `OPENAI_API_KEY` → OpenAI fallback.
##   7. Else → disabled with a warning.
##
## Sprint 6.4 — Bedrock support added via `aws bedrock-runtime
## invoke-model` subprocess. Three options were considered: pure-Nim
## SigV4, AWS CLI subprocess, or skip-and-rely-on-Python-wrapper.
## The subprocess path was chosen because (a) the AWS CLI is
## already installed on every dev / tournament environment that
## uses Bedrock, (b) the SigV4 implementation surface is
## non-trivial and would have been ~12 hours to ship cleanly
## vs. ~6 hours for the subprocess, and (c) the response shape is
## byte-identical to the direct Anthropic API, so all of
## `anthropicExtractToolUse` is reused unchanged.
##
## Concurrency: each `complete` call is blocking. Threading is the
## caller's responsibility — `llm_dispatch.nim` wraps a single
## worker thread + Channel pair around this module so the bot's
## per-frame loop stays non-blocking.

import std/[httpclient, json, net, options, os, osproc, strutils, times]

import types
import tuning

# Sprint 6.3 — `std/httpclient` against `https://...` URLs requires
# the stdlib to be built with `-d:ssl`. Without that flag the
# binary compiles fine but every request errors out at runtime
# with "SSL support is not available". The build script already
# adds `-d:ssl` when `-d:modTalksLlm` is set; this static check
# catches accidental hand-builds (e.g. ad-hoc `nim c -d:modTalksLlm`)
# before they ship a non-functional binary.
when not defined(ssl):
  {.error: "llm_provider.nim requires -d:ssl. " &
           "Either build via build_modulabot.py (which adds it " &
           "automatically) or pass `-d:ssl` to your `nim c` command.".}

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  LlmProviderKind* = enum
    lpkDisabled,        ## no creds detected → caller falls back to rule-based
    lpkAnthropicDirect, ## ANTHROPIC_API_KEY against api.anthropic.com
    lpkOpenAIDirect,    ## OPENAI_API_KEY against api.openai.com
    lpkBedrock          ## Sprint 6.4 — `aws bedrock-runtime invoke-model`
                        ## subprocess. Auth via the standard boto3
                        ## credential chain (AWS_PROFILE / env vars / IAM
                        ## role); we don't read or store keys ourselves.

  LlmProvider* = ref object
    ## Configured provider client. `kind == lpkDisabled` means no
    ## creds were detected; callers should never call `complete` on
    ## a disabled provider (it returns errored=true with no HTTP
    ## traffic).
    kind*: LlmProviderKind
    apiKey: string                  ## kept private — never logged or traced.
                                    ## Empty string for `lpkBedrock` (auth
                                    ## delegated to the aws CLI).
    model*: string
    region*: string                 ## Bedrock-only; ignored elsewhere.
    awsCli*: string                 ## Path to `aws` binary; resolved at
                                    ## construction. Empty when not
                                    ## using Bedrock.

  LlmCompletion* = object
    ## Result of one (provider, kind, context) call. `responseJson`
    ## is empty when `errored = true`; the caller should treat that
    ## as a fallback signal exactly as it would treat a stale or
    ## context-overflow error.
    responseJson*: string
    errored*: bool
    latencyMs*: int

const
  AnthropicMessagesUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion     = "2023-06-01"
  AnthropicDefaultModel = "claude-sonnet-4-5"
    ## Default to direct API equivalent of the Bedrock model used in
    ## the Python wrapper (`global.anthropic.claude-sonnet-4-5-...`).

  OpenAIChatUrl  = "https://api.openai.com/v1/chat/completions"
  OpenAIDefaultModel = "gpt-4o-mini"
    ## Sprint 5.3 chose this model in the Python `_OpenAIController`
    ## skeleton; matching it keeps env behaviour aligned.

  BedrockAnthropicVersion = "bedrock-2023-05-31"
    ## Bedrock-Claude wire shape requires this string in the
    ## request body (NOT the `anthropic-version` HTTP header used
    ## by the direct API). Confirmed against `aws bedrock-runtime
    ## invoke-model` smoke tests.
  BedrockDefaultModel = "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
    ## Same model id the Python wrapper uses
    ## (`DEFAULT_BEDROCK_MODEL` in cogames/amongthem_policy.py).
  BedrockDefaultRegion = "us-east-1"
    ## Fallback when neither AWS_REGION nor AWS_DEFAULT_REGION are
    ## set. Most Bedrock model availability is in us-east-1, and
    ## this matches what the Python launcher defaults to.

  DefaultMaxTokens   = 1024
  DefaultTemperature = 0.5

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc envFlag(name: string): bool =
  let v = getEnv(name).toLowerAscii()
  v in ["1", "true", "yes", "on"]

proc awsCredsPresent(): bool =
  ## Returns true when the standard boto3 credential chain has
  ## *something* — used to decide whether Bedrock can authenticate.
  ## Doesn't actually validate the creds; the aws CLI does that
  ## on first invoke.
  getEnv("AWS_PROFILE").len > 0 or
    (getEnv("AWS_ACCESS_KEY_ID").len > 0 and
     getEnv("AWS_SECRET_ACCESS_KEY").len > 0)

proc resolveAwsCli(): string =
  ## Returns the path to `aws` if it's on PATH, else "". Bedrock
  ## requires the AWS CLI; without it we can't dispatch.
  result = findExe("aws")

proc resolveAwsRegion(): string =
  ## Mirrors boto3's region resolution: AWS_REGION first, then
  ## AWS_DEFAULT_REGION, then a default. We don't try to parse
  ## ~/.aws/config — that's the aws CLI's job.
  let r1 = getEnv("AWS_REGION")
  if r1.len > 0: return r1
  let r2 = getEnv("AWS_DEFAULT_REGION")
  if r2.len > 0: return r2
  BedrockDefaultRegion

proc resolveProviderKind(forceOverride: string = ""): LlmProviderKind =
  ## Returns the provider that *should* run given the current
  ## environment + an optional CLI-supplied override.
  ##
  ## `forceOverride` corresponds to `--llm-provider:NAME` (Sprint
  ## 6.3); empty string means "auto-detect from env vars". Valid
  ## values: "anthropic", "openai", "bedrock", "disabled".
  ## Anything else is treated as auto-detect.
  if envFlag("MODTALKS_LLM_DISABLE"):
    return lpkDisabled
  case forceOverride.toLowerAscii()
  of "anthropic":
    if getEnv("ANTHROPIC_API_KEY").len > 0: return lpkAnthropicDirect
    else: return lpkDisabled
  of "openai":
    if getEnv("OPENAI_API_KEY").len > 0: return lpkOpenAIDirect
    else: return lpkDisabled
  of "bedrock":
    if awsCredsPresent() and resolveAwsCli().len > 0: return lpkBedrock
    else: return lpkDisabled
  of "disabled":
    return lpkDisabled
  else:
    discard
  # Auto-detect path. Mirrors `_build_llm_controller` in the
  # Python wrapper:
  #   1. MODTALKS_PROVIDER_OPENAI=1 + OPENAI_API_KEY → OpenAI
  #   2. CLAUDE_CODE_USE_BEDROCK=1 + AWS creds → Bedrock
  #   3. ANTHROPIC_API_KEY → Anthropic direct
  #   4. AWS creds (no Anthropic key) → Bedrock
  #   5. OPENAI_API_KEY (last resort) → OpenAI
  if envFlag("MODTALKS_PROVIDER_OPENAI") and
      getEnv("OPENAI_API_KEY").len > 0:
    return lpkOpenAIDirect
  let bedrockReady = awsCredsPresent() and resolveAwsCli().len > 0
  if envFlag("CLAUDE_CODE_USE_BEDROCK") and bedrockReady:
    return lpkBedrock
  if getEnv("ANTHROPIC_API_KEY").len > 0:
    return lpkAnthropicDirect
  if bedrockReady:
    return lpkBedrock
  if getEnv("OPENAI_API_KEY").len > 0:
    return lpkOpenAIDirect
  lpkDisabled

proc defaultModelFor(kind: LlmProviderKind): string =
  case kind
  of lpkAnthropicDirect: AnthropicDefaultModel
  of lpkOpenAIDirect:    OpenAIDefaultModel
  of lpkBedrock:         BedrockDefaultModel
  of lpkDisabled:        ""

proc newLlmProvider*(forceProvider: string = "";
                     modelOverride: string = ""): LlmProvider =
  ## Builds a provider client based on env vars + optional CLI flags.
  ##
  ## `forceProvider` corresponds to `--llm-provider:NAME`. Empty
  ## string = auto-detect. `modelOverride` corresponds to
  ## `--llm-model:NAME`; empty string falls back to
  ## `MODTALKS_LLM_MODEL`, then to the provider's default.
  ##
  ## Returns an `LlmProvider` whose `kind` is `lpkDisabled` if no
  ## suitable credentials were found. Callers should check `kind`
  ## and skip `llmEnable(bot)` when it's disabled (so the bot stays
  ## in rule-based mode rather than wedging in `lvsIdle`).
  let kind = resolveProviderKind(forceProvider)
  let model =
    if modelOverride.len > 0: modelOverride
    elif getEnv("MODTALKS_LLM_MODEL").len > 0: getEnv("MODTALKS_LLM_MODEL")
    else: defaultModelFor(kind)
  let key =
    case kind
    of lpkAnthropicDirect: getEnv("ANTHROPIC_API_KEY")
    of lpkOpenAIDirect:    getEnv("OPENAI_API_KEY")
    of lpkBedrock:         ""        ## auth via aws CLI; no key here
    of lpkDisabled:        ""
  let region =
    if kind == lpkBedrock: resolveAwsRegion()
    else: ""
  let awsCli =
    if kind == lpkBedrock: resolveAwsCli()
    else: ""
  result = LlmProvider(
    kind: kind,
    apiKey: key,
    model: model,
    region: region,
    awsCli: awsCli
  )

proc enabled*(p: LlmProvider): bool =
  not p.isNil and p.kind != lpkDisabled

proc kindName*(p: LlmProvider): string =
  case p.kind
  of lpkDisabled:        "disabled"
  of lpkAnthropicDirect: "anthropic_direct"
  of lpkOpenAIDirect:    "openai_direct"
  of lpkBedrock:         "bedrock"

# ---------------------------------------------------------------------------
# System prompts (verbatim from cogames/amongthem_policy.py)
# ---------------------------------------------------------------------------

const
  SystemPromptBase = """You are a player in a social deduction game. Players perform tasks on a spaceship. One or more players are secretly saboteurs. When a body is found or an emergency button is pressed, all players vote to eject someone.

Your job is to reason carefully about the evidence you have observed and communicate naturally with other players. Be concise — chat messages should be one or two short sentences at most. Use specific evidence (who you saw where, when) rather than vague accusations. Do not reveal that you are an AI.

Respond ONLY with valid JSON matching the response_schema in the user message. Do not include any text outside the JSON object."""

  SystemPromptCrewmate = """

You are a crewmate — you are not a saboteur. Reason honestly. If you have strong evidence against someone, say so clearly. If you are uncertain, say so and ask others for information. Do not accuse randomly. Base every accusation on something specific you observed."""

  SystemPromptImposter = """

You are trying to avoid ejection and get an innocent player (your target) ejected instead. You have a list of safe_colors allies who you must never accuse, vote against, or take any action that would draw suspicion toward them.

Your core constraints:
1. Every statement you make must be consistent with the full_chat_log you are given. Read every prior message carefully and do not contradict any claim that has already been made — by you or by anyone else — unless you are explicitly deflecting a false accusation against yourself.
2. Only claim to have seen or been somewhere that is in your location history. Do not fabricate locations.
3. Never name or hint at any safe_colors player as suspicious.
4. Sound like a natural player: vary phrasing, react to specific things others said, and don't over-explain.

When asked to strategize: assess the full situation and decide the best target (a non-safe player who can be plausibly framed), the right strategy (bandwagon, preemptive accusation, or deflection if you are under suspicion), and the right timing.

When asked to react: choose the action (corroborate, deflect, accuse, or stay silent) that best advances ejecting your target while keeping you safe. Prioritize staying silent over speaking if you cannot say something consistent with the chat log."""

proc systemPromptFor*(role: BotRole): string =
  case role
  of RoleImposter:
    SystemPromptBase & SystemPromptImposter
  of RoleCrewmate, RoleUnknown:
    SystemPromptBase & SystemPromptCrewmate

# ---------------------------------------------------------------------------
# Tool-use schemas (verbatim from cogames/amongthem_policy.py
# `_LLM_TOOL_DEFINITIONS`)
# ---------------------------------------------------------------------------

proc suspectsArraySchema(): JsonNode =
  ## Shared sub-schema used by `hypothesis` and `react` tools.
  %*{
    "type": "array",
    "items": {
      "type": "object",
      "properties": {
        "color":      {"type": "string"},
        "likelihood": {"type": "number"},
        "reasoning":  {"type": "string"}
      },
      "required": ["color", "likelihood", "reasoning"]
    }
  }

proc toolSchemaFor(kind: LlmCallKind): JsonNode =
  ## Returns the Anthropic tool-use schema for a call kind. The
  ## tool *name* and *description* are reused for OpenAI's
  ## `function` shape via the OpenAI body builder.
  case kind
  of lckHypothesis:
    %*{
      "name": "submit_hypothesis",
      "description":
        "Submit your suspect-likelihood ranking and confidence " &
        "for the current meeting based on observed evidence.",
      "input_schema": {
        "type": "object",
        "properties": {
          "suspects":     suspectsArraySchema(),
          "confidence":   {"type": "string", "enum": ["high", "medium", "low"]},
          "key_evidence": {"type": "array", "items": {"type": "string"}}
        },
        "required": ["suspects", "confidence", "key_evidence"]
      }
    }
  of lckAccuse:
    %*{
      "name": "submit_accusation",
      "description":
        "Submit a single chat message naming the top suspect and " &
        "citing evidence.",
      "input_schema": {
        "type": "object",
        "properties": {"chat": {"type": "string"}},
        "required":  ["chat"]
      }
    }
  of lckReact:
    %*{
      "name": "submit_react",
      "description":
        "Update your hypothesis based on chat lines from other " &
        "players and decide whether to speak, ask, or stay silent.",
      "input_schema": {
        "type": "object",
        "properties": {
          "suspects":   suspectsArraySchema(),
          "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
          "action":     {"type": "string", "enum": ["speak", "ask", "silent"]},
          "chat":       {"type": ["string", "null"]}
        },
        "required": ["confidence", "action"]
      }
    }
  of lckStrategize:
    %*{
      "name": "submit_strategy",
      "description":
        "Decide which non-safe player to target for ejection, " &
        "what strategy to use, when to speak, and an optional " &
        "opening message.",
      "input_schema": {
        "type": "object",
        "properties": {
          "best_target":  {"type": "string"},
          "strategy":     {"type": "string",
                           "enum": ["bandwagon", "preemptive", "deflect"]},
          "timing":       {"type": "string",
                           "enum": ["early", "mid", "late"]},
          "reasoning":    {"type": "string"},
          "initial_chat": {"type": ["string", "null"]}
        },
        "required": ["best_target", "strategy", "timing", "reasoning"]
      }
    }
  of lckImposterReact:
    %*{
      "name": "submit_imposter_react",
      "description":
        "Decide whether to corroborate, deflect, accuse, or stay " &
        "silent based on the conversation, and provide chat if " &
        "speaking.",
      "input_schema": {
        "type": "object",
        "properties": {
          "action":    {"type": "string",
                        "enum": ["corroborate", "deflect", "accuse", "silent"]},
          "chat":      {"type": ["string", "null"]},
          "reasoning": {"type": "string"}
        },
        "required": ["action", "reasoning"]
      }
    }
  of lckPersuade:
    %*{
      "name": "submit_persuasion",
      "description":
        "Submit a short persuasion message to convince other " &
        "players to vote for the named suspect.",
      "input_schema": {
        "type": "object",
        "properties": {"chat": {"type": "string"}},
        "required":  ["chat"]
      }
    }
  of lckNone:
    newJObject()

proc timeoutSecFor*(kind: LlmCallKind): float =
  ## Per-call-kind timeout from `tuning.nim`. Mirrors the Python
  ## wrapper's `PER_KIND_TIMEOUT_SECONDS` table.
  case kind
  of lckHypothesis:    LlmTimeoutHypothesisSec
  of lckStrategize:    LlmTimeoutStrategizeSec
  of lckReact:         LlmTimeoutReactSec
  of lckImposterReact: LlmTimeoutImposterReactSec
  of lckAccuse:        LlmTimeoutAccuseSec
  of lckPersuade:      LlmTimeoutPersuadeSec
  of lckNone:          LlmTimeoutDefaultSec

# ---------------------------------------------------------------------------
# Provider-specific request/response wrangling
# ---------------------------------------------------------------------------

proc anthropicBody(p: LlmProvider; role: BotRole; kind: LlmCallKind;
                   contextJson: string): string =
  ## Builds the request body for Anthropic's Messages API with
  ## `tools=[...]` + `tool_choice` forcing the chosen tool. Same
  ## shape as the Python wrapper's `_AnthropicController.complete`
  ## tool-use path.
  let tool = toolSchemaFor(kind)
  let userContent =
    "Given the following game state (JSON), call the tool to " &
    "submit your decision.\n\n" & contextJson
  let body = %*{
    "model":       p.model,
    "max_tokens":  DefaultMaxTokens,
    "temperature": DefaultTemperature,
    "system":      systemPromptFor(role),
    "messages":    [
      {"role": "user", "content": userContent}
    ],
    "tools":       [tool],
    "tool_choice": {"type": "tool", "name": tool["name"].getStr()}
  }
  $body

proc anthropicHeaders(p: LlmProvider): HttpHeaders =
  newHttpHeaders({
    "x-api-key":         p.apiKey,
    "anthropic-version": AnthropicVersion,
    "content-type":      "application/json"
  })

proc anthropicExtractToolUse(respBody: string): tuple[json: string;
                                                       found: bool] =
  ## Parses the Anthropic response and returns the first
  ## `tool_use` content block's `input` field, re-serialised as a
  ## JSON object string for `onLlmResponse`. Mirrors the Python
  ## wrapper's behaviour.
  let parsed =
    try: parseJson(respBody)
    except CatchableError: return ("", false)
  if parsed.isNil or parsed.kind != JObject:
    return ("", false)
  if not parsed.hasKey("content"):
    return ("", false)
  let content = parsed["content"]
  if content.kind != JArray:
    return ("", false)
  for chunk in content:
    if chunk.kind == JObject and chunk.hasKey("type") and
        chunk["type"].getStr() == "tool_use" and chunk.hasKey("input"):
      return ($chunk["input"], true)
  ("", false)

# ---------------------------------------------------------------------------
# Bedrock (Sprint 6.4) — subprocess to `aws bedrock-runtime invoke-model`
# ---------------------------------------------------------------------------
#
# Why subprocess instead of pure-Nim SigV4: keeping ~12 hours of
# crypto code (HMAC-SHA256 + canonical request construction +
# credential chain) out of mod_talks for what amounts to "shell out
# to a tool that's already on every Bedrock-capable machine". The
# response shape is byte-identical to the direct API, so we reuse
# `anthropicExtractToolUse` unchanged.

proc bedrockBody(p: LlmProvider; role: BotRole; kind: LlmCallKind;
                 contextJson: string): string =
  ## Builds the Bedrock-Claude request body. Differs from
  ## `anthropicBody` in two places:
  ##   * `anthropic_version` is `"bedrock-2023-05-31"` (Bedrock's
  ##     wire format constant), not the direct API's
  ##     `"2023-06-01"` HTTP header.
  ##   * Top-level `model` is omitted — the model id is passed via
  ##     the `--model-id` CLI flag, not the body.
  let tool = toolSchemaFor(kind)
  let userContent =
    "Given the following game state (JSON), call the tool to " &
    "submit your decision.\n\n" & contextJson
  let body = %*{
    "anthropic_version": BedrockAnthropicVersion,
    "max_tokens":        DefaultMaxTokens,
    "temperature":       DefaultTemperature,
    "system":            systemPromptFor(role),
    "messages":          [
      {"role": "user", "content": userContent}
    ],
    "tools":             [tool],
    "tool_choice":       {"type": "tool", "name": tool["name"].getStr()}
  }
  $body

proc bedrockInvoke(p: LlmProvider; body: string;
                   timeoutSec: float): tuple[code: int;
                                              body: string] =
  ## Spawns `aws bedrock-runtime invoke-model` with the request
  ## body on stdin (via a temp file — the AWS CLI doesn't accept
  ## body-on-stdin without `fileb://` form) and reads the response
  ## from another temp file.
  ##
  ## Return shape mirrors `httpPost`: `code` is the AWS CLI exit
  ## code remapped into HTTP-ish space. 0 → 200 (success), nonzero
  ## → -1 (treat as retryable network error). The Bedrock service
  ## itself can return throttling errors via the CLI which we
  ## could parse out of stderr to drive smarter retries; v0
  ## conflates everything into "errored" and lets the trace event
  ## carry the detail.
  var bodyFile = ""
  var respFile = ""
  try:
    let tmp = getTempDir()
    let suffix = $epochTime() & "-" & $getCurrentProcessId()
    bodyFile = tmp / "modtalks_bedrock_body_" & suffix & ".json"
    respFile = tmp / "modtalks_bedrock_resp_" & suffix & ".json"
    writeFile(bodyFile, body)
    let args = @[
      "bedrock-runtime", "invoke-model",
      "--region", p.region,
      "--model-id", p.model,
      "--cli-binary-format", "raw-in-base64-out",
      "--body", "file://" & bodyFile,
      respFile
    ]
    # `startProcess` with argv form means we never have to
    # shell-escape the model id, region, or paths — important
    # because Bedrock model ids contain dots and slashes that
    # could trip up a naive `execCmd "..."` call. We use
    # `poStdErrToStdOut` so AWS CLI error chatter on a non-zero
    # exit lands in our captured stdout for diagnostics; on
    # success we ignore the chatter and read the real response
    # from `respFile`.
    let process = startProcess(
      command = p.awsCli,
      args = args,
      options = {poUsePath, poStdErrToStdOut}
    )
    defer: process.close()
    let exitCode = process.waitForExit(timeout = max(1, int(timeoutSec * 1000)))
    if exitCode != 0:
      return (-1, "")
    let resp = readFile(respFile)
    (200, resp)
  except CatchableError:
    return (-1, "")
  finally:
    try:
      if bodyFile.len > 0 and fileExists(bodyFile):
        removeFile(bodyFile)
    except CatchableError: discard
    try:
      if respFile.len > 0 and fileExists(respFile):
        removeFile(respFile)
    except CatchableError: discard

proc openAIBody(p: LlmProvider; role: BotRole; kind: LlmCallKind;
                contextJson: string): string =
  ## Builds the OpenAI chat-completion body with `tools=[...]` +
  ## `tool_choice`. The Anthropic `input_schema` translates 1:1
  ## to OpenAI `function.parameters`.
  let anth = toolSchemaFor(kind)
  let toolName = anth["name"].getStr()
  let userContent =
    "Given the following game state (JSON), call the tool to " &
    "submit your decision.\n\n" & contextJson
  let body = %*{
    "model":       p.model,
    "max_tokens":  DefaultMaxTokens,
    "temperature": DefaultTemperature,
    "messages":    [
      {"role": "system", "content": systemPromptFor(role)},
      {"role": "user",   "content": userContent}
    ],
    "tools":       [{
      "type": "function",
      "function": {
        "name":        toolName,
        "description": anth["description"].getStr(),
        "parameters":  anth["input_schema"]
      }
    }],
    "tool_choice": {"type": "function", "function": {"name": toolName}}
  }
  $body

proc openAIHeaders(p: LlmProvider): HttpHeaders =
  newHttpHeaders({
    "authorization": "Bearer " & p.apiKey,
    "content-type":  "application/json"
  })

proc openAIExtractToolUse(respBody: string): tuple[json: string;
                                                    found: bool] =
  ## OpenAI's chat-completion response shape. The first tool_call's
  ## `function.arguments` is a JSON-encoded *string* (not an object).
  ## We pass it through unchanged — `onLlmResponse` parses it.
  let parsed =
    try: parseJson(respBody)
    except CatchableError: return ("", false)
  if parsed.isNil or parsed.kind != JObject or not parsed.hasKey("choices"):
    return ("", false)
  let choices = parsed["choices"]
  if choices.kind != JArray or choices.len == 0:
    return ("", false)
  let msg = choices[0]
  if msg.kind != JObject or not msg.hasKey("message"):
    return ("", false)
  let message = msg["message"]
  if not message.hasKey("tool_calls"):
    return ("", false)
  let calls = message["tool_calls"]
  if calls.kind != JArray or calls.len == 0:
    return ("", false)
  let call = calls[0]
  if call.kind != JObject or not call.hasKey("function"):
    return ("", false)
  let fn = call["function"]
  if fn.kind != JObject or not fn.hasKey("arguments"):
    return ("", false)
  (fn["arguments"].getStr(), true)

# ---------------------------------------------------------------------------
# Retry policy
# ---------------------------------------------------------------------------

proc isRetryableStatus(code: int): bool =
  ## 5xx and 429 are retryable; everything else (404, 401, 403,
  ## 400) is fatal. Mirrors the Python wrapper's `_is_retryable`.
  code == 429 or (code >= 500 and code < 600)

# ---------------------------------------------------------------------------
# Public dispatch
# ---------------------------------------------------------------------------

proc httpPost(url: string; headers: HttpHeaders; body: string;
              timeoutSec: float): tuple[code: int; body: string] =
  ## One-shot POST helper using `std/httpclient`. A fresh client per
  ## call keeps the dispatcher simple; the LLM rate is well below
  ## one request per second so connection-reuse savings are
  ## negligible vs. the lifecycle complexity of managing a pool
  ## across the worker thread + retries.
  let timeoutMs = max(1, int(timeoutSec * 1000))
  var client = newHttpClient(timeout = timeoutMs)
  defer: client.close()
  client.headers = headers
  try:
    let resp = client.request(url, httpMethod = HttpPost, body = body)
    return (resp.code.int, resp.body)
  except TimeoutError:
    return (-1, "")
  except CatchableError:
    return (-2, "")

proc complete*(p: LlmProvider; role: BotRole; kind: LlmCallKind;
               contextJson: string): LlmCompletion =
  ## Synchronous provider call. Returns the response JSON +
  ## errored flag + measured latency. Caller (the dispatcher
  ## thread) is expected to wrap this in a worker so the bot's
  ## per-frame loop stays non-blocking.
  ##
  ## On error (HTTP non-2xx, timeout, malformed response,
  ## disabled provider) returns `errored = true` with empty
  ## `responseJson`. The Nim state machine treats that as a
  ## fallback signal exactly as it would treat any other LLM
  ## error.
  let started = epochTime()
  result.errored = true   ## default; flipped to false on success
  if p.isNil or p.kind == lpkDisabled or kind == lckNone:
    result.latencyMs = int((epochTime() - started) * 1000)
    return

  let perCallTimeout = timeoutSecFor(kind)
  # Bedrock dispatches via subprocess and doesn't share the HTTP
  # path's URL/headers structure. Branch early to keep the HTTP
  # path simple. Body construction is the same JSON shape modulo
  # the `anthropic_version` field, so the response parser is
  # `anthropicExtractToolUse` either way.
  if p.kind == lpkBedrock:
    let body = bedrockBody(p, role, kind, contextJson)
    let deadline = started + perCallTimeout
    var attempt = 0
    while attempt < LlmRetryMaxAttempts:
      let now = epochTime()
      if now >= deadline:
        break
      let attemptTimeout = deadline - now
      let (code, respBody) = bedrockInvoke(p, body, attemptTimeout)
      if code in 200 .. 299:
        let parsed = anthropicExtractToolUse(respBody)
        if parsed.found:
          result.responseJson = parsed.json
          result.errored      = false
        break
      inc attempt
      # AWS CLI failure modes — throttling, transient credential
      # issues — usually clear on retry. Conflate everything to
      # "retryable" since we can't distinguish without parsing
      # stderr.
      if attempt >= LlmRetryMaxAttempts:
        break
      let backoff = LlmRetryBackoffSecs[attempt - 1].float
      if epochTime() + backoff >= deadline:
        break
      sleep(int(backoff * 1000))
    result.latencyMs = int((epochTime() - started) * 1000)
    return

  let url =
    case p.kind
    of lpkAnthropicDirect: AnthropicMessagesUrl
    of lpkOpenAIDirect:    OpenAIChatUrl
    of lpkDisabled:        return    ## already handled above
    of lpkBedrock:         ""        ## already handled above
  let body =
    case p.kind
    of lpkAnthropicDirect: anthropicBody(p, role, kind, contextJson)
    of lpkOpenAIDirect:    openAIBody(p, role, kind, contextJson)
    of lpkDisabled:        ""
    of lpkBedrock:         ""
  let headers =
    case p.kind
    of lpkAnthropicDirect: anthropicHeaders(p)
    of lpkOpenAIDirect:    openAIHeaders(p)
    of lpkDisabled:        newHttpHeaders()
    of lpkBedrock:         newHttpHeaders()

  # Retry loop with exponential backoff, bounded by the per-call
  # timeout — mirrors Sprint 4.4's Python policy.
  let deadline = started + perCallTimeout
  var attempt = 0
  while attempt < LlmRetryMaxAttempts:
    let now = epochTime()
    if now >= deadline:
      break
    let attemptTimeout = deadline - now
    let (code, respBody) = httpPost(url, headers, body, attemptTimeout)
    if code in 200 .. 299:
      let parsed =
        case p.kind
        of lpkAnthropicDirect: anthropicExtractToolUse(respBody)
        of lpkOpenAIDirect:    openAIExtractToolUse(respBody)
        of lpkDisabled:        ("", false)
        of lpkBedrock:         ("", false)
      if parsed.found:
        result.responseJson = parsed.json
        result.errored      = false
        break
      # Successful HTTP but no tool_use block — treat as fatal
      # (model emitted text instead of calling the tool). Don't
      # retry; the bot will fall back.
      break
    let retryable = (code <= 0) or isRetryableStatus(code)
    inc attempt
    if not retryable or attempt >= LlmRetryMaxAttempts:
      break
    let backoff = LlmRetryBackoffSecs[attempt - 1].float
    if epochTime() + backoff >= deadline:
      break
    sleep(int(backoff * 1000))

  result.latencyMs = int((epochTime() - started) * 1000)


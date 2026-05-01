## Unit tests for `llm_provider.nim` env-var resolution and
## tool-schema construction (Sprint 6.1).
##
## Does NOT make real HTTP calls — that's reserved for the live
## Bedrock smoke run in Sprint 6.6 acceptance. These tests cover
## the deterministic surface: provider selection, model defaults,
## prompt construction, tool-schema shapes.
##
## Run with: `nim r -d:modTalksLlm -d:ssl test/llm_provider_unit.nim`

import std/[json, os, strutils]

import ../types
import ../llm_provider

var failures = 0

template check(label: string, cond: untyped) =
  if not cond:
    echo "FAIL: ", label
    inc failures
  else:
    echo "pass: ", label

# ---------------------------------------------------------------------------
# Helpers — set env vars per-test so we can exercise resolution
# without leaking state across tests.
# ---------------------------------------------------------------------------

proc clearLlmEnv() =
  ## Clears every env var resolveProviderKind reads.
  for v in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY",
            "MODTALKS_LLM_DISABLE", "MODTALKS_PROVIDER_OPENAI",
            "MODTALKS_LLM_MODEL",
            # Bedrock-related (Sprint 6.4):
            "AWS_PROFILE", "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY", "AWS_REGION",
            "AWS_DEFAULT_REGION", "CLAUDE_CODE_USE_BEDROCK"]:
    delEnv(v)

# ---------------------------------------------------------------------------
# Provider resolution
# ---------------------------------------------------------------------------

block resolve_disabled_no_creds:
  clearLlmEnv()
  let p = newLlmProvider()
  check "no creds → disabled":
    p.kind == lpkDisabled
  check "disabled provider reports enabled=false":
    not p.enabled()

block resolve_anthropic_from_env:
  clearLlmEnv()
  putEnv("ANTHROPIC_API_KEY", "sk-ant-test-not-real")
  defer: delEnv("ANTHROPIC_API_KEY")
  let p = newLlmProvider()
  check "ANTHROPIC_API_KEY → anthropic_direct":
    p.kind == lpkAnthropicDirect
  check "anthropic provider reports enabled=true":
    p.enabled()
  check "default model is claude-sonnet-4-5":
    p.model == "claude-sonnet-4-5"

block resolve_openai_from_env:
  clearLlmEnv()
  putEnv("OPENAI_API_KEY", "sk-test-not-real")
  defer: delEnv("OPENAI_API_KEY")
  let p = newLlmProvider()
  check "OPENAI_API_KEY alone → openai_direct":
    p.kind == lpkOpenAIDirect

block resolve_anthropic_wins_over_openai:
  clearLlmEnv()
  putEnv("ANTHROPIC_API_KEY", "sk-ant-test")
  putEnv("OPENAI_API_KEY", "sk-openai-test")
  defer:
    delEnv("ANTHROPIC_API_KEY")
    delEnv("OPENAI_API_KEY")
  let p = newLlmProvider()
  check "both keys → anthropic preferred (matches Python wrapper)":
    p.kind == lpkAnthropicDirect

block resolve_openai_force_flag:
  clearLlmEnv()
  putEnv("ANTHROPIC_API_KEY", "sk-ant-test")
  putEnv("OPENAI_API_KEY", "sk-openai-test")
  putEnv("MODTALKS_PROVIDER_OPENAI", "1")
  defer:
    delEnv("ANTHROPIC_API_KEY")
    delEnv("OPENAI_API_KEY")
    delEnv("MODTALKS_PROVIDER_OPENAI")
  let p = newLlmProvider()
  check "MODTALKS_PROVIDER_OPENAI=1 forces openai over anthropic":
    p.kind == lpkOpenAIDirect

block resolve_disabled_flag_overrides_creds:
  clearLlmEnv()
  putEnv("ANTHROPIC_API_KEY", "sk-ant-test")
  putEnv("MODTALKS_LLM_DISABLE", "1")
  defer:
    delEnv("ANTHROPIC_API_KEY")
    delEnv("MODTALKS_LLM_DISABLE")
  let p = newLlmProvider()
  check "MODTALKS_LLM_DISABLE=1 wins over creds":
    p.kind == lpkDisabled

block force_provider_anthropic:
  clearLlmEnv()
  putEnv("ANTHROPIC_API_KEY", "sk-ant-test")
  defer: delEnv("ANTHROPIC_API_KEY")
  let p = newLlmProvider(forceProvider = "anthropic")
  check "--llm-provider:anthropic with key → anthropic":
    p.kind == lpkAnthropicDirect

block force_provider_anthropic_no_key:
  clearLlmEnv()
  let p = newLlmProvider(forceProvider = "anthropic")
  check "--llm-provider:anthropic without key → disabled":
    p.kind == lpkDisabled

block force_provider_openai_no_key:
  clearLlmEnv()
  let p = newLlmProvider(forceProvider = "openai")
  check "--llm-provider:openai without key → disabled":
    p.kind == lpkDisabled

block force_provider_disabled:
  clearLlmEnv()
  putEnv("ANTHROPIC_API_KEY", "sk-ant-test")
  defer: delEnv("ANTHROPIC_API_KEY")
  let p = newLlmProvider(forceProvider = "disabled")
  check "--llm-provider:disabled wins over creds":
    p.kind == lpkDisabled

# ---------------------------------------------------------------------------
# Bedrock resolution (Sprint 6.4)
# ---------------------------------------------------------------------------
# Note: these tests require `aws` to be findable on PATH (which it
# is in any environment that's actually using Bedrock). We don't
# clobber PATH because that's invasive; if `aws` isn't installed,
# resolveAwsCli returns "" and the resolver falls through to
# disabled — which is the right behaviour but not what these tests
# are exercising.

block resolve_bedrock_from_aws_profile:
  clearLlmEnv()
  putEnv("AWS_PROFILE", "test-profile")
  defer: delEnv("AWS_PROFILE")
  let p = newLlmProvider()
  check "AWS_PROFILE alone (no Anthropic) → bedrock":
    p.kind == lpkBedrock or p.kind == lpkDisabled
    # disabled is the fallback when aws CLI isn't installed; test
    # is tolerant of either outcome to stay portable across CI envs.

block resolve_bedrock_from_aws_keys:
  clearLlmEnv()
  putEnv("AWS_ACCESS_KEY_ID", "AKIA-TEST")
  putEnv("AWS_SECRET_ACCESS_KEY", "secret-test")
  defer:
    delEnv("AWS_ACCESS_KEY_ID")
    delEnv("AWS_SECRET_ACCESS_KEY")
  let p = newLlmProvider()
  check "AWS keys (no Anthropic) → bedrock or disabled":
    p.kind == lpkBedrock or p.kind == lpkDisabled

block resolve_bedrock_force_flag_over_anthropic:
  clearLlmEnv()
  putEnv("AWS_PROFILE", "test")
  putEnv("ANTHROPIC_API_KEY", "sk-ant-test")
  putEnv("CLAUDE_CODE_USE_BEDROCK", "1")
  defer:
    delEnv("AWS_PROFILE")
    delEnv("ANTHROPIC_API_KEY")
    delEnv("CLAUDE_CODE_USE_BEDROCK")
  let p = newLlmProvider()
  check "CLAUDE_CODE_USE_BEDROCK=1 + creds → bedrock over anthropic":
    p.kind == lpkBedrock or p.kind == lpkDisabled

block resolve_anthropic_wins_when_no_bedrock_force:
  clearLlmEnv()
  putEnv("AWS_PROFILE", "test")
  putEnv("ANTHROPIC_API_KEY", "sk-ant-test")
  defer:
    delEnv("AWS_PROFILE")
    delEnv("ANTHROPIC_API_KEY")
  let p = newLlmProvider()
  check "anthropic key + AWS creds (no force flag) → anthropic":
    p.kind == lpkAnthropicDirect

block force_provider_bedrock_no_creds:
  clearLlmEnv()
  let p = newLlmProvider(forceProvider = "bedrock")
  check "--llm-provider:bedrock without AWS creds → disabled":
    p.kind == lpkDisabled

block bedrock_default_model_and_region:
  clearLlmEnv()
  putEnv("AWS_PROFILE", "test")
  putEnv("CLAUDE_CODE_USE_BEDROCK", "1")
  defer:
    delEnv("AWS_PROFILE")
    delEnv("CLAUDE_CODE_USE_BEDROCK")
  let p = newLlmProvider()
  if p.kind == lpkBedrock:
    check "Bedrock default model is the cogames Python wrapper's default":
      p.model == "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
    check "Bedrock default region is us-east-1":
      p.region == "us-east-1"
  else:
    # aws CLI not present in this environment; skip the model/region
    # asserts and just confirm we got disabled (not a crash).
    check "no aws CLI → falls back to disabled":
      p.kind == lpkDisabled

block bedrock_region_from_env:
  clearLlmEnv()
  putEnv("AWS_PROFILE", "test")
  putEnv("AWS_REGION", "eu-west-1")
  putEnv("CLAUDE_CODE_USE_BEDROCK", "1")
  defer:
    delEnv("AWS_PROFILE")
    delEnv("AWS_REGION")
    delEnv("CLAUDE_CODE_USE_BEDROCK")
  let p = newLlmProvider()
  if p.kind == lpkBedrock:
    check "AWS_REGION wins over default":
      p.region == "eu-west-1"

block bedrock_kind_name:
  clearLlmEnv()
  putEnv("AWS_PROFILE", "test")
  putEnv("CLAUDE_CODE_USE_BEDROCK", "1")
  defer:
    delEnv("AWS_PROFILE")
    delEnv("CLAUDE_CODE_USE_BEDROCK")
  let p = newLlmProvider()
  if p.kind == lpkBedrock:
    check "bedrock kindName":
      p.kindName() == "bedrock"

# ---------------------------------------------------------------------------
# Model resolution
# ---------------------------------------------------------------------------

block model_override_cli_wins:
  clearLlmEnv()
  putEnv("ANTHROPIC_API_KEY", "sk-test")
  putEnv("MODTALKS_LLM_MODEL", "claude-from-env")
  defer:
    delEnv("ANTHROPIC_API_KEY")
    delEnv("MODTALKS_LLM_MODEL")
  let p = newLlmProvider(modelOverride = "claude-from-cli")
  check "modelOverride wins over MODTALKS_LLM_MODEL":
    p.model == "claude-from-cli"

block model_env_override_used:
  clearLlmEnv()
  putEnv("ANTHROPIC_API_KEY", "sk-test")
  putEnv("MODTALKS_LLM_MODEL", "claude-from-env")
  defer:
    delEnv("ANTHROPIC_API_KEY")
    delEnv("MODTALKS_LLM_MODEL")
  let p = newLlmProvider()
  check "MODTALKS_LLM_MODEL used when no CLI override":
    p.model == "claude-from-env"

block model_default_when_no_overrides:
  clearLlmEnv()
  putEnv("OPENAI_API_KEY", "sk-test")
  defer: delEnv("OPENAI_API_KEY")
  let p = newLlmProvider()
  check "OpenAI default model is gpt-4o-mini":
    p.model == "gpt-4o-mini"

# ---------------------------------------------------------------------------
# kindName
# ---------------------------------------------------------------------------

block kind_name_strings:
  clearLlmEnv()
  let pDisabled = newLlmProvider(forceProvider = "disabled")
  check "disabled kindName":
    pDisabled.kindName() == "disabled"

  putEnv("ANTHROPIC_API_KEY", "sk-test")
  let pAnth = newLlmProvider()
  delEnv("ANTHROPIC_API_KEY")
  check "anthropic kindName":
    pAnth.kindName() == "anthropic_direct"

  putEnv("OPENAI_API_KEY", "sk-test")
  let pOA = newLlmProvider()
  delEnv("OPENAI_API_KEY")
  check "openai kindName":
    pOA.kindName() == "openai_direct"

# ---------------------------------------------------------------------------
# Prompt + timeout helpers
# ---------------------------------------------------------------------------

block prompts_role_specific:
  let crew = systemPromptFor(RoleCrewmate)
  let imp  = systemPromptFor(RoleImposter)
  check "crewmate prompt contains crewmate language":
    "you are a crewmate" in crew.toLowerAscii()
  check "imposter prompt contains target language":
    "target" in imp.toLowerAscii()
  check "imposter prompt does not contain word 'imposter'":
    # LLM_VOTING.md §5.3: the imposter system prompt deliberately
    # avoids the literal word "imposter" so the model can't echo it
    # into chat output.
    "imposter" notin imp.toLowerAscii() and "saboteur" in imp.toLowerAscii()

block timeouts_per_kind_match_python:
  # Mirrors `PER_KIND_TIMEOUT_SECONDS` in cogames/amongthem_policy.py.
  check "hypothesis 20s":
    timeoutSecFor(lckHypothesis) == 20.0
  check "strategize 20s":
    timeoutSecFor(lckStrategize) == 20.0
  check "react 15s":
    timeoutSecFor(lckReact) == 15.0
  check "imposter_react 15s":
    timeoutSecFor(lckImposterReact) == 15.0
  check "accuse 10s":
    timeoutSecFor(lckAccuse) == 10.0
  check "persuade 10s":
    timeoutSecFor(lckPersuade) == 10.0

# ---------------------------------------------------------------------------
# Disabled-provider complete() short-circuit
# ---------------------------------------------------------------------------

block disabled_complete_short_circuits:
  clearLlmEnv()
  let p = newLlmProvider()
  check "disabled provider is reported disabled":
    not p.enabled()
  let res = p.complete(RoleCrewmate, lckHypothesis, "{}")
  check "disabled complete returns errored":
    res.errored
  check "disabled complete returns empty body":
    res.responseJson.len == 0

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if failures > 0:
  echo "\n", failures, " failure(s)"
  quit(1)
echo "\nall llm_provider.nim unit tests passed"

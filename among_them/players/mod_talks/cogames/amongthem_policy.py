"""CoGames AmongThem policy wrapper around the Nim mod_talks shared library.

This module is the entry point that the CoGames tournament worker imports as
``amongthem_policy.AmongThemPolicy``. It:

    1. Locates the ``mod_talks`` source tree (works in both the in-repo source
       layout and the flattened bundle layout that ``cogames ship`` produces).
    2. Imports ``build_modulabot`` from that tree and compiles
       ``libmodulabot.{dylib,so,dll}`` on demand. The tournament image already
       has Nim and ``nimby`` installed (see
       ``packages/cogames/Dockerfile.episode_runner``), so the build runs
       inside the worker without any cross-compilation.
    3. Loads the library through ``ctypes`` and routes the BitWorld
       AmongThem ``step_batch`` interface to ``modulabot_step_batch``.
    4. Wires up the LLM voting layer (LLM_VOTING.md). Each frame:
         a. After the Nim step, drain ``modulabot_take_chat`` per agent and
            surface the result to the game via ``Action(talk=...)``.
         b. Poll ``modulabot_take_llm_request`` — when Nim has prepared a
            context, submit the LLM call to a background worker pool
            (Sprint 4.1) so 8 agents don't serialise behind a single
            blocking provider call. Completed futures are gathered at the
            end of ``step_batch`` (with a wall-clock deadline) and their
            JSON responses fed back through ``modulabot_set_llm_response``.
       The LLM layer is enabled only if the library was built with
       ``-d:modTalksLlm`` (Nim-side gate) AND a provider client was
       constructed successfully (Python-side gate). Otherwise every LLM
       FFI call no-ops and the bot runs as rule-based modulabot.

Credential plumbing (cogames tournaments):
    - Tournament runner injects env vars from ``cogames upload --secret-env``
      into the policy subprocess. See ``packages/cogames/POLICY_SECRETS.md``.
    - Bedrock path: set ``AWS_ACCESS_KEY_ID`` + ``AWS_SECRET_ACCESS_KEY`` +
      ``AWS_REGION`` (or ``AWS_DEFAULT_REGION``). ``CLAUDE_CODE_USE_BEDROCK=1``
      forces Bedrock even if an Anthropic key is also present.
    - Direct API fallback: ``ANTHROPIC_API_KEY``.
    - ``MODTALKS_LLM_MODEL`` overrides the model id.
    - ``MODTALKS_LLM_DISABLE=1`` hard-disables the LLM layer even if creds
      are present (useful for A/B tests).
    - ``MODTALKS_LLM_DEADLINE_SECONDS`` (Sprint 4.1) caps how long
      ``step_batch`` will wait for any in-flight provider future to
      complete during gather; over-deadline futures are abandoned and
      re-checked on the next step. Default 12.0 s, slightly under the
      typical voting-screen window.

Matches ``among_them/players/modulabot/cogames/amongthem_policy.py`` in
wire structure but adds the chat+LLM plumbing. Keep both in lockstep when
the BitWorld policy interface or Nim FFI changes.
"""

from __future__ import annotations

import concurrent.futures
import ctypes
import importlib
import importlib.util
import json
import logging
import os
import platform
import sys
import threading
from pathlib import Path
from types import ModuleType
from typing import Any

import numpy as np

from mettagrid.bitworld import (
    BITWORLD_ACTION_COUNT,
    BITWORLD_ACTION_NAMES,
    SCREEN_HEIGHT,
    SCREEN_WIDTH,
)
from mettagrid.policy.policy import AgentPolicy, MultiAgentPolicy
from mettagrid.policy.policy_env_interface import PolicyEnvInterface
from mettagrid.simulator import Action, AgentObservation

logger = logging.getLogger(__name__)

# --- Model defaults ---------------------------------------------------------

# Mirrors `cogames-agents/src/cogames_agents/policy/bitworld_among_them.py`
# constants so both wrappers target the same stack. If these change, update
# both places — there is no single source of truth for provider metadata
# inside the mod_talks repo (we intentionally do not depend on cogames-agents).
DEFAULT_BEDROCK_MODEL = "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-4-5"
DEFAULT_MAX_TOKENS = 1024
DEFAULT_TEMPERATURE = 0.5
# Provider HTTP timeout in seconds. We block the frame while the call is in
# flight, so this must stay well under the tournament frame budget. The
# BitWorld action loop runs at ~24 fps but the server tolerates per-frame
# latency variance; 20 s matches the hypothesis/strategy budget from
# LLM_VOTING.md §9 plus one retry head room. If the provider is slow we'd
# rather timeout and fall back than wedge the bot.
DEFAULT_TIMEOUT_SECONDS = 15.0

# Sprint 4.2 — per-call-kind timeouts, in seconds. Tighter than
# DEFAULT_TIMEOUT_SECONDS to keep stage transitions responsive within the
# game's voting window. LLM_VOTING.md §9 specifies these budgets.
# The forming-stage calls (hypothesis, strategize) get the longest budget
# because they fire once per meeting and gate everything that follows;
# accuse / persuade are short responses with tight budgets; react /
# imposter_react share a budget that fits inside the chat-cooldown gap.
PER_KIND_TIMEOUT_SECONDS: dict[str, float] = {
    "hypothesis":     20.0,
    "strategize":     20.0,
    "react":          15.0,
    "imposter_react": 15.0,
    "accuse":         10.0,
    "persuade":       10.0,
}

# Sprint 4.4 — retry policy. Three attempts total (initial + 2 retries)
# with exponential backoff. Retry only on errors that have a real
# chance of resolving on a second attempt: rate limits, 5xx, network
# timeouts, transient connection errors. 4xx auth / validation errors
# are not retried.
_MAX_RETRIES = 2
_RETRY_BACKOFF_SECONDS: tuple[float, ...] = (0.5, 1.5)
_RETRYABLE_EXC_NAMES: frozenset[str] = frozenset({
    "RateLimitError",
    "APITimeoutError",
    "APIConnectionError",
    "InternalServerError",
    "ServiceUnavailableError",
})


def _is_retryable(exc: Exception) -> bool:
    """Returns True when the exception is one we should retry.

    Done by exception class name so the helper doesn't import the
    Anthropic SDK at module load time (the LLM layer must be optional).
    Also catches a generic ``APIStatusError`` with status_code in 5xx.
    """
    name = type(exc).__name__
    if name in _RETRYABLE_EXC_NAMES:
        return True
    status = getattr(exc, "status_code", None)
    if isinstance(status, int) and 500 <= status < 600:
        return True
    return False

# Sprint 4.3 — Anthropic tool-use schemas. Registering these as tools
# with `tool_choice={"type":"tool","name":...}` forces the model to
# emit a structured response that conforms to the schema, eliminating
# the parse-failure mode that the schema-in-prompt approach was
# tolerating. The Nim-side parser still validates field types and
# values (it has to, the LLM can still pick a non-living-player color),
# but malformed JSON is no longer a recoverable case.
#
# Schema shapes mirror LLM_VOTING.md §5.4 verbatim. The "additional"
# constraint (additionalProperties=false) is intentionally NOT set —
# Anthropic's tool-use is more lenient about extra fields than strict
# JSON-schema validators, and the Nim parser tolerates them anyway.
_LLM_TOOL_DEFINITIONS: dict[str, dict[str, Any]] = {
    "hypothesis": {
        "name": "submit_hypothesis",
        "description": (
            "Submit your suspect-likelihood ranking, confidence, and "
            "an opening statement for the current meeting based on "
            "observed evidence. The opening_statement is a short chat "
            "message summarizing your read of the situation."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "suspects": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "color": {"type": "string"},
                            "likelihood": {"type": "number"},
                            "reasoning": {"type": "string"},
                        },
                        "required": ["color", "likelihood", "reasoning"],
                    },
                },
                "confidence": {
                    "type": "string",
                    "enum": ["high", "medium", "low"],
                },
                "key_evidence": {
                    "type": "array",
                    "items": {"type": "string"},
                },
                "opening_statement": {
                    "type": ["string", "null"],
                },
            },
            "required": [
                "suspects", "confidence", "key_evidence",
                "opening_statement",
            ],
        },
    },
    "accuse": {
        "name": "submit_accusation",
        "description": (
            "Submit a single chat message naming the top suspect "
            "and citing evidence."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "chat": {"type": "string"},
            },
            "required": ["chat"],
        },
    },
    "react": {
        "name": "submit_react",
        "description": (
            "Update your hypothesis based on chat lines from other "
            "players and decide whether to speak, ask, or stay silent."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "suspects": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "color": {"type": "string"},
                            "likelihood": {"type": "number"},
                            "reasoning": {"type": "string"},
                        },
                        "required": ["color", "likelihood", "reasoning"],
                    },
                },
                "confidence": {
                    "type": "string",
                    "enum": ["high", "medium", "low"],
                },
                "action": {
                    "type": "string",
                    "enum": ["speak", "ask", "silent"],
                },
                "chat": {
                    "type": ["string", "null"],
                },
            },
            "required": ["confidence", "action"],
        },
    },
    "strategize": {
        "name": "submit_strategy",
        "description": (
            "Decide which non-safe player to target for ejection, "
            "what strategy to use, when to speak, and an optional "
            "opening message."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "best_target": {"type": "string"},
                "strategy": {
                    "type": "string",
                    "enum": ["bandwagon", "preemptive", "deflect"],
                },
                "timing": {
                    "type": "string",
                    "enum": ["early", "mid", "late"],
                },
                "reasoning": {"type": "string"},
                "initial_chat": {
                    "type": ["string", "null"],
                },
            },
            "required": ["best_target", "strategy", "timing", "reasoning"],
        },
    },
    "imposter_react": {
        "name": "submit_imposter_react",
        "description": (
            "Decide whether to corroborate, deflect, accuse, or stay "
            "silent based on the conversation, and provide chat if "
            "speaking."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["corroborate", "deflect", "accuse", "silent"],
                },
                "chat": {
                    "type": ["string", "null"],
                },
                "reasoning": {"type": "string"},
            },
            "required": ["action", "reasoning"],
        },
    },
    "persuade": {
        "name": "submit_persuasion",
        "description": (
            "Submit a short persuasion message to convince other "
            "players to vote for the named suspect."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "chat": {"type": "string"},
            },
            "required": ["chat"],
        },
    },
}

# Hard caps on FFI buffer sizes. Must fit the largest expected context
# JSON + any future schema growth. Grows cheaply; shrinks require
# re-thinking the truncation rule in `llm.nim:buildContext`.
_LLM_KIND_BUFFER_SIZE = 64
_LLM_CONTEXT_BUFFER_SIZE = 16384
_CHAT_BUFFER_SIZE = 256

# Nim-side FFI return values for `modulabot_role`. Keep in sync with
# ffi/lib.nim.
_ROLE_CREWMATE = 1
_ROLE_IMPOSTER = 2

# LLM_VOTING.md system prompts verbatim (§5.1-§5.3). Kept inline rather
# than in a separate file so the bundle ships with only the .py.
_SYSTEM_PROMPT_BASE = (
    "You are a player in a social deduction game. Players perform tasks on "
    "a spaceship. One or more players are secretly saboteurs. When a body "
    "is found or an emergency button is pressed, all players vote to eject "
    "someone.\n\n"
    "Your job is to reason carefully about the evidence you have observed "
    "and communicate naturally with other players. Be concise — chat "
    "messages should be one or two short sentences at most. Use specific "
    "evidence (who you saw where, when) rather than vague accusations. Do "
    "not reveal that you are an AI.\n\n"
    "Respond ONLY with valid JSON matching the response_schema in the user "
    "message. Do not include any text outside the JSON object."
)
_SYSTEM_PROMPT_CREWMATE = (
    "\n\nYou are a crewmate — you are not a saboteur. Reason honestly. If "
    "you have strong evidence against someone, say so clearly. If you are "
    "uncertain, say so and ask others for information. Do not accuse "
    "randomly. Base every accusation on something specific you observed."
)
_SYSTEM_PROMPT_IMPOSTER = (
    "\n\nYou are trying to avoid ejection and get an innocent player (your "
    "target) ejected instead. You have a list of safe_colors allies who "
    "you must never accuse, vote against, or take any action that would "
    "draw suspicion toward them.\n\n"
    "Your core constraints:\n"
    "1. Every statement you make must be consistent with the full_chat_log "
    "you are given. Read every prior message carefully and do not "
    "contradict any claim that has already been made — by you or by anyone "
    "else — unless you are explicitly deflecting a false accusation "
    "against yourself.\n"
    "2. Only claim to have seen or been somewhere that is in your "
    "location history. Do not fabricate locations.\n"
    "3. Never name or hint at any safe_colors player as suspicious.\n"
    "4. Sound like a natural player: vary phrasing, react to specific "
    "things others said, and don't over-explain.\n\n"
    "When asked to strategize: assess the full situation and decide the "
    "best target (a non-safe player who can be plausibly framed), the "
    "right strategy (bandwagon, preemptive accusation, or deflection if "
    "you are under suspicion), and the right timing.\n\n"
    "When asked to react: choose the action (corroborate, deflect, "
    "accuse, or stay silent) that best advances ejecting your target "
    "while keeping you safe. Prioritize staying silent over speaking if "
    "you cannot say something consistent with the chat log."
)


def _find_modulabot_dir() -> Path:
    """Returns the directory containing ``build_modulabot.py``.

    Handles two layouts:

    * **Source layout.** This file lives at
      ``among_them/players/mod_talks/cogames/amongthem_policy.py``. The
      mod_talks directory is one level up.
    * **Bundle layout.** ``cogames ship`` flattens this file to the bundle
      root because its basename matches the policy module name. Sibling
      ``-f`` includes preserve their relative paths, so the mod_talks tree
      ends up at ``<bundle_root>/among_them/players/mod_talks``.
    """
    here = Path(__file__).resolve().parent
    candidates = [
        here.parent,                                         # source layout
        here / "among_them" / "players" / "mod_talks",       # bundle layout
        here.parent / "among_them" / "players" / "mod_talks",
        # Legacy fallback: in case a bundle still uses the pre-fork name.
        here / "among_them" / "players" / "modulabot",
        here.parent / "among_them" / "players" / "modulabot",
    ]
    for candidate in candidates:
        if (candidate / "build_modulabot.py").is_file():
            return candidate
    searched = "\n  ".join(str(c) for c in candidates)
    raise RuntimeError(
        "Could not locate mod_talks source directory. Searched:\n  " + searched
    )


def _import_build_modulabot(modulabot_dir: Path) -> ModuleType:
    module_name = "_modulabot_build_modulabot"
    cached = sys.modules.get(module_name)
    if cached is not None:
        return cached
    spec = importlib.util.spec_from_file_location(
        module_name, modulabot_dir / "build_modulabot.py"
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(
            f"Could not load build_modulabot.py from {modulabot_dir}"
        )
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def _env_flag_enabled(name: str) -> bool:
    return os.getenv(name, "").lower() in {"1", "true", "yes", "on"}


def _parse_trace_meta(raw: str) -> str:
    """Converts a ``K=V[,K=V]*`` metadata string to a JSON object string.

    Mirrors the CLI runner's ``--trace-meta`` handling so both paths
    produce identically-shaped ``manifest.harness_meta``. Returns
    ``""`` if the input doesn't look like K=V pairs; the Nim side
    then falls back to the ``{"raw": ...}`` wrapper.
    """
    meta: dict[str, str] = {}
    for chunk in raw.split(","):
        piece = chunk.strip()
        if not piece or "=" not in piece:
            return ""
        key, _, value = piece.partition("=")
        key = key.strip()
        value = value.strip()
        if not key:
            return ""
        meta[key] = value
    if not meta:
        return ""
    return json.dumps(meta)


# ---------------------------------------------------------------------------
# LLM controller
# ---------------------------------------------------------------------------


class _AnthropicController:
    """Blocking wrapper around ``anthropic.Anthropic`` /
    ``anthropic.AnthropicBedrock``.

    Single-shot: one call per ``complete()`` invocation. The official
    Anthropic SDK is thread-safe; concurrency is now driven by the
    parent ``AmongThemPolicy``'s ``ThreadPoolExecutor`` (Sprint 4.1)
    so this class no longer holds a serialising lock. Each provider
    call blocks the worker thread for its duration; the main thread
    only blocks once at the end of ``step_batch`` while gathering
    completed futures.

    Sprint 5.3 — kept as the default provider. An OpenAI fallback
    sibling (``_OpenAIController``) lives below for environments
    without Anthropic credentials. The selector lives in
    ``_build_llm_controller``.
    """

    def __init__(self) -> None:
        self._client: Any = None
        self._model: str = ""
        self._using_bedrock: bool = False
        self._init_client()

    @property
    def enabled(self) -> bool:
        return self._client is not None

    def _init_client(self) -> None:
        if _env_flag_enabled("MODTALKS_LLM_DISABLE"):
            logger.info("mod_talks LLM layer disabled via MODTALKS_LLM_DISABLE")
            return
        try:
            anthropic = importlib.import_module("anthropic")
        except ImportError:
            logger.warning(
                "mod_talks LLM layer unavailable: `anthropic` package not "
                "installed. Install it or set MODTALKS_LLM_DISABLE=1 to "
                "silence this warning."
            )
            return

        aws_has_keys = bool(os.getenv("AWS_ACCESS_KEY_ID")) and bool(
            os.getenv("AWS_SECRET_ACCESS_KEY")
        )
        aws_has_profile = bool(os.getenv("AWS_PROFILE"))
        forced_bedrock = _env_flag_enabled("CLAUDE_CODE_USE_BEDROCK")
        anth_key = os.getenv("ANTHROPIC_API_KEY")

        # Preference order (matching cogames-agents' cyborg policy):
        #   1. CLAUDE_CODE_USE_BEDROCK=1 forces Bedrock.
        #   2. No ANTHROPIC_API_KEY + any AWS creds → Bedrock.
        #   3. ANTHROPIC_API_KEY → direct Anthropic.
        #   4. AWS creds but also Anthropic key → direct Anthropic (simpler).
        use_bedrock = forced_bedrock or (
            not anth_key and (aws_has_keys or aws_has_profile)
        )

        self._model = os.getenv("MODTALKS_LLM_MODEL", "").strip()
        try:
            if use_bedrock:
                region = os.getenv("AWS_REGION") or os.getenv(
                    "AWS_DEFAULT_REGION"
                ) or "us-east-1"
                kwargs: dict[str, Any] = {"aws_region": region}
                # AnthropicBedrock uses boto3 under the hood; it reads AWS
                # creds from the standard chain. We pass profile explicitly
                # when set because the boto3 profile resolution order
                # surprises people (and the runner will only have env-var
                # creds, not a profile).
                if aws_has_profile:
                    kwargs["aws_profile"] = os.getenv("AWS_PROFILE")
                self._client = anthropic.AnthropicBedrock(**kwargs)
                if not self._model:
                    self._model = DEFAULT_BEDROCK_MODEL
                self._using_bedrock = True
                logger.info(
                    "mod_talks LLM via AnthropicBedrock region=%s model=%s",
                    region, self._model,
                )
                return
            if anth_key:
                self._client = anthropic.Anthropic(api_key=anth_key)
                if not self._model:
                    self._model = DEFAULT_ANTHROPIC_MODEL
                self._using_bedrock = False
                logger.info(
                    "mod_talks LLM via Anthropic direct model=%s", self._model
                )
                return
            logger.warning(
                "mod_talks LLM layer disabled: no ANTHROPIC_API_KEY and no "
                "AWS credentials in env. Set one (or MODTALKS_LLM_DISABLE=1)."
            )
        except Exception:  # pragma: no cover - depends on runtime env
            logger.exception(
                "mod_talks LLM controller init failed; running without LLM"
            )
            self._client = None

    def _system_prompt(self, role: int) -> str:
        if role == _ROLE_IMPOSTER:
            return _SYSTEM_PROMPT_BASE + _SYSTEM_PROMPT_IMPOSTER
        return _SYSTEM_PROMPT_BASE + _SYSTEM_PROMPT_CREWMATE

    def complete(
        self, *, role: int, kind: str, context_json: str,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    ) -> str:
        """Sends ``context_json`` to the provider and returns the
        response as a JSON string. The Nim parser feeds this into
        ``onLlmResponse`` exactly as if it had come from the
        schema-in-prompt path; downstream behaviour is identical
        modulo the elimination of malformed-JSON parse errors.

        Thread-safe: callers may invoke from multiple worker threads
        concurrently (Sprint 4.1). The Anthropic SDK serialises
        per-connection internally; on Bedrock the boto3 layer pools
        connections per region.

        Sprint 4.2 — ``timeout_seconds`` is the per-call HTTP timeout.

        Sprint 4.3 — when ``kind`` matches a registered tool in
        ``_LLM_TOOL_DEFINITIONS``, the call uses Anthropic tool-use
        with ``tool_choice`` forcing that tool. The model returns a
        ``tool_use`` content block whose ``input`` field is a parsed
        dict; we serialize that back to JSON for Nim. When ``kind``
        is unknown we fall back to schema-in-prompt parsing
        (legacy path).

        Sprint 4.4 — retryable errors (rate limits, 5xx, connection
        timeouts) are retried up to ``_MAX_RETRIES`` times with
        exponential backoff (500 ms → 1500 ms → 4500 ms). Total
        elapsed time is bounded by ``timeout_seconds`` to keep the
        outer gather pass on schedule. 4xx auth / validation errors
        are NOT retried.
        """
        if self._client is None:
            return ""
        tool = _LLM_TOOL_DEFINITIONS.get(kind)
        kwargs: dict[str, Any] = dict(
            model=self._model,
            max_tokens=DEFAULT_MAX_TOKENS,
            temperature=DEFAULT_TEMPERATURE,
            timeout=timeout_seconds,
            system=self._system_prompt(role),
            messages=[
                {
                    "role": "user",
                    "content": (
                        "Given the following game state "
                        "(JSON), call the tool to submit your "
                        "decision.\n\n"
                        + context_json
                    ),
                }
            ],
        )
        if tool is not None:
            kwargs["tools"] = [tool]
            kwargs["tool_choice"] = {
                "type": "tool",
                "name": tool["name"],
            }
        import time
        start = time.time()
        deadline = start + timeout_seconds
        attempt = 0
        last_exc: Exception | None = None
        while attempt <= _MAX_RETRIES:
            try:
                resp = self._client.messages.create(**kwargs)
                break
            except Exception as exc:  # noqa: BLE001
                last_exc = exc
                if not _is_retryable(exc) or attempt >= _MAX_RETRIES:
                    logger.exception(
                        "mod_talks LLM call raised; "
                        "attempt=%d retryable=%s — falling back",
                        attempt, _is_retryable(exc),
                    )
                    return ""
                backoff = _RETRY_BACKOFF_SECONDS[attempt]
                if time.time() + backoff >= deadline:
                    # Not enough budget left to retry meaningfully.
                    logger.warning(
                        "mod_talks LLM retryable error but no time "
                        "left in budget (attempt=%d, backoff=%.2fs); "
                        "abandoning",
                        attempt, backoff,
                    )
                    return ""
                logger.info(
                    "mod_talks LLM retryable error attempt=%d: %s "
                    "(backoff %.2fs)",
                    attempt, exc.__class__.__name__, backoff,
                )
                time.sleep(backoff)
                attempt += 1
        else:  # pragma: no cover - exhausted while True clause
            return ""
        # Tool-use response: pull the first tool_use block's input
        # field and serialize it back to JSON. This is structurally
        # equivalent to a well-formed prompt-mode response and the
        # Nim parser is shape-agnostic.
        if tool is not None:
            for block in getattr(resp, "content", []) or []:
                if getattr(block, "type", None) == "tool_use":
                    payload = getattr(block, "input", None)
                    if payload is not None:
                        try:
                            return json.dumps(payload)
                        except (TypeError, ValueError):
                            logger.warning(
                                "mod_talks tool_use input not "
                                "JSON-serializable; falling back to "
                                "text extraction"
                            )
                            break
        # Fallback: text extraction (legacy schema-in-prompt path or
        # tool-use response that didn't include the expected block).
        text_parts: list[str] = []
        for block in getattr(resp, "content", []) or []:
            t = getattr(block, "text", None)
            if isinstance(t, str):
                text_parts.append(t)
        return _strip_markdown_code_fence("".join(text_parts))


class _OpenAIController:
    """Sprint 5.3 — stub OpenAI provider for environments without
    Anthropic credentials.

    Initialised when ``OPENAI_API_KEY`` is set AND no Anthropic
    credentials are present. Mirrors the ``_AnthropicController``
    interface (``enabled`` property, ``complete(role, kind,
    context_json, timeout_seconds) -> str``) so it slots into the
    same dispatch path. NOT yet live-tested in a tournament run
    because we don't have OpenAI creds in the lobby; ship as
    structural support and turn on when the keys arrive.

    Tool-use mapping: OpenAI uses ``tools=[{"type":"function",
    "function":{...}}]`` which is structurally similar to the
    Anthropic shape. The translation lives in ``_complete_with_tool``.
    """

    def __init__(self) -> None:
        self._client: Any = None
        self._model: str = ""
        self._init_client()

    @property
    def enabled(self) -> bool:
        return self._client is not None

    def _init_client(self) -> None:
        if _env_flag_enabled("MODTALKS_LLM_DISABLE"):
            return
        try:
            openai = importlib.import_module("openai")
        except ImportError:
            logger.info(
                "OpenAI provider unavailable: `openai` package not installed"
            )
            return
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            return
        try:
            self._client = openai.OpenAI(api_key=api_key)
            self._model = os.getenv("MODTALKS_LLM_MODEL", "").strip() or \
                          "gpt-4o-mini"
            logger.info("mod_talks LLM via OpenAI model=%s", self._model)
        except Exception:  # pragma: no cover
            logger.exception("OpenAI controller init failed")
            self._client = None

    def _system_prompt(self, role: int) -> str:
        if role == _ROLE_IMPOSTER:
            return _SYSTEM_PROMPT_BASE + _SYSTEM_PROMPT_IMPOSTER
        return _SYSTEM_PROMPT_BASE + _SYSTEM_PROMPT_CREWMATE

    def complete(
        self, *, role: int, kind: str, context_json: str,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    ) -> str:
        if self._client is None:
            return ""
        anth_tool = _LLM_TOOL_DEFINITIONS.get(kind)
        if anth_tool is None:
            return ""  # OpenAI path requires tool-use; bail otherwise
        # Translate Anthropic tool shape → OpenAI function shape.
        tools = [{
            "type": "function",
            "function": {
                "name": anth_tool["name"],
                "description": anth_tool["description"],
                "parameters": anth_tool["input_schema"],
            },
        }]
        messages = [
            {"role": "system", "content": self._system_prompt(role)},
            {"role": "user", "content":
                "Given the following game state (JSON), call the tool to "
                "submit your decision.\n\n" + context_json},
        ]
        try:
            resp = self._client.chat.completions.create(
                model=self._model,
                messages=messages,
                tools=tools,
                tool_choice={"type": "function",
                             "function": {"name": anth_tool["name"]}},
                temperature=DEFAULT_TEMPERATURE,
                max_tokens=DEFAULT_MAX_TOKENS,
                timeout=timeout_seconds,
            )
        except Exception:  # pragma: no cover
            logger.exception("OpenAI call raised")
            return ""
        try:
            choice = resp.choices[0]
            tool_calls = getattr(choice.message, "tool_calls", None) or []
            if tool_calls:
                return tool_calls[0].function.arguments
        except (IndexError, AttributeError):
            pass
        return getattr(getattr(resp.choices[0], "message", None),
                       "content", "") or ""


def _build_llm_controller() -> Any:
    """Selects the LLM provider controller based on env vars.

    Preference order (Sprint 5.3):
      1. Anthropic (Bedrock or direct) — default; handles the production
         tournament path.
      2. OpenAI — fallback when ANTHROPIC_API_KEY is unset and
         OPENAI_API_KEY is set.

    Returns the first enabled controller, or ``_AnthropicController``
    (which will report ``enabled=False`` if creds are missing) so the
    rest of the policy can rely on a stable interface.
    """
    if _env_flag_enabled("MODTALKS_PROVIDER_OPENAI"):
        c = _OpenAIController()
        if c.enabled:
            return c
    anth = _AnthropicController()
    if anth.enabled:
        return anth
    # Fall through to OpenAI if Anthropic init failed but OpenAI is
    # configured (rare, but supports environments where Anthropic creds
    # didn't load cleanly).
    if os.getenv("OPENAI_API_KEY"):
        c = _OpenAIController()
        if c.enabled:
            return c
    return anth  # disabled controller — Nim layer will stay rule-based


def _strip_markdown_code_fence(text: str) -> str:
    """Extracts a JSON object from model output, tolerating prose around it.

    The model is instructed to reply with JSON only but sometimes
    wraps it in ```json fences or prefaces it with a short
    explanation like "Here is the response:\\n{...}". We look for the
    first balanced ``{...}`` span and return that. Falls back to
    whitespace-stripped text if no JSON object is detected (caller
    will surface the parse error).
    """
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.removeprefix("```")
        if stripped.startswith("json"):
            stripped = stripped[4:]
        stripped = stripped.strip()
        if stripped.endswith("```"):
            stripped = stripped[:-3]
        stripped = stripped.strip()

    # Already starts with { -> use as-is.
    if stripped.startswith("{"):
        return stripped

    # Scan for the first balanced JSON object. Handles responses like
    # "Based on the evidence, here is my analysis: {...}".
    depth = 0
    start = -1
    in_str = False
    escape = False
    for i, ch in enumerate(stripped):
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            continue
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start >= 0:
                return stripped[start : i + 1]
    return stripped


# ---------------------------------------------------------------------------
# Policy
# ---------------------------------------------------------------------------


class _LlmFuture:
    """Bookkeeping for one in-flight provider call (Sprint 4.1).

    Holds the call kind so the gather pass can route the response
    back to the right Nim slot via ``modulabot_set_llm_response``,
    plus the dispatch wall-clock so we can compute observed latency
    for the trace and for stale-detection in Sprint 4.2.
    """

    __slots__ = ("kind", "future", "dispatched_at_unix")

    def __init__(
        self,
        kind: str,
        future: concurrent.futures.Future,
        dispatched_at_unix: float,
    ):
        self.kind = kind
        self.future = future
        self.dispatched_at_unix = dispatched_at_unix


class _AmongThemAgentPolicy(AgentPolicy):
    """Single-agent wrapper around the batched Nim policy + LLM/chat."""

    def __init__(
        self,
        policy_env_info: PolicyEnvInterface,
        parent: "AmongThemPolicy",
        agent_id: int,
    ):
        super().__init__(policy_env_info)
        self._parent = parent
        self._agent_id = agent_id

    def step(self, obs: AgentObservation) -> Action:
        del obs
        action_index = self._parent.step_agent(self._agent_id)
        talk = self._parent.take_chat(self._agent_id)
        name = self._policy_env_info.action_names[action_index]
        if talk:
            return Action(name=name, talk=talk)
        return Action(name=name)


class AmongThemPolicy(MultiAgentPolicy):
    """Runs ``mod_talks`` through a compiled shared library, with LLM
    meeting chat + voting driven by a provider call per pending request.

    Required action space matches the BitWorld AmongThem trainable action
    set (``BITWORLD_ACTION_NAMES``). The Nim side enforces the same table at
    ``among_them/players/mod_talks/ffi/lib.nim:TrainableMasks``.
    """

    short_names = ["amongthem_modulabot", "amongthem_mod_talks"]

    def __init__(self, policy_env_info: PolicyEnvInterface, device: str = "cpu"):
        super().__init__(policy_env_info, device=device)
        if tuple(policy_env_info.action_names) != BITWORLD_ACTION_NAMES:
            raise ValueError(
                "AmongThemPolicy requires the "
                f"{BITWORLD_ACTION_COUNT}-action BitWorld action space."
            )
        self._modulabot_dir = _find_modulabot_dir()
        self._build = _import_build_modulabot(self._modulabot_dir)
        self._lib = self._load_library()
        self._bind_ffi(self._lib)
        # Arm the Nim-side trace writer BEFORE modulabot_new_policy, so
        # each agent's Bot gets its own TraceWriter attached at
        # initBot-time. No-op if MODULABOT_TRACE_DIR is unset. This is
        # the only place in the FFI path that plumbs tracing; the CLI
        # runner has its own path.
        self._arm_trace_if_requested()
        self._num_agents = max(1, int(policy_env_info.num_agents))
        self._handle = int(self._lib.modulabot_new_policy(self._num_agents))
        self._last_actions = np.zeros(self._num_agents, dtype=np.int32)
        self._pending_chat: dict[int, str] = {}
        self._llm = _build_llm_controller()
        self._llm_enabled_agents: set[int] = set()
        # Pre-allocate FFI buffers once. All ctypes calls are on the
        # MultiAgentPolicy main thread so we can reuse them.
        self._kind_buf = ctypes.create_string_buffer(_LLM_KIND_BUFFER_SIZE)
        self._ctx_buf = ctypes.create_string_buffer(_LLM_CONTEXT_BUFFER_SIZE)
        self._chat_buf = ctypes.create_string_buffer(_CHAT_BUFFER_SIZE)
        # Sprint 4.1 — concurrent dispatch. A single shared
        # ThreadPoolExecutor handles all in-flight provider calls.
        # `_inflight` maps agent_id → currently-dispatched future,
        # carrying the call kind so we can route the result back.
        # The executor is created lazily on first LLM use so non-LLM
        # builds don't pay the thread-pool startup cost.
        self._executor: concurrent.futures.ThreadPoolExecutor | None = None
        self._inflight: dict[int, _LlmFuture] = {}
        try:
            self._gather_deadline_seconds = float(
                os.getenv("MODTALKS_LLM_DEADLINE_SECONDS", "12.0")
            )
        except ValueError:
            self._gather_deadline_seconds = 12.0

    def _arm_trace_if_requested(self) -> None:
        """Calls ``modulabot_init_trace`` when ``MODULABOT_TRACE_DIR`` is set.

        Mirrors the CLI runner's env-var convention so both paths honor
        the same configuration. Silent no-op when the env var is unset
        or when the Nim-side call returns non-zero.
        """
        root = os.getenv("MODULABOT_TRACE_DIR", "").strip()
        if not root:
            return
        level_name = os.getenv("MODULABOT_TRACE_LEVEL", "decisions").strip().lower()
        level_map = {"off": 0, "events": 1, "decisions": 2, "full": 3}
        level = level_map.get(level_name, 2)
        try:
            snapshot_period = int(
                os.getenv("MODULABOT_TRACE_SNAPSHOT_PERIOD", "120")
            )
        except ValueError:
            snapshot_period = 120
        # Frames dump is optional in FFI traces — default off to keep
        # disk usage bounded; the harness can flip via env var.
        capture_frames = _env_flag_enabled("MODULABOT_TRACE_FRAMES_DUMP")
        harness_meta = os.getenv("MODULABOT_TRACE_META", "").strip()
        # `MODULABOT_TRACE_META` is conventionally a K=V[,K=V]* string;
        # convert to JSON object so it merges cleanly into
        # manifest.harness_meta. Falls through to raw-string fallback
        # in Nim if parsing fails.
        meta_json = _parse_trace_meta(harness_meta) if harness_meta else ""
        rc = int(
            self._lib.modulabot_init_trace(
                root.encode("utf-8"),
                ctypes.c_int(level),
                ctypes.c_int(snapshot_period),
                ctypes.c_int(1 if capture_frames else 0),
                meta_json.encode("utf-8") if meta_json else None,
            )
        )
        if rc != 0:
            logger.warning(
                "modulabot_init_trace returned %d for root=%s; trace disabled",
                rc,
                root,
            )
        else:
            logger.info(
                "mod_talks trace armed: root=%s level=%s period=%d frames=%s",
                root,
                level_name,
                snapshot_period,
                capture_frames,
            )

    # --- agent policy construction -----------------------------------------

    def agent_policy(self, agent_id: int) -> AgentPolicy:
        return _AmongThemAgentPolicy(self._policy_env_info, self, agent_id)

    # --- batched step (the hot path) ---------------------------------------

    def step_batch(
        self,
        raw_observations: np.ndarray,
        raw_actions: np.ndarray,
    ) -> None:
        observations = self._normalize_observations(raw_observations)
        batch_size = observations.shape[0]
        self._ensure_agent_count(batch_size)
        agent_ids = np.arange(batch_size, dtype=np.int32)
        frame_advances = np.ones(batch_size, dtype=np.int32)
        actions = np.zeros(batch_size, dtype=np.int32)
        self._lib.modulabot_step_batch(
            self._handle,
            agent_ids.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),
            ctypes.c_int(batch_size),
            ctypes.c_int(max(self._num_agents, batch_size)),
            ctypes.c_int(observations.shape[1]),
            ctypes.c_int(observations.shape[2]),
            ctypes.c_int(observations.shape[3]),
            ctypes.c_void_p(frame_advances.ctypes.data),
            ctypes.c_void_p(observations.ctypes.data),
            ctypes.c_void_p(actions.ctypes.data),
        )
        self._last_actions[:batch_size] = actions
        raw_actions[:batch_size] = actions.astype(raw_actions.dtype, copy=False)

        # Post-step: drain chat per-agent (cheap, main thread) and then
        # dispatch any pending LLM requests onto the worker pool. After
        # all dispatches are submitted, gather completed futures up to
        # the wall-clock deadline so step_batch returns in bounded
        # time even when the provider is slow (Sprint 4.1).
        for agent_id in range(batch_size):
            self._drain_chat(agent_id)
            if self._llm.enabled:
                self._dispatch_llm(agent_id)
        if self._llm.enabled and self._inflight:
            self._gather_llm_futures(batch_size)

    def step_agent(self, agent_id: int) -> int:
        if 0 <= agent_id < self._last_actions.shape[0]:
            return int(self._last_actions[agent_id])
        return 0

    def take_chat(self, agent_id: int) -> str:
        """Pops any pending chat for this agent. One-shot: subsequent
        calls return "" until the Nim side queues a new message."""
        text = self._pending_chat.pop(agent_id, "")
        return text

    def bitworld_chat_messages(self, agent_ids) -> list[str | None]:
        """Batched chat-query hook expected by ``bitworld_runner``.
        The runner calls this after ``step_batch`` and sends any
        non-None / non-empty entry as a BitWorld chat packet alongside
        the action mask.

        Without this method, the runner falls back to
        ``[None] * len(agent_ids)`` and the game never sees our chat
        — which was the bug that silently suppressed every LLM-
        generated accusation before this method existed.
        """
        result: list[str | None] = []
        for agent_id in agent_ids:
            text = self._pending_chat.pop(int(agent_id), "")
            result.append(text if text else None)
        return result

    # --- internals ---------------------------------------------------------

    def _drain_chat(self, agent_id: int) -> None:
        written = int(
            self._lib.modulabot_take_chat(
                self._handle,
                ctypes.c_int(agent_id),
                ctypes.c_void_p(ctypes.addressof(self._chat_buf)),
                ctypes.c_int(len(self._chat_buf)),
            )
        )
        if written <= 0:
            return
        try:
            text = self._chat_buf.raw[:written].decode("ascii").strip()
        except UnicodeDecodeError:
            # The Nim side emits ASCII; anything else is a bug. Skip.
            return
        if text:
            self._pending_chat[agent_id] = text

    def _ensure_executor(self) -> concurrent.futures.ThreadPoolExecutor:
        """Lazily creates the worker pool. Sized to ``num_agents`` so a
        full lobby of imposters + crewmates can dispatch in parallel."""
        if self._executor is None:
            workers = max(2, self._num_agents)
            self._executor = concurrent.futures.ThreadPoolExecutor(
                max_workers=workers,
                thread_name_prefix="mod_talks_llm",
            )
            logger.info(
                "mod_talks llm worker pool: max_workers=%d", workers
            )
        return self._executor

    def _dispatch_llm(self, agent_id: int) -> None:
        """Polls the Nim-side LLM request slot for one agent and, if a
        request is pending and no future is already in flight for the
        same agent, submits the provider call to the worker pool.

        Returns immediately — provider calls happen on background
        threads, results are gathered later. Per-agent in-flight
        bookkeeping in ``self._inflight`` mirrors the Nim-side single-
        slot semantics: one request per agent at a time."""
        if agent_id not in self._llm_enabled_agents:
            # First time we see this agent — enable the LLM path
            # server-side so the state machine actually emits requests.
            if (
                int(
                    self._lib.modulabot_enable_llm(
                        self._handle, ctypes.c_int(agent_id)
                    )
                )
                == 0
            ):
                self._llm_enabled_agents.add(agent_id)

        if agent_id in self._inflight:
            # Provider call from a previous tick is still running. Don't
            # try to take another request — Nim won't have generated one
            # while pending=true anyway, but be defensive.
            return

        ctx_len = int(
            self._lib.modulabot_take_llm_request(
                self._handle,
                ctypes.c_int(agent_id),
                ctypes.c_void_p(ctypes.addressof(self._kind_buf)),
                ctypes.c_int(len(self._kind_buf)),
                ctypes.c_void_p(ctypes.addressof(self._ctx_buf)),
                ctypes.c_int(len(self._ctx_buf)),
            )
        )
        if ctx_len <= 0:
            return
        try:
            kind = self._kind_buf.value.decode("ascii")
            context_json = self._ctx_buf.raw[:ctx_len].decode("utf-8")
        except UnicodeDecodeError:
            logger.warning("mod_talks LLM context buffer was not UTF-8; skipping")
            self._send_llm_error(agent_id, "")
            return
        if not kind:
            self._send_llm_error(agent_id, "")
            return

        role = int(self._lib.modulabot_role(self._handle, ctypes.c_int(agent_id)))
        executor = self._ensure_executor()
        # Sprint 4.2 — pick the per-kind timeout, falling back to the
        # default for kinds we haven't catalogued.
        timeout_s = PER_KIND_TIMEOUT_SECONDS.get(kind, DEFAULT_TIMEOUT_SECONDS)
        future = executor.submit(
            self._llm.complete,
            role=role,
            kind=kind,
            context_json=context_json,
            timeout_seconds=timeout_s,
        )
        import time
        self._inflight[agent_id] = _LlmFuture(
            kind=kind,
            future=future,
            dispatched_at_unix=time.time(),
        )

    def _gather_llm_futures(self, batch_size: int) -> None:
        """Waits for in-flight provider futures to complete (up to
        ``self._gather_deadline_seconds``), then feeds each finished
        result back through the FFI. Futures still running at the
        deadline are left in ``self._inflight`` and re-checked on the
        next step.

        The deadline is a wall-clock total across all futures, not
        per-future: an 8-agent batch with one slow provider doesn't
        block the other seven from being processed promptly. Slow
        ones simply roll over to the next tick.
        """
        if not self._inflight:
            return
        import time
        deadline = time.time() + self._gather_deadline_seconds
        # Snapshot the current set so we can iterate while mutating.
        active_ids = list(self._inflight.keys())
        for agent_id in active_ids:
            entry = self._inflight.get(agent_id)
            if entry is None:
                continue
            remaining = deadline - time.time()
            if remaining <= 0:
                # Out of budget. Leave running futures in place; we'll
                # check them next step. Don't cancel — many providers
                # don't honour cancellation cleanly and we'd just leak
                # a connection.
                break
            try:
                response_text = entry.future.result(timeout=remaining)
            except concurrent.futures.TimeoutError:
                # Future still running. Roll it over to next step.
                continue
            except Exception:  # pragma: no cover
                logger.exception(
                    "mod_talks LLM future raised; agent=%d kind=%s",
                    agent_id, entry.kind,
                )
                response_text = ""
            self._inflight.pop(agent_id, None)
            if not response_text:
                self._send_llm_error(agent_id, entry.kind)
                continue
            # Defensive: try parsing before handing to Nim so we can log
            # malformed responses here rather than eating the error in Nim.
            try:
                json.loads(response_text)
            except json.JSONDecodeError:
                logger.debug(
                    "mod_talks LLM returned non-JSON for %s (agent %d): %r",
                    entry.kind, agent_id, response_text[:200],
                )
                # Let Nim parse it too — it may still recognize substrings.
            self._lib.modulabot_set_llm_response(
                self._handle,
                ctypes.c_int(agent_id),
                entry.kind.encode("ascii"),
                response_text.encode("utf-8"),
                ctypes.c_int(0),
            )

    def _send_llm_error(self, agent_id: int, kind: str) -> None:
        self._lib.modulabot_set_llm_response(
            self._handle,
            ctypes.c_int(agent_id),
            kind.encode("ascii"),
            b"",
            ctypes.c_int(1),
        )

    def __del__(self):
        # Clean shutdown of the worker pool — ThreadPoolExecutor will
        # otherwise hang on interpreter exit waiting for futures.
        try:
            if self._executor is not None:
                self._executor.shutdown(wait=False, cancel_futures=True)
        except Exception:
            pass

    # --- observation helpers -----------------------------------------------

    def _ensure_agent_count(self, count: int) -> None:
        if count <= self._num_agents:
            return
        old_actions = self._last_actions
        self._num_agents = count
        self._last_actions = np.zeros(count, dtype=np.int32)
        self._last_actions[: old_actions.shape[0]] = old_actions

    def _normalize_observations(self, observations: np.ndarray) -> np.ndarray:
        if observations.ndim == 4:
            normalized = observations
        elif observations.ndim == 3:
            normalized = observations[:, np.newaxis, :, :]
        elif observations.ndim == 2:
            normalized = self._unpack_frames(observations)[:, np.newaxis, :, :]
        else:
            raise ValueError(
                "Expected BitWorld observations with 2, 3, or 4 dimensions, "
                f"got {observations.ndim}."
            )
        if normalized.shape[2:] != (SCREEN_HEIGHT, SCREEN_WIDTH):
            raise ValueError(
                f"Expected {SCREEN_HEIGHT}x{SCREEN_WIDTH} BitWorld frames."
            )
        return np.ascontiguousarray(normalized, dtype=np.uint8)

    def _unpack_frames(self, observations: np.ndarray) -> np.ndarray:
        packed = np.ascontiguousarray(observations, dtype=np.uint8)
        pixels = np.empty((packed.shape[0], packed.shape[1] * 2), dtype=np.uint8)
        pixels[:, 0::2] = packed & 0x0F
        pixels[:, 1::2] = packed >> 4
        return pixels.reshape(packed.shape[0], SCREEN_HEIGHT, SCREEN_WIDTH)

    # --- library loading / FFI binding -------------------------------------

    def _load_library(self) -> ctypes.CDLL:
        lib_path = self._modulabot_dir / _library_name()
        if self._library_needs_rebuild(lib_path):
            lib_path = Path(self._build.build_modulabot())
        lib = ctypes.CDLL(str(lib_path))
        self._verify_library_abi(lib, lib_path)
        return lib

    def _library_needs_rebuild(self, lib_path: Path) -> bool:
        if not lib_path.exists():
            return True
        try:
            stamp = int(self._build._abi_stamp_path(lib_path).read_text().strip())
        except (OSError, ValueError):
            return True
        return stamp != self._build.MODULABOT_ABI_VERSION

    def _verify_library_abi(self, lib: ctypes.CDLL, lib_path: Path) -> None:
        try:
            abi_version = lib.modulabot_abi_version
        except AttributeError as exc:
            raise RuntimeError(
                f"mod_talks library {lib_path} does not export an ABI version."
            ) from exc
        abi_version.argtypes = []
        abi_version.restype = ctypes.c_int
        actual = int(abi_version())
        expected = self._build.MODULABOT_ABI_VERSION
        if actual != expected:
            raise RuntimeError(
                f"mod_talks library {lib_path} has ABI version {actual}, "
                f"expected {expected}."
            )

    def _bind_ffi(self, lib: ctypes.CDLL) -> None:
        lib.modulabot_new_policy.argtypes = [ctypes.c_int]
        lib.modulabot_new_policy.restype = ctypes.c_int
        lib.modulabot_step_batch.argtypes = [
            ctypes.c_int,                           # handle
            ctypes.POINTER(ctypes.c_int32),         # agent_ids
            ctypes.c_int,                           # num_agent_ids
            ctypes.c_int,                           # num_agents
            ctypes.c_int,                           # frame_stack
            ctypes.c_int,                           # height
            ctypes.c_int,                           # width
            ctypes.c_void_p,                        # frame_advances
            ctypes.c_void_p,                        # observations
            ctypes.c_void_p,                        # actions
        ]
        lib.modulabot_step_batch.restype = None
        # New in ABI v2. These symbols always exist in v2+ libraries, so
        # binding unconditionally is safe.
        lib.modulabot_take_chat.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        lib.modulabot_take_chat.restype = ctypes.c_int
        lib.modulabot_enable_llm.argtypes = [ctypes.c_int, ctypes.c_int]
        lib.modulabot_enable_llm.restype = ctypes.c_int
        lib.modulabot_take_llm_request.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        lib.modulabot_take_llm_request.restype = ctypes.c_int
        lib.modulabot_set_llm_response.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_int,
        ]
        lib.modulabot_set_llm_response.restype = ctypes.c_int
        lib.modulabot_role.argtypes = [ctypes.c_int, ctypes.c_int]
        lib.modulabot_role.restype = ctypes.c_int
        # Trace-init. Optional; only called when MODULABOT_TRACE_DIR is set.
        lib.modulabot_init_trace.argtypes = [
            ctypes.c_char_p,                        # rootDir
            ctypes.c_int,                           # level
            ctypes.c_int,                           # snapshotPeriod
            ctypes.c_int,                           # captureFrames (0/1)
            ctypes.c_char_p,                        # harnessMeta (JSON or null)
        ]
        lib.modulabot_init_trace.restype = ctypes.c_int


def _library_name() -> str:
    system = platform.system()
    if system == "Darwin":
        return "libmodulabot.dylib"
    if system == "Windows":
        return "modulabot.dll"
    return "libmodulabot.so"

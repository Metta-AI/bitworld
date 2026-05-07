"""Natural-language instruction parsing.

The headline SDK feature: ``Agent.create(instructions="Be aggressive about
reporting bodies; trust nobody after meeting 2.")`` produces a typed
``Directives`` model that the scripted modules consult while making decisions.

There are two parsers:

  * :func:`parse_instructions_with_llm` — calls an LLM (default ``gpt-5.5``)
    to translate the free-form string into JSON matching the ``Directives``
    schema. This is the preferred path when an API key is available.
  * :func:`parse_instructions_keyword` — a regex/keyword parser used when no
    LLM key is set or the LLM call fails. It maps a small set of common
    phrases to directive fields. Lossy but deterministic.

Both return the same :class:`Directives` Pydantic model so downstream code
doesn't care which path produced them.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Literal

from pydantic import BaseModel, Field, field_validator

logger = logging.getLogger("among_them_sdk.cognition.instructions")

ReportEagerness = Literal["low", "normal", "high"]
KillEagerness = Literal["low", "normal", "high"]
ChatTone = Literal["neutral", "suspicious", "defensive", "paranoid", "friendly"]
VotingStyle = Literal["evidence", "majority", "contrarian", "skip_default"]


class Directives(BaseModel):
    """Typed directives that modulate evidencebot_v2 decisions.

    All fields are optional; the SDK applies defaults from
    :func:`Directives.scripted_defaults` when a directive is unset. Directives
    are *additive* with the cognitive kwargs passed to ``Agent.create``: the
    raw kwargs win over instruction-derived values.
    """

    suspicion_threshold: float = Field(0.5, ge=0.0, le=1.0)
    report_eagerness: ReportEagerness = "normal"
    kill_eagerness: KillEagerness = "normal"
    chat_tone: ChatTone = "neutral"
    voting_style: VotingStyle = "evidence"
    trust_horizon_meetings: int = Field(0, ge=0)
    avoid_central_room: bool = False
    follow_majority: bool = False
    raw: str | None = None
    notes: list[str] = Field(default_factory=list)

    @field_validator("notes", mode="before")
    @classmethod
    def _coerce_notes(cls, v: object) -> list[str]:
        if v is None:
            return []
        if isinstance(v, str):
            return [v]
        return list(v)  # type: ignore[arg-type]

    @classmethod
    def scripted_defaults(cls) -> Directives:
        return cls()

    def merged_with(self, **overrides: object) -> Directives:
        merged = self.model_dump()
        merged.update({k: v for k, v in overrides.items() if v is not None})
        return Directives(**merged)


_KEYWORD_PATTERNS: list[tuple[re.Pattern[str], dict[str, object]]] = [
    (re.compile(r"\b(report|reporting)[^.]*\b(aggressiv|eager|fast|always|every)\w*",
                re.IGNORECASE),
     {"report_eagerness": "high"}),
    (re.compile(r"\b(don'?t|never|avoid)\s+(report|reporting)", re.IGNORECASE),
     {"report_eagerness": "low"}),
    (re.compile(r"\btrust\s+nobody|trust\s+no\s+one\b", re.IGNORECASE),
     {"suspicion_threshold": 0.8}),
    (re.compile(r"\btrust\s+(everyone|allies)\b", re.IGNORECASE),
     {"suspicion_threshold": 0.3}),
    (re.compile(r"\bvote\s+with\s+(the\s+)?majority\b", re.IGNORECASE),
     {"voting_style": "majority", "follow_majority": True}),
    (re.compile(r"\b(only )?vote\s+(on|with)\s+evidence\b", re.IGNORECASE),
     {"voting_style": "evidence"}),
    (re.compile(r"\bskip\s+(votes?|voting)\b", re.IGNORECASE),
     {"voting_style": "skip_default"}),
    (re.compile(r"\bavoid\s+(central|cafeteria|the center)\b", re.IGNORECASE),
     {"avoid_central_room": True}),
    (re.compile(r"\b(paranoid|on edge)\b", re.IGNORECASE),
     {"chat_tone": "paranoid"}),
    (re.compile(r"\bdefensive\b", re.IGNORECASE),
     {"chat_tone": "defensive"}),
    (re.compile(r"\bsuspicious\b", re.IGNORECASE),
     {"chat_tone": "suspicious"}),
    (re.compile(r"\b(kill|killing)[^.]*\b(eager|fast|aggressiv)\w*", re.IGNORECASE),
     {"kill_eagerness": "high"}),
    (re.compile(r"\b(after|past)\s+meeting\s+(\d+)", re.IGNORECASE),
     {}),
]


def _extract_trust_horizon(text: str) -> int | None:
    m = re.search(r"\b(after|past)\s+meeting\s+(\d+)", text, re.IGNORECASE)
    if m:
        try:
            return int(m.group(2))
        except ValueError:
            return None
    return None


def parse_instructions_keyword(instructions: str) -> Directives:
    """Deterministic regex-based parse — used when no LLM is available."""
    if not instructions or not instructions.strip():
        return Directives.scripted_defaults()

    fields: dict[str, object] = {}
    notes: list[str] = []

    for pattern, updates in _KEYWORD_PATTERNS:
        if pattern.search(instructions):
            fields.update(updates)
            notes.append(f"matched: {pattern.pattern[:60]}")

    horizon = _extract_trust_horizon(instructions)
    if horizon is not None:
        fields["trust_horizon_meetings"] = horizon

    fields.setdefault("raw", instructions.strip())
    if notes:
        fields["notes"] = notes
    return Directives(**fields)


_LLM_SYSTEM_PROMPT = """You are a translator that converts free-form bot
instructions into a strict JSON object describing how an Among Them agent
should behave. The schema is:

{
  "suspicion_threshold": float in [0,1],
  "report_eagerness": "low" | "normal" | "high",
  "kill_eagerness": "low" | "normal" | "high",
  "chat_tone": "neutral" | "suspicious" | "defensive" | "paranoid" | "friendly",
  "voting_style": "evidence" | "majority" | "contrarian" | "skip_default",
  "trust_horizon_meetings": non-negative int (0 = trust always),
  "avoid_central_room": boolean,
  "follow_majority": boolean,
  "notes": list[string]   // 1-3 short reminders to surface at decision time
}

Output ONLY the JSON. Do not invent fields. Use sane defaults for anything
the user did not specify (suspicion_threshold=0.5, *_eagerness="normal",
chat_tone="neutral", voting_style="evidence", trust_horizon_meetings=0,
booleans=false)."""


def parse_instructions_with_llm(
    instructions: str,
    *,
    model: str = "gpt-5.5",
) -> Directives:
    """Best-effort LLM parse. Falls back to the keyword parser on any failure."""
    if not instructions or not instructions.strip():
        return Directives.scripted_defaults()

    from .llm import LLM, LLMUnavailableError

    try:
        llm = LLM(model=model)
    except LLMUnavailableError as exc:
        logger.info("LLM unavailable, falling back to keyword parse: %s", exc)
        return parse_instructions_keyword(instructions)

    try:
        raw = llm.complete(
            system=_LLM_SYSTEM_PROMPT,
            user=instructions.strip(),
            response_format="json",
        )
    except Exception as exc:
        logger.warning("LLM parse failed (%s); falling back to keyword parse.", exc)
        return parse_instructions_keyword(instructions)

    text = raw.text.strip()
    try:
        match = re.search(r"\{.*\}", text, re.DOTALL)
        if match is None:
            raise ValueError("no JSON object in LLM response")
        data = json.loads(match.group(0))
        data.setdefault("raw", instructions.strip())
        return Directives(**data)
    except Exception as exc:
        logger.warning("Could not coerce LLM response into Directives: %s", exc)
        return parse_instructions_keyword(instructions)


def parse_instructions(
    instructions: str | None,
    *,
    use_llm: bool = True,
    model: str = "gpt-5.5",
) -> Directives:
    """Top-level entry point.

    By default we *try* an LLM call (it gracefully no-ops if no API key is
    set). Pass ``use_llm=False`` to force the keyword parser, which is what
    the test suite uses to keep CI hermetic.
    """
    if instructions is None or not instructions.strip():
        return Directives.scripted_defaults()
    if use_llm:
        return parse_instructions_with_llm(instructions, model=model)
    return parse_instructions_keyword(instructions)

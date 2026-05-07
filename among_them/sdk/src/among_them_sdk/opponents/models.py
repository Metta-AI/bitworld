"""Pydantic models for cross-game opponent modeling.

All on-disk and in-memory data structures live here. The shape of these
models is the SDK's stable contract for opponent intel:

  * :class:`ObservationEvent` — one row per observed action. Persisted as
    NDJSON in the opponent's per-name folder.
  * :class:`ObservationLog` — per-opponent in-memory view of those events.
  * :class:`OpponentProfile` — the analyzed summary the LLM (or the
    deterministic fallback) emits. Persisted as one JSON file per opponent.

Sub-profile models (:class:`ChatStyleProfile`, :class:`VoteStrategyProfile`,
…) are typed Pydantic v2 models — never free-form dicts. The analyzer's
LLM prompt asks for exactly this schema so the parsing path stays trivial.

Privacy note: these structures store opponent player names verbatim and
chat strings verbatim. The store lives on disk by default. See
``docs/opponent-modeling.md`` for the privacy posture.
"""

from __future__ import annotations

import time
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator

ObservationType = Literal[
    "chat",
    "vote",
    "kill",
    "killed",
    "meeting_called",
    "accused",
    "accused_by",
    "alive_at_end",
    "role_revealed",
]
"""Discrete observation kinds we record per opponent. Keep this list in
sync with :class:`ObservationCollector` translation logic."""


Role = Literal["crew", "imposter", "unknown"]
"""Inferred or revealed role at game end. ``"unknown"`` when neither
side wins or the role isn't surfaced (the local server only exposes
roles via end-of-game scores; mid-game the role is hidden)."""


class ObservationEvent(BaseModel):
    """One observation about an opponent in a single game.

    The ``payload`` blob is intentionally untyped so we can store
    type-specific extras (e.g. ``{"target": "P03"}`` for a vote) without
    inflating the schema for every event kind. The analyzer is expected
    to handle missing payload keys gracefully.
    """

    type: ObservationType
    tick: int = 0
    game_id: str = ""
    payload: dict[str, Any] = Field(default_factory=dict)
    recorded_at: float = Field(default_factory=time.time)

    model_config = {"extra": "ignore"}


class ChatStyleProfile(BaseModel):
    """Stylistic summary of how an opponent talks in meetings."""

    avg_message_length: float = 0.0
    chat_rate: float = Field(0.0, ge=0.0, le=1.0)
    """Fraction of meetings this opponent spoke in (0.0–1.0)."""
    tone_descriptors: list[str] = Field(default_factory=list)
    """Free-form tone tags (e.g. ``"defensive"``, ``"taunting"``)."""
    common_phrases: list[str] = Field(default_factory=list)
    addresses_others: bool = False
    """True when chats often name a specific opponent (hint of social gameplay)."""


class VoteStrategyProfile(BaseModel):
    """Voting tendencies aggregated across games."""

    label: str = "unclassified"
    """One of ``evidence_grounded``, ``bandwagoner``, ``contrarian``, ``skipper``,
    ``erratic``, ``aggressive_imposter``, ``unclassified``. The analyzer is
    free to invent new labels — these are guidance, not enums."""
    skip_rate: float = Field(0.0, ge=0.0, le=1.0)
    follow_majority_rate: float = Field(0.0, ge=0.0, le=1.0)
    """Estimated fraction of votes that lined up with the eventual majority."""
    avg_meetings_to_first_vote: float = 0.0
    notes: list[str] = Field(default_factory=list)


class AccusationProfile(BaseModel):
    """How and how often this opponent throws accusations."""

    accusations_per_meeting: float = 0.0
    accuses_aggressively: bool = False
    typical_targets: list[str] = Field(default_factory=list)
    """Other player names this opponent has historically accused (from
    chat-name detection or explicit accuse events). Useful as a read on
    "is this opponent pre-committed to a target?"."""


class DefenseProfile(BaseModel):
    """How this opponent reacts when accused or under pressure."""

    defensiveness_score: float = Field(0.0, ge=0.0, le=1.0)
    counter_accuses: bool = False
    goes_silent_when_pressured: bool = False
    typical_defenses: list[str] = Field(default_factory=list)


class ConditionalBehavior(BaseModel):
    """How an opponent's strategy shifts conditional on their role.

    Filled per-role from the games where we observed the role at reveal.
    Empty when we have no observations of that role yet.
    """

    games_seen: int = 0
    play_pattern: str = ""
    """One-line summary like "kills early then hides in the cafeteria"."""
    chat_strategy: str = ""
    notable_tells: list[str] = Field(default_factory=list)
    """Behaviors that tend to give this opponent's role away."""


class OpponentProfile(BaseModel):
    """Analyzed cross-game profile for one named opponent.

    Produced by :func:`among_them_sdk.opponents.analyze_opponent` and
    persisted to disk via :class:`OpponentStore.save_profile`. The
    consumer modules (:class:`LLMVoter`, :class:`LLMChatter`) accept a
    mapping of name → profile and inject a compact summary into their
    prompts at decision time.
    """

    name: str
    games_observed: int = 0
    last_updated_at: float = Field(default_factory=time.time)
    chat_style: ChatStyleProfile = Field(default_factory=ChatStyleProfile)
    vote_strategy: VoteStrategyProfile = Field(default_factory=VoteStrategyProfile)
    accusation_tendency: AccusationProfile = Field(default_factory=AccusationProfile)
    defensiveness: DefenseProfile = Field(default_factory=DefenseProfile)
    alliance_patterns: list[str] = Field(default_factory=list)
    """Free-form notes like ``"coordinates with nottoodumb1"``."""
    role_conditional: dict[Role, ConditionalBehavior] = Field(default_factory=dict)
    confidence: float = Field(0.0, ge=0.0, le=1.0)
    """0.0 = no real evidence; 1.0 = many games observed + LLM-confirmed.
    The analyzer's deterministic-fallback path tops out at 0.3."""
    freeform_notes: str = ""
    """Append-only freeform notes from the analyzer. The merge step
    preserves prior notes by prefixing them — never discards intel."""

    model_config = {"extra": "ignore"}

    @field_validator("role_conditional", mode="before")
    @classmethod
    def _coerce_role_conditional(cls, v: object) -> dict[str, ConditionalBehavior]:
        # Tolerate JSON loaded as plain dict-of-dicts; Pydantic will
        # coerce the values via the field type, but only when the keys
        # are string-typed Roles. A previous version of this profile may
        # have stored unknown roles like "auto" — drop those silently.
        if v is None:
            return {}
        if not isinstance(v, dict):
            return {}
        out: dict[str, Any] = {}
        for k, val in v.items():
            if k in ("crew", "imposter", "unknown"):
                out[k] = val
        return out

    def compact_summary(self, *, max_chars: int = 360) -> str:
        """Render a one-paragraph summary suitable for LLM injection.

        Used by :class:`LLMVoter` / :class:`LLMChatter` to add opponent
        intel to their prompts without blowing past context budgets.
        Output is plain text, not JSON.
        """
        bits: list[str] = []
        bits.append(
            f"{self.name} (n={self.games_observed}, conf={self.confidence:.2f})"
        )
        if self.vote_strategy.label and self.vote_strategy.label != "unclassified":
            bits.append(
                f"votes: {self.vote_strategy.label}"
                f" (skip={self.vote_strategy.skip_rate:.0%},"
                f" maj={self.vote_strategy.follow_majority_rate:.0%})"
            )
        if self.chat_style.tone_descriptors:
            tones = ",".join(self.chat_style.tone_descriptors[:3])
            bits.append(f"chat: {tones} (rate={self.chat_style.chat_rate:.0%})")
        if self.accusation_tendency.accuses_aggressively:
            targets = ",".join(self.accusation_tendency.typical_targets[:3]) or "?"
            bits.append(f"accuses {targets}")
        if self.defensiveness.defensiveness_score >= 0.5:
            bits.append(
                f"defensive ({self.defensiveness.defensiveness_score:.2f})"
            )
        if self.alliance_patterns:
            bits.append(f"alliance: {self.alliance_patterns[0]}")
        out = "; ".join(bits)
        if len(out) > max_chars:
            out = out[: max_chars - 1] + "…"
        return out


__all__ = [
    "AccusationProfile",
    "ChatStyleProfile",
    "ConditionalBehavior",
    "DefenseProfile",
    "ObservationEvent",
    "ObservationType",
    "OpponentProfile",
    "Role",
    "VoteStrategyProfile",
]

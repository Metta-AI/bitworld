"""Cross-game opponent modeling.

Capture what each named opponent says and does, persist to disk, analyze
into typed profiles, and consume during play. See
``docs/opponent-modeling.md`` for the full architecture.

Public surface:

  * :class:`ObservationEvent` / :class:`ObservationLog` — raw data.
  * :class:`OpponentProfile` (+ sub-profile models) — analyzed output.
  * :class:`OpponentStore` — disk-backed persistence.
  * :class:`ObservationCollector` — translates :class:`AgentHooks`
    payloads into :class:`ObservationEvent` rows.
  * :func:`analyze_opponent` / :func:`analyze_all` — run the analyzer.
  * :func:`freeze_profiles` / :class:`BundledProfileLookup` — tournament
    bundle path (no live LLM calls inside cogames Docker).
"""

from __future__ import annotations

from .analyzer import (
    analyze_all,
    analyze_opponent,
    analyze_opponent_statistical,
    analyze_opponent_with_llm,
    merge_profiles,
)
from .bundle import BundledProfileLookup, freeze_profiles
from .collector import ObservationCollector
from .models import (
    AccusationProfile,
    ChatStyleProfile,
    ConditionalBehavior,
    DefenseProfile,
    ObservationEvent,
    ObservationType,
    OpponentProfile,
    Role,
    VoteStrategyProfile,
)
from .store import (
    DEFAULT_ROOT,
    DEFAULT_ROOT_ENV,
    ObservationLog,
    OpponentStore,
)

__all__ = [
    "AccusationProfile",
    "BundledProfileLookup",
    "ChatStyleProfile",
    "ConditionalBehavior",
    "DEFAULT_ROOT",
    "DEFAULT_ROOT_ENV",
    "DefenseProfile",
    "ObservationCollector",
    "ObservationEvent",
    "ObservationLog",
    "ObservationType",
    "OpponentProfile",
    "OpponentStore",
    "Role",
    "VoteStrategyProfile",
    "analyze_all",
    "analyze_opponent",
    "analyze_opponent_statistical",
    "analyze_opponent_with_llm",
    "freeze_profiles",
    "merge_profiles",
]

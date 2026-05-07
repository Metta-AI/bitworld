"""among_them_sdk — Python SDK for Among Them policy bots.

Public surface (Phase 0 + Phase 1):

  * :class:`Agent` — primary entry point. ``Agent.create(...)`` returns a
    composable agent backed by ``evidencebot_v2`` via FFI.
  * :class:`Runner` — fan-out helper for parallel tournaments.
  * :class:`LocalSim`, :class:`Subprocess`, :class:`RemoteServer` — runtimes.
  * Module ABCs: :class:`Voter`, :class:`Chatter`, :class:`Reporter`,
    :class:`Navigator`, :class:`Perception`, :class:`Memory`.
  * :class:`Directives` — typed instructions model.
  * :class:`LLM`, :func:`tool`, :class:`ToolLoop` — cognition primitives.

See :mod:`among_them_sdk.policy.evidencebot_v2` for the architectural note
on what module overrides can and cannot intercept inside the FFI bot.
"""

from __future__ import annotations

from .agent import Agent, AgentConfig
from .cogames_config import (
    CogamesBundleConfig,
)
from .cogames_config import (
    build_modules as build_cogames_modules,
)
from .cogames_config import (
    load_config as load_cogames_config,
)
from .cogames_config import (
    write_config as write_cogames_config,
)
from .cognition import (
    LLM,
    Directives,
    LLMResponse,
    Tool,
    ToolLoop,
    parse_instructions,
    tool,
)
from .hooks import AgentHooks
from .modules import (
    Chatter,
    Frame,
    LLMChatter,
    LLMVoter,
    Memory,
    Navigator,
    Percept,
    Perception,
    Reporter,
    ScriptedChatter,
    ScriptedMemory,
    ScriptedNavigator,
    ScriptedPerception,
    ScriptedReporter,
    ScriptedVoter,
    SilentChatter,
    Vote,
    Voter,
    VotingContext,
)
from .opponents import (
    BundledProfileLookup,
    ObservationCollector,
    ObservationEvent,
    ObservationLog,
    OpponentProfile,
    OpponentStore,
    analyze_all,
    analyze_opponent,
    freeze_profiles,
)
from .policy import AmongThemPolicy, EvidenceBotV2Policy, LocalSDKPolicy, SDKPolicy
from .runner import Runner
from .runtime import LocalSim, MeetingEvent, RemoteServer, RunResult, Subprocess, TickEvent
from .tracing import Tracer

try:
    from .live_game import LiveGame, LiveGameTranscript, fetch_results_json
except ImportError:  # websockets is optional for LocalSim-only users
    LiveGame = None  # type: ignore[assignment]
    LiveGameTranscript = None  # type: ignore[assignment]
    fetch_results_json = None  # type: ignore[assignment]

__version__ = "0.1.0"

__all__ = [
    "Agent",
    "AgentConfig",
    "AgentHooks",
    "AmongThemPolicy",
    "BundledProfileLookup",
    "Chatter",
    "CogamesBundleConfig",
    "Directives",
    "EvidenceBotV2Policy",
    "Frame",
    "LLM",
    "LLMChatter",
    "LLMResponse",
    "LLMVoter",
    "LiveGame",
    "LiveGameTranscript",
    "LocalSDKPolicy",
    "LocalSim",
    "MeetingEvent",
    "Memory",
    "Navigator",
    "ObservationCollector",
    "ObservationEvent",
    "ObservationLog",
    "OpponentProfile",
    "OpponentStore",
    "Percept",
    "Perception",
    "RemoteServer",
    "Reporter",
    "RunResult",
    "Runner",
    "SDKPolicy",
    "ScriptedChatter",
    "ScriptedMemory",
    "ScriptedNavigator",
    "ScriptedPerception",
    "ScriptedReporter",
    "ScriptedVoter",
    "SilentChatter",
    "Subprocess",
    "TickEvent",
    "Tool",
    "ToolLoop",
    "Tracer",
    "Vote",
    "Voter",
    "VotingContext",
    "__version__",
    "analyze_all",
    "analyze_opponent",
    "build_cogames_modules",
    "fetch_results_json",
    "freeze_profiles",
    "load_cogames_config",
    "parse_instructions",
    "tool",
    "write_cogames_config",
]

"""Cognitive modules — six ABCs and one scripted/LLM impl per slot.

Each module is a constructor-injectable unit of cognition. The default
implementations delegate to the FFI bot's behavior (i.e. they signal "I have
no opinion, ask the FFI"). Custom subclasses can override one or more methods
to inject Python-side decision logic without touching the rest of the
pipeline.
"""

from .chatter import Chatter, LLMChatter, ScriptedChatter, SilentChatter
from .memory import Memory, ScriptedMemory, SuspicionEntry, VotingContext
from .navigator import Navigator, ScriptedNavigator
from .perception import Frame, Percept, Perception, ScriptedPerception
from .reporter import ReportContext, Reporter, ScriptedReporter
from .voter import LLMVoter, ScriptedVoter, Vote, Voter

__all__ = [
    "Chatter",
    "Frame",
    "LLMChatter",
    "LLMVoter",
    "Memory",
    "Navigator",
    "Percept",
    "Perception",
    "ReportContext",
    "Reporter",
    "ScriptedChatter",
    "ScriptedMemory",
    "ScriptedNavigator",
    "ScriptedPerception",
    "ScriptedReporter",
    "ScriptedVoter",
    "SilentChatter",
    "SuspicionEntry",
    "Vote",
    "Voter",
    "VotingContext",
]

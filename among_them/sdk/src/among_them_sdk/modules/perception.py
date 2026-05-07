"""Perception module — turns raw frames into structured percepts.

The default implementation passes frames straight to the FFI; the SDK does
not attempt to re-implement Nim's localization (~1.5k LOC of CV math).
Custom Perception subclasses can attach metadata to the returned Percept
without touching the FFI's internal world model.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any

import numpy as np


@dataclass
class Frame:
    """One observation slice handed to the agent each tick.

    ``pixels`` is a uint8 array of shape ``(frame_stack, 128, 128)`` — exactly
    the shape the FFI expects for a single agent. Higher-level metadata
    (game tick number, agent role hint, etc.) lives on the surrounding
    fields and is consulted only by Python modules.
    """

    pixels: np.ndarray
    tick: int = 0
    agent_id: int = 0
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class Percept:
    """Structured output of a perception pass.

    ``raw`` keeps the FFI-bound pixel buffer; ``derived`` is whatever a
    custom Perception module wants to attach (suspicion deltas, room labels,
    etc.). The runtime forwards ``derived`` to the Voter / Reporter modules
    via the working memory's "extras" channel.
    """

    raw: np.ndarray
    tick: int
    agent_id: int
    derived: dict[str, Any] = field(default_factory=dict)


class Perception(ABC):
    @abstractmethod
    def perceive(self, frame: Frame) -> Percept: ...


class ScriptedPerception(Perception):
    """Default: pass through. The FFI consumes ``percept.raw`` directly."""

    def perceive(self, frame: Frame) -> Percept:
        return Percept(raw=frame.pixels, tick=frame.tick, agent_id=frame.agent_id)


__all__ = ["Frame", "Percept", "Perception", "ScriptedPerception"]

"""Reporter module — body-report decisions."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any


@dataclass
class ReportContext:
    tick: int
    self_id: str
    body_player_id: str
    distance_to_body: float | None
    seen_body_for_ticks: int = 0
    extras: dict[str, Any] | None = None


class Reporter(ABC):
    @abstractmethod
    def should_report(self, ctx: ReportContext) -> bool: ...


class ScriptedReporter(Reporter):
    """Threshold-tunable report logic.

    Eagerness levels map to a max-distance gate:
      * low    — only if the body is right next to us (<=3)
      * normal — within report range (<=10)
      * high   — almost always (<=30)
    """

    _DISTANCE_BY_EAGERNESS = {"low": 3.0, "normal": 10.0, "high": 30.0}

    def __init__(self, eagerness: str = "normal"):
        self.eagerness = eagerness

    def should_report(self, ctx: ReportContext) -> bool:
        max_dist = self._DISTANCE_BY_EAGERNESS.get(
            self.eagerness, self._DISTANCE_BY_EAGERNESS["normal"]
        )
        if ctx.distance_to_body is None:
            return self.eagerness != "low"
        return ctx.distance_to_body <= max_dist


__all__ = ["ReportContext", "Reporter", "ScriptedReporter"]

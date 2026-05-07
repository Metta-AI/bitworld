"""Navigator module — per-tick action choice.

The default delegates to the FFI's action index (see
:class:`among_them_sdk.policy.evidencebot_v2.EvidenceBotV2Policy.step`). The
SDK exposes a ``goal_injector`` slot so custom navigators can nudge the
agent toward a Python-chosen goal without rebuilding the Nim core.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any


@dataclass
class NavigationContext:
    tick: int
    agent_id: int
    ffi_action: int
    extras: dict[str, Any]


class Navigator(ABC):
    @abstractmethod
    def step(self, ctx: NavigationContext) -> int | None: ...


class ScriptedNavigator(Navigator):
    """Default: respect the FFI action. Returns ``None`` to mean "no override"."""

    def __init__(self, goal_injector: Callable[[NavigationContext], int | None] | None = None):
        self.goal_injector = goal_injector

    def step(self, ctx: NavigationContext) -> int | None:
        if self.goal_injector is None:
            return None
        return self.goal_injector(ctx)


__all__ = ["NavigationContext", "Navigator", "ScriptedNavigator"]

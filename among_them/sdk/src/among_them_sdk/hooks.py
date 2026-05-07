"""Lifecycle hooks consumed by the runtime.

Every hook is optional and called from the runtime's tick loop. Hooks raise
=> logged + skipped (we never let user code crash a run by default).
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger("among_them_sdk.hooks")


@dataclass
class AgentHooks:
    pre_tick: Callable[[dict[str, Any]], None] | None = None
    post_tick: Callable[[dict[str, Any], int], None] | None = None
    on_vote: Callable[[dict[str, Any]], None] | None = None
    on_meeting: Callable[[dict[str, Any]], None] | None = None
    on_kill: Callable[[dict[str, Any]], None] | None = None
    on_message: Callable[[dict[str, Any]], None] | None = None
    on_llm_call: Callable[[dict[str, Any]], None] | None = None
    custom: dict[str, Callable[..., Any]] = field(default_factory=dict)

    def call(self, name: str, *args: Any, **kwargs: Any) -> None:
        cb = getattr(self, name, None)
        if cb is None:
            cb = self.custom.get(name)
        if cb is None:
            return
        try:
            cb(*args, **kwargs)
        except Exception as exc:
            logger.warning("hook %s raised: %s", name, exc)


__all__ = ["AgentHooks"]

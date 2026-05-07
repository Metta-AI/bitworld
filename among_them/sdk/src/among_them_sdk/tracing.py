"""Tracing facade.

Default backend is ``structlog`` JSONL on stdout/disk — zero deps. Langfuse
support is **stubbed** for Phase 0/1; calling :func:`enable_langfuse` raises
``NotImplementedError`` for now (deliberately, see DESIGN.md §4.12).
"""

from __future__ import annotations

import logging
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Any

import structlog

structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
)


@dataclass
class TraceEvent:
    name: str
    payload: dict[str, Any] = field(default_factory=dict)


class Tracer:
    def __init__(self, *, name: str = "among_them_sdk", level: int = logging.INFO):
        self._log = structlog.get_logger(name)
        self.name = name
        self.level = level

    def event(self, name: str, **payload: Any) -> None:
        self._log.info(name, **payload)

    @contextmanager
    def span(self, name: str, **payload: Any):
        self._log.info(f"{name}.start", **payload)
        try:
            yield
        finally:
            self._log.info(f"{name}.end", **payload)


def enable_langfuse(*args: Any, **kwargs: Any) -> None:
    """Phase 4 hook — currently a stub.

    The full Langfuse integration was descoped from Phase 0/1 in the build
    plan. Set ``LANGFUSE_PUBLIC_KEY`` etc. in env once the integration lands.
    """
    raise NotImplementedError(
        "Langfuse tracing arrives in Phase 4. Use the default structlog "
        "backend until then."
    )


__all__ = ["Tracer", "TraceEvent", "enable_langfuse"]

"""Wrapper around the evidencebot_v2 Nim FFI policy.

Architectural note (please read before extending)
-------------------------------------------------

The Nim FFI exposes only three symbols (``abi_version``, ``new_policy``,
``step_batch``). Per tick: pixel frames go in, action *indices* come out.
The .so does **not** surface its internal decision points (suspicion table,
voting candidate, report intent, chat queue, navigation goal). All of those
are tunable Nim constants today (see Explorer B's trace, e.g.
``WitnessNearBodyRadius`` at ``evidencebot_v2.nim:87``).

That means SDK module overrides cannot literally replace the bot's voting
function inside Nim. Instead, the SDK runs evidencebot_v2 as the **default
low-level action producer** and the runtime layer surfaces explicit
voting / reporting / chat / navigation events to the user's modules. When a
user passes ``voter=LLMVoter()`` the runtime calls that voter at meeting
time; the FFI continues to handle every-tick navigation indices.

This is the pragmatic shape that actually works against the existing FFI
without a Nim rebuild. Future work (Phase 2+): expose the Nim decision
intermediates over a richer FFI so we can properly intercept inside the
.so. Until then, treat ``OverrideHooks`` as the contract.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from .. import ffi as _ffi

logger = logging.getLogger("among_them_sdk.policy.evidencebot_v2")

BITWORLD_ACTION_NAMES = (
    "noop",
    "up",
    "down",
    "left",
    "right",
    "use",
    "use_up",
    "use_down",
    "use_left",
    "use_right",
    "report",
    "report_up",
    "report_down",
    "report_left",
    "report_right",
)
BITWORLD_NUM_ACTIONS = len(BITWORLD_ACTION_NAMES)


@dataclass
class OverrideHooks:
    """Collection of override callables consulted by the runtime.

    Each override is optional; ``None`` means "use the FFI default action".
    Module classes (Voter, Reporter, etc.) populate these hooks at agent
    construction time.
    """

    pre_tick: Callable[[dict[str, Any]], None] | None = None
    post_tick: Callable[[dict[str, Any], int], None] | None = None
    on_vote: Callable[[dict[str, Any]], Decision | None] | None = None
    on_report: Callable[[dict[str, Any]], bool | None] | None = None
    on_chat: Callable[[dict[str, Any]], str | None] | None = None
    on_navigate: Callable[[dict[str, Any]], int | None] | None = None
    notes: list[str] = field(default_factory=list)


@dataclass
class Decision:
    """Generic decision wrapper used across overrides."""
    kind: str
    value: Any
    reason: str = ""


class EvidenceBotV2Policy:
    """High-level driver around the FFI library.

    Owns one FFI handle per instance and a small bookkeeping cache for the
    per-tick action history (used by the LocalSim runtime to summarize a
    run).
    """

    NAME = "evidencebot_v2"

    def __init__(
        self,
        *,
        num_agents: int = 1,
        auto_build: bool = True,
        library: _ffi.EvidenceBotV2Library | None = None,
    ):
        self.num_agents = max(1, int(num_agents))
        self.library = library or _ffi.load_library(auto_build=auto_build)
        self.handle = self.library.new_policy(self.num_agents)
        self.tick_count = 0
        self.last_actions: np.ndarray = np.zeros(self.num_agents, dtype=np.int32)
        self.action_history: list[np.ndarray] = []

    @property
    def abi_version(self) -> int:
        return self.library.abi_version

    @property
    def library_path(self) -> str:
        return str(self.library.path)

    def reset(self) -> None:
        """Allocate a fresh FFI handle. Old handle is leaked (Nim has no destroy)."""
        self.handle = self.library.new_policy(self.num_agents)
        self.tick_count = 0
        self.last_actions = np.zeros(self.num_agents, dtype=np.int32)
        self.action_history.clear()

    def step(self, observations: np.ndarray) -> np.ndarray:
        actions = self.library.step_batch(
            self.handle,
            observations,
            num_agents_hint=self.num_agents,
        )
        self.tick_count += 1
        self.last_actions = actions.copy()
        self.action_history.append(actions.copy())
        return actions

    def step_with_hooks(
        self,
        observations: np.ndarray,
        hooks: OverrideHooks | None = None,
    ) -> np.ndarray:
        ctx: dict[str, Any] = {
            "tick": self.tick_count,
            "observations_shape": tuple(observations.shape),
            "num_agents": self.num_agents,
        }
        if hooks and hooks.pre_tick:
            try:
                hooks.pre_tick(ctx)
            except Exception as exc:
                logger.warning("pre_tick hook raised: %s", exc)
        actions = self.step(observations)
        if hooks and hooks.on_navigate:
            for agent_id in range(actions.shape[0]):
                try:
                    new_idx = hooks.on_navigate(
                        {**ctx, "agent_id": agent_id, "ffi_action": int(actions[agent_id])}
                    )
                except Exception as exc:
                    logger.warning("on_navigate hook raised: %s", exc)
                    continue
                if new_idx is not None:
                    actions[agent_id] = int(new_idx)
        if hooks and hooks.post_tick:
            try:
                hooks.post_tick(ctx, int(actions[0]) if actions.size else 0)
            except Exception as exc:
                logger.warning("post_tick hook raised: %s", exc)
        return actions

    def summary(self) -> dict[str, Any]:
        return {
            "policy": self.NAME,
            "abi_version": self.abi_version,
            "library_path": self.library_path,
            "num_agents": self.num_agents,
            "ticks": self.tick_count,
            "unique_actions": (
                int(np.unique(np.concatenate(self.action_history)).size)
                if self.action_history else 0
            ),
        }


@dataclass
class DefaultProfile:
    """Entry-point profile pointing at the ``evidencebot_v2`` policy.

    Discovered via the ``among_them.profiles`` setuptools entry-point group.
    Authors of third-party profiles inherit from this and override ``build``.
    """

    name: str = "evidencebot_v2"
    description: str = "Default scripted Among Them policy via FFI."

    def build(self, *, num_agents: int = 1) -> EvidenceBotV2Policy:
        return EvidenceBotV2Policy(num_agents=num_agents)


__all__ = [
    "BITWORLD_ACTION_NAMES",
    "BITWORLD_NUM_ACTIONS",
    "Decision",
    "DefaultProfile",
    "EvidenceBotV2Policy",
    "OverrideHooks",
]


def _decode_action(index: int) -> str:
    if 0 <= index < BITWORLD_NUM_ACTIONS:
        return BITWORLD_ACTION_NAMES[index]
    return "unknown"


def decode_actions(indices: Iterable[int]) -> list[str]:
    """Map int indices to BitWorld action names. Useful for summaries/logging."""
    return [_decode_action(int(i)) for i in indices]

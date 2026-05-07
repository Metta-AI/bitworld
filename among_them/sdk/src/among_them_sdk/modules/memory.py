"""Working memory + voting context.

Cyborg's :class:`framework.base_memory.GameMemory` is a richer three-tier
model (working / episodic / strategic) but it's bound to cyborg's harness
loop. We define a smaller SDK-specific memory here that exposes the suspicion
table — the one piece of bot state custom modules actually need.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any


@dataclass
class SuspicionEntry:
    player_id: str
    score: float = 0.0
    reasons: list[str] = field(default_factory=list)
    last_seen_tick: int = 0
    distance_to_body: int | None = None


@dataclass
class VotingContext:
    """Synthesized at meeting time and handed to ``Voter.vote``.

    The runtime constructs this from accumulated memory; custom Voters get a
    deterministic snapshot rather than the live mutable memory dict.
    """

    meeting_index: int
    self_id: str
    suspects: list[SuspicionEntry]
    body_player_id: str | None = None
    extras: dict[str, Any] = field(default_factory=dict)

    def by_score(self, descending: bool = True) -> list[SuspicionEntry]:
        return sorted(self.suspects, key=lambda s: s.score, reverse=descending)

    def to_prompt(self) -> str:
        lines = [f"You are agent {self.self_id} at meeting #{self.meeting_index}."]
        if self.body_player_id:
            lines.append(f"A body of {self.body_player_id} was just reported.")
        lines.append("Suspects:")
        for s in self.by_score():
            reason = "; ".join(s.reasons) if s.reasons else "no notes"
            lines.append(f"  - {s.player_id}: score={s.score:.2f} ({reason})")
        return "\n".join(lines)


class Memory(ABC):
    @abstractmethod
    def update(self, *, tick: int, percept: Any | None = None) -> None: ...

    @abstractmethod
    def voting_context(self, *, meeting_index: int, self_id: str) -> VotingContext: ...


class ScriptedMemory(Memory):
    """Lightweight memory: a flat suspicion table updated by hooks.

    The FFI maintains its own (richer) suspicion table inside Nim — we cannot
    read it. This SDK-side memory exists so custom modules have *something*
    to consult; populate it from hooks (``on_kill``, ``on_message``, etc.).
    """

    def __init__(self) -> None:
        self.tick = 0
        self.suspects: dict[str, SuspicionEntry] = {}
        self.meetings_seen = 0

    def update(self, *, tick: int, percept: Any | None = None) -> None:
        self.tick = tick

    def bump(self, player_id: str, delta: float, reason: str = "") -> None:
        entry = self.suspects.setdefault(player_id, SuspicionEntry(player_id=player_id))
        entry.score = max(0.0, min(1.0, entry.score + delta))
        if reason:
            entry.reasons.append(reason)
        entry.last_seen_tick = self.tick

    def note_meeting(self) -> int:
        self.meetings_seen += 1
        return self.meetings_seen

    def voting_context(
        self,
        *,
        meeting_index: int | None = None,
        self_id: str = "self",
    ) -> VotingContext:
        idx = meeting_index if meeting_index is not None else self.meetings_seen
        return VotingContext(
            meeting_index=idx,
            self_id=self_id,
            suspects=list(self.suspects.values()),
        )


__all__ = ["Memory", "ScriptedMemory", "SuspicionEntry", "VotingContext"]

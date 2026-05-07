"""Fan-out helper for running multiple agents in parallel.

Borrowed from OpenAI Agents SDK semantics — minimal in Phase 0/1: serial
execution with optional thread-pool parallelism. Each agent runs against an
independent :class:`LocalSim` instance.
"""

from __future__ import annotations

import logging
from collections.abc import Iterable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

from .agent import Agent
from .runtime import LocalSim, RunResult

logger = logging.getLogger("among_them_sdk.runner")


@dataclass
class Runner:
    agents: list[Agent]
    rounds: int = 1
    parallelism: int = 1
    runtime_factory: type[LocalSim] = LocalSim

    def run(self) -> list[RunResult]:
        if self.parallelism <= 1:
            return [a.run(rounds=self.rounds) for a in self.agents]

        with ThreadPoolExecutor(max_workers=self.parallelism) as pool:
            return list(pool.map(lambda a: a.run(rounds=self.rounds), self.agents))

    def leaderboard(self, results: Iterable[RunResult] | None = None) -> list[dict]:
        results_list = list(results) if results is not None else self.run()
        rows: list[dict] = []
        for agent, result in zip(self.agents, results_list, strict=False):
            rows.append({
                "profile": agent.config.profile,
                "ticks": result.ticks,
                "meetings": result.meetings,
                "votes": len(result.votes),
                "chats": len(result.chat_messages),
                "instructions": agent.config.instructions,
            })
        return rows


__all__ = ["Runner"]

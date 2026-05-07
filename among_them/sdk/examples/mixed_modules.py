"""Compose multiple cognitive overrides at once.

Mixes:
  * scripted Perception  (default pass-through)
  * scripted Memory      (default suspicion table)
  * LLM Voter            (gracefully falls back to scripted on missing key)
  * custom Reporter      (Python class that raises body-report threshold)

Then prints which module made each meeting decision so the composition is
observable end-to-end. Output: per-meeting [voter -> Vote] lines, plus a
summary row showing how many reports the custom reporter accepted vs the
scripted default would have.

Run:
  uv run python examples/mixed_modules.py
"""

from __future__ import annotations

import logging

from among_them_sdk import (
    Agent,
    AgentHooks,
    LLMVoter,
    Reporter,
    ScriptedMemory,
    ScriptedPerception,
)
from among_them_sdk.modules.reporter import ReportContext

logging.getLogger("among_them_sdk").setLevel(logging.WARNING)


class HighThresholdReporter(Reporter):
    """Only report bodies that we've watched for >= ``min_seen_ticks``.

    Stricter than ScriptedReporter, which gates on distance only.
    """

    def __init__(self, min_seen_ticks: int = 5, max_distance: float = 8.0):
        self.min_seen_ticks = min_seen_ticks
        self.max_distance = max_distance
        self.accepts = 0
        self.rejects = 0

    def should_report(self, ctx: ReportContext) -> bool:
        ok = (
            ctx.seen_body_for_ticks >= self.min_seen_ticks
            and (ctx.distance_to_body or 99.0) <= self.max_distance
        )
        if ok:
            self.accepts += 1
        else:
            self.rejects += 1
        return ok


def main() -> None:
    reporter = HighThresholdReporter(min_seen_ticks=4, max_distance=8.0)

    decisions: list[tuple[int, str | None, str]] = []
    hooks = AgentHooks(
        on_vote=lambda p: decisions.append(
            (int(p["meeting"]), p.get("target"), str(p.get("reason", "")))
        ),
    )

    agent = Agent.create(
        instructions="Vote on evidence. Be suspicious of anyone near a body.",
        perception=ScriptedPerception(),
        memory=ScriptedMemory(),
        voter=LLMVoter(model="gpt-5.5"),  # falls back to scripted if no key
        reporter=reporter,
        hooks=hooks,
        use_llm_for_instructions=False,
        seed=314,
    )

    result = agent.run(rounds=2)

    voter_kind = "LLM" if getattr(agent.voter, "llm", None) is not None else "scripted-fallback"
    print(f"voter:    LLMVoter ({voter_kind})")
    print(f"reporter: HighThresholdReporter (accepts={reporter.accepts} "
          f"rejects={reporter.rejects})")
    print()
    print("meeting decisions:")
    for meeting, target, reason in decisions:
        target_label = target or "skip"
        print(f"  m{meeting:>2}: {target_label:<10} ({reason})")
    print()
    print(result.summary)


if __name__ == "__main__":
    main()

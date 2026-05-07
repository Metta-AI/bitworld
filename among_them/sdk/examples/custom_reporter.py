"""Implement a custom Reporter from scratch by subclassing the Reporter ABC.

This is the reporter equivalent of ``custom_voter.py``: it shows how to write
a brand-new module that hooks into the body-report decision point. The bot
emits a report when ``should_report`` returns True.

Demonstrates the protocol/ABC pattern from ``among_them_sdk.modules.reporter``.

Run:
  uv run python examples/custom_reporter.py
"""

from __future__ import annotations

import logging

from among_them_sdk import Agent, Reporter
from among_them_sdk.modules.reporter import ReportContext

logging.getLogger("among_them_sdk").setLevel(logging.WARNING)


class CooldownReporter(Reporter):
    """Allow at most one report per ``cooldown_ticks`` window.

    Useful for "report once per situation" bots that don't want to spam
    meetings every time they walk past a body. State is per-instance so
    each Agent gets its own cooldown counter.
    """

    def __init__(self, cooldown_ticks: int = 50, max_distance: float = 12.0):
        self.cooldown_ticks = cooldown_ticks
        self.max_distance = max_distance
        self._last_report_tick: int | None = None
        self.history: list[tuple[int, str, bool, str]] = []

    def should_report(self, ctx: ReportContext) -> bool:
        if ctx.distance_to_body is not None and ctx.distance_to_body > self.max_distance:
            decision, reason = False, f"too far ({ctx.distance_to_body:.1f})"
        elif (self._last_report_tick is not None
              and ctx.tick - self._last_report_tick < self.cooldown_ticks):
            wait = self.cooldown_ticks - (ctx.tick - self._last_report_tick)
            decision, reason = False, f"cooldown ({wait} ticks remaining)"
        else:
            decision, reason = True, "in range and cooldown elapsed"
            self._last_report_tick = ctx.tick

        self.history.append((ctx.tick, ctx.body_player_id, decision, reason))
        return decision


def main() -> None:
    reporter = CooldownReporter(cooldown_ticks=40, max_distance=10.0)
    agent = Agent.create(
        reporter=reporter,
        seed=2026,
        use_llm_for_instructions=False,
    )
    result = agent.run(rounds=2)

    accepted = sum(1 for _, _, ok, _ in reporter.history if ok)
    print(f"reporter calls:   {len(reporter.history)}")
    print(f"reports emitted:  {accepted}")
    print()
    print("decision log:")
    for tick, body, ok, reason in reporter.history:
        verdict = "REPORT" if ok else "skip"
        print(f"  tick {tick:>3}  body={body:<5}  {verdict:<6} {reason}")
    print()
    print(result.summary)


if __name__ == "__main__":
    main()

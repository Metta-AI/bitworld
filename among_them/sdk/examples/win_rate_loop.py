"""Run K games of the default bot and aggregate behavior + directive stats.

LocalSim is a synthetic frame driver — there's no real win/loss signal — so
"win rate" here is a documented proxy: a game is counted as a "win" when the
agent voted (didn't skip) in at least half of its meetings. The script also
prints:

  * average meetings per game (proxy for "rounds-to-resolution")
  * one summary stat per Directives field (mode for categorical, mean for
    numeric, ratio-of-True for booleans)

This demonstrates end-to-end consumption of ``RunResult.summary``,
``RunResult.votes``, ``RunResult.reports`` and ``agent.directives``.

Run:
  uv run python examples/win_rate_loop.py
  uv run python examples/win_rate_loop.py --games 25
"""

from __future__ import annotations

import argparse
import logging
from collections import Counter
from statistics import mean

from among_them_sdk import Agent, Directives

logging.getLogger("among_them_sdk").setLevel(logging.WARNING)

INSTRUCTIONS = (
    "Be suspicious. Vote with the majority unless you have evidence. "
    "Report bodies aggressively."
)


def _is_win(votes_cast: int, n_meetings: int) -> bool:
    if n_meetings == 0:
        return False
    return votes_cast / n_meetings >= 0.5


def _summarize_directive(field: str, values: list[object]) -> str:
    if not values:
        return "n/a"
    sample = values[0]
    if isinstance(sample, bool):
        ratio = sum(1 for v in values if v) / len(values)
        return f"True={ratio:.2f}"
    if isinstance(sample, (int, float)):
        return f"avg={mean(float(v) for v in values):.2f}"  # type: ignore[arg-type]
    counts = Counter(str(v) for v in values)
    most, n = counts.most_common(1)[0]
    return f"mode={most} ({n}/{len(values)})"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--games", type=int, default=10)
    parser.add_argument("--instructions", default=INSTRUCTIONS)
    args = parser.parse_args()

    wins = 0
    meetings_per_game: list[int] = []
    directive_samples: dict[str, list[object]] = {}

    for i in range(args.games):
        agent = Agent.create(
            instructions=args.instructions,
            seed=10 + i,
            use_llm_for_instructions=False,
        )
        # snapshot directives — same instructions but seed-independent
        for k, v in agent.directives.model_dump().items():
            directive_samples.setdefault(k, []).append(v)

        result = agent.run(rounds=1)
        votes_cast = sum(1 for v in result.votes if v.target is not None)
        if _is_win(votes_cast, len(result.votes)):
            wins += 1
        meetings_per_game.append(result.meetings)

    print(f"Games:          {args.games}")
    print(f"Win rate:       {wins / args.games:.2%}  "
          f"(>=50% of meetings actually voted)")
    print(f"Avg meetings:   {mean(meetings_per_game):.2f}")
    print()
    print("Directive summary across games:")
    for field in Directives.model_fields:
        if field in {"raw", "notes"}:
            continue
        values = directive_samples.get(field, [])
        print(f"  {field:<25} {_summarize_directive(field, values)}")


if __name__ == "__main__":
    main()

"""A/B test two instruction strings over N games each.

LocalSim doesn't expose win/loss (it's a synthetic frame driver), so we score
each variant on observable behavior:

  * vote_rate    — fraction of meetings where the agent voted (didn't skip)
  * report_rate  — fraction of synthesized body events that were reported
  * chat_rate    — fraction of meetings where the chatter emitted text
  * action_var   — number of distinct BitWorld actions chosen across the run

Output: one row per variant with each metric averaged across N games. Uses
``rich.table.Table`` if installed (it isn't a SDK dep); falls back to plain
stdout otherwise.

Run:
  uv run python examples/ab_test_instructions.py
  uv run python examples/ab_test_instructions.py --games 20
"""

from __future__ import annotations

import argparse
import logging
from collections.abc import Iterable
from statistics import mean

from among_them_sdk import Agent, RunResult

logging.getLogger("among_them_sdk").setLevel(logging.WARNING)

VARIANT_A = "Vote with the majority. Avoid the central room."
VARIANT_B = "Trust nobody. Report bodies aggressively. Be paranoid in chat."


def _scores(result: RunResult) -> dict[str, float]:
    votes_cast = sum(1 for v in result.votes if v.target is not None)
    n_meetings = max(1, len(result.votes))
    n_reports = max(1, len(result.reports))
    return {
        "vote_rate": votes_cast / n_meetings,
        "report_rate": sum(1 for r in result.reports if r) / n_reports,
        "chat_rate": len(result.chat_messages) / n_meetings,
        "action_var": float(len(set(result.actions))),
    }


def _aggregate(rows: Iterable[dict[str, float]]) -> dict[str, float]:
    rows = list(rows)
    keys = rows[0].keys() if rows else []
    return {k: round(mean(r[k] for r in rows), 3) for k in keys}


def _run_variant(label: str, instructions: str, games: int) -> dict[str, float]:
    per_game: list[dict[str, float]] = []
    for i in range(games):
        agent = Agent.create(
            instructions=instructions,
            seed=1000 + i,  # different seed each game so we sample behavior
            use_llm_for_instructions=False,
        )
        per_game.append(_scores(agent.run(rounds=1)))
    summary = _aggregate(per_game)
    summary["label"] = label  # type: ignore[assignment]
    return summary


def _print(rows: list[dict[str, float]]) -> None:
    try:
        from rich.console import Console
        from rich.table import Table
    except ImportError:
        for row in rows:
            print(f"{row['label']:>10}  "
                  f"vote={row['vote_rate']:.2f}  "
                  f"report={row['report_rate']:.2f}  "
                  f"chat={row['chat_rate']:.2f}  "
                  f"action_var={row['action_var']:.1f}")
        return

    table = Table(title="A/B test: instruction variants")
    for col in ("variant", "vote_rate", "report_rate", "chat_rate", "action_var"):
        table.add_column(col)
    for row in rows:
        table.add_row(
            str(row["label"]),
            f"{row['vote_rate']:.2f}",
            f"{row['report_rate']:.2f}",
            f"{row['chat_rate']:.2f}",
            f"{row['action_var']:.1f}",
        )
    Console().print(table)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--games", type=int, default=10)
    parser.add_argument("--variant-a", default=VARIANT_A)
    parser.add_argument("--variant-b", default=VARIANT_B)
    args = parser.parse_args()

    print(f"Running {args.games} games per variant...")
    rows = [
        _run_variant("A", args.variant_a, args.games),
        _run_variant("B", args.variant_b, args.games),
    ]
    _print(rows)
    winner = max(rows, key=lambda r: r["vote_rate"])
    print(f"\nHigher vote_rate: variant {winner['label']} "
          f"({winner['vote_rate']:.2f})")


if __name__ == "__main__":
    main()

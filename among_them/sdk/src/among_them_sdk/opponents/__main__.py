"""CLI: ``python -m among_them_sdk.opponents``.

Subcommands:

  * ``record``     — sanity-check the current store: print root, list
    opponents, dump per-opponent observation counts.
  * ``list``       — list opponents with games_observed + last_updated.
  * ``show NAME``  — pretty-print one profile as JSON.
  * ``analyze NAME`` — refresh that profile (LLM if available, else
    deterministic).
  * ``analyze-all`` — refresh every known opponent.
  * ``freeze --output PATH`` — write a tournament-safe snapshot.

Friendly errors when the store is empty or no API key set.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from .analyzer import analyze_all, analyze_opponent
from .bundle import freeze_profiles
from .store import DEFAULT_ROOT_ENV, OpponentStore


def _make_store(args: argparse.Namespace) -> OpponentStore:
    return OpponentStore(root=args.store_root) if args.store_root else OpponentStore()


def _print_table(rows: list[dict[str, Any]]) -> None:
    if not rows:
        print("(no opponents)")
        return
    keys = ["name", "games_observed", "confidence", "last_updated", "vote_label"]
    widths = {k: max(len(k), max(len(str(r.get(k, ""))) for r in rows)) for k in keys}
    header = "  ".join(f"{k:<{widths[k]}}" for k in keys)
    print(header)
    print("-" * len(header))
    for r in rows:
        print("  ".join(f"{str(r.get(k, '')):<{widths[k]}}" for k in keys))


def _humanize_ts(ts: float) -> str:
    import datetime as _dt

    return _dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")


def _has_api_key() -> bool:
    return any(
        os.environ.get(k) for k in ("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "AI_GATEWAY_API_KEY")
    )


# ----------------------------- subcommand handlers ----------------------------- #


def cmd_record(args: argparse.Namespace) -> int:
    store = _make_store(args)
    print(f"store root: {store.root}")
    if not store.root.is_dir():
        print(
            "(store root does not exist yet — runs the example with "
            "ObservationCollector to populate it)",
        )
        return 0
    names = store.list_opponents()
    if not names:
        print("(no opponents recorded yet)")
        return 0
    for name in names:
        log = store.log_for(name)
        summary = log.summary()
        print(
            f"  {name:<20}  events={summary['events']}  games={summary['games']}  "
            f"types={summary['type_counts']}"
        )
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    store = _make_store(args)
    names = store.list_opponents()
    if not names:
        print(f"(no opponents in {store.root})")
        return 0
    rows: list[dict[str, Any]] = []
    for name in names:
        profile = store.load_profile(name)
        log_summary = store.log_for(name).summary()
        rows.append({
            "name": name,
            "games_observed": (
                profile.games_observed if profile else log_summary["games"]
            ),
            "confidence": (
                f"{profile.confidence:.2f}" if profile else "?"
            ),
            "last_updated": (
                _humanize_ts(profile.last_updated_at) if profile else "(no profile yet)"
            ),
            "vote_label": (profile.vote_strategy.label if profile else "?"),
        })
    _print_table(rows)
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    store = _make_store(args)
    profile = store.load_profile(args.name)
    if profile is None:
        print(
            f"no profile for {args.name!r}. Run "
            f"'python -m among_them_sdk.opponents analyze {args.name}' first.",
            file=sys.stderr,
        )
        return 1
    if args.summary:
        print(profile.compact_summary())
    else:
        print(json.dumps(profile.model_dump(), indent=2, default=str))
    return 0


def cmd_analyze(args: argparse.Namespace) -> int:
    store = _make_store(args)
    if not store.log_for(args.name).all() and not store.load_profile(args.name):
        print(
            f"no observations yet for {args.name!r} in {store.root}. "
            "Run a game with ObservationCollector first.",
            file=sys.stderr,
        )
        return 1
    use_llm = bool(args.llm) and _has_api_key()
    if args.llm and not _has_api_key():
        print(
            "[warn] --llm requested but no API key set "
            "(OPENAI_API_KEY/ANTHROPIC_API_KEY); using deterministic fallback.",
            file=sys.stderr,
        )
    profile = analyze_opponent(
        args.name,
        store,
        use_llm=use_llm,
        recent_games=args.recent_games,
        model=args.model,
    )
    if args.summary:
        print(profile.compact_summary())
    else:
        print(json.dumps(profile.model_dump(), indent=2, default=str))
    return 0


def cmd_analyze_all(args: argparse.Namespace) -> int:
    store = _make_store(args)
    if not store.list_opponents():
        print(f"(no opponents in {store.root})", file=sys.stderr)
        return 1
    use_llm = bool(args.llm) and _has_api_key()
    if args.llm and not _has_api_key():
        print(
            "[warn] --llm requested but no API key set; using deterministic fallback.",
            file=sys.stderr,
        )
    profiles = analyze_all(
        store,
        use_llm=use_llm,
        recent_games=args.recent_games,
        model=args.model,
    )
    print(f"refreshed {len(profiles)} profile(s) under {store.root}")
    for name, profile in profiles.items():
        print(f"  {name:<20}  conf={profile.confidence:.2f}  {profile.compact_summary()}")
    return 0


def cmd_freeze(args: argparse.Namespace) -> int:
    store = _make_store(args)
    if not store.list_profiles():
        print(
            f"no profiles in {store.root} — run 'analyze-all' first.",
            file=sys.stderr,
        )
        return 1
    out = freeze_profiles(store, args.output)
    print(f"wrote snapshot -> {out}")
    print(f"  size: {out.stat().st_size} bytes")
    return 0


# ----------------------------- argparse ----------------------------- #


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m among_them_sdk.opponents",
        description="Manage cross-game opponent profiles.",
    )
    parser.add_argument(
        "--store-root",
        default=None,
        help=(
            f"Override the store root (defaults to ${DEFAULT_ROOT_ENV} or "
            "~/.among-them/opponents)."
        ),
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_record = sub.add_parser("record", help="show store dir + per-opponent counts")
    p_record.set_defaults(func=cmd_record)

    p_list = sub.add_parser("list", help="list known opponents")
    p_list.set_defaults(func=cmd_list)

    p_show = sub.add_parser("show", help="pretty-print one profile")
    p_show.add_argument("name", help="opponent name")
    p_show.add_argument(
        "--summary",
        action="store_true",
        help="print the one-line compact summary instead of the full JSON",
    )
    p_show.set_defaults(func=cmd_show)

    p_an = sub.add_parser("analyze", help="refresh one opponent's profile")
    p_an.add_argument("name")
    p_an.add_argument(
        "--llm",
        action="store_true",
        help="use the LLM analyzer when an API key is available",
    )
    p_an.add_argument(
        "--recent-games", type=int, default=10, help="restrict analysis to last K games"
    )
    p_an.add_argument(
        "--model", default="gpt-5.5", help="LLM model id (passed to LLM())"
    )
    p_an.add_argument(
        "--summary", action="store_true", help="print the compact summary instead of JSON"
    )
    p_an.set_defaults(func=cmd_analyze)

    p_all = sub.add_parser("analyze-all", help="refresh every known opponent")
    p_all.add_argument("--llm", action="store_true")
    p_all.add_argument("--recent-games", type=int, default=10)
    p_all.add_argument("--model", default="gpt-5.5")
    p_all.set_defaults(func=cmd_analyze_all)

    p_freeze = sub.add_parser(
        "freeze", help="write a tournament-safe snapshot of all profiles"
    )
    p_freeze.add_argument("--output", required=True, type=Path)
    p_freeze.set_defaults(func=cmd_freeze)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.store_root:
        args.store_root = Path(args.store_root).expanduser()
    elif DEFAULT_ROOT_ENV in os.environ:
        args.store_root = Path(os.environ[DEFAULT_ROOT_ENV]).expanduser()
    else:
        args.store_root = None
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())

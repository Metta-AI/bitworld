"""8 SDK policy variants playing each other on a local Among Them server.

What this script does
---------------------

Boots a local ``among_them`` server (no nottoodumb opponents — every
seat is an SDK variant) and spawns 8 :class:`LocalSDKPolicy` players,
one per variant defined in :data:`ARENA_VARIANTS`. Each variant runs in
its own subprocess (see ``_variant_worker.py``); the orchestrator
collects per-variant behavior metrics from worker JSON files and
joins them with the server's final ``scores.json`` to produce a
comparison table.

Why subprocess-per-player
-------------------------

The SDK FFI library (``libevidencebot_v2.dylib``) is a process-wide
singleton with global Nim GC state. Running 8 variants in 8 subprocess
workers — mirroring how the tournament deploys, "one process per
player" — sidesteps any in-process FFI re-entrancy or asyncio loop
conflicts and keeps a crashing variant from taking down the arena.
Each worker opens its own websocket to the same server.

Run::

    cd among_them/sdk
    unset VIRTUAL_ENV && uv sync
    uv run python examples/variant_arena.py --games 5

By default this binds to a random free port and writes per-variant
configs, per-variant metrics, and the final aggregate JSON under
``./logs/variant_arena/<timestamp>/``.

Caveats
-------

See the bottom of the printed comparison table — the server's
``scores.json`` only carries lifetime totals across N games, not per-
game role/win info. The "win rate" columns are best-effort estimates
and noisy at small N. See :func:`_estimate_role_breakdown` for details.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from contextlib import suppress
from pathlib import Path
from typing import Any

# Make sibling helpers importable when run from any cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from _arena_common import (  # noqa: E402, I001
    AMONG_THEM_DIR,
    EXAMPLES_DIR,
    REPO_ROOT,
    SDK_DIR,
    SERVER_BIN,
    SERVER_SRC,
    ExampleError,
    ManagedProc,
    ensure_evidencebot_lib,
    ensure_native_binary,
    pick_free_port,
    start_managed,
    tail_file,
    wait_for_port,
)

# Import the SDK only after sys.path is wired.
sys.path.insert(0, str(SDK_DIR / "src"))

from among_them_sdk import CogamesBundleConfig  # noqa: E402
from among_them_sdk.cogames_config import ModuleSpec  # noqa: E402
from among_them_sdk.live_game import fetch_results_json  # noqa: E402

WORKER_SCRIPT = EXAMPLES_DIR / "_variant_worker.py"


# ----------------------------- variant catalog -------------------------- #
#
# Each variant is a fully-specified ``CogamesBundleConfig`` so the worker
# can rehydrate it from JSON with no Python imports. The mix below is the
# starter set requested in the prompt; treat it as a hypothesis menu —
# real "best variant" findings need many more games than the demo runs.

ARENA_VARIANTS: dict[str, CogamesBundleConfig] = {
    # 1. Defaults all the way down — control to compare everything else against.
    "baseline": CogamesBundleConfig(),
    # 2. High kill eagerness, suppress reports, deceptive chat. Tries to
    # stay quiet as imposter and stir doubt as crew.
    "aggressive_imposter": CogamesBundleConfig(
        instructions=(
            "Kill aggressively. Never report bodies. Skip votes "
            "unless you must blame someone."
        ),
        cognitive={
            "suspicion_threshold": 0.85,
            "report_eagerness": "low",
            "kill_eagerness": "high",
            "chat_tone": "defensive",
            "voting_style": "skip_default",
        },
        modules={
            "reporter": ModuleSpec(type="scripted", params={"eagerness": "low"}),
            "chatter": ModuleSpec(type="scripted", params={"tone": "defensive"}),
            "voter": ModuleSpec(
                type="scripted",
                params={"threshold": 0.85, "follow_majority": False},
            ),
        },
    ),
    # 3. Trust nobody, accuse loudly, report eagerly.
    "paranoid_crewmate": CogamesBundleConfig(
        instructions=(
            "Trust nobody. Report bodies aggressively. Vote on evidence."
        ),
        cognitive={
            "suspicion_threshold": 0.35,
            "report_eagerness": "high",
            "chat_tone": "paranoid",
            "voting_style": "evidence",
        },
        modules={
            "reporter": ModuleSpec(type="scripted", params={"eagerness": "high"}),
            "chatter": ModuleSpec(type="scripted", params={"tone": "paranoid"}),
            "voter": ModuleSpec(type="scripted", params={"threshold": 0.35}),
        },
    ),
    # 4. Only report what we directly witnessed; vote strictly on evidence.
    "evidence_grounded": CogamesBundleConfig(
        instructions="Only vote on evidence. Only report what you see.",
        cognitive={
            "suspicion_threshold": 0.6,
            "report_eagerness": "normal",
            "voting_style": "evidence",
            "follow_majority": False,
        },
        modules={
            "reporter": ModuleSpec(type="scripted", params={"eagerness": "normal"}),
            "voter": ModuleSpec(type="scripted", params={"threshold": 0.7}),
            "chatter": ModuleSpec(type="scripted", params={"tone": "neutral"}),
        },
    ),
    # 5. Friendly, talkative, neutral voting — social pressure as a strategy.
    "social_butterfly": CogamesBundleConfig(
        instructions="Be friendly. Vote with the majority. Avoid the central room.",
        cognitive={
            "chat_tone": "friendly",
            "follow_majority": True,
            "avoid_central_room": True,
        },
        modules={
            "chatter": ModuleSpec(type="scripted", params={"tone": "friendly"}),
            "voter": ModuleSpec(
                type="scripted",
                params={"threshold": 0.55, "follow_majority": True},
            ),
        },
    ),
    # 6. Abstain unless certain. High report threshold, no bandwagoning.
    "conservative_voter": CogamesBundleConfig(
        instructions=(
            "Skip votes unless you have direct evidence. "
            "Don't report unless you saw the kill."
        ),
        cognitive={
            "suspicion_threshold": 0.9,
            "report_eagerness": "low",
            "voting_style": "skip_default",
        },
        modules={
            "voter": ModuleSpec(
                type="scripted",
                params={"threshold": 0.9, "follow_majority": False},
            ),
            "reporter": ModuleSpec(type="scripted", params={"eagerness": "low"}),
            "chatter": ModuleSpec(type="scripted", params={"tone": "neutral"}),
        },
    ),
    # 7. Always vote with the crowd. Low independent suspicion threshold.
    "bandwagoner": CogamesBundleConfig(
        instructions="Vote with the majority. Trust the group.",
        cognitive={
            "suspicion_threshold": 0.4,
            "voting_style": "majority",
            "follow_majority": True,
        },
        modules={
            "voter": ModuleSpec(
                type="scripted",
                params={"threshold": 0.5, "follow_majority": True},
            ),
            "chatter": ModuleSpec(type="scripted", params={"tone": "suspicious"}),
        },
    ),
    # 8. LLM modules where available. Falls back to scripted gracefully when
    # no API keys are set (the LLM* constructors handle this internally).
    "wildcard_llm": CogamesBundleConfig(
        instructions=(
            "Be unpredictable. Read the room. Improvise — sometimes report "
            "aggressively, sometimes hold back. Vote on instinct."
        ),
        cognitive={"chat_tone": "suspicious"},
        modules={
            "voter": ModuleSpec(type="llm", params={"model": "openai/gpt-5.5"}),
            "chatter": ModuleSpec(
                type="llm",
                params={"model": "anthropic/claude-sonnet-4-5", "tone": "suspicious"},
            ),
            "reporter": ModuleSpec(type="scripted", params={"eagerness": "normal"}),
        },
        notes=["LLM modules degrade to scripted on missing API keys."],
    ),
}


# ----------------------------- argparse -------------------------------- #


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Run an 8-way SDK variant tournament on a local Among Them server."
    )
    p.add_argument(
        "--games",
        type=int,
        default=10,
        help="Number of games to play (server `maxGames`). Default: 10.",
    )
    p.add_argument(
        "--server-port",
        type=int,
        default=0,
        help="TCP port to bind the local server to. 0 = pick a free port.",
    )
    p.add_argument(
        "--seed",
        type=int,
        default=42,
        help=(
            "Base RNG seed; per-variant seed = base + variant_index. "
            "Note: directives are deterministic from the variant config; "
            "the seed only affects scripted module RNG paths."
        ),
    )
    p.add_argument(
        "--imposter-count",
        type=int,
        default=2,
        help="Imposters per game. Default: 2.",
    )
    p.add_argument(
        "--tasks-per-player",
        type=int,
        default=6,
        help="Tasks per crewmate. Default: 6.",
    )
    p.add_argument(
        "--vote-timer-ticks",
        type=int,
        default=360,
        help="Voting duration in ticks @ 24fps (360 = 15s). Default: 360.",
    )
    p.add_argument(
        "--variants",
        default=",".join(ARENA_VARIANTS.keys()),
        help=(
            "Comma-separated subset of variant names to run. Must be at "
            "least 8 to satisfy minPlayers=8 — default is all 8."
        ),
    )
    p.add_argument(
        "--rotate-roles",
        action="store_true",
        default=True,
        help=(
            "Documentation-only flag. The server already randomizes role "
            "assignment per game; we set this default-True so users know "
            "rotation is in effect."
        ),
    )
    p.add_argument(
        "--no-spectator",
        action="store_true",
        help="Skip printing the spectator/admin URL block.",
    )
    p.add_argument(
        "--game-timeout",
        type=int,
        default=0,
        help=(
            "Wall-clock seconds before the orchestrator gives up. "
            "0 (default) auto-scales as `max(900, 400 * games)` since one "
            "game routinely takes ~5 minutes when imposters can't finish "
            "tasks fast."
        ),
    )
    p.add_argument(
        "--output",
        default=None,
        help=(
            "Where to write the final aggregate JSON. Default: "
            "./logs/variant_arena/<timestamp>/aggregate.json"
        ),
    )
    p.add_argument(
        "--log-root",
        default=str(REPO_ROOT / "logs" / "variant_arena"),
        help="Directory tree to write per-process .log files into.",
    )
    return p.parse_args()


# ----------------------------- main flow -------------------------------- #


def _selected_variants(raw: str) -> list[str]:
    names = [s.strip() for s in raw.split(",") if s.strip()]
    bad = [n for n in names if n not in ARENA_VARIANTS]
    if bad:
        raise ExampleError(
            f"Unknown variant(s): {bad}. Valid: {sorted(ARENA_VARIANTS)}."
        )
    if len(names) != 8:
        raise ExampleError(
            f"Need exactly 8 variants to fill the 8-player table; got {len(names)}."
        )
    if len(set(names)) != len(names):
        raise ExampleError(f"Duplicate variant names not allowed: {names}.")
    return names


def main() -> int:
    args = parse_args()

    print("=" * 64)
    print("Among Them SDK — 8-variant arena")
    print("=" * 64)

    try:
        variants = _selected_variants(args.variants)
        ensure_evidencebot_lib()
        ensure_native_binary("among_them", SERVER_SRC, SERVER_BIN)
    except ExampleError as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        return 2

    port = args.server_port if args.server_port else pick_free_port()

    ts = time.strftime("%Y%m%d-%H%M%S")
    log_dir = Path(args.log_root) / ts
    log_dir.mkdir(parents=True, exist_ok=True)
    print(f"[setup] logs -> {log_dir}")

    scores_path = log_dir / "scores.json"
    replay_path = log_dir / "replay.bitreplay"
    output_path = Path(args.output) if args.output else log_dir / "aggregate.json"

    procs: list[ManagedProc] = []

    def _terminate_all() -> None:
        for proc in reversed(procs):
            with suppress(Exception):
                proc.stop(timeout=2.0)

    def _signal_handler(sig: int, frame: Any) -> None:  # noqa: ARG001
        print(f"\n[signal] caught {sig}, shutting down...")
        _terminate_all()
        sys.exit(130)

    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    try:
        # ---- Boot the server.
        config = {
            "minPlayers": 8,
            "imposterCount": args.imposter_count,
            "tasksPerPlayer": args.tasks_per_player,
            "voteTimerTicks": args.vote_timer_ticks,
            "maxGames": max(1, args.games),
        }
        server_env = os.environ.copy()
        server_env["COGAME_SAVE_RESULTS_PATH"] = str(scores_path)
        server_env["COGAME_SAVE_REPLAY_PATH"] = str(replay_path)
        server_cmd = [
            str(SERVER_BIN),
            "--address:127.0.0.1",
            f"--port:{port}",
            f"--config:{json.dumps(config)}",
        ]
        print(f"[server] launching on 127.0.0.1:{port} (config={config})")
        server_proc = start_managed(
            "server",
            server_cmd,
            log_dir,
            cwd=AMONG_THEM_DIR,
            env=server_env,
        )
        procs.append(server_proc)

        try:
            wait_for_port("127.0.0.1", port, timeout=20.0)
        except ExampleError as exc:
            print(
                f"\nERROR: {exc}\nServer tail:\n"
                f"{tail_file(server_proc.log_path, lines=20)}",
                file=sys.stderr,
            )
            return 3
        print(
            f"[server] OK — listening on 127.0.0.1:{port} "
            f"(PID {server_proc.popen.pid})"
        )

        if not args.no_spectator:
            print("")
            print("  Open in your browser to watch the arena live:")
            print(f"    Spectator : http://127.0.0.1:{port}/client/global.html")
            print(f"    Admin     : http://127.0.0.1:{port}/client/admin.html")
            print(f"    Rewards   : http://127.0.0.1:{port}/client/rewards.html")
            print(f"    Health    : http://127.0.0.1:{port}/healthz")
            print("")

        # ---- Materialize per-variant configs to JSON.
        config_paths: dict[str, Path] = {}
        metrics_paths: dict[str, Path] = {}
        for variant_name in variants:
            cfg = ARENA_VARIANTS[variant_name]
            cfg_path = log_dir / f"variant_{variant_name}.json"
            cfg_path.write_text(cfg.model_dump_json(indent=2, exclude_none=True) + "\n")
            config_paths[variant_name] = cfg_path
            metrics_paths[variant_name] = log_dir / f"metrics_{variant_name}.json"

        # ---- Spawn 8 worker subprocesses.
        worker_procs: list[ManagedProc] = []
        for i, variant_name in enumerate(variants):
            worker_cmd = [
                sys.executable,
                str(WORKER_SCRIPT),
                "--name",
                variant_name,
                "--host",
                "127.0.0.1",
                "--port",
                str(port),
                "--config",
                str(config_paths[variant_name]),
                "--metrics-out",
                str(metrics_paths[variant_name]),
            ]
            if variant_name == "wildcard_llm":
                worker_cmd.append("--check-llm-key")
            worker_env = os.environ.copy()
            # Keep PYTHONPATH in sync so subprocesses find the SDK src dir
            # without needing `uv run` overhead per worker.
            worker_env["PYTHONPATH"] = (
                f"{SDK_DIR / 'src'}{os.pathsep}{worker_env.get('PYTHONPATH', '')}"
            )
            proc = start_managed(
                f"worker_{i}_{variant_name}",
                worker_cmd,
                log_dir,
                env=worker_env,
            )
            procs.append(proc)
            worker_procs.append(proc)
            print(
                f"[worker {i + 1}/8] {variant_name} "
                f"(PID {proc.popen.pid}) -> ws://127.0.0.1:{port}"
            )

        # ---- Wait for the server to finish or for a global timeout.
        game_timeout = args.game_timeout if args.game_timeout > 0 else max(
            900, 400 * args.games
        )
        deadline = time.monotonic() + game_timeout
        last_status = 0.0
        while True:
            if not server_proc.is_alive():
                print(f"[server] exited (rc={server_proc.popen.returncode})")
                break
            if time.monotonic() > deadline:
                print(
                    f"[timeout] arena ran longer than {game_timeout}s; aborting",
                    file=sys.stderr,
                )
                break
            if time.monotonic() - last_status > 30.0:
                alive_workers = sum(1 for p in worker_procs if p.is_alive())
                print(
                    f"[status] server up; workers alive={alive_workers}/8 "
                    f"(deadline in {int(deadline - time.monotonic())}s)"
                )
                last_status = time.monotonic()
            time.sleep(0.5)

        # Once the server is gone, give workers a beat to drain + write
        # metrics. The websocket close should cascade quickly, but the
        # asyncio shutdown path can take a couple seconds per worker —
        # be generous before SIGTERMing. The worker registers a SIGTERM
        # handler so even forced shutdowns flush a partial metrics file.
        drain_deadline = time.monotonic() + 30.0
        for proc in worker_procs:
            remaining = max(1.0, drain_deadline - time.monotonic())
            try:
                proc.popen.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                with suppress(Exception):
                    proc.stop(timeout=5.0)

        # ---- Collect metrics + scores.
        scores = fetch_results_json(str(scores_path))
        per_variant_metrics: dict[str, dict[str, Any]] = {}
        for variant_name in variants:
            mpath = metrics_paths[variant_name]
            if mpath.is_file():
                try:
                    per_variant_metrics[variant_name] = json.loads(mpath.read_text())
                except json.JSONDecodeError as exc:
                    per_variant_metrics[variant_name] = {
                        "name": variant_name,
                        "error": f"metrics_unparseable: {exc!r}",
                    }
            else:
                per_variant_metrics[variant_name] = {
                    "name": variant_name,
                    "error": "metrics_missing",
                }

        aggregate = _build_aggregate(
            variants=variants,
            scores=scores,
            per_variant_metrics=per_variant_metrics,
            games_played=args.games,
            imposter_count=args.imposter_count,
        )

        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(aggregate, indent=2, default=str) + "\n")

        # ---- Print the comparison block.
        print("")
        print("=" * 64)
        print(f"RESULT — {args.games} games, {len(variants)} variants")
        print("=" * 64)
        _print_comparison(aggregate)

        print("")
        print(f"logs:      {log_dir}")
        print(f"scores:    {scores_path}")
        print(f"replay:    {replay_path}")
        print(f"aggregate: {output_path}")

        if scores is None:
            print("\nNOTE: server didn't write scores.json — likely never reached maxGames.")
            return 4
        return 0

    finally:
        _terminate_all()


# ----------------------------- aggregation ------------------------------ #


def _estimate_role_breakdown(
    name: str,
    scores: dict[str, Any] | None,
    games_played: int,
    imposter_count: int,
    total_players: int = 8,
) -> dict[str, Any]:
    """Best-effort per-variant role/win breakdown from the cumulative scores.

    The server's ``scores.json`` only carries lifetime totals + the LAST
    game's win bool — the per-game role/win breakdown is *not exported*
    by ``playerResultsJson`` in the current server. So we compute:

      * ``games_played``   — assumed equal to ``--games`` (all variants
        survive disconnect).
      * ``games_imposter`` — expected value =
        ``games * imposter_count / total_players``. This is the
        statistical expectation under uniform random assignment, NOT the
        actual count.
      * ``games_crew``     — ``games_played - games_imposter``.
      * ``ejected`` and ``killed`` — not surfaced separately by the
        server; lumped into ``deaths_unknown`` for now.

    Anything we can't observe is flagged ``"_estimated": True`` in the
    output JSON.
    """
    if scores is None:
        return {
            "games_played": 0,
            "_estimated": True,
            "_reason": "no scores.json from server",
        }
    names = scores.get("names") or []
    try:
        idx = names.index(name)
    except ValueError:
        return {
            "games_played": 0,
            "_estimated": True,
            "_reason": f"name {name!r} not in scores.json names {names}",
        }

    rewards = scores.get("scores") or []
    wins = scores.get("win") or []
    tasks = scores.get("tasks") or []
    kills = scores.get("kills") or []

    reward = int(rewards[idx]) if idx < len(rewards) else 0
    last_game_win = bool(wins[idx]) if idx < len(wins) else False
    total_tasks = int(tasks[idx]) if idx < len(tasks) else 0
    total_kills = int(kills[idx]) if idx < len(kills) else 0

    # Statistical expectation of how many games this variant played as
    # imposter under uniform random role assignment.
    expected_imposter_games = (
        games_played * imposter_count / max(1, total_players)
    )
    expected_crew_games = games_played - expected_imposter_games

    return {
        "games_played": games_played,
        "expected_imposter_games": round(expected_imposter_games, 2),
        "expected_crew_games": round(expected_crew_games, 2),
        "total_reward": reward,
        "total_tasks": total_tasks,
        "total_kills": total_kills,
        "last_game_win": last_game_win,
        "_estimated": True,
        "_reason": (
            "server scores.json does not surface per-game role/win; only the "
            "last-game win bool and lifetime totals are available."
        ),
    }


def _build_aggregate(
    *,
    variants: list[str],
    scores: dict[str, Any] | None,
    per_variant_metrics: dict[str, dict[str, Any]],
    games_played: int,
    imposter_count: int,
) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    for variant_name in variants:
        metrics = per_variant_metrics.get(variant_name, {})
        engine = metrics.get("engine_stats") or {}
        role = _estimate_role_breakdown(
            variant_name,
            scores,
            games_played=games_played,
            imposter_count=imposter_count,
            total_players=len(variants),
        )

        # Heuristic overall "rate" using lifetime kills + tasks per game.
        # NOT a true win rate (see caveats); we surface kills/game and
        # tasks/game as the actually-measurable behavior signals.
        denom = max(1, role.get("games_played", 0) or 1)
        kills_per_game = (role.get("total_kills", 0) or 0) / denom
        tasks_per_game = (role.get("total_tasks", 0) or 0) / denom
        reward_per_game = (role.get("total_reward", 0) or 0) / denom

        rows.append(
            {
                "variant": variant_name,
                "games": role.get("games_played", games_played),
                "expected_imposter_games": role.get("expected_imposter_games"),
                "expected_crew_games": role.get("expected_crew_games"),
                "total_reward": role.get("total_reward"),
                "reward_per_game": round(reward_per_game, 2),
                "total_kills": role.get("total_kills"),
                "kills_per_game": round(kills_per_game, 2),
                "total_tasks": role.get("total_tasks"),
                "tasks_per_game": round(tasks_per_game, 2),
                "last_game_win": role.get("last_game_win"),
                "frames_received": metrics.get("frames_received"),
                "masks_sent": metrics.get("masks_sent"),
                "engine_ticks_seen": engine.get("ticks_seen"),
                "engine_reports_passed": engine.get("reports_passed"),
                "engine_reports_suppressed": engine.get("reports_suppressed"),
                "engine_voter_advisories": len(
                    engine.get("voter_advisories") or []
                ),
                "engine_chatter_advisories": len(
                    engine.get("chatter_advisories") or []
                ),
                "directives": metrics.get("directives"),
                "worker_error": metrics.get("error"),
            }
        )

    rows.sort(key=lambda r: (r["reward_per_game"] or 0.0), reverse=True)

    return {
        "schema_version": 1,
        "generated_at": time.time(),
        "games_played": games_played,
        "imposter_count": imposter_count,
        "total_variants": len(variants),
        "raw_scores": scores,
        "rows": rows,
        "caveats": [
            (
                "scores.json is written ONCE at maxGames; `last_game_win` is "
                "only the final game's outcome. Per-game wins are not exported."
            ),
            (
                "`expected_imposter_games` is the statistical expectation "
                "under uniform role assignment, not an observed count. With "
                "imposterCount=2 and 8 players, expected = N * 0.25."
            ),
            (
                "`reward_per_game` is the closest thing to win rate the server "
                "currently surfaces (WinReward is ~100, kill/task rewards are "
                "single digits). Treat as a proxy until the server exposes "
                "per-game role/win telemetry."
            ),
        ],
    }


# ----------------------------- printing --------------------------------- #


def _print_comparison(aggregate: dict[str, Any]) -> None:
    rows: list[dict[str, Any]] = aggregate["rows"]
    headers = [
        ("variant", 22, "<"),
        ("games", 5, ">"),
        ("imp_g≈", 6, ">"),
        ("crew_g≈", 7, ">"),
        ("reward", 6, ">"),
        ("rwd/g", 6, ">"),
        ("kills", 5, ">"),
        ("k/g", 5, ">"),
        ("tasks", 5, ">"),
        ("t/g", 5, ">"),
        ("rep_pass", 8, ">"),
        ("rep_supp", 8, ">"),
        ("vot_adv", 7, ">"),
        ("cht_adv", 7, ">"),
        ("err", 4, "<"),
    ]
    fmt_header = "  " + "  ".join(f"{h[0]:{h[2]}{h[1]}}" for h in headers)
    print(fmt_header)
    print("  " + "-" * (len(fmt_header) - 2))

    def _val(row: dict[str, Any], key: str, default: Any = "?") -> str:
        v = row.get(key)
        if v is None:
            return str(default)
        return str(v)

    keys = [
        "variant",
        "games",
        "expected_imposter_games",
        "expected_crew_games",
        "total_reward",
        "reward_per_game",
        "total_kills",
        "kills_per_game",
        "total_tasks",
        "tasks_per_game",
        "engine_reports_passed",
        "engine_reports_suppressed",
        "engine_voter_advisories",
        "engine_chatter_advisories",
        "worker_error",
    ]
    for row in rows:
        cells = []
        for (header, width, align), key in zip(headers, keys, strict=False):
            del header
            v = _val(row, key, "" if key == "worker_error" else "?")
            if key == "worker_error" and v:
                v = "Y"
            cells.append(f"{v:{align}{width}}")
        print("  " + "  ".join(cells))

    if rows:
        best = rows[0]
        print("")
        print(
            f"  best (by reward/game): {best['variant']!r} "
            f"reward={best['total_reward']} ({best['reward_per_game']}/game)"
        )

    print("")
    print("  caveats:")
    for c in aggregate["caveats"]:
        print(f"    - {c}")


if __name__ == "__main__":
    raise SystemExit(main())

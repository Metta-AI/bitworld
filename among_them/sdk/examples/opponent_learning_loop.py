"""End-to-end demo of the opponent-learning loop.

What this script does
---------------------

Plays K games against the standard 7 ``nottoodumb`` opponents and runs
the cross-game capture → analyze → consume → freeze loop:

1. Boot a fresh :class:`OpponentStore` under a per-run temp dir (so the
   demo never pollutes the user's real ``~/.among-them/opponents``).
2. For each of K games:
   * Build an :class:`ObservationCollector` for the game.
   * Run a game and feed observations through the collector's hooks.
   * After the game, call :func:`analyze_all` and pretty-print how each
     opponent's profile evolved (label transitions, confidence deltas).
3. After the final game, dump the full profile table.
4. Optionally call :func:`freeze_profiles` to write the bundleable
   snapshot for tournament use.

Two modes
---------

``--mode simulated`` (default, hermetic, ~1s per game)
    Synthesizes opponent observations using deterministic per-bot
    behavior templates that mirror what we observe from real
    ``nottoodumb`` players. Lets the loop demonstrate end-to-end without
    needing the Nim server + 7 subprocess opponents to be built.

``--mode real`` (heavy, ~minutes per game)
    Spins up the actual local server + 7 ``nottoodumb`` subprocess
    opponents using the orchestration helpers from ``_arena_common``,
    drives the SDK player via :class:`LocalSDKPolicy` over WebSocket,
    and post-game uses the server's ``scores.json`` for role/alive
    info plus a regex-based parse of the opponents' subprocess stdout
    logs for chat lines. (The local server doesn't expose a
    structured chat-with-author stream over the per-player socket; see
    DESIGN.md §8 / Phase 4.)

Both modes share the *same* capture / analyze / consume code path.

Run::

    cd among_them/sdk

    # Hermetic, fast, no API keys needed:
    uv run python examples/opponent_learning_loop.py --games 3 --no-llm

    # Real games (requires nim toolchain + ~5min per game):
    uv run python examples/opponent_learning_loop.py --games 2 --mode real
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import random
import re
import shutil
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Make sibling helpers importable when run from any cwd.
_THIS_FILE = Path(__file__).resolve()
sys.path.insert(0, str(_THIS_FILE.parent))

# ----- Wire SDK src into sys.path *before* importing among_them_sdk so
# this script works under `uv run python examples/...` from `sdk/`.
SDK_DIR = _THIS_FILE.parent.parent
sys.path.insert(0, str(SDK_DIR / "src"))

from among_them_sdk import (  # noqa: E402
    Agent,
    LLMVoter,
    ObservationCollector,
    OpponentProfile,
    OpponentStore,
    analyze_all,
    freeze_profiles,
)

logging.getLogger("among_them_sdk").setLevel(logging.WARNING)

OPPONENT_NAMES = [f"nottoodumb{i}" for i in range(1, 8)]
SDK_PLAYER_NAME = "sdkbot"


# ----------------------------- arg parsing ----------------------------- #


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=(
            "Run the cross-game opponent-learning loop end-to-end. "
            "Captures opponent observations, analyzes them into typed "
            "profiles, and shows how profiles evolve across games."
        )
    )
    p.add_argument("--games", type=int, default=5, help="Number of games to play (default 5).")
    p.add_argument(
        "--mode",
        choices=("simulated", "real"),
        default="simulated",
        help=(
            "simulated (default, hermetic, ~1s/game) or real (Nim server + "
            "7 nottoodumb subprocesses, ~minutes/game)."
        ),
    )
    p.add_argument(
        "--no-llm",
        action="store_true",
        help="Force the deterministic statistical analyzer (skip LLM calls).",
    )
    p.add_argument("--seed", type=int, default=42, help="RNG seed.")
    p.add_argument(
        "--store-root",
        type=Path,
        default=None,
        help=(
            "Where to write observations + profiles. Default: a per-run "
            "temp dir so the demo never pollutes the user's real "
            "~/.among-them/opponents. Pass an explicit path to keep them "
            "after the run finishes."
        ),
    )
    p.add_argument(
        "--keep-store",
        action="store_true",
        help=(
            "Keep the temp store directory after the run finishes. Implied "
            "when --store-root is set."
        ),
    )
    p.add_argument(
        "--freeze-output",
        type=Path,
        default=None,
        help=(
            "Optional path to write a tournament snapshot (calls "
            "freeze_profiles). Default: no snapshot written."
        ),
    )
    p.add_argument(
        "--real-game-timeout",
        type=int,
        default=300,
        help="(real mode) Wall-clock seconds per game before giving up.",
    )
    return p.parse_args()


# ----------------------------- simulated mode ----------------------------- #
#
# Synthetic per-bot personalities. Each entry deterministically generates
# chat/vote/kill rows so the analyzer has plausible signal to work with.
# These templates mirror the actual `variant_arena.py` variants — a
# bandwagoner *behaves* like a bandwagoner, etc. — so the demo's profile
# output is reasonable to a human reader.


@dataclass
class _SimPersona:
    name: str
    chat_rate: float  # fraction of meetings they speak in
    skip_rate: float
    follow_majority: bool
    chat_templates: list[str]
    accuses_targets: list[str] = field(default_factory=list)
    is_imposter_chance: float = 0.25  # ~ imposterCount/totalPlayers default


SIM_PERSONAS: dict[str, _SimPersona] = {
    "nottoodumb1": _SimPersona(
        name="nottoodumb1",
        chat_rate=0.7,
        skip_rate=0.1,
        follow_majority=False,
        chat_templates=[
            "Saw {target} near the body. Suspicious.",
            "I was on tasks. {target} is sus.",
            "Vote {target}.",
        ],
        accuses_targets=["sdkbot", "nottoodumb3"],
    ),
    "nottoodumb2": _SimPersona(
        name="nottoodumb2",
        chat_rate=0.3,
        skip_rate=0.6,
        follow_majority=True,
        chat_templates=["I have nothing.", "skip", "no info"],
    ),
    "nottoodumb3": _SimPersona(
        name="nottoodumb3",
        chat_rate=0.55,
        skip_rate=0.2,
        follow_majority=True,
        chat_templates=[
            "Going with the group on {target}.",
            "{target} seems likely.",
            "Anyone else see {target}?",
        ],
        accuses_targets=["nottoodumb1"],
    ),
    "nottoodumb4": _SimPersona(
        name="nottoodumb4",
        chat_rate=0.85,
        skip_rate=0.05,
        follow_majority=False,
        chat_templates=[
            "It's not me. I was doing tasks.",
            "Don't pin this on me, I didn't do it.",
            "wasn't me, vent watcher",
        ],
    ),
    "nottoodumb5": _SimPersona(
        name="nottoodumb5",
        chat_rate=0.4,
        skip_rate=0.3,
        follow_majority=False,
        chat_templates=[
            "Trust no one. {target} could be anyone.",
            "Could be {target}.",
            "Watch each other carefully.",
        ],
        accuses_targets=["sdkbot"],
    ),
    "nottoodumb6": _SimPersona(
        name="nottoodumb6",
        chat_rate=0.6,
        skip_rate=0.1,
        follow_majority=True,
        chat_templates=["Going with the majority on {target}.", "voting {target}"],
    ),
    "nottoodumb7": _SimPersona(
        name="nottoodumb7",
        chat_rate=0.2,
        skip_rate=0.7,
        follow_majority=False,
        chat_templates=["skip", "no", "nothing useful"],
    ),
}


def _simulate_one_game(
    *,
    game_id: str,
    rng: random.Random,
    collector: ObservationCollector,
) -> dict[str, Any]:
    """Drive one simulated game's worth of observations into the collector."""
    n_meetings = rng.randint(2, 4)
    imposter_pool = list(OPPONENT_NAMES)
    rng.shuffle(imposter_pool)
    imposters = imposter_pool[:2]
    crew = [n for n in OPPONENT_NAMES if n not in imposters]

    # Seed kills first so chat can reference victims.
    kill_count = rng.randint(0, 2)
    victims: list[str] = []
    for _ in range(kill_count):
        if not crew:
            break
        victim = rng.choice(crew)
        attacker = rng.choice(imposters)
        # Hook payload — collector translates it into kill + killed rows.
        collector.hooks.call(
            "on_kill",
            {"actor": attacker, "target": victim, "tick": rng.randint(50, 1500)},
        )
        crew.remove(victim)
        victims.append(victim)

    for meeting in range(1, n_meetings + 1):
        # Chat phase: each persona may emit a templated line.
        for name in OPPONENT_NAMES:
            if name in victims:
                continue
            persona = SIM_PERSONAS[name]
            if rng.random() > persona.chat_rate:
                continue
            target = (
                rng.choice(persona.accuses_targets) if persona.accuses_targets else (
                    rng.choice(OPPONENT_NAMES + [SDK_PLAYER_NAME])
                )
            )
            template = rng.choice(persona.chat_templates)
            text = template.format(target=target)
            collector.hooks.call(
                "on_message",
                {
                    "actor": name,
                    "text": text,
                    "meeting": meeting,
                    "tick": meeting * 1000 + rng.randint(0, 200),
                },
            )

        # Vote phase: most-mentioned name in chat is the de-facto majority.
        majority = rng.choice(OPPONENT_NAMES + [SDK_PLAYER_NAME, None])  # type: ignore[arg-type]
        for name in OPPONENT_NAMES:
            if name in victims:
                continue
            persona = SIM_PERSONAS[name]
            if rng.random() < persona.skip_rate:
                target = None
            elif persona.follow_majority and majority is not None:
                target = majority
            else:
                pool = [
                    n for n in OPPONENT_NAMES + [SDK_PLAYER_NAME] if n != name
                ]
                target = rng.choice(pool)
            collector.hooks.call(
                "on_vote",
                {
                    "actor": name,
                    "target": target,
                    "meeting": meeting,
                    "reason": "simulated",
                    "tick": meeting * 1000 + 500 + rng.randint(0, 50),
                },
            )

    # Game end: stamp roles + alive-at-end into observations.
    roles: dict[str, str] = {}
    for name in OPPONENT_NAMES:
        roles[name] = "imposter" if name in imposters else "crew"
    alive = set(n for n in OPPONENT_NAMES if n not in victims)
    collector.flush_game_end(roles=roles, alive_at_end=alive)
    return {
        "game_id": game_id,
        "n_meetings": n_meetings,
        "imposters": imposters,
        "victims": victims,
    }


# ----------------------------- real mode ----------------------------- #
#
# Real-game orchestration. This path mirrors examples/eight_player_game.py
# but instead of just running one game, it loops K times, captures each
# game's per-opponent observations from the server's scores.json (roles
# + alive) and from per-bot subprocess stdout logs (chat lines).
#
# Why per-bot stdout? The local server doesn't surface a
# chat-with-author stream over the SDK's per-player WebSocket. Until
# DESIGN.md §8 (Phase 4 /global subscription) lands, the cleanest
# observation channel for chat is the per-bot subprocess log. The
# nottoodumb player binary writes its own chat sends to stdout. Vote
# choices aren't currently logged either; we record what we *can* see.


_CHAT_LINE_RE = re.compile(
    r"^\[?chat\]?\s*[\":]?\s*(?P<text>.+?)\s*\"?$",
    re.IGNORECASE,
)


def _extract_chat_from_log(path: Path, *, max_lines: int = 5000) -> list[str]:
    """Best-effort grep of a nottoodumb subprocess stdout log for chat sends."""
    if not path.is_file():
        return []
    out: list[str] = []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i > max_lines:
                    break
                # nottoodumb logs vary; accept any line that looks chat-y.
                if "chat" in line.lower() or "say" in line.lower():
                    m = _CHAT_LINE_RE.search(line.strip())
                    if m:
                        text = m.group("text").strip().strip('"')
                        if text:
                            out.append(text)
    except OSError:
        return []
    return out


def _real_game_capture(
    *,
    log_dir: Path,
    bot_names: list[str],
    self_name: str,
    scores: dict[str, Any] | None,
    collector: ObservationCollector,
) -> None:
    """Translate real-game logs + scores.json into ObservationEvents.

    Limitations (documented in the final report's "in-flight architectural
    concerns" section):
      * Vote targets are NOT in the local server's scores.json.
      * Chat author/victim attribution from per-bot stdout is best-effort.
      * Roles + alive are reliably surfaced.
    """
    for name in bot_names:
        log_path = log_dir / f"player_{bot_names.index(name) + 1}_{name}.log"
        chats = _extract_chat_from_log(log_path)
        for i, chat in enumerate(chats[:30]):  # cap per-bot
            collector.hooks.call(
                "on_message",
                {
                    "actor": name,
                    "text": chat,
                    "meeting": (i // 4) + 1,  # rough bucket
                    "tick": i * 100,
                },
            )

    if scores:
        names = scores.get("names") or []
        kills = scores.get("kills") or []
        wins = scores.get("win") or []
        roles: dict[str, str] = {}
        alive: set[str] = set()
        for i, n in enumerate(names):
            if n == self_name:
                continue
            k = int(kills[i]) if i < len(kills) else 0
            roles[n] = "imposter" if k > 0 else "crew"
            # The server's `win` field is per-player win bool for the
            # last game; treat winners as alive proxy.
            if i < len(wins) and bool(wins[i]):
                alive.add(n)
        collector.flush_game_end(roles=roles, alive_at_end=alive)


def _run_real_game(
    *,
    game_index: int,
    seed: int,
    log_root: Path,
    timeout_s: int,
    collector: ObservationCollector,
) -> dict[str, Any]:
    """One real game using _arena_common orchestration.

    Returns a summary dict; raises ``ExampleError`` on orchestration
    failure. Imports orchestration helpers lazily so the simulated
    mode never pays the import cost.
    """
    from _arena_common import (  # noqa: PLC0415
        AMONG_THEM_DIR,
        NOTTOODUMB_BIN,
        NOTTOODUMB_SRC,
        REPO_ROOT,
        SERVER_BIN,
        SERVER_SRC,
        ExampleError,
        ManagedProc,
        ensure_evidencebot_lib,
        ensure_native_binary,
        pick_free_port,
        start_managed,
        wait_for_port,
    )

    from among_them_sdk import LiveGame, LocalSDKPolicy  # noqa: PLC0415
    from among_them_sdk.live_game import fetch_results_json  # noqa: PLC0415

    ensure_evidencebot_lib()
    ensure_native_binary("among_them", SERVER_SRC, SERVER_BIN)
    ensure_native_binary("nottoodumb", NOTTOODUMB_SRC, NOTTOODUMB_BIN)

    port = pick_free_port()
    log_dir = log_root / f"game-{game_index:02d}"
    log_dir.mkdir(parents=True, exist_ok=True)
    scores_path = log_dir / "scores.json"
    replay_path = log_dir / "replay.bitreplay"

    procs: list[ManagedProc] = []

    config = {
        "minPlayers": 8,
        "imposterCount": 2,
        "tasksPerPlayer": 4,
        "voteTimerTicks": 240,
        "maxGames": 1,
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
    print(f"  [game {game_index}] server -> 127.0.0.1:{port}")
    server_proc = start_managed(
        "server", server_cmd, log_dir, cwd=AMONG_THEM_DIR, env=server_env
    )
    procs.append(server_proc)

    try:
        wait_for_port("127.0.0.1", port, timeout=20.0)
    except ExampleError:
        for proc in reversed(procs):
            try:
                proc.stop(timeout=2.0)
            except Exception:
                pass
        raise

    bot_names: list[str] = []
    for i in range(1, 8):
        bot_name = f"nottoodumb{i}"
        bot_names.append(bot_name)
        bot_cmd = [
            str(NOTTOODUMB_BIN),
            "--address:127.0.0.1",
            f"--port:{port}",
            f"--name:{bot_name}",
        ]
        proc = start_managed(
            f"player_{i}_{bot_name}",
            bot_cmd,
            log_dir,
            cwd=NOTTOODUMB_BIN.parent,
        )
        procs.append(proc)

    time.sleep(0.5)

    sdk_policy = LocalSDKPolicy()
    live = LiveGame(
        host="127.0.0.1", port=port, name=SDK_PLAYER_NAME, max_ticks=8000,
        connect_timeout=15.0,
    )

    import threading  # noqa: PLC0415

    result_holder: dict[str, Any] = {}

    def _run_sdk() -> None:
        try:
            r, t = live.run_local_sdk_policy(sdk_policy)
            result_holder["result"] = r
            result_holder["transcript"] = t
        except Exception as exc:
            result_holder["error"] = exc

    sdk_thread = threading.Thread(target=_run_sdk, daemon=True)
    sdk_thread.start()

    deadline = time.monotonic() + timeout_s
    while server_proc.is_alive() and sdk_thread.is_alive():
        if time.monotonic() > deadline:
            print(f"  [game {game_index}] timeout after {timeout_s}s; stopping")
            break
        time.sleep(0.5)

    sdk_thread.join(timeout=5.0)
    for proc in reversed(procs):
        try:
            proc.stop(timeout=2.0)
        except Exception:
            pass

    scores = fetch_results_json(str(scores_path))
    _real_game_capture(
        log_dir=log_dir,
        bot_names=bot_names,
        self_name=SDK_PLAYER_NAME,
        scores=scores,
        collector=collector,
    )
    _ = REPO_ROOT  # explicit silence for unused import
    _ = LLMVoter  # silence unused warning when --no-llm
    return {
        "game_index": game_index,
        "scores": scores,
        "log_dir": str(log_dir),
    }


# ----------------------------- diff printing ----------------------------- #


def _profile_diff_line(
    name: str,
    prior: OpponentProfile | None,
    fresh: OpponentProfile,
) -> str:
    """One-line "what changed" summary for the per-game printout."""
    if prior is None or prior.games_observed == 0:
        return (
            f"  {name:<14}  NEW  vote={fresh.vote_strategy.label} "
            f"(conf={fresh.confidence:.2f}, n={fresh.games_observed})"
        )
    bits: list[str] = []
    if prior.vote_strategy.label != fresh.vote_strategy.label:
        bits.append(
            f"vote: {prior.vote_strategy.label} -> {fresh.vote_strategy.label}"
        )
    dconf = fresh.confidence - prior.confidence
    if abs(dconf) >= 0.01:
        bits.append(f"conf: {prior.confidence:.2f}->{fresh.confidence:.2f}")
    if fresh.games_observed > prior.games_observed:
        bits.append(f"games: {prior.games_observed}->{fresh.games_observed}")
    summary = ", ".join(bits) or "stable"
    return f"  {name:<14}  {summary}"


def _print_full_table(profiles: dict[str, OpponentProfile]) -> None:
    if not profiles:
        print("(no opponents in store)")
        return
    print("")
    headers = ("name", "n", "conf", "vote", "skip", "maj", "chat_rate", "tones")
    widths = (14, 4, 5, 18, 5, 5, 9, 28)
    line = "  ".join(f"{h:<{w}}" for h, w in zip(headers, widths, strict=False))
    print(line)
    print("-" * len(line))
    for name in sorted(profiles):
        p = profiles[name]
        cells = (
            name,
            str(p.games_observed),
            f"{p.confidence:.2f}",
            p.vote_strategy.label,
            f"{p.vote_strategy.skip_rate:.0%}",
            f"{p.vote_strategy.follow_majority_rate:.0%}",
            f"{p.chat_style.chat_rate:.0%}",
            ",".join(p.chat_style.tone_descriptors[:3]),
        )
        print("  ".join(f"{str(c):<{w}}" for c, w in zip(cells, widths, strict=False)))


# ----------------------------- main loop ----------------------------- #


def main() -> int:
    args = parse_args()

    if args.store_root is not None:
        store_root = Path(args.store_root).expanduser()
        store_root.mkdir(parents=True, exist_ok=True)
        cleanup_dir = None
    else:
        store_root = Path(tempfile.mkdtemp(prefix="opponent-loop-"))
        cleanup_dir = None if args.keep_store else store_root
    print("=" * 64)
    print("Among Them SDK — opponent learning loop")
    print("=" * 64)
    print(f"mode:        {args.mode}")
    print(f"games:       {args.games}")
    print(f"store root:  {store_root}")
    print(f"analyzer:    {'deterministic (no-llm)' if args.no_llm else 'LLM-with-fallback'}")

    rng = random.Random(args.seed)
    store = OpponentStore(root=store_root)

    real_log_root = (
        store_root / "real_games"
        if args.mode == "real"
        else None
    )
    if real_log_root:
        real_log_root.mkdir(parents=True, exist_ok=True)

    prior_profiles: dict[str, OpponentProfile] = {}
    last_results: list[dict[str, Any]] = []

    try:
        for game_idx in range(1, args.games + 1):
            print("")
            print(f"--- game {game_idx}/{args.games} ---")
            game_id = f"sim-{uuid.uuid4().hex[:6]}" if args.mode == "simulated" else (
                f"real-{game_idx:02d}-{uuid.uuid4().hex[:6]}"
            )
            collector = ObservationCollector(
                store=store,
                game_id=game_id,
                self_id=SDK_PLAYER_NAME,
                known_opponents=list(OPPONENT_NAMES) + [SDK_PLAYER_NAME],
            )
            if args.mode == "simulated":
                summary = _simulate_one_game(
                    game_id=game_id,
                    rng=rng,
                    collector=collector,
                )
                print(
                    f"  imposters={summary['imposters']} victims={summary['victims']}"
                )
            else:
                summary = _run_real_game(
                    game_index=game_idx,
                    seed=args.seed + game_idx,
                    log_root=real_log_root or store_root,
                    timeout_s=args.real_game_timeout,
                    collector=collector,
                )
                if summary.get("scores"):
                    print(f"  scores.json: {Path(summary['log_dir']) / 'scores.json'}")
            last_results.append(summary)

            stats = collector.stats()
            print(
                f"  captured: chats={stats['chats_observed']}, "
                f"votes={stats['votes_observed']}, "
                f"kills={stats['kills_observed']}"
            )

            print("  analyzing ...")
            fresh_profiles = analyze_all(
                store,
                use_llm=not args.no_llm,
                recent_games=10,
            )
            for name in sorted(fresh_profiles):
                prior = prior_profiles.get(name)
                fresh = fresh_profiles[name]
                print(_profile_diff_line(name, prior, fresh))
            prior_profiles = fresh_profiles

        # ---- Final printout. ---- #
        print("")
        print("=" * 64)
        print("FINAL PROFILES")
        print("=" * 64)
        final_profiles = store.list_profiles()
        _print_full_table(final_profiles)

        if args.freeze_output:
            snapshot = freeze_profiles(store, args.freeze_output)
            print("")
            print(f"snapshot: {snapshot} ({snapshot.stat().st_size} bytes)")

        # Demonstrate consumer wiring: build an Agent with the live
        # store's profiles (LLMVoter picks them up automatically).
        print("")
        print("Consumer wiring demo:")
        agent = Agent.create(
            voter=LLMVoter(),
            opponent_profiles=final_profiles,
            use_llm_for_instructions=False,
            load_opponent_profiles=False,
        )
        injected = (
            agent.voter.opponent_profiles
            if isinstance(agent.voter, LLMVoter)
            else None
        )
        n_inj = len(injected) if injected else 0
        print(
            f"  Agent built; LLMVoter has {n_inj} opponent profile(s) loaded "
            f"(injects compact summaries into LLM prompts at vote time)."
        )

        print("")
        print(f"observations + profiles persist at: {store_root}")
        print("Inspect via: python -m among_them_sdk.opponents list "
              f"--store-root {store_root}")

        return 0
    finally:
        if cleanup_dir is not None and not args.keep_store:
            # Only auto-clean when the user didn't supply --store-root and
            # didn't ask us to keep the temp dir. Surface the final
            # location either way.
            print("")
            print(f"(temp store at {cleanup_dir}; pass --keep-store to retain)")
            shutil.rmtree(cleanup_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())

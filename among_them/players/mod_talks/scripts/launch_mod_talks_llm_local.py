#!/usr/bin/env -S uv run
"""Launch a local AmongThem game with mod_talks bots and the global observer.

Mirrors `cogames-agents/scripts/launch_amongthem_cyborg_llm_observer.py` but
points at our `amongthem_policy.AmongThemPolicy` (mod_talks) instead of the
cyborg policy. Uses metta's `bitworld_runner.run_bitworld_episode` so the
run configuration exactly matches what the cogames tournament worker does.

Prereqs:
  * Built server:   `nim c -d:release -o:among_them/among_them among_them/among_them.nim`
  * Built library:  `MODULABOT_LLM=1 python3 among_them/players/mod_talks/build_modulabot.py`
  * metta venv:     uv-managed at ~/coding/metta/.venv (has mettagrid + anthropic)
  * AWS SSO:        `aws sso login --profile softmax` within the last 12 h

Run:
  ~/coding/metta/.venv/bin/python \
    among_them/players/mod_talks/scripts/launch_mod_talks_llm_local.py \
    --port 8081

Environment variables consumed by the policy (set before running):

  AWS_PROFILE=softmax                      # routes AnthropicBedrock through SSO
  AWS_REGION=us-east-1
  CLAUDE_CODE_USE_BEDROCK=1
  # — OR, for direct Anthropic API:
  ANTHROPIC_API_KEY=sk-ant-...

  MODTALKS_LLM_MODEL=<override>            # optional
  MODTALKS_LLM_DISABLE=1                   # kill switch (run without LLM)
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
import webbrowser
from pathlib import Path
from urllib.parse import urlencode

REPO_ROOT = Path(__file__).resolve().parents[4]
MOD_TALKS_DIR = Path(__file__).resolve().parents[1]
COGAMES_DIR = MOD_TALKS_DIR / "cogames"

# The policy file isn't on sys.path by default. Add its dir so
# `class_path="amongthem_policy.AmongThemPolicy"` resolves inside the
# metta loader — same trick the cyborg script relies on implicitly via
# its cogames-agents install.
sys.path.insert(0, str(COGAMES_DIR))

from mettagrid import MettaGridConfig  # noqa: E402
from mettagrid.bitworld import (  # noqa: E402
    BITWORLD_AMONG_THEM_IMPOSTER_COOLDOWN_TICKS,
    BITWORLD_AMONG_THEM_IMPOSTER_COUNT,
    BITWORLD_AMONG_THEM_PLAYER_COUNT,
    BITWORLD_AMONG_THEM_TASKS_PER_PLAYER,
    BITWORLD_AMONG_THEM_VOTE_TIMER_TICKS,
)
from mettagrid.runner import bitworld_runner  # noqa: E402
from mettagrid.runner.types import PureSingleEpisodeJob  # noqa: E402


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a local AmongThem game with mod_talks + Anthropic-backed LLM talk."
    )
    parser.add_argument("--port", type=int, default=8081)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--browser-host", default="localhost")
    parser.add_argument("--players", type=int, default=BITWORLD_AMONG_THEM_PLAYER_COUNT)
    parser.add_argument("--imposters", type=int, default=BITWORLD_AMONG_THEM_IMPOSTER_COUNT)
    parser.add_argument(
        "--tasks-per-player",
        type=int,
        default=BITWORLD_AMONG_THEM_TASKS_PER_PLAYER,
    )
    parser.add_argument(
        "--imposter-cooldown-ticks",
        type=int,
        default=BITWORLD_AMONG_THEM_IMPOSTER_COOLDOWN_TICKS,
    )
    parser.add_argument(
        "--vote-timer-ticks",
        type=int,
        default=BITWORLD_AMONG_THEM_VOTE_TIMER_TICKS,
    )
    parser.add_argument("--max-steps", type=int, default=12000)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument(
        "--binary",
        type=Path,
        default=REPO_ROOT / "among_them" / "among_them",
        help="Path to the compiled among_them server.",
    )
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--no-llm", action="store_true",
                        help="Set MODTALKS_LLM_DISABLE=1 (baseline-only run).")
    parser.add_argument("--observer-delay", type=float, default=6.0,
                        help="Seconds to keep observer open before agents connect.")
    parser.add_argument("--startup-delay", type=float, default=1.0)
    parser.add_argument(
        "--observer-reconnect-seconds",
        type=float,
        default=1.0,
        help="Global observer reconnect interval.",
    )
    parser.add_argument(
        "--replay",
        type=Path,
        default=None,
        help="Optional replay output (file://) path.",
    )
    return parser.parse_args()


def _install_fixed_port_server(args: argparse.Namespace) -> None:
    """Patches bitworld_runner to honor --port/--host and open an
    observer URL, mirroring launch_amongthem_cyborg_llm_observer.py."""

    def start_server_on_requested_port(
        binary_path: Path,
        config: bitworld_runner.BitWorldConfig,
        replay_path: Path | None = None,
    ):
        config.host = args.host
        config.port = args.port
        server_proc = bitworld_runner._start_server(binary_path, config, replay_path)
        time.sleep(args.startup_delay)
        if server_proc.poll() is not None:
            err = b""
            if server_proc.stderr is not None:
                err = server_proc.stderr.read() or b""
            raise RuntimeError(err.decode(errors="replace"))
        observer_query = ""
        if args.observer_reconnect_seconds > 0:
            observer_query = "?" + urlencode({"reconnect": args.observer_reconnect_seconds})
        observer_url = (
            f"http://{args.browser_host}:{args.port}/client/global.html{observer_query}"
        )
        print(f"Observer: {observer_url}", flush=True)
        if not args.no_browser:
            webbrowser.open(observer_url)
        time.sleep(args.observer_delay)
        return server_proc

    bitworld_runner._start_server_on_free_port = start_server_on_requested_port


def _policy_uri() -> str:
    # No `://` in the URI → bitworld_runner treats it as a Python
    # class path and calls `initialize_or_load_policy`. sys.path was
    # extended above so `amongthem_policy` resolves.
    return "amongthem_policy.AmongThemPolicy"


def main() -> None:
    args = _parse_args()

    if args.no_llm:
        os.environ["MODTALKS_LLM_DISABLE"] = "1"

    if not args.binary.exists():
        sys.exit(
            f"among_them server binary not found at {args.binary}. "
            f"Build it with: nim c -d:release -o:{args.binary} "
            f"among_them/among_them.nim"
        )

    os.environ.setdefault("BITWORLD_REPO_PATH", str(REPO_ROOT))

    _install_fixed_port_server(args)
    bitworld_runner._find_bitworld_binary = lambda _config: args.binary

    # Quick sanity echo so operators know which credential path is active.
    using_bedrock = (
        os.getenv("CLAUDE_CODE_USE_BEDROCK", "").lower() in {"1", "true", "yes"}
        or not os.getenv("ANTHROPIC_API_KEY")
    )
    print(
        "LLM config: "
        f"bedrock={using_bedrock} "
        f"profile={os.getenv('AWS_PROFILE', '<unset>')} "
        f"region={os.getenv('AWS_REGION', '<unset>')} "
        f"model={os.getenv('MODTALKS_LLM_MODEL', '<default>')} "
        f"disabled={os.getenv('MODTALKS_LLM_DISABLE', '0')}",
        flush=True,
    )

    policy_uri = _policy_uri()
    job = PureSingleEpisodeJob(
        policy_uris=[policy_uri],
        assignments=[0 for _ in range(args.players)],
        env=MettaGridConfig.model_validate(
            {
                "game": {
                    "num_agents": args.players,
                    "max_steps": args.max_steps,
                    "bitworld": {
                        "imposterCount": args.imposters,
                        "tasksPerPlayer": args.tasks_per_player,
                        "imposterCooldownTicks": args.imposter_cooldown_ticks,
                        "voteTimerTicks": args.vote_timer_ticks,
                    },
                }
            }
        ),
        game_engine="bitworld",
        results_uri=None,
        replay_uri=args.replay.expanduser().resolve().as_uri() if args.replay else None,
        seed=args.seed,
    )

    print(f"Policy: {policy_uri}", flush=True)
    print(
        f"Game: players={args.players} imposters={args.imposters} "
        f"tasks_per_player={args.tasks_per_player}",
        flush=True,
    )
    result = bitworld_runner.run_bitworld_episode(job)
    print(f"rewards {result.rewards}", flush=True)
    print(f"steps {result.steps}", flush=True)
    chats = [stats.get("chat.sent", 0.0) for stats in result.stats["agent"]]
    print(f"chat_sent {chats}", flush=True)


if __name__ == "__main__":
    main()

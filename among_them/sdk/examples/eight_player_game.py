"""Run an actual 8-player Among Them game with one SDK-controlled bot.

This script's headline claim
----------------------------

The SDK player in this game uses :class:`among_them_sdk.LocalSDKPolicy`,
which is **the local-dev mirror of the tournament-uploadable
:class:`among_them_sdk.SDKPolicy`**. They share the same
``_DirectiveOverrideEngine``, the same config loader, and the same JSON
schema (``among_them_sdk_config.json``). The only diff is the framing
layer: ``SDKPolicy`` reads frames from mettagrid inside the cogames
Docker validator; ``LocalSDKPolicy`` reads them from a real WebSocket
via :class:`LiveGame`. Same code path, different bytes-source.

That means: when this example does the right thing locally, the
tournament will see the same overrides applied to the same Nim FFI
actions. See ``docs/tournament-submission.md`` for the upload story.

What this script does
---------------------

  * Boots the local ``among_them`` server (the single-game flavour, since
    that's the documented "play one game locally" path — see
    ``among_them/README.md`` and ``among_them/players/how_to_make_a_bot.md``).
  * Spawns 7 ``nottoodumb`` opponents — that's our reference "small but
    competent" baseline. They run as native subprocesses, mirroring what
    ``tools/quick_player nottoodumb --players:7`` would do, except we
    manage them in-process so we can collect logs and tee everything.
  * Connects 1 SDK-driven player over WebSocket via :class:`LiveGame`.
    The player runs ``LocalSDKPolicy`` configured from CLI flags
    (``--instructions``, ``--cognitive``, ``--bundle-config``), giving
    you the same upload-shape directives + module override engine the
    tournament does.

Verify locally::

    cd among_them/sdk
    unset VIRTUAL_ENV && uv sync
    uv run python examples/eight_player_game.py

By default this binds to a random free port (``--server-port 0``) and
writes per-process logs under ``./logs/eight_player_game/<timestamp>/``.

The example script is intentionally chatty up front and quiet during the
match — one summary per round, plus a final result block when the
server quits.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Any

# Resolve the SDK package path so the script can be run with `uv run` from
# either the SDK directory or the repo root without faffing with sys.path.
_THIS_FILE = Path(__file__).resolve()
SDK_DIR = _THIS_FILE.parent.parent
REPO_ROOT = SDK_DIR.parents[1]
AMONG_THEM_DIR = REPO_ROOT / "among_them"

sys.path.insert(0, str(SDK_DIR / "src"))

from among_them_sdk import (  # noqa: E402
    CogamesBundleConfig,
    LiveGame,
    LocalSDKPolicy,
    load_cogames_config,
)
from among_them_sdk import ffi as _ffi  # noqa: E402
from among_them_sdk.cogames_config import ModuleSpec  # noqa: E402
from among_them_sdk.live_game import fetch_results_json  # noqa: E402

SERVER_BIN = REPO_ROOT / "out" / "among_them"
NOTTOODUMB_BIN = REPO_ROOT / "out" / "nottoodumb"
NOTTOODUMB_SRC = AMONG_THEM_DIR / "players" / "nottoodumb" / "nottoodumb.nim"
SERVER_SRC = AMONG_THEM_DIR / "among_them.nim"


# ----------------------------- error class ---------------------------- #


class ExampleError(RuntimeError):
    """Raised for any user-actionable failure."""


# --------------------------- process plumbing -------------------------- #


@dataclass
class ManagedProc:
    """One subprocess plus its tee'd log file. Cleaned up on context exit."""

    name: str
    popen: subprocess.Popen[bytes]
    log_path: Path
    log_fh: IO[bytes]
    pump_thread: threading.Thread | None = None

    def is_alive(self) -> bool:
        return self.popen.poll() is None

    def stop(self, timeout: float = 5.0) -> int | None:
        if self.popen.poll() is None:
            self.popen.terminate()
            try:
                self.popen.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.popen.kill()
                with suppress(subprocess.TimeoutExpired):
                    self.popen.wait(timeout=2.0)
        if self.pump_thread is not None and self.pump_thread.is_alive():
            self.pump_thread.join(timeout=2.0)
        with suppress(Exception):
            self.log_fh.close()
        return self.popen.returncode


def _start_managed(
    name: str,
    cmd: list[str],
    log_dir: Path,
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> ManagedProc:
    log_path = log_dir / f"{name}.log"
    log_fh = log_path.open("wb", buffering=0)
    log_fh.write(f"$ cwd={cwd or os.getcwd()}\n$ {' '.join(cmd)}\n".encode())
    log_fh.flush()
    popen = subprocess.Popen(  # noqa: S603 - intentional subprocess
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )

    def _pump(stream: IO[bytes], sink: IO[bytes]) -> None:
        try:
            for chunk in iter(lambda: stream.read(4096), b""):
                if not chunk:
                    break
                sink.write(chunk)
        except Exception:
            pass

    thread = threading.Thread(
        target=_pump,
        args=(popen.stdout, log_fh),
        name=f"pump-{name}",
        daemon=True,
    )
    thread.start()

    return ManagedProc(
        name=name,
        popen=popen,
        log_path=log_path,
        log_fh=log_fh,
        pump_thread=thread,
    )


# --------------------------- build helpers ---------------------------- #


def ensure_evidencebot_lib() -> Path:
    """Build (or reuse) the evidencebot_v2 .dylib that the SDK FFI loads."""
    if not _ffi.is_available():
        print("[build] evidencebot_v2 library missing; invoking build script...")
        _ffi.build_library(force=False)
    lib = _ffi.library_path()
    if not lib.exists():
        raise ExampleError(
            f"evidencebot_v2 library not found at {lib} after build."
        )
    print(f"[build] evidencebot_v2 lib OK: {lib}")
    return lib


def ensure_native_binary(name: str, src: Path, exe: Path) -> Path:
    """Compile ``src`` into ``exe`` if the exe is missing or outdated.

    Mirrors the ``tools/quick_player`` recipe: just ``nim c -d:release``
    with the source path, and let ``config.nims`` set ``--outdir:./out``.
    """
    if exe.exists() and src.stat().st_mtime <= exe.stat().st_mtime:
        return exe
    if shutil.which("nim") is None:
        raise ExampleError(
            "`nim` not on PATH but the example needs to compile "
            f"{src.name}. Install Nim 2.2.4 (see "
            "among_them/players/build_evidencebot_v2.py) and re-run."
        )
    print(f"[build] compiling {name} from {src.relative_to(REPO_ROOT)}...")
    extra: list[str] = []
    # nottoodumb pulls in whisky which needs SSL even for ws://.
    if name == "nottoodumb":
        extra.append("-d:ssl")
        extra.append("-d:botHeadless")
    cmd = ["nim", "c", "-d:release", *extra, str(src.relative_to(REPO_ROOT))]
    proc = subprocess.run(  # noqa: S603
        cmd,
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise ExampleError(
            f"Failed to compile {name} ({src}). "
            "See output above; ensure Nim 2.2.4 + repo deps via `nimby sync`."
        )
    if not exe.exists():
        raise ExampleError(
            f"`nim c` succeeded for {name} but {exe} was not produced."
        )
    print(f"[build] {name} -> {exe}")
    return exe


# --------------------------- net helpers ------------------------------ #


def pick_free_port() -> int:
    """Reserve a free TCP port and immediately release it.

    Standard race-prone trick (the OS could hand the port to someone else
    before we bind), but it's good enough for a local example. The user
    can pin a port with ``--server-port`` to make repro easier.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for_port(host: str, port: int, *, timeout: float = 30.0) -> None:
    """Block until ``host:port`` accepts a TCP connect, or raise."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.1)
    raise ExampleError(f"Server didn't listen on {host}:{port} within {timeout:.1f}s")


# ------------------------- printing helpers --------------------------- #


def _fmt_results(scores: dict[str, Any] | None) -> str:
    if not scores:
        return "<no scores written — server didn't reach maxGames>"
    names = scores.get("names") or []
    rewards = scores.get("scores") or []
    wins = scores.get("win") or []
    tasks = scores.get("tasks") or []
    kills = scores.get("kills") or []
    rows = []
    for i, name in enumerate(names):
        kill = int(kills[i]) if i < len(kills) else 0
        task = int(tasks[i]) if i < len(tasks) else 0
        win = bool(wins[i]) if i < len(wins) else False
        reward = int(rewards[i]) if i < len(rewards) else 0
        # crude role inference: anyone with kills > 0 is an imposter; a
        # crewmate-team win flips the roles. Best-effort because the
        # results blob doesn't carry the role assignments.
        role = "imposter" if kill > 0 else "crew"
        rows.append((name, role, kill, task, reward, win))
    rows.sort(key=lambda r: (-r[5], -r[4]))
    out = ["", "  player          role      kills  tasks  reward  win"]
    out.append("  " + "-" * 50)
    for name, role, kill, task, reward, win in rows:
        out.append(
            f"  {name:<14}  {role:<8}  {kill:>5}  {task:>5}  {reward:>6}  {'Y' if win else '.'}"
        )
    return "\n".join(out)


# -------------------------- main entrypoint --------------------------- #


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Run a real 8-player Among Them game with 1 SDK bot vs 7 nottoodumb."
    )
    p.add_argument(
        "--instructions",
        default=None,
        help="Natural-language instructions for the bundled config (deterministic regex parse unless --use-llm).",
    )
    p.add_argument(
        "--cognitive",
        action="append",
        default=[],
        help=(
            "Cognitive override (`key=value`, repeatable). Same shape as "
            "`Agent.create(cognitive={...})` and the bundle config's `cognitive` field."
        ),
    )
    p.add_argument(
        "--module",
        action="append",
        default=[],
        help=(
            "Module spec, e.g. `voter=scripted:threshold=0.7`. Repeatable. "
            "Mirrors the bundle config's `modules` table."
        ),
    )
    p.add_argument(
        "--bundle-config",
        type=str,
        default=None,
        help=(
            "Path to a `among_them_sdk_config.json` to use as the SDKPolicy config. "
            "Wins over --instructions / --cognitive / --module."
        ),
    )
    p.add_argument(
        "--rounds-max",
        type=int,
        default=1,
        help="Number of full games to play (server `maxGames`). Default: 1.",
    )
    p.add_argument(
        "--seed",
        type=int,
        default=42,
        help="RNG seed for the SDK agent.",
    )
    p.add_argument(
        "--server-port",
        type=int,
        default=0,
        help="TCP port to bind the local server to. 0 = pick a free port.",
    )
    p.add_argument(
        "--imposter-count",
        type=int,
        default=2,
        help="Number of imposters in the game. Default: 2.",
    )
    p.add_argument(
        "--tasks-per-player",
        type=int,
        default=6,
        help="Tasks per crewmate.",
    )
    p.add_argument(
        "--vote-timer-ticks",
        type=int,
        default=360,
        help="Voting duration (ticks @ 24fps). 360 = 15s.",
    )
    p.add_argument(
        "--max-ticks",
        type=int,
        default=8000,
        help="SDK agent will disconnect after this many frames if the server hasn't already closed. ~5.5 min @ 24fps.",
    )
    p.add_argument(
        "--game-timeout",
        type=int,
        default=600,
        help="Wall-clock seconds before we give up waiting for the game to end.",
    )
    p.add_argument(
        "--use-llm",
        action="store_true",
        help="Allow the SDK to use an LLM to parse `--instructions`. Default off (deterministic regex parse).",
    )
    p.add_argument(
        "--log-root",
        default=str(REPO_ROOT / "logs" / "eight_player_game"),
        help="Directory tree to write per-process .log files into.",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()

    # ---- 0. Build all the things we need.
    print("=" * 60)
    print("Among Them SDK — 8-player real-game example")
    print("=" * 60)

    try:
        ensure_evidencebot_lib()
        ensure_native_binary("among_them", SERVER_SRC, SERVER_BIN)
        ensure_native_binary("nottoodumb", NOTTOODUMB_SRC, NOTTOODUMB_BIN)
    except ExampleError as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        return 2

    # ---- 1. Resolve the listen port.
    port = args.server_port if args.server_port else pick_free_port()

    # ---- 2. Set up the log directory.
    ts = time.strftime("%Y%m%d-%H%M%S")
    log_dir = Path(args.log_root) / ts
    log_dir.mkdir(parents=True, exist_ok=True)
    print(f"[setup] logs -> {log_dir}")

    scores_path = log_dir / "scores.json"
    replay_path = log_dir / "replay.bitreplay"

    procs: list[ManagedProc] = []

    def _terminate_all() -> None:
        for proc in reversed(procs):
            with suppress(Exception):
                proc.stop(timeout=2.0)

    # Make sure Ctrl+C also cleans up children.
    def _signal_handler(sig: int, frame: Any) -> None:  # noqa: ARG001
        print(f"\n[signal] caught {sig}, shutting down...")
        _terminate_all()
        sys.exit(130)

    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    try:
        # ---- 3. Boot the server. Server requires CWD=among_them/ for assets.
        config = {
            "minPlayers": 8,
            "imposterCount": args.imposter_count,
            "tasksPerPlayer": args.tasks_per_player,
            "voteTimerTicks": args.vote_timer_ticks,
            "maxGames": max(1, args.rounds_max),
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
        server_proc = _start_managed(
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
            tail = _tail_file(server_proc.log_path, lines=20)
            print(f"\nERROR: {exc}\nServer tail:\n{tail}", file=sys.stderr)
            return 3
        print(f"[server] OK — listening on 127.0.0.1:{port} (PID {server_proc.popen.pid})")
        print("")
        print("  Open in your browser to watch the game live:")
        print(f"    Spectator : http://127.0.0.1:{port}/client/global.html")
        print(f"    Admin     : http://127.0.0.1:{port}/client/admin.html")
        print(f"    Rewards   : http://127.0.0.1:{port}/client/rewards.html")
        print(f"    Health    : http://127.0.0.1:{port}/healthz")
        print("")

        # ---- 4. Launch 7 nottoodumb opponents.
        bot_procs: list[ManagedProc] = []
        for i in range(1, 8):
            bot_name = f"nottoodumb{i}"
            bot_cmd = [
                str(NOTTOODUMB_BIN),
                "--address:127.0.0.1",
                f"--port:{port}",
                f"--name:{bot_name}",
            ]
            bot_proc = _start_managed(
                f"player_{i}_{bot_name}",
                bot_cmd,
                log_dir,
                cwd=NOTTOODUMB_BIN.parent,
            )
            procs.append(bot_proc)
            bot_procs.append(bot_proc)
            print(f"[player {i}/7] {bot_name} (PID {bot_proc.popen.pid}) -> ws://127.0.0.1:{port}")

        # Give the Nim bots a moment to connect before the SDK joins. The
        # server starts the game once `minPlayers` connect, so order matters
        # only insofar as we want the SDK bot's join log to be the last one.
        time.sleep(1.0)

        # ---- 5. Build the SDKPolicy + the LiveGame runtime.
        # The same `LocalSDKPolicy` shape that ships to cogames as
        # `among_them_sdk.policy.cogames.SDKPolicy` runs here against the
        # local server. Same `_DirectiveOverrideEngine`, same config schema.
        policy_config = _build_policy_config(args)
        sdk_policy = LocalSDKPolicy(config=policy_config)
        print(
            "[sdk]    policy=LocalSDKPolicy "
            f"(directives={_short_directives(sdk_policy.directives)}, "
            f"modules={list(policy_config.modules.keys()) or 'defaults'})"
        )
        print(
            "[sdk]    NOTE: this same policy shape ships as `SDKPolicy` to "
            "cogames — see docs/tournament-submission.md."
        )

        sdk_log = log_dir / "sdk.log"
        sdk_log_fh = sdk_log.open("a", buffering=1)
        sdk_log_fh.write(f"# instructions: {args.instructions!r}\n")
        sdk_log_fh.write(f"# directives: {sdk_policy.directives.model_dump_json()}\n")
        sdk_log_fh.write(f"# bundle config: {policy_config.model_dump_json()}\n")

        live = LiveGame(
            host="127.0.0.1",
            port=port,
            name="sdkbot",
            max_ticks=args.max_ticks,
            connect_timeout=20.0,
        )
        print(f"[sdk]    connecting -> {live.url}")

        # We run the SDK policy in a worker thread so we can also poll the
        # server / opponents for early failures (e.g. server crash).
        result_holder: dict[str, Any] = {}

        def _run_sdk() -> None:
            try:
                result, transcript = live.run_local_sdk_policy(sdk_policy)
                result_holder["result"] = result
                result_holder["transcript"] = transcript
                sdk_log_fh.write(f"# done: {result.summary}\n")
            except Exception as exc:
                result_holder["error"] = exc
                sdk_log_fh.write(f"# error: {exc!r}\n")
            finally:
                with suppress(Exception):
                    sdk_log_fh.close()

        sdk_thread = threading.Thread(target=_run_sdk, name="sdk-runner", daemon=True)
        sdk_thread.start()

        # ---- 6. Wait for the game to finish.
        deadline = time.monotonic() + args.game_timeout
        last_status_print = 0.0
        while True:
            if not server_proc.is_alive():
                print(f"[server] exited (rc={server_proc.popen.returncode})")
                break
            if not sdk_thread.is_alive():
                print("[sdk]    runner thread exited")
                break
            if time.monotonic() > deadline:
                print(
                    f"[timeout] game ran longer than {args.game_timeout}s; aborting",
                    file=sys.stderr,
                )
                break
            if time.monotonic() - last_status_print > 30.0:
                alive_bots = sum(1 for p in bot_procs if p.is_alive())
                transcript = result_holder.get("transcript")
                frames = transcript.frames_received if transcript else 0
                print(
                    f"[status] server up; bots alive={alive_bots}/7; "
                    f"sdk frames so far={frames}"
                )
                last_status_print = time.monotonic()
            time.sleep(0.5)

        # Once the server is done, give the SDK runner a beat to drain.
        sdk_thread.join(timeout=10.0)
        if sdk_thread.is_alive():
            print("[sdk]    forcing socket close...")
            # The server going away causes the SDK socket to close; this
            # is a final belt-and-braces in case `live.run_agent` is hung.

        # ---- 7. Stop opponents (server is already gone if we got here).
        for proc in procs:
            if proc.is_alive():
                proc.stop(timeout=3.0)

        # ---- 8. Print the final summary.
        print("")
        print("=" * 60)
        print("RESULT")
        print("=" * 60)
        scores = fetch_results_json(str(scores_path))
        print(_fmt_results(scores))

        result = result_holder.get("result")
        transcript = result_holder.get("transcript")
        sdk_error = result_holder.get("error")
        print("")
        print("SDK agent")
        print("---------")
        if sdk_error:
            print(f"  ! errored: {sdk_error!r}")
        elif result is not None:
            print(f"  summary:    {result.summary}")
            print(
                "  directives: "
                f"{json.dumps(sdk_policy.directives.model_dump(), indent=2, default=str)}"
            )
            engine_stats = sdk_policy.engine.stats
            print(
                "  overrides:  "
                f"reports_passed={engine_stats.reports_passed} "
                f"reports_suppressed={engine_stats.reports_suppressed}"
            )
            if transcript is not None:
                top_actions = sorted(
                    transcript.actions_seen.items(), key=lambda kv: -kv[1]
                )[:5]
                print(f"  frames:     {transcript.frames_received}")
                print(f"  masks:      {transcript.masks_sent}")
                print(f"  top actions (idx, count): {top_actions}")
        else:
            print("  (no SDK result captured)")

        print("")
        print(f"logs:    {log_dir}")
        print(f"scores:  {scores_path}")
        print(f"replay:  {replay_path}")

        if scores is None:
            return 4
        if sdk_error is not None:
            return 5
        return 0

    finally:
        _terminate_all()


def _coerce_scalar(raw: str) -> Any:
    """Coerce a CLI key=value string into bool/int/float/str."""
    s = raw.strip()
    if s.lower() in {"true", "false"}:
        return s.lower() == "true"
    try:
        return int(s)
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        pass
    return s


def _parse_kv_list(raw: list[str]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for item in raw:
        if "=" not in item:
            raise ExampleError(f"--cognitive expects key=value, got {item!r}")
        k, v = item.split("=", 1)
        out[k.strip()] = _coerce_scalar(v)
    return out


def _parse_module_specs(raw: list[str]) -> dict[str, ModuleSpec]:
    out: dict[str, ModuleSpec] = {}
    for item in raw:
        if "=" not in item:
            raise ExampleError(
                f"--module expects slot=type[:k=v,...], got {item!r}"
            )
        slot, body = item.split("=", 1)
        kind, _, params_blob = body.partition(":")
        params: dict[str, Any] = {}
        if params_blob:
            for kv in params_blob.split(","):
                if "=" not in kv:
                    raise ExampleError(
                        f"--module params expect k=v, got {kv!r} in {item!r}"
                    )
                k, v = kv.split("=", 1)
                params[k.strip()] = _coerce_scalar(v)
        out[slot.strip()] = ModuleSpec(type=(kind.strip() or "scripted"), params=params)
    return out


def _build_policy_config(args: argparse.Namespace) -> CogamesBundleConfig:
    """Assemble the CogamesBundleConfig the SDK player will run with.

    Mirrors what `python -m among_them_sdk.package` does at upload time:
    if `--use-llm` is set we pre-resolve the natural-language instructions
    into a `directives` block (so the on-disk JSON matches what would
    ship to cogames). Otherwise the keyword parser at construct time
    produces the same Directives.
    """
    if args.bundle_config:
        return load_cogames_config(args.bundle_config)

    cognitive = _parse_kv_list(args.cognitive or [])
    modules = _parse_module_specs(args.module or [])

    if args.use_llm and args.instructions:
        from among_them_sdk import parse_instructions

        resolved = parse_instructions(args.instructions, use_llm=True)
        return CogamesBundleConfig(
            directives=resolved.model_dump(),
            cognitive=cognitive,
            modules=modules,
        )

    return CogamesBundleConfig(
        instructions=args.instructions,
        cognitive=cognitive,
        modules=modules,
    )


def _short_directives(d: Any) -> str:
    return (
        f"susp={d.suspicion_threshold:.2f}, "
        f"report={d.report_eagerness}, "
        f"chat={d.chat_tone}, "
        f"vote={d.voting_style}"
    )


def _tail_file(path: Path, *, lines: int = 20) -> str:
    try:
        with path.open("rb") as fh:
            data = fh.read()
        text = data.decode("utf-8", errors="replace")
        return "\n".join(text.splitlines()[-lines:])
    except OSError:
        return f"<no log at {path}>"


if __name__ == "__main__":
    raise SystemExit(main())

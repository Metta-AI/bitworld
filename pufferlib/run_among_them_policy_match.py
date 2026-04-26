from __future__ import annotations

import argparse
import json
import subprocess
import threading
import time
from contextlib import suppress
from pathlib import Path

from bitworld_pufferlib import (
    DEFAULT_ACTION_REPEAT,
    ENV_SPECS,
    REPO_ROOT,
    connect_websocket,
    ensure_bitworld_binary,
    get_env_spec,
    nim_path_args,
    reserve_port,
    resolve_train_device,
    run_policy_websocket_client,
    train_policy,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Train or reuse an Among Them PufferLib policy, then run it as one websocket player beside four Nim bots."
    )
    parser.add_argument("--output-dir", type=Path, default=Path("tools/runlogs/among_them_policy_match"))
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--train-steps", type=int, default=512)
    parser.add_argument("--force-train", action="store_true")
    parser.add_argument("--num-envs", type=int, default=1)
    parser.add_argument("--episode-steps", type=int, default=64)
    parser.add_argument("--frame-stack", type=int, default=4)
    parser.add_argument("--horizon", type=int, default=8)
    parser.add_argument("--minibatch-size", type=int, default=8)
    parser.add_argument("--hidden-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=0.001)
    parser.add_argument("--seed", type=int, default=73)
    parser.add_argument("--action-repeat", type=int, default=DEFAULT_ACTION_REPEAT)
    parser.add_argument("--device", choices=("auto", "cuda", "cpu"), default="auto")
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--address", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--policy-name", default="puffer")
    parser.add_argument(
        "--bot-source",
        type=Path,
        default=REPO_ROOT / "among_them" / "players" / "nottoodumb.nim",
    )
    parser.add_argument("--bot-name-prefix", default="bot")
    parser.add_argument(
        "--deterministic",
        action="store_true",
        help="Use argmax actions for the policy player instead of sampling.",
    )
    return parser.parse_args()


def compile_nim(source: Path) -> Path:
    subprocess.run(["nim", "c", *nim_path_args(), str(source.relative_to(REPO_ROOT))], cwd=REPO_ROOT, check=True)
    return source.with_suffix("")


def start_process(
    args: list[str],
    cwd: Path,
    log_path: Path,
) -> tuple[subprocess.Popen[str], object]:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_file = log_path.open("w")
    try:
        process = subprocess.Popen(
            args,
            cwd=cwd,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except Exception:
        log_file.close()
        raise
    return process, log_file


def stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2.0)


def wait_for_global(address: str, port: int, duration: float) -> int:
    packets = 0
    deadline = time.monotonic() + max(duration, 1.0)
    with connect_websocket(f"ws://{address}:{port}/global") as global_ws:
        while time.monotonic() < deadline:
            try:
                payload = global_ws.recv(timeout=1.0)
            except TimeoutError:
                continue
            if isinstance(payload, (bytes, bytearray)) and payload:
                packets += 1
    return packets


def train_checkpoint(args: argparse.Namespace, checkpoint_path: Path) -> None:
    spec = get_env_spec("among_them")
    metrics_path = checkpoint_path.parent / "train_metrics.json"
    train_policy(
        spec=spec,
        num_envs=args.num_envs,
        total_timesteps=args.train_steps,
        max_episode_steps=args.episode_steps,
        frame_stack=args.frame_stack,
        learning_rate=args.learning_rate,
        horizon=args.horizon,
        minibatch_size=args.minibatch_size,
        seed=args.seed,
        checkpoint_path=checkpoint_path,
        metrics_path=metrics_path,
        action_repeat=args.action_repeat,
        hidden_size=args.hidden_size,
        device=args.device,
    )


def main() -> None:
    args = parse_args()
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    checkpoint_path = args.checkpoint or (output_dir / "among_them_policy.pt")
    if args.force_train or not checkpoint_path.exists():
        train_checkpoint(args, checkpoint_path)

    ensure_bitworld_binary(ENV_SPECS["among_them"])
    bot_source = args.bot_source
    if not bot_source.is_absolute():
        bot_source = REPO_ROOT / bot_source
    if not bot_source.exists():
        raise FileNotFoundError(f"bot source not found: {bot_source}")
    bot_binary = compile_nim(bot_source)

    port = args.port or reserve_port()
    global_url = f"file://{REPO_ROOT / 'global_client' / 'index.html'}?address=ws://{args.address}:{port}/global"
    server_config = {"seed": args.seed + 1, "minPlayers": 5}
    print(
        json.dumps(
            {
                "event": "match_started",
                "checkpoint": str(checkpoint_path),
                "bot_source": str(bot_source.relative_to(REPO_ROOT)),
                "port": port,
                "global_url": global_url,
            }
        ),
        flush=True,
    )
    processes: list[subprocess.Popen[str]] = []
    logs: list[object] = []
    policy_result: dict[str, object] = {}
    policy_error: list[BaseException] = []

    def run_policy() -> None:
        try:
            policy_result.update(
                run_policy_websocket_client(
                    checkpoint_path=checkpoint_path,
                    address=args.address,
                    port=port,
                    name=args.policy_name,
                    duration_seconds=args.duration,
                    action_repeat=args.action_repeat,
                    device=args.device,
                    sample_actions=not args.deterministic,
                )
            )
        except BaseException as exc:
            policy_error.append(exc)

    try:
        server_binary = REPO_ROOT / "among_them" / "among_them"
        server_process, server_log = start_process(
            [
                str(server_binary),
                f"--address:{args.address}",
                f"--port:{port}",
                f"--config:{json.dumps(server_config, separators=(',', ':'))}",
            ],
            cwd=REPO_ROOT / "among_them",
            log_path=output_dir / "among_them_server.log",
        )
        processes.append(server_process)
        logs.append(server_log)

        time.sleep(0.25)
        for index in range(4):
            bot_process, bot_log = start_process(
                [
                    str(bot_binary),
                    f"--address:{args.address}",
                    f"--port:{port}",
                    f"--name:{args.bot_name_prefix}{index + 1}",
                ],
                cwd=bot_source.parent,
                log_path=output_dir / f"bot{index + 1}.log",
            )
            processes.append(bot_process)
            logs.append(bot_log)

        policy_thread = threading.Thread(target=run_policy, name="bitworld-policy-client")
        policy_thread.start()
        global_packets = wait_for_global(args.address, port, args.duration)
        policy_thread.join(timeout=5.0)
        if policy_thread.is_alive():
            raise TimeoutError("policy client did not stop after match duration")
        if policy_error:
            raise RuntimeError("policy client failed") from policy_error[0]
        if int(policy_result.get("frames_received", 0)) <= 0:
            raise RuntimeError("policy client did not receive player frames")
        if int(policy_result.get("actions_sent", 0)) <= 0:
            raise RuntimeError("policy client did not send actions")
        if int(policy_result.get("nonzero_actions", 0)) <= 0:
            raise RuntimeError("policy client did not send any nonzero actions")
        if global_packets <= 0:
            raise RuntimeError("global observer did not receive packets")

        summary = {
            "checkpoint": str(checkpoint_path),
            "bot_source": str(bot_source.relative_to(REPO_ROOT)),
            "port": port,
            "global_url": global_url,
            "global_packets": global_packets,
            "policy": policy_result,
            "device": resolve_train_device(args.device),
        }
        summary_path = output_dir / "match_summary.json"
        summary_path.write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2))
    finally:
        for process in reversed(processes):
            with suppress(Exception):
                stop_process(process)
        for log in logs:
            with suppress(Exception):
                log.close()


if __name__ == "__main__":
    main()

from __future__ import annotations

import argparse
import json
from pathlib import Path

from bitworld_pufferlib import DEFAULT_ACTION_REPEAT, run_policy_websocket_client


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a trained BitWorld PufferLib policy as an Among Them websocket player."
    )
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--address", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2000)
    parser.add_argument("--name", default="puffer")
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--action-repeat", type=int, default=DEFAULT_ACTION_REPEAT)
    parser.add_argument("--device", choices=("auto", "cuda", "mps", "cpu"), default="auto")
    parser.add_argument(
        "--deterministic",
        action="store_true",
        help="Use argmax actions instead of sampling from the policy distribution.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    stats = run_policy_websocket_client(
        checkpoint_path=args.checkpoint,
        address=args.address,
        port=args.port,
        name=args.name,
        duration_seconds=args.duration,
        action_repeat=args.action_repeat,
        device=args.device,
        sample_actions=not args.deterministic,
    )
    print(json.dumps(stats, indent=2))


if __name__ == "__main__":
    main()

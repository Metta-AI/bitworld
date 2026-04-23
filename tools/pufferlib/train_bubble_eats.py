from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch

from bitworld_pufferlib import BubbleEatsPolicy, evaluate_policy, train_policy


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train Bubble Eats with the PufferLib 4.0 torch backend.")
    parser.add_argument("--total-timesteps", type=int, default=50_000)
    parser.add_argument("--num-envs", type=int, default=8)
    parser.add_argument("--episode-steps", type=int, default=64)
    parser.add_argument("--frame-stack", type=int, default=4)
    parser.add_argument("--learning-rate", type=float, default=0.001)
    parser.add_argument("--horizon", type=int, default=64)
    parser.add_argument("--minibatch-size", type=int, default=512)
    parser.add_argument("--hidden-size", type=int, default=256)
    parser.add_argument("--seed", type=int, default=73)
    parser.add_argument("--fps", type=float, default=0.0, help="Use 0 for uncapped training speed.")
    parser.add_argument("--eval-episodes", type=int, default=20)
    parser.add_argument("--output-dir", type=Path, default=Path("tools/runlogs/pufferlib_training"))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.minibatch_size > args.num_envs * args.horizon:
        raise ValueError("--minibatch-size must be <= num_envs * horizon")
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    model_path = output_dir / "bubble_eats_policy.pt"
    metrics_path = output_dir / "train_metrics.json"

    train_policy(
        num_envs=args.num_envs,
        total_timesteps=args.total_timesteps,
        max_episode_steps=args.episode_steps,
        frame_stack=args.frame_stack,
        learning_rate=args.learning_rate,
        horizon=args.horizon,
        minibatch_size=args.minibatch_size,
        seed=args.seed,
        model_path=model_path,
        metrics_path=metrics_path,
        fps=args.fps,
        hidden_size=args.hidden_size,
    )

    policy = BubbleEatsPolicy(
        frame_stack=args.frame_stack,
        action_count=9,
        hidden_size=args.hidden_size,
    )
    state_dict = torch.load(model_path, map_location="cpu")
    policy.load_state_dict(state_dict)
    policy.eval()

    trained = evaluate_policy(
        policy=policy,
        episodes=args.eval_episodes,
        max_episode_steps=args.episode_steps,
        frame_stack=args.frame_stack,
        seed=args.seed + 10_000,
        fps=args.fps,
        random_actions=False,
    )
    random_baseline = evaluate_policy(
        policy=policy,
        episodes=args.eval_episodes,
        max_episode_steps=args.episode_steps,
        frame_stack=args.frame_stack,
        seed=args.seed + 20_000,
        fps=args.fps,
        random_actions=True,
    )
    summary = {
        "model_path": str(model_path),
        "metrics_path": str(metrics_path),
        "trained": trained,
        "random": random_baseline,
    }
    summary_path = output_dir / "eval_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch

from bitworld_pufferlib import (
    ACTION_MASKS,
    BitWorldPolicy,
    evaluate_policy,
    get_env_spec,
    list_env_names,
    resolve_train_device,
    train_policy,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train a BitWorld environment with the PufferLib 4.0 torch backend.")
    parser.add_argument("--env", choices=list_env_names(), default="bubble_eats")
    parser.add_argument("--total-timesteps", type=int)
    parser.add_argument("--num-envs", type=int, default=8)
    parser.add_argument("--episode-steps", type=int)
    parser.add_argument("--frame-stack", type=int, default=4)
    parser.add_argument("--learning-rate", type=float)
    parser.add_argument("--horizon", type=int)
    parser.add_argument("--minibatch-size", type=int)
    parser.add_argument("--hidden-size", type=int)
    parser.add_argument("--seed", type=int, default=73)
    parser.add_argument("--fps", type=int, default=0, help="Use 0 for uncapped training speed.")
    parser.add_argument("--action-repeat", type=int, default=4)
    parser.add_argument("--device", choices=("auto", "cuda", "cpu"), default="auto")
    parser.add_argument("--eval-episodes", type=int, default=20)
    parser.add_argument("--output-dir", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    spec = get_env_spec(args.env)
    total_timesteps = args.total_timesteps if args.total_timesteps is not None else spec.default_total_timesteps
    episode_steps = args.episode_steps if args.episode_steps is not None else spec.default_episode_steps
    learning_rate = args.learning_rate if args.learning_rate is not None else spec.learning_rate
    horizon = args.horizon if args.horizon is not None else spec.horizon
    minibatch_size = args.minibatch_size if args.minibatch_size is not None else spec.minibatch_size
    hidden_size = args.hidden_size if args.hidden_size is not None else spec.hidden_size
    if minibatch_size > args.num_envs * horizon:
        raise ValueError("--minibatch-size must be <= num-envs * horizon")

    output_dir = args.output_dir if args.output_dir is not None else Path(f"tools/runlogs/{spec.name}_pufferlib_training")
    output_dir.mkdir(parents=True, exist_ok=True)
    model_path = output_dir / f"{spec.name}_policy.pt"
    metrics_path = output_dir / "train_metrics.json"

    train_policy(
        spec=spec,
        num_envs=args.num_envs,
        total_timesteps=total_timesteps,
        max_episode_steps=episode_steps,
        frame_stack=args.frame_stack,
        learning_rate=learning_rate,
        horizon=horizon,
        minibatch_size=minibatch_size,
        seed=args.seed,
        model_path=model_path,
        metrics_path=metrics_path,
        fps=args.fps,
        action_repeat=args.action_repeat,
        hidden_size=hidden_size,
        device=args.device,
    )

    if args.eval_episodes <= 0:
        summary = {
            "env": spec.name,
            "device": resolve_train_device(args.device),
            "model_path": str(model_path),
            "metrics_path": str(metrics_path),
            "trained": None,
            "random": None,
        }
        summary_path = output_dir / "eval_summary.json"
        summary_path.write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2))
        return

    train_device = resolve_train_device(args.device)
    policy = BitWorldPolicy(
        frame_stack=args.frame_stack,
        action_count=len(ACTION_MASKS),
        hidden_size=hidden_size,
    ).to(train_device)
    state_dict = torch.load(model_path, map_location=train_device)
    policy.load_state_dict(state_dict)
    policy.eval()

    trained = evaluate_policy(
        spec=spec,
        policy=policy,
        episodes=args.eval_episodes,
        max_episode_steps=episode_steps,
        frame_stack=args.frame_stack,
        seed=args.seed + 10_000,
        fps=args.fps,
        action_repeat=args.action_repeat,
        random_actions=False,
    )
    random_baseline = evaluate_policy(
        spec=spec,
        policy=None,
        episodes=args.eval_episodes,
        max_episode_steps=episode_steps,
        frame_stack=args.frame_stack,
        seed=args.seed + 20_000,
        fps=args.fps,
        action_repeat=args.action_repeat,
        random_actions=True,
    )
    summary = {
        "env": spec.name,
        "device": train_device,
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

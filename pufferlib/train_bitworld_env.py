from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from bitworld_pufferlib import (
    ENV_SPECS,
    OBSERVATION_MODES,
    evaluate_policy,
    get_env_spec,
    load_policy_checkpoint,
    resolve_train_device,
    train_policy,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train a BitWorld environment with the PufferLib 4.0 torch backend.")
    parser.add_argument("--env", choices=sorted(ENV_SPECS), default="among_them")
    parser.add_argument("--total-timesteps", type=int)
    parser.add_argument("--num-envs", type=int, default=8)
    parser.add_argument("--episode-steps", type=int)
    parser.add_argument("--frame-stack", type=int, default=4)
    parser.add_argument("--learning-rate", type=float)
    parser.add_argument("--horizon", type=int)
    parser.add_argument("--minibatch-size", type=int)
    parser.add_argument("--hidden-size", type=int)
    parser.add_argument("--seed", type=int, default=73)
    parser.add_argument("--action-repeat", type=int, default=4)
    parser.add_argument("--observation-mode", choices=sorted(OBSERVATION_MODES), default="pixels")
    parser.add_argument("--device", choices=("auto", "cuda", "cpu"), default="auto")
    parser.add_argument("--eval-episodes", type=int, default=20)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--local-rank", type=int, default=0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    rank = int(os.environ.get("RANK", "0"))
    spec = get_env_spec(args.env)
    total_timesteps = args.total_timesteps if args.total_timesteps is not None else spec.default_total_timesteps
    episode_steps = args.episode_steps if args.episode_steps is not None else spec.default_episode_steps
    learning_rate = args.learning_rate if args.learning_rate is not None else spec.learning_rate
    horizon = args.horizon if args.horizon is not None else spec.horizon
    minibatch_size = args.minibatch_size if args.minibatch_size is not None else spec.minibatch_size
    hidden_size = args.hidden_size if args.hidden_size is not None else spec.hidden_size
    agents_per_env = spec.server_players if spec.name == "among_them" else 1
    if minibatch_size > args.num_envs * agents_per_env * horizon:
        raise ValueError("--minibatch-size must be <= total agents * horizon")

    output_dir = args.output_dir if args.output_dir is not None else Path(f"tools/runlogs/{spec.name}_pufferlib_training")
    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    checkpoint_path = output_dir / f"{spec.name}_policy.pt"
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
        checkpoint_path=checkpoint_path,
        metrics_path=metrics_path,
        action_repeat=args.action_repeat,
        hidden_size=hidden_size,
        device=args.device,
        observation_mode=args.observation_mode,
    )

    if rank != 0:
        return

    if args.eval_episodes <= 0:
        summary = {
            "env": spec.name,
            "device": resolve_train_device(args.device),
            "observation_mode": args.observation_mode,
            "checkpoint": str(checkpoint_path),
            "metrics_path": str(metrics_path),
            "trained": None,
            "random": None,
        }
        summary_path = output_dir / "eval_summary.json"
        summary_path.write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2))
        return

    train_device = resolve_train_device(args.device)
    checkpoint = load_policy_checkpoint(checkpoint_path, device=train_device)

    trained = evaluate_policy(
        spec=spec,
        policy=checkpoint.policy,
        episodes=args.eval_episodes,
        max_episode_steps=episode_steps,
        frame_stack=checkpoint.frame_stack,
        seed=args.seed + 10_000,
        action_repeat=args.action_repeat,
        observation_mode=checkpoint.observation_mode,
        random_actions=False,
        sample_actions=False,
    )
    random_baseline = evaluate_policy(
        spec=spec,
        policy=None,
        episodes=args.eval_episodes,
        max_episode_steps=episode_steps,
        frame_stack=checkpoint.frame_stack,
        seed=args.seed + 20_000,
        action_repeat=args.action_repeat,
        observation_mode=args.observation_mode,
        random_actions=True,
    )
    teacher_baseline = None
    if args.observation_mode == "state":
        teacher_baseline = evaluate_policy(
            spec=spec,
            policy=None,
            episodes=args.eval_episodes,
            max_episode_steps=episode_steps,
            frame_stack=checkpoint.frame_stack,
            seed=args.seed + 30_000,
            action_repeat=args.action_repeat,
            observation_mode=args.observation_mode,
            teacher_actions=True,
        )
    summary = {
        "env": spec.name,
        "device": train_device,
        "observation_mode": args.observation_mode,
        "checkpoint": str(checkpoint_path),
        "metrics_path": str(metrics_path),
        "trained": trained,
        "random": random_baseline,
        "teacher": teacher_baseline,
    }
    summary_path = output_dir / "eval_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

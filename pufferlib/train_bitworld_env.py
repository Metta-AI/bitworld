from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from bitworld_pufferlib import (
    AMONG_THEM_MAX_PLAYERS,
    ENV_SPECS,
    OBSERVATION_MODES,
    evaluate_policy,
    load_policy_checkpoint,
    resolve_train_device,
    train_policy,
    with_server_players,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train a BitWorld environment with the PufferLib 4.0 torch backend.")
    parser.add_argument("--env", choices=sorted(ENV_SPECS), default="among_them")
    parser.add_argument("--total-timesteps", type=int)
    parser.add_argument("--num-envs", type=int, default=8)
    parser.add_argument("--players", type=int, help=f"Among Them players per game, 1-{AMONG_THEM_MAX_PLAYERS}")
    parser.add_argument("--episode-steps", type=int)
    parser.add_argument("--frame-stack", type=int, default=4)
    parser.add_argument("--learning-rate", type=float)
    parser.add_argument("--horizon", type=int)
    parser.add_argument("--minibatch-size", type=int)
    parser.add_argument("--hidden-size", type=int)
    parser.add_argument("--seed", type=int, default=73)
    parser.add_argument("--action-repeat", type=int, default=4)
    parser.add_argument("--observation-mode", choices=sorted(OBSERVATION_MODES), default="pixels")
    parser.add_argument(
        "--state-aux-coef",
        type=float,
        default=0.0,
        help="Weight for auxiliary state-prediction loss (pixels mode, among_them only). 0 disables.",
    )
    parser.add_argument(
        "--shaping-rewards",
        action="store_true",
        help="Enable task-distance and task-progress shaping rewards in pixel mode (among_them only).",
    )
    parser.add_argument("--imposter-count", type=int, default=-1, help="Override config imposterCount; -1 keeps default.")
    parser.add_argument("--tasks-per-player", type=int, default=-1, help="Override config tasksPerPlayer; -1 keeps default.")
    parser.add_argument("--task-complete-ticks", type=int, default=-1, help="Override config taskCompleteTicks; -1 keeps default.")
    parser.add_argument("--kill-cooldown-ticks", type=int, default=-1, help="Override config killCooldownTicks; -1 keeps default.")
    parser.add_argument("--ent-coef", type=float, default=0.01, help="Entropy coefficient for PPO.")
    parser.add_argument("--no-anneal-lr", action="store_true", help="Disable learning rate annealing.")
    parser.add_argument(
        "--curriculum-file",
        type=Path,
        help="JSON file with a list of stage dicts. Each stage may set total_timesteps, players, "
        "imposter_count, tasks_per_player, task_complete_ticks, kill_cooldown_ticks, learning_rate, "
        "shaping_rewards, state_aux_coef. Stages run sequentially with policy weights preserved.",
    )
    parser.add_argument(
        "--init-checkpoint",
        type=Path,
        help="Load weights from this .pt file before training (continue from a prior run).",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="If --output-dir contains a saved policy, load it as the init checkpoint.",
    )
    parser.add_argument("--device", choices=("auto", "cuda", "mps", "cpu"), default="auto")
    parser.add_argument("--eval-episodes", type=int, default=20)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--local-rank", type=int, default=0)
    return parser.parse_args()


def run_stage(
    args: argparse.Namespace,
    stage: dict,
    output_dir: Path,
    checkpoint_path: Path,
    metrics_path: Path,
    init_checkpoint_path: Path | None,
) -> tuple:
    players = stage.get("players", args.players)
    spec = with_server_players(args.env, players)
    total_timesteps = stage.get("total_timesteps", args.total_timesteps)
    if total_timesteps is None:
        total_timesteps = spec.default_total_timesteps
    episode_steps = stage.get("episode_steps", args.episode_steps)
    if episode_steps is None:
        episode_steps = spec.default_episode_steps
    learning_rate = stage.get("learning_rate", args.learning_rate)
    if learning_rate is None:
        learning_rate = spec.learning_rate
    horizon = stage.get("horizon", args.horizon) or spec.horizon
    minibatch_size = stage.get("minibatch_size", args.minibatch_size) or spec.minibatch_size
    hidden_size = stage.get("hidden_size", args.hidden_size) or spec.hidden_size
    action_repeat = stage.get("action_repeat", args.action_repeat)
    agents_per_env = spec.server_players if spec.name == "among_them" else 1
    if minibatch_size > args.num_envs * agents_per_env * horizon:
        raise ValueError("minibatch_size must be <= total agents * horizon")

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
        action_repeat=action_repeat,
        hidden_size=hidden_size,
        device=args.device,
        observation_mode=args.observation_mode,
        state_aux_coef=stage.get("state_aux_coef", args.state_aux_coef),
        enable_state_shaping=stage.get("shaping_rewards", args.shaping_rewards),
        imposter_count=stage.get("imposter_count", args.imposter_count),
        tasks_per_player=stage.get("tasks_per_player", args.tasks_per_player),
        task_complete_ticks=stage.get("task_complete_ticks", args.task_complete_ticks),
        kill_cooldown_ticks=stage.get("kill_cooldown_ticks", args.kill_cooldown_ticks),
        init_checkpoint_path=init_checkpoint_path,
        ent_coef=stage.get("ent_coef", args.ent_coef),
        anneal_lr=not stage.get("no_anneal_lr", args.no_anneal_lr),
    )
    return spec, episode_steps


def main() -> None:
    args = parse_args()
    rank = int(os.environ.get("RANK", "0"))
    spec_for_paths = with_server_players(args.env, args.players)

    output_dir = args.output_dir if args.output_dir is not None else Path(f"tools/runlogs/{spec_for_paths.name}_pufferlib_training")
    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    checkpoint_path = output_dir / f"{spec_for_paths.name}_policy.pt"

    initial_checkpoint: Path | None = None
    if args.init_checkpoint is not None:
        initial_checkpoint = args.init_checkpoint.resolve()
        if not initial_checkpoint.exists():
            raise FileNotFoundError(f"--init-checkpoint not found: {initial_checkpoint}")
    elif args.resume:
        if checkpoint_path.exists():
            initial_checkpoint = checkpoint_path
        elif rank == 0:
            print(json.dumps({"resume": "no checkpoint found", "looked_in": str(checkpoint_path)}), flush=True)
    if initial_checkpoint is not None and rank == 0:
        print(json.dumps({"resuming_from": str(initial_checkpoint)}), flush=True)

    if args.curriculum_file is not None:
        stages = json.loads(args.curriculum_file.read_text())
        if not isinstance(stages, list) or not stages:
            raise ValueError("--curriculum-file must contain a non-empty JSON list of stage dicts")
        spec = spec_for_paths
        episode_steps = args.episode_steps if args.episode_steps is not None else spec.default_episode_steps
        for stage_idx, stage in enumerate(stages):
            stage_metrics = output_dir / f"train_metrics_stage_{stage_idx}.json"
            if stage_idx == 0:
                init_ckpt = initial_checkpoint
            else:
                init_ckpt = checkpoint_path
            if rank == 0:
                print(json.dumps({"stage": stage_idx, "config": stage}), flush=True)
            spec, episode_steps = run_stage(
                args=args,
                stage=stage,
                output_dir=output_dir,
                checkpoint_path=checkpoint_path,
                metrics_path=stage_metrics,
                init_checkpoint_path=init_ckpt,
            )
        metrics_path = output_dir / f"train_metrics_stage_{len(stages) - 1}.json"
    else:
        metrics_path = output_dir / "train_metrics.json"
        spec, episode_steps = run_stage(
            args=args,
            stage={},
            output_dir=output_dir,
            checkpoint_path=checkpoint_path,
            metrics_path=metrics_path,
            init_checkpoint_path=initial_checkpoint,
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
    summary = {
        "env": spec.name,
        "device": train_device,
        "observation_mode": args.observation_mode,
        "checkpoint": str(checkpoint_path),
        "metrics_path": str(metrics_path),
        "trained": trained,
        "random": random_baseline,
    }
    summary_path = output_dir / "eval_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

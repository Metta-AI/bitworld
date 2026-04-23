from __future__ import annotations

import ctypes
import json
import socket
import struct
import subprocess
import sys
import time
import types
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import numpy as np
import torch
from torch import nn
from websockets.sync.client import ClientConnection, connect

REPO_ROOT = Path(__file__).resolve().parents[2]
BUBBLE_EATS_SOURCE = REPO_ROOT / "bubble_eats" / "bubble_eats.nim"
BUBBLE_EATS_BINARY = REPO_ROOT / "bubble_eats" / "bubble_eats"
RUNLOG_DIR = REPO_ROOT / "tools" / "runlogs" / "pufferlib"

SCREEN_WIDTH = 64
SCREEN_HEIGHT = 64
FRAME_PIXELS = SCREEN_WIDTH * SCREEN_HEIGHT
RL_HEADER_BYTES = 8
RL_FRAME_BYTES = RL_HEADER_BYTES + FRAME_PIXELS
RL_MAGIC = b"BW"
RL_VERSION = 1
RL_RESET_MASK = 255
ACTION_MASKS = np.array(
    [
        0,
        1,
        2,
        4,
        8,
        1 | 4,
        1 | 8,
        2 | 4,
        2 | 8,
    ],
    dtype=np.uint8,
)


def ensure_bubble_eats_binary() -> None:
    if BUBBLE_EATS_BINARY.exists() and BUBBLE_EATS_BINARY.stat().st_mtime >= BUBBLE_EATS_SOURCE.stat().st_mtime:
        return

    subprocess.run(
        ["nim", "c", "bubble_eats/bubble_eats.nim"],
        cwd=REPO_ROOT,
        check=True,
    )


def install_pufferlib_c_stub() -> None:
    if "pufferlib._C" in sys.modules:
        return

    stub = types.ModuleType("pufferlib._C")
    stub.precision_bytes = 4
    stub.gpu = False
    stub.get_utilization = lambda gpu_id=0: {}
    sys.modules["pufferlib._C"] = stub


def compute_puff_advantage_fallback(
    values: torch.Tensor,
    rewards: torch.Tensor,
    terminals: torch.Tensor,
    ratio: torch.Tensor,
    advantages: torch.Tensor,
    gamma: float,
    gae_lambda: float,
    vtrace_rho_clip: float,
    vtrace_c_clip: float,
) -> torch.Tensor:
    num_steps, horizon = values.shape
    del num_steps
    advantages.zero_()
    last_puffer_lambda = torch.zeros(values.shape[0], device=values.device)
    for t in range(horizon - 2, -1, -1):
        next_nonterminal = 1.0 - terminals[:, t + 1]
        importance = ratio[:, t]
        rho_t = torch.clamp(importance, max=vtrace_rho_clip)
        c_t = torch.clamp(importance, max=vtrace_c_clip)
        delta = rho_t * rewards[:, t + 1] + gamma * values[:, t + 1] * next_nonterminal - values[:, t]
        last_puffer_lambda = delta + gamma * gae_lambda * c_t * last_puffer_lambda * next_nonterminal
        advantages[:, t] = last_puffer_lambda
    return advantages


def load_puffer_trainer():
    install_pufferlib_c_stub()
    from pufferlib import torch_pufferl

    torch_pufferl.compute_puff_advantage = compute_puff_advantage_fallback

    return torch_pufferl.PuffeRL


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def parse_rl_frame(packet: bytes) -> tuple[np.ndarray, int, int]:
    if len(packet) != RL_FRAME_BYTES:
        raise ValueError(f"expected {RL_FRAME_BYTES} bytes, received {len(packet)}")
    if packet[:2] != RL_MAGIC:
        raise ValueError(f"bad RL magic: {packet[:2]!r}")
    if packet[2] != RL_VERSION:
        raise ValueError(f"unsupported RL version: {packet[2]}")

    component_size = int(packet[3])
    score = struct.unpack_from("<i", packet, 4)[0]
    frame = np.frombuffer(packet, dtype=np.uint8, count=FRAME_PIXELS, offset=RL_HEADER_BYTES).copy()
    return frame, score, component_size


def flatten_logs(logs: dict, prefix: str = "") -> dict[str, float]:
    flat: dict[str, float] = {}
    for key, value in logs.items():
        next_key = f"{prefix}/{key}" if prefix else key
        if isinstance(value, dict):
            flat.update(flatten_logs(value, next_key))
        else:
            flat[next_key] = value
    return flat


@dataclass
class EpisodeStats:
    score: float
    length: int
    episode_return: float


class BubbleEatsWorker:
    def __init__(self, env_id: int, port: int, seed: int, fps: float) -> None:
        self.env_id = env_id
        self.port = port
        self.seed = seed
        self.fps = fps
        self.process: subprocess.Popen[str] | None = None
        self.connection: ClientConnection | None = None
        self.log_file = None
        self.score = 0
        self.component_size = 1
        self.episode_return = 0.0
        self.episode_steps = 0
        self._start_server()

    def _start_server(self) -> None:
        ensure_bubble_eats_binary()
        RUNLOG_DIR.mkdir(parents=True, exist_ok=True)
        log_path = RUNLOG_DIR / f"bubble_eats_env_{self.env_id}.log"
        self.log_file = log_path.open("w")
        self.process = subprocess.Popen(
            [
                str(BUBBLE_EATS_BINARY),
                f"--address:127.0.0.1",
                f"--port:{self.port}",
                "--rl",
                f"--fps:{self.fps}",
                f"--seed:{self.seed}",
            ],
            cwd=REPO_ROOT,
            stdout=self.log_file,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.connection = self._connect()

    def _connect(self) -> ClientConnection:
        deadline = time.time() + 10.0
        url = f"ws://127.0.0.1:{self.port}/rl"
        last_error: Exception | None = None
        while time.time() < deadline:
            try:
                return connect(url, open_timeout=1.0, ping_interval=None, max_size=None, proxy=None)
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                time.sleep(0.05)
        raise RuntimeError(f"failed to connect to {url}") from last_error

    def _receive_packet(self) -> tuple[np.ndarray, int, int]:
        assert self.connection is not None
        payload = self.connection.recv(timeout=10.0)
        if not isinstance(payload, (bytes, bytearray)):
            raise TypeError(f"expected binary websocket payload, got {type(payload)!r}")
        return parse_rl_frame(bytes(payload))

    def reset(self) -> np.ndarray:
        assert self.connection is not None
        self.connection.send(bytes([RL_RESET_MASK]), text=False)
        frame, score, component_size = self._receive_packet()
        self.score = score
        self.component_size = component_size
        self.episode_return = 0.0
        self.episode_steps = 0
        return frame

    def step(self, action_mask: int) -> tuple[np.ndarray, float]:
        assert self.connection is not None
        self.connection.send(bytes([action_mask]), text=False)
        frame, score, component_size = self._receive_packet()
        reward = float(score - self.score)
        self.score = score
        self.component_size = component_size
        self.episode_return += reward
        self.episode_steps += 1
        return frame, reward

    def close(self) -> None:
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2.0)
            self.process = None

        if self.connection is not None:
            try:
                self.connection.close()
            except Exception:  # noqa: BLE001
                pass
            self.connection = None

        if self.log_file is not None:
            self.log_file.close()
            self.log_file = None


class BubbleEatsVecEnv:
    gpu = False
    obs_dtype = "ByteTensor"
    num_atns = 1

    def __init__(
        self,
        num_envs: int,
        max_episode_steps: int,
        frame_stack: int = 4,
        fps: float = 0.0,
        base_seed: int = 73,
        base_port: int | None = None,
    ) -> None:
        if num_envs <= 0:
            raise ValueError("num_envs must be positive")
        if frame_stack <= 0:
            raise ValueError("frame_stack must be positive")

        self.num_envs = num_envs
        self.total_agents = num_envs
        self.max_episode_steps = max_episode_steps
        self.frame_stack = frame_stack
        self.base_seed = base_seed
        self.base_port = base_port
        self.obs_size = FRAME_PIXELS * frame_stack
        self.action_count = len(ACTION_MASKS)
        self.driver_env = self

        self._frame_history = np.zeros((num_envs, frame_stack, FRAME_PIXELS), dtype=np.uint8)
        self._obs = np.zeros((num_envs, self.obs_size), dtype=np.uint8)
        self._rewards = np.zeros((num_envs,), dtype=np.float32)
        self._terminals = np.zeros((num_envs,), dtype=np.float32)
        self.obs_ptr = self._obs.ctypes.data
        self.rewards_ptr = self._rewards.ctypes.data
        self.terminals_ptr = self._terminals.ctypes.data

        self._completed_scores: deque[float] = deque(maxlen=100)
        self._completed_lengths: deque[float] = deque(maxlen=100)
        self._completed_returns: deque[float] = deque(maxlen=100)
        self._completed_episodes = 0

        self.workers: list[BubbleEatsWorker] = []
        for env_id in range(num_envs):
            port = base_port + env_id if base_port is not None else reserve_port()
            worker = BubbleEatsWorker(env_id=env_id, port=port, seed=base_seed + env_id, fps=fps)
            self.workers.append(worker)

    def _push_frame(self, env_id: int, frame: np.ndarray) -> None:
        self._frame_history[env_id, :-1] = self._frame_history[env_id, 1:]
        self._frame_history[env_id, -1] = frame
        self._obs[env_id] = self._frame_history[env_id].reshape(-1)

    def reset(self):
        self._rewards.fill(0.0)
        self._terminals.fill(0.0)
        for env_id, worker in enumerate(self.workers):
            frame = worker.reset()
            for stack_index in range(self.frame_stack):
                self._frame_history[env_id, stack_index] = frame
            self._obs[env_id] = self._frame_history[env_id].reshape(-1)
        return self._obs

    def _apply_actions(self, action_indices: np.ndarray) -> list[EpisodeStats]:
        self._rewards.fill(0.0)
        self._terminals.fill(0.0)
        completed: list[EpisodeStats] = []
        for env_id, worker in enumerate(self.workers):
            action_index = int(np.clip(action_indices[env_id], 0, self.action_count - 1))
            frame, reward = worker.step(int(ACTION_MASKS[action_index]))
            done = worker.episode_steps >= self.max_episode_steps
            if done:
                completed.append(
                    EpisodeStats(
                        score=float(worker.score),
                        length=worker.episode_steps,
                        episode_return=worker.episode_return,
                    )
                )
                self._completed_scores.append(float(worker.score))
                self._completed_lengths.append(float(worker.episode_steps))
                self._completed_returns.append(worker.episode_return)
                self._completed_episodes += 1
                frame = worker.reset()
                self._terminals[env_id] = 1.0

            self._rewards[env_id] = reward
            self._push_frame(env_id, frame)
        return completed

    def step_discrete(self, action_indices: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, list[EpisodeStats]]:
        completed = self._apply_actions(action_indices)
        return self._obs, self._rewards, self._terminals, completed

    def cpu_step(self, actions_ptr: int) -> None:
        raw = (ctypes.c_float * (self.total_agents * self.num_atns)).from_address(actions_ptr)
        action_indices = np.ctypeslib.as_array(raw).reshape(self.total_agents, self.num_atns)[:, 0].astype(np.int64)
        self._apply_actions(action_indices)

    def log(self) -> dict[str, float]:
        score = float(np.mean(self._completed_scores)) if self._completed_scores else 0.0
        episode_length = float(np.mean(self._completed_lengths)) if self._completed_lengths else 0.0
        episode_return = float(np.mean(self._completed_returns)) if self._completed_returns else 0.0
        return {
            "score": score,
            "episode_length": episode_length,
            "episode_return": episode_return,
            "n": float(self._completed_episodes),
        }

    def render(self, env_id: int = 0) -> None:
        del env_id

    def close(self) -> None:
        for worker in self.workers:
            worker.close()


class BubbleEatsPolicy(nn.Module):
    def __init__(self, frame_stack: int, action_count: int, hidden_size: int = 256) -> None:
        super().__init__()
        self.frame_stack = frame_stack
        self.action_count = action_count
        self.encoder = nn.Sequential(
            nn.Conv2d(frame_stack, 32, kernel_size=8, stride=4),
            nn.ReLU(),
            nn.Conv2d(32, 64, kernel_size=4, stride=2),
            nn.ReLU(),
            nn.Conv2d(64, 64, kernel_size=3, stride=1),
            nn.ReLU(),
            nn.Flatten(),
        )
        with torch.no_grad():
            sample = torch.zeros(1, frame_stack, SCREEN_HEIGHT, SCREEN_WIDTH)
            encoded_size = int(self.encoder(sample).shape[1])

        self.body = nn.Sequential(
            nn.Linear(encoded_size, hidden_size),
            nn.ReLU(),
        )
        self.policy_head = nn.Linear(hidden_size, action_count)
        self.value_head = nn.Linear(hidden_size, 1)
        self._init_weights()

    def _init_weights(self) -> None:
        for module in self.modules():
            if isinstance(module, (nn.Conv2d, nn.Linear)):
                nn.init.orthogonal_(module.weight, gain=np.sqrt(2.0))
                if module.bias is not None:
                    nn.init.zeros_(module.bias)
        nn.init.orthogonal_(self.policy_head.weight, gain=0.01)
        nn.init.zeros_(self.policy_head.bias)
        nn.init.orthogonal_(self.value_head.weight, gain=1.0)
        nn.init.zeros_(self.value_head.bias)

    def initial_state(self, batch_size: int, device: str = "cpu"):
        del batch_size, device
        return ()

    def forward_eval(self, observations: torch.Tensor, state=()):
        x = observations.float().div(15.0).reshape(-1, self.frame_stack, SCREEN_HEIGHT, SCREEN_WIDTH)
        x = self.encoder(x)
        x = self.body(x)
        logits = self.policy_head(x)
        values = self.value_head(x)
        return logits, values, state

    def forward(self, observations: torch.Tensor, state=()):
        logits, values, _ = self.forward_eval(observations, state)
        return logits, values


def make_train_args(
    total_timesteps: int,
    learning_rate: float,
    num_envs: int,
    horizon: int,
    minibatch_size: int,
    seed: int,
    checkpoint_dir: Path,
    log_dir: Path,
) -> dict:
    return {
        "env_name": "bitworld_bubble_eats",
        "rank": 0,
        "world_size": 1,
        "gpu_id": 0,
        "wandb": False,
        "tag": None,
        "checkpoint_dir": str(checkpoint_dir),
        "log_dir": str(log_dir),
        "checkpoint_interval": 25,
        "eval_episodes": 100,
        "train": {
            "gpus": 1,
            "seed": seed,
            "total_timesteps": total_timesteps,
            "learning_rate": learning_rate,
            "anneal_lr": 1,
            "min_lr_ratio": 0.0,
            "gamma": 0.99,
            "gae_lambda": 0.95,
            "replay_ratio": 1.0,
            "clip_coef": 0.2,
            "vf_coef": 2.0,
            "vf_clip_coef": 0.2,
            "max_grad_norm": 1.5,
            "ent_coef": 0.01,
            "beta1": 0.95,
            "beta2": 0.999,
            "eps": 1e-12,
            "minibatch_size": minibatch_size,
            "horizon": horizon,
            "vtrace_rho_clip": 1.0,
            "vtrace_c_clip": 1.0,
            "prio_alpha": 0.8,
            "prio_beta0": 0.2,
        },
        "vec": {
            "total_agents": num_envs,
            "num_buffers": 1,
            "num_threads": 1,
        },
    }


def train_policy(
    num_envs: int,
    total_timesteps: int,
    max_episode_steps: int,
    frame_stack: int,
    learning_rate: float,
    horizon: int,
    minibatch_size: int,
    seed: int,
    model_path: Path,
    metrics_path: Path,
    fps: float = 0.0,
    hidden_size: int = 256,
) -> dict:
    PuffeRL = load_puffer_trainer()
    checkpoint_dir = model_path.parent / "checkpoints"
    log_dir = model_path.parent / "logs"
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    vecenv = BubbleEatsVecEnv(
        num_envs=num_envs,
        max_episode_steps=max_episode_steps,
        frame_stack=frame_stack,
        fps=fps,
        base_seed=seed,
    )
    policy = BubbleEatsPolicy(frame_stack=frame_stack, action_count=vecenv.action_count, hidden_size=hidden_size)
    args = make_train_args(
        total_timesteps=total_timesteps,
        learning_rate=learning_rate,
        num_envs=num_envs,
        horizon=horizon,
        minibatch_size=minibatch_size,
        seed=seed,
        checkpoint_dir=checkpoint_dir,
        log_dir=log_dir,
    )
    trainer = PuffeRL(args, vecenv, policy, verbose=False)

    history: list[dict[str, float]] = []
    try:
        while trainer.global_step < total_timesteps:
            trainer.rollouts()
            trainer.train()
            logs = trainer.log()
            flat_logs = flatten_logs(logs)
            history.append(flat_logs)
            print(
                json.dumps(
                    {
                        "steps": int(flat_logs["agent_steps"]),
                        "sps": round(float(flat_logs["SPS"]), 2),
                        "score": round(float(flat_logs.get("env/score", 0.0)), 3),
                        "episode_length": round(float(flat_logs.get("env/episode_length", 0.0)), 1),
                    }
                ),
                flush=True,
            )
    finally:
        trainer.save_weights(str(model_path))
        trainer.close()

    metrics_path.parent.mkdir(parents=True, exist_ok=True)
    summary = {
        "history": history,
    }
    metrics_path.write_text(json.dumps(summary, indent=2))
    return summary


def evaluate_policy(
    policy: BubbleEatsPolicy,
    episodes: int,
    max_episode_steps: int,
    frame_stack: int,
    seed: int,
    fps: float = 0.0,
    random_actions: bool = False,
) -> dict[str, float]:
    vecenv = BubbleEatsVecEnv(
        num_envs=1,
        max_episode_steps=max_episode_steps,
        frame_stack=frame_stack,
        fps=fps,
        base_seed=seed,
    )
    rng = np.random.default_rng(seed)
    vecenv.reset()
    completed_scores: list[float] = []
    completed_returns: list[float] = []

    try:
        while len(completed_scores) < episodes:
            if random_actions:
                action_indices = rng.integers(0, vecenv.action_count, size=(1,), dtype=np.int64)
            else:
                with torch.no_grad():
                    logits, _, _ = policy.forward_eval(torch.from_numpy(vecenv._obs))
                    action_indices = torch.argmax(logits, dim=-1).cpu().numpy()
            _, _, _, completed = vecenv.step_discrete(action_indices)
            for item in completed:
                completed_scores.append(item.score)
                completed_returns.append(item.episode_return)
    finally:
        vecenv.close()

    return {
        "episodes": float(episodes),
        "mean_score": float(np.mean(completed_scores)),
        "mean_return": float(np.mean(completed_returns)),
        "max_score": float(np.max(completed_scores)),
    }

from __future__ import annotations

import ctypes
import fcntl
import json
import os
import platform
import socket
import subprocess
import sys
import threading
import time
import types
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from contextlib import suppress
from dataclasses import dataclass, replace
from itertools import repeat
from pathlib import Path
from urllib.parse import quote

import numpy as np
import torch
from torch import nn
from websockets.sync.client import ClientConnection, connect

REPO_ROOT = Path(__file__).resolve().parents[1]
RUNLOG_DIR = REPO_ROOT / "tools" / "runlogs" / "pufferlib"

SCREEN_WIDTH = 128
SCREEN_HEIGHT = 128
FRAME_PIXELS = SCREEN_WIDTH * SCREEN_HEIGHT
PACKED_FRAME_BYTES = FRAME_PIXELS // 2
RESET_INPUT_MASK = 255
DEFAULT_ACTION_REPEAT = 4
AMONG_THEM_STEP_ACTIVE = 0
AMONG_THEM_STEP_TERMINAL = 1
AMONG_THEM_STEP_TRUNCATED = 2
AMONG_THEM_MAX_PLAYERS = 16
OBSERVATION_MODES = {"pixels", "state"}
STATE_HEADER_FEATURES = 22
STATE_GRID_SIZE = 32
STATE_PLAYER_FEATURE_OFFSET = STATE_HEADER_FEATURES + STATE_GRID_SIZE * STATE_GRID_SIZE
STATE_PLAYER_FEATURES = 8
STATE_BODY_FEATURE_OFFSET = STATE_PLAYER_FEATURE_OFFSET + STATE_PLAYER_FEATURES * AMONG_THEM_MAX_PLAYERS
STATE_BODY_FEATURES = 8
STATE_TASK_FEATURE_OFFSET = STATE_BODY_FEATURE_OFFSET + STATE_BODY_FEATURES * AMONG_THEM_MAX_PLAYERS
STATE_TASK_FEATURES = 8
STATE_TASK_COUNT = 15
STATE_FEATURES = STATE_TASK_FEATURE_OFFSET + STATE_TASK_FEATURES * STATE_TASK_COUNT
STATE_TASK_PROGRESS_INDEX = 10
STATE_FLAG_TASK_ASSIGNED = 1
STATE_FLAG_TASK_COMPLETED = 32
STATE_FLAG_TASK_ICON_VISIBLE = 8
STATE_FLAG_TASK_ARROW_VISIBLE = 16
STATE_FLAG_PLAYER_ROLE_IMPOSTER = 8

BUTTON_UP = 1
BUTTON_DOWN = 2
BUTTON_LEFT = 4
BUTTON_RIGHT = 8
BUTTON_A = 32
BUTTON_B = 64

DIRECTION_MASKS = np.array(
    [
        0,
        BUTTON_UP,
        BUTTON_DOWN,
        BUTTON_LEFT,
        BUTTON_RIGHT,
        BUTTON_UP | BUTTON_LEFT,
        BUTTON_UP | BUTTON_RIGHT,
        BUTTON_DOWN | BUTTON_LEFT,
        BUTTON_DOWN | BUTTON_RIGHT,
    ],
    dtype=np.uint8,
)
ACTION_BUTTON_MASKS = np.array([0, BUTTON_A, BUTTON_B], dtype=np.uint8)
ACTION_MASKS = np.array([direction | button for direction in DIRECTION_MASKS for button in ACTION_BUTTON_MASKS], dtype=np.uint8)


def native_worker_count(num_envs: int) -> int:
    configured_workers = os.environ.get("BITWORLD_NATIVE_WORKERS")
    if configured_workers is not None:
        return min(num_envs, max(1, int(configured_workers)))
    return min(
        num_envs,
        max(1, (os.cpu_count() or 1) // max(1, int(os.environ.get("WORLD_SIZE", "1")))),
    )


def state_reward_shaping_scale() -> float:
    return float(os.environ.get("BITWORLD_STATE_REWARD_SHAPING", "0.1"))


def state_progress_reward_scale() -> float:
    return float(os.environ.get("BITWORLD_STATE_PROGRESS_REWARD", "0.02"))


SHARED_NIM_SOURCES = (
    REPO_ROOT / "common" / "protocol.nim",
    REPO_ROOT / "common" / "server.nim",
)
AMONG_THEM_NATIVE_SOURCE = REPO_ROOT / "pufferlib" / "among_them_native.nim"


@dataclass(frozen=True)
class EnvironmentSpec:
    name: str
    metric_name: str = "score"
    server_players: int = 1
    default_episode_steps: int = 64
    default_total_timesteps: int = 50_000
    learning_rate: float = 0.001
    horizon: int = 64
    minibatch_size: int = 512
    hidden_size: int = 256


ENV_SPECS: dict[str, EnvironmentSpec] = {
    "among_them": EnvironmentSpec(
        name="among_them",
        metric_name="task_progress",
        server_players=5,
        default_episode_steps=512,
    ),
    "asteroid_arena": EnvironmentSpec(name="asteroid_arena", default_episode_steps=96),
    "big_adventure": EnvironmentSpec(
        name="big_adventure",
        metric_name="coins_collected",
        default_episode_steps=512,
    ),
    "boundless_factory": EnvironmentSpec(name="boundless_factory", metric_name="factory_progress", default_episode_steps=1024),
    "bubble_eats": EnvironmentSpec(name="bubble_eats"),
    "fancy_cookout": EnvironmentSpec(name="fancy_cookout", metric_name="kitchen_progress", default_episode_steps=384),
    "free_chat": EnvironmentSpec(name="free_chat", metric_name="messages_published", default_episode_steps=192),
    "infinite_blocks": EnvironmentSpec(name="infinite_blocks", default_episode_steps=384),
    "overworld": EnvironmentSpec(name="overworld", metric_name="villages_entered", default_episode_steps=384),
    "planet_wars": EnvironmentSpec(name="planet_wars", default_episode_steps=96),
    "tag": EnvironmentSpec(name="tag", default_episode_steps=384),
}


def get_env_spec(spec: str | EnvironmentSpec) -> EnvironmentSpec:
    if isinstance(spec, EnvironmentSpec):
        return spec
    if spec not in ENV_SPECS:
        available = ", ".join(sorted(ENV_SPECS))
        raise KeyError(f"unknown BitWorld environment {spec!r}; expected one of: {available}")
    return ENV_SPECS[spec]


def with_server_players(spec: str | EnvironmentSpec, players: int | None) -> EnvironmentSpec:
    resolved = get_env_spec(spec)
    if players is None:
        return resolved
    if resolved.name != "among_them":
        raise ValueError("--players is only supported for among_them")
    if players < 1 or players > AMONG_THEM_MAX_PLAYERS:
        raise ValueError(f"--players must be between 1 and {AMONG_THEM_MAX_PLAYERS}")
    return replace(resolved, server_players=players)


def binary_is_fresh(spec: EnvironmentSpec) -> bool:
    source = REPO_ROOT / spec.name / f"{spec.name}.nim"
    binary = REPO_ROOT / spec.name / spec.name
    if not binary.exists():
        return False

    source_paths = {source, *SHARED_NIM_SOURCES}
    for dependency in ("server.nim", "sim.nim", "global.nim"):
        source_paths.add(source.parent / dependency)
    newest_source = max(path.stat().st_mtime for path in source_paths if path.exists())
    return binary.stat().st_mtime >= newest_source


def nim_path_args() -> list[str]:
    paths = [REPO_ROOT / "common"]
    for base in (REPO_ROOT / "client", REPO_ROOT / "among_them"):
        if not base.exists():
            continue
        for source_dir in sorted(base.glob("*/src")):
            paths.append(source_dir)
    return [f"--path:{path}" for path in paths if path.exists()]


def shared_library_suffix() -> str:
    system = platform.system()
    if system == "Darwin":
        return ".dylib"
    if system == "Windows":
        return ".dll"
    return ".so"


def among_them_native_library_path() -> Path:
    return RUNLOG_DIR / f"libamong_them_native{shared_library_suffix()}"


def among_them_native_library_is_fresh() -> bool:
    library = among_them_native_library_path()
    if not library.exists():
        return False

    source_paths = {
        AMONG_THEM_NATIVE_SOURCE,
        REPO_ROOT / "among_them" / "sim.nim",
        REPO_ROOT / "client" / "aseprite.nim",
        *SHARED_NIM_SOURCES,
    }
    newest_source = max(path.stat().st_mtime for path in source_paths if path.exists())
    return library.stat().st_mtime >= newest_source


def ensure_among_them_native_library() -> Path:
    library = among_them_native_library_path()
    if among_them_native_library_is_fresh():
        return library

    library.parent.mkdir(parents=True, exist_ok=True)
    lock_path = library.with_suffix(library.suffix + ".lock")
    nimcache = RUNLOG_DIR / "nimcache" / "among_them_native"
    nimcache.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        if among_them_native_library_is_fresh():
            return library
        subprocess.run(
            [
                "nim",
                "c",
                "--app:lib",
                "-d:release",
                "--opt:speed",
                *nim_path_args(),
                f"--nimcache:{nimcache}",
                f"--out:{library}",
                "pufferlib/among_them_native.nim",
            ],
            cwd=REPO_ROOT,
            check=True,
        )
    return library


def ensure_bitworld_binary(spec: str | EnvironmentSpec) -> None:
    resolved = get_env_spec(spec)
    if binary_is_fresh(resolved):
        return

    subprocess.run(
        ["nim", "c", *nim_path_args(), f"{resolved.name}/{resolved.name}.nim"],
        cwd=REPO_ROOT,
        check=True,
    )


def resolve_train_device(device: str = "auto") -> str:
    if device == "auto":
        if torch.cuda.is_available():
            return "cuda"
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return "mps"
        return "cpu"
    if device == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("--device cuda requested, but torch.cuda.is_available() is false")
    if device == "mps" and not (hasattr(torch.backends, "mps") and torch.backends.mps.is_available()):
        raise RuntimeError("--device mps requested, but torch.backends.mps.is_available() is false")
    if device not in {"cpu", "cuda", "mps"}:
        raise ValueError(f"unknown training device {device!r}")
    return device


def install_pufferlib_c_stub(use_gpu: bool) -> None:
    if "pufferlib._C" in sys.modules:
        sys.modules["pufferlib._C"].gpu = use_gpu
        return

    stub = types.ModuleType("pufferlib._C")
    stub.precision_bytes = 4
    stub.gpu = use_gpu
    stub.get_utilization = lambda gpu_id=0: {}
    sys.modules["pufferlib._C"] = stub


class FastBitWorldPuffeRL:
    def __init__(self, args, vecenv, policy, verbose: bool = False, state_aux_coef: float = 0.0):
        del verbose
        self.args = args
        self.vecenv = vecenv
        self.policy = policy
        self.unwrapped_policy = policy.module if hasattr(policy, "module") else policy
        self.config = puffer_train_config(args)
        self.device = torch.device(self.config["device"])
        self.world_size = int(args.get("world_size", 1))
        self.horizon = int(self.config["bptt_horizon"])
        self.total_agents = int(vecenv.total_agents)
        self.batch_size = self.total_agents * self.horizon
        self.minibatch_size = int(self.config["minibatch_size"])
        self.model_path = Path(args["checkpoint_dir"]).parent / "pufferlib_latest.pt"
        self.global_step = 0
        self.epoch = 0
        self.last_log_time = time.time()
        self.last_log_step = 0
        self._logs: dict[str, float] = {}
        self.optimizer = torch.optim.Adam(
            self.policy.parameters(),
            lr=float(self.config["learning_rate"]),
            betas=(float(self.config["adam_beta1"]), float(self.config["adam_beta2"])),
            eps=float(self.config["adam_eps"]),
        )
        self.vecenv.async_reset(int(args["train"]["seed"]))
        obs_shape = tuple(vecenv.single_observation_space.shape)
        self.observations = torch.empty(
            (self.horizon, self.total_agents, *obs_shape),
            dtype=torch.uint8,
            device=self.device,
        )
        self.actions = torch.empty((self.horizon, self.total_agents), dtype=torch.long, device=self.device)
        self.logprobs = torch.empty((self.horizon, self.total_agents), dtype=torch.float32, device=self.device)
        self.values = torch.empty((self.horizon, self.total_agents), dtype=torch.float32, device=self.device)
        self.rewards = torch.empty((self.horizon, self.total_agents), dtype=torch.float32, device=self.device)
        self.terminals = torch.empty((self.horizon, self.total_agents), dtype=torch.float32, device=self.device)
        self.env_logs: dict = {}
        self.state_aux_coef = float(state_aux_coef)
        self.state_targets: torch.Tensor | None = None
        if self.state_aux_coef > 0.0:
            if self.vecenv.state_targets is None:
                raise ValueError("state_aux_coef > 0 requires vecenv with collect_state_target=True")
            self.state_targets = torch.empty(
                (self.horizon, self.total_agents, STATE_FEATURES),
                dtype=torch.uint8,
                device=self.device,
            )

    def rollouts(self):
        observations = self.vecenv._obs
        for t in range(self.horizon):
            obs_device = torch.as_tensor(observations, device=self.device)
            with torch.no_grad():
                logits, value = self.policy.forward_eval(obs_device)
                dist = torch.distributions.Categorical(logits=logits)
                action = dist.sample()
                logprob = dist.log_prob(action)
            self.observations[t].copy_(obs_device)
            self.actions[t].copy_(action)
            self.logprobs[t].copy_(logprob)
            self.values[t].copy_(value.flatten())
            observations, rewards, terminals, _completed = self.vecenv.step_discrete(action.cpu().numpy())
            self.rewards[t].copy_(torch.as_tensor(rewards, device=self.device))
            self.terminals[t].copy_(torch.as_tensor(terminals, device=self.device).float())
            if self.state_targets is not None:
                state_target = self.vecenv.state_targets
                assert state_target is not None
                self.state_targets[t].copy_(torch.as_tensor(state_target, device=self.device))
        self.global_step += self.batch_size
        self.env_logs = self.vecenv.log()

    def _advantages(self) -> tuple[torch.Tensor, torch.Tensor]:
        advantages = torch.empty_like(self.rewards)
        last_advantage = torch.zeros(self.total_agents, device=self.device)
        next_value = torch.zeros(self.total_agents, device=self.device)
        gamma = float(self.config["gamma"])
        gae_lambda = float(self.config["gae_lambda"])
        for t in range(self.horizon - 1, -1, -1):
            next_nonterminal = 1.0 - self.terminals[t]
            delta = self.rewards[t] + gamma * next_value * next_nonterminal - self.values[t]
            last_advantage = delta + gamma * gae_lambda * next_nonterminal * last_advantage
            advantages[t] = last_advantage
            next_value = self.values[t]
        returns = advantages + self.values
        return advantages, returns

    def train(self):
        advantages, returns = self._advantages()
        flat_observations = self.observations.reshape(self.batch_size, *self.vecenv.single_observation_space.shape)
        flat_actions = self.actions.reshape(self.batch_size)
        flat_old_logprobs = self.logprobs.reshape(self.batch_size)
        flat_advantages = advantages.reshape(self.batch_size)
        flat_returns = returns.reshape(self.batch_size)
        flat_values = self.values.reshape(self.batch_size)
        flat_advantages = (flat_advantages - flat_advantages.mean()) / (flat_advantages.std() + 1e-8)
        flat_state_targets: torch.Tensor | None = None
        if self.state_targets is not None:
            flat_state_targets = self.state_targets.reshape(self.batch_size, STATE_FEATURES)

        clip_coef = float(self.config["clip_coef"])
        vf_clip = float(self.config["vf_clip_coef"])
        vf_coef = float(self.config["vf_coef"])
        ent_coef = float(self.config["ent_coef"])
        max_grad_norm = float(self.config["max_grad_norm"])
        losses = {
            "policy_loss": 0.0,
            "value_loss": 0.0,
            "entropy": 0.0,
            "old_approx_kl": 0.0,
            "approx_kl": 0.0,
            "clipfrac": 0.0,
            "importance": 0.0,
            "state_aux_loss": 0.0,
        }
        minibatches = 0
        self.optimizer.zero_grad()
        for start in range(0, self.batch_size, self.minibatch_size):
            end = min(start + self.minibatch_size, self.batch_size)
            policy_out = self.policy(flat_observations[start:end])
            if len(policy_out) == 3:
                logits, new_values, state_pred = policy_out
            else:
                logits, new_values = policy_out
                state_pred = None
            dist = torch.distributions.Categorical(logits=logits)
            new_logprobs = dist.log_prob(flat_actions[start:end])
            entropy = dist.entropy().mean()
            logratio = new_logprobs - flat_old_logprobs[start:end]
            ratio = logratio.exp()
            advantages_mb = flat_advantages[start:end]
            pg_loss = torch.max(
                -advantages_mb * ratio,
                -advantages_mb * torch.clamp(ratio, 1 - clip_coef, 1 + clip_coef),
            ).mean()
            new_values = new_values.flatten()
            old_values = flat_values[start:end]
            returns_mb = flat_returns[start:end]
            v_clipped = old_values + torch.clamp(new_values - old_values, -vf_clip, vf_clip)
            v_loss = 0.5 * torch.max((new_values - returns_mb).square(), (v_clipped - returns_mb).square()).mean()
            loss = pg_loss + vf_coef * v_loss - ent_coef * entropy
            if state_pred is not None and flat_state_targets is not None:
                target_mb = flat_state_targets[start:end].float().div(255.0)
                state_aux_loss = (state_pred - target_mb).square().mean()
                loss = loss + self.state_aux_coef * state_aux_loss
            else:
                state_aux_loss = None
            loss.backward()
            with torch.no_grad():
                losses["policy_loss"] += float(pg_loss)
                losses["value_loss"] += float(v_loss)
                losses["entropy"] += float(entropy)
                losses["old_approx_kl"] += float((-logratio).mean())
                losses["approx_kl"] += float(((ratio - 1) - logratio).mean())
                losses["clipfrac"] += float(((ratio - 1.0).abs() > clip_coef).float().mean())
                losses["importance"] += float(ratio.mean())
                if state_aux_loss is not None:
                    losses["state_aux_loss"] += float(state_aux_loss)
            minibatches += 1
        torch.nn.utils.clip_grad_norm_(self.policy.parameters(), max_grad_norm)
        self.optimizer.step()
        self.epoch += 1
        for key in losses:
            losses[key] /= max(1, minibatches)
        now = time.time()
        global_steps = self.global_step * self.world_size
        step_delta = global_steps - self.last_log_step
        elapsed = max(now - self.last_log_time, 1e-6)
        sps = step_delta / elapsed
        self.last_log_time = now
        self.last_log_step = global_steps
        self._logs = {
            "agent_steps": float(global_steps),
            "SPS": float(sps),
            **{f"losses/{key}": value for key, value in losses.items()},
            **{env_log_key(key): float(value) for key, value in flatten_logs(self.env_logs).items()},
        }
        if self.epoch % int(self.config["checkpoint_interval"]) == 0:
            self.save_weights(str(self.model_path))
        return self._logs

    def log(self) -> dict[str, float]:
        return self._logs

    def save_weights(self, path: str) -> None:
        torch.save(self.unwrapped_policy.state_dict(), path)

    def close(self) -> None:
        self.vecenv.close()


def load_puffer_trainer(use_gpu: bool):
    install_pufferlib_c_stub(use_gpu)
    return FastBitWorldPuffeRL


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def unpack_frame(packet: bytes) -> np.ndarray:
    if len(packet) != PACKED_FRAME_BYTES:
        raise ValueError(f"expected {PACKED_FRAME_BYTES} packed frame bytes, received {len(packet)}")
    packed = np.frombuffer(packet, dtype=np.uint8)
    frame = np.empty(FRAME_PIXELS, dtype=np.uint8)
    frame[0::2] = packed & 0x0F
    frame[1::2] = packed >> 4
    return frame


def parse_reward_payload(payload: bytes | str, player_name: str | None = None) -> int:
    text = payload.decode("utf-8") if isinstance(payload, bytes) else payload
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == "reward":
            if player_name is None or parts[1] == player_name:
                return int(parts[2])
    if not text.strip():
        return 0
    raise ValueError(f"invalid reward payload: {text!r}")


def flatten_logs(logs: dict, prefix: str = "") -> dict[str, float]:
    flat: dict[str, float] = {}
    for key, value in logs.items():
        next_key = f"{prefix}/{key}" if prefix else key
        if isinstance(value, dict):
            flat.update(flatten_logs(value, next_key))
        else:
            flat[next_key] = value
    return flat


def env_log_key(key: str) -> str:
    if "/" not in key:
        return f"env/{key}"
    namespace, metric = key.split("/", 1)
    return f"env_{namespace}/{metric}"


@dataclass
class EpisodeStats:
    score: float
    length: int
    episode_return: float
    tasks_completed: float = 0.0
    shaping_return: float = 0.0

    def info(self, metric_name: str) -> dict[str, dict[str, float]]:
        game = {
            "score": float(self.score),
            "tasks_completed": float(self.tasks_completed),
        }
        if metric_name != "score":
            game[metric_name] = float(self.score)
        return {
            "game": game,
            "episode": {
                "length": float(self.length),
                "return": float(self.episode_return),
                "shaping_return": float(self.shaping_return),
            },
        }


@dataclass
class PolicyCheckpoint:
    policy: "BitWorldPolicy"
    frame_stack: int
    action_count: int
    hidden_size: int
    observation_mode: str
    obs_shape: tuple[int, ...]


def infer_policy_shape(state_dict: dict[str, torch.Tensor]) -> tuple[int, int, int, str, tuple[int, ...]]:
    action_count = int(state_dict["policy_head.bias"].shape[0])
    if "encoder.0.weight" in state_dict:
        frame_stack = int(state_dict["encoder.0.weight"].shape[1])
        hidden_size = int(state_dict["body.0.weight"].shape[0])
        return frame_stack, hidden_size, action_count, "pixels", (frame_stack, SCREEN_HEIGHT, SCREEN_WIDTH)
    frame_stack = 1
    hidden_size = int(state_dict["body.0.weight"].shape[0])
    feature_count = int(state_dict["body.0.weight"].shape[1])
    action_count = int(state_dict["policy_head.bias"].shape[0])
    return frame_stack, hidden_size, action_count, "state", (feature_count,)


def load_policy_checkpoint(path: Path, device: str = "cpu") -> PolicyCheckpoint:
    checkpoint = torch.load(path, map_location=device)
    if not isinstance(checkpoint, dict):
        raise TypeError(f"unsupported policy checkpoint: {path}")
    state_dict = checkpoint
    checkpoint_frame_stack, checkpoint_hidden_size, checkpoint_action_count, observation_mode, obs_shape = infer_policy_shape(
        state_dict
    )
    state_aux = "state_pred_head.weight" in state_dict

    policy = BitWorldPolicy(
        frame_stack=checkpoint_frame_stack,
        action_count=checkpoint_action_count,
        hidden_size=checkpoint_hidden_size,
        observation_mode=observation_mode,
        obs_shape=obs_shape,
        state_aux=state_aux,
    ).to(device)
    policy.load_state_dict(state_dict)
    policy.eval()
    return PolicyCheckpoint(
        policy=policy,
        frame_stack=checkpoint_frame_stack,
        action_count=checkpoint_action_count,
        hidden_size=checkpoint_hidden_size,
        observation_mode=observation_mode,
        obs_shape=obs_shape,
    )


def select_policy_action(
    policy: "BitWorldPolicy",
    observation: np.ndarray,
    device: str,
    sample_actions: bool = True,
) -> tuple[int, int]:
    with torch.no_grad():
        observation_tensor = torch.as_tensor(observation.reshape(1, -1), device=device)
        logits, _ = policy.forward_eval(observation_tensor)
        if sample_actions:
            probs = torch.softmax(logits, dim=-1)
            action_index = int(torch.multinomial(probs, 1).item())
        else:
            action_index = int(torch.argmax(logits, dim=-1).item())
    action_index = max(0, min(action_index, len(ACTION_MASKS) - 1))
    return action_index, int(ACTION_MASKS[action_index])


def policy_player_url(address: str, port: int, name: str) -> str:
    suffix = "?name=" + quote(name, safe="") if name else ""
    return f"ws://{address}:{port}/player{suffix}"


def connect_websocket(url: str, timeout: float = 10.0) -> ClientConnection:
    deadline = time.time() + timeout
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            return connect(url, open_timeout=1.0, ping_interval=None, max_size=None, proxy=None)
        except Exception as exc:
            last_error = exc
            time.sleep(0.05)
    raise RuntimeError(f"failed to connect to {url}") from last_error


def run_policy_websocket_client(
    checkpoint_path: Path,
    address: str,
    port: int,
    name: str,
    duration_seconds: float,
    action_repeat: int = DEFAULT_ACTION_REPEAT,
    device: str = "auto",
    sample_actions: bool = True,
) -> dict[str, object]:
    if action_repeat <= 0:
        raise ValueError("action_repeat must be positive")

    resolved_device = resolve_train_device(device)
    checkpoint = load_policy_checkpoint(checkpoint_path, device=resolved_device)
    frame_history = np.zeros((checkpoint.frame_stack, FRAME_PIXELS), dtype=np.uint8)
    unique_masks: set[int] = set()
    stop = threading.Event()
    frames_received = 0
    actions_sent = 0
    nonzero_actions = 0
    reward = 0
    reward_updates = 0

    def reward_reader() -> None:
        nonlocal reward, reward_updates
        try:
            with connect_websocket(f"ws://{address}:{port}/reward") as reward_ws:
                while not stop.is_set():
                    try:
                        payload = reward_ws.recv(timeout=1.0)
                    except TimeoutError:
                        continue
                    try:
                        next_reward = parse_reward_payload(payload, name)
                    except ValueError:
                        continue
                    reward = next_reward
                    reward_updates += 1
        except Exception:
            return

    reward_thread = threading.Thread(target=reward_reader, name="bitworld-policy-reward", daemon=True)
    reward_thread.start()

    url = policy_player_url(address, port, name)
    deadline = time.monotonic() + duration_seconds if duration_seconds > 0 else None
    last_action_frame = -action_repeat
    last_mask: int | None = None

    try:
        with connect_websocket(url) as player_ws:
            while deadline is None or time.monotonic() < deadline:
                try:
                    payload = player_ws.recv(timeout=1.0)
                except TimeoutError:
                    continue
                if not isinstance(payload, (bytes, bytearray)):
                    continue

                frame = unpack_frame(bytes(payload))
                if frames_received == 0:
                    frame_history[:] = frame
                else:
                    frame_history[:-1] = frame_history[1:]
                    frame_history[-1] = frame

                frames_received += 1
                if frames_received - last_action_frame < action_repeat:
                    continue

                _, action_mask = select_policy_action(
                    checkpoint.policy,
                    frame_history.reshape(-1),
                    resolved_device,
                    sample_actions=sample_actions,
                )
                if action_mask != last_mask:
                    player_ws.send(bytes([action_mask]), text=False)
                    last_mask = action_mask
                    actions_sent += 1
                    if action_mask != 0:
                        nonzero_actions += 1
                    unique_masks.add(action_mask)
                last_action_frame = frames_received
    finally:
        stop.set()
        reward_thread.join(timeout=2.0)

    return {
        "name": name,
        "url": url,
        "checkpoint": str(checkpoint_path),
        "device": resolved_device,
        "frame_stack": checkpoint.frame_stack,
        "hidden_size": checkpoint.hidden_size,
        "frames_received": frames_received,
        "actions_sent": actions_sent,
        "nonzero_actions": nonzero_actions,
        "unique_action_masks": sorted(unique_masks),
        "reward": reward,
        "reward_updates": reward_updates,
    }


class AmongThemNativeLibrary:
    def __init__(self) -> None:
        library_path = ensure_among_them_native_library()
        self.lib = ctypes.CDLL(str(library_path))
        self.lib.NimMain.argtypes = []
        self.lib.NimMain.restype = None
        self.lib.NimMain()
        self.lib.bitworld_at_last_error.argtypes = []
        self.lib.bitworld_at_last_error.restype = ctypes.c_char_p
        self.lib.bitworld_at_tick_count.argtypes = [ctypes.c_int]
        self.lib.bitworld_at_tick_count.restype = ctypes.c_int
        self.lib.bitworld_at_game_hash.argtypes = [ctypes.c_int]
        self.lib.bitworld_at_game_hash.restype = ctypes.c_uint64
        self.lib.bitworld_at_create.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
        ]
        self.lib.bitworld_at_create.restype = ctypes.c_int
        self.lib.bitworld_at_reset.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.POINTER(ctypes.c_float),
        ]
        self.lib.bitworld_at_reset.restype = ctypes.c_int
        self.lib.bitworld_at_reset_state.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.POINTER(ctypes.c_float),
        ]
        self.lib.bitworld_at_reset_state.restype = ctypes.c_int
        self.lib.bitworld_at_step.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.POINTER(ctypes.c_float),
        ]
        self.lib.bitworld_at_step.restype = ctypes.c_int
        self.lib.bitworld_at_step_state.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.POINTER(ctypes.c_float),
        ]
        self.lib.bitworld_at_step_state.restype = ctypes.c_int
        self.lib.bitworld_at_reset_state_batch.argtypes = [
            ctypes.POINTER(ctypes.c_int),
            ctypes.c_int,
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.POINTER(ctypes.c_float),
        ]
        self.lib.bitworld_at_reset_state_batch.restype = ctypes.c_int
        self.lib.bitworld_at_step_state_batch.argtypes = [
            ctypes.POINTER(ctypes.c_int),
            ctypes.c_int,
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.POINTER(ctypes.c_float),
        ]
        self.lib.bitworld_at_step_state_batch.restype = ctypes.c_int
        self.lib.bitworld_at_step_rewards.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_float),
        ]
        self.lib.bitworld_at_step_rewards.restype = ctypes.c_int
        self.lib.bitworld_at_observe_state.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8),
        ]
        self.lib.bitworld_at_observe_state.restype = ctypes.c_int
        self.lib.bitworld_at_close.argtypes = [ctypes.c_int]
        self.lib.bitworld_at_close.restype = None

    def check(self, result: int) -> int:
        if result >= 0:
            return result
        message = self.lib.bitworld_at_last_error()
        if message:
            raise RuntimeError(message.decode("utf-8", errors="replace"))
        raise RuntimeError("Among Them native env failed")


_AMONG_THEM_NATIVE_LIBRARY: AmongThemNativeLibrary | None = None


def among_them_native_library() -> AmongThemNativeLibrary:
    global _AMONG_THEM_NATIVE_LIBRARY
    if _AMONG_THEM_NATIVE_LIBRARY is None:
        _AMONG_THEM_NATIVE_LIBRARY = AmongThemNativeLibrary()
    return _AMONG_THEM_NATIVE_LIBRARY


class AmongThemNativeWorker:
    agent_count: int

    def __init__(
        self,
        spec: EnvironmentSpec,
        env_id: int,
        seed: int,
        max_episode_steps: int,
        action_repeat: int,
        observation_mode: str,
        collect_state_target: bool = False,
        imposter_count: int = -1,
        tasks_per_player: int = -1,
        task_complete_ticks: int = -1,
        kill_cooldown_ticks: int = -1,
    ) -> None:
        if spec.name != "among_them":
            raise ValueError("AmongThemNativeWorker only supports among_them")
        if observation_mode not in OBSERVATION_MODES:
            raise ValueError(f"unknown observation_mode {observation_mode!r}")
        self.spec = spec
        self.env_id = env_id
        self.seed = seed
        self.max_ticks = max_episode_steps * action_repeat
        self.action_repeat = action_repeat
        self.observation_mode = observation_mode
        self.agent_count = spec.server_players
        self.native = among_them_native_library()
        self.handle = self.native.check(
            self.native.lib.bitworld_at_create(
                seed,
                self.agent_count,
                self.max_ticks,
                imposter_count,
                tasks_per_player,
                task_complete_ticks,
                kill_cooldown_ticks,
            )
        )
        feature_count = FRAME_PIXELS if observation_mode == "pixels" else STATE_FEATURES
        dtype = np.uint8
        self.frames = np.zeros((self.agent_count, feature_count), dtype=dtype)
        self.rewards = np.zeros((self.agent_count,), dtype=np.float32)
        self.base_score = np.zeros((self.agent_count,), dtype=np.float32)
        self.score = np.zeros((self.agent_count,), dtype=np.float32)
        self.episode_return = np.zeros((self.agent_count,), dtype=np.float32)
        self.episode_steps = 0
        self.episode = 0
        self.done = False
        self.truncated = False
        self.collect_state_target = collect_state_target and observation_mode == "pixels"
        if self.collect_state_target:
            self.state_targets = np.zeros((self.agent_count, STATE_FEATURES), dtype=np.uint8)
        else:
            self.state_targets = None

    def _obs_ptr(self):
        return self.frames.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8))

    def _reward_ptr(self):
        return self.rewards.ctypes.data_as(ctypes.POINTER(ctypes.c_float))

    def _state_target_ptr(self):
        return self.state_targets.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8))

    def _refresh_state_targets(self) -> None:
        if not self.collect_state_target:
            return
        self.native.check(
            self.native.lib.bitworld_at_observe_state(
                self.handle,
                self._state_target_ptr(),
            )
        )

    def reset(self) -> np.ndarray:
        if self.observation_mode == "pixels":
            self.native.check(
                self.native.lib.bitworld_at_reset(
                    self.handle,
                    self._obs_ptr(),
                    self._reward_ptr(),
                )
            )
        else:
            self.native.check(
                self.native.lib.bitworld_at_reset_state(
                    self.handle,
                    self._obs_ptr(),
                    self._reward_ptr(),
                )
            )
        self.base_score.fill(0.0)
        self.score.fill(0.0)
        self.episode_return.fill(0.0)
        self.episode_steps = 0
        self.episode += 1
        self.done = False
        self.truncated = False
        self._refresh_state_targets()
        return self.frames.copy()

    def step(self, action_masks: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        masks = np.asarray(action_masks, dtype=np.uint8)
        if masks.shape != (self.agent_count,):
            raise ValueError(f"expected {self.agent_count} Among Them action masks")
        masks = np.ascontiguousarray(masks)
        if self.observation_mode == "pixels":
            status = self.native.check(
                self.native.lib.bitworld_at_step(
                    self.handle,
                    masks.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
                    self.action_repeat,
                    self._obs_ptr(),
                    self._reward_ptr(),
                )
            )
        else:
            status = self.native.check(
                self.native.lib.bitworld_at_step_state(
                    self.handle,
                    masks.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
                    self.action_repeat,
                    self._obs_ptr(),
                    self._reward_ptr(),
                )
            )
        if status not in {AMONG_THEM_STEP_ACTIVE, AMONG_THEM_STEP_TERMINAL, AMONG_THEM_STEP_TRUNCATED}:
            raise RuntimeError(f"unknown Among Them native step status {status}")
        self.done = status != AMONG_THEM_STEP_ACTIVE
        self.truncated = status == AMONG_THEM_STEP_TRUNCATED
        self.score += self.rewards
        self.episode_return += self.rewards
        self.episode_steps += 1
        self._refresh_state_targets()
        return self.frames.copy(), self.rewards.copy()

    def close(self) -> None:
        if self.handle >= 0:
            self.native.lib.bitworld_at_close(self.handle)
            self.handle = -1


class BitWorldWorker:
    agent_count = 1

    def __init__(
        self,
        spec: str | EnvironmentSpec,
        env_id: int,
        port: int,
        seed: int,
        action_repeat: int,
    ) -> None:
        self.spec = get_env_spec(spec)
        self.env_id = env_id
        self.port = port
        self.seed = seed
        self.action_repeat = action_repeat
        self.player_name = "player1"
        self.process: subprocess.Popen[str] | None = None
        self.connection: ClientConnection | None = None
        self.reward_connection: ClientConnection | None = None
        self.companion_connections: list[ClientConnection] = []
        self.log_file = None
        self.base_score = 0
        self.score = 0
        self.episode = 0
        self.episode_return = 0.0
        self.episode_steps = 0
        self._condition = threading.Condition()
        self._frame_seq = 0
        self._reward_seq = 0
        self._latest_frame: np.ndarray | None = None
        self._latest_reward: int | None = None
        self._reader_error: Exception | None = None
        self._closed = False
        self._reader_thread: threading.Thread | None = None
        self._reward_reader_thread: threading.Thread | None = None
        self._companion_threads: list[threading.Thread] = []
        try:
            self._start_server()
            first_frame, _ = self._wait_for_frame(lambda _frame, _seq: True)
            reward, _ = self._wait_for_reward(lambda _reward, _seq: True)
        except Exception:
            self.close()
            raise
        del first_frame
        self.score = reward

    def _start_server(self) -> None:
        ensure_bitworld_binary(self.spec)
        RUNLOG_DIR.mkdir(parents=True, exist_ok=True)
        game_dir = REPO_ROOT / self.spec.name
        binary = game_dir / self.spec.name
        log_path = RUNLOG_DIR / f"{self.spec.name}_{self.env_id}.log"
        self.log_file = log_path.open("w")
        server_args = [
            str(binary),
            "--address:127.0.0.1",
            f"--port:{self.port}",
        ]
        config = {
            "seed": self.seed,
        }
        if self.spec.name == "among_them":
            config.update(
                {
                    "minPlayers": self.spec.server_players,
                }
            )
        server_args.append(
            f"--config:{json.dumps(config, separators=(',', ':'))}"
        )
        self.process = subprocess.Popen(
            server_args,
            cwd=game_dir,
            stdout=self.log_file,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.connection = self._connect(self._player_path(1))
        self.reward_connection = self._connect("/reward")
        for player_id in range(2, self.spec.server_players + 1):
            self.companion_connections.append(self._connect(self._player_path(player_id)))
        for player_id, connection in enumerate(self.companion_connections, start=2):
            thread = threading.Thread(
                target=self._companion_reader_loop,
                args=(connection,),
                name=f"bitworld-{self.spec.name}-{self.env_id}-companion-{player_id}-reader",
                daemon=True,
            )
            thread.start()
            self._companion_threads.append(thread)
        self._reader_thread = threading.Thread(
            target=self._reader_loop,
            name=f"bitworld-{self.spec.name}-{self.env_id}-reader",
            daemon=True,
        )
        self._reader_thread.start()
        self._reward_reader_thread = threading.Thread(
            target=self._reward_reader_loop,
            name=f"bitworld-{self.spec.name}-{self.env_id}-reward-reader",
            daemon=True,
        )
        self._reward_reader_thread.start()

    def _player_path(self, player_id: int) -> str:
        return f"/player?name=player{player_id}"

    def _connect(self, path: str) -> ClientConnection:
        deadline = time.time() + 10.0
        url = f"ws://127.0.0.1:{self.port}{path}"
        last_error: Exception | None = None
        while time.time() < deadline:
            try:
                return connect(url, open_timeout=1.0, ping_interval=None, max_size=None, proxy=None)
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                time.sleep(0.05)
        raise RuntimeError(f"failed to connect to {url}") from last_error

    def _receive_packet(self) -> np.ndarray:
        assert self.connection is not None
        payload = self.connection.recv(timeout=10.0)
        if not isinstance(payload, (bytes, bytearray)):
            raise TypeError(f"expected binary websocket payload, got {type(payload)!r}")
        return unpack_frame(bytes(payload))

    def _reader_loop(self) -> None:
        assert self.connection is not None
        while True:
            with self._condition:
                if self._closed:
                    return
            try:
                frame = self._receive_packet()
            except TimeoutError:
                continue
            except Exception as exc:  # noqa: BLE001
                with self._condition:
                    if not self._closed:
                        self._reader_error = exc
                        self._condition.notify_all()
                return

            with self._condition:
                self._latest_frame = frame
                self._frame_seq += 1
                self._condition.notify_all()

    def _reward_reader_loop(self) -> None:
        assert self.reward_connection is not None
        while True:
            with self._condition:
                if self._closed:
                    return
            try:
                payload = self.reward_connection.recv(timeout=10.0)
                if not isinstance(payload, (bytes, str)):
                    raise TypeError(f"expected reward websocket payload, got {type(payload)!r}")
                reward = parse_reward_payload(payload, self.player_name)
            except TimeoutError:
                continue
            except Exception as exc:  # noqa: BLE001
                with self._condition:
                    if not self._closed:
                        self._reader_error = exc
                        self._condition.notify_all()
                return

            with self._condition:
                self._latest_reward = reward
                self._reward_seq += 1
                self._condition.notify_all()

    def _companion_reader_loop(self, connection: ClientConnection) -> None:
        while True:
            with self._condition:
                if self._closed:
                    return
            try:
                payload = connection.recv(timeout=10.0)
                if not isinstance(payload, (bytes, bytearray)):
                    raise TypeError(f"expected binary websocket payload, got {type(payload)!r}")
            except TimeoutError:
                continue
            except Exception as exc:  # noqa: BLE001
                with self._condition:
                    if not self._closed:
                        self._reader_error = exc
                        self._condition.notify_all()
                return

    def _wait_for_frame(
        self,
        predicate,
        timeout: float = 10.0,
    ) -> tuple[np.ndarray, int]:
        deadline = time.time() + timeout
        with self._condition:
            while True:
                if self._reader_error is not None:
                    raise RuntimeError(f"{self.spec.name} worker reader failed") from self._reader_error
                if self._latest_frame is not None and predicate(self._latest_frame, self._frame_seq):
                    return self._latest_frame, self._frame_seq
                remaining = deadline - time.time()
                if remaining <= 0.0:
                    raise TimeoutError(f"timed out waiting for {self.spec.name} frame")
                self._condition.wait(remaining)

    def _wait_for_reward(
        self,
        predicate,
        timeout: float = 10.0,
    ) -> tuple[int, int]:
        deadline = time.time() + timeout
        with self._condition:
            while True:
                if self._reader_error is not None:
                    raise RuntimeError(f"{self.spec.name} worker reader failed") from self._reader_error
                if self._latest_reward is not None and predicate(self._latest_reward, self._reward_seq):
                    return self._latest_reward, self._reward_seq
                remaining = deadline - time.time()
                if remaining <= 0.0:
                    raise TimeoutError(f"timed out waiting for {self.spec.name} reward")
                self._condition.wait(remaining)

    def reset(self) -> np.ndarray:
        assert self.connection is not None
        with self._condition:
            start_seq = self._frame_seq
            start_reward_seq = self._reward_seq
        self.connection.send(bytes([RESET_INPUT_MASK]), text=False)
        frame, _ = self._wait_for_frame(lambda _item, seq: seq > start_seq)
        reward, _ = self._wait_for_reward(lambda _item, seq: seq > start_reward_seq)
        self.base_score = reward
        self.score = reward
        self.episode += 1
        self.episode_return = 0.0
        self.episode_steps = 0
        return frame

    def step(self, action_mask: int) -> tuple[np.ndarray, float]:
        assert self.connection is not None
        with self._condition:
            start_seq = self._frame_seq
            start_reward_seq = self._reward_seq
        self.connection.send(bytes([action_mask]), text=False)
        frame, _ = self._wait_for_frame(
            lambda _item, seq: seq >= start_seq + self.action_repeat
        )
        snapshot, _ = self._wait_for_reward(
            lambda _item, seq: seq >= start_reward_seq + self.action_repeat
        )
        reward_delta = float(snapshot - self.score)
        self.score = snapshot
        self.episode_return += reward_delta
        self.episode_steps += 1
        return frame, reward_delta

    def close(self) -> None:
        with self._condition:
            self._closed = True
            self._condition.notify_all()

        if self.connection is not None:
            with suppress(Exception):
                self.connection.close()
            self.connection = None

        if self.reward_connection is not None:
            with suppress(Exception):
                self.reward_connection.close()
            self.reward_connection = None

        for connection in self.companion_connections:
            with suppress(Exception):
                connection.close()
        self.companion_connections = []

        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2.0)
            self.process = None

        if self._reader_thread is not None:
            self._reader_thread.join(timeout=2.0)
            self._reader_thread = None

        if self._reward_reader_thread is not None:
            self._reward_reader_thread.join(timeout=2.0)
            self._reward_reader_thread = None

        for thread in self._companion_threads:
            thread.join(timeout=2.0)
        self._companion_threads = []

        if self.log_file is not None:
            self.log_file.close()
            self.log_file = None


class BitWorldVecEnv:
    gpu = False
    obs_dtype = "ByteTensor"
    num_atns = 1

    def __init__(
        self,
        spec: str | EnvironmentSpec,
        num_envs: int,
        max_episode_steps: int,
        frame_stack: int = 4,
        action_repeat: int = DEFAULT_ACTION_REPEAT,
        base_seed: int = 73,
        observation_mode: str = "pixels",
        collect_state_target: bool = False,
        enable_state_shaping: bool = False,
        imposter_count: int = -1,
        tasks_per_player: int = -1,
        task_complete_ticks: int = -1,
        kill_cooldown_ticks: int = -1,
    ) -> None:
        if num_envs <= 0:
            raise ValueError("num_envs must be positive")
        if frame_stack <= 0:
            raise ValueError("frame_stack must be positive")
        if action_repeat <= 0:
            raise ValueError("action_repeat must be positive")
        if max_episode_steps <= 0:
            raise ValueError("max_episode_steps must be positive")
        if observation_mode not in OBSERVATION_MODES:
            raise ValueError(f"unknown observation_mode {observation_mode!r}")

        self.spec = get_env_spec(spec)
        if observation_mode == "state" and self.spec.name != "among_them":
            raise ValueError("state observations are only implemented for among_them")
        if self.spec.name == "among_them" and not 1 <= self.spec.server_players <= AMONG_THEM_MAX_PLAYERS:
            raise ValueError(f"among_them server_players must be between 1 and {AMONG_THEM_MAX_PLAYERS}")
        if enable_state_shaping and (self.spec.name != "among_them" or observation_mode != "pixels"):
            raise ValueError("enable_state_shaping requires among_them with pixel observations")
        if enable_state_shaping:
            collect_state_target = True
        if collect_state_target and (self.spec.name != "among_them" or observation_mode != "pixels"):
            raise ValueError("collect_state_target requires among_them with pixel observations")
        self.num_envs = num_envs
        self.observation_mode = observation_mode
        self.collect_state_target = collect_state_target
        self.enable_state_shaping = enable_state_shaping
        self.agents_per_env = self.spec.server_players if self.spec.name == "among_them" else 1
        self.total_agents = num_envs * self.agents_per_env
        self.num_agents = self.total_agents
        self.agents_per_batch = self.total_agents
        self.max_episode_steps = max_episode_steps
        self.frame_stack = frame_stack
        self.action_repeat = action_repeat
        self.obs_features = FRAME_PIXELS if observation_mode == "pixels" else STATE_FEATURES
        self.obs_dtype = np.uint8
        self.obs_size = self.obs_features * frame_stack
        self.action_count = len(ACTION_MASKS)
        self.driver_env = self
        from gymnasium import spaces

        self.single_observation_space = spaces.Box(
            low=0,
            high=15 if observation_mode == "pixels" else 255,
            shape=(self.obs_size,),
            dtype=self.obs_dtype,
        )
        self.single_action_space = spaces.Discrete(self.action_count)

        self._frame_history = np.zeros((self.total_agents, frame_stack, self.obs_features), dtype=self.obs_dtype)
        self._latest_frames = np.zeros((self.total_agents, self.obs_features), dtype=self.obs_dtype)
        self._obs = np.zeros((self.total_agents, self.obs_size), dtype=self.obs_dtype)
        self._rewards = np.zeros((self.total_agents,), dtype=np.float32)
        self._terminals = np.zeros((self.total_agents,), dtype=np.float32)
        self._truncations = np.zeros((self.total_agents,), dtype=np.float32)
        self.masks = np.ones((self.total_agents,), dtype=bool)
        self.agent_ids = np.arange(self.total_agents)
        self.infos: list[dict] = []
        self.observation_space = spaces.Box(
            low=0,
            high=15 if observation_mode == "pixels" else 255,
            shape=self._obs.shape,
            dtype=self.obs_dtype,
        )
        self.action_space = spaces.Discrete(self.action_count)
        self.obs_ptr = self._obs.ctypes.data
        self.rewards_ptr = self._rewards.ctypes.data
        self.terminals_ptr = self._terminals.ctypes.data

        self._completed_scores: deque[float] = deque(maxlen=100)
        self._completed_lengths: deque[float] = deque(maxlen=100)
        self._completed_returns: deque[float] = deque(maxlen=100)
        self._completed_tasks: deque[float] = deque(maxlen=100)
        self._completed_shaping_returns: deque[float] = deque(maxlen=100)
        self._completed_episodes = 0
        self._state_handles: np.ndarray | None = None
        self._state_action_masks: np.ndarray | None = None
        self._state_score = np.zeros((self.total_agents,), dtype=np.float32)
        self._state_episode_return = np.zeros((self.total_agents,), dtype=np.float32)
        self._state_prev_potential = np.zeros((self.total_agents,), dtype=np.float32)
        self._state_prev_task_progress = np.zeros((self.total_agents,), dtype=np.float32)
        self._state_statuses = np.zeros((self.num_envs,), dtype=np.int32)
        self._state_reward_shaping = state_reward_shaping_scale()
        self._state_progress_reward = state_progress_reward_scale()
        self._state_episode_steps = 0
        self._executor = None
        if self.spec.name == "among_them" and self.observation_mode == "pixels":
            self._executor = ThreadPoolExecutor(max_workers=native_worker_count(num_envs))

        self.workers: list[BitWorldWorker | AmongThemNativeWorker] = []
        if self.collect_state_target:
            self._state_target_buffer = np.zeros((self.total_agents, STATE_FEATURES), dtype=np.uint8)
        else:
            self._state_target_buffer = None
        self._pixel_shaping_episode_return = np.zeros((self.total_agents,), dtype=np.float32)
        self._mean_potential = 0.0
        self._mean_task_progress = 0.0
        self._mean_shaping_step = 0.0
        try:
            for env_id in range(num_envs):
                if self.spec.name == "among_them":
                    worker = AmongThemNativeWorker(
                        spec=self.spec,
                        env_id=env_id,
                        seed=base_seed + env_id,
                        max_episode_steps=max_episode_steps,
                        action_repeat=action_repeat,
                        observation_mode=observation_mode,
                        collect_state_target=self.collect_state_target,
                        imposter_count=imposter_count,
                        tasks_per_player=tasks_per_player,
                        task_complete_ticks=task_complete_ticks,
                        kill_cooldown_ticks=kill_cooldown_ticks,
                    )
                else:
                    worker = BitWorldWorker(
                        spec=self.spec,
                        env_id=env_id,
                        port=reserve_port(),
                        seed=base_seed + env_id,
                        action_repeat=action_repeat,
                    )
                self.workers.append(worker)
            if self.observation_mode == "state":
                self._state_handles = np.asarray(
                    [worker.handle for worker in self.workers if isinstance(worker, AmongThemNativeWorker)],
                    dtype=np.int32,
                )
                self._state_action_masks = np.zeros((self.total_agents,), dtype=np.uint8)
        except Exception:
            self.close()
            raise

    def _agent_slice(self, env_id: int) -> slice:
        start = env_id * self.agents_per_env
        return slice(start, start + self.agents_per_env)

    def _frame_batch(self, frame: np.ndarray, worker: BitWorldWorker | AmongThemNativeWorker) -> np.ndarray:
        frames = np.asarray(frame, dtype=self.obs_dtype)
        if worker.agent_count == 1:
            return frames.reshape(1, self.obs_features)
        return frames.reshape(worker.agent_count, self.obs_features)

    def _push_frames(self, agent_slice: slice, frames: np.ndarray) -> None:
        self._frame_history[agent_slice, :-1] = self._frame_history[agent_slice, 1:]
        self._frame_history[agent_slice, -1] = frames
        self._obs[agent_slice] = self._frame_history[agent_slice].reshape(frames.shape[0], -1)

    def _state_handles_ptr(self):
        assert self._state_handles is not None
        return self._state_handles.ctypes.data_as(ctypes.POINTER(ctypes.c_int))

    def _latest_state_ptr(self):
        return self._latest_frames.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8))

    def _state_rewards_ptr(self):
        return self._rewards.ctypes.data_as(ctypes.POINTER(ctypes.c_float))

    def _state_agent_rows(self, env_ids: np.ndarray) -> np.ndarray:
        return (env_ids[:, np.newaxis] * self.agents_per_env + np.arange(self.agents_per_env)).reshape(-1)

    def _reset_state_envs(self, env_ids: np.ndarray) -> None:
        assert self._state_handles is not None
        env_ids = np.asarray(env_ids, dtype=np.int32)
        if env_ids.size == 0:
            return

        rows = self._state_agent_rows(env_ids)
        native = among_them_native_library()
        handles = np.ascontiguousarray(self._state_handles[env_ids])
        latest_frames = np.zeros((rows.size, self.obs_features), dtype=self.obs_dtype)
        rewards = np.zeros((rows.size,), dtype=np.float32)
        native.check(
            native.lib.bitworld_at_reset_state_batch(
                handles.ctypes.data_as(ctypes.POINTER(ctypes.c_int)),
                env_ids.size,
                self.agents_per_env,
                latest_frames.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
                rewards.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
            )
        )
        self._latest_frames[rows] = latest_frames
        self._rewards[rows] = rewards
        self._state_score[rows] = 0.0
        self._state_episode_return[rows] = 0.0
        self._state_prev_potential[rows] = self._state_task_potential(self._latest_frames, rows)
        self._state_prev_task_progress[rows] = self._latest_frames[rows, STATE_TASK_PROGRESS_INDEX]
        self._state_statuses[env_ids] = AMONG_THEM_STEP_ACTIVE
        self._frame_history[rows] = self._latest_frames[rows, np.newaxis, :]
        self._obs[rows] = self._frame_history[rows].reshape(rows.size, -1)

    def _reset_state_batch(self) -> None:
        self._reset_state_envs(np.arange(self.num_envs, dtype=np.int32))
        self._state_episode_steps = 0

    def _state_task_features(self, frames: np.ndarray, rows: np.ndarray | None = None) -> np.ndarray:
        selected = frames if rows is None else frames[rows]
        return selected[:, STATE_TASK_FEATURE_OFFSET:STATE_FEATURES].reshape(
            selected.shape[0],
            STATE_TASK_COUNT,
            STATE_TASK_FEATURES,
        )

    def _state_task_potential(self, frames: np.ndarray, rows: np.ndarray | None = None) -> np.ndarray:
        task_features = self._state_task_features(frames, rows)
        flags = task_features[:, :, 3].astype(np.uint8)
        assigned = (flags & STATE_FLAG_TASK_ASSIGNED) != 0
        completed = (flags & STATE_FLAG_TASK_COMPLETED) != 0
        candidates = assigned & ~completed
        icon_visible = (flags & STATE_FLAG_TASK_ICON_VISIBLE) != 0
        arrow_visible = (flags & STATE_FLAG_TASK_ARROW_VISIBLE) != 0
        visible = icon_visible | arrow_visible
        target_x = np.where(icon_visible, task_features[:, :, 1], np.where(arrow_visible, task_features[:, :, 5], 0))
        target_y = np.where(icon_visible, task_features[:, :, 2], np.where(arrow_visible, task_features[:, :, 6], 0))
        distances = np.sqrt(np.square(target_x.astype(np.float32) - 64.0) + np.square(target_y.astype(np.float32) - 64.0))
        # When the task isn't visible on screen, use max distance so that
        # discovering a task is always rewarding (not punishing).
        distances = np.where(candidates & visible, distances, np.where(candidates, 128.0, np.inf))
        nearest = np.min(distances, axis=1)
        return np.where(np.isfinite(nearest), -nearest / 128.0, 0.0).astype(np.float32)

    def _state_completed_task_counts(self, frames: np.ndarray, rows: np.ndarray | None = None) -> np.ndarray:
        task_features = self._state_task_features(frames, rows)
        flags = task_features[:, :, 3].astype(np.uint8)
        assigned = (flags & STATE_FLAG_TASK_ASSIGNED) != 0
        completed = (flags & STATE_FLAG_TASK_COMPLETED) != 0
        return np.sum(assigned & completed, axis=1).astype(np.float32)

    def _step_env(self, env_id: int, action_indices: np.ndarray):
        worker = self.workers[env_id]
        agent_slice = self._agent_slice(env_id)
        clipped = np.clip(action_indices[agent_slice], 0, self.action_count - 1).astype(np.int64)
        action_masks = ACTION_MASKS[clipped]
        if isinstance(worker, AmongThemNativeWorker):
            frames, rewards = worker.step(action_masks)
            frames = self._frame_batch(frames, worker)
        else:
            frame, reward = worker.step(int(action_masks[0]))
            frames = self._frame_batch(frame, worker)
            rewards = np.asarray([reward], dtype=np.float32)

        completed: list[EpisodeStats] = []
        if isinstance(worker, AmongThemNativeWorker):
            done = worker.done
            truncated = worker.truncated
        else:
            done = worker.episode_steps >= self.max_episode_steps
            truncated = done
        if done:
            scores = (np.asarray(worker.score) - np.asarray(worker.base_score)).reshape(-1)
            returns = np.asarray(worker.episode_return).reshape(-1)
            completed = [
                EpisodeStats(
                    score=float(score),
                    length=worker.episode_steps,
                    episode_return=float(episode_return),
                )
                for score, episode_return in zip(scores, returns)
            ]
            frames = self._frame_batch(worker.reset(), worker)
        state_targets = None
        if self.collect_state_target and isinstance(worker, AmongThemNativeWorker) and worker.state_targets is not None:
            state_targets = worker.state_targets.copy()
        return env_id, frames, rewards, completed, truncated, state_targets

    def reset(self):
        self._rewards.fill(0.0)
        self._terminals.fill(0.0)
        if self.observation_mode == "state":
            self._reset_state_batch()
            return self._obs
        for env_id, worker in enumerate(self.workers):
            agent_slice = self._agent_slice(env_id)
            frames = self._frame_batch(worker.reset(), worker)
            self._frame_history[agent_slice] = frames[:, np.newaxis, :]
            self._obs[agent_slice] = self._frame_history[agent_slice].reshape(worker.agent_count, -1)
            if (
                self._state_target_buffer is not None
                and isinstance(worker, AmongThemNativeWorker)
                and worker.state_targets is not None
            ):
                self._state_target_buffer[agent_slice] = worker.state_targets
        if self.enable_state_shaping and self._state_target_buffer is not None:
            self._state_prev_potential[:] = self._state_task_potential(self._state_target_buffer)
            self._state_prev_task_progress[:] = self._state_target_buffer[:, STATE_TASK_PROGRESS_INDEX]
            self._pixel_shaping_episode_return.fill(0.0)
            self._mean_potential = float(self._state_prev_potential.mean())
            self._mean_task_progress = float(self._state_prev_task_progress.mean())
            self._mean_shaping_step = 0.0
        return self._obs

    def _apply_state_actions(self, action_indices: np.ndarray) -> list[EpisodeStats]:
        assert self._state_action_masks is not None
        clipped = np.clip(action_indices, 0, self.action_count - 1).astype(np.int64)
        self._state_action_masks[:] = ACTION_MASKS[clipped]
        self._rewards.fill(0.0)
        self._terminals.fill(0.0)
        self._truncations.fill(0.0)

        native = among_them_native_library()
        native.check(
            native.lib.bitworld_at_step_state_batch(
                self._state_handles_ptr(),
                self.num_envs,
                self.agents_per_env,
                self._state_action_masks.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
                self.action_repeat,
                self._state_statuses.ctypes.data_as(ctypes.POINTER(ctypes.c_int)),
                self._latest_state_ptr(),
                self._state_rewards_ptr(),
            )
        )
        self._state_score += self._rewards
        current_potential = self._state_task_potential(self._latest_frames)
        task_progress = self._latest_frames[:, STATE_TASK_PROGRESS_INDEX]
        self._rewards += self._state_reward_shaping * (current_potential - self._state_prev_potential)
        self._rewards += self._state_progress_reward * np.maximum(0.0, task_progress - self._state_prev_task_progress)
        self._state_prev_potential[:] = current_potential
        self._state_prev_task_progress[:] = task_progress
        self._state_episode_return += self._rewards
        self._state_episode_steps += 1

        completed: list[EpisodeStats] = []
        done = self._state_statuses != AMONG_THEM_STEP_ACTIVE
        if np.any(done):
            done_env_ids = np.flatnonzero(done).astype(np.int32)
            done_rows = self._state_agent_rows(done_env_ids)
            terminal_rewards = self._rewards[done_rows].copy()
            task_counts = self._state_completed_task_counts(self._latest_frames, done_rows)
            for score, episode_return, tasks_completed in zip(
                self._state_score[done_rows],
                self._state_episode_return[done_rows],
                task_counts,
            ):
                stats = EpisodeStats(
                    score=float(score),
                    length=self._state_episode_steps,
                    episode_return=float(episode_return),
                    tasks_completed=float(tasks_completed),
                )
                completed.append(stats)
                self._completed_scores.append(stats.score)
                self._completed_lengths.append(float(stats.length))
                self._completed_returns.append(stats.episode_return)
                self._completed_tasks.append(stats.tasks_completed)
            self._completed_episodes += done_env_ids.size
            env_truncations = self._state_statuses[done_env_ids] == AMONG_THEM_STEP_TRUNCATED
            self._reset_state_envs(done_env_ids)
            self._rewards[done_rows] = terminal_rewards
            self._terminals[done_rows] = 1.0
            self._truncations[done_rows] = np.repeat(env_truncations.astype(np.float32), self.agents_per_env)

        self._frame_history[:, :-1] = self._frame_history[:, 1:]
        self._frame_history[:, -1] = self._latest_frames
        self._obs[:] = self._frame_history.reshape(self.total_agents, -1)
        return completed

    def _apply_actions(self, action_indices: np.ndarray) -> list[EpisodeStats]:
        if self.observation_mode == "state":
            return self._apply_state_actions(action_indices)

        self._rewards.fill(0.0)
        self._terminals.fill(0.0)
        self._truncations.fill(0.0)
        completed: list[EpisodeStats] = []
        env_ids = range(len(self.workers))
        if self._executor is None:
            step_results = [self._step_env(env_id, action_indices) for env_id in env_ids]
        else:
            step_results = list(self._executor.map(self._step_env, env_ids, repeat(action_indices)))

        terminated_agents = np.zeros((self.total_agents,), dtype=bool)
        per_env_completed: list[tuple[slice, list[EpisodeStats]]] = []
        for env_id, frames, rewards, env_completed, truncated, state_targets in step_results:
            agent_slice = self._agent_slice(env_id)
            if env_completed:
                self._terminals[agent_slice] = 1.0
                terminated_agents[agent_slice] = True
                if truncated:
                    self._truncations[agent_slice] = 1.0
                per_env_completed.append((agent_slice, env_completed))

            self._rewards[agent_slice] = rewards
            self._push_frames(agent_slice, frames)
            if self._state_target_buffer is not None and state_targets is not None:
                self._state_target_buffer[agent_slice] = state_targets

        if self.enable_state_shaping and self._state_target_buffer is not None:
            current_potential = self._state_task_potential(self._state_target_buffer)
            current_progress = self._state_target_buffer[:, STATE_TASK_PROGRESS_INDEX].astype(np.float32)
            potential_delta = current_potential - self._state_prev_potential
            progress_delta = np.maximum(0.0, current_progress - self._state_prev_task_progress)
            potential_delta[terminated_agents] = 0.0
            progress_delta[terminated_agents] = 0.0
            shaping = self._state_reward_shaping * potential_delta + self._state_progress_reward * progress_delta
            self._rewards += shaping
            self._pixel_shaping_episode_return += shaping
            self._mean_potential = float(current_potential.mean())
            self._mean_task_progress = float(current_progress.mean())
            self._mean_shaping_step = float(shaping.mean())
            self._state_prev_potential[:] = current_potential
            self._state_prev_task_progress[:] = current_progress

        for agent_slice, env_completed in per_env_completed:
            for offset, stats in enumerate(env_completed):
                agent_idx = agent_slice.start + offset
                stats.shaping_return = float(self._pixel_shaping_episode_return[agent_idx])
                completed.append(stats)
                self._completed_scores.append(float(stats.score))
                self._completed_lengths.append(float(stats.length))
                self._completed_returns.append(float(stats.episode_return))
                self._completed_shaping_returns.append(stats.shaping_return)
            self._completed_episodes += 1
            self._pixel_shaping_episode_return[agent_slice] = 0.0
        return completed

    def step_discrete(self, action_indices: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, list[EpisodeStats]]:
        completed = self._apply_actions(action_indices)
        return self._obs, self._rewards, self._terminals, completed

    @property
    def state_targets(self) -> np.ndarray | None:
        return self._state_target_buffer

    def async_reset(self, seed: int | None = None) -> None:
        del seed
        self.reset()
        self.infos = []

    def recv(self):
        return (
            self._obs,
            self._rewards,
            self._terminals,
            self._truncations,
            self.infos,
            self.agent_ids,
            self.masks,
        )

    def send(self, actions: np.ndarray) -> None:
        _, _, _, completed = self.step_discrete(np.asarray(actions, dtype=np.int64).reshape(-1))
        self.infos = [item.info(self.spec.metric_name) for item in completed]

    def cpu_step(self, actions_ptr: int) -> None:
        raw = (ctypes.c_float * (self.total_agents * self.num_atns)).from_address(actions_ptr)
        action_indices = np.ctypeslib.as_array(raw).reshape(self.total_agents, self.num_atns)[:, 0].astype(np.int64)
        self._apply_actions(action_indices)

    def log(self) -> dict:
        score = float(np.mean(self._completed_scores)) if self._completed_scores else 0.0
        episode_length = float(np.mean(self._completed_lengths)) if self._completed_lengths else 0.0
        episode_return = float(np.mean(self._completed_returns)) if self._completed_returns else 0.0
        tasks_completed = float(np.mean(self._completed_tasks)) if self._completed_tasks else 0.0
        shaping_return = float(np.mean(self._completed_shaping_returns)) if self._completed_shaping_returns else 0.0
        game = {
            "score": score,
            "tasks_completed": tasks_completed,
            "mean_potential": self._mean_potential,
            "mean_task_progress": self._mean_task_progress,
            "mean_shaping_step": self._mean_shaping_step,
        }
        if self.spec.metric_name != "score":
            game[self.spec.metric_name] = score
        return {
            "game": game,
            "episode": {
                "length": episode_length,
                "return": episode_return,
                "shaping_return": shaping_return,
                "count": float(self._completed_episodes),
            },
        }

    def render(self, env_id: int = 0) -> None:
        del env_id

    def close(self) -> None:
        for worker in self.workers:
            worker.close()
        if self._executor is not None:
            self._executor.shutdown()


class BitWorldPolicy(nn.Module):
    def __init__(
        self,
        frame_stack: int,
        action_count: int,
        hidden_size: int = 256,
        observation_mode: str = "pixels",
        obs_shape: tuple[int, ...] | None = None,
        state_aux: bool = False,
    ) -> None:
        super().__init__()
        if observation_mode not in OBSERVATION_MODES:
            raise ValueError(f"unknown observation_mode {observation_mode!r}")
        self.frame_stack = frame_stack
        self.observation_mode = observation_mode
        self.obs_shape = obs_shape or (
            (frame_stack, SCREEN_HEIGHT, SCREEN_WIDTH) if observation_mode == "pixels" else (STATE_FEATURES * frame_stack,)
        )
        if observation_mode == "pixels":
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
                sample = torch.zeros(1, *self.obs_shape)
                encoded_size = int(self.encoder(sample).shape[1])
        else:
            self.encoder = nn.Flatten()
            encoded_size = int(np.prod(self.obs_shape))

        self.body = nn.Sequential(
            nn.Linear(encoded_size, hidden_size),
            nn.ReLU(),
        )
        self.policy_head = nn.Linear(hidden_size, action_count)
        self.value_head = nn.Linear(hidden_size, 1)
        self.state_aux = state_aux and observation_mode == "pixels"
        if self.state_aux:
            self.state_pred_head = nn.Linear(hidden_size, STATE_FEATURES)
        else:
            self.state_pred_head = None
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
        if self.state_pred_head is not None:
            nn.init.orthogonal_(self.state_pred_head.weight, gain=1.0)
            nn.init.zeros_(self.state_pred_head.bias)

    def initial_state(self, batch_size: int, device: str = "cpu"):
        del batch_size, device
        return ()

    def _features(self, observations: torch.Tensor) -> torch.Tensor:
        x = observations.float()
        if self.observation_mode == "pixels":
            x = x.div(15.0)
        else:
            x = x.div(255.0)
        policy_input = x.reshape(-1, *self.obs_shape)
        x = self.encoder(policy_input)
        return self.body(x)

    def forward_eval(self, observations: torch.Tensor, state=()):
        del state
        features = self._features(observations)
        logits = self.policy_head(features)
        values = self.value_head(features)
        return logits, values

    def forward(self, observations: torch.Tensor, state=()):
        del state
        features = self._features(observations)
        logits = self.policy_head(features)
        values = self.value_head(features)
        if self.state_pred_head is None:
            return logits, values
        state_pred = self.state_pred_head(features)
        return logits, values, state_pred


def make_train_args(
    spec: str | EnvironmentSpec,
    total_timesteps: int,
    learning_rate: float,
    total_agents: int,
    horizon: int,
    minibatch_size: int,
    seed: int,
    checkpoint_dir: Path,
    log_dir: Path,
) -> dict:
    resolved = get_env_spec(spec)
    return {
        "env_name": f"bitworld_{resolved.name}",
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
            "total_agents": total_agents,
            "num_buffers": 1,
            "num_threads": 1,
        },
    }


def puffer_train_config(args: dict) -> dict:
    train = args["train"]
    horizon = train["horizon"]
    total_agents = args["vec"]["total_agents"]
    batch_size = total_agents * horizon
    total_timesteps = max(train["total_timesteps"], batch_size)
    return {
        "env": args["env_name"],
        "torch_deterministic": False,
        "seed": train["seed"],
        "batch_size": batch_size,
        "bptt_horizon": horizon,
        "device": train["device"],
        "cpu_offload": False,
        "minibatch_size": min(train["minibatch_size"], batch_size),
        "max_minibatch_size": min(train["minibatch_size"], batch_size),
        "update_epochs": 1,
        "compile": False,
        "compile_mode": "default",
        "compile_fullgraph": False,
        "optimizer": "adam",
        "learning_rate": train["learning_rate"],
        "adam_beta1": train["beta1"],
        "adam_beta2": train["beta2"],
        "adam_eps": train["eps"],
        "total_timesteps": total_timesteps,
        "precision": "float32",
        "use_rnn": False,
        "prio_beta0": train["prio_beta0"],
        "prio_alpha": train["prio_alpha"],
        "clip_coef": train["clip_coef"],
        "vf_clip_coef": train["vf_clip_coef"],
        "gamma": train["gamma"],
        "gae_lambda": train["gae_lambda"],
        "vtrace_rho_clip": train["vtrace_rho_clip"],
        "vtrace_c_clip": train["vtrace_c_clip"],
        "vf_coef": train["vf_coef"],
        "ent_coef": train["ent_coef"],
        "max_grad_norm": train["max_grad_norm"],
        "anneal_lr": bool(train["anneal_lr"]),
        "checkpoint_interval": args["checkpoint_interval"],
        "data_dir": args["checkpoint_dir"],
    }


def train_policy(
    spec: str | EnvironmentSpec,
    num_envs: int,
    total_timesteps: int,
    max_episode_steps: int,
    frame_stack: int,
    learning_rate: float,
    horizon: int,
    minibatch_size: int,
    seed: int,
    checkpoint_path: Path,
    metrics_path: Path,
    action_repeat: int = DEFAULT_ACTION_REPEAT,
    hidden_size: int = 256,
    device: str = "auto",
    observation_mode: str = "pixels",
    state_aux_coef: float = 0.0,
    enable_state_shaping: bool = False,
    imposter_count: int = -1,
    tasks_per_player: int = -1,
    task_complete_ticks: int = -1,
    kill_cooldown_ticks: int = -1,
    init_checkpoint_path: Path | None = None,
) -> dict:
    resolved = get_env_spec(spec)
    if observation_mode not in OBSERVATION_MODES:
        raise ValueError(f"unknown observation_mode {observation_mode!r}")
    if state_aux_coef < 0.0:
        raise ValueError("state_aux_coef must be non-negative")
    state_aux_active = state_aux_coef > 0.0
    if state_aux_active and observation_mode != "pixels":
        raise ValueError("state_aux_coef > 0 requires --observation-mode pixels")
    if state_aux_active and resolved.name != "among_them":
        raise ValueError("state_aux_coef is only supported for among_them")
    if enable_state_shaping and observation_mode != "pixels":
        raise ValueError("--shaping-rewards requires --observation-mode pixels")
    if enable_state_shaping and resolved.name != "among_them":
        raise ValueError("--shaping-rewards is only supported for among_them")
    train_device = resolve_train_device(device)
    rank = int(os.environ.get("RANK", "0"))
    world_size = int(os.environ.get("WORLD_SIZE", "1"))
    local_rank = int(os.environ.get("LOCAL_RANK", "0"))
    distributed = world_size > 1
    if distributed:
        if train_device != "cuda":
            raise RuntimeError("torchrun DDP requires --device cuda")
        torch.cuda.set_device(local_rank)
        train_device = f"cuda:{local_rank}"
        torch.distributed.init_process_group(backend="nccl", world_size=world_size, rank=rank)
    PuffeRL = load_puffer_trainer(use_gpu=torch.device(train_device).type == "cuda")
    checkpoint_path = checkpoint_path.resolve()
    metrics_path = metrics_path.resolve()
    checkpoint_dir = checkpoint_path.parent / "checkpoints"
    log_dir = checkpoint_path.parent / "logs"
    if rank == 0:
        checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
        checkpoint_dir.mkdir(parents=True, exist_ok=True)
        log_dir.mkdir(parents=True, exist_ok=True)

    vecenv = BitWorldVecEnv(
        spec=resolved,
        num_envs=num_envs,
        max_episode_steps=max_episode_steps,
        frame_stack=frame_stack,
        action_repeat=action_repeat,
        base_seed=seed + rank * num_envs,
        observation_mode=observation_mode,
        collect_state_target=state_aux_active or enable_state_shaping,
        enable_state_shaping=enable_state_shaping,
        imposter_count=imposter_count,
        tasks_per_player=tasks_per_player,
        task_complete_ticks=task_complete_ticks,
        kill_cooldown_ticks=kill_cooldown_ticks,
    )
    policy = BitWorldPolicy(
        frame_stack=frame_stack,
        action_count=vecenv.action_count,
        hidden_size=hidden_size,
        observation_mode=observation_mode,
        obs_shape=vecenv.single_observation_space.shape if observation_mode == "state" else None,
        state_aux=state_aux_active,
    ).to(train_device)
    if init_checkpoint_path is not None:
        if not init_checkpoint_path.exists():
            raise FileNotFoundError(f"init checkpoint not found: {init_checkpoint_path}")
        loaded = torch.load(init_checkpoint_path, map_location=train_device)
        if isinstance(loaded, dict):
            policy.load_state_dict(loaded, strict=False)
        else:
            raise TypeError(f"unsupported init checkpoint format: {init_checkpoint_path}")
    if distributed:
        policy = torch.nn.parallel.DistributedDataParallel(
            policy,
            device_ids=[local_rank],
            output_device=local_rank,
        )
        policy.forward_eval = policy.module.forward_eval
        policy.initial_state = policy.module.initial_state
    args = make_train_args(
        spec=resolved,
        total_timesteps=total_timesteps,
        learning_rate=learning_rate,
        total_agents=vecenv.total_agents,
        horizon=horizon,
        minibatch_size=minibatch_size,
        seed=seed,
        checkpoint_dir=checkpoint_dir,
        log_dir=log_dir,
    )
    args["train"]["device"] = train_device
    args["rank"] = rank
    args["world_size"] = world_size
    args["gpu_id"] = local_rank
    args["train"]["gpus"] = world_size
    trainer = PuffeRL(args, vecenv, policy, verbose=False, state_aux_coef=state_aux_coef)
    if rank == 0:
        print(
            json.dumps(
                {
                    "env": resolved.name,
                    "device": train_device,
                    "cuda_available": bool(torch.cuda.is_available()),
                    "mps_available": bool(hasattr(torch.backends, "mps") and torch.backends.mps.is_available()),
                    "policy_device": str(next(policy.parameters()).device),
                    "world_size": world_size,
                    "observation_mode": observation_mode,
                }
            ),
            flush=True,
        )

    history: list[dict[str, float]] = []
    try:
        while trainer.global_step * world_size < total_timesteps:
            trainer.rollouts()
            trainer.train()
            logs = trainer.log()
            flat_logs = flatten_logs(logs)
            if rank == 0:
                history.append(flat_logs)
                print(
                    json.dumps(
                        {
                            "env": resolved.name,
                            "steps": int(flat_logs["agent_steps"]),
                            "sps": round(float(flat_logs["SPS"]), 2),
                            "score": round(float(flat_logs.get("env_game/score", 0.0)), 3),
                            "episode_length": round(float(flat_logs.get("env_episode/length", 0.0)), 1),
                            "episode_return": round(float(flat_logs.get("env_episode/return", 0.0)), 3),
                            "shaping_return": round(float(flat_logs.get("env_episode/shaping_return", 0.0)), 3),
                            "mean_potential": round(float(flat_logs.get("env_game/mean_potential", 0.0)), 3),
                            "mean_task_progress": round(float(flat_logs.get("env_game/mean_task_progress", 0.0)), 3),
                            "mean_shaping_step": round(float(flat_logs.get("env_game/mean_shaping_step", 0.0)), 4),
                        }
                    ),
                    flush=True,
                )
    finally:
        try:
            if rank == 0:
                trainer.save_weights(str(checkpoint_path))
        finally:
            trainer.close()
            if distributed:
                torch.distributed.destroy_process_group()

    if rank != 0:
        return {
            "env": resolved.name,
            "device": train_device,
            "history": history,
        }

    metrics_path.parent.mkdir(parents=True, exist_ok=True)
    summary = {
        "env": resolved.name,
        "device": train_device,
        "observation_mode": observation_mode,
        "history": history,
    }
    metrics_path.write_text(json.dumps(summary, indent=2))
    return summary


def evaluate_policy(
    spec: str | EnvironmentSpec,
    policy: BitWorldPolicy | None,
    episodes: int,
    max_episode_steps: int,
    frame_stack: int,
    seed: int,
    action_repeat: int = DEFAULT_ACTION_REPEAT,
    observation_mode: str = "pixels",
    random_actions: bool = False,
    sample_actions: bool = True,
) -> dict[str, float]:
    resolved = get_env_spec(spec)
    vecenv = BitWorldVecEnv(
        spec=resolved,
        num_envs=1,
        max_episode_steps=max_episode_steps,
        frame_stack=frame_stack,
        action_repeat=action_repeat,
        base_seed=seed,
        observation_mode=observation_mode,
    )
    rng = np.random.default_rng(seed)
    vecenv.reset()
    completed_scores: list[float] = []
    completed_returns: list[float] = []
    completed_tasks: list[float] = []
    policy_device = next(policy.parameters()).device if policy is not None else torch.device("cpu")

    try:
        while len(completed_scores) < episodes:
            if random_actions:
                action_indices = rng.integers(0, vecenv.action_count, size=(vecenv.total_agents,), dtype=np.int64)
            else:
                if policy is None:
                    raise ValueError("policy must be provided when random_actions is False")
                with torch.no_grad():
                    observations = torch.as_tensor(vecenv._obs, device=policy_device)
                    logits, _ = policy.forward_eval(observations)
                    if sample_actions:
                        probs = torch.softmax(logits, dim=-1)
                        action_indices = torch.multinomial(probs, 1).squeeze(-1).cpu().numpy()
                    else:
                        action_indices = torch.argmax(logits, dim=-1).cpu().numpy()
            _, _, _, completed = vecenv.step_discrete(action_indices)
            for item in completed:
                completed_scores.append(item.score)
                completed_returns.append(item.episode_return)
                completed_tasks.append(item.tasks_completed)
    finally:
        vecenv.close()

    summary = {
        "episodes": float(episodes),
        "mean_score": float(np.mean(completed_scores)),
        "mean_return": float(np.mean(completed_returns)),
        "mean_tasks_completed": float(np.mean(completed_tasks)),
        "max_score": float(np.max(completed_scores)),
        "max_tasks_completed": float(np.max(completed_tasks)),
    }
    if resolved.metric_name != "score":
        summary[f"mean_{resolved.metric_name}"] = summary["mean_score"]
        summary[f"max_{resolved.metric_name}"] = summary["max_score"]
    return summary

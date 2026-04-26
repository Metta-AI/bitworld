from __future__ import annotations

import ctypes
import json
import socket
import subprocess
import sys
import threading
import time
import types
from collections import deque
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
from torch import nn
from websockets.sync.client import ClientConnection, connect

REPO_ROOT = Path(__file__).resolve().parents[2]
RUNLOG_DIR = REPO_ROOT / "tools" / "runlogs" / "pufferlib"

SCREEN_WIDTH = 128
SCREEN_HEIGHT = 128
FRAME_PIXELS = SCREEN_WIDTH * SCREEN_HEIGHT
PACKED_FRAME_BYTES = FRAME_PIXELS // 2
RESET_INPUT_MASK = 255
DEFAULT_ACTION_REPEAT = 4

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

SHARED_NIM_SOURCES = (
    REPO_ROOT / "common" / "protocol.nim",
    REPO_ROOT / "common" / "server.nim",
)


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


def ensure_bitworld_binary(spec: str | EnvironmentSpec) -> None:
    resolved = get_env_spec(spec)
    if binary_is_fresh(resolved):
        return

    subprocess.run(
        ["nim", "c", *nim_path_args(), f"{resolved.name}/{resolved.name}.nim"],
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
    _, horizon = values.shape
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


@dataclass
class EpisodeStats:
    score: float
    length: int
    episode_return: float


class BitWorldWorker:
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
    ) -> None:
        if num_envs <= 0:
            raise ValueError("num_envs must be positive")
        if frame_stack <= 0:
            raise ValueError("frame_stack must be positive")
        if action_repeat <= 0:
            raise ValueError("action_repeat must be positive")

        self.spec = get_env_spec(spec)
        self.num_envs = num_envs
        self.total_agents = num_envs
        self.max_episode_steps = max_episode_steps
        self.frame_stack = frame_stack
        self.action_repeat = action_repeat
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

        self.workers: list[BitWorldWorker] = []
        try:
            for env_id in range(num_envs):
                worker = BitWorldWorker(
                    spec=self.spec,
                    env_id=env_id,
                    port=reserve_port(),
                    seed=base_seed + env_id,
                    action_repeat=action_repeat,
                )
                self.workers.append(worker)
        except Exception:
            self.close()
            raise

    def _push_frame(self, env_id: int, frame: np.ndarray) -> None:
        self._frame_history[env_id, :-1] = self._frame_history[env_id, 1:]
        self._frame_history[env_id, -1] = frame
        self._obs[env_id] = self._frame_history[env_id].reshape(-1)

    def reset(self):
        self._rewards.fill(0.0)
        self._terminals.fill(0.0)
        for env_id, worker in enumerate(self.workers):
            self._frame_history[env_id] = worker.reset()
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
                        score=float(worker.score - worker.base_score),
                        length=worker.episode_steps,
                        episode_return=worker.episode_return,
                    )
                )
                self._completed_scores.append(float(worker.score - worker.base_score))
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
        logs = {
            "score": score,
            "episode_length": episode_length,
            "episode_return": episode_return,
            "n": float(self._completed_episodes),
        }
        if self.spec.metric_name != "score":
            logs[self.spec.metric_name] = score
        return logs

    def render(self, env_id: int = 0) -> None:
        del env_id

    def close(self) -> None:
        for worker in self.workers:
            worker.close()


class BitWorldPolicy(nn.Module):
    def __init__(self, frame_stack: int, action_count: int, hidden_size: int = 256) -> None:
        super().__init__()
        self.frame_stack = frame_stack
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
    spec: str | EnvironmentSpec,
    total_timesteps: int,
    learning_rate: float,
    num_envs: int,
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
            "total_agents": num_envs,
            "num_buffers": 1,
            "num_threads": 1,
        },
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
    model_path: Path,
    metrics_path: Path,
    action_repeat: int = DEFAULT_ACTION_REPEAT,
    hidden_size: int = 256,
) -> dict:
    resolved = get_env_spec(spec)
    PuffeRL = load_puffer_trainer()
    checkpoint_dir = model_path.parent / "checkpoints"
    log_dir = model_path.parent / "logs"
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    vecenv = BitWorldVecEnv(
        spec=resolved,
        num_envs=num_envs,
        max_episode_steps=max_episode_steps,
        frame_stack=frame_stack,
        action_repeat=action_repeat,
        base_seed=seed,
    )
    policy = BitWorldPolicy(frame_stack=frame_stack, action_count=vecenv.action_count, hidden_size=hidden_size)
    args = make_train_args(
        spec=resolved,
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
                        "env": resolved.name,
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
        "env": resolved.name,
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
                if policy is None:
                    raise ValueError("policy must be provided when random_actions is False")
                with torch.no_grad():
                    logits, _, _ = policy.forward_eval(torch.from_numpy(vecenv._obs))
                    if sample_actions:
                        probs = torch.softmax(logits, dim=-1)
                        action_indices = torch.multinomial(probs, 1).squeeze(-1).cpu().numpy()
                    else:
                        action_indices = torch.argmax(logits, dim=-1).cpu().numpy()
            _, _, _, completed = vecenv.step_discrete(action_indices)
            for item in completed:
                completed_scores.append(item.score)
                completed_returns.append(item.episode_return)
    finally:
        vecenv.close()

    summary = {
        "episodes": float(episodes),
        "mean_score": float(np.mean(completed_scores)),
        "mean_return": float(np.mean(completed_returns)),
        "max_score": float(np.max(completed_scores)),
    }
    if resolved.metric_name != "score":
        summary[f"mean_{resolved.metric_name}"] = summary["mean_score"]
        summary[f"max_{resolved.metric_name}"] = summary["max_score"]
    return summary

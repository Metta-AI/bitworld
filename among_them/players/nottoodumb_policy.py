"""ctypes bridge for the Nim NotTooDumb BitWorld policy."""

from __future__ import annotations

import ctypes
import platform
from pathlib import Path

import numpy as np

from mettagrid.bitworld import BITWORLD_ACTION_COUNT, BITWORLD_ACTION_NAMES, SCREEN_HEIGHT, SCREEN_WIDTH
from mettagrid.policy.policy import AgentPolicy, MultiAgentPolicy
from mettagrid.policy.policy_env_interface import PolicyEnvInterface
from mettagrid.simulator import Action, AgentObservation

from among_them.players.build_nottoodumb import NOTTOODUMB_ABI_VERSION, build_nottoodumb


class _NotTooDumbNimAgentPolicy(AgentPolicy):
    """Single-agent fallback wrapper around the batched Nim policy."""

    def __init__(
        self,
        policy_env_info: PolicyEnvInterface,
        parent: "NotTooDumbNimPolicy",
        agent_id: int,
    ):
        super().__init__(policy_env_info)
        self._parent = parent
        self._agent_id = agent_id

    def step(self, obs: AgentObservation) -> Action:
        del obs
        action_index = self._parent.step_agent(self._agent_id)
        return Action(name=self._policy_env_info.action_names[action_index])


class NotTooDumbNimPolicy(MultiAgentPolicy):
    """Runs ``nottoodumb.nim`` through a compiled shared library."""

    short_names = ["nottoodumb_nim"]

    def __init__(self, policy_env_info: PolicyEnvInterface, device: str = "cpu"):
        super().__init__(policy_env_info, device=device)
        if tuple(policy_env_info.action_names) != BITWORLD_ACTION_NAMES:
            raise ValueError(
                "NotTooDumbNimPolicy requires the "
                f"{BITWORLD_ACTION_COUNT}-action BitWorld action space."
            )
        self._lib = self._load_library()
        self._lib.nottoodumb_new_policy.argtypes = [ctypes.c_int]
        self._lib.nottoodumb_new_policy.restype = ctypes.c_int
        self._lib.nottoodumb_step_batch.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_int32),
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        self._lib.nottoodumb_step_batch.restype = None
        self._num_agents = max(1, int(policy_env_info.num_agents))
        self._handle = int(self._lib.nottoodumb_new_policy(self._num_agents))
        self._last_actions = np.zeros(self._num_agents, dtype=np.int32)

    def agent_policy(self, agent_id: int) -> AgentPolicy:
        return _NotTooDumbNimAgentPolicy(self._policy_env_info, self, agent_id)

    def step_batch(self, raw_observations: np.ndarray, raw_actions: np.ndarray) -> None:
        observations = self._normalize_observations(raw_observations)
        batch_size = observations.shape[0]
        self._ensure_agent_count(batch_size)
        agent_ids = np.arange(batch_size, dtype=np.int32)
        frame_advances = np.ones(batch_size, dtype=np.int32)
        actions = np.zeros(batch_size, dtype=np.int32)
        self._lib.nottoodumb_step_batch(
            self._handle,
            agent_ids.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),
            ctypes.c_int(batch_size),
            ctypes.c_int(max(self._num_agents, batch_size)),
            ctypes.c_int(observations.shape[1]),
            ctypes.c_int(observations.shape[2]),
            ctypes.c_int(observations.shape[3]),
            ctypes.c_void_p(frame_advances.ctypes.data),
            ctypes.c_void_p(observations.ctypes.data),
            ctypes.c_void_p(actions.ctypes.data),
        )
        self._last_actions[:batch_size] = actions
        raw_actions[:batch_size] = actions.astype(raw_actions.dtype, copy=False)

    def step_agent(self, agent_id: int) -> int:
        if 0 <= agent_id < self._last_actions.shape[0]:
            return int(self._last_actions[agent_id])
        return 0

    def _ensure_agent_count(self, count: int) -> None:
        if count <= self._num_agents:
            return
        old_actions = self._last_actions
        self._num_agents = count
        self._last_actions = np.zeros(count, dtype=np.int32)
        self._last_actions[: old_actions.shape[0]] = old_actions

    def _normalize_observations(self, observations: np.ndarray) -> np.ndarray:
        if observations.ndim == 4:
            normalized = observations
        elif observations.ndim == 3:
            normalized = observations[:, np.newaxis, :, :]
        elif observations.ndim == 2:
            normalized = self._unpack_frames(observations)[:, np.newaxis, :, :]
        else:
            raise ValueError(
                "Expected BitWorld observations with 2, 3, or 4 dimensions, "
                f"got {observations.ndim}."
            )
        if normalized.shape[2:] != (SCREEN_HEIGHT, SCREEN_WIDTH):
            raise ValueError(f"Expected {SCREEN_HEIGHT}x{SCREEN_WIDTH} BitWorld frames.")
        return np.ascontiguousarray(normalized, dtype=np.uint8)

    def _unpack_frames(self, observations: np.ndarray) -> np.ndarray:
        packed = np.ascontiguousarray(observations, dtype=np.uint8)
        pixels = np.empty((packed.shape[0], packed.shape[1] * 2), dtype=np.uint8)
        pixels[:, 0::2] = packed & 0x0F
        pixels[:, 1::2] = packed >> 4
        return pixels.reshape(packed.shape[0], SCREEN_HEIGHT, SCREEN_WIDTH)

    def _load_library(self) -> ctypes.CDLL:
        lib_path = Path(__file__).resolve().parent / _library_name()
        if _library_needs_rebuild(lib_path):
            lib_path = build_nottoodumb()
        lib = ctypes.CDLL(str(lib_path))
        _verify_library_abi(lib, lib_path)
        return lib


def _library_name() -> str:
    system = platform.system()
    if system == "Darwin":
        return "libnottoodumb.dylib"
    if system == "Windows":
        return "nottoodumb.dll"
    return "libnottoodumb.so"


def _library_needs_rebuild(lib_path: Path) -> bool:
    if not lib_path.exists():
        return True
    try:
        return int(_abi_stamp_path(lib_path).read_text().strip()) != NOTTOODUMB_ABI_VERSION
    except (OSError, ValueError):
        return True


def _abi_stamp_path(lib_path: Path) -> Path:
    return lib_path.with_name(f"{lib_path.name}.abi")


def _verify_library_abi(lib: ctypes.CDLL, lib_path: Path) -> None:
    try:
        abi_version = lib.nottoodumb_abi_version
    except AttributeError as exc:
        raise RuntimeError(
            f"NotTooDumb library {lib_path} does not export an ABI version."
        ) from exc
    abi_version.argtypes = []
    abi_version.restype = ctypes.c_int
    actual = int(abi_version())
    if actual != NOTTOODUMB_ABI_VERSION:
        raise RuntimeError(
            f"NotTooDumb library {lib_path} has ABI version {actual}, "
            f"expected {NOTTOODUMB_ABI_VERSION}."
        )

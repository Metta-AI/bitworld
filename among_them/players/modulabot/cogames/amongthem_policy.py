"""CoGames AmongThem policy wrapper around the Nim Modulabot shared library.

This module is the entry point that the CoGames tournament worker imports as
``amongthem_policy.AmongThemPolicy``. It:

    1. Locates the ``modulabot`` source tree (works in both the in-repo source
       layout and the flattened bundle layout that ``cogames ship`` produces).
    2. Imports ``build_modulabot`` from that tree and compiles
       ``libmodulabot.{dylib,so,dll}`` on demand. The tournament image already
       has Nim and ``nimby`` installed (see
       ``packages/cogames/Dockerfile.episode_runner``), so the build runs
       inside the worker without any cross-compilation.
    3. Loads the library through ``ctypes`` and routes the BitWorld
       AmongThem ``step_batch`` interface to ``modulabot_step_batch``.

Mirrors ``among_them/players/nottoodumb_policy.py`` deliberately — keep the
two in lockstep when the BitWorld policy interface changes.
"""

from __future__ import annotations

import ctypes
import importlib
import importlib.util
import platform
import sys
from pathlib import Path
from types import ModuleType

import numpy as np

from mettagrid.bitworld import (
    BITWORLD_ACTION_COUNT,
    BITWORLD_ACTION_NAMES,
    SCREEN_HEIGHT,
    SCREEN_WIDTH,
)
from mettagrid.policy.policy import AgentPolicy, MultiAgentPolicy
from mettagrid.policy.policy_env_interface import PolicyEnvInterface
from mettagrid.simulator import Action, AgentObservation


def _find_modulabot_dir() -> Path:
    """Returns the directory containing ``build_modulabot.py``.

    Handles two layouts:

    * **Source layout.** This file lives at
      ``among_them/players/modulabot/cogames/amongthem_policy.py``. The
      modulabot directory is one level up.
    * **Bundle layout.** ``cogames ship`` flattens this file to the bundle
      root because its basename matches the policy module name. Sibling
      ``-f`` includes preserve their relative paths, so the modulabot tree
      ends up at ``<bundle_root>/among_them/players/modulabot``.

    Searched in source-layout-first order so an in-repo run never accidentally
    picks up a stale bundled copy.
    """
    here = Path(__file__).resolve().parent
    candidates = [
        here.parent,                                          # source layout
        here / "among_them" / "players" / "modulabot",         # bundle layout
        here.parent / "among_them" / "players" / "modulabot",  # belt + braces
    ]
    for candidate in candidates:
        if (candidate / "build_modulabot.py").is_file():
            return candidate
    searched = "\n  ".join(str(c) for c in candidates)
    raise RuntimeError(
        "Could not locate modulabot source directory. Searched:\n  " + searched
    )


def _import_build_modulabot(modulabot_dir: Path) -> ModuleType:
    """Imports ``build_modulabot`` from the located modulabot directory.

    Uses ``importlib.util.spec_from_file_location`` so we don't depend on
    ``among_them`` being a Python package (it isn't — the repo has no
    ``__init__.py`` files along that path).
    """
    module_name = "_modulabot_build_modulabot"
    cached = sys.modules.get(module_name)
    if cached is not None:
        return cached
    spec = importlib.util.spec_from_file_location(
        module_name, modulabot_dir / "build_modulabot.py"
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(
            f"Could not load build_modulabot.py from {modulabot_dir}"
        )
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


class _AmongThemAgentPolicy(AgentPolicy):
    """Single-agent fallback wrapper around the batched Nim policy."""

    def __init__(
        self,
        policy_env_info: PolicyEnvInterface,
        parent: "AmongThemPolicy",
        agent_id: int,
    ):
        super().__init__(policy_env_info)
        self._parent = parent
        self._agent_id = agent_id

    def step(self, obs: AgentObservation) -> Action:
        del obs
        action_index = self._parent.step_agent(self._agent_id)
        return Action(name=self._policy_env_info.action_names[action_index])


class AmongThemPolicy(MultiAgentPolicy):
    """Runs ``modulabot.nim`` through a compiled shared library.

    Required action space matches the BitWorld AmongThem trainable action
    set (``BITWORLD_ACTION_NAMES``). The Nim side enforces the same table at
    ``among_them/players/modulabot/ffi/lib.nim:TrainableMasks``.
    """

    short_names = ["amongthem_modulabot"]

    def __init__(self, policy_env_info: PolicyEnvInterface, device: str = "cpu"):
        super().__init__(policy_env_info, device=device)
        if tuple(policy_env_info.action_names) != BITWORLD_ACTION_NAMES:
            raise ValueError(
                "AmongThemPolicy requires the "
                f"{BITWORLD_ACTION_COUNT}-action BitWorld action space."
            )
        self._modulabot_dir = _find_modulabot_dir()
        self._build = _import_build_modulabot(self._modulabot_dir)
        self._lib = self._load_library()
        self._lib.modulabot_new_policy.argtypes = [ctypes.c_int]
        self._lib.modulabot_new_policy.restype = ctypes.c_int
        self._lib.modulabot_step_batch.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_int32),
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        self._lib.modulabot_step_batch.restype = None
        self._num_agents = max(1, int(policy_env_info.num_agents))
        self._handle = int(self._lib.modulabot_new_policy(self._num_agents))
        self._last_actions = np.zeros(self._num_agents, dtype=np.int32)

    def agent_policy(self, agent_id: int) -> AgentPolicy:
        return _AmongThemAgentPolicy(self._policy_env_info, self, agent_id)

    def step_batch(self, raw_observations: np.ndarray, raw_actions: np.ndarray) -> None:
        observations = self._normalize_observations(raw_observations)
        batch_size = observations.shape[0]
        self._ensure_agent_count(batch_size)
        agent_ids = np.arange(batch_size, dtype=np.int32)
        frame_advances = np.ones(batch_size, dtype=np.int32)
        actions = np.zeros(batch_size, dtype=np.int32)
        self._lib.modulabot_step_batch(
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
        lib_path = self._modulabot_dir / _library_name()
        if self._library_needs_rebuild(lib_path):
            lib_path = Path(self._build.build_modulabot())
        lib = ctypes.CDLL(str(lib_path))
        self._verify_library_abi(lib, lib_path)
        return lib

    def _library_needs_rebuild(self, lib_path: Path) -> bool:
        if not lib_path.exists():
            return True
        try:
            stamp = int(self._build._abi_stamp_path(lib_path).read_text().strip())
        except (OSError, ValueError):
            return True
        return stamp != self._build.MODULABOT_ABI_VERSION

    def _verify_library_abi(self, lib: ctypes.CDLL, lib_path: Path) -> None:
        try:
            abi_version = lib.modulabot_abi_version
        except AttributeError as exc:
            raise RuntimeError(
                f"Modulabot library {lib_path} does not export an ABI version."
            ) from exc
        abi_version.argtypes = []
        abi_version.restype = ctypes.c_int
        actual = int(abi_version())
        expected = self._build.MODULABOT_ABI_VERSION
        if actual != expected:
            raise RuntimeError(
                f"Modulabot library {lib_path} has ABI version {actual}, "
                f"expected {expected}."
            )


def _library_name() -> str:
    system = platform.system()
    if system == "Darwin":
        return "libmodulabot.dylib"
    if system == "Windows":
        return "modulabot.dll"
    return "libmodulabot.so"

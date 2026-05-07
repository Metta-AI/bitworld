"""Standalone ctypes loader for the evidencebot_v2 Nim shared library.

This is the only mandatory native dependency in the SDK. It wraps the three
exported symbols defined in ``among_them/players/evidencebot_v2.nim``:

  * ``evidencebot_v2_abi_version()`` -> ``cint``
  * ``evidencebot_v2_new_policy(numAgents)`` -> ``cint`` handle
  * ``evidencebot_v2_step_batch(handle, agentIds, numAgentIds, numAgents,
        frameStack, height, width, observations, actions)``

The loader auto-rebuilds the .dylib/.so by invoking the existing
``among_them.players.build_evidencebot_v2`` script as a subprocess so the SDK
never imports ``mettagrid`` (the original ctypes wrapper does). If the build
fails we surface a clear error naming the missing toolchain (``nim``).

Frame / action constants
------------------------

The Nim core hard-codes the BitWorld observation surface at 128x128 4-bit
pixels (one nibble per pixel, low-nibble used). The trainable action space is
a fixed list of button bitmasks; ``step_batch`` returns indices into that
list, not raw button bits.
"""

from __future__ import annotations

import ctypes
import os
import platform
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

EVIDENCEBOT_V2_ABI_VERSION = 1
SCREEN_HEIGHT = 128
SCREEN_WIDTH = 128


def _default_players_dir() -> Path:
    """Best-effort discovery of ``among_them/players/`` in the parent monorepo.

    Resolution order:
      1. ``AMONG_THEM_PLAYERS_DIR`` env var
      2. Walk up from this file looking for ``among_them/players``
      3. Fallback: ``../../players`` relative to the SDK package
    """
    env = os.environ.get("AMONG_THEM_PLAYERS_DIR")
    if env:
        return Path(env).expanduser().resolve()
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "among_them" / "players"
        if candidate.is_dir():
            return candidate
        candidate = parent / "players"
        if (parent.name == "among_them") and candidate.is_dir():
            return candidate
    return here.parents[3] / "among_them" / "players"


def _library_name() -> str:
    system = platform.system()
    if system == "Darwin":
        return "libevidencebot_v2.dylib"
    if system == "Windows":
        return "evidencebot_v2.dll"
    return "libevidencebot_v2.so"


def library_path() -> Path:
    return _default_players_dir() / _library_name()


def _abi_stamp_path(lib_path: Path) -> Path:
    return lib_path.with_name(f"{lib_path.name}.abi")


def _needs_rebuild(lib_path: Path) -> bool:
    if not lib_path.exists():
        return True
    try:
        return int(_abi_stamp_path(lib_path).read_text().strip()) != EVIDENCEBOT_V2_ABI_VERSION
    except (OSError, ValueError):
        return True


class FFIError(RuntimeError):
    """Raised when the evidencebot_v2 native library is missing or unloadable."""


def build_library(force: bool = False) -> Path:
    """Build the evidencebot_v2 shared library by shelling out to the existing
    ``build_evidencebot_v2.py`` script.

    We deliberately invoke this as a subprocess (rather than importing) because
    the build script lives outside the SDK package and importing it requires
    putting the monorepo on ``sys.path``. Subprocess isolation also means a
    Nim toolchain failure produces a clean ``FFIError`` rather than tearing
    down the host interpreter.
    """
    players_dir = _default_players_dir()
    lib_path = players_dir / _library_name()
    if not force and not _needs_rebuild(lib_path):
        return lib_path

    build_script = players_dir / "build_evidencebot_v2.py"
    if not build_script.exists():
        raise FFIError(
            f"Cannot build evidencebot_v2: build script missing at {build_script}. "
            "Set AMONG_THEM_PLAYERS_DIR to the directory containing the Nim sources."
        )

    cmd = [sys.executable, str(build_script)]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        raise FFIError(f"Python interpreter not found: {exc}") from exc

    if result.returncode != 0:
        msg = (
            "Failed to build evidencebot_v2 native library.\n"
            f"  command: {' '.join(cmd)}\n"
            f"  cwd:     {players_dir}\n"
            "  stderr:\n"
            + (result.stderr or "<empty>")
            + "\n  stdout:\n"
            + (result.stdout or "<empty>")
            + "\nMake sure the Nim 2.2.4 toolchain is installed (see the build script "
            "or run `nim --version`)."
        )
        raise FFIError(msg)

    if not lib_path.exists():
        raise FFIError(
            f"build_evidencebot_v2.py succeeded but {lib_path} was not produced."
        )
    return lib_path


@dataclass
class _FFISignatures:
    abi_version: ctypes._FuncPointer  # type: ignore[name-defined]
    new_policy: ctypes._FuncPointer  # type: ignore[name-defined]
    step_batch: ctypes._FuncPointer  # type: ignore[name-defined]


class EvidenceBotV2Library:
    """Thin wrapper over the loaded ctypes CDLL.

    Lifetime: one library per process is plenty; ``new_policy`` allocates a
    new opaque handle on each call. The Nim side never frees handles (they
    accumulate in a global seq), so the SDK exposes ``new_policy`` lazily and
    reuses handles where possible.
    """

    def __init__(self, lib_path: Path | None = None, *, auto_build: bool = True):
        if lib_path is None:
            lib_path = library_path()
        if _needs_rebuild(lib_path):
            if not auto_build:
                raise FFIError(
                    f"evidencebot_v2 library missing or stale at {lib_path}. "
                    "Pass auto_build=True or run `python build_evidencebot_v2.py`."
                )
            lib_path = build_library()

        try:
            cdll = ctypes.CDLL(str(lib_path))
        except OSError as exc:
            raise FFIError(f"Could not load {lib_path}: {exc}") from exc

        try:
            cdll.evidencebot_v2_abi_version.argtypes = []
            cdll.evidencebot_v2_abi_version.restype = ctypes.c_int

            cdll.evidencebot_v2_new_policy.argtypes = [ctypes.c_int]
            cdll.evidencebot_v2_new_policy.restype = ctypes.c_int

            cdll.evidencebot_v2_step_batch.argtypes = [
                ctypes.c_int,                    # handle
                ctypes.POINTER(ctypes.c_int32),  # agentIds
                ctypes.c_int,                    # numAgentIds
                ctypes.c_int,                    # numAgents
                ctypes.c_int,                    # frameStack
                ctypes.c_int,                    # height
                ctypes.c_int,                    # width
                ctypes.c_void_p,                 # observations (uint8 buffer)
                ctypes.c_void_p,                 # actions (int32 output buffer)
            ]
            cdll.evidencebot_v2_step_batch.restype = None
        except AttributeError as exc:
            raise FFIError(
                f"{lib_path} does not export the expected evidencebot_v2 symbols: {exc}"
            ) from exc

        actual_abi = int(cdll.evidencebot_v2_abi_version())
        if actual_abi != EVIDENCEBOT_V2_ABI_VERSION:
            raise FFIError(
                f"ABI mismatch for {lib_path}: library reports {actual_abi}, "
                f"SDK expects {EVIDENCEBOT_V2_ABI_VERSION}."
            )

        self.path = lib_path
        self.abi_version = actual_abi
        self._cdll = cdll
        self._sig = _FFISignatures(
            abi_version=cdll.evidencebot_v2_abi_version,
            new_policy=cdll.evidencebot_v2_new_policy,
            step_batch=cdll.evidencebot_v2_step_batch,
        )

    def new_policy(self, num_agents: int) -> int:
        if num_agents <= 0:
            raise ValueError("num_agents must be >= 1")
        return int(self._sig.new_policy(num_agents))

    def step_batch(
        self,
        handle: int,
        observations: np.ndarray,
        *,
        num_agents_hint: int | None = None,
    ) -> np.ndarray:
        """Run one tick across ``observations.shape[0]`` agents.

        ``observations`` must have shape ``(batch, frame_stack, 128, 128)`` and
        dtype ``uint8`` (low nibble is the actual pixel value, high nibble is
        ignored). Returns an ``(batch,)`` int32 array of action indices.
        """
        if observations.ndim == 3:
            observations = observations[:, np.newaxis, :, :]
        if observations.ndim != 4:
            raise ValueError(
                f"Expected 3D or 4D observations, got shape {observations.shape}"
            )
        if observations.shape[2:] != (SCREEN_HEIGHT, SCREEN_WIDTH):
            raise ValueError(
                f"Expected {SCREEN_HEIGHT}x{SCREEN_WIDTH} frames, got {observations.shape[2:]}"
            )

        observations = np.ascontiguousarray(observations, dtype=np.uint8)
        batch = observations.shape[0]
        agent_ids = np.arange(batch, dtype=np.int32)
        actions = np.zeros(batch, dtype=np.int32)
        num_agents = max(num_agents_hint or batch, batch)

        self._sig.step_batch(
            handle,
            agent_ids.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),
            ctypes.c_int(batch),
            ctypes.c_int(num_agents),
            ctypes.c_int(observations.shape[1]),
            ctypes.c_int(observations.shape[2]),
            ctypes.c_int(observations.shape[3]),
            ctypes.c_void_p(observations.ctypes.data),
            ctypes.c_void_p(actions.ctypes.data),
        )
        return actions


_singleton: EvidenceBotV2Library | None = None


def load_library(*, auto_build: bool = True, force_reload: bool = False) -> EvidenceBotV2Library:
    """Get a process-wide singleton library handle. Idempotent."""
    global _singleton
    if _singleton is None or force_reload:
        _singleton = EvidenceBotV2Library(auto_build=auto_build)
    return _singleton


def is_available() -> bool:
    """Cheap check: does the .so/.dylib exist with a valid ABI stamp?"""
    p = library_path()
    return p.exists() and not _needs_rebuild(p)

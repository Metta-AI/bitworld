"""Lively: a BitWorld AmongThem policy backed by a Go subprocess.

At each batch step, the latest unpacked 128x128 palette-indexed frame is
packed to 8192 bytes (two pixels per byte, low nibble first) and piped
to a persistent Go subprocess ("-mode=stdio"). The subprocess writes a
single button-mask byte back. We convert the mask to a cogames action
index via bitworld_action_index.

One Go subprocess is spawned per batch row lazily; the runner iterates
agents in player-index order inside a single policy, so row indices
remain stable while our assigned agents are alive.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import numpy as np

from mettagrid.bitworld import (
    BITWORLD_ACTION_NAMES,
    bitworld_action_index,
)
from mettagrid.policy.policy import AgentPolicy, MultiAgentPolicy
from mettagrid.policy.policy_env_interface import PolicyEnvInterface
from mettagrid.simulator import Action, AgentObservation

GO_BINARY_NAME = "lively_linux_amd64"
PACKED_FRAME_BYTES = 8192


def _find_binary() -> Path:
    here = Path(__file__).resolve().parent
    candidate = here / GO_BINARY_NAME
    if candidate.exists():
        return candidate
    raise FileNotFoundError(f"lively binary {GO_BINARY_NAME} not found beside {__file__}")


def _ensure_executable(binary: Path) -> None:
    # Bundles extracted from a zip may lose the +x bit. chmod is idempotent.
    mode = binary.stat().st_mode
    binary.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _pack_frame(frame: np.ndarray) -> bytes:
    # frame: (128, 128) uint8 with values 0..15. Our Go UnpackFrame reverses
    # this: dst[2*i] = byte & 0x0F, dst[2*i+1] = byte >> 4.
    flat = np.ascontiguousarray(frame, dtype=np.uint8).reshape(-1)
    lo = flat[0::2]
    hi = flat[1::2]
    return (lo | (hi << 4)).tobytes()


class _LivelyWorker:
    """One Go subprocess: pipe frames in, read one mask byte out."""

    def __init__(self, binary: Path):
        self._proc = subprocess.Popen(
            [str(binary), "-mode=stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
            close_fds=True,
        )

    def step(self, frame: np.ndarray) -> int:
        assert self._proc.stdin is not None
        assert self._proc.stdout is not None
        packed = _pack_frame(frame)
        if len(packed) != PACKED_FRAME_BYTES:
            raise ValueError(f"packed frame length {len(packed)}, want {PACKED_FRAME_BYTES}")
        self._proc.stdin.write(packed)
        self._proc.stdin.flush()
        out = self._proc.stdout.read(1)
        if not out:
            rc = self._proc.poll()
            raise RuntimeError(f"lively subprocess exited (rc={rc})")
        return out[0]

    def close(self) -> None:
        if self._proc.poll() is not None:
            return
        try:
            if self._proc.stdin is not None:
                self._proc.stdin.close()
        except Exception:
            pass
        try:
            self._proc.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            self._proc.kill()


class _LivelyAgentPolicy(AgentPolicy):
    def __init__(self, policy_env_info: PolicyEnvInterface, parent: "LivelyPolicy", agent_id: int):
        super().__init__(policy_env_info)
        self._parent = parent
        self._agent_id = agent_id

    def step(self, obs: AgentObservation) -> Action:
        # The BitWorld runner only invokes step_batch; per-agent .step() is a
        # safe noop path that rollout code never exercises for this policy.
        del obs
        return Action(name=BITWORLD_ACTION_NAMES[0])


class LivelyPolicy(MultiAgentPolicy):
    """AmongThem policy that delegates every frame to a Go subprocess."""

    short_names = ["lively"]

    def __init__(self, policy_env_info: PolicyEnvInterface, device: str = "cpu"):
        super().__init__(policy_env_info, device=device)
        if tuple(policy_env_info.action_names) != BITWORLD_ACTION_NAMES:
            raise ValueError("LivelyPolicy requires the BitWorld AmongThem action space")
        self._binary = _find_binary()
        _ensure_executable(self._binary)
        self._workers: list[_LivelyWorker] = []

    def agent_policy(self, agent_id: int) -> AgentPolicy:
        return _LivelyAgentPolicy(self._policy_env_info, self, agent_id)

    def _ensure_workers(self, n: int) -> None:
        while len(self._workers) < n:
            self._workers.append(_LivelyWorker(self._binary))

    def step_batch(self, raw_observations: np.ndarray, raw_actions: np.ndarray) -> None:
        batch = raw_observations.shape[0]
        self._ensure_workers(batch)
        for i in range(batch):
            # Latest frame in the stack; we only look at the most recent tick.
            frame = raw_observations[i, -1]
            mask = self._workers[i].step(frame)
            try:
                raw_actions[i] = bitworld_action_index(mask)
            except ValueError:
                # Safety net: any mask outside the trainable set (e.g. something
                # with Select set) collapses to noop.
                raw_actions[i] = 0

    def close(self) -> None:
        for w in self._workers:
            w.close()
        self._workers.clear()

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

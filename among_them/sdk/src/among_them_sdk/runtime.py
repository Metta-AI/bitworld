"""Runtime environments for SDK-authored agents.

Three runtimes (per DESIGN.md §4.3):

  * :class:`LocalSim` — in-process tick driver. Phase 0/1 doesn't ship a
    Python port of the bitworld simulator, so LocalSim is *minimal*: it
    feeds synthetic frames to the FFI for K ticks and synthesizes voting /
    reporting / chat events at user-configurable rates so module overrides
    actually fire. This is enough for the 5-line hello world *and* for
    unit-testing custom modules.
  * :class:`Subprocess` — launches a compiled binary and streams decisions.
    Phase 0/1 includes a working ``run_default_subprocess`` helper that
    invokes ``build_evidencebot_v2.py`` to confirm the toolchain is wired
    up; full subprocess streaming arrives with Phase 4.
  * :class:`RemoteServer` — Phase 4 stub. Constructing one raises
    ``NotImplementedError`` per the prompt.
"""

from __future__ import annotations

import logging
import random
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from . import ffi as _ffi

logger = logging.getLogger("among_them_sdk.runtime")


@dataclass
class TickEvent:
    tick: int
    agent_id: int
    action_index: int
    extra: dict[str, Any] = field(default_factory=dict)


@dataclass
class MeetingEvent:
    meeting_index: int
    body_player_id: str | None = None


@dataclass
class RunResult:
    ticks: int
    actions: list[int]
    meetings: int
    votes: list[Any]
    reports: list[Any]
    chat_messages: list[str]
    summary: str
    raw: dict[str, Any] = field(default_factory=dict)


class LocalSim:
    """In-process driver. Synthetic frames + scripted event injection.

    Args:
      seed: RNG seed for deterministic test runs.
      ticks_per_round: total ticks per ``run`` round.
      meeting_every: synthesize a meeting event every N ticks (0 = never).
      report_every: synthesize a report-context event every N ticks.
      n_players: how many fake suspects to populate in the voting context.
      noisy_frames: when True, fill frames with random nibbles instead of zeros.
    """

    def __init__(
        self,
        *,
        seed: int = 42,
        ticks_per_round: int = 60,
        meeting_every: int = 30,
        report_every: int = 25,
        n_players: int = 6,
        noisy_frames: bool = False,
    ):
        self.seed = seed
        self.ticks_per_round = ticks_per_round
        self.meeting_every = meeting_every
        self.report_every = report_every
        self.n_players = n_players
        self.noisy_frames = noisy_frames

    def _make_frame(self, rng: random.Random) -> np.ndarray:
        if self.noisy_frames:
            arr = np.array(
                [rng.randint(0, 15) for _ in range(_ffi.SCREEN_HEIGHT * _ffi.SCREEN_WIDTH)],
                dtype=np.uint8,
            ).reshape(1, _ffi.SCREEN_HEIGHT, _ffi.SCREEN_WIDTH)
        else:
            arr = np.zeros((1, _ffi.SCREEN_HEIGHT, _ffi.SCREEN_WIDTH), dtype=np.uint8)
        return arr[np.newaxis, :, :, :]


class Subprocess:
    """Subprocess-backed runtime — Phase 4 will add streaming."""

    def __init__(self, binary: Path | str | None = None, config_dir: Path | str | None = None):
        self.binary = Path(binary) if binary else None
        self.config_dir = Path(config_dir) if config_dir else None

    def run_default_subprocess(self) -> dict[str, Any]:
        """Smoke-test the Nim toolchain by invoking the build script.

        This is what Phase 0/1 uses to confirm a clean machine can produce a
        ``.dylib`` the SDK can load. It's *not* an actual game subprocess
        runner yet — that arrives with Phase 4.
        """
        from . import ffi

        players_dir = ffi._default_players_dir()
        cmd = [sys.executable, str(players_dir / "build_evidencebot_v2.py")]
        result = subprocess.run(cmd, capture_output=True, text=True)
        return {
            "returncode": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }


class RemoteServer:
    """Connect to a running Among Them server over WebSocket.

    Thin alias around :class:`among_them_sdk.live_game.LiveGame` so the
    historical name from DESIGN.md §8 still resolves. Prefer constructing
    ``LiveGame`` directly in new code; this stub exists for back-compat
    and to make ``from among_them_sdk import RemoteServer`` Just Work.
    """

    def __init__(self, *args: Any, **kwargs: Any):
        from .live_game import LiveGame

        self._impl = LiveGame(*args, **kwargs)

    def run_agent(self, agent: Any) -> Any:
        return self._impl.run_agent(agent)

    @property
    def url(self) -> str:
        return self._impl.url


__all__ = [
    "LocalSim",
    "MeetingEvent",
    "RemoteServer",
    "RunResult",
    "Subprocess",
    "TickEvent",
]

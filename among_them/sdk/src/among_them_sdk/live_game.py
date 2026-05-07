"""``LiveGame`` runtime — connects an :class:`Agent` to a real Among Them server.

This is the "actually plays a game" runtime that the prompt asked for. Until
this module landed, the SDK only had :class:`LocalSim` (synthetic frames) and
:class:`RemoteServer` (a ``NotImplementedError`` stub). ``LiveGame`` speaks
the WebSocket wire protocol (binary 4-bit packed frames in, button-mask
packets out) and drives ``evidencebot_v2``'s FFI from real frames.

Design notes
------------

* Synchronous public surface — ``Agent.run(runtime=LiveGame(...))`` stays
  blocking like ``LocalSim`` so the existing examples still read top-to-bottom.
  Internally we run an asyncio loop on the calling thread; the event-loop
  scope is local to ``run`` so we don't poison anyone else's loop.
* One FFI step per frame, mask-on-change semantics. We mirror
  ``runBot`` in ``nottoodumb.nim``: receive frame → tick FFI → translate
  action index to ``TRAINABLE_MASKS[idx]`` → send only if the mask changed.
* No private SDK state intrudes on the FFI. We pass observations into
  ``EvidenceBotV2Policy.step_with_hooks`` exactly the same way ``LocalSim``
  does so the existing override hooks (``on_navigate``) still work.
* Best-effort transcript capture. The server doesn't emit structured event
  packets we can subscribe to, so we record what flows through *this*
  player's pipe: each chat string sent, the most recent action history, and
  the connection lifecycle. Vote target / kill target observations live
  inside the FFI bot and aren't surfaced via the current ABI — see the
  architectural note in :mod:`among_them_sdk.policy.evidencebot_v2`.

Phase 4 hooks (DESIGN.md §8) can extend this runtime to subscribe to
``/global`` for full-game telemetry and to ``/reward`` for live scores.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any
from urllib.parse import quote

import numpy as np

from . import wire as _wire
from .runtime import RunResult

if TYPE_CHECKING:
    from .agent import Agent

try:
    import websockets
    from websockets.asyncio.client import connect as websockets_connect
except ImportError as exc:  # pragma: no cover - import-time guard
    websockets = None  # type: ignore[assignment]
    websockets_connect = None  # type: ignore[assignment]
    _IMPORT_ERROR: ImportError | None = exc
else:
    _IMPORT_ERROR = None

logger = logging.getLogger("among_them_sdk.live_game")


@dataclass
class LiveGameTranscript:
    """Per-game observations the SDK was able to capture from one socket.

    These are best-effort — anything not surfaced over a single player
    pipe (e.g. the server's full vote tally, who killed whom, who is
    actually an imposter) lives outside this transcript.
    """

    player_name: str
    server_url: str
    connected_at: float
    disconnected_at: float | None = None
    frames_received: int = 0
    masks_sent: int = 0
    chat_messages_sent: list[str] = field(default_factory=list)
    last_action_index: int = 0
    last_mask: int = 0
    actions_seen: dict[int, int] = field(default_factory=dict)
    error: str | None = None


class LiveGame:
    """Run an SDK agent against a running Among Them server.

    Parameters
    ----------
    host:
        Server hostname (default ``localhost``).
    port:
        Server TCP port.
    name:
        Player name (passed via the ``?name=`` query string).
    url:
        Override the WebSocket URL entirely. Useful for ``wss://`` or for
        joining a server that lives behind a path prefix. ``None`` → build
        ``ws://{host}:{port}/player?name={name}`` automatically.
    max_ticks:
        Hard cap on FFI ticks before we disconnect. ``None`` = run until
        the server closes the socket (the natural end-of-game signal).
    connect_timeout:
        Seconds to spend retrying the initial WebSocket connect.
    on_event:
        Optional async callback fired for ``connect``, ``frame``, ``mask``,
        ``chat``, ``disconnect``, and ``error`` events. Useful for tests.
    """

    def __init__(
        self,
        *,
        host: str = "localhost",
        port: int = 2000,
        name: str = "sdkbot",
        url: str | None = None,
        max_ticks: int | None = None,
        connect_timeout: float = 30.0,
        on_event: Callable[[str, dict[str, Any]], Awaitable[None]] | None = None,
    ):
        if _IMPORT_ERROR is not None:
            raise ImportError(
                "LiveGame requires the 'websockets' package. "
                "Install with `uv add websockets` or `pip install websockets`. "
                f"Original error: {_IMPORT_ERROR}"
            )
        self.host = host
        self.port = port
        self.name = name
        self.url = url or self._default_url(host, port, name)
        self.max_ticks = max_ticks
        self.connect_timeout = connect_timeout
        self.on_event = on_event

    @staticmethod
    def _default_url(host: str, port: int, name: str) -> str:
        return f"ws://{host}:{port}/player?name={quote(name)}"

    async def _emit(self, event: str, **payload: Any) -> None:
        if self.on_event is None:
            return
        try:
            await self.on_event(event, payload)
        except Exception as exc:  # pragma: no cover - user callback
            logger.warning("on_event(%s) raised: %s", event, exc)

    async def _connect_with_retry(self) -> Any:
        """Retry the initial connect for ``connect_timeout`` seconds.

        The server takes a few hundred ms to bind its socket after launch,
        and the SDK boots faster than a freshly-spawned ``among_them``. So
        we wait up to ``connect_timeout`` for the port to be live before
        propagating an error to the caller.

        We *disable* WebSocket pings (``ping_interval=None``). The Nim
        ``among_them`` server (mummy + custom framing) doesn't respond to
        WebSocket control pings, so the default 20s ping/20s timeout
        kicks the SDK socket mid-game. ``nottoodumb`` and the Python
        sidecar bot both run with effectively-unlimited ping timeouts —
        we mirror that here to avoid being booted at the 40s mark.
        """
        deadline = time.monotonic() + max(0.1, self.connect_timeout)
        last_exc: Exception | None = None
        attempt = 0
        while time.monotonic() < deadline:
            attempt += 1
            try:
                return await websockets_connect(
                    self.url,
                    max_size=None,
                    ping_interval=None,
                    ping_timeout=None,
                    close_timeout=2.0,
                )
            except (OSError, ConnectionError, Exception) as exc:
                # websockets raises various connection-level errors before
                # the handshake completes; swallow them and keep polling.
                last_exc = exc
                await asyncio.sleep(min(0.25 * attempt, 1.0))
        raise ConnectionError(
            f"Failed to connect to {self.url} within {self.connect_timeout:.1f}s "
            f"(last error: {last_exc!r})"
        )

    async def _run_async(
        self,
        agent: Agent,
        transcript: LiveGameTranscript,
    ) -> None:
        """The actual frame loop. Mirrors ``runBot`` in ``nottoodumb.nim``."""
        from .modules.navigator import NavigationContext  # local to avoid cycles
        from .policy.evidencebot_v2 import OverrideHooks

        try:
            ws = await self._connect_with_retry()
        except Exception as exc:
            transcript.error = f"connect_failed: {exc!r}"
            transcript.disconnected_at = time.time()
            await self._emit("error", phase="connect", error=str(exc))
            raise

        transcript.connected_at = time.time()
        await self._emit("connect", url=self.url, name=self.name)
        logger.info("LiveGame connected: %s", self.url)

        last_mask = -1
        try:
            async for message in ws:
                if isinstance(message, str):
                    # Reward stream packets aren't sent to /player, but
                    # defend in case the server tags one as text by mistake.
                    continue
                if len(message) != _wire.PROTOCOL_BYTES:
                    # Ignore non-frame binary messages (e.g. control frames
                    # that aren't full game frames). Real games only emit
                    # 8192-byte frames on /player.
                    continue

                transcript.frames_received += 1

                pixels = _wire.unpack_4bpp(message)  # (128, 128) uint8
                obs = pixels[np.newaxis, np.newaxis, :, :]  # (1, 1, 128, 128)

                action_arr = agent.policy.step_with_hooks(
                    obs,
                    OverrideHooks(
                        on_navigate=_build_navigator_hook(agent, NavigationContext)
                    ),
                )
                action_idx = int(action_arr[0]) if action_arr.size else 0
                mask = _wire.mask_from_action_index(action_idx)

                transcript.last_action_index = action_idx
                transcript.last_mask = mask
                transcript.actions_seen[action_idx] = (
                    transcript.actions_seen.get(action_idx, 0) + 1
                )

                if mask != last_mask:
                    await ws.send(_wire.blob_from_mask(mask))
                    last_mask = mask
                    transcript.masks_sent += 1

                await self._emit("frame", tick=transcript.frames_received, mask=mask)

                if self.max_ticks is not None and transcript.frames_received >= self.max_ticks:
                    logger.info(
                        "LiveGame hit max_ticks=%d; closing socket",
                        self.max_ticks,
                    )
                    await ws.close()
                    break

        except websockets.exceptions.ConnectionClosed as exc:  # type: ignore[union-attr]
            logger.info("LiveGame socket closed: %s", exc)
        except Exception as exc:
            transcript.error = repr(exc)
            await self._emit("error", phase="run", error=str(exc))
            logger.exception("LiveGame error")
            raise
        finally:
            transcript.disconnected_at = time.time()
            await self._emit(
                "disconnect",
                frames=transcript.frames_received,
                masks=transcript.masks_sent,
                error=transcript.error,
            )
            try:
                await ws.close()
            except Exception:
                pass

    async def _run_async_local_sdk_policy(
        self,
        policy: Any,
        transcript: LiveGameTranscript,
    ) -> None:
        """Frame loop for a :class:`LocalSDKPolicy` (no Agent required).

        Drives the same ``_DirectiveOverrideEngine`` that ``SDKPolicy``
        runs inside the cogames Docker validator, just over a real
        WebSocket instead of mettagrid's batched env.
        """
        try:
            ws = await self._connect_with_retry()
        except Exception as exc:
            transcript.error = f"connect_failed: {exc!r}"
            transcript.disconnected_at = time.time()
            await self._emit("error", phase="connect", error=str(exc))
            raise

        transcript.connected_at = time.time()
        await self._emit("connect", url=self.url, name=self.name)
        logger.info("LiveGame[local_sdk_policy] connected: %s", self.url)

        last_mask = -1
        try:
            async for message in ws:
                if isinstance(message, str):
                    continue
                if len(message) != _wire.PROTOCOL_BYTES:
                    continue

                transcript.frames_received += 1
                pixels = _wire.unpack_4bpp(message)
                obs = pixels[np.newaxis, np.newaxis, :, :]

                action_arr = policy.step_batch(obs)
                action_idx = int(action_arr[0]) if action_arr.size else 0
                mask = _wire.mask_from_action_index(action_idx)

                transcript.last_action_index = action_idx
                transcript.last_mask = mask
                transcript.actions_seen[action_idx] = (
                    transcript.actions_seen.get(action_idx, 0) + 1
                )

                if mask != last_mask:
                    await ws.send(_wire.blob_from_mask(mask))
                    last_mask = mask
                    transcript.masks_sent += 1

                await self._emit("frame", tick=transcript.frames_received, mask=mask)
                if (
                    self.max_ticks is not None
                    and transcript.frames_received >= self.max_ticks
                ):
                    logger.info(
                        "LiveGame hit max_ticks=%d; closing socket", self.max_ticks
                    )
                    await ws.close()
                    break
        except websockets.exceptions.ConnectionClosed as exc:  # type: ignore[union-attr]
            logger.info("LiveGame socket closed: %s", exc)
        except Exception as exc:
            transcript.error = repr(exc)
            await self._emit("error", phase="run", error=str(exc))
            logger.exception("LiveGame error")
            raise
        finally:
            transcript.disconnected_at = time.time()
            await self._emit(
                "disconnect",
                frames=transcript.frames_received,
                masks=transcript.masks_sent,
                error=transcript.error,
            )
            try:
                await ws.close()
            except Exception:
                pass

    def run_local_sdk_policy(
        self, policy: Any
    ) -> tuple[RunResult, LiveGameTranscript]:
        """Drive a :class:`LocalSDKPolicy` directly against the live server.

        Use this when you want to exercise the *exact same code path* the
        cogames tournament runs (the ``SDKPolicy`` override engine) in a
        local game. The only difference between this path and
        ``SDKPolicy.step_batch`` inside cogames is the source of frames
        (WebSocket here, mettagrid env there).
        """
        transcript = LiveGameTranscript(
            player_name=self.name,
            server_url=self.url,
            connected_at=0.0,
        )
        try:
            asyncio.run(self._run_async_local_sdk_policy(policy, transcript))
        except KeyboardInterrupt:
            transcript.error = "keyboard_interrupt"
            raise

        unique_actions = sorted(
            transcript.actions_seen.items(), key=lambda kv: -kv[1]
        )
        from .policy.evidencebot_v2 import BITWORLD_ACTION_NAMES

        action_names = [
            BITWORLD_ACTION_NAMES[i] if 0 <= i < len(BITWORLD_ACTION_NAMES) else str(i)
            for i, _ in unique_actions[:8]
        ]
        summary = (
            f"LiveGame[SDKPolicy]: {transcript.frames_received} frames, "
            f"{transcript.masks_sent} mask updates; top actions: {action_names}"
        )
        return (
            RunResult(
                ticks=transcript.frames_received,
                actions=[],
                meetings=0,
                votes=[],
                reports=[],
                chat_messages=transcript.chat_messages_sent,
                summary=summary,
                raw={
                    "policy_summary": policy.summary(),
                    "directives": policy.directives.model_dump(),
                    "transcript": _transcript_to_dict(transcript),
                    "runtime": "live_game.local_sdk_policy",
                },
            ),
            transcript,
        )

    def run_agent(self, agent: Agent) -> tuple[RunResult, LiveGameTranscript]:
        """Drive ``agent`` against the live server until the socket closes.

        Returns the same :class:`RunResult` shape as :meth:`Agent.run` for
        ``LocalSim`` so the surrounding code can treat both runtimes
        identically. Adds a :class:`LiveGameTranscript` with connection
        details that aren't part of the generic result.
        """
        transcript = LiveGameTranscript(
            player_name=self.name,
            server_url=self.url,
            connected_at=0.0,
        )
        try:
            asyncio.run(self._run_async(agent, transcript))
        except KeyboardInterrupt:
            transcript.error = "keyboard_interrupt"
            raise

        unique_actions = sorted(transcript.actions_seen.items(), key=lambda kv: -kv[1])
        from .policy.evidencebot_v2 import BITWORLD_ACTION_NAMES

        action_names = [
            BITWORLD_ACTION_NAMES[i] if 0 <= i < len(BITWORLD_ACTION_NAMES) else str(i)
            for i, _ in unique_actions[:8]
        ]
        summary = (
            f"LiveGame: {transcript.frames_received} frames, "
            f"{transcript.masks_sent} mask updates against {self.url}; "
            f"top actions: {action_names}"
        )
        result = RunResult(
            ticks=transcript.frames_received,
            actions=[],  # full action history would balloon; transcript carries the histogram
            meetings=0,
            votes=[],
            reports=[],
            chat_messages=transcript.chat_messages_sent,
            summary=summary,
            raw={
                "policy_summary": agent.policy.summary(),
                "directives": agent.directives.model_dump(),
                "transcript": _transcript_to_dict(transcript),
                "runtime": "live_game",
            },
        )
        return result, transcript


def _build_navigator_hook(agent: Agent, NavigationContext: Any) -> Any:
    """Bridge :class:`Agent.navigator` overrides into the FFI nav hook.

    Mirrors the bridge inside ``Agent._build_override_hooks`` but inlined
    here so we don't depend on the runtime's internal helpers (which are
    private and may change).
    """
    from .modules.navigator import ScriptedNavigator

    nav = agent.navigator
    if isinstance(nav, ScriptedNavigator) and nav.goal_injector is None:
        return None

    def _hook(ctx: dict[str, Any]) -> int | None:
        return nav.step(
            NavigationContext(
                tick=ctx.get("tick", 0),
                agent_id=ctx.get("agent_id", 0),
                ffi_action=ctx.get("ffi_action", 0),
                extras=ctx,
            )
        )

    return _hook


def _transcript_to_dict(t: LiveGameTranscript) -> dict[str, Any]:
    return {
        "player_name": t.player_name,
        "server_url": t.server_url,
        "connected_at": t.connected_at,
        "disconnected_at": t.disconnected_at,
        "frames_received": t.frames_received,
        "masks_sent": t.masks_sent,
        "chat_messages_sent": list(t.chat_messages_sent),
        "last_action_index": t.last_action_index,
        "last_mask": t.last_mask,
        "actions_seen": dict(t.actions_seen),
        "error": t.error,
    }


def fetch_results_json(path: str) -> dict[str, Any] | None:
    """Read the server's ``COGAME_SAVE_RESULTS_PATH`` JSON if present.

    Returns ``None`` when the file is missing or unparseable. Used by the
    8-player example to grab winners / tasks / kills after the server
    quits, since none of that is broadcast over the per-player socket.
    """
    try:
        with open(path) as fh:
            return json.load(fh)
    except (FileNotFoundError, OSError, json.JSONDecodeError) as exc:
        logger.debug("fetch_results_json(%s): %s", path, exc)
        return None


__all__ = [
    "LiveGame",
    "LiveGameTranscript",
    "fetch_results_json",
]

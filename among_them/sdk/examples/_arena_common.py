"""Shared scaffolding for the variant_arena and eight_player_game examples.

Hosts the orchestration primitives — ``ManagedProc`` lifecycle, port
allocator, log-pump thread, native-binary builders — so both the
1-SDK-vs-7-bots example and the 8-SDK-variants arena can reuse them
without copy-paste drift.

Nothing here imports the SDK package; it's pure orchestration glue and
safe to import early in any subprocess that just needs to find the repo
layout.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import IO

# Resolve the SDK / repo / among_them paths once and re-export so callers
# don't each redo the parents[N] dance. Kept here (not in the SDK package)
# because these are *example*-side conventions, not part of the public API.
_THIS_FILE = Path(__file__).resolve()
SDK_DIR: Path = _THIS_FILE.parent.parent
REPO_ROOT: Path = SDK_DIR.parents[1]
AMONG_THEM_DIR: Path = REPO_ROOT / "among_them"
EXAMPLES_DIR: Path = _THIS_FILE.parent

SERVER_BIN: Path = REPO_ROOT / "out" / "among_them"
NOTTOODUMB_BIN: Path = REPO_ROOT / "out" / "nottoodumb"
NOTTOODUMB_SRC: Path = AMONG_THEM_DIR / "players" / "nottoodumb" / "nottoodumb.nim"
SERVER_SRC: Path = AMONG_THEM_DIR / "among_them.nim"


class ExampleError(RuntimeError):
    """Raised for any user-actionable orchestration failure."""


# --------------------------- process plumbing -------------------------- #


@dataclass
class ManagedProc:
    """One subprocess plus its tee'd log file. Cleaned up on context exit."""

    name: str
    popen: subprocess.Popen[bytes]
    log_path: Path
    log_fh: IO[bytes]
    pump_thread: threading.Thread | None = None

    def is_alive(self) -> bool:
        return self.popen.poll() is None

    def stop(self, timeout: float = 5.0) -> int | None:
        if self.popen.poll() is None:
            self.popen.terminate()
            try:
                self.popen.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.popen.kill()
                with suppress(subprocess.TimeoutExpired):
                    self.popen.wait(timeout=2.0)
        if self.pump_thread is not None and self.pump_thread.is_alive():
            self.pump_thread.join(timeout=2.0)
        with suppress(Exception):
            self.log_fh.close()
        return self.popen.returncode


def start_managed(
    name: str,
    cmd: list[str],
    log_dir: Path,
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> ManagedProc:
    """Spawn ``cmd`` as a subprocess, tee combined stdout/stderr to ``log_dir/<name>.log``."""
    log_path = log_dir / f"{name}.log"
    log_fh = log_path.open("wb", buffering=0)
    log_fh.write(f"$ cwd={cwd or os.getcwd()}\n$ {' '.join(cmd)}\n".encode())
    log_fh.flush()
    popen = subprocess.Popen(  # noqa: S603 - intentional subprocess
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )

    def _pump(stream: IO[bytes], sink: IO[bytes]) -> None:
        try:
            for chunk in iter(lambda: stream.read(4096), b""):
                if not chunk:
                    break
                sink.write(chunk)
        except Exception:
            pass

    thread = threading.Thread(
        target=_pump,
        args=(popen.stdout, log_fh),
        name=f"pump-{name}",
        daemon=True,
    )
    thread.start()

    return ManagedProc(
        name=name,
        popen=popen,
        log_path=log_path,
        log_fh=log_fh,
        pump_thread=thread,
    )


# --------------------------- net helpers ------------------------------ #


def pick_free_port() -> int:
    """Reserve a free TCP port and immediately release it.

    Standard race-prone trick (the OS could hand the port to someone else
    before the server binds), but good enough for a local example. Pin a
    port via the ``--server-port`` flag for repro.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for_port(host: str, port: int, *, timeout: float = 30.0) -> None:
    """Block until ``host:port`` accepts a TCP connect, or raise."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.1)
    raise ExampleError(f"Server didn't listen on {host}:{port} within {timeout:.1f}s")


# --------------------------- build helpers ---------------------------- #


def ensure_evidencebot_lib() -> Path:
    """Build (or reuse) the evidencebot_v2 .dylib that the SDK FFI loads.

    Imports the SDK lazily so this module is safe to import in subprocesses
    that don't need the FFI (e.g. the orchestrator process itself).
    """
    sys.path.insert(0, str(SDK_DIR / "src"))
    from among_them_sdk import ffi as _ffi

    if not _ffi.is_available():
        print("[build] evidencebot_v2 library missing; invoking build script...")
        _ffi.build_library(force=False)
    lib = _ffi.library_path()
    if not lib.exists():
        raise ExampleError(
            f"evidencebot_v2 library not found at {lib} after build."
        )
    print(f"[build] evidencebot_v2 lib OK: {lib}")
    return lib


def ensure_native_binary(name: str, src: Path, exe: Path) -> Path:
    """Compile ``src`` into ``exe`` if the exe is missing or outdated.

    Mirrors the ``tools/quick_player`` recipe: ``nim c -d:release`` with
    the source path, letting ``config.nims`` set ``--outdir:./out``.
    """
    if exe.exists() and src.stat().st_mtime <= exe.stat().st_mtime:
        return exe
    if shutil.which("nim") is None:
        raise ExampleError(
            "`nim` not on PATH but the example needs to compile "
            f"{src.name}. Install Nim 2.2.4 (see "
            "among_them/players/build_evidencebot_v2.py) and re-run."
        )
    print(f"[build] compiling {name} from {src.relative_to(REPO_ROOT)}...")
    extra: list[str] = []
    # nottoodumb pulls in whisky which needs SSL even for ws://.
    if name == "nottoodumb":
        extra.append("-d:ssl")
        extra.append("-d:botHeadless")
    cmd = ["nim", "c", "-d:release", *extra, str(src.relative_to(REPO_ROOT))]
    proc = subprocess.run(  # noqa: S603
        cmd,
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise ExampleError(
            f"Failed to compile {name} ({src}). "
            "See output above; ensure Nim 2.2.4 + repo deps via `nimby sync`."
        )
    if not exe.exists():
        raise ExampleError(
            f"`nim c` succeeded for {name} but {exe} was not produced."
        )
    print(f"[build] {name} -> {exe}")
    return exe


def tail_file(path: Path, *, lines: int = 20) -> str:
    """Return the last ``lines`` lines of ``path`` as a string, defensively."""
    try:
        with path.open("rb") as fh:
            data = fh.read()
        text = data.decode("utf-8", errors="replace")
        return "\n".join(text.splitlines()[-lines:])
    except OSError:
        return f"<no log at {path}>"


__all__ = [
    "AMONG_THEM_DIR",
    "EXAMPLES_DIR",
    "ExampleError",
    "ManagedProc",
    "NOTTOODUMB_BIN",
    "NOTTOODUMB_SRC",
    "REPO_ROOT",
    "SDK_DIR",
    "SERVER_BIN",
    "SERVER_SRC",
    "ensure_evidencebot_lib",
    "ensure_native_binary",
    "pick_free_port",
    "start_managed",
    "tail_file",
    "wait_for_port",
]

"""Build helper for the Nim Modulabot shared library.

Mirrors players/build_nottoodumb.py — the FFI calling convention and
nimby-managed Nim toolchain are identical across bots; only the source
file, output path, and `-d:` define change.
"""

from __future__ import annotations

import fcntl
import os
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

MODULABOT_DIR = Path(__file__).resolve().parent
PLAYERS_DIR = MODULABOT_DIR.parent
ROOT = PLAYERS_DIR.parents[1]
NIMBY_LOCK = ROOT / "nimby.lock"
NIM_VERSION = "2.2.4"
NIMBY_VERSION = "0.1.26"
NIMBY_SYNC_LOCK = Path.home() / ".nimby" / ".python_sync.lock"


def build_modulabot() -> Path:
    """Builds the Modulabot shared library and returns its path."""
    _install_nim()
    _sync_nimby()
    out_path = MODULABOT_DIR / _library_name()
    cmd = [
        "nim",
        "c",
        "--app:lib",
        "-d:modulabotLibrary",
        f"--out:{out_path}",
        *_nim_paths_from_lock(NIMBY_LOCK),
        str(MODULABOT_DIR / "modulabot.nim"),
    ]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        raise RuntimeError(f"Failed to build Modulabot Nim library: {result.returncode}")
    return out_path


def _sync_nimby() -> None:
    if shutil.which("nimby") is not None:
        if shutil.which("git") is None:
            _manual_sync_nimby_lock(NIMBY_LOCK)
        else:
            _run_nimby_serialized(["nimby", "sync", "-g", str(NIMBY_LOCK)], cwd=ROOT)


def _run_nimby_serialized(args: list[str], *, cwd: Path) -> None:
    NIMBY_SYNC_LOCK.parent.mkdir(parents=True, exist_ok=True)
    with open(NIMBY_SYNC_LOCK, "w") as lock_fd:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        subprocess.check_call(args, cwd=cwd)


def _nim_already_installed() -> bool:
    nim = shutil.which("nim")
    if nim is None:
        return False
    result = subprocess.run([nim, "--version"], capture_output=True, text=True)
    return result.returncode == 0 and f"Nim Compiler Version {NIM_VERSION}" in result.stdout


def _install_nim() -> None:
    if _nim_already_installed():
        return
    nimby_url = _nimby_url()
    if nimby_url is None:
        system = platform.system()
        arch = platform.machine()
        raise RuntimeError(f"Nim {NIM_VERSION} is unavailable for {system} {arch}.")

    nim_bin_dir = Path.home() / ".nimby" / "nim" / "bin"
    dst = nim_bin_dir / "nimby"
    with tempfile.TemporaryDirectory() as tmp:
        nimby = Path(tmp) / "nimby"
        urllib.request.urlretrieve(nimby_url, nimby)
        nimby.chmod(nimby.stat().st_mode | stat.S_IEXEC)
        subprocess.check_call([str(nimby), "use", NIM_VERSION])
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(nimby, dst)

    os.environ["PATH"] = f"{dst.parent}{os.pathsep}" + os.environ.get("PATH", "")
    os.environ["PATH"] = f"{nim_bin_dir}{os.pathsep}" + os.environ.get("PATH", "")


def _nimby_url() -> str | None:
    system = platform.system()
    arch = platform.machine()
    if system == "Linux" and arch == "x86_64":
        return f"https://github.com/treeform/nimby/releases/download/{NIMBY_VERSION}/nimby-Linux-X64"
    if system == "Linux" and arch == "aarch64":
        return f"https://github.com/treeform/nimby/releases/download/{NIMBY_VERSION}/nimby-Linux-ARM64"
    if system == "Darwin" and arch == "arm64":
        return f"https://github.com/treeform/nimby/releases/download/{NIMBY_VERSION}/nimby-macOS-ARM64"
    if system == "Darwin" and arch == "x86_64":
        return f"https://github.com/treeform/nimby/releases/download/{NIMBY_VERSION}/nimby-macOS-X64"
    return None


def _manual_sync_nimby_lock(lock_path: Path) -> None:
    pkgs_dir = Path.home() / ".nimby" / "pkgs"
    pkgs_dir.mkdir(parents=True, exist_ok=True)
    for raw in lock_path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 4:
            raise RuntimeError(f"Unexpected nimby.lock line: {raw!r}")
        name, url, commit = parts[0], parts[2], parts[3]
        if not url.startswith("https://github.com/"):
            raise RuntimeError(f"Unsupported nimby.lock URL without git: {url}")
        owner, repo = url.removeprefix("https://github.com/").strip("/").split("/", 1)
        dest = pkgs_dir / name
        marker = dest / ".nimby_commit"
        if marker.is_file() and marker.read_text().strip() == commit:
            continue
        if dest.exists():
            shutil.rmtree(dest)
        zip_url = f"https://codeload.github.com/{owner}/{repo}/zip/{commit}"
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / f"{name}.zip"
            urllib.request.urlretrieve(zip_url, zip_path)
            with zipfile.ZipFile(zip_path) as zf:
                zf.extractall(tmp)
            dirs = [p for p in Path(tmp).iterdir() if p.is_dir()]
            if len(dirs) != 1:
                raise RuntimeError(f"Unexpected zip layout for {zip_url}.")
            shutil.move(str(dirs[0]), dest)
        marker.write_text(commit)


def _nim_paths_from_lock(lock_path: Path) -> list[str]:
    pkgs_dir = Path.home() / ".nimby" / "pkgs"
    args: list[str] = []
    for raw in lock_path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name = line.split()[0]
        candidate = pkgs_dir / name / "src"
        if not candidate.exists():
            candidate = pkgs_dir / name
        args.append(f"--path:{candidate}")
    return args


def _library_name() -> str:
    system = platform.system()
    if system == "Darwin":
        return "libmodulabot.dylib"
    if system == "Windows":
        return "modulabot.dll"
    return "libmodulabot.so"


if __name__ == "__main__":
    print(build_modulabot())

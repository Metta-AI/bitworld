"""Cyborg policy framework bridge.

The cyborg framework at
``/Users/aaln/experiments/softmax/policies/policies/cyborg-policy-framework``
ships as a vendored source tree without a ``pyproject.toml``. We add it to
``sys.path`` lazily so the SDK can reuse cyborg's primitives (``Directive``,
``Command``, ``CommandKind``) when they are present, and falls back to local
SDK-defined equivalents when they are not. This keeps the SDK installable in
CI / Docker images that don't ship cyborg.

Why a bridge instead of a hard dependency?

  * cyborg is path-only (no PyPI / no pyproject) so we can't list it as a
    proper dependency.
  * Cyborg's import root is ``framework`` — a name that collides with many
    other unrelated packages — so importing it unconditionally is hostile
    in shared environments.
  * Cyborg is sync-only and tightly-coupled to its own game directory layout;
    we want to use only its Pydantic-free dataclasses, not its harness loop.

Override the cyborg path with ``CYBORG_FRAMEWORK_PATH``.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

CYBORG_DEFAULT_PATH = Path(
    "/Users/aaln/experiments/softmax/policies/policies/cyborg-policy-framework"
)


def _candidate_paths() -> list[Path]:
    paths: list[Path] = []
    env = os.environ.get("CYBORG_FRAMEWORK_PATH")
    if env:
        paths.append(Path(env).expanduser())
    paths.append(CYBORG_DEFAULT_PATH)
    return paths


def bootstrap() -> Path | None:
    for candidate in _candidate_paths():
        if candidate.is_dir() and (candidate / "framework").is_dir():
            s = str(candidate)
            if s not in sys.path:
                sys.path.insert(0, s)
            return candidate
    return None


CYBORG_ROOT: Path | None = bootstrap()


CyborgCommandKind = None
CyborgCommand = None
CyborgDirective = None
CyborgGameConfig = None

if CYBORG_ROOT is not None:
    try:
        from framework.types import (  # type: ignore[import-not-found]
            Command as _Cmd,
        )
        from framework.types import (
            CommandKind as _Kind,
        )
        from framework.types import (
            Directive as _Dir,
        )
        from framework.types import (
            GameConfig as _Cfg,
        )

        CyborgCommandKind = _Kind
        CyborgCommand = _Cmd
        CyborgDirective = _Dir
        CyborgGameConfig = _Cfg
    except Exception:
        CyborgCommandKind = None
        CyborgCommand = None
        CyborgDirective = None
        CyborgGameConfig = None


def is_available() -> bool:
    return CyborgDirective is not None


def status() -> dict:
    return {
        "available": is_available(),
        "root": str(CYBORG_ROOT) if CYBORG_ROOT else None,
        "imported": {
            "Command": CyborgCommand is not None,
            "CommandKind": CyborgCommandKind is not None,
            "Directive": CyborgDirective is not None,
            "GameConfig": CyborgGameConfig is not None,
        },
    }

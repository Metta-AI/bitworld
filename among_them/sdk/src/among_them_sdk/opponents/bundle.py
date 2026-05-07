"""Tournament-bundleable snapshot of analyzed opponent profiles.

Cogames runs the SDK's policy inside a Docker validator with no network
and no API keys (see ``policy/cogames.py``). That means the live
:class:`OpponentStore` — which can call an LLM — must never be touched
at tournament time. Instead the packaging step calls
:func:`freeze_profiles` to write a static JSON snapshot, and the
runtime uses :class:`BundledProfileLookup` (read-only) to consult it.

Snapshot schema
---------------

::

    {
      "version": 1,
      "frozen_at": <unix timestamp>,
      "profiles": [<OpponentProfile.model_dump()>, ...]
    }

The whole snapshot is one file. We don't split per-opponent because the
tournament bundle ships a single config + the file count is something
the SDK has to keep low (every -f flag adds upload cost).
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from .models import OpponentProfile
from .store import OpponentStore

logger = logging.getLogger("among_them_sdk.opponents.bundle")

SNAPSHOT_VERSION = 1


def freeze_profiles(
    store: OpponentStore,
    output_path: Path | str,
    *,
    names: list[str] | None = None,
) -> Path:
    """Write a tournament-safe profile snapshot.

    Parameters
    ----------
    store:
        Source store to read profiles from.
    output_path:
        File path to write. Parent directories are created.
    names:
        Optional list of opponent names to include. Default = every
        profile in the store.
    """
    profiles_dict = store.list_profiles()
    if names is not None:
        profiles_dict = {n: p for n, p in profiles_dict.items() if n in names}

    data = {
        "version": SNAPSHOT_VERSION,
        "frozen_at": time.time(),
        "profiles": [p.model_dump() for p in profiles_dict.values()],
    }

    out = Path(output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2, default=str) + "\n", encoding="utf-8")
    logger.info(
        "wrote opponent snapshot: %d profiles -> %s", len(data["profiles"]), out
    )
    return out


class BundledProfileLookup(Mapping[str, OpponentProfile]):
    """Read-only mapping over a frozen snapshot.

    Behaves like a ``dict[str, OpponentProfile]`` so the consumer
    modules can accept either the live store's profiles or this
    static lookup with no special-casing. Construct via
    :meth:`from_path` (preferred) or :meth:`from_dict` (for tests).
    """

    def __init__(self, profiles: dict[str, OpponentProfile]):
        self._profiles = dict(profiles)

    @classmethod
    def from_path(cls, path: Path | str) -> BundledProfileLookup:
        p = Path(path)
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            logger.warning("could not read snapshot %s: %s", p, exc)
            return cls({})
        return cls.from_dict(data)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> BundledProfileLookup:
        version = data.get("version")
        if version != SNAPSHOT_VERSION:
            logger.warning(
                "snapshot version %s != expected %s; loading best-effort",
                version,
                SNAPSHOT_VERSION,
            )
        profiles_list = data.get("profiles") or []
        out: dict[str, OpponentProfile] = {}
        for raw in profiles_list:
            try:
                profile = OpponentProfile.model_validate(raw)
                out[profile.name] = profile
            except Exception as exc:  # pragma: no cover - schema drift
                logger.warning("snapshot row failed validation: %s", exc)
        return cls(out)

    def __getitem__(self, key: str) -> OpponentProfile:
        return self._profiles[key]

    def __iter__(self):  # type: ignore[override]
        return iter(self._profiles)

    def __len__(self) -> int:
        return len(self._profiles)

    def get(self, key: str, default: OpponentProfile | None = None) -> OpponentProfile | None:  # type: ignore[override]
        return self._profiles.get(key, default)

    def names(self) -> list[str]:
        return sorted(self._profiles.keys())


__all__ = [
    "SNAPSHOT_VERSION",
    "BundledProfileLookup",
    "freeze_profiles",
]

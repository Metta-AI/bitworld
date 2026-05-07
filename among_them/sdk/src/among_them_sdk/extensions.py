"""Entry-point discovery for third-party profiles and modules.

Authors of new policies publish them as :pypi:`pip`-installable packages with
``[project.entry-points."among_them.profiles"]`` declarations. The SDK
discovers them via :func:`importlib.metadata.entry_points`. Discovery is
lazy and cheap — we only import an entry point when the user references it
by name.
"""

from __future__ import annotations

import importlib
import logging
from importlib.metadata import EntryPoint, entry_points
from typing import Any

logger = logging.getLogger("among_them_sdk.extensions")

PROFILE_GROUP = "among_them.profiles"
MODULE_GROUPS = (
    "among_them.modules.voter",
    "among_them.modules.chatter",
    "among_them.modules.reporter",
    "among_them.modules.navigator",
)


def _eps(group: str) -> list[EntryPoint]:
    try:
        return list(entry_points(group=group))
    except Exception as exc:
        logger.warning("entry_points(%s) failed: %s", group, exc)
        return []


def list_profiles() -> dict[str, str]:
    """Return ``{name: target}`` for all installed profiles, including built-ins."""
    found: dict[str, str] = {}
    for ep in _eps(PROFILE_GROUP):
        found[ep.name] = ep.value
    found.setdefault("default", "among_them_sdk.policy.evidencebot_v2:DefaultProfile")
    found.setdefault("evidencebot_v2", "among_them_sdk.policy.evidencebot_v2:DefaultProfile")
    return found


def load_profile(name: str) -> Any:
    eps = list_profiles()
    if name not in eps:
        raise KeyError(f"Profile {name!r} not found. Known: {sorted(eps)}")
    target = eps[name]
    module_path, _, attr = target.partition(":")
    module = importlib.import_module(module_path)
    obj = getattr(module, attr)
    return obj() if isinstance(obj, type) else obj


def list_modules(slot: str) -> dict[str, str]:
    group = f"among_them.modules.{slot}"
    return {ep.name: ep.value for ep in _eps(group)}


__all__ = ["list_modules", "list_profiles", "load_profile"]

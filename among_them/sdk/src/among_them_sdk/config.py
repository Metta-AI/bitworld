"""Config layering: defaults < env vars < ``among-them.toml`` < kwargs.

Light layer over ``tomllib`` (Py3.11+). The TOML file is optional; missing
file => empty config. Keys with ``*_API_KEY`` are *rejected* by the loader
to discourage committing secrets.
"""

from __future__ import annotations

import logging
import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

logger = logging.getLogger("among_them_sdk.config")

DEFAULT_TOML_PATH = Path("among-them.toml")
ENV_PREFIX = "AMONG_THEM_"


@dataclass
class SDKConfig:
    profile: str = "evidencebot_v2"
    runtime: str = "local-sim"
    tracing_backend: str = "structlog"
    raw: dict[str, Any] = field(default_factory=dict)


def _reject_secret_keys(data: dict[str, Any]) -> None:
    for k in list(data.keys()):
        if isinstance(k, str) and k.endswith("_API_KEY"):
            logger.warning("Refusing to load secret key %r from TOML config", k)
            data.pop(k)
        elif isinstance(data[k], dict):
            _reject_secret_keys(data[k])


def load_toml(path: Path | None = None) -> dict[str, Any]:
    p = path or DEFAULT_TOML_PATH
    if not p.exists():
        return {}
    try:
        data = tomllib.loads(p.read_text())
    except Exception as exc:
        logger.warning("Failed to parse %s: %s", p, exc)
        return {}
    _reject_secret_keys(data)
    return data


def load_env() -> dict[str, str]:
    out: dict[str, str] = {}
    for key, value in os.environ.items():
        if key.startswith(ENV_PREFIX):
            out[key[len(ENV_PREFIX):].lower()] = value
    if "OPENAI_API_KEY" in os.environ:
        out["openai_api_key_present"] = "1"
    if "ANTHROPIC_API_KEY" in os.environ:
        out["anthropic_api_key_present"] = "1"
    return out


def resolve(*, toml_path: Path | None = None, **overrides: Any) -> SDKConfig:
    """Combine the four layers and produce a typed :class:`SDKConfig`."""
    toml_data = load_toml(toml_path)
    env_data = load_env()
    raw = {**toml_data}
    if "agent" in toml_data and isinstance(toml_data["agent"], dict):
        if "profile" in toml_data["agent"]:
            raw["profile"] = toml_data["agent"]["profile"]
    if "runtime" in toml_data and isinstance(toml_data["runtime"], dict):
        if "default" in toml_data["runtime"]:
            raw["runtime"] = toml_data["runtime"]["default"]
    if "tracing" in toml_data and isinstance(toml_data["tracing"], dict):
        if "backend" in toml_data["tracing"]:
            raw["tracing_backend"] = toml_data["tracing"]["backend"]
    if "profile" in env_data:
        raw["profile"] = env_data["profile"]
    raw.update({k: v for k, v in overrides.items() if v is not None})

    return SDKConfig(
        profile=raw.get("profile", "evidencebot_v2"),
        runtime=raw.get("runtime", "local-sim"),
        tracing_backend=raw.get("tracing_backend", "structlog"),
        raw=raw,
    )


__all__ = ["SDKConfig", "load_env", "load_toml", "resolve"]

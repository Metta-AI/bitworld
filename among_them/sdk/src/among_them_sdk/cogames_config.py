"""Cogames bundle config — the JSON file that ships with the SDK upload.

Cogames calls our policy ``__init__(policy_env_info, device='cpu')`` — there
is no way to pass ``instructions=`` or other kwargs through the constructor.
So when an SDK user wants their tournament submission to behave like
``Agent.create(instructions="...", cognitive={...}, voter=..., ...)`` does
locally, the SDK ships a JSON file alongside the policy module and the
policy reads it at construct time.

Schema (any of these keys may be omitted):

```json
{
  "instructions":  "Be aggressive about reporting bodies, never trust greens",
  "cognitive":     {"suspicion_threshold": 0.6, "report_eagerness": "high"},
  "directives":    { ... }   // pre-resolved Directives JSON, wins over `instructions`
  "modules": {
    "voter":    {"type": "scripted", "params": {"threshold": 0.7}},
    "chatter":  {"type": "scripted", "params": {"tone": "suspicious"}},
    "reporter": {"type": "scripted", "params": {"eagerness": "high"}}
  }
}
```

Three rules the inside-Docker validator must obey:

1. **No network at runtime.** The deterministic ``parse_instructions_keyword``
   parser is the only thing we call inside Docker. If the user wants a
   richer LLM-resolved Directives, they ship the resolved ``directives``
   block (the packaging helper does this automatically when an LLM is
   available at upload time).
2. **No LLM modules instantiated by default.** ``LLMVoter`` / ``LLMChatter``
   silently fall back to scripted on missing keys, but skipping them
   entirely is cheaper. The schema only resolves to LLM modules when the
   user explicitly says ``"type": "llm"`` AND ``llm_safe_in_docker``
   is true (see :func:`build_modules`).
3. **Pre-resolved beats parse.** When ``directives`` is present we use it
   directly and ignore ``instructions``; the parser is only a fallback
   for users who want to write the natural-language string by hand.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field, ValidationError

from .cognition.instructions import Directives, parse_instructions_keyword

logger = logging.getLogger("among_them_sdk.cogames_config")

CONFIG_FILENAME = "among_them_sdk_config.json"


class ModuleSpec(BaseModel):
    """One module slot: ``type`` + free-form ``params``."""

    type: str = "scripted"
    params: dict[str, Any] = Field(default_factory=dict)

    model_config = {"extra": "allow"}


class CogamesBundleConfig(BaseModel):
    """Schema for the JSON file shipped alongside ``SDKPolicy``.

    All fields optional. ``directives`` (pre-resolved) wins over
    ``instructions`` (parsed) wins over an empty config (defaults).
    """

    instructions: str | None = None
    cognitive: dict[str, Any] = Field(default_factory=dict)
    directives: dict[str, Any] | None = None
    modules: dict[str, ModuleSpec] = Field(default_factory=dict)
    notes: list[str] = Field(default_factory=list)

    model_config = {"extra": "forbid"}

    def resolve_directives(self) -> Directives:
        """Resolve the bundled config to a :class:`Directives` instance.

        Order:
          1. ``directives`` if present — straight ``Directives(**...)``.
          2. ``instructions`` parsed with the deterministic keyword parser.
          3. defaults.
          ``cognitive`` overrides win over either path.
        """
        if self.directives is not None:
            try:
                base = Directives(**self.directives)
            except ValidationError as exc:
                logger.warning(
                    "cogames_config.directives failed validation, "
                    "falling back to instructions/defaults: %s",
                    exc,
                )
                base = parse_instructions_keyword(self.instructions or "")
        elif self.instructions:
            # Keyword parser only. The LLM parser is *not* called inside the
            # cogames Docker validator (no API keys, no network). Users who
            # want LLM-resolved directives must run the packaging helper
            # locally before upload.
            base = parse_instructions_keyword(self.instructions)
        else:
            base = Directives.scripted_defaults()
        if self.cognitive:
            base = base.merged_with(**self.cognitive)
        return base


def find_config_file(start_dir: Path) -> Path | None:
    """Look for ``among_them_sdk_config.json`` next to ``start_dir``.

    Cogames bundles ship the policy module at the bundle root; we drop the
    config file there so it sits beside ``cogames.py``. Falling back to
    ``start_dir.parent`` covers a couple of likely layouts (e.g. when the
    bundle root is a parent of the SDK package).
    """
    candidates = [start_dir / CONFIG_FILENAME]
    parent = start_dir.parent
    if parent != start_dir:
        candidates.append(parent / CONFIG_FILENAME)
    for path in candidates:
        if path.is_file():
            return path
    return None


def load_config(path: Path | str) -> CogamesBundleConfig:
    """Load + validate a config file. Returns an empty config on missing/bad input."""
    p = Path(path)
    try:
        data = json.loads(p.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning("cogames config load failed at %s: %s", p, exc)
        return CogamesBundleConfig()
    if not isinstance(data, Mapping):
        logger.warning("cogames config at %s is not an object; ignoring", p)
        return CogamesBundleConfig()
    try:
        return CogamesBundleConfig.model_validate(dict(data))
    except ValidationError as exc:
        logger.warning("cogames config at %s failed schema: %s", p, exc)
        return CogamesBundleConfig()


def write_config(config: CogamesBundleConfig, path: Path | str) -> Path:
    """Write a config to disk as pretty-printed JSON. Creates parents."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(config.model_dump_json(indent=2, exclude_none=True) + "\n")
    return p


# --------------------------- module factory --------------------------- #


def build_modules(
    config: CogamesBundleConfig,
    *,
    llm_safe_in_docker: bool = False,
) -> dict[str, Any]:
    """Resolve ``config.modules`` to actual module instances.

    Returns a dict with optional keys ``voter``, ``chatter``, ``reporter``
    suitable for unpacking into :meth:`Agent.create` or for the
    :class:`SDKPolicy` override engine. Unknown ``type`` strings log a
    warning and fall back to scripted defaults; LLM types are skipped
    when ``llm_safe_in_docker`` is False.
    """
    from .modules import (
        LLMChatter,
        LLMVoter,
        ScriptedChatter,
        ScriptedReporter,
        ScriptedVoter,
        SilentChatter,
    )

    out: dict[str, Any] = {}
    for slot, spec in config.modules.items():
        kind = (spec.type or "scripted").lower()
        params = dict(spec.params or {})

        if slot == "voter":
            if kind == "scripted":
                out[slot] = ScriptedVoter(**params)
            elif kind == "llm" and llm_safe_in_docker:
                out[slot] = LLMVoter(**params)
            elif kind == "llm":
                logger.info(
                    "cogames_config: skipping voter type=llm "
                    "(LLM not safe in cogames Docker)"
                )
                out[slot] = ScriptedVoter()
            else:
                logger.warning("Unknown voter type %r; using scripted default", kind)
                out[slot] = ScriptedVoter()
        elif slot == "chatter":
            if kind == "scripted":
                out[slot] = ScriptedChatter(**params)
            elif kind == "silent":
                out[slot] = SilentChatter()
            elif kind == "llm" and llm_safe_in_docker:
                out[slot] = LLMChatter(**params)
            elif kind == "llm":
                logger.info("cogames_config: skipping chatter type=llm")
                out[slot] = ScriptedChatter()
            else:
                logger.warning("Unknown chatter type %r; using scripted default", kind)
                out[slot] = ScriptedChatter()
        elif slot == "reporter":
            if kind == "scripted":
                out[slot] = ScriptedReporter(**params)
            else:
                logger.warning(
                    "Reporter type %r not supported in this milestone; using scripted",
                    kind,
                )
                out[slot] = ScriptedReporter()
        else:
            logger.warning(
                "cogames_config: ignoring unknown module slot %r (allowed: voter, chatter, reporter)",
                slot,
            )
    return out


__all__ = [
    "CONFIG_FILENAME",
    "CogamesBundleConfig",
    "ModuleSpec",
    "build_modules",
    "find_config_file",
    "load_config",
    "write_config",
]

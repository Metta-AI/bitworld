"""Verification suite for the cogames bundle path.

These tests cover the *bundle shape* — config schema round-trip, the
packaging CLI's output layout, and the override engine's behavior at the
action-index level. They deliberately don't run a real ``cogames upload``;
that path needs Docker + tournament credentials and is out of scope for
unit tests.

What's verified
---------------

* ``CogamesBundleConfig`` round-trips through JSON via the schema.
* :class:`LocalSDKPolicy` resolves directives from a config and applies
  the same override engine ``SDKPolicy`` will at upload time.
* The packaging CLI (``python -m among_them_sdk.package``) writes the
  expected JSON file and prints a usable cogames upload command with all
  the ``-f`` flags from ``among_them/players/SUBMIT_TO_TOURNAMENT.md``.
* :class:`SDKPolicy` is importable + instantiable when ``mettagrid`` is
  available in the environment, and is *gracefully* unavailable
  otherwise.

Mettagrid is not installed in this monorepo's venv, so the ``SDKPolicy``
construction tests are skipped with a clear reason. The override-engine
tests run unconditionally because they don't need mettagrid.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from among_them_sdk import (
    CogamesBundleConfig,
    LocalSDKPolicy,
    load_cogames_config,
    write_cogames_config,
)
from among_them_sdk.cogames_config import CONFIG_FILENAME, ModuleSpec, build_modules
from among_them_sdk.policy.cogames import (
    _METTAGRID_AVAILABLE,
    _NOOP_ACTION_INDEX,
    _REPORT_ACTIONS,
    _DirectiveOverrideEngine,
)

SDK_DIR = Path(__file__).resolve().parents[1]
PACKAGE_PY = SDK_DIR / "src" / "among_them_sdk" / "package.py"


def test_bundle_config_round_trip(tmp_path: Path) -> None:
    """JSON round-trip: file → ``load_config`` → ``write_config`` → file."""
    cfg = CogamesBundleConfig(
        instructions="Be paranoid. Trust nobody.",
        cognitive={"suspicion_threshold": 0.8},
        modules={
            "voter": ModuleSpec(type="scripted", params={"threshold": 0.7}),
            "chatter": ModuleSpec(type="scripted", params={"tone": "suspicious"}),
        },
    )
    out = tmp_path / "bundle.json"
    write_cogames_config(cfg, out)
    assert out.is_file()

    reloaded = load_cogames_config(out)
    assert reloaded.instructions == cfg.instructions
    assert reloaded.cognitive == cfg.cognitive
    assert reloaded.modules.keys() == cfg.modules.keys()
    assert reloaded.modules["voter"].type == "scripted"


def test_resolve_directives_prefers_pre_resolved() -> None:
    """If ``directives`` is present, ``instructions`` is ignored entirely."""
    cfg = CogamesBundleConfig(
        instructions="trust nobody",
        directives={"suspicion_threshold": 0.123, "report_eagerness": "low"},
    )
    d = cfg.resolve_directives()
    assert d.suspicion_threshold == 0.123
    assert d.report_eagerness == "low"


def test_resolve_directives_keyword_fallback() -> None:
    """Without ``directives``, ``instructions`` runs through the keyword parser."""
    cfg = CogamesBundleConfig(instructions="Trust nobody. Vote with the majority.")
    d = cfg.resolve_directives()
    assert d.suspicion_threshold > 0.5
    assert d.voting_style in {"majority", "evidence"}


def test_build_modules_skips_llm_inside_docker() -> None:
    """``llm_safe_in_docker=False`` swaps LLM module specs for scripted ones."""
    cfg = CogamesBundleConfig(
        modules={"voter": ModuleSpec(type="llm", params={"model": "gpt-5.5"})}
    )
    mods = build_modules(cfg, llm_safe_in_docker=False)
    voter = mods["voter"]
    assert type(voter).__name__ == "ScriptedVoter", (
        "LLM voter should fall back to ScriptedVoter when not LLM-safe"
    )


def test_override_engine_suppresses_reports_when_eagerness_low() -> None:
    """End-to-end: report action gets collapsed to noop on directive/Reporter conflict."""
    from among_them_sdk import Directives, ScriptedReporter
    from among_them_sdk.policy.cogames import BITWORLD_ACTION_NAMES

    if not _REPORT_ACTIONS:
        pytest.skip("report actions not present in BITWORLD_ACTION_NAMES")

    report_idx = BITWORLD_ACTION_NAMES.index(next(iter(_REPORT_ACTIONS)))
    engine = _DirectiveOverrideEngine(
        Directives(report_eagerness="low"),
        reporter=ScriptedReporter(eagerness="low"),
    )

    actions = np.array([report_idx, report_idx, 0, 1], dtype=np.int32)
    out = engine.apply_per_tick(actions.copy())
    suppressed = (out == _NOOP_ACTION_INDEX).sum() - (actions == _NOOP_ACTION_INDEX).sum()
    assert suppressed == 2, f"Expected 2 reports suppressed, got {suppressed}"
    assert engine.stats.reports_suppressed == 2
    assert engine.stats.reports_passed == 0


def test_override_engine_passes_reports_when_eagerness_high() -> None:
    from among_them_sdk import Directives, ScriptedReporter
    from among_them_sdk.policy.cogames import BITWORLD_ACTION_NAMES

    if not _REPORT_ACTIONS:
        pytest.skip("report actions not present in BITWORLD_ACTION_NAMES")

    report_idx = BITWORLD_ACTION_NAMES.index(next(iter(_REPORT_ACTIONS)))
    engine = _DirectiveOverrideEngine(
        Directives(report_eagerness="high"),
        reporter=ScriptedReporter(eagerness="high"),
    )
    actions = np.array([report_idx, report_idx, 0], dtype=np.int32)
    out = engine.apply_per_tick(actions.copy())
    assert (out == report_idx).sum() == 2
    assert engine.stats.reports_passed == 2


def test_local_sdk_policy_step_batch() -> None:
    """LocalSDKPolicy.step_batch composes EvidenceBotV2Policy + override engine."""
    cfg = CogamesBundleConfig(
        directives={"suspicion_threshold": 0.7, "report_eagerness": "low"},
        modules={"reporter": ModuleSpec(type="scripted", params={"eagerness": "low"})},
    )
    policy = LocalSDKPolicy(config=cfg)
    obs = np.zeros((1, 1, 128, 128), dtype=np.uint8)

    actions = policy.step_batch(obs)
    assert actions.shape == (1,)
    assert actions.dtype == np.int32

    summary = policy.summary()
    assert summary["policy"] == "among_them_sdk.LocalSDKPolicy"
    assert summary["directives"]["report_eagerness"] == "low"
    assert "stats" in summary


def test_packaging_cli_writes_config_and_prints_command(tmp_path: Path) -> None:
    """``python -m among_them_sdk.package`` produces a valid bundle layout."""
    out = tmp_path / CONFIG_FILENAME
    proc = subprocess.run(  # noqa: S603 - intentional subprocess
        [
            sys.executable,
            "-m",
            "among_them_sdk.package",
            "--instructions",
            "Trust nobody. Report bodies aggressively.",
            "--cognitive",
            "suspicion_threshold=0.6",
            "--module",
            "voter=scripted:threshold=0.6",
            "--policy-name",
            "test-sdk-policy",
            "--out",
            str(out),
            "--dry-run",
        ],
        capture_output=True,
        text=True,
        cwd=str(SDK_DIR),
    )
    assert proc.returncode == 0, f"package CLI failed:\n{proc.stdout}\n{proc.stderr}"
    assert out.is_file(), "config JSON was not written"

    data = json.loads(out.read_text())
    cfg = CogamesBundleConfig.model_validate(data)
    assert cfg.instructions and "Trust nobody" in cfg.instructions
    assert cfg.cognitive["suspicion_threshold"] == 0.6
    assert "voter" in cfg.modules
    assert cfg.modules["voter"].type == "scripted"

    # The printed upload command must include every -f flag from
    # SUBMIT_TO_TOURNAMENT.md plus the SDK package + pyproject.
    stdout = proc.stdout
    must_have_files = [
        "among_them/players/evidencebot_v2_policy.py",
        "among_them/players/build_evidencebot_v2.py",
        "among_them/players/evidencebot_v2.nim",
        "among_them/sim.nim",
        "common",
        "src/bitworld",
        "nimby.lock",
        "among_them/sdk/src/among_them_sdk",
        "among_them/sdk/pyproject.toml",
    ]
    for needle in must_have_files:
        assert needle in stdout, f"upload command missing -f {needle!r}\n{stdout}"
    assert "class=among_them_sdk.policy.cogames.SDKPolicy" in stdout
    assert "test-sdk-policy" in stdout
    assert "--dry-run" in stdout


@pytest.mark.skipif(
    not _METTAGRID_AVAILABLE,
    reason=(
        "mettagrid is not installed in this monorepo venv. SDKPolicy "
        "construction is exercised inside the cogames Docker validator. "
        "The local LocalSDKPolicy test above covers the same override "
        "engine with the same config."
    ),
)
def test_sdk_policy_constructs_with_mettagrid() -> None:
    from mettagrid.policy.policy_env_interface import PolicyEnvInterface

    from among_them_sdk import SDKPolicy
    from among_them_sdk.policy.evidencebot_v2 import BITWORLD_ACTION_NAMES

    info = PolicyEnvInterface(
        action_names=list(BITWORLD_ACTION_NAMES),
        num_agents=1,
    )
    policy = SDKPolicy(info, device="cpu")
    raw_obs = np.zeros((1, 1, 128, 128), dtype=np.uint8)
    raw_actions = np.zeros((1,), dtype=np.int32)
    policy.step_batch(raw_obs, raw_actions)
    assert raw_actions.shape == (1,)

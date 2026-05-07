"""Default scripted policy backends.

Phase 0/1 ships exactly one policy: :class:`EvidenceBotV2Policy`, which
wraps the Nim ``evidencebot_v2`` shared library via FFI. There is *no*
pure-Python fallback in this milestone — the Nim toolchain is a hard
dependency (see ``among_them_sdk.ffi`` for the helpful error).
"""

from .cogames import AmongThemPolicy, LocalSDKPolicy, SDKPolicy
from .evidencebot_v2 import (
    BITWORLD_ACTION_NAMES,
    BITWORLD_NUM_ACTIONS,
    DefaultProfile,
    EvidenceBotV2Policy,
    OverrideHooks,
)

__all__ = [
    "BITWORLD_ACTION_NAMES",
    "BITWORLD_NUM_ACTIONS",
    "AmongThemPolicy",
    "DefaultProfile",
    "EvidenceBotV2Policy",
    "LocalSDKPolicy",
    "OverrideHooks",
    "SDKPolicy",
]

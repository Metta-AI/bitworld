"""Smoke test: the FFI library loads, the ABI matches, and one tick runs."""

from __future__ import annotations

import numpy as np

from among_them_sdk import ffi


def test_ffi_library_loads():
    lib = ffi.load_library()
    assert lib.abi_version == ffi.EVIDENCEBOT_V2_ABI_VERSION
    assert lib.path.exists()


def test_ffi_smoke_tick():
    lib = ffi.load_library()
    handle = lib.new_policy(num_agents=1)
    assert isinstance(handle, int)

    obs = np.zeros((1, 1, ffi.SCREEN_HEIGHT, ffi.SCREEN_WIDTH), dtype=np.uint8)
    actions = lib.step_batch(handle, obs)
    assert actions.shape == (1,)
    assert actions.dtype == np.int32
    assert 0 <= int(actions[0]) < 256


def test_ffi_singleton():
    a = ffi.load_library()
    b = ffi.load_library()
    assert a is b

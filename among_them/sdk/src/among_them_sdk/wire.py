"""Wire protocol primitives for talking to the Among Them server.

This module is the Python mirror of ``common/protocol.nim`` plus the
``TrainableMasks`` table from ``among_them/players/evidencebot_v2/ffi.nim``.
Everything here is byte-for-byte equivalent to what the Nim bots do; we keep
it independent of the rest of the SDK so it can be reused outside ``LiveGame``.
"""

from __future__ import annotations

from typing import Final

import numpy as np

SCREEN_WIDTH: Final[int] = 128
SCREEN_HEIGHT: Final[int] = 128
PROTOCOL_BYTES: Final[int] = (SCREEN_WIDTH * SCREEN_HEIGHT) // 2
INPUT_PACKET_BYTES: Final[int] = 2

PACKET_INPUT: Final[int] = 0
PACKET_CHAT: Final[int] = 1

BUTTON_UP: Final[int] = 1 << 0
BUTTON_DOWN: Final[int] = 1 << 1
BUTTON_LEFT: Final[int] = 1 << 2
BUTTON_RIGHT: Final[int] = 1 << 3
BUTTON_SELECT: Final[int] = 1 << 4
BUTTON_A: Final[int] = 1 << 5
BUTTON_B: Final[int] = 1 << 6

DEFAULT_WS_PATH: Final[str] = "/player"

TRAINABLE_MASKS: Final[tuple[int, ...]] = (
    0,
    BUTTON_A,
    BUTTON_B,
    BUTTON_UP,
    BUTTON_UP | BUTTON_A,
    BUTTON_UP | BUTTON_B,
    BUTTON_DOWN,
    BUTTON_DOWN | BUTTON_A,
    BUTTON_DOWN | BUTTON_B,
    BUTTON_LEFT,
    BUTTON_LEFT | BUTTON_A,
    BUTTON_LEFT | BUTTON_B,
    BUTTON_RIGHT,
    BUTTON_RIGHT | BUTTON_A,
    BUTTON_RIGHT | BUTTON_B,
    BUTTON_UP | BUTTON_LEFT,
    BUTTON_UP | BUTTON_LEFT | BUTTON_A,
    BUTTON_UP | BUTTON_LEFT | BUTTON_B,
    BUTTON_UP | BUTTON_RIGHT,
    BUTTON_UP | BUTTON_RIGHT | BUTTON_A,
    BUTTON_UP | BUTTON_RIGHT | BUTTON_B,
    BUTTON_DOWN | BUTTON_LEFT,
    BUTTON_DOWN | BUTTON_LEFT | BUTTON_A,
    BUTTON_DOWN | BUTTON_LEFT | BUTTON_B,
    BUTTON_DOWN | BUTTON_RIGHT,
    BUTTON_DOWN | BUTTON_RIGHT | BUTTON_A,
    BUTTON_DOWN | BUTTON_RIGHT | BUTTON_B,
)


def unpack_4bpp(packed: bytes | bytearray | memoryview) -> np.ndarray:
    """Expand a packed 4-bit framebuffer (``PROTOCOL_BYTES``) into a 128x128
    ``uint8`` array of palette indices in ``[0..15]``.

    Mirrors ``unpack4bpp`` in ``nottoodumb.nim``: even index = low nibble,
    odd index = high nibble. The frame stores one pixel per cell with the
    high nibble guaranteed zero (the FFI masks it anyway).
    """
    if len(packed) != PROTOCOL_BYTES:
        raise ValueError(
            f"unpack_4bpp expected {PROTOCOL_BYTES} bytes, got {len(packed)}"
        )
    arr = np.frombuffer(packed, dtype=np.uint8)
    out = np.empty(arr.size * 2, dtype=np.uint8)
    out[0::2] = arr & 0x0F
    out[1::2] = (arr >> 4) & 0x0F
    return out.reshape(SCREEN_HEIGHT, SCREEN_WIDTH)


def blob_from_mask(mask: int) -> bytes:
    """Build an input packet for ``mask`` (1 byte tag + 1 byte mask)."""
    return bytes((PACKET_INPUT, mask & 0xFF))


def blob_from_chat(text: str) -> bytes:
    """Build a chat packet (1 byte tag + ASCII bytes)."""
    return bytes((PACKET_CHAT,)) + text.encode("ascii", errors="replace")


def mask_from_action_index(index: int) -> int:
    """Look up the FFI action index in ``TRAINABLE_MASKS``.

    Out-of-range indices fall back to the no-op mask. The Nim FFI never
    emits indices outside ``[0, len(TRAINABLE_MASKS))`` today, but defending
    here keeps the SDK robust if the FFI grows new actions.
    """
    if 0 <= index < len(TRAINABLE_MASKS):
        return TRAINABLE_MASKS[index]
    return 0


__all__ = [
    "BUTTON_A",
    "BUTTON_B",
    "BUTTON_DOWN",
    "BUTTON_LEFT",
    "BUTTON_RIGHT",
    "BUTTON_SELECT",
    "BUTTON_UP",
    "DEFAULT_WS_PATH",
    "INPUT_PACKET_BYTES",
    "PACKET_CHAT",
    "PACKET_INPUT",
    "PROTOCOL_BYTES",
    "SCREEN_HEIGHT",
    "SCREEN_WIDTH",
    "TRAINABLE_MASKS",
    "blob_from_chat",
    "blob_from_mask",
    "mask_from_action_index",
    "unpack_4bpp",
]

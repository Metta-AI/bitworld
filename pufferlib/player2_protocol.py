"""BitWorld /player2 protocol constants and sprite observation adapter."""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]

SCREEN_WIDTH = 128
SCREEN_HEIGHT = 128
PLAYER2_PATH = "/player2"
PACKET_PLAYER2_CHAT = 0x81
PACKET_PLAYER2_INPUT = 0x84
PLAYER2_INPUT_PACKET_BYTES = 2
AMONG_THEM_MAX_PLAYERS = 16
PLAYER2_HEADER_FEATURES = 4
PLAYER2_GRID_SIZE = 32
PLAYER2_PLAYER_FEATURE_OFFSET = PLAYER2_HEADER_FEATURES + PLAYER2_GRID_SIZE * PLAYER2_GRID_SIZE
PLAYER2_PLAYER_FEATURES = 4
PLAYER2_BODY_FEATURE_OFFSET = PLAYER2_PLAYER_FEATURE_OFFSET + PLAYER2_PLAYER_FEATURES * AMONG_THEM_MAX_PLAYERS
PLAYER2_BODY_FEATURES = 4
PLAYER2_TASK_FEATURE_OFFSET = PLAYER2_BODY_FEATURE_OFFSET + PLAYER2_BODY_FEATURES * AMONG_THEM_MAX_PLAYERS
PLAYER2_TASK_FEATURES = 5
PLAYER2_TASK_COUNT = 15
PLAYER2_FEATURES = PLAYER2_TASK_FEATURE_OFFSET + PLAYER2_TASK_FEATURES * PLAYER2_TASK_COUNT
PLAYER2_KILL_ICON_INDEX = 1
PLAYER2_TASK_PROGRESS_INDEX = 2
PLAYER2_TASKS_REMAINING_INDEX = 3
PLAYER2_FLAG_TASK_ICON_VISIBLE = 1
PLAYER2_FLAG_TASK_ARROW_VISIBLE = 2
PLAYER2_FLAG_PLAYER_ROLE_IMPOSTER = 8

AMONG_THEM_PHASE_LOBBY = 0
AMONG_THEM_PHASE_PLAYING = 1
AMONG_THEM_PHASE_VOTING = 2
AMONG_THEM_PHASE_VOTE_RESULT = 3
AMONG_THEM_PHASE_GAME_OVER = 4
AMONG_THEM_PHASE_ROLE_REVEAL = 5

PLAYER2_FLAG_PLAYER_PRESENT = 1
PLAYER2_FLAG_PLAYER_ALIVE = 4
PLAYER2_FLAG_PLAYER_FLIP_H = 16
PLAYER2_FLAG_PLAYER_GHOST = 32

MAP_VOID_COLOR = 12
TASK_BAR_WIDTH = 14

PLAYER_OBJECT_BASE = 1000
PROTOCOL_CHAT_ICON_OBJECT_BASE = 9200
PROTOCOL_VOTE_ICON_OBJECT_BASE = 9300
PROTOCOL_LOBBY_ICON_OBJECT_BASE = 9400
PROTOCOL_ROLE_ICON_OBJECT_BASE = 9500
PROTOCOL_RESULT_ICON_OBJECT_BASE = 9600
PROTOCOL_GAME_OVER_ICON_OBJECT_BASE = 9700

PLAYER_COLOR_NAMES = [
    "red",
    "orange",
    "yellow",
    "light blue",
    "pink",
    "lime",
    "blue",
    "pale blue",
    "gray",
    "white",
    "dark brown",
    "brown",
    "dark teal",
    "green",
    "dark navy",
    "black",
]
PLAYER_COLORS = np.array([3, 7, 8, 14, 4, 11, 13, 15, 1, 2, 5, 6, 9, 10, 12, 0], dtype=np.uint8)


@dataclass
class Player2SpriteInfo:
    width: int
    height: int
    label: str
    kind: str
    color_index: int = -1
    flip_h: bool = False
    pixels: np.ndarray | None = None


@dataclass
class Player2ObjectInfo:
    x: int
    y: int
    z: int
    layer: int
    sprite_id: int


def read_u16(data: bytes, offset: int) -> int:
    return data[offset] | (data[offset + 1] << 8)


def read_i16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<h", data, offset)[0]


def read_u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def pack_player2_input_packet(mask: int) -> bytes:
    if not 0 <= mask <= 0x7F:
        raise ValueError(f"BitWorld /player2 input mask must be in [0, 127], got {mask}")
    return bytes([PACKET_PLAYER2_INPUT, mask])


def unpack_player2_input_packet(packet: bytes | bytearray | memoryview) -> int:
    raw = bytes(packet)
    if len(raw) != PLAYER2_INPUT_PACKET_BYTES or raw[0] != PACKET_PLAYER2_INPUT:
        raise ValueError(
            "BitWorld /player2 input packets must be two bytes: packet kind 0x84 followed by a button mask"
        )
    return raw[1] & 0x7F


def pack_player2_chat_packet(text: str) -> bytes:
    clean_text = text.strip()
    if not clean_text:
        raise ValueError("BitWorld /player2 chat packets require non-empty text")
    if any(ord(ch) < 0x20 or ord(ch) >= 0x7F for ch in clean_text):
        raise ValueError("BitWorld /player2 chat text must be printable ASCII")
    payload = clean_text.encode("ascii")
    if len(payload) > 0xFFFF:
        raise ValueError("BitWorld /player2 chat text is too long")
    return bytes([PACKET_PLAYER2_CHAT]) + len(payload).to_bytes(2, "little") + payload


def snappy_decompress(data: bytes) -> bytes:
    index = 0
    expected = 0
    shift = 0
    while True:
        if index >= len(data):
            raise ValueError("truncated snappy length")
        byte = data[index]
        index += 1
        expected |= (byte & 0x7F) << shift
        if byte < 128:
            break
        shift += 7

    output = bytearray()
    while index < len(data):
        tag = data[index]
        index += 1
        tag_type = tag & 0x03
        if tag_type == 0:
            length_code = tag >> 2
            if length_code < 60:
                length = length_code + 1
            else:
                extra = length_code - 59
                if index + extra > len(data):
                    raise ValueError("truncated snappy literal length")
                length = int.from_bytes(data[index : index + extra], "little") + 1
                index += extra
            if index + length > len(data):
                raise ValueError("truncated snappy literal")
            output.extend(data[index : index + length])
            index += length
            continue

        if tag_type == 1:
            if index >= len(data):
                raise ValueError("truncated snappy copy1")
            length = ((tag >> 2) & 0x07) + 4
            offset = ((tag & 0xE0) << 3) | data[index]
            index += 1
        elif tag_type == 2:
            if index + 2 > len(data):
                raise ValueError("truncated snappy copy2")
            length = (tag >> 2) + 1
            offset = read_u16(data, index)
            index += 2
        else:
            if index + 4 > len(data):
                raise ValueError("truncated snappy copy4")
            length = (tag >> 2) + 1
            offset = read_u32(data, index)
            index += 4

        if offset <= 0 or offset > len(output):
            raise ValueError("invalid snappy copy offset")
        for _ in range(length):
            output.append(output[-offset])

    if len(output) != expected:
        raise ValueError(f"snappy length mismatch: expected {expected}, got {len(output)}")
    return bytes(output)


def png_rgba_pixels(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"not a PNG: {path}")
    offset = 8
    width = height = color_type = bit_depth = None
    compressed = bytearray()
    while offset + 8 <= len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk[:10])[:4]
        elif chunk_type == b"IDAT":
            compressed.extend(chunk)
        elif chunk_type == b"IEND":
            break
    if width is None or height is None or bit_depth != 8 or color_type not in {2, 6}:
        raise ValueError(f"unsupported PNG format: {path}")

    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(bytes(compressed))
    previous = bytearray(stride)
    rows: list[bytes] = []
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        row = bytearray(raw[cursor : cursor + stride])
        cursor += stride
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            up = previous[i]
            up_left = previous[i - channels] if i >= channels else 0
            if filter_type == 1:
                row[i] = (row[i] + left) & 0xFF
            elif filter_type == 2:
                row[i] = (row[i] + up) & 0xFF
            elif filter_type == 3:
                row[i] = (row[i] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                p = left + up - up_left
                pa = abs(p - left)
                pb = abs(p - up)
                pc = abs(p - up_left)
                predictor = left if pa <= pb and pa <= pc else up if pb <= pc else up_left
                row[i] = (row[i] + predictor) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"unsupported PNG filter {filter_type}")
        previous = row
        if channels == 4:
            rows.append(bytes(row))
        else:
            rgba = bytearray(width * 4)
            for x in range(width):
                rgba[x * 4 : x * 4 + 3] = row[x * 3 : x * 3 + 3]
                rgba[x * 4 + 3] = 255
            rows.append(bytes(rgba))
    return width, height, b"".join(rows)


def load_palette_lookup() -> dict[tuple[int, int, int, int], int]:
    width, _height, pixels = png_rgba_pixels(REPO_ROOT / "clients" / "data" / "pallete.png")
    count = min(16, width)
    return {tuple(pixels[index * 4 : index * 4 + 4]): index for index in range(count)}


def color_index_from_name(name: str) -> int:
    lowered = name.lower().strip()
    try:
        return PLAYER_COLOR_NAMES.index(lowered)
    except ValueError:
        return -1


def actor_color_name(label: str, prefix: str) -> str:
    value = label[len(prefix) :].lower().strip()
    for suffix in (" right", " left"):
        if value.endswith(suffix):
            value = value[: -len(suffix)].strip()
    return value


def classify_player2_sprite(label: str) -> tuple[str, int, bool]:
    lowered = label.lower()
    if lowered == "map":
        return "map", -1, False
    if lowered == "task bubble":
        return "task", -1, False
    if lowered == "task arrow":
        return "arrow", -1, False
    if lowered == "imposter icon":
        return "imposter", -1, False
    if lowered == "imposter icon cooldown":
        return "imposter_cooldown", -1, False
    if lowered == "ghost icon":
        return "ghost_icon", -1, False
    if lowered == "player screen":
        return "screen", -1, False
    if lowered.startswith("task counter "):
        return "counter", -1, False
    if lowered.startswith("progress bar "):
        return "progress", -1, False
    if lowered.startswith("body "):
        return "body", color_index_from_name(lowered[len("body ") :]), False
    flip_h = lowered.endswith(" left")
    if lowered.startswith("selected player "):
        return "player", color_index_from_name(actor_color_name(lowered, "selected player ")), flip_h
    if lowered.startswith("selected ghost "):
        return "ghost", color_index_from_name(actor_color_name(lowered, "selected ghost ")), flip_h
    if lowered.startswith("player "):
        return "player", color_index_from_name(actor_color_name(lowered, "player ")), flip_h
    if lowered.startswith("ghost "):
        return "ghost", color_index_from_name(actor_color_name(lowered, "ghost ")), flip_h
    if label:
        return "text", -1, False
    return "unknown", -1, False


class Player2ObservationAdapter:
    def __init__(self) -> None:
        self.sprites: dict[int, Player2SpriteInfo] = {}
        self.objects: dict[int, Player2ObjectInfo] = {}
        self.palette_lookup = load_palette_lookup()
        self.frame_count = 0

    def _sprite_pixels(self, kind: str, width: int, height: int, compressed: bytes) -> np.ndarray | None:
        if kind != "map":
            return None
        raw = snappy_decompress(compressed)
        if len(raw) != width * height * 4:
            return None
        indices = np.full((height, width), MAP_VOID_COLOR, dtype=np.uint8)
        for i in range(width * height):
            rgba = tuple(raw[i * 4 : i * 4 + 4])
            indices.flat[i] = self.palette_lookup.get(rgba, 0)
        return indices

    def apply_packet(self, packet: bytes) -> bool:
        offset = 0
        changed = False
        while offset < len(packet):
            message_type = packet[offset]
            offset += 1
            if message_type == 0x01:
                if offset + 10 > len(packet):
                    return changed
                sprite_id = read_u16(packet, offset)
                width = read_u16(packet, offset + 2)
                height = read_u16(packet, offset + 4)
                compressed_len = read_u32(packet, offset + 6)
                offset += 10
                if offset + compressed_len + 2 > len(packet):
                    return changed
                compressed = packet[offset : offset + compressed_len]
                offset += compressed_len
                label_len = read_u16(packet, offset)
                offset += 2
                if offset + label_len > len(packet):
                    return changed
                label = packet[offset : offset + label_len].decode("utf-8", errors="replace")
                offset += label_len
                kind, color_index, flip_h = classify_player2_sprite(label)
                self.sprites[sprite_id] = Player2SpriteInfo(
                    width=width,
                    height=height,
                    label=label,
                    kind=kind,
                    color_index=color_index,
                    flip_h=flip_h,
                    pixels=self._sprite_pixels(kind, width, height, compressed),
                )
                changed = True
            elif message_type == 0x02:
                if offset + 11 > len(packet):
                    return changed
                object_id = read_u16(packet, offset)
                self.objects[object_id] = Player2ObjectInfo(
                    x=read_i16(packet, offset + 2),
                    y=read_i16(packet, offset + 4),
                    z=read_i16(packet, offset + 6),
                    layer=packet[offset + 8],
                    sprite_id=read_u16(packet, offset + 9),
                )
                offset += 11
                changed = True
            elif message_type == 0x03:
                if offset + 2 > len(packet):
                    return changed
                self.objects.pop(read_u16(packet, offset), None)
                offset += 2
                changed = True
            elif message_type == 0x04:
                self.objects.clear()
                changed = True
            elif message_type == 0x05:
                offset += 5
            elif message_type == 0x06:
                offset += 3
            else:
                return changed
        if changed:
            self.frame_count += 1
        return changed

    def _sprite(self, obj: Player2ObjectInfo) -> Player2SpriteInfo | None:
        return self.sprites.get(obj.sprite_id)

    def _phase(self) -> int:
        labels = " ".join(
            sprite.label
            for obj in self.objects.values()
            if (sprite := self._sprite(obj)) is not None and sprite.kind in {"screen", "text"}
        ).upper()
        if any((self._sprite(obj) is not None and self._sprite(obj).kind == "map") for obj in self.objects.values()):
            return AMONG_THEM_PHASE_PLAYING
        if "SKIP" in labels:
            return AMONG_THEM_PHASE_VOTING
        if "WAS KILLED" in labels or "NO ONE" in labels or "DIED" in labels:
            return AMONG_THEM_PHASE_VOTE_RESULT
        if "CREW WINS" in labels or "IMPS WIN" in labels or "DRAW" in labels:
            return AMONG_THEM_PHASE_GAME_OVER
        if "CREWMATE" in labels or "IMPS" in labels:
            return AMONG_THEM_PHASE_ROLE_REVEAL
        return AMONG_THEM_PHASE_LOBBY

    def _camera(self) -> tuple[int, int] | None:
        for obj in self.objects.values():
            sprite = self._sprite(obj)
            if sprite is not None and sprite.kind == "map":
                return -obj.x, -obj.y
        return None

    def _map_pixels(self) -> np.ndarray | None:
        for sprite in self.sprites.values():
            if sprite.kind == "map":
                return sprite.pixels
        return None

    def _counter_value(self) -> int:
        for obj in self.objects.values():
            sprite = self._sprite(obj)
            if sprite is None or sprite.kind != "counter":
                continue
            try:
                return int(sprite.label.rsplit(" ", 1)[-1])
            except ValueError:
                return 0
        return 0

    def _kill_icon(self) -> int:
        value = 0
        for obj in self.objects.values():
            sprite = self._sprite(obj)
            if sprite is None:
                continue
            if sprite.kind == "imposter":
                value = 255
            elif sprite.kind == "imposter_cooldown":
                value = max(value, 1)
        return value

    def _progress_byte(self) -> int:
        for obj in self.objects.values():
            sprite = self._sprite(obj)
            if sprite is None or sprite.kind != "progress":
                continue
            parts = sprite.label.split()
            if not parts:
                continue
            try:
                percent = int(parts[-1].rstrip("%"))
            except ValueError:
                continue
            filled = max(0, min(TASK_BAR_WIDTH, percent * TASK_BAR_WIDTH // 100))
            return filled * 255 // TASK_BAR_WIDTH
        return 0

    def observation(self) -> np.ndarray:
        obs = np.zeros((PLAYER2_FEATURES,), dtype=np.uint8)
        phase = self._phase()
        obs[0] = phase
        camera = self._camera()
        kill_icon = self._kill_icon()
        progress_byte = self._progress_byte()
        if phase == AMONG_THEM_PHASE_PLAYING and camera is not None:
            camera_x, camera_y = camera
            obs[PLAYER2_KILL_ICON_INDEX] = kill_icon
            obs[PLAYER2_TASK_PROGRESS_INDEX] = progress_byte
            obs[PLAYER2_TASKS_REMAINING_INDEX] = self._counter_value()
            map_pixels = self._map_pixels()
            if map_pixels is not None:
                height, width = map_pixels.shape
                step = SCREEN_WIDTH // PLAYER2_GRID_SIZE
                grid_start = PLAYER2_HEADER_FEATURES
                for gy in range(PLAYER2_GRID_SIZE):
                    for gx in range(PLAYER2_GRID_SIZE):
                        mx = camera_x + gx * step + step // 2
                        my = camera_y + gy * step + step // 2
                        value = MAP_VOID_COLOR
                        if 0 <= mx < width and 0 <= my < height:
                            value = int(map_pixels[my, mx])
                        obs[grid_start + gy * PLAYER2_GRID_SIZE + gx] = value

        for object_id, obj in self.objects.items():
            sprite = self._sprite(obj)
            if sprite is None:
                continue
            vote_slot = self._vote_player_slot(object_id)
            is_dead_vote_candidate = vote_slot is not None and sprite.kind == "body"
            if sprite.kind not in {"player", "ghost"} and not is_dead_vote_candidate:
                continue
            slot = vote_slot if vote_slot is not None else self._player_slot(object_id)
            if slot is None:
                continue
            sx = obj.x + 1
            sy = obj.y + 1
            flags = PLAYER2_FLAG_PLAYER_PRESENT
            if sprite.kind == "player":
                flags |= PLAYER2_FLAG_PLAYER_ALIVE
            elif sprite.kind == "ghost":
                flags |= PLAYER2_FLAG_PLAYER_GHOST
            if sprite.flip_h:
                flags |= PLAYER2_FLAG_PLAYER_FLIP_H
            base = PLAYER2_PLAYER_FEATURE_OFFSET + slot * PLAYER2_PLAYER_FEATURES
            obs[base] = np.uint8(max(0, min(255, sx)))
            obs[base + 1] = np.uint8(max(0, min(255, sy)))
            if 0 <= sprite.color_index < len(PLAYER_COLORS):
                obs[base + 2] = PLAYER_COLORS[sprite.color_index]
            obs[base + 3] = flags

        body_slot = 0
        for object_id, obj in sorted(self.objects.items()):
            if self._vote_player_slot(object_id) is not None:
                continue
            sprite = self._sprite(obj)
            if sprite is None or sprite.kind != "body" or body_slot >= AMONG_THEM_MAX_PLAYERS:
                continue
            base = PLAYER2_BODY_FEATURE_OFFSET + body_slot * PLAYER2_BODY_FEATURES
            obs[base] = np.uint8(max(0, min(255, obj.x + 1)))
            obs[base + 1] = np.uint8(max(0, min(255, obj.y + 1)))
            if 0 <= sprite.color_index < len(PLAYER_COLORS):
                obs[base + 2] = PLAYER_COLORS[sprite.color_index]
            obs[base + 3] = 1
            body_slot += 1

        task_slot = 0
        task_objects = [
            (object_id, obj, self._sprite(obj))
            for object_id, obj in self.objects.items()
            if self._sprite(obj) is not None and self._sprite(obj).kind in {"task", "arrow"}
        ]
        for _object_id, obj, sprite in sorted(task_objects):
            if sprite is None or task_slot >= PLAYER2_TASK_COUNT:
                continue
            base = PLAYER2_TASK_FEATURE_OFFSET + task_slot * PLAYER2_TASK_FEATURES
            flags = 0
            if sprite.kind == "task":
                flags |= PLAYER2_FLAG_TASK_ICON_VISIBLE
                obs[base] = np.uint8(max(0, min(255, obj.x)))
                obs[base + 1] = np.uint8(max(0, min(255, obj.y)))
            else:
                flags |= PLAYER2_FLAG_TASK_ARROW_VISIBLE
                obs[base + 2] = np.uint8(max(0, min(255, obj.x)))
                obs[base + 3] = np.uint8(max(0, min(255, obj.y)))
            obs[base + 4] = flags
            task_slot += 1
        return obs

    @staticmethod
    def _vote_player_slot(object_id: int) -> int | None:
        slot = object_id - PROTOCOL_VOTE_ICON_OBJECT_BASE
        if 0 <= slot < AMONG_THEM_MAX_PLAYERS:
            return slot
        return None

    def _player_slot(self, object_id: int) -> int | None:
        bases = (
            PLAYER_OBJECT_BASE,
            PROTOCOL_VOTE_ICON_OBJECT_BASE,
            PROTOCOL_LOBBY_ICON_OBJECT_BASE,
            PROTOCOL_ROLE_ICON_OBJECT_BASE,
            PROTOCOL_GAME_OVER_ICON_OBJECT_BASE,
        )
        for base in bases:
            slot = object_id - base
            if 0 <= slot < AMONG_THEM_MAX_PLAYERS:
                return slot
        if object_id == PROTOCOL_RESULT_ICON_OBJECT_BASE:
            return 0
        if PROTOCOL_CHAT_ICON_OBJECT_BASE <= object_id < PROTOCOL_CHAT_ICON_OBJECT_BASE + AMONG_THEM_MAX_PLAYERS:
            return object_id - PROTOCOL_CHAT_ICON_OBJECT_BASE
        return None


__all__ = [
    "AMONG_THEM_MAX_PLAYERS",
    "PACKET_PLAYER2_CHAT",
    "PACKET_PLAYER2_INPUT",
    "PLAYER2_FEATURES",
    "PLAYER2_FLAG_PLAYER_ALIVE",
    "PLAYER2_FLAG_PLAYER_FLIP_H",
    "PLAYER2_FLAG_PLAYER_GHOST",
    "PLAYER2_FLAG_PLAYER_PRESENT",
    "PLAYER2_FLAG_PLAYER_ROLE_IMPOSTER",
    "PLAYER2_FLAG_TASK_ARROW_VISIBLE",
    "PLAYER2_FLAG_TASK_ICON_VISIBLE",
    "PLAYER2_GRID_SIZE",
    "PLAYER2_HEADER_FEATURES",
    "PLAYER2_INPUT_PACKET_BYTES",
    "PLAYER2_PATH",
    "PLAYER2_PLAYER_FEATURE_OFFSET",
    "PLAYER2_PLAYER_FEATURES",
    "PLAYER2_BODY_FEATURE_OFFSET",
    "PLAYER2_BODY_FEATURES",
    "PLAYER2_TASK_COUNT",
    "PLAYER2_TASK_FEATURE_OFFSET",
    "PLAYER2_TASK_FEATURES",
    "PLAYER2_TASK_PROGRESS_INDEX",
    "Player2ObservationAdapter",
    "classify_player2_sprite",
    "pack_player2_chat_packet",
    "pack_player2_input_packet",
    "snappy_decompress",
    "unpack_player2_input_packet",
]

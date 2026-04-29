"""Minimal pure-Python Aseprite file reader.

Ported from the Nim aseprite.nim in bitworld/src/bitworld/ — only reads
what's needed to extract per-layer RGBA images from the first frame.
Supports indexed, grayscale, and RGBA color depths with zlib-compressed cels.
"""

from __future__ import annotations
import struct
import zlib
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

HEADER_MAGIC = 0xA5E0
FRAME_MAGIC = 0xF1FA
CHUNK_OLD_PALETTE_SHORT = 0x0004
CHUNK_OLD_PALETTE_LONG = 0x0011
CHUNK_LAYER = 0x2004
CHUNK_CEL = 0x2005
CHUNK_PALETTE = 0x2019
HEADER_BYTES = 128
FRAME_HEADER_BYTES = 16

DEPTH_INDEXED = 8
DEPTH_GRAYSCALE = 16
DEPTH_RGBA = 32

CEL_RAW = 0
CEL_LINKED = 1
CEL_COMPRESSED = 2
CEL_TILEMAP = 3

LAYER_NORMAL = 0
LAYER_GROUP = 1


@dataclass
class AseHeader:
  file_size: int = 0
  frame_count: int = 0
  width: int = 0
  height: int = 0
  color_depth: int = 0
  flags: int = 0
  speed: int = 0
  transparent_index: int = 0
  color_count: int = 256


@dataclass
class AseLayer:
  flags: int = 0
  kind: int = 0
  blend_mode: int = 0
  opacity: int = 255
  name: str = ''


@dataclass
class AseCel:
  layer_index: int = 0
  x: int = 0
  y: int = 0
  opacity: int = 255
  kind: int = 0
  z_index: int = 0
  width: int = 0
  height: int = 0
  linked_frame: int = 0
  data: bytes = b''


@dataclass
class AseFrame:
  duration: int = 0
  cels: list[AseCel] = field(default_factory=list)


@dataclass
class AseSprite:
  header: AseHeader = field(default_factory=AseHeader)
  layers: list[AseLayer] = field(default_factory=list)
  frames: list[AseFrame] = field(default_factory=list)
  palette: list[tuple[int, int, int, int]] = field(default_factory=list)


class _Reader:
  """Binary little-endian reader with bounds checking."""

  __slots__ = ('buf', 'pos')

  def __init__(self, buf: bytes):
    self.buf = buf
    self.pos = 0

  def _ensure(self, n: int):
    if self.pos + n > len(self.buf):
      raise ValueError('unexpected end of aseprite data')

  def u8(self) -> int:
    self._ensure(1)
    v = self.buf[self.pos]
    self.pos += 1
    return v

  def u16(self) -> int:
    self._ensure(2)
    v = struct.unpack_from('<H', self.buf, self.pos)[0]
    self.pos += 2
    return v

  def i16(self) -> int:
    self._ensure(2)
    v = struct.unpack_from('<h', self.buf, self.pos)[0]
    self.pos += 2
    return v

  def u32(self) -> int:
    self._ensure(4)
    v = struct.unpack_from('<I', self.buf, self.pos)[0]
    self.pos += 4
    return v

  def string(self) -> str:
    n = self.u16()
    self._ensure(n)
    s = self.buf[self.pos:self.pos + n].decode('utf-8', errors='replace')
    self.pos += n
    return s

  def skip(self, n: int):
    self.pos += n

  def seek(self, target: int):
    self.pos = target

  def read_bytes(self, n: int) -> bytes:
    self._ensure(n)
    data = self.buf[self.pos:self.pos + n]
    self.pos += n
    return data


def _bytes_per_pixel(depth: int) -> int:
  if depth == DEPTH_INDEXED:
    return 1
  if depth == DEPTH_GRAYSCALE:
    return 2
  return 4


def _parse_header(r: _Reader) -> AseHeader:
  start = r.pos
  h = AseHeader()
  h.file_size = r.u32()
  magic = r.u16()
  if magic != HEADER_MAGIC:
    raise ValueError(f'bad aseprite magic: 0x{magic:04X}')
  h.frame_count = r.u16()
  h.width = r.u16()
  h.height = r.u16()
  h.color_depth = r.u16()
  h.flags = r.u32()
  h.speed = r.u16()
  r.skip(8)  # 2x dword reserved
  h.transparent_index = r.u8()
  r.skip(3)
  h.color_count = r.u16()
  if h.color_count == 0:
    h.color_count = 256
  r.seek(start + HEADER_BYTES)
  return h


def _parse_layer(r: _Reader, chunk_end: int, header: AseHeader) -> AseLayer:
  lay = AseLayer()
  lay.flags = r.u16()
  lay.kind = r.u16()
  r.u16()  # child level
  r.u16()  # default width
  r.u16()  # default height
  lay.blend_mode = r.u16()
  lay.opacity = r.u8()
  r.skip(3)
  lay.name = r.string()
  r.seek(chunk_end)
  return lay


def _parse_cel(r: _Reader, chunk_end: int, header: AseHeader) -> AseCel:
  cel = AseCel()
  cel.layer_index = r.u16()
  cel.x = r.i16()
  cel.y = r.i16()
  cel.opacity = r.u8()
  cel.kind = r.u16()
  cel.z_index = r.i16()
  r.skip(5)

  if cel.kind == CEL_RAW:
    cel.width = r.u16()
    cel.height = r.u16()
    n = cel.width * cel.height * _bytes_per_pixel(header.color_depth)
    cel.data = r.read_bytes(n)

  elif cel.kind == CEL_LINKED:
    cel.linked_frame = r.u16()

  elif cel.kind == CEL_COMPRESSED:
    cel.width = r.u16()
    cel.height = r.u16()
    compressed = r.buf[r.pos:chunk_end]
    cel.data = zlib.decompress(compressed)
    expected = cel.width * cel.height * _bytes_per_pixel(header.color_depth)
    if len(cel.data) != expected:
      raise ValueError(f'compressed cel size mismatch: {len(cel.data)} vs {expected}')

  elif cel.kind == CEL_TILEMAP:
    cel.width = r.u16()
    cel.height = r.u16()
    cel.data = b''

  r.seek(chunk_end)
  return cel


def _parse_old_palette(r: _Reader, sprite: AseSprite, chunk_end: int, scale63: bool):
  idx = 0
  packets = r.u16()
  for _ in range(packets):
    idx += r.u8()
    count = r.u8()
    if count == 0:
      count = 256
    for j in range(count):
      rv = r.u8()
      gv = r.u8()
      bv = r.u8()
      if scale63:
        rv = rv * 255 // 63
        gv = gv * 255 // 63
        bv = bv * 255 // 63
      while len(sprite.palette) <= idx + j:
        sprite.palette.append((0, 0, 0, 0))
      sprite.palette[idx + j] = (rv, gv, bv, 255)
    idx += count
  r.seek(chunk_end)


def _parse_palette(r: _Reader, sprite: AseSprite, chunk_end: int):
  size = r.u32()
  first = r.u32()
  last = r.u32()
  r.skip(8)
  while len(sprite.palette) < size:
    sprite.palette.append((0, 0, 0, 0))
  for index in range(first, last + 1):
    flags = r.u16()
    rv = r.u8()
    gv = r.u8()
    bv = r.u8()
    av = r.u8()
    if index < len(sprite.palette):
      sprite.palette[index] = (rv, gv, bv, av)
    if flags & 1:
      r.string()
  r.seek(chunk_end)


def read_aseprite(path: str | Path) -> AseSprite:
  """Read and decode an Aseprite file, returning an AseSprite."""
  data = Path(path).read_bytes()
  r = _Reader(data)
  sprite = AseSprite()
  sprite.header = _parse_header(r)
  sprite.palette = [(0, 0, 0, 0)] * 256

  has_new_palette = False
  for fi in range(sprite.header.frame_count):
    frame_start = r.pos
    frame_bytes = r.u32()
    frame_end = frame_start + frame_bytes
    magic = r.u16()
    if magic != FRAME_MAGIC:
      raise ValueError(f'bad frame magic: 0x{magic:04X}')
    old_chunks = r.u16()
    duration = r.u16()
    r.skip(2)
    new_chunks = r.u32()
    chunk_count = new_chunks if new_chunks != 0 else old_chunks

    frame = AseFrame(duration=duration)

    for _ in range(chunk_count):
      chunk_start = r.pos
      chunk_size = r.u32()
      chunk_type = r.u16()
      chunk_end = chunk_start + chunk_size

      if chunk_type == CHUNK_LAYER:
        sprite.layers.append(_parse_layer(r, chunk_end, sprite.header))
      elif chunk_type == CHUNK_CEL:
        frame.cels.append(_parse_cel(r, chunk_end, sprite.header))
      elif chunk_type == CHUNK_OLD_PALETTE_SHORT and not has_new_palette:
        _parse_old_palette(r, sprite, chunk_end, False)
      elif chunk_type == CHUNK_OLD_PALETTE_LONG and not has_new_palette:
        _parse_old_palette(r, sprite, chunk_end, True)
      elif chunk_type == CHUNK_PALETTE:
        has_new_palette = True
        _parse_palette(r, sprite, chunk_end)
      else:
        r.seek(chunk_end)

    sprite.frames.append(frame)
    r.seek(frame_end)

  return sprite


def render_layer(sprite: AseSprite, layer_index: int, frame_index: int = 0) -> np.ndarray:
  """Render a single layer from one frame as an (H, W, 4) RGBA uint8 array.

  Uses vectorized numpy operations for speed when possible.
  """
  h = sprite.header
  img = np.zeros((h.height, h.width, 4), dtype=np.uint8)

  if frame_index >= len(sprite.frames):
    return img
  frame = sprite.frames[frame_index]

  for cel in frame.cels:
    if cel.layer_index != layer_index:
      continue
    if cel.kind not in (CEL_RAW, CEL_COMPRESSED):
      continue
    if not cel.data:
      continue

    bpp = _bytes_per_pixel(h.color_depth)
    cel_data = np.frombuffer(cel.data, dtype=np.uint8)

    if h.color_depth == DEPTH_RGBA:
      pixels = cel_data.reshape(cel.height, cel.width, 4)
      y0, x0 = max(0, cel.y), max(0, cel.x)
      y1 = min(h.height, cel.y + cel.height)
      x1 = min(h.width, cel.x + cel.width)
      sy0 = y0 - cel.y
      sx0 = x0 - cel.x
      sy1 = sy0 + (y1 - y0)
      sx1 = sx0 + (x1 - x0)
      src = pixels[sy0:sy1, sx0:sx1]
      mask = src[:, :, 3] > 0
      dst_slice = img[y0:y1, x0:x1]
      dst_slice[mask] = src[mask]

    elif h.color_depth == DEPTH_INDEXED:
      pal_arr = np.array(sprite.palette, dtype=np.uint8)
      indices = cel_data.reshape(cel.height, cel.width)
      is_bg = (layer_index < len(sprite.layers) and
               (sprite.layers[layer_index].flags & 8) != 0)

      y0, x0 = max(0, cel.y), max(0, cel.x)
      y1 = min(h.height, cel.y + cel.height)
      x1 = min(h.width, cel.x + cel.width)
      sy0, sx0 = y0 - cel.y, x0 - cel.x
      sy1, sx1 = sy0 + (y1 - y0), sx0 + (x1 - x0)
      idx_slice = indices[sy0:sy1, sx0:sx1]

      valid = np.ones(idx_slice.shape, dtype=bool)
      if not is_bg:
        valid &= (idx_slice != h.transparent_index)
      valid &= (idx_slice < len(pal_arr))
      rgba_pixels = pal_arr[idx_slice]
      rgba_pixels[~valid] = [0, 0, 0, 0]
      alpha_mask = rgba_pixels[:, :, 3] > 0
      dst_slice = img[y0:y1, x0:x1]
      dst_slice[alpha_mask] = rgba_pixels[alpha_mask]

    elif h.color_depth == DEPTH_GRAYSCALE:
      pixels = cel_data.reshape(cel.height, cel.width, 2)
      y0, x0 = max(0, cel.y), max(0, cel.x)
      y1 = min(h.height, cel.y + cel.height)
      x1 = min(h.width, cel.x + cel.width)
      sy0, sx0 = y0 - cel.y, x0 - cel.x
      sy1, sx1 = sy0 + (y1 - y0), sx0 + (x1 - x0)
      src = pixels[sy0:sy1, sx0:sx1]
      rgba = np.zeros((*src.shape[:2], 4), dtype=np.uint8)
      rgba[:, :, 0] = src[:, :, 0]
      rgba[:, :, 1] = src[:, :, 0]
      rgba[:, :, 2] = src[:, :, 0]
      rgba[:, :, 3] = src[:, :, 1]
      mask = rgba[:, :, 3] > 0
      img[y0:y1, x0:x1][mask] = rgba[mask]

  return img

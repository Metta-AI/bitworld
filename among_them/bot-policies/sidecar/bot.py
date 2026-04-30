"""Among Them visual bot — full Python port of nottoodumb.nim.

Connects via WebSocket, receives 128x128 packed 4-bit framebuffers,
performs localization, sprite scanning, task management, pathfinding,
and sends input masks. Optionally integrates with the LLM brain.
"""

from __future__ import annotations

import argparse
import asyncio
import heapq
import logging
import os
import random
import struct
import time
from dataclasses import dataclass, field
from enum import IntEnum, Enum
from pathlib import Path
from typing import Optional

import numpy as np

try:
  from PIL import Image as PILImage
except ImportError:
  PILImage = None

try:
  import websockets
except ImportError:
  websockets = None

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Protocol constants (from common/protocol.nim)
# ---------------------------------------------------------------------------
SCREEN_WIDTH = 128
SCREEN_HEIGHT = 128
PROTOCOL_BYTES = (SCREEN_WIDTH * SCREEN_HEIGHT) // 2
PACKET_INPUT = 0
PACKET_CHAT = 1
INPUT_PACKET_BYTES = 2

BUTTON_UP = 1
BUTTON_DOWN = 2
BUTTON_LEFT = 4
BUTTON_RIGHT = 8
BUTTON_SELECT = 16
BUTTON_A = 32
BUTTON_B = 64

# ---------------------------------------------------------------------------
# Sim constants (from among_them/sim.nim)
# ---------------------------------------------------------------------------
MAP_WIDTH = 952
MAP_HEIGHT = 534
SPRITE_SIZE = 12
COLLISION_W = 1
COLLISION_H = 1
SPRITE_DRAW_OFF_X = 2
SPRITE_DRAW_OFF_Y = 8
FRICTION_NUM = 144
FRICTION_DEN = 256
SPACE_COLOR = 0
MAP_VOID_COLOR = 12
TINT_COLOR = 3
SHADE_TINT_COLOR = 9
TRANSPARENT_COLOR_INDEX = 255
KILL_RANGE = 20
REPORT_RANGE = 20
TASK_COMPLETE_TICKS = 72
MAX_PLAYERS = 16

BUTTON_X = 524
BUTTON_Y = 114
BUTTON_W = 28
BUTTON_H = 34

PLAYER_COLORS = [3, 7, 8, 14, 4, 11, 13, 15, 1, 2, 5, 6, 9, 10, 12, 0]
PLAYER_COLOR_NAMES = [
  'red', 'orange', 'yellow', 'light blue', 'pink', 'lime',
  'blue', 'pale blue', 'gray', 'white', 'dark brown', 'brown',
  'dark teal', 'green', 'dark navy', 'black',
]
PLAYER_COLOR_COUNT = len(PLAYER_COLORS)

SHADOW_MAP = [0, 12, 9, 5, 5, 0, 5, 5, 5, 12, 9, 9, 0, 12, 12, 9]

# ---------------------------------------------------------------------------
# Bot-specific constants (from nottoodumb.nim)
# ---------------------------------------------------------------------------
PLAYER_SCREEN_X = SCREEN_WIDTH // 2
PLAYER_SCREEN_Y = SCREEN_HEIGHT // 2
PLAYER_WORLD_OFF_X = SPRITE_DRAW_OFF_X + PLAYER_SCREEN_X - SPRITE_SIZE // 2
PLAYER_WORLD_OFF_Y = SPRITE_DRAW_OFF_Y + PLAYER_SCREEN_Y - SPRITE_SIZE // 2

FULL_FRAME_FIT_MAX_ERRORS = 420
LOCAL_FRAME_FIT_MAX_ERRORS = 320
FRAME_FIT_MIN_COMPARED = 12000
LOCAL_FRAME_SEARCH_RADIUS = 8
PLAYER_IGNORE_RADIUS = 9
INTERSTITIAL_BLACK_PERCENT = 30
HOME_SEARCH_RADIUS = 20

RADAR_TASK_COLOR = 8
RADAR_PERIPHERY_MARGIN = 1
RADAR_MATCH_TOLERANCE = 2

TASK_ICON_SEARCH_RADIUS = 2
TASK_ICON_EXPECTED_SEARCH_RADIUS = 3
TASK_ICON_MAX_MISSES = 4
TASK_ICON_MAYBE_MISSES = 12
TASK_ICON_INSPECT_SIZE = 16
TASK_CLEAR_SCREEN_MARGIN = 8
TASK_ICON_MISS_THRESHOLD = 24
TASK_INNER_MARGIN = 6
TASK_PRECISE_APPROACH_RADIUS = 12
TASK_HOLD_PADDING = 8

PATH_LOOKAHEAD = 18
COAST_LOOKAHEAD_TICKS = 8
COAST_ARRIVAL_PADDING = 1
STEER_DEADBAND = 2
BRAKE_DEADBAND = 1
STUCK_FRAME_THRESHOLD = 8
JIGGLE_DURATION = 16

CREWMATE_SEARCH_RADIUS = 1
CREWMATE_MAX_MISSES = 8
CREWMATE_MIN_STABLE_PIXELS = 8
CREWMATE_MIN_BODY_PIXELS = 8

KILL_ICON_X = 1
KILL_ICON_Y = SCREEN_HEIGHT - SPRITE_SIZE - 1
KILL_ICON_MAX_MISSES = 5
GHOST_ICON_MAX_MISSES = 3
GHOST_ICON_FRAME_THRESHOLD = 2
KILL_APPROACH_RADIUS = 3

BODY_SEARCH_RADIUS = 1
BODY_MAX_MISSES = 9
BODY_MIN_STABLE_PIXELS = 6
BODY_MIN_TINT_PIXELS = 6

GHOST_SEARCH_RADIUS = 1
GHOST_MAX_MISSES = 9
GHOST_MIN_STABLE_PIXELS = 6
GHOST_MIN_TINT_PIXELS = 6

VOTE_CELL_W = 16
VOTE_CELL_H = 17
VOTE_START_Y = 2
VOTE_SKIP_W = 28
VOTE_UNKNOWN = -1
VOTE_SKIP = -2
VOTE_BLACK_MARKER = 12
VOTE_LISTEN_TICKS = 100
VOTE_CHAT_TEXT_X = 21
VOTE_CHAT_CHARS = 15

FRAME_DROP_THRESHOLD = 32
MAX_FRAME_DRAIN = 128

INT_MIN = -(2**31)

# ---------------------------------------------------------------------------
# Camera bounds
# ---------------------------------------------------------------------------
def min_camera_x():
  return -SCREEN_WIDTH // 2 - SPRITE_SIZE

def max_camera_x():
  return MAP_WIDTH - SCREEN_WIDTH // 2 + SPRITE_SIZE

def min_camera_y():
  return -SCREEN_HEIGHT // 2 - SPRITE_SIZE

def max_camera_y():
  return MAP_HEIGHT - SCREEN_HEIGHT // 2 + SPRITE_SIZE

def button_camera_x():
  return max(min_camera_x(), min(BUTTON_X + BUTTON_W // 2 - PLAYER_WORLD_OFF_X, max_camera_x()))

def button_camera_y():
  return max(min_camera_y(), min(BUTTON_Y + BUTTON_H // 2 - PLAYER_WORLD_OFF_Y, max_camera_y()))

def camera_x_for_world(x):
  return max(min_camera_x(), min(x - PLAYER_WORLD_OFF_X, max_camera_x()))

def camera_y_for_world(y):
  return max(min_camera_y(), min(y - PLAYER_WORLD_OFF_Y, max_camera_y()))

def in_map(x, y):
  return 0 <= x < MAP_WIDTH and 0 <= y < MAP_HEIGHT

def camera_can_hold_player(cx, cy):
  return in_map(cx + PLAYER_WORLD_OFF_X, cy + PLAYER_WORLD_OFF_Y)


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------
class CameraLock(IntEnum):
  NO_LOCK = 0
  LOCAL_FRAME = 1
  FRAME_MAP = 2

class TaskState(IntEnum):
  NOT_DOING = 0
  MAYBE = 1
  MANDATORY = 2
  COMPLETED = 3

class BotRole(IntEnum):
  UNKNOWN = 0
  CREWMATE = 1
  IMPOSTER = 2


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------
@dataclass
class Room:
  name: str
  x: int
  y: int
  w: int
  h: int

@dataclass
class TaskStation:
  name: str
  x: int
  y: int
  w: int
  h: int

@dataclass
class PathStep:
  found: bool = False
  x: int = 0
  y: int = 0

@dataclass
class CameraScore:
  score: int = -(2**31)
  errors: int = 2**31
  compared: int = 0

@dataclass
class RadarDot:
  x: int = 0
  y: int = 0

@dataclass
class IconMatch:
  x: int = 0
  y: int = 0

@dataclass
class CrewmateMatch:
  x: int = 0
  y: int = 0
  color_index: int = -1
  flip_h: bool = False

@dataclass
class BodyMatch:
  x: int = 0
  y: int = 0

@dataclass
class GhostMatch:
  x: int = 0
  y: int = 0
  flip_h: bool = False

@dataclass
class VoteSlot:
  color_index: int = VOTE_UNKNOWN
  alive: bool = False

@dataclass
class Sprite:
  width: int = 0
  height: int = 0
  pixels: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.uint8))

  def pixel_at(self, x, y):
    return int(self.pixels[y * self.width + x])


# ---------------------------------------------------------------------------
# Room / Task data (hardcoded from sim.nim)
# ---------------------------------------------------------------------------
ROOMS = [
  Room('Upper Engine', 159, 62, 100, 112),
  Room('Reactor', 73, 184, 100, 112),
  Room('Reactor Hallway', 173, 174, 82, 136),
  Room('Electrical Hallway', 294, 409, 158, 38),
  Room('Electrical Hallway Bend', 259, 347, 88, 62),
  Room('Security', 255, 174, 73, 116),
  Room('Lower Engine', 159, 310, 100, 112),
  Room('Electrical', 347, 273, 105, 136),
  Room('Coms', 577, 411, 115, 82),
  Room('Coms Hallway', 577, 349, 118, 60),
  Room('Storage', 452, 318, 125, 175),
  Room('Admin Hallway', 452, 230, 141, 88),
  Room('Shields', 695, 344, 97, 96),
  Room('Nav Hallway', 717, 199, 90, 84),
  Room('Shields Hallway', 717, 283, 62, 61),
  Room('Admin', 593, 254, 102, 95),
  Room('Nav', 807, 180, 134, 103),
  Room('O2', 634, 199, 83, 45),
  Room('Weapons', 673, 47, 119, 152),
  Room('West Cafeteria', 428, 58, 32, 142),
  Room('Cafeteria', 460, 58, 152, 141),
  Room('North Cafeteria', 428, 0, 228, 58),
  Room('South Cafeteria', 452, 199, 182, 31),
  Room('East Cafeteria', 612, 58, 61, 141),
  Room('MedBay', 328, 140, 100, 117),
  Room('MedBay', 428, 210, 24, 47),
  Room('MedBay Hallway', 259, 85, 169, 55),
]

TASKS = [
  TaskStation('Empty Garbage', 554, 465, 16, 16),
  TaskStation('Upload Data From Communications', 667, 419, 16, 16),
  TaskStation('Fix Wires', 574, 269, 16, 16),
  TaskStation('Fix Wires', 444, 31, 16, 16),
  TaskStation('Fix Wires', 510, 322, 16, 16),
  TaskStation('Fix Wires', 392, 296, 16, 16),
  TaskStation('Fix Wires', 838, 222, 16, 16),
  TaskStation('Download Data', 352, 293, 16, 16),
  TaskStation('Calibrate Distributor', 428, 295, 16, 16),
  TaskStation('Submit Scan', 400, 234, 16, 16),
  TaskStation('Divert Power', 372, 293, 16, 16),
  TaskStation('Divert Power', 760, 95, 16, 16),
  TaskStation('Divert Power', 868, 196, 16, 16),
  TaskStation('Divert Power', 186, 328, 16, 16),
  TaskStation('Divert Power', 202, 82, 16, 16),
  TaskStation('Divert Power', 297, 206, 16, 16),
  TaskStation('Divert Power', 146, 209, 16, 16),
  TaskStation('Start Reactor', 123, 244, 16, 16),
  TaskStation('Unlock Manifolds', 107, 186, 16, 16),
  TaskStation('Divert Power', 764, 349, 16, 16),
  TaskStation('Prime Shields', 703, 419, 16, 16),
  TaskStation('Divert Power', 715, 196, 16, 16),
  TaskStation('Clear Asteroids', 731, 95, 16, 16),
  TaskStation('Inspect Sample', 416, 222, 16, 16),
  TaskStation('Upload Data', 597, 267, 16, 16),
  TaskStation('Align Engine Output', 162, 398, 16, 16),
  TaskStation('Align Engine Output', 162, 156, 16, 16),
  TaskStation('Swipe Card', 670, 306, 16, 16),
  TaskStation('Download Data', 612, 39, 16, 16),
  TaskStation('Chart Course', 896, 225, 16, 16),
  TaskStation('Stabilize Steering', 888, 250, 16, 16),
  TaskStation('Download Data', 888, 196, 16, 16),
  TaskStation('Download Data', 626, 432, 16, 16),
  TaskStation('Fuel Engines', 486, 419, 16, 16),
  TaskStation('Fuel Engines', 186, 393, 16, 16),
  TaskStation('Fuel Engines', 186, 151, 16, 16),
  TaskStation('Clean O2 Filter', 667, 197, 16, 16),
  TaskStation('Download Data', 723, 63, 16, 16),
  TaskStation('Empty Garbage', 630, 60, 16, 16),
  TaskStation('Empty Garbage', 651, 212, 16, 16),
]


def room_name_at(x, y):
  for room in ROOMS:
    if room.x <= x < room.x + room.w and room.y <= y < room.y + room.h:
      return room.name
  return 'unknown'

def task_center(task):
  return (task.x + task.w // 2, task.y + task.h // 2)

def heuristic(ax, ay, bx, by):
  return abs(ax - bx) + abs(ay - by)


# ---------------------------------------------------------------------------
# Protocol helpers
# ---------------------------------------------------------------------------
def unpack_4bpp(packed: bytes) -> np.ndarray:
  arr = np.frombuffer(packed, dtype=np.uint8)
  low = arr & 0x0F
  high = (arr >> 4) & 0x0F
  return np.column_stack((low, high)).ravel().astype(np.uint8)

def blob_from_mask(mask: int) -> bytes:
  return bytes([PACKET_INPUT, mask & 0xFF])

def blob_from_chat(text: str) -> bytes:
  return bytes([PACKET_CHAT]) + text.encode('ascii', errors='replace')


# ---------------------------------------------------------------------------
# Asset loading
# ---------------------------------------------------------------------------
def _game_dir() -> Path:
  return Path(__file__).resolve().parent.parent.parent

def _find_palette_path() -> Optional[Path]:
  gd = _game_dir()
  candidates = [
    gd.parent / 'clients' / 'data' / 'pallete.png',
    gd / 'pallete.png',
  ]
  for c in candidates:
    if c.exists():
      return c
  return None

def _find_spritesheet_path() -> Optional[Path]:
  gd = _game_dir()
  candidates = [
    gd / 'spritesheet.png',
    gd.parent / 'clients' / 'dist' / 'atlas.png',
  ]
  for c in candidates:
    if c.exists():
      return c
  return None

def _find_skeld2_path() -> Optional[Path]:
  gd = _game_dir()
  candidates = [
    gd / 'skeld2.aseprite',
  ]
  for c in candidates:
    if c.exists():
      return c
  return None


def _load_palette() -> Optional[np.ndarray]:
  path = _find_palette_path()
  if path is None or PILImage is None:
    return None
  img = PILImage.open(path).convert('RGBA')
  pal = np.zeros((16, 4), dtype=np.uint8)
  for i in range(min(16, img.width)):
    pal[i] = img.getpixel((i, 0))
  return pal


def nearest_palette_index(r, g, b, a, palette):
  r, g, b, a = int(r), int(g), int(b), int(a)
  if a < 20:
    return TRANSPARENT_COLOR_INDEX
  dr = palette[:, 0].astype(int) - r
  dg = palette[:, 1].astype(int) - g
  db = palette[:, 2].astype(int) - b
  da = palette[:, 3].astype(int) - a
  dist = dr * dr + dg * dg + db * db + da * da
  return int(np.argmin(dist))


def _load_sprite_from_sheet(sheet_pixels, palette, sheet_w, cell_x, cell_y, size=SPRITE_SIZE):
  sprite = Sprite(width=size, height=size, pixels=np.full(size * size, TRANSPARENT_COLOR_INDEX, dtype=np.uint8))
  bx = cell_x * size
  by = cell_y * size
  sh = sheet_pixels.shape[0]
  sw = sheet_pixels.shape[1] if len(sheet_pixels.shape) >= 2 else sheet_w
  for y in range(size):
    for x in range(size):
      px, py = bx + x, by + y
      if px >= sw or py >= sh:
        continue
      r = int(sheet_pixels[py, px, 0])
      g = int(sheet_pixels[py, px, 1])
      b_val = int(sheet_pixels[py, px, 2])
      a = int(sheet_pixels[py, px, 3])
      sprite.pixels[y * size + x] = nearest_palette_index(r, g, b_val, a, palette)
  return sprite


def _image_to_palette_indices(img_array, palette, width, height):
  flat = img_array[:height, :width].reshape(-1, 4).astype(np.int32)
  pal = palette.astype(np.int32)
  transparent_mask = flat[:, 3] < 20
  result = np.full(width * height, MAP_VOID_COLOR, dtype=np.uint8)
  non_trans = ~transparent_mask
  if non_trans.any():
    px = flat[non_trans]
    diff = px[:, np.newaxis, :] - pal[np.newaxis, :, :]
    dist = (diff * diff).sum(axis=2)
    result[non_trans] = np.argmin(dist, axis=1).astype(np.uint8)
  result[transparent_mask] = TRANSPARENT_COLOR_INDEX
  return result


class GameData:
  """Holds loaded map pixels, walk/wall masks, and sprites."""

  def __init__(self):
    self.map_pixels: Optional[np.ndarray] = None
    self.walk_mask: Optional[np.ndarray] = None
    self.wall_mask: Optional[np.ndarray] = None
    self.player_sprite = Sprite()
    self.body_sprite = Sprite()
    self.ghost_sprite = Sprite()
    self.task_sprite = Sprite()
    self.kill_button_sprite = Sprite()
    self.ghost_icon_sprite = Sprite()
    self.loaded = False

  def load(self):
    palette = _load_palette()
    if palette is None:
      logger.warning('Could not load palette — running in minimal mode')
      return

    sheet_path = _find_spritesheet_path()
    if sheet_path is not None and PILImage is not None:
      sheet_img = PILImage.open(sheet_path).convert('RGBA')
      sheet_arr = np.array(sheet_img)
      sw = sheet_img.width
      self.player_sprite = _load_sprite_from_sheet(sheet_arr, palette, sw, 0, 0)
      self.body_sprite = _load_sprite_from_sheet(sheet_arr, palette, sw, 1, 0)
      self.kill_button_sprite = _load_sprite_from_sheet(sheet_arr, palette, sw, 3, 0)
      self.task_sprite = _load_sprite_from_sheet(sheet_arr, palette, sw, 4, 0)
      self.ghost_sprite = _load_sprite_from_sheet(sheet_arr, palette, sw, 6, 0)
      self.ghost_icon_sprite = _load_sprite_from_sheet(sheet_arr, palette, sw, 7, 0)
      logger.info('Loaded sprites from %s', sheet_path)

    skeld_path = _find_skeld2_path()
    if skeld_path is not None:
      try:
        from .aseprite_reader import read_aseprite, render_layer
        sprite = read_aseprite(skeld_path)
        map_arr = render_layer(sprite, 0)
        walk_arr = render_layer(sprite, 1)
        wall_arr = render_layer(sprite, 2)

        self.map_pixels = _image_to_palette_indices(map_arr, palette, MAP_WIDTH, MAP_HEIGHT)
        self.walk_mask = (walk_arr[:, :, 3].ravel() > 0)
        self.wall_mask = (wall_arr[:, :, 3].ravel() > 0)
        logger.info('Loaded map data from %s (%dx%d, %d walkable pixels)',
                     skeld_path, sprite.header.width, sprite.header.height,
                     int(self.walk_mask.sum()))
      except Exception as e:
        logger.warning('Failed to load skeld2 map: %s', e)

    self.loaded = self.map_pixels is not None
    if not self.loaded:
      logger.warning('Map data not loaded — localization will not work')


# Singleton game data, loaded once
_game_data: Optional[GameData] = None

def get_game_data() -> GameData:
  global _game_data
  if _game_data is None:
    _game_data = GameData()
    _game_data.load()
  return _game_data


# ---------------------------------------------------------------------------
# Sprite matching helpers
# ---------------------------------------------------------------------------
def stable_crewmate_color(color):
  return color != TRANSPARENT_COLOR_INDEX and color != TINT_COLOR and color != SHADE_TINT_COLOR

def player_body_color(color):
  for pc in PLAYER_COLORS:
    if color == pc or color == SHADOW_MAP[pc & 0x0F]:
      return True
  return False

def player_color_index(color):
  for i, pc in enumerate(PLAYER_COLORS):
    if color == pc:
      return i
  return -1

def crewmate_pixel_matches(sprite_color, frame_color):
  if sprite_color == TINT_COLOR or sprite_color == SHADE_TINT_COLOR:
    return player_body_color(frame_color)
  return frame_color == sprite_color

def has_movement(mask):
  return (mask & (BUTTON_UP | BUTTON_DOWN | BUTTON_LEFT | BUTTON_RIGHT)) != 0


# ---------------------------------------------------------------------------
# Bot class
# ---------------------------------------------------------------------------
class Bot:
  """Full visual bot — perception, navigation, task management, imposter AI, voting."""

  def __init__(self, brain=None, name='bot'):
    self.name = name
    self.brain = brain
    gd = get_game_data()
    self.gd = gd

    self.role = BotRole.CREWMATE
    self.is_ghost = False
    self.ghost_icon_frames = 0
    self.imposter_kill_ready = False
    self.imposter_goal_index = -1

    self.unpacked = np.zeros(SCREEN_WIDTH * SCREEN_HEIGHT, dtype=np.uint8)

    self.camera_x = button_camera_x()
    self.camera_y = button_camera_y()
    self.last_camera_x = self.camera_x
    self.last_camera_y = self.camera_y
    self.camera_lock = CameraLock.NO_LOCK
    self.camera_score = 0
    self.localized = False

    self.interstitial = False
    self.interstitial_text = ''
    self.last_game_over_text = ''
    self.game_started = False

    self.home_set = False
    self.home_x = 0
    self.home_y = 0

    self.have_motion_sample = False
    self.previous_player_world_x = 0
    self.previous_player_world_y = 0
    self.velocity_x = 0
    self.velocity_y = 0
    self.stuck_frames = 0
    self.jiggle_ticks = 0
    self.jiggle_side = 0

    self.desired_mask = 0
    self.controller_mask = 0
    self.task_hold_ticks = 0
    self.task_hold_index = -1

    self.frame_tick = 0
    self.last_mask = 0
    self.last_thought = ''
    self.pending_chat = ''
    self.intent = 'waiting for first frame'

    self.last_body_seen_x = INT_MIN
    self.last_body_seen_y = INT_MIN
    self.last_body_report_x = INT_MIN
    self.last_body_report_y = INT_MIN

    self.last_seen_ticks = [0] * PLAYER_COLOR_COUNT
    self.self_color_index = -1
    self.known_imposters = [False] * PLAYER_COLOR_COUNT

    self.voting = False
    self.vote_player_count = 0
    self.vote_cursor = VOTE_UNKNOWN
    self.vote_self_slot = VOTE_UNKNOWN
    self.vote_target = VOTE_UNKNOWN
    self.vote_start_tick = -1
    self.vote_chat_sus_color = VOTE_UNKNOWN
    self.vote_chat_text = ''
    self.vote_slots = [VoteSlot() for _ in range(MAX_PLAYERS)]
    self.vote_choices = [VOTE_UNKNOWN] * PLAYER_COLOR_COUNT

    self.goal_x = 0
    self.goal_y = 0
    self.goal_index = -1
    self.goal_name = ''
    self.has_goal = False
    self.has_path_step = False
    self.path_step = PathStep()
    self.path: list[PathStep] = []

    self.radar_dots: list[RadarDot] = []
    n_tasks = len(TASKS)
    self.radar_tasks = [False] * n_tasks
    self.checkout_tasks = [False] * n_tasks
    self.task_states = [TaskState.NOT_DOING] * n_tasks
    self.task_icon_misses = [0] * n_tasks

    self.visible_task_icons: list[IconMatch] = []
    self.visible_crewmates: list[CrewmateMatch] = []
    self.visible_bodies: list[BodyMatch] = []
    self.visible_ghosts: list[GhostMatch] = []

    self.rng = random.Random(int(time.time() * 1000) ^ os.getpid())

  # -----------------------------------------------------------------------
  # Derived positions
  # -----------------------------------------------------------------------
  def player_world_x(self):
    return self.camera_x + PLAYER_WORLD_OFF_X

  def player_world_y(self):
    return self.camera_y + PLAYER_WORLD_OFF_Y

  def room_name(self):
    if not self.localized:
      return 'unknown'
    px = self.player_world_x() + COLLISION_W // 2
    py = self.player_world_y() + COLLISION_H // 2
    return room_name_at(px, py)

  # -----------------------------------------------------------------------
  # Ignore-pixel helpers (for localization)
  # -----------------------------------------------------------------------
  def _ignore_sprite_pixel(self, sx, sy, items, sprite, use_flip=False):
    for item in items:
      ix = sx - item.x
      iy = sy - item.y
      if ix < 0 or iy < 0 or ix >= sprite.width or iy >= sprite.height:
        continue
      src_x = (sprite.width - 1 - ix) if (use_flip and hasattr(item, 'flip_h') and item.flip_h) else ix
      if sprite.pixels[iy * sprite.width + src_x] != TRANSPARENT_COLOR_INDEX:
        return True
    return False

  def _ignore_kill_icon_pixel(self, sx, sy):
    if self.role != BotRole.IMPOSTER:
      return False
    ix, iy = sx - KILL_ICON_X, sy - KILL_ICON_Y
    sp = self.gd.kill_button_sprite
    if ix < 0 or iy < 0 or ix >= sp.width or iy >= sp.height:
      return False
    return sp.pixels[iy * sp.width + ix] != TRANSPARENT_COLOR_INDEX

  def _ignore_ghost_icon_pixel(self, sx, sy):
    if not self.is_ghost and self.ghost_icon_frames == 0:
      return False
    sp = self.gd.ghost_icon_sprite
    ix, iy = sx - KILL_ICON_X, sy - KILL_ICON_Y
    if ix < 0 or iy < 0 or ix >= sp.width or iy >= sp.height:
      return False
    return sp.pixels[iy * sp.width + ix] != TRANSPARENT_COLOR_INDEX

  def ignore_frame_pixel(self, frame_color, sx, sy):
    if frame_color == RADAR_TASK_COLOR:
      return True
    if self._ignore_kill_icon_pixel(sx, sy):
      return True
    if self._ignore_ghost_icon_pixel(sx, sy):
      return True
    if self._ignore_sprite_pixel(sx, sy, self.visible_bodies, self.gd.body_sprite):
      return True
    if self._ignore_sprite_pixel(sx, sy, self.visible_ghosts, self.gd.ghost_sprite, use_flip=True):
      return True
    if self._ignore_sprite_pixel(sx, sy, self.visible_task_icons, self.gd.task_sprite):
      return True
    if self._ignore_sprite_pixel(sx, sy, self.visible_crewmates, self.gd.player_sprite, use_flip=True):
      return True
    if abs(sx - PLAYER_SCREEN_X) <= PLAYER_IGNORE_RADIUS and abs(sy - PLAYER_SCREEN_Y) <= PLAYER_IGNORE_RADIUS:
      return True
    return False

  # -----------------------------------------------------------------------
  # Camera scoring
  # -----------------------------------------------------------------------
  def score_camera(self, cx, cy, max_errors):
    if self.gd.map_pixels is None:
      return CameraScore()
    result = CameraScore(score=0, errors=0, compared=0)
    unpacked = self.unpacked
    mp = self.gd.map_pixels
    for sy in range(SCREEN_HEIGHT):
      for sx in range(SCREEN_WIDTH):
        fc = int(unpacked[sy * SCREEN_WIDTH + sx])
        if self.ignore_frame_pixel(fc, sx, sy):
          continue
        mx, my = cx + sx, cy + sy
        mc = int(mp[my * MAP_WIDTH + mx]) if in_map(mx, my) else MAP_VOID_COLOR
        result.compared += 1
        if fc == mc or SHADOW_MAP[mc & 0x0F] == fc:
          pass
        else:
          result.errors += 1
          if result.errors > max_errors:
            result.score = -result.errors
            return result
    result.score = result.compared - result.errors * SCREEN_WIDTH
    return result

  def _accept_camera_score(self, score, max_errors):
    return score.errors <= max_errors and score.compared >= FRAME_FIT_MIN_COMPARED

  def _set_camera_lock(self, x, y, score, lock):
    self.camera_x = x
    self.camera_y = y
    self.camera_score = score.score
    self.camera_lock = lock
    self.localized = True

  # -----------------------------------------------------------------------
  # Localization
  # -----------------------------------------------------------------------
  def locate_near_frame(self):
    if not self.localized:
      return False
    best = CameraScore()
    best_x, best_y = self.camera_x, self.camera_y
    lo_x = max(min_camera_x(), self.camera_x - LOCAL_FRAME_SEARCH_RADIUS)
    hi_x = min(max_camera_x(), self.camera_x + LOCAL_FRAME_SEARCH_RADIUS)
    lo_y = max(min_camera_y(), self.camera_y - LOCAL_FRAME_SEARCH_RADIUS)
    hi_y = min(max_camera_y(), self.camera_y + LOCAL_FRAME_SEARCH_RADIUS)
    for y in range(lo_y, hi_y + 1):
      for x in range(lo_x, hi_x + 1):
        sc = self.score_camera(x, y, LOCAL_FRAME_FIT_MAX_ERRORS)
        if sc.errors < best.errors or (sc.errors == best.errors and sc.compared > best.compared):
          best = sc
          best_x, best_y = x, y
          if best.errors == 0 and best.compared >= FRAME_FIT_MIN_COMPARED:
            break
      if best.errors == 0 and best.compared >= FRAME_FIT_MIN_COMPARED:
        break
    if not self._accept_camera_score(best, LOCAL_FRAME_FIT_MAX_ERRORS):
      return False
    self._set_camera_lock(best_x, best_y, best, CameraLock.LOCAL_FRAME)
    return True

  def locate_by_frame(self):
    """Spiral search from seed outward."""
    best = CameraScore()
    seed_x = self.camera_x if self.game_started else button_camera_x()
    seed_y = self.camera_y if self.game_started else button_camera_y()
    lo_x, hi_x = min_camera_x(), max_camera_x()
    lo_y, hi_y = min_camera_y(), max_camera_y()
    seed_x = max(lo_x, min(seed_x, hi_x))
    seed_y = max(lo_y, min(seed_y, hi_y))
    best_x, best_y = seed_x, seed_y
    max_r = max(max(abs(seed_x - lo_x), abs(seed_x - hi_x)),
                max(abs(seed_y - lo_y), abs(seed_y - hi_y)))

    def try_cam(x, y):
      nonlocal best, best_x, best_y
      if x < lo_x or x > hi_x or y < lo_y or y > hi_y:
        return False
      if not camera_can_hold_player(x, y):
        return False
      sc = self.score_camera(x, y, FULL_FRAME_FIT_MAX_ERRORS)
      if sc.errors < best.errors or (sc.errors == best.errors and sc.compared > best.compared):
        best = sc
        best_x, best_y = x, y
        return best.errors == 0 and best.compared >= FRAME_FIT_MIN_COMPARED
      return False

    done = try_cam(seed_x, seed_y)
    for r in range(1, max_r + 1):
      if done:
        break
      for dx in range(-r, r + 1):
        if try_cam(seed_x + dx, seed_y - r):
          done = True; break
        if try_cam(seed_x + dx, seed_y + r):
          done = True; break
      if done:
        break
      for dy in range(-r + 1, r):
        if try_cam(seed_x - r, seed_y + dy):
          done = True; break
        if try_cam(seed_x + r, seed_y + dy):
          done = True; break
      if done:
        break

    if not self._accept_camera_score(best, FULL_FRAME_FIT_MAX_ERRORS):
      self.camera_lock = CameraLock.NO_LOCK
      self.camera_score = best.score
      self.localized = False
      return False
    self._set_camera_lock(best_x, best_y, best, CameraLock.FRAME_MAP)
    return True

  # -----------------------------------------------------------------------
  # Interstitial detection
  # -----------------------------------------------------------------------
  def is_interstitial_screen(self):
    black = int(np.sum(self.unpacked == SPACE_COLOR))
    return black * 100 >= len(self.unpacked) * INTERSTITIAL_BLACK_PERCENT

  def detect_interstitial_text(self):
    # Simplified: just count black pixels, real text OCR needs ascii sprites
    # For now return empty; brain integration will handle interstitial state
    return ''

  def is_game_over_text(self, text):
    return text in ('CREW WINS', 'IMPS WIN')

  # -----------------------------------------------------------------------
  # Sprite scanning
  # -----------------------------------------------------------------------
  def _sprite_misses(self, sprite, x, y, flip_h=False):
    misses, opaque = 0, 0
    for sy in range(sprite.height):
      for sx in range(sprite.width):
        src_x = (sprite.width - 1 - sx) if flip_h else sx
        color = int(sprite.pixels[sy * sprite.width + src_x])
        if color == TRANSPARENT_COLOR_INDEX:
          continue
        opaque += 1
        fx, fy = x + sx, y + sy
        if fx < 0 or fy < 0 or fx >= SCREEN_WIDTH or fy >= SCREEN_HEIGHT:
          misses += 1
        elif int(self.unpacked[fy * SCREEN_WIDTH + fx]) != color:
          misses += 1
      if misses > KILL_ICON_MAX_MISSES * 2:
        break
    return misses, opaque

  def _matches_sprite(self, sprite, x, y):
    m, o = self._sprite_misses(sprite, x, y)
    return o > 0 and m <= TASK_ICON_MAX_MISSES

  def _matches_sprite_shadowed(self, sprite, x, y):
    misses, opaque = 0, 0
    for sy in range(sprite.height):
      for sx in range(sprite.width):
        color = int(sprite.pixels[sy * sprite.width + sx])
        if color == TRANSPARENT_COLOR_INDEX:
          continue
        opaque += 1
        fx, fy = x + sx, y + sy
        if fx < 0 or fy < 0 or fx >= SCREEN_WIDTH or fy >= SCREEN_HEIGHT:
          misses += 1
        elif int(self.unpacked[fy * SCREEN_WIDTH + fx]) != SHADOW_MAP[color & 0x0F]:
          misses += 1
        if misses > KILL_ICON_MAX_MISSES:
          return False
    return opaque > 0 and misses <= KILL_ICON_MAX_MISSES

  def _matches_crewmate(self, x, y, flip_h):
    sp = self.gd.player_sprite
    if sp.width == 0:
      return False
    body_matched, body_pixels, matched_stable, misses, stable_pixels = 0, 0, 0, 0, 0
    for sy in range(sp.height):
      for sx in range(sp.width):
        src_x = (sp.width - 1 - sx) if flip_h else sx
        color = int(sp.pixels[sy * sp.width + src_x])
        if color == TRANSPARENT_COLOR_INDEX:
          continue
        if stable_crewmate_color(color):
          stable_pixels += 1
        else:
          body_pixels += 1
        fx, fy = x + sx, y + sy
        if fx < 0 or fy < 0 or fx >= SCREEN_WIDTH or fy >= SCREEN_HEIGHT:
          misses += 1
        elif crewmate_pixel_matches(color, int(self.unpacked[fy * SCREEN_WIDTH + fx])):
          if stable_crewmate_color(color):
            matched_stable += 1
          else:
            body_matched += 1
        else:
          misses += 1
        if misses > CREWMATE_MAX_MISSES:
          return False
    return (stable_pixels >= CREWMATE_MIN_STABLE_PIXELS and
            matched_stable >= CREWMATE_MIN_STABLE_PIXELS and
            body_pixels >= CREWMATE_MIN_BODY_PIXELS and
            body_matched >= CREWMATE_MIN_BODY_PIXELS)

  def _crewmate_color_index(self, x, y, flip_h):
    sp = self.gd.player_sprite
    counts = [0] * PLAYER_COLOR_COUNT
    for sy in range(sp.height):
      for sx in range(sp.width):
        src_x = (sp.width - 1 - sx) if flip_h else sx
        color = int(sp.pixels[sy * sp.width + src_x])
        if color != TINT_COLOR:
          continue
        fx, fy = x + sx, y + sy
        if fx < 0 or fy < 0 or fx >= SCREEN_WIDTH or fy >= SCREEN_HEIGHT:
          continue
        idx = player_color_index(int(self.unpacked[fy * SCREEN_WIDTH + fx]))
        if idx >= 0:
          counts[idx] += 1
    best_count, result = 0, -1
    for i, c in enumerate(counts):
      if c > best_count:
        best_count = c
        result = i
    return result

  def _matches_actor_sprite(self, sprite, x, y, flip_h, max_misses, min_stable, min_tint):
    if sprite.width == 0:
      return False
    tint_matched, tint_pixels, stable_matched, misses, stable_pixels = 0, 0, 0, 0, 0
    for sy in range(sprite.height):
      for sx in range(sprite.width):
        src_x = (sprite.width - 1 - sx) if flip_h else sx
        color = int(sprite.pixels[sy * sprite.width + src_x])
        if color == TRANSPARENT_COLOR_INDEX:
          continue
        if stable_crewmate_color(color):
          stable_pixels += 1
        else:
          tint_pixels += 1
        fx, fy = x + sx, y + sy
        if fx < 0 or fy < 0 or fx >= SCREEN_WIDTH or fy >= SCREEN_HEIGHT:
          misses += 1
        elif crewmate_pixel_matches(color, int(self.unpacked[fy * SCREEN_WIDTH + fx])):
          if stable_crewmate_color(color):
            stable_matched += 1
          else:
            tint_matched += 1
        else:
          misses += 1
        if misses > max_misses:
          return False
    return (stable_pixels >= min_stable and stable_matched >= min_stable and
            tint_pixels >= min_tint and tint_matched >= min_tint)

  def scan_crewmates(self):
    self.visible_crewmates = []
    sp = self.gd.player_sprite
    if sp.width == 0:
      return
    for y in range(SCREEN_HEIGHT - sp.height + 1):
      for x in range(SCREEN_WIDTH - sp.width + 1):
        if (abs(x + SPRITE_SIZE // 2 - PLAYER_SCREEN_X) <= PLAYER_IGNORE_RADIUS and
            abs(y + SPRITE_SIZE // 2 - PLAYER_SCREEN_Y) <= PLAYER_IGNORE_RADIUS):
          continue
        for flip in (False, True):
          if self._matches_crewmate(x, y, flip):
            ci = self._crewmate_color_index(x, y, flip)
            self._add_crewmate_match(x, y, ci, flip)
            break
    for cm in self.visible_crewmates:
      if 0 <= cm.color_index < len(self.last_seen_ticks):
        self.last_seen_ticks[cm.color_index] = self.frame_tick

  def _add_crewmate_match(self, x, y, ci, flip):
    for i, m in enumerate(self.visible_crewmates):
      if abs(m.x - x) <= CREWMATE_SEARCH_RADIUS and abs(m.y - y) <= CREWMATE_SEARCH_RADIUS:
        if m.color_index < 0 and ci >= 0:
          self.visible_crewmates[i] = CrewmateMatch(m.x, m.y, ci, m.flip_h)
        return
    self.visible_crewmates.append(CrewmateMatch(x, y, ci, flip))

  def scan_bodies(self):
    self.visible_bodies = []
    sp = self.gd.body_sprite
    if sp.width == 0:
      return
    for y in range(SCREEN_HEIGHT - sp.height + 1):
      for x in range(SCREEN_WIDTH - sp.width + 1):
        if self._matches_actor_sprite(sp, x, y, False, BODY_MAX_MISSES, BODY_MIN_STABLE_PIXELS, BODY_MIN_TINT_PIXELS):
          self._add_body_match(x, y)

  def _add_body_match(self, x, y):
    for m in self.visible_bodies:
      if abs(m.x - x) <= BODY_SEARCH_RADIUS and abs(m.y - y) <= BODY_SEARCH_RADIUS:
        return
    self.visible_bodies.append(BodyMatch(x, y))

  def scan_ghosts(self):
    self.visible_ghosts = []
    sp = self.gd.ghost_sprite
    if sp.width == 0:
      return
    for y in range(SCREEN_HEIGHT - sp.height + 1):
      for x in range(SCREEN_WIDTH - sp.width + 1):
        for flip in (False, True):
          if self._matches_actor_sprite(sp, x, y, flip, GHOST_MAX_MISSES, GHOST_MIN_STABLE_PIXELS, GHOST_MIN_TINT_PIXELS):
            self._add_ghost_match(x, y, flip)
            break

  def _add_ghost_match(self, x, y, flip):
    for m in self.visible_ghosts:
      if abs(m.x - x) <= GHOST_SEARCH_RADIUS and abs(m.y - y) <= GHOST_SEARCH_RADIUS:
        return
    self.visible_ghosts.append(GhostMatch(x, y, flip))

  def scan_task_icons(self):
    self.visible_task_icons = []
    if not self.localized:
      return
    sp = self.gd.task_sprite
    if sp.width == 0:
      return
    for task in TASKS:
      base_x = task.x + task.w // 2 - SPRITE_SIZE // 2 - self.camera_x
      base_y = task.y - SPRITE_SIZE - 2 - self.camera_y
      for bob_y in range(-1, 2):
        ey = base_y + bob_y
        for dy in range(-TASK_ICON_EXPECTED_SEARCH_RADIUS, TASK_ICON_EXPECTED_SEARCH_RADIUS + 1):
          for dx in range(-TASK_ICON_EXPECTED_SEARCH_RADIUS, TASK_ICON_EXPECTED_SEARCH_RADIUS + 1):
            tx, ty = base_x + dx, ey + dy
            if self._matches_sprite(sp, tx, ty):
              self._add_icon_match(tx, ty)

  def _add_icon_match(self, x, y):
    for m in self.visible_task_icons:
      if abs(m.x - x) <= 1 and abs(m.y - y) <= 1:
        return
    self.visible_task_icons.append(IconMatch(x, y))

  def update_role(self):
    sp_ghost = self.gd.ghost_icon_sprite
    if sp_ghost.width > 0:
      m, o = self._sprite_misses(sp_ghost, KILL_ICON_X, KILL_ICON_Y)
      if o > 0 and m <= GHOST_ICON_MAX_MISSES:
        self.ghost_icon_frames += 1
        self.imposter_kill_ready = False
        if self.ghost_icon_frames >= GHOST_ICON_FRAME_THRESHOLD:
          self.is_ghost = True
          if self.role == BotRole.UNKNOWN:
            self.role = BotRole.CREWMATE
        return
      elif not self.is_ghost:
        self.ghost_icon_frames = 0

    sp_kill = self.gd.kill_button_sprite
    if sp_kill.width > 0:
      lit = self._matches_sprite(sp_kill, KILL_ICON_X, KILL_ICON_Y)
      shaded = self._matches_sprite_shadowed(sp_kill, KILL_ICON_X, KILL_ICON_Y)
      self.imposter_kill_ready = lit
      if lit or shaded:
        self.role = BotRole.IMPOSTER
      elif self.role == BotRole.UNKNOWN:
        self.role = BotRole.CREWMATE

  def update_self_color(self):
    sp = self.gd.player_sprite
    if sp.width == 0:
      return
    x = PLAYER_SCREEN_X - sp.width // 2
    y = PLAYER_SCREEN_Y - sp.height // 2
    ci = -1
    if self._matches_crewmate(x, y, False):
      ci = self._crewmate_color_index(x, y, False)
    elif self._matches_crewmate(x, y, True):
      ci = self._crewmate_color_index(x, y, True)
    if 0 <= ci < PLAYER_COLOR_COUNT:
      self.self_color_index = ci

  # -----------------------------------------------------------------------
  # Pathfinding (A* on walk mask)
  # -----------------------------------------------------------------------
  def passable(self, x, y):
    if self.gd.walk_mask is None:
      return True
    if x < 0 or y < 0 or x + COLLISION_W >= MAP_WIDTH or y + COLLISION_H >= MAP_HEIGHT:
      return False
    for dy in range(COLLISION_H):
      for dx in range(COLLISION_W):
        if not self.gd.walk_mask[(y + dy) * MAP_WIDTH + (x + dx)]:
          return False
    return True

  def find_path(self, goal_x, goal_y):
    sx, sy = self.player_world_x(), self.player_world_y()
    area = MAP_WIDTH * MAP_HEIGHT
    si = sy * MAP_WIDTH + sx
    gi = goal_y * MAP_WIDTH + goal_x
    if not self.passable(sx, sy) or not self.passable(goal_x, goal_y):
      return []
    parents = [-2] * area
    costs = [2**30] * area
    closed = bytearray(area)
    parents[si] = -1
    costs[si] = 0
    heap = [(heuristic(sx, sy, goal_x, goal_y), si)]
    while heap:
      _, ci = heapq.heappop(heap)
      if closed[ci]:
        continue
      if ci == gi:
        path = []
        step = gi
        while step != si and step >= 0:
          path.append(PathStep(True, step % MAP_WIDTH, step // MAP_WIDTH))
          step = parents[step]
        path.reverse()
        return path
      closed[ci] = 1
      cx, cy = ci % MAP_WIDTH, ci // MAP_WIDTH
      for ddx, ddy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        nx, ny = cx + ddx, cy + ddy
        if not self.passable(nx, ny):
          continue
        ni = ny * MAP_WIDTH + nx
        if closed[ni]:
          continue
        nc = costs[ci] + 1
        if nc >= costs[ni]:
          continue
        costs[ni] = nc
        parents[ni] = ci
        heapq.heappush(heap, (nc + heuristic(nx, ny, goal_x, goal_y), ni))
    return []

  def goal_distance(self, gx, gy):
    if self.is_ghost:
      return heuristic(self.player_world_x(), self.player_world_y(), gx, gy)
    p = self.find_path(gx, gy)
    return len(p) if p else 2**30

  # -----------------------------------------------------------------------
  # Steering helpers
  # -----------------------------------------------------------------------
  @staticmethod
  def _coast_distance(velocity):
    result, speed = 0, abs(velocity)
    for _ in range(COAST_LOOKAHEAD_TICKS):
      if speed <= 0:
        break
      result += speed
      speed = (speed * FRICTION_NUM) // FRICTION_DEN
    return result

  @staticmethod
  def _should_coast(delta, velocity):
    if delta > 0 and velocity > 0:
      return delta <= Bot._coast_distance(velocity) + COAST_ARRIVAL_PADDING
    if delta < 0 and velocity < 0:
      return -delta <= Bot._coast_distance(velocity) + COAST_ARRIVAL_PADDING
    return False

  @staticmethod
  def _axis_mask(delta, velocity, neg_mask, pos_mask):
    if delta > STEER_DEADBAND:
      if Bot._should_coast(delta, velocity):
        return 0
      if velocity > 1 and delta <= abs(velocity) + BRAKE_DEADBAND:
        return neg_mask
      return pos_mask
    if delta < -STEER_DEADBAND:
      if Bot._should_coast(delta, velocity):
        return 0
      if velocity < -1 and -delta <= abs(velocity) + BRAKE_DEADBAND:
        return pos_mask
      return neg_mask
    if velocity > 0:
      return neg_mask
    if velocity < 0:
      return pos_mask
    return 0

  @staticmethod
  def _precise_axis_mask(delta, velocity, neg_mask, pos_mask):
    if delta > 0:
      if Bot._should_coast(delta, velocity):
        return 0
      if velocity > 1 and delta <= abs(velocity) + BRAKE_DEADBAND:
        return neg_mask
      return pos_mask
    if delta < 0:
      if Bot._should_coast(delta, velocity):
        return 0
      if velocity < -1 and -delta <= abs(velocity) + BRAKE_DEADBAND:
        return pos_mask
      return neg_mask
    if velocity > 0:
      return neg_mask
    if velocity < 0:
      return pos_mask
    return 0

  def mask_for_waypoint(self, wp):
    if not wp.found:
      return 0
    dx = wp.x - self.player_world_x()
    dy = wp.y - self.player_world_y()
    m = self._axis_mask(dx, self.velocity_x, BUTTON_LEFT, BUTTON_RIGHT)
    m |= self._axis_mask(dy, self.velocity_y, BUTTON_UP, BUTTON_DOWN)
    return m

  def precise_mask_for_goal(self, gx, gy):
    dx = gx - self.player_world_x()
    dy = gy - self.player_world_y()
    m = self._precise_axis_mask(dx, self.velocity_x, BUTTON_LEFT, BUTTON_RIGHT)
    m |= self._precise_axis_mask(dy, self.velocity_y, BUTTON_UP, BUTTON_DOWN)
    return m

  def choose_path_step(self):
    if not self.path:
      return PathStep()
    idx = min(len(self.path) - 1, PATH_LOOKAHEAD)
    return self.path[idx]

  def apply_jiggle(self, mask):
    if self.jiggle_ticks <= 0 or not has_movement(mask):
      return mask
    self.jiggle_ticks -= 1
    vert = (mask & (BUTTON_UP | BUTTON_DOWN)) != 0
    horiz = (mask & (BUTTON_LEFT | BUTTON_RIGHT)) != 0
    if vert and not horiz:
      mask |= BUTTON_LEFT if self.jiggle_side == 0 else BUTTON_RIGHT
    elif horiz and not vert:
      mask |= BUTTON_UP if self.jiggle_side == 0 else BUTTON_DOWN
    elif self.jiggle_side == 0:
      mask |= BUTTON_LEFT
    else:
      mask |= BUTTON_RIGHT
    return mask

  # -----------------------------------------------------------------------
  # Motion tracking
  # -----------------------------------------------------------------------
  def update_motion_state(self):
    if not self.localized:
      self.have_motion_sample = False
      self.velocity_x = self.velocity_y = 0
      self.stuck_frames = self.jiggle_ticks = 0
      return
    x, y = self.player_world_x(), self.player_world_y()
    if self.have_motion_sample and has_movement(self.last_mask):
      self.velocity_x = x - self.previous_player_world_x
      self.velocity_y = y - self.previous_player_world_y
      moved = abs(self.velocity_x) + abs(self.velocity_y)
      if moved == 0:
        self.stuck_frames += 1
      else:
        self.stuck_frames = 0
      if self.stuck_frames >= STUCK_FRAME_THRESHOLD:
        self.stuck_frames = 0
        self.jiggle_ticks = JIGGLE_DURATION
        self.jiggle_side = 1 - self.jiggle_side
    else:
      self.velocity_x = self.velocity_y = 0
      self.stuck_frames = 0
    self.have_motion_sample = True
    self.previous_player_world_x = x
    self.previous_player_world_y = y

  # -----------------------------------------------------------------------
  # Task management
  # -----------------------------------------------------------------------
  def scan_radar_dots(self):
    self.radar_dots = []
    for y in range(SCREEN_HEIGHT):
      for x in range(SCREEN_WIDTH):
        if not (x <= RADAR_PERIPHERY_MARGIN or y <= RADAR_PERIPHERY_MARGIN or
                x >= SCREEN_WIDTH - 1 - RADAR_PERIPHERY_MARGIN or
                y >= SCREEN_HEIGHT - 1 - RADAR_PERIPHERY_MARGIN):
          continue
        if int(self.unpacked[y * SCREEN_WIDTH + x]) == RADAR_TASK_COLOR:
          dup = False
          for d in self.radar_dots:
            if abs(d.x - x) <= 1 and abs(d.y - y) <= 1:
              dup = True; break
          if not dup:
            self.radar_dots.append(RadarDot(x, y))

  def _projected_radar_dot(self, task):
    if not self.localized:
      return None
    icon_sx = task.x + task.w // 2 - SPRITE_SIZE // 2 - self.camera_x
    icon_sy = task.y - SPRITE_SIZE - 2 - self.camera_y
    icon_cx = icon_sx + SPRITE_SIZE // 2
    icon_cy = icon_sy + SPRITE_SIZE // 2
    if icon_sx + SPRITE_SIZE > 0 and icon_sy + SPRITE_SIZE > 0 and icon_sx < SCREEN_WIDTH and icon_sy < SCREEN_HEIGHT:
      return ('visible', icon_cx, icon_cy)
    px = float(self.player_world_x() + COLLISION_W // 2 - self.camera_x)
    py = float(self.player_world_y() + COLLISION_H // 2 - self.camera_y)
    dx = float(icon_cx) - px
    dy = float(icon_cy) - py
    if abs(dx) < 0.5 and abs(dy) < 0.5:
      return None
    if abs(dx) > abs(dy):
      ex = float(SCREEN_WIDTH - 1) if dx > 0 else 0.0
      ey = py + dy * (ex - px) / dx
      ey = max(0.0, min(float(SCREEN_HEIGHT - 1), ey))
    else:
      ey = float(SCREEN_HEIGHT - 1) if dy > 0 else 0.0
      ex = px + dx * (ey - py) / dy
      ex = max(0.0, min(float(SCREEN_WIDTH - 1), ex))
    return ('edge', int(ex), int(ey))

  def update_task_guesses(self):
    n = len(TASKS)
    for i in range(n):
      self.radar_tasks[i] = False
    if not self.localized:
      return
    self.scan_radar_dots()
    if not self.radar_dots:
      return
    for i, task in enumerate(TASKS):
      proj = self._projected_radar_dot(task)
      if proj is None or proj[0] == 'visible':
        continue
      _, ex, ey = proj
      for dot in self.radar_dots:
        if abs(dot.x - ex) <= RADAR_MATCH_TOLERANCE and abs(dot.y - ey) <= RADAR_MATCH_TOLERANCE:
          self.radar_tasks[i] = True
          self.checkout_tasks[i] = True
          if self.task_states[i] == TaskState.COMPLETED:
            self.task_states[i] = TaskState.MAYBE

  def _task_icon_visible_for(self, task):
    for bob_y in range(-1, 2):
      ix = task.x + task.w // 2 - SPRITE_SIZE // 2 - self.camera_x
      iy = task.y - SPRITE_SIZE - 2 + bob_y - self.camera_y
      if ix + SPRITE_SIZE < 0 or iy + SPRITE_SIZE < 0 or ix >= SCREEN_WIDTH or iy >= SCREEN_HEIGHT:
        continue
      for icon in self.visible_task_icons:
        if abs(icon.x - ix) <= TASK_ICON_SEARCH_RADIUS and abs(icon.y - iy) <= TASK_ICON_SEARCH_RADIUS:
          return True
    return False

  def _task_icon_clear_area_visible(self, task):
    rx = task.x + task.w // 2 - TASK_ICON_INSPECT_SIZE // 2 - self.camera_x
    ry = task.y - TASK_ICON_INSPECT_SIZE - self.camera_y
    return (rx >= TASK_CLEAR_SCREEN_MARGIN and ry >= TASK_CLEAR_SCREEN_MARGIN and
            rx + TASK_ICON_INSPECT_SIZE + TASK_CLEAR_SCREEN_MARGIN <= SCREEN_WIDTH and
            ry + TASK_ICON_INSPECT_SIZE + TASK_CLEAR_SCREEN_MARGIN <= SCREEN_HEIGHT)

  def update_task_icons(self):
    if not self.localized:
      return
    self.scan_task_icons()
    for i, task in enumerate(TASKS):
      if self._task_icon_visible_for(task):
        self.task_states[i] = TaskState.MANDATORY
        self.task_icon_misses[i] = 0
      elif (self.task_hold_ticks == 0 and self._task_icon_clear_area_visible(task) and
            not self.radar_tasks[i] and self.task_hold_index != i):
        if self.task_states[i] == TaskState.MANDATORY:
          self.task_icon_misses[i] += 1
          if self.task_icon_misses[i] >= TASK_ICON_MISS_THRESHOLD:
            self.task_states[i] = TaskState.COMPLETED
            self.checkout_tasks[i] = False
            self.task_icon_misses[i] = 0
        elif self.checkout_tasks[i]:
          self.task_icon_misses[i] += 1
          if self.task_icon_misses[i] >= TASK_ICON_MISS_THRESHOLD:
            self.checkout_tasks[i] = False
            self.task_icon_misses[i] = 0
      else:
        self.task_icon_misses[i] = 0

  # -----------------------------------------------------------------------
  # Goal selection
  # -----------------------------------------------------------------------
  def _task_goal_for(self, index, state):
    if index < 0 or index >= len(TASKS):
      return None
    task = TASKS[index]
    cx, cy = task_center(task)
    best_dist, best_x, best_y = 2**30, 0, 0
    for ry in range(max(task.y, task.y + TASK_INNER_MARGIN), min(task.y + task.h, task.y + task.h - TASK_INNER_MARGIN)):
      for rx in range(max(task.x, task.x + TASK_INNER_MARGIN), min(task.x + task.w, task.x + task.w - TASK_INNER_MARGIN)):
        if not self.passable(rx, ry):
          continue
        d = heuristic(cx, cy, rx, ry)
        if d < best_dist:
          best_dist, best_x, best_y = d, rx, ry
    if best_dist == 2**30:
      for ry in range(task.y, task.y + task.h):
        for rx in range(task.x, task.x + task.w):
          if not self.passable(rx, ry):
            continue
          d = heuristic(cx, cy, rx, ry)
          if d < best_dist:
            best_dist, best_x, best_y = d, rx, ry
    if best_dist == 2**30:
      return None
    return (index, best_x, best_y, task.name, state)

  def _button_goal(self):
    cx, cy = BUTTON_X + BUTTON_W // 2, BUTTON_Y + BUTTON_H // 2
    best_dist, best_x, best_y = 2**30, 0, 0
    for ry in range(BUTTON_Y, BUTTON_Y + BUTTON_H):
      for rx in range(BUTTON_X, BUTTON_X + BUTTON_W):
        if not self.passable(rx, ry):
          continue
        d = heuristic(cx, cy, rx, ry)
        if d < best_dist:
          best_dist, best_x, best_y = d, rx, ry
    if best_dist == 2**30:
      return None
    return (-1, best_x, best_y, 'Button', TaskState.MAYBE)

  def _home_goal(self):
    if not self.home_set:
      return self._button_goal()
    if self.is_ghost or self.passable(self.home_x, self.home_y):
      return (-1, self.home_x, self.home_y, 'Home', TaskState.MAYBE)
    best_dist, best_x, best_y = 2**30, 0, 0
    for ry in range(max(0, self.home_y - HOME_SEARCH_RADIUS), min(MAP_HEIGHT - 1, self.home_y + HOME_SEARCH_RADIUS) + 1):
      for rx in range(max(0, self.home_x - HOME_SEARCH_RADIUS), min(MAP_WIDTH - 1, self.home_x + HOME_SEARCH_RADIUS) + 1):
        if not self.passable(rx, ry):
          continue
        d = heuristic(self.home_x, self.home_y, rx, ry)
        if d < best_dist:
          best_dist, best_x, best_y = d, rx, ry
    if best_dist == 2**30:
      return self._button_goal()
    return (-1, best_x, best_y, 'Home', TaskState.MAYBE)

  def _button_fallback_ready(self):
    return (not self.radar_dots and
            not any(self.radar_tasks) and
            not any(self.checkout_tasks) and
            not any(s == TaskState.MANDATORY for s in self.task_states))

  def nearest_task_goal(self):
    # Priority 1: visible task icons
    best_dist, best_goal = 2**30, None
    for i, task in enumerate(TASKS):
      if not self._task_icon_visible_for(task):
        continue
      g = self._task_goal_for(i, TaskState.MANDATORY)
      if g is None:
        continue
      d = self.goal_distance(g[1], g[2])
      if d < best_dist:
        best_dist, best_goal = d, g
    if best_goal:
      return best_goal

    # Priority 2: current mandatory goal
    if 0 <= self.goal_index < len(TASKS) and self.task_states[self.goal_index] == TaskState.MANDATORY:
      g = self._task_goal_for(self.goal_index, TaskState.MANDATORY)
      if g:
        return g

    # Priority 3: any mandatory task
    best_dist, best_goal = 2**30, None
    for i in range(len(TASKS)):
      if self.task_states[i] != TaskState.MANDATORY:
        continue
      g = self._task_goal_for(i, TaskState.MANDATORY)
      if g is None:
        continue
      d = self.goal_distance(g[1], g[2])
      if d < best_dist:
        best_dist, best_goal = d, g
    if best_goal:
      return best_goal

    # Priority 4: checkout tasks
    best_dist, best_goal = 2**30, None
    for i in range(len(TASKS)):
      if not self.checkout_tasks[i] or self.task_states[i] == TaskState.COMPLETED:
        continue
      g = self._task_goal_for(i, TaskState.MAYBE)
      if g is None:
        continue
      d = self.goal_distance(g[1], g[2])
      if d < best_dist:
        best_dist, best_goal = d, g
    if best_goal:
      return best_goal

    # Priority 5: radar tasks
    best_dist, best_goal = 2**30, None
    for i in range(len(TASKS)):
      if not self.radar_tasks[i]:
        continue
      g = self._task_goal_for(i, TaskState.MAYBE)
      if g is None:
        continue
      d = self.goal_distance(g[1], g[2])
      if d < best_dist:
        best_dist, best_goal = d, g
    if best_goal:
      return best_goal

    if self._button_fallback_ready():
      return self._home_goal()
    return None

  # -----------------------------------------------------------------------
  # Imposter behavior
  # -----------------------------------------------------------------------
  def _fake_target_count(self):
    return len(TASKS) + 1

  def _fake_target_goal_for(self, index):
    if index == len(TASKS):
      return self._button_goal()
    return self._task_goal_for(index, TaskState.MAYBE)

  def _random_fake_target_index(self):
    c = self._fake_target_count()
    return self.rng.randint(0, c - 1) if c > 0 else -1

  def _fake_target_center(self, index):
    if index == len(TASKS):
      return (BUTTON_X + BUTTON_W // 2, BUTTON_Y + BUTTON_H // 2)
    return task_center(TASKS[index])

  def _farthest_fake_target_from(self, ox, oy):
    best_dist, result = -1, -1
    for i in range(self._fake_target_count()):
      cx, cy = self._fake_target_center(i)
      d = heuristic(ox, oy, cx, cy)
      if d > best_dist:
        best_dist, result = d, i
    return result

  def _visible_crewmate_world(self, cm):
    return (self.camera_x + cm.x + SPRITE_DRAW_OFF_X, self.camera_y + cm.y + SPRITE_DRAW_OFF_Y)

  def _lone_visible_crewmate(self):
    found, result = False, None
    for cm in self.visible_crewmates:
      if self._known_imposter_color(cm.color_index):
        continue
      if found:
        return None
      found, result = True, cm
    return result if found else None

  def _visible_body_world(self, body):
    return (self.camera_x + body.x + SPRITE_DRAW_OFF_X, self.camera_y + body.y + SPRITE_DRAW_OFF_Y)

  def _nearest_body(self):
    best_dist, result = 2**30, None
    for body in self.visible_bodies:
      wx, wy = self._visible_body_world(body)
      d = heuristic(self.player_world_x(), self.player_world_y(), wx, wy)
      if d < best_dist:
        best_dist = d
        result = (wx, wy)
    return result

  def _in_kill_range(self, tx, ty):
    ax = self.player_world_x() + COLLISION_W // 2
    ay = self.player_world_y() + COLLISION_H // 2
    bx = tx + COLLISION_W // 2
    by = ty + COLLISION_H // 2
    dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy <= KILL_RANGE * KILL_RANGE

  def _in_report_range(self, tx, ty):
    ax = self.player_world_x() + COLLISION_W // 2
    ay = self.player_world_y() + COLLISION_H // 2
    bx = tx + COLLISION_W // 2
    by = ty + COLLISION_H // 2
    dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy <= REPORT_RANGE * REPORT_RANGE

  def _known_imposter_color(self, ci):
    return 0 <= ci < len(self.known_imposters) and self.known_imposters[ci]

  def _suspected_color(self):
    best_tick, result = 0, None
    for i, tick in enumerate(self.last_seen_ticks):
      if i == self.self_color_index or self._known_imposter_color(i):
        continue
      if tick > best_tick and i < len(PLAYER_COLOR_NAMES):
        best_tick = tick
        result = (PLAYER_COLOR_NAMES[i], tick, i)
    return result

  def _body_room_message(self, x, y):
    room = room_name_at(x + COLLISION_W // 2, y + COLLISION_H // 2)
    msg = 'body' if room == 'unknown' else f'body in {room}'
    suspect = self._suspected_color()
    if suspect:
      msg += f' sus {suspect[0]}'
    return msg

  def _same_body(self, ax, ay, bx, by):
    if bx == INT_MIN or by == INT_MIN:
      return False
    return heuristic(ax, ay, bx, by) <= BODY_SEARCH_RADIUS + 4

  def _queue_body_seen(self, x, y):
    if self._same_body(x, y, self.last_body_seen_x, self.last_body_seen_y):
      return
    self.last_body_seen_x, self.last_body_seen_y = x, y
    self.pending_chat = self._body_room_message(x, y)

  def _queue_body_report(self, x, y):
    if self._same_body(x, y, self.last_body_report_x, self.last_body_report_y):
      return
    self.last_body_report_x, self.last_body_report_y = x, y
    self.pending_chat = self._body_room_message(x, y)

  # -----------------------------------------------------------------------
  # Navigation actions
  # -----------------------------------------------------------------------
  def _navigate_to_point(self, x, y, name, precise_radius=TASK_PRECISE_APPROACH_RADIUS):
    self.has_goal = True
    self.goal_x, self.goal_y, self.goal_name = x, y, name
    if self.is_ghost:
      self.path = []
      self.has_path_step = False
      self.intent = f'ghost direct to {name}'
      self.desired_mask = self.precise_mask_for_goal(x, y)
    else:
      self.path = self.find_path(x, y)
      self.path_step = self.choose_path_step()
      self.has_path_step = self.path_step.found
      self.intent = f'A* to {name} path={len(self.path)}'
      if heuristic(self.player_world_x(), self.player_world_y(), x, y) <= precise_radius:
        self.intent = f'precise approach to {name}'
        self.desired_mask = self.precise_mask_for_goal(x, y)
      else:
        self.desired_mask = self.mask_for_waypoint(self.path_step)
    self.controller_mask = self.desired_mask
    return self.apply_jiggle(self.controller_mask)

  def _hold_task_action(self, name):
    self.intent = f'doing task at {name} hold={self.task_hold_ticks}'
    self.desired_mask = BUTTON_A
    self.controller_mask = BUTTON_A
    self.has_path_step = False
    self.path = []
    if self.task_hold_ticks > 0:
      self.task_hold_ticks -= 1
    if self.task_hold_ticks == 0 and 0 <= self.task_hold_index < len(self.task_states):
      task = TASKS[self.task_hold_index]
      if not self._task_icon_visible_for(task) and self._task_icon_clear_area_visible(task):
        self.task_states[self.task_hold_index] = TaskState.COMPLETED
        self.checkout_tasks[self.task_hold_index] = False
      else:
        self.task_states[self.task_hold_index] = TaskState.MANDATORY
      self.task_hold_index = -1
    return BUTTON_A

  def _report_body_action(self, x, y):
    self.intent = 'reporting dead body'
    self.desired_mask = BUTTON_A
    self.controller_mask = BUTTON_A
    self.has_path_step = False
    self.path = []
    self.task_hold_ticks = 0
    self.task_hold_index = -1
    self._queue_body_report(x, y)
    return BUTTON_A

  def _task_ready(self, task):
    x, y = self.player_world_x(), self.player_world_y()
    if (x < task.x + TASK_INNER_MARGIN or x >= task.x + task.w - TASK_INNER_MARGIN or
        y < task.y + TASK_INNER_MARGIN or y >= task.y + task.h - TASK_INNER_MARGIN):
      return False
    return abs(self.velocity_x) + abs(self.velocity_y) <= 1

  def _task_ready_at_goal(self, index, gx, gy):
    if index < 0 or index >= len(TASKS):
      return False
    task = TASKS[index]
    x, y = self.player_world_x(), self.player_world_y()
    if x < task.x or x >= task.x + task.w or y < task.y or y >= task.y + task.h:
      return False
    if abs(self.velocity_x) + abs(self.velocity_y) > 1:
      return False
    return self._task_ready(task) or heuristic(x, y, gx, gy) <= 1

  # -----------------------------------------------------------------------
  # Imposter decision
  # -----------------------------------------------------------------------
  def decide_imposter_mask(self):
    self.radar_dots = []
    for i in range(len(TASKS)):
      self.radar_tasks[i] = False
      self.checkout_tasks[i] = False
    self.task_hold_ticks = 0
    self.task_hold_index = -1

    body = self._nearest_body()
    if body:
      bx, by = body
      self.imposter_goal_index = self._farthest_fake_target_from(bx, by)
      goal = self._fake_target_goal_for(self.imposter_goal_index)
      if goal:
        self.goal_index = goal[0]
        return self._navigate_to_point(goal[1], goal[2], f'flee body to {goal[3]}')

    lone = self._lone_visible_crewmate()
    if lone and self.imposter_kill_ready:
      tx, ty = self._visible_crewmate_world(lone)
      if self._in_kill_range(tx, ty):
        self.imposter_goal_index = self._farthest_fake_target_from(self.player_world_x(), self.player_world_y())
        self.intent = 'kill lone crewmate'
        self.desired_mask = BUTTON_A
        self.controller_mask = BUTTON_A
        self.has_path_step = False
        self.path = []
        return BUTTON_A
      self.goal_index = -2
      return self._navigate_to_point(tx, ty, 'lone crewmate', KILL_APPROACH_RADIUS)

    if self.imposter_goal_index < 0 or self.imposter_goal_index >= self._fake_target_count():
      self.imposter_goal_index = self._random_fake_target_index()
    goal = self._fake_target_goal_for(self.imposter_goal_index)
    if goal is None:
      self.imposter_goal_index = self._random_fake_target_index()
      goal = self._fake_target_goal_for(self.imposter_goal_index)
    if goal is None:
      self.intent = 'imposter idle'
      return 0
    if heuristic(self.player_world_x(), self.player_world_y(), goal[1], goal[2]) <= TASK_PRECISE_APPROACH_RADIUS:
      self.imposter_goal_index = self._random_fake_target_index()
      goal = self._fake_target_goal_for(self.imposter_goal_index)
      if goal is None:
        return 0
    self.goal_index = goal[0]
    return self._navigate_to_point(goal[1], goal[2], f'fake target {goal[3]}')

  # -----------------------------------------------------------------------
  # Voting
  # -----------------------------------------------------------------------
  def clear_voting_state(self):
    self.voting = False
    self.vote_player_count = 0
    self.vote_cursor = VOTE_UNKNOWN
    self.vote_self_slot = VOTE_UNKNOWN
    self.vote_target = VOTE_UNKNOWN
    self.vote_start_tick = -1
    self.vote_chat_sus_color = VOTE_UNKNOWN
    self.vote_chat_text = ''
    for i in range(MAX_PLAYERS):
      self.vote_slots[i] = VoteSlot()
    for i in range(PLAYER_COLOR_COUNT):
      self.vote_choices[i] = VOTE_UNKNOWN

  def _vote_grid_layout(self, count):
    cols = min(count, 8)
    rows = (count + cols - 1) // cols
    total_w = cols * VOTE_CELL_W
    start_x = (SCREEN_WIDTH - total_w) // 2
    skip_x = (SCREEN_WIDTH - VOTE_SKIP_W) // 2
    skip_y = VOTE_START_Y + rows * VOTE_CELL_H + 1
    return cols, rows, start_x, skip_x, skip_y

  def _vote_cell_origin(self, count, index):
    cols, _, start_x, _, _ = self._vote_grid_layout(count)
    return (start_x + (index % cols) * VOTE_CELL_W, VOTE_START_Y + (index // cols) * VOTE_CELL_H)

  def _vote_cell_selected(self, count, index):
    cx, cy = self._vote_cell_origin(count, index)
    hits = 0
    for bx in range(VOTE_CELL_W):
      top_idx = (cy - 1) * SCREEN_WIDTH + cx + bx
      bot_idx = (cy + VOTE_CELL_H - 2) * SCREEN_WIDTH + cx + bx
      if 0 <= top_idx < len(self.unpacked) and int(self.unpacked[top_idx]) == 2:
        hits += 1
      if 0 <= bot_idx < len(self.unpacked) and int(self.unpacked[bot_idx]) == 2:
        hits += 1
    return hits >= VOTE_CELL_W

  def _vote_self_marker_present(self, count, index, ci):
    if ci < 0 or ci >= len(PLAYER_COLORS):
      return False
    cx, cy = self._vote_cell_origin(count, index)
    mx, my = cx + VOTE_CELL_W // 2 - 1, cy - 2
    if my < 0 or mx + 1 >= SCREEN_WIDTH:
      return False
    a = int(self.unpacked[my * SCREEN_WIDTH + mx])
    b = int(self.unpacked[my * SCREEN_WIDTH + mx + 1])
    color = PLAYER_COLORS[ci]
    if color == SPACE_COLOR:
      return a == 2 and b == VOTE_BLACK_MARKER
    return a == color and b == color

  def _parse_vote_slot(self, count, index):
    cx, cy = self._vote_cell_origin(count, index)
    sp = self.gd.player_sprite
    sx = cx + (VOTE_CELL_W - sp.width) // 2
    sy = cy + 1
    if self._matches_crewmate(sx, sy, False):
      ci = self._crewmate_color_index(sx, sy, False)
      return VoteSlot(ci, True)
    if self._matches_actor_sprite(self.gd.body_sprite, sx, sy, False, BODY_MAX_MISSES, BODY_MIN_STABLE_PIXELS, BODY_MIN_TINT_PIXELS):
      return VoteSlot(VOTE_UNKNOWN, False)
    return VoteSlot(VOTE_UNKNOWN, False)

  def parse_voting_screen(self):
    start_tick = self.vote_start_tick if (self.voting and self.vote_start_tick >= 0) else self.frame_tick
    for count in range(MAX_PLAYERS, 0, -1):
      if self._try_parse_voting(count, start_tick):
        return True
    self.clear_voting_state()
    return False

  def _try_parse_voting(self, count, start_tick):
    _, _, _, skip_x, skip_y = self._vote_grid_layout(count)
    # Simplified: check that slots parse with sequential colors
    slots = []
    for i in range(count):
      slot = self._parse_vote_slot(count, i)
      if slot.color_index == VOTE_UNKNOWN:
        return False
      if slot.color_index != i:
        return False
      slots.append(slot)

    self.clear_voting_state()
    self.voting = True
    self.vote_player_count = count
    self.vote_start_tick = start_tick
    for i in range(count):
      self.vote_slots[i] = slots[i]
      if slots[i].alive and self._vote_cell_selected(count, i):
        self.vote_cursor = i
      if self._vote_self_marker_present(count, i, slots[i].color_index):
        self.vote_self_slot = i
        self.self_color_index = slots[i].color_index
    return True

  def _desired_voting_target(self):
    if self.vote_chat_sus_color >= 0:
      slot = self._vote_slot_for_color(self.vote_chat_sus_color)
      if slot >= 0 and slot != self.vote_self_slot and self.vote_slots[slot].alive:
        return slot
    suspect = self._suspected_color()
    if suspect:
      slot = self._vote_slot_for_color(suspect[2])
      if slot >= 0 and slot != self.vote_self_slot and self.vote_slots[slot].alive:
        return slot
    return self.vote_player_count  # skip

  def _vote_slot_for_color(self, ci):
    for i in range(self.vote_player_count):
      if self.vote_slots[i].color_index == ci:
        return i
    return VOTE_UNKNOWN

  def _self_vote_choice(self):
    if 0 <= self.self_color_index < len(self.vote_choices):
      return self.vote_choices[self.self_color_index]
    return VOTE_UNKNOWN

  def _next_vote_selectable(self, cursor, direction):
    total = self.vote_player_count + 1
    if total <= 0:
      return VOTE_UNKNOWN
    cur = cursor
    for _ in range(total):
      cur = (cur + direction + total) % total
      if cur == self.vote_player_count:
        return cur
      if 0 <= cur < self.vote_player_count and self.vote_slots[cur].alive:
        return cur
    return VOTE_UNKNOWN

  def _vote_steps_to(self, target, direction):
    if self.vote_cursor == VOTE_UNKNOWN:
      return 2**30
    cur = self.vote_cursor
    for step in range(self.vote_player_count + 2):
      if cur == target:
        return step
      cur = self._next_vote_selectable(cur, direction)
      if cur == VOTE_UNKNOWN:
        return 2**30
    return 2**30

  def decide_voting_mask(self):
    self.has_goal = False
    self.has_path_step = False
    self.path = []
    self.vote_target = self._desired_voting_target()

    own_vote = self._self_vote_choice()
    if own_vote != VOTE_UNKNOWN:
      self.desired_mask = self.controller_mask = 0
      self.intent = 'voted'
      return 0

    if self.vote_cursor != self.vote_target:
      left_steps = self._vote_steps_to(self.vote_target, -1)
      right_steps = self._vote_steps_to(self.vote_target, 1)
      d = -1 if left_steps < right_steps else 1
      mask = BUTTON_LEFT if d < 0 else BUTTON_RIGHT
      self.desired_mask = 0 if self.last_mask == mask else mask
      self.controller_mask = self.desired_mask
      self.intent = 'voting cursor move'
      return self.desired_mask

    listened = (self.frame_tick - self.vote_start_tick) if self.vote_start_tick >= 0 else 0
    if listened < VOTE_LISTEN_TICKS:
      self.desired_mask = self.controller_mask = 0
      self.intent = f'listening in vote {listened}/{VOTE_LISTEN_TICKS}'
      return 0

    self.desired_mask = 0 if self.last_mask == BUTTON_A else BUTTON_A
    self.controller_mask = self.desired_mask
    self.intent = 'voting'
    return self.desired_mask

  # -----------------------------------------------------------------------
  # Round/state management
  # -----------------------------------------------------------------------
  def reset_round_state(self):
    self.localized = False
    self.game_started = False
    self.home_set = False
    self.home_x = self.home_y = 0
    self.role = BotRole.CREWMATE
    self.is_ghost = False
    self.ghost_icon_frames = 0
    self.imposter_kill_ready = False
    self.imposter_goal_index = -1
    self.camera_lock = CameraLock.NO_LOCK
    self.camera_score = 0
    self.have_motion_sample = False
    self.velocity_x = self.velocity_y = 0
    self.stuck_frames = self.jiggle_ticks = self.jiggle_side = 0
    self.desired_mask = self.controller_mask = 0
    self.task_hold_ticks = 0
    self.task_hold_index = -1
    self.pending_chat = ''
    self.last_body_seen_x = self.last_body_seen_y = INT_MIN
    self.last_body_report_x = self.last_body_report_y = INT_MIN
    self.self_color_index = -1
    self.clear_voting_state()
    self.last_seen_ticks = [0] * PLAYER_COLOR_COUNT
    self.known_imposters = [False] * PLAYER_COLOR_COUNT
    self.goal_index = -1
    self.goal_name = ''
    self.has_goal = False
    self.has_path_step = False
    self.path = []
    self.radar_dots = []
    self.visible_task_icons = []
    self.visible_crewmates = []
    self.visible_bodies = []
    self.visible_ghosts = []
    n = len(TASKS)
    self.radar_tasks = [False] * n
    self.checkout_tasks = [False] * n
    self.task_states = [TaskState.NOT_DOING] * n
    self.task_icon_misses = [0] * n

  def reseed_localization_at_home(self):
    if self.home_set:
      self.camera_x = camera_x_for_world(self.home_x)
      self.camera_y = camera_y_for_world(self.home_y)
    else:
      self.camera_x = button_camera_x()
      self.camera_y = button_camera_y()
    self.last_camera_x = self.camera_x
    self.last_camera_y = self.camera_y
    self.camera_lock = CameraLock.NO_LOCK
    self.camera_score = 0
    self.localized = False
    self.have_motion_sample = False
    self.velocity_x = self.velocity_y = 0
    self.stuck_frames = self.jiggle_ticks = 0
    self.desired_mask = self.controller_mask = 0
    self.task_hold_ticks = 0
    self.task_hold_index = -1
    self.goal_index = -1
    self.goal_name = ''
    self.has_goal = self.has_path_step = False
    self.path = []

  def remember_home(self):
    if not self.localized or self.interstitial:
      return
    self.game_started = True
    if self.home_set:
      return
    self.home_x = self.player_world_x()
    self.home_y = self.player_world_y()
    self.home_set = True

  # -----------------------------------------------------------------------
  # Main perception + decision pipeline
  # -----------------------------------------------------------------------
  def update_location(self):
    was_interstitial = self.interstitial
    self.last_camera_x = self.camera_x
    self.last_camera_y = self.camera_y
    self.interstitial = self.is_interstitial_screen()

    if self.interstitial:
      self.interstitial_text = self.detect_interstitial_text()
      self.visible_task_icons = []
      self.visible_crewmates = []
      self.visible_bodies = []
      self.visible_ghosts = []
      if self.is_game_over_text(self.interstitial_text) and self.last_game_over_text != self.interstitial_text:
        self.reset_round_state()
        self.last_game_over_text = self.interstitial_text
      elif not self.parse_voting_screen():
        pass  # could do role reveal detection here
      return

    self.interstitial_text = ''
    self.last_game_over_text = ''
    if self.voting:
      self.clear_voting_state()
    if was_interstitial:
      self.reseed_localization_at_home()

    self.update_role()
    self.update_self_color()
    self.scan_bodies()
    self.scan_ghosts()
    self.scan_crewmates()
    if self.role == BotRole.IMPOSTER and not self.is_ghost:
      self.visible_task_icons = []
    else:
      self.scan_task_icons()

    if self.locate_near_frame():
      return
    self.locate_by_frame()

  def decide_next_mask(self):
    self.update_location()

    if self.interstitial:
      self.update_motion_state()
      self.has_goal = self.has_path_step = False
      self.path = []
      if self.voting:
        return self.decide_voting_mask()
      self.desired_mask = self.controller_mask = 0
      self.intent = f'interstitial: {self.interstitial_text}' if self.interstitial_text else 'interstitial screen'
      return 0

    self.update_motion_state()
    self.update_task_guesses()
    self.update_task_icons()
    self.has_goal = self.has_path_step = False
    self.path = []
    self.desired_mask = self.controller_mask = 0
    self.intent = 'localizing'

    if not self.localized:
      return 0

    self.remember_home()

    # Imposter path
    if self.role == BotRole.IMPOSTER and not self.is_ghost:
      return self.decide_imposter_mask()

    # Crewmate: report bodies
    if not self.is_ghost:
      body = self._nearest_body()
      if body:
        bx, by = body
        self._queue_body_seen(bx, by)
        if self._in_report_range(bx, by) and abs(self.velocity_x) + abs(self.velocity_y) <= 1:
          return self._report_body_action(bx, by)
        return self._navigate_to_point(bx, by, 'dead body', KILL_APPROACH_RADIUS)

    # Continue holding task
    if self.task_hold_ticks > 0:
      return self._hold_task_action(self.goal_name or 'task')

    # Find nearest task goal
    goal = self.nearest_task_goal()
    if goal is None:
      self.intent = 'localized, no task goal'
      return 0

    index, gx, gy, gname, gstate = goal
    self.has_goal = True
    self.goal_x, self.goal_y = gx, gy
    self.goal_index = index
    self.goal_name = gname

    # Ready to do task?
    if gstate == TaskState.MANDATORY and self._task_ready_at_goal(index, gx, gy):
      self.task_hold_ticks = TASK_COMPLETE_TICKS + TASK_HOLD_PADDING
      self.task_hold_index = index
      return self._hold_task_action(gname)

    # Ghost direct nav
    if self.is_ghost:
      return self._navigate_to_point(gx, gy, gname)

    # A* navigation
    self.path = self.find_path(gx, gy)
    self.path_step = self.choose_path_step()
    self.has_path_step = self.path_step.found
    self.intent = f'A* to {gname} path={len(self.path)} state={gstate}'

    if gstate == TaskState.MANDATORY and heuristic(self.player_world_x(), self.player_world_y(), gx, gy) <= TASK_PRECISE_APPROACH_RADIUS:
      self.desired_mask = self.precise_mask_for_goal(gx, gy)
    else:
      self.desired_mask = self.mask_for_waypoint(self.path_step)

    self.controller_mask = self.desired_mask
    return self.apply_jiggle(self.controller_mask)

  # -----------------------------------------------------------------------
  # Brain integration hooks
  # -----------------------------------------------------------------------
  def build_snapshot(self):
    snap = {
      'type': 'snapshot',
      'tick': self.frame_tick,
      'localized': self.localized,
      'camera_x': self.camera_x,
      'camera_y': self.camera_y,
      'player_x': self.player_world_x(),
      'player_y': self.player_world_y(),
      'room': self.room_name(),
      'role': ['unknown', 'crewmate', 'imposter'][self.role],
      'is_ghost': self.is_ghost,
      'kill_ready': self.imposter_kill_ready,
      'self_color': self.self_color_index,
      'voting': self.voting,
      'interstitial': self.interstitial,
      'interstitial_text': self.interstitial_text,
      'visible_players': [
        {'x': self.camera_x + cm.x + SPRITE_DRAW_OFF_X,
         'y': self.camera_y + cm.y + SPRITE_DRAW_OFF_Y,
         'color': cm.color_index,
         'room': room_name_at(self.camera_x + cm.x + SPRITE_DRAW_OFF_X, self.camera_y + cm.y + SPRITE_DRAW_OFF_Y)}
        for cm in self.visible_crewmates
      ],
      'visible_bodies': [
        {'x': self.camera_x + b.x + SPRITE_DRAW_OFF_X,
         'y': self.camera_y + b.y + SPRITE_DRAW_OFF_Y}
        for b in self.visible_bodies
      ],
      'intent': self.intent,
      'goal_name': self.goal_name,
    }
    return snap

  def process_brain_directive(self, directive):
    """Override goal selection based on brain directive."""
    if directive is None:
      return
    if hasattr(directive, 'navigate_to') and directive.navigate_to:
      nx, ny = directive.navigate_to
      if self.passable(nx, ny):
        self.goal_x, self.goal_y = nx, ny
        self.goal_name = f'brain:{directive.strategy}'


# ---------------------------------------------------------------------------
# WebSocket main loop
# ---------------------------------------------------------------------------
async def run_bot(host='localhost', port=8080, name='pybot', brain=None,
                  debug_server=None):
  if websockets is None:
    raise ImportError('websockets package is required: pip install websockets')

  url = f'ws://{host}:{port}/player?name={name}'
  logger.info('Connecting to %s', url)

  bot = Bot(brain=brain, name=name)
  bot._debug_server = debug_server

  if debug_server is not None:
    await debug_server.start()
    if brain is not None:
      brain._debug_server = debug_server

  async for ws in websockets.connect(url, max_size=None):
    logger.info('Connected to game server')
    try:
      last_sent_mask = -1
      log_counter = 0
      last_phase = ''
      last_intent = ''
      last_role = 0
      last_localized = False
      brain_initialized = False
      async for message in ws:
        if isinstance(message, str):
          continue

        data = message
        if len(data) != PROTOCOL_BYTES:
          continue

        bot.frame_tick += 1
        bot.unpacked = unpack_4bpp(data)
        mask = bot.decide_next_mask()

        # Log phase / state transitions
        phase = 'voting' if bot.voting else ('interstitial' if bot.interstitial else 'playing')
        if phase != last_phase:
          logger.info('Phase: %s', phase)
          last_phase = phase
        if bot.role != last_role:
          role_name = ['unknown', 'crewmate', 'imposter'][bot.role]
          logger.info('Role assigned: %s (ghost=%s)', role_name, bot.is_ghost)
          last_role = bot.role

        if brain is not None and not brain_initialized and bot.role != 0 and bot.self_color_index >= 0:
          from .learnings import generate_game_id, synthesize_learnings
          role_name = ['unknown', 'crewmate', 'imposter'][bot.role]
          brain.learnings_text = synthesize_learnings()
          brain.init_game(
            game_id=generate_game_id(),
            role=role_name,
            self_color=bot.self_color_index,
          )
          brain_initialized = True
          logger.info('Brain initialized: role=%s color=%d', role_name, bot.self_color_index)
        if bot.localized and not last_localized:
          logger.info('Localized at (%d, %d) — room: %s',
                       bot.camera_x, bot.camera_y, bot.room_name())
          last_localized = True
        elif not bot.localized and last_localized:
          logger.info('Lost localization')
          last_localized = False

        if bot.intent != last_intent:
          logger.info('Intent: %s', bot.intent)
          last_intent = bot.intent

        # Periodic status log every 120 frames (~5 sec at 24fps)
        log_counter += 1
        if log_counter % 120 == 0:
          vis_players = len(bot.visible_crewmates)
          vis_bodies = len(bot.visible_bodies)
          status_parts = [
            f'tick={bot.frame_tick}',
            f'pos=({bot.player_world_x()},{bot.player_world_y()})',
            f'room={bot.room_name()}',
            f'vis={vis_players}p/{vis_bodies}b',
          ]
          if bot.has_goal:
            status_parts.append(f'goal=({bot.goal_x},{bot.goal_y}):{bot.goal_name}')
          if bot.task_hold_ticks > 0:
            status_parts.append(f'doing_task={bot.task_hold_ticks}t')
          logger.info('Status: %s', ' | '.join(status_parts))

        # Brain integration
        if bot.brain is not None and bot.localized and not bot.interstitial:
          try:
            snap = bot.build_snapshot()
            directive = bot.brain.process_snapshot(snap)
            if directive is not None:
              logger.info('Brain directive: strategy=%s',
                           getattr(directive, 'strategy', '?'))
            bot.process_brain_directive(directive)
          except Exception as e:
            logger.warning('Brain error: %s', e)

        # Debug server emissions (every 3rd frame to avoid flooding)
        if debug_server is not None and bot.frame_tick % 3 == 0:
          debug_server.emit_snapshot(bot)
          if bot.brain is not None:
            debug_server.emit_status(bot, bot.brain)
          else:
            debug_server.emit_status(bot)
          if bot.brain is not None and bot.frame_tick % 30 == 0:
            debug_server.emit_player_model(bot.brain.model, bot.frame_tick)
            debug_server.emit_memory(bot.brain.memory, bot.frame_tick)

        # Send input when changed
        if mask != last_sent_mask:
          await ws.send(blob_from_mask(mask))
          last_sent_mask = mask
        bot.last_mask = mask

        # Send pending chat during interstitial
        if bot.pending_chat and bot.voting:
          logger.info('Chat: %s', bot.pending_chat)
          await ws.send(blob_from_chat(bot.pending_chat))
          bot.pending_chat = ''

    except websockets.ConnectionClosed:
      logger.info('Disconnected, reconnecting...')
      continue


def main():
  logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(name)s] %(levelname)s: %(message)s',
  )

  parser = argparse.ArgumentParser(description='Among Them Python Bot')
  parser.add_argument('--host', default='localhost', help='Game server host')
  parser.add_argument('--port', type=int, default=8080, help='Game server port')
  parser.add_argument('--name', default='pybot', help='Bot player name')
  parser.add_argument('--brain', action='store_true', help='Enable LLM brain')
  parser.add_argument('--provider', default='bedrock', help='LLM provider')
  parser.add_argument('--model', default='', help='LLM model name')
  parser.add_argument('--debug', action='store_true', help='Enable debug GUI server')
  parser.add_argument('--debug-port', type=int, default=9090, help='Debug server port')
  args = parser.parse_args()

  brain = None
  if args.brain:
    try:
      from .brain import Brain
      brain = Brain(provider_spec=args.provider, model=args.model)
      logger.info('Brain enabled: provider=%s model=%s', args.provider, args.model or 'default')
    except ImportError:
      logger.warning('Brain module not available, running without LLM')

  debug_server = None
  if args.debug:
    from .debug_server import DebugServer
    debug_server = DebugServer(port=args.debug_port)
    logger.info('Debug GUI will be at http://localhost:%d', args.debug_port + 1)

  asyncio.run(run_bot(
    host=args.host,
    port=args.port,
    name=args.name,
    brain=brain,
    debug_server=debug_server,
  ))


if __name__ == '__main__':
  main()

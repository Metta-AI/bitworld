#!/usr/bin/env python3
from __future__ import annotations

import argparse
import heapq
import os
import random
import time
import urllib.parse
from dataclasses import dataclass, field
from enum import IntEnum

try:
    import websocket
except ImportError as exc:
    raise SystemExit(
        "Missing dependency: pip install -r requirements.txt"
    ) from exc


PlayerDefaultPort = 2000
ScreenWidth = 128
ScreenHeight = 128
WorldWidthTiles = 596
WorldHeightTiles = 18
WorldTileSize = 32
WorldWidthPixels = WorldWidthTiles * WorldTileSize
WorldHeightPixels = WorldHeightTiles * WorldTileSize
PlayerWebSocketPath = "/player"
DefaultHost = "localhost"

MapLayerId = 0
MapSpriteId = 1
MapObjectId = 1
PlayerSpriteBase = 100
SelectedPlayerSpriteBase = 200
MobSpriteId = 300
BossSpriteId = 301
CoinSpriteId = 302
HeartSpriteId = 303
SwooshSpriteBase = 304
TrollSpriteId = 312
TerrainSpriteBase = 320
LandmarkSpriteBase = 360
PlayerHudSpriteId = 600
PlayerObjectBase = 1000
MobObjectBase = 2000
PlayerHudObjectId = 7000
StatusHudObjectId = PlayerHudObjectId + 2
PlayerHealthObjectBase = 10000
CarryObjectBase = 12000
StatusBadgeObjectBase = 13000
StatusBadgeSlots = 18
LowHealthPercent = 50

ButtonUp = 1 << 0
ButtonDown = 1 << 1
ButtonLeft = 1 << 2
ButtonRight = 1 << 3
ButtonA = 1 << 5
ButtonB = 1 << 6

PlayerSpriteSlots = 64
SelectedPlayerSpriteSlots = 64
SwooshSpriteSlots = 8
TerrainSpriteSlots = 16
LandmarkSpriteSlots = 11
MaxDrainMessages = 256
PathCellSize = 8
PathGridWidth = WorldWidthPixels // PathCellSize
PathGridHeight = WorldHeightPixels // PathCellSize
MoveDeadband = 5
GoalArrivalRadius = 18
AttackReach = 46
AttackAlignSlack = 22
AttackCooldownTicks = 7
ObstaclePad = 8
PathLookaheadCells = 4
StuckFrameThreshold = 14
JiggleDuration = 12
SkipTargetTicks = 72
ExploreStep = 17
MoveMask = ButtonUp | ButtonDown | ButtonLeft | ButtonRight


class SpriteKind(IntEnum):
    Unknown = 0
    Map = 1
    Player = 2
    Mob = 3
    Troll = 4
    Boss = 5
    Coin = 6
    Heart = 7
    Swoosh = 8
    Terrain = 9
    Hud = 10
    Text = 11


class TargetKind(IntEnum):
    Explore = 0
    Regroup = 1
    Coin = 2
    Heart = 3
    Wood = 4
    Food = 5
    Stone = 6
    Gold = 7
    Camp = 8
    Relic = 9
    Gate = 10
    Shrine = 11
    Rescue = 12
    Lair = 13
    Waystation = 14
    Mob = 15
    Troll = 16
    Boss = 17


class CarryKind(IntEnum):
    None_ = 0
    Wood = 1
    Food = 2
    Stone = 3
    Gold = 4


@dataclass
class SpriteInfo:
    defined: bool = False
    width: int = 0
    height: int = 0
    label: str = ""
    kind: SpriteKind = SpriteKind.Unknown
    pixels: bytes = b""


@dataclass
class ObjectState:
    present: bool = False
    x: int = 0
    y: int = 0
    z: int = 0
    layer: int = 0
    sprite_id: int = 0


@dataclass
class SpriteBounds:
    x: int = 0
    y: int = 0
    w: int = 0
    h: int = 0


@dataclass
class Target:
    found: bool = False
    kind: TargetKind = TargetKind.Explore
    object_id: int = -1
    x: int = 0
    y: int = 0
    label: str = ""


@dataclass
class PathStep:
    found: bool = False
    next_tx: int = 0
    next_ty: int = 0


def parse_health_label(label: str) -> tuple[bool, int, int]:
    prefix = "health "
    lower = label.lower()
    if not lower.startswith(prefix):
        return False, 0, 0
    parts = lower[len(prefix) :].split("/")
    if len(parts) != 2:
        return False, 0, 0
    try:
        current = int(parts[0].strip())
        maximum = int(parts[1].strip())
    except ValueError:
        return False, 0, 0
    if maximum <= 0:
        return False, 0, 0
    return True, current, maximum


def carry_kind_from_label(label: str) -> CarryKind:
    lower = label.lower()
    if "wood" in lower:
        return CarryKind.Wood
    if "food" in lower:
        return CarryKind.Food
    if "stone" in lower:
        return CarryKind.Stone
    if "gold" in lower:
        return CarryKind.Gold
    return CarryKind.None_


def token_number(tokens: list[str], key: str) -> int:
    for token in tokens:
        if not token.startswith(key) or len(token) <= len(key):
            continue
        try:
            return int(token[len(key) :])
        except ValueError:
            continue
    return 0


@dataclass
class Bot:
    sprites: list[SpriteInfo] = field(default_factory=list)
    objects: list[ObjectState] = field(default_factory=list)
    rng: random.Random = field(default_factory=random.Random)
    camera_x: int = 0
    camera_y: int = 0
    viewport_width: int = ScreenWidth
    viewport_height: int = ScreenHeight
    player_world_x: int = 0
    player_world_y: int = 0
    previous_player_x: int = 0
    previous_player_y: int = 0
    have_player_sample: bool = False
    self_object_id: int = -1
    frame_tick: int = 0
    explore_index: int = 0
    has_explore_goal: bool = False
    explore_x: int = 0
    explore_y: int = 0
    stuck_frames: int = 0
    jiggle_ticks: int = 0
    jiggle_mask: int = 0
    attack_cooldown: int = 0
    current_target_id: int = -1
    current_target_kind: TargetKind = TargetKind.Explore
    current_target_x: int = 0
    current_target_y: int = 0
    current_target_distance: int = 0
    current_target_label: str = ""
    skip_target_id: int = -1
    skip_ticks: int = 0
    coin_count: int = 0
    heart_count: int = 0
    kill_count: int = 0
    low_health: bool = False
    needs_regroup: bool = False
    carried_item: CarryKind = CarryKind.None_
    objective_hint: str = ""
    need_wood: int = 0
    need_stone: int = 0
    intent: str = ""
    last_mask: int = 0
    next_chat_tick: int = 72
    last_chat: str = ""

    def __post_init__(self) -> None:
        self.rng.seed(time.time_ns() ^ os.getpid())
        self.explore_index = self.rng.randrange(PathGridWidth * PathGridHeight)

    def ensure_sprite(self, sprite_id: int) -> None:
        while sprite_id >= len(self.sprites):
            self.sprites.append(SpriteInfo())

    def ensure_object(self, object_id: int) -> None:
        while object_id >= len(self.objects):
            self.objects.append(ObjectState())

    def sprite_info(self, sprite_id: int) -> SpriteInfo:
        if 0 <= sprite_id < len(self.sprites):
            return self.sprites[sprite_id]
        return SpriteInfo()

    def apply_sprite_packet(self, packet: bytes) -> bool:
        offset = 0
        while offset < len(packet):
            message_type = packet[offset]
            offset += 1
            if message_type == 0x01:
                if offset + 10 > len(packet):
                    return False
                sprite_id = read_u16(packet, offset)
                width = read_u16(packet, offset + 2)
                height = read_u16(packet, offset + 4)
                compressed_len = read_u32(packet, offset + 6)
                offset += 10
                if offset + compressed_len + 2 > len(packet):
                    return False
                compressed = packet[offset : offset + compressed_len]
                offset += compressed_len
                label_len = read_u16(packet, offset)
                offset += 2
                if offset + label_len > len(packet):
                    return False
                label = packet[offset : offset + label_len].decode(
                    "utf-8",
                    "replace",
                )
                offset += label_len
                try:
                    pixels = snappy_decompress(compressed) if compressed else b""
                except ValueError:
                    return False
                if len(pixels) != width * height * 4:
                    pixels = b""
                self.ensure_sprite(sprite_id)
                self.sprites[sprite_id] = SpriteInfo(
                    True,
                    width,
                    height,
                    label,
                    classify_sprite(sprite_id, label),
                    pixels,
                )
            elif message_type == 0x02:
                if offset + 11 > len(packet):
                    return False
                object_id = read_u16(packet, offset)
                x = read_i16(packet, offset + 2)
                y = read_i16(packet, offset + 4)
                z = read_i16(packet, offset + 6)
                layer = packet[offset + 8]
                sprite_id = read_u16(packet, offset + 9)
                offset += 11
                self.ensure_object(object_id)
                self.objects[object_id] = ObjectState(
                    True,
                    x,
                    y,
                    z,
                    layer,
                    sprite_id,
                )
            elif message_type == 0x03:
                if offset + 2 > len(packet):
                    return False
                object_id = read_u16(packet, offset)
                offset += 2
                if 0 <= object_id < len(self.objects):
                    self.objects[object_id].present = False
            elif message_type == 0x04:
                for item in self.objects:
                    item.present = False
            elif message_type == 0x05:
                if offset + 5 > len(packet):
                    return False
                layer = packet[offset]
                width = read_u16(packet, offset + 1)
                height = read_u16(packet, offset + 3)
                if layer == MapLayerId:
                    self.viewport_width = width
                    self.viewport_height = height
                offset += 5
            elif message_type == 0x06:
                if offset + 3 > len(packet):
                    return False
                offset += 3
            else:
                return False
        return True

    def update_camera(self) -> None:
        if MapObjectId < len(self.objects) and self.objects[MapObjectId].present:
            self.camera_x = -self.objects[MapObjectId].x
            self.camera_y = -self.objects[MapObjectId].y

    def update_player_position(self) -> None:
        best_distance = 2**63 - 1
        viewport_center_x = self.viewport_width // 2
        viewport_center_y = self.viewport_height // 2
        best_x = self.camera_x + viewport_center_x
        best_y = self.camera_y + viewport_center_y
        best_id = -1
        for object_id, state in enumerate(self.objects):
            if not state.present:
                continue
            if object_id < PlayerObjectBase or object_id >= MobObjectBase:
                continue
            sprite = self.sprite_info(state.sprite_id)
            if sprite.kind != SpriteKind.Player:
                continue
            screen_x = state.x + sprite.width // 2
            screen_y = state.y + sprite.height // 2
            distance = distance_squared(
                screen_x,
                screen_y,
                viewport_center_x,
                viewport_center_y,
            )
            if distance < best_distance:
                best_distance = distance
                best_x = self.camera_x + screen_x
                best_y = self.camera_y + screen_y
                best_id = object_id
        self.player_world_x = best_x
        self.player_world_y = best_y
        self.self_object_id = best_id

    def update_self_affordances(self) -> None:
        self.low_health = False
        self.needs_regroup = False
        self.carried_item = CarryKind.None_
        self.objective_hint = ""
        self.need_wood = 0
        self.need_stone = 0
        if StatusHudObjectId < len(self.objects) and self.objects[StatusHudObjectId].present:
            self.read_status_hud(self.sprite_info(self.objects[StatusHudObjectId].sprite_id).label)
        if self.self_object_id < PlayerObjectBase:
            return
        player_id = self.self_object_id - PlayerObjectBase
        carry_object_id = CarryObjectBase + player_id
        if carry_object_id < len(self.objects) and self.objects[carry_object_id].present:
            carried = carry_kind_from_label(self.sprite_info(self.objects[carry_object_id].sprite_id).label)
            if carried != CarryKind.None_:
                self.carried_item = carried
        health_object_id = PlayerHealthObjectBase + player_id
        if (
            health_object_id < len(self.objects)
            and self.objects[health_object_id].present
        ):
            health_sprite = self.sprite_info(self.objects[health_object_id].sprite_id)
            found, current, maximum = parse_health_label(health_sprite.label)
            if found and current * 100 <= maximum * LowHealthPercent:
                self.low_health = True

        for badge_index in range(StatusBadgeSlots):
            object_id = StatusBadgeObjectBase + player_id * StatusBadgeSlots + badge_index
            if object_id >= len(self.objects) or not self.objects[object_id].present:
                continue
            label = self.sprite_info(self.objects[object_id].sprite_id).label.lower()
            if label == "status help":
                self.low_health = True
            elif label == "status alone":
                self.needs_regroup = True

    def read_status_hud(self, label: str) -> None:
        for part in label.lower().split("|"):
            section = part.strip()
            if section.startswith("carry "):
                self.carried_item = carry_kind_from_label(section)
            elif section.startswith("next "):
                self.objective_hint = section
                if section.startswith("next gather"):
                    tokens = section.split()
                    self.need_wood = token_number(tokens, "w")
                    self.need_stone = token_number(tokens, "s")

    def target_center(
        self,
        state: ObjectState,
        sprite: SpriteInfo,
    ) -> tuple[int, int]:
        bounds = visible_bounds(sprite)
        return (
            self.camera_x + state.x + bounds.x + bounds.w // 2,
            self.camera_y + state.y + bounds.y + bounds.h // 2,
        )

    def scan_world(self) -> tuple[list[bool], list[Target], list[Target], list[Target]]:
        blocked = [False] * (PathGridWidth * PathGridHeight)
        pickups: list[Target] = []
        allies: list[Target] = []
        mobs: list[Target] = []
        for object_id, state in enumerate(self.objects):
            if not state.present:
                continue
            sprite = self.sprite_info(state.sprite_id)
            if not sprite.defined:
                continue
            if (
                sprite.kind == SpriteKind.Player
                and object_id != self.self_object_id
                and PlayerObjectBase <= object_id < MobObjectBase
            ):
                x, y = self.target_center(state, sprite)
                allies.append(
                    Target(True, TargetKind.Regroup, object_id, x, y, "regroup")
                )
            elif sprite.kind == SpriteKind.Terrain:
                bounds = terrain_bounds(sprite)
                mark_blocked(
                    blocked,
                    self.camera_x + state.x + bounds.x,
                    self.camera_y + state.y + bounds.y,
                    bounds.w,
                    bounds.h,
                )
            elif sprite.kind == SpriteKind.Coin:
                x, y = self.target_center(state, sprite)
                kind = target_kind_for_sprite_info(sprite)
                pickups.append(Target(True, kind, object_id, x, y, target_label(kind)))
            elif sprite.kind == SpriteKind.Heart:
                x, y = self.target_center(state, sprite)
                pickups.append(Target(True, TargetKind.Heart, object_id, x, y, "heart"))
            elif sprite.kind in {SpriteKind.Mob, SpriteKind.Troll, SpriteKind.Boss}:
                kind = target_kind_for_sprite_info(sprite)
                x, y = self.target_center(state, sprite)
                mobs.append(Target(True, kind, object_id, x, y, target_label(kind)))
        return blocked, pickups, allies, mobs

    def update_stuck(self) -> None:
        if not self.have_player_sample:
            self.previous_player_x = self.player_world_x
            self.previous_player_y = self.player_world_y
            self.have_player_sample = True
            return
        moved = distance_squared(
            self.player_world_x,
            self.player_world_y,
            self.previous_player_x,
            self.previous_player_y,
        )
        if self.last_mask & MoveMask and moved <= 1:
            self.stuck_frames += 1
        else:
            self.stuck_frames = 0
        self.previous_player_x = self.player_world_x
        self.previous_player_y = self.player_world_y
        if self.stuck_frames >= StuckFrameThreshold:
            self.jiggle_ticks = JiggleDuration
            self.jiggle_mask = random_move_mask(self.rng)
            if self.current_target_id >= 0:
                self.skip_target_id = self.current_target_id
                self.skip_ticks = SkipTargetTicks
            self.stuck_frames = 0
            self.has_explore_goal = False

    def target_score(self, target: Target) -> int:
        distance = manhattan(
            self.player_world_x,
            self.player_world_y,
            target.x,
            target.y,
        )
        if target.kind == TargetKind.Regroup:
            return distance + (
                -120
                if self.needs_regroup and self.low_health
                else -260
                if self.needs_regroup
                else 20
                if self.low_health
                else 340
            )
        if target.kind == TargetKind.Coin:
            return distance + 90
        if target.kind == TargetKind.Heart:
            return distance + (-210 if self.low_health else -40 if self.needs_regroup else 15)
        if target.kind == TargetKind.Wood:
            if self.need_wood > 0:
                return distance - 260
            if self.carried_item == CarryKind.Wood:
                return distance + 170
            return distance - 120
        if target.kind == TargetKind.Food:
            if self.carried_item == CarryKind.Food:
                return distance + (-20 if self.low_health else 90)
            return distance + (
                -150
                if self.low_health or "heal food" in self.objective_hint
                else -115
                if self.needs_regroup
                else -95
            )
        if target.kind == TargetKind.Stone:
            if self.need_stone > 0:
                return distance - 260
            if self.carried_item == CarryKind.Stone:
                return distance + 170
            return distance - 120
        if target.kind == TargetKind.Gold:
            if self.need_stone > 0:
                return distance - 170
            if self.carried_item == CarryKind.Gold:
                return distance + 160
            return distance - 55
        if target.kind == TargetKind.Camp:
            if self.need_wood > 0 or self.need_stone > 0:
                return distance + 120
            if self.objective_hint.startswith("next build camp") or self.objective_hint.startswith("next camp"):
                return distance - 230
            if self.carried_item != CarryKind.None_:
                return distance - 170
            return distance + (-180 if self.low_health or self.needs_regroup else -100)
        if target.kind == TargetKind.Relic:
            if self.objective_hint.startswith("next relic"):
                return distance - 170
            if self.need_wood > 0 or self.need_stone > 0:
                return distance + 120
            return distance - 85
        if target.kind == TargetKind.Waystation:
            return distance + (-165 if self.low_health or self.needs_regroup else -65)
        if target.kind == TargetKind.Rescue:
            return distance + (-120 if self.needs_regroup else -50)
        if target.kind == TargetKind.Shrine:
            return distance - 20
        if target.kind == TargetKind.Gate:
            return distance + (-210 if self.objective_hint.startswith("next open gate") else 10)
        if target.kind == TargetKind.Lair:
            return distance + (
                420 if self.low_health or self.needs_regroup else -45 if distance < 100 else 180
            )
        if target.kind == TargetKind.Mob:
            return distance + (
                340 if self.low_health else 240 if self.needs_regroup else -70 if distance < 90 else 190
            )
        if target.kind == TargetKind.Troll:
            return distance + (
                400 if self.low_health else 280 if self.needs_regroup else -60 if distance < 105 else 230
            )
        if target.kind == TargetKind.Boss:
            return distance + (
                560 if self.low_health else 440 if self.needs_regroup else -45 if distance < 120 else 420
            )
        return distance + 400

    def refresh_explore_goal(self, blocked: list[bool]) -> None:
        if self.has_explore_goal and distance_squared(
            self.player_world_x,
            self.player_world_y,
            self.explore_x,
            self.explore_y,
        ) > GoalArrivalRadius * GoalArrivalRadius:
            return
        area = PathGridWidth * PathGridHeight
        for attempt in range(area):
            index = (self.explore_index + attempt * ExploreStep) % area
            tx = index % PathGridWidth
            ty = index // PathGridWidth
            if is_blocked(blocked, tx, ty):
                continue
            self.explore_index = (index + ExploreStep) % area
            self.explore_x = tile_center_x(tx)
            self.explore_y = tile_center_y(ty)
            self.has_explore_goal = True
            return
        self.explore_x = WorldWidthPixels // 2
        self.explore_y = WorldHeightPixels // 2
        self.has_explore_goal = True

    def choose_target(
        self,
        blocked: list[bool],
        pickups: list[Target],
        allies: list[Target],
        mobs: list[Target],
    ) -> Target:
        result = Target()
        best_score = 2**63 - 1
        for pickup in pickups:
            if self.skip_ticks > 0 and pickup.object_id == self.skip_target_id:
                continue
            score = self.target_score(pickup)
            if score < best_score:
                best_score = score
                result = pickup
        if self.needs_regroup or self.low_health:
            for ally in allies:
                if self.skip_ticks > 0 and ally.object_id == self.skip_target_id:
                    continue
                score = self.target_score(ally)
                if score < best_score:
                    best_score = score
                    result = ally
        for mob in mobs:
            if self.skip_ticks > 0 and mob.object_id == self.skip_target_id:
                continue
            score = self.target_score(mob)
            if score < best_score:
                best_score = score
                result = mob
        if result.found:
            return result
        self.refresh_explore_goal(blocked)
        return Target(
            True,
            TargetKind.Explore,
            -1,
            self.explore_x,
            self.explore_y,
            "explore",
        )

    def nearest_mob(self, mobs: list[Target]) -> Target:
        result = Target()
        best_distance = 2**63 - 1
        for mob in mobs:
            distance = distance_squared(
                self.player_world_x,
                self.player_world_y,
                mob.x,
                mob.y,
            )
            if distance < best_distance:
                best_distance = distance
                result = mob
        return result

    def remember_target(self, target: Target) -> None:
        self.current_target_id = target.object_id
        self.current_target_kind = target.kind
        self.current_target_x = target.x
        self.current_target_y = target.y
        self.current_target_label = target.label
        self.current_target_distance = manhattan(
            self.player_world_x,
            self.player_world_y,
            target.x,
            target.y,
        )

    def update_target_result(
        self,
        pickups: list[Target],
        allies: list[Target],
        mobs: list[Target],
    ) -> None:
        if self.current_target_id < 0:
            return
        if self.current_target_kind in {
            TargetKind.Coin,
            TargetKind.Heart,
            TargetKind.Wood,
            TargetKind.Food,
            TargetKind.Stone,
            TargetKind.Gold,
            TargetKind.Camp,
            TargetKind.Relic,
            TargetKind.Gate,
            TargetKind.Shrine,
            TargetKind.Rescue,
            TargetKind.Lair,
            TargetKind.Waystation,
        }:
            still_present = contains_target(pickups, self.current_target_id)
        elif self.current_target_kind in {
            TargetKind.Mob,
            TargetKind.Troll,
            TargetKind.Boss,
        }:
            still_present = contains_target(mobs, self.current_target_id)
        elif self.current_target_kind == TargetKind.Regroup:
            still_present = contains_target(allies, self.current_target_id)
        else:
            still_present = True
        if still_present:
            return
        if (
            self.current_target_kind == TargetKind.Coin
            and self.current_target_distance < 64
        ):
            self.coin_count += 1
            print(
                f"coin collected id={self.current_target_id}"
                f" total={self.coin_count}",
                flush=True,
            )
        elif (
            self.current_target_kind == TargetKind.Heart
            and self.current_target_distance < 64
        ):
            self.heart_count += 1
            print(
                f"heart collected id={self.current_target_id}"
                f" total={self.heart_count}",
                flush=True,
            )
        elif (
            self.current_target_kind
            in {
                TargetKind.Wood,
                TargetKind.Food,
                TargetKind.Stone,
                TargetKind.Gold,
                TargetKind.Camp,
                TargetKind.Relic,
                TargetKind.Gate,
                TargetKind.Shrine,
                TargetKind.Rescue,
                TargetKind.Lair,
                TargetKind.Waystation,
            }
            and self.current_target_distance < 96
        ):
            print(
                f"objective done kind={self.current_target_kind}"
                f" id={self.current_target_id}",
                flush=True,
            )
        elif (
            self.current_target_kind
            in {TargetKind.Mob, TargetKind.Troll, TargetKind.Boss}
            and self.current_target_distance < 96
        ):
            self.kill_count += 1
            print(
                f"monster down id={self.current_target_id}"
                f" total={self.kill_count}",
                flush=True,
            )
        self.current_target_id = -1

    def steer_mask(self, x: int, y: int) -> int:
        result = 0
        dx = x - self.player_world_x
        dy = y - self.player_world_y
        if abs(dx) > MoveDeadband:
            result |= ButtonLeft if dx < 0 else ButtonRight
        if abs(dy) > MoveDeadband:
            result |= ButtonUp if dy < 0 else ButtonDown
        return result

    def can_attack(self, target: Target) -> bool:
        dx = target.x - self.player_world_x
        dy = target.y - self.player_world_y
        return (
            abs(dx) <= AttackReach
            and abs(dy) <= AttackAlignSlack
        ) or (
            abs(dy) <= AttackReach
            and abs(dx) <= AttackAlignSlack
        )

    def attack_mask(self, target: Target) -> int:
        result = face_mask(
            target.x - self.player_world_x,
            target.y - self.player_world_y,
        )
        if self.attack_cooldown == 0:
            result |= ButtonA
            self.attack_cooldown = AttackCooldownTicks
        return result

    def decide_next_mask(self) -> int:
        self.update_camera()
        self.update_player_position()
        self.update_self_affordances()
        if self.attack_cooldown > 0:
            self.attack_cooldown -= 1
        if self.skip_ticks > 0:
            self.skip_ticks -= 1
            if self.skip_ticks == 0:
                self.skip_target_id = -1
        blocked, pickups, allies, mobs = self.scan_world()
        self.update_target_result(pickups, allies, mobs)
        self.update_stuck()
        if self.jiggle_ticks > 0:
            self.jiggle_ticks -= 1
            self.intent = "unstuck"
            return self.jiggle_mask
        close_mob = self.nearest_mob(mobs)
        if close_mob.found and self.can_attack(close_mob):
            self.remember_target(close_mob)
            self.intent = close_mob.label
            return self.attack_mask(close_mob)
        target = self.choose_target(blocked, pickups, allies, mobs)
        self.remember_target(target)
        self.intent = target.label
        if is_attack_target(target.kind) and self.can_attack(target):
            return self.attack_mask(target)
        step = find_path_step(
            blocked,
            self.player_world_x,
            self.player_world_y,
            target.x,
            target.y,
        )
        if step.found:
            start_tx = clamp_tile_x(self.player_world_x)
            start_ty = clamp_tile_y(self.player_world_y)
            if step.next_tx == start_tx and step.next_ty == start_ty:
                return self.steer_mask(target.x, target.y)
            return self.steer_mask(
                tile_center_x(step.next_tx),
                tile_center_y(step.next_ty),
            )
        if target.object_id >= 0:
            self.skip_target_id = target.object_id
            self.skip_ticks = SkipTargetTicks
        self.has_explore_goal = False
        return self.steer_mask(target.x, target.y)

    def echo_debug(self, mask: int, force: bool = False) -> None:
        if not force and self.frame_tick % 24 != 0:
            return
        print(
            f"step={self.frame_tick}"
            f" keys={mask_summary(mask)}"
            f" pos={self.player_world_x},{self.player_world_y}"
            f" intent={self.intent}"
            f" target={self.current_target_label}#{self.current_target_id}"
            f"@{self.current_target_x},{self.current_target_y}"
            f" d={self.current_target_distance}"
            f" coins={self.coin_count}"
            f" hearts={self.heart_count}"
            f" kills={self.kill_count}",
            flush=True,
        )

    def next_chat(self) -> str:
        if self.frame_tick < self.next_chat_tick:
            return ""
        self.next_chat_tick = self.frame_tick + 144
        result = self.intent.upper()
        if not result or result == self.last_chat:
            return ""
        self.last_chat = result
        return result


def read_u16(data: bytes, offset: int) -> int:
    return data[offset] | (data[offset + 1] << 8)


def read_i16(data: bytes, offset: int) -> int:
    value = read_u16(data, offset)
    if value >= 0x8000:
        value -= 0x10000
    return value


def read_u32(data: bytes, offset: int) -> int:
    return (
        data[offset]
        | (data[offset + 1] << 8)
        | (data[offset + 2] << 16)
        | (data[offset + 3] << 24)
    )


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
        raise ValueError(
            f"snappy length mismatch: expected {expected}, got {len(output)}"
        )
    return bytes(output)


def classify_sprite(sprite_id: int, label: str) -> SpriteKind:
    lower = label.lower()
    if sprite_id == MapSpriteId or lower == "map":
        return SpriteKind.Map
    if PlayerSpriteBase <= sprite_id < PlayerSpriteBase + PlayerSpriteSlots:
        return SpriteKind.Player
    if (
        SelectedPlayerSpriteBase
        <= sprite_id
        < SelectedPlayerSpriteBase + SelectedPlayerSpriteSlots
    ):
        return SpriteKind.Player
    if (
        sprite_id == MobSpriteId
        or lower == "ghost"
        or lower.startswith("wolf")
    ):
        return SpriteKind.Mob
    if sprite_id == TrollSpriteId or lower == "troll" or lower.startswith("goblin"):
        return SpriteKind.Troll
    if sprite_id == BossSpriteId or lower == "pigman" or lower.startswith("bear"):
        return SpriteKind.Boss
    if (
        sprite_id == CoinSpriteId
        or lower == "coin"
        or lower
        in {
            "camp",
            "beacon",
            "final gate",
            "shrine",
            "rescue",
            "lair",
            "waystation",
            "wood",
            "food",
            "stone",
            "gold",
        }
    ):
        return SpriteKind.Coin
    if sprite_id == HeartSpriteId or lower == "heart":
        return SpriteKind.Heart
    if SwooshSpriteBase <= sprite_id < SwooshSpriteBase + SwooshSpriteSlots:
        return SpriteKind.Swoosh
    if TerrainSpriteBase <= sprite_id < TerrainSpriteBase + TerrainSpriteSlots:
        return SpriteKind.Terrain
    if LandmarkSpriteBase <= sprite_id < LandmarkSpriteBase + LandmarkSpriteSlots:
        return SpriteKind.Coin
    if sprite_id == PlayerHudSpriteId:
        return SpriteKind.Hud
    if label:
        return SpriteKind.Text
    return SpriteKind.Unknown


def target_kind_for_sprite(kind: SpriteKind) -> TargetKind:
    if kind == SpriteKind.Troll:
        return TargetKind.Troll
    if kind == SpriteKind.Boss:
        return TargetKind.Boss
    return TargetKind.Mob


def target_kind_for_sprite_info(sprite: SpriteInfo) -> TargetKind:
    return {
        "wood": TargetKind.Wood,
        "food": TargetKind.Food,
        "stone": TargetKind.Stone,
        "gold": TargetKind.Gold,
        "camp": TargetKind.Camp,
        "beacon": TargetKind.Relic,
        "final gate": TargetKind.Gate,
        "shrine": TargetKind.Shrine,
        "rescue": TargetKind.Rescue,
        "lair": TargetKind.Lair,
        "waystation": TargetKind.Waystation,
    }.get(
        sprite.label.lower(),
        TargetKind.Heart
        if sprite.kind == SpriteKind.Heart
        else TargetKind.Coin
        if sprite.kind == SpriteKind.Coin
        else target_kind_for_sprite(sprite.kind),
    )


def target_label(kind: TargetKind) -> str:
    return {
        TargetKind.Explore: "explore",
        TargetKind.Regroup: "regroup",
        TargetKind.Coin: "coin",
        TargetKind.Heart: "heart",
        TargetKind.Wood: "wood",
        TargetKind.Food: "food",
        TargetKind.Stone: "stone",
        TargetKind.Gold: "gold",
        TargetKind.Camp: "camp",
        TargetKind.Relic: "relic",
        TargetKind.Gate: "gate",
        TargetKind.Shrine: "shrine",
        TargetKind.Rescue: "rescue",
        TargetKind.Lair: "lair",
        TargetKind.Waystation: "waypoint",
        TargetKind.Mob: "hunt",
        TargetKind.Troll: "fight",
        TargetKind.Boss: "boss",
    }[kind]


def is_attack_target(kind: TargetKind) -> bool:
    return kind in {
        TargetKind.Wood,
        TargetKind.Food,
        TargetKind.Stone,
        TargetKind.Gold,
        TargetKind.Lair,
        TargetKind.Mob,
        TargetKind.Troll,
        TargetKind.Boss,
    }


def distance_squared(ax: int, ay: int, bx: int, by: int) -> int:
    dx = ax - bx
    dy = ay - by
    return dx * dx + dy * dy


def manhattan(ax: int, ay: int, bx: int, by: int) -> int:
    return abs(ax - bx) + abs(ay - by)


def grid_index(tx: int, ty: int) -> int:
    return ty * PathGridWidth + tx


def in_grid(tx: int, ty: int) -> bool:
    return 0 <= tx < PathGridWidth and 0 <= ty < PathGridHeight


def tile_center_x(tx: int) -> int:
    return tx * PathCellSize + PathCellSize // 2


def tile_center_y(ty: int) -> int:
    return ty * PathCellSize + PathCellSize // 2


def clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


def clamp_tile_x(x: int) -> int:
    return clamp(x // PathCellSize, 0, PathGridWidth - 1)


def clamp_tile_y(y: int) -> int:
    return clamp(y // PathCellSize, 0, PathGridHeight - 1)


def visible_bounds(sprite: SpriteInfo) -> SpriteBounds:
    if (
        sprite.width <= 0
        or sprite.height <= 0
        or len(sprite.pixels) != sprite.width * sprite.height * 4
    ):
        return SpriteBounds(0, 0, sprite.width, sprite.height)
    min_x = sprite.width
    min_y = sprite.height
    max_x = -1
    max_y = -1
    for y in range(sprite.height):
        for x in range(sprite.width):
            offset = (y * sprite.width + x) * 4 + 3
            if sprite.pixels[offset] == 0:
                continue
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    if max_x < min_x or max_y < min_y:
        return SpriteBounds()
    return SpriteBounds(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


def lower_center_bounds(bounds: SpriteBounds) -> SpriteBounds:
    if bounds.w <= 0 or bounds.h <= 0:
        return bounds
    width = max(6, bounds.w // 3)
    height = max(6, bounds.h // 4)
    return SpriteBounds(
        bounds.x + (bounds.w - width) // 2,
        bounds.y + bounds.h - height,
        width,
        height,
    )


def terrain_bounds(sprite: SpriteInfo) -> SpriteBounds:
    bounds = visible_bounds(sprite)
    lower = sprite.label.lower()
    if lower in {"terraintree", "terrainevergreen"}:
        return lower_center_bounds(bounds)
    return bounds


def is_blocked(blocked: list[bool], tx: int, ty: int) -> bool:
    if not in_grid(tx, ty):
        return True
    return blocked[grid_index(tx, ty)]


def mark_blocked(blocked: list[bool], x: int, y: int, w: int, h: int) -> None:
    if w <= 0 or h <= 0:
        return
    min_tx = clamp_tile_x(max(0, x - ObstaclePad))
    min_ty = clamp_tile_y(max(0, y - ObstaclePad))
    max_tx = clamp_tile_x(min(WorldWidthPixels - 1, x + w + ObstaclePad - 1))
    max_ty = clamp_tile_y(min(WorldHeightPixels - 1, y + h + ObstaclePad - 1))
    for ty in range(min_ty, max_ty + 1):
        for tx in range(min_tx, max_tx + 1):
            blocked[grid_index(tx, ty)] = True


def nearest_open_tile(
    blocked: list[bool],
    tx: int,
    ty: int,
) -> tuple[bool, int, int]:
    if in_grid(tx, ty) and not is_blocked(blocked, tx, ty):
        return True, tx, ty
    for radius in range(1, 7):
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                if abs(dx) != radius and abs(dy) != radius:
                    continue
                nx = tx + dx
                ny = ty + dy
                if in_grid(nx, ny) and not is_blocked(blocked, nx, ny):
                    return True, nx, ny
    return False, tx, ty


def heuristic_distance(ax: int, ay: int, bx: int, by: int) -> int:
    return abs(ax - bx) + abs(ay - by)


def reconstruct_step(
    parents: list[int],
    start_index: int,
    goal_index: int,
) -> PathStep:
    path = [goal_index]
    while path[-1] != start_index:
        next_index = parents[path[-1]]
        if next_index < 0 or next_index == path[-1]:
            return PathStep()
        path.append(next_index)
    step_index = path[max(0, len(path) - 1 - PathLookaheadCells)]
    return PathStep(True, step_index % PathGridWidth, step_index // PathGridWidth)


def find_path_step(
    blocked: list[bool],
    start_x: int,
    start_y: int,
    goal_x: int,
    goal_y: int,
) -> PathStep:
    start_tx = clamp_tile_x(start_x)
    start_ty = clamp_tile_y(start_y)
    found_goal, goal_tx, goal_ty = nearest_open_tile(
        blocked,
        clamp_tile_x(goal_x),
        clamp_tile_y(goal_y),
    )
    if not found_goal:
        return PathStep()
    start_index = grid_index(start_tx, start_ty)
    goal_index = grid_index(goal_tx, goal_ty)
    if start_tx == goal_tx and start_ty == goal_ty:
        return PathStep(True, start_tx, start_ty)
    area = PathGridWidth * PathGridHeight
    parents = [-2] * area
    costs = [2**63 - 1] * area
    closed = [False] * area
    parents[start_index] = start_index
    costs[start_index] = 0
    open_set: list[tuple[int, int]] = [
        (heuristic_distance(start_tx, start_ty, goal_tx, goal_ty), start_index)
    ]
    while open_set:
        _, current_index = heapq.heappop(open_set)
        if closed[current_index]:
            continue
        if current_index == goal_index:
            return reconstruct_step(parents, start_index, goal_index)
        closed[current_index] = True
        tx = current_index % PathGridWidth
        ty = current_index // PathGridWidth
        for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            next_tx = tx + dx
            next_ty = ty + dy
            if not in_grid(next_tx, next_ty):
                continue
            if is_blocked(blocked, next_tx, next_ty):
                continue
            next_index = grid_index(next_tx, next_ty)
            if closed[next_index]:
                continue
            tentative = costs[current_index] + 1
            if tentative >= costs[next_index]:
                continue
            costs[next_index] = tentative
            parents[next_index] = current_index
            heapq.heappush(
                open_set,
                (
                    tentative
                    + heuristic_distance(next_tx, next_ty, goal_tx, goal_ty),
                    next_index,
                ),
            )
    return PathStep()


def random_move_mask(rng: random.Random) -> int:
    choice = rng.randrange(4)
    if choice == 0:
        return ButtonUp
    if choice == 1:
        return ButtonDown
    if choice == 2:
        return ButtonLeft
    return ButtonRight


def contains_target(targets: list[Target], object_id: int) -> bool:
    return any(target.object_id == object_id for target in targets)


def face_mask(dx: int, dy: int) -> int:
    if abs(dx) > abs(dy):
        return ButtonLeft if dx < 0 else ButtonRight
    return ButtonUp if dy < 0 else ButtonDown


def player_input_blob(mask: int) -> bytes:
    return bytes([0x84, mask & 0x7F])


def chat_blob(text: str) -> bytes:
    payload = text.encode("ascii", "ignore")
    length = len(payload)
    return bytes([0x81, length & 0xFF, (length >> 8) & 0xFF]) + payload


def mask_summary(mask: int) -> str:
    result = ""
    if mask & ButtonUp:
        result += "U"
    if mask & ButtonDown:
        result += "D"
    if mask & ButtonLeft:
        result += "L"
    if mask & ButtonRight:
        result += "R"
    if mask & ButtonA:
        result += "A"
    if mask & ButtonB:
        result += "B"
    return result or "."


def accept_server_message(message: object, bot: Bot) -> bool:
    if isinstance(message, bytes):
        result = bot.apply_sprite_packet(message)
        if result:
            bot.frame_tick += 1
        return result
    return False


def receive_updates(ws: websocket.WebSocket, bot: Bot) -> bool:
    first = ws.recv()
    result = accept_server_message(first, bot)
    drained = 0
    ws.settimeout(0.0)
    try:
        while drained < MaxDrainMessages:
            try:
                message = ws.recv()
            except (BlockingIOError, websocket.WebSocketTimeoutException):
                break
            if accept_server_message(message, bot):
                result = True
            drained += 1
    finally:
        ws.settimeout(None)
    return result


def run_bot(
    host: str = DefaultHost,
    port: int = PlayerDefaultPort,
    name: str = "konrad",
    chat: bool = False,
    max_steps: int = 0,
) -> None:
    escaped = urllib.parse.quote(name, safe="-_.~")
    url = f"ws://{host}:{port}{PlayerWebSocketPath}"
    if name:
        url += f"?name={escaped}"
    while True:
        try:
            bot = Bot()
            ws = websocket.create_connection(url)
            last_mask = 0xFF
            try:
                while True:
                    if not receive_updates(ws, bot):
                        continue
                    next_mask = bot.decide_next_mask()
                    bot.echo_debug(next_mask, next_mask != last_mask)
                    bot.last_mask = next_mask
                    if next_mask != last_mask:
                        ws.send(
                            player_input_blob(next_mask),
                            opcode=websocket.ABNF.OPCODE_BINARY,
                        )
                        last_mask = next_mask
                    if chat:
                        text = bot.next_chat()
                        if text:
                            ws.send(
                                chat_blob(text),
                                opcode=websocket.ABNF.OPCODE_BINARY,
                            )
                    if max_steps > 0 and bot.frame_tick >= max_steps:
                        bot.echo_debug(next_mask, True)
                        print(
                            f"done steps={bot.frame_tick}"
                            f" coins={bot.coin_count}"
                            f" hearts={bot.heart_count}"
                            f" kills={bot.kill_count}",
                            flush=True,
                        )
                        ws.close()
                        return
            finally:
                ws.close()
        except KeyboardInterrupt:
            raise
        except Exception:
            time.sleep(0.25)


def main() -> None:
    parser = argparse.ArgumentParser(description="Konrad Party Progressor bot.")
    parser.add_argument("--address", default=DefaultHost)
    parser.add_argument("--port", type=int, default=PlayerDefaultPort)
    parser.add_argument("--name", default="konrad")
    parser.add_argument("--chat", action="store_true")
    parser.add_argument("--max-steps", type=int, default=0)
    args = parser.parse_args()
    run_bot(args.address, args.port, args.name, args.chat, args.max_steps)


if __name__ == "__main__":
    main()

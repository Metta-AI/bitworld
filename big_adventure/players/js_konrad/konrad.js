#!/usr/bin/env node
"use strict";

const WebSocket = require("ws");

const PlayerDefaultPort = 2000;
const ScreenWidth = 128;
const ScreenHeight = 128;
const WorldWidthTiles = 32;
const WorldHeightTiles = 32;
const WorldTileSize = 32;
const WorldWidthPixels = WorldWidthTiles * WorldTileSize;
const WorldHeightPixels = WorldHeightTiles * WorldTileSize;
const PlayerWebSocketPath = "/player";
const DefaultHost = "localhost";

const MapSpriteId = 1;
const MapObjectId = 1;
const PlayerSpriteBase = 100;
const SelectedPlayerSpriteBase = 200;
const MobSpriteId = 300;
const BossSpriteId = 301;
const CoinSpriteId = 302;
const HeartSpriteId = 303;
const SwooshSpriteBase = 304;
const TrollSpriteId = 312;
const TerrainSpriteBase = 320;
const PlayerHudSpriteId = 600;
const PlayerObjectBase = 1000;
const MobObjectBase = 2000;

const ButtonUp = 1 << 0;
const ButtonDown = 1 << 1;
const ButtonLeft = 1 << 2;
const ButtonRight = 1 << 3;
const ButtonA = 1 << 5;
const ButtonB = 1 << 6;

const PlayerSpriteSlots = 64;
const SelectedPlayerSpriteSlots = 64;
const SwooshSpriteSlots = 8;
const TerrainSpriteSlots = 5;
const MaxDrainMessages = 256;
const PathCellSize = 8;
const PathGridWidth = Math.floor(WorldWidthPixels / PathCellSize);
const PathGridHeight = Math.floor(WorldHeightPixels / PathCellSize);
const MoveDeadband = 5;
const GoalArrivalRadius = 18;
const AttackReach = 46;
const AttackAlignSlack = 22;
const AttackCooldownTicks = 7;
const ObstaclePad = 8;
const PathLookaheadCells = 4;
const StuckFrameThreshold = 14;
const JiggleDuration = 12;
const SkipTargetTicks = 72;
const ExploreStep = 17;
const MoveMask = ButtonUp | ButtonDown | ButtonLeft | ButtonRight;

const SpriteKind = Object.freeze({
  Unknown: 0,
  Map: 1,
  Player: 2,
  Mob: 3,
  Troll: 4,
  Boss: 5,
  Coin: 6,
  Heart: 7,
  Swoosh: 8,
  Terrain: 9,
  Hud: 10,
  Text: 11,
});

const TargetKind = Object.freeze({
  Explore: 0,
  Coin: 1,
  Heart: 2,
  Mob: 3,
  Troll: 4,
  Boss: 5,
});

class MinHeap {
  constructor() {
    this.items = [];
  }

  get length() {
    return this.items.length;
  }

  less(a, b) {
    if (a.priority === b.priority) return a.index < b.index;
    return a.priority < b.priority;
  }

  push(item) {
    this.items.push(item);
    let i = this.items.length - 1;
    while (i > 0) {
      const parent = Math.floor((i - 1) / 2);
      if (!this.less(this.items[i], this.items[parent])) break;
      [this.items[i], this.items[parent]] = [this.items[parent], this.items[i]];
      i = parent;
    }
  }

  pop() {
    const result = this.items[0];
    const last = this.items.pop();
    if (this.items.length > 0 && last !== undefined) {
      this.items[0] = last;
      let i = 0;
      while (true) {
        const left = i * 2 + 1;
        const right = left + 1;
        let best = i;
        if (left < this.items.length && this.less(this.items[left], this.items[best])) {
          best = left;
        }
        if (right < this.items.length && this.less(this.items[right], this.items[best])) {
          best = right;
        }
        if (best === i) break;
        [this.items[i], this.items[best]] = [this.items[best], this.items[i]];
        i = best;
      }
    }
    return result;
  }
}

class MessageQueue {
  constructor(ws) {
    this.items = [];
    this.waiters = [];
    this.closedError = null;
    ws.on("message", (data, isBinary) => {
      this.push({ data, isBinary });
    });
    ws.on("close", () => {
      this.close(new Error("websocket closed"));
    });
    ws.on("error", (err) => {
      this.close(err);
    });
  }

  push(message) {
    const waiter = this.waiters.shift();
    if (waiter) {
      waiter.resolve(message);
    } else {
      this.items.push(message);
    }
  }

  shift() {
    const item = this.items.shift();
    if (item) return Promise.resolve(item);
    if (this.closedError) return Promise.reject(this.closedError);
    return new Promise((resolve, reject) => {
      this.waiters.push({ resolve, reject });
    });
  }

  tryShift() {
    return this.items.shift() || null;
  }

  close(err) {
    if (this.closedError) return;
    this.closedError = err;
    for (const waiter of this.waiters) waiter.reject(err);
    this.waiters = [];
  }
}

class Bot {
  constructor() {
    this.sprites = [];
    this.objects = [];
    this.cameraX = 0;
    this.cameraY = 0;
    this.playerWorldX = 0;
    this.playerWorldY = 0;
    this.previousPlayerX = 0;
    this.previousPlayerY = 0;
    this.havePlayerSample = false;
    this.selfObjectId = -1;
    this.frameTick = 0;
    this.exploreIndex = Math.floor(Math.random() * PathGridWidth * PathGridHeight);
    this.hasExploreGoal = false;
    this.exploreX = 0;
    this.exploreY = 0;
    this.stuckFrames = 0;
    this.jiggleTicks = 0;
    this.jiggleMask = 0;
    this.attackCooldown = 0;
    this.currentTargetId = -1;
    this.currentTargetKind = TargetKind.Explore;
    this.currentTargetX = 0;
    this.currentTargetY = 0;
    this.currentTargetDistance = 0;
    this.currentTargetLabel = "";
    this.skipTargetId = -1;
    this.skipTicks = 0;
    this.coinCount = 0;
    this.heartCount = 0;
    this.killCount = 0;
    this.intent = "";
    this.lastMask = 0;
    this.nextChatTick = 72;
    this.lastChat = "";
  }

  ensureSprite(spriteId) {
    while (spriteId >= this.sprites.length) this.sprites.push(makeSpriteInfo());
  }

  ensureObject(objectId) {
    while (objectId >= this.objects.length) this.objects.push(makeObjectState());
  }

  spriteInfo(spriteId) {
    if (spriteId >= 0 && spriteId < this.sprites.length) return this.sprites[spriteId];
    return makeSpriteInfo();
  }

  applySpritePacket(packet) {
    let offset = 0;
    while (offset < packet.length) {
      const messageType = packet[offset];
      offset += 1;
      if (messageType === 0x01) {
        if (offset + 10 > packet.length) return false;
        const spriteId = readU16(packet, offset);
        const width = readU16(packet, offset + 2);
        const height = readU16(packet, offset + 4);
        const compressedLen = readU32(packet, offset + 6);
        offset += 10;
        if (offset + compressedLen + 2 > packet.length) return false;
        const compressed = packet.subarray(offset, offset + compressedLen);
        offset += compressedLen;
        const labelLen = readU16(packet, offset);
        offset += 2;
        if (offset + labelLen > packet.length) return false;
        const label = packet.subarray(offset, offset + labelLen).toString("utf8");
        offset += labelLen;
        let pixels;
        try {
          pixels = compressedLen > 0 ? snappyDecompress(compressed) : new Uint8Array(0);
        } catch (_err) {
          return false;
        }
        if (pixels.length !== width * height * 4) pixels = new Uint8Array(0);
        this.ensureSprite(spriteId);
        this.sprites[spriteId] = {
          defined: true,
          width,
          height,
          label,
          kind: classifySprite(spriteId, label),
          pixels,
        };
      } else if (messageType === 0x02) {
        if (offset + 11 > packet.length) return false;
        const objectId = readU16(packet, offset);
        const x = readI16(packet, offset + 2);
        const y = readI16(packet, offset + 4);
        const z = readI16(packet, offset + 6);
        const layer = packet[offset + 8];
        const spriteId = readU16(packet, offset + 9);
        offset += 11;
        this.ensureObject(objectId);
        this.objects[objectId] = {
          present: true,
          x,
          y,
          z,
          layer,
          spriteId,
        };
      } else if (messageType === 0x03) {
        if (offset + 2 > packet.length) return false;
        const objectId = readU16(packet, offset);
        offset += 2;
        if (objectId >= 0 && objectId < this.objects.length) {
          this.objects[objectId].present = false;
        }
      } else if (messageType === 0x04) {
        for (const item of this.objects) item.present = false;
      } else if (messageType === 0x05) {
        if (offset + 5 > packet.length) return false;
        offset += 5;
      } else if (messageType === 0x06) {
        if (offset + 3 > packet.length) return false;
        offset += 3;
      } else {
        return false;
      }
    }
    return true;
  }

  updateCamera() {
    if (MapObjectId < this.objects.length && this.objects[MapObjectId].present) {
      this.cameraX = -this.objects[MapObjectId].x;
      this.cameraY = -this.objects[MapObjectId].y;
    }
  }

  updatePlayerPosition() {
    let bestDistance = Number.MAX_SAFE_INTEGER;
    let bestX = this.cameraX + Math.floor(ScreenWidth / 2);
    let bestY = this.cameraY + Math.floor(ScreenHeight / 2);
    let bestId = -1;
    for (let objectId = 0; objectId < this.objects.length; objectId++) {
      const state = this.objects[objectId];
      if (!state.present) continue;
      if (objectId < PlayerObjectBase || objectId >= MobObjectBase) continue;
      const sprite = this.spriteInfo(state.spriteId);
      if (sprite.kind !== SpriteKind.Player) continue;
      const screenX = state.x + Math.floor(sprite.width / 2);
      const screenY = state.y + Math.floor(sprite.height / 2);
      const distance = distanceSquared(
        screenX,
        screenY,
        Math.floor(ScreenWidth / 2),
        Math.floor(ScreenHeight / 2),
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        bestX = this.cameraX + screenX;
        bestY = this.cameraY + screenY;
        bestId = objectId;
      }
    }
    this.playerWorldX = bestX;
    this.playerWorldY = bestY;
    this.selfObjectId = bestId;
  }

  targetCenter(state, sprite) {
    const bounds = visibleBounds(sprite);
    return {
      x: this.cameraX + state.x + bounds.x + Math.floor(bounds.w / 2),
      y: this.cameraY + state.y + bounds.y + Math.floor(bounds.h / 2),
    };
  }

  scanWorld() {
    const blocked = new Array(PathGridWidth * PathGridHeight).fill(false);
    const pickups = [];
    const mobs = [];
    for (let objectId = 0; objectId < this.objects.length; objectId++) {
      const state = this.objects[objectId];
      if (!state.present) continue;
      const sprite = this.spriteInfo(state.spriteId);
      if (!sprite.defined) continue;
      if (sprite.kind === SpriteKind.Terrain) {
        const bounds = terrainBounds(sprite);
        markBlocked(
          blocked,
          this.cameraX + state.x + bounds.x,
          this.cameraY + state.y + bounds.y,
          bounds.w,
          bounds.h,
        );
      } else if (sprite.kind === SpriteKind.Coin) {
        const center = this.targetCenter(state, sprite);
        pickups.push(makeTarget(true, TargetKind.Coin, objectId, center.x, center.y, "coin"));
      } else if (sprite.kind === SpriteKind.Heart) {
        const center = this.targetCenter(state, sprite);
        pickups.push(makeTarget(true, TargetKind.Heart, objectId, center.x, center.y, "heart"));
      } else if (
        sprite.kind === SpriteKind.Mob ||
        sprite.kind === SpriteKind.Troll ||
        sprite.kind === SpriteKind.Boss
      ) {
        const kind = targetKindForSprite(sprite.kind);
        const center = this.targetCenter(state, sprite);
        mobs.push(makeTarget(true, kind, objectId, center.x, center.y, targetLabel(kind)));
      }
    }
    return { blocked, pickups, mobs };
  }

  updateStuck() {
    if (!this.havePlayerSample) {
      this.previousPlayerX = this.playerWorldX;
      this.previousPlayerY = this.playerWorldY;
      this.havePlayerSample = true;
      return;
    }
    const moved = distanceSquared(
      this.playerWorldX,
      this.playerWorldY,
      this.previousPlayerX,
      this.previousPlayerY,
    );
    if ((this.lastMask & MoveMask) !== 0 && moved <= 1) {
      this.stuckFrames += 1;
    } else {
      this.stuckFrames = 0;
    }
    this.previousPlayerX = this.playerWorldX;
    this.previousPlayerY = this.playerWorldY;
    if (this.stuckFrames >= StuckFrameThreshold) {
      this.jiggleTicks = JiggleDuration;
      this.jiggleMask = randomMoveMask();
      if (this.currentTargetId >= 0) {
        this.skipTargetId = this.currentTargetId;
        this.skipTicks = SkipTargetTicks;
      }
      this.stuckFrames = 0;
      this.hasExploreGoal = false;
    }
  }

  targetScore(target) {
    const distance = manhattan(
      this.playerWorldX,
      this.playerWorldY,
      target.x,
      target.y,
    );
    switch (target.kind) {
      case TargetKind.Coin:
        return distance;
      case TargetKind.Heart:
        return distance + 35;
      case TargetKind.Mob:
        return distance + (distance < 90 ? -95 : 130);
      case TargetKind.Troll:
        return distance + (distance < 105 ? -85 : 155);
      case TargetKind.Boss:
        return distance + (distance < 120 ? -70 : 220);
      default:
        return distance + 400;
    }
  }

  refreshExploreGoal(blocked) {
    if (
      this.hasExploreGoal &&
      distanceSquared(
        this.playerWorldX,
        this.playerWorldY,
        this.exploreX,
        this.exploreY,
      ) > GoalArrivalRadius * GoalArrivalRadius
    ) {
      return;
    }
    const area = PathGridWidth * PathGridHeight;
    for (let attempt = 0; attempt < area; attempt++) {
      const index = (this.exploreIndex + attempt * ExploreStep) % area;
      const tx = index % PathGridWidth;
      const ty = Math.floor(index / PathGridWidth);
      if (isBlocked(blocked, tx, ty)) continue;
      this.exploreIndex = (index + ExploreStep) % area;
      this.exploreX = tileCenterX(tx);
      this.exploreY = tileCenterY(ty);
      this.hasExploreGoal = true;
      return;
    }
    this.exploreX = Math.floor(WorldWidthPixels / 2);
    this.exploreY = Math.floor(WorldHeightPixels / 2);
    this.hasExploreGoal = true;
  }

  chooseTarget(blocked, pickups, mobs) {
    let result = makeTarget();
    let bestScore = Number.MAX_SAFE_INTEGER;
    for (const pickup of pickups) {
      if (this.skipTicks > 0 && pickup.objectId === this.skipTargetId) continue;
      const score = this.targetScore(pickup);
      if (score < bestScore) {
        bestScore = score;
        result = pickup;
      }
    }
    for (const mob of mobs) {
      if (this.skipTicks > 0 && mob.objectId === this.skipTargetId) continue;
      const score = this.targetScore(mob);
      if (score < bestScore) {
        bestScore = score;
        result = mob;
      }
    }
    if (result.found) return result;
    this.refreshExploreGoal(blocked);
    return makeTarget(
      true,
      TargetKind.Explore,
      -1,
      this.exploreX,
      this.exploreY,
      "explore",
    );
  }

  nearestMob(mobs) {
    let result = makeTarget();
    let bestDistance = Number.MAX_SAFE_INTEGER;
    for (const mob of mobs) {
      const distance = distanceSquared(
        this.playerWorldX,
        this.playerWorldY,
        mob.x,
        mob.y,
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        result = mob;
      }
    }
    return result;
  }

  rememberTarget(target) {
    this.currentTargetId = target.objectId;
    this.currentTargetKind = target.kind;
    this.currentTargetX = target.x;
    this.currentTargetY = target.y;
    this.currentTargetLabel = target.label;
    this.currentTargetDistance = manhattan(
      this.playerWorldX,
      this.playerWorldY,
      target.x,
      target.y,
    );
  }

  updateTargetResult(pickups, mobs) {
    if (this.currentTargetId < 0) return;
    let stillPresent = true;
    if (this.currentTargetKind === TargetKind.Coin || this.currentTargetKind === TargetKind.Heart) {
      stillPresent = containsTarget(pickups, this.currentTargetId);
    } else if (
      this.currentTargetKind === TargetKind.Mob ||
      this.currentTargetKind === TargetKind.Troll ||
      this.currentTargetKind === TargetKind.Boss
    ) {
      stillPresent = containsTarget(mobs, this.currentTargetId);
    }
    if (stillPresent) return;
    if (this.currentTargetKind === TargetKind.Coin && this.currentTargetDistance < 64) {
      this.coinCount += 1;
      console.log(`coin collected id=${this.currentTargetId} total=${this.coinCount}`);
    } else if (this.currentTargetKind === TargetKind.Heart && this.currentTargetDistance < 64) {
      this.heartCount += 1;
      console.log(`heart collected id=${this.currentTargetId} total=${this.heartCount}`);
    } else if (
      (
        this.currentTargetKind === TargetKind.Mob ||
        this.currentTargetKind === TargetKind.Troll ||
        this.currentTargetKind === TargetKind.Boss
      ) &&
      this.currentTargetDistance < 96
    ) {
      this.killCount += 1;
      console.log(`monster down id=${this.currentTargetId} total=${this.killCount}`);
    }
    this.currentTargetId = -1;
  }

  steerMask(x, y) {
    let result = 0;
    const dx = x - this.playerWorldX;
    const dy = y - this.playerWorldY;
    if (Math.abs(dx) > MoveDeadband) result |= dx < 0 ? ButtonLeft : ButtonRight;
    if (Math.abs(dy) > MoveDeadband) result |= dy < 0 ? ButtonUp : ButtonDown;
    return result;
  }

  canAttack(target) {
    const dx = target.x - this.playerWorldX;
    const dy = target.y - this.playerWorldY;
    return (
      Math.abs(dx) <= AttackReach &&
      Math.abs(dy) <= AttackAlignSlack
    ) || (
      Math.abs(dy) <= AttackReach &&
      Math.abs(dx) <= AttackAlignSlack
    );
  }

  attackMask(target) {
    let result = faceMask(target.x - this.playerWorldX, target.y - this.playerWorldY);
    if (this.attackCooldown === 0) {
      result |= ButtonA;
      this.attackCooldown = AttackCooldownTicks;
    }
    return result;
  }

  decideNextMask() {
    this.updateCamera();
    this.updatePlayerPosition();
    if (this.attackCooldown > 0) this.attackCooldown -= 1;
    if (this.skipTicks > 0) {
      this.skipTicks -= 1;
      if (this.skipTicks === 0) this.skipTargetId = -1;
    }
    const { blocked, pickups, mobs } = this.scanWorld();
    this.updateTargetResult(pickups, mobs);
    this.updateStuck();
    if (this.jiggleTicks > 0) {
      this.jiggleTicks -= 1;
      this.intent = "unstuck";
      return this.jiggleMask;
    }
    const closeMob = this.nearestMob(mobs);
    if (closeMob.found && this.canAttack(closeMob)) {
      this.rememberTarget(closeMob);
      this.intent = closeMob.label;
      return this.attackMask(closeMob);
    }
    const target = this.chooseTarget(blocked, pickups, mobs);
    this.rememberTarget(target);
    this.intent = target.label;
    if (
      (
        target.kind === TargetKind.Mob ||
        target.kind === TargetKind.Troll ||
        target.kind === TargetKind.Boss
      ) &&
      this.canAttack(target)
    ) {
      return this.attackMask(target);
    }
    const step = findPathStep(
      blocked,
      this.playerWorldX,
      this.playerWorldY,
      target.x,
      target.y,
    );
    if (step.found) {
      const startTx = clampTileX(this.playerWorldX);
      const startTy = clampTileY(this.playerWorldY);
      if (step.nextTx === startTx && step.nextTy === startTy) {
        return this.steerMask(target.x, target.y);
      }
      return this.steerMask(tileCenterX(step.nextTx), tileCenterY(step.nextTy));
    }
    if (target.objectId >= 0) {
      this.skipTargetId = target.objectId;
      this.skipTicks = SkipTargetTicks;
    }
    this.hasExploreGoal = false;
    return this.steerMask(target.x, target.y);
  }

  echoDebug(mask, force = false) {
    if (!force && this.frameTick % 24 !== 0) return;
    console.log(
      `step=${this.frameTick}` +
      ` keys=${maskSummary(mask)}` +
      ` pos=${this.playerWorldX},${this.playerWorldY}` +
      ` intent=${this.intent}` +
      ` target=${this.currentTargetLabel}#${this.currentTargetId}` +
      `@${this.currentTargetX},${this.currentTargetY}` +
      ` d=${this.currentTargetDistance}` +
      ` coins=${this.coinCount}` +
      ` hearts=${this.heartCount}` +
      ` kills=${this.killCount}`,
    );
  }

  nextChat() {
    if (this.frameTick < this.nextChatTick) return "";
    this.nextChatTick = this.frameTick + 144;
    const result = this.intent.toUpperCase();
    if (!result || result === this.lastChat) return "";
    this.lastChat = result;
    return result;
  }
}

function makeSpriteInfo() {
  return {
    defined: false,
    width: 0,
    height: 0,
    label: "",
    kind: SpriteKind.Unknown,
    pixels: new Uint8Array(0),
  };
}

function makeObjectState() {
  return {
    present: false,
    x: 0,
    y: 0,
    z: 0,
    layer: 0,
    spriteId: 0,
  };
}

function makeTarget(
  found = false,
  kind = TargetKind.Explore,
  objectId = -1,
  x = 0,
  y = 0,
  label = "",
) {
  return { found, kind, objectId, x, y, label };
}

function readU16(data, offset) {
  return data[offset] | (data[offset + 1] << 8);
}

function readI16(data, offset) {
  const value = readU16(data, offset);
  return value >= 0x8000 ? value - 0x10000 : value;
}

function readU32(data, offset) {
  return (
    data[offset] |
    (data[offset + 1] << 8) |
    (data[offset + 2] << 16) |
    (data[offset + 3] << 24)
  ) >>> 0;
}

function snappyDecompress(data) {
  let index = 0;
  let expected = 0;
  let shift = 0;
  while (true) {
    if (index >= data.length) throw new Error("truncated snappy length");
    const byte = data[index++];
    expected |= (byte & 0x7f) << shift;
    if (byte < 128) break;
    shift += 7;
  }
  const output = new Uint8Array(expected);
  let outLen = 0;
  while (index < data.length) {
    const tag = data[index++];
    const tagType = tag & 0x03;
    if (tagType === 0) {
      const lengthCode = tag >> 2;
      let length;
      if (lengthCode < 60) {
        length = lengthCode + 1;
      } else {
        const extra = lengthCode - 59;
        if (index + extra > data.length) throw new Error("truncated snappy literal length");
        length = 1;
        for (let i = 0; i < extra; i++) length += data[index++] << (i * 8);
      }
      if (index + length > data.length) throw new Error("truncated snappy literal");
      if (outLen + length > output.length) throw new Error("snappy literal overflow");
      output.set(data.subarray(index, index + length), outLen);
      outLen += length;
      index += length;
      continue;
    }
    let length;
    let offset;
    if (tagType === 1) {
      if (index >= data.length) throw new Error("truncated snappy copy1");
      length = ((tag >> 2) & 0x07) + 4;
      offset = ((tag & 0xe0) << 3) | data[index++];
    } else if (tagType === 2) {
      if (index + 2 > data.length) throw new Error("truncated snappy copy2");
      length = (tag >> 2) + 1;
      offset = readU16(data, index);
      index += 2;
    } else {
      if (index + 4 > data.length) throw new Error("truncated snappy copy4");
      length = (tag >> 2) + 1;
      offset = readU32(data, index);
      index += 4;
    }
    if (offset <= 0 || offset > outLen) throw new Error("invalid snappy copy offset");
    if (outLen + length > output.length) throw new Error("snappy copy overflow");
    for (let i = 0; i < length; i++) {
      output[outLen] = output[outLen - offset];
      outLen += 1;
    }
  }
  if (outLen !== expected) {
    throw new Error(`snappy length mismatch: expected ${expected}, got ${outLen}`);
  }
  return output;
}

function classifySprite(spriteId, label) {
  const lower = label.toLowerCase();
  if (spriteId === MapSpriteId || lower === "map") return SpriteKind.Map;
  if (spriteId >= PlayerSpriteBase && spriteId < PlayerSpriteBase + PlayerSpriteSlots) {
    return SpriteKind.Player;
  }
  if (
    spriteId >= SelectedPlayerSpriteBase &&
    spriteId < SelectedPlayerSpriteBase + SelectedPlayerSpriteSlots
  ) {
    return SpriteKind.Player;
  }
  if (spriteId === MobSpriteId || lower === "ghost") return SpriteKind.Mob;
  if (spriteId === TrollSpriteId || lower === "troll") return SpriteKind.Troll;
  if (spriteId === BossSpriteId || lower === "pigman") return SpriteKind.Boss;
  if (spriteId === CoinSpriteId || lower === "coin") return SpriteKind.Coin;
  if (spriteId === HeartSpriteId || lower === "heart") return SpriteKind.Heart;
  if (spriteId >= SwooshSpriteBase && spriteId < SwooshSpriteBase + SwooshSpriteSlots) {
    return SpriteKind.Swoosh;
  }
  if (spriteId >= TerrainSpriteBase && spriteId < TerrainSpriteBase + TerrainSpriteSlots) {
    return SpriteKind.Terrain;
  }
  if (spriteId === PlayerHudSpriteId) return SpriteKind.Hud;
  if (label.length > 0) return SpriteKind.Text;
  return SpriteKind.Unknown;
}

function targetKindForSprite(kind) {
  if (kind === SpriteKind.Troll) return TargetKind.Troll;
  if (kind === SpriteKind.Boss) return TargetKind.Boss;
  return TargetKind.Mob;
}

function targetLabel(kind) {
  switch (kind) {
    case TargetKind.Explore:
      return "explore";
    case TargetKind.Coin:
      return "coin";
    case TargetKind.Heart:
      return "heart";
    case TargetKind.Mob:
      return "hunt";
    case TargetKind.Troll:
      return "fight";
    case TargetKind.Boss:
      return "boss";
    default:
      return "";
  }
}

function distanceSquared(ax, ay, bx, by) {
  const dx = ax - bx;
  const dy = ay - by;
  return dx * dx + dy * dy;
}

function manhattan(ax, ay, bx, by) {
  return Math.abs(ax - bx) + Math.abs(ay - by);
}

function gridIndex(tx, ty) {
  return ty * PathGridWidth + tx;
}

function inGrid(tx, ty) {
  return tx >= 0 && ty >= 0 && tx < PathGridWidth && ty < PathGridHeight;
}

function tileCenterX(tx) {
  return tx * PathCellSize + Math.floor(PathCellSize / 2);
}

function tileCenterY(ty) {
  return ty * PathCellSize + Math.floor(PathCellSize / 2);
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value));
}

function clampTileX(x) {
  return clamp(Math.trunc(x / PathCellSize), 0, PathGridWidth - 1);
}

function clampTileY(y) {
  return clamp(Math.trunc(y / PathCellSize), 0, PathGridHeight - 1);
}

function visibleBounds(sprite) {
  if (
    sprite.width <= 0 ||
    sprite.height <= 0 ||
    sprite.pixels.length !== sprite.width * sprite.height * 4
  ) {
    return { x: 0, y: 0, w: sprite.width, h: sprite.height };
  }
  let minX = sprite.width;
  let minY = sprite.height;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < sprite.height; y++) {
    for (let x = 0; x < sprite.width; x++) {
      const offset = (y * sprite.width + x) * 4 + 3;
      if (sprite.pixels[offset] === 0) continue;
      minX = Math.min(minX, x);
      minY = Math.min(minY, y);
      maxX = Math.max(maxX, x);
      maxY = Math.max(maxY, y);
    }
  }
  if (maxX < minX || maxY < minY) return { x: 0, y: 0, w: 0, h: 0 };
  return { x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1 };
}

function lowerCenterBounds(bounds) {
  if (bounds.w <= 0 || bounds.h <= 0) return bounds;
  const width = Math.max(6, Math.floor(bounds.w / 3));
  const height = Math.max(6, Math.floor(bounds.h / 4));
  return {
    x: bounds.x + Math.floor((bounds.w - width) / 2),
    y: bounds.y + bounds.h - height,
    w: width,
    h: height,
  };
}

function terrainBounds(sprite) {
  const bounds = visibleBounds(sprite);
  const lower = sprite.label.toLowerCase();
  if (lower === "terraintree" || lower === "terrainevergreen") {
    return lowerCenterBounds(bounds);
  }
  return bounds;
}

function isBlocked(blocked, tx, ty) {
  if (!inGrid(tx, ty)) return true;
  return blocked[gridIndex(tx, ty)];
}

function markBlocked(blocked, x, y, w, h) {
  if (w <= 0 || h <= 0) return;
  const minTx = clampTileX(Math.max(0, x - ObstaclePad));
  const minTy = clampTileY(Math.max(0, y - ObstaclePad));
  const maxTx = clampTileX(Math.min(WorldWidthPixels - 1, x + w + ObstaclePad - 1));
  const maxTy = clampTileY(Math.min(WorldHeightPixels - 1, y + h + ObstaclePad - 1));
  for (let ty = minTy; ty <= maxTy; ty++) {
    for (let tx = minTx; tx <= maxTx; tx++) {
      blocked[gridIndex(tx, ty)] = true;
    }
  }
}

function nearestOpenTile(blocked, tx, ty) {
  if (inGrid(tx, ty) && !isBlocked(blocked, tx, ty)) {
    return { found: true, tx, ty };
  }
  for (let radius = 1; radius <= 6; radius++) {
    for (let dy = -radius; dy <= radius; dy++) {
      for (let dx = -radius; dx <= radius; dx++) {
        if (Math.abs(dx) !== radius && Math.abs(dy) !== radius) continue;
        const nx = tx + dx;
        const ny = ty + dy;
        if (inGrid(nx, ny) && !isBlocked(blocked, nx, ny)) {
          return { found: true, tx: nx, ty: ny };
        }
      }
    }
  }
  return { found: false, tx, ty };
}

function heuristicDistance(ax, ay, bx, by) {
  return Math.abs(ax - bx) + Math.abs(ay - by);
}

function reconstructStep(parents, startIndex, goalIndex) {
  const path = [goalIndex];
  while (path[path.length - 1] !== startIndex) {
    const nextIndex = parents[path[path.length - 1]];
    if (nextIndex < 0 || nextIndex === path[path.length - 1]) {
      return { found: false, nextTx: 0, nextTy: 0 };
    }
    path.push(nextIndex);
  }
  const stepIndex = path[Math.max(0, path.length - 1 - PathLookaheadCells)];
  return {
    found: true,
    nextTx: stepIndex % PathGridWidth,
    nextTy: Math.floor(stepIndex / PathGridWidth),
  };
}

function findPathStep(blocked, startX, startY, goalX, goalY) {
  const startTx = clampTileX(startX);
  const startTy = clampTileY(startY);
  const openGoal = nearestOpenTile(blocked, clampTileX(goalX), clampTileY(goalY));
  if (!openGoal.found) return { found: false, nextTx: 0, nextTy: 0 };
  const goalTx = openGoal.tx;
  const goalTy = openGoal.ty;
  const startIndex = gridIndex(startTx, startTy);
  const goalIndex = gridIndex(goalTx, goalTy);
  if (startTx === goalTx && startTy === goalTy) {
    return { found: true, nextTx: startTx, nextTy: startTy };
  }
  const area = PathGridWidth * PathGridHeight;
  const parents = new Int32Array(area);
  const costs = new Int32Array(area);
  const closed = new Uint8Array(area);
  parents.fill(-2);
  costs.fill(0x3fffffff);
  parents[startIndex] = startIndex;
  costs[startIndex] = 0;
  const openSet = new MinHeap();
  openSet.push({
    priority: heuristicDistance(startTx, startTy, goalTx, goalTy),
    index: startIndex,
  });
  while (openSet.length > 0) {
    const current = openSet.pop();
    if (closed[current.index]) continue;
    if (current.index === goalIndex) {
      return reconstructStep(parents, startIndex, goalIndex);
    }
    closed[current.index] = 1;
    const tx = current.index % PathGridWidth;
    const ty = Math.floor(current.index / PathGridWidth);
    for (const [dx, dy] of [[-1, 0], [1, 0], [0, -1], [0, 1]]) {
      const nextTx = tx + dx;
      const nextTy = ty + dy;
      if (!inGrid(nextTx, nextTy)) continue;
      if (isBlocked(blocked, nextTx, nextTy)) continue;
      const nextIndex = gridIndex(nextTx, nextTy);
      if (closed[nextIndex]) continue;
      const tentative = costs[current.index] + 1;
      if (tentative >= costs[nextIndex]) continue;
      costs[nextIndex] = tentative;
      parents[nextIndex] = current.index;
      openSet.push({
        priority: tentative + heuristicDistance(nextTx, nextTy, goalTx, goalTy),
        index: nextIndex,
      });
    }
  }
  return { found: false, nextTx: 0, nextTy: 0 };
}

function randomMoveMask() {
  switch (Math.floor(Math.random() * 4)) {
    case 0:
      return ButtonUp;
    case 1:
      return ButtonDown;
    case 2:
      return ButtonLeft;
    default:
      return ButtonRight;
  }
}

function containsTarget(targets, objectId) {
  return targets.some((target) => target.objectId === objectId);
}

function faceMask(dx, dy) {
  if (Math.abs(dx) > Math.abs(dy)) return dx < 0 ? ButtonLeft : ButtonRight;
  return dy < 0 ? ButtonUp : ButtonDown;
}

function playerInputBlob(mask) {
  return Buffer.from([0x84, mask & 0x7f]);
}

function chatBlob(text) {
  const payload = Buffer.from(text, "ascii");
  return Buffer.concat([
    Buffer.from([0x81, payload.length & 0xff, (payload.length >> 8) & 0xff]),
    payload,
  ]);
}

function maskSummary(mask) {
  let result = "";
  if ((mask & ButtonUp) !== 0) result += "U";
  if ((mask & ButtonDown) !== 0) result += "D";
  if ((mask & ButtonLeft) !== 0) result += "L";
  if ((mask & ButtonRight) !== 0) result += "R";
  if ((mask & ButtonA) !== 0) result += "A";
  if ((mask & ButtonB) !== 0) result += "B";
  return result || ".";
}

function acceptServerMessage(message, bot) {
  if (!message.isBinary) return false;
  const packet = Buffer.isBuffer(message.data) ? message.data : Buffer.from(message.data);
  const result = bot.applySpritePacket(packet);
  if (result) bot.frameTick += 1;
  return result;
}

async function receiveUpdates(queue, bot) {
  const first = await queue.shift();
  let result = acceptServerMessage(first, bot);
  let drained = 0;
  while (drained < MaxDrainMessages) {
    const message = queue.tryShift();
    if (!message) break;
    if (acceptServerMessage(message, bot)) result = true;
    drained += 1;
  }
  return result;
}

function connectWebSocket(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    let settled = false;
    ws.once("open", () => {
      settled = true;
      resolve(ws);
    });
    ws.once("error", (err) => {
      if (!settled) {
        settled = true;
        reject(err);
      }
    });
  });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function runBot(
  host = DefaultHost,
  port = PlayerDefaultPort,
  name = "konrad",
  chat = false,
  maxSteps = 0,
) {
  let url = `ws://${host}:${port}${PlayerWebSocketPath}`;
  if (name.length > 0) url += `?name=${encodeURIComponent(name)}`;
  while (true) {
    let ws = null;
    try {
      const bot = new Bot();
      ws = await connectWebSocket(url);
      const queue = new MessageQueue(ws);
      let lastMask = 0xff;
      while (true) {
        if (!(await receiveUpdates(queue, bot))) continue;
        const nextMask = bot.decideNextMask();
        bot.echoDebug(nextMask, nextMask !== lastMask);
        bot.lastMask = nextMask;
        if (nextMask !== lastMask) {
          ws.send(playerInputBlob(nextMask), { binary: true });
          lastMask = nextMask;
        }
        if (chat) {
          const text = bot.nextChat();
          if (text.length > 0) ws.send(chatBlob(text), { binary: true });
        }
        if (maxSteps > 0 && bot.frameTick >= maxSteps) {
          bot.echoDebug(nextMask, true);
          console.log(
            `done steps=${bot.frameTick}` +
            ` coins=${bot.coinCount}` +
            ` hearts=${bot.heartCount}` +
            ` kills=${bot.killCount}`,
          );
          ws.close();
          return;
        }
      }
    } catch (_err) {
      if (ws) ws.close();
      await sleep(250);
    }
  }
}

function readOption(argv, index) {
  const arg = argv[index];
  const equal = arg.indexOf("=");
  if (equal >= 0) return { value: arg.slice(equal + 1), next: index };
  return { value: argv[index + 1] || "", next: index + 1 };
}

function parseArgs(argv) {
  const args = {
    address: DefaultHost,
    port: PlayerDefaultPort,
    name: "konrad",
    chat: false,
    maxSteps: 0,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--chat") {
      args.chat = true;
    } else if (arg === "--address" || arg.startsWith("--address=")) {
      const parsed = readOption(argv, i);
      args.address = parsed.value;
      i = parsed.next;
    } else if (arg === "--port" || arg.startsWith("--port=")) {
      const parsed = readOption(argv, i);
      args.port = Number.parseInt(parsed.value, 10);
      i = parsed.next;
    } else if (arg === "--name" || arg.startsWith("--name=")) {
      const parsed = readOption(argv, i);
      args.name = parsed.value;
      i = parsed.next;
    } else if (arg === "--max-steps" || arg.startsWith("--max-steps=")) {
      const parsed = readOption(argv, i);
      args.maxSteps = Number.parseInt(parsed.value, 10);
      i = parsed.next;
    }
  }
  return args;
}

if (require.main === module) {
  const args = parseArgs(process.argv.slice(2));
  runBot(args.address, args.port, args.name, args.chat, args.maxSteps).catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

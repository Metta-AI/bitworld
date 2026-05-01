import { writeFileSync, readFileSync, openSync, writeSync, closeSync } from "fs";
import { TARGET_FPS } from "./game/constants.js";
import { decodeInputMask, emptyInput } from "./game/protocol.js";
import type { InputState } from "./game/types.js";

const REPLAY_MAGIC = "BITWORLD";
const FORMAT_VERSION = 1;
const GAME_NAME = "PersephonesEscape";
const GAME_VERSION = "0.1";

const RECORD_TICK_HASH = 0;
const RECORD_INPUT = 1;
const RECORD_JOIN = 2;
const RECORD_LEAVE = 3;

function tickTime(tick: number): number {
  return Math.floor((tick * 1000) / TARGET_FPS);
}

// ---------------------------------------------------------------------------
// Binary writing helpers
// ---------------------------------------------------------------------------

function writeU8(buf: number[], v: number) { buf.push(v & 0xff); }
function writeU16(buf: number[], v: number) { buf.push(v & 0xff, (v >> 8) & 0xff); }
function writeU32(buf: number[], v: number) {
  for (let s = 0; s < 32; s += 8) buf.push((v >>> s) & 0xff);
}
function writeBigU64(buf: number[], v: bigint) {
  for (let s = 0n; s < 64n; s += 8n) buf.push(Number((v >> s) & 0xffn));
}
function writeString(buf: number[], s: string) {
  const bytes = Buffer.from(s, "utf-8");
  writeU16(buf, bytes.length);
  for (const b of bytes) buf.push(b);
}

// ---------------------------------------------------------------------------
// Binary reading helpers
// ---------------------------------------------------------------------------

class Reader {
  private offset = 0;
  constructor(private buf: Buffer) {}

  get pos() { return this.offset; }
  get remaining() { return this.buf.length - this.offset; }

  u8(): number { return this.buf[this.offset++]; }
  u16(): number { const v = this.buf.readUInt16LE(this.offset); this.offset += 2; return v; }
  u32(): number { const v = this.buf.readUInt32LE(this.offset); this.offset += 4; return v; }
  u64(): bigint { const v = this.buf.readBigUInt64LE(this.offset); this.offset += 8; return v; }
  str(): string { const len = this.u16(); const s = this.buf.subarray(this.offset, this.offset + len).toString("utf-8"); this.offset += len; return s; }
  magic(expected: string): boolean {
    const s = this.buf.subarray(this.offset, this.offset + expected.length).toString("ascii");
    this.offset += expected.length;
    return s === expected;
  }
}

// ---------------------------------------------------------------------------
// Replay recorder — writes binary replay file
// ---------------------------------------------------------------------------

export class ReplayRecorder {
  private fd: number;
  private lastMasks: number[] = [];
  private tick = 0;
  private closed = false;

  constructor(seed: number, path: string, configJson: string) {
    this.fd = openSync(path, "w");
    const header: number[] = [];
    for (const ch of REPLAY_MAGIC) header.push(ch.charCodeAt(0));
    writeU16(header, FORMAT_VERSION);
    writeString(header, GAME_NAME);
    writeString(header, GAME_VERSION);
    writeBigU64(header, BigInt(Date.now()));
    writeString(header, configJson);
    writeSync(this.fd, Buffer.from(header));
  }

  writeJoin(playerIndex: number, name: string): void {
    if (this.closed) return;
    const buf: number[] = [];
    writeU8(buf, RECORD_JOIN);
    writeU32(buf, tickTime(this.tick));
    writeU8(buf, playerIndex);
    writeString(buf, name);
    writeSync(this.fd, Buffer.from(buf));
  }

  writeLeave(playerIndex: number): void {
    if (this.closed) return;
    const buf: number[] = [];
    writeU8(buf, RECORD_LEAVE);
    writeU32(buf, tickTime(this.tick));
    writeU8(buf, playerIndex);
    writeSync(this.fd, Buffer.from(buf));
  }

  recordTick(inputMasks: number[]): void {
    if (this.closed) return;
    while (this.lastMasks.length < inputMasks.length) this.lastMasks.push(0);

    for (let i = 0; i < inputMasks.length; i++) {
      if (inputMasks[i] !== this.lastMasks[i]) {
        const buf: number[] = [];
        writeU8(buf, RECORD_INPUT);
        writeU32(buf, tickTime(this.tick));
        writeU8(buf, i);
        writeU8(buf, inputMasks[i]);
        writeSync(this.fd, Buffer.from(buf));
        this.lastMasks[i] = inputMasks[i];
      }
    }

    this.tick++;
  }

  writeHash(hash: bigint): void {
    if (this.closed) return;
    const buf: number[] = [];
    writeU8(buf, RECORD_TICK_HASH);
    writeU32(buf, tickTime(this.tick));
    writeBigU64(buf, hash);
    writeSync(this.fd, Buffer.from(buf));
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    closeSync(this.fd);
  }

  get tickCount(): number { return this.tick; }
}

// ---------------------------------------------------------------------------
// Replay data — loaded from file
// ---------------------------------------------------------------------------

interface ReplayInput { time: number; player: number; keys: number; }
interface ReplayJoin { time: number; player: number; name: string; }
interface ReplayLeave { time: number; player: number; }
interface ReplayHash { tick: number; hash: bigint; }

export interface ReplayData {
  gameName: string;
  gameVersion: string;
  configJson: string;
  joins: ReplayJoin[];
  leaves: ReplayLeave[];
  inputs: ReplayInput[];
  hashes: ReplayHash[];
}

export function loadReplay(path: string): ReplayData {
  const r = new Reader(readFileSync(path) as Buffer);
  if (!r.magic(REPLAY_MAGIC)) throw new Error("Bad replay magic");
  const ver = r.u16();
  if (ver !== FORMAT_VERSION) throw new Error(`Unsupported replay version ${ver}`);
  const gameName = r.str();
  const gameVersion = r.str();
  r.u64(); // timestamp
  const configJson = r.str();

  const data: ReplayData = { gameName, gameVersion, configJson, joins: [], leaves: [], inputs: [], hashes: [] };

  while (r.remaining > 0) {
    const recordType = r.u8();
    switch (recordType) {
      case RECORD_TICK_HASH:
        data.hashes.push({ tick: r.u32(), hash: r.u64() });
        break;
      case RECORD_INPUT:
        data.inputs.push({ time: r.u32(), player: r.u8(), keys: r.u8() });
        break;
      case RECORD_JOIN:
        data.joins.push({ time: r.u32(), player: r.u8(), name: r.str() });
        break;
      case RECORD_LEAVE:
        data.leaves.push({ time: r.u32(), player: r.u8() });
        break;
      default:
        throw new Error(`Unknown replay record type ${recordType}`);
    }
  }
  return data;
}

// ---------------------------------------------------------------------------
// Replay player — feeds recorded events into a sim
// ---------------------------------------------------------------------------

export class ReplayPlayer {
  private joinIdx = 0;
  private leaveIdx = 0;
  private inputIdx = 0;
  private hashIdx = 0;
  private masks: number[] = [];
  private lastApplied: number[] = [];

  constructor(public data: ReplayData) {}

  private ensure(player: number) {
    while (this.masks.length <= player) { this.masks.push(0); this.lastApplied.push(0); }
  }

  applyEvents(tick: number, sim: { addPlayer(name: string): number; removePlayer(index: number): void }): void {
    const time = tickTime(tick);

    while (this.leaveIdx < this.data.leaves.length && this.data.leaves[this.leaveIdx].time <= time) {
      const leave = this.data.leaves[this.leaveIdx++];
      sim.removePlayer(leave.player);
      if (leave.player < this.masks.length) {
        this.masks.splice(leave.player, 1);
        this.lastApplied.splice(leave.player, 1);
      }
    }

    while (this.joinIdx < this.data.joins.length && this.data.joins[this.joinIdx].time <= time) {
      const join = this.data.joins[this.joinIdx++];
      sim.addPlayer(join.name);
      this.ensure(join.player);
    }

    while (this.inputIdx < this.data.inputs.length && this.data.inputs[this.inputIdx].time <= time) {
      const input = this.data.inputs[this.inputIdx++];
      this.ensure(input.player);
      this.masks[input.player] = input.keys;
    }
  }

  getInputs(playerCount: number): InputState[] {
    const out: InputState[] = [];
    for (let i = 0; i < playerCount; i++) {
      this.ensure(i);
      out.push(decodeInputMask(this.masks[i]));
      this.lastApplied[i] = this.masks[i];
    }
    return out;
  }

  getPrevInputs(playerCount: number): InputState[] {
    const out: InputState[] = [];
    for (let i = 0; i < playerCount; i++) {
      this.ensure(i);
      out.push(decodeInputMask(this.lastApplied[i]));
    }
    return out;
  }

  get maxTick(): number {
    if (this.data.hashes.length === 0) return 0;
    return this.data.hashes[this.data.hashes.length - 1].tick;
  }

  get done(): boolean {
    return this.joinIdx >= this.data.joins.length &&
      this.inputIdx >= this.data.inputs.length &&
      this.leaveIdx >= this.data.leaves.length;
  }

  reset(): void {
    this.joinIdx = 0;
    this.leaveIdx = 0;
    this.inputIdx = 0;
    this.hashIdx = 0;
    this.masks = [];
    this.lastApplied = [];
  }
}

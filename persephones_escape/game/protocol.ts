import type { InputState } from "./types.js";
import { BUTTON_UP, BUTTON_DOWN, BUTTON_LEFT, BUTTON_RIGHT, BUTTON_SELECT, BUTTON_A, BUTTON_B, PACKET_INPUT, INPUT_PACKET_BYTES, PACKET_CHAT } from "./constants.js";

export function decodeInputMask(mask: number): InputState {
  return {
    up: (mask & BUTTON_UP) !== 0,
    down: (mask & BUTTON_DOWN) !== 0,
    left: (mask & BUTTON_LEFT) !== 0,
    right: (mask & BUTTON_RIGHT) !== 0,
    select: (mask & BUTTON_SELECT) !== 0,
    attack: (mask & BUTTON_A) !== 0,
    b: (mask & BUTTON_B) !== 0,
  };
}

export function emptyInput(): InputState {
  return { up: false, down: false, left: false, right: false, select: false, attack: false, b: false };
}

export function isInputPacket(data: Buffer): boolean {
  return data.length === INPUT_PACKET_BYTES && data[0] === PACKET_INPUT;
}

export function isChatPacket(data: Buffer): boolean {
  return data.length >= 1 && data[0] === PACKET_CHAT;
}

export function blobToMask(data: Buffer): number {
  if (!isInputPacket(data)) return 0;
  return data[1];
}

export function blobToChat(data: Buffer): string {
  if (!isChatPacket(data)) return "";
  let result = "";
  for (let i = 1; i < data.length; i++) {
    const ch = data[i];
    if (ch >= 32 && ch < 127) result += String.fromCharCode(ch);
  }
  return result;
}

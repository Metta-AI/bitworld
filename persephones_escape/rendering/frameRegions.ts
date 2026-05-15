import {
  BOTTOM_BAR_H,
  PLAYER_W,
  SCREEN_HEIGHT,
  SCREEN_WIDTH,
} from "../game/constants.js";

export interface FramePoint {
  x: number;
  y: number;
}

export interface FrameRect extends FramePoint {
  w: number;
  h: number;
}

const WHISPER_HEADER_H = 9;
const WHISPER_TEXT_Y = 2;
const WHISPER_OCCUPANT_X = 66;
const WHISPER_OCCUPANT_Y = 1;
const WHISPER_OCCUPANT_GAP = 2;
const WHISPER_LINE_H = 7;

function bottomBar(): FrameRect {
  return { x: 0, y: SCREEN_HEIGHT - BOTTOM_BAR_H, w: SCREEN_WIDTH, h: BOTTOM_BAR_H };
}

function whisperMessageArea(): FrameRect {
  const bar = bottomBar();
  return { x: 0, y: WHISPER_HEADER_H + 1, w: SCREEN_WIDTH, h: bar.y - 1 - (WHISPER_HEADER_H + 1) };
}

function whisperPendingEntryBang(): FrameRect {
  const bar = bottomBar();
  const msgAreaBot = bar.y - 1;
  const reqY = msgAreaBot - WHISPER_LINE_H;
  return { x: 2, y: reqY - 1, w: 3, h: WHISPER_LINE_H + 1 };
}

function whisperPendingEntrySprite(): FramePoint {
  return { x: 8, y: whisperPendingEntryBang().y + 1 };
}

function whisperPendingEntryText(): FramePoint {
  const sprite = whisperPendingEntrySprite();
  return { x: sprite.x + PLAYER_W + 2, y: sprite.y };
}

function whisperOccupantSlot(slot: number): FrameRect {
  const stride = PLAYER_W + WHISPER_OCCUPANT_GAP;
  return {
    x: WHISPER_OCCUPANT_X + slot * stride,
    y: WHISPER_OCCUPANT_Y,
    w: PLAYER_W,
    h: PLAYER_W,
  };
}

export const FRAME_REGIONS = {
  whisper: {
    header: { x: 0, y: 0, w: SCREEN_WIDTH, h: WHISPER_HEADER_H },
    clockText: { x: 2, y: WHISPER_TEXT_Y },
    titleText: { x: 42, y: WHISPER_TEXT_Y },
    bottomBar,
    bottomText: () => ({ x: 2, y: bottomBar().y + 2 }),
    offerIndicator: () => ({ x: SCREEN_WIDTH - 10, y: bottomBar().y + 2, w: 10, h: 7 }),
    messageArea: whisperMessageArea,
    pendingEntryBang: whisperPendingEntryBang,
    pendingEntrySprite: whisperPendingEntrySprite,
    pendingEntryText: whisperPendingEntryText,
    occupantSlot: whisperOccupantSlot,
    maxOccupantSlots: Math.floor((SCREEN_WIDTH - 2 - WHISPER_OCCUPANT_X) / (PLAYER_W + WHISPER_OCCUPANT_GAP)) + 1,
  },
} as const;

import {
  BUTTON_A, BUTTON_B, BUTTON_SELECT,
  BUTTON_LEFT, BUTTON_RIGHT, BUTTON_UP, BUTTON_DOWN,
} from "./constants.js";
import type { InputState } from "./types.js";

// ---------------------------------------------------------------------------
// 1D menus (comm, share, global, psychopomp, info)
// ---------------------------------------------------------------------------

export interface MenuDef {
  axis: "horizontal" | "vertical";
  selectButton: number;
  closeButton: number | null;
  openButton: number | null;
  openSequence: number[];
}

export const MENU_DEFS = {
  whisper:   { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_SELECT, openButton: BUTTON_B,      openSequence: [BUTTON_B, 0] },
  share:      { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_SELECT, openButton: null,           openSequence: [] },
  shout:      { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_SELECT, openButton: BUTTON_SELECT,  openSequence: [BUTTON_SELECT, 0] },
  psychopomp:    { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_SELECT, openButton: null,           openSequence: [] },
  info:       { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_A,      openButton: BUTTON_B,       openSequence: [BUTTON_B, 0] },
} satisfies Record<string, MenuDef>;

// ---------------------------------------------------------------------------
// 2D whisper menu — categories (L/R) × items (U/D)
// ---------------------------------------------------------------------------

export interface MenuItem2D {
  action: string;
}

export interface MenuCategory2D {
  label: string;
  items: MenuItem2D[];
}

export const WHISPER_MENU: MenuCategory2D[] = [
  {
    label: "COLOR",
    items: [
      { action: "C.OFFER" },
      { action: "C.UNOFFR" },
      { action: "C.ACCPT" },
    ],
  },
  {
    label: "ROLE",
    items: [
      { action: "ROLE" },
      { action: "R.OFFER" },
      { action: "R.UNOFFR" },
      { action: "R.ACCPT" },
    ],
  },
  {
    label: "LEADER",
    items: [
      { action: "PASS" },
      { action: "TAKE" },
      { action: "GRANT" },
    ],
  },
  {
    label: "EXIT",
    items: [
      { action: "EXIT" },
    ],
  },
];

export const WHISPER_OPEN_BUTTON = BUTTON_B;
export const WHISPER_CLOSE_BUTTON = BUTTON_SELECT;
export const WHISPER_SELECT_BUTTON = BUTTON_A;

export function whisperMenuItemLabel(cat: MenuCategory2D, itemIdx: number): string {
  const item = cat.items[itemIdx];
  if (!item) return "";
  return item.action;
}

export function whisperMenuAction(catIdx: number, itemIdx: number): string | null {
  const cat = WHISPER_MENU[catIdx];
  if (!cat) return null;
  const item = cat.items[itemIdx];
  if (!item) return null;
  return item.action;
}

export function findWhisperMenuPosition(action: string): { catIdx: number; itemIdx: number } | null {
  for (let c = 0; c < WHISPER_MENU.length; c++) {
    const cat = WHISPER_MENU[c];
    for (let i = 0; i < cat.items.length; i++) {
      if (cat.items[i].action === action) {
        return { catIdx: c, itemIdx: i };
      }
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Input helpers
// ---------------------------------------------------------------------------

export function pressed(input: InputState, prev: InputState, button: number): boolean {
  const cur = buttonField(input, button);
  const was = buttonField(prev, button);
  return cur && !was;
}

export function anyPressed(input: InputState, prev: InputState, ...buttons: number[]): boolean {
  for (const b of buttons) {
    if (pressed(input, prev, b)) return true;
  }
  return false;
}

function buttonField(input: InputState, button: number): boolean {
  switch (button) {
    case BUTTON_A: return input.attack;
    case BUTTON_B: return input.b;
    case BUTTON_SELECT: return input.select;
    case BUTTON_LEFT: return input.left;
    case BUTTON_RIGHT: return input.right;
    case BUTTON_UP: return input.up;
    case BUTTON_DOWN: return input.down;
    default: return false;
  }
}

// ---------------------------------------------------------------------------
// 1D menu navigation + sequence building
// ---------------------------------------------------------------------------

export function navigateMenu(
  input: InputState, prev: InputState, def: MenuDef, count: number, row: number,
): number {
  if (count === 0) return row;
  row = Math.min(row, count - 1);
  if (def.axis === "horizontal") {
    if (pressed(input, prev, BUTTON_LEFT)) row = (row - 1 + count) % count;
    if (pressed(input, prev, BUTTON_RIGHT)) row = (row + 1) % count;
  } else {
    if (pressed(input, prev, BUTTON_UP)) row = (row - 1 + count) % count;
    if (pressed(input, prev, BUTTON_DOWN)) row = (row + 1) % count;
  }
  return row;
}

export function menuSequence(context: string, action: string, items: string[]): number[] {
  const def = (MENU_DEFS as Record<string, MenuDef>)[context];
  if (!def) return [];

  const idx = items.indexOf(action);
  if (idx < 0) return [];

  const seq: number[] = [...def.openSequence];

  const navButton = def.axis === "horizontal" ? BUTTON_RIGHT : BUTTON_DOWN;
  for (let i = 0; i < idx; i++) {
    seq.push(navButton, 0);
  }

  seq.push(def.selectButton, 0);
  return seq;
}

// ---------------------------------------------------------------------------
// 2D whisper menu navigation + sequence building
// ---------------------------------------------------------------------------

export function navigateWhisperMenu(
  input: InputState, prev: InputState,
  catIdx: number, itemIdx: number,
): { catIdx: number; itemIdx: number } {
  const catCount = WHISPER_MENU.length;
  if (pressed(input, prev, BUTTON_LEFT)) catIdx = (catIdx - 1 + catCount) % catCount;
  if (pressed(input, prev, BUTTON_RIGHT)) catIdx = (catIdx + 1) % catCount;

  const itemCount = WHISPER_MENU[catIdx].items.length;
  if (pressed(input, prev, BUTTON_UP)) itemIdx = (itemIdx - 1 + itemCount) % itemCount;
  if (pressed(input, prev, BUTTON_DOWN)) itemIdx = (itemIdx + 1) % itemCount;

  itemIdx = Math.min(itemIdx, WHISPER_MENU[catIdx].items.length - 1);
  return { catIdx, itemIdx };
}

function shortestWrapSteps(from: number, to: number, count: number): { steps: number; dir: -1 | 1 } {
  if (from === to) return { steps: 0, dir: 1 };
  const fwd = (to - from + count) % count;
  const bwd = (from - to + count) % count;
  return fwd <= bwd ? { steps: fwd, dir: 1 } : { steps: bwd, dir: -1 };
}

export function whisperMenuSequence(action: string): number[] {
  const pos = findWhisperMenuPosition(action);
  if (!pos) return [];

  const seq: number[] = [WHISPER_OPEN_BUTTON, 0];

  const catNav = shortestWrapSteps(0, pos.catIdx, WHISPER_MENU.length);
  const catButton = catNav.dir === 1 ? BUTTON_RIGHT : BUTTON_LEFT;
  for (let i = 0; i < catNav.steps; i++) seq.push(catButton, 0);

  const itemCount = WHISPER_MENU[pos.catIdx].items.length;
  const itemNav = shortestWrapSteps(0, pos.itemIdx, itemCount);
  const itemButton = itemNav.dir === 1 ? BUTTON_DOWN : BUTTON_UP;
  for (let i = 0; i < itemNav.steps; i++) seq.push(itemButton, 0);

  seq.push(WHISPER_SELECT_BUTTON, 0);
  return seq;
}

/**
 * Full whisper-menu action sequence INCLUDING the target-picker auto-confirm
 * for R.ACCPT / C.ACCPT. Those two actions open a sub-menu listing offerers;
 * pressing the select button again picks the first (and usually only) offerer,
 * which is almost always the correct choice. Returns [] if the action is
 * unknown. Safe to push directly into a bot's action queue.
 */
export function whisperMenuSequenceWithTargetPick(action: string): number[] {
  const seq = whisperMenuSequence(action);
  if (seq.length === 0) return seq;
  if (action === "R.ACCPT" || action === "C.ACCPT") {
    seq.push(WHISPER_SELECT_BUTTON, 0);
  }
  return seq;
}

// ---------------------------------------------------------------------------
// Command → action mapping
// ---------------------------------------------------------------------------

export const COMMAND_ACTIONS: Record<string, { context: string; action: string }> = {
  color_offer:    { context: "whisper", action: "C.OFFER" },
  color_withdraw: { context: "whisper", action: "C.UNOFFR" },
  color_accept:   { context: "whisper", action: "C.ACCPT" },
  show_role:      { context: "whisper", action: "ROLE" },
  role_offer:     { context: "whisper", action: "R.OFFER" },
  role_withdraw:  { context: "whisper", action: "R.UNOFFR" },
  role_accept:    { context: "whisper", action: "R.ACCPT" },
  leader_pass:    { context: "whisper", action: "PASS" },
  leader_take:    { context: "whisper", action: "TAKE" },
  grant_entry:    { context: "whisper", action: "GRANT" },
  exit_whisper:  { context: "whisper", action: "EXIT" },
  shout:          { context: "shout", action: "SHOUT" },
  info_shared:    { context: "info", action: "open" },
};

import {
  BUTTON_A, BUTTON_B, BUTTON_SELECT,
  BUTTON_LEFT, BUTTON_RIGHT, BUTTON_UP, BUTTON_DOWN,
} from "./constants.js";
import type { InputState } from "./types.js";

// ---------------------------------------------------------------------------
// 1D menus (comm, share, global, hostage, info)
// ---------------------------------------------------------------------------

export interface MenuDef {
  axis: "horizontal" | "vertical";
  selectButton: number;
  closeButton: number | null;
  openButton: number | null;
  openSequence: number[];
}

export const MENU_DEFS = {
  comm:       { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_SELECT, openButton: BUTTON_SELECT, openSequence: [BUTTON_SELECT, 0] },
  chatroom:   { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_SELECT, openButton: BUTTON_B,      openSequence: [BUTTON_B, 0] },
  share:      { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_SELECT, openButton: null,           openSequence: [] },
  global:     { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_SELECT, openButton: null,           openSequence: [] },
  hostage:    { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_SELECT, openButton: null,           openSequence: [] },
  info:       { axis: "horizontal" as const, selectButton: BUTTON_A, closeButton: BUTTON_A,      openButton: BUTTON_B,       openSequence: [BUTTON_B, 0] },
} satisfies Record<string, MenuDef>;

// ---------------------------------------------------------------------------
// 2D chatroom menu — categories (L/R) × items (U/D)
// ---------------------------------------------------------------------------

export interface MenuItem2D {
  action: string;
  toggleAction?: string;
}

export interface MenuCategory2D {
  label: string;
  items: MenuItem2D[];
}

export const CHATROOM_MENU: MenuCategory2D[] = [
  {
    label: "COLOR",
    items: [
      { action: "C.OFFER", toggleAction: "C.UNOFFR" },
      { action: "C.ACCPT" },
    ],
  },
  {
    label: "ROLE",
    items: [
      { action: "ROLE" },
      { action: "R.OFFER", toggleAction: "R.UNOFFR" },
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

export const CHATROOM_OPEN_BUTTON = BUTTON_B;
export const CHATROOM_CLOSE_BUTTON = BUTTON_SELECT;
export const CHATROOM_SELECT_BUTTON = BUTTON_A;

export function chatMenuItemLabel(cat: MenuCategory2D, itemIdx: number, toggled: boolean): string {
  const item = cat.items[itemIdx];
  if (!item) return "";
  if (toggled && item.toggleAction) return item.toggleAction;
  return item.action;
}

export function chatMenuAction(catIdx: number, itemIdx: number, toggledSet: Set<string>): string | null {
  const cat = CHATROOM_MENU[catIdx];
  if (!cat) return null;
  const item = cat.items[itemIdx];
  if (!item) return null;
  if (item.toggleAction && toggledSet.has(item.action)) return item.toggleAction;
  return item.action;
}

export function findChatMenuPosition(action: string): { catIdx: number; itemIdx: number } | null {
  for (let c = 0; c < CHATROOM_MENU.length; c++) {
    const cat = CHATROOM_MENU[c];
    for (let i = 0; i < cat.items.length; i++) {
      if (cat.items[i].action === action || cat.items[i].toggleAction === action) {
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
// 2D chatroom menu navigation + sequence building
// ---------------------------------------------------------------------------

export function navigateChatMenu(
  input: InputState, prev: InputState,
  catIdx: number, itemIdx: number,
): { catIdx: number; itemIdx: number } {
  const catCount = CHATROOM_MENU.length;
  if (pressed(input, prev, BUTTON_LEFT)) catIdx = (catIdx - 1 + catCount) % catCount;
  if (pressed(input, prev, BUTTON_RIGHT)) catIdx = (catIdx + 1) % catCount;

  const itemCount = CHATROOM_MENU[catIdx].items.length;
  if (pressed(input, prev, BUTTON_UP)) itemIdx = (itemIdx - 1 + itemCount) % itemCount;
  if (pressed(input, prev, BUTTON_DOWN)) itemIdx = (itemIdx + 1) % itemCount;

  itemIdx = Math.min(itemIdx, CHATROOM_MENU[catIdx].items.length - 1);
  return { catIdx, itemIdx };
}

function shortestWrapSteps(from: number, to: number, count: number): { steps: number; dir: -1 | 1 } {
  if (from === to) return { steps: 0, dir: 1 };
  const fwd = (to - from + count) % count;
  const bwd = (from - to + count) % count;
  return fwd <= bwd ? { steps: fwd, dir: 1 } : { steps: bwd, dir: -1 };
}

export function chatMenuSequence(action: string): number[] {
  const pos = findChatMenuPosition(action);
  if (!pos) return [];

  const seq: number[] = [CHATROOM_OPEN_BUTTON, 0];

  const catNav = shortestWrapSteps(0, pos.catIdx, CHATROOM_MENU.length);
  const catButton = catNav.dir === 1 ? BUTTON_RIGHT : BUTTON_LEFT;
  for (let i = 0; i < catNav.steps; i++) seq.push(catButton, 0);

  const itemCount = CHATROOM_MENU[pos.catIdx].items.length;
  const itemNav = shortestWrapSteps(0, pos.itemIdx, itemCount);
  const itemButton = itemNav.dir === 1 ? BUTTON_DOWN : BUTTON_UP;
  for (let i = 0; i < itemNav.steps; i++) seq.push(itemButton, 0);

  seq.push(CHATROOM_SELECT_BUTTON, 0);
  return seq;
}

// ---------------------------------------------------------------------------
// Command → action mapping
// ---------------------------------------------------------------------------

export const COMMAND_ACTIONS: Record<string, { context: string; action: string }> = {
  color_offer:    { context: "chatroom", action: "C.OFFER" },
  color_withdraw: { context: "chatroom", action: "C.UNOFFR" },
  color_accept:   { context: "chatroom", action: "C.ACCPT" },
  show_role:      { context: "chatroom", action: "ROLE" },
  role_offer:     { context: "chatroom", action: "R.OFFER" },
  role_withdraw:  { context: "chatroom", action: "R.UNOFFR" },
  role_accept:    { context: "chatroom", action: "R.ACCPT" },
  leader_pass:    { context: "chatroom", action: "PASS" },
  leader_take:    { context: "chatroom", action: "TAKE" },
  grant_entry:    { context: "chatroom", action: "GRANT" },
  exit_chatroom:  { context: "chatroom", action: "EXIT" },
  shout:          { context: "comm", action: "SHOUT" },
  info_shared:    { context: "info", action: "open" },
};

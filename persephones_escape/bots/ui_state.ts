import {
  BUTTON_A,
  BUTTON_B,
  BUTTON_DOWN,
  BUTTON_LEFT,
  BUTTON_RIGHT,
  BUTTON_SELECT,
  BUTTON_UP,
} from "../game/constants.js";
import { findWhisperMenuPosition, WHISPER_MENU } from "../game/menu_defs.js";
import { FRAME_REGIONS } from "../rendering/frameRegions.js";
import { parsePhase, readTextAt, type ParsedPhase } from "./frame_parser.js";

export type WhisperAction =
  | "ROLE" | "C.OFFER" | "C.UNOFFR" | "C.ACCPT"
  | "R.OFFER" | "R.UNOFFR" | "R.ACCPT"
  | "PASS" | "TAKE" | "GRANT" | "EXIT";

export type ParsedUiState =
  | { phase: ParsedPhase; surface: "playing"; bottomText: string }
  | { phase: ParsedPhase; surface: "shout"; bottomText: string }
  | { phase: ParsedPhase; surface: "whisper_idle"; bottomText: string }
  | { phase: ParsedPhase; surface: "whisper_menu"; bottomText: string; catIdx: number; itemIdx: number; action: WhisperAction }
  | { phase: ParsedPhase; surface: "whisper_share_picker"; bottomText: string; mode: "color" | "card" }
  | { phase: ParsedPhase; surface: "info_screen"; bottomText: string }
  | { phase: ParsedPhase; surface: "other"; bottomText: string };

export type UiTarget =
  | { kind: "whisper_menu_action"; action: WhisperAction }
  | { kind: "whisper_share_picker"; mode: "color" | "card" }
  | { kind: "whisper_idle" }
  | { kind: "info_screen" }
  | { kind: "shout_screen" }
  | { kind: "playing_surface" };

export interface UiNavigationState {
  releaseNext?: boolean;
  attempts?: number;
}

export type UiNavigationStep =
  | { ready: true; state: ParsedUiState }
  | { ready: false; mask: number; reason: string; state: ParsedUiState };

const READ_COLORS = [2, 1, 8] as const;

export function parseUiState(frame: Uint8Array): ParsedUiState {
  const phase = parsePhase(frame);
  const bottomText = readWhisperBottomText(frame);

  if (phase === "info_screen") {
    return { phase, surface: "info_screen", bottomText };
  }

  if (parseShoutSurface(bottomText)) {
    return { phase, surface: "shout", bottomText };
  }

  if (phase !== "whisper" && phase !== "leader_summit") {
    if (phase === "playing" || phase === "psychopomp_select") {
      return { phase, surface: "playing", bottomText };
    }
    return { phase, surface: "other", bottomText };
  }

  if (phase === "leader_summit" && !looksLikeWhisperSurface(bottomText)) {
    return { phase, surface: "playing", bottomText };
  }

  const shareMode = parseSharePickerMode(bottomText);
  if (shareMode) {
    return { phase, surface: "whisper_share_picker", bottomText, mode: shareMode };
  }

  const menu = parseWhisperMenu(bottomText);
  if (menu) {
    return { phase, surface: "whisper_menu", bottomText, ...menu };
  }

  return { phase, surface: "whisper_idle", bottomText };
}

export function navigateUiToward(state: ParsedUiState, target: UiTarget): UiNavigationStep {
  if (target.kind === "info_screen") {
    if (state.surface === "info_screen") return { ready: true, state };
    if (state.surface === "whisper_idle") {
      return { ready: false, mask: BUTTON_LEFT, reason: "cycle_whisper_to_info", state };
    }
    if (state.surface === "whisper_menu" || state.surface === "whisper_share_picker") {
      return { ready: false, mask: BUTTON_SELECT, reason: "close_whisper_overlay_for_info", state };
    }
    if (state.surface === "shout") {
      return { ready: false, mask: BUTTON_RIGHT, reason: "cycle_shout_to_info", state };
    }
    if (state.surface === "playing") {
      return { ready: false, mask: BUTTON_SELECT, reason: "open_social_surface_for_info", state };
    }
    return { ready: false, mask: 0, reason: "wait_for_info_capable_phase", state };
  }

  if (target.kind === "playing_surface") {
    if (state.surface === "playing") {
      return { ready: true, state };
    }
    if (state.surface === "info_screen") {
      return { ready: false, mask: BUTTON_SELECT, reason: "close_info_screen", state };
    }
    if (state.surface === "shout") {
      return { ready: false, mask: BUTTON_SELECT, reason: "close_shout_screen", state };
    }
    if (state.surface === "whisper_menu" || state.surface === "whisper_share_picker") {
      return { ready: false, mask: BUTTON_SELECT, reason: "close_whisper_overlay", state };
    }
    return { ready: false, mask: 0, reason: "wait_for_playing_surface", state };
  }

  if (target.kind === "shout_screen") {
    if (state.surface === "shout") return { ready: true, state };
    if (state.surface === "playing") {
      return { ready: false, mask: BUTTON_SELECT, reason: "open_shout_screen", state };
    }
    if (state.surface === "info_screen") {
      return { ready: false, mask: BUTTON_LEFT, reason: "cycle_info_to_shout", state };
    }
    if (state.surface === "whisper_idle") {
      return { ready: false, mask: BUTTON_RIGHT, reason: "cycle_whisper_to_shout", state };
    }
    if (state.surface === "whisper_menu" || state.surface === "whisper_share_picker") {
      return { ready: false, mask: BUTTON_SELECT, reason: "close_whisper_overlay_for_shout", state };
    }
    return { ready: false, mask: 0, reason: "wait_for_shout_capable_phase", state };
  }

  if (target.kind === "whisper_idle") {
    if (state.surface === "whisper_idle") return { ready: true, state };
    if (state.surface === "info_screen") {
      return { ready: false, mask: BUTTON_SELECT, reason: "close_info_to_whisper", state };
    }
    if (state.surface === "shout") {
      return { ready: false, mask: BUTTON_LEFT, reason: "cycle_shout_to_whisper", state };
    }
    if (state.surface === "whisper_menu" || state.surface === "whisper_share_picker") {
      return { ready: false, mask: BUTTON_SELECT, reason: "close_to_whisper_idle", state };
    }
    return { ready: false, mask: 0, reason: "wait_for_whisper_idle_phase", state };
  }

  if (target.kind === "whisper_share_picker") {
    if (state.surface === "whisper_share_picker" && state.mode === target.mode) {
      return { ready: true, state };
    }
    if (state.surface === "whisper_share_picker") {
      return { ready: false, mask: BUTTON_SELECT, reason: "close_wrong_share_picker", state };
    }
    return { ready: false, mask: 0, reason: "wait_for_share_picker", state };
  }

  const pos = findWhisperMenuPosition(target.action);
  if (!pos) return { ready: false, mask: 0, reason: "unknown_whisper_action", state };

  if (state.surface === "whisper_share_picker") {
    return { ready: false, mask: BUTTON_SELECT, reason: "close_share_picker_for_whisper_menu", state };
  }
  if (state.surface === "whisper_idle") {
    return { ready: false, mask: BUTTON_B, reason: "open_whisper_menu", state };
  }
  if (state.surface !== "whisper_menu") {
    return { ready: false, mask: 0, reason: "wait_for_whisper_menu_phase", state };
  }

  if (state.catIdx !== pos.catIdx) {
    const nav = shortestWrapStep(state.catIdx, pos.catIdx, WHISPER_MENU.length);
    return { ready: false, mask: nav === 1 ? BUTTON_RIGHT : BUTTON_LEFT, reason: "navigate_whisper_menu_category", state };
  }

  if (state.itemIdx !== pos.itemIdx) {
    const itemCount = WHISPER_MENU[pos.catIdx].items.length;
    const nav = shortestWrapStep(state.itemIdx, pos.itemIdx, itemCount);
    return { ready: false, mask: nav === 1 ? BUTTON_DOWN : BUTTON_UP, reason: "navigate_whisper_menu_item", state };
  }

  return { ready: true, state };
}

function readWhisperBottomText(frame: Uint8Array): string {
  const bottom = FRAME_REGIONS.whisper.bottomText();
  let best = "";
  for (const color of READ_COLORS) {
    const text = readTextAt(frame, bottom.x, bottom.y, color, 28).trim();
    if (text.length > best.length) best = text;
  }
  return best;
}

function parseSharePickerMode(text: string): "color" | "card" | null {
  const normalized = text.replace(/\s+/g, "");
  if (normalized.startsWith("COLOR:")) return "color";
  if (normalized.startsWith("ROLE:")) return "card";
  return null;
}

function parseShoutSurface(text: string): boolean {
  const normalized = text.replace(/\s+/g, "").toUpperCase();
  return normalized.includes("TAB") && normalized.includes("CLOSE")
    || normalized.includes("COMMIT") && normalized.includes("TOG");
}

function looksLikeWhisperSurface(text: string): boolean {
  const normalized = text.replace(/\s+/g, "").toUpperCase();
  return normalized.includes("EXIT") || normalized.includes("SUMMIT");
}

function parseWhisperMenu(text: string): { catIdx: number; itemIdx: number; action: WhisperAction } | null {
  const normalized = text.replace(/\s+/g, "");
  for (let catIdx = 0; catIdx < WHISPER_MENU.length; catIdx++) {
    const cat = WHISPER_MENU[catIdx];
    if (!normalized.includes(`(${cat.label})`)) continue;
    const actionText = normalized.replace(`(${cat.label})`, "");
    for (let itemIdx = 0; itemIdx < cat.items.length; itemIdx++) {
      const action = cat.items[itemIdx].action as WhisperAction;
      if (actionText.includes(action)) return { catIdx, itemIdx, action };
    }
  }
  return null;
}

function shortestWrapStep(from: number, to: number, count: number): -1 | 1 {
  const fwd = (to - from + count) % count;
  const bwd = (from - to + count) % count;
  return fwd <= bwd ? 1 : -1;
}

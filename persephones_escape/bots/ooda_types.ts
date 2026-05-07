import { parseRosterScreen } from "./frame_parser.js";
import type { Point } from "./bot_utils.js";
import type { ParsedUiState, UiNavigationState, WhisperAction } from "./ui_state.js";

export interface FrameObservation {
  frame: Uint8Array;
  roster: ReturnType<typeof parseRosterScreen>;
}

export type FrameDecision =
  | { kind: "input"; mask: number; reason: string }
  | { kind: "psychopomp_precommit"; frame: Uint8Array }
  | { kind: "run_activity"; frame: Uint8Array };

export type BotLogFn = (kind: string, data?: Record<string, unknown>) => void;

export type AtomicAction =
  | { kind: "input"; masks: number[]; label: string; index?: number }
  | { kind: "chat"; text: string; label: string }
  | { kind: "whisper_action"; action: WhisperAction; label: string; target?: string; ui?: UiNavigationState; stage?: "menu" | "share_picker" | "release_done" }
  | { kind: "info_check"; label: string; ui?: UiNavigationState; stage?: "open" | "read" | "close" | "release_done"; startedTick: number; readTicks: number; originSurface?: ParsedUiState["surface"] }
  | {
      kind: "usurp_vote";
      target: string;
      label: string;
      startedTick: number;
      state: "opening" | "navigating" | "voting" | "closing";
      navCount: number;
    };

export type ActivityKind =
  | "walk_to"
  | "pursue_player";

export interface ActivityBase {
  id: string;
  kind: ActivityKind;
  startedTick: number;
  lastActiveTick: number;
  timeLimitTicks: number;
  status: string;
}

export interface WalkToActivity extends ActivityBase {
  kind: "walk_to";
  x: number;
  y: number;
  openWhisperOnArrive: boolean;
  openedOnArrive: boolean;
}

export type PursuePlayerMode = "color" | "role" | "whisper" | "leader";
export type PursuePlayerApproach = "find_spot" | "go_to_player";

export interface PursuePlayerActivity extends ActivityBase {
  kind: "pursue_player";
  target: string;
  mode: PursuePlayerMode;
  approach: PursuePlayerApproach;
  createdOwnWhisperTick: number | null;
  enteredWhisperTick: number | null;
  waitingEntryTick: number | null;
  grantDeadlineTick: number | null;
  lastSawTargetTick: number;
  offerSentTick: number | null;
  conversationMessageSentTick: number | null;
  shoutedWrongRoom: boolean;
  privateSpot: Point | null;
  privateSpotTick: number;
  privateSpotShoutTick: number;
  nearTargetWaitTick: number;
  openAttemptStartTick: number | null;
  openAttemptCount: number;
  clusterEscapeStartTick: number | null;
}

export type Activity = WalkToActivity | PursuePlayerActivity;

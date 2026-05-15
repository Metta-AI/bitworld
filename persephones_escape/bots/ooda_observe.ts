import { PACKED_FRAME_BYTES, unpackFrame } from "./bot_utils.js";
import { parseRosterScreen } from "./frame_parser.js";
import type { FrameObservation } from "./ooda_types.js";

export function observeFrame(data: Buffer): FrameObservation | null {
  if (data.length !== PACKED_FRAME_BYTES) return null;
  const frame = unpackFrame(data);
  return { frame, roster: parseRosterScreen(frame) };
}

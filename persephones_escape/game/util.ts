import type { ChatroomMessage } from "./types.js";

export function clamp(val: number, min: number, max: number): number {
  return val < min ? min : val > max ? max : val;
}

export function distSq(ax: number, ay: number, bx: number, by: number): number {
  return (ax - bx) * (ax - bx) + (ay - by) * (ay - by);
}

/**
 * Merge multi-line chat fragments back into a single logical message.
 * Fragments are identified by sharing (tick, senderIndex, type) — this is how
 * sim.chatRateCheck emits a long message: N entries at the same tick from the
 * same sender, each carrying one line of the original text.
 *
 * Fragments are concatenated with NO separator, since sim split the original
 * text at a fixed character count (possibly mid-word). Readers that need a
 * whitespace separator between lines should insert their own.
 */
export function coalesceChatFragments(messages: ChatroomMessage[]): ChatroomMessage[] {
  if (messages.length === 0) return messages;
  const out: ChatroomMessage[] = [];
  for (const m of messages) {
    const prev = out[out.length - 1];
    if (
      prev !== undefined &&
      prev.tick === m.tick &&
      prev.senderIndex === m.senderIndex &&
      prev.type === m.type
    ) {
      prev.text = prev.text + m.text;
    } else {
      out.push({ ...m });
    }
  }
  return out;
}

/**
 * Compatibility exports for older imports.
 *
 * Strategy state is now folded into GameKnowledge.policy. Focused LLM calls
 * write validated policy patches, and Decide reads knowledge.policy.resolved.
 */

import {
  defaultResolvedPolicy,
  type ResolvedPolicy,
} from "./game_knowledge.js";

export type StrategyState = ResolvedPolicy;
export type PrefetchedWhisper = ResolvedPolicy["prefetchedWhisper"];
export type MeetPoint = NonNullable<ResolvedPolicy["meetPoint"]>;

export function defaultStrategyState(): StrategyState {
  return defaultResolvedPolicy();
}

export function mergeStrategyUpdate(
  current: StrategyState,
  update: Partial<StrategyState>,
): StrategyState {
  return { ...current, ...update, lastUpdatedTick: update.lastUpdatedTick ?? current.lastUpdatedTick };
}

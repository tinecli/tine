import type { Suggestion } from "../shared/internal";
import { makeArray } from "../shared/utils";

// { command: { commandParam: { count, lastUsed } } } e.g. git: { add: { count: 12,
// lastUsed: 1754000000000 } }. The app builds this from ~/.zsh_history plus live
// picks and sets it as globalThis.__tineFrecency.
export type Use = { count: number; lastUsed: number };
type Index = Record<string, Record<string, unknown>>;

const HALF_LIFE_MS = 7 * 24 * 60 * 60 * 1000;

const isUse = (value: unknown): value is Use =>
  typeof value === "object" &&
  value !== null &&
  "count" in value &&
  "lastUsed" in value &&
  typeof value.count === "number" &&
  typeof value.lastUsed === "number";

// Uses decayed by age, mapped into (0, 1) so a boost never crosses a priority band.
export const frecencyBoost = (use: unknown, now: number): number => {
  if (!isUse(use)) return 0;
  const age = Math.max(0, now - use.lastUsed);
  const score = use.count * 2 ** (-age / HALF_LIFE_MS);
  return score / (score + 1);
};

const frecencyIndex = (): Index => {
  const index = (globalThis as { __tineFrecency?: unknown }).__tineFrecency;
  return index && typeof index === "object" ? (index as Index) : {};
};

export const updatePriorities = (suggestions: Suggestion[], cmd: string) => {
  const cmdUses = frecencyIndex()[cmd];
  const now = Date.now();

  return suggestions.map((suggestion) => {
    const name = makeArray(suggestion.name)[0] || "";
    const boost = name === "../" ? 0 : frecencyBoost(cmdUses?.[name], now);

    const raw = suggestion.priority || 50;
    const priority =
      suggestion.type === "auto-execute"
        ? raw
        : Math.max(Math.min(100, raw), 0);

    const banded = boost && priority >= 50 && priority <= 75 ? 75 : priority;
    return { ...suggestion, priority: banded + boost };
  });
};

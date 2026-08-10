import type { Suggestion } from "../shared/internal";
import { makeArray } from "../shared/utils";

// { command: { commandParam: { count, lastUsed } } } e.g. git: { add: { count: 12,
// lastUsed: 1754000000000 } }. The app builds this from ~/.zsh_history plus live
// picks and sets it as globalThis.__tineFrecency.
export type Use = { count: number; lastUsed: number };
type Index = Record<string, Record<string, unknown>>;

const HALF_LIFE_MS = 7 * 24 * 60 * 60 * 1000;
const PROJECT_FRECENCY_WEIGHT = 2;

// Foreign data (an edited store, a stale bridge) must never turn into a NaN or
// -Infinity priority, so the shape check also bounds the numbers.
const isUse = (value: unknown): value is Use =>
  typeof value === "object" &&
  value !== null &&
  "count" in value &&
  "lastUsed" in value &&
  typeof value.count === "number" &&
  typeof value.lastUsed === "number" &&
  Number.isFinite(value.count) &&
  value.count >= 0 &&
  Number.isFinite(value.lastUsed);

// Uses decayed by age, mapped into (0, 1) so a boost never crosses a priority band.
export const frecencyBoost = (use: unknown, now: number): number => {
  if (!isUse(use)) return 0;
  const age = Math.max(0, now - use.lastUsed);
  const score = use.count * 2 ** (-age / HALF_LIFE_MS);
  return score / (score + 1);
};

const blendedUse = (
  globalUse: unknown,
  projectUse: unknown,
): Use | undefined => {
  const global = isUse(globalUse) ? globalUse : undefined;
  const project = isUse(projectUse) ? projectUse : undefined;
  if (!global && !project) return undefined;

  return {
    count:
      (global?.count ?? 0) + PROJECT_FRECENCY_WEIGHT * (project?.count ?? 0),
    lastUsed: Math.max(
      global?.lastUsed ?? Number.NEGATIVE_INFINITY,
      project?.lastUsed ?? Number.NEGATIVE_INFINITY,
    ),
  };
};

const frecencyIndex = (): Index => {
  const index = (globalThis as { __tineFrecency?: unknown }).__tineFrecency;
  return index && typeof index === "object" ? (index as Index) : {};
};

const projectFrecencyIndex = (): Index => {
  const index = (globalThis as { __tineProjectFrecency?: unknown })
    .__tineProjectFrecency;
  return index && typeof index === "object" ? (index as Index) : {};
};

export const updatePriorities = (suggestions: Suggestion[], cmd: string) => {
  const cmdUses = frecencyIndex()[cmd];
  const projectUses = projectFrecencyIndex()[cmd];
  const now = Date.now();

  return suggestions.map((suggestion) => {
    const name = makeArray(suggestion.name)[0] || "";
    const use = blendedUse(cmdUses?.[name], projectUses?.[name]);
    const boost = name === "../" ? 0 : frecencyBoost(use, now);

    const raw = suggestion.priority || 50;
    const priority =
      suggestion.type === "auto-execute"
        ? raw
        : Math.max(Math.min(100, raw), 0);

    const banded = boost && priority >= 50 && priority <= 75 ? 75 : priority;
    return { ...suggestion, priority: banded + boost };
  });
};

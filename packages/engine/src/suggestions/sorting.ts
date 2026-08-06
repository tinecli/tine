import type { Suggestion } from "../shared/internal";
import { makeArray } from "../shared/utils";

// { command: { commandParam: lastUsedMillis } } e.g. git: { add: 2, push: 4 }.
// The app builds this from ~/.zsh_history plus live picks and sets it as
// globalThis.__tineFrecency.
type Index = Record<string, Record<string, number>>;

const recencyIndex = (): Index => {
  const index = (globalThis as { __tineFrecency?: unknown }).__tineFrecency;
  return index && typeof index === "object" ? (index as Index) : {};
};

export const updatePriorities = (suggestions: Suggestion[], cmd: string) => {
  const cmdRecency = recencyIndex()[cmd];

  return suggestions.map((suggestion) => {
    const name = makeArray(suggestion.name)[0] || "";
    const recency = name !== "../" && cmdRecency && cmdRecency[name];
    const recencyBoost = recency ? recency / 10000000000000 : 0;

    let priority = suggestion.priority || 50;
    if (suggestion.type !== "auto-execute") {
      priority = Math.max(Math.min(100, priority), 0);
    }

    if (recency && priority >= 50 && priority <= 75) {
      priority = 75 + recencyBoost;
    } else {
      priority += recencyBoost;
    }
    return { ...suggestion, priority };
  });
};

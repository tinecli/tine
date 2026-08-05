import { getSetting, SETTINGS } from "@tine/api-bindings-wrappers";
import type { Suggestion } from "@tine/shared/internal";
import { makeArray } from "@tine/shared/utils";

// { command: { commandParam: count/lastUsedDate } }
// e.g. git: { add: 2, push: 4 }
type Index = Record<string, Record<string, number>>;

const frequencyIndex: Index = JSON.parse(
  localStorage.getItem("term_frequency_index_fig_only") || "{}",
);
const recencyIndex: Index = JSON.parse(
  localStorage.getItem("term_frequency_index_fig_only_recency") || "{}",
);

// This function is called every time a user does an autocomplete command
export const updateAutocompleteIndexFromUserInsert = (
  cmd: string,
  param: string,
) => {
  if (param.includes("↪")) return;

  const frequencyIndexCmd = frequencyIndex[cmd] || {};
  const recencyIndexCmd = recencyIndex[cmd] || {};

  frequencyIndex[cmd] = {
    ...frequencyIndexCmd,
    [param]: (frequencyIndexCmd[param] || 0) + 1,
  };

  recencyIndex[cmd] = {
    ...recencyIndexCmd,
    [param]: Date.now(),
  };

  // Update frequency index
  localStorage.setItem(
    "term_frequency_index_fig_only",
    JSON.stringify(frequencyIndex),
  );

  // Update recency index
  localStorage.setItem(
    "term_frequency_index_fig_only_recency",
    JSON.stringify(recencyIndex),
  );
};

// tine: the recency index is provided by the app (built from ~/.zsh_history +
// live picks), set as globalThis.__tineFrecency. Falls back to the in-engine
// localStorage index when absent.
const tineRecencyIndex = (): Index | undefined => {
  const g = (globalThis as { __tineFrecency?: unknown }).__tineFrecency;
  return g && typeof g === "object" ? (g as Index) : undefined;
};

export const updatePriorities = (suggestions: Suggestion[], cmd: string) => {
  let idxToUse;

  // Default setting for autocomplete.sortMethod is "recency".
  try {
    if (getSetting(SETTINGS.SORT_METHOD) !== "alphabetical") {
      idxToUse = tineRecencyIndex() ?? recencyIndex;
    }
  } catch (_err) {
    idxToUse = tineRecencyIndex() ?? recencyIndex;
  }

  const cmdRecency = idxToUse && idxToUse[cmd];

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

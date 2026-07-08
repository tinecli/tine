// tine engine entry: bundled to a single JS file loaded into the Swift app's
// JavaScriptCore context. Exposes globalThis.tineSuggest(line, cursor, cwd, cb).
//
// The host (Swift, or Node for tests) must first provide:
//   globalThis.__tineReadFile(path)  -> file contents (string)   [sync ok]
//   globalThis.__tineSpecsDir        -> path to the installed spec pack
//   window / document shims (api-bindings touches them at import)
import { getCommand } from "@tine/shell-parser";
import { parseArguments } from "@tine/autocomplete-parser";
import {
  getAllSuggestions,
  filterSuggestions,
  isTemplateSuggestion,
} from "./src/suggestions/index.js";
import { getQueryTermForSuggestion } from "./src/suggestions/helpers.js";
import { updatePriorities } from "./src/suggestions/sorting.js";
import { getScriptSuggestions } from "./src/generators/scriptSuggestionsGenerator.js";
import { getCustomSuggestions } from "./src/generators/customSuggestionsGenerator.js";
import { getTemplateSuggestions } from "./src/generators/templateSuggestionsGenerator.js";

type TineSuggestion = {
  name: string;
  description: string;
  insertValue: string;
  shouldAddSpace: boolean;
  type: string;
  // Chars before the cursor to replace on insert (basename for paths, so
  // `cd app/So` + Sources/ -> `cd app/Sources/`, not `cd Sources/`).
  queryTerm: string;
  isDangerous: boolean;
  // Matched character positions in `name` (fuzzy search), for highlighting.
  matchIndices: number[];
};

const firstName = (n: string | string[]): string =>
  Array.isArray(n) ? n[0] : n;

// Fig's path escaping (insertion.ts): backslash-escape spaces, or single-quote
// the whole thing when it contains other shell-special chars. Only file/folder
// insertions are escaped — generator/custom insertValues are used verbatim.
const escapeInsertion = (str: string, isFolder: boolean): string => {
  const specialCharsNotSpace = "\\?*'\"#|<>()[]!&".split("");
  if (specialCharsNotSpace.every((char) => !str.includes(char))) {
    return !str.includes(" ") ? str : str.replace(/\s/g, "\\ ");
  }
  if (isFolder) {
    return `'${str.slice(0, -1).replace(/'/g, "'\"'\"'")}'/`;
  }
  return `'${str.replace(/'/g, "'\"'\"'")}'`;
};

type TineResult = { searchTerm: string; items: TineSuggestion[] };

async function suggest(
  line: string,
  cursor: number,
  cwd: string,
): Promise<TineResult> {
  const upToCursor = line.slice(0, Math.max(0, cursor));
  // Shell aliases (set by the app from the user's `alias` output) so `pc ` →
  // `plug-cli ` expands to the aliased command's spec.
  const aliases = (globalThis as { __tineAliases?: Record<string, string> })
    .__tineAliases ?? {};

  // First token (no whitespace before the cursor yet): complete the command
  // name itself from known specs + aliases + history, ranked by frecency.
  // Gated by a Settings switch (globalThis.__tineFirstToken; default on).
  const firstTokenEnabled =
    (globalThis as { __tineFirstToken?: boolean }).__tineFirstToken !== false;
  const partial = upToCursor.trim();
  if (firstTokenEnabled && partial.length > 0 && !/\s/.test(upToCursor.trimStart())) {
    return commandNameResult(partial, aliases);
  }

  const command = getCommand(upToCursor, aliases);
  if (!command) return { searchTerm: "", items: [] };
  const context = {
    currentWorkingDirectory: cwd || "/",
    currentProcess: "",
    sshPrefix: "",
    // HOME lets the path generators expand `~` (e.g. `cd ~/`); set by the host.
    environmentVariables: {
      HOME: (globalThis as { __tineHome?: string }).__tineHome ?? "",
    },
  };
  const parsed = await parseArguments(command as never, context as never);

  // Run the current arg's generators (git branches, folder/file listings, …)
  // via the Swift command bridge, and feed the results in as generator states.
  const generators = (parsed.currentArg as { generators?: unknown[] })?.generators ?? [];
  const genContext = {
    ...context,
    annotations: parsed.annotations.slice(parsed.commandIndex),
    tokenArray: (command.tokens ?? []).slice(parsed.commandIndex).map((t) => t.text),
    isDangerous: Boolean((parsed.currentArg as { isDangerous?: boolean })?.isDangerous),
    searchTerm: parsed.searchTerm,
  };
  const generatorStates: unknown[] = [];
  for (const g of generators as Fig.Generator[]) {
    try {
      let result: Fig.Suggestion[];
      if (g.template) {
        result = await getTemplateSuggestions(g as never, genContext as never);
      } else if (g.script) {
        result = await getScriptSuggestions(g as never, genContext as never, 5000);
      } else {
        result = await getCustomSuggestions(g as never, genContext as never);
        if (g.filterTemplateSuggestions && result[0] && isTemplateSuggestion(result[0] as never)) {
          result = g.filterTemplateSuggestions(result as never) as never;
        }
      }
      // Attach the generator to each suggestion so path filtering
      // (getQueryTerm: "/") strips the directory prefix — fixes `cd app/`.
      const withGen = (result ?? []).map((s) => ({ ...s, generator: g }));
      generatorStates.push({ loading: false, generator: g, result: withGen });
    } catch {
      // Generator failed (bad command, timeout) — skip; static suggestions remain.
      generatorStates.push({ loading: false, generator: g, result: [] });
    }
  }

  const all = getAllSuggestions(
    parsed.currentArg,
    parsed.completionObj,
    parsed.passedOptions,
    parsed.suggestionFlags,
    generatorStates as never,
    parsed.annotations,
  );
  // Boost by the user's frecency (globalThis.__tineFrecency, keyed by the raw
  // first token) and sort so most-used surface first — including the empty
  // search-term case, which filterSuggestions leaves unsorted.
  const rawCmd = upToCursor.trim().split(/\s+/)[0] ?? "";
  const ranked = (updatePriorities(all as never, rawCmd) as typeof all).sort(
    (a, b) =>
      ((b as { priority?: number }).priority ?? 0) -
      ((a as { priority?: number }).priority ?? 0),
  );
  const filtered = filterSuggestions(ranked, parsed.searchTerm, true, false, undefined);
  return { searchTerm: parsed.searchTerm ?? "", items: toItems(filtered, parsed.searchTerm ?? "") };
}

function toItems(filtered: readonly unknown[], searchTerm: string): TineSuggestion[] {
  return filtered.map((s) => {
    const type = (s as { type?: string }).type ?? "";
    const isFolder = type === "folder";
    const raw = (s as { insertValue?: string }).insertValue ?? firstName((s as { name: string | string[] }).name);
    // Matched chars for the displayed name (fuzzyMatchData[0] tracks name[0]).
    const fuzzy = (s as { fuzzyMatchData?: Array<{ indexes?: number[] } | null> }).fuzzyMatchData;
    return {
      name: firstName((s as { name: string | string[] }).name),
      description: (s as { description?: string }).description ?? "",
      insertValue: isFolder || type === "file" ? escapeInsertion(raw, isFolder) : raw,
      shouldAddSpace: (s as { shouldAddSpace?: boolean }).shouldAddSpace ?? false,
      type,
      queryTerm: getQueryTermForSuggestion(s as never, searchTerm),
      isDangerous: Boolean((s as { isDangerous?: boolean }).isDangerous),
      matchIndices: fuzzy?.[0]?.indexes ?? [],
    };
  });
}

// Command names for first-token completion: spec index ∪ aliases ∪ history.
let cachedSpecNames: string[] | undefined;
function specNames(): string[] {
  if (cachedSpecNames) return cachedSpecNames;
  try {
    const g = globalThis as { __tineSpecsDir?: string; __tineReadFile?: (p: string) => string };
    const raw = g.__tineReadFile?.(`${g.__tineSpecsDir ?? ""}/index.json`) ?? "";
    cachedSpecNames = (JSON.parse(raw).completions ?? []) as string[];
  } catch {
    cachedSpecNames = [];
  }
  return cachedSpecNames;
}

function commandNameResult(partial: string, aliases: Record<string, string>): TineResult {
  const frec = (globalThis as { __tineFrecency?: Record<string, Record<string, number>> })
    .__tineFrecency ?? {};
  const names = new Set<string>([...specNames(), ...Object.keys(aliases), ...Object.keys(frec)]);
  const recencyOf = (name: string): number => {
    const params = frec[name];
    return params ? Math.max(0, ...Object.values(params)) : 0;
  };
  const cmds = [...names].map((name) => {
    const r = recencyOf(name);
    return {
      name,
      type: "subcommand",
      insertValue: name,
      shouldAddSpace: true,
      description: aliases[name] ? `alias → ${aliases[name]}` : "",
      priority: r ? Math.min(100, 75 + r / 1e13) : 50,
    };
  });
  const filtered = filterSuggestions(cmds as never, partial, true, false, undefined);
  return { searchTerm: partial, items: toItems(filtered, partial) };
}

// Async result delivered via callback (JSC-friendly; no Swift/JS promise bridge).
(globalThis as Record<string, unknown>).tineSuggest = (
  line: string,
  cursor: number,
  cwd: string,
  cb: (r: TineResult) => void,
): void => {
  suggest(line, cursor, cwd)
    .then((r) => cb(r))
    .catch((e) => {
      (globalThis as Record<string, unknown>).__tineErr = String(e);
      cb({ searchTerm: "", items: [] });
    });
};

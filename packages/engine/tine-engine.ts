// tine engine entry: bundled to a single JS file loaded into the Swift app's
// JavaScriptCore context. Exposes globalThis.tineSuggest(line, cursor, cwd, cb).
//
// The host (Swift, or Node for tests) must first provide:
//   globalThis.__tineReadFile(path)  -> file contents (string)   [sync ok]
//   globalThis.__tineSpecsDir        -> path to the installed spec pack

import "../../app/engine/shims.js";
import { getCustomSuggestions } from "./src/generators/customSuggestionsGenerator.js";
import { getScriptSuggestions } from "./src/generators/scriptSuggestionsGenerator.js";
import { getTemplateSuggestions } from "./src/generators/templateSuggestionsGenerator.js";
import { resetCaches } from "./src/parser/caches.js";
import {
  LoadLocalSpecError,
  MissingSpecError,
  parseArguments,
} from "./src/parser/index.js";
import type { Suggestion } from "./src/shared/internal.js";
import { SuggestionFlag } from "./src/shared/utils.js";
import { getCommand } from "./src/shell-parser/index.js";
import { getQueryTermForSuggestion } from "./src/suggestions/helpers.js";
import { getHistoryValueSuggestions } from "./src/suggestions/history.js";
import {
  filterSuggestions,
  getAllSuggestions,
  isTemplateSuggestion,
} from "./src/suggestions/index.js";
import { frecencyBoost, updatePriorities } from "./src/suggestions/sorting.js";

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

const shellContext = (cwd: string) => ({
  currentWorkingDirectory: cwd || "/",
  currentProcess: "",
  sshPrefix: "",
  // HOME lets the path generators expand `~` (e.g. `cd ~/`); set by the host.
  environmentVariables: {
    HOME: (globalThis as { __tineHome?: string }).__tineHome ?? "",
  },
});

// Shell aliases (set by the app from the user's `alias` output) so `pc ` →
// `plug-cli ` expands to the aliased command's spec.
const shellAliases = (): Record<string, string> => {
  const value = (
    globalThis as {
      __tineAliases?: Record<string, string>;
    }
  ).__tineAliases;
  const aliases: Record<string, string> = Object.create(null);
  if (!value) return aliases;

  for (const [name, command] of Object.entries(value)) {
    aliases[name] = command;
  }
  return aliases;
};

const frecencyIndex = (): Record<string, Record<string, unknown>> => {
  const value = (globalThis as { __tineFrecency?: unknown }).__tineFrecency;
  if (typeof value !== "object" || value === null) return {};

  const index: Record<string, Record<string, unknown>> = {};
  for (const [command, params] of Object.entries(value)) {
    if (
      typeof params === "object" &&
      params !== null &&
      !Array.isArray(params)
    ) {
      index[command] = params;
    }
  }
  return index;
};

// Mirrors SpecLearner.isCommandName (app-side): `tine learn` refuses anything
// this doesn't match — notably a path, which always contains a "/".
const isLearnableCommandName = (name: string): boolean =>
  name.length <= 64 && /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(name);

const learnItResult = (
  upToCursor: string,
  typedCommand: string,
  missingCommand: string,
  resolvedCommand: string,
): TineResult => {
  // Wrapper chains do not earn the row; only the resolved root does.
  if (
    !typedCommand ||
    missingCommand !== resolvedCommand ||
    !isLearnableCommandName(resolvedCommand) ||
    !Object.prototype.hasOwnProperty.call(frecencyIndex(), typedCommand)
  ) {
    return { searchTerm: "", items: [] };
  }

  const queryTerm = upToCursor.split(/\s+/).at(-1) ?? "";
  return {
    searchTerm: "",
    items: [
      {
        name: `no spec for \`${resolvedCommand}\` — learn it`,
        description: `writes a spec from \`${resolvedCommand} --help\``,
        insertValue: `tine learn ${resolvedCommand}`,
        shouldAddSpace: false,
        type: "learn-it",
        queryTerm,
        isDangerous: false,
        matchIndices: [],
      },
    ],
  };
};

async function suggest(
  line: string,
  cursor: number,
  cwd: string,
): Promise<TineResult> {
  const upToCursor = line.slice(0, Math.max(0, cursor));
  const aliases = shellAliases();

  // First token (no whitespace before the cursor yet): complete the command
  // name itself from known specs + aliases + history, ranked by frecency.
  // Gated by a Settings switch (globalThis.__tineFirstToken; default on).
  const firstTokenEnabled =
    (globalThis as { __tineFirstToken?: boolean }).__tineFirstToken !== false;
  const partial = upToCursor.trim();
  if (
    firstTokenEnabled &&
    partial.length > 0 &&
    !/\s/.test(upToCursor.trimStart())
  ) {
    return commandNameResult(partial, aliases);
  }

  const command = getCommand(upToCursor, aliases);
  if (!command) return { searchTerm: "", items: [] };
  const context = shellContext(cwd);
  const parsed = await parseArguments(command as never, context as never).catch(
    rethrowUnlessUnavailableSpec,
  );
  if (
    parsed instanceof LoadLocalSpecError ||
    parsed instanceof MissingSpecError
  ) {
    const history = historyOnlyResult(upToCursor);
    if (history.items.length > 0) return history;
    return learnItResult(
      upToCursor,
      command.tokens[0].originalNode.text,
      parsed.command,
      command.tokens[0].text,
    );
  }

  // Run the current arg's generators (git branches, folder/file listings, …)
  // via the Swift command bridge, and feed the results in as generator states.
  const generators =
    (parsed.currentArg as { generators?: unknown[] })?.generators ?? [];
  const genContext = {
    ...context,
    annotations: parsed.annotations.slice(parsed.commandIndex),
    tokenArray: (command.tokens ?? [])
      .slice(parsed.commandIndex)
      .map((t) => t.text),
    isDangerous: Boolean(
      (parsed.currentArg as { isDangerous?: boolean })?.isDangerous,
    ),
    searchTerm: parsed.searchTerm,
  };
  const generatorStates: unknown[] = [];
  for (const g of generators as Fig.Generator[]) {
    try {
      let result: Fig.Suggestion[];
      if (g.template) {
        result = await getTemplateSuggestions(g as never, genContext as never);
      } else if (g.script) {
        result = await getScriptSuggestions(
          g as never,
          genContext as never,
          5000,
        );
      } else {
        result = await getCustomSuggestions(g as never, genContext as never);
        if (
          g.filterTemplateSuggestions &&
          result[0] &&
          isTemplateSuggestion(result[0] as never)
        ) {
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
  const ranked = [
    ...(updatePriorities(all as never, rawCmd) as typeof all),
    ...historyValues(upToCursor, rawCmd, parsed),
  ].sort(
    (a, b) =>
      ((b as { priority?: number }).priority ?? 0) -
      ((a as { priority?: number }).priority ?? 0),
  );
  const filtered = filterSuggestions(ranked, parsed.searchTerm, true, false);
  return {
    searchTerm: parsed.searchTerm ?? "",
    items: toItems(filtered, parsed.searchTerm ?? ""),
  };
}

// Values the user typed before, offered only where the spec has nothing to say
// about the current arg: no generator to run and no suggestions listed. Keyed by
// the flag in front of the cursor, so `-p` and `-e` pools never mix.
function historyValues(
  upToCursor: string,
  cmd: string,
  parsed: {
    currentArg: { generators?: unknown[]; suggestions?: unknown[] } | null;
    suggestionFlags: number;
  },
): Suggestion[] {
  const arg = parsed.currentArg;
  const specIsSilent =
    Boolean(parsed.suggestionFlags & SuggestionFlag.Args) &&
    arg !== null &&
    !arg.generators?.length &&
    !arg.suggestions?.length;
  if (!specIsSilent) return [];

  return getHistoryValueSuggestions(cmd, historyFlagKey(upToCursor));
}

const rethrowUnlessUnavailableSpec = (err: unknown) => {
  if (err instanceof MissingSpecError || err instanceof LoadLocalSpecError) {
    return err;
  }
  throw err;
};

// No spec for this command — the long tail the specs will never cover. The
// parser has nothing to say, so the user's own values are the whole answer, run
// through the same pools, grammar filter and frecency as the specced path.
function historyOnlyResult(upToCursor: string): TineResult {
  const tokens = upToCursor.trimStart().split(/\s+/);
  const command = tokens[0];
  // Still on the command name: first-token completion handles that, not this.
  if (!command || tokens.length < 2) return { searchTerm: "", items: [] };

  const current = tokens[tokens.length - 1];
  const separator = current.startsWith("-") ? current.indexOf("=") : -1;
  // A flag is being typed, not its value: with no spec there are none to offer.
  if (current.startsWith("-") && separator <= 0) {
    return { searchTerm: "", items: [] };
  }

  const searchTerm = separator > 0 ? current.slice(separator + 1) : current;
  // filterSuggestions leaves the empty-search-term case unsorted, so rank first.
  const ranked = getHistoryValueSuggestions(
    command,
    historyFlagKey(upToCursor),
  ).sort((a, b) => (b.priority ?? 0) - (a.priority ?? 0));
  const filtered = filterSuggestions(ranked, searchTerm, true, false);
  if (filtered.length === 0) return { searchTerm: "", items: [] };
  return { searchTerm, items: toItems(filtered, searchTerm) };
}

// The flag whose value the cursor sits in: the one being typed on in `--net=h`,
// otherwise the token before. "" is the positional pool.
function historyFlagKey(upToCursor: string): string {
  const tokens = upToCursor.split(/\s+/);
  const current = tokens[tokens.length - 1] ?? "";
  const separator = current.startsWith("-") ? current.indexOf("=") : -1;
  if (separator > 0) return current.slice(0, separator);
  const previous = tokens[tokens.length - 2] ?? "";
  if (!previous.startsWith("-") || previous.includes("=")) return "";
  return previous;
}

function toItems(
  filtered: readonly unknown[],
  searchTerm: string,
): TineSuggestion[] {
  return filtered.map((s) => {
    const type = (s as { type?: string }).type ?? "";
    const isFolder = type === "folder";
    const raw =
      (s as { insertValue?: string }).insertValue ??
      firstName((s as { name: string | string[] }).name);
    // Matched chars for the displayed name (fuzzyMatchData[0] tracks name[0]).
    const fuzzy = (
      s as { fuzzyMatchData?: Array<{ indexes?: number[] } | null> }
    ).fuzzyMatchData;
    return {
      name: firstName((s as { name: string | string[] }).name),
      description: (s as { description?: string }).description ?? "",
      insertValue:
        isFolder || type === "file" ? escapeInsertion(raw, isFolder) : raw,
      shouldAddSpace:
        (s as { shouldAddSpace?: boolean }).shouldAddSpace ?? false,
      type,
      queryTerm: getQueryTermForSuggestion(s as never, searchTerm),
      isDangerous: Boolean((s as { isDangerous?: boolean }).isDangerous),
      matchIndices: fuzzy?.[0]?.indexes ?? [],
    };
  });
}

// Command names for first-token completion: spec index ∪ aliases ∪ history.
type SpecIndex = { names: string[]; descriptions: Record<string, string> };

// index.json is external data: keep only string values, on a prototype-less
// object so a name like "toString" cannot inherit one.
const descriptionMap = (value: unknown): Record<string, string> => {
  const map: Record<string, string> = Object.create(null);
  if (typeof value !== "object" || value === null) return map;
  for (const [name, description] of Object.entries(value)) {
    if (typeof description === "string") map[name] = description;
  }
  return map;
};

let cachedSpecIndex: SpecIndex | undefined;
function specIndex(): SpecIndex {
  // Don't cache an empty result: the pack may still be downloading on first run,
  // so re-read until the index has content (then it sticks).
  if (cachedSpecIndex && cachedSpecIndex.names.length) return cachedSpecIndex;
  try {
    const g = globalThis as {
      __tineSpecsDir?: string;
      __tineReadFile?: (p: string) => string;
    };
    const raw =
      g.__tineReadFile?.(`${g.__tineSpecsDir ?? ""}/index.json`) ?? "";
    const parsed = JSON.parse(raw);
    cachedSpecIndex = {
      names: (parsed.completions ?? []) as string[],
      descriptions: descriptionMap(parsed.descriptions),
    };
  } catch {
    cachedSpecIndex = { names: [], descriptions: descriptionMap(undefined) };
  }
  return cachedSpecIndex;
}

function commandNameResult(
  partial: string,
  aliases: Record<string, string>,
): TineResult {
  const frec = frecencyIndex();
  const { names: specs, descriptions } = specIndex();
  const names = new Set<string>([
    ...specs,
    ...Object.keys(aliases),
    ...Object.keys(frec),
  ]);
  const now = Date.now();
  const boostOf = (name: string): number => {
    const params = frec[name];
    if (!params) return 0;
    return Math.max(
      0,
      ...Object.values(params).map((use) => frecencyBoost(use, now)),
    );
  };
  const cmds = [...names].map((name) => {
    const boost = boostOf(name);
    return {
      name,
      type: "subcommand",
      insertValue: name,
      shouldAddSpace: true,
      description: aliases[name]
        ? `alias → ${aliases[name]}`
        : (descriptions[name] ?? ""),
      priority: boost ? 75 + boost : 50,
    };
  });
  const filtered = filterSuggestions(cmds as never, partial, true, false);
  return { searchTerm: partial, items: toItems(filtered, partial) };
}

// `tine ask` composes a command line with the on-device model, and a 3B model
// invents flags. Tine owns a parser and a spec corpus for exactly this: run the
// line through the parser before anyone sees it.
type TineValidation = { status: string; token: string; dangerous: boolean };

// The parser is lenient with the *final* token — that one is the search term
// being typed. A trailing space makes every word of the line a non-final token,
// so each is checked against the spec.
async function parseLine(line: string): Promise<TineValidation> {
  const command = getCommand(`${line} `, shellAliases());
  if (!command || !line.trim()) {
    return { status: "unparsed", token: "", dangerous: false };
  }
  try {
    const parsed = await parseArguments(
      command as never,
      shellContext("/") as never,
    );
    // A dangerous arg the line already filled is no longer the *current* one, so
    // the question is whether this subcommand declares one at all — which is what
    // marks `rm`, and what the panel colours red.
    const args = (parsed.completionObj.args ?? []) as Array<{
      isDangerous?: boolean;
    }>;
    return {
      status: "ok",
      token: "",
      dangerous: args.some((arg) => arg.isDangerous),
    };
  } catch (e) {
    if (e instanceof MissingSpecError) {
      return { status: "nospec", token: "", dangerous: false };
    }
    return { status: "invalid", token: "", dangerous: false };
  }
}

async function validate(line: string): Promise<TineValidation> {
  const result = await parseLine(line);
  if (result.status !== "invalid") return result;
  return { ...result, token: await offendingWord(line) };
}

// Which word the spec has no place for. The parser reports *that* a token could
// not be consumed, never which — so the line is re-parsed a word at a time, and
// the word that first fails is the one to tell the model about.
async function offendingWord(line: string): Promise<string> {
  const words = line.split(/\s+/).filter(Boolean);
  for (let i = 2; i <= words.length; i += 1) {
    const { status } = await parseLine(words.slice(0, i).join(" "));
    if (status === "invalid") return words[i - 1];
  }
  return "";
}

(globalThis as Record<string, unknown>).tineValidate = (
  line: string,
  cb: (r: TineValidation) => void,
): void => {
  validate(line)
    .then((r) => cb(r))
    .catch(() => cb({ status: "unparsed", token: "", dangerous: false }));
};

// `tine learn` wrote a spec into a location the loader already reads, so only the
// cached specs stand between the new file and the next suggestion.
(globalThis as Record<string, unknown>).tineResetSpecs = resetCaches;

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

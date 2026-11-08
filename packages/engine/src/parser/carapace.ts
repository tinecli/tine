import type { Subcommand } from "../shared/internal.js";
import { createCache } from "./caches.js";
import { convertSubcommand, initializeDefault } from "./convertSpec.js";

type Carapace = {
  exe: string;
  descriptions: Map<string, string>;
  only: boolean;
  builtins: Set<string>;
  demoted: Set<string>;
  flagsWithValues: boolean;
};

const carapaceCache = createCache<Carapace | null>();

export function carapace(): Carapace | null {
  const cached = carapaceCache.get("carapace");
  if (cached !== undefined) return cached;

  const g = globalThis as {
    __tineCompletionSource?: unknown;
    __tineCarapaceExe?: unknown;
    __tineCarapaceCompleters?: unknown;
    __tineBuiltinSpecNames?: unknown;
    __tineCarapaceDemotedGroups?: unknown;
    __tineCarapaceFlagsWithValues?: unknown;
  };
  const { __tineCompletionSource: source, __tineCarapaceExe: exe } = g;
  const completers = g.__tineCarapaceCompleters;
  const builtins = g.__tineBuiltinSpecNames;
  const demoted = g.__tineCarapaceDemotedGroups;
  const value =
    (source === "carapace" || source === "carapaceOnly") &&
    typeof exe === "string" &&
    exe
      ? {
          exe,
          descriptions: new Map(
            Object.entries(
              typeof completers === "object" && completers !== null
                ? completers
                : {},
            ).map(([cli, description]): [string, string] => [
              cli,
              typeof description === "string" ? description : "",
            ]),
          ),
          only: source === "carapaceOnly",
          builtins: new Set(
            Array.isArray(builtins)
              ? builtins.filter((n): n is string => typeof n === "string")
              : [],
          ),
          demoted: new Set(
            Array.isArray(demoted)
              ? demoted.filter((n): n is string => typeof n === "string")
              : [],
          ),
          flagsWithValues: g.__tineCarapaceFlagsWithValues !== false,
        }
      : null;
  carapaceCache.set("carapace", value);
  return value;
}

const carapaceSuggestions = (
  output: string,
  demoted: Set<string>,
): Fig.Suggestion[] => {
  if (!output) return [];

  const parsed: { values?: unknown; nospace?: unknown } = JSON.parse(output);
  const noSpace = typeof parsed.nospace === "string" ? parsed.nospace : "";
  const values: unknown[] = Array.isArray(parsed.values) ? parsed.values : [];
  return values.flatMap(
    (entry): Array<Fig.Suggestion & { shouldAddSpace: boolean }> => {
      if (typeof entry !== "object" || entry === null) return [];
      const { value, description, tag } = entry as Record<string, unknown>;
      if (typeof value !== "string" || !value) return [];

      const label = typeof tag === "string" ? tag : "";
      const suggestion = {
        name: value,
        insertValue: value,
        description: typeof description === "string" ? description : undefined,
        shouldAddSpace: noSpace !== "*" && !noSpace.includes(value.slice(-1)),
        priority: demoted.has(label)
          ? 40
          : label.endsWith("flags")
            ? 45
            : undefined,
      };
      if (label.endsWith("flags")) return [{ ...suggestion, type: "option" }];
      if (label.endsWith("commands")) {
        return [{ ...suggestion, type: "subcommand" }];
      }
      if (label !== "files" && label !== "directories") {
        return [{ ...suggestion, type: "arg" }];
      }
      return [{ ...suggestion, type: value.endsWith("/") ? "folder" : "file" }];
    },
  );
};

export const carapaceSpec = (
  name: string,
  { exe, demoted, flagsWithValues }: Carapace,
): Subcommand => ({
  ...convertSubcommand(
    {
      name,
      args: {
        isVariadic: true,
        generators: [
          {
            script: (tokens) => {
              const word = tokens[tokens.length - 1] ?? "";
              // Cut so the host's per-args process cache holds while a word is typed.
              const cut = Math.max(word.lastIndexOf("/"), word.indexOf("="));
              const flag = word.startsWith("-") ? "-" : "";
              const prefix = cut >= 0 ? word.slice(0, cut + 1) : flag;
              return [
                exe,
                name,
                "export",
                name,
                ...tokens.slice(1, -1),
                prefix,
              ];
            },
            postProcess: (output) => carapaceSuggestions(output, demoted),
            scriptTimeout: 3000,
          },
          {
            script: (tokens) =>
              flagsWithValues && tokens.at(-1) === ""
                ? [exe, name, "export", name, ...tokens.slice(1, -1), "-"]
                : [],
            postProcess: (output) => carapaceSuggestions(output, demoted),
            scriptTimeout: 3000,
          },
        ],
      },
    },
    initializeDefault,
  ),
  tineCarapace: true,
});

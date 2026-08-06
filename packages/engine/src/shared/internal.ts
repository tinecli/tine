import type { Result } from "../fuzzysort.js";

export type SpecLocation = Fig.SpecLocation & {
  diffVersionedFile?: string;
};

type Override<T, S> = Omit<T, keyof S> & S;
export type SuggestionType = Fig.SuggestionType | "history" | "auto-execute";
export type Suggestion<ArgT = Arg> = Override<
  Fig.Suggestion,
  {
    type?: SuggestionType;
    // Whether or not to add a space after suggestion, e.g. if user completes a
    // subcommand that takes a mandatory arg.
    shouldAddSpace?: boolean;
    // Whether or not to add a separator after suggestion, e.g. for options with requiresSeparator
    separatorToAdd?: string;
    args?: ArgT[];
    // Generator information to determine whether suggestion should be filtered.
    generator?: Fig.Generator;
    getQueryTerm?: (x: string) => string;
    fuzzyMatchData?: (Result | null)[];
    originalType?: SuggestionType;
  }
>;

export type LoadSpec =
  | Fig.SpecLocation[]
  | Subcommand
  | ((
      token: string,
      executeCommand: Fig.ExecuteCommandFunction,
    ) => Promise<Fig.SpecLocation[] | Subcommand>);

export type Arg = Omit<Fig.Arg, "template" | "generators" | "loadSpec"> & {
  generators: Fig.Generator[];
  loadSpec?: LoadSpec;
};

export type OptionMeta = Omit<Fig.Option, "args" | "name">;

export type Option = OptionMeta & {
  name: string[];
  args: Arg[];
};

export type SubcommandMeta = Omit<
  Fig.Subcommand,
  "subcommands" | "options" | "loadSpec" | "persistentOptions" | "args" | "name"
> & {
  loadSpec?: LoadSpec;
};

export type Subcommand = SubcommandMeta & {
  name: string[];
  subcommands: Record<string, Subcommand>;
  options: Record<string, Option>;
  persistentOptions: Record<string, Option>;
  args: Arg[];
};

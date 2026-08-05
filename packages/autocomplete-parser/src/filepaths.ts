import { ensureTrailingSlash } from "@tine/shared/utils";

export type FilepathsOptions = {
  extensions?: string[];
  equals?: string[];
  matches?: RegExp;
  filterFolders?: boolean;
  editFileSuggestions?: Omit<Fig.Suggestion, "name" | "type">;
  editFolderSuggestions?: Omit<Fig.Suggestion, "name" | "type">;
  rootDirectory?: string;
  showFolders?: "always" | "never" | "only";
};

const replaceTilde = (path: string, homeDir: string): string =>
  path.startsWith("~") && (path.length === 1 || path.charAt(1) === "/")
    ? path.replace("~", homeDir)
    : path;

const replaceVariables = (
  path: string,
  environmentVariables: Record<string, string>,
): string =>
  path
    .replace(
      /\$([A-Za-z0-9_]+)/g,
      (key) => environmentVariables[key.slice(1)] ?? key,
    )
    .replace(
      /\$\{([A-Za-z0-9_]+)(?::-([^}]+))?\}/g,
      (match, envKey, defaultValue) =>
        environmentVariables[envKey] ?? defaultValue ?? match,
    );

const shellExpand = (path: string, context: Fig.ShellContext): string => {
  const environmentVariables = context.environmentVariables ?? {};
  return replaceVariables(
    replaceTilde(path, environmentVariables.HOME ?? "~"),
    environmentVariables,
  );
};

// Files starting with "." sort after the rest; "../" is always offered last.
const sortFilesAlphabetically = (
  array: string[],
  skip: string[] = [],
): string[] => {
  const skipLower = skip.map((str) => str.toLowerCase());
  const results = array.filter((x) => !skipLower.includes(x.toLowerCase()));
  return [
    ...results
      .filter((x) => !x.startsWith("."))
      .sort((a, b) => a.localeCompare(b)),
    ...results
      .filter((x) => x.startsWith("."))
      .sort((a, b) => a.localeCompare(b)),
    "../",
  ];
};

const getCurrentInsertedDirectory = (
  cwd: string | null,
  searchTerm: string,
  context: Fig.ShellContext,
): string => {
  if (cwd === null) return "/";
  const resolvedPath = shellExpand(searchTerm, context);
  const dirname = resolvedPath.slice(0, resolvedPath.lastIndexOf("/") + 1);
  if (dirname === "") return ensureTrailingSlash(cwd);
  return dirname.startsWith("/")
    ? dirname
    : `${ensureTrailingSlash(cwd)}${dirname}`;
};

function filepathsFn(options: FilepathsOptions = {}): Fig.Generator {
  const {
    extensions = [],
    equals = [],
    matches,
    filterFolders = false,
    editFileSuggestions,
    editFolderSuggestions,
    rootDirectory,
    showFolders = "always",
  } = options;

  const extensionsSet = new Set(extensions);
  const equalsSet = new Set(equals);
  const shouldFilterSuggestions = () =>
    extensions.length > 0 || equals.length > 0 || matches;

  const filterSuggestions = (suggestions: Fig.Suggestion[] = []) => {
    if (!shouldFilterSuggestions()) return suggestions;
    return suggestions.filter(({ name = "", type }) => {
      if (!filterFolders && type === "folder") return true;
      if (typeof name !== "string") return false;
      if (equalsSet.has(name)) return true;
      if (matches && name.match(matches)) return true;

      const [, ...suggestionExtensions] = name.split(".");
      if (suggestionExtensions.length >= 1) {
        let i = suggestionExtensions.length - 1;
        let stackedExtensions = suggestionExtensions[i];
        do {
          if (extensionsSet.has(stackedExtensions)) return true;
          i -= 1;
          stackedExtensions = [suggestionExtensions[i], stackedExtensions].join(
            ".",
          );
        } while (i >= 0);
      }
      return false;
    });
  };

  const postProcessSuggestions = (suggestions: Fig.Suggestion[] = []) => {
    if (!editFileSuggestions && !editFolderSuggestions) return suggestions;
    return suggestions.map((suggestion) => ({
      ...suggestion,
      ...((suggestion.type === "file"
        ? editFileSuggestions
        : editFolderSuggestions) || {}),
    }));
  };

  return {
    trigger: (oldToken, newToken) => {
      const oldLastSlashIndex = oldToken.lastIndexOf("/");
      const newLastSlashIndex = newToken.lastIndexOf("/");
      // The final path segment changed: suggest for the new directory.
      if (oldLastSlashIndex !== newLastSlashIndex) return true;
      // No slashes at all: don't re-trigger on every keystroke.
      if (oldLastSlashIndex === -1 && newLastSlashIndex === -1) return false;
      return (
        oldToken.slice(0, oldLastSlashIndex) !==
        newToken.slice(0, newLastSlashIndex)
      );
    },
    getQueryTerm: (token) => token.slice(token.lastIndexOf("/") + 1),
    custom: async (_tokens, executeCommand, generatorContext) => {
      const { isDangerous, currentWorkingDirectory, searchTerm } =
        generatorContext;
      const currentInsertedDirectory =
        getCurrentInsertedDirectory(
          rootDirectory ?? currentWorkingDirectory,
          searchTerm,
          generatorContext,
        ) ?? "/";
      try {
        const data = await executeCommand({
          command: "ls",
          args: ["-1ApL"],
          cwd: currentInsertedDirectory,
        });
        const sortedFiles = sortFilesAlphabetically(data.stdout.split("\n"), [
          ".DS_Store",
        ]);
        const generatorOutputArray: Fig.Suggestion[] = [];
        for (const name of sortedFiles) {
          if (!name) continue;
          const templateType = name.endsWith("/") ? "folders" : "filepaths";
          if (
            (templateType === "filepaths" && showFolders !== "only") ||
            (templateType === "folders" && showFolders !== "never")
          ) {
            generatorOutputArray.push({
              type: templateType === "filepaths" ? "file" : "folder",
              name,
              insertValue: name,
              isDangerous,
              context: { templateType },
            } as Fig.TemplateSuggestion);
          }
        }
        return postProcessSuggestions(filterSuggestions(generatorOutputArray));
      } catch (_err) {
        return [];
      }
    },
  };
}

// Callable (`filepaths({ extensions })` inside a spec) *and* usable directly as
// a generator object. Object.assign copies the frozen generator's own props onto
// the function, so the result stays writable — parseArguments sets
// filterTemplateSuggestions on it.
export const folders = Object.assign(
  () => filepathsFn({ showFolders: "only" }),
  Object.freeze(filepathsFn({ showFolders: "only" })),
);

export const filepaths = Object.assign(
  filepathsFn,
  Object.freeze(filepathsFn()),
);

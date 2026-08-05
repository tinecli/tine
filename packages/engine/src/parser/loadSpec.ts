import { convertSubcommand, initializeDefault } from "@fig/autocomplete-shared";
import { executeCommand } from "../shared/execShell.js";
import type { SpecLocation, Subcommand } from "../shared/internal.js";
import { type Logger, logger } from "../shared/log.js";
import {
  ensureTrailingSlash,
  SpecLocationSource,
  splitPath,
  withTimeout,
} from "../shared/utils.js";
import { specCache } from "./caches.js";
import { MissingSpecError } from "./errors.js";
import {
  importFromPublicCDN,
  importSpecFromFile,
  isDiffVersionedSpec,
  publicSpecExists,
  type SpecFileImport,
} from "./loadHelpers.js";
import { mergeSubcommand } from "./mergeSubcommand.js";
import { tryResolveSpecToSubcommand } from "./tryResolveSpecToSubcommand.js";

/**
 * This searches for the first directory containing a .fig/ folder in the parent directories
 */
const searchFigFolder = async (currentDirectory: string) => {
  try {
    return ensureTrailingSlash(
      (
        await executeCommand({
          command: "bash",
          args: [
            "-c",
            `until [[ -f .fig/autocomplete/build/_shortcuts.js ]] || [[ $PWD = $HOME ]] || [[ $PWD = "/" ]]; do cd ..; done; echo $PWD`,
          ],
          cwd: currentDirectory,
        })
      ).stdout,
    );
  } catch {
    return ensureTrailingSlash(currentDirectory);
  }
};

export const serializeSpecLocation = (location: SpecLocation): string => {
  if (location.type === SpecLocationSource.GLOBAL) {
    return `global://name=${location.name}`;
  }
  return `local://path=${location.path ?? ""}&name=${location.name}`;
};

export const getSpecPath = async (
  name: string,
  cwd: string,
  isScript?: boolean,
): Promise<SpecLocation> => {
  if (name === "?") {
    // If the user is searching for _shortcuts.js by using "?"
    const path = await searchFigFolder(cwd);
    return { name: "_shortcuts", type: SpecLocationSource.LOCAL, path };
  }

  if (name === "+") {
    return { name: "+", type: SpecLocationSource.LOCAL, path: "~/" };
  }

  const [path, basename] = splitPath(name);

  if (!isScript) {
    const type = SpecLocationSource.GLOBAL;

    // If `isScript` is undefined, we are parsing the first token, and
    // any path with a / is a script.
    if (isScript === undefined) {
      // special-case: Symfony has "bin/console" which can be invoked directly
      // and should not require a user to create script completions for it
      if (name === "bin/console" || name.endsWith("/bin/console")) {
        return { name: "php/bin-console", type };
      }
      if (!path.includes("/")) {
        return { name, type };
      }
    } else if (["/", "./", "~/"].every((prefix) => !path.startsWith(prefix))) {
      return { name, type };
    }
  }

  const type = SpecLocationSource.LOCAL;
  if (path.startsWith("/") || path.startsWith("~/")) {
    return { name: basename, type, path };
  }

  const relative = path.startsWith("./") ? path.slice(2) : path;
  return { name: basename, type, path: `${cwd}/${relative}` };
};

type ResolvedSpecLocation =
  | { type: "public"; name: string }
  | { type: "private"; namespace: string; name: string };

export const importSpecFromLocation = async (
  specLocation: SpecLocation,
  localLogger: Logger = logger,
): Promise<{
  specFile: SpecFileImport;
  resolvedLocation?: ResolvedSpecLocation;
}> => {
  let specFile: SpecFileImport | undefined;
  let resolvedLocation: ResolvedSpecLocation | undefined;

  if (specLocation.type === SpecLocationSource.LOCAL) {
    const { name, path } = specLocation;
    const [dirname, basename] = splitPath(`${path || "~/"}${name}`);

    specFile = await importSpecFromFile(
      basename,
      `${dirname}.fig/autocomplete/build/`,
      localLogger,
    );
  } else {
    const { name, diffVersionedFile: versionFileName } = specLocation;

    // The pack is the base; the user's own specs (~/.tine/specs) are merged on
    // top in loadSubcommandCached rather than shadowing the pack here.
    if (await publicSpecExists(name)) {
      // If we're here, importing was successful.
      try {
        const result = await importFromPublicCDN(
          versionFileName ? `${name}/${versionFileName}` : name,
        );

        specFile = result;
        resolvedLocation = { type: "public", name };
      } catch (err) {
        localLogger.error("Unable to load from CDN", err);
        throw err;
      }
    } else {
      try {
        specFile = await importSpecFromFile(
          name,
          `~/.fig/autocomplete/build/`,
          localLogger,
        );
      } catch (_err) {
        /* empty */
      }
    }
  }

  if (!specFile) {
    throw new MissingSpecError("No spec found");
  }

  return { specFile, resolvedLocation };
};

export const loadFigSubcommand = async (
  specLocation: SpecLocation,
  _context?: Fig.ShellContext,
  localLogger: Logger = logger,
): Promise<Fig.Subcommand> => {
  const { name } = specLocation;
  const location = (await isDiffVersionedSpec(name))
    ? { ...specLocation, diffVersionedFile: "index" }
    : specLocation;
  const { specFile } = await importSpecFromLocation(location, localLogger);
  const subcommand = await tryResolveSpecToSubcommand(specFile, specLocation);
  return subcommand;
};

export const loadSubcommandCached = async (
  specLocation: SpecLocation,
  context?: Fig.ShellContext,
  localLogger: Logger = logger,
): Promise<Subcommand> => {
  const { name, type: source } = specLocation;
  const path =
    specLocation.type === SpecLocationSource.LOCAL ? specLocation.path : "";

  const key = [source, path || "", name].join(",");
  if (specCache.has(key)) {
    return specCache.get(key) as Subcommand;
  }

  // Base spec (the pack). Missing is not fatal: a command may exist only as a
  // user spec (a command not in the pack).
  let merged: Subcommand | undefined;
  try {
    const subcommand = await withTimeout(
      5000,
      loadFigSubcommand(specLocation, context, localLogger),
    );
    merged = convertSubcommand(subcommand, initializeDefault);
  } catch (err) {
    if (!(err instanceof MissingSpecError)) throw err;
  }

  // User specs (GLOBAL commands only — scripts/.fig keep their own resolution).
  // Each configured location holds, for a command <cmd>:
  //   <cmd>.js           REPLACES the pack spec — kept for backwards compatibility
  //   override/<cmd>.js  REPLACES the pack spec (wins over the root file)
  //   extend/<cmd>.js    is MERGED on top additively (keeps the pack, adds to it)
  // Locations are in priority order: the first with an override wins; every
  // location's extend is merged (earlier/higher-priority wins name collisions).
  if (source === SpecLocationSource.GLOBAL) {
    const dirs =
      (globalThis as { __tineLocalSpecsDirs?: string[] })
        .__tineLocalSpecsDirs ?? [];
    for (const dir of dirs) {
      const override =
        (await loadUserSpec(specLocation, `${dir}/override`, localLogger)) ??
        (await loadUserSpec(specLocation, dir, localLogger));
      if (override) {
        merged = override;
        break;
      }
    }
    for (const dir of dirs) {
      const extension = await loadUserSpec(
        specLocation,
        `${dir}/extend`,
        localLogger,
      );
      if (extension)
        merged = merged ? mergeSubcommand(merged, extension) : extension;
    }
  }

  if (!merged) throw new MissingSpecError("No spec found");
  specCache.set(key, merged);
  return merged;
};

/** Load + convert a user spec for `name` from `dir`, or undefined if absent. */
const loadUserSpec = async (
  specLocation: SpecLocation,
  dir: string,
  localLogger: Logger,
): Promise<Subcommand | undefined> => {
  try {
    const specFile = await importSpecFromFile(
      specLocation.name,
      dir,
      localLogger,
    );
    const subcommand = await tryResolveSpecToSubcommand(specFile, specLocation);
    return convertSubcommand(subcommand, initializeDefault);
  } catch {
    return undefined;
  }
};

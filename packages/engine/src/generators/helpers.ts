import type { Annotation } from "../parser/index";
import type { Suggestion } from "../shared/internal";
import { getCWDForFilesAndFolders } from "../shared/utils";
import { Cache } from "./cache";

export type GeneratorContext = Fig.ShellContext & {
  annotations: Annotation[];
  tokenArray: string[];
  isDangerous?: boolean;
  searchTerm: string;
};

export type GeneratorState = {
  generator: Fig.Generator;
  context: GeneratorContext;
  loading: boolean;
  result: Suggestion[];
  request?: Promise<Fig.Suggestion[]>;
};

export const haveContextForGenerator = (context: GeneratorContext): boolean =>
  Boolean(context.currentWorkingDirectory);

export const generatorCache = new Cache();

export async function runCachedGenerator<T>(
  generator: Fig.Generator,
  context: GeneratorContext,
  initialRun: () => Promise<T>,
  cacheKey?: string /* This is generator.script or generator.script(...) */,
): Promise<T> {
  const { cache } = generator;
  if (!cache) {
    return initialRun();
  }
  const { tokenArray, currentWorkingDirectory, searchTerm } = context;

  const directory = generator.template
    ? getCWDForFilesAndFolders(currentWorkingDirectory, searchTerm)
    : currentWorkingDirectory;

  // we cache generator results by script, if no script was provided we use the tokens instead
  const key = [
    cache.cacheByDirectory ? directory : undefined,
    cacheKey || tokenArray.join(" "),
  ].toString();

  return generatorCache.entry(key, initialRun, cache);
}

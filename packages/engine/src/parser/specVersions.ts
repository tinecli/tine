import { compare } from "./semver.js";

// A spec diff is untyped JSON layered onto a spec, so merging works over plain
// records and casts back to Fig.Subcommand at the boundary.
type Node = Record<string, unknown>;
type Merge = (current: Node | undefined, diff: Node) => Node;
type MergeProperty = (current: unknown, diff: unknown) => unknown;

const asNode = (value: unknown): Node =>
  typeof value === "object" && value !== null ? (value as Node) : {};

const asNodes = (value: unknown): Node[] => {
  if (!value) return [];
  return (Array.isArray(value) ? value : [value]).map(asNode);
};

const asNames = (name: unknown): string[] => {
  if (typeof name === "string") return [name];
  if (!Array.isArray(name)) return [];
  return name.filter((part): part is string => typeof part === "string");
};

const namesMatch = (a: Node, b: Node): boolean => {
  const names = new Set(asNames(a.name));
  return asNames(b.name).some((name) => names.has(name));
};

const mergeSimpleObject: Merge = (current, diff) => ({ ...current, ...diff });

const mergeOrderedArrays = (
  current: Node[],
  diffs: Node[],
  merge: Merge,
): Node[] =>
  diffs
    .filter((diff) => !diff.remove)
    .map((diff, i) => merge(current[i], diff));

const mergeNamedArrays = (
  current: Node[],
  diffs: Node[],
  merge: Merge,
): Node[] => {
  const updated: Node[] = [];
  const merged = new Set<number>();

  for (const diff of diffs) {
    const index = current.findIndex(
      (entry, i) => !merged.has(i) && namesMatch(entry, diff),
    );
    if (index === -1) {
      updated.push(diff);
      continue;
    }
    merged.add(index);
    if (!("remove" in diff)) updated.push(merge(current[index], diff));
  }

  current.forEach((entry, i) => {
    if (!merged.has(i)) updated.push(entry);
  });
  return updated;
};

const makeMerge =
  (properties: Record<string, MergeProperty>): Merge =>
  (current, diff) => {
    const merged: Node = { ...current, ...diff };
    for (const key of Object.keys(properties)) {
      if (diff[key]) merged[key] = properties[key](current?.[key], diff[key]);
    }
    return merged;
  };

const mergeArgs: MergeProperty = (current, diff) =>
  mergeOrderedArrays(asNodes(current), asNodes(diff), mergeSimpleObject);

const mergeOption = makeMerge({ args: mergeArgs });

const properties: Record<string, MergeProperty> = {
  subcommands: (current, diff) =>
    mergeNamedArrays(asNodes(current), asNodes(diff), (a, b) =>
      mergeSubcommand(a, b),
    ),
  options: (current, diff) =>
    mergeNamedArrays(asNodes(current), asNodes(diff), mergeOption),
  args: mergeArgs,
};

const mergeSubcommand = makeMerge(properties);

export const applySpecDiff = (
  spec: Fig.Subcommand,
  diff: Fig.SpecDiff,
): Fig.Subcommand =>
  mergeSubcommand(asNode(spec), {
    ...asNode(diff),
    name: spec.name,
  }) as unknown as Fig.Subcommand;

// The last version at or below the target, or the newest when unknown.
const getBestVersionIndex = (versions: string[], target?: string): number => {
  if (!target) return versions.length - 1;
  for (let i = versions.length - 1; i >= 0; i -= 1) {
    if (compare(versions[i], target) <= 0) return i;
  }
  return versions.length - 1;
};

export const getVersionFromVersionedSpec = (
  base: Fig.Subcommand,
  versions: Fig.VersionDiffMap,
  target?: string,
): { spec: Fig.Subcommand; version: string } => {
  const versionNames = Object.keys(versions).sort(compare);
  const versionIndex = getBestVersionIndex(versionNames, target);
  const spec = versionNames
    .slice(0, versionIndex + 1)
    .map((name) => versions[name])
    .reduce((merged, diff) => applySpecDiff(merged, diff), base);
  return { spec, version: versionNames[versionIndex] };
};

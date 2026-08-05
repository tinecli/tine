const strip = (version: string) =>
  version
    .trim()
    .replace(/^[=v]+/, "")
    .split("+")[0];

const SEMVER = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z-.]+))?$/;

export const clean = (version: string): string | null => {
  const match = SEMVER.exec(strip(version));
  if (!match) return null;
  const [, major, minor, patch, prerelease] = match;
  const release = `${Number(major)}.${Number(minor)}.${Number(patch)}`;
  return prerelease ? `${release}-${prerelease}` : release;
};

const parse = (version: string) => {
  const [release, ...rest] = strip(version).split("-");
  const prerelease = rest.join("-");
  return {
    release: release.split(".").map((part) => Number.parseInt(part, 10) || 0),
    prerelease: prerelease ? prerelease.split(".") : [],
  };
};

const order = (a: number | string, b: number | string) =>
  a === b ? 0 : a < b ? -1 : 1;

// Numeric identifiers always rank below alphanumeric ones.
const compareIdentifiers = (a: string, b: string): number => {
  const [numA, numB] = [Number(a), Number(b)];
  const [isNumA, isNumB] = [!Number.isNaN(numA), !Number.isNaN(numB)];
  if (isNumA && isNumB) return order(numA, numB);
  if (isNumA) return -1;
  if (isNumB) return 1;
  return order(a, b);
};

export const compare = (a: string, b: string): number => {
  const left = parse(a);
  const right = parse(b);

  for (let i = 0; i < 3; i += 1) {
    const result = order(left.release[i] ?? 0, right.release[i] ?? 0);
    if (result !== 0) return result;
  }

  if (!left.prerelease.length && !right.prerelease.length) return 0;
  if (!left.prerelease.length) return 1;
  if (!right.prerelease.length) return -1;

  const length = Math.max(left.prerelease.length, right.prerelease.length);
  for (let i = 0; i < length; i += 1) {
    const [x, y] = [left.prerelease[i], right.prerelease[i]];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const result = compareIdentifiers(x, y);
    if (result !== 0) return result;
  }
  return 0;
};

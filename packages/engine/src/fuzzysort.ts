export type Result = {
  readonly score: number;
  readonly target: string;
  readonly indexes: readonly number[];
};

const WORD_START_PENALTY = 30;
const WORD_INTERIOR_PENALTY = 60;
const WORD_START_GAP_PENALTY = 100;
const WORD_INTERIOR_GAP_PENALTY = 200;
const NOISE_PENALTY_CAP = 25;

const SEPARATOR = /[\s\-_./\\:,=@]/;

const isUpperCase = (char: string) =>
  char === char.toUpperCase() && char !== char.toLowerCase();

const equalsIgnoringCase = (a: string, b: string) =>
  a === b || a.toLowerCase() === b.toLowerCase();

const startsWord = (target: string, index: number) => {
  if (index === 0) {
    return true;
  }
  const previous = target[index - 1];
  if (SEPARATOR.test(previous)) {
    return true;
  }
  return !isUpperCase(previous) && isUpperCase(target[index]);
};

const matchesAt = (search: string, target: string, start: number) => {
  for (let offset = 0; offset < search.length; offset += 1) {
    if (!equalsIgnoringCase(search[offset], target[start + offset])) {
      return false;
    }
  }
  return true;
};

const startPenalty = (target: string, start: number) => {
  if (start === 0) {
    return 0;
  }
  return startsWord(target, start) ? WORD_START_PENALTY : WORD_INTERIOR_PENALTY;
};

const gapPenalty = (target: string, indexes: readonly number[]) => {
  let total = 0;
  for (let position = 1; position < indexes.length; position += 1) {
    const index = indexes[position];
    if (index === indexes[position - 1] + 1) {
      continue;
    }
    total += startsWord(target, index)
      ? WORD_START_GAP_PENALTY
      : WORD_INTERIOR_GAP_PENALTY;
  }
  return total;
};

const caseMismatches = (
  search: string,
  target: string,
  indexes: readonly number[],
) =>
  indexes.reduce(
    (count, index, position) =>
      target[index] === search[position] ? count : count + 1,
    0,
  );

const penalty = (
  search: string,
  target: string,
  indexes: readonly number[],
) => {
  const noise =
    caseMismatches(search, target, indexes) + target.length - search.length;
  return (
    startPenalty(target, indexes[0]) +
    gapPenalty(target, indexes) +
    Math.min(noise, NOISE_PENALTY_CAP)
  );
};

const contiguousIndexes = (start: number, length: number) =>
  Array.from({ length }, (_, offset) => start + offset);

const bestContiguousMatch = (search: string, target: string) => {
  let best: number[] | null = null;
  let bestPenalty = Number.POSITIVE_INFINITY;
  for (let start = 0; start <= target.length - search.length; start += 1) {
    if (!matchesAt(search, target, start)) {
      continue;
    }
    const indexes = contiguousIndexes(start, search.length);
    const candidatePenalty = penalty(search, target, indexes);
    if (candidatePenalty < bestPenalty) {
      best = indexes;
      bestPenalty = candidatePenalty;
    }
  }
  return best;
};

const scatteredMatch = (search: string, target: string) => {
  const indexes: number[] = [];
  let cursor = 0;
  for (let position = 0; position < search.length; position += 1) {
    while (
      cursor < target.length &&
      !equalsIgnoringCase(search[position], target[cursor])
    ) {
      cursor += 1;
    }
    if (cursor === target.length) {
      return null;
    }
    indexes.push(cursor);
    cursor += 1;
  }
  return indexes;
};

export const single = (search: string, target: string): Result | null => {
  if (search === "") {
    return { score: 0, target, indexes: [] };
  }
  if (search.length > target.length) {
    return null;
  }
  const indexes =
    bestContiguousMatch(search, target) ?? scatteredMatch(search, target);
  if (!indexes) {
    return null;
  }
  return { score: 0 - penalty(search, target, indexes), target, indexes };
};

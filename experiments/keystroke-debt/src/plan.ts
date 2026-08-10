import { commandsIn, type Entry } from "./history.js";
import type { Owner, Shell } from "./shell.js";

export type Occurrence = { tokens: string[]; at: number | null };
export type Collision = { name: string; owner: Owner; body: string | null };
export type Refinance = {
  name: string;
  phrase: string;
  uses: number;
  saved: number;
  collisions: Collision[];
};
export type DeadAlias = { name: string; body: string; longhandUses: number };
export type Plan = {
  refinances: Refinance[];
  dead: DeadAlias[];
  saved: number;
};

const MAX_PHRASE_TOKENS = 3;
const MIN_USES = 5;
const MIN_GAIN_PER_USE = 2;
const MIN_SAVED = 60;
const RECENT_DAYS = 180;
const DAY = 86_400_000;

const WORD = /^[A-Za-z_][A-Za-z0-9_.:+@-]*$/;
const FLAG = /^--?[A-Za-z0-9][A-Za-z0-9_.-]*(=[A-Za-z0-9_.,:+@-]+)?$/;

// An aliasable token is one you type the same way every time: a command word or
// a flag. Paths, quoted strings, hashes and ids are per-invocation noise.
const isAliasable = (token: string): boolean =>
  token.length <= 40 && (WORD.test(token) || FLAG.test(token));

const letters = (token: string): string =>
  token.replace(/[^A-Za-z0-9]/g, "").toLowerCase();

// gs, gst, gsta … for `git status`: initials, then more of the last word.
export const aliasLadder = (tokens: string[]): string[] => {
  const parts = tokens.map(letters).filter((part) => part !== "");
  const tail = parts.at(-1) ?? "";
  if (parts.length === 0) return [];
  if (parts.length === 1)
    return [1, 2, 3, 4]
      .filter((size) => size < tail.length)
      .map((size) => tail.slice(0, size));
  const head = parts
    .slice(0, -1)
    .map((part) => part[0])
    .join("");
  return [1, 2, 3, 4]
    .filter((size) => size <= tail.length)
    .map((size) => head + tail.slice(0, size));
};

export const pickName = (
  tokens: string[],
  shell: Shell,
): { name: string; collisions: Collision[] } | null => {
  const collisions: Collision[] = [];
  for (const rung of aliasLadder(tokens)) {
    const owner = shell.taken.get(rung);
    if (!owner) return { name: rung, collisions };
    collisions.push({
      name: rung,
      owner,
      body: shell.aliases.get(rung) ?? null,
    });
  }
  return null;
};

export const occurrencesFrom = (entries: Entry[]): Occurrence[] =>
  entries.flatMap((entry) =>
    commandsIn(entry.command).map((tokens) => ({ tokens, at: entry.at })),
  );

type Candidate = {
  phrase: string;
  tokens: string[];
  indices: number[];
  lastUsed: number | null;
};

const candidates = (occurrences: Occurrence[], shell: Shell): Candidate[] => {
  const found = new Map<string, Candidate>();
  const bodies = new Set(shell.aliases.values());
  occurrences.forEach((occurrence, index) => {
    const [command] = occurrence.tokens;
    if (!command || !WORD.test(command) || shell.aliases.has(command)) return;
    const depth = Math.min(MAX_PHRASE_TOKENS, occurrence.tokens.length);
    for (let size = 1; size <= depth; size += 1) {
      const tokens = occurrence.tokens.slice(0, size);
      const last = tokens.at(-1) ?? "";
      if (!isAliasable(last)) return;
      const phrase = tokens.join(" ");
      if (bodies.has(phrase)) continue;
      const existing = found.get(phrase);
      if (!existing) {
        found.set(phrase, {
          phrase,
          tokens,
          indices: [index],
          lastUsed: occurrence.at,
        });
        continue;
      }
      existing.indices.push(index);
      existing.lastUsed =
        Math.max(existing.lastUsed ?? 0, occurrence.at ?? 0) || null;
    }
  });
  return [...found.values()];
};

const isRecent = (candidate: Candidate, now: number): boolean =>
  candidate.lastUsed === null || now - candidate.lastUsed <= RECENT_DAYS * DAY;

export const deadAliases = (
  occurrences: Occurrence[],
  shell: Shell,
): DeadAlias[] => {
  const typed = new Set(occurrences.map((occurrence) => occurrence.tokens[0]));
  const dead: DeadAlias[] = [];
  for (const [name, body] of shell.aliases) {
    if (typed.has(name)) continue;
    const bodyTokens = commandsIn(body)[0] ?? [];
    if (bodyTokens.length === 0 || !typed.has(bodyTokens[0])) continue;
    const phrase = bodyTokens.join(" ");
    const longhandUses = occurrences.filter(
      (occurrence) =>
        occurrence.tokens.slice(0, bodyTokens.length).join(" ") === phrase,
    ).length;
    if (longhandUses >= MIN_USES) dead.push({ name, body, longhandUses });
  }
  return dead.sort((a, b) => b.longhandUses - a.longhandUses);
};

// Greedy, with one gain per occurrence: adding `gst` on top of `g` only earns
// the difference, so the plan never double-counts the same keystrokes.
export const buildPlan = (
  occurrences: Occurrence[],
  shell: Shell,
  options: { top: number; now: number },
): Plan => {
  const pool = candidates(occurrences, shell).filter(
    (candidate) =>
      candidate.indices.length >= MIN_USES && isRecent(candidate, options.now),
  );
  const gain = new Array<number>(occurrences.length).fill(0);
  const growing: Shell = {
    taken: new Map(shell.taken),
    aliases: new Map(shell.aliases),
  };
  const refinances: Refinance[] = [];

  while (refinances.length < options.top) {
    const scored = pool.flatMap((candidate) => {
      const picked = pickName(candidate.tokens, growing);
      if (!picked) return [];
      const perUse = candidate.phrase.length - picked.name.length;
      if (perUse < MIN_GAIN_PER_USE) return [];
      const saved = candidate.indices.reduce(
        (total, index) => total + Math.max(0, perUse - (gain[index] ?? 0)),
        0,
      );
      return [{ candidate, picked, perUse, saved }];
    });
    const best = scored.sort((a, b) => b.saved - a.saved)[0];
    if (!best || best.saved < MIN_SAVED) break;
    for (const index of best.candidate.indices)
      gain[index] = Math.max(gain[index] ?? 0, best.perUse);
    growing.taken.set(best.picked.name, "plan");
    growing.aliases.set(best.picked.name, best.candidate.phrase);
    refinances.push({
      name: best.picked.name,
      phrase: best.candidate.phrase,
      uses: best.candidate.indices.length,
      saved: best.saved,
      collisions: best.picked.collisions,
    });
  }

  return {
    refinances,
    dead: deadAliases(occurrences, shell),
    saved: gain.reduce((total, value) => total + value, 0),
  };
};

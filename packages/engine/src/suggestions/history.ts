import type { Suggestion } from "../shared/internal";
import { frecencyBoost } from "./sorting";

// { command: { precedingFlag: { value: { count, lastUsed } } } }, where "" is the
// positional pool. The app builds it from ~/.zsh_history and sets it as
// globalThis.__tineHistoryValues. Values the user typed, for args the spec has
// nothing to say about — so `docker run -p ` can offer `8080:8080`.
type ValueIndex = Record<string, Record<string, Record<string, unknown>>>;

// Same rules as the app's value pool (Frecency.swift): the index is foreign data
// to the engine, so it never displays a credential-shaped value on trust.
const SECRET_PREFIXES = [
  "akia",
  "asia",
  "ghp_",
  "gho_",
  "ghu_",
  "ghs_",
  "ghr_",
  "github_pat_",
  "glpat-",
  "npm_",
  "sk-",
  "sk_",
  "pk_",
  "rk_",
  "xox",
  "eyj",
  "aiza",
  "bearer",
  "-----begin",
];

const SECRET_NAMES = [
  "passwd",
  "password",
  "passphrase",
  "secret",
  "token",
  "credential",
  "key",
  "auth",
  "session",
  "cookie",
  "private",
  "signature",
  "salt",
];

const isSecretName = (name: string): boolean => {
  const lower = name.toLowerCase();
  return SECRET_NAMES.some((word) => lower.includes(word));
};

const isHighEntropy = (segment: string): boolean => {
  if (segment.length < 20) return false;
  if (/^[0-9a-fA-F]+$/.test(segment)) return true;
  if (!/^[A-Za-z0-9+_-]+$/.test(segment)) return false;
  if (segment.length >= 32) return true;
  return (
    /[0-9]/.test(segment) && /[a-z]/.test(segment) && /[A-Z]/.test(segment)
  );
};

export const looksSecret = (value: string): boolean => {
  const lower = value.toLowerCase();
  if (SECRET_PREFIXES.some((prefix) => lower.startsWith(prefix))) return true;
  const equals = value.indexOf("=");
  if (equals > 0 && isSecretName(value.slice(0, equals))) return true;
  return value.split(/[/:@=,?&]/).some(isHighEntropy);
};

const valueIndex = (): ValueIndex => {
  const index = (globalThis as { __tineHistoryValues?: unknown })
    .__tineHistoryValues;
  return index && typeof index === "object" ? (index as ValueIndex) : {};
};

// One dictionary hit: the pool for this exact (command, flag), never a scan.
export const getHistoryValueSuggestions = (
  cmd: string,
  flag: string,
): Suggestion[] => {
  if (isSecretName(flag)) return [];
  const pool = valueIndex()[cmd]?.[flag];
  if (!pool) return [];
  const now = Date.now();
  return Object.entries(pool)
    .filter(([value]) => !looksSecret(value))
    .map(([name, use]) => ({
      name,
      type: "history" as const,
      description: "from history",
      shouldAddSpace: true,
      priority: 50 + frecencyBoost(use, now),
    }));
};

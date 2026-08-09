import type { Suggestion } from "../shared/internal";
import { frecencyBoost } from "./sorting";

// { command: { precedingFlag: { value: { count, lastUsed } } } }, where "" is the
// positional pool. The app builds it from ~/.zsh_history and sets it as
// globalThis.__tineHistoryValues. Values the user typed, for args the spec has
// nothing to say about — so `docker run -p ` can offer `8080:8080`.
type ValueIndex = Record<string, Record<string, Record<string, unknown>>>;

// A value is admitted only if it matches one of the grammars below AND survives
// the blocklists. Recognising secrets is a losing game; recognising the handful
// of shapes worth suggesting is not. Frecency.swift runs the identical rules on
// the producing side, and this side repeats them because the bridged index is
// foreign data.

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
  "pass",
  "passwd",
  "password",
  "passphrase",
  "pwd",
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

// Dots stay inside the run: `aB3dEfGh.iJkLmNoPqRs7` is a secret wearing a
// hostname's clothes. Long all-lowercase dotted names are real hostnames, so the
// blanket length rule skips anything dotted.
const isHighEntropy = (segment: string): boolean => {
  if (segment.length < 20) return false;
  if (/^[0-9a-fA-F]+$/.test(segment)) return true;
  if (!/^[A-Za-z0-9+._-]+$/.test(segment)) return false;
  if (segment.length >= 32 && !segment.includes(".")) return true;
  return (
    /[0-9]/.test(segment) && /[a-z]/.test(segment) && /[A-Z]/.test(segment)
  );
};

const looksSecret = (value: string): boolean => {
  const lower = value.toLowerCase();
  if (SECRET_PREFIXES.some((prefix) => lower.startsWith(prefix))) return true;
  const equals = value.indexOf("=");
  if (equals > 0 && isSecretName(value.slice(0, equals))) return true;
  return value.split(/[/:@=,?&]/).some(isHighEntropy);
};

const PORT = /^[0-9]{1,5}$/;
const PORT_MAPPING = /^[0-9]{1,5}(:[0-9]{1,5}){1,2}$/;
const LABEL = "[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?";
const DOTTED_HOST = new RegExp(`^${LABEL}(?:\\.${LABEL})+$`);
const IPV4 = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/;
const WORD = /^[A-Za-z0-9._-]+$/;
const NAME_TAG = /^[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$/;
const URL = /^[A-Za-z][A-Za-z0-9+.-]*:\/\/([^/]*)/;
const UNSAFE = /[\s"'`$*?<>|;&(){}[\]!\\]/;

// A bare single label is not a host — that shape is a dictionary password.
const isHost = (value: string): boolean =>
  value === "localhost" || IPV4.test(value) || DOTTED_HOST.test(value);

const isHostPort = (value: string): boolean => {
  const colon = value.lastIndexOf(":");
  if (colon <= 0) return false;
  return isHost(value.slice(0, colon)) && PORT.test(value.slice(colon + 1));
};

const isUserAtHost = (value: string): boolean => {
  const parts = value.split("@");
  if (parts.length !== 2) return false;
  const [user, host] = parts;
  return WORD.test(user) && (isHost(host) || isHostPort(host));
};

// Userinfo carries the password in `postgres://user:pass@host/db`, so a URL is
// admitted only when its authority has none.
const isUrl = (value: string): boolean => {
  const authority = URL.exec(value)?.[1] ?? "";
  return authority.length > 0 && !authority.includes("@");
};

// Anchored paths only: a bare relative path is indistinguishable from a word.
const isPath = (value: string): boolean => {
  if (!/^(\/|\.\/|\.\.\/|~\/)/.test(value)) return false;
  return value
    .split("/")
    .filter((segment) => segment !== "" && segment !== "~")
    .every((segment) => WORD.test(segment));
};

const matchesGrammar = (value: string, flag: string): boolean => {
  if (PORT.test(value) || PORT_MAPPING.test(value)) return true;
  if (isHost(value) || isHostPort(value) || isUserAtHost(value)) return true;
  if (isUrl(value) || isPath(value)) return true;
  // `nginx:latest` is an image tag positionally and `alice:hunter2` after a
  // flag, so name:tag is admitted in the positional pool only.
  if (flag === "" && NAME_TAG.test(value)) return true;
  return isAssignment(value, flag);
};

const isAssignment = (value: string, flag: string): boolean => {
  const equals = value.indexOf("=");
  if (equals <= 0) return false;
  const name = value.slice(0, equals);
  const rest = value.slice(equals + 1);
  if (!WORD.test(name) || isSecretName(name)) return false;
  if (matchesGrammar(rest, flag)) return true;
  return WORD.test(rest) && !isHighEntropy(rest);
};

// Admitted = one grammar matched, and no blocklist hit. Both must hold.
export const admitsValue = (value: string, flag: string): boolean => {
  if (value.length < 2 || value.length > 80) return false;
  if (UNSAFE.test(value)) return false;
  if (isSecretName(flag)) return false;
  if (looksSecret(value)) return false;
  return matchesGrammar(value, flag);
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
  const pool = valueIndex()[cmd]?.[flag];
  if (!pool) return [];
  const now = Date.now();
  return Object.entries(pool)
    .filter(([value]) => admitsValue(value, flag))
    .map(([name, use]) => ({
      name,
      type: "history" as const,
      description: "from history",
      shouldAddSpace: true,
      priority: 50 + frecencyBoost(use, now),
    }));
};

import { afterEach, describe, expect, it } from "bun:test";
import type { Suggestion } from "../../shared/internal";
import { frecencyBoost, updatePriorities } from "../sorting";

const now = 1_760_000_000_000;
const day = 24 * 60 * 60 * 1000;

describe("frecencyBoost", () => {
  it("ranks a heavily used param above a once-used recent one", () => {
    const heavy = frecencyBoost({ count: 500, lastUsed: now - 7 * day }, now);
    const fresh = frecencyBoost({ count: 1, lastUsed: now }, now);
    expect(heavy).toBeGreaterThan(fresh);
  });

  it("ranks the more recent param first at equal counts", () => {
    const recent = frecencyBoost({ count: 10, lastUsed: now - day }, now);
    const stale = frecencyBoost({ count: 10, lastUsed: now - 90 * day }, now);
    expect(recent).toBeGreaterThan(stale);
  });

  it("stays inside (0, 1) so it never crosses a priority band", () => {
    expect(frecencyBoost({ count: 10000, lastUsed: now }, now)).toBeLessThan(1);
    expect(
      frecencyBoost({ count: 1, lastUsed: now - 365 * day }, now),
    ).toBeGreaterThan(0);
  });

  it("does not let a future timestamp produce NaN", () => {
    expect(frecencyBoost({ count: 3, lastUsed: now + 4000 * day }, now)).toBe(
      0.75,
    );
  });

  it("scores an unknown or malformed entry as zero", () => {
    expect(frecencyBoost(undefined, now)).toBe(0);
    expect(frecencyBoost(now, now)).toBe(0);
    expect(frecencyBoost({ count: 3 }, now)).toBe(0);
  });

  it("scores a foreign entry as zero instead of NaN or -Infinity", () => {
    expect(frecencyBoost({ count: Number.NaN, lastUsed: now }, now)).toBe(0);
    expect(frecencyBoost({ count: -1, lastUsed: now }, now)).toBe(0);
    expect(
      frecencyBoost({ count: Number.POSITIVE_INFINITY, lastUsed: now }, now),
    ).toBe(0);
    expect(
      frecencyBoost({ count: 3, lastUsed: Number.NEGATIVE_INFINITY }, now),
    ).toBe(0);
  });
});

describe("updatePriorities", () => {
  const sub = (name: string): Suggestion => ({ name, type: "subcommand" });
  const host = globalThis as { __tineFrecency?: unknown };

  afterEach(() => {
    host.__tineFrecency = undefined;
  });

  it("orders the used band by frequency, not by timestamp alone", () => {
    host.__tineFrecency = {
      git: {
        commit: { count: 500, lastUsed: Date.now() - day },
        bisect: { count: 1, lastUsed: Date.now() },
      },
    };
    const [commit, bisect, unused] = updatePriorities(
      [sub("commit"), sub("bisect"), sub("clone")],
      "git",
    );
    expect(commit.priority).toBeGreaterThan(bisect.priority ?? 0);
    expect(bisect.priority).toBeGreaterThan(unused.priority ?? 0);
    expect(commit.priority).toBeLessThan(76);
  });
});

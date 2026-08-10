import { describe, expect, test } from "bun:test";
import { parseHistory } from "../src/history.js";
import {
  aliasLadder,
  buildPlan,
  deadAliases,
  occurrencesFrom,
  pickName,
} from "../src/plan.js";
import type { Shell } from "../src/shell.js";

const NOW = Date.UTC(2026, 0, 1);
const DAY = 86_400_000;

const shell = (
  commands: string[],
  aliases: Record<string, string> = {},
): Shell => ({
  taken: new Map([
    ...commands.map((name) => [name, "command"] as const),
    ...Object.keys(aliases).map((name) => [name, "alias"] as const),
  ]),
  aliases: new Map(Object.entries(aliases)),
});

const typed = (command: string, times: number, daysAgo = 1): string =>
  Array.from(
    { length: times },
    (_, index) =>
      `: ${Math.floor((NOW - daysAgo * DAY + index * 1000) / 1000)}:0;${command}`,
  ).join("\n");

const occurrences = (...history: string[]) =>
  occurrencesFrom(parseHistory(`${history.join("\n")}\n`));

const plan = (history: string[], environment: Shell, top = 5) =>
  buildPlan(occurrences(...history), environment, { top, now: NOW });

describe("aliasLadder", () => {
  test("shortens a single word by its prefixes", () => {
    expect(aliasLadder(["kubectl"])).toEqual(["k", "ku", "kub", "kube"]);
  });

  test("takes initials, then grows the last word", () => {
    expect(aliasLadder(["git", "status"])).toEqual([
      "gs",
      "gst",
      "gsta",
      "gstat",
    ]);
  });

  test("reads flags as their letters", () => {
    expect(aliasLadder(["git", "commit", "-m"])).toEqual(["gcm"]);
  });
});

describe("pickName", () => {
  test("steps over a name the machine already owns", () => {
    const picked = pickName(["git", "status"], shell(["gs"]));
    expect(picked?.name).toBe("gst");
    expect(picked?.collisions).toEqual([
      { name: "gs", owner: "command", body: null },
    ]);
  });

  test("reports which alias owns a name", () => {
    const picked = pickName(["ls", "-la"], shell([], { ll: "ls -l" }));
    expect(picked?.name).toBe("lla");
    expect(picked?.collisions[0]).toEqual({
      name: "ll",
      owner: "alias",
      body: "ls -l",
    });
  });

  test("gives up when every rung is taken", () => {
    expect(pickName(["git"], shell(["g", "gi"]))).toBeNull();
  });
});

describe("buildPlan", () => {
  test("proposes a collision-free alias for a repeated command", () => {
    const result = plan([typed("git status", 20)], shell(["gs", "git"]));
    expect(result.refinances[0]).toMatchObject({
      name: "gst",
      phrase: "git status",
      uses: 20,
    });
  });

  test("counts each keystroke once across overlapping aliases", () => {
    const result = plan(
      [
        typed("git status", 200),
        typed("git push", 200),
        typed("git diff --staged", 200),
      ],
      shell(["git"]),
      6,
    );
    const sum = result.refinances.reduce(
      (total, item) => total + item.saved,
      0,
    );
    expect(result.saved).toBe(sum);
    expect(new Set(result.refinances.map((item) => item.name)).size).toBe(
      result.refinances.length,
    );
  });

  test("never proposes a phrase that is already an alias", () => {
    const result = plan(
      [typed("git status", 40)],
      shell([], { gs: "git status" }),
    );
    expect(result.refinances.map((item) => item.phrase)).not.toContain(
      "git status",
    );
  });

  test("ignores commands you already type through an alias", () => {
    const result = plan(
      [typed("gst --short", 40)],
      shell([], { gst: "git status" }),
    );
    expect(result.refinances).toEqual([]);
  });

  test("forgets a command you abandoned months ago", () => {
    const result = plan([typed("vagrant provision", 60, 400)], shell([]));
    expect(result.refinances).toEqual([]);
  });

  test("stops the phrase at the first token you never retype", () => {
    const result = plan([typed('git commit -m "wip"', 40)], shell(["git"]));
    expect(result.refinances[0]?.phrase).toBe("git commit -m");
  });

  test("keeps quiet when there is nothing to win", () => {
    expect(plan([typed("ls", 500)], shell(["l", "ls"])).refinances).toEqual([]);
  });
});

describe("deadAliases", () => {
  test("finds the alias you defined and never typed", () => {
    const dead = deadAliases(
      occurrences(typed("git checkout main", 30)),
      shell([], { gco: "git checkout", gp: "git push" }),
    );
    expect(dead).toEqual([
      { name: "gco", body: "git checkout", longhandUses: 30 },
    ]);
  });

  test("says nothing about an alias you do use", () => {
    const dead = deadAliases(
      occurrences(typed("gco main", 30), typed("git checkout main", 30)),
      shell([], { gco: "git checkout" }),
    );
    expect(dead).toEqual([]);
  });
});

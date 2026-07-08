import { describe, expect, it } from "vitest";
import { Subcommand } from "@tine/shared/internal";
import { mergeSubcommand } from "../src/mergeSubcommand";

// Minimal converted-shape builders (subcommands/options are name-keyed records).
const sub = (name: string, extra: Partial<Subcommand> = {}): Subcommand =>
  ({
    name: [name],
    subcommands: {},
    options: {},
    persistentOptions: {},
    args: [],
    ...extra,
  }) as Subcommand;

const record = (...subs: Subcommand[]): Record<string, Subcommand> =>
  Object.fromEntries(subs.flatMap((s) => s.name.map((n) => [n, s])));

describe("mergeSubcommand", () => {
  it("adds a new top-level subcommand, keeping the base ones", () => {
    const base = sub("aws", { subcommands: record(sub("s3")), description: "AWS CLI" } as never);
    const overlay = sub("aws", { subcommands: record(sub("sso")) });
    const merged = mergeSubcommand(base, overlay);
    expect(Object.keys(merged.subcommands).sort()).toEqual(["s3", "sso"]);
    expect((merged as unknown as { description: string }).description).toBe("AWS CLI");
  });

  it("adds a nested subcommand under an existing one (aws sso login)", () => {
    const base = sub("aws", {
      subcommands: record(sub("sso", { subcommands: record(sub("logout")) })),
    });
    const overlay = sub("aws", {
      subcommands: record(sub("sso", { subcommands: record(sub("login")) })),
    });
    const merged = mergeSubcommand(base, overlay);
    expect(Object.keys(merged.subcommands.sso.subcommands).sort()).toEqual([
      "login",
      "logout",
    ]);
  });

  it("adds new options and keeps base options on collision", () => {
    const base = sub("git", {
      options: { "--verbose": { name: ["--verbose"], args: [] } as never },
    });
    const overlay = sub("git", {
      options: {
        "--verbose": { name: ["--verbose"], args: [], description: "OVERRIDE" } as never,
        "--mine": { name: ["--mine"], args: [] } as never,
      },
    });
    const merged = mergeSubcommand(base, overlay);
    expect(Object.keys(merged.options).sort()).toEqual(["--mine", "--verbose"]);
    expect((merged.options["--verbose"] as { description?: string }).description).toBeUndefined();
  });

  it("does not mutate the base", () => {
    const baseSso = sub("sso", { subcommands: record(sub("logout")) });
    const base = sub("aws", { subcommands: record(baseSso) });
    const overlay = sub("aws", {
      subcommands: record(sub("sso", { subcommands: record(sub("login")) })),
    });
    mergeSubcommand(base, overlay);
    expect(Object.keys(base.subcommands.sso.subcommands)).toEqual(["logout"]);
    expect(Object.keys(baseSso.subcommands)).toEqual(["logout"]);
  });
});

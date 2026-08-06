import { describe, expect, it } from "bun:test";
import { convertSubcommand, initializeDefault } from "../convertSpec";

// Real specs ship sparse name arrays: next.js declares ["-H", , "--hostname"].
// The hole must stay unnamed, never become an "undefined" entry.
const sparseNames = (): string[] => {
  const names: string[] = [];
  names[0] = "-H";
  names[2] = "--hostname";
  return names;
};

describe("convertSubcommand", () => {
  it("skips the holes in sparse name arrays", () => {
    const converted = convertSubcommand(
      {
        name: "next",
        subcommands: [{ name: sparseNames() }],
        options: [
          { name: sparseNames(), description: "Hostname" },
          { name: sparseNames(), isPersistent: true },
        ],
      },
      initializeDefault,
    );

    expect(Object.keys(converted.subcommands)).toEqual(["-H", "--hostname"]);
    expect(Object.keys(converted.options)).toEqual(["-H", "--hostname"]);
    expect(Object.keys(converted.persistentOptions)).toEqual([
      "-H",
      "--hostname",
    ]);
  });
});

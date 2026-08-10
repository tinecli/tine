import { expect, test } from "bun:test";

const root = new URL("..", import.meta.url);

const subcommandNames = (module: unknown): string[] => {
  if (!module || typeof module !== "object" || !("default" in module)) {
    throw new Error("tine spec has no default export");
  }

  const spec = module.default;
  if (
    !spec ||
    typeof spec !== "object" ||
    !("subcommands" in spec) ||
    !Array.isArray(spec.subcommands)
  ) {
    throw new Error("tine spec has no subcommands");
  }

  return spec.subcommands.map((subcommand: unknown) => {
    if (
      !subcommand ||
      typeof subcommand !== "object" ||
      !("name" in subcommand) ||
      typeof subcommand.name !== "string"
    ) {
      throw new Error("tine spec has an unnamed subcommand");
    }
    return subcommand.name;
  });
};

test("the builtin spec covers every tine subcommand", async () => {
  const shell = await Bun.file(new URL("shell/tine.zsh", root)).text();
  const functionStart = shell.indexOf("tine() {");
  const functionEnd = shell.indexOf("\n}\n\n# Re-source", functionStart);
  const tineFunction = shell.slice(functionStart, functionEnd);
  const dispatchedNames = [...tineFunction.matchAll(/^ {4}([^\n)]+)\)/gm)]
    .flatMap((match) => match[1].split("|"))
    .filter((name) => /^[a-z]+$/.test(name))
    .sort();

  const specModule: unknown = await import(
    new URL("builtin-specs/tine.js", root).href
  );

  expect(subcommandNames(specModule).sort()).toEqual(dispatchedNames);
});

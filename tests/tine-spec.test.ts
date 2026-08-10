import { expect, test } from "bun:test";

const root = new URL("..", import.meta.url);

test("the builtin spec covers every tine subcommand", async () => {
  const shell = await Bun.file(new URL("shell/tine.zsh", root)).text();
  const functionStart = shell.indexOf("tine() {");
  if (functionStart === -1) {
    throw new Error("shell/tine.zsh has no tine function");
  }

  const functionEnd = shell.indexOf("\n}", functionStart);
  if (functionEnd === -1) {
    throw new Error("shell/tine.zsh has no end for the tine function");
  }

  const tineFunction = shell.slice(functionStart, functionEnd);
  const dispatchedNames = [...tineFunction.matchAll(/^ {4}([^\n)]+)\)/gm)]
    .flatMap((match) => match[1].split("|"))
    .filter((name) => /^[a-z]+(?:-[a-z]+)*$/.test(name))
    .sort();
  expect(dispatchedNames.length).toBeGreaterThanOrEqual(10);

  const { default: spec } = (await import(
    new URL("builtin-specs/tine.js", root).href
  )) as { default: { subcommands: { name: string }[] } };
  const specNames = spec.subcommands.map((subcommand) => subcommand.name);

  expect(specNames.sort()).toEqual(dispatchedNames);
});

import { describe, expect, it } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { type AssignmentListNode, NodeType, parse } from "../parser";

function parseCommand(command: string): string {
  return JSON.stringify(parse(command), null, "  ");
}

/**
 *
 * @param filePath The path to the file to parse
 * @param nameComment The first character of each title line
 */
function getData(
  filePath: string,
  nameComment: string,
): [name: string, value: string][] {
  if (!fs.existsSync(filePath)) {
    fs.writeFileSync(filePath, "");
    return [];
  }
  return fs
    .readFileSync(filePath, { encoding: "utf8" })
    .split("\n\n")
    .map((testCase) => {
      const firstNewline = testCase.indexOf("\n");
      const title = testCase.slice(0, firstNewline);
      const block = testCase.slice(firstNewline);
      return [title.slice(nameComment.length).trim(), block.trim()];
    });
}

function outputNewFile(
  filePath: string,
  nameComment: string,
  data: [name: string, value: string][],
) {
  fs.writeFileSync(
    filePath,
    data.reduce(
      (previous, current, index) =>
        `${previous}${index > 0 ? "\n\n" : ""}${nameComment} ${current[0]}\n${
          current[1]
        }`,
      "",
    ),
  );
}

function notIncludedIn<K>(setA: Set<K>, setB: Set<K>): K[] {
  const notIncluded: K[] = [];
  for (const v of setA) {
    if (!setB.has(v)) notIncluded.push(v);
  }
  return notIncluded;
}

function mapKeysDiff<K, V>(mapA: Map<K, V>, mapB: Map<K, V>) {
  const keysA = new Set(mapA.keys());
  const keysB = new Set(mapB.keys());
  return [
    notIncludedIn(keysA, keysB), // keys of A not included in B
    notIncludedIn(keysB, keysA), // keys of B not included in A
  ];
}

describe("an empty command stopped by its enclosing terminator stays incomplete", () => {
  it("does not close an unclosed command substitution just because it's empty", () => {
    const [command] = parse("$()").children;
    const [substitution] = command.children;
    expect(substitution.type).toBe(NodeType.CommandSubstitution);
    expect(substitution.complete).toBe(false);
  });

  it("does not close an unclosed subshell just because it's empty", () => {
    const [subshell] = parse("()").children;
    expect(subshell.type).toBe(NodeType.Subshell);
    expect(subshell.complete).toBe(false);
  });

  it("does not read a command after an unterminated empty substitution as its own command", () => {
    const [assignmentList] = parse("ENV=$() cmd").children;
    expect((assignmentList as AssignmentListNode).hasCommand).toBe(false);
    expect(assignmentList.children).toHaveLength(1);
    expect(assignmentList.children[0].complete).toBe(false);
  });
});

describe("parser fixtures", () => {
  const fixturesPath = path.join(import.meta.dirname, "fixtures");
  const fixtures = fs.readdirSync(fixturesPath);
  describe.each(fixtures)("%s", (fixture) => {
    const inputFile = path.join(fixturesPath, fixture, "input.sh");
    const outputFile = path.join(fixturesPath, fixture, "output.txt");
    const inputData = new Map(getData(inputFile, "###"));
    const outputData = new Map(getData(outputFile, "//"));

    // clean diffs and regenerate files if required.
    if (!process.env.NO_FIXTURES_EDIT) {
      const [newInputs, extraOutputs] = mapKeysDiff(inputData, outputData);
      extraOutputs.forEach((v) => outputData.delete(v));
      newInputs.forEach((v) =>
        outputData.set(v, parseCommand(inputData.get(v) ?? "")),
      );
      if (extraOutputs.length || newInputs.length) {
        outputNewFile(outputFile, "//", [...outputData.entries()]);
      }
    }

    it.each([...inputData.keys()])("%s", (caseName) => {
      const input = inputData.get(caseName) ?? "";
      const output = outputData.get(caseName) ?? "";
      expect(parseCommand(input)).toEqual(output);
    });
  });
});

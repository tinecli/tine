import { describe, expect, test } from "bun:test";
import { commandsIn, decodeHistory, parseHistory } from "../src/history.js";

describe("parseHistory", () => {
  test("reads the extended format", () => {
    const entries = parseHistory(
      ": 1700000000:3;git status\n: 1700000060:0;ls -la\n",
    );
    expect(entries).toEqual([
      { command: "git status", at: 1_700_000_000_000 },
      { command: "ls -la", at: 1_700_000_060_000 },
    ]);
  });

  test("reads plain lines as undated entries", () => {
    expect(parseHistory("git status\n\nls -la\n")).toEqual([
      { command: "git status", at: null },
      { command: "ls -la", at: null },
    ]);
  });

  test("folds an unprefixed line into the entry above it", () => {
    const entries = parseHistory(
      ": 1700000000:0;for x in a b; do \\\n  echo $x \\\n done\n",
    );
    expect(entries).toHaveLength(1);
    expect(entries[0]?.command).toBe("for x in a b; do \n  echo $x \n done");
  });

  test("folds a backslash continuation in a plain file", () => {
    expect(parseHistory("echo one \\\ntwo\n")).toEqual([
      { command: "echo one \ntwo", at: null },
    ]);
  });

  test("keeps a semicolon-bearing command whole", () => {
    const entries = parseHistory(': 1700000000:0;git commit -m "a; b"\n');
    expect(entries[0]?.command).toBe('git commit -m "a; b"');
  });
});

describe("decodeHistory", () => {
  test("unmetafies zsh's high-bit encoding", () => {
    const bytes = new Uint8Array([0x63, 0x64, 0x20, 0x83, 0xe3, 0x83, 0x89]);
    expect(decodeHistory(bytes)).toBe("cd é");
  });

  test("leaves plain ascii alone", () => {
    expect(decodeHistory(new Uint8Array([0x6c, 0x73]))).toBe("ls");
  });
});

describe("commandsIn", () => {
  test("splits on unquoted operators", () => {
    expect(commandsIn('git add . && git commit -m "wip; now"')).toEqual([
      ["git", "add", "."],
      ["git", "commit", "-m", "wip; now"],
    ]);
  });

  test("splits a pipeline into both command words", () => {
    expect(commandsIn("git log --oneline | head -20")).toEqual([
      ["git", "log", "--oneline"],
      ["head", "-20"],
    ]);
  });

  test("drops redirect targets and file descriptors", () => {
    expect(commandsIn("swift build 2> /tmp/err.log")).toEqual([
      ["swift", "build"],
    ]);
  });

  test("keeps an escaped separator inside a token", () => {
    expect(commandsIn("grep foo\\;bar file")).toEqual([
      ["grep", "foo;bar", "file"],
    ]);
  });

  test("treats a command substitution as its own command", () => {
    expect(commandsIn("echo $(date -u)")).toEqual([
      ["echo", "$"],
      ["date", "-u"],
    ]);
  });
});

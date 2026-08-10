import { describe, expect, test } from "bun:test";

const CLI = `${import.meta.dir}/../debt.ts`;

const run = (...args: string[]) => {
  const started = Bun.spawnSync([process.execPath, CLI, ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, NO_COLOR: "1" },
  });
  return { out: started.stdout.toString(), code: started.exitCode };
};

describe("the sample statement", () => {
  const { out, code } = run("--sample");

  test("runs clean", () => {
    expect(code).toBe(0);
  });

  test("bills the whole sample history", () => {
    expect(out).toContain("2,816 commands");
    expect(out).toContain("keystrokes");
  });

  test("hands over aliases ready to paste", () => {
    expect(out).toContain("alias gst='git status'");
    expect(out).toContain("alias kgp='kubectl get pods'");
  });

  test("shows the name it had to step over", () => {
    expect(out).toContain("gs is already a command on this machine");
  });

  test("names an alias defined but never typed", () => {
    expect(out).toContain("gco='git checkout'");
  });

  test("obeys NO_COLOR", () => {
    expect(out).not.toContain("[");
  });

  test("promises nothing was written", () => {
    expect(out).toContain("Nothing was written anywhere");
  });
});

describe("the flags", () => {
  test("--top bounds the plan", () => {
    const lines = run("--sample", "--top", "3")
      .out.split("\n")
      .filter((line) => /^ {4}alias \S+=/.test(line));
    expect(lines).toHaveLength(3);
  });

  test("--history explains itself when the file is missing", () => {
    const { out } = run("--history", "/nonexistent/zsh_history");
    expect(out).toContain("No history file at /nonexistent/zsh_history");
  });

  test("--help lists the flags", () => {
    expect(run("--help").out).toContain("--sample");
  });
});

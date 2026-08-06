import { beforeAll, expect, test } from "bun:test";
import vm from "node:vm";

// A bare vm context has no window/TextEncoder/timers, so the bundle only runs
// here if app/engine/shims.js works — same contract as the app's JSC context.

type Result = { searchTerm: string; items: Array<{ name: string }> };
type Suggest = (
  line: string,
  cursor: number,
  cwd: string,
  cb: (r: Result) => void,
) => void;

const root = new URL("..", import.meta.url).pathname;
const specsDir = "/tine-smoke-specs";
const files: Record<string, string> = {
  [`${specsDir}/index.json`]: JSON.stringify({
    completions: ["git"],
    diffVersionedCompletions: [],
  }),
  [`${specsDir}/git.js`]: `var completionSpec = {
    name: "git",
    subcommands: [{ name: "checkout" }, { name: "cherry-pick" }],
    options: [{ name: "--version" }],
  };
  export default completionSpec;`,
};

let context: vm.Context;
let tineSuggest: Suggest;

const suggest = (line: string): Promise<Result> =>
  new Promise((resolve) => tineSuggest(line, line.length, "/tmp", resolve));

const names = async (line: string) =>
  (await suggest(line)).items.map((item) => item.name);

beforeAll(async () => {
  const build = Bun.spawnSync(["bash", "scripts/build-engine.sh"], {
    cwd: root,
  });
  expect(build.stderr.toString()).toBe("");
  expect(build.exitCode).toBe(0);

  context = vm.createContext({
    __tineReadFile: (path: string) => files[path] ?? "",
    __tineSpecsDir: specsDir,
    __tineRun: () => JSON.stringify({ stdout: "", stderr: "", exitCode: 0 }),
  });
  vm.runInContext(
    await Bun.file(`${root}app/engine/tine-engine.js`).text(),
    context,
  );
  tineSuggest = vm.runInContext("globalThis.tineSuggest", context);
});

test("the bundle exposes tineSuggest", () => {
  expect(tineSuggest).toBeFunction();
});

test("suggests subcommands", async () => {
  expect(await names("git ch")).toEqual(["checkout", "cherry-pick"]);
});

test("suggests options", async () => {
  expect(await names("git --vers")).toEqual(["--version"]);
  expect(vm.runInContext("globalThis.__tineErr", context)).toBeUndefined();
});

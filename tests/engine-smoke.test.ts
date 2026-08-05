import { beforeAll, expect, test } from "bun:test";
import vm from "node:vm";

// A bare vm context has no window/TextEncoder/timers, so the bundle only runs
// here if app/engine/shims.js works — same contract as the app's JSC context.

type Item = { name: string; insertValue: string; queryTerm: string };
type Result = { searchTerm: string; items: Item[] };
type Suggest = (
  line: string,
  cursor: number,
  cwd: string,
  cb: (r: Result) => void,
) => void;

const root = new URL("..", import.meta.url).pathname;
const specsDir = "/tine-smoke-specs";
const home = "/home/smoke";
const files: Record<string, string> = {
  [`${specsDir}/index.json`]: JSON.stringify({
    completions: ["git", "cd", "cat"],
    diffVersionedCompletions: [],
  }),
  [`${specsDir}/git.js`]: `var completionSpec = {
    name: "git",
    subcommands: [{ name: "checkout" }, { name: "cherry-pick" }],
    options: [{ name: "--version" }],
  };
  export default completionSpec;`,
  [`${specsDir}/cd.js`]: `var completionSpec = {
    name: "cd",
    args: { name: "folder", template: "folders" },
  };
  export default completionSpec;`,
  [`${specsDir}/cat.js`]: `var completionSpec = {
    name: "cat",
    args: { name: "file", template: "filepaths" },
  };
  export default completionSpec;`,
};

// `ls -1ApL` output per directory, for the filepaths/folders generators.
const listings: Record<string, string> = {
  "/tmp/": "app/\nmy dir/\nREADME.md\n.DS_Store\n.hidden/\n",
  "/tmp/app/": "Sources/\nPackage.swift\n",
  [`${home}/`]: "Documents/\n.config/\n",
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
    __tineHome: home,
    __tineRun: (json: string) => {
      const input = JSON.parse(json) as {
        executable: string;
        workingDirectory?: string;
      };
      const stdout =
        input.executable === "ls"
          ? (listings[input.workingDirectory ?? ""] ?? "")
          : "";
      return JSON.stringify({ stdout, stderr: "", exitCode: 0 });
    },
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

test("the folders template lists only directories", async () => {
  expect(await names("cd ")).toEqual(["app/", "my dir/", ".hidden/", "../"]);
});

test("the filepaths template lists files and directories", async () => {
  expect(await names("cat ")).toEqual([
    "app/",
    "my dir/",
    "README.md",
    ".hidden/",
    "../",
  ]);
});

test("a nested path lists that directory and replaces only the basename", async () => {
  const { items } = await suggest("cd app/S");
  expect(items.map((item) => item.name)).toEqual(["Sources/"]);
  expect(items[0].insertValue).toBe("Sources/");
  expect(items[0].queryTerm).toBe("S");
});

test("a tilde path expands to HOME", async () => {
  // A search term ending in "/" also offers the auto-execute "enter this
  // directory" entry ahead of the listing.
  expect(await names("cd ~/")).toEqual(["↪", "Documents/", ".config/", "../"]);
});

test("a folder with a space is escaped on insert", async () => {
  const { items } = await suggest("cd my");
  expect(items.map((item) => item.name)).toEqual(["my dir/"]);
  expect(items[0].insertValue).toBe("my\\ dir/");
});

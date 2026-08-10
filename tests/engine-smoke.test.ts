import { beforeAll, expect, test } from "bun:test";
import vm from "node:vm";

// A bare vm context has no window/TextEncoder/timers, so the bundle only runs
// here if app/engine/shims.js works — same contract as the app's JSC context.

type Item = {
  name: string;
  description: string;
  insertValue: string;
  queryTerm: string;
  type: string;
};
type Result = { searchTerm: string; items: Item[] };
type Suggest = (
  line: string,
  cursor: number,
  cwd: string,
  cb: (r: Result) => void,
) => void;
type Validation = { status: string; token: string; dangerous: boolean };
type Validate = (line: string, cb: (r: Validation) => void) => void;

const root = new URL("..", import.meta.url).pathname;
const specsDir = "/tine-smoke-specs";
const home = "/home/smoke";
const files: Record<string, string> = {
  [`${specsDir}/index.json`]: JSON.stringify({
    completions: ["git", "cd", "cat", "deploy", "wipe"],
    diffVersionedCompletions: [],
  }),
  [`${specsDir}/deploy.js`]: `var completionSpec = {
    name: "deploy",
    options: [
      { name: "-p", args: { name: "port" } },
      { name: "-e", args: { name: "env" } },
      { name: "--config", args: { name: "file", template: "filepaths" } },
      { name: "--mode", args: { name: "mode", suggestions: ["fast"] } },
      { name: "--net", requiresEquals: true, args: { name: "net" } },
      { name: "-u", args: { name: "user" } },
    ],
    args: { name: "target" },
  };
  export default completionSpec;`,
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
  [`${specsDir}/wipe.js`]: `var completionSpec = {
    name: "wipe",
    options: [{ name: ["-r", "--recursive"] }],
    args: { name: "target", isDangerous: true, template: "filepaths" },
  };
  export default completionSpec;`,
};

// `ls -1ApL` output per directory, for the filepaths/folders generators.
const listings: Record<string, string> = {
  "/tmp/": "app/\nmy dir/\nREADME.md\n.DS_Store\n.hidden/\n",
  "/tmp/app/": "Sources/\nPackage.swift\n",
  [`${home}/`]: "Documents/\n.config/\n",
};

const use = (count: number) => ({ count, lastUsed: Date.now() });

let context: vm.Context;
let tineSuggest: Suggest;
let tineValidate: Validate;
let bundle: string;

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
    __tineFrecency: {
      pc: {},
      deploy: {},
    },
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
    __tineHistoryValues: {
      deploy: {
        "-p": { "8080:8080": use(20), "3000:3000": use(2) },
        "-e": { "NODE_ENV=production": use(4) },
        "--config": { "override.yml": use(9) },
        "--mode": { turbo: use(9) },
        "--net": { "host.local": use(9) },
        "-u": { "alice:hunter2": use(9) },
        "": {
          "web.example.com": use(3),
          ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789: use(99),
        },
      },
      // No spec anywhere for this one: history is the only source it has.
      mytool: {
        "-p": { "8080:8080": use(5) },
        "--host": { "db.example.com": use(5) },
        "": {
          "web.example.com": use(3),
          "cache.example.com": use(30),
          ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789: use(99),
        },
      },
    },
  });
  bundle = await Bun.file(`${root}app/engine/tine-engine.js`).text();
  vm.runInContext(bundle, context);
  tineSuggest = vm.runInContext("globalThis.tineSuggest", context);
  tineValidate = vm.runInContext("globalThis.tineValidate", context);
});

// A fresh context per index fixture: the engine caches the parsed index.json.
const firstTokenItems = (
  index: string,
  aliases: Record<string, string> = {},
): Promise<{ items: Item[]; error: unknown }> => {
  const ctx = vm.createContext({
    __tineReadFile: (path: string) =>
      path === `${specsDir}/index.json` ? index : "",
    __tineSpecsDir: specsDir,
    __tineAliases: aliases,
  });
  vm.runInContext(bundle, ctx);
  const run: Suggest = vm.runInContext("globalThis.tineSuggest", ctx);
  return new Promise((resolve) =>
    run("j", 1, "/tmp", (r) =>
      resolve({
        items: r.items,
        error: vm.runInContext("globalThis.__tineErr", ctx),
      }),
    ),
  );
};

const withDescriptions = JSON.stringify({
  completions: ["jq", "jj"],
  descriptions: { jq: "Command-line JSON processor" },
});

test("a command name carries its root description from the index", async () => {
  const { items } = await firstTokenItems(withDescriptions);
  expect(items.map((item) => [item.name, item.description])).toEqual([
    ["jq", "Command-line JSON processor"],
    ["jj", ""],
  ]);
});

test("alias text wins over the index description", async () => {
  const { items } = await firstTokenItems(withDescriptions, {
    jq: "jq --sort-keys",
  });
  expect(items[0].description).toBe("alias → jq --sort-keys");
});

test("an index without descriptions leaves them blank", async () => {
  const { items, error } = await firstTokenItems(
    JSON.stringify({ completions: ["jq"] }),
  );
  expect(items.map((item) => item.description)).toEqual([""]);
  expect(error).toBeUndefined();
});

test("a malformed descriptions map leaves them blank", async () => {
  for (const descriptions of [42, null, ["jq"], { jq: 42 }]) {
    const { items, error } = await firstTokenItems(
      JSON.stringify({ completions: ["jq"], descriptions }),
    );
    expect(items.map((item) => item.description)).toEqual([""]);
    expect(error).toBeUndefined();
  }
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

test("an arg the spec says nothing about falls back to history values", async () => {
  const { items } = await suggest("deploy -p ");
  expect(items.map((item) => item.name)).toEqual(["8080:8080", "3000:3000"]);
  expect(items[0].type).toBe("history");
  expect(await names("deploy -e ")).toEqual(["NODE_ENV=production"]);
});

test("a `--flag=` value reads that flag's pool, not the positional one", async () => {
  expect(await names("deploy --net=")).toEqual(["host.local"]);
  expect(await names("deploy --net=ho")).toEqual(["host.local"]);
});

test("history values never include a credential-shaped token", async () => {
  expect(await names("deploy ")).toEqual([
    "web.example.com",
    "--config",
    "--mode",
    "--net",
    "-e",
    "-p",
    "-u",
  ]);
  // user:pass wearing an image tag's shape: admitted positionally, never here.
  expect(await names("deploy -u ")).toEqual([]);
});

test("a command with no spec at all still offers its history values", async () => {
  const { items } = await suggest("mytool ");
  // Frecency order, and the credential-shaped seed never surfaces.
  expect(items.map((item) => item.name)).toEqual([
    "cache.example.com",
    "web.example.com",
  ]);
  expect(items[0].type).toBe("history");
  // The old path threw MissingSpecError on every keystroke here.
  expect(vm.runInContext("globalThis.__tineErr", context)).toBeUndefined();
  expect(await names("mytool w")).toEqual(["web.example.com"]);
});

test("a no-spec command keys its history values by the flag in front", async () => {
  expect(await names("mytool -p ")).toEqual(["8080:8080"]);
  expect(await names("mytool --host=")).toEqual(["db.example.com"]);
  // Typing a flag is not typing a value: no spec means no flags to offer.
  expect(await names("mytool -")).toEqual([]);
});

test("a no-spec command with no history values suggests nothing", async () => {
  expect(await names("unseeded ")).toEqual([]);
  expect(await names("unseeded arg ")).toEqual([]);
  expect(vm.runInContext("globalThis.__tineErr", context)).toBeUndefined();
});

test("a used command with no spec offers to learn it", async () => {
  const { items } = await suggest("pc ");
  expect(items).toHaveLength(1);
  expect(items[0]).toMatchObject({
    name: "no spec for `pc` — learn it",
    insertValue: "tine learn pc",
    type: "learn-it",
  });
});

test("a typo with no frecency key does not offer to learn it", async () => {
  expect(await names("px ")).toEqual([]);
});

test("a command with a spec does not offer to learn it", async () => {
  const { items } = await suggest("deploy ");
  expect(items.every((item) => item.type !== "learn-it")).toBe(true);
});

test("the learn-it row replaces the whole line", async () => {
  const line = "pc --unknown";
  const { items } = await suggest(line);
  expect(items).toHaveLength(1);
  expect(items[0].insertValue).toBe("tine learn pc");
  expect(items[0].queryTerm).toBe(line);
});

test("a generator or a spec suggestion keeps history values out", async () => {
  expect(await names("deploy --config ")).toEqual([
    "app/",
    "my dir/",
    "README.md",
    ".hidden/",
    "../",
  ]);
  expect(await names("deploy --mode ")).toEqual(["fast"]);
});

// `tine ask` runs the model's answer through the parser before showing it.
const validate = (line: string): Promise<Validation> =>
  new Promise((resolve) => tineValidate(line, resolve));

test("a command line that matches the spec validates", async () => {
  expect(await validate("git checkout")).toMatchObject({ status: "ok" });
  expect(await validate("deploy --mode fast target")).toMatchObject({
    status: "ok",
  });
  // The last word is checked like every other one: the parser is lenient with
  // the final token, so validation appends a space of its own.
  expect(await validate("git --version")).toMatchObject({ status: "ok" });
});

test("an invented flag or subcommand is rejected, and named", async () => {
  expect(await validate("git --quantum")).toEqual({
    status: "invalid",
    token: "--quantum",
    dangerous: false,
  });
  expect(await validate("git chekout")).toMatchObject({ status: "invalid" });
});

test("a tool with no spec is reported as unchecked, not as invalid", async () => {
  expect(await validate("mytool --whatever")).toEqual({
    status: "nospec",
    token: "",
    dangerous: false,
  });
});

test("a spec's own isDangerous reaches the answer", async () => {
  expect(await validate("wipe -r photos")).toEqual({
    status: "ok",
    token: "",
    dangerous: true,
  });
  expect(await validate("git checkout")).toMatchObject({ dangerous: false });
});

test("nothing that is not a single command validates", async () => {
  expect(await validate("")).toMatchObject({ status: "unparsed" });
});

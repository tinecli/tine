import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  type Mock,
  vi,
} from "bun:test";
import * as execShell from "../../shared/execShell";
import { logger } from "../../shared/log";
import { SpecLocationSource } from "../../shared/utils";
import { resetCaches } from "../caches";
import * as loadHelpers from "../loadHelpers";
import {
  getSpecPath,
  loadFigSubcommand,
  loadSubcommandCached,
} from "../loadSpec";

// Must supply every member loadSpec imports, or the real module's absence
// surfaces as an undefined call deep inside a spec load.
vi.mock("../loadHelpers", () => ({
  importSpecFromFile: vi
    .fn()
    .mockResolvedValue({ default: { name: "loadFromFile" } }),
  importFromPublicCDN: vi
    .fn()
    .mockResolvedValue({ default: { name: "loadFromCDN" } }),
  publicSpecExists: vi.fn().mockResolvedValue(false),
  isDiffVersionedSpec: vi.fn(),
}));

vi.mock("../../shared/execShell", () => ({
  ...execShell,
  executeCommand: vi.fn(),
}));

// TODO: remove this statement and move fig dir to shared
const FIG_DIR = "~/.fig";

describe("getSpecPath", () => {
  const cwd = "test_cwd";

  it("works", async () => {
    expect(await getSpecPath("git", cwd)).toEqual({
      type: SpecLocationSource.GLOBAL,
      name: "git",
    });
  });

  it("works for specs containing a slash in the name", async () => {
    expect(
      await getSpecPath("@withfig/autocomplete-tools", cwd, false),
    ).toEqual({
      type: SpecLocationSource.GLOBAL,
      name: "@withfig/autocomplete-tools",
    });
  });

  it("works for scripts containing a slash in the name", async () => {
    expect(await getSpecPath("@withfig/autocomplete-tools", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      name: "autocomplete-tools",
      path: `${cwd}/@withfig/`,
    });
  });

  it("works properly with local commands", async () => {
    expect(await getSpecPath("./test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      name: "test",
      path: `${cwd}/`,
    });
    expect(await getSpecPath("~/test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `~/`,
      name: "test",
    });
    expect(await getSpecPath("/test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `/`,
      name: "test",
    });
    expect(await getSpecPath("/dir/test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `/dir/`,
      name: "test",
    });
    expect(await getSpecPath("~/dir/test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `~/dir/`,
      name: "test",
    });
    expect(await getSpecPath("./dir/test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `${cwd}/dir/`,
      name: "test",
    });
  });

  it("works properly with ? commands", async () => {
    expect(await getSpecPath("?", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `${cwd}/`,
      name: "_shortcuts",
    });
  });

  it("works properly with + commands", async () => {
    expect(await getSpecPath("+", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      name: "+",
      path: "~/",
    });
  });
});

describe("loadFigSubcommand", () => {
  beforeEach(() => {
    (
      loadHelpers.isDiffVersionedSpec as Mock<
        typeof loadHelpers.isDiffVersionedSpec
      >
    ).mockResolvedValue(false);
  });

  afterEach(() => {
    (
      loadHelpers.isDiffVersionedSpec as Mock<
        typeof loadHelpers.isDiffVersionedSpec
      >
    ).mockClear();
  });

  it("works with expected input", async () => {
    const result = await loadFigSubcommand({
      name: "path",
      type: SpecLocationSource.LOCAL,
    });
    expect(loadHelpers.isDiffVersionedSpec).toHaveBeenCalledTimes(1);
    expect(result.name).toBe("loadFromFile");
  });

  it("loads a local spec from the command's own .fig folder", async () => {
    await loadFigSubcommand({
      name: "git",
      type: SpecLocationSource.LOCAL,
    });
    expect(loadHelpers.importSpecFromFile).toHaveBeenLastCalledWith(
      "git",
      `${FIG_DIR}/autocomplete/build/`,
      logger,
    );
  });
});

describe("loadSubcommandCached", () => {
  beforeEach(() => {
    resetCaches();
    (
      loadHelpers.importSpecFromFile as Mock<
        typeof loadHelpers.importSpecFromFile
      >
    ).mockClear();
    (
      loadHelpers.isDiffVersionedSpec as Mock<
        typeof loadHelpers.isDiffVersionedSpec
      >
    ).mockResolvedValue(false);
  });

  it("caches by spec name", async () => {
    const location: Fig.SpecLocation = {
      name: "path",
      type: SpecLocationSource.LOCAL,
    };

    const first = await loadSubcommandCached(location);
    const second = await loadSubcommandCached(location);

    expect(first.name).toEqual(["loadFromFile"]);
    expect(second).toBe(first);
    expect(loadHelpers.importSpecFromFile).toHaveBeenCalledTimes(1);
  });

  it("reloads a spec whose name differs", async () => {
    await loadSubcommandCached({
      name: "path",
      type: SpecLocationSource.LOCAL,
    });
    await loadSubcommandCached({
      name: "other",
      type: SpecLocationSource.LOCAL,
    });

    expect(loadHelpers.importSpecFromFile).toHaveBeenCalledTimes(2);
  });
});

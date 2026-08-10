import { afterEach, beforeEach, describe, expect, it, vi } from "bun:test";
import * as execShell from "../../shared/execShell";
import * as loadHelpers from "../loadHelpers";

const { getVersionFromFullFile, importString } = loadHelpers;

const specData = {
  getVersionCommand: vi.fn().mockReturnValue(Promise.resolve("1.0.0")),
  default: () => {},
};

describe("test `getVersionFromFullFile`", () => {
  beforeEach(() => {
    vi.spyOn(loadHelpers, "getCachedCLIVersion").mockReturnValue(null);
  });
  afterEach(() => {
    vi.clearAllMocks();
  });
  it("missing `getVersionCommand` and working `command --version`", async () => {
    vi.spyOn(execShell, "executeCommand").mockReturnValue(
      Promise.resolve({
        status: 0,
        stdout: "2.0.0",
        stderr: "",
      }),
    );
    const newSpecData = { ...specData, getVersionCommand: undefined };
    const version = await getVersionFromFullFile(newSpecData, "fig");
    expect(version).toEqual("2.0.0");
  });

  it("missing `getVersionCommand` and not working `command --version`", async () => {
    vi.spyOn(execShell, "executeCommand").mockReturnValue(
      Promise.resolve({
        status: 1,
        stdout: "",
        stderr: "No command available.",
      }),
    );
    const newSpecData = { ...specData, getVersionCommand: undefined };
    const version = await getVersionFromFullFile(newSpecData, "npm");
    expect(version).toBeUndefined();
  });

  it("missing `getVersionCommand` and throwing `command --version`", async () => {
    vi.spyOn(execShell, "executeCommand").mockReturnValue(Promise.reject());
    const newSpecData = { ...specData, getVersionCommand: undefined };
    const version = await getVersionFromFullFile(newSpecData, "npm");
    expect(version).toBeUndefined();
  });

  it("working `getVersionCommand`", async () => {
    vi.spyOn(execShell, "executeCommand").mockReturnValue(
      Promise.resolve({
        status: 0,
        stdout: "",
        stderr: "No command available.",
      }),
    );
    const version = await getVersionFromFullFile(specData, "node");
    expect(version).toEqual("1.0.0");
  });
});

// `tine learn` writes this shape: two comment lines, then `export default` and
// one JSON value. The model's text is data, so a description carrying the words
// the ESM→CJS rewrite looks for must survive as a string and change nothing.
describe("a spec written by `tine learn`", () => {
  const learned = `// Written by \`tine learn faketool\` from \`faketool --help\`, on device.
// Read it, edit it, or delete it — tine merges it onto the shipped pack.
export default {
  "description" : "x) , import evil, export default (name:\\"pwn\\") , //",
  "name" : "faketool",
  "options" : [
    {
      "description" : "Print more output",
      "name" : [
        "--verbose",
        "-v"
      ]
    }
  ]
};
`;

  it("loads as data", async () => {
    const spec = (await importString(learned)).default as Fig.Subcommand;
    expect(spec.name).toEqual("faketool");
    expect(spec.description).toEqual(
      'x) , import evil, export default (name:"pwn") , //',
    );
    expect(spec.options?.[0].name).toEqual(["--verbose", "-v"]);
  });
});

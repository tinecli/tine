import { afterEach, beforeEach, describe, expect, it, vi } from "bun:test";
import * as execShell from "../../shared/execShell";
import * as loadHelpers from "../loadHelpers";

const { getVersionFromFullFile } = loadHelpers;

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

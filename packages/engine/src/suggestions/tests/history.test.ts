import { afterEach, describe, expect, it } from "bun:test";
import { getHistoryValueSuggestions } from "../history";

const now = Date.now();
const day = 24 * 60 * 60 * 1000;
const host = globalThis as { __tineHistoryValues?: unknown };

const names = (cmd: string, flag: string) =>
  getHistoryValueSuggestions(cmd, flag).map((s) => s.name);

afterEach(() => {
  host.__tineHistoryValues = undefined;
});

describe("getHistoryValueSuggestions", () => {
  it("offers the values typed after this flag, marked as history", () => {
    host.__tineHistoryValues = {
      docker: { "-p": { "8080:8080": { count: 3, lastUsed: now } } },
    };
    expect(getHistoryValueSuggestions("docker", "-p")).toEqual([
      {
        name: "8080:8080",
        type: "history",
        description: "from history",
        shouldAddSpace: true,
        priority: 50 + 3 / 4,
      },
    ]);
  });

  it("keeps one flag's values out of another's pool", () => {
    host.__tineHistoryValues = {
      docker: {
        "-p": { "8080:8080": { count: 3, lastUsed: now } },
        "-e": { "NODE_ENV=production": { count: 3, lastUsed: now } },
        "": { "nginx:latest": { count: 3, lastUsed: now } },
      },
    };
    expect(names("docker", "-p")).toEqual(["8080:8080"]);
    expect(names("docker", "-e")).toEqual(["NODE_ENV=production"]);
    expect(names("docker", "")).toEqual(["nginx:latest"]);
    expect(names("docker", "--rm")).toEqual([]);
    expect(names("podman", "-p")).toEqual([]);
  });

  it("ranks by the frecency blend, not by count or recency alone", () => {
    host.__tineHistoryValues = {
      ssh: {
        "": {
          "old.example.com": { count: 40, lastUsed: now - 400 * day },
          "prod.example.com": { count: 30, lastUsed: now - day },
          "test.example.com": { count: 1, lastUsed: now },
        },
      },
    };
    const ranked = getHistoryValueSuggestions("ssh", "").sort(
      (a, b) => (b.priority ?? 0) - (a.priority ?? 0),
    );
    expect(ranked.map((s) => s.name)).toEqual([
      "prod.example.com",
      "test.example.com",
      "old.example.com",
    ]);
    expect(ranked[0].priority).toBeLessThan(51);
  });

  it("never surfaces a credential-shaped value", () => {
    const secrets = [
      "AKIAIOSFODNN7EXAMPLE",
      "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
      "github_pat_11ABCDEFG0abcdefghijkl",
      "sk-proj-abcdefghijklmnopqrstuvwxyz012345",
      "xoxb-123456789012-abcdefghijkl",
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.abc",
      "-----BEGIN",
      "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY",
      "api_token=abcdef",
      "3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a",
      "https://example.com/x?token=abcdef",
      "Zm9vYmFyYmF6cXV4Y29ycmdlZ3JhdWx0Z2FycA",
    ];
    host.__tineHistoryValues = {
      deploy: {
        "-v": Object.fromEntries([
          ...secrets.map((s) => [s, { count: 9, lastUsed: now }]),
          ["nginx:latest", { count: 1, lastUsed: now }],
        ]),
      },
    };
    expect(names("deploy", "-v")).toEqual(["nginx:latest"]);
  });

  it("offers nothing under a flag that names a credential", () => {
    host.__tineHistoryValues = {
      deploy: { "--api-key": { hunter2: { count: 9, lastUsed: now } } },
    };
    expect(names("deploy", "--api-key")).toEqual([]);
  });

  it("offers nothing when the host set no index", () => {
    expect(names("docker", "-p")).toEqual([]);
  });
});

import { afterEach, describe, expect, it } from "bun:test";
import { getHistoryValueSuggestions } from "../history";

const now = Date.now();
const day = 24 * 60 * 60 * 1000;
// The source reads its own clock, so a fixture last used "now" decays by however
// long the test takes to reach it. Dating one ahead pins the decay at zero.
const never = now + 365 * day;
const host = globalThis as { __tineHistoryValues?: unknown };

const names = (cmd: string, flag: string) =>
  getHistoryValueSuggestions(cmd, flag).map((s) => s.name);

// Put one value in one pool and report what survives the filter.
const survivors = (flag: string, value: string) => {
  host.__tineHistoryValues = {
    deploy: { [flag]: { [value]: { count: 3, lastUsed: never } } },
  };
  return names("deploy", flag);
};

afterEach(() => {
  host.__tineHistoryValues = undefined;
});

describe("getHistoryValueSuggestions", () => {
  it("offers the values typed after this flag, marked as history", () => {
    host.__tineHistoryValues = {
      docker: { "-p": { "8080:8080": { count: 3, lastUsed: never } } },
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
        "-p": { "8080:8080": { count: 3, lastUsed: never } },
        "-e": { "NODE_ENV=production": { count: 3, lastUsed: never } },
        "": { "nginx:latest": { count: 3, lastUsed: never } },
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

  it("offers nothing when the host set no index", () => {
    expect(names("docker", "-p")).toEqual([]);
  });
});

// A value is admitted only by matching one of these shapes. Everything else is
// dropped, whether or not it looks like a secret.
describe("admitted grammars", () => {
  const admitted: Array<[string, string, string]> = [
    ["port", "--port", "8080"],
    ["port mapping", "-p", "8080:8080"],
    ["port mapping with a bind address", "-p", "80:8080:80"],
    ["dotted host", "-h", "api.example.com"],
    ["IPv4 literal", "-h", "192.168.1.10"],
    ["localhost", "-h", "localhost"],
    ["host:port", "-h", "cache.example.com:6379"],
    ["user@host", "", "deploy@web.example.com"],
    ["URL without userinfo", "", "https://api.example.com/v1/things"],
    ["absolute path", "", "/etc/hosts"],
    ["relative path", "", "./notes/todo.md"],
    ["parent path", "", "../sibling/file.txt"],
    ["home path", "", "~/Documents/notes.md"],
    ["name:tag in the positional pool", "", "nginx:latest"],
    ["NAME=word", "-e", "NODE_ENV=production"],
    ["NAME=grammar", "-e", "PORT=8080"],
  ];
  for (const [what, flag, value] of admitted) {
    it(`admits a ${what}`, () => {
      expect(survivors(flag, value)).toEqual([value]);
    });
  }
});

describe("rejected values", () => {
  const rejected: Array<[string, string, string]> = [
    ["user:pass after a flag (alice:hunter2)", "-u", "alice:hunter2"],
    ["a URL carrying userinfo", "", "postgres://user:pass@db.example.com/app"],
    ["a slashed AWS key", "", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"],
    ["a base32 seed", "", "JBSWY3DPEHPK3PXPJBSW"],
    ["a dotted 20+ mixed-case secret", "--tag", "aB3dEfGh.iJkLmNoPqRs7"],
    ["a dictionary password after -p (hunter2)", "-p", "hunter2"],
    ["short hex after a flag", "-b", "a1b2c3d4"],
    ["a bare word", "", "production"],
    ["a bare relative path", "", "build/out"],
    ["name:tag after a flag", "-t", "nginx:latest"],
    ["a GitHub token", "", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"],
    ["a fine-grained GitHub token", "", "github_pat_11ABCDEFG0abcdefghijkl"],
    ["an AWS access key id", "", "AKIAIOSFODNN7EXAMPLE"],
    ["an OpenAI key", "", "sk-proj-abcdefghijklmnopqrstuvwxyz012345"],
    ["a Slack token", "", "xoxb-123456789012-abcdefghijkl"],
    ["a JWT", "", "eyJhbGciOiJIUzI1NiJ9.e30.abcdefghijkl"],
    ["a PEM header", "", "-----BEGIN"],
    ["a 40-char hex digest", "", "3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a"],
    ["a base64 blob", "", "Zm9vYmFyYmF6cXV4Y29ycmdlZ3JhdWx0Z2FycA"],
    ["SECRET=value", "-e", "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENG"],
    ["DB_PASS=value", "-e", "DB_PASS=hunter2"],
    ["a value under a credential-named flag", "--api-key", "hunter2"],
    ["a value under --password", "--password", "web.example.com"],
    ["a value under --pwd", "--pwd", "web.example.com"],
  ];
  for (const [what, flag, value] of rejected) {
    it(`rejects ${what}`, () => {
      expect(survivors(flag, value)).toEqual([]);
    });
  }
});

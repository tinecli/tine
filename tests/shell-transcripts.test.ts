// biome-ignore-all lint/suspicious/noTemplateCurlyInString: The harness contains zsh parameter expansions.
import { expect, test } from "bun:test";

type Request = {
  verb: string;
  payload: string;
  reply: string;
};

type Transcript = {
  name: string;
  invocation: string[];
  requests: Request[];
  exitCode: number;
  stdout: string;
  stderr: string;
};

const unitSeparator = "\x1f";
const recordSeparator = "\x1e";
const clearLine = "\x1b[K";
const releases = "https://github.com/tinecli/tine/releases/latest";

const request = (verb: string, payload: string, reply: string): Request => ({
  verb,
  payload,
  reply,
});

const started = (verb: string, payload = ""): Request =>
  request(verb, payload, "started");

const poll = (verb: string, reply: string): Request => request(verb, "", reply);

const transcripts: Transcript[] = [
  {
    name: "install success",
    invocation: ["_tine_install"],
    requests: [
      started("install"),
      poll("installStatus", "done:Installed 42 specs"),
    ],
    exitCode: 0,
    stdout: `tine: checking for spec updates… \rtine: Installed 42 specs${clearLine}\n`,
    stderr: "",
  },
  {
    name: "install progress then success",
    invocation: ["_tine_install"],
    requests: [
      started("install"),
      poll("installStatus", "running"),
      poll("installStatus", "done:Installed 42 specs"),
    ],
    exitCode: 0,
    stdout: `tine: checking for spec updates… \rtine: downloading specs… | \rtine: Installed 42 specs${clearLine}\n`,
    stderr: "",
  },
  {
    name: "install failure",
    invocation: ["_tine_install"],
    requests: [
      started("install"),
      poll("installStatus", "failed:download failed"),
    ],
    exitCode: 1,
    stdout: `tine: checking for spec updates… \r${clearLine}`,
    stderr: "tine: download failed\n",
  },
  {
    name: "install idle completion",
    invocation: ["_tine_install"],
    requests: [started("install"), poll("installStatus", "idle")],
    exitCode: 0,
    stdout: `tine: checking for spec updates… \r${clearLine}`,
    stderr: "",
  },
  {
    name: "update already current",
    invocation: ["_tine_update"],
    requests: [started("appUpdate"), poll("appUpdateStatus", "uptodate:1.2.3")],
    exitCode: 0,
    stdout: `tine: checking for updates… \rtine: 1.2.3 is the latest version${clearLine}\n`,
    stderr: "",
  },
  {
    name: "update available",
    invocation: ["_tine_update"],
    requests: [
      started("appUpdate"),
      poll("appUpdateStatus", "available:1.2.3"),
    ],
    exitCode: 0,
    stdout: `tine: checking for updates… \r${clearLine}tine: 1.2.3 is available — automatic updates are off\ntine: download it from ${releases}\n`,
    stderr: "",
  },
  {
    name: "update failure",
    invocation: ["_tine_update"],
    requests: [
      started("appUpdate"),
      poll("appUpdateStatus", "failed:signature invalid"),
    ],
    exitCode: 1,
    stdout: `tine: checking for updates… \r${clearLine}`,
    stderr: `tine: signature invalid\ntine: download it from ${releases}\n`,
  },
  {
    name: "update staged and applied",
    invocation: ["_tine_update"],
    requests: [
      started("appUpdate"),
      poll("appUpdateStatus", "staged:1.2.3"),
      request("appUpdateApply", "", "ok"),
      request("version", "", "1.2.3"),
    ],
    exitCode: 0,
    stdout: `tine: checking for updates… \rtine: installing 1.2.3… ${clearLine}\rtine: updated to 1.2.3${clearLine}\n`,
    stderr: "",
  },
  {
    name: "learn success",
    invocation: ["_tine_learn", "--force", "jq"],
    requests: [
      started("learn", `jq${recordSeparator}force`),
      poll("learnStatus", "done:/tmp/jq.js"),
    ],
    exitCode: 0,
    stdout: `tine: learning jq… \rtine: learned jq → /tmp/jq.js${clearLine}\n`,
    stderr: "",
  },
  {
    name: "learn partial success",
    invocation: ["_tine_learn", "jq"],
    requests: [
      started("learn", "jq"),
      poll("learnStatus", "partial:/tmp/jq.js"),
    ],
    exitCode: 0,
    stdout: `tine: learning jq… \rtine: learned jq → /tmp/jq.js${clearLine}\ntine: only the start of its --help fits the model — the spec may be partial\n`,
    stderr: "",
  },
  {
    name: "learn incomplete success",
    invocation: ["_tine_learn", "jq"],
    requests: [
      started("learn", "jq"),
      poll("learnStatus", "incomplete:7/9:/tmp/jq.js"),
    ],
    exitCode: 0,
    stdout: `tine: learning jq… \rtine: learned jq → /tmp/jq.js${clearLine}\ntine: 7/9 option lines survived validation — the spec is incomplete\n`,
    stderr: "",
  },
  {
    name: "learn failure",
    invocation: ["_tine_learn", "jq"],
    requests: [
      started("learn", "jq"),
      poll("learnStatus", "failed:model unavailable"),
    ],
    exitCode: 1,
    stdout: `tine: learning jq… \r${clearLine}`,
    stderr: "tine: model unavailable\n",
  },
  {
    name: "ask success",
    invocation: ["_tine_ask", "find", "files"],
    requests: [
      started("ask", "find files"),
      poll("askStatus", `done:note${recordSeparator}Use rg${recordSeparator}`),
    ],
    exitCode: 0,
    stdout: `tine: thinking… \r${clearLine}tine: Use rg\n`,
    stderr: "",
  },
  {
    name: "ask progress then success",
    invocation: ["_tine_ask", "find", "files"],
    requests: [
      started("ask", "find files"),
      poll("askStatus", "running:searching"),
      poll("askStatus", `done:note${recordSeparator}Use rg${recordSeparator}`),
    ],
    exitCode: 0,
    stdout: `tine: thinking… \rtine: searching… | ${clearLine}\r${clearLine}tine: Use rg\n`,
    stderr: "",
  },
  {
    name: "ask failure",
    invocation: ["_tine_ask", "find", "files"],
    requests: [
      started("ask", "find files"),
      poll("askStatus", "failed:model unavailable"),
    ],
    exitCode: 1,
    stdout: `tine: thinking… \r${clearLine}`,
    stderr: "tine: model unavailable\n",
  },
];

const harness = [
  'source "$1"',
  "shift",
  "local invocation_count=$1",
  "shift",
  'local -a invocation=("${@:1:$invocation_count}")',
  "shift $invocation_count",
  'typeset -ga requests=("$@")',
  'typeset -g request_mismatch=""',
  "sleep() { : }",
  "whence() { return 0 }",
  "_tine_req() {",
  "  if (( ${#requests} == 0 )); then",
  '    request_mismatch="unexpected request: $1 ${2-}"',
  "    return 1",
  "  fi",
  "  local expected=$requests[1]",
  "  shift requests",
  "  local expected_verb=${expected%%$_TINE_US*}",
  "  local remainder=${expected#*$_TINE_US}",
  "  local expected_payload=${remainder%%$_TINE_US*}",
  "  _TINE_REPLY=${remainder#*$_TINE_US}",
  '  if [[ "$1" != "$expected_verb" || "${2-}" != "$expected_payload" ]]; then',
  '    request_mismatch="expected: $expected_verb $expected_payload; got: $1 ${2-}"',
  "    return 1",
  "  fi",
  "  return 0",
  "}",
  '"${invocation[@]}"',
  "local invocation_result=$?",
  'if [[ -n "$request_mismatch" || ${#requests} != 0 ]]; then',
  '  print -u2 -r -- "${request_mismatch:-unconsumed requests: ${#requests}}"',
  "  exit 90",
  "fi",
  "exit $invocation_result",
].join("\n");

for (const transcript of transcripts) {
  test(`shell transcript: ${transcript.name}`, () => {
    const requests = transcript.requests.map(
      ({ verb, payload, reply }) =>
        `${verb}${unitSeparator}${payload}${unitSeparator}${reply}`,
    );
    const result = Bun.spawnSync(
      [
        "zsh",
        "-df",
        "-c",
        harness,
        "shell-transcript",
        "shell/tine.zsh",
        transcript.invocation.length.toString(),
        ...transcript.invocation,
        ...requests,
      ],
      { cwd: new URL("..", import.meta.url).pathname },
    );

    expect({
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    }).toEqual({
      exitCode: transcript.exitCode,
      stdout: transcript.stdout,
      stderr: transcript.stderr,
    });
  });
}

test("shell transcript count stays intentional", () => {
  expect(transcripts).toHaveLength(15);
});

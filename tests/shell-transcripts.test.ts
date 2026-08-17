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
  pollInterval?: string;
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

const repeatedPoll = (verb: string, reply: string, count: number): Request[] =>
  Array.from({ length: count }, () => poll(verb, reply));

const spinnerProgress = (line: string, count: number, suffix = ""): string => {
  const spin = "|/-\\";
  return Array.from(
    { length: count },
    (_, index) => `\rtine: ${line}… ${spin[index % spin.length]} ${suffix}`,
  ).join("");
};

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
    name: "update rejected by older app",
    invocation: ["_tine_update"],
    requests: [request("appUpdate", "", "0")],
    exitCode: 1,
    stdout: "",
    stderr:
      "tine: the running app is older than this shell integration — run: tine restart\n",
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
    name: "learn rejected while already learning",
    invocation: ["_tine_learn", "jq"],
    requests: [request("learn", "jq", "busy:jq")],
    exitCode: 1,
    stdout: "",
    stderr: "tine: already learning jq — try again shortly\n",
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
  {
    name: "ask rejected while busy",
    invocation: ["_tine_ask", "find", "files"],
    requests: [request("ask", "find files", "busy:index")],
    exitCode: 1,
    stdout: "",
    stderr: 'tine: already busy with "index" — try again shortly\n',
  },
];

const giveUpTranscripts: Transcript[] = [
  {
    name: "update gives up after 200 checking ticks",
    invocation: ["_tine_update"],
    requests: [
      started("appUpdate"),
      ...repeatedPoll("appUpdateStatus", "checking", 201),
    ],
    pollInterval: "0.001",
    exitCode: 1,
    stdout: `tine: checking for updates… ${spinnerProgress("checking for updates", 200)}\r${clearLine}`,
    stderr: "tine: could not check for updates\n",
  },
  {
    name: "learn gives up after 600 model ticks",
    invocation: ["_tine_learn", "jq"],
    requests: [
      started("learn", "jq"),
      ...repeatedPoll("learnStatus", "idle", 601),
    ],
    pollInterval: "0.001",
    exitCode: 1,
    stdout: `tine: learning jq… ${spinnerProgress("learning jq", 600, clearLine)}\r${clearLine}`,
    stderr: "tine: gave up waiting for the model\n",
  },
  {
    name: "ask gives up after 600 answer ticks",
    invocation: ["_tine_ask", "find", "files"],
    requests: [
      started("ask", "find files"),
      ...repeatedPoll("askStatus", "idle", 601),
    ],
    pollInterval: "0.001",
    exitCode: 1,
    stdout: `tine: thinking… ${spinnerProgress("thinking", 600, clearLine)}\r${clearLine}`,
    stderr: "tine: gave up waiting for an answer\n",
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

// Hundreds of spinner ticks per run: on a loaded CI runner these overrun bun's
// 5s default and have already failed two releases.
const giveUpTimeout = 60_000;

function registerTranscript(transcript: Transcript, timeout?: number) {
  test(
    `shell transcript: ${transcript.name}`,
    () => {
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
        {
          cwd: new URL("..", import.meta.url).pathname,
          env: transcript.pollInterval
            ? { ...process.env, TINE_POLL_INTERVAL: transcript.pollInterval }
            : process.env,
        },
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
    },
    timeout,
  );
}

for (const transcript of transcripts) {
  registerTranscript(transcript);
}

for (const transcript of giveUpTranscripts) {
  registerTranscript(transcript, giveUpTimeout);
}

test("shell transcript count stays intentional", () => {
  expect(transcripts).toHaveLength(18);
  expect(giveUpTranscripts).toHaveLength(3);
});

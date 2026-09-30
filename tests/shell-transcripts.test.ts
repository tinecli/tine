// biome-ignore-all lint/suspicious/noTemplateCurlyInString: The harness contains zsh parameter expansions.
import { afterAll, expect, test } from "bun:test";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";

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

const repoRoot = new URL("..", import.meta.url).pathname;
const sshTimeout = 30_000;
const repoCwd = repoRoot.replace(/\/$/, "");

const scratchDirs: string[] = [];

const scratchDir = (): string => {
  const dir = realpathSync(mkdtempSync("/tmp/tine-ssh-"));
  if (!/^\/(private\/)?tmp\/tine-ssh-/.test(dir)) {
    throw new Error(`refusing to run outside a temp dir: ${dir}`);
  }
  chmodSync(dir, 0o700);
  scratchDirs.push(dir);
  return dir;
};

afterAll(() => {
  for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true });
});

type FakeApp = { lines: string[]; stop: () => void };

const fakeApp = (
  path: string,
  reply: (line: string) => string,
  mode = 0o600,
): FakeApp => {
  const lines: string[] = [];
  const pending = new Map<object, string>();
  const server = Bun.listen({
    unix: path,
    socket: {
      data(socket, data) {
        const buffered = (pending.get(socket) ?? "") + data.toString();
        const end = buffered.indexOf("\n");
        if (end < 0) {
          pending.set(socket, buffered);
          return;
        }
        const line = buffered.slice(0, end);
        lines.push(line);
        socket.end(`${reply(line)}\n`);
      },
    },
  });
  chmodSync(path, mode);
  return { lines, stop: () => server.stop(true) };
};

const runZsh = async (script: string, env: Record<string, string>) => {
  const proc = Bun.spawn(
    ["zsh", "-df", "-c", `source shell/tine.zsh\n${script}`],
    {
      cwd: repoRoot,
      env: { PATH: "/usr/bin:/bin", ...env },
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { stdout, stderr, exitCode };
};

const token = "0123456789abcdef0123456789abcdef";

const remoteEnv = (dir: string, sock: string) => ({
  HOME: dir,
  TINE_SOCK: sock,
  TINE_TOKEN: token,
  TINE_REMOTE: "1",
});

test(
  "remote mode prefixes every request with the token",
  async () => {
    const dir = scratchDir();
    const app = fakeApp(`${dir}/tine.sock`, () => "3");
    const result = await runZsh(
      'print -r -- $$; cd "$HOME"; COLUMNS=80; LINES=24; BUFFER="git st"; CURSOR=6\n' +
        '_tine_req update; print -r -- "rc=$? reply=$_TINE_REPLY"',
      remoteEnv(dir, `${dir}/tine.sock`),
    ).finally(app.stop);
    const [pid, status] = result.stdout.trim().split("\n");
    expect(status).toBe("rc=0 reply=3");
    expect(app.lines).toEqual([
      [token, "update", "6", dir, `1;1;80;24;0;0;${pid}`, "git st"].join(
        unitSeparator,
      ),
    ]);
  },
  sshTimeout,
);

test(
  "remote mode refuses a socket it cannot trust",
  async () => {
    const dir = scratchDir();
    const real = fakeApp(`${dir}/real.sock`, () => "3");
    const loose = fakeApp(`${dir}/loose.sock`, () => "3", 0o666);
    symlinkSync(`${dir}/real.sock`, `${dir}/link.sock`);
    const outcomes = [];
    for (const sock of ["link.sock", "loose.sock", "missing.sock"]) {
      const result = await runZsh(
        'BUFFER="git st"; CURSOR=6; _tine_req update; print -r -- "rc=$?"',
        remoteEnv(dir, `${dir}/${sock}`),
      );
      outcomes.push([sock, result.stdout.trim()]);
    }
    real.stop();
    loose.stop();
    expect(outcomes).toEqual([
      ["link.sock", "rc=1"],
      ["loose.sock", "rc=1"],
      ["missing.sock", "rc=1"],
    ]);
    expect(real.lines).toEqual([]);
    expect(loose.lines).toEqual([]);
  },
  sshTimeout,
);

test(
  "remote mode sends no env and keeps KEYTIMEOUT",
  async () => {
    const dir = scratchDir();
    const app = fakeApp(`${dir}/tine.sock`, () => "0");
    const script =
      'KEYTIMEOUT=40; source shell/tine.zsh; _tine_send_env; print -r -- "kt=$KEYTIMEOUT"';
    const remote = await runZsh(script, remoteEnv(dir, `${dir}/tine.sock`));
    const local = await runZsh(script, {
      HOME: dir,
      TINE_SOCK: `${dir}/missing.sock`,
    });
    app.stop();
    expect(remote.stdout).toBe("kt=40\n");
    expect(local.stdout).toBe("kt=1\n");
    expect(app.lines).toEqual([]);
  },
  sshTimeout,
);

const localOnlyVerbs = [
  "dashboard",
  "restart",
  "install",
  "update",
  "learn",
  "ask",
  "index",
  "doctor",
];

test(
  "remote mode refuses local-only tine verbs",
  async () => {
    const dir = scratchDir();
    const app = fakeApp(`${dir}/tine.sock`, () => "1.2.3");
    const env = remoteEnv(dir, `${dir}/tine.sock`);
    const refused = [];
    for (const verb of localOnlyVerbs) {
      const result = await runZsh(`tine ${verb} jq`, env);
      refused.push([result.exitCode, result.stderr]);
    }
    const version = await runZsh("tine version", env);
    app.stop();
    expect(refused).toEqual(
      localOnlyVerbs.map((verb) => [
        1,
        `tine: ${verb} is not available over ssh\n`,
      ]),
    );
    expect(version.stdout).toBe("tine 1.2.3\n");
    expect(
      app.lines.map((line) => line.split(unitSeparator).slice(0, 2)),
    ).toEqual([[token, "version"]]);
  },
  sshTimeout,
);

type SshCase = {
  name: string;
  args: string[];
  reply?: (line: string) => string;
  sshConfig?: string;
  remote?: boolean;
  appDown?: boolean;
};

const sshWorld = async (c: SshCase) => {
  const dir = scratchDir();
  mkdirSync(`${dir}/bin`, { mode: 0o700 });
  writeFileSync(
    `${dir}/bin/ssh`,
    [
      "#!/bin/sh",
      'if [ "$1" = "-G" ]; then',
      '  [ -n "$FAKE_SSH_CONFIG" ] && printf "user me\\n%s\\nport 22\\n" "$FAKE_SSH_CONFIG"',
      "  exit 0",
      "fi",
      'for a in "$@"; do printf "%s\\n" "$a"; done >> "$SSH_LOG"',
      'printf "%s\\n" "--end--" >> "$SSH_LOG"',
      "exit 7",
    ].join("\n"),
    { mode: 0o700 },
  );
  writeFileSync(`${dir}/ssh.log`, "");
  const app = c.appDown
    ? undefined
    : fakeApp(`${dir}/tine.sock`, c.reply ?? (() => "0"));
  const listener = fakeApp(`${dir}/remote.sock`, () => "0");
  const env: Record<string, string> = {
    HOME: dir,
    PATH: `${dir}/bin:/usr/bin:/bin`,
    TINE_SOCK: `${dir}/tine.sock`,
    SSH_LOG: `${dir}/ssh.log`,
    TERM_PROGRAM: "ghostty",
  };
  if (c.sshConfig) env.FAKE_SSH_CONFIG = c.sshConfig;
  if (c.remote) Object.assign(env, { TINE_REMOTE: "1", TINE_TOKEN: token });
  const quoted = c.args.map((arg) => `'${arg.replace(/'/g, "'\\''")}'`);
  const result = await runZsh(`tine ssh ${quoted.join(" ")}`, env);
  app?.stop();
  listener.stop();
  const invocations = readFileSync(`${dir}/ssh.log`, "utf8")
    .split("--end--\n")
    .filter((chunk) => chunk.length > 0)
    .map((chunk) => chunk.replace(/\n$/, "").split("\n"));
  return {
    dir,
    exitCode: result.exitCode,
    invocations,
    appLines: app?.lines ?? [],
    listenerLines: listener.lines,
  };
};

const plainSshCases: SshCase[] = [
  {
    name: "the app is not running",
    args: ["-p", "2222", "host"],
    appDown: true,
  },
  { name: "a remote command is given", args: ["host", "ls", "-la"] },
  {
    name: "a remote command follows options after the host",
    args: ["-l", "me", "host", "-p", "22", "uptime"],
  },
  { name: "the command follows --", args: ["--", "host", "uptime"] },
  { name: "-N asks for no session", args: ["-N", "host"] },
  { name: "-W forwards stdio", args: ["-W", "db:5432", "jump"] },
  { name: "a flag is unknown", args: ["-Z", "host"] },
  { name: "no destination is given", args: ["-p", "22"] },
  ...[
    "remotecommand tmux attach",
    "sessiontype none",
    "controlmaster auto",
    "controlpersist 10m",
    "controlpath ~/.ssh/cm-%C",
    "forkafterauthentication yes",
    "stdinnull yes",
  ].map((sshConfig) => ({
    name: `ssh -G reports ${sshConfig}`,
    args: ["host"],
    sshConfig,
  })),
  { name: "the shell is already remote", args: ["host"], remote: true },
];

for (const c of plainSshCases) {
  test(
    `tine ssh runs plain ssh when ${c.name}`,
    async () => {
      const world = await sshWorld(c);
      expect(world.exitCode).toBe(7);
      expect(world.invocations).toEqual([c.args]);
      expect(world.appLines).toEqual([]);
    },
    sshTimeout,
  );
}

test(
  "tine ssh runs plain ssh when the app predates sshBegin",
  async () => {
    const world = await sshWorld({ name: "old app", args: ["host"] });
    expect(world.exitCode).toBe(7);
    expect(world.invocations).toEqual([["host"]]);
    expect(world.appLines.map((line) => line.split(unitSeparator)[0])).toEqual([
      "sshBegin",
    ]);
  },
  sshTimeout,
);

test(
  "tine ssh forwards the restricted listener to a per-session path",
  async () => {
    const world = await sshWorld({
      name: "forward",
      args: ["-l", "me", "-i", "key file", "host", "-p", "22"],
      reply: (line) => (line.startsWith("sshBegin") ? token : "0"),
    });
    const sock = `/tmp/tine-${token}.sock`;
    expect(world.exitCode).toBe(7);
    expect(world.invocations).toEqual([
      [
        "-t",
        "-R",
        `${sock}:${world.dir}/remote.sock`,
        "-l",
        "me",
        "-i",
        "key file",
        "host",
        "-p",
        "22",
        `exec env TINE_SOCK=${sock} TINE_TOKEN=${token} TINE_REMOTE=1 TERM_PROGRAM=ghostty /bin/sh -c 'exec "\${SHELL:-/bin/sh}" -l'`,
      ],
    ]);
    expect(world.appLines.map((line) => line.split(unitSeparator))).toEqual([
      ["sshBegin", "", repoCwd, expect.stringMatching(/;\d+$/), ""],
      ["sshEnd", "", repoCwd, expect.stringMatching(/;\d+$/), token],
    ]);
    expect(world.listenerLines).toEqual([]);
  },
  sshTimeout,
);

test(
  "tine ssh treats a destination after -- as a login",
  async () => {
    const world = await sshWorld({
      name: "double dash",
      args: ["--", "host"],
      reply: (line) => (line.startsWith("sshBegin") ? token : "0"),
    });
    expect(
      world.invocations.map((argv) =>
        argv.slice(0, 2).concat(argv.slice(3, 5)),
      ),
    ).toEqual([["-t", "-R", "--", "host"]]);
  },
  sshTimeout,
);

test(
  "tine ssh proceeds when ssh -G reports the defaults",
  async () => {
    const world = await sshWorld({
      name: "defaults",
      args: ["host"],
      sshConfig:
        "sessiontype default\ncontrolmaster false\ncontrolpersist no\nforkafterauthentication no\nstdinnull no",
      reply: (line) => (line.startsWith("sshBegin") ? token : "0"),
    });
    expect(world.invocations.map((argv) => argv[0])).toEqual(["-t"]);
  },
  sshTimeout,
);

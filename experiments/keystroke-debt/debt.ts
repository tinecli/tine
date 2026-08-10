import { decodeHistory, type Entry, parseHistory } from "./src/history.js";
import { buildPlan, occurrencesFrom } from "./src/plan.js";
import { render } from "./src/render.js";
import { liveShell, sampleShell } from "./src/shell.js";

const SAMPLE = `${import.meta.dir}/sample`;
const DEFAULT_TOP = 8;
const MAX_TOP = 20;

const HELP = `keystroke debt — what your shell habits cost you, and the aliases that pay it back

  bun debt.ts              audit your own ~/.zsh_history (read-only)
  bun debt.ts --sample     audit the bundled sample history — instant, offline
  bun debt.ts --history <path>
  bun debt.ts --top <n>    how many aliases to propose (default ${DEFAULT_TOP})

Nothing is ever written. Copy the aliases yourself, or don't.`;

type Options = {
  sample: boolean;
  history: string | null;
  top: number;
  help: boolean;
  unknown: string | null;
};

const parseArgs = (argv: string[]): Options => {
  const options: Options = {
    sample: false,
    history: null,
    top: DEFAULT_TOP,
    help: false,
    unknown: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--sample") options.sample = true;
    else if (arg === "--help" || arg === "-h") options.help = true;
    else if (arg === "--history") options.history = argv[++index] ?? null;
    else if (arg === "--top")
      options.top = Math.min(
        MAX_TOP,
        Math.max(1, Number(argv[++index]) || DEFAULT_TOP),
      );
    else options.unknown = arg ?? null;
  }
  return options;
};

const historyPath = (options: Options): string => {
  if (options.sample) return `${SAMPLE}/zsh_history`;
  if (options.history) return options.history;
  return Bun.env.HISTFILE || `${Bun.env.HOME ?? "."}/.zsh_history`;
};

const readHistory = async (path: string): Promise<string | null> => {
  const file = Bun.file(path);
  if (!(await file.exists())) return null;
  return decodeHistory(new Uint8Array(await file.arrayBuffer()));
};

const lastStamp = (entries: Entry[]): number =>
  entries.reduce((latest, entry) => Math.max(latest, entry.at ?? 0), 0) ||
  Date.now();

const tilde = (path: string): string => {
  const home = Bun.env.HOME ?? "";
  return home !== "" && path.startsWith(home)
    ? `~${path.slice(home.length)}`
    : path;
};

const options = parseArgs(Bun.argv.slice(2));
if (options.help || options.unknown !== null) {
  if (options.unknown !== null)
    console.log(`Not a flag I know: ${options.unknown}\n`);
  console.log(HELP);
} else {
  const path = historyPath(options);
  const text = await readHistory(path);
  if (text === null) {
    console.log(
      `No history file at ${tilde(path)}.\nTry \`bun debt.ts --sample\` for the bundled demo.`,
    );
  } else {
    const entries = parseHistory(text);
    const occurrences = occurrencesFrom(entries);
    const shell = options.sample ? await sampleShell(SAMPLE) : liveShell();
    // The sample statement is dated, so "recent" is measured from the fixture's
    // own last entry — the demo reads the same in 2030.
    const now = options.sample ? lastStamp(entries) : Date.now();
    const plan = buildPlan(occurrences, shell, { top: options.top, now });
    console.log(
      render({
        source: options.sample ? "bundled sample" : tilde(path),
        entries,
        occurrences,
        plan,
        color: Bun.enableANSIColors && !Bun.env.NO_COLOR,
      }),
    );
  }
}

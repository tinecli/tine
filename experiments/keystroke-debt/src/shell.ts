export type Owner = "command" | "alias" | "plan";
export type Shell = { taken: Map<string, Owner>; aliases: Map<string, string> };

const keys = (parameter: string): string => `$\{(k)${parameter}}`;
const NAMES = `print -lr -- ${["commands", "builtins", "reswords", "functions"].map(keys).join(" ")}`;

const unquote = (body: string): string =>
  body.startsWith("'") && body.endsWith("'") && body.length > 1
    ? body.slice(1, -1).replaceAll("'\\''", "'")
    : body;

export const parseAliases = (lines: string[]): Map<string, string> => {
  const aliases = new Map<string, string>();
  for (const line of lines) {
    const equals = line.indexOf("=");
    const name = equals > 0 ? line.slice(0, equals) : "";
    if (name === "" || /\s/.test(name)) continue;
    const body = unquote(line.slice(equals + 1)).trim();
    if (body !== "") aliases.set(name, body);
  }
  return aliases;
};

const shellFrom = (names: string[], aliasLines: string[]): Shell => {
  const aliases = parseAliases(aliasLines);
  const taken = new Map<string, Owner>();
  for (const name of names)
    if (name.trim() !== "") taken.set(name.trim(), "command");
  for (const name of aliases.keys()) taken.set(name, "alias");
  return { taken, aliases };
};

// Sample mode never spawns a process and never reads outside this directory.
export const sampleShell = async (directory: string): Promise<Shell> => {
  const read = async (name: string): Promise<string[]> =>
    (await Bun.file(`${directory}/${name}`).text()).split("\n");
  return shellFrom(await read("commands.txt"), await read("aliases.txt"));
};

const zsh = (script: string): string[] => {
  try {
    const run = Bun.spawnSync(["zsh", "-i", "-c", script], {
      timeout: 4_000,
      stdout: "pipe",
      stderr: "ignore",
    });
    return run.success ? run.stdout.toString().split("\n") : [];
  } catch {
    return [];
  }
};

// Ask the real shell what names it already answers to. A hung or missing zsh
// costs us the collision check, never the report.
export const liveShell = (): Shell => shellFrom(zsh(NAMES), zsh("alias"));

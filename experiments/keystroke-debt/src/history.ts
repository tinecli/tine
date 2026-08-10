export type Entry = { command: string; at: number | null };

const EXTENDED = /^: (\d+):(\d+);([\s\S]*)$/;
const META = 0x83;

// zsh "metafies" the file: a byte with the high bit set is written as 0x83
// followed by that byte XOR 0x20. Undo it before decoding, or every accented
// path in the history turns into replacement characters.
export const decodeHistory = (bytes: Uint8Array): string => {
  const out = new Uint8Array(bytes.length);
  let length = 0;
  for (let index = 0; index < bytes.length; index += 1) {
    const byte = bytes[index] ?? 0;
    const next = bytes[index + 1];
    if (byte === META && next !== undefined) {
      out[length] = next ^ 0x20;
      index += 1;
    } else {
      out[length] = byte;
    }
    length += 1;
  }
  return new TextDecoder().decode(out.subarray(0, length));
};

const unfold = (command: string): string =>
  command.endsWith("\\") ? command.slice(0, -1) : command;

// zsh writes one entry per line, prefixed with `: <epoch>:<seconds>;` when
// EXTENDED_HISTORY is on. A line without that prefix in an extended file is the
// tail of a multi-line entry, as is any line after one ending in a backslash.
export const parseHistory = (text: string): Entry[] => {
  const entries: Entry[] = [];
  const lines = text.split("\n");
  if (lines.at(-1) === "") lines.pop();
  let pending: Entry | null = null;
  for (const line of lines) {
    const extended = EXTENDED.exec(line);
    if (extended) {
      if (pending) entries.push(pending);
      pending = { command: extended[3] ?? "", at: Number(extended[1]) * 1000 };
      continue;
    }
    if (pending && (pending.at !== null || pending.command.endsWith("\\"))) {
      pending.command = `${unfold(pending.command)}\n${line}`;
      continue;
    }
    if (pending) entries.push(pending);
    pending = line.trim() === "" ? null : { command: line, at: null };
  }
  if (pending) entries.push(pending);
  return entries.filter((entry) => entry.command.trim() !== "");
};

const SEPARATORS = new Set([";", "|", "&", "\n", "(", ")", "{", "}", "`"]);
const REDIRECTS = new Set(["<", ">"]);

// Every command word position in an entry, quote-aware. `git add . && git
// commit -m "x"` is two commands; a `;` inside quotes is not a separator.
export const commandsIn = (entry: string): string[][] => {
  const commands: string[][] = [];
  let tokens: string[] = [];
  let token = "";
  let quote = "";
  let skipping = false;
  for (let index = 0; index < entry.length; index += 1) {
    const char = entry[index] ?? "";
    if (quote !== "") {
      if (char === quote) quote = "";
      else token += char;
      continue;
    }
    if (char === "\\") {
      token += entry[index + 1] ?? "";
      index += 1;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }
    if (char === " " || char === "\t") {
      if (token !== "" && !skipping) tokens.push(token);
      token = "";
      continue;
    }
    if (REDIRECTS.has(char)) {
      if (token !== "" && !skipping && !/^\d+$/.test(token)) tokens.push(token);
      token = "";
      skipping = true;
      continue;
    }
    if (SEPARATORS.has(char)) {
      if (token !== "" && !skipping) tokens.push(token);
      token = "";
      skipping = false;
      if (tokens.length > 0) commands.push(tokens);
      tokens = [];
      continue;
    }
    token += char;
  }
  if (token !== "" && !skipping) tokens.push(token);
  if (tokens.length > 0) commands.push(tokens);
  return commands;
};

import type { Entry } from "./history.js";
import type { Collision, Occurrence, Plan, Refinance } from "./plan.js";

export type Report = {
  source: string;
  entries: Entry[];
  occurrences: Occurrence[];
  plan: Plan;
  color: boolean;
};

const CHARS_PER_MINUTE = 300;
const NAME_WIDTH = 7;
const PHRASE_WIDTH = 30;
const USES_WIDTH = 7;
const BAR_WIDTH = 11;
const SAVED_WIDTH = 6;
const MAX_DEAD = 4;
const DAY = 86_400_000;
const RULE =
  4 + NAME_WIDTH + PHRASE_WIDTH + USES_WIDTH + BAR_WIDTH + SAVED_WIDTH + 4;

const paint = (code: string, color: boolean) => (text: string) =>
  color ? `\u001b[${code}m${text}\u001b[0m` : text;

const count = (value: number): string =>
  Math.round(value).toLocaleString("en-US");

const clock = (keystrokes: number): string => {
  const minutes = Math.round(keystrokes / CHARS_PER_MINUTE);
  const hours = Math.floor(minutes / 60);
  return hours === 0 ? `${minutes}m` : `${hours}h ${minutes % 60}m`;
};

const day = (at: number): string =>
  new Date(at).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  });

const quoted = (phrase: string): string =>
  `'${phrase.replaceAll("'", "'\\''")}'`;

const bar = (saved: number, best: number): string =>
  "▇".repeat(Math.max(1, Math.round((saved / best) * BAR_WIDTH)));

const HEADING = `    ${"alias".padEnd(NAME_WIDTH)}${"expands to".padEnd(PHRASE_WIDTH)}${"typed".padStart(USES_WIDTH)}  ${" ".repeat(BAR_WIDTH)}  ${"saves".padStart(SAVED_WIDTH)}`;

const row = (
  item: Refinance,
  best: number,
  dim: (text: string) => string,
  accent: (text: string) => string,
): string =>
  `    ${accent(item.name.padEnd(NAME_WIDTH))}${item.phrase.padEnd(PHRASE_WIDTH)}${dim(`${count(item.uses)}×`.padStart(USES_WIDTH))}  ${accent(bar(item.saved, best).padEnd(BAR_WIDTH))}  ${count(item.saved).padStart(SAVED_WIDTH)}`;

const owns = ({ owner, body }: Collision): string => {
  if (owner === "command") return "is already a command on this machine";
  if (owner === "plan") return `went to ${quoted(body ?? "")} above`;
  return `is already your alias for ${quoted(body ?? "")}`;
};

const collision = (item: Refinance, accent: (t: string) => string): string[] =>
  item.collisions.map(
    (clash) =>
      `    ${accent(clash.name)} ${owns(clash)}, so ${item.phrase} became ${accent(item.name)}.`,
  );

const span = (entries: Entry[]): { text: string; days: number } => {
  const stamps = entries
    .map((entry) => entry.at)
    .filter((at): at is number => at !== null);
  if (stamps.length === 0) return { text: "undated history", days: 0 };
  const from = Math.min(...stamps);
  const to = Math.max(...stamps);
  return {
    text: `${day(from)} → ${day(to)}`,
    days: Math.max(1, (to - from) / DAY),
  };
};

export const render = ({
  source,
  entries,
  occurrences,
  plan,
  color,
}: Report): string => {
  const dim = paint("2", color);
  const bold = paint("1", color);
  const accent = paint("36", color);
  const good = paint("32", color);
  const warn = paint("33", color);
  const ghost = paint("35", color);

  const keystrokes = entries.reduce(
    (total, entry) => total + entry.command.length + 1,
    0,
  );
  const history = span(entries);
  const perYear = history.days > 0 ? (plan.saved * 365) / history.days : 0;
  const best = plan.refinances[0]?.saved ?? 1;
  const dead = plan.dead.slice(0, MAX_DEAD);

  const lines = [
    "",
    `  ${bold("KEYSTROKE DEBT")}   ${dim(`statement · ${source}`)}`,
    `  ${dim("─".repeat(RULE))}`,
    `  ${count(entries.length)} commands   ${dim("·")}   ${history.text}   ${dim("·")}   ${count(keystrokes)} keystrokes`,
    `  ${dim(`That is ${clock(keystrokes)} of your life spent pressing keys at a prompt.`)}`,
    "",
  ];

  if (plan.refinances.length === 0)
    return [
      ...lines,
      `  ${good("Nothing to refinance — your prompt is already lean.")}`,
      "",
    ].join("\n");

  lines.push(
    `  ${bold("REFINANCING PLAN")}`,
    dim(HEADING),
    ...plan.refinances.map((item) => row(item, best, dim, accent)),
    "",
    `  ${good(`${count(plan.saved)} keystrokes`)} unspent over this history ${dim("·")} ${good(`${count(perYear)}/year`)} ${dim(`≈ ${clock(perYear)} of typing a year`)}`,
    "",
  );

  const collisions = plan.refinances.flatMap((item) => collision(item, warn));
  if (collisions.length > 0)
    lines.push(`  ${bold("COLLISIONS AVOIDED")}`, ...collisions, "");

  if (dead.length > 0)
    lines.push(
      `  ${bold("DEAD ALIASES")}   ${dim("you defined them, then never typed them")}`,
      ...dead.map(
        (item) =>
          `    ${ghost(`${item.name}=${quoted(item.body)}`)} ${dim(`— and typed ${item.body} the long way ${count(item.longhandUses)}×`)}`,
      ),
      "",
    );

  lines.push(
    `  ${bold("PASTE ME")}   ${dim("~/.zshrc")}`,
    ...plan.refinances.map(
      (item) => `    alias ${item.name}=${quoted(item.phrase)}`,
    ),
    "",
    dim(
      `  Read from ${count(occurrences.length)} command words. Nothing was written anywhere.`,
    ),
    "",
  );
  return lines.join("\n");
};

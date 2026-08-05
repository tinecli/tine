import { fs } from "@tine/api-bindings";
import { isInDevMode } from "@tine/api-bindings-wrappers";
// "util" here is the npm browser-polyfill package, not Node's built-in — no node: prefix.
import util from "util";

// Logging functions
const DEFAULT_CONSOLE = {
  log: console.log,
  warn: console.warn,
  error: console.error,
};

export const LOG_DIR = window.fig?.constants?.logsDir;

const NEW_LOG_FN = (...content: unknown[]) => {
  fs.append(
    `${LOG_DIR}/logs/specs.log`,
    `\n${util.format(...content)}`,
  ).finally(() => DEFAULT_CONSOLE.warn("SPEC LOG:", util.format(...content)));
};

export function runPipingConsoleMethods<T>(fn: () => T) {
  try {
    pipeConsoleMethods();
    return fn();
  } finally {
    restoreConsoleMethods();
  }
}

export function pipeConsoleMethods() {
  if (isInDevMode()) {
    console.log = NEW_LOG_FN;
    console.warn = NEW_LOG_FN;
    console.error = NEW_LOG_FN;
  }
}

export function restoreConsoleMethods() {
  if (isInDevMode()) {
    console.log = DEFAULT_CONSOLE.log;
    console.warn = DEFAULT_CONSOLE.warn;
    console.error = DEFAULT_CONSOLE.error;
  }
}

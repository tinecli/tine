type Method = "debug" | "info" | "warn" | "error";

export type Logger = Record<Method, (...args: unknown[]) => void>;

const drop = () => {};

export const logger: Logger = {
  debug: drop,
  info: drop,
  warn: (...args) => console.warn(...args),
  error: (...args) => console.error(...args),
};

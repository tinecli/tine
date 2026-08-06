type Host = {
  __tineRun?: (input: string) => string;
  __tineReadFile?: (path: string) => string | Promise<string>;
};

export type ProcessInput = {
  executable: string;
  args: string[];
  environment?: Record<string, string | undefined>;
  workingDirectory?: string;
  terminalSessionId?: string;
  timeout?: number;
};

export type ProcessOutput = {
  stdout: string;
  stderr: string;
  exitCode: number;
};

// Settles inside one microtask flush: JSEngine.swift reads the result straight
// after evaluateScript, so this must never gain an extra `.then` hop.
export const runProcess = (input: ProcessInput): Promise<ProcessOutput> => {
  const run = (globalThis as Host).__tineRun;
  if (typeof run !== "function") {
    return Promise.reject(new Error("tine: no command bridge"));
  }
  try {
    return Promise.resolve(JSON.parse(run(JSON.stringify(input))));
  } catch (err) {
    return Promise.reject(err);
  }
};

export const readFile = (path: string): Promise<string> => {
  const read = (globalThis as Host).__tineReadFile;
  if (!read) return Promise.resolve("");
  return Promise.resolve()
    .then(() => read(path))
    .catch(() => "");
};

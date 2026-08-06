// tine: stub for @tine/api-bindings in the engine bundle, selected by the
// "tine-jsc" export condition (see package.json). The real module is the
// protobuf IPC-to-desktop transport we don't use (buffer comes via the zsh
// socket, specs via __tineReadFile). This keeps proto/IPC out of the JSC bundle.
// Only these named exports are referenced by the bundled wrapper code.

const sub = { subscribe: () => () => {} };

export const fs = { read: () => Promise.resolve("") };

// Dynamic generators run real shell commands via the Swift bridge
// (globalThis.__tineRun, provided by the app). Input/output match Fig's
// Process.run: { executable, args, workingDirectory, environment, timeout }
// -> { stdout, stderr, exitCode }.
export const Process = {
  run: (input) => {
    const fn = globalThis.__tineRun;
    if (typeof fn !== "function") {
      return Promise.reject(new Error("tine: no command bridge"));
    }
    try {
      return Promise.resolve(JSON.parse(fn(JSON.stringify(input))));
    } catch (e) {
      return Promise.reject(e);
    }
  },
};

export const State = { current: () => Promise.resolve({}), didChange: sub };
export const Settings = {
  current: () => Promise.resolve({}),
  get: () => undefined,
  didChange: sub,
};
export const Keybindings = { pressed: sub };
export const History = {
  getHistory: () => Promise.resolve([]),
  query: () => Promise.resolve([]),
};
export const Shell = {};
export const Telemetry = { track: () => {}, page: () => {} };

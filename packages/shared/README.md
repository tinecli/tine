# @tine/shared

Code every other package needs.

- `host.ts`: the two hooks the host (Swift, or Node in tests) injects —
  `runProcess` and `readFile`. `runProcess` settles within one microtask flush,
  which `JSEngine.swift` depends on; never add a `.then` hop to it.
- `exec.ts` / `execShell.ts`: run a shell command through `host.runProcess`,
  either directly or via a login shell.
- `settings.ts`: the `SETTINGS` keys and the in-memory settings map.
- `log.ts`: the logger. `debug` and `info` are dropped; `warn` and `error` reach
  the console.
- `utils.ts`, `errors.ts`, `internal.ts`: helpers, error factory, spec types.

Everything is bundled into one IIFE by `scripts/build-engine.sh`, so a module
here holds exactly one instance of its state at runtime.

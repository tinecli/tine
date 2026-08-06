# tine engine

The whole JS side of tine, in one package. `scripts/build-engine.sh` bundles
`tine-engine.ts` into `app/engine/tine-engine.js`, which the SwiftUI app loads
into JavaScriptCore. `bun build` reads the TypeScript sources directly, so
nothing is compiled to a `dist/` first. The Swift app is the only frontend;
there is no web build.

## Folders

- `src/shell-parser/`: turns an edit-buffer line into tokens and a command,
  expanding shell aliases
- `src/parser/`: loads the Fig completion spec for that command and parses the
  tokens against it, producing annotations and the current arg
- `src/generators/`: runs a spec's dynamic generators (shell scripts, templates,
  custom functions) through the host's command bridge
- `src/suggestions/`: computes, sorts, and filters the suggestion list from
  parser results and completed generators
- `src/fuzzysort.ts`: fuzzy matching for the suggestion list, zero dependencies.
  `single(search, target)` returns `{ score, target, indexes }`, or `null` when
  the search string is not a subsequence of the target. Scores are integers
  where `0` is a perfect match and lower is worse: exact beats prefix, prefix
  beats a word boundary, a word boundary beats a match inside a word, and a
  contiguous match beats a scattered one. `indexes` lists the matched target
  positions, for highlighting.
- `src/shared/`: what the folders above share
  - `host.ts`: the two hooks the host (Swift, or Node in tests) injects —
    `runProcess` and `readFile`. `runProcess` settles within one microtask
    flush, which `JSEngine.swift` depends on; never add a `.then` hop to it.
  - `exec.ts` / `execShell.ts`: run a shell command through `host.runProcess`,
    either directly or via a login shell.
  - `settings.ts`: the `SETTINGS` keys and the in-memory settings map.
  - `log.ts`: the logger. `debug` and `info` are dropped; `warn` and `error`
    reach the console.
  - `utils.ts`, `errors.ts`, `internal.ts`: helpers, error factory, spec types.

`tine-engine.ts` wires these together and exposes
`globalThis.tineSuggest(line, cursor, cwd, callback)`. Everything is bundled
into one IIFE, so a module here holds exactly one instance of its state at
runtime.

## Tests

```bash
bun test                                   # whole repo
bun test packages/engine/src/suggestions   # one folder
```

# @tine/autocomplete

The suggestion engine behind tine. `scripts/build-engine.sh` bundles
`tine-engine.ts` into `app/engine/tine-engine.js`, which the SwiftUI app loads
into JavaScriptCore. The Swift app is the only frontend; there is no web build.

## Folders

- `generators/`: runs a spec's dynamic generators (shell scripts, templates,
  custom functions) through the host's command bridge
- `suggestions/`: computes, sorts, and filters the suggestion list from parser
  results and completed generators
- `history/`: history-backed argument suggestions

`tine-engine.ts` wires these together and exposes
`globalThis.tineSuggest(line, cursor, cwd, callback)`.

## Tests

```bash
bunx vitest run packages/autocomplete
```

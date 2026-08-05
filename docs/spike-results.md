# Phase 1 spike — results

**Question:** can we run the Fig autocomplete engine headless, and specifically
inside JavaScriptCore (so a native Swift app can use it with no webview)?

**Answer: yes.** Proven 2026-07-06.

Historical record. The commands below are what was run at the time; the repo has
since moved to bun (package manager, bundler and test runner) and dropped the
`proto`, `api-bindings` and `api-bindings-wrappers` packages.

## What was verified
1. **Engine logic is headless JS** — 87 tests pass in plain Node (vitest):
   `parseArguments` (107), `loadSpec` (9), `loadHelpers` (4), suggestions (42),
   generators. 0 failures. The only non-headless bits are `window.*` debug shims.
2. **It bundles** — `esbuild` produces a single 22.6 kb IIFE from `shell-parser`
   (same approach scales to the full engine).
3. **It runs in JavaScriptCore from Swift** — `spike/jsc-smoke.swift` loads the
   bundle in a `JSContext`, injects a 1-line `window` shim, and calls the real
   engine. Input `git commit -m 'hi' && aws sso lo` → tokens `["aws","sso","lo"]`.
4. **The IPC/proto layer (`api-bindings`, `proto`) is separable** — it's the
   figterm/desktop transport, which we replace with Swift + a zsh ZLE feed.

## Toolchain confirmed working
swiftc 6.3.3, JavaScriptCore, node 22, pnpm (via corepack), esbuild 0.25.3.

## Reproduce
The throwaway `spike/` scratch files are not kept in the repo — the commands
below are the record of what was run.
```
corepack pnpm install --ignore-scripts
(cd proto && corepack pnpm run build)
for p in shared api-bindings api-bindings-wrappers shell-parser autocomplete-parser; do (cd packages/$p && corepack pnpm run build); done
corepack pnpm exec vitest run packages/autocomplete-parser packages/autocomplete/src/suggestions
# JSC proof:
(cd packages/shell-parser && ../../node_modules/.pnpm/@esbuild+darwin-arm64@0.25.3/node_modules/@esbuild/darwin-arm64/bin/esbuild dist/index.js --bundle --format=iife --global-name=TINE --platform=browser --outfile=/tmp/engine.js)
swiftc spike/jsc-smoke.swift -o /tmp/jsctest && /tmp/jsctest
```

## Note
esbuild's native binary is skipped by `pnpm install --ignore-scripts`; call the
`@esbuild/darwin-arm64` binary directly (the Node wrapper's service spawn fails
under sandbox). Bundle from *within* a package dir — pnpm isolates the `@aws`
scope per-package, not at the repo root.

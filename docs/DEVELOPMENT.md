# Development

Build and run tine from source.

## Prerequisites

macOS 26+ (which ships zsh), Swift 6, and bun (the version in `package.json`'s
`packageManager`). No Node install is needed — bun runs the tests, the bundler and
tsc.

```sh
brew install bun    # bootstrap: `bun run setup` needs bun to run
bun run setup       # Xcode CLI tools, JS dependencies, typecheck
```

## Run

```sh
scripts/dev-run.sh                       # build app + engine, install specs + shell, launch
echo 'source ~/.local/share/tine/tine.zsh' >> ~/.zshrc
```

`dev-run.sh` builds a **separate** app — bundle id `dev.gustaf.tine.dev`, name
"Tine - development" — so it has its own Accessibility grant and menu-bar item and
never collides with an installed release.

Then grant **Accessibility** (System Settings → Privacy & Security → Accessibility)
so the panel can track your cursor. Caret tracking works in Terminal, iTerm2, VSCode,
and Ghostty — no pseudo-terminal, so nothing can leak your keystrokes.

## Layout

- `app/` — the Swift app (SwiftUI panel, JavaScriptCore host, socket server).
- `packages/engine/` — the whole JS engine, one package, no build output. See
  [its README](../packages/engine/README.md) for the folder map.
- `scripts/` — setup, build, package, and dev-run shell scripts.
- `shell/tine.zsh` — the ZLE widget sourced by your shell.
- `tests/` — the end-to-end smoke test that runs the bundled engine in a bare
  `vm` context. `packages/engine/tsconfig.json` includes it, so `bun run build`
  typechecks it too.

`bun run build` typechecks the TypeScript (`tsc --noEmit`), `bun test` runs the JS
tests, and `bun run engine` bundles `app/engine/tine-engine.js`.

## Specs

The completion pack is **downloaded at runtime** — the app fetches it from the
[`tinecli/autocomplete`](https://github.com/tinecli/autocomplete) fork's rolling
`specs` release and extracts it to `~/.local/share/tine/specs` (first launch, or via
Settings → "Install / Update Specs"). So there's nothing to build locally; just run
the app. To publish an updated pack, run the `Spec pack` workflow in the fork.

tine's own built-in specs live in `builtin-specs/` (e.g. the `tine` CLI spec); they
ship in the app bundle and are merged into the downloaded pack on install.

## Releasing

See [RELEASING.md](RELEASING.md).

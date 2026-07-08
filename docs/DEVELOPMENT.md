# Development

Build and run tine from source.

## Prerequisites

macOS 14+, zsh, Swift 6, and Node 22 + pnpm.

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

## Specs

`scripts/build-specs.sh` converts the `@withfig/autocomplete` specs (ESM → CJS so
JavaScriptCore can eval them) into `specs-pack/`; `scripts/install-specs.sh` copies
that to `~/.local/share/tine/specs` (where the app loads it). `dev-run.sh` runs both
as needed.

## Releasing

See [RELEASING.md](RELEASING.md).

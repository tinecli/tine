# Development

Build and run tine from source.

## Prerequisites

macOS 14+, zsh, Swift 6, and Node 22 + bun.

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

The completion pack is **downloaded at runtime** — the app fetches it from the
[`tinecli/autocomplete`](https://github.com/tinecli/autocomplete) fork's rolling
`specs` release and extracts it to `~/.local/share/tine/specs` (first launch, or via
Settings → "Install / Update Specs"). So there's nothing to build locally; just run
the app. To publish an updated pack, run the `Spec pack` workflow in the fork.

tine's own built-in specs live in `builtin-specs/` (e.g. the `tine` CLI spec); they
ship in the app bundle and are merged into the downloaded pack on install.

## Releasing

See [RELEASING.md](RELEASING.md).

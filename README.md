# Tine

Native macOS terminal autocomplete — a fast SwiftUI suggestion panel driven by the
Fig completion-spec engine. No cloud, no AI, no telemetry, no login, and **no
pseudo-terminal**.

## What it is

- A native, non-activating `NSPanel` + SwiftUI suggestion UI (not a webview).
- The Fig autocomplete engine (700+ CLIs) runs locally in
  **JavaScriptCore** — the same specs Fig/Amazon Q used, no network.
- A **zsh ZLE widget** feeds the edit buffer to the app over a unix socket. No
  pty wrapper, so nothing can leak the way pty-based tools can.

Features: history/frecency ranking (from your `~/.zsh_history`), fuzzy matching
with match highlighting, dangerous-command warnings, first-token command-name
completion, a Ctrl+K detail pane, shell-alias expansion, and a personal specs
directory that overrides the shipped pack.

## Install

```sh
brew install --cask gustaferiksson/tap/tine
```

Then finish setup:

```sh
echo 'source ~/.local/share/tine/tine.zsh' >> ~/.zshrc   # shell integration
open -a Tine                                              # launch once (installs the widget)
```

Grant **Accessibility** (System Settings → Privacy & Security → Accessibility) so the
panel can track your cursor. Released builds are Developer ID signed & notarized, so
they launch normally.

## Requirements

macOS 14+ and zsh.

## Configure

Via the Settings window or `~/.config/tine/config.json`: font + size, max rows,
accent, glass, command-name completion, and the local specs directory.

Drop your own Fig `.js` specs under `~/.tine/specs/` to teach tine your commands —
in either of two folders:

- **`override/<cmd>.js`** fully replaces a command's spec.
- **`extend/<cmd>.js`** merges *additively* onto the pack's spec — adds
  subcommands/options while keeping everything upstream. Great for adding your own
  or a company CLI's commands (e.g. a missing `aws sso login`) without inheriting
  the whole 400-file `aws` spec.

## Development

Build and run from source: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Cutting a
release: [docs/RELEASING.md](docs/RELEASING.md).

## Credits & license

Built on the open-source
[amazon-q-developer-cli](https://github.com/aws/amazon-q-developer-cli) autocomplete
engine and Fig completion specs. Licensed under MIT **and** Apache-2.0 — see
`LICENSE.MIT`, `LICENSE.APACHE`, and `NOTICE`.

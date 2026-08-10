# Tine

Native macOS terminal autocomplete — a fast SwiftUI suggestion panel driven by the
Fig completion-spec engine. No cloud, no telemetry, no login, and **no
pseudo-terminal**. The one model tine uses runs on device, only when you ask for
it (`tine learn`).

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
brew install --cask tinecli/tap/tine
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

macOS 26+ and zsh.

## Configure

Everything lives under `~/.config/tine/`: `config.json` (also editable in the
Settings window — font + size, max rows, accent, glass, command-name completion)
and your own Fig `.js` specs under `~/.config/tine/specs/` (add more locations in
Settings). Each spec location has two folders:

- **`override/<cmd>.js`** fully replaces a command's spec.
- **`extend/<cmd>.js`** merges *additively* onto the pack's spec — adds
  subcommands/options while keeping everything upstream. Great for adding your own
  or a company CLI's commands (e.g. a missing `aws sso login`) without inheriting
  the whole 400-file `aws` spec.

For a CLI the pack never covered, `tine learn <cmd>` writes that `extend/<cmd>.js`
for you: it runs `<cmd> --help` and turns the output into a spec with Apple's
on-device model (macOS 26 with Apple Intelligence on; nothing leaves the Mac).
The result is a plain file — read it, edit it, delete it. `--force` learns again.

## Which tool does this?

```sh
tine ask "delete a directory and everything in it"
```

Tine indexes every binary on your `PATH` by its man page's `NAME` line — built on
this machine, on the first ask, and never shipped (`tine index` rebuilds it). The
question is answered with the tools you actually have installed, ranked, with what
each one is for. Where a tool's spec is known, the on-device model also composes a
command line from the flags that spec documents — parsed against the same spec
before you see it, so an invented flag never reaches you.

Nothing is ever run. The command is printed and pushed onto your next prompt, for
you to read and run yourself.

## Development

Build and run from source: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Cutting a
release: [docs/RELEASING.md](docs/RELEASING.md).

## Credits & license

Built on the open-source
[amazon-q-developer-cli](https://github.com/aws/amazon-q-developer-cli) autocomplete
engine and Fig completion specs. Licensed under MIT **and** Apache-2.0 — see
`LICENSE.MIT`, `LICENSE.APACHE`, and `NOTICE`.

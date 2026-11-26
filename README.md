<div align="center">

<img src="icon/tine.svg" width="128" height="128" alt="Tine app icon">

# Tine

**Autocomplete for your terminal, native and on device.**

Subcommands, flags and arguments for 700+ command-line tools, in a panel at your cursor.

[Download](https://github.com/tinecli/tine/releases/latest) · [Install with Homebrew](#install) · Requires macOS 26 and zsh

</div>

## What it does

Start typing a command in zsh and Tine shows what can come next: subcommands, options, arguments, file paths, ranked by what you actually run. Tab inserts the shared prefix, Enter accepts. It works in Terminal, iTerm2, VS Code and Ghostty.

Tine is a native SwiftUI app, not a webview. Completions come from the open-source Fig specs that Fig and Amazon Q shipped, run locally in JavaScriptCore. No cloud, no telemetry, no login. The one model Tine uses is Apple's on-device model, and only when you ask for it.

### Why no pseudo-terminal?

Fig-style tools wrap your shell in a pseudo-terminal to see what you type, so every keystroke passes through them. Tine doesn't: a zsh widget sends only the line you're editing to the app over a local unix socket, and the panel follows your cursor through Accessibility.

| | |
|---|---|
| **Completions** | The Fig spec pack for 700+ CLIs, command names on the first word, and your shell aliases expanded. |
| **Ranking** | Fuzzy matching with highlighted matches, ranked by frecency from your `~/.zsh_history`. |
| **Warnings** | Flags dangerous commands before you run them. |
| **Detail pane** | ⌃K shows the full description of the selected suggestion. |
| **Your own specs** | Fig `.js` specs in `~/.config/tine/specs/` override or extend any command in the pack. |
| **`tine learn <cmd>`** | Writes a spec for a CLI the pack doesn't cover, from its `--help`, with Apple's on-device model. |
| **`tine ask "<question>"`** | Finds the installed tool that does what you describe and suggests a command line for it. Nothing is run. |
| **Carapace** | An opt-in experimental completion source ([carapace](https://carapace.sh)). Your own specs still win, and commands it doesn't know fall back to the Fig specs. |
| **Completion API** | Other apps can show Tine's completions in their own UI with one JSON request over its socket. See [docs/COMPLETION-API.md](docs/COMPLETION-API.md). |
| **Settings** | Font and size, rows, accent, Liquid Glass, launch at login and menu bar icon. Settings are saved to `~/.config/tine/config.json`. |
| **Updates** | Downloads new specs and new versions of Tine automatically. |

## Install

```sh
brew install --cask tinecli/tap/tine
```

Or download `Tine-<version>.dmg` from the [latest release](https://github.com/tinecli/tine/releases/latest) and move `Tine.app` to `/Applications`. Tine is signed and notarized, and updates itself.

## Set up

1. Add the shell integration: `echo 'source ~/.local/share/tine/tine.zsh' >> ~/.zshrc`
2. Open Tine once, so it installs the widget: `open -a Tine`
3. Approve **Tine** in System Settings › Privacy & Security › Accessibility, so the panel can follow your cursor.

<details>
<summary><b>Your own specs</b></summary>

<br>

Each spec location (`~/.config/tine/specs/` by default, add more in Settings) has two folders:

- **`override/<cmd>.js`** replaces a command's spec completely.
- **`extend/<cmd>.js`** merges onto the pack's spec, adding subcommands and options while keeping everything upstream. Good for your own or a company CLI's commands (a missing `aws sso login`, say) without copying the whole 400-file `aws` spec.

For a CLI the pack never covered, `tine learn <cmd>` writes that `extend/<cmd>.js` for you. It runs `<cmd> --help` and turns the output into a spec with Apple's on-device model (Apple Intelligence on, nothing leaves the Mac). The result is a plain file: read it, edit it, delete it. `--force` learns again.

</details>

<details>
<summary><b>How <code>tine ask</code> works</b></summary>

<br>

```sh
tine ask "delete a directory and everything in it"
```

Tine indexes every binary on your `PATH` by its man page's `NAME` line. The index is built on this machine on the first ask and never shipped (`tine index` rebuilds it). The answer is the tools you actually have installed, ranked, with what each one is for. Where a tool's spec is known, the on-device model also composes a command line from the flags that spec documents, parsed against the same spec before you see it, so an invented flag never reaches you.

Nothing is ever run. The command is printed and pushed onto your next prompt, for you to read and run yourself.

</details>

<details>
<summary><b>Building from source</b></summary>

<br>

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Releases are tagged and built by GitHub Actions, see [docs/RELEASING.md](docs/RELEASING.md).

</details>

## Credits and license

Built on the open-source [amazon-q-developer-cli](https://github.com/aws/amazon-q-developer-cli) autocomplete engine and the Fig completion specs. Licensed under MIT and Apache-2.0, see [LICENSE.MIT](LICENSE.MIT), [LICENSE.APACHE](LICENSE.APACHE) and [NOTICE](NOTICE).

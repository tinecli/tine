# Tine

Native macOS terminal autocomplete — a fast SwiftUI suggestion panel driven by the
Fig completion-spec engine. No cloud, no AI, no telemetry, no login, and **no
pseudo-terminal**.

## What it is

- A native, non-activating `NSPanel` + SwiftUI suggestion UI (not a webview).
- The Fig autocomplete engine (1400+ command specs) runs locally in
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
panel can track your cursor. The app is Developer ID signed but not yet notarized, so on
first launch use **right-click → Open** (or approve it in System Settings).

## Requirements

macOS 14+, zsh, and (to build) Swift 6, Node 22 + pnpm.

## Run (dev)

```sh
scripts/dev-run.sh                       # build app + engine, install specs + shell, launch
echo 'source ~/.local/share/tine/tine.zsh' >> ~/.zshrc
```

Then grant **Accessibility** (System Settings → Privacy & Security → Accessibility)
so the panel can track your cursor. For Ghostty, enable the bundled input method
(Settings → Input method → Enable).

## Releasing

Tag a version and push — the `Release` GitHub Action builds the spec pack + app,
packages a dmg (ad-hoc signed), publishes a GitHub Release, and bumps the Homebrew
cask in `gustaferiksson/homebrew-tap`:

```sh
git tag v0.1.1 && git push origin v0.1.1
```

(Set the repo secret `TAP_GITHUB_TOKEN` — a PAT with write access to the tap — for the
cask bump to run.)

To build a dmg locally instead:

```sh
scripts/package.sh                       # → dist/Tine.app + dist/Tine-<version>.dmg
```

`package.sh` Developer ID signs with a hardened runtime + JIT entitlement
(JavaScriptCore needs it); set `TINE_SIGN_ID=-` for an ad-hoc build. Notarization is a
separate step (Apple ID credentials required).

## Configure

Via the Settings window or `~/.config/tine/config.json`: font + size, max rows,
accent, glass, command-name completion, and the local specs directory. Drop your
own `.js` Fig specs in `~/.tine/specs` — they load first and override the pack.

## Credits & license

Built on the open-source
[amazon-q-developer-cli](https://github.com/aws/amazon-q-developer-cli) autocomplete
engine and Fig completion specs. Licensed under MIT **and** Apache-2.0 — see
`LICENSE.MIT`, `LICENSE.APACHE`, and `NOTICE`.

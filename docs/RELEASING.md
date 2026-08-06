# Releasing

Tag a version on `main` and push — the `Release` GitHub Action builds the app,
packages a Developer ID signed + notarized dmg, publishes a GitHub Release, and bumps
the Homebrew cask in `tinecli/homebrew-tap`. The completion pack is not built here; the
app downloads it at runtime from `tinecli/autocomplete`:

```sh
git tag v0.1.1 && git push origin v0.1.1
```

## Repo secrets

| Secret | Purpose |
| --- | --- |
| `APPLE_CERT_P12` | base64 of the exported "Developer ID Application" cert (`.p12`) |
| `APPLE_CERT_PASSWORD` | password used when exporting that `.p12` |
| `NOTARY_APPLE_ID` | Apple ID email for `notarytool` |
| `NOTARY_PASSWORD` | app-specific password for that Apple ID |
| `TAP_GITHUB_TOKEN` | token with write access to the tap (for the cask bump) |

All five are required: the workflow's preflight step fails the run if any is empty, and
the tag must be an ancestor of `main`. The cask's `caveats` block is hand-maintained in
[`tinecli/homebrew-tap`](https://github.com/tinecli/homebrew-tap/blob/main/Casks/tine.rb)
— the workflow only rewrites `version` and `sha256`.

## Building a dmg locally

```sh
scripts/package.sh                       # → dist/Tine.app + dist/Tine-<version>.dmg
```

`package.sh` Developer ID signs with a hardened runtime + JIT entitlement
(JavaScriptCore needs it); set `TINE_SIGN_ID=-` for an ad-hoc build. It notarizes +
staples the app and the dmg too when `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` /
`NOTARY_PASSWORD` are set.

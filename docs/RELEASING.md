# Releasing

Tag a version and push — the `Release` GitHub Action builds the spec pack + app,
packages a Developer ID signed + notarized dmg, publishes a GitHub Release, and bumps
the Homebrew cask in `gustaferiksson/homebrew-tap`:

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
| `TAP_GITHUB_TOKEN` | PAT with write access to the tap (for the cask bump) |

Without the Apple secrets the build falls back to ad-hoc signing (no notarization);
without `TAP_GITHUB_TOKEN` the cask bump is skipped. The cask's `caveats` block is
hand-maintained in the tap — the workflow only rewrites `version` and `sha256`.

## Building a dmg locally

```sh
scripts/package.sh                       # → dist/Tine.app + dist/Tine-<version>.dmg
```

`package.sh` Developer ID signs with a hardened runtime + JIT entitlement
(JavaScriptCore needs it); set `TINE_SIGN_ID=-` for an ad-hoc build. It notarizes +
staples the app and the dmg too when `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` /
`NOTARY_PASSWORD` are set.

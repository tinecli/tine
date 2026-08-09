#!/bin/bash
# Build the tine app, wrap it in a minimal agent .app bundle, and launch it.
# Usage: scripts/dev-run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPDIR="$ROOT/app"
# Separate identity from the released (brew) app: own bundle id → own Accessibility
# grant (no TCC conflict), own display name + menu-bar icon, and own executable
# name so pkill below never touches the production app.
BUNDLE="$ROOT/.build/Tine-dev.app"
# `open` starts the app with a clean environment, so the app can't be pointed at
# another socket from here — it always uses the fixed path tine.zsh defaults to.
SOCK="$HOME/.local/share/tine/tine.sock"

echo "› building"
(cd "$APPDIR" && swift build -c debug)
BIN="$APPDIR/.build/debug/tine"

echo "› bundling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/tine-dev"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tine - development</string>
  <key>CFBundleDisplayName</key><string>Tine - development</string>
  <key>CFBundleExecutable</key><string>tine-dev</string>
  <key>CFBundleIdentifier</key><string>dev.gustaf.tine.dev</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict>
</plist>
PLIST

# Engine + specs into Resources (app loads shims.js/tine-engine.js from there).
echo "› building JS engine"
bash "$ROOT/scripts/build-engine.sh"
mkdir -p "$BUNDLE/Contents/Resources"
cp "$ROOT/icon/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT/app/engine/tine-engine.js" "$BUNDLE/Contents/Resources/"
# tine's built-in specs (tine.js); the completion pack is downloaded at runtime.
cp -R "$ROOT/builtin-specs" "$BUNDLE/Contents/Resources/builtin-specs"
# Keep the sourced shell integration current.
mkdir -p "$HOME/.local/share/tine"
cp "$ROOT/shell/tine.zsh" "$HOME/.local/share/tine/tine.zsh"

# Sign with Developer ID so Accessibility (TCC) trust persists across rebuilds.
# Without a stable signature, macOS re-distrusts the binary every build.
SIGN_ID="${TINE_SIGN_ID:-Developer ID Application: Gustaf Eriksson (82K3YC8HVF)}"
echo "› signing ($SIGN_ID)"
codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"

echo "› stopping any running dev build (leaves the production app alone)"
pkill -x tine-dev 2>/dev/null || true

echo "› socket: $SOCK"
echo "› launching (logs: /tmp/tine.log)"
open -n "$BUNDLE"
echo "done. In your terminal, reload the integration: source ~/.local/share/tine/tine.zsh"

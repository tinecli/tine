#!/usr/bin/env bash
# Build a distributable, Developer ID signed (+ optionally notarized) Tine.app + .dmg.
#   TINE_VERSION=0.1.0 scripts/package.sh [--no-specs]
# Signing: TINE_SIGN_ID="-" → ad-hoc; else Developer ID (default).
# Notarization (skipped unless all three are set): NOTARY_APPLE_ID, NOTARY_TEAM_ID,
# NOTARY_PASSWORD (an app-specific password). Staples the ticket into app + dmg so
# first launch is Gatekeeper-clean even offline.
set -euo pipefail

# Notarize + staple a .app or .dmg, if notary creds are present (else no-op).
notarize() {
  local path="$1" zip
  if [ -z "${NOTARY_APPLE_ID:-}" ] || [ -z "${NOTARY_TEAM_ID:-}" ] || [ -z "${NOTARY_PASSWORD:-}" ]; then
    echo "  (notary creds unset — skipping notarization of $(basename "$path"))"
    return 0
  fi
  echo "› notarize $(basename "$path") — this can take a minute"
  if [[ "$path" == *.app ]]; then
    zip="$(mktemp -d)/$(basename "$path").zip"
    ditto -c -k --keepParent "$path" "$zip"
    xcrun notarytool submit "$zip" --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
    rm -rf "$(dirname "$zip")"
  else
    xcrun notarytool submit "$path" --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  fi
  xcrun stapler staple "$path"
}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPDIR="$ROOT/app"
DIST="$ROOT/dist"
APP="$DIST/Tine.app"
VERSION="${TINE_VERSION:-0.1.0}"
BUILD="${TINE_BUILD:-1}"
SIGN_ID="${TINE_SIGN_ID:-Developer ID Application: Gustaf Eriksson (82K3YC8HVF)}"
BUNDLE_SPECS=1
[ "${1:-}" = "--no-specs" ] && BUNDLE_SPECS=0

echo "› release build"
(cd "$APPDIR" && swift build -c release)
BIN="$APPDIR/.build/release/tine"

echo "› icon + engine"
[ -f "$ROOT/icon/AppIcon.icns" ] || bash "$ROOT/icon/generate-icons.sh"
bash "$ROOT/scripts/build-engine.sh"

echo "› assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/tine"
cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/app/engine/tine-engine.js" "$APP/Contents/Resources/tine-engine.js"
cp "$ROOT/shell/tine.zsh" "$APP/Contents/Resources/tine.zsh"

if [ "$BUNDLE_SPECS" = 1 ] && [ -d "$HOME/.local/share/tine/specs" ]; then
  echo "  bundling spec pack (self-contained)"
  cp -R "$HOME/.local/share/tine/specs" "$APP/Contents/Resources/specs"
elif [ "$BUNDLE_SPECS" = 1 ]; then
  echo "  ⚠ no spec pack at ~/.local/share/tine/specs — run scripts/install-specs.sh first (or --no-specs)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tine</string>
  <key>CFBundleDisplayName</key><string>Tine</string>
  <key>CFBundleExecutable</key><string>tine</string>
  <key>CFBundleIdentifier</key><string>dev.gustaf.tine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>© Gustaf Eriksson. Includes code from amazon-q-developer-cli (MIT/Apache-2.0).</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

# TINE_SIGN_ID="-" → ad-hoc (CI / unsigned dist); else Developer ID (+ timestamp).
if [ "$SIGN_ID" = "-" ]; then
  echo "› ad-hoc sign + hardened runtime (unsigned distribution)"
  codesign --force --options runtime --entitlements "$APPDIR/tine.entitlements" --sign - "$APP"
else
  echo "› sign ($SIGN_ID) + hardened runtime"
  codesign --force --options runtime --timestamp \
    --entitlements "$APPDIR/tine.entitlements" --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -2

# Notarize + staple the app before it goes into the dmg, so the copy dragged to
# /Applications launches cleanly even offline.
notarize "$APP"

echo "› dmg"
DMG="$DIST/Tine-${VERSION}.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Tine.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tine ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Notarize + staple the dmg too (it's what users download from the release).
notarize "$DMG"

echo ""
echo "✅ $APP"
echo "✅ $DMG ($(du -h "$DMG" | cut -f1))"

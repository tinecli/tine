#!/usr/bin/env bash
# Build a distributable, signed (not notarized) Tine.app + .dmg.
# Notarization needs Apple ID creds (task #6) and is done separately.
#   TINE_VERSION=0.1.0 scripts/package.sh [--no-specs]
set -euo pipefail
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

echo "› dmg"
DMG="$DIST/Tine-${VERSION}.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Tine.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tine ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo ""
echo "✅ $APP"
echo "✅ $DMG ($(du -h "$DMG" | cut -f1))"
echo "Not notarized yet — for Gatekeeper-clean distribution, run notarytool with an"
echo "Apple ID + app-specific password (task #6), then: xcrun stapler staple \"$APP\""

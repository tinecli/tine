#!/bin/bash
# Build + install the tine input method (TineInputMethod.app) to
# ~/Library/Input Methods/. After running, enable it in
# System Settings → Keyboard → Input Sources → + → search "tine".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMEDIR="$ROOT/inputmethod"
BUNDLE="$HOME/Library/Input Methods/TineInputMethod.app"
SIGN_ID="${TINE_SIGN_ID:-Developer ID Application: Gustaf Eriksson (82K3YC8HVF)}"

echo "› building input method"
(cd "$IMEDIR" && swift build -c release)
BIN="$IMEDIR/.build/release/TineIME"

echo "› bundling → $BUNDLE"
pkill -x TineIME 2>/dev/null || true
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/TineIME"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tine</string>
  <key>CFBundleDisplayName</key><string>Tine</string>
  <key>CFBundleExecutable</key><string>TineIME</string>
  <key>CFBundleIdentifier</key><string>dev.gustaf.tine.inputmethod</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSBackgroundOnly</key><true/>
  <key>InputMethodConnectionName</key><string>TineIME_1_Connection</string>
  <key>InputMethodServerControllerClass</key><string>TineInputController</string>
  <key>tsInputMethodCharacterRepertoire</key>
  <array><string>Latn</string></array>
  <key>ComponentInputModeDict</key>
  <dict>
    <key>tsVisibleInputModeOrderedArray</key>
    <array><string>dev.gustaf.tine.inputmethod.mode</string></array>
    <key>tsInputModeListKey</key>
    <dict>
      <key>dev.gustaf.tine.inputmethod.mode</key>
      <dict>
        <key>TISInputSourceID</key><string>dev.gustaf.tine.inputmethod.mode</string>
        <key>TISIntendedLanguage</key><string>en</string>
        <key>tsInputModeIsVisibleKey</key><true/>
        <key>tsInputModePrimaryInScriptKey</key><true/>
        <key>tsInputModeScriptKey</key><string>smRoman</string>
        <key>tsInputModeKeyEquivalentModifiersKey</key><integer>0</integer>
        <key>tsInputModeKeyEquivalentKey</key><string></string>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST

# Developer ID + hardened runtime (required for notarization). macOS 26 refuses
# to register an un-notarized input method, so a plain Developer ID signature is
# not enough on its own. Set TINE_SIGN_ID=- to force ad-hoc (won't register on 26).
echo "› signing ($SIGN_ID)"
codesign --force --options runtime --sign "$SIGN_ID" "$BUNDLE"

# Notarize when a keychain credential profile is provided (see scripts/notarize
# setup in the README). Without it, the IME won't register on macOS 26.
if [ -n "${TINE_NOTARY_PROFILE:-}" ]; then
  echo "› notarizing (profile: $TINE_NOTARY_PROFILE) — this can take a minute"
  ZIP="$(mktemp -d)/TineInputMethod.zip"
  ditto -c -k --keepParent "$BUNDLE" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$TINE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$BUNDLE"
  rm -rf "$(dirname "$ZIP")"
else
  echo "⚠ TINE_NOTARY_PROFILE not set — skipping notarization. On macOS 26 the IME"
  echo "  will NOT register until notarized. See README (notarization setup)."
fi

echo ""
echo "Installed. Now:"
echo "  1) bash scripts/enable-ime.sh   (enables it — does NOT change your input source)"
echo "  2) Restart Ghostty so it picks up the input method"
echo "  Ghostty caret tracking should then work without touching your keyboard layout."

#!/bin/bash
# Enable + select the Tine input method without opening System Settings.
# macOS only surfaces a freshly-installed third-party input method after a
# logout/login — run this once after logging back in and it will enable the
# source and make it active (so it can report the caret in Ghostty/VSCode).
set -euo pipefail

open "$HOME/Library/Input Methods/TineInputMethod.app" 2>/dev/null || true
sleep 1

swift - <<'SWIFT'
import Carbon
import Foundation

func strProp(_ s: TISInputSource, _ k: CFString) -> String? {
    guard let p = TISGetInputSourceProperty(s, k) else { return nil }
    return (Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue()) as String
}
func boolProp(_ s: TISInputSource, _ k: CFString) -> Bool {
    guard let p = TISGetInputSourceProperty(s, k) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
}

let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Input Methods/TineInputMethod.app")
_ = TISRegisterInputSource(url as CFURL)
usleep(400_000)

guard let cf = TISCreateInputSourceList(nil, true)?.takeRetainedValue(),
      let list = cf as? [TISInputSource] else { print("no input source list"); exit(1) }

// Enable only — never select. Selecting would hijack the active input source;
// enabling is enough for IME-capable terminals (Ghostty) to query the caret.
var ok = false
for s in list where (strProp(s, kTISPropertyInputSourceID) ?? "").lowercased().contains("tine") {
    if TISEnableInputSource(s) == noErr { ok = true }
}
if ok {
    print("✅ Tine input method enabled (input source unchanged). Restart Ghostty to pick it up.")
} else {
    print("⚠ Tine not registered. It must be notarized first (macOS 26 blocks unnotarized input methods), then re-launched.")
    exit(1)
}
SWIFT

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

var ok = false
for s in list where (strProp(s, kTISPropertyInputSourceID) ?? "").lowercased().contains("tine") {
    _ = TISEnableInputSource(s)
    if boolProp(s, kTISPropertyInputSourceIsSelectCapable) && TISSelectInputSource(s) == noErr { ok = true }
}
if ok {
    print("✅ Tine input method enabled + selected. Caret tracking active in Ghostty/VSCode.")
} else {
    print("⚠ Tine not registered yet. Log out and back in once, then re-run this script.")
    exit(1)
}
SWIFT

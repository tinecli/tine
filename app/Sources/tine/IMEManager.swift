import Carbon
import Foundation

/// Registers/enables/selects the Tine input method via Text Input Sources (TIS),
/// so the user doesn't have to hand-navigate System Settings → Keyboard.
enum IMEManager {
    static let appPath = "\(NSHomeDirectory())/Library/Input Methods/TineInputMethod.app"
    private static let sourceID = "dev.gustaf.tine.inputmethod.mode"
    private static let bundleID = "dev.gustaf.tine.inputmethod"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: appPath) }

    private static func source(id: String) -> TISInputSource? {
        let props = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(props, true)?.takeRetainedValue()
                as? [TISInputSource] else { return nil }
        return list.first
    }

    private static func source() -> TISInputSource? {
        source(id: sourceID) ?? source(id: bundleID)
    }

    static var isEnabled: Bool {
        guard let src = source(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsEnabled)
        else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue() == kCFBooleanTrue
    }

    /// Register (if needed) and enable the input method — but do NOT select it.
    /// Enabling is enough for IME-capable terminals (Ghostty) to route caret
    /// queries to it; selecting would hijack the user's active input source,
    /// which Fig deliberately never did. Returns nil on success, else an error.
    @discardableResult
    static func enable() -> String? {
        guard isInstalled else {
            return "TineInputMethod.app isn't installed yet — run scripts/install-ime.sh."
        }
        // Makes a freshly-installed source visible to TIS without a logout.
        TISRegisterInputSource(URL(fileURLWithPath: appPath) as CFURL)

        guard let src = source() else {
            return "Input method not registered — it must be notarized, then re-launched."
        }
        let e = TISEnableInputSource(src)
        guard e == noErr else { return "Couldn't enable it (error \(e))." }
        return nil
    }
}

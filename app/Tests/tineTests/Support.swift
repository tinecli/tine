import Foundation

/// Fixtures live under a fresh scratch directory per call, never under the
/// user's real ~/.local/share/tine, ~/.config/tine, or ~/.zsh_history.
enum Scratch {
    static func dir(_ name: String) -> String {
        let root = NSTemporaryDirectory()
        precondition(root.hasPrefix("/private/tmp/") || root.hasPrefix("/var/folders/")
                     || root.hasPrefix("/private/var/folders/"),
                     "refusing to run outside /private/tmp or /var/folders: \(root)")
        let dir = root + "tine-tests-\(UUID().uuidString)/\(name)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}

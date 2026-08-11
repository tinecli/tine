import Foundation

/// Fixtures live under a fresh scratch directory per call, never under the
/// user's real ~/.local/share/tine, ~/.config/tine, or ~/.zsh_history.
enum Scratch {
    static func dir(_ name: String) -> String {
        let root = "/private/tmp/tine-tests-\(UUID().uuidString)"
        let dir = root + "/\(name)"
        let permissions = [FileAttributeKey.posixPermissions: NSNumber(value: 0o700)]
        try? FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: false, attributes: permissions)
        try? FileManager.default.setAttributes(permissions, ofItemAtPath: root)
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: permissions)
        try? FileManager.default.setAttributes(permissions, ofItemAtPath: dir)
        return dir
    }
}

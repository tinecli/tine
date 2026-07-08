import Foundation

/// User settings, persisted as ~/.config/tine/config.json (also hand-editable).
struct TineConfig: Codable, Equatable {
    var maxVisibleRows: Int = 12
    var glass: Bool = true          // Liquid Glass vs. a solid panel
    var accentTintName: String = "blue"
    var fontName: String = ""       // "" = system monospaced; else a named font
    var fontSize: Double = 12
    var firstTokenCompletion: Bool = true   // complete bare command names
    var showDetail: Bool = false            // Ctrl+K detail pane visible
    var showMenuBarIcon: Bool = true        // status-bar item visible
    // User's own spec locations. Each holds override/<cmd>.js (replace) and
    // extend/<cmd>.js (merge) subfolders. Default lives under ~/.config/tine,
    // alongside this config; add more (e.g. a team-shared repo) in Settings.
    var localSpecsDirs: [String] = ["\(NSHomeDirectory())/.config/tine/specs"]

    /// The spec dirs with a leading `~` expanded — safe to hand to the file layer.
    var localSpecsDirsExpanded: [String] {
        localSpecsDirs.map { ($0 as NSString).expandingTildeInPath }
    }

    static let path = "\(NSHomeDirectory())/.config/tine/config.json"

    static func load() -> TineConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let cfg = try? JSONDecoder().decode(TineConfig.self, from: data)
        else { return TineConfig() }
        return cfg
    }

    func save() {
        let dir = (Self.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: URL(fileURLWithPath: Self.path))
        }
    }
}

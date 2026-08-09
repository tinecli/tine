import Foundation

/// User settings, persisted as ~/.config/tine/config.json (also hand-editable).
struct TineConfig: Codable, Equatable {
    var maxVisibleRows: Int = 12
    var glass: Bool = true          // Liquid Glass vs. a solid panel
    var fontName: String = ""       // "" = system monospaced; else a named font
    var fontSize: Double = 12
    var firstTokenCompletion: Bool = true   // complete bare command names
    var showDetail: Bool = false            // Ctrl+K detail pane visible
    var showMenuBarIcon: Bool = true        // status-bar item visible
    var openWindowAtStart: Bool = true      // open the dashboard window on launch
    var autoUpdateSpecs: Bool = true        // download a newer spec pack by itself
    var autoUpdateApp: Bool = true          // false = only tell the user about releases
    var updateNotifications: Bool = true    // notify about installed/available updates
    // User's own spec locations. Each holds override/<cmd>.js (replace) and
    // extend/<cmd>.js (merge) subfolders. Default lives under ~/.config/tine,
    // alongside this config; add more (e.g. a team-shared repo) in Settings.
    var localSpecsDirs: [String] = ["\(NSHomeDirectory())/.config/tine/specs"]

    /// The spec dirs with a leading `~` expanded — safe to hand to the file layer.
    var localSpecsDirsExpanded: [String] {
        localSpecsDirs.map { ($0 as NSString).expandingTildeInPath }
    }

    init() {}

    /// Decoded key by key: a config written by an older tine is missing whatever
    /// keys were added since, and the synthesized decoder would throw on the first
    /// one — silently resetting every setting the user does have.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = TineConfig()
        maxVisibleRows = value(.maxVisibleRows, d.maxVisibleRows)
        glass = value(.glass, d.glass)
        fontName = value(.fontName, d.fontName)
        fontSize = value(.fontSize, d.fontSize)
        firstTokenCompletion = value(.firstTokenCompletion, d.firstTokenCompletion)
        showDetail = value(.showDetail, d.showDetail)
        showMenuBarIcon = value(.showMenuBarIcon, d.showMenuBarIcon)
        openWindowAtStart = value(.openWindowAtStart, d.openWindowAtStart)
        autoUpdateSpecs = value(.autoUpdateSpecs, d.autoUpdateSpecs)
        autoUpdateApp = value(.autoUpdateApp, d.autoUpdateApp)
        updateNotifications = value(.updateNotifications, d.updateNotifications)
        localSpecsDirs = value(.localSpecsDirs, d.localSpecsDirs)
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

import Foundation

struct TineConfig: Codable, Equatable {
    var maxVisibleRows: Int = 12
    var glass: Bool = true          // Liquid Glass, vs. a solid panel
    var fontName: String = ""       // "" = system monospaced; else a named font
    var fontSize: Double = 12
    var firstTokenCompletion: Bool = true
    var showDetail: Bool = false
    var showMenuBarIcon: Bool = true
    var openWindowAtStart: Bool = true
    var autoUpdateSpecs: Bool = true
    /// false still surfaces a newer release (see AppUpdater); it only skips the automatic install.
    var autoUpdateApp: Bool = true
    var updateNotifications: Bool = true
    /// Each dir holds override/<cmd>.js (replace) and extend/<cmd>.js (merge) subfolders.
    var localSpecsDirs: [String] = ["\(NSHomeDirectory())/.config/tine/specs"]

    var localSpecsDirsExpanded: [String] {
        localSpecsDirs.map { ($0 as NSString).expandingTildeInPath }
    }

    init() {}

    /// Decoded key by key so a config from an older tine (missing newer keys) falls back
    /// to defaults per-key instead of the synthesized decoder throwing and losing the file.
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

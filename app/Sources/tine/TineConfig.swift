import Foundation

enum PaneTint: String, Codable, CaseIterable, Identifiable {
    case auto, dark, light
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .dark: return "Always dark"
        case .light: return "Always light"
        }
    }
}

enum UpdateChannel: String, Codable, CaseIterable, Identifiable {
    case stable, alpha
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stable: return "Stable"
        case .alpha: return "Alpha"
        }
    }
}

enum CompletionSource: String, Codable, CaseIterable, Identifiable {
    case fig, carapace, carapaceOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fig: return "Fig specs"
        case .carapace: return "carapace first"
        case .carapaceOnly: return "carapace only"
        }
    }
}

struct TineConfig: Codable, Equatable {
    var maxVisibleRows: Int = 12
    var glass: Bool = true
    var paneTint: PaneTint = .auto
    var fontName: String = ""       // "" = system monospaced; else a named font
    var fontSize: Double = 12
    var firstTokenCompletion: Bool = true
    var showDetail: Bool = false
    var showMenuBarIcon: Bool = true
    var openWindowAtStart: Bool = true
    var autoUpdateSpecs: Bool = true
    var autoUpdateApp: Bool = true
    var updateNotifications: Bool = true
    var updateChannel: UpdateChannel = .stable
    var completionSource: CompletionSource = .carapace
    var localSpecsDirs: [String] = ["\(NSHomeDirectory())/.config/tine/specs"]

    var localSpecsDirsExpanded: [String] {
        localSpecsDirs.map { ($0 as NSString).expandingTildeInPath }
    }

    var effectiveCompletionSource: CompletionSource {
        AppUpdater.isAlphaBuild ? completionSource : .fig
    }

    init() {}

    /// Per-key, not synthesized: the synthesized decoder throws on a missing key and resets every setting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = TineConfig()
        maxVisibleRows = value(.maxVisibleRows, d.maxVisibleRows)
        glass = value(.glass, d.glass)
        paneTint = value(.paneTint, d.paneTint)
        fontName = value(.fontName, d.fontName)
        fontSize = value(.fontSize, d.fontSize)
        firstTokenCompletion = value(.firstTokenCompletion, d.firstTokenCompletion)
        showDetail = value(.showDetail, d.showDetail)
        showMenuBarIcon = value(.showMenuBarIcon, d.showMenuBarIcon)
        openWindowAtStart = value(.openWindowAtStart, d.openWindowAtStart)
        autoUpdateSpecs = value(.autoUpdateSpecs, d.autoUpdateSpecs)
        autoUpdateApp = value(.autoUpdateApp, d.autoUpdateApp)
        updateNotifications = value(.updateNotifications, d.updateNotifications)
        updateChannel = value(.updateChannel, d.updateChannel)
        completionSource = value(.completionSource, d.completionSource)
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

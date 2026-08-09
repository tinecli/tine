import Foundation

/// Ranks suggestions by how often and how recently the user used a command's
/// subcommands/flags. The index is `[rawCommand: [param: Use]]`, blended by the
/// engine's sorting.ts. Bootstrapped from ~/.zsh_history and extended with live
/// picks persisted to ~/.local/share/tine/frecency.json.
final class Frecency {
    /// One param's usage. Decodes the older store format — a bare timestamp — as a
    /// single use, so an existing frecency.json still loads.
    struct Use: Codable {
        var count: Int
        var lastUsed: Double

        init(count: Int = 1, lastUsed: Double) {
            self.count = count
            self.lastUsed = lastUsed
        }

        init(from decoder: Decoder) throws {
            if let lastUsed = try? decoder.singleValueContainer().decode(Double.self) {
                self.init(lastUsed: lastUsed)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(count: try c.decode(Int.self, forKey: .count),
                      lastUsed: try c.decode(Double.self, forKey: .lastUsed))
        }

        func merged(with other: Use) -> Use {
            Use(count: max(count, other.count), lastUsed: max(lastUsed, other.lastUsed))
        }
    }

    static let storePath = "\(NSHomeDirectory())/.local/share/tine/frecency.json"
    private static let historyPath = "\(NSHomeDirectory())/.zsh_history"
    private static let maxHistoryLines = 8000

    /// history ∪ live — fed to the engine as globalThis.__tineFrecency.
    private(set) var index: [String: [String: Use]] = [:]
    /// Only the live picks (persisted); merged over history on load.
    private var live: [String: [String: Use]] = [:]

    func load() {
        index = Self.parseHistory()
        if let data = FileManager.default.contents(atPath: Self.storePath),
           let obj = try? JSONDecoder().decode([String: [String: Use]].self, from: data) {
            live = obj
            for (cmd, params) in live {
                // Live picks re-enter ~/.zsh_history when the shell logs them, so the
                // two counts overlap: take the larger, never their sum.
                for (p, use) in params {
                    index[cmd, default: [:]][p] = index[cmd]?[p]?.merged(with: use) ?? use
                }
            }
        }
    }

    /// Record a pick (cmd = raw first token, param = accepted suggestion name).
    func record(cmd: String, param: String) {
        guard !cmd.isEmpty, !param.isEmpty, !param.contains("↪"), !param.contains(" ") else { return }
        let now = Date().timeIntervalSince1970 * 1000
        Self.bump(&live, cmd, param, now)
        Self.bump(&index, cmd, param, now)
        persistLive()
    }

    private static func bump(_ idx: inout [String: [String: Use]],
                             _ cmd: String, _ param: String, _ ts: Double) {
        var use = idx[cmd]?[param] ?? Use(count: 0, lastUsed: 0)
        use.count += 1
        use.lastUsed = max(use.lastUsed, ts)
        idx[cmd, default: [:]][param] = use
    }

    private func persistLive() {
        let dir = (Self.storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(live) {
            try? data.write(to: URL(fileURLWithPath: Self.storePath))
        }
    }

    /// Keep only subcommand/flag-like tokens; skip paths, URLs, quoted args.
    private static func isRankable(_ t: String) -> Bool {
        if t.isEmpty || t.count > 40 { return false }
        if t.hasPrefix("-") { return t.count > 1 }               // flags
        guard let first = t.first, first.isLetter || first.isNumber else { return false }
        return t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private static func parseHistory() -> [String: [String: Use]] {
        let raw = (try? String(contentsOfFile: historyPath, encoding: .utf8))
            ?? String(data: FileManager.default.contents(atPath: historyPath) ?? Data(), encoding: .ascii)
        guard let raw else { return [:] }

        var lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.count > maxHistoryLines { lines = Array(lines.suffix(maxHistoryLines)) }

        var idx: [String: [String: Use]] = [:]
        let nowMs = Date().timeIntervalSince1970 * 1000
        for (i, line) in lines.enumerated() {
            var cmd = line
            var ts = nowMs - Double(lines.count - i)            // fallback: preserve order
            // zsh extended history: ": <epoch>:<dur>;<command>"
            if line.hasPrefix(":"), let semi = line.firstIndex(of: ";") {
                let meta = line[line.index(after: line.startIndex)..<semi]
                let parts = meta.split(separator: ":")
                if let epoch = parts.first.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
                    ts = epoch * 1000
                }
                cmd = String(line[line.index(after: semi)...])
            }
            let tokens = cmd.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let root = tokens.first, !root.isEmpty else { continue }
            // cd targets are paths (skipped by isRankable): record the destination's
            // basename + "/" so it matches the folder suggestion names cd produces.
            if root == "cd", let target = tokens.dropFirst().first {
                let base = (target as NSString).lastPathComponent
                if !base.isEmpty, base != "/", base != "-" {
                    bump(&idx, "cd", base + "/", ts)
                }
            }
            for t in tokens.dropFirst() where isRankable(t) {
                bump(&idx, root, t, ts)
            }
        }
        return idx
    }
}

import Foundation

/// Ranks suggestions by how often and how recently the user used a command's
/// subcommands/flags. The index is `[rawCommand: [param: Use]]`, blended by the
/// engine's sorting.ts. Bootstrapped from ~/.zsh_history and extended with live
/// picks persisted to ~/.local/share/tine/frecency.json.
///
/// Both indexes live behind `queue`, and the store is written there a second
/// after the last pick, so accepting a suggestion never waits on the disk.
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
    /// Live picks kept in the store; past this the least recently used go.
    private static let maxLiveEntries = 5000
    /// Values kept per (command, flag); past this the least frecent go.
    private static let maxValuesPerKey = 20
    private static let writeDelay = 1.0
    private static let halfLifeMs = 7.0 * 24 * 60 * 60 * 1000

    private let queue = DispatchQueue(label: "tine.frecency", qos: .utility)
    /// history ∪ live — fed to the engine as globalThis.__tineFrecency.
    private var merged: [String: [String: Use]] = [:]
    /// Only the live picks (persisted); merged over history on load.
    private var live: [String: [String: Use]] = [:]
    /// Argument values from history, keyed [cmd: [precedingFlag: [value: Use]]],
    /// where "" is the positional pool. Never persisted: the shell logs the same
    /// lines again, and a value is likelier than a flag to carry something private.
    private var values: [String: [String: [String: Use]]] = [:]
    private var pendingWrite: DispatchWorkItem?
    /// Guards the store against a write scheduled before `load` read it.
    private var loaded = false

    var index: [String: [String: Use]] { queue.sync { merged } }
    var valueIndex: [String: [String: [String: Use]]] { queue.sync { values } }

    func load() {
        let history = Self.parseHistory()
        let stored = Self.readStore()
        queue.sync {
            Self.merge(stored, into: &live)
            pruneLive()
            var idx = history.params
            // Live picks re-enter ~/.zsh_history when the shell logs them, so the
            // two counts overlap: take the larger, never their sum.
            Self.merge(live, into: &idx)
            merged = idx
            values = history.values
            loaded = true
        }
    }

    /// Record a pick (cmd = raw first token, param = accepted suggestion name).
    func record(cmd: String, param: String) {
        guard !cmd.isEmpty, !param.isEmpty, !param.contains("↪"), !param.contains(" ") else { return }
        let now = Date().timeIntervalSince1970 * 1000
        queue.sync {
            Self.bump(&live, cmd, param, now)
            Self.bump(&merged, cmd, param, now)
            scheduleWrite()
        }
    }

    /// Persist a debounced pick before the process goes away (app termination).
    func flush() {
        queue.sync {
            guard pendingWrite != nil else { return }
            pendingWrite?.cancel()
            writeStore()
        }
    }

    private static func bump(_ idx: inout [String: [String: Use]],
                             _ cmd: String, _ param: String, _ ts: Double) {
        var use = idx[cmd]?[param] ?? Use(count: 0, lastUsed: 0)
        use.count += 1
        use.lastUsed = max(use.lastUsed, ts)
        idx[cmd, default: [:]][param] = use
    }

    private static func merge(_ src: [String: [String: Use]],
                              into dst: inout [String: [String: Use]]) {
        for (cmd, params) in src {
            for (p, use) in params {
                dst[cmd, default: [:]][p] = dst[cmd]?[p]?.merged(with: use) ?? use
            }
        }
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeStore() }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + Self.writeDelay, execute: work)
    }

    private func writeStore() {
        pendingWrite = nil
        // Writing before load() read the file would replace the whole store with
        // this session's one pick. Retry instead of dropping it.
        guard loaded else { scheduleWrite(); return }
        pruneLive()
        guard let data = try? JSONEncoder().encode(live) else { return }
        let dir = (Self.storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Self.storePath), options: .atomic)
    }

    /// Cap the store: keep the most recently used picks, drop the rest.
    private func pruneLive() {
        guard live.values.reduce(0, { $0 + $1.count }) > Self.maxLiveEntries else { return }
        let keep = live
            .flatMap { cmd, params in params.map { (cmd: cmd, param: $0.key, use: $0.value) } }
            .sorted { $0.use.lastUsed > $1.use.lastUsed }
            .prefix(Self.maxLiveEntries)
        live = keep.reduce(into: [String: [String: Use]]()) { acc, e in
            acc[e.cmd, default: [:]][e.param] = e.use
        }
    }

    /// An unreadable store moves aside instead of staying in place for the next
    /// write to overwrite, so the user can recover it.
    private static func readStore() -> [String: [String: Use]] {
        guard let data = FileManager.default.contents(atPath: storePath) else { return [:] }
        if let obj = try? JSONDecoder().decode([String: [String: Use]].self, from: data) { return obj }
        let backup = storePath + ".bak"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.moveItem(atPath: storePath, toPath: backup)
        tlog("frecency: unreadable store moved to \(backup)")
        return [:]
    }

    /// Keep only subcommand/flag-like tokens; skip paths, URLs, quoted args.
    private static func isRankable(_ t: String) -> Bool {
        if t.isEmpty || t.count > 40 { return false }
        if t.hasPrefix("-") { return t.count > 1 }               // flags
        guard let first = t.first, first.isLetter || first.isNumber else { return false }
        return t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// The value pool's looser rule: `8080:8080`, `nginx:latest` and `./out` pass,
    /// while quoted, shell-special and credential-shaped tokens never do.
    private static func isValue(_ t: String) -> Bool {
        guard t.count >= 2, t.count <= 80, !t.hasPrefix("-") else { return false }
        guard let first = t.first,
              first.isLetter || first.isNumber || first == "." || first == "/" || first == "~"
        else { return false }
        guard t.allSatisfy({ !$0.isWhitespace && !shellSpecial.contains($0) }) else { return false }
        return !looksSecret(t)
    }

    private static let shellSpecial = Set("\"'`$*?<>|;&(){}[]!\\")
    private static let secretPrefixes = [
        "akia", "asia", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "glpat-", "npm_", "sk-", "sk_", "pk_", "rk_", "xox", "eyj", "aiza",
        "bearer", "-----begin",
    ]
    private static let secretNames = [
        "passwd", "password", "passphrase", "secret", "token", "credential",
        "key", "auth", "session", "cookie", "private", "signature", "salt",
    ]

    /// A flag or `NAME=` whose name says the value next to it is a credential.
    private static func isSecretName(_ name: String) -> Bool {
        let n = name.lowercased()
        return secretNames.contains { n.contains($0) }
    }

    /// Err toward dropping: known credential prefixes, `SECRET=…` shapes and long
    /// high-entropy runs never reach the value pool.
    private static func looksSecret(_ t: String) -> Bool {
        let lower = t.lowercased()
        if secretPrefixes.contains(where: lower.hasPrefix) { return true }
        if let eq = t.firstIndex(of: "="), isSecretName(String(t[..<eq])) { return true }
        return t.split(whereSeparator: { "/:@=,?&".contains($0) }).contains(where: looksHighEntropy)
    }

    private static func looksHighEntropy(_ s: Substring) -> Bool {
        guard s.count >= 20 else { return false }
        if s.allSatisfy({ $0.isHexDigit }) { return true }
        guard s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "_" || $0 == "-" })
        else { return false }
        if s.count >= 32 { return true }
        return s.contains(where: \.isNumber) && s.contains(where: \.isUppercase)
            && s.contains(where: \.isLowercase)
    }

    /// zsh keeps HISTORY_IGNORE matches out of the file; honour it on read too, for
    /// lines written before the user set it. Best effort: the app only sees the
    /// pattern when the shell exports it.
    private static func historyIgnorePatterns() -> [String] {
        let raw = ProcessInfo.processInfo.environment["HISTORY_IGNORE"] ?? ""
        var pattern = raw.trimmingCharacters(in: .whitespaces)
        if pattern.hasPrefix("("), pattern.hasSuffix(")") { pattern = String(pattern.dropFirst().dropLast()) }
        return pattern.isEmpty ? [] : pattern.split(separator: "|").map(String.init)
    }

    private static func bumpValue(_ values: inout [String: [String: [String: Use]]],
                                  _ cmd: String, _ flag: String, _ value: String, _ ts: Double) {
        guard !isSecretName(flag) else { return }
        var use = values[cmd]?[flag]?[value] ?? Use(count: 0, lastUsed: 0)
        use.count += 1
        use.lastUsed = max(use.lastUsed, ts)
        values[cmd, default: [:]][flag, default: [:]][value] = use
    }

    /// Record each value under the flag before it, so `-p` and `-e` never mix.
    /// `--flag=value` splits, and a bare word with no flag before it is left out:
    /// in that slot it is nearly always a subcommand the spec already suggests.
    private static func recordValues(_ values: inout [String: [String: [String: Use]]],
                                     _ cmd: String, _ tokens: [String], _ ts: Double) {
        var flag = ""
        for t in tokens.dropFirst() {
            guard t.hasPrefix("-") else {
                if isValue(t), !flag.isEmpty || !isRankable(t) {
                    bumpValue(&values, cmd, flag, t, ts)
                }
                flag = ""
                continue
            }
            guard let eq = t.firstIndex(of: "=") else { flag = t; continue }
            let value = String(t[t.index(after: eq)...])
            if isValue(value) { bumpValue(&values, cmd, String(t[..<eq]), value, ts) }
            flag = ""
        }
    }

    private static func score(_ use: Use, _ now: Double) -> Double {
        Double(use.count) * pow(2, -max(0, now - use.lastUsed) / halfLifeMs)
    }

    /// Bound the pool: the most frecent values per (command, flag), the rest go.
    private static func capValues(_ values: [String: [String: [String: Use]]],
                                  _ now: Double) -> [String: [String: [String: Use]]] {
        values.mapValues { flags in
            flags.mapValues { pool in
                guard pool.count > maxValuesPerKey else { return pool }
                let keep = pool.sorted { score($0.value, now) > score($1.value, now) }
                    .prefix(maxValuesPerKey)
                return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
        }
    }

    static func parseHistory(path: String = historyPath)
        -> (params: [String: [String: Use]], values: [String: [String: [String: Use]]]) {
        let raw = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? String(data: FileManager.default.contents(atPath: path) ?? Data(), encoding: .ascii)
        guard let raw else { return ([:], [:]) }

        var lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.count > maxHistoryLines { lines = Array(lines.suffix(maxHistoryLines)) }

        var idx: [String: [String: Use]] = [:]
        var values: [String: [String: [String: Use]]] = [:]
        let ignored = historyIgnorePatterns()
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
            // HIST_IGNORE_SPACE: a leading space means the user hid the line.
            guard !cmd.hasPrefix(" "), !ignored.contains(where: { fnmatch($0, cmd, 0) == 0 })
            else { continue }
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
            recordValues(&values, root, tokens, ts)
        }
        return (idx, capValues(values, nowMs))
    }
}

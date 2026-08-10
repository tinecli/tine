import Foundation

/// Bootstrapped from ~/.zsh_history, extended with live picks persisted to
/// ~/.local/share/tine/frecency.json a second after the last pick (behind `queue`),
/// so accepting a suggestion never waits on the disk.
final class Frecency {
    /// Decodes the older store format — a bare timestamp — as a single use, so an
    /// existing frecency.json still loads.
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
    private static let defaultHistoryPath = "\(NSHomeDirectory())/.zsh_history"
    private static let maxHistoryLines = 8000
    /// Skipped, not truncated: a truncated line could miss the HISTORY_IGNORE
    /// pattern that was meant to cover it.
    private static let maxLineLength = 4096
    private static let maxLiveEntries = 5000
    private static let maxValuesPerKey = 20
    private static let writeDelay = 1.0
    private static let halfLifeMs = 7.0 * 24 * 60 * 60 * 1000

    private let queue = DispatchQueue(label: "tine.frecency", qos: .utility)
    /// history ∪ live — fed to the engine as globalThis.__tineFrecency.
    private var merged: [String: [String: Use]] = [:]
    /// The persisted subset of `merged`: just the live picks, before history is merged in.
    private var live: [String: [String: Use]] = [:]
    /// Resolved only for command-name scoring — the engine's argument ranking keeps raw
    /// keys since it runs in the alias's own context.
    private var aliases: [String: String] = [:]
    /// [cmd: [precedingFlag: [value: Use]]], "" is the positional pool. Never persisted:
    /// the shell re-logs the same lines, and a value is more likely than a flag to be private.
    private var values: [String: [String: [String: Use]]] = [:]
    private var pendingWrite: DispatchWorkItem?
    private var loaded = false
    private var ignore = HistoryIgnore.none
    private let historyPath: String

    init(historyPath: String = Frecency.defaultHistoryPath) {
        self.historyPath = historyPath
    }

    var index: [String: [String: Use]] { queue.sync { merged } }
    var valueIndex: [String: [String: [String: Use]]] { queue.sync { values } }

    func setAliases(_ aliases: [String: String]) {
        queue.sync { self.aliases = aliases }
    }

    func load() {
        let stored = Self.readStore()
        queue.sync {
            Self.merge(stored, into: &live)
            pruneLive()
            loaded = true
            rebuild()
        }
    }

    /// `HISTORY_IGNORE` is an unexported shell parameter, so it arrives over the socket
    /// rather than from the environment. Rebuilding drops now-ignored entries from an
    /// already-loaded pool, in memory only — ~/.zsh_history is never written.
    func setHistoryIgnore(_ pattern: String) -> Bool {
        queue.sync {
            guard pattern != ignore.source else { return false }
            ignore = HistoryIgnore(pattern)
            tlog("history ignore: \(pattern.count) chars, compiled: \(ignore.isCompiled)") // length only — the log is world-readable
            rebuild()
            return true
        }
    }

    private func rebuild() {
        let history = Self.parseHistory(path: historyPath, ignore: ignore)
        var idx = history.params
        // Live picks re-enter ~/.zsh_history once the shell logs them: take the max, not the sum.
        Self.merge(live, into: &idx)
        merged = idx
        values = history.values
    }

    /// Returns the command's params for `JSEngine.setFrecencyCommand` to re-bridge.
    func record(cmd: String, param: String) -> [String: Use]? {
        guard !cmd.isEmpty, !param.isEmpty, !param.contains("↪"), !param.contains(" ") else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        return queue.sync {
            Self.bump(&live, cmd, param, now)
            Self.bump(&merged, cmd, param, now)
            scheduleWrite()
            return merged[cmd]
        }
    }

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
        // Writing before `load` has read the file would replace the whole store with
        // just this session's picks — retry instead of dropping the rest.
        guard loaded else { scheduleWrite(); return }
        pruneLive()
        guard let data = try? JSONEncoder().encode(live) else { return }
        let dir = (Self.storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Self.storePath), options: .atomic)
    }

    /// Keeps the `maxLiveEntries` most recently used picks.
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

    /// Moves an unreadable store aside so the next write doesn't overwrite it — the
    /// user can still recover it from the `.bak` path.
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

    /// Allowlist, not a secret-detector: a value is admitted only if it matches a
    /// known-useful shape (host, path, URL, …) *and* clears the blocklists below.
    /// Recognizing every secret is a losing game; recognizing the few useful grammars
    /// is not. history.ts mirrors these exact rules on the engine side.
    private static func isValue(_ t: String, _ flag: String) -> Bool {
        guard t.count >= 2, t.count <= 80 else { return false }
        guard t.allSatisfy({ !$0.isWhitespace && !shellSpecial.contains($0) }) else { return false }
        guard !isSecretName(flag), !looksSecret(t) else { return false }
        return matchesGrammar(t, flag)
    }

    private static func matchesGrammar(_ t: String, _ flag: String) -> Bool {
        if isPort(t[...]) || isPortMapping(t) { return true }
        if isHost(t) || isHostPort(t) || isUserAtHost(t) { return true }
        if isURL(t) || isPath(t) { return true }
        // Positional-only: `nginx:latest` is an image tag there, but `alice:hunter2`
        // is a password after a flag like `--password`.
        if flag.isEmpty, isNameTag(t) { return true }
        return isAssignment(t, flag)
    }

    private static func isAlnum(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// `[A-Za-z0-9._-]+` — the plain word every other grammar below is built from.
    private static func isWord(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { isAlnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private static func isPort(_ s: Substring) -> Bool {
        !s.isEmpty && s.count <= 5 && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isPortMapping(_ t: String) -> Bool {
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        return (2...3).contains(parts.count) && parts.allSatisfy(isPort)
    }

    private static func isLabel(_ s: Substring) -> Bool {
        guard let first = s.first, let last = s.last, isAlnum(first), isAlnum(last) else {
            return false
        }
        return s.allSatisfy { isAlnum($0) || $0 == "-" }
    }

    /// A bare single label is never a host — that shape is a dictionary password.
    private static func isHost(_ t: String) -> Bool {
        if t == "localhost" { return true }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy(isLabel)
    }

    private static func isHostPort(_ t: String) -> Bool {
        guard let colon = t.lastIndex(of: ":"), colon != t.startIndex else { return false }
        return isHost(String(t[..<colon])) && isPort(t[t.index(after: colon)...])
    }

    private static func isUserAtHost(_ t: String) -> Bool {
        let parts = t.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, isWord(parts[0]) else { return false }
        let host = String(parts[1])
        return isHost(host) || isHostPort(host)
    }

    /// Rejects an authority with userinfo — `postgres://user:pass@host/db` carries a password.
    private static func isURL(_ t: String) -> Bool {
        guard let mark = t.range(of: "://") else { return false }
        let scheme = t[..<mark.lowerBound]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        guard scheme.allSatisfy({ isAlnum($0) || $0 == "+" || $0 == "." || $0 == "-" })
        else { return false }
        let rest = t[mark.upperBound...]
        let authority = rest.prefix(while: { $0 != "/" })
        return !authority.isEmpty && !authority.contains("@")
    }

    /// Anchored only — a bare relative path is indistinguishable from a plain word.
    private static func isPath(_ t: String) -> Bool {
        guard t.hasPrefix("/") || t.hasPrefix("./") || t.hasPrefix("../") || t.hasPrefix("~/")
        else { return false }
        return t.split(separator: "/").allSatisfy { $0 == "~" || isWord($0) }
    }

    private static func isNameTag(_ t: String) -> Bool {
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy(isWord)
    }

    private static func isAssignment(_ t: String, _ flag: String) -> Bool {
        guard let eq = t.firstIndex(of: "="), eq != t.startIndex else { return false }
        let name = t[..<eq]
        let rest = String(t[t.index(after: eq)...])
        guard isWord(name), !isSecretName(String(name)) else { return false }
        if matchesGrammar(rest, flag) { return true }
        return isWord(rest[...]) && !looksHighEntropy(rest[...])
    }

    private static let shellSpecial = Set("\"'`$*?<>|;&(){}[]!\\")
    private static let secretPrefixes = [
        "akia", "asia", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "glpat-", "npm_", "sk-", "sk_", "pk_", "rk_", "xox", "eyj", "aiza",
        "bearer", "-----begin",
    ]
    private static let secretNames = [
        "pass", "passwd", "password", "passphrase", "pwd", "secret", "token",
        "credential", "key", "auth", "session", "cookie", "private", "signature",
        "salt",
    ]

    private static func isSecretName(_ name: String) -> Bool {
        let n = name.lowercased()
        return secretNames.contains { n.contains($0) }
    }

    /// Errs toward dropping: known credential prefixes, `SECRET=…` shapes, and long
    /// high-entropy runs are all blocked.
    private static func looksSecret(_ t: String) -> Bool {
        let lower = t.lowercased()
        if secretPrefixes.contains(where: lower.hasPrefix) { return true }
        if let eq = t.firstIndex(of: "="), isSecretName(String(t[..<eq])) { return true }
        return t.split(whereSeparator: { "/:@=,?&".contains($0) }).contains(where: looksHighEntropy)
    }

    /// The length rule alone skips anything dotted (real hostnames are long and dotted),
    /// but mixed-case still catches a secret wearing a hostname's clothes, e.g.
    /// `aB3dEfGh.iJkLmNoPqRs7`.
    private static func looksHighEntropy(_ s: Substring) -> Bool {
        guard s.count >= 20 else { return false }
        if s.allSatisfy({ $0.isHexDigit }) { return true }
        guard s.allSatisfy({
            isAlnum($0) || $0 == "+" || $0 == "_" || $0 == "-" || $0 == "."
        }) else { return false }
        if s.count >= 32, !s.contains(".") { return true }
        return s.contains(where: \.isNumber) && s.contains(where: \.isUppercase)
            && s.contains(where: \.isLowercase)
    }

    private static func bumpValue(_ values: inout [String: [String: [String: Use]]],
                                  _ cmd: String, _ flag: String, _ value: String, _ ts: Double) {
        guard !isSecretName(flag) else { return }
        var use = values[cmd]?[flag]?[value] ?? Use(count: 0, lastUsed: 0)
        use.count += 1
        use.lastUsed = max(use.lastUsed, ts)
        values[cmd, default: [:]][flag, default: [:]][value] = use
    }

    /// Rejects `-pHunter2`, `-La`, `--x[1]` — each has swallowed its own value, so
    /// neither it nor the token after it can be trusted as a flag/value pair.
    private static func isPoolKey(_ t: String) -> Bool {
        if t.hasPrefix("--") {
            let name = t.dropFirst(2)
            guard let first = name.first, isAlnum(first) else { return false }
            return name.allSatisfy { isAlnum($0) || $0 == "-" }
        }
        let name = t.dropFirst()
        return name.count == 1 && isAlnum(name[name.startIndex])
    }

    /// Keyed by the flag immediately before each value, so `-p` and `-e` never mix;
    /// a value with no preceding flag goes to the "" pool.
    private static func recordValues(_ values: inout [String: [String: [String: Use]]],
                                     _ cmd: String, _ tokens: [String], _ ts: Double) {
        var flag = ""
        var unrecordable = false
        for t in tokens.dropFirst() {
            guard t.hasPrefix("-") else {
                if !unrecordable, isValue(t, flag) { bumpValue(&values, cmd, flag, t, ts) }
                flag = ""
                unrecordable = false
                continue
            }
            flag = ""
            guard let eq = t.firstIndex(of: "=") else {
                unrecordable = !isPoolKey(t)
                flag = unrecordable ? "" : t
                continue
            }
            unrecordable = false
            let key = String(t[..<eq])
            let value = String(t[t.index(after: eq)...])
            if isPoolKey(key), isValue(value, key) { bumpValue(&values, cmd, key, value, ts) }
        }
    }

    private static func score(_ use: Use, _ now: Double) -> Double {
        Double(use.count) * pow(2, -max(0, now - use.lastUsed) / halfLifeMs)
    }

    /// Resolves the snapshot once; the returned closure then runs once per corpus hit.
    func commandScorer() -> (String) -> Double {
        let snapshot = queue.sync { (merged, aliases) }
        let now = Date().timeIntervalSince1970 * 1000
        let scores = Self.commandScores(in: snapshot.0, aliases: snapshot.1, now: now)
        return { scores[$0] ?? 0 }
    }

    static func commandScore(for name: String, in index: [String: [String: Use]],
                             aliases: [String: String] = [:], now: Double) -> Double {
        commandScores(in: index, aliases: aliases, now: now)[name] ?? 0
    }

    /// Resolves basenames, aliases, and command prefixes (`sudo`, `env`, assignments)
    /// down to a PATH command name while building the map.
    private static func commandScores(in index: [String: [String: Use]],
                                      aliases: [String: String], now: Double) -> [String: Double] {
        var scores: [String: Double] = [:]
        for (rawCommand, uses) in index {
            let name = resolvedCommandName(rawCommand, aliases: aliases)
            scores[name] = max(scores[name] ?? 0, commandScore(uses, now: now))
            guard isCommandPrefix(rawCommand) else { continue }
            for (token, use) in uses {
                let name = resolvedCommandName(token, aliases: aliases)
                scores[name] = max(scores[name] ?? 0, score(use, now))
            }
        }
        return scores
    }

    private static func commandScore(_ uses: [String: Use], now: Double) -> Double {
        uses.values.map { score($0, now) }.max() ?? 0
    }

    private static func resolvedCommandName(_ raw: String, aliases: [String: String],
                                            depth: Int = 0) -> String {
        let name = (raw as NSString).lastPathComponent
        guard depth < 4, let value = aliases[name] else { return name }
        let unquoted: String
        if value.count >= 2, value.first == value.last,
           value.first == "'" || value.first == "\"" {
            unquoted = String(value.dropFirst().dropLast())
        } else {
            unquoted = value
        }
        let tokens = unquoted.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let command = firstCommand(in: tokens) else { return name }
        return resolvedCommandName(command, aliases: aliases, depth: depth + 1)
    }

    private static func firstCommand(in tokens: [String]) -> String? {
        for token in tokens {
            let name = (token as NSString).lastPathComponent
            if isEnvironmentAssignment(token) || name == "sudo" || name == "env" { continue }
            if token.hasPrefix("-") { continue }
            return token
        }
        return nil
    }

    private static func isCommandPrefix(_ raw: String) -> Bool {
        let name = (raw as NSString).lastPathComponent
        return name == "sudo" || name == "env" || isEnvironmentAssignment(raw)
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[..<equals]
        guard let first = name.first, first == "_" || first.isASCII && first.isLetter else {
            return false
        }
        return name.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Keeps the `maxValuesPerKey` most frecent values per (command, flag).
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

    static func parseHistory(path: String = defaultHistoryPath, ignore: HistoryIgnore = .none)
        -> (params: [String: [String: Use]], values: [String: [String: [String: Use]]]) {
        let raw = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? String(data: FileManager.default.contents(atPath: path) ?? Data(), encoding: .ascii)
        guard let raw else { return ([:], [:]) }

        var lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.count > maxHistoryLines { lines = Array(lines.suffix(maxHistoryLines)) }

        var idx: [String: [String: Use]] = [:]
        var values: [String: [String: [String: Use]]] = [:]
        let nowMs = Date().timeIntervalSince1970 * 1000
        for (i, line) in lines.enumerated() where line.count <= maxLineLength {
            var cmd = line
            var ts = nowMs - Double(lines.count - i)            // fallback: preserve order
            // zsh extended history format: ": <epoch>:<dur>;<command>"
            if line.hasPrefix(":"), let semi = line.firstIndex(of: ";") {
                let meta = line[line.index(after: line.startIndex)..<semi]
                let parts = meta.split(separator: ":")
                if let epoch = parts.first.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
                    ts = epoch * 1000
                }
                cmd = String(line[line.index(after: semi)...])
            }
            guard !cmd.hasPrefix(" "), !ignore.matches(cmd) else { continue } // HIST_IGNORE_SPACE
            let tokens = cmd.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let root = tokens.first, !root.isEmpty else { continue }
            // isRankable skips paths, so cd's target is recorded separately, as the
            // basename + "/" shape the folder-suggestion names use.
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

/// Translates one zsh `HISTORY_IGNORE` pattern (matched whole-line) to a regex, compiled
/// once. Applying it on read, not just relying on zsh's own write-time filtering, covers
/// lines written before the user set the pattern.
///
/// Handled: `*`, `?`, `[…]` (`!`/`^` negation, ranges, `[:class:]`), `(…|…)` alternation
/// at any depth, top-level `|`, `\` escapes, and numeric ranges `<->`/`<n-m>` (bounds
/// dropped — `<1-9>` over-matches every digit run, the safe direction for an exclusion).
/// Not handled: extendedglob (`#`, `##`, `^`, `~`, `(#i)`) — such a pattern then matches
/// no line, so it fails open and that history stays visible rather than silently hidden.
struct HistoryIgnore {
    static let none = HistoryIgnore("")

    let source: String
    private let regex: NSRegularExpression?

    var isCompiled: Bool { regex != nil }

    init(_ pattern: String) {
        source = pattern
        regex = Self.compile(pattern)
    }

    func matches(_ line: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        var out = "\\A(?:"
        var depth = 0
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            i = pattern.index(after: i)
            switch c {
            case "\\":
                guard i < pattern.endIndex else { out += "\\\\"; break }
                out += quote(pattern[i])
                i = pattern.index(after: i)
            // Collapses runs: `**` must not become a nested quantifier the regex
            // engine can backtrack on forever.
            case "*":
                while i < pattern.endIndex, pattern[i] == "*" { i = pattern.index(after: i) }
                out += ".*"
            case "?": out += "."
            case "(": out += "(?:"; depth += 1
            case ")":
                guard depth > 0 else { return nil }
                out += ")"
                depth -= 1
            case "|": out += "|"
            case "[":
                guard let (cls, next) = charClass(pattern, i) else { return nil }
                out += cls
                i = next
            case "<":
                guard let next = numericRange(pattern, i) else { out += quote(c); break }
                out += "[0-9]+"
                i = next
            default: out += quote(c)
            }
        }
        guard depth == 0 else { return nil }
        return try? NSRegularExpression(pattern: out + ")\\z")
    }

    private static func quote(_ c: Character) -> String {
        NSRegularExpression.escapedPattern(for: String(c))
    }

    /// `a<b` and `a<1-b` are literal in zsh too — only the exact `<n-m>` shape (both
    /// bounds optional) is a range.
    private static func numericRange(_ p: String, _ start: String.Index) -> String.Index? {
        var i = start
        while i < p.endIndex, p[i].isASCII, p[i].isNumber { i = p.index(after: i) }
        guard i < p.endIndex, p[i] == "-" else { return nil }
        i = p.index(after: i)
        while i < p.endIndex, p[i].isASCII, p[i].isNumber { i = p.index(after: i) }
        guard i < p.endIndex, p[i] == ">" else { return nil }
        return p.index(after: i)
    }

    /// nil for an unterminated `[…]` — zsh itself would not treat that as a class either.
    private static func charClass(_ p: String, _ start: String.Index)
        -> (String, String.Index)? {
        var i = start
        var out = "["
        if i < p.endIndex, p[i] == "!" || p[i] == "^" {
            out += "^"
            i = p.index(after: i)
        }
        if i < p.endIndex, p[i] == "]" {
            out += "\\]"
            i = p.index(after: i)
        }
        while i < p.endIndex {
            let c = p[i]
            i = p.index(after: i)
            if c == "]" { return (out + "]", i) }
            // [:alpha:]-style classes pass through whole; any other `[` is a literal.
            if c == "[", i < p.endIndex, p[i] == ":",
               let end = p.range(of: ":]", range: i..<p.endIndex) {
                out += "[" + p[i..<end.upperBound]
                i = end.upperBound
                continue
            }
            if c == "\\", i < p.endIndex {
                out += "\\" + String(p[i])
                i = p.index(after: i)
                continue
            }
            // `-` stays bare so ranges survive; escaping a letter would spell a regex
            // class like `\d` or `\a`, so only characters meaningful to `[...]` itself are escaped.
            out += setSyntax.contains(c) ? "\\" + String(c) : String(c)
        }
        return nil
    }

    private static let setSyntax: Set<Character> = ["\\", "]", "[", "&", "^", "{", "}"]
}

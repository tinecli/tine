import Foundation

struct AskEntry: Codable, Equatable {
    let name: String
    let description: String
    let manPagePath: String

    init(name: String, description: String, manPagePath: String = "") {
        self.name = name
        self.description = description
        self.manPagePath = manPagePath
    }
}

enum AskIndex {
    struct Stored: Codable {
        let signature: String
        let builtAt: Date
        let entries: [AskEntry]
    }

    /// Tests must set `TINE_DATA_DIR`, or they read/write the real ~/.local/share/tine.
    static var dir: String {
        ProcessInfo.processInfo.environment["TINE_DATA_DIR"]
            ?? "\(NSHomeDirectory())/.local/share/tine"
    }

    static var path: String { "\(dir)/ask-index.json" }

    static func load() -> Stored? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func needsRebuild(_ stored: Stored?, signature: String) -> Bool {
        guard let stored else { return true }
        return stored.signature != signature || stored.entries.isEmpty
    }

    static func save(_ stored: Stored) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(stored).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Weakening this (e.g. dropping mtimes) makes the index cache never invalidate.
    static func signature(pathDirs: [String]) -> String {
        let parts = pathDirs.map { dir -> String in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir)
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(dir)@\(Int(modified))"
        }
        return parts.joined(separator: ":")
    }

    static let maxEntries = 8000

    static func packDescriptions(in packDir: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: "\(packDir)/index.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["descriptions"] as? [String: Any]
        else { return [:] }
        return raw.compactMapValues { $0 as? String }
    }

    /// Blocking — call off the main thread, or a full index build freezes the UI.
    static func build(shellPath: String, packDescriptions: [String: String]) -> Stored {
        let dirs = pathDirs(shellPath)
        let pages = manPages(in: manDirs(pathDirs: dirs))
        var entries: [AskEntry] = []
        for name in binaries(in: dirs).prefix(maxEntries) {
            let manPagePath = pages[name] ?? ""
            let described = nameLine(inManPageAt: manPagePath) ?? packDescriptions[name] ?? ""
            entries.append(AskEntry(name: name,
                                    description: description(described, of: name),
                                    manPagePath: manPagePath))
        }
        return Stored(signature: signature(pathDirs: dirs), builtAt: Date(), entries: entries)
    }

    static func pathDirs(_ shellPath: String) -> [String] {
        var seen = Set<String>()
        return shellPath.split(separator: ":").map(String.init).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    /// Keep first-hit-wins — matches shell PATH shadowing; last-hit-wins picks the wrong binary.
    static func binaries(in dirs: [String]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for dir in dirs {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in contents.sorted() where isToolName(name) {
                // isExecutableFile is true for directories too — filtered out below.
                var isDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: "\(dir)/\(name)", isDirectory: &isDir)
                guard !isDir.boolValue,
                      FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)"),
                      seen.insert(name).inserted else { continue }
                names.append(name)
            }
        }
        return names
    }

    static func isToolName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64
            && name.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]*$", options: .regularExpression) != nil
    }

    static func manDirs(pathDirs: [String]) -> [String] {
        var seen = Set<String>()
        var dirs: [String] = []
        for bin in pathDirs {
            let parent = (bin as NSString).deletingLastPathComponent
            for candidate in ["\(parent)/share/man", "\(parent)/man"] {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
                      isDir.boolValue, seen.insert(candidate).inserted else { continue }
                dirs.append(candidate)
            }
        }
        return dirs
    }

    private static let sections = ["man1", "man6", "man8"]

    /// `.gz` pages must stay skipped — tine has no gunzip and would show garbled text.
    static func manPages(in manDirs: [String]) -> [String: String] {
        var paths: [String: String] = [:]
        for manDir in manDirs {
            for section in sections {
                let dir = "\(manDir)/\(section)"
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                for file in files where !file.hasSuffix(".gz") {
                    let stem = (file as NSString).deletingPathExtension
                    if paths[stem] == nil { paths[stem] = "\(dir)/\(file)" }
                }
            }
        }
        return paths
    }

    private static let maxPageBytes = 128 * 1024

    static func nameLine(inManPageAt path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return manPage(at: path).flatMap(nameLine(inManPage:))
    }

    static func examples(inManPageAt path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return manPage(at: path).flatMap(examples(inManPage:))
    }

    private static func manPage(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxPageBytes), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Must stay unroffed below — this is untrusted local content, never display it raw.
    static func nameLine(inManPage source: String) -> String? {
        guard let section = section(named: ["NAME"], in: source, maxLines: 12) else { return nil }
        var parts: [String] = []
        for line in section.map(String.init) {
            if line.hasPrefix(".Nm") { parts.append(after(".Nm", line)); continue }
            if line.hasPrefix(".Nd") { parts.append("- " + after(".Nd", line)); continue }
            if line.hasPrefix(".") || line.hasPrefix("'") { continue }
            parts.append(line)
        }
        let text = unroff(parts.joined(separator: " "))
        return text.isEmpty ? nil : text
    }

    private static func after(_ macro: String, _ line: String) -> String {
        String(line.dropFirst(macro.count)).trimmingCharacters(in: .whitespaces)
    }

    static func examples(inManPage source: String) -> String? {
        guard let lines = section(named: ["EXAMPLE", "EXAMPLES"], in: source, maxLines: 80)
        else { return nil }
        let text = lines.compactMap { line -> String? in
            if line.hasPrefix(".\\\"") || line.hasPrefix(".\"") { return nil }
            guard line.hasPrefix(".") || line.hasPrefix("'") else { return String(line) }
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            return fields.count == 2 ? String(fields[1]) : nil
        }.joined(separator: " ")
        let cleaned = unroff(text, limit: maxExamples)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static let maxExamples = 1200

    private static func section(named names: Set<String>, in source: String,
                                maxLines: Int) -> [Substring]? {
        var found = false
        var section: [Substring] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if !found {
                found = names.contains(headingName(line))
                continue
            }
            if isHeading(line) { return section }
            section.append(line)
            if section.count >= maxLines { return section }
        }
        return found ? section : nil
    }

    private static func isHeading(_ line: Substring) -> Bool {
        line.hasPrefix(".SH") || line.hasPrefix(".Sh") || line.hasPrefix(".SS")
    }

    private static func headingName(_ line: Substring) -> String {
        guard isHeading(line) else { return "" }
        let raw = line.drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)
        let first = raw.split(whereSeparator: \.isWhitespace).first ?? ""
        return first.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).uppercased()
    }

    static func unroff(_ raw: String, limit: Int = maxDescription) -> String {
        var out = ""
        var iterator = raw.startIndex
        while iterator < raw.endIndex {
            let char = raw[iterator]
            guard char == "\\" else {
                out.append(char.isNewline || char == "\t" ? " " : char)
                iterator = raw.index(after: iterator)
                continue
            }
            let next = raw.index(after: iterator)
            guard next < raw.endIndex else { break }
            switch raw[next] {
            case "-": out.append("-")
            case " ": out.append(" ")
            case "e": out.append("\\")
            case "f", "s":  // font/size change: \fB, \f(CW, \s-1
                iterator = skipArgument(raw, from: raw.index(after: next))
                continue
            case "(":       // two-letter glyph: \(em
                iterator = raw.index(next, offsetBy: 3, limitedBy: raw.endIndex) ?? raw.endIndex
                continue
            default: break
            }
            iterator = raw.index(after: next)
        }
        let collapsed = out.split(separator: " ").joined(separator: " ")
        return String(collapsed.prefix(limit))
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    }

    private static func skipArgument(_ raw: String, from index: String.Index) -> String.Index {
        guard index < raw.endIndex else { return index }
        if raw[index] == "(" {
            return raw.index(index, offsetBy: 3, limitedBy: raw.endIndex) ?? raw.endIndex
        }
        if raw[index] == "+" || raw[index] == "-" {
            let after = raw.index(after: index)
            return after < raw.endIndex ? raw.index(after: after) : raw.endIndex
        }
        return raw.index(after: index)
    }

    static let maxDescription = 180

    static func description(_ raw: String, of name: String) -> String {
        var text = raw
        if let dash = text.range(of: " - "), text[..<dash.lowerBound].count <= name.count + 24,
           !text[..<dash.lowerBound].contains(" ") || text.hasPrefix(name) {
            text = String(text[dash.upperBound...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—,:"))
        let words = terms(text).filter { $0 != name.lowercased() && !filler.contains($0) }
        return words.isEmpty ? "" : String(text.prefix(maxDescription))
    }

    private static let filler: Set<String> = ["documentation", "manual", "man", "page", "utility"]

    struct Hit {
        let entry: AskEntry
        let score: Double
    }

    static func rank(_ query: String, in entries: [AskEntry], limit: Int,
                     frecency: (String) -> Double = { _ in 0 }) -> [Hit] {
        let queryTerms = weighted(terms(query).filter { !stopwords.contains($0) })
        guard !queryTerms.isEmpty else { return [] }

        let documents = entries.map { terms($0.name) + terms($0.description) }
        var frequency: [String: Int] = [:]
        for document in documents {
            for term in Set(document) { frequency[term, default: 0] += 1 }
        }
        let count = Double(entries.count)
        let averageLength = documents.reduce(0.0) { $0 + Double($1.count) } / max(count, 1)
        func inverseFrequency(_ term: String) -> Double {
            let documents = Double(frequency[term] ?? 0)
            return log(1 + (count - documents + 0.5) / (documents + 0.5))
        }

        var hits: [Hit] = []
        for (index, entry) in entries.enumerated() {
            let document = documents[index]
            let nameTerms = Set(terms(entry.name))
            var score = 0.0
            for (term, weight) in queryTerms {
                let occurrences = Double(document.filter { $0 == term }.count)
                    + (nameTerms.contains(term) ? nameWeight : 0)
                if occurrences > 0 {
                    let length = Double(document.count)
                    score += weight * inverseFrequency(term) * (occurrences * (k1 + 1))
                        / (occurrences + k1 * (1 - b + b * length / max(averageLength, 1)))
                } else if term.count >= 3, entry.name.lowercased().contains(term) {
                    score += weight * inverseFrequency(term) * partialNameWeight
                }
            }
            if score > 0 {
                let used = frecency(entry.name)
                score *= 1 + min(log1p(used) * frecencyWeight, maxFrecencyBonus)
                hits.append(Hit(entry: entry, score: score))
            }
        }
        let ranked = hits.sorted { ($0.score, $1.entry.name) > ($1.score, $0.entry.name) }
        return Array(prune(ranked).prefix(limit))
    }

    private static let k1 = 1.2
    private static let b = 0.6
    private static let nameWeight = 2.0
    private static let partialNameWeight = 1.2
    private static let synonymWeight = 0.6
    private static let frecencyWeight = 0.25
    private static let maxFrecencyBonus = 1.0

    static func weighted(_ queryTerms: [String]) -> [String: Double] {
        var weights: [String: Double] = [:]
        for term in queryTerms { weights[term] = 1 }
        for term in queryTerms {
            for synonym in synonyms[term] ?? [] where weights[synonym] == nil {
                weights[synonym] = synonymWeight
            }
        }
        return weights
    }

    private static let synonyms: [String: [String]] = [
        "delete": ["remove", "erase", "unlink"],
        "remove": ["delete", "erase"],
        "search": ["find", "grep", "match"],
        "find": ["search", "locate"],
        "folder": ["directory"],
        "directory": ["folder"],
        "photo": ["image", "picture"],
        "picture": ["image", "photo"],
        "image": ["picture", "photo"],
        "jpg": ["jpeg", "jpe"],
        "jpeg": ["jpg", "jpe"],
        "jpe": ["jpg", "jpeg"],
        "tif": ["tiff"],
        "tiff": ["tif"],
        "compress": ["archive", "compression", "zip"],
        "archive": ["compress", "tar", "zip"],
        "rename": ["move"],
        "download": ["fetch", "retrieve", "transfer"],
        "convert": ["transform", "encode"],
        "monitor": ["watch", "report"],
        "csv": ["delimited", "comma"],
    ]

    private static func prune(_ ranked: [Hit]) -> [Hit] {
        let names = Set(ranked.map { $0.entry.name })
        var shown = Set<String>()
        return ranked.filter { hit in
            if let base = versionlessName(hit.entry.name), names.contains(base) { return false }
            return hit.entry.description.isEmpty || shown.insert(hit.entry.description).inserted
        }
    }

    static func versionlessName(_ name: String) -> String? {
        guard let range = name.range(of: "[0-9]+(\\.[0-9]+)*$", options: .regularExpression),
              range.lowerBound != name.startIndex else { return nil }
        let stripped = String(name[..<range.lowerBound])
        return stripped.isEmpty ? nil : stripped
    }

    static func terms(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { singular(String($0)) }
            .filter { $0.count >= 2 }
    }

    private static func singular(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("es"), !word.hasSuffix("ses") {
            return String(word.dropLast(2))
        }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") {
            return String(word.dropLast())
        }
        return word
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "that", "with", "from", "into", "how", "can", "use", "using",
        "are", "cli", "tool", "command", "line", "get", "make", "run", "program", "some",
        "this", "what", "which", "when", "you", "your", "way", "want", "need", "all", "any",
        "let", "does", "doe", "give", "show", "have", "has", "its", "it", "on", "in", "of",
        "to", "at", "by", "or", "an", "is", "be", "do", "my", "me", "as",
    ]
}

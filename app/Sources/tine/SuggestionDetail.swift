import Foundation

enum SuggestionDetail {
    private static let detailContentLineCount =
        1 // title
        + 1 // type / danger
        + 1 // usage
        + 1 // man NAME
        + 1 // description
        + 1 // inserted value
        + 1 // spec-report action
        + 1 // keyboard footer

    static func panelHeight(rows: Int, config: TineConfig) -> CGFloat {
        let visible = min(max(rows, 1), max(1, config.maxVisibleRows))
        let lineHeight = CGFloat(config.fontSize) + 12
        let rowsHeight = lineHeight * CGFloat(visible) + 8
        guard config.showDetail else { return rowsHeight }
        let detailHeight = lineHeight * CGFloat(detailContentLineCount) + 8
        return max(rowsHeight, detailHeight)
    }

    static func firstToken(in buffer: String, cursor: Int) -> String? {
        let characters = Array(buffer)
        guard cursor >= 0, cursor <= characters.count else { return nil }
        let prefix = characters[..<cursor]
        let tokens = prefix.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = tokens.first else { return nil }
        return String(first)
    }

    static func isFirstTokenRow(buffer: String, cursor: Int) -> Bool {
        let characters = Array(buffer)
        guard cursor >= 0, cursor <= characters.count else { return false }
        let prefix = characters[..<cursor]
        return !prefix.isEmpty && !prefix.contains(where: { $0 == " " || $0 == "\t" })
    }

    static func use(in snapshot: Frecency.Index, command: String,
                    suggestion: String) -> Frecency.Use? {
        snapshot[command]?[suggestion]
    }

    static func usageLine(for use: Frecency.Use, relativeTo now: Date = Date(),
                          locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        let usedAt = Date(timeIntervalSince1970: use.lastUsed / 1000)
        let relative = formatter.localizedString(for: usedAt, relativeTo: now)
        return "used \(use.count) \(use.count == 1 ? "time" : "times"), \(relative)"
    }

    static func manNames(from entries: [AskEntry]) -> [String: String] {
        entries.reduce(into: [:]) { names, entry in
            if names[entry.name] == nil, !entry.description.isEmpty {
                names[entry.name] = entry.description
            }
        }
    }

    static func manName(in snapshot: [String: String], suggestion: String,
                        isFirstTokenRow: Bool) -> String? {
        guard isFirstTokenRow else { return nil }
        return snapshot[suggestion]
    }

    static func issueURL(cli: String, item: String, specName: String,
                         renderedSuggestion: String, version: String) -> URL? {
        guard !cli.isEmpty, !item.isEmpty, !specName.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/tinecli/autocomplete/issues/new"
        let subject = cli == item ? cli : "\(cli) \(item)"
        components.queryItems = [
            URLQueryItem(name: "title", value: "Spec wrong: \(subject)"),
            URLQueryItem(
                name: "body",
                value: "Spec: \(specName)\nRendered suggestion: \(renderedSuggestion)\nTine version: \(version)"
            ),
        ]
        return components.url
    }
}

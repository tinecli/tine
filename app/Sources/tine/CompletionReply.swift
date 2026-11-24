import Foundation

/// Every offset is in UTF-16 code units of the buffer.
struct CompletionReply: Encodable {
    struct Edit: Encodable {
        let start: Int
        let end: Int
        let text: String
        let cursor: Int
    }

    struct Item: Encodable {
        let name: String
        let description: String
        let kind: String
        let dangerous: Bool
        let matches: [Int]
        let edit: Edit
    }

    let version = 1
    let pending: Bool
    let items: [Item]

    init(engine: JSEngine?, buffer: String, cursor: Int, cwd: String) {
        let clamped = min(max(cursor, 0), buffer.utf16.count)
        let suggestions = engine?.suggest(line: buffer, cursor: clamped, cwd: cwd) ?? []
        pending = CommandRunner.isLoading

        items = suggestions.compactMap { suggestion in
            guard suggestion.type != "auto-execute", suggestion.type != "learn-it" else { return nil }
            let start = clamped - suggestion.queryTerm.utf16.count
            guard start >= 0 else { return nil }

            var text = suggestion.insertValue + (suggestion.shouldAddSpace ? " " : "")
            var cursorOffset = text.utf16.count
            if let range = text.range(of: "{cursor}") {
                cursorOffset = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
                text.removeSubrange(range)
            }

            return Item(
                name: suggestion.name,
                description: suggestion.description,
                kind: suggestion.type,
                dangerous: suggestion.isDangerous,
                matches: suggestion.matchIndices,
                edit: Edit(start: start, end: clamped, text: text, cursor: start + cursorOffset)
            )
        }
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8) else {
            return #"{"version":1,"pending":false,"items":[]}"#
        }
        return string
    }
}

import SwiftUI

final class AppState: ObservableObject {
    @Published var buffer = ""
    @Published var cursor = 0
    @Published var cwd = ""
    @Published var suggestions: [Suggestion] = []
    @Published var selectedIndex = 0
    @Published var isLoading = false
    @Published var config = TineConfig.load() {
        didSet {
            guard persists else { return }
            config.save()
            engine?.setFirstTokenEnabled(config.firstTokenCompletion)
        }
    }

    /// The Appearance preview mirrors live config and must never write it back.
    private let persists: Bool

    init(persists: Bool = true) {
        self.persists = persists
    }

    var engine: JSEngine?

    var hasSuggestions: Bool { !suggestions.isEmpty }

    var hasContent: Bool { hasSuggestions || isLoading }

    var selectedIsExecute: Bool {
        suggestions.indices.contains(selectedIndex) && suggestions[selectedIndex].isExecute
    }

    var selectedName: String? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex].name : nil
    }

    var selectedType: String? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex].type : nil
    }

    /// A redraw after a nav key re-sends the same buffer: the early-return below skips
    /// resetting `selectedIndex`, which would otherwise snap the highlight back to the
    /// top and jump the panel on every arrow press.
    @discardableResult
    func update(_ msg: FeedMessage) -> Bool {
        if msg.buffer == buffer && msg.cursor == cursor && msg.cwd == cwd { return false }
        buffer = msg.buffer
        cursor = msg.cursor
        cwd = msg.cwd
        suggestions = engine?.suggest(line: msg.buffer, cursor: msg.cursor, cwd: msg.cwd) ?? []
        selectedIndex = 0
        isLoading = CommandRunner.isLoading
        return true
    }

    /// Unlike `update`, runs even when the buffer hasn't changed — for when a
    /// background generator finishes and its results need to appear regardless.
    @discardableResult
    func recompute() -> Bool {
        guard !buffer.isEmpty else { return false }
        let items = engine?.suggest(line: buffer, cursor: cursor, cwd: cwd) ?? []
        let changed = items.count != suggestions.count
        suggestions = items
        if selectedIndex >= suggestions.count { selectedIndex = 0 }
        isLoading = CommandRunner.isLoading
        return changed
    }

    /// Fig's Tab behavior: the longest common prefix of the visible suggestions, if longer
    /// than what's typed.
    func commonPrefix() -> (buffer: String, cursor: Int)? {
        // An auto-execute row's name ("↪", or the bare exact match) would shrink the
        // prefix and make Tab fall through to shell completion, so it's excluded.
        // insertValue is used, not name, since it's already shell-escaped for paths
        // (e.g. `Edge\ Apps.localized/`).
        let values = suggestions.filter { !$0.isExecute && $0.type != "learn-it" }.map { $0.insertValue }
        guard let first = values.first else { return nil }
        var lcp = Array(first)
        for name in values.dropFirst() {
            let n = Array(name)
            var i = 0
            while i < lcp.count, i < n.count, lcp[i] == n[i] { i += 1 }
            lcp = Array(lcp.prefix(i))
            if lcp.isEmpty { break }
        }
        let prefix = String(lcp)
        // qt (not the whole typed token) is what gets replaced below — otherwise
        // `cd app/So` + `Sources/` would wrongly become `cd Sources/`.
        guard let qt = suggestions.first(where: { !$0.isExecute && $0.type != "learn-it" })?.queryTerm else { return nil }
        guard prefix.count > qt.count, prefix.hasPrefix(qt) else { return nil }

        let chars = Array(buffer)
        let start = max(0, cursor - qt.count)
        guard start <= chars.count, cursor <= chars.count else { return nil }
        let newBuffer = String(chars[0..<start]) + prefix + String(chars[cursor...])
        return (newBuffer, start + prefix.count)
    }

    func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), suggestions.count - 1)
    }

    func accept() -> (buffer: String, cursor: Int)? {
        guard suggestions.indices.contains(selectedIndex) else { return nil }
        let selected = suggestions[selectedIndex]
        if selected.type == "learn-it" {
            return (selected.insertValue, selected.insertValue.count)
        }
        let chars = Array(buffer)
        // queryTerm may legitimately be empty right after a "/" — that means append
        // at the cursor rather than replace anything.
        let start = max(0, cursor - selected.queryTerm.count)
        guard start <= chars.count, cursor <= chars.count else { return nil }

        // Fig's insertion.ts rule: shouldAddSpace appends a space, and a {cursor}
        // placeholder is resolved after that so the space still ends up last.
        var insert = selected.insertValue
        if selected.shouldAddSpace { insert += " " }

        var cursorOffset = insert.count
        if let r = insert.range(of: "{cursor}") {
            cursorOffset = insert.distance(from: insert.startIndex, to: r.lowerBound)
            insert.removeSubrange(r)
        }

        let head = String(chars[0..<start])
        let tail = String(chars[cursor...])
        let newBuffer = head + insert + tail
        let newCursor = start + cursorOffset
        return (newBuffer, newCursor)
    }
}

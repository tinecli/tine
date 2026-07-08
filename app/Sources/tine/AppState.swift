import SwiftUI

/// Shared UI state. Suggestions come from the JS engine (Fig specs via JSC).
final class AppState: ObservableObject {
    @Published var buffer = ""
    @Published var cursor = 0
    @Published var cwd = ""
    @Published var suggestions: [Suggestion] = []
    @Published var selectedIndex = 0
    /// A generator subprocess is still running for the current buffer (e.g. `git
    /// checkout ` fetching branches). Shows a spinner instead of an empty pane.
    @Published var isLoading = false
    @Published var config = TineConfig.load() {
        didSet {
            config.save()
            engine?.setFirstTokenEnabled(config.firstTokenCompletion)
        }
    }

    private var searchTerm = ""
    var engine: JSEngine?

    var hasSuggestions: Bool { !suggestions.isEmpty }

    /// The panel should be visible when there's something to show — suggestions,
    /// or a spinner while a generator is still running.
    var hasContent: Bool { hasSuggestions || isLoading }

    /// True when the highlighted row is Fig's "auto-execute" (run the line as-is).
    var selectedIsExecute: Bool {
        suggestions.indices.contains(selectedIndex) && suggestions[selectedIndex].isExecute
    }

    /// Name of the highlighted suggestion (for frecency recording).
    var selectedName: String? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex].name : nil
    }

    /// Returns true if the buffer actually changed (so the caller repositions the
    /// panel). A redraw after a nav key re-sends the same buffer — recomputing or
    /// resetting the selection then would snap the highlight to the top and make
    /// the panel jump as the caret is re-queried.
    @discardableResult
    func update(_ msg: FeedMessage) -> Bool {
        if msg.buffer == buffer && msg.cursor == cursor { return false }
        buffer = msg.buffer
        cursor = msg.cursor
        cwd = msg.cwd
        let result = engine?.suggest(line: msg.buffer, cursor: msg.cursor, cwd: msg.cwd)
        suggestions = result?.items ?? []
        searchTerm = result?.searchTerm ?? ""
        selectedIndex = 0
        isLoading = CommandRunner.isLoading
        return true
    }

    /// Recompute suggestions for the current buffer without the change guard —
    /// used when a background generator finishes and we want its results to appear
    /// even though the buffer didn't change. Returns true if the set changed.
    @discardableResult
    func recompute() -> Bool {
        guard !buffer.isEmpty else { return false }
        let result = engine?.suggest(line: buffer, cursor: cursor, cwd: cwd)
        let items = result?.items ?? []
        let changed = items.count != suggestions.count
        suggestions = items
        searchTerm = result?.searchTerm ?? ""
        if selectedIndex >= suggestions.count { selectedIndex = 0 }
        isLoading = CommandRunner.isLoading
        return changed
    }

    /// Fig's Tab: insert the longest common prefix of the visible suggestions,
    /// if it extends past what's typed. Returns new (buffer, cursor) or nil.
    func commonPrefix() -> (buffer: String, cursor: Int)? {
        // Exclude auto-execute rows — their names ("↪", or the bare exact match)
        // would shrink the prefix and make Tab fall through to shell completion.
        // Use insertValue (already shell-escaped for paths) so Tab inserts e.g.
        // `Edge\ Apps.localized/`, not an unescaped space.
        let values = suggestions.filter { !$0.isExecute }.map { $0.insertValue }
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
        // Replace the per-suggestion query term (basename for paths), not the whole
        // token — otherwise `cd app/So` + Sources/ becomes `cd Sources/`.
        guard let qt = suggestions.first(where: { !$0.isExecute })?.queryTerm else { return nil }
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

    /// Apply the selected suggestion: replace the current search term with the
    /// suggestion's insertValue. Returns the new (buffer, cursor), or nil.
    func accept() -> (buffer: String, cursor: Int)? {
        guard suggestions.indices.contains(selectedIndex) else { return nil }
        let selected = suggestions[selectedIndex]
        let chars = Array(buffer)
        // Replace only this suggestion's query term (basename for path suggestions;
        // may legitimately be empty right after a "/", meaning append at the cursor).
        let start = max(0, cursor - selected.queryTerm.count)
        guard start <= chars.count, cursor <= chars.count else { return nil }

        // Fig's rule (insertion.ts): append a space when shouldAddSpace is set;
        // a {cursor} placeholder is resolved afterwards (so the space still lands
        // at the end, cursor goes to the placeholder).
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

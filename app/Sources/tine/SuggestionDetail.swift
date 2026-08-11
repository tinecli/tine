import AppKit
import SwiftUI

enum SuggestionDetail {
    static let width: CGFloat = 260

    struct Content {
        let title: String?
        let type: String
        let isDangerous: Bool
        let isExecute: Bool
        let description: String
        let insertValue: String
        let usageLine: String?
        let manName: String?
        let issueURL: URL?

        static let empty = Content(
            title: nil, type: "", isDangerous: false, isExecute: false,
            description: "", insertValue: "", usageLine: nil, manName: nil,
            issueURL: nil)
    }

    @MainActor
    static func panelHeight(rows: Int, config: TineConfig,
                            content: Content = .empty) -> CGFloat {
        let visible = min(max(rows, 1), max(1, config.maxVisibleRows))
        let lineHeight = CGFloat(config.fontSize) + 12
        let rowsHeight = lineHeight * CGFloat(visible) + 8
        guard config.showDetail else { return rowsHeight }

        let detail = SuggestionDetailView(
            content: content, fontSize: CGFloat(config.fontSize)
        )
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: detail)
        renderer.proposedSize = ProposedViewSize(
            width: width, height: nil)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return rowsHeight }
        let detailHeight = CGFloat(image.height)
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
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

struct SuggestionDetailView: View {
    let content: SuggestionDetail.Content
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = content.title {
                Text(content.isExecute ? "Run" : title)
                    .font(.system(
                        size: fontSize + 1, weight: .semibold, design: .monospaced))
                    .lineLimit(2)
                    .foregroundStyle(content.isDangerous ? .red : .primary)
                HStack(spacing: 6) {
                    if !content.type.isEmpty {
                        Text(content.type)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if content.isDangerous {
                        Label("dangerous", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
                if let usageLine = content.usageLine {
                    Text(usageLine)
                        .font(.system(size: max(9, fontSize - 2)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let manName = content.manName {
                    Text("man  \(manName)")
                        .font(.system(size: max(9, fontSize - 2)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !content.description.isEmpty {
                    Text(content.description)
                        .font(.system(size: max(10, fontSize - 1)))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !content.isExecute && !content.insertValue.isEmpty {
                    Text("inserts  \(content.insertValue)")
                        .font(.system(
                            size: max(9, fontSize - 2), design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let issueURL = content.issueURL {
                    Button {
                        NSWorkspace.shared.open(issueURL)
                    } label: {
                        Label("Spec wrong?", systemImage: "exclamationmark.bubble")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: max(9, fontSize - 2)))
                    .foregroundStyle(.tint)
                }
            } else {
                Text("No selection")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("↑↓ move · ↩ accept · ⇥ prefix · esc close · ⌃K hide")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

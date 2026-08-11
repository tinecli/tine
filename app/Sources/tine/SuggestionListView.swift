import AppKit
import SwiftUI

struct SuggestionListView: View {
    @EnvironmentObject var state: AppState
    @State private var topID: Int?

    private var maxRows: Int { max(1, state.config.maxVisibleRows) }

    private var fontSize: CGFloat { CGFloat(state.config.fontSize) }
    private var rowHeight: CGFloat { fontSize + 12 }
    private var rowFont: Font {
        state.config.fontName.isEmpty
            ? .system(size: fontSize, design: .monospaced)
            : .custom(state.config.fontName, size: fontSize)
    }

    private var tint: Color { .accentColor }

    private func keepVisible(_ sel: Int) {
        let top = topID ?? 0
        if sel < top {
            topID = sel
        } else if sel > top + maxRows - 1 {
            topID = sel - maxRows + 1
        }
    }

    private var list: some View {
        let count = state.suggestions.count
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if count == 0 {
                    loadingRow
                } else {
                    ForEach(Array(state.suggestions.enumerated()), id: \.offset) { i, s in
                        row(index: i, s: s).id(i)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollPosition(id: $topID, anchor: .top)
        .frame(height: rowHeight * CGFloat(min(count == 0 ? 1 : count, maxRows)))
        .padding(.vertical, 4)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if state.isLoading && count > 0 {
                ProgressView().controlSize(.small).scaleEffect(0.6).padding(4)
            }
        }
        .onChange(of: state.selectedIndex) { _, sel in keepVisible(sel) }
        .onChange(of: state.suggestions.count) { _, _ in topID = 0 }
    }

    static let detailWidth = SuggestionDetail.width
    static let listWidth: CGFloat = 520

    static func detailContent(from state: AppState) -> SuggestionDetail.Content {
        guard state.suggestions.indices.contains(state.selectedIndex) else {
            return .empty
        }
        let suggestion = state.suggestions[state.selectedIndex]
        return SuggestionDetail.Content(
            title: suggestion.name,
            type: suggestion.type,
            isDangerous: suggestion.isDangerous,
            isExecute: suggestion.isExecute,
            description: suggestion.description,
            insertValue: suggestion.insertValue,
            usageLine: state.selectedUsageLine,
            manName: state.selectedManName,
            issueURL: state.selectedSpecIssueURL
        )
    }

    @MainActor
    static func panelSize(state: AppState) -> CGSize {
        let config = state.config
        return CGSize(
            width: listWidth + (config.showDetail ? detailWidth : 0),
            height: SuggestionDetail.panelHeight(
                rows: state.suggestions.count,
                config: config,
                content: detailContent(from: state)
            )
        )
    }

    private var content: some View {
        // .top, not the HStack default .center: a taller detail pane must not push the list down.
        HStack(alignment: .top, spacing: 0) {
            list.frame(width: Self.listWidth)
            if state.config.showDetail {
                Divider().overlay(.white.opacity(0.12))
                SuggestionDetailView(
                    content: Self.detailContent(from: state), fontSize: fontSize
                )
                .frame(width: Self.detailWidth)
                .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder var body: some View {
        if state.config.glass {
            // Unlike materialContent below, glassEffect draws its own edge — no border needed.
            GlassEffectContainer {
                content.glassEffect(in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            materialContent
        }
    }

    private var materialContent: some View {
        content
            .background(VisualEffectView(material: .hudWindow))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
    }

    private func icon(for s: Suggestion) -> String {
        switch s.type {
        case "auto-execute": return "return"
        case "folder":       return "folder"
        case "file":         return "doc"
        case "option":       return "minus.circle"
        case "subcommand":   return "chevron.forward.square"
        case "arg":          return "character.cursor.ibeam"
        case "shortcut":     return "bolt"
        case "history":      return "clock.arrow.circlepath"
        case "learn-it":     return "graduationcap"
        default:             return "circle.dotted"
        }
    }

    private func highlighted(_ label: String, _ indices: [Int]) -> Text {
        guard !indices.isEmpty else { return Text(label) }
        let hit = Set(indices)
        let boldFont = rowFont.bold()
        var out = AttributedString("")
        for (i, ch) in Array(label).enumerated() {
            var piece = AttributedString(String(ch))
            if hit.contains(i) { piece.font = boldFont }
            out += piece
        }
        return Text(out)
    }

    private var loadingRow: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 13)
            Text("Loading…").font(rowFont).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(index: Int, s: Suggestion) -> some View {
        let selected = index == state.selectedIndex
        let isNameLabel = !(s.isExecute && s.name == "↪") // "↪" as a name would double up with the row's own icon
        let label = isNameLabel ? s.name : s.description
        let iconName = s.isDangerous ? "exclamationmark.triangle.fill" : icon(for: s)
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 13)
                .foregroundStyle(selected ? .white.opacity(0.9)
                                 : (s.isDangerous ? .red : (s.isExecute ? tint : .secondary)))
            Group {
                if isNameLabel { highlighted(s.name, s.matchIndices) } else { Text(label) }
            }
            .font(rowFont)
            .lineLimit(1)
            .foregroundStyle(selected ? .white : (s.isDangerous ? .red : .primary))
            if !s.description.isEmpty && s.description != label {
                Text(s.description)
                    .font(.system(size: max(9, fontSize - 1)))
                    .foregroundStyle(selected ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(0.85))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
            }
        }
        .foregroundStyle(selected ? .white : .primary)
    }
}

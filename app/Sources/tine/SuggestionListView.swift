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

    // The user's system accent color (System Settings › Appearance).
    private var tint: Color { .accentColor }

    /// Scroll only when the selection crosses an edge of the visible window,
    /// pinning it there — so it can't run off the pane (Finder-style).
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
        // A generator is still running while more suggestions are already showing:
        // a small unobtrusive spinner in the corner (Fig-style).
        .overlay(alignment: .topTrailing) {
            if state.isLoading && count > 0 {
                ProgressView().controlSize(.small).scaleEffect(0.6).padding(4)
            }
        }
        .onChange(of: state.selectedIndex) { _, sel in keepVisible(sel) }
        .onChange(of: state.suggestions.count) { _, _ in topID = 0 }
    }

    static let detailWidth: CGFloat = 260
    static let listWidth: CGFloat = 520

    private var content: some View {
        // Pin to the top: when the detail pane is taller than the list (few rows,
        // long description), the list must stay at the top, not center in the gap.
        HStack(alignment: .top, spacing: 0) {
            list.frame(width: Self.listWidth)
            if state.config.showDetail {
                Divider().overlay(.white.opacity(0.12))
                detail.frame(width: Self.detailWidth)
            }
        }
    }

    @ViewBuilder var body: some View {
        // `glassEffect` only exists in the macOS 26 SDK (Swift 6.2+). Guard at
        // compile time so older SDKs (CI runners) fall back to the material.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), state.config.glass {
            // Apple hosts glass in a container (perf + correct edge/blend rendering);
            // the material draws its own edge, so we add no border of our own.
            GlassEffectContainer {
                content.glassEffect(in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            materialContent
        }
        #else
        materialContent
        #endif
    }

    private var materialContent: some View {
        content
            .background(VisualEffectView(material: .hudWindow))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
    }

    /// Ctrl+K detail column for the selected suggestion (Apple-HUD style).
    @ViewBuilder private var detail: some View {
        let sel = state.suggestions.indices.contains(state.selectedIndex)
            ? state.suggestions[state.selectedIndex] : nil
        VStack(alignment: .leading, spacing: 6) {
            if let s = sel {
                Text(s.isExecute ? "Run" : s.name)
                    .font(.system(size: fontSize + 1, weight: .semibold, design: .monospaced))
                    .lineLimit(2)
                    .foregroundStyle(s.isDangerous ? .red : .primary)
                HStack(spacing: 6) {
                    if !s.type.isEmpty {
                        Text(s.type).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if s.isDangerous {
                        Label("dangerous", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
                if !s.description.isEmpty {
                    Text(s.description)
                        .font(.system(size: max(10, fontSize - 1)))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !s.isExecute && !s.insertValue.isEmpty {
                    Text("inserts  \(s.insertValue)")
                        .font(.system(size: max(9, fontSize - 2), design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(3)
                }
            } else {
                Text("No selection").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        default:             return "circle.dotted"
        }
    }

    /// Name with fuzzy-matched characters bolded (in the configured font).
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

    /// Shown when the pane is empty but a generator is still running (the panel is
    /// only presented with no suggestions while `isLoading`).
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
        // The "↪" auto-execute row's name is itself a glyph — show its label
        // (e.g. "Immediately execute") instead so it doesn't read as two icons.
        let isNameLabel = !(s.isExecute && s.name == "↪")
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

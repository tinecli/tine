import SwiftUI
import Testing

@MainActor
struct SuggestionListViewTests {
    private struct DetailCase {
        let label: String
        let name: String
        let description: String
        let insertValue: String
        let hasMetadata: Bool
    }

    private let cases = [
        DetailCase(
            label: "46-char name",
            name: String(repeating: "wrapped-command", count: 3).prefixString(46),
            description: "Everyday completion description",
            insertValue: "wrapped-command",
            hasMetadata: true
        ),
        DetailCase(
            label: "48-char option",
            name: "--" + String(repeating: "long-option", count: 5).prefixString(46),
            description: "Everyday option description",
            insertValue: "--" + String(repeating: "long-option", count: 5).prefixString(46),
            hasMetadata: true
        ),
        DetailCase(
            label: "102-char description",
            name: "deploy",
            description: String(repeating: "description ", count: 9).prefixString(102),
            insertValue: "deploy",
            hasMetadata: true
        ),
        DetailCase(
            label: "165-char description + long name",
            name: String(repeating: "long-command", count: 5).prefixString(72),
            description: String(repeating: "long description ", count: 11).prefixString(165),
            insertValue: String(repeating: "long-command", count: 5).prefixString(72),
            hasMetadata: true
        ),
        DetailCase(
            label: "300-char adversarial name",
            name: String(repeating: "adversarial-name-", count: 20).prefixString(300),
            description: "Bounded detail",
            insertValue: "adversarial",
            hasMetadata: true
        ),
        DetailCase(
            label: "fresh install",
            name: "status",
            description: "",
            insertValue: "status",
            hasMetadata: false
        ),
    ]

    @Test func detailPanelFitsRenderedContentAcrossEveryAcceptanceCase() throws {
        for detailCase in cases {
            var renderedHeights: [Int] = []
            var panelHeights: [Int] = []
            for fontSize in 10...18 {
                let state = makeState(detailCase, fontSize: fontSize)
                let renderer = ImageRenderer(
                    content: SuggestionListView().environmentObject(state)
                )
                renderer.proposedSize = ProposedViewSize(
                    width: SuggestionListView.listWidth + SuggestionListView.detailWidth,
                    height: nil
                )
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                let requiredHeight = CGFloat(image.height)
                let panelHeight = SuggestionDetail.panelHeight(
                    rows: state.suggestions.count,
                    config: state.config,
                    content: SuggestionListView.detailContent(from: state)
                )
                renderedHeights.append(Int(requiredHeight))
                panelHeights.append(Int(panelHeight))

                #expect(
                    panelHeight >= requiredHeight,
                    "font=\(fontSize), name=\(detailCase.name), panel=\(panelHeight), required=\(requiredHeight)"
                )
                if !detailCase.hasMetadata {
                    #expect(panelHeight < 200, "fresh install should not reserve the old 200pt floor")
                }
            }
            print(
                "RENDER_HEIGHT \(detailCase.label) fonts=10...18 "
                    + "required=\(renderedHeights) panel=\(panelHeights)"
            )
        }
    }

    @Test func hiddenDetailKeepsRowDerivedSizing() {
        var config = TineConfig()
        config.fontSize = 12
        config.maxVisibleRows = 12
        config.showDetail = false

        #expect(SuggestionDetail.panelHeight(rows: 0, config: config) == 32)
        #expect(SuggestionDetail.panelHeight(rows: 2, config: config) == 56)
        #expect(SuggestionDetail.panelHeight(rows: 20, config: config) == 296)
    }

    private func makeState(_ detailCase: DetailCase, fontSize: Int) -> AppState {
        var config = TineConfig()
        config.fontSize = Double(fontSize)
        config.showDetail = true
        config.glass = false

        let state = AppState(persists: false)
        state.config = config
        state.buffer = detailCase.name
        state.cursor = detailCase.name.count
        state.suggestions = [
            Suggestion(
                name: detailCase.name,
                description: detailCase.description,
                insertValue: detailCase.insertValue,
                shouldAddSpace: true,
                type: "subcommand",
                queryTerm: "",
                isDangerous: false,
                matchIndices: [],
                specName: detailCase.hasMetadata ? "git" : ""
            ),
        ]
        if detailCase.hasMetadata {
            state.installFrecencySnapshot([
                detailCase.name: [
                    detailCase.name: Frecency.Use(
                        count: 3, lastUsed: Date().timeIntervalSince1970 * 1000),
                ],
            ])
            state.installManNameSnapshot([detailCase.name: "manual page summary"])
        }
        return state
    }
}

private extension String {
    func prefixString(_ length: Int) -> String {
        String(prefix(length))
    }
}

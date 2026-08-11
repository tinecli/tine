import Foundation
import Testing

struct SuggestionListViewTests {
    @Test func detailPanelFitsEveryContentLineWithOneOrTwoRows() {
        var config = TineConfig()
        config.fontSize = 12
        config.showDetail = true

        let lineHeight = CGFloat(config.fontSize) + 12
        let detailContentLines = 8
        let detailMinimum = lineHeight * CGFloat(detailContentLines) + 8

        #expect(SuggestionDetail.panelHeight(rows: 1, config: config) == detailMinimum)
        #expect(SuggestionDetail.panelHeight(rows: 2, config: config) == detailMinimum)
        #expect(SuggestionDetail.panelHeight(rows: 20, config: config) == 296)
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
}

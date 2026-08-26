import Testing

@MainActor
struct AppStateTests {
    private func learnIt() -> Suggestion {
        Suggestion(
            name: "no spec for `pc` — learn it",
            description: "writes a spec from `pc --help`",
            insertValue: "tine learn pc",
            shouldAddSpace: false,
            type: "learn-it",
            queryTerm: "",
            isDangerous: false,
            matchIndices: []
        )
    }

    private func completion() -> Suggestion {
        Suggestion(
            name: "--verbose",
            description: "",
            insertValue: "--verbose",
            shouldAddSpace: true,
            type: "option",
            queryTerm: "",
            isDangerous: false,
            matchIndices: []
        )
    }

    @Test func theLearnItRowStartsUnselectedAndRealCompletionsDoNot() {
        #expect(AppState.initialSelection(for: [learnIt()]) == -1)
        #expect(AppState.initialSelection(for: [completion()]) == 0)
        #expect(AppState.initialSelection(for: []) == 0)
    }

    @Test func anUnselectedLearnItRowLeavesTheTypedLineAlone() {
        let state = AppState(persists: false)
        state.buffer = "pc bui"
        state.cursor = 6
        state.suggestions = [learnIt()]
        state.selectedIndex = -1

        #expect(state.accept() == nil)
        #expect(state.commonPrefix() == nil)
        #expect(state.selectedName == nil)
    }

    @Test func downReachesTheLearnItRowFromUnselected() {
        let state = AppState(persists: false)
        state.suggestions = [learnIt()]
        state.selectedIndex = -1

        state.moveSelection(1)
        #expect(state.selectedIndex == 0)
        #expect(state.accept()?.buffer == "tine learn pc")
    }
}

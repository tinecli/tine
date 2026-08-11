import Foundation
import Testing

struct SuggestionDetailTests {
    @Test func formatsUsageWithThePlatformRelativeFormatter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let use = Frecency.Use(count: 42, lastUsed: (now.timeIntervalSince1970 - 7200) * 1000)

        #expect(SuggestionDetail.usageLine(
            for: use, relativeTo: now, locale: Locale(identifier: "en_US")
        ) == "used 42 times, 2h ago")
    }

    @Test func formatsASingleUseGrammatically() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let use = Frecency.Use(count: 1, lastUsed: now.timeIntervalSince1970 * 1000)

        #expect(SuggestionDetail.usageLine(
            for: use, relativeTo: now, locale: Locale(identifier: "en_US")
        ) == "used 1 time, now")
    }

    @Test func findsOnlyTheExactCommandSuggestionPairInTheSnapshot() {
        let expected = Frecency.Use(count: 7, lastUsed: 1_700_000_000_000)
        let snapshot: Frecency.Index = [
            "git": ["rebase": expected],
            "docker": ["rebase": Frecency.Use(count: 99, lastUsed: 2)],
        ]

        let found = SuggestionDetail.use(in: snapshot, command: "git", suggestion: "rebase")
        #expect(found?.count == expected.count)
        #expect(found?.lastUsed == expected.lastUsed)
        #expect(SuggestionDetail.use(in: snapshot, command: "git", suggestion: "merge") == nil)
    }

    @Test func snapshotsAskDescriptionsAndLimitsThemToFirstTokenRows() {
        let snapshot = SuggestionDetail.manNames(from: [
            AskEntry(name: "jq", description: "Command-line JSON processor"),
            AskEntry(name: "empty", description: ""),
        ])

        #expect(SuggestionDetail.manName(
            in: snapshot, suggestion: "jq", isFirstTokenRow: true
        ) == "Command-line JSON processor")
        #expect(SuggestionDetail.manName(
            in: snapshot, suggestion: "jq", isFirstTokenRow: false
        ) == nil)
        #expect(snapshot["empty"] == nil)
    }

    @Test func issueURLRoundTripsEveryUntrustedValue() throws {
        let item = "--output&mode#raw\n雪"
        let rendered = "--output&mode#raw\nvalue=å/雪 ? yes"
        let url = try #require(SuggestionDetail.issueURL(
            cli: "tool&co", item: item, specName: "pack#main/雪",
            renderedSuggestion: rendered, version: "0.1.36+dev&dirty"
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var query: [String: String] = [:]
        for queryItem in components.queryItems ?? [] {
            query[queryItem.name] = queryItem.value
        }

        #expect(query["title"] == "Spec wrong: tool&co \(item)")
        #expect(query["body"] == "Spec: pack#main/雪\nRendered suggestion: \(rendered)\nTine version: 0.1.36+dev&dirty")
        #expect(url.absoluteString.contains("%26"))
        #expect(url.absoluteString.contains("%23"))
        #expect(url.absoluteString.contains("%0A"))
        #expect(!url.absoluteString.contains("雪"))
    }

    @Test func firstTokenIssueTitleDoesNotRepeatTheCLI() throws {
        let url = try #require(SuggestionDetail.issueURL(
            cli: "git", item: "git", specName: "git",
            renderedSuggestion: "git", version: "1.0"
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.first(where: { $0.name == "title" })?.value
                == "Spec wrong: git")
    }
}

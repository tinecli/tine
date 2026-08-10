import Testing
import Foundation

/// Ported from the old FrecencyHarness (app/Tests/FrecencyHarness.swift). The
/// matcher expectations are zsh's own answers, generated with
/// `[[ "$line" == ${~pattern} ]]` under `zsh -f`.
struct HistoryIgnoreTests {
    static let oracle: [(String, String, Bool)] = [
        ("(ls|cd)", "ls", true),
        ("(ls|cd)", "rm -rf /", false),
        ("(ls|cd)*", "ls -la", true),      // nested group + `*`: the old split broke here
        ("(ls|cd)*", "cd foo", true),
        ("(ls|cd)*", "clear", false),
        ("ls|cd", "ls", true),             // top-level alternation, no parens
        ("ls|cd", "rm", false),
        ("a\\|b", "a|b", true),            // escaped pipe: one literal, not two branches
        ("a\\|b", "ab", false),
        ("((ls|cd)|x*)", "xls", true),
        ("((ls|cd)|x*)", "yls", false),
        ("* [0-9]", "secret 1", true),
        ("* [0-9]", "secret x", false),
        ("[!bc]oo", "foo", true),
        ("[!bc]oo", "boo", false),
        ("[[:digit:]]*", "9lives", true),
        ("[[:digit:]]*", "alives", false),
        ("ls ?x", "ls  x", true),
        ("ls ?x", "ls x", false),
        ("(ls|cd)(| *)", "ls", true),
        ("(ls|cd)(| *)", "ls -l", true),
        ("**secret**", "my secret here", true),
        ("*.txt", "cat a.txt", true),
        ("*.txt", "cat a.md", false),
        ("git commit*", "git commit -m wip", true),
        ("*--password*", "app --password hunter2", true),
        ("^ls", "rm", false),              // `^` is literal without extendedglob
        ("^ls", "^ls", true),
        ("(#i)LS", "ls", false),
        ("secret<->", "secret123", true),
        ("secret<->", "secretabc", false),
        ("secret<1-9>", "secret5", true),
        ("a<5->", "a7", true),
        ("a<-5>", "a3", true),
        ("a<b", "a<b", true),              // no `-`: a literal `<`, in zsh too
        ("a<b", "ab", false),
        ("a<1-b", "a<1-b", true),
    ]

    @Test(arguments: oracle)
    func zshOracle(_ c: (pattern: String, line: String, want: Bool)) {
        #expect(HistoryIgnore(c.pattern).matches(c.line) == c.want)
    }

    @Test func widenedNumericRangeDropsMore() {
        #expect(HistoryIgnore("secret<1-9>").matches("secret12"))
    }

    static let unsupported: [(String, String)] = [
        ("^ls", "rm"),                     // extendedglob negation (literal here)
        ("(#i)LS*", "ls -la"),             // extendedglob case-insensitive flag
        ("ls##", "lsls"),                  // extendedglob repetition
        ("a[b", "a[b"),                    // zsh: bad pattern
        ("x)", "x)"),                      // unbalanced
    ]

    @Test(arguments: unsupported)
    func unsupportedPatternFiltersNothing(_ c: (pattern: String, line: String)) {
        #expect(!HistoryIgnore(c.pattern).matches(c.line))
    }

    @Test func emptyPatternFiltersNothing() {
        #expect(!HistoryIgnore("").matches("anything"))
    }

    @Test func sourceRoundTrips() {
        #expect(HistoryIgnore("(ls|cd)").source == "(ls|cd)")
    }

    @Test func compiledFlagSetForABalancedPattern() {
        #expect(HistoryIgnore("(ls|cd)").isCompiled)
    }

    @Test func compiledFlagClearForAnUnbalancedPattern() {
        #expect(!HistoryIgnore("x)").isCompiled)
    }
}

/// `Frecency.Use`'s decoder must still read the older store format — a bare
/// timestamp — as a single use, so an existing frecency.json loads unchanged.
struct FrecencyUseTests {
    @Test func decodesTheOlderBareTimestampFormat() throws {
        let use = try JSONDecoder().decode(Frecency.Use.self, from: Data("1700000000.5".utf8))
        #expect(use.count == 1)
        #expect(use.lastUsed == 1700000000.5)
    }

    @Test func decodesTheKeyedFormat() throws {
        let json = #"{"count":3,"lastUsed":1700000000.5}"#
        let use = try JSONDecoder().decode(Frecency.Use.self, from: Data(json.utf8))
        #expect(use.count == 3)
        #expect(use.lastUsed == 1700000000.5)
    }

    @Test func mergedKeepsTheLargerOfEachField() {
        let a = Frecency.Use(count: 5, lastUsed: 100)
        let b = Frecency.Use(count: 2, lastUsed: 200)
        let merged = a.merged(with: b)
        #expect(merged.count == 5)
        #expect(merged.lastUsed == 200)
    }
}

/// Ported from FrecencyHarness's `pool(root:)`. Fixtures live under a fresh
/// scratch directory (never ~/.zsh_history), and the pool is memory-only — the
/// rebuild must never write anything next to the fixture.
struct FrecencyPoolTests {
    static func makeFixture() -> (frecency: Frecency, dir: String) {
        let root = Scratch.dir("frecency-pool")
        let dir = root + "/history"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fixture = dir + "/zsh_history"
        let lines = [
            ": 1700000000:0;docker run -p 8080:8080 nginx",
            ": 1700000010:0;secret-tool store --host db.example.com",
            ": 1700000020:0;ssh alice@host.example.com",
            ": 1700000030:0;deploy --url https://api.example.com/v1",
            ": 1700000040:0;huge " + String(repeating: "x", count: 5000) + " --host over.example.com",
        ]
        try? lines.joined(separator: "\n").write(toFile: fixture, atomically: true, encoding: .utf8)
        return (Frecency(historyPath: fixture, logPath: root + "/tine.log"), dir)
    }

    static func value(_ f: Frecency, _ cmd: String, _ flag: String, _ v: String) -> Bool {
        f.valueIndex[cmd]?[flag]?[v] != nil
    }

    static func param(_ f: Frecency, _ cmd: String, _ p: String) -> Bool {
        f.index[cmd]?[p] != nil
    }

    @Test func firstHistoryIgnoreIsAChange() {
        let (f, _) = Self.makeFixture()
        #expect(f.setHistoryIgnore("zz-no-match"))
    }

    @Test func poolLearnsShapesFromHistory() {
        let (f, _) = Self.makeFixture()
        _ = f.setHistoryIgnore("zz-no-match")
        #expect(Self.value(f, "docker", "-p", "8080:8080"))
        #expect(Self.value(f, "secret-tool", "--host", "db.example.com"))
        #expect(Self.value(f, "ssh", "", "alice@host.example.com"))
        #expect(Self.value(f, "deploy", "--url", "https://api.example.com/v1"))
        #expect(Self.param(f, "docker", "run"))
        #expect(!Self.value(f, "huge", "--host", "over.example.com"), "an over-long line is skipped whole")
    }

    @Test func settingHistoryIgnoreDropsMatchingLines() {
        let (f, _) = Self.makeFixture()
        #expect(f.setHistoryIgnore("(secret-tool*)"))
        #expect(!Self.value(f, "secret-tool", "--host", "db.example.com"))
        #expect(!Self.param(f, "secret-tool", "store"))
        #expect(Self.value(f, "docker", "-p", "8080:8080"), "other lines stay in the pool")
        #expect(!f.setHistoryIgnore("(secret-tool*)"), "re-sending the same pattern is not a change")
    }

    @Test func nestedGroupPatternDropsBothBranches() {
        let (f, _) = Self.makeFixture()
        #expect(f.setHistoryIgnore("(docker|ssh)*"))
        #expect(!Self.value(f, "docker", "-p", "8080:8080"))
        #expect(!Self.value(f, "ssh", "", "alice@host.example.com"))
        #expect(Self.value(f, "secret-tool", "--host", "db.example.com"))
    }

    @Test func numericRangeDropsThePortMappingLine() {
        let (f, _) = Self.makeFixture()
        #expect(f.setHistoryIgnore("*<->:<->*"))
        #expect(!Self.value(f, "docker", "-p", "8080:8080"))
        #expect(Self.value(f, "ssh", "", "alice@host.example.com"))
    }

    @Test func clearingThePatternRestoresEverything() {
        let (f, _) = Self.makeFixture()
        _ = f.setHistoryIgnore("(secret-tool*)")
        #expect(f.setHistoryIgnore(""))
        #expect(Self.value(f, "docker", "-p", "8080:8080"))
        #expect(Self.value(f, "secret-tool", "--host", "db.example.com"))
        #expect(!f.setHistoryIgnore(""), "clearing twice is not a change")
    }

    @Test func rebuildNeverWritesNextToTheFixture() {
        let (f, dir) = Self.makeFixture()
        _ = f.setHistoryIgnore("(secret-tool*)")
        _ = f.setHistoryIgnore("")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        #expect(Set(leftovers) == Set(["zsh_history"]))
    }
}

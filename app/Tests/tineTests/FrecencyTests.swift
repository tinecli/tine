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

struct ProjectFrecencyTests {
    static func resolve(_ frecency: Frecency, cwd: String) async {
        await withCheckedContinuation { continuation in
            frecency.resolveProjectRoot(for: cwd) { _, _ in continuation.resume() }
        }
    }

    static func makeRepo(_ root: String) throws {
        try FileManager.default.createDirectory(
            atPath: root + "/.git", withIntermediateDirectories: true)
    }

    @Test func recordsAndReloadsTheProjectPool() async throws {
        let dir = Scratch.dir("project-frecency")
        let repo = dir + "/repo"
        let cwd = repo + "/Sources/Feature"
        let store = dir + "/frecency.json"
        try FileManager.default.createDirectory(
            atPath: repo + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        let frecency = Frecency(historyPath: dir + "/missing-history", storePath: store)
        frecency.load()
        await Self.resolve(frecency, cwd: cwd)
        let result = frecency.record(cmd: "git", param: "rebase", cwd: cwd)
        #expect(result?.global["rebase"]?.count == 1)
        #expect(result?.scoped?["rebase"]?.count == 1)
        #expect(frecency.scopedIndex(for: cwd)["git"]?["rebase"]?.count == 1)
        frecency.flush()

        let reloaded = Frecency(historyPath: dir + "/missing-history", storePath: store)
        reloaded.load()
        await Self.resolve(reloaded, cwd: cwd)
        #expect(reloaded.index["git"]?["rebase"]?.count == 1)
        #expect(reloaded.scopedIndex(for: cwd)["git"]?["rebase"]?.count == 1)
    }

    @Test func recordOnlyUsesAnAlreadyCachedProjectRoot() async throws {
        let dir = Scratch.dir("project-record-cache-only")
        let repo = dir + "/repo"
        try FileManager.default.createDirectory(
            atPath: repo + "/.git", withIntermediateDirectories: true)

        let frecency = Frecency(
            historyPath: dir + "/missing-history",
            storePath: dir + "/frecency.json")
        frecency.load()
        let beforeResolution = frecency.record(cmd: "git", param: "rebase", cwd: repo)
        #expect(beforeResolution?.global["rebase"]?.count == 1)
        #expect(beforeResolution?.scoped == nil)

        await Self.resolve(frecency, cwd: repo)
        let afterResolution = frecency.record(cmd: "git", param: "rebase", cwd: repo)
        #expect(afterResolution?.global["rebase"]?.count == 2)
        #expect(afterResolution?.scoped?["rebase"]?.count == 1)
    }

    @Test func standardizesCacheKeysAndRefreshesMissingRootsAfterTTL() async throws {
        let dir = Scratch.dir("project-root-cache")
        let repo = dir + "/repo"
        let cwd = repo + "/Sources/Feature"
        try FileManager.default.createDirectory(
            atPath: repo + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        let frecency = Frecency(
            historyPath: dir + "/missing-history",
            storePath: dir + "/frecency.json")
        await Self.resolve(frecency, cwd: cwd)
        #expect(frecency.projectRoot(for: cwd) == repo)
        try FileManager.default.removeItem(atPath: repo + "/.git")
        #expect(frecency.projectRoot(for: cwd + "/") == repo,
                "equivalent standardized paths share one positive cache entry")

        let outside = dir + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let expiring = Frecency(
            historyPath: dir + "/missing-history",
            storePath: dir + "/expiring-frecency.json",
            projectRootMissTTL: 0)
        await Self.resolve(expiring, cwd: outside)
        #expect(expiring.projectRoot(for: outside) == nil)
        try FileManager.default.createDirectory(
            atPath: outside + "/.git", withIntermediateDirectories: true)
        await Self.resolve(expiring, cwd: outside)
        #expect(expiring.projectRoot(for: outside) == outside,
                "an expired negative entry must notice git init")
    }

    @Test func loadsTheFlatStoreFormatWithoutChangingItsScores() throws {
        let dir = Scratch.dir("old-frecency-store")
        let store = dir + "/frecency.json"
        let oldStore = #"{"git":{"checkout":{"count":4,"lastUsed":1700000000000}}}"#
        try oldStore.write(toFile: store, atomically: true, encoding: .utf8)

        let frecency = Frecency(historyPath: dir + "/missing-history", storePath: store)
        frecency.load()
        #expect(frecency.index["git"]?["checkout"]?.count == 4)
        #expect(frecency.index["git"]?["checkout"]?.lastUsed == 1_700_000_000_000)
        #expect(frecency.scopedIndex(for: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store + ".bak"))
    }

    @Test func capsEveryProjectPool() async throws {
        let dir = Scratch.dir("project-frecency-cap")
        let repo = dir + "/repo"
        let store = dir + "/frecency.json"
        try FileManager.default.createDirectory(
            atPath: repo + "/.git", withIntermediateDirectories: true)

        let frecency = Frecency(historyPath: dir + "/missing-history", storePath: store)
        frecency.load()
        await Self.resolve(frecency, cwd: repo)
        for n in 0...5_000 {
            _ = frecency.record(cmd: "tool", param: "p\(n)", cwd: repo)
        }
        frecency.flush()

        let count = frecency.scopedIndex(for: repo).values.reduce(0) { $0 + $1.count }
        #expect(count == 5_000)
    }

    @Test func evictsStaleAndLeastRecentlyUsedProjectPoolsByTheirNewestEntry() async throws {
        let dir = Scratch.dir("project-pool-eviction")
        let store = dir + "/frecency.json"
        let active = dir + "/active"
        let recent = dir + "/recent"
        let older = dir + "/older"
        let stale = dir + "/stale"
        for root in [active, recent, older, stale] { try Self.makeRepo(root) }

        let scoped: [String: Any] = [
            active: ["tool": [
                "ancient": ["count": 1, "lastUsed": 1.0],
                "newest": ["count": 1, "lastUsed": 999_000.0]
            ]],
            recent: ["tool": ["pick": ["count": 1, "lastUsed": 998_000.0]]],
            older: ["tool": ["pick": ["count": 1, "lastUsed": 997_000.0]]],
            stale: ["tool": ["pick": ["count": 1, "lastUsed": 800_000.0]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["global": [:], "scoped": scoped])
        try data.write(to: URL(fileURLWithPath: store))

        let frecency = Frecency(
            historyPath: dir + "/missing-history",
            storePath: store,
            maxProjectPools: 2,
            projectPoolTTL: 100,
            now: { 1_000 })
        frecency.load()
        for root in [active, recent, older, stale] { await Self.resolve(frecency, cwd: root) }

        #expect(frecency.scopedIndex(for: active)["tool"]?["ancient"] != nil,
                "a fresh newest entry keeps the whole active pool")
        #expect(frecency.scopedIndex(for: recent)["tool"]?["pick"] != nil)
        #expect(frecency.scopedIndex(for: older).isEmpty, "the oldest fresh pool loses the LRU race")
        #expect(frecency.scopedIndex(for: stale).isEmpty)
    }

    @Test func symlinkedAndCanonicalWorkingDirectoriesShareOnePool() async throws {
        let dir = Scratch.dir("project-root-symlink")
        let repo = dir + "/repo"
        let cwd = repo + "/Sources"
        let link = dir + "/linked-repo"
        try Self.makeRepo(repo)
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: repo)

        let frecency = Frecency(
            historyPath: dir + "/missing-history",
            storePath: dir + "/frecency.json")
        frecency.load()
        await Self.resolve(frecency, cwd: link + "/Sources")
        _ = frecency.record(cmd: "git", param: "status", cwd: link + "/Sources")
        await Self.resolve(frecency, cwd: cwd)
        let result = frecency.record(cmd: "git", param: "status", cwd: cwd)

        #expect(result?.scoped?["status"]?.count == 2)
        #expect(frecency.projectRoot(for: link + "/Sources") == repo)
    }

    @Test func positiveRootTTLNoticesRemovedGitDirectory() async throws {
        let dir = Scratch.dir("project-root-positive-ttl")
        let repo = dir + "/repo"
        var clock = 1_000.0
        try Self.makeRepo(repo)
        let frecency = Frecency(
            historyPath: dir + "/missing-history",
            storePath: dir + "/frecency.json",
            projectRootTTL: 10,
            now: { clock })

        await Self.resolve(frecency, cwd: repo)
        #expect(frecency.projectRoot(for: repo) == repo)
        try FileManager.default.removeItem(atPath: repo + "/.git")
        clock += 11
        guard frecency.projectRoot(for: repo) == nil else {
            Issue.record("an expired positive entry still reports a deleted repository")
            return
        }
        await Self.resolve(frecency, cwd: repo)
        #expect(frecency.projectRoot(for: repo) == nil)
    }

    @Test func projectRootCacheEvictsItsLeastRecentlyUsedWorkingDirectory() async throws {
        let dir = Scratch.dir("project-root-cache-cap")
        let first = dir + "/first"
        let second = dir + "/second"
        let third = dir + "/third"
        for root in [first, second, third] { try Self.makeRepo(root) }
        let frecency = Frecency(
            historyPath: dir + "/missing-history",
            storePath: dir + "/frecency.json",
            maxProjectRootCacheEntries: 2)

        await Self.resolve(frecency, cwd: first)
        await Self.resolve(frecency, cwd: second)
        #expect(frecency.projectRoot(for: first) == first)
        await Self.resolve(frecency, cwd: third)

        #expect(frecency.projectRoot(for: first) == first)
        #expect(frecency.projectRoot(for: second) == nil)
        #expect(frecency.projectRoot(for: third) == third)
    }

    @Test func projectRootLookupNeverBlocksItsCallerAndRefreshesCurrentCWDOnce() throws {
        let dir = Scratch.dir("project-root-async-lookup")
        let repo = dir + "/repo"
        let child = repo + "/nested"
        let outside = dir + "/outside"
        try Self.makeRepo(repo)
        try FileManager.default.createDirectory(atPath: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "tine.frecency.blocked-test")
        let queueStarted = DispatchSemaphore(value: 0)
        queue.async {
            queueStarted.signal()
            Thread.sleep(forTimeInterval: 0.2)
        }
        queueStarted.wait()

        let frecency = Frecency(
            historyPath: dir + "/missing-history",
            storePath: dir + "/frecency.json",
            queue: queue)
        let completed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var deliveries = 0
        var applied = 0
        var recomputes = 0
        var currentCWD = dir + "/new-cwd"
        var appliedProjectRoot: String?
        var pendingApply = true
        func deliver(root: String?, index: Frecency.Index, resolvedFor cwd: String) {
            lock.lock()
            defer { lock.unlock() }
            deliveries += 1
            guard cwd == currentCWD else { return }
            guard pendingApply || root != appliedProjectRoot else { return }
            applied += 1
            if root == nil {
                #expect(index.isEmpty)
            } else {
                #expect(index["git"]?["rebase"]?.count == 1)
            }
            appliedProjectRoot = root
            pendingApply = false
            #expect(applied == recomputes + 1,
                    "the scoped index must be installed before recomputing")
            recomputes += 1
        }
        let started = Date()
        frecency.resolveProjectRoot(for: repo) { root, index in
            deliver(root: root, index: index, resolvedFor: repo)
            completed.signal()
        }
        #expect(Date().timeIntervalSince(started) < 0.05,
                "lookup must enqueue work without waiting behind the frecency queue")
        #expect(completed.wait(timeout: .now() + 1) == .success)
        Thread.sleep(forTimeInterval: 0.02)
        lock.lock()
        let deliveryCount = deliveries
        let appliedCount = applied
        let staleRecomputeCount = recomputes
        let pendingAfterStaleDrop = pendingApply
        lock.unlock()
        #expect(deliveryCount == 1)
        #expect(appliedCount == 0, "a result for an old cwd must not replace the current pool")
        #expect(staleRecomputeCount == 0, "a result for an old cwd must not recompute suggestions")
        #expect(pendingAfterStaleDrop, "a stale result must not consume the current cwd's pending apply")

        let record = frecency.record(cmd: "git", param: "rebase", cwd: repo)
        #expect(record?.scoped?["rebase"]?.count == 1)

        lock.lock()
        currentCWD = repo
        lock.unlock()
        let cachedCompleted = DispatchSemaphore(value: 0)
        frecency.resolveProjectRoot(for: repo) { root, index in
            deliver(root: root, index: index, resolvedFor: repo)
            cachedCompleted.signal()
        }
        #expect(cachedCompleted.wait(timeout: .now() + 1) == .success,
                "a cache hit must still deliver through the completion")
        Thread.sleep(forTimeInterval: 0.02)
        lock.lock()
        let finalDeliveryCount = deliveries
        let finalAppliedCount = applied
        let finalRecomputeCount = recomputes
        lock.unlock()
        #expect(finalDeliveryCount == 2, "each lookup must deliver exactly once")
        #expect(finalAppliedCount == 1, "only the current cwd may apply its delivery")
        #expect(finalRecomputeCount == 1, "the current cwd must recompute exactly once")

        let redeliveryCompleted = DispatchSemaphore(value: 0)
        frecency.resolveProjectRoot(for: repo) { root, index in
            deliver(root: root, index: index, resolvedFor: repo)
            redeliveryCompleted.signal()
        }
        #expect(redeliveryCompleted.wait(timeout: .now() + 1) == .success)
        lock.lock()
        let redeliveryCount = deliveries
        let redeliveryAppliedCount = applied
        let redeliveryRecomputeCount = recomputes
        lock.unlock()
        #expect(redeliveryCount == 3, "same-root redelivery must still complete")
        #expect(redeliveryAppliedCount == 1, "same-root redelivery must not apply again")
        #expect(redeliveryRecomputeCount == 1, "same-root redelivery must not recompute again")

        lock.lock()
        currentCWD = child
        pendingApply = true
        lock.unlock()
        let childCompleted = DispatchSemaphore(value: 0)
        frecency.resolveProjectRoot(for: child) { root, index in
            deliver(root: root, index: index, resolvedFor: child)
            childCompleted.signal()
        }
        #expect(childCompleted.wait(timeout: .now() + 1) == .success)
        lock.lock()
        let childAppliedCount = applied
        let childRecomputeCount = recomputes
        lock.unlock()
        #expect(childAppliedCount == 2,
                "a cwd clear must force apply even when the project root is unchanged")
        #expect(childRecomputeCount == 2,
                "a same-project cwd hop must recompute after restoring the cleared index")

        let childRedeliveryCompleted = DispatchSemaphore(value: 0)
        frecency.resolveProjectRoot(for: child) { root, index in
            deliver(root: root, index: index, resolvedFor: child)
            childRedeliveryCompleted.signal()
        }
        #expect(childRedeliveryCompleted.wait(timeout: .now() + 1) == .success)
        lock.lock()
        let childRedeliveryAppliedCount = applied
        let childRedeliveryRecomputeCount = recomputes
        lock.unlock()
        #expect(childRedeliveryAppliedCount == 2,
                "same-root redelivery after consuming pending must not apply")
        #expect(childRedeliveryRecomputeCount == 2,
                "same-root redelivery after consuming pending must not recompute")

        lock.lock()
        currentCWD = outside
        pendingApply = true
        lock.unlock()
        let outsideCompleted = DispatchSemaphore(value: 0)
        frecency.resolveProjectRoot(for: outside) { root, index in
            deliver(root: root, index: index, resolvedFor: outside)
            outsideCompleted.signal()
        }
        #expect(outsideCompleted.wait(timeout: .now() + 1) == .success)
        lock.lock()
        let outsideAppliedCount = applied
        let outsideRecomputeCount = recomputes
        lock.unlock()
        #expect(outsideAppliedCount == 3, "the cwd clear must be restored once outside a project")
        #expect(outsideRecomputeCount == 3)

        let outsideRedeliveryCompleted = DispatchSemaphore(value: 0)
        frecency.resolveProjectRoot(for: outside) { root, index in
            deliver(root: root, index: index, resolvedFor: outside)
            outsideRedeliveryCompleted.signal()
        }
        #expect(outsideRedeliveryCompleted.wait(timeout: .now() + 1) == .success)
        lock.lock()
        let outsideRedeliveryAppliedCount = applied
        let outsideRedeliveryRecomputeCount = recomputes
        lock.unlock()
        #expect(outsideRedeliveryAppliedCount == 3,
                "nil-root redelivery must not apply when nil is already installed")
        #expect(outsideRedeliveryRecomputeCount == 3,
                "nil-root redelivery must not recompute when nil is already installed")
    }
}

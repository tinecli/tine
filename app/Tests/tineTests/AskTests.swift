import Foundation
import Testing

struct AskIndexSaveTests {
    @Test func successfulSaveFiresTheSnapshotRefreshCallback() throws {
        let entry = AskEntry(name: "jq", description: "Command-line JSON processor")
        let stored = AskIndex.Stored(signature: "test", builtAt: Date(), entries: [entry])
        let dir = Scratch.dir("ask-index-save")
        var refreshedEntries: [AskEntry]?

        try AskIndex.save(stored, to: dir) { refreshedEntries = $0 }

        #expect(refreshedEntries == [entry])
        #expect(FileManager.default.fileExists(atPath: dir + "/ask-index.json"))
    }
}

struct AskExampleTests {
    static let translations: [(String, String)] = [
        (".Dl Nm", "tool"),
        (".Dl Nm Fl x", "tool -x"),
        (".Dl Nm Fl a b", "tool -a -b"),
        (".Dl Nm Fl a , Ar file", "tool -a , file"),
        (".Dl Nm Pa /tmp/archive", "tool /tmp/archive"),
        (".Dl Nm Ar source", "tool source"),
        (#".It Li "tool --literal value""#, "tool --literal value"),
        (".Dl Nm Cm create", "tool create"),
        (".Dl Nm Ic status", "tool status"),
        (".Dl Nm Sy keyword", "tool keyword"),
        (".Dl Nm No text", "tool text"),
        (".Dl Nm replacement", "replacement"),
        (".Dl Nm Qq Li value", "tool \"value\""),
        (".Dl Nm Ql value", "tool 'value'"),
        (".Dl Nm Sq value", "tool 'value'"),
        (".Dl Nm Pq Fl x", "tool (-x)"),
        (".Dl Xr ls 1", "ls(1)"),
        (#".Dl "date ""+%Y%m%d""""#, #"date "+%Y%m%d""#),
        (".Dl Dq multi word arg", "\"multi word arg\""),
        (#".Dl csreq -r="identifier com.foo.test" -b output.csreq"#,
         #"csreq -r="identifier com.foo.test" -b output.csreq"#),
        (#".It Li "tool --list" \" trailing comment"#, "tool --list"),
        (".Dl Nm Ns Pa suffix", "toolsuffix"),
        (".Vb 1\ntool --verbatim\n.Ve", "tool --verbatim"),
        (".Ss First form\n.Dl Nm Fl first", "tool -first"),
    ]

    static func page(example: String) -> String {
        ".Sh NAME\n.Nm tool\n.Sh EXAMPLES\n\(example)\n.Sh SEE ALSO\n"
    }

    @Test(arguments: translations)
    func translatesWhitelistedMdocMacros(_ c: (source: String, expected: String)) {
        #expect(AskIndex.examples(inManPage: Self.page(example: c.source)) == c.expected)
    }

    @Test func optionalFlagsRenderConcreteNotBracketed() {
        let op = AskIndex.examples(inManPage: Self.page(example: ".Dl Nm Op Fl verbose"))
        let oo = AskIndex.examples(inManPage: Self.page(example: ".Dl Nm Oo Fl quiet Oc"))

        #expect(op == "tool -verbose")
        #expect(oo == "tool -quiet")
    }

    @Test func unknownMdocMacroStillFailsClosed() {
        let example = AskIndex.examples(inManPage: Self.page(example: ".Dl Nm Xx injected"))
        #expect(example == "Nm Xx injected")
        #expect(Asker.checked(example ?? "", installed: ["tool"]) == nil)

        let outer = AskIndex.examples(inManPage: Self.page(example: ".Xyz tool --injected"))
        #expect(outer == "Xyz tool --injected")
        #expect(Asker.checked(outer ?? "", installed: ["tool"]) == nil)
    }

    @Test func readsForwardFromTheInitialWindowThroughExamples() throws {
        let dir = Scratch.dir("ask-examples-forward")
        let path = dir + "/tool.1"
        let filler = String(repeating: ".\\\" filler\n", count: 14_000)
        let page = ".SH NAME\ntool \\- a tool\n.SH DESCRIPTION\n" + filler
            + ".SH EXAMPLES\n.B tool --late example\n.SH SEE ALSO\n"
        try Data(page.utf8).write(to: URL(fileURLWithPath: path))

        #expect(AskIndex.examples(inManPageAt: path) == "tool --late example")
    }

    @Test func examplesContinueThroughSubsectionHeadings() {
        let page = ".SH NAME\ntool \\- a tool\n.SH EXAMPLES\n"
            + ".SS First form\n.B tool --first\n.SH SEE ALSO\n"
        #expect(AskIndex.examples(inManPage: page) == "tool --first")
    }

    @Test func mdocExamplesContinueThroughSubsectionHeadings() {
        let page = ".Sh NAME\n.Nm tool\n.Sh EXAMPLES\n"
            + ".Ss First form\n.Dl Nm Fl first\n.Sh SEE ALSO\n"
        #expect(AskIndex.examples(inManPage: page) == "tool -first")
    }

    @Test func mdocLiteralQuotesDoNotHideRejectedShellSyntax() {
        let example = AskIndex.examples(
            inManPage: Self.page(example: ".Dl Nm Ql value | Nm Ar file")
        )
        #expect(example == "tool 'value | tool file'")
        #expect(Asker.checked(example ?? "", installed: ["tool"]) == nil)
    }

    @Test(arguments: ["Ql", "Sq"])
    func mdocLiteralQuotesRemainCheckedEligible(_ macro: String) {
        let example = AskIndex.examples(
            inManPage: Self.page(example: ".Dl Nm \(macro) value")
        )
        #expect(Asker.checked(example ?? "", installed: ["tool"]) == "tool 'value'")
    }

    @Test func nameStopsAtRoffSubsectionHeadings() {
        let page = ".SH NAME\nnpm-access \\- Set access level on published packages\n"
            + ".SS Synopsis\nnpm access list packages [<user>]\n.SH DESCRIPTION\n"
        #expect(AskIndex.nameLine(inManPage: page)
            == "npm-access - Set access level on published packages")
    }

    @Test func examplesPastTheHardCeilingStayUnread() throws {
        let dir = Scratch.dir("ask-examples-ceiling")
        let path = dir + "/tool.1"
        let filler = String(repeating: ".\\\" filler\n", count: 50_000)
        let page = ".SH NAME\ntool \\- a tool\n.SH DESCRIPTION\n" + filler
            + ".SH EXAMPLES\n.B tool --too-late example\n.SH SEE ALSO\n"
        try Data(page.utf8).write(to: URL(fileURLWithPath: path))

        #expect(AskIndex.examples(inManPageAt: path) == nil)
    }

    @Test func destructiveFloorAlsoRejectsTheExampleRow() {
        #expect(!Asker.isSafeExample("rm scratch.txt", validation: .ok(dangerous: false)))
        #expect(Asker.isSafeExample("ls scratch.txt", validation: .ok(dangerous: false)))
        #expect(!Asker.isSafeExample("ls scratch.txt", validation: .ok(dangerous: true)))
    }

    @Test func followsOneSameTreeSoIncludeForTheName() throws {
        let root = Scratch.dir("ask-so-include") + "/share/man"
        let section = root + "/man1"
        try FileManager.default.createDirectory(atPath: section, withIntermediateDirectories: true)
        try ".so man1/tool.1\n".write(
            toFile: section + "/alias.1", atomically: true, encoding: .utf8)
        try ".SH NAME\ntool \\- included description\n".write(
            toFile: section + "/tool.1", atomically: true, encoding: .utf8)

        #expect(AskIndex.nameLine(inManPageAt: section + "/alias.1")
            == "tool - included description")
    }

    @Test func soIncludeIsOneHopAndCannotLeaveItsManTree() throws {
        let parent = Scratch.dir("ask-so-bounds")
        let root = parent + "/share/man"
        let section = root + "/man1"
        try FileManager.default.createDirectory(atPath: section, withIntermediateDirectories: true)
        try ".so man1/middle.1\n".write(
            toFile: section + "/alias.1", atomically: true, encoding: .utf8)
        try ".so man1/target.1\n".write(
            toFile: section + "/middle.1", atomically: true, encoding: .utf8)
        try ".SH NAME\ntool \\- too far\n".write(
            toFile: section + "/target.1", atomically: true, encoding: .utf8)
        try ".SH NAME\nescape \\- outside tree\n".write(
            toFile: parent + "/escape.1", atomically: true, encoding: .utf8)
        try ".so ../../../escape.1\n".write(
            toFile: section + "/escape.1", atomically: true, encoding: .utf8)

        #expect(AskIndex.nameLine(inManPageAt: section + "/alias.1") == nil)
        #expect(AskIndex.nameLine(inManPageAt: section + "/escape.1") == nil)
    }

    @Test func discoversAndReadsGzippedManPages() throws {
        let root = Scratch.dir("ask-gzip") + "/share/man"
        let section = root + "/man1"
        try FileManager.default.createDirectory(atPath: section, withIntermediateDirectories: true)
        let encoded = "H4sIANjPemoAA9ML8VCI8gwI8ff3UTDk0gv2UPBz9HXlqsosKMnPz1GI0VUoSk1MKVZIzs8tKEotLk5NUchNzCtNzCkGK3ZxDXYOAmr39PfjSspPqeQCALg6g0tQAAAA"
        try #require(Data(base64Encoded: encoded)).write(
            to: URL(fileURLWithPath: section + "/ziptool.1.gz"))

        let pages = AskIndex.manPages(in: [root])
        let path = try #require(pages["ziptool"])
        #expect(path.hasSuffix("ziptool.1.gz"))
        #expect(AskIndex.nameLine(inManPageAt: path) == "ziptool - reads compressed manuals")
    }
}

struct AskIndexPruneTests {
    @Test func versionLikeNamesForDistinctBinariesBothSurface() throws {
        let entries = try entriesForPythonCommands(sameBinary: false)
        let names = AskIndex.rank("python runtime", in: entries, limit: 10).map(\.entry.name)

        #expect(names.contains("python"))
        #expect(names.contains("python3"))
    }

    @Test func trueVersionTwinsStillCollapse() throws {
        let entries = try entriesForPythonCommands(sameBinary: true)
        let names = AskIndex.rank("python runtime", in: entries, limit: 10).map(\.entry.name)

        #expect(names.contains("python3"))
        #expect(!names.contains("python3.9"))
    }

    private func entriesForPythonCommands(sameBinary: Bool) throws -> [AskEntry] {
        let root = Scratch.dir("ask-python-twins")
        let bin = root + "/bin"
        let man = root + "/share/man/man1"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: man, withIntermediateDirectories: true)
        let first = root + "/python-runtime"
        let second = root + "/python3-runtime"
        try "#!/bin/sh\n".write(toFile: first, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(toFile: second, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: first)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: second)
        let olderName = sameBinary ? "python3" : "python"
        let newerName = sameBinary ? "python3.9" : "python3"
        try FileManager.default.createSymbolicLink(
            atPath: bin + "/" + olderName, withDestinationPath: first)
        try FileManager.default.createSymbolicLink(
            atPath: bin + "/" + newerName, withDestinationPath: sameBinary ? first : second)
        for name in [olderName, newerName] {
            try ".SH NAME\n\(name) \\- python runtime\n".write(
                toFile: man + "/\(name).1", atomically: true, encoding: .utf8)
        }
        return AskIndex.build(shellPath: bin, packDescriptions: [:]).entries
    }
}

struct LocalSpecsBridgeTests {
    @Test func setLocalSpecsDirsPushesAndResetsWithoutCreatingDirectories() throws {
        let root = Scratch.dir("local-specs-bridge")
        let resources = root + "/resources"
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        let script = """
        globalThis.__tineSpecResetCount = 0;
        globalThis.tineResetSpecs = function() { globalThis.__tineSpecResetCount += 1; };
        globalThis.tineSuggest = function(line, cursor, cwd, cb) {
          cb({items: [{name: globalThis.__tineLocalSpecsDirs.join('|'),
            description: String(globalThis.__tineSpecResetCount),
            insertValue: '', shouldAddSpace: false, type: 'arg', queryTerm: '',
            isDangerous: false, matchIndices: []}]});
        };
        """
        try script.write(
            toFile: resources + "/tine-engine.js", atomically: true, encoding: .utf8)
        let oldDir = root + "/old"
        let newDir = root + "/new"
        let engine = JSEngine(
            specsDir: root + "/pack", localSpecsDirs: [oldDir], resourcesDir: resources,
            logPath: root + "/tine.log")

        engine.setLocalSpecsDirs(["", newDir])

        let suggestion = engine.suggest(line: "x", cursor: 1, cwd: root).first
        #expect(suggestion?.name == newDir)
        #expect(suggestion?.description == "1")
        #expect(!FileManager.default.fileExists(atPath: newDir))
    }
}

struct AskRetrievalTests {
    static let corpus = [
        AskEntry(name: "shrinker", description: "shrink media files"),
        AskEntry(name: "encoder", description: "compress and encode movies"),
        AskEntry(name: "jq", description: "process JSON"),
    ]

    @Test func expansionUnionsRawAndExpandedTerms() {
        let raw = Asker.candidatePool(question: "shrink a video", expansion: nil,
                                      in: Self.corpus, limit: 3)
        let expanded = Asker.candidatePool(
            question: "shrink a video", expansion: "compress encode movie",
            in: Self.corpus, limit: 3
        )

        #expect(raw.map(\.name) == ["shrinker"])
        #expect(Set(expanded.map(\.name)) == ["shrinker", "encoder"])
    }

    @Test func expansionDropsStopwordsBeforeTruncatingTerms() {
        let entries = [AskEntry(name: "metadata-tool", description: "read heic jpeg exif metadata")]
        let expansion = "Here are some command-line tools that can help you with what you need: "
            + "heic jpeg exif"
        let expanded = Asker.candidatePool(
            question: "something unrelated", expansion: expansion, in: entries, limit: 3
        )

        #expect(expanded.map(\.name) == ["metadata-tool"])
    }

    @Test func guidedExpansionTermsDecodeThroughInjectedSeam() async {
        let expanded = await Asker.retrievalCandidates(
            question: "shrink a video", in: Self.corpus, limit: 3,
            expansionTimeout: 0.1,
            expand: { _ in ExpandedSearchTerms(terms: ["compress", "encode", "movie"]) }
        )

        #expect(Set(expanded.map(\.name)) == ["shrinker", "encoder"])
    }

    @Test func expansionErrorFailsOpenToRawRanking() async {
        struct Unavailable: Error {}
        let raw = Asker.candidatePool(question: "shrink a video", expansion: nil,
                                      in: Self.corpus, limit: 3)
        let failed = await Asker.retrievalCandidates(
            question: "shrink a video", in: Self.corpus, limit: 3,
            expansionTimeout: 0.1,
            expand: { _ in throw Unavailable() }
        )

        #expect(failed == raw)
    }

    @Test func expansionTimeoutFailsOpenToRawRanking() async {
        let raw = Asker.candidatePool(question: "shrink a video", expansion: nil,
                                      in: Self.corpus, limit: 3)
        let timedOut = await Asker.retrievalCandidates(
            question: "shrink a video", in: Self.corpus, limit: 3,
            expansionTimeout: 0.01,
            expand: { _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return ExpandedSearchTerms(terms: ["compress", "encode", "video"])
            }
        )

        #expect(timedOut == raw)
    }
}

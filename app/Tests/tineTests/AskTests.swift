import Foundation
import Testing

struct AskExampleTests {
    static let translations: [(String, String)] = [
        (".Dl Nm", "tool"),
        (".Dl Nm Fl x", "tool -x"),
        (".Dl Nm Pa /tmp/archive", "tool /tmp/archive"),
        (".Dl Nm Ar source", "tool source"),
        (#".It Li "tool --literal value""#, "tool --literal value"),
        (".Dl Nm Cm create", "tool create"),
        (".Dl Nm Ic status", "tool status"),
        (".Dl Nm Sy keyword", "tool keyword"),
        (".Dl Nm No text", "tool text"),
        (".Dl Nm replacement", "replacement"),
        (".Dl Nm Qq Li value", "tool \"value\""),
        (".Dl Nm Pq Fl x", "tool (-x)"),
        (".Dl Dq multi word arg", "\"multi word arg\""),
        (#".Dl csreq -r="identifier com.foo.test" -b output.csreq"#,
         #"csreq -r="identifier com.foo.test" -b output.csreq"#),
        (#".It Li "tool --list" \" trailing comment"#, "tool --list"),
        (".Dl Nm Ns Pa suffix", "toolsuffix"),
    ]

    static func page(example: String) -> String {
        ".Sh NAME\n.Nm tool\n.Sh EXAMPLES\n\(example)\n.Sh SEE ALSO\n"
    }

    @Test(arguments: translations)
    func translatesWhitelistedMdocMacros(_ c: (source: String, expected: String)) {
        #expect(AskIndex.examples(inManPage: Self.page(example: c.source)) == c.expected)
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
        #expect(AskIndex.examples(inManPage: page) == "First form tool --first")
    }

    @Test func mdocExamplesContinueThroughSubsectionHeadings() {
        let page = ".Sh NAME\n.Nm tool\n.Sh EXAMPLES\n"
            + ".Ss First form\n.Dl Nm Fl first\n.Sh SEE ALSO\n"
        #expect(AskIndex.examples(inManPage: page) == "First form tool -first")
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
}

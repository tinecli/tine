// `tine ask` harness. There is no Swift test target yet, so build it against the
// sources and run it with a scratch data dir:
//
//   swiftc -swift-version 5 -o /private/tmp/tine-harness/ask app/Tests/AskHarness.swift \
//       app/Sources/tine/AskIndex.swift app/Sources/tine/Asker.swift \
//       app/Sources/tine/CommandRunner.swift app/Sources/tine/SocketServer.swift \
//       app/Sources/tine/Log.swift app/Sources/tine/SpecLearner.swift \
//       app/Sources/tine/TineConfig.swift app/Sources/tine/JSEngine.swift \
//       app/Sources/tine/Frecency.swift
//   TINE_DATA_DIR=/private/tmp/tine-harness /private/tmp/tine-harness/ask
//
// Man-page parsing, description cleaning, ranking and answer validation run
// everywhere. `--live` builds the real index for this machine's PATH and prints
// what it retrieves, which is how the ranking was tuned. `--answer` drives the
// whole verb — real engine, real specs, real model — and needs the on-device
// model to be available. Both write only inside TINE_DATA_DIR.

import Foundation

@main
enum AskHarness {
    static var pass = 0
    static var fail = 0

    static func check(_ name: String, _ ok: Bool) {
        if ok {
            pass += 1
            print("PASS  \(name)")
        } else {
            fail += 1
            print("FAIL  \(name)")
        }
    }

    static func main() {
        // The harness writes an index, so it must never run against real user data.
        let root = ProcessInfo.processInfo.environment["TINE_DATA_DIR"] ?? ""
        guard root.hasPrefix("/private/tmp/") || root.hasPrefix("/var/folders/") else {
            let message = "refusing to run outside /private/tmp or /var/folders: \(root)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(2)
        }
        parsing()
        descriptions()
        names()
        ranking()
        answers()
        store()
        if CommandLine.arguments.contains("--live") { live() }
        if CommandLine.arguments.contains("--answer") { MainActor.assumeIsolated { answering() } }
        print("\n\(pass) passed, \(fail) failed")
        exit(fail == 0 ? 0 : 1)
    }

    // MARK: - Man page parsing

    static let mdocPage = """
        .\\" Copyright (c) 1980, 1990
        .Dd December 1, 2023
        .Dt LS 1
        .Sh NAME
        .Nm ls
        .Nd list directory contents
        .Sh SYNOPSIS
        .Nm
        .Op Fl ABCF
        """

    static let manPage = """
        .TH magick 1 "Date: 2009/01/10" "ImageMagick"
        .SH NAME
        magick \\- convert between image formats as well as \\fBresize\\fP an image
        .SH SYNOPSIS
        .TP
        \\fBmagick\\fP [\\fIinput-options\\fP]
        """

    static func parsing() {
        check("mdoc NAME", AskIndex.nameLine(inManPage: mdocPage) == "ls - list directory contents")
        check("man NAME",
              AskIndex.nameLine(inManPage: manPage)
                  == "magick - convert between image formats as well as resize an image")
        check("no NAME section", AskIndex.nameLine(inManPage: ".TH foo 1\n.SH SYNOPSIS\nfoo\n") == nil)
        check("NAME section stops at the next heading",
              AskIndex.nameLine(inManPage: ".SH NAME\nfoo - a thing\n.SH DESCRIPTION\nlong prose")
                  == "foo - a thing")
        check("quoted NAME heading",
              AskIndex.nameLine(inManPage: ".SH \"NAME\"\nfoo - a thing\n") == "foo - a thing")
        check("roff comment dropped",
              AskIndex.nameLine(inManPage: ".SH NAME\n.\\\" hidden\nfoo - a thing\n") == "foo - a thing")

        check("font escape stripped", AskIndex.unroff("a \\fBbold\\fP word") == "a bold word")
        check("bracketed font stripped", AskIndex.unroff("a \\f(CWmono\\fP word") == "a mono word")
        check("size escape stripped", AskIndex.unroff("a \\s-1small\\s0 word") == "a small word")
        check("glyph escape stripped", AskIndex.unroff("a \\(emdash") == "a dash")
        check("escaped dash kept", AskIndex.unroff("foo \\- bar") == "foo - bar")
        check("whitespace collapsed", AskIndex.unroff("a   b\tc\nd") == "a b c d")
        check("description bounded",
              AskIndex.unroff(String(repeating: "x", count: 400)).count == AskIndex.maxDescription)
        // A NAME line is not a place to hide an escape sequence.
        check("control characters dropped", !AskIndex.unroff("a \\e[31mred").contains("\u{1b}"))
    }

    // MARK: - Descriptions

    static func descriptions() {
        check("leading name dropped",
              AskIndex.description("ls - list directory contents", of: "ls") == "list directory contents")
        check("self-referential description dropped",
              AskIndex.description("csvlook - csvlook Documentation", of: "csvlook") == "")
        check("bare name dropped", AskIndex.description("foo", of: "foo") == "")
        check("real description kept",
              AskIndex.description("jq - Command-line JSON processor", of: "jq")
                  == "Command-line JSON processor")
        check("empty stays empty", AskIndex.description("", of: "foo") == "")
        // A page shared by a family names the family, not this tool.
        check("another tool's heading dropped",
              AskIndex.description("xzgrep - search possibly-compressed files", of: "lzegrep")
                  == "search possibly-compressed files")
        check("a comma-separated heading dropped",
              AskIndex.description("rm, unlink - remove directory entries", of: "rm")
                  == "remove directory entries")
        check("a dash inside the description survives",
              AskIndex.description("a well-known thing - and more", of: "foo")
                  == "a well-known thing - and more")
    }

    // MARK: - Names

    static func names() {
        check("tool name accepted", AskIndex.isToolName("magick"))
        check("dotted tool name accepted", AskIndex.isToolName("python3.12"))
        check("path rejected", !AskIndex.isToolName("../../etc/passwd"))
        check("slash rejected", !AskIndex.isToolName("bin/tool"))
        check("space rejected", !AskIndex.isToolName("rm -rf"))
        check("dotfile rejected", !AskIndex.isToolName(".hidden"))
        check("version twin found", AskIndex.versionlessName("json_xs5.34") == "json_xs")
        check("plain name has no twin", AskIndex.versionlessName("jq") == nil)
        check("all-digit name has no twin", AskIndex.versionlessName("7z") == nil)
    }

    // MARK: - Ranking

    static let corpus = [
        AskEntry(name: "magick", description: "convert between image formats as well as resize an image"),
        AskEntry(name: "jq", description: "Command-line JSON processor"),
        AskEntry(name: "json_pp", description: "JSON pretty printing"),
        AskEntry(name: "json_pp5.34", description: "JSON pretty printing"),
        AskEntry(name: "csvlook", description: ""),
        AskEntry(name: "ls", description: "list directory contents"),
        AskEntry(name: "du", description: "display disk usage statistics"),
        AskEntry(name: "curl", description: "transfer a URL"),
        AskEntry(name: "tar", description: "manipulate tape archives"),
        AskEntry(name: "rm", description: "remove directory entries"),
        AskEntry(name: "rmdir", description: "remove directory entries"),
    ]

    static func top(_ query: String) -> [String] {
        AskIndex.rank(query, in: corpus, limit: 3).map { $0.entry.name }
    }

    static func ranking() {
        check("finds the tool by its description", top("convert an image").first == "magick")
        check("plural folds onto singular", top("list the files in a directory").first == "ls")
        check("name substring matches", top("a cli that can format csv").first == "csvlook")
        check("disk usage", top("show disk usage of a folder").first == "du")
        check("download", top("download something from a url").first == "curl")
        check("version twin never shown",
              !AskIndex.rank("pretty print json", in: corpus, limit: 9)
                  .contains { $0.entry.name == "json_pp5.34" })
        // The page says "remove", the user says "delete".
        check("a synonym of the tool's own word matches",
              top("delete a whole directory").first == "rm")
        check("the user's own word outranks a synonym of it",
              AskIndex.weighted(["delete"])["delete"] == 1
                  && AskIndex.weighted(["delete"])["remove"] == 0.6)
        check("one description takes one row",
              !AskIndex.rank("remove a directory", in: corpus, limit: 9)
                  .contains { $0.entry.name == "rmdir" })
        check("a question of only stopwords retrieves nothing", top("what can I do").isEmpty)
        check("empty question retrieves nothing", top("").isEmpty)
        check("limit honoured", AskIndex.rank("json", in: corpus, limit: 1).count == 1)
    }

    // MARK: - Answer validation

    static func answers() {
        let installed = Set(["magick", "jq", "ls"])
        check("command from an installed tool accepted",
              Asker.checked("magick in.png out.jpg", installed: installed) == "magick in.png out.jpg")
        check("uninstalled tool rejected",
              Asker.checked("mlr --icsv cat f.csv", installed: installed) == nil)
        check("a second command rejected",
              Asker.checked("ls; rm -rf /", installed: installed) == nil)
        check("a pipe rejected", Asker.checked("ls | rm", installed: installed) == nil)
        check("command substitution rejected",
              Asker.checked("ls $(whoami)", installed: installed) == nil)
        check("backtick rejected", Asker.checked("ls `whoami`", installed: installed) == nil)
        check("redirect rejected", Asker.checked("ls > /etc/passwd", installed: installed) == nil)
        check("newline rejected", Asker.checked("ls\nrm -rf /", installed: installed) == nil)
        check("empty rejected", Asker.checked("", installed: installed) == nil)
        check("prose rejected", Asker.checked("You can use ls", installed: installed) == nil)
        check("an over-long line rejected",
              Asker.checked("ls " + String(repeating: "a", count: 400), installed: installed) == nil)
        check("a question is bounded and stripped",
              Asker.question("  convert\nan image\u{1f}to jpeg  ") == "convert an image to jpeg")
        check("an empty question is rejected", Asker.question("   ") == nil)
        check("a question longer than the cap is rejected",
              Asker.question(String(repeating: "x", count: 600)) == nil)
    }

    // MARK: - Store

    static func store() {
        let entries = [AskEntry(name: "jq", description: "Command-line JSON processor")]
        let stored = AskIndex.Stored(signature: "sig", builtAt: Date(), entries: entries)
        do {
            try AskIndex.save(stored)
        } catch {
            check("index saved", false)
            return
        }
        let loaded = AskIndex.load()
        check("index round-trips", loaded?.entries == entries && loaded?.signature == "sig")
        check("index lands in the data dir", AskIndex.path.hasPrefix(AskIndex.dir))
    }

    // MARK: - Live build (opt-in)

    static func live() {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let start = Date()
        let built = AskIndex.build(shellPath: path, packDescriptions: [:])
        let seconds = Date().timeIntervalSince(start)
        let described = built.entries.filter { !$0.description.isEmpty }.count
        try? AskIndex.save(built)
        let size = (try? FileManager.default.attributesOfItem(atPath: AskIndex.path)[.size]) as? Int
        print(String(format: "\nlive: %d tools (%d described) in %.2fs, %d bytes on disk",
                     built.entries.count, described, seconds, size ?? 0))
        for query in ["convert an image to jpeg", "a cli that can format csv",
                      "search for text inside files", "show disk usage of a folder",
                      "compress a folder into an archive", "download a file from a url",
                      "pretty print json", "monitor cpu usage", "resize a photo",
                      "rename many files at once"] {
            let hits = AskIndex.rank(query, in: built.entries, limit: 5)
            print("  \(query): " + hits.map { $0.entry.name }.joined(separator: " "))
        }
        let query = "pretty print json"
        let t0 = Date()
        for _ in 0..<20 { _ = AskIndex.rank(query, in: built.entries, limit: 5) }
        print(String(format: "  rank: %.1f ms", Date().timeIntervalSince(t0) * 1000 / 20))
    }

    // MARK: - A real answer (opt-in)

    /// The whole path the socket verb drives, wired the way the app wires it: a
    /// real engine over the installed pack, the real index, the real model. Only
    /// the scratch data dir is not real.
    @MainActor
    static func answering() {
        let environment = ProcessInfo.processInfo.environment
        let pack = environment["TINE_SPECS_DIR"] ?? "\(NSHomeDirectory())/.local/share/tine/specs"
        let resources = environment["TINE_RESOURCES_DIR"] ?? "app/engine"
        let engine = JSEngine(specsDir: pack, localSpecsDirs: [], resourcesDir: resources)
        check("engine ready", engine.ready)
        check("engine rejects an invented flag",
              engine.validate(line: "git --quantum") == .invalid("--quantum"))
        check("engine accepts a real one", engine.validate(line: "git --version") == .ok(dangerous: false))
        check("engine outlines a tool's flags", engine.outline(command: "git").contains("--version"))

        let asker = Asker(packDir: pack)
        asker.shellPath = { environment["PATH"] ?? "" }
        asker.validate = { engine.validate(line: $0) }
        asker.outline = { engine.outline(command: $0) }

        for question in ["convert an image to jpeg", "a cli that can format csv",
                         "search for text inside files", "delete a directory and everything in it"] {
            let started = Date()
            print("\nask: \(question) → \(asker.ask(question: question))")
            while Date().timeIntervalSince(started) < 90 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let line = asker.statusLine
                if line.hasPrefix("done:") || line.hasPrefix("failed:") {
                    print(String(format: "  %.2fs %@", Date().timeIntervalSince(started),
                                 line.replacingOccurrences(of: TINE_US, with: "\n    ")
                                     .replacingOccurrences(of: TINE_RS, with: " | ")))
                    break
                }
            }
        }
    }
}

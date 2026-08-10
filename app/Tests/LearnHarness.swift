// `tine learn` harness. Build it against the sources and run it with a scratch
// root:
//
//   swiftc -swift-version 5 -o /private/tmp/tine-harness/learn app/Tests/LearnHarness.swift \
//       app/Sources/tine/SpecLearner.swift app/Sources/tine/CommandRunner.swift \
//       app/Sources/tine/SocketServer.swift app/Sources/tine/SocketSafe.swift \
//       app/Sources/tine/TineConfig.swift
//   LEARN_HOME=/private/tmp/tine-harness /private/tmp/tine-harness/learn
//
// The validation/serialization cases run everywhere. The last case is a real
// end-to-end learn — a fake CLI on a scratch PATH, the real model, a spec file in
// the scratch root — and is skipped when the on-device model is unavailable.

import Foundation
import FoundationModels

@main
enum LearnHarness {
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
        // The harness writes files, so it must never run against real user data.
        let root = ProcessInfo.processInfo.environment["LEARN_HOME"] ?? ""
        guard root.hasPrefix("/private/tmp/") || root.hasPrefix("/var/folders/") else {
            let msg = "refusing to run outside /private/tmp or /var/folders: \(root)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        names()
        sanitizing()
        serialization()
        injection()
        endToEnd(root: root)   // exits
    }

    static func finish() -> Never {
        print("\n\(pass) passed, \(fail) failed")
        exit(fail == 0 ? 0 : 1)
    }

    static func names() {
        check("command name accepted", SpecLearner.isCommandName("plug-cli"))
        check("dotted command name accepted", SpecLearner.isCommandName("python3.12"))
        check("path rejected", !SpecLearner.isCommandName("../../etc/passwd"))
        check("slash rejected", !SpecLearner.isCommandName("bin/tool"))
        check("space rejected", !SpecLearner.isCommandName("rm -rf"))
        check("empty rejected", !SpecLearner.isCommandName(""))
        check("leading dash rejected", !SpecLearner.isCommandName("-tool"))
        check("long name rejected", !SpecLearner.isCommandName(String(repeating: "a", count: 65)))

        check("long flag accepted", SpecLearner.isFlag("--dry-run"))
        check("short flag accepted", SpecLearner.isFlag("-v"))
        check("bare word rejected as flag", !SpecLearner.isFlag("verbose"))
        check("flag with value rejected", !SpecLearner.isFlag("--file=NAME"))
        check("flag with space rejected", !SpecLearner.isFlag("--file NAME"))
        check("triple dash rejected", !SpecLearner.isFlag("---x"))

        check("destination is the extend folder",
              SpecLearner.destination(command: "ft", in: "/d") == "/d/extend/ft.js")
    }

    static func sanitizing() {
        let hostile = "closes };\nimport evil; export default {} \u{2028}"
        let cleaned = SpecLearner.text(hostile)
        check("no semicolon survives", !cleaned.contains(";"))
        check("no brace survives", !cleaned.contains("{") && !cleaned.contains("}"))
        check("no newline survives", !cleaned.contains("\n"))
        check("no line separator survives", !cleaned.contains("\u{2028}"))
        check("text is bounded", SpecLearner.text(String(repeating: "x ", count: 400)).count <= 120)
    }

    /// A spec as the model would hand it over, with the junk it also hands over:
    /// a duplicate, an unusable name, a doubled short flag, an invented flag.
    static func sample(description: String = "Fake tool for tests") -> LearnedSpec {
        LearnedSpec(
            description: description,
            subcommands: [
                LearnedSubcommand(name: "build", description: "Build the project"),
                LearnedSubcommand(name: "build", description: "Duplicate"),
                LearnedSubcommand(name: "rm -rf /", description: "Not a subcommand name"),
                LearnedSubcommand(name: "deploy", description: "Invented"),
            ],
            options: [
                LearnedOption(name: "--verbose", short: "--v",
                              description: "Print more", argument: "",
                              takesFilePath: false, isOptional: false),
                LearnedOption(name: "--out", short: "",
                              description: "Where to write", argument: "<FILE>",
                              takesFilePath: true, isOptional: false),
                LearnedOption(name: "not-a-flag", short: "",
                              description: "Dropped", argument: "",
                              takesFilePath: false, isOptional: false),
                LearnedOption(name: "--sudo", short: "",
                              description: "Invented", argument: "",
                              takesFilePath: false, isOptional: false),
            ],
            argument: "path",
            takesFilePath: false,
            isOptional: false)
    }

    static func json(of module: String) -> [String: Any]? {
        guard let start = module.range(of: "export default ") else { return nil }
        var body = String(module[start.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(";") { body.removeLast() }
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    }

    static func serialization() {
        guard let module = SpecLearner.specModule(command: "faketool", from: sample(),
                                                  help: helpText),
              let spec = json(of: module) else {
            check("module serializes", false)
            return
        }
        check("module is a spec module", module.contains("export default {"))
        check("module names the command", spec["name"] as? String == "faketool")

        let subcommands = spec["subcommands"] as? [[String: Any]] ?? []
        check("bad, duplicate and invented subcommands dropped", subcommands.count == 1)
        check("subcommand kept", subcommands.first?["name"] as? String == "build")

        let options = spec["options"] as? [[String: Any]] ?? []
        check("bad and invented flags dropped", options.count == 2)
        check("doubled short flag repaired",
              (options.first?["name"] as? [String] ?? []) == ["--verbose", "-v"])
        let out = options.last ?? [:]
        check("single flag stays a string", out["name"] as? String == "--out")
        check("flag argument unwrapped", (out["args"] as? [String: Any])?["name"] as? String == "FILE")
        check("positional argument kept", (spec["args"] as? [String: Any])?["name"] as? String == "path")

        var empty = sample()
        empty.subcommands = []
        empty.options = []
        check("a spec with nothing in it is not written",
              SpecLearner.specModule(command: "faketool", from: empty, help: helpText) == nil)
        check("an invalid command name is never serialized",
              SpecLearner.specModule(command: "../evil", from: sample(), help: helpText) == nil)
        check("a spec with nothing the help documents is not written",
              SpecLearner.specModule(command: "faketool", from: sample(),
                                     help: "no flags here") == nil)
        check("the module carries the header that marks it tine's",
              module.hasPrefix(SpecLearner.header))
        pairedFlags()
        argumentShape()
        coverage()
        shortFlags()
    }

    static func pairedFlags() {
        let learned = LearnedSpec(
            description: "CSV cleaner",
            subcommands: [],
            options: [
                LearnedOption(name: "-d, --delimiter DELIMITER", short: "",
                              description: "Set delimiter", argument: "DELIMITER",
                              takesFilePath: false, isOptional: false),
            ],
            argument: "",
            takesFilePath: false,
            isOptional: false)
        let help = "  -d, --delimiter DELIMITER  Set delimiter"
        let names = SpecLearner.specModule(command: "csvclean", from: learned, help: help)
            .flatMap(json)?["options"] as? [[String: Any]]
        check("paired flag name carries both forms",
              names?.first?["name"] as? [String] == ["-d", "--delimiter"])

        let invented = LearnedSpec(
            description: "CSV cleaner",
            subcommands: [],
            options: [
                LearnedOption(name: "-d, --invented DELIMITER", short: "",
                              description: "Set delimiter", argument: "DELIMITER",
                              takesFilePath: false, isOptional: false),
            ],
            argument: "",
            takesFilePath: false,
            isOptional: false)
        let kept = SpecLearner.specModule(command: "csvclean", from: invented, help: help)
            .flatMap(json)?["options"] as? [[String: Any]]
        check("split flag still requires help containment",
              kept?.first?["name"] as? String == "-d")

        let conflated = LearnedSpec(
            description: "CSV cleaner",
            subcommands: [],
            options: [
                LearnedOption(name: "-d, -q, --delimiter, --quiet", short: "",
                              description: "Set delimiter", argument: "DELIMITER",
                              takesFilePath: false, isOptional: false),
            ],
            argument: "",
            takesFilePath: false,
            isOptional: false)
        let capped = SpecLearner.specModule(
            command: "csvclean", from: conflated,
            help: "  -d, --delimiter DELIMITER  Set delimiter\n  -q, --quiet  Be quiet"
        ).flatMap(json)?["options"] as? [[String: Any]]
        check("conflated flags keep one short and one long form",
              capped?.first?["name"] as? [String] == ["-d", "--delimiter"])
    }

    static func argumentShape() {
        let learned = LearnedSpec(
            description: "CSV cleaner",
            subcommands: [],
            options: [
                LearnedOption(name: "--help", short: "",
                              description: "Show help", argument: "",
                              takesFilePath: false, isOptional: false),
            ],
            argument: "FILE",
            takesFilePath: true,
            isOptional: true)
        let module = SpecLearner.specModule(command: "csvclean", from: learned,
                                            help: "USAGE: csvclean [FILE]\n  --help  Show help")
        let args = module.flatMap(json)?["args"] as? [String: Any]
        check("positional file argument gets filepaths template", args?["template"] as? String == "filepaths")
        check("positional optional argument is optional", args?["isOptional"] as? Bool == true)

        var required = learned
        required.argument = "INPUT"
        let requiredArgs = SpecLearner.specModule(
            command: "csvclean", from: required,
            help: "USAGE: csvclean INPUT\n  --help  Show help"
        ).flatMap(json)?["args"] as? [String: Any]
        check("unbracketed positional is not optional", requiredArgs?["isOptional"] == nil)

        let count = LearnedSpec(
            description: "Counter",
            subcommands: [],
            options: [
                LearnedOption(name: "--count", short: "", description: "Set count",
                              argument: "COUNT", takesFilePath: true, isOptional: false),
            ],
            argument: "",
            takesFilePath: false,
            isOptional: false)
        let countArgs = SpecLearner.specModule(
            command: "counter", from: count, help: "  --count COUNT  Set count"
        ).flatMap(json)?["options"] as? [[String: Any]]
        check("hallucinated file path on COUNT is dropped",
              (countArgs?.first?["args"] as? [String: Any])?["template"] == nil)

        let output = LearnedSpec(
            description: "Writer",
            subcommands: [],
            options: [
                LearnedOption(name: "--output", short: "", description: "Write output",
                              argument: "OUTPUT_FILE", takesFilePath: true, isOptional: false),
            ],
            argument: "",
            takesFilePath: false,
            isOptional: false)
        let outputArgs = SpecLearner.specModule(
            command: "writer", from: output,
            help: "  --output <OUTPUT_FILE>  Write output"
        ).flatMap(json)?["options"] as? [[String: Any]]
        check("corroborated option file path is kept",
              (outputArgs?.first?["args"] as? [String: Any])?["template"] as? String == "filepaths")
    }

    static func coverage() {
        let learned = LearnedSpec(
            description: "CSV cleaner",
            subcommands: [],
            options: [
                LearnedOption(name: "--help", short: "",
                              description: "Show help", argument: "",
                              takesFilePath: false, isOptional: false),
            ],
            argument: "",
            takesFilePath: false,
            isOptional: false)
        let help = "  --help  Show help\n  --version  Show version"
        let coverage = SpecLearner.optionCoverage(from: learned, help: help)
        check("under-covered help has incomplete coverage",
              coverage.ratio == 0.5 && coverage.isIncomplete)

        let ffmpegHelp = """
              -h      show help
              -h long show more help
              -h full show all help
              -h type show help for a type
            """
        var ffmpeg = learned
        ffmpeg.options[0].name = "-h"
        let ffmpegCoverage = SpecLearner.optionCoverage(from: ffmpeg, help: ffmpegHelp)
        check("repeated argument variants count as one documented flag",
              ffmpegCoverage.surviving == 1
                  && ffmpegCoverage.documented == 1
                  && !ffmpegCoverage.isIncomplete)
    }

    /// A help text that documents `--version` alone contains the characters of an
    /// invented `-v`, so only a word match keeps the invention out.
    static func shortFlags() {
        check("a flag inside a longer flag is not documented",
              !SpecLearner.documented("-v", in: "  --version    Print the version"))
        check("a flag written on its own is documented",
              SpecLearner.documented("-v", in: "  -v, --verbose    Say more"))
        check("a flag before its value is documented",
              SpecLearner.documented("--out", in: "  --out=FILE   Write there"))
        check("a subcommand inside a longer word is not documented",
              !SpecLearner.documented("build", in: "  rebuild   Build it again"))

        let invented = LearnedSpec(
            description: "Fake tool for tests",
            subcommands: [],
            options: [LearnedOption(name: "--version", short: "-v",
                                    description: "Print the version", argument: "",
                                    takesFilePath: false, isOptional: false)],
            argument: "",
            takesFilePath: false,
            isOptional: false)
        guard let module = SpecLearner.specModule(command: "faketool", from: invented,
                                                  help: "  --version    Print the version"),
              let spec = json(of: module) else {
            check("invented short flag still serializes", false)
            return
        }
        check("an invented short flag is dropped",
              (spec["options"] as? [[String: Any]] ?? []).first?["name"] as? String == "--version")
    }

    /// The help text is untrusted, so the model's description is too: it must land
    /// in the file as a JSON string and nowhere else. `;` `{` `}` are what the
    /// loader's ESM→CJS rewrite keys on, so none may survive into the file.
    static func injection() {
        let attack = "x}; import evil; export default {name:\"pwn\"}; //"
        guard let module = SpecLearner.specModule(command: "faketool",
                                                  from: sample(description: attack),
                                                  help: helpText),
              let spec = json(of: module) else {
            check("hostile description still serializes", false)
            return
        }
        // What the loader's ESM→CJS rewrite keys on: `import`/`export` preceded by a
        // statement boundary (file start, newline, `;` or `}`). Exactly one may
        // match — the module's own `export default`.
        let boundary = try? NSRegularExpression(pattern: "(^|[\\n;}])\\s*(import|export)\\s")
        let statements = boundary?.numberOfMatches(
            in: module, range: NSRange(module.startIndex..., in: module)) ?? -1
        check("only the module's own export is a statement", statements == 1)

        let description = spec["description"] as? String ?? ""
        check("the attack text survives as data", description.contains("import evil"))
        check("description carries no statement boundary",
              !description.contains(";") && !description.contains("}"))
        check("braces in the file are all structural",
              module.components(separatedBy: "}").count == module.components(separatedBy: "{").count)
    }

    static let helpText = """
        faketool 1.0 — a tool that does not exist

        USAGE:
            faketool [OPTIONS] <PATH> [COMMAND]

        COMMANDS:
            build     Build the project
            clean     Remove build output

        OPTIONS:
            -v, --verbose        Print more output
            -o, --out <FILE>     Write the result to FILE
                --dry-run        Do nothing, print what would happen
            -h, --help           Print help
        """

    static func endToEnd(root: String) {
        if let reason = SpecLearner.unavailableReason() {
            print("SKIP  end-to-end learn: \(reason)")
            finish()
        }
        let fm = FileManager.default
        let bin = "\(root)/bin"
        try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let tool = "\(bin)/faketool"
        try? "#!/bin/sh\ncat <<'EOF'\n\(helpText)\nEOF\n".write(toFile: tool, atomically: true,
                                                                encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        // The app learns the shell's PATH from the prompt feed; the fake CLI lives
        // only in the scratch bin, so this also proves that plumbing.
        CommandRunner.setShellPath("\(bin):/usr/bin:/bin")

        let specs = "\(root)/specs"
        try? fm.removeItem(atPath: specs)
        Task { @MainActor in
            let learner = SpecLearner(localSpecsDirs: [specs], packDir: "\(root)/pack")
            check("learn starts", learner.learn(command: "faketool", force: false) == "started")
            check("a second learn is told which command is running",
                  learner.learn(command: "othertool", force: false) == "busy:faketool")
            while case .running = learner.status {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            report(learner: learner,
                   path: SpecLearner.destination(command: "faketool", in: specs))
        }
        dispatchMain()
    }

    @MainActor
    static func failure(of learner: SpecLearner) -> String {
        guard case .failed(let message) = learner.status else { return "" }
        return message
    }

    @MainActor
    static func report(learner: SpecLearner, path: String) -> Never {
        guard case .done(let written, let partial, let coverage) = learner.status else {
            check("end-to-end learn succeeded (\(learner.status))", false)
            finish()
        }
        check("spec written to extend/", written == path)
        check("a short help is not reported as partial", !partial)
        check("complete option coverage is not reported as incomplete", !coverage.isIncomplete)
        let module = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        print("--- \(path)\n\(module)---")
        guard let spec = json(of: module) else {
            check("learned spec is one JSON value", false)
            finish()
        }
        check("learned spec names the command", spec["name"] as? String == "faketool")
        let flags = (spec["options"] as? [[String: Any]] ?? []).flatMap { option -> [String] in
            if let one = option["name"] as? String { return [one] }
            return option["name"] as? [String] ?? []
        }
        check("learned --verbose", flags.contains("--verbose"))
        check("learned --out", flags.contains("--out"))
        let subcommands = (spec["subcommands"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        check("learned the build subcommand", subcommands.contains("build"))

        _ = learner.learn(command: "faketool", force: false)
        check("a learned command is not learned again by accident",
              failure(of: learner).contains("was learned already"))

        try? "export default { name: \"faketool\" };\n".write(toFile: path, atomically: true,
                                                              encoding: .utf8)
        _ = learner.learn(command: "faketool", force: true)
        check("--force never overwrites a spec tine did not write",
              failure(of: learner).contains("your own spec"))
        finish()
    }
}

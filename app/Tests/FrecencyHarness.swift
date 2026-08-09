// Frecency/HistoryIgnore harness. There is no Swift test target yet, so build it
// against the sources and run it with a scratch root:
//
//   swiftc -o /private/tmp/tine-harness/harness app/Tests/FrecencyHarness.swift \
//       app/Sources/tine/Frecency.swift app/Sources/tine/Log.swift
//   FREC_HOME=/private/tmp/tine-harness /private/tmp/tine-harness/harness
//
// The matcher expectations below are zsh's own answers, generated with
// `[[ "$line" == ${~pattern} ]]` under `zsh -f`.

import Foundation

@main
enum FrecencyHarness {
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
        // The harness writes fixtures, so it must never run against real user data.
        let root = ProcessInfo.processInfo.environment["FREC_HOME"] ?? ""
        guard root.hasPrefix("/private/tmp/") || root.hasPrefix("/var/folders/") else {
            let msg = "refusing to run outside /private/tmp or /var/folders: \(root)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        matcher()
        pool(root: root)
        print("\n\(pass) passed, \(fail) failed")
        exit(fail == 0 ? 0 : 1)
    }

    static func matcher() {
        let oracle: [(String, String, Bool)] = [
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
        for (pattern, line, want) in oracle {
            check("zsh oracle: [\(pattern)] vs [\(line)] -> \(want)",
                  HistoryIgnore(pattern).matches(line) == want)
        }

        // Deliberate widening: the bounds of a numeric range are dropped, so this
        // ignores a line zsh would keep. Over-dropping is the safe direction.
        check("widened: [secret<1-9>] vs [secret12] (zsh: no)",
              HistoryIgnore("secret<1-9>").matches("secret12"))

        // Documented as untranslated: the pattern matches nothing, so history stays.
        let unsupported: [(String, String)] = [
            ("^ls", "rm"),                     // extendedglob negation (literal here)
            ("(#i)LS*", "ls -la"),             // extendedglob case-insensitive flag
            ("ls##", "lsls"),                  // extendedglob repetition
            ("a[b", "a[b"),                    // zsh: bad pattern
            ("x)", "x)"),                      // unbalanced
        ]
        for (pattern, line) in unsupported {
            check("unsupported filters nothing: [\(pattern)] vs [\(line)]",
                  !HistoryIgnore(pattern).matches(line))
        }
        check("empty pattern filters nothing", !HistoryIgnore("").matches("anything"))
        check("source round-trips", HistoryIgnore("(ls|cd)").source == "(ls|cd)")
        check("compiled flag is set", HistoryIgnore("(ls|cd)").isCompiled)
        check("compiled flag is clear for an unbalanced pattern", !HistoryIgnore("x)").isCompiled)
    }

    static func pool(root: String) {
        let dir = root + "/pool-fixture"
        try? FileManager.default.removeItem(atPath: dir)
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

        let frecency = Frecency(historyPath: fixture)
        func value(_ cmd: String, _ flag: String, _ v: String) -> Bool {
            frecency.valueIndex[cmd]?[flag]?[v] != nil
        }
        func param(_ cmd: String, _ p: String) -> Bool { frecency.index[cmd]?[p] != nil }

        check("first pattern is a change", frecency.setHistoryIgnore("zz-no-match"))
        check("pool: docker -p 8080:8080", value("docker", "-p", "8080:8080"))
        check("pool: secret-tool --host db.example.com", value("secret-tool", "--host", "db.example.com"))
        check("pool: ssh alice@host.example.com", value("ssh", "", "alice@host.example.com"))
        check("pool: deploy --url https://api.example.com/v1", value("deploy", "--url", "https://api.example.com/v1"))
        check("params: docker run", param("docker", "run"))
        check("an over-long line is skipped whole", !value("huge", "--host", "over.example.com"))

        check("ignoring secret-tool is a change", frecency.setHistoryIgnore("(secret-tool*)"))
        check("ignored line leaves the pool", !value("secret-tool", "--host", "db.example.com"))
        check("ignored line leaves the params", !param("secret-tool", "store"))
        check("other lines stay in the pool", value("docker", "-p", "8080:8080"))
        check("re-sending the same pattern is not a change", !frecency.setHistoryIgnore("(secret-tool*)"))

        check("nested-group pattern is a change", frecency.setHistoryIgnore("(docker|ssh)*"))
        check("nested group drops docker", !value("docker", "-p", "8080:8080"))
        check("nested group drops ssh", !value("ssh", "", "alice@host.example.com"))
        check("nested group keeps secret-tool", value("secret-tool", "--host", "db.example.com"))

        check("numeric range is a change", frecency.setHistoryIgnore("*<->:<->*"))
        check("numeric range drops the port mapping line", !value("docker", "-p", "8080:8080"))
        check("numeric range keeps the rest", value("ssh", "", "alice@host.example.com"))

        check("clearing the pattern is a change", frecency.setHistoryIgnore(""))
        check("cleared: docker is back", value("docker", "-p", "8080:8080"))
        check("cleared: secret-tool is back", value("secret-tool", "--host", "db.example.com"))
        check("cleared twice is not a change", !frecency.setHistoryIgnore(""))

        // The pool is memory-only: the rebuild wrote nothing next to the fixture.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        check("no store written by the rebuild", leftovers == ["zsh_history"])
    }
}

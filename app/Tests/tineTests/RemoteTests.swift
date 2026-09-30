import Foundation
import Testing

private func suggestionScript(_ items: String) -> String {
    """
    globalThis.tineResetSpecs = function() {};
    globalThis.tineSuggest = function(line, cursor, cwd, cb) { cb({items: \(items)}); };
    """
}

private func item(_ name: String, description: String = "''") -> String {
    "{name: '\(name)', description: \(description), insertValue: '\(name)', shouldAddSpace: true, "
        + "type: 'arg', queryTerm: '', isDangerous: false, matchIndices: []}"
}

private func writeEngine(_ script: String, in dir: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try script.write(toFile: dir + "/tine-engine.js", atomically: true, encoding: .utf8)
}

private final class FakePanel: RemotePanel {
    var panelIsVisible = false
    var calls: [String] = []

    func record(feed: Request) { calls.append("record \(feed.session)") }
    func present(over app: pid_t, buffer: String) {
        calls.append("present \(app)")
        panelIsVisible = true
    }
    func dismissPanel() {
        calls.append("dismiss")
        panelIsVisible = false
    }
    func scheduleIdleHide() { calls.append("idleHide") }
    func relayoutPanel() { calls.append("relayout") }
}

/// One local shell (pid 1001, in terminal app 100) that ran `tine ssh`.
private final class Fixture {
    let local: pid_t = 1001
    let root = Scratch.dir("remote-router")
    let panel = FakePanel()
    let state = AppState(persists: false)
    var frontmost: pid_t = 100
    var alive: Set<pid_t> = [1001]
    lazy var tokens = RemoteSessions(isAlive: { [unowned self] in self.alive.contains($0) })
    lazy var sessions = SessionOwnership(
        frontmostPID: { [unowned self] in self.frontmost },
        terminalPID: { [unowned self] in $0 == self.local ? 100 : nil },
        isRunningApp: { _ in true })
    lazy var router = RemoteRouter(state: state, sessions: sessions, tokens: tokens,
                                   panel: panel, version: "9.9.9")
    lazy var token = tokens.begin(session: local) ?? ""

    init() throws {
        try writeEngine(suggestionScript("[\(item("local-secret"))]"), in: root + "/local")
        try writeEngine(suggestionScript("[\(item("remote-a")), \(item("remote-b"))]"), in: root + "/remote")
        state.engine = JSEngine(specsDir: root + "/specs", localSpecsDirs: [],
                                resourcesDir: root + "/local", logPath: root + "/tine.log")
        state.remoteEngine = JSEngine.remote(specsDir: root + "/specs", resourcesDir: root + "/remote",
                                             logPath: root + "/tine.log")
    }

    func line(_ verb: String, _ buffer: String = "git ", token: String? = nil) -> String {
        [token ?? self.token, verb, "\(buffer.count)", "/home/me", "1;1;80;24;0;0;4242", buffer]
            .joined(separator: TINE_US)
    }
}

struct RemoteSessionsTests {
    @Test func beginMintsA128BitHexTokenMappedToTheSession() {
        let tokens = RemoteSessions(isAlive: { _ in true })
        let token = tokens.begin(session: 1001)
        #expect(token?.count == 32)
        #expect(token?.allSatisfy { "0123456789abcdef".contains($0) } == true)
        #expect(token.flatMap(tokens.session(for:)) == 1001)
        #expect(tokens.begin(session: 1001) != token)
    }

    @Test func beginRefusesASessionThatCouldNeverBeOwnedAlone() {
        let tokens = RemoteSessions(isAlive: { _ in true })
        #expect(tokens.begin(session: 0) == nil)
        #expect(tokens.begin(session: 1) == nil)
        #expect(tokens.count == 0)
    }

    @Test func endForgetsTheToken() throws {
        let tokens = RemoteSessions(isAlive: { _ in true })
        let token = try #require(tokens.begin(session: 1001))
        tokens.end(token: token)
        #expect(tokens.session(for: token) == nil)
        #expect(tokens.count == 0)
    }

    @Test func aDeadSessionIsPrunedOnLookupAndOnTheNextBegin() throws {
        var alive: Set<pid_t> = [1001, 2002]
        let tokens = RemoteSessions(isAlive: { alive.contains($0) })
        let first = try #require(tokens.begin(session: 1001))
        _ = try #require(tokens.begin(session: 2002))
        alive = [3003]
        #expect(tokens.session(for: first) == nil)
        #expect(tokens.count == 1)
        _ = tokens.begin(session: 3003)
        #expect(tokens.count == 1)
    }

    @Test func theDefaultLivenessCheckSeesThisProcess() throws {
        let tokens = RemoteSessions()
        let token = try #require(tokens.begin(session: getpid()))
        #expect(tokens.session(for: token) == getpid())
    }
}

struct RemoteRouterTests {
    static let localOnlyVerbs = [
        "path", "env", "aliases", "showDashboard", "install", "installStatus", "appUpdate",
        "appUpdateStatus", "appUpdateApply", "learn", "learnStatus", "ask", "index", "askStatus",
        "doctor", "toggleDetail", "sshBegin", "sshEnd", "", "bogus",
    ]

    @Test func anUnknownTokenIsClosedBeforeAnyParsing() throws {
        let f = try Fixture()
        _ = f.token
        #expect(f.router.respond(to: f.line("update", token: String(repeating: "0", count: 32))) == nil)
        #expect(f.router.respond(to: f.line("version", token: "")) == nil)
        #expect(f.router.respond(to: "update") == nil)
        #expect(f.panel.calls.isEmpty)
        #expect(f.state.buffer.isEmpty)
    }

    @Test(arguments: localOnlyVerbs)
    func everyVerbOffTheAllowlistAnswersZeroAndTouchesNothing(verb: String) throws {
        let f = try Fixture()
        let shellPath = CommandRunner.shellPath()
        let showDetail = f.state.config.showDetail
        let payload = "/evil/bin\(TINE_RS)ls=rm -rf\(TINE_RS)*"
        #expect(f.router.respond(to: f.line(verb, payload)) == "0")
        #expect(f.panel.calls.isEmpty)
        #expect(f.state.buffer.isEmpty)
        #expect(f.state.frecencySnapshot.isEmpty)
        #expect(f.state.config.showDetail == showDetail)
        #expect(CommandRunner.shellPath() == shellPath)
        #expect(f.tokens.count == 1)
    }

    @Test func versionIsAnswered() throws {
        let f = try Fixture()
        #expect(f.router.respond(to: f.line("version", "")) == "9.9.9")
    }

    @Test func anUpdateIsOwnedByTheMappedLocalSessionAndUsesTheRemoteEngine() throws {
        let f = try Fixture()
        #expect(f.router.respond(to: f.line("update")) == "2")
        #expect(f.sessions.owner == f.local)
        #expect(f.panel.calls == ["record \(f.local)", "present 100"])
        #expect(f.state.showsRemote)
        #expect(f.state.suggestions.map(\.name) == ["remote-a", "remote-b"])
        f.state.recompute()
        #expect(f.state.suggestions.map(\.name) == ["remote-a", "remote-b"])
        #expect(f.state.frecencySnapshot.isEmpty)
    }

    @Test func anUpdateWhileTheMappedTerminalIsNotFrontmostIsIgnored() throws {
        let f = try Fixture()
        f.frontmost = 300
        #expect(f.router.respond(to: f.line("update")) == "0")
        #expect(f.sessions.owner == nil)
        #expect(f.panel.calls.isEmpty)
    }

    @Test func aDeadLocalSessionClosesItsToken() throws {
        let f = try Fixture()
        _ = f.token
        f.alive = []
        #expect(f.router.respond(to: f.line("update")) == nil)
        #expect(f.tokens.count == 0)
    }

    @Test func navigationAndAcceptDriveTheRemoteSuggestions() throws {
        let f = try Fixture()
        _ = f.router.respond(to: f.line("update"))
        #expect(f.router.respond(to: f.line("down")) == "2")
        #expect(f.router.respond(to: f.line("up")) == "2")
        #expect(f.router.respond(to: f.line("up")) == "PASS")
        #expect(f.router.respond(to: f.line("accept")) == "13\(TINE_US)git remote-a ")
        #expect(f.panel.calls.last == "dismiss")
        #expect(f.state.frecencySnapshot.isEmpty)
    }

    @Test func localSuggestionsAreNeverServedToTheRemote() throws {
        let f = try Fixture()
        _ = f.token
        let feed = FeedMessage(cursor: 4, cwd: "/home/me", buffer: "git ")
        _ = f.sessions.admit(session: f.local, feed)
        f.state.update(feed)
        f.panel.panelIsVisible = true
        #expect(f.state.suggestions.map(\.name) == ["local-secret"])
        #expect(f.router.respond(to: f.line("accept")) == "")
        #expect(f.router.respond(to: f.line("prefix")) == "")
        #expect(f.router.respond(to: f.line("down")) == "PASS")
    }

    @Test func aRemoteUpdateMatchingTheLocalLineStillRecomputesRemotely() throws {
        let f = try Fixture()
        let feed = FeedMessage(cursor: 4, cwd: "/home/me", buffer: "git ")
        f.state.update(feed)
        _ = f.router.respond(to: f.line("update"))
        #expect(f.state.suggestions.map(\.name) == ["remote-a", "remote-b"])
        f.state.update(feed)
        #expect(f.state.suggestions.map(\.name) == ["local-secret"])
    }

    @Test func dismissOnlyHidesThePanelTheSessionOwns() throws {
        let f = try Fixture()
        #expect(f.router.respond(to: f.line("dismiss")) == "0")
        #expect(f.panel.calls.isEmpty)
        _ = f.router.respond(to: f.line("update"))
        #expect(f.router.respond(to: f.line("dismiss")) == "0")
        #expect(f.panel.calls.last == "dismiss")
    }
}

struct RemoteEngineTests {
    @Test func theRemoteEngineRunsNothingAndReadsOnlyTheSpecPack() throws {
        let root = Scratch.dir("remote-engine")
        let specs = root + "/specs"
        try FileManager.default.createDirectory(atPath: specs, withIntermediateDirectories: true)
        try "inside".write(toFile: specs + "/git.js", atomically: true, encoding: .utf8)
        try "outside".write(toFile: root + "/secret.js", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: specs + "/link.js", withDestinationPath: root + "/secret.js")
        let marker = root + "/ran"
        let reads = [specs + "/git.js", root + "/secret.js", specs + "/../secret.js", specs + "/link.js"]
            .map { "__tineReadFile('\($0)')" }.joined(separator: " + '|' + ")
        let run = "JSON.parse(__tineRun(JSON.stringify({executable: '/usr/bin/touch', args: ['\(marker)']}))).exitCode"
        try writeEngine(suggestionScript(
            "[\(item("run", description: "String(\(run))")), \(item("read", description: reads)), "
                + "\(item("home", description: "'[' + __tineHome + ']'"))]"), in: root + "/resources")

        let engine = JSEngine.remote(specsDir: specs, resourcesDir: root + "/resources", logPath: root + "/tine.log")
        let described = engine.suggest(line: "git ", cursor: 4, cwd: root).map(\.description)

        #expect(described == ["1", "inside|||", "[]"])
        Thread.sleep(forTimeInterval: 0.5)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
}

struct RemoteSocketTests {
    @Test func theListenerSocketIsOwnerOnly() throws {
        let path = Scratch.dir("remote-socket") + "/remote.sock"
        let server = SocketServer(path: path) { _ in nil }
        #expect(server.start())
        let mode = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
    }

    @Test func aLimitedListenerDropsAnOversizedLineAndASilentClient() throws {
        let path = Scratch.dir("remote-limits") + "/remote.sock"
        let server = SocketServer(path: path, limits: .init(maxLineBytes: 16, readTimeoutSeconds: 1)) { _ in
            Issue.record("a dropped connection must never reach respond")
            return "0"
        }
        #expect(server.start())

        let connect = { () -> Int32 in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                path.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count - 1))) }
            }
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(connected == 0)
            return fd
        }

        let oversized = connect()
        var line = Array(String(repeating: "x", count: 64).utf8)
        _ = write(oversized, &line, line.count)
        var byte: UInt8 = 0
        #expect(read(oversized, &byte, 1) == 0)
        close(oversized)

        let silent = connect()
        let started = Date()
        #expect(read(silent, &byte, 1) == 0)
        #expect(Date().timeIntervalSince(started) < 5)
        close(silent)
    }
}

// Session-ownership harness. Build it against the sources and run it with a
// scratch root:
//
//   swiftc -o /private/tmp/tine-harness/session app/Tests/SessionHarness.swift \
//       app/Sources/tine/SessionOwnership.swift app/Sources/tine/SocketServer.swift \
//       app/Sources/tine/FeedMessage.swift app/Sources/tine/SocketSafe.swift
//   TINE_TEST_ROOT=/private/tmp/tine-harness /private/tmp/tine-harness/session
//
// It runs the real SocketServer over a real unix socket and the real
// SessionOwnership; only the frontmost app, the shell→terminal mapping and the
// panel are stubbed (the panel model below mirrors App.swift's update branch).

import AppKit

@main
enum SessionHarness {
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

    // Stubbed world: which app is frontmost, which terminal each shell runs in,
    // and which terminals are still running.
    static var frontmost: pid_t = 100
    static var terminals: [pid_t: pid_t] = [:]
    static var running: Set<pid_t> = []
    static let sessions = SessionOwnership(frontmostPID: { frontmost },
                                           terminalPID: { terminals[$0] },
                                           isRunningApp: { running.contains($0) })

    // Panel model: what App.swift does with a verdict.
    static var visible = false
    static var placedOver: pid_t?
    static var line = ""

    static func dismiss() {
        visible = false
        placedOver = nil
        sessions.disown()
    }

    static func handle(_ req: Request) -> String {
        switch req.type {
        case "update":
            let feed = FeedMessage(cursor: req.cursor, cwd: req.cwd, buffer: req.buffer)
            guard let verdict = sessions.admit(session: req.session, feed) else { return "0" }
            line = req.buffer
            let hasContent = !req.buffer.isEmpty // stands in for the engine
            if verdict.changed, let app = verdict.appPID {
                if hasContent {
                    visible = true
                    placedOver = app
                } else {
                    dismiss()
                }
            } else if req.buffer.isEmpty || !hasContent {
                dismiss()
            }
            return hasContent ? "1" : "0"
        case "accept":
            if !visible || !sessions.isOwner(req.session) { return "" }
            let accepted = line
            dismiss()
            return accepted
        case "dismiss":
            if sessions.isOwner(req.session) { dismiss() }
            return "0"
        case "echo":
            return "\(req.session)|\(req.cellH)|\(req.buffer)"
        default:
            return "0"
        }
    }

    static func main() {
        let root = ProcessInfo.processInfo.environment["TINE_TEST_ROOT"] ?? ""
        guard root.hasPrefix("/private/tmp/") || root.hasPrefix("/var/folders/") else {
            let msg = "refusing to run outside /private/tmp or /var/folders: \(root)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let sock = root + "/session-harness.sock"
        let server = SocketServer(path: sock, handler: handle)
        server.start()

        // The server hands each request to the main thread, so the scenarios run
        // off it and the main run loop stays free to service them.
        DispatchQueue.global().async {
            scenarios(sock: sock)
            print("\n\(pass) passed, \(fail) failed")
            exit(fail == 0 ? 0 : 1)
        }
        RunLoop.main.run()
    }

    // MARK: - scenarios

    static let a: pid_t = 1001 // shell in terminal app 100
    static let b: pid_t = 2002 // shell in terminal app 200

    static func scenarios(sock: String) {
        terminals = [a: 100, b: 200]
        running = [100, 200, 300, 400, 500]

        frontmost = 100
        check("A types: panel presents over A's terminal",
              update(sock, a, "gi", cursor: 2) == "1" && visible && placedOver == 100)
        check("A owns the panel", sessions.owner == a)

        // A background shell redraws with a changed buffer while a third app is
        // frontmost: the reported bug.
        frontmost = 300
        check("B redraws with a changed line, third app frontmost: ignored",
              update(sock, b, "ls -l", cursor: 5) == "0")
        check("panel stays up", visible)
        check("panel did not move", placedOver == 100)
        check("A still owns the panel", sessions.owner == a)

        check("B redraws with an empty line: does not dismiss",
              update(sock, b, "", cursor: 0) == "0" && visible && sessions.owner == a)

        // Even with B's own terminal frontmost, a redraw that repeats B's last
        // line is not an edit, so it cannot take the panel.
        frontmost = 200
        check("B repeats its line while its terminal is frontmost: ignored",
              update(sock, b, "", cursor: 0) == "0")
        check("A still owns the panel", visible && placedOver == 100 && sessions.owner == a)

        // A's own redraw (unchanged line) keeps the panel where it is.
        frontmost = 100
        check("A redraws unchanged: panel stays",
              update(sock, a, "gi", cursor: 2) == "1" && visible && placedOver == 100)

        // A non-owner's Enter must not consume the owner's line.
        check("B cannot accept A's line", request(sock, "accept", session: b, buffer: "") == "")
        check("B's line-finish cannot dismiss A's panel",
              request(sock, "dismiss", session: b, buffer: "") == "0" && visible)

        // B edits while its own terminal is frontmost: ownership transfers.
        frontmost = 200
        check("B edits with its terminal frontmost: takes over",
              update(sock, b, "ls -la", cursor: 6) == "1")
        check("panel moved to B's terminal", visible && placedOver == 200)
        check("B owns the panel", sessions.owner == b)
        check("A cannot accept B's line", request(sock, "accept", session: a, buffer: "") == "")
        check("B accepts its own line", request(sock, "accept", session: b, buffer: "") == "ls -la")
        check("accepting disowns the panel", !visible && sessions.owner == nil)

        // A shell with no application ancestor (tmux, ssh) keeps the old
        // frontmost-app behaviour.
        let t: pid_t = 3003
        frontmost = 300
        check("a session with no terminal ancestor still presents",
              update(sock, t, "top", cursor: 3) == "1" && visible && placedOver == 300)
        check("it owns the panel", sessions.owner == t)
        _ = request(sock, "dismiss", session: t, buffer: "")

        // A shell that predates the session id sends six positioning fields.
        frontmost = 300
        check("legacy shell (no session id) presents as before",
              legacyUpdate(sock, "hi") == "1" && visible && placedOver == 300)
        check("legacy shell owns the panel as session 0", sessions.owner == 0)
        check("a new-protocol shell cannot accept the legacy line",
              request(sock, "accept", session: b, buffer: "") == "")
        check("the legacy shell can", request(sock, "accept", session: 0, buffer: "") == "hi")

        // A shell exits, its terminal quits, and the OS hands the pid to a shell
        // in another terminal: the cached mapping must not outlive the terminal.
        let reused: pid_t = 4004
        terminals[reused] = 400
        frontmost = 400
        check("a shell in terminal 400 presents there",
              update(sock, reused, "vim", cursor: 3) == "1" && placedOver == 400)
        _ = request(sock, "dismiss", session: reused, buffer: "")
        running.remove(400)
        terminals[reused] = 500
        frontmost = 500
        check("the same pid, reused in terminal 500, presents there",
              update(sock, reused, "vimrc", cursor: 5) == "1" && placedOver == 500)
        check("it owns the panel", sessions.owner == reused)
        _ = request(sock, "dismiss", session: reused, buffer: "")

        parsing(sock: sock)
    }

    /// The wire compat story, over the real parser.
    static func parsing(sock: String) {
        check("six positioning fields read as session 0",
              reply(sock, "echo\u{1f}0\u{1f}/tmp\u{1f}1;1;80;24;0;30\u{1f}x") == "0|30|x")
        check("seven carry the session",
              reply(sock, "echo\u{1f}0\u{1f}/tmp\u{1f}1;1;80;24;0;30;4242\u{1f}x") == "4242|30|x")
        check("an eighth field is ignored",
              reply(sock, "echo\u{1f}0\u{1f}/tmp\u{1f}1;1;80;24;0;30;4242;9\u{1f}x") == "4242|30|x")
        check("a buffer containing US survives the added field",
              reply(sock, "echo\u{1f}0\u{1f}/tmp\u{1f}1;1;80;24;0;30;4242\u{1f}a\u{1f}b") == "4242|30|a\u{1f}b")
        check("a garbage session reads as 0",
              reply(sock, "echo\u{1f}0\u{1f}/tmp\u{1f}1;1;80;24;0;30;99999999999\u{1f}x") == "0|30|x")
        check("a negative session reads as 0",
              reply(sock, "echo\u{1f}0\u{1f}/tmp\u{1f}1;1;80;24;0;30;-1\u{1f}x") == "0|30|x")
        check("the short (pre-positioning) form still parses",
              reply(sock, "echo\u{1f}0\u{1f}/tmp\u{1f}x") == "0|0|x")
    }

    // MARK: - client

    static func update(_ sock: String, _ session: pid_t, _ buffer: String, cursor: Int) -> String {
        request(sock, "update", session: session, buffer: buffer, cursor: cursor)
    }

    static func legacyUpdate(_ sock: String, _ buffer: String) -> String {
        reply(sock, "update\u{1f}\(buffer.count)\u{1f}/tmp\u{1f}1;1;80;24;0;30\u{1f}\(buffer)")
    }

    static func request(_ sock: String, _ type: String, session: pid_t,
                        buffer: String, cursor: Int = 0) -> String {
        reply(sock, "\(type)\u{1f}\(cursor)\u{1f}/tmp\u{1f}1;1;80;24;0;30;\(session)\u{1f}\(buffer)")
    }

    /// One request over the real socket; returns the reply line.
    static func reply(_ path: String, _ request: String) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "<socket failed>" }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let size = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cs in
                _ = strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cs, size - 1)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard ok == 0 else { return "<connect failed>" }
        var out = Array((request + "\n").utf8)
        _ = write(fd, &out, out.count)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        readLoop: while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            for i in 0..<n {
                if chunk[i] == 0x0a { break readLoop }
                data.append(chunk[i])
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

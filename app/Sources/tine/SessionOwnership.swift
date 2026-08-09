import AppKit

/// Which shell session drives the panel. Every message carries the shell's `$$`,
/// so one terminal tab can be told from another: a session takes the panel over
/// only by editing its own line while its terminal app is frontmost. A
/// background shell's async prompt redraw (p10k-class plugins, a `TMOUT` clock)
/// therefore can neither re-own, move, nor dismiss the panel.
final class SessionOwnership {
    struct Verdict {
        /// This session's own line changed — the panel may follow its caret.
        let changed: Bool
        /// The app to place the panel over, or nil when the session's terminal
        /// isn't frontmost.
        let appPID: pid_t?
    }

    /// The session holding the panel. Shells that predate the session id send 0
    /// and are always treated as the owner, keeping the old global behaviour.
    private(set) var owner: pid_t?
    private var lines: [pid_t: FeedMessage] = [:]
    private var apps: [pid_t: pid_t] = [:] // 0 = no application ancestor
    private let frontmostPID: () -> pid_t?
    private let terminalPID: (pid_t) -> pid_t?
    private let isRunningApp: (pid_t) -> Bool

    init(frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         terminalPID: @escaping (pid_t) -> pid_t? = SessionOwnership.applicationAncestor(of:),
         isRunningApp: @escaping (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0) != nil }) {
        self.frontmostPID = frontmostPID
        self.terminalPID = terminalPID
        self.isRunningApp = isRunningApp
    }

    func isOwner(_ session: pid_t) -> Bool { session == 0 || session == owner }

    func disown() { owner = nil }

    /// Rule the update: nil when it must not touch the panel at all.
    func admit(session: pid_t, _ msg: FeedMessage) -> Verdict? {
        let changed = lines[session].map {
            $0.buffer != msg.buffer || $0.cursor != msg.cursor || $0.cwd != msg.cwd
        } ?? true
        lines[session] = msg
        prune()
        let app = frontmostTerminal(of: session)
        // An empty line never earns the panel: a background shell's first redraw
        // would otherwise take it over and dismiss what the user has up.
        guard isOwner(session) || (changed && !msg.buffer.isEmpty && app != nil) else { return nil }
        if changed, app != nil { owner = session }
        return Verdict(changed: changed, appPID: app)
    }

    /// The app the panel may be placed over for this session: the frontmost one,
    /// but only when the session runs under it. A session with no application
    /// ancestor (tmux, ssh) can't be told apart that way and keeps the old
    /// frontmost-app behaviour.
    private func frontmostTerminal(of session: pid_t) -> pid_t? {
        let front = frontmostPID()
        guard let app = terminalApp(of: session) else { return front }
        return app == front ? front : nil
    }

    private func terminalApp(of session: pid_t) -> pid_t? {
        if let cached = apps[session] {
            // 0 = the walk found no application ancestor (tmux, ssh).
            if cached == 0 { return nil }
            // A cached terminal that has quit means the OS reused the pid for a
            // shell somewhere else: resolve it again rather than answer for a
            // terminal that is gone, which would leave that shell unable to ever
            // show the panel.
            if isRunningApp(cached) { return cached }
        }
        let found = terminalPID(session) ?? 0
        apps[session] = found
        return found == 0 ? nil : found
    }

    /// Forget shells that have exited, so a long-lived app doesn't accumulate
    /// their lines (and can't answer for a pid the OS has since reused).
    private func prune() {
        guard lines.count > 64 else { return }
        lines = lines.filter { kill($0.key, 0) == 0 }
        apps = apps.filter { lines[$0.key] != nil }
    }

    /// The nearest ancestor process that is a running application — the terminal
    /// the shell runs in. Nil under tmux or ssh, where the shell descends from a
    /// daemon instead of an app.
    static func applicationAncestor(of session: pid_t) -> pid_t? {
        let apps = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        var pid = session
        for _ in 0..<16 {
            if apps.contains(pid) { return pid }
            guard let parent = parentPID(of: pid), parent > 1 else { return nil }
            pid = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

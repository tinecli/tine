import AppKit

/// A session (identified by its shell's `$$`) takes over the panel only by editing its own
/// line while its terminal is frontmost — so a background shell's async prompt redraw
/// (p10k-class plugins, a `TMOUT` clock) can never re-own, move, or dismiss the panel.
final class SessionOwnership {
    struct Verdict {
        let changed: Bool
        let appPID: pid_t?
    }

    /// Shells that predate the session id send 0, which `isOwner` always treats as owning.
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

    func admit(session: pid_t, _ msg: FeedMessage) -> Verdict? {
        let changed = lines[session].map {
            $0.buffer != msg.buffer || $0.cursor != msg.cursor || $0.cwd != msg.cwd
        } ?? true
        lines[session] = msg
        prune()
        let app = frontmostTerminal(of: session)
        // A non-owner can't take over on an empty line, or a background shell's first
        // redraw would seize the panel and dismiss what the user has up.
        guard isOwner(session) || (changed && !msg.buffer.isEmpty && app != nil) else { return nil }
        if changed, app != nil { owner = session }
        return Verdict(changed: changed, appPID: app)
    }

    /// Under tmux or ssh there's no application ancestor to compare, so any frontmost app qualifies.
    private func frontmostTerminal(of session: pid_t) -> pid_t? {
        let front = frontmostPID()
        guard let app = terminalApp(of: session) else { return front }
        return app == front ? front : nil
    }

    private func terminalApp(of session: pid_t) -> pid_t? {
        if let cached = apps[session] {
            if cached == 0 { return nil }
            // Re-resolve rather than trust a cached terminal that has quit: the OS may have
            // reused its pid for something else, which would strand this shell without a panel.
            if isRunningApp(cached) { return cached }
        }
        let found = terminalPID(session) ?? 0
        apps[session] = found
        return found == 0 ? nil : found
    }

    /// `kill(pid, 0)` sends no signal — it only reports whether the pid is still alive.
    private func prune() {
        guard lines.count > 64 else { return }
        lines = lines.filter { kill($0.key, 0) == 0 }
        apps = apps.filter { lines[$0.key] != nil }
    }

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

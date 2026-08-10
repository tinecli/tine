import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var cancellables = Set<AnyCancellable>()
    /// Shared with the dashboard, so its "Install / Update Specs" button uses this
    /// same status guard and onInstalled refresh instead of installing behind the app's back.
    @MainActor let specInstaller = SpecInstaller()
    @MainActor let appUpdater = AppUpdater()
    @MainActor let specLearner = SpecLearner(
        packDir: ProcessInfo.processInfo.environment["TINE_SPECS_DIR"] ?? SpecInstaller.specsDir)
    @MainActor let asker = Asker(
        packDir: ProcessInfo.processInfo.environment["TINE_SPECS_DIR"] ?? SpecInstaller.specsDir)
    private var panel: SuggestionPanel?
    private var server: SocketServer?
    /// Captured once by WindowAccessor, so AppKit can reopen the dashboard directly —
    /// independent of the menu-bar item, which the user can hide.
    weak var dashboardWindow: NSWindow?
    private let frecency = Frecency()
    private var idleHide: DispatchWorkItem?
    private var sockPath = ""
    /// Whoever was frontmost when the user last changed the line — only that app may
    /// have the panel placed over it.
    private var ownerPID: pid_t?
    private let sessions = SessionOwnership()
    private var focusWatcher: AXFocusWatcher?
    /// Prompt-anchor cell + grid + cell size (device px), for computing the caret in
    /// canvas terminals (Ghostty) where AX can't.
    private var lastFeed: (anchorRow: Int, anchorCol: Int, cols: Int, rows: Int,
                           cellW: Int, cellH: Int, cursor: Int, buffer: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no dock icon
        TineLog.reset()
        Self.installShellIntegration()
        // With no dock/menu bar, opening the window here is opt-out via Settings —
        // closing it later just leaves the agent running.
        if state.config.openWindowAtStart {
            // Deferred until the MenuBarExtra bridge is mounted to receive the open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.openDashboard() }
        }
        let panel = SuggestionPanel(state: state)
        self.panel = panel

        let env = ProcessInfo.processInfo.environment
        // Fixed default: the input-method process can't see the shell's TINE_SOCK.
        let sockPath = env["TINE_SOCK"] ?? "\(NSHomeDirectory())/.local/share/tine/tine.sock"
        self.sockPath = sockPath
        try? FileManager.default.createDirectory(
            atPath: (sockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        let resources = Bundle.main.resourcePath ?? "."
        // Downloaded at runtime (SpecInstaller), not bundled; the engine reads it
        // lazily, so this works even if the download finishes after launch.
        let specsDir = env["TINE_SPECS_DIR"] ?? SpecInstaller.specsDir
        state.engine = JSEngine(specsDir: specsDir,
                                localSpecsDirs: state.config.localSpecsDirsExpanded,
                                resourcesDir: resources)

        // First run (or a wiped pack): download in the background, so suggestions are
        // just empty until it lands rather than blocking launch.
        specInstaller.onInstalled = { [weak self] in self?.scheduleRefresh() }
        if SpecInstaller.isInstalled() {
            SpecInstaller.refreshBuiltins()
            specInstaller.startChecking()
        } else {
            specInstaller.install()
        }
        appUpdater.start()

        state.engine?.setFirstTokenEnabled(state.config.firstTokenCompletion)
        specLearner.onLearned = { [weak self] in self?.state.engine?.resetSpecCache() }

        asker.validate = { [weak self] line in
            self?.state.engine?.validate(line: line) ?? .unchecked
        }
        asker.outline = { [weak self] tool in self?.state.engine?.outline(command: tool) ?? [] }
        asker.shellPath = { CommandRunner.shellPath() ?? "" }
        asker.frecency = { [weak self] in self?.frecency.commandScorer() ?? { _ in 0 } }

        // Bootstrapped off the main thread, then handed to the engine on the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.frecency.load()
            DispatchQueue.main.async {
                self.state.engine?.setFrecency(self.frecency.index)
                self.state.engine?.setHistoryValues(self.frecency.valueIndex)
            }
        }

        let server = SocketServer(path: sockPath) { [weak self] req in
            guard let self else { return "0" }
            switch req.type {
            case "update":
                let feed = FeedMessage(cursor: req.cursor, cwd: req.cwd, buffer: req.buffer)
                guard let verdict = self.sessions.admit(session: req.session, feed) else {
                    return "0"
                }
                self.lastFeed = (req.anchorRow, req.anchorCol, req.cols, req.rows,
                                 req.cellW, req.cellH, req.cursor, req.buffer)
                self.state.update(feed)
                if verdict.changed, let app = verdict.appPID {
                    // ownerPID only updates here: an async redraw from a background
                    // terminal reaches this handler too, but doesn't prove ownership.
                    self.ownerPID = app
                    self.reflectPanel(buffer: req.buffer)
                } else if req.buffer.isEmpty || !self.state.hasContent {
                    self.dismissPanel()
                } else {
                    self.scheduleIdleHide() // keep visible, don't move
                }
                // max(…, 1), not the raw count: a generator still loading has 0
                // suggestions yet, but Up/Down must stay bound to us for when they land.
                return "\(self.state.hasContent ? max(self.state.suggestions.count, 1) : 0)"
            case "up":
                // PASS lets the key reach zsh history: when the panel isn't showing, or
                // already at the top row, Up could otherwise never get there.
                if self.panel?.isVisible != true || self.state.selectedIndex == 0
                    || !self.sessions.isOwner(req.session) {
                    return "PASS"
                }
                self.state.moveSelection(-1)
                return "\(self.state.suggestions.count)"
            case "down":
                if self.panel?.isVisible != true || !self.sessions.isOwner(req.session) {
                    return "PASS"
                }
                self.state.moveSelection(1)
                return "\(self.state.suggestions.count)"
            case "accept":
                // This shell's _TINE_ACTIVE can be stale — the panel may have idle-hidden
                // or moved to another shell without it knowing. "" falls through to a
                // normal accept-line.
                if self.panel?.isVisible != true || !self.sessions.isOwner(req.session) {
                    return ""
                }
                // Fig's auto-execute row runs the line as-is instead of inserting.
                if self.state.selectedIsExecute {
                    self.dismissPanel()
                    return "EXEC"
                }
                if let (b, c) = self.state.accept() {
                    // "history" is re-logged by zsh already; "learn-it" isn't a usage pick.
                    if let name = self.state.selectedName,
                       self.state.selectedType != "history",
                       self.state.selectedType != "learn-it" {
                        let cmd = req.buffer.split(whereSeparator: { $0 == " " || $0 == "\t" })
                            .first.map(String.init) ?? ""
                        if let params = self.frecency.record(cmd: cmd, param: name) {
                            self.state.engine?.setFrecencyCommand(cmd, params: params)
                        }
                    }
                    self.dismissPanel()
                    return "\(c)\(TINE_US)\(b)"
                }
                return ""
            case "prefix":
                if self.panel?.isVisible != true || !self.sessions.isOwner(req.session) {
                    return ""
                }
                if let (b, c) = self.state.commonPrefix() {
                    return "\(c)\(TINE_US)\(b)"
                }
                return ""
            case "path":
                CommandRunner.setShellPath(req.buffer)
                return "0"
            case "showDashboard":
                self.openDashboard()
                return "0"
            case "install":
                self.specInstaller.install() // never blocks; shell polls `installStatus`
                return "started"
            case "installStatus":
                return self.specInstaller.statusLine
            case "appUpdate":
                self.appUpdater.check(manual: true) // never blocks; shell polls `appUpdateStatus`
                return "started"
            case "appUpdateStatus":
                return self.appUpdater.statusLine
            case "appUpdateApply":
                if let reason = self.appUpdater.applyAndRelaunch() { return reason.socketSafe }
                return "ok"
            case "learn":
                // buffer is "<cmd>" or "<cmd>" RS "force"; never blocks, shell polls `learnStatus`.
                let sections = req.buffer.components(separatedBy: TINE_RS)
                return self.specLearner.learn(command: sections.first ?? "",
                                              force: sections.count > 1 && sections[1] == "force")
            case "learnStatus":
                return self.specLearner.statusLine
            case "ask":
                return self.asker.ask(question: req.buffer) // never blocks; shell polls `askStatus`
            case "index":
                return self.asker.index()
            case "askStatus":
                return self.asker.statusLine
            case "version":
                return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
            case "doctor":
                let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
                let update = self.specInstaller.updateAvailable ? 1 : 0
                return "ax=\(AXCaret.isTrusted ? 1 : 0);specs=\(SpecInstaller.installedCount());"
                    + "version=\(v);update=\(update);"
                    + "appLatest=\(self.appUpdater.newerVersion ?? "");"
                    + "appStaged=\(self.appUpdater.readyVersion ?? "")"
            case "aliases":
                return "\(self.applyAliases(req.buffer))"
            case "env":
                // buffer = "<PATH>" RS "<alias dump>" RS "<HISTORY_IGNORE>". The shell sends
                // only what changed: an empty PATH section means it's unchanged, while the
                // alias/history sections are applied whenever present at all — even empty —
                // and skipped only when the shell omits them (no RS) entirely.
                let sections = req.buffer.components(separatedBy: TINE_RS)
                if let path = sections.first, !path.isEmpty {
                    CommandRunner.setShellPath(path)
                }
                if sections.count > 1 { _ = self.applyAliases(sections[1]) }
                if sections.count > 2 { self.applyHistoryIgnore(sections[2]) }
                return "0"
            case "toggleDetail":
                self.state.config.showDetail.toggle()
                self.panel?.relayout()
                return "0"
            case "dismiss":
                if self.sessions.isOwner(req.session) { self.dismissPanel() }
                return "0"
            default:
                return "0"
            }
        }
        server.start()
        self.server = server

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        AXCaret.ensureTrusted()
        tlog("listening on \(sockPath) (AX trusted: \(AXCaret.isTrusted))")

        CommandRunner.onRefresh = { [weak self] in self?.scheduleRefresh() }
    }

    /// `dump` is the shell's `alias` output, one "name=value" per US-joined line.
    private func applyAliases(_ dump: String) -> Int {
        var map: [String: String] = [:]
        for line in dump.components(separatedBy: TINE_US) where !line.isEmpty {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            if !name.isEmpty { map[name] = value }
        }
        state.engine?.setAliases(map)
        historyIgnoreQueue.async { [weak self] in self?.frecency.setAliases(map) }
        return map.count
    }

    /// Serial, so two pattern changes can never apply out of order.
    private let historyIgnoreQueue = DispatchQueue(label: "tine.historyIgnore", qos: .utility)

    /// Off the prompt's socket call: a rebuild rescans all of ~/.zsh_history.
    private func applyHistoryIgnore(_ pattern: String) {
        historyIgnoreQueue.async { [weak self] in
            guard let self, self.frecency.setHistoryIgnore(pattern) else { return }
            let (index, values) = (self.frecency.index, self.frecency.valueIndex)
            DispatchQueue.main.async {
                self.state.engine?.setFrecency(index)
                self.state.engine?.setHistoryValues(values)
            }
        }
    }

    private var refreshWork: DispatchWorkItem?

    /// Coalesce bursts of background-generator completions into one recompute.
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, !self.state.buffer.isEmpty else { return }
            self.state.recompute()
            // A visible panel updates itself via @Published suggestions — reposition
            // only if it wasn't showing yet; hide if the generator found nothing at all.
            if self.state.hasContent {
                if panel.isVisible != true, self.ownerIsFrontmost {
                    self.reflectPanel(buffer: self.state.buffer)
                }
            } else {
                self.dismissPanel()
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        dismissPanel()
    }

    /// Guards against placing the panel over an app the user switched to mid-generator-run.
    private var ownerIsFrontmost: Bool {
        ownerPID != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID
    }

    /// Settings never hides the panel — it only changes geometry while it stays visible.
    func relayoutPanel() {
        panel?.relayout()
    }

    /// Cancels pending reposition/refresh work too, so nothing scheduled before this
    /// can undo it, and — with `ownerPID` cleared — nothing scheduled after can either.
    /// The next keystroke re-owns the panel and brings it back.
    private func dismissPanel() {
        repositionWork?.cancel()
        refreshWork?.cancel()
        ownerPID = nil
        sessions.disown()
        focusWatcher = nil
        panel?.hidePanel()
    }

    private var repositionWork: DispatchWorkItem?

    private func reflectPanel(buffer: String) {
        guard panel != nil else { return }
        guard !buffer.isEmpty, state.hasContent else { dismissPanel(); return }
        // Deferred past zsh's line-pre-redraw: read immediately and AX still reports
        // the previous cursor spot, since the terminal hasn't drawn the new char yet
        // (the "first space doesn't move it" bug).
        repositionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, let owner = self.ownerPID,
                  self.ownerIsFrontmost else { return }
            self.watchFocus(of: owner)
            let ax = AXCaret.caretTopLeftBelow()
            let axOnScreen = ax.map { p in NSScreen.screens.contains { $0.frame.contains(p.point) } } ?? false
            // AX (Terminal, iTerm2, VSCode) first, then the shell-anchored cell for
            // canvas terminals (Ghostty), then a fixed corner.
            let placement = (ax != nil && axOnScreen) ? ax!
                : (self.terminalCellPoint() ?? (self.fallbackCorner(), 16))
            panel.present(at: placement.point, lineHeight: placement.lineHeight)
        }
        repositionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        scheduleIdleHide()
    }

    /// If AXFocusWatcher's init fails (app gone, Accessibility untrusted), the
    /// frontmost-app guard in `ownerIsFrontmost` remains the only protection.
    private func watchFocus(of pid: pid_t) {
        if focusWatcher?.pid == pid { return }
        // Hops off the AX callout frame: dismissPanel deallocates this watcher, which
        // must not happen while its own callback is still on the stack.
        focusWatcher = AXFocusWatcher(pid: pid) { [weak self] in
            DispatchQueue.main.async { self?.dismissPanel() }
        }
    }

    /// AX gives the text-area frame for a canvas terminal (Ghostty, Canario); the grid
    /// (from `lastFeed`) divides it into cells to locate the caret within it.
    private func terminalCellPoint(gap: CGFloat = 4) -> (point: CGPoint, lineHeight: CGFloat)? {
        guard let f = lastFeed, f.cols > 0, f.rows > 0, f.anchorRow > 0, f.anchorCol > 0,
              let rect = AXCaret.focusedElementRect() else { return nil }
        let consumed = (f.anchorCol - 1) + f.buffer.prefix(f.cursor).count
        let col = consumed % f.cols
        let row = min((f.anchorRow - 1) + consumed / f.cols, f.rows - 1)

        let g = gridGeometry(rect: rect, cols: f.cols, rows: f.rows, cellPxW: f.cellW, cellPxH: f.cellH)
        let x = g.origin.x + CGFloat(col) * g.cellW
        let cellBottomAX = g.origin.y + CGFloat(row + 1) * g.cellH
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return (CGPoint(x: x, y: primaryHeight - cellBottomAX - gap), g.cellH)
    }

    /// The AX text-area rect is bigger than the glyph grid by the terminal's padding —
    /// this returns the grid's own top-left and per-cell size within that rect.
    private func gridGeometry(rect: CGRect, cols: Int, rows: Int, cellPxW: Int, cellPxH: Int)
        -> (origin: CGPoint, cellW: CGFloat, cellH: CGFloat) {
        // Canario (Rio's AppKit frontend) pins the grid to a flat 6pt inset and rounds
        // every cell up to a whole point, so computing from the rect divides exactly —
        // its CSI 16t reply instead divides the *padded* view by the grid and over-reports.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.raphaelamorim.canario" {
            let pad: CGFloat = 6
            return (CGPoint(x: rect.minX + pad, y: rect.minY + pad),
                    floor((rect.width - 2 * pad) / CGFloat(cols)),
                    floor((rect.height - 2 * pad) / CGFloat(rows)))
        }
        // Elsewhere (Ghostty) padding is balanced and the grid sits centred, so the
        // terminal-reported cell size (device px → pt) is trusted when available.
        let scale = screen(containing: rect)?.backingScaleFactor ?? 2
        let cellW = cellPxW > 0 ? CGFloat(cellPxW) / scale : rect.width / CGFloat(cols)
        let cellH = cellPxH > 0 ? CGFloat(cellPxH) / scale : rect.height / CGFloat(rows)
        return (CGPoint(x: rect.minX + max(0, rect.width - cellW * CGFloat(cols)) / 2,
                        y: rect.minY + max(0, rect.height - cellH * CGFloat(rows)) / 2),
                cellW, cellH)
    }

    /// The screen the AX rect (top-left origin) sits on, for its backing scale.
    private func screen(containing rect: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let cocoaCenter = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        return NSScreen.screens.first { $0.frame.contains(cocoaCenter) } ?? NSScreen.main
    }

    /// Safety net: hide if no buffer updates arrive for a while (terminal closed,
    /// shell exited, or line-finish never fired).
    private func scheduleIdleHide() {
        idleHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissPanel() }
        idleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func fallbackCorner() -> CGPoint {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(x: screen.minX + 80, y: screen.maxY - 80)
    }

    // The window is not the app: this keeps the autocomplete agent running after it closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        frecency.flush() // the debounced write is still pending if quit follows an accept closely
        appUpdater.applyOnQuit() // the helper outlives us and waits for this pid first
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openDashboard()
        return true
    }

    /// Before `dashboardWindow` is ever captured, falls back to the menu-bar bridge.
    func openDashboard() {
        if let w = dashboardWindow {
            w.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .tineOpenDashboard, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func installShellIntegration() {
        let dest = "\(NSHomeDirectory())/.local/share/tine/tine.zsh"
        guard let res = Bundle.main.resourcePath,
              let data = FileManager.default.contents(atPath: "\(res)/tine.zsh") else { return }
        try? FileManager.default.createDirectory(
            atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Always overwrite: this is a managed file the user sources, not edits, so a
        // brew upgrade must be able to deliver shell-side changes to it. Already-running
        // sessions need a re-source to pick it up.
        try? data.write(to: URL(fileURLWithPath: dest))
    }
}

extension Notification.Name {
    /// AppKit has no API to open a SwiftUI scene window directly, so this is how it
    /// asks MenuBarLabel (which does have `openWindow`) to do it instead.
    static let tineOpenDashboard = Notification.Name("tine.openDashboard")
}

@main
struct TineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    static let dashboardID = "dashboard"

    var body: some Scene {
        // A SwiftUI-owned Window, not a hand-built NSWindow, is what gets the native
        // Liquid Glass sidebar with the traffic lights inset into it.
        Window("Tine", id: Self.dashboardID) {
            SettingsView()
                .environmentObject(delegate.state)
                .environmentObject(delegate.specInstaller)
                .environmentObject(delegate.appUpdater)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)

        MenuBarExtra(isInserted: Binding(
            get: { delegate.state.config.showMenuBarIcon },
            set: { delegate.state.config.showMenuBarIcon = $0 }
        )) {
            DashboardMenu(updater: delegate.appUpdater)
        } label: {
            MenuBarLabel(updater: delegate.appUpdater)
        }
    }
}

/// This view exists whether or not `isInserted` shows its icon, so its `openWindow`
/// is always available to service `.tineOpenDashboard` from the socket, launch, or reopen.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updater: AppUpdater
    private var isDev: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false }
    private var symbol: String {
        if updater.updateActionable { return "arrow.down.circle.fill" }
        return isDev ? "hammer.fill" : "chevron.forward.2"
    }
    var body: some View {
        Image(systemName: symbol)
            .onReceive(NotificationCenter.default.publisher(for: .tineOpenDashboard)) { _ in
                openWindow(id: TineApp.dashboardID)
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

private struct DashboardMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button("Open Dashboard") {
            openWindow(id: TineApp.dashboardID)
            NSApp.activate(ignoringOtherApps: true)
        }
        if updater.updateActionable {
            if case .ready(let version) = updater.status {
                Button("Update to \(version) and Relaunch") {
                    updater.applyAndRelaunch()
                }
            } else {
                Button("Download update…") {
                    updater.check(manual: true)
                }
                .disabled(updater.status == .checking || updater.status == .downloading)
            }
        }
        Divider()
        Button("Quit tine") { NSApp.terminate(nil) }
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.dashboardWindow = v.window }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.dashboardWindow = nsView.window }
    }
}

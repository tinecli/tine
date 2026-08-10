import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var cancellables = Set<AnyCancellable>()
    @MainActor let specInstaller = SpecInstaller()
    @MainActor let appUpdater = AppUpdater()
    @MainActor let specLearner = SpecLearner(
        packDir: ProcessInfo.processInfo.environment["TINE_SPECS_DIR"] ?? SpecInstaller.specsDir)
    @MainActor let asker = Asker(
        packDir: ProcessInfo.processInfo.environment["TINE_SPECS_DIR"] ?? SpecInstaller.specsDir)
    private var panel: SuggestionPanel?
    private var server: SocketServer?
    weak var dashboardWindow: NSWindow?
    private let frecency = Frecency()
    private var idleHide: DispatchWorkItem?
    private var sockPath = ""
    private var socketListening = false
    private var ownerPID: pid_t?
    private let sessions = SessionOwnership()
    private var focusWatcher: AXFocusWatcher?
    private var lastPanelPlacement: DoctorReport.PanelPlacement = .awaitingInput
    private var lastFeed: (anchorRow: Int, anchorCol: Int, cols: Int, rows: Int,
                           cellW: Int, cellH: Int, cursor: Int, buffer: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        TineLog.reset()
        Self.installShellIntegration()
        if state.config.openWindowAtStart {
            // Must stay deferred — calling before MenuBarExtra's bridge is mounted drops the open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.openDashboard() }
        }
        let panel = SuggestionPanel(state: state)
        self.panel = panel

        let env = ProcessInfo.processInfo.environment
        // Must have this fixed default — the input-method process can't see the shell's TINE_SOCK.
        let sockPath = env["TINE_SOCK"] ?? "\(NSHomeDirectory())/.local/share/tine/tine.sock"
        self.sockPath = sockPath
        try? FileManager.default.createDirectory(
            atPath: (sockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        let resources = Bundle.main.resourcePath ?? "."
        let specsDir = env["TINE_SPECS_DIR"] ?? SpecInstaller.specsDir
        state.engine = JSEngine(specsDir: specsDir,
                                localSpecsDirs: state.config.localSpecsDirsExpanded,
                                resourcesDir: resources)

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

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.frecency.load()
            DispatchQueue.main.async {
                self.state.engine?.setFrecency(self.frecency.index)
                self.selectProjectFrecency(for: self.state.cwd)
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
                if req.cwd != self.state.cwd {
                    self.state.engine?.setProjectFrecency([:])
                }
                self.resolveProjectFrecency(for: req.cwd)
                self.state.update(feed)
                if verdict.changed, let app = verdict.appPID {
                    // Must only update here — an async redraw from a background terminal
                    // reaches this handler too, but doesn't prove ownership.
                    self.ownerPID = app
                    self.reflectPanel(buffer: req.buffer)
                } else if req.buffer.isEmpty || !self.state.hasContent {
                    self.dismissPanel()
                } else {
                    self.scheduleIdleHide()
                }
                // max(…, 1): raw 0 while still loading would unbind Up/Down before results land.
                return "\(self.state.hasContent ? max(self.state.suggestions.count, 1) : 0)"
            case "up":
                if self.panel?.isVisible != true || self.state.selectedIndex == 0
                    || !self.sessions.isOwner(req.session) {
                    return "PASS" // must fire at the top row too, or Up can never reach zsh history
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
                // "" here falls through to a normal accept-line — this shell's _TINE_ACTIVE
                // can be stale if the panel idle-hid or moved to another shell.
                if self.panel?.isVisible != true || !self.sessions.isOwner(req.session) {
                    return ""
                }
                if self.state.selectedIsExecute {
                    self.dismissPanel()
                    return "EXEC"
                }
                if let (b, c) = self.state.accept() {
                    // Must exclude "history" and "learn-it" — recording them as picks corrupts frecency ranking.
                    if let name = self.state.selectedName,
                       self.state.selectedType != "history",
                       self.state.selectedType != "learn-it" {
                        let cmd = req.buffer.split(whereSeparator: { $0 == " " || $0 == "\t" })
                            .first.map(String.init) ?? ""
                        if let result = self.frecency.record(cmd: cmd, param: name, cwd: req.cwd) {
                            self.state.engine?.setFrecencyCommand(cmd, params: result.global)
                            if let scoped = result.scoped {
                                self.state.engine?.setProjectFrecencyCommand(cmd, params: scoped)
                            }
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
                self.specInstaller.install()
                return "started"
            case "installStatus":
                return self.specInstaller.statusLine
            case "appUpdate":
                self.appUpdater.check(manual: true)
                return "started"
            case "appUpdateStatus":
                return self.appUpdater.statusLine
            case "appUpdateApply":
                if let reason = self.appUpdater.applyAndRelaunch() { return reason.socketSafe }
                return "ok"
            case "learn":
                // buffer is "<cmd>" or "<cmd>" RS "force" — changing this breaks --force from the shell.
                let sections = req.buffer.components(separatedBy: TINE_RS)
                return self.specLearner.learn(command: sections.first ?? "",
                                              force: sections.count > 1 && sections[1] == "force")
            case "learnStatus":
                return self.specLearner.statusLine
            case "ask":
                return self.asker.ask(question: req.buffer)
            case "index":
                return self.asker.index()
            case "askStatus":
                return self.asker.statusLine
            case "version":
                return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
            case "doctor":
                return self.doctorReport().socketValue
            case "aliases":
                return "\(self.applyAliases(req.buffer))"
            case "env":
                // A present-but-empty alias/history section still applies; only an omitted one (no RS) is skipped.
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
        socketListening = server.start()
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

    private func selectProjectFrecency(for cwd: String) {
        state.engine?.setProjectFrecency([:])
        resolveProjectFrecency(for: cwd)
    }

    private func resolveProjectFrecency(for cwd: String) {
        frecency.resolveProjectRoot(for: cwd) { [weak self] index in
            DispatchQueue.main.async {
                guard let self else { return }
                Frecency.applyProjectIndex(
                    index,
                    resolvedFor: cwd,
                    currentCWD: self.state.cwd,
                    apply: { self.state.engine?.setProjectFrecency($0) },
                    recompute: { self.scheduleRefresh() })
            }
        }
    }

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

    @MainActor func doctorReport() -> DoctorReport {
        let zshrcPath = (ProcessInfo.processInfo.environment["ZDOTDIR"] ?? NSHomeDirectory())
            + "/.zshrc"
        let shellInstalled = FileManager.default.contents(atPath: zshrcPath)
            .map { String(decoding: $0, as: UTF8.self).contains("tine.zsh") } ?? false
        return DoctorReport(
            accessibilityGranted: AXCaret.isTrusted,
            shellInstalled: shellInstalled,
            specCount: SpecInstaller.installedCount(),
            packUpdateAvailable: specInstaller.updateAvailable,
            appVersion: (Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?",
            latestAppVersion: appUpdater.newerVersion,
            stagedAppVersion: appUpdater.readyVersion,
            socketPath: sockPath,
            socketListening: socketListening,
            panelPlacement: lastPanelPlacement
        )
    }

    /// Must stay serial — a concurrent queue could apply an older pattern after a newer one.
    private let historyIgnoreQueue = DispatchQueue(label: "tine.historyIgnore", qos: .utility)

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

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, !self.state.buffer.isEmpty else { return }
            self.state.recompute()
            // Must only reposition when not already visible — a visible panel updates
            // itself via @Published and would otherwise jump on every generator completion.
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

    /// Must gate every panel placement — skip it and the panel can appear over an app the user switched to.
    private var ownerIsFrontmost: Bool {
        ownerPID != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID
    }

    /// Settings never hides the panel — it only changes geometry while it stays visible.
    func relayoutPanel() {
        panel?.relayout()
    }

    /// Must cancel reposition/refresh work here too, or stale work scheduled before this can undo it.
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
        // Must stay deferred — reading immediately hits the "first space doesn't move it" bug (AX still reports the stale cursor).
        repositionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, let owner = self.ownerPID,
                  self.ownerIsFrontmost else { return }
            self.watchFocus(of: owner)
            let ax = AXCaret.caretTopLeftBelow()
            let axOnScreen = ax.map { p in NSScreen.screens.contains { $0.frame.contains(p.point) } } ?? false
            let placement: (point: CGPoint, lineHeight: CGFloat)
            if let ax, axOnScreen {
                self.lastPanelPlacement = .accessibilityCaret
                placement = ax
            } else if let terminal = self.terminalCellPoint() {
                self.lastPanelPlacement = .terminalGrid
                placement = terminal
            } else {
                self.lastPanelPlacement = .cornerFallback
                placement = (self.fallbackCorner(), 16)
            }
            panel.present(at: placement.point, lineHeight: placement.lineHeight)
        }
        repositionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        scheduleIdleHide()
    }

    private func watchFocus(of pid: pid_t) {
        if focusWatcher?.pid == pid { return }
        // Must hop off the AX callout frame first — dismissPanel deallocates this watcher,
        // which can't happen while its own callback is still on the stack.
        focusWatcher = AXFocusWatcher(pid: pid) { [weak self] in
            DispatchQueue.main.async { self?.dismissPanel() }
        }
    }

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

    private func gridGeometry(rect: CGRect, cols: Int, rows: Int, cellPxW: Int, cellPxH: Int)
        -> (origin: CGPoint, cellW: CGFloat, cellH: CGFloat) {
        // Canario's own CSI 16t reply over-reports (divides the *padded* view by the grid) —
        // must ignore cellPx*/use the fixed 6pt inset here instead, or the panel misplaces.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.raphaelamorim.canario" {
            let pad: CGFloat = 6
            return (CGPoint(x: rect.minX + pad, y: rect.minY + pad),
                    floor((rect.width - 2 * pad) / CGFloat(cols)),
                    floor((rect.height - 2 * pad) / CGFloat(rows)))
        }
        let scale = screen(containing: rect)?.backingScaleFactor ?? 2
        let cellW = cellPxW > 0 ? CGFloat(cellPxW) / scale : rect.width / CGFloat(cols)
        let cellH = cellPxH > 0 ? CGFloat(cellPxH) / scale : rect.height / CGFloat(rows)
        return (CGPoint(x: rect.minX + max(0, rect.width - cellW * CGFloat(cols)) / 2,
                        y: rect.minY + max(0, rect.height - cellH * CGFloat(rows)) / 2),
                cellW, cellH)
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let cocoaCenter = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        return NSScreen.screens.first { $0.frame.contains(cocoaCenter) } ?? NSScreen.main
    }

    /// Without this, a closed terminal or exited shell leaves the panel stuck on screen forever.
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
        frecency.flush() // don't drop a pick made in the last second before quit
        appUpdater.applyOnQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openDashboard()
        return true
    }

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
        // Must always overwrite — this is a managed file, and a brew upgrade needs it to deliver shell-side fixes.
        try? data.write(to: URL(fileURLWithPath: dest))
    }
}

extension Notification.Name {
    /// AppKit has no API to open a SwiftUI scene window directly — this is the only bridge to it.
    static let tineOpenDashboard = Notification.Name("tine.openDashboard")
}

@main
struct TineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    static let dashboardID = "dashboard"

    var body: some Scene {
        // Must stay a SwiftUI Window, not a hand-built NSWindow, or the native Liquid Glass sidebar is lost.
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

/// Must stay unconditional on `isInserted` — hiding this behind the icon's visibility
/// breaks dashboard-opening for anyone who hides the menu-bar icon.
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

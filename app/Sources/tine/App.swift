import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var cancellables = Set<AnyCancellable>()
    private var specInstaller: SpecInstaller?
    private var panel: SuggestionPanel?
    private var server: SocketServer?
    /// The SwiftUI dashboard window, captured once it exists (WindowAccessor), so
    /// AppKit can reopen it directly — independent of the menu-bar item, which the
    /// user can hide.
    weak var dashboardWindow: NSWindow?
    private let frecency = Frecency()
    private var idleHide: DispatchWorkItem?
    private var sockPath = ""
    // Latest shell positioning feed: prompt-anchor cell + grid + cell size (device
    // px), for computing the caret in canvas terminals (Ghostty) where AX can't.
    private var lastFeed: (anchorRow: Int, anchorCol: Int, cols: Int, rows: Int,
                           cellW: Int, cellH: Int, cursor: Int, buffer: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no dock icon
        TineLog.reset()
        Self.installShellIntegration()
        // No dock/menu bar: closing the window leaves the autocomplete agent
        // running (reopen by launching the app again). Opening the window on
        // launch is opt-out via Settings.
        if state.config.openWindowAtStart {
            // Defer so the MenuBarExtra bridge is mounted to receive the open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.openDashboard() }
        }
        let panel = SuggestionPanel(state: state)
        self.panel = panel

        let env = ProcessInfo.processInfo.environment
        // Fixed default (the input-method process can't see the shell's TINE_SOCK).
        let sockPath = env["TINE_SOCK"] ?? "\(NSHomeDirectory())/.local/share/tine/tine.sock"
        self.sockPath = sockPath
        try? FileManager.default.createDirectory(
            atPath: (sockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        let resources = Bundle.main.resourcePath ?? "."
        // The pack is downloaded at runtime (SpecInstaller), not bundled. The
        // engine reads it lazily, so it works once files land — even if the
        // download finishes after launch.
        let specsDir = env["TINE_SPECS_DIR"] ?? SpecInstaller.specsDir
        state.engine = JSEngine(specsDir: specsDir,
                                localSpecsDirs: state.config.localSpecsDirsExpanded,
                                resourcesDir: resources)

        // Keep the installer around so `tine install` / doctor can use it. First
        // run (or a wiped pack): download in the background — suggestions are just
        // empty until it lands, nothing blocks. Otherwise, quietly check whether
        // the fork has a newer pack so doctor can flag it.
        let installer = SpecInstaller()
        installer.onInstalled = { [weak self] in self?.scheduleRefresh() }
        if SpecInstaller.isInstalled() {
            // Keep the app's built-in specs current with this app version, then
            // check whether the fork has a newer pack.
            SpecInstaller.refreshBuiltins()
            installer.checkForUpdate()
        } else {
            installer.install()
        }
        specInstaller = installer

        state.engine?.setFirstTokenEnabled(state.config.firstTokenCompletion)

        // Frecency: bootstrap from ~/.zsh_history off the main thread, then feed
        // the index to the engine so most-used subcommands/flags rank first.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.frecency.load()
            DispatchQueue.main.async { self.state.engine?.setFrecency(self.frecency.index) }
        }

        let server = SocketServer(path: sockPath) { [weak self] req in
            guard let self else { return "0" }
            switch req.type {
            case "update":
                self.lastFeed = (req.anchorRow, req.anchorCol, req.cols, req.rows,
                                 req.cellW, req.cellH, req.cursor, req.buffer)
                let changed = self.state.update(
                    FeedMessage(cursor: req.cursor, cwd: req.cwd, buffer: req.buffer))
                if changed {
                    self.reflectPanel(buffer: req.buffer)
                } else if req.buffer.isEmpty || !self.state.hasContent {
                    self.panel?.hidePanel()
                } else {
                    self.scheduleIdleHide() // keep visible, don't move
                }
                // Report panel-is-active (>0), not the raw count: while a generator
                // is still loading there are 0 suggestions yet, but the shell must
                // keep Up/Down bound to us so nav works once results land.
                return "\(self.state.hasContent ? max(self.state.suggestions.count, 1) : 0)"
            case "up":
                // Let the key fall through to the terminal (zsh history) when the
                // panel isn't actually showing, or when already at the top row —
                // otherwise Up could never reach history.
                if self.panel?.isVisible != true || self.state.selectedIndex == 0 {
                    return "PASS"
                }
                self.state.moveSelection(-1)
                return "\(self.state.suggestions.count)"
            case "down":
                if self.panel?.isVisible != true {
                    return "PASS"
                }
                self.state.moveSelection(1)
                return "\(self.state.suggestions.count)"
            case "accept":
                // The panel may have idle-hidden without the shell knowing, so its
                // _TINE_ACTIVE is stale. Only accept when actually showing; else ""
                // lets Enter fall through to a normal accept-line.
                if self.panel?.isVisible != true { return "" }
                // Fig's auto-execute row runs the line as-is instead of inserting.
                if self.state.selectedIsExecute {
                    self.panel?.hidePanel()
                    return "EXEC"
                }
                if let (b, c) = self.state.accept() {
                    // Learn: record (rawCommand, pickedName) for frecency ranking.
                    if let name = self.state.selectedName {
                        let cmd = req.buffer.split(whereSeparator: { $0 == " " || $0 == "\t" })
                            .first.map(String.init) ?? ""
                        self.frecency.record(cmd: cmd, param: name)
                        self.state.engine?.setFrecency(self.frecency.index)
                    }
                    self.panel?.hidePanel()
                    return "\(c)\(TINE_US)\(b)"
                }
                return ""
            case "prefix":
                // Same guard as accept: ignore Tab when the panel isn't showing.
                if self.panel?.isVisible != true { return "" }
                // Fig's Tab: insert common prefix; keep the panel open.
                if let (b, c) = self.state.commonPrefix() {
                    return "\(c)\(TINE_US)\(b)"
                }
                return ""
            case "path":
                // The shell's PATH, so generators can find non-system tools.
                CommandRunner.setShellPath(req.buffer)
                return "0"
            case "showDashboard":
                self.openDashboard()
                return "0"
            case "install":
                // Kick the (conditional) download off the main thread; the shell
                // polls `installStatus` for progress. Never blocks this handler.
                self.specInstaller?.install()
                return "started"
            case "installStatus":
                return self.specInstaller?.statusLine ?? "idle"
            case "version":
                return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
            case "doctor":
                // Health report for `tine doctor` (semicolon-joined key=value).
                let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
                let update = self.specInstaller?.updateAvailable == true ? 1 : 0
                return "ax=\(AXCaret.isTrusted ? 1 : 0);specs=\(SpecInstaller.installedCount());version=\(v);update=\(update)"
            case "aliases":
                // buffer = the shell's `alias` output, lines joined by US.
                var map: [String: String] = [:]
                for line in req.buffer.components(separatedBy: TINE_US) where !line.isEmpty {
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let name = String(line[..<eq])
                    let value = String(line[line.index(after: eq)...])
                    if !name.isEmpty { map[name] = value }
                }
                self.state.engine?.setAliases(map)
                return "\(map.count)"
            case "toggleDetail":
                self.state.config.showDetail.toggle()
                self.panel?.relayout()
                return "0"
            case "dismiss":
                self.panel?.hidePanel()
                return "0"
            default:
                return "0"
            }
        }
        server.start()
        self.server = server

        // Hide when the user switches to another app (terminal lost focus).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        AXCaret.ensureTrusted()
        tlog("listening on \(sockPath) (AX trusted: \(AXCaret.isTrusted))")

        // A background generator finished with new data — re-run the current
        // suggestion so late results appear without another keystroke.
        CommandRunner.onRefresh = { [weak self] in self?.scheduleRefresh() }
    }

    private var refreshWork: DispatchWorkItem?

    /// Coalesce bursts of background-generator completions into one recompute.
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, !self.state.buffer.isEmpty else { return }
            self.state.recompute()
            // Content is bound to @Published suggestions, so a visible panel updates
            // itself; only (re)position when it wasn't showing yet. If the generator
            // finished with nothing (no suggestions, no longer loading), hide.
            if self.state.hasContent {
                if panel.isVisible != true { self.reflectPanel(buffer: self.state.buffer) }
            } else {
                panel.hidePanel()
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        panel?.hidePanel()
    }

    private var repositionWork: DispatchWorkItem?

    /// Position/show the panel at the caret, or hide it if there's nothing to show.
    private func reflectPanel(buffer: String) {
        guard let panel else { return }
        guard !buffer.isEmpty, state.hasContent else { panel.hidePanel(); return }
        // The caret is read one frame late: this handler runs during zsh's
        // line-pre-redraw, before the terminal has drawn the just-typed char, so
        // AX still reports the previous cursor spot (the "first space doesn't
        // move it" bug). Defer the read until after the terminal redraws.
        repositionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            let ax = AXCaret.caretTopLeftBelow()
            let axOnScreen = ax.map { p in NSScreen.screens.contains { $0.frame.contains(p.point) } } ?? false
            // Prefer Accessibility (Terminal, iTerm2, VSCode); fall back to the
            // shell-anchored cell for canvas terminals (Ghostty), then a corner.
            let placement = (ax != nil && axOnScreen) ? ax!
                : (self.terminalCellPoint() ?? (self.fallbackCorner(), 16))
            panel.present(at: placement.point, lineHeight: placement.lineHeight)
        }
        repositionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        scheduleIdleHide()
    }

    /// Panel top-left just below the caret in a canvas terminal (Ghostty), derived
    /// from the shell's prompt-anchor cell + grid and the buffer offset. AX gives
    /// the text-area frame; the grid divides it into cells.
    private func terminalCellPoint(gap: CGFloat = 4) -> (point: CGPoint, lineHeight: CGFloat)? {
        guard let f = lastFeed, f.cols > 0, f.rows > 0, f.anchorRow > 0, f.anchorCol > 0,
              let rect = AXCaret.focusedElementRect() else { return nil }
        let consumed = (f.anchorCol - 1) + f.buffer.prefix(f.cursor).count
        let col = consumed % f.cols
        let row = min((f.anchorRow - 1) + consumed / f.cols, f.rows - 1)

        // The AX rect is the whole text-area element, larger than the glyph grid
        // (balanced padding). Use the terminal-reported cell size (device px → pt)
        // for exact cells, and centre the grid in the rect. Fall back to rect÷grid.
        let scale = screen(containing: rect)?.backingScaleFactor ?? 2
        let cellW = f.cellW > 0 ? CGFloat(f.cellW) / scale : rect.width / CGFloat(f.cols)
        let cellH = f.cellH > 0 ? CGFloat(f.cellH) / scale : rect.height / CGFloat(f.rows)
        let originX = rect.minX + max(0, rect.width - cellW * CGFloat(f.cols)) / 2
        // The glyph grid is centred within the AX text-area rect (balanced padding).
        let originY = rect.minY + max(0, rect.height - cellH * CGFloat(f.rows)) / 2

        let x = originX + CGFloat(col) * cellW
        let cellBottomAX = originY + CGFloat(row + 1) * cellH
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return (CGPoint(x: x, y: primaryHeight - cellBottomAX - gap), cellH)
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
        let work = DispatchWorkItem { [weak self] in self?.panel?.hidePanel() }
        idleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func fallbackCorner() -> CGPoint {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(x: screen.minX + 80, y: screen.maxY - 80)
    }

    // Closing the window leaves the autocomplete agent running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Relaunching the app (open again) re-shows the GUI.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openDashboard()
        return true
    }

    /// Show the dashboard. Prefer the captured window (works even with the menu-bar
    /// item hidden); fall back to the menu-bar bridge the first time, before the
    /// window has ever been created.
    func openDashboard() {
        if let w = dashboardWindow {
            w.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .tineOpenDashboard, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Distributable first-run: install the bundled shell integration to the fixed
    /// path the user sources, if it isn't there yet (dev-run copies it directly).
    private static func installShellIntegration() {
        let dest = "\(NSHomeDirectory())/.local/share/tine/tine.zsh"
        guard let res = Bundle.main.resourcePath,
              let data = FileManager.default.contents(atPath: "\(res)/tine.zsh") else { return }
        try? FileManager.default.createDirectory(
            atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Always overwrite so brew upgrades deliver shell-side changes — it's a
        // managed file the user sources, not edits. (Open a new shell, or re-source,
        // to pick it up in already-running sessions.)
        try? data.write(to: URL(fileURLWithPath: dest))
    }
}

extension Notification.Name {
    /// Posted by AppKit (socket `tine dashboard`, launch, reopen) to open the
    /// SwiftUI window — SwiftUI has no AppKit API to open a scene window, so the
    /// menu-bar label bridges it to the `openWindow` action.
    static let tineOpenDashboard = Notification.Name("tine.openDashboard")
}

@main
struct TineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    static let dashboardID = "dashboard"

    var body: some Scene {
        // SwiftUI owns the window, so it gets the native Liquid Glass sidebar with
        // the traffic lights inset into it (no hand-built NSWindow).
        Window("Tine", id: Self.dashboardID) {
            SettingsView().environmentObject(delegate.state)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)

        MenuBarExtra(isInserted: Binding(
            get: { delegate.state.config.showMenuBarIcon },
            set: { delegate.state.config.showMenuBarIcon = $0 }
        )) {
            DashboardMenu()
        } label: {
            MenuBarLabel()
        }
    }
}

/// Menu-bar icon. Also the AppKit→SwiftUI bridge: it's always present, so its
/// `openWindow` can service open requests from the socket / launch / reopen.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    private var isDev: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false }
    var body: some View {
        Image(systemName: isDev ? "hammer.fill" : "chevron.forward.2")
            .onReceive(NotificationCenter.default.publisher(for: .tineOpenDashboard)) { _ in
                openWindow(id: TineApp.dashboardID)
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

private struct DashboardMenu: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Dashboard") {
            openWindow(id: TineApp.dashboardID)
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit tine") { NSApp.terminate(nil) }
    }
}

/// Hands the hosting NSWindow to the delegate so AppKit can reopen the dashboard
/// without depending on the menu-bar item (which the user can hide).
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

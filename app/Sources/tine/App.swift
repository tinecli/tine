import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var cancellables = Set<AnyCancellable>()
    /// The app's only installer — injected into the dashboard, so its "Install /
    /// Update Specs" button shares this instance's status guard and onInstalled
    /// refresh instead of installing behind the app's back.
    @MainActor let specInstaller = SpecInstaller()
    private var panel: SuggestionPanel?
    private var server: SocketServer?
    /// The SwiftUI dashboard window, captured once it exists (WindowAccessor), so
    /// AppKit can reopen it directly — independent of the menu-bar item, which the
    /// user can hide.
    weak var dashboardWindow: NSWindow?
    private let frecency = Frecency()
    private var idleHide: DispatchWorkItem?
    private var sockPath = ""
    /// The app the panel belongs to: whoever was frontmost when the user last
    /// changed the line. Only that app may have the panel placed over it.
    private var ownerPID: pid_t?
    /// Watches the owner for window/tab switches while the panel is up.
    private var focusWatcher: AXFocusWatcher?
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
        specInstaller.onInstalled = { [weak self] in self?.scheduleRefresh() }
        if SpecInstaller.isInstalled() {
            // Keep the app's built-in specs current with this app version, then
            // check whether the fork has a newer pack.
            SpecInstaller.refreshBuiltins()
            specInstaller.checkForUpdate()
        } else {
            specInstaller.install()
        }

        state.engine?.setFirstTokenEnabled(state.config.firstTokenCompletion)

        // Frecency: bootstrap from ~/.zsh_history off the main thread, then feed
        // the index to the engine so most-used subcommands/flags rank first.
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
                self.lastFeed = (req.anchorRow, req.anchorCol, req.cols, req.rows,
                                 req.cellW, req.cellH, req.cursor, req.buffer)
                let changed = self.state.update(
                    FeedMessage(cursor: req.cursor, cwd: req.cwd, buffer: req.buffer))
                if changed {
                    // Only an edited line proves who owns the panel: an async prompt
                    // redraw reaches us from a background terminal too.
                    self.ownerPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    self.reflectPanel(buffer: req.buffer)
                } else if req.buffer.isEmpty || !self.state.hasContent {
                    self.dismissPanel()
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
                    self.dismissPanel()
                    return "EXEC"
                }
                if let (b, c) = self.state.accept() {
                    // Learn: record (rawCommand, pickedName) for frecency ranking.
                    // A history value is skipped: it came from ~/.zsh_history, the
                    // shell logs it again, and the store must stay free of values.
                    if let name = self.state.selectedName, self.state.selectedType != "history" {
                        let cmd = req.buffer.split(whereSeparator: { $0 == " " || $0 == "\t" })
                            .first.map(String.init) ?? ""
                        self.frecency.record(cmd: cmd, param: name)
                        self.state.engine?.setFrecency(self.frecency.index)
                    }
                    self.dismissPanel()
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
                self.specInstaller.install()
                return "started"
            case "installStatus":
                return self.specInstaller.statusLine
            case "version":
                return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
            case "doctor":
                // Health report for `tine doctor` (semicolon-joined key=value).
                let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
                let update = self.specInstaller.updateAvailable ? 1 : 0
                return "ax=\(AXCaret.isTrusted ? 1 : 0);specs=\(SpecInstaller.installedCount());version=\(v);update=\(update)"
            case "aliases":
                return "\(self.applyAliases(req.buffer))"
            case "env":
                // buffer = "<PATH>" RS "<alias dump>". The shell sends only what
                // changed since its last prompt, so a section can be absent: no RS
                // means the aliases are unchanged, an empty first section means the
                // PATH is. Both stay as the app last learned them.
                let sections = req.buffer.components(separatedBy: TINE_RS)
                if let path = sections.first, !path.isEmpty {
                    CommandRunner.setShellPath(path)
                }
                if sections.count > 1 { _ = self.applyAliases(sections[1]) }
                return "0"
            case "toggleDetail":
                self.state.config.showDetail.toggle()
                self.panel?.relayout()
                return "0"
            case "dismiss":
                self.dismissPanel()
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

    /// Hand the engine the shell's `alias` output (lines joined by US), so the
    /// parser can expand `pc ` → `plug-cli `. Returns the alias count.
    private func applyAliases(_ dump: String) -> Int {
        var map: [String: String] = [:]
        for line in dump.components(separatedBy: TINE_US) where !line.isEmpty {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            if !name.isEmpty { map[name] = value }
        }
        state.engine?.setAliases(map)
        return map.count
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

    /// The panel may only be placed over the app that fed us the line — never over
    /// an app the user switched to while a generator was still running.
    private var ownerIsFrontmost: Bool {
        ownerPID != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID
    }

    /// Hide the panel, stop watching the owner, and disown it. Cancels the pending
    /// present and refresh too, so nothing scheduled before the dismiss can undo it
    /// — and with no owner, nothing scheduled after it can either. The next
    /// keystroke re-owns the panel and brings it back.
    private func dismissPanel() {
        repositionWork?.cancel()
        refreshWork?.cancel()
        ownerPID = nil
        focusWatcher = nil
        panel?.hidePanel()
    }

    private var repositionWork: DispatchWorkItem?

    /// Position/show the panel at the caret, or hide it if there's nothing to show.
    private func reflectPanel(buffer: String) {
        guard panel != nil else { return }
        guard !buffer.isEmpty, state.hasContent else { dismissPanel(); return }
        // The caret is read one frame late: this handler runs during zsh's
        // line-pre-redraw, before the terminal has drawn the just-typed char, so
        // AX still reports the previous cursor spot (the "first space doesn't
        // move it" bug). Defer the read until after the terminal redraws.
        repositionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, let owner = self.ownerPID,
                  self.ownerIsFrontmost else { return }
            self.watchFocus(of: owner)
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

    /// Watch this app for focus moves, reusing the existing watcher when the app
    /// hasn't changed. A failure (app gone, Accessibility not trusted) leaves the
    /// frontmost-app guard as the only protection.
    private func watchFocus(of pid: pid_t) {
        if focusWatcher?.pid == pid { return }
        // Hop off the AX callout: the dismiss deallocates the watcher, which must
        // not happen while its own callback frame is still on the stack.
        focusWatcher = AXFocusWatcher(pid: pid) { [weak self] in
            DispatchQueue.main.async { self?.dismissPanel() }
        }
    }

    /// Panel top-left just below the caret in a canvas terminal (Ghostty, Canario), derived
    /// from the shell's prompt-anchor cell + grid and the buffer offset. AX gives
    /// the text-area frame; the grid divides it into cells.
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

    /// Cell size and grid top-left inside a canvas terminal's AX text-area rect,
    /// which is bigger than the glyph grid by the terminal's padding.
    private func gridGeometry(rect: CGRect, cols: Int, rows: Int, cellPxW: Int, cellPxH: Int)
        -> (origin: CGPoint, cellW: CGFloat, cellH: CGFloat) {
        // Canario (Rio's AppKit frontend) pins the grid to a flat 6pt inset and
        // rounds every cell up to a whole point, so the rect divides exactly. Its
        // CSI 16t reply divides the *padded* view by the grid, so it over-reports
        // and must be ignored.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.raphaelamorim.canario" {
            let pad: CGFloat = 6
            return (CGPoint(x: rect.minX + pad, y: rect.minY + pad),
                    floor((rect.width - 2 * pad) / CGFloat(cols)),
                    floor((rect.height - 2 * pad) / CGFloat(rows)))
        }
        // Elsewhere (Ghostty) the padding is balanced, so the grid sits centred.
        // Prefer the terminal-reported cell size (device px → pt); else rect÷grid.
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

    // Closing the window leaves the autocomplete agent running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Picks are written a second after the last one, so quitting right after an
    // accept has to write the debounced one now.
    func applicationWillTerminate(_ notification: Notification) {
        frecency.flush()
    }

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
            SettingsView()
                .environmentObject(delegate.state)
                .environmentObject(delegate.specInstaller)
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

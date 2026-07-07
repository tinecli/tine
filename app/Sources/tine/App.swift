import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var panel: SuggestionPanel?
    private var server: SocketServer?
    private var mainWindow: NSWindow?
    private let frecency = Frecency()
    private var idleHide: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var sockPath = ""
    // Latest caret rect from the input method (screen coords), for terminals
    // whose Accessibility can't report it (Ghostty).
    private var imeCaret: (rect: CGRect, at: Date)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no dock icon
        TineLog.reset()
        Self.installShellIntegration()
        // No dock/menu bar: opening the app opens the window; closing it leaves
        // the autocomplete agent running (reopen by launching the app again).
        DispatchQueue.main.async { self.showMainWindow() }
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
        let installed = "\(NSHomeDirectory())/.local/share/tine/specs"
        let specsDir = env["TINE_SPECS_DIR"]
            ?? (FileManager.default.fileExists(atPath: installed) ? installed : "\(resources)/specs")
        state.engine = JSEngine(specsDir: specsDir,
                                localSpecsDir: state.config.localSpecsDirExpanded,
                                resourcesDir: resources)

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
                let changed = self.state.update(
                    FeedMessage(cursor: req.cursor, cwd: req.cwd, buffer: req.buffer))
                if changed {
                    self.reflectPanel(buffer: req.buffer)
                } else if req.buffer.isEmpty || !self.state.hasSuggestions {
                    self.panel?.hidePanel()
                } else {
                    self.scheduleIdleHide() // keep visible, don't move
                }
                return "\(self.state.suggestions.count)"
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
                // Fig's Tab: insert common prefix; keep the panel open.
                if let (b, c) = self.state.commonPrefix() {
                    return "\(c)\(TINE_US)\(b)"
                }
                return ""
            case "caret":
                // From the input method: "caret US x US y US height" (screen coords).
                let x = CGFloat(req.cursor)
                let y = CGFloat(Int(req.cwd) ?? 0)
                let h = CGFloat(Int(req.buffer) ?? 0)
                self.imeCaret = (CGRect(x: x, y: y, width: 0, height: h), Date())
                tlog("caret[IME] rect=(\(x),\(y),h=\(h)) -> point=\(String(describing: self.imeCaretPoint()))")
                // If the panel is up (AX couldn't place it), correct its position.
                if self.panel?.isVisible == true, let p = self.imeCaretPoint() {
                    self.panel?.present(at: p)
                }
                return "0"
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
        setupStatusItem()
    }

    /// Menu-bar item: shows which build is running (name + socket) and gives a
    /// way to open the dashboard or quit — the app is otherwise invisible
    /// (.accessory). Dev builds get a distinct icon so two menu-bar items (dev +
    /// released) are tellable apart.
    private func setupStatusItem() {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Tine"
        let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: isDev ? "hammer.fill" : "wand.and.stars", accessibilityDescription: name)
        item.button?.toolTip = name

        let menu = NSMenu()
        let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let sock = NSMenuItem(title: "socket: \((sockPath as NSString).lastPathComponent)", action: nil, keyEquivalent: "")
        sock.isEnabled = false
        menu.addItem(sock)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Dashboard", action: #selector(statusOpenDashboard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit \(name)", action: #selector(statusQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func statusOpenDashboard() { showMainWindow() }
    @objc private func statusQuit() { NSApp.terminate(nil) }

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        panel?.hidePanel()
    }

    private var repositionWork: DispatchWorkItem?

    /// Position/show the panel at the caret, or hide it if there's nothing to show.
    private func reflectPanel(buffer: String) {
        guard let panel else { return }
        guard !buffer.isEmpty, state.hasSuggestions else { panel.hidePanel(); return }
        // The caret is read one frame late: this handler runs during zsh's
        // line-pre-redraw, before the terminal has drawn the just-typed char, so
        // AX still reports the previous cursor spot (the "first space doesn't
        // move it" bug). Defer the read until after the terminal redraws.
        repositionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            let ax = AXCaret.caretTopLeftBelow()
            let axOnScreen = ax.map { p in NSScreen.screens.contains { $0.frame.contains(p) } } ?? false
            // Prefer Accessibility; fall back to the input-method caret (Ghostty),
            // then to a screen corner.
            let pos = (ax != nil && axOnScreen) ? ax! : (self.imeCaretPoint() ?? self.fallbackCorner())
            panel.present(at: pos)
        }
        repositionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        scheduleIdleHide()
    }

    /// Panel top-left just below the input-method caret, if recent.
    private func imeCaretPoint(gap: CGFloat = 4) -> CGPoint? {
        guard let c = imeCaret, Date().timeIntervalSince(c.at) < 2 else { return nil }
        // firstRectForCharacterRange is screen coords (Cocoa, bottom-left); the
        // rect's origin.y is the line's bottom, so drop just below it.
        return CGPoint(x: c.rect.origin.x, y: c.rect.origin.y - gap)
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
        showMainWindow()
        return true
    }

    /// Show (or create) the settings window. Managed in AppKit because a menuless
    /// (.accessory) app can't reliably drive SwiftUI's Settings scene.
    /// Distributable first-run: install the bundled shell integration to the fixed
    /// path the user sources, if it isn't there yet (dev-run copies it directly).
    private static func installShellIntegration() {
        let dest = "\(NSHomeDirectory())/.local/share/tine/tine.zsh"
        guard !FileManager.default.fileExists(atPath: dest),
              let res = Bundle.main.resourcePath else { return }
        let src = "\(res)/tine.zsh"
        guard FileManager.default.fileExists(atPath: src) else { return }
        try? FileManager.default.createDirectory(
            atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: src, toPath: dest)
    }

    private func showMainWindow() {
        if mainWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(state))
            host.sizingOptions = [.preferredContentSize]
            let win = NSWindow(contentViewController: host)
            win.title = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Tine"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 560, height: 600))
            win.center()
            mainWindow = win
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // The window is managed in AppDelegate; this scene just satisfies `App`.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

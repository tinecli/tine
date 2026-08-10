import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var installer: SpecInstaller
    @EnvironmentObject var updater: AppUpdater

    // Re-read externally-owned state (Accessibility grant, login item) so the UI
    // reflects changes made outside the app without needing a relaunch.
    @State private var axTrusted = AXCaret.isTrusted
    @State private var selectedSpecDir: Int?
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var pane: Pane? = .general
    @StateObject private var previewState = AppState.appearancePreview()
    @State private var previewWidth: CGFloat = 0
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    /// Sidebar sections of the settings window.
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", appearance = "Appearance", suggestions = "Suggestions"
        case specs = "Specs", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .suggestions: return "text.and.command.macwindow"
            case .specs: return "shippingbox"
            case .about: return "info.circle"
            }
        }
    }

    // (config value, display name). "" = the system monospaced font.
    private let fonts = [("", "System Monospaced"), ("Menlo", "Menlo"),
                         ("Monaco", "Monaco"), ("SF Mono", "SF Mono"),
                         ("Courier New", "Courier New")]
    private let shellLine = "source ~/.local/share/tine/tine.zsh"
    static let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"

    private var shellInstalled: Bool {
        FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.local/share/tine/tine.zsh")
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.rawValue, systemImage: p.icon).tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
            .navigationTitle("tine")
        } detail: {
            Form { paneBody }
                .formStyle(.grouped)
                .navigationTitle((pane ?? .general).rawValue)
        }
        .frame(minWidth: 440, idealWidth: 590, minHeight: 360, idealHeight: 520)
        .background(WindowAccessor())
        .onReceive(refresh) { _ in axTrusted = AXCaret.isTrusted }
    }

    @ViewBuilder private var paneBody: some View {
        switch pane ?? .general {
        case .general: generalPane
        case .appearance: appearancePane
        case .suggestions: suggestionsPane
        case .specs: specsPane
        case .about: aboutPane
        }
    }

    @ViewBuilder private var generalPane: some View {
        Section("Setup") {
            setupRow("Accessibility", ok: axTrusted,
                     detail: "Positions the panel at your cursor (Terminal & iTerm).") {
                Button("Grant") {
                    AXCaret.ensureTrusted()
                    openPane("com.apple.preference.security?Privacy_Accessibility")
                }
            }
            setupRow("Shell integration", ok: shellInstalled, detail: shellLine) {
                Button("Copy line") { copy(shellLine) }
            }
        }
        Section {
            Toggle("Start at login", isOn: $startAtLogin)
                .onChange(of: startAtLogin) { _, on in setStartAtLogin(on) }
            Toggle("Menu bar icon", isOn: bind(\.showMenuBarIcon))
            Toggle("Open window at start", isOn: bind(\.openWindowAtStart))
        }
    }

    @ViewBuilder private var appearancePane: some View {
        Section {
            Toggle("Liquid glass", isOn: bind(\.glass))
            Toggle("Detail pane (⌃K)", isOn: bind(\.showDetail))
            Picker("Font", selection: bind(\.fontName)) {
                ForEach(fonts, id: \.0) { Text($0.1).tag($0.0) }
            }
            LabeledContent("Font size") {
                HStack(spacing: 6) {
                    TextField("", value: bind(\.fontSize), format: .number)
                        .frame(width: 46).multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: bind(\.fontSize), in: 8...28, step: 1).labelsHidden()
                }
            }
        }
        Section {
            preview
        } header: {
            Text("Preview")
        } footer: {
            Text("Four sample rows, drawn by the real panel over a mock terminal.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The shipping SuggestionListView, fed by throwaway state that mirrors the live
    /// config, scaled down when the window is narrower than the panel.
    private var preview: some View {
        let size = SuggestionListView.panelSize(rows: previewState.suggestions.count,
                                                config: previewState.config)
        let scale = previewWidth > 0 ? min(1, previewWidth / size.width) : 1
        return ZStack(alignment: .topLeading) {
            terminalBackdrop
            SuggestionListView()
                .environmentObject(previewState)
                .allowsHitTesting(false)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale,
                       alignment: .topLeading)
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { previewWidth = $0 }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.88)))
        .onChange(of: state.config, initial: true) { _, cfg in previewState.config = cfg }
    }

    /// Terminal text the panel floats over, so glass has something real to refract —
    /// over the Form's opaque background it would read as flat grey and tell nothing
    /// about the over-terminal look.
    private var terminalBackdrop: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "~/dev/tine $ git status").foregroundStyle(.green.opacity(0.8))
            Text(verbatim: "On branch main").foregroundStyle(.white.opacity(0.45))
            Text(verbatim: "Your branch is up to date with 'origin/main'.")
                .foregroundStyle(.white.opacity(0.45))
            Text(verbatim: "nothing to commit, working tree clean")
                .foregroundStyle(.white.opacity(0.45))
            Text(verbatim: "~/dev/tine $ git pu").foregroundStyle(.green.opacity(0.8))
        }
        .font(.system(size: 10, design: .monospaced))
    }

    @ViewBuilder private var suggestionsPane: some View {
        Section {
            LabeledContent("Max rows shown") {
                HStack(spacing: 6) {
                    TextField("", value: bind(\.maxVisibleRows), format: .number)
                        .frame(width: 46).multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: bind(\.maxVisibleRows), in: 1...40).labelsHidden()
                }
            }
            Toggle("Complete command names", isOn: bind(\.firstTokenCompletion))
        } footer: {
            Text("↑ ↓ move · Tab inserts the shared prefix · Enter accepts · Esc dismisses · **⌃K** toggles the detail pane")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var specsPane: some View {
        Section("Specs") {
            LabeledContent("Installed", value: {
                let n = SpecInstaller.installedCount()
                return n > 0 ? "\(n) commands" : "None"
            }())
            HStack(spacing: 10) {
                Button("Install / Update Specs") { installer.install() }
                    .disabled(installer.status == .running)
                if installer.status == .running { ProgressView().controlSize(.small) }
                installerStatus
            }
            Toggle("Download new specs automatically", isOn: bind(\.autoUpdateSpecs))
        }
        Section("Your specs") {
            VStack(alignment: .leading, spacing: 6) {
                Text("In each folder, drop Fig `.js` specs in `override/<cmd>.js` (replaces a spec) or `extend/<cmd>.js` (adds to it). Earlier folders win. Restart tine after changing.")
                    .font(.caption).foregroundStyle(.secondary)
                List(selection: $selectedSpecDir) {
                    ForEach(state.config.localSpecsDirs.indices, id: \.self) { i in
                        TextField("Spec folder", text: bindDir(i),
                                  prompt: Text(verbatim: "~/.config/tine/specs"))
                            .font(.caption.monospaced())
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 92)
                HStack(spacing: 2) {
                    Button { addDir() } label: { Image(systemName: "plus") }
                    Button { removeSelectedDir() } label: { Image(systemName: "minus") }
                        .disabled(selectedSpecDir == nil || state.config.localSpecsDirs.count <= 1)
                    Spacer()
                    Button("Reveal") { revealSelectedDir() }
                        .disabled(selectedSpecDir == nil)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var aboutPane: some View {
        Section {
            VStack(spacing: 8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 72, height: 72)
                }
                Text("tine").font(.title2.weight(.semibold))
                Text("Version \(Self.appVersion)").font(.caption).foregroundStyle(.secondary)
                Text("Native macOS terminal autocomplete")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        Section("Updates") {
            HStack(spacing: 10) {
                Button("Check for Updates") { updater.check(manual: true) }
                    .disabled(updater.status == .checking || updater.status == .downloading)
                if updater.status == .checking || updater.status == .downloading {
                    ProgressView().controlSize(.small)
                }
                updaterStatus
            }
            if let ready = updater.readyVersion {
                Button("Update to \(ready) and Relaunch") { updater.applyAndRelaunch() }
            }
            Toggle("Update tine automatically", isOn: bind(\.autoUpdateApp))
            Toggle("Notify me about updates", isOn: bind(\.updateNotifications))
        }
        Section {
            Button("Quit tine", role: .destructive) { NSApplication.shared.terminate(nil) }
        }
    }

    @ViewBuilder private var updaterStatus: some View {
        switch updater.status {
        case .idle, .checking, .downloading: EmptyView()
        case .upToDate(let v): Text("\(v) is the latest version").font(.caption).foregroundStyle(.secondary)
        case .ready(let v): Text("\(v) downloaded, relaunch to update").font(.caption).foregroundStyle(.green)
        case .available(let v): Text("\(v) is available").font(.caption).foregroundStyle(.secondary)
        case .blocked(let m): Text(m).font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    /// Register/unregister the app as a login item; revert the toggle to the real
    /// system state if the call fails (e.g. the user must approve in Login Items).
    private func setStartAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            startAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    @ViewBuilder private var installerStatus: some View {
        switch installer.status {
        case .idle, .running: EmptyView()
        case .done(let msg): Text(msg).foregroundStyle(.green).font(.caption)
        case .failed(let msg): Text(msg).foregroundStyle(.red).font(.caption).lineLimit(2)
        }
    }

    @ViewBuilder
    private func setupRow<Content: View>(
        _ title: String, ok: Bool, detail: String, @ViewBuilder action: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                action()
            }
            Spacer(minLength: 0)
        }
    }

    private func bind<V>(_ keyPath: WritableKeyPath<TineConfig, V>) -> Binding<V> {
        Binding(get: { state.config[keyPath: keyPath] },
                set: {
                    state.config[keyPath: keyPath] = $0
                    (NSApp.delegate as? AppDelegate)?.relayoutPanel()
                })
    }

    private func openPane(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:\(path)") { NSWorkspace.shared.open(url) }
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    /// Two-way binding to one spec-folder path (writing through config saves it).
    private func bindDir(_ i: Int) -> Binding<String> {
        Binding(
            get: { state.config.localSpecsDirs.indices.contains(i) ? state.config.localSpecsDirs[i] : "" },
            set: { if state.config.localSpecsDirs.indices.contains(i) { state.config.localSpecsDirs[i] = $0 } }
        )
    }
    private func addDir() {
        state.config.localSpecsDirs.append("")
        selectedSpecDir = state.config.localSpecsDirs.count - 1
    }
    private func removeSelectedDir() {
        guard let i = selectedSpecDir, state.config.localSpecsDirs.indices.contains(i) else { return }
        state.config.localSpecsDirs.remove(at: i)
        selectedSpecDir = nil
    }
    private func revealSelectedDir() {
        guard let i = selectedSpecDir, state.config.localSpecsDirs.indices.contains(i) else { return }
        revealSpecs(state.config.localSpecsDirs[i])
    }
    private func revealSpecs(_ path: String) {
        let dir = (path as NSString).expandingTildeInPath
        guard !dir.isEmpty else { return }
        for sub in ["override", "extend"] {
            try? FileManager.default.createDirectory(atPath: "\(dir)/\(sub)", withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }
}

private extension AppState {
    /// One row of each kind the panel draws — matched subcommand, described option,
    /// dangerous option, history value. No engine, no sockets, never persisted.
    static func appearancePreview() -> AppState {
        let state = AppState(persists: false)
        state.suggestions = [
            Suggestion(name: "push", description: "Update remote refs along with associated objects",
                       insertValue: "push", shouldAddSpace: true, type: "subcommand",
                       queryTerm: "pu", isDangerous: false, matchIndices: [0, 1]),
            Suggestion(name: "--set-upstream", description: "Set the upstream for the current branch",
                       insertValue: "--set-upstream", shouldAddSpace: true, type: "option",
                       queryTerm: "", isDangerous: false, matchIndices: []),
            Suggestion(name: "--force", description: "Overwrite the remote branch",
                       insertValue: "--force", shouldAddSpace: true, type: "option",
                       queryTerm: "", isDangerous: true, matchIndices: []),
            Suggestion(name: "origin", description: "from history",
                       insertValue: "origin", shouldAddSpace: true, type: "history",
                       queryTerm: "", isDangerous: false, matchIndices: []),
        ]
        state.selectedIndex = 1
        return state
    }
}

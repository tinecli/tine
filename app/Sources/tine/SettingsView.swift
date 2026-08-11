import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var installer: SpecInstaller
    @EnvironmentObject var updater: AppUpdater

    @State private var report: DoctorReport?
    @State private var shellWriteDetail: String?
    @State private var selectedSpecDir: Int?
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var pane: Pane? = .general
    @StateObject private var previewState = AppState.appearancePreview()
    private let previewTopInset: CGFloat = 18
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    enum Pane: String, CaseIterable, Identifiable {
        case status = "Status", general = "General", appearance = "Appearance", suggestions = "Suggestions"
        case specs = "Specs", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .status: return "checkmark.circle"
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .suggestions: return "text.and.command.macwindow"
            case .specs: return "shippingbox"
            case .about: return "info.circle"
            }
        }
    }

    private let fonts = [("", "System Monospaced"), ("Menlo", "Menlo"),
                         ("Monaco", "Monaco"), ("SF Mono", "SF Mono"),
                         ("Courier New", "Courier New")]
    static let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"

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
        .frame(minWidth: 440, idealWidth: 590, minHeight: 360, idealHeight: 700)
        .background(WindowAccessor())
        .onChange(of: pane) { _, pane in
            if pane == .status { refreshReport() }
        }
        .onReceive(refresh) { _ in
            if pane == .status { refreshReport() }
        }
    }

    @ViewBuilder private var paneBody: some View {
        switch pane ?? .general {
        case .status: statusPane
        case .general: generalPane
        case .appearance: appearancePane
        case .suggestions: suggestionsPane
        case .specs: specsPane
        case .about: aboutPane
        }
    }

    @ViewBuilder private var statusPane: some View {
        if let report {
            Section("Setup") {
                setupRow("Accessibility", ok: report.accessibilityGranted,
                         detail: report.accessibilityGranted
                            ? "Granted"
                            : "Required to place the panel at the terminal caret.") {
                    if !report.accessibilityGranted {
                        Button("Grant") {
                            AXCaret.ensureTrusted()
                            openPane("com.apple.preference.security?Privacy_Accessibility")
                        }
                    }
                }
                setupRow("Shell integration", ok: report.shellInstalled,
                         detail: shellWriteDetail ?? report.shellIntegration.detail) {
                    Text(DoctorReport.shellSourceLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Copy line") { copy(DoctorReport.shellSourceLine) }
                    if report.shellIntegration == .missing {
                        Button("Add the source line to .zshrc") { addShellIntegration() }
                    }
                }
            }
            Section("Updates") {
                setupRow("Completion specs", ok: !report.packUpdateAvailable,
                         detail: "\(report.specCount) CLIs available"
                            + (report.packUpdateAvailable ? " — update available" : "")) {
                    if report.packUpdateAvailable {
                        Button("Install Update") { installer.install() }
                            .disabled(installer.status == .running)
                    }
                }
                setupRow("App version", ok: report.latestAppVersion == nil,
                         detail: appVersionDetail(report)) { EmptyView() }
                setupRow("Staged app update", ok: report.stagedAppVersion == nil,
                         detail: report.stagedAppVersion.map { "v\($0) is ready to install" }
                            ?? "No update staged") {
                    if report.stagedAppVersion != nil {
                        Button("Update & Relaunch") {
                            updater.applyAndRelaunch()
                        }
                    }
                }
            }
            Section("Runtime") {
                setupRow("Socket", ok: report.socketListening,
                         detail: report.socketListening ? report.socketPath : "Not listening") {
                    EmptyView()
                }
                setupRow("Panel placement",
                         ok: report.panelPlacement == .accessibilityCaret
                            || report.panelPlacement == .terminalGrid,
                         detail: report.panelPlacement.rawValue) { EmptyView() }
            }
            Section {
                Button("Copy diagnostics") {
                    copy(report.diagnostics())
                }
            } footer: {
                Text("Copies these values and up to the last 4 KB of the tine log.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Section { ProgressView() }
        }
    }

    @ViewBuilder private var generalPane: some View {
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

    private var preview: some View {
        let size = SuggestionListView.panelSize(state: previewState)
        return GeometryReader { geometry in
            let scale = min(1, geometry.size.width / size.width)
            ZStack(alignment: .topLeading) {
                terminalBackdrop
                SuggestionListView()
                    .environmentObject(previewState)
                    .allowsHitTesting(false)
                    .frame(width: size.width, height: size.height)
                    .padding(.top, previewTopInset)
            }
            .frame(width: size.width, height: size.height + previewTopInset,
                   alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
        }
        .aspectRatio(size.width / (size.height + previewTopInset), contentMode: .fit)
        .clipped()
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.88)))
        .onChange(of: state.config, initial: true) { _, cfg in previewState.config = cfg }
    }

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
                Text("In each folder, drop Fig `.js` specs in `override/<cmd>.js` (replaces a spec) or `extend/<cmd>.js` (adds to it). Earlier folders win.")
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
            if updater.readyVersion != nil {
                Button("Update & Relaunch") { updater.applyAndRelaunch() }
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

    private func setStartAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            startAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func refreshReport() {
        let refreshed = (NSApp.delegate as? AppDelegate)?.doctorReport()
        if refreshed?.shellIntegration != .missing { shellWriteDetail = nil }
        report = refreshed
    }

    private func addShellIntegration() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let result = delegate.addShellIntegration()
        shellWriteDetail = result.isInstalled ? nil : result.detail
        refreshReport()
    }

    private func appVersionDetail(_ report: DoctorReport) -> String {
        if let latest = report.latestAppVersion { return "v\(report.appVersion) — v\(latest) available" }
        return "v\(report.appVersion)"
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
    /// Setting this persists immediately: AppState.config's didSet saves on every write.
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
